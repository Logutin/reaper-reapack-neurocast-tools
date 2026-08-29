-- ElevenLabs account assignment manager via Studio Neurocast.
-- English-only maintained ReaImGui entrypoint.

local r = assert(reaper, "REAPER API not found. This script must run inside REAPER.")
local SCRIPT_VERSION = "v0.1.2"
local APP_NAME = "ElevenLabs Manager"
local ENTRYPOINT = "elevenlabs_manager_tool"
local PRODUCTION_BACKEND_URL = "https://reaper.neurocast.tech"

if not r.ImGui_CreateContext then
  r.MB(
    "Missing dependency: ReaImGui extension.\nInstall it through ReaPack, then run this script again.",
    APP_NAME,
    0
  )
  return
end

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
if not script_path then
  r.MB("Failed to resolve the script folder.", APP_NAME, 0)
  return
end

local old_package_path = package.path
package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. old_package_path

local function require_module(name)
  local ok, value = pcall(require, name)
  if not ok then
    package.path = old_package_path
    r.MB("Failed to load " .. tostring(name) .. ":\n" .. tostring(value), APP_NAME, 0)
    error("module load failed: " .. tostring(name))
  end
  return value
end

local Util = require_module("modules-neurocast.Util")
local Files = require_module("modules-neurocast.Files")
local Curl = require_module("modules-neurocast.Curl")
local Jobs = require_module("modules-neurocast.Jobs")
local NeurocastAuth = require_module("modules-neurocast.neurocast_auth")
local ManagerApi = require_module("modules-neurocast.reaper_manager_elevenlabs_api")
local Telemetry = require_module("modules-neurocast.Telemetry")
local Utf8Tools = require_module("modules-neurocast.Utf8Tools")

if not Telemetry.require_identity_or_abort({
  app_name = "CirilicaTools",
  entrypoint = ENTRYPOINT,
  script_version = SCRIPT_VERSION
}) then
  package.path = old_package_path
  return
end

local ok_telemetry, telemetry_err = Telemetry.init({
  app_name = "CirilicaTools",
  entrypoint = ENTRYPOINT,
  script_version = SCRIPT_VERSION,
  enable_file_log = false
})
if not ok_telemetry then
  package.path = old_package_path
  r.MB("Telemetry initialization failed:\n" .. tostring(telemetry_err), APP_NAME, 0)
  return
end

package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ok_imgui, ImGuiOrErr = pcall(function()
  return require("imgui")("0.10")
end)
package.path = old_package_path
if not ok_imgui then
  r.MB("Failed to load ReaImGui Lua module:\n" .. tostring(ImGuiOrErr), APP_NAME, 0)
  return
end
local ImGui = ImGuiOrErr

local function trim(value)
  if type(Util.trim) == "function" then return Util.trim(value) end
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function resolve_curl_path()
  if Util.mac then return "/usr/bin/curl" end
  local pinned = Util.path_join(script_path, [=[bin\win]=]) .. [=[\curl.exe]=]
  local result = r.ExecProcess(pinned .. " --version", 1500)
  if result and result:find("curl 8.13.0 (Windows)", 1, true) then return pinned end
  r.MB(
    "The bundled curl was not found or did not match the expected version.\n\n" ..
      "The script will try Windows system curl from PATH.",
    APP_NAME,
    0
  )
  return "curl"
end

local CFG = {
  base_url = PRODUCTION_BACKEND_URL,
  curl = resolve_curl_path(),
  tmp_dir = Util.path_join(Util.path_join(r.GetResourcePath(), "Data"), "Neurocast_Tools_tmp"),
  timeout_sec = 60,
  max_concurrent_jobs = 2,
  max_concurrent_IVC_jobs = 1,
  curl_connect_timeout_sec = 20,
  curl_speed_limit = 1,
  curl_speed_time = 60,
  button_cooldown_sec = 0.4,
  retry_base_backoff_sec = 1.0,
  max_wait_time_for_retry = 12.0,
  retry_jitter_ratio = 0.0,
  auth_max_attempts = 3,
  manager_max_attempts = 3
}

local ok_tmp_dir, tmp_dir_err = Files.ensure_tmp_dir(CFG.tmp_dir)
if not ok_tmp_dir then
  package.path = old_package_path
  r.MB(
    "ElevenLabs Manager cannot initialize its temporary directory:\n\n" ..
      tostring(tmp_dir_err or CFG.tmp_dir),
    APP_NAME,
    0
  )
  return
end

Util.messaging_level = 3
Util.msg_to_log_file = false
Util.log_level_override = nil
Util.full_path_to_log_file = nil
Util.configure_diagnostics(ENTRYPOINT)

local EXT = {
  AUTH_SECTION = "d2elwegrs",
  AUTH_REFRESH = "art1elm",
  AUTH_EMAIL = "amlueselm",
  AUTH_BACKEND = "art1elmb",
  UI_SECTION = "elevenlabs_manager_ui",
  UI_SHOW_STATUS = "show_status_window"
}

local ctx = ImGui.CreateContext(APP_NAME .. " " .. SCRIPT_VERSION)
local ctx_status = ImGui.CreateContext(APP_NAME .. " Status " .. SCRIPT_VERSION)
local FONT = ImGui.CreateFont("monospace")
ImGui.Attach(ctx, FONT)

local S = {
  email = "",
  password = "",
  remember_me = true,
  access_token = "",
  refresh_token = "",
  has_stored_refresh = false,
  backend_base_url = CFG.base_url,
  accounts = {},
  accounts_by_id = {},
  users = {},
  status_text = "Studio Neurocast login is required.",
  last_api_error = "",
  warnings = {},
  show_status_window = false,
  action_active = false,
  action_user_id = nil,
  action_target = nil,
  startup_auth_attempted = false,
  retry_queue = {},
  retry_generation = 0,
  cleanup_queue = {},
  cleanup_failures = {},
  curl_jobs = {},
  req_count = 0,
  records = {},
  telemetry_ui_status = "",
  sort_column = 1,
  sort_ascending = true,
  last_curl_return = {
    ok = "",
    http = "",
    body = "",
    headers_txt = "",
    meta = "",
    err = "",
    cmd = ""
  }
}

local TelemetryBridge = { closed_event_sent = false }

function TelemetryBridge.safe_event(event_name, data, opts)
  local ok, result = Telemetry.safe_event(event_name, data or {}, opts or {})
  if ok == false and result ~= nil then
    S.telemetry_ui_status = "Telemetry event failed: " .. tostring(result)
  end
  return ok, result
end

function TelemetryBridge.safe_tick(now_t)
  local ok, result = Telemetry.safe_tick(now_t)
  if ok == false and result ~= nil then
    S.telemetry_ui_status = "Telemetry tick failed: " .. tostring(result)
  end
  return ok, result
end

