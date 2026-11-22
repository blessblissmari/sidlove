-- bit.lua - bitwise compatibility shim.
--
-- LuaJIT (and Lua 5.2+ via bit32 / 5.3+ via operators) has real bitwise ops.
-- Vanilla Lua 5.1 — which is what love.js runs in the browser — has none.
-- This module exposes the LuaJIT `bit` API (band/bor/bxor/bnot/lshift/rshift/
-- rol/ror/arshift/tobit/tohex) using the real library when available, and an
-- arithmetic fallback otherwise. The fallback is slower but correct, which is
-- what lets sidlove run in love.js with zero FFI.
--
-- Every other pure-Lua module in sidlove does `local bit = require("sidlove.bit")`
-- and gets a working bit library on every Lua.

local M = {}

local ok, realbit = pcall(require, "bit")
if ok and realbit and realbit.band then
  -- Real LuaJIT bit library — forward the whole API, plus the 8-bit ops the
  -- 6502 core destructures (realbit has none, and m6502.lua crashing on ORA
  -- under LuaJIT was exactly why these live here on every path).
  local W = {}
  for k, v in pairs(realbit) do W[k] = v end
  local band, bor, bxor = realbit.band, realbit.bor, realbit.bxor
  W.band8  = function(a, b) return band(a, band(b, 0xff)) end
  W.bor8   = function(a, b) return band(bor(band(a, 0xff), b), 0xff) end
  W.bxor8  = function(a, b) return band(bxor(band(a, 0xff), b), 0xff) end
  return W
end

-- --- arithmetic fallback (vanilla Lua 5.1) ---------------------------------
-- All inputs are treated as unsigned 32-bit. We build 16x16 nibble tables
-- for the byte ops so the common case (8-bit AND/OR/XOR in the 6502) is two
-- table lookups + an add, not a 32-iteration loop.

local floor = math.floor

-- NIB[a*16+b] = a AND b / a OR b / a XOR b, for nibbles a,b in 0..15.
-- Built in one flat pass: unpack both nibbles bit by bit.
local AND_NIB, OR_NIB, XOR_NIB = {}, {}, {}
for a = 0, 15 do
  for b = 0, 15 do
    local an, orr, xr, m = 0, 0, 0, 1
    for _ = 0, 3 do
      local abit = floor(a / m) % 2
      local bbit = floor(b / m) % 2
      if abit == 1 and bbit == 1 then an  = an  + m end
      if abit == 1 or  bbit == 1 then orr = orr + m end
      if abit ~= bbit            then xr  = xr  + m end
      m = m * 2
    end
    AND_NIB[a * 16 + b] = an
    OR_NIB[a * 16 + b]  = orr
    XOR_NIB[a * 16 + b] = xr
  end
end

local function u32(n)
  n = n % 4294967296
  if n < 0 then n = n + 4294967296 end
  return n
end

-- 8-bit ops via nibble tables: split a byte into hi/lo nibbles, table-lookup,
-- recombine. Fast enough for a 6502 in WASM.
local function byte_op(nib)
  return function(a, b)
    a = a % 256; b = b % 256
    return nib[floor(a / 16) * 16 + floor(b / 16)] * 16
         + nib[a % 16 * 16 + b % 16]
  end
end
local band8 = byte_op(AND_NIB)
local bor8  = byte_op(OR_NIB)
local bxor8 = byte_op(XOR_NIB)

-- 32-bit variants: split into 4 bytes, op each, recombine.
local function word_op(op8)
  return function(a, b)
    a = u32(a); b = u32(b)
    local r, p = 0, 1
    for _ = 1, 4 do
      r = r + op8(a % 256, b % 256) * p
      a = floor(a / 256); b = floor(b / 256); p = p * 256
    end
    return r
  end
end
local band32 = word_op(band8)
local bor32  = word_op(bor8)
local bxor32 = word_op(bxor8)

-- Wrap to signed 32-bit so results match LuaJIT's `bit` library, which
-- returns signed values (e.g. bnot(0) == -1, not 4294967295). rshift stays
-- unsigned because LuaJIT's rshift is logical.
local function sgn(n) n = u32(n); if n >= 2147483648 then return n - 4294967296 end return n end

-- Variadic core shared by band/bor/bxor (LuaJIT's bit lib is variadic too).
local function fold(op32, a, b, ...)
  if not b then return sgn(a) end
  local r = op32(a, b)
  for i = 1, select("#", ...) do r = op32(r, select(i, ...)) end
  return sgn(r)
end

M.band = function(a, b, ...) return fold(band32, a, b, ...) end
M.bor  = function(a, b, ...) return fold(bor32,  a, b, ...) end
M.bxor = function(a, b, ...) return fold(bxor32, a, b, ...) end
function M.bnot(x)
  return sgn(4294967295 - u32(x))
end

function M.lshift(x, n)
  n = n % 32
  if n == 0 then return sgn(u32(x)) end
  -- x * 2^n fits in a double for n<=31 and x<2^32 (product < 2^63)
  return sgn(u32(x * (2 ^ n)))
end
function M.rshift(x, n)
  n = n % 32
  if n == 0 then return u32(x) end
  return floor(u32(x) / (2 ^ n))
end
function M.arshift(x, n)
  n = n % 32
  local ux = u32(x)
  local r = floor(ux / (2 ^ n))
  if ux >= 2147483648 then  -- negative when interpreted as signed: fill high bits with 1s
    r = bor32(r, u32(4294967296 - 2 ^ (32 - n)))
  end
  return sgn(r)
end
function M.rol(x, n)
  n = n % 32
  x = u32(x)
  if n == 0 then return sgn(x) end
  return sgn(u32(M.bor(M.lshift(x, n), M.rshift(x, 32 - n))))
end
function M.ror(x, n)
  n = n % 32
  x = u32(x)
  if n == 0 then return sgn(x) end
  return sgn(u32(M.bor(M.rshift(x, n), M.lshift(x, 32 - n))))
end

function M.tobit(x)
  x = u32(x)
  if x >= 2147483648 then return x - 4294967296 end
  return x
end

function M.tohex(x, n)
  x = u32(x)
  -- lowercase, like LuaJIT's bit.tohex
  local s = string.format("%08x", x)
  if n and n < 8 then s = s:sub(8 - n + 1) end
  return s
end

-- The 8-bit ops are exported too; the 6502 uses them directly for speed.
M.band8 = band8
M.bor8  = bor8
M.bxor8 = bxor8

return M
