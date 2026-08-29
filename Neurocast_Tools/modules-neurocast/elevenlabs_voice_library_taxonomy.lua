-- Source-dated, runtime-independent Voice Library filter taxonomy.
-- Snapshot: 2026-07-31. Schema version: 1.
-- Provenance: approved 2026-07-29 UI plan, reviewed ElevenLabs Voice Library
-- frontend filter assets, the official GET /v1/shared-voices endpoint, and a
-- credential-safe live query-value audit completed on 2026-07-31.
-- This module performs no I/O.

local Taxonomy = {
  SCHEMA_VERSION = 1,
  SNAPSHOT_VERSION = "2026-07-31-v3",
  SOURCE_DATE = "2026-07-31",
  SOURCE = "Approved UI plan, ElevenLabs frontend filter assets, official API reference, and 2026-07-31 live query-value audit",
  languages = {},
  languages_by_value = {},
  accents_by_language = {},
  accents_by_code = {},
  genders = {
    { label = "Any", value = nil },
    { label = "Male", value = "male" },
    { label = "Female", value = "female" },
    { label = "Neutral", value = "neutral" }
  },
  ages = {
    { label = "Any", value = nil },
    { label = "Young", value = "young" },
    { label = "Middle Aged", value = "middle_aged" },
    { label = "Old", value = "old" }
  },
  categories = {
    { label = "Any", value = nil },
    { label = "Professional", value = "professional" },
    { label = "Famous", value = "famous" },
    { label = "Studio Quality", value = "high_quality" }
  }
}

