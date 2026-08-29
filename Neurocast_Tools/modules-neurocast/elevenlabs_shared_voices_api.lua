-- Pure request/response helpers for the ElevenLabs shared Voice Library.
--
-- This module deliberately does not submit Curl jobs, schedule retries, emit
-- telemetry, or retain page state. The calling entrypoint owns those concerns.

local json = require("modules-neurocast.json")

local SharedVoicesApi = {}

SharedVoicesApi.DEFAULT_PAGE_SIZE = 30
SharedVoicesApi.MAX_PAGE_SIZE = 100
SharedVoicesApi.DEFAULT_SORT = "created_date"

local SCALAR_FILTERS = {
  "category",
  "gender",
  "age",
  "accent",
  "language",
  "locale",
  "search",
  "owner_id"
}

local ARRAY_FILTERS = {
  "use_cases",
  "descriptives"
}

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function nonempty(value)
  local text = trim(value)
  if text == "" then return nil end
  return text
end

local function boolean_or_nil(value)
  if type(value) == "boolean" then return value end
  return nil
end

local function normalized_match(value)
  local text = nonempty(value)
  return text and text:lower() or nil
end

local function integer_in_range(value, fallback, minimum, maximum)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) then
    number = fallback
  end
  if number < minimum then number = minimum end
  if number > maximum then number = maximum end
  return number
end

