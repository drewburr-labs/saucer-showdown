extends RefCounted
## The player's settings: name, sound, display and key and button bindings. Kept in
## user://settings.cfg, read on first use and written on every change.
## Nothing in the sim reads these.

## Where settings are kept; tests point this at a scratch file.
static var path := "user://settings.cfg"

const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
		Vector2i(2560, 1440), Vector2i(3840, 2160)]
const FPS_CAPS := [30, 60, 120, 144, 165, 240, 0] # 0 = unlimited
enum WindowMode { WINDOWED, FULLSCREEN, EXCLUSIVE }
const WINDOW_MODES := ["Windowed", "Fullscreen", "Exclusive fullscreen"]
const BUSES := ["Master", "Music", "Effects"]

const DEFAULTS := {
	"name": "",
	"vol_Master": 0.8,
	"vol_Music": 0.7,
	"vol_Effects": 0.8,
	"mute": false,
	"window_mode": WindowMode.WINDOWED,
	"resolution": Vector2i(1280, 720),
	"vsync": true,
	"max_fps": 0,
	"show_fps": false,
	"extra_players": false, # more players at this machine can join (Enter, or a gamepad's jump)
	"role": 0, # what Player 1 plays in local games: 0 the Overlord, 1 a Grey (Main.OVERLORD / GREY)
}

## Rebindable actions, in the order the controls page lists them.
const ACTIONS := ["left", "right", "up", "down", "jump", "action", "beam", "swap"]
const ACTION_NAMES := {
	"left": "Move left", "right": "Move right", "up": "Move up", "down": "Move down",
	"jump": "Jump", "action": "Fire / use", "beam": "Tractor beam", "swap": "Switch unit / join",
}
## Gamepad triggers are axes, not buttons; bindings name them with these.
const PAD_LT := 100
const PAD_RT := 101
## Short names for gamepad buttons, by JOY_BUTTON_* index.
const PAD_BUTTON_NAMES := ["A", "B", "X", "Y", "Back", "Guide", "Start", "L3", "R3", "LB", "RB",
		"D-pad up", "D-pad down", "D-pad left", "D-pad right", "Misc", "Paddle 1", "Paddle 2",
		"Paddle 3", "Paddle 4", "Touchpad"]

## Bindings per device: keyboards "kb1" and "kb2" bind keycodes; "pad", shared
## by every gamepad, binds JOY_BUTTON_* indexes or PAD_LT / PAD_RT. The left
## stick always moves as well, whatever the d-pad is bound to.
const DEFAULT_KEYS := {
	"kb1": {
		"left": [KEY_A], "right": [KEY_D], "up": [KEY_W], "down": [KEY_S],
		"jump": [KEY_SPACE, KEY_W], "action": [KEY_J, KEY_F], "beam": [KEY_K, KEY_G], "swap": [KEY_Q],
	},
	"kb2": {
		"left": [KEY_LEFT], "right": [KEY_RIGHT], "up": [KEY_UP], "down": [KEY_DOWN],
		"jump": [KEY_UP, KEY_KP_0], "action": [KEY_PERIOD, KEY_KP_1], "beam": [KEY_SLASH, KEY_KP_2],
		"swap": [KEY_ENTER, KEY_KP_ENTER],
	},
	"pad": {
		"left": [JOY_BUTTON_DPAD_LEFT], "right": [JOY_BUTTON_DPAD_RIGHT],
		"up": [JOY_BUTTON_DPAD_UP], "down": [JOY_BUTTON_DPAD_DOWN],
		"jump": [JOY_BUTTON_A], "action": [JOY_BUTTON_X, PAD_RT],
		"beam": [JOY_BUTTON_B, JOY_BUTTON_RIGHT_SHOULDER], "swap": [JOY_BUTTON_Y],
	},
}

static var _cfg: ConfigFile
static var _keys := {} # "device.action" -> keys


