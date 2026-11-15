extends RefCounted
## Bot brain for one unit. Reads the sim and writes the unit's in_* fields,
## exactly like a human controller would.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const MapData = preload("res://scripts/sim/map_data.gd")
const FMath = preload("res://scripts/sim/fmath.gd")

# Radians either way; bots shouldn't be snipers, least of all against saucers.
const AIM_ERROR := 0.2
const AIM_ERROR_VS_OVERLORD := 0.45

var sim # Sim; untyped to avoid a preload cycle
var u: E.Unit
var rng := RandomNumberGenerator.new()

# Grey workers
var plan := "" # econ | tractor | warrior | speed
var plan_t := 0.0
var air_x := 0.0

# Overlords
var task := "" # hunt | claim | haul | idle
var task_t := 0.0
var task_unit = null
var task_cow = null
var task_station := -1
var via_station := -1
var trigger_t := 0.0 # pause between pot-shots at the rival saucer


func _init(p_sim, p_unit: E.Unit, p_seed: int) -> void:
	sim = p_sim
	u = p_unit
	rng.seed = p_seed
	air_x = u.pos.x


func think() -> void:
	u.in_move = Vector2.ZERO
	u.in_aim = Vector2.ZERO
	u.in_jump = false
	u.in_action = false
	u.in_beam = false
	if not u.alive:
		plan = ""
		task = ""
		return
	if u.kind == E.Kind.OVERLORD:
		_overlord()
	elif u.held_by != null:
		pass
	elif u.warrior:
		_warrior()
	else:
		_worker()


# --- Greys ---------------------------------------------------------------

func _worker() -> void:
	plan_t -= Cfg.TICK
	if plan == "" or plan_t <= 0.0:
		_choose_plan()
	if u.riding:
		return
	var tr: E.Tractor = sim.tractor
	if plan == "tractor":
		if tr.rider != null:
			plan = "econ" if tr.rider.team == u.team else "warrior"
		else:
			if _goto(tr.pos, 18.0):
				u.in_action = not u.prev_action
			return
	if u.carrying != null:
		var dest: Vector2 = sim.map.silo_point[u.team]
		if plan == "warrior":
			var s := _nearest_station()
			if s >= 0:
				dest = sim.map.stations[s]
		elif plan == "speed" and not u.speedy:
			dest = sim.map.wormholes[u.team]
		_goto(dest, 6.0)
		return
	var cow = _nearest_cow()
	if cow != null:
		_goto(cow.pos, 2.0)
	else:
		_goto(Vector2(Cfg.W / 2.0 - 90.0 * sim.tractor_dir(1 - u.team), Cfg.GROUND_Y - u.half.y), 20.0)


func _choose_plan() -> void:
	var tr: E.Tractor = sim.tractor
	var w := {"econ": 5.0, "tractor": 3.0, "warrior": 2.0, "speed": 0.0 if u.speedy else 0.7}
	if tr.rider != null:
		w["tractor"] = 0.0
		if tr.rider.team != u.team:
			w["warrior"] += 6.0
	# Pull the tractor back if the other side has made ground with it.
	var enemy_gain: float = (tr.pos.x - sim.map.tractor_start.x) * sim.tractor_dir(1 - u.team)
	if enemy_gain > 60.0:
		w["tractor"] *= 2.5
	for mate: E.Unit in sim.units:
		if mate.team == u.team and mate != u and mate.warrior:
			w["warrior"] *= 0.4
	if _nearest_station() < 0:
		w["warrior"] = 0.0
	var total := 0.0
	for k in w:
		total += w[k]
	var roll := rng.randf() * total
	for k in w:
		roll -= w[k]
		if roll <= 0.0:
			plan = k
			break
	plan_t = rng.randf_range(8.0, 14.0)


func _warrior() -> void:
	var t = _pick_enemy()
	if t == null:
		_goto(Vector2(Cfg.W / 2.0, Cfg.GROUND_Y - u.half.y), 40.0)
		return
	var d: Vector2 = t.pos - u.pos
	var dist := d.length()
	if dist < Cfg.BOLT_RANGE * 0.85:
		u.in_aim = _aim_at(t)
		u.in_action = true
	if dist > 150.0 or absf(d.y) > 60.0:
		_goto(t.pos, 100.0)
	# Hop and hover at things overhead.
	if u.grounded and d.y < -40.0 and d.y > -200.0 and absf(d.x) < 140.0:
		u.in_jump = not u.prev_jump
	elif not u.grounded and d.y < -30.0 and u.vel.y > -100.0:
		u.in_jump = true


