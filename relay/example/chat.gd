extends SceneTree
## The smallest game that uses the relay: one machine hosts, the others join
## with the room code, and everyone's lines go to everyone. Copy the shape of
## this into your game; it needs only relay_client.gd and relay_protocol.gd.
##
##   godot --headless --path . --script res://relay/example/chat.gd -- host
##   godot --headless --path . --script res://relay/example/chat.gd -- join KX4PZ
##
## Add `--relay=HOST[:PORT]` to use a relay other than the public one.

const P = preload("../relay_protocol.gd")
const RelayClient = preload("../relay_client.gd")
const GAME_ID := "relay-example-chat" # pick your own; codes only work within one game id

var relay := RelayClient.new()
var said := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var address := P.HOST_NAME
	var port := P.PORT
	for a: String in args:
		if a.begins_with("--relay="):
			address = a.trim_prefix("--relay=").get_slice(":", 0)
			if a.contains(":"):
				port = int(a.get_slice(":", 1))
	if args.has("host"):
		relay.host(address, port, GAME_ID, 3) # up to 3 friends
	elif args.has("join") and args.find("join") + 1 < args.size():
		relay.join(address, port, GAME_ID, args[args.find("join") + 1])
	else:
		print("usage: -- host | -- join CODE")
		quit(1)


## Poll the relay every frame, as a game would in _process.
func _process(delta: float) -> bool:
	for ev: Array in relay.poll():
		match ev[0]:
			"room":
				print("room code: %s  (friends run: -- join %s)" % [ev[1], ev[1]])
			"joined":
				print("in the room as player %d" % ev[1])
			"peer_in":
				print("player %d joined" % ev[1])
			"peer_out":
				print("player %d left" % ev[1])
			"data":
				var line: String = ev[2].get_string_from_utf8()
				print(line)
				if relay.is_host:
					relay.send(0, ev[2]) # the host passes each line on to everyone
			"refused":
				print("the relay said no: %s" % ev[2])
				quit(1)
			"failed":
				print("couldn't reach the relay")
				quit(1)
			"closed":
				print("the game is over")
				quit(0)
	# Say something every few seconds, so there's traffic to watch.
	said += delta
	if relay.is_linked() and said > 3.0:
		said = 0.0
		var line := "player %d: hello at %s" % [relay.my_id, Time.get_time_string_from_system()]
		if relay.is_host:
			print(line)
		relay.send(0 if relay.is_host else P.HOST_ID, line.to_utf8_buffer())
	return false
