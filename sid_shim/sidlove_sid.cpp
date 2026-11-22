// sidlove_sid.cpp - flat C ABI shim around libsidplayfp's C++ API.
//
// See sidlove_sid.h for the contract. This file is the only C++ in sidlove;
// everything downstream (LuaJIT FFI) talks to the C symbols declared there.
//
// Build (see Makefile):
//   g++ -O2 -shared -fPIC -I<sidplayfp-include> sidlove_sid.cpp \
//       -o sidlove_sid.so -L<sidplayfp-lib> -lsidplayfp -lstdc++
//
// The shim is exception-safe: every libsidplayfp call that can throw is
// wrapped, and the error string is stashed in the handle for the Lua side
// to pick up via sidlove_sid_error().

#include "sidlove_sid.h"

#include <new>
#include <string>
#include <cstring>
#include <cstdio>

#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/SidInfo.h>
#include <sidplayfp/builders/residfp.h>

namespace {

// C64 CPU clock rates in Hz. These are the canonical figures libsidplayfp
// emulates; the cycles-per-sample ratio is derived from them.
//   PAL  985248.0   (C64 PAL, 50.125 Hz video)
//   NTSC 1022727.5  (C64 NTSC, 59.826 Hz video)
constexpr double CLOCK_PAL  = 985248.0;
constexpr double CLOCK_NTSC = 1022727.5;

struct Handle {
    ReSIDfpBuilder* builder;
    sidplayfp*      player;
    SidTune*        tune;
    SidConfig       config;
    double          clock_hz;        // set after config(), used by render()
    int             sample_rate;
    bool            stereo;
    std::string     err;

    Handle()
        : builder(nullptr), player(nullptr), tune(nullptr),
          clock_hz(CLOCK_PAL), sample_rate(44100), stereo(true) {}

    void set_err(const char* msg) { err = msg ? msg : "unknown error"; }
};

// Map our public model constants to libsidplayfp's enum values. The enum
// order in SidConfig.h has been stable since 2.0 (MOS6581=0, MOS8580=1).
inline SidConfig::sid_model_t to_sid_model(int m) {
    return (m == SIDLOVE_MODEL_6581) ? SidConfig::MOS6581
         : (m == SIDLOVE_MODEL_8580) ? SidConfig::MOS8580
         : SidConfig::MOS6581; // AUTO resolved later from tune info
}
inline SidConfig::c64_model_t to_c64_model(int m) {
    switch (m) {
        case SIDLOVE_C64_NTSC:     return SidConfig::NTSC;
        case SIDLOVE_C64_OLD_NTSC: return SidConfig::OLD_NTSC;
        case SIDLOVE_C64_DREAN:    return SidConfig::DREAN;
        case SIDLOVE_C64_PAL_M:    return SidConfig::PAL_M;
        case SIDLOVE_C64_PAL:
        case SIDLOVE_C64_AUTO:
        default:                   return SidConfig::PAL;
    }
}
inline SidConfig::sid_cw_t to_cw(int cw) {
    return cw == 0 ? SidConfig::AVERAGE
         : cw == 2 ? SidConfig::STRONG
         : SidConfig::WEAK; // 1 = WEAK is the reSIDfp default sweet spot
}

// Resolve the actual C64 clock after config(). If forceC64Model is set the
// engine honours defaultC64Model; otherwise the tune's own clock wins.
// SidInfo::speedString() returns "PAL" / "NTSC" / "VBI" / "CIA1 Timer A".
inline double resolve_clock(const sidplayfp* p) {
    const SidInfo& info = p->info();
    const char* clk = info.speedString();
    if (clk && std::strstr(clk, "NTSC")) return CLOCK_NTSC;
    return CLOCK_PAL;
}

} // namespace

extern "C" {

void * sidlove_sid_create(int sample_rate) {
    if (sample_rate <= 0) sample_rate = 44100;
    Handle* h = nullptr;
    try { h = new Handle(); }
    catch (...) { return nullptr; }
    h->sample_rate = sample_rate;
    try {
        h->builder = new ReSIDfpBuilder("sidlove");
        // reSIDfp defaults: filter on, 6581 curve 0.5, 8580 curve 12500,
        // combined waveforms WEAK. These match what most HVSC tunes expect.
        h->builder->filter(true);
        h->builder->filter6581Curve(0.5);
        h->builder->filter8580Curve(12500.0);
        h->builder->combinedWaveformsStrength(SidConfig::WEAK);
        // create() with sids=1; the engine upgrades automatically when a
        // tune declares a second/third SID address.
        if (h->builder->create(1) == 0) {
            h->set_err(h->builder->error());
            // fall through; load() will fail loudly if the builder is broken
        }
        h->player = new sidplayfp();
        h->config = h->player->config();
        h->config.frequency = sample_rate;
        h->config.sidEmulation = h->builder;
        h->config.defaultC64Model = SidConfig::PAL;
        h->config.defaultSidModel = SidConfig::MOS6581;
        h->config.forceC64Model = false;
        h->config.forceSidModel = false;
        h->config.digiBoost = false;
        h->config.samplingMethod = SidConfig::INTERPOLATE;
        h->config.secondSidAddress = 0;
        h->config.thirdSidAddress = 0;
        h->config.powerOnDelay = SidConfig::DEFAULT_POWER_ON_DELAY;
    } catch (const std::bad_alloc&) {
        h->set_err("out of memory");
    } catch (const std::exception& e) {
        h->set_err(e.what());
    } catch (...) {
        h->set_err("unknown exception during create");
    }
    return h;
}

int sidlove_sid_set_filter(void *p, double c6581, double c8580, int cw) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->builder) { if (h) h->set_err("no builder"); return 1; }
    try {
        h->builder->filter6581Curve(c6581);
        h->builder->filter8580Curve(c8580);
        h->builder->combinedWaveformsStrength(to_cw(cw));
        return 0;
    } catch (const std::exception& e) {
        h->set_err(e.what()); return 1;
    } catch (...) {
        h->set_err("unknown exception in set_filter"); return 1;
    }
}

