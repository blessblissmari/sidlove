-- platform.lua - resolves the native library path for the current OS/arch
-- and loads all three engines. Returns a table the player modules use.
--
-- Layout convention (what the README tells the user to ship):
--
--   <game>/sidlove/native/
--     linux-x64/   libgme.so, libsidplayfp.so.6, sidlove_sid.so, libfluidsynth.so.3
--     linux-arm64/ ... (Raspberry Pi 4 etc.)
--     windows-x64/ libgme.dll, libsidplayfp.dll, sidlove_sid.dll, libfluidsynth.dll, *.dll deps
--     macos/       libgme.dylib, libsidplayfp.dylib, sidlove_sid.dylib, libfluidsynth.dylib
--     android-arm64/  libgme.so, libsidplayfp.so, sidlove_sid.so, libfluidsynth.so
--
-- On macOS and Windows the deps (libstdc++, libm, libc) are part of the OS
-- runtime and never shipped. On Linux we ship libsndfile.so.1 for fluidsynth
-- unless the user prefers to build fluidsynth without sfloader (see README).
-- On Android we ship libc++_shared.so instead of libstdc++.
--
-- If a library is missing the corresponding engine is simply unavailable -
-- sidlove.load("foo.sid") returns nil + a clear error. The other engines
-- still work. This lets a game ship just the SID engine to save space.
--
-- v2.0: FFI is now OPTIONAL. love.js (and any Lua 5.1 runtime without
-- LuaJIT) has no FFI, so the native engines can't load there. In that case
-- we set M.web=true and M.engines.pure stays true (the pure-Lua SID path
-- needs no FFI), and sidlove routes .sid/.prg to sid_pure_player. The native
-- path still works unchanged on desktop LuaJIT where FFI is present.

local have_ffi, ffi = pcall(require, "ffi")
local gme_ffi, sid_ffi, fluid_ffi
if have_ffi then
  -- these modules themselves require("ffi"); load them only when ffi exists
  -- so a missing ffi doesn't break the whole library on web.
  gme_ffi   = require("sidlove.ffi.gme_ffi")
  sid_ffi   = require("sidlove.ffi.sid_ffi")
  fluid_ffi = require("sidlove.ffi.fluid_ffi")
end

local M = {}
M.os = nil
M.arch = nil
M.dir = nil          -- the native/<tag> directory
M.web = false        -- true when running without FFI (love.js / WASM)
M.engines = { gme = false, sid = false, fluid = false, pure = true }

-- Detect the platform. Love2D sets love._os; LuaJIT sets jit.os / jit.arch.
-- We prefer love._os when present because it distinguishes Android from
-- generic Linux, which jit.os cannot. If neither love._os nor jit is
-- available we're in love.js / a no-FFI Lua -> "Web".
local function detect()
  local os_name, arch
  local ok_love, love_t = pcall(require, "love")
  local love_os
  if ok_love and love_t and love_t._os then love_os = love_t._os end
  if love_os == "windows" then os_name = "Windows"
  elseif love_os == "osx"   then os_name = "OSX"
  elseif love_os == "android" then os_name = "Android"
  elseif love_os == "ios" then os_name = "iOS"
  elseif have_ffi and jit then
    os_name = jit.os    -- "Linux", "Windows", "OSX", "BSD"
  else
    os_name = "Web"     -- love.js / vanilla Lua 5.1 without jit
  end
  if have_ffi and jit then
    arch = jit.arch    -- "x64", "x86", "arm64", "arm", "mips"...
  else
    arch = "wasm"
  end
  return os_name, arch
end

