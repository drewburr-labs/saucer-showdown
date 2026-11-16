extends RefCounted
## The player's settings: name, sound, display and key bindings. Kept in
## user://settings.cfg, read on first use and written on every change.
## Nothing in the sim reads these.

const PATH := "user://settings.cfg"

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
}

## Rebindable keyboard actions, in the order the controls page lists them.
const ACTIONS := ["left", "right", "up", "down", "jump", "action", "beam", "swap"]
const ACTION_NAMES := {
	"left": "Move left", "right": "Move right", "up": "Move up", "down": "Move down",
	"jump": "Jump", "action": "Fire / use", "beam": "Tractor beam", "swap": "Switch unit / join",
}
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
}

static var _cfg: ConfigFile
static var _keys := {} # "device.action" -> keys


static func _file() -> ConfigFile:
	if _cfg == null:
		_cfg = ConfigFile.new()
		_cfg.load(PATH) # a missing file just means defaults
	return _cfg


static func value(key: String) -> Variant:
	var v = _file().get_value("game", key, DEFAULTS[key])
	return v if typeof(v) == typeof(DEFAULTS[key]) else DEFAULTS[key]


static func set_value(key: String, v: Variant) -> void:
	_file().set_value("game", key, v)
	_save()


## The keys bound to `action` for keyboard `device` ("kb1" or "kb2").
## Read every tick, so they're cached.
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


static func key_names(list: Array) -> String:
	var out := PackedStringArray()
	for k: int in list:
		out.append(OS.get_keycode_string(k))
	return " / ".join(out)


static func _save() -> void:
	_file().save(PATH)


# --- Applying them -------------------------------------------------------

## Put every setting into effect; call once at start-up.
static func apply_all() -> void:
	apply_audio()
	apply_display()


static func apply_audio() -> void:
	for bus: String in BUSES:
		var i := AudioServer.get_bus_index(bus)
		if i < 0:
			# No sounds exist yet; make the buses so they're ready when they do.
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
