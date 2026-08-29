-- Shared CirilicaTools telemetry runtime for REAPER scripts.
-- This module owns local identity validation, per-session JSONL queues, and
-- best-effort async flushes to the Apps Script telemetry backend.

if not reaper then
  error("Telemetry.lua must run inside Reaper or the repo FakeReaper test harness.")
end

local r = reaper
local json = require("modules-neurocast.json")
local Util = require("modules-neurocast.Util")
local Files = require("modules-neurocast.Files")
local Curl = require("modules-neurocast.Curl")

local Telemetry = {}

local VERSION = "v0.1.0"
local IDENTITY_FILE_NAME = "CirilicaTools_telemetry_identity.json"
local SETTINGS_FILE_NAME = "CirilicaTools_telemetry_settings.json"
local RUNTIME_DIR_NAME = "CirilicaTools_telemetry"
local MAX_EVENTS_PER_BATCH = 50
local MAX_POST_BYTES = 180000
local MAX_DATA_JSON_CHARS = 18000
local MAX_STRING_CHARS = 2048
local MAX_DEPTH = 6
local CLOSE_SEND_MAX_AGE_SEC = 10 * 60
local RETENTION_TICK_INTERVAL_SEC = 60
local FAILED_MAX_AGE_SEC = 30 * 24 * 60 * 60
local FAILED_MAX_TOTAL_BYTES = 10 * 1024 * 1024
local LOG_MAX_AGE_SEC = 14 * 24 * 60 * 60
local LOG_MAX_TOTAL_BYTES = 10 * 1024 * 1024
local DEFAULT_SENDABLE_QUEUE_SOFT_MAX_BYTES = 100 * 1024 * 1024
local DEFAULT_BUDGET_SOFT_EVENTS_PER_SESSION = 10000
local DEFAULT_BUDGET_HARD_EVENTS_PER_SESSION = 15000
local DEFAULT_BUDGET_RESERVED_EVENTS = 250
local HARD_BACKEND_FAILURES_BEFORE_PAUSE = 5

local budget_limits = {
  sendable_queue_soft_max_bytes = DEFAULT_SENDABLE_QUEUE_SOFT_MAX_BYTES,
  soft_events_per_session = DEFAULT_BUDGET_SOFT_EVENTS_PER_SESSION,
  hard_events_per_session = DEFAULT_BUDGET_HARD_EVENTS_PER_SESSION,
  reserved_events = DEFAULT_BUDGET_RESERVED_EVENTS
}

local function reset_budget_limits()
  budget_limits.sendable_queue_soft_max_bytes = DEFAULT_SENDABLE_QUEUE_SOFT_MAX_BYTES
  budget_limits.soft_events_per_session = DEFAULT_BUDGET_SOFT_EVENTS_PER_SESSION
  budget_limits.hard_events_per_session = DEFAULT_BUDGET_HARD_EVENTS_PER_SESSION
  budget_limits.reserved_events = DEFAULT_BUDGET_RESERVED_EVENTS
end

local function apply_budget_limits(limits)
  local src = type(limits) == "table" and limits or {}
  local hard = math.floor(tonumber(src.hard_events_per_session) or DEFAULT_BUDGET_HARD_EVENTS_PER_SESSION)
  local soft = math.floor(tonumber(src.soft_events_per_session) or DEFAULT_BUDGET_SOFT_EVENTS_PER_SESSION)
  local reserved = math.floor(tonumber(src.reserved_events) or DEFAULT_BUDGET_RESERVED_EVENTS)
  local queue_bytes = math.floor(tonumber(src.sendable_queue_soft_max_bytes) or DEFAULT_SENDABLE_QUEUE_SOFT_MAX_BYTES)

  if hard < 1 then hard = DEFAULT_BUDGET_HARD_EVENTS_PER_SESSION end
  if soft < 1 then soft = DEFAULT_BUDGET_SOFT_EVENTS_PER_SESSION end
  if soft > hard then soft = hard end
  if reserved < 0 then reserved = 0 end
  if reserved > hard then reserved = hard end
  if queue_bytes < 1 then queue_bytes = DEFAULT_SENDABLE_QUEUE_SOFT_MAX_BYTES end

  budget_limits.sendable_queue_soft_max_bytes = queue_bytes
  budget_limits.soft_events_per_session = soft
  budget_limits.hard_events_per_session = hard
  budget_limits.reserved_events = reserved
end

local function copy_budget_limits()
  return {
    sendable_queue_soft_max_bytes = budget_limits.sendable_queue_soft_max_bytes,
    soft_events_per_session = budget_limits.soft_events_per_session,
    hard_events_per_session = budget_limits.hard_events_per_session,
    reserved_events = budget_limits.reserved_events
  }
end

local LEVEL_RANK = {
  basic = 1,
  support = 2,
  debug = 3
}

local EVENT_DEFAULT_POLICY = {
  script_started = "basic",
  script_closed = "basic",
  operation_started = "basic",
  operation_completed = "basic",
  operation_canceled = "basic",
  feature_used = "basic",
  telemetry_flush = "basic",
  telemetry_health = "basic",
  telemetry_budget_exhausted = "basic",
  button_clicked = "support",
  error = "support",
  operation_failed = "support",
  network_request_failed = "support",
  render_failed = "support",
  cleanup_failed = "support",
  telemetry_test = "support"
}

local identity = nil
local runtime = {
  initialized = false,
  app_name = "CirilicaTools",
  entrypoint = "unknown",
  script_version = "",
  session_id = "",
  queue_path = "",
  queue_basename = "",
  paths = {},
  flush_requested = false,
  next_flush_at = nil,
  active_job_id = nil,
  active_queue_path = nil,
  active_source_file = nil,
  active_remaining_lines = nil,
  active_batch_event_count = 0,
  active_batch_payload_bytes = 0,
  status = "not initialized",
  last_error = "",
  last_http_code = nil,
  last_curl_exitcode = nil,
  last_backend_error = "",
  last_flush_at = nil,
  queued_events_session = 0,
  flushed_events_session = 0,
  failed_batches_session = 0,
  dropped_events_session = 0,
  skipped_events_session = 0,
  budget_exhausted_emitted = false,
  send_paused = false,
  send_pause_reason = "",
  hard_backend_failures_session = 0,
  last_retention_cleanup_at = nil,
  last_retention_cleanup = nil,
  settings = nil,
  settings_path = "",
  debug_log_unsafe_secrets = false
}

local function log_debug(message, importance)
  Util.msg("[telemetry] " .. tostring(message or ""), importance or 0)
end

local function log_file_only(message)
  if Util.msg_to_log_file ~= true then return false end
  if type(Util.tmp_dir) ~= "string" or Util.tmp_dir == "" then return false end
  if type(Util.log_file_name) ~= "string" or Util.log_file_name == "" then return false end

  if not Util.full_path_to_log_file then
    Util.msg("[telemetry] debug log file initialized", 0)
  end
  if type(Util.full_path_to_log_file) ~= "string" or Util.full_path_to_log_file == "" then
    return false
  end

  local f = io.open(Util.full_path_to_log_file, "a")
  if not f then return false end
  f:write("[" .. Util.date_time_stamp_with_time_precise() .. "]: " .. tostring(message or "") .. "\n")
  f:close()
  return true
end

local function encode_debug_value(value)
  local ok, encoded = pcall(json.encode, value)
  if ok then return encoded end
  return tostring(encoded)
end

