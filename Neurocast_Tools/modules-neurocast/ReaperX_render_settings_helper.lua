-- Preferred shared helper for REAPER render settings.
--
-- Scope:
--   - snapshot current render settings into a raw-key Lua table
--   - apply raw-key render setting profiles
--   - restore snapshots after temporary render setup
--   - format/decode render settings for diagnostics
--
-- This module intentionally owns only writable RENDER_* settings plus
-- PROJECT_SRATE_USE. Existing callers can migrate to it when ready; legacy
-- inline render setup code should not be treated as the preferred pattern.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper

local RenderSettings = {}

local SCHEMA_VERSION = 1

local DEFAULT_NUMERIC_KEYS = {
  "RENDER_SETTINGS",
  "RENDER_BOUNDSFLAG",
  "RENDER_CHANNELS",
  "RENDER_SRATE",
  "RENDER_STARTPOS",
  "RENDER_ENDPOS",
  "RENDER_TAILFLAG",
  "RENDER_TAILMS",
  "RENDER_ADDTOPROJ",
  "RENDER_DITHER",
  "RENDER_NORMALIZE",
  "RENDER_NORMALIZE_TARGET",
  "RENDER_BRICKWALL",
  "RENDER_FADEIN",
  "RENDER_FADEOUT",
  "RENDER_FADEINSHAPE",
  "RENDER_FADEOUTSHAPE",
  "RENDER_FADELPF",
  "RENDER_PADSTART",
  "RENDER_PADEND",
  "RENDER_TRIMSTART",
  "RENDER_TRIMEND",
  "RENDER_DELAY",
  "PROJECT_SRATE_USE"
}

local DEFAULT_STRING_KEYS = {
  "RENDER_FILE",
  "RENDER_PATTERN",
  "RENDER_EXTRAFILEDIR",
  "RENDER_FORMAT",
  "RENDER_FORMAT2"
}

RenderSettings.RENDER_SETTINGS = {
  MODE_MASTER_MIX = 0,
  MODE_STEMS_AND_MASTER_MIX = 1,
  MODE_STEMS_ONLY = 2,
  MULTICHANNEL_TRACKS_TO_MULTICHANNEL_FILES = 4,
  USE_RENDER_MATRIX = 8,
  MONO_SOURCES_TO_MONO_FILES = 16,
  SELECTED_MEDIA_ITEMS = 32,
  SELECTED_MEDIA_ITEMS_VIA_MASTER = 64,
  SELECTED_TRACKS_VIA_MASTER = 128,
  EMBED_TRANSIENTS = 256,
  EMBED_METADATA = 512,
  EMBED_TAKE_MARKERS = 1024,
  SECOND_PASS_RENDER = 2048,
  RENDER_RAZOR_EDITS = 4096,
  PRE_FADER_STEMS = 8192,
  ONLY_STEM_CHANNELS_SENT_TO_PARENT = 16384,
  PRESERVE_SOURCE_METADATA = 32768,
  PRESERVE_SOURCE_START_OFFSET = 1 << 16,
  PRESERVE_SOURCE_MEDIA_SAMPLE_RATE = 2 << 16,
  SELECTED_ITEMS_OR_RAZOR_EDITS_AS_SINGLE_FILE = 4 << 16,
  PARALLEL_RENDER_VIA_MASTER = 8 << 16,
  DELAY_RENDER_START = 16 << 16
}

RenderSettings.RENDER_BOUNDSFLAG = {
  CUSTOM_TIME_BOUNDS = 0,
  ENTIRE_PROJECT = 1,
  TIME_SELECTION = 2,
  ALL_PROJECT_REGIONS = 3,
  SELECTED_MEDIA_ITEMS = 4,
  SELECTED_PROJECT_REGIONS = 5,
  ALL_PROJECT_MARKERS = 6,
  SELECTED_PROJECT_MARKERS = 7
}

