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
  -- Real LuaJIT bit library — pass everything through.
  return realbit
end

-- --- arithmetic fallback (vanilla Lua 5.1) ---------------------------------
-- All inputs are treated as unsigned 32-bit. We build 16x16 nibble tables
-- for the byte ops so the common case (8-bit AND/OR/XOR in the 6502) is two
-- table lookups + an add, not a 32-iteration loop.

local floor = math.floor

local AND_NIB = {}  -- AND_NIB[a*16+b] = a AND b, for a,b in 0..15
local OR_NIB  = {}
local XOR_NIB = {}
for a = 0, 15 do
  for b = 0, 15 do
    local function bn(x, y)  -- 4-bit AND
      local r = 0; local m = 1
      for _ = 0, 3 do
        if x % 2 == 1 and y % 2 == 1 then r = r + m end
        x = floor(x / 2); y = floor(y / 2); m = m * 2
      end
      return r
    end
    local function bo(x, y)
      local r = 0; local m = 1
      for _ = 0, 3 do
        if x % 2 == 1 or y % 2 == 1 then r = r + m end
        x = floor(x / 2); y = floor(y / 2); m = m * 2
      end
      return r
    end
    local function bx(x, y)
      local r = 0; local m = 1
      for _ = 0, 3 do
        if x % 2 ~= y % 2 then r = r + m end
        x = floor(x / 2); y = floor(y / 2); m = m * 2
      end
      return r
    end
    AND_NIB[a * 16 + b] = bn(a, b)
    OR_NIB[a * 16 + b]  = bo(a, b)
    XOR_NIB[a * 16 + b] = bx(a, b)
  end
end

local function u32(n)
  n = n % 4294967296
  if n < 0 then n = n + 4294967296 end
  return n
end

-- 8-bit ops via nibble tables: split a byte into hi/lo nibbles, table-lookup,
-- recombine. Fast enough for a 6502 in WASM.
local function band8(a, b)
  a = a % 256; b = b % 256
  local ah = floor(a / 16); local al = a % 16
  local bh = floor(b / 16); local bl = b % 16
  return AND_NIB[ah * 16 + bh] * 16 + AND_NIB[al * 16 + bl]
end
local function bor8(a, b)
  a = a % 256; b = b % 256
  local ah = floor(a / 16); local al = a % 16
  local bh = floor(b / 16); local bl = b % 16
  return OR_NIB[ah * 16 + bh] * 16 + OR_NIB[al * 16 + bl]
end
local function bxor8(a, b)
  a = a % 256; b = b % 256
  local ah = floor(a / 16); local al = a % 16
  local bh = floor(b / 16); local bl = b % 16
  return XOR_NIB[ah * 16 + bh] * 16 + XOR_NIB[al * 16 + bl]
end

-- 32-bit variants: split into 4 bytes, op each, recombine.
local function band32(a, b)
  a = u32(a); b = u32(b)
  local r = 0
  local p = 1
  for _ = 1, 4 do
    r = r + band8(a % 256, b % 256) * p
    a = floor(a / 256); b = floor(b / 256); p = p * 256
  end
  return r
end
local function bor32(a, b)
  a = u32(a); b = u32(b)
  local r = 0
  local p = 1
  for _ = 1, 4 do
    r = r + bor8(a % 256, b % 256) * p
    a = floor(a / 256); b = floor(b / 256); p = p * 256
  end
  return r
end
local function bxor32(a, b)
  a = u32(a); b = u32(b)
  local r = 0
  local p = 1
  for _ = 1, 4 do
    r = r + bxor8(a % 256, b % 256) * p
    a = floor(a / 256); b = floor(b / 256); p = p * 256
  end
  return r
end

-- Wrap to signed 32-bit so results match LuaJIT's `bit` library, which
-- returns signed values (e.g. bnot(0) == -1, not 4294967295). rshift stays
-- unsigned because LuaJIT's rshift is logical.
local function sgn(n) n = u32(n); if n >= 2147483648 then return n - 4294967296 end return n end

function M.band(a, b, ...)
  if not b then return sgn(a) end
  local r = band32(a, b)
  local more = {...}
  for i = 1, #more do r = band32(r, more[i]) end
  return sgn(r)
end
function M.bor(a, b, ...)
  if not b then return sgn(a) end
  local r = bor32(a, b)
  local more = {...}
  for i = 1, #more do r = bor32(r, more[i]) end
  return sgn(r)
end
function M.bxor(a, b, ...)
  if not b then return sgn(a) end
  local r = bxor32(a, b)
  local more = {...}
  for i = 1, #more do r = bxor32(r, more[i]) end
  return sgn(r)
end
function M.bnot(x)
  return sgn(4294967295 - u32(x))
end

function M.lshift(x, n)
  n = n % 32
  if n == 0 then return sgn(u32(x)) end
  x = u32(x)
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
  x = u32(x)
  if x >= 2147483648 then  -- negative when interpreted as signed
    return floor((x - 4294967296) / (2 ^ n)) + 4294967296 - floor(4294967296 / (2 ^ n))  -- sign-extend
  end
  return floor(x / (2 ^ n))
end
function M.rol(x, n)
  n = n % 32
  x = u32(x)
  if n == 0 then return x end
  return u32(M.bor(M.lshift(x, n), M.rshift(x, 32 - n)))
end
function M.ror(x, n)
  n = n % 32
  x = u32(x)
  if n == 0 then return x end
  return u32(M.bor(M.rshift(x, n), M.lshift(x, 32 - n)))
end

function M.tobit(x)
  x = u32(x)
  if x >= 2147483648 then return x - 4294967296 end
  return x
end

function M.tohex(x, n)
  x = u32(x)
  local s = string.format("%08X", x)
  if n and n < 8 then s = s:sub(8 - n + 1) end
  return s
end

-- The 8-bit ops are exported too; the 6502 uses them directly for speed.
M.band8 = band8
M.bor8  = bor8
M.bxor8 = bxor8

return M
