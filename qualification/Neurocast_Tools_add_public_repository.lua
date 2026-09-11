local r = reaper
local url = "https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/main/index.xml"
local has_reapack = type(r.ReaPack_AddSetRepository) == "function"
  and type(r.ReaPack_ProcessQueue) == "function"
local has_imgui = type(r.ImGui_CreateContext) == "function"
local report = {
  "ReaPack: " .. (has_reapack and "available" or "missing or not loaded"),
  "ReaImGui: " .. (has_imgui and "available" or "missing or not loaded")
}

if has_reapack then
  local ok, err = r.ReaPack_AddSetRepository("Neurocast Tools", url, true, 0)
  if ok then r.ReaPack_ProcessQueue(true) end
  report[#report + 1] = ok and "Neurocast public repository: added/updated (manual install)"
    or "Neurocast public repository: FAILED - " .. tostring(err or "unknown error")
else
  report[#report + 1] = "Neurocast public repository: skipped (ReaPack required)"
end

r.ShowMessageBox(table.concat(report, "\n"), "Neurocast Tools setup", 0)
