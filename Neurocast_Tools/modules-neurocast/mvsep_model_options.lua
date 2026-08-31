-- Persistence-neutral helpers for MVSEP dynamic model fields.
-- The caller owns file I/O; this module keeps reconciliation testable without
-- a REAPER or ReaImGui runtime.

local M = {}

M.SCHEMA_VERSION = 1

local function copy_values(source)
  local out = {}
  for key, value in pairs(source or {}) do
    if type(key) == "string" and key ~= "" and value ~= nil then
      out[key] = tostring(value)
    end
  end
  return out
end

local function copy_persisted_values(source)
  local out = {}
  for key, value in pairs(source or {}) do
    if type(key) == "string" and key ~= "" and type(value) == "string" then
      out[key] = value
    end
  end
  return out
end

local function sorted_option_keys(options)
  local keys = {}
  for key in pairs(options or {}) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys, function(a, b)
    local an = tonumber(a)
    local bn = tonumber(b)
    if an and bn and an ~= bn then return an < bn end
    if an and not bn then return true end
    if bn and not an then return false end
    return a < b
  end)
  return keys
end

local function select_value(field, remembered)
  local options = type(field.options) == "table" and field.options or {}
  if remembered ~= nil and options[tostring(remembered)] ~= nil then
    return tostring(remembered)
  end

  local default_key = field.default_key
  if default_key ~= nil and options[tostring(default_key)] ~= nil then
    return tostring(default_key)
  end

  local keys = sorted_option_keys(options)
  return keys[1] or ""
end

function M.empty_settings()
  return {
    schema_version = M.SCHEMA_VERSION,
    models = {}
  }
end

function M.decode_settings(decoded)
  if type(decoded) ~= "table" then
    return M.empty_settings(), "settings root must be an object"
  end
  if decoded.schema_version ~= M.SCHEMA_VERSION then
    return M.empty_settings(), "unsupported settings schema_version: " .. tostring(decoded.schema_version)
  end
  if type(decoded.models) ~= "table" then
    return M.empty_settings(), "settings models must be an object"
  end

  local settings = M.empty_settings()
  for sep_type, values in pairs(decoded.models) do
    if type(sep_type) == "string" and sep_type ~= "" and type(values) == "table" then
      settings.models[sep_type] = copy_persisted_values(values)
    end
  end
  return settings, nil
end

function M.decode_json(json, text)
  local ok, decoded = pcall(json.decode, tostring(text or ""))
  if not ok then
    return M.empty_settings(), "settings JSON decode failed: " .. tostring(decoded)
  end
  return M.decode_settings(decoded)
end

function M.reconcile_model(model, remembered_values)
  local active = {}
  local remembered = {}
  local source = type(remembered_values) == "table" and remembered_values or {}

  if type(model) ~= "table" then
    return active, remembered
  end

  for _, field in ipairs(model.fields or {}) do
    local form_key = type(field.form_key) == "string" and field.form_key or ""
    if form_key ~= "" then
      local prior = source[form_key]
      local value
      if field.input_type == "select" then
        value = select_value(field, prior)
      elseif prior ~= nil then
        value = tostring(prior)
      elseif field.default_key ~= nil then
        value = tostring(field.default_key)
      else
        value = ""
      end
      active[form_key] = value
      remembered[form_key] = value
    end
  end

  return active, remembered
end

function M.copy_values(source)
  return copy_values(source)
end

return M