local function log_unsafe_debug(label, value, limit)
  if runtime.debug_log_unsafe_secrets ~= true then return end
  local text = tostring(value or "")
  local clipped = Util.clip_text(text, tonumber(limit) or (256 * 1024))
  log_file_only(
    "[telemetry][unsafe_debug] " .. tostring(label or "value") ..
    " bytes=" .. tostring(#text) ..
    "\n--- BEGIN " .. tostring(label or "value") .. " ---\n" ..
    clipped ..
    "\n--- END " .. tostring(label or "value") .. " ---"
  )
end

local function log_artifact_file(label, path, limit)
  if runtime.debug_log_unsafe_secrets ~= true then return end
  if type(path) ~= "string" or path == "" then
    log_file_only("[telemetry][unsafe_debug] " .. tostring(label or "artifact") .. " path=(none)")
    return
  end
  local text, read_or_size = Files.slurp_with_cap(path, tonumber(limit) or (512 * 1024))
  if text then
    log_unsafe_debug(tostring(label or "artifact") .. " path=" .. tostring(path), text, limit)
  else
    log_file_only(
      "[telemetry][unsafe_debug] " .. tostring(label or "artifact") ..
      " path=" .. tostring(path) ..
      " read_failed=" .. tostring(read_or_size)
    )
  end
end

local function compact_curl_meta_for_log(meta)
  if type(meta) ~= "table" then return meta end
  local out = {}
  for k, v in pairs(meta) do
    if tostring(k) == "certs" then
      out.certs = "[omitted from telemetry debug log; bytes=" .. tostring(#tostring(v or "")) .. "]"
    else
      out[k] = v
    end
  end
  return out
end

local function curl_cfg_quote(value)
  local s = tostring(value or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\r", "\\r")
  s = s:gsub("\n", "\\n")
  return '"' .. s .. '"'
end

local function is_non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

local function clip_text(value, limit)
  local text = tostring(value or "")
  local max_len = tonumber(limit) or MAX_STRING_CHARS
  if #text <= max_len then return text end
  return text:sub(1, max_len) .. "... (" .. tostring(#text - max_len) .. " more bytes)"
end

local function file_exists(path)
  if type(path) ~= "string" or path == "" then return false end
  if type(r.file_exists) == "function" then
    return r.file_exists(path) == true
  end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function file_size(path)
  return Files.file_size(path) or 0
end

local function basename(path)
  return tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
end

local function sanitize_filename_part(value, fallback)
  local text = tostring(value or "")
  text = text:gsub("[^%w%._%-]+", "_")
  text = text:gsub("^_+", ""):gsub("_+$", "")
  if text == "" then text = fallback or "telemetry" end
  return text
end

local function make_guid_text()
  if type(r.genGuid) == "function" then
    local ok_guid, guid = pcall(r.genGuid, "")
    if ok_guid and is_non_empty_string(guid) then
      return tostring(guid):gsub("[{}]", "")
    end
  end
  local now = type(r.time_precise) == "function" and r.time_precise() or os.clock()
  return string.format("%08x%08x", math.floor((now or 0) * 1000000) % 0xffffffff, math.random(0, 0xfffffff))
end

local function utc_stamp()
  return os.date("!%Y%m%dT%H%M%SZ")
end

local function utc_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function resource_path()
  if type(r.GetResourcePath) ~= "function" then
    return nil, "REAPER GetResourcePath API is unavailable"
  end
  local path = r.GetResourcePath()
  if not is_non_empty_string(path) then
    return nil, "REAPER Resource Path is empty"
  end
  return path
end

local function identity_path()
  local root, root_err = resource_path()
  if not root then return nil, root_err end
  return Util.path_join(root, IDENTITY_FILE_NAME), nil
end

local function settings_path()
  local root, root_err = resource_path()
  if not root then return nil, root_err end
  return Util.path_join(root, SETTINGS_FILE_NAME), nil
end

local function normalize_level(value, fallback)
  local text = tostring(value or ""):lower()
  if LEVEL_RANK[text] then return text end
  local fb = tostring(fallback or "support"):lower()
  if LEVEL_RANK[fb] then return fb end
  return "support"
end

local function normalize_priority(value, event_name)
  local text = tostring(value or ""):lower()
  if text == "low" or text == "normal" or text == "error" then
    return text
  end
  local name = tostring(event_name or "")
  if name:find("failed", 1, true) or name == "error" or name:find("error", 1, true) then
    return "error"
  end
  if name == "button_clicked" or name == "feature_used" or name == "telemetry_test" then
    return "low"
  end
  return "normal"
end

local function level_allows(policy, effective_level)
  local need = LEVEL_RANK[normalize_level(policy, "support")] or LEVEL_RANK.support
  local have = LEVEL_RANK[normalize_level(effective_level, "support")] or LEVEL_RANK.support
  return have >= need
end

local function ensure_writable_dir(path, label)
  local ok, err = Files.ensure_tmp_dir(path)
  if not ok then
    return false, tostring(label or "directory") .. ": " .. tostring(err)
  end
  return true
end

local function list_jsonl_files(dir_path)
  local files = {}
  if type(dir_path) ~= "string" or dir_path == "" or type(r.EnumerateFiles) ~= "function" then
    return files
  end
  r.EnumerateFiles(dir_path, -1)
  local idx = 0
  while true do
    local name = r.EnumerateFiles(dir_path, idx)
    if not name then break end
    if tostring(name):match("%.jsonl$") then
      files[#files + 1] = Util.path_join(dir_path, name)
    end
    idx = idx + 1
  end
  table.sort(files)
  return files
end

local function list_all_files(dir_path)
  local files = {}
  if type(dir_path) ~= "string" or dir_path == "" or type(r.EnumerateFiles) ~= "function" then
    return files
  end
  r.EnumerateFiles(dir_path, -1)
  local idx = 0
  while true do
    local name = r.EnumerateFiles(dir_path, idx)
    if not name then break end
    files[#files + 1] = Util.path_join(dir_path, name)
    idx = idx + 1
  end
  table.sort(files)
  return files
end

local function count_jsonl_files(dir_path)
  return #list_jsonl_files(dir_path)
end

local function count_all_files(dir_path)
  return #list_all_files(dir_path)
end

local function file_stamp_epoch(path)
  local name = basename(path)
  local epoch = name:match("^telemetry_close_send%.(%d+)%.")
  if epoch then return tonumber(epoch) end
  local y, mo, d, h, mi, s = name:match("(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z")
  if y then
    return os.time({
      year = tonumber(y),
      month = tonumber(mo),
      day = tonumber(d),
      hour = tonumber(h),
      min = tonumber(mi),
      sec = tonumber(s)
    })
  end
  return nil
end

local function collect_file_records(dir_path)
  local records = {}
  local files = list_all_files(dir_path)
  for i = 1, #files do
    local path = files[i]
    records[#records + 1] = {
      path = path,
      size = file_size(path),
      stamp = file_stamp_epoch(path) or 0,
      name = basename(path)
    }
  end
  table.sort(records, function(a, b)
    if a.stamp ~= b.stamp then return a.stamp < b.stamp end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return records
end

local function total_record_bytes(records)
  local total = 0
  for i = 1, #(records or {}) do
    total = total + (tonumber(records[i].size) or 0)
  end
  return total
end

local function total_jsonl_bytes(dir_path)
  local total = 0
  local files = list_jsonl_files(dir_path)
  for i = 1, #files do
    total = total + file_size(files[i])
  end
  return total
end

local function total_sendable_queue_bytes()
  local total = file_size(runtime.queue_path)
  if runtime.paths then
    total = total + total_jsonl_bytes(runtime.paths.queues)
    total = total + total_jsonl_bytes(runtime.paths.sending)
  end
  return total
end

local function cleanup_dir_by_policy(dir_path, max_age_sec, max_total_bytes)
  local records = collect_file_records(dir_path)
  local now_epoch = tonumber(os.time()) or 0
  local deleted = 0
  local failed = 0
  local kept = #records
  local total = total_record_bytes(records)

  for i = 1, #records do
    local rec = records[i]
    local old_enough = rec.stamp and rec.stamp > 0 and now_epoch > 0 and (now_epoch - rec.stamp) > max_age_sec
    if old_enough then
      local ok_remove = os.remove(rec.path)
      if ok_remove or not file_exists(rec.path) then
        deleted = deleted + 1
        kept = kept - 1
        total = total - (tonumber(rec.size) or 0)
        rec.deleted = true
      else
        failed = failed + 1
      end
    end
  end

  if tonumber(max_total_bytes) and total > max_total_bytes then
    for i = 1, #records do
      local rec = records[i]
      if not rec.deleted and total > max_total_bytes then
        local ok_remove = os.remove(rec.path)
        if ok_remove or not file_exists(rec.path) then
          deleted = deleted + 1
          kept = kept - 1
          total = total - (tonumber(rec.size) or 0)
          rec.deleted = true
        else
          failed = failed + 1
        end
      end
    end
  end

  return {
    deleted = deleted,
    kept = kept,
    failed = failed,
    total_bytes = total
  }
end

local function copy_file(src_path, dst_path)
  local data, read_err = Files.slurp_with_cap(src_path, 2 * 1024 * 1024)
  if not data then
    return false, read_err
  end
  return Files.write_file(dst_path, data)
end

local function unique_path_in_dir(dir_path, file_name)
  local target = Util.path_join(dir_path, file_name)
  if not file_exists(target) then return target end
  local stem, ext = file_name:match("^(.*)(%.jsonl)$")
  stem = stem or file_name
  ext = ext or ""
  for i = 2, 999 do
    local candidate = Util.path_join(dir_path, stem .. "." .. tostring(i) .. ext)
    if not file_exists(candidate) then return candidate end
  end
  return Util.path_join(dir_path, stem .. "." .. make_guid_text():sub(1, 12) .. ext)
end

local function move_file_to_dir(src_path, dst_dir)
  local dst_path = unique_path_in_dir(dst_dir, basename(src_path))
  log_debug("move_file_to_dir: src=" .. tostring(basename(src_path)) .. " dst_dir=" .. tostring(basename(dst_dir)))
  local ok_rename, rename_err = os.rename(src_path, dst_path)
  if ok_rename then
    log_debug("move_file_to_dir: renamed to " .. tostring(basename(dst_path)))
    return dst_path, nil
  end

  local ok_copy, copy_err = copy_file(src_path, dst_path)
  if not ok_copy then
    log_debug("move_file_to_dir: copy failed: " .. tostring(copy_err), 2)
    return nil, tostring(rename_err or "rename failed") .. "; copy failed: " .. tostring(copy_err)
  end
  local ok_remove, remove_err = os.remove(src_path)
  if not ok_remove then
    log_debug("move_file_to_dir: remove source failed after copy: " .. tostring(remove_err), 2)
    return nil, "copied to " .. tostring(dst_path) .. " but could not remove source: " .. tostring(remove_err)
  end
  log_debug("move_file_to_dir: copied to " .. tostring(basename(dst_path)) .. " and removed source")
  return dst_path, nil
end

local blocked_key_patterns = {
  "token",
  "password",
  "authorization",
  "oauth",
  "private[_%-]?key",
  "credentials",
  "credential",
  "access[_%-]?token",
  "refresh[_%-]?token",
  "service[_%-]?account",
  "client[_%-]?secret",
  "api[_%-]?key",
  "^key$",
  "[_%-]key$",
  "^el[_%-]?key$",
  "^openai[_%-]?key$"
}

local function should_redact_key(key)
  local lowered = tostring(key or ""):lower()
  for i = 1, #blocked_key_patterns do
    if lowered:find(blocked_key_patterns[i]) then
      return true
    end
  end
  return false
end

local function sanitize_value(value, key_hint, depth, seen)
  if should_redact_key(key_hint) then
    return "[REDACTED]"
  end

  local value_type = type(value)
  if value_type == "nil" then return nil end
  if value_type == "string" then return clip_text(value, MAX_STRING_CHARS) end
  if value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return tostring(value)
    end
    return value
  end
  if value_type == "boolean" then return value end
  if value_type ~= "table" then return tostring(value) end

  local d = tonumber(depth) or 0
  if d >= MAX_DEPTH then
    return "[TRUNCATED_DEPTH]"
  end
  seen = seen or {}
  if seen[value] then
    return "[CIRCULAR]"
  end
  seen[value] = true

  local out = {}
  if Util.is_array_like(value) then
    local max_items = math.min(#value, 80)
    for i = 1, max_items do
      out[i] = sanitize_value(value[i], tostring(i), d + 1, seen)
    end
    if #value > max_items then
      out[#out + 1] = string.format("[TRUNCATED_%d_MORE_ITEMS]", #value - max_items)
    end
  else
    local count = 0
    for k, v in pairs(value) do
      count = count + 1
      if count > 80 then
        out._truncated = true
        break
      end
      local out_key = clip_text(tostring(k), 128)
      if should_redact_key(out_key) then
        out._redacted_field_count = (tonumber(out._redacted_field_count) or 0) + 1
      else
        out[out_key] = sanitize_value(v, out_key, d + 1, seen)
      end
    end
  end
  seen[value] = nil
  return out
end

local function cap_data_table(data)
  local safe = sanitize_value(data or {}, "", 0, {})
  if type(safe) ~= "table" then
    safe = { value = safe }
  end
  local ok_encoded, encoded = pcall(json.encode, safe)
  if ok_encoded and #encoded <= MAX_DATA_JSON_CHARS then
    return safe
  end
  return {
    _truncated = true,
    _preview = clip_text(ok_encoded and encoded or tostring(encoded), MAX_DATA_JSON_CHARS)
  }
end

local function project_name()
  if type(r.GetProjectName) ~= "function" then return "" end
  local ok_name, name = pcall(r.GetProjectName, 0)
  if ok_name and name then return tostring(name) end
  return ""
end

local function os_text()
  if type(r.GetOS) ~= "function" then return "" end
  local ok_os, value = pcall(r.GetOS)
  if ok_os and value then return tostring(value) end
  return ""
end

local function reaper_version()
  if type(r.GetAppVersion) ~= "function" then return "" end
  local ok_ver, value = pcall(r.GetAppVersion)
  if ok_ver and value then return tostring(value) end
  return ""
end

local function identity_summary()
  if type(identity) ~= "table" then return nil end
  return {
    telemetry_level = tostring(identity.telemetry_level or ""),
    user_id = tostring(identity.user_id or ""),
    display_name = tostring(identity.display_name or ""),
    install_id = tostring(identity.install_id or ""),
    machine_label = tostring(identity.machine_label or ""),
    endpoint_configured = is_non_empty_string(identity.endpoint_url),
    client_token_configured = is_non_empty_string(identity.client_token)
  }
end

local function validate_identity(tbl)
  if type(tbl) ~= "table" then
    return false, { "identity JSON root must be an object" }
  end
  local missing = {}
  local required_strings = {
    "telemetry_level",
    "user_id",
    "display_name",
    "install_id",
    "machine_label",
    "endpoint_url",
    "client_token"
  }
  if tonumber(tbl.schema_version) ~= 1 then
    missing[#missing + 1] = "schema_version must be 1"
  end
  for i = 1, #required_strings do
    local key = required_strings[i]
    if not is_non_empty_string(tbl[key]) then
      missing[#missing + 1] = key
    end
  end
  if is_non_empty_string(tbl.endpoint_url) and not tbl.endpoint_url:match("^https?://") then
    missing[#missing + 1] = "endpoint_url must start with http:// or https://"
  end
  return #missing == 0, missing
end

local function default_settings()
  return {
    schema_version = 1,
    telemetry_level = normalize_level(identity and identity.telemetry_level or "support", "support"),
    debug_enabled = false,
    debug_expires_at = ""
  }
end

local function validate_settings(tbl)
  if type(tbl) ~= "table" then return default_settings(), true end
  local out = default_settings()
  if tonumber(tbl.schema_version) == 1 then
    out.schema_version = 1
  end
  out.telemetry_level = normalize_level(tbl.telemetry_level, out.telemetry_level)
  out.debug_enabled = tbl.debug_enabled == true
  out.debug_expires_at = tostring(tbl.debug_expires_at or "")
  return out, false
end

local function write_settings_file(settings_tbl)
  local path, path_err = settings_path()
  if not path then return false, path_err end
  local ok_json, encoded = pcall(json.encode, settings_tbl)
  if not ok_json then return false, "settings JSON encode failed: " .. tostring(encoded) end
  local ok_write, write_err = Files.write_file(path, encoded .. "\n")
  if not ok_write then return false, write_err end
  runtime.settings_path = path
  return true
end

local function load_settings(create_if_missing)
  local path, path_err = settings_path()
  if not path then return nil, path_err end
  runtime.settings_path = path

  if not file_exists(path) then
    local settings = default_settings()
    runtime.settings = settings
    if create_if_missing then
      local ok_write, write_err = write_settings_file(settings)
      if not ok_write then return nil, write_err end
    end
    return settings, nil
  end

  local raw, read_err = Files.slurp_with_cap(path, 64 * 1024)
  if not raw then return nil, read_err end
  local ok_dec, decoded = pcall(json.decode, raw)
  local settings, repaired = validate_settings(ok_dec and decoded or nil)
  runtime.settings = settings
  if create_if_missing and (not ok_dec or repaired) then
    write_settings_file(settings)
  end
  return settings, nil
end

local function copy_settings(settings_tbl)
  local src = settings_tbl or runtime.settings or default_settings()
  return {
    schema_version = tonumber(src.schema_version) or 1,
    telemetry_level = normalize_level(src.telemetry_level, "support"),
    debug_enabled = src.debug_enabled == true,
    debug_expires_at = tostring(src.debug_expires_at or ""),
    path = runtime.settings_path
  }
end

local function effective_level_from_settings(settings_tbl)
  local settings = settings_tbl or runtime.settings or default_settings()
  local level = normalize_level(settings.telemetry_level, identity and identity.telemetry_level or "support")
  if level == "debug" then
    local expires = tostring(settings.debug_expires_at or "")
    local expired = expires ~= "" and expires < utc_iso()
    if settings.debug_enabled ~= true or expired then
      return "support"
    end
  end
  return level
end

local function make_identity_error_message(path, reason)
  return table.concat({
    "Telemetry identity is required before this REAPER script can run.",
    "",
    "Expected file:",
    tostring(path or ""),
    "",
    tostring(reason or "Identity file is missing or invalid."),
    "",
    "Create or repair CirilicaTools_telemetry_identity.json in the REAPER Resource Path root, then run the script again."
  }, "\n")
end

local function append_json_line(path, tbl)
  local ok_json, line = pcall(json.encode, tbl)
  if not ok_json then
    return false, "JSON encode failed: " .. tostring(line)
  end
  local f, open_err = io.open(path, "ab")
  if not f then
    return false, "open queue failed: " .. tostring(open_err)
  end
  f:write(line)
  f:write("\n")
  f:close()
  log_debug(
    "append_json_line: file=" .. tostring(basename(path)) ..
    " event=" .. tostring(tbl and tbl.event_name or "") ..
    " bytes=" .. tostring(#line)
  )
  return true
end

local function ensure_initialized()
  if runtime.initialized ~= true then
    error("Telemetry.init(opts) must be called before this operation", 2)
  end
end

local function build_event(event_name, data, opts)
  local event_opts = opts or {}
  local safe_data = cap_data_table(data or {})
  local event_level = tostring(event_opts.event_level or event_opts.level or safe_data.event_level or "info")
  local policy = normalize_level(event_opts.policy or safe_data.telemetry_policy or EVENT_DEFAULT_POLICY[tostring(event_name or "")] or "support", "support")
  local priority = normalize_priority(event_opts.priority or safe_data.telemetry_priority, event_name)
  local event = {
    schema_version = 1,
    event_id = make_guid_text(),
    client_time = utc_iso(),
    event_name = tostring(event_name or "event"),
    event_level = event_level,
    telemetry_policy = policy,
    telemetry_priority = priority,
    app_name = runtime.app_name,
    entrypoint = runtime.entrypoint,
    script_version = runtime.script_version,
    telemetry_module_version = VERSION,
    user_id = identity and identity.user_id or "",
    display_name = identity and identity.display_name or "",
    install_id = identity and identity.install_id or "",
    machine_label = identity and identity.machine_label or "",
    os = os_text(),
    reaper_version = reaper_version(),
    project_name = tostring(event_opts.project_name or safe_data.project_name or project_name()),
    operation = tostring(event_opts.operation or safe_data.operation or ""),
    status = tostring(event_opts.status or safe_data.status or ""),
    error_code = tostring(event_opts.error_code or safe_data.error_code or ""),
    duration_ms = tonumber(event_opts.duration_ms or safe_data.duration_ms) or nil,
    request_label = tostring(event_opts.request_label or safe_data.request_label or ""),
    http_code = tonumber(event_opts.http_code or safe_data.http_code) or nil,
    curl_exitcode = tonumber(event_opts.curl_exitcode or safe_data.curl_exitcode) or nil,
    source_queue_file = runtime.queue_basename,
    data = safe_data
  }
  return event
end

local function append_budget_exhausted_event(reason)
  if runtime.budget_exhausted_emitted == true then return false end
  runtime.budget_exhausted_emitted = true
  local event = build_event("telemetry_budget_exhausted", {
    operation = "telemetry_budget",
    status = "limited",
    reason = tostring(reason or ""),
    queued_events_session = runtime.queued_events_session,
    dropped_events_session = runtime.dropped_events_session,
    sendable_queue_bytes = total_sendable_queue_bytes()
  }, {
    policy = "basic",
    priority = "error",
    event_level = "warning",
    operation = "telemetry_budget",
    status = "limited"
  })
  local ok_append = append_json_line(runtime.queue_path, event)
  if ok_append then
    runtime.queued_events_session = runtime.queued_events_session + 1
  end
  return ok_append
end

local function event_is_reserved(event_name, priority)
  local name = tostring(event_name or "")
  if priority == "error" then return true end
  if name == "script_closed" or name == "telemetry_budget_exhausted" or name == "telemetry_health" then return true end
  return false
end

local function should_accept_event(event_name, safe_data, opts)
  local options = opts or {}
  local policy = normalize_level(options.policy or safe_data.telemetry_policy or EVENT_DEFAULT_POLICY[tostring(event_name or "")] or "support", "support")
  local priority = normalize_priority(options.priority or safe_data.telemetry_priority, event_name)
  local effective = effective_level_from_settings(runtime.settings)
  if not level_allows(policy, effective) then
    return false, "policy", policy, priority
  end

  local sendable_bytes = total_sendable_queue_bytes()
  if sendable_bytes >= budget_limits.sendable_queue_soft_max_bytes and priority == "low" then
    append_budget_exhausted_event("local_queue_soft_cap")
    return false, "local_queue_soft_cap", policy, priority
  end

  local queued = tonumber(runtime.queued_events_session) or 0
  local hard_limit = tonumber(budget_limits.hard_events_per_session) or DEFAULT_BUDGET_HARD_EVENTS_PER_SESSION
  local soft_limit = tonumber(budget_limits.soft_events_per_session) or DEFAULT_BUDGET_SOFT_EVENTS_PER_SESSION
  local reserved_start = hard_limit - (tonumber(budget_limits.reserved_events) or DEFAULT_BUDGET_RESERVED_EVENTS)
  if queued >= hard_limit then
    append_budget_exhausted_event("hard_session_cap")
    return false, "hard_session_cap", policy, priority
  end
  if queued >= reserved_start and not event_is_reserved(event_name, priority) then
    append_budget_exhausted_event("reserved_session_cap")
    return false, "reserved_session_cap", policy, priority
  end
  if queued >= soft_limit and priority == "low" then
    append_budget_exhausted_event("soft_session_cap")
    return false, "soft_session_cap", policy, priority
  end

  return true, "", policy, priority
end

local function rotate_current_queue()
  if not is_non_empty_string(runtime.queue_path) or file_size(runtime.queue_path) <= 0 then
    log_debug("rotate_current_queue: current queue empty")
    return nil, nil
  end
  log_debug(
    "rotate_current_queue: moving current queue " ..
    tostring(runtime.queue_basename) ..
    " bytes=" .. tostring(file_size(runtime.queue_path))
  )
  local moved, move_err = move_file_to_dir(runtime.queue_path, runtime.paths.sending)
  if not moved then
    log_debug("rotate_current_queue: move failed: " .. tostring(move_err), 2)
    return nil, move_err
  end
  log_debug("rotate_current_queue: moved to sending as " .. tostring(basename(moved)))
  return moved, nil
end

local function prepare_sending_file()
  local sending = list_jsonl_files(runtime.paths.sending)
  log_debug(
    "prepare_sending_file: sending_files=" .. tostring(#sending) ..
    " queued_files=" .. tostring(count_jsonl_files(runtime.paths.queues)) ..
    " current_queue_bytes=" .. tostring(file_size(runtime.queue_path))
  )
  if #sending > 0 then
    log_debug("prepare_sending_file: using existing sending file " .. tostring(basename(sending[1])))
    return sending[1], nil
  end

  local rotated, rotate_err = rotate_current_queue()
  if rotate_err then return nil, rotate_err end
  if rotated then return rotated, nil end

  local queued = list_jsonl_files(runtime.paths.queues)
  for i = 1, #queued do
    if file_size(queued[i]) > 0 then
      log_debug("prepare_sending_file: moving old queued file " .. tostring(basename(queued[i])))
      return move_file_to_dir(queued[i], runtime.paths.sending)
    end
  end
  log_debug("prepare_sending_file: no sendable files")
  return nil, nil
end

local function close_send_epoch_from_path(path)
  local name = basename(path)
  local stamp = name:match("^telemetry_close_send%.(%d+)%.")
  return stamp and tonumber(stamp) or nil
end

local function cleanup_stale_close_send_artifacts(close_send_dir, max_age_sec)
  local now_epoch = tonumber(os.time()) or 0
  local max_age = tonumber(max_age_sec) or CLOSE_SEND_MAX_AGE_SEC
  local files = list_all_files(close_send_dir)
  local deleted = 0
  local kept = 0
  local failed = 0

  for i = 1, #files do
    local path = files[i]
    local stamp = close_send_epoch_from_path(path)
    if stamp and now_epoch > 0 and (now_epoch - stamp) > max_age then
      local ok_remove, remove_err = os.remove(path)
      if ok_remove or not file_exists(path) then
        deleted = deleted + 1
      else
        failed = failed + 1
        log_debug(
          "cleanup_stale_close_send_artifacts: failed path=" .. tostring(basename(path)) ..
          " err=" .. tostring(remove_err),
          2
        )
      end
    else
      kept = kept + 1
    end
  end

  if deleted > 0 or failed > 0 then
    log_debug(
      "cleanup_stale_close_send_artifacts: deleted=" .. tostring(deleted) ..
      " kept=" .. tostring(kept) ..
      " failed=" .. tostring(failed)
    )
  end
  return {
    deleted = deleted,
    kept = kept,
    failed = failed
  }
end

local function run_retention_cleanup(reason)
  if runtime.initialized ~= true or type(runtime.paths) ~= "table" then
    return nil
  end
  local failed_stats = cleanup_dir_by_policy(runtime.paths.failed, FAILED_MAX_AGE_SEC, FAILED_MAX_TOTAL_BYTES)
  local logs_stats = cleanup_dir_by_policy(runtime.paths.logs, LOG_MAX_AGE_SEC, LOG_MAX_TOTAL_BYTES)
  local close_stats = cleanup_stale_close_send_artifacts(runtime.paths.close_send, CLOSE_SEND_MAX_AGE_SEC)
  local stats = {
    reason = tostring(reason or ""),
    failed = failed_stats,
    logs = logs_stats,
    close_send = close_stats,
    ran_at = utc_iso()
  }
  runtime.last_retention_cleanup = stats
  runtime.last_retention_cleanup_at = type(r.time_precise) == "function" and r.time_precise() or os.clock()
  return stats
end

local function maybe_run_retention_cleanup(now_t)
  if runtime.initialized ~= true then return nil end
  local now = tonumber(now_t) or (type(r.time_precise) == "function" and r.time_precise() or os.clock())
  local last = tonumber(runtime.last_retention_cleanup_at)
  if last and (now - last) < RETENTION_TICK_INTERVAL_SEC then
    return nil
  end
  return run_retention_cleanup("tick")
end

local function build_batch_from_file(path)
  log_debug("build_batch_from_file: start file=" .. tostring(basename(path)) .. " bytes=" .. tostring(file_size(path)))
  local f, open_err = io.open(path, "rb")
  if not f then
    return nil, "open sending queue failed: " .. tostring(open_err)
  end

  local events = {}
  local selected_lines = {}
  local remaining_lines = {}
  local batch_id = make_guid_text()
  local selected_done = false

  for raw_line in f:lines() do
    local line = tostring(raw_line or ""):gsub("\r$", "")
    if line ~= "" then
      if selected_done then
        remaining_lines[#remaining_lines + 1] = line
      else
        local ok_dec, event_or_err = pcall(json.decode, line)
        if not ok_dec or type(event_or_err) ~= "table" then
          f:close()
          log_debug("build_batch_from_file: decode failed file=" .. tostring(basename(path)), 2)
          return nil, "queue JSONL decode failed in " .. basename(path)
        end
        event_or_err.batch_id = batch_id
        local candidate_events = {}
        for i = 1, #events do candidate_events[i] = events[i] end
        candidate_events[#candidate_events + 1] = event_or_err
        local ok_body, body = pcall(json.encode, {
          install_id = identity.install_id,
          client_token = identity.client_token,
          batch_id = batch_id,
          events = candidate_events
        })
        if not ok_body then
          f:close()
          return nil, "batch JSON encode failed: " .. tostring(body)
        end
        if #candidate_events > MAX_EVENTS_PER_BATCH or #body > MAX_POST_BYTES then
          selected_done = true
          remaining_lines[#remaining_lines + 1] = line
        else
          events = candidate_events
          selected_lines[#selected_lines + 1] = line
        end
      end
    end
  end
  f:close()

  if #events < 1 then
    log_debug("build_batch_from_file: no sendable events in " .. tostring(basename(path)), 2)
    return nil, "queue file has no sendable events"
  end

  local ok_payload, payload = pcall(json.encode, {
    install_id = identity.install_id,
    client_token = identity.client_token,
    batch_id = batch_id,
    events = events
  })
  if not ok_payload then
    log_debug("build_batch_from_file: payload encode failed: " .. tostring(payload), 2)
    return nil, "batch JSON encode failed: " .. tostring(payload)
  end

  log_debug(
    "build_batch_from_file: ready file=" .. tostring(basename(path)) ..
    " events=" .. tostring(#events) ..
    " remaining_lines=" .. tostring(#remaining_lines) ..
    " payload_bytes=" .. tostring(#payload)
  )
  if runtime.debug_log_unsafe_secrets == true then
    log_unsafe_debug(
      "build_batch_from_file selected_queue_lines file=" .. tostring(path),
      table.concat(selected_lines, "\n"),
      256 * 1024
    )
    log_unsafe_debug(
      "build_batch_from_file payload_json file=" .. tostring(path),
      payload,
      256 * 1024
    )
  end
  return {
    batch_id = batch_id,
    events = events,
    payload = payload,
    selected_lines = selected_lines,
    remaining_lines = remaining_lines
  }, nil
end

local function write_remaining_lines(original_path, remaining_lines)
  if type(remaining_lines) ~= "table" or #remaining_lines < 1 then
    log_debug("write_remaining_lines: no remaining lines for " .. tostring(basename(original_path)))
    return true
  end
  local target = unique_path_in_dir(runtime.paths.queues, basename(original_path))
  local text = table.concat(remaining_lines, "\n") .. "\n"
  local ok_write, write_err = Files.write_file(target, text)
  if not ok_write then
    log_debug("write_remaining_lines: write failed " .. tostring(write_err), 2)
    return false, write_err
  end
  log_debug(
    "write_remaining_lines: wrote " .. tostring(#remaining_lines) ..
    " line(s) to " .. tostring(basename(target))
  )
  return true
end

local function rewrite_current_queue_after_fire_and_forget(batch)
  local remaining_lines = batch and batch.remaining_lines or {}
  if type(remaining_lines) == "table" and #remaining_lines > 0 then
    local text = table.concat(remaining_lines, "\n") .. "\n"
    local ok_write, write_err = Files.write_file(runtime.queue_path, text)
    if not ok_write then
      return false, "could not rewrite current queue after close-send launch: " .. tostring(write_err)
    end
    runtime.flush_requested = true
    runtime.next_flush_at = (type(r.time_precise) == "function" and r.time_precise() or os.clock()) + 0.25
    return true
  end

  if file_exists(runtime.queue_path) then
    local ok_remove, remove_err = os.remove(runtime.queue_path)
    if not ok_remove and file_exists(runtime.queue_path) then
      return false, "could not remove current queue after close-send launch: " .. tostring(remove_err)
    end
  end
  runtime.flush_requested = false
  runtime.next_flush_at = nil
  return true
end

local function make_close_send_paths()
  local stamp = tostring(tonumber(os.time()) or 0)
  local suffix = sanitize_filename_part(make_guid_text():sub(1, 12), "close")
  local stem = "telemetry_close_send." .. stamp .. "." .. suffix
  local dir = runtime.paths.close_send
  return {
    stem = stem,
    config = Util.path_join(dir, stem .. ".config"),
    payload = Util.path_join(dir, stem .. ".payload.bin"),
    output = Util.path_join(dir, stem .. ".output.file"),
    headers = Util.path_join(dir, stem .. ".headers.txt"),
    stderr = Util.path_join(dir, stem .. ".error.log"),
    meta = Util.path_join(dir, stem .. ".meta.json")
  }
end

local function write_close_send_config(paths, curl_req)
  local lines = {}
  table.insert(lines, "# --- Telemetry Close Send Request ---")
  table.insert(lines, "url = " .. curl_cfg_quote(curl_req.url))
  table.insert(lines, "location")
  table.insert(lines, "header = " .. curl_cfg_quote("Content-Type: application/json"))
  table.insert(lines, "data-binary = " .. curl_cfg_quote("@" .. paths.payload))

  table.insert(lines, "")
  table.insert(lines, "# --- Connection Tuning ---")
  table.insert(lines, "connect-timeout = " .. tostring(curl_req.connect_timeout_sec))
  table.insert(lines, "speed-limit = " .. tostring(curl_req.speed_limit))
  table.insert(lines, "speed-time = " .. tostring(curl_req.speed_time))

  table.insert(lines, "")
  table.insert(lines, "# --- Output & Logging ---")
  table.insert(lines, "output = " .. curl_cfg_quote(paths.output))
  table.insert(lines, "dump-header = " .. curl_cfg_quote(paths.headers))
  table.insert(lines, "stderr = " .. curl_cfg_quote(paths.stderr))
  table.insert(lines, "show-error")
  table.insert(lines, "fail-with-body")
  table.insert(lines, "write-out = " .. curl_cfg_quote(string.format("%%output{%s}%%{json}", paths.meta)))
  table.insert(lines, "max-time = " .. tostring(curl_req.timeout_sec))

  return Files.write_file(paths.config, table.concat(lines, "\n") .. "\n")
end

local function move_failed_or_back(path, permanent)
  if not file_exists(path) then return true end
  local target_dir = permanent and runtime.paths.failed or runtime.paths.queues
  log_debug(
    "move_failed_or_back: file=" .. tostring(basename(path)) ..
    " permanent=" .. tostring(permanent)
  )
  local moved, move_err = move_file_to_dir(path, target_dir)
  if moved then
    log_debug("move_failed_or_back: moved to " .. tostring(permanent and "failed" or "queues") .. " as " .. tostring(basename(moved)))
    return true
  end
  runtime.last_error = "Failed to retain telemetry queue: " .. tostring(move_err)
  log_debug("move_failed_or_back: failed to retain queue: " .. tostring(move_err), 2)
  return false
end

local function decode_response_body(body)
  if not is_non_empty_string(body) then return nil end
  local ok_dec, decoded = pcall(json.decode, body)
  if ok_dec and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function is_permanent_failure(result, decoded)
  local backend_error = decoded and tostring(decoded.error or "") or ""
  if backend_error == "AUTH_FAILED" or backend_error == "INVALID_REQUEST" or backend_error == "POST_ONLY" then
    return true
  end
  local http = tonumber(result and result.http_code)
  if http and http >= 400 and http < 500 and http ~= 408 and http ~= 429 then
    return true
  end
  return false
end

local function finish_flush(result, job, batch)
  log_debug(
    "finish_flush: job_id=" .. tostring(job and job.id or "") ..
    " result_ok=" .. tostring(result and result.ok) ..
    " http=" .. tostring(result and result.http_code or "") ..
    " exit=" .. tostring(result and result.exitcode or "") ..
    " timed_out=" .. tostring(result and result.timed_out or false) ..
    " body_bytes=" .. tostring(result and result.body and #tostring(result.body) or 0)
  )
  runtime.active_job_id = nil
  runtime.last_flush_at = utc_iso()
  runtime.last_http_code = result and result.http_code or nil
  runtime.last_curl_exitcode = result and result.exitcode or nil

  local decoded = decode_response_body(result and result.body or "")
  local backend_ok = decoded and decoded.ok == true
  log_debug(
    "finish_flush: decoded_response=" .. tostring(decoded ~= nil) ..
    " backend_ok=" .. tostring(backend_ok) ..
    " accepted=" .. tostring(decoded and decoded.accepted or "") ..
    " backend_error=" .. tostring(decoded and decoded.error or "")
  )
  if runtime.debug_log_unsafe_secrets == true then
    local result_summary = {
      ok = result and result.ok or false,
      http_code = result and result.http_code or nil,
      exitcode = result and result.exitcode or nil,
      err = result and result.err or nil,
      err_msg = result and result.err_msg or nil,
      url = result and result.url or nil,
      effective_url = result and result.effective_url or nil,
      redirect_url = result and result.redirect_url or nil,
      content_type = result and result.content_type or nil,
      total_time = result and result.total_time or nil,
      namelookup_time = result and result.namelookup_time or nil,
      connect_time = result and result.connect_time or nil,
      appconnect_time = result and result.appconnect_time or nil,
      starttransfer_time = result and result.starttransfer_time or nil,
      size_download = result and result.size_download or nil,
      size_upload = result and result.size_upload or nil,
      timed_out = result and result.timed_out or false,
      artifacts_retained = result and result.artifacts_retained or false,
      artifact_paths = result and result.artifact_paths or nil,
      job = {
        id = job and job.id or nil,
        label = job and job.label or nil,
        kind = job and job.kind or nil,
        phase = job and job.phase or nil,
        cfg_path = job and job.cfg_path or nil,
        out_path = job and job.out_path or nil,
        hdr_path = job and job.hdr_path or nil,
        err_path = job and job.err_path or nil,
        meta_path = job and job.meta_path or nil,
        payload_path = job and job.payload_path or nil
      },
      decoded_response = decoded,
      meta = result and compact_curl_meta_for_log(result.meta) or nil
    }
    log_unsafe_debug("finish_flush result_summary_json", encode_debug_value(result_summary), 256 * 1024)
    log_unsafe_debug("finish_flush response_body", result and result.body or "", 256 * 1024)
    log_unsafe_debug("finish_flush response_headers", result and result.headers_txt or "", 256 * 1024)
    log_unsafe_debug("finish_flush stderr", result and result.err_txt or "", 256 * 1024)
    if result and result.artifact_paths then
      log_artifact_file("finish_flush artifact_output", result.artifact_paths.output, 256 * 1024)
      log_artifact_file("finish_flush artifact_headers", result.artifact_paths.headers, 256 * 1024)
      log_artifact_file("finish_flush artifact_stderr", result.artifact_paths.stderr, 256 * 1024)
      log_unsafe_debug("finish_flush artifact_meta_compact_json", encode_debug_value(compact_curl_meta_for_log(result.meta)), 128 * 1024)
      log_artifact_file("finish_flush artifact_payload", result.artifact_paths.payload, 256 * 1024)
      log_artifact_file("finish_flush artifact_config", result.artifact_paths.cfg, 256 * 1024)
    end
  end
  if result and result.ok and backend_ok then
    local accepted = tonumber(decoded.accepted) or #(batch.events or {})
    local duplicate = tonumber(decoded.duplicate) or 0
    local cleared = accepted + duplicate
    runtime.flushed_events_session = runtime.flushed_events_session + cleared
    runtime.status = duplicate > 0
      and string.format("flushed %d telemetry event(s), %d duplicate(s) accepted", accepted, duplicate)
      or string.format("flushed %d telemetry event(s)", accepted)
    runtime.last_error = ""
    runtime.last_backend_error = ""
    runtime.hard_backend_failures_session = 0
    local ok_remaining, remaining_err = write_remaining_lines(runtime.active_queue_path, batch.remaining_lines)
    if not ok_remaining then
      runtime.last_error = "Flush succeeded but remaining queue rewrite failed: " .. tostring(remaining_err)
      runtime.status = "flush partly succeeded; queue retained for inspection"
      move_failed_or_back(runtime.active_queue_path, true)
    else
      os.remove(runtime.active_queue_path)
      log_debug("finish_flush: removed sent file " .. tostring(basename(runtime.active_queue_path)))
    end
    if file_size(runtime.queue_path) > 0 or count_jsonl_files(runtime.paths.queues) > 0 or count_jsonl_files(runtime.paths.sending) > 0 then
      runtime.flush_requested = true
      runtime.next_flush_at = (type(r.time_precise) == "function" and r.time_precise() or os.clock()) + 0.25
    end
  else
    local backend_error = decoded and tostring(decoded.error or "") or ""
    runtime.last_backend_error = backend_error
    local permanent = is_permanent_failure(result, decoded)
    local err_txt = backend_error
    if err_txt == "" and result and result.err then err_txt = tostring(result.err) end
    if err_txt == "" then err_txt = "telemetry flush failed" end
    runtime.last_error = err_txt
    runtime.status = permanent and "flush failed permanently" or "flush failed; queued for retry"
    runtime.failed_batches_session = runtime.failed_batches_session + 1
    if permanent then
      runtime.send_paused = true
      runtime.send_pause_reason = "permanent backend failure: " .. tostring(err_txt)
    elseif backend_error == "SERVER_ERROR" then
      runtime.hard_backend_failures_session = runtime.hard_backend_failures_session + 1
      if runtime.hard_backend_failures_session >= HARD_BACKEND_FAILURES_BEFORE_PAUSE then
        runtime.send_paused = true
        runtime.send_pause_reason = "repeated backend server errors"
        runtime.status = "flush paused after repeated backend errors"
      end
    else
      runtime.hard_backend_failures_session = 0
    end
    log_debug(
      "finish_flush: failure permanent=" .. tostring(permanent) ..
      " send_paused=" .. tostring(runtime.send_paused) ..
      " err=" .. tostring(err_txt) ..
      " response_preview=" .. Util.clip_text(tostring(result and result.body or ""), 512),
      2
    )
    move_failed_or_back(runtime.active_queue_path, permanent)
  end

  runtime.active_queue_path = nil
  runtime.active_source_file = nil
  runtime.active_remaining_lines = nil
  runtime.active_batch_event_count = 0
  runtime.active_batch_payload_bytes = 0
end

function Telemetry.require_identity_or_abort(_opts)
  local path, path_err = identity_path()
  if not path then
    r.MB(make_identity_error_message("", path_err), "Telemetry Identity Required", 0)
    return false
  end

  if not file_exists(path) then
    identity = nil
    r.MB(make_identity_error_message(path, "Identity file is missing."), "Telemetry Identity Required", 0)
    return false
  end

  local raw, read_err = Files.slurp_with_cap(path, 128 * 1024)
  if not raw then
    identity = nil
    r.MB(make_identity_error_message(path, "Identity file could not be read: " .. tostring(read_err)), "Telemetry Identity Required", 0)
    return false
  end

  local ok_dec, decoded = pcall(json.decode, raw)
  if not ok_dec then
    identity = nil
    r.MB(make_identity_error_message(path, "Identity JSON could not be parsed."), "Telemetry Identity Required", 0)
    return false
  end

  local ok_identity, problems = validate_identity(decoded)
  if not ok_identity then
    identity = nil
    r.MB(
      make_identity_error_message(path, "Identity is missing or has invalid fields: " .. table.concat(problems, ", ")),
      "Telemetry Identity Required",
      0
    )
    return false
  end

  identity = decoded
  runtime.status = "identity loaded"
  log_debug(
    "require_identity_or_abort: identity loaded install_id=" .. tostring(identity.install_id or "") ..
    " user_id=" .. tostring(identity.user_id or "") ..
    " endpoint_present=" .. tostring(is_non_empty_string(identity.endpoint_url)) ..
    " token_present=" .. tostring(is_non_empty_string(identity.client_token))
  )
  return true
end

function Telemetry.init(opts)
  if type(identity) ~= "table" then
    return false, "Telemetry identity must be loaded before init"
  end
  local options = opts or {}
  local root, root_err = resource_path()
  if not root then return false, root_err end

  local runtime_root = Util.path_join(root, RUNTIME_DIR_NAME)
  local paths = {
    root = runtime_root,
    queues = Util.path_join(runtime_root, "queues"),
    sending = Util.path_join(runtime_root, "sending"),
    failed = Util.path_join(runtime_root, "failed"),
    logs = Util.path_join(runtime_root, "logs"),
    close_send = Util.path_join(runtime_root, "close_send")
  }
  for label, path in pairs(paths) do
    local ok_dir, dir_err = ensure_writable_dir(path, label)
    if not ok_dir then return false, dir_err end
  end

  local settings, settings_err = load_settings(true)
  if not settings then
    return false, "Telemetry settings could not be loaded: " .. tostring(settings_err)
  end

  if options.enable_file_log == true then
    Util.tmp_dir = paths.logs
    Util.log_file_name = tostring(options.log_file_name or "telemetry_runtime_log")
    Util.full_path_to_log_file = nil
    Util.msg_to_log_file = true
    Util.log_level_override = 0
  end

  local entrypoint = sanitize_filename_part(options.entrypoint or "unknown", "unknown")
  local session_id = utc_stamp() .. "." .. make_guid_text():sub(1, 12)
  local queue_basename = entrypoint .. "." .. session_id .. ".jsonl"

  runtime.initialized = true
  runtime.app_name = tostring(options.app_name or "CirilicaTools")
  runtime.entrypoint = entrypoint
  runtime.script_version = tostring(options.script_version or "")
  runtime.session_id = session_id
  runtime.paths = paths
  runtime.queue_basename = queue_basename
  runtime.queue_path = Util.path_join(paths.queues, queue_basename)
  runtime.status = "ready"
  runtime.last_error = ""
  runtime.last_backend_error = ""
  runtime.flush_requested = false
  runtime.next_flush_at = nil
  runtime.active_job_id = nil
  runtime.active_queue_path = nil
  runtime.active_source_file = nil
  runtime.active_remaining_lines = nil
  runtime.queued_events_session = 0
  runtime.flushed_events_session = 0
  runtime.failed_batches_session = 0
  runtime.dropped_events_session = 0
  runtime.skipped_events_session = 0
  runtime.budget_exhausted_emitted = false
  runtime.send_paused = false
  runtime.send_pause_reason = ""
  runtime.hard_backend_failures_session = 0
  runtime.settings = settings
  runtime.debug_log_unsafe_secrets = options.debug_log_unsafe_secrets == true
  run_retention_cleanup("init")
  log_debug(
    "init: app=" .. tostring(runtime.app_name) ..
    " entrypoint=" .. tostring(runtime.entrypoint) ..
    " script_version=" .. tostring(runtime.script_version) ..
    " session_id=" .. tostring(runtime.session_id) ..
    " queue_file=" .. tostring(runtime.queue_basename) ..
    " telemetry_level=" .. tostring(effective_level_from_settings(settings)) ..
    " logs=" .. tostring(paths.logs)
  )
  if runtime.debug_log_unsafe_secrets == true then
    log_file_only("[telemetry][unsafe_debug] ENABLED for this telemetry runtime. Local log may contain endpoint URLs, client tokens, payloads, and curl artifacts.")
    log_unsafe_debug("init identity_json", encode_debug_value(identity), 128 * 1024)
    log_unsafe_debug("init runtime_paths_json", encode_debug_value(paths), 128 * 1024)
  end
  return true
end

function Telemetry.event(event_name, data, opts)
  ensure_initialized()
  local name = tostring(event_name or "")
  if name == "" then name = "event" end
  local event_opts = opts or {}
  local safe_data = cap_data_table(data or {})
  local accept, skip_reason, policy, priority = should_accept_event(name, safe_data, event_opts)
  if not accept then
    if skip_reason == "policy" then
      runtime.skipped_events_session = runtime.skipped_events_session + 1
    else
      runtime.dropped_events_session = runtime.dropped_events_session + 1
    end
    runtime.status = "telemetry event skipped: " .. tostring(skip_reason)
    log_debug(
      "event: skipped name=" .. tostring(name) ..
      " reason=" .. tostring(skip_reason) ..
      " policy=" .. tostring(policy) ..
      " priority=" .. tostring(priority) ..
      " effective_level=" .. tostring(effective_level_from_settings(runtime.settings))
    )
    return true, {
      skipped = true,
      reason = skip_reason,
      policy = policy,
      priority = priority
    }
  end
  local build_opts = {}
  for k, v in pairs(event_opts) do
    build_opts[k] = v
  end
  build_opts.policy = policy
  build_opts.priority = priority
  local event = build_event(name, safe_data, build_opts)
  local ok_append, append_err = append_json_line(runtime.queue_path, event)
  if not ok_append then
    runtime.last_error = append_err
    runtime.status = "queue append failed"
    return false, append_err
  end
  runtime.queued_events_session = runtime.queued_events_session + 1
  runtime.status = "queued telemetry event: " .. name
  runtime.flush_requested = true
  runtime.next_flush_at = (type(r.time_precise) == "function" and r.time_precise() or os.clock()) + 0.25
  log_debug(
    "event: queued name=" .. tostring(name) ..
    " level=" .. tostring(event.event_level or "") ..
    " policy=" .. tostring(event.telemetry_policy or "") ..
    " priority=" .. tostring(event.telemetry_priority or "") ..
    " operation=" .. tostring(event.operation or "") ..
    " status=" .. tostring(event.status or "") ..
    " queue_bytes=" .. tostring(file_size(runtime.queue_path)) ..
    " next_flush_at=" .. tostring(runtime.next_flush_at)
  )
  return true
end

function Telemetry.error(error_code, data)
  local payload = data or {}
  if type(payload) ~= "table" then payload = { message = tostring(payload) } end
  payload.error_code = tostring(error_code or payload.error_code or "ERROR")
  payload.status = tostring(payload.status or "failed")
  return Telemetry.event("error", payload, {
    event_level = "error",
    error_code = payload.error_code,
    status = payload.status,
    operation = payload.operation
  })
end

function Telemetry.flush_async(opts)
  ensure_initialized()
  if runtime.send_paused == true then
    local reason = runtime.send_pause_reason ~= "" and runtime.send_pause_reason or "telemetry sending is paused"
    runtime.status = "telemetry sending paused"
    return false, reason
  end
  if runtime.active_job_id ~= nil then
    log_debug("flush_async: skipped, active job=" .. tostring(runtime.active_job_id))
    return false, "telemetry flush already running"
  end
  local options = opts or {}
  log_debug(
    "flush_async: start reason=" .. tostring(options.reason or "") ..
    " queue_files=" .. tostring(count_jsonl_files(runtime.paths.queues)) ..
    " sending_files=" .. tostring(count_jsonl_files(runtime.paths.sending)) ..
    " current_queue_bytes=" .. tostring(file_size(runtime.queue_path))
  )
  local sending_path, prep_err = prepare_sending_file()
  if prep_err then
    runtime.last_error = prep_err
    runtime.status = "flush preparation failed"
    return false, prep_err
  end
  if not sending_path then
    runtime.flush_requested = false
    runtime.status = "no telemetry events to flush"
    log_debug("flush_async: no telemetry events to flush")
    return false, "no telemetry events to flush"
  end

  local batch, batch_err = build_batch_from_file(sending_path)
  if not batch then
    runtime.last_error = batch_err
    runtime.status = "queue file moved to failed"
    log_debug("flush_async: batch build failed: " .. tostring(batch_err), 2)
    move_failed_or_back(sending_path, true)
    return false, batch_err
  end

  local req = {
    kind = "telemetry",
    label = "_telemetry_flush",
    owner = "telemetry",
    blocking = false,
    visible = true,
    priority = "background",
    url = identity.endpoint_url,
    follow_redirects = true,
    headers = {
      ["Content-Type"] = "application/json"
    },
    body_string = batch.payload,
    timeout_sec = tonumber(options.timeout_sec) or 45,
    connect_timeout_sec = tonumber(options.connect_timeout_sec) or 15,
    speed_limit = tonumber(options.speed_limit) or 1,
    speed_time = tonumber(options.speed_time) or 30
  }
  -- Do not force `request = "POST"` in the curl config. `data-binary` makes
  -- the first request a POST, and Apps Script's redirected response fetch must
  -- be allowed to use curl's normal redirect behavior.
  log_debug("flush_async: request uses body-implied initial POST with no explicit curl request override")
  if runtime.debug_log_unsafe_secrets == true then
    log_unsafe_debug("flush_async request_table_json", encode_debug_value({
      kind = req.kind,
      label = req.label,
      method = "(body-implied POST; no explicit curl request override)",
      url = req.url,
      follow_redirects = req.follow_redirects,
      headers = req.headers,
      timeout_sec = req.timeout_sec,
      connect_timeout_sec = req.connect_timeout_sec,
      speed_limit = req.speed_limit,
      speed_time = req.speed_time,
      body_bytes = #tostring(req.body_string or ""),
      install_id = identity.install_id,
      client_token = identity.client_token,
      batch_id = batch.batch_id,
      event_count = #(batch.events or {}),
      sending_path = sending_path
    }), 128 * 1024)
    log_unsafe_debug("flush_async payload_json", batch.payload, 256 * 1024)
  end

  local job, submit_err = Curl.curl_submit(req, function(result, job_done)
    finish_flush(result, job_done, batch)
  end, {
    use_payload_file = true,
    read_body = true,
    body_max_bytes = 64 * 1024,
    timeout_sec = tonumber(options.timeout_sec) or 45,
    owner = "telemetry",
    blocking = false,
    visible = true,
    priority = "background",
    retain_artifacts = false,
    keep_output = false
  })

  if not job then
    runtime.last_error = "telemetry curl submit failed: " .. tostring(submit_err)
    runtime.status = "flush submit failed; queued for retry"
    runtime.active_batch_event_count = 0
    runtime.active_batch_payload_bytes = 0
    runtime.active_queue_path = nil
    runtime.active_source_file = nil
    runtime.active_remaining_lines = nil
    log_debug("flush_async: curl_submit failed: " .. tostring(submit_err), 2)
    if runtime.debug_log_unsafe_secrets == true then
      log_file_only("[telemetry][unsafe_debug] flush_async curl_submit failed: " .. tostring(submit_err))
    end
    move_failed_or_back(sending_path, false)
    return false, submit_err
  end

  runtime.active_job_id = job.id
  runtime.active_queue_path = sending_path
  runtime.active_source_file = basename(sending_path)
  runtime.active_remaining_lines = batch.remaining_lines
  runtime.active_batch_event_count = #(batch.events or {})
  runtime.active_batch_payload_bytes = #tostring(batch.payload or "")
  runtime.flush_requested = false
  runtime.next_flush_at = nil
  runtime.status = string.format("flushing %d telemetry event(s)", #(batch.events or {}))
  log_debug(
    "flush_async: submitted job_id=" .. tostring(job.id) ..
    " events=" .. tostring(#(batch.events or {})) ..
    " sending_file=" .. tostring(basename(sending_path)) ..
    " cfg=" .. tostring(job.cfg_path and basename(job.cfg_path) or "") ..
    " output=" .. tostring(job.out_path and basename(job.out_path) or "") ..
    " headers=" .. tostring(job.hdr_path and basename(job.hdr_path) or "") ..
    " stderr=" .. tostring(job.err_path and basename(job.err_path) or "") ..
    " meta=" .. tostring(job.meta_path and basename(job.meta_path) or "")
  )
  if runtime.debug_log_unsafe_secrets == true then
    log_artifact_file("flush_async curl_config", job.cfg_path, 256 * 1024)
    log_artifact_file("flush_async curl_payload_file", job.payload_path, 256 * 1024)
    log_file_only(
      "[telemetry][unsafe_debug] flush_async job_paths_json=" ..
      encode_debug_value({
        cfg_path = job.cfg_path,
        out_path = job.out_path,
        hdr_path = job.hdr_path,
        err_path = job.err_path,
        meta_path = job.meta_path,
        payload_path = job.payload_path
      })
    )
  end
  return true, job
end

function Telemetry.flush_current_queue_fire_and_forget(opts)
  ensure_initialized()
  if runtime.send_paused == true then
    local reason = runtime.send_pause_reason ~= "" and runtime.send_pause_reason or "telemetry sending is paused"
    runtime.status = "close-send skipped; telemetry sending paused"
    return false, reason
  end
  local options = opts or {}
  local curl_path = tostring(options.curl_path or "")
  if curl_path == "" then
    return false, "flush_current_queue_fire_and_forget requires opts.curl_path"
  end

  if not is_non_empty_string(runtime.queue_path) or file_size(runtime.queue_path) <= 0 then
    runtime.status = "no current telemetry events to close-send"
    log_debug("flush_current_queue_fire_and_forget: no current queue events")
    return false, "no current telemetry events to close-send"
  end

  local batch, batch_err = build_batch_from_file(runtime.queue_path)
  if not batch then
    runtime.last_error = batch_err
    runtime.status = "close-send batch build failed"
    log_debug("flush_current_queue_fire_and_forget: batch build failed: " .. tostring(batch_err), 2)
    return false, batch_err
  end

  local paths = make_close_send_paths()
  local ok_payload, payload_err = Files.write_file(paths.payload, batch.payload)
  if not ok_payload then
    runtime.last_error = "close-send payload write failed: " .. tostring(payload_err)
    runtime.status = "close-send preparation failed"
    log_debug(runtime.last_error, 2)
    return false, runtime.last_error
  end

  local curl_req = {
    url = identity.endpoint_url,
    timeout_sec = tonumber(options.timeout_sec) or 20,
    connect_timeout_sec = tonumber(options.connect_timeout_sec) or 10,
    speed_limit = tonumber(options.speed_limit) or 1,
    speed_time = tonumber(options.speed_time) or 15
  }
  local ok_config, config_err = write_close_send_config(paths, curl_req)
  if not ok_config then
    os.remove(paths.payload)
    runtime.last_error = "close-send config write failed: " .. tostring(config_err)
    runtime.status = "close-send preparation failed"
    log_debug(runtime.last_error, 2)
    return false, runtime.last_error
  end

  local cmd = Util.shell_quote(curl_path) .. " -q --config " .. Util.shell_quote(paths.config)
  log_debug(
    "flush_current_queue_fire_and_forget: launching events=" .. tostring(#(batch.events or {})) ..
    " cfg=" .. tostring(basename(paths.config)) ..
    " payload=" .. tostring(basename(paths.payload))
  )
  if runtime.debug_log_unsafe_secrets == true then
    log_unsafe_debug("close_send payload_json", batch.payload, 256 * 1024)
    log_artifact_file("close_send curl_config", paths.config, 128 * 1024)
    log_file_only("[telemetry][unsafe_debug] close_send command=" .. tostring(cmd))
  end

  local exec_output = r.ExecProcess(cmd, -2)
  if not exec_output then
    os.remove(paths.config)
    os.remove(paths.payload)
    os.remove(paths.output)
    os.remove(paths.headers)
    os.remove(paths.stderr)
    os.remove(paths.meta)
    runtime.last_error = "close-send curl launch failed"
    runtime.status = "close-send launch failed; queued for retry"
    log_debug("flush_current_queue_fire_and_forget: launch failed; current queue left intact", 2)
    return false, runtime.last_error
  end

  local cleanup_ok, cleanup_err = rewrite_current_queue_after_fire_and_forget(batch)
  runtime.status = cleanup_ok and "close-send launched" or "close-send launched; queue cleanup failed"
  runtime.last_error = cleanup_ok and "" or tostring(cleanup_err or "")
  log_debug(
    "flush_current_queue_fire_and_forget: launched events=" .. tostring(#(batch.events or {})) ..
    " cleanup_ok=" .. tostring(cleanup_ok) ..
    " exec_output=" .. tostring(exec_output)
  )

  return true, {
    launched = true,
    cleanup_ok = cleanup_ok,
    cleanup_error = cleanup_err,
    batch_id = batch.batch_id,
    event_count = #(batch.events or {}),
    command = cmd,
    config_path = paths.config,
    payload_path = paths.payload,
    output_path = paths.output,
    headers_path = paths.headers,
    stderr_path = paths.stderr,
    meta_path = paths.meta
  }
end

function Telemetry.tick(now_t)
  if runtime.initialized ~= true then return true end
  maybe_run_retention_cleanup(now_t)
  if runtime.active_job_id ~= nil then return true end
  if runtime.flush_requested ~= true then return true end
  local now = tonumber(now_t) or (type(r.time_precise) == "function" and r.time_precise() or os.clock())
  if runtime.next_flush_at and now < runtime.next_flush_at then return true end
  log_debug(
    "tick: firing scheduled flush now=" .. tostring(now) ..
    " next_flush_at=" .. tostring(runtime.next_flush_at)
  )
  return Telemetry.flush_async({ reason = "scheduled" })
end

function Telemetry.safe_tick(now_t)
  local ok, result_or_err, extra = pcall(Telemetry.tick, now_t)
  if ok then return result_or_err, extra end
  runtime.last_error = tostring(result_or_err)
  runtime.status = "telemetry tick failed"
  return false, result_or_err
end

function Telemetry.safe_event(event_name, data, opts)
  local ok, result_or_err, extra = pcall(Telemetry.event, event_name, data, opts)
  if ok then return result_or_err, extra end
  runtime.last_error = tostring(result_or_err)
  runtime.status = "telemetry event failed"
  return false, result_or_err
end

function Telemetry.safe_flush_async(opts)
  local ok, result_or_err, extra = pcall(Telemetry.flush_async, opts)
  if ok then return result_or_err, extra end
  runtime.last_error = tostring(result_or_err)
  runtime.status = "telemetry flush failed before submit"
  return false, result_or_err
end

function Telemetry.get_settings()
  if runtime.settings == nil then
    load_settings(false)
  end
  return copy_settings(runtime.settings)
end

function Telemetry.effective_level()
  if runtime.settings == nil then
    load_settings(false)
  end
  return effective_level_from_settings(runtime.settings)
end

function Telemetry.set_level(level, opts)
  local normalized = normalize_level(level, "support")
  local options = opts or {}
  local settings = runtime.settings or default_settings()
  settings.telemetry_level = normalized
  if normalized == "debug" then
    settings.debug_enabled = true
    local hours = tonumber(options.debug_hours) or 24
    local expires_at = tostring(options.debug_expires_at or "")
    if expires_at == "" then
      expires_at = os.date("!%Y-%m-%dT%H:%M:%SZ", (tonumber(os.time()) or 0) + math.floor(hours * 60 * 60))
    end
    settings.debug_expires_at = expires_at
  else
    settings.debug_enabled = false
    settings.debug_expires_at = ""
  end
  local ok_write, write_err = write_settings_file(settings)
  if not ok_write then
    return false, write_err
  end
  runtime.settings = settings
  return true, copy_settings(settings)
end

function Telemetry.resume_sending(reason)
  ensure_initialized()
  runtime.send_paused = false
  runtime.send_pause_reason = ""
  runtime.hard_backend_failures_session = 0
  runtime.status = tostring(reason or "") ~= "" and tostring(reason) or "telemetry sending resumed"
  return true
end

function Telemetry.describe_status()
  local desc = {
    initialized = runtime.initialized == true,
    identity = identity_summary(),
    status = runtime.status,
    last_error = runtime.last_error,
    last_backend_error = runtime.last_backend_error,
    last_http_code = runtime.last_http_code,
    last_curl_exitcode = runtime.last_curl_exitcode,
    last_flush_at = runtime.last_flush_at,
    active_job_id = runtime.active_job_id,
    active_source_file = runtime.active_source_file,
    active_batch_event_count = runtime.active_batch_event_count,
    active_batch_payload_bytes = runtime.active_batch_payload_bytes,
    queue_file = runtime.queue_basename,
    queue_path = runtime.queue_path,
    settings = copy_settings(runtime.settings),
    effective_level = effective_level_from_settings(runtime.settings),
    settings_path = runtime.settings_path,
    send_paused = runtime.send_paused == true,
    send_pause_reason = runtime.send_pause_reason,
    hard_backend_failures_session = runtime.hard_backend_failures_session,
    paths = runtime.paths,
    queued_file_count = 0,
    sending_file_count = 0,
    failed_file_count = 0,
    close_send_file_count = 0,
    current_queue_bytes = file_size(runtime.queue_path),
    backlog_file_count = 0,
    backlog_queue_bytes = 0,
    draining_backlog = false,
    sendable_queue_bytes = total_sendable_queue_bytes(),
    queued_events_session = runtime.queued_events_session,
    flushed_events_session = runtime.flushed_events_session,
    failed_batches_session = runtime.failed_batches_session,
    dropped_events_session = runtime.dropped_events_session,
    skipped_events_session = runtime.skipped_events_session,
    budget_exhausted_emitted = runtime.budget_exhausted_emitted == true,
    budget_limits = copy_budget_limits(),
    last_retention_cleanup = runtime.last_retention_cleanup,
    debug_log_unsafe_secrets = runtime.debug_log_unsafe_secrets == true,
    progress_line = "",
    active_job_phase = ""
  }
  if runtime.initialized == true then
    desc.queued_file_count = count_jsonl_files(runtime.paths.queues)
    desc.sending_file_count = count_jsonl_files(runtime.paths.sending)
    desc.failed_file_count = count_jsonl_files(runtime.paths.failed)
    desc.close_send_file_count = count_all_files(runtime.paths.close_send)
    desc.backlog_file_count = desc.queued_file_count + desc.sending_file_count
    desc.backlog_queue_bytes = total_jsonl_bytes(runtime.paths.queues) + total_jsonl_bytes(runtime.paths.sending)
    desc.draining_backlog = desc.backlog_file_count > 0 and desc.backlog_queue_bytes > 0
  end
  if runtime.active_job_id ~= nil and type(Curl.get_jobs) == "function" then
    local ok_jobs, jobs = pcall(Curl.get_jobs)
    local job = ok_jobs and jobs and jobs[runtime.active_job_id] or nil
    if job then
      desc.active_job_phase = tostring(job.phase or "")
      local flow = job.progress and job.progress.flow
      desc.progress_line = flow and tostring(flow.line or "") or ""
    end
  end
  return desc
end

Telemetry.VERSION = VERSION
Telemetry.IDENTITY_FILE_NAME = IDENTITY_FILE_NAME
Telemetry.SETTINGS_FILE_NAME = SETTINGS_FILE_NAME
Telemetry.RUNTIME_DIR_NAME = RUNTIME_DIR_NAME

function Telemetry._test_set_budget_limits(limits)
  apply_budget_limits(limits)
  return copy_budget_limits()
end

function Telemetry._test_reset_budget_limits()
  reset_budget_limits()
  return copy_budget_limits()
end

return Telemetry
