extends SceneTree
## Checks a relay server end to end: opens a room as a host, checks another
## game can't join it, joins it as a friend, and passes a packet each way on
## channel 1. Exits 0 if all of that works.
##   godot --headless --path . --script res://relay/relay_probe.gd -- [host[:port]]
## The default is the public relay (relay_protocol.gd).

const P = preload("relay_protocol.gd")
const RelayClient = preload("relay_client.gd")
const GAME := "relay-probe"
const TIMEOUT_MS := 8000


func _initialize() -> void:
	var target := "%s:%d" % [P.HOST_NAME, P.PORT]
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		target = args[0]
	var host_name := target.get_slice(":", 0)
	var port := int(target.get_slice(":", 1)) if target.contains(":") else P.PORT
	print("probing relay at %s:%d" % [host_name, port])

	var h := RelayClient.new()
	var g: RelayClient = null
	var other: RelayClient = null
	var guest_id := 0
	var stage := "open a room"
	if h.host(host_name, port, GAME, 1, 2) != OK:
		_fail("can't start connecting")
		return
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < TIMEOUT_MS:
		for ev: Array in h.poll():
			match ev[0]:
				"room":
					print("  room %s opened" % ev[1])
					other = RelayClient.new()
					other.join(host_name, port, GAME + "-other", ev[1])
					stage = "turn away another game"
				"peer_in":
					guest_id = ev[1]
					h.send(guest_id, "ping".to_utf8_buffer(), 1)
					stage = "pass a packet to the friend"
				"data":
					if ev[1] == guest_id and ev[2].get_string_from_utf8() == "pong" and ev[3] == 1:
						print("  friend %d -> host: ok" % guest_id)
						print("relay OK (%d ms)" % (Time.get_ticks_msec() - t0))
						quit(0)
						return
				"refused":
					_fail("relay refused the host: " + ev[2])
					return
				"failed", "closed":
					_fail("lost the host's connection at: " + stage)
					return
		if other != null:
			for ev: Array in other.poll():
				match ev[0]:
					"refused":
						if ev[1] != P.Refusal.NO_SUCH_ROOM:
							_fail("another game was refused for the wrong reason: " + ev[2])
							return
						print("  another game can't use the code: ok")
						other = null
						g = RelayClient.new()
						g.join(host_name, port, GAME, h.room_code, 2)
						stage = "join as a friend"
					"joined":
						_fail("another game got into the room")
						return
					"failed", "closed":
						_fail("lost a connection at: " + stage)
						return
		if g != null:
			for ev: Array in g.poll():
				match ev[0]:
					"joined":
						print("  joined as id %d" % ev[1])
					"data":
						if ev[1] == P.HOST_ID and ev[2].get_string_from_utf8() == "ping" and ev[3] == 1:
							print("  host -> friend: ok")
							g.send(P.HOST_ID, "pong".to_utf8_buffer(), 1)
							stage = "pass a packet back to the host"
					"refused":
						_fail("relay refused the friend: " + ev[2])
						return
					"failed", "closed":
						_fail("lost the friend's connection at: " + stage)
						return
		OS.delay_msec(5)
	_fail("timed out at: " + stage)


func _fail(why: String) -> void:
	printerr("relay probe FAILED: " + why)
	quit(1)
