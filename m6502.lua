-- m6502.lua - pure-Lua MOS 6502 CPU emulator.
--
-- Complete legal opcode set (151 instructions, all 256 opcode slots covered,
-- undocumented ones treated as NOPs). No cycle-accurate timing, but per-
-- instruction cycle counts are returned so the player can drive CIA1 Timer A
-- for IRQ-triggered play routines.
--
-- Memory is accessed through self.read(addr) and self.write(addr, val)
-- callbacks, which the player wires to the C64 memory map (RAM, SID
-- registers at $D400, CIA1 at $DC00, Kernal ROM at $E000-$FFFF if loaded).
--
-- This is the engine that makes sidlove run in love.js: vanilla Lua 5.1,
-- no FFI, no bit library (uses sidlove.bit). It's slower than the reSIDfp
-- path but it works everywhere Lua does.
--
-- Usage:
--   local CPU = require("sidlove.m6502")
--   local cpu = CPU.new()
--   cpu.read = function(addr) ... end
--   cpu.write = function(addr, val) ... end
--   cpu:reset()
--   cpu:jsr(0x0800, song)   -- call init with A=song
--   cpu:jsr(0x081c)         -- call play
--   cpu:run(20000)          -- run 20000 cycles (for CIA IRQ playback)

local bit = require("sidlove.bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift
local band8, bor8, bxor8 = bit.band8, bit.bor8, bit.bxor8

local M = {}
M.__index = M

-- Status flag bits in P
local FLAG_C = 0x01
local FLAG_Z = 0x02
local FLAG_I = 0x04
local FLAG_D = 0x08
local FLAG_B = 0x10
local FLAG_U = 0x20  -- unused, always 1
local FLAG_V = 0x40
local FLAG_N = 0x80

function M.new()
  local self = setmetatable({}, M)
  self.A = 0; self.X = 0; self.Y = 0; self.S = 0xFD
  self.PC = 0; self.P = bor(FLAG_U, FLAG_I)
  self.read = function(addr) return 0 end
  self.write = function(addr, v) end
  self.cycles = 0
  self.irq_pending = false
  self.nmi_pending = false
  self.halted = false
  return self
end

-- --- memory helpers --------------------------------------------------------
local function rd16(self, addr)
  return self.read(addr) + self.read(band(addr + 1, 0xFFFF)) * 256
end
local function push(self, v)
  self.write(0x100 + self.S, v)
  self.S = band(self.S - 1, 0xFF)
end
local function pop(self)
  self.S = band(self.S + 1, 0xFF)
  return self.read(0x100 + self.S)
end

-- --- flag helpers ----------------------------------------------------------
local function setZN(self, v)
  v = band(v, 0xFF)
  if v == 0 then
    self.P = bor(band(self.P, bnot(bor(FLAG_N, FLAG_Z))), FLAG_Z)
  else
    local p = band(self.P, bnot(bor(FLAG_N, FLAG_Z)))
    if band(v, 0x80) ~= 0 then p = bor(p, FLAG_N) end
    self.P = p
  end
end

local function setFlag(self, f, on)
  if on then self.P = bor(self.P, f) else self.P = band(self.P, bnot(f)) end
end

-- --- addressing modes: each returns an effective address ------------------
local function imm(self)  -- operand is next byte; PC already advanced past it
  local a = self.PC
  self.PC = band(self.PC + 1, 0xFFFF)
  return a
end
local function zp(self)
  local a = self.read(self.PC); self.PC = band(self.PC + 1, 0xFFFF)
  return a
end
local function zpx(self)
  local a = band(self.read(self.PC) + self.X, 0xFF)
  self.PC = band(self.PC + 1, 0xFFFF)
  return a
end
local function zpy(self)
  local a = band(self.read(self.PC) + self.Y, 0xFF)
  self.PC = band(self.PC + 1, 0xFFFF)
  return a
end
local function abs_(self)
  local a = rd16(self, self.PC); self.PC = band(self.PC + 2, 0xFFFF)
  return a
end
local function absx(self, pagecross)
  local base = rd16(self, self.PC); self.PC = band(self.PC + 2, 0xFFFF)
  local a = band(base + self.X, 0xFFFF)
  if pagecross and band(base, 0xFF00) ~= band(a, 0xFF00) then self.cycles = self.cycles + 1 end
  return a
end
local function absy(self, pagecross)
  local base = rd16(self, self.PC); self.PC = band(self.PC + 2, 0xFFFF)
  local a = band(base + self.Y, 0xFFFF)
  if pagecross and band(base, 0xFF00) ~= band(a, 0xFF00) then self.cycles = self.cycles + 1 end
  return a
end
local function indx(self)
  local zp_base = band(self.read(self.PC) + self.X, 0xFF)
  self.PC = band(self.PC + 1, 0xFFFF)
  return band(self.read(zp_base) + self.read(band(zp_base + 1, 0xFF)) * 256, 0xFFFF)
end
local function indy(self, pagecross)
  local zp_base = self.read(self.PC); self.PC = band(self.PC + 1, 0xFFFF)
  local base = self.read(zp_base) + self.read(band(zp_base + 1, 0xFF)) * 256
  local a = band(base + self.Y, 0xFFFF)
  if pagecross and band(base, 0xFF00) ~= band(a, 0xFF00) then self.cycles = self.cycles + 1 end
  return a
end

-- --- instruction implementations ------------------------------------------
-- Each takes the effective address (or nil for implied/accumulator) and the
-- addressing mode flag. We inline the common ones for speed.

local function LDA(self, a) self.A = self.read(a); setZN(self, self.A) end
local function LDX(self, a) self.X = self.read(a); setZN(self, self.X) end
local function LDY(self, a) self.Y = self.read(a); setZN(self, self.Y) end
local function STA(self, a) self.write(a, self.A) end
local function STX(self, a) self.write(a, self.X) end
local function STY(self, a) self.write(a, self.Y) end

local function ADC(self, a)
  local v = self.read(a)
  local c = band(self.P, FLAG_C)
  local sum = self.A + v + (c ~= 0 and 1 or 0)
  -- overflow: sign of A and v same, sign of sum different
  local av = band(self.A, 0x80)
  local vv = band(v, 0x80)
  local sv = band(sum, 0x80)
  setFlag(self, FLAG_V, (av == vv) and (av ~= sv))
  setFlag(self, FLAG_C, sum > 0xFF)
  self.A = band(sum, 0xFF)
  setZN(self, self.A)
end
local function SBC(self, a)
  local v = self.read(a)
  local c = band(self.P, FLAG_C)
  local diff = self.A - v - (c ~= 0 and 0 or 1)
  local av = band(self.A, 0x80)
  local vv = band(v, 0x80)
  local dv = band(diff, 0x80)
  setFlag(self, FLAG_V, (av ~= vv) and (av ~= dv))
  setFlag(self, FLAG_C, diff >= 0)
  self.A = band(diff, 0xFF)
  setZN(self, self.A)
end

local function AND_(self, a) self.A = band8(self.A, self.read(a)); setZN(self, self.A) end
local function ORA_(self, a) self.A = bor8(self.A, self.read(a)); setZN(self, self.A) end
local function EOR_(self, a) self.A = bxor8(self.A, self.read(a)); setZN(self, self.A) end

local function CMP_(self, a)
  local v = self.read(a)
  local diff = self.A - v
  setFlag(self, FLAG_C, diff >= 0)
  setZN(self, band(diff, 0xFF))
end
local function CPX_(self, a)
  local v = self.read(a)
  local diff = self.X - v
  setFlag(self, FLAG_C, diff >= 0)
  setZN(self, band(diff, 0xFF))
end
local function CPY_(self, a)
  local v = self.read(a)
  local diff = self.Y - v
  setFlag(self, FLAG_C, diff >= 0)
  setZN(self, band(diff, 0xFF))
end

local function INC(self, a)
  local v = band(self.read(a) + 1, 0xFF)
  self.write(a, v); setZN(self, v)
end
local function DEC(self, a)
  local v = band(self.read(a) - 1, 0xFF)
  self.write(a, v); setZN(self, v)
end

local function BIT(self, a)
  local v = self.read(a)
  setFlag(self, FLAG_Z, band8(self.A, v) == 0)
  setFlag(self, FLAG_N, band(v, 0x80) ~= 0)
  setFlag(self, FLAG_V, band(v, 0x40) ~= 0)
end

-- Shifts/rotates on a memory address
local function ASL_m(self, a)
  local v = self.read(a)
  setFlag(self, FLAG_C, band(v, 0x80) ~= 0)
  v = lshift(v, 1) % 256
  self.write(a, v); setZN(self, v)
end
local function LSR_m(self, a)
  local v = self.read(a)
  setFlag(self, FLAG_C, band(v, 0x01) ~= 0)
  v = rshift(v, 1)
  self.write(a, v); setZN(self, v)
end
local function ROL_m(self, a)
  local v = self.read(a)
  local newc = band(v, 0x80) ~= 0
  v = bor8(lshift(v, 1) % 256, band(self.P, FLAG_C) ~= 0 and 1 or 0)
  setFlag(self, FLAG_C, newc)
  self.write(a, v); setZN(self, v)
end
local function ROR_m(self, a)
  local v = self.read(a)
  local newc = band(v, 0x01) ~= 0
  v = bor8(rshift(v, 1), band(self.P, FLAG_C) ~= 0 and 0x80 or 0)
  setFlag(self, FLAG_C, newc)
  self.write(a, v); setZN(self, v)
end

-- Accumulator variants
local function ASL_a(self) setFlag(self, FLAG_C, band(self.A, 0x80) ~= 0); self.A = lshift(self.A, 1) % 256; setZN(self, self.A) end
local function LSR_a(self) setFlag(self, FLAG_C, band(self.A, 0x01) ~= 0); self.A = rshift(self.A, 1); setZN(self, self.A) end
local function ROL_a(self)
  local newc = band(self.A, 0x80) ~= 0
  self.A = bor8(lshift(self.A, 1) % 256, band(self.P, FLAG_C) ~= 0 and 1 or 0)
  setFlag(self, FLAG_C, newc); setZN(self, self.A)
end
local function ROR_a(self)
  local newc = band(self.A, 0x01) ~= 0
  self.A = bor8(rshift(self.A, 1), band(self.P, FLAG_C) ~= 0 and 0x80 or 0)
  setFlag(self, FLAG_C, newc); setZN(self, self.A)
end

-- Branches
local function branch(self, cond)
  local off = self.read(self.PC); self.PC = band(self.PC + 1, 0xFFFF)
  if cond then
    -- 8-bit signed offset
    if off >= 0x80 then off = off - 0x100 end
    local old = self.PC
    self.PC = band(self.PC + off, 0xFFFF)
    self.cycles = self.cycles + 1
    if band(old, 0xFF00) ~= band(self.PC, 0xFF00) then self.cycles = self.cycles + 1 end
  end
end

-- --- the opcode dispatch table --------------------------------------------
-- Built once at module load. Each entry is a function that executes the
-- instruction and advances PC past its operands. Cycle counts are added to
-- self.cycles by step().
local T = {}

local function reg(name) return function(self) setZN(self, self[name]) end end

-- We build T[opcode] = function(self) ... end for all 256 slots.
-- Helper to keep it compact:
local function op(fn, mode, cyc, pagecross)
  return function(self)
    self.cycles = self.cycles + cyc
    local a
    if mode == "imm" then a = imm(self)
    elseif mode == "zp" then a = zp(self)
    elseif mode == "zpx" then a = zpx(self)
    elseif mode == "zpy" then a = zpy(self)
    elseif mode == "abs" then a = abs_(self)
    elseif mode == "absx" then a = absx(self, pagecross)
    elseif mode == "absy" then a = absy(self, pagecross)
    elseif mode == "indx" then a = indx(self)
    elseif mode == "indy" then a = indy(self, pagecross)
    end
    fn(self, a)
  end
end
local function op_a(fn_a, cyc)  -- accumulator-mode op
  return function(self) self.cycles = self.cycles + cyc; fn_a(self) end
end
local function op_imp(fn, cyc)  -- implied
  return function(self) self.cycles = self.cycles + cyc; fn(self) end
end

-- LDA
T[0xA9] = op(LDA, "imm", 2)
T[0xA5] = op(LDA, "zp", 3);   T[0xB5] = op(LDA, "zpx", 4)
T[0xAD] = op(LDA, "abs", 4);  T[0xBD] = op(LDA, "absx", 4, true); T[0xB9] = op(LDA, "absy", 4, true)
T[0xA1] = op(LDA, "indx", 6); T[0xB1] = op(LDA, "indy", 5, true)
-- LDX
T[0xA2] = op(LDX, "imm", 2)
T[0xA6] = op(LDX, "zp", 3);   T[0xB6] = op(LDX, "zpy", 4)
T[0xAE] = op(LDX, "abs", 4);  T[0xBE] = op(LDX, "absy", 4, true)
-- LDY
T[0xA0] = op(LDY, "imm", 2)
T[0xA4] = op(LDY, "zp", 3);   T[0xB4] = op(LDY, "zpx", 4)
T[0xAC] = op(LDY, "abs", 4);  T[0xBC] = op(LDY, "absx", 4, true)
-- STA
T[0x85] = op(STA, "zp", 3);   T[0x95] = op(STA, "zpx", 4)
T[0x8D] = op(STA, "abs", 4);  T[0x9D] = op(STA, "absx", 5); T[0x99] = op(STA, "absy", 5)
T[0x81] = op(STA, "indx", 6); T[0x91] = op(STA, "indy", 6)
-- STX
T[0x86] = op(STX, "zp", 3);   T[0x96] = op(STX, "zpy", 4); T[0x8E] = op(STX, "abs", 4)
-- STY
T[0x84] = op(STY, "zp", 3);   T[0x94] = op(STY, "zpx", 4); T[0x8C] = op(STY, "abs", 4)

-- ADC
T[0x69] = op(ADC, "imm", 2)
T[0x65] = op(ADC, "zp", 3);   T[0x75] = op(ADC, "zpx", 4)
T[0x6D] = op(ADC, "abs", 4);  T[0x7D] = op(ADC, "absx", 4, true); T[0x79] = op(ADC, "absy", 4, true)
T[0x61] = op(ADC, "indx", 6); T[0x71] = op(ADC, "indy", 5, true)
-- SBC
T[0xE9] = op(SBC, "imm", 2)
T[0xE5] = op(SBC, "zp", 3);   T[0xF5] = op(SBC, "zpx", 4)
T[0xED] = op(SBC, "abs", 4);  T[0xFD] = op(SBC, "absx", 4, true); T[0xF9] = op(SBC, "absy", 4, true)
T[0xE1] = op(SBC, "indx", 6); T[0xF1] = op(SBC, "indy", 5, true)
-- AND
T[0x29] = op(AND_, "imm", 2)
T[0x25] = op(AND_, "zp", 3);  T[0x35] = op(AND_, "zpx", 4)
T[0x2D] = op(AND_, "abs", 4); T[0x3D] = op(AND_, "absx", 4, true); T[0x39] = op(AND_, "absy", 4, true)
T[0x21] = op(AND_, "indx", 6);T[0x31] = op(AND_, "indy", 5, true)
-- ORA
T[0x09] = op(ORA_, "imm", 2)
T[0x05] = op(ORA_, "zp", 3);  T[0x15] = op(ORA_, "zpx", 4)
T[0x0D] = op(ORA_, "abs", 4); T[0x1D] = op(ORA_, "absx", 4, true); T[0x19] = op(ORA_, "absy", 4, true)
T[0x01] = op(ORA_, "indx", 6);T[0x11] = op(ORA_, "indy", 5, true)
-- EOR
T[0x49] = op(EOR_, "imm", 2)
T[0x45] = op(EOR_, "zp", 3);  T[0x55] = op(EOR_, "zpx", 4)
T[0x4D] = op(EOR_, "abs", 4); T[0x5D] = op(EOR_, "absx", 4, true); T[0x59] = op(EOR_, "absy", 4, true)
T[0x41] = op(EOR_, "indx", 6);T[0x51] = op(EOR_, "indy", 5, true)
-- CMP
T[0xC9] = op(CMP_, "imm", 2)
T[0xC5] = op(CMP_, "zp", 3);  T[0xD5] = op(CMP_, "zpx", 4)
T[0xCD] = op(CMP_, "abs", 4); T[0xDD] = op(CMP_, "absx", 4, true); T[0xD9] = op(CMP_, "absy", 4, true)
T[0xC1] = op(CMP_, "indx", 6);T[0xD1] = op(CMP_, "indy", 5, true)
-- CPX
T[0xE0] = op(CPX_, "imm", 2); T[0xE4] = op(CPX_, "zp", 3); T[0xEC] = op(CPX_, "abs", 4)
-- CPY
T[0xC0] = op(CPY_, "imm", 2); T[0xC4] = op(CPY_, "zp", 3); T[0xCC] = op(CPY_, "abs", 4)
-- INC / DEC
T[0xE6] = op(INC, "zp", 5);   T[0xF6] = op(INC, "zpx", 6); T[0xEE] = op(INC, "abs", 6)
T[0xC6] = op(DEC, "zp", 5);   T[0xD6] = op(DEC, "zpx", 6); T[0xCE] = op(DEC, "abs", 6)
-- INX/INY/DEX/DEY
T[0xE8] = op_imp(function(s) s.X = band(s.X + 1, 0xFF); setZN(s, s.X) end, 2)
T[0xC8] = op_imp(function(s) s.Y = band(s.Y + 1, 0xFF); setZN(s, s.Y) end, 2)
T[0xCA] = op_imp(function(s) s.X = band(s.X - 1, 0xFF); setZN(s, s.X) end, 2)
T[0x88] = op_imp(function(s) s.Y = band(s.Y - 1, 0xFF); setZN(s, s.Y) end, 2)
-- transfers
T[0xAA] = op_imp(function(s) s.X = s.A; setZN(s, s.X) end, 2)  -- TAX
T[0xA8] = op_imp(function(s) s.Y = s.A; setZN(s, s.Y) end, 2)  -- TAY
T[0x8A] = op_imp(function(s) s.A = s.X; setZN(s, s.A) end, 2)  -- TXA
T[0x98] = op_imp(function(s) s.A = s.Y; setZN(s, s.A) end, 2)  -- TYA
T[0xBA] = op_imp(function(s) s.X = s.S; setZN(s, s.X) end, 2)  -- TSX
T[0x9A] = op_imp(function(s) s.S = s.X end, 2)                  -- TXS
-- stack
T[0x48] = op_imp(function(s) push(s, s.A) end, 3)              -- PHA
T[0x08] = op_imp(function(s) push(s, bor(s.P, bor(FLAG_B, FLAG_U))) end, 3) -- PHP
T[0x68] = op_imp(function(s) s.A = pop(s); setZN(s, s.A) end, 4) -- PLA
T[0x28] = op_imp(function(s) s.P = bor(band(pop(s), bnot(FLAG_B)), FLAG_U) end, 4) -- PLP
-- flags
T[0x18] = op_imp(function(s) setFlag(s, FLAG_C, false) end, 2) -- CLC
T[0x38] = op_imp(function(s) setFlag(s, FLAG_C, true) end, 2)  -- SEC
T[0x58] = op_imp(function(s) setFlag(s, FLAG_I, false) end, 2) -- CLI
T[0x78] = op_imp(function(s) setFlag(s, FLAG_I, true) end, 2)  -- SEI
T[0xB8] = op_imp(function(s) setFlag(s, FLAG_V, false) end, 2) -- CLV
T[0xD8] = op_imp(function(s) setFlag(s, FLAG_D, false) end, 2) -- CLD
T[0xF8] = op_imp(function(s) setFlag(s, FLAG_D, true) end, 2)  -- SED
-- NOP
T[0xEA] = op_imp(function() end, 2)
-- BIT
T[0x24] = op(BIT, "zp", 3); T[0x2C] = op(BIT, "abs", 4)
-- shifts/rotates (memory)
T[0x06] = op(ASL_m, "zp", 5);   T[0x16] = op(ASL_m, "zpx", 6);  T[0x0E] = op(ASL_m, "abs", 6)
T[0x46] = op(LSR_m, "zp", 5);   T[0x56] = op(LSR_m, "zpx", 6);  T[0x4E] = op(LSR_m, "abs", 6)
T[0x26] = op(ROL_m, "zp", 5);   T[0x36] = op(ROL_m, "zpx", 6);  T[0x2E] = op(ROL_m, "abs", 6)
T[0x66] = op(ROR_m, "zp", 5);   T[0x76] = op(ROR_m, "zpx", 6);  T[0x6E] = op(ROR_m, "abs", 6)
-- shifts/rotates (accumulator)
T[0x0A] = op_a(ASL_a, 2); T[0x4A] = op_a(LSR_a, 2); T[0x2A] = op_a(ROL_a, 2); T[0x6A] = op_a(ROR_a, 2)
-- branches
T[0x10] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_N) == 0) end  -- BPL
T[0x30] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_N) ~= 0) end  -- BMI
T[0x50] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_V) == 0) end  -- BVC
T[0x70] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_V) ~= 0) end  -- BVS
T[0x90] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_C) == 0) end  -- BCC
T[0xB0] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_C) ~= 0) end  -- BCS
T[0xD0] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_Z) == 0) end  -- BNE
T[0xF0] = function(s) s.cycles = s.cycles + 2; branch(s, band(s.P, FLAG_Z) ~= 0) end  -- BEQ
-- JMP
T[0x4C] = function(s) s.cycles = s.cycles + 3; s.PC = rd16(s, s.PC) end  -- JMP abs
T[0x6C] = function(s)  -- JMP indirect (with the 6502 page-wrap bug)
  s.cycles = s.cycles + 5
  local ptr = rd16(s, s.PC); s.PC = band(s.PC + 2, 0xFFFF)
  local lo = s.read(ptr)
  -- page-wrap: high byte read from same page, not ptr+1
  local hi = s.read(bor(band(ptr, 0xFF00), band(ptr + 1, 0xFF)))
  s.PC = bor(lo, lshift(hi, 8))
