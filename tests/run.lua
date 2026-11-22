-- tests/run.lua - sidlove test suite. Plain Lua, no LÖVE, no network.
--
-- Run it with any of:
--   luajit tests/run.lua        (from the repo root)
--   lua5.1  tests/run.lua       (pure-Lua path, what love.js uses)
--   bash run_tests.sh           (picks the first interpreter available)
--
-- Everything here is engine-agnostic: tests that touch the native engines
-- pass on LuaJIT (where the bundled .so files load) AND on plain Lua 5.1
-- (where the pure-Lua SID engine runs), so the whole suite must be green
-- on both before a change ships.

local here = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "."
local ROOT = here .. "/.."
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

-- --- tiny test framework ----------------------------------------------------
local pass_n, fail_n = 0, 0
local failures = {}
local group_name = ""

local function group(name)
  group_name = name
  print("\n== " .. name .. " ==")
end

local function ok(cond, msg)
  if cond then
    pass_n = pass_n + 1
  else
    fail_n = fail_n + 1
    failures[#failures + 1] = group_name .. " :: " .. msg
    print("  FAIL: " .. msg)
  end
end

local function eq(actual, expected, msg)
  ok(actual == expected, (msg or "") .. " (expected " ..
     tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

local function near(actual, expected, tol, msg)
  ok(math.abs(actual - expected) <= tol, (msg or "") .. " (expected " ..
     tostring(expected) .. " ±" .. tostring(tol) .. ", got " .. tostring(actual) .. ")")
end

local function perr(fn, msg)
  local okpc, err = pcall(fn)
  ok(not okpc, (msg or "") .. " (error: " .. tostring(err) .. ")")
  return err
end

local have_ffi, ffi = pcall(require, "ffi")
local bit = require("sidlove.bit")

-- ============================================================================
group("bit.lua - bitwise ops (fallback on Lua 5.1, real lib on LuaJIT)")

eq(bit.band(0xF0F0, 0x0FF0), 0x00F0, "band")
eq(bit.bor(0xF0, 0x0F), 0xFF, "bor")
eq(bit.bxor(0xFF, 0x0F), 0xF0, "bxor")
eq(bit.bnot(0), -1, "bnot(0) is -1 (LuaJIT signed convention)")
eq(bit.band(0xFF, 0x0F, 0x03), 0x03, "band is variadic")
eq(bit.bor(0x10, 0x20, 0x40), 0x70, "bor is variadic")
eq(bit.lshift(1, 31), -2147483648, "lshift into sign bit returns signed")
eq(bit.lshift(1, 32), 1, "shift count wraps mod 32")
eq(bit.lshift(-1, 8), -256, "lshift of negative input")
eq(bit.rshift(0x80000000, 31), 1, "rshift is logical")
eq(bit.arshift(-16, 2), -4, "arshift sign-extends negative")
eq(bit.arshift(-1, 1), -1, "arshift(-1,1) stays -1")
eq(bit.arshift(16, 2), 4, "arshift of positive")
eq(bit.rol(0x80000001, 1), 3, "rol")
eq(bit.ror(3, 1), -2147483647, "ror wraps into bit 31 (signed result)")
eq(bit.tobit(-1), -1, "tobit keeps -1")
eq(bit.tobit(4294967296 + 5), 5, "tobit wraps mod 2^32")
eq(bit.tohex(255), "000000ff", "tohex full width (lowercase, like LuaJIT)")
eq(bit.tohex(255, 2), "ff", "tohex truncated")

-- algebraic identities hold for the real lib and the fallback alike
for _, x in ipairs({0, 1, 0x7FFFFFFF, -2147483648, -1, 0x12345678}) do
  eq(bit.band(x, 0xFFFFFFFF), bit.tobit(x), "band identity x&~0 = x")
  eq(bit.bor(x, 0), bit.tobit(x), "bor identity x|0 = x")
  eq(bit.bxor(x, x), 0, "bxor identity x^x = 0")
  eq(bit.bxor(x, 0xFFFFFFFF), bit.bnot(x), "bxor identity x^~0 = ~x")
end

-- the 8-bit ops must exist on EVERY path (m6502.lua destructures them)
ok(type(bit.band8) == "function" and type(bit.bor8) == "function"
   and type(bit.bxor8) == "function", "band8/bor8/bxor8 exported on this Lua")
eq(bit.band8(0xF0, 0x0F), 0x00, "band8")
eq(bit.band8(0xF0, 0xF0), 0xF0, "band8 same bits")
eq(bit.bor8(0xA0, 0x0B), 0xAB, "bor8")
eq(bit.bxor8(0xAA, 0xFF), 0x55, "bxor8")
for a = 0, 255 do
  ok(bit.band8(a, 0x55) == bit.band(a, 0x55),
     "band8 agrees with band32 on " .. a)
end

-- ============================================================================
group("m6502 - CPU core (hand-assembled program)")

local CPU = require("sidlove.m6502")
local cpu = CPU.new()
local ram = {}
cpu.read  = function(a) return ram[a] or 0 end
cpu.write = function(a, v) ram[a] = bit.band(v, 0xFF) end

-- Program (org 0x0200):
--   LDA #$05 ; CLC ; ADC #$03 ; STA $0400        A=8
--   LDA #$FF ; ADC #$01 ; STA $0401              A=0, C=1, Z=1
--   LDA #$F0 ; ORA #$0F ; AND #$0F ; EOR #$FF    A=F0, N=1
--   TAX ; INX ; DEX ; TAY ; INY ; DEY            X=F0 Y=F0
--   SEC ; LDA #$10 ; SBC #$01 ; CMP #$10         A=0F, C=0 (borrow), N=0
--   CPX #$F0                                     Z=1 C=1
--   BEQ +2 (skip LDA #$FF)
--   JMP $022A  (jump to itself; spins until the budget runs out)
local prog = {
  0xA9,0x05, 0x18, 0x69,0x03, 0x8D,0x00,0x04,
  0xA9,0xFF, 0x69,0x01, 0x8D,0x01,0x04,
  0xA9,0xF0, 0x09,0x0F, 0x29,0x0F, 0x49,0xFF,
  0xAA, 0xE8, 0xCA, 0xA8, 0xC8, 0x88,
  0x38, 0xA9,0x10, 0xE9,0x01, 0xC9,0x10,
  0xE0,0xF0,
  0xF0,0x02,
  0xA9,0xFF,
  0x4C,0x2A,0x02,   -- self-jump: JMP is at $022A, so this loops in place
}
for i, b in ipairs(prog) do ram[0x0200 + i - 1] = b end
cpu.PC = 0x0200
cpu:run(2000)

eq(ram[0x0400], 0x08, "ADC 5+3 stored")
eq(ram[0x0401], 0x00, "ADC FF+1 wraps to 0")
eq(cpu.A, 0x0F, "SBC 10-1 = 0F")
eq(cpu.X, 0xF0, "TAX/INX/DEX")
eq(cpu.Y, 0xF0, "TAY/INY/DEY")
eq(bit.band(cpu.P, 0x02), 0x02, "Z set by CPX #$F0")
eq(bit.band(cpu.P, 0x01), 0x01, "C set by CPX (X >= operand)")
eq(bit.band(cpu.P, 0x80), 0x00, "N clear after CMP #$10 vs A=0F")
ok(cpu.cycles > 0, "cycle counter advanced")

-- JSR/RTS through the jsr() entry point (what the SID player uses)
ram[0x0300] = 0x8D; ram[0x0301] = 0x02; ram[0x0302] = 0x04  -- STA $0402
ram[0x0303] = 0x60                                           -- RTS
cpu:jsr(0x0300, 0x42)
eq(ram[0x0402], 0x42, "jsr(addr, A) passes A and returns")
eq(cpu.A, 0x42, "A preserved after RTS")

-- ============================================================================
group("sidchip - SID voice/envelope core")

local SID = require("sidlove.sidchip")
local GATE, TRI, SAW, PULSE, NOISE = 0x01, 0x10, 0x20, 0x40, 0x80

local function peak_of(samples)
  local p = 0
  for _, v in ipairs(samples) do
    local a = math.abs(v)
    if a > p then p = a end
  end
  return p
end

local sid = SID.new(985248, 44100)  -- PAL clock
ok(sid ~= nil, "SID.new constructs")

-- full-volume triangle: attack 0, decay 0, sustain 15, release 0
sid:write(0, 0xF4); sid:write(1, 0x11)        -- freq ~$11F4
sid:write(5, 0x00); sid:write(6, 0xF0)        -- AD=0, SR=$F0 (sustain 15)
sid:write(4, bit.bor(GATE, TRI))

local out = sid:render(4410)                   -- 0.1 s
eq(#out, 4410, "render(n) returns n samples")
local pk = peak_of(out)
ok(pk > 0.05, "gated triangle is audible (peak " .. string.format("%.3f", pk) .. ")")
ok(pk <= 1.0, "samples stay within [-1,1]")

-- regs() is 1-indexed like the native engine: index r+1 = register r
local regs = sid:regs()
eq(regs[1], 0xF4, "regs()[1] = voice1 freq lo (reg 0)")
eq(regs[2], 0x11, "regs()[2] = voice1 freq hi (reg 1)")
eq(regs[6], 0x00, "regs()[6] = attack/decay (reg 5)")
eq(regs[7], 0xF0, "regs()[7] = sustain/release (reg 6)")
eq(regs[5], bit.bor(GATE, TRI), "regs()[5] = voice1 ctrl (reg 4)")

-- mute silences the voice
sid:set_mute(1, true)
local muted = sid:render(2205)
ok(peak_of(muted) < 0.001, "set_mute silences voice 1")
sid:set_mute(1, false)

-- gate off with release=0 -> silence within ~10ms
sid:write(4, 0x00)
local released = sid:render(2205)
ok(peak_of(released) < 0.05, "gate off releases to near-silence (peak " ..
    string.format("%.3f", peak_of(released)) .. ")")

-- noise waveform is audible and stays in range
sid:write(5, 0x00); sid:write(6, 0xF0)
sid:write(4, bit.bor(GATE, NOISE))
local noise = sid:render(2205)
ok(peak_of(noise) > 0.02, "noise waveform audible")
ok(peak_of(noise) <= 1.0, "noise in range")

sid:reset()
ok(peak_of(sid:render(441)) < 0.001, "reset silences the chip")

-- ============================================================================
group("sid_pure_player - PSID parse + render (the love.js engine)")

local pure = require("sidlove.players.sid_pure_player")
local psid_data = (function()
  local f = io.open(ROOT .. "/sidlove/assets/test.psid", "rb")
  if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end)()
ok(psid_data and #psid_data > 0x80, "bundled test.psid readable")

local p = pure{ sampleRate = 44100, channels = 2 }   -- constructor sugar
ok(p ~= nil, "pure player constructor callable")
-- regression: the module tail used to clobber the base-chain metatable, so
-- inherited methods (play/setLoop/playing/tell) resolved to nil
ok(p.play and p.stop and p.setLoop and p.playing and p.tell,
   "pure player inherits base methods (play/stop/setLoop/playing/tell)")
eq(p:load_buffer_str(psid_data), true, "load_buffer_str accepts the tune")

local info = p:info()
ok(info.songs and info.songs >= 1, "info().songs = " .. tostring(info.songs))
ok(info.load_addr and info.load_addr > 0, "info().load_addr = $" ..
    string.format("%04X", info.load_addr or 0))
eq(info.clock, "PAL", "info().clock")

eq(p:select_song(1), true, "select_song(1)")
eq(p:select_song(999), true, "select_song(999) clamps without error")

p:play()
local mono = p:render(4410)
eq(#mono, 4410, "render(n) length")
local ppk = peak_of(mono)
ok(ppk > 0.05, "pure engine renders audible audio (peak " .. string.format("%.3f", ppk) .. ")")

-- fillFloats + fill_into compared on TWO FRESH players (render advances the
-- playhead, so any reuse would compare different positions in the tune).
local tab = {}
do
  local pA = pure{ sampleRate = 44100, channels = 2 }
  pA:load_buffer_str(psid_data)
  pA:select_song(1); pA:play()
  local frames = pA:fillFloats(tab, 1000)
  eq(frames, 1000, "fillFloats returns frames written")
  eq(#tab, 2000, "fillFloats interleaves stereo (2 samples per frame)")
  local bad_pair = false
  for i = 0, 999 do
    if tab[i * 2 + 1] ~= tab[i * 2 + 2] then bad_pair = true end
    if tab[i * 2 + 1] < -32768 or tab[i * 2 + 1] > 32767 then bad_pair = true end
  end
  ok(not bad_pair, "fillFloats output is int16-ranged with L == R")
  pA:dispose()
end

if have_ffi then
  local p2 = pure{ sampleRate = 44100, channels = 2 }
  p2:load_buffer_str(psid_data)
  p2:select_song(1); p2:play()
  local buf = ffi.new("int16_t[?]", 2000)
  eq(p2:fill_into(buf, 1000), 1000, "fill_into returns frames (ffi)")
  ok(buf[0] == tab[1], "fill_into and fillFloats agree on sample 0")
  p2:dispose()
end

-- advancing renders different audio (the tune actually plays, not frozen)
local later = p:render(4410)
local diff = false
for i = 1, 441 do
  if math.abs(mono[i] - later[i]) > 1e-9 then diff = true break end
end
ok(diff, "consecutive renders differ (playhead moves)")

p:dispose()
eq(#p:render(10), 0, "render after dispose returns nothing")

-- ============================================================================
group("init.lua - public API, format sniffing, routing")

local sidlove = require("sidlove")
eq(sidlove.init(), true, "init() succeeds (native on LuaJIT, pure otherwise)")
ok(type(sidlove.VERSION) == "string", "VERSION string")
ok(sidlove.SID and sidlove.SID_PURE and sidlove.Streamer and sidlove.Filter
   and sidlove.Sample, "module exports present")
ok(sidlove.info().engines ~= nil and sidlove.info().platform ~= nil, "info() shape")

-- sniffing: header bytes decide the format
local s = sidlove.sniff
eq(s("PSIDxxxx"), "sid", "sniff PSID")
eq(s("RSIDxxxx"), "sid", "sniff RSID")
eq(s("MThd...."), "midi", "sniff MIDI")
eq(s("NESM$1A"), "chiptune", "sniff NSF")
eq(s("NSFE...."), "chiptune", "sniff NSFE")
eq(s("GBS\x01\x02"), "chiptune", "sniff GBS")
eq(s("SNES...."), "chiptune", "sniff SPC")
eq(s("HESM...."), "chiptune", "sniff HES")
eq(s("KSSX...."), "chiptune", "sniff KSS")
eq(s("Vgm\x20\x00"), "chiptune", "sniff VGM")
eq(s("SAP\r\nAUTHOR \"x\""), "chiptune", "sniff SAP")
eq(s(nil, "sid"), "sid", "sniff by extension")
eq(s(nil, "prg"), "sid", "sniff .prg by extension")
eq(s(nil, "mid"), "midi", "sniff .mid by extension")
eq(s("????", "xyz"), nil, "sniff unknown = nil")
eq(s("AY\x00\x00"), "chiptune", "sniff AY")

-- error paths (engine-agnostic: native or pure both produce nil + message)
local pl, e1 = sidlove.load("this-file-does-not-exist.sid")
ok(pl == nil and type(e1) == "string", "load of missing file fails with a message")

local pg, e2 = sidlove.load_buffer("not-a-real-tune", "sid")
ok(pg == nil and type(e2) == "string", "load_buffer with garbage fails with a message")

local pu, e3 = sidlove.load_buffer("PSID", "bogus-kind")
ok(pu == nil and e3:find("unknown kind", 1, true), "unknown kind rejected")

-- the real bundled tune loads and plays through whichever engine is active
local player, kind = sidlove.load(ROOT .. "/sidlove/assets/test.psid")
eq(kind, "sid", "sidlove.load(test.psid) -> kind 'sid'")
ok(player ~= nil, "player returned")
if player then
  eq(player.kind, "sid", "player.kind set for user code")
  -- regression: inherited Player-interface methods must resolve on BOTH
  -- engines (module tails used to clobber the base chain)
  ok(player.play and player.setLoop and player.playing and player.tell,
     "player inherits base methods regardless of engine")
  player:setLoop(true); player:play()
  eq(player:playing(), true, "player:playing() after play()")
  player:dispose()
end

-- sidlove.play argument checking (full construction needs love.audio)
local sp, se = sidlove.play(nil)
ok(sp == nil and type(se) == "string", "sidlove.play(nil) fails with a message")

-- ============================================================================
group("filter.lua - envelopes + bindings (regression: constructor sugar)")

local F = require("sidlove.filter")

local fmod = F()   -- was broken: module table wasn't callable
ok(fmod and fmod.add and fmod.tick, "Filter() callable")

local env = F.Envelope{ attack = 0.1, decay = 0.2, sustain = 0.1,
                        sustain_level = 0.5, release = 0.1, peak = 1.0 }
ok(env and env.strike, "Filter.Envelope{...} callable")   -- was broken: nil

env:strike()
env:tick(0.05);  near(env:value(), 0.5, 0.01, "attack halfway")
env:tick(0.05);  near(env:value(), 1.0, 0.01, "attack reaches peak")
env:tick(0.1);   near(env:value(), 0.75, 0.01, "decay halfway to sustain")
env:tick(0.1);   near(env:value(), 0.5, 0.01, "decay reaches sustain level")
env:tick(0.05);  near(env:value(), 0.5, 0.01, "sustain holds")
env:tick(0.06);  eq(env:state(), "release", "sustain auto-releases")
env:tick(0.05);  near(env:value(), 0.2, 0.01, "release 60% through (0.01s consumed at auto-release)")
env:tick(0.06);  ok(env:done(), "release finishes")
eq(env:value(), 0, "done envelope is silent")

local env2 = F.Envelope{ attack = 0.5 }
env2:strike(); env2:tick(0.1)
env2:release_now()
env2:tick(0.6)
ok(env2:done(), "release_now short-circuits the attack")

-- binding lifecycle: strike, setter runs each tick, binding removed when done
local seen = {}
local f3 = F()
local benv = F.Envelope{ attack = 0.01, decay = 0.01, sustain = 0.01,
                         sustain_level = 0, release = 0.01 }
f3:add(benv, function(v) seen[#seen + 1] = v end)
eq(#f3.bindings, 1, "add registers the binding")
eq(benv:state(), "idle", "add does not auto-strike (explicit strike)")
benv:strike()
f3:tick(0.5)   -- one big frame traverses the whole 0.04s ADSR
ok(#seen > 0, "setter was called with envelope values")
eq(#f3.bindings, 0, "finished bindings are removed")
eq(#seen, 1, "removed bindings stop ticking")
f3:tick(0.5)
eq(#seen, 1, "removed bindings stop ticking (still one after more ticks)")

-- MIDI CC setter floors to integer 0..127
local fake_midi = { _cc = nil }
function fake_midi:cc(chan, ctrl, val) fake_midi._cc = { chan, ctrl, val } end
local setter = F.setter_midi_cc(fake_midi, 3, F.CC_FILTER_CUTOFF)
setter(0.5)
eq(fake_midi._cc[1], 3, "cc setter channel")
eq(fake_midi._cc[2], F.CC_FILTER_CUTOFF, "cc setter controller")
eq(fake_midi._cc[3], 64, "cc value floors to 64 at v=0.5")

-- ============================================================================
group("sample_player.lua - digi voices (regression: constructor sugar)")

local Sample = require("sidlove.sample_player")
local sm = Sample{ sampleRate = 8000 }   -- was broken: not callable
ok(sm ~= nil, "Sample{...} callable")
eq(sm.sampleRate, 8000, "opts forwarded")
eq(sm.enabled, true, "mixer starts enabled")

-- 4-bit decode: byte 0xA5=165 -> hi nibble A=10 -> (10-8)/8 at even sample,
-- lo nibble 5 -> -0.375 at odd. Decimal escapes (\165) because Lua 5.1 has
-- no \xHH syntax; the file must stay parseable by both engines.
-- 2 bytes = 4 samples (nsamp = 2*len for 4-bit voices).
local v = Sample.Voice.new("\165\90", { bits = 4, loop = false, rate = 8000 })
eq(v.nsamp, 4, "4-bit voice: nsamp counts samples, not bytes")
near(v:_sample(), 0.25, 1e-9, "4-bit sample 0 = hi nibble of byte 0")
v.pos = 1
near(v:_sample(), -0.375, 1e-9, "4-bit sample 1 = lo nibble of byte 0")
v.pos = 2
near(v:_sample(), -0.375, 1e-9, "4-bit sample 2 = hi nibble of byte 1 (0x5A -> hi 5)")

-- 8-bit decode: byte 128 = silence center
local v8 = Sample.Voice.new("\128\128", { bits = 8, loop = false, rate = 8000 })
near(v8:_sample(), 0.0, 1e-9, "8-bit 128 is center/silence")

-- mix_into advances exactly n output frames and finishes non-looping voices
local n = 10
if have_ffi then
  local buf = ffi.new("int16_t[?]", n * 2)
  for i = 0, n * 2 - 1 do buf[i] = 100 end
  sm.voices = {}
  sm:add(Sample.Voice.new(string.rep("\128", n), { bits = 8, loop = false, rate = 8000 }))
  sm:mix_into(buf, n)
  ok(buf[0] == 100, "centered 8-bit voice adds nothing (ffi path)")
  ok(sm.voices[1]._done, "non-looping voice finished after nsamp frames (ffi path)")
else
  local tab = {}
  for i = 1, n * 2 do tab[i] = 100 end
  sm.voices = {}
  sm:add(Sample.Voice.new(string.rep("\128", n), { bits = 8, loop = false, rate = 8000 }))
  sm:mix_into(tab, n)
  ok(tab[1] == 100, "centered 8-bit voice adds nothing (table path)")
  ok(sm.voices[1]._done, "non-looping voice finished after nsamp frames (table path)")
end

-- a 4-bit looping voice cycles through ALL its samples (the old code ended
-- the loop at the byte count, cutting the loop in half). Bytes 0,255,0,255 =
-- nibbles 0,0,15,15,0,0,15,15 -> samples -1,-1,7/8,7/8,-1,-1,7/8,7/8.
local sm3 = Sample{ sampleRate = 8000 }
local lv = Sample.Voice.new("\0\255\0\255", { bits = 4, loop = true, rate = 8000 })
sm3:add(lv)
local got = {}
if have_ffi then
  local buf = ffi.new("int16_t[?]", 16)
  sm3:mix_into(buf, 8)
  for i = 0, 7 do got[#got + 1] = buf[i * 2] end
else
  local tab = {}
  sm3:mix_into(tab, 8)
  for i = 1, 8 do got[#got + 1] = tab[i * 2 - 1] end
end
local lo, hi = got[1], got[3]   -- sample 0 = -1, sample 2 = 7/8 (distinct)
ok(got[1] == got[5] and got[2] == got[6] and got[3] == got[7] and got[4] == got[8]
   and lo ~= hi,
   "4-bit looping voice wraps through all nsamp samples (period == nsamp)")

-- mixing a loud 4-bit voice clamps, never overflows
local sm2 = Sample{ sampleRate = 8000 }
local loud = Sample.Voice.new("\255\255", { bits = 4, loop = false, rate = 8000 })
sm2:add(loud)
if have_ffi then
  local buf = ffi.new("int16_t[?]", 4)
  buf[0] = 30000; buf[1] = 30000; buf[2] = 30000; buf[3] = 30000
  sm2:mix_into(buf, 2)
  ok(buf[0] <= 32767, "mix clamps to int16 max")
else
  local tab = { 30000, 30000, 30000, 30000 }
  sm2:mix_into(tab, 2)
  ok(tab[1] <= 32767, "mix clamps to int16 max (table path)")
end

-- ============================================================================
group("streamer.lua - headless guards")

local Streamer = require("sidlove.streamer")
local s1, e = Streamer{}
ok(s1 == nil and type(e) == "string", "missing player fails with a message")
local s2, e2 = Streamer{ player = {} }
ok(s2 == nil and (e2 or ""):find("love.audio", 1, true), "no love.audio fails with a clear message")

-- ============================================================================
group("API surface - main.lua's expectations still hold")

-- everything main.lua touches at load time must exist and be callable
ok(type(sidlove.Raster) == "table" or sidlove.Raster == nil,
   "Raster is a table (desktop) or nil (web), never a broken require")
ok(sidlove.Filter() ~= nil, "sidlove.Filter() constructs (main.lua startup)")
ok(Sample{ sampleRate = 44100 } ~= nil, "sidlove.Sample{...} constructs (main.lua startup)")
if sidlove.Raster then
  local r = sidlove.Raster{ player = nil, clock = "pal", on_tick = function() end }
  ok(r ~= nil and r.update, "sidlove.Raster{...} constructs (main.lua startup)")
  r:update(1/60)  -- must not error without a player
  ok(true, "Raster:update runs without a player")
end
ok(bit.bor and bit.lshift, "sidlove.bit covers the LuaJIT bit API main.lua uses")

-- ============================================================================
print(string.format("\n%d passed, %d failed (%s, %s engine)",
      pass_n, fail_n,
      have_ffi and "luajit/ffi" or "lua5.1/no-ffi",
      sidlove.engines.sid and "native" or "pure"))

if fail_n > 0 then
  print("\nFailures:")
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print("ALL TESTS PASSED")