static func _file() -> ConfigFile:
	if _cfg == null:
		_cfg = ConfigFile.new()
		_cfg.load(path) # a missing file just means defaults
	return _cfg


static func value(key: String) -> Variant:
	var v = _file().get_value("game", key, DEFAULTS[key])
	return v if typeof(v) == typeof(DEFAULTS[key]) else DEFAULTS[key]


static func set_value(key: String, v: Variant) -> void:
	_file().set_value("game", key, v)
	_save()


## What's bound to `action` on `device` ("kb1", "kb2" or "pad"); see
## DEFAULT_KEYS. Read every tick, so they're cached.
static func keys(device: String, action: String) -> Array:
	var id := "%s.%s" % [device, action]
	if not _keys.has(id):
		var v = _file().get_value("keys", id) if _file().has_section_key("keys", id) else null
		_keys[id] = v if v is Array and not v.is_empty() else DEFAULT_KEYS[device][action]
	return _keys[id]


static func set_keys(device: String, action: String, list: Array) -> void:
	_file().set_value("keys", "%s.%s" % [device, action], list)
	_keys.clear()
	_save()


static func reset_keys() -> void:
	if _file().has_section("keys"):
		_file().erase_section("keys")
	_keys.clear()
	_save()


## The bindings in `list`, for showing: "Space / W", "X / RT".
static func key_names(device: String, list: Array) -> String:
	var out := PackedStringArray()
	for k: int in list:
		out.append(pad_button_name(k) if device == "pad" else OS.get_keycode_string(k))
	return " / ".join(out)


static func pad_button_name(code: int) -> String:
	if code == PAD_LT:
		return "LT"
	if code == PAD_RT:
		return "RT"
	return PAD_BUTTON_NAMES[code] if code >= 0 and code < PAD_BUTTON_NAMES.size() else "Button %d" % code


static func _save() -> void:
	_file().save(path)


# --- Applying them -------------------------------------------------------

## Put every setting into effect; call once at start-up.
static func apply_all() -> void:
	apply_audio()
	apply_display()


static func apply_audio() -> void:
	for bus: String in BUSES:
		var i := AudioServer.get_bus_index(bus)
		if i < 0:
			# default_bus_layout.tres has them; this covers a project without it.
			AudioServer.add_bus()
			i = AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, bus)
			AudioServer.set_bus_send(i, "Master")
		var v: float = value("vol_" + bus)
		AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.0001)))
		AudioServer.set_bus_mute(i, v <= 0.0 or (bus == "Master" and value("mute")))


static func apply_display() -> void:
	var cap: int = value("max_fps")
	Engine.max_fps = cap
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if value("vsync") else DisplayServer.VSYNC_DISABLED)
	var mode: int = value("window_mode")
	match mode:
		WindowMode.FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		WindowMode.EXCLUSIVE:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		_:
			if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var size: Vector2i = value("resolution")
			var screen := DisplayServer.window_get_current_screen()
			var usable := DisplayServer.screen_get_usable_rect(screen)
			if usable.size.x > 0:
				size = size.min(usable.size)
			if DisplayServer.window_get_size() != size:
				DisplayServer.window_set_size(size)
				if usable.size.x > 0:
					DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)


## The resolutions that fit this screen (always at least the first).
static func resolutions() -> Array:
	var out := [RESOLUTIONS[0]]
	var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()) \
			if DisplayServer.get_name() != "headless" else Vector2i(1920, 1080)
	for r: Vector2i in RESOLUTIONS.slice(1):
		if r.x <= screen.x and r.y <= screen.y:
			out.append(r)
	return out


## A name to show when the player hasn't picked one.
static func player_name() -> String:
	var n := clean_name(value("name"))
	return n if n != "" else "Player"


## Trim a typed name to something safe to show: one line, at most 16 chars.
static func clean_name(text: String) -> String:
	var out := ""
	for ch in text.strip_edges():
		if ch.unicode_at(0) >= 32:
			out += ch
	return out.strip_edges().left(16)
