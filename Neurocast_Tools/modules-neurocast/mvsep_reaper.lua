if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Util = require("modules-neurocast.Util")
local Files = require("modules-neurocast.Files")
local RenderSettings = require("modules-neurocast.ReaperX_render_settings_helper")

local MVSepReaper = {}

local FALLBACK_BASE_DIR_NAME = "MVSepTool"
local FLAC16_RENDER_FORMAT = "Y2FsZhAAAAAIAAAA"
local RENDER_PROJECT_ACTION = 42230

local function sanitize_stem(value, fallback, max_len)
  local safe = Util.sanitize_filename(value, fallback or "mvsep", max_len or 120)
  if safe == "" then safe = fallback or "mvsep" end
  return safe
end

local function validate_track_ptr(track)
  if not track then return false end
  if r.ValidatePtr2 then
    return r.ValidatePtr2(0, track, "MediaTrack*") == true
  end
  return true
end

local function track_name(track)
  if not validate_track_ptr(track) then return "" end
  local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return tostring(name or "")
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
  for i = 0, count - 1 do
    local track = r.GetSelectedTrack(0, i)
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

local function base_render_profile(output_dir, pattern)
  return {
    schema_version = 1,
    numeric = {
      RENDER_SRATE = 0,
      RENDER_STARTPOS = 0,
      RENDER_ENDPOS = 0,
      RENDER_CHANNELS = 2,
      RENDER_TAILFLAG = 0,
      RENDER_TAILMS = 1000,
      PROJECT_SRATE_USE = 1,
      RENDER_ADDTOPROJ = 0,
      RENDER_DITHER = 0,
      RENDER_NORMALIZE = 1536,
      RENDER_NORMALIZE_TARGET = 0,
      RENDER_BRICKWALL = 0,
      RENDER_FADEIN = 0.005,
      RENDER_FADEOUT = 0.005,
      RENDER_FADEINSHAPE = 4,
      RENDER_FADEOUTSHAPE = 4,
      RENDER_FADELPF = 0,
      RENDER_PADSTART = 0,
      RENDER_PADEND = 0,
      RENDER_TRIMSTART = 0.000001,
      RENDER_TRIMEND = 0.000001,
      RENDER_DELAY = 0
    },
    strings = {
      RENDER_FILE = output_dir,
      RENDER_PATTERN = pattern,
      RENDER_EXTRAFILEDIR = "",
      RENDER_FORMAT = FLAC16_RENDER_FORMAT,
      RENDER_FORMAT2 = ""
    }
  }
end

local function time_selection_render_profile(output_dir, file_stem)
  local profile = base_render_profile(output_dir, file_stem)
  profile.numeric.RENDER_SETTINGS = RenderSettings.RENDER_SETTINGS.MODE_STEMS_AND_MASTER_MIX
    + RenderSettings.RENDER_SETTINGS.MODE_STEMS_ONLY
  profile.numeric.RENDER_BOUNDSFLAG = RenderSettings.RENDER_BOUNDSFLAG.TIME_SELECTION
  return profile
end

local function region_matrix_render_profile(output_dir, pattern)
  local profile = base_render_profile(output_dir, pattern)
  profile.numeric.RENDER_SETTINGS = RenderSettings.RENDER_SETTINGS.USE_RENDER_MATRIX
  profile.numeric.RENDER_BOUNDSFLAG = RenderSettings.RENDER_BOUNDSFLAG.SELECTED_PROJECT_REGIONS
  return profile
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

  local old_selected_tracks = snapshot_selected_tracks()
  local profile = time_selection_render_profile(output_dir, file_stem)
  local ok_render, render_err = RenderSettings.with_render_settings(profile, function()
    local ok_work, work_err = xpcall(function()
      r.Main_OnCommand(40297, 0)
      r.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)
      r.Main_OnCommand(RENDER_PROJECT_ACTION, 0)
    end, function(err)
      return debug.traceback(err, 2)
    end)

    restore_selected_tracks(old_selected_tracks)
    if not ok_work then
      return false, tostring(work_err), nil
    end
    return true, "ok", nil
  end)

  restore_selected_tracks(old_selected_tracks)

  if not ok_render then
    return false, tostring(render_err), nil
  end

  local output_path = Util.path_join(output_dir, file_stem .. ".flac")
  if not r.file_exists(output_path) then
    return false, "Render output missing: " .. tostring(output_path), nil
  end

  return true, "ok", output_path
end

