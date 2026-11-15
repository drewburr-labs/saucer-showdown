extends Node2D
## Draws the arena from the sim's state each frame: the SVG sprites in
## assets/sprites, animated here, plus particles and an additive glow pass.
## Nothing in this file feeds back into the simulation.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const Art = preload("res://scripts/view/art.gd")

const RS := Art.RS
const GOLD := Color("ffd84a")
const CYAN := Color("59d7ff")
const PROBE_GREEN := Color("b8ff4a")
const INK := Color("140f26")
const SKIN := Color("aab5c6")
const FX_LIFE := 1.1
const GREY_SCALE := 1.12 # drawn a touch larger than the hitbox so they read at a glance

var sim # Sim
var labels: Dictionary = {} # unit id -> "P1"

var _t := 0.0
var _fx: Array = [] # text pop-ups
var _parts: Array = [] # particles
var _stars: Array = []
var _clouds: Array = []
var _anim: Dictionary = {} # instance id -> per-thing animation state
var _seen_bolts: Dictionary = {}
var _shake := 0.0
var _shoot_t := 4.0
var _shooting: Dictionary = {}
var _font: Font
var _title: Font
var _dot: Texture2D # soft round light, for glows
var _glow: Node2D # additive layer, drawn over the world
var _vignette: Node2D
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_font = Art.body_font()
	_title = Art.title_font()
	_rng.seed = 51

	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.35, Color(1, 1, 1, 0.45))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 128
	gt.height = 128
	_dot = gt

	_glow = Node2D.new()
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = mat
	_glow.draw.connect(_draw_glow)
	add_child(_glow)

	_vignette = Node2D.new()
	_vignette.draw.connect(_draw_vignette)
	add_child(_vignette)

	for i in 140:
		_stars.append({
			"p": Vector2(_rng.randf_range(0.0, Cfg.W), _rng.randf_range(0.0, 470.0)),
			"s": _rng.randf_range(0.6, 2.0) if i % 7 != 0 else 2.6,
			"ph": _rng.randf_range(0.0, TAU),
			"sp": _rng.randf_range(1.0, 3.5),
		})
	for i in 5:
		_clouds.append({
			"x": _rng.randf_range(0.0, Cfg.W),
			"y": _rng.randf_range(90.0, 330.0),
			"w": _rng.randf_range(120.0, 220.0),
			"v": _rng.randf_range(4.0, 10.0),
		})
	# Rasterise everything up front so the first frames don't hitch.
	for n in ["backdrop", "barn", "ground", "plank", "station", "swirl", "cow", "tractor", "wheel"]:
		Art.tex(n)
	for team in 2:
		for n in ["saucer", "grey", "warrior", "raygun", "wreck", "silo"]:
			Art.tex(n, team)


func _process(delta: float) -> void:
	_t += delta
	for f in _fx:
		f["t"] += delta
	_fx = _fx.filter(func(f: Dictionary) -> bool: return f["t"] < FX_LIFE)
	_step_particles(delta)
	if sim != null:
		_spawn_ambient(delta)
		_track_bolts()
	for c in _clouds:
		c["x"] += c["v"] * delta
		if c["x"] - c["w"] > Cfg.W:
			c["x"] = -c["w"]
	_shoot_t -= delta
	if _shoot_t <= 0.0:
		_shoot_t = _rng.randf_range(6.0, 14.0)
		_shooting = {"p": Vector2(_rng.randf_range(200.0, 1100.0), _rng.randf_range(80.0, 220.0)), "t": 0.0}
	if not _shooting.is_empty():
		_shooting["t"] += delta
		if _shooting["t"] > 0.8:
			_shooting = {}
	if Engine.get_process_frames() % 600 == 0:
		_prune_anim()
	_shake = maxf(0.0, _shake - delta * 18.0)
	position = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * _shake
	queue_redraw()
	_glow.queue_redraw()


func add_events(events: Array) -> void:
	for ev: Dictionary in events:
		var team: int = ev.get("team", 0)
		var c: Color = Cfg.TEAM_COLORS[team]
		var p: Vector2 = ev["pos"]
		var text := ""
		match ev["type"]:
			"deposit":
				text = "+%d" % ev["value"]
				_burst(p, 22, GOLD, 60.0, 260.0, 0.9, true)
				_burst(p, 10, c.lightened(0.4), 30.0, 160.0, 0.7, true)
			"heist":
				text = "HEIST!"
				_burst(p, 18, Color("ff5a7a"), 80.0, 240.0, 0.6, true)
			"warrior":
				text = "WARRIOR"
				_burst(p, 30, GOLD, 80.0, 300.0, 0.8, true)
				_flash(p, 90.0, GOLD)
			"speed":
				text = "SPEED"
				_burst(p, 24, CYAN, 80.0, 300.0, 0.7, true)
				_flash(p, 80.0, CYAN)
			"probed":
				text = "PROBED x2"
				_burst(p, 20, PROBE_GREEN, 40.0, 200.0, 0.8, true)
			"claim":
				text = "CLAIMED"
				_flash(p, 110.0, c)
				_burst(p, 26, c.lightened(0.3), 60.0, 220.0, 0.8, true)
			"kill":
				if ev["kind"] == E.Kind.OVERLORD:
					_explode(p, c, true)
				else:
					_explode(p, c, false)
			"win":
				for k in 6:
					var q := Vector2(_rng.randf_range(160.0, Cfg.W - 160.0), _rng.randf_range(120.0, 360.0))
					_burst(q, 40, c.lightened(_rng.randf_range(0.0, 0.6)), 80.0, 340.0, 1.6, true)
		if text != "":
			_fx.append({"pos": p, "t": 0.0, "text": text, "color": c})


# --- Frame -----------------------------------------------------------------

