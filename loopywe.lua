--   loopywe v0.1.2 @sonoCircuit
--
--     a looper for my friend
--     
--           - domiwe -
--

local md = require 'core/mods'

--------- variables ----------
local NUM_TRACKS = 2 -- bump up to 6 for more tracks
local PPQN = 96
local FADE_TIME = 0.08
local BUFFER = math.pow(2, 24) / 48000
local MAX_LENGTH = math.floor(BUFFER / NUM_TRACKS) - 1 -- 1-6 voices: 348/173/115/86/68/57 sec

local beat_sec = 60 / params:get("clock_tempo")

local ui = {}
ui.k1 = false
ui.k2 = false
ui.k3 = false
ui.sec = false
ui.coin = false
ui.confirm = false
ui.lane_y = {33, 27, 25, 24, 23, 22}
ui.lane_space = {15, 11, 8, 6, 5, 4}
ui.head_size = {8, 8, 6, 4, 4, 4}
ui.param_focus = 1
ui.param_ids = {"level", "pan", "cutoff", "resonance", "rec", "dub", "tape_length", "frez_length", "frez_rate", "rate_slew", "frez_mode", "frez_quant"}
ui.param_names = {"level", "pan", "cutoff", "resonanz", "rec", "dub", "tape", "fz  size", "fz  rate", "rate  slew", "fz  mode", "fz  quant"}

local mtr = {}
mtr.tik = 0
mtr.count = 1
mtr.clock = nil
mtr.is_running = false

local trk = {}
trk.focus = 1
trk.rec_queued = false
trk.is_recording = false
trk.is_resetting = false
trk.is_clearing = false
trk.rate_options = {"-200%", "-150%", "-100%", "-75%", "-50%", "50%", "75%", "100%", "150%", "200%"}
trk.rate_values = {-2, -1.5, -1, -0.75, -0.5, 0.5, 0.75, 1, 1.5, 2}
trk.freeze_options  = {"1/16", "1/12", "3/32", "1/8", "1/6", "3/16", "1/4", "1/3", "3/8", "1/2", "2/3", "3/4", "4/4"}
trk.freeze_values = {1/16, 1/12, 3/32, 1/8, 1/6, 3/16, 1/4, 1/3, 3/8, 1/2, 2/3, 3/4, 1}
trk.quant_options = {"1/16", "1/12", "3/32", "1/8", "1/6", "3/16", "1/4"}
trk.quant_values = {1/16, 1/12, 3/32, 1/8, 1/6, 3/16, 1/4}

for i = 1, NUM_TRACKS do  
  trk[i] = {}
  trk[i].lvl = 1
  trk[i].pan = 0
  trk[i].rec = 1
  trk[i].dub = 1
  trk[i].fz_qnt = 6
  trk[i].fz_mode = 1 
  trk[i].fz_rate = 1 -- freeze rate
  trk[i].fz_pos = 1 -- freeze reset postion
  trk[i].fz_tik = 1 -- current step of ppqn resolution
  trk[i].fz_max = 1 -- freeue loop length
  trk[i].fz_queued = false
  trk[i].fz_active = false
  trk[i].is_playing = true
  trk[i].undo_enabled = false
  trk[i].beat_num = 8 -- track length in beats
  trk[i].pos = 0 -- buffer postion in seconds
  trk[i].step = 0 -- current step
  trk[i].step_max = trk[i].beat_num * PPQN -- number of steps
  trk[i].s = 1 * i + (i - 1) * MAX_LENGTH -- start pos in seconds
  trk[i].l = trk[i].beat_num * beat_sec -- length in seconds
  trk[i].e = trk[i].s + trk[i].l -- end pos in seconds
  trk[i].d = trk[i].l / trk[i].step_max -- step size in seconds
end

--------- functions ----------

local function set_level(i)
  if trk[i].is_playing then
    softcut.level(i, trk[i].lvl)
  else
    softcut.level(i, 0)
  end
