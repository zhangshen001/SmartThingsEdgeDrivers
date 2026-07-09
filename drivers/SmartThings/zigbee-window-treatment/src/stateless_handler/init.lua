-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local utils = require "st.utils"
local BRAND_CONFIGS = require "stateless_handler.brand_configs"
local ZigbeeZcl = require "st.zigbee.zcl"
local Messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local ZigbeeConstants = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"

-- Tuya cluster constants (for hanssem)
local TUYA_CLUSTER = 0xEF00
local DP_TYPE_VALUE = "\x02"
local DP_ID_SET_POSITION = "\x02"

-- Get next sequence number for Tuya commands (per-device storage to avoid counter conflicts)
local function get_next_tuya_seq_num(device)
  local seq = device:get_field("tuya_seq_num") or 0
  seq = (seq + 1) % 65536
  device:set_field("tuya_seq_num", seq)
  return seq
end

-- Field keys for tracking target level and timeout timer
local LATEST_TARGET_LEVEL = "__latest_target_level"
local TARGET_LEVEL_TIME_OUT = "__target_level_timeout"
local TARGET_LEVEL_TIME_OUT_SECONDS = 30

-- Get brand configuration for a device
local function get_brand_config(device)
  local manufacturer = device:get_manufacturer() or ""
  local model = device:get_model() or ""
  
  for _, config in ipairs(BRAND_CONFIGS) do
    -- Check if this config matches by model only (match_by_model = true)
    if config.match_by_model then
      -- Match model only (case-insensitive)
      for _, model_pattern in ipairs(config.models) do
        if string.lower(model) == string.lower(model_pattern) then
          return config
        end
      end
    else
      -- Match manufacturer (case-insensitive)
      if string.lower(manufacturer) == string.lower(config.mfr) then
        -- If models list is empty, match any model from this manufacturer
        if #config.models == 0 then
          return config
        end
        -- Check if model matches any in the list (case-insensitive substring match)
        for _, model_pattern in ipairs(config.models) do
          if string.find(string.lower(model), string.lower(model_pattern), 1, true) then
            return config
          end
        end
      end
    end
  end
  return nil -- No matching brand, use default behavior
end

