extends Node2D
## Game shell. Offline and online play run the same loop:
##  1. Every machine samples its local devices into one input packet per tick
##     and hands it to the host. Offline, this machine is the host.
##  2. The host applies seat changes and, once it has everyone's input for a
##     tick, packs it into a confirmed InputFrame and sends it to everyone.
##  3. Every machine runs its sim at the "present", ahead of the last
##     confirmed frame. For ticks not yet confirmed it predicts: its own input
##     is known, everyone else is assumed to still be doing what they last did.
##     When a confirmed frame disagrees with a prediction, it rewinds to the
##     saved state of that tick and replays up to the present (rollback).
## So all machines end up running the identical match, and nobody waits for
## the network unless the present gets MAX_AHEAD ticks past the confirmed
## frames. Offline, every frame is confirmed at once and nothing is predicted.
## Restarts, pause and the score are the host's call.
##
## Outside a match the game sits in the menus (menus.gd) with a bot match
## playing behind them. Online, the room waits in the lobby between matches:
## everyone names themselves and picks a team, the host picks the team size
## and starts, and when the match is decided everyone comes back.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const InputFrame = preload("res://scripts/sim/input_frame.gd")
const LocalInput = preload("res://scripts/input/local_input.gd")
const NetPeer = preload("res://scripts/net/net_peer.gd")
const RelayLink = preload("res://scripts/net/relay_link.gd")
const RP = preload("res://relay/relay_protocol.gd")
const ArenaView = preload("res://scripts/view/arena_view.gd")
const Hud = preload("res://scripts/view/hud.gd")
const Menus = preload("res://scripts/ui/menus.gd")
const Settings = preload("res://scripts/settings.gd")
const Updater = preload("res://scripts/update/updater.gd")

enum Role { OFFLINE, HOST, CLIENT }
const Msg = NetPeer.Msg

const LOCAL := NetPeer.HOST_ID # the host's own peer id, online or off
const ONLINE_DELAY := 2 # ticks (~33 ms) of input delay online; it makes rollbacks shallower
const MAX_AHEAD := 12 # ticks (200 ms) the present may run past the confirmed frames
const SUM_EVERY := 60 # clients report a checksum this often
const SYNC_EVERY := 30 # host tells clients how early their inputs arrive this often
const TARGET_LEAD := 1.0 # ticks early a client's input should reach the host
const WAIT_NOTICE := 30 # ticks stalled before the HUD says so
const PING_EVERY := 60 # clients time a round trip to the host this often
const BACK_TO_LOBBY := 600 # ticks after a match is won before everyone goes back on their own
const TEAM_SIZES := [1, 2, 3] # greys per team: 2v2, 3v3, 4v4

var sim: Sim # the match, or the bots playing behind the menus
var in_match := false
var humans: Dictionary = {} # host: "peer:device" -> {"team": int, "idx": int}; idx 0 is the Overlord
var greys_per_team := 1 # 1 = 2v2, 2 = 3v3, 3 = 4v4
var lobby: Array = [] # online: [{"id": peer id, "name": String, "team": int}], in join order
var in_lobby := false # online: the host has us in its room
var player_name := "" # what this machine's player is called online
var map_wins := [0, 0]
var match_winner := -1
var win_confirmed := false # sim.winner is set and every frame up to it is confirmed
var paused := false
var show_help := false # the controls overlay, toggled with F1
var updater: Updater

var role := Role.OFFLINE
var net: NetPeer # a RelayLink when going through the relay
var relay_address := "%s:%d" % [RP.HOST_NAME, RP.PORT] # --relay=HOST[:PORT] overrides it
var room_code := "" # the relay room we host or joined
var ping_ms := -1 # client: round trip to the host, relay included
var input_delay := 0
var fingerprint := 0 # proves to the host that we run the same sim; 0 until needed
var fake_lag_ms := 0 # testing aid: delay every packet we send (--lag=N)
var net_status := "" # one line for the HUD
var you := "" # this machine's players, e.g. "P2"
var notice := "" # a passing message for the HUD
var notice_t := 0.0
var waiting_t := 0 # ticks the present has been held up by the network
var rollbacks := 0 # times the present was rewound and replayed
var resyncs := 0 # host: clients put back in step after a checksum mismatch
var record_sums := false # tests: keep every final tick's checksum in sums_log
var sums_log := {} # "epoch:tick" -> checksum

var _epoch := 0
var _seed := 0
var _win_ticks := 0
var _next_sent := false
var _input = LocalInput.new() # untyped so tests can script it
var _view: ArenaView
var _hud: Hud
var _menu: Menus
var _host_port := NetPeer.PORT
var _join_addr := ""