func _draw() -> void:
	if sim == null:
		return
	_draw_backdrop()
	_draw_silos()
	_tex("barn", -1, sim.map.barn.position - Vector2(20, 0), Vector2.ZERO)
	_draw_ground()
	_draw_platforms()
	_draw_gates()
	for w: E.Wreck in sim.wrecks:
		_draw_wreck(w)
	_draw_tractor()
	for u: E.Unit in sim.units:
		if u.alive and u.kind == E.Kind.OVERLORD and u.in_beam:
			_draw_beam(u)
	for c: E.Cow in sim.cows:
		if c.state != E.CowState.CARRIED:
			_draw_cow(c)
	for u: E.Unit in sim.units:
		if not u.alive:
			continue
		if u.kind == E.Kind.OVERLORD:
			_draw_overlord(u)
		else:
			_draw_grey(u)
			if u.carrying != null:
				_draw_cow(u.carrying)
	_draw_particles(false)
	for b: E.Bolt in sim.bolts:
		var dir := b.vel.normalized()
		draw_line(b.pos - dir * 16.0, b.pos, Color(1, 1, 1, 0.95), 3.0, true)
	for u: E.Unit in sim.units:
		if u.alive and labels.has(u.id):
			_draw_label(u)
	for f in _fx:
		var k: float = f["t"] / FX_LIFE
		var col: Color = f["color"]
		var rise := 34.0 * (1.0 - pow(1.0 - k, 3.0))
		var a := 1.0 if k < 0.6 else 1.0 - (k - 0.6) / 0.4
		var size := int(22 + 8 * maxf(0.0, 1.0 - k * 5.0))
		var pos: Vector2 = f["pos"] + Vector2(-80.0, -26.0 - rise)
		draw_string_outline(_title, pos, f["text"], HORIZONTAL_ALIGNMENT_CENTER, 160.0, size, 6, Color(INK, a))
		draw_string(_title, pos, f["text"], HORIZONTAL_ALIGNMENT_CENTER, 160.0, size, Color(col.lightened(0.55), a))


## Everything that should light up, drawn additively over the world.
func _draw_glow() -> void:
	if sim == null:
		return
	var g := _glow
	var m = sim.map
	# Barn windows and lantern
	var b: Rect2 = m.barn
	var flick := 0.85 + 0.15 * sin(_t * 7.0) * sin(_t * 3.1)
	_light(g, b.position + Vector2(120, 81), 70.0, Color(1.0, 0.7, 0.3, 0.35 * flick))
	_light(g, b.position + Vector2(33, 95), 40.0, Color(1.0, 0.7, 0.3, 0.3 * flick))
	_light(g, b.position + Vector2(207, 95), 40.0, Color(1.0, 0.7, 0.3, 0.3 * flick))
	_light(g, b.position + Vector2(120, 104), 26.0, Color(1.0, 0.8, 0.4, 0.8 * flick))
	# Silo hatches and gauges
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var hx := 58.0 if team == 0 else Cfg.W - 58.0
		_light(g, Vector2(hx, 420), 60.0, Color(c, 0.22 + 0.1 * sin(_t * 3.0)))
		var fill := clampf(float(sim.silo[team]) / Cfg.SILO_GOAL, 0.0, 1.0)
		if fill > 0.0:
			var gx := 32.0 if team == 0 else Cfg.W - 32.0
			var top := 630.0 - 296.0 * fill
			_light_rect(g, Rect2(gx - 26, top, 52, 630 - top), Color(c, 0.18))
	# Crop circles
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var p := Vector2(m.crop_x[team], Cfg.GROUND_Y + 20.0)
		_light(g, p, 70.0, Color(c, 0.25 + 0.08 * sin(_t * 2.5 + team)), Vector2(1.6, 0.5))
		_light_rect(g, Rect2(p.x - 3, 360, 6, Cfg.GROUND_Y - 360), Color(c, 0.05 + 0.03 * sin(_t * 2.0)))
	# Stations
	for i in m.stations.size():
		var p: Vector2 = m.stations[i]
		var held_by: int = sim.station_owner[i]
		var c: Color = Color("c9d6ff") if held_by < 0 else Cfg.TEAM_COLORS[held_by]
		var a := 0.25 if held_by < 0 else 0.45 + 0.12 * sin(_t * 4.0)
		_light(g, p, 48.0, Color(c, a))
		var blink := 1.0 if fmod(_t + i * 0.4, 1.2) < 0.15 else 0.25
		_light(g, p + Vector2(0, -Cfg.GATE_RADIUS - 16), 12.0, Color(c, blink))
	# Wormholes
	for p: Vector2 in m.wormholes:
		_light(g, p, 56.0, Color(CYAN, 0.35 + 0.1 * sin(_t * 5.0)))
	# Wrecks
	for w: E.Wreck in sim.wrecks:
		var fl := 0.6 + 0.4 * sin(_t * 17.0 + w.pos.x) * sin(_t * 7.0)
		_light(g, w.pos + Vector2(6, -8), 30.0, Color(1.0, 0.45, 0.15, 0.35 * fl))
	# Tractor headlamp
	var tr: E.Tractor = sim.tractor
	var flip := _tractor_flip()
	var lamp := tr.pos + Vector2(36.0 * flip, -10.0)
	_light(g, lamp, 12.0, Color(1.0, 0.95, 0.7, 0.9))
	if tr.rider != null:
		_light(g, lamp + Vector2(40.0 * flip, 8.0), 50.0, Color(1.0, 0.9, 0.6, 0.18), Vector2(1.6, 0.6))
	# Units
	for u: E.Unit in sim.units:
		if not u.alive:
			continue
		var c: Color = Cfg.TEAM_COLORS[u.team]
		if u.kind == E.Kind.OVERLORD:
			var a: Dictionary = _anim.get(u.get_instance_id(), {})
			var rot: float = a.get("rot", 0.0)
			var bob: float = a.get("bob", 0.0)
			var p := u.pos + Vector2(0, bob)
			_light(g, p + Vector2(0, 14), 46.0, Color(c, 0.35), Vector2(1.3, 0.55))
			var sockets := [Vector2(-28, 5.5), Vector2(-14, 8), Vector2(0, 8.8), Vector2(14, 8), Vector2(28, 5.5)]
			for k in sockets.size():
				var on := int(_t * 8.0) % sockets.size() == k
				var q: Vector2 = p + (sockets[k] as Vector2).rotated(rot)
				var lc := GOLD if on else c.lightened(0.6)
				_light(g, q, 9.0 if on else 6.0, Color(lc, 0.95 if on else 0.6))
			if u.in_beam:
				_light(g, p + Vector2(0, 10), 30.0, Color(c.lightened(0.5), 0.6))
		else:
			if u.warrior and not u.grounded and u.in_jump and u.hover_fuel > 0.0:
				_light(g, u.pos + Vector2(0, 20), 26.0, Color(1.0, 0.6, 0.2, 0.7))
			if u.speedy:
				_light(g, u.pos + Vector2(0, 12), 18.0, Color(CYAN, 0.25))
	for cow: E.Cow in sim.cows:
		if cow.probed:
			_light(g, cow.pos, 34.0, Color(PROBE_GREEN, 0.35 + 0.12 * sin(_t * 8.0)))
	# Bolts
	for bolt: E.Bolt in sim.bolts:
		var c: Color = Cfg.TEAM_COLORS[bolt.team].lightened(0.3)
		var dir := bolt.vel.normalized()
		_light(g, bolt.pos, 16.0, Color(c, 0.9))
		_light(g, bolt.pos - dir * 10.0, 13.0, Color(c, 0.5))
		_light(g, bolt.pos - dir * 22.0, 9.0, Color(c, 0.25))
	_draw_particles(true)
	# Pop-up rings
	for f in _fx:
		var k: float = f["t"] / FX_LIFE
		var col: Color = f["color"]
		col.a = (1.0 - k) * 0.8
		g.draw_arc(f["pos"], 10.0 + 46.0 * k, 0.0, TAU, 32, col, 3.0 * (1.0 - k) + 0.5, true)


