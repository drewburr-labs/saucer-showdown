extends SceneTree
## Online play over loopback: a host and two clients in one process, each a
## full game with scripted "players". Checks that every machine's sim agrees
## on every tick, through a late join, a new map, a player leaving and a
## mismatched build being turned away; and that the lobby handles names,
## teams, team sizes, a full room and coming back after a match. Runs in real
## time, about 25 s.
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
	_current = "starts at the menus, local play from there"
	var solo := _game(7)
	await physics_frame
	_check(not solo.in_match and solo._menu.page() == "home", "the game should open on the home screen (%s)" % solo._menu.page())
	solo.start_local(2)
	await _settle()
	_check(solo.in_match and solo.sim.greys_per_team == 2 and not solo._menu.is_open(), "Play local should start a 3v3 with the menus out of the way")
	_check(solo.humans.size() == 1, "player 1 should have a seat")
	_report()

	_current = "offline win: banner, score, next map"
	await physics_frame # so the win lands right before the game's own tick
	solo.sim._win(0, Sim.Win.ECONOMIC)
	await physics_frame
	_check(solo.win_confirmed and solo.map_wins == [1, 0], "a win should count at once offline (%s)" % [solo.map_wins])
	var solo_epoch: int = solo._epoch
	_check(await _until(func() -> bool: return solo._epoch > solo_epoch, 4.0), "a press after the banner starts the next map")
	_check(not solo.win_confirmed and solo.map_wins == [1, 0], "the next map starts clean, score kept")
	_report()

	_current = "offline match won: back to the local menu"
	solo.sim._win(0, Sim.Win.MILITARY)
	await physics_frame
	_check(solo.match_winner == 0, "a second map win takes the match")
	_check(await _until(func() -> bool: return not solo.in_match, 4.0), "a press after the banner ends the match")
	await _settle()
	_check(solo._menu.page() == "local", "and goes back to local setup (%s)" % solo._menu.page())
	solo.queue_free()
	_report()

	var host := _game(1, "Hana")
	var c1 := _game(2, "Cleo")
	await physics_frame
	_check(host.host_lan(PORT) == "", "host should start")
	_check(c1.join("127.0.0.1:%d" % PORT) == "", "client should start connecting")

	_current = "client joins the lobby, host starts, they play"
	_check(await _until(func() -> bool: return c1.in_lobby and c1.lobby.size() == 2, 8.0), "client should reach the lobby within 8 s")
	_check(not c1.in_match and not host.in_match, "nobody plays until the host starts")
	_check(host._name_of(c1.net.id()) == "Cleo" and c1._name_of(1) == "Hana", "both should see each other's names")
	await _settle()
	_check(c1._menu.page() == "lobby" and host._menu.page() == "lobby", "both should be looking at the lobby")
	host.start_match()
	_check(await _until(func() -> bool: return c1._started and c1.sim.tick > 240, 8.0), "client should be playing within 8 s")
	var key1 := "%d:kb1" % c1.net.id()
	_check(host.humans.has(key1), "the client's keyboard should have a seat")
	_check(c1.you == "Cleo", "the client's unit should carry its name (%s)" % c1.you)
	var unit_id: int = host._unit_of(key1).id
	_check(await _until(func() -> bool: return host.sim.units[unit_id].in_move != Vector2.ZERO, 2.0),
			"the client's input should drive its unit on the host")
	_check_sync(host, c1, 200)
	_report()

	_current = "second client joins mid-map"
	var c2 := _game(3, "Dax")
	await physics_frame
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
	_check(c1.role == Main.Role.OFFLINE and not c1.in_match, "the leaver is back at the menus")
	_check(host._name_of(int(key1.get_slice(":", 0))) == "" and host.lobby.size() == 2, "and out of the host's lobby (%d)" % host.lobby.size())
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
	c4.join("127.0.0.1:%d" % (PORT + 1))
	_check(await _until(func() -> bool: return c4.in_lobby and h2.lobby.size() == 2, 8.0), "client should reach the lobby")
	h2.start_match()
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

	await _lobby_tests()

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
	_check(rc.join(rh.room_code.to_lower()) == "", "joining by code should start (any case)")
	_check(await _until(func() -> bool: return rc.in_lobby and rc.lobby.size() == 2, 8.0), "friend should reach the lobby")
	_check(rc.room_code == rh.room_code, "and know the room code to show")
	rh.start_match()
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


