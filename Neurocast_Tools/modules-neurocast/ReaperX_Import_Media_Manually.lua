-- Preferred helper for adding existing media files to provided REAPER tracks.
--
-- This module intentionally adds media by reference via PCM_Source_CreateFromFile
-- instead of InsertMedia. Callers own track creation/reuse and file placement.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper

local ImportMedia = {}

ImportMedia.ACTION_REBUILD_PEAKS_FOR_SELECTED_ITEMS = 40441
ImportMedia.ACTION_REBUILD_ALL_PEAKS = 40048
ImportMedia.ACTION_UNSELECT_ALL_ITEMS = 40289

local UNDO_LABEL = "Import media manually by reference"

local function t(text)
  if text == nil then return "" end
  if type(text) ~= "string" then return tostring(text) end
  if type(_G.t) == "function" then
    return _G.t(text)
  end
  return text
end

local function assert_required_api_functions()
  local required_functions = {
    "ValidatePtr2",
    "file_exists",
    "PCM_Source_CreateFromFile",
    "PCM_Source_Destroy",
    "GetMediaSourceLength",
    "AddMediaItemToTrack",
    "AddTakeToMediaItem",
    "SetMediaItemTake_Source",
    "SetMediaItemInfo_Value",
    "SetMediaItemSelected",
    "UpdateItemInProject",
    "GetMediaItemTake_Source",
    "GetMediaSourceFileName",
    "Main_OnCommand",
    "Undo_BeginBlock2",
    "Undo_EndBlock2",
    "PreventUIRefresh",
    "UpdateArrange"
  }

  for i = 1, #required_functions do
    local name = required_functions[i]
    if type(r[name]) ~= "function" then
      error(string.format(
        "Required ReaScript function not found: `%s`. Update REAPER or use this module only inside REAPER.",
        name
      ))
    end
  end
end

assert_required_api_functions()

local function is_finite_number(value)
  local n = tonumber(value)
  if not n then return false, nil end
  if n ~= n then return false, nil end
  if n == math.huge or n == -math.huge then return false, nil end
  return true, n
end

local function validate_track_pointer(track)
  if not track then
    return false
  end
  return r.ValidatePtr2(0, track, "MediaTrack*") == true
end

