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
  return t("English")
end

local r = assert(reaper, t("Reaper API not found. This script must be run within Reaper."))

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
if not script_path then
  r.MB(t("Failed to get script path!"), t("Error"), 0)
  return
end

local old_package_path = package.path
package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. old_package_path
local send_telemetry_closed_event = nil
r.atexit(function()
  if type(send_telemetry_closed_event) == "function" then
    send_telemetry_closed_event("atexit")
  end
  package.path = old_package_path
end)

local function require_project_module(name)
  local ok, mod_or_err = pcall(require, name)
  if not ok then
    package.path = old_package_path
    r.MB(string.format(t("Failed to load %s: %s"), name, tostring(mod_or_err)), t("Error"), 0)
    return nil
  end
  return mod_or_err
end

local SCRIPT_VERSION = "v0.1.0"
local TOOLSET_VERSION = SCRIPT_VERSION

local Util = require_project_module("modules-neurocast.Util")
if not Util then return end
Util.messaging_level = 3
Util.msg_to_log_file = false
Util.log_level_override = nil
Util.configure_diagnostics("mvsep_tool")

local MODERN_REGION_API_NAMES = {
  "GetNumRegionsOrMarkers",
  "GetRegionOrMarker",
  "GetRegionOrMarkerInfo_Value",
  "SetRegionOrMarkerInfo_Value",
  "GetSetRegionOrMarkerInfo_String"
}

