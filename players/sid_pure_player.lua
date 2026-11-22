-- players/sid_pure_player.lua - pure-Lua SID player (no FFI).
--
-- The love.js / web player. Parses a PSID/RSID file, loads it into a 64K C64
-- memory map, wires a sidlove.m6502 CPU to a sidlove.sidchip SID, calls the
-- tune's init + play routines, and renders audio samples. It implements the
-- same Player interface as the native sid_player, so the streamer and the
-- rest of sidlove treat it identically.
--
-- This is the fix for "love.js / web: not supported — no LuaJIT FFI in WASM":
-- everything here is vanilla Lua 5.1 + sidlove.bit, so it runs in the
-- browser. On desktop with the native libs present, sidlove still prefers
-- sid_player (reSIDfp) for bit-exact 6581/8580 sound; this pure path is the
-- portable fallback and the web default.
--
-- Limitations (documented, by design): the 6502 + ADSR + oscillator are
-- accurate enough for the overwhelming majority of HVSC tunes, but
-- sample/digi playback and raster-IRQ-timed tunes are approximated by
-- calling play() at the video frame rate, and the 6581 filter is a linear
-- SVF rather than the non-linear analog model. For those, use the native
-- engine on desktop.

local bit        = require("sidlove.bit")
local band, bor  = bit.band, bit.bor
local lshift, rshift = bit.lshift, bit.rshift
local CPU        = require("sidlove.m6502")
local SID        = require("sidlove.sidchip")
local base       = require("sidlove.players.base")

local M = {}
M.__index = setmetatable(M, base)

