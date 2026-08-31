-- Parser/normalizer for Neurocast script-aligner result JSON.
-- Public API:
--   NeurocastScriptAlignerResult.parse_result_json_text(json_text)
--   NeurocastScriptAlignerResult.parse_result_file(path)
--   NeurocastScriptAlignerResult.build_import_rows(parsed_result, opts)

local NeurocastScriptAlignerResult = {}

local ok_json, json = pcall(require, "modules-neurocast.json")
if not ok_json then
  error("neurocast_script_aligner_result: failed to load modules-neurocast.json: " .. tostring(json))
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function is_array_like(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function utf8_length(text)
  local value = tostring(text or "")
  if utf8 and utf8.len then
    local ok_len, result = pcall(utf8.len, value)
    if ok_len and type(result) == "number" then
      return result
    end
  end
  return #value
end

local function read_file(path)
  local fh, open_err = io.open(tostring(path or ""), "rb")
  if not fh then
    return nil, "open failed: " .. tostring(open_err)
  end
  local data, read_err = fh:read("*a")
  fh:close()
  if not data then
    return nil, "read failed: " .. tostring(read_err or "unknown error")
  end
  return data, nil
end

local function require_nonempty_string(tbl, key, line_index)
  local value = trim(tbl and tbl[key] or "")
  if value == "" then
    return nil, string.format("Line %d: `%s` must be a non-empty string.", line_index, tostring(key))
  end
  return value, nil
end

local function require_nonnegative_number(tbl, key, line_index)
  local value = tonumber(tbl and tbl[key] or nil)
  if value == nil then
    return nil, string.format("Line %d: `%s` must be a number.", line_index, tostring(key))
  end
  if value < 0 then
    return nil, string.format("Line %d: `%s` must be >= 0.", line_index, tostring(key))
  end
  return value, nil
end

local function optional_number(tbl, key)
  local value = tbl and tbl[key]
  if value == nil then return nil, nil end
  local n = tonumber(value)
  if n == nil then
    return nil, string.format("`%s` must be a number when present.", tostring(key))
  end
  return n, nil
end

local function optional_confidence_number(tbl, key)
  local value = tbl and tbl[key]
  if value == nil then return nil end
  return tonumber(value)
end

local function clamp(value, min_value, max_value)
  if value < min_value then return min_value end
  if value > max_value then return max_value end
  return value
end

local function fallback_track_name(value)
  local cleaned = trim(value)
  if cleaned == "" then
    return "no_character", true
  end
  return cleaned, false
end

local function corrected_timing_issue_short_desc(kind)
  if kind == "missing_start" then
    return "missing corrected start"
  end
  if kind == "missing_end" then
    return "missing corrected end"
  end
  if kind == "invalid_number" then
    return "bad corrected time"
  end
  if kind == "negative_time" then
    return "negative corrected time"
  end
  if kind == "nonpositive_length" then
    return "zero/negative length"
  end
  return "invalid corrected timing"
end

local function corrected_timing_marker_name(track_name, issue_kind)
  return trim(track_name) .. " " .. corrected_timing_issue_short_desc(issue_kind)
end

local function build_fallback_length_seconds(text, chars_per_second, min_fallback_item_length_sec)
  local fallback_length = utf8_length(text) / chars_per_second
  if fallback_length < min_fallback_item_length_sec then
    fallback_length = min_fallback_item_length_sec
  end
  return fallback_length
end

local function build_legacy_item_color_rgb(line)
  if type(line) ~= "table" or line.has_corrected_timing ~= true then
    return { r = 255, g = 0, b = 0 }
  end

  local effective_confidence = nil
  local confidence = line.confidence
  if type(confidence) == "number" then
    effective_confidence = clamp(confidence, 0, 1)
  end

  local match_confidence = line.match_confidence
  if type(match_confidence) == "number" then
    local clamped = clamp(match_confidence, 0, 1)
    if effective_confidence == nil or clamped < effective_confidence then
      effective_confidence = clamped
    end
  end

  if effective_confidence == nil then
    effective_confidence = 0
  end

  return {
    r = math.floor((1 - effective_confidence) * 255),
    g = math.floor(effective_confidence * 255),
    b = 0
  }
end

local function normalize_line(line_tbl, line_index)
  if type(line_tbl) ~= "table" then
    return nil, string.format("Line %d: line entry must be an object.", line_index)
  end

  local original_text, text_err = require_nonempty_string(line_tbl, "original_text", line_index)
  if not original_text then return nil, text_err end

  local original_start_time_sec, start_err = require_nonnegative_number(line_tbl, "original_start_timecode", line_index)
  if not original_start_time_sec then return nil, start_err end

  local character_name, used_fallback_track_name = fallback_track_name(line_tbl.character_name)

  local corrected_start_time_sec, corrected_start_err = optional_number(line_tbl, "corrected_start_timecode")
  local corrected_end_time_sec, corrected_end_err = optional_number(line_tbl, "corrected_end_timecode")
  local corrected_start_present = line_tbl.corrected_start_timecode ~= nil
  local corrected_end_present = line_tbl.corrected_end_timecode ~= nil

  local has_corrected_timing = false
  local corrected_timing_issue_kind = ""
  local corrected_timing_issue_text = ""
  local corrected_timing_marker_name_text = ""

  if corrected_start_present or corrected_end_present then
    if corrected_start_err or corrected_end_err then
      corrected_timing_issue_kind = "invalid_number"
      corrected_timing_issue_text = string.format(
        "Line %d: corrected timing ignored because %s",
        line_index,
        tostring(corrected_start_err or corrected_end_err or "corrected timing fields are invalid.")
      )
    elseif corrected_start_time_sec == nil or corrected_end_time_sec == nil then
      corrected_timing_issue_kind = corrected_start_time_sec == nil and "missing_start" or "missing_end"
      corrected_timing_issue_text = string.format(
        "Line %d: corrected timing ignored because `%s` is missing.",
        line_index,
        corrected_start_time_sec == nil and "corrected_start_timecode" or "corrected_end_timecode"
      )
    elseif corrected_start_time_sec < 0 or corrected_end_time_sec < 0 then
      corrected_timing_issue_kind = "negative_time"
      corrected_timing_issue_text = string.format("Line %d: corrected timing ignored because it contains a negative value.", line_index)
    elseif corrected_end_time_sec <= corrected_start_time_sec then
      corrected_timing_issue_kind = "nonpositive_length"
      corrected_timing_issue_text = string.format(
        "Line %d: corrected timing length is <= 0; importing with fallback item length.",
        line_index
      )
    else
      has_corrected_timing = true
    end
  end

  if corrected_timing_issue_kind ~= "" then
    corrected_timing_marker_name_text = corrected_timing_marker_name(character_name, corrected_timing_issue_kind)
  end

  local confidence = optional_confidence_number(line_tbl, "confidence")
  local match_confidence = optional_confidence_number(line_tbl, "match_confidence")
  local original_line_number = tonumber(line_tbl.original_line_number or nil)
  local status = trim(line_tbl.status or "")
  local matched_text = line_tbl.matched_text
  if matched_text ~= nil then
    matched_text = tostring(matched_text)
  end

  return {
    source_index = line_index,
    character_name = character_name,
    original_text = original_text,
    original_line_number = original_line_number,
    original_timecode_start_text = trim(line_tbl.original_timecode_start or ""),
    original_start_time_sec = original_start_time_sec,
    corrected_start_time_sec = corrected_start_time_sec,
    corrected_end_time_sec = corrected_end_time_sec,
    has_corrected_timing = has_corrected_timing,
    corrected_timing_issue_kind = corrected_timing_issue_kind,
    corrected_timing_issue_text = corrected_timing_issue_text,
    corrected_timing_marker_name = corrected_timing_marker_name_text,
    confidence = confidence,
    match_confidence = match_confidence,
    matched_text = matched_text,
    status = status,
    matching_segment_ids = is_array_like(line_tbl.matching_segment_ids) and line_tbl.matching_segment_ids or {},
    used_fallback_track_name = used_fallback_track_name == true
  }, nil
end

function NeurocastScriptAlignerResult.parse_result_table(decoded)
  if type(decoded) ~= "table" then
    return nil, "Top-level JSON value must be an object."
  end
  if not is_array_like(decoded.lines) then
    return nil, "Top-level `lines` field must be an array."
  end

  local parsed_lines = {}
  local status_counts = {}
  local aligned_count = 0
  local fallback_count = 0
  local corrected_timing_issue_count = 0
  local warnings = {}
  for index = 1, #decoded.lines do
    local normalized_line, normalize_err = normalize_line(decoded.lines[index], index)
    if not normalized_line then
      return nil, normalize_err
    end
    parsed_lines[#parsed_lines + 1] = normalized_line
    if normalized_line.has_corrected_timing then
      aligned_count = aligned_count + 1
    else
      fallback_count = fallback_count + 1
    end
    if trim(normalized_line.corrected_timing_issue_kind) ~= "" then
      corrected_timing_issue_count = corrected_timing_issue_count + 1
      warnings[#warnings + 1] = normalized_line.corrected_timing_issue_text
    end
    local status_key = normalized_line.status ~= "" and normalized_line.status or "(empty)"
    status_counts[status_key] = (status_counts[status_key] or 0) + 1
  end

  local no_used_segments_count = 0
  if decoded.no_used_segments ~= nil then
    if not is_array_like(decoded.no_used_segments) then
      return nil, "Top-level `no_used_segments` field must be an array when present."
    end
    no_used_segments_count = #decoded.no_used_segments
  end

  return {
    raw = decoded,
    lines = parsed_lines,
    line_count = #parsed_lines,
    aligned_count = aligned_count,
    fallback_count = fallback_count,
    corrected_timing_issue_count = corrected_timing_issue_count,
    no_used_segments_count = no_used_segments_count,
    status_counts = status_counts,
    warning_count = #warnings,
    warnings = warnings
  }, nil
end

function NeurocastScriptAlignerResult.parse_result_json_text(json_text)
  if type(json_text) ~= "string" or json_text == "" then
    return nil, "Result JSON text must be a non-empty string."
  end

  local ok_decode, decoded_or_err = pcall(json.decode, json_text)
  if not ok_decode then
    return nil, "JSON decode failed: " .. tostring(decoded_or_err)
  end

  return NeurocastScriptAlignerResult.parse_result_table(decoded_or_err)
end

function NeurocastScriptAlignerResult.parse_result_file(path)
  local data, read_err = read_file(path)
  if not data then
    return nil, read_err
  end
  local parsed, parse_err = NeurocastScriptAlignerResult.parse_result_json_text(data)
  if not parsed then
    return nil, parse_err
  end
  parsed.source_path = tostring(path or "")
  return parsed, nil
end

function NeurocastScriptAlignerResult.build_import_rows(parsed_result, opts)
  if type(parsed_result) ~= "table" or type(parsed_result.lines) ~= "table" then
    return nil, "parsed_result.lines table is required"
  end

  local options = type(opts) == "table" and opts or {}
  local base_offset_sec = tonumber(options.base_offset_sec or 0) or 0
  local chars_per_second = tonumber(options.chars_per_second or 20) or 20
  local min_fallback_item_length_sec = tonumber(options.min_fallback_item_length_sec or 1.0) or 1.0

  if chars_per_second <= 0 then
    return nil, "chars_per_second must be greater than 0"
  end
  if min_fallback_item_length_sec <= 0 then
    return nil, "min_fallback_item_length_sec must be greater than 0"
  end

  local rows = {}
  for index = 1, #parsed_result.lines do
    local line = parsed_result.lines[index]
    local start_seconds = nil
    local length_seconds = nil
    local timing_source = nil
    local fallback_length = build_fallback_length_seconds(
      line.original_text,
      chars_per_second,
      min_fallback_item_length_sec
    )

    if line.has_corrected_timing then
      start_seconds = base_offset_sec + line.corrected_start_time_sec
      length_seconds = line.corrected_end_time_sec - line.corrected_start_time_sec
      timing_source = "corrected"
    else
      local preferred_start_time_sec = line.original_start_time_sec
      if trim(line.corrected_timing_issue_kind) ~= "" and type(line.corrected_start_time_sec) == "number" and line.corrected_start_time_sec >= 0 then
        preferred_start_time_sec = line.corrected_start_time_sec
        timing_source = "corrected_start_fallback_length"
      else
        timing_source = "fallback_original"
      end
      start_seconds = base_offset_sec + preferred_start_time_sec
      length_seconds = fallback_length
    end

    rows[#rows + 1] = {
      source_index = line.source_index,
      track_name = line.character_name,
      note_text = line.original_text,
      start_seconds = start_seconds,
      length_seconds = length_seconds,
      timing_source = timing_source,
      original_start_time_sec = line.original_start_time_sec,
      corrected_start_time_sec = line.corrected_start_time_sec,
      corrected_end_time_sec = line.corrected_end_time_sec,
      corrected_timing_issue_kind = line.corrected_timing_issue_kind,
      corrected_timing_issue_text = line.corrected_timing_issue_text,
      warning_marker_name = line.corrected_timing_marker_name,
      warning_marker_position_seconds = trim(line.corrected_timing_issue_kind) ~= "" and start_seconds or nil,
      item_color_rgb = build_legacy_item_color_rgb(line),
      status = line.status,
      original_line_number = line.original_line_number
    }
  end

  table.sort(rows, function(left, right)
    if left.start_seconds ~= right.start_seconds then
      return left.start_seconds < right.start_seconds
    end
    return (left.source_index or 0) < (right.source_index or 0)
  end)

  return rows, nil
end

return NeurocastScriptAlignerResult
