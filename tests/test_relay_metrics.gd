extends SceneTree
## The relay's metrics: a relay with a few games going over loopback, scraped
## over HTTP like Prometheus would. Checks the numbers, that the text is
## well-formed, that made-up game ids can't grow it without limit, and that
## the HTTP side answers properly and never holds the relay up.
##   godot --headless --path . --script tests/test_relay_metrics.gd

const RelayServer = preload("res://relay/relay_server.gd")
const RelayClient = preload("res://relay/relay_client.gd")
const Metrics = preload("res://relay/relay_metrics.gd")
const MetricsHttp = preload("res://relay/relay_metrics_http.gd")
const RP = preload("res://relay/relay_protocol.gd")
const Watchdog = preload("res://tests/watchdog.gd")

## Fails the run, saying where it was, if it takes longer than this; a normal
## run takes about 2 s.
const TIME_LIMIT := 20

const AT := "127.0.0.1"
const GAME := "tank\"game\\1" # a legal game id that needs escaping as a label
const LABEL := "{game=\"tank\\\"game\\\\1\"}"

var _failed := 0
var _current := ""
var _watchdog: Watchdog
var _relay: RelayServer
var _http: MetricsHttp
var _clients: Array[RelayClient] = []
var _logs := {} # RelayClient -> its events so far
var _slowest_poll := 0 # usec, the longest _http.poll() so far


