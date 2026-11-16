extends VBoxContainer
## Settings: sound, display and controls, in tabs. Every change takes effect
## and is saved at once.

signal closed

const Settings = preload("res://scripts/settings.gd")
const UI = preload("res://scripts/ui/ui_kit.gd")

var _tabs: TabContainer
var _sliders := {} # bus -> HSlider
var _values := {} # bus -> Label
var _mute: CheckBox
var _mode: OptionButton
var _res: OptionButton
var _res_list: Array = []
var _vsync: CheckBox
var _fps: OptionButton
var _show_fps: CheckBox
const DEVICES := ["kb1", "kb2", "pad"]
const NO_INPUT := -1 # what _captured() returns for an event that binds nothing
const CANCEL := -2

var _key_btns := {} # "device.action" -> Button
var _rebinding := "" # "device.action" waiting for a key or button, or ""
var _bind_note: Label


func _ready() -> void:
	add_theme_constant_override("separation", 14)
	add_child(UI.title("SETTINGS"))
	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(0, 470)
	add_child(_tabs)
	_tabs.add_child(_sound_tab())
	_tabs.add_child(_display_tab())
	_tabs.add_child(_controls_tab())
	var back := UI.button("Back", func() -> void: closed.emit())
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add_child(back)


## Load the current values into the widgets.
func open() -> void:
	_rebinding = ""
	for bus: String in Settings.BUSES:
		_sliders[bus].set_value_no_signal(Settings.value("vol_" + bus) * 100.0)
		_values[bus].text = "%d%%" % roundi(_sliders[bus].value)
	_mute.set_pressed_no_signal(Settings.value("mute"))
	_mode.select(Settings.value("window_mode"))
	_res.clear()
	_res_list = Settings.resolutions()
	var cur: Vector2i = Settings.value("resolution")
	for i in _res_list.size():
		_res.add_item("%d × %d" % [_res_list[i].x, _res_list[i].y], i)
		if _res_list[i] == cur:
			_res.select(i)
	_res.disabled = Settings.value("window_mode") != Settings.WindowMode.WINDOWED
	_vsync.set_pressed_no_signal(Settings.value("vsync"))
	_fps.select(maxi(0, Settings.FPS_CAPS.find(Settings.value("max_fps"))))
	_show_fps.set_pressed_no_signal(Settings.value("show_fps"))
	_refresh_keys()


## What to focus when the page opens.
func first_focus() -> Control:
	return _tabs.get_tab_bar()


func _row(text: String, widget: Control) -> HBoxContainer:
	var r := UI.row(16)
	var l := UI.label(text, 17, UI.DIM)
	l.custom_minimum_size = Vector2(210, 0)
	r.add_child(l)
	widget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(widget)
	return r


func _sound_tab() -> Control:
	var box := UI.column(16)
	box.name = "Sound"
	for bus: String in Settings.BUSES:
		var s := HSlider.new()
		s.min_value = 0
		s.max_value = 100
		s.step = 5
		s.custom_minimum_size = Vector2(0, 28)
		s.focus_mode = Control.FOCUS_ALL
		var v := UI.label("", 17, Color.WHITE)
		v.custom_minimum_size = Vector2(56, 0)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		s.value_changed.connect(func(x: float) -> void:
			v.text = "%d%%" % roundi(x)
			Settings.set_value("vol_" + bus, x / 100.0)
			Settings.apply_audio())
		var r := _row("Master volume" if bus == "Master" else bus, s)
		r.add_child(v)
		box.add_child(r)
		_sliders[bus] = s
		_values[bus] = v
	_mute = CheckBox.new()
	_mute.text = "Mute all sound"
	_mute.toggled.connect(func(on: bool) -> void:
		Settings.set_value("mute", on)
		Settings.apply_audio())
	box.add_child(_mute)
	return box


