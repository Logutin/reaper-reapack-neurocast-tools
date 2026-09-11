-- AutoMix transport for the dedicated backend (OpenAPI 2026-09-07).
-- Mutations are sent once. Acknowledgements always require production readback.
local M = {}
local json = require("modules-neurocast.json")
local NeurocastAuth = require("modules-neurocast.neurocast_auth")

M.PRODUCTION_BASE = "https://reaper.neurocast.tech"
M.DEVELOPMENT_BASE = "http://localhost:3002"

local function copy(value)
  local out = {}
  for key, item in pairs(value or {}) do out[key] = item end
  return out
end

local function decode(body)
  local ok, value = pcall(json.decode, body or "")
  if ok and type(value) == "table" then return value end
end

local function nonblank(value)
  return type(value) == "string" and value:find("%S") ~= nil
end

function M.resolve_base_url(value)
  local base = tostring(value or M.PRODUCTION_BASE):gsub("/+$", "")
  if base == M.PRODUCTION_BASE or base == M.DEVELOPMENT_BASE then return base end
  return nil, "Choose the production backend or localhost:3002."
end

function M.encode_segment(value)
  return (tostring(value or ""):gsub("[^%w%-._~]", function(ch)
    return string.format("%%%02X", ch:byte())
  end))
end

function M.parse_error(result, mutating)
  result = result or {}
  local body = decode(result.body) or {}
  local details = type(body.details) == "table" and body.details or {}
  local status = tonumber(result.http_code)
  local message = body.message
  if type(message) == "table" then message = table.concat(message, "; ") end
  if type(message) ~= "string" or message == "" then
    message = (result.timed_out or tonumber(result.exitcode) == 28)
      and "Transfer stalled or timed out." or "Backend request failed."
  end
  local uncertain = mutating == true and not result.request_not_sent and
    (details.mutationOutcome == "uncertain" or
      (details.mutationOutcome ~= "definite_rejection" and
        (not status or status == 0 or status == 408 or status >= 500)))
  return {
    ok = false, http_code = status, error = message, api_error = message,
    code = body.code, correlation_id = body.correlationId,
    reauthenticate = details.action == "reauthenticate",
    mutation_outcome = details.mutationOutcome, outcome_uncertain = uncertain == true,
    upstream_status = details.upstreamStatus, retry_after = details.retryAfter,
    request_not_sent = result.request_not_sent == true
  }
end

