-- Pure presentation state for the Voice Library UI.
-- No ReaImGui, network, filesystem, telemetry, or REAPER dependencies.

local VoiceLibraryUiState = {}
VoiceLibraryUiState.__index = VoiceLibraryUiState

local QUERY_KEYS = {
  "search",
  "language",
  "accent",
  "gender",
  "age",
  "category"
}

local function clean(value)
  local text = tostring(value or ""):match("^%s*(.-)%s*$")
  return text ~= "" and text or nil
end

local function copy_query(query)
  local out = {}
  query = type(query) == "table" and query or {}
  for _, key in ipairs(QUERY_KEYS) do out[key] = clean(query[key]) end
  return out
end

local function queries_equal(left, right)
  left = type(left) == "table" and left or {}
  right = type(right) == "table" and right or {}
  for _, key in ipairs(QUERY_KEYS) do
    if clean(left[key]) ~= clean(right[key]) then return false end
  end
  return true
end

function VoiceLibraryUiState.new()
  local defaults = copy_query({})
  return setmetatable({
    draft_query = copy_query(defaults),
    applied_query = copy_query(defaults),
    dirty = false,
    catalog_invalidated = false,
    selected_voice_id = "",
    selected_voice = nil,
    autoplay_voice_id = "",
    autoplay_due_at = nil,
    suppress_autoplay_voice_id = ""
  }, VoiceLibraryUiState)
end

function VoiceLibraryUiState.copy_query(query)
  return copy_query(query)
end

function VoiceLibraryUiState.queries_equal(left, right)
  return queries_equal(left, right)
end

function VoiceLibraryUiState.normalize_page_size(value)
  local number = tonumber(value)
  if number == 30 or number == 50 or number == 100 then return number end
  return 30
end

function VoiceLibraryUiState:set_filter(key, value)
  local supported = false
  for _, candidate in ipairs(QUERY_KEYS) do
    if candidate == key then supported = true break end
  end
  if not supported then return false, "unsupported Voice Library UI filter" end
  local normalized = clean(value)
  if key == "language" and normalized ~= self.draft_query.language then
    self.draft_query.accent = nil
  end
  self.draft_query[key] = normalized
  self.dirty = not queries_equal(self.draft_query, self.applied_query)
  return true
end

function VoiceLibraryUiState:reset_draft()
  self.draft_query = copy_query({})
  self.dirty = not queries_equal(self.draft_query, self.applied_query)
  self:cancel_autoplay()
end

function VoiceLibraryUiState:commit_draft()
  self.applied_query = copy_query(self.draft_query)
  self.dirty = false
  self.catalog_invalidated = false
  self:clear_selection()
  return copy_query(self.applied_query)
end

function VoiceLibraryUiState:invalidate_catalog()
  self.catalog_invalidated = true
  self:clear_selection()
end

function VoiceLibraryUiState:clear_selection()
  self.selected_voice_id = ""
  self.selected_voice = nil
  self.suppress_autoplay_voice_id = ""
  self:cancel_autoplay()
end

function VoiceLibraryUiState:select_voice(voice, now, autoplay_enabled, suppress_autoplay)
  local voice_id = type(voice) == "table" and tostring(voice.voice_id or "") or ""
  self.selected_voice_id = voice_id
  self.selected_voice = voice
  self:cancel_autoplay()
  if suppress_autoplay then
    self.suppress_autoplay_voice_id = voice_id
    return false
  end
  self.suppress_autoplay_voice_id = ""
  if autoplay_enabled and voice_id ~= "" then
    self.autoplay_voice_id = voice_id
    self.autoplay_due_at = (tonumber(now) or 0) + 0.3
    return true
  end
  return false
end

function VoiceLibraryUiState:cancel_autoplay()
  self.autoplay_voice_id = ""
  self.autoplay_due_at = nil
end

function VoiceLibraryUiState:take_due_autoplay(now)
  if not self.autoplay_due_at or (tonumber(now) or 0) < self.autoplay_due_at then
    return nil
  end
  local voice_id = self.autoplay_voice_id
  self:cancel_autoplay()
  if voice_id == "" or voice_id ~= self.selected_voice_id then return nil end
  return self.selected_voice
end

function VoiceLibraryUiState.summary(query, label_for)
  query = type(query) == "table" and query or {}
  label_for = type(label_for) == "function" and label_for or function(_, value)
    return tostring(value or "")
  end
  local parts = {}
  for _, key in ipairs(QUERY_KEYS) do
    local value = clean(query[key])
    if value then
      parts[#parts + 1] = key .. "=" .. tostring(label_for(key, value))
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "Any"
end

return VoiceLibraryUiState
