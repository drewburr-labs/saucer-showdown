extends SceneTree
## Headless simulation tests.
##   godot --headless --path . --script tests/test_sim.gd

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const Bot = preload("res://scripts/sim/bot.gd")
const MapData = preload("res://scripts/sim/map_data.gd")

var _failed := 0
var _current := ""
var _sims: Array = []


func _init() -> void:
	_run("nav graph reaches every platform", _test_nav)
	_run("tractor win", _test_tractor_win)
	_run("tractor flattens enemy greys", _test_tractor_flattens)
	_run("economic win", _test_economic_win)
	_run("saucer takes three hits", _test_saucer_hp)
	_run("military win and saucer wrecks", _test_military_win)
	_run("probe station makes a warrior", _test_station)
	_run("enemy-owned station is locked", _test_station_locked)
	_run("wormhole gives a speed boost", _test_wormhole)
	_run("overlord beams a cow into the silo", _test_beam_deposit)
	_run("probed cow is worth two", _test_probed_cow)
	_run("cow heist out of the beam", _test_heist)
	_run("overlord beams a teammate", _test_beam_teammate)
	_run("worker bot banks a cow on its own", _test_bot_runs_cow)
	_run("bot matches stay sane", _test_bot_soak)
	for s: Sim in _sims:
		s.dispose()
	print("\n%s" % ("ALL TESTS PASSED" if _failed == 0 else "%d TEST(S) FAILED" % _failed))
	quit(1 if _failed > 0 else 0)


func _run(title: String, fn: Callable) -> void:
	_current = title
	var before := _failed
	fn.call()
	print("%s  %s" % ["ok  " if _failed == before else "FAIL", title])


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failed += 1
		print("      %s: %s" % [_current, what])


func _sim(p_seed: int, greys: int) -> Sim:
	var s := Sim.new(p_seed, greys)
	_sims.append(s)
	return s


func _steps(sim: Sim, n: int) -> void:
	for i in n:
		sim.step()


func _give_cow(sim: Sim, u: E.Unit) -> E.Cow:
	var c: E.Cow = sim._spawn_cow()
	c.pos = u.pos
	sim.step() # the grey picks it up on touch
	return c


# --- Tests ---------------------------------------------------------------

func _test_nav() -> void:
	var m := MapData.new()
	for a in m.platforms.size():
		for b in m.platforms.size():
			if a != b:
				_check(m.edge(a, b) != null, "no route from platform %d to %d" % [a, b])


func _test_tractor_win() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var g := sim.unit_at(1, 1)
	g.pos = sim.tractor.pos
	g.in_action = true
	sim.step()
	_check(g.riding, "grey should mount the tractor with the use button")
	g.in_action = false
	var ticks := 0
	while sim.winner < 0 and ticks < 60 * 60:
		sim.step()
		ticks += 1
	_check(sim.winner == 1 and sim.win_reason == Sim.Win.TRACTOR, "team 1 should win by tractor, got %d/%d" % [sim.winner, sim.win_reason])
	_check(sim.tractor.pos.x >= sim.map.crop_x[1], "tractor should be in team 1's crop circle")


func _test_tractor_flattens() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var rider := sim.unit_at(0, 1)
	var victim := sim.unit_at(1, 1)
	rider.pos = sim.tractor.pos
	rider.in_action = true
	victim.pos = Vector2(sim.tractor.pos.x - 70.0, Cfg.GROUND_Y - victim.half.y)
	_steps(sim, 240)
	_check(not victim.alive or victim.pos.x > Cfg.W / 2.0, "grey in the tractor's path should be flattened")
	_check(rider.riding, "rider stays on")


func _test_economic_win() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var g := sim.unit_at(0, 1)
	g.pos = sim.map.silo_point[0]
	for i in Cfg.SILO_GOAL:
		_check(sim.winner < 0, "should not win before the 12th cow")
		_give_cow(sim, g)
		sim.step()
	_check(sim.silo[0] == Cfg.SILO_GOAL, "silo should hold 12, has %d" % sim.silo[0])
	_check(sim.winner == 0 and sim.win_reason == Sim.Win.ECONOMIC, "team 0 should win economically")


func _test_saucer_hp() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var o := sim.overlord(0)
	o.shield_t = 0.0
	_check(o.hp == Cfg.OV_HP, "starts at full health")
	for i in Cfg.OV_HP - 1:
		sim.hit(o, "warrior")
		_check(o.alive, "still flying after %d hit(s)" % (i + 1))
	_check(o.hp == 1 and o.lives == Cfg.OVERLORD_LIVES, "hits cost health, not lives")
	_check(sim.events.filter(func(ev: Dictionary) -> bool: return ev["type"] == "hit").size() == Cfg.OV_HP - 1, "each hit is an event")
	sim.hit(o, "warrior")
	_check(not o.alive and o.lives == Cfg.OVERLORD_LIVES - 1, "the last hit downs her")
	_steps(sim, int(Cfg.OV_RESPAWN * 60.0) + 2)
	_check(o.alive and o.hp == Cfg.OV_HP, "respawns at full health")
	var g := sim.unit_at(0, 1)
	g.shield_t = 0.0
	sim.hit(g, "overlord")
	_check(not g.alive, "a grey still goes down in one")


