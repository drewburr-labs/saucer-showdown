extends Node2D
## Greybox renderer. Draws the whole arena from the sim's state each frame
## with primitives; there are no art assets yet.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")

const SKY := Color("0b1026")
const PLATFORM := Color("5b6078")
const GOLD := Color("ffd84a")

var sim # Sim
var labels: Dictionary = {} # unit id -> "P1"
var _fx: Array = []
var _stars := PackedVector2Array()
var _font: Font
var _t := 0.0


func _ready() -> void:
	_font = ThemeDB.fallback_font
	var rng := RandomNumberGenerator.new()
	rng.seed = 51
	for i in 90:
		_stars.append(Vector2(rng.randf_range(0.0, Cfg.W), rng.randf_range(60.0, 520.0)))


func _process(delta: float) -> void:
	_t += delta
	for f in _fx:
		f["t"] += delta
	_fx = _fx.filter(func(f: Dictionary) -> bool: return f["t"] < 0.9)
	queue_redraw()


func add_events(events: Array) -> void:
	for ev: Dictionary in events:
		var text := ""
		match ev["type"]:
			"deposit":
				text = "+%d" % ev["value"]
			"heist":
				text = "HEIST!"
			"warrior":
				text = "WARRIOR"
			"speed":
				text = "SPEED"
			"probed":
				text = "PROBED x2"
			"claim":
				text = "CLAIMED"
		_fx.append({"pos": ev["pos"], "t": 0.0, "text": text, "color": Cfg.TEAM_COLORS[ev["team"]]})


func _draw() -> void:
	if sim == null:
		return
	_draw_backdrop()
	_draw_gates()
	for w: E.Wreck in sim.wrecks:
		_draw_wreck(w)
	_draw_tractor()
	for u: E.Unit in sim.units:
		if u.alive and u.kind == E.Kind.OVERLORD and u.in_beam:
			_draw_beam(u)
	for c: E.Cow in sim.cows:
		_draw_cow(c)
	for u: E.Unit in sim.units:
		if not u.alive:
			continue
		if u.kind == E.Kind.OVERLORD:
			_draw_overlord(u)
		else:
			_draw_grey(u)
		if labels.has(u.id):
			_text(u.pos + Vector2(-30.0, -u.half.y - 14.0), labels[u.id], 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, 60.0)
	for b: E.Bolt in sim.bolts:
		var c: Color = Cfg.TEAM_COLORS[b.team].lightened(0.5)
		draw_line(b.pos - b.vel.normalized() * 14.0, b.pos, c, 3.0)
	for f in _fx:
		var k: float = f["t"] / 0.9
		var col: Color = f["color"]
		col.a = 1.0 - k
		draw_arc(f["pos"], 10.0 + 40.0 * k, 0.0, TAU, 24, col, 2.0)
		if f["text"] != "":
			_text(f["pos"] + Vector2(-60.0, -24.0 - 30.0 * k), f["text"], 16, col.lightened(0.4), HORIZONTAL_ALIGNMENT_CENTER, 120.0)


func _draw_backdrop() -> void:
	var m = sim.map
	draw_rect(Rect2(0, 0, Cfg.W, Cfg.H), SKY)
	draw_rect(Rect2(0, 520, Cfg.W, 140), Color("121a3a"))
	for s in _stars:
		draw_rect(Rect2(s, Vector2(2, 2)), Color(1, 1, 1, 0.55))
	draw_circle(Vector2(1090, 150), 34.0, Color("e8e6c8"))
	draw_circle(Vector2(1078, 142), 30.0, SKY)

	# Barn
	draw_rect(m.barn, Color("3a1f24"))
	draw_rect(Rect2(m.barn.position.x + 90, m.barn.end.y - 90, 60, 90), Color("2a1418"))
	draw_rect(m.barn, Color("5a2f36"), false, 2.0)

	# Silos, filling up with banked cows
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var x := 0.0 if team == 0 else Cfg.W - 64.0
		var body := Rect2(x, 300, 64, Cfg.GROUND_Y - 300)
		draw_rect(body, Color("1a1e33"))
		var fill := clampf(float(sim.silo[team]) / Cfg.SILO_GOAL, 0.0, 1.0)
		draw_rect(Rect2(x, body.end.y - body.size.y * fill, 64, body.size.y * fill), Color(c, 0.45))
		draw_rect(body, c, false, 2.0)
		_ellipse(Vector2(x + 32, 300), 32, 16, c.darkened(0.4))
		draw_rect(m.silo_zone[team], Color(c, 0.18 + 0.08 * sin(_t * 3.0)))

	# Ground and the crop circles
	draw_rect(Rect2(0, Cfg.GROUND_Y, Cfg.W, Cfg.H - Cfg.GROUND_Y), Color("16241a"))
	draw_line(Vector2(0, Cfg.GROUND_Y), Vector2(Cfg.W, Cfg.GROUND_Y), Color("3d6b45"), 2.0)
	draw_rect(Rect2(m.pasture.x, Cfg.GROUND_Y, m.pasture.y - m.pasture.x, 6), Color("4f8f58"))
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		draw_set_transform(Vector2(m.crop_x[team], Cfg.GROUND_Y + 22.0), 0.0, Vector2(1.0, 0.3))
		draw_arc(Vector2.ZERO, 46.0, 0.0, TAU, 32, c, 4.0)
		draw_arc(Vector2.ZERO, 26.0, 0.0, TAU, 24, Color(c, 0.6), 4.0)
		draw_set_transform(Vector2.ZERO)
		draw_line(Vector2(m.crop_x[team], Cfg.GROUND_Y - 30.0), Vector2(m.crop_x[team], Cfg.GROUND_Y), Color(c, 0.5), 2.0)

	for i in range(1, m.platforms.size()):
		var p = m.platforms[i]
		draw_rect(Rect2(p.x0, p.y, p.x1 - p.x0, 10), PLATFORM)
		draw_line(Vector2(p.x0, p.y + 1), Vector2(p.x1, p.y + 1), PLATFORM.lightened(0.35), 2.0)


