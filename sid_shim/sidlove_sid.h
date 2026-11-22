/*
 * sidlove_sid.h - flat C ABI shim around libsidplayfp's C++ API.
 *
 * libsidplayfp exposes a C++ class API (sidplayfp, SidTune, ReSIDfpBuilder,
 * SidConfig). LuaJIT FFI only handles the C ABI, so this tiny shim wraps the
 * classes into stateless C functions operating on an opaque handle.
 *
 * Build: see Makefile in this directory. The shim links against libsidplayfp
 * (soname 6, version >= 2.0). reSIDfp is bundled inside libsidplayfp.so on
 * Debian/Ubuntu and inside the official windows/macOS builds, so no separate
 * libresidfp is needed.
 *
 * The handle owns: one ReSIDfpBuilder*, one sidplayfp*, one SidTune* (NULL
 * until a tune is loaded), and the last SidConfig used. All sidlove_sid_*
 * functions are safe to call from a single thread (the audio thread); they
 * are NOT internally synchronised - the Lua streamer guarantees serial access.
 */
#ifndef SIDLOVE_SID_H
#define SIDLOVE_SID_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C64 / SID model constants - mirror SidConfig enums, kept stable across
 * libsidplayfp versions so the Lua side never has to know the enum order. */
#define SIDLOVE_MODEL_6581   0   /* old SID, dark filter, twisted-waveform */
#define SIDLOVE_MODEL_8580   1   /* new SID, clean filter */
#define SIDLOVE_MODEL_AUTO  -1   /* honour the tune's own model flag */

#define SIDLOVE_C64_PAL      0
#define SIDLOVE_C64_NTSC     1
#define SIDLOVE_C64_OLD_NTSC 2
#define SIDLOVE_C64_DREAN    3
#define SIDLOVE_C64_PAL_M    4
#define SIDLOVE_C64_AUTO    -1

#define SIDLOVE_SAMPLE_INTERPOLATE       0
#define SIDLOVE_SAMPLE_RESAMPLE          1

/* SID register snapshot, used by raster/live-patch modules.
 * 32 bytes mirrors libsidplayfp's getSidStatus(uint8_t regs[32]). */
typedef struct {
    uint8_t regs[32];
} sidlove_sid_status_t;

/* Sub-song info, mirrors the bits of SidTuneInfo we actually use. */
typedef struct {
    uint32_t songs;
    uint32_t start_song;
    uint32_t current_song;
    uint16_t load_addr;
    uint16_t init_addr;
    uint16_t play_addr;
    int      song_speed;          /* 0 = VBI, 60 = CIA1 timer A */
    int      clock_speed;         /* 0 unknown, 1 PAL, 2 NTSC, 3 any */
    int      sid_model;           /* 0 unknown, 1 6581, 2 8580, 3 any */
    int      sid_chips;           /* number of SID chips the tune uses */
    int      compatibility;       /* 0 C64, 1 PSID, 2 R64, 3 BASIC */
    char     format[32];
    char     title[64];
    char     author[64];
    char     released[64];
} sidlove_sid_tuneinfo_t;

/* Create a player. sample_rate is the Love2D audio rate (e.g. 44100).
 * Returns NULL on out-of-memory (rare). The builder is created here so
 * filter-curve tweaks can be applied before loading a tune. */
void * sidlove_sid_create(int sample_rate);

/* Set the global reSIDfp filter curve. Call before sidlove_sid_load for the
 * curve to apply to the first tune; can be re-applied between tunes.
 *   curve6581: 0.0 (light) .. 1.0 (dark), default 0.5
 *   curve8580: centre frequency in Hz, default 12500
 *   combined_waveforms: 0=AVERAGE, 1=WEAK, 2=STRONG
 * Returns 0 on success, non-zero if the builder rejected the value. */
int sidlove_sid_set_filter(void *h, double curve6581, double curve8580,
                           int combined_waveforms);

/* Load a tune from memory (.sid / .prg / .mus / PSID / RSID). The buffer is
 * copied internally by libsidplayfp, so the caller may free it immediately.
 * Returns 0 on success, non-zero on parse error (use sidlove_sid_error). */
int sidlove_sid_load(void *h, const uint8_t *data, uint32_t len);

/* Select a sub-song (0 = default starting song). Must be called after load.
 * Returns the actually-selected song number, or 0 on failure. */
int sidlove_sid_select_song(void *h, int song);

/* Apply the engine configuration. Call after load + select_song. Returns 0
 * on success. sid_model / c64_model accept the SIDLOVE_* constants above. */
int sidlove_sid_config(void *h, int sid_model, int c64_model,
                       int force_model, int digi_boost,
                       int sampling_method,
                       uint16_t second_sid, uint16_t third_sid);

/* Render `frames` stereo frames into `out` (interleaved L,R,L,R... signed
 * 16-bit). Returns the number of frames actually written. Internally this
 * runs the C64 CPU for the matching number of cycles, mixes all installed
 * SID chips, and writes the result. This is the hot path - called every
 * Love2D audio frame. */
int sidlove_sid_render(void *h, int16_t *out, int frames);

/* Render into a mono buffer. Used when Love2D's source is mono. */
int sidlove_sid_render_mono(void *h, int16_t *out, int frames);

/* Current playback time in milliseconds. */
uint32_t sidlove_sid_time_ms(void *h);

/* Mute/unmute a voice on a SID. sidNum 0..2, voice 0..2 (oscillators) or
 * 3 (the 4-bit digi/sample channel). enable=1 unmutes. */
void sidlove_sid_mute(void *h, int sid_num, int voice, int enable);

/* Enable/disable the analog filter on one SID. For live "filter sweep" tricks
 * typical in C64 demos. */
void sidlove_sid_filter(void *h, int sid_num, int enable);

/* Snapshot the 32 SID registers of `sid_num` into `out`. Returns 0 on
 * success. This is what raster-synced visuals read to mirror the SID state
 * on screen - the same trick A Mind Is Born uses to drive its raster bars. */
int sidlove_sid_get_status(void *h, int sid_num, sidlove_sid_status_t *out);

/* CIA 1 Timer A programmed value - the raster IRQ heartbeat. The Lua raster
 * module divides this by the C64 clock to derive the play-routine rate. */
uint16_t sidlove_sid_get_cia_timer(void *h);

/* Number of installed SID chips (1 unless the tune has $d400+$d440+$d440
 * style second/third SID addresses). */
int sidlove_sid_installed_sids(void *h);

/* Fill in tune info. Returns 0 on success. */
int sidlove_sid_tuneinfo(void *h, sidlove_sid_tuneinfo_t *out);

/* Last error string (valid until the next call into the shim). */
const char * sidlove_sid_error(void *h);

/* Reset the engine (re-init) without reloading the tune. Use for "restart
 * from the top" without paying the parse cost. */
int sidlove_sid_reset(void *h);

/* Tear down everything. NULL-safe. */
void sidlove_sid_destroy(void *h);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SIDLOVE_SID_H */
