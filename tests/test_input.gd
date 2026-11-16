extends SceneTree
## Gamepad bindings: the defaults, a faked gamepad read through them, and
## rebinding on the settings page with a gamepad. Uses a scratch settings
## file, so the player's own settings are never touched.
##   godot --headless --path . --script tests/test_input.gd

const Settings = preload("res://scripts/settings.gd")
const LocalInput = preload("res://scripts/input/local_input.gd")
const SettingsPage = preload("res://scripts/ui/settings_page.gd")

const SCRATCH := "user://test_input_settings.cfg"
const PAD := 0

var _failed := 0


## Godot can't fake a connected gamepad, so this one says pad 0 is plugged in;
## its buttons and axes come from the events the test sends.
class FakePad extends LocalInput:
	func _connected(id: int) -> bool:
		return id == PAD


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
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

	page.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))
	print("ALL TESTS PASSED" if _failed == 0 else "%d FAILED" % _failed)
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
	print("  %s  %s" % ["ok  " if cond else "FAIL", what])
	if not cond:
		_failed += 1
