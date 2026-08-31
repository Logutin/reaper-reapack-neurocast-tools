local M = {}

M.MAX_SUPPORT_EXAMPLES = 12

local SEVERITY_ORDER = {
  bad_timecode = 10,
  bad_status = 20,
  overlap = 30,
  too_close = 40,
  too_short = 50,
  suspicious_timecode = 60,
  fps_warning = 70,
  manual_edit = 80,
  ambiguous_cast_match = 90,
  parser_warning = 100,
  empty_character = 110,
  empty_dialogue = 120,
  shrunk_to_fit = 130,
  offset_clamped = 140,
  sample = 900,
  neighbor = 950
}

local function as_number(value)
  return tonumber(value) or 0
end

local function copy_row(row)
  local out = {}
  if type(row) ~= "table" then return out end
  for k, v in pairs(row) do
    out[k] = v
  end
  return out
end

local function issue_kind(row)
  if type(row) ~= "table" then return "" end
  return tostring(row.issue_kind or "")
end

local function row_index(row)
  if type(row) ~= "table" then return 0 end
  return as_number(row.source_row_index) ~= 0 and as_number(row.source_row_index)
    or as_number(row.input_index)
end

local function severity(row)
  local kind = issue_kind(row)
  return SEVERITY_ORDER[kind] or 500
end

local function row_key(row)
  if type(row) ~= "table" then return "" end
  local source = tostring(row.source or "")
  local ref = tostring(row.row_ref or "")
  if ref ~= "" then return source .. ":" .. ref end
  return source .. ":" .. tostring(row_index(row)) .. ":" .. issue_kind(row)
end

local function count_rows_by_kind(rows)
  local counts = {}
  for i = 1, #(rows or {}) do
    local kind = issue_kind(rows[i])
    if kind == "" then kind = "unspecified" end
    counts[kind] = (counts[kind] or 0) + 1
  end
  return counts
end

local function add_example(out, seen, row)
  if type(row) ~= "table" then return false end
  local key = row_key(row)
  if seen[key] then return false end
  seen[key] = true
  out[#out + 1] = copy_row(row)
  return true
end

local function select_representative_examples(rows, max_examples)
  local src = rows or {}
  local max_count = math.max(0, math.floor(tonumber(max_examples) or M.MAX_SUPPORT_EXAMPLES))
  local out = {}
  local seen = {}
  if max_count < 1 or #src < 1 then return out end

  local sorted = {}
  for i = 1, #src do
    sorted[#sorted + 1] = src[i]
  end
  table.sort(sorted, function(a, b)
    local sa, sb = severity(a), severity(b)
    if sa ~= sb then return sa < sb end
    local ia, ib = row_index(a), row_index(b)
    if ia ~= ib then return ia < ib end
    return tostring(row_key(a)) < tostring(row_key(b))
  end)

  for i = 1, #sorted do
    if #out >= max_count then break end
    local kind = issue_kind(sorted[i])
    if kind ~= "sample" and kind ~= "neighbor" then
      add_example(out, seen, sorted[i])
    end
  end

  if #out < max_count and #src > 0 then
    local sample_positions = { 1, math.max(1, math.floor((#src + 1) / 2)), #src }
    for _, pos in ipairs(sample_positions) do
      if #out >= max_count then break end
      add_example(out, seen, src[pos])
    end
  end

  return out
end

function M.build_support_snapshot(stage, rows, counts, opts)
  local options = opts or {}
  local src_rows = rows or {}
  local max_examples = options.max_examples or M.MAX_SUPPORT_EXAMPLES
  local examples = select_representative_examples(src_rows, max_examples)
  local by_kind = count_rows_by_kind(src_rows)
  local provided_counts = type(counts) == "table" and counts or {}

  return {
    source_operation = tostring(stage or ""),
    snapshot_reason = tostring(options.reason or ""),
    row_count = #src_rows,
    example_count = #examples,
    max_examples = max_examples,
    truncated = #src_rows > #examples,
    counts = provided_counts,
    issue_kind_counts = by_kind,
    rows = examples
  }
end

function M.format_bytes(bytes)
  local n = math.max(0, as_number(bytes))
  if n >= 1000 * 1000 then
    return string.format("%.1f MB", n / (1000 * 1000))
  end
  if n >= 1000 then
    return string.format("%.0f KB", n / 1000)
  end
  return tostring(math.floor(n)) .. " B"
end

local function progress_uploaded_text(progress_line)
  local text = tostring(progress_line or "")
  if text == "" then return "" end
  local value, suffix = text:match("[Uu][Pp]:%s*([%d%.]+)%s*([kKmMgG]?)")
  if not value then return text end
  local n = tonumber(value)
  if not n then return text end
  suffix = tostring(suffix or ""):lower()
  if suffix == "g" then
    return string.format("%.1f GB", n)
  end
  if suffix == "m" then
    return string.format("%.1f MB", n)
  end
  if suffix == "k" then
    return string.format("%.0f KB", n)
  end
  return M.format_bytes(n)
end

function M.backlog_file_count(desc)
  if type(desc) ~= "table" then return 0 end
  local derived = as_number(desc.backlog_file_count)
  if derived > 0 then return derived end
  return as_number(desc.queued_file_count) + as_number(desc.sending_file_count)
end

function M.is_draining_backlog(desc)
  if type(desc) ~= "table" then return false end
  if desc.draining_backlog == true then return true end
  local backlog_bytes = as_number(desc.backlog_queue_bytes)
  if backlog_bytes > 0 then return M.backlog_file_count(desc) > 0 end
  return M.backlog_file_count(desc) > 0 and as_number(desc.sendable_queue_bytes) > as_number(desc.current_queue_bytes)
end

function M.backlog_status_text(desc)
  if not M.is_draining_backlog(desc) then return "" end
  local files = M.backlog_file_count(desc)
  local bytes_value = as_number(desc.backlog_queue_bytes)
  if bytes_value <= 0 then bytes_value = as_number(desc.sendable_queue_bytes) end
  local bytes = M.format_bytes(bytes_value)
  return string.format("Draining old telemetry: %d file%s, %s remaining", files, files == 1 and "" or "s", bytes)
end

function M.batch_progress_text(desc)
  if type(desc) ~= "table" then return "" end
  local event_count = as_number(desc.active_batch_event_count)
  local payload_bytes = as_number(desc.active_batch_payload_bytes)
  if event_count > 0 then
    local uploaded = progress_uploaded_text(desc.progress_line)
    if uploaded ~= "" then
      return string.format("Sending %d event%s, uploaded %s", event_count, event_count == 1 and "" or "s", uploaded)
    end
    return string.format("Sending %d event%s, payload %s", event_count, event_count == 1 and "" or "s", M.format_bytes(payload_bytes))
  end
  local progress = tostring(desc.progress_line or "")
  if progress ~= "" then
    return progress
  end
  if desc.active_job_id ~= nil then
    return tostring(desc.active_job_phase or "active")
  end
  return ""
end

return M