# The timeline, on every machine. The present is sim.tick.
var _cframes := {} # tick -> confirmed frame
var _confirmed := 0 # frames for every tick before this are confirmed
var _verified := 0 # every tick before this was stepped with its confirmed frame, so the state here is final
var _used := {} # tick -> frame the present was stepped with
var _states := {} # tick -> sim state before stepping that tick, for ticks not yet verified
var _local := {} # tick -> this machine's input packet for it
var _next_input := 0 # next tick to sample local input for
var _last_cframe := PackedByteArray() # newest confirmed frame: the basis of predictions
var _my_seats: Array = [] # [unit id, device index] for players at this machine
var _shown: Array = [] # [tick, type, team, pos] effects already shown, so replays don't repeat them

# Host only
var _peers := {} # peer id -> {"greeted", "from" (first tick it owes input for), "inputs" {tick: packet}, "lead", "leads"}
var _prev_buttons := {} # "peer:device" -> button byte in the last frame
var _player_no := {} # "peer:device" -> n, shown as "Pn"
var _next_player := 1
var _sums := {} # tick -> checksum, to check clients against

# Client only
var _started := false
var _drift := 0 # ticks to gain (+) or lose (-) to keep our inputs arriving on time


func _ready() -> void:
	randomize()
	_view = ArenaView.new()
	add_child(_view)
	_hud = Hud.new()
	_hud.game = self
	add_child(_hud)
	updater = Updater.new()
	add_child(updater)
	updater.check()
	_menu = Menus.new()
	_menu.game = self
	add_child(_menu)
	Settings.apply_all()
	_peers[LOCAL] = _peer_state(true)
	player_name = Settings.player_name()
	_start_attract()
	_read_cmdline()


func _read_cmdline() -> void:
	var host_now := false
	for a: String in OS.get_cmdline_user_args():
		if a == "--host":
			host_now = true
		elif a.begins_with("--join="):
			_join_addr = a.trim_prefix("--join=")
		elif a.begins_with("--port="):
			_host_port = int(a.trim_prefix("--port="))
		elif a.begins_with("--lag="):
			fake_lag_ms = int(a.trim_prefix("--lag="))
		elif a.begins_with("--relay="):
			relay_address = a.trim_prefix("--relay=")
		elif a.begins_with("--local"):
			start_local(clampi(int(a.trim_prefix("--local=")), 1, 3) if a.contains("=") else 1)
	if host_now:
		host_lan(_host_port)
	elif _join_addr != "":
		join(_join_addr)


# --- Going online --------------------------------------------------------

## Host through the relay; a room code arrives shortly. Returns "" or what
## went wrong.
func host() -> String:
	if role != Role.OFFLINE:
		leave()
	_ensure_fingerprint()
	var link := RelayLink.new()
	link.lag_ms = fake_lag_ms
	var err := link.host_relay(_split_host(relay_address), _split_port(relay_address, RP.PORT))
	if err != OK:
		return "Couldn't reach the relay server (%s)." % error_string(err)
	net = link
	role = Role.HOST
	room_code = ""
	input_delay = ONLINE_DELAY
	_open_lobby()
	net_status = "Opening a room…"
	return ""


## Host directly on this machine (LAN, or a forwarded port). Returns "" or
## what went wrong.
func host_lan(port: int = NetPeer.PORT) -> String:
	if role != Role.OFFLINE:
		leave()
	_ensure_fingerprint()
	net = NetPeer.new()
	net.lag_ms = fake_lag_ms
	var err := net.host(port)
	if err != OK:
		net = null
		return "Couldn't host on port %d (%s)." % [port, error_string(err)]
	role = Role.HOST
	_host_port = port
	input_delay = ONLINE_DELAY
	_open_lobby()
	_say("Hosting. Friends join at %s" % _host_address())
	return ""


## Join by room code (through the relay), or by "address[:port]" for a
## direct host. Returns "" or what went wrong.
func join(where: String) -> String:
	if role != Role.OFFLINE:
		leave()
	where = where.strip_edges()
	if where == "":
		return "Type the room code first."
	_ensure_fingerprint()
	var code := RP.normalize_code(where)
	if code != "":
		var link := RelayLink.new()
		link.lag_ms = fake_lag_ms
		var err := link.join_relay(_split_host(relay_address), _split_port(relay_address, RP.PORT), code)
		if err != OK:
			return "Couldn't reach the relay server (%s)." % error_string(err)
		net = link
		room_code = code
	else:
		net = NetPeer.new()
		net.lag_ms = fake_lag_ms
		var err := net.join(_split_host(where), _split_port(where, NetPeer.PORT))
		if err != OK:
			net = null
			return "Couldn't start connecting (%s)." % error_string(err)
		room_code = ""
	role = Role.CLIENT
	_join_addr = where
	_started = false
	_end_local_match()
	_epoch = -1
	input_delay = ONLINE_DELAY
	paused = false
	ping_ms = -1
	net_status = "Joining %s…" % (room_code if room_code != "" else where)
	return ""


func _split_host(address: String) -> String:
	return address.get_slice(":", 0) if address.count(":") == 1 else address


func _split_port(address: String, fallback: int) -> int:
	return int(address.get_slice(":", 1)) if address.count(":") == 1 else fallback


## Leave the room (or close it, as host) and go back to the menus.
func leave() -> void:
	_go_offline("")