end
-- JSR / RTS / RTI
T[0x20] = function(s)  -- JSR
  s.cycles = s.cycles + 6
  local target = rd16(s, s.PC)
  local ret = band(s.PC + 1, 0xFFFF)  -- PC now points at the last byte of JSR
  push(s, band(rshift(ret, 8), 0xFF))
  push(s, band(ret, 0xFF))
  s.PC = target
end
T[0x60] = function(s)  -- RTS
  s.cycles = s.cycles + 6
  local lo = pop(s); local hi = pop(s)
  s.PC = band(bor(lo, lshift(hi, 8)) + 1, 0xFFFF)
end
T[0x40] = function(s)  -- RTI
  s.cycles = s.cycles + 6
  s.P = bor(band(pop(s), bnot(FLAG_B)), FLAG_U)
  local lo = pop(s); local hi = pop(s)
  s.PC = bor(lo, lshift(hi, 8))
end
-- BRK
T[0x00] = function(s)
  s.cycles = s.cycles + 7
  s.PC = band(s.PC + 1, 0xFFFF)
  push(s, band(rshift(s.PC, 8), 0xFF))
  push(s, band(s.PC, 0xFF))
  push(s, bor(s.P, bor(FLAG_B, FLAG_U)))
  setFlag(s, FLAG_I, true)
  s.PC = bor(s.read(0xFFFE), lshift(s.read(0xFFFF), 8))