local function check_modern_region_api()
  local missing = {}
  for _, name in ipairs(MODERN_REGION_API_NAMES) do
    if type(r[name]) ~= "function" then
      missing[#missing + 1] = name
    end
  end
  if #missing > 0 then
    return false, string.format(t("missing functions: %s"), table.concat(missing, ", "))
  end

  local ok_count, count_value = pcall(r.GetNumRegionsOrMarkers, 0)
  local marker_count = ok_count and tonumber(count_value) or nil
  if marker_count == nil or marker_count < 0 or marker_count % 1 ~= 0 then
    return false, t("GetNumRegionsOrMarkers returned an invalid result")
  end
  return true, nil
end

local ok_region_api, region_api_err = check_modern_region_api()
if not ok_region_api then
  local installed_version = t("unknown")
  if type(r.GetAppVersion) == "function" then
    local ok_version, version_value = pcall(r.GetAppVersion)
    if ok_version and tostring(version_value or "") ~= "" then
      installed_version = tostring(version_value)
    end
  end

  Util.msg(
    "MVSEP startup aborted: modern REAPER ProjectMarker API check failed; " ..
      tostring(region_api_err or t("unknown compatibility error")) ..
      "; installed_version=" .. installed_version,
    3
  )

  local message = string.format(
    t("MVSEP requires REAPER 7.62 or newer.\n\nThis REAPER installation does not provide the modern project-region APIs required by MVSEP.\nInstalled REAPER version: %s\n\nPlease update REAPER and run the script again. MVSEP did not start."),
    installed_version
  )
  if type(r.MB) == "function" then
    r.MB(message, t("MVSEP requires a newer REAPER version"), 0)
  elseif type(r.ShowMessageBox) == "function" then
    r.ShowMessageBox(message, t("MVSEP requires a newer REAPER version"), 0)
  end
  package.path = old_package_path
  return
end

do
  local ok_languages, languages_or_err = pcall(require, "modules-neurocast.mvsep_tool_languages")
  if not ok_languages then
    r.MB(
      string.format(t("Failed to load translation module! Error message: %s"), tostring(languages_or_err)),
      t("Localization Error"),
      0
    )
  elseif type(languages_or_err) == "table" then
    local module_locale = normalize_runtime_locale(languages_or_err.locale)
    local module_translations = languages_or_err.translations_by_source_text
    if module_locale ~= "eng" and type(module_translations) == "table" then
      translated_runtime_locale = module_locale
      translations_by_source_text = module_translations
    end
  end
end

local Files = require_project_module("modules-neurocast.Files")
if not Files then return end
local Curl = require_project_module("modules-neurocast.Curl")
if not Curl then return end
local Jobs = require_project_module("modules-neurocast.Jobs")
if not Jobs then return end
local Cleanup = require_project_module("modules-neurocast.Cleanup")
if not Cleanup then return end
local json = require_project_module("modules-neurocast.json")
if not json then return end
local MVSepAPI = require_project_module("modules-neurocast.mvsep_api")
if not MVSepAPI then return end
local MVSepViaNeurocast = require_project_module("modules-neurocast.mvsep_api_via_neurocast")
if not MVSepViaNeurocast then return end
local NeurocastAuth = require_project_module("modules-neurocast.neurocast_auth")
if not NeurocastAuth then return end
local MVSepModelOptions = require_project_module("modules-neurocast.mvsep_model_options")
if not MVSepModelOptions then return end
local MVSepReaper = require_project_module("modules-neurocast.mvsep_reaper")
if not MVSepReaper then return end
local Telemetry = require_project_module("modules-neurocast.Telemetry")
if not Telemetry then return end

if not Telemetry.require_identity_or_abort({
  app_name = "CirilicaTools",
  entrypoint = "mvsep_tool",
  script_version = SCRIPT_VERSION
}) then
  package.path = old_package_path
  return
end

local ok_telemetry_init, telemetry_init_err = Telemetry.init({
  app_name = "CirilicaTools",
  entrypoint = "mvsep_tool",
  script_version = SCRIPT_VERSION,
  enable_file_log = false
})
if not ok_telemetry_init then
  package.path = old_package_path
  r.MB(string.format(t("Telemetry initialization failed:\n%s"), tostring(telemetry_init_err)), t("Telemetry Error"), 0)
  return
end

if not r.ImGui_CreateContext then
  r.MB(
    t("Missing dependency: ReaImGui extension.\nDownload it via Reapack ReaTeam extension repository."),
    t("Error"),
    0
  )
  return
end

package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ok_imgui, ImGuiOrErr = pcall(function()
  return require("imgui")("0.10")
end)
package.path = old_package_path
if not ok_imgui then
  r.MB(string.format(t("Failed to load ReaImGui Lua module: %s"), tostring(ImGuiOrErr)), t("Error"), 0)
  return
end
local ImGui = ImGuiOrErr

local FONT = ImGui.CreateFont("monospace")
local font_size = 16
local ctx = ImGui.CreateContext(t("MVSEP via Neurocast") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION)
local ctx_status = ImGui.CreateContext(t("Status") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION)
ImGui.Attach(ctx, FONT)
ImGui.Attach(ctx_status, FONT)

local EXTSTATE = {
  section = "mvsep_tool",
  ui_locale = "ui_locale",
  show_status_window = "show_status_window",
  auth_section = "df3mstbs",
  auth_refresh = "rams2Page",
  auth_email = "brue33",
  auth_backend = "er",
  input_mode = "input_mode",
  free_mode = "free_mode",
  region_concurrency = "region_concurrency",
  favorites_json = "favorites_json",
  selected_model_sep_type = "selected_model_sep_type",
  filter_text = "filter_text",
  favorites_only = "favorites_only",
  output_format_name = "output_format_name"
}

local function resolve_curl_path()
  if Util.mac then
    return "/usr/bin/curl"
  end

  local bundled_curl = Util.path_join(script_path, [=[bin\win]=]) .. [=[\curl.exe]=]
  local result = r.ExecProcess(bundled_curl .. " --version", 1500)
  local target = [=[curl 8.13.0 (Windows)]=]
  if result then
    if result:find(target, 1, true) then
      Util.msg("MVSEP curl resolved to bundled binary: " .. bundled_curl, 0)
      return bundled_curl
    end
    Util.msg("MVSEP bundled curl version mismatch, falling back to PATH curl. Output was:\n" .. tostring(result), 2)
  else
    Util.msg("MVSEP bundled curl check failed, falling back to PATH curl: " .. bundled_curl, 2)
  end
  local detail = result and
    string.format(t("Unexpected curl --version output:\n%s"), tostring(result)) or
    t("Could not run bundled curl --version.")
  r.MB(
    string.format(
      t("Bundled curl was not found or did not match the expected version at:\n%s\n\nThe script will try Windows system curl from PATH instead.\n\nExpected: %s\n%s"),
      tostring(bundled_curl),
      target,
      detail
    ),
    t("Warning"),
    0
  )
  return "curl"
end

local CFG = {
  backend_base_url = MVSepViaNeurocast.production_base_url(),
  backend_development_url = MVSepViaNeurocast.development_base_url(),
  curl = resolve_curl_path(),
  project_folder_name = "mvsep_data",
  tmp_dir = "",
  poll_interval_sec = 15.0,
  initial_poll_delay_sec = 5.0,
  button_cooldown_sec = 1.1,
  free_max_duration_sec = 600,
  max_paid_concurrency = 4
}

local S = {
  status_text = "",
  last_api_error = "",
  warnings = {},
  show_status_window = false,
  pending_job = nil,
  wait_until = nil,
  running_label = nil,
  ui_lock_network_buttons = false,
  curl_jobs = {},
  cleanup_queue = {},
  retry_queue = {},
  retry_generation = 0,
  last_curl_return = { ok = "", http = "", body = "", headers_txt = "", meta = "", err = "", cmd = "" },
  email = "",
  password = "",
  access_token = "",
  refresh_token = "",
  remember_login = true,
  has_stored_refresh = false,
  auth_request_inflight = false,
  auth_status = t("Signed out"),
  backend_base_url_override = "",
  input_mode = "time_selection",
  free_mode = false,
  region_concurrency = 1,
  output_format_name = MVSepAPI.DEFAULT_OUTPUT_FORMAT_NAME,
  favorites = {},
  selected_model_sep_type = "56",
  filter_text = "",
  favorites_only = false,
  model_field_values = {},
  remembered_model_field_values = {},
  paths = nil,
  catalog = nil,
  catalog_loaded_from_cache = false,
  catalog_fetch_inflight = false,
  network_records = {},
  records = {},
  next_record_id = 1,
  next_display_batch_id = 1,
  telemetry_ui_status = ""
}

local button_last_click_at = {}
local TelemetryBridge = {}

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
    or lowered:find("cookie", 1, true) ~= nil
    or lowered:find("csrf", 1, true) ~= nil
    or lowered:find("session", 1, true) ~= nil
    or lowered:find("password", 1, true) ~= nil
    or lowered:find("credential", 1, true) ~= nil
    or lowered:find("secret", 1, true) ~= nil
    or lowered:find("api_key", 1, true) ~= nil
    or lowered == "key"
end

function TelemetryBridge.redact_secret_values(value)
  local text = tostring(value or "")
  for _, secret in ipairs({ S.access_token, S.refresh_token, S.password }) do
    local token = Util.trim(secret or "")
    if #token >= 4 then
      text = text:gsub(telemetry_pattern_escape(token), "[REDACTED_SECRET]")
    end
  end
  text = text:gsub("[Hh][Tt][Tt][Pp][Ss]?://[^%s%]%[<>\"']+", "[REDACTED_URL]")
  text = text:gsub("[Hh][Tt][Tt][Pp][Ss]?%%3[Aa]%%2[Ff]%%2[Ff][^%s%]%[<>\"']+", "[REDACTED_ENCODED_URL]")
  text = text:gsub("Authorization:%s*Bearer%s+[%w%p]+", "Authorization: Bearer [REDACTED_SECRET]")
  text = text:gsub("authorization:%s*Bearer%s+[%w%p]+", "authorization: Bearer [REDACTED_SECRET]")
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

function TelemetryBridge.try_encode_json(value, limit)
  local ok_encoded, encoded = pcall(json.encode, value)
  if not ok_encoded then
    return TelemetryBridge.safe_string(encoded, limit)
  end
  return TelemetryBridge.safe_string(encoded, limit)
end

function TelemetryBridge.selected_model_summary()
  local sep_type = tostring(S.selected_model_sep_type or "")
  local algorithms = type(S.catalog) == "table" and S.catalog.algorithms or {}
  for _, algorithm in ipairs(algorithms) do
    if tostring(algorithm.sep_type or "") == sep_type then
      return {
        sep_type = sep_type,
        name = tostring(algorithm.name or ""),
        group_name = tostring(algorithm.group_name or ""),
        supported_v1 = algorithm.supported_v1 == true,
        field_count = #(algorithm.fields or {})
      }
    end
  end
  return {
    sep_type = sep_type
  }
end

function TelemetryBridge.base_payload(data)
  local paths = S.paths or {}
  local catalog = type(S.catalog) == "table" and S.catalog or {}
  local out = {
    app_area = "mvsep_neurocast",
    backend_class = MVSepViaNeurocast.classify_base_url(
      Util.trim(S.backend_base_url_override or "") ~= "" and S.backend_base_url_override or CFG.backend_base_url
    ),
    backend_host = select(2, MVSepViaNeurocast.classify_base_url(
      Util.trim(S.backend_base_url_override or "") ~= "" and S.backend_base_url_override or CFG.backend_base_url
    )),
    project_path = tostring(paths.project_path or ""),
    temp_dir = tostring(paths.tmp_dir or CFG.tmp_dir or ""),
    results_dir = tostring(paths.results_dir or ""),
    cache_file = tostring(paths.cache_file or ""),
    curl_path = tostring(CFG.curl or ""),
    input_mode = tostring(S.input_mode or ""),
    free_mode = S.free_mode == true,
    region_concurrency = tonumber(S.region_concurrency) or 1,
    output_format_name = tostring(S.output_format_name or ""),
    selected_model = TelemetryBridge.selected_model_summary(),
    catalog_loaded_from_cache = S.catalog_loaded_from_cache == true,
    catalog_algorithm_count = #(catalog.algorithms or {}),
    record_count = #(S.records or {}),
    network_record_count = #(S.network_records or {})
  }
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

function TelemetryBridge.operation_from_stage(stage)
  local key = tostring(stage or "")
  if key == "catalog" then return "mvsep_refresh_catalog" end
  if key == "render" then return "mvsep_render_input" end
  if key == "region_render" then return "mvsep_render_regions" end
  if key == "create" then return "mvsep_create_upload" end
  if key == "poll" then return "mvsep_poll_status" end
  if key == "download" then return "mvsep_download_result" end
  if key == "cancel" then return "mvsep_cancel_remote" end
  if key == "delete" then return "mvsep_delete_remote" end
  if key == "import" then return "mvsep_add_to_project" end
  if key == "retry" then return "mvsep_manual_retry" end
  return "mvsep_workflow"
end

function TelemetryBridge.downloads_payload(rec)
  local rows = {}
  for i, item in ipairs(type(rec) == "table" and rec.downloads or {}) do
    if i > 20 then
      rows[#rows + 1] = { truncated_more = #rec.downloads - 20 }
      break
    end
    rows[#rows + 1] = {
      label = tostring(item.label or ""),
      local_size = item.local_path and Files.file_size(item.local_path) or nil,
      track_name = tostring(item.track_name or ""),
      downloaded = item.downloaded == true,
      imported = item.imported == true
    }
  end
  return rows
end

function TelemetryBridge.record_payload(rec, extra)
  local payload = {}
  if type(rec) == "table" then
    local downloaded_count = 0
    for _, item in ipairs(rec.downloads or {}) do
      if item.downloaded == true then downloaded_count = downloaded_count + 1 end
    end
    payload.record_id = rec.id
    payload.record_label = tostring(rec.label or rec.label_text or "")
    payload.record_state = tostring(rec.state or "")
    payload.network_key = tostring(rec.network_key or "")
    payload.failed_stage = tostring(rec.failed_stage or "")
    payload.input_mode = tostring(rec.input_mode or rec.mode or "")
    payload.track_name = tostring(rec.track_name or "")
    payload.track_position = rec.track_position
    payload.start_time = rec.start_time
    payload.end_time = rec.end_time
    payload.duration_sec = rec.duration
    payload.region_name = tostring(rec.region_name or "")
    payload.region_number = rec.region_number
    payload.model_sep_type = tostring(rec.model_sep_type or "")
    payload.model_name = tostring(rec.model_name or "")
    payload.field_values = rec.field_values
    payload.output_format_name = tostring(rec.output_format_name or "")
    payload.input_path = tostring(rec.input_path or "")
    payload.input_size = rec.input_path and Files.file_size(rec.input_path) or nil
    payload.render_source_path = tostring(rec.render_source_path or "")
    payload.render_source_size = rec.render_source_path and Files.file_size(rec.render_source_path) or nil
    payload.upload_staging = rec.upload_staging
    payload.job_hash = tostring(rec.job_hash or "")
    payload.server_status = tostring(rec.server_status or "")
    payload.raw_server_status = tostring(rec.raw_server_status or "")
    payload.status_source = tostring(rec.status_source or "")
    payload.status_warning = tostring(rec.status_warning or "")
    payload.queue_count = rec.queue_count
    payload.current_order = rec.current_order
    payload.finished_chunks = rec.finished_chunks
    payload.all_chunks = rec.all_chunks
    payload.download_index = rec.download_index
    payload.download_count = #(rec.downloads or {})
    payload.downloaded_count = downloaded_count
    payload.downloads = TelemetryBridge.downloads_payload(rec)
    payload.last_http_code = rec.last_http_code
    payload.network_job_id = tostring(rec.network_job_id or "")
    payload.network_job_label = tostring(rec.network_job_label or "")
    payload.cancel_requested = rec.cancel_requested == true
    payload.cancel_reconcile_pending = rec.cancel_reconcile_pending == true
    payload.cancel_non_retriable = rec.cancel_non_retriable == true
    payload.remote_removed = rec.remote_removed == true
    payload.imported = rec.imported == true
    payload.error_text = TelemetryBridge.safe_string(rec.error_text or "")
    payload.last_message = TelemetryBridge.safe_string(rec.last_message or "")
  end
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  return payload
end

function TelemetryBridge.begin_record_stage(rec, stage, extra)
  if type(rec) ~= "table" then return end
  local operation = tostring(extra and extra.operation or TelemetryBridge.operation_from_stage(stage))
  rec._telemetry_stage = tostring(stage or "")
  rec._telemetry_stage_operation = operation
  rec._telemetry_stage_started_at = TelemetryBridge.now()
  rec._telemetry_stage_completed = false
  TelemetryBridge.operation_started(operation, TelemetryBridge.record_payload(rec, extra))
end

function TelemetryBridge.finish_record_stage_ok(rec, stage, extra)
  if type(rec) ~= "table" or rec._telemetry_stage_completed == true then return end
  if stage and rec._telemetry_stage ~= tostring(stage) then return end
  rec._telemetry_stage_completed = true
  local payload = TelemetryBridge.record_payload(rec, extra)
  payload.duration_ms = payload.duration_ms or TelemetryBridge.duration_ms(rec._telemetry_stage_started_at)
  TelemetryBridge.operation_completed(rec._telemetry_stage_operation or TelemetryBridge.operation_from_stage(stage), payload)
end

function TelemetryBridge.finish_record_stage_failed(rec, err_text, stage, extra, event_name)
  if type(rec) ~= "table" or rec._telemetry_stage_completed == true then return end
  if stage and rec._telemetry_stage ~= tostring(stage) then return end
  rec._telemetry_stage_completed = true
  local payload = TelemetryBridge.record_payload(rec, extra)
  payload.safe_message = TelemetryBridge.safe_string(err_text or rec.error_text or "")
  payload.error_code = tostring((stage or rec._telemetry_stage or "MVSEP_OPERATION") .. "_FAILED"):upper()
  payload.duration_ms = payload.duration_ms or TelemetryBridge.duration_ms(rec._telemetry_stage_started_at)
  local failure_event = event_name
  if failure_event == nil and tostring(stage or rec._telemetry_stage or "") == "render" then
    failure_event = "render_failed"
  end
  TelemetryBridge.operation_failed(
    rec._telemetry_stage_operation or TelemetryBridge.operation_from_stage(stage),
    payload,
    nil,
    failure_event or "operation_failed"
  )
end

function TelemetryBridge.request_endpoint_fields(req)
  if type(req) ~= "table" then return {} end
  local endpoint_path = tostring(req.backend_route or "")
  return {
    request_method = tostring(req.method or ""),
    request_kind = tostring(req.kind or ""),
    request_label = tostring(req.label or ""),
    endpoint_path = endpoint_path,
    download_path = tostring(req.download_path or ""),
    follow_redirects = req.follow_redirects == true
  }
end

function TelemetryBridge.request_payload_fields(req)
  local payload = {}
  if type(req) ~= "table" then return payload end
  if type(req.form_fields) == "table" then
    local fields = {}
    for _, field in ipairs(req.form_fields) do
      if type(field) == "table" then
        local field_name = tostring(field.name or "")
        local row = {
          name = telemetry_should_redact_key(field_name) and "redacted_secret_field" or field_name
        }
        if field.filepath then
          row.filepath = tostring(field.filepath or "")
          row.file_size = Files.file_size(field.filepath)
          row.content_type = tostring(field.content_type or "")
        elseif field.value ~= nil then
          if telemetry_should_redact_key(field_name) then
            row.value_present = true
            row.value = "[REDACTED]"
            row.redacted = true
          else
            row.value = TelemetryBridge.safe_string(field.value)
          end
        end
        fields[#fields + 1] = row
      end
    end
    payload.form_field_count = #fields
    payload.form_fields = fields
  end
  return payload
end

function TelemetryBridge.network_request_failed(req, result, job, track_label)
  local payload = TelemetryBridge.request_endpoint_fields(req)
  local request_payload = TelemetryBridge.request_payload_fields(req)
  for k, v in pairs(request_payload) do payload[k] = v end
  payload.operation = "mvsep_network_request"
  payload.status = "failed"
  payload.request_label = tostring(track_label or payload.request_label or "")
  payload.job_id = tostring(job and job.id or result and result.job_id or "")
  payload.http_code = result and result.http_code or nil
  payload.curl_exitcode = result and result.exitcode or nil
  payload.safe_message = TelemetryBridge.safe_string((result and (result.err or result.err_msg or result.err_txt)) or "curl request failed")
  payload.timed_out = result and result.timed_out == true
  payload.total_time = result and result.total_time or nil
  payload.size_upload = result and result.size_upload or nil
  payload.size_download = result and result.size_download or nil
  TelemetryBridge.emit_operation_event("network_request_failed", "mvsep_network_request", "failed", payload, {
    priority = "error",
    event_level = "error",
    request_label = payload.request_label,
    http_code = payload.http_code,
    curl_exitcode = payload.curl_exitcode
  })
end

function TelemetryBridge.poll_status_transition(rec, payload, effective_status, kind)
  local output_files = type(payload) == "table" and payload.output_files or {}
  local signature = table.concat({
    tostring(rec and rec.id or ""),
    tostring(rec and rec.job_hash or ""),
    tostring(kind or ""),
    tostring(effective_status or ""),
    tostring(payload and payload.raw_status or ""),
    tostring(payload and payload.queue_count or ""),
    tostring(payload and payload.current_order or ""),
    tostring(payload and payload.finished_chunks or ""),
    tostring(payload and payload.all_chunks or ""),
    tostring(#output_files)
  }, "|")
  local now_t = TelemetryBridge.now()
  if signature == rec._telemetry_last_poll_signature
      and rec._telemetry_last_poll_event_at
      and (now_t - rec._telemetry_last_poll_event_at) < 60
      and kind ~= "done"
      and kind ~= "failed" then
    return
  end
  rec._telemetry_last_poll_signature = signature
  rec._telemetry_last_poll_event_at = now_t
  local event_payload = TelemetryBridge.record_payload(rec, {
    poll_transition_kind = tostring(kind or "status"),
    effective_status = tostring(effective_status or ""),
    raw_success = payload and payload.raw_success,
    raw_status = payload and payload.raw_status,
    status_source = payload and payload.status_source,
    status_warning = payload and payload.status_warning,
    status_message = TelemetryBridge.safe_string(payload and payload.message or ""),
    http_code = payload and payload.http_code or nil,
    output_file_count = #output_files
  })
  local event_name = kind == "failed" and "operation_failed" or "operation_completed"
  if event_name == "operation_failed" then
    TelemetryBridge.operation_failed("mvsep_poll_status_transition", event_payload)
  else
    TelemetryBridge.operation_completed("mvsep_poll_status_transition", event_payload)
  end
end

function TelemetryBridge.button_clicked(button_id, label)
  return TelemetryBridge.safe_event("button_clicked", {
    operation = "mvsep_ui",
    status = "clicked",
    button_id = tostring(button_id or ""),
    button_label = tostring(label or "")
  }, {
    operation = "mvsep_ui",
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
      return string.format(t("flushing, %s"), Util.clip_text(progress, 32))
    end
    return t("flushing")
  end
  if Util.trim(desc.last_error or "") ~= "" or Util.trim(desc.last_backend_error or "") ~= "" then
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
  if Util.trim(desc.last_error or "") ~= "" or Util.trim(desc.last_backend_error or "") ~= "" then
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
    reason = reason or "mvsep_manual",
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

send_telemetry_closed_event = TelemetryBridge.send_closed_event

local function current_main_window_title_text()
  return t("MVSEP via Neurocast") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION
end

local function current_status_window_title_text()
  return t("Status") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION
end

local function current_main_window_label()
  return current_main_window_title_text() .. "##mvsep_tool_main_window"
end

local function current_status_window_label()
  return current_status_window_title_text() .. "##mvsep_status_window"
end

local debug_log

local MAIN_WINDOW_MIN_EXPANDED_HEIGHT = 64
local main_window_runtime = {
  force_expand_on_start = true,
  was_visible = nil,
  expanded_w = nil,
  expanded_h = nil,
  last_visible_x = nil,
  last_visible_y = nil
}

local function geometry_number(value)
  local numeric = tonumber(value)
  if numeric == nil then return "unavailable" end
  return string.format("%.1f", numeric)
end

local function prepare_main_window_before_begin()
  if main_window_runtime.force_expand_on_start then
    ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
    main_window_runtime.force_expand_on_start = false
  end

  local has_saved_size =
    tonumber(main_window_runtime.expanded_w) ~= nil and
    tonumber(main_window_runtime.expanded_h) ~= nil
  if main_window_runtime.was_visible == false and has_saved_size then
    ImGui.SetNextWindowSize(
      ctx,
      main_window_runtime.expanded_w,
      main_window_runtime.expanded_h,
      ImGui.Cond_Always
    )
  end
end

local function observe_main_window_after_begin(visible)
  local previous_visible = main_window_runtime.was_visible
  if visible then
    local window_x, window_y = ImGui.GetWindowPos(ctx)
    local window_w, window_h = ImGui.GetWindowSize(ctx)
    if previous_visible == false then
      debug_log(
        "[main-window-collapse] phase=expanded actual={x=" .. geometry_number(window_x) ..
          " y=" .. geometry_number(window_y) ..
          " w=" .. geometry_number(window_w) ..
          " h=" .. geometry_number(window_h) ..
          "} saved_before={w=" .. geometry_number(main_window_runtime.expanded_w) ..
          " h=" .. geometry_number(main_window_runtime.expanded_h) .. "}",
        0
      )
    end
    if tonumber(window_h) ~= nil and window_h >= MAIN_WINDOW_MIN_EXPANDED_HEIGHT then
      main_window_runtime.expanded_w = window_w
      main_window_runtime.expanded_h = window_h
      main_window_runtime.last_visible_x = window_x
      main_window_runtime.last_visible_y = window_y
    end
  elseif previous_visible ~= false then
    debug_log(
      "[main-window-collapse] phase=collapsed saved={w=" ..
        geometry_number(main_window_runtime.expanded_w) ..
        " h=" .. geometry_number(main_window_runtime.expanded_h) ..
        "} last_visible_pos={x=" .. geometry_number(main_window_runtime.last_visible_x) ..
        " y=" .. geometry_number(main_window_runtime.last_visible_y) .. "}",
      0
    )
  end
  main_window_runtime.was_visible = visible == true
end

local function push_warning(text)
  local msg = Util.trim(text)
  if msg == "" then return end
  S.warnings[#S.warnings + 1] = msg
end

local function push_warning_once(text)
  local msg = Util.trim(text)
  if msg == "" then return end
  for _, item in ipairs(S.warnings) do
    if item == msg then return end
  end
  push_warning(msg)
end

local function set_last_error(err_text, status_text)
  S.last_api_error = tostring(err_text or "")
  if S.last_api_error ~= "" then
    S.status_text = tostring(status_text or S.last_api_error)
  end
end

debug_log = function(message, importance)
  local msg = Util.trim(message)
  if msg == "" then return end
  Util.msg("[mvsep] " .. msg, tonumber(importance) or 0)
end

local function refresh_project_relative_paths()
  S.paths = MVSepReaper.create_runtime_paths({
    project_folder_name = CFG.project_folder_name
  })
  CFG.tmp_dir = S.paths.tmp_dir
  return S.paths
end

refresh_project_relative_paths()
local startup_runtime_dirs_ok, startup_runtime_dirs_err = MVSepReaper.ensure_runtime_dirs(S.paths)
if not startup_runtime_dirs_ok then
  push_warning_once(startup_runtime_dirs_err)
end
debug_log(
  "startup version=" .. tostring(SCRIPT_VERSION) ..
  " tmp_dir=" .. tostring(S.paths and S.paths.tmp_dir or "") ..
  " debug_log=runtime_diagnostics",
  0
)
Cleanup.init(S, CFG)
Curl.init(S, CFG)
Jobs.init(S, CFG)

local function persist_plain(key, value)
  local ok_set, err = Util.extstate_set(EXTSTATE.section, key, tostring(value or ""), true)
  if not ok_set then
    Util.msg("Failed to persist " .. tostring(key) .. ": " .. tostring(err), 2)
  end
end

local function load_plain(key)
  local value, err = Util.extstate_get(EXTSTATE.section, key)
  if err then
    Util.msg("Failed to load " .. tostring(key) .. ": " .. tostring(err), 2)
    return nil
  end
  return value
end

local function persist_auth_email(value)
  local email = Util.trim(value)
  if email == "" then
    Util.extstate_delete(EXTSTATE.auth_section, EXTSTATE.auth_email, true)
    return
  end
  local ok_set, err = Util.extstate_set_camo(EXTSTATE.auth_section, EXTSTATE.auth_email, email, true)
  if not ok_set then Util.msg("Failed to persist Studio email: " .. tostring(err), 2) end
end

local function persist_auth_backend(value)
  local base_url = Util.trim(value)
  if base_url == "" then
    Util.extstate_delete(EXTSTATE.auth_section, EXTSTATE.auth_backend, true)
    return
  end
  local ok_set, err = Util.extstate_set_camo(EXTSTATE.auth_section, EXTSTATE.auth_backend, base_url, true)
  if not ok_set then Util.msg("Failed to persist Studio backend: " .. tostring(err), 2) end
end

local function load_auth_identity_on_startup()
  local email, email_err = Util.extstate_get_camo(EXTSTATE.auth_section, EXTSTATE.auth_email)
  if email_err then Util.msg("Failed to load Studio email: " .. tostring(email_err), 2) end
  S.email = Util.trim(email or "")
end

local function persist_locale(locale)
  local normalized = parse_runtime_locale(locale)
  if not normalized then
    Util.extstate_delete(EXTSTATE.section, EXTSTATE.ui_locale, true)
    return
  end
  persist_plain(EXTSTATE.ui_locale, normalized)
end

local function persist_show_status_window(value)
  persist_plain(EXTSTATE.show_status_window, value and "1" or "0")
end

local function load_show_status_window_on_startup()
  local stored = load_plain(EXTSTATE.show_status_window)
  if stored == "1" then S.show_status_window = true end
  if stored == "0" then S.show_status_window = false end
end

local function load_locale_on_startup()
  local stored = load_plain(EXTSTATE.ui_locale)
  set_active_runtime_locale(stored or "eng")
end

local function persist_boolean(key, value)
  persist_plain(key, value and "1" or "0")
end

local function load_boolean(key, default_value)
  local value = load_plain(key)
  if value == "1" then return true end
  if value == "0" then return false end
  return default_value
end

local function persist_json(key, value)
  local ok, encoded = pcall(json.encode, value)
  if not ok then
    Util.msg("Failed to encode JSON for " .. tostring(key) .. ": " .. tostring(encoded), 2)
    return
  end
  persist_plain(key, encoded)
end

local function load_json(key)
  local raw = load_plain(key)
  if raw == nil or raw == "" then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok then
    Util.msg("Failed to decode JSON for " .. tostring(key) .. ": " .. tostring(decoded), 2)
    return nil
  end
  return decoded
end

local function copy_favorites_map(source)
  local out = {}
  for key, value in pairs(source or {}) do
    if value == true then
      out[tostring(key)] = true
    end
  end
  return out
end

local function load_ui_state_on_startup()
  S.input_mode = load_plain(EXTSTATE.input_mode) or S.input_mode
  S.free_mode = load_boolean(EXTSTATE.free_mode, S.free_mode)
  S.region_concurrency = tonumber(load_plain(EXTSTATE.region_concurrency) or S.region_concurrency) or 1
  S.output_format_name = load_plain(EXTSTATE.output_format_name) or S.output_format_name
  S.filter_text = load_plain(EXTSTATE.filter_text) or ""
  S.favorites_only = load_boolean(EXTSTATE.favorites_only, false)
  S.selected_model_sep_type = load_plain(EXTSTATE.selected_model_sep_type) or S.selected_model_sep_type

  local loaded_favorites = load_json(EXTSTATE.favorites_json)
  if type(loaded_favorites) == "table" then
    S.favorites = copy_favorites_map(loaded_favorites)
  else
    S.favorites = copy_favorites_map(MVSepAPI.DEFAULT_FAVORITES)
  end

  if S.region_concurrency < 1 then S.region_concurrency = 1 end
  if S.region_concurrency > CFG.max_paid_concurrency then
    S.region_concurrency = CFG.max_paid_concurrency
  end
  if S.free_mode then
    S.region_concurrency = 1
  end
end

local function save_remembered_model_options()
  if not S.paths then return false end
  local ok_dirs, dirs_err = MVSepReaper.ensure_settings_dir(S.paths)
  if not ok_dirs then
    push_warning_once(dirs_err)
    return false
  end

  local settings = {
    schema_version = MVSepModelOptions.SCHEMA_VERSION,
    models = S.remembered_model_field_values
  }
  local ok_encode, encoded = pcall(json.encode, settings)
  if not ok_encode then
    push_warning_once(t("Failed to encode remembered MVSEP model options."))
    return false
  end

  local target = S.paths.settings_model_options_file
  local temp = target .. ".tmp"
  local backup = target .. ".bak"
  os.remove(temp)
  local write_ok, write_err = Files.write_file(temp, encoded .. "\n")
  if not write_ok then
    push_warning_once(string.format(t("Failed to write remembered MVSEP model options: %s"), tostring(write_err)))
    return false
  end

  local had_existing = r.file_exists(target) == true
  if had_existing then
    os.remove(backup)
    local moved_old, move_old_err = os.rename(target, backup)
    if not moved_old then
      os.remove(temp)
      push_warning_once(string.format(t("Failed to prepare remembered MVSEP model options for saving: %s"), tostring(move_old_err)))
      return false
    end
  end

  local moved_new, move_new_err = os.rename(temp, target)
  if not moved_new then
    if had_existing then os.rename(backup, target) end
    os.remove(temp)
    push_warning_once(string.format(t("Failed to save remembered MVSEP model options: %s"), tostring(move_new_err)))
    return false
  end
  if had_existing then os.remove(backup) end
  return true
end

local function load_remembered_model_options_on_startup()
  S.remembered_model_field_values = {}
  if not S.paths or r.file_exists(S.paths.settings_model_options_file) ~= true then
    return
  end
  local text, read_err = Files.slurp_with_cap(S.paths.settings_model_options_file, 1024 * 1024)
  if not text then
    push_warning_once(string.format(t("Failed to read remembered MVSEP model options: %s"), tostring(read_err)))
    return
  end
  local settings, settings_err = MVSepModelOptions.decode_json(json, text)
  if settings_err then
    Util.msg("Failed to load remembered MVSEP model options: " .. tostring(settings_err), 2)
    push_warning_once(string.format(t("Remembered MVSEP model options were ignored: %s"), tostring(settings_err)))
    return
  end
  S.remembered_model_field_values = settings.models
end

local function save_catalog_cache(catalog)
  if type(catalog) ~= "table" or not S.paths then return end
  local ok_dirs, dirs_err = MVSepReaper.ensure_settings_dir(S.paths)
  if not ok_dirs then
    push_warning_once(dirs_err)
    return
  end
  local ok, encoded = pcall(json.encode, catalog)
  if not ok then
    push_warning_once(t("Failed to encode MVSEP catalog cache."))
    return
  end
  local write_ok, write_err = Files.write_file(S.paths.cache_file, encoded .. "\n")
  if not write_ok then
    push_warning_once(string.format(t("Failed to write MVSEP catalog cache: %s"), tostring(write_err)))
  end
end

local function load_catalog_from_cache()
  if not S.paths or not r.file_exists(S.paths.cache_file) then
    return false
  end
  local text, read_err = Files.slurp_with_cap(S.paths.cache_file, 8 * 1024 * 1024)
  if not text then
    push_warning_once(string.format(t("Failed to read MVSEP catalog cache: %s"), tostring(read_err)))
    return false
  end
  local ok, decoded = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" then
    push_warning_once(t("Failed to decode MVSEP catalog cache."))
    return false
  end
  S.catalog = decoded
  S.catalog_loaded_from_cache = true
  return true
end

local refresh_catalog
local AUTH_CLIENT = nil
local AUTH_CLIENT_BASE_URL = nil
local MVSEP_CLIENT = nil
local MVSEP_CLIENT_BASE_URL = nil
local AUTH_REFRESH_GATE = NeurocastAuth.create_refresh_gate()
local Auth = {}
local Backend = {}
local make_tracked_curl_submit

function Backend.active_base_url()
  local candidate = Util.trim(S.backend_base_url_override or "")
  if candidate == "" then candidate = CFG.backend_base_url end
  local resolved = MVSepViaNeurocast.resolve_base_url(candidate)
  return resolved or CFG.backend_base_url
end

function Backend.reset_clients()
  AUTH_CLIENT = nil
  AUTH_CLIENT_BASE_URL = nil
  MVSEP_CLIENT = nil
  MVSEP_CLIENT_BASE_URL = nil
end

function Auth.client()
  local base_url = Backend.active_base_url()
  if not AUTH_CLIENT or AUTH_CLIENT_BASE_URL ~= base_url then
    AUTH_CLIENT = NeurocastAuth.create_client({
      base_url = base_url,
      ext_section = EXTSTATE.auth_section,
      ext_refresh_key = EXTSTATE.auth_refresh,
      remember_refresh = S.remember_login == true
    })
    AUTH_CLIENT_BASE_URL = base_url
  end
  AUTH_CLIENT.set_tokens(S.access_token or "", S.refresh_token or "")
  return AUTH_CLIENT
end

function Backend.client()
  local base_url = Backend.active_base_url()
  if not MVSEP_CLIENT or MVSEP_CLIENT_BASE_URL ~= base_url then
    MVSEP_CLIENT = MVSepViaNeurocast.create_client({
      base_url = base_url,
      access_token_fn = function() return S.access_token or "" end,
      curl_submit_fn = make_tracked_curl_submit("MVSEP via Neurocast")
    })
    MVSEP_CLIENT_BASE_URL = base_url
  end
  return MVSEP_CLIENT
end

function Backend.set_development_enabled(enabled)
  local next_value = enabled == true and CFG.backend_development_url or ""
  if next_value == S.backend_base_url_override then return true end
  S.backend_base_url_override = next_value
  S.access_token = ""
  S.refresh_token = ""
  S.has_stored_refresh = false
  S.auth_status = t("Backend changed; sign in for this backend.")
  Backend.reset_clients()
  return true
end

function Auth.apply_token_payload(payload)
  S.access_token = tostring(payload and payload.access_token or "")
  S.refresh_token = tostring(payload and payload.refresh_token or "")
  S.password = ""
  S.has_stored_refresh = S.remember_login == true and S.refresh_token ~= ""
  Auth.client().set_tokens(S.access_token, S.refresh_token)
  if S.has_stored_refresh then
    persist_auth_backend(Backend.active_base_url())
  else
    persist_auth_backend("")
  end
end

function Auth.clear_runtime_tokens()
  S.access_token = ""
  S.refresh_token = ""
  S.password = ""
  if AUTH_CLIENT then AUTH_CLIENT.clear_runtime_tokens() end
end

function Auth.forget_stored_login()
  local client = Auth.client()
  client.forget_refresh_token()
  persist_auth_backend("")
  Auth.clear_runtime_tokens()
  S.has_stored_refresh = false
  S.auth_status = t("Stored login forgotten.")
  return true
end

function Auth.load_stored_login()
  local backend, backend_err = Util.extstate_get_camo(EXTSTATE.auth_section, EXTSTATE.auth_backend)
  if backend_err then Util.msg("Failed to load stored Studio backend: " .. tostring(backend_err), 2) end
  backend = Util.trim(backend or "")
  if backend == CFG.backend_development_url then
    S.backend_base_url_override = CFG.backend_development_url
    Backend.reset_clients()
  elseif backend == CFG.backend_base_url then
    S.backend_base_url_override = ""
    Backend.reset_clients()
  end
  local token, token_err = Auth.client().load_refresh_token()
  if token_err then Util.msg("Failed to load stored Studio refresh token: " .. tostring(token_err), 2) end
  if Util.trim(token or "") == "" then
    S.has_stored_refresh = false
    S.auth_status = t("Signed out")
    return false
  end
  if backend ~= Backend.active_base_url() then
    Auth.client().forget_refresh_token()
    persist_auth_backend("")
    S.has_stored_refresh = false
    S.auth_status = t("Stored login belonged to another backend and was cleared.")
    return false
  end
  S.refresh_token = token
  S.has_stored_refresh = true
  S.auth_status = t("Stored login available; refresh required.")
  return true
end

local function auth_submit_opts()
  return {
    read_body = true,
    keep_output = false,
    retain_artifacts = false,
    early_secret_cleanup = true
  }
end

function Auth.submit_login()
  local email = Util.trim(S.email or "")
  if email == "" or tostring(S.password or "") == "" then
    return false, t("Email and password are required.")
  end
  if S.auth_request_inflight then return false, t("An authentication request is already running.") end
  S.auth_request_inflight = true
  S.auth_status = t("Signing in...")
  persist_auth_email(email)
  Backend.reset_clients()
  local job, err = Auth.client().submit_login(email, S.password, function(payload)
    S.auth_request_inflight = false
    if payload and payload.ok then
      Auth.apply_token_payload(payload)
      S.auth_status = t("Signed in.")
      if type(refresh_catalog) == "function" then refresh_catalog() end
      return
    end
    S.password = ""
    S.auth_status = string.format(
      t("Sign-in failed: %s"),
      tostring(payload and (payload.api_error or payload.error) or t("unknown error"))
    )
  end, auth_submit_opts())
  if not job then
    S.auth_request_inflight = false
    S.password = ""
    S.auth_status = string.format(t("Sign-in could not start: %s"), tostring(err or t("unknown error")))
    return false, err
  end
  return true
end

function Auth.request_refresh(on_done)
  if S.auth_request_inflight then return false, t("An authentication request is already running.") end
  S.auth_request_inflight = true
  S.auth_status = t("Refreshing login...")
  local job, err = Auth.client().submit_refresh(function(payload)
    S.auth_request_inflight = false
    if payload and payload.ok then
      Auth.apply_token_payload(payload)
      S.auth_status = t("Signed in (refreshed).")
      if type(on_done) == "function" then on_done(true, payload) end
      return
    end
    local status = tonumber(payload and payload.http_code)
    if NeurocastAuth.is_invalid_refresh_http_status(status) then
      Auth.client().forget_refresh_token()
      persist_auth_backend("")
      Auth.clear_runtime_tokens()
      S.has_stored_refresh = false
      S.auth_status = t("Stored login is invalid and was cleared; email was preserved.")
    else
      S.auth_status = string.format(
        t("Login refresh failed: %s"),
        tostring(payload and (payload.api_error or payload.error) or t("unknown error"))
      )
    end
    if type(on_done) == "function" then on_done(false, payload) end
  end, auth_submit_opts())
  if not job then
    S.auth_request_inflight = false
    S.auth_status = string.format(t("Login refresh could not start: %s"), tostring(err or t("unknown error")))
    if type(on_done) == "function" then on_done(false, { error = err }) end
    return false, err
  end
  return true
end

function Auth.queue_refresh(on_success, on_failure)
  local queued, queue_err = AUTH_REFRESH_GATE.request(
    function(done)
      return Auth.request_refresh(function(ok, payload) done(ok, payload) end)
    end,
    function(payload)
      if type(on_success) == "function" then on_success(payload) end
    end,
    function(payload)
      if type(on_failure) == "function" then on_failure(payload) end
    end
  )
  if not queued and AUTH_REFRESH_GATE.is_in_flight() ~= true then
    return false, queue_err or t("Studio login refresh could not be started.")
  end
  return true
end

function Auth.refresh_after_401(rec, resubmit_fn, on_failure)
  if type(rec) ~= "table" or type(resubmit_fn) ~= "function" then
    return false, t("Request cannot be rebuilt after authentication refresh.")
  end
  if rec._auth_refresh_used_once == true then
    return false, t("Authentication refresh was already used once for this request.")
  end
  rec._auth_refresh_used_once = true
  return Auth.queue_refresh(
    function()
      local ok_submit, submit_err = resubmit_fn()
      if not ok_submit and type(on_failure) == "function" then
        on_failure({ error = submit_err or t("Request rebuild failed after refresh.") })
      end
    end,
    on_failure
  )
end

function Auth.refresh_proactively_if_due(rec, resubmit_fn, on_failure)
  if type(rec) ~= "table" or type(resubmit_fn) ~= "function" then return false end
  local timing = Auth.client().access_token_refresh_status(S.access_token)
  if not timing or timing.refresh_due ~= true then return false end
  local queued, queue_err = Auth.queue_refresh(
    function()
      local ok_submit, submit_err = resubmit_fn()
      if not ok_submit and type(on_failure) == "function" then
        on_failure({ error = submit_err or t("Request rebuild failed after proactive refresh.") })
      end
    end,
    on_failure
  )
  if not queued and type(on_failure) == "function" then on_failure({ error = queue_err }) end
  return queued == true
end

function Auth.submit_logout()
  if S.auth_request_inflight then return false, t("An authentication request is already running.") end
  if Util.trim(S.access_token or "") == "" or Util.trim(S.refresh_token or "") == "" then
    Auth.forget_stored_login()
    return true
  end
  S.auth_request_inflight = true
  S.auth_status = t("Signing out...")
  local job, err = Auth.client().submit_logout(function(payload)
    S.auth_request_inflight = false
    if payload and payload.ok then
      Auth.clear_runtime_tokens()
      persist_auth_backend("")
      S.has_stored_refresh = false
      S.auth_status = t("Signed out.")
    else
      S.auth_status = string.format(
        t("Sign-out failed: %s"),
        tostring(payload and (payload.api_error or payload.error) or t("unknown error"))
      )
    end
  end, auth_submit_opts())
  if not job then
    S.auth_request_inflight = false
    S.auth_status = string.format(t("Sign-out could not start: %s"), tostring(err or t("unknown error")))
    return false, err
  end
  return true
end

local function diagnostic_result(req, result)
  local safe_error = MVSepAPI.parse_standard_backend_error(
    result and result.body or nil,
    result and result.http_code or nil,
    result and result.headers_txt or nil
  )
  return {
    ok = result and result.ok == true,
    http_code = result and result.http_code or nil,
    exitcode = result and result.exitcode or nil,
    body = json.encode({
      status = safe_error.http_status,
      code = safe_error.code,
      failure_type = safe_error.failure_type,
      mutation_outcome = safe_error.mutation_outcome,
      upstream_status = safe_error.upstream_status,
      correlation_id = safe_error.correlation_id,
      message = safe_error.message
    }),
    headers_txt = safe_error.correlation_id and ("x-correlation-id: " .. tostring(safe_error.correlation_id)) or "",
    err = TelemetryBridge.safe_string(result and result.err or safe_error.message),
    total_time = result and result.total_time or nil,
    size_upload = result and result.size_upload or nil,
    size_download = result and result.size_download or nil,
    timed_out = result and result.timed_out == true
  }
end

make_tracked_curl_submit = function(track_label)
  return function(req, on_done, submit_opts)
    local options = type(submit_opts) == "table" and submit_opts or {}
    local rec = options.auth_rec
    local label = req and req.label or "request"

    local function auth_failure(payload, original_result)
      local message = tostring(payload and (payload.api_error or payload.error) or t("Studio login refresh failed."))
      if type(on_done) == "function" then
        on_done({
          ok = false,
          err = message,
          http_code = tonumber(payload and payload.http_code) or tonumber(original_result and original_result.http_code),
          body = "",
          headers_txt = "",
          exitcode = tonumber(original_result and original_result.exitcode),
          request_not_sent = true
        })
      end
    end

    local can_refresh =
      type(rec) == "table" and
      type(rec._retry_submit) == "function" and
      req and req.backend_auth == "studio"

    if can_refresh and Auth.refresh_proactively_if_due(rec, rec._retry_submit, function(payload)
      auth_failure(payload, nil)
    end) then
      return {
        id = "mvsep_auth_wait_" .. tostring(rec.id or rec.network_key or rec),
        label = label,
        phase = "auth_refresh"
      }
    end

    debug_log(
      "curl submit label=" .. tostring(label) ..
      " route=" .. tostring(req and req.backend_route or "") ..
      " method=" .. tostring(req and req.method or ""),
      0
    )
    local job, err = Curl.curl_submit(req, function(result, job_ref)
      local safe_result = diagnostic_result(req, result)
      pcall(Curl.update_last_curl_state, safe_result, job_ref, track_label or label or t("Request"))
      debug_log(
        "curl done label=" .. tostring(label) ..
        " route=" .. tostring(req and req.backend_route or "") ..
        " ok=" .. tostring(result and result.ok) ..
        " http=" .. tostring(result and result.http_code or "") ..
        " exit=" .. tostring(result and result.exitcode or ""),
        (result and result.ok) and 0 or 2
      )

      if can_refresh
          and tonumber(result and result.http_code) == 401
          and rec._auth_refresh_used_once ~= true then
        TelemetryBridge.network_request_failed(req, safe_result, job_ref, label)
        local handled = Auth.refresh_after_401(rec, rec._retry_submit, function(payload)
          auth_failure(payload, result)
        end)
        if handled then return end
      end

      if result and result.ok ~= true then
        TelemetryBridge.network_request_failed(req, safe_result, job_ref, label)
      end
      if type(on_done) == "function" then on_done(result, job_ref) end
    end, options)

    if not job then
      local safe_result = diagnostic_result(req, {
        ok = false,
        err = tostring(err or "request submission failed")
      })
      TelemetryBridge.network_request_failed(req, safe_result, nil, label)
    end
    return job, err
  end
end

local mvsep_client = setmetatable({}, {
  __index = function(_, key)
    local member = Backend.client()[key]
    if type(member) ~= "function" then return member end
    return function(...)
      return member(...)
    end
  end
})
local function UI_button_clicked(id, label, cooldown_override, ctx_override)
  local ctx_ref = ctx_override or ctx
  local key = tostring(id or label)
  local visible_label = tostring(label or "")
  local imgui_label = visible_label
  if key ~= "" then
    imgui_label = visible_label .. "##" .. key
  end
  local cooldown = tonumber(cooldown_override) or CFG.button_cooldown_sec or 0
  local now_t = Jobs.now()
  local last = button_last_click_at[key] or 0
  local remaining = cooldown - (now_t - last)
  if remaining < 0 then remaining = 0 end
  if remaining > 0 then ImGui.BeginDisabled(ctx_ref, true) end
  local clicked = ImGui.Button(ctx_ref, imgui_label)
  if remaining > 0 then ImGui.EndDisabled(ctx_ref) end
  if clicked and remaining <= 0 then
    button_last_click_at[key] = now_t
    return true
  end
  return false
end

local function selected_model()
  return MVSepAPI.find_algorithm_by_sep_type(S.catalog, S.selected_model_sep_type)
end

local function set_selected_model(sep_type)
  S.selected_model_sep_type = tostring(sep_type or "")
  persist_plain(EXTSTATE.selected_model_sep_type, S.selected_model_sep_type)
end

local function ensure_selected_model()
  local algorithms = type(S.catalog) == "table" and S.catalog.algorithms or nil
  if type(algorithms) ~= "table" or #algorithms == 0 then
    return nil
  end

  local current = selected_model()
  if current then return current end

  local fallback = MVSepAPI.find_algorithm_by_sep_type(S.catalog, "56") or algorithms[1]
  if fallback and fallback.sep_type then
    set_selected_model(fallback.sep_type)
  end
  return selected_model()
end

local function same_field_values(left, right)
  for key, value in pairs(left or {}) do
    if tostring(right and right[key] or "") ~= tostring(value) then return false end
  end
  for key, value in pairs(right or {}) do
    if tostring(left and left[key] or "") ~= tostring(value) then return false end
  end
  return true
end

local function remember_active_model_field_values(only_if_already_remembered)
  local model = selected_model()
  local sep_type = model and tostring(model.sep_type or "") or ""
  if sep_type == "" then return false end
  if only_if_already_remembered and type(S.remembered_model_field_values[sep_type]) ~= "table" then
    return true
  end
  S.remembered_model_field_values[sep_type] = MVSepModelOptions.copy_values(S.model_field_values)
  return save_remembered_model_options()
end

local function reconcile_selected_model()
  local model = ensure_selected_model()
  if not model then
    S.model_field_values = {}
    return nil
  end

  local sep_type = tostring(model.sep_type or "")
  local prior = S.remembered_model_field_values[sep_type]
  local active, reconciled = MVSepModelOptions.reconcile_model(model, prior)
  S.model_field_values = active
  if type(prior) == "table" then
    S.remembered_model_field_values[sep_type] = reconciled
    if not same_field_values(prior, reconciled) then
      save_remembered_model_options()
    end
  end
  return model
end

local function reset_remembered_model_options()
  local target = S.paths and S.paths.settings_model_options_file or ""
  if target ~= "" and r.file_exists(target) == true then
    local removed, remove_err = os.remove(target)
    if not removed then
      push_warning_once(string.format(t("Failed to reset remembered MVSEP model options: %s"), tostring(remove_err)))
      return false
    end
  end
  S.remembered_model_field_values = {}
  local model = ensure_selected_model()
  local active = MVSepModelOptions.reconcile_model(model, {})
  S.model_field_values = active
  return true
end

local function model_display_description(model)
  if type(model) ~= "table" then return "" end
  local descriptions = model.descriptions_by_lang or {}
  local preferred_lang = active_locale == "rus" and "ru" or "en"
  local preferred = descriptions[preferred_lang]
  if type(preferred) == "table" and Util.is_non_empty(preferred.short_description) then
    return tostring(preferred.short_description)
  end
  local english = descriptions.en
  if type(english) == "table" and Util.is_non_empty(english.short_description) then
    return tostring(english.short_description)
  end
  return tostring(model.description or "")
end

local function supports_current_model()
  local model = selected_model()
  if not model then
    return false, t("No MVSEP model is selected.")
  end
  if model.supported_v1 ~= true then
    return false, tostring(model.unsupported_reason or t("This model is unsupported in v1."))
  end
  return true, nil
end

local function is_terminal_state(rec)
  if not rec then return true end
  return rec.state == "ready" or rec.state == "failed"
end

local function is_running_state(state_name)
  return state_name == "rendering" or state_name == "submitting" or state_name == "polling"
    or state_name == "downloading" or state_name == "canceling" or state_name == "deleting"
end

local function active_pipeline_count()
  local count = 0
  for _, rec in ipairs(S.records) do
    if rec and (is_running_state(rec.state) or rec.state == "poll_wait") then
      count = count + 1
    end
  end
  return count
end

local function desired_concurrency()
  if S.free_mode then return 1 end
  for _, rec in ipairs(S.records) do
    if rec and not is_terminal_state(rec) and rec.input_mode == "time_selection" then
      return 1
    end
  end
  local value = tonumber(S.region_concurrency) or 1
  if value < 1 then value = 1 end
  if value > CFG.max_paid_concurrency then value = CFG.max_paid_concurrency end
  return value
end

local function can_start_more_records()
  return active_pipeline_count() < desired_concurrency()
end

local function validate_current_model_fields()
  local model = reconcile_selected_model()
  if not model then
    return false, t("No MVSEP model is selected.")
  end
  for _, field in ipairs(model.fields or {}) do
    local value = tostring(S.model_field_values[field.form_key] or "")
    if field.required == true and Util.trim(value) == "" then
      local label = field.label or field.form_key or t("field")
      return false, string.format(t("Missing required model field: %s"), tostring(label))
    end
  end
  return true, nil
end

local function allocate_display_batch_id()
  local batch_id = tonumber(S.next_display_batch_id) or 1
  S.next_display_batch_id = batch_id + 1
  return batch_id
end

local function new_record_from_spec(spec, display_batch_id, display_batch_order)
  local model = ensure_selected_model()
  local rec = {
    id = S.next_record_id,
    display_batch_id = tonumber(display_batch_id) or allocate_display_batch_id(),
    display_batch_order = tonumber(display_batch_order) or 1,
    state = Util.trim(spec.input_path) ~= "" and "queued_submit" or "queued_render",
    mode = spec.mode,
    input_mode = spec.mode,
    label = spec.record_label,
    track = spec.track,
    track_name = spec.track_name,
    track_position = spec.start_time,
    start_time = spec.start_time,
    end_time = spec.end_time,
    duration = spec.duration,
    region_name = spec.region_name,
    region_number = spec.region_number,
    model_sep_type = model and model.sep_type or nil,
    model_name = model and model.name or "",
    field_values = {},
    output_format_name = S.output_format_name,
    input_path = Util.trim(spec.input_path) ~= "" and spec.input_path or nil,
    render_file_stem = spec.render_file_stem,
    render_source_path = spec.render_source_path,
    upload_staging = spec.upload_staging,
    downloads = {},
    download_index = 1,
    job_hash = nil,
    -- This marker is set only for records created by this in-memory workflow.
    -- Remote mutations must never accept an imported or user-supplied hash.
    created_by_this_tool = true,
    server_status = nil,
    raw_server_status = nil,
    status_source = nil,
    status_warning = nil,
    queue_count = nil,
    current_order = nil,
    finished_chunks = nil,
    all_chunks = nil,
    next_poll_at = nil,
    last_http_code = nil,
    error_text = "",
    failed_stage = nil,
    remote_removed = false,
    remote_delete_uncertain = false,
    cancel_outcome_uncertain = false,
    cancel_requested = false,
    cancel_reconcile_pending = false,
    cancel_non_retriable = false,
    create_outcome_uncertain = false,
    imported = false
  }

  for key, value in pairs(S.model_field_values or {}) do
    rec.field_values[key] = value
  end

  S.next_record_id = S.next_record_id + 1
  return rec
end

local function normalize_result_alloc_key(name)
  local key = tostring(name or "")
  if Util.is_windows() then
    key = key:lower()
  end
  return key
end

local function split_file_extension(file_name)
  local text = tostring(file_name or "")
  local stem, ext = text:match("^(.*)(%.[^%.\\/]+)$")
  if stem and stem ~= "" then
    return stem, ext
  end
  return text, ""
end

local function make_result_allocation_context(results_dir)
  local ctx_alloc = {
    results_dir = tostring(results_dir or ""),
    name_set = {},
    existing_count = 0,
    allocated_count = 0
  }

  if ctx_alloc.results_dir == "" or type(r.EnumerateFiles) ~= "function" then
    return ctx_alloc
  end

  pcall(r.EnumerateFiles, ctx_alloc.results_dir, -1)
  local idx = 0
  while true do
    local ok_enum, file_name = pcall(r.EnumerateFiles, ctx_alloc.results_dir, idx)
    if not ok_enum then
      debug_log(
        "result scan failed dir=" .. tostring(ctx_alloc.results_dir) ..
        " idx=" .. tostring(idx) ..
        " err=" .. tostring(file_name),
        2
      )
      break
    end
    if not file_name then break end
    ctx_alloc.name_set[normalize_result_alloc_key(file_name)] = true
    ctx_alloc.existing_count = ctx_alloc.existing_count + 1
    idx = idx + 1
  end

  return ctx_alloc
end

local function allocate_unique_result_path(allocation_ctx, file_name)
  local ctx_alloc = allocation_ctx or make_result_allocation_context(S.paths and S.paths.results_dir or "")
  local safe_name = tostring(file_name or "")
  if safe_name == "" then safe_name = "mvsep_result.bin" end

  local stem, ext = split_file_extension(safe_name)
  local candidate_name = safe_name
  local suffix = 0
  while ctx_alloc.name_set[normalize_result_alloc_key(candidate_name)] do
    suffix = suffix + 1
    candidate_name = stem .. "_" .. tostring(suffix) .. ext
    if suffix > 100000 then
      candidate_name = stem .. "_" .. Util.date_time_stamp_with_time_precise() .. ext
      break
    end
  end

  ctx_alloc.name_set[normalize_result_alloc_key(candidate_name)] = true
  ctx_alloc.allocated_count = (ctx_alloc.allocated_count or 0) + 1
  return Util.path_join(ctx_alloc.results_dir, candidate_name), candidate_name, suffix
end

local function download_target_for_record(rec, entry, allocation_ctx)
  local function extension_from_text(text)
    if type(text) ~= "string" or text == "" then return nil end
    local no_query = text:gsub("[?#].*$", "")
    local ext = no_query:match("%.([A-Za-z0-9]+)$")
    if ext and ext ~= "" then
      return ext:lower()
    end
    return nil
  end

  local function default_extension_for_format(output_format_name)
    local mapping = {
      mp3320 = "mp3",
      wav16 = "wav",
      flac16 = "flac",
      m4a = "m4a",
      wav32 = "wav",
      flac24 = "flac"
    }
    return mapping[tostring(output_format_name or "")]
  end

  local stem_label = Util.sanitize_filename(entry.label or "result", "result", 48)
  local model_label = Util.sanitize_filename(rec.model_name or rec.model_sep_type or "model", "model", 48)
  local source_label = Util.sanitize_filename(rec.track_name or "track", "track", 48)

  local parts = { source_label }
  if rec.input_mode == "regions" then
    parts[#parts + 1] = "r" .. tostring(rec.region_number or "")
    parts[#parts + 1] = Util.sanitize_filename(rec.region_name or "region", "region", 48)
  else
    parts[#parts + 1] = "selection"
  end
  parts[#parts + 1] = model_label
  parts[#parts + 1] = stem_label

  local stem = table.concat(parts, "__")
  local ext =
    extension_from_text(entry.download_name) or
    extension_from_text(entry.url) or
    default_extension_for_format(rec.output_format_name)
  if not ext or ext == "" then ext = "bin" end
  local file_name = Util.sanitize_filename(stem, "mvsep_result", 180) .. "." .. ext
  local ctx_alloc = allocation_ctx or make_result_allocation_context(S.paths.results_dir)
  debug_log(
    "result path allocation before rec=" .. tostring(rec and rec.id or "") ..
    " proposed=" .. tostring(file_name) ..
    " existing_count=" .. tostring(ctx_alloc.existing_count or "") ..
    " already_allocated=" .. tostring(ctx_alloc.allocated_count or 0),
    0
  )
  local full_path, chosen_name, suffix = allocate_unique_result_path(ctx_alloc, file_name)
  debug_log(
    "result path allocation after rec=" .. tostring(rec and rec.id or "") ..
    " suffix=" .. tostring(suffix or 0) ..
    " chosen=" .. tostring(chosen_name) ..
    " path=" .. tostring(full_path),
    0
  )

  local track_title = chosen_name:gsub("%.[^%.]+$", ""):gsub("__", " - "):gsub("_+", " ")
  return full_path, track_title
end

local function set_record_network_job(rec, job, label)
  if type(rec) ~= "table" then return end
  if type(job) == "table" and job.id ~= nil then
    rec.network_job_id = job.id
    rec.network_job_label = tostring(label or "")
  else
    rec.network_job_id = nil
    rec.network_job_label = nil
  end
end

local function clear_record_network_job(rec, label)
  if type(rec) ~= "table" then return end
  if label == nil or rec.network_job_label == tostring(label or "") then
    rec.network_job_id = nil
    rec.network_job_label = nil
  end
end

local function active_record_network_job(rec)
  if type(rec) ~= "table" or rec.network_job_id == nil or type(S.curl_jobs) ~= "table" then
    return nil
  end
  return S.curl_jobs[rec.network_job_id]
end

local function record_network_progress_text(rec)
  local job = active_record_network_job(rec)
  if type(job) ~= "table" then
    return nil
  end
  local flow_line = job.progress and job.progress.flow and job.progress.flow.line or nil
  if type(flow_line) == "string" then
    flow_line = Util.trim(flow_line)
    if flow_line ~= "" then
      return flow_line
    end
  end
  if job.phase == "created" or job.phase == "launched" then
    return t("queued")
  end
  if job.phase == "running" then
    return t("running")
  end
  return nil
end

local function get_or_create_network_record(key, label)
  local record_key = tostring(key or "")
  if record_key == "" then return nil end
  if type(S.network_records) ~= "table" then
    S.network_records = {}
  end
  for _, rec in ipairs(S.network_records) do
    if rec and rec.network_key == record_key then
      rec.label = label or rec.label
      return rec
    end
  end
  local rec = {
    network_key = record_key,
    state = "queued",
    label = tostring(label or record_key),
    model_name = "-",
    last_message = "",
    last_http_code = nil,
    error_text = ""
  }
  S.network_records[#S.network_records + 1] = rec
  return rec
end

local function begin_network_record(rec, progress_text)
  if type(rec) ~= "table" then return end
  rec.display_batch_id = allocate_display_batch_id()
  rec.display_batch_order = 1
  rec.state = "running"
  rec.last_message = tostring(progress_text or t("running"))
  rec.error_text = ""
  rec.last_http_code = nil
  clear_record_network_job(rec)
end

local function finish_network_record_ok(rec, progress_text, http_code)
  if type(rec) ~= "table" then return end
  rec.state = "ready"
  rec.last_message = tostring(progress_text or t("Ready."))
  rec.error_text = ""
  rec.last_http_code = http_code
  clear_record_network_job(rec)
end

local function finish_network_record_failed(rec, err_text, http_code, progress_text)
  if type(rec) ~= "table" then return end
  rec.state = "failed"
  rec.error_text = tostring(err_text or t("request failed"))
  rec.last_message = tostring(progress_text or t("failed"))
  rec.last_http_code = http_code
  clear_record_network_job(rec)
end

local function network_record_progress_text(rec)
  local parts = {}
  local message = Util.trim(rec and rec.last_message or "")
  local network_text = record_network_progress_text(rec)
  if message ~= "" then parts[#parts + 1] = message end
  if network_text and network_text ~= "" then parts[#parts + 1] = network_text end
  if rec and rec.state == "failed" and Util.trim(rec.error_text or "") ~= "" then
    parts[#parts + 1] = tostring(rec.error_text)
  end
  if #parts == 0 then
    if rec and rec.state == "ready" then return t("Ready.") end
    if rec and rec.state == "failed" then return tostring(rec.error_text or t("failed")) end
    return t("queued")
  end
  return table.concat(parts, " | ")
end

local function record_progress_text(rec)
  local state = rec.state or ""
  local now_t = r.time_precise()
  local network_text = record_network_progress_text(rec)
  local countdown_text = nil
  if rec.next_poll_at and rec.next_poll_at > now_t then
    countdown_text = string.format(t("next poll in %.0fs"), rec.next_poll_at - now_t)
  end
  local queue_text = nil
  if rec.queue_count ~= nil or rec.current_order ~= nil then
    local parts = {}
    if rec.queue_count ~= nil then
      parts[#parts + 1] = string.format(t("queue=%s"), tostring(rec.queue_count))
    end
    if rec.current_order ~= nil then
      parts[#parts + 1] = string.format(t("position=%s"), tostring(rec.current_order))
    end
    queue_text = table.concat(parts, " | ")
  end
  local chunk_text = nil
  if rec.finished_chunks ~= nil or rec.all_chunks ~= nil then
    chunk_text = string.format(
      t("chunks=%s/%s"),
      tostring(rec.finished_chunks or "?"),
      tostring(rec.all_chunks or "?")
    )
  end
  local function with_suffix(base)
    local parts = {}
    local base_text = tostring(base or "")
    if base_text ~= "" then parts[#parts + 1] = base_text end
    if network_text and network_text ~= "" then parts[#parts + 1] = network_text end
    if queue_text and queue_text ~= "" then parts[#parts + 1] = queue_text end
    if chunk_text and chunk_text ~= "" then parts[#parts + 1] = chunk_text end
    if countdown_text and countdown_text ~= "" then parts[#parts + 1] = countdown_text end
    return table.concat(parts, " | ")
  end
  if state == "queued_render" then return t("Waiting to render input.") end
  if state == "rendering" then return t("Rendering input...") end
  if state == "queued_submit" then return t("Waiting to submit job.") end
  if state == "submitting" then return with_suffix(t("Submitting job...")) end
  if state == "poll_wait" then return with_suffix(rec.last_message or t("Waiting for next status poll."))
  end
  if state == "polling" then return with_suffix(t("Checking status...")) end
  if state == "queued_download" or state == "downloading" then
    local downloaded = 0
    for _, item in ipairs(rec.downloads or {}) do
      if item.downloaded then downloaded = downloaded + 1 end
    end
    return with_suffix(string.format(t("Downloaded %d/%d files."), downloaded, #(rec.downloads or {})))
  end
  if state == "ready" then
    return t("Ready.")
  end
  if state == "failed" then
    return tostring(rec.error_text or "")
  end
  if state == "canceling" then return with_suffix(t("Requesting remote cancellation...")) end
  if state == "deleting" then return with_suffix(t("Deleting remote files through Studio Neurocast...")) end
  return with_suffix(rec.last_message or "")
end

local function record_state_label(state_name)
  local normalized = tostring(state_name or "")
  if normalized == "queued" then return t("queued") end
  if normalized == "running" then return t("running") end
  if normalized == "ready" then return t("ready") end
  if normalized == "failed" then return t("failed") end
  if normalized == "queued_render" then return t("queued_render") end
  if normalized == "rendering" then return t("rendering") end
  if normalized == "queued_submit" then return t("queued_submit") end
  if normalized == "submitting" then return t("submitting") end
  if normalized == "poll_wait" then return t("poll_wait") end
  if normalized == "polling" then return t("polling") end
  if normalized == "queued_download" then return t("queued_download") end
  if normalized == "downloading" then return t("downloading") end
  if normalized == "canceling" then return t("canceling") end
  if normalized == "deleting" then return t("deleting") end
  if normalized == "canceled" then return t("canceled") end
  return normalized
end

local function update_queue_progress_from_payload(rec, payload)
  rec.server_status = payload and payload.status or nil
  rec.raw_server_status = payload and payload.raw_status or nil
  rec.status_source = payload and payload.status_source or nil
  rec.status_warning = payload and payload.status_warning or nil
  rec.queue_count = payload and payload.queue_count or nil
  rec.current_order = payload and payload.current_order or nil
  rec.finished_chunks = payload and payload.finished_chunks or nil
  rec.all_chunks = payload and payload.all_chunks or nil
end

local function update_record_http(rec, payload)
  rec.last_http_code = payload and payload.http_code or nil
end

local function mark_record_failed(rec, err_text, detail_text, failed_stage)
  local summary = tostring(err_text or t("Unknown error."))
  local details = Util.trim(detail_text or "")
  rec.state = "failed"
  rec.error_text = summary
  rec.failed_stage = failed_stage
  rec.last_message = rec.error_text
  clear_record_network_job(rec)
  TelemetryBridge.finish_record_stage_failed(rec, summary, failed_stage, {
    safe_message = summary,
    detail_text = details
  })
  set_last_error(details ~= "" and details or summary, summary)
  push_warning_once(rec.error_text)
  debug_log(
    "record failed rec=" .. tostring(rec and rec.id or "") ..
    " state=" .. tostring(rec and rec.state or "") ..
    " err=" .. tostring(summary) ..
    " details=" .. tostring(details),
    2
  )
end

local function enqueue_render_input_cleanup(rec, why)
  if type(rec) ~= "table" then return end
  local cleanup_paths = {
    Util.trim(rec.input_path or ""),
    Util.trim(rec.render_source_path or "")
  }
  local seen = {}
  for _, path in ipairs(cleanup_paths) do
    if path ~= "" and not seen[path] then
      seen[path] = true
      debug_log(
        "render input cleanup queued rec=" .. tostring(rec.id or "") ..
          " path=" .. path ..
          " reason=" .. tostring(why or "mvsep rendered input"),
        0
      )
      Cleanup.enqueue_cleanup(path, why or "mvsep rendered input")
    end
  end
  rec.input_path = nil
  rec.render_source_path = nil
end

local function payload_output_count(payload)
  return #(type(payload) == "table" and payload.output_files or {})
end

local function clipped_single_line(text, max_len)
  local clipped = Util.clip_body_text(text or "", tonumber(max_len) or 180)
  clipped = tostring(clipped or ""):gsub("[\r\n]+", " ")
  return Util.trim(clipped)
end

local function poll_failure_diagnostic(rec, payload, effective_status, prefix)
  local label = tostring(prefix or t("MVSEP status problem."))
  local message = Util.trim(payload and payload.message or "")
  local summary_parts = {
    label,
    string.format(t("effective=%s"), tostring(effective_status or "")),
    string.format(t("raw=%s"), tostring(payload and payload.raw_status or "")),
    string.format(t("http=%s"), tostring(payload and payload.http_code or ""))
  }
  if message ~= "" then
    summary_parts[#summary_parts + 1] = string.format(t("message=%s"), clipped_single_line(message, 180))
  end

  local lines = {
    label,
    string.format(t("record_id: %s"), tostring(rec and rec.id or "")),
    string.format(t("record_label: %s"), tostring(rec and rec.label or "")),
    string.format(t("job_hash: %s"), tostring(rec and rec.job_hash or "")),
    string.format(t("endpoint: %s"), tostring(payload and payload.endpoint or "")),
    string.format(t("http: %s"), tostring(payload and payload.http_code or "")),
    string.format(t("raw_success: %s"), tostring(payload and payload.raw_success)),
    string.format(t("raw_status: %s"), tostring(payload and payload.raw_status or "")),
    string.format(t("effective_status: %s"), tostring(effective_status or "")),
    string.format(t("status_source: %s"), tostring(payload and payload.status_source or "")),
    string.format(t("status_warning: %s"), tostring(payload and payload.status_warning or "")),
    string.format(t("message: %s"), tostring(message)),
    string.format(t("queue_count: %s"), tostring(payload and payload.queue_count or "")),
    string.format(t("current_order: %s"), tostring(payload and payload.current_order or "")),
    string.format(
      t("chunks: %s/%s"),
      tostring(payload and payload.finished_chunks or ""),
      tostring(payload and payload.all_chunks or "")
    ),
    string.format(t("output_files: %s"), tostring(payload_output_count(payload)))
  }

  return table.concat(summary_parts, " | "), table.concat(lines, "\n")
end

local function safe_record_callback(stage, rec, callback_fn)
  return function(payload)
    debug_log(
      "callback enter stage=" .. tostring(stage or "") ..
      " rec=" .. tostring(rec and rec.id or "") ..
      " state=" .. tostring(rec and rec.state or "") ..
      " ok=" .. tostring(payload and payload.ok) ..
      " endpoint=" .. tostring(payload and payload.endpoint or "") ..
      " status=" .. tostring(payload and payload.status or "") ..
      " http=" .. tostring(payload and payload.http_code or "") ..
      " files=" .. tostring(payload_output_count(payload)),
      0
    )

    clear_record_network_job(rec, stage)

    local ok_cb, cb_err = xpcall(function()
      callback_fn(payload)
    end, debug.traceback)
    if not ok_cb then
      local err_text = string.format(t("%s callback failed."), tostring(stage or t("request")))
      debug_log(
        "callback error stage=" .. tostring(stage or "") ..
        " rec=" .. tostring(rec and rec.id or "") ..
        " traceback=" .. tostring(cb_err),
        2
      )
      if rec then
        mark_record_failed(rec, err_text)
      else
        set_last_error(err_text)
        push_warning_once(err_text)
      end
    end

    debug_log(
      "callback exit stage=" .. tostring(stage or "") ..
      " rec=" .. tostring(rec and rec.id or "") ..
      " state=" .. tostring(rec and rec.state or ""),
      ok_cb and 0 or 2
    )
  end
end

local submit_cancel_for_record

local function submit_create_for_record(rec, auth_retry)
  if auth_retry ~= true then
    rec._auth_refresh_used_once = false
  end
  rec._retry_submit = function()
    return submit_create_for_record(rec, true)
  end
  rec.state = "submitting"
  rec.error_text = ""
  rec.failed_stage = nil
  rec.queue_count = nil
  rec.current_order = nil
  rec.finished_chunks = nil
  rec.all_chunks = nil
  rec.server_status = "submitting"
  rec.last_message = rec.cancel_requested == true
    and t("Cancellation requested. Waiting for job hash...")
    or t("Submitting job...")
  if auth_retry ~= true then
    TelemetryBridge.begin_record_stage(rec, "create", {
      request_label = "mvsep_neurocast_create",
      model_field_values = rec.field_values,
      input_size = rec.input_path and Files.file_size(rec.input_path) or nil
    })
  end
  debug_log(
    "create submit rec=" .. tostring(rec.id) ..
    " input_mode=" .. tostring(rec.input_mode) ..
    " model=" .. tostring(rec.model_sep_type) ..
    " input_path=" .. tostring(rec.input_path or "") ..
    " input_exists=" .. tostring(rec.input_path and r.file_exists(rec.input_path) == true) ..
    " input_size=" .. tostring(rec.input_path and Files.file_size(rec.input_path) or "") ..
    " input_non_ascii=" .. tostring(Util.has_non_ascii(rec.input_path or "")) ..
    " input_path_bytes=" .. tostring(#tostring(rec.input_path or "")) ..
    " render_source_path=" .. tostring(rec.render_source_path or "") ..
    " render_source_exists=" .. tostring(rec.render_source_path and r.file_exists(rec.render_source_path) == true) ..
    " render_source_size=" .. tostring(rec.render_source_path and Files.file_size(rec.render_source_path) or "") ..
    " render_source_non_ascii=" .. tostring(Util.has_non_ascii(rec.render_source_path or "")),
    0
  )
  local job, submit_err = mvsep_client.submit_create_job(
    rec.input_path,
    rec.model_sep_type,
    rec.field_values,
    rec.output_format_name,
    false,
    safe_record_callback("create", rec, function(payload)
      update_record_http(rec, payload)
      if not payload or payload.ok ~= true then
        rec._retry_submit = nil
        rec.cancel_requested = false
        local message = payload and (payload.api_error or payload.error) or t("Create request failed.")
        if payload and (payload.outcome_uncertain == true or tostring(payload.mutation_outcome or ""):lower() == "uncertain") then
          rec.create_outcome_uncertain = true
          message = t("Create outcome is uncertain. Do not submit the same audio again until the remote state is checked.") ..
            " " .. tostring(message)
        end
        mark_record_failed(rec, message)
        return
      end
      rec._retry_submit = nil
      rec.job_hash = payload.job_hash
      enqueue_render_input_cleanup(rec, "mvsep rendered input (uploaded)")
      rec.state = "poll_wait"
      rec.failed_stage = nil
      rec.server_status = "submitted"
      if rec.cancel_requested == true then
        rec.next_poll_at = nil
        rec.last_message = t("Requesting remote cancellation...")
      else
        rec.next_poll_at = r.time_precise() + CFG.initial_poll_delay_sec
        rec.last_message = t("Submitted. Waiting for first poll.")
      end
      S.status_text = rec.last_message
      TelemetryBridge.finish_record_stage_ok(rec, "create", {
        request_label = "mvsep_neurocast_create",
        http_code = payload.http_code,
        job_hash = rec.job_hash,
        response_message = TelemetryBridge.safe_string(payload.message or "")
      })
      debug_log(
        "create accepted rec=" .. tostring(rec.id) ..
        " job_hash=" .. tostring(rec.job_hash or "") ..
        " backend_route=/api/mvsep/separation/create",
        0
      )
      if rec.cancel_requested == true then
        local ok_cancel, cancel_err = submit_cancel_for_record(rec)
        if not ok_cancel and cancel_err and rec.cancel_reconcile_pending ~= true then
          rec.cancel_requested = false
          mark_record_failed(rec, cancel_err)
        end
      end
    end),
    {
      keep_output = false,
      timeout_sec = 5000,
      auth_rec = rec
    }
  )
  if not job then
    clear_record_network_job(rec, "create")
    mark_record_failed(rec, submit_err or t("Failed to submit create request."))
  else
    set_record_network_job(rec, job, "create")
  end
  return job ~= nil, submit_err
end

local function submit_poll_for_record(rec, auth_retry)
  if auth_retry ~= true then rec._auth_refresh_used_once = false end
  rec._retry_submit = function() return submit_poll_for_record(rec, true) end
  rec.state = "polling"
  rec.failed_stage = nil
  rec.last_message = rec.cancel_requested == true
    and t("Cancellation requested. Waiting for status check...")
    or t("Checking status...")
  debug_log(
    "poll submit rec=" .. tostring(rec.id) ..
    " job_hash=" .. tostring(rec.job_hash or "") ..
    " prev_status=" .. tostring(rec.server_status or ""),
    0
  )
  local job, submit_err = mvsep_client.submit_get_job_status(rec.job_hash, safe_record_callback("poll", rec, function(payload)
    update_record_http(rec, payload)
    if not payload or payload.ok ~= true then
      rec._retry_submit = nil
      debug_log(
        "poll action rec=" .. tostring(rec.id) ..
        " action=request_failed" ..
        " http=" .. tostring(payload and payload.http_code or "") ..
        " err=" .. tostring(payload and (payload.api_error or payload.error) or "Status request failed."),
        2
      )
      TelemetryBridge.operation_failed("mvsep_poll_status", TelemetryBridge.record_payload(rec, {
        request_label = "mvsep_get_job_status",
        http_code = payload and payload.http_code or nil,
        safe_message = payload and (payload.api_error or payload.error) or "Status request failed.",
        endpoint = payload and payload.endpoint or ""
      }))
      if rec.cancel_requested == true and Util.trim(rec.job_hash or "") ~= "" then
        rec.state = "poll_wait"
        rec.next_poll_at = nil
        local ok_cancel, cancel_err = submit_cancel_for_record(rec)
        if not ok_cancel and cancel_err and rec.cancel_reconcile_pending ~= true then
          rec.cancel_requested = false
          mark_record_failed(rec, cancel_err)
        end
        return
      end
      mark_record_failed(rec, payload and (payload.api_error or payload.error) or t("Status request failed."), nil, "poll")
      return
    end

    rec._retry_submit = nil
    update_queue_progress_from_payload(rec, payload)
    local status = MVSepAPI.normalize_job_status(payload.status)
    local cancel_reconcile_was_pending = rec.cancel_reconcile_pending == true
    if MVSepAPI.has_processing_started(status) then
      rec.cancel_non_retriable = true
    end
    if cancel_reconcile_was_pending then
      rec.cancel_reconcile_pending = false
      debug_log(
        "cancel reconciliation rec=" .. tostring(rec.id) ..
        " status=" .. tostring(status) ..
        " non_retriable=" .. tostring(rec.cancel_non_retriable == true),
        0
      )
    end
    rec.last_message = payload.message or status or ""
    if Util.trim(payload.status_warning) ~= "" then
      push_warning_once(payload.status_warning)
    end
    debug_log(
      "poll payload rec=" .. tostring(rec.id) ..
      " effective_status=" .. tostring(status) ..
      " raw_status=" .. tostring(payload.raw_status or "") ..
      " raw_success=" .. tostring(payload.raw_success) ..
      " status_source=" .. tostring(payload.status_source or "") ..
      " http=" .. tostring(payload.http_code or "") ..
      " message=" .. tostring(payload.message or "") ..
      " queue=" .. tostring(payload.queue_count or "") ..
      " order=" .. tostring(payload.current_order or "") ..
      " chunks=" .. tostring(payload.finished_chunks or "") .. "/" .. tostring(payload.all_chunks or "") ..
      " warning=" .. tostring(payload.status_warning or "") ..
      " output_files=" .. tostring(payload_output_count(payload)),
      0
    )
    if rec.cancel_requested == true then
      if MVSepAPI.is_cancelable_status(status) then
        rec.state = "poll_wait"
        rec.failed_stage = nil
        rec.next_poll_at = nil
        TelemetryBridge.poll_status_transition(rec, payload, status, "in_progress")
        local ok_cancel, cancel_err = submit_cancel_for_record(rec)
        if not ok_cancel and cancel_err and rec.cancel_reconcile_pending ~= true then
          rec.cancel_requested = false
          mark_record_failed(rec, cancel_err)
        end
        return
      end
      rec.cancel_requested = false
    end
    if MVSepAPI.is_in_progress_status(status) then
      rec.state = "poll_wait"
      rec.failed_stage = nil
      rec.next_poll_at = r.time_precise() + CFG.poll_interval_sec
      if status == "waiting" then
        rec.last_message = t("Queued on MVSEP.")
      elseif status == "processing" then
        rec.last_message = payload.message or t("Processing on MVSEP.")
      elseif status == "distributing" then
        rec.last_message = payload.message or t("Distributing on MVSEP.")
      elseif status == "merging" then
        rec.last_message = payload.message or t("Merging on MVSEP.")
      end
      debug_log(
        "poll action rec=" .. tostring(rec.id) ..
        " action=poll_wait" ..
        " effective_status=" .. tostring(status) ..
        " next_poll_in=" .. tostring(CFG.poll_interval_sec),
        0
      )
      TelemetryBridge.poll_status_transition(rec, payload, status, "in_progress")
      return
    end

    if status == "canceled" or (cancel_reconcile_was_pending and status == "not_found") then
      rec.state = "canceled"
      rec.server_status = "canceled"
      rec.next_poll_at = nil
      rec.failed_stage = nil
      rec.cancel_non_retriable = true
      rec.last_message = t("Remote job canceled.")
      TelemetryBridge.poll_status_transition(rec, payload, status, "canceled")
      return
    end

    if status == "done" then
      rec.next_poll_at = nil
      rec.downloads = {}
      local allocation_ctx = make_result_allocation_context(S.paths.results_dir)
      debug_log(
        "poll done rec=" .. tostring(rec.id) ..
        " output_files=" .. tostring(payload_output_count(payload)) ..
        " existing_result_files=" .. tostring(allocation_ctx.existing_count or ""),
        0
      )
      for _, entry in ipairs(payload.output_files or {}) do
        local local_path, track_title = download_target_for_record(rec, entry, allocation_ctx)
        rec.downloads[#rec.downloads + 1] = {
          label = entry.label,
          url = entry.url,
          local_path = local_path,
          track_name = track_title,
          downloaded = false,
          imported = false
        }
      end
      if #rec.downloads == 0 then
        debug_log(
          "poll action rec=" .. tostring(rec.id) ..
          " action=failed_no_downloads" ..
          " effective_status=" .. tostring(status),
          2
        )
        TelemetryBridge.poll_status_transition(rec, payload, status, "failed")
        mark_record_failed(rec, t("MVSEP returned no downloadable files."))
        return
      end
      rec.download_index = 1
      rec.state = "queued_download"
      rec.failed_stage = nil
      rec.last_message = t("Processing finished. Downloading files.")
      debug_log(
        "downloads queued rec=" .. tostring(rec.id) ..
        " action=queued_download" ..
        " count=" .. tostring(#rec.downloads),
        0
      )
      TelemetryBridge.poll_status_transition(rec, payload, status, "done")
      return
    end

    rec.next_poll_at = nil
    if MVSepAPI.is_terminal_status(status) then
      local failure_message, failure_details = poll_failure_diagnostic(rec, payload, status, t("MVSEP terminal status."))
      debug_log(
        "poll action rec=" .. tostring(rec.id) ..
        " action=failed_terminal " .. failure_message,
        2
      )
      TelemetryBridge.poll_status_transition(rec, payload, status, "failed")
      mark_record_failed(rec, failure_message, failure_details)
      return
    end
    local failure_message, failure_details = poll_failure_diagnostic(rec, payload, status, t("Unexpected MVSEP status."))
    debug_log(
      "poll action rec=" .. tostring(rec.id) ..
      " action=failed_unexpected " .. failure_message,
      2
    )
    TelemetryBridge.poll_status_transition(rec, payload, status, "failed")
    mark_record_failed(rec, failure_message, failure_details)
  end), {
    keep_output = false,
    auth_rec = rec
  })
  if not job then
    clear_record_network_job(rec, "poll")
    debug_log(
      "poll action rec=" .. tostring(rec.id) ..
      " action=submit_failed" ..
      " err=" .. tostring(submit_err or "Failed to submit status request."),
      2
    )
    TelemetryBridge.operation_failed("mvsep_poll_status", TelemetryBridge.record_payload(rec, {
      request_label = "mvsep_get_job_status",
      safe_message = submit_err or "Failed to submit status request."
    }))
    mark_record_failed(rec, submit_err or t("Failed to submit status request."), nil, "poll")
  else
    set_record_network_job(rec, job, "poll")
  end
  return job ~= nil, submit_err
end

local function submit_download_for_record(rec, auth_retry)
  local item = rec.downloads[rec.download_index]
  if not item then
    rec.state = "ready"
    rec.failed_stage = nil
    rec.last_message = t("Ready.")
    return true
  end
  if auth_retry ~= true then rec._auth_refresh_used_once = false end
  rec._retry_submit = function() return submit_download_for_record(rec, true) end

  rec.state = "downloading"
  rec.failed_stage = nil
  rec.last_message = t("Downloading result files...")
  if auth_retry ~= true then
    TelemetryBridge.begin_record_stage(rec, "download", {
      request_label = "mvsep_download_result",
      download_index = rec.download_index,
      download_path = item.local_path
    })
  end
  debug_log(
    "download submit rec=" .. tostring(rec.id) ..
    " index=" .. tostring(rec.download_index or "") ..
    " path=" .. tostring(item.local_path or ""),
    0
  )

  local job, submit_err = mvsep_client.submit_download_result(item.url, item.local_path, safe_record_callback("download", rec, function(payload)
    update_record_http(rec, payload)
    if not payload or payload.ok ~= true then
      rec._retry_submit = nil
      mark_record_failed(rec, payload and (payload.api_error or payload.error) or t("Download failed."), nil, "download")
      return
    end

    local valid_audio, size_or_err, audio_info = MVSepReaper.validate_downloaded_audio(
      item.local_path,
      payload.downloaded_bytes
    )
    if not valid_audio then
      rec._retry_submit = nil
      mark_record_failed(rec, tostring(size_or_err or t("Downloaded result validation failed.")), nil, "download")
      return
    end

    rec._retry_submit = nil
    item.downloaded = true
    item.validated_audio = true
    item.audio_format = audio_info and audio_info.format or nil
    rec.failed_stage = nil
    debug_log(
      "download complete rec=" .. tostring(rec.id) ..
      " path=" .. tostring(item.local_path or "") ..
      " bytes=" .. tostring(size_or_err or payload.downloaded_bytes or "") ..
      " audio_format=" .. tostring(item.audio_format or ""),
      0
    )
    rec.download_index = rec.download_index + 1
    if rec.download_index <= #(rec.downloads or {}) then
      rec.state = "queued_download"
      rec.last_message = t("Downloading next file.")
    else
      rec.state = "ready"
      rec.failed_stage = nil
      rec.last_message = t("Ready.")
      S.status_text = t("Download finished.")
    end
    TelemetryBridge.finish_record_stage_ok(rec, "download", {
      request_label = "mvsep_download_result",
      http_code = payload.http_code,
      download_path = item.local_path,
      downloaded_bytes = size_or_err,
      audio_format = item.audio_format,
      content_type = payload.content_type
    })
  end), {
    read_body = false,
    keep_output = true,
    timeout_sec = 5000,
    auth_rec = rec
  })

  if not job then
    clear_record_network_job(rec, "download")
    mark_record_failed(rec, submit_err or t("Failed to start download."), nil, "download")
  else
    set_record_network_job(rec, job, "download")
  end
  return job ~= nil, submit_err
end

local function can_retry_record(rec)
  if type(rec) ~= "table" or rec.state ~= "failed" then return false end
  local stage = tostring(rec.failed_stage or "")
  if stage == "poll" then
    return Util.trim(rec.job_hash or "") ~= ""
  end
  if stage == "download" then
    local downloads = type(rec.downloads) == "table" and rec.downloads or {}
    local item = downloads[tonumber(rec.download_index) or 1]
    return type(item) == "table"
      and Util.trim(item.url or "") ~= ""
      and Util.trim(item.local_path or "") ~= ""
  end
  return false
end

local function retry_record(rec)
  if not can_retry_record(rec) then
    return false, t("Retry is not available for this row.")
  end

  local stage = tostring(rec.failed_stage or "")
  local retry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("mvsep_manual_retry", TelemetryBridge.record_payload(rec, {
    retry_stage = stage
  }))
  clear_record_network_job(rec, "retry")
  rec.error_text = ""
  rec.last_http_code = nil

  if stage == "poll" then
    rec.failed_stage = nil
    rec.next_poll_at = r.time_precise()
    rec.state = "poll_wait"
    rec.server_status = "poll_wait"
    rec.last_message = t("Retry queued: checking status.")
    S.status_text = rec.last_message
    S.last_api_error = ""
    TelemetryBridge.operation_completed("mvsep_manual_retry", TelemetryBridge.record_payload(rec, {
      retry_stage = stage
    }), retry_started_at)
    return true, rec.last_message
  end

  if stage == "download" then
    local item = rec.downloads[tonumber(rec.download_index) or 1]
    local local_path = Util.trim(item and item.local_path or "")
    if local_path ~= "" and r.file_exists(local_path) then
      local ok_remove, remove_err = Files.remove_best_effort(local_path)
      if not ok_remove then
        local err_text = string.format(t("Failed to remove partial download before retry: %s"), tostring(remove_err or "unknown error"))
        TelemetryBridge.operation_failed("mvsep_manual_retry", TelemetryBridge.record_payload(rec, {
          retry_stage = stage,
          safe_message = err_text,
          partial_path = local_path
        }), retry_started_at)
        mark_record_failed(rec, err_text, nil, "download")
        return false, err_text
      end
    end
    item.downloaded = false
    item.imported = false
    rec.failed_stage = nil
    rec.state = "queued_download"
    rec.last_message = t("Retry queued: downloading result files.")
    S.status_text = rec.last_message
    S.last_api_error = ""
    TelemetryBridge.operation_completed("mvsep_manual_retry", TelemetryBridge.record_payload(rec, {
      retry_stage = stage,
      partial_path_removed = local_path
    }), retry_started_at)
    return true, rec.last_message
  end

  TelemetryBridge.operation_failed("mvsep_manual_retry", TelemetryBridge.record_payload(rec, {
    retry_stage = stage,
    safe_message = t("Retry is not available for this row.")
  }), retry_started_at)
  return false, t("Retry is not available for this row.")
end

local function all_downloads_complete(rec)
  local downloads = type(rec) == "table" and rec.downloads or {}
  if #downloads < 1 then return false end
  for _, item in ipairs(downloads) do
    if item.downloaded ~= true
        or item.validated_audio ~= true
        or Util.trim(item.local_path or "") == ""
        or r.file_exists(item.local_path) ~= true then
      return false
    end
  end
  return true
end

local function can_request_cancel(rec)
  if type(rec) ~= "table"
      or rec.created_by_this_tool ~= true
      or rec.cancel_requested == true then
    return false
  end
  if rec.cancel_reconcile_pending == true
      or rec.cancel_non_retriable == true
      or rec._cancel_operation_id ~= nil then
    return false
  end
  local job_hash = Util.trim(rec.job_hash or "")
  if rec.state == "submitting" and job_hash == "" then
    return true
  end
  if job_hash == "" or (rec.state ~= "poll_wait" and rec.state ~= "polling") then
    return false
  end
  return MVSepAPI.is_cancel_request_window_status(rec.server_status)
end

local function submit_delete_for_record(rec, auth_retry)
  if type(rec) ~= "table" or rec.created_by_this_tool ~= true then
    return false, t("Remote deletion is available only for jobs created by this running tool.")
  end
  if rec.state ~= "ready" or rec.remote_removed == true or not all_downloads_complete(rec) then
    return false, t("Remote deletion is available only after every result is safely downloaded.")
  end
  if rec.remote_delete_uncertain == true then
    return false, t("Remote deletion outcome is uncertain; this tool will not submit it again.")
  end
  if Util.trim(rec.job_hash or "") == "" then return false, t("Remote deletion requires the tracked job hash.") end
  if auth_retry ~= true then
    rec._auth_refresh_used_once = false
    rec._delete_operation_id = "mvsep_delete_" .. tostring(rec.id) .. "_" .. tostring(r.time_precise())
    TelemetryBridge.begin_record_stage(rec, "delete", {
      request_label = "mvsep_neurocast_delete"
    })
  end
  local operation_id = rec._delete_operation_id
  rec._retry_submit = function() return submit_delete_for_record(rec, true) end
  rec.state = "deleting"
  rec.last_message = t("Deleting remote files through Studio Neurocast...")
  local job, submit_err = mvsep_client.submit_delete_job(rec.job_hash, function(payload)
    if rec._delete_operation_id ~= operation_id then return end
    clear_record_network_job(rec, "delete")
    rec._delete_operation_id = nil
    rec._retry_submit = nil
    update_record_http(rec, payload)
    rec.state = "ready"
    if payload and payload.ok == true then
      rec.remote_removed = true
      rec.error_text = ""
      rec.last_message = t("Remote files deleted.")
      S.status_text = rec.last_message
      TelemetryBridge.finish_record_stage_ok(rec, "delete", {
        request_label = "mvsep_neurocast_delete",
        http_code = payload.http_code
      })
      return
    end
    local message = tostring(payload and payload.error or t("Remote deletion failed."))
    if payload and (payload.outcome_uncertain == true or tostring(payload.mutation_outcome or ""):lower() == "uncertain") then
      rec.remote_delete_uncertain = true
      message = t("Remote deletion outcome is uncertain. This tool will not retry it.") .. " " .. message
    end
    rec.error_text = message
    rec.last_message = message
    set_last_error(message)
    push_warning_once(message)
    TelemetryBridge.finish_record_stage_failed(rec, message, "delete", {
      request_label = "mvsep_neurocast_delete",
      http_code = payload and payload.http_code or nil,
      mutation_outcome = payload and payload.mutation_outcome or nil,
      failure_type = payload and payload.failure_type or nil,
      upstream_status = payload and payload.upstream_status or nil,
      correlation_id = payload and payload.correlation_id or nil
    })
  end, {
    keep_output = false,
    read_body = true,
    auth_rec = rec
  })
  if not job then
    if rec._delete_operation_id == operation_id then
      rec._delete_operation_id = nil
      rec._retry_submit = nil
      rec.state = "ready"
      local message = submit_err or t("Remote deletion could not start.")
      rec.error_text = tostring(message)
      rec.last_message = tostring(message)
    end
  else
    set_record_network_job(rec, job, "delete")
  end
  return job ~= nil, submit_err
end

function submit_cancel_for_record(rec, auth_retry)
  if type(rec) ~= "table" or rec.created_by_this_tool ~= true then
    return false, t("Remote cancellation is available only for jobs created by this running tool.")
  end
  if auth_retry == true then
    if rec.state ~= "canceling" or rec._cancel_operation_id == nil then
      return false, t("Remote cancellation cannot be resumed after authentication refresh.")
    end
  elseif rec.cancel_requested ~= true
      or rec.state ~= "poll_wait"
      or Util.trim(rec.job_hash or "") == ""
      or rec.cancel_reconcile_pending == true
      or rec.cancel_non_retriable == true
      or rec._cancel_operation_id ~= nil
      or not MVSepAPI.is_cancel_request_window_status(rec.server_status) then
    return false, t("Remote cancellation is available only before processing starts.")
  end
  if auth_retry ~= true then
    rec._auth_refresh_used_once = false
    rec._cancel_operation_id = "mvsep_cancel_" .. tostring(rec.id) .. "_" .. tostring(r.time_precise())
    TelemetryBridge.begin_record_stage(rec, "cancel", {
      request_label = "mvsep_neurocast_cancel"
    })
  end
  local operation_id = rec._cancel_operation_id
  rec._retry_submit = function() return submit_cancel_for_record(rec, true) end
  rec.state = "canceling"
  rec.next_poll_at = nil
  rec.last_message = t("Requesting remote cancellation...")
  local job, submit_err = mvsep_client.submit_cancel_job(rec.job_hash, function(payload)
    if rec._cancel_operation_id ~= operation_id then return end
    clear_record_network_job(rec, "cancel")
    rec._cancel_operation_id = nil
    rec._retry_submit = nil
    update_record_http(rec, payload)
    if payload and payload.ok == true then
      rec.cancel_requested = false
      rec.state = "canceled"
      rec.server_status = "canceled"
      rec.cancel_reconcile_pending = false
      rec.cancel_non_retriable = true
      rec.failed_stage = nil
      rec.error_text = ""
      rec.last_message = t("Remote job canceled.")
      TelemetryBridge.finish_record_stage_ok(rec, "cancel", {
        request_label = "mvsep_neurocast_cancel",
        http_code = payload.http_code
      })
      return
    end

    rec.cancel_requested = false
    local message = tostring(payload and payload.error or t("Remote cancellation failed."))
    if payload and (payload.outcome_uncertain == true or tostring(payload.mutation_outcome or ""):lower() == "uncertain") then
      rec.cancel_outcome_uncertain = true
      message = t("Cancellation outcome is uncertain; status polling will reconcile the job.") .. " " .. message
    else
      message = t("Cancellation was rejected; status polling will continue.") .. " " .. message
    end
    rec.cancel_reconcile_pending = true
    rec.state = "poll_wait"
    rec.next_poll_at = r.time_precise()
    rec.error_text = message
    rec.last_message = message
    push_warning_once(message)
    TelemetryBridge.finish_record_stage_failed(rec, message, "cancel", {
      request_label = "mvsep_neurocast_cancel",
      http_code = payload and payload.http_code or nil,
      mutation_outcome = payload and payload.mutation_outcome or nil,
      failure_type = payload and payload.failure_type or nil,
      upstream_status = payload and payload.upstream_status or nil,
      correlation_id = payload and payload.correlation_id or nil
    })
  end, {
    keep_output = false,
    read_body = true,
    auth_rec = rec
  })
  if not job then
    if rec._cancel_operation_id == operation_id then
      rec._cancel_operation_id = nil
      rec._retry_submit = nil
      rec.cancel_requested = false
      rec.cancel_reconcile_pending = true
      rec.state = "poll_wait"
      rec.next_poll_at = r.time_precise()
      local message = tostring(submit_err or t("Cancellation request could not start."))
      rec.error_text = message
      rec.last_message = message
      push_warning_once(message)
    end
  else
    set_record_network_job(rec, job, "cancel")
  end
  return job ~= nil, submit_err
end

local function request_cancel_for_record(rec)
  if not can_request_cancel(rec) then
    return false, t("Remote cancellation is available only before processing starts.")
  end

  rec.cancel_requested = true
  if Util.trim(rec.job_hash or "") == "" then
    rec.last_message = t("Cancellation requested. Waiting for job hash...")
    S.status_text = rec.last_message
    return true
  end

  if rec.state == "polling" then
    rec.last_message = t("Cancellation requested. Waiting for status check...")
    S.status_text = rec.last_message
    return true
  end

  return submit_cancel_for_record(rec)
end

local function tick_records(now_t)
  local now_value = tonumber(now_t) or r.time_precise()

  for _, rec in ipairs(S.records) do
    if rec.state == "queued_render" and can_start_more_records() then
      rec.state = "rendering"
      rec.last_message = t("Rendering input...")
      debug_log(
        "render start rec=" .. tostring(rec.id) ..
        " mode=" .. tostring(rec.input_mode or "") ..
        " start=" .. tostring(rec.start_time or "") ..
        " end=" .. tostring(rec.end_time or ""),
        0
      )
      TelemetryBridge.begin_record_stage(rec, "render", {
        render_mode = "time_selection",
        request_label = "mvsep_render_input"
      })
      local ok_render, render_err, render_info = MVSepReaper.render_spec_to_temp(S.paths, rec)
      if not ok_render then
        mark_record_failed(rec, render_err or t("Render failed."))
      else
        rec.input_path = render_info.input_path
        rec.state = "queued_submit"
        rec.last_message = t("Input rendered. Waiting to submit job.")
        debug_log(
          "render complete rec=" .. tostring(rec.id) ..
          " input_path=" .. tostring(rec.input_path or ""),
          0
        )
        TelemetryBridge.finish_record_stage_ok(rec, "render", {
          render_mode = "time_selection",
          input_path = rec.input_path,
          input_size = rec.input_path and Files.file_size(rec.input_path) or nil
        })
      end
    elseif rec.state == "queued_submit" and can_start_more_records() then
      submit_create_for_record(rec)
    elseif rec.state == "poll_wait" and rec.next_poll_at and rec.next_poll_at <= now_value then
      submit_poll_for_record(rec)
    elseif rec.state == "queued_download" and can_start_more_records() then
      submit_download_for_record(rec)
    end
  end
end

refresh_catalog = function(auth_retry, existing_rec)
  if Util.trim(S.access_token or "") == "" then
    S.status_text = S.has_stored_refresh and
      t("Refresh the stored Studio login before refreshing the catalog.") or
      t("Sign in to Studio Neurocast before refreshing the catalog.")
    return false, S.status_text
  end
  if S.catalog_fetch_inflight and auth_retry ~= true then
    return false, t("Catalog refresh is already running.")
  end
  local rec = existing_rec or get_or_create_network_record("refresh_catalog", t("Refresh catalog"))
  if auth_retry ~= true then
    begin_network_record(rec, t("Refreshing MVSEP catalog..."))
    TelemetryBridge.begin_record_stage(rec, "catalog", {
      request_label = "mvsep_neurocast_algorithms",
      scopes = MVSepAPI.DEFAULT_SCOPES
    })
    rec._auth_refresh_used_once = false
  end
  rec._retry_submit = function() return refresh_catalog(true, rec) end
  S.catalog_fetch_inflight = true
  S.status_text = t("Refreshing MVSEP catalog...")
  local job, submit_err = mvsep_client.submit_get_algorithms(MVSepAPI.DEFAULT_SCOPES, function(payload)
    S.catalog_fetch_inflight = false
    rec._retry_submit = nil
    if not payload or payload.ok ~= true then
      local err_text = payload and (payload.api_error or payload.error) or t("Catalog request failed.")
      finish_network_record_failed(rec, err_text, payload and payload.http_code or nil, t("failed"))
      set_last_error(err_text)
      push_warning_once(S.last_api_error)
      TelemetryBridge.finish_record_stage_failed(rec, err_text, "catalog", {
        request_label = "mvsep_get_algorithms",
        http_code = payload and payload.http_code or nil,
        endpoint = payload and payload.endpoint or ""
      })
      return
    end
    remember_active_model_field_values(true)
    rec.last_http_code = payload.http_code
    S.catalog = payload.catalog
    S.catalog_loaded_from_cache = false
    save_catalog_cache(payload.catalog)
    reconcile_selected_model()
    S.status_text = t("Catalog refreshed.")
    local count = type(payload.catalog) == "table" and #(payload.catalog.algorithms or payload.catalog) or 0
    finish_network_record_ok(rec, string.format(t("Catalog refreshed (%d models)."), count), payload.http_code)
    TelemetryBridge.finish_record_stage_ok(rec, "catalog", {
      request_label = "mvsep_get_algorithms",
      http_code = payload.http_code,
      model_count = count,
      catalog_summary = payload.catalog and payload.catalog.summary or nil
    })
  end, {
    keep_output = false,
    auth_rec = rec
  })
  if submit_err then
    S.catalog_fetch_inflight = false
    finish_network_record_failed(rec, submit_err, nil, t("failed"))
    set_last_error(submit_err)
    push_warning_once(submit_err)
    TelemetryBridge.finish_record_stage_failed(rec, submit_err, "catalog", {
      request_label = "mvsep_get_algorithms"
    })
  elseif job then
    set_record_network_job(rec, job, "refresh_catalog")
  end
  return job ~= nil, submit_err
end

local function add_record(rec)
  S.records[#S.records + 1] = rec
  S.status_text = t("Queued.")
  debug_log(
    "record queued rec=" .. tostring(rec and rec.id or "") ..
    " mode=" .. tostring(rec and rec.input_mode or "") ..
    " label=" .. tostring(rec and rec.label or "") ..
    " track=" .. tostring(rec and rec.track_name or "") ..
    " duration=" .. tostring(rec and rec.duration or ""),
    0
  )
end

local function ensure_runtime_ready_for_actions()
  local ok_dirs, dirs_err = MVSepReaper.ensure_runtime_dirs(S.paths)
  if not ok_dirs then
    set_last_error(dirs_err)
    push_warning_once(dirs_err)
    return false
  end

  if Util.trim(S.access_token) == "" then
    set_last_error(t("Studio Neurocast login is required. Sign in or refresh the stored login in Settings."))
    push_warning_once(S.last_api_error)
    return false
  end

  local ok_supported, supported_err = supports_current_model()
  if not ok_supported then
    set_last_error(supported_err)
    push_warning_once(supported_err)
    return false
  end

  local ok_fields, fields_err = validate_current_model_fields()
  if not ok_fields then
    set_last_error(fields_err)
    push_warning_once(fields_err)
    return false
  end

  return true
end

local function enqueue_time_selection()
  local queue_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("mvsep_queue_time_selection", {
    input_mode = "time_selection"
  })
  if not ensure_runtime_ready_for_actions() then
    TelemetryBridge.operation_failed("mvsep_queue_time_selection", {
      safe_message = S.last_api_error
    }, queue_started_at)
    return
  end
  local spec, spec_err = MVSepReaper.validate_time_selection_input()
  if not spec then
    set_last_error(spec_err)
    push_warning_once(spec_err)
    TelemetryBridge.operation_failed("mvsep_queue_time_selection", {
      safe_message = spec_err
    }, queue_started_at)
    return
  end
  if S.free_mode and spec.duration > CFG.free_max_duration_sec then
    local msg = string.format(t("Free mode blocks jobs longer than %d minutes."), math.floor(CFG.free_max_duration_sec / 60))
    set_last_error(msg)
    push_warning_once(msg)
    TelemetryBridge.operation_failed("mvsep_queue_time_selection", {
      safe_message = msg,
      duration_sec = spec.duration
    }, queue_started_at)
    return
  end
  local rec = new_record_from_spec(spec, allocate_display_batch_id(), 1)
  add_record(rec)
  TelemetryBridge.operation_completed("mvsep_queue_time_selection", TelemetryBridge.record_payload(rec), queue_started_at)
end

local function enqueue_regions()
  local queue_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("mvsep_queue_regions", {
    input_mode = "regions"
  })
  if not ensure_runtime_ready_for_actions() then
    TelemetryBridge.operation_failed("mvsep_queue_regions", {
      safe_message = S.last_api_error
    }, queue_started_at)
    return
  end
  local specs, specs_err = MVSepReaper.prepare_region_jobs()
  if not specs then
    set_last_error(specs_err)
    push_warning_once(specs_err)
    TelemetryBridge.operation_failed("mvsep_queue_regions", {
      safe_message = specs_err
    }, queue_started_at)
    return
  end

  local render_specs = {}
  for _, spec in ipairs(specs) do
    if S.free_mode and spec.duration > CFG.free_max_duration_sec then
      push_warning_once(string.format(t("Skipped region over free-mode limit: %s"), tostring(spec.region_name or spec.record_label)))
    else
      render_specs[#render_specs + 1] = spec
    end
  end

  if #render_specs == 0 then
    set_last_error(t("No valid regions were queued."))
    TelemetryBridge.operation_failed("mvsep_queue_regions", {
      safe_message = S.last_api_error,
      source_region_count = #specs,
      queued_region_count = 0
    }, queue_started_at)
    return
  end

  S.status_text = t("Rendering region inputs...")
  debug_log("region bulk render start count=" .. tostring(#render_specs), 0)
  local render_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("mvsep_render_regions", {
    source_region_count = #specs,
    render_region_count = #render_specs
  })
  local ok_render, render_msg, rendered_specs = MVSepReaper.render_region_specs_to_temp(S.paths, render_specs)
  if not ok_render then
    set_last_error(render_msg or t("Region render failed."))
    push_warning_once(S.last_api_error)
    debug_log("region bulk render failed err=" .. tostring(render_msg or ""), 2)
    TelemetryBridge.operation_failed("mvsep_render_regions", {
      safe_message = render_msg or t("Region render failed."),
      source_region_count = #specs,
      render_region_count = #render_specs
    }, render_started_at, "render_failed")
    TelemetryBridge.operation_failed("mvsep_queue_regions", {
      safe_message = render_msg or t("Region render failed."),
      source_region_count = #specs,
      render_region_count = #render_specs
    }, queue_started_at, "render_failed")
    return
  end

  for _, spec in ipairs(rendered_specs or {}) do
    debug_log(
      "region render artifact region=" .. tostring(spec.region_number or "") ..
        " guid=" .. tostring(spec.marker_guid or "") ..
        " name=" .. tostring(spec.region_name or "") ..
        " path=" .. tostring(spec.input_path or "") ..
        " exists=" .. tostring(spec.input_path and r.file_exists(spec.input_path) == true) ..
        " size=" .. tostring(spec.input_path and Files.file_size(spec.input_path) or "") ..
        " non_ascii=" .. tostring(Util.has_non_ascii(spec.input_path or "")) ..
        " path_bytes=" .. tostring(#tostring(spec.input_path or "")),
      0
    )
  end

  local ok_stage, stage_msg, staged_specs =
    MVSepReaper.stage_region_inputs_for_upload(S.paths, rendered_specs)
  if not ok_stage then
    set_last_error(stage_msg or t("Region render failed."))
    push_warning_once(S.last_api_error)
    debug_log("region upload staging failed err=" .. tostring(stage_msg or ""), 2)
    TelemetryBridge.operation_failed("mvsep_render_regions", {
      safe_message = stage_msg or "Region upload staging failed.",
      source_region_count = #specs,
      render_region_count = #render_specs,
      rendered_region_count = #(rendered_specs or {}),
      staging_failed = true
    }, render_started_at, "render_failed")
    TelemetryBridge.operation_failed("mvsep_queue_regions", {
      safe_message = stage_msg or "Region upload staging failed.",
      source_region_count = #specs,
      render_region_count = #render_specs,
      staging_failed = true
    }, queue_started_at, "render_failed")
    return
  end
  rendered_specs = staged_specs

  local queued_records = {}
  local display_batch_id = allocate_display_batch_id()
  for display_batch_order, spec in ipairs(rendered_specs or {}) do
    local staging = type(spec.upload_staging) == "table" and spec.upload_staging or {}
    debug_log(
      "region rendered input region=" .. tostring(spec.region_number or spec.region_index or "") ..
      " guid=" .. tostring(spec.marker_guid or "") ..
      " name=" .. tostring(spec.region_name or "") ..
      " source_path=" .. tostring(spec.render_source_path or "") ..
      " source_size=" .. tostring(staging.source_size or "") ..
      " source_non_ascii=" .. tostring(staging.source_non_ascii == true) ..
      " staged_path=" .. tostring(spec.input_path or "") ..
      " staged_size=" .. tostring(staging.staged_size or "") ..
      " staged_non_ascii=" .. tostring(Util.has_non_ascii(spec.input_path or "")) ..
      " staged_path_bytes=" .. tostring(#tostring(spec.input_path or "")),
      0
    )
    local rec = new_record_from_spec(spec, display_batch_id, display_batch_order)
    queued_records[#queued_records + 1] = {
      record_id = rec.id,
      record_label = rec.label,
      region_name = rec.region_name,
      region_number = rec.region_number,
      input_path = rec.input_path,
      input_size = rec.input_path and Files.file_size(rec.input_path) or nil
    }
    add_record(rec)
  end
  debug_log("region bulk render complete count=" .. tostring(#(rendered_specs or {})), 0)
  if #(rendered_specs or {}) == 0 then
    set_last_error(t("No valid regions were queued."))
    TelemetryBridge.operation_failed("mvsep_render_regions", {
      safe_message = S.last_api_error,
      source_region_count = #specs,
      render_region_count = #render_specs,
      rendered_region_count = 0
    }, render_started_at, "render_failed")
    TelemetryBridge.operation_failed("mvsep_queue_regions", {
      safe_message = S.last_api_error,
      source_region_count = #specs,
      render_region_count = #render_specs,
      queued_record_count = 0
    }, queue_started_at, "render_failed")
    return
  end
  TelemetryBridge.operation_completed("mvsep_render_regions", {
    source_region_count = #specs,
    render_region_count = #render_specs,
    rendered_region_count = #(rendered_specs or {}),
    queued_records = queued_records
  }, render_started_at)
  TelemetryBridge.operation_completed("mvsep_queue_regions", {
    source_region_count = #specs,
    render_region_count = #render_specs,
    queued_record_count = #queued_records,
    queued_records = queued_records
  }, queue_started_at)
end

local function filtered_algorithms()
  local catalog = type(S.catalog) == "table" and S.catalog.algorithms or {}
  local rows = {}
  local needle = Util.trim(S.filter_text):lower()
  for _, algorithm in ipairs(catalog) do
    local sep_type = tostring(algorithm.sep_type or "")
    local is_favorite = (S.favorites[sep_type] == true)
    if (not S.favorites_only) or is_favorite then
      local haystack = table.concat({
        tostring(algorithm.name or ""),
        tostring(algorithm.group_name or ""),
        tostring(algorithm.description or "")
      }, " "):lower()
      if needle == "" or haystack:find(needle, 1, true) then
        rows[#rows + 1] = algorithm
      end
    end
  end

  table.sort(rows, function(a, b)
    local af = S.favorites[tostring(a.sep_type or "")] == true
    local bf = S.favorites[tostring(b.sep_type or "")] == true
    if af ~= bf then return af end
    if a.supported_v1 ~= b.supported_v1 then return a.supported_v1 == true end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return rows
end

local function status_summary()
  local counts = {
    queued = 0,
    running = 0,
    ready = 0,
    failed = 0
  }
  for _, rec in ipairs(S.records) do
    if rec.state == "ready" then
      counts.ready = counts.ready + 1
    elseif rec.state == "failed" then
      counts.failed = counts.failed + 1
    elseif is_running_state(rec.state) or rec.state == "poll_wait" then
      counts.running = counts.running + 1
    else
      counts.queued = counts.queued + 1
    end
  end
  for _, rec in ipairs(S.network_records or {}) do
    if rec.state == "ready" then
      counts.ready = counts.ready + 1
    elseif rec.state == "failed" then
      counts.failed = counts.failed + 1
    elseif rec.state == "running" then
      counts.running = counts.running + 1
    else
      counts.queued = counts.queued + 1
    end
  end
  return {
    counts = counts,
    status_line = string.format(
      t("%d queued | %d running | %d ready | %d failed"),
      counts.queued,
      counts.running,
      counts.ready,
      counts.failed
    )
  }
end

local function render_status_panel(ctx_to_show, id_suffix)
  local ctx_ref = ctx_to_show or ctx
  local suffix = tostring(id_suffix or "")
  ImGui.PushFont(ctx_ref, FONT, font_size)

  local summary = status_summary()
  local counts = summary.counts
  local has_failed = counts.failed > 0 or Util.is_non_empty(S.last_api_error)
  local has_in_process = counts.running > 0 or counts.queued > 0
  if has_failed then
    ImGui.PushStyleColor(ctx_ref, ImGui.Col_Text, 0xFF0000FF)
  elseif has_in_process then
    ImGui.PushStyleColor(ctx_ref, ImGui.Col_Text, 0x66CCFFFF)
  else
    ImGui.PushStyleColor(ctx_ref, ImGui.Col_Text, 0x00FF00FF)
  end
  ImGui.Text(ctx_ref, string.format(t("Status: %s"), summary.status_line))
  ImGui.PopStyleColor(ctx_ref)

  local last_status = S.status_text ~= "" and S.status_text or t("(none)")
  ImGui.TextWrapped(ctx_ref, string.format(t("Last status: %s"), last_status))

  ImGui.PushStyleVar(ctx_ref, ImGui.StyleVar_SeparatorTextAlign, 0.15, 0.5)
  ImGui.SeparatorText(ctx_ref, t("Warnings"))
  ImGui.PopStyleVar(ctx_ref)
  if #S.warnings == 0 then
    ImGui.TextWrapped(ctx_ref, t("None. Looks good!"))
  else
    for _, warning_text in ipairs(S.warnings) do
      ImGui.TextWrapped(ctx_ref, tostring(warning_text))
    end
  end

  if UI_button_clicked("clear_warnings" .. suffix, t("Clear warnings"), nil, ctx_ref) then
    S.warnings = {}
  end
  ImGui.SameLine(ctx_ref)
  if UI_button_clicked("copy_warnings" .. suffix, t("Copy warnings to clipboard"), nil, ctx_ref) then
    ImGui.SetClipboardText(ctx_ref, table.concat(S.warnings or {}, "\n"))
  end

  ImGui.PopFont(ctx_ref)
end

local function render_status_window()
  ImGui.SetNextWindowSize(ctx_status, 560, 340, ImGui.Cond_FirstUseEver)
  if not S.show_status_window then return end
  local visible = ImGui.Begin(ctx_status, current_status_window_label(), nil, ImGui.WindowFlags_NoTitleBar)
  if visible then
    render_status_panel(ctx_status, "_status")
    ImGui.End(ctx_status)
  end
end

local function render_run_controls_section()
  ImGui.Spacing(ctx)

  local changed_free, new_free = ImGui.Checkbox(ctx, t("Free mode"), S.free_mode)
  if changed_free then
    S.free_mode = new_free
    if S.free_mode then S.region_concurrency = 1 end
    persist_boolean(EXTSTATE.free_mode, S.free_mode)
    persist_plain(EXTSTATE.region_concurrency, tostring(S.region_concurrency))
  end

  ImGui.Text(ctx, t("Input mode") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 220)
  local mode_label = S.input_mode == "regions" and t("Track + project regions") or t("Track + time selection")
  if ImGui.BeginCombo(ctx, "##mvsep_input_mode", mode_label, ImGui.ComboFlags_HeightRegular) then
    local modes = {
      { id = "time_selection", label = t("Track + time selection") },
      { id = "regions", label = t("Track + project regions") }
    }
    for _, mode in ipairs(modes) do
      local is_selected = (S.input_mode == mode.id)
      if ImGui.Selectable(ctx, mode.label, is_selected) then
        S.input_mode = mode.id
        persist_plain(EXTSTATE.input_mode, mode.id)
      end
      if is_selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  ImGui.Text(ctx, t("Region concurrency") .. ":")
  ImGui.SameLine(ctx)
  local avail_w = 800
  if ImGui.GetContentRegionAvail then
    avail_w = select(1, ImGui.GetContentRegionAvail(ctx)) or avail_w
  end
  local concurrency_w = math.max(80, math.min(160, avail_w * 0.15))
  ImGui.SetNextItemWidth(ctx, concurrency_w)
  local concurrency_disabled = (S.free_mode == true) or (S.input_mode ~= "regions")
  if concurrency_disabled then ImGui.BeginDisabled(ctx, true) end
  local changed_concurrency, new_concurrency = ImGui.InputInt(ctx, "##mvsep_concurrency", S.region_concurrency, 1, 1)
  if concurrency_disabled then ImGui.EndDisabled(ctx) end
  if changed_concurrency then
    local normalized = math.floor(tonumber(new_concurrency) or 1)
    if normalized < 1 then normalized = 1 end
    if normalized > CFG.max_paid_concurrency then normalized = CFG.max_paid_concurrency end
    if S.free_mode then normalized = 1 end
    S.region_concurrency = normalized
    persist_plain(EXTSTATE.region_concurrency, tostring(normalized))
  end

  ImGui.Text(ctx, t("Output format") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 180)
  local format_label = S.output_format_name
  if ImGui.BeginCombo(ctx, "##mvsep_output_format", format_label, ImGui.ComboFlags_HeightRegular) then
    for format_name, row in pairs(MVSepAPI.OUTPUT_FORMATS) do
      local label = string.format("%s (%s)", format_name, tostring(row.label or ""))
      local is_selected = (S.output_format_name == format_name)
      if ImGui.Selectable(ctx, label, is_selected) then
        S.output_format_name = format_name
        persist_plain(EXTSTATE.output_format_name, format_name)
      end
      if is_selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
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

local function render_diagnostics_settings()
  local diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Logging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, "##mvsep_logging_threshold", diagnostics_threshold_label(diagnostics.logging_threshold), ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ 4, 0, 1, 2, 3 }) do
      local selected = diagnostics.logging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_logging_threshold(level)
        if not ok_set then push_warning_once(string.format(t("Logging threshold save failed: %s"), tostring(err))) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Messaging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, "##mvsep_messaging_threshold", diagnostics_threshold_label(diagnostics.messaging_threshold), ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ 0, 1, 2, 3, 4 }) do
      local selected = diagnostics.messaging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_messaging_threshold(level)
        if not ok_set then push_warning_once(string.format(t("Messaging threshold save failed: %s"), tostring(err))) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  ImGui.TextWrapped(ctx, string.format(t("Log folder: %s"), diagnostics.log_dir))
  ImGui.TextWrapped(ctx, string.format(
    t("Current log file: %s"),
    diagnostics.current_log_file ~= "" and diagnostics.current_log_file or t("(created after the first matching message)")
  ))
  if UI_button_clicked("copy_diagnostics_log_folder_btn", t("Copy log folder"), 0.2) then
    ImGui.SetClipboardText(ctx, diagnostics.log_dir)
  end
  ImGui.TextWrapped(ctx, t("Local logs may contain project paths, filenames, and workflow content."))
  if diagnostics.messaging_threshold == 4 then
    ImGui.TextWrapped(ctx, t("Messaging is Off. Util-driven errors may be hidden."))
  end
end

local function render_telemetry_level_setting()
  local desc = TelemetryBridge.describe_status()
  local current_level = tostring(desc.effective_level or "support")
  local current_level_label = TelemetryBridge.level_label(current_level)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, t("Telemetry level") .. "##mvsep_telemetry_level", current_level_label, ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ "basic", "support", "debug" }) do
      local selected = current_level == level
      local level_label = TelemetryBridge.level_label(level)
      if ImGui.Selectable(ctx, level_label, selected) then
        local ok_call, ok_set, set_or_err = pcall(Telemetry.set_level, level)
        if ok_call and ok_set then
          S.telemetry_ui_status = string.format(t("Telemetry level set to %s."), level_label)
          TelemetryBridge.safe_event("feature_used", {
            operation = "mvsep_telemetry_settings",
            status = "level_changed",
            telemetry_level = level
          }, {
            operation = "mvsep_telemetry_settings",
            status = "level_changed"
          })
        else
          local err = ok_call and set_or_err or ok_set
          S.telemetry_ui_status = string.format(t("Telemetry level save failed: %s"), tostring(err))
          push_warning_once(S.telemetry_ui_status)
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

local function render_settings_section()
  if not ImGui.CollapsingHeader(ctx, t("Settings")) then
    return
  end

  ImGui.SeparatorText(ctx, t("Studio Neurocast account"))
  local backend_class, backend_host = MVSepViaNeurocast.classify_base_url(Backend.active_base_url())
  local backend_class_text = backend_class
  if backend_class == "production" then
    backend_class_text = t("production")
  elseif backend_class == "development" then
    backend_class_text = t("development")
  elseif backend_class == "custom" then
    backend_class_text = t("custom")
  end
  ImGui.TextWrapped(ctx, string.format(t("Active backend: %s (%s)"), backend_class_text, backend_host))

  local dev_enabled = backend_class == "development"
  local changed_dev, next_dev = ImGui.Checkbox(ctx, t("Use localhost development backend"), dev_enabled)
  if changed_dev then
    Util.extstate_delete(EXTSTATE.auth_section, EXTSTATE.auth_refresh, true)
    persist_auth_backend("")
    Backend.set_development_enabled(next_dev)
  end
  if dev_enabled then
    ImGui.TextWrapped(ctx, t("Development mode is active. Requests go only to http://localhost:3002."))
  end

  local changed_email, next_email = ImGui.InputText(ctx, "##mvsep_neurocast_email", S.email or "")
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Email"))
  if changed_email then
    S.email = next_email
    persist_auth_email(next_email)
  end

  local pass_flags = ImGui.InputTextFlags_Password
  local changed_password, next_password = ImGui.InputText(ctx, "##mvsep_neurocast_password", S.password or "", pass_flags)
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Password"))
  if changed_password then S.password = next_password end

  local changed_remember, next_remember = ImGui.Checkbox(ctx, t("Remember login"), S.remember_login)
  if changed_remember then
    S.remember_login = next_remember
    Backend.reset_clients()
    if not next_remember then
      Auth.client().forget_refresh_token()
      persist_auth_backend("")
      S.has_stored_refresh = false
    elseif Util.trim(S.refresh_token or "") ~= "" then
      Auth.client().persist_refresh_token(S.refresh_token)
      persist_auth_backend(Backend.active_base_url())
      S.has_stored_refresh = true
    end
  end

  local auth_disabled = S.auth_request_inflight == true
  if auth_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI_button_clicked("studio_login", t("Log in")) then
    local ok_login, login_err = Auth.submit_login()
    if not ok_login and login_err then push_warning_once(login_err) end
  end
  ImGui.SameLine(ctx)
  if UI_button_clicked("studio_refresh", t("Refresh stored login")) then
    local ok_refresh, refresh_err = Auth.queue_refresh(function()
      refresh_catalog()
    end, function(payload)
      push_warning_once(tostring(payload and (payload.api_error or payload.error) or t("Login refresh failed.")))
    end)
    if not ok_refresh and refresh_err then push_warning_once(refresh_err) end
  end
  ImGui.SameLine(ctx)
  if UI_button_clicked("studio_logout", t("Log out")) then
    local ok_logout, logout_err = Auth.submit_logout()
    if not ok_logout and logout_err then push_warning_once(logout_err) end
  end
  ImGui.SameLine(ctx)
  if UI_button_clicked("studio_forget", t("Forget stored login")) then
    Auth.forget_stored_login()
  end
  if auth_disabled then ImGui.EndDisabled(ctx) end
  ImGui.TextWrapped(ctx, string.format(t("Login status: %s"), tostring(S.auth_status or "")))

  ImGui.SeparatorText(ctx, t("Paths"))
  local project_path = S.paths and S.paths.project_path or ""
  if project_path == "" then
    ImGui.TextWrapped(ctx, t("Project path not available (unsaved project?). Some features may be limited."))
  else
    ImGui.TextWrapped(ctx, tostring(project_path))
  end
  if S.paths then
    ImGui.TextWrapped(ctx, string.format(t("tmp: %s"), tostring(S.paths.tmp_dir)))
    ImGui.TextWrapped(ctx, string.format(t("results: %s"), tostring(S.paths.results_dir)))
    ImGui.TextWrapped(ctx, string.format(t("cache: %s"), tostring(S.paths.cache_file)))
  end

  ImGui.SeparatorText(ctx, t("Diagnostics"))
  render_diagnostics_settings()
  ImGui.SeparatorText(ctx, t("Telemetry"))
  render_telemetry_level_setting()
end

local function render_catalog_section()
  if not ImGui.CollapsingHeader(ctx, t("Model selection")) then
    return
  end

  if UI_button_clicked("refresh_catalog_btn", t("Refresh catalog")) then
    TelemetryBridge.button_clicked("refresh_catalog_btn", t("Refresh catalog"))
    refresh_catalog()
  end
  ImGui.SameLine(ctx)
  if UI_button_clicked("reset_remembered_model_options_btn", t("Reset all remembered model options")) then
    reset_remembered_model_options()
  end
  ImGui.SameLine(ctx)
  local changed_favs_only, new_favs_only = ImGui.Checkbox(ctx, t("Favorites only"), S.favorites_only)
  if changed_favs_only then
    S.favorites_only = new_favs_only
    persist_boolean(EXTSTATE.favorites_only, new_favs_only)
  end

  local changed_filter, new_filter = ImGui.InputText(ctx, "##mvsep_filter_text", S.filter_text or "")
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Filter models"))
  if changed_filter then
    S.filter_text = new_filter
    persist_plain(EXTSTATE.filter_text, new_filter)
  end

  local rows = filtered_algorithms()
  local child_flags = ImGui.ChildFlags_FrameStyle | ImGui.ChildFlags_Borders
  local child_open = ImGui.BeginChild(ctx, "##mvsep_catalog_list", 360, 220, child_flags)
  if child_open then
    if #rows == 0 then
      ImGui.TextWrapped(ctx, t("No models match the current filter."))
    end
    for _, algorithm in ipairs(rows) do
      local sep_type = tostring(algorithm.sep_type or "")
      local is_selected = (S.selected_model_sep_type == sep_type)
      local star_label = S.favorites[sep_type] and "[*]" or "[ ]"
      if ImGui.Selectable(ctx, star_label .. " " .. tostring(algorithm.name or ""), is_selected) then
        remember_active_model_field_values()
        set_selected_model(sep_type)
        reconcile_selected_model()
      end
    end
    ImGui.EndChild(ctx)
  end

  ImGui.SameLine(ctx)
  local model = ensure_selected_model()
  local details_open = ImGui.BeginChild(ctx, "##mvsep_catalog_details", 0, 220, child_flags)
  if details_open then
    if not model then
      ImGui.TextWrapped(ctx, t("Catalog is empty."))
    else
      local sep_type = tostring(model.sep_type or "")
      ImGui.TextWrapped(ctx, tostring(model.name or ""))
      ImGui.TextWrapped(ctx, model_display_description(model))
      local fav_label = S.favorites[sep_type] and t("Remove from favorites") or t("Add to favorites")
      if UI_button_clicked("toggle_favorite_" .. sep_type, fav_label) then
        if S.favorites[sep_type] then
          S.favorites[sep_type] = nil
        else
          S.favorites[sep_type] = true
        end
        persist_json(EXTSTATE.favorites_json, S.favorites)
      end
      if model.supported_v1 ~= true then
        ImGui.TextWrapped(ctx, tostring(model.unsupported_reason or t("Unsupported.")))
      end
      for _, field in ipairs(model.fields or {}) do
        ImGui.Separator(ctx)
        ImGui.Text(ctx, tostring(field.label or field.form_key))
        if field.input_type == "select" then
          local current_value = tostring(S.model_field_values[field.form_key] or "")
          local options = MVSepAPI.sort_option_entries(field.options or {})
          local preview = current_value
          for _, option in ipairs(options) do
            if option.key == current_value then
              preview = option.label
              break
            end
          end
          if ImGui.BeginCombo(ctx, "##" .. tostring(field.form_key), preview, ImGui.ComboFlags_HeightRegular) then
            for _, option in ipairs(options) do
              local is_selected = (current_value == option.key)
              if ImGui.Selectable(ctx, tostring(option.label), is_selected) then
                S.model_field_values[field.form_key] = option.key
                remember_active_model_field_values()
              end
              if is_selected then ImGui.SetItemDefaultFocus(ctx) end
            end
            ImGui.EndCombo(ctx)
          end
        elseif field.input_type == "textarea" then
          local changed, new_value = ImGui.InputTextMultiline(ctx, "##" .. tostring(field.form_key), tostring(S.model_field_values[field.form_key] or ""), -1, 70)
          if changed then
            S.model_field_values[field.form_key] = new_value
            remember_active_model_field_values()
          end
        else
          local changed, new_value = ImGui.InputText(ctx, "##" .. tostring(field.form_key), tostring(S.model_field_values[field.form_key] or ""))
          if changed then
            S.model_field_values[field.form_key] = new_value
            remember_active_model_field_values()
          end
        end
      end
    end
    ImGui.EndChild(ctx)
  end
end

local queue_table_last_debug_signature = nil

local function queue_utility_row_is_visible(rec)
  if type(rec) ~= "table" then return false end
  return tostring(rec.state or "") ~= "ready"
end

local function build_queue_display_rows()
  local rows = {}
  local hidden_utility_rows = 0

  for index, rec in ipairs(S.network_records or {}) do
    if queue_utility_row_is_visible(rec) then
      rows[#rows + 1] = {
        kind = "network",
        rec = rec,
        batch_id = tonumber(rec.display_batch_id) or 0,
        batch_order = tonumber(rec.display_batch_order) or index,
        stable_order = index
      }
    else
      hidden_utility_rows = hidden_utility_rows + 1
    end
  end

  for index, rec in ipairs(S.records or {}) do
    rows[#rows + 1] = {
      kind = "record",
      rec = rec,
      batch_id = tonumber(rec.display_batch_id) or tonumber(rec.id) or 0,
      batch_order = tonumber(rec.display_batch_order) or index,
      stable_order = index
    }
  end

  table.sort(rows, function(a, b)
    if a.batch_id ~= b.batch_id then
      return a.batch_id > b.batch_id
    end
    if a.batch_order ~= b.batch_order then
      return a.batch_order < b.batch_order
    end
    if a.kind ~= b.kind then
      return a.kind == "network"
    end
    return a.stable_order < b.stable_order
  end)

  return rows, hidden_utility_rows
end

local function log_queue_table_layout(rows, hidden_utility_rows, height_mode)
  local signature_order_parts = {}
  local logged_order_parts = {}
  for _, row in ipairs(rows) do
    local rec = row.rec or {}
    local key
    if row.kind == "network" then
      key = "n:" .. tostring(rec.network_key or "")
    else
      key = "r:" .. tostring(rec.id or "")
    end
    local part = key ..
      "@b" .. tostring(row.batch_id or "") ..
      "." .. tostring(row.batch_order or "")
    signature_order_parts[#signature_order_parts + 1] = part
    if #logged_order_parts < 20 then
      logged_order_parts[#logged_order_parts + 1] = part
    end
  end
  if #signature_order_parts > #logged_order_parts then
    logged_order_parts[#logged_order_parts + 1] =
      "...+" .. tostring(#signature_order_parts - #logged_order_parts)
  end

  local signature = table.concat({
    tostring(#rows),
    tostring(hidden_utility_rows or 0),
    tostring(height_mode or ""),
    table.concat(signature_order_parts, ",")
  }, "|")
  if signature == queue_table_last_debug_signature then return end
  queue_table_last_debug_signature = signature

  debug_log(
    "[queue-table] visible=" .. tostring(#rows) ..
      " hidden_successful_utility=" .. tostring(hidden_utility_rows or 0) ..
      " height_mode=" .. tostring(height_mode or "") ..
      " order=" .. table.concat(logged_order_parts, ","),
    0
  )
end

local function render_queue_section()
  ImGui.SeparatorText(ctx, t("Queue"))

  local queue_disabled = not selected_model()
  if queue_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI_button_clicked("queue_action_btn", S.input_mode == "regions" and t("Queue all project regions") or t("Queue track + time selection")) then
    TelemetryBridge.button_clicked("queue_action_btn", S.input_mode == "regions" and t("Queue all project regions") or t("Queue track + time selection"))
    if S.input_mode == "regions" then
      enqueue_regions()
    else
      enqueue_time_selection()
    end
  end
  if queue_disabled then ImGui.EndDisabled(ctx) end

  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, t("Table rendering not available in this ImGui build."))
    return
  end

  local display_rows, hidden_utility_rows = build_queue_display_rows()
  if #display_rows == 0 then
    log_queue_table_layout(display_rows, hidden_utility_rows, "empty")
    ImGui.TextWrapped(ctx, t("No requests yet."))
    return
  end

  local capped_height = #display_rows > 8
  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable
  local table_height = 0
  local height_mode = "natural:" .. tostring(#display_rows)
  if capped_height then
    table_flags = table_flags | ImGui.TableFlags_ScrollY
    local line_height = ImGui.GetTextLineHeightWithSpacing and ImGui.GetTextLineHeightWithSpacing(ctx)
      or (ImGui.GetTextLineHeight and ImGui.GetTextLineHeight(ctx))
      or 20
    table_height = line_height * 10
    height_mode = "capped:8"
  end
  log_queue_table_layout(display_rows, hidden_utility_rows, height_mode)

  if ImGui.BeginTable(ctx, "##mvsep_records_table", 6, table_flags, -1, table_height) then
    ImGui.TableSetupColumn(ctx, t("State"), ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, t("Record"), ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx, t("Model"), ImGui.TableColumnFlags_WidthFixed, 170)
    ImGui.TableSetupColumn(ctx, t("Progress"), ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx, t("HTTP"), ImGui.TableColumnFlags_WidthFixed, 50)
    ImGui.TableSetupColumn(ctx, t("Actions"), ImGui.TableColumnFlags_WidthFixed, 190)
    ImGui.TableHeadersRow(ctx)

    for _, row in ipairs(display_rows) do
      local rec = row.rec
      if row.kind == "network" then
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.TextWrapped(ctx, record_state_label(rec.state))
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.TextWrapped(ctx, tostring(rec.label or ""))
        ImGui.TableSetColumnIndex(ctx, 2)
        ImGui.TextWrapped(ctx, tostring(rec.model_name or "-"))
        ImGui.TableSetColumnIndex(ctx, 3)
        ImGui.TextWrapped(ctx, network_record_progress_text(rec))
        ImGui.TableSetColumnIndex(ctx, 4)
        ImGui.Text(ctx, rec.last_http_code and tostring(rec.last_http_code) or "-")
        ImGui.TableSetColumnIndex(ctx, 5)
        ImGui.Text(ctx, "-")
      else
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.TextWrapped(ctx, record_state_label(rec.state))
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.TextWrapped(ctx, tostring(rec.label or ""))
        ImGui.TableSetColumnIndex(ctx, 2)
        ImGui.TextWrapped(ctx, tostring(rec.model_name or ""))
        ImGui.TableSetColumnIndex(ctx, 3)
        ImGui.TextWrapped(ctx, record_progress_text(rec))
        ImGui.TableSetColumnIndex(ctx, 4)
        ImGui.Text(ctx, rec.last_http_code and tostring(rec.last_http_code) or "-")
        ImGui.TableSetColumnIndex(ctx, 5)
        if can_retry_record(rec) then
          if UI_button_clicked("retry_" .. tostring(rec.id), t("Retry"), nil, ctx) then
            TelemetryBridge.button_clicked("retry_" .. tostring(rec.id), t("Retry"))
            local ok_retry, retry_err = retry_record(rec)
            if not ok_retry then
              set_last_error(retry_err or t("Retry failed."))
              push_warning_once(S.last_api_error)
            end
          end
        else
          if can_request_cancel(rec) then
            if UI_button_clicked("cancel_remote_" .. tostring(rec.id), t("Cancel remote job"), nil, ctx) then
              TelemetryBridge.button_clicked("cancel_remote_" .. tostring(rec.id), t("Cancel remote job"))
              local ok_cancel, cancel_err = request_cancel_for_record(rec)
              if not ok_cancel and cancel_err then
                set_last_error(cancel_err)
                push_warning_once(cancel_err)
              end
            end
            ImGui.SameLine(ctx)
          end
          local add_disabled = rec.state ~= "ready" or rec.imported == true
          if add_disabled then ImGui.BeginDisabled(ctx, true) end
          if UI_button_clicked("add_to_project_" .. tostring(rec.id), t("Add to project"), nil, ctx) then
            TelemetryBridge.button_clicked("add_to_project_" .. tostring(rec.id), t("Add to project"))
            TelemetryBridge.begin_record_stage(rec, "import", {
              request_label = "mvsep_add_to_project"
            })
            local ok_add, add_err = MVSepReaper.import_downloads_to_bottom(rec)
            if not ok_add then
              TelemetryBridge.finish_record_stage_failed(rec, add_err, "import", {
                request_label = "mvsep_add_to_project"
              })
              mark_record_failed(rec, add_err)
            else
              rec.imported = true
              rec.last_message = t("Added to project.")
              TelemetryBridge.finish_record_stage_ok(rec, "import", {
                request_label = "mvsep_add_to_project"
              })
            end
          end
          if add_disabled then ImGui.EndDisabled(ctx) end

          if rec.job_hash and rec.state == "ready" then
            ImGui.SameLine(ctx)
            local delete_disabled = rec.remote_removed == true
              or rec._delete_operation_id ~= nil
              or rec.remote_delete_uncertain == true
              or not all_downloads_complete(rec)
              or rec.created_by_this_tool ~= true
            if delete_disabled then ImGui.BeginDisabled(ctx, true) end
            if UI_button_clicked("delete_remote_" .. tostring(rec.id), t("Delete remote files"), nil, ctx) then
              TelemetryBridge.button_clicked("delete_remote_" .. tostring(rec.id), t("Delete remote files"))
              local ok_delete, delete_err = submit_delete_for_record(rec)
              if not ok_delete and delete_err then
                set_last_error(delete_err)
                push_warning_once(delete_err)
              end
            end
            if delete_disabled then ImGui.EndDisabled(ctx) end
          end
        end
      end
    end

    ImGui.EndTable(ctx)
  end
end

local function render_telemetry_section()
  local desc = TelemetryBridge.describe_status()
  local header_state = TelemetryBridge.header_state(desc)
  local header_label = string.format(t("Telemetry (%s)"), header_state) .. "###mvsep_telemetry_section"
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  local telemetry_open = ImGui.CollapsingHeader(ctx, header_label)
  ImGui.PopStyleColor(ctx)
  if not telemetry_open then
    return
  end

  local progress = TelemetryBridge.progress_text(desc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  ImGui.TextWrapped(ctx, string.format(t("Telemetry status: %s"), tostring(desc.status or "")))
  ImGui.PopStyleColor(ctx)
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, string.format(t("Telemetry progress: %s"), progress))
  else
    local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "##mvsep_telemetry_status_table", 2, flags, -1, 0) then
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

  if Util.trim(S.telemetry_ui_status or "") ~= "" then
    ImGui.TextWrapped(ctx, S.telemetry_ui_status)
  end

  local flush_disabled = desc.active_job_id ~= nil
  if flush_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI_button_clicked("telemetry_flush_now_btn", t("Flush telemetry now"), 0.2) then
    TelemetryBridge.button_clicked("telemetry_flush_now_btn", t("Flush telemetry now"))
    TelemetryBridge.safe_flush_async("mvsep_manual")
  end
  if flush_disabled then ImGui.EndDisabled(ctx) end

  if desc.send_paused then
    ImGui.SameLine(ctx)
    if UI_button_clicked("telemetry_resume_btn", t("Resume telemetry sending"), 0.2) then
      TelemetryBridge.button_clicked("telemetry_resume_btn", t("Resume telemetry sending"))
      local ok_resume, resume_or_err = pcall(Telemetry.resume_sending, t("manual resume from MVSep UI"))
      S.telemetry_ui_status = ok_resume and t("Telemetry sending resumed.") or string.format(t("Telemetry resume failed: %s"), tostring(resume_or_err))
    end
  end

  ImGui.SameLine(ctx)
  if UI_button_clicked("telemetry_copy_paths_btn", t("Copy telemetry paths"), 0.2) then
    local paths = desc.paths or {}
    ImGui.SetClipboardText(ctx, table.concat({
      string.format(t("settings_path: %s"), tostring(desc.settings_path or "")),
      string.format(t("queue_path: %s"), tostring(desc.queue_path or "")),
      string.format(t("runtime_root: %s"), tostring(paths.root or "")),
      string.format(t("queues: %s"), tostring(paths.queues or "")),
      string.format(t("sending: %s"), tostring(paths.sending or "")),
      string.format(t("failed: %s"), tostring(paths.failed or "")),
      string.format(t("logs: %s"), tostring(paths.logs or "")),
      string.format(t("close_send: %s"), tostring(paths.close_send or ""))
    }, "\n"))
    S.telemetry_ui_status = t("Telemetry paths copied.")
  end

  local budget = desc.budget_limits or {}
  local details = {
    string.format(t("initialized: %s"), tostring(desc.initialized == true)),
    string.format(t("settings_path: %s"), tostring(desc.settings_path or "")),
    string.format(t("queue_path: %s"), tostring(desc.queue_path or "")),
    string.format(t("runtime_root: %s"), tostring(desc.paths and desc.paths.root or "")),
    string.format(t("effective_level: %s"), tostring(desc.effective_level or "")),
    string.format(t("send_paused: %s"), tostring(desc.send_paused == true)),
    string.format(t("send_pause_reason: %s"), tostring(desc.send_pause_reason or "")),
    string.format(t("active_job_id: %s"), tostring(desc.active_job_id or "")),
    string.format(t("active_source_file: %s"), tostring(desc.active_source_file or "")),
    string.format(t("queued_file_count: %s"), tostring(desc.queued_file_count or 0)),
    string.format(t("sending_file_count: %s"), tostring(desc.sending_file_count or 0)),
    string.format(t("failed_file_count: %s"), tostring(desc.failed_file_count or 0)),
    string.format(t("close_send_file_count: %s"), tostring(desc.close_send_file_count or 0)),
    string.format(t("current_queue_bytes: %s"), tostring(desc.current_queue_bytes or 0)),
    string.format(t("sendable_queue_bytes: %s"), tostring(desc.sendable_queue_bytes or 0)),
    string.format(t("budget_soft_events: %s"), tostring(budget.soft_events_per_session or "")),
    string.format(t("budget_hard_events: %s"), tostring(budget.hard_events_per_session or "")),
    string.format(t("budget_reserved_events: %s"), tostring(budget.reserved_events or "")),
    string.format(t("budget_queue_soft_bytes: %s"), tostring(budget.sendable_queue_soft_max_bytes or "")),
    string.format(t("queued_events_session: %s"), tostring(desc.queued_events_session or 0)),
    string.format(t("flushed_events_session: %s"), tostring(desc.flushed_events_session or 0)),
    string.format(t("failed_batches_session: %s"), tostring(desc.failed_batches_session or 0)),
    string.format(t("dropped_events_session: %s"), tostring(desc.dropped_events_session or 0)),
    string.format(t("skipped_events_session: %s"), tostring(desc.skipped_events_session or 0)),
    string.format(t("last_flush_at: %s"), tostring(desc.last_flush_at or "")),
    string.format(t("last_http_code: %s"), tostring(desc.last_http_code or "")),
    string.format(t("last_curl_exitcode: %s"), tostring(desc.last_curl_exitcode or "")),
    string.format(t("last_backend_error: %s"), tostring(desc.last_backend_error or "")),
    string.format(t("last_error: %s"), tostring(desc.last_error or ""))
  }
  ImGui.InputTextMultiline(ctx, "##mvsep_telemetry_details", table.concat(details, "\n"), -1, 180, ImGui.InputTextFlags_ReadOnly)
end

local function render_details_section()
  if not ImGui.CollapsingHeader(ctx, t("Details (errors, status)")) then
    return
  end
  local flags = ImGui.InputTextFlags_ReadOnly
  ImGui.InputTextMultiline(ctx, "##mvsep_errbox", S.last_api_error or "", 0, 120, flags)

  local last_curl = S.last_curl_return or {}
  local curl_lines = table.concat({
    string.format(t("ok: %s"), tostring(last_curl.ok)),
    string.format(t("http: %s"), tostring(last_curl.http)),
    string.format(t("body: %s"), tostring(Util.head32(tostring(last_curl.body or "")))),
    string.format(t("headers: %s"), tostring(Util.head32(tostring(last_curl.headers_txt or "")))),
    string.format(t("meta: %s"), tostring(Util.head32(tostring(last_curl.meta or "")))),
    string.format(t("err: %s"), tostring(last_curl.err or "")),
    string.format(t("cmd: %s"), tostring(last_curl.cmd or ""))
  }, "\n")
  ImGui.InputTextMultiline(ctx, "##mvsep_last_curl", curl_lines, 0, 120, flags)
end

local function gui_loop()
  local now_t = r.time_precise()
  TelemetryBridge.safe_tick(now_t)
  Jobs.tick_all(now_t)
  tick_records(now_t)
  render_status_window()

  ImGui.SetNextWindowSize(ctx, 1180, 900, ImGui.Cond_FirstUseEver)
  prepare_main_window_before_begin()
  local visible, open = ImGui.Begin(ctx, current_main_window_label(), true)
  observe_main_window_after_begin(visible)
  if visible then
    ImGui.PushFont(ctx, FONT, font_size)

    ImGui.Text(ctx, t("Language") .. ":")
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 140)
    local locale_disabled = not translated_locale_available("rus")
    if locale_disabled then ImGui.BeginDisabled(ctx, true) end
    if ImGui.BeginCombo(ctx, "##mvsep_locale", locale_display_name(active_locale), ImGui.ComboFlags_HeightRegular) then
      local options = { "eng" }
      if translated_locale_available("rus") then options[#options + 1] = "rus" end
      for _, locale_id in ipairs(options) do
        local is_selected = (active_locale == locale_id)
        if ImGui.Selectable(ctx, locale_display_name(locale_id), is_selected) then
          set_active_runtime_locale(locale_id)
          persist_locale(locale_id)
        end
        if is_selected then ImGui.SetItemDefaultFocus(ctx) end
      end
      ImGui.EndCombo(ctx)
    end
    if locale_disabled then ImGui.EndDisabled(ctx) end

    ImGui.SameLine(ctx)
    local changed_show_status, new_show_status = ImGui.Checkbox(ctx, t("Show status in dedicated window"), S.show_status_window)
    if changed_show_status then
      S.show_status_window = new_show_status
      persist_show_status_window(new_show_status)
      TelemetryBridge.safe_event("feature_used", {
        operation = "mvsep_status_window_toggle",
        status = new_show_status and "enabled" or "disabled",
        show_status_window = new_show_status == true
      }, {
        operation = "mvsep_status_window_toggle",
        status = new_show_status and "enabled" or "disabled"
      })
    end

    if not S.show_status_window then
      render_status_panel(ctx, "_inline")
    end

    render_settings_section()
    render_run_controls_section()
    render_catalog_section()
    render_queue_section()
    render_telemetry_section()
    render_details_section()

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
load_show_status_window_on_startup()
load_auth_identity_on_startup()
load_ui_state_on_startup()
MVSepReaper.ensure_runtime_dirs(S.paths)
load_remembered_model_options_on_startup()
load_catalog_from_cache()
reconcile_selected_model()
local startup_has_stored_login = Auth.load_stored_login()
if startup_has_stored_login then
  Auth.queue_refresh(function()
    refresh_catalog()
  end, function(payload)
    push_warning_once(tostring(payload and (payload.api_error or payload.error) or t("Stored login refresh failed.")))
  end)
else
  refresh_catalog()
end

TelemetryBridge.script_started()
gui_loop()
