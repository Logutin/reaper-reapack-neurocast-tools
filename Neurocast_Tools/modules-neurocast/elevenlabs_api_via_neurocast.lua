-- Thin Studio Neurocast proxy helper for ElevenLabs-tool routing.
-- Keeps backend URLs and Studio bearer headers out of the user-facing workflow.

local ElevenLabsViaNeurocast = {}

local ok_util, Util = pcall(require, "modules-neurocast.Util")
if not ok_util or type(Util) ~= "table" then
  error("elevenlabs_api_via_neurocast: modules-neurocast.Util is required: " .. tostring(Util))
end

local PRODUCTION_BASE_URL = "https://studio.neurocast.tech"

local function trim(value)
  if type(Util.trim) == "function" then
    return Util.trim(value)
  end
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function join_url(base_url, path)
  if type(Util.join_url) == "function" then
    return Util.join_url(base_url, path)
  end
  local base = trim(base_url)
  local p = tostring(path or "")
  if base:sub(-1) == "/" and p:sub(1, 1) == "/" then
    return base:sub(1, -2) .. p
  end
  if base:sub(-1) ~= "/" and p:sub(1, 1) ~= "/" then
    return base .. "/" .. p
  end
  return base .. p
end

local function url_encode(value)
  if type(Util.url_encode_path_segment) == "function" then
    return Util.url_encode_path_segment(value)
  end
  return (tostring(value or ""):gsub("[^%w%-._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function normalize_base_url(base_url)
  local text = trim(base_url)
  if text == "" then
    return PRODUCTION_BASE_URL
  end
  text = text:gsub("/+$", "")
  return text
end

local function query_string(params)
  local out = {}
  for _, item in ipairs(params or {}) do
    local name = item and item[1]
    local value = item and item[2]
    if name and type(value) == "table" then
      for _, array_value in ipairs(value) do
        if tostring(array_value or "") ~= "" then
          out[#out + 1] = tostring(name) .. "=" .. url_encode(array_value)
        end
      end
    elseif name and value ~= nil and tostring(value) ~= "" then
      out[#out + 1] = tostring(name) .. "=" .. url_encode(value)
    end
  end
  if #out < 1 then return "" end
  return "?" .. table.concat(out, "&")
end

local function make_headers(access_token, accept, content_type)
  local token = trim(access_token)
  if token == "" then
    return nil, "Studio access token is missing."
  end
  local headers = {
    Authorization = "Bearer " .. token
  }
  if accept and accept ~= "" then
    headers.accept = accept
  end
  if content_type and content_type ~= "" then
    headers["Content-Type"] = content_type
  end
  return headers
end

local function make_req(client, spec)
  local headers, header_err = make_headers(client.access_token_fn(), spec.accept, spec.content_type)
  if not headers then return nil, header_err end
  local req = {
    method = spec.method,
    url = join_url(client.base_url, spec.path),
    headers = headers,
    kind = spec.kind,
    label = spec.label,
    timeout_sec = spec.timeout_sec,
    backend_auth = "studio"
  }
  if spec.json_payload_tbl ~= nil then req.json_payload_tbl = spec.json_payload_tbl end
  if spec.form_fields ~= nil then req.form_fields = spec.form_fields end
  if spec.download_path ~= nil then req.download_path = spec.download_path end
  return req, nil
end

function ElevenLabsViaNeurocast.production_base_url()
  return PRODUCTION_BASE_URL
end

function ElevenLabsViaNeurocast.resolve_base_url(override)
  return normalize_base_url(override)
end

function ElevenLabsViaNeurocast.create_client(opts)
  opts = opts or {}
  local client = {
    base_url = normalize_base_url(opts.base_url),
    access_token_fn = type(opts.access_token_fn) == "function" and opts.access_token_fn or function()
      return opts.access_token or ""
    end
  }

  function client:set_base_url(base_url)
    self.base_url = normalize_base_url(base_url)
  end

  function client:models_request(label, timeout_sec)
    return make_req(self, {
      method = "GET",
      path = "/api/elevenlabs/models",
      accept = "application/json",
      kind = "el_models",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:voices_request(params, label, timeout_sec)
    params = params or {}
    local path = "/api/elevenlabs/voices" .. query_string({
      { "page_size", params.page_size },
      { "include_total_count", params.include_total_count },
      { "search", params.search },
      { "next_page_token", params.next_page_token }
    })
    return make_req(self, {
      method = "GET",
      path = path,
      accept = "application/json",
      kind = "el_voices",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:shared_voices_request(params, page, page_size, label, timeout_sec)
    params = params or {}
    local path = "/api/elevenlabs/shared-voices" .. query_string({
      { "page", page },
      { "page_size", page_size },
      { "sort", params.sort },
      { "category", params.category },
      { "gender", params.gender },
      { "age", params.age },
      { "accent", params.accent },
      { "language", params.language },
      { "locale", params.locale },
      { "search", params.search },
      { "owner_id", params.owner_id },
      { "use_cases", params.use_cases },
      { "descriptives", params.descriptives }
    })
    return make_req(self, {
      method = "GET",
      path = path,
      accept = "application/json",
      kind = "el_shared_voices",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:add_shared_voice_request(public_owner_id, voice_id, new_name, label, timeout_sec)
    local owner = trim(public_owner_id)
    if owner == "" then return nil, "Shared voice public owner ID is missing" end
    local source_voice_id = trim(voice_id)
    if source_voice_id == "" then return nil, "Shared voice ID is missing" end
    local destination_name = trim(new_name)
    if destination_name == "" then return nil, "Destination voice name is required" end
    return make_req(self, {
      method = "POST",
      path = "/api/elevenlabs/shared-voices/add-to-account",
      accept = "application/json",
      content_type = "application/json",
      json_payload_tbl = {
        public_owner_id = owner,
        voice_id = source_voice_id,
        new_name = destination_name,
        bookmarked = false
      },
      kind = "el_add_shared_voice",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:account_voice_preview_request(
    voice_id,
    language,
    accent,
    download_path,
    label,
    timeout_sec
  )
    local source_voice_id = trim(voice_id)
    if source_voice_id == "" then return nil, "Account voice ID is missing" end
    return make_req(self, {
      method = "GET",
      path =
        "/api/elevenlabs/voices/" .. url_encode(source_voice_id) ..
        "/preview/stream" .. query_string({
          { "language", trim(language) },
          { "accent", trim(accent) }
        }),
      accept = "audio/mpeg, audio/wav",
      download_path = download_path,
      kind = "el_account_voice_preview",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:shared_voice_preview_request(
    public_owner_id,
    voice_id,
    language,
    accent,
    download_path,
    label,
    timeout_sec
  )
    local owner = trim(public_owner_id)
    if owner == "" then return nil, "Shared voice public owner ID is missing" end
    local source_voice_id = trim(voice_id)
    if source_voice_id == "" then return nil, "Shared voice ID is missing" end
    return make_req(self, {
      method = "GET",
      path =
        "/api/elevenlabs/shared-voices/" .. url_encode(owner) .. "/" ..
        url_encode(source_voice_id) .. "/preview/stream" .. query_string({
          { "language", trim(language) },
          { "accent", trim(accent) }
        }),
      accept = "audio/mpeg, audio/wav",
      download_path = download_path,
      kind = "el_shared_voice_preview",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:delete_voice_request(voice_id, label, timeout_sec)
    return make_req(self, {
      method = "DELETE",
      path = "/api/elevenlabs/voices/" .. url_encode(voice_id),
      accept = "application/json",
      kind = "el_voice_delete",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:voice_design_request(payload, output_format, label, timeout_sec)
    return make_req(self, {
      method = "POST",
      path = "/api/elevenlabs/text-to-voice/design" .. query_string({
        { "output_format", output_format }
      }),
      accept = "application/json",
      content_type = "application/json",
      json_payload_tbl = payload,
      kind = "el_voice_design",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:voice_preview_stream_request(generated_voice_id, download_path, label, timeout_sec)
    return make_req(self, {
      method = "GET",
      path = "/api/elevenlabs/text-to-voice/" .. url_encode(generated_voice_id) .. "/stream",
      accept = "audio/mpeg",
      download_path = download_path,
      kind = "el_voice_preview",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:create_voice_from_preview_request(payload, label, timeout_sec)
    return make_req(self, {
      method = "POST",
      path = "/api/elevenlabs/text-to-voice",
      accept = "application/json",
      content_type = "application/json",
      json_payload_tbl = payload,
      kind = "el_voice_create",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:ivc_create_request(form_fields, label, timeout_sec)
    return make_req(self, {
      method = "POST",
      path = "/api/elevenlabs/voices/add",
      accept = "application/json",
      form_fields = form_fields,
      kind = "el_ivc_create",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:speech_to_speech_request(voice_id, output_format, form_fields, download_path, label, timeout_sec)
    return make_req(self, {
      method = "POST",
      path = "/api/elevenlabs/speech-to-speech/" .. url_encode(voice_id) .. query_string({
        { "output_format", output_format }
      }),
      form_fields = form_fields,
      download_path = download_path,
      kind = "el_sts",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:text_to_speech_request(voice_id, output_format, payload, download_path, label, timeout_sec)
    return make_req(self, {
      method = "POST",
      path = "/api/elevenlabs/text-to-speech/" .. url_encode(voice_id) .. query_string({
        { "output_format", output_format }
      }),
      accept = "application/json",
      content_type = "application/json",
      json_payload_tbl = payload,
      download_path = download_path,
      kind = "el_tts",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  function client:openai_rewrite_request(payload, label, timeout_sec)
    return make_req(self, {
      method = "POST",
      path = "/api/openai/rewrite",
      content_type = "application/json",
      json_payload_tbl = payload,
      kind = "openai_rewrite",
      label = label,
      timeout_sec = timeout_sec
    })
  end

  return client
end

return ElevenLabsViaNeurocast
