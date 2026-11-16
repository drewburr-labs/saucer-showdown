extends SceneTree
## The menus with nothing but a gamepad: every enabled control on every page
## can be reached by moving focus, pages open and close with A, B and Start,
## LB / RB switch settings tabs, the on-screen keyboard types into text
## fields, and lost focus comes back on the next press. Uses a scratch
## settings file, so the player's own settings are never touched.
##   godot --headless --path . --script tests/test_menus.gd

const Watchdog = preload("res://tests/watchdog.gd")
const Settings = preload("res://scripts/settings.gd")
const Updater = preload("res://scripts/update/updater.gd")

const SCRATCH := "user://test_menus_settings.cfg"
const SIDES := [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]


## An updater that says it's on, so the home screen shows its button.
class FakeUpdater extends Updater:
	func enabled() -> bool:
		return true


## Fails the run, saying where it was, if it takes longer than this; a normal
## run takes about 2 s.
const TIME_LIMIT := 10

var _failed := 0
var _last := "" # the last check, for the watchdog to name
var _watchdog: Watchdog
var g: Node
var m: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_watchdog = Watchdog.new(TIME_LIMIT, func() -> String: return "after the check \"%s\"" % _last)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))
	Settings.path = SCRATCH
	Settings._cfg = null
	Settings._keys.clear()
	g = load("res://main.tscn").instantiate()
	root.add_child(g)
	m = g._menu
	await _frames(3)

	print("home")
	_check(m.page() == "home" and _focus_text() == "Play online", "opens on Play online")
	_reachable("home")
	var fake := FakeUpdater.new()
	fake.state = Updater.State.AVAILABLE
	fake.latest = "v9.9.9"
	var real = g.updater
	g.updater = fake
	await _frames(2)
	_check(m._update_btn.visible and m._update_btn.text == "Install update v9.9.9", "update button offers the update")
	_reachable("home", "with the update button")
	g.updater = real
	fake.free()
	await _frames(2)
	_check(not m._update_btn.visible, "and isn't there in a dev build")

	print("play local")
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_A)
	_check(m.page() == "local", "A on Play local opens it")
	_check(_focus_text() == "Start match", "focus starts on Start match")
	_reachable("local")
	_check(m._role_btns[0].button_pressed and not m._role_btns[1].button_pressed, "the Overlord is picked to start with")
	m._role_btns[1].grab_focus()
	await _pad(JOY_BUTTON_A)
	_check(Settings.value("role") == g.GREY and m._role_btns[1].button_pressed and not m._role_btns[0].button_pressed,
			"A on Grey picks it, and only it")
	_check(m._local_blurb.text.contains("a Grey"), "the page says you'll play a Grey")
	await _pad(JOY_BUTTON_B)
	_check(m.page() == "home" and _focus_text() == "Play online", "B goes home")

	print("play online, and the on-screen keyboard")
	await _pad(JOY_BUTTON_A)
	_check(m.page() == "online", "A on Play online opens it")
	_reachable("online")
	m._online_name.grab_focus()
	await _pad(JOY_BUTTON_A)
	_check(m._keyboard.is_open(), "A on the name field opens the keyboard")
	_check(m._keyboard._title.text == "YOUR NAME", "headed YOUR NAME")
	_reachable_keyboard()
	await _pad(JOY_BUTTON_A) # Q
	await _pad(JOY_BUTTON_Y) # lower case
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	await _pad(JOY_BUTTON_A) # w
	await _pad(JOY_BUTTON_A) # w
	await _pad(JOY_BUTTON_X) # delete
	_check(m._online_name.text == "Qw", "typed Qw (got %s)" % m._online_name.text)
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	_check(_focus_text() == "Space", "down to the bottom row, then right, reaches Space")
	await _pad(JOY_BUTTON_A)
	_check(m._online_name.text == "Qw ", "Space types a space")
	await _pad(JOY_BUTTON_X)
	_check(g.player_name == "Qw", "the name follows as it's typed")
	await _pad(JOY_BUTTON_START)
	_check(not m._keyboard.is_open(), "Start finishes")
	_check(m.page() == "online", "and stays on the page")
	_check(m.get_viewport().gui_get_focus_owner() == m._online_name, "focus goes back to the field")
	m._code.grab_focus()
	await _pad(JOY_BUTTON_A)
	_check(m._keyboard.is_open() and m._keyboard._title.text == "ROOM CODE", "the code field opens it as ROOM CODE")
	await _pad(JOY_BUTTON_A)
	_check(m._code.text == "Q", "typed into the code")
	await _pad(JOY_BUTTON_B)
	_check(not m._keyboard.is_open() and m._code.text == "", "B cancels and puts the text back")
	_check(m.page() == "online", "B on the keyboard doesn't also leave the page")
	await _pad(JOY_BUTTON_B)
	_check(m.page() == "home", "a second B goes home")

	print("settings")
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_A)
	_check(m.page() == "settings", "A on Settings opens it")
	var tabs: TabContainer = m._settings._tabs
	for i in tabs.get_tab_count():
		_check(tabs.current_tab == i, "on tab %d" % i)
		_reachable("settings", tabs.get_tab_title(i))
		await _pad(JOY_BUTTON_RIGHT_SHOULDER)
	_check(tabs.current_tab == 0, "RB wraps round to the first tab")
	await _pad(JOY_BUTTON_LEFT_SHOULDER)
	_check(tabs.current_tab == tabs.get_tab_count() - 1, "LB goes back")
	_check(m.get_viewport().gui_get_focus_owner() == tabs.get_tab_bar(), "the tab bar has focus after a switch")
	await _pad(JOY_BUTTON_B)
	_check(m.page() == "home", "B leaves settings")

	print("lost focus comes back")
	m.get_viewport().gui_release_focus()
	await _pad(JOY_BUTTON_DPAD_DOWN)
	_check(_focus_text() == "Play online", "first press refocuses the page instead of being lost")

	print("in-game menu")
	g.start_local(1)
	await _frames(3)
	_check(g.humans["1:kb1"]["idx"] == 1, "the match puts you on a Grey, as picked")
	await _pad(JOY_BUTTON_START)
	_check(m.page() == "pause" and _focus_text() == "Resume", "Start opens it on Resume")
	_reachable("pause")
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_DPAD_DOWN)
	_check(_focus_text() == "Show controls", "Show controls is after Restart")
	await _pad(JOY_BUTTON_A)
	_check(m.page() == "" and g.show_help, "it shows the controls and resumes")
	await _pad(JOY_BUTTON_START)
	_check(m._pause_btns["help"].text == "Hide controls", "then offers to hide them")
	await _pad(JOY_BUTTON_B)
	_check(m.page() == "", "B resumes")
	g.end_match()
	await _frames(3)

	print("lobby")
	g.host_lan(_free_port())
	await _frames(3)
	_check(m.page() == "lobby", "hosting opens the lobby")
	_check(g.my_entry().get("role") == g.OVERLORD, "the host starts as Zeta's Overlord")
	_reachable("lobby")
	var seat: Button = _first_seat(1)
	_check(seat != null and seat.text.begins_with("Overlord"), "Kepler's open Overlord seat is a button")
	seat.grab_focus()
	await _pad(JOY_BUTTON_A)
	await _frames(2)
	_check(g.my_entry().get("team") == 1 and g.my_entry().get("role") == g.OVERLORD, "A on it takes it")
	var owner := m.get_viewport().gui_get_focus_owner()
	_check(owner != null and owner.is_visible_in_tree() and m._team_lists[1].is_ancestor_of(owner), "focus lands on Kepler's open Grey seat")
	await _pad(JOY_BUTTON_A)
	await _frames(2)
	_check(g.my_entry().get("team") == 1 and g.my_entry().get("role") == g.GREY, "and A again takes that")
	_reachable("lobby", "after moving")
	m._lobby_name.grab_focus()
	await _pad(JOY_BUTTON_A)
	await _pad(JOY_BUTTON_A) # Q
	await _pad(JOY_BUTTON_START)
	_check(g.player_name == "QwQ", "lobby name typed and kept (got %s)" % g.player_name)
	_check(m.get_viewport().gui_get_focus_owner() == m._lobby_name, "focus stays on the field after Done")
	g.leave()
	await _frames(3)

	g.queue_free()
	await _frames(2)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))
	print("ALL TESTS PASSED" if _failed == 0 else "%d FAILED" % _failed)
	_watchdog.stop()
	quit(1 if _failed > 0 else 0)