func _draw_vignette() -> void:
	var v := _vignette
	var steps := 10
	for i in steps:
		var k := float(i) / steps
		var a := 0.05 * (1.0 - k)
		var inset := 60.0 * k
		v.draw_rect(Rect2(-10, -10, Cfg.W + 20, inset + 10), Color(0, 0, 0.05, a))
		v.draw_rect(Rect2(-10, Cfg.H - inset, Cfg.W + 20, inset + 10), Color(0, 0, 0.05, a))
		v.draw_rect(Rect2(-10, -10, inset + 10, Cfg.H + 20), Color(0, 0, 0.05, a))
		v.draw_rect(Rect2(Cfg.W - inset, -10, inset + 10, Cfg.H + 20), Color(0, 0, 0.05, a))


# --- Scenery ---------------------------------------------------------------

func _draw_backdrop() -> void:
	var bd := Art.tex("backdrop")
	draw_set_transform(Vector2(-8, -8), 0.0, Vector2(1296.0, 736.0) / (bd.get_size()))
	draw_texture(bd, Vector2.ZERO)
	draw_set_transform(Vector2.ZERO)
	for s in _stars:
		var tw: float = 0.55 + 0.45 * sin(_t * s["sp"] + s["ph"])
		var sz: float = s["s"]
		var c := Color(1.0, 0.97, 0.9, 0.35 + 0.6 * tw)
		if sz > 2.4:
			draw_line(s["p"] - Vector2(4.0 * tw, 0), s["p"] + Vector2(4.0 * tw, 0), c, 1.0, true)
			draw_line(s["p"] - Vector2(0, 4.0 * tw), s["p"] + Vector2(0, 4.0 * tw), c, 1.0, true)
		draw_circle(s["p"], sz * 0.5 + 0.3 * tw, c, true, -1.0, true)
	if not _shooting.is_empty():
		var k: float = _shooting["t"] / 0.8
		var head: Vector2 = _shooting["p"] + Vector2(260, 90) * k
		var tail: Vector2 = head - Vector2(70, 24) * minf(1.0, k * 3.0)
		draw_line(tail, head, Color(1, 1, 1, 0.8 * (1.0 - k)), 2.0, true)
	for c in _clouds:
		var x: float = c["x"]
		var y: float = c["y"]
		var w: float = c["w"]
		for k in 5:
			var cx := x + (k - 2) * w * 0.2
			var r := w * (0.18 + 0.06 * float(2 - absi(k - 2)))
			draw_set_transform(Vector2(cx, y - r * 0.2), 0.0, Vector2(1.0, 0.45))
			draw_circle(Vector2.ZERO, r, Color(0.32, 0.27, 0.55, 0.18), true, -1.0, true)
			draw_set_transform(Vector2.ZERO)


func _draw_silos() -> void:
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var right := team == 1
		if right:
			_tex("silo", team, Vector2(Cfg.W + 8.0, 260.0), Vector2.ZERO, true)
		else:
			_tex("silo", team, Vector2(-8.0, 260.0), Vector2.ZERO)
		# Gauge: one segment per cow banked
		var gx := 20.0 if not right else Cfg.W - 44.0
		var top := 334.0
		var h := 296.0
		var seg := h / Cfg.SILO_GOAL
		var banked: int = sim.silo[team]
		for i in mini(banked, Cfg.SILO_GOAL):
			var y := top + h - seg * (i + 1)
			var col := c.lightened(0.15 * float(i % 2))
			draw_rect(Rect2(gx + 2, y + 1.5, 20, seg - 3), col)
			draw_rect(Rect2(gx + 3, y + 2, 5, seg - 4), Color(1, 1, 1, 0.25))
		for i in range(1, Cfg.SILO_GOAL):
			var y := top + h - seg * i
			draw_line(Vector2(gx + 2, y), Vector2(gx + 7, y), Color(1, 1, 1, 0.25), 1.0)
		if banked > 0 and banked < Cfg.SILO_GOAL:
			var y := top + h - seg * banked
			for k in 3:
				var by := y + fmod(_t * 22.0 + k * 9.0, seg * banked)
				draw_circle(Vector2(gx + 8 + k * 5, by), 1.4, Color(1, 1, 1, 0.5))
		# Deposit chevrons pointing into the hatch
		var zone: Rect2 = sim.map.silo_zone[team]
		var dir := -1.0 if not right else 1.0
		var hx := 82.0 if not right else Cfg.W - 82.0
		for k in 3:
			var ph := fmod(_t * 1.6 + k / 3.0, 1.0)
			var x := hx + dir * 22.0 * ph
			var a := sin(ph * PI) * 0.8
			var y := zone.get_center().y + 4.0
			draw_polyline(PackedVector2Array([Vector2(x - dir * 6, y - 9), Vector2(x, y), Vector2(x - dir * 6, y + 9)]), Color(c.lightened(0.4), a), 3.0, true)


