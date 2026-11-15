extends Node2D
## Game shell: owns the simulation, feeds it human and bot inputs once per
## physics tick, and keeps the best-of-three score.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const Bot = preload("res://scripts/sim/bot.gd")
const LocalInput = preload("res://scripts/input/local_input.gd")
const ArenaView = preload("res://scripts/view/arena_view.gd")
const Hud = preload("res://scripts/view/hud.gd")

var sim: Sim
var bots: Dictionary = {} # unit id -> Bot
var humans: Dictionary = {} # device -> {"team": int, "idx": int}; idx 0 is the Overlord
var greys_per_team := 1 # 1 = the 2v2 prototype, 3 = full 4v4
var map_wins := [0, 0]
var match_winner := -1
var paused := false
var show_help := true

var _win_ticks := 0
var _help_ticks := 480 # the controls overlay hides itself after 8 s
var _input := LocalInput.new()
var _view: ArenaView
var _hud: Hud


func _ready() -> void:
	randomize()
	_view = ArenaView.new()
	add_child(_view)
	_hud = Hud.new()
	_hud.game = self
	add_child(_hud)
	humans["kb1"] = {"team": 0, "idx": 0}
	_new_map()


func _new_match() -> void:
	map_wins = [0, 0]
	match_winner = -1
	_new_map()


func _new_map() -> void:
	if sim != null:
		sim.dispose()
	sim = Sim.new(randi(), greys_per_team)
	_win_ticks = 0
	bots.clear()
	for u: E.Unit in sim.units:
		bots[u.id] = Bot.new(sim, u, randi())
	# Re-seat humans; a smaller team may not have their old slot.
	var seats := humans.duplicate()
	humans.clear()
	for device: String in seats:
		_seat(device, seats[device]["team"], seats[device]["idx"])
	_view.sim = sim
	_refresh_labels()


func _physics_process(_delta: float) -> void:
	_input.poll()
	if _help_ticks > 0:
		_help_ticks -= 1
		if _help_ticks == 0:
			show_help = false
	if sim.winner >= 0:
		_win_ticks += 1
		for device: String in LocalInput.DEVICES:
			# Ignore the first second so a held key can't skip the banner.
			if _win_ticks > 60 and (_input.pressed(device, "join") or _input.pressed(device, "jump")):
				if match_winner >= 0:
					_new_match()
				else:
					_new_map()
				return
		return
	for device: String in LocalInput.DEVICES:
		if humans.has(device):
			if _input.pressed(device, "swap"):
				_seat(device, humans[device]["team"], humans[device]["idx"] + 1)
				_refresh_labels()
		elif device != "kb1" and _input.pressed(device, "join"):
			_join(device)
	if paused:
		return

	var driven := {}
	for device: String in humans:
		var u := _unit_of(device)
		var s := _input.state(device)
		u.in_move = s["move"]
		u.in_aim = s["aim"]
		u.in_jump = s["jump"]
		u.in_action = s["action"]
		u.in_beam = s["beam"]
		driven[u.id] = true
	for u: E.Unit in sim.units:
		if not driven.has(u.id):
			bots[u.id].think()
	sim.step()
	_view.add_events(sim.events)

	if sim.winner >= 0:
		map_wins[sim.winner] += 1
		if map_wins[sim.winner] >= Cfg.MAPS_TO_WIN:
			match_winner = sim.winner


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_F1:
			show_help = not show_help
			_help_ticks = 0
		KEY_F2:
			greys_per_team = 3 if greys_per_team == 1 else 1
			_new_match()
		KEY_F3:
			if humans.has("kb1"):
				humans.erase("kb1")
			else:
				_seat("kb1", 0, 0)
			_refresh_labels()
		KEY_R:
			_new_match()
		KEY_ESCAPE:
			paused = not paused


func _unit_of(device: String) -> E.Unit:
	return sim.unit_at(humans[device]["team"], humans[device]["idx"])


func _join(device: String) -> void:
	var count := [0, 0]
	for d: String in humans:
		count[humans[d]["team"]] += 1
	_seat(device, 0 if count[0] < count[1] else 1, 0)
	_refresh_labels()


## Give `device` the first free unit on `team`, starting the search at `want`.
func _seat(device: String, team: int, want: int) -> void:
	var size := 1 + greys_per_team
	var taken := {}
	for d: String in humans:
		if d != device and humans[d]["team"] == team:
			taken[humans[d]["idx"]] = true
	for k in size:
		var idx := (want + k) % size
		if not taken.has(idx):
			humans[device] = {"team": team, "idx": idx}
			return
	humans.erase(device) # team is full of humans


func _refresh_labels() -> void:
	var labels := {}
	for device: String in humans:
		labels[_unit_of(device).id] = _input.label(device)
	_view.labels = labels


func _exit_tree() -> void:
	if sim != null:
		sim.dispose()
