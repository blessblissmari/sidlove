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
-- The fill function calls player:fill_into(int16_buf, frames), then
-- ffi.copy's the raw int16 bytes into a SoundData's pointer (Love2D 11+
-- exposes SoundData:getPointer()). That copy is a single memcpy - much
-- faster than calling :setSample per sample.

local ffi = require("ffi")

local M = {}
M.__index = M

-- opts:
--   player     -> a Player instance (sid/chiptune/midi)
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
  -- The love 11 QueueableSource API: queue(sd), getFreeBufferCount(), play().

  -- Pre-allocated rotating SoundData buffers + matching int16 scratch.
  local sds = {}
  local scratch = ffi.new(string.format("int16_t[%d]", bf * ch))
  for i = 1, bc do
    table.insert(sds, love.sound.newSoundData(bf, sr, bd, ch))
  end

  local self = setmetatable({
    player = p,
    source = src,
    sds = sds,
    scratch = scratch,
    frames = bf,
    channels = ch,
    _idx = 1,
    _started = false,
    _starved = 0,
  }, M)
  return self
end

-- Called every love.update(dt). Pumps enough audio to keep the queue full.
-- We never block: if the player has nothing to give, we queue silence so
-- the source doesn't underrun and click.
function M:update(dt)
  local free = self.source:getFreeBufferCount()
  while free > 0 do
    local sd = self.sds[self._idx]
    self._idx = self._idx % #self.sds + 1
    local got = self.player:fill_into(self.scratch, self.frames)
    if got < self.frames then
      -- Underrun or end of track: zero the rest so we don't play garbage.
      ffi.fill(self.scratch + got * self.channels,
               (self.frames - got) * self.channels * 2, 0)
      self._starved = self._starved + 1
    end
    -- Copy raw int16 bytes into the SoundData. SoundData:getPointer returns
    -- a void* to its internal sample buffer; the layout for 16-bit stereo
    -- is exactly interleaved L,R,L,R which is what every player produces.
    ffi.copy(sd:getPointer(), self.scratch, self.frames * self.channels * 2)
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

return M
