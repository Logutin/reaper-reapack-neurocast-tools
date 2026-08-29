-- Pure bounded state model for integer-page Voice Library navigation.
--
-- The module performs no HTTP, JSON, telemetry, filesystem, REAPER, or UI work.

local VoiceLibraryState = {}
VoiceLibraryState.__index = VoiceLibraryState

local function positive_integer(value, fallback)
  local number = tonumber(value)
  if not number or number < 1 or number ~= math.floor(number) then
    return fallback
  end
  return number
end

local function valid_page(page)
  local number = tonumber(page)
  if not number or number < 0 or number ~= math.floor(number) then
    return nil
  end
  return number
end

local function copy_array(source)
  local out = {}
  for index, value in ipairs(source or {}) do
    out[index] = value
  end
  return out
end

local function copy_page(page)
  if type(page) ~= "table" then return nil end
  return {
    page = page.page,
    rows = copy_array(page.rows),
    has_more = page.has_more == true,
    total_count = page.total_count,
    duplicate_count = page.duplicate_count or 0,
    accepted_at = page.accepted_at
  }
end

function VoiceLibraryState.new(opts)
  opts = opts or {}
  local self = setmetatable({
    max_cached_pages = positive_integer(opts.max_cached_pages, 4),
    max_cached_rows = positive_integer(opts.max_cached_rows, 400),
    generation = 0,
    request_sequence = 0,
    touch_sequence = 0,
    query_key = "",
    account_generation = 0,
    current_page = nil,
    target_page = nil,
    pages = {},
    pending = {},
    errors = {},
    failed_page = nil,
    failed_error = nil,
    approximate_total = nil,
    stale_drop_count = 0,
    duplicate_drop_count = 0,
    eviction_count = 0
  }, VoiceLibraryState)
  return self
end

function VoiceLibraryState:reset(query_key, account_generation)
  self.generation = self.generation + 1
  self.query_key = tostring(query_key or "")
  self.account_generation = tonumber(account_generation) or 0
  self.current_page = nil
  self.target_page = nil
  self.pages = {}
  self.pending = {}
  self.errors = {}
  self.failed_page = nil
  self.failed_error = nil
  self.approximate_total = nil
  return self.generation
end

function VoiceLibraryState:cancel_pending()
  self.generation = self.generation + 1
  self.pending = {}
  self.target_page = nil
  self.failed_page = nil
  self.failed_error = nil
  return self.generation
end

function VoiceLibraryState:begin_load(page)
  local page_number = valid_page(page)
  if page_number == nil then
    return nil, "Voice Library page must be a non-negative integer"
  end

  self.request_sequence = self.request_sequence + 1
  local token = {
    generation = self.generation,
    request_id = self.request_sequence,
    page = page_number
  }
  self.pending[page_number] = token
  self.errors[page_number] = nil
  if self.failed_page == page_number then
    self.failed_page = nil
    self.failed_error = nil
  end
  self.target_page = page_number
  return token
end

function VoiceLibraryState:is_current_token(token)
  if type(token) ~= "table" then return false end
  if token.generation ~= self.generation then return false end
  local page_number = valid_page(token.page)
  if page_number == nil then return false end
  local pending = self.pending[page_number]
  return type(pending) == "table" and pending.request_id == token.request_id
end

local function resident_ids_except(pages, excluded_page)
  local seen = {}
  for page_number, page in pairs(pages) do
    if page_number ~= excluded_page then
      for _, row in ipairs(page.rows or {}) do
        local voice_id = type(row) == "table" and tostring(row.voice_id or "") or ""
        if voice_id ~= "" then seen[voice_id] = true end
      end
    end
  end
  return seen
end

function VoiceLibraryState:_resident_counts()
  local page_count = 0
  local row_count = 0
  for _, page in pairs(self.pages) do
    page_count = page_count + 1
    row_count = row_count + #(page.rows or {})
  end
  return page_count, row_count
end

function VoiceLibraryState:_evict_if_needed()
  while true do
    local page_count, row_count = self:_resident_counts()
    if page_count <= self.max_cached_pages and row_count <= self.max_cached_rows then
      return
    end

    local candidate_number = nil
    local candidate_touch = nil
    for page_number, page in pairs(self.pages) do
      if page_number ~= self.current_page then
        local touched = tonumber(page.touched) or 0
        if candidate_touch == nil or touched < candidate_touch then
          candidate_number = page_number
          candidate_touch = touched
        end
      end
    end
    if candidate_number == nil then
      -- A single pinned page may itself exceed the configured row bound.
      return
    end
    self.pages[candidate_number] = nil
    self.errors[candidate_number] = nil
    self.eviction_count = self.eviction_count + 1
  end