local function peak_mode_from_opts(opts)
  opts = opts or {}
  local modes = {}

  if opts.trigger_build_peaks_for_added_media == true then
    modes[#modes + 1] = "selected_items_action"
  end
  if opts.trigger_full_project_peaks_rebuild == true then
    modes[#modes + 1] = "full_project_action"
  end
  if opts.build_peaks_manually == true then
    modes[#modes + 1] = "manual_pcm_source_build"
  end

  if #modes > 1 then
    return nil, t("Choose only one peak rebuild option.")
  end

  if modes[1] == "manual_pcm_source_build" then
    return nil, t("Manual PCM_Source_BuildPeaks mode is not implemented in V1.")
  end

  return modes[1], nil
end

local function preflight_media_table(media_table, opts)
  local peak_mode, peak_err = peak_mode_from_opts(opts)
  local result = {
    schema_version = 1,
    created_items = {},
    created_count = 0,
    requested_count = 0,
    peak_mode = peak_mode,
    peak_action_used = nil,
    partial = false,
    error = nil
  }

  if peak_err then
    result.error = peak_err
    return nil, peak_err, result
  end

  if type(media_table) ~= "table" then
    local err = t("Media import table must be a table.")
    result.error = err
    return nil, err, result
  end

  local planned = {}

  for group_index = 1, #media_table do
    local group = media_table[group_index]
    if type(group) ~= "table" then
      local err = string.format(t("Media import group %d must be a table."), group_index)
      result.error = err
      return nil, err, result
    end

    local track = group.track
    if not validate_track_pointer(track) then
      local err = string.format(t("Media import group %d does not have a valid REAPER track."), group_index)
      result.error = err
      return nil, err, result
    end

    if type(group.media_to_add) ~= "table" then
      local err = string.format(t("Media import group %d must include media_to_add."), group_index)
      result.error = err
      return nil, err, result
    end

    for media_index = 1, #group.media_to_add do
      local media = group.media_to_add[media_index]
      if type(media) ~= "table" then
        local err = string.format(t("Media entry %d in group %d must be a table."), media_index, group_index)
        result.error = err
        return nil, err, result
      end

      local ok_position, position = is_finite_number(media.position)
      if not ok_position then
        local err = string.format(t("Media entry %d in group %d must include a finite numeric position."), media_index, group_index)
        result.error = err
        return nil, err, result
      end

      local full_path = tostring(media.full_path or "")
      if full_path == "" then
        local err = string.format(t("Media entry %d in group %d must include full_path."), media_index, group_index)
        result.error = err
        return nil, err, result
      end

      if r.file_exists(full_path) ~= true then
        local err = string.format(t("Media file does not exist: %s"), full_path)
        result.error = err
        return nil, err, result
      end

      planned[#planned + 1] = {
        group_index = group_index,
        media_index = media_index,
        track = track,
        position = position,
        full_path = full_path
      }
    end
  end

  if #planned == 0 then
    local err = t("Media import table must contain at least one media entry.")
    result.error = err
    return nil, err, result
  end

  result.requested_count = #planned
  return planned, nil, result
end

local function create_item_from_plan_item(plan_item, result)
  local media_source = r.PCM_Source_CreateFromFile(plan_item.full_path)
  if not media_source then
    error(string.format(t("Unable to create PCM source from file: %s"), tostring(plan_item.full_path)))
  end

  local media_length, length_is_qn = r.GetMediaSourceLength(media_source)

  if length_is_qn then
    r.PCM_Source_Destroy(media_source)
    error(string.format(t("Media source length is in quarter notes, cannot import as audio: %s"), tostring(plan_item.full_path)))
  end

  if not media_length or media_length <= 0 then
    r.PCM_Source_Destroy(media_source)
    error(string.format(t("Unable to determine positive media source length: %s"), tostring(plan_item.full_path)))
  end

  local item = r.AddMediaItemToTrack(plan_item.track)
  if not item then
    r.PCM_Source_Destroy(media_source)
    error(string.format(t("Failed to create destination media item for: %s"), tostring(plan_item.full_path)))
  end

  local take = r.AddTakeToMediaItem(item)
  if not take then
    r.PCM_Source_Destroy(media_source)
    error(string.format(t("Failed to create take for destination media item: %s"), tostring(plan_item.full_path)))
  end

  local ok_source = r.SetMediaItemTake_Source(take, media_source)
  if ok_source ~= true then
    r.PCM_Source_Destroy(media_source)
    error(string.format(t("Failed to set take source for: %s"), tostring(plan_item.full_path)))
  end

  local created_record = {
    group_index = plan_item.group_index,
    media_index = plan_item.media_index,
    track = plan_item.track,
    item = item,
    take = take,
    source = media_source,
    full_path = plan_item.full_path,
    requested_position = plan_item.position,
    source_length = media_length,
    take_source_filename = ""
  }

  result.created_items[#result.created_items + 1] = created_record
  result.created_count = #result.created_items

  local ok_position = r.SetMediaItemInfo_Value(item, "D_POSITION", plan_item.position)
  if ok_position ~= true and ok_position ~= 1 then
    error(string.format(t("Failed to set media item position for: %s"), tostring(plan_item.full_path)))
  end

  local ok_length = r.SetMediaItemInfo_Value(item, "D_LENGTH", media_length)
  if ok_length ~= true and ok_length ~= 1 then
    error(string.format(t("Failed to set media item length for: %s"), tostring(plan_item.full_path)))
  end

  r.SetMediaItemSelected(item, true)
  r.UpdateItemInProject(item)

  local take_source = r.GetMediaItemTake_Source(take)
  if take_source then
    created_record.take_source_filename = r.GetMediaSourceFileName(take_source) or ""
  end
end

local function trigger_peak_action_if_requested(result)
  if result.peak_mode == "selected_items_action" then
    r.Main_OnCommand(ImportMedia.ACTION_REBUILD_PEAKS_FOR_SELECTED_ITEMS, 0)
    result.peak_action_used = ImportMedia.ACTION_REBUILD_PEAKS_FOR_SELECTED_ITEMS
  elseif result.peak_mode == "full_project_action" then
    r.Main_OnCommand(ImportMedia.ACTION_REBUILD_ALL_PEAKS, 0)
    result.peak_action_used = ImportMedia.ACTION_REBUILD_ALL_PEAKS
  end
end

local function import_planned_media(planned, result)
  r.Main_OnCommand(ImportMedia.ACTION_UNSELECT_ALL_ITEMS, 0)

  for i = 1, #planned do
    create_item_from_plan_item(planned[i], result)
  end

  trigger_peak_action_if_requested(result)
end

function ImportMedia.add_media(media_table, opts)
  opts = opts or {}
  local planned, preflight_err, result = preflight_media_table(media_table, opts)
  if not planned then
    return false, tostring(preflight_err), result
  end

  local manage_transaction = opts.manage_transaction ~= false
  local transaction_started = false
  local refresh_started = false

  local success, runtime_error = xpcall(function()
    if manage_transaction then
      r.Undo_BeginBlock2(0)
      transaction_started = true

      r.PreventUIRefresh(16)
      refresh_started = true
    end

    import_planned_media(planned, result)
  end, function(err)
    return debug.traceback(err, 2)
  end)

  if refresh_started then
    pcall(r.PreventUIRefresh, -16)
  end

  if transaction_started then
    local label = success and UNDO_LABEL or (UNDO_LABEL .. " (failed)")
    pcall(r.Undo_EndBlock2, 0, label, -1)
  end

  if manage_transaction then
    r.UpdateArrange()
  end

  if not success then
    result.partial = result.created_count > 0
    result.error = tostring(runtime_error or t("unknown error"))
    return false, string.format(t("Manual media import failed: %s"), result.error), result
  end

  return true, string.format(t("Imported %d media item(s) by reference."), result.created_count), result
end

return ImportMedia