func _draw_ground() -> void:
	var gt := Art.tex("ground")
	draw_set_transform(Vector2(0, Cfg.GROUND_Y - 8.0), 0.0, Vector2.ONE / RS)
	draw_texture_rect(gt, Rect2(-16 * RS, 0, (Cfg.W + 32) * RS, gt.get_height()), true)
	draw_set_transform(Vector2.ZERO)
	var m = sim.map
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var p := Vector2(m.crop_x[team], Cfg.GROUND_Y + 20.0)
		draw_set_transform(p, 0.0, Vector2(1.0, 0.32))
		draw_circle(Vector2.ZERO, 58.0, Color(0.05, 0.1, 0.06, 0.6), true, -1.0, true)
		draw_arc(Vector2.ZERO, 54.0, 0.0, TAU, 48, c, 4.0, true)
		draw_arc(Vector2.ZERO, 36.0, 0.0, TAU, 40, Color(c, 0.7), 3.0, true)
		draw_circle(Vector2.ZERO, 12.0, Color(c, 0.85), true, -1.0, true)
		for k in 6:
			var a := TAU * k / 6.0 + _t * 0.3
			draw_circle(Vector2.from_angle(a) * 45.0, 5.0, Color(c, 0.85), true, -1.0, true)
			draw_line(Vector2.from_angle(a) * 12.0, Vector2.from_angle(a) * 36.0, Color(c, 0.5), 2.0, true)
		draw_set_transform(Vector2.ZERO)
		# Beacon pole with a pennant
		var base := Vector2(p.x, Cfg.GROUND_Y)
		draw_line(base, base + Vector2(0, -44), Color("8b93b3"), 3.0, true)
		var wave := sin(_t * 4.0 + team) * 3.0
		var fd := 1.0 if team == 0 else -1.0
		draw_colored_polygon(PackedVector2Array([
			base + Vector2(0, -44), base + Vector2(fd * 22, -38 + wave), base + Vector2(0, -31)]), c)
		draw_circle(base + Vector2(0, -46), 3.0, Color.WHITE, true, -1.0, true)


func _draw_platforms() -> void:
	var pt := Art.tex("plank")
	var m = sim.map
	for i in range(1, m.platforms.size()):
		var p = m.platforms[i]
		var w: float = p.x1 - p.x0
		# Braces underneath
		var under := Color("2a1a14")
		for bx in [p.x0 + 12.0, p.x1 - 12.0]:
			var inward := 1.0 if bx < (p.x0 + p.x1) * 0.5 else -1.0
			draw_line(Vector2(bx, p.y + 12), Vector2(bx + inward * 14.0, p.y + 26), under, 4.0, true)
			draw_line(Vector2(bx, p.y + 12), Vector2(bx, p.y + 22), under, 4.0, true)
		draw_rect(Rect2(p.x0 + 2, p.y + 12, w - 4, 4), Color(0, 0, 0, 0.25))
		draw_set_transform(Vector2(p.x0, p.y - 2.0), 0.0, Vector2.ONE / RS)
		draw_texture_rect(pt, Rect2(0, 0, w * RS, pt.get_height()), true)
		draw_set_transform(Vector2.ZERO)
		draw_rect(Rect2(p.x0, p.y - 1.5, w, 15), INK, false, 2.0)
		# Little lanterns on the long decks
		if w >= 180.0 and i % 3 == 0:
			var lx: float = p.x0 + w * 0.5
			draw_line(Vector2(lx, p.y + 12), Vector2(lx, p.y + 20), under, 2.0)
			draw_circle(Vector2(lx, p.y + 23), 3.0, Color("ffcf6a"), true, -1.0, true)


func _draw_gates() -> void:
	var m = sim.map
	for i in m.stations.size():
		var p: Vector2 = m.stations[i]
		var held_by: int = sim.station_owner[i]
		var rim: Color = Color("c9d6ff") if held_by < 0 else Cfg.TEAM_COLORS[held_by]
		_tex("station", -1, p, Vector2(40, 36))
		var r := Cfg.GATE_RADIUS
		var pulse := 0.5 + 0.5 * sin(_t * 4.0)
		draw_circle(p, r - 3.0, Color(rim, 0.12 + 0.06 * pulse), true, -1.0, true)
		draw_arc(p, r, 0.0, TAU, 40, INK, 7.0, true)
		draw_arc(p, r, 0.0, TAU, 40, rim, 4.0, true)
		draw_arc(p, r - 6.0, _t * 1.5, _t * 1.5 + PI * 1.3, 24, Color(rim, 0.6), 2.0, true)
		# Probe glyph: a hovering chevron
		var hy := sin(_t * 3.0 + i) * 2.0
		draw_polyline(PackedVector2Array([p + Vector2(-8, 6 + hy), p + Vector2(0, -5 + hy), p + Vector2(8, 6 + hy)]), rim.lightened(0.3), 3.0, true)
		draw_circle(p + Vector2(0, -10 + hy), 2.0, rim.lightened(0.5), true, -1.0, true)
		# Antenna
		var top := p + Vector2(0, -r - 14)
		draw_line(p + Vector2(0, -r - 2), top, INK, 4.0, true)
		draw_line(p + Vector2(0, -r - 2), top, Color("b7bfd8"), 2.0, true)
		draw_circle(top, 3.5, rim, true, -1.0, true)
	for p: Vector2 in m.wormholes:
		var r := Cfg.GATE_RADIUS
		draw_circle(p, r + 3.0, INK, true, -1.0, true)
		draw_circle(p, r, Color("061224"), true, -1.0, true)
		_tex("swirl", -1, p, Vector2(32, 32), false, _t * 2.4, 0.78, Color(CYAN, 0.9))
		_tex("swirl", -1, p, Vector2(32, 32), false, -_t * 1.5 + 1.0, 0.5, Color(Color("b48cff"), 0.8))
		draw_circle(p, 4.0, Color.WHITE, true, -1.0, true)
		draw_arc(p, r + 1.0, 0.0, TAU, 40, Color(CYAN, 0.8), 2.5, true)


