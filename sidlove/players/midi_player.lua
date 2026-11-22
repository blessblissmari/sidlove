-- players/midi_player.lua - Standard MIDI File player via libfluidsynth.
--
-- Two modes:
--   (A) File playback - load a .mid, hit play. fluid_player runs in its own
--       thread feeding the synth; we pull s16 frames each audio tick via
--       fluid_synth_write_s16. This is the "jukebox" mode.
--   (B) Live MIDI - skip the player, drive the synth directly with noteon/
--       noteoff/cc/program_change/pitch_bend. This is the demoscene / tracker
--       mode: the game code sequences notes live. See the `live_` methods.
--
-- A SoundFont (.sf2/.sf3) MUST be loaded before any sound comes out. The
-- game ships one (e.g. GeneralUser GS ~30MB, or a trimmed ~3MB one). For a
-- C64-ish feel you can use a chiptune soundfont; for general MIDI you want
-- GeneralUser GS.

local base      = require("sidlove.players.base")
local fluid_ffi = require("sidlove.ffi.fluid_ffi")
local ffi       = require("ffi")

local M = {}
-- instance -> M's own methods, then -> base via the module metatable
M.__index = M

-- Re-exported constants
M.TEMPO_INTERNAL      = fluid_ffi.TEMPO_INTERNAL
M.TEMPO_EXTERNAL_BPM  = fluid_ffi.TEMPO_EXTERNAL_BPM
M.TEMPO_EXTERNAL_MIDI = fluid_ffi.TEMPO_EXTERNAL_MIDI
M.PLAYER_PLAYING = fluid_ffi.PLAYER_PLAYING
M.PLAYER_DONE    = fluid_ffi.PLAYER_DONE

local function new(opts)
  opts = opts or {}
  if not fluid_ffi.loaded then
    return nil, "MIDI engine not loaded (libfluidsynth missing)"
  end
  local self = base.new(opts)
  setmetatable(self, M)   -- M.__index chains to base
  self.kind = "midi"

  local lib = fluid_ffi.lib
  self._settings = ffi.gc(lib.new_fluid_settings(), function(p)
    lib.delete_fluid_settings(p) end)
  -- audio.driver is irrelevant: we never create a fluid_audio_driver, we
  -- pull samples ourselves. Set it to a harmless value anyway in case some
  -- internal init peeks at it.
  lib.fluid_settings_setstr(self._settings, "audio.driver", "file")
  lib.fluid_settings_setnum(self._settings, "synth.sample-rate",
                            self.sampleRate)
  -- Default reverb/chorus off - the game can flip them on via set_reverb.
  lib.fluid_settings_setint(self._settings, "synth.reverb.active", 0)
  lib.fluid_settings_setint(self._settings, "synth.chorus.active", 0)
  -- 16 MIDI channels is standard; polyphony 256 is plenty for game BGM.
  lib.fluid_settings_setint(self._settings, "synth.polyphony", 256)

  self._synth = ffi.gc(lib.new_fluid_synth(self._settings), function(p)
    lib.delete_fluid_synth(p) end)
  self._player = nil
  self._sfont_id = -1
  self._gain = 1.0
  return self
end

-- Load a SoundFont (.sf2 / .sf3). Must be called before play / live noteon.
-- Returns the soundfont id (>0) on success, nil + err otherwise.
function M:load_soundfont(path)
  local id = fluid_ffi.lib.fluid_synth_sfload(self._synth, path, 1)
  if id == -1 then
    return nil, "fluid_synth_sfload failed for " .. tostring(path)
  end
  self._sfont_id = id
  return id
end

-- File playback mode ------------------------------------------------------

-- Add a .mid to the player's playlist. Multiple files chain. Call before play.
function M:add_midi(path)
  if not self._player then
    self._player = ffi.gc(fluid_ffi.lib.new_fluid_player(self._synth),
                          function(p) fluid_ffi.lib.delete_fluid_player(p) end)
  end
  local rc = fluid_ffi.lib.fluid_player_add(self._player, path)
  if rc ~= 0 then return nil, "fluid_player_add failed" end
  return true
end

