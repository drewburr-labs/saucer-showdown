extends SceneTree
## Synthesises every sound effect and music track in assets/sounds/. Nothing is
## recorded: each sound is a recipe of oscillators, noise, filters and echoes
## below, so to change one, edit its recipe and run this again.
##
##   godot --headless --path . --script tools/make_sounds.gd [-- name ...]
##
## With names, only those sounds are made. Effects are written as 16-bit mono
## WAV. Music and fanfares are stereo Ogg Vorbis, encoded with ffmpeg (which
## must be on PATH). Afterwards run `godot --headless --path . --import`.
## Every sound is normalised; scripts/audio/sound.gd sets how loud each plays.

const SR := 44100
const OUT := "res://assets/sounds/"
const TAIL := 3.0 # seconds of echo a music loop wraps back onto its start

enum W { SINE, TRI, SAW, SQUARE, NOISE }
enum F { LP, BP, HP }

const SOUNDS := [
	"shot_saucer", "shot_ray", "hit", "boom_big", "boom_small", "jump", "land",
	"moo1", "moo2", "pickup", "beam_loop", "tractor_loop", "tractor_start", "deposit",
	"heist", "powerup", "speed", "probe", "claim", "respawn_saucer", "respawn_grey",
	"ui_move", "ui_click", "go", "win_map", "win_match", "music_menu", "music_battle",
]

var _rng := RandomNumberGenerator.new()


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var want := OS.get_cmdline_user_args()
	for name: String in SOUNDS:
		if want.is_empty() or want.has(name):
			var t := Time.get_ticks_msec()
			_rng.seed = hash(name)
			call("_" + name)
			print("%-16s %5d ms" % [name, Time.get_ticks_msec() - t])
	quit()


# --- Effects ---------------------------------------------------------------

func _shot_saucer() -> void:
	var b := _buf(0.4)
	b = _tone(b, 0.0, 0.22, 1100.0, 170.0, W.SQUARE, 0.5, 0.002, 0.08, {"curve": 0.6, "pw": 0.35})
	b = _tone(b, 0.0, 0.22, 1650.0, 260.0, W.SAW, 0.25, 0.002, 0.06, {"curve": 0.6})
	b = _filt(b, F.LP, 6000.0, 1200.0, 0.9, 0.22)
	var n := _tone(_buf(0.4), 0.0, 0.05, 1.0, 1.0, W.NOISE, 0.4, 0.001, 0.015)
	b = _mix(b, _filt(n, F.HP, 2000.0))
	_wav("shot_saucer", _echo(b, 0.07, 0.3, 0.3))


func _shot_ray() -> void:
	var b := _buf(0.3)
	b = _tone(b, 0.0, 0.13, 2300.0, 520.0, W.TRI, 0.6, 0.001, 0.05, {"curve": 0.5})
	b = _tone(b, 0.0, 0.13, 1150.0, 260.0, W.SQUARE, 0.18, 0.001, 0.04, {"curve": 0.5, "pw": 0.25})
	b = _filt(b, F.LP, 7000.0)
	_wav("shot_ray", _echo(b, 0.05, 0.25, 0.25))


## A clang of inharmonic partials, a crack of noise and a low zap.
func _hit() -> void:
	var b := _buf(0.7)
	for p: Array in [[440.0, 0.5, 0.25], [1013.0, 0.35, 0.18], [1587.0, 0.3, 0.12], [2341.0, 0.2, 0.08], [3120.0, 0.15, 0.05]]:
		b = _tone(b, 0.0, 0.7, p[0], p[0], W.SINE, p[1], 0.001, p[2])
	var n := _tone(_buf(0.7), 0.0, 0.08, 1.0, 1.0, W.NOISE, 0.7, 0.001, 0.02)
	b = _mix(b, _filt(n, F.BP, 3000.0, -1.0, 0.8))
	var z := _tone(_buf(0.7), 0.0, 0.14, 600.0, 110.0, W.SQUARE, 0.3, 0.001, 0.05)
	b = _mix(b, _filt(z, F.LP, 2500.0))
	_wav("hit", b)


## A saucer going down: a noise blast closing into rumble, a falling thump and
## crackle.
func _boom_big() -> void:
	var b := _tone(_buf(2.0), 0.0, 2.0, 1.0, 1.0, W.NOISE, 1.0, 0.002, 0.45)
	b = _filt(b, F.LP, 4500.0, 140.0, 0.9, 1.3)
	b = _tone(b, 0.0, 0.9, 110.0, 30.0, W.SINE, 0.9, 0.002, 0.28, {"curve": 0.4})
	var c := _buf(2.0)
	for i in 45:
		var t := pow(_rng.randf(), 1.6) * 1.0
		c = _tone(c, t, 0.012, 1.0, 1.0, W.NOISE, _rng.randf_range(0.2, 0.6) * (1.0 - t), 0.0005, 0.004)
	b = _mix(b, _filt(c, F.BP, 2500.0, -1.0, 0.7))
	_wav("boom_big", _clip(b, 1.6))


## A grey zapped: a falling buzz and a pop.
func _boom_small() -> void:
	var b := _tone(_buf(0.6), 0.0, 0.26, 900.0, 90.0, W.SQUARE, 0.4, 0.001, 0.1, {"curve": 0.5})
	b = _filt(b, F.LP, 3000.0)
	var n := _tone(_buf(0.6), 0.0, 0.5, 1.0, 1.0, W.NOISE, 0.7, 0.001, 0.08)
	b = _mix(b, _filt(n, F.LP, 3000.0, 400.0, 0.7, 0.3))
	b = _tone(b, 0.02, 0.1, 420.0, 150.0, W.SINE, 0.5, 0.001, 0.04)
	_wav("boom_small", b)