function TelemetryBridge.safe_flush(reason)
  local ok, result = Telemetry.safe_flush_async({
    reason = reason or "manager",
    timeout_sec = 60,
    connect_timeout_sec = 15,
    speed_limit = 1,
    speed_time = 30
  })
  if ok then
    S.telemetry_ui_status = "Telemetry flush started."
  else
    S.telemetry_ui_status = "Telemetry flush failed: " .. tostring(result or "")
  end
  return ok, result
end

function TelemetryBridge.describe_status()
  local ok, value = pcall(Telemetry.describe_status)
  if ok and type(value) == "table" then return value end
  return {
    initialized = false,
    status = "telemetry status unavailable",
    last_error = tostring(value or ""),
    progress_line = "",
    active_job_phase = ""
  }
end

function TelemetryBridge.progress_text(desc)
  local progress = tostring(desc and desc.progress_line or "")
  if progress == "" and desc and desc.active_job_phase and desc.active_job_phase ~= "" then
    progress = tostring(desc.active_job_phase)
  end
  if progress == "" then progress = "-" end
  return progress
end

function TelemetryBridge.level_label(level)
  local normalized = tostring(level or "")
  if normalized == "basic" then return "Basic" end
  if normalized == "support" then return "Support" end
  if normalized == "debug" then return "Debug" end
  return normalized
end

function TelemetryBridge.header_state(desc)
  if not desc or desc.initialized ~= true then return "unavailable" end
  if desc.send_paused then return "paused, see details" end
  if desc.active_job_id ~= nil then
    local progress = TelemetryBridge.progress_text(desc)
    if progress ~= "-" then
      return string.format("flushing, %s", Util.clip_text(progress, 32))
    end
    return "flushing"
  end
  if trim(desc.last_error or "") ~= "" or trim(desc.last_backend_error or "") ~= "" then
    return "fail, see details inside"
  end
  local pending_bytes =
    (tonumber(desc.sendable_queue_bytes) or 0) +
    (tonumber(desc.current_queue_bytes) or 0)
  local pending_files =
    (tonumber(desc.queued_file_count) or 0) +
    (tonumber(desc.sending_file_count) or 0)
  if pending_bytes > 0 or pending_files > 0 then return "queued" end
  return "idle"
end

function TelemetryBridge.status_ok(desc)
  if not desc or desc.initialized ~= true then return false end
  if desc.send_paused then return false end
  if trim(desc.last_error or "") ~= "" or trim(desc.last_backend_error or "") ~= "" then
    return false
  end
  return true
end

function TelemetryBridge.status_color(desc)
  if TelemetryBridge.status_ok(desc) then return 0x00C853FF end
  return 0xD50000FF
end

function TelemetryBridge.record_started(rec)
  if rec._telemetry_started then return end
  rec._telemetry_started = r.time_precise()
  TelemetryBridge.safe_event("operation_started", {
    operation = rec.operation,
    status = "started",
    request_label = rec.label,
    endpoint = rec.endpoint
  }, { operation = rec.operation, status = "started" })
end

function TelemetryBridge.record_finished(rec, ok, safe_message)
  local event_name = ok and "operation_completed" or "operation_failed"
  local elapsed_ms = nil
  if rec._telemetry_started then
    elapsed_ms = math.floor(math.max(0, r.time_precise() - rec._telemetry_started) * 1000 + 0.5)
  end
  TelemetryBridge.safe_event(event_name, {
    operation = rec.operation,
    status = ok and "completed" or "failed",
    request_label = rec.label,
    endpoint = rec.endpoint,
    http_code = rec.http_code,
    duration_ms = elapsed_ms,
    safe_message = trim(safe_message)
  }, { operation = rec.operation, status = ok and "completed" or "failed", priority = ok and "normal" or "error" })
end

function TelemetryBridge.send_closed_event(reason)
  if TelemetryBridge.closed_event_sent then return end
  TelemetryBridge.closed_event_sent = true
  TelemetryBridge.safe_event("script_closed", {
    operation = "elevenlabs_manager_lifecycle",
    status = "closed",
    reason = tostring(reason or "closed")
  }, { operation = "elevenlabs_manager_lifecycle", status = "closed" })
  pcall(Telemetry.flush_current_queue_fire_and_forget, {
    reason = "script_closed",
    curl_path = CFG.curl,
    timeout_sec = 12,
    connect_timeout_sec = 5,
    speed_limit = 1,
    speed_time = 15
  })
end

r.atexit(function()
  TelemetryBridge.send_closed_event("atexit")
  package.path = old_package_path
end)

Curl.init(S, CFG)
Jobs.init(S, CFG)

local AUTH_CLIENT = nil
local MANAGER_CLIENT = nil
local AUTH_REFRESH_GATE = NeurocastAuth.create_refresh_gate()
local Auth = {}
local Manager = {}