function MVSepReaper.create_runtime_paths(opts)
  local options = opts or {}
  local project_path = Files.read_project_path() or ""
  local base_dir = nil
  if project_path ~= "" then
    local folder_name = sanitize_stem(options.project_folder_name or "mvsep_data", "mvsep_data", 64)
    base_dir = Util.path_join(project_path, folder_name)
  else
    base_dir = Util.path_join(r.GetResourcePath(), "Data")
    base_dir = Util.path_join(base_dir, FALLBACK_BASE_DIR_NAME)
  end

  local tmp_dir = Util.path_join(base_dir, "tmp")
  local results_dir = project_path
  local settings_dir = Util.path_join(r.GetResourcePath(), "Data")
  settings_dir = Util.path_join(settings_dir, "NeurocastTool")
  settings_dir = Util.path_join(settings_dir, "mvsep")

  return {
    project_path = project_path,
    base_dir = base_dir,
    tmp_dir = tmp_dir,
    results_dir = results_dir,
    settings_dir = settings_dir,
    settings_model_options_file = Util.path_join(settings_dir, "settings_model_options.json"),
    cache_dir = settings_dir,
    cache_file = Util.path_join(settings_dir, "cache_catalog.json")
  }
end

function MVSepReaper.ensure_runtime_dirs(paths)
  if type(paths) ~= "table" then
    return false, "paths table is required"
  end

  local ok_tmp, tmp_err = Files.ensure_tmp_dir(paths.tmp_dir)
  if not ok_tmp then return false, tmp_err end
  local ok_results, results_err = Files.ensure_output_dir(paths.results_dir)
  if not ok_results then return false, results_err end
  local ok_settings, settings_err = MVSepReaper.ensure_settings_dir(paths)
  if not ok_settings then return false, settings_err end
  return true, nil
end

function MVSepReaper.ensure_settings_dir(paths)
  if type(paths) ~= "table" then
    return false, "paths table is required"
  end
  return Files.ensure_output_dir(paths.settings_dir)
end

function MVSepReaper.validate_time_selection_input()
  local track, track_err = get_selected_track()
  if not track then return nil, track_err end
  local range, range_err = get_time_selection()
  if not range then return nil, range_err end

  local current_track_name = track_name(track)
  local clean_track_name = current_track_name ~= "" and current_track_name or "Track"

  return {
    mode = "time_selection",
    track = track,
    track_name = clean_track_name,
    start_time = range.start_time,
    end_time = range.end_time,
    duration = range.duration,
    record_label = clean_track_name .. " / time selection",
    source_label = clean_track_name
  }, nil
end

local MODERN_REGION_API_NAMES = {
  "GetNumRegionsOrMarkers",
  "GetRegionOrMarker",
  "GetRegionOrMarkerInfo_Value",
  "SetRegionOrMarkerInfo_Value",
  "GetSetRegionOrMarkerInfo_String"
}

local function require_modern_region_api()
  for _, name in ipairs(MODERN_REGION_API_NAMES) do
    if type(r[name]) ~= "function" then
      return false, "REAPER 7.62+ API is required: " .. tostring(name)
    end
  end
  return true, nil
end

local function read_region_number(marker, parameter_name, context)
  local ok_call, value = pcall(r.GetRegionOrMarkerInfo_Value, 0, marker, parameter_name)
  local number_value = ok_call and tonumber(value) or nil
  if number_value == nil then
    return nil, "Failed to read " .. tostring(parameter_name) .. " for " .. tostring(context) .. "."
  end
  return number_value, nil
end

local function read_region_string(marker, parameter_name, context)
  local ok_call, ok_value, value =
    pcall(r.GetSetRegionOrMarkerInfo_String, 0, marker, parameter_name, "", false)
  if not ok_call or ok_value ~= true or type(value) ~= "string" then
    return nil, "Failed to read " .. tostring(parameter_name) .. " for " .. tostring(context) .. "."
  end
  return value, nil
end

local function resolve_region_marker(region)
  local marker_guid = type(region) == "table" and tostring(region.marker_guid or "") or ""
  if marker_guid == "" then
    return nil, "Region record is missing marker_guid."
  end

  local ok_call, marker = pcall(r.GetRegionOrMarker, 0, -1, marker_guid)
  if not ok_call or not marker then
    return nil, "Failed to resolve project region by GUID: " .. marker_guid
  end

  local resolved_guid, guid_err = read_region_string(marker, "GUID", "project region " .. marker_guid)
  if not resolved_guid then
    return nil, guid_err
  end
  if resolved_guid ~= marker_guid then
    return nil, "Resolved project region GUID does not match: " .. marker_guid
  end

  local is_region, is_region_err = read_region_number(marker, "B_ISREGION", "project region " .. marker_guid)
  if is_region == nil then
    return nil, is_region_err
  end
  if is_region == 0 then
    return nil, "ProjectMarker is no longer a region: " .. marker_guid
  end

  return marker, nil
end

local function resolve_region_number(region)
  local marker, marker_err = resolve_region_marker(region)
  if not marker then
    return nil, marker_err
  end
  return read_region_number(marker, "I_NUMBER", "project region " .. tostring(region.marker_guid))
end

