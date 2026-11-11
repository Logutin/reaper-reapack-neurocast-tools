-- Owner-run candidate helper, excluded from the package.
-- Uses the previously qualified ReaPack setup flow; never starts processing.
local r = assert(reaper, "Run inside the authorized disposable REAPER.")
local TITLE = "Neurocast Tools 0.1.10 candidate"
local EXPECTED = [[C:\extra_Reapers\Reaper_Empty_01]]
local FEED = "https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/qualification/Neurocast_Tools_0.1.10_candidate.xml"
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
local installed = read("elevenlabs_tool.lua"):find('local SCRIPT_VERSION = "v2.1.12"', 1, true)
  and read("modules-neurocast/pronunciation_context.lua") ~= ""
  and read("manuals/2026-10-28_automix_tool_manual_ru.html") ~= ""
  and read("manuals/2026-10-28_mvsep_tool_manual_ru.html") ~= ""
  and read("manuals/2026-10-28_neurocast_script_aligner_tool_manual_ru.html") ~= ""
  and read("manuals/2026-10-28_elevenlabs_manager_tool_manual_ru.html") ~= ""
if installed then
  message("The v2.1.12 entrypoint, IPA helper and four new manuals are present. Exact receipt/bytes will be checked separately.\n\n" ..
    "Open installed ElevenLabs from Actions. Confirm v2.1.12 starts and TTS > Pronunciation / IPA expands without an error. Your source listening test is already passed.\n" ..
    "Open Help in ElevenLabs, AutoMix, MVSEP, Script Aligner and ElevenLabs Manager. Confirm each opens its own installed manual, readable offline. Close the tools normally.\n\n" ..
    "No paid generation, provider processing or balance mutation is needed. Production backend rollout is separate; do not test new IPA routes against old production. Report whether this packaged startup/Help check passed.")
  return
end
local ok, err = r.ReaPack_AddSetRepository("Neurocast Tools", FEED, true, 0)
if not ok then message("Cannot set candidate feed:\n" .. tostring(err)); return end
r.ReaPack_ProcessQueue(true)
r.ReaPack_BrowsePackages("Neurocast Tools")
message("The 0.1.10 candidate feed is configured for manual installation.\n\n" ..
  "Wait for synchronization, select Neurocast Tools 0.1.10 and apply the update. Then run this helper again.\n\n" ..
  "Public feed remains 0.1.9 until the packaged check passes. This helper does not start tools, submit jobs or edit your project.")
