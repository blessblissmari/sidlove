-- raster.lua - C64 raster-IRQ sync for demoscene-style music↔video coupling.
--
-- On a real C64 the music player's play routine is called from a raster IRQ
-- that fires once per video frame (~50 Hz PAL / ~60 Hz NTSC). Visual effects
-- (raster bars, scroll text, sprite multiplex) are timed against that same
-- raster, so music and graphics are inherently in lock-step.
--
-- In Love2D love.update(dt) runs at the monitor refresh (usually 60 Hz) and
-- is decoupled from the audio clock. This module restores the C64-style
-- coupling:
--   * It derives the play-rate from the SID engine's CIA timer (if a SID is
--     playing) or from the tune's declared video clock (50/60 Hz for NSF).
--   * It calls user callbacks at that rate, in sub-frame steps if the game's
--     vsync is faster than the C64 clock (so a PAL tune still runs at 50 Hz
--     on a 60 Hz monitor without drift).
--   * It snapshots the SID register state on each "play tick" and exposes
--     it for visuals (e.g. draw 25 vertical bars whose heights come from
--     the 24 SID registers, like a real C64 oscilloscope display).
--
-- It is purely advisory - it never writes to the player. Use it to drive
-- visuals, not to advance the music.

local sid_ffi = require("sidlove.ffi.sid_ffi")

local M = {}
M.__index = M

-- Canonical C64 clocks (Hz) and video refreshes (Hz).
M.CLOCK_PAL  = 985248.0
M.CLOCK_NTSC = 1022727.5
M.FPS_PAL    = 50.0       -- exactly 50.125, but 50 is the musical convention
M.FPS_NTSC   = 60.0       -- 59.826 real, 60 convention

-- opts:
--   player  -> a SID or chiptune player (for CIA timer / clock detection)
--   clock   -> "pal" / "ntsc" / nil (auto from player)
--   on_tick -> callback(dt, frame_no) called at the play rate
function M.new(opts)
  opts = opts or {}
  local clock = opts.clock or "pal"
  local fps = (clock == "ntsc") and M.FPS_NTSC or M.FPS_PAL
  local self = setmetatable({
    player = opts.player,
    fps = fps,
    on_tick = opts.on_tick,
    _acc = 0,
    _frame = 0,
    _last_status = nil,
    _last_cia = 0,
  }, M)
  -- If a SID player is attached, refine the fps from the CIA timer once we
  -- have one (the play routine's actual rate, not the video rate).
  return self
end

-- Decide the play rate. If the player is a SID and has a CIA timer loaded,
-- the play rate = clock_hz / (cia_timer + 2). Otherwise fall back to the
-- video clock (50/60 Hz).
function M:_rate()
  local p = self.player
  if p and p.kind == "sid" and p.cia_timer then
    local cia = p:cia_timer()
    if cia and cia > 0 then
      local clock = (self.fps == M.FPS_NTSC) and M.CLOCK_NTSC or M.CLOCK_PAL
      return clock / (cia + 2)
    end
  end
  return self.fps
end

-- Called from love.update(dt). Distributes the elapsed time across play
-- ticks at the derived rate; fires on_tick for each. Also caches the SID
-- register snapshot at the start of each tick so visual callbacks read a
-- stable value.
function M:update(dt)
  local rate = self:_rate()
  self._acc = self._acc + dt
  local period = 1.0 / rate
  local guard = 0
  while self._acc >= period and guard < 8 do
    self._acc = self._acc - period
    self._frame = self._frame + 1
    local p = self.player
    if p and p.kind == "sid" then
      self._last_status = p:sid_status(0)
      self._last_cia = p:cia_timer()
    end
    if self.on_tick then self.on_tick(period, self._frame) end
    guard = guard + 1   -- avoid spiral of death if dt was huge
  end
end

-- Read the SID register snapshot cached at the last tick. Returns a 1..32
-- Lua array of byte values, or nil if no SID player is attached.
function M:sid_status() return self._last_status end
function M:cia_timer() return self._last_cia end
function M:frame() return self._frame end

-- Convenience: return the 25 standard SID registers (0x00..0x18) as a table
-- keyed by register name. Useful for drawing the chip state.
local REG_NAMES = {
  [0]="v1freq_lo",[1]="v1freq_hi",[2]="v1pw_lo",[3]="v1pw_hi",
  [4]="v1ctrl",[5]="v1atkdec",[6]="v1susrel",
  [7]="v2freq_lo",[8]="v2freq_hi",[9]="v2pw_lo",[10]="v2pw_hi",
  [11]="v2ctrl",[12]="v2atkdec",[13]="v2susrel",
  [14]="v3freq_lo",[15]="v3freq_hi",[16]="v3pw_lo",[17]="v3pw_hi",
  [18]="v3ctrl",[19]="v3atkdec",[20]="v3susrel",
  [21]="fc_lo",[22]="fc_hi",[23]="fresmode",[24]="volume",
}
function M:sid_named()
  local s = self._last_status
  if not s then return nil end
  local t = {}
  for i = 0, 24 do t[REG_NAMES[i] or tostring(i)] = s[i + 1] end
  return t
end

return setmetatable(M, { __call = function(_, ...) return M.new(...) end })