end

local function toggle_levels(i)
  trk[i].is_playing = not trk[i].is_playing
  set_level(i)
end

local function backup_buffer(action)
  if action == "save" then
    local start = trk[trk.focus].s - FADE_TIME
    local length = trk[trk.focus].l + FADE_TIME * 2
    softcut.buffer_copy_mono(1, 2, start, start, length, FADE_TIME)
    trk[trk.focus].undo_enabled = true
  elseif action == "clear" then
    if trk[trk.focus].undo_enabled then
      local start = trk[trk.focus].s - FADE_TIME
      local length = trk[trk.focus].l + FADE_TIME * 2
      softcut.buffer_copy_mono(2, 1, start, start, length, FADE_TIME)
    else
      softcut.buffer_clear_region_channel(1, trk[trk.focus].s - FADE_TIME, MAX_LENGTH + FADE_TIME * 2)
    end
  end
end

local function set_rec()
  if trk.is_recording then
    softcut.rec_level(trk.focus, trk[trk.focus].rec)
    softcut.pre_level(trk.focus, trk[trk.focus].dub)
    ui.coin = true
    backup_buffer("save")
  else
    for i = 1, NUM_TRACKS do
      softcut.rec_level(i, 0)
      softcut.pre_level(i, 1)
    end
  end
end

local function toggle_rec()
  if trk.is_recording or trk[trk.focus].fz_active then
    trk.is_recording = false
    trk.rec_queued = false
    set_rec()
  else
    trk.rec_queued = not trk.rec_queued
  end
end

function set_length(i, num_beats)
  local length = num_beats * beat_sec
  if length > MAX_LENGTH then
    params:set("lw_tape_length_"..i, num_beats - 1)
  else
    trk[i].beat_num = num_beats
    trk[i].l = length
    trk[i].e = trk[i].s + trk[i].l
    softcut.loop_end(i, trk[i].e + FADE_TIME) -- adding fade improves startpoint reset.
    trk[i].step_max = num_beats * PPQN
    trk[i].d = trk[i].l / trk[i].step_max
    -- set phase quant
    local q = (trk[i].l / 120)
    local off = util.round((math.ceil(trk[i].s / q) * q) - trk[i].s, 0.001)
    softcut.phase_quant(i, q)
    softcut.phase_offset(i, off)
  end
end

local function reset_pos(i)
  if trk[i].fz_active == false then
    softcut.position(i, trk[i].s)
  end
  trk[i].step = 0
  if trk.focus == i then
    if trk.rec_queued then
      trk.is_recording = true
      trk.rec_queued = false
    elseif trk.is_recording then
      trk.is_recording = false
    end
    set_rec()
  end
end

local function reset_tracks()
  trk.is_resetting = true
  clock.run(function()
    clock.sync(4)
    for i = 1, NUM_TRACKS do
      reset_pos(i)
    end
    trk.is_resetting = false
  end)
end

local function set_cutoff(i, val)
  if val < -0.1 then -- lp
    local val = -val
    freq = util.linexp(0.1, 1, 12000, 80, val)
    softcut.post_filter_fc(i, freq)
    softcut.post_filter_lp(i, 1)
    softcut.post_filter_hp(i, 0)
  elseif val > 0.1 then -- hp
    freq = util.linexp(0.1, 1, 20, 8000, val)
    softcut.post_filter_fc(i, freq)
    softcut.post_filter_hp(i, 1)
    softcut.post_filter_lp(i, 0)
  else
    softcut.post_filter_fc(i, val > 0 and 20 or 12000)
    softcut.post_filter_lp(i, val > 0 and 0 or 1)
    softcut.post_filter_hp(i, val > 0 and 1 or 0)
  end
end

local function set_filter_q(i, val) -- from ezra's softcut eq class (thank you!)
  local x = 1 - val
  local rq = 2.15821131e-01 + (x * 2.29231176e-09) + (x * x * 3.41072934)
  softcut.post_filter_rq(i, rq)