int sidlove_sid_load(void *p, const uint8_t *data, uint32_t len) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) { if (h) h->set_err("no player"); return 1; }
    if (!data || len == 0) { h->set_err("empty tune buffer"); return 1; }
    try {
        // Drop any previous tune.
        if (h->tune) { delete h->tune; h->tune = nullptr; }
        // SidTune(buffer, len) auto-detects PSID/RSID/PRG/MUS. The buffer
        // is copied internally, so the caller may free it after this returns.
        h->tune = new SidTune(data, len);
        if (!h->tune->getStatus()) {
            h->set_err(h->tune->statusString());
            delete h->tune; h->tune = nullptr;
            return 1;
        }
        // Select the default starting song.
        const SidTuneInfo* info = h->tune->getInfo();
        if (info) h->tune->selectSong(info->startSong());
        // Push the tune into the player.
        if (!h->player->load(h->tune)) {
            h->set_err(h->player->error());
            return 1;
        }
        return 0;
    } catch (const std::bad_alloc&) {
        h->set_err("out of memory"); return 1;
    } catch (const std::exception& e) {
        h->set_err(e.what()); return 1;
    } catch (...) {
        h->set_err("unknown exception in load"); return 1;
    }
}

int sidlove_sid_select_song(void *p, int song) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->tune) { if (h) h->set_err("no tune loaded"); return 0; }
    try {
        unsigned int picked = h->tune->selectSong(song > 0 ? song - 1 : 0);
        // Reloading the (same) tune object re-runs init with the new song.
        if (!h->player->load(h->tune)) {
            h->set_err(h->player->error());
            return 0;
        }
        return (int)picked + 1;
    } catch (const std::exception& e) {
        h->set_err(e.what()); return 0;
    } catch (...) {
        h->set_err("unknown exception in select_song"); return 0;
    }
}

int sidlove_sid_config(void *p, int sid_model, int c64_model,
                       int force_model, int digi_boost,
                       int sampling_method,
                       uint16_t second_sid, uint16_t third_sid) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) { if (h) h->set_err("no player"); return 1; }
    try {
        h->config.defaultC64Model = to_c64_model(c64_model);
        h->config.defaultSidModel = to_sid_model(sid_model);
        h->config.forceC64Model  = (force_model != 0);
        h->config.forceSidModel  = (force_model != 0);
        h->config.digiBoost      = (digi_boost != 0);
        h->config.samplingMethod = (sampling_method == SIDLOVE_SAMPLE_RESAMPLE)
                                   ? SidConfig::RESAMPLE_INTERPOLATE
                                   : SidConfig::INTERPOLATE;
        h->config.secondSidAddress = second_sid;
        h->config.thirdSidAddress  = third_sid;
        if (!h->player->config(h->config)) {
            h->set_err(h->player->error());
            return 1;
        }
        h->clock_hz = resolve_clock(h->player);
        return 0;
    } catch (const std::exception& e) {
        h->set_err(e.what()); return 1;
    } catch (...) {
        h->set_err("unknown exception in config"); return 1;
    }
}

int sidlove_sid_render(void *p, int16_t *out, int frames) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player || !out || frames <= 0) return 0;
    try {
        // cycles needed to produce `frames` samples at this clock.
        // +1 cycle absorbs rounding so play() never under-produces.
        const double cycles_per_sample = h->clock_hz / (double)h->sample_rate;
        unsigned int cycles_needed = (unsigned int)(frames * cycles_per_sample + 1.0);

        h->player->initMixer(h->stereo);
        int total = 0;
        // Loop handles the rare case where play() produces fewer samples
        // than requested (it rounds down). We top up until we have `frames`.
        while (total < frames) {
            int got = h->player->play(cycles_needed);
            if (got < 0) { h->set_err(h->player->error()); break; }
            if (got == 0) break; // hardware device or stuck
            int want = frames - total;
            if (got > want) got = want;
            // mix() writes `got` samples for mono or `got*2` shorts for stereo
            // into out. For stereo it interleaves L,R,L,R.
            unsigned int mixed = h->player->mix(out + total * (h->stereo ? 2 : 1),
                                                (unsigned int)got);
            (void)mixed;
            total += got;
            // shrink the next cycle ask so we don't overshoot wildly
            cycles_needed = (unsigned int)((frames - total) * cycles_per_sample + 1.0);
        }
        return total;
    } catch (const std::exception& e) {
        h->set_err(e.what()); return 0;
    } catch (...) {
        h->set_err("unknown exception in render"); return 0;
    }
}

