-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Direct unit test for stateless_handler module
-- Tests the handler functions directly without relying on can_handle mechanism

local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local t_utils = require "integration_test.utils"
local test = require "integration_test"
local zigbee_test_utils = require "integration_test.zigbee_test_utils"

local WindowCovering = clusters.WindowCovering
local AnalogOutput = clusters.AnalogOutput

zigbee_test_utils.prepare_zigbee_env_info()

-- Mock device for aqara (invert_level = true)
local aqara_device = test.mock_device.build_test_zigbee_device(
  {
    profile = t_utils.get_profile_definition("window-treatment-aqara.yml"),
    fingerprinted_endpoint_id = 0x01,
    zigbee_endpoints = {
      [1] = {
        id = 1,
        manufacturer = "LUMI",
        model = "lumi.curtain",
        server_clusters = { WindowCovering.ID, AnalogOutput.ID }
      }
    }
  }
)

local function test_init()
  test.mock_device.add_test_device(aqara_device)
end

test.set_test_init_function(test_init)

-- ============================================================================
-- Test: stepShadeLevel command for aqara devices (invert_level = true)
-- ============================================================================

test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - aqara device increase",
  function()
    -- Set initial state by simulating a position report
    -- Note: Both aqara sub-driver and stateless_handler will process this message
    -- aqara sends windowShade event, stateless_handler sends windowShadeLevel event
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 50)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 50 } }
    })
    -- Also expect the windowShade event from aqara sub-driver
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()
    
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { stepSize = 10 } }
    })
    
    -- Should send GoToLiftPercentage with inverted value (100 - 60 = 40)
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 40)
    })
  end,
  { min_api_version = 17 }
)

test.run_registered_tests()
-- ============================================================================

test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - aqara device increase",
  function()
    local aqara_device = test.mock_device.build_test_zigbee_device(
      {
        profile = t_utils.get_profile_definition("window-treatment-aqara.yml"),
        fingerprinted_endpoint_id = 0x01,
        zigbee_endpoints = {
          [1] = {
            id = 1,
            manufacturer = "LUMI",
            model = "lumi.curtain",
            server_clusters = { WindowCovering.ID, AnalogOutput.ID }
          }
        }
      }
    )
    test.mock_device.add_test_device(aqara_device)
    
    -- Set initial state by simulating a position report
    -- Note: Both aqara sub-driver and stateless_handler will process this message
    -- aqara sends windowShade event, stateless_handler sends windowShadeLevel event
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 50)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 50 } }
    })
    -- Also expect the windowShade event from aqara sub-driver
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()
    
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { stepSize = 10 } }
    })
    
    -- Should send GoToLiftPercentage with inverted value (100 - 60 = 40)
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 40)
    })
  end,
  { min_api_version = 17 }
)

test.run_registered_tests()
