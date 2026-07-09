-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Direct unit test for stateless_handler module
-- Tests boundary conditions for stepShadeLevel command

local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local t_utils = require "integration_test.utils"
local test = require "integration_test"
local zigbee_test_utils = require "integration_test.zigbee_test_utils"

local WindowCovering = clusters.WindowCovering
local AnalogOutput = clusters.AnalogOutput

-- Register the statelessWindowShadeLevelStep capability for testing
test.add_package_capability("statelessWindowShadeLevelStep.yaml")

-- Create mock Aqara curtain device
-- Aqara has invert_level = true, meaning:
-- - Device reports: 0 = fully open, 100 = fully closed
-- - UI shows: 0 = fully closed, 100 = fully open (inverted)
-- - UI value = 100 - device value
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

zigbee_test_utils.prepare_zigbee_env_info()

local function test_init()
  test.mock_device.add_test_device(aqara_device)
end

test.set_test_init_function(test_init)

-- Test 1: Boundary condition - stepSize = 0 should not send command
-- Tests stateless_handler: stepShadeLevel command with stepSize=0 should not send Zigbee command
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - stepSize 0 does not send command",
  function()
    -- Set initial state via device report: device=50% -> UI = 100 - 50 = 50%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 50)
    })
    -- Device report triggers windowShadeLevel and windowShade events (handled by zigbee_handlers, not stateless_handler)
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 50 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with stepSize = 0 (tests stateless_handler)
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { 0 } }
    })

    -- Should NOT send any Zigbee command (stepSize 0 is ignored by stateless_handler)
    test.wait_for_events()
  end,
  { min_api_version = 17 }
)

-- Test 2: Boundary condition - value clamped to 100 (UI)
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - value clamped to 100",
  function()
    -- Set initial state: device=10% -> UI = 100 - 10 = 90%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 10)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 90 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with stepSize = 50 (would exceed 100)
    -- Expected: clamp(90 + 50, 0, 100) = 100 UI, device = 100 - 100 = 0
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { 50 } }
    })

    -- Should send GoToLiftPercentage with value 0 (clamped and inverted)
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 0)
    })
  end,
  { min_api_version = 17 }
)

-- Test 3: Boundary condition - value clamped to 0 (UI, negative step)
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - value clamped to 0",
  function()
    -- Set initial state: device=90% -> UI = 100 - 90 = 10%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 90)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 10 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with stepSize = -20 (would go below 0)
    -- Expected: clamp(10 + (-20), 0, 100) = 0 UI, device = 100 - 0 = 100
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { -20 } }
    })

    -- Should send GoToLiftPercentage with value 100 (clamped and inverted)
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 100)
    })
  end,
  { min_api_version = 17 }
)

-- Test 4: Normal step up operation
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - normal step up",
  function()
    -- Set initial state: device=70% -> UI = 100 - 70 = 30%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 70)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 30 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with stepSize = 10
    -- Expected: 30 + 10 = 40 UI, device = 100 - 40 = 60
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { 10 } }
    })

    -- Should send GoToLiftPercentage with value 60
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 60)
    })
  end,
  { min_api_version = 17 }
)

-- Test 5: Normal step down operation
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - normal step down",
  function()
    -- Set initial state: device=30% -> UI = 100 - 30 = 70%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 30)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 70 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with stepSize = -20
    -- Expected: 70 + (-20) = 50 UI, device = 100 - 50 = 50
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { -20 } }
    })

    -- Should send GoToLiftPercentage with value 50
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 50)
    })
  end,
  { min_api_version = 17 }
)

-- Test 6: stepSize is nil
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - nil stepSize does not send command",
  function()
    -- Reset Aqara device state
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 50)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 50 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with nil stepSize
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = {} }
    })

    -- Should NOT send any Zigbee command
    test.wait_for_events()
  end,
  { min_api_version = 17 }
)

-- Test 7: Boundary condition - minimum stepSize (stepSize = 1)
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - minimum stepSize 1 works correctly",
  function()
    -- Set initial state: device=50% -> UI = 100 - 50 = 50%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 50)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 50 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with stepSize = 1 (minimum positive step)
    -- Expected: 50 + 1 = 51 UI, device = 100 - 51 = 49
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { 1 } }
    })

    -- Should send GoToLiftPercentage with value 49
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 49)
    })
  end,
  { min_api_version = 17 }
)

-- Test 8: Boundary condition - minimum negative stepSize (stepSize = -1)
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - minimum negative stepSize -1 works correctly",
  function()
    -- Set initial state: device=50% -> UI = 100 - 50 = 50%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 50)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 50 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Send stepShadeLevel command with stepSize = -1 (minimum negative step)
    -- Expected: 50 + (-1) = 49 UI, device = 100 - 49 = 51
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { -1 } }
    })

    -- Should send GoToLiftPercentage with value 51
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 51)
    })
  end,
  { min_api_version = 17 }
)

-- Test 9: Continuous step operation - multiple consecutive steps with mixed directions
test.register_coroutine_test(
  "stateless_handler: stepShadeLevel - continuous step operations with mixed directions",
  function()
    -- Set initial state: device=50% -> UI = 100 - 50 = 50%
    test.socket.zigbee:__queue_receive({
      aqara_device.id,
      WindowCovering.attributes.CurrentPositionLiftPercentage:build_test_attr_report(aqara_device, 50)
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShadeLevel", component_id = "main", attribute_id = "shadeLevel", state = { value = 50 } }
    })
    test.socket.capability:__expect_send({
      aqara_device.id,
      { capability_id = "windowShade", component_id = "main", attribute_id = "windowShade", state = { value = "partially open" } }
    })
    test.wait_for_events()

    -- Step 1: stepSize = 10 (up), Expected: 50 + 10 = 60 UI, device = 100 - 60 = 40
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { 10 } }
    })
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 40)
    })
    test.wait_for_events()

    -- Step 2: stepSize = 10 (up), Expected: 60 + 10 = 70 UI, device = 100 - 70 = 30
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { 10 } }
    })
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 30)
    })
    test.wait_for_events()

    -- Step 3: stepSize = -20 (down), Expected: 70 + (-20) = 50 UI, device = 100 - 50 = 50
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { -20 } }
    })
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 50)
    })
    test.wait_for_events()

    -- Step 4: stepSize = 15 (up), Expected: 50 + 15 = 65 UI, device = 100 - 65 = 35
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { 15 } }
    })
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 35)
    })
    test.wait_for_events()

    -- Step 5: stepSize = -5 (down), Expected: 65 + (-5) = 60 UI, device = 100 - 60 = 40
    test.socket.capability:__queue_receive({
      aqara_device.id,
      { capability = "statelessWindowShadeLevelStep", component = "main", command = "stepShadeLevel", args = { -5 } }
    })
    test.socket.zigbee:__expect_send({
      aqara_device.id,
      WindowCovering.server.commands.GoToLiftPercentage(aqara_device, 40)
    })
    test.wait_for_events()
  end,
  { min_api_version = 17 }
)

test.run_registered_tests()
