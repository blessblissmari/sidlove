-- sidchip.lua - pure-Lua MOS 6581/8580 (SID) sound chip emulator.
--
-- A portable SID core with no FFI: 3 voices (oscillator + ADSR envelope),
-- the combined waveforms, and a simplified state-variable filter. It is not
-- cycle-accurate or bit-exact with reSIDfp — that path lives in the C shim
-- for desktop — but it produces recognisable SID timbre and, crucially, runs
-- in vanilla Lua 5.1 (love.js / WASM) with no `bit` library beyond sidlove.bit.
--
-- Register layout (offsets 0x00..0x1F, base $D400 on a real C64):
--   voice N (N=0,1,2): freqlo freqhi pwlo pwhi ctrl AD SR
--   0x15/0x16 filter cutoff (11-bit), 0x17 resonance+routing, 0x18 vol+mode
--   0x19/0x1A paddle (read), 0x1B osc3 (read), 0x1C env3 (read)
--
-- Usage:
--   local SID = require("sidlove.sidchip")
--   local sid = SID.new(985248, 44100)   -- PAL clock, 44.1k
--   sid:write(0x00, 0x44); sid:write(0x01, 0xC8)  -- freq
--   sid:write(0x04, 0x11)                          -- triangle + gate
--   sid:write(0x18, 0x0F)                          -- volume 15
--   local samples = sid:render(4410)               -- 0.1s of audio