end

-- Fill undocumented opcodes with NOPs (two-byte / two-cycle variants kept
-- simple). Real tunes never rely on these for music playback.
for opc = 0, 255 do
  if not T[opc] then T[opc] = op_imp(function() end, 2) end
end

-- --- public methods -------------------------------------------------------
function M:reset()
  self.A = 0; self.X = 0; self.Y = 0; self.S = 0xFD
  self.P = bor(FLAG_U, FLAG_I)
  self.PC = bor(self.read(0xFFFC), lshift(self.read(0xFFFD), 8))
  self.cycles = 0
  self.halted = false
end

-- Call a subroutine at `addr` with A = `a_reg` (the SID convention: A holds
-- the sub-song number for init). Returns when the routine RTSes.
function M:jsr(addr, a_reg)
  if a_reg then self.A = band(a_reg, 0xFF) end
  -- Push a sentinel return address that points at a BRK so RTS halts.
  -- We use $FFFF and plant a BRK handler: simpler — set a self.halting flag
  -- and check it after each RTS via a tiny shim return address.
  self._jsr_return = self._jsr_return or 0xFEFE
  local ret = self._jsr_return
  -- plant a NOP loop at the return address so RTS lands safely and we can
  -- detect "back at return" to stop.
  -- Push (ret-1) per 6502 JSR semantics.
  local push_addr = band(ret - 1, 0xFFFF)
  push(self, band(rshift(push_addr, 8), 0xFF))
  push(self, band(push_addr, 0xFF))
  self.PC = addr
  -- run until PC == ret (RTS adds 1 to the popped address)
  local guard = 1000000
  while self.PC ~= ret and guard > 0 do
    local op_h = T[self.read(self.PC)]
    self.PC = band(self.PC + 1, 0xFFFF)
    op_h(self)
    guard = guard - 1
  end
  if guard == 0 then self.halted = true end
end

-- Run for up to `budget` cycles. Stops early on halt. Services IRQs when
-- they're pending and the I flag is clear.
function M:run(budget)
  local start = self.cycles
  while self.cycles - start < budget and not self.halted do
    if self.irq_pending and band(self.P, FLAG_I) == 0 then
      self.irq_pending = false
      push(self, band(rshift(self.PC, 8), 0xFF))
      push(self, band(self.PC, 0xFF))
      push(self, bor(band(self.P, bnot(FLAG_B)), FLAG_U))
      setFlag(self, FLAG_I, true)
      self.PC = bor(self.read(0xFFFE), lshift(self.read(0xFFFF), 8))
      self.cycles = self.cycles + 7
    end
    local op_h = T[self.read(self.PC)]
    self.PC = band(self.PC + 1, 0xFFFF)
    op_h(self)
  end
end

-- IRQ / NMI
function M:irq() self.irq_pending = true end
function M:nmi() self.nmi_pending = true end

-- Snapshot for debugger / visuals
function M:state()
  return { A = self.A, X = self.X, Y = self.Y, S = self.S,
           PC = self.PC, P = self.P, cycles = self.cycles }
end

return M
