extends RefCounted
## Deterministic match simulation. No nodes, no rendering, no wall clock.
## Feed it one InputFrame per fixed tick with step_frame(); units marked BOT in
## the frame are driven by the sim's own bots. Tests can instead write units'
## in_* fields and call step() directly.
##
## For netcode: two sims built with the same seed and fed the same frames stay
## identical on every machine, save_state() / load_state() rewind one, and
## checksum() says cheaply whether two of them still agree.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const MapData = preload("res://scripts/sim/map_data.gd")
const Bot = preload("res://scripts/sim/bot.gd")
const InputFrame = preload("res://scripts/sim/input_frame.gd")

const STATE_VERSION := 1

enum Win { NONE, MILITARY, ECONOMIC, TRACTOR }
const WIN_NAMES := ["", "Military", "Economic", "Tractor"]

var map: MapData
var rng := RandomNumberGenerator.new()
var greys_per_team := 1
var units: Array = [] # E.Unit, ordered team 0 [Overlord, greys...], then team 1
var cows: Array = [] # E.Cow
var bolts: Array = [] # E.Bolt
var wrecks: Array = [] # E.Wreck
var tractor: E.Tractor
var bots: Array = [] # Bot, one per unit, same order as units
var station_owner: Array[int] = [] # -1 neutral, else team
var silo: Array[int] = [0, 0]
var tick := 0
var time := 0.0
var winner := -1
var win_reason := Win.NONE
var events: Array[Dictionary] = [] # what happened this tick, for the view
var _cow_t := Cfg.COW_SPAWN_EVERY
var _next_id := 0 # every unit, cow, bolt and wreck gets a unique id


func _init(p_seed: int = 1, p_greys: int = 1) -> void:
	rng.seed = p_seed
	greys_per_team = p_greys
	map = MapData.new()
	for i in map.stations.size():
		station_owner.append(-1)
	for team in 2:
		_add_unit(team, E.Kind.OVERLORD, 0)
		for i in greys_per_team:
			_add_unit(team, E.Kind.GREY, i)
	tractor = E.Tractor.new()
	tractor.pos = map.tractor_start
	for u: E.Unit in units:
		# Bot seeds come from the match seed, so every peer's bots agree.
		bots.append(Bot.new(self, u, p_seed * 1000003 + u.id * 7919 + 17))
	for i in Cfg.COW_START:
		_spawn_cow()


## Break reference cycles so a finished match can be freed.
func dispose() -> void:
	for u: E.Unit in units:
		u.beam_target = null
		u.carrying = null
		u.held_by = null
	for c: E.Cow in cows:
		c.holder = null
	for w: E.Wreck in wrecks:
		w.owner = null
	tractor.rider = null
	for b: Bot in bots:
		b.sim = null
		b.task_unit = null
		b.task_cow = null
	bots.clear()


## idx 0 is the team's Overlord, 1.. are its greys.
func unit_at(team: int, idx: int) -> E.Unit:
	return units[team * (1 + greys_per_team) + idx]


func overlord(team: int) -> E.Unit:
	return unit_at(team, 0)


func spawn_point(u: E.Unit) -> Vector2:
	if u.kind == E.Kind.OVERLORD:
		return map.overlord_spawn[u.team]
	return map.grey_spawn(u.team, u.slot)


func tractor_dir(team: int) -> float:
	return -1.0 if team == 0 else 1.0


## Advance one tick from an InputFrame: humans' inputs are applied, bots think.
func step_frame(frame: PackedByteArray) -> void:
	if winner >= 0:
		events.clear()
		return
	assert(frame.size() == units.size() * InputFrame.UNIT_BYTES, "frame is the wrong size")
	for i in units.size():
		if InputFrame.is_bot(frame, i):
			bots[i].think()
		else:
			InputFrame.apply(frame, i, units[i])
	step()