RenderSettings.RENDER_NORMALIZE = {
  ENABLE_NORMALIZATION = 1,
  MODE_LUFS_I = 0,
  MODE_RMS = 2,
  MODE_PEAK = 4,
  MODE_TRUE_PEAK = 6,
  MODE_LUFS_M_MAX = 8,
  MODE_LUFS_S_MAX = 10,
  MONO_ADJUST_MINUS_3_DB = 16,
  MONO_ADJUST_PLUS_3_DB = 16 | (8 << 16),
  NORMALIZE_AS_FILES_PLAY_TOGETHER = 32,
  NORMALIZE_TO_LOUDEST_FILE = 4096,
  NORMALIZE_AS_FILES_PLAY_TOGETHER_COMMON_GAIN = 32 | 4096,
  NORMALIZE_TO_MASTER_MIX = 16 << 16,
  ENABLE_BRICKWALL_LIMIT = 64,
  BRICKWALL_TRUE_PEAK = 128,
  ONLY_NORMALIZE_TOO_LOUD = 256,
  ONLY_NORMALIZE_TOO_QUIET = 2048,
  APPLY_FADE_IN = 512,
  APPLY_FADE_OUT = 1024,
  TRIM_STARTING_SILENCE = 16384,
  TRIM_ENDING_SILENCE = 32768,
  PAD_START_WITH_SILENCE = 1 << 16,
  PAD_END_WITH_SILENCE = 2 << 16,
  DISABLE_ALL_RENDER_POSTPROCESSING = 4 << 16,
  LIMIT_AS_FILES_PLAY_TOGETHER = 32 << 16,
  LIMIT_TO_MASTER_MIX = 64 << 16
}

RenderSettings.SINK_FORMATS = {
  WAV_16BIT = "ZXZhdxAAAQ==",
  WAV_24BIT = "ZXZhdxgAAQ==",
  FLAC_16BIT = "Y2FsZhAAAAAIAAAA",
  FLAC_24BIT = "Y2FsZhgAAAAIAAAA"
}

local function copy_list(items)
  local out = {}
  for i = 1, #(items or {}) do
    out[i] = items[i]
  end
  return out
end

local function make_set(items)
  local out = {}
  for i = 1, #(items or {}) do
    out[items[i]] = true
  end
  return out
end

RenderSettings.DEFAULT_NUMERIC_KEYS = copy_list(DEFAULT_NUMERIC_KEYS)
RenderSettings.DEFAULT_STRING_KEYS = copy_list(DEFAULT_STRING_KEYS)

