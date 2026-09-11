--========================================================
-- AutoMix Tool (dedicated Neurocast backend)
--========================================================

local Locale = {}

local active_locale = "eng"
local translated_runtime_locale = "eng"
local translations_by_source_text = {}
local locale_runtime_aliases = {
  en = "eng",
  eng = "eng",
  ru = "rus",
  rus = "rus"
}

function Locale.parse_runtime_locale(locale)
  if type(locale) ~= "string" then return nil end
  local lowered = tostring(locale):lower()
  local aliased = locale_runtime_aliases[lowered] or lowered
  if aliased == "eng" or aliased == "rus" then
    return aliased
  end
  return nil
end

function Locale.normalize_runtime_locale(locale)
  return Locale.parse_runtime_locale(locale) or "eng"
end

function Locale.translated_locale_available(locale)
  return translated_runtime_locale ~= "eng" and translated_runtime_locale == Locale.normalize_runtime_locale(locale)
end

function Locale.set_active_runtime_locale(locale)
  local normalized = Locale.normalize_runtime_locale(locale)
  if normalized ~= "eng" and (not Locale.translated_locale_available(normalized)) then
    normalized = "eng"
  end
  active_locale = normalized
  return active_locale
end

function Locale.t(text)
  if text == nil then return "" end
  if type(text) ~= "string" then return tostring(text) end
  if active_locale == "eng" then
    return text
  end
  return translations_by_source_text[text] or text
end

local t = Locale.t

local r = assert(reaper, t("Reaper API not found. This script must be run within Reaper."))
local SCRIPT_VERSION = "v0.1.2"
local TOOLSET_VERSION = "v0.1.0"

function Locale.current_main_window_title_text()
  return t("AutoMix via Neurocast") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION
end

function Locale.current_status_window_title_text()
  return t("Status") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION
end

function Locale.locale_display_name(locale)
  if Locale.normalize_runtime_locale(locale) == "rus" then
    return "Русский"
  end
  return "English"
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

local instance_section = "automix_tool_runtime"
if r.GetExtState(instance_section, "running") == "1" then
  r.MB("AutoMix Tool is already open. Use the existing window.", "AutoMix Tool", 0)
  return
end
r.SetExtState(instance_section, "running", "1", false)
r.atexit(function() r.DeleteExtState(instance_section, "running", false) end)

local old_package_path = package.path
package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. old_package_path

do
  local ok_languages, languages_or_err = pcall(require, "modules-neurocast.automix_tool_languages")
  if not ok_languages then
    r.MB(string.format(t("Failed to load translation module! Error message: %s"), tostring(languages_or_err)), t("Localization Error"), 0)
  elseif type(languages_or_err) == "table" then
    local module_locale = Locale.normalize_runtime_locale(languages_or_err.locale)
    local module_translations = languages_or_err.translations_by_source_text
    if module_locale ~= "eng" and type(module_translations) == "table" then
      translated_runtime_locale = module_locale
      translations_by_source_text = module_translations
    end
  end
end

local ok_util, util_or_err = pcall(require, "modules-neurocast.Util")
if not ok_util then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Util: %s"), tostring(util_or_err)), t("Error"), 0)
  return
end
local Util = util_or_err

local ok_files, files_or_err = pcall(require, "modules-neurocast.Files")
if not ok_files then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Files: %s"), tostring(files_or_err)), t("Error"), 0)
  return
end
local Files = files_or_err

local ok_zip_archive, zip_archive_or_err = pcall(require, "modules-neurocast.zip_archive")
if not ok_zip_archive then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.zip_archive: %s"), tostring(zip_archive_or_err)), t("Error"), 0)
  return
end
local ZipArchive = zip_archive_or_err

local ok_import_media, import_media_or_err = pcall(require, "modules-neurocast.ReaperX_Import_Media_Manually")
if not ok_import_media then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.ReaperX_Import_Media_Manually: %s"), tostring(import_media_or_err)), t("Error"), 0)
  return
end
local ImportMedia = import_media_or_err

local ok_render_settings, render_settings_or_err = pcall(require, "modules-neurocast.ReaperX_render_settings_helper")
if not ok_render_settings then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.ReaperX_render_settings_helper: %s"), tostring(render_settings_or_err)), t("Error"), 0)
  return
end
local RenderSettings = render_settings_or_err

local ok_curl, curl_or_err = pcall(require, "modules-neurocast.Curl")
if not ok_curl then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Curl: %s"), tostring(curl_or_err)), t("Error"), 0)
  return
end
local Curl = curl_or_err

local ok_jobs, jobs_or_err = pcall(require, "modules-neurocast.Jobs")
if not ok_jobs then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Jobs: %s"), tostring(jobs_or_err)), t("Error"), 0)
  return
end
local Jobs = jobs_or_err

local ok_cleanup, cleanup_or_err = pcall(require, "modules-neurocast.Cleanup")
if not ok_cleanup then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Cleanup: %s"), tostring(cleanup_or_err)), t("Error"), 0)
  return
end
local Cleanup = cleanup_or_err

local ok_auphonic, auphonic_or_err = pcall(require, "modules-neurocast.auphonic_api_via_neurocast")
if not ok_auphonic then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.auphonic_api_via_neurocast: %s"), tostring(auphonic_or_err)), t("Error"), 0)
  return
end
local AuphonicAPI = auphonic_or_err

local ok_telemetry, telemetry_or_err = pcall(require, "modules-neurocast.Telemetry")
if not ok_telemetry then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Telemetry: %s"), tostring(telemetry_or_err)), t("Error"), 0)
  return
end
local Telemetry = telemetry_or_err

if not Telemetry.require_identity_or_abort({
  app_name = "CirilicaTools",
  entrypoint = "automix_tool",
  script_version = SCRIPT_VERSION
}) then
  package.path = old_package_path
  return
end

