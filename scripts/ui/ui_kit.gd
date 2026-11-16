extends RefCounted
## The menus' look: one Theme, and small builders for the widgets they share.

const Art = preload("res://scripts/view/art.gd")

const GOLD := Color("ffd84a")
const INK := Color("140f26")
const DIM := Color(1, 1, 1, 0.7)
const PANEL_BG := Color(0.04, 0.03, 0.12, 0.96)


static func label(text: String, size: int = 17, color: Color = Color.WHITE, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func title(text: String, size: int = 34, color: Color = GOLD) -> Label:
	var l := label(text, size, color)
	l.add_theme_font_override("font", Art.title_font())
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


static func button(text: String, on_press: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b


## A tall button for the main choices on a page.
static func big_button(text: String, on_press: Callable) -> Button:
	var b := button(text, on_press)
	b.custom_minimum_size = Vector2(320, 58)
	b.add_theme_font_override("font", Art.title_font())
	b.add_theme_font_size_override("font_size", 26)
	return b


static func row(sep: int = 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func column(sep: int = 12) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


static func name_field() -> LineEdit:
	var e := LineEdit.new()
	e.max_length = 16
	e.placeholder_text = "Your name"
	e.custom_minimum_size = Vector2(240, 0)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return e


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = Art.body_font()
	t.default_font_size = 17

	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL_BG
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
	for type in ["Button", "OptionButton", "CheckBox"]:
		t.set_stylebox("normal", type, normal)
		t.set_stylebox("hover", type, hover)
		t.set_stylebox("pressed", type, pressed)
		t.set_stylebox("hover_pressed", type, pressed)
		t.set_stylebox("focus", type, focus)
		t.set_stylebox("disabled", type, disabled)
		t.set_color("font_color", type, Color.WHITE)
		t.set_color("font_hover_color", type, Color.WHITE)
		t.set_color("font_pressed_color", type, INK)
		t.set_color("font_hover_pressed_color", type, INK)
		t.set_color("font_focus_color", type, Color.WHITE)
		t.set_color("font_disabled_color", type, Color(1, 1, 1, 0.35))
	# A check box shows its state with its tick, not by lighting up.
	t.set_stylebox("pressed", "CheckBox", normal)
	t.set_stylebox("hover_pressed", "CheckBox", hover)
	t.set_color("font_pressed_color", "CheckBox", Color.WHITE)
	t.set_color("font_hover_pressed_color", "CheckBox", Color.WHITE)

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

	var popup := panel.duplicate()
	popup.set_content_margin_all(8)
	popup.set_corner_radius_all(10)
	t.set_stylebox("panel", "PopupMenu", popup)
	var popup_hover := normal.duplicate()
	popup_hover.bg_color = GOLD.darkened(0.3)
	t.set_stylebox("hover", "PopupMenu", popup_hover)
	t.set_color("font_hover_color", "PopupMenu", INK)

	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.15)
	track.set_corner_radius_all(4)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	var fill := track.duplicate()
	fill.bg_color = GOLD.darkened(0.15)
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)

	var tab := normal.duplicate()
	tab.bg_color = Color(1, 1, 1, 0.06)
	tab.corner_radius_bottom_left = 0
	tab.corner_radius_bottom_right = 0
	var tab_on := tab.duplicate()
	tab_on.bg_color = Color(1, 1, 1, 0.16)
	tab_on.border_color = GOLD
	tab_on.border_width_top = 3
	var tab_hover := tab.duplicate()
	tab_hover.bg_color = Color(1, 1, 1, 0.12)
	t.set_stylebox("tab_unselected", "TabContainer", tab)
	t.set_stylebox("tab_selected", "TabContainer", tab_on)
	t.set_stylebox("tab_hovered", "TabContainer", tab_hover)
	t.set_stylebox("tab_focus", "TabContainer", focus)
	var tab_panel := StyleBoxFlat.new()
	tab_panel.bg_color = Color(1, 1, 1, 0.04)
	tab_panel.set_corner_radius_all(10)
	tab_panel.corner_radius_top_left = 0
	tab_panel.set_content_margin_all(18)
	t.set_stylebox("panel", "TabContainer", tab_panel)
	t.set_color("font_selected_color", "TabContainer", GOLD)
	t.set_color("font_unselected_color", "TabContainer", Color(1, 1, 1, 0.7))
	t.set_color("font_hovered_color", "TabContainer", Color.WHITE)
	return t