local function push_warning(message)
  local text = trim(message)
  if text == "" then return end
  S.warnings[#S.warnings + 1] = text
  if #S.warnings > 8 then table.remove(S.warnings, 1) end
end

local function now_stamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function next_request_id()
  S.req_count = S.req_count + 1
  return S.req_count
end

local function active_backend()
  return ManagerApi.resolve_base_url(S.backend_base_url)
end

local function update_last_curl(result, job, label)
  Curl.update_last_curl_state(result, job, label)
end

local function tracked_curl_submit(req, on_done, opts)
  return Curl.curl_submit(req, function(result, job)
    update_last_curl(result, job, req.label or "Manager request")
    if type(on_done) == "function" then on_done(result, job) end
  end, opts)
end

local function rebuild_clients()
  local base_url = active_backend()
  AUTH_CLIENT = NeurocastAuth.create_client({
    base_url = base_url,
    curl_submit_fn = tracked_curl_submit,
    ext_section = EXT.AUTH_SECTION,
    ext_refresh_key = EXT.AUTH_REFRESH,
    remember_refresh = true
  })
  MANAGER_CLIENT = ManagerApi.create_client({
    base_url = base_url,
    access_token_fn = function() return S.access_token end
  })
  CFG.base_url = base_url
end

local function sync_tokens_from_client()
  if not AUTH_CLIENT then return end
  local tokens = AUTH_CLIENT.get_tokens() or {}
  S.access_token = tostring(tokens.access_token or "")
  S.refresh_token = tostring(tokens.refresh_token or "")
  S.has_stored_refresh = S.refresh_token ~= ""
end

local function persist_email()
  if trim(S.email) ~= "" then
    Util.extstate_set_camo(EXT.AUTH_SECTION, EXT.AUTH_EMAIL, trim(S.email), true)
  end
end

local function load_email()
  local value = Util.extstate_get_camo(EXT.AUTH_SECTION, EXT.AUTH_EMAIL)
  return trim(value)
end

local function persist_auth_backend()
  Util.extstate_set_camo(EXT.AUTH_SECTION, EXT.AUTH_BACKEND, active_backend(), true)
end

local function load_auth_backend()
  local value = Util.extstate_get_camo(EXT.AUTH_SECTION, EXT.AUTH_BACKEND)
  value = ManagerApi.resolve_base_url(value)
  if value == PRODUCTION_BACKEND_URL or value == "http://localhost:3002" then return value end
  return nil
end

local function apply_remember_policy()
  sync_tokens_from_client()
  if S.remember_me then
    if S.refresh_token ~= "" then AUTH_CLIENT.persist_refresh_token(S.refresh_token) end
    persist_email()
    persist_auth_backend()
  else
    AUTH_CLIENT.forget_refresh_token()
    Util.extstate_delete(EXT.AUTH_SECTION, EXT.AUTH_EMAIL, true)
    Util.extstate_delete(EXT.AUTH_SECTION, EXT.AUTH_BACKEND, true)
  end
  sync_tokens_from_client()
end

local function create_record(kind, endpoint, label, operation, max_attempts)
  local rec = {
    id = string.format("%s_%04d", kind, next_request_id()),
    kind = kind,
    endpoint = endpoint,
    label = label,
    operation = operation,
    created_at = r.time_precise(),
    created_at_str = now_stamp(),
    job_id = nil,
    state = "queued",
    attempt = 0,
    max_attempts = max_attempts or CFG.manager_max_attempts,
    refresh_used = false,
    next_retry_at = nil,
    http_code = nil,
    error = ""
  }
  table.insert(S.records, 1, rec)
  return rec
end

local function default_submit_opts()
  return {
    read_body = true,
    body_max_bytes = 2 * 1024 * 1024,
    timeout_sec = CFG.timeout_sec,
    keep_output = false
  }
end

local function result_error(result)
  local api_error = ManagerApi.parse_api_error(result and result.body or nil)
  if trim(api_error) ~= "" then return api_error end
  if result and trim(result.err) ~= "" then return tostring(result.err) end
  return "request failed"
end

local function manager_directory_error(resource_name, message, result)
  local http_code = tonumber(result and result.http_code or 0) or 0
  if http_code == 404 then
    return string.format(
      "The Reaper Manager %s route is not available on the active backend:\n%s\n\n" ..
        "This manager has been verified against the local development backend. " ..
        "Select 'Use local development' and log in again, or wait until the manager routes are deployed here.",
      tostring(resource_name or "directory"),
      active_backend()
    )
  end
  return tostring(message or "request failed")
end

local function submit_record(rec, request_builder, response_parser, on_success, on_failure, options)
  options = options or {}

  local function finish_failure(message, result)
    rec.state = "failed"
    rec.error = trim(message) ~= "" and trim(message) or "request failed"
    rec.http_code = result and result.http_code or rec.http_code
    S.last_api_error = rec.error
    S.status_text = rec.label .. " failed: " .. rec.error
    push_warning(S.status_text)
    TelemetryBridge.record_finished(rec, false, rec.error)
    if type(on_failure) == "function" then on_failure(rec.error, result, rec) end
  end

  local function run_attempt(attempt)
    rec.attempt = attempt
    rec.error = ""
    rec.next_retry_at = nil

    local function submit_current_attempt()
      rec.state = "running"
      TelemetryBridge.record_started(rec)

      local req, build_err = request_builder()
      if not req then
        finish_failure(build_err or "request build failed")
        return
      end

      local job, submit_err = tracked_curl_submit(req, function(result, job_ref)
        rec.http_code = result and result.http_code or nil
        rec.job_id = job_ref and job_ref.id or rec.job_id

        if result and result.ok == true then
          local parsed, parse_err = response_parser(result.body)
          if not parsed then
            finish_failure(parse_err or "response validation failed", result)
            return
          end
          rec.state = "ok"
          rec.error = ""
          S.last_api_error = ""
          S.status_text = rec.label .. " completed."
          TelemetryBridge.record_finished(rec, true)
          if type(on_success) == "function" then on_success(parsed, result, rec) end
          return
        end

        if options.allow_refresh_401 and
            tonumber(result and result.http_code or 0) == 401 and
            rec.refresh_used ~= true then
          rec.refresh_used = true
          rec.state = "refreshing"
          local queued, refresh_err = Auth.request_shared_refresh(
            "Refresh before " .. rec.label,
            function(ok_refresh, refresh_payload)
              if ok_refresh and trim(S.access_token) ~= "" then
                run_attempt(attempt)
                return
              end
              local refresh_error = refresh_payload and
                (refresh_payload.api_error or refresh_payload.error) or "refresh failed"
              finish_failure("authentication refresh failed: " .. tostring(refresh_error), result)
            end
          )
          if not queued then
            finish_failure("authentication refresh failed: " .. tostring(refresh_err), result)
          end
          return
        end

        local message = result_error(result)
        local retryable = Jobs.is_retryable_result(result)
        if retryable and attempt < rec.max_attempts then
          local next_attempt = attempt + 1
          rec.state = "retrying"
          rec.error = message
          local ok_retry, retry_err = Jobs.enqueue_retry(
            Jobs.format_attempt_label(rec.label, next_attempt, rec.max_attempts),
            function() run_attempt(next_attempt) end,
            next_attempt,
            rec.max_attempts,
            message,
            rec
          )
          if ok_retry then return end
          finish_failure(retry_err or message, result)
          return
        end
        finish_failure(message, result)
      end, default_submit_opts())

      if not job then
        finish_failure(submit_err or "request could not be started")
        return
      end
      rec.job_id = job.id
    end

    if options.allow_refresh_401 and options.allow_proactive_refresh ~= false then
      local timing, timing_err = AUTH_CLIENT.access_token_refresh_status(S.access_token)
      if timing and timing.refresh_due == true then
        rec.state = "refreshing"
        local queued, refresh_err = Auth.request_shared_refresh(
          "Proactive refresh before " .. rec.label,
          function(ok_refresh, refresh_payload)
            if ok_refresh and trim(S.access_token) ~= "" then
              submit_current_attempt()
              return
            end
            local message = refresh_payload and
              (refresh_payload.api_error or refresh_payload.error) or "refresh failed"
            finish_failure("authentication refresh failed: " .. tostring(message))
          end
        )
        if not queued then
          finish_failure("authentication refresh failed: " .. tostring(refresh_err))
        end
        return
      end
      if timing_err then
        Util.msg(
          "Studio access-token timing unavailable; keeping 401 fallback: " .. tostring(timing_err),
          1
        )
      end
    end

    submit_current_attempt()
  end

  run_attempt(1)
end

function Auth.request_refresh(label, on_done)
  local rec = create_record("Auth", "refresh", label or "Refresh login", "manager_auth_refresh", CFG.auth_max_attempts)
  local done = false
  submit_record(
    rec,
    function()
      local req, err = AUTH_CLIENT.build_refresh_request(S.refresh_token)
      return req, err
    end,
    function(body)
      return AUTH_CLIENT.parse_token_body(body)
    end,
    function(parsed, result)
      AUTH_CLIENT.set_tokens(parsed.access_token, parsed.refresh_token)
      sync_tokens_from_client()
      apply_remember_policy()
      done = true
      if type(on_done) == "function" then
        on_done(true, { ok = true, http_code = result.http_code })
      end
    end,
    function(message, result)
      local http_code = tonumber(result and result.http_code or 0) or 0
      if NeurocastAuth.is_invalid_refresh_http_status(http_code) then
        AUTH_CLIENT.clear_runtime_tokens()
        AUTH_CLIENT.forget_refresh_token()
        Util.extstate_delete(EXT.AUTH_SECTION, EXT.AUTH_BACKEND, true)
        S.access_token = ""
        S.refresh_token = ""
        S.has_stored_refresh = false
      end
      sync_tokens_from_client()
      done = true
      if type(on_done) == "function" then
        on_done(false, { ok = false, http_code = result and result.http_code, error = message })
      end
    end,
    { allow_refresh_401 = false }
  )
  return done or true
end

function Auth.request_shared_refresh(label, on_done)
  local queued, queue_err = AUTH_REFRESH_GATE.request(
    function(done)
      return Auth.request_refresh(label, function(ok, payload)
        done(ok, payload)
      end)
    end,
    function(payload)
      if type(on_done) == "function" then on_done(true, payload) end
    end,
    function(payload)
      if type(on_done) == "function" then on_done(false, payload) end
    end
  )
  if not queued and AUTH_REFRESH_GATE.is_in_flight() ~= true then
    return false, queue_err or "Studio login refresh could not be started."
  end
  return true, nil
end

function Auth.request_login()
  local email = trim(S.email)
  if email == "" or not email:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
    S.status_text = "Enter a valid Studio Neurocast email."
    S.last_api_error = S.status_text
    push_warning(S.status_text)
    return false
  end
  if S.password == "" then
    S.status_text = "Enter the Studio Neurocast password."
    S.last_api_error = S.status_text
    push_warning(S.status_text)
    return false
  end

  local rec = create_record("Auth", "login", "Studio login", "manager_auth_login", CFG.auth_max_attempts)
  submit_record(
    rec,
    function() return AUTH_CLIENT.build_login_request(email, S.password) end,
    function(body) return AUTH_CLIENT.parse_token_body(body) end,
    function(parsed)
      AUTH_CLIENT.set_tokens(parsed.access_token, parsed.refresh_token)
      S.password = ""
      sync_tokens_from_client()
      apply_remember_policy()
      S.status_text = "Studio login completed. Loading manager data."
      Manager.load_all()
    end,
    function(message)
      S.password = ""
      r.MB("Studio Neurocast login failed:\n" .. tostring(message), APP_NAME, 0)
    end,
    { allow_refresh_401 = false }
  )
  return true
end

function Auth.forget_login()
  AUTH_CLIENT.clear_runtime_tokens()
  AUTH_CLIENT.forget_refresh_token()
  Util.extstate_delete(EXT.AUTH_SECTION, EXT.AUTH_EMAIL, true)
  Util.extstate_delete(EXT.AUTH_SECTION, EXT.AUTH_BACKEND, true)
  S.email = ""
  S.password = ""
  S.access_token = ""
  S.refresh_token = ""
  S.has_stored_refresh = false
  S.accounts = {}
  S.accounts_by_id = {}
  S.users = {}
  S.status_text = "Stored Studio login cleared."
  S.last_api_error = ""
end

local function replace_accounts(accounts)
  S.accounts = accounts
  S.accounts_by_id = {}
  for _, account in ipairs(accounts) do
    S.accounts_by_id[account.accountId] = account
  end
end

local function replace_users(users)
  S.users = users
end

function Manager.fetch_accounts(on_done)
  local rec = create_record("Manager", "accounts", "Fetch manager accounts", "manager_accounts_fetch")
  submit_record(
    rec,
    function() return MANAGER_CLIENT:accounts_request(rec.label) end,
    ManagerApi.parse_accounts,
    function(accounts)
      replace_accounts(accounts)
      S.status_text = string.format("Manager accounts loaded: %d.", #accounts)
      if type(on_done) == "function" then on_done(true, accounts) end
    end,
    function(message, result)
      local display_message = manager_directory_error("accounts", message, result)
      if type(on_done) == "function" then on_done(false, display_message) end
    end,
    { allow_refresh_401 = true }
  )
end

function Manager.fetch_users(on_done, label)
  local rec = create_record("Manager", "users", label or "Fetch manager users", "manager_users_fetch")
  submit_record(
    rec,
    function() return MANAGER_CLIENT:users_request(rec.label) end,
    ManagerApi.parse_users,
    function(users)
      replace_users(users)
      S.status_text = string.format("Manager users loaded: %d.", #users)
      if type(on_done) == "function" then on_done(true, users) end
    end,
    function(message, result)
      local display_message = manager_directory_error("users", message, result)
      if type(on_done) == "function" then on_done(false, display_message) end
    end,
    { allow_refresh_401 = true }
  )
end

function Manager.load_all()
  if trim(S.access_token) == "" then
    S.status_text = "Studio Neurocast login is required."
    return false
  end
  Manager.fetch_accounts(function(ok_accounts, accounts_or_error)
    if not ok_accounts then
      r.MB("Could not load manager accounts:\n" .. tostring(accounts_or_error), APP_NAME, 0)
      return
    end
    Manager.fetch_users(function(ok_users, users_or_error)
      if not ok_users then
        r.MB("Could not load manager users:\n" .. tostring(users_or_error), APP_NAME, 0)
      end
    end)
  end)
  return true
end

local function find_user(users, user_id)
  for _, user in ipairs(users or {}) do
    if tostring(user.userId) == tostring(user_id) then return user end
  end
  return nil
end

local function target_matches(user, target)
  if not user then return false end
  if target == "blocked" then
    return user.accountId == nil and user.state == "unassigned"
  end
  return tostring(user.accountId or "") == tostring(target) and user.state == "assigned"
end

local function finish_action_failure(message)
  S.action_active = false
  S.action_user_id = nil
  S.action_target = nil
  local text = "Assignment action failed: " .. tostring(message or "unknown error")
  S.status_text = text
  S.last_api_error = tostring(message or "unknown error")
  push_warning(text)
  r.MB(text, APP_NAME, 0)
end

function Manager.perform_action(user, target)
  if S.action_active or Jobs.network_busy() then return false end
  if not user or trim(user.userId) == "" then
    finish_action_failure("Selected user has no userId.")
    return false
  end
  if target_matches(user, target) then return false end

  S.action_active = true
  S.action_user_id = user.userId
  S.action_target = target
  local display_name = trim(user.fullname) ~= "" and trim(user.fullname) or user.email
  local target_label = target == "blocked" and "Blocked" or (target == "elevenlabs_1" and "el_1" or "el_2")
  local operation = target == "blocked" and "manager_assignment_block" or "manager_assignment_set"
  local rec = create_record("Manager", "assignment", display_name .. " -> " .. target_label, operation)

  submit_record(
    rec,
    function()
      if target == "blocked" then
        return MANAGER_CLIENT:block_request(user.userId, rec.label)
      end
      return MANAGER_CLIENT:assign_request(user.userId, target, rec.label)
    end,
    ManagerApi.parse_mutation,
    function()
      Manager.fetch_users(function(ok_users, users_or_error)
        if not ok_users then
          finish_action_failure(
            "The assignment request succeeded, but the required user-directory readback failed: " ..
              tostring(users_or_error)
          )
          return
        end
        local refreshed = find_user(users_or_error, user.userId)
        if not target_matches(refreshed, target) then
          finish_action_failure("Backend readback did not confirm the requested assignment.")
          return
        end
        S.action_active = false
        S.action_user_id = nil
        S.action_target = nil
        S.status_text = display_name .. " is now " .. target_label .. "."
        S.last_api_error = ""
      end, "Verify assignment readback")
    end,
    function(message)
      finish_action_failure(message)
    end,
    { allow_refresh_401 = true }
  )
  return true
end

local function set_backend(base_url)
  if S.action_active or Jobs.network_busy() then return end
  local normalized = ManagerApi.resolve_base_url(base_url)
  if normalized == active_backend() then return end
  AUTH_CLIENT.clear_runtime_tokens()
  S.backend_base_url = normalized
  S.access_token = ""
  S.refresh_token = ""
  S.has_stored_refresh = false
  S.accounts = {}
  S.accounts_by_id = {}
  S.users = {}
  rebuild_clients()
  local stored_base = load_auth_backend()
  if stored_base == normalized then
    local stored_refresh = AUTH_CLIENT.load_refresh_token()
    if trim(stored_refresh) ~= "" then
      S.refresh_token = stored_refresh
      S.has_stored_refresh = true
    end
  end
  S.status_text = "Backend changed to " .. normalized .. ". Login or refresh is required."
end

local function load_persisted_ui()
  local show_status = Util.extstate_get(EXT.UI_SECTION, EXT.UI_SHOW_STATUS)
  S.show_status_window = tostring(show_status or "") == "1"
  local stored_base = load_auth_backend()
  if stored_base then S.backend_base_url = stored_base end
  rebuild_clients()
  S.email = load_email()
  local stored_refresh = AUTH_CLIENT.load_refresh_token()
  if trim(stored_refresh) ~= "" and stored_base == active_backend() then
    S.refresh_token = stored_refresh
    S.has_stored_refresh = true
  end
  AUTH_CLIENT.set_tokens("", S.refresh_token)
end

local function try_startup_auth()
  if S.startup_auth_attempted then return end
  S.startup_auth_attempted = true
  if not S.has_stored_refresh then return end
  Auth.request_refresh("Startup Studio refresh", function(ok_refresh, payload)
    if ok_refresh then
      S.status_text = "Stored Studio login refreshed. Loading manager data."
      Manager.load_all()
    else
      S.status_text = "Stored Studio login refresh failed. Manual login is required."
      S.last_api_error = tostring(payload and payload.error or "refresh failed")
      push_warning(S.status_text)
    end
  end)
end

local button_last_click = {}
local function button_clicked(id, label, ui_ctx)
  local button_ctx = ui_ctx or ctx
  local locked = S.action_active == true
  if locked then ImGui.BeginDisabled(button_ctx, true) end
  local now_t = Jobs.now()
  local clicked = ImGui.Button(button_ctx, label)
  if locked then ImGui.EndDisabled(button_ctx) end
  if not clicked then return false end
  local last = button_last_click[id]
  if last and now_t - last < CFG.button_cooldown_sec then return false end
  button_last_click[id] = now_t
  TelemetryBridge.safe_event("button_clicked", {
    operation = "elevenlabs_manager_ui",
    status = "clicked",
    button_id = id,
    button_label = label:gsub("##.*$", "")
  }, { operation = "elevenlabs_manager_ui", status = "clicked", priority = "low" })
  return true
end

local function diagnostics_label(level)
  return ({ [0] = "Debug", [1] = "Info", [2] = "Warnings", [3] = "Errors", [4] = "Off" })[level] or "Off"
end

local function draw_diagnostics_settings()
  local diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, "Logging threshold:")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 150)
  if ImGui.BeginCombo(ctx, "##manager_logging", diagnostics_label(diagnostics.logging_threshold)) then
    for _, level in ipairs({ 4, 0, 1, 2, 3 }) do
      local selected = diagnostics.logging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_label(level), selected) then
        local ok_set, err = Util.set_logging_threshold(level)
        if not ok_set then push_warning("Logging setting failed: " .. tostring(err)) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
  diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, "Messaging threshold:")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 150)
  if ImGui.BeginCombo(ctx, "##manager_messaging", diagnostics_label(diagnostics.messaging_threshold)) then
    for _, level in ipairs({ 0, 1, 2, 3, 4 }) do
      local selected = diagnostics.messaging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_label(level), selected) then
        local ok_set, err = Util.set_messaging_threshold(level)
        if not ok_set then push_warning("Messaging setting failed: " .. tostring(err)) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
  diagnostics = Util.get_diagnostics_state()
  ImGui.TextWrapped(ctx, "Log folder: " .. tostring(diagnostics.log_dir or ""))
  if button_clicked("copy_log_folder", "Copy log folder", ctx) then
    ImGui.SetClipboardText(ctx, diagnostics.log_dir or "")
  end
