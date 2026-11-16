extends Node
## Checks GitHub Releases for a newer build and installs it over this one.
##
## Only release builds update themselves: the version is the release tag, which
## the release workflow stamps into project.godot. Editor runs, "dev" builds
## and builds exported with the "steam" feature (Steam does its own updating)
## leave it switched off.

const RELEASES_REPO := "drewburr-labs/saucer-showdown"
const DEV_VERSION := "dev"
## The executable's name inside each platform's release zip.
const EXE_NAMES := {"linux": "saucer-showdown.x86_64", "windows": "saucer-showdown.exe"}
const EXEC_PERMISSIONS := 0x1ED # rwxr-xr-x
## How long a one-off message ("You're up to date") stays on screen.
const NOTE_MS := 5000
## F5 within this long of a failure leaves the failure up rather than asking again.
const RETRY_MS := 1000

enum State { OFF, CHECKING, IDLE, AVAILABLE, DOWNLOADING, INSTALLING, FAILED }

var state := State.OFF
var version := DEV_VERSION # the running build
var latest := "" # tag of the newest release, once known
var error := ""
var feed_url := "https://api.github.com/repos/%s/releases/latest" % RELEASES_REPO

var _asset := {} # the release asset for this platform
var _auto := false
var _manual := false # the current check was asked for with F5
var _retry := false # install whatever the current check finds (F5 after a failure)
var _failed_at := -RETRY_MS * 100 # ticks of the last failed check or install
var _note := ""
var _note_until := 0
var _http: HTTPRequest


func _ready() -> void:
	version = str(ProjectSettings.get_setting("application/config/version", DEV_VERSION))
	_http = HTTPRequest.new()
	_http.timeout = 20.0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	if OS.is_debug_build():
		# Test hooks, so an update can be rehearsed against a local feed.
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--update-feed="):
				feed_url = arg.trim_prefix("--update-feed=")
			elif arg == "--update-auto":
				_auto = true


func enabled() -> bool:
	return version != DEV_VERSION and platform() != "" \
			and not OS.has_feature("editor") and not OS.has_feature("steam")


## Ask the feed for the newest release. Failures are quiet: no network is not
## the player's problem.
func check() -> void:
	if not enabled() or state == State.CHECKING or state == State.DOWNLOADING or state == State.INSTALLING:
		return
	state = State.CHECKING
	_http.download_file = "" # a failed install may have left these set for its download
	_http.timeout = 20.0
	var headers := ["Accept: application/vnd.github+json", "User-Agent: SaucerShowdown/%s" % version]
	if _http.request(feed_url, headers) != OK:
		state = State.IDLE
		_retry = false
		_failed_at = Time.get_ticks_msec()
		if _manual:
			_manual = false
			_say("Couldn't start the update check")


## Download and install the release found by check(). After a failure, ask
## the feed again and install what it finds: a release whose builds were still
## being uploaded may have them by now.
func install() -> void:
	if (state == State.FAILED or state == State.IDLE) and Time.get_ticks_msec() - _failed_at < RETRY_MS:
		return # it only just failed; asking again this soon would fail the same way
	if state == State.FAILED:
		state = State.IDLE
		_retry = true
	if state == State.OFF or state == State.IDLE:
		# Nothing known to install: F5 asks GitHub again and says what it found.
		if not enabled():
			_say("Updates are off in this build (version %s)" % version)
		else:
			_manual = true
			check()
		return
	if state != State.AVAILABLE:
		return
	if _asset.is_empty():
		_fail("no %s build in release %s" % [platform(), latest])
		return
	if not _can_write(_install_dir()):
		_fail("can't write to the game folder")
		return
	DirAccess.make_dir_recursive_absolute(_work_dir())
	_http.download_file = _zip_path()
	_http.timeout = 0.0
	if _http.request(_asset["url"], ["User-Agent: SaucerShowdown/%s" % version]) != OK:
		_fail("couldn't start the download")
		return
	state = State.DOWNLOADING


## Download progress, 0 to 1.
func progress() -> float:
	var size := float(_asset.get("size", 0))
	if state != State.DOWNLOADING or size <= 0.0:
		return 0.0
	return clampf(_http.get_downloaded_bytes() / size, 0.0, 1.0)


