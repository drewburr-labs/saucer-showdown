extends Node2D
## Top bar (Overlord lives, silo count, tractor route, map score), plus the
## win banner and the controls overlay.

const Cfg = preload("res://scripts/sim/config.gd")
const Sim = preload("res://scripts/sim/sim.gd")

const HELP := [
	"P1   WASD move  ·  Space jump  ·  J fire / use  ·  K tractor beam  ·  Q switch unit",
	"P2   Arrows move  ·  Up jump  ·  . fire / use  ·  / tractor beam  ·  Enter join / switch unit",
	"Pad  Stick move  ·  A jump  ·  X fire / use  ·  B tractor beam  ·  Y switch unit  ·  Start join",
	"",
	"Overlord (saucer): flies, shoots, beams cows or teammates, claims Probe Stations by touch.",
	"Grey: carries cows. Use next to the tractor to ride it. Down + jump drops through a platform.",
	"Stand in a Probe Station with a cow to become a warrior; in a wormhole for a speed boost.",
	"",
	"Win a map: shoot down the rival Overlord 3 times, bank 12 cows, or ride the tractor home.",
	"",
	"F1 help  ·  F2 team size (2v2 / 4v4)  ·  F3 spectate bots  ·  F5 install update  ·  R restart  ·  Esc pause",
]

var game # Main
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if game == null or game.sim == null:
		return
	var sim: Sim = game.sim
	draw_rect(Rect2(0, 0, Cfg.W, 58), Color(0.02, 0.03, 0.08, 0.9))
	for team in 2:
		_draw_team(sim, team)
	_draw_route(sim)

	if sim.winner >= 0:
		_draw_banner(sim)
	elif game.paused:
		_centered(330, "PAUSED", 44, Color.WHITE)
	if game.show_help:
		_draw_help()
	else:
		draw_string(_font, Vector2(0, Cfg.H - 10), "F1 controls", HORIZONTAL_ALIGNMENT_CENTER, Cfg.W, 12, Color(1, 1, 1, 0.45))
	_draw_update()


func _draw_team(sim: Sim, team: int) -> void:
	var c: Color = Cfg.TEAM_COLORS[team]
	var left := team == 0
	var x := 16.0 if left else Cfg.W - 16.0 - 400.0
	var align := HORIZONTAL_ALIGNMENT_LEFT if left else HORIZONTAL_ALIGNMENT_RIGHT
	draw_string(_font, Vector2(x, 22), Cfg.TEAM_NAMES[team], align, 400.0, 18, c)

	# Overlord lives
	var lives: int = sim.overlord(team).lives
	for i in Cfg.OVERLORD_LIVES:
		var px := (x + 12.0 + 26.0 * i) if left else (x + 400.0 - 12.0 - 26.0 * i)
		var col := c if i < lives else Color(c, 0.2)
		draw_arc(Vector2(px, 40), 9.0, PI, TAU, 10, col, 3.0)
		draw_line(Vector2(px - 12, 41), Vector2(px + 12, 41), col, 4.0)

	# Silo pips
	for i in Cfg.SILO_GOAL:
		var px := (x + 100.0 + 13.0 * i) if left else (x + 400.0 - 100.0 - 13.0 * i - 9.0)
		draw_rect(Rect2(px, 33, 9, 14), c if i < sim.silo[team] else Color(c, 0.2))
	var count := "%d/%d cows" % [sim.silo[team], Cfg.SILO_GOAL]
	var tx := (x + 264.0) if left else (x + 400.0 - 264.0 - 110.0)
	draw_string(_font, Vector2(tx, 46), count, align, 110.0, 14, Color.WHITE)


func _draw_route(sim: Sim) -> void:
	var x0 := 480.0
	var x1 := 800.0
	var y := 42.0
	var a: float = sim.map.crop_x[0]
	var b: float = sim.map.crop_x[1]
	draw_line(Vector2(x0, y), Vector2(x1, y), Color("5b6078"), 3.0)
	draw_circle(Vector2(x0, y), 7.0, Cfg.TEAM_COLORS[0])
	draw_circle(Vector2(x1, y), 7.0, Cfg.TEAM_COLORS[1])
	var k := clampf((sim.tractor.pos.x - a) / (b - a), 0.0, 1.0)
	var tp := Vector2(lerpf(x0, x1, k), y)
	var rider = sim.tractor.rider
	draw_rect(Rect2(tp.x - 8, tp.y - 7, 16, 11), Color("c0392b"))
	if rider != null:
		draw_rect(Rect2(tp.x - 10, tp.y - 9, 20, 15), Cfg.TEAM_COLORS[rider.team], false, 2.0)
	var score := "%d  –  %d" % [game.map_wins[0], game.map_wins[1]]
	draw_string(_font, Vector2(x0, 22), score, HORIZONTAL_ALIGNMENT_CENTER, x1 - x0, 18, Color.WHITE)
	var clock := "%d:%02d" % [int(sim.time) / 60, int(sim.time) % 60]
	draw_string(_font, Vector2(x0, 56), clock, HORIZONTAL_ALIGNMENT_CENTER, x1 - x0, 11, Color(1, 1, 1, 0.6))


func _draw_banner(sim: Sim) -> void:
	var c: Color = Cfg.TEAM_COLORS[sim.winner]
	draw_rect(Rect2(0, 250, Cfg.W, 170), Color(0.02, 0.03, 0.08, 0.88))
	draw_line(Vector2(0, 250), Vector2(Cfg.W, 250), c, 3.0)
	draw_line(Vector2(0, 420), Vector2(Cfg.W, 420), c, 3.0)
	var match_over: bool = game.match_winner >= 0
	var title: String = "%s wins the %s" % [Cfg.TEAM_NAMES[sim.winner], "match!" if match_over else "map"]
	_centered(315, title.to_upper(), 40, c)
	_centered(355, "%s victory   ·   maps %d – %d" % [Sim.WIN_NAMES[sim.win_reason], game.map_wins[0], game.map_wins[1]], 20, Color.WHITE)
	_centered(395, "Press Enter for %s" % ("a new match" if match_over else "the next map"), 16, Color(1, 1, 1, 0.7))


func _draw_help() -> void:
	var top := 440.0
	draw_rect(Rect2(150, top, Cfg.W - 300, 22.0 * HELP.size() + 24.0), Color(0.02, 0.03, 0.08, 0.86))
	for i in HELP.size():
		draw_string(_font, Vector2(170, top + 28.0 + 22.0 * i), HELP[i], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15, Color(1, 1, 1, 0.92))


func _draw_update() -> void:
	var up = game.updater
	if up == null:
		return
	draw_string(_font, Vector2(0, Cfg.H - 10), up.version, HORIZONTAL_ALIGNMENT_RIGHT, Cfg.W - 12.0, 12, Color(1, 1, 1, 0.45))
	var status: String = up.status_text()
	if status == "":
		return
	var w := _font.get_string_size(status, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14).x + 28.0
	draw_rect(Rect2((Cfg.W - w) * 0.5, 64, w, 26), Color(0.02, 0.03, 0.08, 0.9))
	draw_rect(Rect2((Cfg.W - w) * 0.5, 64, w, 26), Color("ffd166"), false, 1.0)
	draw_string(_font, Vector2(0, 82), status, HORIZONTAL_ALIGNMENT_CENTER, Cfg.W, 14, Color("ffd166"))


func _centered(y: float, s: String, size: int, color: Color) -> void:
	draw_string(_font, Vector2(0, y), s, HORIZONTAL_ALIGNMENT_CENTER, Cfg.W, size, color)