end

local function draw_telemetry_setting()
  local desc = TelemetryBridge.describe_status()
  local current = tostring(desc.effective_level or "support")
  local current_label = TelemetryBridge.level_label(current)
  ImGui.SetNextItemWidth(ctx, 150)
  if ImGui.BeginCombo(ctx, "Telemetry level##manager_telemetry_level", current_label, ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ "basic", "support", "debug" }) do
      local selected = current == level
      local level_label = TelemetryBridge.level_label(level)
      if ImGui.Selectable(ctx, level_label, selected) then
        local ok_call, ok_set, err = pcall(Telemetry.set_level, level)
        if not ok_call or not ok_set then
          push_warning("Telemetry level change failed: " .. tostring(ok_call and err or ok_set))
        else
          S.telemetry_ui_status = "Telemetry level set to " .. level_label .. "."
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

local function draw_settings()
  if not ImGui.CollapsingHeader(ctx, "Settings") then return end
  ImGui.SeparatorText(ctx, "Account / Credentials")
  ImGui.SetNextItemWidth(ctx, 360)
  local email_changed, email_value = ImGui.InputText(ctx, "Email", S.email)
  if email_changed then S.email = email_value end
  ImGui.SetNextItemWidth(ctx, 360)
  local pass_changed, pass_value = ImGui.InputText(ctx, "Password", S.password, ImGui.InputTextFlags_Password)
  if pass_changed then S.password = pass_value end
  local remember_changed, remember_value = ImGui.Checkbox(ctx, "Remember me", S.remember_me)
  if remember_changed then S.remember_me = remember_value end

  local auth_busy = S.action_active or Jobs.network_busy()
  if auth_busy then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("login", "Login", ctx) then Auth.request_login() end
  ImGui.SameLine(ctx)
  if button_clicked("refresh_login", "Refresh stored login", ctx) then
    Auth.request_refresh("Manual Studio refresh", function(ok_refresh)
      if ok_refresh then Manager.load_all() end
    end)
  end
  ImGui.SameLine(ctx)
  if button_clicked("forget_login", "Forget stored login", ctx) then Auth.forget_login() end
  if auth_busy then ImGui.EndDisabled(ctx) end

  ImGui.TextWrapped(ctx, "Active backend: " .. active_backend())
  ImGui.Text(ctx, S.has_stored_refresh and "Stored login: available" or "Stored login: unavailable")

  ImGui.SeparatorText(ctx, "Backend")
  if auth_busy then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("backend_production", "Use production", ctx) then
    set_backend(PRODUCTION_BACKEND_URL)
  end
  ImGui.SameLine(ctx)
  if button_clicked("backend_local", "Use local development", ctx) then
    set_backend("http://localhost:3002")
  end
  if auth_busy then ImGui.EndDisabled(ctx) end

  ImGui.SeparatorText(ctx, "Diagnostics")
  draw_diagnostics_settings()
  ImGui.SeparatorText(ctx, "Telemetry")
  draw_telemetry_setting()
