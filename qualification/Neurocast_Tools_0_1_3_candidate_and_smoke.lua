-- Owner-run helper, excluded from the package. Never mutates project state.
-- API references: https://www.reaper.fm/sdk/reascript/reascripthelp.html
-- ReaPack API usage is retained from the qualified 0.1.2 helper.
local r = assert(reaper, "Run this helper inside the authorized disposable REAPER.")
local TITLE = "Neurocast Tools 0.1.3 candidate"
local EXPECTED = [[C:\extra_Reapers\Reaper_Empty_01]]
local FEED = "http://127.0.0.1:8765/index.xml"
local function normalize(path)
  return tostring(path or ""):gsub("/", "\\"):gsub("\\+$", ""):lower()
end
local function message(text)
  r.ShowMessageBox(text, TITLE, 0)
end
if normalize(r.GetResourcePath()) ~= normalize(EXPECTED) then
  message("STOP: run this helper only in:\n" .. EXPECTED ..
    "\n\nNo repository or project state was changed.")
  return
end
local root = EXPECTED .. [[\Scripts\Neurocast Tools\Neurocast_Tools\]]
local function read(relative)
  local file = io.open(root .. relative, "rb")
  if not file then return "" end
  local body = file:read("*a")
  file:close()
  return body
end
local manager = read("elevenlabs_manager_tool.lua")
local tool = read("elevenlabs_tool.lua")
local helper = read([[modules-neurocast\elevenlabs_manager_user_view.lua]])
local adapter = read([[modules-neurocast\elevenlabs_api_via_neurocast.lua]])
local installed = manager:find('local SCRIPT_VERSION = "v0.1.3"', 1, true)
  and tool:find('local SCRIPT_VERSION = "v2.1.1"', 1, true)
  and helper:find("function UserView.build_rows", 1, true)
  and #adapter > 0 and not adapter:find("delete_voice_request", 1, true)

if installed then
  message("Candidate source markers are present.\n\n" ..
    "From the Actions list, open the installed elevenlabs_manager_tool.lua and elevenlabs_tool.lua separately.\n\n" ..
    "Check Manager v0.1.3: Filter works and Users counts change.\n" ..
    "Check ElevenLabs v2.1.1: Account Voices loads and has no permanent deletion controls.\n\n" ..
    "Log in inside REAPER if required. Do not submit generation jobs or change assignments.\n" ..
    "Report the result to Codex; publication is waiting for your confirmation.")
  return
end

if type(r.ReaPack_AddSetRepository) ~= "function"
  or type(r.ReaPack_ProcessQueue) ~= "function"
  or type(r.ReaPack_BrowsePackages) ~= "function" then
  message("Required ReaPack APIs are unavailable. Stop and report this message.")
  return
end
local answer = r.ShowMessageBox(
  "Configure the temporary 0.1.3 candidate feed in this disposable REAPER?\n\n" .. FEED ..
  "\n\nOnly the Neurocast Tools repository setting changes. The project is untouched.\n" ..
  "The public feed will be restored after the live check and publication.", TITLE, 4)
if answer ~= 6 then return end
local ok, err = r.ReaPack_AddSetRepository("Neurocast Tools", FEED, true, 2)
if not ok then
  message("Could not configure the feed:\n" .. tostring(err))
  return
end
r.ReaPack_ProcessQueue(true)
r.ReaPack_BrowsePackages("Neurocast Tools")
message("Wait for ReaPack synchronization, then select Neurocast Tools 0.1.3 and apply the update.\n\n" ..
  "Run this helper again after installation for the two-tool checklist.\n" ..
  "Do not update unrelated packages. No project state was changed by this helper.")