## Advance one tick with whatever is already in the units' in_* fields.
func step() -> void:
	events.clear()
	if winner >= 0:
		return
	var dt := Cfg.TICK
	tick += 1
	time += dt
	_spawn_cows(dt)
	for u: E.Unit in units:
		_step_unit(u, dt)
	_step_beams(dt)
	_step_tractor(dt)
	_step_cows(dt)
	_step_gates(dt)
	_step_bolts(dt)
	_step_wrecks(dt)
	for u: E.Unit in units:
		u.prev_jump = u.in_jump
		u.prev_action = u.in_action


# --- Units ---------------------------------------------------------------

func _add_unit(team: int, kind: int, slot: int) -> void:
	var u := E.Unit.new()
	u.id = _new_id()
	u.team = team
	u.kind = kind
	u.slot = slot
	u.half = Cfg.OV_HALF if kind == E.Kind.OVERLORD else Cfg.GREY_HALF
	u.lives = Cfg.OVERLORD_LIVES
	u.hp = Cfg.OV_HP
	u.facing = tractor_dir(1 - team)
	u.pos = spawn_point(u)
	units.append(u)


func _step_unit(u: E.Unit, dt: float) -> void:
	u.fire_cd = maxf(0.0, u.fire_cd - dt)
	u.shield_t = maxf(0.0, u.shield_t - dt)
	u.pickup_cd = maxf(0.0, u.pickup_cd - dt)
	if not u.alive:
		u.respawn_t -= dt
		if u.respawn_t <= 0.0:
			_respawn(u)
		return
	if u.kind == E.Kind.OVERLORD:
		_step_overlord(u, dt)
	else:
		_step_grey(u, dt)
	_try_fire(u)


func _step_overlord(u: E.Unit, dt: float) -> void:
	var speed := Cfg.OV_SPEED
	if u.in_beam:
		speed *= Cfg.BEAM_SLOW
	var mv := u.in_move.limit_length(1.0)
	u.vel = u.vel.move_toward(mv * speed, Cfg.OV_ACCEL * dt)
	u.pos += u.vel * dt
	var lo := Vector2(u.half.x, Cfg.CEIL_Y + u.half.y)
	var hi := Vector2(Cfg.W - u.half.x, Cfg.GROUND_Y - u.half.y - 2.0)
	if u.pos.x < lo.x or u.pos.x > hi.x:
		u.vel.x = 0.0
	if u.pos.y < lo.y or u.pos.y > hi.y:
		u.vel.y = 0.0
	u.pos = u.pos.clamp(lo, hi)
	if absf(mv.x) > 0.2:
		u.facing = signf(mv.x)
	# The Overlord claims a Probe Station by touching it.
	for i in map.stations.size():
		if station_owner[i] != u.team and u.pos.distance_to(map.stations[i]) < Cfg.GATE_RADIUS + 14.0:
			station_owner[i] = u.team
			events.append({"type": "claim", "pos": map.stations[i], "team": u.team})