end

local function phase_poll(i, pos)
  trk[i].pos = math.floor(util.linlin(0, 1, 1, 120, (pos - trk[i].s) / trk[i].l))
end

local function set_freeze(i, z)
  if trk[i].fz_mode == 1 then
    trk[i].fz_queued = z == 1 and true or false
  else
    if z == 1 then
      trk[i].fz_queued = not trk[i].fz_queued
    end
  end
end


---- clock coroutines and callbacks ----
local function tempo_change_callback()
  beat_sec = 60 / params:get("clock_tempo")
  for i = 1, NUM_TRACKS do
    set_length(i, trk[i].beat_num)
  end
end

local function transport_start_callback()
  mtr.tik = 0
  mtr.count = 1
  mtr.is_running = true
  for i = 1, NUM_TRACKS do
    reset_pos(i)
    set_level(i)
  end
end

local function transport_stop_callback()
  mtr.is_running = false
  trk.is_recording = false
  trk.rec_queued = false
  for i = 1, NUM_TRACKS do
    softcut.level(i, 0)
    softcut.rec_level(i, 0)
    softcut.pre_level(i, 1)
    trk[i].fz_queued = false
  end
end

local function loopy_clock()
  while true do
    -- metronome
    if mtr.tik >= PPQN then
      mtr.count = util.wrap(mtr.count + 1, 1, 4)
      ui.coin = not ui.coin
      mtr.tik = 0
    end
    mtr.tik = mtr.tik + 1
    -- track stepper
    for i = 1, NUM_TRACKS do
      -- advance steps and reset pos
      if trk[i].step >= trk[i].step_max then
        reset_pos(i)
      end
      trk[i].step = trk[i].step + 1
      if trk[i].step % trk[i].fz_qnt == 0 then
        -- set freeze state
        if trk[i].fz_queued then
          if trk[i].fz_active == false then
            trk[i].fz_active = true
            trk[i].fz_pos = trk[i].s + trk[i].d * (trk[i].step - 1)
            trk[i].fz_tik = 0
            softcut.position(i, trk[i].fz_pos)
            softcut.rate(i, trk[i].fz_rate)
          end
        end
      end
      if trk[i].fz_active and not trk[i].fz_queued then
        trk[i].fz_active = false
        local fpos = trk[i].s + (trk[i].l / trk[i].step_max) * (trk[i].step - 1)
        softcut.position(i, fpos)
        softcut.rate(i, 1)
      end
      -- reset freeze pos
      if trk[i].fz_active then
        if trk[i].fz_tik >= trk[i].fz_max then
          softcut.position(i, trk[i].fz_pos)
          trk[i].fz_tik = 0
        end
        trk[i].fz_tik = trk[i].fz_tik + 1
      end
    end
    clock.sync(1/PPQN)
  end
end


--------- params ----------
local function round_form(param, quant, form)
  return(util.round(param, quant)..form)
end

local function pan_display(param)
  if param < -0.01 then
    return ("L < "..math.abs(util.round(param * 100, 1)))
  elseif param > 0.01 then
    return (math.abs(util.round(param * 100, 1)).." > R")
  else
    return "> <"
  end
end

local function cutoff_display(i, param)
  if param < -0.1 then
    local p = math.abs(util.round(util.linlin(-1, -0.1, -100, -1, param), 1))
    return "lp < " ..p
  elseif param > 0.1 then
    local p = math.abs(util.round(util.linlin(0.1, 1, 1, 100, param), 1))
    return p.." > hp"
  else
    return "|"
  end
end

