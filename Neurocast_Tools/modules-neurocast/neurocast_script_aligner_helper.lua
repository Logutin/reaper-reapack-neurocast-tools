-- Neurocast Script Aligner helper module.
-- Public entry point: NeurocastScriptAlignerHelper.create_client(opts)

local NeurocastScriptAlignerHelper = {}
local Util = require("modules-neurocast.Util")
local json = require("modules-neurocast.json")
if type(json) ~= "table" or type(json.decode) ~= "function" or type(json.encode) ~= "function" then
  error("neurocast_script_aligner_helper: JSON module not available (required 'modules-neurocast.json')")
end
local Curl = require("modules-neurocast.Curl")
if type(Curl) ~= "table" or type(Curl.curl_submit) ~= "function" then
  error("neurocast_script_aligner_helper: Curl module not available (required 'modules-neurocast.Curl')")
end

local trim = Util.trim
local join_url = Util.join_url

local function shallow_copy(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do out[k] = v end
  return out
end

local function validate_nonempty_string(value, field_name, trim_value)
  if type(value) ~= "string" then return nil, field_name .. " must be a string" end
  local text = trim_value and trim(value) or value
  if text == "" then return nil, field_name .. " must be a non-empty string" end
  return text
end

local function validate_integer(value, field_name, min_v, max_v)
  local n = tonumber(value)
  if n == nil or math.floor(n) ~= n then return nil, field_name .. " must be an integer" end
  if min_v and n < min_v then return nil, field_name .. " must be >= " .. tostring(min_v) end
  if max_v and n > max_v then return nil, field_name .. " must be <= " .. tostring(max_v) end
  return n
end

local function validate_number(value, field_name, min_v, max_v)
  local n = tonumber(value)
  if n == nil then return nil, field_name .. " must be a number" end
  if min_v and n < min_v then return nil, field_name .. " must be >= " .. tostring(min_v) end
  if max_v and n > max_v then return nil, field_name .. " must be <= " .. tostring(max_v) end
  return n
end

local function looks_like_http_url(text)
  local s = trim(text):lower()
  return s:match("^https?://") ~= nil
end

local function make_json_headers()
  return { accept = "application/json", ["Content-Type"] = "application/json" }
end

local function with_bearer(headers, access_token)
  local out = shallow_copy(headers)
  out.Authorization = "Bearer " .. tostring(access_token or "")
  return out
end

local function decode_json_object(body_txt)
  if type(body_txt) ~= "string" or body_txt == "" then return nil, "empty body" end
  local ok, decoded = pcall(json.decode, body_txt)
  if not ok then return nil, "JSON decode failed: " .. tostring(decoded) end
  if type(decoded) ~= "table" then return nil, "decoded JSON is not an object" end
  return decoded
end

local function decode_json_any(body_txt)
  if type(body_txt) ~= "string" or body_txt == "" then return nil, "empty body" end
  local ok, decoded = pcall(json.decode, body_txt)
  if not ok then return nil, "JSON decode failed: " .. tostring(decoded) end
  return decoded
end

local is_array_like = Util.is_array_like

local function parse_api_error_from_obj(decoded)
  if type(decoded) ~= "table" then return nil end
  local parts = {}
  local status_code = decoded.statusCode or decoded.status or decoded.code
  local primary_err = decoded.error or decoded.title
  local message_txt = decoded.message or decoded.detail

  if status_code ~= nil then parts[#parts + 1] = tostring(status_code) end
  if primary_err ~= nil and tostring(primary_err) ~= "" then parts[#parts + 1] = tostring(primary_err) end
  if message_txt ~= nil and tostring(message_txt) ~= "" then parts[#parts + 1] = tostring(message_txt) end

  local api_error = nil
  if #parts > 0 then
    api_error = table.concat(parts, " - ")
  end

  local extras = {}
  if decoded.path ~= nil and tostring(decoded.path) ~= "" then
    extras[#extras + 1] = "path: " .. tostring(decoded.path)
  end
  if decoded.correlationId ~= nil and tostring(decoded.correlationId) ~= "" then
    extras[#extras + 1] = "correlationId: " .. tostring(decoded.correlationId)
  end

  if #extras > 0 then
    local extras_txt = table.concat(extras, ", ")
    if api_error and api_error ~= "" then
      api_error = api_error .. " (" .. extras_txt .. ")"
    else
      api_error = extras_txt
    end
  end

  if api_error == "" then return nil end
  return api_error
end

local function parse_api_error_from_body(body_txt)
  local decoded = decode_json_object(body_txt)
  if not decoded then return nil end
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
  if type(on_done) == "function" then pcall(on_done, payload) end
end

local function find_first_string_by_keys(tbl, keys)
  if type(tbl) ~= "table" then return nil, nil end
  for i = 1, #keys do
    local key = keys[i]
    local v = tbl[key]
    if v ~= nil then
      local s = trim(v)
      if s ~= "" then return s, key end
    end
  end
  return nil, nil
end

local function find_first_table_by_keys(tbl, keys)
  if type(tbl) ~= "table" then return nil, nil end
  for i = 1, #keys do
    local key = keys[i]
    local v = tbl[key]
    if type(v) == "table" then
      return v, key
    end
  end
  return nil, nil
end

local function is_valid_upload_fields_table(tbl)
  if type(tbl) ~= "table" then return false end
  local has_any = false
  for k, v in pairs(tbl) do
    local key = trim(k)
    if key == "" then
      return false
    end
    local tv = type(v)
    if tv == "table" or tv == "function" or tv == "thread" or tv == "userdata" then
      return false
    end
    if trim(v) == "" then
      return false
    end
    has_any = true
  end
  return has_any
end

local function parse_request_upload_response(decoded)
  local strict_id_keys = { "fileId", "file_id", "fileID" }
  local strict_url_keys = { "uploadUrl", "uploadURL", "presignedUploadUrl", "presignedUrl", "preSignedUrl", "signedUrl" }
  local broad_id_keys = { "fileId", "file_id", "fileID", "id", "key" }
  local broad_url_keys = { "uploadUrl", "uploadURL", "presignedUploadUrl", "presignedUrl", "preSignedUrl", "signedUrl", "url" }
  local fields_keys = { "uploadFields", "upload_fields", "fields", "formFields", "form_fields" }

  local containers = {}
  local seen = {}
  local function walk(tbl, depth)
    if type(tbl) ~= "table" or seen[tbl] then return end
    seen[tbl] = true
    containers[#containers + 1] = tbl
    if depth >= 2 then return end
    for _, v in pairs(tbl) do
      if type(v) == "table" then
        walk(v, depth + 1)
      end
    end
  end
  walk(decoded, 0)

  -- Strict pass first: prefer explicit upload contract keys.
  for i = 1, #containers do
    local c = containers[i]
    if type(c) == "table" then
      local fid, fid_key = find_first_string_by_keys(c, strict_id_keys)
      local up, up_key = find_first_string_by_keys(c, strict_url_keys)
      local uf, uf_key = find_first_table_by_keys(c, fields_keys)
      if uf and (not is_valid_upload_fields_table(uf)) then
        uf = nil
        uf_key = nil
      end
      if fid and up and looks_like_http_url(up) then
        return fid, up, fid_key, up_key, uf, uf_key
      end
    end
  end

  -- Backward-compatible broad pass.
  for i = 1, #containers do
    local c = containers[i]
    if type(c) == "table" then
      local fid, fid_key = find_first_string_by_keys(c, broad_id_keys)
      local up, up_key = find_first_string_by_keys(c, broad_url_keys)
      local uf, uf_key = find_first_table_by_keys(c, fields_keys)
      if uf and (not is_valid_upload_fields_table(uf)) then
        uf = nil
        uf_key = nil
      end
      if fid and up and looks_like_http_url(up) then
        return fid, up, fid_key, up_key, uf, uf_key
      end
    end
  end

  local best_url = nil
  local best_fid = nil
  for _, c in ipairs(containers) do
    if type(c) == "table" then
      for k, v in pairs(c) do
        if type(v) == "string" then
          local s = trim(v)
          local lk = tostring(k):lower()
          if best_url == nil and looks_like_http_url(s) then
            best_url = s
          end
          if best_fid == nil and not looks_like_http_url(s) then
            if lk:find("fileid", 1, true) or lk == "id" then
              best_fid = s
            end
          end
        end
      end
    end
  end
  return best_fid, best_url, nil, nil, nil, nil
end

local function parse_json_or_raw_table(body_txt)
  if type(body_txt) ~= "string" or body_txt == "" then return {} end
  local decoded, decode_err = decode_json_any(body_txt)
  if decoded ~= nil then
    if type(decoded) == "table" then return decoded end
    return { raw_value = decoded }
  end
  return { raw_body = body_txt, parse_error = decode_err }
end

local function path_basename(path)
  return tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
end

local function path_extension(file_name)
  local ext = tostring(file_name or ""):match("%.([^%.\\/]+)$")
  if ext == nil then return nil end
  ext = trim(ext)
  if ext == "" then return nil end
  return ext
end

local function normalize_extension(ext)
  local text = trim(ext)
  if text:sub(1, 1) == "." then text = text:sub(2) end
  if text == "" then return nil end
  if #text > 10 then return nil end
  return text
end

local url_encode_path_segment = Util.url_encode_path_segment

local function file_exists(path)
  local f = io.open(tostring(path or ""), "rb")
  if not f then return false end
  f:close()
  return true
end

local function file_size(path)
  local f, open_err = io.open(path, "rb")
  if not f then return nil, tostring(open_err) end
  local n, seek_err = f:seek("end")
  f:close()
  if not n then return nil, tostring(seek_err or "seek failed") end
  return n
end

local function coerce_timestamp(value)
  if type(value) == "number" then return value, tostring(value) end
  local text = trim(value)
  if text == "" then return nil, nil end
  local as_num = tonumber(text)
  if as_num ~= nil then return as_num, text end
  local y, mo, d, h, mi, s = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)")
  if y then
    local ok, epoch = pcall(os.time, { year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
    if ok and epoch then return epoch, text end
  end
  return nil, text
end

local function is_script_aligner_type(job_type)
  local s = trim(job_type):lower()
  return (s == "scriptaligner") or (s == "2")
end

local function normalize_job_status(status)
  local s = trim(status):lower()
  if s == "0" or s == "new" then return "new" end
  if s == "1" or s == "process" or s == "processing" then return "process" end
  if s == "2" or s == "done" then return "done" end
  if s == "3" or s == "error" or s == "failed" then return "error" end
  if s == "4" or s == "archived" then return "archived" end
  return s
end

local function extract_job_id_from_obj(obj)
  if type(obj) ~= "table" then return nil end
  local id, _ = find_first_string_by_keys(obj, { "id", "jobId", "job_id" })
  if id and id ~= "" then return id end

  local nested_candidates = { "job", "data", "result", "payload" }
  for i = 1, #nested_candidates do
    local k = nested_candidates[i]
    local t = obj[k]
    if type(t) == "table" then
      local nested_id, _ = find_first_string_by_keys(t, { "id", "jobId", "job_id" })
      if nested_id and nested_id ~= "" then
        return nested_id
      end
    end
  end
  return nil
end

local function matches_title(actual, wanted, exact)
  if not wanted or wanted == "" then return true end
  local a = trim(actual)
  local w = trim(wanted)
  if exact == false then return a:lower():find(w:lower(), 1, true) ~= nil end
  return a == w
end

function NeurocastScriptAlignerHelper.create_client(opts)
  assert(type(opts) == "table", "NeurocastScriptAlignerHelper.create_client(opts): opts table is required")
  local base_url = validate_nonempty_string(opts.base_url, "opts.base_url", true)
  assert(base_url, "NeurocastScriptAlignerHelper.create_client(opts): opts.base_url must be a non-empty string")

  local curl_submit_fn = type(opts.curl_submit_fn) == "function" and opts.curl_submit_fn or Curl.curl_submit

  local client = {}

  local function submit_wrapped(endpoint, req, parse_success_fn, on_success, on_done, submit_opts, default_read_body)
    if type(curl_submit_fn) ~= "function" then
      local payload = make_failure_payload(endpoint, "curl submit function is not available", nil, nil)
      safe_callback(on_done, payload)
      return nil, payload.error
    end
    local merged_opts = shallow_copy(submit_opts or {})
    if merged_opts.read_body == nil then
      merged_opts.read_body = (default_read_body ~= false)
    end
    local job, submit_err = curl_submit_fn(req, function(result, _job)
      if not result or result.ok ~= true then
        safe_callback(on_done, make_failure_payload(endpoint, (result and result.err) or "request failed", result and result.http_code or nil, parse_api_error_from_body(result and result.body or nil)))
        return
      end
      local parsed, parse_err, api_error = parse_success_fn(result.body, result)
      if not parsed then
        safe_callback(on_done, make_failure_payload(endpoint, parse_err or "response parse failed", result.http_code, api_error))
        return
      end
      safe_callback(on_done, on_success(parsed, result.http_code, result))
    end, merged_opts)
    if not job then
      safe_callback(on_done, make_failure_payload(endpoint, submit_err or "submit failed", nil, nil))
      return nil, submit_err
    end
    return job
  end

  function client.make_upload_request_fields_from_path(local_file_path, overrides)
    local path, path_err = validate_nonempty_string(local_file_path, "local_file_path", true)
    if not path then return nil, path_err end
    if not file_exists(path) then return nil, "local_file_path is not readable: " .. tostring(path) end
    local ov = type(overrides) == "table" and overrides or {}
    local n = ov.file_name or ov.fileName or path_basename(path)
    local ext = normalize_extension(ov.file_extension or ov.fileExtension or path_extension(n))
    if not ext then return nil, "file extension is missing; pass overrides.file_extension" end
    local size = ov.file_size or ov.fileSize
    if size == nil then
      local s, size_err = file_size(path)
      if not s then return nil, "cannot get file size: " .. tostring(size_err) end
      size = s
    end
    local mime = ov.mime_type or ov.mimeType or "application/octet-stream"
    return {
      file_name = n,
      file_size = size,
      mime_type = mime,
      file_extension = ext,
      local_file_path = path
    }
  end

  local function parse_upload_fields(fields)
    if type(fields) ~= "table" then return nil, "fields must be a table" end
    local file_name = validate_nonempty_string(fields.file_name or fields.fileName, "file_name", true)
    if not file_name then return nil, "file_name must be a non-empty string" end
    local file_size_num, size_err = validate_integer(fields.file_size or fields.fileSize, "file_size", 1, 2097152000)
    if not file_size_num then return nil, size_err end
    local mime_type = validate_nonempty_string(fields.mime_type or fields.mimeType, "mime_type", true)
    if not mime_type then return nil, "mime_type must be a non-empty string" end
    local file_extension = normalize_extension(fields.file_extension or fields.fileExtension or path_extension(file_name))
    if not file_extension then return nil, "file_extension must be provided (or derivable from file_name) and <= 10 chars" end
    return {
      file_name = file_name,
      file_size = file_size_num,
      mime_type = mime_type,
      file_extension = file_extension
    }
  end

  local function normalize_options(options)
    if options == nil then return nil, nil end
    if type(options) ~= "table" then return nil, "options must be a table or nil" end
    local out = {}
    if options.matchConfidenceThreshold ~= nil then
      local v, err = validate_number(options.matchConfidenceThreshold, "options.matchConfidenceThreshold", 0, 1)
      if not v then return nil, err end
      out.matchConfidenceThreshold = v
    end
    if options.timeWindowSeconds ~= nil then
      local v, err = validate_integer(options.timeWindowSeconds, "options.timeWindowSeconds", 1, 60)
      if not v then return nil, err end
      out.timeWindowSeconds = v
    end
    if options.csvConfidenceThreshold ~= nil then
      local v, err = validate_number(options.csvConfidenceThreshold, "options.csvConfidenceThreshold", 0, 1)
      if not v then return nil, err end
      out.csvConfidenceThreshold = v
    end
    if next(out) == nil then return nil, nil end
    return out, nil
  end

  function client.build_request_upload_request(access_token, fields)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    local parsed, parse_err = parse_upload_fields(fields)
    if not parsed then return nil, parse_err end

    return {
      label = "files_request_upload",
      kind = "neurocast_script_aligner",
      method = "POST",
      url = join_url(base_url, "/api/files/request-upload"),
      headers = with_bearer(make_json_headers(), access),
      json_payload_tbl = {
        fileName = parsed.file_name,
        fileSize = parsed.file_size,
        mimeType = parsed.mime_type,
        fileExtension = parsed.file_extension
      }
    }
  end

  function client.build_upload_to_presigned_request(upload_url, local_file_path, mime_type, upload_fields)
    local url, url_err = validate_nonempty_string(upload_url, "upload_url", true)
    if not url then return nil, url_err end
    if not looks_like_http_url(url) then return nil, "upload_url must start with http:// or https://" end
    local path, path_err = validate_nonempty_string(local_file_path, "local_file_path", true)
    if not path then return nil, path_err end
    if not file_exists(path) then return nil, "local_file_path is not readable: " .. tostring(path) end
    local mime = trim(mime_type)
    if mime == "" then mime = "application/octet-stream" end

    if type(upload_fields) == "table" and next(upload_fields) ~= nil then
      local form_fields = {}
      local seen_content_type = false
      local upload_content_type = nil
      for k, v in pairs(upload_fields) do
        local key = trim(k)
        if key == "" then
          return nil, "upload_fields key must be a non-empty string"
        end
        local tv = type(v)
        if tv == "table" or tv == "function" or tv == "thread" or tv == "userdata" then
          return nil, "upload_fields[" .. key .. "] must be scalar"
        end
        local value = trim(v)
        if value == "" then
          return nil, "upload_fields[" .. key .. "] must be a non-empty scalar"
        end
        if key == "Content-Type" then
          seen_content_type = true
          upload_content_type = value
        end
        form_fields[#form_fields + 1] = {
          name = key,
          value = value
        }
      end
      if not seen_content_type then
        form_fields[#form_fields + 1] = {
          name = "Content-Type",
          value = mime
        }
        upload_content_type = mime
      elseif not upload_content_type or upload_content_type == "" then
        upload_content_type = mime
      end
      form_fields[#form_fields + 1] = {
        name = "file",
        filepath = path,
        content_type = upload_content_type
      }
      return {
        label = "files_upload_post_form",
        kind = "neurocast_script_aligner",
        method = "POST",
        url = url,
        form_fields = form_fields
      }
    end

    return {
      label = "files_upload_put",
      kind = "neurocast_script_aligner",
      method = "PUT",
      url = url,
      headers = { ["Content-Type"] = mime },
      body_file_path = path
    }
  end

  function client.build_confirm_upload_request(access_token, file_id)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    local fid, fid_err = validate_nonempty_string(file_id, "file_id", true)
    if not fid then return nil, fid_err end
    return {
      label = "files_confirm_upload",
      kind = "neurocast_script_aligner",
      method = "POST",
      url = join_url(base_url, "/api/files/confirm-upload"),
      headers = with_bearer(make_json_headers(), access),
      json_payload_tbl = { fileId = fid }
    }
  end

  function client.build_start_script_aligner_request(access_token, params)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    if type(params) ~= "table" then return nil, "params must be a table" end
    local title, title_err = validate_nonempty_string(params.title, "title", true)
    if not title then return nil, title_err end
    if #title < 4 or #title > 255 then return nil, "title length must be in [4, 255]" end
    local text_file_id, text_err = validate_nonempty_string(params.text_file_id or params.textFileId, "text_file_id", true)
    if not text_file_id then return nil, text_err end
    local media_file_id, media_err = validate_nonempty_string(params.media_file_id or params.mediaFileId, "media_file_id", true)
    if not media_file_id then return nil, media_err end
    local options, options_err = normalize_options(params.options)
    if options_err then return nil, options_err end
    local payload = {
      title = title,
      textFileId = text_file_id,
      mediaFileId = media_file_id
    }
    if options then payload.options = options end
    return {
      label = "script_aligner_create",
      kind = "neurocast_script_aligner",
      method = "POST",
      url = join_url(base_url, "/api/script-aligner"),
      headers = with_bearer(make_json_headers(), access),
      json_payload_tbl = payload
    }
  end

  function client.build_list_jobs_request(access_token)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    return {
      label = "jobs_index",
      kind = "neurocast_script_aligner",
      method = "GET",
      url = join_url(base_url, "/api/jobs"),
      headers = with_bearer(make_json_headers(), access)
    }
  end

  function client.build_get_job_request(access_token, job_id)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    local id, id_err = validate_nonempty_string(job_id, "job_id", true)
    if not id then return nil, id_err end
    return {
      label = "jobs_show",
      kind = "neurocast_script_aligner",
      method = "GET",
      url = join_url(base_url, "/api/jobs/" .. url_encode_path_segment(id)),
      headers = with_bearer(make_json_headers(), access)
    }
  end

  function client.build_get_job_files_request(access_token, job_id)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    local id, id_err = validate_nonempty_string(job_id, "job_id", true)
    if not id then return nil, id_err end
    return {
      label = "jobs_files",
      kind = "neurocast_script_aligner",
      method = "GET",
      url = join_url(base_url, "/api/jobs/" .. url_encode_path_segment(id) .. "/files"),
      headers = with_bearer(make_json_headers(), access)
    }
  end

  function client.build_get_job_file_download_url_request(access_token, job_id, file_id)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    local id, id_err = validate_nonempty_string(job_id, "job_id", true)
    if not id then return nil, id_err end
    local fid, fid_err = validate_nonempty_string(file_id, "file_id", true)
    if not fid then return nil, fid_err end
    return {
      label = "jobs_file_download_url",
      kind = "neurocast_script_aligner",
      method = "GET",
      url = join_url(base_url, "/api/jobs/" .. url_encode_path_segment(id) .. "/files/" .. url_encode_path_segment(fid)),
      headers = with_bearer(make_json_headers(), access)
    }
  end

  function client.build_download_from_presigned_request(download_url, target_path)
    local url, url_err = validate_nonempty_string(download_url, "download_url", true)
    if not url then return nil, url_err end
    if not looks_like_http_url(url) then return nil, "download_url must start with http:// or https://" end
    local path, path_err = validate_nonempty_string(target_path, "target_path", true)
    if not path then return nil, path_err end
    return {
      label = "download_result_file",
      kind = "neurocast_script_aligner",
      method = "GET",
      url = url,
      download_path = path
    }
  end

  function client.parse_request_upload_body(body_txt)
    local decoded, decode_err = decode_json_object(body_txt)
    if not decoded then return nil, decode_err, nil end
    local file_id, upload_url, file_id_key, upload_url_key, upload_fields, upload_fields_key = parse_request_upload_response(decoded)
    if not file_id or not upload_url then
      return nil, "request-upload response missing file id or upload url", parse_api_error_from_obj(decoded)
    end
    return {
      file_id = file_id,
      upload_url = upload_url,
      upload_fields = upload_fields,
      inferred_file_id_key = file_id_key,
      inferred_upload_url_key = upload_url_key,
      inferred_upload_fields_key = upload_fields_key,
      raw = decoded
    }
  end

  function client.parse_upload_to_presigned_body(body_txt)
    return parse_json_or_raw_table(body_txt)
  end

  function client.parse_confirm_upload_body(body_txt)
    return parse_json_or_raw_table(body_txt)
  end

  function client.parse_start_script_aligner_body(body_txt)
    local parsed = parse_json_or_raw_table(body_txt)
    if type(parsed) ~= "table" then
      return parsed
    end
    parsed.job_id = extract_job_id_from_obj(parsed)
    return parsed
  end

  function client.parse_jobs_list_body(body_txt)
    local decoded, decode_err = decode_json_any(body_txt)
    if decoded == nil then return nil, decode_err, nil end
    local jobs = decoded
    if type(decoded) == "table" and (not is_array_like(decoded)) then
      if is_array_like(decoded.items) then jobs = decoded.items
      elseif is_array_like(decoded.data) then jobs = decoded.data
      elseif is_array_like(decoded.jobs) then jobs = decoded.jobs
      end
    end
    if not is_array_like(jobs) then
      return nil, "jobs response is not an array", parse_api_error_from_obj(type(decoded) == "table" and decoded or nil)
    end
    return jobs
  end

  function client.parse_job_body(body_txt)
    return decode_json_object(body_txt)
  end

  function client.parse_job_files_body(body_txt)
    local decoded, decode_err = decode_json_any(body_txt)
    if decoded == nil then return nil, decode_err, nil end
    local files = decoded
    if type(decoded) == "table" and (not is_array_like(decoded)) then
      if is_array_like(decoded.items) then files = decoded.items
      elseif is_array_like(decoded.data) then files = decoded.data
      elseif is_array_like(decoded.files) then files = decoded.files
      end
    end
    if not is_array_like(files) then
      return nil, "job files response is not an array", parse_api_error_from_obj(type(decoded) == "table" and decoded or nil)
    end
    return files
  end

  function client.parse_job_file_download_url_body(body_txt)
    local decoded, decode_err = decode_json_object(body_txt)
    if not decoded then return nil, decode_err, nil end
    local url, url_key = find_first_string_by_keys(decoded, { "url", "downloadUrl", "presignedUrl", "preSignedUrl", "signedUrl" })
    if not url then return nil, "download URL response is missing url", parse_api_error_from_obj(decoded) end
    return { url = url, inferred_url_key = url_key }
  end

  function client.submit_request_upload(access_token, fields, on_done, submit_opts)
    local req, req_err = client.build_request_upload_request(access_token, fields)
    if not req then
      local payload = make_failure_payload("request_upload", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("request_upload", req, client.parse_request_upload_body, function(parsed, http_code)
      return {
        ok = true,
        endpoint = "request_upload",
        http_code = http_code,
        file_id = parsed.file_id,
        upload_url = parsed.upload_url,
        upload_fields = parsed.upload_fields,
        inferred_file_id_key = parsed.inferred_file_id_key,
        inferred_upload_url_key = parsed.inferred_upload_url_key,
        inferred_upload_fields_key = parsed.inferred_upload_fields_key,
        raw = parsed.raw
      }
    end, on_done, submit_opts, true)
  end

  function client.submit_upload_to_presigned(upload_url, local_file_path, mime_type, upload_fields, on_done, submit_opts)
    local req, req_err = client.build_upload_to_presigned_request(upload_url, local_file_path, mime_type, upload_fields)
    if not req then
      local payload = make_failure_payload("upload_to_presigned", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("upload_to_presigned", req, client.parse_upload_to_presigned_body, function(parsed, http_code, result)
      return {
        ok = true,
        endpoint = "upload_to_presigned",
        http_code = http_code,
        upload_url = upload_url,
        local_file_path = local_file_path,
        upload_fields_used = (type(upload_fields) == "table" and next(upload_fields) ~= nil) and true or false,
        result_body = parsed,
        headers_txt = result and result.headers_txt or nil
      }
    end, on_done, submit_opts, false)
  end

  function client.submit_confirm_upload(access_token, file_id, on_done, submit_opts)
    local req, req_err = client.build_confirm_upload_request(access_token, file_id)
    if not req then
      local payload = make_failure_payload("confirm_upload", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("confirm_upload", req, client.parse_confirm_upload_body, function(parsed, http_code)
      return {
        ok = true,
        endpoint = "confirm_upload",
        http_code = http_code,
        file_id = tostring(file_id),
        result_body = parsed
      }
    end, on_done, submit_opts, true)
  end

  function client.submit_start_script_aligner(access_token, params, on_done, submit_opts)
    local req, req_err = client.build_start_script_aligner_request(access_token, params)
    if not req then
      local payload = make_failure_payload("start_script_aligner", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("start_script_aligner", req, client.parse_start_script_aligner_body, function(parsed, http_code)
      return {
        ok = true,
        endpoint = "start_script_aligner",
        http_code = http_code,
        job_id = parsed and parsed.job_id or nil,
        title = req.json_payload_tbl and req.json_payload_tbl.title or nil,
        text_file_id = req.json_payload_tbl and req.json_payload_tbl.textFileId or nil,
        media_file_id = req.json_payload_tbl and req.json_payload_tbl.mediaFileId or nil,
        result_body = parsed
      }
    end, on_done, submit_opts, true)
  end

  function client.submit_list_jobs(access_token, on_done, submit_opts)
    local req, req_err = client.build_list_jobs_request(access_token)
    if not req then
      local payload = make_failure_payload("list_jobs", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("list_jobs", req, client.parse_jobs_list_body, function(parsed, http_code)
      return { ok = true, endpoint = "list_jobs", http_code = http_code, jobs = parsed }
    end, on_done, submit_opts, true)
  end

  function client.submit_get_job(access_token, job_id, on_done, submit_opts)
    local req, req_err = client.build_get_job_request(access_token, job_id)
    if not req then
      local payload = make_failure_payload("get_job", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("get_job", req, client.parse_job_body, function(parsed, http_code)
      return { ok = true, endpoint = "get_job", http_code = http_code, job_id = tostring(job_id), job = parsed }
    end, on_done, submit_opts, true)
  end

  function client.submit_get_job_files(access_token, job_id, on_done, submit_opts)
    local req, req_err = client.build_get_job_files_request(access_token, job_id)
    if not req then
      local payload = make_failure_payload("get_job_files", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("get_job_files", req, client.parse_job_files_body, function(parsed, http_code)
      return { ok = true, endpoint = "get_job_files", http_code = http_code, job_id = tostring(job_id), files = parsed }
    end, on_done, submit_opts, true)
  end

  function client.submit_get_job_file_download_url(access_token, job_id, file_id, on_done, submit_opts)
    local req, req_err = client.build_get_job_file_download_url_request(access_token, job_id, file_id)
    if not req then
      local payload = make_failure_payload("get_job_file_download_url", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    return submit_wrapped("get_job_file_download_url", req, client.parse_job_file_download_url_body, function(parsed, http_code)
      return {
        ok = true,
        endpoint = "get_job_file_download_url",
        http_code = http_code,
        job_id = tostring(job_id),
        file_id = tostring(file_id),
        url = parsed.url,
        inferred_url_key = parsed.inferred_url_key
      }
    end, on_done, submit_opts, true)
  end

  function client.submit_download_from_presigned(download_url, target_path, on_done, submit_opts)
    local req, req_err = client.build_download_from_presigned_request(download_url, target_path)
    if not req then
      local payload = make_failure_payload("download_from_presigned", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end
    if type(curl_submit_fn) ~= "function" then
      local payload = make_failure_payload("download_from_presigned", "curl submit function is not available", nil, nil)
      safe_callback(on_done, payload)
      return nil, payload.error
    end

    local merged_opts = shallow_copy(submit_opts or {})
    if merged_opts.read_body == nil then merged_opts.read_body = false end
    if merged_opts.keep_output == nil then merged_opts.keep_output = true end

    local job, submit_err = curl_submit_fn(req, function(result, _job)
      if not result or result.ok ~= true then
        safe_callback(on_done, make_failure_payload("download_from_presigned", (result and result.err) or "request failed", result and result.http_code or nil, parse_api_error_from_body(result and result.body or nil)))
        return
      end

      local fh = io.open(target_path, "rb")
      if not fh then
        safe_callback(on_done, make_failure_payload("download_from_presigned", "download completed but output file is missing", result.http_code, nil))
        return
      end
      fh:close()

      local bytes = file_size(target_path)
      safe_callback(on_done, {
        ok = true,
        endpoint = "download_from_presigned",
        http_code = result.http_code,
        download_url = tostring(download_url),
        out_path = tostring(target_path),
        downloaded_bytes = bytes,
        headers_txt = result and result.headers_txt or nil
      })
    end, merged_opts)

    if not job then
      safe_callback(on_done, make_failure_payload("download_from_presigned", submit_err or "submit failed", nil, nil))
      return nil, submit_err
    end
    return job
  end

  function client.pick_result_files(job, files, opts)
    if type(files) ~= "table" then return nil, "files must be a table" end
    if next(files) ~= nil and (not is_array_like(files)) then return nil, "files must be an array-like table" end

    local options = type(opts) == "table" and opts or {}
    local source_id_set = {}
    local function add_source_ids(ids_tbl)
      if type(ids_tbl) ~= "table" then return end
      for i = 1, #ids_tbl do
        local id = trim(ids_tbl[i])
        if id ~= "" then
          source_id_set[id] = true
        end
      end
    end

    add_source_ids(options.source_file_ids or options.sourceFileIds)
    if type(job) == "table" then
      add_source_ids(job.sourceFileIds)
    end

    local result_id_set = {}
    if type(job) == "table" and type(job.resultIds) == "table" then
      for i = 1, #job.resultIds do
        local id = trim(job.resultIds[i])
        if id ~= "" then
          result_id_set[id] = true
        end
      end
    end
    local has_result_ids = (next(result_id_set) ~= nil)

    local result_files = {}
    for i = 1, #files do
      local one_file = files[i]
      if type(one_file) == "table" then
        local one_id = trim(one_file.id)
        if one_id ~= "" then
          local is_result = false
          if has_result_ids then
            is_result = (result_id_set[one_id] == true)
          else
            is_result = (source_id_set[one_id] ~= true)
          end
          if is_result then
            result_files[#result_files + 1] = one_file
          end
        end
      end
    end
    return result_files, nil
  end

  function client.pick_primary_json_result_file(job, files)
    if type(files) ~= "table" then return nil, "files must be a table" end
    if next(files) ~= nil and (not is_array_like(files)) then return nil, "files must be an array-like table" end

    local function is_json_file(one_file)
      if type(one_file) ~= "table" then return false end
      local ext = tostring(one_file.extension or ""):lower()
      local mime = tostring(one_file.mimeType or ""):lower()
      return (ext == "json") or (mime == "application/json")
    end

    local file_by_id = {}
    for i = 1, #files do
      local one_file = files[i]
      if type(one_file) == "table" then
        local one_id = trim(one_file.id)
        if one_id ~= "" then
          file_by_id[one_id] = one_file
        end
      end
    end

    local has_nonempty_result_ids = false
    if type(job) == "table" and type(job.resultIds) == "table" then
      for i = 1, #job.resultIds do
        local one_result_id = trim(job.resultIds[i])
        if one_result_id ~= "" then
          has_nonempty_result_ids = true
          local result_file = file_by_id[one_result_id]
          if is_json_file(result_file) then
            return result_file, nil
          end
        end
      end
    end
    if has_nonempty_result_ids then
      return nil, "no JSON result file found in job.resultIds"
    end

    local source_id_set = {}
    if type(job) == "table" and type(job.sourceFileIds) == "table" then
      for i = 1, #job.sourceFileIds do
        local one_source_id = trim(job.sourceFileIds[i])
        if one_source_id ~= "" then
          source_id_set[one_source_id] = true
        end
      end
    end

    for i = 1, #files do
      local one_file = files[i]
      if is_json_file(one_file) then
        local one_id = trim(one_file.id)
        if one_id == "" or source_id_set[one_id] ~= true then
          return one_file, nil
        end
      end
    end

    return nil, "no JSON result file found"
  end

  function client.normalize_job_status(status)
    return normalize_job_status(status)
  end

  function client.is_job_terminal_status(status)
    local s = normalize_job_status(status)
    return (s == "done") or (s == "error") or (s == "archived")
  end

  function client.is_job_success_status(status)
    local s = normalize_job_status(status)
    return (s == "done")
  end

  function client.find_latest_script_aligner_job(jobs, opts)
    if not is_array_like(jobs) then return nil, "jobs must be a non-empty array" end
    local options = type(opts) == "table" and opts or {}
    local wanted_title = trim(options.title)
    if wanted_title == "" then wanted_title = nil end
    local exact = (options.exact_title ~= false)

    local best_job, best_idx, best_num, best_txt = nil, nil, nil, nil
    for i = 1, #jobs do
      local job = jobs[i]
      if type(job) == "table" and is_script_aligner_type(job.type) and matches_title(job.title, wanted_title, exact) then
        local num, txt = coerce_timestamp(job.updatedAt)
        if num == nil then num, txt = coerce_timestamp(job.createdAt) end
        local better = false
        if not best_job then
          better = true
        elseif num and best_num then
          better = (num > best_num)
        elseif num and (not best_num) then
          better = true
        elseif (not num) and (not best_num) and txt and best_txt and txt ~= best_txt then
          better = (txt > best_txt)
        else
          better = (i > (best_idx or 0))
        end
        if better then
          best_job, best_idx, best_num, best_txt = job, i, num, txt
        end
      end
    end
    if not best_job then return nil, "no matching scriptaligner job found" end
    return best_job, nil, best_idx
  end

  return client
end

return NeurocastScriptAlignerHelper
