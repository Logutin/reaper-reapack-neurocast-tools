-- Pure MVSEP catalog, create-response, status, result-list, and standard-error parser.
--
-- This module deliberately contains no network request builders, provider host,
-- API-token, region, compatibility-removal, or authentication behavior. The
-- dedicated Studio Neurocast transport lives in mvsep_api_via_neurocast.lua.

local MVSepAPI = {}

local json = nil
local function get_json()
  if json and type(json.decode) == "function" and type(json.encode) == "function" then
    return json
  end

  local ok_json, json_mod = pcall(require, "modules-neurocast.json")
  if ok_json and type(json_mod) == "table" and type(json_mod.decode) == "function" and type(json_mod.encode) == "function" then
    json = json_mod
    return json
  end

  error("mvsep_api: JSON module not available (required 'modules-neurocast.json')")
end

local DEFAULT_SCOPES = { "single_upload", "no_upload", "matchering_upload" }
local DEFAULT_SCOPES_SET = {
  single_upload = true,
  no_upload = true,
  matchering_upload = true
}

local OUTPUT_FORMATS = {
  mp3320 = { code = 0, label = "mp3 (320 kbps)" },
  wav16 = { code = 1, label = "wav (uncompressed, 16 bit)" },
  flac16 = { code = 2, label = "flac (lossless, 16 bit)" },
  m4a = { code = 3, label = "m4a (lossy)" },
  wav32 = { code = 4, label = "wav (uncompressed, 32 bit)" },
  flac24 = { code = 5, label = "flac (lossless, 24 bit)" }
}

local DEFAULT_OUTPUT_FORMAT_NAME = "flac16"

local DEFAULT_FAVORITES = {
  ["56"] = true
}

local IN_PROGRESS_STATUSES = {
  waiting = true,
  processing = true,
  distributing = true,
  merging = true
}

local PROCESSING_STARTED_STATUSES = {
  processing = true,
  distributing = true,
  merging = true,
  done = true
}

local TERMINAL_STATUSES = {
  done = true,
  failed = true,
  canceled = true,
  cancelled = true,
  not_found = true
}

local function is_known_status(status)
  local normalized = MVSepAPI.normalize_job_status(status)
  return IN_PROGRESS_STATUSES[normalized] == true or TERMINAL_STATUSES[normalized] == true
end

MVSepAPI.DEFAULT_SCOPES = DEFAULT_SCOPES
MVSepAPI.OUTPUT_FORMATS = OUTPUT_FORMATS
MVSepAPI.DEFAULT_OUTPUT_FORMAT_NAME = DEFAULT_OUTPUT_FORMAT_NAME
MVSepAPI.DEFAULT_FAVORITES = DEFAULT_FAVORITES
MVSepAPI.IN_PROGRESS_STATUSES = IN_PROGRESS_STATUSES
MVSepAPI.TERMINAL_STATUSES = TERMINAL_STATUSES

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function safe_text(value, max_len)
  if value == nil then return nil end
  local text = tostring(value)
  text = text:gsub("[Hh][Tt][Tt][Pp][Ss]?://[^%s%[%]<>\"']+", "[redacted-url]")
  text = text:gsub("[Hh][Tt][Tt][Pp][Ss]?%%3[Aa]%%2[Ff]%%2[Ff][^%s%[%]<>\"']+", "[redacted-encoded-url]")
  local limit = tonumber(max_len) or 500
  if #text > limit then
    text = text:sub(1, limit) .. "...[truncated]"
  end
  return text
end

function MVSepAPI.normalize_job_status(status)
  local normalized = trim(status):lower():gsub("[%s%-]+", "_")
  if normalized == "cancelled" then return "canceled" end
  return normalized
end

function MVSepAPI.is_in_progress_status(status)
  return IN_PROGRESS_STATUSES[MVSepAPI.normalize_job_status(status)] == true
end

function MVSepAPI.is_cancelable_status(status)
  return MVSepAPI.normalize_job_status(status) == "waiting"