func _pick_enemy():
	var best = null
	var best_score := INF
	for e: E.Unit in sim.units:
		if e.team == u.team or not e.alive:
			continue
		var score := u.pos.distance_to(e.pos)
		if e.riding:
			score -= 500.0
		if e.carrying != null:
			score -= 150.0
		if e.kind == E.Kind.OVERLORD:
			score += 120.0
		if score < best_score:
			best_score = score
			best = e
	return best


func _nearest_cow():
	var best = null
	var best_d := INF
	for c: E.Cow in sim.cows:
		if c.state != E.CowState.LOOSE:
			continue
		var d := u.pos.distance_to(c.pos)
		if d < best_d:
			best_d = d
			best = c
	return best


func _nearest_station() -> int:
	var best := -1
	var best_d := INF
	for i in sim.map.stations.size():
		var owner: int = sim.station_owner[i]
		if owner != -1 and owner != u.team:
			continue
		var d := u.pos.distance_to(sim.map.stations[i])
		if d < best_d:
			best_d = d
			best = i
	return best


## Walk, jump and drop across the platform graph towards `target`.
## Returns true once standing within `tol` px of it on the right platform.
func _goto(target: Vector2, tol: float) -> bool:
	var m: MapData = sim.map
	if not u.grounded:
		var dx := air_x - u.pos.x
		u.in_move.x = signf(dx) if absf(dx) > 3.0 else 0.0
		return false
	if u.on_plat < 0: # standing on a saucer wreck
		u.in_move.x = signf(target.x - u.pos.x)
		u.in_jump = not u.prev_jump
		air_x = target.x
		return false
	var tp := m.plat_under(target)
	if u.on_plat == tp:
		var dx := target.x - u.pos.x
		air_x = target.x
		if absf(dx) <= tol:
			return true
		u.in_move.x = signf(dx)
		return false
	var e: MapData.Edge = m.edge(u.on_plat, tp)
	if e == null:
		return false
	var tx := e.nearest(u.pos.x)
	air_x = tx
	if absf(tx - u.pos.x) > 6.0:
		u.in_move.x = signf(tx - u.pos.x)
		return false
	match e.kind:
		MapData.UP:
			u.in_jump = not u.prev_jump
		MapData.DOWN:
			u.in_move.y = 1.0
			u.in_jump = not u.prev_jump
		MapData.GAP:
			u.in_move.x = e.dir
			u.in_jump = not u.prev_jump
			air_x = e.land_x
	return false


# --- Overlords -----------------------------------------------------------

func _overlord() -> void:
	task_t -= Cfg.TICK
	var rider = sim.tractor.rider
	if rider != null and rider.team != u.team:
		# Nothing matters more than knocking the enemy off the tractor.
		task = "hunt"
		task_unit = rider
		task_t = 2.0
	elif task == "" or task_t <= 0.0 or not _task_ok():
		_pick_task()

	var move := Vector2.ZERO
	match task:
		"hunt":
			var side := signf(u.pos.x - task_unit.pos.x)
			if side == 0.0:
				side = 1.0
			move = _fly(task_unit.pos + Vector2(140.0 * side, -110.0))
		"claim":
			move = _fly(sim.map.stations[task_station])
		"haul":
			move = _haul()
		_:
			move = _fly(sim.map.overlord_spawn[u.team] + Vector2(0.0, 60.0))

	# Keep away from anything armed that we aren't hunting, and climb: warriors
	# can only hover briefly. A saucer with a cow in its beam is slow, so let go.
	var threatened := false
	for e: E.Unit in sim.units:
		if e.team == u.team or not e.alive or e == task_unit:
			continue
		if not e.warrior and e.kind != E.Kind.OVERLORD:
			continue
		var away: Vector2 = u.pos - e.pos
		if away.length() < 320.0:
			threatened = true
			move += (away.normalized() + Vector2(0.0, -0.4)) * 4.0 * (1.0 - away.length() / 320.0)
			if away.length() < 230.0:
				u.in_beam = false
	# Weave, so a hovering saucer isn't a sitting duck.
	if task == "hunt" or (threatened and u.fire_cd > 0.0):
		move += Vector2(0.35 * FMath.cos_d(sim.time * 3.1 + u.id), 0.7 * FMath.sin_d(sim.time * 4.3 + u.id * 2.0))
	u.in_move = move.limit_length(1.0)

	trigger_t -= Cfg.TICK
	if not u.in_beam:
		var t = _shot_target()
		if t != null and (t.kind != E.Kind.OVERLORD or trigger_t <= 0.0):
			u.in_aim = _aim_at(t)
			u.in_action = true
			if t.kind == E.Kind.OVERLORD and u.fire_cd <= 0.0:
				trigger_t = rng.randf_range(0.9, 1.8)


