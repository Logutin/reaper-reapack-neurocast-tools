local r = reaper

local TOOLSET_VERSION = "v0.1.1"
local SCRIPT_TITLE = "Neurocast Tools — Merge selected item text notes " .. TOOLSET_VERSION
local UNDO_LABEL = "Merge selected item text notes"

local function show_message(message)
  r.ShowMessageBox(tostring(message or "Unknown error."), SCRIPT_TITLE, 0)
end

local function trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function read_item_notes(item)
  local ok, notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  if not ok then
    return nil, "Failed to read item notes."
  end
  return tostring(notes or ""), nil
end

local function sort_by_position_then_selection_index(a, b)
  if a.position ~= b.position then
    return a.position < b.position
  end
  return a.selected_index < b.selected_index
end

local function collect_selected_records()
  local selected_count = tonumber(r.CountSelectedMediaItems(0)) or 0
  if selected_count < 1 then
    return nil, "No media items are selected."
  end

  local records = {}
  local eligible_count = 0

  for selected_index = 0, selected_count - 1 do
    local item = r.GetSelectedMediaItem(0, selected_index)
    if not item then
      return nil, "Failed to get selected media item."
    end

    local track = r.GetMediaItem_Track(item)
    if not track then
      return nil, "Failed to get selected media item's track."
    end

    local notes, read_err = read_item_notes(item)
    if read_err then
      return nil, read_err
    end

    local position = tonumber(r.GetMediaItemInfo_Value(item, "D_POSITION"))
    local length = tonumber(r.GetMediaItemInfo_Value(item, "D_LENGTH"))
    if position == nil or length == nil then
      return nil, "Failed to read selected media item position or length."
    end

    local trimmed_notes = trim(notes)
    if trimmed_notes ~= "" then
      eligible_count = eligible_count + 1
    end

    records[#records + 1] = {
      item = item,
      track = track,
      selected_index = selected_index,
      position = position,
      length = length,
      ending = position + length,
      trimmed_notes = trimmed_notes,
      eligible = trimmed_notes ~= ""
    }
  end

  if eligible_count < 1 then
    return nil, "No selected item has non-empty notes."
  end

  return records, nil
end

local function build_merge_plans(records)
  local groups_by_track = {}
  local groups = {}

  for i = 1, #records do
    local record = records[i]
    if record.eligible then
      local group = groups_by_track[record.track]
      if not group then
        group = { track = record.track, records = {} }
        groups_by_track[record.track] = group
        groups[#groups + 1] = group
      end
      group.records[#group.records + 1] = record
    end
  end

  local plans = {}
  for i = 1, #groups do
    local group_records = groups[i].records
    if #group_records >= 2 then
      table.sort(group_records, sort_by_position_then_selection_index)

      local keep_record = group_records[1]
      local start_position = keep_record.position
      local end_position = keep_record.ending
      local notes = {}
      local delete_records = {}

      for j = 1, #group_records do
        local record = group_records[j]
        if record.position < start_position then
          start_position = record.position
        end
        if record.ending > end_position then
          end_position = record.ending
        end
        notes[#notes + 1] = record.trimmed_notes
        if record ~= keep_record then
          delete_records[#delete_records + 1] = record
        end
      end

      plans[#plans + 1] = {
        track = groups[i].track,
        keep_record = keep_record,
        delete_records = delete_records,
        position = start_position,
        length = end_position - start_position,
        notes = table.concat(notes, " ")
      }
    end
  end

  if #plans < 1 then
    return nil, "No track has at least two selected items with non-empty notes."
  end

  return plans, nil
end

local function assert_api_result(ok, message)
  if not ok then
    error(message, 0)
  end
end

local function apply_merge_plans(plans)
  local refresh_started = false

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(16)
  refresh_started = true

  local ok, err = xpcall(function()
    local selected_count = tonumber(r.CountSelectedMediaItems(0)) or 0
    for selected_index = selected_count - 1, 0, -1 do
      local item = r.GetSelectedMediaItem(0, selected_index)
      if item then
        assert_api_result(r.SetMediaItemInfo_Value(item, "B_UISEL", 0), "Failed to clear item selection.")
      end
    end

    for i = 1, #plans do
      local plan = plans[i]
      local item = plan.keep_record.item

      assert_api_result(r.SetMediaItemInfo_Value(item, "D_POSITION", plan.position), "Failed to set merged item position.")
      assert_api_result(r.SetMediaItemInfo_Value(item, "D_LENGTH", plan.length), "Failed to set merged item length.")
      assert_api_result(r.GetSetMediaItemInfo_String(item, "P_NOTES", plan.notes, true), "Failed to write merged item notes.")
      assert_api_result(r.SetMediaItemInfo_Value(item, "B_UISEL", 1), "Failed to select merged item.")
      r.UpdateItemInProject(item)
    end

    for i = 1, #plans do
      local plan = plans[i]
      for j = 1, #plan.delete_records do
        local record = plan.delete_records[j]
        assert_api_result(r.DeleteTrackMediaItem(record.track, record.item), "Failed to delete merged-away item.")
      end
    end
  end, debug.traceback)

  if refresh_started then
    r.PreventUIRefresh(-16)
  end

  r.Undo_EndBlock2(0, ok and UNDO_LABEL or (UNDO_LABEL .. " (failed)"), -1)
  r.UpdateArrange()

  if not ok then
    return false, err
  end
  return true, nil
end

local records, collect_err = collect_selected_records()
if collect_err then
  show_message(collect_err)
  return
end

local plans, plan_err = build_merge_plans(records)
if plan_err then
  show_message(plan_err)
  return
end

local ok_apply, apply_err = apply_merge_plans(plans)
if not ok_apply then
  show_message("Failed to merge selected item text notes:\n\n" .. tostring(apply_err or "Unknown error."))
end
