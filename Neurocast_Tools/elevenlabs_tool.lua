--========================================================
-- Elevenlabs Studio Neurocast tool script v2.1.1
--========================================================

-- Entrypoint-owned orchestration between the shared Voice Library API/state/
-- preview modules and this script's Curl, Jobs, Cleanup, telemetry, and
-- diagnostics adapters. The factory is intentionally above REAPER bootstrap so
-- focused headless tests can load only this controller without starting the app.
local function create_voice_library_controller(deps)
  assert(type(deps) == "table", "Voice Library controller dependencies are required")
  assert(type(deps.api) == "table", "Voice Library API dependency is required")
  assert(type(deps.state) == "table", "Voice Library state dependency is required")
  assert(type(deps.build_list_request) == "function", "Voice Library Studio request builder is required")
  assert(type(deps.submit) == "function", "Voice Library submit dependency is required")

  local controller = {
    deps = deps,
    state = deps.state,
    preview = deps.preview,
    initialized = false,
    closed = false,
    query = nil,
    query_key = "",
    account_generation = 0,
    active = {},
    completed_requests = 0,
    failed_requests = 0,
    canceled_requests = 0,
    stale_completions = 0,
    retry_count = 0,
    preview_request_count = 0
  }

  local function safe_call(callback, ...)
    if type(callback) ~= "function" then return nil end
    local ok, first, second = pcall(callback, ...)
    if ok then return first, second end
    return nil
  end

  local function now()
    if type(deps.now) == "function" then
      return tonumber(deps.now()) or 0
    end
    return os.clock()
  end

  local function safe_error(value)
    local text = tostring(value or "Voice Library request failed")
    if type(deps.sanitize_error) == "function" then
      text = tostring(deps.sanitize_error(text) or "Voice Library request failed")
    end
    if #text > 512 then text = text:sub(1, 512) end
    return text
  end

  local function emit(event_name, payload)
    safe_call(deps.emit_telemetry, event_name, payload or {})
  end

  local function diagnose(level, message, payload)
    safe_call(deps.diagnostic, level, tostring(message or ""), payload or {})
  end

  local function progress(event_name, record)
    safe_call(deps.on_progress, event_name, {
      request_id = record and record.request_id or nil,
      page = record and record.page or nil,
      attempt = record and record.attempt or nil,
      max_attempts = record and record.max_attempts or nil,
      state = record and record.state or nil,
      job_id = record and record.job_id or nil,
      error = record and record.error or nil
    }, record)
  end

  local function release_body(result)
    if type(result) == "table" then result.body = nil end
    safe_call(deps.release_response_body, result)
  end

  local function request_id_for(token)
    return tostring(token.generation) .. ":" .. tostring(token.request_id)
  end

  local function finish_record(record, state, err)
    record.state = state
    record.error = err and safe_error(err) or nil
    record.finished_at = now()
    controller.active[record.request_id] = nil
    progress(state, record)
  end

  function controller:open(filters, account_generation)
    if self.closed then return false, "Voice Library controller is shut down" end
    local normalized, normalize_err = deps.api.normalize_query(filters or {})
    if not normalized then return false, normalize_err end
    local key, key_err = deps.api.query_key(normalized)
    if not key then return false, key_err end

    if self.initialized then
      self:cancel_pending("query_changed")
    end
    self.query = normalized
    self.query_key = key
    self.account_generation = tonumber(account_generation) or self.account_generation or 0
    self.state:reset(key, self.account_generation)
    self.initialized = true
    emit("voice_library_opened", {
      account_generation = self.account_generation,
      filter_count = (function()
        local count = 0
        for name, value in pairs(normalized) do
          if name ~= "sort" and value ~= nil then count = count + 1 end
        end
        return count
      end)()
    })
    progress("opened")
    return true
  end

  function controller:set_filters(filters)
    return self:open(filters, self.account_generation)
  end

  function controller:account_changed(account_generation)
    if self.closed then return false, "Voice Library controller is shut down" end
    self.account_generation = tonumber(account_generation) or (self.account_generation + 1)
    if type(deps.stop_preview_owner) == "function" then
      safe_call(deps.stop_preview_owner, "voice_library")
    else
      self:stop_preview()
    end
    if not self.initialized then
      return self:open({}, self.account_generation)
    end
    self:cancel_pending("account_changed")
    self.state:reset(self.query_key, self.account_generation)
    emit("voice_library_account_changed", {
      account_generation = self.account_generation
    })
    return true
  end

  function controller:cancel_pending(reason)
    local canceled = 0
    local records = {}
    for _, record in pairs(self.active) do records[#records + 1] = record end
    for _, record in ipairs(records) do
      if record.state == "running" or record.state == "retry_wait" then
        record.canceled = true
        finish_record(record, "canceled", safe_error(reason or "canceled"))
        canceled = canceled + 1
      end
    end
    self.state:cancel_pending()
    self.canceled_requests = self.canceled_requests + canceled
    if canceled > 0 then
      local reason_code = tostring(reason or "")
      if reason_code ~= "account_changed" and reason_code ~= "query_changed" and
         reason_code ~= "shutdown" and reason_code ~= "superseded" then
        reason_code = "canceled"
      end
      emit("voice_library_requests_canceled", {
        count = canceled,
        reason = reason_code
      })
    end
    return canceled
  end

  function controller:start_page(page)
    if self.closed then return nil, "Voice Library controller is shut down" end
    if not self.initialized then
      local ok_open, open_err = self:open({}, self.account_generation)
      if not ok_open then return nil, open_err end
    end

    local page_number = page
    if page_number == nil then
      page_number = self.state:navigation().current_page or 0
    end
    page_number = tonumber(page_number)
    if not page_number or page_number < 0 or page_number ~= math.floor(page_number) then
      return nil, "Voice Library page must be a non-negative integer"
    end

    local has_active = false
    for _ in pairs(self.active) do
      has_active = true
      break
    end
    if has_active then
      self:cancel_pending("superseded")
    end

    local token, token_err = self.state:begin_load(page_number)
    if not token then return nil, token_err end
    local request_id = request_id_for(token)
    local record = {
      request_id = request_id,
      token = token,
      page = page_number,
      attempt = 1,
      max_attempts = math.max(1, tonumber(deps.max_attempts) or 3),
      state = "running",
      started_at = now()
    }
    self.active[request_id] = record
    progress("started", record)
    emit("voice_library_page_started", {
      page = page_number,
      attempt = 1
    })

    local submit_once
    submit_once = function()
      if self.closed or record.canceled or not self.state:is_current_token(token) then
        return false, "canceled"
      end

      record.state = "running"
      record.error = nil
      local req, request_err = deps.build_list_request(
        self.query,
        page_number,
        deps.page_size
      )
      if not req then
        local err_text = safe_error(request_err or "Studio Voice Library request could not be built")
        self.state:fail_page(token, err_text)
        self.failed_requests = self.failed_requests + 1
        finish_record(record, "failed", err_text)
        return false, err_text
      end
      local attempt_label = req.label
      if type(deps.format_attempt_label) == "function" then
        attempt_label = deps.format_attempt_label(req.label, record.attempt, record.max_attempts)
      end
      local attempt_req = {}
      for key, value in pairs(req) do attempt_req[key] = value end
      attempt_req.label = attempt_label
      progress("submitted", record)

      local function on_done(result, job)
        if self.closed or record.canceled or not self.state:is_current_token(token) then
          release_body(result)
          self.stale_completions = self.stale_completions + 1
          if record.state ~= "canceled" then
            finish_record(record, "stale")
          end
          emit("voice_library_page_discarded", {
            page = page_number,
            attempt = record.attempt,
            reason = record.canceled and "canceled" or "stale"
          })
          return
        end

        safe_call(deps.update_transport_state, result, job, "Voice Library page")
        if result and result.ok == true and type(result.body) == "string" and result.body ~= "" then
          local raw_body = result.body
          local page_data, parse_err = deps.api.parse_list_response(raw_body)
          raw_body = nil
          release_body(result)
          if page_data then
            local accepted, accept_err = self.state:accept_page(token, page_data)
            if accepted then
              self.completed_requests = self.completed_requests + 1
              finish_record(record, "ok")
              emit("voice_library_page_completed", {
                page = page_number,
                row_count = #page_data.rows,
                has_more = page_data.has_more == true,
                duplicate_count = tonumber(page_data.duplicate_count) or 0,
                attempt_count = record.attempt
              })
              return
            end
            self.stale_completions = self.stale_completions + 1
            finish_record(record, "stale", accept_err)
            return
          end
          result.ok = false
          result.err = safe_error(parse_err)
        else
          local parsed_error = result and deps.api.parse_error(result.body) or nil
          release_body(result)
          if result then
            result.err = safe_error(parsed_error or result.err)
          end
        end

        local err_text = safe_error(result and result.err)
        record.error = err_text
        safe_call(deps.update_retry_state, record, err_text, result, err_text)
        local retryable = false
        if type(deps.is_retryable) == "function" then
          retryable = deps.is_retryable(result) == true
        end
        if retryable and record.attempt < record.max_attempts and
           type(deps.enqueue_retry) == "function" then
          record.attempt = record.attempt + 1
          record.state = "retry_wait"
          self.retry_count = self.retry_count + 1
          progress("retry_wait", record)
          emit("voice_library_page_retry_scheduled", {
            page = page_number,
            attempt = record.attempt,
            max_attempts = record.max_attempts
          })
          deps.enqueue_retry(
            req.label,
            submit_once,
            record.attempt,
            record.max_attempts,
            err_text,
            record
          )
          return
        end

        self.state:fail_page(token, err_text)
        self.failed_requests = self.failed_requests + 1
        finish_record(record, "failed", err_text)
        diagnose(2, "Voice Library page request failed", {
          page = page_number,
          attempt_count = record.attempt
        })
        emit("voice_library_page_failed", {
          page = page_number,
          attempt_count = record.attempt
        })
      end

      local job, submit_err = deps.submit(attempt_req, on_done, {
        read_body = true,
        keep_output = false,
        body_max_bytes = deps.body_max_bytes
      }, record)
      if not job then
        local err_text = safe_error(submit_err or "Voice Library request failed to start")
        self.state:fail_page(token, err_text)
        self.failed_requests = self.failed_requests + 1
        finish_record(record, "failed", err_text)
        emit("voice_library_page_failed", {
          page = page_number,
          attempt_count = record.attempt,
          start_failure = true
        })
        return false, err_text
      end
      record.job_id = job.id
      job.keep_in_list = true
      progress("running", record)
      return true
    end

    record.retry_submit = submit_once
    record._retry_submit = submit_once
    local submitted, submit_err = submit_once()
    if not submitted then return nil, submit_err end
    return token, record
  end

  function controller:navigate(page)
    if self.closed then return false, "Voice Library controller is shut down" end
    local activated, activate_err = self.state:activate_page(page)
    if activated then
      emit("voice_library_page_activated", { page = tonumber(page) })
      progress("activated")
    end
    return activated, activate_err
  end

  function controller:view()
    local view
    if type(self.state.snapshot) == "function" then
      view = self.state:snapshot()
    else
      view = self.state:navigation()
      local current = view.current_page ~= nil and self.state:get_page(view.current_page) or nil
      view.rows = current and current.rows or {}
    end
    view.initialized = self.initialized
    view.account_generation = self.account_generation
    if type(self.preview) == "table" and type(self.preview.status) == "function" then
      view.preview = self.preview:status()
    else
      view.preview = {
        available = false,
        state = "idle",
        voice_id = ""
      }
    end
    return view
  end

  function controller:retry_failed_page()
    if self.closed then return nil, "Voice Library controller is shut down" end
    local navigation = self.state:navigation()
    local failed_page = navigation.failed_page
    if failed_page == nil then return nil, "no failed Voice Library page to retry" end
    return self:start_page(failed_page)
  end

  function controller:preview_policy(voice)
    if type(deps.api.resolve_preview) ~= "function" then
      local available = type(voice) == "table" and tostring(voice.preview_url or "") ~= ""
      return {
        available = available,
        match_kind = available and "top_level" or "unavailable",
        warning_code = available and nil or "unavailable"
      }
    end
    local choice, choice_err = deps.api.resolve_preview(voice, self.query or {})
    if not choice then return nil, choice_err end
    return {
      available = type(choice.voice) == "table",
      match_kind = choice.match_kind,
      language = choice.language,
      accent = choice.accent,
      warning_code = choice.warning_code
    }
  end

  function controller:request_preview(voice, callbacks, opts)
    if self.closed then return nil, "Voice Library controller is shut down" end
    if type(self.preview) ~= "table" or type(self.preview.request) ~= "function" then
      return nil, "Voice Library preview is unavailable"
    end
    local preview_voice = voice
    if type(deps.api.resolve_preview) == "function" then
      local choice, choice_err = deps.api.resolve_preview(voice, self.query or {})
      if not choice then return nil, choice_err end
      if type(choice.voice) ~= "table" then
        return nil, "selected voice has no preview URL"
      end
      preview_voice = choice.voice
    end
    self.preview_request_count = self.preview_request_count + 1
    local token, status = self.preview:request(preview_voice, callbacks, opts)
    if token then
      emit("voice_library_preview_requested", {
        status = tostring(status or "requested"):sub(1, 32)
      })
    end
    return token, status
  end

  function controller:stop_preview()
    if type(self.preview) ~= "table" or type(self.preview.stop) ~= "function" then
      return false, "Voice Library preview is unavailable"
    end
    local ok, err = self.preview:stop()
    emit("voice_library_preview_stopped", { ok = ok == true })
    return ok, err
  end

  function controller:shutdown()
    if self.closed then return true end
    self:cancel_pending("shutdown")
    self.closed = true
    if type(self.preview) == "table" then
      if type(self.preview.shutdown) == "function" then
        safe_call(self.preview.shutdown, self.preview)
      elseif type(self.preview.stop) == "function" then
        safe_call(self.preview.stop, self.preview)
      end
    end
    emit("voice_library_shutdown", {})
    return true
  end

  function controller:stats()
    local active_count = 0
    for _ in pairs(self.active) do active_count = active_count + 1 end
    local out = self.state:stats()
    out.initialized = self.initialized
    out.closed = self.closed
    out.active_requests = active_count
    out.completed_requests = self.completed_requests
    out.failed_requests = self.failed_requests
    out.canceled_requests = self.canceled_requests
    out.stale_completions = self.stale_completions
    out.retries = self.retry_count
    out.preview_requests = self.preview_request_count
    if type(self.preview) == "table" and type(self.preview.stats) == "function" then
      out.preview = self.preview:stats()
    end
    return out
  end

  return controller
end

-- Entrypoint-owned single-flight controller for the only authorized Voice
-- Library mutation: adding one explicitly confirmed selected shared voice to
-- the current ElevenLabs account. It deliberately owns no browse or preview
-- state and exposes a separate headless test boundary.
local function create_voice_library_add_controller(deps)
  assert(type(deps) == "table", "Add shared voice controller dependencies are required")
  assert(type(deps.api) == "table", "Add shared voice API dependency is required")
  assert(type(deps.build_add_request) == "function", "Add shared voice Studio request builder is required")
  assert(type(deps.build_reconciliation_request) == "function", "Shared voice reconciliation Studio request builder is required")
  assert(type(deps.submit_add) == "function", "Add shared voice submit dependency is required")
  assert(type(deps.submit_read) == "function", "Add shared voice read dependency is required")
  assert(type(deps.check_name) == "function", "Add shared voice name-check dependency is required")
  assert(type(deps.refresh_account) == "function", "Add shared voice refresh dependency is required")

  local controller = {
    deps = deps,
    closed = false,
    state = "idle",
    refresh_state = "idle",
    outcome_code = nil,
    error_code = nil,
    account_generation = 0,
    next_token = 0,
    operation = nil,
    selection_voice_id = "",
    draft_name = "",
    added_overlay = {},
    stale_completions = 0,
    double_submit_suppressed = 0
  }

  local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
  end

  local function safe_call(callback, ...)
    if type(callback) ~= "function" then return nil end
    local ok, first, second = pcall(callback, ...)
    if ok then return first, second end
    return nil
  end

  local function now()
    if type(deps.now) == "function" then
      return tonumber(deps.now()) or 0
    end
    return os.clock()
  end

  local function latency_bucket(started_at)
    local elapsed = math.max(0, now() - (tonumber(started_at) or now()))
    if elapsed < 1 then return "under_1s" end
    if elapsed < 5 then return "1_5s" end
    if elapsed < 30 then return "5_30s" end
    return "30s_plus"
  end

  local function http_class(code)
    local number = tonumber(code)
    if not number or number <= 0 then return "none" end
    return tostring(math.floor(number / 100)) .. "xx"
  end

  local function emit(event_name, payload)
    local source = type(payload) == "table" and payload or {}
    safe_call(deps.emit_telemetry, event_name, {
      phase = source.phase and tostring(source.phase):sub(1, 32) or nil,
      outcome = source.outcome and tostring(source.outcome):sub(1, 32) or nil,
      http_class = source.http_class and tostring(source.http_class):sub(1, 8) or nil,
      latency_bucket =
        source.latency_bucket and tostring(source.latency_bucket):sub(1, 16) or nil,
      cancellation = source.cancellation == true or nil,
      duplicate = source.duplicate == true or nil,
      reconciled = source.reconciled == true or nil,
      retry_ready = source.retry_ready == true or nil,
      stale = source.stale == true or nil,
      double_submit = source.double_submit == true or nil
    })
  end

  local function diagnose(event_name, payload)
    local source = type(payload) == "table" and payload or {}
    safe_call(deps.diagnostic, tostring(event_name or "event"):sub(1, 32), {
      outcome = source.outcome and tostring(source.outcome):sub(1, 32) or nil,
      http_class = source.http_class and tostring(source.http_class):sub(1, 8) or nil,
      cancellation = source.cancellation == true or nil
    })
  end

  local function release_body(result)
    if type(result) == "table" then result.body = nil end
    safe_call(deps.release_response_body, result)
  end

  local function is_busy_state(state)
    return
      state == "confirming" or
      state == "checking_name" or
      state == "submitting" or
      state == "reconciling" or
      state == "ambiguous"
  end

  local function is_current(operation)
    return
      not controller.closed and
      type(operation) == "table" and
      controller.operation == operation and
      operation.token == controller.next_token and
      operation.account_generation == controller.account_generation
  end

  local function classify_http_error(code)
    local number = tonumber(code)
    if number == 400 then return "bad_request" end
    if number == 401 then return "authorization" end
    if number == 402 then return "payment_required" end
    if number == 403 then return "forbidden" end
    if number == 404 then return "not_found" end
    if number == 409 then return "conflict" end
    if number == 422 then return "validation" end
    if number == 429 then return "rate_limited" end
    return "request_failed"
  end

  local function is_definite_http_rejection(code)
    local number = tonumber(code)
    return
      number == 400 or
      number == 401 or
      number == 402 or
      number == 403 or
      number == 404 or
      number == 409 or
      number == 422 or
      number == 429
  end

  local function mark_recoverable(operation, code, result)
    if not is_current(operation) then
      release_body(result)
      controller.stale_completions = controller.stale_completions + 1
      return
    end
    release_body(result)
    controller.state = "recoverable_failure"
    controller.outcome_code = "recoverable_failure"
    controller.error_code = code or "request_failed"
    diagnose("recoverable_failure", {
      outcome = controller.error_code,
      http_class = http_class(result and result.http_code)
    })
    emit("voice_library_add_failed", {
      phase = operation.phase,
      outcome = controller.error_code,
      http_class = http_class(result and result.http_code),
      latency_bucket = latency_bucket(operation.started_at)
    })
  end

  local function mark_ambiguous(operation, code, result)
    if not is_current(operation) then
      release_body(result)
      controller.stale_completions = controller.stale_completions + 1
      return
    end
    release_body(result)
    controller.state = "ambiguous"
    controller.outcome_code = "ambiguous"
    controller.error_code = code or "transport_ambiguous"
    diagnose("ambiguous", {
      outcome = controller.error_code,
      http_class = http_class(result and result.http_code),
      cancellation = result and result.canceled == true or nil
    })
    emit("voice_library_add_ambiguous", {
      phase = operation.phase,
      outcome = controller.error_code,
      http_class = http_class(result and result.http_code),
      latency_bucket = latency_bucket(operation.started_at),
      cancellation = result and result.canceled == true or nil
    })
  end

  local begin_refresh

  local function mark_success(operation, account_voice_id, reconciled)
    if not is_current(operation) then return false end
    operation.returned_voice_id = trim(account_voice_id)
    controller.added_overlay[operation.source_voice_id] = true
    controller.state = reconciled and "success_reconciled" or "success"
    controller.outcome_code = reconciled and "success_reconciled" or "success"
    controller.error_code = nil
    emit("voice_library_add_completed", {
      phase = operation.phase,
      outcome = controller.outcome_code,
      http_class = reconciled and "none" or "2xx",
      latency_bucket = latency_bucket(operation.started_at),
      reconciled = reconciled == true
    })
    begin_refresh(operation)
    return true
  end

  begin_refresh = function(operation)
    if not is_current(operation) then return false, "stale" end
    controller.refresh_state = "pending"
    operation.phase = "refreshing"
    local settled = false

    local function on_success(catalog)
      if settled then return end
      settled = true
      if not is_current(operation) then
        controller.stale_completions = controller.stale_completions + 1
        return
      end
      safe_call(deps.commit_catalog, catalog)
      local returned_id = trim(operation.returned_voice_id)
      if returned_id ~= "" and
         type(deps.catalog_has_id) == "function" and
         deps.catalog_has_id(catalog, returned_id) ~= true then
        controller.refresh_state = "failed"
        controller.error_code = "refresh_not_visible"
        emit("voice_library_add_refresh_failed", {
          phase = "refreshing",
          outcome = "not_visible"
        })
        return
      end
      controller.refresh_state = "succeeded"
      controller.error_code = nil
      emit("voice_library_add_refresh_completed", {
        phase = "refreshing",
        outcome = "success"
      })
    end

    local function on_error()
      if settled then return end
      settled = true
      if not is_current(operation) then
        controller.stale_completions = controller.stale_completions + 1
        return
      end
      controller.refresh_state = "failed"
      controller.error_code = "refresh_failed"
      emit("voice_library_add_refresh_failed", {
        phase = "refreshing",
        outcome = "failed"
      })
    end

    local ok_start, start_err = deps.refresh_account({
      on_success = on_success,
      on_error = on_error,
      account_generation = operation.account_generation
    })
    if ok_start == false and not settled then
      on_error(start_err)
      return false, start_err
    end
    return true
  end

  local function submit_add(operation)
    if not is_current(operation) then return false, "stale" end
    controller.state = "submitting"
    operation.phase = "submitting"
    operation.started_at = now()

    local req, request_err = deps.build_add_request(
      operation.public_owner_id,
      operation.source_voice_id,
      operation.destination_name
    )
    if not req then
      mark_recoverable(operation, "request_invalid")
      return false, request_err
    end
    req.label = tostring(deps.add_label or req.label)

    emit("voice_library_add_started", {
      phase = "submitting",
      outcome = "started"
    })

    local function on_done(result)
      if not is_current(operation) then
        release_body(result)
        controller.stale_completions = controller.stale_completions + 1
        return
      end

      local status = tonumber(result and result.http_code)
      if status == 200 and result and result.ok == true then
        local body = type(result) == "table" and result.body or nil
        local parsed = nil
        if type(body) == "string" and body ~= "" then
          parsed = deps.api.parse_add_response(body)
        end
        release_body(result)
        if parsed and trim(parsed.voice_id) ~= "" then
          mark_success(operation, parsed.voice_id, false)
        else
          mark_ambiguous(operation, "malformed_success")
        end
        return
      end

      if is_definite_http_rejection(status) then
        mark_recoverable(operation, classify_http_error(status), result)
        return
      end
      mark_ambiguous(
        operation,
        status and status >= 500 and "server_ambiguous" or "transport_ambiguous",
        result
      )
    end

    local job, submit_err = deps.submit_add(req, on_done, {
      read_body = true,
      keep_output = false,
      body_max_bytes = tonumber(deps.body_max_bytes) or (128 * 1024),
      early_secret_cleanup = true,
      retain_artifacts = false
    })
    if not job then
      mark_recoverable(operation, "request_start_failed")
      return false, submit_err
    end
    if is_current(operation) and controller.state == "submitting" then
      operation.job_id = job.id
    end
    return true
  end

  function controller:sync_selection(voice)
    local voice_id = type(voice) == "table" and trim(voice.voice_id) or ""
    if voice_id ~= self.selection_voice_id and not is_busy_state(self.state) then
      self.selection_voice_id = voice_id
      self.draft_name = type(voice) == "table" and tostring(voice.name or "") or ""
      if self.state == "duplicate_name" or self.state == "recoverable_failure" then
        self.state = "idle"
        self.outcome_code = nil
        self.error_code = nil
      end
    end
    return self.draft_name
  end

  function controller:set_draft(value)
    if self.closed or is_busy_state(self.state) then return false end
    self.draft_name = tostring(value or "")
    if self.state == "duplicate_name" or self.state == "recoverable_failure" then
      self.state = "idle"
      self.outcome_code = nil
      self.error_code = nil
    end
    return true
  end

  function controller:eligibility(voice, catalog)
    if self.closed then return false, "closed" end
    if is_busy_state(self.state) or self.refresh_state == "pending" then
      return false, "pending"
    end
    if type(voice) ~= "table" then return false, "no_selection" end
    local source_voice_id = trim(voice.voice_id)
    local public_owner_id = trim(voice.public_owner_id)
    if source_voice_id == "" or public_owner_id == "" then
      return false, "missing_identifiers"
    end
    if voice.is_added_by_user == true or self.added_overlay[source_voice_id] then
      return false, "already_added"
    end
    if voice.is_added_by_user ~= false then return false, "unknown_eligibility" end
    if self.state == "retry_ready" and self.operation and
       self.operation.source_voice_id ~= source_voice_id then
      return false, "retry_source_changed"
    end
    local destination_name = trim(self.draft_name)
    if destination_name == "" then return false, "name_required" end
    if type(deps.name_exists) == "function" and
       deps.name_exists(catalog, destination_name) == true then
      return false, "duplicate_name"
    end
    return true, "eligible"
  end

  function controller:begin_confirmation(voice, catalog)
    local eligible, reason = self:eligibility(voice, catalog)
    if not eligible then
      if reason == "already_added" then
        self.state = "already_added"
        self.outcome_code = "already_added"
      elseif reason == "duplicate_name" then
        self.state = "duplicate_name"
        self.outcome_code = "duplicate_name"
        self.error_code = "duplicate_name"
      elseif reason == "pending" then
        self.double_submit_suppressed = self.double_submit_suppressed + 1
        emit("voice_library_add_suppressed", {
          phase = self.state,
          outcome = "pending",
          double_submit = true
        })
      end
      return false, reason
    end

    self.next_token = self.next_token + 1
    local operation = {
      token = self.next_token,
      account_generation = self.account_generation,
      source_voice_id = trim(voice.voice_id),
      public_owner_id = trim(voice.public_owner_id),
      source_name = tostring(voice.name or ""),
      destination_name = trim(self.draft_name),
      phase = "confirming",
      started_at = now()
    }
    self.operation = operation
    self.state = "confirming"
    self.refresh_state = "idle"
    self.outcome_code = nil
    self.error_code = nil
    return true, operation
  end

  function controller:cancel_confirmation()
    if self.state ~= "confirming" then return false end
    self.state = "idle"
    self.operation = nil
    self.outcome_code = nil
    self.error_code = nil
    return true
  end

  function controller:confirm()
    local operation = self.operation
    if self.state ~= "confirming" or not is_current(operation) then
      self.double_submit_suppressed = self.double_submit_suppressed + 1
      emit("voice_library_add_suppressed", {
        phase = self.state,
        outcome = "not_confirmable",
        double_submit = true
      })
      return false, "not_confirmable"
    end

    self.state = "checking_name"
    operation.phase = "checking_name"
    local settled = false
    local callbacks = {
      on_duplicate = function()
        if settled then return end
        settled = true
        if not is_current(operation) then return end
        self.state = "duplicate_name"
        self.outcome_code = "duplicate_name"
        self.error_code = "duplicate_name"
        emit("voice_library_add_duplicate", {
          phase = "checking_name",
          outcome = "duplicate_name",
          duplicate = true
        })
      end,
      on_available = function()
        if settled then return end
        settled = true
        if not is_current(operation) then return end
        submit_add(operation)
      end,
      on_error = function()
        if settled then return end
        settled = true
        mark_recoverable(operation, "name_check_failed")
      end
    }
    local ok_start, start_err = deps.check_name(operation.destination_name, callbacks)
    if ok_start == false and not settled then
      callbacks.on_error(start_err)
      return false, start_err
    end
    return true
  end

  function controller:reconcile()
    local operation = self.operation
    if self.state ~= "ambiguous" or not is_current(operation) then
      return false, "not_ambiguous"
    end
    self.state = "reconciling"
    self.error_code = nil
    operation.phase = "reconciling"
    operation.reconcile_page = 0
    operation.reconcile_attempt = 1
    operation.reconcile_started_at = now()

    local submit_page
    submit_page = function()
      if not is_current(operation) or self.state ~= "reconciling" then
        return false, "stale"
      end
      local req, request_err = deps.build_reconciliation_request(
        operation.public_owner_id,
        operation.reconcile_page,
        deps.reconcile_page_size
      )
      if not req then
        self.state = "ambiguous"
        self.error_code = "reconciliation_failed"
        diagnose("reconciliation_failed", {
          outcome = "request_invalid"
        })
        return false, request_err
      end
      req.label = tostring(deps.reconcile_label or req.label)

      local function on_done(result)
        if not is_current(operation) or self.state ~= "reconciling" then
          release_body(result)
          self.stale_completions = self.stale_completions + 1
          return
        end
        if result and result.ok == true and tonumber(result.http_code) == 200 then
          local body = result.body
          local page_data = type(body) == "string" and
            deps.api.parse_list_response(body) or nil
          release_body(result)
          if page_data then
            local exact = deps.api.find_exact_voice(
              page_data,
              operation.source_voice_id
            )
            if exact then
              if exact.is_added_by_user == true then
                mark_success(operation, nil, true)
              elseif exact.is_added_by_user == false then
                self.state = "retry_ready"
                self.outcome_code = "retry_ready"
                self.error_code = nil
                emit("voice_library_add_reconciled", {
                  phase = "reconciling",
                  outcome = "not_added",
                  retry_ready = true
                })
              else
                self.state = "ambiguous"
                self.error_code = "reconciliation_inconclusive"
              end
              return
            end
            if page_data.has_more == true then
              operation.reconcile_page = operation.reconcile_page + 1
              operation.reconcile_attempt = 1
              submit_page()
              return
            end
            self.state = "ambiguous"
            self.error_code = "reconciliation_inconclusive"
            emit("voice_library_add_reconciled", {
              phase = "reconciling",
              outcome = "inconclusive"
            })
            return
          end
        end

        local retryable =
          type(deps.is_retryable) == "function" and deps.is_retryable(result) == true
        local max_attempts = math.max(1, tonumber(deps.reconcile_max_attempts) or 3)
        if retryable and operation.reconcile_attempt < max_attempts and
           type(deps.enqueue_retry) == "function" then
          operation.reconcile_attempt = operation.reconcile_attempt + 1
          release_body(result)
          deps.enqueue_retry(
            req.label,
            submit_page,
            operation.reconcile_attempt,
            max_attempts,
            tostring(deps.reconcile_retry_reason or "read_retry"),
            operation
          )
          return
        end
        release_body(result)
        self.state = "ambiguous"
        self.error_code = "reconciliation_failed"
        diagnose("reconciliation_failed", {
          outcome = "read_failed",
          http_class = http_class(result and result.http_code)
        })
        emit("voice_library_add_reconciled", {
          phase = "reconciling",
          outcome = "failed",
          http_class = http_class(result and result.http_code)
        })
      end

      operation._retry_submit = submit_page
      local job, submit_err = deps.submit_read(req, on_done, {
        read_body = true,
        keep_output = false,
        body_max_bytes = tonumber(deps.body_max_bytes) or (128 * 1024),
        retain_artifacts = false
      }, operation)
      if not job then
        self.state = "ambiguous"
        self.error_code = "reconciliation_failed"
        diagnose("reconciliation_failed", {
          outcome = "request_start_failed"
        })
        return false, submit_err
      end
      operation.reconcile_job_id = job.id
      return true
    end

    emit("voice_library_add_reconciliation_started", {
      phase = "reconciling",
      outcome = "started"
    })
    return submit_page()
  end

  function controller:refresh_account()
    local operation = self.operation
    if not is_current(operation) then return false, "stale" end
    if self.state ~= "success" and self.state ~= "success_reconciled" then
      return false, "not_successful"
    end
    if self.refresh_state == "pending" then return false, "pending" end
    return begin_refresh(operation)
  end

  function controller:account_changed(account_generation)
    local had_pending = is_busy_state(self.state) or self.refresh_state == "pending"
    self.account_generation =
      tonumber(account_generation) or (self.account_generation + 1)
    self.next_token = self.next_token + 1
    self.operation = nil
    self.state = "idle"
    self.refresh_state = "idle"
    self.outcome_code = nil
    self.error_code = nil
    self.selection_voice_id = ""
    self.draft_name = ""
    self.added_overlay = {}
    if had_pending then
      emit("voice_library_add_canceled", {
        phase = "account_changed",
        outcome = "canceled",
        cancellation = true
      })
    end
    return true
  end

  function controller:shutdown()
    if self.closed then return true end
    local had_pending = is_busy_state(self.state) or self.refresh_state == "pending"
    self.closed = true
    self.next_token = self.next_token + 1
    self.operation = nil
    self.state = "idle"
    self.refresh_state = "idle"
    self.added_overlay = {}
    if had_pending then
      emit("voice_library_add_canceled", {
        phase = "shutdown",
        outcome = "canceled",
        cancellation = true
      })
    end
    return true
  end

  function controller:view(voice, catalog)
    self:sync_selection(voice)
    local eligible, reason = self:eligibility(voice, catalog)
    local operation = self.operation
    return {
      state = self.state,
      refresh_state = self.refresh_state,
      outcome_code = self.outcome_code,
      error_code = self.error_code,
      draft_name = self.draft_name,
      eligible = eligible,
      eligibility_reason = reason,
      busy = is_busy_state(self.state) or self.refresh_state == "pending",
      confirming = self.state == "confirming",
      source_name = operation and operation.source_name or nil,
      destination_name = operation and operation.destination_name or nil,
      retry_ready = self.state == "retry_ready",
      stale_completions = self.stale_completions,
      double_submit_suppressed = self.double_submit_suppressed
    }
  end

  return controller
end

if ... == "__voice_library_controller_headless" then
  return create_voice_library_controller
end
if ... == "__voice_library_add_controller_headless" then
  return create_voice_library_add_controller
end

local r = assert(reaper, "Reaper API not found. This script must be run within Reaper.")
local SCRIPT_VERSION = "v2.1.1"
local TOOLSET_VERSION = SCRIPT_VERSION

local active_locale = "eng"
local translated_runtime_locale = "eng"
local translations_by_source_text = {}
local locale_runtime_aliases = {
  en = "eng",
  eng = "eng",
  ru = "rus",
  rus = "rus"
}

local function parse_runtime_locale(locale)
  if type(locale) ~= "string" then return nil end
  local lowered = tostring(locale):lower()
  local aliased = locale_runtime_aliases[lowered] or lowered
  if aliased == "eng" or aliased == "rus" then
    return aliased
  end
  return nil
end

local function normalize_runtime_locale(locale)
  return parse_runtime_locale(locale) or "eng"
end

local function translated_locale_available(locale)
  return translated_runtime_locale ~= "eng" and translated_runtime_locale == normalize_runtime_locale(locale)
end

local function set_active_runtime_locale(locale)
  local normalized = normalize_runtime_locale(locale)
  if normalized ~= "eng" and (not translated_locale_available(normalized)) then
    normalized = "eng"
  end
  active_locale = normalized
  return active_locale
end

local function t(text)
  if text == nil then return "" end
  if type(text) ~= "string" then return tostring(text) end
  if active_locale == "eng" then
    return text
  end
  return translations_by_source_text[text] or text
end

local function current_main_window_title_text()
  return t("ELEVENLABS") .. " " .. TOOLSET_VERSION
end

local function current_main_window_label()
  return current_main_window_title_text() .. "##elevenlabs_tool_main_window"
end

local function current_status_window_title_text()
  return t("Status") .. " " .. TOOLSET_VERSION
end

local function current_status_window_label()
  return current_status_window_title_text() .. "##elevenlabs_tool_status_window"
end

local function locale_display_name(locale)
  if normalize_runtime_locale(locale) == "rus" then
    return "Русский"
  end
  return "English"
end

-- DEPENDENCIES --
if not r.ImGui_CreateContext then
  r.MB(t("Missing dependency: ReaImGui extension.\nDownload it via Reapack ReaTeam extension repository."), t("Error"), 0)
  return false
end

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
if not script_path then
  r.MB(t("Failed to get script path!"), t("Error"), 0)
  return
end

-- Two-stage package.path loading:
-- 1) local project modules
-- 2) ReaImGui builtin module
local old_package_path = package.path
package.path = script_path .. '?.lua;' .. script_path .. '?/init.lua;' .. old_package_path

do
  local ok_languages, languages_or_err = pcall(require, "modules-neurocast.elevenlabs_tool_languages")
  if ok_languages and type(languages_or_err) == "table" then
    local module_locale = normalize_runtime_locale(languages_or_err.locale)
    local module_translations = languages_or_err.translations_by_source_text
    if module_locale ~= "eng" and type(module_translations) == "table" then
      translated_runtime_locale = module_locale
      translations_by_source_text = module_translations
    end
  end
end

local ok_json, json_or_err = pcall(require, "modules-neurocast.json")
if not ok_json then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.json: %s"), tostring(json_or_err)), t("Error"), 0)
  return
end
local json = json_or_err

local ok_util, util_or_err = pcall(require, "modules-neurocast.Util")
if not ok_util then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Util: %s"), tostring(util_or_err)), t("Error"), 0)
  return
end
local Util = util_or_err

local ok_files, files_or_err = pcall(require, "modules-neurocast.Files")
if not ok_files then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Files: %s"), tostring(files_or_err)), t("Error"), 0)
  return
end
local Files = files_or_err

local ok_voice_catalog, voice_catalog_or_err = pcall(require, "modules-neurocast.elevenlabs_voice_catalog")
if not ok_voice_catalog then
  package.path = old_package_path
  r.MB(
    string.format(t("Failed to load modules-neurocast.elevenlabs_voice_catalog: %s"), tostring(voice_catalog_or_err)),
    t("Error"),
    0
  )
  return
end
local VoiceCatalog = voice_catalog_or_err

local ok_shared_voices_api, shared_voices_api_or_err =
  pcall(require, "modules-neurocast.elevenlabs_shared_voices_api")
if not ok_shared_voices_api then
  package.path = old_package_path
  r.MB(
    string.format(
      t("Failed to load modules-neurocast.elevenlabs_shared_voices_api: %s"),
      tostring(shared_voices_api_or_err)
    ),
    t("Error"),
    0
  )
  return
end
local SharedVoicesApi = shared_voices_api_or_err

local ok_voice_library_state, voice_library_state_or_err =
  pcall(require, "modules-neurocast.elevenlabs_voice_library_state")
if not ok_voice_library_state then
  package.path = old_package_path
  r.MB(
    string.format(
      t("Failed to load modules-neurocast.elevenlabs_voice_library_state: %s"),
      tostring(voice_library_state_or_err)
    ),
    t("Error"),
    0
  )
  return
end
local VoiceLibraryState = voice_library_state_or_err

local ok_voice_library_taxonomy, voice_library_taxonomy_or_err =
  pcall(require, "modules-neurocast.elevenlabs_voice_library_taxonomy")
if not ok_voice_library_taxonomy then
  package.path = old_package_path
  r.MB(
    string.format(
      t("Failed to load modules-neurocast.elevenlabs_voice_library_taxonomy: %s"),
      tostring(voice_library_taxonomy_or_err)
    ),
    t("Error"),
    0
  )
  return
end
local VoiceLibraryTaxonomy = voice_library_taxonomy_or_err

local ok_voice_library_ui_state, voice_library_ui_state_or_err =
  pcall(require, "modules-neurocast.elevenlabs_voice_library_ui_state")
if not ok_voice_library_ui_state then
  package.path = old_package_path
  r.MB(
    string.format(
      t("Failed to load modules-neurocast.elevenlabs_voice_library_ui_state: %s"),
      tostring(voice_library_ui_state_or_err)
    ),
    t("Error"),
    0
  )
  return
end
local VoiceLibraryUiState = voice_library_ui_state_or_err

local ok_voice_preview, voice_preview_or_err =
  pcall(require, "modules-neurocast.elevenlabs_voice_preview")
if not ok_voice_preview then
  package.path = old_package_path
  r.MB(
    string.format(
      t("Failed to load modules-neurocast.elevenlabs_voice_preview: %s"),
      tostring(voice_preview_or_err)
    ),
    t("Error"),
    0
  )
  return
end
local VoicePreview = voice_preview_or_err

local ok_elevenlabs_backend, elevenlabs_backend_or_err = pcall(require, "modules-neurocast.elevenlabs_api_via_neurocast")
if not ok_elevenlabs_backend then
  package.path = old_package_path
  r.MB(
    string.format(t("Failed to load modules-neurocast.elevenlabs_api_via_neurocast: %s"), tostring(elevenlabs_backend_or_err)),
    t("Error"),
    0
  )
  return
end
local ElevenLabsViaNeurocast = elevenlabs_backend_or_err

local ok_curl, curl_or_err = pcall(require, "modules-neurocast.Curl")
if not ok_curl then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Curl: %s"), tostring(curl_or_err)), t("Error"), 0)
  return
end
local Curl = curl_or_err

local ok_auth, auth_or_err = pcall(require, "modules-neurocast.neurocast_auth")
if not ok_auth then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.neurocast_auth: %s"), tostring(auth_or_err)), t("Error"), 0)
  return
end
local NeurocastAuth = auth_or_err

local ok_jobs, jobs_or_err = pcall(require, "modules-neurocast.Jobs")
if not ok_jobs then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Jobs: %s"), tostring(jobs_or_err)), t("Error"), 0)
  return
end
local Jobs = jobs_or_err

local ok_cleanup, cleanup_or_err = pcall(require, "modules-neurocast.Cleanup")
if not ok_cleanup then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Cleanup: %s"), tostring(cleanup_or_err)), t("Error"), 0)
  return
end
local Cleanup = cleanup_or_err

local ok_prompts, prompts_or_err = pcall(require, "modules-neurocast.prompts")
if not ok_prompts then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.prompts: %s"), tostring(prompts_or_err)), t("Error"), 0)
  return
end
local prompts = prompts_or_err

local ok_telemetry, telemetry_or_err = pcall(require, "modules-neurocast.Telemetry")
if not ok_telemetry then
  package.path = old_package_path
  r.MB(string.format(t("Failed to load modules-neurocast.Telemetry: %s"), tostring(telemetry_or_err)), t("Error"), 0)
  return
end
local Telemetry = telemetry_or_err

if not Telemetry.require_identity_or_abort({
  app_name = "CirilicaTools",
  entrypoint = "elevenlabs_tool",
  script_version = SCRIPT_VERSION
}) then
  package.path = old_package_path
  return
end

local ok_telemetry_init, telemetry_init_err = Telemetry.init({
  app_name = "CirilicaTools",
  entrypoint = "elevenlabs_tool",
  script_version = SCRIPT_VERSION,
  enable_file_log = false
})
if not ok_telemetry_init then
  package.path = old_package_path
  r.MB(string.format(t("Telemetry initialization failed:\n%s"), tostring(telemetry_init_err)), t("Telemetry Error"), 0)
  return
end

-- 2nd stage:
-- load ReaImGui
package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ok_imgui, ImGuiOrErr = pcall(function()
  return require("imgui")("0.10")
end)
package.path = old_package_path
if not ok_imgui then
  r.MB(string.format(t("Failed to load ReaImGui Lua module: %s"), tostring(ImGuiOrErr)), t("Error"), 0)
  return
end
local ImGui = ImGuiOrErr

-- we will also revert package.path to old_package_path on exit:
local send_telemetry_closed_event = nil
local shutdown_voice_library_controller = nil
r.atexit(function()
  if type(shutdown_voice_library_controller) == "function" then
    shutdown_voice_library_controller()
  end
  if type(send_telemetry_closed_event) == "function" then
    send_telemetry_closed_event("atexit")
  end
  package.path = old_package_path
end)

-- END OF DEPENDENCIES --

-- ==========Namespace tables================
local UI, ReaperX, Eleven, OpenAI, Actions, Auth, Backend, TelemetryBridge = {}, {}, {}, {}, {}, {}, {}, {}
ReaperX.temp_text_track = nil
ReaperX.temp_text_item_next_position = 1

local mac = Util.mac

-- ==================INIT and first (base, low-level) functions================
-- ReaImGui init, font, content, filter creation
local ctx = ImGui.CreateContext(current_main_window_title_text())
local ctx_status = ImGui.CreateContext(current_status_window_title_text())
local filter = ImGui.CreateTextFilter('')
ImGui.Attach(ctx, filter)
local account_voice_clipper = ImGui.CreateListClipper(ctx)
ImGui.Attach(ctx, account_voice_clipper)
local font_size = 16
local FONT = ImGui.CreateFont('monospace')
ImGui.Attach(ctx, FONT)
local FONT_bold = ImGui.CreateFont('monospace', ImGui.FontFlags_Bold)
ImGui.Attach(ctx, FONT_bold)


--=================== Additional Config/State =================

-- This version depends on bin subfolder!
local curl_resolved_path = "curl" -- default fallback, will be overridden in the next code section
if mac then
  -- On mac we expect curl to be at /usr/bin/curl
  curl_resolved_path = "/usr/bin/curl"
  Util.msg("We on mac and curl path resolved to: " .. curl_resolved_path)
else
  -- we are on Windows
  curl_resolved_path = Util.path_join(script_path, [=[bin\win]=]) .. [=[\curl.exe]=]
  Util.msg("We are on windows and curl path resolved to: " .. curl_resolved_path)
  -- now we will check if curl.exe in place is working by running `curl --version` and checking the output
  local result = r.ExecProcess(curl_resolved_path .. " --version", 1500)
  --1500 milliseconds timeout, should be enough for curl to start and return version
  local target = [=[curl 8.13.0 (Windows)]=]
  if result then
    local start_pos, end_pos = result:find(target, 1, true)

    if start_pos then
      local resolved_curl_version = result:sub(start_pos, end_pos)
      Util.msg("Found matching curl version in bin: " .. resolved_curl_version)
    else
      Util.msg("Curl version check failed! Unexpected output from curl --version. Output was:\n" .. result, 3)
      Util.msg("Using mismatched version is no good, fall back to windows system curl", 3)
      curl_resolved_path = "curl"
    end
  else
    Util.msg("pinned Curl existence check in bin subfolder failed!", 3)
    Util.msg("fallback to windows system curl that is always in path", 3)
    curl_resolved_path = "curl"
  end --if result
  if curl_resolved_path == "curl" then
    local detail = result and ("Unexpected curl --version output:\n" .. tostring(result)) or "Could not run bundled curl --version."
    local bundled_curl = Util.path_join(script_path, [=[bin\win]=]) .. [=[\curl.exe]=]
    r.MB(
      string.format(
        t("Bundled curl was not found or did not match the expected version at:\n%s\n\nThe script will try Windows system curl from PATH instead.\n\nExpected: %s\n%s"),
        tostring(bundled_curl),
        target,
        detail
      ),
      t("Warning"),
      0
    )
  end
end --if mac
Util.msg("Final curl path that will be used: " .. curl_resolved_path)

local CFG = {
  base_url = "",
  backend_base_url = "https://reaper.neurocast.tech",
  backend_base_url_override = "",
  curl = curl_resolved_path,
  timeout_sec = 320,
  max_concurrent_jobs = 12,
  max_concurrent_IVC_jobs = 1,
  curl_connect_timeout_sec = 45,
  curl_speed_limit = 1,
  curl_speed_time = 120,
  polling_wait_sec = 15,
  button_cooldown_sec = 1.5,
  manual_status_check_cooldown_sec = 7.0,
  retry_max_attempts_sts = 5,
  retry_max_attempts_tts = 5,
  retry_max_attempts_openai = 5,
  retry_max_attempts_misc = 4,
  el_catalog_body_max_bytes = 16 * 1024 * 1024,
  el_voice_page_size = 100,
  el_voice_library_page_size = SharedVoicesApi.DEFAULT_PAGE_SIZE,
  el_voice_library_max_cached_pages = 8,
  el_voice_library_max_cached_rows = 800,
  retry_max_attempts_voice_design = 4,
  retry_max_attempts_ivc = 3,
  ivc_gap_threshold_sec = 5.5,
  retry_base_backoff_sec = 1.57,
  max_wait_time_for_retry = 16.57,
  retry_jitter_ratio = 0.28,
  openai_batch_timeout_sec = 600,
  openai_batch_max_request_chars = 400000,
  openai_rewrite_mode_default = "all_items",
  sts_merge_gap_sec = 3.5,
  sts_max_region_length_sec = 299,
  sts_send_each_item_separately = false,
  output_audio_path = "",
  output_audio_path_tts = "",
  output_audio_path_voice_design = "",
  vd_open_item_notes_action_id = 40850, -- Reaper action: Show notes for items...
  openai_model = "gpt-5-mini",
  openai_rewrite_prompt = prompts.openai_rewrite_prompt,
  openai_batch_rewrite_prompt = prompts.openai_batch_rewrite_prompt
}

do
  local res = r.GetResourcePath()
  CFG.reaper_resource_path = res
  CFG.tmp_dir = ""

  -- Align module logger behavior with previous script settings.
  Util.messaging_level = 3
  Util.msg_to_log_file = false
  Util.log_level_override = nil
  Util.full_path_to_log_file = nil
end

--extstate sections, keys
local extstate_sections_keys = {}
extstate_sections_keys.EXT_SECTION_for_firing_actions = "nc_dDeSm_Acr33"
extstate_sections_keys.EXT_BACKEND_AUTH_SECTION = "df3mstbs"
extstate_sections_keys.EXT_BACKEND_REFRESH_KEY = "rams2Page"
extstate_sections_keys.EXT_BACKEND_EMAIL_KEY = "brue33"
extstate_sections_keys.EXT_BACKEND_REFRESH_BASE_KEY = "er"
extstate_sections_keys.EXT_SECTION_for_UI_state = "nc_ui_state"
extstate_sections_keys.EXT_KEY_UI_Show_Status = "show_status_window"
extstate_sections_keys.EXT_KEY_UI_Locale = "ui_locale"
extstate_sections_keys.EXT_KEY_UI_Backend_Base_Override = "backend_base_url_override"
extstate_sections_keys.EXT_KEY_UI_TTS_Model = "tts_model_id"
extstate_sections_keys.EXT_KEY_UI_STS_Merge_Gap = "sts_merge_gap_sec"
extstate_sections_keys.EXT_KEY_UI_STS_Max_Region_Length = "sts_max_region_length_sec"
extstate_sections_keys.EXT_KEY_UI_STS_Send_Each_Item_Separately = "sts_send_each_item_separately"
extstate_sections_keys.EXT_KEY_UI_Voice_Library_Autoplay = "voice_library_autoplay"
extstate_sections_keys.EXT_KEY_UI_Voice_Library_Page_Size = "voice_library_page_size"

local function normalize_voice_library_page_size(value)
  return VoiceLibraryUiState.normalize_page_size(value)
end

local function load_voice_library_startup_preferences()
  local page_size, page_size_err = Util.extstate_get(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Voice_Library_Page_Size
  )
  if page_size_err then
    Util.msg("Failed to load Voice Library page size: " .. tostring(page_size_err), 2)
  end
  CFG.el_voice_library_page_size = normalize_voice_library_page_size(page_size)

  local autoplay_value, autoplay_err = Util.extstate_get(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Voice_Library_Autoplay
  )
  if autoplay_err then
    Util.msg("Failed to load Voice Library autoplay: " .. tostring(autoplay_err), 2)
  end
  local lowered = tostring(autoplay_value or ""):lower()
  return lowered == "1" or lowered == "true" or lowered == "yes"
end

local voice_library_autoplay_on_startup = load_voice_library_startup_preferences()

--STATUS
local S = {
  email = "",
  password = "",
  access_token = "",
  refresh_token = "",
  remember_login = true,
  has_stored_refresh = false,
  backend_base_url_override = "",
  el_models = nil,
  el_voices = nil,
  -- Bounded Voice Library state. Its entrypoint-owned controller is constructed
  -- below, remains network-inert at startup, and is not coupled to product UI.
  el_voice_library = VoiceLibraryState.new({
    max_cached_pages = CFG.el_voice_library_max_cached_pages,
    max_cached_rows = CFG.el_voice_library_max_cached_rows
  }),
  el_voice_library_controller = nil,
  el_voice_library_add_controller = nil,
  el_voice_library_account_generation = 0,
  el_voice_library_autoplay = voice_library_autoplay_on_startup,
  el_voice_library_preview_gain = 1.0,
  el_voice_library_active_page_size = CFG.el_voice_library_page_size,
  el_voice_library_saved_page_size = CFG.el_voice_library_page_size,
  el_voice_library_ui = VoiceLibraryUiState.new(),
  el_voice_library_was_expanded = false,
  el_account_voices_was_expanded = false,
  voice_design_was_expanded = false,
  el_voice_library_ever_opened = false,
  el_voice_library_last_committed_page = nil,
  el_voice_selected_id = "",
  el_voice_selection_cleared_by_filter = false,
  el_voice_combo_open = false,
  el_voice_filters = VoiceCatalog.empty_filters(),
  el_voice_language_search = "",
  voice_choice_by_name = {},
  voice_resolver = nil,
  voice_flow_approval = nil,
  el_tts_model_selected = "",
  el_tts_model_preferred = "",
  status_text = "",
  last_http = "",
  last_api_error = "",
  warnings = {},             -- array of strings
  checks_ran = false,
  tmp_writable = false,
  project_path = "",
  stop_polling_flag = false, -- for possible another polling approach
  next_poll_at = nil, -- for possible another polling approach
  pending_job = nil,
  curl_jobs = {},
  curl_jobs_selected_id = nil,
  cleanup_queue = {},
  retry_queue = {},
  retry_generation = 0,
  wait_until = nil,
  running_label = nil,
  ui_lock_network_buttons = false,
  show_status_window = true,
  last_check_error = "",
  last_curl_return = {
    ok          = '',
    http        = '',
    body        = '',
    headers_txt = '',
    meta        = '',
    err         = '',
    cmd         = ''
  },
  render_regions_output = t("Press the button to list render regions."),
  rendered_regions = nil,
  tts_records = nil,
  fast_sts_records = nil,
  fast_tts_records = nil,
  voice_design_records = nil,
  voice_create_records = nil,
  ivc_create_records = nil,
  ivc_ui = nil,
  ivc_batch_ui = nil,
  openai_records = nil,
  openai_rewrite_mode = CFG.openai_rewrite_mode_default or "per_item",
  openai_insert_inline = true,
  audio_tags_input = "",
  misc_records = nil,
  telemetry_ui_status = ""
}

local start_chain_state = {
  active = false,
  poll_attempt = 0,
  max_poll_attempts = 5
}

-- Resolves project-relative paths so temp/output paths follow the current project.
local function refresh_project_relative_paths()
  local project_path = Files.read_project_path() or ""
  S.project_path = project_path

  -- In Reaper, even an unsaved project still reports a project path.
  -- An empty path here means something is genuinely wrong with path discovery.
  if project_path ~= "" then
    CFG.output_audio_path = project_path
    CFG.output_audio_path_tts = project_path
    CFG.output_audio_path_voice_design = project_path
    CFG.tmp_dir = Util.path_join(project_path, "Neurocast_Tools_tmp")
  else
    CFG.output_audio_path = ""
    CFG.output_audio_path_tts = ""
    CFG.output_audio_path_voice_design = ""
    CFG.tmp_dir = ""
  end

  return CFG.tmp_dir
end

refresh_project_relative_paths()
Util.configure_diagnostics("elevenlabs_tool")

-- Initialize module stateful services.
Curl.init(S, CFG)
Jobs.init(S, CFG)

local telemetry_button_ids = {
  empty_temp_folder = true,
  render_regions_btn = true,
  reset_account_voice_filters = true,
  login_btn = true,
  refresh_login_btn = true,
  forget_login_btn = true,
  backend_override_localhost_btn = true,
  backend_override_clear_btn = true,
  fetch_el_models_btn = true,
  fetch_el_voices_btn = true,
  ivc_create_btn = true,
  ivc_batch_inspect_btn = true,
  ivc_batch_run_btn = true,
  el_voice_design_run_btn = true,
  vd_insert_previews_btn = true,
  el_tts_fast_run_btn = true,
  el_tts_run_btn = true,
  el_tts_add_results_btn = true,
  openai_rewrite_btn = true,
  audio_tags_insert_selected_notes_btn = true,
  audio_tags_remove_brackets_selected_notes_btn = true,
  el_sts_fast_run_btn = true,
  el_sts_run_btn = true,
  el_sts_add_results_btn = true,
  reset_state_btn = true,
  telemetry_flush_now_btn = true,
  telemetry_resume_btn = true,
  telemetry_copy_paths_btn = true
}

local telemetry_button_prefixes = {
  "retry_",
  "cancel_",
  "vd_create_voice_btn_",
  "vd_create_voice_now_btn_",
  "vd_create_voice_cancel_btn_"
}

local function telemetry_should_track_button(id)
  local key = tostring(id or "")
  if telemetry_button_ids[key] then return true end
  for _, prefix in ipairs(telemetry_button_prefixes) do
    if key:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

function TelemetryBridge.now()
  return type(r.time_precise) == "function" and r.time_precise() or os.clock()
end

function TelemetryBridge.duration_ms(started_at)
  local started = tonumber(started_at)
  if not started then return nil end
  local elapsed = TelemetryBridge.now() - started
  if elapsed < 0 then elapsed = 0 end
  return math.floor((elapsed * 1000) + 0.5)
end

function TelemetryBridge.safe_string(value, limit)
  local text = tostring(value or "")
  text = TelemetryBridge.redact_secret_values(text)
  if type(Util.clip_text) == "function" then
    return Util.clip_text(text, tonumber(limit) or 2048)
  end
  return text:sub(1, tonumber(limit) or 2048)
end

local function telemetry_pattern_escape(value)
  return tostring(value or ""):gsub("([^%w])", "%%%1")
end

function TelemetryBridge.redact_secret_values(value)
  local text = tostring(value or "")
  local secrets = {
    S.password,
    S.access_token,
    S.refresh_token
  }
  for _, secret in ipairs(secrets) do
    local secret_txt = tostring(secret or "")
    if #secret_txt >= 8 then
      text = text:gsub(telemetry_pattern_escape(secret_txt), "[REDACTED_SECRET]")
    end
  end
  text = text:gsub("Authorization:%s*Bearer%s+[%w%p]+", "Authorization: Bearer [REDACTED_SECRET]")
  text = text:gsub("authorization:%s*Bearer%s+[%w%p]+", "authorization: Bearer [REDACTED_SECRET]")
  return text
end

function TelemetryBridge.content_allowed()
  local ok_level, level = pcall(Telemetry.effective_level)
  if not ok_level then return false end
  return level == "support" or level == "debug"
end

function TelemetryBridge.sanitize_value(value, depth)
  local d = tonumber(depth) or 0
  if d > 6 then return "[truncated]" end
  local value_type = type(value)
  if value_type == "string" then
    return TelemetryBridge.safe_string(value)
  end
  if value_type == "number" or value_type == "boolean" or value == nil then
    return value
  end
  if value_type ~= "table" then
    return TelemetryBridge.safe_string(value)
  end

  local out = {}
  local count = 0
  for k, v in pairs(value) do
    count = count + 1
    if count > 80 then
      out._truncated = true
      break
    end
    local key = TelemetryBridge.safe_string(k, 160)
    out[key] = TelemetryBridge.sanitize_value(v, d + 1)
  end
  return out
end

function TelemetryBridge.try_encode_json(value, limit)
  local ok_encoded, encoded = pcall(json.encode, value)
  if not ok_encoded then
    return TelemetryBridge.safe_string(encoded, limit)
  end
  return TelemetryBridge.safe_string(encoded, limit)
end

function TelemetryBridge.base_payload(data)
  local out = {
    app_area = "elevenlabs",
    project_path = tostring(S.project_path or ""),
    temp_dir = tostring(CFG.tmp_dir or ""),
    sts_output_dir = tostring(CFG.output_audio_path or ""),
    tts_output_dir = tostring(CFG.output_audio_path_tts or ""),
    voice_design_output_dir = tostring(CFG.output_audio_path_voice_design or ""),
    backend_base_url = Backend.active_base_url and Backend.active_base_url() or tostring(CFG.backend_base_url or ""),
    has_studio_access_token = S.access_token ~= "",
    has_stored_login = S.has_stored_refresh == true,
    voices_count = tonumber(S.el_voices and S.el_voices.count) or nil,
    models_count = tonumber(S.el_models and S.el_models.count) or nil,
    retry_generation = tonumber(S.retry_generation) or 0
  }
  if type(data) == "table" then
    for k, v in pairs(data) do
      out[k] = v
    end
  end
  return TelemetryBridge.sanitize_value(out)
end

function TelemetryBridge.safe_event(event_name, data, opts)
  local ok_event, event_or_err = Telemetry.safe_event(event_name, TelemetryBridge.base_payload(data), opts or {})
  if ok_event then
    return true, event_or_err
  end
  S.telemetry_ui_status = string.format(t("Telemetry event failed: %s"), tostring(event_or_err))
  Util.msg(S.telemetry_ui_status, 2)
  return false, event_or_err
end

function TelemetryBridge.emit_operation_event(event_name, operation, status, data, opts)
  local payload = TelemetryBridge.base_payload(data)
  payload.operation = tostring(operation or "")
  payload.status = tostring(status or "")

  local event_opts = {}
  if type(opts) == "table" then
    for k, v in pairs(opts) do
      event_opts[k] = v
    end
  end
  event_opts.operation = payload.operation
  event_opts.status = payload.status
  event_opts.request_label = payload.request_label
  event_opts.http_code = payload.http_code
  event_opts.curl_exitcode = payload.curl_exitcode
  event_opts.duration_ms = payload.duration_ms
  event_opts.error_code = payload.error_code

  return TelemetryBridge.safe_event(event_name, payload, event_opts)
end

function TelemetryBridge.operation_started(operation, data)
  return TelemetryBridge.emit_operation_event("operation_started", operation, "started", data, {
    priority = "normal"
  })
end

function TelemetryBridge.operation_completed(operation, data, started_at)
  local payload = data or {}
  if started_at and payload.duration_ms == nil then
    payload.duration_ms = TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event("operation_completed", operation, "completed", payload, {
    priority = "normal"
  })
end

function TelemetryBridge.operation_failed(operation, data, started_at, event_name)
  local payload = data or {}
  if started_at and payload.duration_ms == nil then
    payload.duration_ms = TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event(event_name or "operation_failed", operation, "failed", payload, {
    priority = "error",
    event_level = "error"
  })
end

function TelemetryBridge.operation_canceled(operation, data, started_at)
  local payload = data or {}
  if started_at and payload.duration_ms == nil then
    payload.duration_ms = TelemetryBridge.duration_ms(started_at)
  end
  return TelemetryBridge.emit_operation_event("operation_canceled", operation, "canceled", payload, {
    priority = "normal"
  })
end

function TelemetryBridge.put_content(payload, key, value)
  if not TelemetryBridge.content_allowed() then return false end
  if value == nil then return false end
  local text = TelemetryBridge.safe_string(value)
  if text == "" then return false end
  payload[key] = text
  return true
end

function TelemetryBridge.extract_endpoint_path(url)
  local text = tostring(url or "")
  local path = text:match("^https?://[^/]+(/.*)$") or text
  path = path:gsub("%?.*$", "")
  return TelemetryBridge.safe_string(path, 512)
end

function TelemetryBridge.extract_output_format(url)
  local text = tostring(url or "")
  local format = text:match("[?&]output_format=([^&]+)")
  return format and TelemetryBridge.safe_string(format, 128) or nil
end

function TelemetryBridge.request_endpoint_fields(req)
  if type(req) ~= "table" then return {} end
  return {
    request_method = tostring(req.method or ""),
    request_kind = tostring(req.kind or ""),
    request_label = tostring(req.label or ""),
    endpoint_path = TelemetryBridge.extract_endpoint_path(req.url),
    output_format = TelemetryBridge.extract_output_format(req.url)
  }
end

function TelemetryBridge.request_payload_fields(req)
  local payload = {}
  if type(req) ~= "table" then return payload end
  local body = req.json_payload_tbl
  if type(body) == "table" then
    payload.model_id = body.model_id or body.model
    payload.voice_name = body.voice_name or body.name
    payload.generated_voice_id = body.generated_voice_id
    TelemetryBridge.put_content(payload, "request_text", body.text)
    TelemetryBridge.put_content(payload, "request_input", body.input)
    TelemetryBridge.put_content(payload, "request_instructions", body.instructions)
    TelemetryBridge.put_content(payload, "request_voice_description", body.voice_description or body.description)
    TelemetryBridge.put_content(payload, "request_payload_json", TelemetryBridge.try_encode_json(body, 2048))
  end
  if type(req.form_fields) == "table" then
    local fields = {}
    for _, field in ipairs(req.form_fields) do
      if type(field) == "table" then
        local row = {
          name = tostring(field.name or "")
        }
        if field.filepath then
          row.filepath = tostring(field.filepath or "")
          row.file_size = Files.file_size(field.filepath)
        elseif field.value ~= nil then
          local field_name = tostring(field.name or "")
          if field_name == "model_id" or field_name == "remove_background_noise" then
            row.value = tostring(field.value)
          elseif TelemetryBridge.content_allowed() then
            row.value = TelemetryBridge.safe_string(field.value)
          else
            row.value_present = true
          end
        end
        fields[#fields + 1] = row
        if tostring(field.name or "") == "model_id" then payload.model_id = field.value end
      end
    end
    payload.form_field_count = #fields
    payload.form_fields = fields
  end
  return payload
end

function TelemetryBridge.operation_from_kind(req, ctx_info, rec)
  if type(ctx_info) == "table" and ctx_info.operation and ctx_info.operation ~= "" then
    return tostring(ctx_info.operation)
  end
  local kind = tostring(req and req.kind or "")
  if kind == "el_models" then return "elevenlabs_fetch_models" end
  if kind == "el_voices" then return "elevenlabs_fetch_voices" end
  if kind == "el_shared_voices" then return "elevenlabs_voice_library" end
  if kind == "el_reconcile_shared_voice" then return "elevenlabs_voice_library_reconcile" end
  if kind == "el_add_shared_voice" then return "elevenlabs_voice_library_add" end
  if kind == "el_voice_preview" then return "elevenlabs_voice_preview" end
  if kind == "el_account_voice_preview" then return "elevenlabs_account_voice_preview" end
  if kind == "el_shared_voice_preview" then return "elevenlabs_voice_library_preview" end
  if kind == "el_voice_create" then return "elevenlabs_voice_create" end
  if kind == "el_ivc_create" then return "elevenlabs_ivc_create" end
  if kind == "el_voice_design" then return "elevenlabs_voice_design" end
  if kind == "el_sts" then return "elevenlabs_sts" end
  if kind == "el_tts" then return "elevenlabs_tts" end
  if kind == "openai_rewrite" then return "elevenlabs_openai_rewrite" end
  local flow = tostring(rec and rec.flow_label or "")
  if flow ~= "" then
    return "elevenlabs_" .. flow:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  end
  return "elevenlabs_request"
end

function TelemetryBridge.record_payload(rec, req, result, job, ctx_info, response_body)
  local payload = TelemetryBridge.request_endpoint_fields(req)
  local request_payload = TelemetryBridge.request_payload_fields(req)
  for k, v in pairs(request_payload) do
    payload[k] = v
  end

  payload.flow_label = tostring((ctx_info and ctx_info.flow_label) or (rec and rec.flow_label) or "")
  payload.record_name = tostring(rec and rec.record_name or rec and rec.region_name or rec and rec.item_label or "")
  payload.record_state = tostring(rec and rec._state or "")
  payload.attempt = rec and rec._attempt or nil
  payload.max_attempts = rec and rec._max_attempts or nil
  payload.job_id = tostring(job and job.id or "")
  payload.http_code = result and result.http_code or rec and rec._last_http_code or nil
  payload.curl_exitcode = result and result.exitcode or rec and rec._last_exitcode or nil
  payload.timed_out = result and result.timed_out == true
  payload.total_time = result and result.total_time or nil
  payload.size_upload = result and result.size_upload or nil
  payload.size_download = result and result.size_download or nil
  payload.safe_message = TelemetryBridge.safe_string(
    (result and (result.err or result.err_msg or result.err_txt)) or
    (rec and rec._last_error_summary) or
    ""
  )
  payload.error_code = tostring((req and req.kind) or (rec and rec._misc_key) or "ELEVENLABS_OPERATION"):upper()
  payload.input_path = tostring(rec and rec.input_path or "")
  payload.output_path = tostring(rec and rec.output_path or (job and job.out_path) or "")
  payload.input_size = rec and rec.input_path and Files.file_size(rec.input_path) or nil
  payload.output_size = rec and rec.output_path and Files.file_size(rec.output_path) or (job and job.out_path and Files.file_size(job.out_path) or nil)
  payload.track_name = tostring(rec and rec.track_name or "")
  payload.track_number = rec and rec.track_number or rec and rec.track_position or nil
  payload.region_name = tostring(rec and rec.region_name or "")
  payload.item_position = rec and rec.item_position or rec and rec.track_position or nil
  payload.voice_id = tostring((ctx_info and ctx_info.voice_id) or (rec and rec.voice_id) or "")
  payload.voice_name = tostring((ctx_info and ctx_info.voice_name) or (rec and rec.voice_name) or payload.voice_name or "")
  payload.model_id = tostring((ctx_info and ctx_info.model_id) or payload.model_id or "")
  payload.generated_voice_id = tostring((ctx_info and ctx_info.generated_voice_id) or (rec and rec.generated_voice_id) or payload.generated_voice_id or "")
  payload.preview_index = rec and rec.preview_index or nil

  TelemetryBridge.put_content(payload, "record_text", rec and rec.text)
  TelemetryBridge.put_content(payload, "input_payload_text", rec and rec.input_payload_text)
  TelemetryBridge.put_content(payload, "voice_description", rec and rec.voice_description)
  TelemetryBridge.put_content(payload, "preview_text", (rec and rec.preview_text) or (S.voice_design_records and S.voice_design_records.preview_text))
  TelemetryBridge.put_content(payload, "openai_output_text", rec and rec.openai_output_text)
  TelemetryBridge.put_content(payload, "last_error_snippet", rec and rec._last_error_snippet)
  TelemetryBridge.put_content(payload, "response_body_snippet", response_body or (result and result.body))

  if type(ctx_info) == "table" and type(ctx_info.extra_payload) == "table" then
    for k, v in pairs(ctx_info.extra_payload) do
      payload[k] = v
    end
  end
  return payload
end

function TelemetryBridge.begin_record(rec, operation, payload)
  if type(rec) ~= "table" then return end
  if rec._telemetry_started_at and rec._telemetry_completed_current ~= true then
    return
  end
  rec._telemetry_started_at = TelemetryBridge.now()
  rec._telemetry_completed_current = false
  rec._telemetry_operation = tostring(operation or "elevenlabs_request")
  TelemetryBridge.operation_started(rec._telemetry_operation, payload or {})
end

function TelemetryBridge.finish_record_ok(rec, payload)
  if type(rec) ~= "table" or rec._telemetry_completed_current == true then return end
  rec._telemetry_completed_current = true
  local event_payload = payload or {}
  event_payload.duration_ms = event_payload.duration_ms or TelemetryBridge.duration_ms(rec._telemetry_started_at)
  TelemetryBridge.operation_completed(rec._telemetry_operation or "elevenlabs_request", event_payload)
end

function TelemetryBridge.finish_record_failed(rec, payload, event_name)
  if type(rec) ~= "table" or rec._telemetry_completed_current == true then return end
  rec._telemetry_completed_current = true
  local event_payload = payload or {}
  event_payload.duration_ms = event_payload.duration_ms or TelemetryBridge.duration_ms(rec._telemetry_started_at)
  TelemetryBridge.operation_failed(rec._telemetry_operation or "elevenlabs_request", event_payload, nil, event_name or "operation_failed")
end

function TelemetryBridge.finish_record_canceled(rec, payload)
  if type(rec) ~= "table" or rec._telemetry_completed_current == true then return end
  rec._telemetry_completed_current = true
  local event_payload = payload or {}
  event_payload.duration_ms = event_payload.duration_ms or TelemetryBridge.duration_ms(rec._telemetry_started_at)
  TelemetryBridge.operation_canceled(rec._telemetry_operation or "elevenlabs_request", event_payload)
end

function TelemetryBridge.network_request_failed(req, result, job, ctx_info, response_body)
  local payload = TelemetryBridge.record_payload(ctx_info and ctx_info.rec, req, result, job, ctx_info, response_body)
  payload.operation = "elevenlabs_network_request"
  payload.status = "failed"
  payload.safe_message = payload.safe_message ~= "" and payload.safe_message or t("curl request failed")
  TelemetryBridge.emit_operation_event("network_request_failed", "elevenlabs_network_request", "failed", payload, {
    priority = "error",
    event_level = "error",
    request_label = payload.request_label,
    http_code = payload.http_code,
    curl_exitcode = payload.curl_exitcode
  })
end

function TelemetryBridge.submit_curl(req, on_done, opts, ctx_info)
  local info = ctx_info or {}
  local rec = info.rec
  local operation = TelemetryBridge.operation_from_kind(req, info, rec)
  local start_payload = TelemetryBridge.record_payload(rec, req, nil, nil, info, nil)
  local record_started = false
  local function begin_record_once()
    if record_started then return end
    record_started = true
    TelemetryBridge.begin_record(rec, operation, start_payload)
  end

  local function finish_response(result, job)
    local body_before = result and result.body or nil
    if type(on_done) == "function" then
      on_done(result, job)
    end

    local body_after = body_before or (result and result.body) or nil
    if TelemetryBridge.content_allowed() and (not body_after or body_after == "") and info.capture_response_body and job and job.out_path then
      local data = Files.slurp_with_cap(job.out_path, 2048)
      if data and data ~= "" then
        body_after = data
      end
    end

    local payload = TelemetryBridge.record_payload(rec, req, result, job, info, body_after)
    if result and result.ok ~= true then
      TelemetryBridge.network_request_failed(req, result, job, info, body_after)
    end

    if type(rec) == "table" then
      if rec._state == "ok" then
        TelemetryBridge.finish_record_ok(rec, payload)
      elseif rec._state == "failed_final" then
        TelemetryBridge.finish_record_failed(rec, payload, "operation_failed")
      elseif rec._state == "canceled" then
        TelemetryBridge.finish_record_canceled(rec, payload)
      end
    end
  end

  local function wrapped_on_done(result, job)
    local can_refresh =
      type(rec) == "table" and
      type(rec._retry_submit) == "function" and
      req and req.backend_auth == "studio" and
      info.allow_refresh_401 ~= false and
      tonumber(result and result.http_code or 0) == 401 and
      rec._auth_refresh_used_once ~= true

    if can_refresh then
      rec._state = "refreshing"
      rec._next_retry_at = nil
      Curl.update_last_curl_state(result, job, req.label or t("Studio request"))
      local response_body = result and result.body or nil
      TelemetryBridge.network_request_failed(req, result, job, info, response_body)

      local handled, refresh_err = Auth.refresh_after_401(
        rec,
        rec._retry_submit,
        function(message, refresh_payload)
          finish_response({
            ok = false,
            err = tostring(message or t("Studio login refresh failed.")),
            http_code = tonumber(refresh_payload and refresh_payload.http_code) or
              tonumber(result and result.http_code) or 401,
            body = ""
          }, job)
        end
      )
      if handled then return end
      result.err = tostring(refresh_err or result.err or t("Studio login refresh could not be started."))
    end

    finish_response(result, job)
  end

  local can_refresh_proactively =
    type(rec) == "table" and
    type(rec._retry_submit) == "function" and
    req and req.backend_auth == "studio" and
    info.allow_refresh_401 ~= false
  if can_refresh_proactively then
    local handled, timing_err = Auth.refresh_proactively_if_due(
      rec,
      rec._retry_submit,
      function(message, refresh_payload)
        begin_record_once()
        local failed_job = {
          id = "studio_auth_failed_" .. tostring(rec._telemetry_record_id or rec.record_name or rec),
          label = req.label or t("Studio request"),
          out_path = req.download_path,
          phase = "completed"
        }
        finish_response({
          ok = false,
          err = tostring(message or t("Studio login refresh failed.")),
          http_code = tonumber(refresh_payload and refresh_payload.http_code),
          body = ""
        }, failed_job)
      end
    )
    if handled then
      return {
        id = "studio_auth_wait_" .. tostring(rec._telemetry_record_id or rec.record_name or rec),
        phase = "auth_wait",
        keep_in_list = true
      }, nil
    end
    if timing_err then
      Util.msg(
        "Studio access-token timing unavailable; keeping 401 fallback: " .. tostring(timing_err),
        1
      )
    end
  end

  begin_record_once()
  local job, err = Curl.curl_submit(req, wrapped_on_done, opts)
  if not job then
    local result = {
      ok = false,
      err = tostring(err or ""),
      exitcode = nil,
      http_code = nil
    }
    local payload = TelemetryBridge.record_payload(rec, req, result, nil, info, nil)
    TelemetryBridge.network_request_failed(req, result, nil, info, nil)
    if type(rec) == "table" then
      TelemetryBridge.finish_record_failed(rec, payload, "operation_failed")
    else
      TelemetryBridge.operation_failed(operation, payload)
    end
  end
  return job, err
end

function TelemetryBridge.button_clicked(button_id, label)
  return TelemetryBridge.safe_event("button_clicked", {
    operation = "elevenlabs_ui",
    status = "clicked",
    button_id = tostring(button_id or ""),
    button_label = tostring(label or "")
  }, {
    operation = "elevenlabs_ui",
    status = "clicked",
    priority = "low"
  })
end

function TelemetryBridge.progress_text(desc)
  local progress = tostring(desc and desc.progress_line or "")
  if progress == "" and desc and desc.active_job_phase and desc.active_job_phase ~= "" then
    progress = tostring(desc.active_job_phase)
  end
  if progress == "" then progress = "-" end
  return progress
end

function TelemetryBridge.level_label(level)
  local normalized = tostring(level or "")
  if normalized == "basic" then return t("Basic") end
  if normalized == "support" then return t("Support") end
  if normalized == "debug" then return t("Debug") end
  return normalized
end

function TelemetryBridge.describe_status()
  local ok_desc, desc_or_err = pcall(Telemetry.describe_status)
  if ok_desc and type(desc_or_err) == "table" then
    return desc_or_err
  end
  return {
    initialized = false,
    status = t("telemetry status unavailable"),
    last_error = tostring(desc_or_err or ""),
    progress_line = "",
    active_job_phase = ""
  }
end

function TelemetryBridge.header_state(desc)
  if not desc or desc.initialized ~= true then
    return t("unavailable")
  end
  if desc.send_paused then
    return t("paused, see details")
  end
  if desc.active_job_id ~= nil then
    local progress = TelemetryBridge.progress_text(desc)
    if progress ~= "-" then
      return string.format(t("flushing, %s"), Util.clip_text(progress, 32))
    end
    return t("flushing")
  end
  if Util.trim(desc.last_error or "") ~= "" or Util.trim(desc.last_backend_error or "") ~= "" then
    return t("fail, see details inside")
  end
  local pending_bytes = (tonumber(desc.sendable_queue_bytes) or 0) + (tonumber(desc.current_queue_bytes) or 0)
  local pending_files =
    (tonumber(desc.queued_file_count) or 0) +
    (tonumber(desc.sending_file_count) or 0)
  if pending_bytes > 0 or pending_files > 0 then
    return t("queued")
  end
  return t("idle")
end

function TelemetryBridge.status_ok(desc)
  if not desc or desc.initialized ~= true then return false end
  if desc.send_paused then return false end
  if Util.trim(desc.last_error or "") ~= "" or Util.trim(desc.last_backend_error or "") ~= "" then
    return false
  end
  return true
end

function TelemetryBridge.status_color(desc)
  if TelemetryBridge.status_ok(desc) then
    return 0x00C853FF
  end
  return 0xD50000FF
end

function TelemetryBridge.safe_tick(now_t)
  local ok_tick, tick_or_err = Telemetry.safe_tick(now_t)
  if ok_tick == false and tick_or_err ~= nil then
    S.telemetry_ui_status = string.format(t("Telemetry tick failed: %s"), tostring(tick_or_err))
  end
  return ok_tick, tick_or_err
end

function TelemetryBridge.safe_flush_async(reason)
  local ok_flush, flush_or_err = Telemetry.safe_flush_async({
    reason = reason or "elevenlabs_manual",
    timeout_sec = 60,
    connect_timeout_sec = 15,
    speed_limit = 1,
    speed_time = 30
  })
  if ok_flush then
    S.telemetry_ui_status = t("Telemetry flush started.")
  else
    S.telemetry_ui_status = tostring(flush_or_err or "")
  end
  return ok_flush, flush_or_err
end

function TelemetryBridge.script_started()
  TelemetryBridge.safe_event("script_started", {
    operation = "script_lifecycle",
    status = "started"
  }, {
    operation = "script_lifecycle",
    status = "started"
  })
end

function TelemetryBridge.send_closed_event(reason)
  if TelemetryBridge.closed_event_sent == true then return end
  TelemetryBridge.closed_event_sent = true
  TelemetryBridge.safe_event("script_closed", {
    operation = "script_lifecycle",
    status = "closed",
    close_reason = tostring(reason or "")
  }, {
    operation = "script_lifecycle",
    status = "closed"
  })

  local ok_call, ok_close, close_or_err = pcall(Telemetry.flush_current_queue_fire_and_forget, {
    curl_path = CFG.curl,
    timeout_sec = 20,
    connect_timeout_sec = 10,
    speed_limit = 1,
    speed_time = 15
  })
  if ok_call and ok_close then
    S.telemetry_ui_status = t("Telemetry close-send launched.")
  else
    local err = ok_call and close_or_err or ok_close
    S.telemetry_ui_status = string.format(t("Telemetry close-send failed: %s"), tostring(err))
    Util.msg(S.telemetry_ui_status, 2)
  end
end

send_telemetry_closed_event = TelemetryBridge.send_closed_event

--==================== Voice Library controller ===================

local voice_library_progress_records = {}
local voice_library_progress_order = {}
local VOICE_LIBRARY_PROGRESS_RECORD_LIMIT = 24

local function ensure_voice_library_progress_record(request_id, page)
  if not request_id then return nil end
  local rec = voice_library_progress_records[request_id]
  if rec then return rec end
  rec = {
    _misc_key = "el_voice_library_" .. tostring(request_id),
    record_name = string.format("Voice Library page %s", tostring(page or "?")),
    flow_label = "Voice Library",
    misc_start_time_override = "-",
    _state = "running"
  }
  voice_library_progress_records[request_id] = rec
  voice_library_progress_order[#voice_library_progress_order + 1] = request_id
  if type(S.misc_records) ~= "table" then S.misc_records = {} end
  S.misc_records[#S.misc_records + 1] = rec
  while #voice_library_progress_order > VOICE_LIBRARY_PROGRESS_RECORD_LIMIT do
    local expired_id = table.remove(voice_library_progress_order, 1)
    local expired = voice_library_progress_records[expired_id]
    voice_library_progress_records[expired_id] = nil
    if expired then
      for index = #S.misc_records, 1, -1 do
        if S.misc_records[index] == expired then
          table.remove(S.misc_records, index)
          break
        end
      end
    end
  end
  return rec
end

local function on_voice_library_progress(event_name, snapshot)
  local rec = ensure_voice_library_progress_record(snapshot.request_id, snapshot.page)
  if not rec then return end
  rec._attempt = snapshot.attempt
  rec._max_attempts = snapshot.max_attempts
  rec.misc_job_id = snapshot.job_id or rec.misc_job_id
  rec._last_error_summary = snapshot.error
  rec._state = snapshot.state or event_name
  if event_name == "retry_wait" then
    rec._state = "retry_wait"
  elseif event_name == "ok" then
    rec._state = "ok"
    rec._next_retry_at = nil
  elseif event_name == "failed" then
    rec._state = "failed_final"
    rec._next_retry_at = nil
  elseif event_name == "canceled" or event_name == "stale" then
    rec._state = "canceled"
    rec._next_retry_at = nil
  end
end

local function sanitize_voice_library_error(value)
  local text = TelemetryBridge.safe_string(value, 512)
  text = text:gsub("https?://[^%s\"']+", "[URL]")
  return text
end

-- Curl intentionally logs a query-stripped request URL at debug level. Public
-- preview paths and add-shared-voice path identifiers are sensitive support
-- data, so suppress only the synchronous debug-level preparation message while
-- retaining warnings, errors, progress, and completion logging.
local function submit_without_preparation_log(submitter)
  return function(req, on_done, opts, rec)
    local old_messaging_level = Util.messaging_level
    local old_log_level_override = Util.log_level_override
    Util.messaging_level = math.max(1, tonumber(old_messaging_level) or 0)
    Util.log_level_override = math.max(
      1,
      tonumber(old_log_level_override) or tonumber(old_messaging_level) or 0
    )
    local ok, job_or_err, submit_err = pcall(submitter, req, on_done, opts, rec)
    Util.messaging_level = old_messaging_level
    Util.log_level_override = old_log_level_override
    if not ok then return nil, tostring(job_or_err) end
    return job_or_err, submit_err
  end
end

local submit_sensitive_mutation_without_log = submit_without_preparation_log(
  function(req, on_done, opts)
    return Curl.curl_submit(req, on_done, opts)
  end
)

local submit_sensitive_studio_get_without_log = submit_without_preparation_log(
  function(req, on_done, opts, rec)
    return TelemetryBridge.submit_curl(req, on_done, opts, {
      rec = rec,
      operation = TelemetryBridge.operation_from_kind(req, nil, rec),
      allow_refresh_401 = true
    })
  end
)

local voice_library_preview = VoicePreview.new({
  submit = submit_sensitive_studio_get_without_log,
  build_download_request = function(spec)
    if tostring(spec and spec.owner or "") == "account_voices" then
      return Backend.client():account_voice_preview_request(
        spec.voice_id,
        spec.language,
        spec.accent,
        spec.download_path,
        spec.label,
        spec.timeout_sec
      )
    end
    if tostring(spec and spec.owner or "") == "voice_library" then
      return Backend.client():shared_voice_preview_request(
        spec.public_owner_id,
        spec.voice_id,
        spec.language,
        spec.accent,
        spec.download_path,
        spec.label,
        spec.timeout_sec
      )
    end
    return nil, "Remote preview source is unsupported"
  end,
  files = Files,
  util = Util,
  cache_dir_fn = function()
    refresh_project_relative_paths()
    if not CFG.tmp_dir or CFG.tmp_dir == "" then return "" end
    return Util.path_join(CFG.tmp_dir, "voice_library_previews")
  end,
  file_exists = r.file_exists,
  enqueue_cleanup = Cleanup.enqueue_cleanup,
  play_file = r.cyr_essentials_Preview_PlayFile,
  stop_file = r.cyr_essentials_Preview_Stop,
  summarize_error = function(result)
    return sanitize_voice_library_error(Eleven.summarize_el_error(result))
  end,
  update_last_curl_state = Curl.update_last_curl_state,
  update_retry_state = Jobs.update_record_retry_state,
  is_retryable = Jobs.is_retryable_result,
  enqueue_retry = Jobs.enqueue_retry,
  format_attempt_label = Jobs.format_attempt_label,
  max_attempts = CFG.retry_max_attempts_misc,
  timeout_sec = 300,
  on_event = function(event_name, payload)
    local allowed = {
      cache_hit = true,
      download_started = true,
      download_completed = true,
      failed = true,
      canceled = true,
      started = true,
      stopped = true,
      orphans_queued = true
    }
    if not allowed[event_name] then return end
    local owner = tostring(payload and payload.owner or "voice_library")
    local operation_by_owner = {
      voice_library = "elevenlabs_voice_library_preview",
      account_voices = "elevenlabs_account_voice_preview",
      voice_design = "elevenlabs_voice_design_preview_playback"
    }
    local operation = operation_by_owner[owner] or "elevenlabs_voice_preview"
    local event_prefix_by_owner = {
      voice_library = "voice_library_preview_",
      account_voices = "account_voice_preview_",
      voice_design = "voice_design_preview_playback_"
    }
    local event_prefix = event_prefix_by_owner[owner] or "voice_preview_"
    TelemetryBridge.safe_event(event_prefix .. event_name, {
      operation = operation,
      source = operation_by_owner[owner] and owner or "unknown",
      status = event_name,
      attempt = tonumber(payload and payload.attempt) or nil,
      cache_hit = payload and payload.cache_hit == true or nil,
      audio_format =
        payload and (payload.format == "wav" or payload.format == "mp3") and
        payload.format or nil,
      orphan_count = tonumber(payload and payload.count) or nil
    }, {
      operation = operation,
      status = event_name
    })
  end
})

S.el_voice_library_controller = create_voice_library_controller({
  api = SharedVoicesApi,
  state = S.el_voice_library,
  preview = voice_library_preview,
  stop_preview_owner = function(owner)
    local status = voice_library_preview:status()
    if status.owner == tostring(owner or "") then
      return voice_library_preview:stop()
    end
    return false
  end,
  build_list_request = function(query, page, page_size)
    return Backend.client():shared_voices_request(
      query,
      page,
      page_size,
      string.format("Fetch Voice Library page %d", tonumber(page) or 0),
      120
    )
  end,
  submit = function(req, on_done, opts, rec)
    return TelemetryBridge.submit_curl(req, on_done, opts, {
      rec = rec,
      operation = "elevenlabs_voice_library",
      allow_refresh_401 = true
    })
  end,
  enqueue_retry = Jobs.enqueue_retry,
  is_retryable = Jobs.is_retryable_result,
  update_retry_state = Jobs.update_record_retry_state,
  update_transport_state = Curl.update_last_curl_state,
  format_attempt_label = Jobs.format_attempt_label,
  page_size = CFG.el_voice_library_page_size,
  max_attempts = CFG.retry_max_attempts_misc,
  body_max_bytes = CFG.el_catalog_body_max_bytes,
  now = r.time_precise,
  sanitize_error = function(value)
    return sanitize_voice_library_error(value)
  end,
  release_response_body = function(result)
    if result then result.body = nil end
    if type(S.last_curl_return) == "table" then S.last_curl_return.body = "" end
  end,
  on_progress = on_voice_library_progress,
  diagnostic = function(level, _message, payload)
    Util.msg(
      string.format(
        "Voice Library request failed: page=%s attempts=%s",
        tostring(payload and payload.page or "?"),
        tostring(payload and payload.attempt_count or "?")
      ),
      tonumber(level) or 2
    )
  end,
  emit_telemetry = function(event_name, payload)
    local safe_payload = {
      operation = "elevenlabs_voice_library",
      status = tostring(event_name or "event"),
      page = tonumber(payload and payload.page) or nil,
      row_count = tonumber(payload and payload.row_count) or nil,
      duplicate_count = tonumber(payload and payload.duplicate_count) or nil,
      attempt = tonumber(payload and payload.attempt) or nil,
      attempt_count = tonumber(payload and payload.attempt_count) or nil,
      max_attempts = tonumber(payload and payload.max_attempts) or nil,
      count = tonumber(payload and payload.count) or nil,
      filter_count = tonumber(payload and payload.filter_count) or nil,
      has_more = payload and payload.has_more == true or nil,
      ok = payload and payload.ok == true or nil,
      reason = payload and tostring(payload.reason or ""):sub(1, 64) or nil
    }
    TelemetryBridge.safe_event(event_name, safe_payload, {
      operation = "elevenlabs_voice_library",
      status = safe_payload.status
    })
  end
})

S.el_voice_library_add_controller = create_voice_library_add_controller({
  api = SharedVoicesApi,
  build_add_request = function(public_owner_id, voice_id, new_name)
    return Backend.client():add_shared_voice_request(
      public_owner_id,
      voice_id,
      new_name,
      t("Add shared voice"),
      120
    )
  end,
  build_reconciliation_request = function(public_owner_id, page, page_size)
    local query, normalize_err = SharedVoicesApi.normalize_query({
      owner_id = public_owner_id
    })
    if not query then return nil, normalize_err end
    local req, request_err = Backend.client():shared_voices_request(
      query,
      page,
      page_size,
      t("Verify shared voice status"),
      120
    )
    if req then req.kind = "el_reconcile_shared_voice" end
    return req, request_err
  end,
  -- The add mutation is intentionally never auto-resubmitted. A transport or
  -- 5xx ambiguity must reconcile through a fresh shared-voice read first.
  submit_add = submit_sensitive_mutation_without_log,
  submit_read = submit_sensitive_studio_get_without_log,
  check_name = function(name, callbacks)
    local safe_callbacks = {}
    for key, value in pairs(callbacks or {}) do safe_callbacks[key] = value end
    safe_callbacks.aggregate_only = true
    return Eleven.check_voice_name_available(name, safe_callbacks)
  end,
  name_exists = function(catalog, name)
    return VoiceCatalog.name_exists_exact(catalog, name)
  end,
  refresh_account = function(callbacks)
    callbacks = callbacks or {}
    return Eleven.fetch_el_voices({
      commit = false,
      purpose = "voice_library_add_refresh",
      aggregate_only = true,
      on_success = callbacks.on_success,
      on_error = callbacks.on_error
    })
  end,
  commit_catalog = function(catalog)
    return Eleven.commit_el_voice_catalog(catalog)
  end,
  catalog_has_id = function(catalog, voice_id)
    return
      type(catalog) == "table" and
      type(catalog.by_id) == "table" and
      catalog.by_id[tostring(voice_id or "")] ~= nil
  end,
  enqueue_retry = Jobs.enqueue_retry,
  is_retryable = Jobs.is_retryable_result,
  reconcile_max_attempts = CFG.retry_max_attempts_misc,
  reconcile_page_size = SharedVoicesApi.MAX_PAGE_SIZE,
  add_label = t("Add shared voice"),
  reconcile_label = t("Verify shared voice status"),
  reconcile_retry_reason = t("Read request retry"),
  body_max_bytes = 128 * 1024,
  now = r.time_precise,
  release_response_body = function(result)
    if result then result.body = nil end
    if type(S.last_curl_return) == "table" then
      S.last_curl_return.body = ""
      S.last_curl_return.headers_txt = ""
      S.last_curl_return.meta = ""
    end
  end,
  diagnostic = function(event_name, payload)
    Util.msg(
      string.format(
        "Voice Library add: event=%s outcome=%s http=%s canceled=%s",
        tostring(event_name or "event"),
        tostring(payload and payload.outcome or "none"),
        tostring(payload and payload.http_class or "none"),
        tostring(payload and payload.cancellation == true)
      ),
      2
    )
  end,
  emit_telemetry = function(event_name, payload)
    local safe_payload = {
      operation = "elevenlabs_voice_library_add",
      status = tostring(event_name or "event"):sub(1, 64),
      phase = payload and payload.phase or nil,
      outcome = payload and payload.outcome or nil,
      http_class = payload and payload.http_class or nil,
      latency_bucket = payload and payload.latency_bucket or nil,
      cancellation = payload and payload.cancellation == true or nil,
      duplicate = payload and payload.duplicate == true or nil,
      reconciled = payload and payload.reconciled == true or nil,
      retry_ready = payload and payload.retry_ready == true or nil,
      stale = payload and payload.stale == true or nil,
      double_submit = payload and payload.double_submit == true or nil
    }
    TelemetryBridge.safe_event(event_name, safe_payload, {
      operation = "elevenlabs_voice_library_add",
      status = safe_payload.status
    })
  end
})
S.el_voice_library_add_controller:account_changed(
  S.el_voice_library_account_generation
)

shutdown_voice_library_controller = function()
  if S.el_voice_library_add_controller then
    S.el_voice_library_add_controller:shutdown()
  end
  if S.el_voice_library_controller then
    S.el_voice_library_controller:shutdown()
  end
end

function Eleven.open_voice_library(filters)
  return S.el_voice_library_controller:open(
    filters or {},
    S.el_voice_library_account_generation
  )
end

function Eleven.set_voice_library_filters(filters)
  return S.el_voice_library_controller:set_filters(filters or {})
end

function Eleven.request_voice_library_page(page)
  return S.el_voice_library_controller:start_page(page)
end

function Eleven.retry_voice_library_page()
  return S.el_voice_library_controller:retry_failed_page()
end

function Eleven.voice_library_view()
  return S.el_voice_library_controller:view()
end

function Eleven.voice_library_preview_policy(voice)
  return S.el_voice_library_controller:preview_policy(voice)
end

function Eleven.cancel_voice_library_requests(reason)
  return S.el_voice_library_controller:cancel_pending(reason)
end

function Eleven.navigate_voice_library_page(page)
  return S.el_voice_library_controller:navigate(page)
end

function Eleven.request_voice_library_preview(voice, callbacks, opts)
  return S.el_voice_library_controller:request_preview(voice, callbacks, opts)
end

function Eleven.voice_preview_status()
  return voice_library_preview:status()
end

function Eleven.stop_voice_preview(owner)
  local status = voice_library_preview:status()
  if owner and status.owner ~= tostring(owner) then
    return false, "preview owner does not match"
  end
  return voice_library_preview:stop()
end

function Eleven.request_account_voice_preview(voice, callbacks, opts)
  opts = opts or {}
  opts.owner = "account_voices"
  opts.preview_id = tostring(type(voice) == "table" and voice.id or "")
  return voice_library_preview:request(voice, callbacks, opts)
end

function Eleven.play_voice_design_preview(rec, callbacks, opts)
  opts = opts or {}
  opts.owner = "voice_design"
  local preview_id = tostring(
    type(rec) == "table" and
    (rec.record_name or rec.generated_voice_id or rec.output_path) or ""
  )
  return voice_library_preview:play_local({
    preview_id = preview_id,
    voice_id = preview_id,
    name = type(rec) == "table" and rec.record_name or preview_id,
    path = type(rec) == "table" and rec.output_path or ""
  }, callbacks, opts)
end

function Eleven.voice_library_add_view(voice)
  return S.el_voice_library_add_controller:view(voice, S.el_voices)
end

function Eleven.set_voice_library_add_name(name)
  return S.el_voice_library_add_controller:set_draft(name)
end

function Eleven.begin_voice_library_add_confirmation(voice)
  return S.el_voice_library_add_controller:begin_confirmation(
    voice,
    S.el_voices
  )
end

function Eleven.cancel_voice_library_add_confirmation()
  return S.el_voice_library_add_controller:cancel_confirmation()
end

function Eleven.confirm_voice_library_add()
  return S.el_voice_library_add_controller:confirm()
end

function Eleven.reconcile_voice_library_add()
  return S.el_voice_library_add_controller:reconcile()
end

function Eleven.refresh_voices_after_library_add()
  return S.el_voice_library_add_controller:refresh_account()
end

function Eleven.notify_voice_library_account_changed()
  Eleven.stop_voice_preview("account_voices")
  Eleven.stop_voice_preview("voice_library")
  S.el_voice_library_account_generation = S.el_voice_library_account_generation + 1
  S.el_voice_filters = VoiceCatalog.empty_filters()
  S.el_voice_language_search = ""
  S.el_voice_selected_id = ""
  S.el_voice_selection_cleared_by_filter = false
  ImGui.TextFilter_Clear(filter)
  if S.el_voice_library_add_controller then
    S.el_voice_library_add_controller:account_changed(
      S.el_voice_library_account_generation
    )
  end
  if S.el_voice_library_ui then
    S.el_voice_library_ui:invalidate_catalog()
  end
  S.el_voice_library_local_error = nil
  S.el_voice_library_last_committed_page = nil
  if S.el_voice_library_controller.initialized then
    return S.el_voice_library_controller:account_changed(
      S.el_voice_library_account_generation
    )
  end
  return true
end

--==================== More Low-level utils ===================

function UI.persist_show_status_window(value)
  if value == nil then return end
  local encoded = value and "1" or "0"
  local ok_set, err = Util.extstate_set_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Show_Status,
    encoded,
    true
  )
  if not ok_set then
    Util.msg("Failed to persist status window state: " .. tostring(err), 2)
  end
end --function UI.persist_show_status_window(value)

function UI.persist_locale(locale)
  local normalized = parse_runtime_locale(locale)
  if not normalized then
    UI.forget_locale()
    return
  end
  local ok_set, err = Util.extstate_set_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Locale,
    normalized,
    true
  )
  if not ok_set then
    Util.msg("Failed to persist UI locale: " .. tostring(err), 2)
  end
end --function UI.persist_locale(locale)

function UI.persist_tts_model_preference(model_id)
  local value = tostring(model_id or "")
  if value == "" then return end
  local ok_set, err = Util.extstate_set(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_TTS_Model,
    value,
    true
  )
  if not ok_set then
    Util.msg("Failed to persist TTS model preference: " .. tostring(err), 2)
  end
end --function UI.persist_tts_model_preference(model_id)

function UI.persist_voice_library_autoplay(value)
  local ok_set, err = Util.extstate_set(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Voice_Library_Autoplay,
    value and "1" or "0",
    true
  )
  if not ok_set then
    Util.msg("Failed to persist Voice Library autoplay: " .. tostring(err), 2)
  end
end

function UI.persist_voice_library_page_size(value)
  local normalized = normalize_voice_library_page_size(value)
  local ok_set, err = Util.extstate_set(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Voice_Library_Page_Size,
    tostring(normalized),
    true
  )
  if not ok_set then
    Util.msg("Failed to persist Voice Library page size: " .. tostring(err), 2)
    return false
  end
  S.el_voice_library_saved_page_size = normalized
  return true
end

function UI.forget_show_status_window()
  local _, err = Util.extstate_delete(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Show_Status,
    true
  )
  if err then Util.msg("Failed to forget status window state: " .. tostring(err), 2) end
end --function UI.forget_show_status_window()

function UI.forget_locale()
  local _, err = Util.extstate_delete(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Locale,
    true
  )
  if err then Util.msg("Failed to forget UI locale: " .. tostring(err), 2) end
end --function UI.forget_locale()

function UI.forget_tts_model_preference()
  local _, err = Util.extstate_delete(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_TTS_Model,
    true
  )
  if err then Util.msg("Failed to forget TTS model preference: " .. tostring(err), 2) end
end --function UI.forget_tts_model_preference()

function Auth.persist_email(value)
  local email = Util.trim(value or "")
  if email == "" then return end
  local ok_set, err = Util.extstate_set_camo(
    extstate_sections_keys.EXT_BACKEND_AUTH_SECTION,
    extstate_sections_keys.EXT_BACKEND_EMAIL_KEY,
    email,
    true
  )
  if not ok_set then
    Util.msg("Failed to persist Studio login email: " .. tostring(err), 2)
  end
end --function Auth.persist_email(value)

function Auth.load_email_from_ext_state()
  local email, err = Util.extstate_get_camo(
    extstate_sections_keys.EXT_BACKEND_AUTH_SECTION,
    extstate_sections_keys.EXT_BACKEND_EMAIL_KEY
  )
  if err then
    Util.msg("Failed to load Studio login email: " .. tostring(err), 2)
    return nil
  end
  email = Util.trim(email or "")
  if email == "" then return nil end
  return email
end --function Auth.load_email_from_ext_state()

function Auth.forget_email()
  local _, err = Util.extstate_delete(
    extstate_sections_keys.EXT_BACKEND_AUTH_SECTION,
    extstate_sections_keys.EXT_BACKEND_EMAIL_KEY,
    true
  )
  if err then Util.msg("Failed to forget Studio login email: " .. tostring(err), 2) end
end --function Auth.forget_email()

function Auth.persist_refresh_backend_base()
  local ok_set, err = Util.extstate_set_camo(
    extstate_sections_keys.EXT_BACKEND_AUTH_SECTION,
    extstate_sections_keys.EXT_BACKEND_REFRESH_BASE_KEY,
    Backend.active_base_url(),
    true
  )
  if not ok_set then
    Util.msg("Failed to persist Studio refresh backend: " .. tostring(err), 2)
  end
end --function Auth.persist_refresh_backend_base()

function Auth.load_refresh_backend_base()
  local value, err = Util.extstate_get_camo(
    extstate_sections_keys.EXT_BACKEND_AUTH_SECTION,
    extstate_sections_keys.EXT_BACKEND_REFRESH_BASE_KEY
  )
  if err then
    Util.msg("Failed to load Studio refresh backend: " .. tostring(err), 2)
    return nil
  end
  value = Util.trim(value or "")
  if value == "" then return nil end
  return value
end --function Auth.load_refresh_backend_base()

function Auth.forget_refresh_backend_base()
  local _, err = Util.extstate_delete(
    extstate_sections_keys.EXT_BACKEND_AUTH_SECTION,
    extstate_sections_keys.EXT_BACKEND_REFRESH_BASE_KEY,
    true
  )
  if err then Util.msg("Failed to forget Studio refresh backend: " .. tostring(err), 2) end
end --function Auth.forget_refresh_backend_base()

function UI.persist_backend_base_url_override(value)
  local override = Util.trim(value or "")
  local ok_set, err = Util.extstate_set(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Backend_Base_Override,
    override,
    true
  )
  if not ok_set then
    Util.msg("Failed to persist backend override: " .. tostring(err), 2)
  end
end --function UI.persist_backend_base_url_override(value)

function UI.load_backend_base_url_override_from_ext_state()
  local value, err = Util.extstate_get(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Backend_Base_Override
  )
  if err then
    Util.msg("Failed to load backend override from extstate: " .. tostring(err), 2)
    return nil
  end
  return Util.trim(value or "")
end --function UI.load_backend_base_url_override_from_ext_state()

function UI.forget_backend_base_url_override()
  local _, err = Util.extstate_delete(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Backend_Base_Override,
    true
  )
  if err then Util.msg("Failed to clear backend override: " .. tostring(err), 2) end
end --function UI.forget_backend_base_url_override()

local AUTH_CLIENT = nil
local AUTH_CLIENT_BASE_URL = nil
local ELEVENLABS_BACKEND_CLIENT = nil
local ELEVENLABS_BACKEND_BASE_URL = nil
local AUTH_REFRESH_GATE = NeurocastAuth.create_refresh_gate()

function Backend.active_base_url()
  local override = Util.trim(S.backend_base_url_override or CFG.backend_base_url_override or "")
  if override ~= "" then
    return ElevenLabsViaNeurocast.resolve_base_url(override)
  end
  return ElevenLabsViaNeurocast.resolve_base_url(CFG.backend_base_url)
end --function Backend.active_base_url()

function Backend.reset_clients()
  AUTH_CLIENT = nil
  AUTH_CLIENT_BASE_URL = nil
  ELEVENLABS_BACKEND_CLIENT = nil
  ELEVENLABS_BACKEND_BASE_URL = nil
end --function Backend.reset_clients()

function Backend.client()
  local base_url = Backend.active_base_url()
  if not ELEVENLABS_BACKEND_CLIENT or ELEVENLABS_BACKEND_BASE_URL ~= base_url then
    ELEVENLABS_BACKEND_CLIENT = ElevenLabsViaNeurocast.create_client({
      base_url = base_url,
      access_token_fn = function()
        return S.access_token or ""
      end
    })
    ELEVENLABS_BACKEND_BASE_URL = base_url
  end
  return ELEVENLABS_BACKEND_CLIENT
end --function Backend.client()

function Backend.request_build_failed(rec, err_txt)
  local err = tostring(err_txt or Auth.login_required_message())
  if type(rec) == "table" then
    rec._state = "failed_final"
    rec._next_retry_at = nil
    rec._last_error_summary = err
  end
  S.status_text = err
  S.last_api_error = err
  return false, err
end --function Backend.request_build_failed(rec, err_txt)

function Auth.client()
  local base_url = Backend.active_base_url()
  if not AUTH_CLIENT or AUTH_CLIENT_BASE_URL ~= base_url then
    AUTH_CLIENT = NeurocastAuth.create_client({
      base_url = base_url,
      ext_section = extstate_sections_keys.EXT_BACKEND_AUTH_SECTION,
      ext_refresh_key = extstate_sections_keys.EXT_BACKEND_REFRESH_KEY,
      remember_refresh = S.remember_login == true
    })
    AUTH_CLIENT_BASE_URL = base_url
  end
  AUTH_CLIENT.set_tokens(S.access_token or "", S.refresh_token or "")
  return AUTH_CLIENT
end --function Auth.client()

function Auth.has_access_token()
  return Util.trim(S.access_token or "") ~= ""
end --function Auth.has_access_token()

function Auth.login_required_message()
  if S.has_stored_refresh then
    return t("Studio Neurocast login needs refresh. Click Refresh stored login in Settings.")
  end
  return t("Studio Neurocast login is required. Log in in Settings.")
end --function Auth.login_required_message()

function Auth.ensure_access_token()
  if Auth.has_access_token() then return true, nil end
  return false, Auth.login_required_message()
end --function Auth.ensure_access_token()

function Auth.apply_token_payload(payload)
  S.access_token = tostring(payload and payload.access_token or "")
  S.refresh_token = tostring(payload and payload.refresh_token or "")
  if S.remember_login and S.refresh_token ~= "" then
    S.has_stored_refresh = true
  elseif not S.remember_login then
    S.has_stored_refresh = false
  end
  local client = Auth.client()
  client.set_tokens(S.access_token, S.refresh_token)
end --function Auth.apply_token_payload(payload)

function Auth.clear_runtime_tokens()
  S.access_token = ""
  S.refresh_token = ""
  S.password = ""
  if AUTH_CLIENT then
    AUTH_CLIENT.clear_runtime_tokens()
  end
end --function Auth.clear_runtime_tokens()

function UI.load_show_status_window_from_ext_state()
  local value, err = Util.extstate_get_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Show_Status
  )
  if err then
    Util.msg("Failed to load status window state from extstate: " .. tostring(err), 2)
    return nil
  end
  if value == nil then return nil end

  value = tostring(value or "")
  if value == "" then
    UI.forget_show_status_window()
    return nil
  end

  local lowered = value:lower()
  if lowered == "1" or lowered == "true" or lowered == "yes" then return true end
  if lowered == "0" or lowered == "false" or lowered == "no" then return false end
  return nil
end --function UI.load_show_status_window_from_ext_state()

function UI.load_locale_from_ext_state()
  local value, err = Util.extstate_get_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_Locale
  )
  if err then
    Util.msg("Failed to load UI locale from extstate: " .. tostring(err), 2)
    return nil
  end
  if value == nil then return nil end

  value = tostring(value or "")
  if value == "" then
    UI.forget_locale()
    return nil
  end

  local normalized = parse_runtime_locale(value)
  if not normalized then
    UI.forget_locale()
    return nil
  end
  if normalized ~= "eng" and (not translated_locale_available(normalized)) then
    return "eng"
  end
  return normalized
end --function UI.load_locale_from_ext_state()

function UI.load_tts_model_preference_from_ext_state()
  local value, err = Util.extstate_get(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_TTS_Model
  )
  if err then
    Util.msg("Failed to load TTS model preference from extstate: " .. tostring(err), 2)
    return nil
  end
  if value == nil then return nil end

  value = tostring(value or "")
  if value == "" then
    UI.forget_tts_model_preference()
    return nil
  end
  return value
end --function UI.load_tts_model_preference_from_ext_state()

local function parse_bool_extstate_value(value)
  local lowered = tostring(value or ""):lower()
  if lowered == "1" or lowered == "true" or lowered == "yes" then return true end
  if lowered == "0" or lowered == "false" or lowered == "no" then return false end
  return nil
end

local function normalize_sts_max_region_length_sec(value)
  local num = tonumber(value)
  if not num then
    return 299
  end
  num = math.floor(num + 0.5)
  if num < 1 then num = 1 end
  if num > 299 then num = 299 end
  return num
end

local function fmt_minutes_seconds(value)
  local total = tonumber(value) or 0
  total = math.floor(total + 0.5)
  if total < 0 then total = 0 end
  local minutes = math.floor(total / 60)
  local seconds = total % 60
  return string.format("%d:%02d", minutes, seconds)
end

function UI.persist_sts_merge_gap_sec(value)
  local num = tonumber(value)
  if not num then return end
  if num < 0 then num = 0 end
  local ok_set, err = Util.extstate_set_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_STS_Merge_Gap,
    tostring(num),
    true
  )
  if not ok_set then
    Util.msg("Failed to persist STS merge gap: " .. tostring(err), 2)
  end
end --function UI.persist_sts_merge_gap_sec(value)

function UI.persist_sts_max_region_length_sec(value)
  local num = normalize_sts_max_region_length_sec(value)
  local ok_set, err = Util.extstate_set_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_STS_Max_Region_Length,
    tostring(num),
    true
  )
  if not ok_set then
    Util.msg("Failed to persist STS max region length: " .. tostring(err), 2)
  end
end --function UI.persist_sts_max_region_length_sec(value)

function UI.persist_sts_send_each_item_separately(value)
  local encoded = value and "1" or "0"
  local ok_set, err = Util.extstate_set_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_STS_Send_Each_Item_Separately,
    encoded,
    true
  )
  if not ok_set then
    Util.msg("Failed to persist STS per-item mode: " .. tostring(err), 2)
  end
end --function UI.persist_sts_send_each_item_separately(value)

function UI.load_sts_merge_gap_sec_from_ext_state()
  local value, err = Util.extstate_get_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_STS_Merge_Gap
  )
  if err then
    Util.msg("Failed to load STS merge gap from extstate: " .. tostring(err), 2)
    return nil
  end
  if value == nil then return nil end
  local num = tonumber(value)
  if not num then return nil end
  if num < 0 then num = 0 end
  return num
end --function UI.load_sts_merge_gap_sec_from_ext_state()

function UI.load_sts_max_region_length_sec_from_ext_state()
  local value, err = Util.extstate_get_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_STS_Max_Region_Length
  )
  if err then
    Util.msg("Failed to load STS max region length from extstate: " .. tostring(err), 2)
    return nil
  end
  if value == nil then return nil end
  return normalize_sts_max_region_length_sec(value)
end --function UI.load_sts_max_region_length_sec_from_ext_state()

function UI.load_sts_send_each_item_separately_from_ext_state()
  local value, err = Util.extstate_get_camo(
    extstate_sections_keys.EXT_SECTION_for_UI_state,
    extstate_sections_keys.EXT_KEY_UI_STS_Send_Each_Item_Separately
  )
  if err then
    Util.msg("Failed to load STS per-item mode from extstate: " .. tostring(err), 2)
    return nil
  end
  if value == nil then return nil end
  return parse_bool_extstate_value(value)
end --function UI.load_sts_send_each_item_separately_from_ext_state()

function Files.ensure_output_dir()
  S.project_path = Files.read_project_path()
  if not S.project_path or S.project_path == "" then
    return false, t("Project path not available. Save the project before running speech-to-speech.")
  end
  CFG.output_audio_path = S.project_path
  r.RecursiveCreateDirectory(CFG.output_audio_path, 0)
  local test_path = Util.path_join(CFG.output_audio_path, "._write_test.tmp")
  local ok, err = Files.write_file(test_path, "test")
  if not ok then
    return false, string.format(t("Cannot write to output folder: %s"), tostring(err or t("unknown IO error")))
  end
  local remove_ok, remove_err = os.remove(test_path)
  if not remove_ok then
    Util.msg('Cannot delete test file from output folder! Not secure!', 3, 'box')
    return false, string.format(t("SECURITY risk!! Cannot delete from output folder: %s"), tostring(remove_err or t("unknown IO error")))
  end
  return true
end

-- Ensures text-to-speech output directory so later steps do not fail.
-- Called by `run_el_text_to_speech_for_selected_items`; caller passes no arguments and uses shared state.
function Files.ensure_tts_output_dir()
  S.project_path = Files.read_project_path()
  if not S.project_path or S.project_path == "" then
    return false, t("Project path not available. Save the project before running text-to-speech.")
  end
  CFG.output_audio_path_tts = S.project_path
  r.RecursiveCreateDirectory(CFG.output_audio_path_tts, 0)
  local test_path = Util.path_join(CFG.output_audio_path_tts, "._write_test.tmp")
  local ok, err = Files.write_file(test_path, "test")
  if not ok then
    return false, string.format(t("Cannot write to output folder: %s"), tostring(err or t("unknown IO error")))
  end
  local remove_ok, remove_err = os.remove(test_path)
  if not remove_ok then
    Util.msg('Cannot delete test file from output folder! Not secure!', 3, 'box')
    return false, string.format(t("SECURITY risk!! Cannot delete from output folder: %s"), tostring(remove_err or t("unknown IO error")))
  end
  return true
end

-- Ensures voice design output directory so later steps do not fail.
-- Called by `run_el_voice_design`; caller passes no arguments and uses shared state.
function Files.ensure_voice_design_output_dir()
  S.project_path = Files.read_project_path()
  if not S.project_path or S.project_path == "" then
    return false, t("Project path not available. Save the project before running voice design.")
  end
  CFG.output_audio_path_voice_design = S.project_path
  r.RecursiveCreateDirectory(CFG.output_audio_path_voice_design, 0)
  local test_path = Util.path_join(CFG.output_audio_path_voice_design, "._write_test.tmp")
  local ok, err = Files.write_file(test_path, "test")
  if not ok then
    return false, string.format(t("Cannot write to output folder: %s"), tostring(err or t("unknown IO error")))
  end
  local remove_ok, remove_err = os.remove(test_path)
  if not remove_ok then
    Util.msg('Cannot delete test file from output folder! Not secure!', 3, 'box')
    return false, string.format(t("SECURITY risk!! Cannot delete from output folder: %s"), tostring(remove_err or t("unknown IO error")))
  end
  return true
end

-- Handles rebuild warnings so other code can call it.
-- Called during startup and by `GuiLoop`; caller passes no arguments and uses shared state.
-- Important: run this at startup so warnings are ready.
function UI.rebuild_warnings()
  if type(S.warnings) ~= "table" then
    S.warnings = {}
  end
  local function add_check_warning(msg)
    local txt = tostring(msg or "")
    if txt == "" then return end
    table.insert(S.warnings, txt)
  end

  S.last_check_error = ""
  -- Project path & tmp dir checks
  refresh_project_relative_paths()

  -- Keep this warning branch because an empty path should be rare in Reaper.
  if S.project_path == "" then
    add_check_warning(t("Project path not available (unsaved project?). Some features may be limited."))
  else
    if Util.has_non_ascii(S.project_path) then
      add_check_warning(t("Project path contains non-ASCII characters. This can cause trouble for external tools on Windows."))
    end
    if Util.has_quoting_risk(S.project_path) then
      add_check_warning(t("Project path contains characters that require careful quoting (quotes or newlines)."))
    end
  end

  -- Temp dir create + write test
  local ok, err = Files.ensure_tmp_dir(CFG.tmp_dir)
  S.tmp_writable = ok
  if not ok then
    S.last_check_error = err or t("Unknown error ensuring temp directory.")
    add_check_warning(t("Temp directory is NOT writable. See error below."))
    add_check_warning(S.last_check_error)
  else
    -- Keep warning on path characteristics even though tmp dir is now project-relative.
    if Util.has_non_ascii(CFG.tmp_dir) then
      add_check_warning(t("Temp directory path contains non-ASCII characters. May affect external tool behavior on Windows."))
    end
    if Util.has_quoting_risk(CFG.tmp_dir) then
      add_check_warning(t("Temp directory path contains quotes/newlines and will be carefully quoted later."))
    end
  end

  S.checks_ran = true
end --function UI.rebuild_warnings()
-- !! Run startup checks to ensure temp dir exists and is writable.
UI.rebuild_warnings()

do --WORK WITH REAPER PROJ
  local function fmt_time_for_region(value)
    local v = tonumber(value) or 0
    if v < 0 then v = 0 end
    return r.format_timestr_pos(v, "", 5)
  end

  local function get_sts_region_settings()
    local merge_gap = tonumber(CFG.sts_merge_gap_sec)
    if not merge_gap then merge_gap = 3.5 end
    if merge_gap < 0 then merge_gap = 0 end

    local max_region_length = normalize_sts_max_region_length_sec(CFG.sts_max_region_length_sec)

    return {
      merge_gap_sec = merge_gap,
      max_region_length_sec = max_region_length,
      send_each_item_separately = CFG.sts_send_each_item_separately == true
    }
  end

  local function track_label_for_region(track)
    local _, track_name = r.GetTrackName(track)
    local track_idx = tonumber(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) or 0
    if track_name and track_name ~= "" then
      return tostring(track_name), track_name, track_idx
    end
    local fallback = string.format(t("Track %s"), string.format("%.0f", track_idx))
    return fallback, "", track_idx
  end

  local function describe_sts_skipped_region(skipped)
    if type(skipped) ~= "table" then
      return t("Skipped STS region.")
    end
    local label = track_label_for_region(skipped.track)
    local region = skipped.region or {}
    local start_pos = tonumber(region[1]) or 0
    local end_pos = tonumber(region[2]) or 0
    local duration = tonumber(skipped.duration_sec)
    if not duration then duration = end_pos - start_pos end
    if duration < 0 then duration = 0 end
    local max_len = tonumber(skipped.max_region_length_sec) or 0
    return string.format(
      t("Skipped STS region on %s: %s - %s (dur: %s) exceeds Max region length (sec) = %.2f."),
      tostring(label),
      fmt_time_for_region(start_pos),
      fmt_time_for_region(end_pos),
      fmt_time_for_region(duration),
      max_len
    )
  end

  function ReaperX.push_sts_skipped_region_warnings(skipped_regions)
    if type(skipped_regions) ~= "table" then return 0 end
    local pushed = 0
    for _, skipped in ipairs(skipped_regions) do
      local msg = describe_sts_skipped_region(skipped)
      table.insert(S.warnings, msg)
      S.status_text = msg
      pushed = pushed + 1
    end
    if pushed > 0 then
      S.last_api_error = ""
    end
    return pushed
  end --function ReaperX.push_sts_skipped_region_warnings(skipped_regions)

  -- Gets track items regions so later steps can use it.
  -- Called by `ReaperX.get_render_regions_by_track`; caller passes `items_table` and `opts`.
  local function get_track_items_regions(items_table, opts)
    if #items_table < 1 then
      return
        false,
        'No items in items_table!'
    end --if
    -- we construct this table so it is always has at least one item, but I keep that check here

    local gap = tonumber(opts and opts.merge_gap_sec)
    if not gap then gap = 3.5 end
    if gap < 0 then gap = 0 end
    local send_each_item_separately = opts and opts.send_each_item_separately == true

    local sorted = true
    local last_pos = r.GetMediaItemInfo_Value(items_table[1], "D_POSITION")

    -- We'll store positions in a cache in case we need to sort later
    local pos_cache = {[items_table[1]] = last_pos}
    local first_item_tail = last_pos + r.GetMediaItemInfo_Value(items_table[1], "D_LENGTH")
    local tails_cache = {[items_table[1]] = first_item_tail}
    for i = 2, #items_table do
        local item = items_table[i]
        local current_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local current_length = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        pos_cache[item] = current_pos
        tails_cache[item] = current_pos + current_length

        if current_pos < last_pos then
            sorted = false
            -- We can't stop the loop here because we need to fill
            -- the cache for the remaining items for the fastest sort and later usage.
        end --if
        last_pos = current_pos
    end --for

    if not sorted then
        table.sort(
          items_table,
          function(a, b)
            return pos_cache[a] < pos_cache[b]
          end
        )
    end --if not sorted

    local regions = {}
    if send_each_item_separately then
      for i = 1, #items_table do
        local item = items_table[i]
        table.insert(regions, {pos_cache[item], tails_cache[item]})
      end
      return
        true,
        regions
    end

    --now we can build regions
    local first_item = items_table[1]
    local current_region_start = pos_cache[first_item]
    local current_region_end = tails_cache[first_item]

    for i=2, #items_table do
        local item = items_table[i]
        local item_start = pos_cache[item]
        local item_end = tails_cache[item]

        --If the current item starts AFTER the current region ends + gap
        if item_start > (current_region_end + gap) then
            -- We have a gap larger than maximum_pause, so we finalize the current region
            table.insert(regions, {current_region_start, current_region_end})
            -- Start a new region
            current_region_start = item_start
            current_region_end = item_end
        else
            -- The current item is within the gap, so we extend the current region
            if item_end > current_region_end then
                current_region_end = item_end
            end --if
        end --if
    end --for

    -- Insert the last region
    table.insert(regions, {current_region_start, current_region_end})

    return
      true,
      regions

  end --get_track_items_regions(items_table)

  local function collect_selected_items_by_track()
    local number_of_selected_items = r.CountSelectedMediaItems(0)
    if number_of_selected_items < 1 then
      return false, t('No selected items in project! Please select items to process.'), nil
    end

    local items_by_track = {}
    for i = 0, (number_of_selected_items - 1) do
      local current_item = r.GetSelectedMediaItem(0, i)
      local track = r.GetMediaItemTrack(current_item)
      if not items_by_track[track] then
        items_by_track[track] = {}
      end
      table.insert(items_by_track[track], current_item)
    end

    return true, "ok", items_by_track
  end --function collect_selected_items_by_track()

  local function build_sts_regions_by_track(items_by_track)
    if not items_by_track or not next(items_by_track) then
      return false, t("No selected items grouped by track."), nil
    end

    local settings = get_sts_region_settings()
    local regions_by_track = {}
    local skipped_regions = {}

    for track, items_table in pairs(items_by_track) do
      Util.msg('Now inspecting items on track...')

      local ok, err_or_regions = get_track_items_regions(items_table, settings)
      if not ok then
        return false, string.format(t('While calling get_track_items_regions(items_table) we got error: %s'), tostring(err_or_regions)), nil
      end

      local accepted_regions = {}
      for _, region in ipairs(err_or_regions) do
        local region_start = tonumber(region[1]) or 0
        local region_end = tonumber(region[2]) or 0
        local duration = region_end - region_start
        if duration < 0 then duration = 0 end
        if settings.max_region_length_sec > 0 and duration > settings.max_region_length_sec then
          table.insert(skipped_regions, {
            track = track,
            region = { region_start, region_end },
            duration_sec = duration,
            max_region_length_sec = settings.max_region_length_sec
          })
        else
          table.insert(accepted_regions, { region_start, region_end })
        end
      end

      if #accepted_regions > 0 then
        regions_by_track[track] = accepted_regions
      end
      Util.msg('Items on track inspected successfully, found '..tostring(#accepted_regions)..' renderable regions.')
    end

    return true, "ok", {
      regions_by_track = regions_by_track,
      skipped_regions = skipped_regions,
      settings = settings
    }
  end --function build_sts_regions_by_track(items_by_track)

  -- Collects one candidate region per selected track for future IVC inspection.
  -- Called by `ReaperX.get_regions_by_track_for_IVC`; caller passes no arguments.
  -- Returns on success: `true, "ok", regions_by_track_table`.
  -- Returns on failure: `false, error_message, nil`.
  local function collect_regions_by_track_for_IVC()
    local selected_tracks_count = r.CountSelectedTracks(0)
    if selected_tracks_count < 1 then
      return false, t("No tracks selected."), nil
    end

    local regions_by_track_table = {}
    local gap_threshold = tonumber(CFG.ivc_gap_threshold_sec) or 3.5
    if gap_threshold < 0 then gap_threshold = 0 end

    for i = 0, selected_tracks_count - 1 do
      local track = r.GetSelectedTrack(0, i)
      if track then
        local item_count = r.CountTrackMediaItems(track)
        local track_items = {}

        for j = 0, item_count - 1 do
          local item = r.GetTrackMediaItem(track, j)
          if item then
            local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
            local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            local item_end = item_pos + item_len
            table.insert(track_items, {
              position = item_pos,
              end_position = item_end
            })
          end
        end

        if #track_items < 1 then
          regions_by_track_table[track] = {}
        else
          table.sort(track_items, function(a, b)
            return a.position < b.position
          end)

          local start_pos = nil
          local end_pos = nil
          for _, item_data in ipairs(track_items) do
            local item_pos = item_data.position
            local item_end = item_data.end_position

            if start_pos == nil then
              start_pos = item_pos
              end_pos = item_end
            else
              if item_pos > (end_pos + gap_threshold) then
                break
              end
              if (not end_pos) or (end_pos < item_end) then
                end_pos = item_end
              end
            end
          end

          if start_pos ~= nil and end_pos ~= nil then
            regions_by_track_table[track] = {
              { start_pos, end_pos }
            }
          else
            regions_by_track_table[track] = {}
          end
        end
      end
    end

    return true, "ok", regions_by_track_table
  end --function collect_regions_by_track_for_IVC()

  -- Gets track text items so later steps can use it.
  -- Called by `ReaperX.get_text_items_by_track`; caller passes `items_table`.
  local function get_track_text_items(items_table)
    if #items_table < 1 then
      return
        false,
        'No items in items_table!'
    end --if
    -- we construct this table so it is always has at least one item, but I keep that check here

    local track_text_items = {}
    for i = 1, #items_table do
      local item = items_table[i]
      local _, item_notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
      if item_notes ~= "" then
        local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        table.insert(track_text_items, {
          text = item_notes,
          position = item_pos,
          length = item_len,
          media_item = item
        })
      end --if
    end --for

    return
      true,
      track_text_items

  end --get_track_text_items(items_table)

  -- Gets render regions by track so later steps can use it.
  -- Called by several helpers (for example `run_el_speech_to_speech_for_selected_items`, `run_el_speech_to_speech_fast`, and `GuiLoop`); caller passes no arguments and uses shared state.
  function ReaperX.get_render_regions_by_track(voice_choices)
    if (S) and (S.el_voices) and (S.el_voices.by_id) and (next(S.el_voices.by_id))
      then
        --ok
        -- We have voices by ID
      else
        return
          false,
          t('No voices configured! Please fetch voices from server first.')
    end --if
    local ok_items, items_msg, items_by_track = collect_selected_items_by_track()
    if not ok_items then
      return false, items_msg
    end

    local missing_tracks = {}
    for track, items_table in pairs(items_by_track) do
      local _, track_name = r.GetTrackName(track)
      local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
      Util.msg('Track: '..tostring(track_name)..', has '..tostring(#items_table)..' selected items.')
      local voice_id = Eleven.resolve_voice_id_for_track_name(track_name, voice_choices)
      if voice_id then
        Util.msg('Track: '..tostring(track_name)..' is mapped to voice ID: '..tostring(voice_id)..'.')
      else
        Util.msg('Track: '..tostring(track_name)..' is NOT mapped to any voice ID! Aborting...', 1)
        table.insert(S.warnings, string.format(t('Track: %s has wrong name (no voice found)! Aborting.'), tostring(track_name)))
        local label = (track_name and track_name ~= "") and track_name or string.format(t("Track %s"), tostring(track_idx))
        table.insert(missing_tracks, label)
      end --if
    end --for

    if #missing_tracks > 0 then
      local msg_txt = string.format(t('Track name(s) not mapped to voice IDs: %s'), table.concat(missing_tracks, ", "))
      return false, msg_txt
    end --if

    local ok_regions, regions_msg, prepared = build_sts_regions_by_track(items_by_track)
    if not ok_regions then
      return false, regions_msg
    end

    local regions_by_track = prepared and prepared.regions_by_track or nil
    local skipped_regions = prepared and prepared.skipped_regions or nil
    if (regions_by_track and next(regions_by_track)) or (skipped_regions and #skipped_regions > 0) then
      return true, prepared
    end

    return false, t('No regions found on any track!')

  end --function ReaperX.get_render_regions_by_track()

  -- Collects and inspects selected-track regions for future IVC flow.
  -- Called by future IVC UI flows; caller passes optional default noise-removal boolean.
  -- Returns on success: `true, "ok", rows`.
  -- Returns on hard failure: `false, error_message, nil`.
  function ReaperX.get_regions_by_track_for_IVC(default_remove_background_noise)
    local voices_by_name = S.el_voices and S.el_voices.by_name or nil
    if type(voices_by_name) ~= "table" or not next(voices_by_name) then
      return false, t("No voices configured! Please fetch voices from server first."), nil
    end
    local default_remove_noise = default_remove_background_noise == true

    local ok_collect, collect_msg, regions_by_track_table = collect_regions_by_track_for_IVC()
    if not ok_collect then
      return false, collect_msg, nil
    end

    local selected_name_counts = {}
    for track in pairs(regions_by_track_table) do
      local _, track_name_raw = r.GetTrackName(track)
      local track_name = VoiceCatalog.trim_name(track_name_raw)
      if track_name ~= "" then
        selected_name_counts[track_name] = (selected_name_counts[track_name] or 0) + 1
      end
    end

    local rows = {}
    for track, regions in pairs(regions_by_track_table) do
      local _, track_name_raw = r.GetTrackName(track)
      local track_name = VoiceCatalog.trim_name(track_name_raw)
      local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
      local track_number = math.floor(track_idx + 0.0001)

      local region_start = nil
      local region_end = nil
      if type(regions) == "table" and #regions > 0 and type(regions[1]) == "table" then
        region_start = regions[1][1]
        region_end = regions[1][2]
      end

      local problems = {}
      if track_name == "" then
        table.insert(problems, t("Track name is empty."))
      end
      if track_name ~= "" and voices_by_name[track_name] ~= nil then
        table.insert(problems, t("Track name is mapped to an existing voice ID."))
      end
      if track_name ~= "" and (selected_name_counts[track_name] or 0) > 1 then
        table.insert(problems, t("Track name is duplicated across selected tracks."))
      end

      if region_start == nil or region_end == nil then
        table.insert(problems, t("No region found for selected track."))
      else
        local start_num = tonumber(region_start)
        local end_num = tonumber(region_end)
        if start_num == nil or end_num == nil or start_num >= end_num then
          table.insert(problems, t("Region bounds are invalid."))
        else
          region_start = start_num
          region_end = end_num
          if not (start_num < (end_num - 1.0)) then
            table.insert(problems, t("Region duration must be greater than 1.0 seconds."))
          end
        end
      end

      local can_pass = (#problems == 0)
      local status = can_pass and t("OK to pass to IVC") or table.concat(problems, "; ")
      table.insert(rows, {
        track = track,
        track_number = track_number,
        track_name = track_name,
        region_start = region_start,
        region_end = region_end,
        can_pass = can_pass,
        status = status,
        remove_background_noise = default_remove_noise
      })
    end

    table.sort(rows, function(a, b)
      local a_num = tonumber(a.track_number) or 0
      local b_num = tonumber(b.track_number) or 0
      if a_num == b_num then
        return tostring(a.track_name or "") < tostring(b.track_name or "")
      end
      return a_num < b_num
    end)

    return true, t("ok"), rows
  end --function ReaperX.get_regions_by_track_for_IVC()

  -- Gets text items by track so later steps can use it.
  -- Called by `run_el_text_to_speech_for_selected_items`; caller passes no arguments and uses shared state.
  function ReaperX.get_text_items_by_track(ignore_voice_mapping, voice_choices)
    -- ignore_voice_mapping=true skips voice checks (used by OpenAI flow).
    if not ignore_voice_mapping then
      if (S) and (S.el_voices) and (S.el_voices.by_id) and (next(S.el_voices.by_id))
        then
          --ok
          -- We have voices by ID
        else
          return
            false,
            t('No voices configured! Please fetch voices from server first.')
      end --if
    end
    local number_of_selected_items = r.CountSelectedMediaItems(0)
    if number_of_selected_items > 0
      then
        --we have selected items
        local items_by_track = { }
        for i=0, (number_of_selected_items-1) do
          local current_item = r.GetSelectedMediaItem(0, i)
          local track = r.GetMediaItemTrack(current_item)
          if not items_by_track[track] then
            items_by_track[track] = { }
          end
          table.insert(items_by_track[track], current_item)
        end --for

        local text_items_by_track = {}
        local total_text_items = 0
        local missing_tracks = {}
        for track, items_table in pairs(items_by_track) do
          local ok, err_or_text_items = get_track_text_items(items_table)
          if ok
            then
              if #err_or_text_items > 0 then
                local _, track_name = r.GetTrackName(track)
                local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
                Util.msg('Track: '..tostring(track_name)..', has '..tostring(#items_table)..' selected text items.')
                local voice_id = ""
                if not ignore_voice_mapping then
                  voice_id = Eleven.resolve_voice_id_for_track_name(track_name, voice_choices)
                  if voice_id then
                    Util.msg('Track: '..tostring(track_name)..' is mapped to voice ID: '..tostring(voice_id)..'.')
                  else
                    Util.msg('Track: '..tostring(track_name)..' is NOT mapped to any voice ID! Aborting...', 1)
                    table.insert(
                      S.warnings,
                      string.format(t("Track: %s has wrong name (no voice found)! Aborting."), tostring(track_name))
                    )
                    local label =
                      (track_name and track_name ~= "") and
                      track_name or
                      string.format(t("Track %s"), tostring(track_idx))
                    table.insert(missing_tracks, label)
                  end --if
                end

                text_items_by_track[track] = {
                  voice_name = track_name or "",
                  voice_ID = voice_id,
                  text_items = err_or_text_items
                }
                total_text_items = total_text_items + #err_or_text_items
              end --if #err_or_text_items > 0
            else
              --some error
              return
                false,
                string.format(
                  t("While calling get_track_text_items(items_table) we got error: %s"),
                  tostring(err_or_text_items)
                )
          end --if
        end --for

        if (not ignore_voice_mapping) and #missing_tracks > 0 then
          local msg_txt = string.format(t("Track name(s) not mapped to voice IDs: %s"), table.concat(missing_tracks, ", "))
          return false, msg_txt
        end --if

        if total_text_items > 0 then
          return
            true,
            text_items_by_track
        else
          return
            false,
            t("No text items found on any track!"),
            "no_text_items"
        end --if

      else
        return
          false,
          t("No selected items in project! Please select items to process."),
          "no_selected_items"
    end --if number_of_selected_items > 0

  end --function ReaperX.get_text_items_by_track()

  -- Gets text from selected items grouped by track, with per-track text joined by spaces
  -- and tracks joined by newlines. Keeps raw item notes; no sorting.
  -- Returns ok, combined_text, text_by_track.
  function ReaperX.get_text_from_selected_items_by_track()
    local ok, err_or_items, reason = ReaperX.get_text_items_by_track(true) --ignores voice mapping
    if not ok then
      if reason == "no_text_items" or reason == "no_selected_items" then
        return true, "", {}
      end
      local msg = type(err_or_items) == "string" and err_or_items or t("Failed to collect text items.")
      return false, msg, {}
    end

    local text_by_track = {}
    local track_texts = {}
    for track, data in pairs(err_or_items) do
      local pieces = {}
      local text_items = data and data.text_items or {}
      for _, item in ipairs(text_items) do
        local item_text = item and item.text or ""
        if item_text ~= "" then
          table.insert(pieces, item_text)
        end
      end
      local track_text = table.concat(pieces, " ")
      text_by_track[track] = track_text
      table.insert(track_texts, track_text)
    end

    local combined = table.concat(track_texts, "\n")
    return true, combined, text_by_track
  end --function ReaperX.get_text_from_selected_items_by_track()

  -- Removes brackets in selected items notes,
  -- returns success(true/false), count_items_updated, count_failed, message.
  function ReaperX.remove_brackets_in_selected_items_notes()
    local number_of_selected_items = r.CountSelectedMediaItems(0)
    if number_of_selected_items < 1 then
      return true, 0, 0, t("No selected items.")
    end
    local count_items_updated = 0
    local count_failed = 0
    local undo_started = false
    local get_item = r.GetSelectedMediaItem
    local get_set_item_info_string = r.GetSetMediaItemInfo_String
    local do_remove = Util.remove_brackets
    for i=0, (number_of_selected_items-1) do
      local current_item = get_item(0, i)
      if current_item then
        local get_result, item_notes = get_set_item_info_string(current_item, "P_NOTES", "", false)
        if get_result then
          local trimmed_notes, count = do_remove(item_notes or "")
          if count > 0 then
            if not undo_started then
              undo_started = true
              r.PreventUIRefresh(1)
              r.Undo_BeginBlock()
            end --if not undo_started
            local set_result, _ = get_set_item_info_string(current_item, "P_NOTES", trimmed_notes, true)
            if set_result then
              --Util.msg("Updated item notes for item number " .. tostring(i) .. ".")
              count_items_updated = count_items_updated + 1
            else
              --Util.msg("Failed to set updated item notes for item number " .. tostring(i) .. ".", 2)
              count_failed = count_failed + 1
            end --if set_result
          else
            --Util.msg("No bracketed sections found in item notes.")
            -- just don't count
          end --if count > 0
        else
          --Util.msg("Failed to get item notes for item number " .. tostring(i) .. ".", 2)
          count_failed = count_failed + 1
        end --if get_result
      else
        Util.msg("Failed to get item number " .. tostring(i) .. ". Selection changed during tight loop?", 3)
        count_failed = count_failed + 1
      end --if current_item
    end --for
    if undo_started then
      r.PreventUIRefresh(-1)
      r.Undo_EndBlock("Remove brackets from selected items notes", 4)
      r.UpdateArrange()
    end
    local message = ""
    if count_items_updated > 0 then
      message = string.format(t("Removed bracketed sections from %s item(s)."), tostring(count_items_updated))
      --Util.msg(message)
    else
      message = t("No bracketed sections found in items.")
      --Util.msg(message)
    end
    local success = true
    if count_failed > 0 then
      success = false
      message = string.format(t("%s But failed to process %s item(s)."), message, tostring(count_failed))
    end
    return success, count_items_updated, count_failed, message
  end --function ReaperX.remove_brackets_in_selected_items_notes()

  -- Stores warning in UI warnings collection.
  local function push_ui_warning(msg)
    if type(S.warnings) ~= "table" then
      S.warnings = {}
    end
    table.insert(S.warnings, tostring(msg or t("Unknown warning.")))
  end

  -- returns true, track on success, false, "reason" on failure.
  function ReaperX.get_temp_text_track()
    -- get number of tracks in project
    local track_count = r.CountTracks(0)
    -- add new track at the end
    local new_track_idx = track_count
    r.InsertTrackAtIndex(new_track_idx, false)
    local new_track = r.GetTrack(0, new_track_idx)
    if not new_track then
      return false, t("Failed to create temporary text track.")
    end
    -- set new track's name
    local stamp = Util.date_time_stamp_with_time_precise()
    local name_ok, name_string_return =
      r.GetSetMediaTrackInfo_String(
        new_track,
        'P_NAME',
        'TempTextTrack_' .. stamp,
        true
      )
    if name_ok then
      Util.msg("Created temp text track: " .. "TempTextTrack_" .. stamp)
    else
      Util.msg("Failed to set temp text track name, but track created successfully.", 2)
    end

    -- set new track master/parent send to false
    r.SetMediaTrackInfo_Value(new_track, "B_MAINSEND", 0)

    -- set new track vol to minus infinity
    r.SetMediaTrackInfo_Value(new_track, "D_VOL", 0)

    -- update reaper's ui
    r.UpdateArrange()
    return true, new_track
  end --function ReaperX.get_temp_text_track()

  -- Gets a valid temp text track and caches it in ReaperX.temp_text_track.
  -- On success, returns true and the track pointer.
  -- On failure, returns false and an error message.
  function ReaperX.resolve_temp_text_track()
    if ReaperX.temp_text_track and r.ValidatePtr2(0, ReaperX.temp_text_track, "MediaTrack*") then
      return true, ReaperX.temp_text_track
    end

    if type(ReaperX.get_temp_text_track) ~= "function" then
      return false, t("ReaperX.get_temp_text_track() is not implemented.")
    end

    local get_track_ok, tr_or_err_msg = ReaperX.get_temp_text_track()
    local resolved = nil
    local err = nil

    if get_track_ok and r.ValidatePtr2(0, tr_or_err_msg, "MediaTrack*") then
      resolved = tr_or_err_msg
    else
      err = tr_or_err_msg or t("unknown error")
    end

    if not resolved then
      return false, string.format(t("Could not resolve temp text track: %s"), tostring(err or t("unknown error")))
    end

    ReaperX.temp_text_track = resolved
    return true, resolved
  end --function ReaperX.resolve_temp_text_track()

  -- Merges imported text into existing text based on selected mode.
  function ReaperX.merge_text(base, incoming, mode)
    local base_txt = tostring(base or "")
    local incoming_txt = tostring(incoming or "")
    local merge_mode = tostring(mode or "overwrite")

    if merge_mode == "append_newline" then
      if base_txt ~= "" and incoming_txt ~= "" then
        return base_txt .. "\n" .. incoming_txt
      end
      return base_txt .. incoming_txt
    end

    if merge_mode == "append_space" then
      if base_txt ~= "" and incoming_txt ~= "" then
        return base_txt .. " " .. incoming_txt
      end
      return base_txt .. incoming_txt
    end

    return incoming_txt
  end --function ReaperX.merge_text(base, incoming, mode)

  -- Applies imported text to a Voice Design field using selected merge mode.
  function ReaperX.apply_import_to_vd_field(field_key, incoming_text, merge_mode)
    local vd = Eleven.ensure_voice_design_state()
    local key = tostring(field_key or "")
    if key ~= "voice_description" and key ~= "text" then
      return false, string.format(t("Unsupported Voice Design field key: %s"), key)
    end

    local current = tostring(vd[key] or "")
    vd[key] = ReaperX.merge_text(current, tostring(incoming_text or ""), merge_mode)
    return true, vd[key]
  end --function ReaperX.apply_import_to_vd_field(field_key, incoming_text, merge_mode)

  -- Creates a temporary text item on the given track and stores text in item notes.
  function ReaperX.create_temp_text_item(track, text)
    if not track or (not r.ValidatePtr2(0, track, "MediaTrack*")) then
      return false, t("Invalid temp text track."), nil
    end

    local position = tonumber(ReaperX.temp_text_item_next_position) or 1
    local length = 3
    local item = r.AddMediaItemToTrack(track)
    if not item then
      return false, t("Failed to create temp text item."), nil
    end

    r.SetMediaItemInfo_Value(item, "D_POSITION", position)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", length)
    r.GetSetMediaItemInfo_String(item, "P_NOTES", tostring(text or ""), true)
    ReaperX.temp_text_item_next_position = position + 4
    r.UpdateArrange()
    return true, item, nil
  end --function ReaperX.create_temp_text_item(track, text)

  -- Opens REAPER item notes for the provided item using a configured command id.
  function ReaperX.open_item_notes_best_effort(item)
    if not item or (not r.ValidatePtr2(0, item, "MediaItem*")) then
      return false, t("Invalid MediaItem for opening notes.")
    end

    --Item: Unselect (clear selection of) all items
    --40289
    r.Main_OnCommand(40289, 0)
    r.UpdateArrange()
    r.SetMediaItemSelected(item, true)
    r.UpdateArrange()

    local cmd_id = tonumber(CFG and CFG.vd_open_item_notes_action_id or 0) or 0
    cmd_id = math.floor(cmd_id)
    if cmd_id <= 0 then
      return false, t("Item-notes action is not configured (CFG.vd_open_item_notes_action_id <= 0).")
    end

    r.Main_OnCommand(cmd_id, 0)
    return true, nil
  end --function ReaperX.open_item_notes_best_effort(item)

  -- Reads notes from a media item.
  function ReaperX.read_item_notes(item)
    if not item or (not r.ValidatePtr2(0, item, "MediaItem*")) then
      return false, t("Invalid MediaItem pointer."), nil
    end
    local ok, notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    if not ok then
      return false, t("Failed to read item notes."), nil
    end
    return true, notes, nil
  end --function ReaperX.read_item_notes(item)

  -- Prepends text to notes for all currently selected media items.
  -- Called by `GuiLoop`; caller passes `prefix_text`.
  -- Returns ok, message, updated_count, failed_count.
  function ReaperX.prepend_text_to_selected_item_notes(prefix_text)
    local prefix = tostring(prefix_text or "")
    if prefix == "" then
      return false, t("Audio tags input is empty. Nothing to insert."), 0, 0
    end

    local selected_count = r.CountSelectedMediaItems(0)
    if (not selected_count) or selected_count < 1 then
      return false, t("No selected items in project! Please select items first."), 0, 0
    end

    local updated_count = 0
    local failed_count = 0
    r.Undo_BeginBlock2(0)
    r.PreventUIRefresh(16)
    for i = 0, selected_count - 1 do
      local item = r.GetSelectedMediaItem(0, i)
      if item and r.ValidatePtr2(0, item, "MediaItem*") then
        local ok_read, notes_or_err, _ = ReaperX.read_item_notes(item)
        if ok_read then
          local merged_notes = prefix .. tostring(notes_or_err or "")
          local ok_write = r.GetSetMediaItemInfo_String(item, "P_NOTES", merged_notes, true)
          if ok_write then
            r.UpdateItemInProject(item)
            updated_count = updated_count + 1
          else
            failed_count = failed_count + 1
          end
        else
          Util.msg("Failed to read item notes before prepend: " .. tostring(notes_or_err or "unknown error"), 2)
          failed_count = failed_count + 1
        end
      else
        failed_count = failed_count + 1
      end
    end
    r.PreventUIRefresh(-16)
    r.Undo_EndBlock2(0, "Prepend audio tags to selected item notes", 4)
    r.UpdateArrange()

    if updated_count < 1 then
      return false, t("Could not update selected item notes."), updated_count, failed_count
    end
    if failed_count > 0 then
      local msg = string.format(t("Inserted audio tags into %s selected item(s); failed on %s."), tostring(updated_count), tostring(failed_count))
      return true, msg, updated_count, failed_count
    end
    return true, string.format(t("Inserted audio tags into %s selected item(s)."), tostring(updated_count)), updated_count, failed_count
  end --function ReaperX.prepend_text_to_selected_item_notes(prefix_text)

  -- Synchronizes Voice Design text fields from currently linked temporary items.
  function ReaperX.sync_voice_design_temp_items(vd)
    if type(vd) ~= "table" then
      return
    end

    local links = {
      { item_key = "desc_temp_item", field_key = "voice_description", warn_key = "desc_temp_item_invalid_warned", label = t("Voice description") },
      { item_key = "preview_temp_item", field_key = "text", warn_key = "preview_temp_item_invalid_warned", label = t("Preview text") }
    }

    for _, link in ipairs(links) do
      local item = vd[link.item_key]
      if item ~= nil then
        if r.ValidatePtr2(0, item, "MediaItem*") then
          local ok, notes = ReaperX.read_item_notes(item)
          if ok then
            vd[link.field_key] = tostring(notes or "")
          end
          vd[link.warn_key] = false
        else
          vd[link.item_key] = nil
          if vd[link.warn_key] ~= true then
            push_ui_warning(string.format(t("Voice Design %s temp item is no longer valid. Link cleared."), tostring(link.label)))
            vd[link.warn_key] = true
          end
        end
      end
    end
  end --function ReaperX.sync_voice_design_temp_items(vd)

  -- Stub: returns selected track name if available.
  -- Called by Voice Design popup; caller passes no arguments.
  function ReaperX.get_selected_track_name()
    return ""
  end --function ReaperX.get_selected_track_name()

  -- Formats render regions by track into a friendlier form for logs or UI.
  -- Called by `GuiLoop`; caller passes `regions_by_track`.
  function ReaperX.format_render_regions_by_track(regions_by_track)
    local prepared = regions_by_track
    local skipped_regions = nil
    if type(prepared) == "table" and (prepared.regions_by_track or prepared.skipped_regions) then
      regions_by_track = prepared.regions_by_track or {}
      skipped_regions = prepared.skipped_regions or {}
    end

    local has_regions = type(regions_by_track) == "table" and next(regions_by_track) ~= nil
    local has_skipped = type(skipped_regions) == "table" and #skipped_regions > 0
    if (not has_regions) and (not has_skipped) then
      return t("No regions to display.")
    end

    local tracks_list = {}
    for track, regions in pairs(regions_by_track or {}) do
      local _, track_name = r.GetTrackName(track)
      local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
      table.insert(tracks_list, {
        track = track,
        name = track_name or "",
        idx = track_idx,
        regions = regions or {}
      })
    end

    table.sort(tracks_list, function(a, b)
      if a.idx == b.idx then
        return (a.name or "") < (b.name or "")
      end
      return a.idx < b.idx
    end)

    local lines = {}
    local total_regions = 0
    local total_duration = 0
    for _, entry in ipairs(tracks_list) do
      local label =
        entry.name ~= "" and
        entry.name or
        string.format(t("Track %s"), string.format("%.0f", entry.idx))
      local regions = entry.regions or {}
      local track_duration = 0
      total_regions = total_regions + #regions
      for i, region in ipairs(regions) do
        local start_pos = tonumber(region[1]) or 0
        local end_pos = tonumber(region[2]) or 0
        local duration = end_pos - start_pos
        if duration < 0 then duration = 0 end
        track_duration = track_duration + duration
      end
      total_duration = total_duration + track_duration
      table.insert(
        lines,
        string.format(t("Track: %s (regions: %d, duration: %s)"), label, #regions, fmt_time_for_region(track_duration))
      )
      for i, region in ipairs(regions) do
        local start_pos = tonumber(region[1]) or 0
        local end_pos = tonumber(region[2]) or 0
        local duration = end_pos - start_pos
        if duration < 0 then duration = 0 end
        table.insert(
          lines,
          string.format(t("  %d) %s - %s (dur: %s)"), i, fmt_time_for_region(start_pos), fmt_time_for_region(end_pos), fmt_time_for_region(duration))
        )
      end
    end

    if has_regions then
      table.insert(
        lines,
        1,
        string.format(
          t("Tracks: %d | Total regions: %d | Total duration: %s"),
          #tracks_list,
          total_regions,
          fmt_time_for_region(total_duration)
        )
      )
    else
      table.insert(lines, t("No renderable regions after applying current STS settings."))
    end

    if has_skipped then
      table.insert(lines, "")
      table.insert(lines, string.format(t("Skipped STS regions: %d"), #skipped_regions))
      for i, skipped in ipairs(skipped_regions) do
        table.insert(lines, string.format(t("  %d) %s"), i, describe_sts_skipped_region(skipped)))
      end
    end

    return table.concat(lines, "\n")
  end
end  --enf of "do --WORK WITH REAPER PROJ"

--====================== API helpers======================

-- Clips body text into a friendlier form for logs or UI.
-- Called by `Eleven.summarize_el_error` and `Eleven.summarize_sts_error_body`; caller passes `body` and `max_len`.
-- Called by `Eleven.summarize_el_error` and `Eleven.summarize_sts_error_body`; caller passes `val`.
do --some API helpers (ElevenLabs, OpenAI) and curl somehow
  -- Summarizes ElevenLabs error into a friendlier form for logs or UI.
  -- Called by several helpers (for example `Eleven.fetch_el_models`, `Eleven.fetch_el_voices`, and `Eleven.submit_el_speech_to_speech_jobs_fast`); caller passes `result`.
  function Eleven.summarize_el_error(result)
    local base = result and result.err or nil
    local body = result and result.body or nil
    local body_summary = nil

    if body and body ~= "" then
      local ok, decoded = pcall(json.decode, body)
      if ok and type(decoded) == "table" then
        local pieces = {}
        local status = Util.stringify_json_value(decoded.status or decoded.statusCode or decoded.code)
        local title = Util.stringify_json_value(decoded.error or decoded.title)
        local msg_txt = Util.stringify_json_value(decoded.message or decoded.detail)
        if status and status ~= "" then table.insert(pieces, status) end
        if title and title ~= "" then table.insert(pieces, title) end
        if msg_txt and msg_txt ~= "" then table.insert(pieces, msg_txt) end
        if #pieces > 0 then
          body_summary = table.concat(pieces, " - ")
        else
          local ok_enc, encoded = pcall(json.encode, decoded)
          if ok_enc then body_summary = encoded end
        end
      else
        body_summary = Util.clip_body_text(body, 1024)
      end
    end

    if base and body_summary and base ~= "" and body_summary ~= "" then
      if body_summary:find(base, 1, true) then
        return body_summary
      end
      return base .. " - " .. body_summary
    end

    return body_summary or base or t("Request failed.")
  end

  -- Summarizes speech-to-speech error body into a friendlier form for logs or UI.
  -- Called by several helpers (for example `Eleven.submit_el_speech_to_speech_jobs_fast`, `Eleven.submit_el_speech_to_speech_jobs`, and `on_done`); caller passes `body`.
  function Eleven.summarize_sts_error_body(body)
    if not body or body == "" then return nil end
    local ok, decoded = pcall(json.decode, body)
    if ok and type(decoded) == "table" then
      if type(decoded.detail) == "table" then
        local pieces = {}
        for _, d in ipairs(decoded.detail) do
          if type(d) == "table" then
            local msg_txt = d.msg or d.message or d.detail or d.error
            local loc = d.loc
            if type(loc) == "table" and #loc > 0 then
              local loc_parts = {}
              for _, entry in ipairs(loc) do
                table.insert(loc_parts, tostring(entry))
              end
              local loc_str = table.concat(loc_parts, ".")
              local base_msg = (msg_txt and msg_txt ~= "" and msg_txt) or t("Error")
              msg_txt = string.format(t("%s (loc: %s)"), tostring(base_msg), tostring(loc_str))
            end
            if msg_txt and msg_txt ~= "" then
              table.insert(pieces, msg_txt)
            end
          else
            table.insert(pieces, tostring(d))
          end
        end
        if #pieces > 0 then
          return table.concat(pieces, "; ")
        end
      end
      local msg_txt = Util.stringify_json_value(decoded.message or decoded.detail or decoded.error)
      if msg_txt and msg_txt ~= "" then return msg_txt end
      local ok_enc, encoded = pcall(json.encode, decoded)
      if ok_enc then return encoded end
    end
    return Util.clip_body_text(body, 1024)
  end

  -- Summarizes OpenAI error into a friendlier form for logs or UI.
  -- Called by `OpenAI.submit_openai_text_rewrite_jobs`; caller passes `result`.
  function OpenAI.summarize_openai_error(result)
    local base = result and result.err or nil
    local body = result and result.body or nil
    local body_summary = nil

    if body and body ~= "" then
      local ok, decoded = pcall(json.decode, body)
      if ok and type(decoded) == "table" then
        local err = decoded.error or decoded.err
        if type(err) == "table" then
          local pieces = {}
          local status = Util.stringify_json_value(err.status or decoded.status or decoded.code)
          local typ = Util.stringify_json_value(err.type or err.code)
          local msg_txt = Util.stringify_json_value(err.message or err.detail or err.error)
          if status and status ~= "" then table.insert(pieces, status) end
          if typ and typ ~= "" then table.insert(pieces, typ) end
          if msg_txt and msg_txt ~= "" then table.insert(pieces, msg_txt) end
          if #pieces > 0 then
            body_summary = table.concat(pieces, " - ")
          end
        else
          local msg_txt = Util.stringify_json_value(decoded.message or decoded.detail or decoded.error)
          if msg_txt and msg_txt ~= "" then body_summary = msg_txt end
        end
        if not body_summary then
          local ok_enc, encoded = pcall(json.encode, decoded)
          if ok_enc then body_summary = encoded end
        end
      else
        body_summary = Util.clip_body_text(body, 1024)
      end
    end

    if base and body_summary and base ~= "" and body_summary ~= "" then
      if body_summary:find(base, 1, true) then
        return body_summary
      end
      return base .. " - " .. body_summary
    end

    return body_summary or base or t("Request failed.")
  end

  -- Extracts output text from OpenAI Responses payload.
  -- Called by `OpenAI.submit_openai_text_rewrite_jobs`; caller passes decoded response table.
  function OpenAI.extract_openai_output_text(decoded)
    if type(decoded) ~= "table" then
      return nil, t("Response is not a table.")
    end

    local function first_non_empty(...)
      for i = 1, select("#", ...) do
        local val = select(i, ...)
        if val ~= nil then
          local s = Util.stringify_json_value(val)
          if s and s ~= "" then
            return s
          end
        end
      end
      return nil
    end

    local function refusal_error(part, item)
      local msg = first_non_empty(
        part and part.refusal,
        item and item.refusal,
        part and part.text,
        item and item.text
      )
      if not msg or msg == "" then
        return t("Model refused.")
      end
      return string.format(t("Model refused: %s"), msg)
    end

    local function tool_call_error(part, item, tool_call)
      local name = first_non_empty(
        tool_call and (tool_call.name or tool_call.tool_name or tool_call.function_name),
        part and (part.name or part.tool_name or part.function_name),
        item and (item.name or item.tool_name or item.function_name)
      ) or t("unknown")
      local call_id = first_non_empty(
        tool_call and (tool_call.call_id or tool_call.id),
        part and (part.call_id or part.id),
        item and (item.call_id or item.id)
      ) or t("unknown")
      return string.format(t("Unexpected tool call output: %s (call_id=%s)"), tostring(name), tostring(call_id))
    end

    local top_refusal = first_non_empty(decoded.refusal)
    if top_refusal and top_refusal ~= "" then
      if top_refusal == t("Model refused.") then
        return nil, top_refusal
      end
      return nil, string.format(t("Model refused: %s"), top_refusal)
    end

    local pieces = {}
    local tool_call_err = nil

    local output = decoded.output
    if type(output) == "table" then
      for _, item in ipairs(output) do
        if type(item) == "table" then
          if item.refusal and item.refusal ~= "" then
            return nil, refusal_error(nil, item)
          end

          local item_type = item.type
          if item_type == "tool_call" or item_type == "function_call" then
            if not tool_call_err then
              tool_call_err = tool_call_error(nil, item)
            end
          end

          if type(item.tool_calls) == "table" and item.tool_calls[1] then
            if not tool_call_err then
              tool_call_err = tool_call_error(nil, item, item.tool_calls[1])
            end
          elseif type(item.function_call) == "table" then
            if not tool_call_err then
              tool_call_err = tool_call_error(nil, item, item.function_call)
            end
          end

          local content = item.content
          if type(content) == "table" then
            for _, part in ipairs(content) do
              if type(part) == "table" then
                if part.type == "refusal" or (part.refusal and part.refusal ~= "") then
                  return nil, refusal_error(part, item)
                end

                if part.type == "tool_call" or part.type == "function_call" then
                  if not tool_call_err then
                    tool_call_err = tool_call_error(part, item)
                  end
                end

                if type(part.tool_calls) == "table" and part.tool_calls[1] then
                  if not tool_call_err then
                    tool_call_err = tool_call_error(part, item, part.tool_calls[1])
                  end
                elseif type(part.function_call) == "table" then
                  if not tool_call_err then
                    tool_call_err = tool_call_error(part, item, part.function_call)
                  end
                end

                if part.type == "output_text" and part.text then
                  table.insert(pieces, tostring(part.text))
                elseif part.type == "text" and part.text then
                  table.insert(pieces, tostring(part.text))
                end
              end
            end
          elseif item.type == "output_text" and item.text then
            table.insert(pieces, tostring(item.text))
          elseif item.type == "text" and item.text then
            table.insert(pieces, tostring(item.text))
          end
        end
      end
    end

    if tool_call_err then
      return nil, tool_call_err
    end

    local direct = decoded.output_text
    if type(direct) == "string" and direct ~= "" then
      return direct
    end

    local combined = table.concat(pieces, "")
    if combined ~= "" then
      return combined
    end
    return nil, t("No output_text in response.")
  end

  -- Normalizes OpenAI rewrite mode so unknown values fall back safely.
  function OpenAI.normalize_rewrite_mode(mode)
    local v = tostring(mode or ""):lower()
    if v == "per_track" then return "per_track" end
    if v == "all_items" then return "all_items" end
    return "per_item"
  end

  -- Builds a user-facing label for the selected OpenAI rewrite mode.
  function OpenAI.rewrite_mode_label(mode)
    local m = OpenAI.normalize_rewrite_mode(mode)
    if m == "per_track" then return t("Per-track") end
    if m == "all_items" then return t("All selected") end
    return t("Per-item")
  end

  -- Returns Structured Outputs schema for OpenAI batch rewrite response.
  function OpenAI.batch_output_json_schema()
    return {
      type = "object",
      additionalProperties = false,
      properties = {
        items = {
          type = "array",
          description = "Output items.",
          items = {
            type = "object",
            additionalProperties = false,
            properties = {
              id = {
                type = "string",
                description = "Item ID, matching the input ID."
              },
              text = {
                type = "string",
                description = "The rewritten text for this ID, with inserted audio tags."
              }
            },
            required = { "id", "text" }
          }
        }
      },
      required = { "items" }
    }
  end

  -- Builds OpenAI batch request with Structured Outputs json_schema format.
  function OpenAI.build_openai_batch_request(rec_ref, base_label, attempt, max_attempts)
    local req_input = rec_ref and rec_ref.input_payload_text or nil
    if type(req_input) ~= "string" or req_input == "" then
      return nil, t("OpenAI batch request missing input payload.")
    end
    local instructions = CFG.openai_batch_rewrite_prompt
    if type(instructions) ~= "string" or instructions == "" then
      return nil, t("Missing OpenAI batch rewrite prompt.")
    end

    return Backend.client():openai_rewrite_request({
        model = CFG.openai_model,
        instructions = instructions,
        input = req_input,
        text = {
          format = {
            type = "json_schema",
            name = "elevenlabs_audio_tag_batch",
            strict = true,
            schema = OpenAI.batch_output_json_schema()
          }
        }
      }, Jobs.format_attempt_label(base_label, attempt, max_attempts), tonumber(CFG.openai_batch_timeout_sec) or 600)
  end

  -- Extracts and validates batch rewrite payload with strict ID mapping.
  -- Returns id_to_text map keyed by string id.
  function OpenAI.extract_openai_batch_output(decoded, expected_ids)
    if type(expected_ids) ~= "table" or not next(expected_ids) then
      return nil, t("Batch validator missing expected IDs.")
    end
    local output_text, out_err = OpenAI.extract_openai_output_text(decoded)
    if not output_text or output_text == "" then
      return nil, out_err or t("Batch response missing output text.")
    end

    local ok_json, parsed = pcall(json.decode, output_text)
    if not ok_json or type(parsed) ~= "table" then
      return nil, t("schema-shape mismatch: response is not valid JSON object.")
    end

    for key, _ in pairs(parsed) do
      if key ~= "items" then
        return nil, string.format(t("schema-shape mismatch: unexpected root key '%s'."), tostring(key))
      end
    end

    local items = parsed.items
    if type(items) ~= "table" then
      return nil, t("schema-shape mismatch: missing 'items' array.")
    end

    local seen = {}
    local id_to_text = {}
    for idx, entry in ipairs(items) do
      if type(entry) ~= "table" then
        return nil, string.format(t("schema-shape mismatch: item %d is not an object."), idx)
      end
      for key, _ in pairs(entry) do
        if key ~= "id" and key ~= "text" then
          return nil, string.format(t("schema-shape mismatch: item %d has unexpected key '%s'."), idx, tostring(key))
        end
      end
      local id_key = entry.id
      if type(id_key) ~= "string" or id_key == "" then
        return nil, string.format(t("schema-shape mismatch: item %d has invalid string id."), idx)
      end
      if seen[id_key] then
        return nil, string.format(t("duplicate id: %s"), id_key)
      end
      if not expected_ids[id_key] then
        return nil, string.format(t("unexpected id: %s"), id_key)
      end
      if type(entry.text) ~= "string" or entry.text == "" then
        return nil, string.format(t("schema-shape mismatch: empty text for id: %s"), id_key)
      end
      seen[id_key] = true
      id_to_text[id_key] = entry.text
    end

    for id_key, _ in pairs(expected_ids) do
      if not seen[id_key] then
        return nil, string.format(t("missing expected id: %s"), tostring(id_key))
      end
    end
    return id_to_text
  end

  -- Builds text-to-speech model list so later steps can reuse it.
  -- Called by `Eleven.run_el_text_to_speech_for_selected_items` and `GuiLoop`; caller passes no arguments and uses shared state.
  function Eleven.build_tts_model_list()
    local list = {}
    local default_id = nil
    local seen = {}
    local models = S.el_models and S.el_models.models
    if type(models) ~= "table" then return list, default_id end
    for _, model in ipairs(models) do
      if model then
        local can_tts = model.can_do_text_to_speech
        if can_tts == true or can_tts == 1 or can_tts == "true" then
          local model_id = model.model_id or model.modelId or model.id or model.name or ""
          if model_id ~= "" and not seen[model_id] then
            local label = model.name or model_id
            table.insert(list, { id = model_id, label = label })
            seen[model_id] = true
            if model_id == "eleven_v3" then
              default_id = model_id
            end
          end
        end
      end
    end
    table.sort(list, function(a, b)
      return (a.label or "") < (b.label or "")
    end)
    return list, default_id
  end

  -- Resolves the active TTS model without overwriting an unavailable saved preference.
  function Eleven.resolve_tts_model_selection(tts_models, default_id)
    local models = tts_models
    local fallback_id = default_id
    if type(models) ~= "table" then
      models, fallback_id = Eleven.build_tts_model_list()
    end
    if #models < 1 then
      S.el_tts_model_selected = ""
      return nil
    end

    local available = {}
    for _, model in ipairs(models) do
      available[model.id] = true
    end

    local preferred_id = tostring(S.el_tts_model_preferred or "")
    local selected_id
    if preferred_id ~= "" and available[preferred_id] then
      selected_id = preferred_id
    else
      selected_id = fallback_id or models[1].id
    end

    S.el_tts_model_selected = selected_id
    if preferred_id == "" then
      S.el_tts_model_preferred = selected_id
      UI.persist_tts_model_preference(selected_id)
    end
    return selected_id
  end

  function Eleven.select_tts_model(model_id)
    local selected_id = tostring(model_id or "")
    if selected_id == "" then return false end
    S.el_tts_model_selected = selected_id
    S.el_tts_model_preferred = selected_id
    UI.persist_tts_model_preference(selected_id)
    return true
  end

  -- Handles cleanup ElevenLabs response so other code can call it.
  -- Called by `Eleven.fetch_el_models` and `Eleven.fetch_el_voices`; caller passes `result`.
  local function cleanup_el_response(result)
    if result then
      result.body = nil
    end
    if S.last_curl_return then
      S.last_curl_return.body = ""
    end
  end --function cleanup_el_response(result)

  -- Ensures misc records list exists so fetch jobs can be shown in the table.
  local function ensure_misc_records()
    if type(S.misc_records) ~= "table" then
      S.misc_records = {}
    end
  end

  -- Finds or creates a misc record for table display.
  local function get_or_create_misc_record(key, display_name, flow_label)
    ensure_misc_records()
    local fallback_label = t("Fetch")
    local rec = nil
    for _, item in ipairs(S.misc_records) do
      if item and item._misc_key == key then
        rec = item
        break
      end
    end
    if not rec then
      rec = {
        _misc_key = key,
        record_name = display_name or fallback_label,
        flow_label = flow_label or display_name or fallback_label,
        misc_start_time_override = "-"
      }
      table.insert(S.misc_records, rec)
    else
      if display_name and display_name ~= "" then rec.record_name = display_name end
      if flow_label and flow_label ~= "" then rec.flow_label = flow_label end
      if rec.misc_start_time_override == nil then rec.misc_start_time_override = "-" end
    end
    return rec
  end

  local function auth_submit_opts()
    return {
      read_body = true,
      keep_output = false,
      body_max_bytes = 512 * 1024,
      timeout_sec = 120
    }
  end

  function Auth.sync_stored_refresh_flag()
    local stored_base = Auth.load_refresh_backend_base()
    local active_base = Backend.active_base_url()
    if stored_base ~= nil and stored_base ~= active_base then
      S.has_stored_refresh = false
      S.refresh_token = ""
      return false, "stored refresh token belongs to another backend"
    end
    local client = Auth.client()
    local token, err = client.load_refresh_token()
    if err then
      Util.msg("Stored Studio refresh probe failed: " .. tostring(err), 2)
      S.has_stored_refresh = false
      S.refresh_token = ""
      return false, err
    end
    if type(token) == "string" and token ~= "" then
      S.refresh_token = token
      S.has_stored_refresh = true
      return true, nil
    end
    S.has_stored_refresh = false
    S.refresh_token = ""
    return false, nil
  end

  local function auth_finish_failed(rec, payload, fallback)
    local err_txt = tostring((payload and (payload.api_error or payload.error)) or fallback or t("Studio auth failed."))
    rec._state = "failed_final"
    rec._next_retry_at = nil
    rec._last_error_summary = err_txt
    S.status_text = err_txt
    S.last_api_error = err_txt
    TelemetryBridge.operation_failed("studio_neurocast_auth", {
      endpoint = tostring(payload and payload.endpoint or ""),
      http_code = payload and payload.http_code or nil,
      safe_message = err_txt,
      backend_base_url = Backend.active_base_url()
    }, nil, "operation_failed")
    return false, err_txt
  end

  local function auth_finish_ok(rec, payload, status_text)
    Auth.apply_token_payload(payload)
    if S.remember_login then
      Auth.persist_email(S.email)
      Auth.persist_refresh_backend_base()
      S.has_stored_refresh = S.refresh_token ~= ""
    else
      Auth.client().forget_refresh_token()
      Auth.forget_email()
      Auth.forget_refresh_backend_base()
      S.has_stored_refresh = false
    end
    rec._state = "ok"
    rec._next_retry_at = nil
    S.password = ""
    S.status_text = status_text or t("Studio login refreshed.")
    S.last_api_error = ""
    TelemetryBridge.operation_completed("studio_neurocast_auth", {
      endpoint = tostring(payload and payload.endpoint or ""),
      http_code = payload and payload.http_code or nil,
      backend_base_url = Backend.active_base_url(),
      remembered = S.remember_login == true
    })
    return true, nil
  end

  function Auth.request_login(on_done)
    local email = Util.trim(S.email or "")
    local password = tostring(S.password or "")
    if email == "" then
      local err_txt = t("Studio login email is required.")
      S.status_text = err_txt
      S.last_api_error = err_txt
      if type(on_done) == "function" then on_done(false, { error = err_txt }) end
      return false, err_txt
    end
    if password == "" then
      local err_txt = t("Studio login password is required.")
      S.status_text = err_txt
      S.last_api_error = err_txt
      if type(on_done) == "function" then on_done(false, { error = err_txt }) end
      return false, err_txt
    end

    S.email = email
    local rec = get_or_create_misc_record("studio_auth_login", t("Studio login"), t("Studio login"))
    rec._state = "running"
    rec._next_retry_at = nil
    rec._last_error_summary = ""
    TelemetryBridge.operation_started("studio_neurocast_auth", {
      endpoint = "login",
      backend_base_url = Backend.active_base_url(),
      remembered = S.remember_login == true
    })

    local client = Auth.client()
    local job, err = client.submit_login(email, password, function(payload)
      if payload and payload.ok then
        auth_finish_ok(rec, payload, t("Studio login ok."))
        Eleven.notify_voice_library_account_changed()
        if type(on_done) == "function" then on_done(true, payload) end
        Eleven.auto_fetch_el_data_on_startup()
        return
      end
      auth_finish_failed(rec, payload, t("Studio login failed."))
      if type(on_done) == "function" then on_done(false, payload) end
    end, auth_submit_opts())
    if not job then
      local payload = { endpoint = "login", error = err or t("Could not start Studio login request.") }
      auth_finish_failed(rec, payload, payload.error)
      if type(on_done) == "function" then on_done(false, payload) end
      return false, payload.error
    end
    job.keep_in_list = true
    rec.misc_job_id = job.id
    S.status_text = t("Studio login request submitted.")
    return true, nil
  end

  function Auth.request_refresh(flow_label, on_done, opts)
    opts = opts or {}
    local rec = get_or_create_misc_record("studio_auth_refresh", flow_label or t("Studio login refresh"), flow_label or t("Studio login refresh"))
    rec._state = "running"
    rec._next_retry_at = nil
    rec._last_error_summary = ""
    TelemetryBridge.operation_started("studio_neurocast_auth", {
      endpoint = "refresh",
      backend_base_url = Backend.active_base_url(),
      remembered = S.remember_login == true
    })

    local client = Auth.client()
    local callback_finished = false
    local function notify_done(ok, payload)
      if callback_finished then return end
      callback_finished = true
      if type(on_done) == "function" then on_done(ok, payload) end
    end
    local job, err = client.submit_refresh(function(payload)
      if payload and payload.ok then
        auth_finish_ok(rec, payload, t("Studio login refreshed."))
        notify_done(true, payload)
        if opts.fetch_catalog_after ~= false then
          Eleven.auto_fetch_el_data_on_startup()
        end
        return
      end
      local refresh_http = tonumber(payload and payload.http_code or 0)
      if NeurocastAuth.is_invalid_refresh_http_status(refresh_http) then
        client.clear_runtime_tokens()
        client.forget_refresh_token()
        Auth.forget_refresh_backend_base()
        S.access_token = ""
        S.has_stored_refresh = false
        S.refresh_token = ""
      end
      auth_finish_failed(rec, payload, t("Studio login refresh failed."))
      notify_done(false, payload)
    end, auth_submit_opts())
    if not job then
      local payload = { endpoint = "refresh", error = err or t("Could not start Studio refresh request.") }
      if not callback_finished then
        auth_finish_failed(rec, payload, payload.error)
        notify_done(false, payload)
      end
      return false, payload.error
    end
    job.keep_in_list = true
    rec.misc_job_id = job.id
    S.status_text = t("Studio refresh request submitted.")
    return true, nil
  end

  function Auth.refresh_after_401(rec, resubmit_fn, on_failure)
    if type(rec) ~= "table" then
      return false, t("Studio request record is missing.")
    end
    if rec._auth_refresh_used_once == true then
      return false, t("Studio login refresh was already attempted for this request.")
    end
    if type(resubmit_fn) ~= "function" then
      return false, t("Studio request cannot be resubmitted after refresh.")
    end

    rec._auth_refresh_used_once = true
    local refresh_label = string.format(
      t("Refresh before %s"),
      tostring(rec.flow_label or rec.record_name or rec._retry_label or t("Studio request"))
    )
    local queued, queue_err = AUTH_REFRESH_GATE.request(
      function(done)
        return Auth.request_refresh(refresh_label, function(ok, payload)
          done(ok, payload)
        end, { fetch_catalog_after = false })
      end,
      function(refresh_payload)
        local ok_submit, submit_err = resubmit_fn()
        if not ok_submit and type(on_failure) == "function" then
          on_failure(
            string.format(
              t("Studio login refreshed, but the request could not be resubmitted: %s"),
              tostring(submit_err or t("unknown error"))
            ),
            refresh_payload
          )
        end
      end,
      function(refresh_payload)
        if type(on_failure) == "function" then
          local raw_err = (refresh_payload and (refresh_payload.api_error or refresh_payload.error)) or
            t("refresh failed")
          on_failure(
            string.format(t("Studio login refresh failed: %s"), tostring(raw_err)),
            refresh_payload
          )
        end
      end
    )
    if not queued and AUTH_REFRESH_GATE.is_in_flight() ~= true then
      return false, queue_err or t("Studio login refresh could not be started.")
    end
    return true, nil
  end

  function Auth.refresh_proactively_if_due(rec, resubmit_fn, on_failure)
    if type(rec) ~= "table" or type(resubmit_fn) ~= "function" then
      return false, nil
    end

    local timing, timing_err = Auth.client().access_token_refresh_status(S.access_token)
    if not timing then
      return false, timing_err
    end
    if timing.refresh_due ~= true then
      return false, nil
    end

    rec._state = "refreshing"
    rec._next_retry_at = nil
    local refresh_label = string.format(
      t("Refresh before %s"),
      tostring(rec.flow_label or rec.record_name or rec._retry_label or t("Studio request"))
    )
    local queued, queue_err = AUTH_REFRESH_GATE.request(
      function(done)
        return Auth.request_refresh(refresh_label, function(ok, payload)
          done(ok, payload)
        end, { fetch_catalog_after = false })
      end,
      function(refresh_payload)
        local ok_submit, submit_err = resubmit_fn()
        if not ok_submit and type(on_failure) == "function" then
          on_failure(
            string.format(
              t("Studio login refreshed, but the request could not be submitted: %s"),
              tostring(submit_err or t("unknown error"))
            ),
            refresh_payload
          )
        end
      end,
      function(refresh_payload)
        if type(on_failure) == "function" then
          local raw_err = (refresh_payload and (refresh_payload.api_error or refresh_payload.error)) or
            t("refresh failed")
          on_failure(
            string.format(t("Studio login refresh failed: %s"), tostring(raw_err)),
            refresh_payload
          )
        end
      end
    )
    if not queued and AUTH_REFRESH_GATE.is_in_flight() ~= true then
      return false, queue_err or t("Studio login refresh could not be started.")
    end
    return true, nil
  end

  function Auth.forget_stored_login()
    local client = Auth.client()
    client.forget_refresh_token()
    Auth.forget_email()
    Auth.forget_refresh_backend_base()
    Auth.clear_runtime_tokens()
    Eleven.notify_voice_library_account_changed()
    S.has_stored_refresh = false
    S.status_text = t("Stored Studio login cleared.")
    S.last_api_error = ""
    TelemetryBridge.operation_completed("studio_neurocast_auth", {
      endpoint = "forget_stored_login",
      backend_base_url = Backend.active_base_url()
    })
  end

  function Auth.load_login_on_startup()
    local email = Auth.load_email_from_ext_state()
    if email then S.email = email end
    Auth.sync_stored_refresh_flag()
  end

  function Auth.try_auto_login_on_startup()
    Auth.load_login_on_startup()
    if not S.has_stored_refresh then
      S.status_text = t("No stored Studio login. Please log in.")
      return
    end
    Jobs.schedule_job(t("Refresh Studio login"), function()
      Auth.request_refresh(t("Startup Studio refresh"), nil, { fetch_catalog_after = true })
    end)
  end

  -- Fetches ElevenLabs models so later steps can use it.
  -- Called by `auto_fetch_el_data_on_startup` and `GuiLoop`; caller passes no arguments and uses shared state.
  function Eleven.fetch_el_models()
    local ok_auth, auth_msg = Auth.ensure_access_token()
    if not ok_auth then
      S.status_text = auth_msg
      S.last_api_error = auth_msg
      return
    end

    local max_attempts = tonumber(CFG.retry_max_attempts_misc) or 3
    local rec = get_or_create_misc_record("el_models", t("Fetch models"), t("Fetch models"))
    local base_label = rec.record_name or t("Fetch models")
    rec._attempt = 1
    rec._max_attempts = max_attempts
    rec._auth_refresh_used_once = false
    rec._retry_generation = S.retry_generation
    rec._retry_label = base_label

    local function submit_once()
      if rec._state == "canceled" then
        return false, "canceled"
      end
      rec._state = "running"
      rec._next_retry_at = nil
      local attempt = rec._attempt or 1

      local req, req_err = Backend.client():models_request(
        Jobs.format_attempt_label(base_label, attempt, max_attempts),
        120
      )
      if not req then
        return Backend.request_build_failed(rec, req_err)
      end

      local opts = {
        read_body = true,
        keep_output = false,
        body_max_bytes = CFG.el_catalog_body_max_bytes
      }

      local function on_done(result, job)
        if rec._state == "canceled" then return end
        Curl.update_last_curl_state(result, job, "Fetch Models")
        if result.ok and result.body and result.body ~= "" then
          local ok, decoded = pcall(json.decode, result.body)
          if ok and type(decoded) == "table" then
            local count = (type(decoded) == "table") and #decoded or 0
            S.el_models = {
              fetched_at = os.date("%Y-%m-%d %H:%M:%S"),
              http_code = result.http_code,
              count = count,
              models = decoded
            }
            Eleven.resolve_tts_model_selection()
            S.status_text = string.format(t("Models fetched (%s)."), tostring(count))
            S.last_api_error = ""
            rec._state = "ok"
            rec._next_retry_at = nil
            cleanup_el_response(result)
            return
          end
          local err_txt = t("Models response JSON decode failed.")
          result.ok = false
          result.err = err_txt
        else
          local err_txt = Eleven.summarize_el_error(result)
          result.err = err_txt
        end

        local err_txt = result.err or t("Models request failed.")
        local snippet = Util.clip_body_text(result.body or err_txt, 512)
        Jobs.update_record_retry_state(rec, err_txt, result, snippet)
        local retryable = Jobs.is_retryable_result(result)
        if rec._retry_generation ~= S.retry_generation then retryable = false end
        local attempt_now = rec._attempt or 1
        if retryable and attempt_now < max_attempts then
          local next_attempt = attempt_now + 1
          rec._attempt = next_attempt
          Jobs.enqueue_retry(rec._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec)
          S.last_api_error = err_txt
          S.status_text = string.format(t("Models request failed (retrying): %s"), err_txt)
        else
          rec._state = "failed_final"
          rec._next_retry_at = nil
          S.last_api_error = err_txt
          S.status_text = string.format(t("Models request failed: %s"), err_txt)
        end
        cleanup_el_response(result)
      end

      local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
        rec = rec,
        operation = "elevenlabs_fetch_models",
        capture_response_body = true
      })
      if not job then
        local err_txt = string.format(t("Models request failed to start: %s"), tostring(err))
        rec._state = "failed_final"
        rec._next_retry_at = nil
        rec._last_error_summary = err_txt
        S.status_text = err_txt
        S.last_api_error = err_txt
        return false, err_txt
      end
      job.keep_in_list = true
      rec.misc_job_id = job.id
      return true
    end

    rec._retry_submit = submit_once
    local ok_submit, _ = submit_once()
    if not ok_submit then
      return
    end
    S.status_text = t("Models request submitted.")
  end

  function Eleven.commit_el_voice_catalog(catalog)
    if type(catalog) ~= "table" or type(catalog.by_id) ~= "table" then
      return false, t("Voice catalog is invalid.")
    end
    local previous_selected_id = tostring(S.el_voice_selected_id or "")
    local selected_id_before_commit = previous_selected_id
    S.el_voices = catalog
    local previous_filters = S.el_voice_filters or VoiceCatalog.empty_filters()
    local reconciled_filters = VoiceCatalog.reconcile_filters(catalog, previous_filters)
    for _, key in ipairs({ "origin", "language", "accent", "gender", "age", "use_case" }) do
      if tostring(previous_filters[key] or "") ~= tostring(reconciled_filters[key] or "") then
        S.el_voice_selection_cleared_by_filter = true
        previous_selected_id = ""
        break
      end
    end
    S.el_voice_filters = reconciled_filters
    for name, voice_id in pairs(S.voice_choice_by_name or {}) do
      local valid = false
      for _, voice in ipairs(catalog.by_name[name] or {}) do
        if voice.id == voice_id then
          valid = true
          break
        end
      end
      if not valid then
        S.voice_choice_by_name[name] = nil
      end
    end
    if S.el_voice_selection_cleared_by_filter then
      S.el_voice_selected_id = ""
    elseif previous_selected_id ~= "" and catalog.by_id[previous_selected_id] then
      S.el_voice_selected_id = previous_selected_id
    elseif catalog.voices[1] then
      S.el_voice_selected_id = catalog.voices[1].id
    else
      S.el_voice_selected_id = ""
    end
    if selected_id_before_commit ~= tostring(S.el_voice_selected_id or "") then
      Eleven.stop_voice_preview("account_voices")
    end
    return true
  end

  -- Fetches ElevenLabs voices so later steps can use it.
  -- Called by `auto_fetch_el_data_on_startup` and `GuiLoop`; caller passes no arguments and uses shared state.
  function Eleven.fetch_el_voices(opts)
    opts = opts or {}
    local ok_auth, auth_msg = Auth.ensure_access_token()
    if not ok_auth then
      S.status_text = auth_msg
      S.last_api_error = auth_msg
      if type(opts.on_error) == "function" then
        opts.on_error(auth_msg)
      end
      return false, auth_msg
    end
    local account_generation_snapshot = S.el_voice_library_account_generation

    local on_success = opts.on_success
    local on_error = opts.on_error
    local should_commit = opts.commit ~= false
    local aggregate_only = opts.aggregate_only == true
    local search = VoiceCatalog.trim_name(opts.search)
    local purpose = tostring(opts.purpose or (search ~= "" and "search" or "catalog"))
    local misc_key
    if aggregate_only then
      misc_key = search ~= "" and
        "el_voice_library_add_name_check" or
        "el_voice_library_add_refresh"
    else
      misc_key = search ~= "" and "el_voice_search" or "el_voices"
    end
    local telemetry_operation =
      search ~= "" and "elevenlabs_search_voices" or "elevenlabs_fetch_voices"
    local telemetry_started_at = TelemetryBridge.now()
    if not aggregate_only then
      TelemetryBridge.operation_started(telemetry_operation, {
        search_mode = search ~= "",
        purpose = purpose
      })
    end

    local max_attempts = tonumber(CFG.retry_max_attempts_misc) or 3
    local rec = get_or_create_misc_record(misc_key, t("Fetch voices"), t("Fetch voices"))
    local base_label = rec.record_name or t("Fetch voices")
    rec._attempt = 1
    rec._max_attempts = max_attempts
    rec._auth_refresh_used_once = false
    rec._retry_generation = S.retry_generation
    rec._retry_label = base_label
    rec._voice_fetch_generation = (rec._voice_fetch_generation or 0) + 1
    local fetch_generation = rec._voice_fetch_generation

    local staged_voices = {}
    local staged_ids = {}
    local next_page_token = nil
    local seen_page_tokens = {}
    local page_number = 1
    local total_count = nil
    local last_http_code = nil
    local finished = false

    local function is_current_fetch()
      return rec._voice_fetch_generation == fetch_generation and not finished
    end

    local function progress_text()
      local total = total_count and tostring(total_count) or "?"
      return string.format(t("Fetching voices: %d of %s"), #staged_voices, total)
    end

    local function finish_error(err_txt, failure_kind)
      if finished then return end
      finished = true
      rec._state = "failed_final"
      rec._next_retry_at = nil
      rec._last_error_summary = err_txt
      S.last_api_error = err_txt
      S.status_text = string.format(t("Voices request failed: %s"), err_txt)
      if not aggregate_only then
        TelemetryBridge.operation_failed(telemetry_operation, {
          safe_message = tostring(err_txt or ""),
          page_number = page_number,
          staged_count = #staged_voices,
          search_mode = search ~= "",
          purpose = purpose
        }, telemetry_started_at, failure_kind or "request_failed")
      end
      if type(on_error) == "function" then
        on_error(err_txt)
      end
    end

    local function finish_account_changed()
      if finished then return end
      finished = true
      rec._state = "canceled"
      rec._next_retry_at = nil
      if not aggregate_only then
        TelemetryBridge.operation_canceled(telemetry_operation, {
          page_number = page_number,
          staged_count = #staged_voices,
          search_mode = search ~= "",
          purpose = purpose,
          cancellation_reason = "account_changed"
        }, telemetry_started_at)
      end
      if type(on_error) == "function" then
        on_error(t("Voice request canceled because the ElevenLabs account changed."))
      end
    end

    local function finish_success()
      if finished then return end
      if S.el_voice_library_account_generation ~= account_generation_snapshot then
        finish_account_changed()
        return
      end
      finished = true
      local catalog = VoiceCatalog.build(staged_voices)
      catalog.fetched_at = os.date("%Y-%m-%d %H:%M:%S")
      catalog.http_code = last_http_code
      catalog.total_count = total_count
      catalog.search = search ~= "" and search or nil

      if should_commit then
        Eleven.commit_el_voice_catalog(catalog)
      end

      rec._state = "ok"
      rec._next_retry_at = nil
      if search ~= "" then
        S.status_text = t("Voice name check completed.")
      else
        S.status_text = string.format(t("Voices fetched (%s)."), tostring(catalog.count))
      end
      S.last_api_error = ""
      if not aggregate_only then
        TelemetryBridge.operation_completed(telemetry_operation, {
          page_count = page_number,
          voice_count = catalog.count,
          duplicate_name_count = catalog.duplicate_name_count,
          duplicate_voice_count = catalog.duplicate_voice_count,
          search_mode = search ~= "",
          purpose = purpose
        }, telemetry_started_at)
      end
      if type(on_success) == "function" then
        on_success(catalog)
      end
    end

    local submit_page

    submit_page = function()
      if rec._state == "canceled" or not is_current_fetch() then
        return false, "canceled"
      end
      if S.el_voice_library_account_generation ~= account_generation_snapshot then
        finish_account_changed()
        return false, "account_changed"
      end
      rec._state = "running"
      rec._next_retry_at = nil
      local attempt = rec._attempt or 1

      local query = {
        "page_size=" .. tostring(tonumber(CFG.el_voice_page_size) or 100),
        "include_total_count=" .. (page_number == 1 and "true" or "false")
      }
      if search ~= "" then
        query[#query + 1] = "search=" .. Util.url_encode_path_segment(search)
      end
      if next_page_token and next_page_token ~= "" then
        query[#query + 1] = "next_page_token=" .. Util.url_encode_path_segment(next_page_token)
      end

      local req, req_err = Backend.client():voices_request({
        page_size = tonumber(CFG.el_voice_page_size) or 100,
        include_total_count = page_number == 1 and "true" or "false",
        search = search ~= "" and search or nil,
        next_page_token = next_page_token and next_page_token ~= "" and next_page_token or nil
      }, Jobs.format_attempt_label(
          string.format(t("Fetch voices (page %d)"), page_number),
          attempt,
          max_attempts
        ), 120)
      if not req then
        return Backend.request_build_failed(rec, req_err)
      end

      local curl_opts = {
        read_body = true,
        keep_output = false,
        body_max_bytes = CFG.el_catalog_body_max_bytes
      }

      local function on_done(result, job)
        if rec._state == "canceled" or not is_current_fetch() then return end
        if S.el_voice_library_account_generation ~= account_generation_snapshot then
          cleanup_el_response(result)
          finish_account_changed()
          return
        end
        if aggregate_only then
          S.last_http = tostring(result and result.http_code or "")
          S.last_curl_return = {
            ok = result and result.ok == true or false,
            http = result and result.http_code or "",
            body = "",
            headers_txt = "",
            meta = "",
            err = result and result.ok == true and "" or t("Voice request failed."),
            cmd = t("Fetch voices")
          }
        else
          Curl.update_last_curl_state(result, job, "Fetch Voices")
        end
        if result.ok and result.body and result.body ~= "" then
          local ok, decoded = pcall(json.decode, result.body)
          if ok and type(decoded) == "table" and type(decoded.voices) == "table" then
            local voices = decoded.voices
            local page_error = nil
            local page_voices = {}
            local page_ids = {}
            for _, v in ipairs(voices) do
              local vid = type(v) == "table" and (v.voice_id or v.voiceId or v.id) or ""
              vid = tostring(vid or "")
              if vid == "" then
                page_error = t("Voices response contained a voice without an ID.")
                break
              elseif not staged_ids[vid] and not page_ids[vid] then
                page_ids[vid] = true
                page_voices[#page_voices + 1] = v
              end
            end
            if page_error then
              result.ok = false
              result.err = page_error
            else
              for _, voice in ipairs(page_voices) do
                local voice_id = tostring(voice.voice_id or voice.voiceId or voice.id)
                staged_ids[voice_id] = true
                staged_voices[#staged_voices + 1] = voice
              end
              last_http_code = result.http_code
              local decoded_total = tonumber(decoded.total_count)
              if total_count == nil and decoded_total and decoded_total >= 0 then
                total_count = decoded_total
              end
              S.status_text = progress_text()
              cleanup_el_response(result)

              local has_more = decoded.has_more == true
              local candidate_token = tostring(decoded.next_page_token or "")
              if has_more then
                if candidate_token == "" or seen_page_tokens[candidate_token] then
                  finish_error(t("Voices response contained an invalid pagination token."), "pagination_failed")
                  return
                end
                seen_page_tokens[candidate_token] = true
                next_page_token = candidate_token
                page_number = page_number + 1
                rec._attempt = 1
                rec._retry_label = base_label
                submit_page()
              else
                finish_success()
              end
              return
            end
          end
          if result.ok then
            local err_txt
            if ok and type(decoded) == "table" then
              err_txt = t("Voices response did not contain a voices array.")
            else
              err_txt = t("Voices response JSON decode failed.")
            end
            result.ok = false
            result.err = err_txt
          end
        else
          local err_txt
          if aggregate_only then
            err_txt = t("Voice request failed.")
          else
            err_txt = Eleven.summarize_el_error(result)
          end
          result.err = err_txt
        end

        local err_txt = result.err or t("Voices request failed.")
        local snippet = aggregate_only and err_txt or
          Util.clip_body_text(result.body or err_txt, 512)
        Jobs.update_record_retry_state(rec, err_txt, result, snippet)
        local retryable = Jobs.is_retryable_result(result)
        if rec._retry_generation ~= S.retry_generation then retryable = false end
        local attempt_now = rec._attempt or 1
        if retryable and attempt_now < max_attempts then
          local next_attempt = attempt_now + 1
          rec._attempt = next_attempt
          local retry_label = string.format(t("Fetch voices (page %d)"), page_number)
          rec._retry_label = retry_label
          Jobs.enqueue_retry(retry_label, submit_page, next_attempt, max_attempts, err_txt, rec)
          S.last_api_error = err_txt
          S.status_text = string.format(
            t("Voice page %d failed (retrying): %s"),
            page_number,
            err_txt
          )
        else
          finish_error(err_txt)
        end
        cleanup_el_response(result)
      end

      local submit_catalog_request =
        aggregate_only and Curl.curl_submit or TelemetryBridge.submit_curl
      local job, err = submit_catalog_request(req, on_done, curl_opts, {
        rec = rec,
        operation = telemetry_operation,
        capture_response_body = not aggregate_only,
        extra_payload = {
          page_number = page_number,
          staged_count = #staged_voices,
          search_mode = search ~= "",
          purpose = purpose
        }
      })
      if not job then
        local err_txt = string.format(t("Voices request failed to start: %s"), tostring(err))
        finish_error(err_txt, "request_start_failed")
        return false, err_txt
      end
      job.keep_in_list = true
      rec.misc_job_id = job.id
      return true
    end

    rec._retry_submit = submit_page
    S.status_text = progress_text()
    local ok_submit, submit_err = submit_page()
    if not ok_submit then
      if not finished then
        finish_error(submit_err or t("Voices request failed to start."), "request_start_failed")
      end
      return false, submit_err
    end
    return true
  end

  function Eleven.check_voice_name_available(name, callbacks)
    callbacks = callbacks or {}
    local trimmed_name = VoiceCatalog.trim_name(name)
    if trimmed_name == "" then
      local err_txt = t("Voice name is required.")
      if type(callbacks.on_error) == "function" then callbacks.on_error(err_txt) end
      return false, err_txt
    end

    return Eleven.fetch_el_voices({
      search = trimmed_name,
      commit = false,
      purpose = "voice_name_uniqueness",
      aggregate_only = callbacks.aggregate_only == true,
      on_success = function(catalog)
        if VoiceCatalog.name_exists_exact(catalog, trimmed_name) then
          if type(callbacks.on_duplicate) == "function" then
            callbacks.on_duplicate(trimmed_name, catalog)
          end
        elseif type(callbacks.on_available) == "function" then
          callbacks.on_available(trimmed_name, catalog)
        end
      end,
      on_error = function(err_txt)
        if type(callbacks.on_error) == "function" then
          callbacks.on_error(err_txt)
        end
      end
    })
  end
end --end of "do --some API helpers (ElevenLabs, OpenAI) and curl somehow"

--=================== Scheduler and button helpers =================
math.randomseed(os.time())

function Jobs.is_openai_refusal_error(err_txt)
  if not err_txt or err_txt == "" then return false end
  return err_txt:find("Model refused", 1, true) ~= nil
end

function Jobs.full_reset_state(reason)
  Eleven.stop_voice_preview()
  local reset_started_at = TelemetryBridge.now()
  local reset_reason = reason or "reset state"
  TelemetryBridge.operation_started("elevenlabs_reset_runtime", {
    reason = reset_reason,
    reset_scope = "workflow"
  })
  Jobs.reset_runtime({
    reason = reset_reason,
    scope = "workflow"
  })
  S.stop_polling_flag = false
  S.next_poll_at = nil
  S.rendered_regions = nil
  S.render_regions_output = t("Press the button to list render regions.")
  S.tts_records = nil
  S.fast_tts_records = nil
  S.fast_sts_records = nil
  S.voice_design_records = nil
  S.voice_create_records = nil
  S.ivc_create_records = nil
  S.ivc_batch_ui = nil
  S.openai_records = nil
  S.misc_records = nil
  S.curl_jobs_selected_id = nil
  S.pending_job = nil
  S.wait_until = nil
  S.running_label = nil
  S.voice_resolver = nil
  S.voice_flow_approval = nil
  S.ui_lock_network_buttons = false
  UI.rebuild_warnings()
  TelemetryBridge.operation_completed("elevenlabs_reset_runtime", {
    reason = reset_reason,
    reset_scope = "workflow"
  }, reset_started_at)
end

--===============BUTTONS (and guarded buttons) helpers =================
do --UI buttons
  local button_last_click_at = {}
  local guard_button_last_click_at = {}
  -- Handles a button click so we can throttle actions and avoid double runs.
  -- Called by `GuiLoop`; caller passes the required inputs (for example `id`, `label`).
  function UI.button_clicked(id, label, cooldown_override, ctx_override)
    if not ctx_override then
      ctx_override = ctx
    end
    local key = id or label
    local cooldown = tonumber(cooldown_override) or tonumber(CFG.button_cooldown_sec or 0) or 0
    local last = button_last_click_at[key]
    local now_t = Jobs.now()
    -- Draw the button regardless, but ignore clicks inside cooldown window.
    local clicked = ImGui.Button(ctx_override, label)
    if not clicked then return false end
    if last and (now_t - last) < cooldown then
      return false
    end
    button_last_click_at[key] = now_t
    if telemetry_should_track_button(id) then
      TelemetryBridge.button_clicked(id, label)
    end
    return true
  end

  -- Handles a guarded button click so users see the cooldown.
  -- Called by `GuiLoop`; caller passes the required inputs (for example `id`, `base_label`).
  -- Disable a button during cooldown and show a countdown-friendly label.
  -- Useful for buttons that trigger network calls and need a short guard.
  function UI.guard_with_timer_button_clicked(id, base_label, cooldown_override, externally_disabled)
    local key = id or base_label
    local cooldown =
      tonumber(cooldown_override) or
      tonumber(CFG.manual_status_check_cooldown_sec) or
      tonumber(CFG.button_cooldown_sec) or
      0
    local now_t = Jobs.now()
    local last = guard_button_last_click_at[key]
    local remaining = 0
    if last then
      remaining = cooldown - (now_t - last)
      if remaining < 0 then remaining = 0 end
    end

    local label = base_label
    local suffix = t("N/A")
    if remaining > 0 then
      local approx_seconds = math.max(0, remaining)
      suffix = string.format(t("Wait %.3f sec"), approx_seconds)
      -- label = string.format("[%s] %s", base_label, suffix)
    end

    local disabled = externally_disabled or (remaining > 0)
    if disabled then
      ImGui.BeginDisabled(ctx, true)
    end

    local clicked = ImGui.Button(ctx, label)
    if disabled then
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, suffix)
    end

    if disabled then
      ImGui.EndDisabled(ctx)
    end

    if clicked and (remaining <= 0) and (not externally_disabled) then
      guard_button_last_click_at[key] = now_t
      if telemetry_should_track_button(id) then
        TelemetryBridge.button_clicked(id, base_label)
      end
      return true
    end
    return false
  end
end --UI buttons

--================ Startup settings persistence ===================

-- Loads status window visibility on startup so UI honors user preference.
-- Called during startup; caller passes no arguments and uses shared state.
function UI.load_show_status_window_on_startup()
  local stored = UI.load_show_status_window_from_ext_state()
  if stored ~= nil then
    S.show_status_window = stored
  end
end --function UI.load_show_status_window_on_startup()

-- Loads runtime locale on startup so later UI/messages use the persisted language.
-- Called during startup; caller passes no arguments and uses shared state.
function UI.load_locale_on_startup()
  local stored = UI.load_locale_from_ext_state()
  set_active_runtime_locale(stored or "eng")
end --function UI.load_locale_on_startup()

-- Loads the preferred TTS model before the startup catalog fetch.
function UI.load_tts_model_preference_on_startup()
  local stored = UI.load_tts_model_preference_from_ext_state()
  if stored then
    S.el_tts_model_preferred = stored
    S.el_tts_model_selected = stored
  end
end --function UI.load_tts_model_preference_on_startup()

-- Loads persisted STS UI/runtime settings on startup.
-- Called during startup; caller passes no arguments and uses shared state.
function UI.load_sts_settings_on_startup()
  local merge_gap = UI.load_sts_merge_gap_sec_from_ext_state()
  if merge_gap ~= nil then
    CFG.sts_merge_gap_sec = merge_gap
  end

  local max_region_length = UI.load_sts_max_region_length_sec_from_ext_state()
  if max_region_length ~= nil then
    CFG.sts_max_region_length_sec = max_region_length
  end

  local send_each_item = UI.load_sts_send_each_item_separately_from_ext_state()
  if send_each_item ~= nil then
    CFG.sts_send_each_item_separately = send_each_item == true
  end
end --function UI.load_sts_settings_on_startup()

function UI.load_backend_base_url_override_on_startup()
  local override = UI.load_backend_base_url_override_from_ext_state()
  S.backend_base_url_override = override or ""
  CFG.backend_base_url_override = S.backend_base_url_override
end --function UI.load_backend_base_url_override_on_startup()

-- Fetches auto ElevenLabs data on startup so later steps can use it.
-- Called during startup; caller passes no arguments and uses shared state.
function Eleven.auto_fetch_el_data_on_startup()
  local auto_started_at = TelemetryBridge.now()
  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    S.status_text = string.format(t("Auto-fetch skipped: %s"), auth_msg)
    S.last_api_error = auth_msg
    TelemetryBridge.operation_canceled("elevenlabs_auto_fetch", {
      reason = "missing_studio_login"
    }, auto_started_at)
    return
  end
  TelemetryBridge.operation_started("elevenlabs_auto_fetch", {
    has_studio_access_token = true,
    backend_base_url = Backend.active_base_url()
  })
  Eleven.fetch_el_models()
  Eleven.fetch_el_voices()
  TelemetryBridge.operation_completed("elevenlabs_auto_fetch", {
    submitted_models = true,
    submitted_voices = true
  }, auto_started_at)
end --function Eleven.auto_fetch_el_data_on_startup()


--================UI functions=======================
-- Shows warning in the UI so the user can see it.
-- Called by `GuiLoop`; caller passes `text` and `ctx_to_show`.
function UI.ui_warning(text, ctx_to_show)
  if not ctx_to_show then ctx_to_show = ctx end
  ImGui.PushStyleColor(ctx_to_show, ImGui.Col_Text, 0xFFB000FF) -- RGBA
  ImGui.TextWrapped(ctx_to_show, string.format(t("⚠  %s"), text))
  ImGui.PopStyleColor(ctx_to_show)
end

-- Shows info in the UI so the user can see it.
-- Called by `GuiLoop`; caller passes `text` and `ctx_to_show`.
function UI.ui_info(text, ctx_to_show)
  if not ctx_to_show then ctx_to_show = ctx end
  ImGui.TextWrapped(ctx_to_show, text)
end

-- Renders the status + warnings panel so it can live in a window or inline.
-- Called by `GuiLoop`; caller passes `ctx_to_show` and `id_suffix`.
function UI.render_status_panel(ctx_to_show, id_suffix)
  if not ctx_to_show then ctx_to_show = ctx end
  local suffix = id_suffix and tostring(id_suffix) or ""
  ImGui.PushFont(ctx_to_show, FONT, font_size)
  local summary = UI.build_status_summary()
  local status_line = (summary and summary.status_line) or ""
  local counts = (summary and summary.counts) or {}
  local warning_count = (type(S.warnings) == "table" and #S.warnings) or 0
  local failed_count = tonumber(counts.failed) or 0
  local has_failed = (failed_count > 0) or Util.is_non_empty(S.last_api_error)
  local has_in_process =
    ((tonumber(counts.queued) or 0) > 0) or
    ((tonumber(counts.running) or 0) > 0) or
    ((tonumber(counts.retrying) or 0) > 0)
  if (warning_count > 0) or has_failed then
    ImGui.PushStyleColor(ctx_to_show, ImGui.Col_Text, 0xFF0000FF) -- red
  elseif has_in_process then
    ImGui.PushStyleColor(ctx_to_show, ImGui.Col_Text, 0x66CCFFFF) -- light blue
  else
    ImGui.PushStyleColor(ctx_to_show, ImGui.Col_Text, 0x00FF00FF) -- green
  end

  ImGui.Text(ctx_to_show, string.format(t("Status: %s"), status_line))
  ImGui.PopStyleColor(ctx_to_show)

  local last_status = S.status_text or ""
  if last_status == "" then last_status = t("(none)") end
  ImGui.TextWrapped(ctx_to_show, string.format(t("Last status: %s"), last_status))

  -- Warnings list
  ImGui.PushStyleVar(ctx_to_show, ImGui.StyleVar_SeparatorTextAlign, 0.15, 0.5)
  ImGui.SeparatorText(ctx_to_show, t("Warnings"))
  ImGui.PopStyleVar(ctx_to_show)
  if #S.warnings == 0 then
    UI.ui_info(t("None. Looks good!"), ctx_to_show)
  else
    for _, w in ipairs(S.warnings) do
      UI.ui_warning(w, ctx_to_show)
    end
  end
  if UI.button_clicked("clear_warnings_btn" .. suffix, t("Clear warnings"), nil, ctx_to_show) then
    S.warnings = {}
  end
  ImGui.SameLine(ctx_to_show)
  if UI.button_clicked("copy_warnings_btn" .. suffix, t("Copy warnings to clipboard"), nil, ctx_to_show) then
    local warning_lines = {}
    if type(S.warnings) == "table" then
      for i = 1, #S.warnings do
        warning_lines[#warning_lines + 1] = tostring(S.warnings[i])
      end
    end
    local warnings_text = table.concat(warning_lines, "\n")
    ImGui.SetClipboardText(ctx_to_show, warnings_text)
  end
  ImGui.PopFont(ctx_to_show)
end

-- Shows print out last curl return in the UI so the user can see it.
-- Called by `GuiLoop`; caller passes no arguments and uses shared state.
function UI.ui_print_out_last_curl_return()
  local last_curl_return = S.last_curl_return
  local all_lines =
    string.format(t("ok: %s"), tostring(last_curl_return.ok)) .. '\n' ..
    string.format(t("http: %s"), tostring(last_curl_return.http)) .. '\n' ..
    string.format(t("body: %s"), Util.head32(tostring(last_curl_return.body))) .. '\n' ..
    string.format(t("headers: %s"), Util.head32(tostring(last_curl_return.headers_txt))) .. '\n' ..
    string.format(t("meta: %s"), Util.head32(tostring(last_curl_return.meta))) .. '\n' ..
    string.format(t("err: %s"), tostring(last_curl_return.err)) .. '\n' ..
    string.format(t("cmd: %s"), tostring(last_curl_return.cmd))
    local flags = ImGui.InputTextFlags_ReadOnly
    ImGui.InputTextMultiline(ctx, "##curl_last_status", all_lines, 0, 0, flags)
end --function UI.ui_print_out_last_curl_return()

local MAIN_WINDOW_MIN_EXPANDED_HEIGHT = 64
local main_window_runtime = {
  was_visible = nil,
  expanded_w = nil,
  expanded_h = nil,
  last_visible_x = nil,
  last_visible_y = nil,
  modal_expand_source = nil
}

local function geometry_number(value)
  local numeric = tonumber(value)
  if numeric == nil then return "unavailable" end
  return string.format("%.1f", numeric)
end

local function geometry_rect(x, y, w, h)
  return string.format(
    "x=%s y=%s w=%s h=%s",
    geometry_number(x),
    geometry_number(y),
    geometry_number(w),
    geometry_number(h)
  )
end

function UI.request_main_window_expanded_for_modal(source)
  local normalized_source = tostring(source or "modal")
  if main_window_runtime.modal_expand_source == nil then
    Util.msg(
      string.format(
        "[main-window-collapse] phase=modal_expand_requested source=%s was_visible=%s " ..
          "saved={w=%s h=%s}",
        normalized_source,
        tostring(main_window_runtime.was_visible),
        geometry_number(main_window_runtime.expanded_w),
        geometry_number(main_window_runtime.expanded_h)
      ),
      0
    )
  end
  main_window_runtime.modal_expand_source = normalized_source
end

function UI.prepare_main_window_before_begin(ctx_to_show)
  local has_saved_size =
    tonumber(main_window_runtime.expanded_w) ~= nil and
    tonumber(main_window_runtime.expanded_h) ~= nil
  local restore_collapsed_size =
    main_window_runtime.was_visible == false and has_saved_size

  if restore_collapsed_size then
    ImGui.SetNextWindowSize(
      ctx_to_show,
      main_window_runtime.expanded_w,
      main_window_runtime.expanded_h,
      ImGui.Cond_Always
    )
  end

  local modal_source = main_window_runtime.modal_expand_source
  if modal_source ~= nil then
    ImGui.SetNextWindowCollapsed(ctx_to_show, false, ImGui.Cond_Always)
  end

  return modal_source
end

function UI.observe_main_window_after_begin(ctx_to_show, visible, modal_source)
  local previous_visible = main_window_runtime.was_visible
  if visible then
    local window_x, window_y = ImGui.GetWindowPos(ctx_to_show)
    local window_w, window_h = ImGui.GetWindowSize(ctx_to_show)

    if previous_visible == false then
      Util.msg(
        string.format(
          "[main-window-collapse] phase=visible_after_collapse source=%s actual={%s} " ..
            "saved_before={w=%s h=%s}",
          tostring(modal_source or "manual"),
          geometry_rect(window_x, window_y, window_w, window_h),
          geometry_number(main_window_runtime.expanded_w),
          geometry_number(main_window_runtime.expanded_h)
        ),
        0
      )
    end

    if tonumber(window_h) ~= nil and window_h >= MAIN_WINDOW_MIN_EXPANDED_HEIGHT then
      main_window_runtime.expanded_w = window_w
      main_window_runtime.expanded_h = window_h
      main_window_runtime.last_visible_x = window_x
      main_window_runtime.last_visible_y = window_y
    end

    if modal_source ~= nil and
        main_window_runtime.modal_expand_source == modal_source then
      main_window_runtime.modal_expand_source = nil
    end
  elseif previous_visible ~= false then
    Util.msg(
      string.format(
        "[main-window-collapse] phase=collapsed_detected saved={w=%s h=%s} " ..
          "last_visible_pos={x=%s y=%s}",
        geometry_number(main_window_runtime.expanded_w),
        geometry_number(main_window_runtime.expanded_h),
        geometry_number(main_window_runtime.last_visible_x),
        geometry_number(main_window_runtime.last_visible_y)
      ),
      0
    )
  end

  main_window_runtime.was_visible = visible == true
end

-- Keeps a modal centered in the current parent window. Applying the position on
-- every modal frame avoids a ReaImGui first-appearance placement race observed
-- when a popup is opened from a deeply scrolled section of the main window.
function UI.center_next_modal_in_current_window(ctx_to_show, log_requested, source)
  local parent_x, parent_y = ImGui.GetWindowPos(ctx_to_show)
  local parent_w, parent_h = ImGui.GetWindowSize(ctx_to_show)
  local target_x = parent_x + (parent_w * 0.5)
  local target_y = parent_y + (parent_h * 0.5)
  ImGui.SetNextWindowPos(
    ctx_to_show,
    target_x,
    target_y,
    ImGui.Cond_Always,
    0.5,
    0.5
  )

  if log_requested == true then
    Util.msg(
      string.format(
        "[modal-placement] phase=requested source=%s parent={%s} target={x=%s y=%s}",
        tostring(source or "unknown"),
        geometry_rect(parent_x, parent_y, parent_w, parent_h),
        geometry_number(target_x),
        geometry_number(target_y)
      ),
      0
    )
  end
end

-- Formats a time value for record tables.
function UI.fmt_time(value)
  local v = tonumber(value) or 0
  if v < 0 then v = 0 end
  return r.format_timestr_pos(v, "", 5)
end

-- Checks that a stored REAPER track pointer still belongs to the current project.
local function is_valid_media_track(track)
  return track ~= nil
    and type(r.ValidatePtr2) == "function"
    and r.ValidatePtr2(0, track, "MediaTrack*") == true
end

-- Extracts a track number from a record.
function UI.track_number_for_record(rec)
  if not rec or not is_valid_media_track(rec.track) then return "-" end
  local track_idx = r.GetMediaTrackInfo_Value(rec.track, "IP_TRACKNUMBER") or 0
  if track_idx <= 0 then return "-" end
  return string.format("%d", math.floor(track_idx + 0.0001))
end

-- Builds a friendly label for a record.
function UI.record_label(rec)
  return rec and (rec.record_name or rec.region_name or rec.output_path or t("record")) or t("record")
end

-- Formats the Start column label for a record row.
function UI.start_label_for_record(rec)
  if rec and rec.misc_start_time_override ~= nil then
    return tostring(rec.misc_start_time_override)
  end
  return UI.fmt_time((rec and rec.item_position) or (rec and rec.track_position))
end

-- Renders a small help marker with a hover tooltip.
function UI.help_marker(ctx, text)
  ImGui.TextDisabled(ctx, "(?)")
  if ImGui.BeginItemTooltip(ctx) then
    ImGui.Text(ctx, text or "")
    ImGui.EndTooltip(ctx)
  end
end

-- Adds record rows to a table for the UI.
function UI.add_record_rows(out, records, flow_label, job_field)
  if type(records) ~= "table" then return end
  for _, rec in ipairs(records) do
    local row_flow = flow_label or ""
    if rec and rec.flow_label and rec.flow_label ~= "" then
      row_flow = rec.flow_label
    end
    local rec_id = rec.record_name or rec.region_name or rec.output_path or tostring(rec)
    table.insert(out, {
      rec = rec,
      flow = row_flow,
      job_id = job_field and rec[job_field] or nil,
      id = tostring(row_flow) .. "_" .. tostring(rec_id)
    })
  end
end

-- Builds the record rows for the UI table.
function UI.build_record_rows()
  local rows = {}
  UI.add_record_rows(rows, S.fast_sts_records, t("STS (fast)"), "sts_job_id")
  UI.add_record_rows(rows, S.fast_tts_records, t("TTS (fast)"), "tts_job_id")
  UI.add_record_rows(rows, S.rendered_regions, t("STS"), "sts_job_id")
  UI.add_record_rows(rows, S.tts_records, t("TTS"), "tts_job_id")
  if type(S.voice_design_records) == "table" then
    if S.voice_design_records.design then
      UI.add_record_rows(rows, { S.voice_design_records.design }, t("Voice Design"), "voice_design_job_id")
    end
    UI.add_record_rows(rows, S.voice_design_records.preview, t("Voice Design"), "voice_preview_job_id")
  end
  UI.add_record_rows(rows, S.voice_create_records, t("Voice Create"), "voice_create_job_id")
  UI.add_record_rows(rows, S.ivc_create_records, t("IVC Create"), "ivc_create_job_id")
  UI.add_record_rows(rows, S.openai_records, t("OpenAI"), "openai_job_id")
  UI.add_record_rows(rows, S.misc_records, t("Fetch"), "misc_job_id")
  return rows
end

local METER_COLUMNS = {
  { header = t("Tot%"), key = "total_pct", width = 62 },
  { header = t("TotSz"), key = "total_size", width = 72 },
  { header = t("Recv%"), key = "received_pct", width = 62 },
  { header = t("RecvSz"), key = "received_size", width = 72 },
  { header = t("Xfer%"), key = "xferd_pct", width = 62 },
  { header = t("XferSz"), key = "xferd_size", width = 72 },
  { header = t("AvgDl"), key = "avg_dload_speed", width = 72 },
  { header = t("AvgUp"), key = "avg_upload_speed", width = 72 },
  { header = t("TTot"), key = "time_total", width = 76 },
  { header = t("TSpent"), key = "time_spent", width = 76 },
  { header = t("TLeft"), key = "time_left", width = 76 },
  { header = t("CurSpd"), key = "current_speed", width = 76 }
}

-- Collects running curl jobs mapped to existing record rows.
function UI.collect_running_meter_rows()
  local rows = UI.build_record_rows()
  local running_rows = {}
  for i = 1, #rows do
    local row = rows[i]
    local job = row.job_id and S.curl_jobs and S.curl_jobs[row.job_id] or nil
    if job and job.phase == "running" then
      table.insert(running_rows, {
        row = row,
        job = job
      })
    end
  end
  return running_rows
end

-- Renders a live meter table for running requests.
function UI.render_running_meter_table(ctx_to_show)
  if not ctx_to_show then ctx_to_show = ctx end

  ImGui.Text(ctx_to_show, t("Live running meter"))
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx_to_show, t("Table rendering not available in this ImGui build."))
    return
  end

  local running_rows = UI.collect_running_meter_rows()
  if #running_rows == 0 then
    ImGui.TextWrapped(ctx_to_show, t("No running requests."))
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_ScrollX
  local table_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx_to_show) * 10) or 220
  local total_columns = 3 + #METER_COLUMNS + 1
  if ImGui.BeginTable(ctx_to_show, "##curl_jobs_running_meter_table", total_columns, table_flags, -1, table_h) then
    ImGui.TableSetupColumn(ctx_to_show, t("Flow"), ImGui.TableColumnFlags_WidthFixed, 100)
    ImGui.TableSetupColumn(ctx_to_show, t("Record"), ImGui.TableColumnFlags_WidthFixed, 230)
    ImGui.TableSetupColumn(ctx_to_show, t("Progress"), ImGui.TableColumnFlags_WidthFixed, 120)
    for i = 1, #METER_COLUMNS do
      local col = METER_COLUMNS[i]
      ImGui.TableSetupColumn(ctx_to_show, col.header, ImGui.TableColumnFlags_WidthFixed, col.width)
    end
    ImGui.TableSetupColumn(ctx_to_show, t("MUpd"), ImGui.TableColumnFlags_WidthFixed, 80)
    ImGui.TableHeadersRow(ctx_to_show)

    for i = 1, #running_rows do
      local item = running_rows[i]
      local row = item.row
      local job = item.job
      local flow_txt = tostring(row.flow or "")
      if flow_txt == "" then flow_txt = t("-") end
      local rec_txt = UI.record_label(row.rec)
      local flow_line = job.progress and job.progress.flow and job.progress.flow.line
      if type(flow_line) ~= "string" or flow_line == "" then flow_line = t("running") end

      ImGui.TableNextRow(ctx_to_show)
      ImGui.TableSetColumnIndex(ctx_to_show, 0)
      ImGui.TextWrapped(ctx_to_show, flow_txt)
      ImGui.TableSetColumnIndex(ctx_to_show, 1)
      ImGui.TextWrapped(ctx_to_show, rec_txt)
      ImGui.TableSetColumnIndex(ctx_to_show, 2)
      ImGui.TextWrapped(ctx_to_show, flow_line)

      local col_idx = 3
      for j = 1, #METER_COLUMNS do
        local meter_col = METER_COLUMNS[j]
        ImGui.TableSetColumnIndex(ctx_to_show, col_idx)
        local meter_val = job.progress and job.progress.meter and job.progress.meter[meter_col.key]
        local txt = tostring(meter_val or "")
        if txt == "" then txt = t("-") end
        ImGui.Text(ctx_to_show, txt)
        col_idx = col_idx + 1
      end

      ImGui.TableSetColumnIndex(ctx_to_show, col_idx)
      local ts = job.progress and tonumber(job.progress.meter_updated_at) or nil
      if ts == nil then
        ImGui.Text(ctx_to_show, t("-"))
      else
        local age = r.time_precise() - ts
        if age < 0 then age = 0 end
        ImGui.Text(ctx_to_show, string.format(t("%.1fs ago"), age))
      end
    end
    ImGui.EndTable(ctx_to_show)
  end
end

-- Aggregates status summary for the status window.
function UI.build_status_summary()
  local rows = UI.build_record_rows()
  local current_gen = S.retry_generation
  local filtered = {}
  for _, row in ipairs(rows) do
    local rec = row.rec
    if rec and rec._retry_generation == current_gen then
      table.insert(filtered, row)
    end
  end
  rows = filtered
  local total = #rows
  local summary = {
    mode = "none",
    total = total,
    counts = { queued = 0, running = 0, ok = 0, failed = 0, retrying = 0, canceled = 0 },
    single_label = "",
    single_progress = "",
    status_line = "",
    hint_line = ""
  }

  local warning_count = (S.warnings and #S.warnings) or 0
  local function append_warning(line)
    if warning_count > 0 then
      local suffix = string.format(t("Warnings: %s (see warnings)"), tostring(warning_count))
      if line and line ~= "" then
        return line .. " | " .. suffix
      end
      return suffix
    end
    return line or ""
  end

  local function classify_row_state(rec, job)
    if rec and rec._state then
      if rec._state == "retrying" then return "retrying" end
      if rec._state == "failed_final" then return "failed" end
      if rec._state == "ok" then return "ok" end
      if rec._state == "canceled" then return "canceled" end
      if rec._state == "refreshing" then return "running" end
      if rec._state == "running" then return "running" end
    end
    if job then
      if job.phase == "running" then return "running" end
      if job.phase == "created" or job.phase == "launched" then return "queued" end
      if job.phase == "completed" then
        if job.result and job.result.ok then return "ok" end
        return "failed"
      end
    end
    return "queued"
  end

  for _, row in ipairs(rows) do
    local rec = row.rec
    local job = row.job_id and S.curl_jobs[row.job_id] or nil
    local state = classify_row_state(rec, job)
    summary.counts[state] = (summary.counts[state] or 0) + 1
  end

  if total > 1 then
    summary.mode = "multi"
    local parts = {
      string.format(t("Queued %d"), summary.counts.queued),
      string.format(t("Retrying %d"), summary.counts.retrying),
      string.format(t("OK %d"), summary.counts.ok),
      string.format(t("Failed %d"), summary.counts.failed),
      string.format(t("Canceled %d"), summary.counts.canceled)
    }
    if summary.counts.running > 0 then
      table.insert(parts, 2, string.format(t("Running %d"), summary.counts.running))
    end
    local line = table.concat(parts, " | ")
    summary.status_line = append_warning(line)
    return summary
  end

  if total == 1 then
    summary.mode = "single"
    local row = rows[1]
    local rec = row.rec
    local job = row.job_id and S.curl_jobs[row.job_id] or nil
    local flow = row.flow or ""
    local label = UI.record_label(rec)
    if flow ~= "" then
      label = flow .. ": " .. label
    end
    local progress = UI.format_record_progress(rec, job)
    summary.single_label = label
    summary.single_progress = progress or ""
    local line = label
    if progress and progress ~= "" then
      line = line .. " - " .. progress
    end
    summary.status_line = append_warning(line)
    return summary
  end

  local base_line = S.status_text or ""
  if base_line == "" and S.running_label and S.running_label ~= "" then
    base_line = string.format(t("Running: %s"), S.running_label)
  end
  summary.status_line = append_warning(base_line)
  return summary
end

-- Formats the progress string for a record row.
function UI.format_record_progress(rec, job)
  if rec and rec._state == "canceled" then return t("canceled") end
  if rec and rec._state == "failed_final" then return t("failed") end
  if rec and rec._state == "ok" then return t("ok") end
  if rec and rec._state == "retrying" then
    if rec._next_retry_at then
      local remaining = rec._next_retry_at - r.time_precise()
      if remaining < 0 then remaining = 0 end
      return string.format(t("retry in %.1fs"), remaining)
    end
    return t("retrying")
  end
  if rec and rec._state == "refreshing" then return t("refreshing login") end

  if job then
    if job.phase == "running" then
      local flow_line = job.progress and job.progress.flow and job.progress.flow.line
      if type(flow_line) == "string" and flow_line ~= "" then
        return flow_line
      end
      return t("running")
    end
    if job.phase == "created" or job.phase == "launched" then
      return t("queued")
    end
    if job.phase == "completed" then
      if job.result and job.result.ok then return t("ok") end
      return t("failed")
    end
  end

  if rec and rec._state == "running" then
    return t("running")
  end
  return t("queued")
end

-- Checks whether a record can be retried from the UI.
function UI.can_retry_record(rec)
  if not rec or type(rec._retry_submit) ~= "function" then return false end
  return rec._state == "failed_final"
end

-- Checks whether a record can be canceled from the UI.
function UI.can_cancel_record(rec, job)
  if not rec then return false end
  return rec._state == "failed_final"
end

-- Clips text into a friendlier form for logs or UI.
-- Called by `format_curl_job_details`; caller passes `s` and `max_len`.
--==================RENDER (audio)===========================================
--===========================================================================
do --RENDER (audio)
  -- Renders setup flac 16bit project sample rate mono.
  -- Called by `ReaperX.render_regions_by_track_for_STS`; caller passes `render_folder`.
  local function Setup_Render_FLAC_16bit_Project_sample_rate_mono(render_folder)
    --number r.GetSetProjectInfo(ReaProject project, string desc, number value, boolean is_set)
    r.GetSetProjectInfo(0, 'RENDER_SETTINGS', 8, true) --to use render matrix
    r.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 0, true)
    r.GetSetProjectInfo(0, 'RENDER_SRATE', 0, true)
    -- r.GetSetProjectInfo(0, 'RENDER_STARTPOS', render_start, true) -- to render function
    -- r.GetSetProjectInfo(0, 'RENDER_ENDPOS', render_end, true) -- to render function
    r.GetSetProjectInfo(0, 'RENDER_CHANNELS', 1, true)
    r.GetSetProjectInfo(0, 'RENDER_TAILFLAG', 0, true)
    r.GetSetProjectInfo(0, 'PROJECT_SRATE_USE', 1, true)
    r.GetSetProjectInfo(0, 'RENDER_ADDTOPROJ', 0, true)
    r.GetSetProjectInfo(0, 'RENDER_NORMALIZE', 1536, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEIN', 0.005, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEOUT', 0.005, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEINSHAPE', 4, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEOUTSHAPE', 4, true)
    --[[
    Get or set project information.
    RENDER_SETTINGS : &(1|2)=0:master mix, &1=stems+master mix, &2=stems only, &4=multichannel tracks to multichannel files, &8=use render matrix, &16=tracks with only mono media to mono files, &32=selected media items, &64=selected media items via master, &128=selected tracks via master, &256=embed transients if format supports, &512=embed metadata if format supports, &1024=embed take markers if format supports, &2048=2nd pass render
    RENDER_BOUNDSFLAG : 0=custom time bounds, 1=entire project, 2=time selection, 3=all project regions, 4=selected media items, 5=selected project regions, 6=all project markers, 7=selected project markers
    RENDER_CHANNELS : number of channels in rendered file
    RENDER_SRATE : sample rate of rendered file (or 0 for project sample rate)
    RENDER_STARTPOS : render start time when RENDER_BOUNDSFLAG=0
    RENDER_ENDPOS : render end time when RENDER_BOUNDSFLAG=0
    RENDER_TAILFLAG : apply render tail setting when rendering: &1=custom time bounds, &2=entire project, &4=time selection, &8=all project markers/regions, &16=selected media items, &32=selected project markers/regions
    RENDER_TAILMS : tail length in ms to render (only used if RENDER_BOUNDSFLAG and RENDER_TAILFLAG are set)
    RENDER_ADDTOPROJ : &1=add rendered files to project, &2=do not render files that are likely silent
    RENDER_DITHER : &1=dither, &2=noise shaping, &4=dither stems, &8=noise shaping on stems
    RENDER_NORMALIZE: &1=enable, (&14==0)=LUFS-I, (&14==2)=RMS, (&14==4)=peak, (&14==6)=true peak, (&14==8)=LUFS-M max, (&14==10)=LUFS-S max,
    &32=normalize stems to common gain based on master,
    &64=enable brickwall limit, &128=brickwall limit true peak,
    (&2304==256)=only normalize files that are too loud,
    (&2304==2048)=only normalize files that are too quiet,
    &512=apply fade-in, &1024=apply fade-out
    RENDER_NORMALIZE_TARGET: render normalization target as amplitude, so 0.5 means -6.02dB, 0.25 means -12.04dB, etc
    RENDER_BRICKWALL: render brickwall limit as amplitude, so 0.5 means -6.02dB, 0.25 means -12.04dB, etc
    RENDER_FADEIN: render fade-in (0.001 means 1 ms, requires RENDER_NORMALIZE&512)
    RENDER_FADEOUT: render fade-out (0.001 means 1 ms, requires RENDER_NORMALIZE&1024)
    RENDER_FADEINSHAPE: render fade-in shape
    RENDER_FADEOUTSHAPE: render fade-out shape
    PROJECT_SRATE : samplerate (ignored unless PROJECT_SRATE_USE set)
    PROJECT_SRATE_USE : set to 1 if project samplerate is used
    ]]--

    --  boolean retval, string valuestrNeedBig = r.GetSetProjectInfo_String(ReaProject project, string desc, string valuestrNeedBig, boolean is_set)
    r.GetSetProjectInfo_String(0, 'RENDER_FILE', render_folder, true)
    r.GetSetProjectInfo_String(0, 'RENDER_PATTERN', [=[$region]=], true)
    r.GetSetProjectInfo_String(0, 'RENDER_FORMAT', 'Y2FsZhAAAAAIAAAA', true) --flac 16 bit slowest
    --ZXZhdxABAA== - wav 16bit
    --Y2FsZhAAAAAIAAAA - flac 16 bit slowest
    --Y2FsZhgAAAAIAAAA - flac 24 bit slowest
    -- to find out these strings you need to set what you want in render settings window - then run GetSetProjectInfo_String with boolean is_set = false to get sink configuration string
    --retval_format, string_format = r.GetSetProjectInfo_String(0, 'RENDER_FORMAT', '', false)
    --Util.msg(retval_format)
    --Util.msg(string_format)

    --[[
    Get or set project information.
    PROJECT_NAME : project file name (read-only, is_set will be ignored)
    PROJECT_TITLE : title field from Project Settings/Notes dialog
    PROJECT_AUTHOR : author field from Project Settings/Notes dialog
    TRACK_GROUP_NAME:X : track group name, X should be 1..64
    MARKER_GUID:X : get the GUID (unique ID) of the marker or region with index X, where X is the index passed to EnumProjectMarkers, not necessarily the displayed number (read-only)
    MARKER_INDEX_FROM_GUID:{GUID} : get the GUID index of the marker or region with GUID {GUID} (read-only)
    OPENCOPY_CFGIDX : integer for the configuration of format to use when creating copies/applying FX. 0=wave (auto-depth), 1=APPLYFX_FORMAT, 2=RECORD_FORMAT
    RECORD_PATH : recording directory -- may be blank or a relative path, to get the effective path see GetProjectPathEx()
    RECORD_PATH_SECONDARY : secondary recording directory
    RECORD_FORMAT : base64-encoded sink configuration (see project files, etc). Callers can also pass a simple 4-byte string (non-base64-encoded), e.g. "evaw" or "l3pm", to use default settings for that sink type.
    APPLYFX_FORMAT : base64-encoded sink configuration (see project files, etc). Used only if RECFMT_OPENCOPY is set to 1. Callers can also pass a simple 4-byte string (non-base64-encoded), e.g. "evaw" or "l3pm", to use default settings for that sink type.
    RENDER_FILE : render directory
    RENDER_PATTERN : render file name (may contain wildcards)
    RENDER_METADATA : get or set the metadata saved with the project (not metadata embedded in project media). Example, ID3 album name metadata: valuestr="ID3:TALB" to get, valuestr="ID3:TALB|my album name" to set. Call with valuestr="" and is_set=false to get a semicolon-separated list of defined project metadata identifiers.
    RENDER_TARGETS : semicolon separated list of files that would be written if the project is rendered using the most recent render settings
    RENDER_STATS : (read-only) semicolon separated list of statistics for the most recently rendered files. call with valuestr="XXX" to run an action (for example, "42437"=dry run render selected items) before returning statistics.
    RENDER_FORMAT : base64-encoded sink configuration (see project files, etc). Callers can also pass a simple 4-byte string (non-base64-encoded), e.g. "evaw" or "l3pm", to use default settings for that sink type.
    RENDER_FORMAT2 : base64-encoded secondary sink configuration. Callers can also pass a simple 4-byte string (non-base64-encoded), e.g. "evaw" or "l3pm", to use default settings for that sink type, or "" to disable secondary render.
        Formats available on this machine:
        "wave" "aiff" "caff" "raw " "iso " "ddp " "flac" "mp3l" "oggv" "OggS" "FFMP" "WMF " "GIF " "LCF " "wvpk"
    ]]--

  end --function Setup_Render_FLAC_16bit_Project_sample_rate_mono()

  local function Setup_Render_FLAC_16bit_Project_sample_rate_mono_For_IVC(dir_name, file_name_no_extension)
    if not dir_name or dir_name == "" then
      return false, t("Missing render output directory.")
    end
    if not file_name_no_extension or file_name_no_extension == "" then
      return false, t("Missing render output file name.")
    end
    r.GetSetProjectInfo(0, 'RENDER_SETTINGS', 2, true) -- &2=stems only
    r.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true) -- 2=time selection
    r.GetSetProjectInfo(0, 'RENDER_SRATE', 0, true)
    r.GetSetProjectInfo(0, 'RENDER_CHANNELS', 1, true)
    r.GetSetProjectInfo(0, 'RENDER_TAILFLAG', 0, true)
    r.GetSetProjectInfo(0, 'PROJECT_SRATE_USE', 1, true)
    r.GetSetProjectInfo(0, 'RENDER_ADDTOPROJ', 0, true)
    r.GetSetProjectInfo(0, 'RENDER_NORMALIZE', 1536, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEIN', 0.005, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEOUT', 0.005, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEINSHAPE', 4, true)
    r.GetSetProjectInfo(0, 'RENDER_FADEOUTSHAPE', 4, true)

    --  boolean retval, string valuestrNeedBig = r.GetSetProjectInfo_String(ReaProject project, string desc, string valuestrNeedBig, boolean is_set)
    r.GetSetProjectInfo_String(0, 'RENDER_FILE', dir_name, true)
    r.GetSetProjectInfo_String(0, 'RENDER_PATTERN', file_name_no_extension, true)
    r.GetSetProjectInfo_String(0, 'RENDER_FORMAT', 'Y2FsZhAAAAAIAAAA', true) --flac 16 bit slowest

    return true, "ok"
  end --function Setup_Render_FLAC_16bit_Project_sample_rate_mono_For_IVC(full_file_name)

  -- Renders a single FLAC file for IVC.
  -- Called by `Eleven.run_el_ivc_create`; caller passes `render_dir` and `render_file_name`.
  -- Returns `ok`, `msg`, `full_file_name`.
  function ReaperX.render_ivc_flac(render_dir, render_file_name_no_extension)
    local time_start, time_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if
        (not time_start) or
        (not time_end) or
        ((time_end-0.75) <= time_start)
      then
      return false, t("No time selection set or selection is too small."), nil
    end

    local selected_tracks = r.CountSelectedTracks(0)
    if selected_tracks ~= 1 then
      return false, t("Please select exactly one track."), nil
    end

    if not render_dir or render_dir == "" then
      return false, t("Missing render output directory."), nil
    end
    if not render_file_name_no_extension or render_file_name_no_extension == "" then
      return false, t("Missing render output file name."), nil
    end

    local result, err_msg =
      Setup_Render_FLAC_16bit_Project_sample_rate_mono_For_IVC(render_dir, render_file_name_no_extension)

    if not result then
      return false, err_msg, nil
    end

    --42230
    --File: Render project, using the most recent render settings, auto-close render dialog
    r.Main_OnCommand(42230, 0)

    local full_file_name = Util.path_join(render_dir, render_file_name_no_extension .. ".flac")
    -- note that extension depends on render settings;
    -- update if render format changes!
    if not r.file_exists(full_file_name) then
      return false, string.format(t("Render output missing: %s"), tostring(full_file_name)), nil
    end

    return true, "ok", full_file_name
  end --function ReaperX.render_ivc_flac(render_dir, render_file_name_no_extension)

  -- Renders regions by track.
  -- Called by `run_el_speech_to_speech_for_selected_items` and `run_el_speech_to_speech_fast`;
  -- caller passes `regions_by_track_table`.
  -- Returns on success: `true, "ok", tracks_to_regions_enriched`.
  -- Returns on failure: `false, error_message, nil`.
  local function render_regions_via_matrix_to_tmp_flac(tracks_to_regions)
    if CFG and CFG.tmp_dir then
      Setup_Render_FLAC_16bit_Project_sample_rate_mono(CFG.tmp_dir)
    else
      Util.msg('Error: no temp dir set in config!', 3, 'box')
      return
        false, t("No temp dir in config."), nil
    end

    if not tracks_to_regions or not next(tracks_to_regions) then
      return false, t("No regions to render."), nil
    end

    r.Undo_BeginBlock2(0)
    r.PreventUIRefresh(16)
    local region_indexes_added_by_this_code = { }
    local tracks_to_regions_enriched = { }
    local our_regions_by_track = { }
    for track, regions in pairs(tracks_to_regions) do
      Util.msg('addings regions for track: '..tostring(track))
      local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
      local stamp = Util.date_time_stamp_with_time_precise()
      local enriched_rows = {}
      tracks_to_regions_enriched[track] = enriched_rows
      for i, region in ipairs(regions) do
        local region_start = region[1]
        local region_end = region[2]
        local region_name = stamp..'_tr'..tostring(math.floor(track_idx))..'_reg'..tostring(i)
        local region_index = r.AddProjectMarker(0, true,
              region_start, -- region start
              region_end, -- region end
              region_name, -- will be unique file name
              -1)
        table.insert(region_indexes_added_by_this_code,region_index)
        if not our_regions_by_track[track] then
          our_regions_by_track[track] = {}
        end
        table.insert(our_regions_by_track[track], region_index)
        -- NOTE: input extension depends on render settings; update if render format changes.
        local input_path = Util.path_join(CFG.tmp_dir, region_name .. [=[.flac]=])
        table.insert(enriched_rows, {
          region = { region_start, region_end },
          track = track,
          track_position = region_start,
          region_index = region_index,
          region_name = region_name,
          input_path = input_path
        })
        Util.msg('  added region '..tostring(region_index))
      end --for loop
    end --for

    r.PreventUIRefresh(-16)
    r.Undo_EndBlock2( 0, 'added_regions', 8)
    --[[undo flags:
    #ifndef UNDO_STATE_ALL
    #define UNDO_STATE_ALL 0xFFFFFFFF
    #define UNDO_STATE_TRACKCFG 1 // has track/master vol/pan/routing, ALL envelopes (matser included)
    #define UNDO_STATE_FX 2  // track/master fx
    #define UNDO_STATE_ITEMS 4  // track items
    #define UNDO_STATE_MISCCFG 8 // loop selection, markers, regions, extensions!
    #endif]]--
    r.UpdateArrange()

    --now we need to get all tracks (and master track too)
    local all_tr_table = { }
    local master_track = r.GetMasterTrack(0)
    if master_track then
      table.insert(all_tr_table, master_track)
    else
      Util.msg('Error getting master track!', 3, 'box')
      return false, t("Error getting master track!"), nil
    end
    local i=0
    repeat
      local tr = r.GetTrack(0, i)
      if tr then table.insert(all_tr_table, tr) end
      i = i + 1
    until not tr

    --now we need to get all regions
    local all_regions_table = { }
    i=0
    repeat
      local return_value, isrgn, reg_start, reg_end, region_name,
      region_index_number
      = r.EnumProjectMarkers2(0, i)
      --integer retval,
      --boolean isrgn,
      --number pos, number rgnend,
      --string name,
      --integer markrgnindexnumber
      --= r.EnumProjectMarkers2(ReaProject proj, integer idx)
      if isrgn then
        table.insert(
          all_regions_table,
          region_index_number
        )
      end --if isrgn
      i = i + 1
    until return_value == 0

    --now we need make sure all tracks and region in region render matrix are off
    for _, current_track in ipairs(all_tr_table) do
      for _, region_index_number in ipairs(all_regions_table) do
      r.SetRegionRenderMatrix(0, region_index_number, current_track, -1) -- -1 to set to not render
      end --for
    end --for

    --now we need to set to render only our added regions and only for their respective tracks
    for track_to_render_in_render_matrix, region_numbers in pairs(our_regions_by_track) do
      for _, region_index_number in ipairs(region_numbers) do
        r.SetRegionRenderMatrix(0, region_index_number, track_to_render_in_render_matrix, 1) -- 1 to set render
      end --for
    end --for

    --42230
    --File: Render project, using the most recent render settings, auto-close render dialog
    r.Main_OnCommand(42230, 0)

    --now we need to delete regions that were created by this code
    r.Undo_BeginBlock2(0)
    r.PreventUIRefresh(16)

    for i, region_index_number in ipairs(region_indexes_added_by_this_code) do
      --boolean r.DeleteProjectMarker(ReaProject proj, integer markrgnindexnumber, boolean isrgn)
      --Delete a marker. proj==NULL for the active project.
      if r.DeleteProjectMarker(nil, region_index_number, true)
        then
          --ok, we have deleted region
        else
          Util.msg('something wrong - region delete unsuccessful!', 3)
      end --if
    end --for

    r.PreventUIRefresh(-16)
    r.Undo_EndBlock2( 0, 'removed_regions', 8)
    --[[undo flags:
    #ifndef UNDO_STATE_ALL
    #define UNDO_STATE_ALL 0xFFFFFFFF
    #define UNDO_STATE_TRACKCFG 1 // has track/master vol/pan/routing, ALL envelopes (matser included)
    #define UNDO_STATE_FX 2  // track/master fx
    #define UNDO_STATE_ITEMS 4  // track items
    #define UNDO_STATE_MISCCFG 8 // loop selection, markers, regions, extensions!
    #endif]]--
    r.UpdateArrange()

    for _, rows in pairs(tracks_to_regions_enriched) do
      for _, rec in ipairs(rows) do
        if not r.file_exists(rec.input_path) then
          return false, string.format(t("After render, file does not exist unexpectedly: %s"), rec.input_path), nil
        end
      end
    end

    return true, 'ok', tracks_to_regions_enriched
  end

  -- Renders track regions to temporary FLAC files via render matrix.
  -- Called by future batch flows; caller passes `tracks_to_regions`.
  -- Returns on success: `true, "ok", tracks_to_regions_enriched`.
  -- Returns on failure: `false, error_message, nil`.
  function ReaperX.render_regions_by_track_to_tmp_flac(tracks_to_regions)
    return render_regions_via_matrix_to_tmp_flac(tracks_to_regions)
  end

  -- Renders regions by track.
  -- Called by `run_el_speech_to_speech_for_selected_items` and `run_el_speech_to_speech_fast`;
  -- caller passes `regions_by_track_table`.
  -- Returns on success: `true, "ok", region_records`.
  -- Returns on failure: `false, error_message, nil`.
  function ReaperX.render_regions_by_track_for_STS(regions_by_track_table, voice_choices)
    refresh_project_relative_paths()
    local skipped_regions = nil
    if type(regions_by_track_table) == "table" and (regions_by_track_table.regions_by_track or regions_by_track_table.skipped_regions) then
      skipped_regions = regions_by_track_table.skipped_regions or {}
      regions_by_track_table = regions_by_track_table.regions_by_track or {}
    end

    if skipped_regions and #skipped_regions > 0 then
      ReaperX.push_sts_skipped_region_warnings(skipped_regions)
    end

    if not (CFG and CFG.tmp_dir) then
      Util.msg('Error: no temp dir set in config!', 3, 'box')
      return false, t("No temp dir in config."), nil
    end

    if not CFG.output_audio_path or CFG.output_audio_path == "" then
      return false, t("Output audio path is not set. Save the project before running speech-to-speech."), nil
    end

    if not regions_by_track_table or not next(regions_by_track_table) then
      if skipped_regions and #skipped_regions > 0 then
        return false, t("No STS regions to render after applying Max region length (sec)."), nil
      end
      return false, t("No regions to render."), nil
    end

    local voice_id_by_track = {}
    local track_name_by_track = {}
    local missing_tracks = {}
    for track in pairs(regions_by_track_table) do
      local _, track_name = r.GetTrackName(track)
      local voice_id = Eleven.resolve_voice_id_for_track_name(track_name, voice_choices)
      if voice_id and voice_id ~= "" then
        voice_id_by_track[track] = voice_id
        track_name_by_track[track] = track_name or ""
      else
        local label = (track_name and track_name ~= "") and track_name or tostring(track)
        table.insert(missing_tracks, label)
      end
    end
    if #missing_tracks > 0 then
      return false, string.format(t("Track name(s) not mapped to voice IDs: %s"), table.concat(missing_tracks, ", ")), nil
    end

    local ok_render, render_err, tracks_to_regions_enriched =
      render_regions_via_matrix_to_tmp_flac(regions_by_track_table)
    if not ok_render then
      return false, render_err, nil
    end

    local region_records = { }
    for track, rows in pairs(tracks_to_regions_enriched) do
      local track_name = track_name_by_track[track] or ""
      local voice_id = voice_id_by_track[track] or ""
      for _, rec in ipairs(rows) do
        -- NOTE: output file naming for later project import should be adjusted here.
        local output_name = rec.region_name .. "_result.mp3"
        local output_path = Files.bump_to_unique_path(Util.path_join(CFG.output_audio_path, output_name))
        table.insert(region_records, {
          track = track,
          track_position = rec.track_position,
          track_name = track_name,
          voice_id = voice_id,
          region_index = rec.region_index,
          region_name = rec.region_name,
          input_path = rec.input_path,
          output_path = output_path
        })
      end --for each row
    end --for

    return true, 'ok', region_records
  end --function ReaperX.render_regions_by_track_for_STS()
end --RENDER (audio)

--==========================================================================
--===============ReaperX Helpers============================================
--==========================================================================

do --ReaperX Helpers
  -- Safe conversion of seconds to hmsf string.
  -- Called by `ReaperX.report_time_selection` and IVC batch preview UI; caller passes `seconds`.
  function ReaperX.seconds_to_hmsf(seconds)
    if type(seconds) ~= "number" then
      return nil, string.format(t("ReaperX.seconds_to_hmsf: expected number, got %s"), type(seconds))
    end
    if seconds ~= seconds then
      return nil, t("ReaperX.seconds_to_hmsf: seconds is NaN")
    end

    local s = r.format_timestr_pos(seconds, "", 5)
    if type(s) ~= "string" or s == "" then
      return nil, t("ReaperX.seconds_to_hmsf: r.format_timestr_pos failed")
    end
    return s
  end --function ReaperX.seconds_to_hmsf(seconds)

  -- Reports current time selection.
  -- Called by various functions; no parameters.
  -- Returns true, `time_start_hmsf`, `time_end_hmsf`, `duration_hmsf`, time_start_in_seconds, time_end_in_seconds on success.
  -- Returns false, `error_message`, nil, nil, nil, nil on failure.
  function ReaperX.report_time_selection()
    local time_start, time_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if (not time_start) or (not time_end) then
      Util.msg('Reaper API failed in ReaperX.report_time_selection') -- very unlikely
      return false, t("Reaper API failed"), nil, nil, nil, nil
    end
    if time_start == 0 and time_end == 0 then
      --Util.msg('No time selection set')
      return false, t("no time selection set"), nil, nil, nil, nil
    end
    local duration = time_end - time_start
    local time_start_hmsf = ReaperX.seconds_to_hmsf(time_start)
    local time_end_hmsf = ReaperX.seconds_to_hmsf(time_end)
    local duration_hmsf = ReaperX.seconds_to_hmsf(duration)
    --[[ debug msg
      Util.msg(
        'Time selection: '
        ..time_start_hmsf
        ..' to '
        ..time_end_hmsf
        ..' (duration '
        ..duration_hmsf
        ..')'
      )
    --]]
    return true, time_start_hmsf, time_end_hmsf, duration_hmsf, time_start, time_end
  end --function ReaperX.report_time_selection()

  -- Reports if only one track is selected, and its name and number.
  -- Called by various functions; no parameters.
  -- Returns true, `track_name`, `track_number_in_reaper`, track_object on success.
  -- Returns false, `error_message`, nil, nil on failure.
  function ReaperX.report_only_one_selected_track()
    local selected_tracks_count = r.CountSelectedTracks(0)
    if selected_tracks_count > 1 then
      return false, t("more than one track selected!"), nil, nil
    end
    if selected_tracks_count < 1 then
      return false, t("no track selected!"), nil, nil
    end
    local track = r.GetSelectedTrack(0, 0)
    if not track then
      return false, t("Reaper API failed to get selected track!"), nil, nil
    end
    local _, track_name = r.GetTrackName(track)
    local track_number_in_reaper = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
    --Util.msg('Selected track: ' .. tostring(track_name))
    return true, track_name, track_number_in_reaper, track
  end --function ReaperX.report_only_one_selected_track()

  -- Calculate how much of [start_pos, end_pos] is occupied by media items on a track.
  -- Returns: ok, ratio_or_nil, err_or_nil
  -- Rules:
  -- - ratio = occupied_seconds / (end_pos - start_pos), in [0..1]
  -- - overlaps are counted ONCE (union of time)
  -- - items partially overlapping the range count only the overlapping part
  -- - fail early on invalid inputs, or if the track is a folder parent (has children)
  -- - interpret everything in seconds using D_POSITION and D_LENGTH
  function ReaperX.occupancy_ratio(track, start_pos, end_pos)
    -- ---------- input validation ----------
    if not track then
      return false, nil, "track is nil"
    end

    local check_res = r.ValidatePtr2(0, track, 'MediaTrack*')
    if not check_res then
      return false, nil, "track is not a valid MediaTrack object"
    end

    if type(start_pos) ~= "number" or type(end_pos) ~= "number" then
      return false, nil, "start_pos and end_pos must be numbers"
    end

    if start_pos >= end_pos then
      return false, nil, "start_pos must be < end_pos"
    end

    -- Fail early if track has children (i.e., is a folder parent).
    -- In REAPER, I_FOLDERDEPTH:
    --   1  = this track starts a folder (has children)
    --   0  = normal track
    --  -1  = this track is the last track in a folder
    local folder_depth = r.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    if folder_depth == 1 then
      return false, nil, "track is a folder parent (has children) - not allowed"
    end

    local range_len = end_pos - start_pos

    -- ---------- collect overlapping item segments ----------
    -- We'll store segments as {s = segment_start, e = segment_end}
    local segments = {}

    local item_count = r.CountTrackMediaItems(track)
    for i = 0, item_count - 1 do
      local item = r.GetTrackMediaItem(track, i)
      if item then
        local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_pos + item_len

        -- Fast path: one item fully covers the entire range -> occupancy is 100%
        if item_pos <= start_pos and item_end >= end_pos then
          return true, 1.0, nil
        end

        -- Check if [item_pos, item_end] intersects [start_pos, end_pos]
        -- Intersection exists if item starts before range ends AND item ends after range starts.
        if item_pos < end_pos and item_end > start_pos then
          -- Clamp the intersection to the requested range.
          local seg_start = (item_pos > start_pos) and item_pos or start_pos
          local seg_end   = (item_end < end_pos) and item_end or end_pos

          -- seg_end should be > seg_start, but we keep a safe check.
          if seg_end > seg_start then
            table.insert(segments, { s = seg_start, e = seg_end })
          end
        end
      end
    end

    -- No overlapping items -> ratio is 0
    if #segments == 0 then
      return true, 0.0, nil
    end

    -- ---------- merge segments (union) ----------
    -- Sort by start time.
    table.sort(segments, function(a, b) return a.s < b.s end)

    local merged = {}
    local cur_s = segments[1].s
    local cur_e = segments[1].e

    for i = 2, #segments do
      local s = segments[i].s
      local e = segments[i].e

      if s <= cur_e then
        -- Overlaps or touches current segment -> extend end if needed
        if e > cur_e then cur_e = e end
      else
        -- Gap -> store current segment and start a new one
        table.insert(merged, { s = cur_s, e = cur_e })
        cur_s, cur_e = s, e
      end
    end
    -- Store last segment
    table.insert(merged, { s = cur_s, e = cur_e })

    -- ---------- sum merged length ----------
    local occupied = 0.0
    for i = 1, #merged do
      occupied = occupied + (merged[i].e - merged[i].s)
    end

    -- ---------- compute ratio, clamp to [0..1] ----------
    local ratio = occupied / range_len
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end

    return true, ratio, nil
  end --ReaperX.occupancy_ratio(track, start_pos, end_pos)


end --ReaperX Helpers

--===========================================================================
--==================Text preparation (text items)============================
--===========================================================================
-- Builds text-to-speech records so later steps can reuse it.
-- Called by `Eleven.run_el_text_to_speech_for_selected_items`; caller passes `text_items_by_track`.
function Eleven.build_tts_records(text_items_by_track)
  if not text_items_by_track or not next(text_items_by_track) then
    return false, t("No text items to process."), nil
  end
  if not CFG.output_audio_path_tts or CFG.output_audio_path_tts == "" then
    return false, t("Output audio path is not set. Save the project before running text-to-speech."), nil
  end

  local records = {}
  for track, data in pairs(text_items_by_track) do
    local voice_id = data.voice_ID or data.voice_id or ""
    local track_name = data.voice_name or ""
    local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
    local stamp = Util.date_time_stamp_with_time_precise()
    local text_items = data.text_items or {}
    for i, item in ipairs(text_items) do
      local record_name = stamp .. "_tr" .. tostring(math.floor(track_idx)) .. "_item" .. tostring(i)
      local output_name = record_name .. "_result.mp3"
      local output_path = Files.bump_to_unique_path(Util.path_join(CFG.output_audio_path_tts, output_name))
      table.insert(records, {
        track = track,
        track_position = item.position,
        track_name = track_name,
        voice_id = voice_id,
        text = item.text,
        output_path = output_path,
        record_name = record_name
      })
    end --for
  end --for

  if #records < 1 then
    return false, t("No text items found to process."), nil
  end
  return true, "ok", records
end

-- Ensures voice design records container exists.
local function ensure_voice_design_records()
  if type(S.voice_design_records) ~= "table" then
    S.voice_design_records = {}
  end
  if type(S.voice_design_records.preview) ~= "table" then
    S.voice_design_records.preview = {}
  end
  if type(S.voice_design_records.generated_voices) ~= "table" then
    S.voice_design_records.generated_voices = {}
  end
  if S.voice_design_records.preview_text == nil then
    S.voice_design_records.preview_text = ""
  end
  return S.voice_design_records
end

-- Ensures voice create records container exists.
local function ensure_voice_create_records()
  if type(S.voice_create_records) ~= "table" then
    S.voice_create_records = {}
  end
  return S.voice_create_records
end

-- Ensures IVC create records container exists.
local function ensure_ivc_create_records()
  if type(S.ivc_create_records) ~= "table" then
    S.ivc_create_records = {}
  end
  return S.ivc_create_records
end

-- Ensures voice design UI state exists and has defaults.
function Eleven.ensure_voice_design_state()
  if type(S.voice_design) ~= "table" then
    S.voice_design = {}
  end
  local vd = S.voice_design
  if vd.voice_description == nil then vd.voice_description = "" end
  if vd.text == nil then vd.text = "" end
  if vd.auto_generate_text == nil then vd.auto_generate_text = true end
  if vd.desc_merge_mode == nil then vd.desc_merge_mode = "overwrite" end
  if vd.preview_merge_mode == nil then vd.preview_merge_mode = "overwrite" end
  if vd.desc_temp_item_invalid_warned == nil then vd.desc_temp_item_invalid_warned = false end
  if vd.preview_temp_item_invalid_warned == nil then vd.preview_temp_item_invalid_warned = false end
  if vd.should_enhance == nil then vd.should_enhance = true end
  if vd.guidance_scale == nil then vd.guidance_scale = 5 end
  if vd.loudness == nil then
    vd.loudness = 75
    vd.loudness_ui_100_migrated = true
  else
    local loudness = tonumber(vd.loudness)
    if not loudness then
      loudness = 75
    elseif vd.loudness_ui_100_migrated ~= true and loudness >= -1 and loudness <= 1 then
      loudness = (loudness + 1) * 50
    end
    if loudness < 0 then loudness = 0 end
    if loudness > 100 then loudness = 100 end
    vd.loudness = loudness
    vd.loudness_ui_100_migrated = true
  end
  return vd
end

-- Ensures IVC UI state exists and has defaults.
function Eleven.ensure_ivc_state()
  if type(S.ivc_ui) ~= "table" then
    S.ivc_ui = {}
  end
  local ivc = S.ivc_ui
  if ivc.use_track_name == nil then ivc.use_track_name = true end
  if ivc.voice_name == nil then ivc.voice_name = "" end
  if ivc.description == nil then ivc.description = t("From Reaper script") end
  if ivc.remove_background_noise == nil then ivc.remove_background_noise = false end
  return ivc
end

-- Ensures batch IVC inspect UI state exists and has defaults.
function Eleven.ensure_ivc_batch_ui_state()
  if type(S.ivc_batch_ui) ~= "table" then
    S.ivc_batch_ui = {}
  end
  local ivc_batch = S.ivc_batch_ui
  if ivc_batch.inspect_rows == nil then ivc_batch.inspect_rows = nil end
  if ivc_batch.inspect_ok == nil then ivc_batch.inspect_ok = nil end
  if ivc_batch.inspect_msg == nil then
    ivc_batch.inspect_msg = t("Press Inspect to preview batch IVC track regions.")
  end
  if ivc_batch.inspect_ran == nil then ivc_batch.inspect_ran = false end
  return ivc_batch
end

-- Validates state and builds a voice design payload.
function Eleven.build_voice_design_payload()
  local vd = Eleven.ensure_voice_design_state()

  local voice_description = tostring(vd.voice_description or "")
  local desc_len = #voice_description
  if desc_len < 20 or desc_len > 1000 then
    return nil, t("Voice description must be 20-1000 characters.")
  end

  local auto_generate_text = vd.auto_generate_text == true
  local text = nil
  if not auto_generate_text then
    text = tostring(vd.text or "")
    local text_len = #text
    if text_len < 100 or text_len > 1000 then
      return nil, t("Text must be 100-1000 characters when auto-generate is off.")
    end
  end

  local loudness_ui = tonumber(vd.loudness)
  if not loudness_ui then loudness_ui = 75 end
  if loudness_ui < 0 then loudness_ui = 0 end
  if loudness_ui > 100 then loudness_ui = 100 end
  local loudness = (loudness_ui / 50) - 1

  local guidance_scale = tonumber(vd.guidance_scale)
  if not guidance_scale then guidance_scale = 5 end
  if guidance_scale < 0 then guidance_scale = 0 end
  if guidance_scale > 100 then guidance_scale = 100 end

  -- Keep state in sync with clamped values.
  vd.loudness = loudness_ui
  vd.loudness_ui_100_migrated = true
  vd.guidance_scale = guidance_scale

  local payload = {
    voice_description = voice_description,
    model_id = "eleven_ttv_v3", -- hardcoded (UI hidden for now).
    auto_generate_text = auto_generate_text,
    loudness = loudness,
    guidance_scale = guidance_scale,
    should_enhance = vd.should_enhance == true,
    stream_previews = true -- fixed to true by design; not exposed in UI.
  }
  if not auto_generate_text then
    payload.text = text
  end

  return payload, nil
end

-- Checks whether voice design is ready so the UI can warn before submitting.
-- Called by `GuiLoop`; caller passes no arguments and uses shared state.
function Eleven.check_voice_design_preflight()
  local warnings = {}
  local ok = true

  local function add_block(msg)
    ok = false
    table.insert(warnings, msg)
  end

  local function add_warn(msg)
    table.insert(warnings, msg)
  end

  if Jobs.network_busy() then
    add_block(t("Network is busy. Please wait for current jobs to finish."))
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    add_block(auth_msg)
  end

  local project_path = Files.read_project_path() or ""
  S.project_path = project_path
  if project_path == "" then
    add_block(t("Project path not available. Save the project before running Voice Design."))
  else
    if Util.has_non_ascii(project_path) then
      add_warn(t("Project path contains non-ASCII characters. This can cause trouble for external tools on Windows."))
    end
    if Util.has_quoting_risk(project_path) then
      add_warn(t("Project path contains characters that require careful quoting (quotes or newlines)."))
    end
  end

  if S.tmp_writable ~= true then
    local msg = t("Temp directory is NOT writable. Fix this before running Voice Design.")
    if S.last_check_error and S.last_check_error ~= "" then
      msg = string.format(t("%s Details: %s"), msg, tostring(S.last_check_error))
    end
    add_block(msg)
  end
  if CFG.tmp_dir and CFG.tmp_dir ~= "" then
    if Util.has_non_ascii(CFG.tmp_dir) then
      add_warn(t("Temp directory path contains non-ASCII characters. May affect external tool behavior on Windows."))
    end
    if Util.has_quoting_risk(CFG.tmp_dir) then
      add_warn(t("Temp directory path contains quotes/newlines and will be carefully quoted later."))
    end
  end

  local vd = Eleven.ensure_voice_design_state()
  local voice_description = tostring(vd.voice_description or "")
  local desc_len = #voice_description
  if desc_len < 20 or desc_len > 1000 then
    add_block(t("Voice description must be 20-1000 characters."))
  end

  if vd.auto_generate_text ~= true then
    local text = tostring(vd.text or "")
    local text_len = #text
    if text_len < 100 or text_len > 1000 then
      add_block(t("Preview text must be 100-1000 characters when auto-generate is off."))
    end
  end

  return ok, warnings
end

-- Submits a voice preview stream job.
-- I.e., downloads a preview audio stream for a generated voice.
-- Called by `submit_el_voice_design_job`; caller passes `rec`.
function Eleven.submit_el_voice_preview_job(rec)
  if not rec then
    return false, t("Preview record missing.")
  end
  local generated_voice_id = rec.generated_voice_id or ""
  if generated_voice_id == "" then
    local err_txt = t("Missing generated_voice_id for preview.")
    rec._state = "failed_final"
    rec._last_error_summary = err_txt
    S.status_text = err_txt
    S.last_api_error = err_txt
    return false, err_txt
  end
  if not rec.output_path or rec.output_path == "" then
    local err_txt = t("Missing output path for preview.")
    rec._state = "failed_final"
    rec._last_error_summary = err_txt
    S.status_text = err_txt
    S.last_api_error = err_txt
    return false, err_txt
  end

  local max_attempts = tonumber(CFG.retry_max_attempts_voice_design) or 3
  rec._attempt = 1
  rec._max_attempts = max_attempts
  rec._auth_refresh_used_once = false
  rec._retry_generation = S.retry_generation
  local base_label = string.format(t("Voice preview %s"), tostring(rec.preview_index or "?"))
  rec._retry_label = rec.record_name or base_label

  local function submit_once()
    if rec._state == "canceled" then
      return false, "canceled"
    end
    rec._state = "running"
    rec._next_retry_at = nil
    local attempt = rec._attempt or 1
    local needs_trunc = attempt > 1 or rec._force_truncate
    if needs_trunc and rec.output_path and rec.output_path ~= "" then
      local ok_trunc, trunc_err = Files.truncate_file(rec.output_path)
      if not ok_trunc then
        Util.msg("Failed to truncate voice preview output before retry: " .. tostring(trunc_err), 2)
      end
      rec._force_truncate = nil
    end

    local req, req_err = Backend.client():voice_preview_stream_request(
      generated_voice_id,
      rec.output_path,
      Jobs.format_attempt_label(base_label, attempt, max_attempts),
      300
    )
    if not req then
      return Backend.request_build_failed(rec, req_err)
    end

    local opts = {
      read_body = false,
      keep_output = true
    }

    local function on_done(result, job)
      if rec._state == "canceled" then return end
      local output_size = Files.file_size(job.out_path)
      local ok_output = output_size and output_size > 0
      if result.ok and ok_output then
        Curl.update_last_curl_state(result, job, "Voice preview stream")
        S.status_text = string.format(t("Voice preview ok: %s"), tostring(rec.record_name))
        S.last_api_error = ""
        rec._state = "ok"
        rec._next_retry_at = nil
        Util.msg('Downloaded voice preview: ' .. rec.output_path)

      else
        local body_txt = nil
        local body_err = nil
        local body_data, body_info = Files.slurp_with_cap(job.out_path, 128 * 1024)
        if body_data and body_data ~= "" then
          body_txt = body_data
          result.body = body_txt
        elseif body_data == nil then
          body_err = body_info
        end
        local err_txt =
          Eleven.summarize_sts_error_body(body_txt) or
          Eleven.summarize_el_error({ err = result.err, body = body_txt }) or
          result.err or
          t("Request failed.")
        if not ok_output then
          local size_label = output_size and tostring(output_size) or t("missing")
          local prefix = string.format(t("Output file empty (%s bytes)."), size_label)
          if err_txt and err_txt ~= "" then
            err_txt = prefix .. " " .. err_txt
          else
            err_txt = prefix
          end
        end
        if body_err and (not body_txt or body_txt == "") then
          err_txt = err_txt .. string.format(t(" (output read failed: %s)"), tostring(body_err))
        end
        result.ok = false
        result.err = err_txt
        Curl.update_last_curl_state(result, job, "Voice preview stream")
        local snippet = Util.clip_body_text(body_txt or result.err_txt or err_txt, 512)
        Jobs.update_record_retry_state(rec, err_txt, result, snippet)
        local retryable = Jobs.is_retryable_result(result)
        if not ok_output then retryable = true end
        if rec._retry_generation ~= S.retry_generation then retryable = false end
        local attempt_now = rec._attempt or 1
        if retryable and attempt_now < max_attempts then
          local next_attempt = attempt_now + 1
          rec._attempt = next_attempt
          Jobs.enqueue_retry(rec._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec)
          if snippet and snippet ~= "" then
            Util.msg("Retry scheduled (Voice Preview): " .. snippet, 1)
          end
          S.last_api_error = err_txt
          S.status_text = string.format(t("Voice preview failed (retrying): %s"), err_txt)
        else
          rec._state = "failed_final"
          rec._next_retry_at = nil
          S.last_api_error = err_txt
          S.status_text = string.format(t("Voice preview failed: %s"), err_txt)
        end
      end
    end

    local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
      rec = rec,
      operation = "elevenlabs_voice_preview",
      capture_response_body = false
    })
    if not job then
      local err_txt = string.format(t("Voice preview request failed to start: %s"), tostring(err))
      rec._state = "failed_final"
      rec._next_retry_at = nil
      rec._last_error_summary = err_txt
      S.status_text = err_txt
      S.last_api_error = err_txt
      return false, err_txt
    end
    job.keep_in_list = true
    rec.voice_preview_job_id = job.id
    return true
  end

  rec._retry_submit = submit_once
  local ok_submit, submit_err = submit_once()
  if not ok_submit then
    return false, submit_err
  end
  return true
end

-- Creates a new voice from a generated preview.
-- Called by future UI flows; caller passes `rec` with generated_voice_id and voice metadata.
function Eleven.add_voice_from_preview(rec)
  if not rec then
    return false, t("Preview record missing.")
  end
  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    return false, auth_msg
  end

  local generated_voice_id = tostring(rec.generated_voice_id or "")
  if generated_voice_id == "" then
    return false, t("Missing generated_voice_id for voice creation.")
  end

  local voice_name = VoiceCatalog.trim_name(rec.voice_name)
  if voice_name == "" then
    return false, t("Missing voice_name for voice creation.")
  end
  if rec._voice_name_uniqueness_verified ~= voice_name then
    return false, t("Voice name uniqueness must be checked before creation.")
  end
  rec.voice_name = voice_name

  local voice_description = tostring(rec.voice_description or "")
  if voice_description == "" then
    return false, t("Missing voice_description for voice creation.")
  end

  local create_rec = rec._voice_create_rec
  if type(create_rec) ~= "table" then
    local stamp = Util.date_time_stamp_with_time_precise()
    create_rec = {
      record_name = stamp .. "_VOICE_CREATE_" .. tostring(generated_voice_id),
      flow_label = t("Voice Create"),
      misc_start_time_override = "-"
    }
    rec._voice_create_rec = create_rec
  end

  local create_list = ensure_voice_create_records()
  if not create_rec._in_voice_create_list then
    table.insert(create_list, create_rec)
    create_rec._in_voice_create_list = true
  end

  create_rec.generated_voice_id = generated_voice_id
  create_rec.voice_name = voice_name
  create_rec.voice_description = voice_description
  local voice_labels = VoiceCatalog.with_cirilica_origin(rec.labels, "voice_design")
  create_rec.labels = voice_labels
  create_rec.played_not_selected_voice_ids = rec.played_not_selected_voice_ids

  local payload = {
    voice_name = voice_name,
    voice_description = voice_description,
    generated_voice_id = generated_voice_id
  }
  payload.labels = voice_labels
  if type(rec.played_not_selected_voice_ids) == "table" then
    payload.played_not_selected_voice_ids = rec.played_not_selected_voice_ids
  end

  local max_attempts = tonumber(CFG.retry_max_attempts_voice_design) or 3
  create_rec._attempt = 1
  create_rec._max_attempts = max_attempts
  create_rec._auth_refresh_used_once = false
  create_rec._retry_generation = S.retry_generation
  local base_label = t("Voice create")
  create_rec._retry_label = create_rec.record_name or base_label

  local function submit_once()
    if create_rec._state == "canceled" then
      return false, "canceled"
    end
    create_rec._state = "running"
    create_rec._next_retry_at = nil
    local attempt = create_rec._attempt or 1

    local req, req_err = Backend.client():create_voice_from_preview_request(
      payload,
      Jobs.format_attempt_label(base_label, attempt, max_attempts),
      120
    )
    if not req then
      return Backend.request_build_failed(create_rec, req_err)
    end

    local opts = {
      read_body = true,
      keep_output = false,
      body_max_bytes = 4 * 1024 * 1024
    }

    local function on_done(result, job)
      if create_rec._state == "canceled" then return end
      if result.ok then
        Curl.update_last_curl_state(result, job, "Voice create")
        S.status_text = string.format(t("Voice created: %s"), tostring(voice_name))
        S.last_api_error = ""
        create_rec._state = "ok"
        create_rec._next_retry_at = nil
        Eleven.fetch_el_voices()
        return
      end

      local err_txt = Eleven.summarize_el_error(result)
      result.err = err_txt
      Curl.update_last_curl_state(result, job, "Voice create")
      local snippet = Util.clip_body_text(result.body or err_txt, 512)
      Jobs.update_record_retry_state(create_rec, err_txt, result, snippet)
      local retryable = Jobs.is_retryable_result(result)
      if create_rec._retry_generation ~= S.retry_generation then retryable = false end
      local attempt_now = create_rec._attempt or 1
      if retryable and attempt_now < max_attempts then
        local next_attempt = attempt_now + 1
        create_rec._attempt = next_attempt
        Jobs.enqueue_retry(create_rec._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, create_rec)
        if snippet and snippet ~= "" then
          Util.msg("Retry scheduled (Voice create): " .. snippet, 1)
        end
        S.last_api_error = err_txt
        S.status_text = string.format(t("Voice create failed (retrying): %s"), err_txt)
      else
        create_rec._state = "failed_final"
        create_rec._next_retry_at = nil
        S.last_api_error = err_txt
        S.status_text = string.format(t("Voice create failed: %s"), err_txt)
      end
    end

    local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
      rec = create_rec,
      operation = "elevenlabs_voice_create",
      capture_response_body = true
    })
    if not job then
      local err_txt = string.format(t("Voice create request failed to start: %s"), tostring(err))
      create_rec._state = "failed_final"
      create_rec._next_retry_at = nil
      create_rec._last_error_summary = err_txt
      S.status_text = err_txt
      S.last_api_error = err_txt
      return false, err_txt
    end
    job.keep_in_list = true
    create_rec.voice_create_job_id = job.id
    return true
  end

  create_rec._retry_submit = submit_once
  local ok_submit, submit_err = submit_once()
  if not ok_submit then
    return false, submit_err
  end
  return true
end

-- Creates a new IVC voice from a single audio file (multipart/form-data).
-- Called by `run_el_ivc_create`; caller passes `file_path` and `meta`.
function Eleven.submit_el_ivc_create(file_path, meta)
  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    return false, auth_msg
  end

  local input_path = tostring(file_path or "")
  if input_path == "" then
    return false, t("Missing input file path for IVC create.")
  end
  if not r.file_exists(input_path) then
    return false, string.format(t("IVC input file does not exist: %s"), input_path)
  end

  local name = VoiceCatalog.trim_name((meta and meta.name) or "ivc_from_script_name_not_provided")
  local description = (meta and meta.description) or "From_Script_desc_not_provided"
  local remove_background_noise = (meta and meta.remove_background_noise) == true
  local voice_labels = VoiceCatalog.with_cirilica_origin(meta and meta.labels, "ivc")
  if name == "" then
    return false, t("Missing voice name for IVC create.")
  end
  if not meta or meta._voice_name_uniqueness_verified ~= name then
    return false, t("Voice name uniqueness must be checked before IVC create.")
  end

  local create_rec = nil
  local stamp = Util.date_time_stamp_with_time_precise()
  create_rec = {
    record_name = stamp .. "_IVC_CREATE",
    flow_label = t("IVC Create"),
    misc_start_time_override = "-"
  }

  local create_list = ensure_ivc_create_records()
  table.insert(create_list, create_rec)

  create_rec.input_path = input_path
  create_rec.voice_name = name
  create_rec.voice_description = description
  create_rec.remove_background_noise = remove_background_noise
  create_rec.labels = voice_labels

  local max_attempts = tonumber(CFG.retry_max_attempts_ivc) or 3
  create_rec._attempt = 1
  create_rec._max_attempts = max_attempts
  create_rec._auth_refresh_used_once = false
  create_rec._retry_generation = S.retry_generation
  local base_label = t("IVC create")
  create_rec._retry_label = create_rec.record_name or base_label

  local function submit_once()
    if create_rec._state == "canceled" then
      return false, "canceled"
    end
    create_rec._state = "running"
    create_rec._next_retry_at = nil
    local attempt = create_rec._attempt or 1

    local req, req_err = Backend.client():ivc_create_request({
        { name = "name", value = name },
        { name = "files", filepath = input_path, content_type = "audio/flac" },
        -- note that content_type must be adjusted if input format changes
        -- also it is strange that in the docs they want "files[]",
        -- but in practice only "files" works
        -- The Studio proxy preserves the working direct-API field name here.
        { name = "description", value = description },
        { name = "labels", value = json.encode(voice_labels) },
        { name = "remove_background_noise", value = remove_background_noise and "true" or "false" }
      },
      Jobs.format_attempt_label(base_label, attempt, max_attempts),
      120
    )
    if not req then
      return Backend.request_build_failed(create_rec, req_err)
    end
    Util.msg("Submitting IVC create for: " .. name)
    Util.msg("Submitting IVC input audio file: " .. input_path)
    local opts = {
      read_body = true,
      keep_output = false,
      body_max_bytes = 4 * 1024 * 1024
    }

    local function on_done(result, job)
      if create_rec._state == "canceled" then return end
      Curl.update_last_curl_state(result, job, "IVC create")
      if result.ok and result.body and result.body ~= "" then
        local ok, decoded = pcall(json.decode, result.body)
        if ok and type(decoded) == "table" then
          local voice_id = decoded.voice_id or decoded.voiceId or decoded.id or ""
          local requires_verification =
            decoded.requires_verification == true or decoded.requiresVerification == true or false
          if voice_id ~= "" then
            create_rec.voice_id = voice_id
            create_rec.requires_verification = requires_verification
            create_rec._state = "ok"
            create_rec._next_retry_at = nil
            S.last_api_error = ""
            S.status_text = string.format(t("IVC voice created: %s"), tostring(name))
            if requires_verification then
              table.insert(S.warnings, string.format(t("IVC voice requires verification: %s"), tostring(name)))
            end
            Eleven.fetch_el_voices()
            Cleanup.enqueue_cleanup(input_path, "ivc input audio")
            return
          end
          local err_txt = t("IVC response missing voice_id.")
          result.ok = false
          result.err = err_txt
        else
          local err_txt = t("IVC response JSON decode failed.")
          result.ok = false
          result.err = err_txt
        end
      else
        local err_txt = Eleven.summarize_el_error(result)
        result.err = err_txt
      end

      local err_txt = result.err or t("IVC request failed.")
      local snippet = Util.clip_body_text(result.body or err_txt, 512)
      Jobs.update_record_retry_state(create_rec, err_txt, result, snippet)
      local retryable = Jobs.is_retryable_result(result)
      if create_rec._retry_generation ~= S.retry_generation then retryable = false end
      local attempt_now = create_rec._attempt or 1
      if retryable and attempt_now < max_attempts then
        local next_attempt = attempt_now + 1
        create_rec._attempt = next_attempt
        Jobs.enqueue_retry(create_rec._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, create_rec)
        if snippet and snippet ~= "" then
          Util.msg("Retry scheduled (IVC create): " .. snippet, 1)
        end
        S.last_api_error = err_txt
        S.status_text = string.format(t("IVC create failed (retrying): %s"), err_txt)
      else
        create_rec._state = "failed_final"
        create_rec._next_retry_at = nil
        S.last_api_error = err_txt
        S.status_text = string.format(t("IVC create failed: %s"), err_txt)
      end
    end

    local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
      rec = create_rec,
      operation = "elevenlabs_ivc_create",
      capture_response_body = true
    })
    if not job then
      local err_txt = string.format(t("IVC create request failed to start: %s"), tostring(err))
      create_rec._state = "failed_final"
      create_rec._next_retry_at = nil
      create_rec._last_error_summary = err_txt
      S.status_text = err_txt
      S.last_api_error = err_txt
      return false, err_txt
    end
    job.keep_in_list = true
    create_rec.ivc_create_job_id = job.id
    return true
  end

  create_rec._retry_submit = submit_once
  local ok_submit, submit_err = submit_once()
  if not ok_submit then
    return false, submit_err
  end
  return true
end

-- Runs ElevenLabs IVC create flow.
-- Called by future UI flows; caller passes `meta` and uses shared state.
function Eleven.run_el_ivc_create(meta)
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_ivc_create_preflight", {
    has_meta = type(meta) == "table"
  })

  local function fail(msg_to_show, event_name, extra_payload)
    S.status_text = msg_to_show
    S.last_api_error = msg_to_show
    S.ui_lock_network_buttons = false
    local payload = extra_payload or {}
    payload.safe_message = tostring(msg_to_show or "")
    TelemetryBridge.operation_failed("elevenlabs_ivc_create_preflight", payload, telemetry_started_at, event_name)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  local meta_in = (type(meta) == "table") and meta or {}
  local name = VoiceCatalog.trim_name(meta_in.name)
  local description = tostring(meta_in.description or "")
  local remove_background_noise = meta_in.remove_background_noise == true

  if name == "" then
    fail(t("Error: Missing voice name for IVC create."))
    return
  end
  if description == "" then
    description = t("From Reaper script")
  end

  refresh_project_relative_paths()
  local ok_tmp, tmp_err = Files.ensure_tmp_dir(CFG.tmp_dir)
  if not ok_tmp then
    fail(tmp_err or t("Temp directory is not writable."))
    return
  end

  local meta = {
    name = name,
    description = description,
    remove_background_noise = remove_background_noise
  }

  local function continue_after_name_check(trimmed_name)
    meta.name = trimmed_name
    meta._voice_name_uniqueness_verified = trimmed_name
    local stamp = Util.date_time_stamp_with_time_precise()
    local reander_output_file_name_no_extension =
      stamp ..
      "_ivc_input_for_" ..
      Util.sanitize_filename(meta.name, 'no_voice_name_provided', 100)
    -- extension will be added by ReaperX.render_ivc_flac!
    local ok_render, render_err, file_path =
      ReaperX.render_ivc_flac(CFG.tmp_dir, reander_output_file_name_no_extension)
    if not ok_render then
      fail(string.format(t("IVC render failed: %s"), tostring(render_err)), "render_failed", {
        stage = "render"
      })
      return
    end

    local ok_submit, submit_err = Eleven.submit_el_ivc_create(file_path, meta)
    if not ok_submit then
      fail(submit_err or t("IVC create request failed."))
      return
    end

    S.ui_lock_network_buttons = false
    TelemetryBridge.operation_completed("elevenlabs_ivc_create_preflight", {
      submitted = true
    }, telemetry_started_at)
  end

  local name_check_callback_fired = false
  local ok_fetch, fetch_err = Eleven.check_voice_name_available(meta.name, {
    on_available = continue_after_name_check,
    on_duplicate = function(duplicate_name)
      name_check_callback_fired = true
      fail(string.format(t("Voice name already exists: %s"), tostring(duplicate_name)))
    end,
    on_error = function(err_txt)
      name_check_callback_fired = true
      fail(string.format(t("Voice name check failed: %s"), tostring(err_txt or t("unknown error"))))
    end
  })
  if not ok_fetch and not name_check_callback_fired then
    fail(string.format(t("Voice name check failed: %s"), tostring(fetch_err or t("unknown error"))))
    return
  end
end --function Eleven.run_el_ivc_create()

-- Runs Batch IVC create flow from inspector rows.
-- Called by Batch IVC UI run button; caller passes `rows` and optional `batch_meta`.
function Eleven.run_el_ivc_batch_from_inspect_rows(rows, batch_meta)
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_ivc_batch_preflight", {
    inspect_row_count = type(rows) == "table" and #rows or 0
  })

  local function fail(msg_to_show, event_name, extra_payload)
    local msg = tostring(msg_to_show or t("Unknown Batch IVC error."))
    S.status_text = msg
    S.last_api_error = msg
    if type(S.warnings) ~= "table" then
      S.warnings = {}
    end
    table.insert(S.warnings, msg)
    S.ui_lock_network_buttons = false
    local payload = extra_payload or {}
    payload.safe_message = msg
    TelemetryBridge.operation_failed("elevenlabs_ivc_batch_preflight", payload, telemetry_started_at, event_name)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  if type(rows) ~= "table" then
    fail(t("Batch IVC: inspect rows missing. Press Inspect first."))
    return
  end

  local pass_rows = {}
  local pass_row_by_track = {}
  local pass_row_by_name = {}
  for idx, row in ipairs(rows) do
    if row and row.can_pass == true then
      local track = row.track
      local track_name = VoiceCatalog.trim_name(row.track_name)
      local start_num = tonumber(row.region_start)
      local end_num = tonumber(row.region_end)
      if track and track_name ~= "" and start_num ~= nil and end_num ~= nil and end_num > start_num then
        if pass_row_by_track[track] ~= nil then
          fail(t("Batch IVC: duplicate pass rows for one track are not supported."))
          return
        end
        if pass_row_by_name[track_name] ~= nil then
          fail(string.format(t("Batch IVC: duplicate trimmed voice name: %s"), track_name))
          return
        end
        local prepared = {
          _source_row_index = idx,
          track = track,
          track_name = track_name,
          region_start = start_num,
          region_end = end_num,
          remove_background_noise = (row.remove_background_noise == true)
        }
        table.insert(pass_rows, prepared)
        pass_row_by_track[track] = prepared
        pass_row_by_name[track_name] = prepared
      end
    end
  end

  if #pass_rows < 1 then
    fail(t("Batch IVC: no pass rows available. Run Inspect and fix failing rows."))
    return
  end

  refresh_project_relative_paths()
  local ok_tmp, tmp_err = Files.ensure_tmp_dir(CFG.tmp_dir)
  if not ok_tmp then
    fail(tmp_err or t("Temp directory is not writable."))
    return
  end

  local batch_meta_in = (type(batch_meta) == "table") and batch_meta or {}
  local shared_description = tostring(batch_meta_in.description or "")
  if shared_description == "" then
    shared_description = t("From Reaper script")
  end

  local function continue_after_fetch(catalog)
    for _, row in ipairs(pass_rows) do
      if VoiceCatalog.name_exists_exact(catalog, row.track_name) then
        fail(string.format(t("Voice name already exists: %s"), tostring(row.track_name)))
        return
      end
    end

    Jobs.bump_retry_generation("batch IVC")
    S.ivc_create_records = nil

    local tracks_to_regions = {}
    for _, row in ipairs(pass_rows) do
      tracks_to_regions[row.track] = {
        { row.region_start, row.region_end }
      }
    end

    local ok_render, render_err, tracks_to_regions_enriched =
      ReaperX.render_regions_by_track_to_tmp_flac(tracks_to_regions)
    if not ok_render then
      fail(string.format(t("Batch IVC render failed: %s"), tostring(render_err)), "render_failed", {
        stage = "render",
        pass_row_count = #pass_rows
      })
      return
    end

    local submit_queue = {}
    for _, row in ipairs(pass_rows) do
      local rendered_rows = tracks_to_regions_enriched and tracks_to_regions_enriched[row.track] or nil
      local rendered = (type(rendered_rows) == "table") and rendered_rows[1] or nil
      if not rendered or not rendered.input_path or rendered.input_path == "" then
        fail(string.format(t("Batch IVC render mapping failed for track: %s"), tostring(row.track_name)))
        return
      end
      table.insert(submit_queue, {
        input_path = rendered.input_path,
        track_name = row.track_name,
        remove_background_noise = row.remove_background_noise == true
      })
    end

    local submitted = 0
    for i, item in ipairs(submit_queue) do
      local meta = {
        name = item.track_name,
        description = shared_description,
        remove_background_noise = item.remove_background_noise == true,
        _voice_name_uniqueness_verified = item.track_name
      }
      local ok_submit, submit_err = Eleven.submit_el_ivc_create(item.input_path, meta)
      if not ok_submit then
        for j = i, #submit_queue do
          local pending = submit_queue[j]
          if pending and pending.input_path and pending.input_path ~= "" then
            Cleanup.enqueue_cleanup(pending.input_path, "batch ivc input audio (not submitted)")
          end
        end
        fail(
          string.format(
            t("Batch IVC stopped at %s/%s: %s"),
            tostring(i),
            tostring(#submit_queue),
            tostring(submit_err or t("IVC create request failed."))
          )
        )
        return
      end
      submitted = submitted + 1
    end

    S.status_text = string.format(t("Batch IVC jobs submitted (%s)."), tostring(submitted))
    S.last_api_error = ""
    S.ui_lock_network_buttons = false
    TelemetryBridge.operation_completed("elevenlabs_ivc_batch_preflight", {
      submitted = submitted,
      pass_row_count = #pass_rows
    }, telemetry_started_at)
  end

  local fetch_callback_fired = false
  local ok_fetch, fetch_err = Eleven.fetch_el_voices({
    purpose = "batch_ivc_uniqueness",
    on_success = continue_after_fetch,
    on_error = function(err_txt)
      fetch_callback_fired = true
      fail(string.format(t("Fetch voices failed: %s"), tostring(err_txt or t("unknown error"))))
    end
  })
  if not ok_fetch and not fetch_callback_fired then
    fail(string.format(t("Fetch voices failed: %s"), tostring(fetch_err or t("unknown error"))))
    return
  end
end --function Eleven.run_el_ivc_batch_from_inspect_rows()

-- Submits a voice design job and schedules preview streams.
-- Called by `run_el_voice_design`; caller passes `rec`.
function Eleven.submit_el_voice_design_job(rec)
  if not rec then
    return false, t("Design record missing.")
  end

  local max_attempts = tonumber(CFG.retry_max_attempts_voice_design) or 3
  rec._attempt = 1
  rec._max_attempts = max_attempts
  rec._auth_refresh_used_once = false
  rec._retry_generation = S.retry_generation
    local base_label = t("Voice design")
  rec._retry_label = rec.record_name or base_label

  local function submit_once()
    if rec._state == "canceled" then
      return false, "canceled"
    end
    rec._state = "running"
    rec._next_retry_at = nil
    local attempt = rec._attempt or 1

    local payload, payload_err = Eleven.build_voice_design_payload()
    if not payload then
      local err_txt = payload_err or t("Voice design parameters invalid.")
      rec._state = "failed_final"
      rec._next_retry_at = nil
      rec._last_error_summary = err_txt
      S.status_text = err_txt
      S.last_api_error = err_txt
      return false, err_txt
    end

    local req, req_err = Backend.client():voice_design_request(
      payload,
      "mp3_44100_128",
      Jobs.format_attempt_label(base_label, attempt, max_attempts),
      120
    )
    if not req then
      return Backend.request_build_failed(rec, req_err)
    end

    local opts = {
      read_body = true,
      keep_output = false,
      body_max_bytes = 4 * 1024 * 1024
    }

    local function on_done(result, job)
      if rec._state == "canceled" then return end
      Curl.update_last_curl_state(result, job, "Voice design")
      if result.ok and result.body and result.body ~= "" then
        local ok, decoded = pcall(json.decode, result.body)
        if ok and type(decoded) == "table" then
          local previews = decoded.previews
          if type(previews) ~= "table" then previews = {} end
          Eleven.stop_voice_preview("voice_design")
          ensure_voice_design_records()
          S.voice_design_records.preview = {}
          S.voice_design_records.generated_voices = {}
          S.voice_design_records.preview_text = decoded.text or ""
          S.voice_design_records.batch_stamp = Util.date_time_stamp_with_time_precise()
          S.voice_design_records.batch_inserted = false

          for i, preview in ipairs(previews) do
            local generated_voice_id = preview.generated_voice_id or preview.generatedVoiceId or preview.id or ""
            if generated_voice_id ~= "" then
              table.insert(S.voice_design_records.generated_voices, generated_voice_id)
            end
            local stamp = S.voice_design_records.batch_stamp
            local preview_audio_file_name = string.format("%s_Voice_Preview_"..i..".mp3", stamp)
            local output_path = Files.bump_to_unique_path(
              Util.path_join(CFG.output_audio_path_voice_design, preview_audio_file_name)
            )
            local preview_rec = {
              record_name = stamp .. "_VOICE_PREVIEW_" .. tostring(i),
              flow_label = t("Voice Design"),
              generated_voice_id = generated_voice_id,
              output_path = output_path,
              preview_index = i,
              misc_start_time_override = "-"
            }
            for key, value in pairs(preview_rec) do
              Util.msg(key..' = '..tostring(value))
            end -- for
            table.insert(S.voice_design_records.preview, preview_rec)
          end

          rec._state = "ok"
          rec._next_retry_at = nil
          S.status_text = string.format(t("Voice design ok (%s previews)."), tostring(#S.voice_design_records.preview))
          S.last_api_error = ""

          for _, preview_rec in ipairs(S.voice_design_records.preview) do
            Eleven.submit_el_voice_preview_job(preview_rec)
          end
          return
        end
        local err_txt = t("Voice design response JSON decode failed.")
        result.ok = false
        result.err = err_txt
      else
        local err_txt = Eleven.summarize_el_error(result)
        result.err = err_txt
      end

      local err_txt = result.err or t("Voice design request failed.")
      local snippet = Util.clip_body_text(result.body or err_txt, 512)
      Jobs.update_record_retry_state(rec, err_txt, result, snippet)
      local retryable = Jobs.is_retryable_result(result)
      if rec._retry_generation ~= S.retry_generation then retryable = false end
      local attempt_now = rec._attempt or 1
      if retryable and attempt_now < max_attempts then
        local next_attempt = attempt_now + 1
        rec._attempt = next_attempt
        Jobs.enqueue_retry(rec._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec)
        S.last_api_error = err_txt
        S.status_text = string.format(t("Voice design failed (retrying): %s"), err_txt)
      else
        rec._state = "failed_final"
        rec._next_retry_at = nil
        S.last_api_error = err_txt
        S.status_text = string.format(t("Voice design failed: %s"), err_txt)
      end
    end

    local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
      rec = rec,
      operation = "elevenlabs_voice_design",
      capture_response_body = true
    })
    if not job then
      local err_txt = string.format(t("Voice design request failed to start: %s"), tostring(err))
      rec._state = "failed_final"
      rec._next_retry_at = nil
      rec._last_error_summary = err_txt
      S.status_text = err_txt
      S.last_api_error = err_txt
      return false, err_txt
    end
    job.keep_in_list = true
    rec.voice_design_job_id = job.id
    return true
  end

  rec._retry_submit = submit_once
  local ok_submit, submit_err = submit_once()
  if not ok_submit then
    return false, submit_err
  end
  return true
end

-- Runs ElevenLabs voice design as part of the workflow.
-- Called by `GuiLoop`; caller passes no arguments and uses shared state.
function Eleven.run_el_voice_design()
  Eleven.stop_voice_preview("voice_design")
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_voice_design_preflight", {})
  Jobs.bump_retry_generation("voice design")
  S.voice_design_records = nil

  -- Handles fail so other code can call it.
  -- Called by `run_el_voice_design`; caller passes `msg_to_show`.
  local function fail(msg_to_show)
    S.status_text = msg_to_show
    S.last_api_error = msg_to_show
    S.ui_lock_network_buttons = false
    TelemetryBridge.operation_failed("elevenlabs_voice_design_preflight", {
      safe_message = tostring(msg_to_show or "")
    }, telemetry_started_at)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  local ok_out, out_err = Files.ensure_voice_design_output_dir()
  if not ok_out then
    fail(out_err)
    return
  end

  ensure_voice_design_records()
  local stamp = Util.date_time_stamp_with_time_precise()
  local rec = {
    record_name = stamp .. "_VOICE_DESIGN",
    flow_label = t("Voice Design"),
    misc_start_time_override = "-"
  }
  S.voice_design_records.design = rec

  local ok_submit, submit_err = Eleven.submit_el_voice_design_job(rec)
  if not ok_submit then
    fail(submit_err)
    return
  end

  S.ui_lock_network_buttons = false
  TelemetryBridge.operation_completed("elevenlabs_voice_design_preflight", {
    submitted = true
  }, telemetry_started_at)
end

-- Collects selected source text items and normalizes geometry for OpenAI modes.
-- Returns records sorted by track number and item position.
  function OpenAI.collect_selected_source_items()
  local ok_items, err_or_items = ReaperX.get_text_items_by_track(true)
  if not ok_items then
    local err_txt = type(err_or_items) == "string" and err_or_items or t("Failed to collect text items.")
    return false, err_txt, nil
  end
  if type(err_or_items) ~= "table" or not next(err_or_items) then
    return false, t("No text items to process."), nil
  end

  local source_items = {}
  local selection_index = 0
  for track, data in pairs(err_or_items) do
    local track_num = tonumber(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) or 0
    local _, track_name_fallback = r.GetTrackName(track)
    local track_name = tostring((data and data.voice_name) or track_name_fallback or "")
    local text_items = data and data.text_items or {}
    for _, item in ipairs(text_items) do
      local item_text = tostring(item and item.text or "")
      if item_text ~= "" then
        local item_position = tonumber(item.position)
        local item_length = tonumber(item.length)
        if item_position == nil then
          local label = track_name ~= "" and track_name or string.format(t("Track %s"), tostring(math.floor(track_num)))
          return false, string.format(t("Missing item position on %s."), tostring(label)), nil
        end
        if (not item_length) or item_length <= 0 then
          local label = track_name ~= "" and track_name or string.format(t("Track %s"), tostring(math.floor(track_num)))
          return false, string.format(t("Invalid item length on %s at %.3f sec."), tostring(label), item_position), nil
        end
        selection_index = selection_index + 1
        table.insert(source_items, {
          track = track,
          track_name = track_name,
          track_number = track_num,
          item_position = item_position,
          item_length = item_length,
          media_item = item.media_item,
          text = item_text,
          selection_index = selection_index
        })
      end
    end
  end

  if #source_items < 1 then
    return false, t("No text items found to process."), nil
  end

  table.sort(source_items, function(a, b)
    -- we sort now only by position so I will comment out track sorting for now,
    -- but we may want to re-enable it later if we want to enforce track grouping
    --[[sorting by track
      local a_track = tonumber(a.track_number) or 0
      local b_track = tonumber(b.track_number) or 0
      if a_track ~= b_track then
        return a_track < b_track
      end
    ]]--
    local a_pos = tonumber(a.item_position) or 0
    local b_pos = tonumber(b.item_position) or 0
    if a_pos ~= b_pos then
      return a_pos < b_pos
    end
    return (tonumber(a.selection_index) or 0) < (tonumber(b.selection_index) or 0)
  end)

  local position_epsilon = 0.001
  for i = 2, #source_items do
    local prev = source_items[i - 1]
    local curr = source_items[i]
    if
        prev.track == curr.track and
        math.abs((tonumber(curr.item_position) or 0) - (tonumber(prev.item_position) or 0)) <= position_epsilon
      then
        local label =
          curr.track_name ~= "" and
          curr.track_name or
          string.format(t("Track %s"), tostring(math.floor(tonumber(curr.track_number) or 0)))
        return
          false,
          string.format(
            t("Multiple selected items on %s at the same position (%.3f sec)."),
            tostring(label),
            tonumber(curr.item_position) or 0
          ),
          nil
    end
  end

  local stamp = Util.date_time_stamp_with_time_precise()
  for i, src in ipairs(source_items) do
    src.id = i
    local track_num =
      math.max(
        0,
        math.floor((tonumber(src.track_number) or 0) + 0.0001)
      )
    local pos_txt = string.format("%.3f", tonumber(src.item_position) or 0):gsub("%.", "_")
    src.record_name = string.format("%s_openai_id%04d_tr%02d_pos%s", stamp, i, track_num, pos_txt)
  end

  return true, t("ok"), source_items
end

-- Builds OpenAI rewrite records for per-item / per-track / all-items modes.
-- Called by `OpenAI.run_openai_text_rewrite_for_selected_items`; caller passes `source_items` and `mode`.
function OpenAI.build_openai_text_records(source_items, mode)
  if type(source_items) ~= "table" or #source_items < 1 then
    return false, t("No text items to process."), nil
  end

  local rewrite_mode = OpenAI.normalize_rewrite_mode(mode or S.openai_rewrite_mode)
  local max_chars = tonumber(CFG.openai_batch_max_request_chars) or 400000
  local mode_label = OpenAI.rewrite_mode_label(rewrite_mode)
  local records = {}

  local function build_batch_payload(items)
    local payload = { items = {} }
    for _, src in ipairs(items) do
      table.insert(payload.items, {
        id = tostring(src.id),
        track_name = src.track_name or "",
        track_position_sec = src.item_position,
        text = src.text
      })
    end
    local ok_enc, encoded = pcall(json.encode, payload)
    if not ok_enc then
      return nil, string.format(t("Batch payload JSON encode failed: %s"), tostring(encoded))
    end
    if #encoded > max_chars then
      return nil, string.format(t("Batch payload too large (%d chars, limit %d)."), #encoded, max_chars)
    end
    return encoded
  end

  if rewrite_mode == "per_item" then
    for _, src in ipairs(source_items) do
      table.insert(records, {
        mode = "per_item",
        track = src.track,
        track_name = src.track_name,
        track_number = src.track_number,
        item_position = src.item_position,
        item_length = src.item_length,
        text = src.text,
        source_item = src,
        items = { src },
        record_name = src.record_name,
        flow_label = string.format(t("OpenAI (%s)"), mode_label)
      })
    end
    return true, t("ok"), records
  end

  if rewrite_mode == "per_track" then
    local groups = {}
    local group_order = {}
    for _, src in ipairs(source_items) do
      local g = groups[src.track]
      if not g then
        g = {
          track = src.track,
          track_name = src.track_name,
          track_number = src.track_number,
          items = {}
        }
        groups[src.track] = g
        table.insert(group_order, g)
      end
      table.insert(g.items, src)
    end

    local stamp = Util.date_time_stamp_with_time_precise()
    for idx, group in ipairs(group_order) do
      local payload, payload_err = build_batch_payload(group.items)
      if not payload then
        return false, payload_err, nil
      end
      local expected_ids = {}
      for _, src in ipairs(group.items) do
        expected_ids[tostring(src.id)] = true
      end
      local track_num = math.max(0, math.floor((tonumber(group.track_number) or 0) + 0.0001))
      table.insert(records, {
        mode = "per_track",
        track = group.track,
        track_name = group.track_name,
        track_number = group.track_number,
        item_position = group.items[1] and group.items[1].item_position or nil,
        item_length = group.items[1] and group.items[1].item_length or nil,
        items = group.items,
        expected_ids = expected_ids,
        input_payload_text = payload,
        record_name = string.format("%s_openai_track%02d_batch%02d", stamp, track_num, idx),
        flow_label = string.format(t("OpenAI (%s)"), mode_label)
      })
    end
  elseif rewrite_mode == "all_items" then
    local payload, payload_err = build_batch_payload(source_items)
    if not payload then
      return false, payload_err, nil
    end
    local expected_ids = {}
    for _, src in ipairs(source_items) do
      expected_ids[tostring(src.id)] = true
    end
    local stamp = Util.date_time_stamp_with_time_precise()
    table.insert(records, {
      mode = "all_items",
      track = nil,
      misc_start_time_override = t("all items"),
      items = source_items,
      expected_ids = expected_ids,
      input_payload_text = payload,
      record_name = stamp .. "_openai_all_items_batch",
      flow_label = string.format(t("OpenAI (%s)"), mode_label)
    })
  else
    return false, string.format(t("Unsupported OpenAI rewrite mode: %s"), tostring(rewrite_mode)), nil
  end

  if #records < 1 then
    return false, t("No OpenAI records prepared."), nil
  end
  return true, t("ok"), records
end

--==========================================================================
--================= FLOWS ==================================================
--==========================================================================

do --insert media in project, insert results, OpenAI insert text result
  -- Gets fast flow result track (STS/TTS) or creates it so later steps can use it.
  -- Called by `ReaperX.fast_sts_insert_result`, `ReaperX.fast_tts_insert_result`, and `ReaperX.openai_insert_text_result`; caller passes `track`, `track_map`, and `flow`.
  local function fast_get_or_create_result_track(track, track_map, flow)
    if not track then
      return nil, t("missing source track")
    end

    if track_map and track_map[track] then
      return track_map[track], false
    end

    local track_num = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    if not track_num or track_num < 1 then
      return nil, t("invalid source track number")
    end

    local flow_key = tostring(flow or "sts"):lower()
    local color = { r = 0, g = 255, b = 0 }
    if flow_key == "tts" then
      color = { r = 255, g = 172, b = 28 }
    end

    local next_track = r.GetTrack(0, track_num)
    local created = false
    if not next_track then
      -- r.InsertTrackAtIndex(track_num, false)
      -- Superseded, changed to InsertTrackInProject (see ReaScript doc).
      r.InsertTrackInProject(0, track_num, 0)
      next_track = r.GetTrack(0, track_num)
      if not next_track then
        return nil, t("unable to create result track")
      end
      created = true
      local _, track_name = r.GetTrackName(track)
      r.GetSetMediaTrackInfo_String(next_track, 'P_NAME', 'RESULT_' .. (track_name or "Track"), true)
      r.SetTrackColor(next_track, r.ColorToNative(color.r, color.g, color.b) | 0x1000000)
    end

    if track_map then
      track_map[track] = next_track
    end
    return next_track, created
  end

  -- Inserts a text item on the provided track.
  local function insert_text_item_on_track(track, text, position, length)
    if not track then return false, t('No track provided for text item.') end
    if not text or type(text) ~= "string" then return false, t('No text provided for text item.') end
    if not position then return false, t('No position provided for text item.') end
    if not length or length <= 0 then return false, t('Invalid length provided for text item.') end
    local item = r.AddMediaItemToTrack( track )
    if not item then
      return false, t('Failed to create item on track.')
    end
    -- Set position and length
    r.SetMediaItemInfo_Value( item, 'D_POSITION', position )
    r.SetMediaItemInfo_Value( item, 'D_LENGTH', length )
    --boolean r.SetMediaItemInfo_Value(MediaItem item, string parmname, number newvalue)
    --D_POSITION : double * : item position in seconds
    --D_LENGTH : double * : item length in seconds
    r.GetSetMediaItemInfo_String( item, 'P_NOTES', text, true )
    return true, t('Text item inserted successfully.')
  end --function insert_text_item_on_track(track, text, position, length)

  -- Overwrites source media item notes with processed text.
  local function overwrite_text_on_media_item(media_item, text)
    if not media_item then
      return false, t("missing source media item")
    end
    if r.ValidatePtr and (not r.ValidatePtr(media_item, "MediaItem*")) then
      return false, t("invalid source media item")
    end
    if type(text) ~= "string" or text == "" then
      return false, t("empty output text")
    end
    local ok = r.GetSetMediaItemInfo_String(media_item, "P_NOTES", text, true)
    if not ok then
      return false, t("failed to write source item notes")
    end
    r.UpdateItemInProject(media_item)
    return true, t("ok")
  end

  -- Handles fast speech-to-speech insert result so other code can call it.
  -- Called by `submit_el_speech_to_speech_jobs_fast`; caller passes `rec` and `track_map`.
  function ReaperX.fast_sts_insert_result(rec, track_map)
    if not rec then return false, t("record missing") end
    if rec.fast_inserted then return true, t("already inserted") end
    if not rec.output_path or rec.output_path == "" then
      return false, t("missing output path")
    end

    local sz = Files.file_size(rec.output_path)
    if not sz or sz <= 0 then
      return false, t("empty output")
    end

    local result_track, err = fast_get_or_create_result_track(rec.track, track_map, "sts")
    if not result_track then
      return false, err
    end

    r.Undo_BeginBlock2(0)
    r.PreventUIRefresh(16)
    r.Main_OnCommand(40297, 0) -- Track: Unselect (clear selection of) all tracks
    r.SetMediaTrackInfo_Value(result_track, 'I_SELECTED', 1)
    --r.SetEditCurPos(rec.track_position or 0, false, false)
    if rec.track_position then
      r.SetEditCurPos(rec.track_position, false, false)
    else
      return false, t("missing track position")
    end
    r.InsertMedia(rec.output_path, 0)
    r.PreventUIRefresh(-16)
    local label = rec.region_name or "result"
    r.Undo_EndBlock2(0, 'FAST STS add ' .. tostring(label), 4)
    r.UpdateArrange()

    rec.fast_inserted = true
    return true, t("ok")
  end

  -- Handles fast text-to-speech insert result so other code can call it.
  -- Called by `submit_el_text_to_speech_jobs_fast`; caller passes `rec` and `track_map`.
  function ReaperX.fast_tts_insert_result(rec, track_map)
    if not rec then return false, t("record missing") end
    if rec.fast_inserted then return true, t("already inserted") end

    if not rec.output_path or rec.output_path == "" then
      return false, t("missing output path")
    end

    if rec.track_position then
      -- we're good to go
    else
      return false, t("missing track position")
    end

    local sz = Files.file_size(rec.output_path)
    if not sz or sz <= 0 then
      return false, t("empty output")
    end

    local result_track, err = fast_get_or_create_result_track(rec.track, track_map, "tts")
    if not result_track then
      return false, err
    end

    r.Undo_BeginBlock2(0)
    r.PreventUIRefresh(16)
    r.Main_OnCommand(40297, 0) -- Track: Unselect (clear selection of) all tracks
    r.SetMediaTrackInfo_Value(result_track, 'I_SELECTED', 1)
    r.SetEditCurPos(rec.track_position, false, false)
    r.InsertMedia(rec.output_path, 0)
    r.PreventUIRefresh(-16)
    local label = rec.record_name or "result"
    r.Undo_EndBlock2(0, 'FAST TTS add ' .. tostring(label), 4)
    r.UpdateArrange()

    rec.fast_inserted = true
    return true, t("ok")
  end

  -- Handles OpenAI text insert result so other code can call it.
  -- Called by `submit_openai_text_rewrite_jobs`; caller passes `rec`, `track_map`, `text`, and optional `opts`.
  function ReaperX.openai_insert_text_result(rec, track_map, text, opts)
    if not rec then return false, t("record missing") end
    if rec.openai_inserted then return true, t("already inserted") end
    if not text or text == "" then
      return false, t("empty output text")
    end

    opts = opts or {}
    local inline_mode = (opts.inline ~= nil) and opts.inline or (S.openai_insert_inline ~= false)
    local skip_undo = opts.skip_undo == true

    local label = rec.record_name or "result"
    if inline_mode then
      local media_item = rec.media_item or (rec.source_item and rec.source_item.media_item)
      if not media_item then
        return false, t("missing source media item")
      end
      if skip_undo then
        local ok_inline, inline_err = overwrite_text_on_media_item(media_item, text)
        if not ok_inline then return false, inline_err end
        rec.openai_inserted = true
        return true, t("ok")
      end

      r.Undo_BeginBlock2(0)
      r.PreventUIRefresh(16)
      local ok_inline, inline_err = overwrite_text_on_media_item(media_item, text)
      r.PreventUIRefresh(-16)
      r.Undo_EndBlock2(0, 'OpenAI inline ' .. tostring(label), 4)
      r.UpdateArrange()

      if not ok_inline then
        return false, inline_err
      end
      rec.openai_inserted = true
      return true, t("ok")
    end

    local result_track, err = fast_get_or_create_result_track(rec.track, track_map, "sts")
    if not result_track then
      return false, err
    end

    local pos = tonumber(rec.item_position)
    if not pos then
      pos = tonumber(rec.track_position)
    end
    if not pos then
      return false, t("missing track position")
    end
    local len = tonumber(rec.item_length)
    if not len then
      len = tonumber(rec.track_length) or 0
    end

    local ok_insert, insert_err = nil, nil
    if not skip_undo then
      r.Undo_BeginBlock2(0)
      r.PreventUIRefresh(16)
      ok_insert, insert_err = insert_text_item_on_track(result_track, text, pos, len)
      r.PreventUIRefresh(-16)
      r.Undo_EndBlock2(0, 'OpenAI add ' .. tostring(label), 4)
      r.UpdateArrange()
    else
      ok_insert, insert_err = insert_text_item_on_track(result_track, text, pos, len)
    end

    if not ok_insert then
      return false, insert_err or t("Insert failed.")
    end
    rec.openai_inserted = true
    return true, "ok"
  end
end --insert media in project, insert results, OpenAI insert text result

-- Submits ElevenLabs speech to speech jobs fast as part of the workflow.
-- Called by `run_el_speech_to_speech_fast`; caller passes `records`.
function Eleven.submit_el_speech_to_speech_jobs_fast(records)
  if not records or #records < 1 then
    return false, t("No rendered regions to process.")
  end

  local track_map = {}
  local total = #records
  local submitted = 0
  local max_attempts = tonumber(CFG.retry_max_attempts_sts) or 3
  for i, rec in ipairs(records) do
    local rec_ref = rec
    local voice_id = rec_ref.voice_id or ""
    if voice_id == "" then
      return false, string.format(t("Missing voice_id for region %s"), tostring(rec_ref.region_name))
    end

    rec_ref.auto_insert = true
    rec_ref.fast_inserted = false
    rec_ref._attempt = 1
    rec_ref._max_attempts = max_attempts
    rec_ref._auth_refresh_used_once = false
    rec_ref._retry_generation = S.retry_generation
    local base_label = string.format(t("Speech-to-speech %s/%s"), tostring(i), tostring(total))
    rec_ref._retry_label = rec_ref.region_name or base_label

    local opts = {
      read_body = false,
      keep_output = true
    }

    local function submit_once()
      if rec_ref._state == "canceled" then
        return false, "canceled"
      end
      rec_ref._state = "running"
      rec_ref._next_retry_at = nil
      local attempt = rec_ref._attempt or 1
      local needs_trunc = attempt > 1 or rec_ref._force_truncate
      if needs_trunc and rec_ref.output_path and rec_ref.output_path ~= "" then
        local ok_trunc, trunc_err = Files.truncate_file(rec_ref.output_path)
        if not ok_trunc then
          Util.msg("Failed to truncate STS output before retry: " .. tostring(trunc_err), 2)
        end
        rec_ref._force_truncate = nil
      end

      local req, req_err = Backend.client():speech_to_speech_request(
        voice_id,
        "mp3_44100_192",
        {
          { name = "audio", filepath = rec_ref.input_path },
          { name = "model_id", value = "eleven_multilingual_sts_v2" }
        },
        rec_ref.output_path,
        Jobs.format_attempt_label(base_label, attempt, max_attempts),
        300
      )
      if not req then
        return Backend.request_build_failed(rec_ref, req_err)
      end

      local function on_done(result, job)
        if rec_ref._state == "canceled" then return end
        local output_size = Files.file_size(job.out_path)
        local ok_output = output_size and output_size > 0
        if result.ok and ok_output then
          Curl.update_last_curl_state(result, job, "Speech-to-speech")
          S.status_text = string.format(t("FAST Speech-to-speech ok: %s"), tostring(rec_ref.region_name))
          S.last_api_error = ""
          rec_ref._state = "ok"
          rec_ref._next_retry_at = nil
          local ok_insert, ins_err = ReaperX.fast_sts_insert_result(rec_ref, track_map)
          if not ok_insert then
            local msg_txt = string.format(t("FAST STS insert failed: %s"), tostring(ins_err))
            table.insert(S.warnings, msg_txt)
            S.status_text = msg_txt
            S.last_api_error = msg_txt
          end
          Cleanup.enqueue_cleanup(rec_ref.input_path, "sts input audio")
        else
          local body_txt = nil
          local body_err = nil
          local body_data, body_info = Files.slurp_with_cap(job.out_path, 128 * 1024)
          if body_data and body_data ~= "" then
            body_txt = body_data
            result.body = body_txt
          elseif body_data == nil then
            body_err = body_info
          end
          local err_txt =
            Eleven.summarize_sts_error_body(body_txt) or
            Eleven.summarize_el_error({ err = result.err, body = body_txt }) or
            result.err or
            t("Request failed.")
          if not ok_output then
            local size_label = output_size and tostring(output_size) or t("missing")
            local prefix = string.format(t("Output file empty (%s bytes)."), size_label)
            if err_txt and err_txt ~= "" then
              err_txt = prefix .. " " .. err_txt
            else
              err_txt = prefix
            end
          end
          if body_err and (not body_txt or body_txt == "") then
            err_txt = err_txt .. string.format(t(" (output read failed: %s)"), tostring(body_err))
          end
          result.ok = false
          result.err = err_txt
          Curl.update_last_curl_state(result, job, "Speech-to-speech")
          local snippet = Util.clip_body_text(body_txt or result.err_txt or err_txt, 512)
          Jobs.update_record_retry_state(rec_ref, err_txt, result, snippet)
          local retryable = Jobs.is_retryable_result(result)
          if not ok_output then retryable = true end
          if rec_ref._retry_generation ~= S.retry_generation then retryable = false end
          local attempt_now = rec_ref._attempt or 1
          if retryable and attempt_now < max_attempts then
            local next_attempt = attempt_now + 1
            rec_ref._attempt = next_attempt
            Jobs.enqueue_retry(rec_ref._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec_ref)
            if snippet and snippet ~= "" then
              Util.msg("Retry scheduled (FAST STS): " .. snippet, 1)
            end
            S.last_api_error = err_txt
            S.status_text = string.format(t("Speech-to-speech failed (retrying): %s"), err_txt)
          else
            rec_ref._state = "failed_final"
            rec_ref._next_retry_at = nil
            S.last_api_error = err_txt
            S.status_text = string.format(t("Speech-to-speech failed: %s"), err_txt)
          end
        end
      end

      local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
        rec = rec_ref,
        operation = "elevenlabs_sts_fast",
        capture_response_body = false
      })
      if not job then
        local err_txt = string.format(t("Speech-to-speech request failed to start: %s"), tostring(err))
        rec_ref._state = "failed_final"
        rec_ref._next_retry_at = nil
        rec_ref._last_error_summary = err_txt
        S.status_text = err_txt
        S.last_api_error = err_txt
        return false, err_txt
      end
      job.keep_in_list = true
      rec_ref.sts_job_id = job.id
      return true
    end

    rec_ref._retry_submit = submit_once
    local ok_submit, submit_err = submit_once()
    if not ok_submit then
      return false, submit_err
    end
    submitted = submitted + 1
  end

  S.status_text = string.format(t("Speech-to-speech jobs submitted (%s)."), tostring(submitted))
  S.last_api_error = ""
  return true
end

-- Submits ElevenLabs speech to speech jobs as part of the workflow.
-- Called by `run_el_speech_to_speech_for_selected_items`; caller passes `records`.
function Eleven.submit_el_speech_to_speech_jobs(records)
  if not records or #records < 1 then
    return false, t("No rendered regions to process.")
  end

  local total = #records
  local submitted = 0
  local max_attempts = tonumber(CFG.retry_max_attempts_sts) or 3
  for i, rec in ipairs(records) do
    local voice_id = rec.voice_id or ""
    if voice_id == "" then
      return false, string.format(t("Missing voice_id for region %s"), tostring(rec.region_name))
    end

    rec._attempt = 1
    rec._max_attempts = max_attempts
    rec._auth_refresh_used_once = false
    rec._retry_generation = S.retry_generation
    local base_label = string.format(t("Speech-to-speech %s/%s"), tostring(i), tostring(total))
    rec._retry_label = rec.region_name or base_label

    local opts = {
      read_body = false,
      keep_output = true
    }

    local function submit_once()
      if rec._state == "canceled" then
        return false, "canceled"
      end
      rec._state = "running"
      rec._next_retry_at = nil
      local attempt = rec._attempt or 1
      local needs_trunc = attempt > 1 or rec._force_truncate
      if needs_trunc and rec.output_path and rec.output_path ~= "" then
        local ok_trunc, trunc_err = Files.truncate_file(rec.output_path)
        if not ok_trunc then
          Util.msg("Failed to truncate STS output before retry: " .. tostring(trunc_err), 2)
        end
        rec._force_truncate = nil
      end

      local req, req_err = Backend.client():speech_to_speech_request(
        voice_id,
        "mp3_44100_192",
        {
          { name = "audio", filepath = rec.input_path },
          { name = "model_id", value = "eleven_multilingual_sts_v2" }
        },
        rec.output_path,
        Jobs.format_attempt_label(base_label, attempt, max_attempts),
        300
      )
      if not req then
        return Backend.request_build_failed(rec, req_err)
      end

      local function on_done(result, job)
        if rec._state == "canceled" then return end
        local output_size = Files.file_size(job.out_path)
        local ok_output = output_size and output_size > 0
        if result.ok and ok_output then
          Curl.update_last_curl_state(result, job, "Speech-to-speech")
          S.status_text = string.format(t("Speech-to-speech ok: %s"), tostring(rec.region_name))
          S.last_api_error = ""
          rec._state = "ok"
          rec._next_retry_at = nil
          Cleanup.enqueue_cleanup(rec.input_path, "sts input audio")
        else
          local body_txt = nil
          local body_err = nil
          local body_data, body_info = Files.slurp_with_cap(job.out_path, 128 * 1024)
          if body_data and body_data ~= "" then
            body_txt = body_data
            result.body = body_txt
          elseif body_data == nil then
            body_err = body_info
          end
          local err_txt =
            Eleven.summarize_sts_error_body(body_txt) or
            Eleven.summarize_el_error({ err = result.err, body = body_txt }) or
            result.err or
            t("Request failed.")
          if not ok_output then
            local size_label = output_size and tostring(output_size) or t("missing")
            local prefix = string.format(t("Output file empty (%s bytes)."), size_label)
            if err_txt and err_txt ~= "" then
              err_txt = prefix .. " " .. err_txt
            else
              err_txt = prefix
            end
          end
          if body_err and (not body_txt or body_txt == "") then
            err_txt = err_txt .. string.format(t(" (output read failed: %s)"), tostring(body_err))
          end
          result.ok = false
          result.err = err_txt
          Curl.update_last_curl_state(result, job, "Speech-to-speech")
          local snippet = Util.clip_body_text(body_txt or result.err_txt or err_txt, 512)
          Jobs.update_record_retry_state(rec, err_txt, result, snippet)
          local retryable = Jobs.is_retryable_result(result)
          if not ok_output then retryable = true end
          if rec._retry_generation ~= S.retry_generation then retryable = false end
          local attempt_now = rec._attempt or 1
          if retryable and attempt_now < max_attempts then
            local next_attempt = attempt_now + 1
            rec._attempt = next_attempt
            Jobs.enqueue_retry(rec._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec)
            if snippet and snippet ~= "" then
              Util.msg("Retry scheduled (STS): " .. snippet, 1)
            end
            S.last_api_error = err_txt
            S.status_text = string.format(t("Speech-to-speech failed (retrying): %s"), err_txt)
          else
            rec._state = "failed_final"
            rec._next_retry_at = nil
            S.last_api_error = err_txt
            S.status_text = string.format(t("Speech-to-speech failed: %s"), err_txt)
          end
        end
      end

      local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
        rec = rec,
        operation = "elevenlabs_sts",
        capture_response_body = false
      })
      if not job then
        local err_txt = string.format(t("Speech-to-speech request failed to start: %s"), tostring(err))
        rec._state = "failed_final"
        rec._next_retry_at = nil
        rec._last_error_summary = err_txt
        S.status_text = err_txt
        S.last_api_error = err_txt
        return false, err_txt
      end
      job.keep_in_list = true
      rec.sts_job_id = job.id
      return true
    end

    rec._retry_submit = submit_once
    local ok_submit, submit_err = submit_once()
    if not ok_submit then
      return false, submit_err
    end
    submitted = submitted + 1
  end

  S.status_text = string.format(t("Speech-to-speech jobs submitted (%s)."), tostring(submitted))
  S.last_api_error = ""
  return true
end

function Eleven.resolve_voice_id_for_track_name(track_name, voice_choices)
  local resolution = VoiceCatalog.resolve_name(S.el_voices, track_name)
  if resolution.status == "unique" then
    return resolution.selected_voice_id
  end
  if resolution.status ~= "ambiguous" then
    return nil
  end

  local selected_id = voice_choices and voice_choices[tostring(track_name or "")] or nil
  if not selected_id then return nil end
  for _, voice in ipairs(resolution.candidates) do
    if voice.id == selected_id then
      return selected_id
    end
  end
  return nil
end

local function collect_selected_voice_names(flow_id)
  local names = {}
  local seen = {}
  local selected_count = r.CountSelectedMediaItems(0)
  local is_tts = flow_id == "tts_regular" or flow_id == "tts_fast"

  for index = 0, selected_count - 1 do
    local item = r.GetSelectedMediaItem(0, index)
    local include_item = item ~= nil
    if include_item and is_tts then
      local _, notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
      include_item = tostring(notes or "") ~= ""
    end
    if include_item then
      local track = r.GetMediaItemTrack(item)
      local _, track_name_raw = r.GetTrackName(track)
      local track_name = tostring(track_name_raw or "")
      if track_name ~= "" and not seen[track_name] then
        seen[track_name] = true
        names[#names + 1] = track_name
      end
    end
  end

  table.sort(names)
  return names
end

function Eleven.prepare_voice_resolution(flow_id)
  if not Auth.has_access_token() then
    return true, {}
  end
  local catalog = S.el_voices
  if type(catalog) ~= "table" or type(catalog.by_name) ~= "table" then
    return true, {}
  end

  local rows = {}
  for _, track_name in ipairs(collect_selected_voice_names(flow_id)) do
    local resolution = VoiceCatalog.resolve_name(
      catalog,
      track_name,
      S.voice_choice_by_name and S.voice_choice_by_name[track_name]
    )
    if resolution.status == "ambiguous" then
      rows[#rows + 1] = {
        track_name = track_name,
        candidates = resolution.candidates,
        selected_voice_id = resolution.selected_voice_id
      }
    end
  end

  local approval = S.voice_flow_approval
  if approval and approval.flow_id == flow_id then
    local approved_choices = approval.choices or {}
    local approval_valid = true
    for _, row in ipairs(rows) do
      local approved_id = approved_choices[row.track_name]
      local candidate_valid = false
      for _, candidate in ipairs(row.candidates) do
        if candidate.id == approved_id then
          candidate_valid = true
          break
        end
      end
      if not candidate_valid then
        approval_valid = false
        break
      end
    end
    S.voice_flow_approval = nil
    if approval_valid then
      return true, approved_choices
    end
  end

  if #rows == 0 then
    return true, {}
  end

  S.voice_resolver = {
    flow_id = flow_id,
    rows = rows,
    open_requested = true,
    started_at = TelemetryBridge.now()
  }
  UI.request_main_window_expanded_for_modal("duplicate_voice_resolver")
  S.ui_lock_network_buttons = true
  S.status_text = t("Choose voices for duplicate track names.")
  S.last_api_error = ""
  TelemetryBridge.operation_started("elevenlabs_voice_resolution", {
    ambiguous_name_count = #rows,
    flow_id = flow_id
  })
  return false, nil, "pending"
end

local function resume_voice_resolved_flow(flow_id)
  local label
  local runner
  if flow_id == "tts_regular" then
    label = t("Text-to-speech")
    runner = Eleven.run_el_text_to_speech_for_selected_items
  elseif flow_id == "tts_fast" then
    label = t("Fast text-to-speech")
    runner = Eleven.run_el_text_to_speech_fast
  elseif flow_id == "sts_regular" then
    label = t("Speech-to-speech")
    runner = Eleven.run_el_speech_to_speech_for_selected_items
  elseif flow_id == "sts_fast" then
    label = t("Fast speech-to-speech")
    runner = Eleven.run_el_speech_to_speech_fast
  end
  if not runner then
    return false
  end
  return Jobs.schedule_job(label, runner)
end

local function voice_resolver_candidate_label(voice)
  local label = tostring(voice and voice.display_label or voice and voice.name or "")
  local voice_id = tostring(voice and voice.id or "")
  if voice_id ~= "" and not label:find(voice_id, 1, true) then
    label = label .. " [" .. voice_id .. "]"
  end
  return label
end

function Eleven.draw_voice_resolver_modal(ctx_to_show)
  local resolver = S.voice_resolver
  if type(resolver) ~= "table" then return end

  local popup_id = t("Resolve duplicate voice names") .. "##elevenlabs_voice_resolver"
  local placement_debug_requested = resolver.open_requested == true
  if resolver.open_requested then
    ImGui.OpenPopup(ctx_to_show, popup_id)
    resolver.open_requested = false
  end

  local popup_flags = ImGui.WindowFlags_AlwaysAutoResize
  local _, float_max = ImGui.NumericLimits_Float()
  ImGui.SetNextWindowSizeConstraints(
    ctx_to_show,
    590,
    0,
    590,
    float_max
  )
  UI.center_next_modal_in_current_window(
    ctx_to_show,
    placement_debug_requested,
    "duplicate_voice_resolver"
  )
  local popup_open = ImGui.BeginPopupModal(ctx_to_show, popup_id, nil, popup_flags)
  if not popup_open then return end

  ImGui.TextWrapped(
    ctx_to_show,
    t("Some selected track names match more than one ElevenLabs voice. Choose the full voice ID for this operation.")
  )
  ImGui.Separator(ctx_to_show)

  for row_index, row in ipairs(resolver.rows or {}) do
    ImGui.Text(ctx_to_show, tostring(row.track_name or ""))
    ImGui.SetNextItemWidth(ctx_to_show, 560)
    local selected_voice = S.el_voices and S.el_voices.by_id and
      S.el_voices.by_id[row.selected_voice_id] or nil
    local preview = voice_resolver_candidate_label(selected_voice)
    if ImGui.BeginCombo(
      ctx_to_show,
      "##voice_resolver_" .. tostring(row_index),
      preview,
      ImGui.ComboFlags_HeightLarge
    ) then
      for _, candidate in ipairs(row.candidates or {}) do
        local selected = candidate.id == row.selected_voice_id
        if ImGui.Selectable(
          ctx_to_show,
          voice_resolver_candidate_label(candidate) .. "##candidate_" .. tostring(candidate.id),
          selected
        ) then
          row.selected_voice_id = candidate.id
        end
        if selected then ImGui.SetItemDefaultFocus(ctx_to_show) end
      end
      ImGui.EndCombo(ctx_to_show)
    end
  end

  ImGui.Separator(ctx_to_show)
  if ImGui.Button(ctx_to_show, t("OK")) then
    local choices = {}
    for _, row in ipairs(resolver.rows or {}) do
      choices[row.track_name] = row.selected_voice_id
      S.voice_choice_by_name[row.track_name] = row.selected_voice_id
    end
    local flow_id = resolver.flow_id
    S.voice_flow_approval = {
      flow_id = flow_id,
      choices = choices
    }
    S.voice_resolver = nil
    S.ui_lock_network_buttons = false
    ImGui.CloseCurrentPopup(ctx_to_show)
    TelemetryBridge.operation_completed("elevenlabs_voice_resolution", {
      ambiguous_name_count = #resolver.rows,
      flow_id = flow_id,
      outcome = "confirmed"
    }, resolver.started_at)
    if not resume_voice_resolved_flow(flow_id) then
      S.voice_flow_approval = nil
      S.status_text = t("Could not resume the voice workflow.")
      S.last_api_error = S.status_text
    end
  end
  ImGui.SameLine(ctx_to_show)
  if ImGui.Button(ctx_to_show, t("Cancel")) then
    local flow_id = resolver.flow_id
    S.voice_resolver = nil
    S.voice_flow_approval = nil
    S.ui_lock_network_buttons = false
    S.status_text = t("Voice selection canceled. No render or request was started.")
    S.last_api_error = ""
    ImGui.CloseCurrentPopup(ctx_to_show)
    TelemetryBridge.operation_completed("elevenlabs_voice_resolution", {
      ambiguous_name_count = #resolver.rows,
      flow_id = flow_id,
      outcome = "canceled"
    }, resolver.started_at)
  end

  ImGui.EndPopup(ctx_to_show)
end

-- Runs ElevenLabs speech to speech for selected items as part of the workflow.
-- Called by `GuiLoop`; caller passes no arguments and uses shared state.
function Eleven.run_el_speech_to_speech_for_selected_items()
  local resolution_ready, voice_choices = Eleven.prepare_voice_resolution("sts_regular")
  if not resolution_ready then return end
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_sts_preflight", {})

  -- Handles fail so other code can call it.
  -- Called by several helpers (for example `run_el_speech_to_speech_for_selected_items`, `run_el_speech_to_speech_fast`, and `run_el_text_to_speech_for_selected_items`); caller passes `msg_to_show`.
  local function fail(msg_to_show, event_name, extra_payload)
    S.status_text = msg_to_show
    S.last_api_error = msg_to_show
    S.ui_lock_network_buttons = false
    local payload = extra_payload or {}
    payload.safe_message = tostring(msg_to_show or "")
    TelemetryBridge.operation_failed("elevenlabs_sts_preflight", payload, telemetry_started_at, event_name)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  if (not S.el_voices) or (not S.el_voices.by_id) or (not next(S.el_voices.by_id)) then
    fail(t("No voices configured! Please fetch voices from server first."))
    return
  end

  local ok_out, out_err = Files.ensure_output_dir()
  if not ok_out then
    fail(out_err)
    return
  end

  local ok_regions, err_or_regions = ReaperX.get_render_regions_by_track(voice_choices)
  if not ok_regions then
    fail(string.format(t("Render regions failed: %s"), tostring(err_or_regions)))
    return
  end

  S.status_text = t("Rendering regions...")
  local ok_render, render_err, records =
    ReaperX.render_regions_by_track_for_STS(err_or_regions, voice_choices)
  if not ok_render then
    fail(string.format(t("Render regions failed: %s"), tostring(render_err)), "render_failed", {
      stage = "render"
    })
    return
  end

  Jobs.full_reset_state("auto reset: STS")
  S.ui_lock_network_buttons = true

  -- Importnat to store rendered regions for later use:
  -- retries and adding results to project
  S.rendered_regions = records
  -- TODO: allow reusing S.rendered_regions for retries without re-rendering.
  local ok_submit, submit_err = Eleven.submit_el_speech_to_speech_jobs(S.rendered_regions)
  if not ok_submit then
    fail(submit_err)
    return
  end

  S.ui_lock_network_buttons = false
  TelemetryBridge.operation_completed("elevenlabs_sts_preflight", {
    record_count = type(S.rendered_regions) == "table" and #S.rendered_regions or 0,
    submitted = true
  }, telemetry_started_at)
end

-- Runs ElevenLabs speech to speech fast as part of the workflow.
-- Called during startup and by `GuiLoop`; caller passes no arguments and uses shared state.
function Eleven.run_el_speech_to_speech_fast()
  local resolution_ready, voice_choices = Eleven.prepare_voice_resolution("sts_fast")
  if not resolution_ready then return end
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_sts_fast_preflight", {})
  Jobs.bump_retry_generation()
  S.fast_sts_records = nil

  -- Handles fail so other code can call it.
  -- Called by several helpers (for example `run_el_speech_to_speech_for_selected_items`, `run_el_speech_to_speech_fast`, and `run_el_text_to_speech_for_selected_items`); caller passes `msg_to_show`.
  local function fail(msg_to_show, event_name, extra_payload)
    S.status_text = msg_to_show
    S.last_api_error = msg_to_show
    S.ui_lock_network_buttons = false
    local payload = extra_payload or {}
    payload.safe_message = tostring(msg_to_show or "")
    TelemetryBridge.operation_failed("elevenlabs_sts_fast_preflight", payload, telemetry_started_at, event_name)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  if (not S.el_voices) or (not S.el_voices.by_id) or (not next(S.el_voices.by_id)) then
    fail(t("No voices configured! Please fetch voices from server first."))
    return
  end

  local ok_out, out_err = Files.ensure_output_dir()
  if not ok_out then
    fail(out_err)
    return
  end

  local ok_regions, err_or_regions = ReaperX.get_render_regions_by_track(voice_choices)
  if not ok_regions then
    fail(string.format(t("Render regions failed: %s"), tostring(err_or_regions)))
    return
  end

  S.status_text = t("Rendering regions...")
  local ok_render, render_err, records =
    ReaperX.render_regions_by_track_for_STS(err_or_regions, voice_choices)
  if not ok_render then
    fail(string.format(t("Render regions failed: %s"), tostring(render_err)), "render_failed", {
      stage = "render"
    })
    return
  end

  S.fast_sts_records = records
  local ok_submit, submit_err = Eleven.submit_el_speech_to_speech_jobs_fast(S.fast_sts_records)
  if not ok_submit then
    fail(submit_err)
    return
  end

  S.ui_lock_network_buttons = false
  TelemetryBridge.operation_completed("elevenlabs_sts_fast_preflight", {
    record_count = type(S.fast_sts_records) == "table" and #S.fast_sts_records or 0,
    submitted = true
  }, telemetry_started_at)
end

-- Submits ElevenLabs text to speech jobs fast as part of the workflow.
-- Called by `run_el_text_to_speech_fast`; caller passes `records` and `model_id`.
function Eleven.submit_el_text_to_speech_jobs_fast(records, model_id)
  if not records or #records < 1 then
    return false, t("No text items to process.")
  end
  if not model_id or model_id == "" then
    return false, t("Missing model_id for text-to-speech.")
  end

  local track_map = {}
  local total = #records
  local submitted = 0
  local max_attempts = tonumber(CFG.retry_max_attempts_tts) or 3
  for i, rec in ipairs(records) do
    local rec_ref = rec
    local voice_id = rec_ref.voice_id or ""
    if voice_id == "" then
      return false, string.format(t("Missing voice_id for item %s"), tostring(rec_ref.record_name))
    end

    local opts = {
      read_body = false,
      keep_output = true
    }

    rec_ref.auto_insert = true
    rec_ref.fast_inserted = false
    rec_ref._attempt = 1
    rec_ref._max_attempts = max_attempts
    rec_ref._auth_refresh_used_once = false
    rec_ref._retry_generation = S.retry_generation
    local base_label = string.format(t("Text-to-speech %s/%s"), tostring(i), tostring(total))
    rec_ref._retry_label = rec_ref.record_name or base_label

    local function submit_once()
      if rec_ref._state == "canceled" then
        return false, "canceled"
      end
      rec_ref._state = "running"
      rec_ref._next_retry_at = nil
      local attempt = rec_ref._attempt or 1
      local needs_trunc = attempt > 1 or rec_ref._force_truncate
      if needs_trunc and rec_ref.output_path and rec_ref.output_path ~= "" then
        local ok_trunc, trunc_err = Files.truncate_file(rec_ref.output_path)
        if not ok_trunc then
          Util.msg("Failed to truncate TTS output before retry: " .. tostring(trunc_err), 2)
        end
        rec_ref._force_truncate = nil
      end

      local req, req_err = Backend.client():text_to_speech_request(
        voice_id,
        "mp3_44100_192",
        {
          text = rec_ref.text,
          model_id = model_id
        },
        rec_ref.output_path,
        Jobs.format_attempt_label(base_label, attempt, max_attempts),
        300
      )
      if not req then
        return Backend.request_build_failed(rec_ref, req_err)
      end

      local function on_done(result, job)
        if rec_ref._state == "canceled" then return end
        local output_size = Files.file_size(job.out_path)
        local ok_output = output_size and output_size > 0
        if result.ok and ok_output then
          Curl.update_last_curl_state(result, job, "Text-to-speech")
          S.status_text = string.format(t("FAST Text-to-speech ok: %s"), tostring(rec_ref.record_name))
          S.last_api_error = ""
          rec_ref._state = "ok"
          rec_ref._next_retry_at = nil
          local ok_insert, ins_err = ReaperX.fast_tts_insert_result(rec_ref, track_map)
          if not ok_insert then
            local msg_txt = string.format(t("FAST TTS insert failed: %s"), tostring(ins_err))
            table.insert(S.warnings, msg_txt)
            S.status_text = msg_txt
            S.last_api_error = msg_txt
          end
        else
          local body_txt = nil
          local body_err = nil
          local body_data, body_info = Files.slurp_with_cap(job.out_path, 128 * 1024)
          if body_data and body_data ~= "" then
            body_txt = body_data
            result.body = body_txt
          elseif body_data == nil then
            body_err = body_info
          end
          local err_txt =
            Eleven.summarize_sts_error_body(body_txt) or
            Eleven.summarize_el_error({ err = result.err, body = body_txt }) or
            result.err or
            t("Request failed.")
          if not ok_output then
            local size_label = output_size and tostring(output_size) or t("missing")
            local prefix = string.format(t("Output file empty (%s bytes)."), size_label)
            if err_txt and err_txt ~= "" then
              err_txt = prefix .. " " .. err_txt
            else
              err_txt = prefix
            end
          end
          if body_err and (not body_txt or body_txt == "") then
            err_txt = err_txt .. string.format(t(" (output read failed: %s)"), tostring(body_err))
          end
          result.ok = false
          result.err = err_txt
          Curl.update_last_curl_state(result, job, "Text-to-speech")
          local snippet = Util.clip_body_text(body_txt or result.err_txt or err_txt, 512)
          Jobs.update_record_retry_state(rec_ref, err_txt, result, snippet)
          local retryable = Jobs.is_retryable_result(result)
          if not ok_output then retryable = true end
          if rec_ref._retry_generation ~= S.retry_generation then retryable = false end
          local attempt_now = rec_ref._attempt or 1
          if retryable and attempt_now < max_attempts then
            local next_attempt = attempt_now + 1
            rec_ref._attempt = next_attempt
            Jobs.enqueue_retry(rec_ref._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec_ref)
            if snippet and snippet ~= "" then
              Util.msg("Retry scheduled (FAST TTS): " .. snippet, 1)
            end
            S.last_api_error = err_txt
            S.status_text = string.format(t("Text-to-speech failed (retrying): %s"), err_txt)
          else
            rec_ref._state = "failed_final"
            rec_ref._next_retry_at = nil
            S.last_api_error = err_txt
            S.status_text = string.format(t("Text-to-speech failed: %s"), err_txt)
          end
        end
      end

      local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
        rec = rec_ref,
        operation = "elevenlabs_tts_fast",
        capture_response_body = false
      })
      if not job then
        local err_txt = string.format(t("Text-to-speech request failed to start: %s"), tostring(err))
        rec_ref._state = "failed_final"
        rec_ref._next_retry_at = nil
        rec_ref._last_error_summary = err_txt
        S.status_text = err_txt
        S.last_api_error = err_txt
        return false, err_txt
      end
      job.keep_in_list = true
      rec_ref.tts_job_id = job.id
      return true
    end

    rec_ref._retry_submit = submit_once
    local ok_submit, submit_err = submit_once()
    if not ok_submit then
      return false, submit_err
    end
    submitted = submitted + 1
  end

  S.status_text = string.format(t("Text-to-speech jobs submitted (%s)."), tostring(submitted))
  S.last_api_error = ""
  return true
end

-- Submits ElevenLabs text to speech jobs as part of the workflow.
-- Called by `run_el_text_to_speech_for_selected_items`; caller passes `records` and `model_id`.
function Eleven.submit_el_text_to_speech_jobs(records, model_id)
  if not records or #records < 1 then
    return false, t("No text items to process.")
  end
  if not model_id or model_id == "" then
    return false, t("Missing model_id for text-to-speech.")
  end

  local total = #records
  local submitted = 0
  local max_attempts = tonumber(CFG.retry_max_attempts_tts) or 3
  for i, rec in ipairs(records) do
    local voice_id = rec.voice_id or ""
    if voice_id == "" then
      return false, string.format(t("Missing voice_id for item %s"), tostring(rec.record_name))
    end

    local opts = {
      read_body = false,
      keep_output = true
    }

    rec._attempt = 1
    rec._max_attempts = max_attempts
    rec._auth_refresh_used_once = false
    rec._retry_generation = S.retry_generation
    local base_label = string.format(t("Text-to-speech %s/%s"), tostring(i), tostring(total))
    rec._retry_label = rec.record_name or base_label

    local function submit_once()
      if rec._state == "canceled" then
        return false, "canceled"
      end
      rec._state = "running"
      rec._next_retry_at = nil
      local attempt = rec._attempt or 1
      local needs_trunc = attempt > 1 or rec._force_truncate
      if needs_trunc and rec.output_path and rec.output_path ~= "" then
        local ok_trunc, trunc_err = Files.truncate_file(rec.output_path)
        if not ok_trunc then
          Util.msg("Failed to truncate TTS output before retry: " .. tostring(trunc_err), 2)
        end
        rec._force_truncate = nil
      end

      local req, req_err = Backend.client():text_to_speech_request(
        voice_id,
        "mp3_44100_192",
        {
          text = rec.text,
          model_id = model_id
        },
        rec.output_path,
        Jobs.format_attempt_label(base_label, attempt, max_attempts),
        300
      )
      if not req then
        return Backend.request_build_failed(rec, req_err)
      end

      local function on_done(result, job)
        if rec._state == "canceled" then return end
        local output_size = Files.file_size(job.out_path)
        local ok_output = output_size and output_size > 0
        if result.ok and ok_output then
          Curl.update_last_curl_state(result, job, "Text-to-speech")
          S.status_text = string.format(t("Text-to-speech ok: %s"), tostring(rec.record_name))
          S.last_api_error = ""
          rec._state = "ok"
          rec._next_retry_at = nil
        else
          local body_txt = nil
          local body_err = nil
          local body_data, body_info = Files.slurp_with_cap(job.out_path, 128 * 1024)
          if body_data and body_data ~= "" then
            body_txt = body_data
            result.body = body_txt
          elseif body_data == nil then
            body_err = body_info
          end
          local err_txt =
            Eleven.summarize_sts_error_body(body_txt) or
            Eleven.summarize_el_error({ err = result.err, body = body_txt }) or
            result.err or
            t("Request failed.")
          if not ok_output then
            local size_label = output_size and tostring(output_size) or t("missing")
            local prefix = string.format(t("Output file empty (%s bytes)."), size_label)
            if err_txt and err_txt ~= "" then
              err_txt = prefix .. " " .. err_txt
            else
              err_txt = prefix
            end
          end
          if body_err and (not body_txt or body_txt == "") then
            err_txt = err_txt .. string.format(t(" (output read failed: %s)"), tostring(body_err))
          end
          result.ok = false
          result.err = err_txt
          Curl.update_last_curl_state(result, job, "Text-to-speech")
          local snippet = Util.clip_body_text(body_txt or result.err_txt or err_txt, 512)
          Jobs.update_record_retry_state(rec, err_txt, result, snippet)
          local retryable = Jobs.is_retryable_result(result)
          if not ok_output then retryable = true end
          if rec._retry_generation ~= S.retry_generation then retryable = false end
          local attempt_now = rec._attempt or 1
          if retryable and attempt_now < max_attempts then
            local next_attempt = attempt_now + 1
            rec._attempt = next_attempt
            Jobs.enqueue_retry(rec._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec)
            if snippet and snippet ~= "" then
              Util.msg("Retry scheduled (TTS): " .. snippet, 1)
            end
            S.last_api_error = err_txt
            S.status_text = string.format(t("Text-to-speech failed (retrying): %s"), err_txt)
          else
            rec._state = "failed_final"
            rec._next_retry_at = nil
            S.last_api_error = err_txt
            S.status_text = string.format(t("Text-to-speech failed: %s"), err_txt)
          end
        end
      end

      local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
        rec = rec,
        operation = "elevenlabs_tts",
        capture_response_body = false
      })
      if not job then
        local err_txt = string.format(t("Text-to-speech request failed to start: %s"), tostring(err))
        rec._state = "failed_final"
        rec._next_retry_at = nil
        rec._last_error_summary = err_txt
        S.status_text = err_txt
        S.last_api_error = err_txt
        return false, err_txt
      end
      job.keep_in_list = true
      rec.tts_job_id = job.id
      return true
    end

    rec._retry_submit = submit_once
    local ok_submit, submit_err = submit_once()
    if not ok_submit then
      return false, submit_err
    end
    submitted = submitted + 1
  end

  S.status_text = string.format(t("Text-to-speech jobs submitted (%s)."), tostring(submitted))
  S.last_api_error = ""
  return true
end

-- Runs ElevenLabs text to speech for selected items as part of the workflow.
-- Called by `GuiLoop`; caller passes no arguments and uses shared state.
function Eleven.run_el_text_to_speech_for_selected_items()
  local resolution_ready, voice_choices = Eleven.prepare_voice_resolution("tts_regular")
  if not resolution_ready then return end
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_tts_preflight", {})

  -- Handles fail so other code can call it.
  -- Called by several helpers (for example `run_el_speech_to_speech_for_selected_items`, `run_el_speech_to_speech_fast`, and `run_el_text_to_speech_for_selected_items`); caller passes `msg_to_show`.
  local function fail(msg_to_show)
    S.status_text = msg_to_show
    S.last_api_error = msg_to_show
    S.ui_lock_network_buttons = false
    TelemetryBridge.operation_failed("elevenlabs_tts_preflight", {
      safe_message = tostring(msg_to_show or "")
    }, telemetry_started_at)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  if (not S.el_voices) or (not S.el_voices.by_id) or (not next(S.el_voices.by_id)) then
    fail(t("No voices configured! Please fetch voices from server first."))
    return
  end

  local tts_models, default_id = Eleven.build_tts_model_list()
  if #tts_models < 1 then
    fail(t("No TTS models available! Please fetch models from server first."))
    return
  end

  local selected_model_id = Eleven.resolve_tts_model_selection(tts_models, default_id)

  local ok_out, out_err = Files.ensure_tts_output_dir()
  if not ok_out then
    fail(out_err)
    return
  end

  local ok_items, err_or_items = ReaperX.get_text_items_by_track(false, voice_choices)
  if not ok_items then
    fail(string.format(t("Text items failed: %s"), tostring(err_or_items)))
    return
  end

  local ok_records, rec_err, records = Eleven.build_tts_records(err_or_items)
  if not ok_records then
    fail(string.format(t("Text items failed: %s"), tostring(rec_err)))
    return
  end

  Jobs.full_reset_state("auto reset: TTS")
  S.ui_lock_network_buttons = true

  S.tts_records = records
  local ok_submit, submit_err = Eleven.submit_el_text_to_speech_jobs(S.tts_records, selected_model_id)
  if not ok_submit then
    fail(submit_err)
    return
  end

  S.ui_lock_network_buttons = false
  TelemetryBridge.operation_completed("elevenlabs_tts_preflight", {
    record_count = type(S.tts_records) == "table" and #S.tts_records or 0,
    model_id = selected_model_id,
    submitted = true
  }, telemetry_started_at)
end

-- Runs ElevenLabs text to speech fast as part of the workflow.
-- Called by `GuiLoop`; caller passes no arguments and uses shared state.
function Eleven.run_el_text_to_speech_fast()
  local resolution_ready, voice_choices = Eleven.prepare_voice_resolution("tts_fast")
  if not resolution_ready then return end
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_tts_fast_preflight", {})
  Jobs.bump_retry_generation()
  S.fast_tts_records = nil

  -- Handles fail so other code can call it.
  -- Called by `run_el_text_to_speech_fast`; caller passes `msg_to_show`.
  local function fail(msg_to_show)
    S.status_text = msg_to_show
    S.last_api_error = msg_to_show
    S.ui_lock_network_buttons = false
    TelemetryBridge.operation_failed("elevenlabs_tts_fast_preflight", {
      safe_message = tostring(msg_to_show or "")
    }, telemetry_started_at)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  if (not S.el_voices) or (not S.el_voices.by_id) or (not next(S.el_voices.by_id)) then
    fail(t("No voices configured! Please fetch voices from server first."))
    return
  end

  local tts_models, default_id = Eleven.build_tts_model_list()
  if #tts_models < 1 then
    fail(t("No TTS models available! Please fetch models from server first."))
    return
  end

  local selected_model_id = Eleven.resolve_tts_model_selection(tts_models, default_id)

  local ok_out, out_err = Files.ensure_tts_output_dir()
  if not ok_out then
    fail(out_err)
    return
  end

  local ok_items, err_or_items = ReaperX.get_text_items_by_track(false, voice_choices)
  if not ok_items then
    fail(string.format(t("Text items failed: %s"), tostring(err_or_items)))
    return
  end

  local ok_records, rec_err, records = Eleven.build_tts_records(err_or_items)
  if not ok_records then
    fail(string.format(t("Text items failed: %s"), tostring(rec_err)))
    return
  end

  S.fast_tts_records = records
  local ok_submit, submit_err = Eleven.submit_el_text_to_speech_jobs_fast(S.fast_tts_records, selected_model_id)
  if not ok_submit then
    fail(submit_err)
    return
  end

  S.ui_lock_network_buttons = false
  TelemetryBridge.operation_completed("elevenlabs_tts_fast_preflight", {
    record_count = type(S.fast_tts_records) == "table" and #S.fast_tts_records or 0,
    model_id = selected_model_id,
    submitted = true
  }, telemetry_started_at)
end

-- Checks whether all voice design previews are ready for insertion.
-- Returns (bool: all_ready, string: message).
-- Called by the explicit Voice Design batch-insertion UI.
function Eleven.voice_design_previews_all_ready()
  local previews = S.voice_design_records and S.voice_design_records.preview
  if type(previews) ~= "table" or #previews == 0 then
    return false, t("No previews available.")
  end
  for _, preview_rec in ipairs(previews) do
    if preview_rec._state ~= "ok" then
      return false, t("Not all previews are ready.")
    end
    if not preview_rec.output_path or preview_rec.output_path == "" then
      return false, t("Preview output path missing.")
    end
    if not r.file_exists(preview_rec.output_path) then
      return false, t("Preview output file missing.")
    end
    local valid = VoicePreview.validate_audio(preview_rec.output_path)
    if not valid then
      return false, t("Not all previews are valid audio files.")
    end
  end
  return true, "ok"
end

-- Inserts one complete Voice Design preview batch on one new track. Playback is
-- deliberately unrelated to these project items.
function Eleven.insert_voice_design_previews_to_new_track()
  local previews = S.voice_design_records and S.voice_design_records.preview
  if type(previews) ~= "table" or #previews == 0 then
    return false, t("No previews available.")
  end
  if S.voice_design_records.batch_inserted == true then
    return false, t("Preview batch already inserted.")
  end
  local all_ready, all_msg = Eleven.voice_design_previews_all_ready()
  if not all_ready then
    return false, all_msg
  end

  local ordered = {}
  for _, preview_rec in ipairs(previews) do
    table.insert(ordered, preview_rec)
  end
  table.sort(ordered, function(a, b)
    local ai = tonumber(a.preview_index) or math.huge
    local bi = tonumber(b.preview_index) or math.huge
    if ai == bi then
      return tostring(a.record_name or "") < tostring(b.record_name or "")
    end
    return ai < bi
  end)

  local prepared = {}
  local function destroy_prepared_sources()
    for _, item in ipairs(prepared) do
      if item.source then
        r.PCM_Source_Destroy(item.source)
        item.source = nil
      end
    end
  end
  for _, rec in ipairs(ordered) do
    local valid, validation_err = VoicePreview.validate_audio(rec.output_path)
    if not valid then
      destroy_prepared_sources()
      return false, string.format(
        t("Voice Design preview validation failed: %s"),
        tostring(validation_err)
      )
    end
    local source = r.PCM_Source_CreateFromFile(rec.output_path)
    if not source then
      destroy_prepared_sources()
      return false, string.format(
        t("Unable to create PCM source from file: %s"),
        tostring(rec.output_path)
      )
    end
    local length, length_is_qn = r.GetMediaSourceLength(source)
    if length_is_qn or not length or length <= 0 then
      r.PCM_Source_Destroy(source)
      destroy_prepared_sources()
      return false, t("Unable to determine Voice Design preview length.")
    end
    prepared[#prepared + 1] = { rec = rec, source = source, length = length }
  end

  local selected_tracks = {}
  for index = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, index)
    if track and r.IsTrackSelected(track) then selected_tracks[#selected_tracks + 1] = track end
  end
  local master_track = r.GetMasterTrack and r.GetMasterTrack(0) or nil
  local master_selected = master_track and r.IsTrackSelected(master_track) or false
  local selected_items = {}
  for index = 0, r.CountSelectedMediaItems(0) - 1 do
    selected_items[#selected_items + 1] = r.GetSelectedMediaItem(0, index)
  end
  local cursor_position = r.GetCursorPosition()
  local new_track = nil
  local failure = nil

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(16)
  local ok_mutation, mutation_err = pcall(function()
    local track_index = r.CountTracks(0)
    r.InsertTrackInProject(0, track_index, 0)
    new_track = r.GetTrack(0, track_index)
    if not new_track then error(t("Unable to create Voice Design preview track.")) end

    local batch_stamp = tostring(S.voice_design_records.batch_stamp or "")
    if batch_stamp == "" then batch_stamp = Util.date_time_stamp_with_time_precise() end
    batch_stamp = batch_stamp:gsub("_", " ")
    r.GetSetMediaTrackInfo_String(
      new_track,
      "P_NAME",
      t("VOICE DESIGN PREVIEWS") .. " " .. batch_stamp,
      true
    )
    r.SetTrackColor(new_track, r.ColorToNative(128, 0, 128) | 0x1000000)

    local position = tonumber(cursor_position) or 0
    for _, item_data in ipairs(prepared) do
      local item = r.AddMediaItemToTrack(new_track)
      if not item then error(t("Failed to create Voice Design preview item.")) end
      local take = r.AddTakeToMediaItem(item)
      if not take then error(t("Failed to create Voice Design preview take.")) end
      r.SetMediaItemTake_Source(take, item_data.source)
      item_data.source = nil -- ownership transferred to the take
      r.SetMediaItemInfo_Value(item, "D_POSITION", position)
      r.SetMediaItemInfo_Value(item, "D_LENGTH", item_data.length)
      r.GetSetMediaItemTakeInfo_String(
        take,
        "P_NAME",
        string.format(t("Voice Design Preview %d"), tonumber(item_data.rec.preview_index) or 0),
        true
      )
      r.UpdateItemInProject(item)
      position = position + item_data.length + 0.250
    end
  end)
  if not ok_mutation then failure = tostring(mutation_err) end
  destroy_prepared_sources()
  if failure and new_track then
    r.DeleteTrack(new_track)
    new_track = nil
  end

  for index = 0, r.CountTracks(0) - 1 do
    r.SetTrackSelected(r.GetTrack(0, index), false)
  end
  if master_track then r.SetTrackSelected(master_track, false) end
  for _, track in ipairs(selected_tracks) do
    if not r.ValidatePtr or r.ValidatePtr(track, "MediaTrack*") then
      r.SetTrackSelected(track, true)
    end
  end
  if master_selected and master_track then r.SetTrackSelected(master_track, true) end
  r.SelectAllMediaItems(0, false)
  for _, item in ipairs(selected_items) do
    if not r.ValidatePtr or r.ValidatePtr(item, "MediaItem*") then
      r.SetMediaItemSelected(item, true)
    end
  end
  r.SetEditCurPos(cursor_position, false, false)
  r.PreventUIRefresh(-16)
  r.Undo_EndBlock2(0, t("Insert Voice Design previews"), -1)
  r.UpdateArrange()

  if failure then
    return false, string.format(t("Failed to insert Voice Design previews: %s"), failure)
  end
  S.voice_design_records.batch_inserted = true
  S.status_text = t("Voice Design previews inserted to a new track.")
  S.last_api_error = ""
  return true, "ok"
end

-- Submits OpenAI rewrite jobs as part of the workflow.
-- Called by `run_openai_text_rewrite_for_selected_items`; caller passes `records`.
function OpenAI.submit_openai_text_rewrite_jobs(records)
  if not records or #records < 1 then
    return false, t("No text items to process.")
  end
  if not CFG.openai_model or CFG.openai_model == "" then
    return false, t("Missing OpenAI model.")
  end

  local track_map = {}
  local total = #records
  local submitted = 0
  local max_attempts = tonumber(CFG.retry_max_attempts_openai) or 3

  local function insert_grouped_results(rec_ref, id_to_text)
    local items = rec_ref.items or {}
    if #items < 1 then
      return false, t("Batch record has no source items.")
    end
    local inline_mode = (S.openai_insert_inline ~= false)
    local used_batch_undo = false
    if inline_mode then
      r.Undo_BeginBlock2(0)
      r.PreventUIRefresh(16)
      used_batch_undo = true
    end

    local function finish_batch_undo(label)
      if used_batch_undo then
        r.PreventUIRefresh(-16)
        r.Undo_EndBlock2(0, label, 4)
        r.UpdateArrange()
      end
    end

    for _, src in ipairs(items) do
      local id_key = tostring(src.id or "")
      local out_text = id_to_text[id_key]
      if type(out_text) ~= "string" or out_text == "" then
        finish_batch_undo("OpenAI inline batch")
        return false, string.format(t("Missing output text for source id %s"), tostring(id_key))
      end
      local ok_insert, insert_err = ReaperX.openai_insert_text_result(src, track_map, out_text, {
        inline = inline_mode,
        skip_undo = inline_mode
      })
      if not ok_insert then
        finish_batch_undo("OpenAI inline batch")
        return false, string.format(t("Insert failed for id %s: %s"), tostring(id_key), tostring(insert_err))
      end
    end
    finish_batch_undo("OpenAI inline batch")
    rec_ref.openai_inserted = true
    return true
  end

  for i, rec in ipairs(records) do
    local rec_ref = rec
    rec_ref._attempt = 1
    rec_ref._max_attempts = max_attempts
    rec_ref._auth_refresh_used_once = false
    rec_ref._retry_generation = S.retry_generation
    local base_label = string.format(t("OpenAI rewrite %s/%s"), tostring(i), tostring(total))
    rec_ref._retry_label = rec_ref.record_name or base_label

    local function submit_once()
      if rec_ref._state == "canceled" then
        return false, "canceled"
      end
      rec_ref._state = "running"
      rec_ref._next_retry_at = nil
      local attempt = rec_ref._attempt or 1
      local mode = OpenAI.normalize_rewrite_mode(rec_ref.mode or S.openai_rewrite_mode)
      local is_batch_mode = mode ~= "per_item"
      local req, req_err = nil, nil
      if is_batch_mode then
        req, req_err = OpenAI.build_openai_batch_request(rec_ref, base_label, attempt, max_attempts)
        if not req then
          return false, req_err or t("Failed to build OpenAI batch request.")
        end
      else
        local req_input = rec_ref.text
        if type(req_input) ~= "string" or req_input == "" then
          return false, t("OpenAI request missing input text.")
        end
        local instructions = CFG.openai_rewrite_prompt
        req, req_err = Backend.client():openai_rewrite_request(
          {
            model = CFG.openai_model,
            instructions = instructions,
            input = req_input
          },
          Jobs.format_attempt_label(base_label, attempt, max_attempts),
          120
        )
        if not req then
          return Backend.request_build_failed(rec_ref, req_err)
        end
      end

      local opts = {
        read_body = true,
        keep_output = false
      }

      local function on_done(result, job)
        if rec_ref._state == "canceled" then return end
        local body_txt = result.body or ""
        if body_txt == "" and job and job.out_path then
          local body_data = Files.slurp_with_cap(job.out_path, 128 * 1024)
          if body_data and body_data ~= "" then
            body_txt = body_data
            result.body = body_txt
          end
        end

        local force_retry = false
        local force_no_retry = false
        if result.ok then
          local ok_dec, decoded = pcall(json.decode, body_txt)
          if ok_dec and type(decoded) == "table" then
            if is_batch_mode then
              local id_to_text, batch_err = OpenAI.extract_openai_batch_output(decoded, rec_ref.expected_ids or {})
              if id_to_text then
                rec_ref.openai_output_text = TelemetryBridge.try_encode_json(id_to_text, 2048)
                local ok_insert, ins_err = insert_grouped_results(rec_ref, id_to_text)
                if ok_insert then
                  Curl.update_last_curl_state(result, job, "OpenAI rewrite")
                  S.status_text = string.format(t("OpenAI rewrite ok: %s"), tostring(rec_ref.record_name))
                  S.last_api_error = ""
                  rec_ref._state = "ok"
                  rec_ref._next_retry_at = nil
                  return
                else
                  result.ok = false
                  result.err = string.format(t("OpenAI insert failed: %s"), tostring(ins_err))
                  force_no_retry = true
                end
              else
                local err_txt = batch_err or t("OpenAI batch response parse failed.")
                if err_txt == "" then
                  err_txt = t("OpenAI batch response parse failed.")
                end
                result.ok = false
                result.err = err_txt
                force_retry = true
                if Jobs.is_openai_refusal_error(err_txt) then
                  force_retry = false
                  force_no_retry = true
                end
              end
            else
              local out_text, out_err = OpenAI.extract_openai_output_text(decoded)
              if out_text and out_text ~= "" then
                rec_ref.openai_output_text = out_text
                Curl.update_last_curl_state(result, job, "OpenAI rewrite")
                S.status_text = string.format(t("OpenAI rewrite ok: %s"), tostring(rec_ref.record_name))
                S.last_api_error = ""
                rec_ref._state = "ok"
                rec_ref._next_retry_at = nil
                local target_rec = rec_ref.source_item or rec_ref
                local ok_insert, ins_err = ReaperX.openai_insert_text_result(target_rec, track_map, out_text, {
                  inline = (S.openai_insert_inline ~= false)
                })
                if not ok_insert then
                  local msg_txt = string.format(t("OpenAI insert failed: %s"), tostring(ins_err))
                  table.insert(S.warnings, msg_txt)
                  S.status_text = msg_txt
                  S.last_api_error = msg_txt
                end
                return
              else
                local err_txt = out_err or t("OpenAI response missing output text.")
                if err_txt == "" then
                  err_txt = t("OpenAI response missing output text.")
                end
                result.ok = false
                result.err = err_txt
                force_retry = true
                if Jobs.is_openai_refusal_error(err_txt) then
                  force_retry = false
                  force_no_retry = true
                end
              end
            end
          else
            local err_txt = string.format(t("OpenAI response decode failed: %s"), tostring(decoded))
            result.ok = false
            result.err = err_txt
            force_retry = true
          end
        end

        local err_txt = result.err or OpenAI.summarize_openai_error(result)
        result.err = err_txt
        Curl.update_last_curl_state(result, job, "OpenAI rewrite")
        local snippet = Util.clip_body_text(body_txt or result.err_txt or err_txt, 512)
        Jobs.update_record_retry_state(rec_ref, err_txt, result, snippet)
        local retryable = Jobs.is_retryable_result(result)
        if force_retry then retryable = true end
        if force_no_retry then retryable = false end
        if rec_ref._retry_generation ~= S.retry_generation then retryable = false end
        local attempt_now = rec_ref._attempt or 1
        if retryable and attempt_now < max_attempts then
          local next_attempt = attempt_now + 1
          rec_ref._attempt = next_attempt
          Jobs.enqueue_retry(rec_ref._retry_label or base_label, submit_once, next_attempt, max_attempts, err_txt, rec_ref)
          if snippet and snippet ~= "" then
            Util.msg("Retry scheduled (OpenAI): " .. snippet, 1)
          end
          S.last_api_error = err_txt
          S.status_text = string.format(t("OpenAI rewrite failed (retrying): %s"), err_txt)
        else
          rec_ref._state = "failed_final"
          rec_ref._next_retry_at = nil
          S.last_api_error = err_txt
          S.status_text = string.format(t("OpenAI rewrite failed: %s"), err_txt)
        end
      end

      local job, err = TelemetryBridge.submit_curl(req, on_done, opts, {
        rec = rec_ref,
        operation = "elevenlabs_openai_rewrite",
        capture_response_body = true
      })
      if not job then
        local err_txt = string.format(t("OpenAI request failed to start: %s"), tostring(err))
        rec_ref._state = "failed_final"
        rec_ref._next_retry_at = nil
        rec_ref._last_error_summary = err_txt
        S.status_text = err_txt
        S.last_api_error = err_txt
        return false, err_txt
      end
      job.keep_in_list = true
      rec_ref.openai_job_id = job.id
      return true
    end

    rec_ref._retry_submit = submit_once
    local ok_submit, submit_err = submit_once()
    if not ok_submit then
      return false, submit_err
    end
    submitted = submitted + 1
  end

  S.status_text = string.format(t("OpenAI rewrite jobs submitted (%s)."), tostring(submitted))
  S.last_api_error = ""
  return true
end

-- Runs OpenAI rewrite for selected items as part of the workflow.
-- Called by `GuiLoop`; caller passes no arguments and uses shared state.
function OpenAI.run_openai_text_rewrite_for_selected_items()
  S.ui_lock_network_buttons = true
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_openai_rewrite_preflight", {
    rewrite_mode = tostring(S.openai_rewrite_mode or "")
  })
  Jobs.bump_retry_generation()
  S.openai_records = nil

  -- Handles fail so other code can call it.
  -- Called by `run_openai_text_rewrite_for_selected_items`; caller passes `msg_to_show`.
  local function fail(msg_to_show)
    S.status_text = msg_to_show
    S.last_api_error = msg_to_show
    table.insert(S.warnings, msg_to_show)
    S.ui_lock_network_buttons = false
    TelemetryBridge.operation_failed("elevenlabs_openai_rewrite_preflight", {
      safe_message = tostring(msg_to_show or ""),
      rewrite_mode = tostring(S.openai_rewrite_mode or "")
    }, telemetry_started_at)
  end

  local ok_auth, auth_msg = Auth.ensure_access_token()
  if not ok_auth then
    fail(auth_msg)
    return
  end

  local mode = OpenAI.normalize_rewrite_mode(S.openai_rewrite_mode)
  S.openai_rewrite_mode = mode

  local ok_items, src_err, source_items = OpenAI.collect_selected_source_items()
  if not ok_items then
    fail(string.format(t("Text items failed: %s"), tostring(src_err)))
    return
  end

  local ok_records, rec_err, records = OpenAI.build_openai_text_records(source_items, mode)
  if not ok_records then
    fail(string.format(t("Text items failed: %s"), tostring(rec_err)))
    return
  end

  S.openai_records = records
  local ok_submit, submit_err = OpenAI.submit_openai_text_rewrite_jobs(S.openai_records)
  if not ok_submit then
    fail(submit_err)
    return
  end

  S.ui_lock_network_buttons = false
  TelemetryBridge.operation_completed("elevenlabs_openai_rewrite_preflight", {
    record_count = type(S.openai_records) == "table" and #S.openai_records or 0,
    rewrite_mode = tostring(mode or ""),
    submitted = true
  }, telemetry_started_at)
end

do --adding results to project
  -- Checks whether the speech-to-speech record ready so we can branch safely.
  -- Called by `ReaperX.add_all_sts_results_to_project`; caller passes `rec`.
  local function is_sts_record_ready(rec)
    if not rec or not rec.sts_job_id then return false, t("no job id") end
    local job = S.curl_jobs[rec.sts_job_id]
    if not job then return false, t("job missing") end
    if job.phase ~= "completed" then return false, t("job not completed") end
    if not job.result or job.result.ok ~= true then return false, t("job failed") end
    local sz = Files.file_size(rec.output_path)
    if not sz or sz <= 0 then return false, t("empty output") end
    return true, t("ok")
  end

  -- Checks whether the text-to-speech record ready so we can branch safely.
  local function is_tts_record_ready(rec)
    if not rec or not rec.tts_job_id then return false, t("no job id") end
    local job = S.curl_jobs[rec.tts_job_id]
    if not job then return false, t("job missing") end
    if job.phase ~= "completed" then return false, t("job not completed") end
    if not job.result or job.result.ok ~= true then return false, t("job failed") end
    local sz = Files.file_size(rec.output_path)
    if not sz or sz <= 0 then return false, t("empty output") end
    return true, t("ok")
  end

  -- Adds results to project so results appear in the project.
  -- Called by `ReaperX.add_all_sts_results_to_project` and `ReaperX.add_all_tts_results_to_project`; caller passes `records` and `opts`.
  local function add_results_to_project(records, opts)
    if not records or #records < 1 then
      S.status_text = (opts and opts.empty_msg) or t("No results to add to project.")
      table.insert(S.warnings, S.status_text)
      return false, 0, S.status_text
    end

    local ready_fn = opts and opts.ready_fn
    if type(ready_fn) ~= "function" then
      ready_fn = function() return true, "ok" end
    end

    local added_count = 0
    local seen_tracks = {}
    local result_label = opts and opts.result_label or "results"
    local track_prefix = opts and opts.track_prefix or "RESULT_"
    local track_color = opts and opts.track_color
    for i, rec in ipairs(records) do
      local ok_ready, ready_err = ready_fn(rec)
      if ok_ready and not is_valid_media_track(rec and rec.track) then
        ok_ready = false
        ready_err = t("missing source track")
      end
      if not ok_ready then
        local label = rec and (rec.record_name or rec.region_name or rec.item_label or rec.output_path or ("item " .. tostring(i))) or tostring(i)
        S.status_text = string.format(t("Skipping file %s: %s"), tostring(label), tostring(ready_err))
        table.insert(S.warnings, S.status_text)
      else
        local track = rec.track
        local track_to_add_item_to = seen_tracks[track]
        if not track_to_add_item_to then
          -- add new track below original track
          local track_idx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
          local new_track_idx = track_idx
          r.InsertTrackAtIndex(new_track_idx, true)
          local new_track = r.GetTrack(0, new_track_idx)
          if new_track then
            local _, orig_name = r.GetTrackName(track)
            local new_name = track_prefix .. (orig_name or "Track")
            r.GetSetMediaTrackInfo_String(new_track, "P_NAME", new_name, true)
            if track_color then
              r.SetTrackColor(
                new_track,
                r.ColorToNative(track_color.r, track_color.g, track_color.b) | 0x1000000
              )
            end
            track_to_add_item_to = new_track
            seen_tracks[track] = new_track
          else
            S.status_text = string.format(t("Added so far: %s; error adding new track, aborting!"), added_count)
            table.insert(S.warnings, S.status_text)
            return false, added_count, S.status_text
          end
        end
        -- add media item to track_to_add_item_to
        r.Undo_BeginBlock2(0)
        r.PreventUIRefresh(16)
        -- unselect all tracks
        r.Main_OnCommand(40297, 0)
        -- select only track_to_add_item_to track
        r.SetMediaTrackInfo_Value(track_to_add_item_to, 'I_SELECTED', 1)
        -- scroll cursor to needed position
        r.SetEditCurPos(rec.track_position, false, false)
        r.InsertMedia(rec.output_path, 0) -- 0=add to current track

        -- end undo block and unfreeze UI
        r.PreventUIRefresh(-16)
        local label = rec.record_name or rec.region_name or rec.item_label or "result"
        r.Undo_EndBlock2(0, 'Added ' .. tostring(label), 4)
        r.UpdateArrange()
        added_count = added_count + 1

      end --if ok_ready
    end --for

    S.status_text = string.format(t("Added %s %s to project."), tostring(added_count), tostring(result_label))
    S.last_api_error = ""
    return true, added_count, S.status_text
  end

  -- Adds all speech-to-speech results to project so results appear in the project.
  -- Called by `GuiLoop`; caller passes no arguments and uses shared state.
  function ReaperX.add_all_sts_results_to_project()
    local telemetry_started_at = TelemetryBridge.now()
    TelemetryBridge.operation_started("elevenlabs_sts_add_results", {
      record_count = type(S.rendered_regions) == "table" and #S.rendered_regions or 0
    })
    local opts = {
      empty_msg = t("No rendered regions to add results for."),
      ready_fn = is_sts_record_ready,
      result_label = t("speech-to-speech results"),
      track_color = { r = 0, g = 255, b = 0 },
      track_prefix = "RESULT_"
    }
    local ok_add, added_count, msg = add_results_to_project(S.rendered_regions, opts)
    if ok_add then
      TelemetryBridge.operation_completed("elevenlabs_sts_add_results", {
        added_count = added_count
      }, telemetry_started_at)
    else
      TelemetryBridge.operation_failed("elevenlabs_sts_add_results", {
        added_count = added_count,
        safe_message = tostring(msg or "")
      }, telemetry_started_at)
    end
  end

  -- Adds all text-to-speech results to project so results appear in the project.
  -- Called by `GuiLoop`; caller passes no arguments and uses shared state.
  function ReaperX.add_all_tts_results_to_project()
    local telemetry_started_at = TelemetryBridge.now()
    TelemetryBridge.operation_started("elevenlabs_tts_add_results", {
      record_count = type(S.tts_records) == "table" and #S.tts_records or 0
    })
    local opts = {
      empty_msg = t("No TTS records to add results for."),
      ready_fn = is_tts_record_ready,
      result_label = t("text-to-speech results"),
      track_color = { r = 255, g = 172, b = 28 },
      track_prefix = "RESULT_"
    }
    local ok_add, added_count, msg = add_results_to_project(S.tts_records, opts)
    if ok_add then
      TelemetryBridge.operation_completed("elevenlabs_tts_add_results", {
        added_count = added_count
      }, telemetry_started_at)
    else
      TelemetryBridge.operation_failed("elevenlabs_tts_add_results", {
        added_count = added_count,
        safe_message = tostring(msg or "")
      }, telemetry_started_at)
    end
  end
end --adding results to project

-- Shared Audio tags actions so button and hotkey paths stay behavior-identical.
function UI.run_audio_tags_insert_selected_notes()
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_audio_tags_insert", {
    has_text = Util.trim(S.audio_tags_input or "") ~= ""
  })
  local ok_insert, msg, _, failed_count = ReaperX.prepend_text_to_selected_item_notes(S.audio_tags_input)
  S.status_text = tostring(msg or "")
  if ok_insert then
      S.last_api_error = ""
    if (tonumber(failed_count) or 0) > 0 then
      if type(S.warnings) ~= "table" then S.warnings = {} end
      table.insert(S.warnings, tostring(msg or t("Some selected item notes were not updated.")))
    end
    TelemetryBridge.operation_completed("elevenlabs_audio_tags_insert", {
      failed_count = tonumber(failed_count) or 0
    }, telemetry_started_at)
  else
    S.last_api_error = tostring(msg or "")
    if type(S.warnings) ~= "table" then S.warnings = {} end
    table.insert(S.warnings, tostring(msg or t("Failed to insert audio tags to selected item notes.")))
    TelemetryBridge.operation_failed("elevenlabs_audio_tags_insert", {
      failed_count = tonumber(failed_count) or 0,
      safe_message = tostring(msg or "")
    }, telemetry_started_at)
  end
  return ok_insert, msg, failed_count
end

function UI.run_audio_tags_remove_brackets_selected_notes()
  local telemetry_started_at = TelemetryBridge.now()
  TelemetryBridge.operation_started("elevenlabs_audio_tags_remove_brackets", {})
  local ok_remove, updated_count, failed_count, msg = ReaperX.remove_brackets_in_selected_items_notes()
  local err_msg = tostring(msg or "")
  S.status_text = string.format(
    t("updated=%d; %s"),
    tonumber(updated_count) or 0,
    err_msg
  )
  if ok_remove then
    S.last_api_error = ""
    TelemetryBridge.operation_completed("elevenlabs_audio_tags_remove_brackets", {
      updated_count = tonumber(updated_count) or 0,
      failed_count = tonumber(failed_count) or 0
    }, telemetry_started_at)
  else
    S.last_api_error = err_msg
    if type(S.warnings) ~= "table" then S.warnings = {} end
    table.insert(S.warnings, err_msg)
    TelemetryBridge.operation_failed("elevenlabs_audio_tags_remove_brackets", {
      updated_count = tonumber(updated_count) or 0,
      failed_count = tonumber(failed_count) or 0,
      safe_message = err_msg
    }, telemetry_started_at)
  end
  return ok_remove, updated_count, failed_count, msg
end


--==================================================================================================
--ACTIONS INSTALLS
--==================================================================================================

local ACTIONS = {
  {
    id = "fast_STS_flow_action_for_hotkey_trigger",
    wrapper_relative_path = "actions-neurocast/action_neurocast_tools_fast_sts_action.lua",
    label = t("Fast Voice to Voice action"),
    cooldown_sec = 1,
    needs_network = true,
    fn = function()
      local scheduled = Jobs.schedule_job(t("Fast speech-to-speech"), function()
        Eleven.run_el_speech_to_speech_fast()
      end)
      if not scheduled then
        local msg_txt = t("Could not schedule fast speech-to-speech job.")
        S.status_text = msg_txt
        S.last_api_error = msg_txt
        return false, msg_txt
      end
      return true
    end
  },
  {
    id = "fast_TTS_flow_action_for_hotkey_trigger",
    wrapper_relative_path = "actions-neurocast/action_neurocast_tools_fast_tts_action.lua",
    label = t("Fast Text to Speech action"),
    cooldown_sec = 1,
    needs_network = true,
    fn = function()
      local scheduled = Jobs.schedule_job(t("Fast text-to-speech"), function()
        Eleven.run_el_text_to_speech_fast()
      end)
      if not scheduled then
        local msg_txt = t("Could not schedule fast text-to-speech job.")
        S.status_text = msg_txt
        S.last_api_error = msg_txt
        return false, msg_txt
      end
      return true
    end
  },
  {
    id = "audio_tags_insert_selected_notes_action_for_hotkey_trigger",
    wrapper_relative_path = "actions-neurocast/action_neurocast_tools_audio_tags_insert_action.lua",
    label = t("Audio tags insert selected notes action"),
    cooldown_sec = 0.1,
    needs_network = false,
    fn = function()
      UI.run_audio_tags_insert_selected_notes()
      return true
    end
  },
  {
    id = "audio_tags_remove_brackets_selected_notes_action_for_hotkey_trigger",
    wrapper_relative_path = "actions-neurocast/action_neurocast_tools_audio_tags_remove_brackets_action.lua",
    label = t("Audio tags remove brackets selected notes action"),
    cooldown_sec = 0.1,
    needs_network = false,
    fn = function()
      UI.run_audio_tags_remove_brackets_selected_notes()
      return true
    end
  }
}

local ACTION_STATE = {
  last_seen = {},
  last_fired_at = {}
}

do -- ACTIONS

  -- Resolves one maintained wrapper without deriving its path from localized UI text.
  -- Called by `install_actions_on_startup`; caller passes `action`.
  local function action_wrapper_paths(action)
    if not action or not action.id or action.id == "" then
      return nil, nil, t("invalid action id")
    end
    if not script_path or script_path == "" then
      return nil, nil, t("script path not set")
    end
    local relative_path = tostring(action.wrapper_relative_path or "")
    local filename = relative_path:match("([^/\\]+)$")
    if relative_path == "" or not filename then
      return nil, nil, t("maintained action wrapper path not set")
    end
    return filename, Util.path_join(script_path, relative_path), nil
  end

  -- Registers an existing maintained wrapper as a direct-source fallback.
  -- Called by `install_actions_on_startup`; caller passes `action` and `full_path`.
  local function add_existing_wrapper_action_to_reaper_menu(action, full_path)
    if not action or not action.id or action.id == "" then
      return false, t("invalid action id")
    end
    if not full_path or full_path == "" then
      return false, t("maintained action wrapper path not set")
    end
    if not r.file_exists(full_path) then
      return false, string.format(t("Maintained action wrapper file is missing; it was not generated: %s"), full_path)
    end
    local cmd_id = r.AddRemoveReaScript(true, 0, full_path, true)
    -- add to main action list, force update
    if cmd_id and cmd_id ~= 0 then
      local ok_message = string.format(t("Added wrapper action to Reaper menu: %s"), (action.label or action.id))
      S.status_text = ok_message
      return true, cmd_id
    else
      local fail_message = string.format(t("Failed to add wrapper action to Reaper menu: %s"), (action.label or action.id))
      table.insert(S.warnings, fail_message)
      Util.msg(fail_message, 2)
      return false, fail_message
    end --cmd_id

  end --function add_existing_wrapper_action_to_reaper_menu(action, full_path)

  -- Checks whether the script registered so we can branch safely.
  -- Called by `install_actions_on_startup`; caller passes `filename`.
  local function IsScriptRegistered(filename)
    local resource_path = r.GetResourcePath()
    if (not resource_path) or (resource_path == '') then
        return -1, t("Failed to get Reaper resource path!")
    end --if
    local path = Util.path_join(resource_path, 'reaper-kb.ini')
    local f = io.open(path, "r")
    if not f then
        return -1, t("Failed to open reaper-kb.ini!")
    end --if not f
    local content = f:read("*all")
    f:close()

    if content and content:find(filename, 1, true) then
        return 1, t("Found!")
    end
      return 0, t("Not found!")
  end

  -- Installs actions on startup.
  -- Called during startup; caller passes no arguments and uses shared state.
  function Actions.install_actions_on_startup()
    for _, action in ipairs(ACTIONS) do
      local filename, full_path, path_err = action_wrapper_paths(action)
      if not filename then
        local warn = string.format(t("Action install failed (%s): %s"), action.label or action.id, tostring(path_err))
        table.insert(S.warnings, warn)
        Util.msg(warn, 3)
      elseif not r.file_exists(full_path) then
        local warn = string.format(t("Maintained action wrapper file is missing; it was not generated: %s"), full_path)
        table.insert(S.warnings, warn)
        Util.msg(warn, 3)
      else
        local has_action, has_action_msg = IsScriptRegistered(filename)
        if has_action == 0 then
          local ok, err = add_existing_wrapper_action_to_reaper_menu(action, full_path)
          if not ok then
            local warn = string.format(t("Action install failed (%s): %s"), action.label or action.id, tostring(err))
            table.insert(S.warnings, warn)
            Util.msg(warn, 3)
          end
        elseif has_action == -1 then
          local warn = string.format(t("Action install check failed (%s): %s"), action.label or action.id, tostring(has_action_msg))
          table.insert(S.warnings, warn)
          Util.msg(warn, 3)
        end
      end
    end
  end

  -- Initializes action flags.
  -- Called during startup; caller passes no arguments and uses shared state.
  function Actions.init_action_flags()
    for _, action in ipairs(ACTIONS) do
      local key = action.id
      if key and key ~= "" then
        local stamp = r.GetExtState(extstate_sections_keys.EXT_SECTION_for_firing_actions, key) or ""
        ACTION_STATE.last_seen[key] = stamp
        r.SetExtState(extstate_sections_keys.EXT_SECTION_for_firing_actions, key, "", false)
      end
    end
  end

  -- Checks whether the fire action so we can guard the UI.
  -- Called by `poll_action_flags`; caller passes `action` and `now_time`.
  function Actions.can_fire_action(action, now_time)
    if action.needs_network and (Jobs.network_busy() or S.ui_lock_network_buttons) then
      return false, "network busy"
    end
    local cooldown = tonumber(action.cooldown_sec) or 0
    if cooldown > 0 then
      local last_fired = ACTION_STATE.last_fired_at[action.id]
      if last_fired and (now_time - last_fired) < cooldown then
        return false, "cooldown"
      end
    end
    return true
  end

  -- Polls action flags so async work keeps moving.
  -- Called by `GuiLoop`; caller passes no arguments and uses shared state.
  function Actions.poll_action_flags()
    for _, action in ipairs(ACTIONS) do
      local key = action.id
      if key and key ~= "" then
        local stamp = r.GetExtState(extstate_sections_keys.EXT_SECTION_for_firing_actions, key) or ""
        if stamp ~= "" and stamp ~= ACTION_STATE.last_seen[key] then
          ACTION_STATE.last_seen[key] = stamp
          local now = r.time_precise()
          local ok_to_fire = Actions.can_fire_action(action, now)
          if ok_to_fire then
            ACTION_STATE.last_fired_at[key] = now
            TelemetryBridge.safe_event("feature_used", {
              operation = "elevenlabs_hotkey_action",
              status = "fired",
              action_id = tostring(action.id or ""),
              action_label = tostring(action.label or "")
            }, {
              operation = "elevenlabs_hotkey_action",
              status = "fired"
            })
            local ok, result_or_err, maybe_err = pcall(action.fn)
            if not ok then
              local warn = string.format(t("Action '%s' failed: %s"), action.label or key, tostring(result_or_err))
              table.insert(S.warnings, warn)
              Util.msg(warn, 2)
              TelemetryBridge.operation_failed("elevenlabs_hotkey_action", {
                action_id = tostring(action.id or ""),
                action_label = tostring(action.label or ""),
                safe_message = tostring(result_or_err or "")
              })
            elseif result_or_err == false then
              local warn = string.format(
                t("Action '%s' failed: %s"),
                action.label or key,
                tostring(maybe_err or t("unknown error"))
              )
              table.insert(S.warnings, warn)
              Util.msg(warn, 2)
              TelemetryBridge.operation_failed("elevenlabs_hotkey_action", {
                action_id = tostring(action.id or ""),
                action_label = tostring(action.label or ""),
                safe_message = tostring(maybe_err or t("unknown error"))
              })
            end
          end
        end
      end
    end
  end

end --do ACTIONS

local function diagnostics_threshold_label(level)
  local labels = {
    [0] = t("Debug"),
    [1] = t("Info"),
    [2] = t("Warnings"),
    [3] = t("Errors"),
    [4] = t("Off")
  }
  return labels[tonumber(level)] or labels[4]
end

function UI.render_diagnostics_settings()
  local diagnostics = Util.get_diagnostics_state()

  ImGui.Text(ctx, t("Logging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(
    ctx,
    "##elevenlabs_logging_threshold",
    diagnostics_threshold_label(diagnostics.logging_threshold),
    ImGui.ComboFlags_HeightRegular
  ) then
    local levels = { 4, 0, 1, 2, 3 }
    for _, level in ipairs(levels) do
      local selected = diagnostics.logging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_logging_threshold(level)
        if not ok_set then
          table.insert(S.warnings, string.format(t("Logging threshold save failed: %s"), tostring(err)))
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  ImGui.Text(ctx, t("Messaging threshold") .. ":")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(
    ctx,
    "##elevenlabs_messaging_threshold",
    diagnostics_threshold_label(diagnostics.messaging_threshold),
    ImGui.ComboFlags_HeightRegular
  ) then
    local levels = { 0, 1, 2, 3, 4 }
    for _, level in ipairs(levels) do
      local selected = diagnostics.messaging_threshold == level
      if ImGui.Selectable(ctx, diagnostics_threshold_label(level), selected) then
        local ok_set, err = Util.set_messaging_threshold(level)
        if not ok_set then
          table.insert(S.warnings, string.format(t("Messaging threshold save failed: %s"), tostring(err)))
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end

  diagnostics = Util.get_diagnostics_state()
  UI.ui_info(string.format(t("Log folder: %s"), diagnostics.log_dir))
  UI.ui_info(string.format(
    t("Current log file: %s"),
    diagnostics.current_log_file ~= "" and diagnostics.current_log_file or t("(created after the first matching message)")
  ))
  if UI.button_clicked("copy_diagnostics_log_folder_btn", t("Copy log folder"), 0.2) then
    ImGui.SetClipboardText(ctx, diagnostics.log_dir)
  end
  UI.ui_info(t("Local logs may contain project paths, filenames, and workflow content."))
  if diagnostics.messaging_threshold == 4 then
    UI.ui_warning(t("Messaging is Off. Util-driven errors may be hidden."))
  end
end

function UI.render_telemetry_level_setting()
  local desc = TelemetryBridge.describe_status()
  local current_level = tostring(desc.effective_level or "support")
  local current_level_label = TelemetryBridge.level_label(current_level)
  ImGui.SetNextItemWidth(ctx, 160)
  if ImGui.BeginCombo(ctx, t("Telemetry level") .. "##elevenlabs_telemetry_level", current_level_label, ImGui.ComboFlags_HeightRegular) then
    local levels = { "basic", "support", "debug" }
    for _, level in ipairs(levels) do
      local selected = current_level == level
      local level_label = TelemetryBridge.level_label(level)
      if ImGui.Selectable(ctx, level_label, selected) then
        local ok_call, ok_set, set_or_err = pcall(Telemetry.set_level, level)
        if ok_call and ok_set then
          S.telemetry_ui_status = string.format(t("Telemetry level set to %s."), level_label)
          TelemetryBridge.safe_event("feature_used", {
            operation = "elevenlabs_telemetry_settings",
            status = "level_changed",
            telemetry_level = level
          }, {
            operation = "elevenlabs_telemetry_settings",
            status = "level_changed"
          })
        else
          local err = ok_call and set_or_err or ok_set
          S.telemetry_ui_status = string.format(t("Telemetry level save failed: %s"), tostring(err))
          table.insert(S.warnings, S.telemetry_ui_status)
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

function UI.render_telemetry_section()
  local desc = TelemetryBridge.describe_status()
  local header_state = TelemetryBridge.header_state(desc)
  local header_label = string.format(t("Telemetry (%s)"), header_state) .. "###elevenlabs_telemetry_section"
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  local telemetry_open = ImGui.CollapsingHeader(ctx, header_label)
  ImGui.PopStyleColor(ctx)
  if not telemetry_open then
    return
  end

  local progress = TelemetryBridge.progress_text(desc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TelemetryBridge.status_color(desc))
  ImGui.TextWrapped(ctx, string.format(t("Telemetry status: %s"), tostring(desc.status or "")))
  ImGui.PopStyleColor(ctx)
  if not ImGui.BeginTable then
    UI.ui_info(string.format(t("Telemetry progress: %s"), progress))
  else
    local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "##elevenlabs_telemetry_status_table", 2, flags, -1, 0) then
      ImGui.TableSetupColumn(ctx, t("Field"), ImGui.TableColumnFlags_WidthFixed, 180)
      ImGui.TableSetupColumn(ctx, t("Value"), ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableHeadersRow(ctx)

      local rows = {
        { t("Status"), tostring(desc.status or "") },
        { t("Progress"), progress },
        { t("Level"), TelemetryBridge.level_label(desc.effective_level) },
        { t("Queue bytes"), tostring(tonumber(desc.sendable_queue_bytes) or 0) },
        { t("Queued / flushed"), string.format("%d / %d", tonumber(desc.queued_events_session) or 0, tonumber(desc.flushed_events_session) or 0) },
        { t("Failed / dropped / skipped"), string.format("%d / %d / %d", tonumber(desc.failed_batches_session) or 0, tonumber(desc.dropped_events_session) or 0, tonumber(desc.skipped_events_session) or 0) },
        { t("HTTP / curl"), string.format("%s / %s", tostring(desc.last_http_code or "-"), tostring(desc.last_curl_exitcode or "-")) }
      }

      for _, row in ipairs(rows) do
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.TextWrapped(ctx, row[1])
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.TextWrapped(ctx, row[2])
      end
      ImGui.EndTable(ctx)
    end
  end

  if Util.trim(S.telemetry_ui_status or "") ~= "" then
    UI.ui_info(S.telemetry_ui_status)
  end

  local flush_disabled = desc.active_job_id ~= nil
  if flush_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("telemetry_flush_now_btn", t("Flush telemetry now"), 0.2) then
    TelemetryBridge.safe_flush_async("elevenlabs_manual")
  end
  if flush_disabled then ImGui.EndDisabled(ctx) end

  if desc.send_paused then
    ImGui.SameLine(ctx)
    if UI.button_clicked("telemetry_resume_btn", t("Resume telemetry sending"), 0.2) then
      local ok_resume, resume_or_err = pcall(Telemetry.resume_sending, t("manual resume from ElevenLabs UI"))
      S.telemetry_ui_status = ok_resume and t("Telemetry sending resumed.") or string.format(t("Telemetry resume failed: %s"), tostring(resume_or_err))
    end
  end

  ImGui.SameLine(ctx)
  if UI.button_clicked("telemetry_copy_paths_btn", t("Copy telemetry paths"), 0.2) then
    local paths = desc.paths or {}
    ImGui.SetClipboardText(ctx, table.concat({
      t("settings_path") .. ": " .. tostring(desc.settings_path or ""),
      t("queue_path") .. ": " .. tostring(desc.queue_path or ""),
      t("runtime_root") .. ": " .. tostring(paths.root or ""),
      t("queues") .. ": " .. tostring(paths.queues or ""),
      t("sending") .. ": " .. tostring(paths.sending or ""),
      t("failed") .. ": " .. tostring(paths.failed or ""),
      t("logs") .. ": " .. tostring(paths.logs or ""),
      t("close_send") .. ": " .. tostring(paths.close_send or "")
    }, "\n"))
    S.telemetry_ui_status = t("Telemetry paths copied.")
  end

  local details = {
    t("initialized") .. ": " .. tostring(desc.initialized == true),
    t("settings_path") .. ": " .. tostring(desc.settings_path or ""),
    t("queue_path") .. ": " .. tostring(desc.queue_path or ""),
    t("runtime_root") .. ": " .. tostring(desc.paths and desc.paths.root or ""),
    t("effective_level") .. ": " .. tostring(desc.effective_level or ""),
    t("send_paused") .. ": " .. tostring(desc.send_paused == true),
    t("send_pause_reason") .. ": " .. tostring(desc.send_pause_reason or ""),
    t("active_job_id") .. ": " .. tostring(desc.active_job_id or ""),
    t("active_source_file") .. ": " .. tostring(desc.active_source_file or ""),
    t("queued_file_count") .. ": " .. tostring(desc.queued_file_count or 0),
    t("sending_file_count") .. ": " .. tostring(desc.sending_file_count or 0),
    t("failed_file_count") .. ": " .. tostring(desc.failed_file_count or 0),
    t("close_send_file_count") .. ": " .. tostring(desc.close_send_file_count or 0),
    t("current_queue_bytes") .. ": " .. tostring(desc.current_queue_bytes or 0),
    t("sendable_queue_bytes") .. ": " .. tostring(desc.sendable_queue_bytes or 0),
    t("queued_events_session") .. ": " .. tostring(desc.queued_events_session or 0),
    t("flushed_events_session") .. ": " .. tostring(desc.flushed_events_session or 0),
    t("failed_batches_session") .. ": " .. tostring(desc.failed_batches_session or 0),
    t("dropped_events_session") .. ": " .. tostring(desc.dropped_events_session or 0),
    t("skipped_events_session") .. ": " .. tostring(desc.skipped_events_session or 0),
    t("last_flush_at") .. ": " .. tostring(desc.last_flush_at or ""),
    t("last_http_code") .. ": " .. tostring(desc.last_http_code or ""),
    t("last_curl_exitcode") .. ": " .. tostring(desc.last_curl_exitcode or ""),
    t("last_backend_error") .. ": " .. tostring(desc.last_backend_error or ""),
    t("last_error") .. ": " .. tostring(desc.last_error or "")
  }
  ImGui.InputTextMultiline(ctx, "##elevenlabs_telemetry_details", table.concat(details, "\n"), -1, 180, ImGui.InputTextFlags_ReadOnly)
end

local function voice_library_value_label(key, value, query)
  if value == nil or tostring(value) == "" then return t("Any") end
  if key == "language" then
    local language = VoiceLibraryTaxonomy.languages_by_value[tostring(value)]
    return language and language.label or tostring(value)
  end
  if key == "accent" then
    local language = query and query.language or ""
    local accent = VoiceLibraryTaxonomy.accents_by_code[
      tostring(language) .. "-" .. tostring(value)
    ]
    return accent and accent.label or tostring(value)
  end
  local source =
    key == "gender" and VoiceLibraryTaxonomy.genders or
    key == "age" and VoiceLibraryTaxonomy.ages or
    key == "category" and VoiceLibraryTaxonomy.categories or nil
  for _, option in ipairs(source or {}) do
    if option.value == value then return option.label end
  end
  return tostring(value)
end

local function voice_library_query_summary(query)
  query = type(query) == "table" and query or {}
  local labels = {
    search = t("Search"),
    language = t("Language"),
    accent = t("Accent"),
    gender = t("Gender"),
    age = t("Age"),
    category = t("Category")
  }
  local parts = {}
  for _, key in ipairs({ "search", "language", "accent", "gender", "age", "category" }) do
    local value = query[key]
    if value ~= nil and tostring(value) ~= "" then
      parts[#parts + 1] = string.format(
        "%s=%s",
        labels[key],
        voice_library_value_label(key, value, query)
      )
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or t("Any")
end

local function voice_library_text(text)
  ImGui.Text(ctx, tostring(text or t("(not provided)")))
end

function UI.voice_library_stop_preview(clear_selection, owner_only)
  S.el_voice_library_ui:cancel_autoplay()
  if owner_only then
    Eleven.stop_voice_preview("voice_library")
  else
    Eleven.stop_voice_preview()
  end
  if clear_selection then S.el_voice_library_ui:clear_selection() end
end

function UI.render_voice_preview_volume(id_suffix)
  ImGui.Text(ctx, t("Preview playback volume (next Play):"))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 190)
  local gain_changed, preview_gain = ImGui.SliderDouble(
    ctx,
    "##voice_preview_volume_" .. tostring(id_suffix or "shared"),
    tonumber(S.el_voice_library_preview_gain) or 1.0,
    0.0,
    2.0,
    "%.2f"
  )
  if gain_changed then
    S.el_voice_library_preview_gain =
      math.max(0.0, math.min(2.0, tonumber(preview_gain) or 1.0))
  end
  if (tonumber(S.el_voice_library_preview_gain) or 1.0) > 1.0 then
    UI.ui_warning(t("Preview volume above 1.0 may clip at the monitoring output."))
  end
end

function UI.voice_preview_play_button(button_id, label, owner, preview_id, disabled, state_override)
  local status = Eleven.voice_preview_status()
  local is_current =
    status.owner == tostring(owner or "") and
    status.preview_id == tostring(preview_id or "")
  local pushed = false
  local display_state = is_current and status.state or tostring(state_override or "")
  if display_state == "downloading" then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0xD6A900FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xE6BC22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0xB98E00FF)
    pushed = true
  elseif is_current and status.state == "playing" then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E8B57FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x3FA66BFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x247047FF)
    pushed = true
  end
  if disabled then ImGui.BeginDisabled(ctx, true) end
  local clicked = UI.button_clicked(button_id, label, 0)
  if disabled then ImGui.EndDisabled(ctx) end
  if pushed then ImGui.PopStyleColor(ctx, 3) end
  return clicked
end

function UI.voice_library_request_preview(voice)
  if type(voice) ~= "table" then return false end
  S.el_voice_library_local_error = nil
  local preview_gain = tonumber(S.el_voice_library_preview_gain) or 1.0
  preview_gain = math.max(0.0, math.min(2.0, preview_gain))
  local token, err = Eleven.request_voice_library_preview(voice, {
    on_submitted = function()
      S.status_text = t("Voice Library preview downloading...")
    end,
    on_started = function()
      S.status_text = t("Voice Library preview playing.")
      S.last_api_error = ""
    end,
    on_error = function(message)
      local safe_message = sanitize_voice_library_error(message)
      S.el_voice_library_local_error = safe_message
      S.status_text = t("Voice Library preview failed.")
      S.last_api_error = safe_message
    end,
    on_canceled = function()
      S.status_text = t("Voice Library preview stopped.")
    end
  }, {
    -- VoicePreview copies this value into the new request, so later slider
    -- movement cannot change a download or playback already in progress.
    gain = preview_gain,
    owner = "voice_library",
    preview_id = tostring(voice.voice_id or voice.id or "")
  })
  if not token then
    local safe_error = sanitize_voice_library_error(err)
    S.el_voice_library_local_error = safe_error
    S.status_text = t("Voice Library preview could not start.")
    S.last_api_error = safe_error
    return false
  end
  return true
end

function UI.voice_library_start_page(page)
  S.el_voice_library_ui:cancel_autoplay()
  S.el_voice_library_local_error = nil
  local activated, navigation_error = Eleven.navigate_voice_library_page(page)
  if activated then
    UI.voice_library_stop_preview(true, true)
    S.el_voice_library_last_committed_page = tonumber(page)
    return true
  end
  if navigation_error ~= "not_cached" then
    S.el_voice_library_local_error = sanitize_voice_library_error(navigation_error)
    return false
  end
  local token, request_error = Eleven.request_voice_library_page(page)
  if not token then
    S.el_voice_library_local_error = sanitize_voice_library_error(request_error)
    return false
  end
  return true
end

function UI.voice_library_apply(force_load)
  local ui_state = S.el_voice_library_ui
  local view = Eleven.voice_library_view()
  if not force_load and not ui_state.dirty and not ui_state.catalog_invalidated and
     (view.current_page ~= nil or view.loading) then
    return false, "no_change"
  end

  UI.voice_library_stop_preview(true, true)
  Eleven.cancel_voice_library_requests("query_changed")
  S.el_voice_library_local_error = nil
  S.el_voice_library_last_committed_page = nil
  local query = ui_state:commit_draft()
  local opened, open_error = Eleven.set_voice_library_filters(query)
  if not opened then
    ui_state.catalog_invalidated = true
    S.el_voice_library_local_error = sanitize_voice_library_error(open_error)
    return false, open_error
  end
  local token, request_error = Eleven.request_voice_library_page(0)
  if not token then
    ui_state.catalog_invalidated = true
    S.el_voice_library_local_error = sanitize_voice_library_error(request_error)
    return false, request_error
  end
  return true
end

local function voice_library_simple_combo(label, id, key, options)
  local ui_state = S.el_voice_library_ui
  local current = ui_state.draft_query[key]
  ImGui.Text(ctx, label)
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 155)
  if ImGui.BeginCombo(
    ctx,
    id,
    voice_library_value_label(key, current, ui_state.draft_query),
    ImGui.ComboFlags_HeightRegular
  ) then
    for _, option in ipairs(options) do
      local selected = option.value == current
      if ImGui.Selectable(ctx, option.label, selected) then
        ui_state:set_filter(key, option.value)
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

local function voice_library_language_combo()
  local ui_state = S.el_voice_library_ui
  local current = ui_state.draft_query.language
  ImGui.Text(ctx, t("Language"))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 210)
  if ImGui.BeginCombo(
    ctx,
    "##voice_library_language",
    voice_library_value_label("language", current, ui_state.draft_query),
    ImGui.ComboFlags_HeightLarge
  ) then
    local changed, search = ImGui.InputText(
      ctx,
      "##voice_library_language_search",
      tostring(ui_state.language_search or "")
    )
    if changed then ui_state.language_search = search end
    local needle = tostring(ui_state.language_search or ""):lower()
    local any_selected = current == nil
    if ImGui.Selectable(ctx, t("Any"), any_selected) then
      ui_state:set_filter("language", nil)
    end
    for _, language in ipairs(VoiceLibraryTaxonomy.languages) do
      if needle == "" or language.label:lower():find(needle, 1, true) or
         language.value:lower():find(needle, 1, true) then
        local selected = language.value == current
        if ImGui.Selectable(ctx, language.label, selected) then
          ui_state:set_filter("language", language.value)
        end
        if selected then ImGui.SetItemDefaultFocus(ctx) end
      end
    end
    ImGui.EndCombo(ctx)
  end
end

local function voice_library_accent_combo()
  local ui_state = S.el_voice_library_ui
  local language = ui_state.draft_query.language
  local accents = VoiceLibraryTaxonomy.accents_for(language)
  local disabled = not language or #accents == 0
  ImGui.Text(ctx, t("Accent"))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 210)
  if disabled then ImGui.BeginDisabled(ctx, true) end
  if ImGui.BeginCombo(
    ctx,
    "##voice_library_accent",
    voice_library_value_label("accent", ui_state.draft_query.accent, ui_state.draft_query),
    ImGui.ComboFlags_HeightLarge
  ) then
    local changed, search = ImGui.InputText(
      ctx,
      "##voice_library_accent_search",
      tostring(ui_state.accent_search or "")
    )
    if changed then ui_state.accent_search = search end
    local needle = tostring(ui_state.accent_search or ""):lower()
    if ImGui.Selectable(ctx, t("Any"), ui_state.draft_query.accent == nil) then
      ui_state:set_filter("accent", nil)
    end
    for _, accent in ipairs(accents) do
      if needle == "" or accent.label:lower():find(needle, 1, true) or
         accent.value:lower():find(needle, 1, true) then
        local selected = accent.value == ui_state.draft_query.accent
        if ImGui.Selectable(ctx, accent.label, selected) then
          ui_state:set_filter("accent", accent.value)
        end
        if selected then ImGui.SetItemDefaultFocus(ctx) end
      end
    end
    ImGui.EndCombo(ctx)
  end
  if disabled then ImGui.EndDisabled(ctx) end
  if not language then
    UI.ui_info(t("Select a language first."))
  elseif #accents == 0 then
    UI.ui_info(t("No accent filters are listed for this language."))
  end
end

local function voice_library_preview_warning(policy)
  if not policy then return nil end
  if policy.warning_code == "accent_mismatch" then
    return string.format(
      t("Preview uses the %s accent for this language."),
      tostring(policy.accent or t("different"))
    )
  end
  if policy.warning_code == "general_preview" then
    return t("General preview; language and accent are not verified for the applied filters.")
  end
  if policy.warning_code == "unavailable" then
    return t("No preview is available for this voice.")
  end
  return nil
end

local function voice_library_render_table(view)
  local rows = view.rows or {}
  local available_width = select(1, ImGui.GetContentRegionAvail(ctx))
  local show_demographics = available_width >= 570
  local show_use_case = available_width >= 720
  local column_count = 3 + (show_demographics and 1 or 0) + (show_use_case and 1 or 0)
  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY
  if not ImGui.BeginTable(ctx, "##voice_library_results", column_count, table_flags, -1, 260) then
    return
  end

  ImGui.TableSetupColumn(ctx, t("Voice"), ImGui.TableColumnFlags_WidthStretch)
  ImGui.TableSetupColumn(ctx, t("Language / Accent"), ImGui.TableColumnFlags_WidthFixed, 175)
  if show_demographics then
    ImGui.TableSetupColumn(ctx, t("Gender / Age"), ImGui.TableColumnFlags_WidthFixed, 125)
  end
  if show_use_case then
    ImGui.TableSetupColumn(ctx, t("Use case"), ImGui.TableColumnFlags_WidthFixed, 150)
  end
  ImGui.TableSetupColumn(ctx, t("Preview"), ImGui.TableColumnFlags_WidthFixed, 145)
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableHeadersRow(ctx)

  for _, voice in ipairs(rows) do
    local voice_id = tostring(voice.voice_id or "")
    local labels = type(voice.labels) == "table" and voice.labels or {}
    local selected = S.el_voice_library_ui.selected_voice_id == voice_id
    local policy = Eleven.voice_library_preview_policy(voice)
    local warning = voice_library_preview_warning(policy)
    ImGui.TableNextRow(ctx)
    local column = 0
    ImGui.TableSetColumnIndex(ctx, column)
    column = column + 1
    if ImGui.Selectable(
      ctx,
      tostring(voice.name or t("(unnamed voice)")) .. "##voice_library_row_" .. voice_id,
      selected
    ) then
      if S.el_voice_library_autoplay == true then
        local preview_status = Eleven.voice_preview_status()
        if preview_status.preview_id ~= voice_id or
           preview_status.owner ~= "voice_library" then
          Eleven.stop_voice_preview()
        end
      end
      S.el_voice_library_ui:select_voice(
        voice,
        r.time_precise(),
        S.el_voice_library_autoplay == true,
        false
      )
    end
    ImGui.TableSetColumnIndex(ctx, column)
    column = column + 1
    voice_library_text(
      string.format(
        "%s / %s",
        tostring(labels.language or labels.locale or t("(unknown)")),
        tostring(labels.accent or t("(unknown)"))
      )
    )
    if show_demographics then
      ImGui.TableSetColumnIndex(ctx, column)
      column = column + 1
      voice_library_text(
        string.format(
          "%s / %s",
          tostring(labels.gender or t("(unknown)")),
          tostring(labels.age or t("(unknown)"))
        )
      )
    end
    if show_use_case then
      ImGui.TableSetColumnIndex(ctx, column)
      column = column + 1
      voice_library_text(labels.use_case or t("(not provided)"))
    end

    ImGui.TableSetColumnIndex(ctx, column)
    local unavailable = not policy or not policy.available
    local play_label = t("Play")
    if warning then play_label = play_label .. " *" end
    if UI.voice_preview_play_button(
      "voice_library_preview_" .. voice_id,
      play_label .. "##voice_library_preview_" .. voice_id,
      "voice_library",
      voice_id,
      unavailable
    ) then
      S.el_voice_library_ui:select_voice(
        voice,
        r.time_precise(),
        S.el_voice_library_autoplay == true,
        true
      )
      UI.voice_library_request_preview(voice)
    end
    ImGui.SameLine(ctx)
    if UI.button_clicked(
      "voice_library_stop_" .. voice_id,
      t("Stop") .. "##voice_library_stop_" .. voice_id,
      0
    ) then
      UI.voice_library_stop_preview(false)
    end
  end
  ImGui.EndTable(ctx)
end

local function voice_library_add_error_text(code)
  local messages = {
    authorization = t("ElevenLabs authorization failed. Check the current API key."),
    payment_required = t("The ElevenLabs account cannot perform this operation on its current plan."),
    forbidden = t("The ElevenLabs account is not allowed to add this voice."),
    not_found = t("The selected shared voice is no longer available."),
    conflict = t("ElevenLabs reported a conflict while adding this voice."),
    validation = t("ElevenLabs rejected the voice name or selected voice."),
    rate_limited = t("ElevenLabs rate limited the request. Confirm again after waiting."),
    bad_request = t("ElevenLabs rejected the add request."),
    request_invalid = t("The add request could not be prepared."),
    request_start_failed = t("The add request could not be started."),
    name_check_failed = t("The account voice-name check failed. No voice was added."),
    request_failed = t("The voice could not be added."),
    refresh_failed = t("The voice was added, but My Voices could not be refreshed."),
    refresh_not_visible = t("The voice was added, but it is not visible in My Voices yet."),
    reconciliation_failed = t("The add result could not be verified. No retry was submitted."),
    reconciliation_inconclusive = t("The add result is still uncertain. No retry was submitted.")
  }
  return messages[tostring(code or "")] or t("The voice could not be added.")
end

local function voice_library_render_add_controls(voice)
  local add_view = Eleven.voice_library_add_view(voice)
  ImGui.SeparatorText(ctx, t("Add selected voice to My Voices"))

  local input_disabled = add_view.busy or add_view.confirming
  if input_disabled then ImGui.BeginDisabled(ctx, true) end
  ImGui.SetNextItemWidth(ctx, -1)
  local name_changed, destination_name = ImGui.InputText(
    ctx,
    "##voice_library_add_name",
    tostring(add_view.draft_name or ""),
    ImGui.InputTextFlags_None
  )
  if name_changed then
    Eleven.set_voice_library_add_name(destination_name)
    add_view = Eleven.voice_library_add_view(voice)
  end
  if input_disabled then ImGui.EndDisabled(ctx) end

  local reason = add_view.eligibility_reason
  if reason == "duplicate_name" or add_view.state == "duplicate_name" then
    UI.ui_warning(t("That exact voice name already exists in My Voices. Choose a different name."))
  elseif reason == "already_added" or add_view.state == "already_added" then
    UI.ui_info(t("This Voice Library voice is already in My Voices."))
  elseif reason == "unknown_eligibility" then
    UI.ui_warning(t("ElevenLabs did not provide a reliable added-status for this voice."))
  elseif reason == "missing_identifiers" then
    UI.ui_warning(t("This voice is missing the identifiers required to add it."))
  elseif reason == "name_required" then
    UI.ui_warning(t("Enter a destination voice name."))
  end

  local button_disabled = not add_view.eligible
  if button_disabled then ImGui.BeginDisabled(ctx, true) end
  local add_label =
    add_view.retry_ready and t("Confirm retry") or t("Add to My Voices")
  local add_clicked = UI.button_clicked(
    "voice_library_add_selected",
    add_label .. "##voice_library_add_selected",
    0
  )
  if button_disabled then ImGui.EndDisabled(ctx) end
  if add_clicked then
    local opened = Eleven.begin_voice_library_add_confirmation(voice)
    if opened then
      ImGui.OpenPopup(ctx, "##voice_library_add_confirmation")
      add_view = Eleven.voice_library_add_view(voice)
    end
  end

  if add_view.state == "checking_name" then
    UI.ui_info(t("Checking the destination name in My Voices..."))
  elseif add_view.state == "submitting" then
    UI.ui_info(t("Adding the selected voice to My Voices..."))
  elseif add_view.state == "success" or add_view.state == "success_reconciled" then
    if add_view.state == "success_reconciled" then
      UI.ui_info(t("The voice was added. The uncertain result was reconciled successfully."))
    else
      UI.ui_info(t("The voice was added to My Voices."))
    end
    if add_view.refresh_state == "pending" then
      UI.ui_info(t("Refreshing My Voices..."))
    elseif add_view.refresh_state == "succeeded" then
      UI.ui_info(t("My Voices is up to date."))
    elseif add_view.refresh_state == "failed" then
      UI.ui_warning(voice_library_add_error_text(add_view.error_code))
      if UI.button_clicked(
        "voice_library_add_refresh",
        t("Refresh My Voices") .. "##voice_library_add_refresh",
        0
      ) then
        Eleven.refresh_voices_after_library_add()
      end
    end
  elseif add_view.state == "recoverable_failure" then
    UI.ui_warning(voice_library_add_error_text(add_view.error_code))
    UI.ui_info(t("Correct the issue, then use Add to My Voices and confirm again."))
  elseif add_view.state == "ambiguous" then
    UI.ui_warning(
      t("The add result is uncertain. The voice may already have been added; no retry was submitted.")
    )
    if add_view.error_code then
      UI.ui_info(voice_library_add_error_text(add_view.error_code))
    end
    if UI.button_clicked(
      "voice_library_add_reconcile",
      t("Reconcile add result") .. "##voice_library_add_reconcile",
      0
    ) then
      Eleven.reconcile_voice_library_add()
    end
  elseif add_view.state == "reconciling" then
    UI.ui_info(t("Checking whether ElevenLabs added the selected voice..."))
  elseif add_view.state == "retry_ready" then
    UI.ui_warning(
      t("ElevenLabs reports that this exact shared voice is not in My Voices. A new confirmation is required to retry.")
    )
  end

  local popup_id = "##voice_library_add_confirmation"
  UI.center_next_modal_in_current_window(ctx, add_clicked == true, "voice_library_add")
  local popup_open = ImGui.BeginPopupModal(
    ctx,
    popup_id,
    nil,
    ImGui.WindowFlags_AlwaysAutoResize
  )
  if popup_open then
    add_view = Eleven.voice_library_add_view(voice)
    if add_view.state ~= "confirming" and
       add_view.state ~= "checking_name" and
       add_view.state ~= "submitting" then
      ImGui.CloseCurrentPopup(ctx)
    else
      ImGui.TextWrapped(
        ctx,
        string.format(
          t("Add the selected Voice Library voice \"%s\" to My Voices as \"%s\"?"),
          tostring(add_view.source_name or ""),
          tostring(add_view.destination_name or "")
        )
      )
      if add_view.state == "confirming" then
        if UI.button_clicked(
          "voice_library_add_confirm",
          t("Confirm add") .. "##voice_library_add_confirm",
          0
        ) then
          Eleven.confirm_voice_library_add()
        end
        ImGui.SameLine(ctx)
        if UI.button_clicked(
          "voice_library_add_cancel",
          t("Cancel") .. "##voice_library_add_cancel",
          0
        ) then
          Eleven.cancel_voice_library_add_confirmation()
          ImGui.CloseCurrentPopup(ctx)
        end
      elseif add_view.state == "checking_name" then
        UI.ui_info(t("Checking the destination name..."))
      else
        UI.ui_info(t("Submitting one add request..."))
      end
    end
    ImGui.EndPopup(ctx)
  end
end

local function voice_library_render_details()
  local voice = S.el_voice_library_ui.selected_voice
  ImGui.SeparatorText(ctx, t("Selected voice details"))
  if type(voice) ~= "table" then
    UI.ui_info(t("Select a voice to see its full details."))
    return
  end
  local labels = type(voice.labels) == "table" and voice.labels or {}
  local child_flags = ImGui.ChildFlags_Borders
  local child_open = ImGui.BeginChild(ctx, "##voice_library_details", -1, 120, child_flags)
  if child_open then
    ImGui.Text(ctx, tostring(voice.name or t("(unnamed voice)")))
    ImGui.TextWrapped(ctx, tostring(voice.description or t("No description provided.")))
    ImGui.TextWrapped(
      ctx,
      string.format(
        t("Language: %s | Locale: %s | Accent: %s"),
        tostring(labels.language or t("(unknown)")),
        tostring(labels.locale or t("(unknown)")),
        tostring(labels.accent or t("(unknown)"))
      )
    )
    ImGui.TextWrapped(
      ctx,
      string.format(
        t("Gender: %s | Age: %s | Use case: %s | Category: %s"),
        tostring(labels.gender or t("(unknown)")),
        tostring(labels.age or t("(unknown)")),
        tostring(labels.use_case or t("(not provided)")),
        tostring(voice.category or t("(not provided)"))
      )
    )
    local policy = Eleven.voice_library_preview_policy(voice)
    local warning = voice_library_preview_warning(policy)
    if warning then ImGui.TextWrapped(ctx, warning) end
    ImGui.EndChild(ctx)
  end
  voice_library_render_add_controls(voice)
end

function UI.render_voice_library_section()
  local expanded = ImGui.CollapsingHeader(ctx, t("Voice Library"))
  if S.el_voice_library_was_expanded and not expanded then
    UI.voice_library_stop_preview(false, true)
  end
  S.el_voice_library_was_expanded = expanded
  if not expanded then return end

  if not S.el_voice_library_ever_opened then
    S.el_voice_library_ever_opened = true
    UI.voice_library_apply(true)
  end

  local ui_state = S.el_voice_library_ui
  local view = Eleven.voice_library_view()
  if view.current_page ~= nil and view.current_page ~= S.el_voice_library_last_committed_page then
    if S.el_voice_library_last_committed_page ~= nil then
      UI.voice_library_stop_preview(true, true)
    end
    S.el_voice_library_last_committed_page = view.current_page
    S.el_voice_library_local_error = nil
    view = Eleven.voice_library_view()
  end

  local due_voice = ui_state:take_due_autoplay(r.time_precise())
  if due_voice then UI.voice_library_request_preview(due_voice) end

  ImGui.Text(ctx, t("Search (input text, then Enter)"))
  ImGui.SetNextItemWidth(ctx, -1)
  local search_changed, search_value = ImGui.InputText(
    ctx,
    "##voice_library_search",
    tostring(ui_state.draft_query.search or ""),
    ImGui.InputTextFlags_EnterReturnsTrue
  )
  if search_value ~= tostring(ui_state.draft_query.search or "") then
    ui_state:set_filter("search", search_value)
  end
  if ui_state.dirty then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2F76CFFF)
  end
  local apply_clicked = UI.button_clicked("voice_library_apply", t("Apply"), 0)
  if ui_state.dirty then ImGui.PopStyleColor(ctx) end
  ImGui.SameLine(ctx)
  local reset_clicked = UI.button_clicked("voice_library_reset", t("Reset"), 0)
  if search_changed or apply_clicked then UI.voice_library_apply(false) end
  if reset_clicked then ui_state:reset_draft() end

  voice_library_language_combo()
  ImGui.SameLine(ctx)
  voice_library_accent_combo()

  if ImGui.CollapsingHeader(ctx, t("Advanced filters")) then
    voice_library_simple_combo(t("Gender"), "##voice_library_gender", "gender",
      VoiceLibraryTaxonomy.genders)
    ImGui.SameLine(ctx)
    voice_library_simple_combo(t("Age"), "##voice_library_age", "age",
      VoiceLibraryTaxonomy.ages)
    ImGui.SameLine(ctx)
    voice_library_simple_combo(t("Category"), "##voice_library_category", "category",
      VoiceLibraryTaxonomy.categories)
  end

  if ui_state.dirty then UI.ui_warning(t("Filters changed — press Apply.")) end
  if ui_state.catalog_invalidated then
    UI.ui_warning(t("The ElevenLabs account changed. Press Apply to load Voice Library results."))
  end
  UI.ui_info(
    string.format(
      t("Results for: %s"),
      voice_library_query_summary(ui_state.applied_query)
    )
  )
  if view.approximate_total ~= nil then
    UI.ui_info(
      string.format(
        t("Approximate matching voices: %s"),
        tostring(view.approximate_total)
      )
    )
  end

  if view.current_page ~= nil and #(view.rows or {}) > 0 then
    UI.render_voice_preview_volume("voice_library")
  end

  if view.loading then
    if view.current_page == nil then
      UI.ui_info(t("Loading Voice Library results..."))
    else
      UI.ui_info(
        string.format(
          t("Loading page %s; the current page remains available."),
          tostring((view.target_page or 0) + 1)
        )
      )
    end
  end

  if view.current_page ~= nil then
    if #(view.rows or {}) == 0 then
      UI.ui_info(t("No Voice Library voices match the applied filters."))
    else
      voice_library_render_table(view)
      voice_library_render_details()
    end
  elseif not view.loading and not view.failed_page and not S.el_voice_library_local_error then
    UI.ui_info(t("Press Apply to load Voice Library results."))
  end

  local failed_error = S.el_voice_library_local_error or view.failed_error
  if failed_error then
    UI.ui_warning(
      string.format(
        t("Voice Library request failed: %s"),
        tostring(failed_error)
      )
    )
  end
  if view.failed_page ~= nil then
    if UI.button_clicked("voice_library_retry", t("Retry"), 0) then
      local token, retry_error = Eleven.retry_voice_library_page()
      if not token then
        S.el_voice_library_local_error = sanitize_voice_library_error(retry_error)
      else
        S.el_voice_library_local_error = nil
      end
    end
  end

  local pager_disabled =
    ui_state.dirty or view.loading or view.current_page == nil or
    view.failed_page ~= nil
  local previous_disabled = pager_disabled or not view.has_previous
  if previous_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("voice_library_previous", t("Previous"), 0) then
    UI.voice_library_start_page(view.current_page - 1)
  end
  if previous_disabled then ImGui.EndDisabled(ctx) end
  ImGui.SameLine(ctx)
  ImGui.Text(
    ctx,
    view.current_page ~= nil and
      string.format(t("Page %s"), tostring(view.current_page + 1)) or
      t("No page loaded")
  )
  ImGui.SameLine(ctx)
  local next_disabled = pager_disabled or not view.has_more
  if next_disabled then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("voice_library_next", t("Next"), 0) then
    UI.voice_library_start_page(view.current_page + 1)
  end
  if next_disabled then ImGui.EndDisabled(ctx) end
end

local function account_voice_origin_label(origin_code)
  local labels = {
    voice_library = t("Voice Library"),
    ivc = t("IVC"),
    voice_design = t("Voice Design"),
    professional_clone = t("Professional Clone"),
    default = t("Default"),
    unknown = t("Unknown")
  }
  return labels[tostring(origin_code or "")] or labels.unknown
end

local function account_voice_display_label(voice)
  if type(voice) ~= "table" then return t("(none)") end
  return string.format(
    "%s / %s",
    tostring(voice.display_label or voice.name or t("(unnamed voice)")),
    account_voice_origin_label(voice.origin_code)
  )
end

local function account_voice_preview_available(voice)
  if type(voice) ~= "table" then return false end
  return tostring(
    voice.preview_url or
    (type(voice.raw) == "table" and voice.raw.preview_url) or
    ""
  ) ~= ""
end

local function account_voice_request_preview(voice)
  if not account_voice_preview_available(voice) then return false end
  local gain = math.max(
    0.0,
    math.min(2.0, tonumber(S.el_voice_library_preview_gain) or 1.0)
  )
  local token, err = Eleven.request_account_voice_preview(voice, {
    on_submitted = function()
      S.status_text = t("Account voice preview downloading...")
    end,
    on_started = function()
      S.status_text = t("Account voice preview playing.")
      S.last_api_error = ""
    end,
    on_error = function(message)
      local safe_message = sanitize_voice_library_error(message)
      S.status_text = t("Account voice preview failed.")
      S.last_api_error = safe_message
    end,
    on_canceled = function()
      S.status_text = t("Account voice preview stopped.")
    end
  }, { gain = gain })
  if not token then
    local safe_error = sanitize_voice_library_error(err)
    S.status_text = t("Account voice preview could not start.")
    S.last_api_error = safe_error
    return false
  end
  return true
end

local function account_voice_clear_selection_for_filter_change()
  Eleven.stop_voice_preview("account_voices")
  S.el_voice_selected_id = ""
  S.el_voice_selection_cleared_by_filter = true
end

local function account_voice_filter_combo(label, id, key, options, display_value)
  local filters = S.el_voice_filters
  local current = filters[key]
  ImGui.Text(ctx, label)
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 220)
  if ImGui.BeginCombo(
    ctx,
    id,
    current and display_value(current) or t("Any"),
    ImGui.ComboFlags_HeightRegular
  ) then
    if ImGui.Selectable(ctx, t("Any"), current == nil) then
      if current ~= nil then
        filters[key] = nil
        if key == "language" then filters.accent = nil end
        account_voice_clear_selection_for_filter_change()
      end
    end
    for _, option in ipairs(options or {}) do
      local selected = tostring(option) == tostring(current)
      if ImGui.Selectable(ctx, display_value(option), selected) then
        if not selected then
          filters[key] = option
          if key == "language" then filters.accent = nil end
          account_voice_clear_selection_for_filter_change()
        end
      end
      if selected then ImGui.SetItemDefaultFocus(ctx) end
    end
    ImGui.EndCombo(ctx)
  end
end

local function account_voice_filter_value(value)
  return tostring(value or "")
end

local function account_voice_accent_label(language, value)
  local canonical = VoiceLibraryTaxonomy.resolve_accent(language, value)
  if canonical then return canonical.label end
  return string.format(t("Other metadata / %s"), tostring(value or ""))
end

local function account_voice_language_label(value)
  local short_label = tostring(value or "")
  local taxonomy_entry =
    VoiceLibraryTaxonomy.languages_by_value[short_label] or
    VoiceLibraryTaxonomy.languages_by_value[short_label:lower()]
  local canonical_name = taxonomy_entry and taxonomy_entry.label or t("Unknown")
  return string.format("%s / %s", tostring(canonical_name), short_label)
end

local function account_voice_language_filter(options)
  local filters = S.el_voice_filters
  local current = filters.language
  ImGui.Text(ctx, t("Language:"))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 220)
  if ImGui.BeginCombo(
    ctx,
    "##account_voice_language_filter",
    current and account_voice_language_label(current) or t("Any"),
    ImGui.ComboFlags_HeightLarge
  ) then
    local search_changed, search_value = ImGui.InputTextWithHint(
      ctx,
      "##account_voice_language_search",
      t("Filter languages..."),
      tostring(S.el_voice_language_search or "")
    )
    if search_changed then S.el_voice_language_search = search_value end
    local needle = tostring(S.el_voice_language_search or ""):lower()
    if ImGui.Selectable(ctx, t("Any"), current == nil) then
      if current ~= nil then
        filters.language = nil
        filters.accent = nil
        account_voice_clear_selection_for_filter_change()
      end
    end
    for _, option in ipairs(options or {}) do
      local display_label = account_voice_language_label(option)
      if needle == "" or display_label:lower():find(needle, 1, true) then
        local selected = tostring(option) == tostring(current)
        if ImGui.Selectable(ctx, display_label, selected) then
          if not selected then
            filters.language = option
            filters.accent = nil
            account_voice_clear_selection_for_filter_change()
          end
        end
        if selected then ImGui.SetItemDefaultFocus(ctx) end
      end
    end
    ImGui.EndCombo(ctx)
  end
end

local function account_voice_render_filters(catalog)
  local facets = type(catalog) == "table" and catalog.facets or nil
  facets = type(facets) == "table" and facets or {
    origins = {}, languages = {}, accents_by_language = {},
    genders = {}, ages = {}, use_cases = {}
  }
  local filters = S.el_voice_filters
  account_voice_filter_combo(
    t("Origin:"),
    "##account_voice_origin_filter",
    "origin",
    facets.origins,
    account_voice_origin_label
  )
  account_voice_language_filter(facets.languages)

  local accent_options = {}
  local accent_disabled = filters.language == nil
  if not accent_disabled then
    for _, value in ipairs(
      facets.accents_by_language[tostring(filters.language):lower()] or {}
    ) do
      accent_options[#accent_options + 1] = value
    end
    table.sort(accent_options, function(a, b)
      local a_label = account_voice_accent_label(filters.language, a):lower()
      local b_label = account_voice_accent_label(filters.language, b):lower()
      if a_label == b_label then return tostring(a) < tostring(b) end
      return a_label < b_label
    end)
  end
  if accent_disabled then ImGui.BeginDisabled(ctx, true) end
  account_voice_filter_combo(
    t("Accent:"),
    "##account_voice_accent_filter",
    "accent",
    accent_options,
    function(value)
      return account_voice_accent_label(filters.language, value)
    end
  )
  if accent_disabled then ImGui.EndDisabled(ctx) end

  account_voice_filter_combo(
    t("Gender:"),
    "##account_voice_gender_filter",
    "gender",
    facets.genders,
    account_voice_filter_value
  )
  account_voice_filter_combo(
    t("Age:"),
    "##account_voice_age_filter",
    "age",
    facets.ages,
    account_voice_filter_value
  )
  account_voice_filter_combo(
    t("Use case:"),
    "##account_voice_use_case_filter",
    "use_case",
    facets.use_cases,
    account_voice_filter_value
  )

  local has_filters = VoiceCatalog.has_active_filters(filters)
  local has_text_filter = ImGui.TextFilter_IsActive and ImGui.TextFilter_IsActive(filter) or false
  if not has_filters and not has_text_filter then ImGui.BeginDisabled(ctx, true) end
  if UI.button_clicked("reset_account_voice_filters", t("Reset filters")) then
    S.el_voice_filters = VoiceCatalog.empty_filters()
    S.el_voice_language_search = ""
    ImGui.TextFilter_Clear(filter)
    account_voice_clear_selection_for_filter_change()
  end
  if not has_filters and not has_text_filter then ImGui.EndDisabled(ctx) end
end

local function account_voice_filtered_rows(voices)
  local matched = {}
  for _, voice in ipairs(voices or {}) do
    if VoiceCatalog.matches_filters(voice, S.el_voice_filters) and
       ImGui.TextFilter_PassFilter(filter, voice.search_text or voice.name) then
      table.insert(matched, voice)
    end
  end
  table.sort(matched, function(a, b)
    local a_label = tostring(a.display_label or a.name or ""):lower()
    local b_label = tostring(b.display_label or b.name or ""):lower()
    if a_label == b_label then
      return tostring(a.id or "") < tostring(b.id or "")
    end
    return a_label < b_label
  end)
  return matched
end

local function account_voice_join(values, fallback)
  if type(values) ~= "table" or #values == 0 then return fallback end
  return table.concat(values, ", ")
end

local function account_voice_render_selected_details(voice)
  ImGui.SeparatorText(ctx, t("Selected voice details"))
  if type(voice) ~= "table" then
    UI.ui_info(t("Select a voice to see its details."))
    return
  end

  local child_open = ImGui.BeginChild(
    ctx,
    "##account_voice_selected_details",
    -1,
    145,
    ImGui.ChildFlags_Borders
  )
  if child_open then
    ImGui.TextWrapped(
      ctx,
      string.format(t("Origin: %s"), account_voice_origin_label(voice.origin_code))
    )
    ImGui.TextWrapped(ctx, tostring(voice.description or t("No description provided.")))
    ImGui.TextWrapped(
      ctx,
      string.format(
        t("Languages: %s | Locales: %s | Accents: %s"),
        account_voice_join(voice.languages, t("(unknown)")),
        account_voice_join(voice.locales, t("(unknown)")),
        account_voice_join(voice.accents, t("(unknown)"))
      )
    )
    ImGui.TextWrapped(
      ctx,
      string.format(
        t("Gender: %s | Age: %s | Use case: %s | Descriptive: %s"),
        tostring(voice.gender or t("(unknown)")),
        tostring(voice.age or t("(unknown)")),
        tostring(voice.use_case or t("(not provided)")),
        tostring(voice.descriptive or t("(not provided)"))
      )
    )
    local created = t("(unknown)")
    if tonumber(voice.created_at_unix) and tonumber(voice.created_at_unix) > 0 then
      created = os.date("%Y-%m-%d %H:%M:%S", tonumber(voice.created_at_unix))
    end
    ImGui.TextWrapped(ctx, string.format(t("Created: %s"), created))
    if type(voice.additional_labels) == "table" and #voice.additional_labels > 0 then
      local label_parts = {}
      for _, item in ipairs(voice.additional_labels) do
        label_parts[#label_parts + 1] = tostring(item.key) .. ": " .. tostring(item.value)
      end
      ImGui.TextWrapped(
        ctx,
        string.format(t("Additional labels: %s"), table.concat(label_parts, " | "))
      )
    end
    ImGui.EndChild(ctx)
  end
end

--===============================================================================
--===============================================================================
--================= GuiLoop - DEFER part ========================================
--===============================================================================
--===============================================================================
local function GuiLoop()
  --ImGui.SetNextWindowBgAlpha( ctx, 1 )
  local now_t = TelemetryBridge.now()
  TelemetryBridge.safe_tick(now_t)
  Jobs.tick_all(now_t)

  Actions.poll_action_flags()
  local conditions_met = false

  ImGui.SetNextWindowSize(ctx_status, 500, 375, ImGui.Cond_FirstUseEver)
  if S.show_status_window then

    local status_flags =
      ImGui.WindowFlags_NoTitleBar
    local status_open_bool = nil --not letting user close it from UI
    local status_visible, status_open = ImGui.Begin(ctx_status, current_status_window_label(), status_open_bool, status_flags)
    if status_visible then
      UI.render_status_panel(ctx_status, "_status_window")
    end
    ImGui.End(ctx_status)
  end --if S.show_status_window

  ImGui.SetNextWindowSize(ctx, 750, 975, ImGui.Cond_FirstUseEver)
  --ImGui.SetNextWindowSize(ctx, 750, 975)

  local modal_expand_source = UI.prepare_main_window_before_begin(ctx)
  local imgui_visible, imgui_open = ImGui.Begin(ctx, current_main_window_label(), true)
  UI.observe_main_window_after_begin(ctx, imgui_visible, modal_expand_source)
  if imgui_visible then
    ImGui.PushFont(ctx, FONT, font_size)
    Eleven.draw_voice_resolver_modal(ctx)

    ImGui.Text(ctx, t("Language") .. ":")
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 160)
    local locale_combo_disabled = not translated_locale_available("rus")
    if locale_combo_disabled then ImGui.BeginDisabled(ctx, true) end
    local locale_combo_open = ImGui.BeginCombo(ctx, "##ui_locale_combo", locale_display_name(active_locale), ImGui.ComboFlags_HeightRegular)
    if locale_combo_open then
      local locale_options = { "eng" }
      if translated_locale_available("rus") then
        table.insert(locale_options, "rus")
      end
      for _, locale_id in ipairs(locale_options) do
        local is_selected = (active_locale == locale_id)
        local activated = ImGui.Selectable(ctx, locale_display_name(locale_id), is_selected)
        if activated then
          set_active_runtime_locale(locale_id)
          UI.persist_locale(locale_id)
        end
        if is_selected then ImGui.SetItemDefaultFocus(ctx) end
      end
      ImGui.EndCombo(ctx)
    end
    if locale_combo_disabled then ImGui.EndDisabled(ctx) end

    ImGui.SameLine(ctx)
    local changed_show_status, new_show_status = ImGui.Checkbox(ctx, t("Show status in dedicated window"), S.show_status_window)
    if changed_show_status then
      S.show_status_window = new_show_status
      UI.persist_show_status_window(new_show_status)
      TelemetryBridge.safe_event("feature_used", {
        operation = "elevenlabs_status_window_toggle",
        status = new_show_status and "enabled" or "disabled",
        show_status_window = new_show_status == true
      }, {
        operation = "elevenlabs_status_window_toggle",
        status = new_show_status and "enabled" or "disabled"
      })
    end

    if not S.show_status_window then
      UI.render_status_panel(ctx, "_inline")
    end

    if ImGui.CollapsingHeader(ctx, t("Settings")) then
      ImGui.SeparatorText(ctx, t("Account / Credentials"))
      UI.ui_info(string.format(t("Active Studio backend: %s"), Backend.active_base_url()))
      if Auth.has_access_token() then
        UI.ui_info(t("Studio login: active for this session."))
      elseif S.has_stored_refresh then
        UI.ui_info(t("Stored Studio login is available. Refresh it or log in again."))
      else
        UI.ui_info(t("No Studio login is active."))
      end

      ImGui.Text(ctx, t("Email"))
      ImGui.SetNextItemWidth(ctx, -10.0)
      local changed_email, new_email = ImGui.InputText(ctx, "##studio_login_email", S.email or "")
      if changed_email then
        S.email = new_email
        if S.remember_login then
          Auth.persist_email(S.email)
        end
      end

      ImGui.Text(ctx, t("Password"))
      ImGui.SetNextItemWidth(ctx, -10.0)
      local pass_flags = ImGui.InputTextFlags_Password
      local changed_password, new_password = ImGui.InputText(ctx, "##studio_login_password", S.password or "", pass_flags)
      if changed_password then
        S.password = new_password
      end

      local changed_remember, new_remember = ImGui.Checkbox(ctx, t("Remember me"), S.remember_login)
      if changed_remember then
        S.remember_login = new_remember
        Backend.reset_clients()
        if new_remember then
          Auth.persist_email(S.email)
          if S.refresh_token ~= "" then
            Auth.client().persist_refresh_token(S.refresh_token)
            S.has_stored_refresh = true
          end
        else
          Auth.client().forget_refresh_token()
          Auth.forget_email()
          Auth.forget_refresh_backend_base()
          S.has_stored_refresh = false
        end
      end

      local login_disabled = Jobs.network_busy()
      if login_disabled then ImGui.BeginDisabled(ctx, true) end
      if UI.button_clicked("login_btn", t("Login")) then
        Jobs.schedule_job(t("Studio login"), function() Auth.request_login() end)
      end
      if login_disabled then ImGui.EndDisabled(ctx) end

      ImGui.SameLine(ctx)
      local refresh_disabled = Jobs.network_busy() or not S.has_stored_refresh
      if refresh_disabled then ImGui.BeginDisabled(ctx, true) end
      if UI.button_clicked("refresh_login_btn", t("Refresh stored login")) then
        Jobs.schedule_job(t("Refresh Studio login"), function()
          Auth.request_refresh(t("Manual Studio refresh"), nil, { fetch_catalog_after = true })
        end)
      end
      if refresh_disabled then ImGui.EndDisabled(ctx) end

      ImGui.SameLine(ctx)
      if UI.button_clicked("forget_login_btn", t("Forget stored login")) then
        Auth.forget_stored_login()
      end

      ImGui.SeparatorText(ctx, t("Voice Library"))
      local autoplay_changed, autoplay_value = ImGui.Checkbox(
        ctx,
        t("Autoplay preview when selecting a Voice Library voice"),
        S.el_voice_library_autoplay == true
      )
      if autoplay_changed then
        S.el_voice_library_autoplay = autoplay_value == true
        UI.persist_voice_library_autoplay(S.el_voice_library_autoplay)
        if not S.el_voice_library_autoplay then
          S.el_voice_library_ui:cancel_autoplay()
        end
      end

      ImGui.Text(ctx, t("Voice Library page size:"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 100)
      if ImGui.BeginCombo(
        ctx,
        "##voice_library_page_size",
        tostring(S.el_voice_library_saved_page_size or 30),
        ImGui.ComboFlags_HeightRegular
      ) then
        for _, page_size in ipairs({ 30, 50, 100 }) do
          local selected = page_size == S.el_voice_library_saved_page_size
          if ImGui.Selectable(ctx, tostring(page_size), selected) then
            UI.persist_voice_library_page_size(page_size)
          end
          if selected then ImGui.SetItemDefaultFocus(ctx) end
        end
        ImGui.EndCombo(ctx)
      end
      if S.el_voice_library_saved_page_size ~= S.el_voice_library_active_page_size then
        UI.ui_info(
          string.format(
            t("Page size %s will be used the next time this script is run. Current session: %s."),
            tostring(S.el_voice_library_saved_page_size),
            tostring(S.el_voice_library_active_page_size)
          )
        )
      else
        UI.ui_info(
          string.format(
            t("Current Voice Library page size: %s."),
            tostring(S.el_voice_library_active_page_size)
          )
        )
      end

      ImGui.SeparatorText(ctx, t("Paths"))
      UI.ui_info(string.format(t("Project path: %s"), S.project_path ~= "" and S.project_path or t("(unknown)")))
      UI.ui_info(string.format(t("Temp folder: %s"), CFG.tmp_dir))
      UI.ui_info(string.format(t("STS output folder: %s"), CFG.output_audio_path ~= "" and CFG.output_audio_path or t("(not set)")))
      UI.ui_info(string.format(t("TTS output folder: %s"), CFG.output_audio_path_tts ~= "" and CFG.output_audio_path_tts or t("(not set)")))
      UI.ui_info(string.format(t("Voice Design output folder: %s"), CFG.output_audio_path_voice_design ~= "" and CFG.output_audio_path_voice_design or t("(not set)")))

      if UI.button_clicked("copy_tmp_path_btn", t("Copy temp folder path to clipboard")) then
        ImGui.SetClipboardText(ctx, CFG.tmp_dir)
      end

      ImGui.SameLine(ctx)

      if UI.button_clicked("refresh_checks_btn", t("Refresh checks")) then
        S.checks_ran = false
        UI.rebuild_warnings()
      end

      -- Writability status
      ImGui.Text(ctx, t("Temp folder status"))
      if S.tmp_writable then
        UI.ui_info(t("✅ Temp directory is writable."))
      else
        UI.ui_warning(t("❌ Temp directory is NOT writable."))
      end

      if UI.button_clicked("empty_temp_folder", t("Empty temp folder!")) then
        local telemetry_started_at = TelemetryBridge.now()
        TelemetryBridge.operation_started("elevenlabs_temp_cleanup", {
          temp_dir = tostring(CFG.tmp_dir or "")
        })
        local empty_temp_folder_result, empty_temp_folder_explanation = Files.remove_all_files_in_dir(CFG.tmp_dir)
        -- ignores subdirs!

        local status_message_friendly
        if empty_temp_folder_result then
          status_message_friendly = string.format(t("Temp folder emptied successfully. %s"), empty_temp_folder_explanation or '')
          TelemetryBridge.operation_completed("elevenlabs_temp_cleanup", {
            safe_message = tostring(empty_temp_folder_explanation or "")
          }, telemetry_started_at)
        else
          status_message_friendly = string.format(t("Problem: %s"), empty_temp_folder_explanation or '')
          table.insert(S.warnings, status_message_friendly)
          status_message_friendly = t('!! Some problems with temp folder... See warnings.')
          TelemetryBridge.operation_failed("elevenlabs_temp_cleanup", {
            safe_message = tostring(empty_temp_folder_explanation or "")
          }, telemetry_started_at, "cleanup_failed")
        end
        S.status_text = status_message_friendly
      end

      ImGui.SeparatorText(ctx, t("Diagnostics"))
      UI.ui_info(string.format(t("Active Studio backend: %s"), Backend.active_base_url()))
      ImGui.Text(ctx, t("Developer backend override"))
      ImGui.SetNextItemWidth(ctx, -10.0)
      local changed_backend_override, new_backend_override =
        ImGui.InputText(ctx, "##studio_backend_override", S.backend_base_url_override or "")
      if changed_backend_override then
        S.backend_base_url_override = Util.trim(new_backend_override or "")
        CFG.backend_base_url_override = S.backend_base_url_override
        UI.persist_backend_base_url_override(S.backend_base_url_override)
        Auth.clear_runtime_tokens()
        Backend.reset_clients()
        Eleven.notify_voice_library_account_changed()
        Auth.sync_stored_refresh_flag()
        S.status_text = t("Studio backend changed. Refresh or log in again.")
      end
      if UI.button_clicked("backend_override_localhost_btn", t("Use local dev backend")) then
        S.backend_base_url_override = "http://localhost:3002"
        CFG.backend_base_url_override = S.backend_base_url_override
        UI.persist_backend_base_url_override(S.backend_base_url_override)
        Auth.clear_runtime_tokens()
        Backend.reset_clients()
        Eleven.notify_voice_library_account_changed()
        Auth.sync_stored_refresh_flag()
        S.status_text = t("Local Studio backend selected. Refresh or log in again.")
      end
      ImGui.SameLine(ctx)
      if UI.button_clicked("backend_override_clear_btn", t("Use production backend")) then
        S.backend_base_url_override = ""
        CFG.backend_base_url_override = ""
        UI.forget_backend_base_url_override()
        Auth.clear_runtime_tokens()
        Backend.reset_clients()
        Eleven.notify_voice_library_account_changed()
        Auth.sync_stored_refresh_flag()
        S.status_text = t("Production Studio backend selected. Refresh or log in again.")
      end
      UI.render_diagnostics_settings()

      ImGui.SeparatorText(ctx, t("Telemetry"))
      UI.render_telemetry_level_setting()
    end --if settings section

    -- Render regions by track (selected items)
    if ImGui.CollapsingHeader(ctx, t("Render Regions")) then
      if UI.button_clicked("render_regions_btn", t("Compute render regions (selected items)")) then
        local telemetry_started_at = TelemetryBridge.now()
        TelemetryBridge.operation_started("elevenlabs_render_region_scan", {})
        local ok, err_or_regions = ReaperX.get_render_regions_by_track()
        if ok then
          S.render_regions_output = ReaperX.format_render_regions_by_track(err_or_regions)
          local region_count = 0
          if type(err_or_regions) == "table" then
            for _, rows in pairs(err_or_regions.regions_by_track or err_or_regions) do
              if type(rows) == "table" then
                region_count = region_count + #rows
              end
            end
          end
          TelemetryBridge.operation_completed("elevenlabs_render_region_scan", {
            region_count = region_count
          }, telemetry_started_at)
        else
          S.render_regions_output = string.format(t("Error: %s"), tostring(err_or_regions))
          TelemetryBridge.operation_failed("elevenlabs_render_region_scan", {
            safe_message = tostring(err_or_regions or "")
          }, telemetry_started_at, "render_failed")
        end
      end

      local regions_output = S.render_regions_output or ""
      local rflags = ImGui.InputTextFlags_ReadOnly
      ImGui.InputTextMultiline(ctx, "##render_regions_output", regions_output, 0, 100, rflags)
    end --if collapsing header "Render Regions"

    --==========================================================================
    --==========================================================================

    -- ElevenLabs API jobs
    local voice_catalog = S.el_voices
    local account_voice_count = voice_catalog and tonumber(voice_catalog.count) or 0
    local account_voices_header = string.format(
      t("Account Voices [%d] (refetch Voices / Models)"),
      account_voice_count
    ) .. "###elevenlabs_account_voices_section"
    local account_voices_expanded = ImGui.CollapsingHeader(ctx, account_voices_header)
    if S.el_account_voices_was_expanded and not account_voices_expanded then
      Eleven.stop_voice_preview("account_voices")
    end
    S.el_account_voices_was_expanded = account_voices_expanded
    if account_voices_expanded then
      local voices = voice_catalog and voice_catalog.voices or nil
      local has_voice_catalog = type(voices) == "table" and #voices > 0
      if not has_voice_catalog then
        Eleven.stop_voice_preview("account_voices")
        S.el_voice_selected_id = ""
      elseif not S.el_voice_selection_cleared_by_filter and
             not (voice_catalog.by_id and voice_catalog.by_id[S.el_voice_selected_id]) then
        S.el_voice_selected_id = voices[1].id
      end

      account_voice_render_filters(voice_catalog)
      UI.render_voice_preview_volume("account_voices")
      local matched = account_voice_filtered_rows(voices)

      ImGui.Text(ctx, string.format(t("Voices list [%d]:"), #matched))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 320)
      local selected_voice =
        voice_catalog and voice_catalog.by_id and voice_catalog.by_id[S.el_voice_selected_id] or nil
      local preview_name = account_voice_display_label(selected_voice)
      local combo_open = ImGui.BeginCombo(ctx, "##el_voice_list_combo", preview_name, ImGui.ComboFlags_HeightLarge)
      if combo_open and not S.el_voice_combo_open then
        if ImGui.SetScrollY then
          ImGui.SetScrollY(ctx, 0)
        end
      end
      S.el_voice_combo_open = combo_open
      if combo_open then
        local text_filter_changed = ImGui.TextFilter_Draw(filter, ctx, t("Filter..."), 0)
        if text_filter_changed then
          account_voice_clear_selection_for_filter_change()
          matched = account_voice_filtered_rows(voices)
        end
        if has_voice_catalog then
          local matched_count = #matched
          if matched_count > 0 then
            ImGui.ListClipper_Begin(account_voice_clipper, matched_count)
            while ImGui.ListClipper_Step(account_voice_clipper) do
              local display_start, display_end =
                ImGui.ListClipper_GetDisplayRange(account_voice_clipper)
              for row_index = display_start + 1, display_end do
                local entry = matched[row_index]
                local is_selected = (entry.id == S.el_voice_selected_id)
                local activated = ImGui.Selectable(
                  ctx,
                  account_voice_display_label(entry) .. "##voice_" .. tostring(entry.id or ""),
                  is_selected
                )
                if activated then
                  if entry.id ~= S.el_voice_selected_id then
                    Eleven.stop_voice_preview("account_voices")
                  end
                  S.el_voice_selected_id = entry.id
                  S.el_voice_selection_cleared_by_filter = false
                end
              end
            end
          end
          if matched_count == 0 then
            ImGui.TextWrapped(ctx, t("No account voices match the current filters."))
          end
        else
          ImGui.Text(ctx, t("(no voices fetched)"))
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.SameLine(ctx)
      selected_voice =
        voice_catalog and voice_catalog.by_id and voice_catalog.by_id[S.el_voice_selected_id] or nil
      local selected_voice_name = selected_voice and selected_voice.name or ""
      local selected_voice_id = selected_voice and selected_voice.id or ""
      local can_copy_voice = selected_voice_name ~= ""
      local can_preview_voice = account_voice_preview_available(selected_voice)
      if UI.voice_preview_play_button(
        "account_voice_play_btn",
        t("Play") .. "##account_voice_play",
        "account_voices",
        selected_voice_id,
        not can_preview_voice
      ) then
        account_voice_request_preview(selected_voice)
      end
      ImGui.SameLine(ctx)
      if UI.button_clicked(
        "account_voice_stop_btn",
        t("Stop") .. "##account_voice_stop",
        0
      ) then
        Eleven.stop_voice_preview()
      end
      ImGui.SameLine(ctx)
      if not can_copy_voice then ImGui.BeginDisabled(ctx, true) end
      if UI.button_clicked("copy_voice_name_btn", t("Copy!")) then
        ImGui.SetClipboardText(ctx, selected_voice_name)
      end
      if not can_copy_voice then ImGui.EndDisabled(ctx) end

      account_voice_render_selected_details(selected_voice)

      local catalog_fetch_disabled = Jobs.network_busy()
      if catalog_fetch_disabled then ImGui.BeginDisabled(ctx, true) end
      if UI.button_clicked("fetch_el_models_btn", t("Refetch models")) then
        Eleven.fetch_el_models()
      end

      ImGui.SameLine(ctx)

      if UI.button_clicked("fetch_el_voices_btn", t("Refetch voices")) then
        Eleven.fetch_el_voices()
      end
      if catalog_fetch_disabled then ImGui.EndDisabled(ctx) end
    end --if collapsing header "ElevenLabs API"

    UI.render_voice_library_section()

    if ImGui.CollapsingHeader(ctx, t("Elevenlabs IVC")) then
      local ivc = Eleven.ensure_ivc_state()
      local ivc_batch = Eleven.ensure_ivc_batch_ui_state()

      ImGui.SeparatorText(ctx, t("=-=Common IVC=-="))
      local remove_changed, remove_val =
        ImGui.Checkbox(ctx, t("Remove background noise/music"), ivc.remove_background_noise)
      if remove_changed then
        ivc.remove_background_noise = remove_val
      end

      ImGui.Text(ctx, t("Description:"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local desc_changed, desc_val = ImGui.InputText(
        ctx,
        "##ivc_description",
        tostring(ivc.description or ""),
        ImGui.InputTextFlags_None
      )
      if desc_changed then
        ivc.description = desc_val
      end

      if ImGui.CollapsingHeader(ctx, t("=-=Single IVC=-=")) then
        local time_ok, t_start, t_end, t_dur,
          t_start_seconds, t_end_seconds =
            ReaperX.report_time_selection()
        if time_ok then
          UI.ui_info(string.format(t("Time selection: %s to %s (duration %s)"), t_start, t_end, t_dur))
        else
          UI.ui_warning(string.format(t("Set time selection! %s"), tostring(t_start or t("(not set now)"))))
        end

        local track_ok, track_name, track_num, track_object =
          ReaperX.report_only_one_selected_track()
        if track_ok then
          local track_idx = tostring(math.floor(track_num or 0))
          local tn = tostring(track_name or "")
          if tn ~= "" then
            UI.ui_info(string.format(t("Selected track: #%s %s"), track_idx, tn))
          else
            UI.ui_info(string.format(t("Selected track: #%s (unnamed)"), track_idx))
          end
        else
          UI.ui_warning(string.format(t("Track selection: %s"), tostring(track_name or t("not set"))))
        end

        local use_track_changed, use_track_val =
          ImGui.Checkbox(ctx, t("Get voice name from selected track name"), ivc.use_track_name)
        if use_track_changed then
          ivc.use_track_name = use_track_val
        end

        local resolved_name = ""
        if ivc.use_track_name and track_ok and (track_name or "") ~= "" then
          resolved_name = tostring(track_name)
          UI.ui_info(string.format(t("Voice name: %s"), resolved_name))
        else
          if ivc.use_track_name and track_ok then
            UI.ui_warning(t("Selected track has no name. Enter a voice name manually."))
          end
          ImGui.Text(ctx, t("Voice name:"))
          ImGui.SameLine(ctx)
          ImGui.SetNextItemWidth(ctx, 260)
          local name_changed, name_val = ImGui.InputText(
            ctx,
            "##ivc_voice_name",
            tostring(ivc.voice_name or ""),
            ImGui.InputTextFlags_None
          )
          if name_changed then
            ivc.voice_name = name_val
          end
          resolved_name = tostring(ivc.voice_name or "")
        end

        local name_ok = VoiceCatalog.trim_name(resolved_name) ~= ""
        local can_run = name_ok and time_ok and track_ok and not Jobs.network_busy()
        if can_run then
          local occupancy_ok, occupancy_ratio, occupancy_msg =
            ReaperX.occupancy_ratio(track_object, t_start_seconds, t_end_seconds)
          if occupancy_ok then
            if occupancy_ratio < 0.85 then
              UI.ui_warning(
                string.format(
                  t("Selected track occupancy ratio in time selection is too low: %.2f"),
                  occupancy_ratio
                )
              )
            else
              UI.ui_info(
                string.format(
                  t("Selected track occupancy ratio in time selection: %.2f."),
                  occupancy_ratio
                )
              )
            end
          else
            UI.ui_warning(string.format(t("Could not compute track occupancy ratio: %s"), tostring(occupancy_msg or t("unknown error"))))
          end
        end --if can_run
        if not can_run then ImGui.BeginDisabled(ctx, true) end
        if UI.button_clicked("ivc_create_btn", t("Create IVC voice")) then
          local meta = {
            name = resolved_name,
            description = tostring(ivc.description or ""),
            remove_background_noise = ivc.remove_background_noise == true
          }
          Eleven.run_el_ivc_create(meta)
        end
        if not can_run then ImGui.EndDisabled(ctx) end
      end

      if ImGui.CollapsingHeader(ctx, t("=-=Batch IVC=-=")) then
        if UI.button_clicked("ivc_batch_inspect_btn", t("Inspect selected tracks for batch IVC")) then
          local ok_inspect, inspect_msg, inspect_rows =
            ReaperX.get_regions_by_track_for_IVC(ivc.remove_background_noise == true)
          ivc_batch.inspect_ran = true
          if ok_inspect then
            ivc_batch.inspect_ok = true
            ivc_batch.inspect_msg = (type(inspect_msg) == "string" and inspect_msg ~= "") and inspect_msg or "ok"
            ivc_batch.inspect_rows = (type(inspect_rows) == "table") and inspect_rows or {}
            S.status_text = t("Batch IVC inspection completed.")
            S.last_api_error = ""
          else
            ivc_batch.inspect_ok = false
            ivc_batch.inspect_msg =
              (type(inspect_msg) == "string" and inspect_msg ~= "") and inspect_msg or t("Batch IVC inspection failed.")
            ivc_batch.inspect_rows = nil
            S.status_text = ivc_batch.inspect_msg
            S.last_api_error = S.status_text
            if type(S.warnings) ~= "table" then
              S.warnings = {}
            end
            table.insert(S.warnings, S.status_text)
          end
        end

        local batch_rows = ivc_batch.inspect_rows
        if type(batch_rows) ~= "table" then batch_rows = {} end
        local batch_pass_count = 0
        for _, row in ipairs(batch_rows) do
          if row and row.can_pass == true then
            batch_pass_count = batch_pass_count + 1
          end
        end

        if not ivc_batch.inspect_ran then
          UI.ui_info(t("Press Inspect to preview batch IVC track regions."))
        elseif ivc_batch.inspect_ok ~= true then
          UI.ui_warning(
            (type(ivc_batch.inspect_msg) == "string" and ivc_batch.inspect_msg ~= "")
              and ivc_batch.inspect_msg
              or t("Batch IVC inspection failed.")
          )
        else
          local rows = batch_rows

          local total = #rows
          local pass_count = batch_pass_count
          local fail_count = 0
          for _, row in ipairs(rows) do
            if not (row and row.can_pass == true) then
              fail_count = fail_count + 1
            end
          end
          UI.ui_info(string.format(t("Tracks: %d | Pass: %d | Fail: %d"), total, pass_count, fail_count))

          if total > 0 then
            local table_flags =
              ImGui.TableFlags_Borders |
              ImGui.TableFlags_RowBg |
              ImGui.TableFlags_Resizable
            local line_h = ImGui.GetTextLineHeightWithSpacing(ctx)
            local visible_rows = total
            if visible_rows < 3 then visible_rows = 3 end
            if visible_rows > 10 then visible_rows = 10 end
            local table_height = line_h * (visible_rows + 1.6)

            if ImGui.BeginTable(ctx, "##ivc_batch_preview_table", 7, table_flags, -1, table_height) then
              ImGui.TableSetupColumn(ctx, "#", ImGui.TableColumnFlags_WidthFixed, 45)
              ImGui.TableSetupColumn(ctx, t("Voice name"), ImGui.TableColumnFlags_WidthFixed, 220)
              ImGui.TableSetupColumn(ctx, t("Dataset start"), ImGui.TableColumnFlags_WidthFixed, 120)
              ImGui.TableSetupColumn(ctx, t("Dataset end"), ImGui.TableColumnFlags_WidthFixed, 120)
              ImGui.TableSetupColumn(ctx, t("Dataset length"), ImGui.TableColumnFlags_WidthFixed, 120)
              ImGui.TableSetupColumn(ctx, t("Status"), ImGui.TableColumnFlags_WidthStretch)
              ImGui.TableSetupColumn(ctx, t("remove noise"), ImGui.TableColumnFlags_WidthFixed, 120)

              ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers)
              ImGui.TableSetColumnIndex(ctx, 0)
              ImGui.TableHeader(ctx, "#")
              ImGui.TableSetColumnIndex(ctx, 1)
              ImGui.TableHeader(ctx, t("Voice name"))
              ImGui.TableSetColumnIndex(ctx, 2)
              ImGui.TableHeader(ctx, t("Dataset start"))
              ImGui.TableSetColumnIndex(ctx, 3)
              ImGui.TableHeader(ctx, t("Dataset end"))
              ImGui.TableSetColumnIndex(ctx, 4)
              ImGui.TableHeader(ctx, t("Dataset length"))
              ImGui.TableSetColumnIndex(ctx, 5)
              ImGui.TableHeader(ctx, t("Status"))
              ImGui.TableSetColumnIndex(ctx, 6)
              local all_remove_noise = true
              for _, row in ipairs(rows) do
                if not (row and row.remove_background_noise == true) then
                  all_remove_noise = false
                  break
                end
              end
              local header_changed, header_value =
                ImGui.Checkbox(ctx, "##ivc_batch_remove_noise_all", all_remove_noise)
              if header_changed then
                for _, row in ipairs(rows) do
                  if row then
                    row.remove_background_noise = header_value == true
                  end
                end
              end
              ImGui.SameLine(ctx)
              ImGui.Text(ctx, t("remove noise"))

              for idx, row in ipairs(rows) do
                local track_number_txt = "-"
                if row and row.track_number ~= nil then
                  track_number_txt = tostring(row.track_number)
                end
                local track_name_txt = tostring((row and row.track_name) or "")
                if track_name_txt == "" then track_name_txt = "-" end

                local start_txt = "-"
                if row and row.region_start ~= nil then
                  local start_num = tonumber(row.region_start)
                  if start_num ~= nil then
                    local hmsf = ReaperX.seconds_to_hmsf(start_num)
                    if hmsf and hmsf ~= "" then start_txt = hmsf end
                  end
                end

                local end_txt = "-"
                if row and row.region_end ~= nil then
                  local end_num = tonumber(row.region_end)
                  if end_num ~= nil then
                    local hmsf = ReaperX.seconds_to_hmsf(end_num)
                    if hmsf and hmsf ~= "" then end_txt = hmsf end
                  end
                end

                local len_txt = "-"
                local start_num_for_len = row and tonumber(row.region_start) or nil
                local end_num_for_len = row and tonumber(row.region_end) or nil
                if start_num_for_len ~= nil and end_num_for_len ~= nil and end_num_for_len >= start_num_for_len then
                  local len_hmsf = ReaperX.seconds_to_hmsf(end_num_for_len - start_num_for_len)
                  if len_hmsf and len_hmsf ~= "" then len_txt = len_hmsf end
                end

                local status_txt = tostring((row and row.status) or "")
                if status_txt == "" then status_txt = "-" end

                ImGui.TableNextRow(ctx)
                ImGui.TableSetColumnIndex(ctx, 0)
                ImGui.Text(ctx, track_number_txt)
                ImGui.TableSetColumnIndex(ctx, 1)
                ImGui.Text(ctx, track_name_txt)
                ImGui.TableSetColumnIndex(ctx, 2)
                ImGui.Text(ctx, start_txt)
                ImGui.TableSetColumnIndex(ctx, 3)
                ImGui.Text(ctx, end_txt)
                ImGui.TableSetColumnIndex(ctx, 4)
                ImGui.Text(ctx, len_txt)
                ImGui.TableSetColumnIndex(ctx, 5)
                if row and row.can_pass == true then
                  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00FF00FF) -- green
                else
                  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF0000FF) -- red
                end
                ImGui.TextWrapped(ctx, status_txt)
                ImGui.PopStyleColor(ctx)
                ImGui.TableSetColumnIndex(ctx, 6)
                local row_remove_noise = false
                if row and row.remove_background_noise == true then
                  row_remove_noise = true
                end
                local row_changed, row_value = ImGui.Checkbox(
                  ctx,
                  "##ivc_batch_remove_noise_row_" .. tostring(idx),
                  row_remove_noise
                )
                if row_changed and row then
                  row.remove_background_noise = row_value == true
                end
              end

              ImGui.EndTable(ctx)
            end
          end
        end

        local can_run_ivc_batch =
          (ivc_batch.inspect_ok == true) and
          (batch_pass_count > 0) and
          (not Jobs.network_busy())
        if UI.guard_with_timer_button_clicked("ivc_batch_run_btn", t("Run Batch IVC"), nil, not can_run_ivc_batch) then
          local rows_snapshot = ivc_batch.inspect_rows
          local description_snapshot = tostring(ivc.description or "")
          local scheduled = Jobs.schedule_job(t("Batch IVC"), function()
            Eleven.run_el_ivc_batch_from_inspect_rows(rows_snapshot, {
              description = description_snapshot
            })
          end)
          if not scheduled then
            S.status_text = t("Could not schedule batch IVC job.")
            S.last_api_error = t("Could not schedule batch IVC job.")
            if type(S.warnings) ~= "table" then
              S.warnings = {}
            end
            table.insert(S.warnings, S.status_text)
          end
        end
      end
    end --if collapsing header "Elevenlabs IVC"

    local voice_design_expanded = ImGui.CollapsingHeader(ctx, t("Voice Design"))
    if S.voice_design_was_expanded and not voice_design_expanded then
      Eleven.stop_voice_preview("voice_design")
    end
    S.voice_design_was_expanded = voice_design_expanded
    if voice_design_expanded then
      local vd = Eleven.ensure_voice_design_state()
      ReaperX.sync_voice_design_temp_items(vd)

      local function add_warning(msg)
        if type(S.warnings) ~= "table" then
          S.warnings = {}
        end
        table.insert(S.warnings, tostring(msg or t("Unknown warning.")))
      end

      local function merge_mode_label(mode)
        local m = tostring(mode or "overwrite")
        if m == "append_newline" then return t("Append (new line)") end
        if m == "append_space" then return t("Append (space)") end
        return t("Overwrite")
      end

      local function draw_merge_mode_combo(combo_id, current_mode)
        local changed = false
        local value = current_mode or "overwrite"
        local combo_open = ImGui.BeginCombo(ctx, combo_id, merge_mode_label(value), ImGui.ComboFlags_HeightRegular)
        if combo_open then
          local modes = {
            { id = "overwrite", label = t("Overwrite") },
            { id = "append_newline", label = t("Append (new line)") },
            { id = "append_space", label = t("Append (space)") }
          }
          for _, mode in ipairs(modes) do
            local is_selected = (value == mode.id)
            if ImGui.Selectable(ctx, mode.label, is_selected) then
              value = mode.id
              changed = true
            end
            if is_selected then ImGui.SetItemDefaultFocus(ctx) end
          end
          ImGui.EndCombo(ctx)
        end
        return changed, value
      end

      local function unlink_field_link(item_link_key)
        if item_link_key == "desc_temp_item" then
          vd.desc_temp_item = nil
          vd.desc_temp_item_invalid_warned = false
        elseif item_link_key == "preview_temp_item" then
          vd.preview_temp_item = nil
          vd.preview_temp_item_invalid_warned = false
        end
      end

      local function import_selected_items_to_field(field_key, merge_mode, item_link_key)
        unlink_field_link(item_link_key)
        local ok, combined = ReaperX.get_text_from_selected_items_by_track()
        if not ok then
          add_warning(string.format(t("Failed to import selected item text: %s"), tostring(combined or t("unknown error"))))
          return
        end
        if not combined or combined == "" then
          add_warning(t("No text found in selected items."))
          return
        end
        local applied, err = ReaperX.apply_import_to_vd_field(field_key, combined, merge_mode)
        if not applied then
          add_warning(string.format(t("Could not apply imported text: %s"), tostring(err or t("unknown error"))))
        end
      end

      local function import_clipboard_to_field(field_key, merge_mode, item_link_key)
        unlink_field_link(item_link_key)
        local clip_txt = tostring(ImGui.GetClipboardText(ctx) or "")
        if clip_txt == "" then
          add_warning(t("Clipboard is empty."))
          return
        end
        local applied, err = ReaperX.apply_import_to_vd_field(field_key, clip_txt, merge_mode)
        if not applied then
          add_warning(string.format(t("Could not apply clipboard text: %s"), tostring(err or t("unknown error"))))
        end
      end

      local function start_temp_item_edit(field_key, item_link_key)
        local ok_track, track_or_err = ReaperX.resolve_temp_text_track()
        if not ok_track then
          add_warning(tostring(track_or_err or t("Failed to resolve temp text track.")))
          return
        end

        local ok_item, item_or_err = ReaperX.create_temp_text_item(track_or_err, vd[field_key] or "")
        if not ok_item then
          add_warning(tostring(item_or_err or t("Failed to create temp text item.")))
          return
        end

        vd[item_link_key] = item_or_err
        if item_link_key == "desc_temp_item" then
          vd.desc_temp_item_invalid_warned = false
        elseif item_link_key == "preview_temp_item" then
          vd.preview_temp_item_invalid_warned = false
        end

        local opened, open_err = ReaperX.open_item_notes_best_effort(item_or_err)
        if not opened then
          add_warning(string.format(t("Temp text item created, but failed to open notes window: %s"), tostring(open_err or t("unknown error"))))
        end
      end

      ImGui.Text(ctx, t("Voice description:"))
      ImGui.SameLine(ctx)
      local voice_desc_longhint = t(
        [===[Minimum 20 characters.
Max 1000 characters.
The prompt is the foundation of your voice.
It tells the model what kind of voice you’re trying to create —
everything from the accent and character-type
to the gender and vibe of the voice.]===]
      )
      UI.help_marker(ctx, voice_desc_longhint)
      local avail_w = select(1, ImGui.GetContentRegionAvail(ctx))
      local input_w = avail_w * 0.8
      local text_child_flags = ImGui.ChildFlags_FrameStyle | ImGui.ChildFlags_Borders
      local desc_child_open = ImGui.BeginChild(ctx, "##vd_voice_description_view", input_w, 90, text_child_flags)
      if desc_child_open then
        ImGui.TextWrapped(ctx, vd.voice_description or "")
        ImGui.EndChild(ctx)
      end
      if UI.button_clicked("vd_desc_from_items_btn", t("Get text from selected item(s)")) then
        import_selected_items_to_field("voice_description", vd.desc_merge_mode, "desc_temp_item")
      end
      ImGui.SameLine(ctx)
      if UI.button_clicked("vd_desc_from_clipboard_btn", t("Get from clipboard")) then
        import_clipboard_to_field("voice_description", vd.desc_merge_mode, "desc_temp_item")
      end
      ImGui.SameLine(ctx)
      if UI.button_clicked("vd_desc_edit_btn", t("Edit")) then
        start_temp_item_edit("voice_description", "desc_temp_item")
      end
      ImGui.SameLine(ctx)
      if UI.button_clicked("vd_desc_clear_btn", t("Clear!")) then
        vd.voice_description = ""
        vd.desc_temp_item = nil
        vd.desc_temp_item_invalid_warned = false
      end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, t("Mode:"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 170)
      local desc_mode_changed, desc_mode_val = draw_merge_mode_combo("##vd_desc_merge_mode", vd.desc_merge_mode)
      if desc_mode_changed then
        vd.desc_merge_mode = desc_mode_val
      end

      local auto_changed, auto_val = ImGui.Checkbox(ctx, t("Auto-generate preview text"), vd.auto_generate_text)
      if auto_changed then
        vd.auto_generate_text = auto_val
      end
      ImGui.SameLine(ctx)
      UI.help_marker(ctx, t("Unselect to write your own preview text."))

      if not vd.auto_generate_text then
        ImGui.Text(ctx, t("Preview text:"))
        ImGui.SameLine(ctx)
        UI.help_marker(ctx, t("This text will be used for previewing the voice."))
        local preview_avail_w = select(1, ImGui.GetContentRegionAvail(ctx))
        local preview_input_w = preview_avail_w * 0.8
        local preview_child_open = ImGui.BeginChild(ctx, "##vd_preview_text_view", preview_input_w, 90, text_child_flags)
        if preview_child_open then
          ImGui.TextWrapped(ctx, vd.text or "")
          ImGui.EndChild(ctx)
        end
        if UI.button_clicked("vd_preview_from_items_btn", t("Get text from selected item(s)") .. "##2") then
          import_selected_items_to_field("text", vd.preview_merge_mode, "preview_temp_item")
        end
        ImGui.SameLine(ctx)
        if UI.button_clicked("vd_preview_from_clipboard_btn", t("Get from clipboard") .. "##2") then
          import_clipboard_to_field("text", vd.preview_merge_mode, "preview_temp_item")
        end
        ImGui.SameLine(ctx)
        if UI.button_clicked("vd_preview_edit_btn", t("Edit") .. "##2") then
          start_temp_item_edit("text", "preview_temp_item")
        end
        ImGui.SameLine(ctx)
        if UI.button_clicked("vd_preview_clear_btn", t("Clear!") .. "##2") then
          vd.text = ""
          vd.preview_temp_item = nil
          vd.preview_temp_item_invalid_warned = false
        end
        ImGui.SameLine(ctx)
        ImGui.Text(ctx, t("Mode:"))
        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 170)
        local preview_mode_changed, preview_mode_val = draw_merge_mode_combo("##vd_preview_merge_mode", vd.preview_merge_mode)
        if preview_mode_changed then
          vd.preview_merge_mode = preview_mode_val
        end
      end

      local enhance_changed, enhance_val = ImGui.Checkbox(ctx, t("Enhance description"), vd.should_enhance)
      if enhance_changed then
        vd.should_enhance = enhance_val
      end
      ImGui.SameLine(ctx)
      UI.help_marker(ctx, t("If enabled, the prompt you write will be enhanced with AI before being used for voice design."))

      ImGui.Text(ctx, t("Guidance scale:"))
      ImGui.SameLine(ctx)
      UI.help_marker(
        ctx,
        t(
          [==[(0–100, default 5)
How strongly the voice design process will try to match the prompt you wrote.
Higher values force the AI to adhere closely to the text
but can sometimes sound over-processed.
Lower values allow for more creative variety.]==]
        )
      )
      ImGui.SetNextItemWidth(ctx, -1)
      local gs_changed, gs_val = ImGui.SliderDouble(ctx, "##vd_guidance_scale", vd.guidance_scale, 0.0, 100.0, "%.2f")
      if gs_changed then
        vd.guidance_scale = gs_val
      end

      ImGui.Text(ctx, t("Loudness:"))
      ImGui.SameLine(ctx)
      UI.help_marker(
        ctx,
        t(
          [=====[from 0 to 100 (default 75):
Adjusts the output volume level.
50 corresponds to roughly -24 LUFS.]=====]
        )
      )
      ImGui.SetNextItemWidth(ctx, -1)
      local loud_changed, loud_val = ImGui.SliderDouble(ctx, "##vd_loudness", vd.loudness, 0.0, 100.0, "%.0f")
      if loud_changed then
        vd.loudness = loud_val
      end

      ImGui.Separator(ctx)
      local vd_disabled = Jobs.network_busy()
      if UI.guard_with_timer_button_clicked("el_voice_design_run_btn", t("Design now!"), nil, vd_disabled) then
        local ok_ready, warn_list = Eleven.check_voice_design_preflight()
        if type(warn_list) == "table" and #warn_list > 0 then
          if type(S.warnings) ~= "table" then
            S.warnings = {}
          end
          for _, warn in ipairs(warn_list) do
            table.insert(S.warnings, warn)
          end
        end
        if ok_ready then
          local scheduled = Jobs.schedule_job(t("Voice Design"), function()
            Eleven.run_el_voice_design()
          end)
          if not scheduled then
            S.status_text = t("Could not schedule voice design job.")
            S.last_api_error = t("Could not schedule voice design job.")
          end
        end
      end
      if S.voice_design_records and type(S.voice_design_records.preview) == "table" then
        UI.ui_info(string.format(t("Voice Design previews: %s"), tostring(#S.voice_design_records.preview)))
        if #S.voice_design_records.preview > 0 then
          UI.render_voice_preview_volume("voice_design")
          for i, rec in ipairs(S.voice_design_records.preview) do
            local rec_id = rec.record_name or ""
            local preview_id = rec_id ~= "" and rec_id or (rec.output_path or ("preview_" .. tostring(i)))
            ImGui.Text(ctx, string.format(t("Preview %d "), i))
            ImGui.SameLine(ctx)
            local can_play =
              rec._state == "ok" and
              tostring(rec.output_path or "") ~= "" and
              r.file_exists(rec.output_path) and
              VoicePreview.validate_audio(rec.output_path) == true
            local play_id = "vd_play_preview_btn_" .. tostring(preview_id)
            if UI.voice_preview_play_button(
              play_id,
              t("Play") .. "##vd_play_" .. tostring(preview_id),
              "voice_design",
              preview_id,
              not can_play,
              (rec._state == "running" or rec._next_retry_at ~= nil) and
                "downloading" or nil
            ) then
              local gain = math.max(
                0.0,
                math.min(2.0, tonumber(S.el_voice_library_preview_gain) or 1.0)
              )
              local token, play_err = Eleven.play_voice_design_preview(rec, {
                on_started = function()
                  S.status_text = string.format(
                    t("Playing preview: %s"),
                    tostring(rec.record_name)
                  )
                  S.last_api_error = ""
                end,
                on_error = function(message)
                  S.status_text = t("Voice Design preview failed.")
                  S.last_api_error = tostring(message or "")
                end
              }, { gain = gain })
              if not token then
                S.status_text = t("Voice Design preview could not start.")
                S.last_api_error = tostring(play_err or "")
              end
            end

            ImGui.SameLine(ctx)
            if UI.button_clicked(
              "vd_stop_preview_btn_" .. tostring(preview_id),
              t("Stop") .. "##vd_stop_" .. tostring(preview_id),
              0
            ) then
              Eleven.stop_voice_preview()
            end

            ImGui.SameLine(ctx)
            local popup_id = t("Create voice") .. "##vd_create_voice_popup_" .. tostring(preview_id)
            local create_btn_id = "vd_create_voice_btn_" .. tostring(preview_id)
            local create_label = t("Create voice!") .. "##" .. tostring(rec.preview_index or i)
            if not can_play then ImGui.BeginDisabled(ctx, true) end
            local create_clicked = UI.button_clicked(create_btn_id, create_label)
            if not can_play then ImGui.EndDisabled(ctx) end
            if create_clicked then
              if rec.voice_description == nil or rec.voice_description == "" then
                rec.voice_description = t("Added from Reaper script")
              end
              ImGui.OpenPopup(ctx, popup_id)
            end

            local popup_flags = ImGui.WindowFlags_AlwaysAutoResize
            local name_checking = rec._voice_name_check_state == "checking"
            local popup_close_state = true
            if name_checking then popup_close_state = nil end
            UI.center_next_modal_in_current_window(
              ctx,
              create_clicked == true,
              "voice_design_create"
            )
            local popup_open, _ = ImGui.BeginPopupModal(
              ctx,
              popup_id,
              popup_close_state,
              popup_flags
            )
            if popup_open then
              if rec._voice_name_create_close_requested then
                rec._voice_name_create_close_requested = nil
                ImGui.CloseCurrentPopup(ctx)
              end
              if name_checking then ImGui.BeginDisabled(ctx, true) end
              ImGui.Text(ctx, t("Voice name:"))
              ImGui.SameLine(ctx)
              ImGui.SetNextItemWidth(ctx, 260)
              local name_changed, name_val = ImGui.InputText(
                ctx,
                "##vd_create_voice_name_" .. tostring(preview_id),
                tostring(rec.voice_name or ""),
                ImGui.InputTextFlags_None
              )
              if name_changed then
                rec.voice_name = name_val
                rec._voice_name_check_state = nil
                rec._voice_name_check_message = nil
                rec._voice_name_uniqueness_verified = nil
              end
              ImGui.SameLine(ctx)
              if UI.button_clicked("vd_copy_track_name_btn_" .. tostring(preview_id), t("Copy from selected track name")) then
                local track_name = ReaperX.get_selected_track_name()
                if track_name and track_name ~= "" then
                  rec.voice_name = track_name
                  rec._voice_name_check_state = nil
                  rec._voice_name_check_message = nil
                  rec._voice_name_uniqueness_verified = nil
                end
              end

              ImGui.Text(ctx, t("Description:"))
              local desc_w = select(1, ImGui.GetContentRegionAvail(ctx))
              local desc_changed, desc_val = ImGui.InputTextMultiline(
                ctx,
                "##vd_create_voice_desc_" .. tostring(preview_id),
                tostring(rec.voice_description or ""),
                desc_w,
                90,
                ImGui.InputTextFlags_None
              )
              if desc_changed then
                rec.voice_description = desc_val
              end
              if name_checking then ImGui.EndDisabled(ctx) end

              local desc_len = #(rec.voice_description or "")
              ImGui.Text(ctx, string.format(t("Description length: %d (20-1000)"), desc_len))
              if rec._voice_name_check_message and rec._voice_name_check_message ~= "" then
                if rec._voice_name_check_state == "failed" then
                  UI.ui_warning(rec._voice_name_check_message)
                else
                  UI.ui_info(rec._voice_name_check_message)
                end
              end
              ImGui.Separator(ctx)

              local voice_name = VoiceCatalog.trim_name(rec.voice_name)
              local voice_description = tostring(rec.voice_description or "")
              local desc_len = #voice_description
              local has_key = Auth.has_access_token()
              local has_generated = (rec.generated_voice_id ~= nil and tostring(rec.generated_voice_id) ~= "")
              local can_submit =
                (voice_name ~= "") and
                (desc_len >= 20) and
                (desc_len <= 1000) and
                has_key and
                has_generated and
                (not Jobs.network_busy()) and
                (not name_checking)

              local create_now_clicked = false
              ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0xC00000FF)
              ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xE00000FF)
              ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0xA00000FF)
              if not can_submit then ImGui.BeginDisabled(ctx, true) end
              if UI.button_clicked("vd_create_voice_now_btn_" .. tostring(preview_id), t("Create now!")) then
                create_now_clicked = true
              end
              if not can_submit then ImGui.EndDisabled(ctx) end
              ImGui.PopStyleColor(ctx, 3)
              ImGui.SameLine(ctx)
              if name_checking then ImGui.BeginDisabled(ctx, true) end
              if UI.button_clicked("vd_create_voice_cancel_btn_" .. tostring(preview_id), t("Cancel")) then
                ImGui.CloseCurrentPopup(ctx)
              end
              if name_checking then ImGui.EndDisabled(ctx) end

              if create_now_clicked then
                local err_txt = nil
                if voice_name == "" then
                  err_txt = t("Voice name is required.")
                elseif #voice_description < 20 or #voice_description > 1000 then
                  err_txt = t("Voice description must be 20-1000 characters.")
                end
                if err_txt then
                  S.status_text = err_txt
                  S.last_api_error = err_txt
                else
                  rec.voice_name = voice_name
                  rec._voice_name_check_state = "checking"
                  rec._voice_name_check_message = t("Checking whether this voice name is available...")
                  rec._voice_name_uniqueness_verified = nil

                  local function name_check_failed(message)
                    local msg = tostring(message or t("Voice name check failed."))
                    rec._voice_name_check_state = "failed"
                    rec._voice_name_check_message = msg
                    S.status_text = msg
                    S.last_api_error = msg
                  end

                  local ok_check, check_err = Eleven.check_voice_name_available(voice_name, {
                    on_available = function(trimmed_name)
                      rec.voice_name = trimmed_name
                      rec._voice_name_uniqueness_verified = trimmed_name
                      local ok_submit, submit_err = Eleven.add_voice_from_preview(rec)
                      if ok_submit then
                        rec._voice_name_check_state = "submitted"
                        rec._voice_name_check_message = t("Voice creation submitted.")
                        S.status_text = rec._voice_name_check_message
                        S.last_api_error = ""
                        rec._voice_name_create_close_requested = true
                      else
                        rec._voice_name_uniqueness_verified = nil
                        name_check_failed(submit_err or t("Voice create request failed."))
                      end
                    end,
                    on_duplicate = function(duplicate_name)
                      name_check_failed(
                        string.format(t("Voice name already exists: %s"), tostring(duplicate_name))
                      )
                    end,
                    on_error = function(fetch_error)
                      name_check_failed(
                        string.format(
                          t("Voice name check failed: %s"),
                          tostring(fetch_error or t("unknown error"))
                        )
                      )
                    end
                  })
                  if not ok_check and rec._voice_name_check_state == "checking" then
                    name_check_failed(check_err)
                  end
                end
              end

              ImGui.EndPopup(ctx)
            end
          end
          local all_previews_ready = Eleven.voice_design_previews_all_ready()
          local batch_already_inserted = S.voice_design_records.batch_inserted == true
          local insert_disabled = not all_previews_ready or batch_already_inserted
          if insert_disabled then ImGui.BeginDisabled(ctx, true) end
          if UI.button_clicked(
            "vd_insert_previews_btn",
            t("Insert previews to project to new track")
          ) then
            local inserted, insert_err = Eleven.insert_voice_design_previews_to_new_track()
            if not inserted then
              local message = tostring(insert_err or t("Voice Design preview insertion failed."))
              S.status_text = message
              S.last_api_error = message
              table.insert(S.warnings, message)
            end
          end
          if insert_disabled then ImGui.EndDisabled(ctx) end
        end
      end
    end --if collapsing header "Voice Design"

    if ImGui.CollapsingHeader(ctx, t("Text-to-Speech")) then
      local tts_models, tts_default = Eleven.build_tts_model_list()
      local has_tts_models = (#tts_models > 0)
      if has_tts_models then
        Eleven.resolve_tts_model_selection(tts_models, tts_default)
      else
        S.el_tts_model_selected = ""
      end

      ImGui.Text(ctx, t("Model:"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 320)
      local tts_preview = t("(none)")
      if has_tts_models then
        for _, model in ipairs(tts_models) do
          if model.id == S.el_tts_model_selected then
            tts_preview = model.label
            break
          end
        end
        if tts_preview == t("(none)") then
          tts_preview = tts_models[1].label or t("(none)")
        end
      end
      local tts_combo_open = ImGui.BeginCombo(ctx, "##el_tts_model_combo", tts_preview, ImGui.ComboFlags_HeightLarge)
      if tts_combo_open then
        if has_tts_models then
          for _, model in ipairs(tts_models) do
            local is_selected = (model.id == S.el_tts_model_selected)
            local activated = ImGui.Selectable(ctx, model.label, is_selected)
            if activated then
              Eleven.select_tts_model(model.id)
            end
            if is_selected then ImGui.SetItemDefaultFocus(ctx) end
          end
        else
          ImGui.Text(ctx, t("(no models fetched)"))
        end
        ImGui.EndCombo(ctx)
      end

      if not has_tts_models then
        UI.ui_warning(t("No TTS models available. Fetch models first."))
      end

      local tts_disabled = Jobs.network_busy() or S.ui_lock_network_buttons
      if UI.guard_with_timer_button_clicked("el_tts_fast_run_btn", t("FAST TTS FLOW (auto insert)"), nil, tts_disabled) then
        local scheduled = Jobs.schedule_job(t("Fast text-to-speech"), function()
          Eleven.run_el_text_to_speech_fast()
        end)
        if not scheduled then
          S.status_text = t("Could not schedule fast text-to-speech job.")
          S.last_api_error = t("Could not schedule fast text-to-speech job.")
        end
      end
      if UI.guard_with_timer_button_clicked("el_tts_run_btn", t("Text-to-Speech (selected items)"), nil, tts_disabled) then
        local scheduled = Jobs.schedule_job(t("Text-to-speech"), function()
          Eleven.run_el_text_to_speech_for_selected_items()
        end)
        if not scheduled then
          S.status_text = t("Could not schedule text-to-speech job.")
          S.last_api_error = t("Could not schedule text-to-speech job.")
        end
      end
      if tts_disabled then ImGui.BeginDisabled(ctx, true) end
      if UI.button_clicked("el_tts_add_results_btn", t("Add TTS results to project!")) then
        ReaperX.add_all_tts_results_to_project()
      end
      if tts_disabled then ImGui.EndDisabled(ctx) end
      if S.tts_records and type(S.tts_records) == "table" then
        UI.ui_info(string.format(t("TTS records: %s"), tostring(#S.tts_records)))
      end

      S.openai_rewrite_mode = OpenAI.normalize_rewrite_mode(S.openai_rewrite_mode)
      ImGui.Text(ctx, t("OpenAI rewrite mode:"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 180)
      local rewrite_mode_preview = OpenAI.rewrite_mode_label(S.openai_rewrite_mode)
      local mode_combo_open = ImGui.BeginCombo(ctx, "##openai_rewrite_mode_combo", rewrite_mode_preview, ImGui.ComboFlags_HeightLarge)
      if mode_combo_open then
        local mode_items = {
          { id = "per_item", label = t("Per-item") },
          { id = "per_track", label = t("Per-track") },
          { id = "all_items", label = t("All selected") }
        }
        for _, mode_item in ipairs(mode_items) do
          local is_selected = (S.openai_rewrite_mode == mode_item.id)
          local activated = ImGui.Selectable(ctx, mode_item.label, is_selected)
          if activated then
            S.openai_rewrite_mode = mode_item.id
          end
          if is_selected then ImGui.SetItemDefaultFocus(ctx) end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.SameLine(ctx)
      local inline_changed, inline_value = ImGui.Checkbox(ctx, t("Inline"), S.openai_insert_inline ~= false)
      if inline_changed then
        S.openai_insert_inline = inline_value
      end
      ImGui.SameLine(ctx)
      if UI.guard_with_timer_button_clicked("openai_rewrite_btn", t("Enhance!"), nil, tts_disabled) then
        local scheduled = Jobs.schedule_job(t("OpenAI rewrite"), function()
          OpenAI.run_openai_text_rewrite_for_selected_items()
        end)
        if not scheduled then
          S.status_text = t("Could not schedule OpenAI rewrite job.")
          S.last_api_error = t("Could not schedule OpenAI rewrite job.")
        end
      end
      ImGui.Text(ctx, t("Audio tags:"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local audio_tags_changed, audio_tags_value =
        ImGui.InputText(
          ctx,
          "##audio_tags_input",
          S.audio_tags_input or "",
          ImGui.InputTextFlags_None
        )
      if audio_tags_changed then
        S.audio_tags_input = audio_tags_value
      end

      if UI.button_clicked("audio_tags_insert_selected_notes_btn", t("Insert to selected item(s)")) then
        UI.run_audio_tags_insert_selected_notes()
      end
      ImGui.SameLine(ctx)
      if UI.button_clicked("audio_tags_remove_brackets_selected_notes_btn", t("Remove [..] from selected")) then
        UI.run_audio_tags_remove_brackets_selected_notes()
      end


    end --if collapsing header "Text-to-Speech"

    if ImGui.CollapsingHeader(ctx, t("Speech-to-Speech")) then
      local sts_gap_value = tonumber(CFG.sts_merge_gap_sec) or 3.5
      if sts_gap_value < 0 then sts_gap_value = 0 end
      local sts_max_len_value = normalize_sts_max_region_length_sec(CFG.sts_max_region_length_sec)
      local sts_send_each_item = CFG.sts_send_each_item_separately == true

      local per_item_changed, per_item_value =
        ImGui.Checkbox(ctx, t("Send each item separately"), sts_send_each_item)
      if per_item_changed then
        CFG.sts_send_each_item_separately = per_item_value == true
        UI.persist_sts_send_each_item_separately(CFG.sts_send_each_item_separately)
        sts_send_each_item = CFG.sts_send_each_item_separately == true
      end

      if sts_send_each_item then
        ImGui.BeginDisabled(ctx, true)
      end
      ImGui.Text(ctx, t("Auto-merge gap (sec):"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 110)
      local gap_changed, gap_value = ImGui.InputDouble(ctx, "##sts_merge_gap_sec", sts_gap_value, 0.1, 1.0, "%.2f")
      if sts_send_each_item then
        ImGui.EndDisabled(ctx)
      end
      if gap_changed then
        if gap_value < 0 then gap_value = 0 end
        CFG.sts_merge_gap_sec = gap_value
        UI.persist_sts_merge_gap_sec(gap_value)
      end

      ImGui.Text(ctx, t("Max region length (sec):"))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 110)
      local max_len_changed, max_len_value = ImGui.InputInt(ctx, "##sts_max_region_length_sec", sts_max_len_value, 1, 10)
      if max_len_changed then
        local normalized_max_len = normalize_sts_max_region_length_sec(max_len_value)
        CFG.sts_max_region_length_sec = normalized_max_len
        UI.persist_sts_max_region_length_sec(normalized_max_len)
        sts_max_len_value = normalized_max_len
      end
      UI.ui_info(string.format("%s    %s", fmt_minutes_seconds(sts_max_len_value), t("Max 5 minutes! (ElevenLabs limit)")))

      local sts_disabled = Jobs.network_busy() or S.ui_lock_network_buttons
      if UI.guard_with_timer_button_clicked("el_sts_fast_run_btn", t("FAST STS FLOW (auto insert)"), nil, sts_disabled) then
        local scheduled = Jobs.schedule_job(t("Fast speech-to-speech"), function()
          Eleven.run_el_speech_to_speech_fast()
        end)
        if not scheduled then
          S.status_text = t("Could not schedule fast speech-to-speech job.")
          S.last_api_error = t("Could not schedule fast speech-to-speech job.")
        end
      end
      if UI.guard_with_timer_button_clicked("el_sts_run_btn", t("Render regions + Speech-to-Speech (selected items)"), nil, sts_disabled) then
        local scheduled = Jobs.schedule_job(t("Speech-to-speech"), function()
          Eleven.run_el_speech_to_speech_for_selected_items()
        end)
        if not scheduled then
          S.status_text = t("Could not schedule speech-to-speech job.")
          S.last_api_error = t("Could not schedule speech-to-speech job.")
        end
      end
      if UI.button_clicked("el_sts_add_results_btn", t("Add STS results to project!")) then
        ReaperX.add_all_sts_results_to_project()
      end
    end --if collapsing header "Speech-to-Speech"

    --====RESET STATE and clear table!
    if UI.button_clicked("reset_state_btn", t('Clear Table and RESET STATE! (Start again...)')) then
      Jobs.full_reset_state("reset state")
    end --reset state button

    if S.rendered_regions and type(S.rendered_regions) == "table" then
      UI.ui_info(string.format(t("Rendered regions: %s"), tostring(#S.rendered_regions)))
    end

    local record_rows = UI.build_record_rows()
    if #record_rows == 0 then
      UI.ui_info(t("No records prepared yet."))
    else
      local table_flags =
        ImGui.TableFlags_Borders |
        ImGui.TableFlags_RowBg |
        ImGui.TableFlags_Resizable
      if ImGui.BeginTable(ctx, "##records_table", 5, table_flags, -1, 0) then
        ImGui.TableSetupColumn(ctx, t("Track"), ImGui.TableColumnFlags_WidthFixed, 60)
        ImGui.TableSetupColumn(ctx, t("Start"), ImGui.TableColumnFlags_WidthFixed, 110)
        ImGui.TableSetupColumn(ctx, t("Flow"), ImGui.TableColumnFlags_WidthFixed, 90)
        ImGui.TableSetupColumn(ctx, t("Progress"), ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableSetupColumn(ctx, t("Actions"), ImGui.TableColumnFlags_WidthFixed, 140)
        ImGui.TableHeadersRow(ctx)
        for _, row in ipairs(record_rows) do
          local rec = row.rec
          local job = row.job_id and S.curl_jobs[row.job_id] or nil
          local track_txt = UI.track_number_for_record(rec)
          local start_txt = UI.start_label_for_record(rec)
          local progress_txt = UI.format_record_progress(rec, job)
          ImGui.TableNextRow(ctx)
          ImGui.TableSetColumnIndex(ctx, 0)
          ImGui.Text(ctx, track_txt)
          ImGui.TableSetColumnIndex(ctx, 1)
          ImGui.Text(ctx, start_txt)
          ImGui.TableSetColumnIndex(ctx, 2)
          ImGui.Text(ctx, row.flow)
          ImGui.TableSetColumnIndex(ctx, 3)
          ImGui.Text(ctx, progress_txt)
          ImGui.TableSetColumnIndex(ctx, 4)
          local retry_enabled = UI.can_retry_record(rec)
          if not retry_enabled then ImGui.BeginDisabled(ctx, true) end
          if UI.button_clicked("retry_" .. row.id, t("Retry") .. "##" .. row.id) then
            local telemetry_started_at = TelemetryBridge.now()
            local ok, err = Jobs.manual_retry_record(rec)
            if ok then
              S.status_text = string.format(t("Retry queued: %s"), tostring(UI.record_label(rec)))
              S.last_api_error = ""
              TelemetryBridge.operation_completed("elevenlabs_manual_retry", {
                record_label = tostring(UI.record_label(rec)),
                flow_label = tostring(row.flow or "")
              }, telemetry_started_at)
            else
              S.status_text = string.format(t("Retry failed: %s"), tostring(err))
              S.last_api_error = S.status_text
              TelemetryBridge.operation_failed("elevenlabs_manual_retry", {
                record_label = tostring(UI.record_label(rec)),
                flow_label = tostring(row.flow or ""),
                safe_message = tostring(err or "")
              }, telemetry_started_at)
            end
          end
          if not retry_enabled then ImGui.EndDisabled(ctx) end
          ImGui.SameLine(ctx)
          local cancel_enabled = UI.can_cancel_record(rec, job)
          if not cancel_enabled then ImGui.BeginDisabled(ctx, true) end
          if UI.button_clicked("cancel_" .. row.id, t("Cancel") .. "##" .. row.id) then
            local telemetry_started_at = TelemetryBridge.now()
            local ok, err = Jobs.cancel_record(rec, "canceled by user")
            if ok then
              S.status_text = string.format(t("Canceled: %s"), tostring(UI.record_label(rec)))
              S.last_api_error = ""
              TelemetryBridge.finish_record_canceled(rec, {
                record_label = tostring(UI.record_label(rec)),
                flow_label = tostring(row.flow or ""),
                reason = "canceled by user"
              })
            else
              S.status_text = string.format(t("Cancel failed: %s"), tostring(err))
              S.last_api_error = S.status_text
              TelemetryBridge.operation_failed("elevenlabs_record_cancel", {
                record_label = tostring(UI.record_label(rec)),
                flow_label = tostring(row.flow or ""),
                safe_message = tostring(err or "")
              }, telemetry_started_at)
            end
          end
          if not cancel_enabled then ImGui.EndDisabled(ctx) end
        end
        ImGui.EndTable(ctx)
      end
    end

    --=====more info and errors=============

    if (not S.last_api_error) then S.last_api_error = '' end --if

    UI.render_telemetry_section()

    if ImGui.CollapsingHeader(ctx, t("Details (errors, status)")) then
      UI.render_running_meter_table(ctx)
      ImGui.Separator(ctx)
      -- Read-only multiline
      local flags = ImGui.InputTextFlags_ReadOnly
      ImGui.InputTextMultiline(ctx, "##errbox", S.last_api_error, 0, 0, flags)
    end

    ImGui.PopFont(ctx)
    ImGui.End(ctx)
  end --if ImGui_Begin


  if imgui_open --and not ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
    then
      r.defer(GuiLoop)
  else
    TelemetryBridge.send_closed_event("window_closed")
  end --if
end -- END function GuiLoop() (DEFER part)

--==================================================================================================
--==================================================================================================
-- additional init before starting defer loop
--==================================================================================================
--==================================================================================================
UI.load_locale_on_startup()
UI.load_show_status_window_on_startup()
UI.load_backend_base_url_override_on_startup()
UI.load_tts_model_preference_on_startup()
UI.load_sts_settings_on_startup()
TelemetryBridge.script_started()
Auth.try_auto_login_on_startup()
Actions.install_actions_on_startup()
Actions.init_action_flags()

-- LET'S GO!
r.defer(GuiLoop)
