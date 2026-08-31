-- REAPER-facing helpers for Neurocast script-aligner workflow.
-- Public API:
--   NeurocastScriptAlignerReaper.validate_time_selection_input()
--   NeurocastScriptAlignerReaper.render_time_selection_to_temp(output_dir[, opts])
--   NeurocastScriptAlignerReaper.apply_import_rows(rows[, opts])

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Util = require("modules-neurocast.Util")
local Files = require("modules-neurocast.Files")

local NeurocastScriptAlignerReaper = {}

local FLAC16_RENDER_FORMAT = "Y2FsZhAAAAAIAAAA"
local REQUIRED_REAPER_VERSION = "7.66+"

local NUMERIC_RENDER_KEYS = {
  "RENDER_SETTINGS",
  "RENDER_BOUNDSFLAG",
  "RENDER_SRATE",
  "RENDER_STARTPOS",
  "RENDER_ENDPOS",
  "RENDER_CHANNELS",
  "RENDER_TAILFLAG",
  "PROJECT_SRATE_USE",
  "RENDER_ADDTOPROJ",
  "RENDER_NORMALIZE",
  "RENDER_FADEIN",
  "RENDER_FADEOUT",
  "RENDER_FADEINSHAPE",
  "RENDER_FADEOUTSHAPE"
}

local STRING_RENDER_KEYS = {
  "RENDER_FILE",
  "RENDER_PATTERN",
  "RENDER_FORMAT"
}

local function assert_required_api_functions()
  local required = {
    "ValidatePtr2",
    "CountTracks",
    "GetTrack",
    "GetTrackName",
    "InsertTrackInProject",
    "GetSetMediaTrackInfo_String",
    "AddProjectMarker",
    "AddMediaItemToTrack",
    "ColorToNative",
    "SetMediaItemInfo_Value",
    "GetSetMediaItemInfo_String",
    "UpdateItemInProject",
    "Undo_BeginBlock2",
    "Undo_EndBlock2",
    "PreventUIRefresh",
    "TrackList_AdjustWindows",
    "UpdateArrange",
    "GetSetProjectInfo",
    "GetSetProjectInfo_String",
    "Main_OnCommand",
    "CountSelectedTracks",
    "GetSelectedTrack",
    "GetSet_LoopTimeRange"
  }

  for i = 1, #required do
    local name = required[i]
    if type(r[name]) ~= "function" then
      error(string.format("ReaScript function not found: `%s`; likely need Reaper %s.", name, REQUIRED_REAPER_VERSION))
    end
  end
end

assert_required_api_functions()

local function trim(value)
  return Util.trim and Util.trim(value) or tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function sanitize_stem(value, fallback, max_len)
  local safe = Util.sanitize_filename(value, fallback or "script_aligner", max_len or 120)
  if safe == "" then safe = fallback or "script_aligner" end
  return safe
end

local function validate_track_ptr(track)
  if not track then return false end
  return r.ValidatePtr2(0, track, "MediaTrack*") == true
end

local function track_name(track)
  if not validate_track_ptr(track) then return "" end
  local _, name = r.GetTrackName(track)
  return trim(name)
end

local function selected_track_count()
  return tonumber(r.CountSelectedTracks(0)) or 0
end

local function get_selected_track()
  if selected_track_count() ~= 1 then
    return nil, "Please select exactly one track."
  end
  local track = r.GetSelectedTrack(0, 0)
  if not validate_track_ptr(track) then
    return nil, "Selected track pointer is invalid."
  end
  return track, nil
end

local function get_time_selection()
  local start_pos, end_pos = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  start_pos = tonumber(start_pos) or 0
  end_pos = tonumber(end_pos) or 0
  local duration = end_pos - start_pos
  if duration <= 0 then
    return nil, "Please set a non-empty time selection."
  end
  return {
    start_time = start_pos,
    end_time = end_pos,
    duration = duration
  }, nil
end