local NUMERIC_SPECS = {
  RENDER_SETTINGS = {
    kind = "bitmask",
    note = "main render behavior flags",
    mode_decoder = function(value)
      local mode_bits = value & 3
      local mode_name_map = {
        [0] = "master mix",
        [1] = "stems + master mix",
        [2] = "stems only",
        [3] = "unknown/unrecognized base mode"
      }
      return mode_bits, mode_name_map[mode_bits] or "unknown/unrecognized base mode"
    end,
    flags = {
      { bit = 4, name = "multichannel tracks to multichannel files", explanation = "render multichannel tracks to multichannel output files" },
      { bit = 8, name = "use render matrix", explanation = "use render matrix routing" },
      { bit = 16, name = "mono sources to mono files", explanation = "tracks with only mono media render to mono files" },
      { bit = 32, name = "selected media items", explanation = "render selected media items" },
      { bit = 64, name = "selected media items via master", explanation = "render selected items through master mix path" },
      { bit = 128, name = "selected tracks via master", explanation = "render selected tracks through master mix path" },
      { bit = 256, name = "embed transients", explanation = "embed transient data if format supports it" },
      { bit = 512, name = "embed metadata", explanation = "embed metadata if format supports it" },
      { bit = 1024, name = "embed take markers", explanation = "embed take markers if format supports it" },
      { bit = 2048, name = "2nd pass render", explanation = "use two-pass rendering" },
      { bit = 4096, name = "render razor edits", explanation = "render razor edit areas" },
      { bit = 8192, name = "pre-fader stems", explanation = "render stems pre-fader, except when via master" },
      { bit = 16384, name = "only stem channels sent to parent", explanation = "limit stem output to channels sent to parent" },
      { bit = 32768, name = "preserve source metadata", explanation = "preserve source metadata if possible" },
      { bit = 1 << 16, name = "preserve source start offset", explanation = "preserve source media start offset if possible" },
      { bit = 2 << 16, name = "preserve source media sample rate", explanation = "preserve source sample rate if possible" },
      { bit = 4 << 16, name = "selected items/razor edits as single file", explanation = "render selected items or razor edits into one file" },
      { bit = 8 << 16, name = "parallel render via master", explanation = "render in parallel through master path" },
      { bit = 16 << 16, name = "delay render start", explanation = "delay render start so FX can initialize/load samples" }
    }
  },
  RENDER_BOUNDSFLAG = {
    kind = "enum",
    note = "what area is rendered",
    values = {
      [0] = "custom time bounds",
      [1] = "entire project",
      [2] = "time selection",
      [3] = "all project regions",
      [4] = "selected media items",
      [5] = "selected project regions",
      [6] = "all project markers",
      [7] = "selected project markers"
    }
  },
  RENDER_CHANNELS = {
    kind = "plain",
    note = "number of channels in rendered file"
  },
  RENDER_SRATE = {
    kind = "plain",
    note = "render sample rate, 0 means use project sample rate"
  },
  RENDER_STARTPOS = {
    kind = "plain",
    note = "render start time when bounds mode is custom time bounds"
  },
  RENDER_ENDPOS = {
    kind = "plain",
    note = "render end time when bounds mode is custom time bounds"
  },
  RENDER_TAILFLAG = {
    kind = "bitmask_no_mode",
    note = "when tail is applied",
    flags = {
      { bit = 1, name = "custom time bounds", explanation = "apply tail when rendering custom bounds" },
      { bit = 2, name = "entire project", explanation = "apply tail when rendering entire project" },
      { bit = 4, name = "time selection", explanation = "apply tail when rendering time selection" },
      { bit = 8, name = "all project markers/regions", explanation = "apply tail for all markers/regions" },
      { bit = 16, name = "selected media items", explanation = "apply tail for selected media items" },
      { bit = 32, name = "selected project markers/regions", explanation = "apply tail for selected markers/regions" }
    }
  },
  RENDER_TAILMS = {
    kind = "plain",
    note = "tail length in milliseconds"
  },
  RENDER_ADDTOPROJ = {
    kind = "bitmask_no_mode",
    note = "post-render project actions",
    flags = {
      { bit = 1, name = "add rendered files to project", explanation = "add result files back into the project" },
      { bit = 2, name = "skip likely silent files", explanation = "do not render files likely to be silent" }
    }
  },
  RENDER_DITHER = {
    kind = "bitmask_no_mode",
    note = "dither and noise shaping options",
    flags = {
      { bit = 1, name = "dither", explanation = "enable dither" },
      { bit = 2, name = "noise shaping", explanation = "enable noise shaping" },
      { bit = 4, name = "dither stems", explanation = "enable dither for stem renders" },
      { bit = 8, name = "noise shaping on stems", explanation = "enable noise shaping for stems" },
      { bit = 16, name = "disable all", explanation = "disable all dither/noise shaping processing" }
    }
  },
  RENDER_NORMALIZE = {
    kind = "render_normalize",
    note = "render normalization / limiting / trim / pad options"
  },
  RENDER_NORMALIZE_TARGET = {
    kind = "plain",
    note = "normalization target, only relevant when normalization is enabled"
  },
  RENDER_BRICKWALL = {
    kind = "plain",
    note = "brickwall limit target, only relevant when brickwall limiting is enabled"
  },
  RENDER_FADEIN = {
    kind = "plain",
    note = "fade-in duration, only relevant when fade-in is enabled"
  },
  RENDER_FADEOUT = {
    kind = "plain",
    note = "fade-out duration, only relevant when fade-out is enabled"
  },
  RENDER_FADEINSHAPE = {
    kind = "plain",
    note = "fade-in shape"
  },
  RENDER_FADEOUTSHAPE = {
    kind = "plain",
    note = "fade-out shape"
  },
  RENDER_FADELPF = {
    kind = "bitmask_no_mode",
    note = "low-pass fade options",
    flags = {
      { bit = 1, name = "fade-in LPF", explanation = "apply low-pass frequency fade-in" },
      { bit = 2, name = "fade-out LPF", explanation = "apply low-pass frequency fade-out" }
    }
  },
  RENDER_PADSTART = {
    kind = "plain",
    note = "pad start with silence duration"
  },
  RENDER_PADEND = {
    kind = "plain",
    note = "pad end with silence duration"
  },
  RENDER_TRIMSTART = {
    kind = "plain",
    note = "trim start threshold"
  },
  RENDER_TRIMEND = {
    kind = "plain",
    note = "trim end threshold"
  },
  RENDER_DELAY = {
    kind = "plain",
    note = "delay before render start for FX initialization"
  },
  PROJECT_SRATE_USE = {
    kind = "enum",
    note = "whether project sample rate override is used",
    values = {
      [0] = "disabled",
      [1] = "enabled"
    }
  }
}

