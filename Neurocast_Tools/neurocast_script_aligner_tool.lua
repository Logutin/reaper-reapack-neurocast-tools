--========================================================
-- Neurocast script aligner async prototype
--========================================================

local active_locale = "eng"
local translated_runtime_locale = "eng"
local translations_by_source_text = {}
local locale_runtime_aliases = {
  en = "eng",
  eng = "eng",
  ru = "rus",
  rus = "rus"
}

local function parse_runtime_locale(locale)
  if type(locale) ~= "string" then return nil end
  local lowered = tostring(locale):lower()
  local aliased = locale_runtime_aliases[lowered] or lowered
  if aliased == "eng" or aliased == "rus" then
    return aliased
  end
  return nil
end

local function normalize_runtime_locale(locale)
  return parse_runtime_locale(locale) or "eng"
end

local function translated_locale_available(locale)
  return translated_runtime_locale ~= "eng" and translated_runtime_locale == normalize_runtime_locale(locale)
end

local function set_active_runtime_locale(locale)
  local normalized = normalize_runtime_locale(locale)
  if normalized ~= "eng" and (not translated_locale_available(normalized)) then
    normalized = "eng"
  end
  active_locale = normalized
  return active_locale
end

local function t(text)
  if text == nil then return "" end
  if type(text) ~= "string" then return tostring(text) end
  if active_locale == "eng" then
    return text
  end
  return translations_by_source_text[text] or text
end

local function locale_display_name(locale)
  if normalize_runtime_locale(locale) == "rus" then
    return "Русский"
  end
  return "English"
end

local r = assert(reaper, t("Reaper API not found. This script must be run within Reaper."))
local SCRIPT_VERSION = "v0.1.0"
local TOOLSET_VERSION = SCRIPT_VERSION

local function current_main_window_title_text()
  return t("Neurocast Script Aligner") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION
end

local function current_status_window_title_text()
  return t("Status") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION
end

if not r.ImGui_CreateContext then
  r.MB(
    t("Missing dependency: ReaImGui extension.\nDownload it via Reapack ReaTeam extension repository."),
    t("Error"),
    0
  )
  return false
end

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
if not script_path then
  r.MB(t("Failed to get script path!"), t("Error"), 0)
  return
end

local old_package_path = package.path
package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. old_package_path

do
  local ok_languages, languages_or_err = pcall(require, "modules-neurocast.neurocast_script_aligner_tool_languages")
  if ok_languages and type(languages_or_err) == "table" then
    local module_locale = normalize_runtime_locale(languages_or_err.locale)
    local module_translations = languages_or_err.translations_by_source_text
    if module_locale ~= "eng" and type(module_translations) == "table" then
      translated_runtime_locale = module_locale
      translations_by_source_text = module_translations
    end
  end
end

local function require_module(module_name)
  local ok, value = pcall(require, module_name)
  if not ok then
    package.path = old_package_path
    r.MB(string.format(t("Failed to load %s: %s"), module_name, tostring(value)), t("Error"), 0)
    error("module load failed: " .. module_name)
  end
  return value
end

local Util = require_module("modules-neurocast.Util")
local Files = require_module("modules-neurocast.Files")
local Curl = require_module("modules-neurocast.Curl")
local Jobs = require_module("modules-neurocast.Jobs")
local NeurocastAuth = require_module("modules-neurocast.neurocast_auth")
local NeurocastScriptAlignerHelper = require_module("modules-neurocast.neurocast_script_aligner_helper")
local NeurocastScriptAlignerSettings = require_module("modules-neurocast.neurocast_script_aligner_settings")
local NeurocastScriptAlignerResult = require_module("modules-neurocast.neurocast_script_aligner_result")
local NeurocastScriptAlignerReaper = require_module("modules-neurocast.neurocast_script_aligner_reaper")
local Telemetry = require_module("modules-neurocast.Telemetry")

if not Telemetry.require_identity_or_abort({
  app_name = "CirilicaTools",
  entrypoint = "neurocast_script_aligner_tool",
  script_version = SCRIPT_VERSION
}) then
  package.path = old_package_path
  return
end

local ok_telemetry_init, telemetry_init_err = Telemetry.init({
  app_name = "CirilicaTools",
  entrypoint = "neurocast_script_aligner_tool",
  script_version = SCRIPT_VERSION,
  enable_file_log = false
})
if not ok_telemetry_init then
  package.path = old_package_path
  r.MB(string.format(t("Telemetry initialization failed:\n%s"), tostring(telemetry_init_err)), t("Telemetry Error"), 0)
  return
end

package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ok_imgui, imgui_or_err = pcall(function()
  return require("imgui")("0.10")
end)
package.path = old_package_path
if not ok_imgui then
  r.MB(string.format(t("Failed to load ReaImGui Lua module: %s"), tostring(imgui_or_err)), t("Error"), 0)
  return
end
local ImGui = imgui_or_err

local TelemetryBridge = nil

r.atexit(function()
  if type(TelemetryBridge) == "table" and type(TelemetryBridge.send_closed_event) == "function" then
    TelemetryBridge.send_closed_event("atexit")
  end
  package.path = old_package_path
end)

local function resolve_curl_path()
  if Util.mac then
    return "/usr/bin/curl"
  end
  local pinned_path = Util.path_join(script_path, [=[bin\win]=]) .. [=[\curl.exe]=]
  local result = r.ExecProcess(pinned_path .. " --version", 1500)
  local target = [=[curl 8.13.0 (Windows)]=]
  if result and result:find(target, 1, true) then
    return pinned_path
  end
  local detail = result and ("Unexpected curl --version output:\n" .. tostring(result)) or "Could not run bundled curl --version."
  r.MB(
    string.format(
      t("Bundled curl was not found or did not match the expected version at:\n%s\n\nThe script will try Windows system curl from PATH instead.\n\nExpected: %s\n%s"),
      tostring(pinned_path),
      target,
      detail
    ),
    t("Warning"),
    0
  )
  return "curl"
end

-- Approved backend-target exception: this tool remains on the established
-- Studio portal host rather than the dedicated reaper.neurocast.tech backend.
-- Changing this target requires an explicit, versioned contract change.
local BASE_URL = "https://studio.neurocast.tech"
local CFG = {
  base_url = BASE_URL,
  curl = resolve_curl_path(),
  timeout_sec = 57,
  max_concurrent_jobs = 2,
  max_concurrent_IVC_jobs = 1,
  curl_connect_timeout_sec = 20,
  curl_speed_limit = 1,
  curl_speed_time = 60,
  button_cooldown_sec = 1.5,
  retry_base_backoff_sec = 1.0,
  max_wait_time_for_retry = 25.0,
  retry_jitter_ratio = 0.0,
  auth_max_attempts = 3,
  aligner_max_attempts = 3,
  aligner_poll_min_sec = 3.0,
  aligner_poll_max_sec = 15.0,
  result_prefix = "script_aligner_",
  temp_subfolder_name = "neurocast_script_aligner_tool_TEMP",
  fallback_chars_per_second = 20,
  fallback_min_item_length_sec = 1.0
}

do
  local resource_path = r.GetResourcePath()
  CFG.tmp_dir = Util.path_join(resource_path, "Data")
  CFG.tmp_dir = Util.path_join(CFG.tmp_dir, "NeurocastTool")
  CFG.tmp_dir = Util.path_join(CFG.tmp_dir, "tmp")

  Util.messaging_level = 3
  Util.msg_to_log_file = false
  Util.log_level_override = nil
  Util.full_path_to_log_file = nil
end
Util.configure_diagnostics("neurocast_script_aligner_tool")

local S

local function refresh_project_relative_paths()
  S.project_path = Files.read_project_path() or ""
  if S.project_path ~= "" then
    CFG.tmp_dir = Util.path_join(S.project_path, CFG.temp_subfolder_name or "neurocast_script_aligner_tool_TEMP")
  else
    local fallback = Util.path_join(r.GetResourcePath(), "Data")
    fallback = Util.path_join(fallback, "NeurocastTool")
    CFG.tmp_dir = Util.path_join(fallback, "tmp")
  end
  return CFG.tmp_dir
end

local EXT = {
  AUTH_SECTION = "ncsa_tool_auth_7f3",
  AUTH_REFRESH = "refresh_42d",
  AUTH_EMAIL = "email_91b",
  UI_SECTION = "neurocast_aligner_tool_ui",
  UI_SHOW_STATUS = "show_status_window",
  UI_LOCALE = "ui_locale",
  UI_ALIGNER_MATCH_CONFIDENCE_THRESHOLD = "aligner_match_confidence_threshold",
  UI_ALIGNER_TIME_WINDOW_SECONDS = "aligner_time_window_seconds",
  UI_IMPORT_OFFSET_ENABLED = "import_offset_enabled",
  UI_IMPORT_OFFSET_DIRECTION = "import_offset_direction",
  UI_IMPORT_OFFSET_HOURS = "import_offset_hours",
  UI_IMPORT_OFFSET_MINUTES = "import_offset_minutes"
}

local ctx = ImGui.CreateContext(current_main_window_title_text())
local ctx_status = ImGui.CreateContext(current_status_window_title_text())
local font_size = 16
local FONT = ImGui.CreateFont("monospace")
ImGui.Attach(ctx, FONT)