end

function VoiceLibraryState:accept_page(token, page_data)
  if not self:is_current_token(token) then
    self.stale_drop_count = self.stale_drop_count + 1
    return false, "stale"
  end
  if type(page_data) ~= "table" or type(page_data.rows) ~= "table" then
    return false, "page data must contain a rows array"
  end

  local page_number = token.page
  local seen = resident_ids_except(self.pages, page_number)
  local rows = {}
  local dropped = tonumber(page_data.duplicate_count) or 0
  for _, row in ipairs(page_data.rows) do
    local voice_id = type(row) == "table" and tostring(row.voice_id or "") or ""
    if voice_id == "" then
      return false, "page row is missing voice_id"
    end
    if seen[voice_id] then
      dropped = dropped + 1
    else
      seen[voice_id] = true
      rows[#rows + 1] = row
    end
  end

  self.touch_sequence = self.touch_sequence + 1
  local total_count = tonumber(page_data.total_count)
  if total_count and (total_count < 0 or total_count ~= math.floor(total_count)) then
    total_count = nil
  end
  self.pages[page_number] = {
    page = page_number,
    rows = rows,
    has_more = page_data.has_more == true,
    total_count = total_count,
    duplicate_count = dropped,
    accepted_at = os.time(),
    touched = self.touch_sequence
  }
  self.pending[page_number] = nil
  self.errors[page_number] = nil
  self.failed_page = nil
  self.failed_error = nil
  self.current_page = page_number
  self.target_page = nil
  if total_count ~= nil then self.approximate_total = total_count end
  self.duplicate_drop_count = self.duplicate_drop_count + dropped
  self:_evict_if_needed()
  return true
end

function VoiceLibraryState:fail_page(token, error_info)
  if not self:is_current_token(token) then
    self.stale_drop_count = self.stale_drop_count + 1
    return false, "stale"
  end
  local page_number = token.page
  self.pending[page_number] = nil
  self.errors[page_number] = tostring(error_info or "Voice Library page load failed")
  self.failed_page = page_number
  self.failed_error = self.errors[page_number]
  if self.target_page == page_number then self.target_page = nil end
  return true
end

function VoiceLibraryState:has_page(page)
  local page_number = valid_page(page)
  return page_number ~= nil and self.pages[page_number] ~= nil
end

function VoiceLibraryState:get_page(page)
  local page_number = valid_page(page)
  if page_number == nil then return nil end
  local stored = self.pages[page_number]
  if not stored then return nil end
  self.touch_sequence = self.touch_sequence + 1
  stored.touched = self.touch_sequence
  return copy_page(stored)
end

function VoiceLibraryState:activate_page(page)
  local page_number = valid_page(page)
  if page_number == nil then
    return false, "Voice Library page must be a non-negative integer"
  end
  local stored = self.pages[page_number]
  if not stored then return false, "not_cached" end
  self.touch_sequence = self.touch_sequence + 1
  stored.touched = self.touch_sequence
  self.current_page = page_number
  self.target_page = nil
  return true
end

function VoiceLibraryState:navigation()
  local current = self.current_page and self.pages[self.current_page] or nil
  local loading = false
  for _ in pairs(self.pending) do
    loading = true
    break
  end
  return {
    current_page = self.current_page,
    target_page = self.target_page,
    has_previous = self.current_page ~= nil and self.current_page > 0,
    has_more = current and current.has_more == true or false,
    loading = loading,
    approximate_total = self.approximate_total,
    failed_page = self.failed_page,
    failed_error = self.failed_error,
    error = self.failed_error
  }
end

function VoiceLibraryState:snapshot()
  local navigation = self:navigation()
  local current = self.current_page and self.pages[self.current_page] or nil
  navigation.rows = current and copy_array(current.rows) or {}
  navigation.current_total_count = current and current.total_count or nil
  navigation.current_duplicate_count = current and current.duplicate_count or 0
  return navigation
end

function VoiceLibraryState:stats()
  local page_count, row_count = self:_resident_counts()
  local pending_count = 0
  for _ in pairs(self.pending) do pending_count = pending_count + 1 end
  return {
    generation = self.generation,
    pages_held = page_count,
    rows_held = row_count,
    pending_count = pending_count,
    stale_drops = self.stale_drop_count,
    duplicate_drops = self.duplicate_drop_count,
    evictions = self.eviction_count
  }
end

return VoiceLibraryState
