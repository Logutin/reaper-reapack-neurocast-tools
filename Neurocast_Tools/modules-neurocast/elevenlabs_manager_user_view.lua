-- Local user-directory view model for the active ElevenLabs Manager.
-- Filtering and sorting are intentionally client-side and have no network or
-- telemetry dependencies.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local Util = require("modules-neurocast.Util")
local Utf8Tools = require("modules-neurocast.Utf8Tools")

local UserView = {}

local function trim(value)
  if type(Util.trim) == "function" then return Util.trim(value) end
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalized_text(value)
  local text = trim(value)
  local lowered = Utf8Tools.lower(text)
  if type(lowered) == "string" then return lowered end
  return text:lower()
end

function UserView.account_display(account_id)
  if account_id == nil or trim(account_id) == "" then return "Blocked" end
  if account_id == "elevenlabs_1" then return "el_1" end
  if account_id == "elevenlabs_2" then return "el_2" end
  return tostring(account_id)
end

local function user_matches(user, normalized_query)
  if normalized_query == "" then return true end
  for _, field in ipairs({ "fullname", "username", "email" }) do
    if normalized_text(user[field]):find(normalized_query, 1, true) then return true end
  end
  return false
end

local function user_sort_source(user, column)
  if column == 1 then return trim(user.fullname) end
  if column == 2 then return trim(user.username) end
  if column == 3 then return trim(user.email) end
  if column == 4 then return UserView.account_display(user.accountId) end
  return trim(user.fullname)
end

function UserView.build_rows(users, query, sort_column, sort_ascending)
  local source_rows = type(users) == "table" and users or {}
  local normalized_query = normalized_text(query)
  local filter_active = normalized_query ~= ""
  local column = tonumber(sort_column) or 1
  if column < 1 or column > 4 then column = 1 end
  local ascending = sort_ascending ~= false

  local rows = {}
  for _, user in ipairs(source_rows) do
    if type(user) == "table" and user_matches(user, normalized_query) then
      rows[#rows + 1] = user
    end
  end

  table.sort(rows, function(a, b)
    local a_source = user_sort_source(a, column)
    local b_source = user_sort_source(b, column)
    local a_missing = trim(a_source) == ""
    local b_missing = trim(b_source) == ""
    if a_missing ~= b_missing then return not a_missing end

    local av = normalized_text(a_source)
    local bv = normalized_text(b_source)
    if av == bv then
      av = trim(a.userId)
      bv = trim(b.userId)
    end
    if ascending then return av < bv end
    return av > bv
  end)

  return rows, filter_active
end

return UserView