func _jump() -> void:
	var b := _tone(_buf(0.2), 0.0, 0.15, 280.0, 640.0, W.SQUARE, 0.4, 0.002, 0.08, {"curve": 0.7, "pw": 0.25})
	_wav("jump", _filt(b, F.LP, 3500.0))


func _land() -> void:
	var b := _tone(_buf(0.15), 0.0, 0.15, 1.0, 1.0, W.NOISE, 0.6, 0.001, 0.03)
	b = _filt(b, F.LP, 600.0)
	b = _tone(b, 0.0, 0.1, 120.0, 60.0, W.SINE, 0.6, 0.001, 0.04)
	_wav("land", b)


func _moo1() -> void:
	_wav("moo1", _moo(1.3, 1.0, 1.0))


func _moo2() -> void:
	_wav("moo2", _moo(1.6, 0.85, 0.75))


## A moo: a growly, nasal voice that starts as a closed-mouth "mm", opens
## into a "waa" as it swells and rises, then sags and closes. `k` scales the
## pitch; `open` how wide the mouth gets.
func _moo(dur: float, k: float, open := 1.0) -> PackedFloat32Array:
	var pitch := [[0.0, 98.0 * k], [0.14, 142.0 * k], [0.5, 138.0 * k], [0.82, 116.0 * k], [1.0, 88.0 * k]]
	var o := {"pts": pitch, "vib": [5.0, 0.2], "vib_delay": 0.25, "rel": 0.15, "trem": [27.0, 0.3],
		"amp_pts": [[0.0, 0.0], [0.1, 0.35], [0.28, 1.0], [0.7, 0.85], [1.0, 0.0]]}
	var src := _tone(_buf(dur + 0.1), 0.0, dur, 1.0, 1.0, W.SAW, 0.7, 0.01, 0.0, o)
	# A quieter voice an octave down: the rough, chesty part of a moo.
	var sub := pitch.map(func(p: Array) -> Array: return [p[0], p[1] * 0.5])
	var o2 := o.duplicate()
	o2["pts"] = sub
	src = _tone(src, 0.0, dur, 1.0, 1.0, W.SAW, 0.18, 0.01, 0.0, o2)
	src = _filt(src, F.LP, 1600.0) # a voice, not a buzzer: the harmonics fall away
	var mouth := [[0.0, 300.0], [0.25, 300.0 + 380.0 * open], [0.7, 260.0 + 320.0 * open], [1.0, 320.0]]
	var f2 := [[0.0, 750.0], [0.25, 750.0 + 380.0 * open], [0.7, 700.0 + 300.0 * open], [1.0, 780.0]]
	var b := _filt(src.duplicate(), F.BP, 0.0, -1.0, 3.0, -1.0, mouth)
	b = _mix(b, _filt(src.duplicate(), F.BP, 0.0, -1.0, 4.0, -1.0, f2), 0.45)
	b = _mix(b, _filt(src, F.LP, 280.0), 0.6) # the "mm" through the nose
	b = _filt(_filt(b, F.LP, 2200.0), F.LP, 2200.0)
	var br := _tone(_buf(dur + 0.1), 0.0, dur, 1.0, 1.0, W.NOISE, 0.02, 0.2, 0.0, {"rel": 0.3})
	return _mix(b, _filt(br, F.BP, 900.0, -1.0, 1.0))


func _pickup() -> void:
	var b := _tone(_buf(0.3), 0.0, 0.06, 1047.0, 1047.0, W.SQUARE, 0.35, 0.001, 0.05)
	b = _tone(b, 0.055, 0.12, 1568.0, 1568.0, W.SQUARE, 0.35, 0.001, 0.05)
	_wav("pickup", _echo(_filt(b, F.LP, 6000.0), 0.06, 0.3, 0.3))


## A one-second hum that loops: whole numbers of cycles of every partial and
## of the tremolo, so the seam is clean.
func _beam_loop() -> void:
	var b := _buf(1.25)
	for p: Array in [[110.0, 0.35], [165.0, 0.18], [220.0, 0.2], [441.0, 0.06]]:
		b = _tone(b, 0.0, 1.25, p[0], p[0], W.SINE, p[1], 0.0001, 0.0, {"rel": 0.0, "trem": [8.0, 0.35]})
	b = _tone(b, 0.0, 1.25, 880.0, 880.0, W.SINE, 0.05, 0.0001, 0.0, {"rel": 0.0, "trem": [4.0, 0.8]})
	var n := _tone(_buf(1.25), 0.0, 1.25, 1.0, 1.0, W.NOISE, 0.25, 0.0001, 0.0, {"rel": 0.0})
	b = _mix(b, _filt(n, F.BP, 700.0, -1.0, 2.0))
	_wav("beam_loop", _loopify(b, 1.0))


## Putt-putt: fourteen chugs a second over a low drone, looped.
func _tractor_loop() -> void:
	var b := _buf(1.25)
	var putts := _buf(1.25)
	for k in 18:
		var t := k / 14.0 + _rng.randf_range(-0.003, 0.003)
		var a := 0.5 if k % 2 == 0 else 0.38
		putts = _tone(putts, maxf(t, 0.0), 0.06, 55.0, 48.0, W.SQUARE, a, 0.001, 0.022)
		putts = _tone(putts, maxf(t, 0.0), 0.04, 1.0, 1.0, W.NOISE, a * 0.5, 0.001, 0.012)
	b = _mix(b, _filt(putts, F.LP, 900.0))
	b = _tone(b, 0.0, 1.25, 42.0, 42.0, W.TRI, 0.15, 0.0001, 0.0, {"rel": 0.0})
	_wav("tractor_loop", _loopify(b, 1.0))