func _test_military_win() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var target := sim.overlord(0)
	var shooter := sim.unit_at(1, 1)
	shooter.warrior = true
	var downs := 0
	var ticks := 0
	while sim.winner < 0 and ticks < 60 * 60:
		var was_alive := target.alive
		shooter.pos = target.pos + Vector2(80.0, 0.0)
		shooter.vel = Vector2.ZERO
		shooter.in_aim = Vector2.LEFT
		shooter.in_action = true
		sim.step()
		if was_alive and not target.alive:
			downs += 1
			_check(sim.wrecks.size() == 1, "a downed saucer leaves a wreck")
		elif target.alive and target.shield_t <= 0.0 and not was_alive:
			pass
		if target.alive and downs > 0 and downs < 3:
			_check(sim.wrecks.is_empty(), "wreck clears when she respawns")
		ticks += 1
	_check(downs == 3, "three downs, got %d" % downs)
	_check(sim.winner == 1 and sim.win_reason == Sim.Win.MILITARY, "team 1 should win militarily")


func _test_station() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var g := sim.unit_at(0, 1)
	g.pos = Vector2(sim.map.stations[0].x, MapData.T4 - g.half.y)
	_give_cow(sim, g)
	_check(g.carrying != null, "grey should be carrying")
	_steps(sim, 45)
	_check(g.warrior, "grey should come out a warrior")
	_check(g.carrying == null and sim.cows.is_empty(), "the cow is spent")
	var c: E.Cow = sim._spawn_cow()
	c.pos = g.pos
	_steps(sim, 5)
	_check(g.carrying == null, "warriors can't carry cows")


func _test_station_locked() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	sim.station_owner[0] = 1
	var g := sim.unit_at(0, 1)
	g.pos = Vector2(sim.map.stations[0].x, MapData.T4 - g.half.y)
	_give_cow(sim, g)
	_steps(sim, 60)
	_check(not g.warrior, "enemy-owned station should not work")
	# The Overlord claims it by touch, and then it does.
	var o := sim.overlord(0)
	o.pos = sim.map.stations[0]
	_steps(sim, 60)
	_check(sim.station_owner[0] == 0, "overlord should claim the station")
	_check(g.warrior, "claimed station should work")


func _test_wormhole() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var g := sim.unit_at(0, 1)
	g.pos = Vector2(sim.map.wormholes[0].x, MapData.T1 - g.half.y)
	_give_cow(sim, g)
	_steps(sim, 45)
	_check(g.speedy and g.carrying == null, "grey should get the speed boost and spend the cow")
	sim.kill(g)
	_steps(sim, 240)
	_check(g.alive and g.speedy, "speed boost is permanent")


func _fly_to(sim: Sim, o: E.Unit, dest: Vector2, max_ticks: int) -> void:
	for i in max_ticks:
		var d := dest - o.pos
		if d.length() < 4.0:
			break
		o.in_move = d.limit_length(40.0) / 40.0
		sim.step()
	o.in_move = Vector2.ZERO


func _test_beam_deposit() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var o := sim.overlord(0)
	var c: E.Cow = sim._spawn_cow()
	c.pos = Vector2(640, Cfg.GROUND_Y - c.half.y)
	o.pos = c.pos + Vector2(0, -100)
	o.in_beam = true
	_steps(sim, 30)
	_check(o.beam_target == c and c.state == E.CowState.BEAMED, "overlord should lift the cow")
	_fly_to(sim, o, sim.map.silo_zone[0].get_center() - Vector2(0, Cfg.BEAM_HANG), 900)
	_steps(sim, 10)
	_check(sim.silo[0] == 1, "beamed cow should be banked, silo has %d" % sim.silo[0])
	_check(o.beam_target == null, "beam lets go after the deposit")


func _test_probed_cow() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var o := sim.overlord(0)
	var c: E.Cow = sim._spawn_cow()
	c.pos = Vector2(640, Cfg.GROUND_Y - c.half.y)
	o.pos = c.pos + Vector2(0, -100)
	o.in_beam = true
	_steps(sim, 30)
	_fly_to(sim, o, sim.map.stations[0] - Vector2(0, Cfg.BEAM_HANG), 900)
	_steps(sim, 10)
	_check(c.probed, "cow beamed through a station should be probed")
	_fly_to(sim, o, sim.map.silo_zone[0].get_center() - Vector2(0, Cfg.BEAM_HANG), 900)
	_steps(sim, 10)
	_check(sim.silo[0] == Cfg.PROBED_VALUE, "probed cow should bank for 2, silo has %d" % sim.silo[0])