local function init_params()
  params:add_separator("lw_params", "loopywee")
  for i = 1, NUM_TRACKS do
    params:add_group("lw_track_"..i, "track "..i, 18)

    params:add_separator("lw_levels"..i, "levels")
    
    params:add_control("lw_level_"..i, "level", controlspec.new(0, 1, 'lin', 0, 1, ""), function(param) return (round_form(param:get() * 100, 1, "%")) end)
    params:set_action("lw_level_"..i, function(x) trk[i].lvl = x set_level(i) end)

    params:add_control("lw_pan_"..i, "pan", controlspec.new(-1, 1, 'lin', 0, 0, ""), function(param) return pan_display(param:get()) end)
    params:set_action("lw_pan_"..i, function(x) trk[i].pan = x softcut.pan(i, x) end)

    params:add_control("lw_rec_"..i, "rec", controlspec.new(0, 1, 'lin', 0, 1, ""), function(param) return (round_form(param:get() * 100, 1, "%")) end)
    params:set_action("lw_rec_"..i, function(x) trk[i].rec = x set_rec() end)

    params:add_control("lw_dub_"..i, "dub", controlspec.new(0, 1, 'lin', 0, 1, ""), function(param) return (round_form(param:get() * 100, 1, "%")) end)
    params:set_action("lw_dub_"..i, function(x) trk[i].dub = x set_rec() end)

    params:add_separator("lw_filter"..i, "filter")

    params:add_control("lw_cutoff_"..i, "cutoff", controlspec.new(-1, 1, 'lin', 0, 0, ""), function(param) return cutoff_display(i, param:get()) end)
    params:set_action("lw_cutoff_"..i, function(x) set_cutoff(i, x) end)

    params:add_control("lw_resonance_"..i, "resonance", controlspec.new(0, 1, 'lin', 0, 0.2, ""), function(param) return (round_form(param:get() * 100, 1, "%")) end)
    params:set_action("lw_resonance_"..i, function(x) set_filter_q(i, x) end)

    params:add_separator("lw_tape_"..i, "tape")

    params:add_number("lw_tape_length_"..i, "tape length", 2, 128, (math.floor(math.pow(2, i + 1))), function(param) return param:get().."beats" end)
    params:set_action("lw_tape_length_"..i, function(x) set_length(i, x) end)

    params:add_option("lw_frez_mode_"..i, "freeze mode", {"mom", "tog"}, 1)
    params:set_action("lw_frez_mode_"..i, function(x) trk[i].fz_mode = x end)

    params:add_option("lw_frez_quant_"..i, "freeze quant", trk.quant_options, 7)
    params:set_action("lw_frez_quant_"..i, function(x) trk[i].fz_qnt = math.floor(trk.quant_values[x] * 4 * PPQN) end)

    params:add_option("lw_frez_length_"..i, "freeze size", trk.freeze_options, 7)
    params:set_action("lw_frez_length_"..i, function(x) trk[i].fz_max = math.floor(trk.freeze_values[x] * 4 * PPQN) end)

    params:add_option("lw_frez_rate_"..i, "freeze rate", trk.rate_options, 8)
    params:set_action("lw_frez_rate_"..i, function(x) trk[i].fz_rate = trk.rate_values[x] if trk[i].fz_active then softcut.rate(i, trk[i].fz_rate) end end)

    params:add_control("lw_rate_slew_"..i, "rate slew", controlspec.new(0, 1, 'lin', 0, 0, ""), function(param) return (round_form(param:get(), 0.01, "s")) end)
    params:set_action("lw_rate_slew_"..i, function(x) softcut.rate_slew_time(i, x) end)

    params:add_separator("lw_ctrl_"..i, "control")

    params:add_binary("lw_freeze_trig_"..i, "freeze", "momentary")
    params:set_action("lw_freeze_trig_"..i, function(z) set_freeze(i, z) end)

    params:add_binary("lw_mute_trig_"..i, "mute", "momentary")
    params:set_action("lw_mute_trig_"..i, function(z) if z == 1 then toggle_levels(i) end end)
  end

    -- fx separator
  if md.is_loaded("fx") then
    params:add_separator("fx_params", "fx")
  end

  params:bang()
end

