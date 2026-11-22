-- players/chiptune_player.lua - NSF/NSFE/SAP/VGM/SPC/AY/HES/KSS/GBS/GYM
-- player via libgme. libgme plays any of those through one C API, so this
-- module handles all of them. The format is detected from the header bytes.
--
-- libgme works in "stereo interleaved s16" by default. gme_play(count, out)
-- writes `count` int16 = count/2 frames (one frame = L+R pair). The engine
-- has built-in voice muting, tempo, fade, and a treble/bass EQ - exposed
-- here so a game can do demoscene-style "voice isolation" tricks.

local base    = require("sidlove.players.base")
local gme_ffi = require("sidlove.ffi.gme_ffi")
local ffi     = require("ffi")

local M = {}
M.__index = setmetatable(M, base)

local function new(opts)
  opts = opts or {}
  if not gme_ffi.loaded then
    return nil, "chiptune engine not loaded (libgme missing)"
  end
  local self = base.new(opts)
  setmetatable(self, {__index = M})
  self.kind = "chiptune"
  self._emu = nil          -- Music_Emu* (gc-managed)
  self._track = 0
  self._voice_count = 0
  return self
end

-- Load a chiptune from a memory buffer. Detects the format from the header
-- and constructs the right emulator. Returns true / nil+err.
function M:load_buffer(data, len)
  len = len or #data
  local lib = gme_ffi.lib
  -- gme_open_data makes a copy; data can be freed after.
  local pemu = ffi.new("Music_Emu*[1]")
  local err = lib.gme_open_data(data, len, pemu, self.sampleRate)
  if err ~= nil then
    return nil, "gme_open_data: " .. ffi.string(err)
  end
  self._emu = ffi.gc(pemu[0], function(p) gme_ffi.lib.gme_delete(p) end)
  self._voice_count = tonumber(lib.gme_voice_count(self._emu)) or 0
  -- By default libgme auto-loads track length metadata and stops at end.
  -- For a game we usually want infinite loops: disable the auto limit so
  -- NSF/SAP/etc. loop forever. set_loop(true) on the player re-enables a
  -- gme-style fade as a soft fallback if the user opts out of looping.
  lib.gme_set_autoload_playback_limit(self._emu, 0)
  lib.gme_ignore_silence(self._emu, 1)
  return true
end

function M:load_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return self:load_buffer(ffi.new("uint8_t[?]", #data + 1, data), #data)
end

function M:track_count()
  if not self._emu then return 0 end
  return tonumber(gme_ffi.lib.gme_track_count(self._emu))
end

-- Start a track (0-based index). Returns true / nil+err.
function M:start_track(idx)
  if not self._emu then return nil, "no tune loaded" end
  local err = gme_ffi.lib.gme_start_track(self._emu, idx)
  if err ~= nil then return nil, ffi.string(err) end
  self._track = idx
  return true
end

function M:playing()
  if not self._emu then return false end
  if not self._playing then return false end
  -- gme_track_ended flips true at end-of-track. With looping we restart.
  if gme_ffi.lib.gme_track_ended(self._emu) ~= 0 then
    if self._loop then
      gme_ffi.lib.gme_start_track(self._emu, self._track)
    else
      self._playing = false
      return false
    end
  end
  return true
end

-- Hot path: fill `out_buf` (int16_t[n*2] for stereo) with up to n frames.
-- libgme writes stereo interleaved, so n frames = 2*n int16 = 2*n "count"
-- in libgme's units (gme_play's count is in int16, not frames).
function M:fill_into(out_buf, n)
  if not self._emu or not self:playing() then return 0 end
  local want_shorts = n * self.channels
  local err = gme_ffi.lib.gme_play(self._emu, want_shorts, out_buf)
  if err ~= nil then return 0 end
  return n
end

function M:tell()
  if not self._emu then return 0 end
  return tonumber(gme_ffi.lib.gme_tell(self._emu))
end

function M:seek(ms)
  if not self._emu then return end
  gme_ffi.lib.gme_seek(self._emu, ms)
end

-- libgme extras, exposed for demoscene voice tricks ---------------------

function M:voice_count() return self._voice_count end

function M:voice_name(i)
  if not self._emu then return nil end
  local s = gme_ffi.lib.gme_voice_name(self._emu, i)
  if s == nil then return nil end
  return ffi.string(s)
end

-- Mute a single voice (0-based). enable=true = audible, false = muted.
function M:mute_voice(i, enable)
  if not self._emu then return end
  gme_ffi.lib.gme_mute_voice(self._emu, i, enable and 0 or 1)
end

-- Mute by bitmask: bit set = muted. -1 = all muted, 0 = all on.
function M:mute_voices(mask)
  if not self._emu then return end
  gme_ffi.lib.gme_mute_voices(self._emu, mask)
end

function M:set_tempo(t)
  if not self._emu then return end
  gme_ffi.lib.gme_set_tempo(self._emu, t)
end

-- treble -50..+5, bass 1..16000 (libgme's odd scale).
function M:set_equalizer(treble, bass)
  if not self._emu then return end
  local eq = ffi.new("gme_equalizer_t")
  eq.treble = treble or 0
  eq.bass   = bass or 90
  gme_ffi.lib.gme_set_equalizer(self._emu, eq)
end

function M:enable_accuracy(on)
  if not self._emu then return end
  gme_ffi.lib.gme_enable_accuracy(self._emu, on and 1 or 0)
end

function M:set_loop(on)
  self._loop = on and true or false
  if self._emu then
    if on then
      gme_ffi.lib.gme_set_autoload_playback_limit(self._emu, 0)
    else
      -- When looping is off, ask libgme to fade after the track's nominal
      -- length so it doesn't drone forever on infinite-loop NSF tracks.
      local ms = self:tell()
      gme_ffi.lib.gme_set_fade(self._emu, ms + 8000)
    end
  end
end

function M:dispose()
  if self._disposed then return end
  self._disposed = true
  if self._emu then
    ffi.gc(self._emu, nil)
    gme_ffi.lib.gme_delete(self._emu)
    self._emu = nil
  end
end

return setmetatable(M, {__call = function(_, opts) return new(opts) end})