## The engine catching: a clunk, then chugs closing up.
func _tractor_start() -> void:
	var b := _tone(_buf(0.9), 0.0, 0.1, 1.0, 1.0, W.NOISE, 0.8, 0.001, 0.03)
	b = _filt(b, F.LP, 500.0)
	var putts := _buf(0.9)
	var t := 0.12
	var gap := 0.13
	while t < 0.85:
		putts = _tone(putts, t, 0.07, 60.0, 50.0, W.SQUARE, 0.5, 0.001, 0.025)
		putts = _tone(putts, t, 0.04, 1.0, 1.0, W.NOISE, 0.25, 0.001, 0.012)
		t += gap
		gap = maxf(0.065, gap * 0.85)
	_wav("tractor_start", _mix(b, _filt(putts, F.LP, 1000.0)))


## Cha-ching: two quick coin bleeps and a bell shimmer.
func _deposit() -> void:
	var b := _tone(_buf(0.8), 0.0, 0.075, 988.0, 988.0, W.SQUARE, 0.35, 0.001, 0.0)
	b = _tone(b, 0.07, 0.5, 1319.0, 1319.0, W.SQUARE, 0.35, 0.001, 0.15)
	b = _tone(b, 0.07, 0.6, 2637.0, 2637.0, W.SINE, 0.12, 0.001, 0.2)
	b = _tone(b, 0.07, 0.6, 3951.0, 3951.0, W.SINE, 0.06, 0.001, 0.12)
	_wav("deposit", _echo(_filt(b, F.LP, 7000.0), 0.09, 0.3, 0.25))


## A swipe of noise and a two-tone alarm.
func _heist() -> void:
	var n := _tone(_buf(0.75), 0.0, 0.35, 1.0, 1.0, W.NOISE, 0.6, 0.05, 0.12)
	var b := _filt(n, F.BP, 400.0, 3500.0, 1.5, 0.3)
	var a := _buf(0.75)
	for i in 3:
		var f := 880.0 if i % 2 == 0 else 660.0
		a = _tone(a, 0.1 + i * 0.12, 0.12, f, f, W.SQUARE, 0.25, 0.002, 0.0, {"rel": 0.01})
	_wav("heist", _mix(b, _filt(a, F.LP, 4000.0)))


## Becoming a warrior: a quick rising arpeggio.
func _powerup() -> void:
	var b := _buf(1.0)
	var notes := [72, 76, 79, 84, 88, 91]
	for i in notes.size():
		var f := _hz(notes[i])
		b = _tone(b, i * 0.055, 0.12 if i < notes.size() - 1 else 0.3, f, f, W.SQUARE, 0.3, 0.001, 0.06 if i < notes.size() - 1 else 0.12, {"pw": 0.25})
	_wav("powerup", _echo(_filt(b, F.LP, 6000.0), 0.11, 0.35, 0.35))


func _speed() -> void:
	var b := _tone(_buf(0.75), 0.0, 0.45, 220.0, 1760.0, W.SAW, 0.35, 0.005, 0.2, {"curve": 0.7, "vib": [18.0, 0.6]})
	var n := _tone(_buf(0.75), 0.0, 0.45, 1.0, 1.0, W.NOISE, 0.4, 0.02, 0.15)
	b = _mix(b, _filt(n, F.BP, 800.0, 5000.0, 1.2, 0.4))
	_wav("speed", _filt(b, F.LP, 6000.0))


## The probe: an alien warble.
func _probe() -> void:
	var b := _tone(_buf(0.9), 0.0, 0.7, 520.0, 900.0, W.SINE, 0.5, 0.02, 0.35, {"vib": [22.0, 4.0]})
	b = _tone(b, 0.0, 0.7, 260.0, 260.0, W.TRI, 0.25, 0.02, 0.3, {"vib": [11.0, 2.0]})
	_wav("probe", _echo(b, 0.12, 0.3, 0.3))


## A station claimed: two bells a fifth apart.
func _claim() -> void:
	var b := _buf(1.3)
	for n: Array in [[659.0, 0.0], [988.0, 0.09]]:
		for p: Array in [[1.0, 0.5, 0.5], [2.76, 0.2, 0.25], [5.4, 0.08, 0.1]]:
			var f: float = n[0] * p[0]
			b = _tone(b, n[1], 1.2, f, f, W.SINE, p[1], 0.001, p[2])
	_wav("claim", _echo(b, 0.15, 0.35, 0.3))


## A saucer warping back in.
func _respawn_saucer() -> void:
	var b := _tone(_buf(0.85), 0.0, 0.65, 180.0, 1400.0, W.SINE, 0.4, 0.1, 0.0, {"curve": 1.5, "trem": [16.0, 0.5], "rel": 0.15})
	b = _tone(b, 0.0, 0.65, 360.0, 2800.0, W.TRI, 0.12, 0.1, 0.0, {"curve": 1.5, "rel": 0.15})
	var n := _tone(_buf(0.85), 0.0, 0.7, 1.0, 1.0, W.NOISE, 0.15, 0.3, 0.2)
	b = _mix(b, _filt(n, F.HP, 6000.0))
	_wav("respawn_saucer", _echo(b, 0.08, 0.3, 0.3))


func _respawn_grey() -> void:
	var b := _tone(_buf(0.3), 0.0, 0.16, 400.0, 1200.0, W.TRI, 0.4, 0.002, 0.08)
	b = _tone(b, 0.12, 0.1, 1600.0, 1600.0, W.SINE, 0.3, 0.001, 0.04)
	_wav("respawn_grey", b)


func _ui_move() -> void:
	_wav("ui_move", _tone(_buf(0.06), 0.0, 0.05, 1700.0, 1700.0, W.SINE, 0.5, 0.001, 0.012))