## One line for the HUD; empty when there is nothing to say.
func status_text() -> String:
	if state == State.CHECKING and _manual:
		return "Checking for updates…"
	if _note != "" and Time.get_ticks_msec() < _note_until and state != State.AVAILABLE \
			and state != State.DOWNLOADING and state != State.INSTALLING and state != State.FAILED:
		return _note
	match state:
		State.AVAILABLE:
			return "Update %s is available  ·  F5 to install" % latest
		State.DOWNLOADING:
			return "Downloading %s…  %d%%" % [latest, int(progress() * 100.0)]
		State.INSTALLING:
			return "Installing %s, restarting…" % latest
		State.FAILED:
			return "Update failed: %s  ·  F5 to retry" % error
	return ""


# ------------------------------------------------------------- pure helpers

static func platform() -> String:
	match OS.get_name():
		"Windows":
			return "windows"
		"Linux":
			return "linux"
	return ""


## [major, minor, patch, pre-release] for tags like "v1.2.3" or "1.2.3-beta1";
## empty when the tag is not a version number.
static func parse_version(tag: String) -> Array:
	var s := tag.strip_edges().trim_prefix("v").trim_prefix("V")
	var plus := s.find("+")
	if plus >= 0:
		s = s.substr(0, plus) # build metadata never affects ordering
	var pre := ""
	var dash := s.find("-")
	if dash >= 0:
		pre = s.substr(dash + 1)
		s = s.substr(0, dash)
	var parts := s.split(".")
	if s.is_empty() or parts.size() > 3:
		return []
	var out := [0, 0, 0, pre]
	for i in parts.size():
		if not parts[i].is_valid_int() or parts[i].begins_with("-") or parts[i].begins_with("+"):
			return []
		out[i] = parts[i].to_int()
	return out


## Whether release `candidate` should replace the running `current` build.
static func is_newer(candidate: String, current: String) -> bool:
	if candidate == current:
		return false
	var a := parse_version(candidate)
	var b := parse_version(current)
	if a.is_empty() or b.is_empty():
		return true # can't order them, so trust the feed's idea of "latest"
	for i in 3:
		if a[i] != b[i]:
			return a[i] > b[i]
	return a[3] == "" and b[3] != "" # 1.0.0 replaces 1.0.0-beta


## The asset for `plat` from a GitHub release's "assets" list: the zip whose
## name ends in "-<plat>.zip". Returns {} when the release has none.
static func pick_asset(assets: Array, plat: String) -> Dictionary:
	for a in assets:
		if a is Dictionary and str(a.get("name", "")).ends_with("-%s.zip" % plat):
			var digest := str(a.get("digest", ""))
			return {
				"name": str(a["name"]),
				"url": str(a.get("browser_download_url", "")),
				"size": int(a.get("size", 0)),
				"sha256": digest.trim_prefix("sha256:") if digest.begins_with("sha256:") else "",
			}
	return {}


# ------------------------------------------------------------------ requests

func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if state == State.CHECKING:
		_on_checked(result, code, body)
	elif state == State.DOWNLOADING:
		_on_downloaded(result, code)


func _on_checked(result: int, code: int, body: PackedByteArray) -> void:
	state = State.IDLE
	var manual := _manual
	var retry := _retry
	_manual = false
	_retry = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_failed_at = Time.get_ticks_msec()
		print("Update check failed (result %d, HTTP %d)." % [result, code])
		if manual:
			_say("Couldn't check for updates (%s)" % (
					"HTTP %d" % code if result == HTTPRequest.RESULT_SUCCESS else "no connection"))
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary or not data.has("tag_name"):
		_failed_at = Time.get_ticks_msec()
		print("Update check failed: unexpected reply.")
		if manual:
			_say("Couldn't check for updates (unexpected reply)")
		return
	latest = str(data["tag_name"])
	if not is_newer(latest, version):
		if manual:
			_say("You're up to date (%s)" % version)
		return
	var assets = data.get("assets", [])
	_asset = pick_asset(assets if assets is Array else [], platform())
	state = State.AVAILABLE
	if _auto or retry:
		install()


