extends Node2D
## Top bar (Overlord lives, silo count, tractor route, map score), plus the
## win banner and the controls overlay.

const Cfg = preload("res://scripts/sim/config.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const Art = preload("res://scripts/view/art.gd")

const INK := Color("140f26")
const PANEL := Color(0.04, 0.03, 0.12, 0.82)
const BAR_H := 62.0

const HELP := [
	["P1", "WASD move  ·  Space jump  ·  J fire / use  ·  K tractor beam  ·  Q switch unit"],
	["P2", "Arrows move  ·  Up jump  ·  . fire / use  ·  / tractor beam  ·  Enter join / switch unit"],
	["Pad", "Stick move  ·  A jump  ·  X fire / use  ·  B tractor beam  ·  Y switch unit  ·  Start join"],
	["", ""],
	["", "Overlord (saucer): flies, shoots, beams cows or teammates, claims Probe Stations by touch."],
	["", "Grey: carries cows. Use next to the tractor to ride it. Down + jump drops through a platform."],
	["", "Stand in a Probe Station with a cow to become a warrior; in a wormhole for a speed boost."],
	["", ""],
	["Win", "Shoot down the rival Overlord 3 times, bank 12 cows, or ride the tractor home."],
	["", ""],
	["", "F1 help  ·  F2 team size (2v2 / 4v4)  ·  F3 spectate bots  ·  F5 check for update  ·  R restart  ·  Esc pause"],
]

var game # Main
var _font: Font
var _title: Font
var _t := 0.0


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_font = Art.body_font()
	_title = Art.title_font()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	if game == null or game.sim == null:
		return
	var sim: Sim = game.sim
	_draw_bar()
	for team in 2:
		_draw_team(sim, team)
	_draw_route(sim)

	if sim.winner >= 0:
		_draw_banner(sim)
	elif game.paused:
		_draw_paused()
	if game.show_help:
		_draw_help()
	else:
		_text(_font, Vector2(0, Cfg.H - 10), "F1 controls", 13, Color(1, 1, 1, 0.5), HORIZONTAL_ALIGNMENT_CENTER, Cfg.W)
	_draw_update()


func _draw_bar() -> void:
	draw_rect(Rect2(0, 0, Cfg.W, BAR_H), PANEL)
	for i in 8:
		draw_rect(Rect2(0, BAR_H + i, Cfg.W, 1), Color(0, 0, 0, 0.18 * (1.0 - i / 8.0)))
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var x0 := 0.0 if team == 0 else Cfg.W * 0.5
		draw_rect(Rect2(x0, BAR_H - 3, Cfg.W * 0.5, 3), Color(c, 0.85))
	# Centre plate for the score and route
	var plate := PackedVector2Array([Vector2(452, 0), Vector2(828, 0), Vector2(808, BAR_H + 10), Vector2(472, BAR_H + 10)])
	draw_colored_polygon(plate, Color(0.07, 0.05, 0.18, 0.95))
	draw_polyline(PackedVector2Array([Vector2(452, 0), Vector2(472, BAR_H + 10), Vector2(808, BAR_H + 10), Vector2(828, 0)]), Color(1, 1, 1, 0.18), 2.0, true)


func _draw_team(sim: Sim, team: int) -> void:
	var c: Color = Cfg.TEAM_COLORS[team]
	var left := team == 0
	var x := 18.0 if left else Cfg.W - 18.0 - 420.0
	var align := HORIZONTAL_ALIGNMENT_LEFT if left else HORIZONTAL_ALIGNMENT_RIGHT
	_text(_title, Vector2(x, 27), Cfg.TEAM_NAMES[team], 23, c.lightened(0.15), align, 420.0, true)

	# Overlord lives, as little saucers
	var lives: int = sim.overlord(team).lives
	var saucer := Art.tex("saucer", team)
	for i in Cfg.OVERLORD_LIVES:
		var px := (x + 20.0 + 34.0 * i) if left else (x + 420.0 - 20.0 - 34.0 * i)
		var alive := i < lives
		var s := 0.36 / Art.RS
		draw_set_transform(Vector2(px, 45), 0.0, Vector2(s, s))
		draw_texture(saucer, -Vector2(44, 30) * Art.RS, Color.WHITE if alive else Color(0.45, 0.45, 0.55, 0.4))
		draw_set_transform(Vector2.ZERO)
		if not alive:
			draw_line(Vector2(px - 9, 39), Vector2(px + 9, 51), Color("ff5a7a"), 2.5, true)

	# Silo pips
	var banked: int = sim.silo[team]
	for i in Cfg.SILO_GOAL:
		var px := (x + 130.0 + 13.0 * i) if left else (x + 420.0 - 130.0 - 13.0 * i - 10.0)
		var r := Rect2(px, 37, 10, 16)
		draw_rect(r.grow(1.5), INK)
		if i < banked:
			draw_rect(r, c)
			draw_rect(Rect2(px + 1, 38, 3, 14), Color(1, 1, 1, 0.35))
		else:
			draw_rect(r, Color(c, 0.18))
	var cow := Art.tex("cow")
	var cx := (x + 296.0) if left else (x + 420.0 - 296.0 - 30.0)
	draw_set_transform(Vector2(cx + 15, 45), 0.0, Vector2(0.55, 0.55) / Art.RS)
	draw_texture(cow, -Vector2(22, 22) * Art.RS)
	draw_set_transform(Vector2.ZERO)
	var count := "%d/%d" % [banked, Cfg.SILO_GOAL]
	var tx := (cx + 34.0) if left else (cx - 74.0)
	_text(_title, Vector2(tx, 53), count, 19, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT if left else HORIZONTAL_ALIGNMENT_RIGHT, 70.0, true)


func _draw_route(sim: Sim) -> void:
	var x0 := 500.0
	var x1 := 780.0
	var y := 52.0
	var a: float = sim.map.crop_x[0]
	var b: float = sim.map.crop_x[1]
	draw_line(Vector2(x0, y), Vector2(x1, y), INK, 7.0, true)
	draw_line(Vector2(x0, y), Vector2(x1, y), Color("3b3f5c"), 3.0, true)
	var k := clampf((sim.tractor.pos.x - a) / (b - a), 0.0, 1.0)
	var tp := Vector2(lerpf(x0, x1, k), y)
	draw_line(Vector2(x0, y), Vector2(tp.x, y), Color(Cfg.TEAM_COLORS[0], 0.6), 3.0, true)
	draw_line(Vector2(tp.x, y), Vector2(x1, y), Color(Cfg.TEAM_COLORS[1], 0.6), 3.0, true)
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var e := Vector2(x0 if team == 0 else x1, y)
		draw_set_transform(e, 0.0, Vector2(1.0, 0.45))
		draw_circle(Vector2.ZERO, 12.0, INK, true, -1.0, true)
		draw_arc(Vector2.ZERO, 9.0, 0.0, TAU, 24, c, 3.0, true)
		draw_circle(Vector2.ZERO, 3.5, c, true, -1.0, true)
		draw_set_transform(Vector2.ZERO)
	var rider = sim.tractor.rider
	var face := -1.0 if sim.tractor.dir < 0.0 else 1.0
	if rider != null:
		var rc: Color = Cfg.TEAM_COLORS[rider.team]
		var pulse := 0.6 + 0.4 * sin(_t * 8.0)
		draw_circle(tp + Vector2(0, -4), 15.0, Color(rc, 0.35 * pulse), true, -1.0, true)
	var s := 0.32 / Art.RS
	draw_set_transform(tp + Vector2(0, -6), 0.0, Vector2(s * face, s))
	draw_texture(Art.tex("tractor"), -Vector2(44, 38) * Art.RS)
	draw_set_transform(Vector2.ZERO)
	var score := "%d  –  %d" % [game.map_wins[0], game.map_wins[1]]
	_text(_title, Vector2(x0, 31), score, 28, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, x1 - x0, true)
	var clock := "%d:%02d" % [int(sim.time) / 60, int(sim.time) % 60]
	_text(_font, Vector2(x0, 31), clock, 13, Color(1, 1, 1, 0.55), HORIZONTAL_ALIGNMENT_RIGHT, x1 - x0 - 4.0)
	_text(_font, Vector2(x0 + 4.0, 31), "MAP %d" % (game.map_wins[0] + game.map_wins[1] + (0 if sim.winner >= 0 else 1)), 13, Color(1, 1, 1, 0.55), HORIZONTAL_ALIGNMENT_LEFT, 80.0)


func _draw_banner(sim: Sim) -> void:
	var c: Color = Cfg.TEAM_COLORS[sim.winner]
	var top := 236.0
	var h := 200.0
	draw_rect(Rect2(0, 0, Cfg.W, Cfg.H), Color(0.0, 0.0, 0.05, 0.35))
	draw_rect(Rect2(0, top, Cfg.W, h), Color(0.03, 0.02, 0.1, 0.92))
	for i in 3:
		var a := 0.9 - i * 0.3
		draw_line(Vector2(0, top - i * 3), Vector2(Cfg.W, top - i * 3), Color(c, a), 2.0)
		draw_line(Vector2(0, top + h + i * 3), Vector2(Cfg.W, top + h + i * 3), Color(c, a), 2.0)
	var saucer := Art.tex("saucer", sim.winner)
	for side in [-1.0, 1.0]:
		var p := Vector2(Cfg.W * 0.5 + side * 470.0, top + 92.0 + sin(_t * 2.5 + side) * 6.0)
		var s := 1.4 / Art.RS
		draw_set_transform(p, side * -0.12, Vector2(s, s))
		draw_texture(saucer, -Vector2(44, 30) * Art.RS)
		draw_set_transform(Vector2.ZERO)
	var match_over: bool = game.match_winner >= 0
	var title: String = "%s wins the %s" % [Cfg.TEAM_NAMES[sim.winner], "match!" if match_over else "map"]
	var bump := 1.0 + 0.04 * sin(_t * 4.0)
	_text(_title, Vector2(0, top + 78), title.to_upper(), int(50 * bump), c.lightened(0.2), HORIZONTAL_ALIGNMENT_CENTER, Cfg.W, true, 10)
	_text(_title, Vector2(0, top + 122), "%s victory   ·   maps %d – %d" % [Sim.WIN_NAMES[sim.win_reason], game.map_wins[0], game.map_wins[1]], 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, Cfg.W, true)
	var blink := 0.55 + 0.35 * sin(_t * 3.0)
	_text(_font, Vector2(0, top + 166), "Press Enter for %s" % ("a new match" if match_over else "the next map"), 18, Color(1, 1, 1, blink), HORIZONTAL_ALIGNMENT_CENTER, Cfg.W)


func _draw_paused() -> void:
	draw_rect(Rect2(0, 0, Cfg.W, Cfg.H), Color(0.0, 0.0, 0.05, 0.45))
	_text(_title, Vector2(0, 350), "PAUSED", 64, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, Cfg.W, true, 10)
	_text(_font, Vector2(0, 386), "Esc to resume", 18, Color(1, 1, 1, 0.7), HORIZONTAL_ALIGNMENT_CENTER, Cfg.W)


func _draw_help() -> void:
	var w := 1000.0
	var row := 23.0
	var h := row * HELP.size() + 30.0
	var r := Rect2((Cfg.W - w) * 0.5, Cfg.H - h - 26.0, w, h)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.03, 0.12, 0.9)
	sb.border_color = Color(1, 1, 1, 0.16)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	draw_style_box(sb, r)
	for i in HELP.size():
		var y := r.position.y + 30.0 + row * i
		var tag: String = HELP[i][0]
		if tag != "":
			var tw := 46.0
			var kr := Rect2(r.position.x + 22.0, y - 16.0, tw, 21.0)
			var ks := StyleBoxFlat.new()
			ks.bg_color = Color("ffd84a") if tag == "Win" else Color(1, 1, 1, 0.14)
			ks.set_corner_radius_all(6)
			draw_style_box(ks, kr)
			_text(_title, Vector2(kr.position.x, y), tag, 15, INK if tag == "Win" else Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, tw)
		_text(_font, Vector2(r.position.x + 84.0, y), HELP[i][1], 15, Color(1, 1, 1, 0.92))


func _draw_update() -> void:
	var up = game.updater
	if up == null:
		return
	_text(_font, Vector2(0, Cfg.H - 10), up.version, 12, Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_RIGHT, Cfg.W - 12.0)
	var status: String = up.status_text()
	if status == "":
		return
	var w := _font.get_string_size(status, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15).x + 36.0
	var r := Rect2((Cfg.W - w) * 0.5, BAR_H + 16, w, 30)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.03, 0.12, 0.92)
	sb.border_color = Color("ffd166")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(15)
	draw_style_box(sb, r)
	_text(_font, Vector2(0, r.position.y + 21), status, 15, Color("ffd166"), HORIZONTAL_ALIGNMENT_CENTER, Cfg.W)


func _text(font: Font, pos: Vector2, s: String, size: int, color: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0,
		outline := false, outline_size := 6) -> void:
	if outline:
		draw_string_outline(font, pos, s, align, width, size, outline_size, INK)
	draw_string(font, pos, s, align, width, size, color)
