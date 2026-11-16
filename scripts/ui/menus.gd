extends CanvasLayer
## Every screen outside the arena: home, local setup, play online, the online
## lobby, the in-game menu and settings. Main decides what the game is
## doing and this follows along: during a match the menus stay hidden until
## Esc or Start, while in a room they show the lobby, and otherwise the home screen.
## Bots play a match behind them.
##
## Everything works from a gamepad too: the d-pad or stick moves between
## controls, A presses, B goes back, LB / RB switch settings tabs, and A on a
## text field opens an on-screen keyboard.

const Cfg = preload("res://scripts/sim/config.gd")
const Settings = preload("res://scripts/settings.gd")
const UI = preload("res://scripts/ui/ui_kit.gd")
const SettingsPage = preload("res://scripts/ui/settings_page.gd")
const PadKeyboard = preload("res://scripts/ui/pad_keyboard.gd")

## Actions that move or use focus; if focus has gone missing, the first of
## these puts it back on the page instead.
const NAV_ACTIONS := ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_focus_next", "ui_focus_prev"]

var game # Main

var _root: Control
var _pages := {} # name -> Control
var _first := {} # name -> the Control to focus when it opens
var _page := "none"
var _settings_from := "home" # the page settings goes back to
var _after_room := "home" # where to land once a match or room is over
var _toast: PanelContainer
var _toast_text: Label
var _fps: Label

var _version: Label
var _update_btn: Button
var _local_btns: Array[Button] = []
var _local_greys := 1
var _local_blurb: Label
var _p2_btns: Array[Button] = [] # the "2nd player" toggles, on the local and lobby pages
var _online_name: LineEdit
var _code: LineEdit
var _host_btn: Button
var _join_btn: Button
var _online_status: Label

var _room_code: Label
var _room_hint: Label
var _size_btns: Array[Button] = []
var _team_heads: Array[Label] = []
var _team_lists: Array[VBoxContainer] = []
var _team_btns: Array[Button] = []
var _lobby_name: LineEdit
var _count: Label
var _room_note: Label
var _start_btn: Button
var _waiting: Label
var _lobby_sig := ""

var _pause_note: Label
var _pause_btns := {} # name -> Button
var _settings: SettingsPage
var _keyboard: PadKeyboard


func _ready() -> void:
	_map_pad_buttons()
	layer = 10
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.theme = UI.make_theme()
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.05, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	_build_home()
	_build_local()
	_build_online()
	_build_lobby()
	_build_pause()
	var box := _add_page("settings", 760)
	_settings = SettingsPage.new()
	_settings.closed.connect(_close_settings)
	box.add_child(_settings)
	_first["settings"] = _settings.first_focus()

	_toast = PanelContainer.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position.y = 18
	var ts := StyleBoxFlat.new()
	ts.bg_color = UI.PANEL_BG
	ts.border_color = UI.GOLD
	ts.set_border_width_all(2)
	ts.set_corner_radius_all(16)
	ts.content_margin_left = 20
	ts.content_margin_right = 20
	ts.content_margin_top = 6
	ts.content_margin_bottom = 6
	_toast.add_theme_stylebox_override("panel", ts)
	_toast_text = UI.label("", 16, UI.GOLD)
	_toast.add_child(_toast_text)
	_toast.visible = false
	_root.add_child(_toast)

	# Not under _root, so focus can't wander between it and the page behind.
	_keyboard = PadKeyboard.new()
	_keyboard.theme = _root.theme
	add_child(_keyboard)

	_fps = UI.label("", 14, Color(1, 1, 1, 0.75))
	_fps.position = Vector2(Cfg.W - 90, 4)
	_fps.size = Vector2(84, 20)
	_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps.add_theme_constant_override("outline_size", 4)
	_fps.add_theme_color_override("font_outline_color", UI.INK)
	add_child(_fps)
	show_page("home")