func _ui_click() -> void:
	var b := _tone(_buf(0.14), 0.0, 0.045, 660.0, 660.0, W.SQUARE, 0.3, 0.001, 0.02)
	b = _tone(b, 0.035, 0.07, 990.0, 990.0, W.SQUARE, 0.3, 0.001, 0.025)
	_wav("ui_click", _filt(b, F.LP, 5000.0))


## A map starting: a swell into two chimes.
func _go() -> void:
	var n := _tone(_buf(1.7), 0.0, 1.0, 1.0, 1.0, W.NOISE, 0.4, 0.8, 0.0, {"rel": 0.15})
	var b := _filt(n, F.BP, 300.0, 4000.0, 1.5, 0.95)
	var s := _buf(1.7)
	for m: int in [57, 64, 69]:
		s = _tone(s, 0.0, 1.0, _hz(m), _hz(m), W.SAW, 0.12, 0.85, 0.0, {"rel": 0.12})
	b = _mix(b, _filt(s, F.LP, 400.0, 2500.0, 0.9, 0.95))
	for c: Array in [[81, 0.95], [88, 1.1]]:
		for p: Array in [[1.0, 0.4, 0.35], [2.76, 0.15, 0.15]]:
			var f: float = _hz(c[0]) * p[0]
			b = _tone(b, c[1], 0.6, f, f, W.SINE, p[1], 0.001, p[2])
	_wav("go", _echo(b, 0.13, 0.3, 0.25))


# --- Fanfares --------------------------------------------------------------

func _win_map() -> void:
	var span := 3.0
	var lead := _buf(span)
	var chord := _buf(span)
	var drums := _buf(span)
	var cym := _buf(span)
	for n: Array in [[67, 0.0, 0.13], [72, 0.13, 0.13], [76, 0.26, 0.13], [79, 0.39, 0.25], [76, 0.64, 0.13], [79, 0.77, 1.5]]:
		lead = _brass(lead, n[1], n[2], n[0], 0.5)
	for m: int in [60, 64, 67]:
		chord = _brass(chord, 0.77, 1.5, m, 0.3)
	for t: float in [0.0, 0.77]:
		drums = _tone(drums, t, 0.6, 100.0, 78.0, W.SINE, 0.8, 0.002, 0.2)
	cym = _tone(cym, 0.77, 2.0, 1.0, 1.0, W.NOISE, 0.4, 0.002, 0.6)
	cym = _filt(cym, F.HP, 5000.0)
	_ogg("win_map", _stereo(span, [[lead, 0.5, -0.1], [chord, 0.4, 0.15], [drums, 0.5, 0.0], [cym, 0.25, 0.0]], 0.35))


## The match: up the triad, then a flat-six, flat-seven, home cadence.
func _win_match() -> void:
	var span := 4.8
	var lead := _buf(span)
	var chord := _buf(span)
	var drums := _buf(span)
	var cym := _buf(span)
	var notes := [[67, 0.0, 0.12], [72, 0.12, 0.12], [76, 0.24, 0.12], [79, 0.36, 0.36], [76, 0.72, 0.12],
		[79, 0.84, 0.5], [80, 1.34, 0.36], [82, 1.7, 0.36], [84, 2.06, 2.0]]
	for n: Array in notes:
		lead = _brass(lead, n[1], n[2], n[0], 0.5)
	for c: Array in [[[60, 64, 67], 0.36, 0.98], [[56, 60, 63], 1.34, 0.36], [[58, 62, 65], 1.7, 0.36], [[60, 64, 67, 72], 2.06, 2.0]]:
		for m: int in c[0]:
			chord = _brass(chord, c[1], c[2], m, 0.25)
	for t: float in [0.0, 0.36, 1.34, 1.7, 2.06]:
		drums = _tone(drums, t, 0.7, 100.0, 76.0, W.SINE, 0.8, 0.002, 0.22)
	for t: float in [0.36, 2.06]:
		cym = _tone(cym, t, 2.5, 1.0, 1.0, W.NOISE, 0.4, 0.002, 0.7)
	cym = _filt(cym, F.HP, 5000.0)
	_ogg("win_match", _stereo(span, [[lead, 0.5, -0.1], [chord, 0.4, 0.15], [drums, 0.5, 0.0], [cym, 0.25, 0.0]], 0.35))


## Two detuned saws whose filter opens as the note speaks.
func _brass(s: PackedFloat32Array, t: float, dur: float, m: int, amp: float) -> PackedFloat32Array:
	var f := _hz(m)
	var n := _buf(dur + 0.05)
	for d: float in [-6.0, 6.0]:
		var g := f * pow(2.0, d / 1200.0)
		n = _tone(n, 0.0, dur, g, g, W.SAW, amp * 0.5, 0.03, 0.0, {"rel": minf(0.08, dur * 0.4),
			"vib": [5.5, 0.12], "vib_delay": 0.25, "phase": _rng.randf()})
	n = _filt(n, F.LP, 500.0, 3200.0, 0.8, 0.09)
	return _add_at(s, n, t)


# --- Music -----------------------------------------------------------------
# Each track loops: notes are written onto one loop length plus a tail, and
# the tail (echoes and reverb) is folded back onto the start.

