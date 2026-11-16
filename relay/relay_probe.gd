extends SceneTree
## Checks a relay server end to end: opens a room as a host, joins it as a
## friend, and passes a packet each way. Exits 0 if all of that works.
##   godot --headless --path . --script res://relay/relay_probe.gd -- [host[:port]]
## The default is the relay the game uses (relay_protocol.gd).

const P = preload("relay_protocol.gd")
const TIMEOUT_MS := 8000


func _initialize() -> void:
	var target := "%s:%d" % [P.HOST_NAME, P.PORT]
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		target = args[0]
	var host_name := target.get_slice(":", 0)
	var port := int(target.get_slice(":", 1)) if target.contains(":") else P.PORT
	print("probing relay at %s:%d" % [host_name, port])

	var h := _Link.new(host_name, port)
	var g: _Link = null
	var code := ""
	var guest_id := 0
	var stage := "connect host"
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < TIMEOUT_MS:
		for p: PackedByteArray in h.poll():
			match p[0]:
				P.ROOM:
					code = p.slice(1).get_string_from_ascii()
					print("  room %s opened" % code)
					g = _Link.new(host_name, port, code)
					stage = "join as a friend"
				P.PEER_IN:
					guest_id = p.decode_u32(1)
					var out := P.with_id(P.DATA, guest_id)
					out.append_array("ping".to_utf8_buffer())
					h.send(out)
					stage = "pass a packet to the friend"
				P.DATA:
					if p.slice(5).get_string_from_utf8() == "pong" and p.decode_u32(1) == guest_id:
						print("  friend %d -> host: ok" % guest_id)
						print("relay OK (%d ms)" % (Time.get_ticks_msec() - t0))
						quit(0)
						return
				P.ERROR:
					_fail("relay refused the host: " + p.slice(1).get_string_from_utf8())
					return
		if g != null:
			for p: PackedByteArray in g.poll():
				match p[0]:
					P.JOINED:
						print("  joined as id %d" % p.decode_u32(1))
					P.DATA:
						if p.slice(5).get_string_from_utf8() == "ping":
							print("  host -> friend: ok")
							var out := P.with_id(P.DATA, 1)
							out.append_array("pong".to_utf8_buffer())
							g.send(out)
							stage = "pass a packet back to the host"
					P.ERROR:
						_fail("relay refused the friend: " + p.slice(1).get_string_from_utf8())
						return
		OS.delay_msec(5)
	_fail("timed out at: " + stage)


func _fail(why: String) -> void:
	printerr("relay probe FAILED: " + why)
	quit(1)


class _Link:
	var conn := ENetConnection.new()
	var peer: ENetPacketPeer
	var first: PackedByteArray

	func _init(host_name: String, port: int, code: String = "") -> void:
		conn.create_host(1, 1)
		peer = conn.connect_to_host(host_name, port, 1)
		if code == "":
			first = P.with_version(P.HOST)
		else:
			first = P.with_version(P.JOIN)
			first.append_array(code.to_ascii_buffer())

	func send(bytes: PackedByteArray) -> void:
		peer.send(0, bytes, ENetPacketPeer.FLAG_RELIABLE)
		conn.flush()

	func poll() -> Array:
		var out := []
		var ev: Array = conn.service(0)
		while ev[0] != ENetConnection.EVENT_NONE and ev[0] != ENetConnection.EVENT_ERROR:
			if ev[0] == ENetConnection.EVENT_CONNECT:
				send(first)
			elif ev[0] == ENetConnection.EVENT_RECEIVE:
				var p := peer.get_packet()
				if not p.is_empty():
					out.append(p)
			ev = conn.service(0)
		return out