func _on_downloaded(result: int, code: int) -> void:
	_http.download_file = ""
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail("download failed (HTTP %d)" % code)
		return
	if _asset["sha256"] != "" and FileAccess.get_sha256(_zip_path()) != _asset["sha256"]:
		_fail("the download is corrupt")
		return
	state = State.INSTALLING
	# Let the HUD draw "Installing…" before the blocking unzip.
	await get_tree().process_frame
	await get_tree().process_frame
	var exe := OS.get_executable_path()
	var err := _install_windows(exe) if platform() == "windows" else _install_in_place(exe)
	DirAccess.remove_absolute(_zip_path())
	if err != "":
		_fail(err)
		return
	get_tree().quit()


func _say(text: String) -> void:
	_note = text
	_note_until = Time.get_ticks_msec() + NOTE_MS
	print(text)


func _fail(why: String) -> void:
	error = why
	state = State.FAILED
	_failed_at = Time.get_ticks_msec()
	push_warning("Update failed: %s" % why)


# ---------------------------------------------------------------- installing

## Linux lets a running program's file be replaced, so unpack straight over
## the install and start the new build.
func _install_in_place(exe: String) -> String:
	var err := _unpack(_zip_path(), exe.get_base_dir(), exe.get_file())
	if err != "":
		return err
	if OS.create_process(exe, OS.get_cmdline_args()) < 0:
		return "installed, but couldn't restart; start the game again"
	return ""


## Windows locks a running .exe, so unpack next to the save data and leave a
## small script to copy it over once this process has gone, then relaunch.
func _install_windows(exe: String) -> String:
	var staged := _work_dir().path_join("staged")
	var script := _work_dir().path_join("apply.cmd")
	var dst := exe.get_base_dir()
	for path: String in [staged, script, dst]:
		if path.contains("%"):
			return "the game is in a folder with % in its name"
	_remove_tree(staged)
	var err := _unpack(_zip_path(), staged, exe.get_file())
	if err != "":
		return err
	var lines := [
		"@echo off",
		"set \"PID=%d\"" % OS.get_process_id(),
		"set \"SRC=%s\"" % staged.replace("/", "\\"),
		"set \"DST=%s\"" % dst.replace("/", "\\"),
		"set \"EXE=%s\"" % exe.get_file(),
		":wait",
		"tasklist /FI \"PID eq %PID%\" /NH 2>nul | find \" %PID% \" >nul",
		"if errorlevel 1 goto apply",
		"ping -n 2 127.0.0.1 >nul",
		"goto wait",
		":apply",
		"xcopy \"%SRC%\\*\" \"%DST%\\\" /E /Y /Q >nul",
		"rmdir /S /Q \"%SRC%\"",
		"start \"\" \"%DST%\\%EXE%\"",
	]
	var f := FileAccess.open(script, FileAccess.WRITE)
	if f == null:
		return "couldn't write the update script"
	f.store_string("\r\n".join(lines) + "\r\n")
	f.close()
	if OS.create_process("cmd.exe", ["/c", script.replace("/", "\\")]) < 0:
		return "couldn't start the update script"
	return ""


## Unpack `zip_path` into `dest`. The game's executable is written under
## `exe_name`, so an install whose .exe was renamed keeps its name.
func _unpack(zip_path: String, dest: String, exe_name: String) -> String:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return "couldn't open the download"
	for entry in zip.get_files():
		if entry.ends_with("/"):
			continue
		if entry.is_absolute_path() or entry.contains("..") or entry.contains("\\"):
			return "the download has an unsafe path"
		var is_exe: bool = entry == EXE_NAMES[platform()]
		var target := dest.path_join(exe_name if is_exe else entry)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var tmp := target + ".new"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			return "couldn't write %s" % target.get_file()
		f.store_buffer(zip.read_file(entry))
		f.close()
		if is_exe and platform() == "linux":
			FileAccess.set_unix_permissions(tmp, EXEC_PERMISSIONS)
		if DirAccess.rename_absolute(tmp, target) != OK:
			DirAccess.remove_absolute(tmp)
			return "couldn't replace %s" % target.get_file()
	zip.close()
	return ""


func _install_dir() -> String:
	return OS.get_executable_path().get_base_dir()


func _work_dir() -> String:
	return OS.get_user_data_dir().path_join("update")


func _zip_path() -> String:
	return _work_dir().path_join("download.zip")


func _can_write(dir: String) -> bool:
	var probe := dir.path_join(".update-probe")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true


func _remove_tree(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_tree(dir.path_join(sub))
	for file in d.get_files():
		d.remove(file)
	DirAccess.remove_absolute(dir)