func _step_grey(u: E.Unit, dt: float) -> void:
	if u.held_by != null:
		return # the beam moves it
	var jump_pressed := u.in_jump and not u.prev_jump
	var action_pressed := u.in_action and not u.prev_action

	if u.riding:
		u.pos = tractor.pos + Vector2(0.0, -(Cfg.TRACTOR_HALF.y + u.half.y) + 6.0)
		u.vel = Vector2.ZERO
		u.facing = tractor_dir(u.team)
		if action_pressed or jump_pressed:
			u.riding = false
			tractor.rider = null
			u.vel.y = -Cfg.GREY_JUMP * 0.6
		return

	if action_pressed and not u.warrior:
		if tractor.rider == null and _overlap(u.pos, u.half, tractor.pos, Cfg.TRACTOR_HALF):
			_drop_cow(u)
			u.riding = true
			u.grounded = false
			u.on_plat = -1
			tractor.rider = u
			return
		_drop_cow(u)

	var speed := Cfg.GREY_RUN
	if u.speedy:
		speed *= Cfg.SPEED_BOOST
	if u.carrying != null:
		speed *= Cfg.PROBED_SLOW if u.carrying.probed else Cfg.CARRY_SLOW
	var mx := clampf(u.in_move.x, -1.0, 1.0)
	u.vel.x = move_toward(u.vel.x, mx * speed, Cfg.GREY_ACCEL * dt)
	if absf(mx) > 0.2:
		u.facing = signf(mx)

	u.drop_t = maxf(0.0, u.drop_t - dt)
	if u.grounded:
		u.hover_fuel = Cfg.HOVER_TIME
		if jump_pressed:
			if u.in_move.y > 0.5 and u.on_plat > 0:
				u.drop_t = 0.15 # fall through the one-way platform
			else:
				u.vel.y = -Cfg.GREY_JUMP
	elif u.warrior and u.in_jump and u.hover_fuel > 0.0 and u.vel.y >= -Cfg.HOVER_RISE - 1.0:
		u.hover_fuel -= dt
		u.vel.y = move_toward(u.vel.y, -Cfg.HOVER_RISE - Cfg.GRAVITY * dt, 6000.0 * dt)
	_fall_and_land(u, dt, true)


func _try_fire(u: E.Unit) -> void:
	if not u.in_action or u.fire_cd > 0.0:
		return
	if u.kind == E.Kind.GREY and (not u.warrior or u.riding or u.held_by != null):
		return
	if u.kind == E.Kind.OVERLORD and u.in_beam:
		return
	var dir := Vector2(u.facing, 0.0)
	if u.in_aim.length() > 0.3:
		dir = u.in_aim.normalized()
	elif u.in_move.length() > 0.5:
		dir = u.in_move.normalized()
	var b := E.Bolt.new()
	b.id = _new_id()
	b.pos = u.pos + dir * 14.0
	b.vel = dir * Cfg.BOLT_SPEED
	b.team = u.team
	b.from_kind = u.kind
	b.life = Cfg.BOLT_RANGE / Cfg.BOLT_SPEED
	bolts.append(b)
	u.fire_cd = Cfg.OV_FIRE_CD if u.kind == E.Kind.OVERLORD else Cfg.FIRE_CD
	if absf(dir.x) > 0.2:
		u.facing = signf(dir.x)


## A bolt landed. Greys go down in one; a saucer takes Cfg.OV_HP.
func hit(u: E.Unit, by: String = "") -> void:
	if u.kind == E.Kind.OVERLORD:
		u.hp -= 1
		if u.hp > 0:
			events.append({"type": "hit", "pos": u.pos, "team": u.team, "id": u.id, "hp": u.hp, "by": by})
			return
	kill(u, by)


## `by` says what did it: "overlord", "warrior" or "tractor".
func kill(u: E.Unit, by: String = "") -> void:
	if not u.alive:
		return
	u.alive = false
	u.vel = Vector2.ZERO
	events.append({"type": "kill", "pos": u.pos, "team": u.team, "kind": u.kind, "by": by})
	if u.kind == E.Kind.GREY:
		_drop_cow(u)
		if u.riding:
			u.riding = false
			tractor.rider = null
		if u.held_by != null:
			u.held_by.beam_target = null
			u.held_by = null
		u.warrior = false
		u.gate_t = 0.0
		u.respawn_t = Cfg.GREY_RESPAWN
	else:
		_release_beam(u)
		u.lives -= 1
		# The downed saucer stays on the map as a platform until she respawns.
		var w := E.Wreck.new()
		w.id = _new_id()
		w.pos = u.pos
		w.half = Cfg.WRECK_HALF
		w.owner = u
		wrecks.append(w)
		u.respawn_t = Cfg.OV_RESPAWN
		if u.lives <= 0:
			_win(1 - u.team, Win.MILITARY)


