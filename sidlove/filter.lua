-- filter.lua - live ADSR / pitch / filter envelopes that drive a player's
-- parameters frame by frame. This is the "tracker" surface: you define an
-- envelope, attach it to a SID voice or MIDI channel, and the streamer's
-- update loop calls filter:tick(dt) which writes the current values into
-- the player.
--
-- SID live patching: the SID has 25 registers per chip. We can't write them
-- directly through libsidplayfp (the emulated CPU owns them), but we CAN
-- mute/unmute voices, toggle the filter, and tweak the reSIDfp filter
-- curve. For per-voice timbre changes on SID the demoscene approach is to
-- let the tune drive the chip and instead layer additional synthesis on
-- top via the sample_player module.
--
-- For MIDI, live patching is rich: cc (continuous controllers), program
-- change, pitch bend, channel pressure, and synth generators (attack,
-- release, filter cutoff via fluid_synth_set_gen). This module gives you
-- ADSR envelopes that map to any of those.

local M = {}
M.__index = M   -- instance -> M's own methods (Filter() module sugar is at the tail)

-- The native-ffi handles are needed only by the preset setters. Load them
-- safely so the pure-Lua / web build (no ffi) still constructs envelopes.
local have_ffi = pcall(require, "ffi")
local sid_ffi, fluid_ffi
if have_ffi then
  sid_ffi   = require("sidlove.ffi.sid_ffi")
  fluid_ffi = require("sidlove.ffi.fluid_ffi")
end

-- Standard MIDI continuous controller numbers (subset).
M.CC_MODWHEEL     = 1
M.CC_BREATH       = 2
M.CC_FOOT         = 4
M.CC_PORTAMENTO   = 5
M.CC_VOLUME       = 7
M.CC_BALANCE      = 8
M.CC_PAN          = 10
M.CC_EXPRESSION   = 11
M.CC_EFFECT1      = 12
M.CC_SUSTAIN      = 64
M.CC_PORTAMENTO_SW= 65
M.CC_FILTER_CUTOFF= 74   -- GM2 sound controller
M.CC_FILTER_RESON = 71
M.CC_RELEASE_TIME = 72
M.CC_ATTACK_TIME  = 73

-- fluid_synth_set_gen parameter IDs (subset).
M.GEN_ATTACK      = 5
M.GEN_RELEASE     = 6
M.GEN_SUSTAIN     = 9   -- sustain level (0..1)
M.GEN_FILTERFC    = 17  -- filter cutoff (Hz, cents)
M.GEN_FILTERQ     = 18  -- filter resonance

-- ADSR envelope. times in seconds. levels in 0..1 (for CC/gen) or 0..127
-- for CC - we accept either and scale via the target's max.
local Envelope = {}
Envelope.__index = Envelope

-- opts: { attack=, decay=, sustain=, release=, peak=1.0, sustain_level= }
-- peak defaults to 1.0; sustain_level defaults to 0.7.
function Envelope.new(opts)
  opts = opts or {}
  local self = setmetatable({
    attack  = opts.attack  or 0.02,
    decay   = opts.decay   or 0.1,
    sustain = opts.sustain or 0.2,   -- sustain *hold* time, not level
    release = opts.release or 0.3,
    peak    = opts.peak    or 1.0,
    sustain_level = opts.sustain_level or 0.7,
    _t = 0,
    _state = "idle",   -- idle/attack/decay/sustain/release/done
    _cur = 0,
  }, Envelope)
  return self
end

-- Trigger the envelope (note-on).
function Envelope:strike()
  self._t = 0
  self._state = "attack"
end

-- Release the envelope (note-off).
function Envelope:release_now()
  if self._state ~= "done" and self._state ~= "idle" then
    self._state = "release"
    self._relstart = self._cur
  end
end

function Envelope:value() return self._cur end
function Envelope:state() return self._state end
function Envelope:done() return self._state == "done" end