func _init() -> void:
	_watchdog = Watchdog.new(TIME_LIMIT, func() -> String: return _current)
	var started := Time.get_ticks_msec()
	_relay = RelayServer.new()
	_relay.quiet = true
	_check(_relay.start(0, AT) == OK, "the relay should start")
	var port := _relay.conn.get_local_port()
	_http = MetricsHttp.new()
	_check(_http.start(0, AT, _relay.metrics_text) == OK, "the metrics server should start")

	_current = "an empty relay"
	var text := _body(_fetch("GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n"))
	_check_format(text)
	_check(_value(text, "relay_connections") == 0 and _value(text, "relay_rooms_limit") == RelayServer.MAX_ROOMS, "nothing is connected, and the limits are there")
	_check(_value(text, "relay_info{protocol=\"%d\"}" % RP.VERSION) == 1, "it says which protocol it speaks")
	_check(not text.contains("game="), "no games yet")
	if OS.get_name() == "Linux":
		_check(_value(text, "process_resident_memory_bytes") > 1e6 and _value(text, "process_cpu_seconds_total") >= 0, "memory and CPU time are reported")
	_report()

	_current = "rooms, seats, joins, refusals and traffic are counted"
	var host := _client()
	var c1 := _client()
	var c2 := _client()
	var wrong := _client()
	var solo := _client()
	host.host(AT, port, GAME, 3, 2)
	solo.host(AT, port, "solo", 31)
	_check(_until(func() -> bool: return host.room_code != "" and solo.room_code != ""), "two games open rooms")
	c1.join(AT, port, GAME, host.room_code, 2)
	c2.join(AT, port, GAME, host.room_code, 2)
	wrong.join(AT, port, GAME, "ZZZZZ" if host.room_code != "ZZZZZ" else "YYYYY")
	_check(_until(func() -> bool: return c1.is_linked() and c2.is_linked() and _saw(wrong, "refused")), "two friends join, and a wrong code is refused")
	host.send(0, PackedByteArray([1, 2, 3, 4]), 1, 0)
	c1.send(RP.HOST_ID, PackedByteArray([5, 6]))
	c2._server.send(0, PackedByteArray([99]), ENetPacketPeer.FLAG_RELIABLE) # no such packet type
	_check(_until(func() -> bool: return _saw(c1, "data") and _saw(c2, "data") and _saw(host, "data")), "packets get through")
	_relay._sample()
	text = _body(_fetch("GET /metrics?x=1 HTTP/1.1\r\n\r\n"))
	_check_format(text)
	_check(_value(text, "relay_rooms" + LABEL) == 1 and _value(text, "relay_rooms{game=\"solo\"}") == 1, "one room each")
	_check(_value(text, "relay_room_seats" + LABEL) == 4 and _value(text, "relay_room_seats{game=\"solo\"}") == 32, "seats are what the hosts asked for, plus themselves")
	_check(_value(text, "relay_room_peers" + LABEL) == 3 and _value(text, "relay_room_peers{game=\"solo\"}") == 1, "peers are who's in them")
	_check(_value(text, "relay_connections") == 4, "four connections are open (%s)" % _value(text, "relay_connections"))
	_check(_value(text, "relay_connections_opened_total") == 5, "five were made")
	_check(_value(text, "relay_rooms_opened_total" + LABEL) == 1 and _value(text, "relay_room_joins_total" + LABEL) == 2, "the room and its joins are counted")
	_check(_value(text, "relay_game_packets_total" + LABEL) == 2 and _value(text, "relay_game_bytes_total" + LABEL) == 6, "game packets are counted where they come in, by payload")
	_check(_value(text, "relay_game_packets_total{game=\"solo\"}") == 0, "and only for their own game")
	_check(_value(text, "relay_refusals_total{reason=\"no_such_room\"}") == 1 and _value(text, "relay_refusals_total{reason=\"room_full\"}") == 0, "the refusal is counted by reason")
	_check(_value(text, "relay_ignored_packets_total") == 1, "the packet of no known type is counted as ignored")
	_check(_value(text, "relay_peer_round_trip_seconds_count" + LABEL) == 3 and _value(text, "relay_peer_packet_loss_ratio_count" + LABEL) == 3, "each machine in the room was sampled")
	_check(_value(text, "relay_network_received_bytes_total") > 0 and _value(text, "relay_network_sent_packets_total") > 0, "traffic on the wire is counted")
	_check(_value(text, "relay_poll_duration_seconds_count") > 0, "busy polls are timed")
	_check(not text.contains(host.room_code) and not text.contains("127.0.0.1"), "no room codes or addresses are given away")
	_report()

	_current = "a closed room is counted, with how long it ran and how big it got"
	c2.close()
	_check(_until(func() -> bool: return _saw(host, "peer_out")), "a friend leaves")
	host.close()
	_check(_until(func() -> bool: return _saw(c1, "closed") and _relay.room_count() == 1), "then the host does")
	text = _body(_fetch("GET /metrics HTTP/1.1\r\n\r\n"))
	_check_format(text)
	_check(_value(text, "relay_rooms" + LABEL) == 0 and _value(text, "relay_room_peers" + LABEL) == 0, "the game stays listed, at zero")
	_check(_value(text, "relay_rooms_closed_total" + LABEL) == 1 and _value(text, "relay_rooms_closed_total{game=\"solo\"}") == 0, "the closed room is counted")
	_check(_value(text, "relay_room_duration_seconds_count" + LABEL) == 1 and _value(text, "relay_room_duration_seconds_bucket" + LABEL.replace("}", ",le=\"10\"}")) == 1, "it lasted under 10 s")
	_check(_value(text, "relay_room_peak_peers_sum" + LABEL) == 3, "it had 3 machines at its fullest, though one had left")
	_check(_value(text, "relay_room_peak_peers_bucket" + LABEL.replace("}", ",le=\"2\"}")) == 0 and _value(text, "relay_room_peak_peers_bucket" + LABEL.replace("}", ",le=\"3\"}")) == 1, "which lands in the right bucket")
	_check(_until(func() -> bool: return _value(_relay.metrics_text(), "relay_connections") == 1), "only the other game's host is still connected")
	_report()

	_current = "made-up game ids can't grow the metrics without limit"
	var m := Metrics.new()
	for i in Metrics.MAX_GAMES + 50:
		m.game("game-%d" % i).rooms_opened += 1
	m.game("game-0").rooms_opened += 1
	text = m.render({}, 0, 1, 1)
	_check_format(text)
	var games := 0
	for line in text.split("\n"):
		if line.begins_with("relay_rooms_opened_total{"):
			games += 1
	_check(games == Metrics.MAX_GAMES + 1, "%d games get their own label, the rest share one (%d)" % [Metrics.MAX_GAMES, games])
	_check(_value(text, "relay_rooms_opened_total{game=\"other\"}") == 50 and _value(text, "relay_rooms_opened_total{game=\"game-0\"}") == 2, "and nothing goes uncounted")
	_report()

	_current = "http: other paths and methods, a health check"
	_check(_fetch("GET /healthz HTTP/1.1\r\n\r\n").begins_with("HTTP/1.1 200 ") and _body(_fetch("GET /healthz HTTP/1.0\n\n")) == "ok\n", "/healthz says ok")
	_check(_fetch("GET / HTTP/1.1\r\n\r\n").begins_with("HTTP/1.1 404 "), "other paths aren't found")
	_check(_fetch("POST /metrics HTTP/1.1\r\nContent-Length: 0\r\n\r\n").begins_with("HTTP/1.1 405 "), "only GET is allowed")
	_check(_fetch("hello\r\n\r\n").begins_with("HTTP/1.1 400 "), "nonsense is a bad request")
	_check(not _fetch("GET /metrics HTTP/1.1\r\nX: " + "y".repeat(MetricsHttp.MAX_REQUEST) + "\r\n\r\n").contains("200 OK"), "an endless request is hung up on")
	var head := _fetch("GET /metrics HTTP/1.1\r\n\r\n").get_slice("\r\n\r\n", 0)
	_check(head.contains("Content-Type: text/plain; version=0.0.4") and head.contains("Content-Length: %d" % _relay.metrics_text().to_utf8_buffer().size()), "metrics come with their type and length")
	_report()

	_current = "http: slow and silent clients don't hold the relay up"
	var big := MetricsHttp.new()
	big.deadline_msec = 300
	var huge := "0123456789abcdef".repeat(1 << 18) # 4 MB, more than a socket takes at once
	big.start(0, AT, func() -> String: return huge)
	_http.stop()
	_http = big
	_slowest_poll = 0
	var silent := _connect("") # connects and never asks
	var deaf := _connect("GET /metrics HTTP/1.1\r\n\r\n") # asks and never reads
	var flood: Array[StreamPeerTCP] = []
	for i in MetricsHttp.MAX_CONNECTIONS + 4:
		flood.append(_connect(""))
	_until(func() -> bool: return false, 100)
	_check(_http._open.size() == MetricsHttp.MAX_CONNECTIONS, "it holds at most %d connections at once (%d)" % [MetricsHttp.MAX_CONNECTIONS, _http._open.size()])
	_check(_until(func() -> bool: return _http._open.is_empty(), 2000), "and drops the ones that don't finish in time")
	_check(_body(_fetch("GET /metrics HTTP/1.1\r\n\r\n")) == huge, "a client that does read gets all 4 MB, in pieces")
	_check(_slowest_poll < 50000, "no poll waited on a client (the slowest took %d ms)" % (_slowest_poll / 1000))
	_check(solo.is_linked() and _relay.room_count() == 1, "and the game still running didn't notice")
	silent.disconnect_from_host()
	deaf.disconnect_from_host()
	_report()

	_http.stop()
	_relay.stop()
	print("\n%s in %.1f s" % ["ALL TESTS PASSED" if _failed == 0 else "%d TEST(S) FAILED" % _failed, (Time.get_ticks_msec() - started) / 1000.0])
	_watchdog.stop()
	quit(1 if _failed > 0 else 0)


