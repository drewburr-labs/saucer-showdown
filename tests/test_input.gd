extends SceneTree
## Gamepad bindings: the defaults, a faked gamepad read through them,
## rebinding on the settings page with a gamepad, and the F1 help naming
## whatever is bound. Uses a scratch settings
## file, so the player's own settings are never touched.
##   godot --headless --path . --script tests/test_input.gd

const Watchdog = preload("res://tests/watchdog.gd")
const Settings = preload("res://scripts/settings.gd")
const LocalInput = preload("res://scripts/input/local_input.gd")
const SettingsPage = preload("res://scripts/ui/settings_page.gd")
const Hud = preload("res://scripts/view/hud.gd")

const SCRATCH := "user://test_input_settings.cfg"
const PAD := 0

## Fails the run, saying where it was, if it takes longer than this; a normal
## run takes under a second.
const TIME_LIMIT := 10

var _failed := 0
var _last := "" # the last check, for the watchdog to name
var _watchdog: Watchdog


## Godot can't fake a connected gamepad, so this one says pad 0 is plugged in;
## its buttons and axes come from the events the test sends.
class FakePad extends LocalInput:
	func _connected(id: int) -> bool:
		return id == PAD


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_watchdog = Watchdog.new(TIME_LIMIT, func() -> String: return "after the check \"%s\"" % _last)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))
	Settings.path = SCRATCH
	Settings._cfg = null
	Settings._keys.clear()

	print("defaults")
	_check(Settings.key_names("pad", Settings.keys("pad", "action")) == "X / RT", "fire is X / RT")
	_check(Settings.key_names("pad", Settings.keys("pad", "beam")) == "B / RB", "beam is B / RB")
	_check(Settings.key_names("kb1", Settings.keys("kb1", "jump")) == "Space / W", "keyboard names unchanged")

	print("a gamepad reads through its bindings")
	var input := FakePad.new()
	_button(JOY_BUTTON_A, true)
	_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_button(JOY_BUTTON_DPAD_LEFT, true)
	input.poll()
	var s := input.state("pad0")
	_check(s["jump"] and s["join"], "A jumps and joins")
	_check(s["action"], "right trigger fires")
	_check(s["move"].x < -0.9, "d-pad left moves left")
	_check(not s["beam"] and not s["swap"], "nothing else held")
	_button(JOY_BUTTON_A, false)
	_axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	_button(JOY_BUTTON_DPAD_LEFT, false)

	print("rebinding with a gamepad on the settings page")
	var page := SettingsPage.new()
	root.add_child(page)
	page.open()
	page._start_rebind("pad.jump")
	_check(page._key_btns["pad.jump"].text == "Press a button…", "cell waits for a button")
	_axis(JOY_AXIS_LEFT_X, -1.0) # a stick nudge binds nothing
	_check(page._rebinding == "pad.jump", "stick doesn't bind")
	_key(KEY_Q) # nor does a key, on a gamepad cell
	_check(page._rebinding == "pad.jump", "key doesn't bind a gamepad cell")
	_button(JOY_BUTTON_Y, true)
	_button(JOY_BUTTON_Y, false)
	_check(page._rebinding == "", "a button finishes it")
	_check(Settings.keys("pad", "jump") == [JOY_BUTTON_Y], "jump is now Y")
	_check(page._key_btns["pad.jump"].text == "Y", "cell shows Y")

	page._start_rebind("pad.beam")
	_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)
	_axis(JOY_AXIS_TRIGGER_LEFT, 0.0)
	_check(Settings.keys("pad", "beam") == [Settings.PAD_LT], "a trigger binds")

	page._start_rebind("pad.swap")
	_button(JOY_BUTTON_START, true)
	_button(JOY_BUTTON_START, false)
	_check(page._rebinding == "", "Start cancels")
	_check(Settings.keys("pad", "swap") == [JOY_BUTTON_Y], "cancelled cell keeps its binding")

	page._start_rebind("kb1.jump")
	_button(JOY_BUTTON_X, true)
	_button(JOY_BUTTON_X, false)
	_check(page._rebinding == "kb1.jump", "a button doesn't bind a keyboard cell")
	_key(KEY_E)
	_check(Settings.keys("kb1", "jump") == [KEY_E], "a key does")

	print("the new bindings drive the gamepad, and survive a reload")
	Settings._cfg = null
	Settings._keys.clear()
	_check(Settings.keys("pad", "jump") == [JOY_BUTTON_Y], "saved")
	_button(JOY_BUTTON_A, true)
	input.poll()
	_check(not input.state("pad0")["jump"], "A no longer jumps")
	_button(JOY_BUTTON_A, false)
	_button(JOY_BUTTON_Y, true)
	input.poll()
	_check(input.state("pad0")["jump"], "Y jumps")
	_button(JOY_BUTTON_Y, false)

	print("reset")
	Settings.reset_keys()
	_check(Settings.keys("pad", "jump") == [JOY_BUTTON_A], "back to A")

	print("F1 help names the current bindings")
	var hud := Hud.new()
	var help := hud._help()
	_check(help[0][1] == "WASD move  ·  Space jump  ·  J fire / use  ·  K tractor beam  ·  Q switch unit", "P1 defaults")
	_check(help[1][1] == "Arrows move  ·  Up jump  ·  . fire / use  ·  / tractor beam  ·  Enter join / switch unit", "P2 defaults")
	_check(help[2][1] == "Stick move  ·  A jump / join  ·  X fire / use  ·  B tractor beam  ·  Y switch unit  ·  Start menu", "Pad defaults")
	for a: Array in [["up", KEY_I], ["left", KEY_J], ["down", KEY_K], ["right", KEY_L], ["action", KEY_U]]:
		Settings.set_keys("kb1", a[0], [a[1]])
	Settings.set_keys("kb2", "up", [KEY_KP_8])
	Settings.set_keys("kb2", "beam", [KEY_SEMICOLON])
	Settings.set_keys("pad", "jump", [JOY_BUTTON_LEFT_SHOULDER])
	Settings.set_keys("pad", "action", [Settings.PAD_LT])
	help = hud._help()
	_check(help[0][1].begins_with("IJKL move  ·  Space jump  ·  U fire / use"), "P1 rebound: " + help[0][1])
	_check(help[1][1].begins_with("Kp 8 / Left / Down / Right move  ·  Up jump  ·  . fire / use  ·  ; tractor beam"), "P2 rebound: " + help[1][1])
	_check(help[2][1].begins_with("Stick move  ·  LB jump / join  ·  LT fire / use"), "Pad rebound: " + help[2][1])
	hud.free()
	Settings.reset_keys()

	page.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))
	print("ALL TESTS PASSED" if _failed == 0 else "%d FAILED" % _failed)
	_watchdog.stop()
	quit(1 if _failed > 0 else 0)


func _send(e: InputEvent) -> void:
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _button(b: JoyButton, down: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = PAD
	e.button_index = b
	e.pressed = down
	_send(e)


func _axis(a: JoyAxis, v: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = PAD
	e.axis = a
	e.axis_value = v
	_send(e)


func _key(k: Key) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.pressed = true
	_send(e)
	e = e.duplicate()
	e.pressed = false
	_send(e)


func _check(cond: bool, what: String) -> void:
	_last = what
	print("  %s  %s" % ["ok  " if cond else "FAIL", what])
	if not cond:
		_failed += 1
