extends SceneTree
## Online play over loopback: a host and two clients in one process, each a
## full game with scripted "players". Checks that every machine's sim agrees
## on every tick, through a late join, a new map, a player leaving and a
## mismatched build being turned away. Runs in real time, about 15 s.
##   godot --headless --path . --script tests/test_net.gd

const Main = preload("res://scripts/main.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const RelayServer = preload("res://relay/relay_server.gd")
const LocalInput = preload("res://scripts/input/local_input.gd")

const PORT := 24690


## Runs a relay server inside the test, polled every physics frame.
class RelayNode extends Node:
	var relay: RelayServer

	func _physics_process(_delta: float) -> void:
		relay.poll()


## Plays kb1 like a restless human: a new random move and buttons every few ticks.
class ScriptedInput extends LocalInput:
	var rng := RandomNumberGenerator.new()
	var held := {}
	var n := 0

	func _init(p_seed: int) -> void:
		super()
		rng.seed = p_seed

	func poll() -> void:
		n += 1
		super()

	func _read(device: String) -> Dictionary:
		var s := _blank()
		if device != "kb1":
			return s
		if n % 9 == 0 or held.is_empty():
			held = {
				"move": Vector2(rng.randi_range(-1, 1), rng.randi_range(-1, 1)),
				"jump": rng.randf() < 0.3, "action": rng.randf() < 0.4, "beam": rng.randf() < 0.3,
			}
		s.merge(held, true)
		return s


var _failed := 0
var _current := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_current = "offline win: banner, score, next map"
	var solo := _game(7)
	await physics_frame
	solo.sim._win(0, Sim.Win.ECONOMIC)
	await physics_frame
	_check(solo.win_confirmed and solo.map_wins == [1, 0], "a win should count at once offline (%s)" % [solo.map_wins])
	var solo_epoch: int = solo._epoch
	_check(await _until(func() -> bool: return solo._epoch > solo_epoch, 4.0), "a press after the banner starts the next map")
	_check(not solo.win_confirmed and solo.map_wins == [1, 0], "the next map starts clean, score kept")
	solo.queue_free()
	_report()

	var host := _game(1)
	var c1 := _game(2)
	await physics_frame
	_check(host.host_lan(PORT) == "", "host should start")
	c1.sums_log.clear() # forget its own offline game
	_check(c1.join("127.0.0.1:%d" % PORT) == "", "client should start connecting")

	_current = "client joins and plays"
	_check(await _until(func() -> bool: return c1._started and c1.sim.tick > 240, 8.0), "client should be playing within 8 s")
	var key1 := "%d:kb1" % c1.net.id()
	_check(host.humans.has(key1), "the client's keyboard should have a seat")
	_check(c1.you != "", "the client should know its label (%s)" % c1.you)
	var unit_id: int = host._unit_of(key1).id
	_check(await _until(func() -> bool: return host.sim.units[unit_id].in_move != Vector2.ZERO, 2.0),
			"the client's input should drive its unit on the host")
	_check_sync(host, c1, 200)
	_report()

	_current = "second client joins mid-map"
	var c2 := _game(3)
	await physics_frame
	c2.sums_log.clear()
	c2.join("127.0.0.1:%d" % PORT)
	_check(await _until(func() -> bool: return c2._started, 8.0), "late joiner should get the match")
	var joined_at: int = c2.sim.tick
	_check(joined_at > 200, "and start from the host's snapshot, not tick 0 (%d)" % joined_at)
	_check(await _until(func() -> bool: return c2.sim.tick > joined_at + 180, 8.0), "late joiner should be playing")
	_check_sync(host, c2, 150)
	_check_sync(host, c1, 400)
	_check(host.waiting_t < 30, "host shouldn't be stuck waiting")
	_report()

	_current = "new map for everyone"
	host._new_map()
	var ep: int = host._epoch
	_check(await _until(func() -> bool: return c1._epoch == ep and c2._epoch == ep and c1.sim.tick > 120 and c2.sim.tick > 120, 5.0), "clients should follow to the new map")
	_check(c1._seed == host._seed and c2._seed == host._seed, "same seed everywhere")
	_check_sync(host, c1, 100)
	_check_sync(host, c2, 100)
	_report()

	_current = "a player leaves"
	var tick_before: int = host.sim.tick
	c1.leave()
	_check(await _until(func() -> bool: return not host.humans.has(key1), 5.0), "host should free the leaver's seat")
	_check(c1.role == Main.Role.OFFLINE, "the leaver is back to a local game")
	_check(await _until(func() -> bool: return host.sim.tick > tick_before + 120, 5.0), "host keeps going without them")
	_check_sync(host, c2, 200)
	_report()

	_current = "a desynced client is put back in step"
	# Corrupt it, rollback history included, so a rewind can't quietly undo it.
	c2.sim.silo[0] += 5
	var scratch := Sim.new(1, c2.greys_per_team)
	for k: int in c2._states:
		scratch.load_state(c2._states[k])
		scratch.silo[0] += 5
		c2._states[k] = scratch.save_state()
	scratch.dispose()
	var fixes: int = host.resyncs
	_check(await _until(func() -> bool: return host.resyncs > fixes, 3.0), "host should spot the bad checksum")
	_check(await _until(func() -> bool: return c2.sim.silo == host.sim.silo, 2.0), "client should get the host's state back")
	c2.sums_log.clear()
	var t_fix: int = c2.sim.tick
	_check(await _until(func() -> bool: return c2.sim.tick > t_fix + 120, 4.0), "and carry on")
	_check_sync(host, c2, 100)
	_check(host.resyncs == fixes + 1, "one resync should be enough (%d)" % (host.resyncs - fixes))
	_report()

	_current = "mismatched build is turned away"
	var c3 := _game(4)
	c3.fingerprint = 12345
	await physics_frame
	c3.join("127.0.0.1:%d" % PORT)
	_check(await _until(func() -> bool: return c3.role == Main.Role.OFFLINE, 5.0), "a different build should be rejected")
	_check(c3.notice.contains("same version"), "and told why (%s)" % c3.notice)
	_check(host.waiting_t < 30, "a rejected client mustn't stall the host")
	_report()

	_current = "host leaves"
	host.leave()
	_check(await _until(func() -> bool: return c2.role == Main.Role.OFFLINE, 8.0), "client should notice the host is gone")
	_report()

	_current = "60 ms each way: predicts, rolls back, stays in step"
	var h2 := _game(5)
	var c4 := _game(6)
	h2.fake_lag_ms = 60
	c4.fake_lag_ms = 60
	await physics_frame
	h2.host_lan(PORT + 1)
	c4.sums_log.clear()
	c4.join("127.0.0.1:%d" % (PORT + 1))
	_check(await _until(func() -> bool: return c4._started, 8.0), "client should get the match")
	var t0: int = h2.sim.tick
	var f0 := Engine.get_physics_frames()
	var most_ahead := 0
	var stalled := 0
	var frames := 0
	var end := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < end:
		await physics_frame
		frames += 1
		most_ahead = maxi(most_ahead, c4.sim.tick - c4._confirmed)
		if h2.waiting_t > 0 or c4.waiting_t > 0:
			stalled += 1
	var pace := float(h2.sim.tick - t0) / float(Engine.get_physics_frames() - f0)
	print("      pace %.2f ticks/frame, client up to %d ticks ahead of confirmed, %d rollbacks, stalled %d of %d frames" % [
			pace, most_ahead, c4.rollbacks, stalled, frames])
	_check(pace > 0.9, "the game should keep real-time pace, not wait on the network (%.2f)" % pace)
	_check(most_ahead >= 3, "the client should be predicting ahead of confirmed frames (%d)" % most_ahead)
	_check(c4.rollbacks > 10, "wrong guesses should have been rolled back (%d)" % c4.rollbacks)
	_check(stalled < frames / 10, "stalls should be rare (%d of %d frames)" % [stalled, frames])
	_check_sync(h2, c4, 250)
	_check(h2.resyncs == 0, "no desyncs (%d resyncs)" % h2.resyncs)
	_report()

	for g in [host, c1, c2, c3, h2, c4]:
		g.queue_free()
	await process_frame

	_current = "relay: host gets a room code, a friend joins with it"
	var relay_node := RelayNode.new()
	relay_node.relay = RelayServer.new()
	relay_node.relay.quiet = true
	_check(relay_node.relay.start(PORT + 2, "127.0.0.1") == OK, "relay should start")
	root.add_child(relay_node)
	var relay_at := "127.0.0.1:%d" % (PORT + 2)
	var rh := _game(8)
	var rc := _game(9)
	for g in [rh, rc]:
		g.relay_address = relay_at
		g.fake_lag_ms = 30
	await physics_frame
	_check(rh.host() == "", "hosting through the relay should start")
	_check(await _until(func() -> bool: return rh.room_code.length() == 5, 4.0), "host should get a room code (%s)" % rh.room_code)
	rc.sums_log.clear()
	_check(rc.join(rh.room_code.to_lower()) == "", "joining by code should start (any case)")
	_check(await _until(func() -> bool: return rc._started and rc.sim.tick > 300, 8.0), "friend should be playing through the relay")
	_check(rh.humans.has("%d:kb1" % rc.net.id()), "friend should have a seat")
	_check(rc.ping_ms >= 60, "ping should be the real round trip through the relay, fake lag included (%d ms)" % rc.ping_ms)
	_check(rc.net_status.contains(rh.room_code), "friend's status names the room (%s)" % rc.net_status)
	_check(rh.net_status.contains("1 joined"), "host's status counts the friend (%s)" % rh.net_status)
	_check_sync(rh, rc, 250)
	_check(rh.resyncs == 0, "no desyncs through the relay")
	_report()

	_current = "relay: wrong code is refused"
	var rx := _game(10)
	rx.relay_address = relay_at
	await physics_frame
	rx.join("ZZZZZ")
	_check(await _until(func() -> bool: return rx.role == Main.Role.OFFLINE, 4.0), "a wrong code should be turned down")
	_check(rx.notice.contains("No game with the code ZZZZZ"), "and say so (%s)" % rx.notice)
	_report()

	_current = "relay: host leaving ends the room"
	rh.leave()
	_check(await _until(func() -> bool: return rc.role == Main.Role.OFFLINE, 4.0), "the friend should be sent home")
	_check(rc.notice.contains("host closed"), "and told why (%s)" % rc.notice)
	_check(await _until(func() -> bool: return relay_node.relay.room_count() == 0, 2.0), "the relay should drop the room")
	_report()

	_current = "relay: unreachable relay"
	var rz := _game(11)
	rz.relay_address = "127.0.0.1:%d" % (PORT + 3) # nothing listens here
	await physics_frame
	rz.host()
	_check(await _until(func() -> bool: return rz.role == Main.Role.OFFLINE, 12.0), "hosting should give up")
	_check(rz.notice.contains("relay server"), "and say the relay is unreachable (%s)" % rz.notice)
	_report()

	for g in [rh, rc, rx, rz]:
		g.queue_free()
	relay_node.relay.stop()
	relay_node.queue_free()
	await process_frame
	print("\n%s" % ("ALL TESTS PASSED" if _failed == 0 else "%d TEST(S) FAILED" % _failed))
	quit(1 if _failed > 0 else 0)


func _game(p_seed: int) -> Node:
	var g = load("res://main.tscn").instantiate()
	root.add_child(g)
	g._input = ScriptedInput.new(p_seed)
	g.record_sums = true
	g.show_help = false
	return g


## Wait (in real time) until `cond` holds, up to `timeout` seconds.
func _until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


## Every tick both games simulated in this epoch must have the same checksum.
func _check_sync(a: Node, b: Node, at_least: int) -> void:
	var common := 0
	var bad := ""
	var prefix := "%d:" % a._epoch
	for k: String in b.sums_log:
		if k.begins_with(prefix) and a.sums_log.has(k):
			common += 1
			if a.sums_log[k] != b.sums_log[k] and bad == "":
				bad = k
	_check(bad == "", "sims disagree at epoch:tick %s" % bad)
	_check(common >= at_least, "only %d ticks to compare, wanted %d" % [common, at_least])


var _ok_before := 0
func _report() -> void:
	print("%s  %s" % ["ok  " if _failed == _ok_before else "FAIL", _current])
	_ok_before = _failed


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failed += 1
		print("      %s: %s" % [_current, what])
