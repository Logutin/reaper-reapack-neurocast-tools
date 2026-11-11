-- Contextual IPA contract: docs/2026-11-11_elevenlabs_pronunciation_context.md.
-- Pure UTF-8 matching and item snapshot state; REAPER read/Undo/write are injected.
-- No network, persistence, text logging or implicit project mutation.
local M = {}
local folded = { [0x152] = "œ", [0x153] = "œ", [0xC6] = "æ", [0xE6] = "æ" }
-- Canonical decompositions used in French/Portuguese (plus adjacent Latin vowels).
-- This is a scoped matcher, not a general-purpose Unicode normalization library.
for _, group in ipairs({
  {"Àà", "a\u{300}"}, {"Áá", "a\u{301}"}, {"Ââ", "a\u{302}"},
  {"Ãã", "a\u{303}"}, {"Ää", "a\u{308}"}, {"Åå", "a\u{30A}"},
  {"Çç", "c\u{327}"}, {"Èè", "e\u{300}"}, {"Éé", "e\u{301}"},
  {"Êê", "e\u{302}"}, {"Ëë", "e\u{308}"}, {"Ìì", "i\u{300}"},
  {"Íí", "i\u{301}"}, {"Îî", "i\u{302}"}, {"Ïï", "i\u{308}"},
  {"Ññ", "n\u{303}"}, {"Òò", "o\u{300}"}, {"Óó", "o\u{301}"},
  {"Ôô", "o\u{302}"}, {"Õõ", "o\u{303}"}, {"Öö", "o\u{308}"},
  {"Ùù", "u\u{300}"}, {"Úú", "u\u{301}"}, {"Ûû", "u\u{302}"},
  {"Üü", "u\u{308}"}, {"Ýý", "y\u{301}"}, {"Ÿÿ", "y\u{308}"}
}) do for _, cp in utf8.codes(group[1]) do folded[cp] = group[2] end end