-- Step shade level handler for statelessWindowShadeLevelStep capability
local function step_shade_level_handler(driver, device, command)
  -- Get brand-specific configuration
  local brand_config = get_brand_config(device)
  
  -- Support both args.stepSize (named) and args[1] (array) formats
  local step = command.args.stepSize or command.args[1]

  if not step or step == 0 then
    return
  end

  -- Priority: use target_level if exists, otherwise use latest state
  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)
  local current_level = latest_target_level or
    device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME) or 0

  -- Calculate UI target_level (user's expected percentage)
  local ui_target_level= utils.clamp_value(current_level + step, 0, 100)
  
  ui_target_level = utils.round(ui_target_level)

  -- Apply brand-specific inversion if needed
  local device_target_level = ui_target_level
  if brand_config and brand_config.invert_level then
    device_target_level = 100 - ui_target_level
  end

  -- Set target_level for tracking (store UI value)
  device:set_field(LATEST_TARGET_LEVEL, ui_target_level)

  -- Cancel previous timeout timer if exists
  local old_timer = device:get_field(TARGET_LEVEL_TIME_OUT)
  if old_timer ~= nil then
    device.thread:cancel_timer(old_timer)
  end

  -- Set timeout timer to ensure target_level is cleared after operation completes
  local timer = device.thread:call_with_delay(TARGET_LEVEL_TIME_OUT_SECONDS, function(d)
    device:set_field(LATEST_TARGET_LEVEL, nil)
    device:set_field(TARGET_LEVEL_TIME_OUT, nil)
  end)
  device:set_field(TARGET_LEVEL_TIME_OUT, timer)

  -- Send command based on brand configuration
  if brand_config and brand_config.use_level_cluster then
    -- Feibit/Axis uses Level cluster
    local level_value = math.floor(device_target_level / 100.0 * 254)
    device:send_to_component(command.component, clusters.Level.server.commands.MoveToLevelWithOnOff(device, level_value))
  elseif brand_config and brand_config.use_tuya_cluster then
    -- Hanssem uses Tuya custom cluster 0xEF00
    local strSeqNum = string.pack(">I2", get_next_tuya_seq_num(device))
    local value = string.pack(">I4", device_target_level)
    local LenOfValue = string.pack(">I2", string.len(value))
    local PayloadBody = generic_body.GenericBody(strSeqNum .. DP_ID_SET_POSITION .. DP_TYPE_VALUE .. LenOfValue .. value)
    local zclh = ZigbeeZcl.ZclHeader({cmd = data_types.ZCLCommandId(0x00)})
    zclh.frame_ctrl:set_cluster_specific()
    local addrh = Messages.AddressHeader(
      ZigbeeConstants.HUB.ADDR,
      ZigbeeConstants.HUB.ENDPOINT,
      device:get_short_address(),
      device:get_endpoint(TUYA_CLUSTER),
      ZigbeeConstants.HA_PROFILE_ID,
      TUYA_CLUSTER
    )
    local MsgBody = ZigbeeZcl.ZclMessageBody({zcl_header = zclh, zcl_body = PayloadBody})
    local TxMsg = Messages.ZigbeeMessageTx({address_header = addrh, body = MsgBody})
    device:send(TxMsg)
  else
    -- Standard: use WindowCovering.GoToLiftPercentage
    device:send_to_component(command.component, clusters.WindowCovering.server.commands.GoToLiftPercentage(device, device_target_level))
  end
end

-- Handle device position report from WindowCovering cluster, Level cluster, or AnalogOutput cluster
-- Parameters:
--   reported_level: The raw level value from the device (0-100 percentage)
--   zb_rx: The zigbee receive message for endpoint info
local function shade_level_report_handler(driver, device, reported_level, zb_rx)
  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)
  
  -- Get brand configuration for inversion handling
  local brand_config = get_brand_config(device)
  
  -- Apply brand-specific inversion if needed (device reports inverted value)
  local ui_reported_level = reported_level
  if brand_config and brand_config.invert_level then
    ui_reported_level = 100 - reported_level
  end

  if latest_target_level ~= nil then
    -- Active step control: check if device reached target position (compare UI values)
    if utils.round(ui_reported_level) == utils.round(latest_target_level) then
      -- Device reached target position, clear target marker and timeout timer
      device:set_field(LATEST_TARGET_LEVEL, nil)
      local timer = device:get_field(TARGET_LEVEL_TIME_OUT)
      if timer ~= nil then
        device.thread:cancel_timer(timer)
        device:set_field(TARGET_LEVEL_TIME_OUT, nil)
      end
    end
  end
end

-- Handle device position report from Level cluster (for Feibit, Axis devices)
-- Level cluster reports 0-254, convert to percentage 0-100
local function level_report_handler(driver, device, value, zb_rx)
  local level_value = value.value or 0
  local reported_level = math.floor(level_value / 254.0 * 100)
  shade_level_report_handler(driver, device, reported_level, zb_rx)
end

-- Handle device position report from WindowCovering cluster
-- Reports 0-100 percentage directly
local function window_covering_report_handler(driver, device, value, zb_rx)
  local reported_level = value.value or 0
  shade_level_report_handler(driver, device, reported_level, zb_rx)
end

-- Handle device position report from AnalogOutput cluster (for Aqara devices)
-- Reports 0-100 percentage directly
local function analog_output_report_handler(driver, device, value, zb_rx)
  local reported_level = value.value or 0
  shade_level_report_handler(driver, device, reported_level, zb_rx)
end

local stateless_handler = {
  NAME = "Zigbee Window Treatment Stateless Step Handlers",
  capability_handlers = {
    [capabilities.statelessWindowShadeLevelStep.ID] = {
      [capabilities.statelessWindowShadeLevelStep.commands.stepShadeLevel.NAME] = step_shade_level_handler,
    },
  },
  zigbee_handlers = {
    attr = {
      [clusters.WindowCovering.ID] = {
        [clusters.WindowCovering.attributes.CurrentPositionLiftPercentage.ID] = window_covering_report_handler,
      },
      [clusters.Level.ID] = {
        [clusters.Level.attributes.CurrentLevel.ID] = level_report_handler,
      },
      [clusters.AnalogOutput.ID] = {
        [clusters.AnalogOutput.attributes.PresentValue.ID] = analog_output_report_handler,
      },
    },
  },
  can_handle = require("stateless_handler.can_handle")
}

return stateless_handler