## The first open seat button in a lobby team's list.
func _first_seat(team: int) -> Button:
	for c in m._team_lists[team].get_children():
		if c is Button:
			return c
	return null


## Every enabled, focusable control on the page can be reached from the
## focused one by moving up, down, left and right.
func _reachable(page: String, what := "") -> void:
	var start: Control = m.get_viewport().gui_get_focus_owner()
	var want := _usable_in(m._pages[page])
	var seen := _walk(start)
	var missing := PackedStringArray()
	for c in want:
		if not seen.has(c):
			missing.append(_name(c))
	_check(start != null and missing.is_empty(), "all %d controls reachable %s%s" % [
			want.size(), what, (": missing " + ", ".join(missing)) if not missing.is_empty() else ""])


func _reachable_keyboard() -> void:
	var want := _usable_in(m._keyboard)
	var seen := _walk(m.get_viewport().gui_get_focus_owner())
	var outside := 0
	for c: Control in seen:
		if not m._keyboard.is_ancestor_of(c):
			outside += 1
	_check(seen.size() == want.size() and outside == 0, "every key reachable, and nothing behind it (%d of %d, %d outside)" % [
			seen.size(), want.size(), outside])


func _walk(start: Control) -> Dictionary:
	var seen := {}
	if start == null:
		return seen
	var todo: Array[Control] = [start]
	seen[start] = true
	while not todo.is_empty():
		var c: Control = todo.pop_back()
		for side in SIDES:
			var n := c.find_valid_focus_neighbor(side)
			if n != null and not seen.has(n):
				seen[n] = true
				todo.append(n)
	return seen


func _usable_in(n: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child in n.get_children(true):
		if child is Control and m._usable(child):
			out.append(child)
		out.append_array(_usable_in(child))
	return out


func _name(c: Control) -> String:
	if c is Button:
		return "%s \"%s\"" % [c.get_class(), c.text]
	return c.get_class()


func _focus_text() -> String:
	var f := m.get_viewport().gui_get_focus_owner()
	return f.text if f is Button else (_name(f) if f != null else "")


func _pad(b: JoyButton) -> void:
	for down in [true, false]:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		e.pressed = down
		Input.parse_input_event(e)
		Input.flush_buffered_events()
	await _frames(2)


## A UDP port nothing is using, so two runs at once don't collide.
static func _free_port() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for attempt in 50:
		var port := rng.randi_range(20000, 40000)
		var u := PacketPeerUDP.new()
		var ok := u.bind(port) == OK
		u.close()
		if ok:
			return port
	return 24711


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _check(cond: bool, what: String) -> void:
	_last = what
	print("  %s  %s" % ["ok  " if cond else "FAIL", what])
	if not cond:
		_failed += 1
