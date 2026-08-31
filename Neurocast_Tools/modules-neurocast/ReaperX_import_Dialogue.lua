-- REAPER-facing dialogue import facade for DOCX workflow rows.
-- Public API:
--   ReaperX_import_Dialogue.preflight_import(rows, settings)
--   ReaperX_import_Dialogue.apply_import(rows, settings)

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local ReaperX_import_Dialogue = {}
local track_colors = require("modules-neurocast.track_colors")
local REQUIRED_REAPER_VERSION = "7.66+"

local function assert_required_api_functions()
  local required_functions = {
    "ValidatePtr2",
    "CountTracks",
    "GetTrack",
    "GetTrackName",
    "CountTrackMediaItems",
    "GetTrackMediaItem",
    "GetMediaItemInfo_Value",
    "InsertTrackInProject",
    "GetSetMediaTrackInfo_String",
    "GetMediaTrackInfo_Value",
    "SetMediaTrackInfo_Value",
    "AddMediaItemToTrack",
    "SetMediaItemInfo_Value",
    "GetSetMediaItemInfo_String",
    "UpdateItemInProject",
    "AddProjectMarker",
    "Undo_BeginBlock2",
    "PreventUIRefresh",
    "SetTrackColor",
    "ColorToNative",
    "Undo_EndBlock2",
    "TrackList_AdjustWindows",
    "UpdateArrange"
  }

  for i = 1, #required_functions do
    local name = required_functions[i]
    if type(r[name]) ~= "function" then
      error(string.format("ReaScrip function now found: `%s`; Likely need to update Reaper, version needed: %s.", name, REQUIRED_REAPER_VERSION))
    end
  end
end

assert_required_api_functions()

local DEFAULT_SETTINGS = {
  layout_mode = "single_track",
  single_track_name = "Dialogue_Import",
  reuse_existing_tracks = true,
  apply_color_policy = false,
  prepend_character_name = false,
  create_rec_track = false,
  alt_take_track_count = 0,
  make_folders = false,
  folder_collapsed_state = "normal",
  use_source_end_timecodes = false,
  length_mode = "fixed",
  fixed_length_seconds = 3.0,
  chars_per_second = 15,
  overlap_policy = "allow",
  add_warning_markers = false,
  offset_enabled = false,
  offset_direction = "right",
  offset_hours = 0,
  offset_minutes = 0,
  offset_seconds = 0,
  too_short_seconds = 0.5,
  too_close_seconds = 0.2
}

local MIN_ITEM_LENGTH_SECONDS = 0.1
local ALT_TAKE_TRACK_HEIGHT_OVERRIDE = 33
local UNDO_LABEL = "Import DOCX Dialogue"
local UNKNOWN_CHARACTER_NAME = "Unknown"

local function t(text)
  if text == nil then return "" end
  if type(text) ~= "string" then return tostring(text) end
  return text
end

local function trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function utf8_length(text)
  local value = tostring(text or "")
  if utf8 and utf8.len then
    local ok, result = pcall(utf8.len, value)
    if ok and type(result) == "number" then
      return result
    end
  end
  return #value
end

local function to_number(value)
  local number = tonumber(value)
  if not number then
    return nil
  end
  return number
end

local function to_nonnegative_integer(value, default_value)
  local number = tonumber(value)
  if not number then
    return default_value
  end
  return math.max(0, math.floor(number))
end

local function normalize_folder_collapsed_state(value)
  local collapsed_state = trim(value)
  if collapsed_state == "collapsed" then
    return "collapsed"
  end
  if collapsed_state == "fully_collapsed" then
    return "fully_collapsed"
  end
  return "normal"
end

local function bool_or_default(value, default_value)
  if value == nil then
    return default_value == true
  end
  return value == true
end

local function shallow_copy(map_in)
  local out = {}
  for key, value in pairs(map_in or {}) do
    out[key] = value
  end
  return out
end

