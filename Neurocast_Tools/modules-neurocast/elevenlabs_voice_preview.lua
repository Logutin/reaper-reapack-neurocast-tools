-- Explicit-action ElevenLabs voice preview controller.
--
-- The controller owns preview request identity, cache validation, partial-file
-- hygiene, retries, and native playback sequencing. Transport, retry scheduling,
-- cleanup, filesystem helpers, and native playback functions are injected so
-- this module can be tested headlessly and does not initialize shared services.
-- Remote preview requests must be built by an injected Studio Neurocast
-- backend adapter. The source preview URL may identify/cache the selection but
-- is never submitted directly by this module.

local VoicePreview = {}
VoicePreview.__index = VoicePreview

local function identity(value)
  return tostring(value or "")
end

local function finite_gain(value)
  local gain = tonumber(value)
  if not gain or gain ~= gain or gain == math.huge or gain == -math.huge then
    return nil
  end
  return math.max(0.0, math.min(2.0, gain))
end

local function default_file_exists(path)
  if type(path) ~= "string" or path == "" then return false end
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function stable_url_fingerprint(url)
  local hash = 5381
  local text = tostring(url or "")
  for index = 1, #text do
    hash = (hash * 33 + text:byte(index)) % 4294967296
  end
  return string.format("%08x", hash)
end

local function safe_call(callback, ...)
  if type(callback) ~= "function" then return end
  pcall(callback, ...)
end