func _draw_gates() -> void:
	var m = sim.map
	for i in m.stations.size():
		var p: Vector2 = m.stations[i]
		var held_by: int = sim.station_owner[i]
		var rim: Color = Color("c9cbd6") if held_by < 0 else Cfg.TEAM_COLORS[held_by]
		draw_circle(p, Cfg.GATE_RADIUS, Color("141829"))
		draw_arc(p, Cfg.GATE_RADIUS, 0.0, TAU, 28, rim, 4.0)
		draw_line(p + Vector2(0, -Cfg.GATE_RADIUS), p + Vector2(0, -Cfg.GATE_RADIUS - 12), rim, 2.0)
		draw_circle(p + Vector2(0, -Cfg.GATE_RADIUS - 14), 3.0, rim)
		draw_line(p + Vector2(-7, 6), p + Vector2(0, -8), rim, 2.0)
		draw_line(p + Vector2(7, 6), p + Vector2(0, -8), rim, 2.0)
	for p: Vector2 in m.wormholes:
		draw_circle(p, Cfg.GATE_RADIUS, Color("0d1a2a"))
		for k in 3:
			var a := _t * (2.0 + k) + k * 2.1
			draw_arc(p, Cfg.GATE_RADIUS - 4.0 - 6.0 * k, a, a + 4.2, 16, Color("59d7ff"), 2.5)


func _draw_wreck(w: E.Wreck) -> void:
	var c: Color = Cfg.TEAM_COLORS[w.owner.team].darkened(0.55) if w.owner != null else Color.DIM_GRAY
	_ellipse(w.pos, w.half.x, w.half.y, c)
	draw_line(w.pos + Vector2(-w.half.x, -w.half.y), w.pos + Vector2(w.half.x, -w.half.y), c.lightened(0.3), 2.0)
	for k in 3:
		var rise := fmod(_t * 30.0 + k * 13.0, 40.0)
		draw_circle(w.pos + Vector2(-8.0 + 8.0 * k, -12.0 - rise), 4.0, Color(0.6, 0.6, 0.6, 0.5 - rise / 80.0))


func _draw_tractor() -> void:
	var t: E.Tractor = sim.tractor
	var p := t.pos
	draw_rect(Rect2(p.x - 30, p.y - 14, 60, 22), Color("c0392b"))
	draw_rect(Rect2(p.x - 14, p.y - 20, 28, 8), Color("962d22"))
	draw_circle(p + Vector2(-18, 8), 12.0, Color("1c1c22"))
	draw_circle(p + Vector2(-18, 8), 5.0, Color("8a8a94"))
	draw_circle(p + Vector2(18, 11), 9.0, Color("1c1c22"))
	draw_circle(p + Vector2(18, 11), 4.0, Color("8a8a94"))
	if t.rider != null:
		var c: Color = Cfg.TEAM_COLORS[t.rider.team]
		var tip := p + Vector2(t.dir * 52.0, -4.0)
		draw_line(tip - Vector2(t.dir * 14.0, 0), tip, c, 3.0)
		draw_line(tip, tip + Vector2(-t.dir * 7.0, -6.0), c, 3.0)
		draw_line(tip, tip + Vector2(-t.dir * 7.0, 6.0), c, 3.0)


