extends CanvasLayer
## The F6 "Play online" panel: host a game and get a room code, join one by
## its code, or leave. Games go through the relay server.
## Offline, the match waits while it is open; online, your input is muted so
## typing an address doesn't move your saucer.

const Art = preload("res://scripts/view/art.gd")

const GOLD := Color("ffd84a")

var game # Main

var _root: Control
var _addr: LineEdit
var _status: Label
var _code: Label
var _host_btn: Button
var _join_btn: Button
var _leave_btn: Button


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.theme = _make_theme()
	_root.visible = false
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.05, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var title := Label.new()
	title.text = "PLAY ONLINE"
	title.add_theme_font_override("font", Art.title_font())
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var blurb := _label("Host a game to get a room code, then friends type it in below. Everyone needs the same version. Bots fill every seat nobody takes.", 15, Color(1, 1, 1, 0.75))
	box.add_child(blurb)

	_host_btn = _button("Host a game")
	_host_btn.pressed.connect(_on_host)
	box.add_child(_host_btn)

	_code = Label.new()
	_code.add_theme_font_override("font", Art.title_font())
	_code.add_theme_font_size_override("font_size", 46)
	_code.add_theme_color_override("font_color", Color.WHITE)
	_code.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code.visible = false
	box.add_child(_code)

	box.add_child(_label("Join a game", 15, Color(1, 1, 1, 0.75)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	_addr = LineEdit.new()
	_addr.placeholder_text = "Room code, e.g. KX4PZ"
	_addr.max_length = 64
	_addr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_addr.text_submitted.connect(func(_t: String) -> void: _on_join())
	row.add_child(_addr)
	_join_btn = _button("Join")
	_join_btn.pressed.connect(_on_join)
	row.add_child(_join_btn)

	_status = _label("", 15, GOLD)
	box.add_child(_status)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	bottom.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(bottom)
	_leave_btn = _button("Leave online game")
	_leave_btn.pressed.connect(func() -> void: game.leave())
	bottom.add_child(_leave_btn)
	var close := _button("Close  (F6)")
	close.pressed.connect(toggle)
	bottom.add_child(close)



func is_open() -> bool:
	return _root != null and _root.visible


func toggle() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_status.text = ""
		_refresh()
		_addr.grab_focus()
	else:
		_addr.release_focus()


func _process(_delta: float) -> void:
	if is_open():
		_refresh()


func _refresh() -> void:
	var online: bool = game.role != game.Role.OFFLINE
	_host_btn.disabled = online
	_join_btn.disabled = online
	_addr.editable = not online
	_leave_btn.visible = online
	_code.visible = game.role == game.Role.HOST and game.room_code != ""
	_code.text = "  ".join(game.room_code.split(""))
	if online:
		_status.text = game.net_status


func _on_host() -> void:
	var err: String = game.host()
	_status.text = err if err != "" else game.net_status


func _on_join() -> void:
	var addr := _addr.text.strip_edges()
	var err: String = game.join(addr)
	_status.text = err if err != "" else game.net_status


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	return b


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = Art.body_font()
	t.default_font_size = 17

	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.04, 0.03, 0.12, 0.96)
	panel.border_color = Color(1, 1, 1, 0.18)
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(16)
	panel.set_content_margin_all(26)
	t.set_stylebox("panel", "PanelContainer", panel)

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(1, 1, 1, 0.1)
	normal.set_corner_radius_all(10)
	normal.content_margin_left = 18
	normal.content_margin_right = 18
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	var hover := normal.duplicate()
	hover.bg_color = Color(1, 1, 1, 0.2)
	var pressed := normal.duplicate()
	pressed.bg_color = GOLD.darkened(0.3)
	var focus := normal.duplicate()
	focus.draw_center = false
	focus.border_color = GOLD
	focus.set_border_width_all(2)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(1, 1, 1, 0.04)
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", focus)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_color("font_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.35))

	var edit := normal.duplicate()
	edit.bg_color = Color(0, 0, 0, 0.35)
	edit.border_color = Color(1, 1, 1, 0.2)
	edit.set_border_width_all(1)
	var edit_focus := edit.duplicate()
	edit_focus.border_color = GOLD
	t.set_stylebox("normal", "LineEdit", edit)
	t.set_stylebox("focus", "LineEdit", edit_focus)
	t.set_stylebox("read_only", "LineEdit", disabled)
	t.set_color("font_placeholder_color", "LineEdit", Color(1, 1, 1, 0.35))
	return t
