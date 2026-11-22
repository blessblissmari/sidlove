-- ffi/fluid_ffi.lua - LuaJIT FFI binding to libfluidsynth (pure C API).
-- libfluidsynth's ABI is C and stable across the 2.x series (soname 3).
-- We bind the synthesizer + MIDI file player + settings subset that the
-- midi_player module needs. Audio output is NOT bound here - Love2D's
-- QueueableSource pulls the samples via fluid_synth_write_s16 / nwrite_float,
-- so we never create a fluid_audio_driver_t (and therefore never need
-- pulse/alsa/jack/pipewire at runtime - those drivers are compiled out of
-- the minimal libfluidsynth.so we ship; see README.md).

local ffi = require("ffi")

ffi.cdef[[
typedef struct _fluid_settings_t fluid_settings_t;
typedef struct _fluid_synth_t fluid_synth_t;
typedef struct _fluid_player_t fluid_player_t;
typedef struct _fluid_midi_event_t fluid_midi_event_t;
typedef struct _fluid_sfont_t fluid_sfont_t;
typedef struct _fluid_preset_t fluid_preset_t;
typedef struct _fluid_sample_t fluid_sample_t;
typedef struct _fluid_audio_driver_t fluid_audio_driver_t;
typedef struct _fluid_file_renderer_t fluid_file_renderer_t;
typedef struct _fluid_midi_router_t fluid_midi_router_t;
typedef struct _fluid_sequencer_t fluid_sequencer_t;
typedef struct _fluid_event_t fluid_event_t;
typedef struct _fluid_mod_t fluid_mod_t;

/* settings */
fluid_settings_t* new_fluid_settings(void);
void              delete_fluid_settings(fluid_settings_t*);
int               fluid_settings_setstr(fluid_settings_t*, const char* name, const char* str);
int               fluid_settings_setnum(fluid_settings_t*, const char* name, double val);
int               fluid_settings_setint(fluid_settings_t*, const char* name, int val);
int               fluid_settings_getnum(fluid_settings_t*, const char* name, double* val);

/* synth lifecycle */
fluid_synth_t*    new_fluid_synth(fluid_settings_t*);
void              delete_fluid_synth(fluid_synth_t*);
const char*       fluid_synth_error(fluid_synth_t*);
int               fluid_synth_system_reset(fluid_synth_t*);
int               fluid_synth_program_reset(fluid_synth_t*);

/* soundfont */
int               fluid_synth_sfload(fluid_synth_t*, const char* filename, int reset_presets);
int               fluid_synth_sfunload(fluid_synth_t*, unsigned int id, int reset_presets);
int               fluid_synth_sfcount(fluid_synth_t*);
int               fluid_synth_program_select(fluid_synth_t*, int chan, unsigned int sfont_id,
                                             int bank_num, int preset_num);
int               fluid_synth_sfont_select(fluid_synth_t*, int chan, unsigned int sfont_id);
int               fluid_synth_get_program(fluid_synth_t*, int chan, unsigned int* sfont_id,
                                          int* bank_num, int* preset_num);

/* MIDI channel messages - the live-patching surface */
int fluid_synth_noteon(fluid_synth_t*, int chan, int key, int vel);
int fluid_synth_noteoff(fluid_synth_t*, int chan, int key);
int fluid_synth_cc(fluid_synth_t*, int chan, int ctrl, int val);
int fluid_synth_get_cc(fluid_synth_t*, int chan, int ctrl, int* pval);
int fluid_synth_pitch_bend(fluid_synth_t*, int chan, int val);
int fluid_synth_get_pitch_bend(fluid_synth_t*, int chan, int* ppitch_bend);
int fluid_synth_pitch_wheel_sens(fluid_synth_t*, int chan, int val);
int fluid_synth_program_change(fluid_synth_t*, int chan, int program);
int fluid_synth_channel_pressure(fluid_synth_t*, int chan, int val);
int fluid_synth_key_pressure(fluid_synth_t*, int chan, int key, int val);
int fluid_synth_bank_select(fluid_synth_t*, int chan, int bank);
int fluid_synth_all_notes_off(fluid_synth_t*, int chan);
int fluid_synth_all_sounds_off(fluid_synth_t*, int chan);
int fluid_synth_set_gen(fluid_synth_t*, int chan, int param, float value);
float fluid_synth_get_gen(fluid_synth_t*, int chan, int param);

/* audio pull - the two functions we actually use per frame.
   write_s16 fills an interleaved L,R buffer in one call (preferred).
   nwrite_float writes separate L/R float planes (use if Love2D's source is
   stereo float). */
int fluid_synth_write_s16(fluid_synth_t*, int len,
                          void* lout, int loff, int lincr,
                          void* rout, int roff, int rincr);
int fluid_synth_write_float(fluid_synth_t*, int len,
                            void* lout, int loff, int lincr,
                            void* rout, int roff, int rincr);
int fluid_synth_nwrite_float(fluid_synth_t*, int len,
                             float** left, float** right,
                             float** fx_left, float** fx_right);

/* chorus / reverb (built-in, cheap) */
int fluid_synth_set_chorus_on(fluid_synth_t*, int on);
int fluid_synth_set_reverb_on(fluid_synth_t*, int on);
int fluid_synth_set_chorus(fluid_synth_t*, int nr, double level, double speed, double depth_ms, int type);
int fluid_synth_set_reverb(fluid_synth_t*, double roomsize, double damping, double width, double level);
double fluid_synth_get_cpu_load(fluid_synth_t*);
int fluid_synth_set_gain(fluid_synth_t*, float gain);

/* MIDI file player - runs in its own internal thread, feeds the synth */
fluid_player_t* new_fluid_player(fluid_synth_t*);
void            delete_fluid_player(fluid_player_t*);
int             fluid_player_add(fluid_player_t*, const char* midifile);
int             fluid_player_add_mem(fluid_player_t*, const void* buffer, size_t len);
int             fluid_player_play(fluid_player_t*);
int             fluid_player_stop(fluid_player_t*);
int             fluid_player_join(fluid_player_t*);
int             fluid_player_set_loop(fluid_player_t*, int loop);
int             fluid_player_set_tempo(fluid_player_t*, int tempo_type, double tempo);
int             fluid_player_get_status(fluid_player_t*);
int             fluid_player_get_current_tick(fluid_player_t*);
int             fluid_player_get_total_ticks(fluid_player_t*);
int             fluid_player_get_bpm(fluid_player_t*);
int             fluid_player_get_division(fluid_player_t*);
int             fluid_player_seek(fluid_player_t*, int ticks);
]]

-- player tempo type enum (fluid_player_set_tempo)
local M = {}
M.lib = nil
M.loaded = false

M.TEMPO_INTERNAL      = 0
M.TEMPO_EXTERNAL_BPM  = 1
M.TEMPO_EXTERNAL_MIDI = 2

M.PLAYER_READY   = 0
M.PLAYER_PLAYING = 1
M.PLAYER_STOPPING = 2
M.PLAYER_DONE    = 3

function M.load(libpath)
  local ok, lib = pcall(ffi.load, libpath)
  if not ok then return nil, lib end
  M.lib = lib
  M.loaded = true
  return M
end

return M