local function normalize_string_array(value)
  if value == nil then return nil end
  if type(value) ~= "table" then
    value = { value }
  end

  local out = {}
  local seen = {}
  for _, item in ipairs(value) do
    local text = nonempty(item)
    if text and not seen[text] then
      seen[text] = true
      out[#out + 1] = text
    end
  end
  if #out == 0 then return nil end
  table.sort(out)
  return out
end

local function url_encode(value)
  return (tostring(value or ""):gsub("[^%w%-._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function append_query_value(parts, key, value)
  if value == nil then return end
  if type(value) == "table" then
    for _, item in ipairs(value) do
      parts[#parts + 1] = url_encode(key) .. "=" .. url_encode(item)
    end
    return
  end
  parts[#parts + 1] = url_encode(key) .. "=" .. url_encode(value)
end

local function key_part(value)
  local text = tostring(value or "")
  return tostring(#text) .. ":" .. text
end

local function projected_verified_languages(raw)
  local source = type(raw) == "table" and raw.verified_languages or nil
  if type(source) ~= "table" then return {} end

  local out = {}
  for _, item in ipairs(source) do
    if type(item) == "table" then
      local preview_url = nonempty(item.preview_url)
      local language = nonempty(item.language)
      local locale = nonempty(item.locale)
      local accent = nonempty(item.accent)
      if preview_url or language or locale or accent then
        out[#out + 1] = {
          language = language,
          locale = locale,
          accent = accent,
          preview_url = preview_url
        }
      end
    end
  end
  return out
end

function SharedVoicesApi.normalize_query(params)
  params = params or {}
  if type(params) ~= "table" then
    return nil, "query parameters must be a table"
  end

  local normalized = {
    -- Product policy: use neutral chronological catalog navigation. Popular,
    -- featured, cloned-count, and trending rankings are intentionally absent.
    sort = SharedVoicesApi.DEFAULT_SORT
  }

  for _, key in ipairs(SCALAR_FILTERS) do
    normalized[key] = nonempty(params[key])
  end
  for _, key in ipairs(ARRAY_FILTERS) do
    normalized[key] = normalize_string_array(params[key])
  end

  if params.sort ~= nil and trim(params.sort) ~= "" and trim(params.sort) ~= SharedVoicesApi.DEFAULT_SORT then
    return nil, "unsupported Voice Library sort: " .. trim(params.sort)
  end

  return normalized
end

function SharedVoicesApi.query_key(normalized_query)
  if type(normalized_query) ~= "table" then
    return nil, "normalized query must be a table"
  end

  local parts = {}
  for _, key in ipairs(SCALAR_FILTERS) do
    parts[#parts + 1] = key_part(key)
    parts[#parts + 1] = key_part(normalized_query[key])
  end
  for _, key in ipairs(ARRAY_FILTERS) do
    parts[#parts + 1] = key_part(key)
    for _, value in ipairs(normalized_query[key] or {}) do
      parts[#parts + 1] = key_part(value)
    end
    parts[#parts + 1] = "0:"
  end
  parts[#parts + 1] = key_part("sort")
  parts[#parts + 1] = key_part(normalized_query.sort or SharedVoicesApi.DEFAULT_SORT)
  return table.concat(parts, "|")
end

function SharedVoicesApi.build_list_request(api_key, normalized_query, page, page_size)
  local key = nonempty(api_key)
  if not key then return nil, "ElevenLabs API key is missing" end
  if type(normalized_query) ~= "table" then
    return nil, "normalized query must be a table"
  end

  local page_number = tonumber(page)
  if not page_number or page_number < 0 or page_number ~= math.floor(page_number) then
    return nil, "Voice Library page must be a non-negative integer"
  end
  local size = integer_in_range(
    page_size,
    SharedVoicesApi.DEFAULT_PAGE_SIZE,
    1,
    SharedVoicesApi.MAX_PAGE_SIZE
  )

  local query_parts = {
    "page=" .. tostring(page_number),
    "page_size=" .. tostring(size),
    "sort=" .. url_encode(normalized_query.sort or SharedVoicesApi.DEFAULT_SORT)
  }
  for _, filter_key in ipairs(SCALAR_FILTERS) do
    append_query_value(query_parts, filter_key, normalized_query[filter_key])
  end
  for _, filter_key in ipairs(ARRAY_FILTERS) do
    append_query_value(query_parts, filter_key, normalized_query[filter_key])
  end

  return {
    method = "GET",
    url = "https://api.elevenlabs.io/v1/shared-voices?" .. table.concat(query_parts, "&"),
    headers = {
      ["xi-api-key"] = key,
      ["accept"] = "application/json"
    },
    kind = "el_shared_voices",
    label = string.format("Fetch Voice Library page %d", page_number),
    timeout_sec = 120
  }
end

function SharedVoicesApi.build_add_request(
  api_key,
  public_owner_id,
  voice_id,
  new_name
)
  local key = nonempty(api_key)
  if not key then return nil, "ElevenLabs API key is missing" end
  local owner = nonempty(public_owner_id)
  if not owner then return nil, "Shared voice public owner ID is missing" end
  local source_voice_id = nonempty(voice_id)
  if not source_voice_id then return nil, "Shared voice ID is missing" end
  local destination_name = nonempty(new_name)
  if not destination_name then return nil, "Destination voice name is required" end

  return {
    method = "POST",
    url =
      "https://api.elevenlabs.io/v1/voices/add/" ..
      url_encode(owner) .. "/" .. url_encode(source_voice_id),
    headers = {
      ["xi-api-key"] = key,
      ["accept"] = "application/json",
      ["Content-Type"] = "application/json"
    },
    json_payload_tbl = {
      new_name = destination_name,
      bookmarked = false
    },
    kind = "el_add_shared_voice",
    label = "el_add_shared_voice",
    timeout_sec = 120
  }
end

function SharedVoicesApi.parse_add_response(body)
  if type(body) ~= "string" or body == "" then
    return nil, "Add shared voice response body is empty"
  end
  local ok_decode, decoded = pcall(json.decode, body)
  if not ok_decode then
    return nil, "Add shared voice response JSON decode failed"
  end
  if type(decoded) ~= "table" then
    return nil, "Add shared voice response is not an object"
  end
  local account_voice_id = nonempty(decoded.voice_id)
  if not account_voice_id then
    return nil, "Add shared voice response is missing voice_id"
  end
  return {
    voice_id = account_voice_id
  }
end

function SharedVoicesApi.build_reconciliation_request(
  api_key,
  public_owner_id,
  page,
  page_size
)
  local owner = nonempty(public_owner_id)
  if not owner then return nil, "Shared voice public owner ID is missing" end
  local normalized, normalize_err = SharedVoicesApi.normalize_query({
    owner_id = owner
  })
  if not normalized then return nil, normalize_err end
  local req, request_err = SharedVoicesApi.build_list_request(
    api_key,
    normalized,
    page,
    page_size or SharedVoicesApi.MAX_PAGE_SIZE
  )
  if not req then return nil, request_err end
  req.kind = "el_reconcile_shared_voice"
  req.label = "el_reconcile_shared_voice"
  return req
end

function SharedVoicesApi.find_exact_voice(page_data, voice_id)
  local source_voice_id = nonempty(voice_id)
  if not source_voice_id or type(page_data) ~= "table" then return nil end
  for _, row in ipairs(page_data.rows or {}) do
    if tostring(row.voice_id or "") == source_voice_id then
      return row
    end
  end
  return nil
end

function SharedVoicesApi.project_voice(raw)
  if type(raw) ~= "table" then
    return nil, "shared voice is not an object"
  end
  local voice_id = nonempty(raw.voice_id)
  if not voice_id then
    return nil, "shared voice is missing voice_id"
  end

  return {
    voice_id = voice_id,
    public_owner_id = nonempty(raw.public_owner_id),
    name = nonempty(raw.name) or "",
    description = nonempty(raw.description),
    category = nonempty(raw.category),
    preview_url = nonempty(raw.preview_url),
    is_added_by_user = boolean_or_nil(raw.is_added_by_user),
    labels = {
      language = nonempty(raw.language),
      locale = nonempty(raw.locale),
      accent = nonempty(raw.accent),
      gender = nonempty(raw.gender),
      age = nonempty(raw.age),
      use_case = nonempty(raw.use_case),
      descriptive = nonempty(raw.descriptive)
    },
    preview_variants = projected_verified_languages(raw)
  }
end

function SharedVoicesApi.resolve_preview(voice, query)
  if type(voice) ~= "table" then
    return nil, "voice must be a table"
  end
  local voice_id = nonempty(voice.voice_id)
  if not voice_id then return nil, "preview voice ID is missing" end

  query = type(query) == "table" and query or {}
  local requested_language = normalized_match(query.language)
  local requested_accent = normalized_match(query.accent)
  local language_candidate = nil

  if requested_language then
    for _, variant in ipairs(voice.preview_variants or {}) do
      if type(variant) == "table" and nonempty(variant.preview_url) and
         normalized_match(variant.language) == requested_language then
        local variant_accent = normalized_match(variant.accent)
        if not requested_accent or variant_accent == requested_accent then
          return {
            voice = {
              voice_id = voice_id,
              name = tostring(voice.name or voice_id),
              preview_url = nonempty(variant.preview_url),
              public_owner_id = nonempty(voice.public_owner_id),
              language = nonempty(variant.language),
              accent = nonempty(variant.accent)
            },
            match_kind = requested_accent and "exact" or "language",
            language = nonempty(variant.language),
            accent = nonempty(variant.accent),
            warning_code = nil
          }
        end
        if not language_candidate then language_candidate = variant end
      end
    end
  end

  if language_candidate then
    return {
      voice = {
        voice_id = voice_id,
        name = tostring(voice.name or voice_id),
        preview_url = nonempty(language_candidate.preview_url),
        public_owner_id = nonempty(voice.public_owner_id),
        language = nonempty(language_candidate.language),
        accent = nonempty(language_candidate.accent)
      },
      match_kind = "language_mismatch",
      language = nonempty(language_candidate.language),
      accent = nonempty(language_candidate.accent),
      warning_code = "accent_mismatch"
    }
  end

  local top_level_url = nonempty(voice.preview_url)
  if top_level_url then
    return {
      voice = {
        voice_id = voice_id,
        name = tostring(voice.name or voice_id),
        preview_url = top_level_url,
        public_owner_id = nonempty(voice.public_owner_id)
      },
      match_kind = "top_level",
      language = nil,
      accent = nil,
      warning_code = requested_language and "general_preview" or nil
    }
  end

  return {
    voice = nil,
    match_kind = "unavailable",
    language = nil,
    accent = nil,
    warning_code = "unavailable"
  }
end

function SharedVoicesApi.parse_list_response(body)
  if type(body) ~= "string" or body == "" then
    return nil, "Voice Library response body is empty"
  end

  local ok_decode, decoded = pcall(json.decode, body)
  if not ok_decode then
    return nil, "Voice Library response JSON decode failed: " .. tostring(decoded)
  end
  if type(decoded) ~= "table" or type(decoded.voices) ~= "table" then
    return nil, "Voice Library response did not contain a voices array"
  end

  local rows = {}
  local seen = {}
  local duplicate_count = 0
  for index, raw in ipairs(decoded.voices) do
    local row, row_err = SharedVoicesApi.project_voice(raw)
    if not row then
      return nil, string.format("Voice Library row %d is invalid: %s", index, tostring(row_err))
    end
    if seen[row.voice_id] then
      duplicate_count = duplicate_count + 1
    else
      seen[row.voice_id] = true
      rows[#rows + 1] = row
    end
  end

  local total_count = tonumber(decoded.total_count)
  if total_count and (total_count < 0 or total_count ~= math.floor(total_count)) then
    total_count = nil
  end

  return {
    rows = rows,
    has_more = decoded.has_more == true,
    total_count = total_count,
    duplicate_count = duplicate_count
  }
end

function SharedVoicesApi.parse_error(body)
  if type(body) ~= "string" or body == "" then return nil end
  local ok_decode, decoded = pcall(json.decode, body)
  if not ok_decode or type(decoded) ~= "table" then return nil end

  local parts = {}
  for _, key in ipairs({ "status", "statusCode", "code", "error", "title", "message", "detail" }) do
    local value = nonempty(decoded[key])
    if value then parts[#parts + 1] = value end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " - ")
end

return SharedVoicesApi