func _go_offline(reason: String) -> void:
	if net != null:
		net.close()
		net = null
	role = Role.OFFLINE
	input_delay = 0
	net_status = ""
	room_code = ""
	ping_ms = -1
	_started = false
	in_lobby = false
	lobby.clear()
	for id: int in _peers.keys():
		if id != LOCAL:
			_drop_peer(id)
	if reason != "":
		_say(reason)
	_stop_match()


## Host: a fresh room with just us in it, sitting in the lobby.
func _open_lobby() -> void:
	_end_local_match()
	in_lobby = true
	lobby = [{"id": LOCAL, "name": player_name, "team": 0}]


func _end_local_match() -> void:
	if in_match:
		_stop_match()


func _ensure_fingerprint() -> void:
	if fingerprint == 0:
		fingerprint = NetPeer.sim_fingerprint()


func _host_address() -> String:
	var lan := NetPeer.lan_addresses()
	var a: String = lan[0] if lan.size() > 0 else "this machine's address"
	return a if _host_port == NetPeer.PORT else "%s:%d" % [a, _host_port]


# --- Matches -------------------------------------------------------------

## Play on this machine against bots; with "extra_players" on, more local
## players join with Enter or Start.
func start_local(greys: int) -> void:
	if role != Role.OFFLINE:
		leave()
	greys_per_team = greys
	humans = {_key(LOCAL, "kb1"): {"team": 0, "idx": 0}}
	_start_match()


## Host: everyone in the lobby takes a seat on the team they picked.
func start_match() -> void:
	if role != Role.HOST or in_match:
		return
	humans.clear()
	for e: Dictionary in lobby:
		humans[_key(e["id"], "kb1")] = {"team": e["team"], "idx": 0}
	_start_match()
	_send_lobby()


func _start_match() -> void:
	in_match = true
	paused = false
	_prev_buttons.clear()
	_new_match()


## Host or offline: the match is over (or abandoned); back to the lobby or menu.
func end_match() -> void:
	if role == Role.CLIENT or not in_match:
		return
	_stop_match()
	_send_lobby()


func _stop_match() -> void:
	in_match = false
	paused = false
	humans.clear()
	map_wins = [0, 0]
	match_winner = -1
	_start_attract()


## Bots playing a 4v4 behind the menus. It never touches the network.
func _start_attract() -> void:
	if sim != null:
		sim.dispose()
	sim = Sim.new(randi(), 3)
	_view.sim = sim
	_view.labels = {}
	win_confirmed = false
	waiting_t = 0
	you = ""
	_shown.clear()


func _step_attract() -> void:
	if sim.winner >= 0:
		_start_attract()
	sim.step_frame(InputFrame.all_bots(sim.units.size()))
	if not sim.events.is_empty():
		_view.add_events(sim.events)


func _new_match() -> void:
	map_wins = [0, 0]
	match_winner = -1
	_new_map()


func _new_map() -> void:
	_epoch += 1
	_seed = randi()
	_begin(_seed, greys_per_team, PackedByteArray())
	for id: int in _peers:
		if id != LOCAL and _peers[id]["greeted"]:
			_send_start(id)


## Set up a map from its seed, or from the host's snapshot when joining late.
func _begin(p_seed: int, greys: int, snapshot: PackedByteArray) -> void:
	if sim != null:
		sim.dispose()
	greys_per_team = greys
	sim = Sim.new(p_seed, greys)
	if not snapshot.is_empty():
		sim.load_state(snapshot)
	_cframes.clear()
	_used.clear()
	_states.clear()
	_local.clear()
	_shown.clear()
	_confirmed = sim.tick
	_verified = sim.tick
	_next_input = sim.tick
	win_confirmed = false
	_win_ticks = 0
	_next_sent = false
	waiting_t = 0
	_drift = 0
	_view.sim = sim
	if role != Role.CLIENT:
		_sums.clear()
		for id: int in _peers:
			_peers[id]["inputs"].clear()
			_peers[id]["from"] = sim.tick
		# Re-seat humans; a smaller team may not have their old slot.
		var seats := humans.duplicate()
		humans.clear()
		for key: String in seats:
			_seat(key, seats[key]["team"], seats[key]["idx"])
		_refresh_labels()
	_last_cframe = _idle_frame()


## Host: send `peer` the match as it stands at the last final tick, plus the
## confirmed frames since, so it can join or get back in step.
func _send_start(peer: int) -> void:
	var state: PackedByteArray = _states[_verified] if _verified < sim.tick else sim.save_state()
	net.send(peer, [Msg.START, _epoch, _seed, greys_per_team, map_wins[0], map_wins[1], match_winner, state, paused])
	for t in range(_verified, _confirmed):
		net.send(peer, [Msg.FRAME, _epoch, t, _cframes[t]])


func _advance_map() -> void:
	if match_winner >= 0:
		end_match()
	else:
		_new_map()