local function callbacks_add(request, callbacks)
  if type(callbacks) == "table" then
    request.callbacks[#request.callbacks + 1] = callbacks
  end
end

local function callbacks_emit(request, name, ...)
  for _, callbacks in ipairs(request.callbacks or {}) do
    safe_call(callbacks[name], ...)
  end
end

local function voice_fields(voice)
  if type(voice) ~= "table" then return nil, "voice must be a table" end
  local voice_id = tostring(voice.voice_id or voice.id or "")
  local preview_url = tostring(
    voice.preview_url or
    (type(voice.raw) == "table" and voice.raw.preview_url) or
    ""
  )
  if voice_id == "" then return nil, "preview voice ID is missing" end
  return {
    voice_id = voice_id,
    name = tostring(voice.name or voice_id),
    preview_url = preview_url,
    public_owner_id = tostring(voice.public_owner_id or ""),
    language = tostring(voice.language or ""),
    accent = tostring(voice.accent or "")
  }
end

function VoicePreview.validate_audio(path)
  if type(path) ~= "string" or path == "" then
    return false, "preview file path is empty"
  end
  local file, open_err = io.open(path, "rb")
  if not file then
    return false, "preview file cannot be opened: " .. tostring(open_err or "unknown")
  end
  local size = file:seek("end")
  file:seek("set", 0)
  local head = file:read(256) or ""
  file:close()
  if not size or size <= 0 then
    return false, "preview file is empty"
  end
  local lowered = head:sub(1, 32):lower()
  if lowered:find("<%?xml", 1) or lowered:find("<html", 1, true) or lowered:find("{", 1, true) == 1 then
    return false, "preview server returned non-audio content"
  end
  local first, second = head:byte(1), head:byte(2)
  local frame_sync = first == 0xFF and second and (second & 0xE0) == 0xE0
  if frame_sync or head:sub(1, 3) == "ID3" then
    return true, size, {
      format = "mp3",
      extension = ".mp3"
    }
  end
  if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE" then
    return true, size, {
      format = "wav",
      extension = ".wav"
    }
  end
  return false, "preview file is not recognizable MP3 or WAV audio"
end

-- Retained for callers that explicitly need strict MP3 validation.
function VoicePreview.validate_mp3(path)
  local valid, size_or_err, info = VoicePreview.validate_audio(path)
  if not valid then return false, size_or_err end
  if not info or info.format ~= "mp3" then
    return false, "preview file is not recognizable MP3 audio"
  end
  return true, size_or_err
end

function VoicePreview.new(deps)
  assert(type(deps) == "table", "VoicePreview.new(deps): deps table is required")
  assert(type(deps.submit) == "function", "VoicePreview.new(deps): deps.submit is required")
  assert(type(deps.files) == "table", "VoicePreview.new(deps): deps.files is required")
  assert(type(deps.util) == "table", "VoicePreview.new(deps): deps.util is required")
  assert(type(deps.cache_dir_fn) == "function", "VoicePreview.new(deps): deps.cache_dir_fn is required")

  local self = setmetatable({
    deps = deps,
    translate = type(deps.translate) == "function" and deps.translate or identity,
    request_sequence = 0,
    current_request = nil,
    active_voice_id = "",
    active_owner = "",
    active_preview_id = "",
    active_path = "",
    cache_hits = 0,
    cache_misses = 0,
    coalesced_requests = 0,
    canceled_requests = 0,
    stale_completions = 0,
    validation_failures = 0,
    completed_downloads = 0
  }, VoicePreview)
  return self
end

function VoicePreview:available()
  return type(self.deps.play_file) == "function" and type(self.deps.stop_file) == "function"
end

function VoicePreview:cache_base_path(voice_id, cache_identity)
  local cache_dir = tostring(self.deps.cache_dir_fn() or "")
  if cache_dir == "" or tostring(voice_id or "") == "" or tostring(cache_identity or "") == "" then
    return nil
  end
  local safe_id = self.deps.util.sanitize_filename(tostring(voice_id), "voice", 120)
  return self.deps.util.path_join(
    cache_dir,
    "preview_" .. safe_id .. "_" .. stable_url_fingerprint(cache_identity)
  )
end

function VoicePreview:cache_path(voice_id, cache_identity, extension)
  local base_path = self:cache_base_path(voice_id, cache_identity)
  if not base_path then return nil end
  local suffix = extension == ".wav" and ".wav" or ".mp3"
  return base_path .. suffix
end

function VoicePreview:_emit(name, payload)
  safe_call(self.deps.on_event, name, payload or {})
end

function VoicePreview:_file_exists(path)
  if type(self.deps.file_exists) == "function" then
    return self.deps.file_exists(path) == true
  end
  return default_file_exists(path)
end

function VoicePreview:_enqueue_cleanup(path, reason)
  if not self:_file_exists(path) then return end
  if type(self.deps.enqueue_cleanup) == "function" then
    self.deps.enqueue_cleanup(path, reason)
  else
    self.deps.files.remove_best_effort(path)
  end
end

function VoicePreview:_is_current(request)
  return self.current_request == request and request.canceled ~= true and request.finished ~= true
end

function VoicePreview:_finish_error(request, message)
  if request.finished then return end
  request.finished = true
  if self.current_request == request then self.current_request = nil end
  self:_enqueue_cleanup(request.partial_path, "failed voice preview partial")
  callbacks_emit(request, "on_error", tostring(message or "preview failed"), request.token)
  self:_emit("failed", {
    token = request.token,
    voice_id = request.voice.voice_id,
    owner = request.owner,
    preview_id = request.preview_id,
    attempt = request.attempt,
    error = tostring(message or "preview failed")
  })
end

function VoicePreview:_finish_canceled(request)
  if request.finished then return end
  request.canceled = true
  request.finished = true
  if self.current_request == request then self.current_request = nil end
  self.canceled_requests = self.canceled_requests + 1
  self:_enqueue_cleanup(request.partial_path, "canceled voice preview partial")
  callbacks_emit(request, "on_canceled", request.token)
  self:_emit("canceled", {
    token = request.token,
    voice_id = request.voice.voice_id,
    owner = request.owner,
    preview_id = request.preview_id
  })
end

function VoicePreview:_play_file(request, path)
  if not self:_is_current(request) then
    self.stale_completions = self.stale_completions + 1
    return false, "stale"
  end
  local valid, validation_err = VoicePreview.validate_audio(path)
  if not valid then
    self.validation_failures = self.validation_failures + 1
    if request.owns_file then self.deps.files.remove_best_effort(path) end
    self:_finish_error(request, validation_err)
    return false, validation_err
  end

  local gain = finite_gain(request.gain)
  if not gain then
    self:_finish_error(request, "preview gain must be a finite number")
    return false, "preview gain must be a finite number"
  end

  pcall(self.deps.stop_file)
  local ok_call, played_or_err = pcall(self.deps.play_file, path, gain)
  if not ok_call or played_or_err ~= true then
    if request.owns_file then self.deps.files.remove_best_effort(path) end
    local message = ok_call and "native preview could not open the cached audio file" or
      ("native preview call failed: " .. tostring(played_or_err))
    self:_finish_error(request, message)
    return false, message
  end

  request.finished = true
  self.current_request = nil
  self.active_voice_id = request.voice.voice_id
  self.active_owner = request.owner
  self.active_preview_id = request.preview_id
  self.active_path = path
  callbacks_emit(request, "on_started", {
    token = request.token,
    voice_id = request.voice.voice_id,
    name = request.voice.name,
    path = path,
    gain = gain
  })
  self:_emit("started", {
    token = request.token,
    voice_id = request.voice.voice_id,
    owner = request.owner,
    preview_id = request.preview_id,
    cache_hit = request.cache_hit == true
  })
  return true
end

function VoicePreview:cancel()
  local request = self.current_request
  if not request then return false end
  self:_finish_canceled(request)
  return true
end

function VoicePreview:stop()
  local stopped_owner = self.current_request and self.current_request.owner or self.active_owner
  local stopped_preview_id =
    self.current_request and self.current_request.preview_id or self.active_preview_id
  self:cancel()
  self.request_sequence = self.request_sequence + 1
  self.active_voice_id = ""
  self.active_owner = ""
  self.active_preview_id = ""
  self.active_path = ""
  if type(self.deps.stop_file) ~= "function" then
    return false, "native preview stop function is unavailable"
  end
  local ok_stop, stop_err = pcall(self.deps.stop_file)
  if not ok_stop then
    return false, "native preview stop failed: " .. tostring(stop_err)
  end
  self:_emit("stopped", {
    owner = stopped_owner,
    preview_id = stopped_preview_id
  })
  return true
end

function VoicePreview:shutdown()
  return self:stop()
end

function VoicePreview:request(voice, callbacks, opts)
  opts = opts or {}
  if not self:available() then
    return nil, "native preview playback is unavailable"
  end
  local projected, voice_err = voice_fields(voice)
  if not projected then return nil, voice_err end

  local owner = tostring(opts.owner or "voice_library")
  local preview_id = tostring(opts.preview_id or projected.voice_id)
  local public_owner_id = tostring(opts.public_owner_id or projected.public_owner_id or "")
  local language = tostring(opts.language or projected.language or "")
  local accent = tostring(opts.accent or projected.accent or "")
  local cache_identity = table.concat({
    owner,
    public_owner_id,
    projected.voice_id,
    language,
    accent,
    projected.preview_url
  }, "\31")
  local request_key = table.concat({
    owner,
    preview_id,
    projected.voice_id,
    public_owner_id,
    language,
    accent,
    cache_identity
  }, "\31")
  if self.current_request and not self.current_request.finished and
     self.current_request.request_key == request_key then
    callbacks_add(self.current_request, callbacks)
    self.coalesced_requests = self.coalesced_requests + 1
    return self.current_request.token, "coalesced"
  end

  self:cancel()
  -- A replacement request owns the one global native preview channel. Stop
  -- current playback immediately instead of letting it continue while the
  -- replacement downloads.
  if self.active_voice_id ~= "" then
    local stopped_owner = self.active_owner
    local stopped_preview_id = self.active_preview_id
    pcall(self.deps.stop_file)
    self.active_voice_id = ""
    self.active_owner = ""
    self.active_preview_id = ""
    self.active_path = ""
    self:_emit("stopped", {
      owner = stopped_owner,
      preview_id = stopped_preview_id
    })
  end
  self.request_sequence = self.request_sequence + 1

  local cache_dir = tostring(self.deps.cache_dir_fn() or "")
  if cache_dir == "" then return nil, "preview cache directory is unavailable" end
  local ok_dir, dir_err = self.deps.files.ensure_tmp_dir(cache_dir)
  if not ok_dir then return nil, tostring(dir_err or "preview cache directory could not be created") end

  local cache_base_path = self:cache_base_path(projected.voice_id, cache_identity)
  if not cache_base_path then return nil, "could not build preview cache path" end

  local request = {
    token = self.request_sequence,
    request_key = request_key,
    voice = projected,
    owner = owner,
    preview_id = preview_id,
    public_owner_id = public_owner_id,
    language = language,
    accent = accent,
    owns_file = true,
    final_path = nil,
    partial_path = cache_base_path .. ".download.part",
    callbacks = {},
    attempt = 1,
    max_attempts = tonumber(opts.max_attempts or self.deps.max_attempts) or 3,
    gain = opts.gain == nil and 1.0 or opts.gain,
    finished = false,
    canceled = false
  }
  if request.max_attempts < 1 then request.max_attempts = 1 end
  callbacks_add(request, callbacks)
  self.current_request = request

  for _, extension in ipairs({ ".mp3", ".wav" }) do
    local cached_path = cache_base_path .. extension
    if self:_file_exists(cached_path) then
      local valid, _, format_info = VoicePreview.validate_audio(cached_path)
      local extension_matches =
        valid and format_info and format_info.extension == extension
      if extension_matches then
        request.final_path = cached_path
        request.cache_hit = true
        self.cache_hits = self.cache_hits + 1
        self:_emit("cache_hit", {
          token = request.token,
          voice_id = projected.voice_id,
          owner = request.owner,
          preview_id = request.preview_id,
          format = format_info.format
        })
        local played, play_err = self:_play_file(request, cached_path)
        if not played then return nil, play_err end
        return request.token, "cache_hit"
      end
      self.validation_failures = self.validation_failures + 1
      local removed, remove_err = self.deps.files.remove_best_effort(cached_path)
      if not removed then
        self:_finish_error(request, "invalid preview cache could not be removed: " .. tostring(remove_err))
        return nil, remove_err
      end
    end
  end

  self.cache_misses = self.cache_misses + 1
  if self:_file_exists(request.partial_path) then
    local removed, remove_err = self.deps.files.remove_best_effort(request.partial_path)
    if not removed then
      self:_finish_error(request, "stale preview partial could not be removed: " .. tostring(remove_err))
      return nil, remove_err
    end
  end

  local submit_once
  submit_once = function()
    if not self:_is_current(request) then return false, "canceled" end
    if self:_file_exists(request.partial_path) then
      local truncated, truncate_err = self.deps.files.truncate_file(request.partial_path)
      if not truncated then
        self:_finish_error(request, "could not reset preview partial: " .. tostring(truncate_err))
        return false, truncate_err
      end
    end

    local label = string.format("Preview %s", projected.name)
    if type(self.deps.format_attempt_label) == "function" then
      label = self.deps.format_attempt_label(label, request.attempt, request.max_attempts)
    end
    if type(self.deps.build_download_request) ~= "function" then
      local err_text = "Studio backend preview proxy request builder is unavailable"
      self:_finish_error(request, err_text)
      return false, err_text
    end
    local req, request_err = self.deps.build_download_request({
      voice_id = projected.voice_id,
      public_owner_id = request.public_owner_id,
      language = request.language,
      accent = request.accent,
      preview_id = request.preview_id,
      owner = request.owner,
      download_path = request.partial_path,
      label = label,
      timeout_sec = tonumber(opts.timeout_sec or self.deps.timeout_sec) or 300
    })
    if type(req) ~= "table" then
      local err_text = tostring(request_err or "Studio backend preview proxy request could not be built")
      self:_finish_error(request, err_text)
      return false, err_text
    end
    if req.backend_auth ~= "studio" then
      local err_text = "Remote preview requests must use the Studio Neurocast backend"
      self:_finish_error(request, err_text)
      return false, err_text
    end
    req.download_path = request.partial_path
    req.kind = req.kind or "el_voice_sample_preview"
    req.label = req.label or label
    req.timeout_sec = tonumber(req.timeout_sec) or
      tonumber(opts.timeout_sec or self.deps.timeout_sec) or 300
    local submit_opts = {
      read_body = false,
      keep_output = true
    }

    callbacks_emit(request, "on_download_started", {
      token = request.token,
      voice_id = projected.voice_id,
      attempt = request.attempt,
      max_attempts = request.max_attempts
    })
    self:_emit("download_started", {
      token = request.token,
      voice_id = projected.voice_id,
      owner = request.owner,
      preview_id = request.preview_id,
      attempt = request.attempt,
      max_attempts = request.max_attempts
    })

    local function on_done(result, job)
      if not self:_is_current(request) then
        self.stale_completions = self.stale_completions + 1
        self:_enqueue_cleanup(request.partial_path, "stale voice preview partial")
        return
      end
      if type(self.deps.update_last_curl_state) == "function" then
        self.deps.update_last_curl_state(result, job, label)
      end

      local valid_output, validation_err, format_info =
        VoicePreview.validate_audio(request.partial_path)
      if result and result.ok == true and valid_output then
        local final_path = cache_base_path .. format_info.extension
        request.final_path = final_path
        if self:_file_exists(final_path) then
          local existing_valid, _, existing_info = VoicePreview.validate_audio(final_path)
          if existing_valid and existing_info and
             existing_info.extension == format_info.extension then
            self.deps.files.remove_best_effort(request.partial_path)
            self.completed_downloads = self.completed_downloads + 1
            self:_play_file(request, final_path)
            return
          end
          local removed, remove_err = self.deps.files.remove_best_effort(final_path)
          if not removed then
            self:_finish_error(request, "existing preview cache could not be replaced: " .. tostring(remove_err))
            return
          end
        end

        local renamed, rename_err = (self.deps.rename or os.rename)(request.partial_path, final_path)
        if not renamed then
          -- Another process may have won the same atomic promotion.
          local existing_valid, _, existing_info
          if self:_file_exists(final_path) then
            existing_valid, _, existing_info = VoicePreview.validate_audio(final_path)
          end
          existing_valid = existing_valid and existing_info and
            existing_info.extension == format_info.extension
          if existing_valid then
            self.deps.files.remove_best_effort(request.partial_path)
          else
            self:_finish_error(request, "preview cache promotion failed: " .. tostring(rename_err or "unknown"))
            return
          end
        end
        self.completed_downloads = self.completed_downloads + 1
        self:_emit("download_completed", {
          token = request.token,
          voice_id = projected.voice_id,
          owner = request.owner,
          preview_id = request.preview_id,
          format = format_info.format
        })
        self:_play_file(request, final_path)
        return
      end

      local request_was_ok = result and result.ok == true
      if request_was_ok and not valid_output then
        self.validation_failures = self.validation_failures + 1
      end
      local error_text
      if request_was_ok then
        error_text = validation_err
      elseif type(self.deps.summarize_error) == "function" then
        error_text = self.deps.summarize_error(result)
      else
        error_text = result and result.err or "preview download failed"
      end
      error_text = tostring(error_text or "preview download failed")
      if result then
        result.ok = false
        result.err = error_text
      end
      if type(self.deps.update_retry_state) == "function" then
        self.deps.update_retry_state(request, error_text, result, error_text:sub(1, 512))
      end

      local retryable = request_was_ok and not valid_output
      if type(self.deps.is_retryable) == "function" then
        retryable = self.deps.is_retryable(result) == true or retryable
      end
      if retryable and request.attempt < request.max_attempts and
         type(self.deps.enqueue_retry) == "function" then
        request.attempt = request.attempt + 1
        callbacks_emit(request, "on_retry", {
          token = request.token,
          attempt = request.attempt,
          max_attempts = request.max_attempts,
          error = error_text
        })
        self.deps.enqueue_retry(
          label,
          submit_once,
          request.attempt,
          request.max_attempts,
          error_text,
          request
        )
      else
        self:_finish_error(request, error_text)
      end
    end

    request._retry_submit = submit_once
    local job, submit_err = self.deps.submit(req, on_done, submit_opts, request)
    if not job then
      self:_finish_error(request, "preview download failed to start: " .. tostring(submit_err))
      return false, submit_err
    end
    request.job_id = job.id
    callbacks_emit(request, "on_submitted", {
      token = request.token,
      voice_id = projected.voice_id,
      job_id = job.id
    })
    return true
  end

  local submitted, submit_err = submit_once()
  if not submitted then return nil, submit_err end
  return request.token, "submitted"
end

-- Plays an already-downloaded local preview through the same single native
-- channel used by remote previews. Local files are validated but never removed
-- by this controller when validation or playback fails.
function VoicePreview:play_local(preview, callbacks, opts)
  opts = opts or {}
  if not self:available() then
    return nil, "native preview playback is unavailable"
  end
  if type(preview) ~= "table" then return nil, "preview must be a table" end

  local path = tostring(preview.path or preview.output_path or "")
  local preview_id = tostring(preview.preview_id or preview.voice_id or preview.id or "")
  local owner = tostring(opts.owner or preview.owner or "local")
  if preview_id == "" then return nil, "preview ID is missing" end
  if path == "" then return nil, "preview file path is empty" end

  local valid, validation_err = VoicePreview.validate_audio(path)
  if not valid then
    self.validation_failures = self.validation_failures + 1
    return nil, validation_err
  end

  self:cancel()
  self.request_sequence = self.request_sequence + 1
  local stopped_owner = self.active_owner
  local stopped_preview_id = self.active_preview_id
  pcall(self.deps.stop_file)
  self.active_voice_id = ""
  self.active_owner = ""
  self.active_preview_id = ""
  self.active_path = ""
  if stopped_owner ~= "" then
    self:_emit("stopped", {
      owner = stopped_owner,
      preview_id = stopped_preview_id
    })
  end

  local request = {
    token = self.request_sequence,
    request_key = table.concat({ owner, preview_id, path }, "\31"),
    voice = {
      voice_id = tostring(preview.voice_id or preview_id),
      name = tostring(preview.name or preview_id)
    },
    owner = owner,
    preview_id = preview_id,
    owns_file = false,
    final_path = path,
    callbacks = {},
    gain = opts.gain == nil and 1.0 or opts.gain,
    finished = false,
    canceled = false
  }
  callbacks_add(request, callbacks)
  self.current_request = request
  local played, play_err = self:_play_file(request, path)
  if not played then return nil, play_err end
  return request.token, "local"
end

function VoicePreview:sweep_orphans()
  if type(self.deps.enumerate_files) ~= "function" then
    return 0, "file enumeration is unavailable"
  end
  local cache_dir = tostring(self.deps.cache_dir_fn() or "")
  if cache_dir == "" then return 0, "preview cache directory is unavailable" end

  local count = 0
  local index = 0
  while true do
    local filename = self.deps.enumerate_files(cache_dir, index)
    if not filename then break end
    if tostring(filename):sub(-5) == ".part" then
      local path = self.deps.util.path_join(cache_dir, filename)
      self:_enqueue_cleanup(path, "orphaned voice preview partial")
      count = count + 1
    end
    index = index + 1
  end
  if count > 0 then self:_emit("orphans_queued", { count = count }) end
  return count
end

function VoicePreview:stats()
  return {
    available = self:available(),
    busy = self.current_request ~= nil,
    active_voice_id = self.active_voice_id,
    active_owner = self.active_owner,
    active_preview_id = self.active_preview_id,
    cache_hits = self.cache_hits,
    cache_misses = self.cache_misses,
    coalesced_requests = self.coalesced_requests,
    canceled_requests = self.canceled_requests,
    stale_completions = self.stale_completions,
    validation_failures = self.validation_failures,
    completed_downloads = self.completed_downloads
  }
end

function VoicePreview:status()
  if self.current_request and not self.current_request.finished then
    return {
      available = self:available(),
      state = "downloading",
      owner = tostring(self.current_request.owner or ""),
      preview_id = tostring(self.current_request.preview_id or ""),
      voice_id = tostring(
        self.current_request.voice and self.current_request.voice.voice_id or ""
      )
    }
  end
  if self.active_voice_id ~= "" then
    return {
      available = self:available(),
      state = "playing",
      owner = self.active_owner,
      preview_id = self.active_preview_id,
      voice_id = self.active_voice_id
    }
  end
  return {
    available = self:available(),
    state = "idle",
    owner = "",
    preview_id = "",
    voice_id = ""
  }
end

return VoicePreview