func _respawn(u: E.Unit) -> void:
	for w: E.Wreck in wrecks.duplicate():
		if w.owner == u:
			w.owner = null
			wrecks.erase(w)
	u.pos = spawn_point(u)
	u.vel = Vector2.ZERO
	u.alive = true
	u.hp = Cfg.OV_HP
	u.grounded = false
	u.on_plat = -1
	u.shield_t = Cfg.OV_SHIELD_TIME if u.kind == E.Kind.OVERLORD else Cfg.SHIELD_TIME
	u.facing = tractor_dir(1 - u.team)


func _win(team: int, reason: int) -> void:
	if winner >= 0:
		return
	winner = team
	win_reason = reason
	events.append({"type": "win", "team": team, "pos": Vector2(Cfg.W / 2.0, Cfg.H / 2.0)})


# --- Tractor beam --------------------------------------------------------

func _step_beams(dt: float) -> void:
	for u: E.Unit in units:
		if u.kind != E.Kind.OVERLORD or not u.alive:
			continue
		if not u.in_beam:
			_release_beam(u)
			continue
		if u.beam_target == null:
			_grab_beam_target(u)
		var t = u.beam_target
		if t == null:
			continue
		var hang := u.pos + Vector2(0.0, Cfg.BEAM_HANG)
		hang.y = minf(hang.y, Cfg.GROUND_Y - t.half.y)
		t.pos = t.pos.move_toward(hang, Cfg.BEAM_LIFT * dt)
		t.vel = Vector2.ZERO
		if not (t is E.Cow):
			continue
		var cow: E.Cow = t
		if not cow.probed:
			for i in map.stations.size():
				var usable := station_owner[i] == -1 or station_owner[i] == u.team
				if usable and cow.pos.distance_to(map.stations[i]) <= Cfg.GATE_RADIUS:
					cow.probed = true
					events.append({"type": "probed", "pos": cow.pos, "team": u.team})
		if map.silo_zone[u.team].has_point(cow.pos):
			_deposit(cow, u.team)


func _grab_beam_target(u: E.Unit) -> void:
	var best = null
	var best_d := INF
	for c: E.Cow in cows:
		if c.state == E.CowState.LOOSE and _in_beam(u, c.pos, c.half) and u.pos.distance_to(c.pos) < best_d:
			best_d = u.pos.distance_to(c.pos)
			best = c
	if best != null:
		best.state = E.CowState.BEAMED
		best.holder = u
		u.beam_target = best
		return
	for g: E.Unit in units:
		if g.team != u.team or g.kind != E.Kind.GREY or not g.alive or g.riding or g.held_by != null:
			continue
		if _in_beam(u, g.pos, g.half) and u.pos.distance_to(g.pos) < best_d:
			best_d = u.pos.distance_to(g.pos)
			best = g
	if best != null:
		best.held_by = u
		best.grounded = false
		best.on_plat = -1
		u.beam_target = best


func _in_beam(u: E.Unit, p: Vector2, half: Vector2) -> bool:
	var dy := p.y - u.pos.y
	return absf(p.x - u.pos.x) <= Cfg.BEAM_HALF_W + half.x and dy > 0.0 and dy <= Cfg.BEAM_RANGE


func _release_beam(u: E.Unit) -> void:
	var t = u.beam_target
	if t == null:
		return
	u.beam_target = null
	t.vel = u.vel * 0.6
	if t is E.Cow:
		t.state = E.CowState.LOOSE
		t.holder = null
	else:
		t.held_by = null


# --- Tractor -------------------------------------------------------------

func _step_tractor(dt: float) -> void:
	var r = tractor.rider
	if r == null:
		tractor.dir = 0.0
		return
	var dir := tractor_dir(r.team)
	tractor.dir = dir
	tractor.pos.x += dir * Cfg.TRACTOR_SPEED * dt
	# Flatten enemy greys standing in front of it.
	var front := tractor.pos.x + dir * Cfg.TRACTOR_HALF.x
	for u: E.Unit in units:
		if u.team == r.team or u.kind != E.Kind.GREY or not u.alive or u.shield_t > 0.0 or u.held_by != null:
			continue
		if u.pos.y + u.half.y >= Cfg.GROUND_Y - 8.0 and absf(u.pos.x - front) <= u.half.x + 6.0:
			kill(u, "tractor")
	if (dir < 0.0 and tractor.pos.x <= map.crop_x[0]) or (dir > 0.0 and tractor.pos.x >= map.crop_x[1]):
		_win(r.team, Win.TRACTOR)


