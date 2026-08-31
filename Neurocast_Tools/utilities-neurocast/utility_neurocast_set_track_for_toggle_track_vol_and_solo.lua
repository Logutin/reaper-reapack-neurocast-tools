local TOOLSET_VERSION = "v0.1.1"
local SCRIPT_TITLE = "Neurocast Tools — Set track for toggle volume and solo " .. TOOLSET_VERSION
local EXTSTATE_SECTION = "neurocast_tools_toggle_track_vol_and_solo"

local retval, retvals_csv = reaper.GetUserInputs(
    SCRIPT_TITLE,
    1,
    "Track number:",
    ""
)

if not retval then
    return
end

local track_number = tonumber(retvals_csv)
if (track_number == nil) or (math.floor(track_number) ~= track_number) or (track_number < 1) then
    reaper.ShowMessageBox("Track number must be a positive integer.", SCRIPT_TITLE, 0)
    return
end

local track = reaper.GetTrack(0, track_number - 1)
if not track then
    reaper.ShowMessageBox("Track object not found for that track number.", SCRIPT_TITLE, 0)
    return
end

local solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") or 0
local toggle_state = (solo ~= 0) and "1" or "0"

reaper.SetExtState(EXTSTATE_SECTION, "track_number", tostring(track_number), true)
reaper.SetExtState(EXTSTATE_SECTION, "toggle_state", toggle_state, true)

reaper.ShowMessageBox(
    "Set. Use utility_neurocast_toggle_track_vol_and_solo.lua",
    SCRIPT_TITLE,
    0
)
