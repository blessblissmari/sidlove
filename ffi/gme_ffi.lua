-- ffi/gme_ffi.lua - LuaJIT FFI binding to libgme (game-music-emu).
-- libgme is pure C with a stable ABI (soname 0). We bind it directly, no
-- shim needed. Supported formats via one C API: AY, GBS, GYM, HES, KSS, NSF,
-- NSFE, SAP, SPC, VGM, VGZ.
--
-- This file only loads the C library and declares the cdefs. The
-- chiptune_player module wraps it into a Love2D-friendly object.

local ffi = require("ffi")
local bit = require("bit")

local C = ffi.C

-- Match the symbols exported by libgme.so.0 / gme.h 0.6.6. gme_err_t is a
-- const char* (NULL on success). Music_Emu is opaque.
ffi.cdef[[
typedef const char* gme_err_t;
typedef struct Music_Emu Music_Emu;
typedef struct gme_info_t gme_info_t;
typedef const struct gme_type_t_* gme_type_t;

typedef struct {
    double treble;
    double bass;
    double d2,d3,d4,d5,d6,d7,d8,d9;
} gme_equalizer_t;

gme_err_t gme_open_file(const char* path, Music_Emu** out, int sample_rate);
gme_err_t gme_open_data(const void* data, long size, Music_Emu** out, int sample_rate);

const char* gme_identify_header(const void* header);
gme_type_t gme_identify_extension(const char* path_or_extension);
gme_err_t  gme_identify_file(const char* path, gme_type_t* type_out);

Music_Emu* gme_new_emu(gme_type_t type, int sample_rate);
Music_Emu* gme_new_emu_multi_channel(gme_type_t type, int sample_rate);

gme_err_t gme_load_file(Music_Emu*, const char* path);
gme_err_t gme_load_data(Music_Emu*, const void* data, long size);

int       gme_track_count(Music_Emu*);
gme_err_t gme_start_track(Music_Emu*, int index);
gme_err_t gme_play(Music_Emu*, int count, short* out);
void      gme_delete(Music_Emu*);

void      gme_set_fade(Music_Emu*, int start_msec);
void      gme_set_fade_msecs(Music_Emu*, int start_msec, int length_msecs);
void      gme_set_autoload_playback_limit(Music_Emu*, int do_autoload_limit);
int       gme_track_ended(Music_Emu*);
int       gme_tell(Music_Emu*);
int       gme_tell_samples(Music_Emu*);
gme_err_t gme_seek(Music_Emu*, int msec);
gme_err_t gme_seek_samples(Music_Emu*, int n);

gme_err_t gme_track_info(Music_Emu*, gme_info_t** out, int track);
void      gme_free_info(gme_info_t*);

void      gme_set_stereo_depth(Music_Emu*, double depth);
void      gme_ignore_silence(Music_Emu*, int ignore);
void      gme_set_tempo(Music_Emu*, double tempo);
int       gme_voice_count(Music_Emu*);
const char* gme_voice_name(Music_Emu*, int i);
void      gme_mute_voice(Music_Emu*, int index, int mute);
void      gme_mute_voices(Music_Emu*, int muting_mask);
void      gme_enable_accuracy(Music_Emu*, int enabled);

void      gme_equalizer(Music_Emu*, gme_equalizer_t* out);
void      gme_set_equalizer(Music_Emu*, const gme_equalizer_t* eq);

gme_type_t gme_type(Music_Emu*);
gme_type_t const* gme_type_list(void);
const char* gme_type_system(gme_type_t);
int         gme_type_multitrack(gme_type_t);
const char* gme_type_extension(gme_type_t);

gme_err_t gme_load_m3u(Music_Emu*, const char* path);
void      gme_clear_playlist(Music_Emu*);
int       gme_multi_channel(Music_Emu*);
]]

-- gme_info_t is an opaque struct to us; we never read its fields from Lua.
-- If we ever need track metadata we'd add the full struct cdef here.

local M = {}
M.lib = nil
M.loaded = false

-- Load the shared library. Called once by platform.lua with the resolved
-- path. Returns the ffi namespace on success, nil + error on failure.
function M.load(libpath)
  local ok, lib = pcall(ffi.load, libpath)
  if not ok then return nil, lib end
  M.lib = lib
  M.loaded = true
  return M
end

-- Friendly error → string (gme returns const char* or NULL).
function M.errstr(p)
  if p == nil then return nil end
  return ffi.string(p)
end

-- Map a file extension to its gme_type_t by calling gme_identify_extension.
-- Returns the gme_type_t (a pointer) or nil.
function M.type_for_extension(ext)
  if not M.loaded then return nil end
  local t = M.lib.gme_identify_extension(ext)
  -- gme_type_t is a pointer; NULL means unknown
  if t == nil then return nil end
  return t
end

-- Sniff a header (first 4 bytes) -> extension string like "NSF" or "".
function M.identify_header(header_bytes)
  if not M.loaded then return "" end
  local s = M.lib.gme_identify_header(header_bytes)
  if s == nil then return "" end
  return ffi.string(s)
end

return M