# --- Things ----------------------------------------------------------------

func _draw_wreck(w: E.Wreck) -> void:
	var team: int = w.owner.team if w.owner != null else 0
	var tilt := 0.12 if int(w.pos.x) % 2 == 0 else -0.12
	_tex("wreck", team, w.pos, Vector2(40, 24), tilt < 0.0, tilt)


func _tractor_flip() -> float:
	var tr: E.Tractor = sim.tractor
	var a: Dictionary = _anim.get_or_add(tr.get_instance_id(), {"face": -1.0, "x": tr.pos.x})
	if tr.dir != 0.0:
		a["face"] = signf(tr.dir)
	return a["face"]


func _draw_tractor() -> void:
	var tr: E.Tractor = sim.tractor
	var face := _tractor_flip()
	var p := tr.pos
	if tr.rider != null:
		p.y += sin(_t * 40.0) * 0.6
	var flip := face < 0.0
	_tex("tractor", -1, p, Vector2(44, 38), flip)
	var spin := tr.pos.x / 15.0
	_tex("wheel", -1, p + Vector2(-17.0 * face, 5.0), Vector2(16, 16), false, spin, 30.0 / 32.0)
	_tex("wheel", -1, p + Vector2(19.0 * face, 10.0), Vector2(16, 16), false, spin * 1.5, 20.0 / 32.0)
	if tr.rider != null:
		var c: Color = Cfg.TEAM_COLORS[tr.rider.team]
		for k in 3:
			var ph := fmod(_t * 1.5 + k / 3.0, 1.0)
			var x := p.x + face * (48.0 + 18.0 * ph)
			var a := sin(ph * PI)
			draw_polyline(PackedVector2Array([
				Vector2(x - face * 7.0, p.y - 34), Vector2(x, p.y - 26), Vector2(x - face * 7.0, p.y - 18)]),
				Color(c.lightened(0.3), a), 4.0, true)


func _draw_beam(u: E.Unit) -> void:
	var c := Cfg.TEAM_COLORS[u.team].lightened(0.5) as Color
	var a: Dictionary = _anim.get(u.get_instance_id(), {})
	var p := u.pos + Vector2(0, a.get("bob", 0.0) + 8.0)
	var bottom := minf(p.y + Cfg.BEAM_RANGE, Cfg.GROUND_Y)
	var hw := Cfg.BEAM_HALF_W
	draw_polygon(PackedVector2Array([
		p + Vector2(-9, 0), p + Vector2(9, 0),
		Vector2(p.x + hw, bottom), Vector2(p.x - hw, bottom)]),
		PackedColorArray([Color(c, 0.45), Color(c, 0.45), Color(c, 0.06), Color(c, 0.06)]))
	for k in 4:
		var ph := fmod(_t * 0.9 + k / 4.0, 1.0)
		var y := lerpf(bottom, p.y + 6.0, ph)
		var half := lerpf(hw, 9.0, ph)
		draw_set_transform(Vector2(p.x, y), 0.0, Vector2(1.0, 0.22))
		draw_arc(Vector2.ZERO, half, 0.0, TAU, 28, Color(c, 0.5 * sin(ph * PI)), 3.0, true)
		draw_set_transform(Vector2.ZERO)
	draw_set_transform(Vector2(p.x, bottom), 0.0, Vector2(1.0, 0.25))
	draw_circle(Vector2.ZERO, hw, Color(c, 0.2), true, -1.0, true)
	draw_set_transform(Vector2.ZERO)


func _draw_cow(c: E.Cow) -> void:
	var id := c.get_instance_id()
	var a: Dictionary = _anim.get_or_add(id, {"face": 1.0 if id % 2 == 0 else -1.0, "walk": 0.0})
	if absf(c.vel.x) > 2.0:
		a["face"] = signf(c.vel.x)
	var face: float = a["face"]
	var p := c.pos
	var rot := 0.0
	var dangle := false
	match c.state:
		E.CowState.CARRIED:
			rot = sin(_t * 6.0 + id) * 0.08
			dangle = true
			if c.holder != null:
				face = c.holder.facing
		E.CowState.BEAMED:
			rot = sin(_t * 2.6 + id) * 0.35
			dangle = true
		_:
			if not c.grounded:
				dangle = true
	if c.grounded and absf(c.vel.x) > 2.0:
		a["walk"] += absf(c.vel.x) * get_process_delta_time() * 0.35
	var walk: float = a["walk"]
	var leg_c := Color("e6e8f0")
	var xf := Transform2D(rot, p)
	for k in 4:
		var lx: float = [-10.0, -5.0, 6.0, 11.0][k] * face
		var swing := 0.0
		if dangle:
			swing = sin(_t * 9.0 + k * 1.7) * 2.5
		else:
			swing = sin(walk + (PI if k % 2 == 0 else 0.0)) * 2.5
		var hip := xf * Vector2(lx, 2.0)
		var hoof := xf * Vector2(lx + swing, 10.0 if not dangle else 11.0)
		draw_line(hip, hoof, INK, 6.0, true)
		draw_line(hip, hoof, leg_c, 3.4, true)
		draw_circle(hoof, 2.6, Color("3a2f40"), true, -1.0, true)
	var mod := Color.WHITE
	if c.probed:
		mod = Color(0.85, 1.0, 0.7)
	_tex("cow", -1, p, Vector2(22, 22), face < 0.0, rot, 1.0, mod)
	if c.probed:
		var ant := xf * Vector2(16.0 * face, -16.0)
		draw_line(xf * Vector2(14.0 * face, -9.0), ant, INK, 2.0, true)
		draw_circle(ant, 2.6, PROBE_GREEN, true, -1.0, true)