func _client() -> RelayClient:
	var c := RelayClient.new()
	_clients.append(c)
	_logs[c] = []
	return c


func _saw(c: RelayClient, kind: String) -> bool:
	return _logs[c].any(func(e: Array) -> bool: return e[0] == kind)


## One turn of everything: the relay, its metrics server and the clients.
func _pump() -> void:
	_relay.poll()
	var t := Time.get_ticks_usec()
	_http.poll()
	_slowest_poll = maxi(_slowest_poll, Time.get_ticks_usec() - t)
	for c in _clients:
		_logs[c].append_array(c.poll())


## Keep everything turning until `cond` holds, up to `msec`.
func _until(cond: Callable, msec := 3000) -> bool:
	var end := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < end:
		_pump()
		if cond.call():
			return true
		OS.delay_msec(1)
	return false


## Connect to the metrics server and send `request` (nothing, if it's "").
func _connect(request: String) -> StreamPeerTCP:
	var tcp := StreamPeerTCP.new()
	tcp.connect_to_host(AT, _http.port())
	_until(func() -> bool:
		tcp.poll()
		return tcp.get_status() != StreamPeerTCP.STATUS_CONNECTING)
	if request != "":
		tcp.put_data(request.to_utf8_buffer())
	return tcp


## Send `request` and return everything that comes back before the server
## hangs up.
func _fetch(request: String) -> String:
	var tcp := _connect(request)
	var got := PackedByteArray()
	_until(func() -> bool:
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return true
		if tcp.get_available_bytes() > 0:
			got.append_array(tcp.get_partial_data(tcp.get_available_bytes())[1])
		return false)
	return got.get_string_from_utf8()