# --- Cows ----------------------------------------------------------------

func _spawn_cows(dt: float) -> void:
	_cow_t -= dt
	if _cow_t > 0.0:
		return
	_cow_t = Cfg.COW_SPAWN_EVERY
	var grazing := 0
	for c: E.Cow in cows:
		if c.state == E.CowState.LOOSE and c.on_plat == 0 and c.pos.x >= map.pasture.x and c.pos.x <= map.pasture.y:
			grazing += 1
	if grazing < Cfg.COW_MAX_PASTURE and cows.size() < Cfg.COW_MAX_TOTAL:
		_spawn_cow()


func _spawn_cow() -> E.Cow:
	var c := E.Cow.new()
	c.id = _new_id()
	c.half = Cfg.COW_HALF
	c.pos = Vector2(rng.randf_range(map.pasture.x + 20.0, map.pasture.y - 20.0), Cfg.GROUND_Y - c.half.y)
	cows.append(c)
	return c


func _step_cows(dt: float) -> void:
	for c: E.Cow in cows.duplicate():
		match c.state:
			E.CowState.LOOSE:
				_step_loose_cow(c, dt)
			E.CowState.CARRIED:
				var h: E.Unit = c.holder
				c.pos = h.pos + Vector2(0.0, -(h.half.y + c.half.y - 2.0))
				c.vel = Vector2.ZERO
				if map.silo_zone[h.team].has_point(h.pos):
					_deposit(c, h.team)
			E.CowState.BEAMED:
				# Cow heist: an enemy grey can grab a cow out of the beam.
				var o: E.Unit = c.holder
				for u: E.Unit in units:
					if u.team != o.team and _can_carry(u) and _overlap(u.pos, u.half, c.pos, c.half):
						o.beam_target = null
						_give_cow(c, u)
						events.append({"type": "heist", "pos": c.pos, "team": u.team})
						break


func _step_loose_cow(c: E.Cow, dt: float) -> void:
	var in_pasture := c.on_plat == 0 and c.pos.x >= map.pasture.x and c.pos.x <= map.pasture.y
	if c.grounded and in_pasture:
		c.wander_t -= dt
		if c.wander_t <= 0.0:
			c.wander_t = rng.randf_range(1.0, 3.0)
			c.vel.x = Cfg.COW_WANDER * float(rng.randi_range(-1, 1))
		if c.pos.x < map.pasture.x + 20.0:
			c.vel.x = Cfg.COW_WANDER
		elif c.pos.x > map.pasture.y - 20.0:
			c.vel.x = -Cfg.COW_WANDER
	elif c.grounded:
		c.vel.x = move_toward(c.vel.x, 0.0, 900.0 * dt)
	_fall_and_land(c, dt, false)
	# A loose cow that ends up in a silo is banked for whoever owns the silo.
	for team in 2:
		if map.silo_zone[team].has_point(c.pos):
			_deposit(c, team)
			return
	for u: E.Unit in units:
		if _can_carry(u) and _overlap(u.pos, u.half, c.pos, c.half):
			_give_cow(c, u)
			return


func _can_carry(u: E.Unit) -> bool:
	return u.alive and u.kind == E.Kind.GREY and not u.warrior and u.carrying == null \
			and not u.riding and u.held_by == null and u.pickup_cd <= 0.0


func _give_cow(c: E.Cow, u: E.Unit) -> void:
	c.state = E.CowState.CARRIED
	c.holder = u
	u.carrying = c