local bit = require("sidlove.bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local M = {}
M.__index = M

-- ADSR timing tables (milliseconds). These are the canonical SID envelope
-- rates from the original 6581 datasheet / programmer's reference:
--   attack: time to rise 0 -> full (one full ramp, 256 envelope steps)
--   decay/release: time per step (16 steps in the exponential fall)
-- We convert ms -> clock cycles at construction time.
local ATTACK_MS = {
  2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000,
}
local DECAY_REL_MS = {  -- per-step ms for each 4-bit decay/release rate
  6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000,
}

-- control register (0x04/0x0B/0x12) bit meanings
local CTRL_GATE    = 0x01
local CTRL_SYNC    = 0x02
local CTRL_RING    = 0x04
local CTRL_TEST    = 0x08
local CTRL_TRI     = 0x10
local CTRL_SAW     = 0x20
local CTRL_PULSE   = 0x40
local CTRL_NOISE   = 0x80

-- filter mode bits in 0x18
local FILT_LP = 0x10
local FILT_BP = 0x20
local FILT_HP = 0x40
local FILT_3OFF = 0x80

local function u24(n) n = n % 16777216; if n < 0 then n = n + 16777216 end return n end

function M.new(clock_hz, sample_rate)
  local self = setmetatable({}, M)
  self.clock_hz = clock_hz or 985248      -- PAL default
  self.sample_rate = sample_rate or 44100
  self.cycles_per_sample = self.clock_hz / self.sample_rate
  -- precompute per-step cycle counts (cycles per single envelope step)
  local k = self.clock_hz / 1000.0
  self.attack_steps = {}   -- cycles for the WHOLE attack ramp (256 steps)
  self.decay_steps = {}    -- cycles per single decay/release step
  for i = 1, 16 do
    self.attack_steps[i] = ATTACK_MS[i] * k
    self.decay_steps[i] = DECAY_REL_MS[i] * k
  end
  self:reset()
  return self
end

function M:reset()
  self.reg = {}
  for i = 0, 0x1F do self.reg[i] = 0 end
  -- Default the master volume to max. A real 6581's reset state is
  -- indeterminate (often 0), but a software player should produce sound for
  -- tunes that simply forget to set $D418; tunes that set it overwrite this.
  self.reg[0x18] = 0x0F
  -- per-voice state
  self.v = {}
  for i = 1, 3 do
    self.v[i] = {
      phase = 0,          -- 24-bit oscillator phase accumulator
      noise = 0x7fffff,   -- 23-bit noise LFSR seed
      env_state = 0,      -- 0=idle 1=attack 2=decay 3=sustain 4=release
      env_level = 0,      -- 0..255 envelope amplitude
      env_step_cycles = 0,-- cycle counter until next env step
      prev_gate = false,  -- boolean (NOT 0: in Lua 0 is truthy, which would
                          -- break the `gate and not prev_gate` attack trigger)
    }
  end
  -- filter state (state-variable filter integrators)
  self.f_lp = 0; self.f_bp = 0; self.f_hp = 0
  self.muted = {false, false, false}
end

function M:write(reg, val)
  reg = band(reg, 0x1F)
  val = band(val, 0xFF)
  self.reg[reg] = val
end

function M:read(reg)
  reg = band(reg, 0x1F)
  if reg == 0x1B then
    -- osc3: top 8 bits of voice 3 phase (the noise/random source)
    return band(rshift(self.v[3].phase, 16), 0xFF)
  elseif reg == 0x1C then
    -- env3: current envelope of voice 3
    return band(self.v[3].env_level, 0xFF)
  end
  return self.reg[reg] or 0
end

-- --- per-voice oscillator output (12-bit, 0..4095) ------------------------
local function osc_output(self, vidx)
  local v = self.v[vidx]
  local ctrl = self.reg[(vidx - 1) * 7 + 4] or 0
  local phase = v.phase
  local p12 = rshift(phase, 12)  -- top 12 bits, 0..4095
  local wf = band(ctrl, 0xF0)    -- waveform bits (tri/saw/pulse/noise)

  if wf == 0 then
    return 0  -- no waveform selected -> silence (DC blocked by envelope anyway)
  end

  -- Most tunes use a single waveform. When multiple are set the 6581 outputs
  -- a bitwise combination; we approximate the common pairs with simple AND.
  local tri, saw, pul, noi
  if band(ctrl, CTRL_TRI) ~= 0 then
    -- triangle: fold the 12-bit saw at the midpoint
    tri = (p12 < 2048) and p12 or (4095 - p12)
  end
  if band(ctrl, CTRL_SAW) ~= 0 then
    saw = p12
  end
  if band(ctrl, CTRL_PULSE) ~= 0 then
    local pwlo = self.reg[(vidx - 1) * 7 + 2] or 0
    local pwhi = self.reg[(vidx - 1) * 7 + 3] or 0
    local pw = bor(pwlo, lshift(band(pwhi, 0x0F), 8))  -- 12-bit pulse width
    pul = (p12 < pw) and 4095 or 0
  end
  if band(ctrl, CTRL_NOISE) ~= 0 then
    noi = band(rshift(v.noise, 4), 0xFFF)  -- top bits of the 23-bit LFSR
  end

  -- combine: the 6581 mostly ANDs overlapping waveforms. For the single-
  -- waveform common case this just returns that waveform.
  if wf == CTRL_TRI then return tri end
  if wf == CTRL_SAW then return saw end
  if wf == CTRL_PULSE then return pul end
  if wf == CTRL_NOISE then return noi end

  -- combined: approximate with AND where both present
  local acc = nil
  for _, w in ipairs({tri, saw, pul, noi}) do
    if w then acc = (acc == nil) and w or band(acc, w) end
  end
  return acc or 0
end

-- advance one voice's oscillator + envelope by `cycles` clock cycles
local function clock_voice(self, vidx, cycles)
  local v = self.v[vidx]
  local base = (vidx - 1) * 7
  local freq = bor(self.reg[base + 1] or 0, lshift(self.reg[base + 2] or 0, 8))
  local ctrl = self.reg[base + 4] or 0

  -- TEST bit freezes and resets the oscillator
  if band(ctrl, CTRL_TEST) ~= 0 then
    v.phase = 0
  else
    -- advance phase: freq cycles per clock cycle
    v.phase = u24(v.phase + freq * cycles)
    -- noise LFSR shifts roughly once per cycle (we shift per sample, by a few)
    if band(ctrl, CTRL_NOISE) ~= 0 then
      local shifts = math.max(1, math.floor(cycles))
      local lfsr = v.noise
      for _ = 1, shifts do
        -- 23-bit LFSR, taps at bits 22 and 17 (6581 polynomial)
        local bit22 = band(lfsr, 0x400000) ~= 0 and 1 or 0
        local bit17 = band(lfsr, 0x020000) ~= 0 and 1 or 0
        local fb = bxor(bit22, bit17)
        lfsr = bor(rshift(lfsr, 1), lshift(fb, 22))
        lfsr = band(lfsr, 0x7FFFFF)
      end
      v.noise = lfsr
    end
  end

  -- envelope state machine
  local gate = band(ctrl, CTRL_GATE) ~= 0
  if gate and not v.prev_gate then
    v.env_state = 1  -- attack
    v.env_step_cycles = 0
  elseif (not gate) and v.prev_gate then
    v.env_state = 4  -- release
    v.env_step_cycles = 0
  end
  v.prev_gate = gate

  local ad = self.reg[base + 5] or 0
  local sr = self.reg[base + 6] or 0
  local atk_idx = band(rshift(ad, 4), 0x0F) + 1      -- 1..16
  local dec_idx = band(ad, 0x0F) + 1
  local sus_lvl = band(rshift(sr, 4), 0x0F)          -- 0..15
  local rel_idx = band(sr, 0x0F) + 1
  local sustain_target = sus_lvl * 17                -- 0,17,...,255

  v.env_step_cycles = v.env_step_cycles + cycles
  if v.env_state == 1 then  -- attack: 256 steps total
    local per_step = self.attack_steps[atk_idx] / 256.0
    while v.env_step_cycles >= per_step and v.env_level < 255 do
      v.env_level = v.env_level + 1
      v.env_step_cycles = v.env_step_cycles - per_step
    end
    if v.env_level >= 255 then v.env_state = 2; v.env_step_cycles = 0 end
  elseif v.env_state == 2 then  -- decay: fall to sustain
    local per_step = self.decay_steps[dec_idx]
    while v.env_step_cycles >= per_step and v.env_level > sustain_target do
      v.env_level = v.env_level - 1
      v.env_step_cycles = v.env_step_cycles - per_step
    end
    if v.env_level <= sustain_target then v.env_state = 3 end
  elseif v.env_state == 4 then  -- release: fall to 0
    local per_step = self.decay_steps[rel_idx]
    while v.env_step_cycles >= per_step and v.env_level > 0 do
      v.env_level = v.env_level - 1
      v.env_step_cycles = v.env_step_cycles - per_step
    end
    if v.env_level <= 0 then v.env_state = 0 end
  end
  -- state 3 (sustain): hold, no change
end

-- --- filter ---------------------------------------------------------------
-- Simplified state-variable filter. cutoff/resonance derived from the SID
-- registers; mode (LP/BP/HP) selects which integrator(s) feed the output.
local function filter_sample(self, voice_in, routed)
  if not routed then return voice_in end  -- voice bypasses the filter
  local fclo = self.reg[0x15] or 0
  local fchi = self.reg[0x16] or 0
  local cutoff11 = bor(fclo, lshift(band(fchi, 0x07), 8))  -- 0..2047
  local reso = band(rshift(self.reg[0x17] or 0, 4), 0x0F)  -- 0..15
  local mode = self.reg[0x18] or 0

  -- map cutoff (0..2047) to a normalised frequency 0..~0.5 of sample rate
  -- 6581 cutoff is exponential-ish; we approximate linearly in log space.
  local f = (2.0 ^ ((cutoff11 / 2047.0) * 7.0 - 2.5)) * 0.45  -- tuned range
  if f > 0.49 then f = 0.49 end
  local q = 0.5 + reso * 0.08  -- resonance feedback

  -- SVF: bp = bp + hp*f; lp = lp + bp*f; hp = input - lp - bp*q
  self.f_hp = voice_in - self.f_lp - self.f_bp * q
  self.f_bp = self.f_bp + self.f_hp * f
  self.f_lp = self.f_lp + self.f_bp * f

  local out = 0
  if band(mode, FILT_LP) ~= 0 then out = out + self.f_lp end
  if band(mode, FILT_BP) ~= 0 then out = out + self.f_bp end
  if band(mode, FILT_HP) ~= 0 then out = out + self.f_hp end
  if band(mode, FILT_LP) == 0 and band(mode, FILT_BP) == 0 and band(mode, FILT_HP) == 0 then
    -- no mode selected: pass dry (SID would be silent through filter, but
    -- be forgiving for tunes that route without setting mode)
    out = voice_in
  end
  return out
end

-- --- render n samples ------------------------------------------------------
-- Returns a Lua array (1-indexed) of float samples in roughly [-1, 1].
--
-- Hot path, optimised for pure-Lua: registers do not change during a render
-- call (the player calls play() between frames, then renders one frame's
-- worth), so we cache every register-derived value into locals ONCE and
-- inline the per-voice oscillator/envelope/waveform/filter work into the
-- sample loop. This removes ~9 function calls and ~30 table lookups per
-- sample, which is what makes the difference between unusable and tolerable
-- in an interpreted Lua.
function M:render(n)
  local out = {}
  local cps = self.cycles_per_sample
  local reg = self.reg
  local v1, v2, v3 = self.v[1], self.v[2], self.v[3]
  local muted = self.muted

  -- cache per-voice registers (constant for this whole render call)
  local b1, b2, b3 = 0, 7, 14
  local f1_freq = reg[b1+1] + reg[b1+2]*256
  local f1_ctrl = reg[b1+4]
  local f1_pwlo, f1_pwhi = reg[b1+2], reg[b1+3]
  local f1_pw = f1_pwlo + band(f1_pwhi, 0x0F) * 256
  local f1_atk = band(rshift(reg[b1+5], 4), 0x0F) + 1
  local f1_dec = band(reg[b1+5], 0x0F) + 1
  local f1_sus = band(rshift(reg[b1+6], 4), 0x0F)
  local f1_rel = band(reg[b1+6], 0x0F) + 1
  local f1_sustgt = f1_sus * 17
  local f1_atk_ps = self.attack_steps[f1_atk] / 256.0
  local f1_dec_ps = self.decay_steps[f1_dec]
  local f1_rel_ps = self.decay_steps[f1_rel]
  local f1_wf = band(f1_ctrl, 0xF0)
  local f1_noise = band(f1_ctrl, CTRL_NOISE) ~= 0
  local f1_test  = band(f1_ctrl, CTRL_TEST) ~= 0

  local f2_freq = reg[b2+1] + reg[b2+2]*256
  local f2_ctrl = reg[b2+4]
  local f2_pw = reg[b2+2] + band(reg[b2+3], 0x0F) * 256
  local f2_atk = band(rshift(reg[b2+5], 4), 0x0F) + 1
  local f2_dec = band(reg[b2+5], 0x0F) + 1
  local f2_sus = band(rshift(reg[b2+6], 4), 0x0F)
  local f2_rel = band(reg[b2+6], 0x0F) + 1
  local f2_sustgt = f2_sus * 17
  local f2_atk_ps = self.attack_steps[f2_atk] / 256.0
  local f2_dec_ps = self.decay_steps[f2_dec]
  local f2_rel_ps = self.decay_steps[f2_rel]
  local f2_wf = band(f2_ctrl, 0xF0)
  local f2_noise = band(f2_ctrl, CTRL_NOISE) ~= 0
  local f2_test  = band(f2_ctrl, CTRL_TEST) ~= 0

  local f3_freq = reg[b3+1] + reg[b3+2]*256
  local f3_ctrl = reg[b3+4]
  local f3_pw = reg[b3+2] + band(reg[b3+3], 0x0F) * 256
  local f3_atk = band(rshift(reg[b3+5], 4), 0x0F) + 1
  local f3_dec = band(reg[b3+5], 0x0F) + 1
  local f3_sus = band(rshift(reg[b3+6], 4), 0x0F)
  local f3_rel = band(reg[b3+6], 0x0F) + 1
  local f3_sustgt = f3_sus * 17
  local f3_atk_ps = self.attack_steps[f3_atk] / 256.0
  local f3_dec_ps = self.decay_steps[f3_dec]
  local f3_rel_ps = self.decay_steps[f3_rel]
  local f3_wf = band(f3_ctrl, 0xF0)
  local f3_noise = band(f3_ctrl, CTRL_NOISE) ~= 0
  local f3_test  = band(f3_ctrl, CTRL_TEST) ~= 0

  -- filter registers (constant for this call)
  local fclo, fchi = reg[0x15], reg[0x16]
  local cutoff11 = fclo + band(fchi, 0x07) * 256
  local reso = band(rshift(reg[0x17], 4), 0x0F)
  local mode = reg[0x18]
  local filt1 = band(reg[0x17], 0x01) ~= 0
  local filt2 = band(reg[0x17], 0x02) ~= 0
  local filt3 = band(reg[0x17], 0x04) ~= 0
  local voice3_off = band(mode, FILT_3OFF) ~= 0
  local vol = band(mode, 0x0F)
  local f_sv = (2.0 ^ ((cutoff11 / 2047.0) * 7.0 - 2.5)) * 0.45
  if f_sv > 0.49 then f_sv = 0.49 end
  local q_sv = 0.5 + reso * 0.08
  local has_lp = band(mode, FILT_LP) ~= 0
  local has_bp = band(mode, FILT_BP) ~= 0
  local has_hp = band(mode, FILT_HP) ~= 0
  local any_mode = has_lp or has_bp or has_hp
  local f_lp, f_bp, f_hp = self.f_lp, self.f_bp, self.f_hp

  local vol_scale = vol / 15.0

  -- precompute noise shift count (cycles per sample, floored) once
  local noise_shifts = math.max(1, math.floor(cps))

  for s = 1, n do
    -- ===== voice 1: advance phase + envelope =====
    if f1_test then
      v1.phase = 0
    else
      v1.phase = u24(v1.phase + f1_freq * cps)
      if f1_noise then
        local lfsr = v1.noise
        for _ = 1, noise_shifts do
          local b22 = band(lfsr, 0x400000) ~= 0 and 1 or 0
          local b17 = band(lfsr, 0x020000) ~= 0 and 1 or 0
          lfsr = band(rshift(lfsr, 1) + bxor(b22, b17) * 4194304, 0x7FFFFF)
        end
        v1.noise = lfsr
      end
    end
    local gate1 = band(f1_ctrl, CTRL_GATE) ~= 0
    if gate1 and not v1.prev_gate then v1.env_state = 1; v1.env_step_cycles = 0
    elseif (not gate1) and v1.prev_gate then v1.env_state = 4; v1.env_step_cycles = 0 end
    v1.prev_gate = gate1
    v1.env_step_cycles = v1.env_step_cycles + cps
    if v1.env_state == 1 then
      local ps = f1_atk_ps
      while v1.env_step_cycles >= ps and v1.env_level < 255 do
        v1.env_level = v1.env_level + 1; v1.env_step_cycles = v1.env_step_cycles - ps
      end
      if v1.env_level >= 255 then v1.env_state = 2; v1.env_step_cycles = 0 end
    elseif v1.env_state == 2 then
      local ps = f1_dec_ps
      while v1.env_step_cycles >= ps and v1.env_level > f1_sustgt do
        v1.env_level = v1.env_level - 1; v1.env_step_cycles = v1.env_step_cycles - ps
      end
      if v1.env_level <= f1_sustgt then v1.env_state = 3 end
    elseif v1.env_state == 4 then
      local ps = f1_rel_ps
      while v1.env_step_cycles >= ps and v1.env_level > 0 do
        v1.env_level = v1.env_level - 1; v1.env_step_cycles = v1.env_step_cycles - ps
      end
      if v1.env_level <= 0 then v1.env_state = 0 end
    end

    -- ===== voice 2 =====
    if f2_test then
      v2.phase = 0
    else
      v2.phase = u24(v2.phase + f2_freq * cps)
      if f2_noise then
        local lfsr = v2.noise
        for _ = 1, noise_shifts do
          local b22 = band(lfsr, 0x400000) ~= 0 and 1 or 0
          local b17 = band(lfsr, 0x020000) ~= 0 and 1 or 0
          lfsr = band(rshift(lfsr, 1) + bxor(b22, b17) * 4194304, 0x7FFFFF)
        end
        v2.noise = lfsr
      end
    end
    local gate2 = band(f2_ctrl, CTRL_GATE) ~= 0
    if gate2 and not v2.prev_gate then v2.env_state = 1; v2.env_step_cycles = 0
    elseif (not gate2) and v2.prev_gate then v2.env_state = 4; v2.env_step_cycles = 0 end
    v2.prev_gate = gate2
    v2.env_step_cycles = v2.env_step_cycles + cps
    if v2.env_state == 1 then
      local ps = f2_atk_ps
      while v2.env_step_cycles >= ps and v2.env_level < 255 do
        v2.env_level = v2.env_level + 1; v2.env_step_cycles = v2.env_step_cycles - ps
      end
      if v2.env_level >= 255 then v2.env_state = 2; v2.env_step_cycles = 0 end
    elseif v2.env_state == 2 then
      local ps = f2_dec_ps
      while v2.env_step_cycles >= ps and v2.env_level > f2_sustgt do
        v2.env_level = v2.env_level - 1; v2.env_step_cycles = v2.env_step_cycles - ps
      end
      if v2.env_level <= f2_sustgt then v2.env_state = 3 end
    elseif v2.env_state == 4 then
      local ps = f2_rel_ps
      while v2.env_step_cycles >= ps and v2.env_level > 0 do
        v2.env_level = v2.env_level - 1; v2.env_step_cycles = v2.env_step_cycles - ps
      end
      if v2.env_level <= 0 then v2.env_state = 0 end
    end

    -- ===== voice 3 =====
    if f3_test then
      v3.phase = 0
    else
      v3.phase = u24(v3.phase + f3_freq * cps)
      if f3_noise then
        local lfsr = v3.noise
        for _ = 1, noise_shifts do
          local b22 = band(lfsr, 0x400000) ~= 0 and 1 or 0
          local b17 = band(lfsr, 0x020000) ~= 0 and 1 or 0
          lfsr = band(rshift(lfsr, 1) + bxor(b22, b17) * 4194304, 0x7FFFFF)
        end
        v3.noise = lfsr
      end
    end
    local gate3 = band(f3_ctrl, CTRL_GATE) ~= 0
    if gate3 and not v3.prev_gate then v3.env_state = 1; v3.env_step_cycles = 0
    elseif (not gate3) and v3.prev_gate then v3.env_state = 4; v3.env_step_cycles = 0 end
    v3.prev_gate = gate3
    v3.env_step_cycles = v3.env_step_cycles + cps
    if v3.env_state == 1 then
      local ps = f3_atk_ps
      while v3.env_step_cycles >= ps and v3.env_level < 255 do
        v3.env_level = v3.env_level + 1; v3.env_step_cycles = v3.env_step_cycles - ps
      end
      if v3.env_level >= 255 then v3.env_state = 2; v3.env_step_cycles = 0 end
    elseif v3.env_state == 2 then
      local ps = f3_dec_ps
      while v3.env_step_cycles >= ps and v3.env_level > f3_sustgt do
        v3.env_level = v3.env_level - 1; v3.env_step_cycles = v3.env_step_cycles - ps
      end
      if v3.env_level <= f3_sustgt then v3.env_state = 3 end
    elseif v3.env_state == 4 then
      local ps = f3_rel_ps
      while v3.env_step_cycles >= ps and v3.env_level > 0 do
        v3.env_level = v3.env_level - 1; v3.env_step_cycles = v3.env_step_cycles - ps
      end
      if v3.env_level <= 0 then v3.env_state = 0 end
    end

    -- ===== mix voice outputs (inline waveform lookup) =====
    local mix = 0
    if not muted[1] then
      local p12 = rshift(v1.phase, 12)
      local w = 0
      if f1_wf == CTRL_TRI then w = (p12 < 2048) and p12 or (4095 - p12)
      elseif f1_wf == CTRL_SAW then w = p12
      elseif f1_wf == CTRL_PULSE then w = (p12 < f1_pw) and 4095 or 0
      elseif f1_wf == CTRL_NOISE then w = band(rshift(v1.noise, 4), 0xFFF)
      elseif f1_wf ~= 0 then
        -- combined waveforms: AND of present ones
        local acc
        if band(f1_ctrl, CTRL_TRI)   ~= 0 then acc = (p12 < 2048) and p12 or (4095 - p12) end
        if band(f1_ctrl, CTRL_SAW)   ~= 0 then acc = (acc == nil) and p12 or band(acc, p12) end
        if band(f1_ctrl, CTRL_PULSE) ~= 0 then local pp = (p12 < f1_pw) and 4095 or 0; acc = (acc == nil) and pp or band(acc, pp) end
        if band(f1_ctrl, CTRL_NOISE) ~= 0 then local nn = band(rshift(v1.noise, 4), 0xFFF); acc = (acc == nil) and nn or band(acc, nn) end
        w = acc or 0
      end
      local s1 = w * (v1.env_level / 255.0)
      if filt1 and any_mode then
        f_hp = s1 - f_lp - f_bp * q_sv
        f_bp = f_bp + f_hp * f_sv
        f_lp = f_lp + f_bp * f_sv
        local o = 0
        if has_lp then o = o + f_lp end
        if has_bp then o = o + f_bp end
        if has_hp then o = o + f_hp end
        mix = mix + o
      else
        mix = mix + s1
      end
    end
    if not muted[2] then
      local p12 = rshift(v2.phase, 12)
      local w = 0
      if f2_wf == CTRL_TRI then w = (p12 < 2048) and p12 or (4095 - p12)
      elseif f2_wf == CTRL_SAW then w = p12
      elseif f2_wf == CTRL_PULSE then w = (p12 < f2_pw) and 4095 or 0
      elseif f2_wf == CTRL_NOISE then w = band(rshift(v2.noise, 4), 0xFFF)
      elseif f2_wf ~= 0 then
        local acc
        if band(f2_ctrl, CTRL_TRI)   ~= 0 then acc = (p12 < 2048) and p12 or (4095 - p12) end
        if band(f2_ctrl, CTRL_SAW)   ~= 0 then acc = (acc == nil) and p12 or band(acc, p12) end
        if band(f2_ctrl, CTRL_PULSE) ~= 0 then local pp = (p12 < f2_pw) and 4095 or 0; acc = (acc == nil) and pp or band(acc, pp) end
        if band(f2_ctrl, CTRL_NOISE) ~= 0 then local nn = band(rshift(v2.noise, 4), 0xFFF); acc = (acc == nil) and nn or band(acc, nn) end
        w = acc or 0
      end
      local s2 = w * (v2.env_level / 255.0)
      if filt2 and any_mode then
        f_hp = s2 - f_lp - f_bp * q_sv
        f_bp = f_bp + f_hp * f_sv
        f_lp = f_lp + f_bp * f_sv
        local o = 0
        if has_lp then o = o + f_lp end
        if has_bp then o = o + f_bp end
        if has_hp then o = o + f_hp end
        mix = mix + o
      else
        mix = mix + s2
      end
    end
    if not muted[3] and not voice3_off then
      local p12 = rshift(v3.phase, 12)
      local w = 0
      if f3_wf == CTRL_TRI then w = (p12 < 2048) and p12 or (4095 - p12)
      elseif f3_wf == CTRL_SAW then w = p12
      elseif f3_wf == CTRL_PULSE then w = (p12 < f3_pw) and 4095 or 0
      elseif f3_wf == CTRL_NOISE then w = band(rshift(v3.noise, 4), 0xFFF)
      elseif f3_wf ~= 0 then
        local acc
        if band(f3_ctrl, CTRL_TRI)   ~= 0 then acc = (p12 < 2048) and p12 or (4095 - p12) end
        if band(f3_ctrl, CTRL_SAW)   ~= 0 then acc = (acc == nil) and p12 or band(acc, p12) end
        if band(f3_ctrl, CTRL_PULSE) ~= 0 then local pp = (p12 < f3_pw) and 4095 or 0; acc = (acc == nil) and pp or band(acc, pp) end
        if band(f3_ctrl, CTRL_NOISE) ~= 0 then local nn = band(rshift(v3.noise, 4), 0xFFF); acc = (acc == nil) and nn or band(acc, nn) end
        w = acc or 0
      end
      local s3 = w * (v3.env_level / 255.0)
      if filt3 and any_mode then
        f_hp = s3 - f_lp - f_bp * q_sv
        f_bp = f_bp + f_hp * f_sv
        f_lp = f_lp + f_bp * f_sv
        local o = 0
        if has_lp then o = o + f_lp end
        if has_bp then o = o + f_bp end
        if has_hp then o = o + f_hp end
        mix = mix + o
      else
        mix = mix + s3
      end
    end

    out[s] = (mix / 4095.0) * vol_scale
  end

  -- persist the filter integrators back
  self.f_lp, self.f_bp, self.f_hp = f_lp, f_bp, f_hp
  return out
end

-- set per-voice mute (the sidlove mute(sid,voice,on) API)
function M:set_mute(voice, on)
  if voice >= 1 and voice <= 3 then self.muted[voice] = on end
end

-- snapshot of registers for the visualiser / debugger
function M:regs()
  local t = {}
  for i = 0, 0x1F do t[i] = self.reg[i] end
  return t
end

return M
