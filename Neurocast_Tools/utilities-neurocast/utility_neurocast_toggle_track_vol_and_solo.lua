local TOOLSET_VERSION = "v0.1.1"
local SCRIPT_TITLE = "Neurocast Tools — Toggle track volume and solo " .. TOOLSET_VERSION
local EXTSTATE_SECTION = "neurocast_tools_toggle_track_vol_and_solo"
local SETTER_FILENAME = "utility_neurocast_set_track_for_toggle_track_vol_and_solo.lua"

local has_extstate_in_reaper = {
    state = nil,
    track_number = nil
}
has_extstate_in_reaper.state = reaper.HasExtState(EXTSTATE_SECTION, "toggle_state")
has_extstate_in_reaper.track_number = reaper.HasExtState(EXTSTATE_SECTION, "track_number")
if
    (not has_extstate_in_reaper.state) or
    (not has_extstate_in_reaper.track_number)
    then
        reaper.ShowMessageBox("Run " .. SETTER_FILENAME .. " first!", SCRIPT_TITLE, 0)
        return
    else
        local track_number_string = reaper.GetExtState(EXTSTATE_SECTION, "track_number")
        local track_number = tonumber(track_number_string)
        if (track_number == nil) or (track_number < 1) then
            reaper.ShowMessageBox("Track number state corruption, rerun " .. SETTER_FILENAME .. "!", SCRIPT_TITLE, 0)
            return
        end
        local current_state = reaper.GetExtState(EXTSTATE_SECTION, "toggle_state")
        if (current_state ~= "1") and (current_state ~= "0") then
            reaper.ShowMessageBox("State corruption, rerun " .. SETTER_FILENAME .. "!", SCRIPT_TITLE, 0)
            return
        end
        if current_state == "1" then
            -- now track is on
            -- vol down, unsolo
            local track_object = reaper.GetTrack(0, track_number - 1)
            if not track_object then
                reaper.ShowMessageBox("Track object not found, track number state corruption, rerun " .. SETTER_FILENAME .. "!", SCRIPT_TITLE, 0)
                return
            end
            reaper.SetMediaTrackInfo_Value(track_object, "I_SOLO", 0)
            reaper.SetMediaTrackInfo_Value(track_object, "D_VOL", 0)
            reaper.SetExtState(EXTSTATE_SECTION, "toggle_state", "0", true)
        else
            -- now track is off
            -- vol up, solo
            local track_object = reaper.GetTrack(0, track_number - 1)
            if not track_object then
                reaper.ShowMessageBox("Track object not found, track number state corruption, rerun " .. SETTER_FILENAME .. "!", SCRIPT_TITLE, 0)
                return
            end
            reaper.SetMediaTrackInfo_Value(track_object, "I_SOLO", 1)
            reaper.SetMediaTrackInfo_Value(track_object, "D_VOL", 1)
            reaper.SetExtState(EXTSTATE_SECTION, "toggle_state", "1", true)
        end
end