int sidlove_sid_render_mono(void *p, int16_t *out, int frames) {
    Handle* h = static_cast<Handle*>(p);
    if (!h) return 0;
    bool prev = h->stereo;
    h->stereo = false;
    int n = sidlove_sid_render(p, out, frames);
    h->stereo = prev;
    return n;
}

uint32_t sidlove_sid_time_ms(void *p) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) return 0;
    try { return (uint32_t)h->player->timeMs(); }
    catch (...) { return 0; }
}

void sidlove_sid_mute(void *p, int sid_num, int voice, int enable) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) return;
    try { h->player->mute((unsigned)sid_num, (unsigned)voice, enable != 0); }
    catch (...) {}
}

void sidlove_sid_filter(void *p, int sid_num, int enable) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) return;
    try { h->player->filter((unsigned)sid_num, enable != 0); }
    catch (...) {}
}

int sidlove_sid_get_status(void *p, int sid_num, sidlove_sid_status_t *out) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player || !out) return 1;
    try {
        uint8_t regs[32];
        std::memset(regs, 0, sizeof(regs));
        if (!h->player->getSidStatus((unsigned)sid_num, regs)) {
            h->set_err("no such SID");
            return 1;
        }
        std::memcpy(out->regs, regs, 32);
        return 0;
    } catch (const std::exception& e) {
        h->set_err(e.what()); return 1;
    } catch (...) { return 1; }
}

uint16_t sidlove_sid_get_cia_timer(void *p) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) return 0;
    try { return (uint16_t)h->player->getCia1TimerA(); }
    catch (...) { return 0; }
}

int sidlove_sid_installed_sids(void *p) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) return 0;
    try { return (int)h->player->installedSIDs(); }
    catch (...) { return 0; }
}

int sidlove_sid_tuneinfo(void *p, sidlove_sid_tuneinfo_t *out) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->tune || !out) { if (out) std::memset(out, 0, sizeof(*out)); return 1; }
    try {
        std::memset(out, 0, sizeof(*out));
        const SidTuneInfo* ti = h->tune->getInfo();
        if (!ti) { h->set_err("no tune info"); return 1; }
        out->songs        = ti->songs();
        out->start_song   = ti->startSong();
        out->current_song = ti->currentSong();
        out->load_addr    = ti->loadAddr();
        out->init_addr    = ti->initAddr();
        out->play_addr    = ti->playAddr();
        out->song_speed   = ti->songSpeed();
        out->clock_speed  = (int)ti->clockSpeed();
        out->sid_model    = (int)ti->sidModel(0);
        out->sid_chips    = ti->sidChips();
        out->compatibility = (int)ti->compatibility();
        // info strings: 0=title, 1=author, 2=released (HVSC convention)
        if (ti->numberOfInfoStrings() > 0 && ti->infoString(0))
            std::snprintf(out->title, sizeof(out->title), "%s", ti->infoString(0));
        if (ti->numberOfInfoStrings() > 1 && ti->infoString(1))
            std::snprintf(out->author, sizeof(out->author), "%s", ti->infoString(1));
        if (ti->numberOfInfoStrings() > 2 && ti->infoString(2))
            std::snprintf(out->released, sizeof(out->released), "%s", ti->infoString(2));
        if (ti->formatString())
            std::snprintf(out->format, sizeof(out->format), "%s", ti->formatString());
        return 0;
    } catch (const std::exception& e) {
        h->set_err(e.what()); return 1;
    } catch (...) { return 1; }
}

const char * sidlove_sid_error(void *p) {
    Handle* h = static_cast<Handle*>(p);
    if (!h) return "null handle";
    return h->err.c_str();
}

int sidlove_sid_reset(void *p) {
    Handle* h = static_cast<Handle*>(p);
    if (!h || !h->player) return 1;
    try { return h->player->reset() ? 0 : (h->set_err(h->player->error()), 1); }
    catch (const std::exception& e) { h->set_err(e.what()); return 1; }
    catch (...) { return 1; }
}

void sidlove_sid_destroy(void *p) {
    Handle* h = static_cast<Handle*>(p);
    if (!h) return;
    try {
        if (h->tune)   { delete h->tune;   h->tune = nullptr; }
        if (h->player) { delete h->player; h->player = nullptr; }
        if (h->builder){ delete h->builder; h->builder = nullptr; }
    } catch (...) {}
    delete h;
}

} // extern "C"