## The menus: an unhurried night on the farm, with a theremin.
func _music_menu() -> void:
	var beat := 60.0 / 92.0
	var bars := 16
	var span := bars * 4 * beat
	var total := span + TAIL
	var pad := _buf(total)
	var bass := _buf(total)
	var arp := _buf(total)
	var lead := _buf(total)
	var kick := _buf(total)
	var shaker := _buf(total)
	var chords := [[57, 60, 64], [53, 57, 60, 64], [60, 64, 67], [55, 59, 62],
		[57, 60, 64], [53, 57, 60, 64], [50, 53, 57, 60], [52, 56, 59]]
	var arp_order := [0, 1, 2, 3, 1, 2, 3, 2]
	for bar in bars:
		var ch: Array = chords[bar % 8]
		var t0 := bar * 4 * beat
		for m: int in ch:
			pad = _pad(pad, t0, 4 * beat + 0.3, m, 0.07)
		var root: int = ch[0] - 12
		for n: Array in [[0.0, 1.5, root], [2.0, 1.0, root], [3.5, 0.5, root + 7]]:
			var f := _hz(n[2])
			bass = _tone(bass, t0 + n[0] * beat, n[1] * beat, f, f, W.SINE, 0.6, 0.01, 0.6, {"rel": 0.08})
			bass = _tone(bass, t0 + n[0] * beat, n[1] * beat, f * 2.0, f * 2.0, W.TRI, 0.12, 0.01, 0.3, {"rel": 0.08})
		var tones: Array = [ch[0] + 12, ch[1] + 12, ch[2] + 12, ch[0] + 24]
		for i in 8:
			var f := _hz(tones[arp_order[i]])
			arp = _tone(arp, t0 + i * 0.5 * beat, 0.4 * beat, f, f, W.SQUARE, 0.25, 0.003, 0.12, {"pw": 0.3})
		for i in 8:
			shaker = _tone(shaker, t0 + i * 0.5 * beat, 0.08, 1.0, 1.0, W.NOISE, 0.5 if i % 2 == 1 else 0.25, 0.01, 0.03)
		if bar >= 4:
			for k: Array in [[0.0, 0.8], [2.0, 0.55]]:
				kick = _kick(kick, t0 + k[0] * beat, k[1])
	var melody := [
		[4, 0, 2, 76], [4, 2, 1, 74], [4, 3, 1, 72],
		[5, 0, 3, 69], [5, 3, 1, 72],
		[6, 0, 2, 74], [6, 2, 1, 77], [6, 3, 1, 76],
		[7, 0, 2, 76], [7, 2, 2, 71],
		[8, 0, 1.5, 69], [8, 1.5, 0.5, 72], [8, 2, 2, 76],
		[9, 0, 2, 77], [9, 2, 1, 76], [9, 3, 1, 72],
		[10, 0, 2, 76], [10, 2, 2, 79],
		[11, 0, 3, 74], [11, 3, 1, 71],
		[12, 0, 2, 72], [12, 2, 1, 71], [12, 3, 1, 69],
		[13, 0, 2, 72], [13, 2, 2, 69],
		[14, 0, 1, 65], [14, 1, 1, 69], [14, 2, 2, 74],
		[15, 0, 3, 76],
	]
	var prev := 0.0
	for n: Array in melody:
		var t: float = (n[0] * 4 + n[1]) * beat
		var f := _hz(n[3])
		var from := prev if prev > 0.0 else f
		lead = _tone(lead, t, n[2] * beat + 0.05, from, f, W.SINE, 0.5, 0.06, 0.0,
			{"glide_t": 0.09, "vib": [5.5, 0.3], "vib_delay": 0.18, "rel": 0.15})
		lead = _tone(lead, t, n[2] * beat + 0.05, from * 2.0, f * 2.0, W.TRI, 0.06, 0.06, 0.0,
			{"glide_t": 0.09, "vib": [5.5, 0.3], "vib_delay": 0.18, "rel": 0.15})
		prev = f
	pad = _filt(pad, F.LP, 1300.0)
	arp = _filt(arp, F.LP, 2800.0)
	shaker = _filt(shaker, F.HP, 5000.0)
	var mixed := _stereo(total, [[pad, 0.5, 0.0], [bass, 0.55, 0.0], [lead, 0.45, 0.1],
		[kick, 0.45, 0.0], [shaker, 0.1, 0.3]], 0.3, [[arp, 0.25, 0.375 * beat * 2.0]])
	_ogg("music_menu", _fold(mixed, span))