# --- The tick ------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	_input.poll()
	notice_t = maxf(0.0, notice_t - Cfg.TICK)
	if net != null:
		_net_events()
	if not in_match:
		_step_attract()
		if role == Role.CLIENT and in_lobby and Engine.get_physics_frames() % PING_EVERY == 0:
			net.send(LOCAL, [Msg.PING, Time.get_ticks_msec()])
		if net != null:
			net.flush()
		_update_status()
		return
	if role != Role.CLIENT:
		_assemble()
	_reconcile()

	# Normally one tick per physics tick; a client that runs early or late
	# against the host drops or adds one every other tick until it's on time.
	var steps := 1
	if _drift != 0 and Engine.get_physics_frames() % 2 == 0:
		steps = 2 if _drift > 0 else 0
		_drift -= signi(_drift)
	var stalled := false
	for i in steps:
		if not _advance():
			stalled = sim.tick - _confirmed >= MAX_AHEAD
			break
	waiting_t = waiting_t + 1 if stalled and role != Role.OFFLINE else 0

	_check_win()
	if role == Role.HOST and Engine.get_physics_frames() % SYNC_EVERY == 0:
		_send_sync()
	if role == Role.CLIENT and _started and Engine.get_physics_frames() % PING_EVERY == 0:
		net.send(LOCAL, [Msg.PING, Time.get_ticks_msec()])
	if net != null:
		net.flush()
	_update_status()


## Move the present on one tick. Returns false if it can't right now.
func _advance() -> bool:
	if paused or (role == Role.OFFLINE and _menu.is_open()) or sim.winner >= 0:
		return false
	if role == Role.CLIENT and not _started:
		return false
	if sim.tick - _confirmed >= MAX_AHEAD:
		return false # too far past what's confirmed: wait for the network
	while _next_input <= sim.tick + input_delay:
		var packet := _local_packet()
		_local[_next_input] = packet
		if role == Role.CLIENT:
			net.send(LOCAL, [Msg.INPUT, _epoch, _next_input, packet])
		else:
			_peers[LOCAL]["inputs"][_next_input] = packet
		_next_input += 1
	if role != Role.CLIENT:
		_assemble()
		_reconcile()
		if sim.winner >= 0:
			return false
	var t := sim.tick
	var confirmed := _cframes.has(t)
	var f: PackedByteArray = _cframes[t] if confirmed else _predict(t)
	var final := confirmed and t == _verified
	if not final:
		_states[t] = sim.save_state()
	_used[t] = f
	sim.step_frame(f)
	_show_events(t, sim.events, false)
	if final:
		_verify_to(t + 1)
	return true


## Our best guess at tick t: everyone keeps doing what they last did, except
## the players at this machine, whose input we already have.
func _predict(t: int) -> PackedByteArray:
	var f := _last_cframe.duplicate()
	var packet = _local.get(t)
	if packet == null:
		return f
	for s: Array in _my_seats:
		var dst: int = s[0] * InputFrame.UNIT_BYTES
		var src: int = s[1] * InputFrame.UNIT_BYTES
		if dst + 4 >= f.size():
			continue
		for k in 4:
			f[dst + k] = packet[src + k]
		f[dst + 4] = packet[src + 4] & InputFrame.PLAY_BUTTONS
	return f


## Check the present against newly confirmed frames; rewind and replay from
## the first tick that was predicted wrong.
func _reconcile() -> void:
	var v := _verified
	var limit := mini(_confirmed, sim.tick)
	while v < limit and _used[v] == _cframes[v]:
		v += 1
	if v >= limit:
		if v > _verified:
			_verify_to(v)
		return
	rollbacks += 1
	var present := sim.tick
	sim.load_state(_states[v])
	for k in range(v, present):
		var f: PackedByteArray = _cframes[k] if _cframes.has(k) else _predict(k)
		_states[k] = sim.save_state()
		_used[k] = f
		sim.step_frame(f)
		_show_events(k, sim.events, true)
		if sim.winner >= 0:
			break # the replay ended the map sooner than the prediction did
	for k: int in _states.keys():
		if k >= sim.tick:
			_states.erase(k)
			_used.erase(k)
	_verify_to(mini(_confirmed, sim.tick))


## Ticks up to `v` are final: report their checksums and forget their history.
func _verify_to(v: int) -> void:
	for m in range(_verified + 1, v + 1):
		var report := m % SUM_EVERY == 0 and role != Role.OFFLINE
		if report or record_sums:
			var s := Sim.hash_state(_states[m]) if m < sim.tick else sim.checksum()
			if record_sums:
				sums_log["%d:%d" % [_epoch, m]] = s
			if report and role == Role.HOST:
				_sums[m] = s
				_sums.erase(m - SUM_EVERY * 20)
			elif report:
				net.send(LOCAL, [Msg.SUM, _epoch, m, s])
	for k in range(_verified, v):
		_states.erase(k)
		_used.erase(k)
		_cframes.erase(k)
		_local.erase(k)
	_verified = v