end

local function account_display(account_id)
  if account_id == nil or trim(account_id) == "" then return "Blocked" end
  if account_id == "elevenlabs_1" then return "el_1" end
  if account_id == "elevenlabs_2" then return "el_2" end
  return tostring(account_id)
end

local function sort_text(value)
  local lowered = Utf8Tools.lower(trim(value))
  if type(lowered) == "string" then return lowered end
  return trim(value):lower()
end

local function user_sort_source(user, column)
  if column == 1 then return trim(user.fullname) end
  if column == 2 then return trim(user.username) end
  if column == 3 then return trim(user.email) end
  if column == 4 then return account_display(user.accountId) end
  return trim(user.fullname)
end

local function sorted_users()
  local rows = {}
  for index, user in ipairs(S.users) do
    rows[index] = user
  end
  table.sort(rows, function(a, b)
    local a_source = user_sort_source(a, S.sort_column)
    local b_source = user_sort_source(b, S.sort_column)
    local a_missing = trim(a_source) == ""
    local b_missing = trim(b_source) == ""
    if a_missing ~= b_missing then return not a_missing end
    local av = sort_text(a_source)
    local bv = sort_text(b_source)
    if av == bv then
      av = trim(a.userId)
      bv = trim(b.userId)
    end
    if S.sort_ascending then return av < bv end
    return av > bv
  end)
  return rows