func _test_heist() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var o := sim.overlord(0)
	var thief := sim.unit_at(1, 1)
	var c: E.Cow = sim._spawn_cow()
	c.pos = Vector2(640, Cfg.GROUND_Y - c.half.y)
	o.pos = Vector2(640, Cfg.GROUND_Y - 60.0)
	o.in_beam = true
	sim.step()
	_check(c.state == E.CowState.BEAMED, "cow should be in the beam")
	thief.pos = Vector2(640, Cfg.GROUND_Y - thief.half.y)
	_steps(sim, 3)
	_check(thief.carrying == c, "enemy grey should grab the cow mid-beam")
	_check(o.beam_target == null, "overlord loses the cow")


func _test_beam_teammate() -> void:
	var sim := _sim(1, 1)
	sim.cows.clear()
	var o := sim.overlord(0)
	var g := sim.unit_at(0, 1)
	g.pos = Vector2(400, Cfg.GROUND_Y - g.half.y)
	o.pos = g.pos + Vector2(0, -120)
	o.in_beam = true
	_steps(sim, 30)
	_check(g.held_by == o, "overlord should lift a teammate")
	_fly_to(sim, o, Vector2(640, MapData.T4 - 80.0), 900)
	o.in_beam = false
	_steps(sim, 60)
	_check(g.held_by == null and g.grounded, "dropped teammate lands")
	_check(g.on_plat == sim.map.plat_under(Vector2(640, MapData.T4 - 10.0)), "and lands on the centre probe deck")


func _test_bot_runs_cow() -> void:
	var sim := _sim(3, 1)
	var g := sim.unit_at(0, 1)
	var bot := Bot.new(sim, g, 7)
	bot.plan = "econ"
	bot.plan_t = 999.0
	var ticks := 0
	while sim.silo[0] == 0 and ticks < 60 * 30:
		bot.think()
		sim.step()
		ticks += 1
	_check(sim.silo[0] >= 1, "bot should carry a cow up to the silo within 30 s")


func _test_bot_soak() -> void:
	var finished := 0
	var total := 0
	var reasons := {}
	for greys in [1, 3]:
		for s in 6:
			total += 1
			var sim := Sim.new(100 + s, greys)
			var bots: Array = []
			for u: E.Unit in sim.units:
				bots.append(Bot.new(sim, u, 1000 + s * 31 + u.id))
			var ticks := 0
			while sim.winner < 0 and ticks < 60 * 60 * 8:
				for b: Bot in bots:
					b.think()
				sim.step()
				ticks += 1
				if ticks % 600 == 0:
					_sanity(sim)
			if sim.winner >= 0:
				finished += 1
				var r: String = Sim.WIN_NAMES[sim.win_reason]
				reasons[r] = reasons.get(r, 0) + 1
			print("      %dv%d seed %d: %s after %d s  (silo %s, lives %d/%d, tractor x %d)" % [
				greys + 1, greys + 1, 100 + s,
				("%s win for team %d" % [Sim.WIN_NAMES[sim.win_reason], sim.winner]) if sim.winner >= 0 else "no result",
				int(sim.time), sim.silo, sim.overlord(0).lives, sim.overlord(1).lives, int(sim.tractor.pos.x)])
			sim.dispose()
	print("      %d/%d finished inside 8 minutes; wins by type: %s" % [finished, total, reasons])
	_check(finished >= total / 2, "at least half of bot matches should finish inside 8 minutes")


func _sanity(sim: Sim) -> void:
	for u: E.Unit in sim.units:
		_check(u.pos.x >= 0.0 and u.pos.x <= Cfg.W and u.pos.y >= 0.0 and u.pos.y <= Cfg.GROUND_Y + 1.0, "unit %d out of bounds at %s" % [u.id, u.pos])
		if u.carrying != null:
			_check(u.carrying.holder == u and sim.cows.has(u.carrying), "carry link broken on unit %d" % u.id)
	for c: E.Cow in sim.cows:
		_check(c.pos.y <= Cfg.GROUND_Y + 1.0, "cow below the ground at %s" % c.pos)
		_check((c.state == E.CowState.LOOSE) == (c.holder == null), "cow state and holder disagree")
	_check(sim.cows.size() <= Cfg.COW_MAX_TOTAL, "too many cows: %d" % sim.cows.size())
