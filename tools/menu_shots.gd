extends SceneTree
## Saves a screenshot of every menu page, to check UI changes. Needs a display
## (use xvfb-run on a headless box):
##   xvfb-run -a godot --path . --script tools/menu_shots.gd -- out_dir

var _main: Node
var _out := "user://menu_shots"
var _steps: Array = []
var _wait := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	var m = _main
	_steps = [
		["home", func() -> void: pass],
		["local", func() -> void: m._menu.show_page("local")],
		["online", func() -> void: m._menu.show_page("online")],
		["settings_sound", func() -> void: m._menu._open_settings("home")],
		["settings_display", func() -> void: m._menu._settings._tabs.current_tab = 1],
		["settings_controls", func() -> void: m._menu._settings._tabs.current_tab = 2],
		["lobby", func() -> void:
			m._menu._close_settings()
			m.player_name = "Drew"
			m.host_lan(24699)
			m.room_code = "KX4PZ"
			m.greys_per_team = 2
			for e in [[11, "Sam", 1, 0], [12, "Priya", 0, 1], [13, "Jo", 1, 1]]:
				m.lobby.append({"id": e[0], "name": e[1], "team": e[2], "role": e[3]})],
		["lobby_full", func() -> void:
			for e in [[14, "Marcus", 1, 1], [15, "Lee", 0, 1]]:
				m.lobby.append({"id": e[0], "name": e[1], "team": e[2], "role": e[3]})],
		["match", func() -> void:
			m.lobby.resize(1)
			m.start_match()
			m.show_help = false],
		["pause", func() -> void: m._menu._open_pause()],
	]


func _process(_delta: float) -> bool:
	_wait += 1
	if _wait < 40:
		return false
	_wait = 0
	if _steps.is_empty():
		return true
	var step: Array = _steps[0]
	if step.size() == 2:
		step[1].call()
		step.append(true)
		return false
	var path := "%s/%s.png" % [_out, step[0]]
	root.get_texture().get_image().save_png(path)
	print("saved ", path)
	_steps.pop_front()
	return false
