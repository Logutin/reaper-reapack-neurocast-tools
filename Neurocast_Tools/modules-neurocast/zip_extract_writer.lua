-- Extract exact archive members to preallocated project paths without overwriting.
-- Media bytes never pass through PowerShell's text pipeline or a result subfolder.
local r = assert(reaper, "REAPER API required")
local Files = require("modules-neurocast.Files")
local Util = require("modules-neurocast.Util")
local Writer = {}

local function ps_literal(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function windows_argument(value)
  local text = tostring(value):gsub('(\\*)"', '%1%1\\"'):gsub('(\\+)$', '%1%1')
  return '"' .. text .. '"'
end

local function windows_script(tool, archive, items, log_path)
  local lines = {
    "$ErrorActionPreference = 'Stop'",
    "$logPath = " .. ps_literal(log_path),
    "$toolPath = " .. ps_literal(tool),
    "$ownedPaths = New-Object 'System.Collections.Generic.List[string]'",
    "$success = $false",
    "[IO.File]::WriteAllText($logPath, '', [Text.Encoding]::UTF8)",
    "function Write-Diagnostic([string]$message) { [IO.File]::AppendAllText($logPath, $message + [Environment]::NewLine, [Text.Encoding]::UTF8) }",
    "try {"
  }
  for _, item in ipairs(items) do
    local args = {"e", "-so", "-spd", "-y", archive, "--", item.entry}
    for i, value in ipairs(args) do args[i] = windows_argument(value) end
    lines[#lines + 1] = "$targetPath = " .. ps_literal(item.path)
    lines[#lines + 1] = "$arguments = " .. ps_literal(table.concat(args, " "))
    lines[#lines + 1] = [=[
  Write-Diagnostic ('Extracting to: ' + $targetPath)
  $stream = $null
  $process = $null
  try {
    $stream = [IO.File]::Open($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $ownedPaths.Add($targetPath)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $toolPath
    $info.Arguments = $arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Could not start 7-Zip.' }
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardOutput.BaseStream.CopyTo($stream)
    $process.WaitForExit()
    Write-Diagnostic ($stderrTask.GetAwaiter().GetResult())
    Write-Diagnostic ('7zip_exit_code=' + $process.ExitCode)
    if ($process.ExitCode -ne 0) { throw '7-Zip extraction failed.' }
    $stream.Flush()
    if ($stream.Length -le 0) { throw 'Extracted audio is empty.' }
  } finally {
    if ($null -ne $process) {
      try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch {}
      $process.Dispose()
    }
    if ($null -ne $stream) { $stream.Dispose() }
  }
]=]
  end
  lines[#lines + 1] = [=[
  Write-Diagnostic 'archive_extract_ok=true'
  $success = $true
} catch {
  Write-Diagnostic ($_.Exception.ToString())
} finally {
  if (-not $success) {
    foreach ($ownedPath in $ownedPaths) {
      try { [IO.File]::Delete($ownedPath) } catch { Write-Diagnostic ('Partial-file cleanup failed: ' + $_.Exception.Message) }
    }
  }
}
if ($success) { exit 0 } else { exit 1 }
]=]
  -- Windows PowerShell 5.1 needs the BOM to read Unicode literal paths correctly.
  return "\239\187\191" .. table.concat(lines, "\n")
end

local function posix_script(tool, archive, items, log_path)
  local quote = Util.shell_quote
  local lines = {"#!/bin/sh", ": > " .. quote(log_path) .. " || exit 1", "exec 2>> " .. quote(log_path), "success=0", "cleanup() {", "  if [ \"$success\" != 1 ]; then"}
  for i, item in ipairs(items) do
    lines[#lines + 1] = "    [ \"${owned_" .. i .. ":-0}\" != 1 ] || rm -f -- " .. quote(item.path)
  end
  lines[#lines + 1] = "  fi\n}\ntrap cleanup EXIT\nset -C"
  for i, item in ipairs(items) do
    -- unzip treats member arguments as patterns even when shell-quoted.
    local member = item.entry:gsub("([\\%[%]%*%?])", "\\%1")
    lines[#lines + 1] = "printf '%s\\n' " .. quote("Extracting to: " .. item.path) .. " >> " .. quote(log_path)
    -- noclobber makes opening the actual output atomic; a late collision fails.
    lines[#lines + 1] = "exec 3> " .. quote(item.path) .. " || exit 1"
    lines[#lines + 1] = "owned_" .. i .. "=1"
    lines[#lines + 1] = quote(tool) .. " -p " .. quote(archive) .. " " .. quote(member) .. " >&3"
    lines[#lines + 1] = "tool_status=$?\nexec 3>&-"
    lines[#lines + 1] = "printf 'unzip_exit_code=%s\\n' \"$tool_status\" >> " .. quote(log_path)
    lines[#lines + 1] = "[ \"$tool_status\" = 0 ] && [ -s " .. quote(item.path) .. " ] || exit 1"
  end
  lines[#lines + 1] = "printf 'archive_extract_ok=true\\n' >> " .. quote(log_path)
  lines[#lines + 1] = "success=1\nexit 0\n"
  return table.concat(lines, "\n")
end

function Writer.run(tool, archive, items, log_path, timeout_ms)
  local windows = Util.is_windows()
  local script_dir = windows and (os.getenv("TEMP") or os.getenv("TMP")) or "/tmp"
  if not script_dir or script_dir == "" then
    return {ok=false, error="Temporary script directory is unavailable."}
  end
  local script_path = Util.path_join(script_dir, "neurocast_zip_extract_" .. Util.date_time_stamp_with_time_precise() .. (windows and ".ps1" or ".sh"))
  local body = windows and windows_script(tool, archive, items, log_path) or posix_script(tool, archive, items, log_path)
  local written, write_err = Files.write_file(script_path, body)
  if not written then return {ok=false, error=write_err, script_path=script_path} end
  local command = windows
    and ("powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " .. windows_argument(script_path))
    or ("/bin/sh " .. Util.shell_quote(script_path))
  local output = r.ExecProcess(command, timeout_ms)
  local code = output and tonumber(tostring(output):match("^([^\r\n]*)"))
  return {
    ok = output ~= nil,
    error = output == nil and "ExecProcess returned nil" or nil,
    exit_code = code,
    exit_code_label = "REAPER ExecProcess script exit code",
    warning = code ~= 0 and ("Extraction script exit code: " .. tostring(code or "unavailable")) or nil,
    script_path = script_path
  }
end

return Writer
