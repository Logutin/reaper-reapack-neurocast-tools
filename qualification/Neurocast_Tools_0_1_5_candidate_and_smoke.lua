-- Owner-run candidate helper; excluded from the installed package.
-- Only the named disposable installation may change its Neurocast feed.
-- API reference: https://www.reaper.fm/sdk/reascript/reascripthelp.html
-- ReaPack calls retain the previously qualified repository setup pattern.
local r = assert(reaper, "Run this helper inside the authorized disposable REAPER.")
local TITLE = "Neurocast Tools 0.1.5 candidate"
local EXPECTED = [[C:\extra_Reapers\Reaper_Empty_01]]
local FEED = "https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/qualification/Neurocast_Tools_0.1.5_candidate.xml"
local function normalize(path)
  return tostring(path or ""):gsub("/", "\\"):gsub("\\+$", ""):lower()
end
local function message(text)
  r.ShowMessageBox(text, TITLE, 0)
end
if normalize(r.GetResourcePath()) ~= normalize(EXPECTED)
  or normalize(r.GetExePath()) ~= normalize(EXPECTED) then
  message("STOP: open this helper only in:\n" .. EXPECTED .. "\\reaper.exe\n\nNo settings were changed.")
  return
end
if type(r.ReaPack_AddSetRepository) ~= "function"
  or type(r.ReaPack_ProcessQueue) ~= "function"
  or type(r.ReaPack_BrowsePackages) ~= "function" then
  message("Required ReaPack APIs are unavailable. Report this message to Codex.")
  return
end
if type(r.ImGui_CreateContext) ~= "function" then
  message("ReaImGui is unavailable. Report this message to Codex.")
  return
end
local root = EXPECTED .. [[\Scripts\Neurocast Tools\Neurocast_Tools\]]
local function read(path)
  local file = io.open(root .. path, "rb")
  if not file then return "" end
  local body = file:read("*a")
  file:close()
  return body
end
local source_markers = read("elevenlabs_manager_tool.lua"):find('local SCRIPT_VERSION = "v0.2.2"', 1, true)
if source_markers then
  message("Manager v0.2.2 source marker is present. This is not a package byte/receipt verification.\n\n" ..
    "Open the installed elevenlabs_manager_tool.lua from the Actions list.\n" ..
    "Confirm v0.2.2 opens without a missing-module or Lua error, then close it normally.\n\n" ..
    "Report your observations to Codex. Exact package byte/action readback and publication follow your live confirmation.")
  return
end
local ok, err = r.ReaPack_AddSetRepository("Neurocast Tools", FEED, true, 0)
if not ok then
  message("Could not set the candidate feed:\n" .. tostring(err))
  return
end
r.ReaPack_ProcessQueue(true)
r.ReaPack_BrowsePackages("Neurocast Tools")
message("The separate 0.1.5 candidate feed is configured with manual installation.\n\n" ..
  "Wait for synchronization. Select Neurocast Tools 0.1.5, apply the update, then run this helper again.\n\n" ..
  "The public feed remains at 0.1.4. This helper does not start tools, submit jobs, or change your project.")
