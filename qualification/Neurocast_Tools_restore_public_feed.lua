local r = assert(reaper, "REAPER API is required")

local TITLE = "Neurocast Tools: restore public feed"
local EXPECTED_RESOURCE_PATH = [[C:\extra_Reapers\Reaper_Empty_01]]
local PUBLIC_FEED_URL = "https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml"
local REPOSITORY_NAME = "Neurocast Tools"

local function normalize_windows_path(value)
  local normalized = tostring(value or ""):gsub("/", "\\"):gsub("\\+$", "")
  return normalized:lower()
end

local actual_resource_path = tostring(r.GetResourcePath and r.GetResourcePath() or "")
if normalize_windows_path(actual_resource_path) ~= normalize_windows_path(EXPECTED_RESOURCE_PATH) then
  r.ShowMessageBox(
    "STOP: this helper may run only in the authorized disposable REAPER.\n\n" ..
    "Expected resource path:\n" .. EXPECTED_RESOURCE_PATH .. "\n\n" ..
    "Actual resource path:\n" .. actual_resource_path .. "\n\n" ..
    "No repository or project state was changed.",
    TITLE,
    0
  )
  return
end

if type(r.ReaPack_AddSetRepository) ~= "function" or type(r.ReaPack_ProcessQueue) ~= "function" then
  r.ShowMessageBox("Required ReaPack APIs are unavailable.", TITLE, 0)
  return
end

local answer = r.ShowMessageBox(
  "Restore the Neurocast Tools repository to the published raw-GitHub feed?\n\n" ..
  PUBLIC_FEED_URL .. "\n\n" ..
  "This changes only the disposable ReaPack repository setting. It does not change the REAPER project.",
  TITLE,
  4
)
if answer ~= 6 then return end

local ok_feed, feed_err = r.ReaPack_AddSetRepository(REPOSITORY_NAME, PUBLIC_FEED_URL, true, 2)
if not ok_feed then
  r.ShowMessageBox(
    "Failed to restore the published feed:\n\n" .. tostring(feed_err or "Unknown error"),
    TITLE,
    0
  )
  return
end

r.ReaPack_ProcessQueue(true)
r.ShowMessageBox(
  "The Neurocast Tools repository now uses the published feed.\n\n" ..
  "No REAPER project state was changed.",
  TITLE,
  0
)