## Godot's ui_accept and ui_cancel only have keys (its d-pad and stick moves
## do have the gamepad), so a pad could move between buttons but not press
## them. Give every gamepad's A and B to them.
static func _map_pad_buttons() -> void:
	for pair: Array in [["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B]]:
		var e := InputEventJoypadButton.new()
		e.device = -1 # all devices
		e.button_index = pair[1]
		if not InputMap.action_has_event(pair[0], e):
			InputMap.action_add_event(pair[0], e)


## True while a menu covers the game (and takes the keyboard).
func is_open() -> bool:
	return _root != null and _root.visible


func page() -> String:
	return _page


func show_page(name: String) -> void:
	if name == _page:
		return
	for k: String in _pages:
		_pages[k].visible = k == name
	_page = name
	_root.visible = name != ""
	if _keyboard.is_open():
		_keyboard.cancel()
	match name:
		"online":
			_online_name.text = Settings.value("name")
			_online_status.text = ""
		"lobby":
			_lobby_name.text = game.player_name
			_lobby_sig = ""
		"settings":
			_settings.open()
	_refresh()
	if is_inside_tree():
		_focus_page.call_deferred()


## Focus the page's first control, or the first usable one when that's hidden
## or disabled (a client's lobby has no Start button).
func _focus_page() -> void:
	var c := _focus_target()
	if c != null:
		c.grab_focus()


func _focus_target() -> Control:
	if _keyboard.is_open():
		return _keyboard.first_focus()
	if not _pages.has(_page):
		return null
	var f: Control = _first.get(_page)
	if f != null and _usable(f):
		return f
	return _first_usable(_pages[_page])


static func _usable(c: Control) -> bool:
	return c.is_visible_in_tree() and c.focus_mode == Control.FOCUS_ALL \
			and not (c is BaseButton and c.disabled)


static func _first_usable(n: Node) -> Control:
	for child in n.get_children():
		if child is Control and _usable(child):
			return child
		var deeper := _first_usable(child)
		if deeper != null:
			return deeper
	return null


# --- Following the game --------------------------------------------------

func _process(_delta: float) -> void:
	_fps.visible = Settings.value("show_fps")
	if _fps.visible:
		_fps.text = "%d fps" % Engine.get_frames_per_second()
	if game == null:
		return
	_follow()
	if is_open():
		_refresh()


## Pick the page that fits what the game is doing now.
func _follow() -> void:
	var from_settings := _settings_from if _page == "settings" else ""
	if game.in_match:
		if _page not in ["", "pause"] and from_settings != "pause":
			show_page("")
		_after_room = "local" if game.role == game.Role.OFFLINE else "online"
	elif game.in_lobby:
		if _page != "lobby" and from_settings != "lobby":
			show_page("lobby")
		_after_room = "online"
	elif _page in ["", "pause", "lobby"] or from_settings in ["pause", "lobby"]:
		show_page("online" if game.role != game.Role.OFFLINE else _after_room)


## Gamepad extras that must come before the controls see the event.
func _input(event: InputEvent) -> void:
	if not is_open() and not _keyboard.is_open():
		return
	if _keyboard.is_open():
		if _keyboard.handle(event):
			get_viewport().set_input_as_handled()
			return
	elif _pad_pressed(event, JOY_BUTTON_A):
		var field := get_viewport().gui_get_focus_owner() as LineEdit
		if field != null and field.editable:
			_keyboard.open(field, "ROOM CODE" if field == _code else "YOUR NAME")
			get_viewport().set_input_as_handled()
			return
	elif _page == "settings" and (_pad_pressed(event, JOY_BUTTON_LEFT_SHOULDER) or _pad_pressed(event, JOY_BUTTON_RIGHT_SHOULDER)):
		_settings.cycle_tab(1 if _pad_pressed(event, JOY_BUTTON_RIGHT_SHOULDER) else -1)
		get_viewport().set_input_as_handled()
		return
	# Focus went missing (the focused button was hidden, or a click on empty
	# space): the first press puts it back rather than doing nothing.
	var owner := get_viewport().gui_get_focus_owner()
	if owner != null and owner.is_visible_in_tree():
		return
	for a: String in NAV_ACTIONS:
		if event.is_action_pressed(a):
			_focus_page()
			get_viewport().set_input_as_handled()
			return


static func _pad_pressed(event: InputEvent, button: JoyButton) -> bool:
	var pad := event as InputEventJoypadButton
	return pad != null and pad.pressed and pad.button_index == button


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		_escape() # (the on-screen keyboard took Esc already, in _input)
		get_viewport().set_input_as_handled()
	elif _is_start(event) and _page in ["", "pause"]:
		# Gamepad Start opens and closes the in-game menu, like Esc.
		_escape()
		get_viewport().set_input_as_handled()
	elif is_open() and event.is_action_pressed("ui_cancel"):
		# Gamepad B; Esc is handled above.
		_escape()
		get_viewport().set_input_as_handled()


static func _is_start(event: InputEvent) -> bool:
	return _pad_pressed(event, JOY_BUTTON_START)


func _escape() -> void:
	match _page:
		"":
			if game.in_match:
				_open_pause()
		"pause":
			_resume()
		"settings":
			_close_settings()
		"local", "online":
			_back_home()


func _back_home() -> void:
	if game.role != game.Role.OFFLINE:
		game.leave()
	_after_room = "home"
	show_page("home")


func _refresh() -> void:
	match _page:
		"home":
			var up = game.updater
			var status: String = up.status_text() if up != null else ""
			_version.text = (up.version if up != null else "") + ("   ·   " + status if status != "" else "")
			_refresh_update(up)
		"local":
			var who := "Player 2 joins with %s and gamepads with %s, at any time." % [_p2_key(), _pad_join()] \
					if Settings.value("extra_players") else "Any keyboard or gamepad plays as you."
			_local_blurb.text = "You're Player 1 on %s. %s Bots fill every other seat. Best of 3 maps." % [
					Cfg.TEAM_NAMES[0], who]
			for i in _local_btns.size():
				_local_btns[i].set_pressed_no_signal(game.TEAM_SIZES[i] == _local_greys)
		"online":
			_refresh_online()
		"lobby":
			_refresh_lobby()
		"pause":
			_refresh_pause()
	var on: bool = Settings.value("extra_players")
	for b in _p2_btns:
		b.set_pressed_no_signal(on)
		b.text = "2nd player: On" if on else "2nd player: Off"
		b.tooltip_text = ("Player 2 joins with %s, gamepads with %s. Click to turn off." % [_p2_key(), _pad_join()]) if on \
				else "Only you play at this machine; every keyboard and gamepad controls you. Click to let a 2nd player join."
	var show_toast: bool = game.notice_t > 0.0 and game.notice != ""
	_toast.visible = show_toast
	if show_toast:
		_toast_text.text = game.notice
		_toast.modulate.a = minf(1.0, game.notice_t)
		_toast.reset_size()
		_toast.position.x = (Cfg.W - _toast.size.x) * 0.5


# --- Pages ---------------------------------------------------------------

func _add_page(name: String, width: float, framed := true) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.visible = false
	_root.add_child(center)
	var box := UI.column(14)
	if framed:
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(width, 0)
		center.add_child(panel)
		panel.add_child(box)
	else:
		box.custom_minimum_size = Vector2(width, 0)
		center.add_child(box)
	_pages[name] = center
	return box


func _build_home() -> void:
	var box := _add_page("home", 560, false)
	box.add_child(UI.title("SAUCER SHOWDOWN", 76))
	var sub := UI.label("Two alien fleets. One farm. Three ways to win.", 20, UI.DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	box.add_child(UI.spacer(18))
	var buttons := UI.column(12)
	buttons.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(buttons)
	var online := UI.big_button("Play online", func() -> void: show_page("online"))
	buttons.add_child(online)
	buttons.add_child(UI.big_button("Play local", func() -> void: show_page("local")))
	buttons.add_child(UI.big_button("Settings", func() -> void: _open_settings("home")))
	buttons.add_child(UI.big_button("Quit", func() -> void: get_tree().quit()))
	# What F5 does, for a gamepad: check, install, or retry a failed update.
	_update_btn = UI.button("", func() -> void:
		if game.updater != null:
			game.updater.install())
	_update_btn.custom_minimum_size = Vector2(320, 40)
	_update_btn.visible = false
	buttons.add_child(_update_btn)
	# No panel behind these, so give them a solid fill over the busy arena.
	for b: Button in buttons.get_children():
		for state in ["normal", "hover", "disabled"]:
			var sb: StyleBoxFlat = _root.theme.get_stylebox(state, "Button").duplicate()
			sb.bg_color = UI.PANEL_BG.lerp(Color.WHITE, 0.12 if state == "hover" else 0.04)
			sb.border_color = Color(1, 1, 1, 0.2)
			sb.set_border_width_all(2)
			b.add_theme_stylebox_override(state, sb)
	_first["home"] = online
	box.add_child(UI.spacer(18))
	_version = UI.label("", 14, Color(1, 1, 1, 0.5))
	_version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_version)


func _refresh_update(up) -> void:
	var on: bool = up != null and up.enabled()
	_update_btn.visible = on
	if not on:
		return
	var S = up.State
	match up.state:
		S.CHECKING:
			_update_btn.text = "Checking for updates…"
		S.AVAILABLE:
			_update_btn.text = "Install update %s" % up.latest
		S.DOWNLOADING:
			_update_btn.text = "Downloading… %d%%" % roundi(up.progress() * 100.0)
		S.INSTALLING:
			_update_btn.text = "Installing…"
		S.FAILED:
			_update_btn.text = "Retry the update"
		_:
			_update_btn.text = "Check for updates"
	_update_btn.disabled = up.state in [S.CHECKING, S.DOWNLOADING, S.INSTALLING]


func _build_local() -> void:
	var box := _add_page("local", 560)
	box.add_child(UI.title("PLAY LOCAL"))
	box.add_child(UI.label("Team size", 15, UI.DIM))
	var sizes := UI.row()
	box.add_child(sizes)
	for greys: int in [1, 2, 3]:
		var b := UI.button(game.size_name(greys) if game != null else "%dv%d" % [greys + 1, greys + 1])
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void: _local_greys = greys)
		sizes.add_child(b)
		_local_btns.append(b)
	_local_blurb = UI.label("", 16, UI.DIM, true)
	box.add_child(_local_blurb)
	var p2 := _p2_toggle()
	p2.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(p2)
	box.add_child(UI.spacer(4))
	var start := UI.big_button("Start match", func() -> void: game.start_local(_local_greys))
	start.size_flags_horizontal = Control.SIZE_FILL
	box.add_child(start)
	var back := UI.button("Back", _back_home)
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(back)
	_first["local"] = start


func _build_online() -> void:
	var box := _add_page("online", 560)
	box.add_child(UI.title("PLAY ONLINE"))
	var name_row := UI.row()
	box.add_child(name_row)
	name_row.add_child(UI.label("Your name", 17, UI.DIM))
	_online_name = UI.name_field()
	_online_name.text_changed.connect(func(t: String) -> void: game.set_player_name(t))
	name_row.add_child(_online_name)
	box.add_child(UI.spacer(2))
	_host_btn = UI.big_button("Host a game", _on_host)
	_host_btn.size_flags_horizontal = Control.SIZE_FILL
	box.add_child(_host_btn)
	box.add_child(UI.label("…or join a friend's game with their room code", 15, UI.DIM))
	var join_row := UI.row()
	box.add_child(join_row)
	_code = LineEdit.new()
	_code.placeholder_text = "Room code, e.g. KX4PZ"
	_code.max_length = 64
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code.text_submitted.connect(func(_t: String) -> void: _on_join())
	join_row.add_child(_code)
	_join_btn = UI.button("Join", _on_join)
	join_row.add_child(_join_btn)
	_online_status = UI.label("", 15, UI.GOLD, true)
	box.add_child(_online_status)
	var back := UI.button("Back", _back_home)
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(back)
	_first["online"] = _host_btn


func _refresh_online() -> void:
	var busy: bool = game.role != game.Role.OFFLINE
	_host_btn.disabled = busy
	_join_btn.disabled = busy
	_code.editable = not busy
	if busy:
		_online_status.text = game.net_status
	elif game.notice_t > 0.0:
		_online_status.text = game.notice


func _on_host() -> void:
	game.set_player_name(_online_name.text)
	var err: String = game.host()
	_online_status.text = err if err != "" else game.net_status


func _on_join() -> void:
	game.set_player_name(_online_name.text)
	var err: String = game.join(_code.text)
	_online_status.text = err if err != "" else game.net_status


func _build_lobby() -> void:
	var box := _add_page("lobby", 960)
	var top := UI.row(24)
	box.add_child(top)
	var code_box := UI.column(0)
	code_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(code_box)
	code_box.add_child(UI.label("ROOM CODE", 14, UI.DIM))
	_room_code = UI.title("", 52, Color.WHITE)
	_room_code.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	code_box.add_child(_room_code)
	_room_hint = UI.label("", 15, UI.DIM)
	code_box.add_child(_room_hint)
	var size_box := UI.column(6)
	size_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(size_box)
	size_box.add_child(UI.label("Team size", 15, UI.DIM))
	var sizes := UI.row(8)
	size_box.add_child(sizes)
	for greys: int in [1, 2, 3]:
		var b := UI.button("%dv%d" % [greys + 1, greys + 1])
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(84, 44)
		b.add_theme_font_override("font", UI.Art.title_font())
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(func() -> void:
			var err: String = game.set_team_size(greys)
			if err != "":
				game._say(err))
		sizes.add_child(b)
		_size_btns.append(b)

	var teams := UI.row(18)
	box.add_child(teams)
	for team in 2:
		var c: Color = Cfg.TEAM_COLORS[team]
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(c, 0.08)
		sb.border_color = Color(c, 0.8)
		sb.set_border_width_all(2)
		sb.border_width_top = 5
		sb.set_corner_radius_all(12)
		sb.set_content_margin_all(16)
		panel.add_theme_stylebox_override("panel", sb)
		teams.add_child(panel)
		var col := UI.column(8)
		panel.add_child(col)
		var head := UI.row()
		col.add_child(head)
		var tname := UI.title(Cfg.TEAM_NAMES[team], 26, c.lightened(0.2))
		tname.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		tname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(tname)
		var count := UI.label("", 16, UI.DIM)
		count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(count)
		_team_heads.append(count)
		var list := UI.column(6)
		list.custom_minimum_size = Vector2(0, 4 * 34 - 6)
		col.add_child(list)
		_team_lists.append(list)
		var join := UI.button("", func() -> void:
			var err: String = game.pick_team(team)
			if err != "":
				game._say(err))
		col.add_child(join)
		_team_btns.append(join)

	var name_row := UI.row()
	box.add_child(name_row)
	name_row.add_child(UI.label("Your name", 17, UI.DIM))
	_lobby_name = UI.name_field()
	_lobby_name.size_flags_horizontal = Control.SIZE_FILL
	_lobby_name.text_submitted.connect(func(t: String) -> void:
		game.set_player_name(t)
		_lobby_name.release_focus())
	_lobby_name.focus_exited.connect(func() -> void: game.set_player_name(_lobby_name.text))
	name_row.add_child(_lobby_name)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(gap)
	_count = UI.label("", 17, Color.WHITE)
	name_row.add_child(_count)

	_room_note = UI.label("", 15, UI.GOLD, true)
	box.add_child(_room_note)

	var bottom := UI.row()
	box.add_child(bottom)
	var leave := UI.button("Leave room", func() -> void:
		_after_room = "online"
		game.leave())
	bottom.add_child(leave)
	bottom.add_child(UI.button("Settings", func() -> void: _open_settings("lobby")))
	bottom.add_child(_p2_toggle())
	var gap2 := Control.new()
	gap2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(gap2)
	_waiting = UI.label("", 16, UI.DIM)
	_waiting.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bottom.add_child(_waiting)
	_start_btn = UI.big_button("Start match", func() -> void: game.start_match())
	_start_btn.custom_minimum_size = Vector2(240, 54)
	bottom.add_child(_start_btn)
	_first["lobby"] = _start_btn


func _refresh_lobby() -> void:
	var host: bool = game.role == game.Role.HOST
	var me: int = game.my_id()
	var per_team: int = 1 + game.greys_per_team
	var full: bool = game.lobby.size() >= game.room_size()

	if game.room_code != "":
		_room_code.text = "  ".join(game.room_code.split(""))
		_room_hint.text = "Friends pick Play online and type this code in."
	elif game.via_relay():
		_room_code.text = "· · · · ·"
		_room_hint.text = "Opening a room on the relay server…"
	else:
		_room_code.text = "DIRECT"
		_room_hint.text = game.net_status

	for i in _size_btns.size():
		var greys: int = game.TEAM_SIZES[i]
		_size_btns[i].set_pressed_no_signal(greys == game.greys_per_team)
		_size_btns[i].disabled = not host or (greys != game.greys_per_team and game.lobby.size() > 2 * (1 + greys))
		_size_btns[i].tooltip_text = "" if host else "The host picks the team size."

	var my_team := -1
	for e: Dictionary in game.lobby:
		if e["id"] == me:
			my_team = e["team"]
	for team in 2:
		var n: int = game.team_count(team)
		_team_heads[team].text = "%d / %d" % [n, per_team]
		var b := _team_btns[team]
		if my_team == team:
			b.text = "You're on this team"
			b.disabled = true
		elif n >= per_team:
			b.text = "Team full"
			b.disabled = true
		else:
			b.text = "Join %s" % Cfg.TEAM_NAMES[team]
			b.disabled = false

	_count.text = "%d / %d players" % [game.lobby.size(), game.room_size()]
	_count.add_theme_color_override("font_color", UI.GOLD if full else Color.WHITE)
	if full:
		_room_note.text = "The room is full. Anyone else who tries to join will be told so%s." % (
				", unless you pick a bigger team size" if host and game.greys_per_team < 3 else "")
	else:
		_room_note.text = "Bots fill every open seat."
	_start_btn.visible = host
	var host_name := ""
	for e: Dictionary in game.lobby:
		if e["id"] == game.LOCAL:
			host_name = e["name"]
	_waiting.text = "" if host else "Waiting for %s to start the match…" % (host_name if host_name != "" else "the host")
	if not host:
		var ping: int = game.ping_ms
		if ping >= 0:
			_waiting.text += "   ·   ping %d ms" % ping

	var sig := "%s|%d|%d" % [str(game.lobby), game.greys_per_team, me]
	if sig == _lobby_sig:
		return
	_lobby_sig = sig
	for team in 2:
		var list := _team_lists[team]
		for child in list.get_children():
			list.remove_child(child)
			child.queue_free()
		list.custom_minimum_size.y = per_team * 34 - 6
		var shown := 0
		for e: Dictionary in game.lobby:
			if e["team"] != team:
				continue
			list.add_child(_player_row(e, e["id"] == me, e["id"] == game.LOCAL, team))
			shown += 1
		for k in range(shown, per_team):
			list.add_child(_open_row())


## A button that lets (or stops) a second player at this machine joining.
## Off, every keyboard and gamepad here drives the one player.
func _p2_toggle() -> Button:
	var b := UI.button("")
	b.toggle_mode = true
	b.custom_minimum_size.x = 190
	b.toggled.connect(func(on: bool) -> void: Settings.set_value("extra_players", on))
	_p2_btns.append(b)
	return b


func _p2_key() -> String:
	return OS.get_keycode_string(Settings.keys("kb2", "swap")[0])


## A gamepad joins with its jump button.
func _pad_join() -> String:
	return Settings.pad_button_name(Settings.keys("pad", "jump")[0])


func _player_row(e: Dictionary, mine: bool, is_host: bool, team: int) -> Control:
	var r := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Cfg.TEAM_COLORS[team], 0.28 if mine else 0.16)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	if mine:
		sb.border_color = UI.GOLD
		sb.set_border_width_all(2)
	r.add_theme_stylebox_override("panel", sb)
	r.custom_minimum_size = Vector2(0, 28)
	var h := UI.row(8)
	r.add_child(h)
	var n := UI.label(e["name"], 18, UI.GOLD if mine else Color.WHITE)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.clip_text = true
	h.add_child(n)
	if mine:
		h.add_child(UI.label("you", 14, UI.DIM))
	if is_host:
		h.add_child(UI.label("HOST", 14, UI.GOLD))
	return r


