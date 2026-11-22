-- streamer.lua - bridges a player to Love2D's audio output via a
-- QueueableSource and a small ring of pre-allocated SoundData buffers.
--
-- Why a ring of buffers and not one big SoundData: QueueableSource plays
-- each queued buffer in turn; while one is playing you queue the next.
-- Allocating SoundData per frame is expensive (it zero-inits and registers
-- with the audio device). Pre-allocating N (default 4) and cycling them
-- means zero allocation on the hot path - the same trick Love2D games use
-- for microphone input and procedural audio.
--
-- v2.0: FFI is now OPTIONAL. On desktop (LuaJIT) the fast path is used:
-- player:fill_into(int16_buf, frames) + ffi.copy of the raw bytes into the
-- SoundData's pointer (a single memcpy). On love.js / web (no FFI) we fall
-- back to player:fillFloats(lua_table, frames) + SoundData:setSample() per
-- sample. The pure-Lua sid_pure_player exposes fillFloats for exactly this.

local have_ffi, ffi = pcall(require, "ffi")

local M = {}
M.__index = M

-- opts:
--   player     -> a Player instance (sid/chiptune/midi)
--   mixers     -> optional list of mixer objects with :mix_into(out, frames)
--                 (e.g. a sidlove.Sample); each runs after the player fill so
--                 digi samples layer on top of the tune. A mixer with
--                 enabled == false is skipped that frame.
--   bufferFrames -> frames per SoundData (default 2048, ~46ms at 44.1k)
--   bufferCount  -> number of rotating SoundData buffers (default 4)
--   sampleRate, channels, bitDepth -> from player if absent
--   volume       -> 0..1 (default 1)
function M.new(opts)
  opts = opts or {}
  local p = opts.player
  if not p then return nil, "streamer: player required" end
  local love_ok, love = pcall(require, "love")
  if not love_ok or not love or not love.audio then
    return nil, "streamer: love.audio not available (use the smoke_test for headless)"
  end

  local sr   = opts.sampleRate  or p.sampleRate or 44100
  local ch   = opts.channels    or p.channels   or 2
  local bd   = opts.bitDepth    or p.bitDepth   or 16
  local bf   = opts.bufferFrames or 2048
  local bc   = opts.bufferCount  or 4

  local src = love.audio.newQueueableSource(sr, bd, ch, bc)
  src:setVolume(opts.volume or 1)

  -- Pre-allocated rotating SoundData buffers.
  local sds = {}
  for i = 1, bc do
    table.insert(sds, love.sound.newSoundData(bf, sr, bd, ch))
  end

  -- Fast path (desktop): one int16 scratch buffer reused every frame.
  -- Web path: a Lua table, filled by player:fillFloats.
  local scratch, scratch_tab
  if have_ffi then
    scratch = ffi.new(string.format("int16_t[%d]", bf * ch))
  else
    scratch_tab = {}
  end

  local self = setmetatable({
    player = p,
    mixers = opts.mixers or nil,
    source = src,
    sds = sds,
    scratch = scratch,
    scratch_tab = scratch_tab,
    frames = bf,
    channels = ch,
    use_ffi = have_ffi,
    _idx = 1,
    _started = false,
    _starved = 0,
  }, M)
  return self
end

-- Layer the optional mixers over the first `got` frames of the scratch
-- buffer/table. No-op when no mixers were configured.
function M:_apply_mixers(got)
  if not self.mixers then return end
  for _, mx in ipairs(self.mixers) do
    if mx and mx.mix_into and mx.enabled ~= false and got > 0 then
      mx:mix_into(self.use_ffi and self.scratch or self.scratch_tab, got)
    end
  end
end

-- Called every love.update(dt). Pumps enough audio to keep the queue full.
-- We never block: if the player has nothing to give, we queue silence so
-- the source doesn't underrun and click.
function M:update(_dt)
  local free = self.source:getFreeBufferCount()
  local ch = self.channels
  local n = self.frames
  while free > 0 do
    local sd = self.sds[self._idx]
    self._idx = self._idx % #self.sds + 1
    local got
    if self.use_ffi then
      got = self.player:fill_into(self.scratch, n)
      if got > 0 then self:_apply_mixers(got) end
      if got < n then
        ffi.fill(self.scratch + got * ch, (n - got) * ch * 2, 0)
        self._starved = self._starved + 1
      end
      ffi.copy(sd:getPointer(), self.scratch, n * ch * 2)
    else
      -- web / pure-Lua path: fill a Lua table of interleaved int16, then
      -- write each sample into the SoundData via setSample.
      got = self.player:fillFloats(self.scratch_tab, n)
      if got > 0 then self:_apply_mixers(got) end
      local total = n * ch
      -- Zero the tail past what the player wrote: the table keeps values
      -- from previous frames, and setSample would otherwise replay stale
      -- audio during an underrun.
      for i = got * ch + 1, total do self.scratch_tab[i] = 0 end
      for i = 1, total do
        sd:setSample(i - 1, (self.scratch_tab[i] or 0) / 32768)
      end
      if got < n then self._starved = self._starved + 1 end
    end
    self.source:queue(sd)
    free = free - 1
  end
  if not self._started then
    self.source:play()
    self._started = true
  end
end

function M:setVolume(v) self.source:setVolume(v) end
function M:getVolume()  return self.source:getVolume() end
function M:playing() return self.source:isPlaying() end
function M:starved() return self._starved end

-- Stop playback and drop queued buffers (so a switch to a new player
-- doesn't leak old audio).
function M:stop()
  self.source:stop()
  self._started = false
end

function M:dispose()
  self:stop()
  self.player:dispose()
  self.source:release()
  for _, sd in ipairs(self.sds) do sd:release() end
end

return setmetatable(M, { __call = function(_, ...) return M.new(...) end })
