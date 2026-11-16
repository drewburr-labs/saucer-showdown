extends "res://scripts/net/net_peer.gd"
## Online play through the relay server: the same interface and events as
## NetPeer's direct ENet link, plus ["room", code] for a host once its room
## is open and ["refused", reason] when the relay turns us down.
## The relay gives every client an id, and the host is always 1.

const RP = preload("res://scripts/net/relay_protocol.gd")
const CONNECT_TIMEOUT_MS := 8000

var room_code := ""
var _conn: ENetConnection
var _server: ENetPacketPeer
var _join_code := ""
var _my_id := HOST_ID
var _linked := false # the relay has put us in a room
var _started_ms := 0


func host_relay(address: String, port: int) -> Error:
	is_host = true
	return _connect(address, port)


func join_relay(address: String, port: int, code: String) -> Error:
	_join_code = code
	return _connect(address, port)


func _connect(address: String, port: int) -> Error:
	_conn = ENetConnection.new()
	var err := _conn.create_host(1, 1)
	if err != OK:
		_conn = null
		return err
	_server = _conn.connect_to_host(address, port, 1)
	if _server == null:
		_conn.destroy()
		_conn = null
		return ERR_CANT_CONNECT
	_started_ms = Time.get_ticks_msec()
	return OK


func id() -> int:
	return _my_id


func poll() -> Array:
	var out: Array = []
	if _conn == null or _closed:
		return out
	var ev: Array = _conn.service(0)
	while ev[0] != ENetConnection.EVENT_NONE:
		match ev[0]:
			ENetConnection.EVENT_CONNECT:
				if is_host:
					_server.send(0, RP.with_version(RP.HOST), ENetPacketPeer.FLAG_RELIABLE)
				else:
					var p := RP.with_version(RP.JOIN)
					p.append_array(_join_code.to_ascii_buffer())
					_server.send(0, p, ENetPacketPeer.FLAG_RELIABLE)
			ENetConnection.EVENT_RECEIVE:
				_receive(_server.get_packet(), out)
			ENetConnection.EVENT_DISCONNECT, ENetConnection.EVENT_ERROR:
				_hang_up(out, "closed" if _linked else "failed")
		if _closed:
			return out
		ev = _conn.service(0)
	if not _linked and Time.get_ticks_msec() - _started_ms > CONNECT_TIMEOUT_MS:
		_hang_up(out, "failed")
	return out


func _receive(p: PackedByteArray, out: Array) -> void:
	if p.is_empty():
		return
	match p[0]:
		RP.ROOM:
			room_code = p.slice(1).get_string_from_ascii()
			_linked = true
			out.append(["room", room_code])
		RP.JOINED:
			if p.size() == 5:
				_my_id = p.decode_u32(1)
				_linked = true
				out.append(["connected"])
		RP.ERROR:
			out.append(["refused", p.slice(1).get_string_from_utf8()])
			_hang_up(out, "")
		RP.PEER_IN:
			if p.size() == 5:
				_ids[p.decode_u32(1)] = true
				out.append(["join", p.decode_u32(1)])
		RP.PEER_OUT:
			if p.size() == 5:
				_ids.erase(p.decode_u32(1))
				out.append(["leave", p.decode_u32(1)])
		RP.DATA:
			if p.size() > 5:
				var m = bytes_to_var(p.slice(5))
				if m is Array and not m.is_empty() and m[0] is int:
					out.append(["msg", p.decode_u32(1), m])


func _hang_up(out: Array, event: String) -> void:
	if event != "":
		out.append([event])
	close()


func send(to: int, m: Array) -> void:
	if _conn == null or _closed or not _linked:
		return
	if is_host and to != 0 and not _ids.has(to):
		return
	var bytes := RP.with_id(RP.DATA, to)
	bytes.append_array(var_to_bytes(m))
	if lag_ms > 0:
		_outbox.append([Time.get_ticks_msec() + lag_ms, to, bytes])
	else:
		_server.send(0, bytes, ENetPacketPeer.FLAG_RELIABLE)


func flush() -> void:
	if _conn == null or _closed:
		return
	var now := Time.get_ticks_msec()
	while not _outbox.is_empty() and _outbox[0][0] <= now:
		_server.send(0, _outbox.pop_front()[2], ENetPacketPeer.FLAG_RELIABLE)
	_conn.flush()


## Round trip to the relay only; Main measures the real one with PING.
func ping(_peer: int) -> int:
	if _server == null or _closed:
		return -1
	return int(_server.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))


func close() -> void:
	if _conn != null:
		if _server != null and _server.is_active():
			_server.peer_disconnect_now() # tell the relay at once, so the room closes
		_conn.flush()
		_conn.destroy()
	_conn = null
	_server = null
	_closed = true