func _display_tab() -> Control:
	var box := UI.column(16)
	box.name = "Display"
	_mode = OptionButton.new()
	for m: String in Settings.WINDOW_MODES:
		_mode.add_item(m)
	_mode.item_selected.connect(func(i: int) -> void:
		Settings.set_value("window_mode", i)
		_res.disabled = i != Settings.WindowMode.WINDOWED
		Settings.apply_display())
	box.add_child(_row("Window", _mode))
	_res = OptionButton.new()
	_res.item_selected.connect(func(i: int) -> void:
		Settings.set_value("resolution", _res_list[i])
		Settings.apply_display())
	box.add_child(_row("Resolution", _res))
	_fps = OptionButton.new()
	for cap: int in Settings.FPS_CAPS:
		_fps.add_item("Unlimited" if cap == 0 else "%d fps" % cap)
	_fps.item_selected.connect(func(i: int) -> void:
		Settings.set_value("max_fps", Settings.FPS_CAPS[i])
		Settings.apply_display())
	box.add_child(_row("Frame rate limit", _fps))
	_vsync = CheckBox.new()
	_vsync.text = "VSync (match the monitor's refresh rate, no tearing)"
	_vsync.toggled.connect(func(on: bool) -> void:
		Settings.set_value("vsync", on)
		Settings.apply_display())
	box.add_child(_vsync)
	_show_fps = CheckBox.new()
	_show_fps.text = "Show frame rate"
	_show_fps.toggled.connect(func(on: bool) -> void: Settings.set_value("show_fps", on))
	box.add_child(_show_fps)
	box.add_child(UI.label("Resolution sets the window size; fullscreen always fills the screen. The game itself runs at 60 ticks a second whatever the frame rate.", 15, Color(1, 1, 1, 0.45), true))
	return box


func _controls_tab() -> Control:
	var box := UI.column(10)
	box.name = "Controls"
	var grid := GridContainer.new()
	grid.columns = 1 + DEVICES.size()
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	grid.add_child(UI.label("", 15))
	for head: String in ["Player 1 keyboard", "Player 2 keyboard", "Gamepad"]:
		var l := UI.label(head, 15, UI.GOLD)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
	for action: String in Settings.ACTIONS:
		var l := UI.label(Settings.ACTION_NAMES[action], 16, UI.DIM)
		l.custom_minimum_size = Vector2(150, 0)
		grid.add_child(l)
		for device: String in DEVICES:
			var id := "%s.%s" % [device, action]
			var b := UI.button("")
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.custom_minimum_size = Vector2(0, 34)
			b.add_theme_constant_override("h_separation", 0)
			b.pressed.connect(func() -> void: _start_rebind(id))
			grid.add_child(b)
			_key_btns[id] = b
	_bind_note = UI.label("", 15, Color(1, 1, 1, 0.5), true)
	box.add_child(_bind_note)
	box.add_child(UI.label("All gamepads share these. Left stick moves, right stick aims, Jump joins, Start opens the menu.", 15, Color(1, 1, 1, 0.5), true))
	var reset := UI.button("Reset to defaults", func() -> void:
		Settings.reset_keys()
		_rebinding = ""
		_refresh_keys())
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(reset)
	return box


func _refresh_keys() -> void:
	for id: String in _key_btns:
		var parts := id.split(".")
		var waiting := "Press a button…" if parts[0] == "pad" else "Press a key…"
		_key_btns[id].text = waiting if id == _rebinding else Settings.key_names(parts[0], Settings.keys(parts[0], parts[1]))
	if _rebinding == "":
		_bind_note.text = "Pick a key or button to change it."
	elif _rebinding.begins_with("pad."):
		_bind_note.text = "Press the new gamepad button or trigger, or Start or Esc to cancel."
	else:
		_bind_note.text = "Press the new key, or Esc or Start to cancel."


func _start_rebind(id: String) -> void:
	_rebinding = id
	_refresh_keys()


func _input(event: InputEvent) -> void:
	if _rebinding == "" or not is_visible_in_tree():
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	# While waiting, keys and gamepads only answer this: no menu moves, B or Esc.
	get_viewport().set_input_as_handled()
	var parts := _rebinding.split(".")
	var code := _captured(event, parts[0] == "pad")
	if code == NO_INPUT:
		return
	if code != CANCEL:
		Settings.set_keys(parts[0], parts[1], [code])
	var was := _rebinding
	_rebinding = ""
	_refresh_keys()
	_key_btns[was].grab_focus()


## The binding `event` makes for a keyboard cell or, with `pad`, a gamepad
## cell; or CANCEL (Esc, Start), or NO_INPUT for anything else.
static func _captured(event: InputEvent, pad: bool) -> int:
	var key := event as InputEventKey
	if key != null:
		if not key.pressed or key.echo:
			return NO_INPUT
		var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
		if code == KEY_ESCAPE:
			return CANCEL
		return NO_INPUT if pad else code
	var button := event as InputEventJoypadButton
	if button != null:
		if not button.pressed:
			return NO_INPUT
		if button.button_index == JOY_BUTTON_START:
			return CANCEL
		return button.button_index if pad else NO_INPUT
	var motion := event as InputEventJoypadMotion
	if motion != null and pad and motion.axis_value > 0.5:
		if motion.axis == JOY_AXIS_TRIGGER_LEFT:
			return Settings.PAD_LT
		if motion.axis == JOY_AXIS_TRIGGER_RIGHT:
			return Settings.PAD_RT
	return NO_INPUT