func _draw_grey(u: E.Unit) -> void:
	var id := u.get_instance_id()
	var a: Dictionary = _anim.get_or_add(id, {"walk": 0.0, "squash": 0.0, "was_grounded": true})
	var dt := get_process_delta_time()
	var on_ground := u.grounded or u.riding
	if on_ground and not a["was_grounded"]:
		a["squash"] = 1.0
		_dust(u.pos + Vector2(0, u.half.y), 5)
	a["was_grounded"] = on_ground
	a["squash"] = maxf(0.0, a["squash"] - dt * 6.0)
	var running := u.grounded and absf(u.vel.x) > 20.0
	if running:
		a["walk"] += absf(u.vel.x) * dt * 0.075
	var walk: float = a["walk"]
	var c: Color = Cfg.TEAM_COLORS[u.team]
	var face := u.facing
	var p := u.pos
	var sq: float = a["squash"]
	var scale := Vector2(1.0 + 0.2 * sq, 1.0 - 0.2 * sq)
	if not on_ground and u.held_by == null:
		var st := clampf(absf(u.vel.y) / 1400.0, 0.0, 0.12)
		scale = Vector2(1.0 - st * 0.6, 1.0 + st)
	scale *= GREY_SCALE
	var bob := -absf(sin(walk)) * 2.0 if running else 0.0
	var rot := 0.0
	if u.held_by != null:
		rot = sin(_t * 3.0 + id) * 0.3
	# Pivot at the feet so squash keeps them planted
	var feet := p + Vector2(0, u.half.y)
	var xf := Transform2D(rot, scale, 0.0, feet)
	var body := xf * Vector2(0, -u.half.y + bob)

	if u.shield_t > 0.0:
		var sa := 0.35 + 0.25 * sin(_t * 20.0)
		draw_circle(p, 22.0, Color(0.7, 0.9, 1.0, sa * 0.3), true, -1.0, true)
		draw_arc(p, 22.0, 0.0, TAU, 32, Color(1, 1, 1, sa + 0.2), 2.0, true)

	# Legs
	var pants := c.darkened(0.45)
	for k in 2:
		var side := -1.0 if k == 0 else 1.0
		var hip := xf * Vector2(side * 3.5, -7.0 + bob)
		var foot: Vector2
		if u.riding:
			foot = xf * Vector2(side * 3.5 + face * 5.0, -2.0)
		elif not u.grounded:
			foot = xf * Vector2(side * 4.0 - face * 2.0, -2.0)
		elif running:
			var s := sin(walk + (0.0 if k == 0 else PI))
			foot = xf * Vector2(side * 2.0 + s * 6.0 * face, -maxf(0.0, -cos(walk + (0.0 if k == 0 else PI))) * 4.0)
		else:
			foot = xf * Vector2(side * 4.0, 0.0)
		draw_line(hip, foot, INK, 6.0, true)
		draw_line(hip, foot, pants, 3.2, true)
		draw_circle(foot + Vector2(face * 1.0, -0.5), 2.8, INK, true, -1.0, true)

	# Back arm, body, front arm
	var shoulder := Vector2(0, -21.0 + bob)
	var arm_c := c.darkened(0.15)
	var hands := _hand_targets(u, walk, running)
	_arm(xf, shoulder + Vector2(-face * 5.0, 0), hands[0], arm_c)
	_tex("grey", u.team, body, Vector2(18, 24), face < 0.0, rot, 1.0, Color.WHITE, scale)
	if u.warrior:
		_tex("warrior", u.team, body, Vector2(18, 24), face < 0.0, rot, 1.0, Color.WHITE, scale)
	_arm(xf, shoulder + Vector2(face * 5.0, 0), hands[1], arm_c)
	if u.warrior:
		var gun := xf * (hands[1] as Vector2)
		_tex("raygun", u.team, gun, Vector2(5, 7), face < 0.0, rot, 0.9)

	if u.warrior and not u.grounded and u.in_jump and u.hover_fuel > 0.0:
		var fl := 8.0 + 4.0 * sin(_t * 40.0)
		draw_colored_polygon(PackedVector2Array([
			feet + Vector2(-5, -2), feet + Vector2(5, -2), feet + Vector2(0, fl)]), Color("ffb347"))
		draw_colored_polygon(PackedVector2Array([
			feet + Vector2(-2.5, -2), feet + Vector2(2.5, -2), feet + Vector2(0, fl * 0.6)]), Color("fff3b0"))
	if u.gate_t > 0.0:
		var k := u.gate_t / Cfg.GATE_DWELL
		draw_arc(p, 26.0, 0.0, TAU, 32, Color(0, 0, 0, 0.4), 5.0, true)
		draw_arc(p, 26.0, -PI / 2.0, -PI / 2.0 + TAU * k, 32, Color.WHITE, 3.5, true)


## Where the back and front hands go, in the grey's local space (feet at origin).
func _hand_targets(u: E.Unit, walk: float, running: bool) -> Array:
	var f := u.facing
	if u.carrying != null:
		return [Vector2(-f * 8.0, -33.0), Vector2(f * 8.0, -33.0)]
	if u.warrior:
		return [Vector2(-f * 7.0, -12.0), Vector2(f * 11.0, -17.0)]
	if u.held_by != null or not u.grounded:
		return [Vector2(-f * 11.0, -27.0), Vector2(f * 11.0, -27.0)]
	if running:
		var s := sin(walk)
		return [Vector2(-f * 5.0 - s * 5.0 * f, -12.0), Vector2(f * 5.0 + s * 5.0 * f, -12.0)]
	return [Vector2(-f * 7.0, -11.0), Vector2(f * 7.0, -11.0)]


