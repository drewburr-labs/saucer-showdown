extends Node2D
## The game's sound: effects for what happens in a match, loops for tractor
## beams and the tractor, ticks and clicks for the menus, and the music. Like
## the view it only reads the sim (its events, and its state each tick) and
## never feeds back into it. The sounds are made by tools/make_sounds.gd.
##
## Effects play from where they happen, panned across the screen. The bots'
## match behind the menus plays quietly.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")

const DIR := "res://assets/sounds/"
const VOICES := 24
const QUIET_DB := -18.0 # the bots' match behind the menus
const MUSIC_DB := -4.0
const FADE := 1.2 # seconds to cross-fade between tracks
const REPEAT_MS := 45 # the same effect can't start more often than this
## How loud each sound plays, in dB (every file is normalised).
const GAIN := {
	"shot_saucer": -11.0, "shot_ray": -12.0, "hit": -5.0, "boom_big": -1.0, "boom_small": -7.0,
	"jump": -19.0, "land": -22.0, "moo1": -10.0, "moo2": -10.0, "pickup": -14.0,
	"beam_loop": -17.0, "tractor_loop": -15.0, "tractor_start": -11.0, "deposit": -7.0,
	"heist": -8.0, "powerup": -8.0, "speed": -10.0, "probe": -9.0, "claim": -8.0,
	"respawn_saucer": -12.0, "respawn_grey": -18.0, "ui_move": -16.0, "ui_click": -11.0,
	"go": -8.0, "win_map": -3.0, "win_match": -2.0,
}

var sim # Sim, or null
var quiet := false # the bots' match behind the menus
var ducked := false # the in-game menu is open

var _streams := {}
var _voices: Array[AudioStreamPlayer2D] = []
var _last := {} # sound -> msec it last started
var _silent := false
var _music: Array[AudioStreamPlayer] = []
var _music_vol := [0.0, 0.0]
var _cur := 0 # which of _music is the track playing now
var _track := ""
var _fanfare: AudioStreamPlayer
var _loops := {} # key -> {"name", "player", "vol"}
var _seen_sim = null
var _tick := -1
var _still := 0.0 # seconds since the sim last moved (paused, waiting, or a banner)
var _bolts := {}
var _units := {} # unit id -> what it was doing last tick
var _cows := {}
var _rider := false
var _moo_t := 6.0
var _ready_ms := 0
var _click_ms := -1000
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_ready_ms = Time.get_ticks_msec()
	for i in VOICES:
		_voices.append(_player2d())
	for i in 2:
		var m := AudioStreamPlayer.new()
		m.bus = "Music"
		add_child(m)
		_music.append(m)
	_fanfare = AudioStreamPlayer.new()
	_fanfare.bus = "Music"
	add_child(_fanfare)
	get_tree().node_added.connect(_on_node_added)
	get_viewport().gui_focus_changed.connect(_on_focus)


func _process(delta: float) -> void:
	_update_music(delta)
	if sim != _seen_sim:
		# A new map or a bot match: note what's there without sounding it.
		_seen_sim = sim
		_bolts.clear()
		_units.clear()
		_cows.clear()
		_rider = false
		if sim != null:
			_silent = true
			_watch()
			_silent = false
			_tick = sim.tick
	elif sim != null:
		if sim.tick != _tick:
			_tick = sim.tick
			_still = 0.0
			_watch()
			_ambient(delta)
		else:
			_still += delta
	_update_loops(delta)


## Plays effect `name` at `pos` (the middle of the screen if null). `ui`
## sounds aren't hushed with the bots' match.
func play(name: String, pos: Variant = null, db := 0.0, pitch := 1.0, ui := false) -> void:
	if _silent:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last.get(name, -1000)) < REPEAT_MS:
		return
	var s := _stream(name)
	if s == null:
		return
	_last[name] = now
	var v := _free_voice()
	v.stream = s
	v.position = pos if pos != null else Vector2(Cfg.W, Cfg.H) * 0.5
	v.volume_db = GAIN.get(name, 0.0) + db + (QUIET_DB if quiet and not ui else 0.0)
	v.pitch_scale = pitch * _rng.randf_range(0.96, 1.04)
	v.set_meta("t", now)
	v.play()