func _body(response: String) -> String:
	var at := response.find("\r\n\r\n")
	return response.substr(at + 4) if at >= 0 else ""


## The value on the line for this metric (with its labels), or -1.
func _value(text: String, metric: String) -> float:
	for line in text.split("\n"):
		if line.begins_with(metric + " "):
			return float(line.substr(metric.length() + 1))
	return -1.0


## The text must be what Prometheus reads: every sample a known metric with a
## number, nothing twice, and histograms that add up.
func _check_format(text: String) -> void:
	var sample := RegEx.create_from_string("^([a-zA-Z_:][a-zA-Z0-9_:]*)(\\{(?:[a-zA-Z_][a-zA-Z0-9_]*=\"(?:[^\"\\\\\\n]|\\\\[\\\\\"n])*\",?)*\\})? (-?[0-9]+(?:\\.[0-9]+)?(?:e[-+]?[0-9]+)?)$")
	var types := {} # metric -> type
	var helped := {}
	var seen := {}
	var last_bucket := {} # series without le -> its last bucket's count
	_check(text.ends_with("\n"), "the text should end with a newline")
	for line in text.trim_suffix("\n").split("\n"):
		if line.begins_with("# HELP "):
			helped[line.get_slice(" ", 2)] = true
		elif line.begins_with("# TYPE "):
			_check(not types.has(line.get_slice(" ", 2)), "%s is described twice" % line.get_slice(" ", 2))
			types[line.get_slice(" ", 2)] = line.get_slice(" ", 3)
		else:
			var m := sample.search(line)
			if m == null:
				_check(false, "not a sample line: %s" % line)
				continue
			var name := m.get_string(1)
			var series := name + m.get_string(2)
			_check(not seen.has(series), "%s appears twice" % series)
			seen[series] = true
			var family := name
			for suffix: String in ["_bucket", "_sum", "_count"]:
				if name.ends_with(suffix) and types.get(name.trim_suffix(suffix)) == "histogram":
					family = name.trim_suffix(suffix)
			_check(types.has(family) and helped.has(family), "%s has no TYPE and HELP before it" % name)
			if types.get(family) == "counter":
				_check(name.ends_with("_total"), "counter %s should end in _total" % name)
			if name.ends_with("_bucket"):
				var le := RegEx.create_from_string(",?le=\"([^\"]+)\"").search(series)
				var key := series.replace(le.get_string(0), "").trim_suffix("{}")
				var n := float(m.get_string(3))
				_check(n >= last_bucket.get(key, 0.0), "%s goes down" % series)
				last_bucket[key] = n
				if le.get_string(1) == "+Inf":
					last_bucket[key + " total"] = n
			elif name.ends_with("_count") and family != name:
				var key := (family + "_bucket" + m.get_string(2)).trim_suffix("{}")
				_check(last_bucket.get(key + " total", -1.0) == float(m.get_string(3)), "%s isn't its +Inf bucket" % series)


var _ok_before := 0
var _section_from := Time.get_ticks_msec()
func _report() -> void:
	var now := Time.get_ticks_msec()
	print("%s  %5.1f s  %s" % ["ok  " if _failed == _ok_before else "FAIL", (now - _section_from) / 1000.0, _current])
	_ok_before = _failed
	_section_from = now


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failed += 1
		print("      %s: %s" % [_current, what])