func _draw_beam(u: E.Unit) -> void:
	var c := Color(Cfg.TEAM_COLORS[u.team].lightened(0.5), 0.22)
	var p := u.pos
	var bottom := minf(p.y + Cfg.BEAM_RANGE, Cfg.GROUND_Y)
	draw_colored_polygon(PackedVector2Array([
		p + Vector2(-8, 6), p + Vector2(8, 6),
		Vector2(p.x + Cfg.BEAM_HALF_W, bottom), Vector2(p.x - Cfg.BEAM_HALF_W, bottom)]), c)


func _draw_cow(c: E.Cow) -> void:
	var p := c.pos
	if c.probed:
		_ellipse(p, 26, 20, Color(0.75, 1.0, 0.3, 0.25 + 0.1 * sin(_t * 8.0)))
	draw_rect(Rect2(p.x - 13, p.y - 8, 23, 13), Color.WHITE)
	draw_rect(Rect2(p.x + 7, p.y - 11, 8, 9), Color.WHITE)
	draw_rect(Rect2(p.x - 9, p.y - 6, 7, 5), Color.BLACK)
	draw_rect(Rect2(p.x + 1, p.y - 2, 5, 5), Color.BLACK)
	draw_rect(Rect2(p.x - 11, p.y + 5, 4, 5), Color("d9d9d9"))
	draw_rect(Rect2(p.x + 4, p.y + 5, 4, 5), Color("d9d9d9"))
	draw_rect(Rect2(p.x + 12, p.y - 8, 2, 2), Color.BLACK)


func _draw_grey(u: E.Unit) -> void:
	var c: Color = Cfg.TEAM_COLORS[u.team]
	var p := u.pos
	if u.shield_t > 0.0:
		draw_arc(p, 20.0, 0.0, TAU, 20, Color(1, 1, 1, 0.7), 2.0)
	draw_rect(Rect2(p.x - 7, p.y - 2, 14, 17), c.darkened(0.2))
	_ellipse(p + Vector2(0, -6), 11, 9, c)
	_ellipse(p + Vector2(-4 + u.facing * 2.0, -6), 3, 4, Color.BLACK)
	_ellipse(p + Vector2(4 + u.facing * 2.0, -6), 3, 4, Color.BLACK)
	if u.warrior:
		draw_rect(Rect2(p.x - 9, p.y - 3, 18, 19), GOLD, false, 2.0)
		draw_line(p + Vector2(u.facing * 5.0, 5), p + Vector2(u.facing * 20.0, 5), GOLD, 4.0)
		if not u.grounded and u.in_jump and u.hover_fuel > 0.0:
			draw_line(p + Vector2(0, 15), p + Vector2(0, 26), Color("ff9d3b"), 5.0)
	if u.speedy:
		for k in 2:
			var b := p + Vector2(-u.facing * (15.0 + 6.0 * k), 6.0)
			draw_line(b + Vector2(-u.facing * 4.0, -5), b, Color("59d7ff"), 2.0)
			draw_line(b + Vector2(-u.facing * 4.0, 5), b, Color("59d7ff"), 2.0)
	if u.gate_t > 0.0:
		draw_arc(p, 24.0, -PI / 2.0, -PI / 2.0 + TAU * u.gate_t / Cfg.GATE_DWELL, 20, Color.WHITE, 3.0)


func _draw_overlord(u: E.Unit) -> void:
	var c: Color = Cfg.TEAM_COLORS[u.team]
	var p := u.pos
	if u.shield_t > 0.0:
		draw_arc(p, 32.0, 0.0, TAU, 24, Color(1, 1, 1, 0.7), 2.0)
	_ellipse(p + Vector2(0, -6), 12, 10, Color(0.75, 0.92, 1.0, 0.85))
	_ellipse(p, u.half.x, 9, c)
	_ellipse(p + Vector2(0, 3), u.half.x, 5, c.darkened(0.35))
	for k in 3:
		var on := int(_t * 6.0) % 3 == k
		draw_circle(p + Vector2(-12.0 + 12.0 * k, 3), 2.0, GOLD if on else c.lightened(0.5))
	var nose := p + Vector2(u.facing * (u.half.x + 4.0), 0)
	draw_line(nose - Vector2(u.facing * 6.0, 0), nose, c.lightened(0.6), 3.0)


func _ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 20:
		var a := TAU * i / 20.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, color)


func _text(pos: Vector2, s: String, size: int, color: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	draw_string(_font, pos, s, align, width, size, color)
