extends RefCounted
## ENet transport for online play: one host and up to MAX_CLIENTS clients.
## Messages are short Arrays, sent reliably and in order on one channel. They
## are decoded with bytes_to_var, which never builds objects, and handlers
## check each message's shape with valid() before trusting it.
##
## Protocol (first element is the Msg):
##   client -> host  HELLO   protocol, version, sim fingerprint
##                   INPUT   epoch, tick, local input packet (LocalInput.packet())
##                   NEXT    epoch                  (wants the next map after a win)
##                   SUM     epoch, tick, checksum  (every Main.SUM_EVERY ticks)
##   host -> client  REJECT  reason
##                   START   epoch, seed, greys, wins0, wins1, match winner, snapshot, paused
##                   FRAME   epoch, tick, InputFrame   (confirmed: everyone's real input)
##                   SEATS   [[unit id, label, peer id, device], ...]
##                   PAUSE   paused
##                   SYNC    how many ticks early this client's inputs arrive, on average
## The epoch goes up with every new map, so stale inputs and frames are dropped.

const Sim = preload("res://scripts/sim/sim.gd")
const InputFrame = preload("res://scripts/sim/input_frame.gd")

const PORT := 24680
const PROTOCOL := 2
const MAX_CLIENTS := 7
const HOST_ID := 1

enum Msg { HELLO, REJECT, START, FRAME, INPUT, SEATS, NEXT, SUM, PAUSE, SYNC }

var is_host := false
## Testing aid: hold every outgoing packet this long before sending it.
var lag_ms := 0
var _outbox: Array = [] # [due msec, to, bytes] while lag_ms > 0
var _peer: ENetMultiplayerPeer
var _events: Array = []
var _ids: Dictionary = {} # connected peer ids (host)
var _was_connected := false
var _closed := false


func host(port: int) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		_peer = null
		return err
	is_host = true
	_peer.peer_connected.connect(_on_connected)
	_peer.peer_disconnected.connect(_on_disconnected)
	return OK


func join(address: String, port: int) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		_peer = null
	return err


## This machine's peer id: 1 on the host.
func id() -> int:
	return _peer.get_unique_id() if _peer != null else HOST_ID


## Everything that happened since the last poll, in order:
##   ["join", id] / ["leave", id]   host: a client connected or left
##   ["connected"] / ["failed"] / ["closed"]   client: link to the host
##   ["msg", from, Array]
func poll() -> Array:
	var out: Array = []
	if _peer == null or _closed:
		return out
	_peer.poll()
	out.append_array(_events)
	_events.clear()
	while _peer.get_available_packet_count() > 0:
		var from := _peer.get_packet_peer()
		var m = bytes_to_var(_peer.get_packet())
		if m is Array and not m.is_empty() and m[0] is int:
			out.append(["msg", from, m])
	if not is_host:
		var st := _peer.get_connection_status()
		if st == MultiplayerPeer.CONNECTION_CONNECTED and not _was_connected:
			_was_connected = true
			out.append(["connected"])
		elif st == MultiplayerPeer.CONNECTION_DISCONNECTED:
			_closed = true
			out.append(["closed" if _was_connected else "failed"])
	return out


## `to` is a peer id, or 0 for every client.
func send(to: int, m: Array) -> void:
	if _peer == null or _closed:
		return
	if _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if is_host and to != 0 and not _has_peer(to):
		return
	if lag_ms > 0:
		_outbox.append([Time.get_ticks_msec() + lag_ms, to, var_to_bytes(m)])
		return
	_put(to, var_to_bytes(m))


## Push queued packets out now instead of at the next poll.
func flush() -> void:
	if _peer == null or _closed:
		return
	var now := Time.get_ticks_msec()
	while not _outbox.is_empty() and _outbox[0][0] <= now:
		var o: Array = _outbox.pop_front()
		if not is_host or o[1] == 0 or _has_peer(o[1]):
			_put(o[1], o[2])
	if _peer.host != null:
		_peer.host.flush()


func _put(to: int, bytes: PackedByteArray) -> void:
	_peer.set_target_peer(to)
	_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	_peer.transfer_channel = 0
	_peer.put_packet(bytes)


## Round-trip time to `peer` in ms, or -1.
func ping(peer: int) -> int:
	if _peer == null or _closed or (is_host and not _has_peer(peer)):
		return -1
	if not is_host and not _was_connected:
		return -1
	var p := _peer.get_peer(peer)
	return int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)) if p != null else -1


func close() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	_closed = true


## True if `m` is [Msg, ...] with one value of each of `types` after the Msg.
static func valid(m: Array, types: Array) -> bool:
	if m.size() != types.size() + 1:
		return false
	for i in types.size():
		if typeof(m[i + 1]) != types[i]:
			return false
	return true


## A checksum of a short bot match. Builds whose sim or tuning differ in any
## way give different numbers, so the host can turn away a mismatched client
## before it desyncs.
static func sim_fingerprint() -> int:
	var s := Sim.new(4242, 3)
	var f := InputFrame.all_bots(s.units.size())
	for i in 240:
		s.step_frame(f)
	var h := s.checksum()
	s.dispose()
	return h


## This machine's LAN addresses, for telling friends where to join. Home
## router ranges come first; 172.x is often a VM or container bridge.
static func lan_addresses() -> PackedStringArray:
	var ranked := []
	for a in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		var rank := 0 if a.begins_with("192.168.") else (1 if a.begins_with("10.") else 2)
		ranked.append([rank, a])
	ranked.sort()
	var out := PackedStringArray()
	for r in ranked:
		out.append(r[1])
	return out


func _has_peer(peer: int) -> bool:
	return _ids.has(peer)


func _on_connected(peer: int) -> void:
	_ids[peer] = true
	_events.append(["join", peer])


func _on_disconnected(peer: int) -> void:
	_ids.erase(peer)
	_events.append(["leave", peer])