## Host: turn every tick that all players have sent input for into a
## confirmed frame.
func _assemble() -> void:
	var seats_changed := false
	while _all_inputs_in(_confirmed):
		var t := _confirmed
		var packets := {}
		for id: int in _peers:
			var p: Dictionary = _peers[id]
			if p["greeted"] and t >= p["from"]:
				packets[id] = p["inputs"][t]
				p["inputs"].erase(t)
		# Seat changes first, so a switch takes effect on this very tick.
		for id: int in packets:
			var packet: PackedByteArray = packets[id]
			for d in LocalInput.DEVICES.size():
				var key := _key(id, LocalInput.DEVICES[d])
				var b: int = packet[d * InputFrame.UNIT_BYTES + 4]
				var pressed: int = b & ~int(_prev_buttons.get(key, 0))
				_prev_buttons[key] = b
				if humans.has(key):
					if pressed & InputFrame.SWAP:
						_seat(key, humans[key]["team"], humans[key]["idx"] + 1)
						seats_changed = true
				elif pressed & InputFrame.JOIN:
					_join(key)
					seats_changed = true
		var frame := InputFrame.all_bots(sim.units.size())
		for key: String in humans:
			var id := int(key.get_slice(":", 0))
			var dst := _unit_of(key).id * InputFrame.UNIT_BYTES
			frame[dst + 4] = 0 # a human with no packet this tick stands still
			if not packets.has(id):
				continue
			var packet: PackedByteArray = packets[id]
			var src := LocalInput.DEVICES.find(key.get_slice(":", 1)) * InputFrame.UNIT_BYTES
			for k in 4:
				frame[dst + k] = packet[src + k]
			frame[dst + 4] = packet[src + 4] & InputFrame.PLAY_BUTTONS
		_confirm(t, frame)
		if net != null:
			net.send(0, [Msg.FRAME, _epoch, t, frame])
	if seats_changed:
		_refresh_labels()


func _all_inputs_in(t: int) -> bool:
	for id: int in _peers:
		var p: Dictionary = _peers[id]
		if p["greeted"] and t >= p["from"] and not p["inputs"].has(t):
			return false
	return true


func _confirm(t: int, frame: PackedByteArray) -> void:
	_cframes[t] = frame
	_confirmed = t + 1
	_last_cframe = frame


## A frame where the seated humans stand still and bots drive the rest.
func _idle_frame() -> PackedByteArray:
	var f := InputFrame.all_bots(sim.units.size())
	for id: int in _view.labels:
		if id < sim.units.size():
			f[id * InputFrame.UNIT_BYTES + 4] = 0
	return f


## Hand a tick's events to the view. A replayed tick skips the effects it
## already showed the first time round (give or take a few ticks and pixels).
func _show_events(t: int, events: Array, replay: bool) -> void:
	var fresh := []
	for ev: Dictionary in events:
		var seen := false
		if replay:
			for s: Array in _shown:
				if s[1] == ev["type"] and s[2] == ev.get("team", -1) and absi(s[0] - t) <= 4 \
						and s[3].distance_to(ev["pos"]) < 48.0:
					seen = true
					break
		if not seen:
			fresh.append(ev)
			_shown.append([t, ev["type"], ev.get("team", -1), ev["pos"]])
	if not fresh.is_empty():
		_view.add_events(fresh)
	while not _shown.is_empty() and _shown[0][0] < _verified - 10:
		_shown.pop_front()


func _check_win() -> void:
	if sim.winner < 0 or _verified < sim.tick:
		return
	if not win_confirmed:
		win_confirmed = true
		map_wins[sim.winner] += 1
		if map_wins[sim.winner] >= Cfg.MAPS_TO_WIN:
			match_winner = sim.winner
	_win_ticks += 1
	if match_winner >= 0 and _win_ticks > BACK_TO_LOBBY and role != Role.CLIENT:
		end_match()
		return
	# Ignore the first second so a held key can't skip the banner.
	if _win_ticks <= 60 or not _wants_next():
		return
	if role == Role.CLIENT:
		if not _next_sent:
			net.send(LOCAL, [Msg.NEXT, _epoch])
			_next_sent = true
	else:
		_advance_map()


func _local_packet() -> PackedByteArray:
	return LocalInput.blank_packet() if _menu.is_open() else _input.packet(not Settings.value("extra_players"))


func _wants_next() -> bool:
	if _menu.is_open():
		return false
	for device: String in LocalInput.DEVICES:
		if _input.pressed(device, "join") or _input.pressed(device, "jump"):
			return true
	return false


## Host: tell each client how many ticks early its inputs have been arriving.
func _send_sync() -> void:
	for id: int in _peers:
		var p: Dictionary = _peers[id]
		if id == LOCAL or not p["greeted"] or p["leads"] == 0:
			continue
		net.send(id, [Msg.SYNC, p["lead"] / p["leads"]])
		p["lead"] = 0.0
		p["leads"] = 0


# --- Network messages ----------------------------------------------------

