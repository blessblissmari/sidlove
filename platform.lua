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

local ffi = require("ffi")
local gme_ffi   = require("sidlove.ffi.gme_ffi")
local sid_ffi   = require("sidlove.ffi.sid_ffi")
local fluid_ffi = require("sidlove.ffi.fluid_ffi")

local M = {}
M.os = nil
M.arch = nil
M.dir = nil          -- the native/<tag> directory
M.engines = { gme = false, sid = false, fluid = false }

-- Detect the platform. Love2D sets love._os; LuaJIT sets jit.os / jit.arch.
-- We prefer love._os when present because it distinguishes Android from
-- generic Linux, which jit.os cannot.
local function detect()
  local os_name, arch
  local ok_love, love_t = pcall(require, "love")
  local love_os
  if ok_love and love_t and love_t._os then love_os = love_t._os end
  -- love._os is one of: "windows", "linux", "osx", "android", "ios"
  if love_os == "windows" then os_name = "Windows"
  elseif love_os == "osx"   then os_name = "OSX"
  elseif love_os == "android" then os_name = "Android"
  elseif love_os == "ios" then os_name = "iOS"
  else
    os_name = jit.os    -- "Linux", "Windows", "OSX", "BSD"
  end
  arch = jit.arch      -- "x64", "x86", "arm64", "arm", "mips"...
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
  return nil
end

-- Resolve a file path inside the game. In Love2D the game's files are inside
-- the .love archive by default, but native .so/.dll CANNOT live inside a
-- zipped .love (the OS loader can't read them from there). They must sit on
-- the real filesystem next to the executable. We use love.filesystem.getSaveDirectory
-- or the source directory. For a fused game this is the same as the exe dir.
local function resolve_native_dir(native_subdir)
  -- Try, in order:
  --  1.love.filesystem.getSourceBaseDirectory()/<game>/sidlove/native/<tag> (unfused)
  --  2.love.filesystem.getSaveDirectory()/sidlove/native/<tag>
  --  3. relative ./sidlove/native/<tag> (for plain `luajit main.lua` testing)
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
    local f = io.open(c .. "/.exists", "r")
    if f then f:close() return c end
    -- fall back: check if any .so/.dll is in there
    f = io.open(c, "r")
    if f then f:close() end
    -- cheap probe: try to open the first candidate file
    for _, probe in ipairs{"libgme.so","libgme.dll","libgme.dylib","sidlove_sid.so","sidlove_sid.dll"} do
      local pf = io.open(c .. "/" .. probe, "rb")
      if pf then pf:close() return c end
    end
  end
  return candidates[1]  -- return best guess even if empty, so error msgs are useful
end

-- The library file names per OS. libsidplayfp's soname matters on Linux:
-- the loader wants libsidplayfp.so.6, not libsidplayfp.so, unless the dev
-- symlink is shipped too. We try soname first, then bare name.
local function lib_names(os_name, base)
  if os_name == "Windows" then return { base .. ".dll" } end
  if os_name == "OSX"     then return { base .. ".dylib" } end
  -- Linux / Android: try soname then bare .so
  return { base .. ".so", base .. ".so.6", base .. ".so.3", base .. ".so.0" }
end

local function try_load_any(dir, base, os_name)
  local names = lib_names(os_name, base)
  local last_err
  for _, n in ipairs(names) do
    local path = dir .. "/" .. n
    local f = io.open(path, "rb")
    if f then f:close() end
    -- We don't require the file to exist on disk for the FFI load attempt -
    -- sometimes it's reachable via the system loader path. But for a bundled
    -- game we want the file in our native dir, so the existence check keeps
    -- error messages honest.
    local ok, lib = pcall(ffi.load, path)
    if ok then return lib end
    last_err = lib
  end
  return nil, last_err or "not found"
end

-- Public entry point. Call once at game startup (sidlove.init() does this).
-- `native_root` is optional; if nil we auto-resolve as above.
function M.init(native_root)
  M.os, M.arch = detect()
  local tag = tag_for(M.os, M.arch)
  if not tag then
    return nil, "sidlove: unsupported platform " .. tostring(M.os) .. "/" .. tostring(M.arch)
  end
  M.tag = tag
  M.dir = native_root and (native_root .. "/" .. tag) or resolve_native_dir(tag)

  -- Load each engine independently. Failure of one does not abort the others.
  local g = M.dir and try_load_any(M.dir, "libgme", M.os)
  if g then gme_ffi.load(""); gme_ffi.lib = g; gme_ffi.loaded = true; M.engines.gme = true end

  local s = M.dir and try_load_any(M.dir, "sidlove_sid", M.os)
  if s then sid_ffi.load(""); sid_ffi.lib = s; sid_ffi.loaded = true; M.engines.sid = true end

  local f = M.dir and try_load_any(M.dir, "libfluidsynth", M.os)
  if f then fluid_ffi.load(""); fluid_ffi.lib = f; fluid_ffi.loaded = true; M.engines.fluid = true end

  -- Also try system loader for libgme (commonly installed on Linux).
  if not M.engines.gme then
    local ok, lib = pcall(ffi.load, "gme")
    if ok then gme_ffi.lib = lib; gme_ffi.loaded = true; M.engines.gme = true end
  end
  -- And system libfluidsynth.
  if not M.engines.fluid then
    local ok, lib = pcall(ffi.load, "fluidsynth")
    if ok then fluid_ffi.lib = lib; fluid_ffi.loaded = true; M.engines.fluid = true end
  end

  return M
end

return M
