-- main.lua - sidlove demo. Drop into a Love2D project as main.lua.
--
-- Run:    love . path/to/tune.sid
--   or:   love . path/to/tune.mid  (needs a soundfont; set SF env var)
--   or:   love . path/to/tune.nsf
--
-- What it shows off:
--   * Auto-detection of .sid / .prg / .mid / .nsf / .sap / .vgm / .spc ...
--   * QueueableSource streaming with a ring of SoundData buffers
--   * SID register snapshot -> on-screen "oscilloscope" raster bars
--   * Raster-style tick sync derived from the CIA timer
--   * Live voice muting, filter toggle, sub-song switching
--   * A 4-bit digi drum loop layered on top (Sample module)
--   * A live ADSR envelope sweeping the filter (Filter module)
--
-- Controls:
--   1/2/3      mute/unmute SID voice 1/2/3 (or NSF voices 0..7 with shift)
--   F          toggle SID filter
--   N / P      next / previous sub-song (SID/NSF)
--   D          toggle the digi drum loop
--   E          toggle the filter-sweep envelope
--   R          toggle raster sync callback
--   Space      pause / resume
--   Esc        quit

local sidlove = require("sidlove")

local streamer, player, raster, drum, filter, envbinding
local kind, info_str
local paused = false
local show_raster = true
local drum_on = false
local env_on = false
local voice_muted = {false, false, false, false}

local WAV_HEADER = 44  -- for the headless render path

function love.load(args)
  -- Find the music file path in args.
  local path
  for _, a in ipairs(args) do
    if not a:find("^%-") then path = a break end
  end
  -- Default: look for sidlove/assets/sample.sid bundled with the demo.
  if not path then
    local candidates = {
      "sidlove/assets/sample.sid",
      "assets/sample.sid",
      "sample.sid",
    }
    for _, c in ipairs(candidates) do
      local f = io.open(c, "rb")
      if f then f:close() path = c break end
    end
  end

  local ok, err = sidlove.init()
  if not ok then
    info_str = "sidlove.init failed: " .. tostring(err)
    return
  end

  if not path then
    info_str = "no tune given. Usage: love . <file.sid|mid|nsf|...>\n"
       .. "engines: sid=" .. tostring(sidlove.engines.sid)
       .. " chip=" .. tostring(sidlove.engines.chiptune)
       .. " midi=" .. tostring(sidlove.engines.midi)
    return
  end

  player, kind = sidlove.load(path, {
    sampleRate = 44100,
    -- For SID you can force a model: sid_model = sidlove.SID.MODEL_8580
    -- For MIDI you must supply a soundfont: soundfont = "GeneralUser.sf2"
    soundfont = os.getenv("SF") or "sidlove/assets/GeneralUser.sf2",
  })
  if not player then
    info_str = "load failed: " .. tostring(kind)
    return
  end

  -- Streamer pumps the player into Love2D audio.
  streamer = sidlove.Streamer{ player = player, bufferFrames = 2048, bufferCount = 4 }
  player:setLoop(true)
  player:play()

  -- Raster: snap the SID state at the play-rate for visuals.
  raster = sidlove.Raster{
    player = player,
    clock = (player.info and player.info().clock_speed == 2) and "ntsc" or "pal",
    on_tick = function(dt, frame) end,
  }

  -- 4-bit digi drum: a tiny loop of packed nibbles. This is what a C64
  -- digi-drum looks like in a tune - 256 samples of 4-bit data looped at
  -- ~6 kHz. We synthesize a decaying noise burst procedurally so the demo
  -- is self-contained.
  drum = require("sidlove.sample_player"){ sampleRate = 44100 }
  local nibbles = {}
  for i = 0, 255 do
    local decay = math.exp(-i / 80)
    local s = math.floor((math.random() * 2 - 1) * decay * 7 + 8)
    table.insert(nibbles, math.max(0, math.min(15, s)))
  end
  local packed = {}
  for i = 1, #nibbles, 2 do
    packed[#packed + 1] = string.char(bit.bor(bit.lshift(nibbles[i], 4),
                                              nibbles[i + 1] or 0))
  end
  drum:add(drum.Voice.new(table.concat(packed),
                          { rate = 6000, bits = 4, loop = true, vol = 0.4 }))

  -- Filter module: a slow ADSR that sweeps the SID 6581 filter curve (or
  -- for MIDI, the filter cutoff CC). Demonstrates live patching.
  filter = sidlove.Filter()