local function snapshot_selected_tracks()
  local tracks = {}
  local count = selected_track_count()
  for index = 0, count - 1 do
    local track = r.GetSelectedTrack(0, index)
    if validate_track_ptr(track) then
      tracks[#tracks + 1] = track
    end
  end
  return tracks
end

local function restore_selected_tracks(tracks)
  r.Main_OnCommand(40297, 0)
  for _, track in ipairs(tracks or {}) do
    if validate_track_ptr(track) then
      r.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)
    end
  end
end

local function snapshot_render_settings()
  local snapshot = {
    numeric = {},
    strings = {}
  }
  for _, key in ipairs(NUMERIC_RENDER_KEYS) do
    snapshot.numeric[key] = r.GetSetProjectInfo(0, key, 0, false)
  end
  for _, key in ipairs(STRING_RENDER_KEYS) do
    local _, value = r.GetSetProjectInfo_String(0, key, "", false)
    snapshot.strings[key] = tostring(value or "")
  end
  return snapshot
end

local function restore_render_settings(snapshot)
  if type(snapshot) ~= "table" then return end
  for _, key in ipairs(NUMERIC_RENDER_KEYS) do
    local value = snapshot.numeric and snapshot.numeric[key]
    if value ~= nil then
      r.GetSetProjectInfo(0, key, value, true)
    end
  end
  for _, key in ipairs(STRING_RENDER_KEYS) do
    local value = snapshot.strings and snapshot.strings[key]
    if value ~= nil then
      r.GetSetProjectInfo_String(0, key, tostring(value), true)
    end
  end
end

local function setup_render_for_bounds(output_dir, file_stem, start_time, end_time)
  r.GetSetProjectInfo(0, "RENDER_SETTINGS", 2, true)
  r.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)
  r.GetSetProjectInfo(0, "RENDER_STARTPOS", tonumber(start_time) or 0, true)
  r.GetSetProjectInfo(0, "RENDER_ENDPOS", tonumber(end_time) or 0, true)
  r.GetSetProjectInfo(0, "RENDER_SRATE", 0, true)
  r.GetSetProjectInfo(0, "RENDER_CHANNELS", 2, true)
  r.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
  r.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 1, true)
  r.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  r.GetSetProjectInfo(0, "RENDER_NORMALIZE", 0, true)
  r.GetSetProjectInfo(0, "RENDER_FADEIN", 0, true)
  r.GetSetProjectInfo(0, "RENDER_FADEOUT", 0, true)
  r.GetSetProjectInfo(0, "RENDER_FADEINSHAPE", 0, true)
  r.GetSetProjectInfo(0, "RENDER_FADEOUTSHAPE", 0, true)

  r.GetSetProjectInfo_String(0, "RENDER_FILE", output_dir, true)
  r.GetSetProjectInfo_String(0, "RENDER_PATTERN", file_stem, true)
  r.GetSetProjectInfo_String(0, "RENDER_FORMAT", FLAC16_RENDER_FORMAT, true)
end

local function render_selected_track_bounds(track, output_dir, file_stem, start_time, end_time)
  if not validate_track_ptr(track) then
    return false, "Track is missing or invalid.", nil
  end
  if type(output_dir) ~= "string" or output_dir == "" then
    return false, "Missing output directory.", nil
  end
  if type(file_stem) ~= "string" or file_stem == "" then
    return false, "Missing output file name.", nil
  end

  start_time = tonumber(start_time) or 0
  end_time = tonumber(end_time) or 0
  if end_time <= start_time then
    return false, "Render bounds are invalid.", nil
  end

  local ok_output, output_err = Files.ensure_output_dir(output_dir)
  if not ok_output then
    return false, output_err or "Cannot write to output directory.", nil
  end

  local old_render = snapshot_render_settings()
  local old_selected_tracks = snapshot_selected_tracks()
  local ok_render, render_err = xpcall(function()
    r.Main_OnCommand(40297, 0)
    r.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)
    setup_render_for_bounds(output_dir, file_stem, start_time, end_time)
    r.Main_OnCommand(42230, 0)
  end, function(err)
    return debug.traceback(err, 2)
  end)

  restore_selected_tracks(old_selected_tracks)
  restore_render_settings(old_render)

  if not ok_render then
    return false, tostring(render_err), nil
  end

  local output_path = Util.path_join(output_dir, file_stem .. ".flac")
  if not r.file_exists(output_path) then
    return false, "Render output missing: " .. tostring(output_path), nil
  end

  return true, "ok", output_path