func _open_row() -> Control:
	var r := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.03)
	sb.border_color = Color(1, 1, 1, 0.1)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	r.add_theme_stylebox_override("panel", sb)
	r.custom_minimum_size = Vector2(0, 28)
	r.add_child(UI.label("Open seat · a bot plays", 15, Color(1, 1, 1, 0.35)))
	return r


func _build_pause() -> void:
	var box := _add_page("pause", 420)
	box.add_child(UI.title("MENU"))
	_pause_note = UI.label("", 15, UI.DIM, true)
	_pause_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_pause_note)
	var add := func(key: String, text: String, f: Callable) -> void:
		var b := UI.big_button(text, f)
		b.size_flags_horizontal = Control.SIZE_FILL
		box.add_child(b)
		_pause_btns[key] = b
	add.call("resume", "Resume", _resume)
	add.call("restart", "Restart match", func() -> void:
		game.start_local(game.greys_per_team)
		show_page(""))
	add.call("help", "", func() -> void:
		game.show_help = not game.show_help
		_resume())
	add.call("settings", "Settings", func() -> void: _open_settings("pause"))
	add.call("lobby", "End match · back to lobby", func() -> void: game.end_match())
	add.call("setup", "Back to setup", func() -> void: game.end_match())
	add.call("leave", "Leave room", func() -> void:
		_after_room = "online"
		game.leave())
	add.call("home", "Quit to home screen", func() -> void:
		_after_room = "home"
		if game.role == game.Role.OFFLINE:
			game.end_match()
		else:
			game.leave())
	_first["pause"] = _pause_btns["resume"]


func _refresh_pause() -> void:
	_pause_btns["help"].text = "Hide controls" if game.show_help else "Show controls"
	var offline: bool = game.role == game.Role.OFFLINE
	var host: bool = game.role == game.Role.HOST
	_pause_btns["restart"].visible = offline
	_pause_btns["setup"].visible = offline
	_pause_btns["lobby"].visible = host
	_pause_btns["leave"].visible = not offline
	if offline:
		_pause_note.text = "Paused."
	elif host:
		_pause_note.text = "The game is paused for everyone while this is open."
	else:
		_pause_note.text = "The game carries on while this is open; only the host can pause."
	_pause_btns["home"].text = "Quit to home screen" if offline else ("Close room · home screen" if host else "Leave · home screen")
	_pause_btns["leave"].visible = false if host else not offline


func _open_pause() -> void:
	game.set_paused(true)
	show_page("pause")


func _resume() -> void:
	game.set_paused(false)
	show_page("")


func _open_settings(from: String) -> void:
	_settings_from = from
	show_page("settings")


func _close_settings() -> void:
	if _settings_from == "pause" and not game.in_match:
		_follow()
		return
	show_page(_settings_from)
