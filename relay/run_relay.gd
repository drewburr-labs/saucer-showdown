extends SceneTree
## Entry point for the relay server; the Docker image runs this. From the
## game's folder:
##   godot --headless --path . --script res://relay/run_relay.gd -- [--port=24680] [--bind=*]
##       [--metrics-port=24681] [--metrics-bind=*]
## With --metrics-port it also serves its metrics over HTTP on that TCP port
## (relay_metrics_http.gd). Keep that port private: only the UDP port needs
## to face the internet.

const RelayServer = preload("relay_server.gd")
const MetricsHttp = preload("relay_metrics_http.gd")
const P = preload("relay_protocol.gd")


func _initialize() -> void:
	var port := P.PORT
	var bind := "*"
	var metrics_port := 0
	var metrics_bind := "*"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
		elif a.begins_with("--bind="):
			bind = a.trim_prefix("--bind=")
		elif a.begins_with("--metrics-port="):
			metrics_port = int(a.trim_prefix("--metrics-port="))
		elif a.begins_with("--metrics-bind="):
			metrics_bind = a.trim_prefix("--metrics-bind=")
	var relay := RelayServer.new()
	var err := relay.start(port, bind)
	if err != OK:
		printerr("can't listen on udp %s:%d: %s" % [bind, port, error_string(err)])
		quit(1)
		return
	var http: MetricsHttp = null
	if metrics_port > 0:
		http = MetricsHttp.new()
		err = http.start(metrics_port, metrics_bind, relay.metrics_text)
		if err != OK:
			printerr("can't serve metrics on tcp %s:%d: %s" % [metrics_bind, metrics_port, error_string(err)])
			quit(1)
			return
		print("[%s] metrics on http://%s:%d/metrics" % [Time.get_datetime_string_from_system(true), metrics_bind, metrics_port])
	# Poll, and nap whenever nothing came in: 1 ms while games are running
	# (that's all the latency it adds), 10 ms once it's been quiet for a
	# second, so an empty relay costs next to no CPU. Metrics requests are
	# looked at every 20 ms at most; they're in no hurry.
	var last_report := Time.get_ticks_msec()
	var quiet_since := Time.get_ticks_msec()
	var last_http := 0
	while true:
		if relay.poll() > 0:
			quiet_since = Time.get_ticks_msec()
		else:
			OS.delay_msec(1 if Time.get_ticks_msec() - quiet_since < 1000 else 10)
		if http != null and Time.get_ticks_msec() - last_http >= 20:
			last_http = Time.get_ticks_msec()
			http.poll()
		if Time.get_ticks_msec() - last_report > 600000:
			last_report = Time.get_ticks_msec()
			print("[%s] %d rooms, %d peers" % [Time.get_datetime_string_from_system(true), relay.room_count(), relay.peer_count()])
