-- init.lua - sidlove public API. require("sidlove") returns this table.
--
-- Usage:
--   local sidlove = require("sidlove")
--   sidlove.init()                              -- detect platform, load native libs
--   local s = sidlove.Streamer{ player = sidlove.load("song.sid") }
--   function love.update(dt) s:update(dt) end
--
-- The library is low-level by design: each engine (SID/chiptune/MIDI) is a
-- player module with a fill_into() method, and the Streamer pumps it into
-- Love2D's audio. Demoscene helpers (Filter, Sample, Raster) are opt-in.

local platform         = require("sidlove.platform")
local sid_player       = require("sidlove.players.sid_player")
local chiptune_player  = require("sidlove.players.chiptune_player")
local midi_player      = require("sidlove.players.midi_player")
local Streamer         = require("sidlove.streamer")
local Filter           = require("sidlove.filter")
local Sample           = require("sidlove.sample_player")
local Raster           = require("sidlove.raster")

local M = {}

-- Re-export modules so user code can do sidlove.SID / sidlove.MIDI / etc.
M.SID    = sid_player
M.CHIP   = chiptune_player
M.MIDI   = midi_player
M.Streamer = Streamer
M.Filter   = Filter
M.Sample   = Sample
M.Raster   = Raster
M.platform = platform

-- Engine availability flags (set after init()).
M.engines = { sid = false, chiptune = false, midi = false }

-- Load native libraries. Call once at startup, before any player is created.
-- opts.native_root (optional) overrides the native/<tag> directory.
-- Returns true on success (at least one engine loaded) or nil + error.
function M.init(opts)
  opts = opts or {}
  local p, err = platform.init(opts.native_root)
  if not p then return nil, err end
  M.engines.sid      = platform.engines.sid
  M.engines.chiptune = platform.engines.gme
  M.engines.midi     = platform.engines.fluid
  M.platform_info = { os = platform.os, arch = platform.arch, tag = platform.tag,
                      dir = platform.dir }
  if not (M.engines.sid or M.engines.chiptune or M.engines.midi) then
    return nil, "sidlove: no audio engines loaded (native libs not found in "
                .. tostring(platform.dir) .. ")"
  end
  return true
end

-- File-format sniffing. The first 4 bytes distinguish SID, PSID/RSID, NSF,
-- NSFE, SAP, VGM, SPC, GBS, AY, HES, KSS. .mid is detected by extension /
-- "MThd" header. Returns one of: "sid", "chiptune", "midi", nil.
local function sniff(data, ext)
  if not data or #data < 4 then
    -- fall back to extension
    if ext == "sid" or ext == "prg" or ext == "mus" then return "sid" end
    if ext == "mid" or ext == "midi" then return "midi" end
    return nil
  end
  local h = data:sub(1, 4)
  if h == "PSID" or h == "RSID" then return "sid" end
  if h == "MThd" then return "midi" end
  -- chiptune signatures:
  if h == "NESM" or h == "NSFE" then return "chiptune" end  -- NSF / NSFE
  if h:sub(1,2) == "Vg" then return "chiptune" end          -- VGM/VGZ
  if data:sub(1,37) == "SAP\r\nAUTHOR " then return "chiptune" end  -- SAP
  if h == "SNES" then return "chiptune" end                 -- SPC (SPC700)
  if data:sub(1,3) == "GBS" then return "chiptune" end
  if data:sub(1,2) == "AY" then return "chiptune" end
  if h == "HESM" then return "chiptune" end
  if h == "KSSX" then return "chiptune" end
  -- .prg has no magic - it's raw C64 code with a 2-byte load address
  if ext == "prg" then return "sid" end
  if ext == "sid" then return "sid" end
  if ext == "mid" or ext == "midi" then return "midi" end
  return nil
end

-- Auto-load: sniff the file, pick the right engine, instantiate + load.
-- opts is passed through to the player constructor.
-- Returns (player, kind) on success, (nil, err) on failure.
function M.load(path, opts)
  opts = opts or {}
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  local ext = path:match("%.([^./\\]+)$") or ""
  ext = ext:lower()
  local kind = sniff(data, ext)
  if not kind then
    return nil, "sidlove: unrecognised file format for " .. path
  end
  return M.load_buffer(data, kind, opts)
end

-- Load from memory. data is a Lua string. kind is "sid"/"chiptune"/"midi".
function M.load_buffer(data, kind, opts)
  opts = opts or {}
  local ffi = require("ffi")
  local n = #data
  local cbuf = ffi.new("uint8_t[?]", n + 1, data)
  local player, perr
  if kind == "sid" then
    if not M.engines.sid then return nil, "SID engine not loaded" end
    player, perr = sid_player(opts)
    if player then
      local ok, e = player:load_buffer(cbuf, n)
      if not ok then player:dispose(); return nil, e end
    end
  elseif kind == "chiptune" then
    if not M.engines.chiptune then return nil, "chiptune engine not loaded" end
    player, perr = chiptune_player(opts)
    if player then
      local ok, e = player:load_buffer(cbuf, n)
      if not ok then player:dispose(); return nil, e end
      player:start_track(opts.track or 0)
    end
  elseif kind == "midi" then
    if not M.engines.midi then return nil, "MIDI engine not loaded" end
    player, perr = midi_player(opts)
    if player then
      if opts.soundfont then
        local sfid, e = player:load_soundfont(opts.soundfont)
        if not sfid then player:dispose(); return nil, e end
      else
        return nil, "midi: opts.soundfont (.sf2/.sf3) required"
      end
      local ok, e = player:add_midi_buffer(cbuf, n)
      if not ok then player:dispose(); return nil, e end
    end
  else
    return nil, "unknown kind: " .. tostring(kind)
  end
  if not player then return nil, perr end
  player._kind = kind
  return player, kind
end

-- Convenience: build a Streamer around a player in one call.
function M.play(player, opts)
  return Streamer(opts and opts.streamer or {})
end

-- Version + engine info, for diagnostics / splash screens.
M.VERSION = "0.1.0"
function M.info()
  return {
    version = M.VERSION,
    platform = M.platform_info,
    engines = M.engines,
  }
end

return M