--------- softcut ----------
local function init_softcut()
  audio.level_adc_cut(1)
  audio.level_eng_cut(1)
  for i = 1, NUM_TRACKS do
    softcut.enable(i, 1)
    softcut.buffer(i, 1)

    softcut.level_input_cut(1, i, 0.707)
    softcut.level_input_cut(2, i, 0.707)

    softcut.play(i, 1)
    softcut.rec(i, 1)
    
    softcut.level(i, 0)
    softcut.pan(i, 0)

    softcut.pre_level(i, 1)
    softcut.rec_level(i, 0)

    softcut.pre_filter_dry(i, 1)
    softcut.pre_filter_lp(i, 0)
    
    softcut.post_filter_dry(i, 0)
    softcut.post_filter_lp(i, 1)
    softcut.post_filter_fc(i, 12000)
    softcut.post_filter_rq(i, 2)

    softcut.fade_time(i, FADE_TIME)
    softcut.level_slew_time(i, 0.2)
    softcut.pan_slew_time(i, 0.2)
    softcut.rate_slew_time(i, 0)
    softcut.rate(i, 1)

    softcut.loop_start(i, trk[i].s)
    softcut.loop_end(i, trk[i].e)
    softcut.loop(i, 1)
    softcut.position(i, trk[i].s)
  end
  softcut.event_phase(phase_poll)
  softcut.poll_start_phase()
end

--------- init function ----------
function init()
  -- init stuff
  init_softcut()
  init_params()
  -- set callbacks
  clock.tempo_change_handler = tempo_change_callback
  clock.transport.start = transport_start_callback
  clock.transport.stop = transport_stop_callback
  -- run clocks
  clock.run(function()
    clock.sync(4)
    mtr.count = 1
    mtr.is_running = true
    clock.run(loopy_clock)
    for i = 1, NUM_TRACKS do
      reset_pos(i)
    end
  end)
  -- call redraw
  redraw()
end

--------- norns UI ----------
function key(n, z)
  if n == 1 then
    ui.k1 = z == 1 and true or false
    if z == 0 then ui.confirm = false end
  end
  if n == 2 then
    ui.k2 = z == 1 and true or false
    if ui.k1 then
      if ui.confirm then
        if z == 1 then ui.confirm = false end
      elseif ui.sec then
        if z == 1 then
          toggle_levels(trk.focus)
        end
      else
        if z == 1 then
          ui.confirm = true
        end
      end
    elseif z == 1 and not ui.k3 then
      toggle_rec()      
    end
  elseif n == 3 then
    ui.k3 = z == 1 and true or false
    if ui.k1 then
      if ui.confirm then
        trk.is_clearing = true
        backup_buffer("clear")
        clock.run(function()
          clock.sleep(0.8)
          trk.is_clearing = false
          trk[trk.focus].undo_enabled = false
        end)
        ui.confirm = false
      elseif ui.sec then
        for i = 1, NUM_TRACKS do
          set_freeze(i, z)
        end
      else
        if z == 1 then
          reset_tracks()
        end
      end
    else
      set_freeze(trk.focus, z)
    end
  end
end

