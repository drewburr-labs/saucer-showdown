extends RefCounted
## Plain data for everything the simulation moves around.

enum Kind { OVERLORD, GREY }
enum CowState { LOOSE, CARRIED, BEAMED }


class Unit extends RefCounted:
	var id := 0
	var team := 0
	var kind := 1 # Kind
	var slot := 0 # index among the team's greys
	var pos := Vector2.ZERO # centre of the hitbox
	var vel := Vector2.ZERO
	var half := Vector2.ZERO
	var facing := 1.0
	var alive := true
	var respawn_t := 0.0
	var shield_t := 0.0
	var fire_cd := 0.0
	var grounded := false
	var on_plat := -1 # index into MapData.platforms, -1 in the air or on a wreck

	# Overlord
	var lives := 3
	var beam_target = null # Cow or Unit being lifted

	# Grey
	var warrior := false
	var speedy := false
	var hover_fuel := 0.0
	var carrying = null # Cow
	var riding := false
	var held_by = null # Overlord beaming this grey
	var drop_t := 0.0
	var pickup_cd := 0.0
	var gate_t := 0.0

	# Inputs. A human or a bot writes these before every Sim.step().
	var in_move := Vector2.ZERO
	var in_aim := Vector2.ZERO # optional; falls back to in_move, then facing
	var in_jump := false
	var in_action := false # fire (Overlord, warrior) or use (worker)
	var in_beam := false
	var prev_jump := false
	var prev_action := false


class Cow extends RefCounted:
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var half := Vector2.ZERO
	var state := 0 # CowState
	var holder = null # Unit carrying or beaming it
	var probed := false
	var grounded := false
	var on_plat := -1
	var wander_t := 0.0


class Bolt extends RefCounted:
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var team := 0
	var from_kind := 0 # Kind of the shooter
	var life := 0.0


class Wreck extends RefCounted:
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var half := Vector2.ZERO
	var grounded := false
	var on_plat := -1
	var owner = null # the downed Overlord


class Tractor extends RefCounted:
	var pos := Vector2.ZERO
	var rider = null # Unit
	var dir := 0.0
