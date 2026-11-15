extends SceneTree
## Runs the game for a few seconds and saves screenshots, to check art changes.
## Needs a display (use xvfb-run on a headless box):
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- out_dir [seconds...]

var _main: Node
var _times: Array[float] = []
var _out := "user://shots"
var _t := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	for i in range(1, args.size()):
		_times.append(float(args[i]))
	if _times.is_empty():
		_times = [3.0, 12.0, 30.0]
	DirAccess.make_dir_recursive_absolute(_out)
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	if _t == 0.0:
		_main.set("show_help", false)
		_main.set("greys_per_team", 3)
		_main.call("_new_match")
	_t += delta
	if not _times.is_empty() and _t >= _times[0]:
		var img := root.get_texture().get_image()
		var path := "%s/shot_%05.1f.png" % [_out, _times[0]]
		img.save_png(path)
		print("saved ", path)
		_times.pop_front()
	return _times.is_empty()