func _net_events() -> void:
	for ev: Array in net.poll():
		match ev[0]:
			"join":
				if role == Role.HOST:
					_peers[ev[1]] = _peer_state(false)
			"leave":
				if role == Role.HOST and _peers.has(ev[1]):
					var had := _name_of(ev[1])
					var seated := _labels_of(ev[1]) != ""
					_drop_peer(ev[1])
					_refresh_labels()
					_send_lobby()
					if had != "":
						_say("%s left; a bot takes over." % had if seated else "%s left." % had)
			"room":
				room_code = ev[1]
				_say("Room %s is open. Friends pick Play online and type the code in." % room_code)
			"connected":
				net.send(LOCAL, [Msg.HELLO, NetPeer.PROTOCOL, updater.version, fingerprint, player_name])
				net_status = "Connected, waiting for the host…"
			"refused":
				_go_offline(ev[1])
			"failed":
				if net is RelayLink:
					_go_offline("Couldn't reach the relay server at %s." % relay_address)
				else:
					_go_offline("Couldn't reach a host at %s." % _join_addr)
			"closed":
				if role == Role.HOST:
					_go_offline("Lost the connection to the relay server.")
				else:
					_go_offline("The host closed the game." if in_lobby else "The host turned us away.")
			"msg":
				if role == Role.HOST:
					_host_msg(ev[1], ev[2])
				else:
					_client_msg(ev[2])
		if net == null:
			return


func _host_msg(id: int, m: Array) -> void:
	if not _peers.has(id):
		return
	var p: Dictionary = _peers[id]
	match m[0]:
		Msg.HELLO:
			if p["greeted"] or m.size() < 2 or not m[1] is int:
				return
			# Check the version before the shape, so an older build is told why.
			if m[1] != NetPeer.PROTOCOL or not NetPeer.valid(m, [TYPE_INT, TYPE_STRING, TYPE_INT, TYPE_STRING]) \
					or m[3] != fingerprint:
				var theirs: String = m[2] if m.size() > 2 and m[2] is String else "an older version"
				net.send(id, [Msg.REJECT, "The host runs %s and you run %s. Everyone needs the same version." % [updater.version, theirs]])
				return
			if lobby.size() >= room_size():
				net.send(id, [Msg.REJECT, "That room is full: %d of %d players for a %s." % [lobby.size(), room_size(), size_name(greys_per_team)]])
				return
			var name := Settings.clean_name(m[4])
			if name == "":
				name = "Player %d" % (lobby.size() + 1)
			var team := 0 if _team_count(0) <= _team_count(1) else 1
			lobby.append({"id": id, "name": name, "team": team})
			p["greeted"] = true
			p["from"] = _confirmed
			if in_match:
				# Mid-match: straight into a free seat on the smaller team.
				_send_start(id)
				_seat(_key(id, "kb1"), team, 0)
				_refresh_labels()
			_send_lobby()
			_say("%s joined." % name)
		Msg.TEAM:
			if p["greeted"] and NetPeer.valid(m, [TYPE_INT]):
				_set_team(id, m[1])
		Msg.NAME:
			if p["greeted"] and NetPeer.valid(m, [TYPE_STRING]):
				_rename(id, m[1])
		Msg.INPUT:
			if not in_match or not p["greeted"] or not NetPeer.valid(m, [TYPE_INT, TYPE_INT, TYPE_PACKED_BYTE_ARRAY]):
				return
			var t: int = m[2]
			if m[1] != _epoch or m[3].size() != LocalInput.PACKET_BYTES:
				return
			if t >= maxi(_confirmed, p["from"]) and t < _confirmed + 600 and not p["inputs"].has(t):
				p["inputs"][t] = m[3]
				p["lead"] += float(t - sim.tick)
				p["leads"] += 1
		Msg.NEXT:
			if in_match and p["greeted"] and NetPeer.valid(m, [TYPE_INT]) and m[1] == _epoch \
					and win_confirmed and _win_ticks > 60:
				_advance_map()
		Msg.PING:
			if p["greeted"] and NetPeer.valid(m, [TYPE_INT]):
				net.send(id, [Msg.PONG, m[1]])
		Msg.SUM:
			if not in_match or not p["greeted"] or not NetPeer.valid(m, [TYPE_INT, TYPE_INT, TYPE_INT]):
				return
			if m[1] == _epoch and _sums.has(m[2]) and _sums[m[2]] != m[3]:
				# Out of step: send the client the current state to carry on from.
				resyncs += 1
				push_warning("peer %d desynced at tick %d; resyncing" % [id, m[2]])
				_send_start(id)