## A match: driving bass, drums and a square-wave lead.
func _music_battle() -> void:
	var beat := 60.0 / 136.0
	var bars := 16
	var span := bars * 4 * beat
	var total := span + TAIL
	var pad := _buf(total)
	var bass := _buf(total)
	var arp := _buf(total)
	var lead := _buf(total)
	var drum := _buf(total)
	var snare := _buf(total)
	var hat := _buf(total)
	var EM := [52, 55, 59]
	var C := [48, 52, 55]
	var D := [50, 54, 57]
	var B := [47, 51, 54]
	var prog := [EM, EM, C, D, EM, EM, C, B, C, D, EM, EM, C, D, B, B]
	var bass_steps := [0, 0, 12, 0, 0, 12, 0, 7]
	for bar in bars:
		var ch: Array = prog[bar]
		var t0 := bar * 4 * beat
		for m: int in ch:
			pad = _pad(pad, t0, 4 * beat + 0.2, m, 0.05)
		var root: int = ch[0] - 12
		for i in 8:
			var f := _hz(root + bass_steps[i])
			bass = _tone(bass, t0 + i * 0.5 * beat, 0.45 * beat, f, f, W.SAW, 0.45, 0.003, 0.14, {"rel": 0.03})
			bass = _tone(bass, t0 + i * 0.5 * beat, 0.45 * beat, f * 0.5, f * 0.5, W.SINE, 0.5, 0.003, 0.2, {"rel": 0.03})
		var tones: Array = [ch[0] + 12, ch[1] + 12, ch[2] + 12, ch[0] + 24]
		var av := 0.28 if bar < 8 else 0.18
		for i in 16:
			var f := _hz(tones[i % 4])
			arp = _tone(arp, t0 + i * 0.25 * beat, 0.2 * beat, f, f, W.SQUARE, av, 0.002, 0.07, {"pw": 0.25})
		for b in 4:
			drum = _kick(drum, t0 + b * beat, 0.9)
			if b % 2 == 1:
				drum = _snare_body(drum, t0 + b * beat, 0.8)
				snare = _snare(snare, t0 + b * beat, 0.8)
		for i in 16:
			hat = _tone(hat, t0 + i * 0.25 * beat, 0.06, 1.0, 1.0, W.NOISE, 0.6 if i % 2 == 1 else 0.3, 0.001, 0.018)
		if bar == bars - 1:
			for i in 4:
				drum = _snare_body(drum, t0 + (3.0 + i * 0.25) * beat, 0.35 + i * 0.12)
				snare = _snare(snare, t0 + (3.0 + i * 0.25) * beat, 0.35 + i * 0.12)
	var melody := [
		[8, 0, 1, 79], [8, 1, 0.5, 76], [8, 1.5, 0.5, 79], [8, 2, 1, 81], [8, 3, 1, 79],
		[9, 0, 1, 78], [9, 1, 0.5, 74], [9, 1.5, 0.5, 78], [9, 2, 2, 81],
		[10, 0, 1.5, 83], [10, 1.5, 0.5, 81], [10, 2, 1, 79], [10, 3, 1, 78],
		[11, 0, 3, 76],
		[12, 0, 1, 79], [12, 1, 0.5, 76], [12, 1.5, 0.5, 79], [12, 2, 1, 84], [12, 3, 1, 83],
		[13, 0, 1, 81], [13, 1, 0.5, 78], [13, 1.5, 0.5, 81], [13, 2, 2, 86],
		[14, 0, 2, 83], [14, 2, 1, 81], [14, 3, 1, 78],
		[15, 0, 2, 78], [15, 2, 1, 75], [15, 3, 1, 71],
	]
	for n: Array in melody:
		var t: float = (n[0] * 4 + n[1]) * beat
		var f := _hz(n[3])
		var d: float = n[2] * beat * 0.95
		lead = _tone(lead, t, d, f, f, W.SQUARE, 0.3, 0.01, 0.0, {"pw": 0.5, "vib": [6.0, 0.2], "vib_delay": 0.2, "rel": 0.05})
		lead = _tone(lead, t, d, f * 1.003, f * 1.003, W.SAW, 0.2, 0.01, 0.0, {"vib": [6.0, 0.2], "vib_delay": 0.2, "rel": 0.05})
	pad = _filt(pad, F.LP, 1800.0)
	bass = _filt(bass, F.LP, 750.0, -1.0, 1.2)
	arp = _filt(arp, F.LP, 3200.0)
	lead = _filt(lead, F.LP, 2800.0)
	snare = _filt(snare, F.HP, 1200.0)
	hat = _filt(hat, F.HP, 7000.0)
	var mixed := _stereo(total, [[pad, 0.25, 0.0], [bass, 0.6, 0.0], [lead, 0.4, -0.1],
		[drum, 0.75, 0.0], [snare, 0.45, 0.05], [hat, 0.14, 0.35]], 0.18, [[arp, 0.22, 0.75 * beat]])
	_ogg("music_battle", _fold(mixed, span))


func _pad(s: PackedFloat32Array, t: float, dur: float, m: int, amp: float) -> PackedFloat32Array:
	var f := _hz(m)
	for d: float in [-8.0, 0.0, 8.0]:
		var g := f * pow(2.0, d / 1200.0)
		s = _tone(s, t, dur, g, g, W.SAW, amp, 0.35, 0.0, {"rel": 0.5, "phase": _rng.randf()})
	return s


func _kick(s: PackedFloat32Array, t: float, v: float) -> PackedFloat32Array:
	s = _tone(s, t, 0.4, 150.0, 42.0, W.SINE, v, 0.001, 0.14, {"curve": 0.3})
	return _tone(s, t, 0.006, 1.0, 1.0, W.NOISE, v * 0.3, 0.0005, 0.002)


## A snare's rattle, as noise to be filtered with the rest of its stem.
func _snare(s: PackedFloat32Array, t: float, v: float) -> PackedFloat32Array:
	return _tone(s, t, 0.25, 1.0, 1.0, W.NOISE, v, 0.001, 0.07)


## A snare's tonal body, which goes in with the kicks.
func _snare_body(s: PackedFloat32Array, t: float, v: float) -> PackedFloat32Array:
	return _tone(s, t, 0.12, 200.0, 170.0, W.TRI, v * 0.35, 0.001, 0.05)


# --- Building blocks -------------------------------------------------------

func _buf(sec: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(sec * SR))
	b.fill(0.0)
	return b


func _hz(m: int) -> float:
	return 440.0 * pow(2.0, (m - 69) / 12.0)


