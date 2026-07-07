-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0


local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local window_shade_utils = require "window_shade_utils"
local utils = require "st.utils"

local WindowCovering = zcl_clusters.WindowCovering

local SHADE_SET_STATUS = "shade_set_status"
local LATEST_TARGET_LEVEL = "latest_target_level"
local TARGET_LEVEL_TIME_OUT = "_target_level_timeout"
local TARGET_LEVEL_TIME_OUT_SECONDS = 30

local function current_position_attr_handler(driver, device, value, zb_rx)
  local level = 100 - value.value
  local current_level = device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
  local windowShade = capabilities.windowShade.windowShade
  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)

  if latest_target_level ~= nil then
    -- Active step control
    if utils.round(level) == utils.round(latest_target_level) then
      -- Device reached target position, clear target marker and timeout timer
      device:set_field(LATEST_TARGET_LEVEL, nil)
      local timer = device:get_field(TARGET_LEVEL_TIME_OUT)
      if timer ~= nil then
        device.thread:cancel_timer(timer)
        device:set_field(TARGET_LEVEL_TIME_OUT, nil)
      end
    end
  end
  if level == -155 then -- unknown position
    device:emit_event(windowShade.unknown())
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(100))
  elseif level == 0 then
    device:emit_event(windowShade.closed())
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(0))
  elseif level == 100 then
    device:emit_event(windowShade.open())
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(100))
  else
    if current_level ~= level or current_level == nil then
      current_level = current_level or 0
      device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
      local event = nil
      if current_level ~= level then
        event = current_level < level and windowShade.opening() or windowShade.closing()
      end
      if event ~= nil then
        device:emit_event(event)
      end
    end
    local set_status_timer = device:get_field(SHADE_SET_STATUS)
    if set_status_timer then
      device.thread:cancel_timer(set_status_timer)
      device:set_field(SHADE_SET_STATUS, nil)
    end
    local set_window_shade_status = function()
      device:set_field(SHADE_SET_STATUS, nil)
      local current_level = device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
      if current_level == 0 then
        device:emit_event(windowShade.closed())
      elseif current_level == 100 then
        device:emit_event(windowShade.open())
      else
        device:emit_event(windowShade.partially_open())
      end
    end
    set_status_timer = device.thread:call_with_delay(1, set_window_shade_status)
    device:set_field(SHADE_SET_STATUS, set_status_timer)
  end
end

local function set_shade_level(device, value, command)
  local level = 100 - value
  device:send_to_component(command.component, WindowCovering.server.commands.GoToLiftPercentage(device, level))
end

local function window_shade_level_cmd(driver, device, command)
  set_shade_level(device, command.args.shadeLevel, command)
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

  set_shade_level(device, target_level, command)
end

local function window_shade_preset_cmd(driver, device, command)
  local level = window_shade_utils.get_preset_level(device, command.component)
  set_shade_level(device, level, command)
end

local ikea_window_treatment = {
  NAME = "inverted lift percentage",
  zigbee_handlers = {
    attr = {
      [WindowCovering.ID] = {
        [WindowCovering.attributes.CurrentPositionLiftPercentage.ID] = current_position_attr_handler
      }
    }
  },
  capability_handlers = {
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_cmd
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_cmd
    },
    [capabilities.statelessWindowShadeLevelStep.ID] = {
      [capabilities.statelessWindowShadeLevelStep.commands.stepShadeLevel.NAME] = window_shade_step_level_cmd
   }
  },
  can_handle = require("invert-lift-percentage.can_handle"),
}

return ikea_window_treatment
