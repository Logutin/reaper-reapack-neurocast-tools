-- Search all project item notes and add one marker at each matching item start.
-- Requires REAPER 7.72+ because AddRegionOrMarker was introduced in that version.

local r = reaper

local TOOLSET_VERSION = "v0.1.1"
local SCRIPT_TITLE = "Neurocast Tools — Search item notes " .. TOOLSET_VERSION
local UNDO_LABEL = "Add markers for item-note search results"
local MARKER_UNDO_FLAG = 8

-- Check the version-sensitive API before prompting or touching the project.
if type(r.AddRegionOrMarker) ~= "function" then
  r.ShowMessageBox(
    "This script requires REAPER 7.72 or newer.\n\n"
      .. "Your installed REAPER version does not provide the AddRegionOrMarker API. "
      .. "Please update REAPER and run the script again.",
    SCRIPT_TITLE,
    0
  )
  return
end

local function show_message(message)
  r.ShowMessageBox(tostring(message or "Unknown error."), SCRIPT_TITLE, 0)
end

local function collect_item_records()
  local item_count = tonumber(r.CountMediaItems(0)) or 0
  local records = {}

  -- This is a real hot loop in large REAPER projects: it may scan 10,000+ items.
  -- Cache REAPER API functions locally to avoid repeated table lookups on every item.
  local get_item = r.GetMediaItem
  local get_item_notes = r.GetSetMediaItemInfo_String
  local get_item_track = r.GetMediaItem_Track
  local get_track_number = r.GetMediaTrackInfo_Value
  local get_track_name = r.GetTrackName
  local get_item_value = r.GetMediaItemInfo_Value

  -- Phase 1: take a read-only snapshot of every project item before searching.
  -- Keeping all required metadata in Lua separates REAPER API access from text matching
  -- and guarantees that no markers are added if any project item cannot be read.
  for item_index = 0, item_count - 1 do
    local item = get_item(0, item_index)
    if not item then
      return nil, "Failed to get project media item " .. tostring(item_index + 1) .. "."
    end

    local notes_ok, notes = get_item_notes(item, "P_NOTES", "", false)
    if not notes_ok then
      return nil, "Failed to read item notes. Item " .. tostring(item_index + 1) .. "."
    end
    notes = tostring(notes or "")

    local position = tonumber(get_item_value(item, "D_POSITION"))
    if position == nil then
      return nil, "Failed to read item " .. tostring(item_index + 1) .. " position."
    end

    local track = get_item_track(item)
    if not track then
      return nil, "Failed to get the track for item " .. tostring(item_index + 1) .. "."
    end

    local track_number = tonumber(get_track_number(track, "IP_TRACKNUMBER"))
    if not track_number or track_number < 1 then
      return nil, "Failed to read an item's track number."
    end
    track_number = math.floor(track_number)

    local track_name_ok, track_name = get_track_name(track)
    if not track_name_ok then
      return nil, "Failed to read track " .. tostring(track_number) .. " name."
    end

    records[#records + 1] = {
      notes = notes,
      position = position,
      track_number = track_number,
      track_name = tostring(track_name or "")
    }
  end

  return records, nil
end

local function find_matches(records, query)
  local matches = {}

  -- Phase 2: search the in-memory snapshot without further REAPER API calls.
  -- The fourth string.find argument treats the complete user query as literal text,
  -- so Lua pattern symbols such as ".", "%", "+", and "[]" have no special meaning.
  for i = 1, #records do
    local record = records[i]
    if string.find(record.notes, query, 1, true) then
      matches[#matches + 1] = record
    end
  end

  return matches
end

local function has_shared_hit_positions(matches)
  local seen_positions = {}

  for i = 1, #matches do
    local position = matches[i].position
    -- Compare positions at millisecond precision to absorb insignificant float differences.
    local position_ms = math.floor(position * 1000 + 0.5)
    if seen_positions[position_ms] then
      return true
    end
    seen_positions[position_ms] = true
  end

  return false
end

local function add_markers(matches)
  -- Phase 3: mutate the project only after the snapshot and search have succeeded.
  -- Keep every marker from this run in one undo step, including a partial failed run.
  r.Undo_BeginBlock2(0)
  -- Suppress intermediate redraws while adding many markers, then always restore UI updates.
  r.PreventUIRefresh(1)

  local add_region_or_marker = r.AddRegionOrMarker
  local marker_color = r.ColorToNative(0, 255, 0) | 0x1000000

  local ok, err = xpcall(function()
    for i = 1, #matches do
      local match = matches[i]
      local marker = add_region_or_marker(
        0,
        false,
        match.position,
        0,
        string.format(
          "Track %d (%s)",
          match.track_number,
          match.track_name
        ),
        -1,
        marker_color
      )
      if marker == nil or marker == false or marker == -1 then
        error("Failed to add marker " .. tostring(i) .. ".", 0)
      end
    end
  end, debug.traceback)

  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(
    0,
    ok and UNDO_LABEL or (UNDO_LABEL .. " (failed)"),
    MARKER_UNDO_FLAG
  )
  r.UpdateArrange()

  if not ok then
    return false, err
  end
  return true, nil
end

local accepted, query = r.GetUserInputs(
  SCRIPT_TITLE,
  1,
  "Text to find:",
  ""
)
if not accepted then
  return
end

query = tostring(query or "")
if query == "" then
  show_message("Enter non-empty text to search for.")
  return
end

local item_records, collect_err = collect_item_records()
if collect_err then
  show_message(collect_err)
  return
end

local matches = find_matches(item_records, query)
if #matches == 0 then
  show_message("No matching item notes were found.")
  return
end

if has_shared_hit_positions(matches) then
  show_message(
    "Warning: some matching items start at the same project position.\n\n"
      .. "REAPER will create overlapping markers there, so some marker labels "
      .. "may be difficult to see in the arrange view."
  )
end

local ok, add_err = add_markers(matches)
if not ok then
  show_message(
    "Failed to add all search-result markers.\n\n"
      .. tostring(add_err or "Unknown error.")
      .. "\n\nUse Undo to remove any markers that were added."
  )
end
