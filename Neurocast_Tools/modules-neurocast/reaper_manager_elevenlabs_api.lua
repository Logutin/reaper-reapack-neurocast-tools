-- Thin Studio Neurocast helper for Reaper Manager ElevenLabs routing.
-- This module builds authenticated requests and validates safe manager responses.

local ManagerApi = {}

local Util = require("modules-neurocast.Util")
local json = require("modules-neurocast.json")

local PRODUCTION_BASE_URL = "https://reaper.neurocast.tech"

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
  if not ok then return nil, "JSON decode failed." end
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
  if not (method == "POST" and path == "/api/reaper-manager/connection") then
    local connection = trim(client.connection_token_fn())
    if connection == "" then return nil, "Connect Manager explicitly before loading data." end
    headers["X-Reaper-Manager-Connection"] = connection
  end
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

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function integer(value, minimum)
  return finite(value) and value >= (minimum or 0) and value <= 9007199254740991 and value % 1 == 0
end

local function validate_wallet(row)
  if type(row) ~= "table" or trim(row.userId) == "" or row.provider ~= "elevenlabs" or
      type(row.enabled) ~= "boolean" or not finite(row.balance) or not integer(row.revision) or
      not finite(row.consumption) or not integer(row.pendingJobs) or not integer(row.uncertainJobs) then
    return nil, "Invalid ElevenLabs wallet response. Refresh current backend data."
  end
  return row
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
  local wallet, wallet_err = validate_wallet(row)
  if not wallet then return nil, wallet_err end
  return {
    userId = user_id,
    fullname = trim(row.fullname),
    username = trim(row.username),
    email = email,
    accountId = account_id,
    state = state,
    provider = row.provider, enabled = row.enabled, balance = row.balance,
    revision = row.revision, consumption = row.consumption,
    pendingJobs = row.pendingJobs, uncertainJobs = row.uncertainJobs
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
  if type(body) ~= "string" or not body:match("^%s*%[") then return nil, "Expected accounts array." end
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
  if type(body) ~= "string" or not body:match("^%s*%[") then return nil, "Expected users array." end
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

function ManagerApi.connection_error(body)
  local decoded = decode_json(body)
  local code = decoded and decoded.code
  if code == "MANAGER_CONNECTION_REPLACED" or code == "MANAGER_CONNECTION_EXPIRED" then return code end
end

function ManagerApi.parse_connection(body)
  local row, err = decode_json(body)
  if not row then return nil, err end
  if trim(row.userId) == "" or row.client ~= "reaper" or not integer(row.expiresAt, 1) or
      type(row.connectionToken) ~= "string" or row.connectionToken == "" then
    return nil, "Invalid Manager connection response. Connect again explicitly."
  end
  return row
end

function ManagerApi.parse_wallet(body)
  local row, err = decode_json(body)
  if not row then return nil, err end
  return validate_wallet(row)
end

-- Normalize decimal text before converting to binary64. This retains the user's
-- intended value, including digits that tonumber would otherwise discard.
local function normalize_decimal(text)
  if type(text) ~= "string" then return nil, "Enter a numeric balance." end
  local raw = trim(text)
  if raw == "" or #raw > 256 then return nil, "Enter a numeric balance (up to 256 characters)." end
  local negative = raw:sub(1, 1) == "-"
  if raw:sub(1, 1) == "-" or raw:sub(1, 1) == "+" then raw = raw:sub(2) end
  local mantissa, exponent = raw, "0"
  if raw:find("[eE]") then
    mantissa, exponent = raw:match("^(.-)[eE]([+-]?%d+)$")
    if not mantissa then return nil, "Enter a numeric balance." end
  end
  local whole, fraction = mantissa:match("^(%d*)%.(%d*)$")
  if not whole then whole, fraction = mantissa:match("^(%d+)$"), "" end
  if not whole or (whole == "" and fraction == "") then return nil, "Enter a numeric balance." end
  local digits = (whole .. fraction):gsub("^0+", "")
  if digits == "" then return "0", 0, "0" end
  local power = tonumber(exponent)
  if not power or math.abs(power) > 1024 then return nil, "Balance is outside supported range or precision." end
  local significant = digits:gsub("0+$", "")
  local scale = #fraction - power - (#digits - #significant)
  digits = significant
  local canonical
  if scale <= 0 then canonical = digits .. string.rep("0", -scale)
  elseif scale >= #digits then canonical = "0." .. string.rep("0", scale - #digits) .. digits
  else canonical = digits:sub(1, #digits - scale) .. "." .. digits:sub(#digits - scale + 1) end
  return (negative and "-" or "") .. canonical, scale, digits
end

function ManagerApi.format_number(value)
  if not finite(value) then return nil end
  -- Find a shortest round-trip decimal; a fixed %.9f or the shared %.14g
  -- encoder can change supported large fractional balances.
  for precision = 1, 17 do
    local candidate = string.format("%." .. precision .. "g", value):gsub(",", ".")
    if tonumber(candidate) == value then return (normalize_decimal(candidate)) end
  end
end

function ManagerApi.parse_balance_input(text)
  local canonical, scale, digits = normalize_decimal(text)
  if not canonical then return nil, nil, scale end
  if canonical == "0" then return 0, "0" end
  if scale > 9 then return nil, nil, "Balance supports at most nine effective decimal places; no rounding was applied." end
  local unit_length = #digits + 9 - scale
  local maximum_units = "9007199254740991"
  if unit_length > #maximum_units then
    return nil, nil, "Balance exceeds the technical maximum magnitude of 9,007,199.25474099 credits."
  end
  local units = digits .. string.rep("0", 9 - scale)
  if #units == #maximum_units and units > maximum_units then
    return nil, nil, "Balance exceeds the technical maximum magnitude of 9,007,199.25474099 credits."
  end
  local value = tonumber(canonical)
  if not finite(value) or ManagerApi.format_number(value) ~= canonical then
    return nil, nil, "This decimal cannot be represented exactly by the backend. Change the amount; no rounding was applied."
  end
  return value, canonical
end

function ManagerApi.validate_edit(edit, balance_text)
  if type(edit) ~= "table" or not integer(edit.expectedRevision) then return nil, "Current revision is required." end
  for key in pairs(edit) do
    if key ~= "expectedRevision" and key ~= "enabled" and key ~= "balance" then return nil, "Unknown edit field." end
  end
  if edit.enabled == nil and edit.balance == nil then return nil, "Choose a balance or access change." end
  if edit.enabled ~= nil and type(edit.enabled) ~= "boolean" then return nil, "Enabled must be boolean." end
  if edit.balance ~= nil then
    if not finite(edit.balance) then return nil, "Enter a finite numeric balance." end
    local value, _, err = ManagerApi.parse_balance_input(balance_text or ManagerApi.format_number(edit.balance))
    if value == nil then return nil, err end
    if value ~= edit.balance then return nil, "Balance text and numeric value disagree; reload before editing." end
  end
  return true
end

function ManagerApi.edit_confirmed(row, user_id, edit)
  return validate_wallet(row) ~= nil and row.userId == user_id and row.revision > edit.expectedRevision and
    (edit.enabled == nil or row.enabled == edit.enabled) and (edit.balance == nil or row.balance == edit.balance)
end

function ManagerApi.parse_credits(body)
  if type(body) ~= "string" or not body:match("^%s*%[") then return nil, "Expected credits array." end
  local rows, err = decode_json(body)
  if not rows then return nil, err end
  for _, row in ipairs(rows) do
    if type(row) ~= "table" or trim(row.accountId) == "" or type(row.checkedAt) ~= "string" then
      return nil, "Invalid account credit identity/time."
    end
    if row.status == "ok" then
      if not finite(row.creditsUsed) or not finite(row.allowance) or not finite(row.remaining) or
          (row.nextResetUnix ~= nil and not integer(row.nextResetUnix)) then return nil, "Invalid credit totals." end
    elseif row.status == "error" then
      if type(row.error) ~= "table" or type(row.error.code) ~= "string" then return nil, "Invalid credit error." end
    else return nil, "Invalid credit status." end
  end
  return rows
end

local function parse_page(body, user_id, kind)
  local row, err = decode_json(body)
  if not row then return nil, err end
  local items = kind == "history" and row.events or row.jobs
  if row.userId ~= user_id or row.provider ~= "elevenlabs" or type(items) ~= "table" or #items > 100 then
    return nil, "Invalid user history/pending page."
  end
  local previous
  for _, item in ipairs(items) do
    if type(item) ~= "table" then return nil, "Invalid page item." end
    if kind == "history" then
      if not integer(item.id, 1) or (previous and item.id >= previous) or
          not finite(item.delta) or not finite(item.balance) or not integer(item.revision) or
          (item.enabled ~= 0 and item.enabled ~= 1) or (item.previousEnabled ~= 0 and item.previousEnabled ~= 1) or
          (item.kind ~= "manager" and item.kind ~= "usage") then return nil, "Invalid history event." end
    elseif type(item.id) ~= "string" or item.id == "" or (previous and item.id <= previous) then
      return nil, "Invalid pending job."
    end
    previous = item.id
  end
  local cursor = kind == "history" and row.nextBeforeId or row.nextAfterId
  if cursor ~= nil then
    if kind == "history" and (not integer(cursor, 1) or cursor ~= previous) then return nil, "Invalid history cursor." end
    if kind ~= "history" and (type(cursor) ~= "string" or #cursor > 128 or cursor ~= previous) then return nil, "Invalid pending cursor." end
  end
  return row
end

function ManagerApi.parse_history(body, user_id) return parse_page(body, user_id, "history") end
function ManagerApi.parse_pending(body, user_id) return parse_page(body, user_id, "pending") end

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
    end,
    connection_token_fn = type(opts.connection_token_fn) == "function" and opts.connection_token_fn or function()
      return opts.connection_token or ""
    end
  }

  function client:set_base_url(base_url)
    self.base_url = normalize_base_url(base_url)
  end

  function client:connect_request()
    return make_request(self, "POST", "/api/reaper-manager/connection", "Connect Manager")
  end

  function client:disconnect_request()
    return make_request(self, "DELETE", "/api/reaper-manager/connection", "Disconnect Manager")
  end

  function client:connection_status_request()
    return make_request(self, "GET", "/api/reaper-manager/connection", "Check Manager connection")
  end

  function client:credits_request()
    return make_request(self, "GET", "/api/reaper-manager/elevenlabs/credits", "Fetch account credits")
  end

  function client:wallet_request(user_id, edit, balance_text)
    if trim(user_id) == "" then return nil, "userId is missing." end
    if edit then
      local ok, err = ManagerApi.validate_edit(edit, balance_text)
      if not ok then return nil, err end
    end
    local req, err = make_request(self, edit and "PUT" or "GET",
      "/api/reaper-manager/elevenlabs/users/" .. url_encode_path_segment(user_id),
      edit and "Edit balance/access" or "Read balance/access", edit)
    if req and edit then
      -- Emit the validated decimal as a JSON number, never as a string or a
      -- rounded fixed-width value. Revision is an exact safe integer.
      local fields = { '"expectedRevision":' .. string.format("%.0f", edit.expectedRevision) }
      if edit.balance ~= nil then
        local _, canonical = ManagerApi.parse_balance_input(balance_text or ManagerApi.format_number(edit.balance))
        fields[#fields + 1] = '"balance":' .. canonical
      end
      if edit.enabled ~= nil then fields[#fields + 1] = '"enabled":' .. tostring(edit.enabled) end
      req.json_payload_tbl = nil
      req.body_string = "{" .. table.concat(fields, ",") .. "}"
    end
    return req, err
  end

  function client:page_request(user_id, kind, cursor)
    if trim(user_id) == "" then return nil, "userId is missing." end
    if kind ~= "history" and kind ~= "pending" then return nil, "Invalid page kind." end
    local suffix = ""
    if cursor ~= nil then
      if kind == "history" and not integer(cursor, 1) then return nil, "Invalid history cursor." end
      if kind == "pending" and (type(cursor) ~= "string" or cursor == "" or #cursor > 128) then return nil, "Invalid pending cursor." end
      suffix = "?" .. (kind == "history" and "beforeId=" or "afterId=") .. url_encode_path_segment(cursor)
    end
    return make_request(self, "GET", "/api/reaper-manager/elevenlabs/users/" ..
      url_encode_path_segment(user_id) .. "/" .. kind .. suffix, "Read " .. kind)
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