func _haul() -> Vector2:
	var t = u.beam_target
	if t == null:
		u.in_beam = absf(task_cow.pos.x - u.pos.x) < 30.0 and task_cow.pos.y > u.pos.y \
				and task_cow.pos.y - u.pos.y < Cfg.BEAM_RANGE
		return _fly(task_cow.pos + Vector2(0.0, -70.0))
	if not (t is E.Cow):
		return Vector2.ZERO # picked up a teammate by accident: let go
	u.in_beam = true
	var hang := Vector2(0.0, Cfg.BEAM_HANG)
	if via_station >= 0 and not t.probed and sim.station_owner[via_station] in [-1, u.team]:
		return _fly(sim.map.stations[via_station] - hang)
	var zone: Rect2 = sim.map.silo_zone[u.team]
	return _fly(zone.get_center() - hang)


func _task_ok() -> bool:
	match task:
		"hunt":
			return task_unit != null and task_unit.alive
		"claim":
			return sim.station_owner[task_station] != u.team
		"haul":
			if u.beam_target != null:
				return true
			return task_cow != null and task_cow.state == E.CowState.LOOSE and sim.cows.has(task_cow)
	return false


func _pick_task() -> void:
	task_unit = null
	task_cow = null
	var options: Array = [["idle", 0.5, null]]
	for e: E.Unit in sim.units:
		if e.team == u.team or not e.alive or e.shield_t > 0.0:
			continue
		if e.kind == E.Kind.OVERLORD:
			options.append(["hunt", 0.25, e])
		elif e.warrior:
			options.append(["hunt", 3.0, e])
		elif e.carrying != null:
			options.append(["hunt", 2.0, e])
	var st := -1
	var st_d := INF
	var rival: E.Unit = sim.overlord(1 - u.team)
	for i in sim.map.stations.size():
		var d := u.pos.distance_to(sim.map.stations[i])
		if rival.alive and rival.pos.distance_to(sim.map.stations[i]) < 280.0:
			continue # not worth a duel
		if sim.station_owner[i] != u.team and d < st_d:
			st_d = d
			st = i
	if st >= 0:
		options.append(["claim", 1.5, st])
	var cow = null
	var cow_d := INF
	for c: E.Cow in sim.cows:
		if c.state == E.CowState.LOOSE and u.pos.distance_to(c.pos) < cow_d:
			cow_d = u.pos.distance_to(c.pos)
			cow = c
	if cow != null:
		options.append(["haul", 4.0, cow])

	var total := 0.0
	for o in options:
		total += o[1]
	var roll := rng.randf() * total
	var pick: Array = options[0]
	for o in options:
		roll -= o[1]
		if roll <= 0.0:
			pick = o
			break
	task = pick[0]
	match task:
		"hunt":
			task_unit = pick[2]
			# Saucer duels are short raids, not fights to the death.
			task_t = 3.0 if task_unit.kind == E.Kind.OVERLORD else 6.0
		"claim":
			task_station = pick[2]
			task_t = 6.0
		"haul":
			task_cow = pick[2]
			task_t = 16.0
			# Half the time, run the cow through a Probe Station first for double value.
			via_station = -1
			if rng.randf() < 0.5:
				via_station = _nearest_station()
		_:
			task_t = 1.5


func _shot_target():
	var best = null
	var best_d := Cfg.BOLT_RANGE * 0.85
	for e: E.Unit in sim.units:
		if e.team == u.team or not e.alive or e.shield_t > 0.0:
			continue
		var d := u.pos.distance_to(e.pos)
		if e == task_unit:
			d -= 80.0
		elif e.kind == E.Kind.OVERLORD and d > 150.0:
			continue # only trade shots with her when duelling or cornered
		if d < best_d:
			best_d = d
			best = e
	return best


func _aim_at(t: E.Unit) -> Vector2:
	var err := AIM_ERROR_VS_OVERLORD if t.kind == E.Kind.OVERLORD else AIM_ERROR
	return FMath.rotated((t.pos - u.pos).normalized(), rng.randf_range(-err, err))


func _fly(dest: Vector2) -> Vector2:
	var d := dest - u.pos
	if d.length() < 6.0:
		return Vector2.ZERO
	return d.limit_length(60.0) / 60.0