function MVSepReaper.collect_project_regions()
  local ok_api, api_err = require_modern_region_api()
  if not ok_api then
    return nil, api_err
  end

  local ok_count, count_value = pcall(r.GetNumRegionsOrMarkers, 0)
  local marker_count = ok_count and tonumber(count_value) or nil
  if marker_count == nil or marker_count < 0 or marker_count % 1 ~= 0 then
    return nil, "GetNumRegionsOrMarkers returned an invalid result."
  end

  local regions = {}
  for api_index = 0, marker_count - 1 do
    local context = "project marker/region at internal position " .. tostring(api_index)
    local ok_marker, marker = pcall(r.GetRegionOrMarker, 0, api_index, "")
    if not ok_marker or not marker then
      return nil, "Failed to get " .. context .. "."
    end

    local marker_guid, guid_err = read_region_string(marker, "GUID", context)
    if not marker_guid then return nil, guid_err end
    if marker_guid == "" then
      return nil, "Project marker/region has an empty GUID at internal position " .. tostring(api_index) .. "."
    end

    local is_region, is_region_err = read_region_number(marker, "B_ISREGION", context)
    if is_region == nil then return nil, is_region_err end
    local internal_index, internal_err = read_region_number(marker, "I_INDEX", context)
    if internal_index == nil then return nil, internal_err end
    local marker_number, marker_number_err = read_region_number(marker, "I_NUMBER", context)
    if marker_number == nil then return nil, marker_number_err end
    local start_time, start_err = read_region_number(marker, "D_STARTPOS", context)
    if start_time == nil then return nil, start_err end
    local end_time, end_err = read_region_number(marker, "D_ENDPOS", context)
    if end_time == nil then return nil, end_err end
    local name, name_err = read_region_string(marker, "P_NAME", context)
    if not name then return nil, name_err end

    if is_region ~= 0 then
      if end_time > start_time then
        regions[#regions + 1] = {
          marker_guid = marker_guid,
          internal_index = internal_index,
          region_index = marker_number,
          start_time = start_time,
          end_time = end_time,
          duration = end_time - start_time,
          region_name = tostring(name or "")
        }
      end
    end
  end

  table.sort(regions, function(a, b)
    if a.start_time ~= b.start_time then return a.start_time < b.start_time end
    local a_name = tostring(a.region_name or "")
    local b_name = tostring(b.region_name or "")
    if a_name ~= b_name then return a_name < b_name end
    if a.region_index ~= b.region_index then return a.region_index < b.region_index end
    return a.internal_index < b.internal_index
  end)
  return regions, nil
end

