class_name EngineClient
extends Node
## Talks to the Python engine (127.0.0.1, bearer token) and starts it when it is not running.
## The engine runs where tmux is: Linux directly, or WSL from Windows (wsl.exe).

signal ready_changed(ok: bool)

var port := 8790
var token := ""
var connected := false
var engine_pid := -1
var on_windows := OS.get_name() == "Windows"


func _init() -> void:
	port = int(OS.get_environment("AGMGD_PORT")) if OS.get_environment("AGMGD_PORT") != "" else 8790


## The repository root as the engine sees it (a WSL path on Windows).
func engine_root() -> String:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	if on_windows and root.length() > 1 and root[1] == ":":
		root = "/mnt/" + root[0].to_lower() + root.substr(2).replace("\\", "/")
	return root


## Runs a command where tmux lives (prefixes wsl.exe on Windows).
func host_command(argv: Array) -> Array:
	return (["wsl.exe", "-e"] + argv) if on_windows else argv


func connect_engine() -> bool:
	if not await _health():
		# A login shell (bash -l): the user's PATH, so their claude and codex are found. AGMGD_HOME and
		# AGMGD_TMUX_SOCKET (tests, a second profile) are passed on explicitly: they do not cross into WSL.
		# No quotes in these arguments: Godot's OS.execute/create_process re-split arguments that contain them.
		var env_prefix := ""
		for k in ["AGMGD_HOME", "AGMGD_TMUX_SOCKET"]:
			if OS.get_environment(k) != "":
				env_prefix += "%s=%s " % [k, OS.get_environment(k).replace(" ", "\\ ")]
		var root := engine_root()
		var cmd: Array
		if on_windows:
			cmd = ["wsl.exe", "--cd", root, "-e", "bash", "-lc", "exec env %spython3 -m engine --port %d" % [env_prefix, port]]
		else:
			cmd = ["bash", "-lc", "cd %s && exec env %spython3 -m engine --port %d" % [root.replace(" ", "\\ "), env_prefix, port]]
		engine_pid = OS.create_process(cmd[0], cmd.slice(1))
		for i in 50:
			await get_tree().create_timer(0.2).timeout
			if await _health():
				break
	connected = await _health() and _load_token()
	ready_changed.emit(connected)
	return connected


func _load_token() -> bool:
	var rel := "runtime/api_token"
	var home := OS.get_environment("AGMGD_HOME")
	if on_windows:
		var out := []
		var path := (home if home != "" else "$HOME/.local/share/agent-manager-gd") + "/" + rel
		OS.execute("wsl.exe", ["-e", "bash", "-c", "cat " + path.replace(" ", "\\ ")], out)
		token = "".join(out).strip_edges()
	else:
		if home == "":
			home = OS.get_environment("HOME").path_join(".local/share/agent-manager-gd")
		token = FileAccess.get_file_as_string(home.path_join(rel)).strip_edges()
	return token != ""


func stop_engine() -> void:
	if engine_pid > 0:
		OS.kill(engine_pid)
		engine_pid = -1


func _health() -> bool:
	var r := await call_api("GET", "/health", null, false)
	return r.get("ok", false) == true


## Returns the JSON reply, or {"error": …}.
func call_api(method: String, path: String, body: Variant = null, auth := true) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if auth:
		headers.append("Authorization: Bearer " + token)
	var m: int = {"GET": HTTPClient.METHOD_GET, "POST": HTTPClient.METHOD_POST, "DELETE": HTTPClient.METHOD_DELETE}[method]
	var err := http.request("http://127.0.0.1:%d%s" % [port, path], headers, m, JSON.stringify(body) if body != null else "")
	if err != OK:
		http.queue_free()
		return {"error": "request failed"}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS:
		return {"error": "engine unreachable"}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if data is Dictionary:
		if int(res[1]) >= 400 and not data.has("error"):
			data["error"] = "HTTP %d" % res[1]
		return data
	return {"error": "bad reply"}