func _drop_cow(u: E.Unit) -> void:
	var c = u.carrying
	if c == null:
		return
	u.carrying = null
	u.pickup_cd = Cfg.PICKUP_CD
	c.state = E.CowState.LOOSE
	c.holder = null
	c.vel = Vector2(u.vel.x * 0.5, -180.0)
	c.grounded = false
	c.on_plat = -1


func _remove_cow(c: E.Cow) -> void:
	var h = c.holder
	if h != null:
		if c.state == E.CowState.CARRIED:
			h.carrying = null
		else:
			h.beam_target = null
	c.holder = null
	cows.erase(c)


func _deposit(c: E.Cow, team: int) -> void:
	var value := Cfg.PROBED_VALUE if c.probed else 1
	silo[team] += value
	events.append({"type": "deposit", "pos": c.pos, "team": team, "value": value})
	_remove_cow(c)
	if silo[team] >= Cfg.SILO_GOAL:
		_win(team, Win.ECONOMIC)


# --- Gates ---------------------------------------------------------------

func _step_gates(dt: float) -> void:
	for u: E.Unit in units:
		if u.kind != E.Kind.GREY:
			continue
		if not u.alive or u.carrying == null or not u.grounded:
			u.gate_t = 0.0
			continue
		var station := -1
		for i in map.stations.size():
			var usable := station_owner[i] == -1 or station_owner[i] == u.team
			if usable and u.pos.distance_to(map.stations[i]) <= Cfg.GATE_RADIUS + 6.0:
				station = i
		var wormhole := false
		if not u.speedy:
			for wh in map.wormholes:
				if u.pos.distance_to(wh) <= Cfg.GATE_RADIUS + 6.0:
					wormhole = true
		if station < 0 and not wormhole:
			u.gate_t = 0.0
			continue
		u.gate_t += dt
		if u.gate_t < Cfg.GATE_DWELL:
			continue
		u.gate_t = 0.0
		_remove_cow(u.carrying)
		if station >= 0:
			u.warrior = true
			u.hover_fuel = 0.0
			events.append({"type": "warrior", "pos": u.pos, "team": u.team})
		else:
			u.speedy = true
			events.append({"type": "speed", "pos": u.pos, "team": u.team})


# --- Bolts and wrecks ----------------------------------------------------

func _step_bolts(dt: float) -> void:
	for b: E.Bolt in bolts.duplicate():
		b.pos += b.vel * dt
		b.life -= dt
		if b.life <= 0.0 or b.pos.y >= Cfg.GROUND_Y or b.pos.x < 0.0 or b.pos.x > Cfg.W:
			bolts.erase(b)
			continue
		for u: E.Unit in units:
			if not u.alive or u.team == b.team or u.shield_t > 0.0:
				continue
			if absf(b.pos.x - u.pos.x) <= u.half.x + 3.0 and absf(b.pos.y - u.pos.y) <= u.half.y + 3.0:
				hit(u, "overlord" if b.from_kind == E.Kind.OVERLORD else "warrior")
				bolts.erase(b)
				break


func _step_wrecks(dt: float) -> void:
	for w: E.Wreck in wrecks:
		if not w.grounded:
			_fall_and_land(w, dt, false)


# --- Shared physics ------------------------------------------------------

