-- Reaper-hosted user-oriented DOCX import prototype.
-- Current scope:
-- 1. Extract DOCX
-- 2. Parse extracted XML
-- 3. Preflight and explicit column mapping
-- 4. Cast processing and merge
-- 5. Timecode validation and correction

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
  return t("DOCX Import") .. " — script " .. SCRIPT_VERSION .. " / toolset " .. TOOLSET_VERSION
end

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
if not script_path then
  r.MB(t("Failed to get script path!"), t("Error"), 0)
  return
end

local old_package_path = package.path
package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. old_package_path

do
  local ok_languages, languages_or_err = pcall(require, "modules-neurocast.docx_import_tool_languages")
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

local ok_util, Util = pcall(require, "modules-neurocast.Util")
if not ok_util then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Util: %s"), tostring(Util)), t("Error"), 0)
  return
end

local ok_files, Files = pcall(require, "modules-neurocast.Files")
if not ok_files then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Files: %s"), tostring(Files)), t("Error"), 0)
  return
end

local ok_cleanup, Cleanup = pcall(require, "modules-neurocast.Cleanup")
if not ok_cleanup then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Cleanup: %s"), tostring(Cleanup)), t("Error"), 0)
  return
end

local ok_curl, Curl = pcall(require, "modules-neurocast.Curl")
if not ok_curl then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Curl: %s"), tostring(Curl)), t("Error"), 0)
  return
end

local ok_jobs, Jobs = pcall(require, "modules-neurocast.Jobs")
if not ok_jobs then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Jobs: %s"), tostring(Jobs)), t("Error"), 0)
  return
end

local ok_telemetry, Telemetry = pcall(require, "modules-neurocast.Telemetry")
if not ok_telemetry then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Telemetry: %s"), tostring(Telemetry)), t("Error"), 0)
  return
end

local ok_docx_telemetry_summary, DocxTelemetrySummary = pcall(require, "modules-neurocast.docx_telemetry_summary")
if not ok_docx_telemetry_summary then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.docx_telemetry_summary: %s"), tostring(DocxTelemetrySummary)), t("Error"), 0)
  return
end

if not Telemetry.require_identity_or_abort({
  app_name = "CirilicaTools",
  entrypoint = "docx_import_tool",
  script_version = SCRIPT_VERSION
}) then
  package.path = old_package_path
  return
end

local ok_telemetry_init, telemetry_init_err = Telemetry.init({
  app_name = "CirilicaTools",
  entrypoint = "docx_import_tool",
  script_version = SCRIPT_VERSION,
  enable_file_log = false
})
if not ok_telemetry_init then
  package.path = old_package_path
  r.MB(string.format(t("Telemetry initialization failed:\n%s"), tostring(telemetry_init_err)), t("Telemetry Error"), 0)
  return
end

local ok_extractor, DocxXmlExtractor = pcall(require, "modules-neurocast.docx_xml_extractor")
if not ok_extractor then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.docx_xml_extractor: %s"), tostring(DocxXmlExtractor)), t("Error"), 0)
  return
end

local ok_parser, DocxDialogueParser = pcall(require, "modules-neurocast.docx_dialogue_parser")
if not ok_parser then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.docx_dialogue_parser: %s"), tostring(DocxDialogueParser)), t("Error"), 0)
  return
end

local ok_parse, Parse = pcall(require, "modules-neurocast.Parse")
if not ok_parse then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Parse: %s"), tostring(Parse)), t("Error"), 0)
  return
end

local ok_dialogue_import, ReaperX_import_Dialogue = pcall(require, "modules-neurocast.ReaperX_import_Dialogue")
if not ok_dialogue_import then
  package.path = old_package_path
  r.MB(
    string.format(t("Failed to load modules-neurocast.ReaperX_import_Dialogue: %s"), tostring(ReaperX_import_Dialogue)),
    t("Error"),
    0
  )
  return
end

if not r.ImGui_CreateContext then
  package.path = old_package_path
  r.MB(t("Missing dependency: ReaImGui extension.\nDownload it via Reapack ReaTeam extension repository."), t("Error"), 0)
  return false
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

local old_util_state = {
  messaging_level = Util.messaging_level,
  msg_to_log_file = Util.msg_to_log_file,
  log_level_override = Util.log_level_override,
  full_path_to_log_file = Util.full_path_to_log_file,
  tmp_dir = Util.tmp_dir,
  log_file_name = Util.log_file_name
}

local old_extractor_settings = {
  keep_listing_on_failure = DocxXmlExtractor.settings.keep_listing_on_failure,
  delete_listing_on_success = DocxXmlExtractor.settings.delete_listing_on_success,
  keep_extract_log_on_failure = DocxXmlExtractor.settings.keep_extract_log_on_failure,
  delete_extract_log_on_success = DocxXmlExtractor.settings.delete_extract_log_on_success,
  exec_timeout_ms = DocxXmlExtractor.settings.exec_timeout_ms
}

local old_parse_settings = {
  empty_character_name_mode = Parse.empty_character_name_mode,
  maximum_allowed_typo_distance = Parse.maximum_allowed_typo_distance
}

local Helpers, TestCases, UI, TelemetryBridge = {}, {}, {}, {}
local send_telemetry_closed_event = nil
local ctx = ImGui.CreateContext(current_main_window_title_text())
local font_size = 16
local FONT = ImGui.CreateFont("monospace")
ImGui.Attach(ctx, FONT)

local runtime = {
  project_path = "",
  base_root = "",
  log_root = "",
  internal_root = "",
  default_output_root = ""
}

