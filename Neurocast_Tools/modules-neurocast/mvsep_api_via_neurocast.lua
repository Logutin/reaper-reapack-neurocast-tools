-- Thin authenticated Studio Neurocast transport for the dedicated MVSEP tool.
-- All provider-facing routing remains behind fixed backend routes.

local MVSepViaNeurocast = {}
local Parser = require("modules-neurocast.mvsep_api")

local PRODUCTION_BASE_URL = "https://reaper.neurocast.tech"
local DEVELOPMENT_BASE_URL = "http://localhost:3002"
local ROUTES = {
  algorithms = "/api/mvsep/algorithms",
  create = "/api/mvsep/separation/create",
  status = "/api/mvsep/separation/get",
  download = "/api/mvsep/download",
  cancel = "/api/mvsep/separation/cancel",
  delete = "/api/mvsep/separation/delete"
}

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function shallow_copy(value)
  local out = {}
  for key, item in pairs(type(value) == "table" and value or {}) do out[key] = item end
  return out
end

local function join_url(base_url, path)
  local base = trim(base_url):gsub("/+$", "")
  local suffix = tostring(path or "")
  if suffix:sub(1, 1) ~= "/" then suffix = "/" .. suffix end
  return base .. suffix
end

local function url_encode(value)
  return (tostring(value or ""):gsub("[^%w%-._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function validate_nonempty(value, field_name, do_trim)
  if type(value) ~= "string" then
    return nil, tostring(field_name) .. " must be a string"
  end
  local resolved = do_trim == false and value or trim(value)
  if resolved == "" then
    return nil, tostring(field_name) .. " must be non-empty"
  end
  return resolved
end

local function safe_callback(callback, payload)
  if type(callback) == "function" then callback(payload) end
end

local function make_headers(access_token, accept)
  local token, token_err = validate_nonempty(access_token, "Studio access token", true)
  if not token then return nil, token_err end
  return {
    Authorization = "Bearer " .. token,
    accept = accept or "application/json"
  }
end

local function request_for(client, spec)
  local headers, header_err = make_headers(client.access_token_fn(), spec.accept)
  if not headers then return nil, header_err end
  if spec.json_payload_tbl ~= nil then
    headers["Content-Type"] = "application/json"
  end
  return {
    label = spec.label,
    kind = spec.kind or "mvsep_neurocast",
    method = spec.method,
    url = join_url(client.base_url, spec.path),
    backend_route = spec.route,
    backend_auth = "studio",
    headers = headers,
    form_fields = spec.form_fields,
    json_payload_tbl = spec.json_payload_tbl,
    download_path = spec.download_path,
    follow_redirects = spec.follow_redirects,
    timeout_sec = spec.timeout_sec
  }
end

local function output_format_code(output_format_name)
  local row = Parser.OUTPUT_FORMATS[tostring(output_format_name or Parser.DEFAULT_OUTPUT_FORMAT_NAME)]
  if type(row) ~= "table" or tonumber(row.code) == nil then
    return nil, "Unknown output format: " .. tostring(output_format_name)
  end
  local code = tonumber(row.code)
  if code < 0 or code > 5 or code % 1 ~= 0 then
    return nil, "Output format code is outside the backend contract"
  end
  return tostring(code)
end

local function dynamic_form_fields(field_values)
  local out = {}
  if field_values == nil then return out end
  if type(field_values) ~= "table" then return nil, "field_values must be a table" end
  local keys = {}
  for key, value in pairs(field_values) do
    if value ~= nil and trim(value) ~= "" then
      local key_text = tostring(key)
      local index = tonumber(key_text:match("^add_opt(%d+)$"))
      if not index or index < 1 or index > 10 then
        return nil, "Only add_opt1 through add_opt10 are accepted by the backend contract"
      end
      keys[#keys + 1] = key_text
    end
  end
  table.sort(keys, function(a, b)
    return tonumber(a:match("%d+")) < tonumber(b:match("%d+"))
  end)
  for _, key in ipairs(keys) do
    out[#out + 1] = { name = key, value = trim(field_values[key]) }
  end
  return out
end

local function scopes_query(scopes)
  local source = scopes or Parser.DEFAULT_SCOPES
  if type(source) ~= "table" or #source < 1 then return nil, "scopes must be a non-empty array" end
  local allowed = {
    single_upload = true,
    no_upload = true,
    matchering_upload = true
  }
  local values = {}
  for _, scope in ipairs(source) do
    local value = trim(scope)
    if not allowed[value] then return nil, "Unsupported algorithm scope: " .. value end
    values[#values + 1] = value
  end
  return table.concat(values, ",")
end

local function mutation_is_uncertain(http_code, parsed_error)
  local reported = trim(parsed_error and parsed_error.mutation_outcome or ""):lower()
  if reported ~= "" then return reported == "uncertain" or reported == "unknown" end
  local status = tonumber(http_code)
  return status == nil or status == 408 or status >= 500
end

function MVSepViaNeurocast.production_base_url()
  return PRODUCTION_BASE_URL
end

function MVSepViaNeurocast.development_base_url()
  return DEVELOPMENT_BASE_URL
end

function MVSepViaNeurocast.resolve_base_url(value)
  local candidate = trim(value):gsub("/+$", "")
  if candidate == "" or candidate == PRODUCTION_BASE_URL then return PRODUCTION_BASE_URL end
  if candidate == DEVELOPMENT_BASE_URL then return DEVELOPMENT_BASE_URL end
  return nil, "MVSEP backend must be production or the explicit localhost development endpoint"
end

function MVSepViaNeurocast.classify_base_url(value)
  local resolved = MVSepViaNeurocast.resolve_base_url(value)
  if resolved == DEVELOPMENT_BASE_URL then return "development", "localhost:3002" end
  if resolved == PRODUCTION_BASE_URL then return "production", "reaper.neurocast.tech" end
  return "invalid", ""
end

function MVSepViaNeurocast.route_path(endpoint)
  return ROUTES[endpoint]
end

function MVSepViaNeurocast.create_client(opts)
  opts = type(opts) == "table" and opts or {}
  local base_url, base_err = MVSepViaNeurocast.resolve_base_url(opts.base_url)
  assert(base_url, "mvsep_api_via_neurocast: " .. tostring(base_err))
  local curl_submit_fn = opts.curl_submit_fn
  if type(curl_submit_fn) ~= "function" then
    local Curl = require("modules-neurocast.Curl")
    curl_submit_fn = Curl.curl_submit
  end
  local client = {
    base_url = base_url,
    access_token_fn = type(opts.access_token_fn) == "function" and opts.access_token_fn or function()
      return opts.access_token or ""
    end
  }

  function client:set_base_url(value)
    local resolved, err = MVSepViaNeurocast.resolve_base_url(value)
    if not resolved then return nil, err end
    self.base_url = resolved
    return true
  end

  local function failure_payload(endpoint, result, mutating)
    local parsed_error = Parser.parse_standard_backend_error(
      result and result.body or nil,
      result and result.http_code or nil,
      result and result.headers_txt or nil
    )
    local payload = {
      ok = false,
      endpoint = endpoint,
      backend_route = ROUTES[endpoint],
      http_code = tonumber(result and result.http_code),
      curl_exitcode = tonumber(result and result.exitcode),
      error = parsed_error.message or (result and result.err) or "Studio Neurocast request failed.",
      code = parsed_error.code,
      failure_type = parsed_error.failure_type,
      mutation_outcome = parsed_error.mutation_outcome,
      upstream_status = parsed_error.upstream_status,
      retry_after = parsed_error.retry_after,
      rate_limit = parsed_error.rate_limit,
      rate_remaining = parsed_error.rate_remaining,
      correlation_id = parsed_error.correlation_id
    }
    if payload.failure_type == nil then
      if result and (result.timed_out == true or tonumber(result.exitcode) == 28) then
        payload.failure_type = "stalled_transfer"
      elseif payload.http_code == 401 then
        payload.failure_type = "authentication_required"
      elseif payload.http_code == 400 or payload.http_code == 422 then
        payload.failure_type = "validation_rejection"
      elseif payload.http_code == 429 then
        payload.failure_type = "rate_or_concurrency_rejection"
      elseif (payload.curl_exitcode ~= nil and payload.curl_exitcode ~= 0)
          or payload.http_code == nil
          or payload.http_code == 0 then
        payload.failure_type = "transport_failure"
      elseif payload.http_code >= 500 then
        payload.failure_type = "backend_failure"
      end
    end
    if mutating and result and result.request_not_sent == true then
      payload.mutation_outcome = payload.mutation_outcome or "not_started"
      payload.outcome_uncertain = false
    elseif mutating and mutation_is_uncertain(payload.http_code, parsed_error) then
      payload.mutation_outcome = payload.mutation_outcome or "uncertain"
      payload.outcome_uncertain = true
    end
    return payload
  end

  local function submit_json(endpoint, req, parser_fn, on_done, submit_opts, mutating)
    if not req then return nil, "request is missing" end
    local options = shallow_copy(submit_opts)
    options.read_body = true
    local job, submit_err = curl_submit_fn(req, function(result)
      if not result or result.ok ~= true then
        safe_callback(on_done, failure_payload(endpoint, result, mutating))
        return
      end
      local parsed, parse_err, api_error, parse_meta = parser_fn(result.body)
      if not parsed then
        local payload = failure_payload(endpoint, {
          body = result.body,
          headers_txt = result.headers_txt,
          http_code = result.http_code,
          exitcode = result.exitcode,
          err = parse_err or api_error or "response parse failed"
        }, mutating)
        payload.error = tostring(parse_err or api_error or payload.error)
        if mutating and not (parse_meta and parse_meta.definite_rejection == true) then
          payload.mutation_outcome = payload.mutation_outcome or "uncertain"
          payload.outcome_uncertain = true
          payload.failure_type = payload.failure_type or "malformed_backend_success"
        elseif parse_meta and parse_meta.definite_rejection == true then
          payload.provider_success = false
          payload.mutation_outcome = payload.mutation_outcome or "rejected"
          payload.failure_type = payload.failure_type or "provider_declared_failure"
        else
          payload.failure_type = payload.failure_type or "malformed_backend_success"
        end
        safe_callback(on_done, payload)
        return
      end
      parsed.ok = true
      parsed.endpoint = endpoint
      parsed.backend_route = ROUTES[endpoint]
      parsed.http_code = tonumber(result.http_code)
      safe_callback(on_done, parsed)
    end, options)
    if not job then
      local payload = failure_payload(endpoint, {
        err = submit_err or "submit failed",
        request_not_sent = true
      }, mutating)
      safe_callback(on_done, payload)
      return nil, submit_err
    end
    return job
  end

  function client.build_get_algorithms_request(scopes)
    local query, query_err = scopes_query(scopes)
    if not query then return nil, query_err end
    return request_for(client, {
      method = "GET",
      path = ROUTES.algorithms .. "?scopes=" .. url_encode(query),
      route = ROUTES.algorithms,
      label = "mvsep_neurocast_algorithms"
    })
  end

  function client.build_create_job_request(input_audio_path, sep_type, field_values, output_format_name, is_demo)
    local input_path, input_err = validate_nonempty(input_audio_path, "input_audio_path", false)
    if not input_path then return nil, input_err end
    local separation_type, type_err = validate_nonempty(tostring(sep_type or ""), "sep_type", true)
    if not separation_type then return nil, type_err end
    local format, format_err = output_format_code(output_format_name)
    if not format then return nil, format_err end
    local dynamic, dynamic_err = dynamic_form_fields(field_values)
    if not dynamic then return nil, dynamic_err end
    local fields = {
      { name = "sep_type", value = separation_type },
      { name = "output_format", value = format },
      { name = "is_demo", value = is_demo == true and "1" or "0" },
      { name = "audiofile", filepath = input_path, content_type = "application/octet-stream" }
    }
    for _, field in ipairs(dynamic) do fields[#fields + 1] = field end
    return request_for(client, {
      method = "POST",
      path = ROUTES.create,
      route = ROUTES.create,
      label = "mvsep_neurocast_create",
      form_fields = fields
    })
  end

  function client.build_get_job_status_request(job_hash)
    local hash, hash_err = validate_nonempty(job_hash, "job_hash", true)
    if not hash then return nil, hash_err end
    return request_for(client, {
      method = "GET",
      path = ROUTES.status .. "?hash=" .. url_encode(hash),
      route = ROUTES.status,
      label = "mvsep_neurocast_status"
    })
  end

  function client.build_download_result_request(download_url, download_path)
    local target, target_err = validate_nonempty(download_url, "download_url", true)
    if not target then return nil, target_err end
    if not target:match("^https://") or target:find("[%c%s]") then
      return nil, "download_url is not an approved HTTPS provider target"
    end
    local destination, destination_err = validate_nonempty(download_path, "download_path", false)
    if not destination then return nil, destination_err end
    return request_for(client, {
      method = "GET",
      path = ROUTES.download .. "?url=" .. url_encode(target),
      route = ROUTES.download,
      label = "mvsep_neurocast_download",
      accept = "application/octet-stream, audio/*",
      download_path = destination,
      -- The backend streams the provider result. Refusing redirects guarantees
      -- that curl cannot be sent to a provider or CDN target by a response.
      follow_redirects = false
    })
  end

  local function build_mutation_request(endpoint, job_hash)
    local hash, hash_err = validate_nonempty(job_hash, "job_hash", true)
    if not hash then return nil, hash_err end
    return request_for(client, {
      method = "POST",
      path = ROUTES[endpoint],
      route = ROUTES[endpoint],
      label = "mvsep_neurocast_" .. endpoint,
      json_payload_tbl = { hash = hash }
    })
  end

  function client.build_cancel_job_request(job_hash)
    return build_mutation_request("cancel", job_hash)
  end

  function client.build_delete_job_request(job_hash)
    return build_mutation_request("delete", job_hash)
  end

  function client.submit_get_algorithms(scopes, on_done, submit_opts)
    local req, err = client.build_get_algorithms_request(scopes)
    if not req then
      safe_callback(on_done, { ok = false, endpoint = "algorithms", error = err, failure_type = "validation_rejection" })
      return nil, err
    end
    return submit_json("algorithms", req, function(body)
      return Parser.parse_algorithms_body(body, {
        source_label = "studio_neurocast",
        requested_scopes = scopes or Parser.DEFAULT_SCOPES
      })
    end, function(payload)
      if payload and payload.ok then
        safe_callback(on_done, {
          ok = true,
          endpoint = "algorithms",
          backend_route = ROUTES.algorithms,
          http_code = payload.http_code,
          catalog = payload
        })
      else
        safe_callback(on_done, payload)
      end
    end, submit_opts, false)
  end

  function client.submit_create_job(input_audio_path, sep_type, field_values, output_format_name, is_demo, on_done, submit_opts)
    local req, err = client.build_create_job_request(input_audio_path, sep_type, field_values, output_format_name, is_demo)
    if not req then
      safe_callback(on_done, {
        ok = false,
        endpoint = "create",
        error = err,
        failure_type = "validation_rejection",
        mutation_outcome = "not_started"
      })
      return nil, err
    end
    return submit_json("create", req, Parser.parse_create_job_body, on_done, submit_opts, true)
  end

  function client.submit_get_job_status(job_hash, on_done, submit_opts)
    local req, err = client.build_get_job_status_request(job_hash)
    if not req then
      safe_callback(on_done, { ok = false, endpoint = "status", error = err, failure_type = "validation_rejection" })
      return nil, err
    end
    return submit_json("status", req, Parser.parse_get_job_status_body, on_done, submit_opts, false)
  end

  function client.submit_download_result(download_url, download_path, on_done, submit_opts)
    local req, err = client.build_download_result_request(download_url, download_path)
    if not req then
      safe_callback(on_done, { ok = false, endpoint = "download", error = err, failure_type = "unsafe_download_target" })
      return nil, err
    end
    local options = shallow_copy(submit_opts)
    options.read_body = false
    options.keep_output = true
    local job, submit_err = curl_submit_fn(req, function(result)
      if not result or result.ok ~= true then
        safe_callback(on_done, failure_payload("download", result, false))
        return
      end
      safe_callback(on_done, {
        ok = true,
        endpoint = "download",
        backend_route = ROUTES.download,
        http_code = tonumber(result.http_code),
        download_path = download_path,
        downloaded_bytes = tonumber(result.size_download),
        content_type = tostring(result.content_type or "")
      })
    end, options)
    if not job then
      safe_callback(on_done, failure_payload("download", {
        err = submit_err or "submit failed",
        request_not_sent = true
      }, false))
      return nil, submit_err
    end
    return job
  end

  function client.submit_cancel_job(job_hash, on_done, submit_opts)
    local req, err = client.build_cancel_job_request(job_hash)
    if not req then
      safe_callback(on_done, {
        ok = false,
        endpoint = "cancel",
        error = err,
        failure_type = "validation_rejection",
        mutation_outcome = "not_started"
      })
      return nil, err
    end
    return submit_json("cancel", req, function(body)
      return Parser.parse_mutation_body(body, "cancel")
    end, on_done, submit_opts, true)
  end

  function client.submit_delete_job(job_hash, on_done, submit_opts)
    local req, err = client.build_delete_job_request(job_hash)
    if not req then
      safe_callback(on_done, {
        ok = false,
        endpoint = "delete",
        error = err,
        failure_type = "validation_rejection",
        mutation_outcome = "not_started"
      })
      return nil, err
    end
    return submit_json("delete", req, function(body)
      return Parser.parse_mutation_body(body, "delete")
    end, on_done, submit_opts, true)
  end

  return client
end

return MVSepViaNeurocast