local function fields(line)
  local out = {}
  for value in tostring(line or ""):gmatch("([^|]*)|?") do
    out[#out + 1] = value
    if #out == 4 then break end
  end
  return out
end

local function normalized(value)
  return tostring(value or ""):match("^%s*(.-)%s*$"):lower()
end

local function separator_key(value)
  local key = normalized(value):gsub("[%s_%-]+", " ")
  return key:match("^%s*(.-)%s*$")
end

local accent_exact_by_language = {}
local accent_separator_by_language = {}

local language_rows = [[
en|English|US
zh|Chinese|CN
es|Spanish|ES
hi|Hindi|IN
pt|Portuguese|PT
fr|French|FR
de|German|DE
ja|Japanese|JP
ar|Arabic|AE
ru|Russian|RU
ko|Korean|KR
id|Indonesian|ID
it|Italian|IT
nl|Dutch|NL
tr|Turkish|TR
pl|Polish|PL
sv|Swedish|SE
fil|Filipino|PH
ms|Malay|MY
ro|Romanian|RO
uk|Ukrainian|UA
el|Greek|GR
cs|Czech|CZ
da|Danish|DK
fi|Finnish|FI
bg|Bulgarian|BG
hr|Croatian|HR
sk|Slovak|SK
ta|Tamil|IN
hu|Hungarian|HU
no|Norwegian|NO
vi|Vietnamese|VN
af|Afrikaans|ZA
hy|Armenian|AM
as|Assamese|IN
ast|Asturian|ES
az|Azerbaijani|AZ
be|Belarusian|BY
bn|Bengali|IN
bs|Bosnian|BA
yue|Cantonese|HK
ca|Catalan|ES-CT
ceb|Cebuano|PH
ny|Chichewa|MW
et|Estonian|EE
gl|Galician|ES-GA
ka|Georgian|GE
gu|Gujarati|IN
ha|Hausa|NG
he|Hebrew|IL
is|Icelandic|IS
ga|Irish|IE
jv|Javanese|ID
kn|Kannada|IN
kk|Kazakh|KZ
ky|Kirghiz|KG
lv|Latvian|LV
ln|Lingala|CD
lt|Lithuanian|LT
lb|Luxembourgish|LU
mk|Macedonian|MK
ml|Malayalam|IN
mt|Maltese|MT
mi|Maori|NZ
mn|Mongolian|MN
mr|Marathi|IN
my|Burmese|MM
ne|Nepali|NP
oc|Occitan|FR
or|Odia|IN
ps|Pashto|AF
fa|Persian|IR
pa|Punjabi|IN
sr|Serbian|RS
sd|Sindhi|IN
sl|Slovenian|SI
so|Somali|SO
sw|Swahili|KE
tg|Tajik|TJ
te|Telugu|IN
th|Thai|TH
ur|Urdu|PK
uz|Uzbek|UZ
yo|Yoruba|NG
cy|Welsh|GB-WLS
ak|Akan|GH
sq|Albanian|AL
am|Amharic|ET
ay|Aymara|BO
bm|Bambara|ML
eu|Basque|ES
bho|Bhojpuri|IN
br|Breton|FR
co|Corsican|FR
eo|Esperanto|
ee|Ewe|GH
fy|Frisian|NL
gn|Guarani|PY
ht|Haitian Creole|HT
haw|Hawaiian|US
hmn|Hmong|
ig|Igbo|NG
rw|Kinyarwanda|RW
ku|Kurdish|
lo|Lao|LA
la|Latin|
st|Sesotho|LS
]]

for line in language_rows:gmatch("[^\r\n]+") do
  local row = fields(line)
  local language = {
    value = row[1],
    label = row[2],
    flag_code = row[3] ~= "" and row[3] or nil
  }
  Taxonomy.languages[#Taxonomy.languages + 1] = language
  Taxonomy.languages_by_value[language.value] = language
  Taxonomy.accents_by_language[language.value] = {}
end

table.sort(Taxonomy.languages, function(left, right)
  return left.label:lower() < right.label:lower()
end)

local accent_rows = [[
ar|Modern Standard|modern standard|1
ar|Egyptian|egyptian|2
ar|Gulf|gulf|3
ar|Levantine|levantine|4
ar|Bahraini|bahraini|5
ar|Kuwaiti|kuwaiti|6
ar|Omani|omani|7
ar|Qatari|qatari|8
ar|Saudi|saudi|9
ar|Iraqi|iraqi|10
ar|Jordanian|jordanian|11
ar|Palestinian|palestinian|12
ar|Syrian|syrian|13
ar|Algerian|algerian|14
ar|Moroccan|moroccan|15
ar|Tunisian|tunisian|16
ar|Libyan|libyan|17
ar|Sudanese|sudanese|18
bg|Bansko|bansko|1
bg|Rhodopean|rhodopean|2
bg|Ruse|ruse|3
bg|Sofia|sofia|4
bg|Standard|standard|5
bg|Varna|varna|6
cs|Moravian|moravian|1
cs|Prague|prague|2
cs|Silesian|silesian|3
cs|Standard|standard|4
da|Copenhagen|copenhagen|1
da|Jutlandic|jutlandic|2
da|Standard|standard|3
da|Zealandic|zealandic|4
de|Bavarian|bavarian|1
de|Berlinerisch|berlinerisch|2
de|Rhine Franconian|rhine franconian|3
de|Saxon|saxon|4
de|Standard|standard|5
de|Swabian|swabian|6
el|Aegean|aegean|1
el|Athenian|athenian|2
el|Cretan|cretan|3
el|Cypriot|cypriot|4
el|Macedonian|macedonian|5
el|Pontic|pontic|6
el|Standard|standard|7
en|American|american|1
en|Australian|australian|2
en|British|british|3
en|Canadian|canadian|4
en|Indian|indian|5
en|Irish|irish|6
en|Jamaican|jamaican|7
en|New Zealand|new zealand|8
en|Nigerian|nigerian|9
en|Scottish|scottish|10
en|South African|south african|11
en|African American|african american|12
en|Singaporean|singaporean|13
en|US - Boston|boston|14
en|US - Chicago|chicago|15
en|US - New York|new york|16
en|US - Southern|us southern|17
en|US - Midwest|us midwest|18
en|US - Northeast|us northeast|19
en|Cockney|cockney|20
en|Geordie|geordie|21
en|Received Pronunciation|received pronunciation|22
en|Scouse|scouse|23
en|Welsh|welsh|24
en|Yorkshire|yorkshire|25
en|Arabic|arabic|26
en|Bulgarian|bulgarian|27
en|Chinese|chinese|28
en|Croatian|croatian|29
en|Czech|czech|30
en|Danish|danish|31
en|Dutch|dutch|32
en|Filipino|filipino|33
en|Finnish|finnish|34
en|French|french|35
en|German|german|36
en|Greek|greek|37
en|Hindi|hindi|38
en|Indonesian|indonesian|39
en|Italian|italian|40
en|Japanese|japanese|41
en|Korean|korean|42
en|Malay|malay|43
en|Polish|polish|44
en|Portuguese|portuguese|45
en|Romanian|romanian|46
en|Russian|russian|47
en|Slovak|slovak|48
en|Spanish|spanish|49
en|Swedish|swedish|50
en|Tamil|tamil|51
en|Turkish|turkish|52
en|Ukrainian|ukrainian|53
es|Latin American|latin american|1
es|Peninsular|peninsular|2
es|Andalusian|andalusian|3
es|Argentine|argentine|4
es|Basque|basque|5
es|Canary Islands|canary islands|6
es|Caribbean|caribbean|7
es|Chilean|chilean|8
es|Colombian|colombian|9
es|Cuban|cuban|10
es|Dominican|dominican|11
es|Ecuadorian|ecuadorian|12
es|Galician|galician|13
es|Mexican|mexican|14
es|Peruvian|peruvian|15
es|Puerto Rican|puerto rican|16
es|Venezuelan|venezuelan|17
fi|Eastern|eastern|1
fi|Helsinki|helsinki|2
fi|Standard|standard|3
fi|Tampere|tampere|4
fi|Turku|turku|5
fi|Western|western|6
fil|Cebuano|cebuano|1
fil|Ilocano|ilocano|2
fil|Standard|standard|3
fr|Acadian|acadian|1
fr|African|african|2
fr|Belgian|belgian|3
fr|Cajun|cajun|4
fr|Creole|creole|5
fr|Meridional|meridional|6
fr|Parisian|parisian|7
fr|Quebec|quebec|8
fr|Standard|standard|9
fr|Swiss|swiss|10
hi|Awadhi|awadhi|1
hi|Bengali|bengali|2
hi|Bhojpuri|bhojpuri|3
hi|Bihari|bihari|4
hi|Chhattisgarhi|chhattisgarhi|5
hi|Gujarati|gujarati|6
hi|Haryanvi|haryanvi|7
hi|Khariboli|khariboli|8
hi|Malvi|malvi|9
hi|Marathi|marathi|10
hi|Marwadi|marwadi|11
hi|Punjabi|punjabi|12
hi|Rajasthani|rajasthani|13
hi|Standard|standard|14
hi|Tamil|tamil|15
hi|Telugu|telugu|16
hr|Dubrovnik|dubrovnik|1
hr|Istrian|istrian|2
hr|Standard|standard|3
hr|Zagreb|zagreb|4
id|Balinese|balinese|1
id|Javanese|javanese|2
id|Standard|standard|3
id|Sundanese|sundanese|4
it|Calabrese|calabrese|1
it|Florentine|florentine|2
it|Genoese|genoese|3
it|Milanese|milanese|4
it|Neapolitan|neapolitan|5
it|Romanesco|romanesco|6
it|Sicilian|sicilian|7
it|Standard|standard|8
it|Ticinese|ticinese|9
it|Tuscan|tuscan|10
it|Venetian|venetian|11
ja|Kansai|kansai|1
ja|Kanto|kanto|2
ja|Kyushu|kyushu|3
ja|Okinawa|okinawa|4
ja|Standard|standard|5
ja|Tohoku|tohoku|6
ko|Chungcheong|chungcheong|1
ko|Gyeongsang|gyeongsang|2
ko|Hamgyong|hamgyong|3
ko|Jeolla|jeolla|4
ko|Seoul|seoul|5
ko|Standard|standard|6
ms|Brunei|brunei|1
ms|Indonesian|indonesian|2
ms|Kelantanese|kelantanese|3
ms|Malaysian|malaysian|4
ms|Singaporean|singaporean|5
ms|Standard|standard|6
nl|Brabantian|brabantian|1
nl|Flemish|flemish|2
nl|Gronings|gronings|3
nl|Limburgish|limburgish|4
nl|Standard|standard|5
pl|Kashubian|kashubian|1
pl|Mazovian|mazovian|2
pl|Podhale|podhale|3
pl|Silesian|silesian|4
pl|Standard|standard|5
pt|Brazilian|brazilian|1
pt|European|european|2
pt|African|african|3
pt|Azorean|azorean|4
pt|Creole|creole|5
pt|Galician|galician|6
pt|Madeiran|madeiran|7
ro|Banat|banat|1
ro|Bucovina|bucovina|2
ro|Maramures|maramures|3
ro|Moldovan|moldovan|4
ro|Oltenia|oltenia|5
ro|Standard|standard|6
ro|Transylvanian|transylvanian|7
ru|Moscow|moscow|1
ru|Saint Petersburg|saint petersburg|2
ru|Standard|standard|3
sk|Central|central|1
sk|Eastern|eastern|2
sk|Standard|standard|3
sk|Western|western|4
sv|Gothenburg|gothenburg|1
sv|Gotland|gotland|2
sv|Norrland|norrland|3
sv|Scanian|scanian|4
sv|Standard|standard|5
sv|Stockholm|stockholm|6
ta|Chennai|chennai|1
ta|Coimbatore|coimbatore|2
ta|Madurai|madurai|3
ta|Salem|salem|4
ta|Standard|standard|5
ta|Thanjavur|thanjavur|6
ta|Tirunelveli|tirunelveli|7
tr|Aegean|aegean|1
tr|Anatolian|anatolian|2
tr|Black Sea|black sea|3
tr|Central|central|4
tr|Eastern|eastern|5
tr|Istanbul|istanbul|6
tr|Southeastern|southeastern|7
tr|Standard|standard|8
uk|Kyiv|kiev|1
uk|Standard|standard|2
zh|Cantonese (Guangzhou)|guangzhou cantonese|1
zh|Cantonese (Hong Kong)|hong kong cantonese|2
zh|Cantonese (Singapore)|singapore cantonese|3
zh|Mandarin (Beijing)|beijing mandarin|4
zh|Mandarin (Singapore)|singapore mandarin|5
zh|Mandarin (Taiwan)|taiwan mandarin|6
zh|Standard|standard|7
hu|Standard|standard|1
hu|Budapest|budapest|2
hu|Eastern|eastern|3
hu|Western|western|4
hu|Northern|northern|5
hu|Southern|southern|6
vi|Standard|standard|1
vi|Northern|northern|2
vi|Central|central|3
vi|Southern|southern|4
no|Standard|standard|1
no|Oslo|oslo|2
no|Bergen|bergen|3
no|Trøndersk|trøndersk|4
no|Northern|northern|5
no|Sørlandsk|sørlandsk|6
]]

for line in accent_rows:gmatch("[^\r\n]+") do
  local row = fields(line)
  local language = row[1]
  local suffix = row[3]
  local accent = {
    language = language,
    label = row[2],
    value = suffix,
    code = language .. "-" .. suffix,
    sort = tonumber(row[4]) or 0
  }
  local list = Taxonomy.accents_by_language[language]
  if list then
    list[#list + 1] = accent
    Taxonomy.accents_by_code[accent.code] = accent
    accent_exact_by_language[language] = accent_exact_by_language[language] or {}
    accent_exact_by_language[language][normalized(accent.value)] = accent
    accent_separator_by_language[language] = accent_separator_by_language[language] or {}
    local key = separator_key(accent.value)
    local matches = accent_separator_by_language[language][key]
    if not matches then
      matches = {}
      accent_separator_by_language[language][key] = matches
    end
    matches[#matches + 1] = accent
  end
end

for _, list in pairs(Taxonomy.accents_by_language) do
  table.sort(list, function(left, right)
    if left.sort ~= right.sort then return left.sort < right.sort end
    return left.label:lower() < right.label:lower()
  end)
end

function Taxonomy.accents_for(language)
  return Taxonomy.accents_by_language[tostring(language or "")] or {}
end

function Taxonomy.resolve_accent(language, raw_accent)
  local language_key = normalized(language)
  local raw_key = normalized(raw_accent)
  if language_key == "" or raw_key == "" then return nil, nil end

  local exact = accent_exact_by_language[language_key] or {}
  if exact[raw_key] then return exact[raw_key], "exact" end

  local candidate = raw_key
  local prefix = language_key .. "-"
  if candidate:sub(1, #prefix) == prefix and #candidate > #prefix then
    candidate = candidate:sub(#prefix + 1)
    if exact[candidate] then return exact[candidate], "language_prefix" end
  end

  local separator_matches =
    (accent_separator_by_language[language_key] or {})[separator_key(candidate)] or {}
  if #separator_matches == 1 then
    return separator_matches[1], "separator"
  end
  return nil, nil
end

function Taxonomy.validate()
  local errors = {}
  local language_count = 0
  local accent_count = 0
  local seen_language = {}
  local seen_accent = {}
  local previous_language_label = nil
  for _, language in ipairs(Taxonomy.languages) do
    language_count = language_count + 1
    if language.value == "" or language.label == "" then
      errors[#errors + 1] = "language has an empty value or label"
    elseif seen_language[language.value] then
      errors[#errors + 1] = "duplicate language: " .. language.value
    end
    if previous_language_label and
       previous_language_label:lower() > language.label:lower() then
      errors[#errors + 1] = "language order is unstable at: " .. language.value
    end
    previous_language_label = language.label
    seen_language[language.value] = true
  end
  for language, list in pairs(Taxonomy.accents_by_language) do
    if not seen_language[language] then
      errors[#errors + 1] = "accent language is missing: " .. language
    end
    local prior_sort = -1
    for _, accent in ipairs(list) do
      accent_count = accent_count + 1
      if accent.label ~= accent.label:match("^%s*(.-)%s*$") or
         accent.value ~= accent.value:match("^%s*(.-)%s*$") then
        errors[#errors + 1] = "accent has edge whitespace: " .. accent.code
      end
      if seen_accent[accent.code] then
        errors[#errors + 1] = "duplicate accent: " .. accent.code
      end
      if accent.code ~= language .. "-" .. accent.value then
        errors[#errors + 1] = "invalid accent code: " .. accent.code
      end
      if accent.sort < prior_sort then
        errors[#errors + 1] = "accent order is unstable for: " .. language
      end
      prior_sort = accent.sort
      seen_accent[accent.code] = true
    end
    for key, matches in pairs(accent_separator_by_language[language] or {}) do
      if #matches ~= 1 then
        errors[#errors + 1] =
          "ambiguous accent separator key: " .. language .. "/" .. key
      end
    end
  end
  if language_count ~= 107 then
    errors[#errors + 1] = "expected 107 languages, got " .. tostring(language_count)
  end
  if accent_count ~= 264 then
    errors[#errors + 1] = "expected 264 accents, got " .. tostring(accent_count)
  end
  return #errors == 0, errors, {
    language_count = language_count,
    accent_count = accent_count
  }
end

return Taxonomy