## The sim's events for a tick (the same ones the view gets).
func add_events(events: Array) -> void:
	for ev: Dictionary in events:
		var p: Vector2 = ev["pos"]
		match ev["type"]:
			"deposit":
				play("deposit", p, 0.0, 1.12 if ev["value"] > 1 else 1.0)
			"heist":
				play("heist", p)
			"warrior":
				play("powerup", p)
			"speed":
				play("speed", p)
			"probed":
				play("probe", p)
			"claim":
				play("claim", p)
			"hit":
				play("hit", p)
			"kill":
				play("boom_big" if ev["kind"] == E.Kind.OVERLORD else "boom_small", p)
			# "win" sounds once the win is confirmed; see win().


## The music to play: "menu", "battle", or "" for none.
func music(track: String) -> void:
	if track == _track:
		return
	_track = track
	_cur = 1 - _cur
	var m := _music[_cur]
	m.stop()
	m.stream = _stream("music_" + track) if track != "" else null
	_music_vol[_cur] = 0.0
	m.volume_db = -80.0
	if m.stream != null:
		m.play()


## A map is won (or the whole match).
func win(match_over: bool) -> void:
	var s := _stream("win_match" if match_over else "win_map")
	if s == null:
		return
	_fanfare.stream = s
	_fanfare.volume_db = GAIN["win_match" if match_over else "win_map"]
	_fanfare.play()


## A map is starting.
func go() -> void:
	play("go", null, 0.0, 1.0, true)


# --- Watching the sim ------------------------------------------------------

## Sounds for changes since the last tick that the sim doesn't report as
## events: shots, jumps, respawns, cows picked up, the tractor starting.
func _watch() -> void:
	var live := {}
	for b: E.Bolt in sim.bolts:
		live[b.id] = true
		if not _bolts.has(b.id):
			play("shot_saucer" if b.from_kind == E.Kind.OVERLORD else "shot_ray", b.pos)
	_bolts = live
	for u: E.Unit in sim.units:
		var was: Dictionary = _units.get(u.id, {})
		_units[u.id] = {"alive": u.alive, "ground": u.grounded, "vy": u.vel.y,
			"carry": u.carrying != null, "beam": u.beam_target != null}
		if was.is_empty() or not u.alive:
			continue
		if not was["alive"]:
			play("respawn_saucer" if u.kind == E.Kind.OVERLORD else "respawn_grey", u.pos)
		elif u.kind == E.Kind.GREY:
			if was["ground"] and not u.grounded and u.vel.y < -200.0 and u.held_by == null:
				play("jump", u.pos)
			elif u.grounded and not was["ground"] and was["vy"] > 450.0:
				play("land", u.pos)
			if u.carrying != null and not was["carry"]:
				play("pickup", u.pos)
				if _rng.randf() < 0.4:
					_moo(u.pos)
		elif u.beam_target != null and not was["beam"]:
			if u.beam_target is E.Cow:
				_moo(u.beam_target.pos)
			else:
				play("pickup", u.pos, 0.0, 0.7)
	var cows := {}
	for c: E.Cow in sim.cows:
		cows[c.id] = true
		if not _cows.has(c.id):
			_moo(c.pos, -5.0)
	_cows = cows
	var riding: bool = sim.tractor.rider != null
	if riding and not _rider:
		play("tractor_start", sim.tractor.pos)
	_rider = riding


## Now and then a loose cow moos.
func _ambient(delta: float) -> void:
	_moo_t -= delta
	if _moo_t > 0.0:
		return
	_moo_t = _rng.randf_range(7.0, 16.0)
	var loose: Array = sim.cows.filter(func(c: E.Cow) -> bool: return c.state == E.CowState.LOOSE)
	if not loose.is_empty():
		_moo(loose[_rng.randi() % loose.size()].pos, -4.0)


func _moo(pos: Vector2, db := 0.0) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_last.get("moo", -1000)) < 600:
		return
	if not _silent:
		_last["moo"] = now
	play("moo1" if _rng.randf() < 0.5 else "moo2", pos, db, _rng.randf_range(0.9, 1.1))


