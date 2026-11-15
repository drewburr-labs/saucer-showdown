extends SceneTree
## Balance probe: plays bot-only matches and tallies how they end and who
## kills whom. Pass the greys per team after `--` (1 = 2v2, 3 = 4v4).
##   godot --headless --path . --script tests/bot_stats.gd -- 3
const E = preload("res://scripts/sim/entities.gd")
const Sim = preload("res://scripts/sim/sim.gd")
const InputFrame = preload("res://scripts/sim/input_frame.gd")
func _init() -> void:
	var tally := {}
	var g: int = int(OS.get_cmdline_user_args()[0]) if OS.get_cmdline_user_args().size() > 0 else 1
	for s in 8:
		var sim := Sim.new(100 + s, g)
		var frame := InputFrame.all_bots(sim.units.size())
		while sim.winner < 0 and sim.time < 480.0:
			sim.step_frame(frame)
			var tasks := {}
			for b in sim.bots:
				tasks[b.u.id] = b.task
			for ev in sim.events:
				if ev["type"] == "kill":
					var who := "overlord" if ev["kind"] == E.Kind.OVERLORD else "grey"
					var key := "%s killed by %s" % [who, ev["by"]]
					if who == "overlord":
						var o: E.Unit = sim.overlord(ev["team"])
						key += " while " + str(tasks[o.id]) + (" (low)" if ev["pos"].y > 450 else " (high)")
					tally[key] = tally.get(key, 0) + 1
		print("seed %d: %s t=%d silo=%s lives=%d/%d tractor=%d" % [100 + s, Sim.WIN_NAMES[sim.win_reason] if sim.winner >= 0 else "none", int(sim.time), sim.silo, sim.overlord(0).lives, sim.overlord(1).lives, int(sim.tractor.pos.x)])
		sim.dispose()
	for k in tally:
		print("%4d  %s" % [tally[k], k])
	quit()