end

function MVSepAPI.is_cancel_request_window_status(status)
  local normalized = MVSepAPI.normalize_job_status(status)
  return normalized == "submitted" or normalized == "waiting"
end

function MVSepAPI.has_processing_started(status)
  return PROCESSING_STARTED_STATUSES[MVSepAPI.normalize_job_status(status)] == true
end

function MVSepAPI.is_terminal_status(status)
  return TERMINAL_STATUSES[MVSepAPI.normalize_job_status(status)] == true
end

function MVSepAPI.is_known_status(status)
  return is_known_status(status)
end

local function contains_not_found(text)
  return trim(text):lower():find("not found", 1, true) ~= nil
end

local function is_large_file_progress_message(text)
  local lowered = trim(text):lower()
  if lowered == "" then return false end
  local has_large = lowered:find("large", 1, true) ~= nil
  local has_split = lowered:find("split", 1, true) ~= nil or lowered:find("splitted", 1, true) ~= nil
  local has_distributed =
    lowered:find("distributed", 1, true) ~= nil or
    lowered:find("multiple gpu", 1, true) ~= nil
  local has_merged = lowered:find("merged", 1, true) ~= nil or lowered:find("merging", 1, true) ~= nil
  return has_large and has_split and has_distributed and has_merged
end

local function status_display(value)
  local txt = trim(value)
  if txt == "" then return "(missing)" end
  return txt
end

local function classify_job_status(decoded, data, success, message, api_error)
  local raw_root_status = decoded and decoded.status or nil
  local raw_data_status = data and data.status or nil
  local root_status = MVSepAPI.normalize_job_status(raw_root_status)
  local data_status = MVSepAPI.normalize_job_status(raw_data_status)
  local raw_status = trim(raw_root_status) ~= "" and raw_root_status or raw_data_status
  local status = nil
  local status_source = nil

  if root_status ~= "" and is_known_status(root_status) then
    status = root_status
    status_source = "root"
  elseif data_status ~= "" and is_known_status(data_status) then
    status = data_status
    status_source = "data"
  elseif root_status ~= "" then
    status = root_status
    status_source = "root_unknown"
  elseif data_status ~= "" then
    status = data_status
    status_source = "data_unknown"
  end

  local combined_message = table.concat({
    tostring(message or ""),
    tostring(api_error or ""),
    tostring(raw_root_status or ""),
    tostring(raw_data_status or "")
  }, "\n")
  local large_file_progress = is_large_file_progress_message(combined_message)
  local status_warning = nil

  if large_file_progress then
    if status ~= "distributing" or success ~= true then
      status_warning =
        "MVSEP large-file progress message classified as distributing" ..
        " (raw_status=" .. status_display(raw_status) ..
        ", success=" .. tostring(success) .. ")."
    end
    return "distributing", raw_status, status_source or "large_file_message", status_warning
  end

  if status then
    return status, raw_status, status_source or "unknown", nil
  end

  if contains_not_found(message) or contains_not_found(api_error) then
    return "not_found", raw_status, "message_not_found", nil
  end

  if success then
    return "processing", raw_status, "success_fallback", nil
  end

  return "failed", raw_status, "failure_fallback", nil
end

