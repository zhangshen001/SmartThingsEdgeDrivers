-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0



local capabilities = require "st.capabilities"
local device_management = require "st.zigbee.device_management"
local window_shade_utils = require "window_shade_utils"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local utils = require "st.utils"

local Basic = zcl_clusters.Basic
local Level = zcl_clusters.Level
local PowerConfiguration = zcl_clusters.PowerConfiguration
local WindowCovering = zcl_clusters.WindowCovering

local LATEST_TARGET_LEVEL = "latest_target_level"
local TARGET_LEVEL_TIME_OUT = "_target_level_timeout"
local TARGET_LEVEL_TIME_OUT_SECONDS = 30
local SOFTWARE_VERSION = "software_version"
local DEFAULT_LEVEL = 0


-- Commands
local function window_shade_set_level(device, command, level)
  local current_level = device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME) or DEFAULT_LEVEL
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  -- Opening or Closing
  local windowShade = capabilities.windowShade.windowShade
  device:emit_event(level > current_level and windowShade.opening() or windowShade.closing())
  -- Send Zigbee command
  device:send_to_component(command.component, Level.server.commands.MoveToLevelWithOnOff(device, utils.round(level/100.0 * 254)))
end

local function window_shade_level_cmd_handler(driver, device, command)
  local level = command.args.shadeLevel
  window_shade_set_level(device, command, level)
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

  window_shade_set_level(device, command, target_level)
end

local function window_shade_preset_cmd(driver, device, command)
  local level = window_shade_utils.get_preset_level(device, command.component)
  window_shade_set_level(device, command, level)
end

local function window_shade_pause_cmd(driver, device, command)
  device.thread:call_with_delay(5, function(d)
    device:send(Level.attributes.CurrentLevel:read(device))
    end
  )
end

local function window_shade_open_cmd(driver, device, command)
  window_shade_set_level(device, command, 100)
end

local function window_shade_close_cmd(driver, device, command)
  window_shade_set_level(device, command, 0)
end

-- Common
local function handle_window_shade(device, current_level)
  local windowShade = capabilities.windowShade.windowShade
  if current_level > 0 and current_level < 99 then
    device:emit_event(windowShade.partially_open())
  elseif current_level >= 99 then
    device:emit_event(windowShade.open())
  else
    device:emit_event(windowShade.closed())
  end
end

local function level_attr_handler(driver, device, value, zb_rx)
  local level = utils.round((value.value/254.0) * 100)
  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)

  if latest_target_level ~= nil then
    -- Active step control
    if level == utils.round(latest_target_level) then
      -- Device reached target position, clear target marker and timeout timer
      device:set_field(LATEST_TARGET_LEVEL, nil)
      local timer = device:get_field(TARGET_LEVEL_TIME_OUT)
      if timer ~= nil then
        device.thread:cancel_timer(timer)
        device:set_field(TARGET_LEVEL_TIME_OUT, nil)
      end
    end
  end
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  handle_window_shade(device, level)
end

local do_refresh = function(self, device)
  device:send(Level.attributes.CurrentLevel:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  device:send(Basic.attributes.SWBuildID:read(device))
end

-- Attr Handlers
local function basic_software_version_attr_handler(driver, device, value, zb_rx)
  -- The version string is usually in the format of A.B.C.DDDD
  -- Such as: 102-5.3.5.1125
  -- We want the last 4
  local version = tonumber(string.sub(value.value, -4))

  device:set_field(SOFTWARE_VERSION, version, {persist = true})
end

local do_configure = function(self, device)
  device:send(device_management.build_bind_request(device, Level.ID, self.environment_info.hub_zigbee_eui))
  device:send(Level.attributes.CurrentLevel:configure_reporting(device, 1, 3600, 1))
  device:send(device_management.build_bind_request(device, WindowCovering.ID, self.environment_info.hub_zigbee_eui))
  device:send(WindowCovering.attributes.CurrentPositionLiftPercentage:configure_reporting(device, 1, 3600, 1))
  device:send(device_management.build_bind_request(device, PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 1, 3600, 1))
  device:refresh()
end

local device_added = function(self, device)
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({"open", "close", "pause"}, { visibility = { displayed = false } }))
  device:set_field(SOFTWARE_VERSION, 0)
  device:send(Basic.attributes.SWBuildID:read(device))
end

local axis_handler = {
  NAME = "AXIS Gear Handler",
  capability_handlers = {
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_cmd_handler
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_cmd
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = window_shade_open_cmd,
      [capabilities.windowShade.commands.close.NAME] = window_shade_close_cmd,
      [capabilities.windowShade.commands.pause.NAME] = window_shade_pause_cmd
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
      [Basic.ID] = {
        [Basic.attributes.SWBuildID.ID] = basic_software_version_attr_handler
      },
      [Level.ID] = {
        [Level.attributes.CurrentLevel.ID] = level_attr_handler
      }
    }
  },
  lifecycle_handlers = {
    added = device_added,
    doConfigure = do_configure,
  },
  sub_drivers = require("axis.sub_drivers"),
  can_handle = require("axis.can_handle"),
}

return axis_handler
