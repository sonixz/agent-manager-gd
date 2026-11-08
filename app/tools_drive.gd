extends SceneTree
## Drives the real app on a virtual display (tools/app_shots.sh). DRIVE_STEP = create | reopen.
## Uses its own engine port, data folder and tmux socket (environment), never the owner's.

var out := OS.get_environment("DRIVE_OUT")
var report: Array[String] = []
var main: Control


func _initialize() -> void:
	_run.call_deferred()


func shot(name: String) -> void:
	if OS.get_environment("DRIVE_NO_SHOTS") != "":
		return
	for i in 3:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))
	report.append("capture " + name)


func wait(s: float) -> void:
	await create_timer(s).timeout


func _id(name: String) -> String:
	for x in main.sessions:
		if str(x["name"]) == name:
			return str(x["id"])
	return ""


func _row(name: String) -> Control:
	for c in main.list_box.get_children():
		if c is SessionCard and str(c.data.get("name", "")) == name:
			return c
	return null


func _header(label: String) -> Control:
	for c in main.list_box.get_children():
		if c is Button and c.text.contains(label):
			return c
	return null


func _drag(from: Vector2, to: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	press.global_position = from
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(press)
	await process_frame
	for i in range(1, 21):
		var m := InputEventMouseMotion.new()
		m.position = from.lerp(to, i / 20.0)
		m.global_position = m.position
		m.relative = (to - from) / 20.0
		m.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(m)
		await process_frame
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = to
	rel.global_position = to
	Input.parse_input_event(rel)
	await process_frame


func _tree_text() -> String:
	var parts: Array[String] = []
	for g in main.tree:
		parts.append("%s%s[%s]" % [g["name"] if g["name"] != "" else "(none)", " (folded)" if g["folded"] else "",
			", ".join((g["sessions"] as Array).map(func(x): return str(x["name"])))])
	return " ".join(parts)


## Demo sessions: four real Claude Code (started, no prompt), a busy shell, a quiet one; states injected.
func _demo() -> Dictionary:
	var trusted := OS.get_environment("DRIVE_TRUSTED")
	var home := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	await main.engine.call_api("POST", "/groups", {"name": "Second Brain"})
	await main.engine.call_api("POST", "/groups", {"name": "Agent Manager"})
	var made := {}
	for it in [["Themes", "claude", "Second Brain"], ["MCP fixes", "claude", "Second Brain"], ["Docs", "claude", "Second Brain"],
			["Terminal", "claude", "Agent Manager"], ["Build", "shell", "Agent Manager"], ["Scratch", "shell", ""]]:
		var r: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": it[0], "tool": it[1], "cwd": trusted if it[1] == "claude" else home, "group": it[2]})
		made[it[0]] = str(r.get("id", ""))
	var c0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - c0 < 40000:
		await wait(1.0)
		await main.refresh()
		var started: int = main.sessions.filter(func(x): return x["tool"] == "claude" and str(x["conversation"]) != "").size()
		if started == 4:
			break
	var hook := ProjectSettings.globalize_path("res://").path_join("../engine/hook.py").simplify_path()
	var data := OS.get_environment("AGMGD_HOME")
	for ev in [["Themes", {"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"}],
			["MCP fixes", {"hook_event_name": "UserPromptSubmit", "prompt": "x"}],
			["Docs", {"hook_event_name": "Stop"}],
			["Terminal", {"hook_event_name": "Notification", "message": "Claude is waiting for your input"}]]:
		var pf := FileAccess.open(data.path_join("payload.json"), FileAccess.WRITE)
		pf.store_string(JSON.stringify(ev[1]))
		pf.close()
		OS.execute("bash", ["-c", "AGMGD_SESSION=%s AGMGD_HOME=%s python3 %s claude < %s" % [made[ev[0]], data, hook, data.path_join("payload.json")]])
	await main.engine.call_api("POST", "/sessions/%s/send" % made["Build"], {"text": "clear; git log --oneline --color=always | head -12; python3 prototype/terminal-ghostty/tools/colors.py; sleep 120"})
	await main.engine.call_api("POST", "/sessions/%s/send" % made["Scratch"], {"text": "echo 'déjà « vu » — ✓ 😀'"})
	await wait(1.5)
	await main.refresh()
	return made


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1440, 900)  # a headless window is 64x64: terminals would shrink to one line
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	var t0 := Time.get_ticks_msec()
	while (main.engine == null or not main.engine.connected) and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
	report.append("engine connected: %s" % (main.engine != null and main.engine.connected))
	await wait(1.0)
	match OS.get_environment("DRIVE_STEP"):
		"tree":
			var home := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
			for g in ["Second Brain", "Ticket System", "Agent Manager"]:
				await main.engine.call_api("POST", "/groups", {"name": g})
			var plan := [["Themes", "Second Brain"], ["MCP fixes", "Second Brain"], ["Docs", "Second Brain"],
				["Playtest 5", "Ticket System"], ["Open world", "Ticket System"], ["Terminal", "Agent Manager"],
				["Engine", "Agent Manager"], ["Tree", "Agent Manager"], ["Scratch", ""], ["Notes", ""]]
			for it in plan:
				await main.engine.call_api("POST", "/sessions", {"name": it[0], "tool": "shell", "cwd": home, "group": it[1]})
			await main.refresh()
			await wait(0.5)
			# a real mouse drag: "Docs" onto the "Agent Manager" header
			var src := _row("Docs")
			var dst := _header("AGENT MANAGER")
			report.append("rows found: %s %s" % [src != null, dst != null])
			if src and dst:
				await _drag(src.get_global_rect().get_center(), dst.get_global_rect().get_center())
			await wait(0.8)
			await main._move(_id("Notes"), "Second Brain", 0)     # menu path: Notes to the top of Second Brain
			await main.engine.call_api("POST", "/groups/Ticket%20System/fold", {"folded": true})
			await main.refresh()
			await wait(0.5)
			var eng := _row("Engine")
			if eng:
				var at: Vector2 = eng.get_global_rect().get_center()
				for pressed in [true, false]:
					var ev := InputEventMouseButton.new()
					ev.button_index = MOUSE_BUTTON_LEFT
					ev.pressed = pressed
					ev.position = at
					ev.global_position = at
					Input.parse_input_event(ev)
					await process_frame
				await wait(1.0)
				report.append("a click on a card selects it: %s" % (main.selected == _id("Engine")))
			main.select(_id("Terminal"))
			await wait(1.0)
			await shot("05-tree")
			report.append("tree: " + _tree_text())
		"states":
			var trusted := OS.get_environment("DRIVE_TRUSTED")
			var home := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
			await main.engine.call_api("POST", "/groups", {"name": "Second Brain"})
			await main.engine.call_api("POST", "/groups", {"name": "Agent Manager"})
			var made := {}
			for it in [["Themes", "claude", "Second Brain"], ["MCP fixes", "claude", "Second Brain"], ["Docs", "claude", "Second Brain"],
					["Terminal", "claude", "Agent Manager"], ["Build", "shell", "Agent Manager"], ["Scratch", "shell", ""]]:
				var r: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": it[0], "tool": it[1], "cwd": trusted if it[1] == "claude" else home, "group": it[2]})
				made[it[0]] = str(r.get("id", ""))
			var c0 := Time.get_ticks_msec()  # Claude Code starts; its SessionStart hook says « ready »
			while Time.get_ticks_msec() - c0 < 40000:
				await wait(1.0)
				await main.refresh()
				var started: int = main.sessions.filter(func(x): return x["tool"] == "claude" and str(x["conversation"]) != "").size()
				if started == 4:
					break
			report.append("claude sessions started (hook seen): %d" % main.sessions.filter(func(x): return x["tool"] == "claude" and str(x["conversation"]) != "").size())
			var hook := ProjectSettings.globalize_path("res://").path_join("../engine/hook.py").simplify_path()
			var data := OS.get_environment("AGMGD_HOME")
			for ev in [["Themes", {"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"}],
					["MCP fixes", {"hook_event_name": "UserPromptSubmit", "prompt": "x"}],
					["Docs", {"hook_event_name": "Stop"}],
					["Terminal", {"hook_event_name": "Notification", "message": "Claude is waiting for your input"}]]:
				var outp := []
				var payload_file := data.path_join("payload.json")
				var pf := FileAccess.open(payload_file, FileAccess.WRITE)
				pf.store_string(JSON.stringify(ev[1]))
				pf.close()
				# no quotes in OS.execute arguments (Godot re-splits them): the payload goes through a file on stdin
				var code := OS.execute("bash", ["-c", "AGMGD_SESSION=%s AGMGD_HOME=%s python3 %s claude < %s" % [made[ev[0]], data, hook, payload_file]], outp, true)
				report.append("inject %s -> %d %s %s" % [ev[0], code, "".join(outp).strip_edges(), FileAccess.get_file_as_string(data.path_join("state/%s.json" % made[ev[0]])).left(60)])
			await main.engine.call_api("POST", "/sessions/%s/send" % made["Build"], {"text": "sleep 60"})
			await wait(2.5)
			await main.refresh()
			main.select(made["Themes"])
			await wait(2.0)
			await main.refresh()
			await shot("07-states")
			report.append("states: " + ", ".join(main.sessions.map(func(x): return "%s=%s" % [x["name"], x["activity"]])))
			# 4C: a session turns to « waits for your OK » while the app runs -> toast; quick reply into a shell
			var pf2 := FileAccess.open(data.path_join("payload.json"), FileAccess.WRITE)
			pf2.store_string(JSON.stringify({"hook_event_name": "Notification", "message": "Claude needs your permission to use Edit"}))
			pf2.close()
			OS.execute("bash", ["-c", "AGMGD_SESSION=%s AGMGD_HOME=%s python3 %s claude < %s" % [made["Docs"], data, hook, data.path_join("payload.json")]])
			await main.refresh()
			report.append("toast after a new approval: %s [%s]" % [main.toast.visible, main.toast_label.text])
			report.append("queue cards: %d" % (main.queue_box.get_child_count() - 1))
			main.select(made["Scratch"])
			await wait(1.0)
			main._quick_reply(made["Scratch"])
			main.ask_edit.text = "echo quick-reply-ok"
			main.ask_dialog.hide()
			main.ask_dialog.confirmed.emit()
			await wait(1.5)
			report.append("quick reply reached the shell: %s" % main.terms[made["Scratch"]].get_screen_text().contains("quick-reply-ok\n"))
			main.select(made["Themes"])
			await wait(1.0)
			await shot("08-waiting-queue")
		"design":
			var made := await _demo()
			main.select(made["Themes"])
			await wait(2.5)
			await main.refresh()
			await shot("10-focus-%s" % AmTheme.current)
			main.grid_ids = [made["Themes"], made["Build"], made["Docs"], made["Terminal"]]
			main.set_view("grid")
			await wait(3.0)
			await shot("11-grid")
			main.set_view("board")
			await wait(3.0)
			await main.refresh()
			await wait(1.0)
			await shot("12-board")
			main.set_view("focus")
			main.open_palette()
			main.palette.edit.text = "th"
			main.palette._filter("th")
			await wait(0.6)
			await shot("13-palette")
			main.palette.hide()
			for t in ["terminal", "neon", "paper"]:
				await main.set_theme_name(t)
				await wait(1.2)
				await shot("14-theme-%s" % t)
			await main.set_theme_name("focus")
			report.append("design: views and themes captured; sessions=%d" % main.sessions.size())
		"tree-reopen":
			await wait(1.5)
			report.append("tree after reopening: " + _tree_text())
			await shot("06-tree-reopened")
		"create":
			main.f_name.text = "Brain themes"
			main.f_tool.select(0)
			main.f_cwd.text = OS.get_environment("DRIVE_TRUSTED")
			await main._create()
			main.f_name.text = "Build and tests"
			main.f_tool.select(2)
			main.f_cwd.text = ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
			await main._create()
			await wait(1.5)
			await main.engine.call_api("POST", "/sessions/%s/send" % main.selected, {"text": "clear; git log --oneline | head -5; python3 prototype/terminal-ghostty/tools/colors.py; echo 'déjà « vu » — ✓ 😀'"})
			main.f_name.text = "Scratch"
			main.f_tool.select(2)
			main.f_cwd.text = "~"
			await main._create()
			await wait(1.0)
			main.select(str(main.sessions[1]["id"]))
			await wait(1.5)
			await shot("01-shell-session")
			main.select(str(main.sessions[0]["id"]))
			await wait(10.0)
			await shot("02-claude-session")
			var shell_text: String = main.terms[str(main.sessions[1]["id"])].get_screen_text()
			report.append("shell screen shows the accents: %s" % shell_text.contains("déjà « vu » — ✓"))
			if not shell_text.contains("déjà « vu » — ✓"):
				var tt: Control = main.terms[str(main.sessions[1]["id"])]
				report.append("screen was: [%s] running=%s cols=%d rows=%d size=%s parent=%s view=%s root=%s" % [shell_text.strip_edges().right(300).replace("\n", " | "), tt.is_running(), tt.get_cols(), tt.get_rows(), tt.size, tt.get_parent().name, main.view, root.size])
			report.append("sessions: %s" % ", ".join(main.sessions.map(func(s): return "%s=%s" % [s["name"], s["state"]])))
		"reopen":
			await wait(2.0)
			report.append("after reopening: %s" % ", ".join(main.sessions.map(func(s): return "%s=%s" % [s["name"], s["state"]])))
			main.select(str(main.sessions[1]["id"]))
			await wait(1.5)
			var again: String = main.terms[str(main.sessions[1]["id"])].get_screen_text()
			report.append("reattached screen still shows the accents: %s" % again.contains("déjà « vu » — ✓"))
			await shot("03-reopened-shell")
			main.select(str(main.sessions[0]["id"]))
			await wait(2.0)
			await shot("04-reopened-claude")
	main.engine.stop_engine()
	print("\n".join(report))
	var f := FileAccess.open(out.path_join("report-%s.txt" % OS.get_environment("DRIVE_STEP")), FileAccess.WRITE)
	f.store_string("\n".join(report) + "\n")
	f.close()
	quit()
