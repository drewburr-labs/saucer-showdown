extends SceneTree
## Headless tests for the updater's version and asset logic.
## Run: godot --headless --path . --script tests/test_updater.gd

const Updater = preload("res://scripts/update/updater.gd")

var _failed := 0


func _init() -> void:
	# [candidate, current, should update]
	var cases := [
		["v0.2.0", "v0.1.0", true],
		["v0.1.0", "v0.1.0", false],
		["v0.1.0", "v0.2.0", false],
		["v0.10.0", "v0.9.3", true],
		["v1.0.0", "v0.99.99", true],
		["0.2.0", "v0.1.9", true],
		["v0.2", "v0.1.5", true],
		["v0.2.0", "v0.2", false],
		["v1.0.0", "v1.0.0-beta1", true],
		["v1.0.0-beta1", "v1.0.0", false],
		["v1.0.0+build7", "v1.0.0", false],
		["v0.3.0", "v0.4.0-beta", false],
		["nightly-2", "v0.1.0", true],
	]
	for c: Array in cases:
		_check(Updater.is_newer(c[0], c[1]) == c[2], "is_newer(%s, %s) should be %s" % c)

	_check(Updater.parse_version("v1.2.3") == [1, 2, 3, ""], "parse v1.2.3")
	_check(Updater.parse_version("1.2.3-rc.1") == [1, 2, 3, "rc.1"], "parse pre-release")
	_check(Updater.parse_version("latest").is_empty(), "words are not versions")
	_check(Updater.parse_version("1.2.3.4").is_empty(), "four parts are not a version")
	_check(Updater.parse_version("1.-2.3").is_empty(), "negative parts are not a version")

	var assets := [
		{"name": "notes.txt", "browser_download_url": "https://example.test/notes.txt", "size": 3},
		{"name": "saucer-showdown-v0.2.0-windows.zip", "browser_download_url": "https://example.test/w.zip", "size": 10, "digest": "sha256:abc"},
		{"name": "saucer-showdown-v0.2.0-linux.zip", "browser_download_url": "https://example.test/l.zip", "size": 20, "digest": null},
	]
	var win := Updater.pick_asset(assets, "windows")
	_check(win.get("url") == "https://example.test/w.zip" and win.get("sha256") == "abc" and win.get("size") == 10, "windows asset")
	var lin := Updater.pick_asset(assets, "linux")
	_check(lin.get("url") == "https://example.test/l.zip" and lin.get("sha256") == "", "linux asset without a digest")
	_check(Updater.pick_asset(assets, "macos").is_empty(), "no macOS asset")
	_check(Updater.pick_asset([], "linux").is_empty(), "empty release")

	print("ALL TESTS PASSED" if _failed == 0 else "%d FAILED" % _failed)
	quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failed += 1
		printerr("FAIL: ", what)
