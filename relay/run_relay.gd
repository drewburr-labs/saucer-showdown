extends SceneTree
## Entry point for the relay server; the Docker image runs this. From the
## game's folder:
##   godot --headless --path . --script res://relay/run_relay.gd -- [--port=24680] [--bind=*]

const RelayServer = preload("relay_server.gd")
const P = preload("relay_protocol.gd")


func _initialize() -> void:
	var port := P.PORT
	var bind := "*"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
		elif a.begins_with("--bind="):
			bind = a.trim_prefix("--bind=")
	var relay := RelayServer.new()
	var err := relay.start(port, bind)
	if err != OK:
		printerr("can't listen on udp %s:%d: %s" % [bind, port, error_string(err)])
		quit(1)
		return
	# Poll, and nap whenever nothing came in: 1 ms while games are running
	# (that's all the latency it adds), 10 ms once it's been quiet for a
	# second, so an empty relay costs next to no CPU.
	var last_report := Time.get_ticks_msec()
	var quiet_since := Time.get_ticks_msec()
	while true:
		if relay.poll() > 0:
			quiet_since = Time.get_ticks_msec()
		else:
			OS.delay_msec(1 if Time.get_ticks_msec() - quiet_since < 1000 else 10)
		if Time.get_ticks_msec() - last_report > 600000:
			last_report = Time.get_ticks_msec()
			print("[%s] %d rooms, %d peers" % [Time.get_datetime_string_from_system(true), relay.room_count(), relay.peer_count()])
