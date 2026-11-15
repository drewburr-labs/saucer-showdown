extends RefCounted
## Polls local keyboards and gamepads into one small state per device, so the
## game never touches Input directly. Call poll() once per tick.

const InputFrame = preload("res://scripts/sim/input_frame.gd")

const DEVICES := ["kb1", "kb2", "pad0", "pad1", "pad2", "pad3"]
## A packet holds every device's state in InputFrame's 5-byte layout, with
## SWAP and JOIN added to the button byte. It is what a machine sends the host.
const PACKET_BYTES := 6 * InputFrame.UNIT_BYTES
const STICK_DEADZONE := 0.25
const AIM_DEADZONE := 0.4

var _cur: Dictionary = {}
var _prev: Dictionary = {}


func _init() -> void:
	for d in DEVICES:
		_cur[d] = _blank()
		_prev[d] = _blank()


func poll() -> void:
	for d in DEVICES:
		_prev[d] = _cur[d]
		_cur[d] = _read(d)


func state(device: String) -> Dictionary:
	return _cur[device]


## True on the tick `key` went down. Keys: jump, action, beam, swap, join.
func pressed(device: String, key: String) -> bool:
	return _cur[device][key] and not _prev[device][key]


## This tick's state of every device, packed for the host.
func packet() -> PackedByteArray:
	var p := blank_packet()
	for i in DEVICES.size():
		var s: Dictionary = _cur[DEVICES[i]]
		InputFrame.put(p, i, s)
		var o := i * InputFrame.UNIT_BYTES + 4
		p[o] = p[o] | (InputFrame.SWAP if s["swap"] else 0) | (InputFrame.JOIN if s["join"] else 0)
	return p


static func blank_packet() -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(PACKET_BYTES)
	return p


func _blank() -> Dictionary:
	return {
		"move": Vector2.ZERO, "aim": Vector2.ZERO,
		"jump": false, "action": false, "beam": false, "swap": false, "join": false,
	}


func _read(device: String) -> Dictionary:
	match device:
		"kb1":
			return _keys(KEY_A, KEY_D, KEY_W, KEY_S, [KEY_SPACE, KEY_W], [KEY_J, KEY_F], [KEY_K, KEY_G], [KEY_Q])
		"kb2":
			return _keys(KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, [KEY_UP, KEY_KP_0],
					[KEY_PERIOD, KEY_KP_1], [KEY_SLASH, KEY_KP_2], [KEY_ENTER, KEY_KP_ENTER])
	return _pad(int(device.substr(3)))


func _keys(left: int, right: int, up: int, down: int, jump: Array, action: Array, beam: Array, swap: Array) -> Dictionary:
	var s := _blank()
	s["move"] = Vector2(
		float(_down(right)) - float(_down(left)),
		float(_down(down)) - float(_down(up)))
	s["jump"] = _any(jump)
	s["action"] = _any(action)
	s["beam"] = _any(beam)
	s["swap"] = _any(swap)
	s["join"] = s["swap"]
	return s


func _pad(id: int) -> Dictionary:
	var s := _blank()
	if not Input.get_connected_joypads().has(id):
		return s
	var move := Vector2(Input.get_joy_axis(id, JOY_AXIS_LEFT_X), Input.get_joy_axis(id, JOY_AXIS_LEFT_Y))
	if move.length() < STICK_DEADZONE:
		move = Vector2.ZERO
	move.x += float(Input.is_joy_button_pressed(id, JOY_BUTTON_DPAD_RIGHT)) - float(Input.is_joy_button_pressed(id, JOY_BUTTON_DPAD_LEFT))
	move.y += float(Input.is_joy_button_pressed(id, JOY_BUTTON_DPAD_DOWN)) - float(Input.is_joy_button_pressed(id, JOY_BUTTON_DPAD_UP))
	s["move"] = move.limit_length(1.0)
	var aim := Vector2(Input.get_joy_axis(id, JOY_AXIS_RIGHT_X), Input.get_joy_axis(id, JOY_AXIS_RIGHT_Y))
	if aim.length() >= AIM_DEADZONE:
		s["aim"] = aim.normalized()
	s["jump"] = Input.is_joy_button_pressed(id, JOY_BUTTON_A)
	s["action"] = Input.is_joy_button_pressed(id, JOY_BUTTON_X) or Input.get_joy_axis(id, JOY_AXIS_TRIGGER_RIGHT) > 0.5
	s["beam"] = Input.is_joy_button_pressed(id, JOY_BUTTON_B) or Input.is_joy_button_pressed(id, JOY_BUTTON_RIGHT_SHOULDER)
	s["swap"] = Input.is_joy_button_pressed(id, JOY_BUTTON_Y)
	s["join"] = Input.is_joy_button_pressed(id, JOY_BUTTON_START) or s["jump"]
	return s


func _down(key: int) -> bool:
	return Input.is_physical_key_pressed(key)


func _any(keys: Array) -> bool:
	for k in keys:
		if Input.is_physical_key_pressed(k):
			return true
	return false