local STRING_SPECS = {
  RENDER_FILE = {
    note = "render directory"
  },
  RENDER_PATTERN = {
    note = "render file name pattern"
  },
  RENDER_EXTRAFILEDIR = {
    note = "alternate path for extra render files"
  },
  RENDER_FORMAT = {
    note = "render sink config, printed as-is"
  },
  RENDER_FORMAT2 = {
    note = "secondary render sink config, printed as-is"
  }
}

local EXCLUDED_KEYS = {
  RENDER_METADATA = "RENDER_METADATA has special identifier/value semantics and is excluded from v1.",
  RENDER_TARGETS = "RENDER_TARGETS is read-only and is excluded from v1.",
  RENDER_STATS = "RENDER_STATS is read-only and is excluded from v1.",
  RENDER_STATS_SUMMARY = "RENDER_STATS_SUMMARY is read-only and is excluded from v1.",
  PROJECT_SRATE = "PROJECT_SRATE changes the project sample-rate override value and is excluded from v1."
}

local DEFAULT_NUMERIC_KEY_SET = make_set(DEFAULT_NUMERIC_KEYS)
local DEFAULT_STRING_KEY_SET = make_set(DEFAULT_STRING_KEYS)

local function project_from_opts(opts)
  if type(opts) == "table" and opts.project ~= nil then
    return opts.project
  end
  return 0
end

local function ensure_required_api()
  if type(r.GetSetProjectInfo) ~= "function" then
    return false, "ReaScript function not found: GetSetProjectInfo"
  end
  if type(r.GetSetProjectInfo_String) ~= "function" then
    return false, "ReaScript function not found: GetSetProjectInfo_String"
  end
  return true, nil
end

local function key_reason(key)
  if EXCLUDED_KEYS[key] then
    return EXCLUDED_KEYS[key]
  end
  if NUMERIC_SPECS[key] then
    return "This is a numeric render setting; put it under profile.numeric."
  end
  if STRING_SPECS[key] then
    return "This is a string render setting; put it under profile.strings."
  end
  return "Unknown or unsupported render setting key."
end

