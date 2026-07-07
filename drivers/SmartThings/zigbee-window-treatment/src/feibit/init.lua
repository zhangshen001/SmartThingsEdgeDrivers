-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0


local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local window_shade_utils = require "window_shade_utils"
local window_shade_defaults = require "st.zigbee.defaults.windowShade_defaults"
local device_management = require "st.zigbee.device_management"
local Level = zcl_clusters.Level
local utils = require "st.utils"

local LATEST_TARGET_LEVEL = "latest_target_level"
local TARGET_LEVEL_TIME_OUT = "_target_level_timeout"
local TARGET_LEVEL_TIME_OUT_SECONDS = 30


local function set_shade_level(device, value, component)
  local level = math.floor(value / 100.0 * 254)
  device:send_to_component(component, Level.server.commands.MoveToLevelWithOnOff(device, level))
end

local function window_shade_level_cmd_handler(driver, device, command)
  set_shade_level(device, command.args.shadeLevel, command.component)
end

local function window_shade_step_level_cmd(driver, device, command)
  -- Support both args.stepSize (named) and args[1] (array) formats
  local step = command.args.stepSize or command.args[1]

  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)
  local current_level = latest_target_level or
    device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME) or 0

  local target_level = current_level + step
  if target_level > 100 then
    target_level = 100
  elseif target_level < 0 then
    target_level = 0
  end
  target_level = utils.round(target_level)

  device:set_field(LATEST_TARGET_LEVEL, target_level)

  -- Cancel previous timeout timer if exists
  local old_timer = device:get_field(TARGET_LEVEL_TIME_OUT)
  if old_timer ~= nil then
    device.thread:cancel_timer(old_timer)
  end

  -- Set 30 second timeout timer to ensure target_level is cleared
  local timer = device.thread:call_with_delay(TARGET_LEVEL_TIME_OUT_SECONDS, function(d)
    device:set_field(LATEST_TARGET_LEVEL, nil)
    device:set_field(TARGET_LEVEL_TIME_OUT, nil)
  end)
  device:set_field(TARGET_LEVEL_TIME_OUT, timer)

  set_shade_level(device, target_level, command.component)
end

local function level_attr_handler(driver, device, value, zb_rx)
  local current_level = math.floor(value.value / 100 * 254)
  local reported_level = value.value
  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)

  value.value = current_level

  if latest_target_level ~= nil then
    -- Active step control
    if utils.round(reported_level) == utils.round(latest_target_level) then
      -- Device reached target position, clear target marker and timeout timer
      device:set_field(LATEST_TARGET_LEVEL, nil)
      local timer = device:get_field(TARGET_LEVEL_TIME_OUT)
      if timer ~= nil then
        device.thread:cancel_timer(timer)
        device:set_field(TARGET_LEVEL_TIME_OUT, nil)
      end
    end
  end
  window_shade_defaults.default_current_lift_percentage_handler(driver, device, value, zb_rx)
end

local function window_shade_preset_cmd(driver, device, command)
  local level = window_shade_utils.get_preset_level(device, command.component)
  set_shade_level(device, level, command.component)
end

local do_refresh = function(self, device)
  device:send(Level.attributes.CurrentLevel:read(device))
end

local do_configure = function(self, device)
  device:send(device_management.build_bind_request(device, Level.ID, self.environment_info.hub_zigbee_eui))
  device:send(Level.attributes.CurrentLevel:configure_reporting(device, 1, 3600, 1))
  device:refresh()
end

local feibit_handler = {
  NAME = "Feibit Device Handler",
  capability_handlers = {
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_cmd_handler
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_cmd
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
    [capabilities.statelessWindowShadeLevelStep.ID] = {
      [capabilities.statelessWindowShadeLevelStep.commands.stepShadeLevel.NAME] = window_shade_step_level_cmd
    }
  },
  zigbee_handlers = {
    attr = {
      [Level.ID] = {
        [Level.attributes.CurrentLevel.ID] = level_attr_handler
      }
    }
  },
  lifecycle_handlers = {
    doConfigure = do_configure,
  },
  can_handle = require("feibit.can_handle"),
}

return feibit_handler