local function shallow_copy(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    out[k] = v
  end
  return out
end

local function validate_table(value, field_name)
  if type(value) ~= "table" then
    return nil, field_name .. " must be a table"
  end
  return value
end

local function decode_json_value(body_txt)
  if type(body_txt) ~= "string" or body_txt == "" then
    return nil, "empty body"
  end
  local ok, decoded = pcall(get_json().decode, body_txt)
  if not ok then
    return nil, "JSON decode failed: " .. tostring(decoded)
  end
  return decoded
end

local function decode_json_object(body_txt)
  local decoded, decode_err = decode_json_value(body_txt)
  if not decoded then
    return nil, decode_err
  end
  if type(decoded) ~= "table" then
    return nil, "decoded JSON is not an object"
  end
  return decoded
end

local function parse_api_error_from_obj(decoded)
  if type(decoded) ~= "table" then return nil end

  local pieces = {}
  local primary_err = decoded.error or decoded.title or decoded.error_message or decoded.err
  local message_txt = decoded.message or decoded.detail
  local status_code = decoded.statusCode or decoded.status or decoded.code

  if status_code ~= nil and tostring(status_code) ~= "" then
    pieces[#pieces + 1] = tostring(status_code)
  end
  if primary_err ~= nil and tostring(primary_err) ~= "" then
    pieces[#pieces + 1] = tostring(primary_err)
  end
  if message_txt ~= nil and tostring(message_txt) ~= "" then
    pieces[#pieces + 1] = tostring(message_txt)
  end

  if type(decoded.data) == "table" then
    local data_message = decoded.data.message or decoded.data.error_message
    if data_message ~= nil and tostring(data_message) ~= "" then
      pieces[#pieces + 1] = tostring(data_message)
    end
  end

  if #pieces == 0 then return nil end
  return safe_text(table.concat(pieces, " - "), 500)
end

local function parse_api_error_from_body(body_txt)
  local decoded = decode_json_value(body_txt)
  if not decoded then return nil end
  if type(decoded) ~= "table" then return nil end
  return parse_api_error_from_obj(decoded)
end

local function make_failure_payload(endpoint, error_txt, http_code, api_error)
  return {
    ok = false,
    endpoint = tostring(endpoint or ""),
    http_code = http_code,
    error = tostring(error_txt or "request failed"),
    api_error = api_error
  }
end

local function safe_callback(on_done, payload)
  if type(on_done) ~= "function" then return end
  pcall(on_done, payload)
end

local function parse_scopes(scopes)
  if scopes == nil then
    return shallow_copy(DEFAULT_SCOPES), nil
  end

  local out = {}
  if type(scopes) == "string" then
    for part in tostring(scopes):gmatch("[^,]+") do
      local item = trim(part)
      if item ~= "" then
        out[#out + 1] = item
      end
    end
  elseif type(scopes) == "table" then
    for _, item in ipairs(scopes) do
      local text = trim(item)
      if text ~= "" then
        out[#out + 1] = text
      end
    end
  else
    return nil, "scopes must be a comma-separated string, table, or nil"
  end

  if #out == 0 then
    return nil, "at least one scope is required"
  end

  for i = 1, #out do
    if not DEFAULT_SCOPES_SET[out[i]] then
      return nil, "unknown scope: " .. tostring(out[i])
    end
  end

  return out, nil
end

local function parse_add_opt_index(field_name)
  if type(field_name) ~= "string" then return nil end
  local match = field_name:match("^add_opt(%d+)$")
  if not match then return nil end
  return tonumber(match)
end

local function parse_options(raw_options)
  if type(raw_options) == "table" then
    local out = {}
    for key, value in pairs(raw_options) do
      out[tostring(key)] = value
    end
    return out
  end

  if raw_options == nil then
    return {}
  end

  if type(raw_options) ~= "string" then
    return nil, "Unsupported options type: " .. tostring(type(raw_options))
  end

  local stripped = trim(raw_options)
  if stripped == "" then
    return {}
  end

  local parsed, decode_err = decode_json_value(stripped)
  if not parsed then
    return nil, "options decode failed: " .. tostring(decode_err)
  end
  if type(parsed) ~= "table" then
    return nil, "options must decode to a JSON object"
  end

  local out = {}
  for key, value in pairs(parsed) do
    out[tostring(key)] = value
  end
  return out
end

local function sort_fields(fields)
  table.sort(fields, function(a, b)
    local ai = tonumber(a and a.option_index) or math.huge
    local bi = tonumber(b and b.option_index) or math.huge
    if ai ~= bi then return ai < bi end
    return tostring(a and a.form_key or "") < tostring(b and b.form_key or "")
  end)
  return fields
end

local function normalize_field(row_name, raw_field)
  local options, options_err = parse_options(raw_field.options)
  if not options then
    return nil, string.format(
      "Failed to parse options for '%s' field '%s': %s",
      tostring(row_name or ""),
      tostring(raw_field and raw_field.name or ""),
      tostring(options_err)
    )
  end

  return {
    form_key = raw_field.name,
    option_index = parse_add_opt_index(raw_field.name),
    label = raw_field.text,
    server_key = raw_field.server_key,
    input_type = raw_field.input_type,
    required = (raw_field.required == true),
    default_key = raw_field.default_key == nil and nil or tostring(raw_field.default_key),
    options = options,
    conditions = type(raw_field.conditions) == "table" and raw_field.conditions or {},
    price_rules = type(raw_field.price_rules) == "table" and raw_field.price_rules or {},
    created_at = raw_field.created_at,
    updated_at = raw_field.updated_at,
    source_algorithm_name = row_name
  }
end

local function normalize_description(raw_description)
  return {
    lang = raw_description.lang,
    short_description = raw_description.short_description,
    long_description_html = raw_description.long_description,
    created_at = raw_description.created_at,
    updated_at = raw_description.updated_at
  }
end

local function normalize_algorithm(row)
  local row_name = tostring(row.name or "")
  local raw_fields = type(row.algorithm_fields) == "table" and row.algorithm_fields or {}
  local raw_descriptions = type(row.algorithm_descriptions) == "table" and row.algorithm_descriptions or {}

  local fields = {}
  for _, field in ipairs(raw_fields) do
    if type(field) == "table" then
      local normalized_field, normalize_err = normalize_field(row_name, field)
      if not normalized_field then
        return nil, normalize_err
      end
      fields[#fields + 1] = normalized_field
    end
  end
  sort_fields(fields)

  local descriptions = {}
  local descriptions_by_lang = {}
  for _, description in ipairs(raw_descriptions) do
    if type(description) == "table" then
      local normalized = normalize_description(description)
      descriptions[#descriptions + 1] = normalized
      if type(normalized.lang) == "string" and normalized.lang ~= "" then
        descriptions_by_lang[tostring(normalized.lang)] = normalized
      end
    end
  end

  local group = type(row.algorithm_group) == "table" and row.algorithm_group or nil
  local sep_type = row.render_id
  if sep_type ~= nil then sep_type = tostring(sep_type) end
  if sep_type == "" then sep_type = nil end

  local audio_widget = tostring(row.audio_widget or "")
  local supported_v1 = false
  local unsupported_reason = nil
  if not sep_type then
    unsupported_reason = "Missing sep_type."
  elseif audio_widget ~= "single_upload" then
    unsupported_reason = "Unsupported in v1: requires " .. tostring(audio_widget ~= "" and audio_widget or "non-upload workflow") .. "."
  elseif row.audio_upload_disabled == true then
    unsupported_reason = "Audio upload is disabled for this model."
  else
    supported_v1 = true
  end

  return {
    sep_type = sep_type,
    internal_id = row.id == nil and nil or tostring(row.id),
    name = row.name,
    group_id = row.algorithm_group_id,
    group_name = group and group.name or nil,
    audio_widget = row.audio_widget,
    orientation = row.orientation,
    order_id = row.order_id,
    is_active = (row.is_active == true),
    audio_upload_disabled = (row.audio_upload_disabled == true),
    price_coefficient = row.price_coefficient,
    usage = row.usage,
    rating = type(row.rating) == "table" and row.rating or nil,
    description = row.description,
    created_at = row.created_at,
    updated_at = row.updated_at,
    fields = fields,
    descriptions = descriptions,
    descriptions_by_lang = descriptions_by_lang,
    supported_v1 = supported_v1,
    unsupported_reason = unsupported_reason,
    favorite_default = (sep_type == "56")
  }
end

local function build_catalog_summary(algorithms)
  local widget_counts = {}
  local with_fields_count = 0
  local with_descriptions_count = 0
  local max_add_opt_number = 0

  for _, algorithm in ipairs(algorithms or {}) do
    local widget = tostring(algorithm.audio_widget or "")
    widget_counts[widget] = (widget_counts[widget] or 0) + 1

    if type(algorithm.fields) == "table" and #algorithm.fields > 0 then
      with_fields_count = with_fields_count + 1
      for _, field in ipairs(algorithm.fields) do
        local option_index = tonumber(field.option_index)
        if option_index and option_index > max_add_opt_number then
          max_add_opt_number = option_index
        end
      end
    end

    if type(algorithm.descriptions) == "table" and #algorithm.descriptions > 0 then
      with_descriptions_count = with_descriptions_count + 1
    end
  end

  return {
    algorithm_count = #(algorithms or {}),
    audio_widget_counts = widget_counts,
    with_fields_count = with_fields_count,
    with_descriptions_count = with_descriptions_count,
    max_add_opt_number = max_add_opt_number
  }
end

local function first_text(mapping, keys)
  if type(mapping) ~= "table" then return nil end
  for _, key in ipairs(keys or {}) do
    local value = mapping[key]
    if type(value) == "string" then
      local stripped = trim(value)
      if stripped ~= "" then
        return stripped
      end
    end
  end
  return nil
end

local function normalize_download_entries(value)
  local entries = {}
  local seen = {}

  local function basename_from_pathish(text)
    local value_text = trim(text)
    if value_text == "" then return nil end
    value_text = value_text:gsub("[?#].*$", "")
    local base = value_text:match("([^/\\]+)$") or value_text
    base = trim(base)
    if base == "" then return nil end
    return base
  end

  local function add_entry(label, url, download_name)
    local clean_url = trim(url)
    if clean_url == "" then return end
    local clean_label = trim(label)
    if clean_label == "" then clean_label = "file" end
    local key = clean_label .. "\n" .. clean_url
    if seen[key] then return end
    seen[key] = true
    local clean_download_name = basename_from_pathish(download_name) or basename_from_pathish(clean_url)
    entries[#entries + 1] = {
      label = clean_label,
      url = clean_url,
      download_name = clean_download_name
    }
  end

  local function visit(node, default_label)
    if type(node) == "string" then
      if node:match("^https?://") then
        add_entry(default_label, node)
      end
      return
    end

    if type(node) ~= "table" then return end

    if node[1] ~= nil then
      for _, item in ipairs(node) do
        visit(item, default_label)
      end
      return
    end

    local url = first_text(node, { "url", "link", "download", "download_link", "file", "path" })
    local label = first_text(node, { "name", "title", "label", "stem", "type", "filename", "download" }) or default_label
    local download_name = first_text(node, { "download", "filename", "name", "title" })
    if url then
      add_entry(label, url, download_name)
    end

    for key, child in pairs(node) do
      local child_label = label
      if child_label == nil and type(key) == "string" and not ({
        url = true,
        link = true,
        download = true,
        download_link = true
      })[key] then
        child_label = key
      end
      visit(child, child_label)
    end
  end

  visit(value, nil)
  return entries
end

function MVSepAPI.sort_option_entries(options_map)
  local rows = {}
  for key, value in pairs(options_map or {}) do
    rows[#rows + 1] = {
      key = tostring(key),
      label = tostring(value or "")
    }
  end
  table.sort(rows, function(a, b)
    local an = tonumber(a.key)
    local bn = tonumber(b.key)
    if an and bn and an ~= bn then return an < bn end
    if an and not bn then return true end
    if bn and not an then return false end
    return a.key < b.key
  end)
  return rows
end

function MVSepAPI.find_algorithm_by_sep_type(catalog_payload, sep_type)
  if type(catalog_payload) ~= "table" then return nil end
  local target = tostring(sep_type or "")
  if target == "" then return nil end
  local algorithms = catalog_payload.algorithms or {}
  for _, algorithm in ipairs(algorithms) do
    if tostring(algorithm.sep_type or "") == target then
      return algorithm
    end
  end
  return nil
end

local function safe_known_scalar(value)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return safe_text(value, 500)
  end
  return nil
end

local function first_table(mapping, keys)
  if type(mapping) ~= "table" then return nil end
  for _, key in ipairs(keys or {}) do
    if type(mapping[key]) == "table" then return mapping[key] end
  end
  return nil
end

local function first_scalar(mapping, keys)
  if type(mapping) ~= "table" then return nil end
  for _, key in ipairs(keys or {}) do
    local value = safe_known_scalar(mapping[key])
    if value ~= nil and value ~= "" then return value end
  end
  return nil
end

local function response_rows(decoded)
  if type(decoded) ~= "table" then return nil end
  if #decoded > 0 then return decoded end
  if next(decoded) == nil then return decoded end
  if type(decoded.algorithms) == "table" then return decoded.algorithms end
  if type(decoded.data) == "table" then
    if #decoded.data > 0 then return decoded.data end
    if next(decoded.data) == nil then return decoded.data end
    if type(decoded.data.algorithms) == "table" then return decoded.data.algorithms end
  end
  return nil
end

function MVSepAPI.parse_algorithms_body(body_txt, opts)
  local decoded, decode_err = decode_json_value(body_txt)
  if not decoded then return nil, decode_err, nil end
  local rows = response_rows(decoded)
  if type(rows) ~= "table" then
    return nil, "decoded JSON does not contain an algorithms array", nil
  end

  local algorithms = {}
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local normalized, normalize_err = normalize_algorithm(row)
      if not normalized then return nil, normalize_err, nil end
      algorithms[#algorithms + 1] = normalized
    end
  end

  table.sort(algorithms, function(a, b)
    local a_order = tonumber(a.order_id) or math.huge
    local b_order = tonumber(b.order_id) or math.huge
    if a_order ~= b_order then return a_order < b_order end
    local a_group = tostring(a.group_name or "")
    local b_group = tostring(b.group_name or "")
    if a_group ~= b_group then return a_group < b_group end
    return tostring(a.name or "") < tostring(b.name or "")
  end)

  local options = type(opts) == "table" and opts or {}
  return {
    fetched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    source_label = safe_text(options.source_label or "studio_neurocast", 80),
    requested_scopes = shallow_copy(options.requested_scopes or DEFAULT_SCOPES),
    contract_notes = {
      "Use the catalog-provided render_id as sep_type.",
      "Parse algorithm_fields[].options as JSON for live option labels.",
      "Preserve all supported add_opt1 through add_opt10 fields."
    },
    summary = build_catalog_summary(algorithms),
    algorithms = algorithms
  }
end

function MVSepAPI.parse_create_job_body(body_txt)
  local decoded, decode_err = decode_json_object(body_txt)
  if not decoded then return nil, decode_err, nil end
  local data = type(decoded.data) == "table" and decoded.data or decoded
  local job_hash = trim(data.hash or data.job_hash)
  local message = safe_text(data.message or decoded.message, 500)
  local success = decoded.success == true or data.success == true or job_hash ~= ""
  if not success or job_hash == "" then
    return nil, "response missing a valid job hash", parse_api_error_from_obj(decoded) or message
  end
  return {
    success = true,
    job_hash = job_hash,
    message = message
  }
end

function MVSepAPI.parse_get_job_status_body(body_txt)
  local decoded, decode_err = decode_json_object(body_txt)
  if not decoded then return nil, decode_err, nil end
  local data = type(decoded.data) == "table" and decoded.data or decoded
  local success = decoded.success == true or data.success == true
  local message = safe_text(data.message or decoded.message, 500)
  local api_error = parse_api_error_from_obj(decoded)
  local status, raw_status, status_source, status_warning =
    classify_job_status(decoded, data, success, message, api_error)

  return {
    success = success,
    raw_success = decoded.success,
    status = status,
    raw_status = safe_text(raw_status, 80),
    status_source = safe_text(status_source, 80),
    status_warning = safe_text(status_warning, 500),
    message = message,
    date = safe_text(data.date, 80),
    queue_count = tonumber(data.queue_count),
    current_order = tonumber(data.current_order),
    finished_chunks = tonumber(data.finished_chunks),
    all_chunks = tonumber(data.all_chunks),
    algorithm = safe_text(data.algorithm, 200),
    algorithm_description = safe_text(data.algorithm_description, 500),
    output_format = safe_text(data.output_format, 80),
    input_file = safe_text(data.input_file, 260),
    output_files = normalize_download_entries(data.files)
  }
end

function MVSepAPI.parse_mutation_body(body_txt, operation)
  local decoded, decode_err = decode_json_object(body_txt)
  if not decoded then return nil, decode_err, nil end
  local data = type(decoded.data) == "table" and decoded.data or decoded
  local success = decoded.success == true or data.success == true
  if success then
    return {
      success = true,
      operation = safe_text(operation, 40),
      status = safe_text(data.status or decoded.status, 80),
      message = safe_text(data.message or decoded.message, 500)
    }
  end
  local message = safe_text(
    data.message or decoded.message or data.error or decoded.error or "backend rejected the mutation",
    500
  )
  return nil, message, parse_api_error_from_obj(decoded) or message, {
    definite_rejection = true,
    provider_success = false
  }
end

function MVSepAPI.parse_standard_backend_error(body_txt, http_code, headers_txt)
  local decoded = decode_json_value(body_txt)
  local root = type(decoded) == "table" and decoded or {}
  local error_obj = type(root.error) == "table" and root.error or {}
  local details = first_table(root, { "details", "publicDetails", "public_details" }) or
    first_table(error_obj, { "details", "publicDetails", "public_details" }) or {}
  local rate = first_table(root, { "rateLimit", "rate_limit", "retry" }) or
    first_table(details, { "rateLimit", "rate_limit", "retry" }) or {}
  local safe = {
    http_status = tonumber(http_code) or tonumber(root.statusCode or root.status),
    code = first_scalar(root, { "code", "errorCode", "error_code" }) or
      first_scalar(error_obj, { "code", "errorCode", "error_code" }),
    message = first_scalar(root, { "message", "error_description" }) or
      first_scalar(error_obj, { "message", "error_description" }),
    failure_type = first_scalar(details, { "failureType", "failure_type" }),
    mutation_outcome = first_scalar(details, { "mutationOutcome", "mutation_outcome" }),
    upstream_status = tonumber(first_scalar(details, { "upstreamStatus", "upstream_status" })),
    retry_after = first_scalar(root, { "retryAfter", "retry_after", "retryAfterSeconds" }) or
      first_scalar(details, { "retryAfter", "retry_after", "retryAfterSeconds" }) or
      first_scalar(rate, { "retryAfter", "retry_after", "reset" }),
    rate_limit = first_scalar(rate, { "limit" }),
    rate_remaining = first_scalar(rate, { "remaining" }),
    correlation_id = first_scalar(root, { "correlationId", "correlation_id", "requestId", "request_id" }) or
      first_scalar(details, { "correlationId", "correlation_id", "requestId", "request_id" })
  }

  if safe.correlation_id == nil and type(headers_txt) == "string" then
    safe.correlation_id = safe_text(
      headers_txt:match("[Xx]%-[Cc]orrelation%-[Ii][Dd]%s*:%s*([^\r\n]+)") or
      headers_txt:match("[Xx]%-[Rr]equest%-[Ii][Dd]%s*:%s*([^\r\n]+)"),
      200
    )
  end
  if safe.message == nil or safe.message == "" then
    safe.message = "Studio Neurocast request failed."
  end
  return safe
end

return MVSepAPI
