extends RefCounted
## One call to the engine, in a thread of its own that sleeps while it waits (2026-11-13).
##
## Godot's HTTPRequest in thread mode loops with a one-microsecond pause while it waits for an answer: every call in
## flight kept a whole core busy. The app asks the engine several things every 2 seconds, some slow (git, WSL), so
## two or three were always in flight: about two cores on Windows (owner: « le CPU dans Windows semble être élevé »).
## Here the thread checks quickly for the first moments (a local engine answers in a few milliseconds), then sleeps
## a millisecond between two looks. Without a thread (Loop 33), a call moved one step per drawn frame.

signal finished(result: Dictionary)

var thread := Thread.new()


## {"code": int, "body": PackedByteArray} or {"error": String}
func run(port: int, method: int, path: String, headers: PackedStringArray, body: String, timeout: float) -> Dictionary:
	thread.start(_work.bind(port, method, path, headers, body, timeout))
	var r: Dictionary = await finished
	thread.wait_to_finish()
	return r


static func _rest(spins: int) -> void:
	if spins < 40:
		OS.delay_usec(100)  # the first 4 ms: a local answer comes this fast
	else:
		OS.delay_msec(1)


func _work(port: int, method: int, path: String, headers: PackedStringArray, body: String, timeout: float) -> void:
	_done.call_deferred(_exchange(port, method, path, headers, body, timeout))


func _done(r: Dictionary) -> void:
	finished.emit(r)


static func _exchange(port: int, method: int, path: String, headers: PackedStringArray, body: String, timeout: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	var c := HTTPClient.new()
	if c.connect_to_host("127.0.0.1", port) != OK:
		return {"error": "engine unreachable"}
	var spins := 0
	while c.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		c.poll()
		if Time.get_ticks_msec() > deadline:
			return {"error": "engine unreachable"}
		_rest(spins)
		spins += 1
	if c.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"error": "engine unreachable"}
	if c.request(method, path, headers, body) != OK:
		return {"error": "request failed"}
	spins = 0
	while c.get_status() == HTTPClient.STATUS_REQUESTING:
		c.poll()
		if Time.get_ticks_msec() > deadline:
			return {"error": "engine unreachable"}
		_rest(spins)
		spins += 1
	if not c.has_response():
		return {"error": "engine unreachable"}
	var code := c.get_response_code()
	var out := PackedByteArray()
	spins = 0
	while c.get_status() == HTTPClient.STATUS_BODY:
		c.poll()
		var chunk := c.read_response_body_chunk()
		if chunk.size() > 0:
			out.append_array(chunk)
			spins = 0
			continue
		if Time.get_ticks_msec() > deadline:
			return {"error": "engine unreachable"}
		_rest(spins)
		spins += 1
	c.close()
	return {"code": code, "body": out}