func _lobby_tests() -> void:
	_current = "lobby: joiners are spread over the teams"
	var lh := _game(20, "Host")
	var la := _game(21, "Ann")
	var lb := _game(22, "Bo")
	await physics_frame
	lh.host_lan(PORT + 4)
	var at := "127.0.0.1:%d" % (PORT + 4)
	la.join(at)
	_check(await _until(func() -> bool: return la.in_lobby, 6.0), "Ann should get in")
	lb.join(at)
	_check(await _until(func() -> bool: return lb.in_lobby and la.lobby.size() == 3, 6.0), "Bo should get in, and Ann should see him")
	_check(_teams(lh) == [0, 1, 0], "teams should alternate as people join (%s)" % [_teams(lh)])
	_check(_teams(la) == _teams(lh) and _teams(lb) == _teams(lh), "everyone sees the same teams")
	_report()

	_current = "lobby: players pick teams, a full team says no"
	_check(la.pick_team(0).contains("full"), "2v2: a third player can't join a team of two")
	lb.pick_team(1)
	_check(await _until(func() -> bool: return _teams(la) == [0, 1, 1], 3.0), "Bo's switch should reach everyone (%s)" % [_teams(la)])
	lh.pick_team(1)
	await _frames(20)
	_check(_teams(lh) == [0, 1, 1], "the host can't overfill a team either (%s)" % [_teams(lh)])
	lb.set_player_name("Bobo", false)
	_check(await _until(func() -> bool: return la._name_of(lb.net.id()) == "Bobo", 3.0), "a rename should reach everyone")
	_report()

	_current = "lobby: the room fills up and says so"
	var lc := _game(23, "Cy")
	var ld := _game(24, "Di")
	await physics_frame
	lc.join(at)
	_check(await _until(func() -> bool: return lc.in_lobby and lh.lobby.size() == 4, 6.0), "a fourth player fits a 2v2")
	ld.join(at)
	_check(await _until(func() -> bool: return ld.role == Main.Role.OFFLINE, 6.0), "a fifth is turned away")
	_check(ld.notice.contains("full"), "and told the room is full (%s)" % ld.notice)
	_check(lh.lobby.size() == 4, "the room still holds four")
	_report()

	_current = "lobby: the host picks the team size"
	_check(la.set_team_size(2) == "" and la.greys_per_team == 1, "only the host can change it")
	_check(lh.set_team_size(2) == "", "4 players fit a 3v3")
	_check(await _until(func() -> bool: return la.greys_per_team == 2 and lc.greys_per_team == 2, 3.0), "everyone sees 3v3")
	ld.join(at)
	_check(await _until(func() -> bool: return ld.in_lobby and lh.lobby.size() == 5, 6.0), "now a fifth fits")
	_check(lh.set_team_size(1).contains("won't fit"), "and the host can't shrink below five players")
	_check(lh.greys_per_team == 2, "so it stays 3v3")
	_report()

	_current = "lobby: the match uses the lobby's teams, then everyone comes back"
	lh.start_match()
	var all := [la, lb, lc, ld]
	_check(await _until(func() -> bool: return all.all(func(g) -> bool: return g._started and g.sim.tick > 60), 6.0), "everyone should be in the match")
	_check(lh.sim.greys_per_team == 2 and la.sim.greys_per_team == 2, "it should be a 3v3")
	var teams_ok := true
	for e: Dictionary in lh.lobby:
		var key := "%d:kb1" % e["id"]
		if not lh.humans.has(key) or lh.humans[key]["team"] != e["team"]:
			teams_ok = false
	_check(teams_ok, "everyone plays for the team they picked")
	await _settle()
	_check(la._menu.page() == "", "the lobby gets out of the way")
	var before: Array = _teams(lh)
	lh.map_wins = [0, 1]
	# A rollback can undo a win written straight into the sim, so keep writing it.
	_check(await _until(func() -> bool:
		if lh.sim.winner < 0:
			lh.sim._win(1, Sim.Win.TRACTOR)
		return lh.match_winner == 1, 3.0), "the host's win should decide the match")
	_check(await _until(func() -> bool: return not lh.in_match and all.all(func(g) -> bool: return not g.in_match and g.in_lobby), 6.0),
			"after the banner everyone goes back to the lobby")
	await _settle()
	_check(all.all(func(g) -> bool: return g._menu.page() == "lobby"), "and sees it")
	_check(_teams(lh) == before and lh.lobby.size() == 5, "with the same players on the same teams")
	lh.start_match()
	_check(await _until(func() -> bool: return all.all(func(g) -> bool: return g._started and g.sim.tick > 60), 6.0), "and the host can start the next match")
	_check_sync(lh, la, 40)
	_report()

	_current = "lobby: someone leaves mid-match, then the host closes the room"
	var left: int = lc.net.id()
	lc.leave()
	_check(await _until(func() -> bool: return la.lobby.size() == 4 and la._name_of(left) == "", 4.0), "the leaver should drop off everyone's lobby")
	lh.leave()
	_check(await _until(func() -> bool: return all.all(func(g) -> bool: return g.role == Main.Role.OFFLINE), 6.0), "closing the room sends everyone home")
	await _settle()
	_check(la._menu.page() == "online", "back on the Play online page (%s)" % la._menu.page())
	_report()
	for g in [lh, la, lb, lc, ld]:
		g.queue_free()
	await process_frame


func _teams(g: Node) -> Array:
	var out := []
	for e: Dictionary in g.lobby:
		out.append(e["team"])
	return out


## Let the menus catch up: several physics steps can run before one _process.
func _settle() -> void:
	for i in 3:
		await process_frame


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _game(p_seed: int, name := "") -> Node:
	var g = load("res://main.tscn").instantiate()
	root.add_child(g)
	g._input = ScriptedInput.new(p_seed)
	g.record_sums = true
	g.show_help = false
	if name != "":
		g.player_name = name
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
