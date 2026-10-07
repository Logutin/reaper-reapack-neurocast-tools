-- Submit a local HTML file to the system opener. No browser confirmation.
local M = {}

M.relative_path = "manuals/2026-09-28_elevenlabs_tool_manual_ru.html"

function M.path(script_directory, relative_path)
  return tostring(script_directory):gsub("[/\\]+$", "") .. "/" .. (relative_path or M.relative_path)
end

function M.launch_command(platform, target)
  if type(target) ~= "string" or target:find('[\0\r\n]') then return nil, "launch" end
  if platform:match("^Win") then
    local windows = os.getenv("SystemRoot") or os.getenv("WINDIR")
    if not windows or not windows:match("^%a:[/\\]") or windows:find('["\0\r\n]')
      or target:find('"', 1, true) then return nil, "launch" end
    local explorer = windows:gsub("/", "\\"):gsub("\\+$", "") .. "\\explorer.exe"
    return '"' .. explorer .. '" "' .. target:gsub("/", "\\") .. '"'
  end
  if platform:match("^OSX") or platform:match("^macOS") then
    -- ExecProcess receives the executable and one quoted argument, not shell code.
    local argument = target:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '/usr/bin/open "' .. argument .. '"'
  end
  return nil, "unsupported"
end

-- The caller checks manual availability once at startup; never recheck on click.
function M.open(r, target)
  if type(r.ExecProcess) ~= "function" then return false, "launch" end
  local command, reason = M.launch_command(r.GetOS(), target)
  if not command then return false, reason end
  local ok, result = pcall(r.ExecProcess, command, -2)
  if not ok or result == nil or result == "" then return false, "launch" end
  return true
end

return M
