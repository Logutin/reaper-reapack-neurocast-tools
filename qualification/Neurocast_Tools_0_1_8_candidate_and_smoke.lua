-- Owner-run candidate helper; excluded from the installed package.
-- Only the named disposable installation may change its Neurocast feed.
-- API reference: https://www.reaper.fm/sdk/reascript/reascripthelp.html
-- ReaPack calls retain the previously qualified repository setup pattern.
local r = assert(reaper, "Run this helper inside the authorized disposable REAPER.")
local TITLE = "Neurocast Tools 0.1.8 candidate"
local EXPECTED = [[C:\extra_Reapers\Reaper_Empty_01]]
local FEED = "https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/qualification/Neurocast_Tools_0.1.8_candidate.xml"
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
local source_markers = read("elevenlabs_tool.lua"):find('local SCRIPT_VERSION = "v2.1.6"', 1, true)
local docx_present = read("docx_import_tool.lua"):find('local SCRIPT_VERSION = "v0.1.1"', 1, true)
local docx_manual_present = read("manuals/2026-10-05_docx_import_tool_manual_ru.html"):find('<html lang="ru">', 1, true)
local helper_present = read("modules-neurocast/offline_manual.lua") ~= ""
local manual_present = read("manuals/2026-09-28_elevenlabs_tool_manual_ru.html"):find('<html lang="ru">', 1, true)
if source_markers and docx_present and docx_manual_present and helper_present and manual_present then
  message("DOCX v0.1.1, ElevenLabs v2.1.6, Help module and both Russian manuals are present. This is not a package byte/receipt verification.\n\n" ..
    "Open the installed docx_import_tool.lua from Actions. Confirm v0.1.1, click Help / Помощь and check the illustrated DOCX manual opens from this installation. Close the tool normally. Then open elevenlabs_tool.lua.\n" ..
    "Confirm v2.1.6 opens without a missing-module or Lua error.\n" ..
    "Click Help / Помощь: the Russian manual should open from this installation's manuals folder.\n" ..
    "Confirm language, status and Help stay on one row, then close the tool normally.\n" ..
    "No login, paid request or audio processing is needed.\n\n" ..
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
message("The separate 0.1.8 candidate feed is configured with manual installation.\n\n" ..
  "Wait for synchronization. Select Neurocast Tools 0.1.8, apply the update, then run this helper again.\n\n" ..
  "The public feed remains at 0.1.7 until the package check passes. This helper does not start tools, submit jobs, or change your project.")
