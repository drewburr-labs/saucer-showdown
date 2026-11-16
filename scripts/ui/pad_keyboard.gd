extends Control
## An on-screen keyboard, so a gamepad can type a name or a room code. The
## menus open it when A is pressed on a text field, and it edits that field in
## place. On the pad: X deletes, Y switches case, Start finishes (like Done)
## and B puts the text back as it was.

const UI = preload("res://scripts/ui/ui_kit.gd")

const ROWS := ["1234567890", "QWERTYUIOP", "ASDFGHJKL-", "ZXCVBNM.:_"]

var _field: LineEdit
var _before := ""
var _lower := false
var _letters: Array[Button] = []
var _first: Button
var _case: Button
var _title: Label
var _preview: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.05, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := UI.column(12)
	panel.add_child(box)
	_title = UI.title("", 26)
	box.add_child(_title)
	var shown := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.35)
	sb.border_color = UI.GOLD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(8)
	shown.add_theme_stylebox_override("panel", sb)
	box.add_child(shown)
	_preview = UI.label("", 24)
	_preview.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shown.add_child(_preview)

	var grid := GridContainer.new()
	grid.columns = ROWS[0].length()
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	for row: String in ROWS:
		for ch in row:
			var b := UI.button(ch, _type.bind(ch))
			b.custom_minimum_size = Vector2(54, 48)
			b.add_theme_font_size_override("font_size", 22)
			grid.add_child(b)
			if ch != ch.to_lower():
				_letters.append(b)
			if ch == "Q":
				_first = b
	var keys := UI.row(6)
	box.add_child(keys)
	_case = UI.button("", toggle_case)
	_case.custom_minimum_size = Vector2(110, 48)
	keys.add_child(_case)
	var space := UI.button("Space", _type.bind(" "))
	space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys.add_child(space)
	var del := UI.button("Delete", backspace)
	del.custom_minimum_size = Vector2(110, 48)
	keys.add_child(del)
	var done := UI.button("Done", finish)
	done.custom_minimum_size = Vector2(110, 48)
	keys.add_child(done)
	box.add_child(UI.label("X delete  ·  Y abc / ABC  ·  Start done  ·  B cancel", 15, Color(1, 1, 1, 0.5)))


## Start editing `field`, headed by `heading`.
func open(field: LineEdit, heading: String) -> void:
	_field = field
	_before = field.text
	_title.text = heading
	_lower = false # capitals to start: codes are capitals, and so are most names' first letters
	visible = true
	_relabel()
	_refresh()
	_first.grab_focus()


func is_open() -> bool:
	return visible


## The key to focus if focus goes missing while open.
func first_focus() -> Control:
	return _first


## A pad button pressed while open: true if the keyboard used it.
func handle(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_cancel"):
		cancel()
		return true
	var pad := event as InputEventJoypadButton
	if pad == null or not pad.pressed:
		return false
	match pad.button_index:
		JOY_BUTTON_START:
			finish()
		JOY_BUTTON_X:
			backspace()
		JOY_BUTTON_Y:
			toggle_case()
		_:
			return false
	return true


func backspace() -> void:
	_set_text(_field.text.left(-1))


func toggle_case() -> void:
	_lower = not _lower
	_relabel()


## Keep the text, as if Enter was pressed in the field.
func finish() -> void:
	visible = false
	_field.text_submitted.emit(_field.text)
	_return_focus()


## Put the text back as it was.
func cancel() -> void:
	_set_text(_before)
	visible = false
	_return_focus()


func _return_focus() -> void:
	if _field.is_visible_in_tree():
		_field.grab_focus()


func _type(ch: String) -> void:
	if _field.max_length > 0 and _field.text.length() >= _field.max_length:
		return
	_set_text(_field.text + (ch.to_lower() if _lower else ch))


func _set_text(t: String) -> void:
	if t == _field.text:
		return
	_field.text = t
	_field.caret_column = t.length()
	_field.text_changed.emit(t)
	_refresh()


func _relabel() -> void:
	for b in _letters:
		b.text = b.text.to_lower() if _lower else b.text.to_upper()
	_case.text = "ABC" if _lower else "abc"


func _refresh() -> void:
	var empty := _field.text == ""
	_preview.text = (_field.placeholder_text if empty else _field.text) + "_"
	_preview.add_theme_color_override("font_color", Color(1, 1, 1, 0.4) if empty else Color.WHITE)
