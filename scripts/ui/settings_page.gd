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
var _key_btns := {} # "device.action" -> Button
var _rebinding := "" # "device.action" waiting for a key, or ""
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
	box.add_child(UI.label("The game has no sound effects or music yet; these are ready for when it does.", 15, Color(1, 1, 1, 0.45), true))
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
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	grid.add_child(UI.label("", 15))
	for head: String in ["Player 1 keyboard", "Player 2 keyboard"]:
		var l := UI.label(head, 15, UI.GOLD)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
	for action: String in Settings.ACTIONS:
		var l := UI.label(Settings.ACTION_NAMES[action], 16, UI.DIM)
		l.custom_minimum_size = Vector2(170, 0)
		grid.add_child(l)
		for device: String in ["kb1", "kb2"]:
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
	box.add_child(UI.label("Gamepad: stick or d-pad move · A jump · X fire / use · B beam · Y switch unit · Start join", 15, Color(1, 1, 1, 0.5), true))
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
		_key_btns[id].text = "Press a key…" if id == _rebinding else Settings.key_names(Settings.keys(parts[0], parts[1]))
	_bind_note.text = "Press the new key, or Esc to cancel." if _rebinding != "" \
			else "Click a key to change it."


func _start_rebind(id: String) -> void:
	_rebinding = id
	_refresh_keys()


func _input(event: InputEvent) -> void:
	if _rebinding == "" or not is_visible_in_tree():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	get_viewport().set_input_as_handled()
	var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	if code != KEY_ESCAPE:
		var parts := _rebinding.split(".")
		Settings.set_keys(parts[0], parts[1], [code])
	var was := _rebinding
	_rebinding = ""
	_refresh_keys()
	_key_btns[was].grab_focus()
