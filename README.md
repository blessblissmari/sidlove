# sidlove — SID / chiptune / MIDI music engine for LÖVE

A demoscene-quality music library for [LÖVE](https://love2d.org) 11.x that plays
**real C64 SID** music (the actual reSIDfp chip emulator), **NSF / GBS / SAP /
VGM / SPC / AY / HES / KSS** chiptunes (via libgme), and **standard MIDI files**
(via libfluidsynth + a SoundFont). Built to run the kind of music used in
[*A Mind Is Born*](https://linusakesson.net/scene/a-mind-is-born/)
([CSDb #155560](https://csdb.dk/release/?id=155560)).

It is **low-level** by design: each engine is a `Player` object with a
`fill_into(buf, n)` (desktop) or `fillFloats(tab, n)` (web) method; a `Streamer`
pumps it into LÖVE's `QueueableSource` with a ring of pre-allocated `SoundData`
buffers so the hot path allocates nothing. Demoscene helpers (`Raster`,
`Sample`, `Filter`) layer on top and are opt-in.

### ✨ What's new in v2.0 — love.js / web support

v1.0 could not run in love.js (the web build) because LuaJIT FFI does not work
in WASM. **v2.0 fixes this.** sidlove now ships a **pure-Lua SID emulation
path** — `bit.lua` + `m6502.lua` + `sidchip.lua` + `players/sid_pure_player.lua`
— that runs in vanilla Lua 5.1 with no FFI, so `.sid` / `.prg` files play in
the browser out of the box. The native reSIDfp path is kept as the
high-quality engine on desktop; the pure-Lua path is the portable fallback and
the automatic web default. There is also a standalone **`sidlove_web.js`** — a
self-contained JS 6502 + SID emulator with Web Audio output — for projects that
want SID audio to bypass love.js entirely. See
[§ love.js / web — supported](#lovejs-web--supported).

## Architecture

```
            ┌─────────────── your game (love.update) ───────────────┐
            │                                                          │
            │   sidlove.Streamer{ player = p }   sidlove.Raster{...}  │
            │        │  update(dt)                     │ update(dt)   │
            │        ▼                                 ▼              │
            │   QueueableSource  ◀── SoundData ring    CIA-timer-sync │
            │        ▲                                 tick callbacks │
            │        │                                 + SID reg snap │
            │   player:fill_into(int16, n)                            │
            │        │                                                │
   ┌────────┼────────┼────────────────────┐  ┌──────────────────────┐ │
   │  SID   │  Chiptune  │     MIDI       │  │  Sample (4-bit digi) │ │
   │ sid_player  chip_player   midi_player│  │  mixer overlays      │ │
   │   │           │              │       │  │  onto the buffer     │ │
   │   ▼           ▼              ▼       │  └──────────────────────┘ │
   │ sidlove_sid  libgme.so    libfluid-  │                           │
   │ .so (shim)   (C ABI)      synth.so   │                           │
   │   │ direct FFI             (C ABI)   │                           │
   │   ▼                                    │                           │
   │ libsidplayfp.so.6 (reSIDfp bundled)   │                           │
   └────────────────────────────────────────┘                           │
            └──────────────────────────────────────────────────────────┘
```

`sidlove_sid.so` is the **only** thing you compile. It is a 600-line C shim
that wraps libsidplayfp's C++ class API into a flat C ABI that LuaJIT FFI can
bind directly. libgme and libfluidsynth are already pure-C, so they bind
without a shim.

## File formats

| Engine    | Formats                                                        | Library          |
|-----------|----------------------------------------------------------------|------------------|
| `sid`     | `.sid` (PSID/RSID v1-v4), `.prg`, `.mus`                       | libsidplayfp 2.x |
| `chiptune`| `.nsf` `.nsfe` `.gbs` `.sap` `.vgm` `.vgz` `.spc` `.ay` `.hes` `.kss` `.gym` | libgme 0.6.x |
| `midi`    | `.mid` `.midi` (SMF 0/1/2) + live MIDI sequencing              | libfluidsynth 2.x |

`sidlove.load(path)` sniffs the header magic and picks the engine; you can
also construct a specific player directly via `sidlove.SID(...)`,
`sidlove.CHIP(...)`, `sidlove.MIDI(...)`.

## Quick start

1. Drop the `sidlove/` folder into your game next to `main.lua`.
2. Ship the native libraries (see **Ship list** below) into
   `sidlove/native/<tag>/`.
3. Use it:

```lua
local sidlove = require("sidlove")

function love.load()
  sidlove.init()                              -- detect OS/arch, load .so/.dll
  local player = sidlove.load("music/a_mind_is_born.sid", {
    sampleRate = 44100,
    -- sid_model = sidlove.SID.MODEL_8580,   -- force 8580 (clean filter)
    -- filter_6581_curve = 0.5,              -- reSIDfp filter curve
  })
  streamer = sidlove.Streamer{ player = player, bufferFrames = 2048 }
  player:setLoop(true)
  player:play()
end

function love.update(dt) streamer:update(dt) end
function love.quit()      if streamer then streamer:dispose() end end
```

For MIDI you must supply a SoundFont:

```lua
local player = sidlove.load("song.mid", { soundfont = "sf/GeneralUser.sf2" })
```

The demo `main.lua` at the repo root is a full-featured example: load any
tune from the command line, on-screen SID-register raster bars, voice
muting, filter toggle, sub-song switching, a 4-bit digi drum loop (press
`D` — it is mixed over the tune by the Streamer), and a live ADSR filter
sweep. Run it straight from a clone of this repo:

```
love .                        # plays the bundled sidlove/assets/test.psid
love . path/to/tune.sid
love . path/to/tune.mid       # set SF env var to your .sf2 path
love . path/to/tune.nsf
```

To use the demo in your own game instead, copy `main.lua` and the
`sidlove/` folder into your game folder.

## Testing

The suite runs headless — no LÖVE, no network — and must be green on both
interpreters before a change ships:

```
bash run_tests.sh             # picks luajit or lua5.1, whichever exists
luajit tests/run.lua          # native engines (bundled .so files load)
lua5.1  tests/run.lua         # pure-Lua path, what love.js runs
```

It covers the bit-op shim, the 6502 core (hand-assembled program), the SID
chip (envelope/mute/regs/waveforms), PSID parsing + rendering, format
sniffing, the public API, and the envelope/sample/streamer modules —
including regression tests for every bug this repo has ever had. `luajit`
exercises the native engine, `lua5.1` the pure engine; both must pass.

For a WAV-rendering smoke test of the native libraries on a new platform,
run `luajit smoke_test.lua` (see the header of that file).

## Ship list (what native binaries to bundle)

Put these in `sidlove/native/<tag>/` (one subdir per platform). All three
engines are optional — if you only ship the SID engine, `.mid` and `.nsf`
files will fail to load with a clear error but the SID engine still works.
**`<tag>`** is one of: `linux-x64`, `linux-x86`, `linux-arm64`, `linux-arm`,
`windows-x64`, `windows-x86`, `macos` (universal), `android-arm64`,
`android-arm`, `ios-arm64`.

### Linux x86_64 (already bundled in this repo as a reference)

| File                   | Size  | Source                                                                 |
|------------------------|-------|------------------------------------------------------------------------|
| `libgme.so.0`          | 330 KB| `apt install libgme0` or build [libgme](https://github.com/libgme/game-music-emu) |
| `libz.so.1`            | 125 KB| system (zlib)                                                          |
| `libsidplayfp.so.6`    | 480 KB| `apt install libsidplayfp6` (≥ 2.0) or [source](https://github.com/libsidplayfp/libsidplayfp) |
| `sidlove_sid.so`       |  29 KB| **you build** — see below                                              |
| `libfluidsynth.so.3`   | 860 KB| **you build minimal** — see below (the distro package pulls in pulse/jack/pipewire/SDL2 — don't ship that) |
| `libsndfile.so.1`      | 575 KB| system (libsndfile) — only needed by fluidsynth                       |

### Windows x64

| File                   | Source                                                                 |
|------------------------|------------------------------------------------------------------------|
| `libgme.dll`           | [libgme releases](https://github.com/libgme/game-music-emu/releases) or vcpkg `gme` |
| `libsidplayfp.dll`     | [libsidplayfp releases](https://sourceforge.net/projects/sidplay2/files/) or build from source |
| `sidlove_sid.dll`      | `make windows` in `sid_shim/` (needs mingw-w64)                        |
| `libfluidsynth.dll`    | build minimal (see below) or [fluidsynth releases](https://github.com/FluidSynth/fluidsynth/releases) (rename) |
| `libsndfile.dll`, `libglib-2.0-0.dll`, `libgobject-2.0-0.dll` | vcpkg `sndfile` `glib` — fluidsynth's only runtime deps in minimal build |

### macOS (universal arm64 + x86_64)

| File                   | Source                                                                 |
|------------------------|------------------------------------------------------------------------|
| `libgme.dylib`         | brew `libgme` or build from source                                     |
| `libsidplayfp.dylib`   | brew `libsidplayfp` or build from source                               |
| `sidlove_sid.dylib`    | `make macos` in `sid_shim/` (needs Xcode clang)                        |
| `libfluidsynth.dylib`  | `brew install fluidsynth` (or build minimal) — pulls glib/sndfile via brew |

### Android (arm64-v8a + armeabi-v7a)

| File                   | Source                                                                 |
|------------------------|------------------------------------------------------------------------|
| `libgme.so`            | build from source with NDK (`-DCMAKE_TOOLCHAIN_FILE=...android.toolchain.cmake`) |
| `libsidplayfp.so`      | build from source with NDK                                             |
| `sidlove_sid.so`       | `make android` in `sid_shim/` (needs Android NDK)                      |
| `libfluidsynth.so`     | build minimal with NDK                                                 |
| `libc++_shared.so`     | from the NDK                                                           |

LÖVE for Android loads native libs from the app's private data directory;
see `platform.lua` for the path resolution logic.

### love.js / web — supported (v2.0)

love.js compiles LÖVE + Lua to WASM via Emscripten. LuaJIT FFI does not work
there (no native code in WASM, and love.js runs vanilla Lua 5.1), so the
native `sidlove_sid.so` / libgme / libfluidsynth engines cannot load. sidlove
detects this automatically — `platform.init()` sets `platform.web = true` and
`os = "Web"` — and routes `.sid` / `.prg` files to the **pure-Lua SID engine**
(`sidlove.bit` + `sidlove.m6502` + `sidlove.sidchip` +
`sidlove.players.sid_pure_player`), which has no FFI dependency and runs in
vanilla Lua 5.1.

**What works on web:** SID playback (`.sid`, `.prg`), the `Streamer` (it falls
back to `SoundData:setSample` per sample instead of `ffi.copy`), the `Sample`
digi mixer (voices stored as Lua strings instead of C buffers), and all the
player controls (play/stop/seek/mute/loop).

**What does NOT work on web:** chiptune (libgme) and MIDI (libfluidsynth) —
these need native C. The `Raster` visualiser is desktop-only (it reads live
SID registers via the native shim); on web, read `player:sid_status()` for the
same 32-register snapshot as a Lua table and roll your own bars.

**Using it:** nothing changes in your code. The same call works on desktop and
web:

```lua
local sidlove = require("sidlove")
sidlove.init()                                   -- auto-detects web on love.js
local player = sidlove.load("music.sid")         -- routes to pure player on web
local s = sidlove.Streamer{ player = player }
function love.update(dt) s:update(dt) end
```

You can force the pure-Lua engine on desktop too (handy for testing or when
you want a dependency-free build):

```lua
local player = sidlove.load("music.sid", { force_pure = true })
```

**Performance:** the pure-Lua engine renders faster than realtime in both
LuaJIT (~0.01 s per 0.3 s of audio) and vanilla Lua 5.1 (~0.06 s per 0.3 s),
measured against `assets/test.psid`. love.js runs Lua-in-WASM (~5–10× slower
than native Lua), so at 44.1 kHz stereo you have comfortable headroom for a
game's background music; for very busy multi-voice tunes you can drop to
22050 Hz (`opts.sampleRate = 22050`).

**Standalone JS player (alternative):** for projects that want SID audio to
come out of a native JS emulator rather than the pure-Lua path, include
`sidlove_web.js` from the page that hosts love.js:

```html
<script src="sidlove_web.js"></script>
<script>
  const sid = new SidloveWeb();
  sid.loadUrl('music.sid').then(() => sid.play(0));
</script>
```

It runs its own 6502 + SID core and plays through its own `AudioContext`,
independent of love.js's audio system (the two mix at the browser level). Use
this when you want the CPU cost off the Lua/WASM thread, or to play SID music
on a page with no love.js at all.

**Fidelity note:** the pure-Lua and JS engines share the same model — full
legal-opcode 6502, three voices with ADSR + combined waveforms, and a linear
state-variable filter. They are not bit-exact with the 6581's non-linear
analog filter, and play() is called at the video frame rate (50/60 Hz) which
is correct for VBI tunes and fine for the great majority of CIA tunes, but
sample/digi-heavy tunes that rely on cycle-exact IRQ timing (e.g. some
players in HVSC) are approximated. For bit-exact 6581/8580 sound, use the
native reSIDfp engine on desktop.

## Building the SID shim

The shim is one C++ file. From `sidlove/sid_shim/`:

```
make linux     # → sidlove_sid.so      (x86_64-linux)
make windows   # → sidlove_sid.dll     (x86_64-w64-mingw32, needs mingw-w64)
make macos     # → sidlove_sid.dylib   (universal arm64+x86_64, needs clang)
make android   # → sidlove_sid.so for arm64 + arm  (needs $ANDROID_NDK_HOME)
```

Override the sidplayfp header / lib locations with `SIDINC=` and `SIDLIB=`
if they aren't on the system path. The Linux `.so` shipped in
`native/linux-x64/` was built against libsidplayfp 2.16.1 and is compatible
with any 2.x (soname 6).

## Building a minimal libfluidsynth (recommended)

The distro `libfluidsynth` links against PulseAudio, JACK, PipeWire, ALSA,
SDL2, D-Bus, readline… none of which a LÖVE game needs (LÖVE itself is the
audio sink). Build a minimal one:

```bash
git clone https://github.com/FluidSynth/fluidsynth
cmake -S fluidsynth -B build \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -Denable-pulseaudio=OFF -Denable-jack=OFF -Denable-pipewire=OFF \
  -Denable-alsa=OFF -Denable-dbus=OFF -Denable-readline=OFF \
  -Denable-sdl2=OFF -Denable-ladspa=OFF -Denable-systemd=OFF \
  -Denable-oss=OFF -Denable-waveout=OFF -Denable-midishare=OFF \
  -Denable-coreaudio=OFF -Denable-coremidi=OFF -Denable-libinstpatch=OFF \
  -Denable-openmp=OFF -Denable-ipv6=OFF -Denable-network=OFF \
  -Denable-pkgconfig=ON
cmake --build build -j
```

The result depends on **only** `libsndfile`, `libstdc++`, `libm`, `libc` —
exactly the ship list above. Cross-compile for Windows / Android by pointing
CMake at the mingw / NDK toolchain file.

## API reference (low-level)

### `sidlove.init([native_root])` → `true | nil, err`
Detect OS/arch, load all three native libraries. Safe to call once at
startup. Returns true if at least one engine loaded.

### `sidlove.load(path, opts)` → `player, kind | nil, err`
Auto-detect format and construct the right player. `opts` is passed through
to the player constructor (see below).

### `sidlove.load_buffer(data, kind, opts)` → `player, kind | nil, err`
Load from a Lua string. `kind` is `"sid"`, `"chiptune"`, or `"midi"`.

### Players

Every player implements:

| Method                          | Purpose                                        |
|---------------------------------|------------------------------------------------|
| `:load_file(path)` / `:load_buffer(data, len)` | Load music        |
| `:play()` / `:stop()` / `:playing()` | Control playback                         |
| `:fill_into(int16buf, frames)`  | Hot path: render N frames into an int16 buffer |
| `:tell()` → ms / `:seek(ms)`    | Position                                      |
| `:setLoop(bool)`                | Infinite loop (default true)                  |
| `:dispose()`                    | Free native resources                         |

#### SID-specific (`sidlove.SID`)

| Method                              | Purpose                                  |
|-------------------------------------|------------------------------------------|
| `:select_song(n)`                   | Switch sub-song (1-based)                |
| `:info()`                           | `{songs, title, author, load_addr, ...}` |
| `:mute(sid, voice, enable)`         | voice 0-2 = oscillators, 3 = digi chan   |
| `:filter(sid, enable)`              | Toggle analog filter (live sweeps)       |
| `:sid_status(sid)`                  | 32-byte register snapshot (raster scope) |
| `:cia_timer()`                      | CIA1 Timer A value (play-rate heartbeat) |
| `:reset()`                          | Re-init without reloading                |

Constructor opts: `sid_model` (`MODEL_6581`/`MODEL_8580`/`MODEL_AUTO`),
`c64_model` (`C64_PAL`/`C64_NTSC`/...), `force_model`, `digi_boost`,
`filter_6581_curve` (0-1), `filter_8580_curve` (Hz), `combined_waveforms`
(`CW_AVERAGE`/`CW_WEAK`/`CW_STRONG`), `sampling`, `second_sid`, `third_sid`.

#### Chiptune-specific (`sidlove.CHIP`)

| Method                          | Purpose                                  |
|---------------------------------|------------------------------------------|
| `:track_count()` / `:start_track(i)` | Multi-track NSF/SAP                 |
| `:voice_count()` / `:voice_name(i)`  | For mute-by-voice UI                 |
| `:mute_voice(i, enable)` / `:mute_voices(mask)` | Voice isolation        |
| `:set_tempo(t)`                 | 0.5 = half, 2.0 = double                 |
| `:set_equalizer(treble, bass)`  | -50..+5 / 1..16000                       |
| `:enable_accuracy(bool)`        | Slower, cycle-accurate emulation         |

#### MIDI-specific (`sidlove.MIDI`)

File playback mode:

| Method                          | Purpose                                  |
|---------------------------------|------------------------------------------|
| `:load_soundfont(path)` → id    | Required before any sound               |
| `:add_midi(path)` / `:add_midi_buffer(data)` | Playlist             |
| `:set_tempo(type, value)`       | `TEMPO_INTERNAL`/`_EXTERNAL_BPM`/`_MIDI` |
| `:bpm()` / `:seek(ticks)`       | Position                                |

Live sequencing mode (tracker / demoscene):

| Method                          | Purpose                                  |
|---------------------------------|------------------------------------------|
| `:noteon(chan, key, vel)`       |                                          |
| `:noteoff(chan, key)`           |                                          |
| `:cc(chan, ctrl, val)`          | Continuous controllers (modwheel, etc.) |
| `:program_change(chan, prog)` / `:program_select(chan, bank, preset)` | Timbre |
| `:pitch_bend(chan, val)`        | 0-16383, 8192 = center                   |
| `:bank_select(chan, bank)`      |                                          |
| `:set_reverb(on, ...)` / `:set_chorus(on, ...)` | Built-in FX         |
| `:set_gain(g)` / `:cpu_load()`  |                                          |

### Demoscene helpers

#### `sidlove.Raster{ player=, clock="pal"/"ntsc", on_tick=fn }`
Restores C64-style music↔video lock-step. `update(dt)` distributes elapsed
time across play-ticks at the rate derived from the SID's CIA timer (or the
video clock), firing `on_tick(dt, frame)` each. `:sid_status()` and
`:sid_named()` return the cached register snapshot for visuals — draw 25
bars whose heights come from the SID registers, exactly like a C64
oscilloscope display.

#### `sidlove.Sample{ sampleRate= }` + `Sample.Voice.new(bytes, opts)`
4-bit / 8-bit digi sample playback, the C64 `$D418` digi-drum technique.
`bytes` is a Lua string of packed samples (`bits=4` packs two per byte,
high nibble first). `:tick(dt)` advances voices, `:mix_into(buf, n)` adds
them into an int16 buffer alongside the SID output. Use it to layer custom
drum loops over a SID tune.

#### `sidlove.Filter()` + `Filter.Envelope{ attack, decay, sustain, release, peak, sustain_level }`
Live ADSR envelopes bound to player parameters. `:add(env, setter)` attaches
an envelope; `:tick(dt)` advances all of them. Preset setters:
`setter_midi_cc(midi, chan, ctrl)`, `setter_midi_pitch(midi, chan)`,
`setter_midi_gen(midi, chan, gen, lo, hi)`, `setter_sid_filter6581(sid)`,
`setter_sid_gate(sid, sid_num, voice)`.

#### `sidlove.Streamer{ player=, bufferFrames=, bufferCount=, volume= }`
The bridge to LÖVE audio. `update(dt)` keeps the QueueableSource fed from a
ring of pre-allocated SoundData buffers (zero allocation on the hot path).
`stop()` / `dispose()` for clean teardown.

## The *A Mind Is Born* use case

The demo ships as a `.sid` (PSID, for SID players) and a `.prg` (raw C64
binary, for VICE / real hardware). With sidlove:

```lua
local player = sidlove.load("amib.sid", {
  sid_model = sidlove.SID.MODEL_6581,   -- the tune is 6581-authored
  c64_model = sidlove.SID.C64_PAL,
  filter_6581_curve = 0.5,              -- authentic filter curve
  combined_waveforms = sidlove.SID.CW_STRONG,  -- A Mind Is Born leans on
                                               -- combined waveforms heavily
})
```

The tune uses sophisticated sample playback (4-bit samples fetched from the
SID oscillator) and raster-synced visuals — both handled natively by
reSIDfp inside libsidplayfp, no special handling needed. To drive your own
raster-synced visuals in lock-step with the music, attach a `Raster` to the
player and read `:sid_status()` every tick.

For the `.prg`: libsidplayfp's `SidTune` loads `.prg` directly (it wraps it
as an RSID-style tune). `sidlove.load("amib.prg")` works.

## Performance notes

- **CPU cost** (measured on the reference Linux x64 build, 44.1 kHz stereo):
  - SID (reSIDfp, interpolation): ~3-5% of one core for a typical tune
  - Chiptune (libgme): ~1-3%
  - MIDI (fluidsynth minimal, 256-voice polyphony): ~2-4% + soundfont dependent
- The `Streamer` ring avoids per-frame `SoundData` allocation; the only
  allocation per frame is the `ffi.copy` memcpy (a few KB).
- For multi-SID tunes (two or three SID chips), the cost scales linearly.
- `sampling = SAMPLE_RESAMPLE` is ~20% slower than `SAMPLE_INTERPOLATE`
  but cleaner at high notes; use `INTERPOLATE` for games.
- Set `synth.polyphony` lower (64 or 128) if you ship a heavy soundfont.

## Limitations

- **love.js / web**: SID playback is supported via the pure-Lua engine (no
  FFI). Chiptune (libgme) and MIDI (libfluidsynth) are **not** available on
  web — they need native C. Use the standalone `sidlove_web.js` if you want a
  JS-native SID emulator independent of love.js. See
  [§ love.js / web — supported](#lovejs-web--supported).
- **Pure-Lua / JS SID fidelity**: the portable engines use a linear SVF
  filter, not the 6581's non-linear analog model, and call play() at the video
  frame rate. VBI tunes and most CIA tunes play correctly; cycle-exact
  sample/digi tunes are approximated. Use the native reSIDfp engine on desktop
  for bit-exact sound.
- **iOS**: technically works (the shim builds with `make ios-arm64`), but
  iOS app sandboxing makes loading arbitrary `.so` files from the app
  bundle require special packaging — link the engines statically instead.
- **Streaming from inside a zipped `.love`**: native `.so`/`.dll` cannot be
  loaded from inside a zip. Ship them next to the executable (the
  `platform.lua` resolver handles this). The pure-Lua SID path has no such
  constraint, which is why it's the right choice for fused love.js builds.
- **Sample rate**: all three engines resample to whatever LÖVE's audio
  device runs at (44.1 kHz default). For lowest latency match
  `love.audio.getSampleRate()`. On web, drop to 22050 if CPU is tight.

## Verification

The three C harnesses in `scripts/` (`verify_sid.c`, `verify_gme.c`,
`verify_fluid.c`) prove each native engine produces real audio. They were run
against the bundled Linux libraries and produced:

| Engine | Output               | Peak amplitude |
|--------|----------------------|----------------|
| SID    | `sidlove_out_sid.wav`  | 17.85% (audible triangle tone) |
| GBS    | `sidlove_out_gme.wav`  | 35.0%  (audible square tone)   |
| MIDI   | `sidlove_out_fluid.wav`| 11.43% (audible piano arpeggio)|

The test tunes (`assets/test.psid`, `assets/test.gbs`) are minimal
hand-assembled 6502 / SM83 programs (28 / 32 bytes of code), public domain.

### Pure-Lua SID engine (v2.0, web path)

`scripts/test_pure_player.py` renders `assets/test.psid` through
`sidlove.players.sid_pure_player` in **both** LuaJIT 2.1 (desktop) and vanilla
Lua 5.1 (the love.js runtime, via lupa), proving the no-FFI path works and
produces identical output across runtimes:

| Runtime         | 0.3 s render time | Peak | RMS  | Result |
|-----------------|-------------------|------|------|--------|
| LuaJIT 2.1      | 0.01 s            | 0.50 | 0.29 | non-silent ✓ |
| vanilla Lua 5.1 | 0.06 s            | 0.50 | 0.29 | non-silent ✓ |

Both faster than realtime. The matching peak/RMS confirms `sidlove.bit`
(arithmetic fallback) produces the same results as LuaJIT's native `bit`
library — i.e. the web build sounds the same as desktop when both use the
pure engine. `scripts/test_public_api.py` exercises the full
`sidlove.init()` → `sidlove.load()` → `player:render()` path in both runtimes
and confirms web auto-detection (`os = "Web"`, `web = true`) and `.sid` →
pure-player routing. `sidlove_web.js` is syntax-checked and smoke-tested in
Node (parses `test.psid`, renders non-silent audio, peak ≈ 0.50).

## License

The sidlove Lua code and the C shim source are MIT-licensed (see `LICENSE`).
The bundled native libraries retain their own licenses: libgme and
libsidplayfp are **GPL v2** (your game must be GPL-compatible if you ship
them, or talk to the maintainers about a commercial license), libfluidsynth
is **LGPL v2.1** (linkable from proprietary software). The demo soundfont
`VintageDreamsWaves-v2.sf2` has its own license — check before shipping.