func _client_msg(m: Array) -> void:
	match m[0]:
		Msg.REJECT:
			if NetPeer.valid(m, [TYPE_STRING]):
				_go_offline(m[1])
		Msg.START:
			if not NetPeer.valid(m, [TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT,
					TYPE_PACKED_BYTE_ARRAY, TYPE_BOOL]) or not m[3] in TEAM_SIZES:
				return
			var resync: bool = _started and m[1] == _epoch
			if not in_match:
				in_match = true
			_epoch = m[1]
			_seed = m[2]
			map_wins = [m[4], m[5]]
			match_winner = m[6]
			paused = m[8]
			_begin(m[2], m[3], m[7])
			if resync:
				_say("Back in step with the host.")
			_started = true
		Msg.FRAME:
			if NetPeer.valid(m, [TYPE_INT, TYPE_INT, TYPE_PACKED_BYTE_ARRAY]) and _started \
					and m[1] == _epoch and m[2] == _confirmed \
					and m[3].size() == sim.units.size() * InputFrame.UNIT_BYTES:
				_confirm(m[2], m[3])
		Msg.SEATS:
			# The host sends these just before START, so take them in the lobby too.
			if NetPeer.valid(m, [TYPE_ARRAY]):
				_apply_seats(m[1])
		Msg.LOBBY:
			if not NetPeer.valid(m, [TYPE_INT, TYPE_BOOL, TYPE_ARRAY]) or not m[1] in TEAM_SIZES:
				return
			var list := []
			for e in m[3]:
				if e is Array and e.size() == 3 and e[0] is int and e[1] is String and e[2] is int and e[2] in [0, 1]:
					list.append({"id": e[0], "name": e[1], "team": e[2]})
			lobby = list
			in_lobby = true
			if not in_match:
				greys_per_team = m[1]
			elif not m[2]:
				# The host ended the match: back to the lobby.
				_started = false
				_stop_match()
		Msg.PAUSE:
			if NetPeer.valid(m, [TYPE_BOOL]):
				paused = m[1]
		Msg.PONG:
			if NetPeer.valid(m, [TYPE_INT]):
				var rtt: int = Time.get_ticks_msec() - m[1]
				ping_ms = rtt if ping_ms < 0 else (ping_ms * 3 + rtt) / 4
		Msg.SYNC:
			if NetPeer.valid(m, [TYPE_FLOAT]) and _started:
				# Close half the gap each time, so the correction can't overshoot.
				_drift = clampi(roundi((TARGET_LEAD - m[1]) * 0.5), -15, 15)


func _peer_state(greeted: bool) -> Dictionary:
	return {"greeted": greeted, "from": _confirmed, "inputs": {}, "lead": 0.0, "leads": 0}


func _drop_peer(id: int) -> void:
	_peers.erase(id)
	for i in range(lobby.size() - 1, -1, -1):
		if lobby[i]["id"] == id:
			lobby.remove_at(i)
	var prefix := "%d:" % id
	for key: String in humans.keys():
		if key.begins_with(prefix):
			humans.erase(key)
	for key: String in _prev_buttons.keys():
		if key.begins_with(prefix):
			_prev_buttons.erase(key)


# --- Lobby ---------------------------------------------------------------

## Players a room holds at the current team size.
func room_size() -> int:
	return 2 * (1 + greys_per_team)


static func size_name(greys: int) -> String:
	return "%dv%d" % [greys + 1, greys + 1]


func team_count(team: int) -> int:
	return _team_count(team)


func _team_count(team: int) -> int:
	var n := 0
	for e: Dictionary in lobby:
		if e["team"] == team:
			n += 1
	return n


## This machine's peer id in the lobby.
func my_id() -> int:
	return net.id() if net != null else LOCAL


## Ask to play for `team`. The host has the last word, and a full team says no.
func pick_team(team: int) -> String:
	if not in_lobby or in_match:
		return ""
	if _team_count(team) >= 1 + greys_per_team:
		return "%s is full." % Cfg.TEAM_NAMES[team]
	if role == Role.CLIENT:
		net.send(LOCAL, [Msg.TEAM, team])
	else:
		_set_team(LOCAL, team)
	return ""


func _set_team(id: int, team: int) -> void:
	if in_match or not team in [0, 1] or _team_count(team) >= 1 + greys_per_team:
		return
	for e: Dictionary in lobby:
		if e["id"] == id and e["team"] != team:
			e["team"] = team
			_send_lobby()


## Host: change the team size (greys per team). Returns "" or why not.
func set_team_size(greys: int) -> String:
	if role == Role.CLIENT or in_match or not greys in TEAM_SIZES:
		return ""
	if lobby.size() > 2 * (1 + greys):
		return "%d players won't fit in a %s." % [lobby.size(), size_name(greys)]
	greys_per_team = greys
	# Anyone over the new size moves to the other team, newest first.
	for team in 2:
		for i in range(lobby.size() - 1, -1, -1):
			if _team_count(team) <= 1 + greys:
				break
			if lobby[i]["team"] == team:
				lobby[i]["team"] = 1 - team
	_send_lobby()
	return ""


## Set this player's name, for now and (if `save`) next time too.
func set_player_name(text: String, save := true) -> void:
	var name := Settings.clean_name(text)
	if save:
		Settings.set_value("name", name)
	player_name = name if name != "" else "Player"
	if role == Role.CLIENT:
		if in_lobby:
			net.send(LOCAL, [Msg.NAME, player_name])
	elif in_lobby:
		_rename(LOCAL, player_name)


func _rename(id: int, text: String) -> void:
	var name := Settings.clean_name(text)
	if name == "":
		return
	for e: Dictionary in lobby:
		if e["id"] == id and e["name"] != name:
			e["name"] = name
			_refresh_labels()
			_send_lobby()


