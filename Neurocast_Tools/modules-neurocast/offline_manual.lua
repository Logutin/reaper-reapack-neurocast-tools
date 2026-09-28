-- Open a bundled HTML manual without blocking the REAPER defer loop.
-- No network, project paths, shell-interpolated user data, or required SWS dependency.
local Base64 = require("modules-neurocast.base64_encode_decode")
local M = {}

M.relative_path = "manuals/2026-09-28_elevenlabs_tool_manual_ru_draft.html"

function M.path(script_directory)
  return tostring(script_directory):gsub("[/\\]+$", "") .. "/" .. M.relative_path
end

local function ps_utf8_literal(value)
  return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" .. Base64.encode_std(value) .. "'))"
end

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Returns a native command line; path data is never interpreted as shell code.
function M.launch_command(platform, target, receipt, script)
  if platform:match("^Win") then
    local command = "$ErrorActionPreference='Stop';$target=" .. ps_utf8_literal(target)
      .. ";$receipt=" .. ps_utf8_literal(receipt)
      .. ";try{$info=New-Object Diagnostics.ProcessStartInfo;"
      .. "$info.FileName=$target;$info.UseShellExecute=$true;"
      .. "[void][Diagnostics.Process]::Start($info);"
      .. "if([IO.File]::Exists($receipt)){[IO.File]::WriteAllText($receipt,'ok')}}"
      .. "catch{if([IO.File]::Exists($receipt)){[IO.File]::WriteAllText($receipt,'error')}}"
    -- The command above is ASCII. PowerShell -EncodedCommand expects UTF-16LE.
    local utf16 = command:gsub(".", function(c) return c .. "\0" end)
    return "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand "
      .. Base64.encode_std(utf16)
  end
  if platform:match("^OSX") or platform:match("^macOS") then
    local file, err = io.open(script, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write("#!/bin/sh\nif /usr/bin/open " .. shell_quote(target)
      .. " >/dev/null 2>&1; then result=ok; else result=error; fi\n"
      .. "if [ -f " .. shell_quote(receipt) .. " ]; then printf '%s' \"$result\" > " .. shell_quote(receipt) .. "; fi\n")
    local closed = file:close()
    if not ok or not closed then return nil, write_err end
    -- ExecProcess parses this command directly, without /bin/sh -c.
    if script:find('["\r\n]') then return nil, "unsupported temporary path" end
    return '/bin/sh "' .. script .. '"'
  end
  return nil, "unsupported platform"
end

function M.cleanup(request)
  if not request then return end
  if request.receipt then os.remove(request.receipt) end
  if request.script then os.remove(request.script) end
end

-- Success means the OS accepted an open request, not that a browser rendered it.
-- Result: true = dispatched, nil = pending with request, false = reason code.
function M.open(r, target)
  if not r.file_exists(target) then return false, "missing" end
  if type(r.CF_ShellExecute) == "function" then
    local ok, accepted = pcall(r.CF_ShellExecute, target)
    if ok and accepted == true then return true end
    return false, "launch"
  end
  if type(r.ExecProcess) ~= "function" then return false, "launch" end
  local platform = r.GetOS()
  if not (platform:match("^Win") or platform:match("^OSX") or platform:match("^macOS")) then
    return false, "unsupported"
  end
  local ok_tmp, receipt = pcall(os.tmpname)
  if not ok_tmp or not receipt then return false, "temporary" end
  local request = { receipt = receipt, script = receipt .. ".sh", started = r.time_precise() }
  local file = io.open(receipt, "wb")
  if not file then M.cleanup(request); return false, "temporary" end
  file:close()
  local command = M.launch_command(platform, target, receipt, request.script)
  if not command then M.cleanup(request); return false, "temporary" end
  local ok_launch, result = pcall(r.ExecProcess, command, -2)
  if not ok_launch or result == nil or result == "" then
    M.cleanup(request)
    return false, "launch"
  end
  return nil, request
end

function M.poll(r, request)
  local file = io.open(request.receipt, "rb")
  local result = file and file:read(32) or ""
  if file then file:close() end
  if result == "ok" then M.cleanup(request); return true end
  if result == "error" then M.cleanup(request); return false, "launch" end
  if r.time_precise() - request.started >= 20 then
    M.cleanup(request)
    return false, "timeout"
  end
  return nil
end

return M
