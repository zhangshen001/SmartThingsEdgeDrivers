-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

-- Brand-specific configuration for window treatment devices
-- Supports statelessWindowShadeLevelStep capability

local BRAND_CONFIGS = {
  -- invert_level = true: Device reports inverted values (0 = open, 100 = closed)
  -- When sending command: device_target_level = 100 - ui_target_level
  -- When receiving report: ui_reported_level = 100 - reported_level
  {
    name = "aqara",
    mfr = "LUMI",
    models = { "lumi.curtain", "lumi.curtain.v1", "lumi.curtain.aq2", "lumi.curtain.agl001", "lumi.curtain.acn002" },
    invert_level = true,
  },
  {
    name = "somfy",
    mfr = "Somfy",
    models = {},  -- Empty models = match any model from this manufacturer
    invert_level = true,
  },
  {
    name = "vimar",
    mfr = "VIMAR",
    models = {},
    invert_level = true,
  },
  {
    name = "invert-lift-percentage",
    mfr = "IKEA of Sweden",
    models = {},
    invert_level = true,
  },
  {
    name = "invert-lift-percentage",
    mfr = "Smartwings",
    models = {},
    invert_level = true,
  },
  {
    name = "invert-lift-percentage",
    mfr = "Insta GmbH",
    models = {},
    invert_level = true,
  },
  {
    name = "yoolax",
    mfr = "Yookee",
    models = { "D10110" },
    invert_level = true,
  },
  {
    name = "yoolax",
    mfr = "yooksmart",
    models = { "D10110" },
    invert_level = true,
  },
  -- use_level_cluster = true: Use Level cluster instead of WindowCovering
  -- Level cluster uses 0-254 range, converted from percentage: level_value = math.floor(percentage / 100.0 * 254)
  {
    name = "feibit",
    mfr = "Feibit Co.Ltd",
    models = { "FTB56-ZT218AK1.6", "FTB56-ZT218AK1.8" },
    use_level_cluster = true,
  },
  {
    name = "axis",
    mfr = "AXIS",
    models = {},
    use_level_cluster = true,
  },
  -- Standard devices (no special handling needed)
  -- Use WindowCovering.GoToLiftPercentage with 0-100 percentage
  {
    name = "hanssem",
    mfr = "",
    models = { "TS0601" },
    match_by_model = true,  -- Match by model only, not manufacturer
    use_tuya_cluster = true,  -- Use Tuya custom cluster 0xEF00
  },
  {
    name = "rooms-beautiful",
    mfr = "Rooms Beautiful",
    models = { "C001" },
  },
  {
    name = "screen-innovations",
    mfr = "",
    models = { "WM25/L-Z" },
    match_by_model = true,
  },
  -- Note: HOPOsmart and VIVIDSTORM are NOT supported (use custom clusters)
}

return BRAND_CONFIGS