func _arm(xf: Transform2D, from: Vector2, to: Vector2, col: Color) -> void:
	var a := xf * from
	var b := xf * to
	draw_line(a, b, INK, 5.5, true)
	draw_line(a, b, col, 2.8, true)
	draw_circle(b, 2.6, INK, true, -1.0, true)
	draw_circle(b, 1.7, SKIN, true, -1.0, true)


func _draw_overlord(u: E.Unit) -> void:
	var id := u.get_instance_id()
	var a: Dictionary = _anim.get_or_add(id, {"rot": 0.0, "bob": 0.0})
	var dt := get_process_delta_time()
	var target := clampf(u.vel.x / Cfg.OV_SPEED, -1.0, 1.0) * 0.2
	a["rot"] = lerpf(a["rot"], target, minf(1.0, dt * 8.0))
	a["bob"] = sin(_t * 2.4 + u.id) * 2.5
	var p := u.pos + Vector2(0, a["bob"])
	var rot: float = a["rot"]
	if u.shield_t > 0.0:
		var sa := 0.35 + 0.25 * sin(_t * 20.0)
		draw_circle(p, 36.0, Color(0.7, 0.9, 1.0, sa * 0.25), true, -1.0, true)
		draw_arc(p, 36.0, 0.0, TAU, 40, Color(1, 1, 1, sa + 0.2), 2.0, true)
	_tex("saucer", u.team, p, Vector2(44, 30), false, rot)
	# Blaster pod on the facing side
	var pod := p + Vector2(u.facing * 30.0, 6.0).rotated(rot)
	draw_line(pod - Vector2(u.facing * 6.0, 0).rotated(rot), pod + Vector2(u.facing * 6.0, 0).rotated(rot), INK, 6.0, true)
	draw_line(pod - Vector2(u.facing * 6.0, 0).rotated(rot), pod + Vector2(u.facing * 5.0, 0).rotated(rot), Color("b7bfd8"), 3.0, true)


func _draw_label(u: E.Unit) -> void:
	var c: Color = Cfg.TEAM_COLORS[u.team].lightened(0.45)
	var top := u.pos.y - u.half.y - (22.0 if u.kind == E.Kind.GREY else 18.0)
	if u.kind == E.Kind.GREY and u.carrying != null:
		top -= 22.0
	var s: String = labels[u.id]
	var pos := Vector2(u.pos.x - 30.0, top - 6.0)
	draw_string_outline(_title, pos, s, HORIZONTAL_ALIGNMENT_CENTER, 60.0, 16, 5, INK)
	draw_string(_title, pos, s, HORIZONTAL_ALIGNMENT_CENTER, 60.0, 16, c)
	var tip := Vector2(u.pos.x, top + 5.0)
	draw_colored_polygon(PackedVector2Array([tip + Vector2(-5, -5), tip + Vector2(5, -5), tip]), c)


# --- Particles -------------------------------------------------------------
# Each particle: p, v, life, max, size, color, add (glow layer), grav, grow

func _step_particles(dt: float) -> void:
	for q in _parts:
		q["life"] -= dt
		q["v"] += Vector2(0, q["grav"]) * dt
		q["v"] *= 1.0 - q.get("drag", 0.0) * dt
		q["p"] += q["v"] * dt
	_parts = _parts.filter(func(q: Dictionary) -> bool: return q["life"] > 0.0)


func _draw_particles(additive: bool) -> void:
	var ci: CanvasItem = _glow if additive else self
	for q in _parts:
		if q["add"] != additive:
			continue
		var k: float = 1.0 - q["life"] / q["max"]
		var col: Color = q["color"]
		var size: float = q["size"] * (1.0 + q.get("grow", 0.0) * k)
		if additive:
			_light(ci, q["p"], size * 2.5, Color(col, col.a * (1.0 - k)))
		else:
			ci.draw_circle(q["p"], size, Color(col, col.a * (1.0 - k)), true, -1.0, true)


func _part(p: Vector2, v: Vector2, life: float, size: float, color: Color, add: bool, grav := 0.0, grow := 0.0, drag := 0.0) -> void:
	if _parts.size() > 900:
		return
	_parts.append({"p": p, "v": v, "life": life, "max": life, "size": size, "color": color,
		"add": add, "grav": grav, "grow": grow, "drag": drag})


func _burst(p: Vector2, n: int, color: Color, smin: float, smax: float, life: float, add: bool) -> void:
	for i in n:
		var v := Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(smin, smax)
		_part(p, v, life * _rng.randf_range(0.6, 1.0), _rng.randf_range(1.5, 3.5), color, add, 300.0, 0.0, 2.0)


func _flash(p: Vector2, size: float, color: Color) -> void:
	_part(p, Vector2.ZERO, 0.35, size * 0.4, Color(color, 0.9), true)


func _dust(p: Vector2, n: int) -> void:
	for i in n:
		var v := Vector2(_rng.randf_range(-60.0, 60.0), _rng.randf_range(-30.0, -5.0))
		_part(p, v, 0.45, _rng.randf_range(2.0, 3.5), Color(0.75, 0.75, 0.85, 0.5), false, 0.0, 1.2, 3.0)


