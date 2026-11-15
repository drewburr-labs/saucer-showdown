extends Node2D
## Game shell. Offline and online play run the same loop:
##  1. Every machine samples its local devices into one input packet per tick
##     and hands it to the host. Offline, this machine is the host.
##  2. The host applies seat changes, packs everyone's input into one
##     InputFrame per tick (bots drive the empty seats) and sends it out.
##  3. Every machine steps its sim only on those frames, so they all run the
##     identical match. Restarts, pause and the score are the host's call.
## Input is sampled `input_delay` ticks ahead of the sim: 1 offline, which is
## no delay at all, and ONLINE_DELAY online, to cover the round trip.

const Cfg = preload("res://scripts/sim/config.gd")
const E = preload("res://scripts/sim/entities.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const InputFrame = preload("res://scripts/sim/input_frame.gd")
const LocalInput = preload("res://scripts/input/local_input.gd")
const NetPeer = preload("res://scripts/net/net_peer.gd")
const ArenaView = preload("res://scripts/view/arena_view.gd")
const Hud = preload("res://scripts/view/hud.gd")
const OnlineMenu = preload("res://scripts/view/online_menu.gd")
const Updater = preload("res://scripts/update/updater.gd")

enum Role { OFFLINE, HOST, CLIENT }
const Msg = NetPeer.Msg

const LOCAL := NetPeer.HOST_ID # the host's own peer id, online or off
const ONLINE_DELAY := 4 # ticks (~67 ms) between sampling input and simulating it
const SUM_EVERY := 60 # clients report a checksum this often
const MAX_CATCHUP := 4 # frames a client may step in one physics tick
const WAIT_NOTICE := 30 # ticks stalled before the HUD says so

var sim: Sim
var humans: Dictionary = {} # host: "peer:device" -> {"team": int, "idx": int}; idx 0 is the Overlord
var greys_per_team := 1 # 1 = the 2v2 prototype, 3 = full 4v4
var map_wins := [0, 0]
var match_winner := -1
var paused := false
var show_help := true
var updater: Updater

var role := Role.OFFLINE
var net: NetPeer
var input_delay := 1
var fingerprint := 0 # proves to the host that we run the same sim; 0 until needed
var net_status := "" # one line for the HUD
var you := "" # this machine's players, e.g. "P2"
var notice := "" # a passing message for the HUD
var notice_t := 0.0
var waiting_t := 0 # ticks the sim has been held up waiting for a frame
var resyncs := 0 # host: clients put back in step after a checksum mismatch
var record_sums := false # tests: keep every tick's checksum in sums_log
var sums_log := {} # "epoch:tick" -> checksum

var _epoch := 0
var _seed := 0
var _frames := {} # tick -> InputFrame waiting to be stepped
var _next_input := 0 # next tick to sample local input for
var _win_ticks := 0
var _next_sent := false
var _help_ticks := 480 # the controls overlay hides itself after 8 s
var _input = LocalInput.new() # untyped so tests can script it
var _view: ArenaView
var _hud: Hud
var _menu: OnlineMenu
var _host_port := NetPeer.PORT
var _join_addr := ""

# Host only
var _peers := {} # peer id -> {"greeted": bool, "from": first tick it owes input for, "inputs": {tick: packet}}
var _next_frame := 0
var _prev_buttons := {} # "peer:device" -> button byte in the last frame
var _player_no := {} # "peer:device" -> n, shown as "Pn"
var _next_player := 1
var _sums := {} # tick -> checksum, to check clients against

# Client only
var _started := false


func _ready() -> void:
	randomize()
	_view = ArenaView.new()
	add_child(_view)
	_hud = Hud.new()
	_hud.game = self
	add_child(_hud)
	_menu = OnlineMenu.new()
	_menu.game = self
	add_child(_menu)
	updater = Updater.new()
	add_child(updater)
	updater.check()
	_peers[LOCAL] = _peer_state(true)
	humans[_key(LOCAL, "kb1")] = {"team": 0, "idx": 0}
	_new_map()
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
	if host_now:
		host(_host_port)
	elif _join_addr != "":
		join(_join_addr)


# --- Going online --------------------------------------------------------

## Start hosting. Returns "" or what went wrong.
func host(port: int = NetPeer.PORT) -> String:
	if role != Role.OFFLINE:
		leave()
	_ensure_fingerprint()
	net = NetPeer.new()
	var err := net.host(port)
	if err != OK:
		net = null
		return "Couldn't host on port %d (%s)." % [port, error_string(err)]
	role = Role.HOST
	_host_port = port
	input_delay = ONLINE_DELAY
	_refresh_labels()
	_say("Hosting. Friends join at %s" % _host_address())
	return ""


## Join a host at "address" or "address:port". Returns "" or what went wrong.
func join(address: String) -> String:
	if role != Role.OFFLINE:
		leave()
	var port := NetPeer.PORT
	var host_name := address.strip_edges()
	if host_name.count(":") == 1:
		port = int(host_name.get_slice(":", 1))
		host_name = host_name.get_slice(":", 0)
	if host_name == "":
		return "Type the host's address first."
	_ensure_fingerprint()
	net = NetPeer.new()
	var err := net.join(host_name, port)
	if err != OK:
		net = null
		return "Couldn't start connecting (%s)." % error_string(err)
	role = Role.CLIENT
	_join_addr = address
	_started = false
	_epoch = -1
	input_delay = ONLINE_DELAY
	paused = false
	net_status = "Connecting to %s…" % address
	return ""


func leave() -> void:
	_go_offline("")


func _go_offline(reason: String) -> void:
	if net != null:
		net.close()
		net = null
	var was_client := role == Role.CLIENT
	role = Role.OFFLINE
	input_delay = 1
	net_status = ""
	_started = false
	for id: int in _peers.keys():
		if id != LOCAL:
			_drop_peer(id)
	if reason != "":
		_say(reason)
	if was_client:
		# The host's match leaves with the host: start a fresh local one.
		paused = false
		humans = {_key(LOCAL, "kb1"): {"team": 0, "idx": 0}}
		_new_match()
	else:
		_refresh_labels()


func _ensure_fingerprint() -> void:
	if fingerprint == 0:
		fingerprint = NetPeer.sim_fingerprint()


func _host_address() -> String:
	var lan := NetPeer.lan_addresses()
	var a: String = lan[0] if lan.size() > 0 else "this machine's address"
	return a if _host_port == NetPeer.PORT else "%s:%d" % [a, _host_port]


# --- Matches (host and offline) -----------------------------------------

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
			net.send(id, _start_msg(false))


## Set up a map from its seed, or from a host's snapshot when joining late.
func _begin(p_seed: int, greys: int, snapshot: PackedByteArray) -> void:
	if sim != null:
		sim.dispose()
	greys_per_team = greys
	sim = Sim.new(p_seed, greys)
	if not snapshot.is_empty():
		sim.load_state(snapshot)
	_frames.clear()
	_next_input = sim.tick
	_win_ticks = 0
	_next_sent = false
	waiting_t = 0
	_view.sim = sim
	if role == Role.CLIENT:
		return
	_next_frame = sim.tick
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


func _advance() -> void:
	if match_winner >= 0:
		_new_match()
	else:
		_new_map()


func _start_msg(with_state: bool) -> Array:
	return [Msg.START, _epoch, _seed, greys_per_team, map_wins[0], map_wins[1], match_winner,
			sim.save_state() if with_state else PackedByteArray(), paused]


# --- The tick ------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	_input.poll()
	if _help_ticks > 0:
		_help_ticks -= 1
		if _help_ticks == 0:
			show_help = false
	notice_t = maxf(0.0, notice_t - Cfg.TICK)
	if net != null:
		_net_events()
	if role == Role.CLIENT:
		_client_tick()
	else:
		_host_tick()
	_step_frames()
	if net != null:
		net.flush()
	_update_status()


func _host_tick() -> void:
	if sim.winner >= 0:
		_win_ticks += 1
		# Ignore the first second so a held key can't skip the banner.
		if _win_ticks > 60 and _wants_next():
			_advance()
		return
	if paused or (role == Role.OFFLINE and _menu.is_open()):
		return
	if _next_input < _next_frame + input_delay:
		_peers[LOCAL]["inputs"][_next_input] = _local_packet()
		_next_input += 1
	_assemble()


func _client_tick() -> void:
	if not _started:
		return
	if sim.winner >= 0:
		_win_ticks += 1
		if _win_ticks > 60 and not _next_sent and _wants_next():
			net.send(LOCAL, [Msg.NEXT, _epoch])
			_next_sent = true
		return
	if _next_input < sim.tick + input_delay:
		net.send(LOCAL, [Msg.INPUT, _epoch, _next_input, _local_packet()])
		_next_input += 1


## Host: turn every tick that all players have sent input for into a frame.
func _assemble() -> void:
	var seats_changed := false
	while _all_inputs_in(_next_frame):
		var t := _next_frame
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
		_frames[t] = frame
		if net != null:
			net.send(0, [Msg.FRAME, _epoch, t, frame])
		_next_frame += 1
	if seats_changed:
		_refresh_labels()


func _all_inputs_in(t: int) -> bool:
	for id: int in _peers:
		var p: Dictionary = _peers[id]
		if p["greeted"] and t >= p["from"] and not p["inputs"].has(t):
			return false
	return true


func _step_frames() -> void:
	var cap := MAX_CATCHUP if role == Role.CLIENT else 1 << 30
	var n := 0
	while n < cap and sim.winner < 0 and _frames.has(sim.tick):
		var t := sim.tick
		sim.step_frame(_frames[t])
		_frames.erase(t)
		n += 1
		_view.add_events(sim.events)
		var report := sim.tick % SUM_EVERY == 0 and role != Role.OFFLINE
		if report or record_sums:
			var s := sim.checksum()
			if record_sums:
				sums_log["%d:%d" % [_epoch, sim.tick]] = s
			if report and role == Role.HOST:
				_sums[sim.tick] = s
				_sums.erase(sim.tick - SUM_EVERY * 20)
			elif report:
				net.send(LOCAL, [Msg.SUM, _epoch, sim.tick, s])
		if sim.winner >= 0:
			map_wins[sim.winner] += 1
			if map_wins[sim.winner] >= Cfg.MAPS_TO_WIN:
				match_winner = sim.winner
	if n > 0 or sim.winner >= 0 or paused or role == Role.OFFLINE:
		waiting_t = 0
	else:
		waiting_t += 1


func _local_packet() -> PackedByteArray:
	return LocalInput.blank_packet() if _menu.is_open() else _input.packet()


func _wants_next() -> bool:
	if _menu.is_open():
		return false
	for device: String in LocalInput.DEVICES:
		if _input.pressed(device, "join") or _input.pressed(device, "jump"):
			return true
	return false


# --- Network messages ----------------------------------------------------

func _net_events() -> void:
	for ev: Array in net.poll():
		match ev[0]:
			"join":
				if role == Role.HOST:
					_peers[ev[1]] = _peer_state(false)
			"leave":
				if role == Role.HOST and _peers.has(ev[1]):
					var had := _labels_of(ev[1])
					_drop_peer(ev[1])
					_refresh_labels()
					_say("%s left; bots take over." % had if had != "" else "A player left.")
			"connected":
				net.send(LOCAL, [Msg.HELLO, NetPeer.PROTOCOL, updater.version, fingerprint])
				net_status = "Connected, waiting for the host…"
			"failed":
				_go_offline("Couldn't reach a host at %s." % _join_addr)
			"closed":
				_go_offline("The host closed the game." if _started else "The host turned us away.")
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
			if p["greeted"] or not NetPeer.valid(m, [TYPE_INT, TYPE_STRING, TYPE_INT]):
				return
			if m[1] != NetPeer.PROTOCOL or m[3] != fingerprint:
				net.send(id, [Msg.REJECT, "The host runs %s and you run %s. Everyone needs the same version." % [updater.version, m[2]]])
				return
			p["greeted"] = true
			p["from"] = _next_frame
			net.send(id, _start_msg(true))
			_join(_key(id, "kb1"))
			_refresh_labels()
			_say("%s joined." % _labels_of(id) if _labels_of(id) != "" else "A player joined to watch.")
		Msg.INPUT:
			if not p["greeted"] or not NetPeer.valid(m, [TYPE_INT, TYPE_INT, TYPE_PACKED_BYTE_ARRAY]):
				return
			var t: int = m[2]
			if m[1] == _epoch and t >= maxi(_next_frame, p["from"]) and t < _next_frame + 600 \
					and m[3].size() == LocalInput.PACKET_BYTES and not p["inputs"].has(t):
				p["inputs"][t] = m[3]
		Msg.NEXT:
			if p["greeted"] and NetPeer.valid(m, [TYPE_INT]) and m[1] == _epoch \
					and sim.winner >= 0 and _win_ticks > 60:
				_advance()
		Msg.SUM:
			if not p["greeted"] or not NetPeer.valid(m, [TYPE_INT, TYPE_INT, TYPE_INT]):
				return
			if m[1] == _epoch and _sums.has(m[2]) and _sums[m[2]] != m[3]:
				# Out of step: send the client the current state to carry on from.
				resyncs += 1
				push_warning("peer %d desynced at tick %d; resyncing" % [id, m[2]])
				net.send(id, _start_msg(true))


func _client_msg(m: Array) -> void:
	match m[0]:
		Msg.REJECT:
			if NetPeer.valid(m, [TYPE_STRING]):
				_go_offline(m[1])
		Msg.START:
			if not NetPeer.valid(m, [TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT,
					TYPE_PACKED_BYTE_ARRAY, TYPE_BOOL]) or not m[3] in [1, 3]:
				return
			var resync: bool = _started and m[1] == _epoch
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
					and m[1] == _epoch and m[2] >= sim.tick \
					and m[3].size() == sim.units.size() * InputFrame.UNIT_BYTES:
				_frames[m[2]] = m[3]
		Msg.SEATS:
			if NetPeer.valid(m, [TYPE_ARRAY]):
				_apply_seats(m[1])
		Msg.PAUSE:
			if NetPeer.valid(m, [TYPE_BOOL]):
				paused = m[1]


func _peer_state(greeted: bool) -> Dictionary:
	return {"greeted": greeted, "from": _next_frame, "inputs": {}}


func _drop_peer(id: int) -> void:
	_peers.erase(id)
	var prefix := "%d:" % id
	for key: String in humans.keys():
		if key.begins_with(prefix):
			humans.erase(key)
	for key: String in _prev_buttons.keys():
		if key.begins_with(prefix):
			_prev_buttons.erase(key)


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


## Number the seated players and tell everyone who is where.
func _refresh_labels() -> void:
	var entries := []
	for key: String in humans:
		if not _player_no.has(key):
			_player_no[key] = _next_player
			_next_player += 1
		entries.append([_unit_of(key).id, "P%d" % _player_no[key], int(key.get_slice(":", 0))])
	_apply_seats(entries)
	if net != null:
		net.send(0, [Msg.SEATS, entries])


func _apply_seats(entries: Array) -> void:
	var labels := {}
	var mine := PackedStringArray()
	var me := net.id() if net != null else LOCAL
	for e in entries:
		if not (e is Array and e.size() == 3 and e[0] is int and e[1] is String and e[2] is int):
			continue
		labels[e[0]] = e[1]
		if e[2] == me:
			mine.append(e[1])
	_view.labels = labels
	you = ", ".join(mine)


func _labels_of(peer: int) -> String:
	var out := PackedStringArray()
	for key: String in _player_no:
		if key.begins_with("%d:" % peer) and humans.has(key):
			out.append("P%d" % _player_no[key])
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
			net_status = "Hosting at %s  ·  %d joined" % [_host_address(), n]
		Role.CLIENT:
			if _started:
				net_status = "Online  ·  %d ms" % net.ping(LOCAL)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var host_only := "Only the host can do that."
	match key.physical_keycode:
		KEY_F1:
			show_help = not show_help
			_help_ticks = 0
		KEY_F2:
			if role == Role.CLIENT:
				_say(host_only)
				return
			greys_per_team = 3 if greys_per_team == 1 else 1
			_new_match()
		KEY_F3:
			if role == Role.CLIENT:
				_say(host_only)
				return
			var k1 := _key(LOCAL, "kb1")
			if humans.has(k1):
				humans.erase(k1)
			else:
				_seat(k1, 0, 0)
			_refresh_labels()
		KEY_F5:
			updater.install()
		KEY_F6:
			_menu.toggle()
		KEY_R:
			if role == Role.CLIENT:
				_say(host_only)
				return
			_new_match()
		KEY_ESCAPE:
			if _menu.is_open():
				_menu.toggle()
			elif role == Role.CLIENT:
				_say("Only the host can pause.")
			else:
				paused = not paused
				if net != null:
					net.send(0, [Msg.PAUSE, paused])


func _exit_tree() -> void:
	if net != null:
		net.close()
	if sim != null:
		sim.dispose()