-- Add MIDI from memory.
function M:add_midi_buffer(data, len)
  if not self._player then
    self._player = ffi.gc(fluid_ffi.lib.new_fluid_player(self._synth),
                          function(p) fluid_ffi.lib.delete_fluid_player(p) end)
  end
  local rc = fluid_ffi.lib.fluid_player_add_mem(self._player, data, len or #data)
  if rc ~= 0 then return nil, "fluid_player_add_mem failed" end
  return true
end

function M:play()
  base.play(self)
  if self._player then
    fluid_ffi.lib.fluid_player_set_loop(self._player, self._loop and -1 or 0)
    fluid_ffi.lib.fluid_player_play(self._player)
  end
end

function M:stop()
  base.stop(self)
  if self._player then
    fluid_ffi.lib.fluid_player_stop(self._player)
    fluid_ffi.lib.fluid_synth_all_sounds_off(self._synth, -1)
  end
end

function M:playing()
  if not self._playing then return false end
  if self._player then
    local st = fluid_ffi.lib.fluid_player_get_status(self._player)
    if st == fluid_ffi.PLAYER_DONE then
      if self._loop then
        fluid_ffi.lib.fluid_player_seek(self._player, 0)
        fluid_ffi.lib.fluid_player_play(self._player)
      else
        self._playing = false
        return false
      end
    end
  end
  return true
end

-- Hot path: render n stereo frames into out_buf (int16_t[n*2]).
-- fluid_synth_write_s16 writes interleaved L,R,L,R with lincr=2,rincr=2
-- into one shared buffer - exactly what Love2D's stereo SoundData wants.
function M:fill_into(out_buf, n)
  if not self:playing() then return 0 end
  -- write_s16(out, loff=0, lincr=2, same buf for R) -> interleaved stereo.
  local rc = fluid_ffi.lib.fluid_synth_write_s16(self._synth, n,
              out_buf, 0, 2, out_buf, 1, 2)
  if rc ~= 0 then return 0 end
  return n
end

function M:tell()
  if not self._player then return 0 end
  return tonumber(fluid_ffi.lib.fluid_player_get_current_tick(self._player))
end

function M:seek(ticks)
  if self._player then fluid_ffi.lib.fluid_player_seek(self._player, ticks) end
end

function M:set_tempo(type_, value)
  if self._player then
    fluid_ffi.lib.fluid_player_set_tempo(self._player, type_, value)
  end
end

function M:bpm()
  if not self._player then return 120 end
  return tonumber(fluid_ffi.lib.fluid_player_get_bpm(self._player))
end

-- Live MIDI mode (demoscene / tracker sequencing) ------------------------

function M:noteon(chan, key, vel)
  fluid_ffi.lib.fluid_synth_noteon(self._synth, chan, key, vel)
end
function M:noteoff(chan, key)
  fluid_ffi.lib.fluid_synth_noteoff(self._synth, chan, key)
end
function M:cc(chan, ctrl, val)
  fluid_ffi.lib.fluid_synth_cc(self._synth, chan, ctrl, val)
end
function M:program_change(chan, prog)
  fluid_ffi.lib.fluid_synth_program_change(self._synth, chan, prog)
end
function M:pitch_bend(chan, val)
  fluid_ffi.lib.fluid_synth_pitch_bend(self._synth, chan, val)
end
function M:bank_select(chan, bank)
  fluid_ffi.lib.fluid_synth_bank_select(self._synth, chan, bank)
end
function M:program_select(chan, bank, preset)
  if self._sfont_id < 0 then return nil, "no soundfont loaded" end
  fluid_ffi.lib.fluid_synth_program_select(self._synth, chan,
      self._sfont_id, bank, preset)
end
function M:all_notes_off(chan)
  fluid_ffi.lib.fluid_synth_all_notes_off(self._synth, chan)
end

-- Built-in FX (cheap, on the synth side) ---------------------------------

function M:set_reverb(on, roomsize, damping, width, level)
  local lib = fluid_ffi.lib
  lib.fluid_synth_set_reverb_on(self._synth, on and 1 or 0)
  if on then
    lib.fluid_synth_set_reverb(self._synth,
        roomsize or 0.5, damping or 0.3, width or 0.5, level or 0.3)
  end
end

function M:set_chorus(on, nr, level, speed, depth_ms)
  local lib = fluid_ffi.lib
  lib.fluid_synth_set_chorus_on(self._synth, on and 1 or 0)
  if on then
    lib.fluid_synth_set_chorus(self._synth,
        nr or 3, level or 0.3, speed or 0.3, depth_ms or 2.0, 0)
  end
end

function M:set_gain(g)
  self._gain = g
  fluid_ffi.lib.fluid_synth_set_gain(self._synth, g)
end

function M:cpu_load()
  return tonumber(fluid_ffi.lib.fluid_synth_get_cpu_load(self._synth))
end

function M:dispose()
  if self._disposed then return end
  self._disposed = true
  if self._player then
    ffi.gc(self._player, nil)
    fluid_ffi.lib.delete_fluid_player(self._player)
    self._player = nil
  end
  if self._synth then
    ffi.gc(self._synth, nil)
    fluid_ffi.lib.delete_fluid_synth(self._synth)
    self._synth = nil
  end
  if self._settings then
    ffi.gc(self._settings, nil)
    fluid_ffi.lib.delete_fluid_settings(self._settings)
    self._settings = nil
  end
end

return setmetatable(M, { __index = base, __call = function(_, opts) return new(opts) end })