local function append_message(list_ref, message)
  local text = trim(message)
  if text == "" then
    return
  end
  list_ref[#list_ref + 1] = text
end

local function validate_track_pointer(track)
  if not track then
    return false
  end
  return r.ValidatePtr2(0, track, "MediaTrack*") == true
end

local function format_project_timecode(seconds)
  if type(seconds) ~= "number" then
    return ""
  end
  if type(r.format_timestr_pos) ~= "function" then
    return ""
  end
  return trim(tostring(r.format_timestr_pos(seconds, "", 5) or ""))
end

local function display_timecode(seconds)
  local timecode = format_project_timecode(seconds)
  if timecode ~= "" then
    return timecode
  end
  return t("(no timecode)")
end

local function display_row_id(row_key, source_row_index, fallback_index)
  local source_text = trim(source_row_index)
  if source_text ~= "" then
    return source_text
  end

  local key = trim(row_key)
  if key ~= "" then
    local suffix = key:match("^[^:]+:(.+)$")
    if trim(suffix) ~= "" then
      return trim(suffix)
    end
    return key
  end

  return tostring(fallback_index or "?")
end

local function row_problem_message(row_key, source_row_index, fallback_index, seconds, reason)
  local row_id = display_row_id(row_key, source_row_index, fallback_index)
  local timecode = format_project_timecode(seconds)
  if timecode ~= "" then
    return string.format(t("Row %s at %s cannot be imported: %s."), row_id, timecode, reason)
  end
  return string.format(t("Row %s (no timecode): %s."), row_id, reason)
end

local function friendly_setting_blocker(text)
  local value = trim(text)
  if value == "" then
    return t("Preflight cannot continue.")
  end
  return string.format(t("Preflight cannot continue: %s"), value)
end

local function apply_offset_to_seconds(source_seconds, settings)
  local original = tonumber(source_seconds)
  if original == nil then
    return nil, "", false
  end

  local effective_seconds = original
  local offset_seconds = tonumber(settings and settings.offset_seconds) or 0
  if settings and settings.offset_enabled == true and offset_seconds > 0 then
    if settings.offset_direction == "left" then
      effective_seconds = original - offset_seconds
    else
      effective_seconds = original + offset_seconds
    end
  end

  local clamped = false
  if effective_seconds < 0 then
    effective_seconds = 0
    clamped = true
  end

  return effective_seconds, format_project_timecode(effective_seconds), clamped
end

local function apply_offset_to_source_span(start_seconds, end_seconds, settings)
  local source_start = tonumber(start_seconds)
  local source_end = tonumber(end_seconds)
  if source_start == nil or source_end == nil then
    return nil, nil, "", "", false
  end

  local duration = source_end - source_start
  local shifted_start = source_start
  local shifted_end = source_end
  local offset_seconds = tonumber(settings and settings.offset_seconds) or 0
  if settings and settings.offset_enabled == true and offset_seconds > 0 then
    if settings.offset_direction == "left" then
      shifted_start = source_start - offset_seconds
      shifted_end = source_end - offset_seconds
    else
      shifted_start = source_start + offset_seconds
      shifted_end = source_end + offset_seconds
    end
  end

  local clamped = false
  if shifted_start < 0 then
    shifted_start = 0
    shifted_end = duration
    clamped = true
  elseif shifted_end < 0 then
    shifted_end = 0
    clamped = true
  end

  return shifted_start, shifted_end, format_project_timecode(shifted_start), format_project_timecode(shifted_end), clamped
end

local function normalize_settings(settings_in)
  local settings = shallow_copy(DEFAULT_SETTINGS)
  for key, value in pairs(settings_in or {}) do
    settings[key] = value
  end

  settings.layout_mode = trim(settings.layout_mode)
  settings.single_track_name = trim(settings.single_track_name)
  if settings.single_track_name == "" then
    settings.single_track_name = DEFAULT_SETTINGS.single_track_name
  end

  settings.reuse_existing_tracks = bool_or_default(settings.reuse_existing_tracks, DEFAULT_SETTINGS.reuse_existing_tracks)
  settings.apply_color_policy = bool_or_default(settings.apply_color_policy, DEFAULT_SETTINGS.apply_color_policy)
  settings.prepend_character_name = bool_or_default(settings.prepend_character_name, DEFAULT_SETTINGS.prepend_character_name)
  settings.create_rec_track = bool_or_default(settings.create_rec_track, DEFAULT_SETTINGS.create_rec_track)
  settings.alt_take_track_count = to_nonnegative_integer(settings.alt_take_track_count, DEFAULT_SETTINGS.alt_take_track_count)
  settings.make_folders = bool_or_default(settings.make_folders, DEFAULT_SETTINGS.make_folders)
  settings.folder_collapsed_state = normalize_folder_collapsed_state(settings.folder_collapsed_state)
  settings.use_source_end_timecodes = bool_or_default(settings.use_source_end_timecodes, DEFAULT_SETTINGS.use_source_end_timecodes)
  settings.length_mode = trim(settings.length_mode)
  settings.fixed_length_seconds = to_number(settings.fixed_length_seconds) or DEFAULT_SETTINGS.fixed_length_seconds
  settings.chars_per_second = to_number(settings.chars_per_second) or DEFAULT_SETTINGS.chars_per_second
  settings.overlap_policy = trim(settings.overlap_policy)
  settings.add_warning_markers = bool_or_default(settings.add_warning_markers, DEFAULT_SETTINGS.add_warning_markers)
  settings.offset_enabled = bool_or_default(settings.offset_enabled, DEFAULT_SETTINGS.offset_enabled)
  settings.offset_direction = trim(settings.offset_direction)
  settings.offset_hours = to_nonnegative_integer(settings.offset_hours, DEFAULT_SETTINGS.offset_hours)
  settings.offset_minutes = to_nonnegative_integer(settings.offset_minutes, DEFAULT_SETTINGS.offset_minutes)
  settings.offset_seconds = to_number(settings.offset_seconds) or DEFAULT_SETTINGS.offset_seconds
  settings.too_short_seconds = to_number(settings.too_short_seconds) or DEFAULT_SETTINGS.too_short_seconds
  settings.too_close_seconds = to_number(settings.too_close_seconds) or DEFAULT_SETTINGS.too_close_seconds
  if settings.layout_mode ~= "dedicated_tracks" or settings.create_rec_track ~= true then
    settings.make_folders = false
  end
  if settings.use_source_end_timecodes == true then
    settings.overlap_policy = "allow"
  end

  return settings
end

local function validate_settings(settings)
  local blockers = {}

  if settings.layout_mode ~= "single_track" and settings.layout_mode ~= "dedicated_tracks" then
    append_message(blockers, friendly_setting_blocker(t("the selected import layout is not supported.")))
  end
  if settings.use_source_end_timecodes ~= true
    and settings.length_mode ~= "fixed"
    and settings.length_mode ~= "chars_per_second"
  then
    append_message(blockers, friendly_setting_blocker(t("the selected timing mode is not supported.")))
  end
  if settings.use_source_end_timecodes ~= true
    and settings.overlap_policy ~= "allow"
    and settings.overlap_policy ~= "shrink_to_fit_best_effort"
  then
    append_message(blockers, friendly_setting_blocker(t("the selected overlap policy is not supported.")))
  end
  if settings.offset_direction ~= "left" and settings.offset_direction ~= "right" then
    append_message(blockers, friendly_setting_blocker(t("the selected offset direction is not supported.")))
  end
  if settings.offset_hours == nil or settings.offset_hours < 0 then
    append_message(blockers, friendly_setting_blocker(t("offset hours must be 0 or greater.")))
  end
  if settings.offset_minutes == nil or settings.offset_minutes < 0 then
    append_message(blockers, friendly_setting_blocker(t("offset minutes must be 0 or greater.")))
  end
  if settings.offset_seconds == nil or settings.offset_seconds < 0 then
    append_message(blockers, friendly_setting_blocker(t("the import offset must be 0 seconds or greater.")))
  end
  if settings.use_source_end_timecodes ~= true and (settings.fixed_length_seconds == nil or settings.fixed_length_seconds <= 0) then
    append_message(blockers, friendly_setting_blocker(t("fixed item length must be greater than 0 seconds.")))
  end
  if settings.use_source_end_timecodes ~= true and (settings.chars_per_second == nil or settings.chars_per_second <= 0) then
    append_message(blockers, friendly_setting_blocker(t("chars per second must be greater than 0.")))
  end
  if settings.use_source_end_timecodes ~= true and (settings.too_short_seconds == nil or settings.too_short_seconds < 0) then
    append_message(blockers, friendly_setting_blocker(t("the too-short threshold must be 0 seconds or greater.")))
  end
  if settings.too_close_seconds == nil or settings.too_close_seconds < 0 then
    append_message(blockers, friendly_setting_blocker(t("the too-close threshold must be 0 seconds or greater.")))
  end
  if settings.layout_mode == "single_track" and trim(settings.single_track_name) == "" then
    append_message(blockers, friendly_setting_blocker(t("the shared dialogue track name is empty.")))
  end
  if settings.alt_take_track_count == nil or settings.alt_take_track_count < 0 then
    append_message(blockers, friendly_setting_blocker(t("alt-take track count must be 0 or greater.")))
  end
  if settings.layout_mode == "dedicated_tracks"
    and settings.alt_take_track_count > 0
    and settings.create_rec_track ~= true then
    append_message(blockers, friendly_setting_blocker(t("alt-take tracks require REC track creation in Path B.")))
  end

  return blockers
end

local function resolve_character_name(row)
  local canonical_name = trim(row and row.canonical_name or "")
  if canonical_name ~= "" then
    return canonical_name
  end
  local raw_name = trim(row and row.raw_character_name or "")
  if raw_name ~= "" then
    return raw_name
  end
  return ""
end

local function resolve_character_color_key(row)
  local character_name = resolve_character_name(row)
  if character_name ~= "" then
    return character_name
  end
  return UNKNOWN_CHARACTER_NAME
end

local function resolve_track_name(row, settings)
  if settings.layout_mode == "single_track" then
    return settings.single_track_name
  end
  local name = resolve_character_name(row)
  if name == "" then
    return UNKNOWN_CHARACTER_NAME
  end
  return name
end

local function format_item_text(row, settings)
  local dialogue = tostring((row and row.dialogue) or "")
  if settings.layout_mode ~= "single_track" or settings.prepend_character_name ~= true then
    return dialogue
  end

  local character_name = resolve_character_name(row)
  if character_name == "" then
    return dialogue
  end
  if dialogue == "" then
    return string.format("[%s]", character_name)
  end
  return string.format("[%s] %s", character_name, dialogue)
end

local function compute_base_length_seconds(dialogue, settings)
  if settings.length_mode == "fixed" then
    return settings.fixed_length_seconds
  end

  local cps_floor = math.max(
    MIN_ITEM_LENGTH_SECONDS,
    tonumber(settings and settings.too_short_seconds) or MIN_ITEM_LENGTH_SECONDS
  )
  local guessed = utf8_length(dialogue) / settings.chars_per_second
  if guessed < cps_floor then
    return cps_floor
  end
  return guessed
end

local function build_target_plan_key(role, dialogue_track_name, alt_take_index)
  if role == "dialogue" then
    return "dialogue:" .. tostring(dialogue_track_name or "")
  end
  if role == "rec" then
    return "rec:" .. tostring(dialogue_track_name or "")
  end
  return string.format("alt:%s:%s", tostring(dialogue_track_name or ""), tostring(alt_take_index or 0))
end

local function build_rec_track_name(dialogue_track_name)
  return "REC_" .. tostring(dialogue_track_name or "")
end

local function build_alt_take_track_name(dialogue_track_name, alt_take_index)
  return string.format("Alt_Takes_%02d_%s", alt_take_index or 0, tostring(dialogue_track_name or ""))
end

local function role_label_for_message(role)
  if role == "dialogue" then
    return "dialogue track"
  end
  if role == "rec" then
    return "REC track"
  end
  if role == "alt_take" then
    return "alt-take track"
  end
  return "track"
end

local function build_track_lookup()
  local by_name = {}
  local GetTrack = r.GetTrack
  local GetTrackName = r.GetTrackName
  local track_count = r.CountTracks(0)
  for track_index = 0, track_count - 1 do
    local track = GetTrack(0, track_index)
    if track and validate_track_pointer(track) then
      local _, track_name = GetTrackName(track)
      local trimmed_name = trim(track_name)
      by_name[trimmed_name] = by_name[trimmed_name] or {}
      by_name[trimmed_name][#by_name[trimmed_name] + 1] = track
    end
  end
  return by_name
end

local function track_has_item_in_span(track, span_start, span_end)
  if not validate_track_pointer(track) then
    return false
  end

  local GetTrackMediaItem = r.GetTrackMediaItem
  local GetMediaItemInfo_Value = r.GetMediaItemInfo_Value
  local item_count = r.CountTrackMediaItems(track)
  for item_index = 0, item_count - 1 do
    local item = GetTrackMediaItem(track, item_index)
    if item then
      local position = GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end = position + GetMediaItemInfo_Value(item, "D_LENGTH")
      if item_end >= span_start and position <= span_end then
        return true
      end
    end
  end

  return false
end

local function create_track_at_index(track_name, insert_index)
  local track_count = r.CountTracks(0)
  local safe_index = to_nonnegative_integer(insert_index, track_count)
  if safe_index > track_count then
    safe_index = track_count
  end

  r.InsertTrackInProject(0, safe_index, 0)
  local track = r.GetTrack(0, safe_index)
  if not validate_track_pointer(track) then
    return false, t("Failed to create destination track."), nil
  end

  local ok_name = r.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(track_name or ""), true)
  if ok_name ~= true then
    return false, string.format(t("Failed to set destination track name: %s"), tostring(track_name or "")), nil
  end

  return true, nil, track
end

local function create_track_at_end(track_name)
  return create_track_at_index(track_name, r.CountTracks(0))
end

local function create_track_after(anchor_track, track_name)
  if not validate_track_pointer(anchor_track) then
    return create_track_at_end(track_name)
  end

  local track_number = r.GetMediaTrackInfo_Value(anchor_track, "IP_TRACKNUMBER")
  if track_number < 1 then
    return create_track_at_end(track_name)
  end

  return create_track_at_index(track_name, math.floor(track_number))
end

local function set_track_muted(track, muted)
  if not validate_track_pointer(track) then
    return false, t("Invalid destination track.")
  end

  r.SetMediaTrackInfo_Value(track, "B_MUTE", muted and 1 or 0)
  return true, nil
end

local function set_track_height_override(track, height)
  if not validate_track_pointer(track) then
    return false, t("Invalid destination track.")
  end

  r.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", tonumber(height) or 0)
  return true, nil
end

local function set_track_folder_depth(track, depth)
  if not validate_track_pointer(track) then
    return false, t("Invalid destination track.")
  end

  r.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", tonumber(depth) or 0)
  return true, nil
end

local function folder_compact_state_to_number(collapsed_state)
  local normalized = normalize_folder_collapsed_state(collapsed_state)
  if normalized == "collapsed" then
    return 1
  end
  if normalized == "fully_collapsed" then
    return 2
  end
  return 0
end

local function set_track_folder_compact(track, collapsed_state)
  if not validate_track_pointer(track) then
    return false, t("Invalid destination track.")
  end

  r.SetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT", folder_compact_state_to_number(collapsed_state))
  return true, nil
end

local function create_text_item(track, text, position, length)
  if not validate_track_pointer(track) then
    return false, t("Invalid destination track."), nil
  end

  local item = r.AddMediaItemToTrack(track)
  if not item then
    return false, t("Failed to create destination media item."), nil
  end

  r.SetMediaItemInfo_Value(item, "D_POSITION", position)
  r.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  local ok_notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", tostring(text or ""), true)
  if ok_notes ~= true then
    return false, t("Failed to write destination item notes."), nil
  end

  r.UpdateItemInProject(item)

  return true, nil, item
end

local function add_warning_marker(position, name)
  if type(position) ~= "number" then
    return false, t("Marker position is not a number.")
  end
  local marker_index = r.AddProjectMarker(0, false, position, 0, tostring(name or ""), -1)
  if type(marker_index) ~= "number" or marker_index < 0 then
    return false, string.format(t("Failed to create project marker: %s"), tostring(name or ""))
  end
  return true, nil
end

local function default_row_label(item)
  local name = trim(item.character_name or "")
  if name ~= "" then
    return name
  end
  return trim(item.track_name or "")
end

local function build_marker_name(kind, item, extra)
  local label = default_row_label(item)
  if label == "" then
    label = tostring(item.row_key or item.input_index or "?")
  end

  if kind == "empty_dialogue" then
    return string.format("! EMPTY DIALOGUE: %s", label)
  end
  if kind == "too_short" then
    return string.format("%s: too short", label)
  end
  if kind == "too_close" then
    return string.format("%s: too close", label)
  end
  if kind == "overlap" then
    return string.format("! OVERLAP: %s", tostring(extra or label))
  end
  if kind == "shrunk" then
    return string.format("! SHRUNK ITEM: %s", label)
  end
  return string.format("! WARNING: %s", label)
end

local function sort_items_for_track(items)
  table.sort(items, function(left, right)
    if left.start_seconds == right.start_seconds then
      return left.input_index < right.input_index
    end
    return left.start_seconds < right.start_seconds
  end)
end

local function resolve_target_for_preflight(track_name, role, dialogue_track_name, alt_take_index, character_color_key, settings, track_lookup, span_start, span_end, report)
  local matches = track_lookup[track_name] or {}
  local action = "create"
  local existing_track = nil
  local allow_reuse = false

  if settings.layout_mode == "dedicated_tracks" and settings.reuse_existing_tracks == true then
    allow_reuse = true
  end

  if allow_reuse then
    if #matches > 1 then
      if settings.layout_mode == "single_track" and role == "dialogue" then
        append_message(
          report.blockers,
          string.format(t("Preflight cannot continue: more than one track named \"%s\" matches the shared dialogue target."), track_name)
        )
      else
        append_message(
          report.blockers,
          string.format(
            t("Preflight cannot continue: more than one track named \"%s\" matches the %s target."),
            track_name,
            role_label_for_message(role)
          )
        )
      end
    elseif #matches == 1 then
      action = "reuse"
      existing_track = matches[1]
    end
  end

  local has_existing_items_in_span = false
  if role == "dialogue" and action == "reuse" and existing_track and span_start ~= nil and span_end ~= nil then
    has_existing_items_in_span = track_has_item_in_span(existing_track, span_start, span_end)
    if has_existing_items_in_span then
      append_message(report.warnings, string.format(
        t("Track %s already has items in the import span %s -> %s."),
        track_name,
        display_timecode(span_start),
        display_timecode(span_end)
      ))
    end
  end

  return {
    plan_key = build_target_plan_key(role, dialogue_track_name, alt_take_index),
    track_name = track_name,
    dialogue_track_name = dialogue_track_name,
    character_color_key = tostring(character_color_key or UNKNOWN_CHARACTER_NAME),
    role = role,
    alt_take_index = alt_take_index,
    action = action,
    existing_match_count = #matches,
    has_existing_items_in_span = has_existing_items_in_span,
    existing_items_in_span_count = has_existing_items_in_span and 1 or 0,
    _track_pointer = existing_track
  }
end

local function build_preflight(rows_in, settings_in)
  local report = {
    settings = normalize_settings(settings_in),
    summary = {
      row_count = 0,
      item_count = 0,
      marker_count = 0,
      create_track_count = 0,
      reuse_track_count = 0,
      existing_items_in_span_count = 0
    },
    warnings = {},
    blockers = {},
    track_plan = {
      mode = nil,
      targets = {}
    },
    folder_plan = {
      enabled = false,
      groups = {}
    },
    item_plan = {},
    marker_plan = {},
    time_span = {
      start_seconds = nil,
      end_seconds = nil,
      duration_seconds = 0,
      start_timecode = "",
      end_timecode = ""
    }
  }

  local settings = report.settings
  report.track_plan.mode = settings.layout_mode
  report.folder_plan.enabled = settings.make_folders == true

  local setting_blockers = validate_settings(settings)
  for i = 1, #setting_blockers do
    append_message(report.blockers, setting_blockers[i])
  end

  if type(rows_in) ~= "table" or #rows_in == 0 then
    append_message(report.blockers, friendly_setting_blocker(t("there are no import-ready rows.")))
    return false, report
  end

  local dialogue_tracks_in_order = {}
  local dialogue_tracks_seen = {}
  local dialogue_track_color_keys = {}

  for input_index = 1, #rows_in do
    local row = rows_in[input_index] or {}
    local row_key = trim(row.row_key or "")
    if row_key == "" then
      row_key = "row:" .. tostring(input_index)
    end

    if trim(row.status or "") == "bad" then
      append_message(
        report.blockers,
        row_problem_message(row_key, row.source_row_index, input_index, row.raw_seconds, t("it is still marked bad"))
      )
    end

    local raw_seconds = to_number(row.raw_seconds)
    local end_raw_seconds = to_number(row.end_raw_seconds)
    if raw_seconds == nil then
      append_message(
        report.blockers,
        row_problem_message(row_key, row.source_row_index, input_index, nil, t("it has no usable timecode"))
      )
    elseif raw_seconds < 0 then
      append_message(
        report.blockers,
        row_problem_message(row_key, row.source_row_index, input_index, nil, t("its timecode is negative"))
      )
    end
    if settings.use_source_end_timecodes == true then
      if end_raw_seconds == nil then
        append_message(
          report.blockers,
          row_problem_message(row_key, row.source_row_index, input_index, nil, t("it has no usable end timecode"))
        )
      elseif raw_seconds ~= nil and end_raw_seconds < raw_seconds then
        append_message(
          report.blockers,
          row_problem_message(row_key, row.source_row_index, input_index, raw_seconds, t("its end timecode is earlier than its start timecode"))
        )
      elseif raw_seconds ~= nil and end_raw_seconds == raw_seconds then
        append_message(
          report.blockers,
          row_problem_message(row_key, row.source_row_index, input_index, raw_seconds, t("its source duration is zero"))
        )
      end
    end

    local track_name = resolve_track_name(row, settings)
    if not dialogue_tracks_seen[track_name] then
      dialogue_tracks_seen[track_name] = true
      dialogue_tracks_in_order[#dialogue_tracks_in_order + 1] = track_name
      dialogue_track_color_keys[track_name] = resolve_character_color_key(row)
    end

    local dialogue = tostring(row.dialogue or "")
    local empty_dialogue = trim(dialogue) == ""
    local shifted_seconds = nil
    local shifted_end_seconds = nil
    local shifted_timecode = ""
    local shifted_end_timecode = ""
    local was_clamped = false
    local base_length = nil
    if settings.use_source_end_timecodes == true then
      shifted_seconds, shifted_end_seconds, shifted_timecode, shifted_end_timecode, was_clamped =
        apply_offset_to_source_span(raw_seconds, end_raw_seconds, settings)
      if type(raw_seconds) == "number" and type(end_raw_seconds) == "number" then
        base_length = end_raw_seconds - raw_seconds
      else
        base_length = 0
      end
    else
      base_length = compute_base_length_seconds(dialogue, settings)
      if base_length < MIN_ITEM_LENGTH_SECONDS then
        base_length = MIN_ITEM_LENGTH_SECONDS
      end
      shifted_seconds, shifted_timecode, was_clamped = apply_offset_to_seconds(raw_seconds, settings)
      shifted_end_seconds = shifted_seconds and (shifted_seconds + base_length) or nil
      shifted_end_timecode = format_project_timecode(shifted_end_seconds)
    end
    if was_clamped then
      append_message(
        report.warnings,
        string.format(
          t("Item at %s was shifted before 00:00:00:00 and will be clamped to 00:00:00:00."),
          display_timecode(raw_seconds)
        )
      )
    end

    report.item_plan[#report.item_plan + 1] = {
      input_index = input_index,
      row_key = row_key,
      source_row_index = row.source_row_index,
      source_start_seconds = raw_seconds,
      source_end_seconds = end_raw_seconds,
      source_timecode = format_project_timecode(raw_seconds),
      source_end_timecode = format_project_timecode(end_raw_seconds),
      start_seconds = shifted_seconds,
      track_name = track_name,
      character_name = resolve_character_name(row),
      note_text = format_item_text(row, settings),
      dialogue = dialogue,
      base_length_seconds = base_length,
      effective_length_seconds = base_length,
      effective_end_seconds = shifted_end_seconds,
      start_timecode = shifted_timecode,
      end_timecode = shifted_end_timecode,
      normalized_timecode = tostring(row.normalized_timecode or ""),
      normalized_end_timecode = tostring(row.normalized_end_timecode or ""),
      original_timecode = tostring(row.original_timecode or ""),
      original_end_timecode = tostring(row.original_end_timecode or ""),
      status = tostring(row.status or ""),
      validation_message = tostring(row.validation_message or ""),
      offset_was_clamped = was_clamped == true,
      empty_dialogue = empty_dialogue,
      too_short = false,
      too_close = false,
      closest_too_close_row_key = nil,
      closest_too_close_delta_seconds = nil,
      closest_too_close_start_seconds = nil,
      overlap_next = false,
      shrunk_to_fit = false,
      next_gap_seconds = nil
    }
  end

  report.summary.row_count = #report.item_plan
  report.summary.item_count = #report.item_plan

  if #report.blockers > 0 then
    return false, report
  end

  -- Reused-track occupancy inspection intentionally follows the caller's
  -- original row order: first row raw_seconds -> last row raw_seconds.
  -- We do not normalize inverted spans because the source order itself is the
  -- signal the user asked to preserve, but we warn when that order looks odd.
  local span_start = report.item_plan[1] and report.item_plan[1].start_seconds or nil
  local last_item = report.item_plan[#report.item_plan] or nil
  local span_end = last_item and (last_item.effective_end_seconds or last_item.start_seconds) or nil
  report.time_span.start_seconds = span_start
  report.time_span.end_seconds = span_end
  report.time_span.duration_seconds = (span_start ~= nil and span_end ~= nil) and (span_end - span_start) or 0
  report.time_span.start_timecode = format_project_timecode(span_start)
  report.time_span.end_timecode = format_project_timecode(span_end)
  if span_start ~= nil and span_end ~= nil and span_start > span_end then
    append_message(
      report.warnings,
      string.format(
        t("Import order looks reversed: the first item is at %s and the last item is at %s. Reused-track span checks may be unreliable."),
        report.time_span.start_timecode ~= "" and report.time_span.start_timecode or t("(n/a)"),
        report.time_span.end_timecode ~= "" and report.time_span.end_timecode or t("(n/a)")
      )
    )
  end

  local track_lookup = {}
  if settings.layout_mode == "dedicated_tracks" and settings.reuse_existing_tracks == true then
    track_lookup = build_track_lookup()
  end
  for i = 1, #dialogue_tracks_in_order do
    local dialogue_track_name = dialogue_tracks_in_order[i]
    local character_color_key = dialogue_track_color_keys[dialogue_track_name] or UNKNOWN_CHARACTER_NAME
    local character_targets = {}
    local dialogue_target = resolve_target_for_preflight(
      dialogue_track_name,
      "dialogue",
      dialogue_track_name,
      nil,
      character_color_key,
      settings,
      track_lookup,
      span_start,
      span_end,
      report
    )
    report.track_plan.targets[#report.track_plan.targets + 1] = dialogue_target
    character_targets[#character_targets + 1] = dialogue_target

    if settings.layout_mode == "dedicated_tracks" and settings.create_rec_track == true then
      local rec_target = resolve_target_for_preflight(
        build_rec_track_name(dialogue_track_name),
        "rec",
        dialogue_track_name,
        nil,
        character_color_key,
        settings,
        track_lookup,
        span_start,
        span_end,
        report
      )
      report.track_plan.targets[#report.track_plan.targets + 1] = rec_target
      character_targets[#character_targets + 1] = rec_target
      local folder_last_target = rec_target

      for alt_take_index = 1, settings.alt_take_track_count do
        local alt_take_target = resolve_target_for_preflight(
          build_alt_take_track_name(dialogue_track_name, alt_take_index),
          "alt_take",
          dialogue_track_name,
          alt_take_index,
          character_color_key,
          settings,
          track_lookup,
          span_start,
          span_end,
          report
        )
        report.track_plan.targets[#report.track_plan.targets + 1] = alt_take_target
        character_targets[#character_targets + 1] = alt_take_target
        folder_last_target = alt_take_target
      end

      if settings.make_folders == true and folder_last_target ~= nil then
        local group_has_reuse = false
        local group_all_created = true
        for target_index = 1, #character_targets do
          local target = character_targets[target_index]
          if target.action == "reuse" then
            group_has_reuse = true
          end
          if target.action ~= "create" then
            group_all_created = false
          end
        end

        report.folder_plan.groups[#report.folder_plan.groups + 1] = {
          dialogue_track_name = dialogue_track_name,
          first_track_name = dialogue_target.track_name,
          last_track_name = folder_last_target.track_name,
          first_plan_key = dialogue_target.plan_key,
          last_plan_key = folder_last_target.plan_key,
          collapsed_state = settings.folder_collapsed_state,
          enabled = group_all_created == true,
          skipped_due_to_reuse = group_has_reuse == true
        }

        if group_has_reuse then
          append_message(
            report.warnings,
            string.format(
              t("Folder creation for %s will be skipped because one or more Path B tracks for this character will be reused."),
              dialogue_track_name
            )
          )
        end
      end
    end
  end

  if #report.blockers > 0 then
    return false, report
  end

  local item_groups = {}
  for i = 1, #report.item_plan do
    local item = report.item_plan[i]
    item_groups[item.track_name] = item_groups[item.track_name] or {}
    item_groups[item.track_name][#item_groups[item.track_name] + 1] = item
  end

  local function register_too_close_pair(item, other_item, delta_seconds)
    if type(delta_seconds) ~= "number" then
      return
    end

    item.too_close = true
    if item.closest_too_close_delta_seconds == nil
      or delta_seconds < item.closest_too_close_delta_seconds
      or (
        delta_seconds == item.closest_too_close_delta_seconds
        and tostring(other_item.row_key or "") < tostring(item.closest_too_close_row_key or "")
      ) then
      item.closest_too_close_row_key = other_item.row_key
      item.closest_too_close_delta_seconds = delta_seconds
      item.closest_too_close_start_seconds = other_item.start_seconds
    end
  end

  for track_name, items in pairs(item_groups) do
    sort_items_for_track(items)
    for i = 1, #items do
      local item = items[i]
      local next_item = items[i + 1]
      if next_item then
        local start_distance_to_next = next_item.start_seconds - item.start_seconds
        local available_gap = start_distance_to_next
        if settings.use_source_end_timecodes ~= true
          and settings.overlap_policy == "shrink_to_fit_best_effort"
          and item.effective_length_seconds > available_gap
        then
          local shrink_floor = math.max(
            MIN_ITEM_LENGTH_SECONDS,
            tonumber(settings.too_short_seconds) or MIN_ITEM_LENGTH_SECONDS
          )
          local shrunk_length = math.max(shrink_floor, available_gap)
          if available_gap <= shrink_floor then
            shrunk_length = shrink_floor
          end
          if shrunk_length < item.effective_length_seconds then
            item.effective_length_seconds = shrunk_length
            item.effective_end_seconds = item.start_seconds + shrunk_length
            item.shrunk_to_fit = true
          end
        end

        local gap_to_next = next_item.start_seconds - item.effective_end_seconds
        item.next_gap_seconds = gap_to_next

        if gap_to_next < 0 then
          item.overlap_next = true
          append_message(report.warnings, string.format(
            t("On track %s, item at %s overlaps the next item at %s."),
            track_name,
            display_timecode(item.start_seconds),
            display_timecode(next_item.start_seconds)
          ))
        end
      end

      if settings.use_source_end_timecodes ~= true and item.effective_length_seconds < settings.too_short_seconds then
        item.too_short = true
        append_message(report.warnings, string.format(
          t("Track %s: item at %s is too short (%.3fs)."),
          track_name,
          display_timecode(item.start_seconds),
          item.effective_length_seconds
        ))
      end

      if item.empty_dialogue == true then
        append_message(report.warnings, string.format(
          t("Track %s: item at %s has empty dialogue text."),
          track_name,
          display_timecode(item.start_seconds)
        ))
      end

      if item.shrunk_to_fit then
        append_message(report.warnings, string.format(
          t("Track %s: item at %s was shortened to fit (%.3fs)."),
          track_name,
          display_timecode(item.start_seconds),
          item.effective_length_seconds
        ))
      end
    end

    for i = 1, #items do
      local item = items[i]
      for j = i + 1, #items do
        local other_item = items[j]
        local start_distance = math.abs((other_item.start_seconds or 0) - (item.start_seconds or 0))
        if start_distance <= settings.too_close_seconds then
          register_too_close_pair(item, other_item, start_distance)
          register_too_close_pair(other_item, item, start_distance)
        end
      end
    end

    for i = 1, #items do
      local item = items[i]
      if item.too_close == true then
        append_message(report.warnings, string.format(
          t("On track %s, item at %s is too close to item at %s (start delta %.3fs)."),
          track_name,
          display_timecode(item.start_seconds),
          display_timecode(item.closest_too_close_start_seconds),
          item.closest_too_close_delta_seconds or 0
        ))
      end
    end
  end

  if settings.add_warning_markers == true then
    for i = 1, #report.item_plan do
      local item = report.item_plan[i]
      if item.empty_dialogue == true then
        report.marker_plan[#report.marker_plan + 1] = {
          kind = "empty_dialogue",
          position = item.start_seconds,
          name = build_marker_name("empty_dialogue", item),
          row_key = item.row_key,
          track_name = item.track_name
        }
      end

      if item.too_short then
        report.marker_plan[#report.marker_plan + 1] = {
          kind = "too_short",
          position = item.start_seconds,
          name = build_marker_name("too_short", item),
          row_key = item.row_key,
          track_name = item.track_name
        }
      end

      if item.too_close then
        report.marker_plan[#report.marker_plan + 1] = {
          kind = "too_close",
          position = item.start_seconds,
          name = build_marker_name("too_close", item),
          row_key = item.row_key,
          closest_too_close_row_key = item.closest_too_close_row_key,
          track_name = item.track_name
        }
      end
    end
  end

  local create_track_count = 0
  local reuse_track_count = 0
  local existing_items_in_span_count = 0
  for i = 1, #report.track_plan.targets do
    local target = report.track_plan.targets[i]
    if target.action == "create" then
      create_track_count = create_track_count + 1
    elseif target.action == "reuse" then
      reuse_track_count = reuse_track_count + 1
    end
    existing_items_in_span_count = existing_items_in_span_count + (target.existing_items_in_span_count or 0)
  end

  report.summary.create_track_count = create_track_count
  report.summary.reuse_track_count = reuse_track_count
  report.summary.existing_items_in_span_count = existing_items_in_span_count
  report.summary.marker_count = #report.marker_plan

  return true, report
end

local function build_apply_summary_message(report)
  local summary = report.summary or {}
  local track_total = (summary.create_track_count or 0) + (summary.reuse_track_count or 0)
  return string.format(
    t("Imported %d item(s) to %d track(s). Created %d, reused %d, markers %d."),
    summary.item_count or 0,
    track_total,
    summary.create_track_count or 0,
    summary.reuse_track_count or 0,
    summary.marker_count or 0
  )
end

function ReaperX_import_Dialogue.preflight_import(rows, settings)
  return build_preflight(rows, settings)
end

function ReaperX_import_Dialogue.apply_import(rows, settings)
  local ok_preflight, report = build_preflight(rows, settings)
  local ok_result = false
  local message_result = ""

  if not ok_preflight then
    local first_blocker = report.blockers and report.blockers[1] or t("Import preflight failed.")
    message_result = tostring(first_blocker)
  else
    local transaction_started = false
    local refresh_started = false
    r.Undo_BeginBlock2(0)
    transaction_started = true

    r.PreventUIRefresh(16)
    refresh_started = true

    local success, runtime_error = pcall(function()
      local SetTrackColor = r.SetTrackColor
      local ColorToNative = r.ColorToNative
      local dialogue_track_by_name = {}
      local local_anchor_by_dialogue = {}
      local track_by_plan_key = {}

      for i = 1, #report.track_plan.targets do
        local target = report.track_plan.targets[i]
        local track = nil
        if target.action == "reuse" then
          track = target._track_pointer
          if not validate_track_pointer(track) then
            error(string.format(t("Failed to reuse destination track '%s'."), tostring(target.track_name)))
          end
        else
          local ok_track = false
          local err_track = nil
          if target.role == "dialogue" then
            ok_track, err_track, track = create_track_at_end(target.track_name)
          else
            ok_track, err_track, track = create_track_after(local_anchor_by_dialogue[target.dialogue_track_name], target.track_name)
          end
          if not ok_track then
            error(tostring(err_track or t("Failed to create destination track.")))
          end
          if report.settings.layout_mode == "dedicated_tracks"
            and report.settings.apply_color_policy == true then
            local color = track_colors.get_color_for_name(target.character_color_key)
            SetTrackColor(track, ColorToNative(color.r, color.g, color.b))
          end
        end

        if target.role == "alt_take" then
          local ok_height, err_height = set_track_height_override(track, ALT_TAKE_TRACK_HEIGHT_OVERRIDE)
          if not ok_height then
            error(tostring(err_height or t("Failed to resize alt-take track.")))
          end

          local ok_mute, err_mute = set_track_muted(track, true)
          if not ok_mute then
            error(tostring(err_mute or t("Failed to mute alt-take track.")))
          end
        end

        if target.role == "dialogue" then
          dialogue_track_by_name[target.track_name] = track
          local_anchor_by_dialogue[target.dialogue_track_name] = track
        elseif target.action == "create" then
          local_anchor_by_dialogue[target.dialogue_track_name] = track
        end

        track_by_plan_key[target.plan_key] = track
      end

      if report.folder_plan and report.folder_plan.enabled == true then
        for i = 1, #(report.folder_plan.groups or {}) do
          local group = report.folder_plan.groups[i]
          if group and group.enabled == true then
            local first_track = track_by_plan_key[group.first_plan_key]
            local last_track = track_by_plan_key[group.last_plan_key]

            local ok_first_depth, err_first_depth = set_track_folder_depth(first_track, 1)
            if not ok_first_depth then
              error(tostring(err_first_depth or t("Failed to mark folder parent track.")))
            end

            local ok_first_compact, err_first_compact = set_track_folder_compact(first_track, group.collapsed_state)
            if not ok_first_compact then
              error(tostring(err_first_compact or t("Failed to set folder collapsed state.")))
            end

            local ok_last_depth, err_last_depth = set_track_folder_depth(last_track, -1)
            if not ok_last_depth then
              error(tostring(err_last_depth or t("Failed to mark folder end track.")))
            end
          end
        end
      end

      for i = 1, #report.item_plan do
        local item = report.item_plan[i]
        local track = dialogue_track_by_name[item.track_name]
        local ok_item, err_item = create_text_item(track, item.note_text, item.start_seconds, item.effective_length_seconds)
        if not ok_item then
          error(tostring(err_item or t("Failed to create destination item.")))
        end
      end

      if report.settings.add_warning_markers == true then
        for i = 1, #report.marker_plan do
          local marker = report.marker_plan[i]
          local ok_marker, err_marker = add_warning_marker(marker.position, marker.name)
          if not ok_marker then
            error(tostring(err_marker or t("Failed to create warning marker.")))
          end
        end
      end
    end)

    if refresh_started then
      r.PreventUIRefresh(-16)
    end

    if transaction_started then
      local undo_label = success and UNDO_LABEL or (UNDO_LABEL .. " (failed)")
      r.Undo_EndBlock2(0, undo_label, -1)
    end

    if success then
      ok_result = true
      message_result = build_apply_summary_message(report)
    else
      message_result = string.format(t("Import failed: %s"), tostring(runtime_error or t("unknown error")))
    end
  end

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()

  return ok_result, message_result, report
end

return ReaperX_import_Dialogue