## Adds an oscillator to `b`: `f0` gliding to `f1` Hz over `dur` seconds from
## `t0`, shaped by a linear attack and an exponential decay (0 = sustain).
## Options: "curve" glide shape, "glide_t" glide over this long and then hold,
## "pts" [[fraction, hz], ...] pitch contour instead, "amp_pts" [[fraction,
## level], ...] loudness contour, "vib" [rate, semitones] and "vib_delay",
## "trem" [rate, depth], "pw" pulse width, "rel" fade at the end, "phase" start
## phase.
func _tone(b: PackedFloat32Array, t0: float, dur: float, f0: float, f1: float, w: int, amp: float,
		att := 0.005, dec := 0.0, o := {}) -> PackedFloat32Array:
	var i0 := int(t0 * SR)
	var n := mini(int(dur * SR), b.size() - i0)
	var vib: Array = o.get("vib", [0.0, 0.0])
	var vib_rate: float = vib[0]
	var vib_depth: float = vib[1]
	var vib_delay: float = o.get("vib_delay", 0.0)
	var trem: Array = o.get("trem", [0.0, 0.0])
	var trem_rate: float = trem[0]
	var trem_depth: float = trem[1]
	var pw: float = o.get("pw", 0.5)
	var curve: float = o.get("curve", 1.0)
	var glide_t: float = o.get("glide_t", dur)
	var rel: float = o.get("rel", minf(0.02, dur * 0.5))
	var pts: Array = o.get("pts", [])
	var amp_pts: Array = o.get("amp_pts", [])
	var ph: float = o.get("phase", 0.0)
	var glide := f1 != f0
	var ratio := f1 / f0
	var att_s := maxf(att, 1.0 / SR)
	for i in n:
		var t := float(i) / SR
		var f := f0
		if not pts.is_empty():
			f = _contour(pts, t / dur, true)
		elif glide:
			f = f0 * pow(ratio, pow(minf(t / glide_t, 1.0), curve))
		if vib_depth > 0.0 and t > vib_delay:
			f *= pow(2.0, vib_depth * sin(TAU * vib_rate * (t - vib_delay)) / 12.0)
		var dt := f / SR
		ph += dt
		ph -= floorf(ph)
		var s: float
		if w == W.SINE:
			s = sin(TAU * ph)
		elif w == W.TRI:
			s = 1.0 - 4.0 * absf(ph - 0.5)
		elif w == W.SAW:
			s = 2.0 * ph - 1.0 - _blep(ph, dt)
		elif w == W.SQUARE:
			s = (1.0 if ph < pw else -1.0) + _blep(ph, dt) - _blep(fposmod(ph - pw, 1.0), dt)
		else:
			s = _rng.randf_range(-1.0, 1.0)
		var env := 1.0 if t >= att_s else t / att_s
		if dec > 0.0 and t > att_s:
			env *= exp(-(t - att_s) / dec)
		if not amp_pts.is_empty():
			env *= _contour(amp_pts, t / dur, false)
		if trem_depth > 0.0:
			env *= 1.0 - trem_depth * (0.5 - 0.5 * cos(TAU * trem_rate * t))
		var left := dur - t
		if rel > 0.0 and left < rel:
			env *= left / rel
		b[i0 + i] += s * env * amp
	return b


## The value of a [[fraction, value], ...] contour at fraction `x`, eased
## exponentially between points (for pitches and cutoffs) or linearly.
func _contour(pts: Array, x: float, expo: bool) -> float:
	var k := 1
	while k < pts.size() - 1 and pts[k][0] < x:
		k += 1
	var a: Array = pts[k - 1]
	var c: Array = pts[k]
	var u := clampf((x - a[0]) / (c[0] - a[0]), 0.0, 1.0)
	return a[1] * pow(c[1] / a[1], u) if expo else lerpf(a[1], c[1], u)


## Smooths the corners of a saw or square so high notes don't alias.
func _blep(t: float, dt: float) -> float:
	if t < dt:
		t /= dt
		return t + t - t * t - 1.0
	if t > 1.0 - dt:
		t = (t - 1.0) / dt
		return t * t + t + t + 1.0
	return 0.0


## A state-variable filter over `b`; the cutoff sweeps from c0 to c1 Hz over
## `sweep` seconds (or the whole buffer) and then holds. Or it follows `pts`,
## a [[fraction, hz], ...] contour over the whole buffer.
func _filt(b: PackedFloat32Array, mode: int, c0: float, c1 := -1.0, q := 0.707, sweep := -1.0, pts := []) -> PackedFloat32Array:
	if c1 <= 0.0:
		c1 = c0
	var moving := c1 != c0 or not pts.is_empty()
	var n := b.size()
	var sn := float(n) if sweep <= 0.0 else sweep * SR
	var k := 1.0 / q
	var ic1 := 0.0
	var ic2 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var a3 := 0.0
	for i in n:
		if i == 0 or (moving and i % 16 == 0 and i <= sn + 16):
			var fc := c0 * pow(c1 / c0, minf(i / sn, 1.0)) if pts.is_empty() else _contour(pts, i / sn, true)
			fc = clampf(fc, 10.0, SR * 0.45)
			var g := tan(PI * fc / SR)
			a1 = 1.0 / (1.0 + g * (g + k))
			a2 = g * a1
			a3 = g * a2
		var v0 := b[i]
		var v3 := v0 - ic2
		var v1 := a1 * ic1 + a2 * v3
		var v2 := ic2 + a2 * ic1 + a3 * v3
		ic1 = 2.0 * v1 - ic1
		ic2 = 2.0 * v2 - ic2
		if mode == F.LP:
			b[i] = v2
		elif mode == F.BP:
			b[i] = v1
		else:
			b[i] = v0 - k * v1 - v2
	return b


func _mix(a: PackedFloat32Array, b: PackedFloat32Array, gain := 1.0) -> PackedFloat32Array:
	for i in mini(a.size(), b.size()):
		a[i] += b[i] * gain
	return a


func _add_at(s: PackedFloat32Array, n: PackedFloat32Array, t: float) -> PackedFloat32Array:
	var i0 := int(t * SR)
	for i in mini(n.size(), s.size() - i0):
		s[i0 + i] += n[i]
	return s


## Feedback echo mixed in at `mix`.
func _echo(b: PackedFloat32Array, time: float, fb: float, mix: float) -> PackedFloat32Array:
	var d := int(time * SR)
	var w := PackedFloat32Array()
	w.resize(b.size())
	w.fill(0.0)
	for i in range(d, b.size()):
		w[i] = b[i - d] + fb * w[i - d]
	return _mix(b, w, mix)