end

local function table_buttons_locked()
  return S.action_active or Jobs.network_busy() or trim(S.access_token) == ""
end

local function draw_assignment_button(user, label, target, available)
  local current = target_matches(user, target)
  local disabled = table_buttons_locked() or current or available == false
  if current then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x237A3BFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x237A3BFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x237A3BFF)
  end
  if disabled then ImGui.BeginDisabled(ctx, true) end
  if ImGui.SmallButton(ctx, label .. "##" .. tostring(user.userId) .. "_" .. target) then
    TelemetryBridge.safe_event("button_clicked", {
      operation = "elevenlabs_manager_assignment_button",
      status = "clicked",
      target_account = target
    }, { operation = "elevenlabs_manager_assignment_button", status = "clicked", priority = "low" })
    Manager.perform_action(user, target)
  end
  if disabled then ImGui.EndDisabled(ctx) end
  if current then ImGui.PopStyleColor(ctx, 3) end

  if ImGui.IsItemHovered(ctx) then
    local tooltip = nil
    if target == "blocked" then
      tooltip = "Remove the user's ElevenLabs assignment."
    else
      local account = S.accounts_by_id[target]
      tooltip = account and account.label or target
      if available == false then tooltip = tooltip .. " (unavailable)" end
    end
    ImGui.SetTooltip(ctx, tooltip)
  end
end

local function update_table_sort()
  local changed, has_specs = ImGui.TableNeedSort(ctx)
  if not changed or not has_specs then return end
  local has_spec, _, user_id, direction = ImGui.TableGetColumnSortSpecs(ctx, 0)
  if has_spec and tonumber(user_id) and tonumber(user_id) >= 1 and tonumber(user_id) <= 4 then
    S.sort_column = tonumber(user_id)
    S.sort_ascending = direction ~= ImGui.SortDirection_Descending
  end
end

local function draw_users_table()
  ImGui.SeparatorText(ctx, "User assignments")
  ImGui.Text(ctx, string.format("Users: %d", #S.users))
  ImGui.SameLine(ctx)
  local refresh_disabled = S.action_active or Jobs.network_busy() or trim(S.access_token) == ""
  if refresh_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("refresh_users", "Refresh users", ctx) then
    Manager.fetch_users(function(ok_users, error_message)
      if not ok_users then r.MB("Could not refresh users:\n" .. tostring(error_message), APP_NAME, 0) end
    end)
  end
  if refresh_disabled then ImGui.EndDisabled(ctx) end

  local flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_Sortable
  local table_height = ImGui.GetFrameHeightWithSpacing(ctx) * 13
  if ImGui.BeginTable(ctx, "##manager_users_table", 5, flags, -1, table_height) then
    ImGui.TableSetupColumn(
      ctx,
      "Name",
      ImGui.TableColumnFlags_WidthStretch | ImGui.TableColumnFlags_DefaultSort,
      0.25,
      1
    )
    ImGui.TableSetupColumn(ctx, "Username", ImGui.TableColumnFlags_WidthFixed, 125, 2)
    ImGui.TableSetupColumn(ctx, "Email", ImGui.TableColumnFlags_WidthStretch, 0.35, 3)
    ImGui.TableSetupColumn(ctx, "Current", ImGui.TableColumnFlags_WidthFixed, 85, 4)
    ImGui.TableSetupColumn(
      ctx,
      "Action",
      ImGui.TableColumnFlags_WidthFixed | ImGui.TableColumnFlags_NoSort,
      170,
      5
    )
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableHeadersRow(ctx)
    update_table_sort()

    local account_1 = S.accounts_by_id.elevenlabs_1
    local account_2 = S.accounts_by_id.elevenlabs_2
    local account_1_available = account_1 ~= nil and account_1.available ~= false
    local account_2_available = account_2 ~= nil and account_2.available ~= false

    for _, user in ipairs(sorted_users()) do
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, trim(user.fullname) ~= "" and user.fullname or "-")
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, trim(user.username) ~= "" and user.username or "-")
      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.Text(ctx, user.email)
      ImGui.TableSetColumnIndex(ctx, 3)
      ImGui.Text(ctx, account_display(user.accountId))
      ImGui.TableSetColumnIndex(ctx, 4)
      draw_assignment_button(user, "el_1", "elevenlabs_1", account_1_available)
      ImGui.SameLine(ctx)
      draw_assignment_button(user, "el_2", "elevenlabs_2", account_2_available)
      ImGui.SameLine(ctx)
      draw_assignment_button(user, "Block", "blocked", true)
    end
    ImGui.EndTable(ctx)
  end
end

