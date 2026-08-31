-- Shared defaults and normalization helpers for Neurocast script-aligner UI settings.
-- Public API:
--   NeurocastScriptAlignerSettings.DEFAULTS
--   NeurocastScriptAlignerSettings.CSV_SERVER_DEFAULT
--   NeurocastScriptAlignerSettings.normalize_match_confidence_threshold(value)
--   NeurocastScriptAlignerSettings.normalize_time_window_seconds(value)
--   NeurocastScriptAlignerSettings.resolve_ui_state(values)
--   NeurocastScriptAlignerSettings.build_request_options(values)

local NeurocastScriptAlignerSettings = {}

NeurocastScriptAlignerSettings.DEFAULTS = {
  matchConfidenceThreshold = 0.65,
  timeWindowSeconds = 5
}

NeurocastScriptAlignerSettings.CSV_SERVER_DEFAULT = 0.5

local function clamp(value, min_value, max_value)
  if value < min_value then return min_value end
  if value > max_value then return max_value end
  return value
end

local function round_to_decimals(value, decimals)
  local precision = 10 ^ (tonumber(decimals) or 0)
  return math.floor((value * precision) + 0.5) / precision
end

function NeurocastScriptAlignerSettings.normalize_match_confidence_threshold(value)
  local number = tonumber(value)
  if number == nil then
    number = NeurocastScriptAlignerSettings.DEFAULTS.matchConfidenceThreshold
  end
  number = clamp(number, 0, 1)
  return round_to_decimals(number, 2)
end

function NeurocastScriptAlignerSettings.normalize_time_window_seconds(value)
  local number = tonumber(value)
  if number == nil then
    number = NeurocastScriptAlignerSettings.DEFAULTS.timeWindowSeconds
  end
  return clamp(math.floor(number), 1, 60)
end

function NeurocastScriptAlignerSettings.resolve_ui_state(values)
  local source = type(values) == "table" and values or {}
  return {
    matchConfidenceThreshold = NeurocastScriptAlignerSettings.normalize_match_confidence_threshold(source.matchConfidenceThreshold),
    timeWindowSeconds = NeurocastScriptAlignerSettings.normalize_time_window_seconds(source.timeWindowSeconds)
  }
end

function NeurocastScriptAlignerSettings.build_request_options(values)
  local resolved = NeurocastScriptAlignerSettings.resolve_ui_state(values)
  return {
    matchConfidenceThreshold = resolved.matchConfidenceThreshold,
    timeWindowSeconds = resolved.timeWindowSeconds
  }
end

return NeurocastScriptAlignerSettings