local function combining(cp) return cp >= 0x300 and cp <= 0x36F end
local function canonical_class(cp) return (cp == 0x327 or cp == 0x328) and 202 or 230 end
local function normalize(text)
  local codes = {}
  for _, cp in utf8.codes(text) do
    if cp >= 65 and cp <= 90 then cp = cp + 32 end
    for _, part in utf8.codes(folded[cp] or utf8.char(cp)) do
      codes[#codes + 1] = part
      if combining(part) then
        local i = #codes
        while i > 1 and combining(codes[i-1]) and canonical_class(codes[i-1]) > canonical_class(part) do
          codes[i], codes[i-1] = codes[i-1], codes[i]; i = i - 1
        end
      end
    end
  end
  local out = {}; for i, cp in ipairs(codes) do out[i] = utf8.char(cp) end
  return table.concat(out)
end

local function word_core(cp)
  if cp < 128 then return cp >= 48 and cp <= 57 or cp >= 65 and cp <= 90 or cp >= 97 and cp <= 122 or cp == 95 end
  if cp < 0xC0 then return cp == 0xAA or cp == 0xB5 or cp == 0xBA end
  if cp == 0xD7 or cp == 0xF7 or cp == 0x1680 or cp == 0xFEFF then return false end
  if cp >= 0x2000 and cp <= 0x206F or cp >= 0x2E00 and cp <= 0x2E7F or
      cp >= 0x3000 and cp <= 0x303F or cp >= 0xFE10 and cp <= 0xFE6F or
      cp >= 0xFF00 and cp <= 0xFF65 or cp >= 0x1F000 and cp <= 0x1FAFF then return false end
  -- Conservatively keep adjacent non-Latin letters/marks inside a word too.
  return true
end
local function connector(cp)
  return cp == 0x27 or cp == 0x2018 or cp == 0x2019 or cp == 0x2D or cp == 0x2010 or cp == 0x2011 or cp == 0xAD
end

function M.find_spans(text, word)
  if type(text) ~= "string" or type(word) ~= "string" or not utf8.len(text) or not utf8.len(word) then return nil, "encoding" end
  word = word:match("^%s*(.-)%s*$")
  if word == "" then return {} end
  local wanted, units, spans = normalize(word), {}, {}
  for offset, cp in utf8.codes(text) do units[#units+1] = { offset=offset, cp=cp } end
  local i = 1
  while i <= #units do
    if word_core(units[i].cp) and not connector(units[i].cp) then
      local first, j = units[i].offset, i + 1
      while j <= #units do
        local cp = units[j].cp
        if connector(cp) then
          if j < #units and word_core(units[j+1].cp) and not connector(units[j+1].cp) then j=j+2 else break end
        elseif word_core(cp) then j=j+1 else break end
      end
      local last = units[j] and units[j].offset-1 or #text
      if normalize(text:sub(first,last)) == wanted then spans[#spans+1] = {first=first,last=last} end
      i = j
    else i = i + 1 end
  end
  return spans
end

function M.replace(text, spans, ipa)
  local out, offset = {}, 1
  for _, span in ipairs(spans) do
    out[#out+1] = text:sub(offset,span.first-1); out[#out+1] = ipa; offset=span.last+1
  end
  out[#out+1] = text:sub(offset)
  return table.concat(out)
end

local sample_fields = {"project", "item", "id", "text", "label", "reason"}
local function same(a,b)
  if not a or not b then return false end
  for _, key in ipairs(sample_fields) do if a[key] ~= b[key] then return false end end
  return true
end
local function same_target(a,b) return a and b and a.project==b.project and a.item==b.item and a.id==b.id end

function M.new(deps)
  local self = { revision=0, word="", reason="selection" }
  function self:reset()
    self.sample=nil; self.session=nil; self.error=nil; self.revision=self.revision+1
  end
  function self:sync(word)
    word=tostring(word or "")
    local ok, raw=pcall(deps.read)
    if not ok or type(raw)~="table" then raw={reason="read"} end
    local sample={}; for _,key in ipairs(sample_fields) do sample[key]=raw[key] end
    if not sample.reason and (type(sample.text)~="string" or not sample.item or not sample.id or not sample.project) then sample.reason="read" end
    if word==self.word and same(self.sample,sample) then return end
    self.revision=self.revision+1; self.error=nil
    local session=self.session
    if sample.reason or word~=self.word or not same_target(session,sample) or
        (sample.text~=session.expected and sample.text~=session.baseline) then session=nil end
    self.word=word; self.sample=sample; self.reason=sample.reason
    if not self.reason then
      if not session then
        session={project=sample.project,item=sample.item,id=sample.id,baseline=sample.text,expected=sample.text}
        session.spans, session.error=M.find_spans(sample.text,word)
      end
      if sample.text~=session.expected then session.applied_id=nil end
      session.expected=sample.text
      if session.error then self.reason=session.error
      elseif sample.text:match("^%s*$") and session.baseline:match("^%s*$") then self.reason="empty"
      elseif #session.spans==0 then self.reason="not_found" end
    end
    self.session=session
  end
  function self:preview(candidate)
    local contextual=not self.reason and self.session~=nil
    local sample=self.sample or {}
    local view={ revision=self.revision, candidate_id=candidate.id, ipa=candidate.ipa,
      project=sample.project,item=sample.item,id=sample.id,expected=sample.text,label=sample.label,
      reason=self.reason, count=contextual and #self.session.spans or 0,
      mode=contextual and "item" or (self.reason=="read" or self.reason=="encoding") and "error" or "word" }
    local inline_ipa="/" .. candidate.ipa .. "/"
    view.text=contextual and M.replace(self.session.baseline,self.session.spans,inline_ipa) or inline_ipa
    view.applied=contextual and sample.text==view.text
    return view
  end
  function self:is_current(view)
    if not view or view.revision~=self.revision then return false end
    local current=self:preview({id=view.candidate_id,ipa=view.ipa})
    return current.mode==view.mode and current.text==view.text and current.expected==view.expected and same_target(current,view)
  end
  function self:apply(view)
    self:sync(self.word)
    if not self:is_current(view) then self.error="stale";return false end
    if view.mode~="item" then self.error=view.reason or "selection";return false end
    if view.applied then self.error=nil;return true,"unchanged" end
    local ok, written, reason=pcall(deps.write,view,view.text)
    if not ok or not written then self:sync(self.word);self.error=reason or "write";return false end
    self.session.expected=view.text; self.session.applied_id=view.candidate_id
    self:sync(self.word)
    if not same_target(self.sample,view) or self.sample.text~=view.text then self.error="readback";return false end
    self.error=nil;return true
  end
  return self
end
return M