local function collect_render_matrix_tracks()
  local tracks = {}
  local master_track = r.GetMasterTrack(0)
  if master_track then
    tracks[#tracks + 1] = master_track
  end
  local count = tonumber(r.CountTracks(0)) or 0
  for i = 0, count - 1 do
    local track = r.GetTrack(0, i)
    if validate_track_ptr(track) then
      tracks[#tracks + 1] = track
    end
  end
  return tracks
end

local function region_key(region)
  return tostring(region and region.marker_guid or "")
end

local function require_region_selection_api()
  local ok_modern, modern_err = require_modern_region_api()
  if not ok_modern then return false, modern_err end
  if type(r.SetRegionRenderMatrix) ~= "function" then
    return false, "REAPER API SetRegionRenderMatrix is required for region render matrix setup."
  end
  if type(r.EnumRegionRenderMatrix) ~= "function" then
    return false, "REAPER API EnumRegionRenderMatrix is required for region render matrix restore."
  end
  return true, nil
end

local function snapshot_region_selection(regions)
  local snapshot = {}
  for _, region in ipairs(regions or {}) do
    local marker, marker_err = resolve_region_marker(region)
    if not marker then return nil, marker_err end
    local selected, selected_err =
      read_region_number(marker, "B_UISEL", "project region " .. tostring(region.marker_guid))
    if selected == nil then return nil, selected_err end
    snapshot[#snapshot + 1] = {
      region = region,
      selected = selected
    }
  end
  return snapshot, nil
end

local function restore_region_selection(snapshot)
  for _, row in ipairs(snapshot or {}) do
    local marker, marker_err = resolve_region_marker(row.region)
    if not marker then return false, marker_err end
    local ok_set, result =
      pcall(r.SetRegionOrMarkerInfo_Value, 0, marker, "B_UISEL", tonumber(row.selected) or 0)
    if not ok_set or tonumber(result) == nil then
      return false, "Failed to restore project region selection: " .. tostring(row.region.marker_guid)
    end
  end
  return true, nil
end

local function select_only_regions(all_regions, selected_regions)
  local selected = {}
  for _, region in ipairs(selected_regions or {}) do
    local key = region_key(region)
    if key == "" then
      return false, "Selected region is missing marker_guid."
    end
    selected[key] = true
  end
  for _, region in ipairs(all_regions or {}) do
    local marker, marker_err = resolve_region_marker(region)
    if not marker then return false, marker_err end
    local ok_set, result =
      pcall(r.SetRegionOrMarkerInfo_Value, 0, marker, "B_UISEL", selected[region_key(region)] and 1 or 0)
    if not ok_set or tonumber(result) == nil then
      return false, "Failed to update project region selection: " .. tostring(region.marker_guid)
    end
  end
  return true, nil
end

local function snapshot_region_matrix(regions)
  local snapshot = {}
  for _, region in ipairs(regions or {}) do
    local region_index, region_index_err = resolve_region_number(region)
    if region_index == nil then return nil, region_index_err end
    local tracks = {}
    local i = 0
    while true do
      local ok_enum, track = pcall(r.EnumRegionRenderMatrix, 0, region_index, i)
      if not ok_enum then
        return nil, "Failed to enumerate render matrix for region " .. tostring(region.marker_guid) .. "."
      end
      if not track then break end
      tracks[#tracks + 1] = track
      i = i + 1
    end
    snapshot[#snapshot + 1] = {
      region = region,
      tracks = tracks
    }
  end
  return snapshot, nil
end

local function clear_region_matrix(regions, tracks)
  for _, region in ipairs(regions or {}) do
    local region_index, region_index_err = resolve_region_number(region)
    if region_index == nil then return false, region_index_err end
    for _, track in ipairs(tracks or {}) do
      local ok_set = pcall(r.SetRegionRenderMatrix, 0, region_index, track, -1)
      if not ok_set then
        return false, "Failed to clear render matrix for region " .. tostring(region.marker_guid) .. "."
      end
    end
  end
  return true, nil
end

local function restore_region_matrix(snapshot, all_tracks)
  local regions = {}
  for _, row in ipairs(snapshot or {}) do
    regions[#regions + 1] = row.region
  end
  local ok_clear, clear_err = clear_region_matrix(regions, all_tracks)
  if not ok_clear then return false, clear_err end
  for _, row in ipairs(snapshot or {}) do
    local region_index, region_index_err = resolve_region_number(row.region)
    if region_index == nil then return false, region_index_err end
    for _, track in ipairs(row.tracks or {}) do
      if track then
        local ok_set = pcall(r.SetRegionRenderMatrix, 0, region_index, track, 1)
        if not ok_set then
          return false, "Failed to restore render matrix for region " .. tostring(row.region.marker_guid) .. "."
        end
      end
    end
  end
  return true, nil
end

local function parse_render_targets(targets_txt)
  local out = {}
  for target in tostring(targets_txt or ""):gmatch("[^;]+") do
    local text = Util.trim(target)
    if text ~= "" then
      out[#out + 1] = text
    end
  end
  return out
end

local function read_render_targets(expected_count)
  local ok_targets, targets_txt = r.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
  if ok_targets ~= true then
    return nil, "Failed to read RENDER_TARGETS."
  end
  local targets = parse_render_targets(targets_txt)
  if #targets ~= expected_count then
    return nil, "Unexpected render target count: expected " .. tostring(expected_count) .. ", got " .. tostring(#targets)
  end
  return targets, nil
end

function MVSepReaper.prepare_region_jobs()
  local track, track_err = get_selected_track()
  if not track then return nil, track_err end

  local all_regions, regions_err = MVSepReaper.collect_project_regions()
  if not all_regions then
    return nil, regions_err
  end
  if #all_regions == 0 then
    return nil, "No project regions found."
  end

  local current_track_name = track_name(track)
  local clean_track_name = current_track_name ~= "" and current_track_name or "Track"
  local jobs = {}
  for idx, region in ipairs(all_regions) do
    local region_title = Util.trim(region.region_name)
    if region_title == "" then
      region_title = "Region " .. tostring(idx)
    end
    jobs[#jobs + 1] = {
      mode = "regions",
      track = track,
      track_name = clean_track_name,
      marker_guid = region.marker_guid,
      internal_index = region.internal_index,
      region_index = region.region_index,
      region_number = idx,
      region_name = region_title,
      start_time = region.start_time,
      end_time = region.end_time,
      duration = region.duration,
      track_position = region.start_time,
      record_label = clean_track_name .. " / " .. region_title,
      source_label = clean_track_name
    }
  end

  return jobs, nil
end

local function build_render_file_stem(spec)
  local mode = spec.mode or spec.input_mode
  local source_part = sanitize_stem(spec.track_name or spec.source_label or "track", "track", 64)
  local mode_part = mode == "regions" and "region" or "time"
  local label_part = mode == "regions"
    and sanitize_stem(spec.region_name or ("region_" .. tostring(spec.region_number or "")), "region", 64)
    or "selection"
  local stamp = Util.date_time_stamp_with_time_precise()
  return sanitize_stem(table.concat({ source_part, mode_part, label_part, stamp }, "__"), "mvsep_input", 180)
end

local function build_region_batch_pattern(specs)
  local first = specs and specs[1] or {}
  local source_part = sanitize_stem(first.track_name or first.source_label or "track", "track", 64)
  local stamp = Util.date_time_stamp_with_time_precise()
  return sanitize_stem(table.concat({ source_part, "regions", stamp }, "__"), "mvsep_regions", 128) .. "-$region"
end

local function file_stem_from_path(path)
  local name = tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
  return name:gsub("%.[^%.]+$", "")
end

local function copy_file_chunked(source_path, target_path)
  local source, source_err = io.open(source_path, "rb")
  if not source then
    return false, "Failed to open rendered input: " .. tostring(source_err or source_path)
  end

  local target, target_err = io.open(target_path, "wb")
  if not target then
    source:close()
    return false, "Failed to create ASCII upload staging file: " .. tostring(target_err or target_path)
  end

  local ok_copy, copy_err = xpcall(function()
    while true do
      local chunk = source:read(1024 * 1024)
      if not chunk then break end
      local ok_write, write_err = target:write(chunk)
      if not ok_write then
        error("staging write failed: " .. tostring(write_err or target_path))
      end
    end
    local ok_flush, flush_err = target:flush()
    if not ok_flush then
      error("staging flush failed: " .. tostring(flush_err or target_path))
    end
  end, debug.traceback)

  source:close()
  target:close()
  if not ok_copy then
    os.remove(target_path)
    return false, "Failed to copy rendered input to ASCII upload staging: " .. tostring(copy_err)
  end
  return true, nil
end

function MVSepReaper.stage_region_inputs_for_upload(paths, specs)
  if type(paths) ~= "table" or type(paths.tmp_dir) ~= "string" or paths.tmp_dir == "" then
    return false, "MVSEP temp directory is required for upload staging.", nil
  end
  if type(specs) ~= "table" or #specs == 0 then
    return false, "No rendered region inputs to stage.", nil
  end

  local ok_dirs, dirs_err = MVSepReaper.ensure_runtime_dirs(paths)
  if not ok_dirs then
    return false, dirs_err, nil
  end
  if Util.has_non_ascii(paths.tmp_dir) then
    return false, "MVSEP temp directory contains non-ASCII characters and is not safe for Windows curl uploads: " .. paths.tmp_dir, nil
  end

  local stamp = Util.date_time_stamp_with_time_precise()
  local staged_rows = {}
  local created_paths = {}

  local function cleanup_created_paths()
    for _, path in ipairs(created_paths) do
      Files.remove_best_effort(path)
    end
  end

  for i, spec in ipairs(specs) do
    local source_path = Util.trim(type(spec) == "table" and spec.input_path or "")
    if source_path == "" then
      cleanup_created_paths()
      return false, "Rendered region input path is missing at index " .. tostring(i) .. ".", nil
    end
    local source_size = Files.file_size(source_path)
    if source_size == nil then
      cleanup_created_paths()
      return false, "Rendered region input is missing or unreadable: " .. source_path, nil
    end

    local target_name = string.format("mvsep_region_upload_%s_%03d.flac", stamp, i)
    local target_path = Files.bump_to_unique_path(Util.path_join(paths.tmp_dir, target_name))
    if Util.has_non_ascii(target_path) then
      cleanup_created_paths()
      return false, "Generated MVSEP upload staging path is not ASCII-safe: " .. target_path, nil
    end
    if #target_path > 240 then
      cleanup_created_paths()
      return false, "Generated MVSEP upload staging path is too long for reliable Windows curl access: " .. target_path, nil
    end

    local ok_copy, copy_err = copy_file_chunked(source_path, target_path)
    if not ok_copy then
      cleanup_created_paths()
      return false, copy_err, nil
    end
    created_paths[#created_paths + 1] = target_path

    local target_size = Files.file_size(target_path)
    if target_size ~= source_size then
      cleanup_created_paths()
      return false, string.format(
        "MVSEP upload staging size mismatch for region %d: source=%s staged=%s",
        i,
        tostring(source_size),
        tostring(target_size)
      ), nil
    end

    staged_rows[#staged_rows + 1] = {
      spec = spec,
      source_path = source_path,
      source_size = source_size,
      source_non_ascii = Util.has_non_ascii(source_path),
      staged_path = target_path,
      staged_size = target_size
    }
  end

  for _, row in ipairs(staged_rows) do
    row.spec.render_source_path = row.source_path
    row.spec.input_path = row.staged_path
    row.spec.render_file_stem = file_stem_from_path(row.staged_path)
    row.spec.upload_staging = {
      source_path = row.source_path,
      source_size = row.source_size,
      source_non_ascii = row.source_non_ascii,
      staged_path = row.staged_path,
      staged_size = row.staged_size
    }
  end

  return true, "ok", specs
end

function MVSepReaper.render_spec_to_temp(paths, spec)
  if type(paths) ~= "table" then
    return false, "paths table is required", nil
  end
  if type(spec) ~= "table" then
    return false, "spec table is required", nil
  end
  local ok_dirs, dirs_err = MVSepReaper.ensure_runtime_dirs(paths)
  if not ok_dirs then
    return false, dirs_err, nil
  end

  local file_stem = build_render_file_stem(spec)
  local ok_render, render_msg, output_path = render_selected_track_bounds(
    spec.track,
    paths.tmp_dir,
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
    duration = spec.duration
  }
end

function MVSepReaper.render_region_specs_to_temp(paths, specs)
  if type(paths) ~= "table" then
    return false, "paths table is required", nil
  end
  if type(specs) ~= "table" or #specs == 0 then
    return false, "No region specs to render.", nil
  end
  local ok_dirs, dirs_err = MVSepReaper.ensure_runtime_dirs(paths)
  if not ok_dirs then
    return false, dirs_err, nil
  end

  local ok_region_api, region_api_err = require_region_selection_api()
  if not ok_region_api then
    return false, region_api_err, nil
  end

  local target_track = specs[1].track
  if not validate_track_ptr(target_track) then
    return false, "Region render target track is missing or invalid.", nil
  end
  for _, spec in ipairs(specs) do
    if spec.track ~= target_track then
      return false, "All bulk-rendered MVSEP regions must use the same selected track.", nil
    end
    if type(spec.marker_guid) ~= "string" or spec.marker_guid == "" then
      return false, "Region spec is missing marker_guid.", nil
    end
  end

  local all_regions, all_regions_err = MVSepReaper.collect_project_regions()
  if not all_regions then
    return false, all_regions_err, nil
  end
  local all_tracks = collect_render_matrix_tracks()
  local old_selected_tracks = snapshot_selected_tracks()
  local region_selection_snapshot = nil
  local region_matrix_snapshot = nil
  local render_targets = nil
  local restore_errors = {}
  local profile = region_matrix_render_profile(paths.tmp_dir, build_region_batch_pattern(specs))

  local function remember_restore(label, fn)
    local ok_restore, restore_err = pcall(fn)
    if not ok_restore then
      restore_errors[#restore_errors + 1] = tostring(label) .. ": " .. tostring(restore_err)
    end
  end

  local function restore_region_render_state()
    remember_restore("region matrix", function()
      if region_matrix_snapshot then
        local ok_restore, restore_err = restore_region_matrix(region_matrix_snapshot, all_tracks)
        if not ok_restore then error(restore_err) end
      end
    end)
    remember_restore("region selection", function()
      if region_selection_snapshot then
        local ok_restore, restore_err = restore_region_selection(region_selection_snapshot)
        if not ok_restore then error(restore_err) end
      end
    end)
    remember_restore("track selection", function()
      restore_selected_tracks(old_selected_tracks)
    end)
    r.UpdateArrange()
  end

  local ok_render, render_err = RenderSettings.with_render_settings(profile, function()
    local ok_work, work_err = xpcall(function()
      local selection_err = nil
      region_selection_snapshot, selection_err = snapshot_region_selection(all_regions)
      if not region_selection_snapshot then error(selection_err) end
      local matrix_err = nil
      region_matrix_snapshot, matrix_err = snapshot_region_matrix(specs)
      if not region_matrix_snapshot then error(matrix_err) end

      r.Main_OnCommand(40297, 0)
      r.SetMediaTrackInfo_Value(target_track, "I_SELECTED", 1)
      local ok_select, select_err = select_only_regions(all_regions, specs)
      if not ok_select then error(select_err) end
      local ok_clear, clear_err = clear_region_matrix(specs, all_tracks)
      if not ok_clear then error(clear_err) end
      for _, spec in ipairs(specs) do
        local region_index, region_index_err = resolve_region_number(spec)
        if region_index == nil then error(region_index_err) end
        local ok_matrix = pcall(r.SetRegionRenderMatrix, 0, region_index, target_track, 1)
        if not ok_matrix then
          error("Failed to set render matrix for region " .. tostring(spec.marker_guid) .. ".")
        end
      end

      local targets, targets_err = read_render_targets(#specs)
      if not targets then
        error(targets_err)
      end
      render_targets = targets
      r.Main_OnCommand(RENDER_PROJECT_ACTION, 0)
    end, function(err)
      return debug.traceback(err, 2)
    end)

    restore_region_render_state()

    if not ok_work then
      local message = tostring(work_err)
      if #restore_errors > 0 then
        message = message .. " | Failed to restore region render state: " .. table.concat(restore_errors, " | ")
      end
      return false, message, nil
    end
    if #restore_errors > 0 then
      return false, "Failed to restore region render state: " .. table.concat(restore_errors, " | "), nil
    end
    return true, "ok", nil
  end)

  restore_selected_tracks(old_selected_tracks)

  if not ok_render then
    return false, tostring(render_err), nil
  end
  if type(render_targets) ~= "table" or #render_targets ~= #specs then
    return false, "Region render targets were not captured.", nil
  end

  for i, spec in ipairs(specs) do
    local output_path = render_targets[i]
    if not r.file_exists(output_path) then
      return false, "Render output missing: " .. tostring(output_path), nil
    end
    spec.input_path = output_path
    spec.render_file_stem = file_stem_from_path(output_path)
  end

  return true, "ok", specs
end

local function cleaned_track_title(download)
  if type(download) == "table" and type(download.track_name) == "string" and Util.trim(download.track_name) ~= "" then
    return Util.trim(download.track_name)
  end

  local source = ""
  if type(download) == "table" and type(download.local_path) == "string" then
    source = download.local_path
  end
  local name = source:match("([^/\\]+)$") or source
  name = name:gsub("%.[^%.]+$", "")
  name = name:gsub("__", " - ")
  name = name:gsub("_+", " ")
  name = Util.trim(name)
  if name == "" then
    name = "MVSEP Result"
  end
  return name
end

local DOWNLOAD_AUDIO_EXTENSIONS = {
  mp3 = true,
  wav = true,
  flac = true,
  m4a = true
}

local function downloaded_audio_signature(head)
  local bytes = tostring(head or "")
  local first, second = bytes:byte(1), bytes:byte(2)
  if bytes:sub(1, 4) == "fLaC" then return "flac" end
  if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WAVE" then return "wav" end
  if bytes:sub(1, 3) == "ID3" or (first == 0xFF and second and (second & 0xE0) == 0xE0) then
    return "mp3"
  end
  if bytes:sub(5, 8) == "ftyp" then return "m4a" end
  return nil
end

function MVSepReaper.validate_downloaded_audio(path, reported_bytes)
  local resolved = type(path) == "string" and path or ""
  if resolved == "" then return false, "Downloaded result path is empty." end
  local extension = resolved:match("%.([A-Za-z0-9]+)$")
  extension = extension and extension:lower() or ""
  if DOWNLOAD_AUDIO_EXTENSIONS[extension] ~= true then
    return false, "Downloaded result has an unsupported audio extension: " .. tostring(extension ~= "" and extension or "(missing)")
  end

  local file, open_err = io.open(resolved, "rb")
  if not file then return false, "Downloaded result cannot be opened: " .. tostring(open_err or "unknown error") end
  local size = file:seek("end")
  file:seek("set", 0)
  local head = file:read(256) or ""
  file:close()
  if not size or size <= 0 then return false, "Downloaded result is empty." end
  local reported = tonumber(reported_bytes)
  if reported ~= nil and reported <= 0 then return false, "Backend download reported zero bytes." end

  local detected = downloaded_audio_signature(head)
  if not detected then return false, "Downloaded result is not recognizable audio." end
  if detected ~= extension then
    return false, "Downloaded result audio signature does not match its extension."
  end
  return true, size, { format = detected, extension = "." .. extension }
end

local function create_track_at_bottom(track_title)
  local index = tonumber(r.CountTracks(0)) or 0
  r.InsertTrackAtIndex(index, true)
  local track = r.GetTrack(0, index)
  if not validate_track_ptr(track) then
    return nil, "Failed to create destination track."
  end
  r.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(track_title or "MVSEP Result"), true)
  return track, nil
end

local function create_track_at_index(index, track_title)
  r.InsertTrackAtIndex(index, true)
  local track = r.GetTrack(0, index)
  if not validate_track_ptr(track) then
    return nil, "Failed to create destination track."
  end
  r.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(track_title or "MVSEP Result"), true)
  return track, nil
end

local IMPORT_MODE_BELOW_SOURCE = "below_source"
local IMPORT_MODE_STARTING_AT_TRACK = "starting_at_track"

local function resolve_existing_track_index(track)
  if not validate_track_ptr(track) then return nil end
  local track_number = tonumber(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
  if not track_number or track_number <= 0 then return nil end

  local index = math.floor(track_number + 0.0001) - 1
  local count = tonumber(r.CountTracks(0)) or 0
  if index < 0 or index >= count then return nil end
  if r.GetTrack(0, index) ~= track then return nil end
  return index
end

local function resolve_source_insert_index(record)
  local source_track = type(record) == "table" and record.track or nil
  local source_index = resolve_existing_track_index(source_track)
  if source_index == nil then return nil end
  return source_index + 1
end

local function import_failure_info(error_code, placement_mode, mutation_started)
  return {
    error_code = tostring(error_code or "IMPORT_FAILED"),
    placement_mode = tostring(placement_mode or ""),
    mutation_started = mutation_started == true
  }
end

function MVSepReaper.import_downloads(record, placement)
  if type(record) ~= "table" then
    return false, "record is required", 0,
      import_failure_info("INVALID_RECORD", nil, false)
  end
  if type(record.downloads) ~= "table" or #record.downloads == 0 then
    return false, "No downloaded files are available.", 0,
      import_failure_info("NO_DOWNLOADS", nil, false)
  end

  local requested_placement = type(placement) == "table" and placement or {}
  local placement_mode = tostring(requested_placement.mode or IMPORT_MODE_BELOW_SOURCE)
  if placement_mode ~= IMPORT_MODE_BELOW_SOURCE
      and placement_mode ~= IMPORT_MODE_STARTING_AT_TRACK then
    return false, "Unknown add-to-project placement mode.", 0,
      import_failure_info("INVALID_PLACEMENT_MODE", placement_mode, false)
  end

  local valid_downloads = {}
  for _, download in ipairs(record.downloads) do
    if type(download) == "table" and type(download.local_path) == "string" and download.local_path ~= "" and r.file_exists(download.local_path) then
      valid_downloads[#valid_downloads + 1] = download
    end
  end
  if #valid_downloads == 0 then
    return false, "Downloaded files are missing on disk.", 0,
      import_failure_info("DOWNLOADS_MISSING", placement_mode, false)
  end

  local starting_track_index = nil
  local initial_track_count = tonumber(r.CountTracks(0)) or 0
  local starting_track_plan = {}
  if placement_mode == IMPORT_MODE_STARTING_AT_TRACK then
    starting_track_index = resolve_existing_track_index(requested_placement.start_track)
    if starting_track_index == nil then
      return false, "Starting destination track is missing or invalid.", 0,
        import_failure_info("INVALID_DESTINATION_TRACK", placement_mode, false)
    end
    for download_index = 1, #valid_downloads do
      local destination_index = starting_track_index + download_index - 1
      if destination_index < initial_track_count then
        local destination_track = r.GetTrack(0, destination_index)
        if resolve_existing_track_index(destination_track) ~= destination_index then
          return false, "An existing destination track is missing or invalid.", 0,
            import_failure_info("INVALID_DESTINATION_TRACK", placement_mode, false)
        end
        starting_track_plan[download_index] = { track = destination_track }
      else
        starting_track_plan[download_index] = { create_at_bottom = true }
      end
    end
  end

  local old_cursor = r.GetCursorPosition()
  local old_selected_tracks = snapshot_selected_tracks()
  local inserted_count = 0
  local undo_started = false
  local refresh_started = false

  local ok_import, import_err = xpcall(function()
    r.Undo_BeginBlock2(0)
    undo_started = true
    r.PreventUIRefresh(1)
    refresh_started = true

    local insert_index = placement_mode == IMPORT_MODE_BELOW_SOURCE
      and resolve_source_insert_index(record)
      or nil

    for download_index, download in ipairs(valid_downloads) do
      local destination_track, create_err
      if placement_mode == IMPORT_MODE_STARTING_AT_TRACK then
        local planned_destination = starting_track_plan[download_index] or {}
        if planned_destination.track then
          destination_track = planned_destination.track
        else
          destination_track, create_err = create_track_at_bottom(cleaned_track_title(download))
        end
      else
        if insert_index then
          destination_track, create_err = create_track_at_index(insert_index, cleaned_track_title(download))
          insert_index = insert_index + 1
        else
          destination_track, create_err = create_track_at_bottom(cleaned_track_title(download))
        end
      end
      if not destination_track then
        error(create_err or "Failed to create destination track.")
      end
      r.Main_OnCommand(40297, 0)
      r.SetMediaTrackInfo_Value(destination_track, "I_SELECTED", 1)
      r.SetEditCurPos(tonumber(record.track_position) or 0, false, false)
      r.InsertMedia(download.local_path, 0)
      download.imported = true
      inserted_count = inserted_count + 1
    end
  end, function(err)
    return debug.traceback(err, 2)
  end)

  if refresh_started then r.PreventUIRefresh(-1) end
  if undo_started then r.Undo_EndBlock2(0, "MVSEP add results to project", 4) end
  restore_selected_tracks(old_selected_tracks)
  r.SetEditCurPos(old_cursor, false, false)
  r.UpdateArrange()

  if not ok_import then
    return false, tostring(import_err), inserted_count,
      import_failure_info("IMPORT_FAILED", placement_mode, undo_started)
  end

  return true, "ok", inserted_count, {
    placement_mode = placement_mode,
    mutation_started = undo_started
  }
end

function MVSepReaper.import_downloads_to_bottom(record)
  return MVSepReaper.import_downloads(record, {
    mode = IMPORT_MODE_BELOW_SOURCE
  })
end

return MVSepReaper