-- Advance by dt seconds. Updates self._cur. A large dt traverses as many
-- phases as it covers (a 0.5s frame on a 0.1s attack runs the whole ADSR),
-- so callers can never get stuck in a phase by passing big frames.
function Envelope:tick(dt)
  if self._state == "idle" or self._state == "done" then self._cur = 0 return end
  local left = dt
  while left > 0 do
    local s = self._state
    if s == "attack" then
      local rem = self.attack - self._t
      if left >= rem then
        left = left - rem
        self._cur = self.peak
        self._state, self._t = "decay", 0
      else
        self._t = self._t + left
        self._cur = self.peak * (self._t / self.attack)
        left = 0
      end
    elseif s == "decay" then
      local rem = self.decay - self._t
      if left >= rem then
        left = left - rem
        self._cur = self.sustain_level * self.peak
        self._state, self._t = "sustain", 0
      else
        self._t = self._t + left
        local a = self._t / self.decay
        self._cur = self.peak + (self.sustain_level * self.peak - self.peak) * a
        left = 0
      end
    elseif s == "sustain" then
      self._cur = self.sustain_level * self.peak
      local rem = self.sustain - self._t
      if left >= rem then
        left = left - rem
        self._state, self._t = "release", 0   -- auto-release when hold time ends
        self._relstart = self._cur
      else
        self._t = self._t + left
        left = 0
      end
    elseif s == "release" then
      local rem = self.release - self._t
      if left >= rem then
        left = left - rem
        self._cur = 0
        self._state, self._t = "done", 0
      else
        self._t = self._t + left
        local a = self._t / self.release
        self._cur = (self._relstart or self._cur) * (1 - a)
        left = 0
      end
    else
      break  -- unknown state, don't spin
    end
  end
end

-- A binding from an envelope to a player parameter. The setter is a closure
-- the user supplies, or one of the presets below.
local Binding = {}
Binding.__index = Binding

function Binding.new(env, setter)
  return setmetatable({env = env, setter = setter, active = true}, Binding)
end
function Binding:tick(dt)
  if not self.active then return end
  self.env:tick(dt)
  self.setter(self.env:value())
end

-- Constructor sugar so both forms work:
--   Filter.Envelope.new{...}   Filter.Envelope{...}   (same for Binding)
setmetatable(Envelope, { __call = function(_, opts) return Envelope.new(opts) end })
setmetatable(Binding,  { __call = function(_, ...) return Binding.new(...)   end })

-- Export now that the locals exist (doing this above the definitions would
-- export nil).
M.Envelope = Envelope
M.Binding  = Binding

-- The Filter holds a list of bindings; tick() advances all of them. This
-- lets a single game frame drive many envelopes (e.g. one per MIDI voice).
function M.new()
  return setmetatable({bindings = {}}, M)
end

function M:add(env, setter)
  local b = Binding.new(env, setter)
  table.insert(self.bindings, b)
  return b
end

function M:tick(dt)
  for i = #self.bindings, 1, -1 do
    local b = self.bindings[i]
    b:tick(dt)
    if b.env:done() and not b.hold then
      table.remove(self.bindings, i)
    end
  end
end

function M:clear() self.bindings = {} end

-- Preset setters for a MIDI player ---------------------------------------

-- Bind envelope 0..1 -> CC value 0..127 on a channel/controller.
function M.setter_midi_cc(midi, chan, ctrl)
  return function(v)
    midi:cc(chan, ctrl, math.floor(v * 127 + 0.5))
  end
end

-- Bind envelope 0..1 -> pitch bend (0..16383, 8192 = center).
function M.setter_midi_pitch(midi, chan)
  return function(v)
    midi:pitch_bend(chan, math.floor(8192 + v * 8190 + 0.5))
  end
end

-- Bind envelope 0..1 -> fluidsynth generator (e.g. GEN_FILTERFC cutoff).
-- value scaled into the gen's range; for cutoff we map 0..1 -> 20..20000 Hz.
function M.setter_midi_gen(midi, chan, gen, lo, hi)
  return function(v)
    if midi._synth and fluid_ffi and fluid_ffi.lib then
      fluid_ffi.lib.fluid_synth_set_gen(midi._synth, chan, gen, lo + (hi - lo) * v)
    end
  end
end

-- Preset setters for a SID player ---------------------------------------

-- Bind envelope 0..1 -> reSIDfp 6581 filter curve sweep (0..1).
function M.setter_sid_filter6581(sid)
  return function(v)
    if sid_ffi and sid_ffi.lib then
      sid_ffi.lib.sidlove_sid_set_filter(sid._h, v, 12500.0, 1)
    end
  end
end

-- Bind envelope 0..1 -> mute toggle on a voice (gate effect).
function M.setter_sid_gate(sid, sid_num, voice)
  return function(v)
    sid:mute(sid_num, voice, v > 0.5)
  end
end

-- Constructor sugar: Filter{...} == Filter.new(...) (main.lua calls it plain).
return setmetatable(M, { __call = function(_, ...) return M.new(...) end })
