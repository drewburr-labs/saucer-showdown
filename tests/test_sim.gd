extends SceneTree
## Headless simulation tests.
##   godot --headless --path . --script tests/test_sim.gd

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const Bot = preload("res://scripts/sim/bot.gd")
const MapData = preload("res://scripts/sim/map_data.gd")
const InputFrame = preload("res://scripts/sim/input_frame.gd")
const FMath = preload("res://scripts/sim/fmath.gd")

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
	_run("deterministic trig matches sin and cos", _test_fmath)
	_run("input frames pack and unpack", _test_input_frame)
	_run("same seed and frames give the same match", _test_lockstep)
	_run("snapshot restores into a fresh sim", _test_snapshot)
	_run("rollback with wrong guesses converges", _test_rollback)
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
	var bot: Bot = sim.bots[g.id]
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
			var frame := InputFrame.all_bots(sim.units.size())
			var ticks := 0
			while sim.winner < 0 and ticks < 60 * 60 * 8:
				sim.step_frame(frame)
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


# --- Netcode readiness ---------------------------------------------------

## Frames for a mixed match: units in `humans` get scripted inputs that
## change every few ticks, everyone else is left to the bots.
func _frames(units: int, humans: Array, n: int, p_seed: int) -> Array[PackedByteArray]:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var out: Array[PackedByteArray] = []
	var held := {}
	for t in n:
		var f := InputFrame.all_bots(units)
		for i: int in humans:
			if t % 12 == 0 or not held.has(i):
				held[i] = {
					"move": Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)),
					"aim": Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) if rng.randf() < 0.3 else Vector2.ZERO,
					"jump": rng.randf() < 0.3, "action": rng.randf() < 0.4, "beam": rng.randf() < 0.3,
				}
			InputFrame.put(f, i, held[i])
		out.append(f)
	return out


func _test_fmath() -> void:
	var worst := 0.0
	var x := -60.0
	while x < 60.0:
		worst = maxf(worst, absf(FMath.sin_d(x) - sin(x)))
		worst = maxf(worst, absf(FMath.cos_d(x) - cos(x)))
		x += 0.0137
	_check(worst < 1e-6, "sin_d/cos_d off by %s" % worst)
	var v := FMath.rotated(Vector2(3.0, -2.0), 0.7)
	_check(v.distance_to(Vector2(3.0, -2.0).rotated(0.7)) < 1e-5, "rotated() disagrees: %s" % v)


func _test_input_frame() -> void:
	var f := InputFrame.all_bots(4)
	_check(f.size() == 4 * InputFrame.UNIT_BYTES, "frame size")
	InputFrame.put(f, 2, {"move": Vector2(-1.0, 1.0), "aim": Vector2(0.5, -0.25), "jump": true, "beam": true})
	_check(InputFrame.is_bot(f, 1) and InputFrame.is_bot(f, 3), "untouched units stay bots")
	_check(not InputFrame.is_bot(f, 2), "a put unit is human")
	var u := E.Unit.new()
	InputFrame.apply(f, 2, u)
	_check(u.in_move == Vector2(-1.0, 1.0), "full deflection survives exactly: %s" % u.in_move)
	_check(absf(u.in_aim.x - 0.5) < 0.005 and absf(u.in_aim.y + 0.25) < 0.005, "aim within a step: %s" % u.in_aim)
	_check(u.in_jump and u.in_beam and not u.in_action, "buttons")
	# Packing an already-quantised value gives the same bytes back.
	var g := InputFrame.all_bots(4)
	InputFrame.put(g, 2, {"move": u.in_move, "aim": u.in_aim, "jump": true, "beam": true})
	_check(g == f, "re-packing is stable")


func _test_lockstep() -> void:
	for greys in [1, 3]:
		var a := _sim(77, greys)
		var b := _sim(77, greys)
		var frames := _frames(a.units.size(), [0, a.units.size() - 1], 3000, 5)
		var first_bad := -1
		for t in frames.size():
			a.step_frame(frames[t])
			b.step_frame(frames[t])
			if first_bad < 0 and a.checksum() != b.checksum():
				first_bad = t
		_check(first_bad < 0, "%dv%d: sims split at tick %d" % [greys + 1, greys + 1, first_bad])
		_check(a.save_state() == b.save_state(), "%dv%d: final states differ" % [greys + 1, greys + 1])
		var c := _sim(78, greys)
		for t in 600:
			c.step_frame(frames[t])
		var a600 := _sim(77, greys)
		for t in 600:
			a600.step_frame(frames[t])
		_check(c.checksum() != a600.checksum(), "checksum should tell different seeds apart")


func _test_snapshot() -> void:
	var a := _sim(9, 3)
	var frames := _frames(a.units.size(), [1, 4], 3000, 11)
	for t in 1500:
		a.step_frame(frames[t])
	var snap := a.save_state()
	var b := _sim(9, 3)
	b.load_state(snap)
	_check(b.save_state() == snap, "a loaded state should save back byte for byte")
	_check(b.tick == a.tick and b.cows.size() == a.cows.size(), "tick and cows restored")
	var first_bad := -1
	for t in range(1500, 3000):
		a.step_frame(frames[t])
		b.step_frame(frames[t])
		if first_bad < 0 and a.checksum() != b.checksum():
			first_bad = t
	_check(first_bad < 0, "restored sim split from the original at tick %d" % first_bad)
	# Loading over a live sim keeps the objects that survive.
	var keep: Array = a.cows.duplicate()
	var snap2 := a.save_state()
	for t in 120:
		a.step_frame(InputFrame.all_bots(a.units.size()))
	a.load_state(snap2)
	var same := 0
	for c in a.cows:
		if keep.has(c):
			same += 1
	_check(same == keep.size(), "cows should be the same objects after a rewind (%d of %d)" % [same, keep.size()])


func _test_rollback() -> void:
	# `truth` sees every frame on time. `peer` only learns each frame DELAY
	# ticks late: until then it guesses by repeating the last real frame, and
	# when a real frame arrives it rewinds to its last confirmed tick and
	# replays. This is the loop rollback netcode runs.
	const DELAY := 7
	var truth := _sim(21, 3)
	var peer := _sim(21, 3)
	var n := truth.units.size()
	var frames := _frames(n, [0, 3, 5], 2400, 3)
	var truth_sums: Array[int] = []
	for f in frames:
		truth.step_frame(f)
		truth_sums.append(truth.checksum())

	var confirmed := peer.save_state()
	var bad := -1
	var t0 := Time.get_ticks_usec()
	for t in range(DELAY, frames.size()):
		# Frame t - DELAY has just arrived.
		var known := t - DELAY + 1
		peer.load_state(confirmed)
		peer.step_frame(frames[known - 1])
		if bad < 0 and peer.checksum() != truth_sums[known - 1]:
			bad = known - 1
		confirmed = peer.save_state()
		for k in range(known, t + 1):
			peer.step_frame(frames[known - 1]) # guess
	var us := float(Time.get_ticks_usec() - t0) / (frames.size() - DELAY)
	_check(bad < 0, "confirmed state split from the truth at tick %d" % bad)
	_check(peer.tick == frames.size(), "peer should be predicting at the head (tick %d)" % peer.tick)
	print("      4v4, rewind + %d ticks of replay every tick: %.0f us per tick" % [DELAY, us])
