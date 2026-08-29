local VoiceLibraryTaxonomy = require("modules-neurocast.elevenlabs_voice_library_taxonomy")

local VoiceCatalog = {}

local ORIGIN_ORDER = {
  "voice_library",
  "ivc",
  "voice_design",
  "professional_clone",
  "default",
  "unknown"
}

local ORIGIN_LABELS = {
  voice_library = "Voice Library",
  ivc = "IVC",
  voice_design = "Voice Design",
  professional_clone = "Professional Clone",
  default = "Default",
  unknown = "Unknown"
}

local KNOWN_LABEL_KEYS = {
  accent = true,
  age = true,
  cirilica_origin = true,
  description = true,
  descriptive = true,
  gender = true,
  language = true,
  locale = true,
  use = true,
  use_case = true
}

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalized_compare(value)
  return trim(value):lower()
end

local function nonempty(value)
  local text = trim(value)
  if text == "" then return nil end
  return text
end

local function voice_id_from_raw(raw)
  if type(raw) ~= "table" then return "" end
  return nonempty(raw.voice_id or raw.voiceId or raw.id) or ""
end

local function collect_verified_profiles(raw)
  local profiles = {}
  local source = type(raw) == "table" and raw.verified_languages or nil
  if type(source) ~= "table" then return profiles end

  local seen = {}
  for _, item in ipairs(source) do
    if type(item) == "table" then
      local profile = {
        language = nonempty(item.language),
        accent = nonempty(item.accent),
        locale = nonempty(item.locale),
        model_id = nonempty(item.model_id)
      }
      local key = table.concat({
        normalized_compare(profile.language),
        normalized_compare(profile.accent),
        normalized_compare(profile.locale),
        normalized_compare(profile.model_id)
      }, "\31")
      if not seen[key] then
        seen[key] = true
        profiles[#profiles + 1] = profile
      end
    end
  end
  return profiles
end

local function derive_unambiguous_locale(language, accent, profiles)
  local language_key = normalized_compare(language)
  local accent_key = normalized_compare(accent)
  local locales = {}
  local locale_count = 0

  for _, profile in ipairs(profiles or {}) do
    local locale = nonempty(profile.locale)
    local language_matches =
      language_key == "" or normalized_compare(profile.language) == language_key
    local accent_matches =
      accent_key == "" or normalized_compare(profile.accent) == accent_key
    if locale and language_matches and accent_matches then
      local locale_key = normalized_compare(locale)
      if not locales[locale_key] then
        locales[locale_key] = locale
        locale_count = locale_count + 1
      end
    end
  end

  if locale_count ~= 1 then return nil end
  for _, locale in pairs(locales) do
    return locale
  end
  return nil
end

local function collect_unique_values(values)
  local result = {}
  local seen = {}
  for _, value in ipairs(values or {}) do
    local text = nonempty(value)
    local key = normalized_compare(text)
    if text and not seen[key] then
      seen[key] = true
      result[#result + 1] = text
    end
  end
  table.sort(result, function(a, b)
    local a_key = normalized_compare(a)
    local b_key = normalized_compare(b)
    if a_key == b_key then return a < b end
    return a_key < b_key
  end)
  return result
end

local function collect_additional_labels(labels)
  local result = {}
  for key, value in pairs(labels or {}) do
    local key_text = nonempty(key)
    local value_text = nonempty(value)
    if key_text and value_text and not KNOWN_LABEL_KEYS[normalized_compare(key_text)] then
      result[#result + 1] = { key = key_text, value = value_text }
    end
  end
  table.sort(result, function(a, b)
    local a_key = normalized_compare(a.key)
    local b_key = normalized_compare(b.key)
    if a_key == b_key then return tostring(a.key) < tostring(b.key) end
    return a_key < b_key
  end)
  return result
end

local function classify_origin(raw)
  if type(raw.sharing) == "table" and raw.is_owner ~= true then
    return "voice_library"
  end
  local category = normalized_compare(raw.category)
  if category == "cloned" then return "ivc" end
  if category == "generated" then return "voice_design" end
  if category == "premade" then return "default" end
  if category == "professional" and raw.is_owner == true then
    return "professional_clone"
  end
  return "unknown"
end

local function append_search_value(parts, value)
  local text = nonempty(value)
  if text then parts[#parts + 1] = text end
end

local function language_accent_pair(language, accent)
  local pair = {
    language = nonempty(language),
    accent = nonempty(accent)
  }
  local canonical, match_kind =
    VoiceLibraryTaxonomy.resolve_accent(pair.language, pair.accent)
  pair.filter_accent = canonical and canonical.value or pair.accent
  pair.canonical_accent_label = canonical and canonical.label or nil
  pair.accent_match_kind = match_kind
  return pair
end

local function build_search_text(raw, voice)
  local parts = {}
  append_search_value(parts, voice.name)
  append_search_value(parts, ORIGIN_LABELS[voice.origin_code])
  append_search_value(parts, voice.category)
  append_search_value(parts, voice.description)
  for key, value in pairs(type(raw.labels) == "table" and raw.labels or {}) do
    append_search_value(parts, key)
    append_search_value(parts, value)
  end
  for _, profile in ipairs(voice.verified_profiles or {}) do
    append_search_value(parts, profile.language)
    append_search_value(parts, profile.accent)
    append_search_value(parts, profile.locale)
    append_search_value(parts, profile.model_id)
  end
  for _, pair in ipairs(voice.language_accent_pairs or {}) do
    append_search_value(parts, pair.canonical_accent_label)
  end
  return table.concat(parts, "\n")
end

local function normalize_voice(raw)
  local labels = type(raw.labels) == "table" and raw.labels or {}
  local profiles = collect_verified_profiles(raw)
  local language = nonempty(labels.language)
  local accent = nonempty(labels.accent)
  local voice_id = voice_id_from_raw(raw)
  local name = nonempty(raw.name) or ""
  local languages = { language }
  local accents = { accent }
  local locales = { nonempty(labels.locale) }
  local language_accent_pairs = {}
  if language or accent then
    language_accent_pairs[#language_accent_pairs + 1] =
      language_accent_pair(language, accent)
  end
  for _, profile in ipairs(profiles) do
    languages[#languages + 1] = profile.language
    accents[#accents + 1] = profile.accent
    locales[#locales + 1] = profile.locale
    if profile.language or profile.accent then
      language_accent_pairs[#language_accent_pairs + 1] =
        language_accent_pair(profile.language, profile.accent)
    end
  end

  local voice = {
    id = voice_id,
    name = name,
    accent = accent,
    language = language,
    locale = derive_unambiguous_locale(language, accent, profiles),
    category = nonempty(raw.category),
    description = nonempty(raw.description),
    gender = nonempty(labels.gender),
    age = nonempty(labels.age),
    use_case = nonempty(labels.use_case or labels.use),
    descriptive = nonempty(labels.descriptive or labels.description),
    created_at_unix = tonumber(raw.created_at_unix),
    origin_code = classify_origin(raw),
    verified_profiles = profiles,
    languages = collect_unique_values(languages),
    accents = collect_unique_values(accents),
    locales = collect_unique_values(locales),
    language_accent_pairs = language_accent_pairs,
    additional_labels = collect_additional_labels(labels),
    raw = raw,
    display_label = name ~= "" and name or ("[" .. voice_id .. "]")
  }
  voice.search_text = build_search_text(raw, voice)
  return voice
end

local function metadata_value(voice, key)
  return nonempty(voice and voice[key])
end

local function metadata_signature(voice, keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = normalized_compare(metadata_value(voice, key))
  end
  return table.concat(parts, "\31")
end

local function display_metadata(voice, keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local value = metadata_value(voice, key)
    if value then parts[#parts + 1] = value end
  end
  return table.concat(parts, ", ")
end

local function assign_duplicate_labels(group)
  local keys_in_order = { "accent", "locale", "language", "category" }
  local active_keys = {}
  local signatures = {}

  for _, key in ipairs(keys_in_order) do
    active_keys[#active_keys + 1] = key
    signatures = {}
    local all_unique = true
    for _, voice in ipairs(group) do
      local signature = metadata_signature(voice, active_keys)
      if signatures[signature] then all_unique = false end
      signatures[signature] = true
    end
    if all_unique then break end
  end

  local collision_counts = {}
  for _, voice in ipairs(group) do
    local signature = metadata_signature(voice, active_keys)
    collision_counts[signature] = (collision_counts[signature] or 0) + 1
  end

  for _, voice in ipairs(group) do
    local metadata = display_metadata(voice, active_keys)
    local label = voice.name
    if metadata ~= "" then label = label .. " (" .. metadata .. ")" end
    local signature = metadata_signature(voice, active_keys)
    if metadata == "" or (collision_counts[signature] or 0) > 1 then
      label = label .. " [" .. voice.id .. "]"
    end
    voice.display_label = label
  end
end

local function sort_group(group)
  table.sort(group, function(a, b)
    local a_label = normalized_compare(a.display_label)
    local b_label = normalized_compare(b.display_label)
    if a_label == b_label then return tostring(a.id or "") < tostring(b.id or "") end
    return a_label < b_label
  end)
end

local function new_option_accumulator()
  return { values = {}, seen = {} }
end

local function add_option(accumulator, value)
  local text = nonempty(value)
  local key = normalized_compare(text)
  if text and not accumulator.seen[key] then
    accumulator.seen[key] = true
    accumulator.values[#accumulator.values + 1] = text
  end
end

local function finish_options(accumulator)
  table.sort(accumulator.values, function(a, b)
    local a_key = normalized_compare(a)
    local b_key = normalized_compare(b)
    if a_key == b_key then return a < b end
    return a_key < b_key
  end)
  return accumulator.values
end

local function build_facets(voices)
  local origin_presence = {}
  local languages = new_option_accumulator()
  local genders = new_option_accumulator()
  local ages = new_option_accumulator()
  local use_cases = new_option_accumulator()
  local accents_by_language_acc = {}

  local function language_accumulator(language)
    local key = normalized_compare(language)
    if key == "" then return nil end
    if not accents_by_language_acc[key] then
      accents_by_language_acc[key] = new_option_accumulator()
    end
    return accents_by_language_acc[key]
  end

  for _, voice in ipairs(voices or {}) do
    origin_presence[voice.origin_code or "unknown"] = true
    for _, language in ipairs(voice.languages or {}) do add_option(languages, language) end
    add_option(genders, voice.gender)
    add_option(ages, voice.age)
    add_option(use_cases, voice.use_case)
    for _, pair in ipairs(voice.language_accent_pairs or {}) do
      local accumulator = language_accumulator(pair.language)
      if accumulator then add_option(accumulator, pair.filter_accent or pair.accent) end
    end
  end

  local origins = {}
  for _, code in ipairs(ORIGIN_ORDER) do
    if origin_presence[code] then origins[#origins + 1] = code end
  end
  local accents_by_language = {}
  for key, accumulator in pairs(accents_by_language_acc) do
    accents_by_language[key] = finish_options(accumulator)
  end
  return {
    origins = origins,
    languages = finish_options(languages),
    accents_by_language = accents_by_language,
    genders = finish_options(genders),
    ages = finish_options(ages),
    use_cases = finish_options(use_cases)
  }
end

local function contains_normalized(values, expected)
  local expected_key = normalized_compare(expected)
  if expected_key == "" then return true end
  for _, value in ipairs(values or {}) do
    if normalized_compare(value) == expected_key then return true end
  end
  return false
end

local function matches_language_accent(voice, language, accent)
  local language_key = normalized_compare(language)
  local accent_key = normalized_compare(accent)
  if language_key == "" then return accent_key == "" end
  if accent_key == "" then return contains_normalized(voice.languages, language) end
  for _, pair in ipairs(voice.language_accent_pairs or {}) do
    if normalized_compare(pair.language) == language_key and
       normalized_compare(pair.filter_accent or pair.accent) == accent_key then
      return true
    end
  end
  return false
end

function VoiceCatalog.trim_name(value)
  return trim(value)
end

function VoiceCatalog.origin_label(origin_code)
  return ORIGIN_LABELS[tostring(origin_code or "")] or ORIGIN_LABELS.unknown
end

function VoiceCatalog.with_cirilica_origin(labels, origin)
  local merged = {}
  if type(labels) == "table" then
    for key, value in pairs(labels) do merged[key] = value end
  end
  merged.cirilica_origin = tostring(origin or "")
  return merged
end

function VoiceCatalog.empty_filters()
  return {
    origin = nil,
    language = nil,
    accent = nil,
    gender = nil,
    age = nil,
    use_case = nil
  }
end

function VoiceCatalog.has_active_filters(filters)
  if type(filters) ~= "table" then return false end
  for _, key in ipairs({ "origin", "language", "accent", "gender", "age", "use_case" }) do
    if nonempty(filters[key]) then return true end
  end
  return false
end

function VoiceCatalog.matches_filters(voice, filters)
  if type(voice) ~= "table" then return false end
  filters = type(filters) == "table" and filters or {}
  if nonempty(filters.origin) and tostring(voice.origin_code or "unknown") ~= filters.origin then
    return false
  end
  if not matches_language_accent(voice, filters.language, filters.accent) then return false end
  if nonempty(filters.gender) and normalized_compare(voice.gender) ~= normalized_compare(filters.gender) then
    return false
  end
  if nonempty(filters.age) and normalized_compare(voice.age) ~= normalized_compare(filters.age) then
    return false
  end
  if nonempty(filters.use_case) and normalized_compare(voice.use_case) ~= normalized_compare(filters.use_case) then
    return false
  end
  return true
end

function VoiceCatalog.reconcile_filters(catalog, filters)
  local result = VoiceCatalog.empty_filters()
  filters = type(filters) == "table" and filters or {}
  local facets = type(catalog) == "table" and catalog.facets or nil
  if type(facets) ~= "table" then return result end

  if contains_normalized(facets.origins, filters.origin) then
    for _, value in ipairs(facets.origins) do
      if normalized_compare(value) == normalized_compare(filters.origin) then result.origin = value end
    end
  end
  for _, spec in ipairs({
    { key = "language", options = facets.languages },
    { key = "gender", options = facets.genders },
    { key = "age", options = facets.ages },
    { key = "use_case", options = facets.use_cases }
  }) do
    if contains_normalized(spec.options, filters[spec.key]) then
      for _, value in ipairs(spec.options or {}) do
        if normalized_compare(value) == normalized_compare(filters[spec.key]) then
          result[spec.key] = value
          break
        end
      end
    end
  end
  if result.language then
    local accents = facets.accents_by_language[normalized_compare(result.language)] or {}
    if contains_normalized(accents, filters.accent) then
      for _, value in ipairs(accents) do
        if normalized_compare(value) == normalized_compare(filters.accent) then
          result.accent = value
          break
        end
      end
    end
  end
  return result
end

function VoiceCatalog.build(raw_voices)
  local catalog = {
    voices = {},
    by_id = {},
    by_name = {},
    count = 0,
    duplicate_name_count = 0,
    duplicate_voice_count = 0,
    facets = build_facets({})
  }

  if type(raw_voices) ~= "table" then return catalog end

  for _, raw in ipairs(raw_voices) do
    if type(raw) == "table" then
      local voice = normalize_voice(raw)
      if voice.id ~= "" and not catalog.by_id[voice.id] then
        catalog.voices[#catalog.voices + 1] = voice
        catalog.by_id[voice.id] = voice
        if voice.name ~= "" then
          local group = catalog.by_name[voice.name]
          if not group then group = {}; catalog.by_name[voice.name] = group end
          group[#group + 1] = voice
        end
      end
    end
  end

  catalog.count = #catalog.voices
  catalog.facets = build_facets(catalog.voices)
  for _, group in pairs(catalog.by_name) do
    if #group > 1 then
      catalog.duplicate_name_count = catalog.duplicate_name_count + 1
      catalog.duplicate_voice_count = catalog.duplicate_voice_count + #group
      assign_duplicate_labels(group)
    end
    sort_group(group)
  end
  return catalog
end

function VoiceCatalog.name_exists_exact(catalog, proposed_name)
  local needle = trim(proposed_name)
  if needle == "" or type(catalog) ~= "table" then return false end
  for _, voice in ipairs(catalog.voices or {}) do
    if trim(voice.name) == needle then return true end
  end
  return false
end

function VoiceCatalog.resolve_name(catalog, track_name, preferred_voice_id)
  local group =
    type(catalog) == "table" and
    type(catalog.by_name) == "table" and
    catalog.by_name[tostring(track_name or "")] or
    nil
  if type(group) ~= "table" or #group == 0 then
    return { status = "missing", track_name = tostring(track_name or ""), candidates = {}, selected_voice_id = nil }
  end
  if #group == 1 then
    return { status = "unique", track_name = tostring(track_name or ""), candidates = group, selected_voice_id = group[1].id }
  end

  local selected_id = nil
  local preferred = tostring(preferred_voice_id or "")
  if preferred ~= "" then
    for _, voice in ipairs(group) do
      if voice.id == preferred then selected_id = preferred; break end
    end
  end
  if not selected_id then selected_id = group[1].id end
  return { status = "ambiguous", track_name = tostring(track_name or ""), candidates = group, selected_voice_id = selected_id }
end

return VoiceCatalog
