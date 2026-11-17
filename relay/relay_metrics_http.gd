extends RefCounted
## A very small HTTP server for the relay's metrics, on a TCP port of its own
## so it can stay private while the game's UDP port faces the internet:
##   GET /metrics   the relay's numbers, as Prometheus text
##   GET /healthz   "ok", for a liveness check
## It never blocks: poll() does what it can and returns, so a slow or silent
## client can't hold up the games. Each connection gets one reply and
## deadline_msec to ask for it and take it.

const MAX_CONNECTIONS := 16
const MAX_REQUEST := 8192

var deadline_msec := 5000

var _server: TCPServer
var _text: Callable # () -> String, the body for /metrics
var _open: Array = [] # [StreamPeerTCP, request so far, reply left to send, when to give up]


func start(port: int, bind: String, text: Callable) -> Error:
	_text = text
	_server = TCPServer.new()
	var err := _server.listen(port, bind)
	if err != OK:
		_server = null
	return err


## The port it's listening on (start() with port 0 takes any free one).
func port() -> int:
	return _server.get_local_port() if _server != null else 0


func stop() -> void:
	for c: Array in _open:
		c[0].disconnect_from_host()
	_open.clear()
	if _server != null:
		_server.stop()
	_server = null


func poll() -> void:
	if _server == null:
		return
	var now := Time.get_ticks_msec()
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if _open.size() >= MAX_CONNECTIONS:
			peer.disconnect_from_host()
		else:
			_open.append([peer, PackedByteArray(), PackedByteArray(), now + deadline_msec])
	for i in range(_open.size() - 1, -1, -1):
		if not _serve(_open[i], now):
			_open[i][0].disconnect_from_host()
			_open.remove_at(i)


## Move one connection along. False once it's finished with, either way.
func _serve(c: Array, now: int) -> bool:
	var peer: StreamPeerTCP = c[0]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or now > c[3]:
		return false
	if c[2].is_empty():
		var waiting := peer.get_available_bytes()
		if waiting <= 0:
			return true
		var got: Array = peer.get_partial_data(mini(waiting, MAX_REQUEST + 1 - c[1].size()))
		if got[0] != OK:
			return false
		c[1].append_array(got[1])
		var request: String = c[1].get_string_from_ascii()
		if request.contains("\r\n\r\n") or request.contains("\n\n"):
			c[2] = _reply(request)
		else:
			return c[1].size() <= MAX_REQUEST # an endless request is hung up on
	var sent: Array = peer.put_partial_data(c[2])
	if sent[0] != OK:
		return false
	c[2] = c[2].slice(sent[1])
	return not c[2].is_empty()


func _reply(request: String) -> PackedByteArray:
	var first := request.get_slice("\n", 0).strip_edges().split(" ", false)
	if first.size() < 2:
		return _response("400 Bad Request", "bad request\n")
	if first[0] != "GET":
		return _response("405 Method Not Allowed", "only GET\n")
	match first[1].get_slice("?", 0):
		"/metrics":
			return _response("200 OK", _text.call(), "text/plain; version=0.0.4; charset=utf-8")
		"/healthz":
			return _response("200 OK", "ok\n")
	return _response("404 Not Found", "try /metrics\n")


static func _response(status: String, body: String, type := "text/plain; charset=utf-8") -> PackedByteArray:
	var bytes := body.to_utf8_buffer()
	var out := ("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, type, bytes.size()]).to_utf8_buffer()
	out.append_array(bytes)
	return out
