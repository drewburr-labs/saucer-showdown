extends SceneTree
## Plays fixed matches (bots plus scripted "humans") and writes the sim's
## checksum once a second. Two machines that write the same file would stay
## in sync online; CI runs this on Linux and Windows and diffs the output.
##   godot --headless --path . --script tools/sim_trace.gd -- trace.txt

const Sim = preload("res://scripts/sim/sim.gd")
const InputFrame = preload("res://scripts/sim/input_frame.gd")

const TICKS := 60 * 180


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var path: String = args[0] if args.size() > 0 else "user://sim_trace.txt"
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		push_error("can't write %s" % path)
		quit(1)
		return
	for greys in [1, 3]:
		for match_seed in [1, 2, 3]:
			var sim := Sim.new(match_seed, greys)
			var rng := RandomNumberGenerator.new()
			rng.seed = match_seed * 31 + greys
			var held := {}
			var humans := [0, sim.units.size() - 1]
			for t in TICKS:
				var f := InputFrame.all_bots(sim.units.size())
				for i: int in humans:
					if t % 12 == 0:
						held[i] = {
							"move": Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)),
							"aim": Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)),
							"jump": rng.randf() < 0.3, "action": rng.randf() < 0.4, "beam": rng.randf() < 0.3,
						}
					InputFrame.put(f, i, held[i])
				sim.step_frame(f)
				if t % 60 == 59 or sim.winner >= 0:
					out.store_line("%dv%d seed %d tick %d: %08x" % [greys + 1, greys + 1, match_seed, sim.tick, sim.checksum()])
				if sim.winner >= 0:
					break
			out.store_line("%dv%d seed %d ended: winner %d (%s) at tick %d" % [
					greys + 1, greys + 1, match_seed, sim.winner, Sim.WIN_NAMES[sim.win_reason], sim.tick])
			sim.dispose()
	out.close()
	print("wrote %s" % path)
	quit()
