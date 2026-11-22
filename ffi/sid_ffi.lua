-- ffi/sid_ffi.lua - LuaJIT FFI binding to sidlove_sid (the C shim around
-- libsidplayfp). The shim is a flat C ABI, so we can bind every function
-- directly. The SID model / C64 model / sampling constants are mirrored
-- from sidlove_sid.h so the Lua side is self-documenting.
--
-- This file only loads the shim and declares cdefs. sid_player wraps it.

local ffi = require("ffi")

ffi.cdef[[
typedef struct {
    uint8_t regs[32];
} sidlove_sid_status_t;

typedef struct {
    uint32_t songs;
    uint32_t start_song;
    uint32_t current_song;
    uint16_t load_addr;
    uint16_t init_addr;
    uint16_t play_addr;
    int      song_speed;
    int      clock_speed;
    int      sid_model;
    int      sid_chips;
    int      compatibility;
    char     format[32];
    char     title[64];
    char     author[64];
    char     released[64];
} sidlove_sid_tuneinfo_t;

void *      sidlove_sid_create(int sample_rate);
int         sidlove_sid_set_filter(void* h, double curve6581, double curve8580, int combined_waveforms);
int         sidlove_sid_load(void* h, const uint8_t* data, uint32_t len);
int         sidlove_sid_select_song(void* h, int song);
int         sidlove_sid_config(void* h, int sid_model, int c64_model, int force_model,
                               int digi_boost, int sampling_method,
                               uint16_t second_sid, uint16_t third_sid);
int         sidlove_sid_render(void* h, int16_t* out, int frames);
int         sidlove_sid_render_mono(void* h, int16_t* out, int frames);
uint32_t    sidlove_sid_time_ms(void* h);
void        sidlove_sid_mute(void* h, int sid_num, int voice, int enable);
void        sidlove_sid_filter(void* h, int sid_num, int enable);
int         sidlove_sid_get_status(void* h, int sid_num, sidlove_sid_status_t* out);
uint16_t    sidlove_sid_get_cia_timer(void* h);
int         sidlove_sid_installed_sids(void* h);
int         sidlove_sid_tuneinfo(void* h, sidlove_sid_tuneinfo_t* out);
const char* sidlove_sid_error(void* h);
int         sidlove_sid_reset(void* h);
void        sidlove_sid_destroy(void* h);
]]

-- Public constants, mirroring sidlove_sid.h. The Lua player modules import
-- these so user code can write sidlove.SID.MODEL_8580 etc.
local M = {}
M.lib = nil
M.loaded = false

M.MODEL_6581  = 0
M.MODEL_8580  = 1
M.MODEL_AUTO  = -1

M.C64_PAL      = 0
M.C64_NTSC     = 1
M.C64_OLD_NTSC = 2
M.C64_DREAN    = 3
M.C64_PAL_M    = 4
M.C64_AUTO     = -1

M.SAMPLE_INTERPOLATE = 0
M.SAMPLE_RESAMPLE    = 1

M.CW_AVERAGE = 0
M.CW_WEAK    = 1   -- reSIDfp default, sweet spot for most HVSC tunes
M.CW_STRONG  = 2

-- Voice indices for sidlove_sid_mute: 0..2 = oscillators, 3 = digi channel
M.VOICE_OSC_0 = 0
M.VOICE_OSC_1 = 1
M.VOICE_OSC_2 = 2
M.VOICE_DIGI  = 3

function M.load(libpath)
  local ok, lib = pcall(ffi.load, libpath)
  if not ok then return nil, lib end
  M.lib = lib
  M.loaded = true
  return M
end

-- Convenience: read the SID register snapshot as a Lua array of 32 ints.
-- regs[0..24] are the standard 25 SID registers; regs[25..31] are unused
-- by the chip but reserved for the digi channel in some engines.
function M.status_table(handle)
  local st = ffi.new("sidlove_sid_status_t[1]")
  if M.lib.sidlove_sid_get_status(handle, 0, st) ~= 0 then return nil end
  local t = {}
  for i = 0, 31 do t[i + 1] = st[0].regs[i] end
  return t
end

-- Pull the tuneinfo struct into a plain Lua table.
function M.tuneinfo_table(handle)
  local ti = ffi.new("sidlove_sid_tuneinfo_t[1]")
  if M.lib.sidlove_sid_tuneinfo(handle, ti) ~= 0 then return nil end
  local r = ti[0]
  return {
    songs        = tonumber(r.songs),
    start_song   = tonumber(r.start_song),
    current_song = tonumber(r.current_song),
    load_addr    = tonumber(r.load_addr),
    init_addr    = tonumber(r.init_addr),
    play_addr    = tonumber(r.play_addr),
    song_speed   = tonumber(r.song_speed),
    clock_speed  = tonumber(r.clock_speed),
    sid_model    = tonumber(r.sid_model),
    sid_chips    = tonumber(r.sid_chips),
    compatibility = tonumber(r.compatibility),
    format       = ffi.string(r.format),
    title        = ffi.string(r.title),
    author       = ffi.string(r.author),
    released     = ffi.string(r.released),
  }
end

return M