function enc(n, d)
  if n == 1 then
    if ui.k1 then
      ui.sec = d > 0 and true or false
    else
      trk.focus = util.clamp(trk.focus + d, 1, NUM_TRACKS)
    end
  elseif n == 2 then
    ui.param_focus = util.clamp(ui.param_focus + d, 1, #ui.param_ids)
  elseif n == 3 then
    if ui.k1 then
      for i = 1, NUM_TRACKS do
        params:delta("lw_"..ui.param_ids[ui.param_focus].."_"..i, d)
      end
    else
      params:delta("lw_"..ui.param_ids[ui.param_focus].."_"..trk.focus, d)
    end
  end
end

function redraw()
  screen.clear()
  -- track focus
  screen.font_face(2)
  screen.font_size(7)
  screen.move(4, 12)
  screen.level(15)
  screen.text(trk.focus)
  -- metronome
  for i = 1, 4 do
    screen.level(mtr.is_running and (mtr.count == i and 15 or 4) or 1)
    screen.rect(110 + (i - 1) * 4, 6, 2, 6)
    screen.fill()
  end
  -- indicators
  if trk.is_recording then
    screen.level(ui.coin and 15 or 0)
    screen.rect(45, 4, 39, 12)
    screen.fill()
    screen.move(64, 12)
    screen.level(ui.coin and 0 or 15)
    screen.text_center("recording")
  elseif trk.rec_queued then
    screen.move(64, 12)
    screen.level(4)
    screen.text_center("rec   queued")
  elseif trk.is_resetting then
    screen.move(64, 12)
    screen.level(15)
    screen.text_center("resetting... "..(5 - mtr.count))
  elseif trk.is_clearing then
    screen.move(64, 12)
    screen.level(15)
    screen.text_center(trk[trk.focus].undo_enabled and "undone" or "cleared")
  else
    if ui.k1 then
      if ui.sec then
        screen.level(trk[trk.focus].is_playing and 10 or (ui.coin and 15 or 6))
        screen.move(46, 12)
        screen.text_center(trk[trk.focus].is_playing and "mute" or "unmute")
        screen.level(10)
        screen.move(82, 12)
        screen.text_center("freez*")
      else
        if ui.confirm then
          screen.level(ui.coin and 15 or 4)
          screen.move(40, 12)
          screen.text_center("no")
          screen.level(4)
          screen.move(64, 12)
          screen.text_center(trk[trk.focus].undo_enabled and "undo?" or "clear?")
          screen.level(ui.coin and 4 or 15)
          screen.move(88, 12)
          screen.text_center("yes")
        else
          screen.level(10)
          screen.move(46, 12)
          screen.text_center(trk[trk.focus].undo_enabled and "undo" or "clear")
          screen.level(10)
          screen.move(82, 12)
          screen.text_center("reset")
        end
      end
    elseif trk[trk.focus].fz_active then
      screen.level(ui.coin and 15 or 0)
      screen.rect(45, 4, 39, 12)
      screen.fill()
      screen.move(64, 12)
      screen.level(ui.coin and 0 or 15)
      screen.text_center("freeeeze")
    end
  end
  -- track lane
  for i = 1, NUM_TRACKS do
    screen.level(trk.focus == i and 2 or 1)
    screen.move(4, ui.lane_y[NUM_TRACKS] + (i - 1) * ui.lane_space[NUM_TRACKS])
    screen.line_width(2)
    screen.line_rel(120, 0)
    screen.stroke()
    if mtr.is_running then
      screen.level(trk[i].is_playing and 15 or 3)
      screen.move(4 + trk[i].pos, ui.lane_y[NUM_TRACKS] - (ui.head_size[NUM_TRACKS] / 2) + (i -1) * ui.lane_space[NUM_TRACKS])
      screen.line_width(1)
      screen.line_rel(0, ui.head_size[NUM_TRACKS])
      screen.stroke()
    end
  end
  -- params
  screen.level(4)
  if ui.param_focus > 1 then
    screen.move(44, 57)
    screen.text_center("<")
    screen.move(28, 57)
    screen.text_right(ui.param_names[ui.param_focus - 1])
  end
  if ui.param_focus < #ui.param_ids then
    screen.move(84, 57)
    screen.text_center(">")
    screen.move(100, 57)
    screen.text(ui.param_names[ui.param_focus + 1])
  end
  screen.level(8)
  screen.move(64, 52)
  screen.text_center(ui.param_names[ui.param_focus])
  screen.level(15)
  screen.move(64, 62)
  screen.text_center(params:string("lw_"..ui.param_ids[ui.param_focus].."_"..trk.focus))
  
  screen.update()
end

function refresh()
	redraw()
end

--------- cleanup ----------
function cleanup()
  
end
