-- Single-word pronunciation client contract: docs/2026-11-09_elevenlabs_pronunciation_ui.md.
-- Backend owns IPA normalization/ranking/cache. This module owns one in-flight
-- operation, context isolation and acknowledged personal feedback; no paid calls.
-- All dependencies are injected so lifecycle races can be tested without REAPER.
local M = {}
local locales = { ['fr-FR']=true, ['pt-BR']=true, ['pt-PT']=true }
local outcomes = { worked=true, did_not_work=true, unsure=true }
local sources = { espeak=true, wiktionary=true, gruut=true }
local statuses = { success=true, not_found=true, failed=true, not_applicable=true }
local function text(v, max)
  return type(v)=='string' and #v <= (max or 8192) and not v:find('[%z\1-\8\11\12\14-\31]') and utf8.len(v) ~= nil
end
local function nonempty(v, max) return text(v,max) and v ~= '' end
local function array(v, max, check)
  if type(v)~='table' or #v>(max or 512) then return false end
  local count=0
  for k,x in pairs(v) do
    if type(k)~='number' or k%1~=0 or k<1 or k>#v or not check(x) then return false end
    count=count+1
  end
  return count==#v
end
local function strings(v) return array(v,512,function(x)return text(x) end) end
local function scope(v,locale) return v==locale or (locale=='fr-FR' and v=='fr') end
local function candidate_id(v) return type(v)=='string' and #v==64 and v:match('^[a-f0-9]+$') ~= nil end
local function valid_feedback(v,model,voice)
  return type(v)=='table' and outcomes[v.outcome] and v.model_id==model and v.voice_id==voice and type(v.updatedAt)=='number'
end
local function valid_response(d, locale, model, voice)
  if type(d)~='table' or not nonempty(d.word) or d.locale~=locale or
    not nonempty(d.rankingVersion) or not nonempty(d.normalizationVersion) or type(d.cache)~='table' or
    type(d.cache.hit)~='boolean' or type(d.cache.complete)~='boolean' then return false end
  if not array(d.sources,3,function(s)
    return type(s)=='table' and sources[s.source] and statuses[s.status] and
      type(s.cached)=='boolean' and type(s.stale)=='boolean' and
      (s.warning==nil or text(s.warning)) and (s.nextRetryAt==nil or type(s.nextRetryAt)=='number') and
      (s.evidenceAt==nil or type(s.evidenceAt)=='number')
  end) or #d.sources~=3 then return false end
  local seen_sources={}
  for _,s in ipairs(d.sources) do if seen_sources[s.source] then return false end;seen_sources[s.source]=true end
  local seen={}
  return array(d.candidates,512,function(c)
    if type(c)~='table' or not candidate_id(c.id) or seen[c.id] or not nonempty(c.ipa) or
      type(c.rank)~='number' or c.rank<1 or c.rank%1~=0 or not scope(c.regionalScope,locale) or not strings(c.meanings) then return false end
    seen[c.id]=true
    if not array(c.reasons,32,function(r)return type(r)=='table' and nonempty(r.code) and text(r.message) end) then return false end
    if not array(c.evidence,512,function(e)
      if type(e)~='table' or not sources[e.source] or not nonempty(e.ipa) or not scope(e.regionalScope,locale) or
        not strings(e.meanings) or (e.labels~=nil and not strings(e.labels)) or
        (e.observedAt~=nil and type(e.observedAt)~='number') then return false end
      if e.attribution~=nil then
        local a=e.attribution
        if type(a)~='table' or not text(a.url) or not text(a.title) or not text(a.revision) or not text(a.license) then return false end
      end
      return true
    end) or #c.evidence==0 then return false end
    return c.feedback==nil or (model~='' and voice~='' and valid_feedback(c.feedback,model,voice))
  end) and #d.candidates>0
end

