extends RefCounted
## The relay: lets players behind home routers play without port forwarding.
## A host opens a room and gets a short code; friends join with the code;
## the relay then passes each room's packets between its host and clients.
## It never reads the game's messages, so it doesn't change when the game
## does, as long as relay_protocol.gd's VERSION stays the same.
##
## run_relay.gd runs it (see Dockerfile); tests drive poll() themselves.
## It uses a raw ENetConnection rather than ENetMultiplayerPeer, so it sees
## every connection as a plain peer and can route between them.

const P = preload("relay_protocol.gd")

const MAX_PEERS := 1024
const MAX_ROOMS := 400
const MAX_PACKET := 256 * 1024
const MAX_BAD_JOINS := 20 # wrong codes per address per minute, against code guessing

var quiet := false # tests: don't log
var conn: ENetConnection

var _next_id := 2 # 1 means "the host" inside a room
var _ids := {} # ENetPacketPeer -> id
var _peers := {} # id -> ENetPacketPeer
var _room_of := {} # id -> room code
var _rooms := {} # code -> {"host": id, "clients": {id: true}}
var _bad_joins := {} # remote address -> [wrong codes, minute they're counted in]
var _rng := RandomNumberGenerator.new()


func start(port: int, bind: String = "*") -> Error:
	conn = ENetConnection.new()
	var err := conn.create_host_bound(bind, port, MAX_PEERS, 1)
	if err != OK:
		conn = null
		return err
	_rng.randomize()
	_log("listening on udp %s:%d" % [bind, port])
	return OK


func stop() -> void:
	if conn != null:
		for peer: ENetPacketPeer in _ids:
			peer.peer_disconnect_now()
		conn.flush()
		conn.destroy()
	conn = null
	_ids.clear()
	_peers.clear()
	_rooms.clear()
	_room_of.clear()


## Handle everything that has arrived. Returns how many events there were.
## (Don't pass service() a timeout to wait for packets: Godot's ENet spins
## the CPU while it waits. run_relay.gd sleeps between empty polls instead.)
func poll() -> int:
	if conn == null:
		return 0
	var n := 0
	var ev: Array = conn.service(0)
	while ev[0] != ENetConnection.EVENT_NONE and ev[0] != ENetConnection.EVENT_ERROR:
		n += 1
		var peer: ENetPacketPeer = ev[1]
		match ev[0]:
			ENetConnection.EVENT_CONNECT:
				_ids[peer] = _next_id
				_peers[_next_id] = peer
				_next_id += 1
			ENetConnection.EVENT_DISCONNECT:
				if _ids.has(peer):
					var id: int = _ids[peer]
					_leave(id)
					_ids.erase(peer)
					_peers.erase(id)
			ENetConnection.EVENT_RECEIVE:
				var packet := peer.get_packet()
				if _ids.has(peer) and packet.size() >= 1 and packet.size() <= MAX_PACKET:
					_receive(_ids[peer], packet)
		ev = conn.service(0)
	conn.flush()
	if _bad_joins.size() > 1000:
		_bad_joins.clear()
	return n


func room_count() -> int:
	return _rooms.size()


func peer_count() -> int:
	return _peers.size()


func _receive(id: int, p: PackedByteArray) -> void:
	match p[0]:
		P.HOST:
			if _room_of.has(id) or not _version_ok(id, p):
				return
			if _rooms.size() >= MAX_ROOMS:
				_refuse(id, "The relay is full right now. Try again in a bit.")
				return
			var code := _new_code()
			_rooms[code] = {"host": id, "clients": {}}
			_room_of[id] = code
			var out := PackedByteArray([P.ROOM])
			out.append_array(code.to_ascii_buffer())
			_send(id, out)
			_log("room %s opened (%d rooms, %d peers)" % [code, _rooms.size(), _peers.size()])
		P.JOIN:
			if _room_of.has(id) or not _version_ok(id, p) or p.size() != 3 + P.CODE_LEN:
				return
			var addr: String = (_peers[id] as ENetPacketPeer).get_remote_address()
			var minute := Time.get_ticks_msec() / 60000
			var bad: Array = _bad_joins.get(addr, [0, minute])
			if bad[1] != minute:
				bad = [0, minute]
			if bad[0] >= MAX_BAD_JOINS:
				_refuse(id, "Too many wrong codes. Wait a minute and try again.")
				return
			var code := P.normalize_code(p.slice(3).get_string_from_ascii())
			if not _rooms.has(code):
				_bad_joins[addr] = [bad[0] + 1, minute]
				_refuse(id, "No game with the code %s. Check it with the host." % code if code != "" else "That isn't a room code.")
				return
			var room: Dictionary = _rooms[code]
			if room["clients"].size() >= P.MAX_CLIENTS:
				_refuse(id, "That game is full.")
				return
			room["clients"][id] = true
			_room_of[id] = code
			_send(id, P.with_id(P.JOINED, id))
			_send(room["host"], P.with_id(P.PEER_IN, id))
		P.DATA:
			if not _room_of.has(id) or p.size() < 5:
				return
			var room: Dictionary = _rooms[_room_of[id]]
			var payload := p.slice(5)
			if room["host"] == id:
				var out := P.with_id(P.DATA, 1)
				out.append_array(payload)
				var to := p.decode_u32(1)
				if to == 0:
					for c: int in room["clients"]:
						_send(c, out)
				elif room["clients"].has(to):
					_send(to, out)
			else:
				var out := P.with_id(P.DATA, id)
				out.append_array(payload)
				_send(room["host"], out)


func _leave(id: int) -> void:
	if not _room_of.has(id):
		return
	var code: String = _room_of[id]
	_room_of.erase(id)
	var room: Dictionary = _rooms[code]
	if room["host"] == id:
		# No host, no game: send everyone home.
		for c: int in room["clients"]:
			_room_of.erase(c)
			_peers[c].peer_disconnect_later()
		_rooms.erase(code)
		_log("room %s closed (%d rooms, %d peers)" % [code, _rooms.size(), _peers.size() - 1])
	else:
		room["clients"].erase(id)
		_send(room["host"], P.with_id(P.PEER_OUT, id))


func _version_ok(id: int, p: PackedByteArray) -> bool:
	if p.size() < 3:
		return false
	if p.decode_u16(1) != P.VERSION:
		_refuse(id, "This version of the game can't use the relay. Update the game (F5).")
		return false
	return true


func _refuse(id: int, reason: String) -> void:
	var out := PackedByteArray([P.ERROR])
	out.append_array(reason.to_utf8_buffer())
	_send(id, out)
	_peers[id].peer_disconnect_later()


func _send(id: int, bytes: PackedByteArray) -> void:
	var peer: ENetPacketPeer = _peers.get(id)
	if peer != null:
		peer.send(0, bytes, ENetPacketPeer.FLAG_RELIABLE)


func _new_code() -> String:
	while true:
		var c := ""
		for i in P.CODE_LEN:
			c += P.CODE_CHARS[_rng.randi_range(0, P.CODE_CHARS.length() - 1)]
		if not _rooms.has(c):
			return c
	return ""


func _log(text: String) -> void:
	if not quiet:
		print("[%s] %s" % [Time.get_datetime_string_from_system(true), text])