-- Reuse the existing token parser, storage helpers, timing policy and refresh gate.
-- The session belongs to AutoMix; it never rotates a sibling tool's saved token.
function M.create_session(opts)
  local base = assert(M.resolve_base_url(opts.base_url))
  local auth = NeurocastAuth.create_client({
    base_url = base, ext_section = opts.ext_section, ext_refresh_key = opts.ext_refresh_key,
    curl_submit_fn = opts.curl_submit_fn, remember_refresh = false
  })
  local gate = NeurocastAuth.create_refresh_gate()
  local session = { access_token = "", refresh_token = "" }
  local refresh_failure = nil

  local function publish(warning)
    if opts.on_tokens then opts.on_tokens(session, warning) end
  end

  function session.load_refresh_token()
    local token, err = auth.load_refresh_token()
    if token then session.refresh_token = token end
    return token, err
  end

  function session.forget_refresh_token()
    return auth.forget_refresh_token()
  end

  function session.clear()
    session.access_token, session.refresh_token = "", ""
    refresh_failure = nil
    auth.clear_runtime_tokens()
    publish()
  end

  local function authenticate(req, expected_status, callback, submit_opts)
    if not req then callback({ ok = false, error = "Invalid login request." }); return nil end
    local completed = false
    local function finish(payload)
      if completed then return end
      completed = true
      callback(payload)
    end
    local job, err = opts.curl_submit_fn(req, function(result)
      if not result or result.ok ~= true or tonumber(result.http_code) ~= expected_status then
        finish(M.parse_error(result))
        return
      end
      local tokens = auth.parse_token_body(result.body)
      if not tokens then
        finish({ ok = false, error = "Backend returned an invalid token pair." })
        return
      end
      session.access_token, session.refresh_token = tokens.access_token, tokens.refresh_token
      auth.set_tokens(tokens.access_token, tokens.refresh_token)
      refresh_failure = nil
      local warning
      if opts.remember_fn() then
        local saved, save_err = auth.persist_refresh_token(tokens.refresh_token)
        if not saved then warning = "Could not save the refreshed login: " .. tostring(save_err) end
      else
        auth.forget_refresh_token()
      end
      publish(warning)
      tokens.ok, tokens.http_code = true, result.http_code
      finish(tokens)
    end, submit_opts)
    if not job then finish({ ok = false, error = err or "Login request could not start.", request_not_sent = true }) end
    return job, err
  end

  function session.submit_login(email, password, callback, submit_opts)
    if gate.is_in_flight() then return nil, "Login refresh is already running." end
    local req, err = auth.build_login_request(email, password)
    if not req then return nil, err end
    return authenticate(req, 201, callback, submit_opts)
  end

  function session.submit_refresh(callback, submit_opts)
    local refresh_job
    gate.request(function(done)
      local token = session.refresh_token
      if not nonblank(token) then token = session.load_refresh_token() end
      if not nonblank(token) then
        done(false, { ok = false, error = "No stored login. Please log in." })
        return true
      end
      local req = assert(auth.build_refresh_request(token))
      req.json_payload_tbl.refresh_token = token -- opaque: preserve the exact stored value
      refresh_job = authenticate(req, 200, function(payload)
        if not payload.ok then
          refresh_failure = payload -- no automatic repeat of a possibly consumed refresh token
          if payload.reauthenticate then
            session.forget_refresh_token()
            session.access_token, session.refresh_token = "", ""
            publish()
          end
        end
        done(payload.ok, payload)
      end, submit_opts)
      return true
    end, callback, callback)
    return refresh_job or { waiting_for_auth = true }
  end

  function session.submit(req, callback, submit_opts)
    local options = copy(submit_opts)
    local returned_job
    local auth_retried = false
    local function auth_failed(payload)
      callback({ ok = false, http_code = payload.http_code, request_not_sent = true,
        body = json.encode({ message = payload.error, details = {
          action = payload.reauthenticate and "reauthenticate" or nil
        } }) })
    end
    local function dispatch()
      local request = copy(req)
      request.headers = copy(req.headers)
      request.headers.Authorization = "Bearer " .. session.access_token
      local completed = false
      local function receive(result, job)
        if completed then return end
        completed = true
        if result and tonumber(result.http_code) == 401 and not auth_retried then
          auth_retried = true
          if refresh_failure then auth_failed(refresh_failure); return end
          session.submit_refresh(function(payload)
            if payload.ok then dispatch() else auth_failed(payload) end
          end, { read_body = true, keep_output = false })
          return
        end
        callback(result, job)
      end
      local job, err = opts.curl_submit_fn(request, receive, options)
      returned_job = job
      if not job then receive({ ok = false, request_not_sent = true, err = err }) end
    end
    local timing = auth.access_token_refresh_status(session.access_token)
    if gate.is_in_flight() or session.access_token == "" or (timing and timing.refresh_due) then
      if refresh_failure then auth_failed(refresh_failure)
      else
        session.submit_refresh(function(payload)
          if payload.ok then dispatch() else auth_failed(payload) end
        end, { read_body = true, keep_output = false })
      end
    else dispatch() end
    return returned_job or { waiting_for_auth = true }
  end
  return session
end

function M.production_is_done(details)
  return type(details) == "table" and tonumber(details.status) == 3
end

function M.valid_input_id(value)
  if not nonblank(value) or not utf8.len(value) then return false end
  if value:find('[%z\1-\31\127"\\]') then return false end
  for _, code in utf8.codes(value) do if code >= 128 and code <= 159 then return false end end
  local reserved = { input_file = true, image = true, intro_file = true, outro_file = true,
    chapters = true, action = true, start = true }
  return not reserved[value:match("^%s*(.-)%s*$"):lower()]
end

function M.validate_download(path, result)
  if not result or result.ok ~= true or tonumber(result.http_code) ~= 200
      or tonumber(result.exitcode) ~= 0 then return nil, "Download did not complete." end
  local file = io.open(path, "rb")
  if not file then return nil, "Downloaded file is missing." end
  local size = file:seek("end")
  file:seek("set", 0)
  local head = file:read(16) or ""
  file:close()
  if not size or size <= 0 or size ~= tonumber(result.size_download) then
    return nil, "Downloaded file size does not match the completed transfer."
  end
  local length = tostring(result.headers_txt or ""):lower():match("content%-length:%s*(%d+)")
  if length and tonumber(length) ~= size then return nil, "Downloaded file is incomplete." end
  local content_type = tostring(result.content_type or ""):lower()
  if content_type:find("json", 1, true) or content_type:find("text/", 1, true)
      or head:match("^%s*[{<]") then return nil, "Backend returned an error document instead of media." end
  return true
