-- Thin Studio Neurocast helper for Reaper Manager ElevenLabs routing.
-- This module builds authenticated requests and validates safe manager responses.

local ManagerApi = {}

local Util = require("modules-neurocast.Util")
local json = require("modules-neurocast.json")

local PRODUCTION_BASE_URL = "https://studio.neurocast.tech"

local function trim(value)
  if type(Util.trim) == "function" then return Util.trim(value) end
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_base_url(base_url)
  local value = trim(base_url)
  if value == "" then value = PRODUCTION_BASE_URL end
  return value:gsub("/+$", "")
end

local function join_url(base_url, path)
  if type(Util.join_url) == "function" then
    return Util.join_url(base_url, path)
  end
  return normalize_base_url(base_url) .. "/" .. tostring(path or ""):gsub("^/+", "")
end

local function url_encode_path_segment(value)
  if type(Util.url_encode_path_segment) == "function" then
    return Util.url_encode_path_segment(value)
  end
  return (tostring(value or ""):gsub("[^%w%-._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function decode_json(body)
  if type(body) ~= "string" or body == "" then return nil, "empty response body" end
  local ok, value = pcall(json.decode, body)
  if not ok then return nil, "JSON decode failed: " .. tostring(value) end
  if type(value) ~= "table" then return nil, "JSON response is not an object or array" end
  return value
end

local function parse_error_object(value)
  if type(value) ~= "table" then return nil end
  local parts = {}
  for _, field in ipairs({ "code", "statusCode", "error", "message", "detail" }) do
    local item = value[field]
    if item ~= nil and trim(item) ~= "" then parts[#parts + 1] = trim(item) end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " - ")
end

local function make_headers(access_token, has_body)
  local token = trim(access_token)
  if token == "" then return nil, "Studio access token is missing." end
  local headers = {
    accept = "application/json",
    Authorization = "Bearer " .. token
  }
  if has_body then headers["Content-Type"] = "application/json" end
  return headers
end

local function make_request(client, method, path, label, payload)
  local headers, headers_err = make_headers(client.access_token_fn(), payload ~= nil)
  if not headers then return nil, headers_err end
  local req = {
    method = method,
    url = join_url(client.base_url, path),
    headers = headers,
    kind = "reaper_manager_elevenlabs",
    label = label,
    backend_auth = "studio"
  }
  if payload ~= nil then req.json_payload_tbl = payload end
  return req
end

local function validate_account(row, index)
  if type(row) ~= "table" then
    return nil, string.format("accounts[%d] is not an object", index)
  end
  local account_id = trim(row.accountId)
  if account_id == "" then
    return nil, string.format("accounts[%d].accountId is missing", index)
  end
  return {
    accountId = account_id,
    label = trim(row.label),
    available = row.available ~= false
  }
end

local function validate_user(row, index)
  if type(row) ~= "table" then
    return nil, string.format("users[%d] is not an object", index)
  end
  local user_id = trim(row.userId)
  local email = trim(row.email)
  if user_id == "" then return nil, string.format("users[%d].userId is missing", index) end
  if email == "" then return nil, string.format("users[%d].email is missing", index) end
  local account_id = trim(row.accountId)
  if account_id == "" then account_id = nil end
  local state = trim(row.state)
  if state ~= "assigned" and state ~= "unassigned" then
    return nil, string.format("users[%d].state is unsupported: %s", index, state)
  end
  return {
    userId = user_id,
    fullname = trim(row.fullname),
    username = trim(row.username),
    email = email,
    accountId = account_id,
    state = state
  }
end

function ManagerApi.production_base_url()
  return PRODUCTION_BASE_URL
end

function ManagerApi.resolve_base_url(value)
  return normalize_base_url(value)
end

function ManagerApi.parse_api_error(body)
  local decoded = decode_json(body)
  if not decoded then return nil end
  return parse_error_object(decoded)
end

function ManagerApi.parse_accounts(body)
  local decoded, decode_err = decode_json(body)
  if not decoded then return nil, decode_err end
  local rows = {}
  for index, row in ipairs(decoded) do
    local parsed, parse_err = validate_account(row, index)
    if not parsed then return nil, parse_err end
    rows[#rows + 1] = parsed
  end
  return rows
end

function ManagerApi.parse_users(body)
  local decoded, decode_err = decode_json(body)
  if not decoded then return nil, decode_err end
  local rows = {}
  for index, row in ipairs(decoded) do
    local parsed, parse_err = validate_user(row, index)
    if not parsed then return nil, parse_err end
    rows[#rows + 1] = parsed
  end
  return rows
end

function ManagerApi.parse_mutation(body)
  if body == nil or body == "" then return {} end
  local decoded, decode_err = decode_json(body)
  if not decoded then return nil, decode_err end
  return decoded
end

function ManagerApi.create_client(opts)
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

  function client:accounts_request(label)
    return make_request(self, "GET", "/api/reaper-manager/elevenlabs/accounts", label or "Fetch accounts")
  end

  function client:users_request(label)
    return make_request(self, "GET", "/api/reaper-manager/elevenlabs/users", label or "Fetch users")
  end

  function client:assign_request(user_id, account_id, label)
    local safe_user_id = trim(user_id)
    local safe_account_id = trim(account_id)
    if safe_user_id == "" then return nil, "userId is missing." end
    if safe_account_id == "" then return nil, "accountId is missing." end
    return make_request(
      self,
      "PUT",
      "/api/reaper-manager/elevenlabs/assignments/" .. url_encode_path_segment(safe_user_id),
      label or "Assign ElevenLabs account",
      { accountId = safe_account_id }
    )
  end

  function client:block_request(user_id, label)
    local safe_user_id = trim(user_id)
    if safe_user_id == "" then return nil, "userId is missing." end
    return make_request(
      self,
      "DELETE",
      "/api/reaper-manager/elevenlabs/assignments/" .. url_encode_path_segment(safe_user_id),
      label or "Block ElevenLabs access"
    )
  end

  return client
end

return ManagerApi
