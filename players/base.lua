-- players/base.lua - the common Player interface. Each engine's player
-- module (sid_player, chiptune_player, midi_player) inherits from this.
--
-- The interface every player implements (called by streamer.lua):
--   player.sampleRate      -> number (Hz)
--   player.channels        -> 1 (mono) or 2 (stereo)
--   player.bitDepth        -> 16 (we always work in s16; Love2D converts)
--   player:fillFrames(n)   -> fills self._scratch (a SoundData) with n frames
--                             and returns it. May return fewer than n if the
--                             source ran out (end of tune).
--   player:playing()       -> bool
--   player:play()          -> start / resume
--   player:stop()          -> stop (clears voices)
--   player:tell()          -> current position in ms
--   player:seek(ms)        -> seek
--   player:setLoop(on)     -> enable infinite loop (default true for game bgm)
--   player:dispose()       -> free native resources
--
-- A "frame" = one audio sample point per channel. For stereo, n frames
-- means 2*n int16 in the interleaved buffer.

local M = {}
M.__index = M

function M.new(opts)
  local self = setmetatable({}, M)
  self.sampleRate = opts.sampleRate or 44100
  self.channels   = opts.channels   or 2
  self.bitDepth   = 16
  self._loop      = true
  self._playing   = false
  self._disposed  = false
  return self
end

-- Default no-ops; overridden by subclasses.
function M:play() self._playing = true end
function M:stop() self._playing = false end
function M:playing() return self._playing end
function M:tell() return 0 end
function M:seek(ms) end
function M:setLoop(on) self._loop = on and true or false end
function M:setVolume(v) self._volume = v end

-- Dispose must be idempotent.
function M:dispose()
  if self._disposed then return end
  self._disposed = true
  self._playing = false
end

return M