func _explode(p: Vector2, c: Color, big: bool) -> void:
	var n := 40 if big else 16
	_flash(p, 160.0 if big else 70.0, Color(1.0, 0.8, 0.5))
	for i in n:
		var v := Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(80.0, 380.0 if big else 220.0)
		_part(p, v, _rng.randf_range(0.4, 0.9), _rng.randf_range(2.0, 4.0), Color(1.0, _rng.randf_range(0.5, 0.9), 0.3), true, 500.0, 0.0, 1.5)
	for i in (14 if big else 6):
		var v := Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(60.0, 260.0) + Vector2(0, -120)
		_part(p, v, _rng.randf_range(0.7, 1.2), _rng.randf_range(2.5, 4.0), c, false, 700.0)
	for i in (12 if big else 5):
		var v := Vector2(_rng.randf_range(-50.0, 50.0), _rng.randf_range(-70.0, -20.0))
		_part(p, v, _rng.randf_range(0.8, 1.4), _rng.randf_range(6.0, 10.0), Color(0.35, 0.33, 0.45, 0.6), false, -20.0, 1.5, 1.0)
	_shake = maxf(_shake, 7.0 if big else 2.5)


## Smoke, exhaust and trails that come from the world's state each frame.
func _spawn_ambient(dt: float) -> void:
	var rate := dt * 60.0
	for w: E.Wreck in sim.wrecks:
		if _rng.randf() < 0.35 * rate:
			_part(w.pos + Vector2(_rng.randf_range(-12.0, 16.0), -10.0), Vector2(_rng.randf_range(-8.0, 8.0), -40.0),
				1.4, _rng.randf_range(4.0, 6.0), Color(0.3, 0.29, 0.38, 0.5), false, -10.0, 1.8)
		if _rng.randf() < 0.08 * rate:
			_part(w.pos + Vector2(_rng.randf_range(-15.0, 15.0), -6.0), Vector2(_rng.randf_range(-60.0, 60.0), -140.0),
				0.5, 1.5, Color(1.0, 0.7, 0.3), true, 500.0)
	var tr: E.Tractor = sim.tractor
	var face := _tractor_flip()
	var stack := tr.pos + Vector2(14.0 * face, -34.0)
	if _rng.randf() < (0.3 if tr.rider != null else 0.04) * rate:
		_part(stack, Vector2(-face * 10.0 + _rng.randf_range(-5.0, 5.0), -40.0), 1.2, 3.0,
			Color(0.45, 0.43, 0.52, 0.55), false, -10.0, 2.0)
	for u: E.Unit in sim.units:
		if not u.alive:
			continue
		if u.kind == E.Kind.GREY and u.speedy and u.grounded and absf(u.vel.x) > 60.0 and _rng.randf() < 0.5 * rate:
			_part(u.pos + Vector2(-u.facing * 8.0, 10.0), Vector2(-u.facing * 30.0, -10.0), 0.35, 2.0, CYAN, true)
		if u.kind == E.Kind.GREY and u.warrior and not u.grounded and u.in_jump and u.hover_fuel > 0.0 and _rng.randf() < 0.6 * rate:
			_part(u.pos + Vector2(0, 22), Vector2(_rng.randf_range(-20.0, 20.0), 120.0), 0.3, 2.0, Color(1.0, 0.6, 0.2), true)
		if u.kind == E.Kind.OVERLORD and u.in_beam and _rng.randf() < 0.5 * rate:
			var bottom := minf(u.pos.y + Cfg.BEAM_RANGE, Cfg.GROUND_Y)
			var q := Vector2(u.pos.x + _rng.randf_range(-Cfg.BEAM_HALF_W, Cfg.BEAM_HALF_W) * 0.8, _rng.randf_range(u.pos.y + 20.0, bottom))
			_part(q, Vector2(0, -90.0), 0.6, 1.6, Cfg.TEAM_COLORS[u.team].lightened(0.6), true)
	for p: Vector2 in sim.map.wormholes:
		if _rng.randf() < 0.15 * rate:
			var off := Vector2.from_angle(_rng.randf() * TAU) * 30.0
			_part(p + off, -off * 1.6, 0.6, 1.5, CYAN, true, 0.0, -0.5)


## Muzzle flashes for bolts fired since last frame.
func _track_bolts() -> void:
	var live := {}
	for b: E.Bolt in sim.bolts:
		var id := b.get_instance_id()
		live[id] = true
		if not _seen_bolts.has(id):
			var c: Color = Cfg.TEAM_COLORS[b.team].lightened(0.4)
			_flash(b.pos, 40.0, c)
			for i in 4:
				_part(b.pos, b.vel.normalized().rotated(_rng.randf_range(-0.6, 0.6)) * _rng.randf_range(80.0, 160.0), 0.2, 1.5, c, true)
	_seen_bolts = live


# --- Helpers ---------------------------------------------------------------

## Draws sprite `name` with its SVG-space `pivot` at `pos`.
func _tex(name: String, team: int, pos: Vector2, pivot: Vector2, flip := false, rot := 0.0,
		scale := 1.0, mod := Color.WHITE, squash := Vector2.ONE) -> void:
	var t := Art.tex(name, team)
	var s := Vector2(scale / RS * squash.x, scale / RS * squash.y)
	if flip:
		s.x = -s.x
	draw_set_transform(pos, rot, s)
	draw_texture(t, -pivot * RS, mod)
	draw_set_transform(Vector2.ZERO)


func _light(ci: CanvasItem, pos: Vector2, radius: float, color: Color, stretch := Vector2.ONE) -> void:
	var size := Vector2(radius, radius) * 2.0 * stretch
	ci.draw_texture_rect(_dot, Rect2(pos - size * 0.5, size), false, color)


func _light_rect(ci: CanvasItem, r: Rect2, color: Color) -> void:
	ci.draw_rect(r, color)


## Forget animation state for things the sim no longer has.
func _prune_anim() -> void:
	if sim == null:
		_anim.clear()
		return
	var live := {sim.tractor.get_instance_id(): true}
	for u: E.Unit in sim.units:
		live[u.get_instance_id()] = true
	for c: E.Cow in sim.cows:
		live[c.get_instance_id()] = true
	for id in _anim.keys():
		if not live.has(id):
			_anim.erase(id)


func _exit_tree() -> void:
	_anim.clear()