## Gravity, horizontal move, and landing on platforms and wrecks. Works on
## anything with pos / vel / half / grounded / on_plat.
func _fall_and_land(o, dt: float, can_drop: bool) -> void:
	o.vel.y = minf(o.vel.y + Cfg.GRAVITY * dt, Cfg.MAX_FALL)
	o.pos.x = clampf(o.pos.x + o.vel.x * dt, o.half.x, Cfg.W - o.half.x)
	var prev_bottom: float = o.pos.y + o.half.y
	o.pos.y += o.vel.y * dt
	if o.pos.y - o.half.y < Cfg.CEIL_Y:
		o.pos.y = Cfg.CEIL_Y + o.half.y
		o.vel.y = maxf(o.vel.y, 0.0)
	o.grounded = false
	o.on_plat = -1
	if o.vel.y < 0.0:
		return
	var bottom: float = o.pos.y + o.half.y
	var reach: float = o.half.x - 3.0
	var dropping: bool = can_drop and o.drop_t > 0.0
	var best_y := INF
	var best_i := -1
	for i in map.platforms.size():
		var p := map.platforms[i]
		if i > 0 and dropping:
			continue
		if o.pos.x < p.x0 - reach or o.pos.x > p.x1 + reach:
			continue
		if prev_bottom <= p.y + 0.01 and bottom >= p.y and p.y < best_y:
			best_y = p.y
			best_i = i
	for w: E.Wreck in wrecks:
		if w == o:
			continue
		var top := w.pos.y - w.half.y
		if absf(o.pos.x - w.pos.x) > w.half.x + reach:
			continue
		if prev_bottom <= top + 0.01 and bottom >= top and top < best_y:
			best_y = top
			best_i = -1
	if best_y < INF:
		o.pos.y = best_y - o.half.y
		o.vel.y = 0.0
		o.grounded = true
		o.on_plat = best_i


func _overlap(ap: Vector2, ah: Vector2, bp: Vector2, bh: Vector2) -> bool:
	return absf(ap.x - bp.x) <= ah.x + bh.x and absf(ap.y - bp.y) <= ah.y + bh.y


func _new_id() -> int:
	_next_id += 1
	return _next_id - 1


# --- Snapshots -----------------------------------------------------------
# Everything that changes during a match, bots included, as plain values.
# Links between objects are stored as ids. Loading reuses the objects that
# already exist with the same id, so the view's per-object animation survives
# a rollback.

func save_state() -> PackedByteArray:
	var live := {}
	for list: Array in [units, cows, bolts, wrecks]:
		for o in list:
			live[o.id] = o
	var us := []
	for u: E.Unit in units:
		us.append([u.pos, u.vel, u.facing, u.alive, u.respawn_t, u.shield_t, u.fire_cd,
				u.grounded, u.on_plat, u.lives, u.hp, _ref(live, u.beam_target),
				u.warrior, u.speedy, u.hover_fuel, _ref(live, u.carrying), u.riding,
				_ref(live, u.held_by), u.drop_t, u.pickup_cd, u.gate_t,
				u.in_move, u.in_aim, u.in_jump, u.in_action, u.in_beam,
				u.prev_jump, u.prev_action])
	var cs := []
	for c: E.Cow in cows:
		cs.append([c.id, c.pos, c.vel, c.state, _ref(live, c.holder), c.probed,
				c.grounded, c.on_plat, c.wander_t])
	var bs := []
	for b: E.Bolt in bolts:
		bs.append([b.id, b.pos, b.vel, b.team, b.from_kind, b.life])
	var ws := []
	for w: E.Wreck in wrecks:
		ws.append([w.id, w.pos, w.vel, w.grounded, w.on_plat, _ref(live, w.owner)])
	var bots_s := []
	for b: Bot in bots:
		bots_s.append([b.plan, b.plan_t, b.air_x, b.task, b.task_t,
				_ref(live, b.task_unit), _ref(live, b.task_cow), b.task_station,
				b.via_station, b.trigger_t, b.rng.state])
	return var_to_bytes([STATE_VERSION, greys_per_team, tick, time, winner, win_reason,
			_cow_t, _next_id, rng.state, silo.duplicate(), station_owner.duplicate(),
			[tractor.pos, tractor.dir, _ref(live, tractor.rider)],
			us, cs, bs, ws, bots_s])


