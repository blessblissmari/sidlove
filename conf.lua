-- conf.lua - LÖVE configuration for the sidlove demo.
-- This makes `love .` (run in the cloned repo root) open a titled window.
function love.conf(t)
  t.window.title   = "sidlove v2.0 — SID/chiptune/MIDI demo"
  t.window.width   = 900
  t.window.height  = 600
  t.window.vsync   = 1
  -- The demo needs audio + the standard modules; keep the rest off so it
  -- starts fast and runs in love.js too.
  t.modules.physics = false
  t.modules.video   = false
  t.identity = "sidlove"
  t.version  = "11.3"
end