-- exposed constants (mirror the native player's surface)
M.MODEL_6581 = 0x6581
M.MODEL_8580 = 0x8580
M.MODEL_AUTO = 0
M.C64_PAL    = 0x00
M.C64_NTSC   = 0x01
M.C64_AUTO   = 0xFF
M.VOICE_OSC_0 = 0
M.VOICE_OSC_1 = 1
M.VOICE_OSC_2 = 2
M.VOICE_DIGI  = 3

-- clock/model tables
local CLOCK_HZ  = { [0x00] = 985248, [0x01] = 1022727 }  -- PAL / NTSC
local FRAME_HZ  = { [0x00] = 50.0,    [0x01] = 60.0 }

-- --- PSID header parse ----------------------------------------------------
local function parse_psid(data, len)
  -- data: a 0-indexed byte-accessible source. We accept either a Lua string
  -- or a table/ffi-cdata with [i] indexing. Normalise to a string for parse.
  if type(data) == "table" or (bit and tostring(data):find("cdata")) then
    local t = {}
    for i = 0, len - 1 do t[i + 1] = string.char(band(data[i], 0xFF)) end
    data = table.concat(t)
  end
  if #data < 0x76 then return nil, "PSID: file too small" end
  local magic = data:sub(1, 4)
  if magic ~= "PSID" and magic ~= "RSID" then return nil, "PSID: bad magic" end
  local function u16(off) return data:byte(off) * 256 + data:byte(off + 1) end
  local function u32(off) return u16(off) * 65536 + u16(off + 2) end
  local h = {}
  h.magic       = magic
  h.version     = u16(5)
  h.dataOffset  = u16(7)
  h.loadAddr    = u16(9)
  h.initAddr    = u16(11)
  h.playAddr    = u16(13)
  h.songs       = u16(15)
  h.startSong   = u16(17)
  h.speed       = u32(19)              -- bit per song: 0=VBI, 1=CIA
  h.flags       = (h.version >= 2) and u32(23) or 0
  h.clock       = (h.version >= 2) and band(data:byte(0x77), 0xFF) or 0x00
  h.sidModel    = (h.version >= 2) and band(data:byte(0x78), 0xFF) or 0x00
  h.relocPages  = (h.version >= 2) and { start = band(data:byte(0x79), 0xFF),
                                          length = band(data:byte(0x7A), 0xFF) } or nil
  if h.version >= 2 then
    h.name      = data:sub(0x16 + 1, 0x16 + 32):gsub("%z+$", "")
    h.author    = data:sub(0x36 + 1, 0x36 + 32):gsub("%z+$", "")
    h.released  = data:sub(0x56 + 1, 0x56 + 32):gsub("%z+$", "")
  else
    h.name, h.author, h.released = "(unnamed)", "?", "?"
  end
  h.data        = data
  h.dataStart   = h.dataOffset + 1   -- 1-indexed into the Lua string
  h.dataLen     = #data - h.dataOffset
  return h
end

-- --- constructor ----------------------------------------------------------
local function new(opts)
  opts = opts or {}
  local self = base.new({
    sampleRate = opts.sampleRate or 44100,
    channels   = opts.channels or 2,
  })
  setmetatable(self, M)
  self.model      = opts.sid_model or M.MODEL_AUTO
  self.clock_sel  = opts.c64_clock or M.C64_AUTO
  self._h         = nil      -- parsed header
  self._ram       = nil      -- 64K memory
  self._cpu       = nil
  self._sid       = nil
  self._song      = 0
  self._elapsed_ms = 0
  self._frame_samples = 0    -- samples to render before next play() call
  self._frames_played  = 0
  return self
end

-- --- load a PSID from a Lua string ----------------------------------------
function M:load_buffer_str(str, len)
  local h, err = parse_psid(str, len or #str)
  if not h then return nil, err end
  self._h = h

  -- resolve load address: RSID & PSID loadAddr==0 -> first 2 data bytes,
  -- which are a C64 little-endian load address (NOT big-endian like the
  -- header fields).
  local loadAddr = h.loadAddr
  local dataOff
  if loadAddr == 0 then
    if #h.data < h.dataStart + 1 then return nil, "PSID: truncated" end
    loadAddr = h.data:byte(h.dataStart) + h.data:byte(h.dataStart + 1) * 256
    dataOff = h.dataStart + 2
  else
    dataOff = h.dataStart
  end
  if loadAddr < 0 or loadAddr > 0xFFFF then return nil, "PSID: bad load addr" end

  -- build the 64K memory map and load the tune
  local ram = {}
  for i = 0, 0xFFFF do ram[i] = 0 end
  for i = 0, h.dataLen - 1 do
    ram[band(loadAddr + i, 0xFFFF)] = h.data:byte(dataOff + i)
  end
  self._ram = ram
  self._loadAddr = loadAddr

  -- clock / model resolution
  local clock = h.clock
  if self.clock_sel == M.C64_PAL  then clock = 0x00 end
  if self.clock_sel == M.C64_NTSC then clock = 0x01 end
  if clock ~= 0x00 and clock ~= 0x01 then clock = 0x00 end  -- default PAL
  self._clock_hz = CLOCK_HZ[clock]
  self._frame_hz = FRAME_HZ[clock]

  -- wire the SID chip
  self._sid = SID.new(self._clock_hz, self.sampleRate)

  -- wire the CPU with a read/write that routes $D400-$D41F to the SID
  local sid, ram_ = self._sid, self._ram
  self._cpu = CPU.new()
  self._cpu.write = function(addr, val)
    if addr >= 0xD400 and addr <= 0xD41F then
      sid:write(addr - 0xD400, val)
    elseif addr >= 0xD420 and addr <= 0xD7FF then
      -- mirrored SID (2nd/3rd SID on some tunes) - ignore beyond $D440
      if addr <= 0xD43F then sid:write(addr - 0xD400, val) end
    else
      ram_[addr] = band(val, 0xFF)
    end
  end
  self._cpu.read = function(addr)
    if addr >= 0xD400 and addr <= 0xD41F then
      return sid:read(addr - 0xD400)
    elseif addr >= 0xD420 and addr <= 0xD43F then
      return sid:read(addr - 0xD400)
    end
    return ram_[addr] or 0
  end

  -- a stable place for the JSR return sentinel (in low RAM, unused by tunes)
  self._jsr_ret = 0x0334
  ram_[self._jsr_ret] = 0x60  -- RTS lands here and we detect PC == ret+1

  self._configured = true
  return true
end

-- --- song init + per-frame play -------------------------------------------
function M:select_song(n)
  if not self._configured then return nil, "not loaded" end
  local h = self._h
  self._song = (n and n >= 1 and n <= h.songs) and n or h.startSong
  -- reset chip + cpu
  self._sid:reset()
  self._cpu.S = 0xFD
  self._cpu.P = bor(0x20, 0x04)  -- U | I
  self._cpu.halted = false
  -- run the init routine: JSR initAddr with A = song-1
  self._cpu:jsr(h.initAddr, self._song - 1)
  self._elapsed_ms = 0
  self._frames_played = 0
  self._frame_samples = 0
  return true
end

-- call the play routine once (one video frame's worth of CPU time)
function M:_call_play()
  local h = self._h
  if h.playAddr ~= 0 then
    self._cpu:jsr(h.playAddr)
  end
end

-- --- render: returns a 1-indexed table of mono float samples [-1,1] -------
function M:render(n)
  if not self._configured then return {} end
  local samples_per_frame = self.sampleRate / self._frame_hz
  local out = {}
  local i = 1
  while i <= n do
    -- do we need to call play() before rendering this frame's samples?
    if self._frame_samples <= 0 then
      self:_call_play()
      self._frame_samples = self._frame_samples + samples_per_frame
      self._frames_played = self._frames_played + 1
    end
    -- render min(remaining samples in this frame, samples still needed)
    local take = math.min(self._frame_samples, n - i + 1)
    local chunk = self._sid:render(math.floor(take))
    for _, v in ipairs(chunk) do
      out[i] = v
      i = i + 1
    end
    self._frame_samples = self._frame_samples - #chunk
    self._elapsed_ms = self._elapsed_ms + (#chunk / self.sampleRate) * 1000
  end
  return out
end

-- --- the sidlove player hot path (no-FFI version) -------------------------
-- Fills `out` (a plain Lua table, 1-indexed) with interleaved int16 samples
-- for `n` frames, honouring self.channels. Returns frames written.
function M:fillFloats(out, n)
  if not self._configured then return 0 end
  local mono = self:render(n)
  local ch = self.channels
  local w = 1
  for i = 1, #mono do
    local s = mono[i]
    -- clamp + convert to int16
    if s > 1 then s = 1 elseif s < -1 then s = -1 end
    local v = math.floor(s * 32767)
    out[w] = v; w = w + 1
    if ch == 2 then out[w] = v; w = w + 1 end
  end
  return #mono
end

-- FFI-compatible fill_into (used only when the native streamer path is
-- available but the pure engine was explicitly selected). Writes int16
-- straight into the cdata buffer.
function M:fill_into(out_buf, n)
  if not self._configured then return 0 end
  local mono = self:render(n)
  local ch = self.channels
  local idx = 0
  for i = 1, #mono do
    local s = mono[i]
    if s > 1 then s = 1 elseif s < -1 then s = -1 end
    local v = math.floor(s * 32767)
    if v > 32767 then v = 32767 elseif v < -32768 then v = -32768 end
    out_buf[idx] = v; idx = idx + 1
    if ch == 2 then out_buf[idx] = v; idx = idx + 1 end
  end
  return #mono
end

-- --- the rest of the Player interface -------------------------------------
function M:tell() return math.floor(self._elapsed_ms) end
function M:seek(ms)
  -- pure-Lua path: re-init and fast-forward to the target frame
  if not self._configured then return end
  local target_frame = math.floor((ms / 1000) * self._frame_hz)
  self:select_song(self._song)
  while self._frames_played < target_frame do
    self:_call_play()
    self._frames_played = self._frames_played + 1
  end
  self._elapsed_ms = ms
  self._frame_samples = 0
end
function M:info()
  local h = self._h
  if not h then return {} end
  return {
    name = h.name, author = h.author, released = h.released,
    songs = h.songs, start_song = h.startSong,
    version = h.version, clock = (h.clock == 0x01) and "NTSC" or "PAL",
    sid_model = (h.sidModel == 0x02) and "8580" or "6581",
    load_addr = self._loadAddr, init_addr = h.initAddr, play_addr = h.playAddr,
  }
end
function M:mute(sid_num, voice, enable)
  if voice >= 0 and voice <= 2 then self._sid:set_mute(voice + 1, enable) end
end
function M:filter(sid_num, enable) self._filter_on = enable end
function M:sid_status(sid_num)
  return self._sid:regs()
end
function M:reset() if self._configured then self:select_song(self._song) end end
function M:dispose()
  if self._disposed then return end
  self._disposed = true
  self._configured = false
  self._ram, self._cpu, self._sid, self._h = nil, nil, nil, nil
end

return setmetatable(M, {__call = function(_, opts) return new(opts) end})