local function record_progress(rec)
  if rec.state == "ok" then return "ok" end
  if rec.state == "failed" then return "failed" end
  if rec.state == "refreshing" then return "refreshing login" end
  if rec.state == "retrying" then
    if rec._next_retry_at then
      return string.format("retry in %.1fs", math.max(0, rec._next_retry_at - Jobs.now()))
    end
    return "retrying"
  end
  local job = rec.job_id and S.curl_jobs[rec.job_id] or nil
  local flow = job and job.progress and job.progress.flow and job.progress.flow.line or nil
  if trim(flow) ~= "" then return tostring(flow) end
  return rec.state or "queued"
end

local request_table_record_counts = {}
local function draw_request_table(ui_ctx, suffix)
  local table_ctx = ui_ctx or ctx
  local id_suffix = suffix or ""
  ImGui.SeparatorText(table_ctx, "Request progress")
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable | ImGui.TableFlags_ScrollY
  local table_height = ImGui.GetFrameHeightWithSpacing(table_ctx) * 8
  if ImGui.BeginTable(table_ctx, "##manager_request_table" .. id_suffix, 5, flags, -1, table_height) then
    ImGui.TableSetupColumn(table_ctx, "Flow", ImGui.TableColumnFlags_WidthFixed, 85)
    ImGui.TableSetupColumn(table_ctx, "Request", ImGui.TableColumnFlags_WidthFixed, 250)
    ImGui.TableSetupColumn(table_ctx, "Progress", ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(table_ctx, "HTTP", ImGui.TableColumnFlags_WidthFixed, 55)
    ImGui.TableSetupColumn(table_ctx, "Error", ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupScrollFreeze(table_ctx, 0, 1)
    ImGui.TableHeadersRow(table_ctx)
    local previous_count = request_table_record_counts[id_suffix] or 0
    if #S.records > previous_count and ImGui.SetScrollY then
      ImGui.SetScrollY(table_ctx, 0)
    end
    request_table_record_counts[id_suffix] = #S.records
    if #S.records == 0 then
      ImGui.TableNextRow(table_ctx)
      ImGui.TableSetColumnIndex(table_ctx, 0)
      ImGui.Text(table_ctx, "-")
      ImGui.TableSetColumnIndex(table_ctx, 1)
      ImGui.Text(table_ctx, "No requests yet.")
    else
      for _, rec in ipairs(S.records) do
        ImGui.TableNextRow(table_ctx)
        ImGui.TableSetColumnIndex(table_ctx, 0)
        ImGui.Text(table_ctx, rec.kind)
        ImGui.TableSetColumnIndex(table_ctx, 1)
        ImGui.TextWrapped(table_ctx, string.format("%s [%d/%d]", rec.label, rec.attempt, rec.max_attempts))
        ImGui.TableSetColumnIndex(table_ctx, 2)
        ImGui.TextWrapped(table_ctx, record_progress(rec))
        ImGui.TableSetColumnIndex(table_ctx, 3)
        ImGui.Text(table_ctx, rec.http_code and tostring(rec.http_code) or "-")
        ImGui.TableSetColumnIndex(table_ctx, 4)
        ImGui.TextWrapped(table_ctx, rec.error or "")
      end
    end
    ImGui.EndTable(table_ctx)
  end
end

local function draw_status_panel(ui_ctx)
  local panel_ctx = ui_ctx or ctx
  local color = 0x00C853FF
  if trim(S.last_api_error) ~= "" then color = 0xFF3030FF
  elseif S.action_active or Jobs.network_busy() then color = 0xF0B000FF end
  ImGui.PushStyleColor(panel_ctx, ImGui.Col_Text, color)
  ImGui.TextWrapped(panel_ctx, "Status: " .. tostring(S.status_text or ""))
  ImGui.PopStyleColor(panel_ctx)
  for _, warning in ipairs(S.warnings) do
    ImGui.PushStyleColor(panel_ctx, ImGui.Col_Text, 0xFFB000FF)
    ImGui.TextWrapped(panel_ctx, warning)
    ImGui.PopStyleColor(panel_ctx)
  end
end

local function draw_telemetry_section()
  local desc = TelemetryBridge.describe_status()
  local header_label = string.format("Telemetry (%s)", TelemetryBridge.header_state(desc)) ..
    "###manager_telemetry_section"
  local color = TelemetryBridge.status_color(desc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, color)
  local telemetry_open = ImGui.CollapsingHeader(ctx, header_label)
  ImGui.PopStyleColor(ctx)
  if not telemetry_open then return end

  local progress = TelemetryBridge.progress_text(desc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, color)
  ImGui.TextWrapped(ctx, "Telemetry status: " .. tostring(desc.status or ""))
  ImGui.PopStyleColor(ctx)

  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
  if ImGui.BeginTable(ctx, "##manager_telemetry_status_table", 2, flags, -1, 0) then
    ImGui.TableSetupColumn(ctx, "Field", ImGui.TableColumnFlags_WidthFixed, 180)
    ImGui.TableSetupColumn(ctx, "Value", ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableHeadersRow(ctx)
    local rows = {
      { "Status", tostring(desc.status or "") },
      { "Progress", progress },
      { "Level", TelemetryBridge.level_label(desc.effective_level) },
      { "Queue bytes", tostring(tonumber(desc.sendable_queue_bytes) or 0) },
      {
        "Queued / flushed",
        string.format(
          "%d / %d",
          tonumber(desc.queued_events_session) or 0,
          tonumber(desc.flushed_events_session) or 0
        )
      },
      {
        "Failed / dropped / skipped",
        string.format(
          "%d / %d / %d",
          tonumber(desc.failed_batches_session) or 0,
          tonumber(desc.dropped_events_session) or 0,
          tonumber(desc.skipped_events_session) or 0
        )
      },
      {
        "HTTP / curl",
        string.format(
          "%s / %s",
          tostring(desc.last_http_code or "-"),
          tostring(desc.last_curl_exitcode or "-")
        )
      }
    }
    for _, row in ipairs(rows) do
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.TextWrapped(ctx, row[1])
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.TextWrapped(ctx, row[2])
    end
    ImGui.EndTable(ctx)
  end

  if trim(S.telemetry_ui_status) ~= "" then ImGui.TextWrapped(ctx, S.telemetry_ui_status) end

  local flush_disabled = desc.active_job_id ~= nil
  if flush_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("telemetry_flush", "Flush telemetry now", ctx) then
    TelemetryBridge.safe_flush("manager_manual")
  end
  if flush_disabled then ImGui.EndDisabled(ctx) end

  if desc.send_paused then
    ImGui.SameLine(ctx)
    if button_clicked("telemetry_resume", "Resume telemetry sending", ctx) then
      local ok_resume, resume_or_err = pcall(Telemetry.resume_sending, "manual resume from ElevenLabs Manager UI")
      S.telemetry_ui_status = ok_resume and "Telemetry sending resumed." or
        "Telemetry resume failed: " .. tostring(resume_or_err)
    end
  end

  ImGui.SameLine(ctx)
  if button_clicked("telemetry_copy_paths", "Copy telemetry paths", ctx) then
    local paths = desc.paths or {}
    ImGui.SetClipboardText(ctx, table.concat({
      "settings_path: " .. tostring(desc.settings_path or ""),
      "queue_path: " .. tostring(desc.queue_path or ""),
      "runtime_root: " .. tostring(paths.root or ""),
      "queues: " .. tostring(paths.queues or ""),
      "sending: " .. tostring(paths.sending or ""),
      "failed: " .. tostring(paths.failed or ""),
      "logs: " .. tostring(paths.logs or ""),
      "close_send: " .. tostring(paths.close_send or "")
    }, "\n"))
    S.telemetry_ui_status = "Telemetry paths copied."
  end

  local details = {
    "initialized: " .. tostring(desc.initialized == true),
    "settings_path: " .. tostring(desc.settings_path or ""),
    "queue_path: " .. tostring(desc.queue_path or ""),
    "runtime_root: " .. tostring(desc.paths and desc.paths.root or ""),
    "effective_level: " .. tostring(desc.effective_level or ""),
    "send_paused: " .. tostring(desc.send_paused == true),
    "send_pause_reason: " .. tostring(desc.send_pause_reason or ""),
    "active_job_id: " .. tostring(desc.active_job_id or ""),
    "active_source_file: " .. tostring(desc.active_source_file or ""),
    "queued_file_count: " .. tostring(desc.queued_file_count or 0),
    "sending_file_count: " .. tostring(desc.sending_file_count or 0),
    "failed_file_count: " .. tostring(desc.failed_file_count or 0),
    "close_send_file_count: " .. tostring(desc.close_send_file_count or 0),
    "current_queue_bytes: " .. tostring(desc.current_queue_bytes or 0),
    "sendable_queue_bytes: " .. tostring(desc.sendable_queue_bytes or 0),
    "queued_events_session: " .. tostring(desc.queued_events_session or 0),
    "flushed_events_session: " .. tostring(desc.flushed_events_session or 0),
    "failed_batches_session: " .. tostring(desc.failed_batches_session or 0),
    "dropped_events_session: " .. tostring(desc.dropped_events_session or 0),
    "skipped_events_session: " .. tostring(desc.skipped_events_session or 0),
    "last_flush_at: " .. tostring(desc.last_flush_at or ""),
    "last_http_code: " .. tostring(desc.last_http_code or ""),
    "last_curl_exitcode: " .. tostring(desc.last_curl_exitcode or ""),
    "last_backend_error: " .. tostring(desc.last_backend_error or ""),
    "last_error: " .. tostring(desc.last_error or "")
  }
  ImGui.InputTextMultiline(
    ctx,
    "##manager_telemetry_details",
    table.concat(details, "\n"),
    -1,
    180,
    ImGui.InputTextFlags_ReadOnly
  )
end

local MAIN_WINDOW_MIN_EXPANDED_HEIGHT = 64
local main_window_runtime = {
  force_expand_on_start = true,
  was_visible = nil,
  expanded_w = nil,
  expanded_h = nil
}

local function prepare_main_window_before_begin()
  if main_window_runtime.force_expand_on_start then
    ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
    main_window_runtime.force_expand_on_start = false
  end
  if main_window_runtime.was_visible == false and
      tonumber(main_window_runtime.expanded_w) and
      tonumber(main_window_runtime.expanded_h) then
    ImGui.SetNextWindowSize(
      ctx,
      main_window_runtime.expanded_w,
      main_window_runtime.expanded_h,
      ImGui.Cond_Always
    )
  end
end

local function observe_main_window_after_begin(visible)
  if visible then
    local window_w, window_h = ImGui.GetWindowSize(ctx)
    if tonumber(window_h) and window_h >= MAIN_WINDOW_MIN_EXPANDED_HEIGHT then
      main_window_runtime.expanded_w = window_w
      main_window_runtime.expanded_h = window_h
    end
  end
  main_window_runtime.was_visible = visible == true
end

local function draw_status_window()
  ImGui.SetNextWindowSize(ctx_status, 700, 440, ImGui.Cond_FirstUseEver)
  if not S.show_status_window then return end
  local visible = ImGui.Begin(
    ctx_status,
    APP_NAME .. " Status " .. SCRIPT_VERSION .. "##manager_status_window",
    nil,
    ImGui.WindowFlags_NoTitleBar
  )
  if visible then
    draw_status_panel(ctx_status)
    draw_request_table(ctx_status, "_status")
    ImGui.End(ctx_status)
  end
end

local function gui_frame()
  local now_t = Jobs.now()
  TelemetryBridge.safe_tick(now_t)
  Jobs.tick_all(now_t)
  sync_tokens_from_client()
  try_startup_auth()
  draw_status_window()

  ImGui.SetNextWindowSize(ctx, 1080, 900, ImGui.Cond_FirstUseEver)
  prepare_main_window_before_begin()
  local visible, open = ImGui.Begin(
    ctx,
    APP_NAME .. " " .. SCRIPT_VERSION .. "##elevenlabs_manager_main_window",
    true
  )
  observe_main_window_after_begin(visible)
  if visible then
    ImGui.PushFont(ctx, FONT, 16)
    local changed_status, show_status = ImGui.Checkbox(ctx, "Show status in dedicated window", S.show_status_window)
    if changed_status then
      S.show_status_window = show_status
      Util.extstate_set(EXT.UI_SECTION, EXT.UI_SHOW_STATUS, show_status and "1" or "0", true)
    end
    draw_status_panel(ctx)
    draw_settings()
    draw_users_table()
    draw_request_table(ctx, "_main")
    draw_telemetry_section()
    ImGui.PopFont(ctx)
    ImGui.End(ctx)
  end
  return open
end

local stopped_after_error = false
local function defer_loop()
  if stopped_after_error then return end
  local ok, open_or_error = xpcall(gui_frame, debug.traceback)
  if not ok then
    stopped_after_error = true
    local traceback = tostring(open_or_error)
    Util.msg("ElevenLabs Manager UI failed: " .. traceback, 3)
    TelemetryBridge.safe_event("error", {
      operation = "elevenlabs_manager_ui_loop",
      status = "failed",
      error_code = "UI_LOOP_ERROR",
      safe_message = traceback:sub(1, 1500)
    }, { operation = "elevenlabs_manager_ui_loop", status = "failed", priority = "error" })
    r.MB("ElevenLabs Manager stopped after an unexpected error:\n\n" .. traceback, APP_NAME, 0)
    return
  end
  if open_or_error then
    r.defer(defer_loop)
  else
    TelemetryBridge.send_closed_event("window_closed")
  end
end

load_persisted_ui()
TelemetryBridge.safe_event("script_started", {
  operation = "elevenlabs_manager_lifecycle",
  status = "started",
  backend_target = active_backend()
}, { operation = "elevenlabs_manager_lifecycle", status = "started" })
TelemetryBridge.safe_flush("startup")
r.defer(defer_loop)
