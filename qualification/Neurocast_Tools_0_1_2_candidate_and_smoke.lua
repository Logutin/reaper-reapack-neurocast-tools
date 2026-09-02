local r = assert(reaper, "REAPER API is required")

local TITLE = "Neurocast Tools 0.1.2 candidate"
local EXPECTED_RESOURCE_PATH = [[C:\extra_Reapers\Reaper_Empty_01]]
local CANDIDATE_FEED_URL = "http://127.0.0.1:8765/index.xml"
local REAL_FEED_NAME = "Neurocast Tools"

local function normalize_windows_path(value)
  local normalized = tostring(value or ""):gsub("/", "\\"):gsub("\\+$", "")
  return normalized:lower()
end

local function join_path(...)
  local parts = { ... }
  return table.concat(parts, "\\"):gsub("\\+", "\\")
end

local function read_file(path)
  local handle, open_err = io.open(path, "rb")
  if not handle then return nil, open_err end
  local body = handle:read("*a")
  handle:close()
  return body, nil
end

local function show_error(message)
  r.ShowMessageBox(tostring(message or "Unknown error"), TITLE, 0)
end

local actual_resource_path = tostring(r.GetResourcePath and r.GetResourcePath() or "")
if normalize_windows_path(actual_resource_path) ~= normalize_windows_path(EXPECTED_RESOURCE_PATH) then
  show_error(
    "STOP: this helper may run only in the authorized disposable REAPER.\n\n" ..
    "Expected resource path:\n" .. EXPECTED_RESOURCE_PATH .. "\n\n" ..
    "Actual resource path:\n" .. actual_resource_path .. "\n\n" ..
    "No repository or project state was changed."
  )
  return
end

local package_root = join_path(actual_resource_path, "Scripts", "Neurocast Tools", "Neurocast_Tools")
local entrypoint_path = join_path(package_root, "mvsep_tool.lua")
local adapter_path = join_path(package_root, "modules-neurocast", "mvsep_reaper.lua")
local entrypoint_source = read_file(entrypoint_path)
local adapter_source = read_file(adapter_path)

local candidate_markers_ok = entrypoint_source ~= nil
  and adapter_source ~= nil
  and entrypoint_source:find('local SCRIPT_VERSION = "v0.2.0"', 1, true) ~= nil
  and entrypoint_source:find('Select exactly one track, make time selection', 1, true) ~= nil
  and entrypoint_source:find('ADD_TO_PROJECT_MODE_STARTING_AT_TRACK = "starting_at_track"', 1, true) ~= nil
  and entrypoint_source:find('concurrency = "concurrency"', 1, true) ~= nil
  and entrypoint_source:find('Free mode', 1, true) == nil
  and entrypoint_source:find('Track + project regions', 1, true) == nil
  and adapter_source:find('function MVSepReaper.import_downloads(record, placement)', 1, true) ~= nil
  and adapter_source:find('INVALID_DESTINATION_TRACK', 1, true) ~= nil

if not candidate_markers_ok then
  if type(r.ReaPack_AddSetRepository) ~= "function" or type(r.ReaPack_ProcessQueue) ~= "function" then
    show_error(
      "The 0.1.2 candidate payload is not installed and ReaPack 1.2.6 APIs are unavailable.\n\n" ..
      "No project state was changed."
    )
    return
  end

  local answer = r.ShowMessageBox(
    "The 0.1.2 candidate payload is not installed yet.\n\n" ..
    "Configure and synchronize the local candidate feed now?\n\n" ..
    CANDIDATE_FEED_URL .. "\n\n" ..
    "This changes only the disposable ReaPack repository setting. It does not change the REAPER project.",
    TITLE,
    4
  )
  if answer ~= 6 then return end

  local ok_feed, feed_err = r.ReaPack_AddSetRepository(REAL_FEED_NAME, CANDIDATE_FEED_URL, true, 2)
  if not ok_feed then
    show_error("Failed to configure the candidate feed:\n\n" .. tostring(feed_err or "Unknown error"))
    return
  end
  r.ReaPack_ProcessQueue(true)
  if type(r.ReaPack_BrowsePackages) == "function" then
    r.ReaPack_BrowsePackages("Neurocast Tools")
  end
  r.ShowMessageBox(
    "Candidate feed configured and synchronized.\n\n" ..
    "In ReaPack, apply the Neurocast Tools update to 0.1.2. Then run this same helper again.\n\n" ..
    "No project state was changed.",
    TITLE,
    0
  )
  return
end

local missing = {}
local required_files = {
  "modules-neurocast\\Util.lua",
  "modules-neurocast\\Files.lua",
  "modules-neurocast\\Curl.lua",
  "modules-neurocast\\Jobs.lua",
  "modules-neurocast\\Cleanup.lua",
  "modules-neurocast\\json.lua",
  "modules-neurocast\\mvsep_api.lua",
  "modules-neurocast\\mvsep_api_via_neurocast.lua",
  "modules-neurocast\\neurocast_auth.lua",
  "modules-neurocast\\mvsep_model_options.lua",
  "modules-neurocast\\mvsep_reaper.lua",
  "modules-neurocast\\Telemetry.lua",
  "modules-neurocast\\mvsep_tool_languages.lua"
}

for _, relative_path in ipairs(required_files) do
  local body = read_file(join_path(package_root, relative_path))
  if body == nil then missing[#missing + 1] = relative_path end
end
if type(r.ImGui_GetBuiltinPath) ~= "function" then missing[#missing + 1] = "ReaImGui" end
if type(r.cyr_essentials_Preview_PlayFile) ~= "function" then
  missing[#missing + 1] = "reaper_cyr_essentials_Preview_PlayFile"
end
if type(r.cyr_essentials_Preview_Stop) ~= "function" then
  missing[#missing + 1] = "reaper_cyr_essentials_Preview_Stop"
end

if #missing > 0 then
  show_error(
    "The 0.1.2 payload markers are present, but required dependencies are missing:\n\n" ..
    table.concat(missing, "\n") .. "\n\nNo project state was changed."
  )
  return
end

r.ShowConsoleMsg(
  "\nNeurocast Tools 0.1.2 minimal smoke\n" ..
  "Candidate markers and dependencies: PASS\n" ..
  "Opening packaged MVSEP UI from:\n" .. entrypoint_path .. "\n\n" ..
  "Minimal visual check only:\n" ..
  "1. Title shows script v0.2.0 / toolset v0.2.0.\n" ..
  "2. Queue is time-selection-only; Free/Regions controls are absent.\n" ..
  "3. Concurrency control and Add results to selector are visible.\n" ..
  "4. Set up any track/time selection yourself only if you want to inspect the dynamic queue label.\n" ..
  "Do not submit a remote job for this release gate.\n\n"
)

local ok_launch, launch_err = xpcall(function()
  dofile(entrypoint_path)
end, debug.traceback)
if not ok_launch then
  show_error(
    "Candidate markers and dependencies passed, but the packaged MVSEP UI failed to open:\n\n" ..
    tostring(launch_err or "Unknown error") .. "\n\nNo project state was changed by this helper."
  )
end