## Beams hum and the tractor chugs while they're in use and the sim is moving.
func _update_loops(delta: float) -> void:
	var want := {} # key -> [sound, position, pitch]
	if sim != null and _still < 0.2:
		for u: E.Unit in sim.units:
			if u.alive and u.kind == E.Kind.OVERLORD and u.in_beam:
				want["beam%d" % u.id] = ["beam_loop", u.pos + Vector2(0, 60), 0.85 if u.beam_target != null else 1.0]
		var tr: E.Tractor = sim.tractor
		if tr.rider != null:
			want["tractor"] = ["tractor_loop", tr.pos, 1.0 if tr.dir == 0.0 else 1.12]
	for key: String in want:
		if not _loops.has(key):
			var s := _stream(want[key][0])
			if s == null:
				continue
			var p := _player2d()
			p.stream = s
			p.volume_db = -80.0
			p.play()
			_loops[key] = {"name": want[key][0], "player": p, "vol": 0.0}
	for key: String in _loops.keys():
		var l: Dictionary = _loops[key]
		var p: AudioStreamPlayer2D = l["player"]
		var on := want.has(key)
		l["vol"] = move_toward(l["vol"], 1.0 if on else 0.0, delta * (8.0 if on else 5.0))
		if on:
			p.position = want[key][1]
			p.pitch_scale = want[key][2]
		elif l["vol"] <= 0.0:
			p.queue_free()
			_loops.erase(key)
			continue
		p.volume_db = GAIN[l["name"]] + linear_to_db(maxf(l["vol"], 0.0001)) + (QUIET_DB if quiet else 0.0)


# --- Music -----------------------------------------------------------------

func _update_music(delta: float) -> void:
	var level := 1.0
	if ducked:
		level = 0.4
	if _fanfare.playing:
		level = 0.15
	for i in 2:
		var target := level if i == _cur and _track != "" else 0.0
		_music_vol[i] = move_toward(_music_vol[i], target, delta / FADE)
		var m := _music[i]
		if not m.playing:
			continue
		if _music_vol[i] <= 0.0 and i != _cur:
			m.stop()
		m.volume_db = MUSIC_DB + linear_to_db(maxf(_music_vol[i], 0.0001))


# --- Menus -----------------------------------------------------------------

## Every button clicks and every slider ticks, wherever it is.
func _on_node_added(n: Node) -> void:
	if n is BaseButton:
		(n as BaseButton).pressed.connect(_ui_click)
	elif n is Slider:
		(n as Slider).value_changed.connect(_ui_tick.unbind(1))
	elif n is TabBar:
		(n as TabBar).tab_changed.connect(_ui_tick.unbind(1))


## Moving the focus with keys or a gamepad ticks; a mouse click doesn't, and
## nor does the focus a page sets as it opens.
func _on_focus(_c: Control) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Time.get_ticks_msec() - _click_ms < 200:
		return
	_ui_tick()


func _ui_click() -> void:
	_click_ms = Time.get_ticks_msec()
	if _click_ms - _ready_ms > 500:
		play("ui_click", null, 0.0, 1.0, true)


func _ui_tick() -> void:
	if Time.get_ticks_msec() - _ready_ms > 500:
		play("ui_move", null, 0.0, 1.0, true)


# --- Helpers ---------------------------------------------------------------

func _stream(name: String) -> AudioStream:
	if not _streams.has(name):
		var s: AudioStream = null
		for ext in [".wav", ".ogg"]:
			if ResourceLoader.exists(DIR + name + ext):
				s = load(DIR + name + ext)
				break
		_streams[name] = s
	return _streams[name]


func _player2d() -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.bus = "Effects"
	p.attenuation = 0.0 # no fall-off: the whole arena is on screen
	p.max_distance = 100000.0
	p.panning_strength = 1.2
	add_child(p)
	return p


## An idle voice, or else the one that started longest ago.
func _free_voice() -> AudioStreamPlayer2D:
	var best: AudioStreamPlayer2D = _voices[0]
	for v in _voices:
		if not v.playing:
			return v
		if int(v.get_meta("t", 0)) < int(best.get_meta("t", 0)):
			best = v
	return best


## Stop everything, so no playback outlives the players at exit.
func _exit_tree() -> void:
	for c in get_children():
		if c is AudioStreamPlayer or c is AudioStreamPlayer2D:
			c.stop()
			c.stream = null