end

function M.create_client(opts)
  local base = assert(M.resolve_base_url(opts.base_url))
  local submit = assert(opts.curl_submit_fn)
  local client = {}
  local function request(method, path, token, payload)
    return { label = "automix_" .. method:lower(), kind = "auphonic_neurocast", method = method,
      url = base .. path, backend_auth = "studio", backend_route = path, follow_redirects = false,
      headers = { Authorization = "Bearer " .. tostring(token), accept = "application/json",
        ["Content-Type"] = payload and "application/json" or nil }, json_payload_tbl = payload }
  end
  local function production_path(uuid)
    assert(nonblank(uuid), "Production UUID is missing.")
    return "/api/auphonic/production/" .. M.encode_segment(uuid)
  end
  local function send(req, callback, options)
    local finished = false
    local function receive(result)
      if finished then return end
      finished = true
      local status = tonumber(result and result.http_code)
      if not result or result.ok ~= true or not status or status < 200 or status >= 300 then
        callback(M.parse_error(result, req.method ~= "GET")); return
      end
      local data = decode(result.body)
      if not data then
        callback({ ok = false, http_code = status, error = "Backend returned invalid JSON.",
          outcome_uncertain = req.method ~= "GET" }); return
      end
      callback({ ok = true, http_code = status, data = data })
    end
    local job, err = submit(req, receive, options)
    if not job then receive({ ok = false, request_not_sent = true, err = err }) end
    return job or { completed = true }, err
  end
  local function read_production(token, uuid, callback, options)
    return send(request("GET", production_path(uuid), token), function(payload)
      if payload.ok then
        if payload.data.uuid ~= uuid then
          payload.ok, payload.error = false, "Production readback returned a different or missing UUID."
        else payload.production_details, payload.production_uuid = payload.data, uuid end
      end
      callback(payload)
    end, options)
  end
  local function mutate_and_read(req, token, uuid, callback, options)
    return send(req, function(payload)
      if not payload.ok then payload.production_uuid = uuid; callback(payload); return end
      if payload.data.success ~= true then
        callback({ ok = false, error = "Backend did not acknowledge the operation.",
          production_uuid = uuid, outcome_uncertain = true }); return
      end
      read_production(token, uuid, function(readback)
        readback.mutation_succeeded = true
        readback.readback_failed = not readback.ok
        readback.production_uuid = uuid
        callback(readback)
      end, options)
    end, options)
  end

  function client.submit_get_presets(token, callback, options)
    return send(request("GET", "/api/auphonic/presets", token), function(payload)
      if payload.ok then
        payload.presets = {}
        for _, preset in ipairs(payload.data) do
          if preset.is_multitrack == true then
            local item = copy(preset)
            item.name = preset.display_name or preset.preset_name or preset.uuid
            payload.presets[#payload.presets + 1] = item
          end
        end
      end
      callback(payload)
    end, options)
  end
  function client.submit_get_preset_details(token, uuid, callback, options)
    return send(request("GET", "/api/auphonic/presets/" .. M.encode_segment(uuid), token), function(payload)
      if payload.ok then
        if payload.data.uuid ~= uuid then payload.ok, payload.error = false, "Preset UUID is missing or differs."
        else payload.preset_details = payload.data end
      end
      callback(payload)
    end, options)
  end
  function client.submit_create_production(token, value, callback, options)
    if type(value) ~= "table" or value.is_multitrack ~= true then
      callback({ ok = false, error = "AutoMix supports only multitrack productions.", request_not_sent = true })
      return { completed = true }
    end
    local payload = copy(value)
    payload.action = "save"
    return send(request("POST", "/api/auphonic/productions", token, payload), function(response)
      if response.ok then
        if not nonblank(response.data.uuid) then
          response.ok, response.outcome_uncertain = false, true
          response.error = "Creation returned no production UUID. Check the backend before creating again."
        else response.production_details, response.production_uuid = response.data, response.data.uuid end
      end
      callback(response)
    end, options)
  end
  client.submit_get_production_status = read_production
  function client.submit_set_production_output_files(token, uuid, outputs, callback, options)
    return mutate_and_read(request("POST", production_path(uuid) .. "/output_files", token, outputs),
      token, uuid, callback, options)
  end
  function client.submit_delete_production_output_files(token, uuid, callback, options)
    return mutate_and_read(request("DELETE", production_path(uuid) .. "/output_files", token),
      token, uuid, callback, options)
  end
  function client.submit_start_production(token, uuid, callback, options)
    return mutate_and_read(request("POST", production_path(uuid) .. "/start", token),
      token, uuid, callback, options)
  end
  function client.submit_configure_outputs(token, uuid, adjustment, callback, options)
    local function has_stems(details)
      for _, output in ipairs(details.output_files or {}) do
        if output.format == "tracks" then return true end
      end
      return false
    end
    local function contains(actual, wanted)
      if type(wanted) ~= "table" then return actual == wanted end
      if type(actual) ~= "table" then return false end
      for key, value in pairs(wanted) do if not contains(actual[key], value) then return false end end
      return true
    end
    local function matches(details)
      if adjustment.kind == "remove_tracks" and has_stems(details) then return false end
      for _, wanted in ipairs(adjustment.output_files or {}) do
        local found = false
        for _, actual in ipairs(details.output_files or {}) do
          if contains(actual, wanted) then found = true; break end
        end
        if not found then return false end
      end
      return true
    end
    local function restore()
      client.submit_set_production_output_files(token, uuid, adjustment.output_files, function(response)
        if response.ok and not matches(response.production_details) then
          response.ok, response.error = false, "Output settings were acknowledged but are not confirmed in readback."
        end
        callback(response)
      end, options)
    end
    return read_production(token, uuid, function(response)
      if not response.ok or matches(response.production_details) then callback(response); return end
      if adjustment.kind == "remove_tracks" and has_stems(response.production_details) then
        client.submit_delete_production_output_files(token, uuid, function(cleared)
          if not cleared.ok then callback(cleared); return end
          if #(cleared.production_details.output_files or {}) ~= 0 then
            callback({ ok = false, error = "Output clearing is not confirmed. Check status before continuing." })
            return
          end
          restore()
        end, options)
      else restore() end
    end, options)
  end
  function client.submit_upload_audio(token, uuid, fields, callback, options)
    for _, field in ipairs(fields) do
      if not M.valid_input_id(field.name) then
        callback({ ok = false, error = "The production contains an unsupported named input ID.", request_not_sent = true })
        return { completed = true }
      end
    end
    -- Read before every manual continuation; acknowledged matching files are skipped.
    return read_production(token, uuid, function(initial)
      if not initial.ok then callback(initial); return end
      local existing = {}
      for _, input in ipairs(initial.production_details.multi_input_files or {}) do existing[input.id] = input end
      local function upload_index(index, last)
        if index > #fields then callback(last); return end
        local field = fields[index]
        local input = existing[field.name]
        if not input then callback({ ok = false, error = "Production input ID is missing from readback." }); return end
        local basename = field.filepath:match("[^/\\]+$")
        local remote_name = tostring(input.input_file or ""):match("[^/\\]+$")
        if remote_name == basename then upload_index(index + 1, last); return end
        if options and options.on_upload then options.on_upload(index, #fields) end
        local req = request("POST", production_path(uuid) .. "/upload", token)
        req.form_fields = {
          { name = "input_file", filepath = field.filepath, content_type = field.content_type },
          { name = "input_id", value = field.name, literal = true }
        }
        mutate_and_read(req, token, uuid, function(response)
          if not response.ok then callback(response); return end
          local confirmed
          for _, updated in ipairs(response.production_details.multi_input_files or {}) do
            if updated.id == field.name then confirmed = tostring(updated.input_file or ""):match("[^/\\]+$") == basename end
          end
          if not confirmed then
            callback({ ok = false, error = "Upload acknowledged, but the named input is not confirmed in readback.",
              production_uuid = uuid, mutation_succeeded = true, readback_failed = true }); return
          end
          upload_index(index + 1, response)
        end, options)
      end
      upload_index(1, initial)
    end, options)
  end
  function client.submit_download_result(token, uuid, filename, path, callback, options)
    local req = request("GET", "/api/auphonic/download/" .. M.encode_segment(uuid) .. "/" .. M.encode_segment(filename), token)
    req.download_path, req.headers.accept = path, "application/octet-stream"
    local finished = false
    local function receive(result)
      if finished then return end
      finished = true
      local valid, err = M.validate_download(path, result)
      if not valid then
        os.remove(path)
        local failure = M.parse_error(result)
        failure.error, failure.api_error = err, err
        callback(failure)
      else callback({ ok = true, http_code = result.http_code, download_path = path }) end
    end
    local job, err = submit(req, receive, options)
    if not job then receive({ ok = false, request_not_sent = true, err = err }) end
    return job or { completed = true }, err
  end
  return client
end

return M
