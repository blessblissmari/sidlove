-- players/sid_player.lua - SID engine player, wraps the sidlove_sid C shim.
--
-- Hot path: fillFrames(n) calls sidlove_sid_render which runs the C64 CPU
-- for the matching number of cycles and mixes all installed SIDs into a
-- stereo interleaved s16 buffer. The demoscene surface (mute/filter/
-- get_status/get_cia_timer) is exposed as methods so the raster and filter
-- modules can drive visuals and live patching off the same handle.

local base   = require("sidlove.players.base")
local sid_ffi = require("sidlove.ffi.sid_ffi")
local ffi    = require("ffi")

local M = {}
M.__index = setmetatable(M, base)

-- Constants re-exported for user code (sidlove.SID.MODEL_8580 etc.)
M.MODEL_6581 = sid_ffi.MODEL_6581
M.MODEL_8580 = sid_ffi.MODEL_8580
M.MODEL_AUTO = sid_ffi.MODEL_AUTO
M.C64_PAL    = sid_ffi.C64_PAL
M.C64_NTSC   = sid_ffi.C64_NTSC
M.C64_AUTO   = sid_ffi.C64_AUTO
M.VOICE_OSC_0 = sid_ffi.VOICE_OSC_0
M.VOICE_OSC_1 = sid_ffi.VOICE_OSC_1
M.VOICE_OSC_2 = sid_ffi.VOICE_OSC_2
M.VOICE_DIGI  = sid_ffi.VOICE_DIGI

-- opts:
--   sampleRate (default 44100)
--   sid_model  (MODEL_AUTO / MODEL_6581 / MODEL_8580)
--   c64_model  (C64_AUTO / C64_PAL / C64_NTSC ...)
--   force_model (bool) - force the model even when the tune says otherwise
--   digi_boost  (bool) - 8580 digi boost (for 6581-authored tunes on 8580)
--   filter_6581_curve (0..1, default 0.5)
--   filter_8580_curve (Hz, default 12500)
--   combined_waveforms (0/1/2, default 1 = WEAK)
--   sampling (0 interpolate / 1 resample)
--   second_sid, third_sid (hex addresses, 0 unless multi-SID tune)
local function new(opts)
  opts = opts or {}
  if not sid_ffi.loaded then
    return nil, "SID engine not loaded (sidlove_sid.so/.dll/.dylib missing)"
  end
  local self = base.new(opts)
  setmetatable(self, {__index = M})
  self.kind = "sid"

  local lib = sid_ffi.lib
  local h = lib.sidlove_sid_create(self.sampleRate)
  if h == nil then return nil, "sidlove_sid_create failed (OOM)" end
  self._h = ffi.gc(h, function(p) sid_ffi.lib.sidlove_sid_destroy(p) end)

  -- Filter curve tweaks must happen before load() for them to apply to the
  -- first tune; they're cheap to re-apply between tunes too.
  lib.sidlove_sid_set_filter(self._h,
      opts.filter_6581_curve or 0.5,
      opts.filter_8580_curve or 12500.0,
      opts.combined_waveforms or 1)

  self._sid_model   = opts.sid_model  or sid_ffi.MODEL_AUTO
  self._c64_model   = opts.c64_model  or sid_ffi.C64_AUTO
  self._force_model = opts.force_model and true or false
  self._digi_boost  = opts.digi_boost and true or false
  self._sampling    = opts.sampling or sid_ffi.SAMPLE_INTERPOLATE
  self._second_sid  = opts.second_sid or 0
  self._third_sid   = opts.third_sid  or 0
  self._configured  = false
  return self
end

-- Load a .sid / .prg / .mus from a memory buffer. Call before play().
-- Returns true on success, nil + error otherwise.
function M:load_buffer(data, len)
  local lib = sid_ffi.lib
  local rc = lib.sidlove_sid_load(self._h, data, len or #data)
  if rc ~= 0 then
    return nil, ffi.string(lib.sidlove_sid_error(self._h))
  end
  -- Apply config now that we know the tune exists.
  rc = lib.sidlove_sid_config(self._h,
      self._sid_model, self._c64_model,
      self._force_model and 1 or 0,
      self._digi_boost and 1 or 0,
      self._sampling, self._second_sid, self._third_sid)
  if rc ~= 0 then
    return nil, ffi.string(lib.sidlove_sid_error(self._h))
  end
  self._configured = true
  return true
end

-- Load from a file path. Uses plain io because Love2D's love.filesystem
-- paths don't reach the FFI buffer; pass an absolute path.
function M:load_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return self:load_buffer(ffi.new("uint8_t[?]", #data + 1, data), #data)
end

-- Sub-song selection (1-based). Returns the actually selected song number.
function M:select_song(n)
  return sid_ffi.lib.sidlove_sid_select_song(self._h, n)
end

-- Tune info as a Lua table (songs, title, author, ...).
function M:info()
  return sid_ffi.tuneinfo_table(self._h)
end

-- The hot path. Fills `out_buf` (an int16_t[n*channels]) with up to n frames.
-- Returns the number of frames actually written.
function M:fill_into(out_buf, n)
  if not self._configured then return 0 end
  local got
  if self.channels == 2 then
    got = sid_ffi.lib.sidlove_sid_render(self._h, out_buf, n)
  else
    got = sid_ffi.lib.sidlove_sid_render_mono(self._h, out_buf, n)
  end
  return got
end

function M:tell()
  return tonumber(sid_ffi.lib.sidlove_sid_time_ms(self._h))
end

-- SID-specific demoscene surface -------------------------------------------

-- Mute one voice. sidNum 0..2, voice 0..2 or VOICE_DIGI (3).
function M:mute(sid_num, voice, enable)
  sid_ffi.lib.sidlove_sid_mute(self._h, sid_num, voice, enable and 1 or 0)
end

-- Toggle the analog filter on one SID - for live filter sweeps.
function M:filter(sid_num, enable)
  sid_ffi.lib.sidlove_sid_filter(self._h, sid_num, enable and 1 or 0)
end

-- Snapshot of the 32 SID registers. The raster module reads this every
-- frame to mirror chip state into on-screen bars.
function M:sid_status(sid_num)
  return sid_ffi.status_table(self._h)
end

-- CIA 1 Timer A programmed value - the heartbeat of the raster IRQ player.
function M:cia_timer()
  return tonumber(sid_ffi.lib.sidlove_sid_get_cia_timer(self._h))
end

function M:installed_sids()
  return tonumber(sid_ffi.lib.sidlove_sid_installed_sids(self._h))
end

function M:reset()
  sid_ffi.lib.sidlove_sid_reset(self._h)
end

function M:dispose()
  if self._disposed then return end
  self._disposed = true
  if self._h then
    ffi.gc(self._h, nil)  -- drop the gc hook; we destroy manually
    sid_ffi.lib.sidlove_sid_destroy(self._h)
    self._h = nil
  end
end

return setmetatable(M, {__call = function(_, opts) return new(opts) end})