local function normalize_key_list(kind, opts)
  local option_name = kind == "numeric" and "numeric_keys" or "string_keys"
  local default_keys = kind == "numeric" and DEFAULT_NUMERIC_KEYS or DEFAULT_STRING_KEYS
  local specs = kind == "numeric" and NUMERIC_SPECS or STRING_SPECS
  local selected = type(opts) == "table" and opts[option_name] or nil

  if selected == nil then
    return copy_list(default_keys), nil
  end
  if type(selected) ~= "table" then
    return nil, "opts." .. option_name .. " must be a table when provided"
  end

  local out = {}
  local seen = {}
  for i = 1, #selected do
    local key = selected[i]
    if type(key) ~= "string" or key == "" then
      return nil, "opts." .. option_name .. "[" .. tostring(i) .. "] must be a non-empty string"
    end
    if not specs[key] then
      return nil, "Unsupported " .. kind .. " render setting key `" .. key .. "`: " .. key_reason(key)
    end
    if seen[key] then
      return nil, "Duplicate " .. kind .. " render setting key `" .. key .. "`"
    end
    seen[key] = true
    out[#out + 1] = key
  end
  return out, nil
end

local function to_integer(value)
  local n = tonumber(value)
  if not n then return nil end
  if math.tointeger then
    local i = math.tointeger(n)
    if i then return i end
  end
  if n >= 0 then
    return math.floor(n)
  end
  return math.ceil(n)
end

local function join_list(items)
  if #items == 0 then
    return "(none)"
  end
  return table.concat(items, ", ")
end

local function collect_enabled_flags(value, flags)
  local enabled = {}
  local recognized_bits = 0

  for i = 1, #(flags or {}) do
    local flag = flags[i]
    recognized_bits = recognized_bits | flag.bit
    if (value & flag.bit) ~= 0 then
      enabled[#enabled + 1] = {
        bit = flag.bit,
        name = flag.name,
        explanation = flag.explanation
      }
    end
  end

  local unrecognized_bits = value & (~recognized_bits)
  return enabled, unrecognized_bits
end

local function enabled_flags_text(enabled)
  local parts = {}
  for i = 1, #(enabled or {}) do
    local flag = enabled[i]
    parts[#parts + 1] = tostring(flag.name) .. " (" .. tostring(flag.explanation) .. ")"
  end
  return join_list(parts)
end

local function decode_render_normalize(key, value, spec)
  local int_value = to_integer(value)
  if not int_value then
    return nil, key .. " must be numeric"
  end

  local enabled = {}
  local recognized_bits = 0

  local function add_flag(bit, name, explanation)
    recognized_bits = recognized_bits | bit
    if (int_value & bit) ~= 0 then
      enabled[#enabled + 1] = {
        bit = bit,
        name = name,
        explanation = explanation
      }
    end
  end

  add_flag(1, "enable normalization", "normalization is enabled")

  local normalize_mode_bits = int_value & 14
  recognized_bits = recognized_bits | 14
  local normalize_mode_name_map = {
    [0] = "LUFS-I",
    [2] = "RMS",
    [4] = "peak",
    [6] = "true peak",
    [8] = "LUFS-M max",
    [10] = "LUFS-S max",
    [12] = "unknown/unrecognized normalization mode",
    [14] = "unknown/unrecognized normalization mode"
  }
  local normalize_mode_name = normalize_mode_name_map[normalize_mode_bits] or "unknown/unrecognized normalization mode"

  local mono_adjust_group = int_value & (16 | (8 << 16))
  recognized_bits = recognized_bits | 16 | (8 << 16)
  local mono_adjust_name_map = {
    [0] = "default",
    [16] = "adjust mono media -3 dB",
    [8 << 16] = "unknown/unrecognized mono adjust mode",
    [16 | (8 << 16)] = "adjust mono media +3 dB"
  }
  local mono_adjust_name = mono_adjust_name_map[mono_adjust_group] or "unknown/unrecognized mono adjust mode"

  local normalize_scope_group = int_value & (32 | 4096 | (16 << 16))
  recognized_bits = recognized_bits | 32 | 4096 | (16 << 16)
  local normalize_scope_map = {
    [32] = "normalize as if files play together",
    [4096] = "normalize to loudest file",
    [32 | 4096] = "normalize as if files play together (common gain)",
    [16 << 16] = "normalize to master mix"
  }
  local normalize_scope_name = normalize_scope_map[normalize_scope_group] or "default / no special normalize scope"

  add_flag(64, "enable brickwall limit", "brickwall limiting is enabled")
  add_flag(128, "brickwall true peak", "brickwall limit uses true peak")

  local loudness_filter_group = int_value & (256 | 2048)
  recognized_bits = recognized_bits | 256 | 2048
  local loudness_filter_map = {
    [0] = "default",
    [256] = "only normalize files that are too loud",
    [2048] = "only normalize files that are too quiet",
    [256 | 2048] = "unknown/unrecognized loudness filter mode"
  }
  local loudness_filter_name = loudness_filter_map[loudness_filter_group] or "unknown/unrecognized loudness filter mode"

  add_flag(512, "apply fade-in", "apply render fade-in")
  add_flag(1024, "apply fade-out", "apply render fade-out")
  add_flag(16384, "trim starting silence", "trim start silence")
  add_flag(32768, "trim ending silence", "trim end silence")
  add_flag(1 << 16, "pad start with silence", "pad render start with silence")
  add_flag(2 << 16, "pad end with silence", "pad render end with silence")
  add_flag(4 << 16, "disable all render postprocessing", "disable all render post-processing")

  local limit_scope_group = int_value & ((32 << 16) | (64 << 16))
  recognized_bits = recognized_bits | (32 << 16) | (64 << 16)
  local limit_scope_map = {
    [0] = "default",
    [32 << 16] = "limit as if files play together",
    [64 << 16] = "limit to master mix",
    [(32 << 16) | (64 << 16)] = "unknown/unrecognized limit scope mode"
  }
  local limit_scope_name = limit_scope_map[limit_scope_group] or "unknown/unrecognized limit scope mode"

  local unrecognized_bits = int_value & (~recognized_bits)

  return {
    key = key,
    kind = spec.kind,
    value = value,
    int_value = int_value,
    note = spec.note,
    flags = enabled,
    normalize_mode = normalize_mode_name,
    mono_adjust = mono_adjust_name,
    normalize_scope = normalize_scope_name,
    loudness_filter = loudness_filter_name,
    limit_scope = limit_scope_name,
    unrecognized_bits = unrecognized_bits
  }, nil
end

local function decode_numeric_value(key, value, spec)
  if type(value) ~= "number" then
    return nil, key .. " must be numeric"
  end

  if spec.kind == "plain" then
    return {
      key = key,
      kind = spec.kind,
      value = value,
      note = spec.note
    }, nil
  end

  local int_value = to_integer(value)
  if not int_value then
    return nil, key .. " must be convertible to an integer for decoding"
  end

  if spec.kind == "enum" then
    return {
      key = key,
      kind = spec.kind,
      value = value,
      int_value = int_value,
      mode = spec.values[int_value] or "unknown/unrecognized value",
      note = spec.note
    }, nil
  end

  if spec.kind == "bitmask_no_mode" then
    local enabled, unrecognized_bits = collect_enabled_flags(int_value, spec.flags)
    return {
      key = key,
      kind = spec.kind,
      value = value,
      int_value = int_value,
      flags = enabled,
      unrecognized_bits = unrecognized_bits,
      note = spec.note
    }, nil
  end

  if spec.kind == "bitmask" then
    local mode_bits, mode_name = spec.mode_decoder(int_value)
    local enabled, unrecognized_bits = collect_enabled_flags(int_value, spec.flags)
    local unrecognized_without_mode = unrecognized_bits & (~mode_bits)
    return {
      key = key,
      kind = spec.kind,
      value = value,
      int_value = int_value,
      mode_bits = mode_bits,
      mode = mode_name,
      flags = enabled,
      unrecognized_bits = unrecognized_without_mode,
      note = spec.note
    }, nil
  end

  if spec.kind == "render_normalize" then
    return decode_render_normalize(key, value, spec)
  end

  return nil, key .. " has unsupported decoder kind `" .. tostring(spec.kind) .. "`"
end

function RenderSettings.decode_value(key, value)
  if type(key) ~= "string" or key == "" then
    return nil, "key must be a non-empty string"
  end

  local numeric_spec = NUMERIC_SPECS[key]
  if numeric_spec then
    return decode_numeric_value(key, value, numeric_spec)
  end

  local string_spec = STRING_SPECS[key]
  if string_spec then
    if type(value) ~= "string" then
      return nil, key .. " must be a string"
    end
    return {
      key = key,
      kind = "string",
      value = value,
      note = string_spec.note
    }, nil
  end

  return nil, "Unsupported render setting key `" .. key .. "`: " .. key_reason(key)
end

local function format_unrecognized_suffix(decoded)
  local bits = tonumber(decoded and decoded.unrecognized_bits) or 0
  if bits == 0 then
    return ""
  end
  return " | unrecognized=0x" .. string.format("%X", bits)
end

local function format_decoded(decoded)
  if decoded.kind == "plain" then
    return decoded.key .. " = " .. tostring(decoded.value) .. " | note=" .. tostring(decoded.note)
  end
  if decoded.kind == "enum" then
    return decoded.key .. " = " .. tostring(decoded.value) .. " | mode=" .. tostring(decoded.mode) .. " | note=" .. tostring(decoded.note)
  end
  if decoded.kind == "bitmask_no_mode" then
    return decoded.key
      .. " = " .. tostring(decoded.value)
      .. " | flags=" .. enabled_flags_text(decoded.flags)
      .. format_unrecognized_suffix(decoded)
      .. " | note=" .. tostring(decoded.note)
  end
  if decoded.kind == "bitmask" then
    return decoded.key
      .. " = " .. tostring(decoded.value)
      .. " | mode=" .. tostring(decoded.mode)
      .. " | flags=" .. enabled_flags_text(decoded.flags)
      .. format_unrecognized_suffix(decoded)
      .. " | note=" .. tostring(decoded.note)
  end
  if decoded.kind == "render_normalize" then
    return decoded.key
      .. " = " .. tostring(decoded.value)
      .. " | flags=" .. enabled_flags_text(decoded.flags)
      .. " | normalize_mode=" .. tostring(decoded.normalize_mode)
      .. " | mono_adjust=" .. tostring(decoded.mono_adjust)
      .. " | normalize_scope=" .. tostring(decoded.normalize_scope)
      .. " | loudness_filter=" .. tostring(decoded.loudness_filter)
      .. " | limit_scope=" .. tostring(decoded.limit_scope)
      .. format_unrecognized_suffix(decoded)
      .. " | note=" .. tostring(decoded.note)
  end
  if decoded.kind == "string" then
    return decoded.key .. " = " .. string.format("%q", tostring(decoded.value or "")) .. " | note=" .. tostring(decoded.note)
  end
  return decoded.key .. " = " .. tostring(decoded.value) .. " | note=unknown decoder kind"
end

function RenderSettings.format_value(key, value)
  local decoded, err = RenderSettings.decode_value(key, value)
  if not decoded then
    return tostring(key) .. " = " .. tostring(value) .. " | error=" .. tostring(err)
  end
  return format_decoded(decoded)
end

local function build_allowed_key_set(keys)
  local allowed = {}
  for i = 1, #(keys or {}) do
    allowed[keys[i]] = true
  end
  return allowed
end

function RenderSettings.validate_profile(profile, opts)
  if type(profile) ~= "table" then
    return false, "render settings profile must be a table"
  end
  if profile.schema_version ~= nil and profile.schema_version ~= SCHEMA_VERSION then
    return false, "unsupported render settings profile schema_version: " .. tostring(profile.schema_version)
  end

  local numeric_keys, numeric_err = normalize_key_list("numeric", opts)
  if not numeric_keys then return false, numeric_err end
  local string_keys, string_err = normalize_key_list("string", opts)
  if not string_keys then return false, string_err end
  local allowed_numeric = build_allowed_key_set(numeric_keys)
  local allowed_strings = build_allowed_key_set(string_keys)

  if profile.numeric ~= nil and type(profile.numeric) ~= "table" then
    return false, "profile.numeric must be a table when provided"
  end
  if profile.strings ~= nil and type(profile.strings) ~= "table" then
    return false, "profile.strings must be a table when provided"
  end

  for key, value in pairs(profile.numeric or {}) do
    if type(key) ~= "string" or key == "" then
      return false, "profile.numeric keys must be non-empty strings"
    end
    if not NUMERIC_SPECS[key] then
      return false, "profile.numeric." .. key .. " is not a supported numeric render setting: " .. key_reason(key)
    end
    if not allowed_numeric[key] then
      return false, "profile.numeric." .. key .. " is not selected by opts.numeric_keys"
    end
    if type(value) ~= "number" then
      return false, "profile.numeric." .. key .. " must be a number"
    end
  end

  for key, value in pairs(profile.strings or {}) do
    if type(key) ~= "string" or key == "" then
      return false, "profile.strings keys must be non-empty strings"
    end
    if not STRING_SPECS[key] then
      return false, "profile.strings." .. key .. " is not a supported string render setting: " .. key_reason(key)
    end
    if not allowed_strings[key] then
      return false, "profile.strings." .. key .. " is not selected by opts.string_keys"
    end
    if type(value) ~= "string" then
      return false, "profile.strings." .. key .. " must be a string"
    end
  end

  return true, nil
end

function RenderSettings.snapshot(opts)
  local ok_api, api_err = ensure_required_api()
  if not ok_api then return nil, api_err end

  local numeric_keys, numeric_err = normalize_key_list("numeric", opts)
  if not numeric_keys then return nil, numeric_err end
  local string_keys, string_err = normalize_key_list("string", opts)
  if not string_keys then return nil, string_err end
  local project = project_from_opts(opts)

  local snapshot = {
    schema_version = SCHEMA_VERSION,
    numeric = {},
    strings = {}
  }

  for i = 1, #numeric_keys do
    local key = numeric_keys[i]
    snapshot.numeric[key] = r.GetSetProjectInfo(project, key, 0, false)
  end

  for i = 1, #string_keys do
    local key = string_keys[i]
    local ok_string, value = r.GetSetProjectInfo_String(project, key, "", false)
    if ok_string ~= true then
      return nil, "Failed to read string render setting `" .. key .. "`"
    end
    snapshot.strings[key] = tostring(value or "")
  end

  return snapshot, nil
end

function RenderSettings.apply(profile, opts)
  local ok_api, api_err = ensure_required_api()
  if not ok_api then return false, api_err end

  local ok_validate, validate_err = RenderSettings.validate_profile(profile, opts)
  if not ok_validate then return false, validate_err end

  local numeric_keys, numeric_err = normalize_key_list("numeric", opts)
  if not numeric_keys then return false, numeric_err end
  local string_keys, string_err = normalize_key_list("string", opts)
  if not string_keys then return false, string_err end
  local project = project_from_opts(opts)
  local numeric = profile.numeric or {}
  local strings = profile.strings or {}

  for i = 1, #numeric_keys do
    local key = numeric_keys[i]
    local value = numeric[key]
    if value ~= nil then
      r.GetSetProjectInfo(project, key, value, true)
    end
  end

  for i = 1, #string_keys do
    local key = string_keys[i]
    local value = strings[key]
    if value ~= nil then
      local ok_set = r.GetSetProjectInfo_String(project, key, value, true)
      if ok_set ~= true then
        return false, "Failed to set string render setting `" .. key .. "`"
      end
    end
  end

  return true, nil
end

function RenderSettings.restore(snapshot, opts)
  return RenderSettings.apply(snapshot, opts)
end

local function combine_failure(primary, restore_err)
  if restore_err and restore_err ~= "" then
    return tostring(primary) .. "\nAdditionally failed to restore render settings: " .. tostring(restore_err)
  end
  return tostring(primary)
end

function RenderSettings.with_render_settings(profile, work_fn, opts)
  if type(work_fn) ~= "function" then
    return false, "work_fn must be a function", nil
  end

  local original, snapshot_err = RenderSettings.snapshot(opts)
  if not original then
    return false, "Failed to snapshot render settings: " .. tostring(snapshot_err), nil
  end

  local ok_apply, apply_err = RenderSettings.apply(profile, opts)
  if not ok_apply then
    local ok_restore, restore_err = RenderSettings.restore(original, opts)
    if not ok_restore then
      return false, combine_failure("Failed to apply render settings: " .. tostring(apply_err), restore_err), nil
    end
    return false, "Failed to apply render settings: " .. tostring(apply_err), nil
  end

  local work_ok, work_result_1, work_result_2, work_result_3 = xpcall(work_fn, function(err)
    return debug.traceback(tostring(err), 2)
  end)

  local ok_restore, restore_err = RenderSettings.restore(original, opts)

  if not work_ok then
    return false, combine_failure(work_result_1, restore_err), nil
  end

  if work_result_1 == false then
    local failure_message = tostring(work_result_2 or "Render work failed.")
    if not ok_restore then
      failure_message = combine_failure(failure_message, restore_err)
    end
    return false, failure_message, work_result_3
  end

  if not ok_restore then
    return false, "Failed to restore render settings: " .. tostring(restore_err), nil
  end

  return work_result_1, work_result_2, work_result_3
end

local function append_formatted_values(lines, title, keys, values)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "---- " .. title .. " ----"
  for i = 1, #keys do
    local key = keys[i]
    if values and values[key] ~= nil then
      lines[#lines + 1] = RenderSettings.format_value(key, values[key])
    end
  end
end

function RenderSettings.format_snapshot(snapshot, opts)
  if type(snapshot) ~= "table" then
    return "Invalid render settings snapshot: table expected"
  end

  local numeric_keys = normalize_key_list("numeric", opts)
  if not numeric_keys then numeric_keys = DEFAULT_NUMERIC_KEYS end
  local string_keys = normalize_key_list("string", opts)
  if not string_keys then string_keys = DEFAULT_STRING_KEYS end

  local lines = {
    "====== RENDER SETTINGS DUMP ======",
    "Legend:",
    "format = NAME = raw_value | mode=... | flags=... | note=...",
    "blank strings are shown as \"\"",
    "unknown or unrecognized values/flags are reported explicitly"
  }

  append_formatted_values(lines, "Render numeric settings", numeric_keys, snapshot.numeric)
  append_formatted_values(lines, "Render string settings", string_keys, snapshot.strings)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "====== END OF RENDER SETTINGS DUMP ======"

  return table.concat(lines, "\n")
end

function RenderSettings.build_console_dump(opts)
  local snapshot, err = RenderSettings.snapshot(opts)
  if not snapshot then
    return nil, err
  end
  return RenderSettings.format_snapshot(snapshot, opts), nil
end

function RenderSettings.show_console_dump(opts)
  if type(r.ShowConsoleMsg) ~= "function" then
    return false, "ReaScript function not found: ShowConsoleMsg"
  end
  local dump, err = RenderSettings.build_console_dump(opts)
  if not dump then
    return false, err
  end
  r.ShowConsoleMsg(dump)
  if dump:sub(-1) ~= "\n" then
    r.ShowConsoleMsg("\n")
  end
  return true, nil
end

RenderSettings._SPEC = {
  numeric = NUMERIC_SPECS,
  strings = STRING_SPECS,
  excluded = EXCLUDED_KEYS,
  default_numeric_key_set = DEFAULT_NUMERIC_KEY_SET,
  default_string_key_set = DEFAULT_STRING_KEY_SET
}

return RenderSettings
