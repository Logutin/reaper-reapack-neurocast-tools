-- Owner-run candidate helper, excluded from the package.
-- Uses the previously qualified ReaPack setup flow; never starts processing.
local r = assert(reaper, "Run inside the authorized disposable REAPER.")
local TITLE = "Neurocast Tools 0.1.9 candidate"
local EXPECTED = [[C:\extra_Reapers\Reaper_Empty_01]]
local FEED = "https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/qualification/Neurocast_Tools_0.1.9_candidate.xml"
local function normalize(path)
  return tostring(path or ""):gsub("/", "\\"):gsub("\\+$", ""):lower()
end
local function message(text) r.ShowMessageBox(text, TITLE, 0) end
if normalize(r.GetResourcePath()) ~= normalize(EXPECTED)
  or normalize(r.GetExePath()) ~= normalize(EXPECTED) then
  message("STOP: run only in:\n" .. EXPECTED .. "\\reaper.exe\n\nNo settings changed.")
  return
end
if type(r.ReaPack_AddSetRepository) ~= "function"
  or type(r.ReaPack_ProcessQueue) ~= "function"
  or type(r.ReaPack_BrowsePackages) ~= "function"
  or type(r.ImGui_CreateContext) ~= "function" then
  message("ReaPack or ReaImGui is unavailable. Report this message to Codex.")
  return
end
local root = EXPECTED .. [[\Scripts\Neurocast Tools\Neurocast_Tools\]]
local function read(path)
  local file = io.open(root .. path, "rb")
  if not file then return "" end
  local body = file:read("*a"); file:close(); return body
end
local installed = read("elevenlabs_tool.lua"):find('local SCRIPT_VERSION = "v2.1.7"', 1, true)
  and read("manuals/2026-09-28_elevenlabs_tool_manual_ru.html"):find('manual-sts-source-snapshot" content="2026-10-09"', 1, true)
if installed then
  message("ElevenLabs v2.1.7 and the refreshed manual are present. Exact package receipt/bytes will be checked separately.\n\n" ..
    "Open installed elevenlabs_tool.lua from Actions. Confirm v2.1.7 opens without errors and STS explains that items without audio and tracks without a matching voice are skipped.\n" ..
    "Click Help / Помощь. Confirm the STS chapter explains select-all and skipped tracks (09.10.2026 update). Close the tool normally.\n\n" ..
    "No login, paid request or repeat processing test is needed. Report whether this packaged check passed.")
  return
end
local ok, err = r.ReaPack_AddSetRepository("Neurocast Tools", FEED, true, 0)
if not ok then message("Cannot set candidate feed:\n" .. tostring(err)); return end
r.ReaPack_ProcessQueue(true)
r.ReaPack_BrowsePackages("Neurocast Tools")
message("The 0.1.9 candidate feed is configured for manual installation.\n\n" ..
  "Wait for synchronization, select Neurocast Tools 0.1.9 and apply the update. Then run this helper again.\n\n" ..
  "Public feed remains 0.1.8 until the packaged check passes. This helper does not start tools, submit jobs or edit your project.")
