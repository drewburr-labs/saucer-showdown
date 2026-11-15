extends RefCounted
## One tick of input for every unit, packed into bytes. This is what peers
## will send each other: Sim.step_frame() takes a frame, so a match is fully
## described by its seed and the frames fed to it.
##
## Each unit gets UNIT_BYTES bytes, in Sim.units order:
##   0  move.x  signed, -127..127 for -1..1
##   1  move.y
##   2  aim.x
##   3  aim.y
##   4  buttons: JUMP | ACTION | BEAM, or BOT when the sim's own bot drives it
## Sticks are quantised here, so every peer feeds the sim the same values.

const UNIT_BYTES := 5
const JUMP := 1
const ACTION := 2
const BEAM := 4
const BOT := 128


## A frame with every unit left to its bot.
static func all_bots(unit_count: int) -> PackedByteArray:
	var f := PackedByteArray()
	f.resize(unit_count * UNIT_BYTES)
	for i in unit_count:
		f[i * UNIT_BYTES + 4] = BOT
	return f


## Write one human unit's input into `frame`. `s` is shaped like LocalInput's
## state: move, aim, jump, action, beam.
static func put(frame: PackedByteArray, unit_index: int, s: Dictionary) -> void:
	var o := unit_index * UNIT_BYTES
	var move: Vector2 = s.get("move", Vector2.ZERO)
	var aim: Vector2 = s.get("aim", Vector2.ZERO)
	frame.encode_s8(o, _q(move.x))
	frame.encode_s8(o + 1, _q(move.y))
	frame.encode_s8(o + 2, _q(aim.x))
	frame.encode_s8(o + 3, _q(aim.y))
	frame[o + 4] = (JUMP if s.get("jump", false) else 0) \
			| (ACTION if s.get("action", false) else 0) \
			| (BEAM if s.get("beam", false) else 0)


static func is_bot(frame: PackedByteArray, unit_index: int) -> bool:
	return frame[unit_index * UNIT_BYTES + 4] & BOT != 0


## Copy a human unit's input from `frame` into its in_* fields.
static func apply(frame: PackedByteArray, unit_index: int, u) -> void:
	var o := unit_index * UNIT_BYTES
	u.in_move = Vector2(frame.decode_s8(o) / 127.0, frame.decode_s8(o + 1) / 127.0)
	u.in_aim = Vector2(frame.decode_s8(o + 2) / 127.0, frame.decode_s8(o + 3) / 127.0)
	var b: int = frame[o + 4]
	u.in_jump = b & JUMP != 0
	u.in_action = b & ACTION != 0
	u.in_beam = b & BEAM != 0


static func _q(v: float) -> int:
	return int(roundf(clampf(v, -1.0, 1.0) * 127.0))