S = {
  email = "",
  password = "",
  remember_me = true,
  access_token = "",
  refresh_token = "",
  has_stored_refresh = false,
  current_user = nil,
  current_user_claims = nil,
  status_text = "",
  last_http = "",
  last_api_error = "",
  warnings = {},
  checks_ran = false,
  tmp_writable = false,
  project_path = "",
  last_prompt_for_file_dir = "",
  show_status_window = false,
  pending_job = nil,
  wait_until = nil,
  running_label = nil,
  ui_lock_network_buttons = false,
  retry_queue = {},
  retry_generation = 0,
  cleanup_queue = {},
  cleanup_failures = {},
  curl_jobs = {},
  req_count = 0,
  auth_records = {},
  aligner_records = {},
  aligner_script_path = "",
  aligner_match_confidence_threshold = NeurocastScriptAlignerSettings.DEFAULTS.matchConfidenceThreshold,
  aligner_time_window_seconds = NeurocastScriptAlignerSettings.DEFAULTS.timeWindowSeconds,
  aligner_import_offset_enabled = false,
  aligner_import_offset_direction = "right",
  aligner_import_offset_hours = 0,
  aligner_import_offset_minutes = 0,
  aligner_import_offset_hours_input = "00",
  aligner_import_offset_minutes_input = "00",
  aligner_import_offset_seconds = 0,
  aligner_active_run = nil,
  aligner_last_success_job = nil,
  aligner_last_success_job_id = "",
  aligner_last_download_path = "",
  aligner_last_download_context = nil,
  aligner_parsed_result = nil,
  aligner_last_parse_error = "",
  aligner_last_import_message = "",
  aligner_last_import_report = nil,
  telemetry_ui_status = "",
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

local AUTH_CLIENT = nil
local SCRIPT_ALIGNER_CLIENT = nil

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

TelemetryBridge = {
  closed_event_sent = false
}

function TelemetryBridge.now()
  return type(r.time_precise) == "function" and r.time_precise() or os.clock()
end

function TelemetryBridge.duration_ms(started_at)
  local started = tonumber(started_at)
  if not started then return nil end
  local elapsed = TelemetryBridge.now() - started
  if elapsed < 0 then elapsed = 0 end
  return math.floor((elapsed * 1000) + 0.5)
end

local function telemetry_pattern_escape(value)
  return tostring(value or ""):gsub("([^%w])", "%%%1")
end

local function telemetry_should_redact_key(key)
  local lowered = tostring(key or ""):lower()
  return lowered:find("token", 1, true) ~= nil
    or lowered:find("authorization", 1, true) ~= nil
    or lowered:find("password", 1, true) ~= nil
    or lowered:find("credential", 1, true) ~= nil
    or lowered:find("secret", 1, true) ~= nil
    or lowered:find("signature", 1, true) ~= nil
    or lowered:find("presigned", 1, true) ~= nil
    or lowered:find("upload_url", 1, true) ~= nil
    or lowered:find("download_url", 1, true) ~= nil
    or lowered == "url"
    or lowered == "key"
    or lowered == "policy"
end

function TelemetryBridge.redact_secret_values(value)
  local text = tostring(value or "")
  for _, secret in ipairs({ S.password, S.access_token, S.refresh_token }) do
    local secret_text = tostring(secret or "")
    if #secret_text >= 8 then
      text = text:gsub(telemetry_pattern_escape(secret_text), "[REDACTED_SECRET]")
    end
  end
  text = text:gsub("[Aa]uthorization:%s*Bearer%s+[%w%p]+", "Authorization: Bearer [REDACTED_SECRET]")
  text = text:gsub("[Bb]earer%s+[%w%._%-]+", "Bearer [REDACTED_SECRET]")
  text = text:gsub("https?://[%w%-%._~:/%?#%[%]@!$&'%(%)%*%+,;=%%]+", "[REDACTED_URL]")
  text = text:gsub("([Aa]ccess[_%-]?[Tt]oken[%s:=]+)[%w%p]+", "%1[REDACTED_SECRET]")
  text = text:gsub("([Rr]efresh[_%-]?[Tt]oken[%s:=]+)[%w%p]+", "%1[REDACTED_SECRET]")
  text = text:gsub("([Pp]assword[%s:=]+)[%w%p]+", "%1[REDACTED_SECRET]")
  return text
end

function TelemetryBridge.safe_string(value, limit)
  local text = TelemetryBridge.redact_secret_values(value)
  if type(Util.clip_text) == "function" then
    return Util.clip_text(text, tonumber(limit) or 2048)
  end
  local max_len = tonumber(limit) or 2048
  if #text <= max_len then return text end
  return text:sub(1, max_len)
end

function TelemetryBridge.content_allowed()
  local ok_level, level = pcall(Telemetry.effective_level)
  if not ok_level then return false end
  return tostring(level or "") == "support" or tostring(level or "") == "debug"
end

function TelemetryBridge.sanitize_value(value, depth, key_hint)
  if telemetry_should_redact_key(key_hint) then
    return "[REDACTED]"
  end
  local value_type = type(value)
  if value_type == "nil" then return nil end
  if value_type == "string" then return TelemetryBridge.safe_string(value) end
  if value_type == "number" or value_type == "boolean" then return value end
  if value_type ~= "table" then return TelemetryBridge.safe_string(value) end
  local d = tonumber(depth) or 0
  if d > 6 then return "[truncated]" end
  local out = {}
  local count = 0
  for k, v in pairs(value) do
    count = count + 1
    if count > 80 then
      out._truncated = true
      break
    end
    local key = TelemetryBridge.safe_string(k, 160)
    out[key] = TelemetryBridge.sanitize_value(v, d + 1, key)
  end
  return out
end

function TelemetryBridge.active_run_summary(run)
  local r0 = type(run) == "table" and run or S.aligner_active_run
  if type(r0) ~= "table" then return nil end
  local render_info = type(r0.render_info) == "table" and r0.render_info or {}
  return {
    run_id = tostring(r0.id or ""),
    run_title = tostring(r0.title or ""),
    audio_input_mode = tostring(r0.audio_input_mode or ""),
    source_docx_path = tostring(r0.script_path or ""),
    rendered_audio_path = tostring(r0.audio_path or render_info.input_path or ""),
    rendered_audio_size = (r0.audio_path and Files.file_size(r0.audio_path)) or (render_info.input_path and Files.file_size(render_info.input_path)) or nil,
    base_import_offset_sec = r0.base_import_offset_sec,
    job_id = tostring(r0.job_id or ""),
    polling_enabled = r0.polling_enabled == true,
    poll_inflight = r0.poll_inflight == true,
    poll_stopped_locally = r0.poll_stop_local == true,
    options = r0.script_aligner_options
  }
end

function TelemetryBridge.base_payload(data)
  local out = {
    app_area = "neurocast_script_aligner",
    script_version = SCRIPT_VERSION,
    project_path = tostring(S.project_path or ""),
    temp_dir = tostring(CFG.tmp_dir or ""),
    curl_path = tostring(CFG.curl or ""),
    login_present = trim(S.email or "") ~= "",
    has_access_token = trim(S.access_token or "") ~= "",
    has_stored_refresh = S.has_stored_refresh == true,
    show_status_window = S.show_status_window == true,
    auth_record_count = #(S.auth_records or {}),
    aligner_record_count = #(S.aligner_records or {}),
    active_run = TelemetryBridge.active_run_summary()
  }
  if TelemetryBridge.content_allowed() and trim(S.email or "") ~= "" then
    out.login_email = tostring(S.email or "")
  end
  if type(data) == "table" then
    for k, v in pairs(data) do
      out[k] = v
    end
  end
  return TelemetryBridge.sanitize_value(out)
end

function TelemetryBridge.safe_event(event_name, data, opts)
  local ok_event, event_or_err = Telemetry.safe_event(event_name, TelemetryBridge.base_payload(data), opts or {})
  if ok_event then
    return true, event_or_err
  end
  S.telemetry_ui_status = string.format(t("Telemetry event failed: %s"), tostring(event_or_err))
  Util.msg(S.telemetry_ui_status, 2)
  return false, event_or_err
end

function TelemetryBridge.emit_operation_event(event_name, operation, status, data, opts)
  local payload = TelemetryBridge.base_payload(data)
  payload.operation = tostring(operation or "")
  payload.status = tostring(status or "")
  local event_opts = {}
  if type(opts) == "table" then
    for k, v in pairs(opts) do
      event_opts[k] = v
    end
  end
  event_opts.operation = payload.operation
  event_opts.status = payload.status
  event_opts.request_label = payload.request_label
  event_opts.http_code = payload.http_code
  event_opts.curl_exitcode = payload.curl_exitcode
  event_opts.duration_ms = payload.duration_ms
  event_opts.error_code = payload.error_code
  return TelemetryBridge.safe_event(event_name, payload, event_opts)
end

function TelemetryBridge.operation_started(operation, data)
  return TelemetryBridge.emit_operation_event("operation_started", operation, "started", data, {
    priority = "normal"
  })
end

function TelemetryBridge.operation_completed(operation, data, started_at)
  local payload = data or {}
  if started_at and payload.duration_ms == nil then
    payload.duration_ms = TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event("operation_completed", operation, "completed", payload, {
    priority = "normal"
  })
end

function TelemetryBridge.operation_failed(operation, data, started_at, event_name)
  local payload = data or {}
  if started_at and payload.duration_ms == nil then
    payload.duration_ms = TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event(event_name or "operation_failed", operation, "failed", payload, {
    priority = "error",
    event_level = "error"
  })
end

function TelemetryBridge.operation_canceled(operation, data, started_at)
  local payload = data or {}
  if started_at and payload.duration_ms == nil then
    payload.duration_ms = TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event("operation_canceled", operation, "canceled", payload, {
    priority = "low"
  })
end

function TelemetryBridge.operation_from_record(rec)
  local endpoint = tostring(rec and rec.endpoint or "")
  if tostring(rec and rec.kind or "") == "auth" then
    if endpoint == "login" then return "neurocast_auth_login" end
    if endpoint == "refresh" then return "neurocast_auth_refresh" end
    if endpoint == "get_current_user" then return "neurocast_auth_get_current_user" end
    if endpoint == "logout" then return "neurocast_auth_logout" end
    return "neurocast_auth_request"
  end
  if endpoint ~= "" then return "neurocast_" .. endpoint end
  return "neurocast_script_aligner_request"
end

function TelemetryBridge.record_payload(rec, extra)
  local payload = {}
  if type(rec) == "table" then
    payload.record_id = tostring(rec.id or "")
    payload.record_kind = tostring(rec.kind or "")
    payload.endpoint = tostring(rec.endpoint or "")
    payload.request_label = tostring(rec.flow_label or rec.endpoint or "")
    payload.flow_label = tostring(rec.flow_label or "")
    payload.record_state = tostring(rec._state or "")
    payload.attempt = tonumber(rec._attempt) or 0
    payload.max_attempts = tonumber(rec._max_attempts) or 0
    payload.http_code = rec._last_http_code or rec.result_http
    payload.result_ok = rec.result_ok == true
    payload.progress = tostring(rec._custom_progress or "")
    payload.safe_message = TelemetryBridge.safe_string(rec._last_error_summary or "")
    payload.network_job_id = tostring(rec.job_id or "")
  end
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  return payload
end

function TelemetryBridge.begin_record(rec, extra)
  if type(rec) ~= "table" or rec._telemetry_started_at ~= nil then return end
  rec._telemetry_started_at = TelemetryBridge.now()
  rec._telemetry_operation = TelemetryBridge.operation_from_record(rec)
  rec._telemetry_completed = false
  TelemetryBridge.operation_started(rec._telemetry_operation, TelemetryBridge.record_payload(rec, extra))
end

function TelemetryBridge.finish_record_ok(rec, extra)
  if type(rec) ~= "table" or rec._telemetry_completed == true then return end
  rec._telemetry_completed = true
  local payload = TelemetryBridge.record_payload(rec, extra)
  payload.duration_ms = payload.duration_ms or TelemetryBridge.duration_ms(rec._telemetry_started_at)
  TelemetryBridge.operation_completed(rec._telemetry_operation or TelemetryBridge.operation_from_record(rec), payload)
end

function TelemetryBridge.finish_record_failed(rec, extra, event_name)
  if type(rec) ~= "table" or rec._telemetry_completed == true then return end
  rec._telemetry_completed = true
  local payload = TelemetryBridge.record_payload(rec, extra)
  payload.error_code = tostring((rec.endpoint or "neurocast_request") .. "_failed"):upper()
  payload.duration_ms = payload.duration_ms or TelemetryBridge.duration_ms(rec._telemetry_started_at)
  TelemetryBridge.operation_failed(
    rec._telemetry_operation or TelemetryBridge.operation_from_record(rec),
    payload,
    nil,
    event_name or "operation_failed"
  )
end

function TelemetryBridge.request_endpoint_fields(req, track_label)
  if type(req) ~= "table" then return {} end
  local url = tostring(req.url or "")
  local host = url:match("^https?://([^/]+)") or ""
  local endpoint_path = url:match("^https?://[^/]+(/.*)$") or ""
  endpoint_path = endpoint_path:gsub("%?.*$", "")
  local is_neurocast_api = host == "studio.neurocast.tech" or host == "neurocast.tech"
  return {
    request_label = tostring(track_label or req.label or ""),
    request_method = tostring(req.method or req.request or ""),
    request_kind = tostring(req.kind or ""),
    endpoint_kind = is_neurocast_api and "neurocast_api" or "presigned_transfer",
    endpoint_path = is_neurocast_api and endpoint_path or "",
    has_body_string = req.body_string ~= nil,
    body_file_path = tostring(req.body_file_path or ""),
    body_file_size = req.body_file_path and Files.file_size(req.body_file_path) or nil,
    download_path = tostring(req.download_path or ""),
    follow_redirects = req.follow_redirects == true
  }
end

function TelemetryBridge.network_request_failed(req, result, job, track_label)
  local payload = TelemetryBridge.request_endpoint_fields(req, track_label)
  payload.operation = "neurocast_network_request"
  payload.status = "failed"
  payload.http_code = result and result.http_code or nil
  payload.curl_exitcode = result and (result.exitcode or result.curl_exitcode) or nil
  payload.safe_message = TelemetryBridge.safe_string((result and (result.err or result.error or result.err_msg or result.err_txt)) or "curl request failed")
  payload.network_job_id = tostring(job and job.id or "")
  TelemetryBridge.emit_operation_event("network_request_failed", "neurocast_network_request", "failed", payload, {
    priority = "error",
    event_level = "error",
    request_label = payload.request_label,
    http_code = payload.http_code,
    curl_exitcode = payload.curl_exitcode
  })
end

function TelemetryBridge.result_summary(parsed)
  if type(parsed) ~= "table" then return nil end
  local summary = {
    line_count = tonumber(parsed.line_count or 0) or 0,
    aligned_count = tonumber(parsed.aligned_count or 0) or 0,
    fallback_count = tonumber(parsed.fallback_count or 0) or 0,
    corrected_timing_issue_count = tonumber(parsed.corrected_timing_issue_count or 0) or 0,
    no_used_segments_count = tonumber(parsed.no_used_segments_count or 0) or 0,
    warning_count = tonumber(parsed.warning_count or 0) or 0,
    status_counts = parsed.status_counts,
    source_path = tostring(parsed.source_path or "")
  }
  local warnings = {}
  for i, warning in ipairs(parsed.warnings or {}) do
    if i > 5 then
      warnings[#warnings + 1] = string.format("...%d more", #parsed.warnings - 5)
      break
    end
    warnings[#warnings + 1] = TelemetryBridge.safe_string(warning, 240)
  end
  summary.warnings = warnings
  if TelemetryBridge.content_allowed() then
    local rows = {}
    for i, line in ipairs(parsed.lines or {}) do
      if i > 3 then break end
      rows[#rows + 1] = {
        source_index = line.source_index,
        character_name = TelemetryBridge.safe_string(line.character_name, 120),
        original_text = TelemetryBridge.safe_string(line.original_text, 240),
        matched_text = TelemetryBridge.safe_string(line.matched_text or "", 240),
        status = TelemetryBridge.safe_string(line.status or "", 80),
        has_corrected_timing = line.has_corrected_timing == true,
        original_start_time_sec = line.original_start_time_sec,
        corrected_start_time_sec = line.corrected_start_time_sec,
        corrected_end_time_sec = line.corrected_end_time_sec,
        confidence = line.confidence,
        match_confidence = line.match_confidence
      }
    end
    summary.row_snippets = rows
  end
  return summary
end

function TelemetryBridge.poll_status_transition(run, status)
  if type(run) ~= "table" then return end
  local normalized = SCRIPT_ALIGNER_CLIENT.normalize_job_status(status)
  if run._telemetry_last_poll_status == normalized then return end
  run._telemetry_last_poll_status = normalized
  TelemetryBridge.emit_operation_event("operation_completed", "neurocast_poll_status_transition", "completed", {
    request_label = "get_job",
    job_id = tostring(run.job_id or ""),
    job_status = tostring(normalized or ""),
    active_run = TelemetryBridge.active_run_summary(run)
  }, {
    operation = "neurocast_poll_status_transition",
    status = "completed",
    priority = "low"
  })
end

local telemetry_button_allow = {
  login_btn = true,
  forget_login_btn = true,
  load_current_user_btn = true,
  aligner_select_script = true,
  aligner_start_flow = true,
  aligner_stop_polling = true,
  aligner_download_result_json = true,
  aligner_reparse_result = true,
  aligner_import_result = true,
  reset_state_btn = true,
  telemetry_flush_now_btn = true,
  telemetry_resume_btn = true,
  telemetry_copy_paths_btn = true
}

local function telemetry_button_allowed(button_id)
  local id = tostring(button_id or "")
  return telemetry_button_allow[id] == true or id:match("^retry_") ~= nil
end

function TelemetryBridge.button_clicked(button_id, label)
  if not telemetry_button_allowed(button_id) then return false end
  return TelemetryBridge.safe_event("button_clicked", {
    operation = "neurocast_ui",
    status = "clicked",
    button_id = tostring(button_id or ""),
    button_label = tostring(label or "")
  }, {
    operation = "neurocast_ui",
    status = "clicked",
    priority = "low"
  })
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
  if normalized == "basic" then return t("Basic") end
  if normalized == "support" then return t("Support") end
  if normalized == "debug" then return t("Debug") end
  return normalized
end

function TelemetryBridge.describe_status()
  local ok_desc, desc_or_err = pcall(Telemetry.describe_status)
  if ok_desc and type(desc_or_err) == "table" then
    return desc_or_err
  end
  return {
    initialized = false,
    status = t("telemetry status unavailable"),
    last_error = tostring(desc_or_err or ""),
    progress_line = "",
    active_job_phase = ""
  }
end

function TelemetryBridge.header_state(desc)
  if not desc or desc.initialized ~= true then return t("unavailable") end
  if desc.send_paused then return t("paused, see details") end
  if desc.active_job_id ~= nil then
    local progress = TelemetryBridge.progress_text(desc)
    if progress ~= "-" then
      return string.format(t("flushing, %s"), TelemetryBridge.safe_string(progress, 32))
    end
    return t("flushing")
  end
  if trim(desc.last_error or "") ~= "" or trim(desc.last_backend_error or "") ~= "" then
    return t("fail, see details inside")
  end
  local pending_bytes = (tonumber(desc.sendable_queue_bytes) or 0) + (tonumber(desc.current_queue_bytes) or 0)
  local pending_files = (tonumber(desc.queued_file_count) or 0) + (tonumber(desc.sending_file_count) or 0)
  if pending_bytes > 0 or pending_files > 0 then return t("queued") end
  return t("idle")
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

function TelemetryBridge.safe_tick(now_t)
  local ok_tick, tick_or_err = Telemetry.safe_tick(now_t)
  if ok_tick == false and tick_or_err ~= nil then
    S.telemetry_ui_status = string.format(t("Telemetry tick failed: %s"), tostring(tick_or_err))
  end
  return ok_tick, tick_or_err
end

function TelemetryBridge.safe_flush_async(reason)
  local ok_flush, flush_or_err = Telemetry.safe_flush_async({
    reason = reason or "neurocast_manual",
    timeout_sec = 60,
    connect_timeout_sec = 15,
    speed_limit = 1,
    speed_time = 30
  })
  if ok_flush then
    S.telemetry_ui_status = t("Telemetry flush started.")
  else
    S.telemetry_ui_status = tostring(flush_or_err or "")
  end
  return ok_flush, flush_or_err
end

function TelemetryBridge.script_started()
  TelemetryBridge.safe_event("script_started", {
    operation = "script_lifecycle",
    status = "started"
  }, {
    operation = "script_lifecycle",
    status = "started"
  })
end

function TelemetryBridge.send_closed_event(reason)
  if TelemetryBridge.closed_event_sent == true then return end
  TelemetryBridge.closed_event_sent = true
  TelemetryBridge.safe_event("script_closed", {
    operation = "script_lifecycle",
    status = "closed",
    close_reason = tostring(reason or "")
  }, {
    operation = "script_lifecycle",
    status = "closed"
  })

  local ok_call, ok_close, close_or_err = pcall(Telemetry.flush_current_queue_fire_and_forget, {
    curl_path = CFG.curl,
    timeout_sec = 20,
    connect_timeout_sec = 10,
    speed_limit = 1,
    speed_time = 15
  })
  if ok_call and ok_close then
    S.telemetry_ui_status = t("Telemetry close-send launched.")
  else
    local err = ok_call and close_or_err or ok_close
    S.telemetry_ui_status = string.format(t("Telemetry close-send failed: %s"), tostring(err))
    Util.msg(S.telemetry_ui_status, 2)
  end
end

local function make_tracked_curl_submit(track_label)
  return function(req, on_done, submit_opts)
    local job, err = Curl.curl_submit(req, function(result, job_ref)
      Curl.update_last_curl_state(result, job_ref, track_label or req.label or "Request")
      if result and result.ok ~= true then
        TelemetryBridge.network_request_failed(req, result, job_ref, track_label)
      end
      if type(on_done) == "function" then
        on_done(result, job_ref)
      end
    end, submit_opts)
    if not job then
      TelemetryBridge.network_request_failed(req, { ok = false, err = err }, nil, track_label)
    end
    return job, err
  end
end

AUTH_CLIENT = NeurocastAuth.create_client({
  base_url = BASE_URL,
  curl_submit_fn = make_tracked_curl_submit("Portal Auth"),
  ext_section = EXT.AUTH_SECTION,
  ext_refresh_key = EXT.AUTH_REFRESH,
  remember_refresh = true
})

SCRIPT_ALIGNER_CLIENT = NeurocastScriptAlignerHelper.create_client({
  base_url = BASE_URL,
  curl_submit_fn = make_tracked_curl_submit("Script Aligner API")
})

Curl.init(S, CFG)
Jobs.init(S, CFG)

local function now_stamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function next_request_seq()
  S.req_count = (tonumber(S.req_count) or 0) + 1
  return S.req_count
end

local function push_warning(message)
  local text = trim(message)
  if text == "" then return end
  S.warnings[#S.warnings + 1] = text
end

local function update_last_curl_error_from_payload(payload, label)
  S.last_http = tostring(payload and payload.http_code or S.last_http or "")
  local previous = S.last_curl_return or {}
  S.last_curl_return = {
    ok = previous.ok,
    http = previous.http ~= "" and previous.http or tostring(payload and payload.http_code or ""),
    body = previous.body or "",
    headers_txt = previous.headers_txt or "",
    meta = previous.meta or "",
    err = tostring((payload and (payload.api_error or payload.error)) or previous.err or ""),
    cmd = tostring(previous.cmd ~= "" and previous.cmd or label or "")
  }
end

local function parse_nonnegative_number(text, fallback)
  local value = tonumber(text)
  if value == nil or value < 0 then
    return fallback, false
  end
  return value, true
end

local function format_seconds(seconds)
  local value = tonumber(seconds)
  if value == nil then
    return t("(n/a)")
  end
  if type(r.format_timestr_pos) == "function" then
    local formatted = trim(r.format_timestr_pos(value, "", 5) or "")
    if formatted ~= "" then
      return formatted
    end
  end
  return string.format("%.3fs", value)
end

local function sorted_status_keys(status_counts)
  local keys = {}
  for key in pairs(status_counts or {}) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  return keys
end

local function clear_result_state()
  S.aligner_last_download_path = ""
  S.aligner_last_download_context = nil
  S.aligner_parsed_result = nil
  S.aligner_last_parse_error = ""
  S.aligner_last_import_message = ""
  S.aligner_last_import_report = nil
end

local function persist_plain_string(key, value)
  local ok_set, err = Util.extstate_set(EXT.UI_SECTION, key, tostring(value or ""), true)
  if not ok_set then
    Util.msg("Failed to persist UI state: " .. tostring(err), 2)
  end
end

local function load_plain_string(key)
  local value, err = Util.extstate_get(EXT.UI_SECTION, key)
  if err then
    Util.msg("Failed to load UI state: " .. tostring(err), 2)
    return nil
  end
  return value
end

local function forget_locale()
  Util.extstate_delete(EXT.UI_SECTION, EXT.UI_LOCALE, true)
end

local function persist_locale(locale)
  local normalized = parse_runtime_locale(locale)
  if not normalized then
    forget_locale()
    return
  end
  persist_plain_string(EXT.UI_LOCALE, normalized)
end

local function load_locale_from_ext_state()
  local value = load_plain_string(EXT.UI_LOCALE)
  if value == nil then return nil end
  value = tostring(value or "")
  if value == "" then
    forget_locale()
    return nil
  end
  local normalized = parse_runtime_locale(value)
  if not normalized then
    forget_locale()
    return nil
  end
  if normalized ~= "eng" and not translated_locale_available(normalized) then
    return "eng"
  end
  return normalized
end

local function load_locale_on_startup()
  set_active_runtime_locale(load_locale_from_ext_state() or "eng")
end

local function persist_show_status_window(value)
  persist_plain_string(EXT.UI_SHOW_STATUS, value and "1" or "0")
end

local function load_show_status_window()
  local value = load_plain_string(EXT.UI_SHOW_STATUS)
  if value == "1" then return true end
  if value == "0" then return false end
  return nil
end

local function sync_script_aligner_settings_state()
  local resolved = NeurocastScriptAlignerSettings.resolve_ui_state({
    matchConfidenceThreshold = S.aligner_match_confidence_threshold,
    timeWindowSeconds = S.aligner_time_window_seconds
  })
  S.aligner_match_confidence_threshold = resolved.matchConfidenceThreshold
  S.aligner_time_window_seconds = resolved.timeWindowSeconds
  return resolved
end

local function persist_script_aligner_settings_state()
  local resolved = sync_script_aligner_settings_state()
  persist_plain_string(EXT.UI_ALIGNER_MATCH_CONFIDENCE_THRESHOLD, tostring(resolved.matchConfidenceThreshold))
  persist_plain_string(EXT.UI_ALIGNER_TIME_WINDOW_SECONDS, tostring(resolved.timeWindowSeconds))
  return resolved
end

local function set_script_aligner_match_confidence_threshold(value)
  S.aligner_match_confidence_threshold = value
  return persist_script_aligner_settings_state()
end

local function set_script_aligner_time_window_seconds(value)
  S.aligner_time_window_seconds = value
  return persist_script_aligner_settings_state()
end

local function load_script_aligner_settings_state()
  local stored_match_confidence_threshold = load_plain_string(EXT.UI_ALIGNER_MATCH_CONFIDENCE_THRESHOLD)
  if stored_match_confidence_threshold ~= nil and stored_match_confidence_threshold ~= "" then
    S.aligner_match_confidence_threshold = stored_match_confidence_threshold
  end

  local stored_time_window_seconds = load_plain_string(EXT.UI_ALIGNER_TIME_WINDOW_SECONDS)
  if stored_time_window_seconds ~= nil and stored_time_window_seconds ~= "" then
    S.aligner_time_window_seconds = stored_time_window_seconds
  end

  return sync_script_aligner_settings_state()
end

local function current_script_aligner_request_options()
  return NeurocastScriptAlignerSettings.build_request_options({
    matchConfidenceThreshold = S.aligner_match_confidence_threshold,
    timeWindowSeconds = S.aligner_time_window_seconds
  })
end

local ALIGNER_IMPORT_OFFSET_DEFAULTS = {
  enabled = false,
  direction = "right",
  hours = 0,
  minutes = 0
}

local function normalize_import_offset_direction(value)
  if tostring(value or "") == "left" then
    return "left"
  end
  return ALIGNER_IMPORT_OFFSET_DEFAULTS.direction
end

local function normalize_import_offset_hours(value)
  local number = tonumber(value)
  if not number then
    return ALIGNER_IMPORT_OFFSET_DEFAULTS.hours
  end
  return math.max(0, math.min(99, math.floor(number)))
end

local function normalize_import_offset_minutes(value)
  local number = tonumber(value)
  if not number then
    return ALIGNER_IMPORT_OFFSET_DEFAULTS.minutes
  end
  return math.max(0, math.min(59, math.floor(number)))
end

local function current_import_offset_timecode_text()
  return string.format(
    "%02d:%02d:00:00",
    normalize_import_offset_hours(S.aligner_import_offset_hours),
    normalize_import_offset_minutes(S.aligner_import_offset_minutes)
  )
end

local function refresh_import_offset_seconds()
  local magnitude_seconds = (normalize_import_offset_hours(S.aligner_import_offset_hours) * 3600) +
    (normalize_import_offset_minutes(S.aligner_import_offset_minutes) * 60)
  if S.aligner_import_offset_enabled ~= true then
    S.aligner_import_offset_seconds = 0
    return S.aligner_import_offset_seconds
  end
  if normalize_import_offset_direction(S.aligner_import_offset_direction) == "left" then
    S.aligner_import_offset_seconds = -magnitude_seconds
  else
    S.aligner_import_offset_seconds = magnitude_seconds
  end
  return S.aligner_import_offset_seconds
end

local function sync_import_offset_inputs()
  S.aligner_import_offset_direction = normalize_import_offset_direction(S.aligner_import_offset_direction)
  S.aligner_import_offset_hours = normalize_import_offset_hours(S.aligner_import_offset_hours)
  S.aligner_import_offset_minutes = normalize_import_offset_minutes(S.aligner_import_offset_minutes)
  S.aligner_import_offset_hours_input = string.format("%02d", S.aligner_import_offset_hours)
  S.aligner_import_offset_minutes_input = string.format("%02d", S.aligner_import_offset_minutes)
  refresh_import_offset_seconds()
end

local function persist_import_offset_state()
  persist_plain_string(EXT.UI_IMPORT_OFFSET_ENABLED, S.aligner_import_offset_enabled == true and "1" or "0")
  persist_plain_string(EXT.UI_IMPORT_OFFSET_DIRECTION, normalize_import_offset_direction(S.aligner_import_offset_direction))
  persist_plain_string(EXT.UI_IMPORT_OFFSET_HOURS, tostring(normalize_import_offset_hours(S.aligner_import_offset_hours)))
  persist_plain_string(EXT.UI_IMPORT_OFFSET_MINUTES, tostring(normalize_import_offset_minutes(S.aligner_import_offset_minutes)))
end

local function apply_import_offset_change()
  sync_import_offset_inputs()
  persist_import_offset_state()
end

local function set_import_offset_enabled(enabled)
  S.aligner_import_offset_enabled = enabled == true
  apply_import_offset_change()
end

local function set_import_offset_direction(direction)
  S.aligner_import_offset_direction = normalize_import_offset_direction(direction)
  apply_import_offset_change()
end

local function set_import_offset_hours_from_input(text)
  S.aligner_import_offset_hours_input = tostring(text or "")
  local parsed = tonumber(S.aligner_import_offset_hours_input)
  if parsed ~= nil then
    S.aligner_import_offset_hours = normalize_import_offset_hours(parsed)
    apply_import_offset_change()
  end
end

local function set_import_offset_minutes_from_input(text)
  S.aligner_import_offset_minutes_input = tostring(text or "")
  local parsed = tonumber(S.aligner_import_offset_minutes_input)
  if parsed ~= nil then
    S.aligner_import_offset_minutes = normalize_import_offset_minutes(parsed)
    apply_import_offset_change()
  end
end

local function load_import_offset_state()
  local stored_enabled = load_plain_string(EXT.UI_IMPORT_OFFSET_ENABLED)
  if stored_enabled == "1" or stored_enabled == "true" then
    S.aligner_import_offset_enabled = true
  elseif stored_enabled == "0" or stored_enabled == "false" then
    S.aligner_import_offset_enabled = false
  end

  local stored_direction = load_plain_string(EXT.UI_IMPORT_OFFSET_DIRECTION)
  if type(stored_direction) == "string" and stored_direction ~= "" then
    S.aligner_import_offset_direction = normalize_import_offset_direction(stored_direction)
  end

  local stored_hours = load_plain_string(EXT.UI_IMPORT_OFFSET_HOURS)
  if stored_hours ~= nil and stored_hours ~= "" then
    S.aligner_import_offset_hours = normalize_import_offset_hours(stored_hours)
  end

  local stored_minutes = load_plain_string(EXT.UI_IMPORT_OFFSET_MINUTES)
  if stored_minutes ~= nil and stored_minutes ~= "" then
    S.aligner_import_offset_minutes = normalize_import_offset_minutes(stored_minutes)
  end

  sync_import_offset_inputs()
end

local function import_offset_direction_label(direction)
  if normalize_import_offset_direction(direction) == "left" then
    return t("Left")
  end
  return t("Right")
end

local function import_offset_summary_text()
  local signed_seconds = refresh_import_offset_seconds()
  local offset_text = current_import_offset_timecode_text()
  if S.aligner_import_offset_enabled ~= true then
    return string.format(t("Additional import offset: off (%s)"), offset_text)
  end
  return string.format(
    t("Additional import offset: %s %s (%.3fs)"),
    import_offset_direction_label(S.aligner_import_offset_direction),
    offset_text,
    signed_seconds
  )
end

local function prompt_for_file(window_title, initial_dir, file_types)
  local dir = initial_dir or ""
  if dir ~= "" then
    local last_char = dir:sub(-1)
    if last_char ~= Util.separator and last_char ~= "/" and last_char ~= "\\" then
      dir = dir .. Util.separator
    end
  end
  local success, selected_path = r.GetUserFileNameForRead(dir, window_title, file_types or "")
  if not success then
    return false, t("File selection was cancelled by the user or an error occurred.")
  end
  if not selected_path or selected_path == "" then
    return false, t("File selection reported success, but no valid file path was returned.")
  end
  return true, selected_path
end

local function rebuild_warnings()
  S.warnings = {}
  refresh_project_relative_paths()
  if S.project_path == "" then
    push_warning(t("Project path not available (unsaved project?)."))
  end
  local ok_tmp, err_tmp = Files.ensure_tmp_dir(CFG.tmp_dir)
  S.tmp_writable = ok_tmp
  if not ok_tmp then
    push_warning(t("Temp directory is NOT writable."))
    push_warning(err_tmp or t("Unknown error ensuring temp directory."))
  end
  S.checks_ran = true
end

local button_last_click_at = {}
local function button_clicked(id, label, cooldown_override, ctx_override)
  local ui_ctx = ctx_override or ctx
  local key = id or label
  local cooldown = tonumber(cooldown_override) or tonumber(CFG.button_cooldown_sec or 0) or 0
  local now_t = Jobs.now()
  local last = button_last_click_at[key]
  local clicked = ImGui.Button(ui_ctx, label)
  if not clicked then return false end
  if last and (now_t - last) < cooldown then
    return false
  end
  button_last_click_at[key] = now_t
  TelemetryBridge.button_clicked(id, label)
  return true
end

local function ui_info(text, ctx_to_show)
  ImGui.TextWrapped(ctx_to_show or ctx, tostring(text or ""))
end

local function ui_warning(text, ctx_to_show)
  local ui_ctx = ctx_to_show or ctx
  ImGui.PushStyleColor(ui_ctx, ImGui.Col_Text, 0xFFB000FF)
  ImGui.TextWrapped(ui_ctx, tostring(text or ""))
  ImGui.PopStyleColor(ui_ctx)
end

local function sync_tokens_from_client()
  local tokens = AUTH_CLIENT.get_tokens() or {}
  S.access_token = tostring(tokens.access_token or "")
  S.refresh_token = tostring(tokens.refresh_token or "")
  if S.refresh_token == "" then
    local loaded = AUTH_CLIENT.load_refresh_token()
    if type(loaded) == "string" and loaded ~= "" then
      S.refresh_token = loaded
    end
  end
  S.has_stored_refresh = (S.refresh_token ~= "")
end

local function persist_email(email)
  local value = trim(email)
  if value == "" then return end
  Util.extstate_set_camo(EXT.AUTH_SECTION, EXT.AUTH_EMAIL, value, true)
end

local function load_email_from_ext_state()
  local value = Util.extstate_get_camo(EXT.AUTH_SECTION, EXT.AUTH_EMAIL)
  if value == nil then return nil end
  value = trim(value)
  if value == "" then
    Util.extstate_delete(EXT.AUTH_SECTION, EXT.AUTH_EMAIL, true)
    return nil
  end
  return value
end

local function forget_email()
  Util.extstate_delete(EXT.AUTH_SECTION, EXT.AUTH_EMAIL, true)
end

local function apply_remember_policy()
  if S.remember_me then
    if S.refresh_token ~= "" then
      AUTH_CLIENT.persist_refresh_token(S.refresh_token)
    end
    if S.email ~= "" then
      persist_email(S.email)
    end
  else
    AUTH_CLIENT.forget_refresh_token()
    forget_email()
  end
  sync_tokens_from_client()
end

local function mark_auth_cleared(message)
  AUTH_CLIENT.clear_runtime_tokens()
  AUTH_CLIENT.forget_refresh_token()
  forget_email()
  sync_tokens_from_client()
  S.current_user = nil
  S.current_user_claims = nil
  S.status_text = message or t("Stored login cleared.")
  TelemetryBridge.safe_event("feature_used", {
    operation = "neurocast_auth_clear",
    status = "completed",
    safe_message = S.status_text
  }, {
    operation = "neurocast_auth_clear",
    status = "completed"
  })
end

local function create_record(kind, endpoint, flow_label, max_attempts)
  local rec = {
    id = string.format("%s_%04d", kind, next_request_seq()),
    kind = kind,
    endpoint = tostring(endpoint or ""),
    flow_label = tostring(flow_label or endpoint or kind),
    created_at = r.time_precise(),
    created_at_str = now_stamp(),
    job_id = nil,
    _state = "queued",
    _attempt = 0,
    _max_attempts = tonumber(max_attempts) or 3,
    _retry_generation = S.retry_generation,
    _retry_submit = nil,
    _next_retry_at = nil,
    _refresh_used_once = false,
    _custom_progress = "",
    _last_http_code = nil,
    _last_error_summary = "",
    result_http = nil,
    result_ok = nil
  }
  local target = (kind == "auth") and S.auth_records or S.aligner_records
  target[#target + 1] = rec
  return rec
end

local function default_submit_opts(timeout_sec)
  return {
    read_body = true,
    body_max_bytes = 2 * 1024 * 1024,
    timeout_sec = timeout_sec or CFG.timeout_sec,
    keep_output = true
  }
end

local function download_submit_opts()
  return {
    read_body = false,
    timeout_sec = 120,
    keep_output = true
  }
end

local function upload_submit_opts()
  return {
    read_body = true,
    body_max_bytes = 2 * 1024 * 1024,
    timeout_sec = 180,
    keep_output = true
  }
end

local Auth = {}

local function submit_record(rec, submit_builder, on_success, on_failure, submit_opts, opts)
  opts = opts or {}
  local max_attempts = tonumber(rec._max_attempts) or 3

  local function run_attempt(attempt)
    rec._attempt = attempt
    rec._retry_generation = S.retry_generation
    rec._state = "running"
    rec._next_retry_at = nil
    rec._last_error_summary = ""
    TelemetryBridge.begin_record(rec, {
      request_label = tostring(rec.flow_label or rec.endpoint or "")
    })

    local callback = function(payload)
      update_last_curl_error_from_payload(payload, rec.flow_label)
      rec.result_http = payload and payload.http_code or nil
      rec._last_http_code = rec.result_http
      rec.result_ok = (payload and payload.ok) == true
      sync_tokens_from_client()

      if payload and payload.ok == true then
        rec._state = "ok"
        rec._last_error_summary = ""
        S.last_api_error = ""
        S.status_text = rec.flow_label .. " OK."
        TelemetryBridge.finish_record_ok(rec, {
          response = payload
        })
        if on_success then on_success(payload, rec) end
        return
      end

      if opts.allow_refresh_401 and tonumber(payload and payload.http_code or 0) == 401 and rec._refresh_used_once ~= true then
        rec._refresh_used_once = true
        Auth.request_refresh(t("Refresh before ") .. rec.flow_label, function(ok_refresh, refresh_payload)
          if ok_refresh and S.access_token ~= "" then
            run_attempt(attempt)
            return
          end
          local raw_err = (refresh_payload and (refresh_payload.api_error or refresh_payload.error)) or t("refresh failed")
          rec._state = "failed_final"
          rec._last_error_summary = tostring(raw_err)
          S.status_text = rec.flow_label .. t(" failed after refresh attempt: ") .. tostring(raw_err)
          S.last_api_error = tostring(raw_err)
          push_warning(S.status_text)
          TelemetryBridge.finish_record_failed(rec, {
            response = refresh_payload or payload,
            safe_message = raw_err
          })
          if on_failure then on_failure(payload, rec) end
        end)
        return
      end

      local raw_err = (payload and (payload.api_error or payload.error)) or t("request failed")
      rec._last_error_summary = tostring(raw_err)
      local retryable = Jobs.is_retryable_result(payload and { http_code = payload.http_code } or nil)
      if retryable and attempt < max_attempts then
        local next_attempt = attempt + 1
        rec._state = "retrying"
        S.status_text = rec.flow_label .. t(" failed (retrying): ") .. tostring(raw_err)
        local retry_label = Jobs.format_attempt_label(rec.flow_label, next_attempt, max_attempts)
        local ok_retry, retry_err = Jobs.enqueue_retry(retry_label, function()
          run_attempt(next_attempt)
        end, next_attempt, max_attempts, raw_err, rec)
        if ok_retry then
          return
        end
        rec._state = "failed_final"
        S.status_text = rec.flow_label .. t(" failed: ") .. tostring(retry_err or raw_err)
      else
        rec._state = "failed_final"
        S.status_text = rec.flow_label .. t(" failed: ") .. tostring(raw_err)
      end

      S.last_api_error = tostring(raw_err)
      push_warning(S.status_text)
      TelemetryBridge.finish_record_failed(rec, {
        response = payload,
        safe_message = raw_err
      })
      if on_failure then on_failure(payload, rec) end
    end

    local job, submit_err = submit_builder(callback, submit_opts or default_submit_opts())
    if not job then
      callback({
        ok = false,
        endpoint = rec.endpoint,
        http_code = nil,
        error = tostring(submit_err or "submit failed"),
        api_error = nil
      })
      return
    end
    rec.job_id = job.id
  end

  rec._retry_submit = function()
    rec._refresh_used_once = false
    rec._telemetry_started_at = nil
    rec._telemetry_completed = false
    rec._telemetry_operation = nil
    run_attempt(1)
  end
  run_attempt(1)
end

function Auth.request_login()
  if trim(S.email) == "" then
    S.status_text = t("Login failed: email is empty.")
    S.last_api_error = t("email is empty")
    push_warning(S.status_text)
    TelemetryBridge.operation_failed("neurocast_auth_login_preflight", {
      error_code = "LOGIN_EMAIL_EMPTY",
      safe_message = S.last_api_error
    })
    return false
  end
  if not trim(S.email):match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
    S.status_text = t("Login failed: email format looks invalid.")
    S.last_api_error = t("email format looks invalid")
    push_warning(S.status_text)
    TelemetryBridge.operation_failed("neurocast_auth_login_preflight", {
      error_code = "LOGIN_EMAIL_INVALID",
      safe_message = S.last_api_error
    })
    return false
  end
  if (S.password or "") == "" then
    S.status_text = t("Login failed: password is empty.")
    S.last_api_error = t("password is empty")
    push_warning(S.status_text)
    TelemetryBridge.operation_failed("neurocast_auth_login_preflight", {
      error_code = "LOGIN_PASSWORD_EMPTY",
      safe_message = S.last_api_error
    })
    return false
  end

  local rec = create_record("auth", "login", t("Login"), CFG.auth_max_attempts)
  submit_record(
    rec,
    function(callback, opts)
      return AUTH_CLIENT.submit_login(S.email, S.password, callback, opts)
    end,
    function()
      sync_tokens_from_client()
      apply_remember_policy()
      S.password = ""
      S.current_user = nil
      S.current_user_claims = nil
      S.status_text = t("Login OK.")
    end,
    nil,
    default_submit_opts(),
    { allow_refresh_401 = false }
  )
  return true
end

function Auth.request_refresh(flow_label, on_done)
  local rec = create_record("auth", "refresh", flow_label or t("Refresh"), CFG.auth_max_attempts)
  submit_record(
    rec,
    function(callback, opts)
      return AUTH_CLIENT.submit_refresh(callback, opts)
    end,
    function(payload)
      sync_tokens_from_client()
      apply_remember_policy()
      if on_done then on_done(true, payload, rec) end
    end,
    function(payload)
      if on_done then on_done(false, payload, rec) end
    end,
    default_submit_opts(),
    { allow_refresh_401 = false }
  )
  return true
end

function Auth.request_get_current_user(flow_label)
  local rec = create_record("auth", "get_current_user", flow_label or t("Get Current User"), CFG.auth_max_attempts)
  submit_record(
    rec,
    function(callback, opts)
      return AUTH_CLIENT.submit_get_current_user(callback, opts)
    end,
    function(payload)
      S.current_user = payload and payload.user or nil
      S.current_user_claims = payload and payload.claims or nil
      S.status_text = t("User profile loaded.")
    end,
    nil,
    default_submit_opts(),
    { allow_refresh_401 = false }
  )
  return true
end

function Auth.request_logout(flow_label, on_done)
  local rec = create_record("auth", "logout", flow_label or t("Logout"), CFG.auth_max_attempts)
  submit_record(
    rec,
    function(callback, opts)
      return AUTH_CLIENT.submit_logout(callback, opts)
    end,
    function(payload)
      local msg = trim(payload and payload.message or "")
      if msg == "" then msg = t("Logout OK.") end
      S.status_text = msg
      if on_done then on_done(true, payload) end
    end,
    function(payload)
      if on_done then on_done(false, payload) end
    end,
    default_submit_opts(),
    { allow_refresh_401 = false }
  )
  return true
end

function Auth.forget_stored_login_and_logout()
  sync_tokens_from_client()
  local had_access = (S.access_token ~= "")
  local had_refresh = (S.refresh_token ~= "")

  local function finalize_clear(message, payload)
    if payload and payload.ok ~= true then
      local err_txt = payload.api_error or payload.error or t("logout request failed")
      push_warning(t("Logout request failed, local auth still cleared: ") .. tostring(err_txt))
    end
    mark_auth_cleared(message or t("Stored login cleared."))
    S.last_api_error = ""
  end

  if (not had_access) and had_refresh then
    Auth.request_refresh(t("Refresh before Logout"), function(ok, payload)
      if not ok then
        finalize_clear(t("Stored login cleared (refresh failed before logout)."), payload)
        return
      end
      Auth.request_logout(t("Logout"), function(logout_ok, logout_payload)
        if logout_ok then
          finalize_clear(t("Stored login cleared after refresh+logout."), logout_payload)
        else
          finalize_clear(t("Stored login cleared (logout failed after refresh)."), logout_payload)
        end
      end)
    end)
    return
  end

  if had_access or had_refresh then
    Auth.request_logout(t("Logout"), function(ok, payload)
      if ok then
        finalize_clear(t("Stored login cleared after logout."), payload)
      else
        finalize_clear(t("Stored login cleared (logout failed)."), payload)
      end
    end)
  else
    finalize_clear(t("Stored login cleared."))
  end
end

local auto_auth_attempted = false
local email_prefilled_from_ext_state = false

local function try_startup_auto_auth_once()
  if auto_auth_attempted then return end
  auto_auth_attempted = true

  sync_tokens_from_client()
  if not S.has_stored_refresh then
    return
  end

  local scheduled = Jobs.schedule_job(t("Auto Refresh"), function()
    Auth.request_refresh(t("Startup Refresh"), function(ok, payload)
      if not ok then
        local http_num = tonumber(payload and payload.http_code or nil)
        if http_num == 401 or http_num == 403 then
          mark_auth_cleared(t("Stored login invalid. Please log in again."))
          return
        end
        local raw_err = (payload and (payload.api_error or payload.error)) or t("request failed")
        S.status_text = t("Startup Refresh failed: ") .. tostring(raw_err)
        S.last_api_error = tostring(raw_err)
        push_warning(S.status_text)
        return
      end
      if S.access_token == "" then
        mark_auth_cleared(t("Stored login invalid. Please log in again."))
        return
      end
      S.status_text = t("Login refreshed.")
    end)
  end)
  if not scheduled then
    S.status_text = t("Could not schedule startup auth refresh.")
    push_warning(S.status_text)
  end
end

local ScriptAligner = {}

local function file_extension_lower(path)
  local ext = tostring(path or ""):match("%.([^%.\\/]+)$")
  ext = trim(ext or ""):lower()
  if ext == "" then return nil end
  return ext
end

local function mime_for_file_path(path)
  local ext = file_extension_lower(path)
  if ext == "docx" then
    return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  end
  if ext == "flac" then
    return "audio/flac"
  end
  return "application/octet-stream"
end

local function ensure_project_path()
  refresh_project_relative_paths()
  if S.project_path == "" then
    local msg = t("Project path not available. Save the project first.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    return false
  end
  return true
end

local function ensure_logged_in()
  sync_tokens_from_client()
  if S.access_token == "" then
    local msg = t("Login required before script aligner flow.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    return false
  end
  return true
end

local function ensure_docx_path()
  local path = trim(S.aligner_script_path)
  if path == "" then
    local msg = t("Select DOCX file first.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    return false
  end
  if file_extension_lower(path) ~= "docx" then
    local msg = t("Script file must be .docx")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    return false
  end
  return true
end

local function next_run_context()
  S.aligner_run_seq = (tonumber(S.aligner_run_seq) or 0) + 1
  return {
    id = "aligner_run_" .. tostring(S.aligner_run_seq),
    title = "script-aligner-" .. os.date("%Y%m%d-%H%M%S"),
    script_path = S.aligner_script_path,
    audio_input_mode = "selected_track_time_selection",
    audio_path = "",
    text_fields = nil,
    audio_fields = nil,
    text_file_id = "",
    audio_file_id = "",
    text_upload_url = "",
    audio_upload_url = "",
    text_upload_fields = nil,
    audio_upload_fields = nil,
    job_id = "",
    job = nil,
    poll_record = nil,
    poll_next_at = nil,
    poll_inflight = false,
    polling_enabled = false,
    poll_stop_local = false,
    render_info = nil,
    base_import_offset_sec = nil,
    script_aligner_options = nil
  }
end

local function is_active_run(run)
  return type(run) == "table" and type(S.aligner_active_run) == "table" and tostring(run.id or "") ~= "" and tostring(run.id or "") == tostring(S.aligner_active_run.id or "")
end

local function make_result_context_from_run(run)
  if type(run) ~= "table" then return nil end
  return {
    audio_input_mode = run.audio_input_mode,
    base_import_offset_sec = run.base_import_offset_sec,
    rendered_audio_path = run.render_info and run.render_info.input_path or nil,
    source_docx_path = run.script_path,
    source_audio_path = run.audio_path,
    job_id = run.job_id,
    run_title = run.title
  }
end

function ScriptAligner.select_script_file()
  local started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("neurocast_select_docx", {
    request_label = "select_docx"
  })
  if not ensure_project_path() then
    TelemetryBridge.operation_failed("neurocast_select_docx", {
      request_label = "select_docx",
      error_code = "PROJECT_PATH_MISSING",
      safe_message = S.last_api_error
    }, started_at)
    return false
  end
  local initial_dir = trim(S.last_prompt_for_file_dir)
  if initial_dir == "" then initial_dir = S.project_path end
  local ok_pick, selected_or_err = prompt_for_file(t("Select DOCX file"), initial_dir, "*.docx")
  if not ok_pick then
    S.status_text = tostring(selected_or_err)
    TelemetryBridge.operation_canceled("neurocast_select_docx", {
      request_label = "select_docx",
      safe_message = S.status_text
    }, started_at)
    return false
  end
  local new_dir = Files.get_dir_from_file_path(selected_or_err)
  if type(new_dir) == "string" and new_dir ~= "" then
    S.last_prompt_for_file_dir = new_dir
  end
  S.aligner_script_path = tostring(selected_or_err)
  S.status_text = t("Selected DOCX") .. ": " .. S.aligner_script_path
  S.last_api_error = ""
  TelemetryBridge.operation_completed("neurocast_select_docx", {
    request_label = "select_docx",
    source_docx_path = S.aligner_script_path,
    source_docx_size = Files.file_size(S.aligner_script_path)
  }, started_at)
  return true
end

local function prepare_run_inputs(run)
  local text_fields, text_err = SCRIPT_ALIGNER_CLIENT.make_upload_request_fields_from_path(run.script_path, {
    mime_type = mime_for_file_path(run.script_path)
  })
  if type(text_fields) ~= "table" then
    return false, t("DOCX file prep failed: ") .. tostring(text_err)
  end
  run.text_fields = text_fields

  local ok_tmp, tmp_err = Files.ensure_tmp_dir(CFG.tmp_dir)
  if not ok_tmp then
    return false, tmp_err or t("Temp directory is not writable.")
  end
  local render_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("neurocast_render_time_selection", {
    request_label = "render_time_selection",
    active_run = TelemetryBridge.active_run_summary(run)
  })
  local ok_render, render_msg, render_info = NeurocastScriptAlignerReaper.render_time_selection_to_temp(CFG.tmp_dir, {
    file_stem_prefix = "script_aligner"
  })
  if not ok_render then
    TelemetryBridge.operation_failed("neurocast_render_time_selection", {
      request_label = "render_time_selection",
      error_code = "RENDER_FAILED",
      safe_message = render_msg or t("Failed to render selected track time selection."),
      active_run = TelemetryBridge.active_run_summary(run)
    }, render_started_at, "render_failed")
    return false, render_msg or t("Failed to render selected track time selection.")
  end
  run.render_info = render_info
  run.audio_path = render_info.input_path
  run.base_import_offset_sec = tonumber(render_info.start_time) or 0
  TelemetryBridge.operation_completed("neurocast_render_time_selection", {
    request_label = "render_time_selection",
    rendered_audio_path = tostring(run.audio_path or ""),
    rendered_audio_size = Files.file_size(run.audio_path),
    render_start_time = render_info.start_time,
    render_end_time = render_info.end_time,
    render_duration_sec = render_info.duration,
    active_run = TelemetryBridge.active_run_summary(run)
  }, render_started_at)

  local rendered_audio_fields, rendered_audio_err = SCRIPT_ALIGNER_CLIENT.make_upload_request_fields_from_path(run.audio_path, {
    mime_type = "audio/flac"
  })
  if type(rendered_audio_fields) ~= "table" then
    return false, t("Rendered audio prep failed: ") .. tostring(rendered_audio_err)
  end
  run.audio_fields = rendered_audio_fields
  return true
end

function ScriptAligner.start()
  local preflight_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("neurocast_script_aligner_preflight", {
    request_label = "start_script_aligner",
    source_docx_path = S.aligner_script_path,
    source_docx_size = Files.file_size(S.aligner_script_path),
    options = current_script_aligner_request_options()
  })
  if not ensure_project_path() then
    TelemetryBridge.operation_failed("neurocast_script_aligner_preflight", {
      request_label = "start_script_aligner",
      error_code = "PROJECT_PATH_MISSING",
      safe_message = S.last_api_error
    }, preflight_started_at)
    return false
  end
  if not ensure_logged_in() then
    TelemetryBridge.operation_failed("neurocast_script_aligner_preflight", {
      request_label = "start_script_aligner",
      error_code = "LOGIN_REQUIRED",
      safe_message = S.last_api_error
    }, preflight_started_at)
    return false
  end
  if not ensure_docx_path() then
    TelemetryBridge.operation_failed("neurocast_script_aligner_preflight", {
      request_label = "start_script_aligner",
      error_code = "DOCX_PATH_INVALID",
      safe_message = S.last_api_error
    }, preflight_started_at)
    return false
  end
  local selection_spec, selection_err = NeurocastScriptAlignerReaper.validate_time_selection_input()
  if not selection_spec then
    S.status_text = selection_err or t("Select exactly one track and a non-empty time selection.")
    S.last_api_error = S.status_text
    push_warning(S.status_text)
    TelemetryBridge.operation_failed("neurocast_script_aligner_preflight", {
      request_label = "start_script_aligner",
      error_code = "TIME_SELECTION_INVALID",
      safe_message = S.status_text
    }, preflight_started_at)
    return false
  end
  TelemetryBridge.operation_completed("neurocast_script_aligner_preflight", {
    request_label = "start_script_aligner",
    selection_track_name = tostring(selection_spec.track_name or ""),
    selection_start_time = selection_spec.start_time,
    selection_end_time = selection_spec.end_time,
    selection_duration_sec = selection_spec.duration,
    source_docx_path = S.aligner_script_path,
    source_docx_size = Files.file_size(S.aligner_script_path)
  }, preflight_started_at)

  clear_result_state()
  local run = next_run_context()
  run._telemetry_flow_started_at = TelemetryBridge.now()
  run.script_aligner_options = current_script_aligner_request_options()
  local ok_prepare, prepare_err = prepare_run_inputs(run)
  if not ok_prepare then
    S.status_text = prepare_err
    S.last_api_error = prepare_err
    push_warning(prepare_err)
    TelemetryBridge.operation_failed("neurocast_script_aligner_prepare_inputs", {
      request_label = "prepare_run_inputs",
      error_code = "PREPARE_INPUTS_FAILED",
      safe_message = prepare_err,
      active_run = TelemetryBridge.active_run_summary(run)
    })
    return false
  end

  S.aligner_active_run = run
  S.aligner_last_success_job = nil
  S.aligner_last_success_job_id = ""
  S.status_text = t("Script aligner flow started") .. ": " .. tostring(run.title)
  S.last_api_error = ""
  TelemetryBridge.operation_started("neurocast_script_aligner_flow", {
    request_label = "start_script_aligner",
    active_run = TelemetryBridge.active_run_summary(run)
  })
  ScriptAligner.start_text_request_upload(run)
  return true
end

function ScriptAligner.start_text_request_upload(run)
  if not is_active_run(run) then return false end
  local rec = create_record("aligner", "request_upload_text", t("Request Upload: DOCX"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_request_upload(S.access_token, run.text_fields, callback, opts)
  end, function(payload)
    if not is_active_run(run) then return end
    run.text_file_id = tostring(payload.file_id or "")
    run.text_upload_url = tostring(payload.upload_url or "")
    run.text_upload_fields = payload.upload_fields
    ScriptAligner.start_text_upload(run)
  end, nil, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.start_text_upload(run)
  if not is_active_run(run) then return false end
  local rec = create_record("aligner", "upload_text", t("Upload DOCX"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_upload_to_presigned(
      run.text_upload_url,
      run.text_fields.local_file_path,
      run.text_fields.mime_type,
      run.text_upload_fields,
      callback,
      opts
    )
  end, function()
    if not is_active_run(run) then return end
    ScriptAligner.start_text_confirm(run)
  end, nil, upload_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.start_text_confirm(run)
  if not is_active_run(run) then return false end
  local rec = create_record("aligner", "confirm_upload_text", t("Confirm DOCX Upload"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_confirm_upload(S.access_token, run.text_file_id, callback, opts)
  end, function()
    if not is_active_run(run) then return end
    ScriptAligner.start_audio_request_upload(run)
  end, nil, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.start_audio_request_upload(run)
  if not is_active_run(run) then return false end
  local rec = create_record("aligner", "request_upload_audio", t("Request Upload: Audio"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_request_upload(S.access_token, run.audio_fields, callback, opts)
  end, function(payload)
    if not is_active_run(run) then return end
    run.audio_file_id = tostring(payload.file_id or "")
    run.audio_upload_url = tostring(payload.upload_url or "")
    run.audio_upload_fields = payload.upload_fields
    ScriptAligner.start_audio_upload(run)
  end, nil, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.start_audio_upload(run)
  if not is_active_run(run) then return false end
  local rec = create_record("aligner", "upload_audio", t("Upload Audio"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_upload_to_presigned(
      run.audio_upload_url,
      run.audio_fields.local_file_path,
      run.audio_fields.mime_type,
      run.audio_upload_fields,
      callback,
      opts
    )
  end, function()
    if not is_active_run(run) then return end
    ScriptAligner.start_audio_confirm(run)
  end, nil, upload_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.start_audio_confirm(run)
  if not is_active_run(run) then return false end
  local rec = create_record("aligner", "confirm_upload_audio", t("Confirm Audio Upload"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_confirm_upload(S.access_token, run.audio_file_id, callback, opts)
  end, function()
    if not is_active_run(run) then return end
    ScriptAligner.start_create_job(run)
  end, nil, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.start_create_job(run)
  if not is_active_run(run) then return false end
  -- KNOWN TECHNICAL DEBT: this mutating create request intentionally retains
  -- the generic automatic/manual retry surface. An ambiguous response may
  -- therefore create a duplicate alignment. Reconcile existing Studio jobs
  -- before manually retrying an ambiguous create failure.
  run.script_aligner_options = NeurocastScriptAlignerSettings.build_request_options(run.script_aligner_options)
  local rec = create_record("aligner", "start_script_aligner", t("Start Script Aligner"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_start_script_aligner(S.access_token, {
      title = run.title,
      text_file_id = run.text_file_id,
      media_file_id = run.audio_file_id,
      options = run.script_aligner_options
    }, callback, opts)
  end, function(payload)
    if not is_active_run(run) then return end
    local job_id = trim(payload and payload.job_id or "")
    if job_id == "" and type(payload and payload.result_body) == "table" then
      job_id = trim(payload.result_body.id)
    end
    if job_id ~= "" then
      run.job_id = job_id
      run.job = payload and payload.result_body or nil
      ScriptAligner.begin_polling(run)
      return
    end
    ScriptAligner.start_recover_job_id(run)
  end, nil, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.start_recover_job_id(run)
  if not is_active_run(run) then return false end
  local rec = create_record("aligner", "list_jobs", t("Recover Job ID"), CFG.aligner_max_attempts)
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_list_jobs(S.access_token, callback, opts)
  end, function(payload)
    if not is_active_run(run) then return end
    local job, find_err = SCRIPT_ALIGNER_CLIENT.find_latest_script_aligner_job(payload.jobs, {
      title = run.title,
      exact_title = true
    })
    if type(job) ~= "table" then
      local msg = t("Failed to recover script aligner job id: ") .. tostring(find_err or t("not found"))
      S.status_text = msg
      S.last_api_error = msg
      push_warning(msg)
      TelemetryBridge.operation_failed("neurocast_recover_job_id", {
        request_label = "list_jobs",
        error_code = "RECOVER_JOB_ID_FAILED",
        safe_message = msg,
        active_run = TelemetryBridge.active_run_summary(run)
      })
      return
    end
    run.job = job
    run.job_id = trim(job.id)
    if run.job_id == "" then
      local msg = t("Recovered job has empty id.")
      S.status_text = msg
      S.last_api_error = msg
      push_warning(msg)
      TelemetryBridge.operation_failed("neurocast_recover_job_id", {
        request_label = "list_jobs",
        error_code = "RECOVERED_JOB_ID_EMPTY",
        safe_message = msg,
        active_run = TelemetryBridge.active_run_summary(run)
      })
      return
    end
    ScriptAligner.begin_polling(run)
  end, nil, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.begin_polling(run)
  if not is_active_run(run) then return false end
  if trim(run.job_id) == "" then
    local msg = t("Cannot start polling: job id is missing.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    TelemetryBridge.operation_failed("neurocast_script_aligner_polling", {
      request_label = "get_job",
      error_code = "JOB_ID_MISSING",
      safe_message = msg,
      active_run = TelemetryBridge.active_run_summary(run)
    })
    return false
  end
  run.polling_enabled = true
  run.poll_stop_local = false
  run.poll_inflight = false
  run.poll_next_at = nil
  if type(run.poll_record) ~= "table" then
    run.poll_record = create_record("aligner", "get_job", t("Poll Job Status"), CFG.aligner_max_attempts)
  end
  run.poll_record._custom_progress = t("polling")
  S.status_text = t("Polling started for job") .. ": " .. tostring(run.job_id)
  run._telemetry_polling_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("neurocast_script_aligner_polling", {
    request_label = "get_job",
    job_id = tostring(run.job_id or ""),
    active_run = TelemetryBridge.active_run_summary(run)
  })
  ScriptAligner.schedule_next_poll(run, true)
  return true
end

function ScriptAligner.schedule_next_poll(run, immediate)
  if not is_active_run(run) then return false end
  if run.polling_enabled ~= true or run.poll_stop_local == true then return false end
  if immediate then
    run.poll_next_at = r.time_precise()
    ScriptAligner.submit_poll(run)
    return true
  end
  local min_v = tonumber(CFG.aligner_poll_min_sec) or 3.0
  local max_v = tonumber(CFG.aligner_poll_max_sec) or 15.0
  run.poll_next_at = r.time_precise() + min_v + (math.random() * math.max(0, max_v - min_v))
  return true
end

function ScriptAligner.submit_poll(run)
  if not is_active_run(run) or run.poll_inflight == true or trim(run.job_id) == "" then return false end
  if run.polling_enabled ~= true or run.poll_stop_local == true then return false end

  run.poll_inflight = true
  local rec = run.poll_record
  rec._custom_progress = t("polling")
  submit_record(rec, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_get_job(S.access_token, run.job_id, callback, opts)
  end, function(payload)
    if not is_active_run(run) then return end
    run.poll_inflight = false
    run.job = payload and payload.job or nil
    local status = tostring(payload and payload.job and payload.job.status or "")
    TelemetryBridge.poll_status_transition(run, status)
    if SCRIPT_ALIGNER_CLIENT.is_job_terminal_status(status) then
      run.polling_enabled = false
      run.poll_next_at = nil
      rec._custom_progress = ""
      S.aligner_last_success_job = run.job
      S.aligner_last_success_job_id = tostring(run.job_id or "")
      if SCRIPT_ALIGNER_CLIENT.is_job_success_status(status) then
        S.status_text = t("Script aligner done. Downloading result JSON...")
        S.last_api_error = ""
        TelemetryBridge.operation_completed("neurocast_script_aligner_polling", {
          request_label = "get_job",
          job_id = tostring(run.job_id or ""),
          job_status = SCRIPT_ALIGNER_CLIENT.normalize_job_status(status),
          active_run = TelemetryBridge.active_run_summary(run)
        }, run._telemetry_polling_started_at)
        ScriptAligner.download_result_for_job(run.job_id, run.job, make_result_context_from_run(run))
      else
        local msg = t("Script aligner terminal status") .. ": " .. tostring(SCRIPT_ALIGNER_CLIENT.normalize_job_status(status))
        S.status_text = msg
        S.last_api_error = msg
        push_warning(msg)
        run._telemetry_flow_completed = true
        TelemetryBridge.operation_failed("neurocast_script_aligner_polling", {
          request_label = "get_job",
          error_code = "SCRIPT_ALIGNER_TERMINAL_FAILURE",
          safe_message = msg,
          job_id = tostring(run.job_id or ""),
          job_status = SCRIPT_ALIGNER_CLIENT.normalize_job_status(status),
          active_run = TelemetryBridge.active_run_summary(run)
        }, run._telemetry_polling_started_at)
        TelemetryBridge.operation_failed("neurocast_script_aligner_flow", {
          request_label = "start_script_aligner",
          error_code = "SCRIPT_ALIGNER_TERMINAL_FAILURE",
          safe_message = msg,
          job_id = tostring(run.job_id or ""),
          job_status = SCRIPT_ALIGNER_CLIENT.normalize_job_status(status),
          active_run = TelemetryBridge.active_run_summary(run)
        }, run._telemetry_flow_started_at)
      end
      return
    end
    ScriptAligner.schedule_next_poll(run, false)
  end, function()
    if not is_active_run(run) then return end
    run.poll_inflight = false
    if run.polling_enabled == true and run.poll_stop_local ~= true then
      local msg = t("Polling request failed; scheduling next poll.")
      S.status_text = msg
      push_warning(msg)
      ScriptAligner.schedule_next_poll(run, false)
    end
  end, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.maybe_poll_tick()
  local run = S.aligner_active_run
  if type(run) ~= "table" or run.polling_enabled ~= true or run.poll_stop_local == true then return false end
  if run.poll_inflight == true or run.poll_next_at == nil then return false end
  if r.time_precise() < run.poll_next_at then return false end
  return ScriptAligner.submit_poll(run)
end

function ScriptAligner.stop_polling()
  local run = S.aligner_active_run
  if type(run) ~= "table" or run.polling_enabled ~= true then
    S.status_text = t("No active polling to stop.")
    return false
  end
  run.poll_stop_local = true
  run.polling_enabled = false
  run.poll_next_at = nil
  run.poll_inflight = false
  if type(run.poll_record) == "table" then
    run.poll_record._custom_progress = ""
  end
  S.status_text = t("Polling stopped locally.")
  TelemetryBridge.operation_canceled("neurocast_script_aligner_polling", {
    request_label = "stop_polling",
    job_id = tostring(run.job_id or ""),
    active_run = TelemetryBridge.active_run_summary(run)
  }, run._telemetry_polling_started_at)
  return true
end

function ScriptAligner.parse_downloaded_result(path, context)
  local started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("neurocast_parse_result_json", {
    request_label = "parse_result_json",
    result_json_path = tostring(path or ""),
    result_json_size = Files.file_size(path),
    result_context = context
  })
  local parsed, parse_err = NeurocastScriptAlignerResult.parse_result_file(path)
  S.aligner_last_download_path = tostring(path or "")
  S.aligner_last_download_context = context
  S.aligner_last_import_message = ""
  S.aligner_last_import_report = nil

  if not parsed then
    S.aligner_parsed_result = nil
    S.aligner_last_parse_error = tostring(parse_err or t("Result parse failed."))
    S.status_text = t("Downloaded JSON could not be parsed.")
    S.last_api_error = S.aligner_last_parse_error
    push_warning(S.aligner_last_parse_error)
    TelemetryBridge.operation_failed("neurocast_parse_result_json", {
      request_label = "parse_result_json",
      error_code = "RESULT_JSON_PARSE_FAILED",
      safe_message = S.aligner_last_parse_error,
      result_json_path = tostring(path or ""),
      result_json_size = Files.file_size(path),
      result_context = context
    }, started_at)
    return false
  end

  S.aligner_parsed_result = parsed
  S.aligner_last_parse_error = ""
  if tonumber(parsed.warning_count or 0) > 0 then
    S.status_text = string.format(
      t("Downloaded and parsed result JSON with %d warning(s)."),
      tonumber(parsed.warning_count or 0) or 0
    )
  else
    S.status_text = t("Downloaded and parsed result JSON successfully.")
  end
  S.last_api_error = ""
  TelemetryBridge.operation_completed("neurocast_parse_result_json", {
    request_label = "parse_result_json",
    result_json_path = tostring(path or ""),
    result_json_size = Files.file_size(path),
    result_summary = TelemetryBridge.result_summary(parsed),
    result_context = context
  }, started_at)
  local run = S.aligner_active_run
  if type(run) == "table" and type(context) == "table" and tostring(context.run_title or "") == tostring(run.title or "") and run._telemetry_flow_completed ~= true then
    run._telemetry_flow_completed = true
    TelemetryBridge.operation_completed("neurocast_script_aligner_flow", {
      request_label = "start_script_aligner",
      job_id = tostring(context.job_id or run.job_id or ""),
      result_json_path = tostring(path or ""),
      result_summary = TelemetryBridge.result_summary(parsed),
      active_run = TelemetryBridge.active_run_summary(run)
    }, run._telemetry_flow_started_at)
  end
  return true
end

function ScriptAligner.download_result_for_job(job_id, job, result_context)
  if not ensure_project_path() then
    TelemetryBridge.operation_failed("neurocast_download_result_json", {
      request_label = "download_result_json",
      error_code = "PROJECT_PATH_MISSING",
      safe_message = S.last_api_error,
      job_id = tostring(job_id or "")
    })
    return false
  end
  if not ensure_logged_in() then
    TelemetryBridge.operation_failed("neurocast_download_result_json", {
      request_label = "download_result_json",
      error_code = "LOGIN_REQUIRED",
      safe_message = S.last_api_error,
      job_id = tostring(job_id or "")
    })
    return false
  end

  local resolved_job_id = trim(job_id)
  if resolved_job_id == "" then
    local msg = t("No successful script aligner job is available for download.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    TelemetryBridge.operation_failed("neurocast_download_result_json", {
      request_label = "download_result_json",
      error_code = "JOB_ID_MISSING",
      safe_message = msg
    })
    return false
  end

  local dl_ctx = {
    job_id = resolved_job_id,
    job = job,
    files = nil,
    primary_result_file = nil,
    download_url = "",
    target_path = "",
    result_context = result_context
  }

  local rec_files = create_record("aligner", "get_job_files", t("Get Job Files"), CFG.aligner_max_attempts)
  submit_record(rec_files, function(callback, opts)
    return SCRIPT_ALIGNER_CLIENT.submit_get_job_files(S.access_token, dl_ctx.job_id, callback, opts)
  end, function(payload)
    dl_ctx.files = payload and payload.files or nil
    local result_file, pick_err = SCRIPT_ALIGNER_CLIENT.pick_primary_json_result_file(dl_ctx.job, dl_ctx.files)
    if type(result_file) ~= "table" then
      local msg = t("Could not resolve primary JSON result file: ") .. tostring(pick_err)
      S.status_text = msg
      S.last_api_error = msg
      push_warning(msg)
      TelemetryBridge.operation_failed("neurocast_resolve_result_file", {
        request_label = "get_job_files",
        error_code = "RESULT_FILE_MISSING",
        safe_message = msg,
        job_id = tostring(dl_ctx.job_id or "")
      })
      return
    end
    dl_ctx.primary_result_file = result_file

    local rec_url = create_record("aligner", "get_job_file_download_url", t("Get Result Download URL"), CFG.aligner_max_attempts)
    submit_record(rec_url, function(callback, opts)
      return SCRIPT_ALIGNER_CLIENT.submit_get_job_file_download_url(
        S.access_token,
        dl_ctx.job_id,
        tostring(dl_ctx.primary_result_file.id or ""),
        callback,
        opts
      )
    end, function(url_payload)
      dl_ctx.download_url = tostring(url_payload and url_payload.url or "")
      local target_path, path_err = Files.build_safe_download_path(
        S.project_path,
        dl_ctx.primary_result_file.name,
        CFG.result_prefix
      )
      if type(target_path) ~= "string" or target_path == "" then
        local msg = t("Failed to build download path: ") .. tostring(path_err)
        S.status_text = msg
        S.last_api_error = msg
        push_warning(msg)
        TelemetryBridge.operation_failed("neurocast_download_result_json", {
          request_label = "download_result_json",
          error_code = "DOWNLOAD_PATH_BUILD_FAILED",
          safe_message = msg,
          job_id = tostring(dl_ctx.job_id or "")
        })
        return
      end
      dl_ctx.target_path = target_path

      local rec_download = create_record("aligner", "download_result_json", t("Download Result JSON"), CFG.aligner_max_attempts)
      submit_record(rec_download, function(callback)
        return SCRIPT_ALIGNER_CLIENT.submit_download_from_presigned(
          dl_ctx.download_url,
          dl_ctx.target_path,
          callback,
          download_submit_opts()
        )
      end, function(download_payload)
        local out_path = tostring(download_payload and download_payload.out_path or dl_ctx.target_path or "")
        S.aligner_last_download_path = out_path
        S.status_text = t("Downloaded result JSON") .. ": " .. out_path
        S.last_api_error = ""
        ScriptAligner.parse_downloaded_result(out_path, dl_ctx.result_context)
      end, nil, download_submit_opts(), { allow_refresh_401 = true })
    end, nil, default_submit_opts(), { allow_refresh_401 = true })
  end, nil, default_submit_opts(), { allow_refresh_401 = true })
  return true
end

function ScriptAligner.download_latest_result_json()
  local job_id = trim(S.aligner_last_success_job_id)
  if job_id == "" then
    local msg = t("No successful script aligner run in this session.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    TelemetryBridge.operation_failed("neurocast_download_result_json", {
      request_label = "download_latest_result_json",
      error_code = "SUCCESS_JOB_MISSING",
      safe_message = msg
    })
    return false
  end
  local result_context = S.aligner_last_download_context
  local run = S.aligner_active_run
  if type(run) == "table" and trim(run.job_id) == job_id then
    result_context = make_result_context_from_run(run)
  end
  return ScriptAligner.download_result_for_job(job_id, S.aligner_last_success_job, result_context)
end

function ScriptAligner.reparse_last_downloaded_result()
  local path = trim(S.aligner_last_download_path)
  if path == "" then
    local msg = t("No downloaded JSON is available to parse.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    TelemetryBridge.operation_failed("neurocast_parse_result_json", {
      request_label = "reparse_result_json",
      error_code = "RESULT_JSON_PATH_MISSING",
      safe_message = msg
    })
    return false
  end
  return ScriptAligner.parse_downloaded_result(path, S.aligner_last_download_context)
end

function ScriptAligner.import_last_parsed_result()
  local started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("neurocast_import_result_to_project", {
    request_label = "import_result",
    import_offset_enabled = S.aligner_import_offset_enabled == true,
    import_offset_direction = tostring(S.aligner_import_offset_direction or ""),
    import_offset_seconds = tonumber(refresh_import_offset_seconds()) or 0,
    result_json_path = tostring(S.aligner_last_download_path or ""),
    result_summary = TelemetryBridge.result_summary(S.aligner_parsed_result)
  })
  if type(S.aligner_parsed_result) ~= "table" then
    local msg = t("No parsed result is available to import.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    TelemetryBridge.operation_failed("neurocast_import_result_to_project", {
      request_label = "import_result",
      error_code = "PARSED_RESULT_MISSING",
      safe_message = msg
    }, started_at)
    return false
  end

  local context = type(S.aligner_last_download_context) == "table" and S.aligner_last_download_context or {}
  if type(context.base_import_offset_sec) ~= "number" then
    local msg = t("Track-mode import requires a remembered time-selection start offset from this session.")
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    TelemetryBridge.operation_failed("neurocast_import_result_to_project", {
      request_label = "import_result",
      error_code = "BASE_IMPORT_OFFSET_MISSING",
      safe_message = msg,
      result_context = context,
      result_summary = TelemetryBridge.result_summary(S.aligner_parsed_result)
    }, started_at)
    return false
  end
  local base_offset_sec = tonumber(context.base_import_offset_sec) or 0
  base_offset_sec = base_offset_sec + (tonumber(refresh_import_offset_seconds()) or 0)

  local rows, rows_err = NeurocastScriptAlignerResult.build_import_rows(S.aligner_parsed_result, {
    base_offset_sec = base_offset_sec,
    chars_per_second = CFG.fallback_chars_per_second,
    min_fallback_item_length_sec = CFG.fallback_min_item_length_sec
  })
  if type(rows) ~= "table" then
    local msg = t("Failed to build import rows: ") .. tostring(rows_err)
    S.status_text = msg
    S.last_api_error = msg
    push_warning(msg)
    TelemetryBridge.operation_failed("neurocast_import_result_to_project", {
      request_label = "import_result",
      error_code = "IMPORT_ROWS_BUILD_FAILED",
      safe_message = msg,
      base_offset_sec = base_offset_sec,
      result_summary = TelemetryBridge.result_summary(S.aligner_parsed_result)
    }, started_at)
    return false
  end

  local ok_import, import_msg, report = NeurocastScriptAlignerReaper.apply_import_rows(rows, {
    undo_label = t("Import Neurocast Script Aligner JSON")
  })
  S.aligner_last_import_message = tostring(import_msg or "")
  S.aligner_last_import_report = report
  S.status_text = S.aligner_last_import_message
  if ok_import then
    S.last_api_error = ""
    TelemetryBridge.operation_completed("neurocast_import_result_to_project", {
      request_label = "import_result",
      base_offset_sec = base_offset_sec,
      row_count = #rows,
      import_report = report,
      result_summary = TelemetryBridge.result_summary(S.aligner_parsed_result)
    }, started_at)
    return true
  end
  S.last_api_error = S.aligner_last_import_message
  push_warning(S.aligner_last_import_message)
  TelemetryBridge.operation_failed("neurocast_import_result_to_project", {
    request_label = "import_result",
    error_code = "IMPORT_APPLY_FAILED",
    safe_message = S.aligner_last_import_message,
    base_offset_sec = base_offset_sec,
    row_count = #rows,
    import_report = report,
    result_summary = TelemetryBridge.result_summary(S.aligner_parsed_result)
  }, started_at)
  return false
end

local function active_poll_run_for_record(rec)
  local run = S.aligner_active_run
  if type(run) ~= "table" then return nil end
  if run.poll_record ~= rec then return nil end
  if run.polling_enabled ~= true or run.poll_stop_local == true then return nil end
  return run
end

local function active_poll_countdown_seconds(run)
  if type(run) ~= "table" then return nil end
  if run.poll_next_at == nil then return nil end
  local remaining = math.max(0, math.ceil((tonumber(run.poll_next_at) or 0) - r.time_precise()))
  return remaining
end

function ScriptAligner.build_status_line()
  local run = S.aligner_active_run
  if type(run) ~= "table" then
    return t("Run") .. ": " .. t("(none)")
  end
  local polling = (run.polling_enabled == true and run.poll_stop_local ~= true) and t("on") or t("off")
  local job_id = trim(run.job_id)
  if job_id == "" then job_id = t("(pending)") end
  local next_poll_text = ""
  if run.polling_enabled == true and run.poll_stop_local ~= true then
    local remaining = active_poll_countdown_seconds(run)
    if run.poll_inflight == true then
      next_poll_text = t("polling now")
    elseif remaining ~= nil then
      next_poll_text = string.format(t("next in %ds"), remaining)
    end
  end
  if next_poll_text ~= "" then
    return string.format(
      "%s: %s | %s: %s | %s: %s | %s: %s",
      t("Run"),
      tostring(run.title or ""),
      t("Job"),
      job_id,
      t("Polling"),
      polling,
      t("Next poll"),
      next_poll_text
    )
  end
  return string.format("%s: %s | %s: %s | %s: %s", t("Run"), tostring(run.title or ""), t("Job"), job_id, t("Polling"), polling)
end

local function build_record_rows()
  local rows = {}
  for _, group in ipairs({ S.auth_records, S.aligner_records }) do
    for i = 1, #group do
      local rec = group[i]
      if rec and rec._retry_generation == S.retry_generation then
        rows[#rows + 1] = rec
      end
    end
  end
  return rows
end

local function classify_record_state(rec, job)
  if active_poll_run_for_record(rec) ~= nil then
    return "running"
  end
  if rec and rec._state then
    if rec._state == "failed_final" then return "failed" end
    if rec._state == "ok" then return "ok" end
    if rec._state == "retrying" then return "retrying" end
    if rec._state == "running" then return "running" end
  end
  if job then
    if job.phase == "running" then return "running" end
    if job.phase == "created" or job.phase == "launched" then return "queued" end
    if job.phase == "completed" then
      if job.result and job.result.ok then return "ok" end
      return "failed"
    end
  end
  return "queued"
end

local function format_record_progress(rec)
  local job = rec.job_id and S.curl_jobs[rec.job_id] or nil
  local active_poll_run = active_poll_run_for_record(rec)
  if active_poll_run ~= nil and active_poll_run.poll_inflight ~= true then
    local remaining = active_poll_countdown_seconds(active_poll_run)
    if remaining ~= nil then
      return string.format(t("polling | next in %ds"), remaining)
    end
  end
  if rec._state == "failed_final" then
    return rec._custom_progress ~= "" and rec._custom_progress or t("failed")
  end
  if rec._state == "ok" then
    return rec._custom_progress ~= "" and rec._custom_progress or t("ok")
  end
  if rec._state == "retrying" then
    if rec._next_retry_at then
      local remaining = rec._next_retry_at - r.time_precise()
      if remaining < 0 then remaining = 0 end
      return string.format(t("retry in %.1fs"), remaining)
    end
    return t("retrying")
  end
  if rec._state == "running" then
    local custom = tostring(rec._custom_progress or "")
    local flow_line = job and job.progress and job.progress.flow and job.progress.flow.line or ""
    flow_line = tostring(flow_line or "")
    if custom ~= "" and flow_line ~= "" and flow_line:lower() ~= "running" then
      return custom .. " | " .. flow_line
    end
    if custom ~= "" then
      return custom
    end
    if flow_line ~= "" then
      return flow_line
    end
    return t("running")
  end
  if job and job.phase == "running" then
    local flow_line = job.progress and job.progress.flow and job.progress.flow.line
    if trim(flow_line or "") ~= "" then
      return flow_line
    end
    return t("running")
  end
  if job and (job.phase == "created" or job.phase == "launched") then
    return t("queued")
  end
  if job and job.phase == "completed" then
    if job.result and job.result.ok then return t("ok") end
    return t("failed")
  end
  return t("queued")
end

local function progress_pct_text(job)
  local meter = job and job.progress and job.progress.meter or nil
  if type(meter) ~= "table" then return nil end

  local candidates = {
    meter.total_pct,
    meter.received_pct,
    meter.xferd_pct
  }
  for i = 1, #candidates do
    local raw = tostring(candidates[i] or "")
    local pct = tonumber(raw:match("^([%d]+%.?%d*)%%?$"))
    if pct ~= nil then
      if pct < 0 then pct = 0 end
      if pct > 100 then pct = 100 end
      if math.abs(pct - math.floor(pct + 0.0001)) < 0.0001 then
        return string.format("%d%%", math.floor(pct + 0.0001))
      end
      return string.format("%.1f%%", pct)
    end
  end
  return nil
end

local function progress_with_pct(rec)
  local label = format_record_progress(rec)
  local job = rec and rec.job_id and S.curl_jobs[rec.job_id] or nil
  local active_poll_run = active_poll_run_for_record(rec)
  if active_poll_run ~= nil and active_poll_run.poll_inflight ~= true then
    return label
  end
  if classify_record_state(rec, job) ~= "running" then
    return label
  end
  local pct = progress_pct_text(job)
  if pct ~= nil then
    local normalized = tostring(label or "")
    if normalized == "" or normalized == "running" then
      return pct
    end
    if normalized:find("%%", 1, true) then
      return normalized
    end
    return normalized .. " (" .. pct .. ")"
  end
  return label
end

local function can_retry_record(rec)
  return rec and rec._state == "failed_final" and type(rec._retry_submit) == "function"
end

local function render_status_panel(ctx_to_show, suffix)
  local ui_ctx = ctx_to_show or ctx
  local id_suffix = suffix or ""
  local rows = build_record_rows()
  local counts = { queued = 0, running = 0, ok = 0, failed = 0, retrying = 0 }
  for i = 1, #rows do
    local rec = rows[i]
    local job = rec and rec.job_id and S.curl_jobs and S.curl_jobs[rec.job_id] or nil
    local state = classify_record_state(rec, job)
    counts[state] = (counts[state] or 0) + 1
  end
  local summary = string.format(
    t("Queued %d | Running %d | Retrying %d | OK %d | Failed %d"),
    counts.queued, counts.running, counts.retrying, counts.ok, counts.failed
  )
  if counts.failed > 0 or trim(S.last_api_error) ~= "" then
    ImGui.PushStyleColor(ui_ctx, ImGui.Col_Text, 0xFF3030FF)
  elseif counts.running > 0 or counts.retrying > 0 then
    ImGui.PushStyleColor(ui_ctx, ImGui.Col_Text, 0xF0F000FF)
  else
    ImGui.PushStyleColor(ui_ctx, ImGui.Col_Text, 0x00FF00FF)
  end
  ImGui.TextWrapped(ui_ctx, t("Status") .. ": " .. summary)
  ImGui.PopStyleColor(ui_ctx)
  if trim(S.status_text) ~= "" then
    ui_info(t("Last status") .. ": " .. S.status_text, ui_ctx)
  end
  ImGui.PushStyleVar(ui_ctx, ImGui.StyleVar_SeparatorTextAlign, 0.15, 0.5)
  ImGui.SeparatorText(ui_ctx, t("Warnings"))
  ImGui.PopStyleVar(ui_ctx)
  if #S.warnings == 0 then
    ui_info(t("None."), ui_ctx)
  else
    for i = 1, #S.warnings do
      ui_warning(S.warnings[i], ui_ctx)
    end
  end
  if button_clicked("clear_warnings_btn" .. id_suffix, t("Clear warnings"), nil, ui_ctx) then
    S.warnings = {}
  end
end

local function record_flow_label(rec)
  if tostring(rec and rec.kind or "") == "auth" then
    return t("Auth")
  end
  return t("Aligner")
end

local function record_label(rec)
  local base = tostring(rec and rec.flow_label or "")
  local attempt = tonumber(rec and rec._attempt or 0) or 0
  local max_attempts = tonumber(rec and rec._max_attempts or 0) or 0
  if attempt > 0 and max_attempts > 0 then
    return string.format("%s [%d/%d]", base, attempt, max_attempts)
  end
  return base
end

local function draw_request_table()
  local rows = build_record_rows()
  if not ImGui.BeginTable then
    ui_info(t("Table rendering not available in this ImGui build."))
    return
  end
  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY
  local table_height = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 12) or 240
  if ImGui.BeginTable(ctx, "##request_records_table", 6, table_flags, -1, table_height) then
    ImGui.TableSetupColumn(ctx, t("Flow"), ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, t("Record"), ImGui.TableColumnFlags_WidthFixed, 230)
    ImGui.TableSetupColumn(ctx, t("Progress"), ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx, t("HTTP"), ImGui.TableColumnFlags_WidthFixed, 60)
    ImGui.TableSetupColumn(ctx, t("Error"), ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx, t("Actions"), ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableHeadersRow(ctx)
    if #rows == 0 then
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, "-")
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, t("No requests yet."))
    else
      for i = 1, #rows do
        local rec = rows[i]
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0); ImGui.TextWrapped(ctx, record_flow_label(rec))
        ImGui.TableSetColumnIndex(ctx, 1); ImGui.TextWrapped(ctx, record_label(rec))
        ImGui.TableSetColumnIndex(ctx, 2); ImGui.TextWrapped(ctx, progress_with_pct(rec))
        ImGui.TableSetColumnIndex(ctx, 3); ImGui.Text(ctx, rec._last_http_code and tostring(rec._last_http_code) or "-")
        ImGui.TableSetColumnIndex(ctx, 4); ImGui.TextWrapped(ctx, tostring(rec._last_error_summary or ""))
        ImGui.TableSetColumnIndex(ctx, 5)
        local retry_enabled = can_retry_record(rec)
        if not retry_enabled then ImGui.BeginDisabled(ctx, true) end
        if button_clicked("retry_" .. tostring(rec.id), t("Retry") .. "##" .. tostring(rec.id)) then
          local ok_retry, retry_err = Jobs.manual_retry_record(rec)
          if ok_retry then
            S.status_text = t("Retry queued") .. ": " .. tostring(rec.flow_label or rec.endpoint)
            S.last_api_error = ""
          else
            S.status_text = t("Retry failed") .. ": " .. tostring(retry_err)
            S.last_api_error = S.status_text
            push_warning(S.status_text)
          end
        end
        if not retry_enabled then ImGui.EndDisabled(ctx) end
      end
      if ImGui.SetScrollHereY then
        ImGui.SetScrollHereY(ctx, 1.0)
      end
    end
    ImGui.EndTable(ctx)
  end
end

local function draw_locale_picker()
  ImGui.Text(ctx, t("Language") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  local locale_combo_disabled = not translated_locale_available("rus")
  if locale_combo_disabled and ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, true) end
  local locale_combo_open = ImGui.BeginCombo(ctx, "##aligner_ui_locale_combo", locale_display_name(active_locale))
  if locale_combo_open then
    local options = { "eng" }
    if translated_locale_available("rus") then options[#options + 1] = "rus" end
    for _, locale_id in ipairs(options) do
      local is_selected = (active_locale == locale_id)
      local activated = ImGui.Selectable(ctx, locale_display_name(locale_id), is_selected)
      if activated then
        set_active_runtime_locale(locale_id)
        persist_locale(locale_id)
      end
      if is_selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
  if locale_combo_disabled and ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
end

local function draw_current_user_block()
  if type(S.current_user) ~= "table" then return end
  ImGui.SeparatorText(ctx, t("Current User"))
  ui_info("id: " .. tostring(S.current_user.id or ""))
  ui_info("email: " .. tostring(S.current_user.email or ""))
  ui_info("username: " .. tostring(S.current_user.username or ""))
end

local function draw_result_summary()
  if trim(S.aligner_last_download_path) ~= "" then
    ui_info(t("Last downloaded JSON") .. ": " .. S.aligner_last_download_path)
  end
  if trim(S.aligner_last_parse_error) ~= "" then
    ui_warning(t("Result parse failed") .. ": " .. S.aligner_last_parse_error)
    return
  end
  local parsed = S.aligner_parsed_result
  if type(parsed) ~= "table" then return end

  ui_info(string.format(
    t("Parsed lines: %d | corrected timing: %d | fallback timing: %d | corrected issues: %d | unused segments: %d"),
    tonumber(parsed.line_count or 0) or 0,
    tonumber(parsed.aligned_count or 0) or 0,
    tonumber(parsed.fallback_count or 0) or 0,
    tonumber(parsed.corrected_timing_issue_count or 0) or 0,
    tonumber(parsed.no_used_segments_count or 0) or 0
  ))

  local status_keys = sorted_status_keys(parsed.status_counts)
  if #status_keys > 0 then
    local parts = {}
    for i = 1, #status_keys do
      parts[#parts + 1] = status_keys[i] .. "=" .. tostring(parsed.status_counts[status_keys[i]] or 0)
    end
    ui_info(t("Statuses") .. ": " .. table.concat(parts, ", "))
  end

  local context = type(S.aligner_last_download_context) == "table" and S.aligner_last_download_context or {}
  if type(context.base_import_offset_sec) == "number" then
    ui_info(t("Track-mode import base offset") .. ": " .. format_seconds(context.base_import_offset_sec))
  else
    ui_warning(t("Track-mode import requires a remembered time-selection start offset from this session."))
  end

  ui_info(import_offset_summary_text())

  local changed_offset_enabled, new_offset_enabled =
    ImGui.Checkbox(ctx, t("Enable import offset"), S.aligner_import_offset_enabled == true)
  if changed_offset_enabled then
    set_import_offset_enabled(new_offset_enabled)
  end
  ImGui.SameLine(ctx)

  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, S.aligner_import_offset_enabled ~= true)
  end
  if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
    local direction_label = import_offset_direction_label(S.aligner_import_offset_direction)
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, 110)
    end
    if ImGui.BeginCombo(ctx, t("Offset direction"), direction_label) then
      local left_selected = normalize_import_offset_direction(S.aligner_import_offset_direction) == "left"
      if ImGui.Selectable(ctx, t("Left"), left_selected) then
        set_import_offset_direction("left")
      end
      local right_selected = normalize_import_offset_direction(S.aligner_import_offset_direction) ~= "left"
      if ImGui.Selectable(ctx, t("Right"), right_selected) then
        set_import_offset_direction("right")
      end
      ImGui.EndCombo(ctx)
    end
  else
    ui_info(string.format(t("Offset direction: %s"), import_offset_direction_label(S.aligner_import_offset_direction)))
  end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Offset hours:"))
  ImGui.SameLine(ctx)
  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 42)
  end
  local changed_offset_hours, new_offset_hours =
    ImGui.InputText(ctx, "##aligner_import_offset_hours", tostring(S.aligner_import_offset_hours_input or ""))
  if changed_offset_hours then
    set_import_offset_hours_from_input(new_offset_hours)
  end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Offset minutes:"))
  ImGui.SameLine(ctx)
  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 42)
  end
  local changed_offset_minutes, new_offset_minutes =
    ImGui.InputText(ctx, "##aligner_import_offset_minutes", tostring(S.aligner_import_offset_minutes_input or ""))
  if changed_offset_minutes then
    set_import_offset_minutes_from_input(new_offset_minutes)
  end
  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.EndDisabled(ctx)
  end

  if type(context.base_import_offset_sec) == "number" then
    local resolved_offset = (tonumber(context.base_import_offset_sec) or 0) + (tonumber(refresh_import_offset_seconds()) or 0)
    ui_info(t("Resolved import base offset") .. ": " .. format_seconds(resolved_offset))
  end

  if button_clicked("aligner_reparse_result", t("Re-parse downloaded JSON")) then
    ScriptAligner.reparse_last_downloaded_result()
  end
  ImGui.SameLine(ctx)
  if button_clicked("aligner_import_result", t("Import parsed JSON to project")) then
    ScriptAligner.import_last_parsed_result()
  end

  if trim(S.aligner_last_import_message) ~= "" then
    ui_info(t("Last import") .. ": " .. S.aligner_last_import_message)
  end
end

local function draw_paths_section()
  ui_info(string.format(t("Project path: %s"), S.project_path ~= "" and S.project_path or t("(unknown)")))
  ui_info(string.format(t("Temp folder: %s"), CFG.tmp_dir))
  if button_clicked("refresh_checks_btn", t("Refresh checks")) then
    rebuild_warnings()
  end
  if S.tmp_writable then
    ui_info(t("Temp directory is writable."))
  else
    ui_warning(t("Temp directory is NOT writable."))
  end
end

local function draw_auth_section()
  ui_info(t("Email") .. ":")
  ImGui.SetNextItemWidth(ctx, -10.0)
  local changed_email, new_email = ImGui.InputText(ctx, "##email", S.email or "")
  if changed_email then S.email = new_email end

  ui_info(t("Password") .. ":")
  ImGui.SetNextItemWidth(ctx, -10.0)
  local changed_pass, new_pass = ImGui.InputText(ctx, "##password", S.password or "", ImGui.InputTextFlags_Password)
  if changed_pass then S.password = new_pass end

  local changed_remember, new_remember = ImGui.Checkbox(ctx, t("Remember me"), S.remember_me)
  if changed_remember then
    S.remember_me = new_remember
    if not new_remember then
      AUTH_CLIENT.forget_refresh_token()
      forget_email()
    else
      apply_remember_policy()
    end
  end

  local login_disabled = Jobs.network_busy() or (S.access_token ~= "")
  if login_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("login_btn", t("Login")) then
    Jobs.schedule_job(t("Login"), function() Auth.request_login() end)
  end
  if login_disabled then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  local forget_disabled = Jobs.network_busy()
  if forget_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("forget_login_btn", t("Forget stored login (and logout)")) then
    Jobs.schedule_job(t("Forget+Logout"), function() Auth.forget_stored_login_and_logout() end)
  end
  if forget_disabled then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  local load_user_disabled = Jobs.network_busy() or (S.access_token == "")
  if load_user_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("load_current_user_btn", t("Load current user")) then
    Jobs.schedule_job(t("Get Current User"), function()
      Auth.request_get_current_user(t("Get Current User"))
    end)
  end
  if load_user_disabled then ImGui.EndDisabled(ctx) end

  draw_current_user_block()
end

local function draw_script_aligner_section()
  if not ImGui.CollapsingHeader(ctx, t("Script Aligner")) then return end

  S.project_path = Files.read_project_path() or ""
  ui_info(t("Selected DOCX") .. ": " .. (trim(S.aligner_script_path) ~= "" and S.aligner_script_path or t("(not selected)")))
  ui_info(ScriptAligner.build_status_line())
  ui_info(t("Last successful job id") .. ": " .. (trim(S.aligner_last_success_job_id) ~= "" and S.aligner_last_success_job_id or t("(none)")))
  ui_info(t("Audio input") .. ": " .. t("Selected track + time selection"))

  local unsaved_project = (S.project_path == "")
  if unsaved_project then
    ui_warning(t("Project must be saved to use script aligner controls."))
  end

  local select_disabled = unsaved_project or Jobs.network_busy()
  if select_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("aligner_select_script", t("Select DOCX")) then
    ScriptAligner.select_script_file()
  end
  if select_disabled then ImGui.EndDisabled(ctx) end

  local selection_spec, selection_err = NeurocastScriptAlignerReaper.validate_time_selection_input()
  if selection_spec then
    ui_info(t("Track mode source") .. ": " .. tostring(selection_spec.track_name or ""))
    ui_info(t("Time selection") .. ": " .. format_seconds(selection_spec.start_time) .. " -> " .. format_seconds(selection_spec.end_time))
    ui_info(t("Track mode renders a temp post-FX FLAC before upload."))
  else
    ui_warning(selection_err or t("Select exactly one track and a non-empty time selection."))
  end

  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 220)
  end
  local changed_match_threshold, new_match_threshold = ImGui.SliderDouble(
    ctx,
    t("Match threshold (0-1)"),
    tonumber(S.aligner_match_confidence_threshold) or NeurocastScriptAlignerSettings.DEFAULTS.matchConfidenceThreshold,
    0.0,
    1.0,
    "%.2f"
  )
  if changed_match_threshold then
    set_script_aligner_match_confidence_threshold(new_match_threshold)
  end

  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 220)
  end
  local changed_time_window, new_time_window = ImGui.SliderInt(
    ctx,
    t("Time window (sec)"),
    tonumber(S.aligner_time_window_seconds) or NeurocastScriptAlignerSettings.DEFAULTS.timeWindowSeconds,
    1,
    60
  )
  if changed_time_window then
    set_script_aligner_time_window_seconds(new_time_window)
  end

  ui_info(t("CSV threshold is not exposed here; REAPER uses the server default."))

  local start_disabled = unsaved_project or Jobs.network_busy() or (S.access_token == "") or (trim(S.aligner_script_path) == "")
  start_disabled = start_disabled or (selection_spec == nil)
  if start_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("aligner_start_flow", t("Start script aligner")) then
    Jobs.schedule_job(t("Start Script Aligner"), function() ScriptAligner.start() end)
  end
  if start_disabled then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  local stop_enabled = type(S.aligner_active_run) == "table" and S.aligner_active_run.polling_enabled == true
  if not stop_enabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("aligner_stop_polling", t("Stop polling")) then
    ScriptAligner.stop_polling()
  end
  if not stop_enabled then ImGui.EndDisabled(ctx) end

  local download_disabled = unsaved_project or Jobs.network_busy() or (S.access_token == "") or (trim(S.aligner_last_success_job_id) == "")
  if download_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("aligner_download_result_json", t("Download result JSON")) then
    Jobs.schedule_job(t("Download Result JSON"), function() ScriptAligner.download_latest_result_json() end)
  end
  if download_disabled then ImGui.EndDisabled(ctx) end

  draw_result_summary()
end

local function diagnostics_threshold_label(level)
  local labels = {
    [0] = t("Debug"),
    [1] = t("Info"),
    [2] = t("Warnings"),
    [3] = t("Errors"),
    [4] = t("Off")
  }
  return labels[tonumber(level)] or labels[4]
end

local function draw_diagnostics_settings()
  local diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Logging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, "##neurocast_logging_threshold", diagnostics_threshold_label(diagnostics.logging_threshold), ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ 4, 0, 1, 2, 3 }) do
      local selected = diagnostics.logging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_logging_threshold(level)
        if not ok_set then push_warning(string.format(t("Logging threshold save failed: %s"), tostring(err))) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Messaging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, "##neurocast_messaging_threshold", diagnostics_threshold_label(diagnostics.messaging_threshold), ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ 0, 1, 2, 3, 4 }) do
      local selected = diagnostics.messaging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_messaging_threshold(level)
        if not ok_set then push_warning(string.format(t("Messaging threshold save failed: %s"), tostring(err))) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  ui_info(string.format(t("Log folder: %s"), diagnostics.log_dir))
  ui_info(string.format(
    t("Current log file: %s"),
    diagnostics.current_log_file ~= "" and diagnostics.current_log_file or t("(created after the first matching message)")
  ))
  if button_clicked("copy_diagnostics_log_folder_btn", t("Copy log folder"), 0.2) then
    ImGui.SetClipboardText(ctx, diagnostics.log_dir)
  end
  ui_info(t("Local logs may contain project paths, filenames, and workflow content."))
  if diagnostics.messaging_threshold == 4 then
    ui_warning(t("Messaging is Off. Util-driven errors may be hidden."))
  end
end

local function draw_telemetry_level_setting()
  local desc = TelemetryBridge.describe_status()
  local current_level = tostring(desc.effective_level or "support")
  local current_level_label = TelemetryBridge.level_label(current_level)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, t("Telemetry level") .. "##neurocast_telemetry_level", current_level_label, ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ "basic", "support", "debug" }) do
      local selected = current_level == level
      local level_label = TelemetryBridge.level_label(level)
      if ImGui.Selectable(ctx, level_label, selected) then
        local ok_call, ok_set, set_or_err = pcall(Telemetry.set_level, level)
        if ok_call and ok_set then
          S.telemetry_ui_status = string.format(t("Telemetry level set to %s."), level_label)
          TelemetryBridge.safe_event("feature_used", {
            operation = "neurocast_telemetry_settings",
            status = "level_changed",
            telemetry_level = level
          }, {
            operation = "neurocast_telemetry_settings",
            status = "level_changed"
          })
        else
          local err = ok_call and set_or_err or ok_set
          S.telemetry_ui_status = string.format(t("Telemetry level save failed: %s"), tostring(err))
          push_warning(S.telemetry_ui_status)
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

local function draw_settings_section()
  if not ImGui.CollapsingHeader(ctx, t("Settings")) then return end
  ImGui.SeparatorText(ctx, t("Account / Credentials"))
  draw_auth_section()
  ImGui.SeparatorText(ctx, t("Paths"))
  draw_paths_section()
  ImGui.SeparatorText(ctx, t("Diagnostics"))
  draw_diagnostics_settings()
  ImGui.SeparatorText(ctx, t("Telemetry"))
  draw_telemetry_level_setting()
end

local function draw_telemetry_section()
  local desc = TelemetryBridge.describe_status()
  local header_state = TelemetryBridge.header_state(desc)
  local header_label = string.format(t("Telemetry (%s)"), header_state) .. "###neurocast_telemetry_section"
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  local telemetry_open = ImGui.CollapsingHeader(ctx, header_label)
  ImGui.PopStyleColor(ctx)
  if not telemetry_open then return end

  local progress = TelemetryBridge.progress_text(desc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  ImGui.TextWrapped(ctx, string.format(t("Telemetry status: %s"), tostring(desc.status or "")))
  ImGui.PopStyleColor(ctx)

  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, string.format(t("Telemetry progress: %s"), progress))
  else
    local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "##neurocast_telemetry_status_table", 2, flags, -1, 0) then
      ImGui.TableSetupColumn(ctx, t("Field"), ImGui.TableColumnFlags_WidthFixed, 180)
      ImGui.TableSetupColumn(ctx, t("Value"), ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableHeadersRow(ctx)

      local rows = {
        { t("Status"), tostring(desc.status or "") },
        { t("Progress"), progress },
        { t("Level"), TelemetryBridge.level_label(desc.effective_level) },
        { t("Queue bytes"), tostring(tonumber(desc.sendable_queue_bytes) or 0) },
        { t("Queued / flushed"), string.format("%d / %d", tonumber(desc.queued_events_session) or 0, tonumber(desc.flushed_events_session) or 0) },
        { t("Failed / dropped / skipped"), string.format("%d / %d / %d", tonumber(desc.failed_batches_session) or 0, tonumber(desc.dropped_events_session) or 0, tonumber(desc.skipped_events_session) or 0) },
        { t("HTTP / curl"), string.format("%s / %s", tostring(desc.last_http_code or "-"), tostring(desc.last_curl_exitcode or "-")) }
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
  end

  if trim(S.telemetry_ui_status or "") ~= "" then
    ImGui.TextWrapped(ctx, S.telemetry_ui_status)
  end

  local flush_disabled = desc.active_job_id ~= nil
  if flush_disabled then ImGui.BeginDisabled(ctx, true) end
  if button_clicked("telemetry_flush_now_btn", t("Flush telemetry now"), 0.2) then
    TelemetryBridge.safe_flush_async("neurocast_manual")
  end
  if flush_disabled then ImGui.EndDisabled(ctx) end

  if desc.send_paused then
    ImGui.SameLine(ctx)
    if button_clicked("telemetry_resume_btn", t("Resume telemetry sending"), 0.2) then
      local ok_resume, resume_or_err = pcall(Telemetry.resume_sending, t("manual resume from Neurocast UI"))
      S.telemetry_ui_status = ok_resume and t("Telemetry sending resumed.") or string.format(t("Telemetry resume failed: %s"), tostring(resume_or_err))
    end
  end

  ImGui.SameLine(ctx)
  if button_clicked("telemetry_copy_paths_btn", t("Copy telemetry paths"), 0.2) then
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
    S.telemetry_ui_status = t("Telemetry paths copied.")
  end

  local details = {
    "initialized: " .. tostring(desc.initialized == true),
    "settings_path: " .. tostring(desc.settings_path or ""),
    "queue_path: " .. tostring(desc.queue_path or ""),
    "runtime_root: " .. tostring(desc.paths and desc.paths.root or ""),
    "effective_level: " .. tostring(desc.effective_level or ""),
    "send_paused: " .. tostring(desc.send_paused == true),
    "send_pause_reason: " .. tostring(desc.send_pause_reason or ""),
    "last_error: " .. tostring(desc.last_error or ""),
    "last_backend_error: " .. tostring(desc.last_backend_error or "")
  }
  ImGui.InputTextMultiline(ctx, "##neurocast_telemetry_details", table.concat(details, "\n"), 0, 0, ImGui.InputTextFlags_ReadOnly)
end

local function draw_details_section()
  if not ImGui.CollapsingHeader(ctx, t("Details")) then return end
  local flags = ImGui.InputTextFlags_ReadOnly
  ImGui.InputTextMultiline(ctx, "##errbox", S.last_api_error or "", 0, 0, flags)
  local last = S.last_curl_return or {}
  local all_lines =
    "ok: " .. tostring(last.ok) .. "\n" ..
    "http: " .. tostring(last.http) .. "\n" ..
    "body: " .. Util.head32(tostring(last.body)) .. "\n" ..
    "headers: " .. Util.head32(tostring(last.headers_txt)) .. "\n" ..
    "meta: " .. Util.head32(tostring(last.meta)) .. "\n" ..
    "err: " .. tostring(last.err) .. "\n" ..
    "cmd: " .. tostring(last.cmd)
  ImGui.InputTextMultiline(ctx, "##curl_last_status", all_lines, 0, 0, flags)
end

local function reset_state(reason)
  Jobs.reset_runtime(reason or "reset state")
  S.auth_records = {}
  S.aligner_records = {}
  S.aligner_script_path = ""
  S.aligner_active_run = nil
  S.aligner_last_success_job = nil
  S.aligner_last_success_job_id = ""
  S.last_http = ""
  S.last_api_error = ""
  S.last_curl_return = { ok = "", http = "", body = "", headers_txt = "", meta = "", err = "", cmd = "" }
  clear_result_state()
  rebuild_warnings()
  S.status_text = t("State reset.")
end

local function gui_loop()
  refresh_project_relative_paths()
  local now_t = Jobs.now()
  TelemetryBridge.safe_tick(now_t)
  Jobs.tick_all(now_t)
  sync_tokens_from_client()
  ScriptAligner.maybe_poll_tick()

  if not email_prefilled_from_ext_state then
    local stored_email = load_email_from_ext_state()
    if S.email == "" and stored_email and stored_email ~= "" then
      S.email = stored_email
    end
    email_prefilled_from_ext_state = true
  end

  try_startup_auto_auth_once()

  ImGui.SetNextWindowSize(ctx_status, 500, 375, ImGui.Cond_FirstUseEver)
  if S.show_status_window then
    local status_visible = ImGui.Begin(ctx_status, current_status_window_title_text(), nil, ImGui.WindowFlags_NoTitleBar)
    if status_visible then
      render_status_panel(ctx_status, "_status_window")
      ImGui.End(ctx_status)
    end
  end

  ImGui.SetNextWindowSize(ctx, 840, 930, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, current_main_window_title_text(), true, ImGui.WindowFlags_NoCollapse)
  if visible then
    ImGui.PushFont(ctx, FONT, font_size)

    draw_locale_picker()
    ImGui.SameLine(ctx)
    local changed_show_status, new_show_status = ImGui.Checkbox(ctx, t("Show status window"), S.show_status_window)
    if changed_show_status then
      S.show_status_window = new_show_status
      persist_show_status_window(new_show_status)
      TelemetryBridge.safe_event("feature_used", {
        operation = "neurocast_status_window_toggle",
        status = new_show_status and "enabled" or "disabled",
        enabled = new_show_status == true
      }, {
        operation = "neurocast_status_window_toggle",
        status = new_show_status and "enabled" or "disabled",
        priority = "low"
      })
    end
    if not S.show_status_window then
      render_status_panel(ctx, "_inline")
    end

    draw_settings_section()
    draw_script_aligner_section()

    if button_clicked("reset_state_btn", t("Clear request table and reset state")) then
      reset_state("reset state")
    end

    draw_request_table()
    draw_telemetry_section()
    draw_details_section()

    ImGui.PopFont(ctx)
    ImGui.End(ctx)
  end

  if open then
    r.defer(gui_loop)
  else
    TelemetryBridge.send_closed_event("window_closed")
  end
end

load_locale_on_startup()
do
  local stored = load_show_status_window()
  if stored ~= nil then S.show_status_window = stored end
end
load_script_aligner_settings_state()
load_import_offset_state()

rebuild_warnings()
S.last_prompt_for_file_dir = S.project_path or ""
TelemetryBridge.script_started()
r.defer(gui_loop)
