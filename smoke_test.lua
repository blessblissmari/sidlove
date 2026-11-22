-- smoke_test.lua - headless verification of the sidlove engines.
-- Runs without LÖVE (plain LuaJIT), renders 2 seconds of each engine to
-- a WAV file. Use this to confirm your native libraries load correctly
-- on a new platform before wiring the library into your game.
--
-- Run:  luajit smoke_test.lua
-- (or:  love sidlove --smoke-test   if you adapt the runner)
--
-- Requires: the native/<tag>/ directory populated (see README.md).
-- For the MIDI test, set the SF env var to a .sf2 path, or put one at
-- sidlove/assets/GeneralUser.sf2.

local ffi = require("ffi")
local sidlove = require("sidlove")

-- LuaJIT (Love2D 11.x) has no string.pack (that's Lua 5.3+). Build the
-- 44-byte WAV header with ffi and write it in one shot.
local function write_wav_header(f, sr, channels, data_bytes)
  local h = ffi.new("uint8_t[44]")
  local function u32(off, v)
    h[off]   = bit.band(v, 0xff)
    h[off+1] = bit.band(bit.rshift(v, 8), 0xff)
    h[off+2] = bit.band(bit.rshift(v, 16), 0xff)
    h[off+3] = bit.band(bit.rshift(v, 24), 0xff)
  end
  local function u16(off, v)
    h[off]   = bit.band(v, 0xff)
    h[off+1] = bit.band(bit.rshift(v, 8), 0xff)
  end
  ffi.copy(h + 0, "RIFF", 4)
  u32(4, 36 + data_bytes)
  ffi.copy(h + 8, "WAVE", 4)
  ffi.copy(h + 12, "fmt ", 4)
  u32(16, 16)
  u16(20, 1)
  u16(22, channels)
  u32(24, sr)
  u32(28, sr * channels * 2)
  u16(32, channels * 2)
  u16(34, 16)
  ffi.copy(h + 36, "data", 4)
  u32(40, data_bytes)
  f:write(ffi.string(h, 44))
end

local function fail(msg) io.stderr:write("FAIL: ", msg, "\n") os.exit(1) end

print("=== sidlove smoke test ===")
local ok, err = sidlove.init()
if not ok then fail("sidlove.init: "..tostring(err)) end
print(string.format("platform: %s/%s  tag=%s", sidlove.platform_info.os,
    sidlove.platform_info.arch, sidlove.platform_info.tag))
print(string.format("engines: sid=%s chiptune=%s midi=%s",
    sidlove.engines.sid, sidlove.engines.chiptune, sidlove.engines.midi))

local SR, SECONDS = 44100, 2
local FRAMES_PER_BLOCK = 1024
local out = ffi.new("int16_t[?]", FRAMES_PER_BLOCK * 2)

-- --- SID ---
if sidlove.engines.sid then
  print("\n[SID] loading assets/test.psid ...")
  local p, e = sidlove.load("sidlove/assets/test.psid",
      { sampleRate = SR, sid_model = sidlove.SID.MODEL_AUTO })
  if not p then fail("SID load: "..tostring(e)) end
  local info = p:info()
  print(string.format("  tune: %s / %s / songs=%d load=$%04X",
      info.format, info.title, info.songs, info.load_addr))
  p:setLoop(true); p:play()
  local total, peak = 0, 0
  local f = io.open("sidlove_smoke_sid.wav", "wb")
  -- write header first (we know total frames)
  write_wav_header(f, SR, 2, SECONDS*SR*4)
  while total < SR * SECONDS do
    local want = math.min(FRAMES_PER_BLOCK, SR*SECONDS - total)
    local got = p:fill_into(out, want)
    for i = 0, got*2-1 do
      local v = math.abs(out[i])
      if v > peak then peak = v end
    end
    f:write(ffi.string(out, got*2*2))
    total = total + got
  end
  f:close()
  p:dispose()
  print(string.format("  wrote sidlove_smoke_sid.wav (%d frames, peak=%d/32767 = %.1f%%)",
      total, peak, 100*peak/32767))
end

-- --- Chiptune ---
if sidlove.engines.chiptune then
  print("\n[Chiptune] loading assets/test.gbs ...")
  local p, e = sidlove.load("sidlove/assets/test.gbs", { sampleRate = SR })
  if not p then fail("Chiptune load: "..tostring(e)) end
  p:start_track(0); p:setLoop(true); p:play()
  local total, peak = 0, 0
  local f = io.open("sidlove_smoke_gme.wav", "wb")
  write_wav_header(f, SR, 2, SECONDS*SR*4)
  while total < SR * SECONDS do
    local want = math.min(FRAMES_PER_BLOCK, SR*SECONDS - total)
    local got = p:fill_into(out, want)
    for i = 0, got*2-1 do
      local v = math.abs(out[i])
      if v > peak then peak = v end
    end
    f:write(ffi.string(out, got*2*2))
    total = total + got
  end
  f:close()
  p:dispose()
  print(string.format("  wrote sidlove_smoke_gme.wav (%d frames, peak=%d/32767 = %.1f%%)",
      total, peak, 100*peak/32767))
end

-- --- MIDI ---
if sidlove.engines.midi then
  local sf = os.getenv("SF") or "sidlove/assets/GeneralUser.sf2"
  local sf_probe = io.open(sf, "rb")
  if sf_probe then
    sf_probe:close()
    print("\n[MIDI] loading SF="..sf.." ...")
    -- Live mode: synthesize a C-major arpeggio without a .mid file.
    local p, e = sidlove.MIDI{ sampleRate = SR }
    if not p then fail("MIDI new: "..tostring(e)) end
    local id, e2 = p:load_soundfont(sf)
    if not id then fail("MIDI sfload: "..tostring(e2)) end
    p:program_select(0, 0, 0)  -- bank 0 preset 0 (piano)
    local notes = {60, 64, 67, 72}
    local idx = 1
    p:noteon(0, notes[1], 100)
    p:play()
    local total, peak = 0, 0
    local f = io.open("sidlove_smoke_fluid.wav", "wb")
    write_wav_header(f, SR, 2, SECONDS*SR*4)
    local frames_per_note = SR / 2
    while total < SR * SECONDS do
      local want = math.min(FRAMES_PER_BLOCK, SR*SECONDS - total)
      local got = p:fill_into(out, want)
      for i = 0, got*2-1 do
        local v = math.abs(out[i])
        if v > peak then peak = v end
      end
      f:write(ffi.string(out, got*2*2))
      total = total + got
      if total % frames_per_note < FRAMES_PER_BLOCK then
        local next_idx = math.floor(total / frames_per_note) + 1
        if next_idx ~= idx and next_idx <= #notes then
          p:noteoff(0, notes[idx])
          idx = next_idx
          p:noteon(0, notes[idx], 100)
        end
      end
    end
    f:close()
    p:dispose()
    print(string.format("  wrote sidlove_smoke_fluid.wav (%d frames, peak=%d/32767 = %.1f%%)",
        total, peak, 100*peak/32767))
  else
    print("\n[MIDI] skipped (no soundfont at "..sf.."; set SF env var)")
  end
end

print("\n=== smoke test complete ===")