local ok_telemetry_init, telemetry_init_err = Telemetry.init({
  app_name = "CirilicaTools",
  entrypoint = "automix_tool",
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

local UI, Automix = {}, {}
local ProjectPaths, RuntimeState, ClientFactory, FileNames, ReaperRefs = {}, {}, {}, {}, {}
local DiaFlow, ImportFlow, RenderFlow, PresetFlow, ProductionFlow, RecordFlow = {}, {}, {}, {}, {}, {}
local PopupUI, MainUI, TelemetryBridge = {}, {}, {}
local mac = Util.mac
local send_telemetry_closed_event = nil

r.atexit(function()
  if type(send_telemetry_closed_event) == "function" then
    send_telemetry_closed_event("atexit")
  end
  package.path = old_package_path
end)

local ctx = ImGui.CreateContext(Locale.current_main_window_title_text())
local ctx_status = ImGui.CreateContext(Locale.current_status_window_title_text())
local filter = ImGui.CreateTextFilter("")
ImGui.Attach(ctx, filter)
local font_size = 16
local FONT = ImGui.CreateFont("monospace")
ImGui.Attach(ctx, FONT)
local FONT_bold = ImGui.CreateFont("monospace", ImGui.FontFlags_Bold)
ImGui.Attach(ctx, FONT_bold)

function ProjectPaths.resolve_curl_path()
  local curl_resolved_path = "curl"
  if mac then
    curl_resolved_path = "/usr/bin/curl"
    return curl_resolved_path
  end

  curl_resolved_path = Util.path_join(script_path, [=[bin\win]=]) .. [=[\curl.exe]=]
  local result = r.ExecProcess(curl_resolved_path .. " --version", 1500)
  local target = [=[curl 8.13.0 (Windows)]=]
  if result then
    if result:find(target, 1, true) then
      return curl_resolved_path
    end
  end
  local detail = result and ("Unexpected curl --version output:\n" .. tostring(result)) or "Could not run bundled curl --version."
  r.MB(
    string.format(
      t("Bundled curl was not found or did not match the expected version at:\n%s\n\nThe script will try Windows system curl from PATH instead.\n\nExpected: %s\n%s"),
      tostring(curl_resolved_path),
      target,
      detail
    ),
    t("Warning"),
    0
  )
  return "curl"
end

local auth_session = nil

local extstate_keys = {
  EXT_SECTION = "ncam_tool_auth_7f3",
  EXT_KEY = "refresh_42d",
  EXT_EMAIL_KEY = "email_91b",
  EXT_SECTION_UI = "automix_tool_ui",
  EXT_KEY_UI_Show_Status = "show_status_window",
  EXT_KEY_UI_Locale = "ui_locale",
  EXT_KEY_UI_Dia_Wav_Bit_Depth = "dia_wav_bit_depth",
  EXT_KEY_UI_Result_Insert_Position = "result_insert_position"
}

local CFG = {
  base_url = AuphonicAPI.PRODUCTION_BASE,
  curl = ProjectPaths.resolve_curl_path(),
  timeout_sec = 320,
  max_concurrent_jobs = 8,
  curl_connect_timeout_sec = 45,
  curl_speed_limit = 1,
  curl_speed_time = 120,
  button_cooldown_sec = 1.5,
  manual_status_check_cooldown_sec = 7.0,
  production_poll_min_sec = 10,
  production_poll_max_sec = 20,
  retry_base_backoff_sec = 1.57,
  max_wait_time_for_retry = 16.57,
  retry_jitter_ratio = 0.0,
  temp_subfolder_name = "Neurocast_Tools_tmp/automix"
}

Util.messaging_level = 3
Util.msg_to_log_file = false
Util.log_level_override = nil
Util.full_path_to_log_file = nil

local S = {
  email = "",
  password = "",
  access_token = "",
  refresh_token = "",
  use_local_backend = false,
  creation_uncertain = false,
  start_uncertain = false,
  upload_confirmed = false,
  output_setup_confirmed = false,
  pending_output_adjustment = nil,
  remember_me = true,
  has_stored_refresh = false,
  status_text = "",
  last_http = "",
  last_api_error = "",
  warnings = {},
  checks_ran = false,
  tmp_writable = false,
  project_path = "",
  pending_job = nil,
  curl_jobs = {},
  cleanup_queue = {},
  cleanup_failures = {},
  retry_queue = {},
  retry_generation = 0,
  wait_until = nil,
  running_label = nil,
  ui_lock_network_buttons = false,
  show_status_window = false,
  last_check_error = "",
  last_curl_return = {
    ok = "",
    http = "",
    body = "",
    headers_txt = "",
    meta = "",
    err = "",
    cmd = ""
  },
  misc_records = nil,
  presets = {},
  preset_details_by_uuid = {},
  selected_preset_idx = nil,
  selected_preset_details = {},
  create_stems_archive = false,
  tracks = nil,
  selected_tracks_indexes = {},
  rendered_files_in_order = nil,
  render_last_summary = "",
  render_last_error = "",
  has_render_result = false,
  production_name_input = nil,
  production_details = nil,
  result_insert_position = "edit_cursor",
  production_insert_anchor = nil,
  selected_download_output = nil,
  selected_stems_output = nil,
  inserted_mix_path = "",
  imported_stems_extract_dir = "",
  imported_stems_count = 0,
  imported_stems_renamed_files = {},
  dia_candidates = {},
  dia_wav_bit_depth = 24,
  dia_last_status = "",
  dia_last_error = "",
  dia_last_output_path = "",
  dia_last_imported_path = "",
  production_ready_to_start = false,
  production_started_flag = false,
  production_poll_active = false,
  production_poll_next_at = nil,
  production_poll_last_interval_sec = nil,
  pending_paid_start_popup = false,
  pending_cleanup_prompt = false,
  cleanup_prompt_download_path = "",
  main_window_pos_x = nil,
  main_window_pos_y = nil,
  main_window_size_w = nil,
  main_window_size_h = nil,
  has_duplicate = {},
  project_track_matched = {},
  auto_auth_attempted = false,
  auto_auth_finished = false,
  auto_auth_success = false,
  telemetry_ui_status = "",
  telemetry_last_poll_signature = "",
  telemetry_last_poll_event_at = nil
}

local button_last_click_at = {}

local telemetry_button_ids = {
  login_btn = true,
  connect_btn = true,
  render_btn = true,
  create_and_upload_btn = true,
  start_production_btn = true,
  manual_status_btn = true,
  download_import_btn = true,
  download_stems_btn = true,
  dia_render_btn = true,
  paid_start_now_btn = true,
  paid_start_later_btn = true,
  cleanup_render_files_btn = true,
  keep_render_files_btn = true
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

function TelemetryBridge.safe_string(value)
  local text = tostring(value or "")
  if type(Util.clip_text) == "function" then
    return Util.clip_text(text, 2048)
  end
  return text:sub(1, 2048)
end

function TelemetryBridge.production_uuid()
  return Util.trim((S.production_details and S.production_details.uuid) or "")
end

function TelemetryBridge.production_status_fields()
  local details = S.production_details
  if type(details) ~= "table" then
    return "", ""
  end
  return Util.trim(details.status or details.status_code or ""), Util.trim(details.status_string or "")
end

function TelemetryBridge.selected_track_names()
  local names = {}
  if not (S.tracks and S.tracks.list and type(S.selected_tracks_indexes) == "table") then
    return names
  end
  for _, track_index in ipairs(S.selected_tracks_indexes) do
    local name = S.tracks.list[track_index]
    if name then
      names[#names + 1] = tostring(name)
    end
  end
  return names
end

function TelemetryBridge.rendered_file_paths()
  local paths = {}
  if type(S.rendered_files_in_order) ~= "table" then
    return paths
  end
  for i = 1, #S.rendered_files_in_order do
    paths[#paths + 1] = tostring(S.rendered_files_in_order[i] or "")
  end
  return paths
end

function TelemetryBridge.base_payload(data)
  local status_code, status_string = TelemetryBridge.production_status_fields()
  local out = {
    app_area = "automix",
    project_path = tostring(S.project_path or ""),
    temp_dir = tostring(CFG.tmp_dir or ""),
    production_uuid = TelemetryBridge.production_uuid(),
    production_status_code = status_code,
    production_status_string = status_string
  }
  if type(data) == "table" then
    for k, v in pairs(data) do
      out[k] = v
    end
  end
  return out
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

function TelemetryBridge.cleanup_failed(data, started_at)
  return TelemetryBridge.operation_failed("automix_cleanup_render_files", data, started_at, "cleanup_failed")
end

function TelemetryBridge.operation_from_record(rec)
  local key = tostring(rec and rec._misc_key or "")
  if key ~= "" then
    return "automix_" .. key
  end
  return "automix_request"
end

function TelemetryBridge.safe_request_label(label)
  return tostring(label or "")
end

function TelemetryBridge.record_payload(rec, progress_text)
  local key = tostring(rec and rec._misc_key or "")
  local payload = {
    request_label = TelemetryBridge.safe_request_label(rec and rec.record_name or ""),
    flow_label = TelemetryBridge.safe_request_label(rec and rec.flow_label or ""),
    progress = tostring(progress_text or (rec and rec._custom_progress) or ""),
    http_code = rec and rec._last_http_code or nil
  }

  if key == "render" or key == "create_production" or key == "upload_production" then
    payload.selected_track_names = TelemetryBridge.selected_track_names()
    payload.selected_track_count = #(payload.selected_track_names or {})
    payload.rendered_file_paths = TelemetryBridge.rendered_file_paths()
    payload.rendered_file_count = #(payload.rendered_file_paths or {})
  end
  if key == "download_import" then
    payload.inserted_mix_path = tostring(S.inserted_mix_path or "")
  end
  if key == "download_stems" then
    payload.imported_stems_extract_dir = tostring(S.imported_stems_extract_dir or "")
    payload.imported_stems_count = tonumber(S.imported_stems_count) or 0
    payload.renamed_stem_files = S.imported_stems_renamed_files
  end
  return payload
end

function TelemetryBridge.begin_record(rec, progress_text, opts)
  if type(rec) ~= "table" then return end
  local options = opts or {}
  rec._telemetry_suppressed_current = options.suppress_telemetry == true
  rec._telemetry_started_at = TelemetryBridge.now()
  rec._telemetry_completed_current = false
  rec._telemetry_operation = tostring(options.operation or TelemetryBridge.operation_from_record(rec))

  if rec._telemetry_suppressed_current then
    return
  end
  local payload = TelemetryBridge.record_payload(rec, progress_text)
  payload.progress = tostring(progress_text or "")
  TelemetryBridge.operation_started(rec._telemetry_operation, payload)
end

function TelemetryBridge.finish_record_ok(rec, progress_text)
  if type(rec) ~= "table" or rec._telemetry_suppressed_current == true or rec._telemetry_completed_current == true then
    return
  end
  rec._telemetry_completed_current = true
  local payload = TelemetryBridge.record_payload(rec, progress_text)
  payload.duration_ms = TelemetryBridge.duration_ms(rec._telemetry_started_at)
  TelemetryBridge.operation_completed(rec._telemetry_operation or TelemetryBridge.operation_from_record(rec), payload)
end

function TelemetryBridge.finish_record_failed(rec, err_text, progress_text)
  if type(rec) ~= "table" or rec._telemetry_suppressed_current == true or rec._telemetry_completed_current == true then
    return
  end
  rec._telemetry_completed_current = true
  local payload = TelemetryBridge.record_payload(rec, progress_text)
  payload.safe_message = TelemetryBridge.safe_string(err_text or rec._last_error_summary or "")
  payload.error_code = tostring(rec._misc_key or "AUTOMIX_OPERATION_FAILED"):upper()
  payload.duration_ms = TelemetryBridge.duration_ms(rec._telemetry_started_at)
  local event_name = tostring(rec._misc_key or "") == "render" and "render_failed" or "operation_failed"
  TelemetryBridge.operation_failed(rec._telemetry_operation or TelemetryBridge.operation_from_record(rec), payload, nil, event_name)
end

function TelemetryBridge.network_request_failed(req, result, job, track_label)
  local label = TelemetryBridge.safe_request_label(track_label or (req and req.label) or (job and job.label) or "request")
  local payload = {
    operation = "automix_network_request",
    status = "failed",
    request_label = label,
    request_kind = tostring(req and req.kind or ""),
    job_id = tostring(job and job.id or ""),
    http_code = result and result.http_code or nil,
    curl_exitcode = result and result.exitcode or nil,
    safe_message = TelemetryBridge.safe_string((result and (result.err or result.err_msg or result.err_txt)) or "curl request failed"),
    timed_out = result and result.timed_out == true,
    total_time = result and result.total_time or nil,
    size_upload = result and result.size_upload or nil,
    size_download = result and result.size_download or nil
  }
  TelemetryBridge.emit_operation_event("network_request_failed", "automix_network_request", "failed", payload, {
    priority = "error",
    event_level = "error",
    request_label = label,
    http_code = payload.http_code,
    curl_exitcode = payload.curl_exitcode
  })
end

function TelemetryBridge.button_clicked(button_id, label)
  return TelemetryBridge.safe_event("button_clicked", {
    operation = "automix_ui",
    status = "clicked",
    button_id = tostring(button_id or ""),
    button_label = tostring(label or "")
  }, {
    operation = "automix_ui",
    status = "clicked",
    priority = "low"
  })
end

function TelemetryBridge.poll_status_transition(kind, is_manual)
  local details = S.production_details
  local status_code, status_string = TelemetryBridge.production_status_fields()
  local signature = table.concat({
    tostring(kind or ""),
    TelemetryBridge.production_uuid(),
    status_code,
    status_string
  }, "|")
  local now_t = TelemetryBridge.now()
  if signature == S.telemetry_last_poll_signature and S.telemetry_last_poll_event_at and (now_t - S.telemetry_last_poll_event_at) < 60 then
    return
  end
  S.telemetry_last_poll_signature = signature
  S.telemetry_last_poll_event_at = now_t

  TelemetryBridge.emit_operation_event("operation_completed", "automix_production_status_transition", "completed", {
    production_transition_kind = tostring(kind or "status"),
    automatic_poll = not is_manual,
    manual_poll = is_manual == true,
    production_details_present = type(details) == "table",
    production_status_code = status_code,
    production_status_string = status_string
  }, {
    priority = "normal"
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
  if not desc or desc.initialized ~= true then
    return t("unavailable")
  end
  if desc.send_paused then
    return t("paused, see details")
  end
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
  local pending_files =
    (tonumber(desc.queued_file_count) or 0) +
    (tonumber(desc.sending_file_count) or 0)
  if pending_bytes > 0 or pending_files > 0 then
    return t("queued")
  end
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
  if TelemetryBridge.status_ok(desc) then
    return 0x00C853FF
  end
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
    reason = reason or "automix_manual",
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

function ProjectPaths.refresh_project_relative_paths()
  S.project_path = Files.read_project_path() or ""
  if S.project_path ~= "" then
    CFG.tmp_dir = Util.path_join(S.project_path, CFG.temp_subfolder_name or "Neurocast_Tools_tmp/automix")
  else
    local fallback = Util.path_join(r.GetResourcePath(), "Data")
    fallback = Util.path_join(fallback, "NeurocastAutoMixTool")
    CFG.tmp_dir = Util.path_join(fallback, "tmp")
  end
  return CFG.tmp_dir
end

ProjectPaths.refresh_project_relative_paths()
Util.configure_diagnostics("automix_tool")
Cleanup.init(S, CFG)
Curl.init(S, CFG)
Jobs.init(S, CFG)

function MainUI.current_main_window_label()
  return Locale.current_main_window_title_text() .. "##automix_tool_main_window"
end

function MainUI.current_status_window_label()
  return Locale.current_status_window_title_text() .. "##automix_tool_status_window"
end

function RuntimeState.push_warning(msg)
  local text = Util.trim(msg)
  if text == "" then return end
  if type(S.warnings) ~= "table" then
    S.warnings = {}
  end
  S.warnings[#S.warnings + 1] = text
end

function RuntimeState.push_warning_once(msg)
  local text = Util.trim(msg)
  if text == "" then return end
  for i = 1, #(S.warnings or {}) do
    if S.warnings[i] == text then
      return
    end
  end
  RuntimeState.push_warning(text)
end

function RuntimeState.clear_runtime_auth_state()
  S.access_token = ""
  S.refresh_token = ""
  if auth_session then auth_session.clear() end
end

function RuntimeState.persist_email(email)
  local text = Util.trim(email)
  if text == "" then return end
  Util.extstate_set_camo(extstate_keys.EXT_SECTION, extstate_keys.EXT_EMAIL_KEY, text, true)
end

function RuntimeState.forget_email()
  Util.extstate_delete(extstate_keys.EXT_SECTION, extstate_keys.EXT_EMAIL_KEY, true)
end

function RuntimeState.load_email_from_ext_state()
  local value, err = Util.extstate_get_camo(extstate_keys.EXT_SECTION, extstate_keys.EXT_EMAIL_KEY)
  if err then
    Util.msg("Failed to load stored email: " .. tostring(err), 2)
    return nil
  end
  local email = Util.trim(value or "")
  if email == "" then
    RuntimeState.forget_email()
    return nil
  end
  return email
end

function RuntimeState.persist_ui_state(key, value)
  local ok_set, err = Util.extstate_set(extstate_keys.EXT_SECTION_UI, key, tostring(value or ""), true)
  if not ok_set then
    Util.msg(string.format(t("Failed to persist UI state: %s"), tostring(err)), 2)
  end
end

function RuntimeState.forget_ui_state(key)
  local _, err = Util.extstate_delete(extstate_keys.EXT_SECTION_UI, key, true)
  if err then
    Util.msg(string.format(t("Failed to forget UI state: %s"), tostring(err)), 2)
  end
end

function RuntimeState.load_plain_ui_state(key)
  local value, err = Util.extstate_get(extstate_keys.EXT_SECTION_UI, key)
  if err then
    Util.msg(string.format(t("Failed to load UI state: %s"), tostring(err)), 2)
    return nil
  end
  return value
end

function RuntimeState.load_legacy_camo_ui_state(key)
  local value, err = Util.extstate_get_camo(extstate_keys.EXT_SECTION_UI, key)
  if err then
    Util.msg(string.format(t("Failed to load legacy UI state: %s"), tostring(err)), 2)
    return nil
  end
  return value
end

function RuntimeState.load_result_insert_position_on_startup()
  local stored = RuntimeState.load_plain_ui_state(extstate_keys.EXT_KEY_UI_Result_Insert_Position)
  S.result_insert_position = stored == "selection_start" and "selection_start" or "edit_cursor"
end

function RuntimeState.set_result_insert_position(value)
  S.result_insert_position = value == "selection_start" and "selection_start" or "edit_cursor"
  RuntimeState.persist_ui_state(extstate_keys.EXT_KEY_UI_Result_Insert_Position, S.result_insert_position)
end

function RuntimeState.load_migrated_ui_state(key, normalize_value, serialize_value)
  if type(normalize_value) ~= "function" then return nil end

  local plain_value = RuntimeState.load_plain_ui_state(key)
  local normalized = normalize_value(plain_value)
  if normalized ~= nil then
    return normalized
  end

  local legacy_value = RuntimeState.load_legacy_camo_ui_state(key)
  normalized = normalize_value(legacy_value)
  if normalized ~= nil then
    local stored = normalized
    if type(serialize_value) == "function" then
      stored = serialize_value(normalized)
    end
    RuntimeState.persist_ui_state(key, stored)
    return normalized
  end

  return nil
end

function RuntimeState.normalize_show_status_window_value(value)
  if value == true then return true end
  if value == false then return false end
  if value == "1" then return true end
  if value == "0" then return false end
  return nil
end

function RuntimeState.serialize_show_status_window_value(value)
  return value and "1" or "0"
end

function RuntimeState.persist_show_status_window(value)
  RuntimeState.persist_ui_state(
    extstate_keys.EXT_KEY_UI_Show_Status,
    RuntimeState.serialize_show_status_window_value(value)
  )
end

function RuntimeState.load_show_status_window_from_ext_state()
  return RuntimeState.load_migrated_ui_state(
    extstate_keys.EXT_KEY_UI_Show_Status,
    RuntimeState.normalize_show_status_window_value,
    RuntimeState.serialize_show_status_window_value
  )
end

function RuntimeState.forget_locale()
  RuntimeState.forget_ui_state(extstate_keys.EXT_KEY_UI_Locale)
end

function RuntimeState.normalize_locale_value(value)
  if value == nil then return nil end

  value = tostring(value or "")
  if value == "" then
    return nil
  end

  local normalized = Locale.parse_runtime_locale(value)
  if not normalized then
    return nil
  end
  return normalized
end

function RuntimeState.persist_locale(locale)
  local normalized = RuntimeState.normalize_locale_value(locale)
  if not normalized then
    RuntimeState.forget_locale()
    return
  end
  RuntimeState.persist_ui_state(extstate_keys.EXT_KEY_UI_Locale, normalized)
end

function RuntimeState.load_locale_from_ext_state()
  return RuntimeState.load_migrated_ui_state(
    extstate_keys.EXT_KEY_UI_Locale,
    RuntimeState.normalize_locale_value,
    tostring
  )
end

function RuntimeState.normalize_dia_wav_bit_depth_value(value)
  local bit_depth = tonumber(value)
  if bit_depth == 16 then return 16 end
  if bit_depth == 24 then return 24 end
  return nil
end

function RuntimeState.persist_dia_wav_bit_depth(value)
  local bit_depth = RuntimeState.normalize_dia_wav_bit_depth_value(value) or 24
  RuntimeState.persist_ui_state(extstate_keys.EXT_KEY_UI_Dia_Wav_Bit_Depth, tostring(bit_depth))
end

function RuntimeState.load_dia_wav_bit_depth_from_ext_state()
  return RuntimeState.load_migrated_ui_state(
    extstate_keys.EXT_KEY_UI_Dia_Wav_Bit_Depth,
    RuntimeState.normalize_dia_wav_bit_depth_value,
    tostring
  )
end

function RuntimeState.load_show_status_window_on_startup()
  local stored = RuntimeState.load_show_status_window_from_ext_state()
  if stored ~= nil then
    S.show_status_window = stored
  end
end

function RuntimeState.load_locale_on_startup()
  local stored = RuntimeState.load_locale_from_ext_state()
  Locale.set_active_runtime_locale(stored or "eng")
end

function RuntimeState.load_dia_wav_bit_depth_on_startup()
  local stored = RuntimeState.load_dia_wav_bit_depth_from_ext_state()
  if stored ~= nil then
    S.dia_wav_bit_depth = stored
  end
end

function ClientFactory.make_tracked_curl_submit(track_label)
  return function(req, on_done, submit_opts)
    local request_label = req.label or track_label
    local job, err = Curl.curl_submit(req, function(result, job_ref)
      local failure = AuphonicAPI.parse_error(result)
      local safe = {
        ok = result and result.ok, http_code = result and result.http_code,
        exitcode = result and result.exitcode, total_time = result and result.total_time,
        size_upload = result and result.size_upload, size_download = result and result.size_download,
        body = failure.code or "", headers_txt = "", cmd = "",
        err = result and result.ok and "" or failure.error
      }
      Curl.update_last_curl_state(safe, nil, request_label)
      if result and result.ok ~= true then TelemetryBridge.network_request_failed(req, safe, job_ref, request_label) end
      if on_done then on_done(result, job_ref) end
    end, submit_opts)
    if job then
      for _, rec in ipairs(S.misc_records or {}) do
        if rec._state == "running" then rec.misc_job_id = job.id end
      end
    end
    return job, err
  end
end

function ClientFactory.create_auth_client(_track_label)
  if not auth_session then
    local backend_suffix = S.use_local_backend and "_local" or "_production"
    auth_session = AuphonicAPI.create_session({
      base_url = CFG.base_url,
      curl_submit_fn = ClientFactory.make_tracked_curl_submit(t("Studio login")),
      ext_section = extstate_keys.EXT_SECTION .. backend_suffix,
      ext_refresh_key = extstate_keys.EXT_KEY,
      remember_fn = function() return S.remember_me == true end,
      on_tokens = function(tokens, warning)
        S.access_token, S.refresh_token = tokens.access_token, tokens.refresh_token
        S.has_stored_refresh = S.remember_me and tokens.refresh_token ~= ""
        if warning then RuntimeState.push_warning_once(warning) end
      end
    })
  end
  return auth_session
end

function ClientFactory.create_auphonic_client(track_label)
  local session = ClientFactory.create_auth_client(track_label)
  return AuphonicAPI.create_client({
    base_url = CFG.base_url,
    curl_submit_fn = function(req, callback, opts)
      req.label = track_label or req.label
      return session.submit(req, callback, opts)
    end
  })
end

local AUDIO_FILE_EXTENSIONS = {
  wav = true,
  flac = true,
  mp3 = true,
  m4a = true,
  aac = true,
  ogg = true,
  opus = true,
  aiff = true,
  aif = true,
  w64 = true
}

function FileNames.file_name_looks_like_audio(file_name)
  local name = tostring(file_name or "")
  local ext = name:match("%.([^.]+)$")
  if not ext then return false end
  return AUDIO_FILE_EXTENSIONS[string.lower(ext)] == true
end

function FileNames.get_default_production_name()
  local proj_name = r.GetProjectName(0) or ""
  proj_name = tostring(proj_name):gsub("[.][rR][pP][pP]$", "")
  proj_name = Util.trim(proj_name)
  proj_name = Util.sanitize_filename(proj_name, t("Mixdown"), 128)
  if proj_name == "" then
    proj_name = t("Mixdown")
  end
  return proj_name
end

function FileNames.ensure_production_name_input()
  local current = Util.trim(S.production_name_input or "")
  if current == "" then
    S.production_name_input = FileNames.get_default_production_name()
  end
  return S.production_name_input
end

function FileNames.path_basename(path)
  local text = tostring(path or ""):gsub("\\", "/")
  return text:match("([^/]+)$") or text
end

function FileNames.strip_final_extension(file_name)
  local name = tostring(file_name or "")
  local stripped = name:gsub("%.[^%.]+$", "")
  if stripped == "" then return name end
  return stripped
end

function FileNames.track_name_from_file_path(file_path, fallback_name)
  local name = FileNames.strip_final_extension(FileNames.path_basename(file_path))
  name = Util.trim(name)
  if name == "" then
    name = fallback_name or t("Imported media")
  end
  return name
end

function ReaperRefs.validate_reaper_ptr(pointer, pointer_type)
  if not pointer then return false end
  if type(r.ValidatePtr2) == "function" then
    return r.ValidatePtr2(0, pointer, pointer_type) == true
  end
  return true
end

function ReaperRefs.get_track_name_safe(track)
  if not ReaperRefs.validate_reaper_ptr(track, "MediaTrack*") then return "" end
  local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return Util.trim(name or "")
end

function ReaperRefs.get_item_position_length(item)
  if not ReaperRefs.validate_reaper_ptr(item, "MediaItem*") then
    return 0, 0
  end
  local position = tonumber(r.GetMediaItemInfo_Value(item, "D_POSITION")) or 0
  local length = tonumber(r.GetMediaItemInfo_Value(item, "D_LENGTH")) or 0
  return position, length
end

function FileNames.stem_text_matches_voice(text)
  return tostring(text or ""):lower():find("voice", 1, true) ~= nil
end

function DiaFlow.clear_dia_runtime_state()
  S.dia_candidates = {}
  S.dia_last_status = ""
  S.dia_last_error = ""
  S.dia_last_output_path = ""
  S.dia_last_imported_path = ""
end

function DiaFlow.remember_imported_stems_for_dia(audio_files, import_result)
  DiaFlow.clear_dia_runtime_state()
  if type(audio_files) ~= "table" or type(import_result) ~= "table" then
    return
  end

  local created_by_group = {}
  for _, created in ipairs(import_result.created_items or {}) do
    if type(created) == "table" and created.group_index ~= nil then
      created_by_group[tonumber(created.group_index)] = created
    end
  end

  for index, stem in ipairs(audio_files) do
    local created = created_by_group[index] or (import_result.created_items or {})[index]
    if type(created) == "table" then
      local source_path = Util.trim(created.full_path or (stem and stem.path) or "")
      local stem_id = Util.trim(stem and stem.stem_id or "")
      local track_name = ReaperRefs.get_track_name_safe(created.track)
      if track_name == "" then
        track_name = stem_id ~= "" and stem_id or FileNames.track_name_from_file_path(source_path, t("Stem"))
      end

      local display_name = track_name
      if stem_id ~= "" and stem_id ~= track_name then
        display_name = track_name .. " / " .. stem_id
      end

      local item_position, item_length = ReaperRefs.get_item_position_length(created.item)
      local file_name = FileNames.path_basename(source_path)
      local preselected =
        FileNames.stem_text_matches_voice(track_name) or
        FileNames.stem_text_matches_voice(stem_id) or
        FileNames.stem_text_matches_voice(file_name)

      S.dia_candidates[#S.dia_candidates + 1] = {
        track = created.track,
        item = created.item,
        source_path = source_path,
        file_name = file_name,
        stem_id = stem_id,
        track_name = track_name,
        display_name = display_name,
        selected = preselected,
        item_position = item_position,
        item_length = item_length,
        source_length = tonumber(created.source_length) or item_length
      }
    end
  end

  if #S.dia_candidates > 0 then
    S.dia_last_status = string.format(t("Imported stems ready for DIA mix (%d candidate(s).)"), #S.dia_candidates)
  end
end

function DiaFlow.selected_dia_candidate_count()
  local count = 0
  for _, candidate in ipairs(S.dia_candidates or {}) do
    if candidate and candidate.selected == true then
      count = count + 1
    end
  end
  return count
end

function DiaFlow.set_dia_candidate_selection(mode)
  for _, candidate in ipairs(S.dia_candidates or {}) do
    if candidate then
      if mode == "all" then
        candidate.selected = true
      elseif mode == "none" then
        candidate.selected = false
      elseif mode == "voice" then
        candidate.selected =
          FileNames.stem_text_matches_voice(candidate.track_name) or
          FileNames.stem_text_matches_voice(candidate.stem_id) or
          FileNames.stem_text_matches_voice(candidate.file_name)
      end
    end
  end
end

function DiaFlow.parse_reaper_major_minor(version_text)
  local major, minor = tostring(version_text or ""):match("^(%d+)%.(%d+)")
  major = tonumber(major)
  minor = tonumber(minor)
  if not major or not minor then
    return nil, nil
  end
  return major, minor
end

function DiaFlow.dia_render_mode_supported()
  if type(r.GetAppVersion) ~= "function" then
    return false, t("DIA render requires REAPER 7.37 or newer; GetAppVersion is unavailable.")
  end

  local version_text = tostring(r.GetAppVersion() or "")
  local major, minor = DiaFlow.parse_reaper_major_minor(version_text)
  if not major then
    return false, string.format(t("DIA render requires REAPER 7.37 or newer; could not parse REAPER version: %s"), version_text)
  end
  if major > 7 or (major == 7 and minor >= 37) then
    return true, nil
  end
  return false, string.format(t("DIA render requires REAPER 7.37 or newer. Current REAPER version: %s"), version_text)
end

function DiaFlow.ensure_dia_selection_api()
  local required = {
    "CountSelectedMediaItems",
    "GetSelectedMediaItem",
    "SelectAllMediaItems",
    "SetMediaItemSelected"
  }
  for _, name in ipairs(required) do
    if type(r[name]) ~= "function" then
      return false, string.format(t("DIA render unavailable: ReaScript function missing: %s"), name)
    end
  end
  return true, nil
end

function ReaperRefs.snapshot_selected_media_items()
  local items = {}
  local count = tonumber(r.CountSelectedMediaItems(0)) or 0
  for index = 0, count - 1 do
    local item = r.GetSelectedMediaItem(0, index)
    if ReaperRefs.validate_reaper_ptr(item, "MediaItem*") then
      items[#items + 1] = item
    end
  end
  return items
end

function ReaperRefs.select_only_media_items(items)
  r.SelectAllMediaItems(0, false)
  for _, item in ipairs(items or {}) do
    if ReaperRefs.validate_reaper_ptr(item, "MediaItem*") then
      r.SetMediaItemSelected(item, true)
    end
  end
  r.UpdateArrange()
end

function ReaperRefs.restore_selected_media_items(items)
  ReaperRefs.select_only_media_items(items or {})
end

function DiaFlow.get_checked_dia_candidates()
  local checked = {}
  local invalid = {}
  for _, candidate in ipairs(S.dia_candidates or {}) do
    if candidate and candidate.selected == true then
      if not ReaperRefs.validate_reaper_ptr(candidate.item, "MediaItem*") then
        invalid[#invalid + 1] = candidate.display_name or candidate.track_name or t("Stem")
      else
        checked[#checked + 1] = candidate
      end
    end
  end

  if #invalid > 0 then
    return nil, string.format(t("Selected DIA stem item is no longer valid: %s"), table.concat(invalid, ", "))
  end
  if #checked == 0 then
    return nil, t("Select at least one imported stem for the DIA mix.")
  end
  return checked, nil
end

function DiaFlow.build_dia_mix_name()
  local fallback = FileNames.get_default_production_name()
  local safe_name = Util.sanitize_filename(FileNames.ensure_production_name_input(), fallback, 128)
  if Util.trim(safe_name) == "" then
    safe_name = fallback
  end
  return safe_name
end

function DiaFlow.bump_to_unique_dia_file_path(path)
  if type(path) ~= "string" or path == "" then return path end
  local base, ext = path:match("^(.+)(%.[^%.\\/]+)$")
  if not base then
    base, ext = path, ""
  end

  local n = 0
  local candidate = path
  while r.file_exists(candidate) == true do
    n = n + 1
    candidate = base .. "_" .. tostring(n) .. ext
  end
  return candidate
end

function DiaFlow.build_dia_output_target()
  ProjectPaths.refresh_project_relative_paths()
  if S.project_path == "" then
    return nil, t("Project path is unavailable. Save the project before rendering the DIA mix.")
  end

  local dia_dir = S.project_path
  local ok_dir, dir_err = Files.ensure_tmp_dir(dia_dir)
  if not ok_dir then
    return nil, string.format(t("DIA folder is not writable: %s"), tostring(dir_err or dia_dir))
  end

  local base_file_stem = DiaFlow.build_dia_mix_name() .. "_DIA20"
  local candidate_path = Util.path_join(dia_dir, base_file_stem .. ".wav")
  local output_path = DiaFlow.bump_to_unique_dia_file_path(candidate_path)
  local output_file_stem = FileNames.strip_final_extension(FileNames.path_basename(output_path))

  return {
    output_dir = dia_dir,
    output_file_stem = output_file_stem,
    output_path = output_path
  }, nil
end

function DiaFlow.dia_project_sample_rate_warning()
  local project_srate = tonumber(r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 0
  if math.floor(project_srate + 0.5) == 48000 then
    return nil
  end
  return string.format(
    t("Project sample rate is %s Hz, not 48000 Hz. DIA render will use the project sample rate."),
    tostring(project_srate)
  )
end

function DiaFlow.current_dia_wav_bit_depth()
  return RuntimeState.normalize_dia_wav_bit_depth_value(S.dia_wav_bit_depth) or 24
end

function DiaFlow.dia_wav_bit_depth_label(bit_depth)
  if RuntimeState.normalize_dia_wav_bit_depth_value(bit_depth) == 16 then
    return t("16-bit WAV")
  end
  return t("24-bit WAV")
end

function DiaFlow.get_dia_wav_sink_format()
  if DiaFlow.current_dia_wav_bit_depth() == 16 then
    return RenderSettings.SINK_FORMATS.WAV_16BIT
  end
  return RenderSettings.SINK_FORMATS.WAV_24BIT
end

function DiaFlow.build_dia_render_profile(target)
  return {
    schema_version = 1,
    numeric = {
      RENDER_SETTINGS = 262176,
      RENDER_BOUNDSFLAG = RenderSettings.RENDER_BOUNDSFLAG.SELECTED_MEDIA_ITEMS,
      RENDER_CHANNELS = 2,
      RENDER_SRATE = 0,
      RENDER_TAILFLAG = 0,
      RENDER_TAILMS = 1000,
      RENDER_ADDTOPROJ = 0,
      RENDER_DITHER = 0,
      RENDER_NORMALIZE = 1536,
      RENDER_NORMALIZE_TARGET = 0,
      RENDER_BRICKWALL = 0,
      RENDER_FADEIN = 0.005,
      RENDER_FADEOUT = 0.005,
      RENDER_FADEINSHAPE = 4,
      RENDER_FADEOUTSHAPE = 4,
      RENDER_FADELPF = 0,
      RENDER_PADSTART = 0,
      RENDER_PADEND = 0,
      RENDER_TRIMSTART = 0.000001,
      RENDER_TRIMEND = 0.000001,
      RENDER_DELAY = 0,
      PROJECT_SRATE_USE = 1
    },
    strings = {
      RENDER_FILE = target.output_dir,
      RENDER_PATTERN = target.output_file_stem,
      RENDER_EXTRAFILEDIR = "",
      RENDER_FORMAT = DiaFlow.get_dia_wav_sink_format(),
      RENDER_FORMAT2 = ""
    }
  }
end

function DiaFlow.earliest_dia_candidate_position(candidates)
  local earliest = nil
  for _, candidate in ipairs(candidates or {}) do
    local position = tonumber(candidate and candidate.item_position)
    if not position and candidate and candidate.item then
      position = ReaperRefs.get_item_position_length(candidate.item)
    end
    if position then
      if earliest == nil or position < earliest then
        earliest = position
      end
    end
  end
  return earliest or r.GetCursorPosition()
end

function ImportFlow.build_stems_extract_target_dir(_output, _archive_path)
  ProjectPaths.refresh_project_relative_paths()
  if S.project_path == "" then
    return nil, t("Project path is unavailable. Save the project before extracting the stem archive.")
  end

  local stems_root = S.project_path
  local ok_root, root_err = Files.ensure_tmp_dir(stems_root)
  if not ok_root then
    return nil, string.format(t("Stems folder is not writable: %s"), tostring(root_err or stems_root))
  end

  return stems_root, nil
end

function ImportFlow.create_destination_track_at_bottom(track_name, fallback_name)
  local index = tonumber(r.CountTracks(0)) or 0
  r.InsertTrackAtIndex(index, true)
  local track = r.GetTrack(0, index)
  if not track then
    return nil, t("Failed to create destination track.")
  end

  local clean_track_name = Util.trim(track_name or "")
  if clean_track_name == "" then
    clean_track_name = fallback_name or t("Imported media")
  end
  r.GetSetMediaTrackInfo_String(track, "P_NAME", clean_track_name, true)
  return track, nil
end

function ImportFlow.refresh_track_list_and_arrange()
  if type(r.TrackList_AdjustWindows) == "function" then
    r.TrackList_AdjustWindows(false)
  end
  r.UpdateArrange()
end

function ImportFlow.import_files_to_new_bottom_tracks(entries, undo_label, opts)
  if type(entries) ~= "table" or #entries == 0 then
    return false, t("No media files to import."), 0, nil
  end

  local options = opts or {}
  local original_cursor_position = r.GetCursorPosition()
  local import_position = tonumber(options.position)
  if not import_position or import_position ~= import_position then
    import_position = original_cursor_position
  end
  local created_tracks = {}
  local imported_count = 0
  local undo_open = false
  local refresh_open = false
  local import_result = nil

  local ok_import, import_err = xpcall(function()
    r.Undo_BeginBlock2(0)
    undo_open = true
    r.PreventUIRefresh(1)
    refresh_open = true

    r.Main_OnCommand(40297, 0)

    local media_table = {}
    for _, entry in ipairs(entries) do
      local media_path = Util.trim(entry and entry.full_path or "")
      if media_path == "" or not r.file_exists(media_path) then
        error(string.format(t("Media file is missing: %s"), media_path))
      end

      local track, track_err = ImportFlow.create_destination_track_at_bottom(
        entry and entry.track_name or "",
        entry and entry.fallback_track_name or t("Imported media")
      )
      if not track then
        error(track_err or t("Failed to create destination track."))
      end

      created_tracks[#created_tracks + 1] = track
      r.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)

      media_table[#media_table + 1] = {
        track = track,
        media_to_add = {
          {
            position = import_position,
            full_path = media_path
          }
        }
      }
    end

    local ok_media, media_err, media_result = ImportMedia.add_media(media_table, {
      manage_transaction = false,
      trigger_build_peaks_for_added_media = true
    })
    import_result = media_result
    imported_count = tonumber(media_result and media_result.created_count) or 0
    if not ok_media then
      error(tostring(media_err or t("Media import failed.")))
    end

    r.Main_OnCommand(40297, 0)
    for _, track in ipairs(created_tracks) do
      r.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)
    end

    r.SetEditCurPos(original_cursor_position, false, false)
    r.PreventUIRefresh(-1)
    refresh_open = false
    r.Undo_EndBlock2(0, undo_label or t("Auphonic add media to project"), -1)
    undo_open = false
  end, function(err)
    return debug.traceback(err, 2)
  end)

  if refresh_open then
    pcall(r.PreventUIRefresh, -1)
  end
  r.SetEditCurPos(original_cursor_position, false, false)
  if undo_open then
    local failed_label = string.format(t("%s (failed)"), tostring(undo_label or t("Auphonic add media to project")))
    pcall(r.Undo_EndBlock2, 0, failed_label, -1)
  end
  ImportFlow.refresh_track_list_and_arrange()

  if not ok_import then
    return false, tostring(import_err), imported_count, import_result
  end

  return true, nil, imported_count, import_result
end

function ImportFlow.capture_job_insertion_anchor()
  local selection_start, selection_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  local anchor = {project = r.EnumProjects(-1)}
  if type(selection_start) == "number" and type(selection_end) == "number"
    and selection_start > -math.huge and selection_end < math.huge and selection_end > selection_start then
    anchor.selection_start = selection_start
  end
  return anchor
end

function ImportFlow.result_import_options()
  -- Resolve the mode for this download; cursor mode reads the cursor only when
  -- import actually runs. The job's selection anchor is never read from the UI again.
  if S.result_insert_position ~= "selection_start" then return {} end
  local anchor = S.production_insert_anchor
  if not anchor or type(anchor.selection_start) ~= "number" then
    return nil, t("No selection start was captured for this job. Choose edit cursor or create a new job with a time selection.")
  end
  if r.EnumProjects(-1) ~= anchor.project then
    return nil, t("The captured selection belongs to another project. Switch back to the job's project before importing at its selection start.")
  end
  return {position = anchor.selection_start}
end

function ImportFlow.import_mixdown_to_project(destination_file_full_path, options)
  local track_name = FileNames.track_name_from_file_path(destination_file_full_path, t("Mixdown"))
  return ImportFlow.import_files_to_new_bottom_tracks({
    {
      full_path = destination_file_full_path,
      track_name = track_name,
      fallback_track_name = t("Mixdown")
    }
  }, t("Auphonic add mixdown to project"), options)
end

function ImportFlow.stem_rename_warning(renamed_files)
  if #(renamed_files or {}) == 0 then return nil end
  local names = {}
  for _, renamed in ipairs(renamed_files) do
    names[#names + 1] = tostring(renamed.original_filename) .. " -> " .. tostring(renamed.filename)
  end
  return string.format(t("Stem files were renamed to avoid overwriting existing files:\n%s"), table.concat(names, "\n"))
end

function ImportFlow.import_extracted_stems_to_project(audio_files, options)
  if type(audio_files) ~= "table" or #audio_files == 0 then
    return false, t("No extracted stem audio files to import."), 0
  end

  local entries = {}
  for _, stem in ipairs(audio_files) do
    local stem_path = Util.trim(stem and stem.path or "")
    local stem_id = Util.trim(stem and stem.stem_id or "")
    entries[#entries + 1] = {
      full_path = stem_path,
      track_name = stem_id,
      fallback_track_name = t("Stem")
    }
  end

  local ok_import, import_err, imported_count, import_result =
    ImportFlow.import_files_to_new_bottom_tracks(entries, t("Auphonic add stems to project"), options)
  if ok_import then
    DiaFlow.remember_imported_stems_for_dia(audio_files, import_result)
  else
    DiaFlow.clear_dia_runtime_state()
  end
  return ok_import, import_err, imported_count, import_result
end

function DiaFlow.run_dia_mix_render()
  local telemetry_started_at = TelemetryBridge.now()
  local function dia_payload(extra)
    local payload = {
      selected_dia_candidate_count = DiaFlow.selected_dia_candidate_count(),
      dia_wav_bit_depth = DiaFlow.current_dia_wav_bit_depth(),
      dia_candidate_count = #(S.dia_candidates or {})
    }
    if type(extra) == "table" then
      for k, v in pairs(extra) do
        payload[k] = v
      end
    end
    return payload
  end
  local function finish_dia_failed(err_text, stage, event_name)
    TelemetryBridge.operation_failed("automix_dia_render", dia_payload({
      safe_message = tostring(err_text or ""),
      dia_stage = tostring(stage or "")
    }), telemetry_started_at, event_name or "operation_failed")
  end

  TelemetryBridge.operation_started("automix_dia_render", dia_payload({
    dia_stage = "start"
  }))

  local supported, support_err = DiaFlow.dia_render_mode_supported()
  if not supported then
    S.dia_last_error = support_err or t("DIA render is not supported by this REAPER version.")
    S.dia_last_status = S.dia_last_error
    S.status_text = S.dia_last_error
    RuntimeState.push_warning_once(S.dia_last_error)
    finish_dia_failed(S.dia_last_error, "capability", "render_failed")
    return false, S.dia_last_error
  end

  local ok_api, api_err = DiaFlow.ensure_dia_selection_api()
  if not ok_api then
    S.dia_last_error = api_err or t("DIA render selection API is unavailable.")
    S.dia_last_status = S.dia_last_error
    S.status_text = S.dia_last_error
    RuntimeState.push_warning_once(S.dia_last_error)
    finish_dia_failed(S.dia_last_error, "api", "render_failed")
    return false, S.dia_last_error
  end

  local checked, checked_err = DiaFlow.get_checked_dia_candidates()
  if not checked then
    S.dia_last_error = checked_err or t("Select at least one imported stem for the DIA mix.")
    S.dia_last_status = S.dia_last_error
    S.status_text = S.dia_last_error
    finish_dia_failed(S.dia_last_error, "selection", "render_failed")
    return false, S.dia_last_error
  end

  local target, target_err = DiaFlow.build_dia_output_target()
  if not target then
    S.dia_last_error = target_err or t("Failed to prepare DIA render path.")
    S.dia_last_status = S.dia_last_error
    S.status_text = S.dia_last_error
    RuntimeState.push_warning_once(S.dia_last_error)
    finish_dia_failed(S.dia_last_error, "target", "render_failed")
    return false, S.dia_last_error
  end

  local sample_rate_warning = DiaFlow.dia_project_sample_rate_warning()
  if sample_rate_warning then
    RuntimeState.push_warning_once(sample_rate_warning)
  end

  local items_to_render = {}
  for _, candidate in ipairs(checked) do
    items_to_render[#items_to_render + 1] = candidate.item
  end

  local previous_selected_items = ReaperRefs.snapshot_selected_media_items()
  S.dia_last_error = ""
  S.dia_last_status = string.format(t("Rendering DIA mix from %d stem item(s)..."), #checked)
  S.status_text = S.dia_last_status

  local render_ok, render_msg = RenderSettings.with_render_settings(DiaFlow.build_dia_render_profile(target), function()
    ReaperRefs.select_only_media_items(items_to_render)
    r.Main_OnCommand(42230, 0)
    if not r.file_exists(target.output_path) then
      return false, string.format(t("DIA render output was not created: %s"), target.output_path), nil
    end
    return true, t("ok"), target.output_path
  end)

  if not render_ok then
    ReaperRefs.restore_selected_media_items(previous_selected_items)
    S.dia_last_error = tostring(render_msg or t("DIA render failed."))
    S.dia_last_status = S.dia_last_error
    S.status_text = S.dia_last_error
    RuntimeState.push_warning_once(S.dia_last_error)
    finish_dia_failed(S.dia_last_error, "render", "render_failed")
    return false, S.dia_last_error
  end

  local import_position = DiaFlow.earliest_dia_candidate_position(checked)
  local dia_track_name = FileNames.track_name_from_file_path(target.output_path, t("DIA mix"))
  local imported, import_err, _imported_count, import_result = ImportFlow.import_files_to_new_bottom_tracks({
    {
      full_path = target.output_path,
      track_name = dia_track_name,
      fallback_track_name = t("DIA mix")
    }
  }, t("Auphonic add DIA mix to project"), {
    position = import_position
  })

  if not imported then
    S.dia_last_error = tostring(import_err or t("DIA mix rendered, but import failed."))
    S.dia_last_status = S.dia_last_error
    S.status_text = S.dia_last_error
    RuntimeState.push_warning_once(S.dia_last_error)
    finish_dia_failed(S.dia_last_error, "import", "operation_failed")
    return false, S.dia_last_error
  end

  S.dia_last_output_path = target.output_path
  S.dia_last_imported_path = target.output_path
  S.dia_last_error = ""
  S.dia_last_status = string.format(t("DIA mix rendered and imported: %s"), target.output_path)
  S.status_text = S.dia_last_status
  S.last_api_error = ""

  if type(import_result) == "table" and tonumber(import_result.created_count) ~= 1 then
    RuntimeState.push_warning_once(string.format(t("DIA mix import created an unexpected number of items: %s"), tostring(import_result.created_count)))
  end

  TelemetryBridge.operation_completed("automix_dia_render", dia_payload({
    dia_stage = "imported",
    output_path = target.output_path,
    imported_path = S.dia_last_imported_path,
    imported_count = tonumber(import_result and import_result.created_count) or 0,
    duration_ms = TelemetryBridge.duration_ms(telemetry_started_at)
  }))

  return true, S.dia_last_status
end

function RuntimeState.clear_render_result()
  S.rendered_files_in_order = nil
  S.has_render_result = false
end

function RuntimeState.clear_production_runtime_state()
  S.production_details = nil
  S.production_insert_anchor = nil
  S.creation_uncertain, S.start_uncertain = false, false
  S.upload_confirmed, S.output_setup_confirmed = false, false
  S.pending_output_adjustment = nil
  S.selected_download_output = nil
  S.selected_stems_output = nil
  S.inserted_mix_path = ""
  S.imported_stems_extract_dir = ""
  S.imported_stems_count = 0
  S.imported_stems_renamed_files = {}
  DiaFlow.clear_dia_runtime_state()
  S.production_ready_to_start = false
  S.production_started_flag = false
  S.production_poll_active = false
  S.production_poll_next_at = nil
  S.production_poll_last_interval_sec = nil
  S.pending_paid_start_popup = false
  S.pending_cleanup_prompt = false
  S.cleanup_prompt_download_path = ""
end

function RuntimeState.clear_preset_state()
  S.presets = {}
  S.preset_details_by_uuid = {}
  S.selected_preset_idx = nil
  S.selected_preset_details = {}
  S.create_stems_archive = false
  S.tracks = nil
  S.selected_tracks_indexes = {}
  S.has_duplicate = {}
  S.project_track_matched = {}
  RuntimeState.clear_production_runtime_state()
  RuntimeState.clear_render_result()
end

function ReaperRefs.build_tracks_index()
  local number_of_tracks = r.CountTracks(0)
  local index = {
    lookup_by_index = {},
    index_lookup_by_original_name = {},
    dup_count = {},
    list = {}
  }

  for i = 0, number_of_tracks - 1 do
    local current_track = r.GetTrack(0, i)
    local _, current_track_name = r.GetSetMediaTrackInfo_String(current_track, "P_NAME", "", false)
    local sanitized_track_name = Util.trim(current_track_name)
    if not index.index_lookup_by_original_name[sanitized_track_name] then
      index.index_lookup_by_original_name[sanitized_track_name] = i + 1
    end
    index.dup_count[sanitized_track_name] = (index.dup_count[sanitized_track_name] or 0) + 1
    index.list[#index.list + 1] = string.format(t("%d: %s"), i + 1, sanitized_track_name)
    index.lookup_by_index[#index.lookup_by_index + 1] = current_track
  end

  return index
end

function RuntimeState.rebuild_warnings()
  S.warnings = {}
  S.last_check_error = ""
  ProjectPaths.refresh_project_relative_paths()

  if S.project_path == "" then
    RuntimeState.push_warning(t("Project path not available (unsaved project?). Some features may be limited."))
  else
    if Util.has_non_ascii(S.project_path) then
      RuntimeState.push_warning(t("Project path contains non-ASCII characters. This can cause trouble for external tools on Windows."))
    end
    if Util.has_quoting_risk(S.project_path) then
      RuntimeState.push_warning(t("Project path contains characters that require careful quoting (quotes or newlines)."))
    end
  end

  local ok_tmp, tmp_err = Files.ensure_tmp_dir(CFG.tmp_dir)
  S.tmp_writable = (ok_tmp == true)
  if not ok_tmp then
    S.last_check_error = tostring(tmp_err or t("Unknown error ensuring temp directory."))
    RuntimeState.push_warning(t("Temp directory is NOT writable. See error below."))
    RuntimeState.push_warning(S.last_check_error)
  else
    if Util.has_non_ascii(CFG.tmp_dir) then
      RuntimeState.push_warning(t("Temp directory path contains non-ASCII characters. May affect external tool behavior on Windows."))
    end
    if Util.has_quoting_risk(CFG.tmp_dir) then
      RuntimeState.push_warning(t("Temp directory path contains quotes/newlines and will be carefully quoted later."))
    end
  end

  S.checks_ran = true
end

function PresetFlow.output_file_format(output)
  if type(output) ~= "table" then return "" end
  return string.lower(Util.trim(output.format or ""))
end

function PresetFlow.preset_has_tracks_output(details)
  if type(details) ~= "table" or type(details.output_files) ~= "table" then
    return false
  end
  for _, output in ipairs(details.output_files) do
    if PresetFlow.output_file_format(output) == "tracks" then
      return true
    end
  end
  return false
end

function PresetFlow.clone_output_file_request(output)
  if type(output) ~= "table" then return nil end
  local format = Util.trim(output.format or "")
  if format == "" then return nil end

  local out = {}
  local delivery = { download_url = true, size = true, size_string = true }
  for key, value in pairs(output) do
    if not delivery[key] then out[key] = value end
  end
  out.format = format
  return out
end

function PresetFlow.copy_preset_non_tracks_output_files(details)
  local outputs = {}
  if type(details) ~= "table" or type(details.output_files) ~= "table" then
    return outputs
  end
  for _, output in ipairs(details.output_files) do
    if PresetFlow.output_file_format(output) ~= "tracks" then
      local cloned = PresetFlow.clone_output_file_request(output)
      if cloned then
        outputs[#outputs + 1] = cloned
      end
    end
  end
  return outputs
end

function PresetFlow.apply_selected_preset_details()
  local idx = tonumber(S.selected_preset_idx)
  local preset = idx and S.presets[idx] or nil
  if preset and preset.uuid and S.preset_details_by_uuid[preset.uuid] then
    S.selected_preset_details = S.preset_details_by_uuid[preset.uuid]
  else
    S.selected_preset_details = {}
  end
  S.create_stems_archive = PresetFlow.preset_has_tracks_output(S.selected_preset_details)
end

function PresetFlow.rebuild_track_matching()
  S.tracks = ReaperRefs.build_tracks_index()
  S.selected_tracks_indexes = {}
  S.has_duplicate = {}
  S.project_track_matched = {}

  local details = S.selected_preset_details
  if type(details) == "table" and type(details.multi_input_files) == "table" then
    for j, file_details in ipairs(details.multi_input_files) do
      local file_id = tostring(file_details and file_details.id or "")
      local matched_index = S.tracks.index_lookup_by_original_name[file_id]
      if matched_index then
        S.selected_tracks_indexes[j] = matched_index
        S.has_duplicate[j] = (S.tracks.dup_count[file_id] or 0) > 1
        S.project_track_matched[j] = true
      else
        if #S.tracks.list > 0 then
          S.selected_tracks_indexes[j] = 1
        end
        S.has_duplicate[j] = nil
        S.project_track_matched[j] = false
      end
    end
  end

  RuntimeState.rebuild_warnings()
end

function PresetFlow.clone_array_of_strings(items)
  local out = {}
  if type(items) ~= "table" then return out end
  for i = 1, #items do
    out[i] = tostring(items[i] or "")
  end
  return out
end

function PresetFlow.get_selected_download_output_from_details(details)
  if type(details) ~= "table" or type(details.output_files) ~= "table" then
    return nil
  end

  local fallback = nil
  for _, output in ipairs(details.output_files) do
    if type(output) == "table" then
      local filename = Util.trim(output.filename or "")
      local format = string.lower(Util.trim(output.format or ""))
      if filename ~= "" then
        if format ~= "tracks" and FileNames.file_name_looks_like_audio(filename) then
          return output
        end
        if format ~= "tracks" and not fallback then
          fallback = output
        end
      end
    end
  end

  return fallback
end

function PresetFlow.get_selected_stems_output_from_details(details)
  if type(details) ~= "table" or type(details.output_files) ~= "table" then
    return nil
  end

  for _, output in ipairs(details.output_files) do
    if type(output) == "table" then
      local format = string.lower(Util.trim(output.format or ""))
      local ending = string.lower(Util.trim(output.ending or ""))
      local filename = Util.trim(output.filename or "")
      local lower_filename = string.lower(filename)
      local looks_like_zip = lower_filename:match("%.zip$") ~= nil or ending:match("%.zip$") ~= nil
      if format == "tracks" and filename ~= "" and looks_like_zip then
        return output
      end
    end
  end

  return nil
end

function PresetFlow.refresh_selected_download_outputs()
  S.selected_download_output = PresetFlow.get_selected_download_output_from_details(S.production_details)
  S.selected_stems_output = PresetFlow.get_selected_stems_output_from_details(S.production_details)
  return S.selected_download_output, S.selected_stems_output
end

function PresetFlow.refresh_selected_download_output()
  PresetFlow.refresh_selected_download_outputs()
  return S.selected_download_output
end

function ProductionFlow.production_has_terminal_error()
  local details = S.production_details
  if type(details) ~= "table" then return false, nil end
  local error_message = Util.trim(details.error_message or "")
  if error_message == "" and tonumber(details.status) == 2 then error_message = t("Production processing failed.") end
  if error_message == "" then return false, nil end
  return true, error_message
end

function ProductionFlow.production_is_ready_for_download()
  if not AuphonicAPI.production_is_done(S.production_details) then return false, nil, nil end
  local output, stems_output = PresetFlow.refresh_selected_download_outputs()
  if not output and not stems_output then return false, nil, nil end
  return true, output, stems_output
end

function ProductionFlow.production_status_code(details)
  if type(details) ~= "table" then return nil end
  return tonumber(details.status)
end

function ProductionFlow.details_wait_for_paid_start(details)
  if type(details) ~= "table" then return false end
  local status = ProductionFlow.production_status_code(details)
  return details.start_allowed == true or status == 10
end

function ProductionFlow.details_are_server_started(details)
  local status = ProductionFlow.production_status_code(details)
  if not status then return false end
  return status == 1 or (status >= 4 and status <= 8) or status == 12 or status == 13 or status == 14
end

function ProductionFlow.sync_lifecycle_flags_from_details(details)
  if type(details) ~= "table" then return end

  local status = ProductionFlow.production_status_code(details)
  if details.start_allowed == true or status == 10 then
    S.production_ready_to_start = S.upload_confirmed and S.output_setup_confirmed and not S.start_uncertain
    S.production_started_flag = false
    return
  end

  S.production_ready_to_start = false
  if ProductionFlow.details_are_server_started(details) or status == 2 or status == 3 then
    S.production_started_flag = true
    S.start_uncertain = false
  elseif status == 9 or status == 10 then
    S.production_started_flag = false
  end
end

function ProductionFlow.next_production_poll_interval_sec()
  local min_sec = tonumber(CFG.production_poll_min_sec) or 10
  local max_sec = tonumber(CFG.production_poll_max_sec) or 20
  min_sec = math.floor(min_sec)
  max_sec = math.floor(max_sec)
  if min_sec < 1 then min_sec = 1 end
  if max_sec < min_sec then max_sec = min_sec end
  if min_sec == max_sec then
    return min_sec
  end
  return math.random(min_sec, max_sec)
end

function ProductionFlow.schedule_next_production_poll(now_t)
  local interval = ProductionFlow.next_production_poll_interval_sec()
  S.production_poll_last_interval_sec = interval
  S.production_poll_next_at = (tonumber(now_t) or r.time_precise()) + interval
  return interval
end

function ProductionFlow.stop_production_polling()
  S.production_poll_active = false
  S.production_poll_next_at = nil
  S.production_poll_last_interval_sec = nil
end

function RenderFlow.build_render_summary(track_count, duration_sec, rendered_files)
  local count = tonumber(track_count) or 0
  local duration_text = t("unknown duration")
  if tonumber(duration_sec) and duration_sec > 0 then
    duration_text = r.format_timestr_pos(duration_sec, "", 5)
  end

  local file_count = 0
  if type(rendered_files) == "table" then
    file_count = #rendered_files
  end

  return string.format(
    t("Rendered %d tracks (%s) to %d .flac files in %s"),
    count,
    duration_text,
    file_count,
    tostring(CFG.tmp_dir or "")
  )
end

function RenderFlow.set_render_failure(err_text)
  S.render_last_error = tostring(err_text or t("Render failed."))
  S.status_text = S.render_last_error
  RuntimeState.push_warning(S.render_last_error)
end

function RenderFlow.build_local_render_profile(render_full_path)
  return {
    schema_version = 1,
    numeric = {
      RENDER_SETTINGS = 19,
      RENDER_BOUNDSFLAG = RenderSettings.RENDER_BOUNDSFLAG.TIME_SELECTION,
      RENDER_SRATE = 0,
      RENDER_CHANNELS = 2,
      RENDER_TAILFLAG = 0,
      PROJECT_SRATE_USE = 1,
      RENDER_ADDTOPROJ = 0
    },
    strings = {
      RENDER_FILE = render_full_path,
      RENDER_PATTERN = [=[$track]=],
      RENDER_FORMAT = RenderSettings.SINK_FORMATS.FLAC_16BIT
    }
  }
end

function RenderFlow.restore_track_names(tracks_table, old_names)
  if type(tracks_table) ~= "table" or type(old_names) ~= "table" then return end
  for i, tr in ipairs(tracks_table) do
    if tr and old_names[i] ~= nil then
      r.GetSetMediaTrackInfo_String(tr, "P_NAME", tostring(old_names[i]), true)
    end
  end
end

function RenderFlow.render_tracks(tracks_table)
  if type(tracks_table) ~= "table" or #tracks_table < 1 then
    return false, t("Bad tracks_table (nil or <1 track)!"), nil
  end

  local details = S.selected_preset_details
  if type(details) ~= "table" or type(details.multi_input_files) ~= "table" then
    return false, t("selected_preset_details has no valid multi_input_files table!"), nil
  end
  if #details.multi_input_files < 1 then
    return false, t("#selected_preset_details.multi_input_files <= 0"), nil
  end
  if #tracks_table ~= #details.multi_input_files then
    return false, t("Number of tracks to render and tracks number in production preset mismatch!"), nil
  end

  local safe_names = {}
  local old_names = {}
  local renamed_count = 0

  local function cleanup_names()
    if renamed_count > 0 then
      RenderFlow.restore_track_names(tracks_table, old_names)
    end
  end

  local ok_render, render_err = RenderSettings.with_render_settings(RenderFlow.build_local_render_profile(CFG.tmp_dir), function()
    local ok_work, work_err = xpcall(function()
      for i, _ in ipairs(tracks_table) do
        safe_names[i] = "Render_" .. tostring(i) .. "_" .. Util.date_time_stamp_with_time_precise()
      end

      r.Main_OnCommand(40297, 0)
      for i, tr in ipairs(tracks_table) do
        r.SetMediaTrackInfo_Value(tr, "I_SELECTED", 1)
        local _, current_track_name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        old_names[i] = current_track_name or ""
        if not Files.is_filesystem_safe_name(safe_names[i]) then
          error("Generated unsafe track name for render: " .. tostring(safe_names[i]))
        end
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", safe_names[i], true)
        renamed_count = i
      end

      r.Main_OnCommand(42230, 0)
    end, function(err)
      return debug.traceback(err, 2)
    end)

    cleanup_names()
    if not ok_work then
      return false, string.format(t("Render failed: %s"), tostring(work_err)), nil
    end

    return true, t("ok"), nil
  end)

  if not ok_render then
    cleanup_names()
    return false, tostring(render_err or t("Render failed.")), nil
  end

  local rendered_files_full_paths = {}
  for _, track_name in ipairs(safe_names) do
    local file_name = track_name .. ".flac"
    local full_name = Util.path_join(CFG.tmp_dir, file_name)
    if r.file_exists(full_name) then
      rendered_files_full_paths[#rendered_files_full_paths + 1] = full_name
    else
      return false, string.format(t("After render %s does not exist unexpectedly!"), tostring(full_name)), nil
    end
  end

  return true, t("ok"), rendered_files_full_paths
end

function RenderFlow.build_tracks_to_render()
  local tracks_to_render = {}
  if type(S.selected_tracks_indexes) ~= "table" or #S.selected_tracks_indexes == 0 then
    return nil, t("No selected tracks to render.")
  end
  if not (S.tracks and S.tracks.lookup_by_index) then
    return nil, t("Track lookup is not available.")
  end

  for _, track_index in ipairs(S.selected_tracks_indexes) do
    local track = S.tracks.lookup_by_index[track_index]
    if not track then
      return nil, string.format(t("Can't find track with index %s"), tostring(track_index))
    end
    tracks_to_render[#tracks_to_render + 1] = track
  end

  return tracks_to_render, nil
end

function RenderFlow.run_local_render()
  local rec = RecordFlow.get_or_create_misc_record("render", t("Render"), t("Render"))
  local ok_tmp, tmp_err = Files.ensure_tmp_dir(CFG.tmp_dir)
  S.tmp_writable = (ok_tmp == true)
  if not ok_tmp then
    local temp_err_text = string.format(t("Temp directory is not writable: %s"), tostring(tmp_err or CFG.tmp_dir or ""))
    RecordFlow.finish_record_failed(rec, temp_err_text, nil, t("failed"))
    RenderFlow.set_render_failure(temp_err_text)
    return
  end

  local sel_start, sel_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  local sel_duration = sel_end - sel_start
  if sel_duration <= 0 then
    RecordFlow.finish_record_failed(rec, t("Render unavailable: check time selection."), nil, t("failed"))
    RenderFlow.set_render_failure(t("Render unavailable: check time selection."))
    return
  end

  local tracks_to_render, track_err = RenderFlow.build_tracks_to_render()
  if not tracks_to_render then
    RecordFlow.finish_record_failed(rec, track_err or t("Track selection is invalid."), nil, t("failed"))
    RenderFlow.set_render_failure(track_err or t("Track selection is invalid."))
    return
  end

  RecordFlow.begin_record(rec, string.format(t("%d tracks"), #tracks_to_render))
  S.render_last_error = ""
  S.status_text = string.format(t("Rendering %d selected tracks..."), #tracks_to_render)
  local result, message, rendered_files = RenderFlow.render_tracks(tracks_to_render)
  if result and rendered_files then
    S.rendered_files_in_order = rendered_files
    S.has_render_result = true
    S.render_last_error = ""
    S.render_last_summary = RenderFlow.build_render_summary(#tracks_to_render, sel_duration, rendered_files)
    S.status_text = S.render_last_summary
    RecordFlow.finish_record_ok(rec, S.render_last_summary, nil)
    return
  end

  RecordFlow.finish_record_failed(rec, message or t("Render failed."), nil, t("failed"))
  RenderFlow.set_render_failure(message or t("Render failed."))
end

function RenderFlow.render_local_render_section()
  local sel_start, sel_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  local sel_duration = sel_end - sel_start

  local details = S.selected_preset_details
  local has_preset_inputs = type(details) == "table" and type(details.multi_input_files) == "table"
  local duplicates_or_no_match_flag = false
  for j, _ in ipairs(S.selected_tracks_indexes or {}) do
    if S.has_duplicate[j] or (S.project_track_matched[j] ~= true) then
      duplicates_or_no_match_flag = true
      break
    end
  end
  local missing_track_selection =
    (not has_preset_inputs) or
    (#S.selected_tracks_indexes == 0) or
    (not S.tracks) or
    (not S.tracks.lookup_by_index)

  local conditions_met =
    has_preset_inputs and
    (#S.selected_tracks_indexes > 0) and
    (sel_duration > 0) and
    S.tracks and
    S.tracks.lookup_by_index and
    CFG.tmp_dir and
    (CFG.tmp_dir ~= "") and
    (S.tmp_writable == true) and
    (not duplicates_or_no_match_flag)

  local render_button_label = ""
  if conditions_met then
    local duration_hh_mm_ss_ff = r.format_timestr_pos(sel_duration, "", 5)
    render_button_label = string.format(
      t("Render %d tracks (duration %s)"),
      #S.selected_tracks_indexes,
      duration_hh_mm_ss_ff
    )
  else
    local unavailable_reasons = {}
    if sel_duration <= 0 then
      unavailable_reasons[#unavailable_reasons + 1] = t("Check time selection!")
    end
    if duplicates_or_no_match_flag or missing_track_selection then
      unavailable_reasons[#unavailable_reasons + 1] = t("Check track selection!")
    end
    if S.tmp_writable ~= true then
      unavailable_reasons[#unavailable_reasons + 1] = t("Check temp folder!")
    end
    if #unavailable_reasons > 0 then
      render_button_label = string.format(t("Render unavailable! %s"), table.concat(unavailable_reasons, " "))
    else
      render_button_label = t("Render unavailable!")
    end
  end

  if not conditions_met then
    ImGui.BeginDisabled(ctx, true)
  end
  if UI.button_clicked("render_btn", render_button_label) then
    RenderFlow.run_local_render()
  end
  ImGui.SameLine(ctx)
  UI.ui_info(string.format(
    t("Time selection: start %s; end %s."),
    r.format_timestr_pos(sel_start, "", 5),
    r.format_timestr_pos(sel_end, "", 5)
  ))
  if not conditions_met then
    ImGui.EndDisabled(ctx)
  end

  if S.render_last_error ~= "" then
    UI.ui_warning(string.format(t("Last render error: %s"), S.render_last_error))
  end
end

function DiaFlow.render_dia_candidate_row(candidate, index)
  local valid_item = ReaperRefs.validate_reaper_ptr(candidate and candidate.item, "MediaItem*")
  if not valid_item then ImGui.BeginDisabled(ctx, true) end
  local changed, selected = ImGui.Checkbox(ctx, "##dia_candidate_selected_" .. tostring(index), candidate.selected == true)
  if changed then
    candidate.selected = selected
  end
  if not valid_item then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  ImGui.Text(ctx, tostring(candidate.display_name or candidate.track_name or t("Stem")))

  if not valid_item then
    ImGui.SameLine(ctx)
    UI.ui_warning(t("item missing"))
  end
end

function DiaFlow.render_dia_mix_section()
  if type(S.dia_candidates) ~= "table" or #S.dia_candidates == 0 then
    return
  end

  if not ImGui.CollapsingHeader(ctx, t("Create DIA mix")) then
    return
  end

  local supported, support_err = DiaFlow.dia_render_mode_supported()
  if not supported then
    UI.ui_warning(support_err or t("DIA render is not supported by this REAPER version."))
  end

  local sample_rate_warning = DiaFlow.dia_project_sample_rate_warning()
  if sample_rate_warning then
    UI.ui_warning(sample_rate_warning)
  end

  ImGui.Text(ctx, string.format(t("Imported stem candidates: %d"), #S.dia_candidates))
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, string.format(t("Selected: %d"), DiaFlow.selected_dia_candidate_count()))

  if UI.button_clicked("dia_select_voice_btn", t("Voice"), nil) then
    DiaFlow.set_dia_candidate_selection("voice")
  end
  ImGui.SameLine(ctx)
  if UI.button_clicked("dia_select_all_btn", t("All"), nil) then
    DiaFlow.set_dia_candidate_selection("all")
  end
  ImGui.SameLine(ctx)
  if UI.button_clicked("dia_select_none_btn", t("None"), nil) then
    DiaFlow.set_dia_candidate_selection("none")
  end

  if ImGui.BeginTable then
    local table_flags =
      ImGui.TableFlags_Borders |
      ImGui.TableFlags_RowBg |
      ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "##automix_tool_dia_candidates", 3, table_flags) then
      ImGui.TableSetupColumn(ctx, t("Use"), ImGui.TableColumnFlags_WidthFixed, 48)
      ImGui.TableSetupColumn(ctx, t("Stem"), ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, t("Source"), ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableHeadersRow(ctx)

      for index, candidate in ipairs(S.dia_candidates) do
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        local valid_item = ReaperRefs.validate_reaper_ptr(candidate and candidate.item, "MediaItem*")
        if not valid_item then ImGui.BeginDisabled(ctx, true) end
        local changed, selected = ImGui.Checkbox(ctx, "##dia_candidate_selected_table_" .. tostring(index), candidate.selected == true)
        if changed then
          candidate.selected = selected
        end
        if not valid_item then ImGui.EndDisabled(ctx) end

        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.TextWrapped(ctx, tostring(candidate.display_name or candidate.track_name or t("Stem")))
        if not valid_item then
          UI.ui_warning(t("item missing"))
        end

        ImGui.TableSetColumnIndex(ctx, 2)
        ImGui.TextWrapped(ctx, tostring(candidate.file_name or FileNames.path_basename(candidate.source_path or "")))
      end

      ImGui.EndTable(ctx)
    end
  else
    for index, candidate in ipairs(S.dia_candidates) do
      DiaFlow.render_dia_candidate_row(candidate, index)
    end
  end

  local current_bit_depth = DiaFlow.current_dia_wav_bit_depth()
  ImGui.Text(ctx, t("DIA WAV bit depth") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(
    ctx,
    "##automix_tool_dia_wav_bit_depth",
    DiaFlow.dia_wav_bit_depth_label(current_bit_depth),
    ImGui.ComboFlags_HeightRegular
  ) then
    local bit_depth_options = { 24, 16 }
    for _, bit_depth in ipairs(bit_depth_options) do
      local is_selected = current_bit_depth == bit_depth
      local activated = ImGui.Selectable(ctx, DiaFlow.dia_wav_bit_depth_label(bit_depth), is_selected)
      if activated then
        S.dia_wav_bit_depth = bit_depth
        current_bit_depth = bit_depth
        RuntimeState.persist_dia_wav_bit_depth(bit_depth)
      end
      if is_selected then
        ImGui.SetItemDefaultFocus(ctx)
      end
    end
    ImGui.EndCombo(ctx)
  end

  local can_render = supported and DiaFlow.selected_dia_candidate_count() > 0
  if not can_render then ImGui.BeginDisabled(ctx, true) end
  local dia_render_button_label = string.format(
    t("Render DIA mix (%s)"),
    DiaFlow.dia_wav_bit_depth_label(current_bit_depth)
  )
  if UI.button_clicked("dia_render_btn", dia_render_button_label) then
    DiaFlow.run_dia_mix_render()
  end
  if not can_render then ImGui.EndDisabled(ctx) end

  if S.dia_last_error ~= "" then
    UI.ui_warning(string.format(t("Last DIA render error: %s"), S.dia_last_error))
  elseif S.dia_last_status ~= "" then
    UI.ui_info(S.dia_last_status)
  end

  if S.dia_last_output_path ~= "" then
    ImGui.Text(ctx, t("DIA mix path:"))
    ImGui.SetNextItemWidth(ctx, -10.0)
    ImGui.InputText(ctx, "##automix_tool_dia_mix_path", S.dia_last_output_path, ImGui.InputTextFlags_ReadOnly)
  end
end

function MainUI.render_production_lifecycle_section()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_SeparatorTextAlign, 0.15, 0.5)
  ImGui.SeparatorText(ctx, t("Mixdown"))
  ImGui.PopStyleVar(ctx)

  FileNames.ensure_production_name_input()
  ImGui.Text(ctx, t("Mix name:"))
  ImGui.SetNextItemWidth(ctx, -10.0)
  local changed_name, new_name = ImGui.InputText(ctx, "##automix_tool_mix_name", S.production_name_input or "")
  if changed_name then
    S.production_name_input = new_name
  end

  local details = S.selected_preset_details
  local can_create =
    (S.access_token ~= "") and
    (S.production_details == nil) and (not S.creation_uncertain) and
    (type(details) == "table") and
    (details.is_multitrack == true) and
    (Util.trim(details.uuid or "") ~= "") and
    (type(details.multi_input_files) == "table") and
    (type(S.rendered_files_in_order) == "table") and
    (#details.multi_input_files == #S.rendered_files_in_order) and
    (#S.rendered_files_in_order > 0) and
    (Jobs.network_busy() ~= true)

  if not can_create then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("create_and_upload_btn", t("Create production and upload")) then
    ProductionFlow.schedule_create_production_flow()
  end
  if not can_create then ImGui.EndDisabled(ctx) end

  local production_uuid = Util.trim((S.production_details and S.production_details.uuid) or "")
  if production_uuid ~= "" or S.creation_uncertain then
    local busy = Jobs.network_busy()
    if busy then ImGui.BeginDisabled(ctx, true) end
    if UI.button_clicked("new_production_btn", t("New production")) then
      local message = S.creation_uncertain
        and t("Creation outcome is uncertain. Check the backend for an existing production first. Have you checked and do you want to reset this window?")
        or t("This forgets the current production in this window. It does not cancel it on the server. Continue?")
      if r.MB(message, t("New production"), 4) == 6 then
        RuntimeState.clear_production_runtime_state()
        production_uuid = ""
      end
    end
    if busy then ImGui.EndDisabled(ctx) end
  end
  if production_uuid ~= "" and not Jobs.network_busy() and not S.production_started_flag then
    if S.pending_output_adjustment then
      if UI.button_clicked("continue_outputs_btn", t("Check and continue output setup")) then
        RecordFlow.schedule_job_or_status(t("Output setup"), function()
          local rec = RecordFlow.get_or_create_misc_record("create_production", t("Output setup"), t("Output setup"))
          RecordFlow.begin_record(rec, t("Checking production outputs"))
          ProductionFlow.submit_created_production_output_adjustment(
            ClientFactory.create_auphonic_client(t("Output setup")), rec,
            production_uuid, S.pending_output_adjustment)
        end)
      end
    elseif S.output_setup_confirmed and not S.upload_confirmed then
      if UI.button_clicked("continue_uploads_btn", t("Check and continue uploads")) then
        RecordFlow.schedule_job_or_status(t("Upload audio"), ProductionFlow.submit_upload_audio_flow)
      end
    end
  end
  if S.start_uncertain then
    UI.ui_warning(t("Start outcome is uncertain. Check status; do not start another production."))
  end
  local production_status = t("No production yet.")
  if type(S.production_details) == "table" then
    local status_string = Util.trim(S.production_details.status_string or "")
    if status_string ~= "" then
      production_status = status_string
    elseif S.production_ready_to_start then
      production_status = t("Uploaded. Waiting for explicit paid start.")
    elseif S.production_started_flag then
      production_status = t("Started. Waiting for status update.")
    else
      production_status = t("Created.")
    end
  end

  local is_ready, output, stems_output = ProductionFlow.production_is_ready_for_download()
  local status_line = ""
  if is_ready then
    status_line = t("Production status: DONE")
  elseif S.production_poll_active and S.production_poll_next_at then
    local remaining = math.max(0, math.ceil(S.production_poll_next_at - r.time_precise()))
    status_line = string.format(t("Production status: %s. Next poll in %d sec."), production_status, remaining)
  elseif S.production_ready_to_start then
    status_line = string.format(t("Production status: %s. Ready for explicit paid start."), production_status)
  else
    status_line = string.format(t("Production status: %s"), production_status)
  end

  if is_ready then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00FF00FF)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x3399FFFF)
  end
  ImGui.TextWrapped(ctx, status_line)
  ImGui.PopStyleColor(ctx)

  if production_uuid ~= "" then
    ImGui.Text(ctx, t("Production UUID:"))
    ImGui.SetNextItemWidth(ctx, -10.0)
    ImGui.InputText(ctx, "##automix_tool_production_uuid", production_uuid, ImGui.InputTextFlags_ReadOnly)
  end

  local can_start =
    (production_uuid ~= "") and
    (S.production_ready_to_start == true) and (not S.start_uncertain) and
    (Jobs.network_busy() ~= true)
  if not can_start then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("start_production_btn", t("Start production (paid)")) then
    RecordFlow.schedule_job_or_status(t("Start production"), ProductionFlow.submit_start_production_flow, t("Could not schedule production start."))
  end
  if not can_start then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  local can_check = (production_uuid ~= "") and (Jobs.network_busy() ~= true)
  if not can_check then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("manual_status_btn", t("Check status"), CFG.manual_status_check_cooldown_sec) then
    RecordFlow.schedule_job_or_status(
      t("Manual production status"),
      function()
        ProductionFlow.submit_production_status_flow(true)
      end,
      t("Could not schedule production status check.")
    )
  end
  if not can_check then ImGui.EndDisabled(ctx) end

  local network_busy = Jobs.network_busy() == true
  local can_download = is_ready and (type(output) == "table") and (not network_busy)
  local download_button_label = t("Download and add to project")
  if can_download and type(output) == "table" and Util.trim(output.filename or "") ~= "" then
    download_button_label = string.format(t("Download and add to project %s"), tostring(output.filename))
  end
  if not can_download then ImGui.BeginDisabled(ctx, true) end
  if can_download then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x00AA00FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x00CC00FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x008800FF)
  end
  if UI.button_clicked("download_import_btn", download_button_label) then
    RecordFlow.schedule_job_or_status(t("Download and import"), ProductionFlow.submit_download_and_import_flow, t("Could not schedule download."))
  end
  if can_download then
    ImGui.PopStyleColor(ctx, 3)
  end
  if not can_download then ImGui.EndDisabled(ctx) end

  local can_download_stems = is_ready and (type(stems_output) == "table") and (not network_busy)
  local stems_button_label = t("Download and add to project stems")
  if type(stems_output) == "table" and Util.trim(stems_output.filename or "") ~= "" then
    stems_button_label = string.format(t("Download and add to project %s"), tostring(stems_output.filename))
  end
  if not can_download_stems then ImGui.BeginDisabled(ctx, true) end
  if can_download_stems then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x00AA00FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x00CC00FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x008800FF)
  end
  if UI.button_clicked("download_stems_btn", stems_button_label) then
    RecordFlow.schedule_job_or_status(t("Download stems"), ProductionFlow.submit_download_stems_flow, t("Could not schedule stem archive download."))
  end
  if can_download_stems then
    ImGui.PopStyleColor(ctx, 3)
  end
  if not can_download_stems then ImGui.EndDisabled(ctx) end

  local has_error, error_message = ProductionFlow.production_has_terminal_error()
  if has_error then
    UI.ui_warning(string.format(t("Server error: %s"), tostring(error_message)))
  end

  if S.inserted_mix_path ~= "" then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00FF00FF)
    ImGui.Text(ctx, t("Inserted mix path:"))
    ImGui.SetNextItemWidth(ctx, -10.0)
    ImGui.InputText(ctx, "##automix_tool_inserted_mix_path", S.inserted_mix_path, ImGui.InputTextFlags_ReadOnly)
    ImGui.PopStyleColor(ctx)
  end

  if S.imported_stems_extract_dir ~= "" then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00FF00FF)
    ImGui.Text(ctx, string.format(t("Imported stems: %d tracks"), tonumber(S.imported_stems_count) or 0))
    ImGui.SetNextItemWidth(ctx, -10.0)
    ImGui.InputText(ctx, "##automix_tool_imported_stems_extract_dir", S.imported_stems_extract_dir, ImGui.InputTextFlags_ReadOnly)
    ImGui.PopStyleColor(ctx)
  end

  local rename_warning = ImportFlow.stem_rename_warning(S.imported_stems_renamed_files)
  if rename_warning then UI.ui_warning(rename_warning) end

  DiaFlow.render_dia_mix_section()
end

function PopupUI.center_next_popup_in_parent_window()
  if not ImGui.SetNextWindowPos then
    return
  end
  local pos_x = tonumber(S.main_window_pos_x)
  local pos_y = tonumber(S.main_window_pos_y)
  local size_w = tonumber(S.main_window_size_w)
  local size_h = tonumber(S.main_window_size_h)
  if not pos_x or not pos_y or not size_w or not size_h then
    return
  end
  ImGui.SetNextWindowPos(
    ctx,
    pos_x + (size_w * 0.15),
    pos_y + (size_h * 0.25),
    ImGui.Cond_Always,
    0,
    0
  )
end

function PopupUI.render_paid_start_popup()
  local popup_id = "automix_tool_paid_start_popup"
  if S.pending_paid_start_popup then
    ImGui.OpenPopup(ctx, popup_id)
    S.pending_paid_start_popup = false
  end

  local popup_flags = ImGui.WindowFlags_AlwaysAutoResize
  PopupUI.center_next_popup_in_parent_window()
  local popup_open, _ = ImGui.BeginPopupModal(ctx, popup_id, true, popup_flags)
  if not popup_open then return end

  ImGui.TextWrapped(ctx, t("Uploading finished. Starting the production is a paid action on Auphonic."))
  ImGui.TextWrapped(ctx, t("You can start it now or leave it prepared and start it later from the main window."))
  ImGui.Separator(ctx)

  local can_start = (S.production_ready_to_start == true) and (Jobs.network_busy() ~= true)
  if not can_start then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("paid_start_now_btn", t("Start now")) then
    ImGui.CloseCurrentPopup(ctx)
    RecordFlow.schedule_job_or_status(t("Start production"), ProductionFlow.submit_start_production_flow, t("Could not schedule production start."))
  end
  if not can_start then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  if UI.button_clicked("paid_start_later_btn", t("Start later")) then
    ImGui.CloseCurrentPopup(ctx)
    S.status_text = t("Production is ready to start.")
  end

  ImGui.EndPopup(ctx)
end

function PopupUI.render_cleanup_prompt_popup()
  local popup_id = "automix_tool_cleanup_prompt_popup"
  if S.pending_cleanup_prompt then
    ImGui.OpenPopup(ctx, popup_id)
    S.pending_cleanup_prompt = false
  end

  local popup_flags = ImGui.WindowFlags_AlwaysAutoResize
  PopupUI.center_next_popup_in_parent_window()
  local popup_open, _ = ImGui.BeginPopupModal(ctx, popup_id, true, popup_flags)
  if not popup_open then return end

  ImGui.TextWrapped(ctx, t("The mix was downloaded and inserted successfully."))
  ImGui.TextWrapped(ctx, t("Delete the rendered temp source files now?"))
  if S.cleanup_prompt_download_path ~= "" then
    ImGui.Separator(ctx)
    ImGui.TextWrapped(ctx, string.format(t("Downloaded mix: %s"), S.cleanup_prompt_download_path))
  end

  if UI.button_clicked("cleanup_render_files_btn", t("Delete rendered temp files")) then
    local cleanup_started_at = TelemetryBridge.now()
    TelemetryBridge.operation_started("automix_cleanup_render_files", {
      rendered_file_paths = TelemetryBridge.rendered_file_paths(),
      rendered_file_count = #(S.rendered_files_in_order or {})
    })
    local ok_remove, remove_msg = RenderFlow.remove_rendered_source_files()
    if ok_remove then
      S.status_text = tostring(remove_msg or t("Rendered temp files removed."))
      S.last_api_error = ""
      TelemetryBridge.operation_completed("automix_cleanup_render_files", {
        safe_message = S.status_text
      }, cleanup_started_at)
    else
      S.status_text = t("Failed to remove rendered temp files.")
      S.last_api_error = tostring(remove_msg or t("Failed to remove rendered temp files."))
      RuntimeState.push_warning_once(S.last_api_error)
      TelemetryBridge.cleanup_failed({
        safe_message = S.last_api_error,
        rendered_file_paths = TelemetryBridge.rendered_file_paths()
      }, cleanup_started_at)
    end
    S.cleanup_prompt_download_path = ""
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.SameLine(ctx)
  if UI.button_clicked("keep_render_files_btn", t("Keep them")) then
    S.status_text = t("Rendered temp files were kept.")
    TelemetryBridge.emit_operation_event("operation_canceled", "automix_cleanup_render_files", "canceled", {
      safe_message = S.status_text,
      rendered_file_count = #(S.rendered_files_in_order or {})
    }, {
      priority = "normal"
    })
    S.cleanup_prompt_download_path = ""
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.EndPopup(ctx)
end

function RecordFlow.ensure_misc_records()
  if type(S.misc_records) ~= "table" then
    S.misc_records = {}
  end
end

function RecordFlow.get_or_create_misc_record(key, display_name, flow_label)
  RecordFlow.ensure_misc_records()
  for _, item in ipairs(S.misc_records) do
    if item and item._misc_key == key then
      if display_name and display_name ~= "" then item.record_name = display_name end
      if flow_label and flow_label ~= "" then item.flow_label = flow_label end
      return item
    end
  end

  local rec = {
    _misc_key = key,
    record_name = display_name or t("Request"),
    flow_label = flow_label or display_name or t("Request"),
    misc_start_time_override = "-",
    misc_job_id = nil
  }
  S.misc_records[#S.misc_records + 1] = rec
  return rec
end

function RecordFlow.reset_progress_state(reason)
  Jobs.reset_runtime(reason or t("reset progress"))
  S.misc_records = nil
  S.last_http = ""
  S.last_api_error = ""
  if S.last_curl_return then
    S.last_curl_return.ok = ""
    S.last_curl_return.http = ""
    S.last_curl_return.body = ""
    S.last_curl_return.headers_txt = ""
    S.last_curl_return.meta = ""
    S.last_curl_return.err = ""
    S.last_curl_return.cmd = ""
  end
end

function RecordFlow.begin_record(rec, progress_text, telemetry_opts)
  rec._attempt = 1
  rec._max_attempts = 1
  rec._retry_generation = S.retry_generation
  rec._retry_label = rec.record_name or t("Request")
  rec._state = "running"
  rec._next_retry_at = nil
  rec._last_error_summary = nil
  rec._last_http_code = nil
  rec._custom_progress = progress_text or ""
  TelemetryBridge.begin_record(rec, progress_text, telemetry_opts)
end

function RecordFlow.record_http_code(rec, http_code)
  if http_code ~= nil then
    rec._last_http_code = http_code
    S.last_http = tostring(http_code)
  end
end

function RecordFlow.finish_record_ok(rec, progress_text, http_code)
  rec._state = "ok"
  rec._custom_progress = progress_text or t("ok")
  RecordFlow.record_http_code(rec, http_code)
  rec.misc_job_id = nil
  TelemetryBridge.finish_record_ok(rec, rec._custom_progress)
end

function RecordFlow.finish_record_failed(rec, err_text, http_code, progress_text)
  rec._state = "failed_final"
  rec._last_error_summary = tostring(err_text or t("request failed"))
  rec._custom_progress = progress_text or t("failed")
  RecordFlow.record_http_code(rec, http_code)
  rec.misc_job_id = nil
  TelemetryBridge.finish_record_failed(rec, rec._last_error_summary, rec._custom_progress)
end

function RecordFlow.keep_record_running(rec, progress_text, http_code)
  rec._state = "running"
  rec._custom_progress = progress_text or t("running")
  RecordFlow.record_http_code(rec, http_code)
  rec.misc_job_id = nil
end

function RecordFlow.schedule_job_or_status(label, fn, fail_text)
  local scheduled = Jobs.schedule_job(label, fn)
  if not scheduled then
    S.status_text = fail_text or t("Request already running.")
    return false
  end
  return true
end

function RuntimeState.update_auth_state_from_payload(payload)
  S.access_token = tostring(payload.access_token or "")
  S.refresh_token = tostring(payload.refresh_token or "")
  if S.remember_me and S.refresh_token ~= "" then
    S.has_stored_refresh = true
  else
    S.has_stored_refresh = false
  end
end

function RuntimeState.sync_stored_refresh_flag()
  local auth_client = ClientFactory.create_auth_client("Stored login probe")
  local token, err = auth_client.load_refresh_token()
  if err then
    Util.msg("Stored refresh probe failed: " .. tostring(err), 2)
    S.has_stored_refresh = false
    return false
  end
  if type(token) == "string" and token ~= "" then
    S.refresh_token = token
    S.has_stored_refresh = true
    return true
  end
  S.has_stored_refresh = false
  return false
end

function RuntimeState.finish_stored_login_invalid(rec, payload)
  local auth_client = ClientFactory.create_auth_client("Stored login invalid")
  auth_client.forget_refresh_token()
  RuntimeState.forget_email()
  RuntimeState.clear_runtime_auth_state()
  S.has_stored_refresh = false
  RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Stored login invalid."), payload.http_code, t("failed"))
  S.status_text = t("Stored login invalid. Please log in again.")
  S.last_api_error = tostring(payload.api_error or payload.error or t("Stored login invalid."))
  S.auto_auth_finished = true
  S.auto_auth_success = false
end

function PresetFlow.submit_fetch_all_preset_details()
  local total = #S.presets
  local rec = RecordFlow.get_or_create_misc_record("preset_details", t("Fetch preset details"), t("Preset details"))
  RecordFlow.begin_record(rec, string.format(t("0/%d"), total))

  if total == 0 then
    RecordFlow.finish_record_ok(rec, t("0/0"), nil)
    S.status_text = t("No multitrack presets found.")
    S.last_api_error = ""
    PresetFlow.rebuild_track_matching()
    return true
  end

  local client = ClientFactory.create_auphonic_client("Preset details")

  local function submit_index(idx)
    if idx > total then
      if not S.selected_preset_idx and total > 0 then
        S.selected_preset_idx = 1
      end
      PresetFlow.apply_selected_preset_details()
      RecordFlow.finish_record_ok(rec, string.format(t("%d/%d"), total, total), nil)
      S.status_text = string.format(t("All preset details fetched (%d)."), total)
      S.last_api_error = ""
      PresetFlow.rebuild_track_matching()
      return
    end

    local preset = S.presets[idx]
    local preset_name = tostring((preset and preset.name) or (preset and preset.uuid) or string.format(t("Preset %s"), tostring(idx)))
    rec._custom_progress = string.format(t("%d/%d - %s"), idx - 1, total, preset_name)
    S.status_text = string.format(t("Fetching preset details %d/%d: %s"), idx, total, preset_name)

    local job, err = client.submit_get_preset_details(S.access_token, preset.uuid, function(payload)
      if not payload.ok then
        RecordFlow.finish_record_failed(
          rec,
          payload.api_error or payload.error or t("Preset details request failed."),
          payload.http_code,
          string.format(t("%d/%d failed"), idx, total)
        )
        S.status_text = string.format(t("Failed to fetch preset details for '%s'."), preset_name)
        S.last_api_error = tostring(payload.api_error or payload.error or t("Preset details request failed."))
        RuntimeState.rebuild_warnings()
        return
      end

      RecordFlow.record_http_code(rec, payload.http_code)
      local merged = {}
      for key, value in pairs(preset) do merged[key] = value end
      for key, value in pairs(payload.preset_details or {}) do merged[key] = value end
      S.preset_details_by_uuid[preset.uuid] = merged
      rec._custom_progress = string.format(t("%d/%d - %s"), idx, total, preset_name)
      submit_index(idx + 1)
    end, {
      read_body = true,
      keep_output = false,
      body_max_bytes = 2 * 1024 * 1024
    })

    if not job then
      RecordFlow.finish_record_failed(rec, err or t("Failed to submit preset details request."), nil, string.format(t("%d/%d failed"), idx, total))
      S.status_text = string.format(t("Failed to fetch preset details for '%s'."), preset_name)
      S.last_api_error = tostring(err or t("Failed to submit preset details request."))
      RuntimeState.rebuild_warnings()
      return
    end

    rec.misc_job_id = job.id
  end

  submit_index(1)
  return true
end

function PresetFlow.submit_fetch_presets_flow()
  local rec = RecordFlow.get_or_create_misc_record("presets", t("Fetch presets"), t("Presets"))
  RecordFlow.begin_record(rec, t("fetching presets"))

  RuntimeState.clear_preset_state()
  local client = ClientFactory.create_auphonic_client("Fetch presets")
  local job, err = client.submit_get_presets(S.access_token, function(payload)
    if not payload.ok then
      RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Preset fetch failed."), payload.http_code, t("failed"))
      S.status_text = t("Failed to fetch presets.")
      S.last_api_error = tostring(payload.api_error or payload.error or t("Preset fetch failed."))
      RuntimeState.rebuild_warnings()
      return
    end

    S.presets = payload.presets or {}
    if #S.presets == 0 then
      RecordFlow.finish_record_ok(rec, t("0 presets"), payload.http_code)
      S.status_text = t("No multitrack presets found.")
      S.last_api_error = ""
      PresetFlow.rebuild_track_matching()
      return
    end

    RecordFlow.finish_record_ok(rec, string.format(t("%d presets"), #S.presets), payload.http_code)
    S.status_text = string.format(t("Presets fetched (%d multitrack)."), #S.presets)
    S.last_api_error = ""
    RecordFlow.schedule_job_or_status(t("Fetch preset details"), PresetFlow.submit_fetch_all_preset_details, t("Could not schedule preset details fetch."))
  end, {
    read_body = true,
    keep_output = false,
    body_max_bytes = 3 * 1024 * 1024
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit presets request."), nil, t("failed"))
    S.status_text = t("Failed to fetch presets.")
    S.last_api_error = tostring(err or t("Failed to submit presets request."))
    RuntimeState.rebuild_warnings()
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function ProductionFlow.build_effective_production_name()
  local safe_name = Util.sanitize_filename(FileNames.ensure_production_name_input(), FileNames.get_default_production_name(), 128)
  if safe_name == "" then
    safe_name = FileNames.get_default_production_name()
  end
  S.production_name_input = safe_name
  return safe_name
end

function ProductionFlow.build_create_production_payload(production_name)
  local details = S.selected_preset_details
  if type(details) ~= "table" or Util.trim(details.uuid or "") == "" then
    return nil, t("Preset details are missing. Connect and select a preset first.")
  end
  if details.is_multitrack ~= true or type(details.multi_input_files) ~= "table" or #details.multi_input_files == 0 then
    return nil, t("AutoMix supports only confirmed multitrack presets with named inputs.")
  end

  return {
    preset = details.uuid,
    metadata = {
      title = Util.date_time_stamp_with_time_precise() .. "_" .. production_name
    },
    output_basename = production_name,
    is_multitrack = true,
    action = "save"
  }, nil
end

function ProductionFlow.build_output_adjustment_request()
  local details = S.selected_preset_details
  local preset_has_stems = PresetFlow.preset_has_tracks_output(details)
  local wants_stems = S.create_stems_archive == true

  if wants_stems and not preset_has_stems then
    return {
      kind = "add_tracks",
      output_files = {
        {
          format = "tracks",
          ending = "flac.zip"
        }
      }
    }, nil
  end

  if (not wants_stems) and preset_has_stems then
    local non_tracks_outputs = PresetFlow.copy_preset_non_tracks_output_files(details)
    if #non_tracks_outputs == 0 then
      return nil, t("Selected preset has no non-stem output files to preserve.")
    end
    return {
      kind = "remove_tracks",
      output_files = non_tracks_outputs
    }, nil
  end

  return nil, nil
end

function ProductionFlow.build_upload_form_fields()
  local production_details = S.production_details
  if type(production_details) ~= "table" then
    return nil, t("Production details are missing.")
  end
  if type(production_details.multi_input_files) ~= "table" then
    return nil, t("Production details have no multi_input_files.")
  end
  if type(S.rendered_files_in_order) ~= "table" or #S.rendered_files_in_order == 0 then
    return nil, t("Rendered files are missing. Render first.")
  end
  if #production_details.multi_input_files ~= #S.rendered_files_in_order then
    return nil, t("Rendered file count does not match production input count.")
  end

  local available_ids = {}
  for _, input in ipairs(production_details.multi_input_files) do
    if not AuphonicAPI.valid_input_id(input.id) or available_ids[input.id] then
      return nil, t("Production input ID is missing or unsupported.")
    end
    available_ids[input.id] = true
  end
  local preset_inputs = S.selected_preset_details and S.selected_preset_details.multi_input_files
  if type(preset_inputs) ~= "table" or #preset_inputs ~= #S.rendered_files_in_order then
    return nil, t("Rendered file count does not match production input count.")
  end
  local form_fields = {}
  for j, file_details in ipairs(preset_inputs) do
    local field_name = file_details and file_details.id or ""
    if not available_ids[field_name] or not AuphonicAPI.valid_input_id(field_name) then
      return nil, t("Production input ID is missing or unsupported.")
    end
    available_ids[field_name] = nil
    local file_path = tostring(S.rendered_files_in_order[j] or "")
    if field_name == "" then
      return nil, string.format(t("Production input %s has no id."), tostring(j))
    end
    if file_path == "" then
      return nil, string.format(t("Rendered file path missing for input %s."), tostring(j))
    end
    if not r.file_exists(file_path) then
      return nil, string.format(t("Rendered file not found: %s"), file_path)
    end
    form_fields[#form_fields + 1] = {
      name = field_name,
      filepath = file_path,
      content_type = "audio/flac"
    }
  end

  return form_fields, nil
end

function ProductionFlow.build_project_download_target(output, fallback_filename, missing_project_message)
  ProjectPaths.refresh_project_relative_paths()
  if S.project_path == "" then
    return nil, missing_project_message or t("Project path is unavailable. Save the project before downloading the mix.")
  end
  local output_dir = S.project_path

  local output_dir_ok, output_dir_err = Files.ensure_tmp_dir(output_dir)
  if not output_dir_ok then
    return nil, string.format(t("Download directory is not writable: %s"), tostring(output_dir_err or output_dir))
  end

  local file_name = tostring(output and output.filename or "")
  local safe_name = Util.sanitize_filename(file_name, fallback_filename or "mix.flac", 255)
  local candidate = Util.path_join(output_dir, safe_name)
  return Files.bump_to_unique_path(candidate), nil
end

function ProjectPaths.capture_import_destination()
  local project = r.EnumProjects(-1)
  local recording_path = Files.read_project_path()
  return function()
    return r.EnumProjects(-1) == project and Files.read_project_path() == recording_path
  end
end

function ProductionFlow.check_download_destination(rec, destination_is_current, http_code)
  if destination_is_current() then return true end
  local message = t("Active project or recording path changed during download. The file was kept in the original recording folder; import was stopped.")
  RecordFlow.finish_record_failed(rec, message, http_code, t("failed"))
  S.status_text, S.last_api_error = message, message
  return false
end

function RenderFlow.remove_rendered_source_files(rendered_files)
  local files = rendered_files or S.rendered_files_in_order
  if type(files) ~= "table" or #files == 0 then
    return true, t("No rendered files to remove.")
  end

  local failures = {}
  local removed_count = 0
  for i = 1, #files do
    local path = tostring(files[i] or "")
    if path ~= "" then
      if r.file_exists(path) then
        local ok_remove, remove_err = Files.remove_best_effort(path)
        if ok_remove then
          removed_count = removed_count + 1
        else
          failures[#failures + 1] = tostring(remove_err or path)
        end
      else
        removed_count = removed_count + 1
      end
    end
  end

  if #failures > 0 then
    return false, string.format(t("Failed to remove some rendered files: %s"), table.concat(failures, "; "))
  end

  RuntimeState.clear_render_result()
  return true, string.format(t("Removed %d rendered file(s)."), removed_count)
end

function ProductionFlow.apply_production_details(details)
  if type(details) ~= "table" then
    S.production_details = nil
  else
    S.production_details = details
    ProductionFlow.sync_lifecycle_flags_from_details(details)
  end
  PresetFlow.refresh_selected_download_output()
end

function ProductionFlow.handle_terminal_production_state(rec, default_running_text, is_manual)
  local has_error, error_message = ProductionFlow.production_has_terminal_error()
  if has_error then
    ProductionFlow.stop_production_polling()
    RecordFlow.finish_record_failed(rec, error_message, rec and rec._last_http_code or nil, t("server error"))
    S.status_text = string.format(t("Production failed: %s"), error_message)
    S.last_api_error = error_message
    RuntimeState.push_warning_once(string.format(t("Mix processing problem: %s"), error_message))
    TelemetryBridge.poll_status_transition("server_error", is_manual)
    return true
  end

  local details = S.production_details
  if ProductionFlow.details_wait_for_paid_start(details) then
    ProductionFlow.stop_production_polling()
    local progress_text = t("not started")
    if type(details) == "table" and Util.trim(details.status_string or "") ~= "" then
      progress_text = details.status_string
    end
    RecordFlow.finish_record_ok(rec, progress_text, rec and rec._last_http_code or nil)
    if type(details) == "table" and details.start_allowed == true then
      S.status_text = string.format(t("Production status: %s. Ready for explicit paid start."), progress_text)
    else
      S.status_text = string.format(t("Production status: %s"), progress_text)
    end
    S.last_api_error = ""
    TelemetryBridge.poll_status_transition("waiting_for_paid_start", is_manual)
    return true
  end

  local is_ready, output, stems_output = ProductionFlow.production_is_ready_for_download()
  if is_ready then
    ProductionFlow.stop_production_polling()
    RecordFlow.finish_record_ok(rec, t("ready"), rec and rec._last_http_code or nil)
    S.status_text = t("Production finished. Download is ready.")
    S.last_api_error = ""
    local status_output = output or stems_output
    if type(status_output) == "table" and Util.trim(status_output.filename or "") ~= "" then
      S.status_text = string.format(t("Production finished. Download is ready: %s"), tostring(status_output.filename))
    end
    TelemetryBridge.poll_status_transition("ready_for_download", is_manual)
    return true
  end

  local progress_text = default_running_text or t("processing")
  if type(details) == "table" and Util.trim(details.status_string or "") ~= "" then
    progress_text = details.status_string
  end
  RecordFlow.keep_record_running(rec, progress_text, rec and rec._last_http_code or nil)
  S.status_text = string.format(t("Production in progress: %s"), progress_text)
  S.last_api_error = ""
  TelemetryBridge.poll_status_transition("processing", is_manual)
  return false
end

function ProductionFlow.submit_upload_audio_flow()
  local rec = RecordFlow.get_or_create_misc_record("upload_production", t("Upload audio"), t("Upload"))
  RecordFlow.begin_record(rec, t("preparing upload"))

  local production_uuid = Util.trim((S.production_details and S.production_details.uuid) or "")
  if production_uuid == "" then
    RecordFlow.finish_record_failed(rec, t("Missing production UUID for upload."), nil, t("failed"))
    S.status_text = t("Upload failed.")
    S.last_api_error = t("Missing production UUID for upload.")
    return false
  end

  local form_fields, fields_err = ProductionFlow.build_upload_form_fields()
  if not form_fields then
    RecordFlow.finish_record_failed(rec, fields_err or t("Failed to prepare upload fields."), nil, t("failed"))
    S.status_text = t("Upload failed.")
    S.last_api_error = tostring(fields_err or t("Failed to prepare upload fields."))
    return false
  end

  rec._custom_progress = string.format(t("%d files"), #form_fields)
  local client = ClientFactory.create_auphonic_client("Upload audio")
  local job, err = client.submit_upload_audio(S.access_token, production_uuid, form_fields, function(payload)
    if not payload.ok then
      RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Upload failed."), payload.http_code, t("failed"))
      S.status_text = t("Upload failed.")
      S.last_api_error = tostring(payload.api_error or payload.error or t("Upload failed."))
      return
    end

    S.upload_confirmed = true
    ProductionFlow.apply_production_details(payload.production_details)
    S.production_ready_to_start = S.output_setup_confirmed and not S.start_uncertain
      and not S.production_started_flag
    ProductionFlow.stop_production_polling()
    RecordFlow.finish_record_ok(rec, string.format(t("%d files uploaded"), #form_fields), payload.http_code)
    S.status_text = t("Upload complete. Confirm the paid start action.")
    S.last_api_error = ""
    S.pending_paid_start_popup = true
  end, {
    read_body = true,
    keep_output = false,
    body_max_bytes = 2 * 1024 * 1024,
    timeout_sec = 3000,
    on_upload = function(index, total)
      rec._custom_progress = string.format(t("Uploading input %d/%d"), index, total)
    end
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit upload request."), nil, t("failed"))
    S.status_text = t("Upload failed.")
    S.last_api_error = tostring(err or t("Failed to submit upload request."))
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function ProductionFlow.finish_create_and_schedule_upload(rec, http_code)
  S.output_setup_confirmed = true
  S.pending_output_adjustment = nil
  RecordFlow.finish_record_ok(rec, t("created"), http_code)
  S.status_text = t("Production created. Starting upload...")
  S.last_api_error = ""
  RecordFlow.schedule_job_or_status(t("Upload audio"), ProductionFlow.submit_upload_audio_flow, t("Could not schedule audio upload."))
end

function ProductionFlow.fail_created_production_output_setup(rec, err_text, http_code)
  local message = tostring(err_text or t("Failed to set production output files."))
  RecordFlow.finish_record_failed(rec, message, http_code, t("output setup failed"))
  S.status_text = t("Production output setup failed.")
  S.last_api_error = message
end

function ProductionFlow.submit_created_production_output_adjustment(client, rec, production_uuid, adjustment, create_http_code)
  S.pending_output_adjustment = adjustment
  if not adjustment then
    ProductionFlow.finish_create_and_schedule_upload(rec, create_http_code)
    return true
  end
  RecordFlow.keep_record_running(rec, t("Checking production outputs"))
  return client.submit_configure_outputs(S.access_token, production_uuid, adjustment, function(payload)
    if not payload.ok then
      ProductionFlow.fail_created_production_output_setup(rec, payload.api_error or payload.error, payload.http_code)
      return
    end
    ProductionFlow.apply_production_details(payload.production_details)
    ProductionFlow.finish_create_and_schedule_upload(rec, payload.http_code)
  end, { read_body = true, keep_output = false, body_max_bytes = 2 * 1024 * 1024 })
end

function ProductionFlow.schedule_create_production_flow()
  -- Capture at the user's click, before the scheduler can defer job creation.
  local anchor = ImportFlow.capture_job_insertion_anchor()
  return RecordFlow.schedule_job_or_status(t("Create production"), function()
    return ProductionFlow.submit_create_production_flow(anchor)
  end, t("Could not schedule production creation."))
end

function ProductionFlow.submit_create_production_flow(insertion_anchor)
  if S.production_details or S.creation_uncertain then
    S.status_text = t("Keep the current production. Reset it explicitly before creating another.")
    return false
  end
  local rec = RecordFlow.get_or_create_misc_record("create_production", t("Create production"), t("Create production"))
  RecordFlow.begin_record(rec, t("creating"))

  if S.access_token == "" then
    RecordFlow.finish_record_failed(rec, t("Studio login is required."), nil, t("failed"))
    S.status_text = t("Create production failed.")
    S.last_api_error = t("Studio login is required.")
    return false
  end

  if type(S.rendered_files_in_order) ~= "table" or #S.rendered_files_in_order == 0 then
    RecordFlow.finish_record_failed(rec, t("Rendered files are missing. Render first."), nil, t("failed"))
    S.status_text = t("Create production failed.")
    S.last_api_error = t("Rendered files are missing. Render first.")
    return false
  end

  local production_name = ProductionFlow.build_effective_production_name()
  local payload_table, payload_err = ProductionFlow.build_create_production_payload(production_name)
  if not payload_table then
    RecordFlow.finish_record_failed(rec, payload_err or t("Invalid production payload."), nil, t("failed"))
    S.status_text = t("Create production failed.")
    S.last_api_error = tostring(payload_err or t("Invalid production payload."))
    return false
  end

  local anchor = insertion_anchor or ImportFlow.capture_job_insertion_anchor()
  local placement_error
  if S.result_insert_position == "selection_start" and anchor.selection_start == nil then
    placement_error = t("Make a time selection before creating a job when insertion at selection start is selected.")
  elseif anchor.project ~= r.EnumProjects(-1) then
    placement_error = t("The active project changed before job creation. Create the job again in the intended project.")
  end
  if placement_error then
    RecordFlow.finish_record_failed(rec, placement_error, nil, t("failed"))
    S.status_text = t("Create production failed.")
    S.last_api_error = placement_error
    return false
  end

  RuntimeState.clear_production_runtime_state()
  S.production_insert_anchor = anchor

  local client = ClientFactory.create_auphonic_client("Create production")
  local job, err = client.submit_create_production(S.access_token, payload_table, function(payload)
    if not payload.ok then
      RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Create production failed."), payload.http_code, t("failed"))
      S.status_text = t("Create production failed.")
      S.last_api_error = tostring(payload.api_error or payload.error or t("Create production failed."))
      S.creation_uncertain = payload.outcome_uncertain == true
      if S.creation_uncertain then
        RuntimeState.push_warning_once(t("Creation outcome is uncertain. Check the backend before creating another production."))
      end
      return
    end

    ProductionFlow.apply_production_details(payload.production_details)
    local prod_inputs = S.production_details and S.production_details.multi_input_files or nil
    local preset_inputs = S.selected_preset_details and S.selected_preset_details.multi_input_files or nil
    if type(prod_inputs) ~= "table" or type(preset_inputs) ~= "table" or #prod_inputs ~= #preset_inputs then
      RecordFlow.finish_record_failed(rec, t("Created production does not match the selected preset."), payload.http_code, t("failed"))
      S.status_text = t("Create production failed.")
      S.last_api_error = t("Created production does not match the selected preset.")
      return
    end

    local adjustment, adjustment_err = ProductionFlow.build_output_adjustment_request()
    if adjustment_err then
      ProductionFlow.fail_created_production_output_setup(rec, adjustment_err, payload.http_code)
      return
    end
    ProductionFlow.submit_created_production_output_adjustment(client, rec, payload.production_uuid, adjustment, payload.http_code)
  end, {
    read_body = true,
    keep_output = false,
    body_max_bytes = 2 * 1024 * 1024
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit create production request."), nil, t("failed"))
    S.status_text = t("Create production failed.")
    S.last_api_error = tostring(err or t("Failed to submit create production request."))
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function ProductionFlow.submit_start_production_flow()
  if not S.upload_confirmed or not S.output_setup_confirmed or S.start_uncertain or S.production_started_flag then
    S.status_text = t("Confirm uploads and output settings before starting.")
    return false
  end
  local rec = RecordFlow.get_or_create_misc_record("start_production", t("Start production"), t("Start"))
  RecordFlow.begin_record(rec, t("starting"))

  local production_uuid = Util.trim((S.production_details and S.production_details.uuid) or "")
  if production_uuid == "" then
    RecordFlow.finish_record_failed(rec, t("Missing production UUID."), nil, t("failed"))
    S.status_text = t("Start production failed.")
    S.last_api_error = t("Missing production UUID.")
    return false
  end
  if S.access_token == "" then
    RecordFlow.finish_record_failed(rec, t("Studio login is required."), nil, t("failed"))
    S.status_text = t("Start production failed.")
    S.last_api_error = t("Studio login is required.")
    return false
  end

  local client = ClientFactory.create_auphonic_client("Start production")
  local job, err = client.submit_start_production(S.access_token, production_uuid, function(payload)
    if not payload.ok then
      local failure_text = tostring(payload.api_error or payload.error or t("Start production failed."))
      RecordFlow.finish_record_failed(rec, failure_text, payload.http_code, t("failed"))
      S.status_text = t("Start production failed.")
      S.last_api_error = failure_text
      local http_num = tonumber(payload.http_code)
      if http_num and http_num >= 500 then
        RuntimeState.push_warning_once(string.format(t("Auphonic start returned server error: %s"), failure_text))
      end
      S.start_uncertain = payload.outcome_uncertain == true or payload.mutation_succeeded == true
      S.production_ready_to_start = false
      ProductionFlow.stop_production_polling()
      return
    end

    ProductionFlow.apply_production_details(payload.production_details)
    S.start_uncertain = false
    S.production_ready_to_start = false
    S.production_started_flag = true
    S.production_poll_active = true
    local now_t = r.time_precise()
    ProductionFlow.schedule_next_production_poll(now_t)
    RecordFlow.finish_record_ok(rec, t("started"), payload.http_code)
    S.status_text = string.format(t("Production started. Next poll in %ds."), tonumber(S.production_poll_last_interval_sec) or 0)
    S.last_api_error = ""
  end, {
    read_body = true,
    keep_output = false,
    body_max_bytes = 2 * 1024 * 1024
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit start request."), nil, t("failed"))
    S.status_text = t("Start production failed.")
    S.last_api_error = tostring(err or t("Failed to submit start request."))
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function ProductionFlow.submit_production_status_flow(is_manual)
  local rec = RecordFlow.get_or_create_misc_record("poll_production", t("Poll production"), t("Poll"))
  RecordFlow.begin_record(rec, is_manual and t("manual check") or t("polling"), {
    suppress_telemetry = not is_manual
  })

  local production_uuid = Util.trim((S.production_details and S.production_details.uuid) or "")
  if production_uuid == "" then
    RecordFlow.finish_record_failed(rec, t("Missing production UUID."), nil, t("failed"))
    S.status_text = t("Status check failed.")
    S.last_api_error = t("Missing production UUID.")
    if not is_manual then
      ProductionFlow.stop_production_polling()
    end
    return false
  end
  if S.access_token == "" then
    RecordFlow.finish_record_failed(rec, t("Studio login is required."), nil, t("failed"))
    S.status_text = t("Status check failed.")
    S.last_api_error = t("Studio login is required.")
    if not is_manual then
      ProductionFlow.stop_production_polling()
    end
    return false
  end

  local client = ClientFactory.create_auphonic_client(is_manual and "Manual production status" or "Poll production status")
  local job, err = client.submit_get_production_status(S.access_token, production_uuid, function(payload)
    if not payload.ok then
      RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Status request failed."), payload.http_code, t("failed"))
      S.status_text = t("Status check failed.")
      S.last_api_error = tostring(payload.api_error or payload.error or t("Status request failed."))
      if not is_manual then
        TelemetryBridge.operation_failed("automix_poll_production", {
          request_label = t("Poll production"),
          http_code = payload.http_code,
          safe_message = S.last_api_error,
          automatic_poll = true
        }, rec._telemetry_started_at)
      end
      if not is_manual then
        ProductionFlow.stop_production_polling()
      end
      return
    end

    ProductionFlow.apply_production_details(payload.production_details)
    RecordFlow.record_http_code(rec, payload.http_code)
    if ProductionFlow.handle_terminal_production_state(rec, t("processing"), is_manual) then
      return
    end

    if is_manual then
      S.status_text = t("Production status refreshed.")
    else
      ProductionFlow.schedule_next_production_poll(r.time_precise())
      S.status_text = string.format(t("Production in progress. Next poll in %ds."), tonumber(S.production_poll_last_interval_sec) or 0)
    end
    S.last_api_error = ""
  end, {
    read_body = true,
    keep_output = false,
    body_max_bytes = 2 * 1024 * 1024
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit status request."), nil, t("failed"))
    S.status_text = t("Status check failed.")
    S.last_api_error = tostring(err or t("Failed to submit status request."))
    if not is_manual then
      TelemetryBridge.operation_failed("automix_poll_production", {
        request_label = t("Poll production"),
        safe_message = S.last_api_error,
        automatic_poll = true
      }, rec._telemetry_started_at)
    end
    if not is_manual then
      ProductionFlow.stop_production_polling()
    end
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function ProductionFlow.submit_download_and_import_flow()
  local rec = RecordFlow.get_or_create_misc_record("download_import", t("Download and import"), t("Download/import"))
  RecordFlow.begin_record(rec, t("preparing"))

  local ready, output = ProductionFlow.production_is_ready_for_download()
  if not ready or type(output) ~= "table" then
    RecordFlow.finish_record_failed(rec, t("No downloadable mix result is available yet."), nil, t("failed"))
    S.status_text = t("Download failed.")
    S.last_api_error = t("No downloadable mix result is available yet.")
    return false
  end

  if Util.trim(output.filename or "") == "" then
    RecordFlow.finish_record_failed(rec, t("Output filename is missing."), nil, t("failed"))
    S.status_text = t("Download failed.")
    S.last_api_error = t("Output filename is missing.")
    return false
  end

  local import_options, placement_error = ImportFlow.result_import_options()
  if not import_options then
    RecordFlow.finish_record_failed(rec, placement_error, nil, t("failed"))
    S.status_text = t("Download failed.")
    S.last_api_error = placement_error
    return false
  end

  local destination_file_full_path, path_err = ProductionFlow.build_project_download_target(output)
  if not destination_file_full_path then
    RecordFlow.finish_record_failed(rec, path_err or t("Failed to build output path."), nil, t("failed"))
    S.status_text = t("Download failed.")
    S.last_api_error = tostring(path_err or t("Failed to build output path."))
    return false
  end

  local destination_is_current = ProjectPaths.capture_import_destination()
  local client = ClientFactory.create_auphonic_client("Download result")
  local job, err = client.submit_download_result(S.access_token, S.production_details.uuid, output.filename, destination_file_full_path, function(payload)
    if not payload.ok then
      RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Download failed."), payload.http_code, t("failed"))
      S.status_text = t("Download failed.")
      S.last_api_error = tostring(payload.api_error or payload.error or t("Download failed."))
      return
    end

    if not ProductionFlow.check_download_destination(rec, destination_is_current, payload.http_code) then return end
    if not r.file_exists(destination_file_full_path) then
      RecordFlow.finish_record_failed(rec, t("Downloaded file was not created."), payload.http_code, t("failed"))
      S.status_text = t("Download failed.")
      S.last_api_error = t("Downloaded file was not created.")
      return
    end

    local inserted, insert_err = ImportFlow.import_mixdown_to_project(destination_file_full_path, import_options)
    if not inserted then
      RecordFlow.finish_record_failed(rec, insert_err or t("Downloaded mix, but failed to insert it into the project."), payload.http_code, t("failed"))
      S.status_text = t("Download finished, but insert failed.")
      S.last_api_error = tostring(insert_err or t("Downloaded mix, but failed to insert it into the project."))
      RuntimeState.push_warning_once(string.format(t("Downloaded mix, but failed to insert into the project: %s"), tostring(insert_err or destination_file_full_path)))
      return
    end

    S.inserted_mix_path = destination_file_full_path
    RecordFlow.finish_record_ok(rec, t("downloaded and inserted"), payload.http_code)
    S.status_text = t("Mix downloaded and inserted into the project.")
    S.last_api_error = ""
    S.cleanup_prompt_download_path = destination_file_full_path
    S.pending_cleanup_prompt = true
  end, {
    read_body = false,
    keep_output = true,
    timeout_sec = 4200
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit download request."), nil, t("failed"))
    S.status_text = t("Download failed.")
    S.last_api_error = tostring(err or t("Failed to submit download request."))
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function ProductionFlow.submit_download_stems_flow()
  -- A new attempt must not leave stale stems available for a subsequent DIA render.
  DiaFlow.clear_dia_runtime_state()
  S.imported_stems_count, S.imported_stems_extract_dir = 0, ""
  S.imported_stems_renamed_files = {}
  local rec = RecordFlow.get_or_create_misc_record("download_stems", t("Download stems"), t("Stems download/import"))
  RecordFlow.begin_record(rec, t("preparing"))

  local ready, _, output = ProductionFlow.production_is_ready_for_download()
  if not ready or type(output) ~= "table" then
    RecordFlow.finish_record_failed(rec, t("No downloadable stem archive is available yet."), nil, t("failed"))
    S.status_text = t("Stem archive download failed.")
    S.last_api_error = t("No downloadable stem archive is available yet.")
    return false
  end

  if Util.trim(output.filename or "") == "" then
    RecordFlow.finish_record_failed(rec, t("Stem archive filename is missing."), nil, t("failed"))
    S.status_text = t("Stem archive download failed.")
    S.last_api_error = t("Stem archive filename is missing.")
    return false
  end

  local import_options, placement_error = ImportFlow.result_import_options()
  if not import_options then
    RecordFlow.finish_record_failed(rec, placement_error, nil, t("failed"))
    S.status_text = t("Stem archive download failed.")
    S.last_api_error = placement_error
    return false
  end

  local destination_file_full_path, path_err = ProductionFlow.build_project_download_target(
    output,
    "stems.flac.zip",
    t("Project path is unavailable. Save the project before downloading the stem archive.")
  )
  if not destination_file_full_path then
    RecordFlow.finish_record_failed(rec, path_err or t("Failed to build stem archive output path."), nil, t("failed"))
    S.status_text = t("Stem archive download failed.")
    S.last_api_error = tostring(path_err or t("Failed to build stem archive output path."))
    return false
  end

  local production_details_for_download = S.production_details
  local destination_is_current = ProjectPaths.capture_import_destination()
  local client = ClientFactory.create_auphonic_client(t("Download stems"))
  local job, err = client.submit_download_result(S.access_token, S.production_details.uuid, output.filename, destination_file_full_path, function(payload)
    if not payload.ok then
      RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Stem archive download failed."), payload.http_code, t("failed"))
      S.status_text = t("Stem archive download failed.")
      S.last_api_error = tostring(payload.api_error or payload.error or t("Stem archive download failed."))
      return
    end

    if not ProductionFlow.check_download_destination(rec, destination_is_current, payload.http_code) then return end
    if not r.file_exists(destination_file_full_path) then
      RecordFlow.finish_record_failed(rec, t("Downloaded stem archive was not created."), payload.http_code, t("failed"))
      S.status_text = t("Stem archive download failed.")
      S.last_api_error = t("Downloaded stem archive was not created.")
      return
    end

    RecordFlow.keep_record_running(rec, t("extracting stems"), payload.http_code)
    local extract_dir, extract_dir_err = ImportFlow.build_stems_extract_target_dir(output, destination_file_full_path)
    if not extract_dir then
      RecordFlow.finish_record_failed(rec, extract_dir_err or t("Failed to prepare stem extraction folder."), payload.http_code, t("failed"))
      S.status_text = t("Stem archive downloaded, but extraction could not start.")
      S.last_api_error = tostring(extract_dir_err or t("Failed to prepare stem extraction folder."))
      return
    end

    local extracted, extract_err = ZipArchive.extract_audio_files(destination_file_full_path, extract_dir)
    if type(extracted) ~= "table" then
      RecordFlow.finish_record_failed(rec, extract_err or t("Stem archive extraction failed."), payload.http_code, t("failed"))
      S.status_text = t("Stem archive downloaded, but extraction failed.")
      S.last_api_error = tostring(extract_err or t("Stem archive extraction failed."))
      return
    end
    local renamed_files = extracted.renamed_files or {}
    S.imported_stems_renamed_files = renamed_files
    local warning = ImportFlow.stem_rename_warning(renamed_files)
    if warning then
      RuntimeState.push_warning_once(warning)
      Util.msg(warning, 2)
    end
    local stem_extract_warning = Util.trim(extracted.warning_text or "")
    if stem_extract_warning ~= "" then
      RuntimeState.push_warning_once(string.format(t("Stem archive extraction warning: %s"), stem_extract_warning))
    end

    local ordered_audio_files = ZipArchive.order_audio_files_for_production(
      extracted.audio_files,
      production_details_for_download
    )

    RecordFlow.keep_record_running(rec, t("importing stems"), payload.http_code)
    local imported, import_err, imported_count = ImportFlow.import_extracted_stems_to_project(ordered_audio_files, import_options)
    if not imported then
      RecordFlow.finish_record_failed(rec, import_err or t("Stem import failed."), payload.http_code, t("failed"))
      S.status_text = t("Stem archive extracted, but import failed.")
      S.last_api_error = tostring(import_err or t("Stem import failed."))
      return
    end

    S.imported_stems_extract_dir = extracted.output_dir or extract_dir
    S.imported_stems_count = tonumber(imported_count) or 0
    local finish_text = (stem_extract_warning ~= "" or #renamed_files > 0)
      and t("downloaded, extracted, and imported with warnings")
      or t("downloaded, extracted, and imported")
    RecordFlow.finish_record_ok(rec, finish_text, payload.http_code)
    S.status_text = string.format(t("Stem archive downloaded, extracted, and imported (%d tracks)."), S.imported_stems_count)
    S.last_api_error = ""
  end, {
    read_body = false,
    keep_output = true,
    timeout_sec = 4200
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit stem archive download request."), nil, t("failed"))
    S.status_text = t("Stem archive download failed.")
    S.last_api_error = tostring(err or t("Failed to submit stem archive download request."))
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function Automix.tick_production_poll(now_t)
  if S.production_poll_active ~= true then return end
  if S.production_poll_next_at == nil then
    ProductionFlow.schedule_next_production_poll(now_t)
    return
  end
  local now_value = tonumber(now_t) or r.time_precise()
  if now_value < S.production_poll_next_at then
    return
  end
  if Jobs.network_busy() then
    return
  end

  RecordFlow.schedule_job_or_status(
    t("Poll production status"),
    function()
      ProductionFlow.submit_production_status_flow(false)
    end,
    t("Could not schedule production polling.")
  )
end

function ProductionFlow.submit_login_flow()
  local rec = RecordFlow.get_or_create_misc_record("auth", t("Login"), t("Auth"))
  RecordFlow.begin_record(rec, t("login"))

  local auth_client = ClientFactory.create_auth_client("Login")
  local job, err = auth_client.submit_login(S.email, S.password, function(payload)
    if not payload.ok then
      RecordFlow.finish_record_failed(rec, payload.api_error or payload.error or t("Login failed."), payload.http_code, t("failed"))
      S.status_text = t("Login failed.")
      S.last_api_error = tostring(payload.api_error or payload.error or t("Login failed."))
      return
    end

    RuntimeState.update_auth_state_from_payload(payload)
    if S.remember_me then
      RuntimeState.persist_email(S.email)
    else
      RuntimeState.forget_email()
    end

    RecordFlow.finish_record_ok(rec, t("login ok"), payload.http_code)
    S.status_text = t("Login OK.")
    S.last_api_error = ""
    if not S.production_details and not S.creation_uncertain then
      RecordFlow.schedule_job_or_status(t("Connect"), function() Automix.begin_connect_flow(false) end, t("Could not schedule connect."))
    end
  end, {
    read_body = true,
    keep_output = false,
    body_max_bytes = 512 * 1024
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Failed to submit login request."), nil, t("failed"))
    S.status_text = t("Login failed.")
    S.last_api_error = tostring(err or t("Failed to submit login request."))
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function ProductionFlow.submit_refresh_flow(from_startup)
  local rec = RecordFlow.get_or_create_misc_record("auth", t("Stored login"), t("Auth"))
  RecordFlow.begin_record(rec, t("refresh"))

  local auth_client = ClientFactory.create_auth_client("Refresh login")
  local job, err = auth_client.submit_refresh(function(payload)
    if not payload.ok then
      if payload.reauthenticate then RuntimeState.finish_stored_login_invalid(rec, payload)
      else
        RecordFlow.finish_record_failed(rec, payload.api_error or payload.error, payload.http_code)
        S.status_text = t("Login refresh failed. Stored login was retained; retry refresh or log in again.")
        S.last_api_error = payload.api_error or payload.error or ""
        S.auto_auth_finished, S.auto_auth_success = true, false
      end
      return
    end

    RuntimeState.update_auth_state_from_payload(payload)
    RecordFlow.finish_record_ok(rec, t("refresh ok"), payload.http_code)
    S.status_text = t("Login refreshed.")
    S.last_api_error = ""
    S.auto_auth_finished, S.auto_auth_success = true, true
    if not S.production_details and not S.creation_uncertain then
      RecordFlow.schedule_job_or_status(t("Connect"), function() Automix.begin_connect_flow(false) end, t("Could not schedule connect."))
    end
  end, {
    read_body = true,
    keep_output = false,
    body_max_bytes = 512 * 1024
  })

  if not job then
    RecordFlow.finish_record_failed(rec, err or t("Login refresh could not start."))
    S.auto_auth_finished, S.auto_auth_success = true, false
    return false
  end

  rec.misc_job_id = job.id
  return true
end

function Automix.begin_connect_flow(reset_existing)
  if reset_existing ~= false then
    RecordFlow.reset_progress_state("connect")
  end

  if S.access_token == "" then
    S.status_text = t("Studio login is required.")
    S.last_api_error = t("Studio login is required.")
    return false
  end

  return PresetFlow.submit_fetch_presets_flow()
end

function ProductionFlow.begin_manual_login_flow()
  RecordFlow.reset_progress_state("login")
  RuntimeState.rebuild_warnings()
  RecordFlow.schedule_job_or_status(t("Login"), ProductionFlow.submit_login_flow, t("Request already running."))
end

function ProductionFlow.try_auto_login_on_startup()
  if S.auto_auth_attempted then return end
  S.auto_auth_attempted = true
  S.auto_auth_finished = false
  S.auto_auth_success = false

  if not RuntimeState.sync_stored_refresh_flag() then
    S.auto_auth_finished = true
    S.status_text = t("No stored login. Please log in.")
    return
  end

  RecordFlow.reset_progress_state("auto login")
  RecordFlow.schedule_job_or_status(t("Refresh login"), function()
    ProductionFlow.submit_refresh_flow(true)
  end, t("Could not schedule auto login."))
end

function ProductionFlow.load_email_on_startup()
  local stored_email = RuntimeState.load_email_from_ext_state()
  if stored_email then
    S.email = stored_email
  end
end

function UI.button_clicked(id, label, cooldown_override, ctx_override)
  local ctx_ref = ctx_override or ctx
  local key = tostring(id or label)
  local cooldown = tonumber(cooldown_override) or tonumber(CFG.button_cooldown_sec) or 0
  local now_t = r.time_precise()
  local last = button_last_click_at[key] or 0
  local remaining = cooldown - (now_t - last)
  if remaining < 0 then remaining = 0 end

  if remaining > 0 then
    ImGui.BeginDisabled(ctx_ref, true)
  end
  local clicked = ImGui.Button(ctx_ref, label)
  if remaining > 0 then
    ImGui.EndDisabled(ctx_ref)
  end

  if clicked and remaining <= 0 then
    button_last_click_at[key] = now_t
    if telemetry_button_ids[key] == true then
      TelemetryBridge.button_clicked(key, label)
    end
    return true
  end
  return false
end

function UI.ui_warning(text, ctx_to_show)
  local ctx_ref = ctx_to_show or ctx
  ImGui.PushStyleColor(ctx_ref, ImGui.Col_Text, 0xFFB000FF)
  ImGui.TextWrapped(ctx_ref, string.format(t("WARNING: %s"), tostring(text or "")))
  ImGui.PopStyleColor(ctx_ref)
end

function UI.ui_info(text, ctx_to_show)
  local ctx_ref = ctx_to_show or ctx
  ImGui.TextWrapped(ctx_ref, tostring(text or ""))
end

function UI.record_label(rec)
  if not rec then return t("record") end
  return rec.record_name or rec.region_name or rec.output_path or t("record")
end

function UI.add_record_rows(out, records, flow_label, job_field)
  if type(records) ~= "table" then return end
  for _, rec in ipairs(records) do
    if rec and rec._misc_key == "render" then
      goto continue
    end
    local row_flow = flow_label or ""
    if rec and rec.flow_label and rec.flow_label ~= "" then
      row_flow = rec.flow_label
    end
    local rec_id = rec.record_name or rec.output_path or tostring(rec)
    out[#out + 1] = {
      rec = rec,
      flow = row_flow,
      job_id = job_field and rec[job_field] or nil,
      id = tostring(row_flow) .. "_" .. tostring(rec_id)
    }
    ::continue::
  end
end

function UI.build_record_rows()
  local rows = {}
  UI.add_record_rows(rows, S.misc_records, t("Fetch"), "misc_job_id")
  return rows
end

function UI.format_record_progress(rec, job)
  if rec and rec._state == "failed_final" then
    return rec._custom_progress or t("failed")
  end
  if rec and rec._state == "ok" then
    return rec._custom_progress or t("ok")
  end
  if rec and rec._state == "running" then
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
  if job then
    if job.phase == "running" then
      local flow_line = job.progress and job.progress.flow and job.progress.flow.line
      if type(flow_line) == "string" and flow_line ~= "" then
        return flow_line
      end
      return t("running")
    end
    if job.phase == "created" or job.phase == "launched" then
      return t("queued")
    end
    if job.phase == "completed" then
      if job.result and job.result.ok then return t("ok") end
      return t("failed")
    end
  end
  return t("queued")
end

function UI.build_status_summary()
  local rows = UI.build_record_rows()
  local filtered = {}
  for _, row in ipairs(rows) do
    local rec = row.rec
    if rec and rec._retry_generation == S.retry_generation then
      filtered[#filtered + 1] = row
    end
  end
  rows = filtered

  local summary = {
    counts = { queued = 0, running = 0, ok = 0, failed = 0 },
    status_line = S.status_text or ""
  }

  local function classify_row_state(rec, job)
    if rec and rec._state then
      if rec._state == "failed_final" then return "failed" end
      if rec._state == "ok" then return "ok" end
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

  for _, row in ipairs(rows) do
    local rec = row.rec
    local job = row.job_id and S.curl_jobs[row.job_id] or nil
    local state = classify_row_state(rec, job)
    summary.counts[state] = (summary.counts[state] or 0) + 1
  end

  if #rows > 0 then
    summary.status_line = string.format(
      t("Queued %d | Running %d | OK %d | Failed %d"),
      summary.counts.queued or 0,
      summary.counts.running or 0,
      summary.counts.ok or 0,
      summary.counts.failed or 0
    )
  end

  return summary
end

function UI.render_status_panel(ctx_to_show, id_suffix)
  local ctx_ref = ctx_to_show or ctx
  local suffix = tostring(id_suffix or "")
  ImGui.PushFont(ctx_ref, FONT, font_size)

  local summary = UI.build_status_summary()
  local status_line = summary.status_line or ""
  local has_failed = (summary.counts.failed or 0) > 0 or Util.is_non_empty(S.last_api_error)
  local has_in_process = ((summary.counts.queued or 0) > 0) or ((summary.counts.running or 0) > 0)

  if has_failed then
    ImGui.PushStyleColor(ctx_ref, ImGui.Col_Text, 0xFF0000FF)
  elseif has_in_process then
    ImGui.PushStyleColor(ctx_ref, ImGui.Col_Text, 0x66CCFFFF)
  else
    ImGui.PushStyleColor(ctx_ref, ImGui.Col_Text, 0x00FF00FF)
  end
  ImGui.Text(ctx_ref, string.format(t("Status: %s"), tostring(status_line)))
  ImGui.PopStyleColor(ctx_ref)

  local last_status = S.status_text or ""
  if last_status == "" then last_status = t("(none)") end
  ImGui.TextWrapped(ctx_ref, string.format(t("Last status: %s"), last_status))

  ImGui.PushStyleVar(ctx_ref, ImGui.StyleVar_SeparatorTextAlign, 0.15, 0.5)
  ImGui.SeparatorText(ctx_ref, t("Warnings"))
  ImGui.PopStyleVar(ctx_ref)
  if #S.warnings == 0 then
    UI.ui_info(t("None. Looks good!"), ctx_ref)
  else
    for _, w in ipairs(S.warnings) do
      UI.ui_warning(w, ctx_ref)
    end
  end

  if UI.button_clicked("clear_warnings_btn" .. suffix, t("Clear warnings"), nil, ctx_ref) then
    S.warnings = {}
  end
  ImGui.SameLine(ctx_ref)
  if UI.button_clicked("copy_warnings_btn" .. suffix, t("Copy warnings to clipboard"), nil, ctx_ref) then
    ImGui.SetClipboardText(ctx_ref, table.concat(S.warnings or {}, "\n"))
  end

  ImGui.PopFont(ctx_ref)
end

function UI.render_progress_table(ctx_to_show, id_suffix)
  local ctx_ref = ctx_to_show or ctx
  local rows = UI.build_record_rows()

  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx_ref, t("Table rendering not available in this ImGui build."))
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY

  local table_height = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx_ref) * 12) or 240
  if ImGui.BeginTable(ctx_ref, "##automix_tool_progress_" .. tostring(id_suffix or "main"), 5, table_flags, -1, table_height) then
    ImGui.TableSetupColumn(ctx_ref, t("Flow"), ImGui.TableColumnFlags_WidthFixed, 110)
    ImGui.TableSetupColumn(ctx_ref, t("Record"), ImGui.TableColumnFlags_WidthFixed, 190)
    ImGui.TableSetupColumn(ctx_ref, t("Progress"), ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx_ref, t("HTTP"), ImGui.TableColumnFlags_WidthFixed, 60)
    ImGui.TableSetupColumn(ctx_ref, t("Error"), ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableHeadersRow(ctx_ref)

    if #rows == 0 then
      ImGui.TableNextRow(ctx_ref)
      ImGui.TableSetColumnIndex(ctx_ref, 0)
      ImGui.Text(ctx_ref, "-")
      ImGui.TableSetColumnIndex(ctx_ref, 1)
      ImGui.Text(ctx_ref, t("No requests yet."))
    else
      for _, row in ipairs(rows) do
        local rec = row.rec
        local job = row.job_id and S.curl_jobs and S.curl_jobs[row.job_id] or nil
        local http_code = rec and rec._last_http_code or nil
        local err_text = rec and rec._last_error_summary or ""
        local progress = UI.format_record_progress(rec, job)

        ImGui.TableNextRow(ctx_ref)
        ImGui.TableSetColumnIndex(ctx_ref, 0)
        ImGui.TextWrapped(ctx_ref, tostring(row.flow or ""))
        ImGui.TableSetColumnIndex(ctx_ref, 1)
        ImGui.TextWrapped(ctx_ref, UI.record_label(rec))
        ImGui.TableSetColumnIndex(ctx_ref, 2)
        ImGui.TextWrapped(ctx_ref, tostring(progress or ""))
        ImGui.TableSetColumnIndex(ctx_ref, 3)
        ImGui.Text(ctx_ref, http_code and tostring(http_code) or "-")
        ImGui.TableSetColumnIndex(ctx_ref, 4)
        ImGui.TextWrapped(ctx_ref, tostring(err_text or ""))
      end
      if ImGui.SetScrollHereY then
        ImGui.SetScrollHereY(ctx_ref, 1.0)
      end
    end

    ImGui.EndTable(ctx_ref)
  end
end

function UI.ui_print_out_last_curl_return(ctx_to_show)
  local ctx_ref = ctx_to_show or ctx
  local last_curl = S.last_curl_return or {}
  local all_lines = table.concat({
    string.format(t("ok: %s"), tostring(last_curl.ok)),
    string.format(t("http: %s"), tostring(last_curl.http)),
    string.format(t("body: %s"), tostring(Util.head32(tostring(last_curl.body or "")))),
    string.format(t("headers: %s"), tostring(Util.head32(tostring(last_curl.headers_txt or "")))),
    string.format(t("meta: %s"), tostring(Util.head32(tostring(last_curl.meta or "")))),
    string.format(t("err: %s"), tostring(last_curl.err)),
    string.format(t("cmd: %s"), tostring(last_curl.cmd))
  }, "\n")
  local flags = ImGui.InputTextFlags_ReadOnly
  ImGui.InputTextMultiline(ctx_ref, "##automix_tool_last_curl", all_lines, -1, 140, flags)
end

function MainUI.render_status_window()
  ImGui.SetNextWindowSize(ctx_status, 500, 375, ImGui.Cond_FirstUseEver)
  if S.show_status_window then
    local status_flags = ImGui.WindowFlags_NoTitleBar
    local status_open_bool = nil
    local visible = ImGui.Begin(ctx_status, MainUI.current_status_window_label(), status_open_bool, status_flags)
    if visible then
      UI.render_status_panel(ctx_status, "_status_window")
      ImGui.End(ctx_status)
    end
  end
end

function MainUI.render_paths_section()
  UI.ui_info(string.format(t("Project path: %s"), (S.project_path ~= "" and S.project_path or t("(unknown)"))))
  UI.ui_info(string.format(t("Temp folder: %s"), tostring(CFG.tmp_dir or "")))

  if UI.button_clicked("copy_tmp_path_btn", t("Copy temp folder path")) then
    ImGui.SetClipboardText(ctx, tostring(CFG.tmp_dir or ""))
  end
  ImGui.SameLine(ctx)
  if UI.button_clicked("refresh_checks_btn", t("Refresh checks")) then
    RuntimeState.rebuild_warnings()
  end

  if S.tmp_writable then
    UI.ui_info(t("Temp directory is writable."))
  else
    UI.ui_warning(t("Temp directory is NOT writable."))
  end
end

function MainUI.render_auth_section()
  if S.auto_auth_attempted and (not S.auto_auth_finished) then
    UI.ui_info(t("Stored login check is in progress."))
  elseif S.has_stored_refresh then
    UI.ui_info(t("Stored login is available."))
  else
    UI.ui_info(t("No stored login is available."))
  end

  ImGui.Text(ctx, t("Email:"))
  ImGui.SetNextItemWidth(ctx, -10.0)
  local changed_email, new_email = ImGui.InputText(ctx, "##automix_tool_email", S.email or "")
  if changed_email then
    S.email = new_email
  end

  ImGui.Text(ctx, t("Password:"))
  ImGui.SetNextItemWidth(ctx, -10.0)
  local changed_pass, new_pass = ImGui.InputText(ctx, "##automix_tool_password", S.password or "", ImGui.InputTextFlags_Password)
  if changed_pass then
    S.password = new_pass
  end

  local changed_remember, new_remember = ImGui.Checkbox(ctx, t("Remember me"), S.remember_me)
  if changed_remember then
    S.remember_me = new_remember
    if not new_remember then
      local auth_client = ClientFactory.create_auth_client("Forget stored login")
      auth_client.forget_refresh_token()
      RuntimeState.forget_email()
      S.has_stored_refresh = false
    elseif S.email ~= "" then
      RuntimeState.persist_email(S.email)
      RuntimeState.sync_stored_refresh_flag()
    end
  end

  local login_disabled = Jobs.network_busy()
  if login_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("login_btn", t("Login")) then
    ProductionFlow.begin_manual_login_flow()
  end
  if login_disabled then ImGui.EndDisabled(ctx) end

  if S.refresh_token ~= "" then
    ImGui.SameLine(ctx)
    if UI.button_clicked("refresh_login_btn", t("Retry login refresh")) then
      RecordFlow.schedule_job_or_status(t("Refresh login"), function() ProductionFlow.submit_refresh_flow(false) end)
    end
  end

  ImGui.SameLine(ctx)
  local forget_disabled = Jobs.network_busy()
  if forget_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("forget_login_btn", t("Forget stored login")) then
    local auth_client = ClientFactory.create_auth_client("Forget stored login")
    auth_client.forget_refresh_token()
    RuntimeState.forget_email()
    RuntimeState.clear_runtime_auth_state()
    S.password = ""
    S.has_stored_refresh = false
    S.status_text = t("Stored login cleared.")
    S.last_api_error = ""
    RuntimeState.rebuild_warnings()
  end
  if forget_disabled then ImGui.EndDisabled(ctx) end

end

function MainUI.render_preset_and_matching_section()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_SeparatorTextAlign, 0.15, 0.5)
  ImGui.SeparatorText(ctx, t("Processing"))
  ImGui.PopStyleVar(ctx)

  local preset_label = t("Connect first...")
  local selected_idx = tonumber(S.selected_preset_idx)
  if selected_idx and S.presets[selected_idx] and S.presets[selected_idx].name then
    preset_label = S.presets[selected_idx].name
  end

  local connect_disabled = Jobs.network_busy() or (S.access_token == "")
  if connect_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("connect_btn", t("(Re)Connect")) then
    RecordFlow.reset_progress_state("connect")
    RecordFlow.schedule_job_or_status(t("Connect"), function()
      Automix.begin_connect_flow(false)
    end, t("Request already running."))
  end
  if connect_disabled then ImGui.EndDisabled(ctx) end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Select preset:"))
  if ImGui.BeginCombo(ctx, "##automix_tool_select_preset", preset_label, ImGui.ComboFlags_HeightLarge) then
    ImGui.TextFilter_Draw(filter, ctx, t("Filter..."), 0)
    for i, preset in ipairs(S.presets or {}) do
      local name = tostring(preset.name or preset.uuid or string.format(t("Preset %s"), tostring(i)))
      if ImGui.TextFilter_PassFilter(filter, name) then
        local is_selected = (i == selected_idx)
        local activated = ImGui.Selectable(ctx, string.format(t("%d: %s"), i, name), is_selected)
        if activated then
          S.selected_preset_idx = i
          PresetFlow.apply_selected_preset_details()
          PresetFlow.rebuild_track_matching()
          RuntimeState.clear_production_runtime_state()
        end
        if is_selected then
          ImGui.SetItemDefaultFocus(ctx)
        end
      end
    end
    ImGui.EndCombo(ctx)
  end

  if UI.button_clicked("rebuild_track_list_btn", t("Rebuild track list")) then
    PresetFlow.rebuild_track_matching()
    RuntimeState.clear_production_runtime_state()
  end
  ImGui.SameLine(ctx)
  UI.ui_info(t("Track matching:"))
  local details = S.selected_preset_details
  if type(details) ~= "table" or type(details.multi_input_files) ~= "table" then
    UI.ui_info(t("No preset details loaded yet."))
  else
    if not S.tracks then
      PresetFlow.rebuild_track_matching()
    end

    for j, file_details in ipairs(details.multi_input_files) do
      local file_id = tostring(file_details and file_details.id or string.format(t("Input %s"), tostring(j)))
      local combo_label = (S.tracks and S.tracks.list and S.tracks.list[S.selected_tracks_indexes[j]]) or t("No tracks")
      local style_pushed = false
      local track_name_addition = ""
      if S.has_duplicate[j] then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, ImGui.ColorConvertDouble4ToU32(1, 1, 0, 1))
        style_pushed = true
        track_name_addition = t(" - check duplicate track names in project!")
      end
      if S.project_track_matched[j] ~= true then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, ImGui.ColorConvertDouble4ToU32(1, 0, 0, 1))
        style_pushed = true
        track_name_addition = t(" - no match, please make selection!")
      end

      if ImGui.BeginCombo(ctx, tostring(j) .. ": " .. file_id, combo_label .. track_name_addition, ImGui.ComboFlags_HeightLarge) then
        ImGui.TextFilter_Draw(filter, ctx, t("Filter..."), 0)
        for i, track_name in ipairs((S.tracks and S.tracks.list) or {}) do
          if ImGui.TextFilter_PassFilter(filter, track_name) then
            local is_selected = (i == S.selected_tracks_indexes[j])
            local activated = ImGui.Selectable(ctx, track_name, is_selected)
            if activated then
              S.selected_tracks_indexes[j] = i
              S.has_duplicate[j] = nil
              S.project_track_matched[j] = true
            end
            if is_selected then
              ImGui.SetItemDefaultFocus(ctx)
            end
          end
        end
        ImGui.EndCombo(ctx)
      end

      if style_pushed then
        ImGui.PopStyleColor(ctx)
      end

      ImGui.SameLine(ctx)
      if UI.button_clicked("copy_match_name_btn_" .. tostring(j), t("Copy name") .. "##" .. tostring(j)) then
        ImGui.SetClipboardText(ctx, file_id)
      end
    end
  end

  local stems_checkbox_disabled = type(details) ~= "table" or Util.trim(details.uuid or "") == ""
  if stems_checkbox_disabled then ImGui.BeginDisabled(ctx, true) end
  local changed_stems, new_create_stems = ImGui.Checkbox(ctx, t("Create stems archive"), S.create_stems_archive == true)
  if changed_stems then
    S.create_stems_archive = new_create_stems
    RuntimeState.clear_production_runtime_state()
  end
  if stems_checkbox_disabled then ImGui.EndDisabled(ctx) end

  RenderFlow.render_local_render_section()
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

function MainUI.render_diagnostics_settings()
  ImGui.TextWrapped(ctx, string.format(t("Backend: %s"), CFG.base_url))
  local backend_locked = Jobs.network_busy() or S.production_details ~= nil or S.creation_uncertain
  if backend_locked then ImGui.BeginDisabled(ctx, true) end
  local changed_backend, use_local = ImGui.Checkbox(ctx, t("Use local development backend (localhost:3002)"), S.use_local_backend)
  if changed_backend then
    RuntimeState.clear_runtime_auth_state()
    auth_session = nil
    S.use_local_backend = use_local
    CFG.base_url = use_local and AuphonicAPI.DEVELOPMENT_BASE or AuphonicAPI.PRODUCTION_BASE
    RuntimeState.persist_ui_state("use_local_backend", use_local and "1" or "0")
    RuntimeState.clear_preset_state()
    RuntimeState.sync_stored_refresh_flag()
    S.auto_auth_attempted = false
    ProductionFlow.try_auto_login_on_startup()
  end
  if backend_locked then ImGui.EndDisabled(ctx) end
  local diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Logging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, "##automix_tool_logging_threshold", diagnostics_threshold_label(diagnostics.logging_threshold), ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ 4, 0, 1, 2, 3 }) do
      local selected = diagnostics.logging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_logging_threshold(level)
        if not ok_set then RuntimeState.push_warning_once(string.format(t("Logging threshold save failed: %s"), tostring(err))) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Messaging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, "##automix_tool_messaging_threshold", diagnostics_threshold_label(diagnostics.messaging_threshold), ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ 0, 1, 2, 3, 4 }) do
      local selected = diagnostics.messaging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_messaging_threshold(level)
        if not ok_set then RuntimeState.push_warning_once(string.format(t("Messaging threshold save failed: %s"), tostring(err))) end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  UI.ui_info(string.format(t("Log folder: %s"), diagnostics.log_dir))
  UI.ui_info(string.format(
    t("Current log file: %s"),
    diagnostics.current_log_file ~= "" and diagnostics.current_log_file or t("(created after the first matching message)")
  ))
  if UI.button_clicked("copy_diagnostics_log_folder_btn", t("Copy log folder"), 0.2) then
    ImGui.SetClipboardText(ctx, diagnostics.log_dir)
  end
  UI.ui_info(t("Local logs may contain project paths, filenames, and workflow content."))
  if diagnostics.messaging_threshold == 4 then
    UI.ui_warning(t("Messaging is Off. Util-driven errors may be hidden."))
  end
end

function MainUI.render_telemetry_level_setting()
  local desc = TelemetryBridge.describe_status()
  local current_level = tostring(desc.effective_level or "support")
  local current_level_label = TelemetryBridge.level_label(current_level)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, t("Telemetry level") .. "##automix_tool_telemetry_level", current_level_label, ImGui.ComboFlags_HeightRegular) then
    for _, level in ipairs({ "basic", "support", "debug" }) do
      local selected = current_level == level
      local level_label = TelemetryBridge.level_label(level)
      if ImGui.Selectable(ctx, level_label, selected) then
        local ok_call, ok_set, set_or_err = pcall(Telemetry.set_level, level)
        if ok_call and ok_set then
          S.telemetry_ui_status = string.format(t("Telemetry level set to %s."), level_label)
          TelemetryBridge.safe_event("feature_used", {
            operation = "automix_telemetry_settings",
            status = "level_changed",
            telemetry_level = level
          }, {
            operation = "automix_telemetry_settings",
            status = "level_changed"
          })
        else
          local err = ok_call and set_or_err or ok_set
          S.telemetry_ui_status = string.format(t("Telemetry level save failed: %s"), tostring(err))
          RuntimeState.push_warning_once(S.telemetry_ui_status)
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

function MainUI.render_result_insertion_setting()
  ImGui.SeparatorText(ctx, t("Result insertion"))
  ImGui.Text(ctx, t("Insert results"))
  local choices = {
    {value="edit_cursor", label=t("At edit cursor")},
    {value="selection_start", label=t("At selection start captured when creating the job")}
  }
  local selected_label = S.result_insert_position == "selection_start" and choices[2].label or choices[1].label
  ImGui.SetNextItemWidth(ctx, -10.0)
  if ImGui.BeginCombo(ctx, "##automix_tool_result_insert_position", selected_label, ImGui.ComboFlags_HeightRegular) then
    for _, choice in ipairs(choices) do
      local selected = S.result_insert_position == choice.value
      if ImGui.Selectable(ctx, choice.label, selected) then
        RuntimeState.set_result_insert_position(choice.value)
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.TextWrapped(ctx, t("Applies to the next mix or stems download. Selection start is captured when you click Create production and upload. The DIA mix stays aligned with its selected stems."))
end

function MainUI.render_settings_section()
  if not ImGui.CollapsingHeader(ctx, t("Settings")) then return end
  ImGui.SeparatorText(ctx, t("Account / Credentials"))
  local auth_busy = Jobs.network_busy()
  if auth_busy then ImGui.BeginDisabled(ctx, true) end
  MainUI.render_auth_section()
  if auth_busy then ImGui.EndDisabled(ctx) end
  MainUI.render_result_insertion_setting()
  ImGui.SeparatorText(ctx, t("Paths"))
  MainUI.render_paths_section()
  ImGui.SeparatorText(ctx, t("Diagnostics"))
  MainUI.render_diagnostics_settings()
  ImGui.SeparatorText(ctx, t("Telemetry"))
  MainUI.render_telemetry_level_setting()
end

function MainUI.render_telemetry_section()
  local desc = TelemetryBridge.describe_status()
  local header_state = TelemetryBridge.header_state(desc)
  local header_label = string.format(t("Telemetry (%s)"), header_state) .. "###automix_tool_tool_telemetry_section"
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
    UI.ui_info(string.format(t("Telemetry progress: %s"), progress))
  else
    local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "##automix_tool_telemetry_status_table", 2, flags, -1, 0) then
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
    UI.ui_info(S.telemetry_ui_status)
  end

  local flush_disabled = desc.active_job_id ~= nil
  if flush_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("telemetry_flush_now_btn", t("Flush telemetry now"), 0.2) then
    TelemetryBridge.button_clicked("telemetry_flush_now_btn", t("Flush telemetry now"))
    TelemetryBridge.safe_flush_async("automix_manual")
  end
  if flush_disabled then ImGui.EndDisabled(ctx) end

  if desc.send_paused then
    ImGui.SameLine(ctx)
    if UI.button_clicked("telemetry_resume_btn", t("Resume telemetry sending"), 0.2) then
      TelemetryBridge.button_clicked("telemetry_resume_btn", t("Resume telemetry sending"))
      local ok_resume, resume_or_err = pcall(Telemetry.resume_sending, t("manual resume from Automix UI"))
      S.telemetry_ui_status = ok_resume and t("Telemetry sending resumed.") or string.format(t("Telemetry resume failed: %s"), tostring(resume_or_err))
    end
  end

  ImGui.SameLine(ctx)
  if UI.button_clicked("telemetry_copy_paths_btn", t("Copy telemetry paths"), 0.2) then
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
  ImGui.InputTextMultiline(ctx, "##automix_tool_telemetry_details", table.concat(details, "\n"), -1, 180, ImGui.InputTextFlags_ReadOnly)
end

function MainUI.render_debug_section()
  if not S.last_api_error then S.last_api_error = "" end
  if ImGui.CollapsingHeader(ctx, t("Details (errors, status)")) then
    local flags = ImGui.InputTextFlags_ReadOnly
    ImGui.InputTextMultiline(ctx, "##automix_tool_errbox", S.last_api_error, 0, 0, flags)
    UI.ui_print_out_last_curl_return(ctx)
  end
end

function MainUI.gui_loop()
  local now_t = r.time_precise()
  TelemetryBridge.safe_tick(now_t)
  Jobs.tick_all(now_t)
  Automix.tick_production_poll(now_t)
  MainUI.render_status_window()

  ImGui.SetNextWindowSize(ctx, 840, 900, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, MainUI.current_main_window_label(), true, ImGui.WindowFlags_NoCollapse)
  if visible then
    if ImGui.GetWindowPos and ImGui.GetWindowSize then
      S.main_window_pos_x, S.main_window_pos_y = ImGui.GetWindowPos(ctx)
      S.main_window_size_w, S.main_window_size_h = ImGui.GetWindowSize(ctx)
    end
    ImGui.PushFont(ctx, FONT, font_size)

    ImGui.Text(ctx, t("Language") .. ":")
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 160)
    local locale_combo_disabled = not Locale.translated_locale_available("rus")
    if locale_combo_disabled then ImGui.BeginDisabled(ctx, true) end
    local locale_combo_open = ImGui.BeginCombo(
      ctx,
      "##automix_tool_ui_locale_combo",
      Locale.locale_display_name(active_locale),
      ImGui.ComboFlags_HeightRegular
    )
    if locale_combo_open then
      local locale_options = { "eng" }
      if Locale.translated_locale_available("rus") then
        table.insert(locale_options, "rus")
      end
      for _, locale_id in ipairs(locale_options) do
        local is_selected = (active_locale == locale_id)
        local activated = ImGui.Selectable(ctx, Locale.locale_display_name(locale_id), is_selected)
        if activated then
          Locale.set_active_runtime_locale(locale_id)
          RuntimeState.persist_locale(locale_id)
        end
        if is_selected then
          ImGui.SetItemDefaultFocus(ctx)
        end
      end
      ImGui.EndCombo(ctx)
    end
    if locale_combo_disabled then ImGui.EndDisabled(ctx) end

    ImGui.SameLine(ctx)
    local changed_show_status, new_show_status = ImGui.Checkbox(ctx, t("Show status in dedicated window"), S.show_status_window)
    if changed_show_status then
      S.show_status_window = new_show_status
      RuntimeState.persist_show_status_window(new_show_status)
      TelemetryBridge.safe_event("feature_used", {
        operation = "automix_status_window_toggle",
        status = new_show_status and "enabled" or "disabled",
        show_status_window = new_show_status == true
      }, {
        operation = "automix_status_window_toggle",
        status = new_show_status and "enabled" or "disabled"
      })
    end

    if not S.show_status_window then
      UI.render_status_panel(ctx, "_inline")
    end
    MainUI.render_settings_section()
    local setup_locked = S.production_details ~= nil or S.creation_uncertain or Jobs.network_busy()
    if setup_locked then ImGui.BeginDisabled(ctx, true) end
    MainUI.render_preset_and_matching_section()
    if setup_locked then ImGui.EndDisabled(ctx) end
    UI.render_progress_table(ctx, "_inline")
    MainUI.render_production_lifecycle_section()
    MainUI.render_telemetry_section()
    MainUI.render_debug_section()
    PopupUI.render_paid_start_popup()
    PopupUI.render_cleanup_prompt_popup()

    ImGui.PopFont(ctx)
    ImGui.End(ctx)
  end

  if open then
    r.defer(MainUI.gui_loop)
  else
    TelemetryBridge.send_closed_event("window_closed")
  end
end

S.use_local_backend = RuntimeState.load_plain_ui_state("use_local_backend") == "1"
RuntimeState.load_result_insert_position_on_startup()
CFG.base_url = S.use_local_backend and AuphonicAPI.DEVELOPMENT_BASE or AuphonicAPI.PRODUCTION_BASE
ProductionFlow.load_email_on_startup()
RuntimeState.load_show_status_window_on_startup()
RuntimeState.load_locale_on_startup()
RuntimeState.load_dia_wav_bit_depth_on_startup()
RuntimeState.sync_stored_refresh_flag()
RuntimeState.rebuild_warnings()
TelemetryBridge.script_started()
ProductionFlow.try_auto_login_on_startup()
MainUI.gui_loop()
