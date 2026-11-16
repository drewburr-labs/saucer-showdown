extends "res://scripts/net/net_peer.gd"
## Online play through the relay server: the same interface and events as
## NetPeer's direct ENet link, plus ["room", code] for a host once its room
## is open and ["refused", reason] when the relay turns us down.
## The relay gives every client an id, and the host is always 1.
## relay/relay_client.gd does the talking; this turns its events into ours.

const RP = preload("res://relay/relay_protocol.gd")
const RelayClient = preload("res://relay/relay_client.gd")
const GAME_ID := "saucer-showdown"

var room_code := ""
var _relay := RelayClient.new()
var _my_id := HOST_ID


func host_relay(address: String, port: int) -> Error:
	is_host = true
	return _relay.host(address, port, GAME_ID, MAX_CLIENTS)


func join_relay(address: String, port: int, code: String) -> Error:
	return _relay.join(address, port, GAME_ID, code)


func id() -> int:
	return _my_id


func poll() -> Array:
	var out: Array = []
	if _closed:
		return out
	for ev: Array in _relay.poll():
		match ev[0]:
			"room":
				room_code = ev[1]
				out.append(["room", room_code])
			"joined":
				_my_id = ev[1]
				if not is_host:
					out.append(["connected"])
			"peer_in":
				_ids[ev[1]] = true
				out.append(["join", ev[1]])
			"peer_out":
				_ids.erase(ev[1])
				out.append(["leave", ev[1]])
			"data":
				var m = bytes_to_var(ev[2])
				if m is Array and not m.is_empty() and m[0] is int:
					out.append(["msg", ev[1], m])
			"refused":
				if ev[1] == RP.Refusal.OUTDATED:
					out.append(["refused", "This version of the game can't use the relay. Update the game (F5)."])
				else:
					out.append(["refused", ev[2]])
				_closed = true
			"failed", "closed":
				out.append([ev[0]])
				_closed = true
	return out


func send(to: int, m: Array) -> void:
	if _closed or not _relay.is_linked():
		return
	if is_host and to != 0 and not _ids.has(to):
		return
	var bytes := var_to_bytes(m)
	if lag_ms > 0:
		_outbox.append([Time.get_ticks_msec() + lag_ms, to, bytes])
	else:
		_relay.send(to, bytes)


func flush() -> void:
	if _closed:
		return
	var now := Time.get_ticks_msec()
	while not _outbox.is_empty() and _outbox[0][0] <= now:
		var o: Array = _outbox.pop_front()
		_relay.send(o[1], o[2])
	_relay.flush()


## Round trip to the relay only; Main measures the real one with PING.
func ping(_peer: int) -> int:
	return -1 if _closed else _relay.relay_ping()


func close() -> void:
	_relay.close()
	_closed = true