end

local function create_track_at_end(track_name_text)
  local insert_index = tonumber(r.CountTracks(0)) or 0
  r.InsertTrackInProject(0, insert_index, 0)
  local track = r.GetTrack(0, insert_index)
  if not validate_track_ptr(track) then
    return nil, "Failed to create destination track."
  end
  local ok_name = r.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(track_name_text or ""), true)
  if ok_name ~= true then
    return nil, "Failed to name destination track."
  end
  return track, nil
end

local function build_track_lookup()
  local by_name = {}
  local track_count = tonumber(r.CountTracks(0)) or 0
  for index = 0, track_count - 1 do
    local track = r.GetTrack(0, index)
    if validate_track_ptr(track) then
      local name = track_name(track)
      by_name[name] = by_name[name] or {}
      by_name[name][#by_name[name] + 1] = track
    end
  end
  return by_name
end

local function create_text_item(track, text, position, length)
  local item = r.AddMediaItemToTrack(track)
  if not item then
    return false, "Failed to create destination media item.", nil
  end
  r.SetMediaItemInfo_Value(item, "D_POSITION", position)
  r.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  local ok_notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", tostring(text or ""), true)
  if ok_notes ~= true then
    return false, "Failed to write destination item notes.", nil
  end
  r.UpdateItemInProject(item)
  return true, nil, item
end

local function apply_item_custom_color(item, color)
  if not item then
    return false, "Destination item is missing."
  end
  if type(color) ~= "table" then
    return false, "Item color must be a table."
  end

  local red = tonumber(color.r)
  local green = tonumber(color.g)
  local blue = tonumber(color.b)
  if red == nil or green == nil or blue == nil then
    return false, "Item color must provide numeric r/g/b values."
  end

  red = math.max(0, math.min(255, math.floor(red)))
  green = math.max(0, math.min(255, math.floor(green)))
  blue = math.max(0, math.min(255, math.floor(blue)))

  r.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", r.ColorToNative(red, green, blue) | 0x1000000)
  r.UpdateItemInProject(item)
  return true, nil
end

local function add_project_marker(position, name)
  if type(position) ~= "number" or position < 0 then
    return false, "Marker position is invalid."
  end
  local marker_index = r.AddProjectMarker(0, false, position, 0, tostring(name or ""), -1)
  if type(marker_index) ~= "number" or marker_index < 0 then
    return false, "Failed to create project marker."
  end
  return true, nil
end

function NeurocastScriptAlignerReaper.validate_time_selection_input()
  local track, track_err = get_selected_track()
  if not track then return nil, track_err end

  local range, range_err = get_time_selection()
  if not range then return nil, range_err end

  local clean_track_name = track_name(track)
  if clean_track_name == "" then
    clean_track_name = "Track"
  end

  return {
    mode = "selected_track_time_selection",
    track = track,
    track_name = clean_track_name,
    start_time = range.start_time,
    end_time = range.end_time,
    duration = range.duration,
    record_label = clean_track_name .. " / time selection",
    source_label = clean_track_name
  }, nil
end

function NeurocastScriptAlignerReaper.render_time_selection_to_temp(output_dir, opts)
  local options = type(opts) == "table" and opts or {}
  local spec, spec_err = NeurocastScriptAlignerReaper.validate_time_selection_input()
  if not spec then
    return false, spec_err, nil
  end

  local prefix = sanitize_stem(options.file_stem_prefix or "script_aligner", "script_aligner", 64)
  local track_part = sanitize_stem(spec.track_name, "track", 64)
  local stamp = Util.date_time_stamp_with_time_precise()
  local file_stem = sanitize_stem(
    table.concat({ prefix, track_part, "selection", stamp }, "__"),
    "script_aligner_input",
    180
  )

  local ok_render, render_msg, output_path = render_selected_track_bounds(
    spec.track,
    output_dir,
    file_stem,
    spec.start_time,
    spec.end_time
  )
  if not ok_render then
    return false, render_msg, nil
  end

  return true, "ok", {
    input_path = output_path,
    render_file_stem = file_stem,
    start_time = spec.start_time,
    end_time = spec.end_time,
    duration = spec.duration,
    track_name = spec.track_name,
    source_label = spec.source_label
  }
end

function NeurocastScriptAlignerReaper.apply_import_rows(rows, opts)
  if type(rows) ~= "table" or #rows == 0 then
    return false, "No import rows are available.", nil
  end

  local options = type(opts) == "table" and opts or {}
  local undo_label = trim(options.undo_label)
  if undo_label == "" then
    undo_label = "Import Neurocast Script Aligner JSON"
  end

  local track_lookup = build_track_lookup()
  local track_by_name = {}
  local created_track_count = 0
  local reused_track_count = 0
  local marker_count = 0
  local touched_track_names = {}
  local touched_track_count = 0

  local success, runtime_err = pcall(function()
    r.Undo_BeginBlock2(0)
    r.PreventUIRefresh(16)

    for index = 1, #rows do
      local row = rows[index]
      if type(row) ~= "table" then
        error(string.format("Import row %d is not a table.", index))
      end

      local track_name_text = trim(row.track_name)
      if track_name_text == "" then
        error(string.format("Import row %d has empty track_name.", index))
      end

      local start_seconds = tonumber(row.start_seconds)
      if start_seconds == nil or start_seconds < 0 then
        error(string.format("Import row %d has invalid start_seconds.", index))
      end

      local length_seconds = tonumber(row.length_seconds)
      if length_seconds == nil or length_seconds <= 0 then
        error(string.format("Import row %d has invalid length_seconds.", index))
      end

      local track = track_by_name[track_name_text]
      if not validate_track_ptr(track) then
        local existing = track_lookup[track_name_text]
        if type(existing) == "table" and validate_track_ptr(existing[1]) then
          track = existing[1]
          reused_track_count = reused_track_count + 1
        else
          local create_err = nil
          track, create_err = create_track_at_end(track_name_text)
          if not track then
            error(tostring(create_err or "Failed to create destination track."))
          end
          created_track_count = created_track_count + 1
        end
        track_by_name[track_name_text] = track
        touched_track_names[#touched_track_names + 1] = track_name_text
        touched_track_count = touched_track_count + 1
      end

      local ok_item, item_err, item = create_text_item(track, row.note_text or "", start_seconds, length_seconds)
      if not ok_item then
        error(tostring(item_err or "Failed to create destination item."))
      end

      if row.item_color_rgb ~= nil then
        local ok_color, color_err = apply_item_custom_color(item, row.item_color_rgb)
        if not ok_color then
          error(tostring(color_err or "Failed to color destination item."))
        end
      end

      local marker_name = trim(row.warning_marker_name)
      if marker_name ~= "" then
        local marker_position = tonumber(row.warning_marker_position_seconds)
        local ok_marker, marker_err = add_project_marker(marker_position, marker_name)
        if not ok_marker then
          error(tostring(marker_err or "Failed to create warning marker."))
        end
        marker_count = marker_count + 1
      end
    end
  end)

  r.PreventUIRefresh(-16)
  r.Undo_EndBlock2(0, success and undo_label or (undo_label .. " (failed)"), -1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()

  if not success then
    return false, "Import failed: " .. tostring(runtime_err), nil
  end

  return true, string.format(
    "Imported %d item(s) to %d track(s). Created %d, reused %d. Added %d marker(s).",
    #rows,
    touched_track_count,
    created_track_count,
    reused_track_count,
    marker_count
  ), {
    item_count = #rows,
    created_track_count = created_track_count,
    reused_track_count = reused_track_count,
    marker_count = marker_count,
    touched_track_names = touched_track_names,
    track_count = touched_track_count
  }
end

return NeurocastScriptAlignerReaper