function M.new(deps)
  local self={ word='',locale='',model_id='',voice_id='',generation=0,serial=0,closed=false }
  local now=deps.now or os.clock
  local function fail(code,operation)
    self.error={code=code,operation=operation or 'lookup'}
    return false
  end
  local function clear_feedback()
    for _,c in ipairs(self.result and self.result.candidates or {}) do c.feedback=nil end
    self.feedback_ready=false
  end
  function self:set_input(word,locale)
    word,locale=tostring(word or ''),tostring(locale or '')
    if self.word==word and self.locale==locale then return end
    self.word,self.locale=word,locale
    self.generation=self.generation+1;self.result=nil;self.error=nil;self.notice=nil;self.retained=false;self.reload_context=false
    clear_feedback()
  end
  function self:set_context(model,voice)
    model,voice=tostring(model or ''),tostring(voice or '')
    if self.model_id==model and self.voice_id==voice then return end
    self.model_id,self.voice_id=model,voice;self.generation=self.generation+1
    self.notice=nil
    self.reload_context=self.result~=nil or (self.busy and self.busy.kind=='lookup') or false
    if self.error and self.error.operation=='feedback' then self.error=nil end
    clear_feedback()
  end
  function self:reset(abandon)
    self.generation=self.generation+1;self.result=nil;self.error=nil;self.notice=nil;self.retained=false;self.reload_context=false
    -- Terminal teardown can abandon callbacks; ordinary TTS reset preserves
    -- this controller's independent pronunciation job owner.
    if abandon then self.busy=nil end
    self.model_id='';self.voice_id='';clear_feedback()
  end
  function self:shutdown() self:reset(true);self.closed=true end
  function self:has_context() return nonempty(self.model_id,800) and nonempty(self.voice_id,800) end
  function self:find(id)
    for _,c in ipairs(self.result and self.result.candidates or {}) do if c.id==id then return c end end
  end
  function self:ipa(id) local c=self:find(id);return c and c.ipa end
  function self:clear_notice() self.notice=nil end
  function self:copy(id,copy)
    local ipa=self:ipa(id)
    if not ipa then return fail('response','copy') end
    local ok,value=pcall(copy,ipa)
    if not ok or value==false then return fail('clipboard','copy') end
    self.notice='copied';if self.error and self.error.operation=='copy' then self.error=nil end
    return true
  end
  local function decode(result)
    if type(result.body)~='string' or #result.body>2*1024*1024 then return nil end
    local ok,d=pcall(deps.decode,result.body);return ok and type(d)=='table' and d or nil
  end
  local function error_code(result,d)
    local status=tonumber(result.http_code) or 0
    if status==401 then return 'login' end
    if status==403 then return 'forbidden' end
    if status==400 then return 'validation' end
    local codes={PRONUNCIATION_NOT_FOUND='not_found',PRONUNCIATION_CANDIDATE_NOT_FOUND='candidate_missing',
      PRONUNCIATION_STORAGE_ERROR='storage',PRONUNCIATION_BUSY='busy',PRONUNCIATION_UNAVAILABLE='unavailable'}
    if d and codes[d.code] then return codes[d.code] end
    if status==404 then return 'unsupported' end
    return status==0 and 'transport' or 'unavailable'
  end
  local function start(kind,payload,id)
    if self.closed then return false end
    if self.busy then return fail('busy',kind) end
    if not deps.authenticated() then return fail('login',kind) end
    self.serial=self.serial+1
    local ticket={generation=self.generation,serial=self.serial,kind=kind,started_at=now(),candidate_id=id}
    self.busy=ticket;self.error=nil;self.notice=nil
    local rec={_state='running',_max_attempts=1}
    ticket.record=rec
    local function current() return not self.closed and self.generation==ticket.generation and self.busy==ticket end
    rec.is_current=current
    local function done(result)
      if self.busy~=ticket then return end
      local accepted=current();self.busy=nil
      if not accepted then rec._state='canceled';self:tick();return end
      local d=decode(result)
      if result.ok~=true or tonumber(result.http_code)~=200 then
        fail(error_code(result,d),kind);self.retained=self.result~=nil
        rec._state='failed_final';return
      end
      if kind=='lookup' then
        if not valid_response(d,payload.locale,payload.model_id or '',payload.voice_id or '') then
          fail('response',kind);self.retained=self.result~=nil;rec._state='failed_final';return
        end
        self.result=d;self.retained=false;self.feedback_ready=payload.model_id~=nil
      else
        local c=self:find(id)
        if not c or not valid_feedback(d,payload.model_id,payload.voice_id) or d.outcome~=payload.outcome then
          fail('response',kind);rec._state='failed_final';return
        end
        c.feedback=d;self.notice='saved'
      end
      self.error=nil;rec._state='ok'
    end
    local function send()
      if not current() then done({ok=false});return false end
      local built,req
      if kind=='lookup' then built,req=pcall(deps.build_lookup,payload)
      else built,req=pcall(deps.build_feedback,id,payload) end
      if not built or not req then done({ok=false});return false end
      local ok,job=pcall(deps.submit,req,done,rec)
      if not ok or not job then done({ok=false});return false end
      ticket.job=job;return true
    end
    rec._retry_submit=send
    return send()
  end
  function self:lookup(refresh)
    if not locales[self.locale] then return fail('locale') end
    local word=self.word:match('^%s*(.-)%s*$')
    local length=utf8.len(word)
    if not length or length<1 or length>128 or word:find('[%s%d%z\1-\31<>]') then return fail('word') end
    local payload={word=word,locale=self.locale,refresh=refresh==true}
    if self:has_context() then payload.model_id=self.model_id;payload.voice_id=self.voice_id end
    self.reload_context=false
    return start('lookup',payload)
  end
  function self:feedback(id,outcome)
    if not self:has_context() or not self.feedback_ready then return fail('context','feedback') end
    if not candidate_id(id) or not self:find(id) or not outcomes[outcome] then return fail('response','feedback') end
    return start('feedback',{outcome=outcome,model_id=self.model_id,voice_id=self.voice_id},id)
  end
  function self:tick()
    if self.closed or self.busy or not self.reload_context then return end
    self.reload_context=false;self:lookup(false)
  end
  function self:elapsed() return self.busy and math.max(0,now()-self.busy.started_at) or 0 end
  return self
end
return M
