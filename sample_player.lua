-- sample_player.lua - 4-bit / 8-bit sample (digi) playback, demoscene style.
--
-- The C64 plays digi samples by writing 4-bit values to the SID volume
-- register ($D418) at ~4-8 kHz, exploiting the chip's non-linear mixing.
-- A Mind Is Born uses a more sophisticated technique that fetches samples
-- from the SID oscillator, but the user-facing idea is the same: drop a
-- raw sample in and have it play synced to the music.
--
-- This module is independent of the SID engine. It generates a 16-bit
-- stereo buffer per frame from one or more active voices, which the
-- streamer mixes alongside the SID/chiptune output. (If you want the digi
-- to come out of the SID chip itself, write the sample into the tune's
-- data via a custom PSID - that path is in sid_player:load_buffer.)
--
-- Voices are tiny: { data = uint8_t*, len = N, rate = Hz, pos = double,
--   vol = 0..1, loop = bool, bits = 4 or 8 }. tick(dt) advances the read
--   position; fill_into(out, n) adds the voice into the interleaved buffer.

local ffi = require("ffi")

local M = {}
M.__index = M
M.Voice = Voice   -- exported so user code can build digi voices directly

local Voice = {}
Voice.__index = Voice

-- Create a voice from a Lua string of sample bytes. bits=4 packs two samples
-- per byte (high nibble first, like the C64 $D418 convention); bits=8 is one
-- per byte. rate is the playback sample rate (e.g. 6000 for C64 digi, 22050
-- for clean). The voice is mono; the mixer pans it center.
function Voice.new(bytes, opts)
  opts = opts or {}
  local n = #bytes
  local buf = ffi.new("uint8_t[?]", n)
  ffi.copy(buf, bytes, n)
  local self = setmetatable({
    data = buf,
    len = n,
    rate = opts.rate or 6000,
    pos = opts.start or 0.0,
    vol = opts.vol or 1.0,
    pan = opts.pan or 0.0,   -- -1 left .. +1 right
    loop = opts.loop ~= false,  -- default loop (demoscene drum loop)
    bits = opts.bits or 8,
    _done = false,
  }, Voice)
  return self
end

-- Read one sample at the current fractional position; return as float -1..1.
function Voice:_sample()
  local i = math.floor(self.pos)
  if i >= self.len then
    if self.loop then i = i % self.len else self._done = true return 0 end
  end
  local raw
  if self.bits == 4 then
    local byte = self.data[i % self.len]
    -- high nibble for even sample, low for odd (matches C64 $D418 players)
    if (math.floor(self.pos) % 2) == 0 then
      raw = bit.rshift(byte, 4)
    else
      raw = bit.band(byte, 0x0f)
    end
    -- 4-bit unsigned 0..15 -> signed -1..1 (center at 8)
    return ((raw - 8) / 8.0) * self.vol
  else
    raw = self.data[i % self.len]
    -- 8-bit unsigned 0..255 -> signed -1..1
    return ((raw - 128) / 128.0) * self.vol
  end
end

function Voice:tick(dt)
  if self._done then return end
  self.pos = self.pos + self.rate * dt
  if not self.loop and self.pos >= self.len then
    self._done = true
    self.pos = self.len
  end
end

function Voice:done() return self._done end
function Voice:reset() self.pos = 0 self._done = false end

-- The Sample mixer -------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    voices = {},
    sampleRate = opts.sampleRate or 44100,
    channels = opts.channels or 2,
  }, M)
  return self
end

function M:add(voice) table.insert(self.voices, voice) return voice end

function M:remove(voice)
  for i, v in ipairs(self.voices) do
    if v == voice then table.remove(self.voices, i) return end
  end
end

-- Advance all voices by dt. Called once per frame from love.update.
function M:tick(dt)
  for i = #self.voices, 1, -1 do
    local v = self.voices[i]
    v:tick(dt)
    if v:done() then table.remove(self.voices, i) end
  end
end

-- Mix into an interleaved int16 stereo buffer alongside whatever's there.
-- out is int16_t[n*2]. This ADDS to the existing samples (clamped) so it
-- layers cleanly over a SID/chiptune buffer the streamer already filled.
function M:mix_into(out, n)
  if #self.voices == 0 then return end
  local sr = self.sampleRate
  for i = 0, n - 1 do
    local acc = 0
    for _, v in ipairs(self.voices) do
      if not v:done() then acc = acc + v:_sample() end
    end
    -- linear pan: -1 = full left, +1 = full right
    local pan = self.voices[1] and self.voices[1].pan or 0
    local l = acc * (1.0 - math.max(0, pan)) * 0.5
    local r = acc * (1.0 + math.min(0, pan)) * 0.5
    -- clamp & add into the int16 buffer
    local li = math.max(-32768, math.min(32767, math.floor(out[i*2]   + l * 32767)))
    local ri = math.max(-32768, math.min(32767, math.floor(out[i*2+1] + r * 32767)))
    out[i*2]   = li
    out[i*2+1] = ri
    -- advance each voice's fractional position by 1/sampleRate of a second
    -- (we ticked once per frame already, but this is the per-sample tick
    -- for accuracy when n > 1).
    for _, v in ipairs(self.voices) do
      v.pos = v.pos + v.rate / sr
      if not v.loop and v.pos >= v.len then v._done = true end
    end
  end
end

return M