local EXTSTATE = {
  section = "docx_import_tool_ui",
  ui_locale = "ui_locale",
  docx_path = "docx_path",
  docx_source_mode = "docx_source_mode",
  header_enabled = "header_enabled",
  use_header_names = "use_header_names",
  dialogue_import_layout_mode = "dialogue_import_layout_mode",
  dialogue_import_single_track_name = "dialogue_import_single_track_name",
  dialogue_import_reuse_existing_tracks = "dialogue_import_reuse_existing_tracks",
  dialogue_import_apply_color_policy = "dialogue_import_apply_color_policy",
  dialogue_import_prepend_character_name = "dialogue_import_prepend_character_name",
  dialogue_import_create_rec_track = "dialogue_import_create_rec_track",
  dialogue_import_alt_take_track_count = "dialogue_import_alt_take_track_count",
  dialogue_import_make_folders = "dialogue_import_make_folders",
  dialogue_import_folder_collapsed_state = "dialogue_import_folder_collapsed_state",
  dialogue_import_length_mode = "dialogue_import_length_mode",
  dialogue_import_fixed_length_seconds = "dialogue_import_fixed_length_seconds",
  dialogue_import_chars_per_second = "dialogue_import_chars_per_second",
  dialogue_import_min_item_length_seconds = "dialogue_import_min_item_length_seconds",
  dialogue_import_too_close_seconds = "dialogue_import_too_close_seconds",
  dialogue_import_overlap_policy = "dialogue_import_overlap_policy",
  dialogue_import_add_warning_markers = "dialogue_import_add_warning_markers",
  timecode_offset_enabled = "timecode_offset_enabled",
  timecode_offset_direction = "timecode_offset_direction",
  timecode_offset_hours = "timecode_offset_hours",
  timecode_offset_minutes = "timecode_offset_minutes"
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
      return bundled_curl
    end
  end
  local detail = result and ("Unexpected curl --version output:\n" .. tostring(result)) or "Could not run bundled curl --version."
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

local telemetry_desc_on_startup = Telemetry.describe_status()
local telemetry_paths_on_startup = telemetry_desc_on_startup.paths or {}
local CFG = {
  curl = resolve_curl_path(),
  tmp_dir = tostring(telemetry_paths_on_startup.logs or Util.path_join(r.GetResourcePath(), "Data")),
  timeout_sec = 60,
  curl_connect_timeout_sec = 15,
  curl_speed_limit = 1,
  curl_speed_time = 30,
  max_concurrent_jobs = 2
}

local function forget_locale()
  local _, err = Util.extstate_delete(EXTSTATE.section, EXTSTATE.ui_locale, true)
  if err then
    Util.msg("Failed to forget UI locale: " .. tostring(err), 2)
  end
end

local function persist_locale(locale)
  local normalized = parse_runtime_locale(locale)
  if not normalized then
    forget_locale()
    return
  end
  local ok_set, err = Util.extstate_set(EXTSTATE.section, EXTSTATE.ui_locale, normalized, true)
  if not ok_set then
    Util.msg("Failed to persist UI locale: " .. tostring(err), 2)
  end
end

local function load_locale_from_ext_state()
  local value, err = Util.extstate_get(EXTSTATE.section, EXTSTATE.ui_locale)
  if err then
    Util.msg("Failed to load UI locale: " .. tostring(err), 2)
    return nil
  end
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
  if normalized ~= "eng" and (not translated_locale_available(normalized)) then
    return "eng"
  end
  return normalized
end

local function load_locale_on_startup()
  local stored = load_locale_from_ext_state()
  set_active_runtime_locale(stored or "eng")
end

load_locale_on_startup()

local DIALOGUE_IMPORT_DEFAULTS = {
  layout_mode = "single_track",
  single_track_name = t("Dialogue_Import"),
  reuse_existing_tracks = true,
  apply_color_policy = false,
  prepend_character_name = false,
  create_rec_track = false,
  alt_take_track_count = 1,
  make_folders = false,
  folder_collapsed_state = "normal",
  length_mode = "fixed",
  fixed_length_seconds = 3.0,
  chars_per_second = 15,
  min_item_length_seconds = 0.5,
  too_close_seconds = 0.2,
  overlap_policy = "allow",
  add_warning_markers = false
}

local TIMECODE_OFFSET_DEFAULTS = {
  enabled = false,
  direction = "right",
  hours = 0,
  minutes = 0
}

local FRAME_TIMECODE_FORMAT_ID = 3
local FPS_MATCH_TOLERANCE = 0.01

local DOCX_SOURCE_MODE_DEFAULT = "auto"
local DOCX_SOURCE_MODES = {
  {
    id = "auto",
    label = t("Auto-detect"),
    description = t("Let the parser choose the DOCX dialogue layout.")
  },
  {
    id = "table_last",
    label = t("Legacy table"),
    description = t("Use the last Word table as the parsed dialogue table.")
  },
  {
    id = "paragraph_start_end",
    label = t("Start/end paragraph blocks"),
    description = t("Use repeated start, end, character, dialogue paragraphs.")
  },
  {
    id = "paragraph_line_stream",
    label = t("Timecode/speaker line stream"),
    description = t("Use timecode, speaker, dialogue lines until the next timecode.")
  }
}

local function normalize_docx_source_mode(value)
  local text = tostring(value or "")
  for i = 1, #DOCX_SOURCE_MODES do
    if DOCX_SOURCE_MODES[i].id == text then
      return text
    end
  end
  return DOCX_SOURCE_MODE_DEFAULT
end

local function docx_source_mode_item(mode)
  local normalized = normalize_docx_source_mode(mode)
  for i = 1, #DOCX_SOURCE_MODES do
    if DOCX_SOURCE_MODES[i].id == normalized then
      return DOCX_SOURCE_MODES[i]
    end
  end
  return DOCX_SOURCE_MODES[1]
end

local function make_empty_extract_result()
  return {
    ok = nil,
    input_docx = "",
    output_dir = "",
    xml_path = "",
    message = "",
    elapsed_sec = nil
  }
end

local function make_empty_parse_result()
  return {
    ok = nil,
    input_xml = "",
    header_enabled = false,
    message = "",
    number_of_columns = 0,
    number_of_rows = 0,
    header = nil,
    rows = {},
    source_mode_requested = DOCX_SOURCE_MODE_DEFAULT,
    source_mode_detected = "",
    supports_header = false,
    suggested_timecode_format_id = nil,
    suggested_header_enabled = false,
    suggested_mapping = nil,
    row_metadata_by_index = {},
    end_timecode_count = 0,
    end_timecode_complete = false,
    warnings = {},
    warning_count = 0,
    empty_character_row_count = 0,
    elapsed_sec = nil
  }
end

local function make_empty_preflight_result()
  return {
    ok = nil,
    message = "",
    confirmed = false,
    readiness_text = t("Not ready."),
    number_of_columns = 0,
    mapped_row_count = 0,
    selected_timecode_col = 1,
    selected_character_name_col = 2,
    selected_dialogue_col = 3,
    use_end_timecodes = false,
    end_timecode_count = 0,
    end_timecode_complete = false,
    end_timecode_status_text = t("No end timecodes"),
    confirmed_mapping = nil,
    header_cells = {},
    visible_rows = {},
    visible_row_metadata = {}
  }
end

local function make_empty_cast_result()
  return {
    ok = nil,
    message = "",
    elapsed_sec = nil,
    total_elapsed_sec = nil,
    empty_character_name_mode = Parse.empty_character_name_mode,
    maximum_allowed_typo_distance = Parse.maximum_allowed_typo_distance,
    base_cast = {
      character_count = 0,
      merge_candidate_count = 0,
      characters = {},
      merge_candidates = {},
      script_rows = {},
      source_row_numbers = {},
      row_links = {}
    },
    merged_view = {
      character_count = 0,
      merge_candidate_count = 0,
      characters = {},
      merge_candidates = {},
      row_links = {}
    },
    applied_merges = {},
    selected_character_id = nil,
    selected_merge_candidate_index = nil
  }
end

local function default_timecode_format_id()
  local first = Parse.formats and Parse.formats[1] or nil
  return first and first.id or nil
end

local function make_empty_timecode_result()
  return {
    finalized = false,
    has_validated = false,
    fps_check_ran = false,
    selected_format_id = default_timecode_format_id(),
    source_fps_input = "",
    source_fps = nil,
    base_rows = {},
    rows = {},
    draft_raw_timecodes_by_source_row = {},
    draft_raw_end_timecodes_by_source_row = {},
    use_end_timecodes = false,
    extraction_active = false,
    extraction_format_id = nil,
    extracted_inline_count = 0,
    inline_result_visible = false,
    inline_result_text = "",
    inline_result_count = 0,
    final_look_applied = false,
    fps_warning_count = 0,
    fps_warning_row_indices = {},
    selected_fps_warning_position = nil,
    project_frame_rate = nil,
    project_drop_frame = false,
    offset_enabled = TIMECODE_OFFSET_DEFAULTS.enabled,
    offset_direction = TIMECODE_OFFSET_DEFAULTS.direction,
    offset_hours = TIMECODE_OFFSET_DEFAULTS.hours,
    offset_minutes = TIMECODE_OFFSET_DEFAULTS.minutes,
    offset_hours_input = string.format("%02d", TIMECODE_OFFSET_DEFAULTS.hours),
    offset_minutes_input = string.format("%02d", TIMECODE_OFFSET_DEFAULTS.minutes),
    offset_timecode_text = "00:00:00:00",
    offset_project_seconds = 0,
    bad_issue_row_indices = {},
    selected_bad_issue_position = nil,
    suspicious_issue_row_indices = {},
    selected_suspicious_issue_position = nil,
    pending_scroll_row_index = nil,
    total_count = 0,
    ok_count = 0,
    bad_count = 0,
    inconsistent_count = 0,
    ready = false,
    readiness_text = t("Not ready. Finalize Cast to continue."),
    message = "",
    elapsed_sec = nil
  }
end

local function make_empty_dialogue_import_runtime()
  return {
    preflight_has_run = false,
    preflight_is_stale = false,
    preflight_ok = nil,
    preflight_message = "",
    preflight_report = nil,
    last_apply_ok = nil,
    last_apply_message = "",
    last_apply_report = nil
  }
end

local function normalize_dialogue_import_layout_mode(value)
  if tostring(value or "") == "dedicated_tracks" then
    return "dedicated_tracks"
  end
  return DIALOGUE_IMPORT_DEFAULTS.layout_mode
end

local function normalize_dialogue_import_single_track_name(value)
  local text = Util.trim(tostring(value or ""))
  if text == "" then
    return DIALOGUE_IMPORT_DEFAULTS.single_track_name
  end
  return text
end

local function normalize_dialogue_import_alt_take_count(value)
  local number = tonumber(value)
  if not number then
    return DIALOGUE_IMPORT_DEFAULTS.alt_take_track_count
  end
  return math.max(0, math.floor(number))
end

local function normalize_dialogue_import_folder_collapsed_state(value)
  local collapsed_state = tostring(value or "")
  if collapsed_state == "collapsed" then
    return "collapsed"
  end
  if collapsed_state == "fully_collapsed" then
    return "fully_collapsed"
  end
  return DIALOGUE_IMPORT_DEFAULTS.folder_collapsed_state
end

local function normalize_dialogue_import_length_mode(value)
  if tostring(value or "") == "chars_per_second" then
    return "chars_per_second"
  end
  return DIALOGUE_IMPORT_DEFAULTS.length_mode
end

local function normalize_dialogue_import_fixed_length_seconds(value)
  local number = tonumber(value)
  if not number or number <= 0 then
    return DIALOGUE_IMPORT_DEFAULTS.fixed_length_seconds
  end
  return number
end

local function normalize_dialogue_import_chars_per_second(value)
  local number = tonumber(value)
  if not number or number <= 0 then
    return DIALOGUE_IMPORT_DEFAULTS.chars_per_second
  end
  return number
end

local function normalize_dialogue_import_min_item_length_seconds(value)
  local number = tonumber(value)
  if not number or number < 0 then
    return DIALOGUE_IMPORT_DEFAULTS.min_item_length_seconds
  end
  return number
end

local function normalize_dialogue_import_too_close_seconds(value)
  local number = tonumber(value)
  if not number or number < 0 then
    return DIALOGUE_IMPORT_DEFAULTS.too_close_seconds
  end
  return number
end

local function normalize_dialogue_import_overlap_policy(value)
  if tostring(value or "") == "shrink_to_fit_best_effort" then
    return "shrink_to_fit_best_effort"
  end
  return DIALOGUE_IMPORT_DEFAULTS.overlap_policy
end

local function normalize_timecode_offset_direction(value)
  if tostring(value or "") == "left" then
    return "left"
  end
  return TIMECODE_OFFSET_DEFAULTS.direction
end

local function normalize_timecode_offset_hours(value)
  local number = tonumber(value)
  if not number then
    return TIMECODE_OFFSET_DEFAULTS.hours
  end
  return math.max(0, math.min(99, math.floor(number)))
end

local function normalize_timecode_offset_minutes(value)
  local number = tonumber(value)
  if not number then
    return TIMECODE_OFFSET_DEFAULTS.minutes
  end
  return math.max(0, math.min(59, math.floor(number)))
end

local state = {
  docx_path = "",
  docx_source_mode = DOCX_SOURCE_MODE_DEFAULT,
  output_root = runtime.default_output_root,
  header_enabled = false,
  use_header_names = true,
  empty_character_name_mode = Parse.empty_character_name_mode,
  maximum_allowed_typo_distance = Parse.maximum_allowed_typo_distance,
  max_distance_input = tostring(Parse.maximum_allowed_typo_distance),
  current_status_line = t("Waiting for a DOCX file."),
  status_text = t("Ready."),
  last_status_text = t("Ready."),
  technical_status_text = "",
  warnings = {},
  rolling_log_lines = {},
  log_max_lines = 350,
  counters = { pass = 0, fail = 0, skip = 0 },
  dialogue_import_layout_mode = DIALOGUE_IMPORT_DEFAULTS.layout_mode,
  dialogue_import_single_track_name = DIALOGUE_IMPORT_DEFAULTS.single_track_name,
  dialogue_import_reuse_existing_tracks = DIALOGUE_IMPORT_DEFAULTS.reuse_existing_tracks,
  dialogue_import_apply_color_policy = DIALOGUE_IMPORT_DEFAULTS.apply_color_policy,
  dialogue_import_prepend_character_name = DIALOGUE_IMPORT_DEFAULTS.prepend_character_name,
  dialogue_import_create_rec_track = DIALOGUE_IMPORT_DEFAULTS.create_rec_track,
  dialogue_import_alt_take_track_count = DIALOGUE_IMPORT_DEFAULTS.alt_take_track_count,
  dialogue_import_alt_take_track_count_input = tostring(DIALOGUE_IMPORT_DEFAULTS.alt_take_track_count),
  dialogue_import_make_folders = DIALOGUE_IMPORT_DEFAULTS.make_folders,
  dialogue_import_folder_collapsed_state = DIALOGUE_IMPORT_DEFAULTS.folder_collapsed_state,
  dialogue_import_length_mode = DIALOGUE_IMPORT_DEFAULTS.length_mode,
  dialogue_import_fixed_length_seconds = DIALOGUE_IMPORT_DEFAULTS.fixed_length_seconds,
  dialogue_import_chars_per_second = DIALOGUE_IMPORT_DEFAULTS.chars_per_second,
  dialogue_import_min_item_length_seconds = DIALOGUE_IMPORT_DEFAULTS.min_item_length_seconds,
  dialogue_import_too_close_seconds = DIALOGUE_IMPORT_DEFAULTS.too_close_seconds,
  dialogue_import_overlap_policy = DIALOGUE_IMPORT_DEFAULTS.overlap_policy,
  dialogue_import_add_warning_markers = DIALOGUE_IMPORT_DEFAULTS.add_warning_markers,
  import_ready_rows = {},
  last_extract = make_empty_extract_result(),
  last_parse = make_empty_parse_result(),
  last_preflight = make_empty_preflight_result(),
  last_cast = make_empty_cast_result(),
  last_timecode = make_empty_timecode_result(),
  last_dialogue_import = make_empty_dialogue_import_runtime(),
  telemetry_ui_status = "",
  telemetry_edited_rows = {},
  pending_job = nil,
  wait_until = nil,
  running_label = nil,
  ui_lock_network_buttons = false,
  curl_jobs = {},
  cleanup_queue = {},
  cleanup_failures = {},
  retry_queue = {},
  retry_generation = 0,
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

do
  local ok_tmp, tmp_err = Files.ensure_tmp_dir(CFG.tmp_dir)
  if not ok_tmp then
    package.path = old_package_path
    r.MB(string.format(t("Telemetry temporary directory setup failed:\n%s"), tostring(tmp_err)), t("Telemetry Error"), 0)
    return
  end
end

Cleanup.init(state, CFG)
Curl.init(state, CFG)
Jobs.init(state, CFG)

function Helpers.refresh_project_relative_paths()
  local project_path = Files.read_project_path() or ""
  runtime.project_path = project_path

  if project_path ~= "" then
    runtime.base_root = project_path .. Util.separator .. "docx_import_tmp"
    runtime.log_root = Util.path_join(runtime.base_root, "logs")
    runtime.internal_root = runtime.base_root
    runtime.default_output_root = Util.path_join(runtime.base_root, "output")
    r.RecursiveCreateDirectory(runtime.base_root, 0)
    r.RecursiveCreateDirectory(runtime.log_root, 0)
    r.RecursiveCreateDirectory(runtime.default_output_root, 0)
  else
    runtime.base_root = ""
    runtime.log_root = ""
    runtime.internal_root = ""
    runtime.default_output_root = ""
  end

  if state ~= nil then
    state.output_root = runtime.default_output_root or ""
  end

  return runtime.base_root
end

local function restore_state()
  if type(send_telemetry_closed_event) == "function" then
    send_telemetry_closed_event("atexit")
  end
  package.path = old_package_path
  Util.messaging_level = old_util_state.messaging_level
  Util.msg_to_log_file = old_util_state.msg_to_log_file
  Util.log_level_override = old_util_state.log_level_override
  Util.full_path_to_log_file = old_util_state.full_path_to_log_file
  Util.tmp_dir = old_util_state.tmp_dir
  Util.log_file_name = old_util_state.log_file_name

  DocxXmlExtractor.settings.keep_listing_on_failure = old_extractor_settings.keep_listing_on_failure
  DocxXmlExtractor.settings.delete_listing_on_success = old_extractor_settings.delete_listing_on_success
  DocxXmlExtractor.settings.keep_extract_log_on_failure = old_extractor_settings.keep_extract_log_on_failure
  DocxXmlExtractor.settings.delete_extract_log_on_success = old_extractor_settings.delete_extract_log_on_success
  DocxXmlExtractor.settings.exec_timeout_ms = old_extractor_settings.exec_timeout_ms

  Parse.empty_character_name_mode = old_parse_settings.empty_character_name_mode
  Parse.maximum_allowed_typo_distance = old_parse_settings.maximum_allowed_typo_distance
end

r.atexit(restore_state)

Util.messaging_level = 3
Util.msg_to_log_file = false
Util.log_level_override = 0
Util.full_path_to_log_file = nil
Util.configure_diagnostics("docx_import_tool")

DocxXmlExtractor.settings.keep_listing_on_failure = true
DocxXmlExtractor.settings.delete_listing_on_success = false
DocxXmlExtractor.settings.keep_extract_log_on_failure = true
DocxXmlExtractor.settings.delete_extract_log_on_success = false

function Helpers.add_log_line(line)
  table.insert(state.rolling_log_lines, line)
  if #state.rolling_log_lines > state.log_max_lines then
    table.remove(state.rolling_log_lines, 1)
  end
end

function Helpers.set_status(status_line, last_status, technical_status)
  if status_line ~= nil and tostring(status_line) ~= "" then
    state.current_status_line = tostring(status_line)
  end
  if last_status ~= nil and tostring(last_status) ~= "" then
    state.last_status_text = tostring(last_status)
    state.status_text = tostring(last_status)
  end
  if technical_status ~= nil then
    state.technical_status_text = tostring(technical_status)
  end
end

function Helpers.add_warning(message)
  local text = Util.trim(tostring(message or ""))
  if text == "" then
    return
  end
  state.warnings[#state.warnings + 1] = text
end

function Helpers.clear_warnings()
  state.warnings = {}
end

function Helpers.add_parse_warnings_from_result(result)
  local warnings = type(result) == "table" and result.warnings or {}
  if type(warnings) ~= "table" then
    return
  end
  local existing = {}
  for i = 1, #state.warnings do
    existing[tostring(state.warnings[i] or "")] = true
  end
  for i = 1, #warnings do
    local text = Util.trim(tostring(warnings[i] or ""))
    if text ~= "" and existing[text] ~= true then
      Helpers.add_warning(text)
      existing[text] = true
    end
  end
end

function Helpers.workflow_status_text()
  if state.last_timecode.final_look_applied == true then
    return t("Import-ready rows are locked to parsed timecodes.")
  end
  if state.last_timecode.ready == true then
    return t("Import-ready rows are ready.")
  end
  if state.last_timecode.finalized == true then
    return tostring(state.last_timecode.readiness_text or t("Not ready."))
  end
  if state.last_cast.ok == true then
    return t("Cast is ready for timecode review.")
  end
  if state.last_preflight.confirmed == true then
    return t("Mapping is confirmed. Process cast next.")
  end
  if state.last_parse.ok == true then
    return t("Review columns and confirm mapping.")
  end
  return t("Load a DOCX file to begin.")
end

function Helpers.log_status_label(status)
  local value = tostring(status or "")
  if value == "PASS" then
    return t("PASS")
  end
  if value == "SKIP" then
    return t("SKIP")
  end
  if value == "STEP" then
    return t("STEP")
  end
  return t("FAIL")
end

function Helpers.log_step(test_id, message, importance)
  local line = os.date("%H:%M:%S") .. " [" .. Helpers.log_status_label("STEP") .. "] " .. tostring(test_id) .. " - " .. tostring(message or "")
  Helpers.add_log_line(line)
  Helpers.set_status(nil, tostring(message or ""), line)
  Util.msg(line, importance or 1)
end

function Helpers.log_outcome(test_id, status, details)
  local st = tostring(status or "FAIL")
  local line = os.date("%H:%M:%S") .. " [" .. Helpers.log_status_label(st) .. "] " .. tostring(test_id) .. " - " .. tostring(details or "")
  Helpers.set_status(Helpers.workflow_status_text(), tostring(details or line), line)
  Helpers.add_log_line(line)
  if st == "PASS" then
    state.counters.pass = state.counters.pass + 1
    Util.msg(line, 1)
  elseif st == "SKIP" then
    state.counters.skip = state.counters.skip + 1
    Util.msg(line, 1)
  else
    state.counters.fail = state.counters.fail + 1
    Helpers.add_warning(details or line)
    Util.msg(line, 2)
  end
end

function Helpers.log_result(test_id, passed, details)
  Helpers.log_outcome(test_id, passed and "PASS" or "FAIL", details)
end

function Helpers.persist_string(key, value)
  local ok, err = Util.extstate_set(EXTSTATE.section, key, tostring(value or ""), true)
  if not ok then
    Helpers.log_step("persist_" .. tostring(key), string.format(t("Failed: %s"), tostring(err)), 2)
  end
end

function Helpers.persist_boolean(key, value)
  Helpers.persist_string(key, value and "1" or "0")
end

function Helpers.load_persisted_string(key)
  local value, err = Util.extstate_get(EXTSTATE.section, key)
  if err then
    Helpers.log_step("load_" .. tostring(key), string.format(t("Failed: %s"), tostring(err)), 2)
    return nil
  end
  return value
end

function Helpers.is_windows_absolute_path(path)
  local text = tostring(path or "")
  if text == "" then return false end
  if Util.mac then
    return text:sub(1, 1) == "/"
  end
  if text:match("^%a:[/\\]") then return true end
  if text:match("^\\\\[^\\]+\\[^\\]+") then return true end
  return false
end

function Helpers.has_extension(path, ext)
  local text = tostring(path or ""):lower()
  return text:sub(-#ext) == ext
end

function Helpers.format_elapsed_seconds(elapsed_sec)
  if type(elapsed_sec) ~= "number" then
    return t("(n/a)")
  end
  return string.format(t("%.6f sec (%.3f ms)"), elapsed_sec, elapsed_sec * 1000.0)
end

function Helpers.safe_header_label(idx, value)
  local text = tostring(value or "")
  if text == "" then
    return string.format(t("Col %d (blank)"), idx)
  end
  return text
end

function Helpers.readable_bool(value)
  if value == true then return t("true") end
  if value == false then return t("false") end
  return t("(nil)")
end

function Helpers.message_has_warning(message)
  return tostring(message or ""):find("warning:", 1, true) ~= nil
end

function Helpers.short_preview_text(value, max_len)
  local text = tostring(value or "")
  text = text:gsub("[\r\n]+", " / ")
  text = Util.trim(text)
  if text == "" then
    return t("(blank)")
  end
  local limit = tonumber(max_len) or 42
  if #text > limit then
    return text:sub(1, math.max(1, limit - 3)) .. "..."
  end
  return text
end

function Helpers.load_persisted_state()
  local docx_path = Helpers.load_persisted_string(EXTSTATE.docx_path)
  if type(docx_path) == "string" then
    state.docx_path = docx_path
  end

  local docx_source_mode = Helpers.load_persisted_string(EXTSTATE.docx_source_mode)
  if type(docx_source_mode) == "string" and docx_source_mode ~= "" then
    state.docx_source_mode = normalize_docx_source_mode(docx_source_mode)
  end

  local header_enabled = Helpers.load_persisted_string(EXTSTATE.header_enabled)
  if header_enabled == "1" or header_enabled == "true" then
    state.header_enabled = true
  end

  local use_header_names = Helpers.load_persisted_string(EXTSTATE.use_header_names)
  if use_header_names == "0" or use_header_names == "false" then
    state.use_header_names = false
  elseif use_header_names == "1" or use_header_names == "true" then
    state.use_header_names = true
  end

  local dialogue_import_layout_mode = Helpers.load_persisted_string(EXTSTATE.dialogue_import_layout_mode)
  if type(dialogue_import_layout_mode) == "string" and dialogue_import_layout_mode ~= "" then
    state.dialogue_import_layout_mode = normalize_dialogue_import_layout_mode(dialogue_import_layout_mode)
  end

  local dialogue_import_single_track_name = Helpers.load_persisted_string(EXTSTATE.dialogue_import_single_track_name)
  if type(dialogue_import_single_track_name) == "string" and dialogue_import_single_track_name ~= "" then
    state.dialogue_import_single_track_name = normalize_dialogue_import_single_track_name(dialogue_import_single_track_name)
  end

  local dialogue_import_reuse_existing_tracks = Helpers.load_persisted_string(EXTSTATE.dialogue_import_reuse_existing_tracks)
  if dialogue_import_reuse_existing_tracks == "1" or dialogue_import_reuse_existing_tracks == "true" then
    state.dialogue_import_reuse_existing_tracks = true
  elseif dialogue_import_reuse_existing_tracks == "0" or dialogue_import_reuse_existing_tracks == "false" then
    state.dialogue_import_reuse_existing_tracks = false
  end

  local dialogue_import_apply_color_policy = Helpers.load_persisted_string(EXTSTATE.dialogue_import_apply_color_policy)
  if dialogue_import_apply_color_policy == "1" or dialogue_import_apply_color_policy == "true" then
    state.dialogue_import_apply_color_policy = true
  elseif dialogue_import_apply_color_policy == "0" or dialogue_import_apply_color_policy == "false" then
    state.dialogue_import_apply_color_policy = false
  end

  local dialogue_import_prepend_character_name = Helpers.load_persisted_string(EXTSTATE.dialogue_import_prepend_character_name)
  if dialogue_import_prepend_character_name == "1" or dialogue_import_prepend_character_name == "true" then
    state.dialogue_import_prepend_character_name = true
  elseif dialogue_import_prepend_character_name == "0" or dialogue_import_prepend_character_name == "false" then
    state.dialogue_import_prepend_character_name = false
  end

  local dialogue_import_create_rec_track = Helpers.load_persisted_string(EXTSTATE.dialogue_import_create_rec_track)
  if dialogue_import_create_rec_track == "1" or dialogue_import_create_rec_track == "true" then
    state.dialogue_import_create_rec_track = true
  elseif dialogue_import_create_rec_track == "0" or dialogue_import_create_rec_track == "false" then
    state.dialogue_import_create_rec_track = false
  end

  local dialogue_import_alt_take_track_count = Helpers.load_persisted_string(EXTSTATE.dialogue_import_alt_take_track_count)
  if dialogue_import_alt_take_track_count ~= nil and dialogue_import_alt_take_track_count ~= "" then
    state.dialogue_import_alt_take_track_count = normalize_dialogue_import_alt_take_count(dialogue_import_alt_take_track_count)
    state.dialogue_import_alt_take_track_count_input = tostring(state.dialogue_import_alt_take_track_count)
  end

  local dialogue_import_make_folders = Helpers.load_persisted_string(EXTSTATE.dialogue_import_make_folders)
  if dialogue_import_make_folders == "1" or dialogue_import_make_folders == "true" then
    state.dialogue_import_make_folders = true
  elseif dialogue_import_make_folders == "0" or dialogue_import_make_folders == "false" then
    state.dialogue_import_make_folders = false
  end

  local dialogue_import_folder_collapsed_state = Helpers.load_persisted_string(EXTSTATE.dialogue_import_folder_collapsed_state)
  if dialogue_import_folder_collapsed_state ~= nil and dialogue_import_folder_collapsed_state ~= "" then
    state.dialogue_import_folder_collapsed_state =
      normalize_dialogue_import_folder_collapsed_state(dialogue_import_folder_collapsed_state)
  end

  local dialogue_import_length_mode = Helpers.load_persisted_string(EXTSTATE.dialogue_import_length_mode)
  if type(dialogue_import_length_mode) == "string" and dialogue_import_length_mode ~= "" then
    state.dialogue_import_length_mode = normalize_dialogue_import_length_mode(dialogue_import_length_mode)
  end

  local dialogue_import_fixed_length_seconds = Helpers.load_persisted_string(EXTSTATE.dialogue_import_fixed_length_seconds)
  if dialogue_import_fixed_length_seconds ~= nil and dialogue_import_fixed_length_seconds ~= "" then
    state.dialogue_import_fixed_length_seconds =
      normalize_dialogue_import_fixed_length_seconds(dialogue_import_fixed_length_seconds)
  end

  local dialogue_import_chars_per_second = Helpers.load_persisted_string(EXTSTATE.dialogue_import_chars_per_second)
  if dialogue_import_chars_per_second ~= nil and dialogue_import_chars_per_second ~= "" then
    state.dialogue_import_chars_per_second =
      normalize_dialogue_import_chars_per_second(dialogue_import_chars_per_second)
  end

  local dialogue_import_min_item_length_seconds = Helpers.load_persisted_string(EXTSTATE.dialogue_import_min_item_length_seconds)
  if dialogue_import_min_item_length_seconds ~= nil and dialogue_import_min_item_length_seconds ~= "" then
    state.dialogue_import_min_item_length_seconds =
      normalize_dialogue_import_min_item_length_seconds(dialogue_import_min_item_length_seconds)
  end

  local dialogue_import_too_close_seconds = Helpers.load_persisted_string(EXTSTATE.dialogue_import_too_close_seconds)
  if dialogue_import_too_close_seconds ~= nil and dialogue_import_too_close_seconds ~= "" then
    state.dialogue_import_too_close_seconds =
      normalize_dialogue_import_too_close_seconds(dialogue_import_too_close_seconds)
  end

  local dialogue_import_overlap_policy = Helpers.load_persisted_string(EXTSTATE.dialogue_import_overlap_policy)
  if dialogue_import_overlap_policy ~= nil and dialogue_import_overlap_policy ~= "" then
    state.dialogue_import_overlap_policy =
      normalize_dialogue_import_overlap_policy(dialogue_import_overlap_policy)
  end

  local dialogue_import_add_warning_markers = Helpers.load_persisted_string(EXTSTATE.dialogue_import_add_warning_markers)
  if dialogue_import_add_warning_markers == "1" or dialogue_import_add_warning_markers == "true" then
    state.dialogue_import_add_warning_markers = true
  elseif dialogue_import_add_warning_markers == "0" or dialogue_import_add_warning_markers == "false" then
    state.dialogue_import_add_warning_markers = false
  end

  if state.dialogue_import_create_rec_track ~= true then
    state.dialogue_import_alt_take_track_count = DIALOGUE_IMPORT_DEFAULTS.alt_take_track_count
    state.dialogue_import_alt_take_track_count_input = tostring(state.dialogue_import_alt_take_track_count)
  end

  local timecode_offset_enabled = Helpers.load_persisted_string(EXTSTATE.timecode_offset_enabled)
  if timecode_offset_enabled == "1" or timecode_offset_enabled == "true" then
    state.last_timecode.offset_enabled = true
  elseif timecode_offset_enabled == "0" or timecode_offset_enabled == "false" then
    state.last_timecode.offset_enabled = false
  end

  local timecode_offset_direction = Helpers.load_persisted_string(EXTSTATE.timecode_offset_direction)
  if type(timecode_offset_direction) == "string" and timecode_offset_direction ~= "" then
    state.last_timecode.offset_direction = normalize_timecode_offset_direction(timecode_offset_direction)
  end

  local timecode_offset_hours = Helpers.load_persisted_string(EXTSTATE.timecode_offset_hours)
  if timecode_offset_hours ~= nil and timecode_offset_hours ~= "" then
    state.last_timecode.offset_hours = normalize_timecode_offset_hours(timecode_offset_hours)
  end

  local timecode_offset_minutes = Helpers.load_persisted_string(EXTSTATE.timecode_offset_minutes)
  if timecode_offset_minutes ~= nil and timecode_offset_minutes ~= "" then
    state.last_timecode.offset_minutes = normalize_timecode_offset_minutes(timecode_offset_minutes)
  end

  Helpers.sync_timecode_offset_inputs()
  Helpers.refresh_project_timecode_context()
end

function Helpers.prompt_for_file(window_title, initial_dir, file_types)
  local title = window_title or t("Select a File")
  local initial = initial_dir or ""
  if initial ~= "" then
    local last_char = initial:sub(-1)
    if last_char ~= Util.separator and last_char ~= "/" and last_char ~= "\\" then
      initial = initial .. Util.separator
    end
  end

  local ok_pick, selected_path = r.GetUserFileNameForRead(initial, title, file_types or "")
  if not ok_pick then
    return false, t("File selection was cancelled by the user or an error occurred.")
  end
  if selected_path == nil or selected_path == "" then
    return false, t("File selection reported success, but no valid file path was returned.")
  end
  return true, selected_path
end

function Helpers.make_run_output_dir(prefix)
  local base_root = Util.trim(state.output_root)
  if base_root == "" then
    return nil, t("output_root must be a non-empty string")
  end
  local dir_name = tostring(prefix or "run") .. "_" .. Util.date_time_stamp_with_time_precise()
  return Util.path_join(base_root, dir_name)
end

function Helpers.path_inside_created_output_dir(path, out_dir)
  return Files.is_path_inside(out_dir, path)
end

function Helpers.store_extract_result(payload)
  state.last_extract.ok = payload.ok
  state.last_extract.input_docx = payload.input_docx or ""
  state.last_extract.output_dir = payload.output_dir or ""
  state.last_extract.xml_path = payload.xml_path or ""
  state.last_extract.message = payload.message or ""
  state.last_extract.elapsed_sec = payload.elapsed_sec
end

function Helpers.count_end_timecodes_in_parse_result(result)
  local rows = result and result.rows or {}
  local metadata = result and result.row_metadata_by_index or {}
  local count = 0
  for row_index = 1, #(rows or {}) do
    local meta = metadata[row_index] or {}
    if Util.trim(tostring(meta.end_timecode or "")) ~= "" then
      count = count + 1
    end
  end
  return count, (#(rows or {}) > 0 and count == #(rows or {}))
end

function Helpers.apply_parse_suggested_timecode_format()
  local suggested = tonumber(state.last_parse.suggested_timecode_format_id)
  if suggested ~= nil and Helpers.find_timecode_format_by_id and Helpers.find_timecode_format_by_id(suggested) ~= nil then
    state.last_timecode.selected_format_id = suggested
  end
end

function Helpers.store_parse_result(payload)
  state.last_parse.ok = payload.ok
  state.last_parse.input_xml = payload.input_xml or ""
  state.last_parse.header_enabled = payload.header_enabled == true
  state.last_parse.message = payload.result and payload.result.message or payload.message or ""
  state.last_parse.number_of_columns = tonumber(payload.result and payload.result.number_of_columns) or 0
  state.last_parse.number_of_rows = tonumber(payload.result and payload.result.number_of_rows) or 0
  state.last_parse.header = payload.result and payload.result.header or nil
  state.last_parse.rows = payload.result and payload.result.rows or {}
  state.last_parse.source_mode_requested = payload.result and payload.result.source_mode_requested or state.docx_source_mode
  state.last_parse.source_mode_detected = payload.result and payload.result.source_mode_detected or ""
  state.last_parse.supports_header = payload.result and payload.result.supports_header == true
  state.last_parse.suggested_timecode_format_id = payload.result and payload.result.suggested_timecode_format_id or nil
  state.last_parse.suggested_header_enabled = payload.result and payload.result.suggested_header_enabled == true
  state.last_parse.suggested_mapping = payload.result and payload.result.suggested_mapping or nil
  state.last_parse.row_metadata_by_index = payload.result and payload.result.row_metadata_by_index or {}
  state.last_parse.end_timecode_count, state.last_parse.end_timecode_complete =
    Helpers.count_end_timecodes_in_parse_result(payload.result)
  state.last_parse.warnings = payload.result and payload.result.warnings or {}
  state.last_parse.warning_count = tonumber(payload.result and payload.result.warning_count) or 0
  state.last_parse.empty_character_row_count = tonumber(payload.result and payload.result.empty_character_row_count) or 0
  state.last_parse.elapsed_sec = payload.elapsed_sec
  Helpers.apply_parse_suggested_timecode_format()
end

function Helpers.store_cast_result(payload)
  local last = state.last_cast
  last.ok = payload.ok
  last.message = payload.message or ""
  last.elapsed_sec = payload.elapsed_sec
  last.total_elapsed_sec = payload.total_elapsed_sec
  last.empty_character_name_mode = payload.empty_character_name_mode
  last.maximum_allowed_typo_distance = payload.maximum_allowed_typo_distance
  last.base_cast = {
    character_count = tonumber(payload.character_count) or 0,
    merge_candidate_count = tonumber(payload.merge_candidate_count) or 0,
    characters = payload.characters or {},
    merge_candidates = payload.merge_candidates or {},
    script_rows = payload.script_rows or {},
    source_row_numbers = payload.source_row_numbers or {},
    row_links = payload.row_links or {}
  }
  last.merged_view = {
    character_count = 0,
    merge_candidate_count = 0,
    characters = {},
    merge_candidates = {},
    row_links = {}
  }
  last.applied_merges = {}
  last.selected_character_id = nil
  last.selected_merge_candidate_index = nil
  if Helpers.refresh_merged_view then
    Helpers.refresh_merged_view()
  end
  Helpers.refresh_import_ready_rows()
end

function Helpers.copy_string_map(map_in)
  local out = {}
  for key, value in pairs(map_in or {}) do
    out[key] = value
  end
  return out
end

function Helpers.copy_timecode_review_row(row)
  local source = row or {}
  return {
    row_index = source.row_index,
    row_key = tostring(source.row_key or ""),
    base_row_index = source.base_row_index,
    segment_index = source.segment_index,
    source_row_index = source.source_row_index,
    original_timecode = tostring(source.original_timecode or ""),
    raw_timecode_text = tostring(source.raw_timecode_text or ""),
    original_end_timecode = tostring(source.original_end_timecode or ""),
    raw_end_timecode_text = tostring(source.raw_end_timecode_text or ""),
    raw_character_name = tostring(source.raw_character_name or ""),
    canonical_name = tostring(source.canonical_name or ""),
    canonical_id = source.canonical_id,
    resolved_group = tostring(source.resolved_group or ""),
    dialogue = tostring(source.dialogue or ""),
    extracted_from_inline = source.extracted_from_inline == true,
    status = tostring(source.status or ""),
    validation_message = tostring(source.validation_message or ""),
    normalized_timecode = source.normalized_timecode,
    normalized_end_timecode = source.normalized_end_timecode,
    parser_seconds = source.parser_seconds,
    end_parser_seconds = source.end_parser_seconds,
    project_source_seconds = source.project_source_seconds,
    end_project_source_seconds = source.end_project_source_seconds,
    raw_seconds = source.raw_seconds,
    end_raw_seconds = source.end_raw_seconds,
    effective_timecode_text = tostring(source.effective_timecode_text or ""),
    effective_end_timecode_text = tostring(source.effective_end_timecode_text or ""),
    fps_warning_message = tostring(source.fps_warning_message or ""),
    fps_warning = source.fps_warning == true
  }
end

function Helpers.copy_timecode_review_rows(rows_in)
  local out = {}
  for i = 1, #(rows_in or {}) do
    out[i] = Helpers.copy_timecode_review_row(rows_in[i])
  end
  return out
end

function Helpers.copy_import_ready_rows(rows_in)
  return Helpers.copy_timecode_review_rows(rows_in)
end

function Helpers.refresh_project_timecode_context()
  local frame_rate = nil
  local drop_frame = false
  if type(r.TimeMap_curFrameRate) == "function" then
    frame_rate, drop_frame = r.TimeMap_curFrameRate(0)
  end
  state.last_timecode.project_frame_rate = tonumber(frame_rate)
  state.last_timecode.project_drop_frame = drop_frame == true
  return state.last_timecode.project_frame_rate, state.last_timecode.project_drop_frame
end

function Helpers.is_frame_timecode_format(format_item)
  return type(format_item) == "table" and tonumber(format_item.id) == FRAME_TIMECODE_FORMAT_ID
end

function Helpers.parse_source_fps_input(text)
  local normalized = Util.trim(tostring(text or "")):gsub(",", ".")
  if normalized == "" then
    return nil, t("Source FPS is required for HH:MM:SS:FF timecodes.")
  end

  local value = tonumber(normalized)
  if value == nil or value <= 0 then
    return nil, t("Source FPS must be a number greater than 0.")
  end

  return value, nil
end

function Helpers.fps_values_match(left, right)
  local a = tonumber(left)
  local b = tonumber(right)
  if a == nil or b == nil then
    return false
  end
  return math.abs(a - b) <= FPS_MATCH_TOLERANCE
end

function Helpers.frame_timecode_validation_context(format_item)
  if not Helpers.is_frame_timecode_format(format_item) then
    return {
      ok = true,
      source_fps = nil,
      project_frame_rate = nil,
      project_drop_frame = false,
      message = ""
    }
  end

  state.last_timecode.source_fps = nil
  local source_fps, source_fps_err = Helpers.parse_source_fps_input(state.last_timecode.source_fps_input)
  if source_fps == nil then
    return {
      ok = false,
      source_fps = nil,
      project_frame_rate = nil,
      project_drop_frame = false,
      message = source_fps_err
    }
  end

  local project_frame_rate, project_drop_frame = Helpers.refresh_project_timecode_context()
  if type(project_frame_rate) ~= "number" or project_frame_rate <= 0 then
    return {
      ok = false,
      source_fps = source_fps,
      project_frame_rate = project_frame_rate,
      project_drop_frame = project_drop_frame,
      message = t("REAPER project FPS is unavailable. Check Project settings > Video > Frame rate.")
    }
  end

  if project_drop_frame == true then
    return {
      ok = false,
      source_fps = source_fps,
      project_frame_rate = project_frame_rate,
      project_drop_frame = project_drop_frame,
      message = t("Drop-frame project timecode is not supported for DOCX HH:MM:SS:FF import.")
    }
  end

  if not Helpers.fps_values_match(source_fps, project_frame_rate) then
    return {
      ok = false,
      source_fps = source_fps,
      project_frame_rate = project_frame_rate,
      project_drop_frame = project_drop_frame,
      message = string.format(
        t("Source FPS %.3f does not match REAPER project FPS %.3f. Set the project FPS or source FPS before validating."),
        source_fps,
        project_frame_rate
      )
    }
  end

  state.last_timecode.source_fps = source_fps
  return {
    ok = true,
    source_fps = source_fps,
    project_frame_rate = project_frame_rate,
    project_drop_frame = project_drop_frame,
    message = ""
  }
end

function Helpers.parse_project_frame_timecode_seconds(normalized_timecode)
  if type(r.parse_timestr_pos) ~= "function" then
    return nil
  end
  local seconds = r.parse_timestr_pos(tostring(normalized_timecode or ""), 5)
  if type(seconds) ~= "number" then
    return nil
  end
  return seconds
end

function Helpers.format_project_frame_timecode_seconds(seconds)
  if type(seconds) ~= "number" or type(r.format_timestr_pos) ~= "function" then
    return ""
  end
  return Util.trim(tostring(r.format_timestr_pos(seconds, "", 5) or ""))
end

function Helpers.project_frame_timecode_roundtrip(normalized_timecode)
  local normalized = tostring(normalized_timecode or "")
  local seconds = Helpers.parse_project_frame_timecode_seconds(normalized)
  if seconds == nil then
    return nil, "", false
  end
  local formatted = Helpers.format_project_frame_timecode_seconds(seconds)
  return seconds, formatted, formatted == normalized
end

function Helpers.set_source_fps_input(text)
  local last = state.last_timecode
  local next_text = tostring(text or "")
  if last.source_fps_input == next_text then
    return
  end
  last.source_fps_input = next_text
  last.source_fps = nil
  Helpers.clear_timecode_validation(t("Source FPS changed. Revalidate to refresh issues."))
end

function Helpers.current_offset_timecode_text()
  local last = state.last_timecode
  if last.offset_enabled ~= true then
    return "00:00:00:00"
  end
  return string.format(
    "%02d:%02d:00:00",
    normalize_timecode_offset_hours(last.offset_hours),
    normalize_timecode_offset_minutes(last.offset_minutes)
  )
end

function Helpers.refresh_offset_project_seconds()
  local last = state.last_timecode
  local offset_text = Helpers.current_offset_timecode_text()
  last.offset_timecode_text = offset_text
  if last.offset_enabled == true and type(r.parse_timestr_pos) == "function" then
    last.offset_project_seconds = r.parse_timestr_pos(offset_text, 5)
  else
    last.offset_project_seconds = 0
  end
  return last.offset_project_seconds
end

function Helpers.clear_fps_warning_state()
  local last = state.last_timecode
  last.fps_check_ran = false
  last.fps_warning_count = 0
  last.fps_warning_row_indices = {}
  last.selected_fps_warning_position = nil
  for i = 1, #(last.rows or {}) do
    local row = last.rows[i]
    row.fps_warning = false
    row.fps_warning_message = ""
  end
end

function Helpers.persist_timecode_offset_state()
  local last = state.last_timecode
  Helpers.persist_boolean(EXTSTATE.timecode_offset_enabled, last.offset_enabled == true)
  Helpers.persist_string(EXTSTATE.timecode_offset_direction, normalize_timecode_offset_direction(last.offset_direction))
  Helpers.persist_string(EXTSTATE.timecode_offset_hours, normalize_timecode_offset_hours(last.offset_hours))
  Helpers.persist_string(EXTSTATE.timecode_offset_minutes, normalize_timecode_offset_minutes(last.offset_minutes))
end

function Helpers.sync_timecode_offset_inputs()
  local last = state.last_timecode
  last.offset_hours = normalize_timecode_offset_hours(last.offset_hours)
  last.offset_minutes = normalize_timecode_offset_minutes(last.offset_minutes)
  last.offset_direction = normalize_timecode_offset_direction(last.offset_direction)
  last.offset_hours_input = string.format("%02d", last.offset_hours)
  last.offset_minutes_input = string.format("%02d", last.offset_minutes)
  Helpers.refresh_offset_project_seconds()
end

function Helpers.apply_timecode_offset_change(message)
  Helpers.sync_timecode_offset_inputs()
  Helpers.persist_timecode_offset_state()
  Helpers.mark_dialogue_import_settings_changed()
  if message ~= nil and tostring(message) ~= "" then
    state.last_timecode.message = tostring(message)
  end
end

function Helpers.set_timecode_offset_enabled(enabled)
  local last = state.last_timecode
  last.offset_enabled = enabled == true
  Helpers.apply_timecode_offset_change(t("Offset changed. Run Preflight again."))
end

function Helpers.set_timecode_offset_direction(direction)
  local last = state.last_timecode
  last.offset_direction = normalize_timecode_offset_direction(direction)
  Helpers.apply_timecode_offset_change(t("Offset changed. Run Preflight again."))
end

function Helpers.set_timecode_offset_hours_from_input(text)
  local last = state.last_timecode
  last.offset_hours_input = tostring(text or "")
  local parsed = tonumber(last.offset_hours_input)
  if parsed ~= nil then
    last.offset_hours = normalize_timecode_offset_hours(parsed)
    last.offset_hours_input = string.format("%02d", last.offset_hours)
    Helpers.apply_timecode_offset_change(t("Offset changed. Run Preflight again."))
  end
end

function Helpers.set_timecode_offset_minutes_from_input(text)
  local last = state.last_timecode
  last.offset_minutes_input = tostring(text or "")
  local parsed = tonumber(last.offset_minutes_input)
  if parsed ~= nil then
    last.offset_minutes = normalize_timecode_offset_minutes(parsed)
    last.offset_minutes_input = string.format("%02d", last.offset_minutes)
    Helpers.apply_timecode_offset_change(t("Offset changed. Run Preflight again."))
  end
end

function Helpers.project_frame_rate_summary_text()
  local frame_rate, drop_frame = Helpers.refresh_project_timecode_context()
  local fps_text = (type(frame_rate) == "number") and string.format("%.3f", frame_rate) or t("(unknown)")
  local drop_frame_text = (drop_frame == true) and t("drop-frame") or t("non-drop-frame")
  return string.format(t("Project FPS: %s (%s)"), fps_text, drop_frame_text)
end

function Helpers.format_project_timecode(seconds)
  if type(seconds) ~= "number" or type(r.format_timestr_pos) ~= "function" then
    return t("(n/a)")
  end
  local formatted = tostring(r.format_timestr_pos(seconds, "", 5) or "")
  formatted = Util.trim(formatted)
  if formatted == "" then
    return t("(n/a)")
  end
  return formatted
end

function Helpers.timecode_offset_summary_text()
  local last = state.last_timecode
  Helpers.refresh_offset_project_seconds()
  if last.offset_enabled ~= true then
    return string.format(t("Offset: off (%s)"), tostring(last.offset_timecode_text or "00:00:00:00"))
  end
  local direction_text = Helpers.timecode_offset_direction_label(last.offset_direction)
  return string.format(
    t("Offset: %s %s (%.3fs)"),
    direction_text,
    tostring(last.offset_timecode_text or "00:00:00:00"),
    tonumber(last.offset_project_seconds) or 0
  )
end

function Helpers.timecode_offset_direction_label(value)
  if tostring(value or "") == "left" then
    return t("left")
  end
  return t("right")
end

function Helpers.dialogue_import_layout_label(layout_mode)
  local mode = normalize_dialogue_import_layout_mode(layout_mode or state.dialogue_import_layout_mode)
  if mode == "dedicated_tracks" then
    return t("Path B: one dialogue track per character")
  end
  return t("Path A: one shared dialogue track")
end

function Helpers.mark_dialogue_import_settings_changed()
  local last = state.last_dialogue_import
  if last.preflight_has_run == true then
    last.preflight_is_stale = true
    last.preflight_message = t("Import settings changed. Run Preflight again.")
  end
  last.last_apply_ok = nil
  last.last_apply_message = ""
  last.last_apply_report = nil
end

function Helpers.dialogue_import_has_fresh_preflight()
  local last = state.last_dialogue_import
  local report = last.preflight_report or {}
  return last.preflight_has_run == true and
    last.preflight_is_stale ~= true and
    last.preflight_ok == true and
    #(report.blockers or {}) == 0
end

function Helpers.set_dialogue_import_layout_mode(layout_mode)
  state.dialogue_import_layout_mode = normalize_dialogue_import_layout_mode(layout_mode)
  Helpers.persist_string(EXTSTATE.dialogue_import_layout_mode, state.dialogue_import_layout_mode)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_single_track_name(value)
  state.dialogue_import_single_track_name = normalize_dialogue_import_single_track_name(value)
  Helpers.persist_string(EXTSTATE.dialogue_import_single_track_name, state.dialogue_import_single_track_name)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_reuse_existing_tracks(enabled)
  state.dialogue_import_reuse_existing_tracks = enabled == true
  Helpers.persist_boolean(EXTSTATE.dialogue_import_reuse_existing_tracks, state.dialogue_import_reuse_existing_tracks)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_apply_color_policy(enabled)
  state.dialogue_import_apply_color_policy = enabled == true
  Helpers.persist_boolean(EXTSTATE.dialogue_import_apply_color_policy, state.dialogue_import_apply_color_policy)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_prepend_character_name(enabled)
  state.dialogue_import_prepend_character_name = enabled == true
  Helpers.persist_boolean(EXTSTATE.dialogue_import_prepend_character_name, state.dialogue_import_prepend_character_name)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_create_rec_track(enabled)
  state.dialogue_import_create_rec_track = enabled == true
  Helpers.persist_boolean(EXTSTATE.dialogue_import_create_rec_track, state.dialogue_import_create_rec_track)
  if state.dialogue_import_create_rec_track ~= true then
    Helpers.set_dialogue_import_alt_take_track_count(DIALOGUE_IMPORT_DEFAULTS.alt_take_track_count)
    return
  end
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_alt_take_track_count(value)
  local normalized = normalize_dialogue_import_alt_take_count(value)
  state.dialogue_import_alt_take_track_count = normalized
  state.dialogue_import_alt_take_track_count_input = tostring(normalized)
  Helpers.persist_string(EXTSTATE.dialogue_import_alt_take_track_count, state.dialogue_import_alt_take_track_count)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.dialogue_import_folder_collapsed_state_label(value)
  local collapsed_state = normalize_dialogue_import_folder_collapsed_state(value or state.dialogue_import_folder_collapsed_state)
  if collapsed_state == "collapsed" then
    return t("collapsed")
  end
  if collapsed_state == "fully_collapsed" then
    return t("fully collapsed")
  end
  return t("normal")
end

function Helpers.set_dialogue_import_make_folders(enabled)
  state.dialogue_import_make_folders = enabled == true
  Helpers.persist_boolean(EXTSTATE.dialogue_import_make_folders, state.dialogue_import_make_folders)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_folder_collapsed_state(value)
  state.dialogue_import_folder_collapsed_state = normalize_dialogue_import_folder_collapsed_state(value)
  Helpers.persist_string(EXTSTATE.dialogue_import_folder_collapsed_state, state.dialogue_import_folder_collapsed_state)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_length_mode(value)
  state.dialogue_import_length_mode = normalize_dialogue_import_length_mode(value)
  Helpers.persist_string(EXTSTATE.dialogue_import_length_mode, state.dialogue_import_length_mode)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_fixed_length_seconds(value)
  state.dialogue_import_fixed_length_seconds = normalize_dialogue_import_fixed_length_seconds(value)
  Helpers.persist_string(
    EXTSTATE.dialogue_import_fixed_length_seconds,
    string.format("%.3f", state.dialogue_import_fixed_length_seconds)
  )
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_chars_per_second(value)
  state.dialogue_import_chars_per_second = normalize_dialogue_import_chars_per_second(value)
  Helpers.persist_string(
    EXTSTATE.dialogue_import_chars_per_second,
    string.format("%.3f", state.dialogue_import_chars_per_second)
  )
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_min_item_length_seconds(value)
  state.dialogue_import_min_item_length_seconds = normalize_dialogue_import_min_item_length_seconds(value)
  Helpers.persist_string(
    EXTSTATE.dialogue_import_min_item_length_seconds,
    string.format("%.3f", state.dialogue_import_min_item_length_seconds)
  )
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_too_close_seconds(value)
  state.dialogue_import_too_close_seconds = normalize_dialogue_import_too_close_seconds(value)
  Helpers.persist_string(
    EXTSTATE.dialogue_import_too_close_seconds,
    string.format("%.3f", state.dialogue_import_too_close_seconds)
  )
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.dialogue_import_overlap_policy_label(value)
  local policy = normalize_dialogue_import_overlap_policy(value or state.dialogue_import_overlap_policy)
  if policy == "shrink_to_fit_best_effort" then
    return t("Shrink to fit")
  end
  return t("Allow overlaps")
end

function Helpers.dialogue_import_length_mode_label(value)
  if Helpers.use_end_timecodes_enabled() then
    return t("Source end timecodes")
  end
  if normalize_dialogue_import_length_mode(value or state.dialogue_import_length_mode) == "chars_per_second" then
    return t("Chars per second")
  end
  return t("Fixed length")
end

function Helpers.set_dialogue_import_overlap_policy(value)
  state.dialogue_import_overlap_policy = normalize_dialogue_import_overlap_policy(value)
  Helpers.persist_string(EXTSTATE.dialogue_import_overlap_policy, state.dialogue_import_overlap_policy)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.set_dialogue_import_add_warning_markers(enabled)
  state.dialogue_import_add_warning_markers = enabled == true
  Helpers.persist_boolean(EXTSTATE.dialogue_import_add_warning_markers, state.dialogue_import_add_warning_markers)
  Helpers.mark_dialogue_import_settings_changed()
end

function Helpers.build_dialogue_import_settings()
  local layout_mode = normalize_dialogue_import_layout_mode(state.dialogue_import_layout_mode)
  local dedicated_mode = layout_mode == "dedicated_tracks"
  local create_rec_track = dedicated_mode and state.dialogue_import_create_rec_track == true
  local make_folders = create_rec_track and state.dialogue_import_make_folders == true
  Helpers.refresh_offset_project_seconds()
  return {
    layout_mode = layout_mode,
    single_track_name = normalize_dialogue_import_single_track_name(state.dialogue_import_single_track_name),
    reuse_existing_tracks = dedicated_mode and state.dialogue_import_reuse_existing_tracks == true or false,
    apply_color_policy = dedicated_mode and state.dialogue_import_apply_color_policy == true or false,
    prepend_character_name = layout_mode == "single_track" and state.dialogue_import_prepend_character_name == true or false,
    create_rec_track = create_rec_track,
    alt_take_track_count = create_rec_track and normalize_dialogue_import_alt_take_count(state.dialogue_import_alt_take_track_count) or 0,
    make_folders = make_folders,
    folder_collapsed_state = make_folders
      and normalize_dialogue_import_folder_collapsed_state(state.dialogue_import_folder_collapsed_state)
      or DIALOGUE_IMPORT_DEFAULTS.folder_collapsed_state,
    use_source_end_timecodes = Helpers.use_end_timecodes_enabled(),
    length_mode = normalize_dialogue_import_length_mode(state.dialogue_import_length_mode),
    fixed_length_seconds = normalize_dialogue_import_fixed_length_seconds(state.dialogue_import_fixed_length_seconds),
    chars_per_second = normalize_dialogue_import_chars_per_second(state.dialogue_import_chars_per_second),
    too_short_seconds = normalize_dialogue_import_min_item_length_seconds(state.dialogue_import_min_item_length_seconds),
    too_close_seconds = normalize_dialogue_import_too_close_seconds(state.dialogue_import_too_close_seconds),
    overlap_policy = normalize_dialogue_import_overlap_policy(state.dialogue_import_overlap_policy),
    add_warning_markers = state.dialogue_import_add_warning_markers == true,
    offset_enabled = state.last_timecode.offset_enabled == true,
    offset_direction = normalize_timecode_offset_direction(state.last_timecode.offset_direction),
    offset_hours = normalize_timecode_offset_hours(state.last_timecode.offset_hours),
    offset_minutes = normalize_timecode_offset_minutes(state.last_timecode.offset_minutes),
    offset_seconds = tonumber(state.last_timecode.offset_project_seconds) or 0
  }
end

function Helpers.dialogue_import_preflight_summary_text(report)
  local summary = report and report.summary or {}
  return string.format(
    t("Ready: rows %d, items %d, tracks create/reuse %d/%d, markers %d"),
    tonumber(summary.row_count) or 0,
    tonumber(summary.item_count) or 0,
    tonumber(summary.create_track_count) or 0,
    tonumber(summary.reuse_track_count) or 0,
    tonumber(summary.marker_count) or 0
  )
end

function Helpers.run_dialogue_import_preflight_once()
  local rows = state.import_ready_rows or {}
  local settings = Helpers.build_dialogue_import_settings()
  local ok, report = ReaperX_import_Dialogue.preflight_import(rows, settings)
  local last = state.last_dialogue_import
  last.preflight_has_run = true
  last.preflight_is_stale = false
  last.preflight_ok = ok == true
  last.preflight_report = report
  last.last_apply_ok = nil
  last.last_apply_message = ""
  last.last_apply_report = nil

  if ok == true then
    last.preflight_message = Helpers.dialogue_import_preflight_summary_text(report)
  else
    local blockers = report and report.blockers or {}
    last.preflight_message = tostring(blockers[1] or t("Import preflight failed."))
  end

  return ok == true, last.preflight_message, report
end

function Helpers.apply_dialogue_import_once()
  local rows = state.import_ready_rows or {}
  local settings = Helpers.build_dialogue_import_settings()
  local ok, message, report = ReaperX_import_Dialogue.apply_import(rows, settings)
  local last = state.last_dialogue_import
  last.preflight_has_run = true
  last.preflight_is_stale = false
  last.preflight_ok = report ~= nil and #(report.blockers or {}) == 0
  last.preflight_report = report
  last.preflight_message = report and Helpers.dialogue_import_preflight_summary_text(report) or ""
  last.last_apply_ok = ok == true
  last.last_apply_message = tostring(message or "")
  last.last_apply_report = report
  return ok == true, last.last_apply_message, report
end

function Helpers.refresh_import_ready_rows()
  Helpers.reset_dialogue_import_runtime()
  local last = state.last_timecode
  if last.finalized == true and #(last.rows or {}) > 0 then
    state.import_ready_rows = Helpers.copy_import_ready_rows(last.rows)
    return
  end

  local script_rows = {}
  local source_row_numbers = {}
  if state.last_cast.ok == true then
    script_rows = (state.last_cast.base_cast and state.last_cast.base_cast.script_rows) or {}
    source_row_numbers = (state.last_cast.base_cast and state.last_cast.base_cast.source_row_numbers) or {}
  else
    script_rows, source_row_numbers = Helpers.build_mapped_script_rows()
  end

  local row_links = state.last_cast.ok == true and Helpers.visible_row_links() or {}
  local import_rows = {}
  for row_index = 1, #(script_rows or {}) do
    local row = script_rows[row_index] or {}
    local row_link = row_links[row_index] or {}
    local source_row_index = tonumber(source_row_numbers[row_index]) or row_index
    import_rows[#import_rows + 1] = {
      row_index = row_index,
      row_key = "src:" .. tostring(source_row_index),
      base_row_index = row_index,
      segment_index = 1,
      source_row_index = source_row_index,
      original_timecode = tostring(row.timecode or ""),
      raw_timecode_text = tostring(row.timecode or ""),
      original_end_timecode = tostring(row.end_timecode or ""),
      raw_end_timecode_text = tostring(row.end_timecode or ""),
      raw_character_name = tostring(row.character_name or ""),
      canonical_name = tostring(row_link.canonical_name or row.character_name or ""),
      canonical_id = row_link.resolved_character_id,
      resolved_group = tostring(row_link.resolved_group or ""),
      dialogue = tostring(row.character_line or ""),
      extracted_from_inline = false,
      status = "",
      validation_message = "",
      normalized_timecode = nil,
      normalized_end_timecode = nil,
      parser_seconds = nil,
      end_parser_seconds = nil,
      project_source_seconds = nil,
      end_project_source_seconds = nil,
      raw_seconds = nil,
      end_raw_seconds = nil,
      effective_timecode_text = "",
      effective_end_timecode_text = "",
      fps_warning_message = "",
      fps_warning = false
    }
  end
  state.import_ready_rows = import_rows
end

function Helpers.multiline_display_line_count(text)
  local value = tostring(text or "")
  local count = 1
  for _ in value:gmatch("\n") do
    count = count + 1
  end
  return count
end

function Helpers.multiline_display_height(text)
  local line_count = Helpers.multiline_display_line_count(text)
  local line_height = ImGui.GetTextLineHeightWithSpacing and ImGui.GetTextLineHeightWithSpacing(ctx) or 20
  return math.max(line_height + 8, (line_count * line_height) + 8)
end

function Helpers.reset_extract_state()
  state.last_extract = make_empty_extract_result()
end

function Helpers.reset_parse_state()
  state.last_parse = make_empty_parse_result()
end

function Helpers.reset_preflight_state()
  state.last_preflight = make_empty_preflight_result()
end

function Helpers.reset_cast_state()
  state.last_cast = make_empty_cast_result()
  state.last_cast.empty_character_name_mode = state.empty_character_name_mode
  state.last_cast.maximum_allowed_typo_distance = state.maximum_allowed_typo_distance
end

function Helpers.reset_dialogue_import_runtime()
  state.last_dialogue_import = make_empty_dialogue_import_runtime()
end

-- Timecode stage owns draft/raw edits, inline extraction state, validation
-- results, and Final Look output. Only user preferences survive a back step.
function Helpers.capture_timecode_preferences()
  local last = state.last_timecode or {}
  return {
    selected_format_id = last.selected_format_id,
    source_fps_input = tostring(last.source_fps_input or ""),
    offset_enabled = last.offset_enabled == true,
    offset_direction = normalize_timecode_offset_direction(last.offset_direction),
    offset_hours = normalize_timecode_offset_hours(last.offset_hours),
    offset_minutes = normalize_timecode_offset_minutes(last.offset_minutes)
  }
end

function Helpers.restore_timecode_preferences(preferences)
  local last = state.last_timecode
  local source = preferences or {}
  local selected_format_id = source.selected_format_id
  if Helpers.find_timecode_format_by_id and Helpers.find_timecode_format_by_id(selected_format_id) == nil then
    selected_format_id = default_timecode_format_id()
  end

  last.selected_format_id = selected_format_id or default_timecode_format_id()
  last.source_fps_input = tostring(source.source_fps_input or "")
  last.source_fps = nil
  last.offset_enabled = source.offset_enabled == true
  last.offset_direction = normalize_timecode_offset_direction(source.offset_direction)
  last.offset_hours = normalize_timecode_offset_hours(source.offset_hours)
  last.offset_minutes = normalize_timecode_offset_minutes(source.offset_minutes)
  Helpers.sync_timecode_offset_inputs()
  Helpers.refresh_project_timecode_context()
end

function Helpers.reset_timecode_stage()
  state.last_timecode = make_empty_timecode_result()
  state.telemetry_edited_rows = {}
  Helpers.sync_timecode_offset_inputs()
  Helpers.refresh_project_timecode_context()
end

function Helpers.reset_timecode_stage_preserve_preferences()
  local preferences = Helpers.capture_timecode_preferences()
  state.last_timecode = make_empty_timecode_result()
  state.telemetry_edited_rows = {}
  Helpers.restore_timecode_preferences(preferences)
end

function Helpers.invalidate_cast_state(reason)
  local had_cast_state =
    state.last_cast.ok ~= nil or
    #(state.last_cast.base_cast and state.last_cast.base_cast.script_rows or {}) > 0 or
    #(state.last_cast.applied_merges or {}) > 0

  Helpers.reset_cast_state()
  Helpers.reset_timecode_stage_preserve_preferences()
  Helpers.reset_dialogue_import_runtime()
  if had_cast_state and reason and reason ~= "" then
    Helpers.log_step("cast_invalidate", reason)
  end
end

function Helpers.reset_all_results()
  Helpers.reset_extract_state()
  Helpers.reset_parse_state()
  Helpers.reset_preflight_state()
  Helpers.reset_cast_state()
  Helpers.reset_timecode_stage()
  Helpers.reset_dialogue_import_runtime()
  state.import_ready_rows = {}
  state.telemetry_edited_rows = {}
end

function Helpers.reset_after_docx_or_output_change()
  Helpers.reset_all_results()
end

function TelemetryBridge.now()
  if type(r.time_precise) == "function" then
    return r.time_precise()
  end
  return os.clock()
end

function TelemetryBridge.duration_ms(started_at)
  local started = tonumber(started_at)
  if not started then return nil end
  return math.max(0, math.floor((TelemetryBridge.now() - started) * 1000 + 0.5))
end

function TelemetryBridge.error_code_unless(ok, code)
  if ok then return nil end
  return tostring(code or "")
end

function TelemetryBridge.safe_string(value, limit)
  local text = tostring(value or "")
  local max_len = tonumber(limit) or 1200
  if #text <= max_len then return text end
  return text:sub(1, max_len) .. "... (" .. tostring(#text - max_len) .. " more bytes)"
end

function TelemetryBridge.basic_field_allowed(key, value)
  local name = tostring(key or "")
  if name == "operation" or name == "status" or name == "duration_ms" or name == "error_code" then return true end
  if name == "script_version" or name == "close_reason" or name == "telemetry_level" then return true end
  if name == "ok" or name == "passed" or name == "mode" or name == "source_mode" or name == "new_source_mode" then return true end
  if name == "old_source_mode" or name == "use_end_timecodes" or name == "source_operation" then return true end
  if name == "selection_method" then return true end
  if name:match("_count$") or name:match("_seconds$") or name:match("_ms$") or name:match("_sec$") then return true end
  if type(value) == "number" or type(value) == "boolean" then return true end
  return false
end

function TelemetryBridge.basename(path)
  local text = tostring(path or "")
  return text:match("([^/\\]+)$") or text
end

function TelemetryBridge.effective_level()
  local ok_level, level_or_err = pcall(Telemetry.effective_level)
  if ok_level then
    return tostring(level_or_err or "support")
  end
  return "support"
end

function TelemetryBridge.content_allowed()
  local level = TelemetryBridge.effective_level()
  return level == "support" or level == "debug"
end

function TelemetryBridge.project_name()
  if type(r.GetProjectName) ~= "function" then return "" end
  local ok_name, name = pcall(r.GetProjectName, 0)
  if ok_name then return tostring(name or "") end
  return ""
end

function TelemetryBridge.current_timecode_format_label()
  local item = Helpers.ensure_selected_timecode_format and Helpers.ensure_selected_timecode_format() or nil
  if type(item) ~= "table" then return "" end
  return Helpers.timecode_format_label and Helpers.timecode_format_label(item) or tostring(item.id or "")
end

function TelemetryBridge.settings_payload()
  local preflight = state.last_preflight or {}
  local timecode = state.last_timecode or {}
  local import_settings = Helpers.build_dialogue_import_settings and Helpers.build_dialogue_import_settings() or {}
  return {
    source_mode = normalize_docx_source_mode(state.docx_source_mode),
    header_enabled = state.header_enabled == true,
    use_header_names = state.use_header_names == true,
    mapping = {
      selected_timecode_col = tonumber(preflight.selected_timecode_col) or nil,
      selected_character_name_col = tonumber(preflight.selected_character_name_col) or nil,
      selected_dialogue_col = tonumber(preflight.selected_dialogue_col) or nil,
      confirmed = preflight.confirmed == true,
      use_end_timecodes = Helpers.use_end_timecodes_enabled and Helpers.use_end_timecodes_enabled() or false
    },
    cast = {
      empty_character_name_mode = tonumber(state.empty_character_name_mode) or nil,
      maximum_allowed_typo_distance = tonumber(state.maximum_allowed_typo_distance) or nil
    },
    timecode = {
      selected_format_id = timecode.selected_format_id,
      selected_format_label = TelemetryBridge.current_timecode_format_label(),
      extraction_active = timecode.extraction_active == true,
      extracted_inline_count = tonumber(timecode.extracted_inline_count) or 0,
      finalized = timecode.finalized == true,
      validated = timecode.has_validated == true,
      final_look_applied = timecode.final_look_applied == true,
      project_frame_rate = tonumber(timecode.project_frame_rate) or nil,
      project_drop_frame = timecode.project_drop_frame == true
    },
    offset = {
      enabled = timecode.offset_enabled == true,
      direction = normalize_timecode_offset_direction(timecode.offset_direction),
      hours = normalize_timecode_offset_hours(timecode.offset_hours),
      minutes = normalize_timecode_offset_minutes(timecode.offset_minutes),
      seconds = tonumber(timecode.offset_project_seconds) or 0,
      timecode_text = tostring(timecode.offset_timecode_text or "")
    },
    import = import_settings
  }
end

function TelemetryBridge.import_summary(report)
  local src = report or (state.last_dialogue_import and state.last_dialogue_import.preflight_report) or nil
  local summary = src and src.summary or {}
  local blockers = src and src.blockers or {}
  local warnings = src and src.warnings or {}
  return {
    preflight_has_run = state.last_dialogue_import and state.last_dialogue_import.preflight_has_run == true or false,
    preflight_is_stale = state.last_dialogue_import and state.last_dialogue_import.preflight_is_stale == true or false,
    preflight_ok = state.last_dialogue_import and state.last_dialogue_import.preflight_ok == true or false,
    last_apply_ok = state.last_dialogue_import and state.last_dialogue_import.last_apply_ok == true or false,
    row_count = tonumber(summary.row_count) or 0,
    item_count = tonumber(summary.item_count) or 0,
    marker_count = tonumber(summary.marker_count) or 0,
    create_track_count = tonumber(summary.create_track_count) or 0,
    reuse_track_count = tonumber(summary.reuse_track_count) or 0,
    existing_items_in_span_count = tonumber(summary.existing_items_in_span_count) or 0,
    blocker_count = #blockers,
    warning_count = #warnings
  }
end

function TelemetryBridge.counts_payload(report)
  local parse = state.last_parse or {}
  local preflight = state.last_preflight or {}
  local cast = state.last_cast or {}
  local cast_base = cast.base_cast or {}
  local cast_view = cast.merged_view or {}
  local timecode = state.last_timecode or {}
  return {
    warnings_count = #(state.warnings or {}),
    rolling_log_count = #(state.rolling_log_lines or {}),
    import_ready_rows = #(state.import_ready_rows or {}),
    parse = {
      ok = parse.ok == true,
      columns = tonumber(parse.number_of_columns) or 0,
      rows = tonumber(parse.number_of_rows) or 0,
      warning_count = tonumber(parse.warning_count) or 0,
      empty_character_row_count = tonumber(parse.empty_character_row_count) or 0,
      end_timecode_count = tonumber(parse.end_timecode_count) or 0,
      source_mode_requested = tostring(parse.source_mode_requested or ""),
      source_mode_detected = tostring(parse.source_mode_detected or "")
    },
    mapping = {
      ok = preflight.ok == true,
      confirmed = preflight.confirmed == true,
      mapped_row_count = tonumber(preflight.mapped_row_count) or 0,
      end_timecode_count = tonumber(preflight.end_timecode_count) or 0,
      end_timecode_complete = preflight.end_timecode_complete == true
    },
    cast = {
      ok = cast.ok == true,
      base_character_count = tonumber(cast_base.character_count) or 0,
      base_merge_candidate_count = tonumber(cast_base.merge_candidate_count) or 0,
      character_count = tonumber(cast_view.character_count) or 0,
      merge_candidate_count = tonumber(cast_view.merge_candidate_count) or 0,
      applied_merge_count = #(cast.applied_merges or {})
    },
    timecode = {
      finalized = timecode.finalized == true,
      validated = timecode.has_validated == true,
      final_look_applied = timecode.final_look_applied == true,
      total_count = tonumber(timecode.total_count) or 0,
      ok_count = tonumber(timecode.ok_count) or 0,
      bad_count = tonumber(timecode.bad_count) or 0,
      inconsistent_count = tonumber(timecode.inconsistent_count) or 0,
      fps_warning_count = tonumber(timecode.fps_warning_count) or 0,
      extracted_inline_count = tonumber(timecode.extracted_inline_count) or 0
    },
    import = TelemetryBridge.import_summary(report)
  }
end

function TelemetryBridge.paths_payload()
  local desc = TelemetryBridge.describe_status()
  local telemetry_paths = desc.paths or {}
  return {
    docx_path = tostring(state.docx_path or ""),
    docx_basename = TelemetryBridge.basename(state.docx_path),
    project_path = tostring(runtime.project_path or ""),
    project_name = TelemetryBridge.project_name(),
    output_root = tostring(state.output_root or ""),
    extract_output_dir = tostring(state.last_extract and state.last_extract.output_dir or ""),
    extract_xml_path = tostring(state.last_extract and state.last_extract.xml_path or ""),
    base_root = tostring(runtime.base_root or ""),
    log_root = tostring(runtime.log_root or ""),
    internal_root = tostring(runtime.internal_root or ""),
    telemetry_tmp_dir = tostring(CFG.tmp_dir or ""),
    telemetry_settings_path = tostring(desc.settings_path or ""),
    telemetry_queue_path = tostring(desc.queue_path or ""),
    telemetry_root = tostring(telemetry_paths.root or ""),
    telemetry_queues_dir = tostring(telemetry_paths.queues or ""),
    telemetry_sending_dir = tostring(telemetry_paths.sending or ""),
    telemetry_failed_dir = tostring(telemetry_paths.failed or ""),
    telemetry_logs_dir = tostring(telemetry_paths.logs or ""),
    telemetry_close_send_dir = tostring(telemetry_paths.close_send or "")
  }
end

function TelemetryBridge.recent_log_lines(limit)
  local max_count = tonumber(limit) or 40
  local src = state.rolling_log_lines or {}
  local first = math.max(1, #src - max_count + 1)
  local out = {}
  for i = first, #src do
    out[#out + 1] = TelemetryBridge.safe_string(src[i], 1000)
  end
  return out
end

function TelemetryBridge.warning_lines()
  local out = {}
  for i = 1, #(state.warnings or {}) do
    out[#out + 1] = TelemetryBridge.safe_string(state.warnings[i], 1200)
  end
  return out
end

function TelemetryBridge.report_messages(report)
  if not TelemetryBridge.content_allowed() then return nil end
  local src = report or (state.last_dialogue_import and state.last_dialogue_import.preflight_report) or {}
  local blockers = {}
  local warnings = {}
  for i = 1, #(src.blockers or {}) do
    blockers[#blockers + 1] = TelemetryBridge.safe_string(src.blockers[i], 1200)
  end
  for i = 1, #(src.warnings or {}) do
    warnings[#warnings + 1] = TelemetryBridge.safe_string(src.warnings[i], 1200)
  end
  return {
    blockers = blockers,
    warnings = warnings
  }
end

function TelemetryBridge.base_payload(data, opts)
  local options = opts or {}
  local content_ok = TelemetryBridge.content_allowed()
  local out = {
    project_name = TelemetryBridge.project_name(),
    docx_basename = TelemetryBridge.basename(state.docx_path),
    workflow_status = Helpers.workflow_status_text and Helpers.workflow_status_text() or "",
    settings = TelemetryBridge.settings_payload(),
    counts = TelemetryBridge.counts_payload(options.report),
    telemetry_effective_level = TelemetryBridge.effective_level()
  }
  if type(data) == "table" then
    for k, v in pairs(data) do
      if content_ok or TelemetryBridge.basic_field_allowed(k, v) then
        out[k] = v
      end
    end
  end
  if content_ok then
    out.status_text = tostring(state.status_text or "")
    out.technical_status_text = TelemetryBridge.safe_string(state.technical_status_text, 1000)
    out.paths = TelemetryBridge.paths_payload()
    if options.include_messages ~= false then
      out.warnings = TelemetryBridge.warning_lines()
      out.import_messages = TelemetryBridge.report_messages(options.report)
    end
    if options.include_log == true then
      out.recent_log_lines = TelemetryBridge.recent_log_lines(options.log_limit or 40)
    end
  end
  return out
end

function TelemetryBridge.safe_event(event_name, data, opts)
  local ok_event, event_or_err = Telemetry.safe_event(event_name, data, opts or {})
  if ok_event then
    return true, event_or_err
  end
  state.telemetry_ui_status = string.format(t("Telemetry event failed: %s"), tostring(event_or_err))
  Util.msg(state.telemetry_ui_status, 2)
  return false, event_or_err
end

function TelemetryBridge.emit_operation_event(event_name, operation, status, data, opts)
  local options = opts or {}
  local payload = TelemetryBridge.base_payload(data, {
    include_log = options.include_log == true,
    log_limit = options.log_limit,
    report = options.report
  })
  payload.operation = tostring(operation or "")
  payload.status = tostring(status or "")
  local event_opts = {
    operation = payload.operation,
    status = payload.status,
    duration_ms = payload.duration_ms,
    error_code = payload.error_code,
    policy = options.policy or "basic",
    priority = options.priority or (event_name == "operation_failed" and "error" or "normal"),
    event_level = options.event_level or (event_name == "operation_failed" and "error" or "info")
  }
  return TelemetryBridge.safe_event(event_name, payload, event_opts)
end

function TelemetryBridge.operation_started(operation, data)
  return TelemetryBridge.emit_operation_event("operation_started", operation, "started", data, {
    policy = "basic"
  })
end

function TelemetryBridge.operation_completed(operation, data, started_at, opts)
  local payload = data or {}
  if started_at then
    payload.duration_ms = payload.duration_ms or TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event("operation_completed", operation, "completed", payload, opts or {
    policy = "basic"
  })
end

function TelemetryBridge.operation_failed(operation, data, started_at, opts)
  local payload = data or {}
  if started_at then
    payload.duration_ms = payload.duration_ms or TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event("operation_failed", operation, "failed", payload, opts or {
    policy = "basic",
    priority = "error",
    event_level = "error",
    include_log = true
  })
end

function TelemetryBridge.operation_canceled(operation, data, started_at, opts)
  local payload = data or {}
  if started_at then
    payload.duration_ms = payload.duration_ms or TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event("operation_canceled", operation, "canceled", payload, opts or {
    policy = "basic"
  })
end

function TelemetryBridge.stage_finished(operation, ok, data, started_at, opts)
  local options = opts or {}
  local payload = data or {}
  if ok then
    TelemetryBridge.operation_completed(operation, payload, started_at, options)
  else
    options.include_log = options.include_log ~= false
    options.priority = options.priority or "error"
    options.event_level = options.event_level or "error"
    TelemetryBridge.operation_failed(operation, payload, started_at, options)
  end
  TelemetryBridge.emit_support_rows_snapshot(operation, {
    report = options.report,
    include_log = options.include_log == true,
    reason = ok and "stage_completed" or "stage_failed"
  })
end

function TelemetryBridge.mark_index(selected, index, count, reason, detail)
  local idx = tonumber(index)
  local total = tonumber(count) or 0
  if not idx or idx < 1 or total < 1 then return end
  for offset = -1, 1 do
    local pos = idx + offset
    if pos >= 1 and pos <= total then
      local kind = offset == 0 and tostring(reason or "issue") or "neighbor"
      if selected[pos] == nil or selected[pos].reason == "sample" or selected[pos].reason == "neighbor" then
        selected[pos] = {
          reason = kind,
          detail = offset == 0 and tostring(detail or "") or tostring(reason or "issue")
        }
      end
    end
  end
end

function TelemetryBridge.mark_sample_indices(selected, count)
  local total = tonumber(count) or 0
  if total < 1 then return end
  selected[1] = selected[1] or { reason = "sample", detail = "first" }
  if total > 1 then
    selected[total] = selected[total] or { reason = "sample", detail = "last" }
  end
end

function TelemetryBridge.sorted_indices(map)
  local out = {}
  for idx in pairs(map or {}) do
    out[#out + 1] = tonumber(idx) or idx
  end
  table.sort(out, function(a, b) return tonumber(a) < tonumber(b) end)
  return out
end

function TelemetryBridge.parser_warning_row_indices()
  local selected = {}
  for i = 1, #(state.last_parse.warnings or {}) do
    local warning = tostring(state.last_parse.warnings[i] or "")
    local row_num = warning:match("[Rr]ow%s+(%d+)") or warning:match("[Rr]ow%s*#(%d+)")
    if row_num then
      TelemetryBridge.mark_index(selected, tonumber(row_num), #(state.last_parse.rows or {}), "parser_warning", warning)
    end
  end
  local metadata = state.last_parse.row_metadata_by_index or {}
  for idx = 1, #(state.last_parse.rows or {}) do
    local meta = metadata[idx] or {}
    if meta.empty_character_detected == true then
      TelemetryBridge.mark_index(selected, idx, #(state.last_parse.rows or {}), "empty_character", meta.empty_character_reason or "")
    end
  end
  return selected
end

function TelemetryBridge.parsed_row_payload(index, reason)
  local row = (state.last_parse.rows or {})[index] or {}
  local meta = (state.last_parse.row_metadata_by_index or {})[index] or {}
  return {
    source = "parsed",
    row_ref = "parsed:" .. tostring(index),
    source_row_index = index,
    issue_kind = reason and reason.reason or "",
    issue_detail = TelemetryBridge.safe_string(reason and reason.detail or "", 900),
    timecode = TelemetryBridge.safe_string(row[1], 500),
    character_name = TelemetryBridge.safe_string(row[2], 500),
    dialogue = TelemetryBridge.safe_string(row[3], 1200),
    end_timecode = TelemetryBridge.safe_string(meta.end_timecode or "", 500),
    empty_character_detected = meta.empty_character_detected == true,
    source_mode_detected = tostring(state.last_parse.source_mode_detected or "")
  }
end

function TelemetryBridge.mapped_row_payload(index, reason)
  local row = (state.last_preflight.visible_rows or {})[index] or {}
  local meta = (state.last_preflight.visible_row_metadata or {})[index] or {}
  local mapping = state.last_preflight.confirmed_mapping or {
    timecode_col = state.last_preflight.selected_timecode_col,
    character_name_col = state.last_preflight.selected_character_name_col,
    dialogue_col = state.last_preflight.selected_dialogue_col,
    use_end_timecodes = Helpers.use_end_timecodes_enabled and Helpers.use_end_timecodes_enabled() or false
  }
  local source_row_index = tonumber(meta.raw_row_index) or index
  local row_link = (state.last_cast.merged_view and state.last_cast.merged_view.row_links or {})[index] or {}
  return {
    source = "mapped",
    row_ref = "mapped:" .. tostring(source_row_index),
    source_row_index = source_row_index,
    input_index = index,
    issue_kind = reason and reason.reason or "",
    issue_detail = TelemetryBridge.safe_string(reason and reason.detail or "", 900),
    timecode = TelemetryBridge.safe_string(row[mapping.timecode_col], 500),
    end_timecode = TelemetryBridge.safe_string(Helpers.end_timecode_from_visible_metadata(meta), 500),
    character_name = TelemetryBridge.safe_string(row[mapping.character_name_col], 500),
    dialogue = TelemetryBridge.safe_string(row[mapping.dialogue_col], 1200),
    canonical_name = TelemetryBridge.safe_string(row_link.canonical_name or "", 500),
    resolved_group = TelemetryBridge.safe_string(row_link.resolved_group or "", 200),
    ambiguous_match = row_link.ambiguous_match == true
  }
end

function TelemetryBridge.timecode_row_payload(index, reason)
  local row = (state.last_timecode.rows or {})[index] or {}
  local edit = state.telemetry_edited_rows and state.telemetry_edited_rows[tostring(row.row_key or row.source_row_index or index)] or nil
  return {
    source = "timecode",
    row_ref = tostring(row.row_key or ("timecode:" .. tostring(index))),
    source_row_index = row.source_row_index,
    input_index = index,
    base_row_index = row.base_row_index,
    segment_index = row.segment_index,
    issue_kind = reason and reason.reason or "",
    issue_detail = TelemetryBridge.safe_string(reason and reason.detail or "", 900),
    original_timecode = TelemetryBridge.safe_string(row.original_timecode, 500),
    raw_timecode_text = TelemetryBridge.safe_string(row.raw_timecode_text, 500),
    original_end_timecode = TelemetryBridge.safe_string(row.original_end_timecode, 500),
    raw_end_timecode_text = TelemetryBridge.safe_string(row.raw_end_timecode_text, 500),
    normalized_timecode = TelemetryBridge.safe_string(row.normalized_timecode, 500),
    normalized_end_timecode = TelemetryBridge.safe_string(row.normalized_end_timecode, 500),
    effective_timecode_text = TelemetryBridge.safe_string(row.effective_timecode_text, 500),
    effective_end_timecode_text = TelemetryBridge.safe_string(row.effective_end_timecode_text, 500),
    raw_character_name = TelemetryBridge.safe_string(row.raw_character_name, 500),
    canonical_name = TelemetryBridge.safe_string(row.canonical_name, 500),
    resolved_group = TelemetryBridge.safe_string(row.resolved_group, 200),
    dialogue = TelemetryBridge.safe_string(row.dialogue, 1200),
    status = tostring(row.status or ""),
    validation_message = TelemetryBridge.safe_string(row.validation_message, 900),
    fps_warning = row.fps_warning == true,
    fps_warning_message = TelemetryBridge.safe_string(row.fps_warning_message, 900),
    edited = edit ~= nil,
    edit_fields = edit and edit.fields or nil
  }
end

function TelemetryBridge.import_item_payload(index, reason, report)
  local item = (report and report.item_plan or {})[index] or {}
  return {
    source = "import_item",
    row_ref = tostring(item.row_key or ("item:" .. tostring(index))),
    source_row_index = item.source_row_index,
    input_index = item.input_index or index,
    issue_kind = reason and reason.reason or "",
    issue_detail = TelemetryBridge.safe_string(reason and reason.detail or "", 900),
    track_name = TelemetryBridge.safe_string(item.track_name, 700),
    character_name = TelemetryBridge.safe_string(item.character_name, 500),
    note_text = TelemetryBridge.safe_string(item.note_text, 1200),
    dialogue = TelemetryBridge.safe_string(item.dialogue, 1200),
    start_seconds = item.start_seconds,
    effective_end_seconds = item.effective_end_seconds,
    effective_length_seconds = item.effective_length_seconds,
    source_timecode = TelemetryBridge.safe_string(item.source_timecode, 500),
    source_end_timecode = TelemetryBridge.safe_string(item.source_end_timecode, 500),
    start_timecode = TelemetryBridge.safe_string(item.start_timecode, 500),
    end_timecode = TelemetryBridge.safe_string(item.end_timecode, 500),
    status = tostring(item.status or ""),
    validation_message = TelemetryBridge.safe_string(item.validation_message, 900),
    empty_dialogue = item.empty_dialogue == true,
    too_short = item.too_short == true,
    too_close = item.too_close == true,
    overlap_next = item.overlap_next == true,
    shrunk_to_fit = item.shrunk_to_fit == true,
    offset_was_clamped = item.offset_was_clamped == true
  }
end

function TelemetryBridge.collect_support_rows(report)
  local rows = {}

  local parsed_selected = TelemetryBridge.parser_warning_row_indices()
  TelemetryBridge.mark_sample_indices(parsed_selected, #(state.last_parse.rows or {}))
  for _, idx in ipairs(TelemetryBridge.sorted_indices(parsed_selected)) do
    rows[#rows + 1] = TelemetryBridge.parsed_row_payload(idx, parsed_selected[idx])
  end

  local mapped_selected = {}
  TelemetryBridge.mark_sample_indices(mapped_selected, #(state.last_preflight.visible_rows or {}))
  local row_links = state.last_cast.merged_view and state.last_cast.merged_view.row_links or {}
  for idx = 1, #row_links do
    local link = row_links[idx] or {}
    if link.ambiguous_match == true then
      TelemetryBridge.mark_index(mapped_selected, idx, #(state.last_preflight.visible_rows or {}), "ambiguous_cast_match", "")
    end
  end
  for _, idx in ipairs(TelemetryBridge.sorted_indices(mapped_selected)) do
    if (state.last_preflight.visible_rows or {})[idx] ~= nil then
      rows[#rows + 1] = TelemetryBridge.mapped_row_payload(idx, mapped_selected[idx])
    end
  end

  local timecode_selected = {}
  TelemetryBridge.mark_sample_indices(timecode_selected, #(state.last_timecode.rows or {}))
  for _, idx in ipairs(state.last_timecode.bad_issue_row_indices or {}) do
    local row = (state.last_timecode.rows or {})[idx] or {}
    TelemetryBridge.mark_index(timecode_selected, idx, #(state.last_timecode.rows or {}), "bad_timecode", row.validation_message or "")
  end
  for _, idx in ipairs(state.last_timecode.suspicious_issue_row_indices or {}) do
    local row = (state.last_timecode.rows or {})[idx] or {}
    TelemetryBridge.mark_index(timecode_selected, idx, #(state.last_timecode.rows or {}), "suspicious_timecode", row.validation_message or "")
  end
  for _, idx in ipairs(state.last_timecode.fps_warning_row_indices or {}) do
    local row = (state.last_timecode.rows or {})[idx] or {}
    TelemetryBridge.mark_index(timecode_selected, idx, #(state.last_timecode.rows or {}), "fps_warning", row.fps_warning_message or "")
  end
  for _, edit in pairs(state.telemetry_edited_rows or {}) do
    local idx = tonumber(edit.row_index)
    if idx ~= nil then
      TelemetryBridge.mark_index(timecode_selected, idx, #(state.last_timecode.rows or {}), "manual_edit", "")
    end
  end
  for _, idx in ipairs(TelemetryBridge.sorted_indices(timecode_selected)) do
    if (state.last_timecode.rows or {})[idx] ~= nil then
      rows[#rows + 1] = TelemetryBridge.timecode_row_payload(idx, timecode_selected[idx])
    end
  end

  if type(report) == "table" then
    local item_selected = {}
    TelemetryBridge.mark_sample_indices(item_selected, #(report.item_plan or {}))
    for idx = 1, #(report.item_plan or {}) do
      local item = report.item_plan[idx] or {}
      if item.empty_dialogue == true then
        TelemetryBridge.mark_index(item_selected, idx, #(report.item_plan or {}), "empty_dialogue", "")
      elseif item.too_short == true then
        TelemetryBridge.mark_index(item_selected, idx, #(report.item_plan or {}), "too_short", "")
      elseif item.too_close == true then
        TelemetryBridge.mark_index(item_selected, idx, #(report.item_plan or {}), "too_close", "")
      elseif item.overlap_next == true then
        TelemetryBridge.mark_index(item_selected, idx, #(report.item_plan or {}), "overlap", "")
      elseif item.shrunk_to_fit == true then
        TelemetryBridge.mark_index(item_selected, idx, #(report.item_plan or {}), "shrunk_to_fit", "")
      elseif item.offset_was_clamped == true then
        TelemetryBridge.mark_index(item_selected, idx, #(report.item_plan or {}), "offset_clamped", "")
      elseif tostring(item.status or "") == "bad" then
        TelemetryBridge.mark_index(item_selected, idx, #(report.item_plan or {}), "bad_status", item.validation_message or "")
      end
    end
    for _, idx in ipairs(TelemetryBridge.sorted_indices(item_selected)) do
      if (report.item_plan or {})[idx] ~= nil then
        rows[#rows + 1] = TelemetryBridge.import_item_payload(idx, item_selected[idx], report)
      end
    end
  end

  return rows
end

function TelemetryBridge.count_support_row_issues(rows)
  local count = 0
  for i = 1, #(rows or {}) do
    local kind = tostring(rows[i] and rows[i].issue_kind or "")
    if kind ~= "" and kind ~= "sample" and kind ~= "neighbor" then
      count = count + 1
    end
  end
  return count
end

function TelemetryBridge.support_snapshot_counts(rows, report)
  local parse = state.last_parse or {}
  local cast = state.last_cast or {}
  local timecode = state.last_timecode or {}
  local row_links = cast.merged_view and cast.merged_view.row_links or {}
  local ambiguous_count = 0
  for i = 1, #row_links do
    if row_links[i] and row_links[i].ambiguous_match == true then
      ambiguous_count = ambiguous_count + 1
    end
  end

  local edited_count = 0
  for _ in pairs(state.telemetry_edited_rows or {}) do
    edited_count = edited_count + 1
  end

  local empty_dialogue_count = 0
  local import_issue_count = 0
  if type(report) == "table" then
    for i = 1, #(report.item_plan or {}) do
      local item = report.item_plan[i] or {}
      if item.empty_dialogue == true then empty_dialogue_count = empty_dialogue_count + 1 end
      if item.empty_dialogue == true
        or item.too_short == true
        or item.too_close == true
        or item.overlap_next == true
        or item.shrunk_to_fit == true
        or item.offset_was_clamped == true
        or tostring(item.status or "") == "bad"
      then
        import_issue_count = import_issue_count + 1
      end
    end
  end

  return {
    support_row_candidate_count = #(rows or {}),
    support_issue_row_count = TelemetryBridge.count_support_row_issues(rows),
    parser_warning_count = tonumber(parse.warning_count) or 0,
    empty_character_row_count = tonumber(parse.empty_character_row_count) or 0,
    empty_dialogue_row_count = empty_dialogue_count,
    ambiguous_cast_row_count = ambiguous_count,
    bad_timecode_count = tonumber(timecode.bad_count) or #(timecode.bad_issue_row_indices or {}),
    suspicious_timecode_count = tonumber(timecode.inconsistent_count) or #(timecode.suspicious_issue_row_indices or {}),
    fps_warning_count = tonumber(timecode.fps_warning_count) or #(timecode.fps_warning_row_indices or {}),
    edited_row_count = edited_count,
    import_issue_count = import_issue_count,
    import_blocker_count = type(report) == "table" and #(report.blockers or {}) or 0,
    import_warning_count = type(report) == "table" and #(report.warnings or {}) or 0
  }
end

function TelemetryBridge.track_targets_payload(report)
  if not TelemetryBridge.content_allowed() then return nil end
  local targets = report and report.track_plan and report.track_plan.targets or {}
  local out = {}
  for i = 1, #targets do
    local target = targets[i] or {}
    out[#out + 1] = {
      index = i,
      role = tostring(target.role or ""),
      track_name = TelemetryBridge.safe_string(target.track_name, 700),
      action = tostring(target.action or ""),
      plan_ref = tostring(target.plan_key or ""),
      dialogue_track_name = TelemetryBridge.safe_string(target.dialogue_track_name, 700),
      alt_take_index = target.alt_take_index,
      has_existing_items_in_span = target.has_existing_items_in_span == true
    }
  end
  return out
end

function TelemetryBridge.import_report_payload(report)
  if type(report) ~= "table" then return nil end
  local summary = report.summary or {}
  local time_span = report.time_span or {}
  local payload = {
    summary = {
      row_count = tonumber(summary.row_count) or 0,
      item_count = tonumber(summary.item_count) or 0,
      marker_count = tonumber(summary.marker_count) or 0,
      create_track_count = tonumber(summary.create_track_count) or 0,
      reuse_track_count = tonumber(summary.reuse_track_count) or 0,
      existing_items_in_span_count = tonumber(summary.existing_items_in_span_count) or 0
    },
    time_span = {
      start_seconds = time_span.start_seconds,
      end_seconds = time_span.end_seconds
    },
    blocker_count = #(report.blockers or {}),
    warning_count = #(report.warnings or {})
  }
  if TelemetryBridge.content_allowed() then
    payload.time_span.start_timecode = TelemetryBridge.safe_string(time_span.start_timecode, 500)
    payload.time_span.end_timecode = TelemetryBridge.safe_string(time_span.end_timecode, 500)
    payload.track_targets = TelemetryBridge.track_targets_payload(report)
  end
  return payload
end

function TelemetryBridge.emit_support_rows_snapshot(stage, opts)
  if not TelemetryBridge.content_allowed() then
    return false, "content disabled"
  end
  local options = opts or {}
  local rows = TelemetryBridge.collect_support_rows(options.report)
  local counts = TelemetryBridge.support_snapshot_counts(rows, options.report)
  local issue_count = tonumber(counts.support_issue_row_count) or 0
  if #rows == 0 or (issue_count < 1 and tostring(options.reason or "") == "stage_completed") then
    return false, "no support rows"
  end
  local snapshot = DocxTelemetrySummary.build_support_snapshot(stage, rows, counts, {
    reason = options.reason,
    max_examples = 12
  })
  TelemetryBridge.safe_event("operation_completed", TelemetryBridge.base_payload({
    operation = "docx_support_rows_snapshot",
    status = "completed",
    source_operation = snapshot.source_operation,
    snapshot_reason = snapshot.snapshot_reason,
    row_count = snapshot.row_count,
    example_count = snapshot.example_count,
    max_examples = snapshot.max_examples,
    truncated = snapshot.truncated == true,
    counts = snapshot.counts,
    issue_kind_counts = snapshot.issue_kind_counts,
    rows = snapshot.rows
  }, {
    include_log = options.include_log == true,
    include_messages = false,
    report = options.report
  }), {
    operation = "docx_support_rows_snapshot",
    status = "completed",
    policy = "support",
    priority = "normal"
  })
  return true
end

function TelemetryBridge.note_timecode_edit(row_index, row, field_name, old_value, new_value)
  if type(row) ~= "table" then return end
  local ref = tostring(row.row_key or row.source_row_index or row_index)
  local rec = state.telemetry_edited_rows[ref]
  if type(rec) ~= "table" then
    rec = {
      row_ref = ref,
      row_index = row_index,
      source_row_index = row.source_row_index,
      fields = {}
    }
    state.telemetry_edited_rows[ref] = rec
  end
  rec.fields[tostring(field_name or "value")] = {
    old_value = TelemetryBridge.safe_string(old_value, 500),
    new_value = TelemetryBridge.safe_string(new_value, 500)
  }
end

function TelemetryBridge.button_clicked(button_id, label)
  return TelemetryBridge.safe_event("button_clicked", {
    operation = "docx_button",
    status = "clicked",
    button_id = tostring(button_id or ""),
    button_label = tostring(label or "")
  }, {
    operation = "docx_button",
    status = "clicked",
    policy = "basic",
    priority = "low"
  })
end

function TelemetryBridge.progress_text(desc)
  if type(desc) ~= "table" then return "" end
  return DocxTelemetrySummary.batch_progress_text(desc)
end

function TelemetryBridge.backlog_status_text(desc)
  return DocxTelemetrySummary.backlog_status_text(desc)
end

function TelemetryBridge.level_label(level)
  local text = tostring(level or "support")
  if text == "basic" then return t("Basic") end
  if text == "debug" then return t("Debug") end
  return t("Support")
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
    effective_level = "support",
    paths = {}
  }
end

function TelemetryBridge.header_state(desc)
  if type(desc) ~= "table" or desc.initialized ~= true then return t("unavailable") end
  if desc.send_paused == true then return t("paused") end
  if tostring(desc.last_error or "") ~= "" then return t("error") end
  if desc.active_job_id ~= nil then return t("sending") end
  if (tonumber(desc.sendable_queue_bytes) or 0) > 0 then return t("queued") end
  return t("ok")
end

function TelemetryBridge.status_ok(desc)
  return type(desc) == "table"
    and desc.initialized == true
    and desc.send_paused ~= true
    and tostring(desc.last_error or "") == ""
end

function TelemetryBridge.status_color(desc)
  if TelemetryBridge.status_ok(desc) then return 0x00C853FF end
  return 0xFF3030FF
end

function TelemetryBridge.safe_tick(now_t)
  local ok_tick, tick_or_err = Telemetry.safe_tick(now_t)
  if not ok_tick then
    state.telemetry_ui_status = string.format(t("Telemetry tick failed: %s"), tostring(tick_or_err))
    Util.msg(state.telemetry_ui_status, 2)
  end
  return ok_tick, tick_or_err
end

function TelemetryBridge.safe_flush_async(reason)
  local ok_flush, flush_or_err = Telemetry.safe_flush_async({
    reason = tostring(reason or "docx_manual"),
    timeout_sec = CFG.timeout_sec,
    connect_timeout_sec = CFG.curl_connect_timeout_sec,
    speed_limit = CFG.curl_speed_limit,
    speed_time = CFG.curl_speed_time
  })
  if ok_flush then
    state.telemetry_ui_status = t("Telemetry flush started.")
  else
    state.telemetry_ui_status = tostring(flush_or_err or "")
  end
  return ok_flush, flush_or_err
end

function TelemetryBridge.set_level(level)
  local ok_call, ok_set, set_or_err = pcall(Telemetry.set_level, level)
  if ok_call and ok_set then
    state.telemetry_ui_status = string.format(t("Telemetry level set to %s."), TelemetryBridge.level_label(level))
    TelemetryBridge.safe_event("feature_used", {
      operation = "docx_telemetry_settings",
      status = "level_changed",
      telemetry_level = tostring(level or "")
    }, {
      operation = "docx_telemetry_settings",
      status = "level_changed",
      policy = "basic"
    })
    return true, set_or_err
  end
  local err = ok_call and set_or_err or ok_set
  state.telemetry_ui_status = string.format(t("Telemetry level save failed: %s"), tostring(err))
  Util.msg(state.telemetry_ui_status, 2)
  return false, err
end

function TelemetryBridge.resume_sending(reason)
  local ok_call, ok_resume, resume_or_err = pcall(Telemetry.resume_sending, reason or t("manual resume from DOCX Import UI"))
  if ok_call and ok_resume then
    state.telemetry_ui_status = t("Telemetry sending resumed.")
    return true
  end
  local err = ok_call and resume_or_err or ok_resume
  state.telemetry_ui_status = string.format(t("Telemetry resume failed: %s"), tostring(err))
  Util.msg(state.telemetry_ui_status, 2)
  return false, err
end

function TelemetryBridge.script_started()
  TelemetryBridge.safe_event("script_started", TelemetryBridge.base_payload({
    operation = "docx_script_lifecycle",
    status = "started",
    script_version = SCRIPT_VERSION
  }), {
    operation = "docx_script_lifecycle",
    status = "started",
    policy = "basic"
  })
end

function TelemetryBridge.send_closed_event(reason)
  if TelemetryBridge.closed_event_sent == true then return end
  TelemetryBridge.closed_event_sent = true
  TelemetryBridge.safe_event("script_closed", TelemetryBridge.base_payload({
    operation = "docx_script_lifecycle",
    status = "closed",
    close_reason = tostring(reason or ""),
    recent_log_lines = TelemetryBridge.content_allowed() and TelemetryBridge.recent_log_lines(40) or nil
  }, {
    include_log = true
  }), {
    operation = "docx_script_lifecycle",
    status = "closed",
    policy = "basic"
  })
  local ok_call, ok_close, close_or_err = pcall(Telemetry.flush_current_queue_fire_and_forget, {
    curl_path = CFG.curl,
    timeout_sec = 7,
    connect_timeout_sec = 2,
    speed_limit = CFG.curl_speed_limit,
    speed_time = 3
  })
  if ok_call and ok_close then
    state.telemetry_ui_status = t("Telemetry close-send launched.")
  else
    local err = ok_call and close_or_err or ok_close
    state.telemetry_ui_status = string.format(t("Telemetry close-send failed: %s"), tostring(err))
    Util.msg(state.telemetry_ui_status, 2)
  end
end

send_telemetry_closed_event = TelemetryBridge.send_closed_event

function Helpers.reset_after_header_change()
  if state.last_parse.ok == true then
    Helpers.refresh_preflight_preview()
  else
    Helpers.reset_preflight_state()
  end
  Helpers.invalidate_cast_state(t("Header view changed. Run Process Cast again."))
end

function Helpers.set_docx_source_mode(value)
  local normalized = normalize_docx_source_mode(value)
  if normalized == state.docx_source_mode then
    return
  end

  local previous_mode = state.docx_source_mode
  state.docx_source_mode = normalized
  Helpers.persist_string(EXTSTATE.docx_source_mode, state.docx_source_mode)
  Helpers.reset_parse_state()
  Helpers.reset_preflight_state()
  Helpers.reset_cast_state()
  Helpers.reset_timecode_stage_preserve_preferences()
  Helpers.reset_dialogue_import_runtime()
  state.import_ready_rows = {}
  Helpers.log_step("docx_source_mode", string.format(t("Source format changed to: %s"), docx_source_mode_item(normalized).label))
  TelemetryBridge.operation_completed("docx_source_mode_changed", {
    old_source_mode = previous_mode,
    new_source_mode = normalized,
    source_mode = normalized
  })
end

function Helpers.ensure_extract_inputs(docx_path, output_root)
  Helpers.refresh_project_relative_paths()
  local docx = Util.trim(docx_path)
  local out_root = Util.trim(output_root)
  if Util.trim(runtime.project_path or "") == "" then
    return false, t("Project path not available. Save the project before importing DOCX.")
  end
  if docx == "" then
    return false, t("docx_path must be a non-empty string")
  end
  if out_root == "" then
    return false, t("output_root must be a non-empty string")
  end
  if not Helpers.is_windows_absolute_path(docx) then
    return false, t("docx_path must be an absolute path")
  end
  if not Helpers.is_windows_absolute_path(out_root) then
    return false, t("output_root must be an absolute path")
  end
  if not Helpers.has_extension(docx, ".docx") then
    return false, t("docx_path must point to a .docx file")
  end
  if r.file_exists(docx) ~= true then
    return false, string.format(t("docx_path not found: %s"), tostring(docx))
  end
  return true
end

function Helpers.run_extract_once(docx_path, out_dir)
  local started_at = r.time_precise()
  local xml_path, message = DocxXmlExtractor.extract_main_document_xml(docx_path, out_dir)
  local elapsed_sec = r.time_precise() - started_at
  local ok =
    type(xml_path) == "string" and xml_path ~= "" and
    r.file_exists(xml_path) == true and
    type(message) == "string" and message ~= "" and
    Helpers.path_inside_created_output_dir(xml_path, out_dir)

  local payload = {
    ok = ok,
    input_docx = docx_path,
    output_dir = out_dir,
    xml_path = xml_path or "",
    message = tostring(message or ""),
    warning = Helpers.message_has_warning(message),
    elapsed_sec = elapsed_sec
  }
  Helpers.store_extract_result(payload)
  return payload
end

function Helpers.run_parse_once(xml_path)
  local started_at = r.time_precise()
  local result = DocxDialogueParser.parse_docx_dialogue_xml(xml_path, {
    source_mode = normalize_docx_source_mode(state.docx_source_mode),
    header = false
  })
  local elapsed_sec = r.time_precise() - started_at
  local ok =
    type(result) == "table" and
    result.message == "_Success_" and
    type(result.rows) == "table" and
    (tonumber(result.number_of_columns) or 0) > 0 and
    (tonumber(result.number_of_rows) or -1) >= 0

  local payload = {
    ok = ok,
    input_xml = xml_path,
    header_enabled = false,
    result = result,
    elapsed_sec = elapsed_sec,
    message = type(result) == "table" and tostring(result.message or "") or ""
  }
  Helpers.store_parse_result(payload)
  return payload
end

function Helpers.column_count()
  return tonumber(state.last_parse.number_of_columns) or 0
end

function Helpers.current_parse_supports_header()
  return state.last_parse.ok == true and state.last_parse.supports_header == true
end

function Helpers.default_column_selection(column_count)
  local cols = tonumber(column_count) or 0
  local timecode_col = (cols >= 1) and 1 or 1
  local character_name_col = (cols >= 2) and 2 or timecode_col
  local dialogue_col = (cols >= 3) and 3 or ((cols >= 2) and 2 or timecode_col)
  return timecode_col, character_name_col, dialogue_col
end

function Helpers.apply_preflight_mapping_suggestions()
  local last = state.last_preflight
  local column_count = tonumber(last.number_of_columns) or 0
  local suggested = state.last_parse.suggested_mapping
  if type(suggested) ~= "table" or column_count < 1 then
    return
  end

  if state.last_parse.suggested_header_enabled == true and Helpers.current_parse_supports_header() == true then
    state.header_enabled = true
  end

  local function valid_column(value)
    local number = tonumber(value)
    if number == nil or math.floor(number) ~= number then
      return nil
    end
    if number < 1 or number > column_count then
      return nil
    end
    return number
  end

  local suggested_timecode_col = valid_column(suggested.timecode_col)
  local suggested_character_col = valid_column(suggested.character_name_col)
  local suggested_dialogue_col = valid_column(suggested.dialogue_col)

  if suggested_timecode_col ~= nil then
    last.selected_timecode_col = suggested_timecode_col
  end
  if suggested_character_col ~= nil then
    last.selected_character_name_col = suggested_character_col
  end
  if suggested_dialogue_col ~= nil then
    last.selected_dialogue_col = suggested_dialogue_col
  end
end

function Helpers.build_header_cells_and_visible_rows()
  local raw_rows = state.last_parse.rows or {}
  local header_cells = {}
  local visible_rows = {}
  local visible_row_metadata = {}
  local start_index = 1

  if Helpers.current_parse_supports_header() == true and state.header_enabled == true and raw_rows[1] ~= nil then
    local header_row = raw_rows[1] or {}
    for col_idx = 1, Helpers.column_count() do
      header_cells[col_idx] = tostring(header_row[col_idx] or "")
    end
    start_index = 2
  end

  for raw_row_index = start_index, #raw_rows do
    local row = raw_rows[raw_row_index] or {}
    local parser_metadata = (state.last_parse.row_metadata_by_index or {})[raw_row_index] or {}
    visible_rows[#visible_rows + 1] = row
    visible_row_metadata[#visible_row_metadata + 1] = {
      raw_row_index = raw_row_index,
      parser_metadata = parser_metadata
    }
  end

  return header_cells, visible_rows, visible_row_metadata
end

function Helpers.end_timecode_from_visible_metadata(meta)
  local parser_metadata = meta and meta.parser_metadata or {}
  return Util.trim(tostring(parser_metadata.end_timecode or ""))
end

function Helpers.refresh_preflight_end_timecode_state()
  local last = state.last_preflight
  local rows = last.visible_rows or {}
  local metadata = last.visible_row_metadata or {}
  local row_count = #rows
  local end_count = 0
  for i = 1, row_count do
    if Helpers.end_timecode_from_visible_metadata(metadata[i]) ~= "" then
      end_count = end_count + 1
    end
  end

  last.end_timecode_count = end_count
  last.end_timecode_complete = row_count > 0 and end_count == row_count
  if end_count == 0 then
    last.use_end_timecodes = false
    last.end_timecode_status_text = t("No end timecodes")
  elseif last.end_timecode_complete == true then
    last.end_timecode_status_text =
      string.format(t("End timecodes found for %d row(s)."), end_count)
  else
    last.use_end_timecodes = false
    last.end_timecode_status_text =
      string.format(t("End timecodes found for %d of %d row(s); disabled until every visible row has one."), end_count, row_count)
  end
end

function Helpers.use_end_timecodes_enabled()
  if state.last_timecode and state.last_timecode.finalized == true then
    return state.last_timecode.use_end_timecodes == true
  end
  return state.last_preflight.use_end_timecodes == true and state.last_preflight.end_timecode_complete == true
end

function Helpers.validate_mapping_selection()
  if state.last_parse.ok ~= true then
    return false, t("Parse result is not available.")
  end

  local column_count = Helpers.column_count()
  if column_count < 3 then
    return false, t("Preflight failed: at least 3 columns are required for mapping.")
  end

  local last = state.last_preflight
  local timecode_col = tonumber(last.selected_timecode_col)
  local character_name_col = tonumber(last.selected_character_name_col)
  local dialogue_col = tonumber(last.selected_dialogue_col)

  if timecode_col == nil or character_name_col == nil or dialogue_col == nil then
    return false, t("All mapping selectors must point to a valid column.")
  end
  if math.floor(timecode_col) ~= timecode_col or math.floor(character_name_col) ~= character_name_col or math.floor(dialogue_col) ~= dialogue_col then
    return false, t("Mapping selectors must use whole-number column indexes.")
  end
  if timecode_col < 1 or timecode_col > column_count then
    return false, t("timecode column is out of range.")
  end
  if character_name_col < 1 or character_name_col > column_count then
    return false, t("character_name column is out of range.")
  end
  if dialogue_col < 1 or dialogue_col > column_count then
    return false, t("dialogue column is out of range.")
  end
  if timecode_col == character_name_col or timecode_col == dialogue_col or character_name_col == dialogue_col then
    return false, t("timecode, character_name, and dialogue columns must be unique.")
  end
  if last.use_end_timecodes == true and last.end_timecode_complete ~= true then
    return false, t("Use end timecodes is enabled, but not every visible row has an end timecode.")
  end

  return true, nil
end

function Helpers.refresh_preflight_preview()
  local last = state.last_preflight
  last.number_of_columns = Helpers.column_count()
  last.header_cells, last.visible_rows, last.visible_row_metadata = Helpers.build_header_cells_and_visible_rows()
  last.mapped_row_count = #(last.visible_rows or {})
  Helpers.refresh_preflight_end_timecode_state()

  local valid_mapping, validation_err = Helpers.validate_mapping_selection()
  if not valid_mapping then
    last.confirmed = false
    last.confirmed_mapping = nil
    if last.ok == nil then
      last.readiness_text = t("Not ready.")
    else
      last.readiness_text = t("Not ready. Resolve mapping issues.")
    end
    last.message = validation_err or ""
    return
  end

  if last.confirmed == true then
    last.readiness_text = t("ready for cast/timecodes")
    last.message = t("Mapping confirmed.")
  else
    last.readiness_text = t("Not ready. Confirm mapping to continue.")
    last.message = t("Preview is based on the current mapping selection.")
  end
end

function Helpers.initialize_preflight_from_parse()
  Helpers.reset_preflight_state()
  local last = state.last_preflight
  last.number_of_columns = Helpers.column_count()
  last.selected_timecode_col, last.selected_character_name_col, last.selected_dialogue_col =
    Helpers.default_column_selection(last.number_of_columns)
  Helpers.apply_preflight_mapping_suggestions()

  if state.last_parse.ok ~= true then
    last.ok = nil
    last.message = ""
    last.readiness_text = t("Not ready.")
    return
  end

  if last.number_of_columns < 3 then
    last.ok = false
    last.readiness_text = t("Not ready. At least 3 columns are required.")
  else
    last.ok = true
    last.readiness_text = t("Not ready. Confirm mapping to continue.")
  end

  Helpers.refresh_preflight_preview()
  Helpers.refresh_import_ready_rows()
end

function Helpers.mapping_display_label(column_index)
  local idx = tonumber(column_index) or 0
  if idx < 1 then
    return t("(not selected)")
  end

  if Helpers.current_parse_supports_header() ~= true or state.header_enabled ~= true or state.use_header_names ~= true then
    return string.format(t("Col %s"), tostring(idx))
  end
  local header_cells = state.last_preflight.header_cells or {}
  local header_text = Helpers.short_preview_text(header_cells[idx] or "", 24)
  if header_text ~= "" and header_text ~= t("(blank)") then
    return string.format(t("Col %d - %s"), idx, header_text)
  end
  return Helpers.safe_header_label(idx, header_cells[idx])
end

function Helpers.mapping_value_label(column_index)
  return Helpers.mapping_display_label(column_index)
end

function Helpers.column_roles_for_index(column_index)
  local idx = tonumber(column_index) or 0
  local last = state.last_preflight
  local roles = {}

  if idx == tonumber(last.selected_timecode_col) then
    roles[#roles + 1] = "TC"
  end
  if idx == tonumber(last.selected_character_name_col) then
    roles[#roles + 1] = "CHAR"
  end
  if idx == tonumber(last.selected_dialogue_col) then
    roles[#roles + 1] = "DLG"
  end

  return roles
end

function Helpers.column_role_label(column_index)
  local roles = Helpers.column_roles_for_index(column_index)
  if #roles == 0 then
    return ""
  end
  return table.concat(roles, "/")
end

function Helpers.column_primary_role(column_index)
  local idx = tonumber(column_index) or 0
  local last = state.last_preflight
  if idx == tonumber(last.selected_dialogue_col) then
    return "DLG"
  end
  if idx == tonumber(last.selected_timecode_col) then
    return "TC"
  end
  if idx == tonumber(last.selected_character_name_col) then
    return "CHAR"
  end
  return ""
end

function Helpers.percent_width(total_width, ratio, min_width)
  local total = tonumber(total_width) or 0
  local target = math.floor(total * (tonumber(ratio) or 0))
  return math.max(tonumber(min_width) or 0, target)
end

function Helpers.tight_combo_width(label_text, min_width, max_width, padding)
  local min_w = tonumber(min_width) or 90
  local max_w = tonumber(max_width) or 190
  local extra = tonumber(padding) or 33
  local width = min_w
  if ImGui.CalcTextSize then
    local text_w = ImGui.CalcTextSize(ctx, tostring(label_text or ""))
    width = math.ceil((tonumber(text_w) or 0) + extra)
  end
  width = math.max(min_w, width)
  width = math.min(max_w, width)
  return width
end

function Helpers.column_role_color(column_index)
  local roles = Helpers.column_roles_for_index(column_index)
  if #roles > 1 then
    return 0x80C0FFFF, 0x20304060
  end
  local role = roles[1]
  if role == "TC" then
    return 0x40D0FFFF, 0x20304060
  end
  if role == "CHAR" then
    return 0x6CFF7CFF, 0x20382060
  end
  if role == "DLG" then
    return 0xFFD36AFF, 0x40302060
  end
  return nil, nil
end

function Helpers.table_header_label(column_index)
  local base_label = ""
  if Helpers.current_parse_supports_header() == true and state.header_enabled == true and state.use_header_names == true then
    local header_text = tostring((state.last_preflight.header_cells or {})[column_index] or "")
    header_text = Util.trim(header_text)
    if header_text ~= "" then
      base_label = header_text
    end
  end
  local role_label = Helpers.column_role_label(column_index)
  if base_label == "" and role_label ~= "" then
    base_label = role_label
  end
  if base_label == "" then
    base_label = string.format(t("Col %s"), tostring(column_index))
  end

  if role_label ~= "" then
    if base_label == role_label then
      return base_label
    end
    return role_label .. " | " .. base_label
  end
  return base_label
end

function Helpers.confirm_mapping()
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_mapping_confirm", {
    use_end_timecodes = Helpers.use_end_timecodes_enabled()
  })
  local valid_mapping, validation_err = Helpers.validate_mapping_selection()
  if not valid_mapping then
    Helpers.refresh_preflight_preview()
    Helpers.log_step("confirm_mapping", tostring(validation_err), 2)
    TelemetryBridge.operation_failed("docx_mapping_confirm", {
      error_code = "DOCX_MAPPING_INVALID",
      validation_failed = true,
      detail_message = tostring(validation_err)
    }, telemetry_started_at)
    TelemetryBridge.emit_support_rows_snapshot("docx_mapping_confirm", {
      reason = "mapping_invalid",
      include_log = true
    })
    return false
  end

  local last = state.last_preflight
  last.confirmed = true
  last.confirmed_mapping = {
    timecode_col = last.selected_timecode_col,
    character_name_col = last.selected_character_name_col,
    dialogue_col = last.selected_dialogue_col,
    use_end_timecodes = Helpers.use_end_timecodes_enabled()
  }
  Helpers.refresh_preflight_preview()
  Helpers.log_step(
    "confirm_mapping",
    string.format(
      t("Confirmed timecode=%s, character_name=%s, dialogue=%s, use_end_timecodes=%s"),
      tostring(last.selected_timecode_col),
      tostring(last.selected_character_name_col),
      tostring(last.selected_dialogue_col),
      Helpers.readable_bool(Helpers.use_end_timecodes_enabled())
    )
  )
  TelemetryBridge.operation_completed("docx_mapping_confirm", {
    timecode_col = tonumber(last.selected_timecode_col) or 0,
    character_name_col = tonumber(last.selected_character_name_col) or 0,
    dialogue_col = tonumber(last.selected_dialogue_col) or 0,
    use_end_timecodes = Helpers.use_end_timecodes_enabled(),
    mapped_row_count = tonumber(last.mapped_row_count) or 0
  }, telemetry_started_at)
  TelemetryBridge.emit_support_rows_snapshot("docx_mapping_confirm", {
    reason = "mapping_confirmed"
  })
  return true
end

function Helpers.set_use_end_timecodes(enabled)
  local last = state.last_preflight
  local next_enabled = enabled == true and last.end_timecode_complete == true
  if last.use_end_timecodes == next_enabled then
    return
  end

  last.use_end_timecodes = next_enabled
  if last.confirmed == true and type(last.confirmed_mapping) == "table" then
    last.confirmed_mapping.use_end_timecodes = next_enabled
  end
  Helpers.refresh_preflight_preview()
  Helpers.invalidate_cast_state(t("End timecode usage changed. Run Process Cast again."))
  Helpers.refresh_import_ready_rows()
end

function Helpers.set_mapping_column(field_name, column_index)
  local last = state.last_preflight
  local previous = tonumber(last[field_name]) or 0
  local next_value = tonumber(column_index) or previous
  if previous == next_value then
    return
  end

  last[field_name] = next_value
  if last.confirmed == true then
    last.confirmed = false
    last.confirmed_mapping = nil
    last.message = t("Mapping changed. Confirm mapping again.")
    last.readiness_text = t("Not ready. Confirm mapping to continue.")
  end
  Helpers.refresh_preflight_preview()
  Helpers.invalidate_cast_state(t("Mapping changed. Run Process Cast again."))
end

function Helpers.render_column_selector(field_name, ui_label)
  local last = state.last_preflight
  local current_value = tonumber(last[field_name]) or 0
  local current_label = Helpers.mapping_value_label(current_value)
  local column_count = Helpers.column_count()

  if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(current_label, 250, 330, 33))
    end
    if ImGui.BeginCombo(ctx, ui_label, current_label) then
      for col_idx = 1, column_count do
        local label = Helpers.mapping_display_label(col_idx)
        local selected = current_value == col_idx
        if ImGui.Selectable(ctx, label .. "##" .. field_name .. "_" .. tostring(col_idx), selected) then
          Helpers.set_mapping_column(field_name, col_idx)
        end
      end
      ImGui.EndCombo(ctx)
    end
  else
    ImGui.TextWrapped(ctx, ui_label .. ": " .. current_label)
  end
end

function Helpers.build_mapped_script_rows()
  local preflight = state.last_preflight
  local mapping = preflight.confirmed_mapping
  if preflight.confirmed ~= true or type(mapping) ~= "table" then
    return {}, {}
  end

  local script_rows = {}
  local source_row_numbers = {}
  local visible_rows = preflight.visible_rows or {}
  local metadata = preflight.visible_row_metadata or {}
  for i = 1, #visible_rows do
    local row = visible_rows[i] or {}
    local meta = metadata[i] or {}
    script_rows[i] = {
      timecode = tostring(row[mapping.timecode_col] or ""),
      end_timecode = Helpers.end_timecode_from_visible_metadata(meta),
      character_name = tostring(row[mapping.character_name_col] or ""),
      character_line = tostring(row[mapping.dialogue_col] or "")
    }
    source_row_numbers[i] = tonumber(meta.raw_row_index) or i
  end

  return script_rows, source_row_numbers
end

function Helpers.count_raw_variants(raw_names_captured)
  local count = 0
  for _ in pairs(raw_names_captured or {}) do
    count = count + 1
  end
  return count
end

function Helpers.character_lookup_by_id(characters)
  local out = {}
  for i = 1, #(characters or {}) do
    local item = characters[i]
    out[item.id] = item
  end
  return out
end

function Helpers.build_row_links(script_rows, characters, source_row_numbers)
  local row_links = {}
  local pending = {}

  for i = 1, #(characters or {}) do
    local item = characters[i]
    pending[item.id] = {
      character = item,
      next_index = 1
    }
  end

  local function next_pair_matches(pending_item, row)
    local seq = pending_item.character.timecodes_lines_from_script or {}
    local pair = seq[pending_item.next_index]
    if type(pair) ~= "table" then
      return false
    end
    return pair[1] == row.timecode and pair[2] == row.character_line
  end

  for row_index = 1, #(script_rows or {}) do
    local row = script_rows[row_index]
    local candidates = {}

    for i = 1, #(characters or {}) do
      local item = characters[i]
      local pending_item = pending[item.id]
      if pending_item and next_pair_matches(pending_item, row) then
        candidates[#candidates + 1] = item
      end
    end

    if #candidates > 1 then
      local narrowed = {}
      for i = 1, #candidates do
        local item = candidates[i]
        if (item.raw_names_captured or {})[row.character_name] ~= nil then
          narrowed[#narrowed + 1] = item
        end
      end
      if #narrowed > 0 then
        candidates = narrowed
      end
    end

    local chosen = nil
    if #candidates >= 1 then
      table.sort(candidates, function(a, b)
        return tostring(a.id) < tostring(b.id)
      end)
      chosen = candidates[1]
      pending[chosen.id].next_index = pending[chosen.id].next_index + 1
    end

    row_links[row_index] = {
      row_index = row_index,
      source_row_index = tonumber((source_row_numbers or {})[row_index]) or row_index,
      raw_character_name = row.character_name,
      timecode = row.timecode,
      end_timecode = row.end_timecode,
      character_line = row.character_line,
      character_id = chosen and chosen.id or nil,
      canonical_name = chosen and chosen.name or "",
      resolved_group = chosen and ("#" .. tostring(chosen.id)) or "",
      ambiguous_match = (#candidates > 1)
    }
  end

  return row_links
end

function Helpers.empty_merged_view()
  return {
    character_count = 0,
    merge_candidate_count = 0,
    characters = {},
    merge_candidates = {},
    row_links = {}
  }
end

function Helpers.visible_characters()
  return state.last_cast.merged_view and state.last_cast.merged_view.characters or {}
end

function Helpers.visible_merge_candidates()
  return state.last_cast.merged_view and state.last_cast.merged_view.merge_candidates or {}
end

function Helpers.visible_row_links()
  return state.last_cast.merged_view and state.last_cast.merged_view.row_links or {}
end

function Helpers.find_character_in_list(characters, character_id)
  for i = 1, #(characters or {}) do
    local item = characters[i]
    if item.id == character_id then
      return item
    end
  end
  return nil
end

function Helpers.find_base_character_by_id(character_id)
  local base = state.last_cast.base_cast or {}
  return Helpers.find_character_in_list(base.characters, character_id)
end

function Helpers.call_process_script_cast_with_settings(script_rows, empty_mode, max_distance)
  local previous_empty_mode = Parse.empty_character_name_mode
  local previous_max_distance = Parse.maximum_allowed_typo_distance

  Parse.empty_character_name_mode = empty_mode
  Parse.maximum_allowed_typo_distance = max_distance

  local ok_call, characters_or_err, merge_candidates_or_nil, message_or_nil =
    pcall(Parse.process_script_cast, script_rows)

  Parse.empty_character_name_mode = previous_empty_mode
  Parse.maximum_allowed_typo_distance = previous_max_distance

  return ok_call, characters_or_err, merge_candidates_or_nil, message_or_nil
end

function Helpers.build_merge_resolution(applied_merges)
  local direct = {}
  for i = 1, #(applied_merges or {}) do
    local item = applied_merges[i]
    if item and item.typo_id ~= nil and item.canonical_id ~= nil then
      direct[item.typo_id] = item.canonical_id
    end
  end

  local function resolve(character_id)
    local current = character_id
    local seen = {}
    while current ~= nil and direct[current] ~= nil and not seen[current] do
      seen[current] = true
      current = direct[current]
    end
    return current
  end

  return resolve
end

function Helpers.build_merged_characters(base_cast, resolve_character_id)
  local base_characters = base_cast.characters or {}
  local base_by_id = Helpers.character_lookup_by_id(base_characters)
  local merged_characters = {}
  local merged_by_id = {}
  local survivor_seen = {}

  for i = 1, #base_characters do
    local base_item = base_characters[i]
    local current_id = resolve_character_id(base_item.id)
    if current_id == base_item.id and not survivor_seen[current_id] then
      survivor_seen[current_id] = true
      local source = base_by_id[current_id] or base_item
      local merged_item = {
        id = current_id,
        name = tostring(source.name or ""),
        count = 0,
        raw_names_captured = {},
        timecodes_lines_from_script = {}
      }
      merged_by_id[current_id] = merged_item
      merged_characters[#merged_characters + 1] = merged_item
    end
  end

  for i = 1, #base_characters do
    local base_item = base_characters[i]
    local current_id = resolve_character_id(base_item.id)
    local merged_item = merged_by_id[current_id]
    if merged_item then
      merged_item.count = merged_item.count + (tonumber(base_item.count) or 0)
      for raw_name, tally in pairs(base_item.raw_names_captured or {}) do
        merged_item.raw_names_captured[raw_name] = (merged_item.raw_names_captured[raw_name] or 0) + (tonumber(tally) or 0)
      end
    end
  end

  return merged_characters, merged_by_id
end

function Helpers.build_merged_row_links(base_cast, resolve_character_id, merged_by_id)
  local base_row_links = base_cast.row_links or {}
  local merged_row_links = {}

  for row_index = 1, #base_row_links do
    local row_link = base_row_links[row_index] or {}
    local current_id = row_link.character_id
    if current_id ~= nil then
      current_id = resolve_character_id(current_id)
    end

    local merged_item = current_id ~= nil and merged_by_id[current_id] or nil
    merged_row_links[row_index] = {
      row_index = row_index,
      source_row_index = row_link.source_row_index or row_index,
      raw_character_name = row_link.raw_character_name,
      timecode = row_link.timecode,
      end_timecode = row_link.end_timecode,
      character_line = row_link.character_line,
      character_id = current_id,
      canonical_name = merged_item and merged_item.name or "",
      resolved_group = merged_item and ("#" .. tostring(current_id)) or "",
      ambiguous_match = row_link.ambiguous_match == true
    }

    if merged_item then
      merged_item.timecodes_lines_from_script[#merged_item.timecodes_lines_from_script + 1] = {
        row_link.timecode,
        row_link.character_line
      }
    end
  end

  return merged_row_links
end

function Helpers.recompute_merge_candidates(base_cast, merged_characters, merged_row_links, empty_mode, max_distance)
  local current_id_by_name = {}
  local synthetic_script_rows = {}

  for i = 1, #merged_characters do
    local item = merged_characters[i]
    current_id_by_name[tostring(item.name or "")] = item.id
  end

  for row_index = 1, #(base_cast.script_rows or {}) do
    local row = base_cast.script_rows[row_index] or {}
    local row_link = merged_row_links[row_index] or {}
    local merged_name = row_link.canonical_name
    if row_link.character_id == nil then
      merged_name = tostring(row.character_name or "")
    end

    synthetic_script_rows[row_index] = {
      timecode = tostring(row.timecode or ""),
      end_timecode = tostring(row.end_timecode or ""),
      character_name = tostring(merged_name or ""),
      character_line = tostring(row.character_line or "")
    }
  end

  local ok_call, characters_or_err, merge_candidates_or_nil, message_or_nil =
    Helpers.call_process_script_cast_with_settings(synthetic_script_rows, empty_mode, max_distance)

  if not ok_call then
    Helpers.log_step("merge_recompute", string.format(t("Synthetic recompute failed: %s"), tostring(characters_or_err)), 2)
    return {}
  end

  if type(characters_or_err) ~= "table" or type(merge_candidates_or_nil) ~= "table" or message_or_nil ~= "Success" then
    Helpers.log_step(
      "merge_recompute",
      string.format(t("Synthetic recompute returned non-success: %s"), tostring(message_or_nil)),
      2
    )
    return {}
  end

  local synthetic_by_id = Helpers.character_lookup_by_id(characters_or_err)
  local seen_pairs = {}
  local out = {}

  for i = 1, #merge_candidates_or_nil do
    local item = merge_candidates_or_nil[i]
    local synthetic_canonical = synthetic_by_id[item.canonical_id]
    local synthetic_typo = synthetic_by_id[item.typo_id]
    local current_canonical_id = synthetic_canonical and current_id_by_name[tostring(synthetic_canonical.name or "")]
    local current_typo_id = synthetic_typo and current_id_by_name[tostring(synthetic_typo.name or "")]

    if current_canonical_id ~= nil and current_typo_id ~= nil and current_canonical_id ~= current_typo_id then
      local key = tostring(current_canonical_id) .. "->" .. tostring(current_typo_id)
      if not seen_pairs[key] then
        seen_pairs[key] = true
        out[#out + 1] = {
          canonical_id = current_canonical_id,
          typo_id = current_typo_id,
          distance = item.distance
        }
      end
    end
  end

  return out
end

function Helpers.validate_cast_selection()
  if state.last_cast.selected_character_id ~= nil and not Helpers.find_character_by_id(state.last_cast.selected_character_id) then
    state.last_cast.selected_character_id = nil
  end

  local candidates = Helpers.visible_merge_candidates()
  if state.last_cast.selected_merge_candidate_index ~= nil and candidates[state.last_cast.selected_merge_candidate_index] == nil then
    state.last_cast.selected_merge_candidate_index = nil
  end
end

function Helpers.refresh_merged_view()
  local last = state.last_cast
  local base_cast = last.base_cast or {}

  if last.ok ~= true then
    last.merged_view = Helpers.empty_merged_view()
    Helpers.validate_cast_selection()
    return
  end

  local resolve_character_id = Helpers.build_merge_resolution(last.applied_merges)
  local merged_characters, merged_by_id = Helpers.build_merged_characters(base_cast, resolve_character_id)
  local merged_row_links = Helpers.build_merged_row_links(base_cast, resolve_character_id, merged_by_id)
  local merged_candidates = Helpers.recompute_merge_candidates(
    base_cast,
    merged_characters,
    merged_row_links,
    last.empty_character_name_mode,
    last.maximum_allowed_typo_distance
  )

  last.merged_view = {
    character_count = #merged_characters,
    merge_candidate_count = #merged_candidates,
    characters = merged_characters,
    merge_candidates = merged_candidates,
    row_links = merged_row_links
  }

  Helpers.validate_cast_selection()
end

function Helpers.apply_selected_merge()
  local telemetry_started_at = TelemetryBridge.now()
  if state.last_cast.ok ~= true then
    Helpers.log_step("apply_merge", t("Cast processing is not available for merge application."), 2)
    TelemetryBridge.operation_failed("docx_apply_merge", {
      error_code = "DOCX_CAST_NOT_READY",
      detail_message = t("Cast processing is not available for merge application.")
    }, telemetry_started_at)
    return
  end

  local selected_index = state.last_cast.selected_merge_candidate_index
  local candidate = selected_index and Helpers.visible_merge_candidates()[selected_index] or nil
  if not candidate then
    Helpers.log_step("apply_merge", t("No merge candidate selected."), 2)
    TelemetryBridge.operation_canceled("docx_apply_merge", {
      selected_candidate_index = tonumber(selected_index) or 0,
      detail_message = t("No merge candidate selected.")
    }, telemetry_started_at)
    return
  end

  state.last_cast.applied_merges[#state.last_cast.applied_merges + 1] = {
    canonical_id = candidate.canonical_id,
    typo_id = candidate.typo_id,
    distance = candidate.distance
  }

  Helpers.refresh_merged_view()
  state.last_cast.selected_merge_candidate_index = nil
  state.last_cast.selected_character_id = candidate.canonical_id
  Helpers.validate_cast_selection()
  Helpers.log_step(
    "apply_merge",
    string.format(
      t("Merged #%s into #%s (distance=%s)"),
      tostring(candidate.typo_id),
      tostring(candidate.canonical_id),
      tostring(candidate.distance)
    )
  )
  TelemetryBridge.operation_completed("docx_apply_merge", {
    selected_candidate_index = tonumber(selected_index) or 0,
    canonical_id = candidate.canonical_id,
    typo_id = candidate.typo_id,
    distance = candidate.distance,
    applied_merge_count = #(state.last_cast.applied_merges or {})
  }, telemetry_started_at)
  TelemetryBridge.emit_support_rows_snapshot("docx_apply_merge", {
    reason = "merge_applied"
  })
end

function Helpers.undo_last_merge()
  local telemetry_started_at = TelemetryBridge.now()
  local applied = state.last_cast.applied_merges or {}
  if #applied == 0 then
    Helpers.log_step("undo_merge", t("No applied merges to undo."), 2)
    TelemetryBridge.operation_canceled("docx_undo_merge", {
      applied_merge_count = 0,
      detail_message = t("No applied merges to undo.")
    }, telemetry_started_at)
    return
  end

  local item = table.remove(applied)
  Helpers.refresh_merged_view()
  state.last_cast.selected_merge_candidate_index = nil
  Helpers.validate_cast_selection()
  Helpers.log_step(
    "undo_merge",
    string.format(t("Removed merge #%s -> #%s"), tostring(item.typo_id), tostring(item.canonical_id))
  )
  TelemetryBridge.operation_completed("docx_undo_merge", {
    canonical_id = item.canonical_id,
    typo_id = item.typo_id,
    distance = item.distance,
    applied_merge_count = #(state.last_cast.applied_merges or {})
  }, telemetry_started_at)
  TelemetryBridge.emit_support_rows_snapshot("docx_undo_merge", {
    reason = "merge_undone"
  })
end

function Helpers.reset_applied_merges()
  local telemetry_started_at = TelemetryBridge.now()
  local previous_count = #(state.last_cast.applied_merges or {})
  if #(state.last_cast.applied_merges or {}) == 0 then
    Helpers.log_step("reset_merges", t("No applied merges to reset."), 2)
    TelemetryBridge.operation_canceled("docx_reset_merges", {
      applied_merge_count = 0,
      detail_message = t("No applied merges to reset.")
    }, telemetry_started_at)
    return
  end

  state.last_cast.applied_merges = {}
  state.last_cast.selected_character_id = nil
  state.last_cast.selected_merge_candidate_index = nil
  Helpers.refresh_merged_view()
  Helpers.log_step("reset_merges", t("Cleared all applied merges."))
  TelemetryBridge.operation_completed("docx_reset_merges", {
    previous_merge_count = previous_count,
    applied_merge_count = 0
  }, telemetry_started_at, {
    policy = "basic",
    include_log = true
  })
  TelemetryBridge.emit_support_rows_snapshot("docx_reset_merges", {
    reason = "merges_reset",
    include_log = true
  })
end

function Helpers.run_cast_once(script_rows, source_row_numbers, total_elapsed_before_cast)
  local started_at = r.time_precise()
  local ok_call, characters_or_err, merge_candidates_or_nil, message_or_nil =
    Helpers.call_process_script_cast_with_settings(
      script_rows,
      state.empty_character_name_mode,
      state.maximum_allowed_typo_distance
    )

  local elapsed_sec = r.time_precise() - started_at
  if not ok_call then
    local payload = {
      ok = false,
      message = tostring(characters_or_err),
      elapsed_sec = elapsed_sec,
      total_elapsed_sec = total_elapsed_before_cast + elapsed_sec,
      empty_character_name_mode = state.empty_character_name_mode,
      maximum_allowed_typo_distance = state.maximum_allowed_typo_distance,
      character_count = 0,
      merge_candidate_count = 0,
      characters = {},
      merge_candidates = {},
      script_rows = script_rows,
      source_row_numbers = source_row_numbers,
      row_links = {}
    }
    Helpers.store_cast_result(payload)
    return payload
  end

  local characters = characters_or_err
  local merge_candidates = merge_candidates_or_nil
  local message = message_or_nil
  local ok =
    type(characters) == "table" and
    type(merge_candidates) == "table" and
    message == "Success"

  local row_links = ok and Helpers.build_row_links(script_rows, characters, source_row_numbers) or {}
  local payload = {
    ok = ok,
    message = tostring(message or ""),
    elapsed_sec = elapsed_sec,
    total_elapsed_sec = total_elapsed_before_cast + elapsed_sec,
    empty_character_name_mode = state.empty_character_name_mode,
    maximum_allowed_typo_distance = state.maximum_allowed_typo_distance,
    character_count = ok and #characters or 0,
    merge_candidate_count = ok and #merge_candidates or 0,
    characters = ok and characters or {},
    merge_candidates = ok and merge_candidates or {},
    script_rows = script_rows,
    source_row_numbers = source_row_numbers,
    row_links = row_links
  }
  Helpers.store_cast_result(payload)
  return payload
end

function Helpers.clear_cast_selection()
  state.last_cast.selected_character_id = nil
  state.last_cast.selected_merge_candidate_index = nil
end

function Helpers.find_character_by_id(character_id)
  return Helpers.find_character_in_list(Helpers.visible_characters(), character_id)
end

function Helpers.raw_variants_lines(raw_names_captured)
  local keys = {}
  for key in pairs(raw_names_captured or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local out = {}
  for i = 1, #keys do
    local key = keys[i]
    local label = tostring(key)
    if label == "" then
      label = t("(empty)")
    end
    out[#out + 1] = label .. " x" .. tostring(raw_names_captured[key])
  end
  return out
end

function Helpers.filtered_row_indices(total_rows)
  local row_count = tonumber(total_rows) or 0
  local row_links = Helpers.visible_row_links()
  local selected_character_id = state.last_cast.selected_character_id
  local selected_merge = Helpers.visible_merge_candidates()[state.last_cast.selected_merge_candidate_index or 0]
  local out = {}

  for row_index = 1, row_count do
    local row_link = row_links[row_index] or {}
    local include = true
    if selected_character_id ~= nil then
      include = row_link.character_id == selected_character_id
    elseif selected_merge ~= nil then
      include =
        row_link.character_id == selected_merge.canonical_id or
        row_link.character_id == selected_merge.typo_id
    end
    if include then
      out[#out + 1] = row_index
    end
  end

  return out
end

function Helpers.find_timecode_format_by_id(format_id)
  local formats = Parse.formats or {}
  for i = 1, #formats do
    local item = formats[i]
    if item.id == format_id then
      return item
    end
  end
  return nil
end

function Helpers.ensure_selected_timecode_format()
  local current = Helpers.find_timecode_format_by_id(state.last_timecode.selected_format_id)
  if current == nil then
    state.last_timecode.selected_format_id = default_timecode_format_id()
  end
  return Helpers.find_timecode_format_by_id(state.last_timecode.selected_format_id)
end

function Helpers.timecode_format_label(format_item)
  if type(format_item) ~= "table" then
    return t("(no format)")
  end
  local description = Util.trim(tostring(format_item.description or ""))
  if description == "" then
    return tostring(format_item.id)
  end
  return tostring(format_item.id) .. ": " .. description
end

function Helpers.clear_timecode_validation(message)
  local last = state.last_timecode
  last.has_validated = false
  last.fps_check_ran = false
  last.final_look_applied = false
  last.fps_warning_count = 0
  last.fps_warning_row_indices = {}
  last.selected_fps_warning_position = nil
  last.bad_issue_row_indices = {}
  last.selected_bad_issue_position = nil
  last.suspicious_issue_row_indices = {}
  last.selected_suspicious_issue_position = nil
  last.pending_scroll_row_index = nil
  last.total_count = #(last.rows or {})
  last.ok_count = 0
  last.bad_count = 0
  last.inconsistent_count = 0
  last.ready = false
  last.readiness_text = last.finalized and t("Not ready. Validate timecodes.") or t("Not ready. Finalize Cast to continue.")
  last.message = tostring(message or "")
  last.elapsed_sec = nil
  Helpers.refresh_project_timecode_context()
  Helpers.refresh_offset_project_seconds()

  for i = 1, #(last.rows or {}) do
    local row = last.rows[i]
    row.status = ""
    row.validation_message = ""
    row.normalized_timecode = nil
    row.normalized_end_timecode = nil
    row.parser_seconds = nil
    row.end_parser_seconds = nil
    row.project_source_seconds = nil
    row.end_project_source_seconds = nil
    row.raw_seconds = nil
    row.end_raw_seconds = nil
    row.effective_timecode_text = ""
    row.effective_end_timecode_text = ""
    row.fps_warning_message = ""
    row.fps_warning = false
  end
  Helpers.refresh_import_ready_rows()
end

function Helpers.clear_inline_extraction_result()
  local last = state.last_timecode
  last.inline_result_visible = false
  last.inline_result_text = ""
  last.inline_result_count = 0
end

function Helpers.set_inline_extraction_result(message, count)
  local last = state.last_timecode
  last.inline_result_text = tostring(message or "")
  last.inline_result_visible = Util.trim(last.inline_result_text) ~= ""
  last.inline_result_count = tonumber(count) or 0
end

function Helpers.inline_extraction_result_text_for_count(count)
  local numeric_count = tonumber(count) or 0
  if numeric_count == 1 then
    return t("Extracted 1 inline timecode.")
  end
  return string.format(t("Extracted %d inline timecodes."), numeric_count)
end

function Helpers.issue_row_indices(issue_type)
  local last = state.last_timecode
  if issue_type == "bad" then
    return last.bad_issue_row_indices or {}
  end
  if issue_type == "suspicious" then
    return last.suspicious_issue_row_indices or {}
  end
  if issue_type == "fps" then
    return last.fps_warning_row_indices or {}
  end
  return {}
end

function Helpers.issue_selected_position(issue_type)
  local last = state.last_timecode
  if issue_type == "bad" then
    return tonumber(last.selected_bad_issue_position) or 0
  end
  if issue_type == "suspicious" then
    return tonumber(last.selected_suspicious_issue_position) or 0
  end
  if issue_type == "fps" then
    return tonumber(last.selected_fps_warning_position) or 0
  end
  return 0
end

local function strict_hh_mm_ss_ff_match(text)
  return tostring(text or ""):match("^(%d%d):(%d%d):(%d%d):(%d%d)$")
end

function Helpers.restore_timecode_rows_from_base(message)
  local last = state.last_timecode
  last.rows = Helpers.copy_timecode_review_rows(last.base_rows)
  state.telemetry_edited_rows = {}
  last.extraction_active = false
  last.extraction_format_id = nil
  last.extracted_inline_count = 0
  Helpers.clear_timecode_validation(message)
end

function Helpers.finalize_cast_rows()
  local last = state.last_timecode
  local base_cast = state.last_cast.base_cast or {}
  local script_rows = base_cast.script_rows or {}
  local source_row_numbers = base_cast.source_row_numbers or {}
  local merged_row_links = Helpers.visible_row_links()
  local draft_map = last.draft_raw_timecodes_by_source_row or {}
  local draft_end_map = last.draft_raw_end_timecodes_by_source_row or {}
  local use_end_timecodes = Helpers.use_end_timecodes_enabled()
  local rows = {}

  for row_index = 1, #script_rows do
    local source = tonumber(source_row_numbers[row_index]) or row_index
    local row = script_rows[row_index] or {}
    local row_link = merged_row_links[row_index] or {}
    local preserved_timecode = draft_map[source]
    local preserved_end_timecode = draft_end_map[source]
    local canonical_name = tostring(row_link.canonical_name or "")
    if canonical_name == "" then
      canonical_name = tostring(row.character_name or "")
    end
    rows[row_index] = {
      row_index = row_index,
      row_key = "src:" .. tostring(source),
      base_row_index = row_index,
      segment_index = 1,
      source_row_index = source,
      original_timecode = tostring(row.timecode or ""),
      raw_timecode_text = tostring(preserved_timecode or row.timecode or ""),
      original_end_timecode = tostring(row.end_timecode or ""),
      raw_end_timecode_text = tostring(preserved_end_timecode or row.end_timecode or ""),
      raw_character_name = tostring(row.character_name or ""),
      canonical_name = canonical_name,
      canonical_id = row_link.resolved_character_id,
      resolved_group = tostring(row_link.resolved_group or ""),
      dialogue = tostring(row.character_line or ""),
      extracted_from_inline = false,
      status = "",
      validation_message = "",
      normalized_timecode = nil,
      normalized_end_timecode = nil,
      parser_seconds = nil,
      end_parser_seconds = nil,
      project_source_seconds = nil,
      end_project_source_seconds = nil,
      raw_seconds = nil,
      end_raw_seconds = nil,
      effective_timecode_text = "",
      effective_end_timecode_text = "",
      fps_warning_message = "",
      fps_warning = false
    }
  end

  last.base_rows = Helpers.copy_timecode_review_rows(rows)
  last.rows = Helpers.copy_timecode_review_rows(rows)
  last.finalized = true
  last.use_end_timecodes = use_end_timecodes
  last.extraction_active = false
  last.extraction_format_id = nil
  last.extracted_inline_count = 0
  last.final_look_applied = false
  last.total_count = #(last.rows or {})
  Helpers.clear_inline_extraction_result()
  Helpers.ensure_selected_timecode_format()
  Helpers.clear_timecode_validation(t("Cast finalized. Validate timecodes."))
  Helpers.refresh_import_ready_rows()
end

function Helpers.extract_inline_timecodes_once()
  local last = state.last_timecode
  if last.finalized ~= true or #(last.base_rows or {}) == 0 then
    return {
      ok = false,
      message = t("Finalize Cast before extracting inline timecodes."),
      elapsed_sec = nil
    }
  end
  if last.use_end_timecodes == true then
    return {
      ok = false,
      message = t("Inline timecode extraction is unavailable when Use end timecodes is enabled."),
      elapsed_sec = nil
    }
  end

  local format_item = Helpers.ensure_selected_timecode_format()
  if format_item == nil then
    return {
      ok = false,
      message = t("No timecode formats are available in Parse.formats."),
      elapsed_sec = nil
    }
  end

  local started_at = r.time_precise()
  local rebuilt_rows = {}
  local extracted_inline_count = 0
  local parse_opts = nil
  if Helpers.is_frame_timecode_format(format_item) then
    local frame_context = Helpers.frame_timecode_validation_context(format_item)
    if frame_context.ok ~= true then
      return {
        ok = false,
        message = tostring(frame_context.message or t("Source FPS is required before extracting frame timecodes.")),
        elapsed_sec = nil
      }
    end
    parse_opts = { source_fps = frame_context.source_fps }
  end

  for base_index = 1, #last.base_rows do
    local base_row = last.base_rows[base_index]
    local fragments, inline_count, extract_message =
      Parse.extract_inline_timecode_fragments(
          tostring(base_row.raw_timecode_text or ""),
          tostring(base_row.dialogue or ""),
          format_item.id,
          parse_opts
        )

    if type(fragments) ~= "table" then
      return {
        ok = false,
        message = tostring(extract_message or t("Inline extraction failed.")),
        elapsed_sec = nil
      }
    end

    extracted_inline_count = extracted_inline_count + (tonumber(inline_count) or 0)
    for segment_index = 1, #fragments do
      local fragment = fragments[segment_index] or {}
      rebuilt_rows[#rebuilt_rows + 1] = {
        row_index = #rebuilt_rows + 1,
        row_key = "src:" .. tostring(base_row.source_row_index or base_index) .. ":seg:" .. tostring(segment_index),
        base_row_index = base_index,
        segment_index = segment_index,
        source_row_index = base_row.source_row_index,
        original_timecode = tostring(fragment.timecode or ""),
        raw_timecode_text = tostring(fragment.timecode or ""),
        raw_character_name = tostring(base_row.raw_character_name or ""),
        canonical_name = tostring(base_row.canonical_name or ""),
        canonical_id = base_row.canonical_id,
        resolved_group = tostring(base_row.resolved_group or ""),
        dialogue = tostring(fragment.dialogue or ""),
        extracted_from_inline = fragment.extracted_from_inline == true,
        status = "",
        validation_message = "",
        normalized_timecode = nil,
        normalized_end_timecode = nil,
        parser_seconds = nil,
        end_parser_seconds = nil,
        project_source_seconds = nil,
        end_project_source_seconds = nil,
        raw_seconds = nil,
        end_raw_seconds = nil,
        effective_timecode_text = "",
        effective_end_timecode_text = "",
        fps_warning_message = "",
        fps_warning = false
      }
    end
  end

  if extracted_inline_count > 0 then
    last.rows = rebuilt_rows
    state.telemetry_edited_rows = {}
    last.extraction_active = true
    last.extraction_format_id = format_item.id
    last.extracted_inline_count = extracted_inline_count
    Helpers.set_inline_extraction_result(
      Helpers.inline_extraction_result_text_for_count(extracted_inline_count),
      extracted_inline_count
    )
    Helpers.clear_timecode_validation(
      string.format(t("Extracted %s inline timecodes. Revalidate to refresh issues."), tostring(extracted_inline_count))
    )
  else
    Helpers.set_inline_extraction_result(t("No inline timecodes found."), 0)
    Helpers.restore_timecode_rows_from_base(
      string.format(t("No inline timecodes found for format %s."), Helpers.timecode_format_label(format_item))
    )
  end

  local elapsed_sec = r.time_precise() - started_at
  last.elapsed_sec = elapsed_sec
  Helpers.refresh_import_ready_rows()
  return {
    ok = true,
    message = last.message,
    elapsed_sec = elapsed_sec,
    extracted_inline_count = extracted_inline_count
  }
end

function Helpers.handle_timecode_format_change()
  local last = state.last_timecode
  if last.extraction_active == true then
    Helpers.restore_timecode_rows_from_base(t("Timecode format changed. Run extraction again if needed, then revalidate."))
    return
  end
  Helpers.clear_timecode_validation(t("Timecode format changed. Revalidate to refresh issues."))
end

function Helpers.can_apply_final_look()
  local last = state.last_timecode
  if last.finalized ~= true or #(last.rows or {}) == 0 then
    return false, t("Finalize Cast before applying Final Look.")
  end
  if last.has_validated ~= true then
    return false, t("Validate timecodes before applying Final Look.")
  end
  if (tonumber(last.bad_count) or 0) > 0 then
    return false, t("Resolve bad timecodes before applying Final Look.")
  end
  if last.final_look_applied == true then
    return false, t("Final Look is already applied.")
  end

  for row_index = 1, #last.rows do
    local row = last.rows[row_index]
    local normalized = Util.trim(tostring(row and row.normalized_timecode or ""))
    if normalized == "" then
      return false, string.format(t("Row %s has no parsed normalized timecode."), tostring(row_index))
    end
    if last.use_end_timecodes == true then
      local normalized_end = Util.trim(tostring(row and row.normalized_end_timecode or ""))
      if normalized_end == "" then
        return false, string.format(t("Row %s has no parsed normalized end timecode."), tostring(row_index))
      end
    end
  end

  return true, t("Ready")
end

function Helpers.apply_final_look_once()
  local can_apply, reason = Helpers.can_apply_final_look()
  if not can_apply then
    return {
      ok = false,
      message = tostring(reason or t("Final Look cannot be applied.")),
      elapsed_sec = nil
    }
  end

  local last = state.last_timecode
  local started_at = r.time_precise()

  for row_index = 1, #last.rows do
    local row = last.rows[row_index]
    local normalized = tostring(row.normalized_timecode or "")
    row.raw_timecode_text = normalized
    local normalized_end = tostring(row.normalized_end_timecode or "")
    if last.use_end_timecodes == true then
      row.raw_end_timecode_text = normalized_end
    end

    local base_row = last.base_rows[row.base_row_index or row_index]
    if base_row ~= nil then
      base_row.raw_timecode_text = normalized
      if last.use_end_timecodes == true then
        base_row.raw_end_timecode_text = normalized_end
      end
    end
  end

  last.draft_raw_timecodes_by_source_row = {}
  last.draft_raw_end_timecodes_by_source_row = {}
  last.final_look_applied = true
  last.message = t("Final look applied. Timecodes locked in parsed format.")
  Helpers.refresh_import_ready_rows()

  return {
    ok = true,
    message = last.message,
    elapsed_sec = r.time_precise() - started_at
  }
end

function Helpers.select_timecode_issue(issue_type, position)
  local last = state.last_timecode
  local issues = Helpers.issue_row_indices(issue_type)
  if #issues == 0 then
    if issue_type == "bad" then
      last.selected_bad_issue_position = nil
    elseif issue_type == "suspicious" then
      last.selected_suspicious_issue_position = nil
    elseif issue_type == "fps" then
      last.selected_fps_warning_position = nil
    end
    last.pending_scroll_row_index = nil
    return
  end

  local clamped = math.max(1, math.min(#issues, tonumber(position) or 1))
  if issue_type == "bad" then
    last.selected_bad_issue_position = clamped
  elseif issue_type == "suspicious" then
    last.selected_suspicious_issue_position = clamped
  elseif issue_type == "fps" then
    last.selected_fps_warning_position = clamped
  end
  last.pending_scroll_row_index = issues[clamped]
end

function Helpers.navigate_timecode_issue(issue_type, delta)
  local issues = Helpers.issue_row_indices(issue_type)
  if #issues == 0 then
    return
  end

  local current = Helpers.issue_selected_position(issue_type)
  if current < 1 then
    current = 1
  end
  Helpers.select_timecode_issue(issue_type, current + (tonumber(delta) or 0))
end

function Helpers.finalize_cast_for_timecodes()
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_finalize_cast", {
    mapped_row_count = tonumber(state.last_preflight.mapped_row_count) or 0
  })
  if state.last_cast.ok ~= true then
    Helpers.log_step("finalize_cast", t("Cast processing must succeed before finalization."), 2)
    TelemetryBridge.operation_failed("docx_finalize_cast", {
      error_code = "DOCX_CAST_NOT_READY",
      detail_message = t("Cast processing must succeed before finalization.")
    }, telemetry_started_at)
    return false
  end

  local base_cast = state.last_cast.base_cast or {}
  if #(base_cast.script_rows or {}) == 0 then
    Helpers.log_step("finalize_cast", t("No cast rows are available for timecode review."), 2)
    TelemetryBridge.operation_failed("docx_finalize_cast", {
      error_code = "DOCX_CAST_EMPTY",
      detail_message = t("No cast rows are available for timecode review.")
    }, telemetry_started_at)
    return false
  end

  Helpers.finalize_cast_rows()
  Helpers.log_step(
    "finalize_cast",
    string.format(t("Finalized cast rows for timecode review: %s"), tostring(state.last_timecode.total_count))
  )
  TelemetryBridge.operation_completed("docx_finalize_cast", {
    review_row_count = tonumber(state.last_timecode.total_count) or 0,
    use_end_timecodes = state.last_timecode.use_end_timecodes == true
  }, telemetry_started_at)
  TelemetryBridge.emit_support_rows_snapshot("docx_finalize_cast", {
    reason = "cast_finalized"
  })
  return true
end

function Helpers.back_to_cast_from_timecodes()
  local telemetry_started_at = TelemetryBridge.now()
  local had_timecode_stage = state.last_timecode.finalized == true or #(state.last_timecode.rows or {}) > 0
  TelemetryBridge.emit_support_rows_snapshot("docx_back_to_cast", {
    reason = "before_back_to_cast",
    include_log = true,
    report = state.last_dialogue_import and state.last_dialogue_import.preflight_report or nil
  })
  Helpers.reset_timecode_stage_preserve_preferences()
  Helpers.refresh_import_ready_rows()
  if had_timecode_stage then
    Helpers.log_step(
      "back_to_cast",
      t("Returned to cast workflow. Discarded the timecode stage and preserved cast results plus timecode preferences.")
    )
  end
  TelemetryBridge.operation_completed("docx_back_to_cast", {
    had_timecode_stage = had_timecode_stage == true,
    import_ready_count = #(state.import_ready_rows or {})
  }, telemetry_started_at, {
    policy = "basic",
    include_log = true
  })
end

function Helpers.set_timecode_text(row_index, new_text)
  local last = state.last_timecode
  if last.final_look_applied == true then
    return
  end
  local row = last.rows[row_index]
  if row == nil then
    return
  end

  local next_text = tostring(new_text or "")
  if row.raw_timecode_text == next_text then
    return
  end

  local old_text = row.raw_timecode_text
  row.raw_timecode_text = next_text
  TelemetryBridge.note_timecode_edit(row_index, row, "start_timecode", old_text, next_text)
  if last.extraction_active == true then
  else
    last.draft_raw_timecodes_by_source_row[row.source_row_index] = next_text
    local base_row = last.base_rows[row.base_row_index or row_index]
    if base_row ~= nil then
      base_row.raw_timecode_text = next_text
    end
  end
  Helpers.clear_timecode_validation(t("Timecodes changed. Revalidate to refresh issues."))
  Helpers.refresh_import_ready_rows()
end

function Helpers.set_end_timecode_text(row_index, new_text)
  local last = state.last_timecode
  if last.final_look_applied == true or last.use_end_timecodes ~= true then
    return
  end
  local row = last.rows[row_index]
  if row == nil then
    return
  end

  local next_text = tostring(new_text or "")
  if row.raw_end_timecode_text == next_text then
    return
  end

  local old_text = row.raw_end_timecode_text
  row.raw_end_timecode_text = next_text
  TelemetryBridge.note_timecode_edit(row_index, row, "end_timecode", old_text, next_text)
  last.draft_raw_end_timecodes_by_source_row[row.source_row_index] = next_text
  local base_row = last.base_rows[row.base_row_index or row_index]
  if base_row ~= nil then
    base_row.raw_end_timecode_text = next_text
  end
  Helpers.clear_timecode_validation(t("Timecodes changed. Revalidate to refresh issues."))
  Helpers.refresh_import_ready_rows()
end

function Helpers.validate_timecodes_once()
  local last = state.last_timecode
  if last.finalized ~= true or #(last.rows or {}) == 0 then
    local payload = {
      ok = false,
      message = t("Finalize Cast before validating timecodes."),
      elapsed_sec = nil
    }
    return payload
  end

  local format_item = Helpers.ensure_selected_timecode_format()
  if format_item == nil then
    return {
      ok = false,
      message = t("No timecode formats are available in Parse.formats."),
      elapsed_sec = nil
    }
  end

  local started_at = r.time_precise()
  Helpers.clear_timecode_validation("")
  local frame_context = Helpers.frame_timecode_validation_context(format_item)
  if frame_context.ok ~= true then
    last.ready = false
    last.readiness_text = t("Timecodes need edits before Final Look/import.")
    last.message = tostring(frame_context.message or t("Frame timecode validation failed."))
    last.elapsed_sec = r.time_precise() - started_at
    Helpers.refresh_import_ready_rows()
    return {
      ok = false,
      message = last.message,
      elapsed_sec = last.elapsed_sec
    }
  end

  local parse_opts = nil
  if Helpers.is_frame_timecode_format(format_item) then
    parse_opts = { source_fps = frame_context.source_fps }
  end

  local previous_valid_start_seconds = nil
  local previous_valid_end_seconds = nil
  local first_bad_issue_position = nil
  local first_suspicious_issue_position = nil

  for row_index = 1, #last.rows do
    local row = last.rows[row_index]
    local row_messages = {}
    local inconsistent_messages = {}
    local row_bad = false
    local normalized, parser_seconds, parse_message = Parse.parse_timecode(row.raw_timecode_text, format_item.id, parse_opts)

    if normalized == nil then
      row_bad = true
      row_messages[#row_messages + 1] = string.format(t("Start: %s"), tostring(parse_message or ""))
    else
      if Helpers.is_frame_timecode_format(format_item) then
        local project_seconds, roundtrip_timecode, roundtrip_ok =
          Helpers.project_frame_timecode_roundtrip(normalized)
        if project_seconds == nil then
          parser_seconds = nil
          row_bad = true
          row_messages[#row_messages + 1] = t("Start: REAPER project frame parser did not return a usable position.")
        elseif roundtrip_ok ~= true then
          parser_seconds = nil
          row_bad = true
          row_messages[#row_messages + 1] = string.format(
            t("Start: REAPER frame round-trip mismatch: %s -> %s"),
            tostring(normalized),
            Util.trim(tostring(roundtrip_timecode or "")) ~= "" and tostring(roundtrip_timecode) or t("(blank)")
          )
        else
          parser_seconds = project_seconds
        end
      end
      row.normalized_timecode = tostring(normalized)
      row.parser_seconds = parser_seconds
      row.project_source_seconds = parser_seconds
      row.raw_seconds = parser_seconds
      if type(r.format_timestr_pos) == "function" and type(parser_seconds) == "number" then
        row.effective_timecode_text = tostring(r.format_timestr_pos(parser_seconds, "", 5) or "")
      else
        row.effective_timecode_text = tostring(row.normalized_timecode or "")
      end
    end

    local normalized_end = nil
    local end_parser_seconds = nil
    local end_parse_message = nil
    local raw_end_timecode_text = Util.trim(tostring(row.raw_end_timecode_text or ""))
    local should_validate_end_timecode = last.use_end_timecodes == true or raw_end_timecode_text ~= ""
    if should_validate_end_timecode == true then
      normalized_end, end_parser_seconds, end_parse_message =
        Parse.parse_timecode(row.raw_end_timecode_text, format_item.id, parse_opts)
      if normalized_end == nil then
        row_bad = true
        row_messages[#row_messages + 1] = string.format(t("End: %s"), tostring(end_parse_message or ""))
      else
        if Helpers.is_frame_timecode_format(format_item) then
          local end_project_seconds, end_roundtrip_timecode, end_roundtrip_ok =
            Helpers.project_frame_timecode_roundtrip(normalized_end)
          if end_project_seconds == nil then
            end_parser_seconds = nil
            row_bad = true
            row_messages[#row_messages + 1] = t("End: REAPER project frame parser did not return a usable position.")
          elseif end_roundtrip_ok ~= true then
            end_parser_seconds = nil
            row_bad = true
            row_messages[#row_messages + 1] = string.format(
              t("End: REAPER frame round-trip mismatch: %s -> %s"),
              tostring(normalized_end),
              Util.trim(tostring(end_roundtrip_timecode or "")) ~= "" and tostring(end_roundtrip_timecode) or t("(blank)")
            )
          else
            end_parser_seconds = end_project_seconds
          end
        end
        row.normalized_end_timecode = tostring(normalized_end)
        row.end_parser_seconds = end_parser_seconds
        row.end_project_source_seconds = end_parser_seconds
        row.end_raw_seconds = end_parser_seconds
        if type(r.format_timestr_pos) == "function" and type(end_parser_seconds) == "number" then
          row.effective_end_timecode_text = tostring(r.format_timestr_pos(end_parser_seconds, "", 5) or "")
        else
          row.effective_end_timecode_text = tostring(row.normalized_end_timecode or "")
        end
      end

      if type(parser_seconds) == "number" and type(end_parser_seconds) == "number" then
        if end_parser_seconds < parser_seconds then
          row_bad = true
          row_messages[#row_messages + 1] = t("End timecode is earlier than start timecode.")
        elseif end_parser_seconds == parser_seconds then
          row_bad = true
          row_messages[#row_messages + 1] = t("End timecode equals start timecode; item duration would be zero.")
        end
      end
    end

    if row_bad == true then
      row.status = "bad"
      row.validation_message = table.concat(row_messages, "\n")
      last.bad_count = last.bad_count + 1
      last.bad_issue_row_indices[#last.bad_issue_row_indices + 1] = row_index
      if first_bad_issue_position == nil then
        first_bad_issue_position = #last.bad_issue_row_indices
      end
    else
      if previous_valid_start_seconds ~= nil and parser_seconds < previous_valid_start_seconds then
        inconsistent_messages[#inconsistent_messages + 1] =
          t("Inconsistent start timecode: current row is earlier than the previous valid parsed row.")
      end
      if last.use_end_timecodes == true
        and previous_valid_end_seconds ~= nil
        and type(end_parser_seconds) == "number"
        and end_parser_seconds < previous_valid_end_seconds
      then
        inconsistent_messages[#inconsistent_messages + 1] =
          t("Inconsistent end timecode: current row is earlier than the previous valid parsed row.")
      end

      if #inconsistent_messages > 0 then
        row.status = "inconsistent"
        row.validation_message = table.concat(inconsistent_messages, "\n")
        last.inconsistent_count = last.inconsistent_count + 1
        last.suspicious_issue_row_indices[#last.suspicious_issue_row_indices + 1] = row_index
        if first_suspicious_issue_position == nil then
          first_suspicious_issue_position = #last.suspicious_issue_row_indices
        end
      else
        row.status = "ok"
        row.validation_message = tostring(parse_message or t("Success"))
        last.ok_count = last.ok_count + 1
      end
      previous_valid_start_seconds = parser_seconds
      if last.use_end_timecodes == true and type(end_parser_seconds) == "number" then
        previous_valid_end_seconds = end_parser_seconds
      end
    end
  end

  last.total_count = #last.rows
  last.elapsed_sec = r.time_precise() - started_at
  last.has_validated = true
  last.ready = last.bad_count == 0

  if last.bad_count > 0 then
    last.readiness_text = t("Timecodes need edits before Final Look/import.")
  elseif last.inconsistent_count > 0 then
    last.readiness_text = t("ready (warnings only)")
  else
    last.readiness_text = t("ready")
  end

  last.message =
    string.format(t("Validated %s rows with format %s."), tostring(last.total_count), Helpers.timecode_format_label(format_item))

  if #last.bad_issue_row_indices > 0 then
    Helpers.select_timecode_issue("bad", first_bad_issue_position or 1)
  elseif #last.suspicious_issue_row_indices > 0 then
    Helpers.select_timecode_issue("suspicious", first_suspicious_issue_position or 1)
  else
    last.selected_bad_issue_position = nil
    last.selected_suspicious_issue_position = nil
    last.pending_scroll_row_index = nil
  end

  Helpers.refresh_import_ready_rows()

  return {
    ok = last.ready,
    message = last.message,
    elapsed_sec = last.elapsed_sec
  }
end

function Helpers.run_fps_aware_timecode_check_once()
  local last = state.last_timecode
  if last.finalized ~= true or #(last.rows or {}) == 0 then
    return {
      ok = false,
      message = t("Finalize Cast before running FPS-aware Check."),
      elapsed_sec = nil
    }
  end

  if last.has_validated ~= true then
    return {
      ok = false,
      message = t("Validate timecodes before running FPS-aware Check."),
      elapsed_sec = nil
    }
  end

  local started_at = r.time_precise()
  Helpers.refresh_project_timecode_context()
  Helpers.clear_fps_warning_state()

  local function fps_warning_for_normalized_timecode(label, normalized)
    local text = tostring(normalized or "")
    local hh = strict_hh_mm_ss_ff_match(text)
    if text == "" then
      return string.format(t("%s: no normalized timecode is available for FPS-aware check."), label)
    end
    if hh == nil then
      return string.format(t("%s: normalized timecode is not strict HH:MM:SS:FF: %s"), label, text)
    end

    local parsed_seconds = type(r.parse_timestr_pos) == "function" and r.parse_timestr_pos(text, 5) or 0
    local round_trip = type(r.format_timestr_pos) == "function" and tostring(r.format_timestr_pos(parsed_seconds, "", 5) or "") or ""
    if round_trip ~= text then
      return string.format(t("%s: FPS-aware round-trip mismatch: %s -> %s"), label, text, round_trip)
    end
    return nil
  end

  for row_index = 1, #last.rows do
    local row = last.rows[row_index]
    local warning_messages = {}
    local start_warning = fps_warning_for_normalized_timecode(t("Start"), row.normalized_timecode)
    if start_warning ~= nil then
      warning_messages[#warning_messages + 1] = start_warning
    end
    if last.use_end_timecodes == true then
      local end_warning = fps_warning_for_normalized_timecode(t("End"), row.normalized_end_timecode)
      if end_warning ~= nil then
        warning_messages[#warning_messages + 1] = end_warning
      end
    end

    if #warning_messages > 0 then
      row.fps_warning = true
      row.fps_warning_message = table.concat(warning_messages, "\n")
      last.fps_warning_row_indices[#last.fps_warning_row_indices + 1] = row_index
    else
      row.fps_warning = false
      row.fps_warning_message = ""
    end
  end

  last.fps_check_ran = true
  last.fps_warning_count = #last.fps_warning_row_indices
  last.elapsed_sec = r.time_precise() - started_at

  if last.fps_warning_count > 0 then
    Helpers.select_timecode_issue("fps", 1)
    last.message = string.format(t("FPS-aware Check finished with %d warning(s)."), last.fps_warning_count)
  else
    last.selected_fps_warning_position = nil
    last.message = t("FPS-aware Check passed with no warnings.")
  end

  return {
    ok = true,
    message = last.message,
    elapsed_sec = last.elapsed_sec,
    warning_count = last.fps_warning_count
  }
end

function TestCases.run_extract_parse_preflight_test()
  local test_id = "extract_parse_preflight"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_extract_parse_preflight", {
    source_mode = normalize_docx_source_mode(state.docx_source_mode)
  })
  Helpers.log_step(test_id, t("Starting"))
  Helpers.reset_all_results()

  local ok_inputs, input_err = Helpers.ensure_extract_inputs(state.docx_path, state.output_root)
  if not ok_inputs then
    Helpers.log_result(test_id, false, input_err)
    TelemetryBridge.stage_finished("docx_extract_parse_preflight", false, {
      error_code = "DOCX_EXTRACT_INPUT_INVALID",
      input_valid = false,
      detail_message = tostring(input_err)
    }, telemetry_started_at)
    return
  end

  local out_dir, out_err = Helpers.make_run_output_dir("extract_parse_import_01")
  if not out_dir then
    Helpers.log_result(test_id, false, out_err)
    TelemetryBridge.stage_finished("docx_extract_parse_preflight", false, {
      error_code = "DOCX_EXTRACT_OUTPUT_DIR_FAILED",
      output_dir_created = false,
      detail_message = tostring(out_err)
    }, telemetry_started_at)
    return
  end

  local extract_payload = Helpers.run_extract_once(state.docx_path, out_dir)
  if not extract_payload.ok then
    Helpers.reset_parse_state()
    Helpers.reset_preflight_state()
    Helpers.log_result(
      test_id,
      false,
      string.format(
        t("extract failed; elapsed=%s; out_dir=%s; msg=%s"),
        Helpers.format_elapsed_seconds(extract_payload.elapsed_sec),
        tostring(extract_payload.output_dir),
        tostring(extract_payload.message)
      )
    )
    TelemetryBridge.stage_finished("docx_extract_parse_preflight", false, {
      error_code = "DOCX_EXTRACT_FAILED",
      extract_ok = false,
      extract_elapsed_sec = tonumber(extract_payload.elapsed_sec) or 0,
      detail_message = tostring(extract_payload.message or "")
    }, telemetry_started_at)
    return
  end

  local extract_warning = ""
  if extract_payload.warning == true then
    extract_warning = tostring(extract_payload.message or "")
    Helpers.add_warning(extract_warning)
    local warning_line = os.date("%H:%M:%S") .. " [" .. t("WARNING") .. "] " .. test_id .. " - " .. extract_warning
    Helpers.add_log_line(warning_line)
    Helpers.set_status(nil, extract_warning, warning_line)
    Util.msg(warning_line, 2)
  end

  local parse_payload = Helpers.run_parse_once(extract_payload.xml_path)
  if not parse_payload.ok then
    Helpers.reset_preflight_state()
    Helpers.log_result(
      test_id,
      false,
      string.format(
        t("parse failed; extract_elapsed=%s; parse_elapsed=%s; parse_msg=%s"),
        Helpers.format_elapsed_seconds(extract_payload.elapsed_sec),
        Helpers.format_elapsed_seconds(parse_payload.elapsed_sec),
        tostring(parse_payload.result and parse_payload.result.message)
      )
    )
    TelemetryBridge.stage_finished("docx_extract_parse_preflight", false, {
      error_code = "DOCX_PARSE_FAILED",
      extract_ok = true,
      parse_ok = false,
      extract_elapsed_sec = tonumber(extract_payload.elapsed_sec) or 0,
      parse_elapsed_sec = tonumber(parse_payload.elapsed_sec) or 0,
      detail_message = tostring(parse_payload.result and parse_payload.result.message or "")
    }, telemetry_started_at)
    return
  end

  Helpers.add_parse_warnings_from_result(parse_payload.result)
  Helpers.initialize_preflight_from_parse()
  local preflight_payload = state.last_preflight
  local passed = preflight_payload.ok == true
  local detail = string.format(
    t("extract_elapsed=%s; parse_elapsed=%s; source=%s; cols=%s; rows=%s; parser_warnings=%s; empty_character_rows=%s; preflight_msg=%s%s"),
    Helpers.format_elapsed_seconds(extract_payload.elapsed_sec),
    Helpers.format_elapsed_seconds(parse_payload.elapsed_sec),
    tostring(parse_payload.result and parse_payload.result.source_mode_detected or ""),
    tostring(parse_payload.result and parse_payload.result.number_of_columns or 0),
    tostring(parse_payload.result and parse_payload.result.number_of_rows or 0),
    tostring(parse_payload.result and parse_payload.result.warning_count or 0),
    tostring(parse_payload.result and parse_payload.result.empty_character_row_count or 0),
    tostring(preflight_payload.message or ""),
    extract_warning ~= "" and ("; extract_warning=" .. extract_warning) or ""
  )
  Helpers.log_result(test_id, passed, detail)
  TelemetryBridge.stage_finished("docx_extract_parse_preflight", passed, {
    error_code = TelemetryBridge.error_code_unless(passed, "DOCX_PREFLIGHT_FAILED"),
    extract_ok = true,
    parse_ok = true,
    preflight_ok = passed == true,
    extract_elapsed_sec = tonumber(extract_payload.elapsed_sec) or 0,
    parse_elapsed_sec = tonumber(parse_payload.elapsed_sec) or 0,
    source_mode = tostring(parse_payload.result and parse_payload.result.source_mode_detected or ""),
    column_count = tonumber(parse_payload.result and parse_payload.result.number_of_columns) or 0,
    row_count = tonumber(parse_payload.result and parse_payload.result.number_of_rows) or 0,
    parser_warning_count = tonumber(parse_payload.result and parse_payload.result.warning_count) or 0,
    empty_character_row_count = tonumber(parse_payload.result and parse_payload.result.empty_character_row_count) or 0,
    detail_message = detail
  }, telemetry_started_at)
end

function TestCases.run_process_cast_test()
  local test_id = "process_cast"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_process_cast", {
    mapped_row_count = tonumber(state.last_preflight.mapped_row_count) or 0,
    use_end_timecodes = Helpers.use_end_timecodes_enabled()
  })
  Helpers.log_step(test_id, t("Starting"))

  if state.last_preflight.confirmed ~= true or type(state.last_preflight.confirmed_mapping) ~= "table" then
    Helpers.log_result(test_id, false, t("Mapping must be confirmed before cast processing."))
    TelemetryBridge.stage_finished("docx_process_cast", false, {
      error_code = "DOCX_MAPPING_NOT_CONFIRMED",
      detail_message = t("Mapping must be confirmed before cast processing.")
    }, telemetry_started_at)
    return
  end

  local script_rows, source_row_numbers = Helpers.build_mapped_script_rows()
  if #script_rows == 0 then
    Helpers.log_result(test_id, false, t("No mapped rows are available for cast processing."))
    TelemetryBridge.stage_finished("docx_process_cast", false, {
      error_code = "DOCX_MAPPED_ROWS_EMPTY",
      mapped_row_count = 0,
      detail_message = t("No mapped rows are available for cast processing.")
    }, telemetry_started_at)
    return
  end

  local total_elapsed_before_cast =
    (tonumber(state.last_extract.elapsed_sec) or 0) +
    (tonumber(state.last_parse.elapsed_sec) or 0)
  local cast_payload = Helpers.run_cast_once(script_rows, source_row_numbers, total_elapsed_before_cast)
  local passed = cast_payload.ok == true
  local detail = string.format(
    t("cast_elapsed=%s; total_elapsed=%s; mapped_rows=%s; character_groups=%s; merge_candidates=%s; message=%s"),
    Helpers.format_elapsed_seconds(cast_payload.elapsed_sec),
    Helpers.format_elapsed_seconds(cast_payload.total_elapsed_sec),
    tostring(#script_rows),
    tostring(state.last_cast.base_cast.character_count or 0),
    tostring(state.last_cast.base_cast.merge_candidate_count or 0),
    tostring(cast_payload.message or "")
  )
  Helpers.log_result(test_id, passed, detail)
  TelemetryBridge.stage_finished("docx_process_cast", passed, {
    error_code = TelemetryBridge.error_code_unless(passed, "DOCX_CAST_FAILED"),
    cast_ok = passed == true,
    cast_elapsed_sec = tonumber(cast_payload.elapsed_sec) or 0,
    total_elapsed_sec = tonumber(cast_payload.total_elapsed_sec) or 0,
    mapped_row_count = #script_rows,
    character_group_count = tonumber(state.last_cast.base_cast.character_count) or 0,
    merge_candidate_count = tonumber(state.last_cast.base_cast.merge_candidate_count) or 0,
    detail_message = detail
  }, telemetry_started_at)
end

function TestCases.run_timecode_validation_test()
  local test_id = "validate_timecodes"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_validate_timecodes", {
    review_row_count = #(state.last_timecode.rows or {})
  })
  Helpers.log_step(test_id, t("Starting"))

  local payload = Helpers.validate_timecodes_once()
  if payload.ok == false and payload.elapsed_sec == nil then
    Helpers.log_result(test_id, false, tostring(payload.message or t("Validation could not start.")))
    TelemetryBridge.stage_finished("docx_validate_timecodes", false, {
      error_code = "DOCX_TIMECODE_VALIDATION_NOT_STARTED",
      detail_message = tostring(payload.message or t("Validation could not start."))
    }, telemetry_started_at)
    return
  end

  local last = state.last_timecode
  local detail = string.format(
    t("elapsed=%s; total_rows=%s; ok=%s; bad=%s; inconsistent=%s; message=%s"),
    Helpers.format_elapsed_seconds(payload.elapsed_sec),
    tostring(last.total_count or 0),
    tostring(last.ok_count or 0),
    tostring(last.bad_count or 0),
    tostring(last.inconsistent_count or 0),
    tostring(payload.message or "")
  )
  Helpers.log_result(test_id, true, detail)
  TelemetryBridge.stage_finished("docx_validate_timecodes", true, {
    validation_ok = payload.ok ~= false,
    elapsed_sec = tonumber(payload.elapsed_sec) or 0,
    total_row_count = tonumber(last.total_count) or 0,
    ok_count = tonumber(last.ok_count) or 0,
    bad_count = tonumber(last.bad_count) or 0,
    inconsistent_count = tonumber(last.inconsistent_count) or 0,
    detail_message = detail
  }, telemetry_started_at)
end

function TestCases.run_fps_aware_timecode_check_test()
  local test_id = "fps_aware_check"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_fps_aware_check", {
    review_row_count = #(state.last_timecode.rows or {})
  })
  Helpers.log_step(test_id, t("Starting"))

  local payload = Helpers.run_fps_aware_timecode_check_once()
  if payload.ok == false then
    Helpers.log_result(test_id, false, tostring(payload.message or t("FPS-aware Check could not start.")))
    TelemetryBridge.stage_finished("docx_fps_aware_check", false, {
      error_code = "DOCX_FPS_CHECK_NOT_STARTED",
      detail_message = tostring(payload.message or t("FPS-aware Check could not start."))
    }, telemetry_started_at)
    return
  end

  local last = state.last_timecode
  local detail = string.format(
    t("elapsed=%s; total_rows=%s; fps_warnings=%s; frame_rate=%s; drop_frame=%s; message=%s"),
    Helpers.format_elapsed_seconds(payload.elapsed_sec),
    tostring(last.total_count or 0),
    tostring(last.fps_warning_count or 0),
    tostring(last.project_frame_rate or t("(nil)")),
    Helpers.readable_bool(last.project_drop_frame == true),
    tostring(payload.message or "")
  )
  Helpers.log_result(test_id, true, detail)
  TelemetryBridge.stage_finished("docx_fps_aware_check", true, {
    elapsed_sec = tonumber(payload.elapsed_sec) or 0,
    total_row_count = tonumber(last.total_count) or 0,
    fps_warning_count = tonumber(last.fps_warning_count) or 0,
    project_frame_rate = tonumber(last.project_frame_rate) or nil,
    project_drop_frame = last.project_drop_frame == true,
    detail_message = detail
  }, telemetry_started_at)
end

function TestCases.run_inline_timecode_extraction_test()
  local test_id = "extract_inline_timecodes"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_inline_timecodes", {
    review_row_count = #(state.last_timecode.rows or {})
  })
  Helpers.log_step(test_id, t("Starting"))

  local last = state.last_timecode
  if last.extraction_active == true then
    local restored_count = tonumber(last.extracted_inline_count) or 0
    Helpers.restore_timecode_rows_from_base(t("Inline timecodes restored to the original finalized rows. Revalidate to refresh issues."))
    Helpers.set_inline_extraction_result(t("Inline timecodes restored to the original rows."), restored_count)
    local detail = string.format(
      t("mode=%s; review_rows=%s; extracted_inline=%s; extraction_active=%s; message=%s"),
      t("undo"),
      tostring(#(last.rows or {})),
      tostring(restored_count),
      Helpers.readable_bool(last.extraction_active == true),
      tostring(last.message or "")
    )
    Helpers.log_result(test_id, true, detail)
    TelemetryBridge.stage_finished("docx_inline_timecodes", true, {
      mode = "undo",
      review_row_count = #(last.rows or {}),
      extracted_inline_count = restored_count,
      extraction_active = last.extraction_active == true,
      detail_message = detail
    }, telemetry_started_at)
    return
  end

  local payload = Helpers.extract_inline_timecodes_once()
  if payload.ok == false then
    Helpers.log_result(test_id, false, tostring(payload.message or t("Inline extraction could not start.")))
    TelemetryBridge.stage_finished("docx_inline_timecodes", false, {
      error_code = "DOCX_INLINE_TIMECODE_EXTRACT_NOT_STARTED",
      mode = "extract",
      detail_message = tostring(payload.message or t("Inline extraction could not start."))
    }, telemetry_started_at)
    return
  end

  local mode = (last.extraction_active == true) and t("extract") or t("no_matches")
  local detail = string.format(
    t("mode=%s; elapsed=%s; review_rows=%s; extracted_inline=%s; extraction_active=%s; message=%s"),
    tostring(mode),
    Helpers.format_elapsed_seconds(payload.elapsed_sec),
    tostring(#(last.rows or {})),
    tostring(last.extracted_inline_count or 0),
    Helpers.readable_bool(last.extraction_active == true),
    tostring(payload.message or "")
  )
  Helpers.log_result(test_id, true, detail)
  TelemetryBridge.stage_finished("docx_inline_timecodes", true, {
    mode = (last.extraction_active == true) and "extract" or "no_matches",
    elapsed_sec = tonumber(payload.elapsed_sec) or 0,
    review_row_count = #(last.rows or {}),
    extracted_inline_count = tonumber(last.extracted_inline_count) or 0,
    extraction_active = last.extraction_active == true,
    detail_message = detail
  }, telemetry_started_at)
end

function TestCases.run_final_look_test()
  local test_id = "final_look"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_final_look", {
    review_row_count = #(state.last_timecode.rows or {})
  })
  Helpers.log_step(test_id, t("Starting"))

  local payload = Helpers.apply_final_look_once()
  if payload.ok == false then
    Helpers.log_result(test_id, false, tostring(payload.message or t("Final Look could not start.")))
    TelemetryBridge.stage_finished("docx_final_look", false, {
      error_code = "DOCX_FINAL_LOOK_NOT_STARTED",
      detail_message = tostring(payload.message or t("Final Look could not start."))
    }, telemetry_started_at)
    return
  end

  local last = state.last_timecode
  local detail = string.format(
    t("elapsed=%s; total_rows=%s; bad=%s; inconsistent=%s; final_look_applied=%s; message=%s"),
    Helpers.format_elapsed_seconds(payload.elapsed_sec),
    tostring(last.total_count or 0),
    tostring(last.bad_count or 0),
    tostring(last.inconsistent_count or 0),
    Helpers.readable_bool(last.final_look_applied == true),
    tostring(payload.message or "")
  )
  Helpers.log_result(test_id, true, detail)
  TelemetryBridge.stage_finished("docx_final_look", true, {
    elapsed_sec = tonumber(payload.elapsed_sec) or 0,
    total_row_count = tonumber(last.total_count) or 0,
    bad_count = tonumber(last.bad_count) or 0,
    inconsistent_count = tonumber(last.inconsistent_count) or 0,
    final_look_applied = last.final_look_applied == true,
    detail_message = detail
  }, telemetry_started_at)
end

function TestCases.run_dialogue_import_preflight_test()
  local test_id = "dialogue_import_preflight"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_import_preflight", {
    import_ready_count = #(state.import_ready_rows or {})
  })
  Helpers.log_step(test_id, t("Starting"))

  local ok, message, report = Helpers.run_dialogue_import_preflight_once()
  local blockers = report and report.blockers or {}
  local warnings = report and report.warnings or {}
  local detail = string.format(
    t("ok=%s; blockers=%s; warnings=%s; message=%s"),
    Helpers.readable_bool(ok == true),
    tostring(#blockers),
    tostring(#warnings),
    tostring(message or "")
  )

  Helpers.log_result(test_id, ok == true, detail)
  TelemetryBridge.stage_finished("docx_import_preflight", ok == true, {
    error_code = TelemetryBridge.error_code_unless(ok == true, "DOCX_IMPORT_PREFLIGHT_FAILED"),
    import_ready_count = #(state.import_ready_rows or {}),
    blocker_count = #blockers,
    warning_count = #warnings,
    report = TelemetryBridge.import_report_payload(report),
    detail_message = tostring(message or "")
  }, telemetry_started_at, {
    report = report,
    include_log = ok ~= true
  })
end

function TestCases.run_dialogue_import_apply_test()
  local test_id = "dialogue_import_apply"
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("docx_import_apply", {
    import_ready_count = #(state.import_ready_rows or {})
  })
  Helpers.log_step(test_id, t("Starting"))

  local ok, message, report = Helpers.apply_dialogue_import_once()
  local summary = report and report.summary or {}
  local detail = string.format(
    t("ok=%s; items=%s; create_tracks=%s; reuse_tracks=%s; markers=%s; message=%s"),
    Helpers.readable_bool(ok == true),
    tostring(summary.item_count or 0),
    tostring(summary.create_track_count or 0),
    tostring(summary.reuse_track_count or 0),
    tostring(summary.marker_count or 0),
    tostring(message or "")
  )

  Helpers.log_result(test_id, ok == true, detail)
  TelemetryBridge.stage_finished("docx_import_apply", ok == true, {
    error_code = TelemetryBridge.error_code_unless(ok == true, "DOCX_IMPORT_APPLY_FAILED"),
    import_ready_count = #(state.import_ready_rows or {}),
    item_count = tonumber(summary.item_count) or 0,
    create_track_count = tonumber(summary.create_track_count) or 0,
    reuse_track_count = tonumber(summary.reuse_track_count) or 0,
    marker_count = tonumber(summary.marker_count) or 0,
    report = TelemetryBridge.import_report_payload(report),
    detail_message = tostring(message or "")
  }, telemetry_started_at, {
    report = report,
    include_log = ok ~= true
  })
end

function UI.set_separator_text(label)
  if ImGui.SeparatorText then
    ImGui.SeparatorText(ctx, t(label))
  else
    ImGui.Separator(ctx)
    ImGui.Text(ctx, t(label))
  end
end

function UI.ui_warning(text)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFB000FF)
  ImGui.TextWrapped(ctx, string.format(t("Warning: %s"), tostring(text or "")))
  ImGui.PopStyleColor(ctx)
end

function UI.ui_error(text)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF3030FF)
  ImGui.TextWrapped(ctx, string.format(t("Blocker: %s"), tostring(text or "")))
  ImGui.PopStyleColor(ctx)
end

function UI.ui_info(text)
  ImGui.TextWrapped(ctx, tostring(text or ""))
end

function UI.render_status_panel()
  local status_line = Helpers.workflow_status_text()
  local has_blocking_timecode_edits = (state.last_timecode.bad_count or 0) > 0
  local has_failed = state.last_cast.ok == false or state.last_parse.ok == false
  local has_warnings =
    not has_blocking_timecode_edits and (
      #state.warnings > 0 or
      (state.last_timecode.inconsistent_count or 0) > 0 or
      (state.last_timecode.fps_warning_count or 0) > 0
    )
  if has_failed then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF3030FF)
  elseif has_blocking_timecode_edits then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xC8C8C8FF)
  elseif has_warnings then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFB000FF)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00CC66FF)
  end
  ImGui.Text(ctx, string.format(t("Status: %s"), status_line))
  ImGui.PopStyleColor(ctx)

  local last_status = state.status_text or state.last_status_text or ""
  if last_status == "" then
    last_status = t("(none)")
  end
  ImGui.TextWrapped(ctx, string.format(t("Last status: %s"), last_status))

  local import_ready_count = #(state.import_ready_rows or {})
  ImGui.TextWrapped(ctx, string.format(t("Import-ready rows: %d"), import_ready_count))

  UI.set_separator_text(t("Warnings"))
  if #state.warnings == 0 then
    UI.ui_info(t("None."))
  else
    for i = 1, #state.warnings do
      UI.ui_warning(state.warnings[i])
    end
  end
  if ImGui.Button(ctx, t("Clear warnings")) then
    Helpers.clear_warnings()
  end
end

function UI.render_mapping_controls()
  UI.set_separator_text(t("Preflight Mapping"))
  if state.last_parse.ok ~= true then
    ImGui.TextWrapped(ctx, t("Run Extract + Parse to inspect columns and confirm mapping."))
    return
  end

  local supports_header = Helpers.current_parse_supports_header()
  if ImGui.BeginDisabled and ImGui.EndDisabled and supports_header ~= true then
    ImGui.BeginDisabled(ctx, true)
  end
  local ch_header, nv_header = ImGui.Checkbox(ctx, t("First row is a header"), supports_header == true and state.header_enabled == true)
  if ImGui.BeginDisabled and ImGui.EndDisabled and supports_header ~= true then
    ImGui.EndDisabled(ctx)
  end
  if ch_header and supports_header == true then
    state.header_enabled = nv_header
    Helpers.persist_boolean(EXTSTATE.header_enabled, state.header_enabled)
    Helpers.reset_after_header_change()
    Helpers.refresh_import_ready_rows()
  end

  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, supports_header ~= true or state.header_enabled ~= true)
    local ch_use_header_names, nv_use_header_names = ImGui.Checkbox(ctx, t("Use header names in column pickers"), state.use_header_names == true)
    if ch_use_header_names then
      state.use_header_names = nv_use_header_names
      Helpers.persist_boolean(EXTSTATE.use_header_names, state.use_header_names)
    end
    ImGui.EndDisabled(ctx)
  else
    if supports_header == true and state.header_enabled == true then
      local ch_use_header_names, nv_use_header_names = ImGui.Checkbox(ctx, t("Use header names in column pickers"), state.use_header_names == true)
      if ch_use_header_names then
        state.use_header_names = nv_use_header_names
        Helpers.persist_boolean(EXTSTATE.use_header_names, state.use_header_names)
      end
    else
      ImGui.TextWrapped(ctx, t("Header controls are unavailable for this parsed DOCX layout."))
    end
  end

  Helpers.render_column_selector("selected_timecode_col", t("Timecode column"))
  Helpers.render_column_selector("selected_character_name_col", t("Character column"))
  Helpers.render_column_selector("selected_dialogue_col", t("Dialogue column"))

  local last = state.last_preflight
  if last.end_timecode_count == 0 then
    ImGui.TextWrapped(ctx, t("No end timecodes"))
  elseif last.end_timecode_complete == true then
    local changed_end_tc, new_end_tc =
      ImGui.Checkbox(ctx, t("Use end timecodes"), last.use_end_timecodes == true)
    if changed_end_tc then
      Helpers.set_use_end_timecodes(new_end_tc)
    end
    ImGui.TextWrapped(ctx, tostring(last.end_timecode_status_text or ""))
  else
    UI.ui_warning(tostring(last.end_timecode_status_text or ""))
  end

  local can_confirm = select(1, Helpers.validate_mapping_selection())
  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, not can_confirm)
    if ImGui.Button(ctx, t("Confirm Mapping")) then
      Helpers.confirm_mapping()
    end
    ImGui.EndDisabled(ctx)
  else
    if can_confirm then
      if ImGui.Button(ctx, t("Confirm Mapping")) then
        Helpers.confirm_mapping()
      end
    else
      ImGui.TextWrapped(ctx, t("Confirm Mapping is unavailable until the 3 selected columns are unique and valid."))
    end
  end

  if state.last_preflight.confirmed == true then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, t("Status: confirmed"))
  else
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, t("Status: not confirmed"))
  end
end

function UI.render_docx_source_mode_selector()
  local current_item = docx_source_mode_item(state.docx_source_mode)
  local current_label = tostring(current_item.label or current_item.id)

  if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(current_label, 260, 420, 55))
    end
    if ImGui.BeginCombo(ctx, t("Source format"), current_label) then
      for i = 1, #DOCX_SOURCE_MODES do
        local item = DOCX_SOURCE_MODES[i]
        local selected = item.id == normalize_docx_source_mode(state.docx_source_mode)
        if ImGui.Selectable(ctx, tostring(item.label), selected) then
          Helpers.set_docx_source_mode(item.id)
        end
        if selected and ImGui.SetItemDefaultFocus then
          ImGui.SetItemDefaultFocus(ctx)
        end
      end
      ImGui.EndCombo(ctx)
    end
  else
    ImGui.TextWrapped(ctx, string.format(t("Source format: %s"), current_label))
  end

  local mode_description = tostring(current_item.description or "")
  if mode_description ~= "" then
    ImGui.TextWrapped(ctx, mode_description)
  end

  if state.last_parse.ok == true then
    local detected = docx_source_mode_item(state.last_parse.source_mode_detected)
    ImGui.TextWrapped(ctx, string.format(t("Detected format: %s"), tostring(detected.label or detected.id)))
  end
end

function UI.render_mode_selector()
  local current_label = Parse.empty_character_name_config[state.empty_character_name_mode] or tostring(state.empty_character_name_mode)
  if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(current_label, 275, 570, 57))
    end
    if ImGui.BeginCombo(ctx, t("Empty character handling"), current_label) then
      for i = 1, #Parse.empty_character_name_config do
        local label = Parse.empty_character_name_config[i]
        local selected = state.empty_character_name_mode == i
        if ImGui.Selectable(ctx, tostring(i) .. ": " .. tostring(label), selected) then
          state.empty_character_name_mode = i
          Helpers.invalidate_cast_state(t("Cast settings changed. Run Process Cast again."))
        end
      end
      ImGui.EndCombo(ctx)
    end
  else
    ImGui.TextWrapped(ctx, string.format(t("Empty character handling: %s"), tostring(current_label)))
  end
end

function UI.render_cast_controls()
  UI.set_separator_text(t("Cast Processing and Merge"))

  if state.last_preflight.confirmed ~= true then
    ImGui.TextWrapped(ctx, t("Confirm mapping first. Cast processing becomes available after that."))
    return
  end

  if state.last_timecode.finalized == true then
    ImGui.TextWrapped(
      ctx,
      t("Cast is finalized for timecode review. Use Back To Cast in the Timecode Review section to discard the timecode stage and continue merging.")
    )
    return
  end

  UI.render_mode_selector()

  ImGui.Text(ctx, t("Maximum typo distance:"))
  ImGui.SameLine(ctx)
  local ch_distance, nv_distance = ImGui.InputText(ctx, "##maximum_allowed_typo_distance", tostring(state.max_distance_input or ""))
  if ch_distance then
    state.max_distance_input = nv_distance
    local parsed = tonumber(nv_distance)
    if parsed ~= nil then
      local clamped = math.max(0, math.floor(parsed))
      if clamped ~= state.maximum_allowed_typo_distance then
        state.maximum_allowed_typo_distance = clamped
        Helpers.invalidate_cast_state(t("Cast settings changed. Run Process Cast again."))
      end
      if tostring(clamped) ~= nv_distance then
        state.max_distance_input = tostring(clamped)
      end
    end
  end

  if ImGui.Button(ctx, t("Process Cast")) then
    TestCases.run_process_cast_test()
  end
end

function UI.render_timecode_format_selector()
  local current = Helpers.ensure_selected_timecode_format()
  local current_label = Helpers.timecode_format_label(current)
  local formats = Parse.formats or {}

  if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(current_label, 357, 570, 57))
    end
    if ImGui.BeginCombo(ctx, t("Timecode format"), current_label) then
      for i = 1, #formats do
        local item = formats[i]
        local label = Helpers.timecode_format_label(item)
        local selected = item.id == state.last_timecode.selected_format_id
        if ImGui.Selectable(ctx, label .. "##timecode_format_" .. tostring(item.id), selected) then
          state.last_timecode.selected_format_id = item.id
          Helpers.handle_timecode_format_change()
        end
      end
      ImGui.EndCombo(ctx)
    end
  else
    ImGui.TextWrapped(ctx, string.format(t("Timecode format: %s"), current_label))
  end

  if current and Util.trim(tostring(current.explanation or "")) ~= "" then
    ImGui.TextWrapped(ctx, tostring(current.explanation))
  end
end

function UI.render_source_fps_controls(format_item)
  if Helpers.is_frame_timecode_format(format_item) ~= true then
    ImGui.TextWrapped(ctx, t("FPS check is not applicable for this timecode format."))
    return
  end

  local last = state.last_timecode
  local source_fps, source_fps_err = Helpers.parse_source_fps_input(last.source_fps_input)

  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 160)
  end

  local push_red_field = source_fps == nil and ImGui.PushStyleColor and ImGui.PopStyleColor and ImGui.Col_FrameBg
  if push_red_field then
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x402020FF)
  end
  local changed_source_fps, next_source_fps =
    ImGui.InputText(ctx, t("Source FPS") .. "##docx_import_source_fps", tostring(last.source_fps_input or ""))
  if push_red_field then
    ImGui.PopStyleColor(ctx)
  end
  if changed_source_fps then
    Helpers.set_source_fps_input(next_source_fps)
    source_fps, source_fps_err = Helpers.parse_source_fps_input(state.last_timecode.source_fps_input)
  end

  if source_fps == nil then
    UI.ui_error(t("Source FPS is required for HH:MM:SS:FF timecodes. It must match the REAPER project FPS before import."))
    UI.ui_error(source_fps_err)
    return
  end

  local project_frame_rate, project_drop_frame = Helpers.refresh_project_timecode_context()
  if type(project_frame_rate) ~= "number" or project_frame_rate <= 0 then
    UI.ui_error(t("REAPER project FPS is unavailable. Check Project settings > Video > Frame rate."))
  elseif project_drop_frame == true then
    UI.ui_error(t("Drop-frame project timecode is not supported for DOCX HH:MM:SS:FF import."))
  elseif not Helpers.fps_values_match(source_fps, project_frame_rate) then
    UI.ui_error(
      string.format(
        t("Source FPS %.3f does not match REAPER project FPS %.3f."),
        source_fps,
        project_frame_rate
      )
    )
  else
    UI.ui_info(string.format(t("Source FPS %.3f matches REAPER project FPS %.3f."), source_fps, project_frame_rate))
  end
end

function UI.render_timecode_controls()
  UI.set_separator_text(t("Timecode Review"))
  local last = state.last_timecode

  if state.last_cast.ok ~= true then
    ImGui.TextWrapped(ctx, t("Run Process Cast successfully before timecode review."))
    return
  end

  if last.finalized ~= true then
    ImGui.TextWrapped(ctx, t("Click Finalize Cast to start timecode validation and correction."))
    return
  end

  if ImGui.Button(ctx, t("Back To Cast")) then
    Helpers.back_to_cast_from_timecodes()
    return
  end

  if last.final_look_applied == true then
    ImGui.TextWrapped(ctx, t("Final Look is applied. Timecodes are locked in parsed format."))
    ImGui.TextWrapped(ctx, t("Back To Cast will discard the timecode stage and keep cast results plus timecode preferences."))
    if last.inline_result_visible == true then
      ImGui.TextWrapped(ctx, tostring(last.inline_result_text or ""))
    end
    return
  end

  local current_format = Helpers.ensure_selected_timecode_format()
  UI.render_timecode_format_selector()
  current_format = Helpers.ensure_selected_timecode_format()
  if Helpers.is_frame_timecode_format(current_format) then
    ImGui.TextWrapped(ctx, Helpers.project_frame_rate_summary_text())
    ImGui.TextWrapped(ctx, t("Confirm REAPER project FPS in File > Project settings... > Video tab > Frame rate."))
  end
  UI.render_source_fps_controls(current_format)

  if last.use_end_timecodes == true then
    ImGui.TextWrapped(ctx, t("Inline timecode extraction is unavailable when Use end timecodes is enabled."))
  else
    local extract_label = last.extraction_active and t("Undo Extract inline timecodes") or t("Extract inline timecodes")
    if ImGui.Button(ctx, extract_label) then
      TestCases.run_inline_timecode_extraction_test()
    end
    ImGui.SameLine(ctx)
  end
  local validate_label = last.has_validated and t("Revalidate Timecodes") or t("Validate Timecodes")
  if ImGui.Button(ctx, validate_label) then
    TestCases.run_timecode_validation_test()
    last = state.last_timecode
  end
  ImGui.SameLine(ctx)
  ImGui.TextWrapped(ctx, Helpers.is_frame_timecode_format(current_format) and t("Frame/FPS validation runs with Validate Timecodes.") or t("FPS check: not applicable."))

  local can_final_look = Helpers.can_apply_final_look()
  if can_final_look then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Final Look")) then
      TestCases.run_final_look_test()
      return
    end
  end

  if last.inline_result_visible == true then
    ImGui.TextWrapped(ctx, tostring(last.inline_result_text or ""))
  end

  local bad_issue_count = #(last.bad_issue_row_indices or {})
  local suspicious_issue_count = #(last.suspicious_issue_row_indices or {})
  local fps_issue_count = #(last.fps_warning_row_indices or {})
  local selected_bad_issue_position = tonumber(last.selected_bad_issue_position) or 0
  local selected_suspicious_issue_position = tonumber(last.selected_suspicious_issue_position) or 0
  local selected_fps_issue_position = tonumber(last.selected_fps_warning_position) or 0

  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, bad_issue_count == 0)
    if ImGui.Button(ctx, t("Prev Bad")) then
      Helpers.navigate_timecode_issue("bad", -1)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Next Bad")) then
      Helpers.navigate_timecode_issue("bad", 1)
    end
    ImGui.EndDisabled(ctx)
  else
    if ImGui.Button(ctx, t("Prev Bad")) then
      Helpers.navigate_timecode_issue("bad", -1)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Next Bad")) then
      Helpers.navigate_timecode_issue("bad", 1)
    end
  end
  ImGui.SameLine(ctx)
  ImGui.TextWrapped(
    ctx,
    string.format(t("Bad: %d"), bad_issue_count)
  )

  if bad_issue_count > 0 then
    ImGui.TextWrapped(
      ctx,
      string.format(t("Bad issue %d of %d"), math.max(1, selected_bad_issue_position), bad_issue_count)
    )
  end

  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, suspicious_issue_count == 0)
    if ImGui.Button(ctx, t("Prev Suspicious")) then
      Helpers.navigate_timecode_issue("suspicious", -1)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Next Suspicious")) then
      Helpers.navigate_timecode_issue("suspicious", 1)
    end
    ImGui.EndDisabled(ctx)
  else
    if ImGui.Button(ctx, t("Prev Suspicious")) then
      Helpers.navigate_timecode_issue("suspicious", -1)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Next Suspicious")) then
      Helpers.navigate_timecode_issue("suspicious", 1)
    end
  end
  ImGui.SameLine(ctx)
  ImGui.TextWrapped(
    ctx,
    string.format(t("Suspicious: %d"), suspicious_issue_count)
  )

  if suspicious_issue_count > 0 then
    ImGui.TextWrapped(
      ctx,
      string.format(t("Suspicious issue %d of %d"), math.max(1, selected_suspicious_issue_position), suspicious_issue_count)
    )
  end

  if fps_issue_count > 0 then
    if ImGui.Button(ctx, t("Prev FPS")) then
      Helpers.navigate_timecode_issue("fps", -1)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Next FPS")) then
      Helpers.navigate_timecode_issue("fps", 1)
    end
    ImGui.SameLine(ctx)
    ImGui.TextWrapped(ctx, string.format(t("FPS warnings: %d"), fps_issue_count))
    ImGui.TextWrapped(
      ctx,
      string.format(t("FPS warning %d of %d"), math.max(1, selected_fps_issue_position), fps_issue_count)
    )
    local fps_row_index = (last.fps_warning_row_indices or {})[math.max(1, selected_fps_issue_position)]
    local fps_row = fps_row_index and last.rows[fps_row_index] or nil
    if fps_row and Util.trim(tostring(fps_row.fps_warning_message or "")) ~= "" then
      ImGui.TextWrapped(ctx, tostring(fps_row.fps_warning_message))
    end
  elseif suspicious_issue_count == 0 and bad_issue_count == 0 and last.has_validated == true then
    ImGui.TextWrapped(ctx, t("No current issues."))
  elseif suspicious_issue_count == 0 and bad_issue_count == 0 then
    ImGui.TextWrapped(ctx, t("Run Validate Timecodes to refresh issues."))
  end
end

function UI.dialogue_import_item_flags_text(item)
  local flags = {}
  if item and item.empty_dialogue == true then flags[#flags + 1] = t("empty_dialogue") end
  if item and item.too_short == true then flags[#flags + 1] = t("too_short") end
  if item and item.too_close == true then flags[#flags + 1] = t("too_close") end
  if item and item.overlap_next == true then flags[#flags + 1] = t("overlap") end
  if item and item.shrunk_to_fit == true then flags[#flags + 1] = t("shrunk") end
  if #flags == 0 then
    return t("-")
  end
  return table.concat(flags, ", ")
end

function UI.render_dialogue_import_track_plan(report)
  local targets = report and report.track_plan and report.track_plan.targets or {}
  UI.set_separator_text(t("Track Plan"))
  if #targets == 0 then
    UI.ui_info(t("No destination tracks are planned."))
    return
  end
  if not ImGui.BeginTable then
    UI.ui_info(t("Table rendering is not available in this ReaImGui build."))
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable
  local table_h = math.max(120, math.min(260, (#targets + 2) * 24))
  if ImGui.BeginTable(ctx, "##docx_import_dialogue_track_plan", 4, table_flags, -1, table_h) then
    ImGui.TableSetupColumn(ctx, t("Role"), ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, t("Track"), ImGui.TableColumnFlags_WidthStretch, 3.0)
    ImGui.TableSetupColumn(ctx, t("Action"), ImGui.TableColumnFlags_WidthFixed, 85)
    ImGui.TableSetupColumn(ctx, t("Span"), ImGui.TableColumnFlags_WidthFixed, 110)
    ImGui.TableHeadersRow(ctx)

    for i = 1, #targets do
      local target = targets[i] or {}
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, tostring(target.role or ""))
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.TextWrapped(ctx, tostring(target.track_name or ""))
      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.Text(ctx, tostring(target.action or ""))
      ImGui.TableSetColumnIndex(ctx, 3)
      if target.has_existing_items_in_span == true then
        ImGui.TextWrapped(ctx, t("occupied"))
      else
        ImGui.TextWrapped(ctx, t("-"))
      end
    end

    ImGui.EndTable(ctx)
  end
end

function UI.render_dialogue_import_item_plan(report)
  local items = report and report.item_plan or {}
  UI.set_separator_text(t("Item Plan"))
  if #items == 0 then
    UI.ui_info(t("No import items are planned."))
    return
  end
  if not ImGui.BeginTable then
    UI.ui_info(t("Table rendering is not available in this ReaImGui build."))
    return
  end

  local flags = (#items <= 25 and ImGui.TreeNodeFlags_DefaultOpen) or 0
  local open = ImGui.CollapsingHeader(ctx, t("Planned Items"), nil, flags)
  if not open then
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY
  local table_h = math.max(180, math.min(360, (#items + 2) * 24))
  local source_end_mode = report and report.settings and report.settings.use_source_end_timecodes == true
  local column_count = source_end_mode and 7 or 6
  if ImGui.BeginTable(ctx, "##docx_import_dialogue_item_plan", column_count, table_flags, -1, table_h) then
    ImGui.TableSetupColumn(ctx, t("Row"), ImGui.TableColumnFlags_WidthFixed, 64)
    ImGui.TableSetupColumn(ctx, t("Track"), ImGui.TableColumnFlags_WidthFixed, 140)
    ImGui.TableSetupColumn(ctx, t("Start"), ImGui.TableColumnFlags_WidthFixed, 80)
    if source_end_mode then
      ImGui.TableSetupColumn(ctx, t("End"), ImGui.TableColumnFlags_WidthFixed, 80)
    end
    ImGui.TableSetupColumn(ctx, t("Length"), ImGui.TableColumnFlags_WidthFixed, 80)
    ImGui.TableSetupColumn(ctx, t("Flags"), ImGui.TableColumnFlags_WidthFixed, 130)
    ImGui.TableSetupColumn(ctx, t("Notes"), ImGui.TableColumnFlags_WidthStretch, 3.0)
    if ImGui.TableSetupScrollFreeze then
      ImGui.TableSetupScrollFreeze(ctx, 1, 1)
    end
    ImGui.TableHeadersRow(ctx)

    for i = 1, #items do
      local item = items[i] or {}
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, tostring(item.row_key or item.input_index or i))
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.TextWrapped(ctx, tostring(item.track_name or ""))
      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.Text(ctx, string.format("%.3f", tonumber(item.start_seconds) or 0))
      if source_end_mode then
        ImGui.TableSetColumnIndex(ctx, 3)
        ImGui.Text(ctx, string.format("%.3f", tonumber(item.effective_end_seconds) or 0))
      end
      ImGui.TableSetColumnIndex(ctx, source_end_mode and 4 or 3)
      ImGui.Text(ctx, string.format("%.3f", tonumber(item.effective_length_seconds) or 0))
      ImGui.TableSetColumnIndex(ctx, source_end_mode and 5 or 4)
      ImGui.TextWrapped(ctx, UI.dialogue_import_item_flags_text(item))
      ImGui.TableSetColumnIndex(ctx, source_end_mode and 6 or 5)
      ImGui.TextWrapped(ctx, tostring(item.note_text or ""))
    end

    ImGui.EndTable(ctx)
  end
end

function UI.render_dialogue_import_controls()
  UI.set_separator_text(t("Final Import"))

  if state.last_timecode.final_look_applied ~= true then
    ImGui.TextWrapped(ctx, t("Apply Final Look in Timecode Review to unlock import preflight and apply."))
    return
  end

  if #(state.import_ready_rows or {}) == 0 then
    ImGui.TextWrapped(ctx, t("No import-ready rows are available for REAPER import."))
    return
  end

  local current_format = Helpers.ensure_selected_timecode_format()
  if Helpers.is_frame_timecode_format(current_format) then
    ImGui.TextWrapped(ctx, Helpers.project_frame_rate_summary_text())
    ImGui.TextWrapped(ctx, t("Confirm REAPER project FPS in File > Project settings... > Video tab > Frame rate."))
  else
    ImGui.TextWrapped(ctx, t("FPS check: not applicable."))
  end
  ImGui.TextWrapped(ctx, Helpers.timecode_offset_summary_text())

  local current_label = Helpers.dialogue_import_layout_label()
  if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(current_label, 357, 1024, 33))
    end
    if ImGui.BeginCombo(ctx, t("Import layout"), current_label) then
      local single_selected = state.dialogue_import_layout_mode == "single_track"
      if ImGui.Selectable(ctx, Helpers.dialogue_import_layout_label("single_track"), single_selected) then
        Helpers.set_dialogue_import_layout_mode("single_track")
      end

      local dedicated_selected = state.dialogue_import_layout_mode == "dedicated_tracks"
      if ImGui.Selectable(ctx, Helpers.dialogue_import_layout_label("dedicated_tracks"), dedicated_selected) then
        Helpers.set_dialogue_import_layout_mode("dedicated_tracks")
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SameLine(ctx)
    local changed_markers, new_markers =
      ImGui.Checkbox(ctx, t("Add warning markers"), state.dialogue_import_add_warning_markers == true)
    if changed_markers then
      Helpers.set_dialogue_import_add_warning_markers(new_markers)
    end
  else
    ImGui.TextWrapped(ctx, string.format(t("Import layout: %s"), current_label))
    local changed_markers, new_markers =
      ImGui.Checkbox(ctx, t("Add warning markers"), state.dialogue_import_add_warning_markers == true)
    if changed_markers then
      Helpers.set_dialogue_import_add_warning_markers(new_markers)
    end
  end
  local using_end_timecodes = Helpers.use_end_timecodes_enabled()
  if using_end_timecodes then
    ImGui.TextWrapped(ctx, t("Markers use a separate severe-issue policy: too close and empty dialogue only."))
  else
    ImGui.TextWrapped(ctx, t("Markers use a separate severe-issue policy: too short, too close, and empty dialogue only."))
  end

  local changed_offset_enabled, new_offset_enabled =
    ImGui.Checkbox(ctx, t("Enable import offset"), state.last_timecode.offset_enabled == true)
  if changed_offset_enabled then
    Helpers.set_timecode_offset_enabled(new_offset_enabled)
  end
  ImGui.SameLine(ctx)

  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, state.last_timecode.offset_enabled ~= true)
  end
  if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
    local current_direction_label = (state.last_timecode.offset_direction == "left") and t("Left") or t("Right")
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(current_direction_label, 57, 150, 33))
    end
    if ImGui.BeginCombo(ctx, t("Offset direction"), current_direction_label) then
      local left_selected = state.last_timecode.offset_direction == "left"
      if ImGui.Selectable(ctx, t("Left"), left_selected) then
        Helpers.set_timecode_offset_direction("left")
      end
      local right_selected = state.last_timecode.offset_direction ~= "left"
      if ImGui.Selectable(ctx, t("Right"), right_selected) then
        Helpers.set_timecode_offset_direction("right")
      end
      ImGui.EndCombo(ctx)
    end
  else
    ImGui.TextWrapped(ctx, string.format(t("Offset direction: %s"), Helpers.timecode_offset_direction_label(state.last_timecode.offset_direction)))
  end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Offset hours:"))
  ImGui.SameLine(ctx)
  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 42)
  end
  local changed_offset_hours, new_offset_hours =
    ImGui.InputText(ctx, "##dialogue_import_offset_hours", tostring(state.last_timecode.offset_hours_input or ""))
  if changed_offset_hours then
    Helpers.set_timecode_offset_hours_from_input(new_offset_hours)
  end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, t("Offset minutes:"))
  ImGui.SameLine(ctx)
  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 42)
  end
  local changed_offset_minutes, new_offset_minutes =
    ImGui.InputText(ctx, "##dialogue_import_offset_minutes", tostring(state.last_timecode.offset_minutes_input or ""))
  if changed_offset_minutes then
    Helpers.set_timecode_offset_minutes_from_input(new_offset_minutes)
  end
  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.EndDisabled(ctx)
  end

  local single_mode = state.dialogue_import_layout_mode == "single_track"
  local dedicated_mode = state.dialogue_import_layout_mode == "dedicated_tracks"

  if single_mode then
    local changed_track_name, new_track_name =
      ImGui.InputText(ctx, "##dialogue_import_single_track_name", tostring(state.dialogue_import_single_track_name or ""))
    if changed_track_name then
      Helpers.set_dialogue_import_single_track_name(new_track_name)
    end
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, t("Shared track name"))

    local changed_prepend, new_prepend =
      ImGui.Checkbox(ctx, t("Prepend character name to item notes"), state.dialogue_import_prepend_character_name == true)
    if changed_prepend then
      Helpers.set_dialogue_import_prepend_character_name(new_prepend)
    end

    ImGui.TextWrapped(ctx, t("Path A always creates a new shared track and never reuses existing tracks."))
  end

  if dedicated_mode then
    local changed_reuse, new_reuse =
      ImGui.Checkbox(ctx, t("Reuse matching dedicated tracks"), state.dialogue_import_reuse_existing_tracks == true)
    if changed_reuse then
      Helpers.set_dialogue_import_reuse_existing_tracks(new_reuse)
    end

    local changed_color, new_color =
      ImGui.Checkbox(ctx, t("Apply colors to new Path B tracks"), state.dialogue_import_apply_color_policy == true)
    if changed_color then
      Helpers.set_dialogue_import_apply_color_policy(new_color)
    end

    local changed_rec, new_rec =
      ImGui.Checkbox(ctx, t("Add REC track below each character track"), state.dialogue_import_create_rec_track == true)
    if changed_rec then
      Helpers.set_dialogue_import_create_rec_track(new_rec)
    end

    if ImGui.BeginDisabled and ImGui.EndDisabled then
      ImGui.BeginDisabled(ctx, state.dialogue_import_create_rec_track ~= true)
      ImGui.Text(ctx, t("Alt-take tracks below REC:"))
      ImGui.SameLine(ctx)
      if ImGui.SetNextItemWidth then
        ImGui.SetNextItemWidth(ctx, 42)
      end
      local changed_alt, new_alt = ImGui.InputText(
        ctx,
        "##dialogue_import_alt_take_track_count",
        tostring(state.dialogue_import_alt_take_track_count_input or "")
      )
      if changed_alt then
        state.dialogue_import_alt_take_track_count_input = new_alt
        local parsed = tonumber(new_alt)
        if parsed ~= nil then
          local clamped = math.max(0, math.floor(parsed))
          Helpers.set_dialogue_import_alt_take_track_count(clamped)
          if tostring(clamped) ~= new_alt then
            state.dialogue_import_alt_take_track_count_input = tostring(clamped)
          end
        end
      end
      ImGui.EndDisabled(ctx)
    else
      ImGui.Text(ctx, t("Alt-take tracks below REC:"))
      ImGui.SameLine(ctx)
      if ImGui.SetNextItemWidth then
        ImGui.SetNextItemWidth(ctx, 42)
      end
      local changed_alt, new_alt = ImGui.InputText(
        ctx,
        "##dialogue_import_alt_take_track_count",
        tostring(state.dialogue_import_alt_take_track_count_input or "")
      )
      if changed_alt then
        state.dialogue_import_alt_take_track_count_input = new_alt
        local parsed = tonumber(new_alt)
        if parsed ~= nil then
          local clamped = math.max(0, math.floor(parsed))
          Helpers.set_dialogue_import_alt_take_track_count(clamped)
          if tostring(clamped) ~= new_alt then
            state.dialogue_import_alt_take_track_count_input = tostring(clamped)
          end
        end
      end
    end

    local folders_enabled = state.dialogue_import_create_rec_track == true
    if ImGui.BeginDisabled and ImGui.EndDisabled then
      ImGui.BeginDisabled(ctx, not folders_enabled)
      local changed_make_folders, new_make_folders =
        ImGui.Checkbox(ctx, t("Make Folders"), state.dialogue_import_make_folders == true)
      if changed_make_folders then
        Helpers.set_dialogue_import_make_folders(new_make_folders)
      end
      ImGui.EndDisabled(ctx)
    else
      local changed_make_folders, new_make_folders =
        ImGui.Checkbox(ctx, t("Make Folders"), state.dialogue_import_make_folders == true)
      if changed_make_folders then
        Helpers.set_dialogue_import_make_folders(new_make_folders)
      end
    end

    if folders_enabled and state.dialogue_import_make_folders == true then
      local folder_state_label = Helpers.dialogue_import_folder_collapsed_state_label()
      if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
        if ImGui.SetNextItemWidth then
          ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(folder_state_label, 120, 190, 34))
        end
        if ImGui.BeginCombo(ctx, t("Folder collapsed state"), folder_state_label) then
          local normal_selected =
            normalize_dialogue_import_folder_collapsed_state(state.dialogue_import_folder_collapsed_state) == "normal"
          if ImGui.Selectable(ctx, t("normal"), normal_selected) then
            Helpers.set_dialogue_import_folder_collapsed_state("normal")
          end

          local collapsed_selected =
            normalize_dialogue_import_folder_collapsed_state(state.dialogue_import_folder_collapsed_state) == "collapsed"
          if ImGui.Selectable(ctx, t("collapsed"), collapsed_selected) then
            Helpers.set_dialogue_import_folder_collapsed_state("collapsed")
          end

          local fully_collapsed_selected =
            normalize_dialogue_import_folder_collapsed_state(state.dialogue_import_folder_collapsed_state) == "fully_collapsed"
          if ImGui.Selectable(ctx, t("fully collapsed"), fully_collapsed_selected) then
            Helpers.set_dialogue_import_folder_collapsed_state("fully_collapsed")
          end
          ImGui.EndCombo(ctx)
        end
      else
        ImGui.TextWrapped(
          ctx,
          string.format(
            t("Folder collapsed state: %s"),
            Helpers.dialogue_import_folder_collapsed_state_label(state.dialogue_import_folder_collapsed_state)
          )
        )
      end
    end

    ImGui.TextWrapped(
      ctx,
      string.format(
        t("Path B naming: REC_<Character_name> and Alt_Takes_01_<Character_name> ... count %d."),
        tonumber(state.dialogue_import_alt_take_track_count) or 0
      )
    )
  end

  if using_end_timecodes then
    ImGui.TextWrapped(ctx, string.format(t("Timing mode: %s"), t("Source end timecodes")))
  else
    local timing_label =
      (state.dialogue_import_length_mode == "chars_per_second") and t("Chars per second") or t("Fixed length")
    if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
      if ImGui.SetNextItemWidth then
        ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(timing_label, 110, 170, 57))
      end
      if ImGui.BeginCombo(ctx, t("Timing mode"), timing_label) then
        local fixed_selected = state.dialogue_import_length_mode ~= "chars_per_second"
        if ImGui.Selectable(ctx, t("Fixed length"), fixed_selected) then
          Helpers.set_dialogue_import_length_mode("fixed")
        end

        local cps_selected = state.dialogue_import_length_mode == "chars_per_second"
        if ImGui.Selectable(ctx, t("Chars per second"), cps_selected) then
          Helpers.set_dialogue_import_length_mode("chars_per_second")
        end
        ImGui.EndCombo(ctx)
      end
    end

    if state.dialogue_import_length_mode == "chars_per_second" then
      if ImGui.SetNextItemWidth then
        ImGui.SetNextItemWidth(ctx, 157)
      end
      if ImGui.InputDouble then
        local changed_cps, new_cps =
          ImGui.InputDouble(ctx, t("Chars per second"), tonumber(state.dialogue_import_chars_per_second) or 0, 1.0, 5.0, "%.3f")
        if changed_cps then
          Helpers.set_dialogue_import_chars_per_second(new_cps)
        end
      else
        local changed_cps, new_cps_text =
          ImGui.InputText(ctx, t("Chars per second"), tostring(state.dialogue_import_chars_per_second or ""))
        if changed_cps then
          local parsed = tonumber(new_cps_text)
          if parsed ~= nil then
            Helpers.set_dialogue_import_chars_per_second(parsed)
          end
        end
      end
    else
      if ImGui.SetNextItemWidth then
        ImGui.SetNextItemWidth(ctx, 157)
      end
      if ImGui.InputDouble then
        local changed_len, new_len =
          ImGui.InputDouble(ctx, t("Fixed item length (sec)"), tonumber(state.dialogue_import_fixed_length_seconds) or 0, 0.1, 1.0, "%.3f")
        if changed_len then
          Helpers.set_dialogue_import_fixed_length_seconds(new_len)
        end
      else
        local changed_len, new_len_text =
          ImGui.InputText(ctx, t("Fixed item length (sec)"), tostring(state.dialogue_import_fixed_length_seconds or ""))
        if changed_len then
          local parsed = tonumber(new_len_text)
          if parsed ~= nil then
            Helpers.set_dialogue_import_fixed_length_seconds(parsed)
          end
        end
      end
    end
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, 157)
    end
    if ImGui.InputDouble then
      local changed_min_length, new_min_length =
        ImGui.InputDouble(ctx, t("Min item length (sec)"), tonumber(state.dialogue_import_min_item_length_seconds) or 0, 0.1, 1.0, "%.3f")
      if changed_min_length then
        Helpers.set_dialogue_import_min_item_length_seconds(new_min_length)
      end
    else
      local changed_min_length, new_min_length_text =
        ImGui.InputText(ctx, t("Min item length (sec)"), tostring(state.dialogue_import_min_item_length_seconds or ""))
      if changed_min_length then
        local parsed = tonumber(new_min_length_text)
        if parsed ~= nil then
          Helpers.set_dialogue_import_min_item_length_seconds(parsed)
        end
      end
    end
  end
  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 157)
  end
  if ImGui.InputDouble then
    local changed_too_close, new_too_close =
      ImGui.InputDouble(ctx, t("Too close threshold (sec)"), tonumber(state.dialogue_import_too_close_seconds) or 0, 0.05, 0.25, "%.3f")
    if changed_too_close then
      Helpers.set_dialogue_import_too_close_seconds(new_too_close)
    end
  else
    local changed_too_close, new_too_close_text =
      ImGui.InputText(ctx, t("Too close threshold (sec)"), tostring(state.dialogue_import_too_close_seconds or ""))
    if changed_too_close then
      local parsed = tonumber(new_too_close_text)
      if parsed ~= nil then
        Helpers.set_dialogue_import_too_close_seconds(parsed)
      end
    end
  end

  if not using_end_timecodes then
    local overlap_policy_label = Helpers.dialogue_import_overlap_policy_label()
    if ImGui.BeginCombo and ImGui.EndCombo and ImGui.Selectable then
      if ImGui.SetNextItemWidth then
        ImGui.SetNextItemWidth(ctx, Helpers.tight_combo_width(overlap_policy_label, 110, 170, 34))
      end
      if ImGui.BeginCombo(ctx, t("Overlap policy"), overlap_policy_label) then
        local allow_selected = normalize_dialogue_import_overlap_policy(state.dialogue_import_overlap_policy) == "allow"
        if ImGui.Selectable(ctx, t("Allow overlaps"), allow_selected) then
          Helpers.set_dialogue_import_overlap_policy("allow")
        end

        local shrink_selected = normalize_dialogue_import_overlap_policy(state.dialogue_import_overlap_policy) == "shrink_to_fit_best_effort"
        if ImGui.Selectable(ctx, t("Shrink to fit"), shrink_selected) then
          Helpers.set_dialogue_import_overlap_policy("shrink_to_fit_best_effort")
        end
        ImGui.EndCombo(ctx)
      end
    else
      ImGui.TextWrapped(ctx, string.format(t("Overlap policy: %s"), overlap_policy_label))
    end

    if normalize_dialogue_import_overlap_policy(state.dialogue_import_overlap_policy) == "shrink_to_fit_best_effort" then
      ImGui.TextWrapped(ctx, t("When two items on the same destination track would overlap, preflight shrinks the earlier item toward the next start."))
    else
      ImGui.TextWrapped(ctx, t("Overlaps are checked per destination track and reported as warnings without changing item length."))
    end
  end

  if ImGui.Button(ctx, t("Run Preflight")) then
    TestCases.run_dialogue_import_preflight_test()
  end

  if Helpers.dialogue_import_has_fresh_preflight() then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Apply Import")) then
      TestCases.run_dialogue_import_apply_test()
    end
  end

  local import_state = state.last_dialogue_import
  if import_state.preflight_is_stale == true then
    UI.ui_warning(t("Import settings changed. Run Preflight again."))
  elseif import_state.preflight_has_run ~= true then
    UI.ui_info(t("Run Preflight to inspect blockers, warnings, and the destination plan before importing."))
  end

  if Util.trim(tostring(import_state.last_apply_message or "")) ~= "" then
    if import_state.last_apply_ok == true then
      UI.ui_info(import_state.last_apply_message)
    else
      UI.ui_error(import_state.last_apply_message)
    end
  end

  local report = import_state.preflight_report
  if type(report) ~= "table" then
    return
  end

  UI.set_separator_text(t("Preflight Summary"))
  UI.ui_info(Helpers.dialogue_import_preflight_summary_text(report))
  local time_span = report.time_span or {}
  UI.ui_info(
    string.format(
      t("Import span: %s -> %s"),
      Util.trim(tostring(time_span.start_timecode or "")) ~= "" and tostring(time_span.start_timecode) or Helpers.format_project_timecode(time_span.start_seconds),
      Util.trim(tostring(time_span.end_timecode or "")) ~= "" and tostring(time_span.end_timecode) or Helpers.format_project_timecode(time_span.end_seconds)
    )
  )

  UI.set_separator_text(t("Blockers"))
  local blockers = report.blockers or {}
  if #blockers == 0 then
    UI.ui_info(t("None."))
  else
    for i = 1, #blockers do
      UI.ui_error(blockers[i])
    end
  end

  UI.set_separator_text(t("Warnings"))
  local warnings = report.warnings or {}
  if #warnings == 0 then
    UI.ui_info(t("None."))
  else
    for i = 1, #warnings do
      UI.ui_warning(warnings[i])
    end
  end

  UI.render_dialogue_import_track_plan(report)
  UI.render_dialogue_import_item_plan(report)
end

function UI.render_character_summary()
  UI.set_separator_text(t("Character Summary"))
  if state.last_timecode.finalized == true then
    ImGui.TextWrapped(ctx, t("Character summary is hidden while timecode review is active."))
    return
  end
  if not state.last_cast.ok then
    ImGui.TextWrapped(ctx, t("No character summary available for the current run."))
    return
  end
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, t("Table rendering is not available in this ReaImGui build."))
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY
  local table_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 10) or 220
  if ImGui.BeginTable(ctx, "##docx_import_01_character_summary_table", 4, table_flags, -1, table_h) then
    ImGui.TableSetupColumn(ctx, t("ID"), ImGui.TableColumnFlags_WidthFixed, 48)
    ImGui.TableSetupColumn(ctx, t("Name"), ImGui.TableColumnFlags_WidthStretch, 3.0)
    ImGui.TableSetupColumn(ctx, t("Count"), ImGui.TableColumnFlags_WidthFixed, 64)
    ImGui.TableSetupColumn(ctx, t("Raw Variants"), ImGui.TableColumnFlags_WidthFixed, 90)
    if ImGui.TableSetupScrollFreeze then
      ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    end
    ImGui.TableHeadersRow(ctx)

    local visible_characters = Helpers.visible_characters()
    for i = 1, #visible_characters do
      local item = visible_characters[i]
      local selected = state.last_cast.selected_character_id == item.id
      ImGui.TableNextRow(ctx)

      ImGui.TableSetColumnIndex(ctx, 0)
      if ImGui.Selectable(ctx, tostring(item.id) .. "##char_select_" .. tostring(item.id), selected) then
        state.last_cast.selected_character_id = item.id
        state.last_cast.selected_merge_candidate_index = nil
      end

      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.TextWrapped(ctx, tostring(item.name))

      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.Text(ctx, tostring(item.count))

      ImGui.TableSetColumnIndex(ctx, 3)
      ImGui.Text(ctx, tostring(Helpers.count_raw_variants(item.raw_names_captured)))
    end

    ImGui.EndTable(ctx)
  end

end

function UI.render_merge_candidates()
  UI.set_separator_text(t("Merge Candidates"))
  if state.last_timecode.finalized == true then
    ImGui.TextWrapped(ctx, t("Merge controls are hidden while timecode review is active."))
    return
  end
  if not state.last_cast.ok then
    ImGui.TextWrapped(ctx, t("No merge candidate data available for the current run."))
    return
  end

  local merge_enabled = state.last_cast.ok == true
  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, not merge_enabled)
    if ImGui.Button(ctx, t("Apply Selected Merge")) then
      Helpers.apply_selected_merge()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Undo Last Merge")) then
      Helpers.undo_last_merge()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Reset Merges")) then
      Helpers.reset_applied_merges()
    end
    ImGui.EndDisabled(ctx)
  else
    if ImGui.Button(ctx, t("Apply Selected Merge")) then
      Helpers.apply_selected_merge()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Undo Last Merge")) then
      Helpers.undo_last_merge()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Reset Merges")) then
      Helpers.reset_applied_merges()
    end
  end

  local selected_candidate = Helpers.visible_merge_candidates()[state.last_cast.selected_merge_candidate_index or 0]
  if selected_candidate then
    ImGui.TextWrapped(
      ctx,
      string.format(
        t("Selected candidate: #%s -> #%s (distance=%s)"),
        tostring(selected_candidate.typo_id),
        tostring(selected_candidate.canonical_id),
        tostring(selected_candidate.distance)
      )
    )
  else
    ImGui.TextWrapped(ctx, t("Select a merge candidate to focus the rows table or apply it."))
  end

  UI.set_separator_text(t("Applied Merges"))
  local applied_merges = state.last_cast.applied_merges or {}
  if #applied_merges == 0 then
    ImGui.TextWrapped(ctx, t("No merges have been applied in this run."))
  elseif not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, t("Table rendering is not available in this ReaImGui build."))
  else
    local history_flags =
      ImGui.TableFlags_Borders |
      ImGui.TableFlags_RowBg |
      ImGui.TableFlags_Resizable |
      ImGui.TableFlags_ScrollY
    local history_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 6) or 140
    if ImGui.BeginTable(ctx, "##docx_import_01_applied_merges_table", 6, history_flags, -1, history_h) then
      ImGui.TableSetupColumn(ctx, t("Step"), ImGui.TableColumnFlags_WidthFixed, 50)
      ImGui.TableSetupColumn(ctx, t("Canonical ID"), ImGui.TableColumnFlags_WidthFixed, 90)
      ImGui.TableSetupColumn(ctx, t("Canonical Name"), ImGui.TableColumnFlags_WidthStretch, 2.0)
      ImGui.TableSetupColumn(ctx, t("Typo ID"), ImGui.TableColumnFlags_WidthFixed, 70)
      ImGui.TableSetupColumn(ctx, t("Typo Name"), ImGui.TableColumnFlags_WidthStretch, 2.0)
      ImGui.TableSetupColumn(ctx, t("Distance"), ImGui.TableColumnFlags_WidthFixed, 70)
      if ImGui.TableSetupScrollFreeze then
        ImGui.TableSetupScrollFreeze(ctx, 0, 1)
      end
      ImGui.TableHeadersRow(ctx)

      for i = 1, #applied_merges do
        local item = applied_merges[i]
        local canonical = Helpers.find_base_character_by_id(item.canonical_id) or {}
        local typo = Helpers.find_base_character_by_id(item.typo_id) or {}

        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.Text(ctx, tostring(i))
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, tostring(item.canonical_id))
        ImGui.TableSetColumnIndex(ctx, 2)
        ImGui.TextWrapped(ctx, tostring(canonical.name or ""))
        ImGui.TableSetColumnIndex(ctx, 3)
        ImGui.Text(ctx, tostring(item.typo_id))
        ImGui.TableSetColumnIndex(ctx, 4)
        ImGui.TextWrapped(ctx, tostring(typo.name or ""))
        ImGui.TableSetColumnIndex(ctx, 5)
        ImGui.Text(ctx, tostring(item.distance))
      end

      ImGui.EndTable(ctx)
    end
  end

  local visible_merge_candidates = Helpers.visible_merge_candidates()
  if #visible_merge_candidates == 0 then
    ImGui.TextWrapped(ctx, t("No merge candidates for the current settings."))
    return
  end
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, t("Table rendering is not available in this ReaImGui build."))
    return
  end

  local by_id = Helpers.character_lookup_by_id(Helpers.visible_characters())
  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_ScrollX
  local table_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 8) or 180
  if ImGui.BeginTable(ctx, "##docx_import_01_merge_candidates_table", 7, table_flags, -1, table_h) then
    ImGui.TableSetupColumn(ctx, t("Canonical ID"), ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, t("Canonical Name"), ImGui.TableColumnFlags_WidthStretch, 2.0)
    ImGui.TableSetupColumn(ctx, t("Typo ID"), ImGui.TableColumnFlags_WidthFixed, 70)
    ImGui.TableSetupColumn(ctx, t("Typo Name"), ImGui.TableColumnFlags_WidthStretch, 2.0)
    ImGui.TableSetupColumn(ctx, t("Distance"), ImGui.TableColumnFlags_WidthFixed, 70)
    ImGui.TableSetupColumn(ctx, t("Canonical Count"), ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, t("Typo Count"), ImGui.TableColumnFlags_WidthFixed, 80)
    if ImGui.TableSetupScrollFreeze then
      ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    end
    ImGui.TableHeadersRow(ctx)

    for i = 1, #visible_merge_candidates do
      local item = visible_merge_candidates[i]
      local canonical = by_id[item.canonical_id] or {}
      local typo = by_id[item.typo_id] or {}
      local selected = state.last_cast.selected_merge_candidate_index == i

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      if ImGui.Selectable(ctx, tostring(item.canonical_id) .. "##merge_select_" .. tostring(i), selected) then
        state.last_cast.selected_merge_candidate_index = i
        state.last_cast.selected_character_id = nil
      end

      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.TextWrapped(ctx, tostring(canonical.name or ""))

      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.Text(ctx, tostring(item.typo_id))

      ImGui.TableSetColumnIndex(ctx, 3)
      ImGui.TextWrapped(ctx, tostring(typo.name or ""))

      ImGui.TableSetColumnIndex(ctx, 4)
      ImGui.Text(ctx, tostring(item.distance))

      ImGui.TableSetColumnIndex(ctx, 5)
      ImGui.Text(ctx, tostring(canonical.count or 0))

      ImGui.TableSetColumnIndex(ctx, 6)
      ImGui.Text(ctx, tostring(typo.count or 0))
    end

    ImGui.EndTable(ctx)
  end
end

function UI.render_full_raw_table()
  UI.set_separator_text(t("Parsed Table"))
  local rows = state.last_preflight.visible_rows or {}
  local row_meta = state.last_preflight.visible_row_metadata or {}
  local column_count = Helpers.column_count()

  if state.last_parse.ok ~= true or column_count < 1 then
    ImGui.TextWrapped(ctx, t("No parsed table is available yet."))
    return
  end
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, t("Table rendering is not available in this ReaImGui build."))
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_ScrollX
  local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
  local total_w = math.max(700, tonumber(avail_w) or 0)
  local fallback_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 18) or 300
  local table_h = math.max(fallback_h, (avail_h or 0) - 180)
  local show_end_timecode_column = Helpers.use_end_timecodes_enabled()
  local total_columns = column_count + 1 + (show_end_timecode_column and 1 or 0)

  if ImGui.BeginTable(ctx, "##docx_import_01_full_raw_table", total_columns, table_flags, avail_w, table_h) then
    ImGui.TableSetupColumn(
      ctx,
      t("Row"),
      ImGui.TableColumnFlags_WidthFixed,
      Helpers.percent_width(total_w, 0.05, 1)
    )
    for col_idx = 1, column_count do
      local role = Helpers.column_primary_role(col_idx)
      if role == "TC" then
        ImGui.TableSetupColumn(
          ctx,
          "##col_" .. tostring(col_idx),
          ImGui.TableColumnFlags_WidthFixed,
          Helpers.percent_width(total_w, 0.07, 1)
        )
        if show_end_timecode_column then
          ImGui.TableSetupColumn(
            ctx,
            "##end_timecode_col_" .. tostring(col_idx),
            ImGui.TableColumnFlags_WidthFixed,
            Helpers.percent_width(total_w, 0.07, 1)
          )
        end
      elseif role == "CHAR" then
        ImGui.TableSetupColumn(
          ctx,
          "##col_" .. tostring(col_idx),
          ImGui.TableColumnFlags_WidthFixed,
          Helpers.percent_width(total_w, 0.12, 1)
        )
      elseif role == "DLG" then
        ImGui.TableSetupColumn(
          ctx,
          "##col_" .. tostring(col_idx),
          ImGui.TableColumnFlags_WidthStretch,
          1.0
        )
      else
        ImGui.TableSetupColumn(
          ctx,
          "##col_" .. tostring(col_idx),
          ImGui.TableColumnFlags_WidthFixed,
          Helpers.percent_width(total_w, 0.08, 110)
        )
      end
    end
    if ImGui.TableSetupScrollFreeze then
      ImGui.TableSetupScrollFreeze(ctx, 1, 1)
    end

    ImGui.TableNextRow(ctx)
    ImGui.TableSetColumnIndex(ctx, 0)
    ImGui.Text(ctx, t("Row"))
    local display_col_idx = 1
    for col_idx = 1, column_count do
      local fg_color, bg_color = Helpers.column_role_color(col_idx)
      ImGui.TableSetColumnIndex(ctx, display_col_idx)
      if ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg and bg_color ~= nil then
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, bg_color)
      end
      if fg_color ~= nil then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, fg_color)
      end
      ImGui.PushTextWrapPos(ctx, 0.0)
      ImGui.Text(ctx, Helpers.table_header_label(col_idx))
      ImGui.PopTextWrapPos(ctx)
      if fg_color ~= nil then
        ImGui.PopStyleColor(ctx)
      end
      display_col_idx = display_col_idx + 1

      if show_end_timecode_column and col_idx == tonumber(state.last_preflight.selected_timecode_col) then
        ImGui.TableSetColumnIndex(ctx, display_col_idx)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x40D0FFFF)
        ImGui.PushTextWrapPos(ctx, 0.0)
        ImGui.Text(ctx, t("END"))
        ImGui.PopTextWrapPos(ctx)
        ImGui.PopStyleColor(ctx)
        display_col_idx = display_col_idx + 1
      end
    end

    for visible_idx = 1, #rows do
      local row = rows[visible_idx] or {}
      local meta = row_meta[visible_idx] or {}
      ImGui.TableNextRow(ctx)

      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, tostring(meta.raw_row_index or visible_idx))

      display_col_idx = 1
      for col_idx = 1, column_count do
        local fg_color, bg_color = Helpers.column_role_color(col_idx)
        local is_timecode_col = col_idx == tonumber(state.last_preflight.selected_timecode_col)
        ImGui.TableSetColumnIndex(ctx, display_col_idx)
        if ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg and bg_color ~= nil then
          ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, bg_color)
        end
        if fg_color ~= nil then
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, fg_color)
        end
        if is_timecode_col then
          local cell_text = tostring(row[col_idx] or "")
          ImGui.PushTextWrapPos(ctx, 0.0)
          ImGui.Text(ctx, cell_text)
          ImGui.PopTextWrapPos(ctx)
        else
          ImGui.PushTextWrapPos(ctx, 0.0)
          ImGui.Text(ctx, tostring(row[col_idx] or ""))
          ImGui.PopTextWrapPos(ctx)
        end
        if fg_color ~= nil then
          ImGui.PopStyleColor(ctx)
        end
        display_col_idx = display_col_idx + 1

        if show_end_timecode_column and is_timecode_col then
          ImGui.TableSetColumnIndex(ctx, display_col_idx)
          if ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg and bg_color ~= nil then
            ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, bg_color)
          end
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x40D0FFFF)
          ImGui.PushTextWrapPos(ctx, 0.0)
          ImGui.Text(ctx, Helpers.end_timecode_from_visible_metadata(meta))
          ImGui.PopTextWrapPos(ctx)
          ImGui.PopStyleColor(ctx)
          display_col_idx = display_col_idx + 1
        end
      end
    end

    ImGui.EndTable(ctx)
  end
end

function UI.render_mapped_cast_table()
  UI.set_separator_text(t("Mapped Rows"))
  local script_rows, source_row_numbers = Helpers.build_mapped_script_rows()
  if #script_rows == 0 then
    ImGui.TextWrapped(ctx, t("No mapped rows are available yet."))
    return
  end
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, t("Table rendering is not available in this ReaImGui build."))
    return
  end

  local filtered_indices = Helpers.filtered_row_indices(#script_rows)
  local filter_label = t("All mapped rows")
  if state.last_cast.selected_character_id ~= nil then
    local selected = Helpers.find_character_by_id(state.last_cast.selected_character_id)
    filter_label = string.format(t("Filtered to character: %s"), tostring(selected and selected.name or state.last_cast.selected_character_id))
  elseif state.last_cast.selected_merge_candidate_index ~= nil then
    local item = Helpers.visible_merge_candidates()[state.last_cast.selected_merge_candidate_index]
    local canonical = item and Helpers.find_character_by_id(item.canonical_id) or nil
    local typo = item and Helpers.find_character_by_id(item.typo_id) or nil
    filter_label = string.format(
      t("Filtered to merge pair: %s + %s"),
      tostring(canonical and canonical.name or ""),
      tostring(typo and typo.name or "")
    )
  end

  ImGui.TextWrapped(ctx, string.format(t("%s | showing %d of %d rows"), filter_label, #filtered_indices, #script_rows))
  if ImGui.Button(ctx, t("Clear selection")) then
    Helpers.clear_cast_selection()
    filtered_indices = Helpers.filtered_row_indices(#script_rows)
  end
  ImGui.SameLine(ctx)
  local can_finalize = state.last_cast.ok == true
  local finalized_now = false
  if ImGui.BeginDisabled and ImGui.EndDisabled then
    ImGui.BeginDisabled(ctx, not can_finalize)
    if ImGui.Button(ctx, t("Finalize Cast")) then
      Helpers.finalize_cast_for_timecodes()
      if state.last_timecode.finalized == true then
        finalized_now = true
      end
    end
    ImGui.EndDisabled(ctx)
  else
    if can_finalize and ImGui.Button(ctx, t("Finalize Cast")) then
      Helpers.finalize_cast_for_timecodes()
      if state.last_timecode.finalized == true then
        finalized_now = true
      end
    end
  end
  if finalized_now then
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_ScrollX
  local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
  local total_w = math.max(700, tonumber(avail_w) or 0)
  local fallback_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 18) or 280
  local table_h = math.max(fallback_h, (avail_h or 0) - 180)
  local use_end_timecodes = Helpers.use_end_timecodes_enabled()
  local mapped_column_count = use_end_timecodes and 7 or 6
  if ImGui.BeginTable(ctx, "##docx_import_01_mapped_rows_table", mapped_column_count, table_flags, avail_w, table_h) then
    ImGui.TableSetupColumn(ctx, t("Row"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.05, 48))
    ImGui.TableSetupColumn(ctx, use_end_timecodes and t("Start") or t("Timecode"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.08, 100))
    if use_end_timecodes then
      ImGui.TableSetupColumn(ctx, t("End"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.08, 100))
    end
    ImGui.TableSetupColumn(ctx, t("Raw Character"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.12, 120))
    ImGui.TableSetupColumn(ctx, t("Resolved Group"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.09, 90))
    ImGui.TableSetupColumn(ctx, t("Canonical Name"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.14, 140))
    ImGui.TableSetupColumn(ctx, t("Dialogue"), ImGui.TableColumnFlags_WidthStretch, 5.0)
    if ImGui.TableSetupScrollFreeze then
      ImGui.TableSetupScrollFreeze(ctx, 1, 1)
    end
    ImGui.TableHeadersRow(ctx)

    local row_links = Helpers.visible_row_links()
    for i = 1, #filtered_indices do
      local row_index = filtered_indices[i]
      local row = script_rows[row_index] or {}
      local row_link = row_links[row_index] or {}
      local source_row_index = row_link.source_row_index or source_row_numbers[row_index] or row_index
      ImGui.TableNextRow(ctx)

      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, tostring(source_row_index))

      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.PushTextWrapPos(ctx, 0.0)
      ImGui.Text(ctx, tostring(row.timecode or ""))
      ImGui.PopTextWrapPos(ctx)

      if use_end_timecodes then
        ImGui.TableSetColumnIndex(ctx, 2)
        ImGui.PushTextWrapPos(ctx, 0.0)
        ImGui.Text(ctx, tostring(row.end_timecode or ""))
        ImGui.PopTextWrapPos(ctx)
      end

      ImGui.TableSetColumnIndex(ctx, use_end_timecodes and 3 or 2)
      ImGui.TextWrapped(ctx, tostring(row.character_name or ""))

      ImGui.TableSetColumnIndex(ctx, use_end_timecodes and 4 or 3)
      ImGui.Text(ctx, tostring(row_link.resolved_group or ""))

      ImGui.TableSetColumnIndex(ctx, use_end_timecodes and 5 or 4)
      ImGui.TextWrapped(ctx, tostring(row_link.canonical_name or ""))

      ImGui.TableSetColumnIndex(ctx, use_end_timecodes and 6 or 5)
      ImGui.PushTextWrapPos(ctx, 0.0)
      ImGui.Text(ctx, tostring(row.character_line or ""))
      ImGui.PopTextWrapPos(ctx)
    end

    ImGui.EndTable(ctx)
  end
end

function Helpers.timecode_row_bg_color(row)
  local status = row and row.status or ""
  if status == "bad" then
    return 0x404060C0
  end
  if status == "inconsistent" then
    return 0x4050B0D0
  end
  if row and row.fps_warning == true then
    return 0x4060B0D0
  end
  return nil
end

function UI.render_timecode_review_table()
  UI.set_separator_text(t("Timecode Review Rows"))
  local last = state.last_timecode
  local rows = last.rows or {}
  if #rows == 0 then
    ImGui.TextWrapped(ctx, t("No finalized rows are available yet."))
    return
  end
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, t("Table rendering is not available in this ReaImGui build."))
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_ScrollX
  local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
  local total_w = math.max(700, tonumber(avail_w) or 0)
  local fallback_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 18) or 280
  local table_h = math.max(fallback_h, (avail_h or 0) - 180)
  local scroll_target = last.pending_scroll_row_index
  local did_scroll = false
  local use_end_timecodes = last.use_end_timecodes == true
  local review_column_count = use_end_timecodes and 5 or 4

  if ImGui.BeginTable(ctx, "##docx_import_01_timecode_review_table", review_column_count, table_flags, avail_w, table_h) then
    ImGui.TableSetupColumn(ctx, t("Row"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.05, 48))
    if use_end_timecodes then
      ImGui.TableSetupColumn(ctx, t("START"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.10, 118))
      ImGui.TableSetupColumn(ctx, t("END"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.10, 118))
      ImGui.TableSetupColumn(ctx, t("CHAR"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.14, 140))
      ImGui.TableSetupColumn(ctx, t("DLG"), ImGui.TableColumnFlags_WidthStretch, 5.0)
    else
      ImGui.TableSetupColumn(ctx, t("TC"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.12, 130))
      ImGui.TableSetupColumn(ctx, t("CHAR"), ImGui.TableColumnFlags_WidthFixed, Helpers.percent_width(total_w, 0.14, 140))
      ImGui.TableSetupColumn(ctx, t("DLG"), ImGui.TableColumnFlags_WidthStretch, 5.0)
    end
    if ImGui.TableSetupScrollFreeze then
      ImGui.TableSetupScrollFreeze(ctx, 1, 1)
    end
    ImGui.TableHeadersRow(ctx)

    for row_index = 1, #rows do
      local row = rows[row_index]
      local row_bg = Helpers.timecode_row_bg_color(row)
      ImGui.TableNextRow(ctx)

      ImGui.TableSetColumnIndex(ctx, 0)
      if row_bg ~= nil and ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg then
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, row_bg)
      end
      ImGui.Text(ctx, tostring(row.source_row_index or row_index))

      ImGui.TableSetColumnIndex(ctx, 1)
      if row_bg ~= nil and ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg then
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, row_bg)
      end
      local timecode_text = tostring(row.raw_timecode_text or "")
      local timecode_h = Helpers.multiline_display_height(timecode_text)
      if ImGui.SetNextItemWidth then
        ImGui.SetNextItemWidth(ctx, -1)
      end
      if row_bg ~= nil then
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, row_bg)
      end
      if last.final_look_applied == true then
        ImGui.InputTextMultiline(
          ctx,
          "##timecode_view_" .. tostring(row.row_key or row.source_row_index),
          timecode_text,
          -1,
          timecode_h,
          ImGui.InputTextFlags_ReadOnly or 0
        )
      else
        local changed_tc, new_tc =
          ImGui.InputTextMultiline(
            ctx,
            "##timecode_edit_" .. tostring(row.row_key or row.source_row_index),
            timecode_text,
            -1,
            timecode_h
          )
        if changed_tc then
          Helpers.set_timecode_text(row_index, new_tc)
        end
      end
      if row_bg ~= nil then
        ImGui.PopStyleColor(ctx)
      end

      if use_end_timecodes then
        ImGui.TableSetColumnIndex(ctx, 2)
        if row_bg ~= nil and ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg then
          ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, row_bg)
        end
        local end_timecode_text = tostring(row.raw_end_timecode_text or "")
        local end_timecode_h = Helpers.multiline_display_height(end_timecode_text)
        if ImGui.SetNextItemWidth then
          ImGui.SetNextItemWidth(ctx, -1)
        end
        if row_bg ~= nil then
          ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, row_bg)
        end
        if last.final_look_applied == true then
          ImGui.InputTextMultiline(
            ctx,
            "##end_timecode_view_" .. tostring(row.row_key or row.source_row_index),
            end_timecode_text,
            -1,
            end_timecode_h,
            ImGui.InputTextFlags_ReadOnly or 0
          )
        else
          local changed_end_tc, new_end_tc =
            ImGui.InputTextMultiline(
              ctx,
              "##end_timecode_edit_" .. tostring(row.row_key or row.source_row_index),
              end_timecode_text,
              -1,
              end_timecode_h
            )
          if changed_end_tc then
            Helpers.set_end_timecode_text(row_index, new_end_tc)
          end
        end
        if row_bg ~= nil then
          ImGui.PopStyleColor(ctx)
        end
      end

      ImGui.TableSetColumnIndex(ctx, use_end_timecodes and 3 or 2)
      if row_bg ~= nil and ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg then
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, row_bg)
      end
      ImGui.TextWrapped(ctx, tostring(row.canonical_name or ""))

      ImGui.TableSetColumnIndex(ctx, use_end_timecodes and 4 or 3)
      if row_bg ~= nil and ImGui.TableSetBgColor and ImGui.TableBgTarget_CellBg then
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, row_bg)
      end
      ImGui.PushTextWrapPos(ctx, 0.0)
      ImGui.Text(ctx, tostring(row.dialogue or ""))
      ImGui.PopTextWrapPos(ctx)

      if scroll_target ~= nil and row_index == scroll_target and ImGui.SetScrollHereY then
        ImGui.SetScrollHereY(ctx, 0.25)
        did_scroll = true
      end
    end

    ImGui.EndTable(ctx)
  end

  if did_scroll then
    last.pending_scroll_row_index = nil
  end
end

function UI.render_main_rows_table()
  if state.last_timecode.finalized == true then
    UI.render_timecode_review_table()
  elseif state.last_preflight.confirmed == true then
    UI.render_mapped_cast_table()
  else
    UI.render_full_raw_table()
  end
end

function UI.render_result_log()
  UI.set_separator_text(t("Rolling Result Log"))
  local log_line_h = ImGui.GetTextLineHeightWithSpacing and ImGui.GetTextLineHeightWithSpacing(ctx) or 20
  local log_h = log_line_h * 7
  local start_index = math.max(1, #state.rolling_log_lines - 89)
  local visible_lines = {}
  for i = start_index, #state.rolling_log_lines do
    visible_lines[#visible_lines + 1] = state.rolling_log_lines[i]
  end
  local log_text = table.concat(visible_lines, "\n")
  local flags = ImGui.InputTextFlags_ReadOnly or 0
  ImGui.InputTextMultiline(ctx, "##docx_import_01_result_log_view", log_text, -1, log_h, flags)
end

function UI.render_details_panel()
  if not ImGui.CollapsingHeader(ctx, t("Details (errors, status)")) then
    return
  end

  local detail_lines = {
    string.format(t("Technical status: %s"), tostring(state.technical_status_text ~= "" and state.technical_status_text or t("(none)"))),
    string.format(t("DOCX path: %s"), tostring(state.docx_path ~= "" and state.docx_path or t("(none)"))),
    string.format(t("Output root: %s"), tostring(state.output_root ~= "" and state.output_root or t("(none)"))),
    string.format(t("Log root: %s"), tostring(runtime.log_root or t("(none)"))),
    string.format(t("Extract ok: %s"), Helpers.readable_bool(state.last_extract.ok)),
    string.format(t("Parse ok: %s"), Helpers.readable_bool(state.last_parse.ok)),
    string.format(t("Source format requested: %s"), tostring(docx_source_mode_item(state.last_parse.source_mode_requested).label)),
    string.format(t("Source format detected: %s"), tostring(docx_source_mode_item(state.last_parse.source_mode_detected).label)),
    string.format(t("Parsed rows: %s"), tostring(state.last_parse.number_of_rows or 0)),
    string.format(t("Parsed columns: %s"), tostring(state.last_parse.number_of_columns or 0)),
    string.format(t("Parsed rows with end timecodes: %s"), tostring(state.last_parse.end_timecode_count or 0)),
    string.format(t("Use end timecodes: %s"), Helpers.readable_bool(Helpers.use_end_timecodes_enabled())),
    string.format(t("Parser warnings: %s"), tostring(state.last_parse.warning_count or 0)),
    string.format(t("Empty character rows: %s"), tostring(state.last_parse.empty_character_row_count or 0)),
    string.format(t("Mapping confirmed: %s"), Helpers.readable_bool(state.last_preflight.confirmed == true)),
    string.format(t("Mapped rows: %s"), tostring(state.last_preflight.mapped_row_count or 0)),
    string.format(t("Cast ok: %s"), Helpers.readable_bool(state.last_cast.ok)),
    string.format(t("Character groups: %s"), tostring(state.last_cast.merged_view.character_count or 0)),
    string.format(t("Merge candidates: %s"), tostring(state.last_cast.merged_view.merge_candidate_count or 0)),
    string.format(t("Timecodes finalized: %s"), Helpers.readable_bool(state.last_timecode.finalized == true)),
    string.format(t("Timecodes validated: %s"), Helpers.readable_bool(state.last_timecode.has_validated == true)),
    string.format(t("Bad timecodes: %s"), tostring(state.last_timecode.bad_count or 0)),
    string.format(t("Inconsistent timecodes: %s"), tostring(state.last_timecode.inconsistent_count or 0)),
    string.format(t("FPS-aware check ran: %s"), Helpers.readable_bool(state.last_timecode.fps_check_ran == true)),
    string.format(t("FPS-aware warnings: %s"), tostring(state.last_timecode.fps_warning_count or 0)),
    string.format(t("Project FPS: %s"), tostring(state.last_timecode.project_frame_rate or t("(nil)"))),
    string.format(t("Source FPS: %s"), tostring(state.last_timecode.source_fps_input ~= "" and state.last_timecode.source_fps_input or t("(blank)"))),
    string.format(t("Project drop-frame: %s"), Helpers.readable_bool(state.last_timecode.project_drop_frame == true)),
    string.format(t("Offset enabled: %s"), Helpers.readable_bool(state.last_timecode.offset_enabled == true)),
    string.format(t("Offset direction: %s"), Helpers.timecode_offset_direction_label(state.last_timecode.offset_direction)),
    string.format(t("Offset text: %s"), tostring(state.last_timecode.offset_timecode_text or "00:00:00:00")),
    string.format(t("Offset seconds: %s"), tostring(state.last_timecode.offset_project_seconds or 0)),
    string.format(t("Import-ready rows: %s"), tostring(#(state.import_ready_rows or {}))),
    string.format(t("Dialogue import layout: %s"), Helpers.dialogue_import_layout_label()),
    string.format(t("Shared track name: %s"), tostring(state.dialogue_import_single_track_name or "")),
    string.format(t("Reuse dedicated tracks: %s"), Helpers.readable_bool(state.dialogue_import_reuse_existing_tracks == true)),
    string.format(t("Apply color policy: %s"), Helpers.readable_bool(state.dialogue_import_apply_color_policy == true)),
    string.format(t("Prepend character name: %s"), Helpers.readable_bool(state.dialogue_import_prepend_character_name == true)),
    string.format(t("Create REC track: %s"), Helpers.readable_bool(state.dialogue_import_create_rec_track == true)),
    string.format(t("Alt-take track count: %s"), tostring(state.dialogue_import_alt_take_track_count or 0)),
    string.format(t("Make folders: %s"), Helpers.readable_bool(state.dialogue_import_make_folders == true)),
    string.format(
      t("Folder collapsed state: %s"),
      Helpers.dialogue_import_folder_collapsed_state_label(state.dialogue_import_folder_collapsed_state)
    ),
    string.format(t("Timing mode: %s"), Helpers.dialogue_import_length_mode_label(state.dialogue_import_length_mode)),
    string.format(t("Fixed item length: %s"), Helpers.use_end_timecodes_enabled() and t("(disabled)") or tostring(state.dialogue_import_fixed_length_seconds or 0)),
    string.format(t("Chars per second: %s"), Helpers.use_end_timecodes_enabled() and t("(disabled)") or tostring(state.dialogue_import_chars_per_second or 0)),
    string.format(t("Min item length: %s"), Helpers.use_end_timecodes_enabled() and t("(disabled)") or tostring(state.dialogue_import_min_item_length_seconds or 0)),
    string.format(t("Too close threshold: %s"), tostring(state.dialogue_import_too_close_seconds or 0)),
    string.format(t("Overlap policy: %s"), Helpers.use_end_timecodes_enabled() and t("(disabled)") or Helpers.dialogue_import_overlap_policy_label()),
    string.format(t("Add warning markers: %s"), Helpers.readable_bool(state.dialogue_import_add_warning_markers == true)),
    string.format(t("Import preflight ran: %s"), Helpers.readable_bool(state.last_dialogue_import.preflight_has_run == true)),
    string.format(t("Import preflight stale: %s"), Helpers.readable_bool(state.last_dialogue_import.preflight_is_stale == true)),
    string.format(t("Import apply ok: %s"), Helpers.readable_bool(state.last_dialogue_import.last_apply_ok))
  }
  local details_text = table.concat(detail_lines, "\n")
  ImGui.InputTextMultiline(ctx, "##docx_import_tool_details_summary", details_text, -1, 220, ImGui.InputTextFlags_ReadOnly or 0)
  UI.render_result_log()
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

function UI.render_diagnostics_settings()
  local diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Logging threshold") .. ":")
  ImGui.SameLine(ctx)
  if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(ctx, 160) end
  if ImGui.BeginCombo(ctx, "##docx_import_logging_threshold", diagnostics_threshold_label(diagnostics.logging_threshold)) then
    for _, level in ipairs({ 4, 0, 1, 2, 3 }) do
      local selected = diagnostics.logging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_logging_threshold(level)
        if not ok_set then Helpers.log_step("settings", string.format(t("Logging threshold save failed: %s"), tostring(err)), 2) end
      end
      if selected and ImGui.SetItemDefaultFocus then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Messaging threshold") .. ":")
  ImGui.SameLine(ctx)
  if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(ctx, 160) end
  if ImGui.BeginCombo(ctx, "##docx_import_messaging_threshold", diagnostics_threshold_label(diagnostics.messaging_threshold)) then
    for _, level in ipairs({ 0, 1, 2, 3, 4 }) do
      local selected = diagnostics.messaging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_messaging_threshold(level)
        if not ok_set then Helpers.log_step("settings", string.format(t("Messaging threshold save failed: %s"), tostring(err)), 2) end
      end
      if selected and ImGui.SetItemDefaultFocus then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  UI.ui_info(string.format(t("Log folder: %s"), diagnostics.log_dir))
  UI.ui_info(string.format(
    t("Current log file: %s"),
    diagnostics.current_log_file ~= "" and diagnostics.current_log_file or t("(created after the first matching message)")
  ))
  if ImGui.Button(ctx, t("Copy log folder")) then
    TelemetryBridge.button_clicked("copy_diagnostics_log_folder_btn", t("Copy log folder"))
    ImGui.SetClipboardText(ctx, diagnostics.log_dir)
  end
  UI.ui_info(t("Local logs may contain project paths, filenames, and workflow content."))
  if diagnostics.messaging_threshold == 4 then
    UI.ui_warning(t("Messaging is Off. Util-driven errors may be hidden."))
  end
end

function UI.render_telemetry_level_setting()
  local desc = TelemetryBridge.describe_status()
  local current_level = tostring(desc.effective_level or "support")
  local current_level_label = TelemetryBridge.level_label(current_level)
  if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(ctx, 160) end
  if ImGui.BeginCombo(ctx, t("Telemetry level") .. "##docx_import_telemetry_level", current_level_label) then
    for _, level in ipairs({ "basic", "support", "debug" }) do
      local selected = current_level == level
      local level_label = TelemetryBridge.level_label(level)
      if ImGui.Selectable(ctx, level_label, selected) then
        TelemetryBridge.set_level(level)
      end
      if selected and ImGui.SetItemDefaultFocus then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

function UI.render_settings_section()
  if not ImGui.CollapsingHeader(ctx, t("Settings")) then return end
  UI.set_separator_text(t("Diagnostics"))
  UI.render_diagnostics_settings()
  UI.set_separator_text(t("Telemetry"))
  UI.render_telemetry_level_setting()
end

function UI.render_telemetry_section()
  local desc = TelemetryBridge.describe_status()
  local header_state = TelemetryBridge.header_state(desc)
  local header_label = string.format(t("Telemetry (%s)"), header_state) .. "###docx_import_telemetry_section"
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  local telemetry_open = ImGui.CollapsingHeader(ctx, header_label)
  ImGui.PopStyleColor(ctx)
  if not telemetry_open then
    return
  end

  local progress = TelemetryBridge.progress_text(desc)
  local backlog_text = TelemetryBridge.backlog_status_text(desc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  ImGui.TextWrapped(ctx, string.format(t("Telemetry status: %s"), tostring(desc.status or "")))
  ImGui.PopStyleColor(ctx)
  if backlog_text ~= "" then
    UI.ui_info(backlog_text)
  end

  if ImGui.BeginTable then
    local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "##docx_import_telemetry_status_table", 2, flags, -1, 0) then
      ImGui.TableSetupColumn(ctx, t("Field"), ImGui.TableColumnFlags_WidthFixed, 180)
      ImGui.TableSetupColumn(ctx, t("Value"), ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableHeadersRow(ctx)

      local rows = {
        { t("Status"), tostring(desc.status or "") },
        { t("Backlog"), backlog_text ~= "" and backlog_text or t("No old telemetry backlog.") },
        { t("Active batch"), progress ~= "" and progress or t("Idle") },
        { t("Level"), TelemetryBridge.level_label(desc.effective_level) },
        { t("Queue bytes"), DocxTelemetrySummary.format_bytes(desc.sendable_queue_bytes) },
        {
          t("Queued / flushed"),
          string.format(
            "%d / %d",
            tonumber(desc.queued_events_session) or 0,
            tonumber(desc.flushed_events_session) or 0
          )
        },
        {
          t("Failed / dropped / skipped"),
          string.format(
            "%d / %d / %d",
            tonumber(desc.failed_batches_session) or 0,
            tonumber(desc.dropped_events_session) or 0,
            tonumber(desc.skipped_events_session) or 0
          )
        },
        {
          t("HTTP / curl"),
          string.format("%s / %s", tostring(desc.last_http_code or "-"), tostring(desc.last_curl_exitcode or "-"))
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
  else
    if progress ~= "" then
      UI.ui_info(string.format(t("Telemetry progress: %s"), progress))
    end
  end

  if Util.trim(state.telemetry_ui_status or "") ~= "" then
    UI.ui_info(state.telemetry_ui_status)
  end

  local flush_disabled = desc.active_job_id ~= nil
  if flush_disabled and ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, true) end
  if ImGui.Button(ctx, t("Flush telemetry now")) then
    TelemetryBridge.button_clicked("telemetry_flush_now_btn", t("Flush telemetry now"))
    TelemetryBridge.safe_flush_async("docx_manual")
  end
  if flush_disabled and ImGui.EndDisabled then ImGui.EndDisabled(ctx) end

  if desc.send_paused == true then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Resume telemetry sending")) then
      TelemetryBridge.button_clicked("telemetry_resume_btn", t("Resume telemetry sending"))
      TelemetryBridge.resume_sending(t("manual resume from DOCX Import UI"))
    end
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, t("Copy telemetry paths")) then
    TelemetryBridge.button_clicked("telemetry_copy_paths_btn", t("Copy telemetry paths"))
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
    state.telemetry_ui_status = t("Telemetry paths copied.")
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
    "active_batch_event_count: " .. tostring(desc.active_batch_event_count or 0),
    "active_batch_payload_bytes: " .. tostring(desc.active_batch_payload_bytes or 0),
    "queued_file_count: " .. tostring(desc.queued_file_count or 0),
    "sending_file_count: " .. tostring(desc.sending_file_count or 0),
    "backlog_file_count: " .. tostring(desc.backlog_file_count or 0),
    "backlog_queue_bytes: " .. tostring(desc.backlog_queue_bytes or 0),
    "draining_backlog: " .. tostring(desc.draining_backlog == true),
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
    "##docx_import_telemetry_details",
    table.concat(details, "\n"),
    -1,
    180,
    ImGui.InputTextFlags_ReadOnly or 0
  )
end

function UI.gui_loop()
  Helpers.refresh_project_relative_paths()
  Helpers.set_status(Helpers.workflow_status_text(), nil, state.technical_status_text)
  local now_t = TelemetryBridge.now()
  TelemetryBridge.safe_tick(now_t)
  Jobs.tick_all(now_t)
  ImGui.SetNextWindowSize(ctx, 750, 975, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, current_main_window_title_text() .. "##docx_import_tool_main_window", true)
  if visible then
    -- ReaImGui Lua can report collapsed windows as not visible; guard End with the visible branch.
    ImGui.PushFont(ctx, FONT, font_size)

    ImGui.Text(ctx, t("Language") .. ":")
    ImGui.SameLine(ctx)
    if ImGui.SetNextItemWidth then
      ImGui.SetNextItemWidth(ctx, 160)
    end
    local locale_combo_disabled = not translated_locale_available("rus")
    if locale_combo_disabled and ImGui.BeginDisabled then
      ImGui.BeginDisabled(ctx, true)
    end
    local locale_combo_open = ImGui.BeginCombo(
      ctx,
      "##docx_import_ui_locale_combo",
      locale_display_name(active_locale)
    )
    if locale_combo_open then
      local locale_options = { "eng" }
      if translated_locale_available("rus") then
        table.insert(locale_options, "rus")
      end
      for _, locale_id in ipairs(locale_options) do
        local is_selected = (active_locale == locale_id)
        local activated = ImGui.Selectable(ctx, locale_display_name(locale_id), is_selected)
        if activated then
          set_active_runtime_locale(locale_id)
          persist_locale(locale_id)
        end
        if is_selected and ImGui.SetItemDefaultFocus then
          ImGui.SetItemDefaultFocus(ctx)
        end
      end
      ImGui.EndCombo(ctx)
    end
    if locale_combo_disabled and ImGui.EndDisabled then
      ImGui.EndDisabled(ctx)
    end

    UI.render_status_panel()
    UI.render_settings_section()

    UI.set_separator_text(t("DOCX Source"))
    ImGui.Text(ctx, t("DOCX file:"))
    ImGui.SameLine(ctx)
    local ch_docx, nv_docx = ImGui.InputText(ctx, "##docx_path", tostring(state.docx_path or ""))
    if ch_docx then
      state.docx_path = nv_docx
      Helpers.persist_string(EXTSTATE.docx_path, state.docx_path)
      Helpers.reset_after_docx_or_output_change()
      Helpers.refresh_import_ready_rows()
      TelemetryBridge.operation_completed("docx_source_selected", {
        selection_method = "text_input",
        source_mode = normalize_docx_source_mode(state.docx_source_mode)
      })
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Browse DOCX")) then
      local telemetry_started_at = TelemetryBridge.now()
      TelemetryBridge.button_clicked("browse_docx_btn", t("Browse DOCX"))
      local initial_dir = Files.get_dir_from_file_path(state.docx_path)
      local ok_pick, selected_or_err = Helpers.prompt_for_file(t("Select DOCX file"), initial_dir or Files.read_project_path(), "*.docx")
      if ok_pick then
        state.docx_path = selected_or_err
        Helpers.persist_string(EXTSTATE.docx_path, state.docx_path)
        Helpers.reset_after_docx_or_output_change()
        Helpers.refresh_import_ready_rows()
        Helpers.log_step("browse_docx", string.format(t("Selected: %s"), tostring(state.docx_path)))
        TelemetryBridge.operation_completed("docx_source_selected", {
          selection_method = "browse",
          source_mode = normalize_docx_source_mode(state.docx_source_mode)
        }, telemetry_started_at)
      else
        Helpers.log_step("browse_docx", tostring(selected_or_err), 2)
        TelemetryBridge.operation_canceled("docx_source_selected", {
          selection_method = "browse",
          detail_message = tostring(selected_or_err)
        }, telemetry_started_at)
      end
    end

    UI.render_docx_source_mode_selector()

    if ImGui.Button(ctx, t("Extract + Parse")) then
      TestCases.run_extract_parse_preflight_test()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t("Start Over")) then
      local telemetry_started_at = TelemetryBridge.now()
      TelemetryBridge.button_clicked("start_over_btn", t("Start Over"))
      TelemetryBridge.emit_support_rows_snapshot("docx_start_over", {
        reason = "before_start_over",
        include_log = true,
        report = state.last_dialogue_import and state.last_dialogue_import.preflight_report or nil
      })
      local previous_import_ready_count = #(state.import_ready_rows or {})
      Helpers.reset_all_results()
      Helpers.clear_warnings()
      state.rolling_log_lines = {}
      state.technical_status_text = ""
      Helpers.set_status(t("Waiting for a DOCX file."), t("Workflow reset."), "")
      TelemetryBridge.operation_completed("docx_start_over", {
        previous_import_ready_count = previous_import_ready_count,
        import_ready_count = #(state.import_ready_rows or {})
      }, telemetry_started_at, {
        policy = "basic",
        include_log = true
      })
    end

    UI.render_mapping_controls()
    UI.render_cast_controls()
    UI.render_timecode_controls()
    if state.last_timecode.finalized ~= true then
      UI.render_character_summary()
      UI.render_merge_candidates()
    end
    UI.render_main_rows_table()
    UI.render_dialogue_import_controls()
    UI.render_telemetry_section()
    UI.render_details_panel()

    ImGui.PopFont(ctx)
    ImGui.End(ctx)
  end

  if open then
    r.defer(UI.gui_loop)
  else
    TelemetryBridge.send_closed_event("window_closed")
  end
end

Helpers.refresh_project_relative_paths()
Helpers.load_persisted_state()
Helpers.refresh_import_ready_rows()
state.status_text = t("DOCX import prototype initialized.")
state.last_status_text = state.status_text
Helpers.add_log_line(os.date("%H:%M:%S") .. " [" .. t("INFO") .. "] startup_init - " .. state.status_text)
Util.msg(state.status_text, 1)
TelemetryBridge.script_started()
r.defer(UI.gui_loop)