func _clip(b: PackedFloat32Array, drive: float) -> PackedFloat32Array:
	for i in b.size():
		b[i] = tanh(b[i] * drive)
	return b


## Crossfades the last part of `b` (past `sec`) into its start, so it loops.
func _loopify(b: PackedFloat32Array, sec: float) -> PackedFloat32Array:
	var n := int(sec * SR)
	var xf := b.size() - n
	for i in xf:
		var k := float(i) / xf
		b[i] = b[i] * k + b[n + i] * (1.0 - k)
	b.resize(n)
	return b


## Mixes mono stems [buffer, gain, pan] into [left, right], with a shared
## reverb at `wet` and stems [buffer, gain, delay] that ping-pong between sides.
func _stereo(sec: float, stems: Array, wet: float, pingpong := []) -> Array:
	var l := _buf(sec)
	var r := _buf(sec)
	var send := _buf(sec)
	for st: Array in stems:
		var b: PackedFloat32Array = st[0]
		var gl: float = st[1] * cos((st[2] + 1.0) * PI / 4.0) * sqrt(2.0)
		var gr: float = st[1] * sin((st[2] + 1.0) * PI / 4.0) * sqrt(2.0)
		for i in mini(b.size(), l.size()):
			l[i] += b[i] * gl
			r[i] += b[i] * gr
			send[i] += b[i] * st[1]
	for st: Array in pingpong:
		var b: PackedFloat32Array = st[0]
		var g: float = st[1]
		var d := int(st[2] * SR)
		var odd := _buf(sec)
		var even := _buf(sec)
		for i in mini(b.size(), l.size()):
			if i >= d:
				odd[i] = b[i - d] + 0.45 * even[i - d]
				even[i] = 0.45 * odd[i - d]
			l[i] += (b[i] + odd[i] * 0.6) * g
			r[i] += (b[i] + even[i] * 0.6) * g
			send[i] += b[i] * g
	var rv := _reverb(send)
	for i in l.size():
		l[i] += rv[0][i] * wet
		r[i] += rv[1][i] * wet
	return [l, r]


## A small Schroeder reverb: four damped combs, then two allpasses; the right
## side's delays are a little longer.
func _reverb(src: PackedFloat32Array) -> Array:
	var outs := []
	var n := src.size()
	for ch in 2:
		var o := PackedFloat32Array()
		o.resize(n)
		o.fill(0.0)
		for dl: int in [1116, 1277, 1422, 1617]:
			var line := PackedFloat32Array()
			line.resize(dl + ch * 23)
			line.fill(0.0)
			var size := line.size()
			var idx := 0
			var store := 0.0
			for i in n:
				var y := line[idx]
				store = y * 0.7 + store * 0.3
				line[idx] = src[i] * 0.06 + store * 0.84
				idx += 1
				if idx >= size:
					idx = 0
				o[i] += y
		for dl: int in [556, 341]:
			var line := PackedFloat32Array()
			line.resize(dl + ch * 23)
			line.fill(0.0)
			var size := line.size()
			var idx := 0
			for i in n:
				var y := line[idx]
				var x := o[i]
				o[i] = y - x
				line[idx] = x + y * 0.5
				idx += 1
				if idx >= size:
					idx = 0
		outs.append(o)
	return outs


## Folds everything past `sec` back onto the start, for a seamless loop.
func _fold(lr: Array, sec: float) -> Array:
	var n := int(sec * SR)
	for ch in 2:
		var b: PackedFloat32Array = lr[ch]
		for i in range(n, b.size()):
			b[i - n] += b[i]
		b.resize(n)
		lr[ch] = b
	return lr


func _norm(b: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var m := 0.0
	for x in b:
		m = maxf(m, absf(x))
	if m > 0.0:
		var g := peak / m
		for i in b.size():
			b[i] *= g
	return b


func _wav(name: String, b: PackedFloat32Array) -> void:
	_save(OUT + name + ".wav", [_norm(b, 0.9)])


## Writes a stereo pair through a temporary WAV into Ogg Vorbis.
func _ogg(name: String, lr: Array) -> void:
	var m := 0.0
	for ch in 2:
		for x in lr[ch]:
			m = maxf(m, absf(x))
	for ch in 2:
		var b: PackedFloat32Array = lr[ch]
		for i in b.size():
			b[i] = tanh(b[i] / m * 1.1) / tanh(1.1) * 0.9
		lr[ch] = b
	var wav := ProjectSettings.globalize_path("user://%s.wav" % name)
	_save(wav, lr)
	var out := []
	var code := OS.execute("ffmpeg", ["-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis", "-q:a", "5",
		ProjectSettings.globalize_path(OUT + name + ".ogg")], out, true)
	DirAccess.remove_absolute(wav)
	if code != 0:
		push_error("ffmpeg failed for %s: %s" % [name, "".join(out)])


func _save(path: String, chans: Array) -> void:
	var stereo := chans.size() == 2
	var l: PackedFloat32Array = chans[0]
	var r: PackedFloat32Array = chans[1] if stereo else l
	var step := 4 if stereo else 2
	var data := PackedByteArray()
	data.resize(l.size() * step)
	for i in l.size():
		data.encode_s16(i * step, int(clampf(l[i], -1.0, 1.0) * 32767.0))
		if stereo:
			data.encode_s16(i * step + 2, int(clampf(r[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = stereo
	w.data = data
	var err := w.save_to_wav(path)
	if err != OK:
		push_error("couldn't save %s: %s" % [path, error_string(err)])