## Rewind to a state from save_state() of a sim with the same team size.
func load_state(bytes: PackedByteArray) -> void:
	var s: Array = bytes_to_var(bytes)
	assert(s[0] == STATE_VERSION, "snapshot is from another version")
	assert(s[1] == greys_per_team, "snapshot is for another team size")
	tick = s[2]
	time = s[3]
	winner = s[4]
	win_reason = s[5]
	_cow_t = s[6]
	_next_id = s[7]
	rng.state = s[8]
	silo.assign(s[9])
	station_owner.assign(s[10])
	events.clear()

	# Pass 1: make sure every object exists and set its plain fields.
	var live := {}
	for u: E.Unit in units:
		live[u.id] = u
	var old := {}
	for list: Array in [cows, bolts, wrecks]:
		for o in list:
			old[o.id] = o
	cows = _restore(s[13], old, live, E.Cow)
	bolts = _restore(s[14], old, live, E.Bolt)
	wrecks = _restore(s[15], old, live, E.Wreck)
	for id in old:
		if not live.has(id):
			_unlink(old[id]) # gone in the restored state

	# Pass 2: plain fields that need nothing else, then the links.
	var us: Array = s[12]
	for i in units.size():
		var u: E.Unit = units[i]
		var a: Array = us[i]
		u.pos = a[0]; u.vel = a[1]; u.facing = a[2]; u.alive = a[3]
		u.respawn_t = a[4]; u.shield_t = a[5]; u.fire_cd = a[6]; u.grounded = a[7]
		u.on_plat = a[8]; u.lives = a[9]; u.hp = a[10]; u.beam_target = live.get(a[11])
		u.warrior = a[12]; u.speedy = a[13]; u.hover_fuel = a[14]
		u.carrying = live.get(a[15]); u.riding = a[16]; u.held_by = live.get(a[17])
		u.drop_t = a[18]; u.pickup_cd = a[19]; u.gate_t = a[20]
		u.in_move = a[21]; u.in_aim = a[22]; u.in_jump = a[23]; u.in_action = a[24]
		u.in_beam = a[25]; u.prev_jump = a[26]; u.prev_action = a[27]
	for i in cows.size():
		cows[i].holder = live.get(s[13][i][4])
	for i in wrecks.size():
		wrecks[i].owner = live.get(s[15][i][5])
	var tr: Array = s[11]
	tractor.pos = tr[0]
	tractor.dir = tr[1]
	tractor.rider = live.get(tr[2])
	var bots_s: Array = s[16]
	for i in bots.size():
		var b: Bot = bots[i]
		var a: Array = bots_s[i]
		b.plan = a[0]; b.plan_t = a[1]; b.air_x = a[2]; b.task = a[3]; b.task_t = a[4]
		b.task_unit = live.get(a[5]); b.task_cow = live.get(a[6]); b.task_station = a[7]
		b.via_station = a[8]; b.trigger_t = a[9]; b.rng.state = a[10]


## A 32-bit fingerprint of the whole state. Peers compare these to catch a
## desync on the tick it happens.
func checksum() -> int:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(save_state())
	return h.finish().decode_u32(0)


func _ref(live: Dictionary, o) -> int:
	# A link to something no longer in the match (a bot remembering a cow that
	# was banked) saves as none; the bot treats both the same.
	return o.id if o != null and live.get(o.id) == o else -1


func _restore(rows: Array, old: Dictionary, live: Dictionary, cls) -> Array:
	var out := []
	for a: Array in rows:
		var o = old.get(a[0])
		if o == null:
			o = cls.new()
			o.id = a[0]
		live[o.id] = o
		out.append(o)
		if cls == E.Cow:
			o.half = Cfg.COW_HALF
			o.pos = a[1]; o.vel = a[2]; o.state = a[3]; o.probed = a[5]
			o.grounded = a[6]; o.on_plat = a[7]; o.wander_t = a[8]
		elif cls == E.Bolt:
			o.pos = a[1]; o.vel = a[2]; o.team = a[3]; o.from_kind = a[4]; o.life = a[5]
		else:
			o.half = Cfg.WRECK_HALF
			o.pos = a[1]; o.vel = a[2]; o.grounded = a[3]; o.on_plat = a[4]
	return out


func _unlink(o) -> void:
	if o is E.Cow:
		o.holder = null
	elif o is E.Wreck:
		o.owner = null