func _name_of(id: int) -> String:
	for e: Dictionary in lobby:
		if e["id"] == id:
			return e["name"]
	return ""


func via_relay() -> bool:
	return net is RelayLink


func menu_open() -> bool:
	return _menu.is_open()


## Host: tell everyone who is in the room.
func _send_lobby() -> void:
	if role != Role.HOST or net == null:
		return
	var entries := []
	for e: Dictionary in lobby:
		entries.append([e["id"], e["name"], e["team"]])
	net.send(0, [Msg.LOBBY, greys_per_team, in_match, entries])


## Host or offline: pause or unpause the match for everyone.
func set_paused(on: bool) -> void:
	if role == Role.CLIENT or not in_match or paused == on:
		return
	paused = on
	if net != null:
		net.send(0, [Msg.PAUSE, paused])


# --- Seats (host and offline) -------------------------------------------

func _key(peer: int, device: String) -> String:
	return "%d:%s" % [peer, device]


func _unit_of(key: String) -> E.Unit:
	return sim.unit_at(humans[key]["team"], humans[key]["idx"])


func _join(key: String) -> void:
	var count := [0, 0]
	for k: String in humans:
		count[humans[k]["team"]] += 1
	_seat(key, 0 if count[0] < count[1] else 1, 0)


## Give `key` the first free unit on `team`, starting the search at `want`.
func _seat(key: String, team: int, want: int) -> void:
	var size := 1 + greys_per_team
	var taken := {}
	for k: String in humans:
		if k != key and humans[k]["team"] == team:
			taken[humans[k]["idx"]] = true
	for k in size:
		var idx := (want + k) % size
		if not taken.has(idx):
			humans[key] = {"team": team, "idx": idx}
			return
	humans.erase(key) # team is full of humans


## Label the seated players and tell everyone who is where. Online a
## player shows by name (a second player at the same machine as "Name 2");
## offline as P1, P2...
func _refresh_labels() -> void:
	if not in_match:
		return
	var entries := []
	var per_peer := {}
	for key: String in humans:
		if not _player_no.has(key):
			_player_no[key] = _next_player
			_next_player += 1
		var peer := int(key.get_slice(":", 0))
		var label := "P%d" % _player_no[key]
		if role != Role.OFFLINE:
			per_peer[peer] = per_peer.get(peer, 0) + 1
			label = _name_of(peer) if per_peer[peer] == 1 else "%s %d" % [_name_of(peer), per_peer[peer]]
		entries.append([_unit_of(key).id, label, peer, key.get_slice(":", 1)])
	_apply_seats(entries)
	if net != null:
		net.send(0, [Msg.SEATS, entries])


func _apply_seats(entries: Array) -> void:
	var labels := {}
	var mine := PackedStringArray()
	_my_seats.clear()
	var me := net.id() if net != null else LOCAL
	for e in entries:
		if not (e is Array and e.size() == 4 and e[0] is int and e[1] is String and e[2] is int and e[3] is String):
			continue
		labels[e[0]] = e[1]
		var device := LocalInput.DEVICES.find(e[3])
		if e[2] == me and device >= 0:
			mine.append(e[1])
			_my_seats.append([e[0], device])
	_view.labels = labels
	you = ", ".join(mine)


func _labels_of(peer: int) -> String:
	var out := PackedStringArray()
	for key: String in humans:
		if key.begins_with("%d:" % peer):
			out.append(_view.labels.get(_unit_of(key).id, "P%d" % _player_no.get(key, 0)))
	return ", ".join(out)


# --- HUD text and keys ---------------------------------------------------

func _say(text: String) -> void:
	notice = text
	notice_t = 5.0


func _update_status() -> void:
	match role:
		Role.OFFLINE:
			net_status = ""
		Role.HOST:
			var n := 0
			for id: int in _peers:
				if id != LOCAL and _peers[id]["greeted"]:
					n += 1
			if net is RelayLink:
				net_status = "Room %s  ·  %d joined" % [room_code, n] if room_code != "" else "Opening a room…"
			else:
				net_status = "Hosting at %s  ·  %d joined" % [_host_address(), n]
		Role.CLIENT:
			if in_lobby:
				var where := "Room %s" % room_code if room_code != "" else "Online"
				net_status = "%s  ·  %s" % [where, "%d ms" % ping_ms if ping_ms >= 0 else "…"]


## Esc (the in-game menu) is handled by the menus.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_F1:
			if in_match:
				show_help = not show_help
		KEY_F3:
			if not in_match:
				return
			if role != Role.OFFLINE:
				_say("Spectating is for local games.")
				return
			var k1 := _key(LOCAL, "kb1")
			if humans.has(k1):
				humans.erase(k1)
			else:
				_seat(k1, 0, 0)
			_refresh_labels()
		KEY_F5:
			updater.install()


func _exit_tree() -> void:
	if net != null:
		net.close()
	if sim != null:
		sim.dispose()
