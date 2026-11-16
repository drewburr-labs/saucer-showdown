extends RefCounted
## Fails a test run that goes on too long instead of letting it hang: after
## `seconds` it prints what the test was doing and kills the process. It
## watches from its own thread, so it fires even if the test is stuck in a
## loop. Call stop() before quitting.
##   var _watchdog := Watchdog.new(60, func() -> String: return _current)

var _thread := Thread.new()
var _stopped := false


func _init(seconds: float, doing: Callable) -> void:
	_thread.start(_watch.bind(seconds, doing))


func stop() -> void:
	_stopped = true
	_thread.wait_to_finish()


func _watch(seconds: float, doing: Callable) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		if _stopped:
			return
		OS.delay_msec(50)
	printerr("\nTIMED OUT: still running after %d s, in \"%s\"" % [seconds, doing.call()])
	OS.kill(OS.get_process_id())