-- Map (os, arch) -> the subdirectory tag under native/.
local function tag_for(os_name, arch)
  if os_name == "Windows" then
    return arch == "x86" and "windows-x86" or "windows-x64"
  elseif os_name == "OSX" then
    return "macos"   -- universal dylibs, no arch split
  elseif os_name == "Android" then
    return arch == "arm64" and "android-arm64" or "android-arm"
  elseif os_name == "iOS" then
    return "ios-arm64"
  elseif os_name == "Linux" or os_name == "BSD" then
    if arch == "x86" then return "linux-x86"
    elseif arch == "arm64" then return "linux-arm64"
    elseif arch == "arm" then return "linux-arm"
    else return "linux-x64" end
  end
  return nil  -- "Web" has no native dir
end

-- Resolve the native dir on the real filesystem (native .so/.dll can't live
-- inside a zipped .love; the OS loader can't read them from there).
local function resolve_native_dir(native_subdir)
  local candidates = {}
  local ok, love = pcall(require, "love")
  if ok and love and love.filesystem then
    local sb = love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory() or nil
    if sb then table.insert(candidates, sb .. "/sidlove/native/" .. native_subdir) end
    local sd = love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory() or nil
    if sd then table.insert(candidates, sd .. "/sidlove/native/" .. native_subdir) end
  end
  table.insert(candidates, "./sidlove/native/" .. native_subdir)
  table.insert(candidates, "./native/" .. native_subdir)
  for _, c in ipairs(candidates) do
    for _, probe in ipairs{"libgme.so","libgme.dll","libgme.dylib","sidlove_sid.so","sidlove_sid.dll"} do
      local pf = io.open(c .. "/" .. probe, "rb")
      if pf then pf:close() return c end
    end
  end
  return candidates[1]  -- return best guess even if empty, so error msgs are useful
end

local function lib_names(os_name, base)
  if os_name == "Windows" then return { base .. ".dll" } end
  if os_name == "OSX"     then return { base .. ".dylib" } end
  return { base .. ".so", base .. ".so.6", base .. ".so.3", base .. ".so.0" }
end

local function try_load_any(dir, base, os_name)
  if not have_ffi then return nil, "no FFI (web build)" end
  local names = lib_names(os_name, base)
  local last_err
  for _, n in ipairs(names) do
    local path = dir .. "/" .. n
    local ok, lib = pcall(ffi.load, path)
    if ok then return lib end
    last_err = lib
  end
  return nil, last_err or "not found"
end

-- Public entry point. Call once at game startup (sidlove.init() does this).
function M.init(native_root)
  M.os, M.arch = detect()
  local tag = tag_for(M.os, M.arch)
  M.tag = tag
  M.dir = tag and (native_root and (native_root .. "/" .. tag) or resolve_native_dir(tag)) or nil

  -- Web / no-FFI: skip native loading entirely. The pure-Lua SID path
  -- (sidlove.bit + m6502 + sidchip + sid_pure_player) handles .sid/.prg with
  -- no native libs. chiptune/midi are unavailable on web (documented).
  if not have_ffi or M.os == "Web" then
    M.web = true
    return M
  end

  local g = M.dir and try_load_any(M.dir, "libgme", M.os)
  if g then gme_ffi.load(""); gme_ffi.lib = g; gme_ffi.loaded = true; M.engines.gme = true end

  local s = M.dir and try_load_any(M.dir, "sidlove_sid", M.os)
  if s then sid_ffi.load(""); sid_ffi.lib = s; sid_ffi.loaded = true; M.engines.sid = true end

  local f = M.dir and try_load_any(M.dir, "libfluidsynth", M.os)
  if f then fluid_ffi.load(""); fluid_ffi.lib = f; fluid_ffi.loaded = true; M.engines.fluid = true end

  if not M.engines.gme then
    local ok, lib = pcall(ffi.load, "gme")
    if ok then gme_ffi.lib = lib; gme_ffi.loaded = true; M.engines.gme = true end
  end
  if not M.engines.fluid then
    local ok, lib = pcall(ffi.load, "fluidsynth")
    if ok then fluid_ffi.lib = lib; fluid_ffi.loaded = true; M.engines.fluid = true end
  end

  return M
end

return M