-- We export Envelope from filter.lua so the filter-sweep demo works.
local function make_filter_envelope()
  local F = require("sidlove.filter")
  local env = F.Envelope{ attack = 1.5, decay = 1.0, sustain = 4.0,
                          release = 2.0, peak = 1.0, sustain_level = 0.3 }
  local setter
  if player and player.kind == "sid" then
    setter = F.setter_sid_filter6581(player)
  elseif player and player.kind == "midi" then
    setter = F.setter_midi_cc(player, 0, F.CC_FILTER_CUTOFF)
  else
    setter = function() end
  end
  return env, setter
end

function love.update(dt)
  if not streamer then return end
  if not paused then
    streamer:update(dt)
    if drum_on then drum:tick(dt) end
    if raster and show_raster then raster:update(dt) end
    if filter then filter:tick(dt) end
  end
end

function love.draw()
  love.graphics.clear(0.05, 0.05, 0.08)
  if info_str and not player then
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(info_str, 20, 20)
    return
  end
  -- Top status line.
  love.graphics.setColor(0.7, 1.0, 0.7)
  local status = string.format("sidlove %s | kind=%s | engines sid/chip/midi=%s/%s/%s",
      sidlove.VERSION, tostring(kind),
      tostring(sidlove.engines.sid), tostring(sidlove.engines.chiptune),
      tostring(sidlove.engines.midi))
  love.graphics.print(status, 10, 10)

  -- Time + song info.
  local ti = player.info and player.info() or {}
  love.graphics.setColor(1, 1, 1)
  love.graphics.print(string.format("time=%d ms | %s - %s",
      player:tell() or 0, ti.title or "?", ti.author or "?"), 10, 30)

  -- SID register bars (raster scope).
  if raster and player.kind == "sid" then
    local st = raster:sid_status()
    if st then
      local y0 = 60
      for i = 0, 24 do
        local v = st[i + 1] or 0
        local h = v * 2
        love.graphics.setColor(0.2, 0.9, 0.4 + i * 0.02)
        love.graphics.rectangle("fill", 10 + i * 12, y0, 10, h)
      end
      love.graphics.setColor(0.5, 0.5, 0.5)
      love.graphics.print("SID registers $D400-$D418", 10, y0 + 270)
    end
  end

  -- Help.
  love.graphics.setColor(0.6, 0.6, 0.6)
  love.graphics.print("1/2/3 mute  F filter  N/P song  D drum  E env  R raster  Space pause  Esc quit",
                      10, love.graphics.getHeight() - 24)
end

function love.keypressed(k)
  if k == "escape" then love.event.quit()
  elseif k == "space" then paused = not paused
       if paused then streamer:stop() else streamer.source:play() end
  elseif k == "f" and player and player.kind == "sid" then
       player:filter(0, not voice_muted[4])  -- toggle filter on SID 0
       voice_muted[4] = not voice_muted[4]
  elseif (k == "1" or k == "2" or k == "3") and player and player.kind == "sid" then
       local v = tonumber(k)
       voice_muted[v] = not voice_muted[v]
       player:mute(0, v - 1, not voice_muted[v])
  elseif k == "n" and player and player.select_song then
       local ti = player.info and player.info() or {}
       local cur = (ti.current_song or 1) + 1
       if cur > (ti.songs or 1) then cur = 1 end
       player:select_song(cur)
  elseif k == "p" and player and player.select_song then
       local ti = player.info and player.info() or {}
       local cur = (ti.current_song or 1) - 1
       if cur < 1 then cur = ti.songs or 1 end
       player:select_song(cur)
  elseif k == "d" then
       drum_on = not drum_on
  elseif k == "e" then
       env_on = not env_on
       if env_on then
         local env, setter = make_filter_envelope()
         if env and setter then
           env:strike()
           filter:add(env, setter)
         end
       else
         filter:clear()
       end
  elseif k == "r" then
       show_raster = not show_raster
  end
end
