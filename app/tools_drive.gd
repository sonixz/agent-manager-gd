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
		if c is Button and c.text.contains(name + "\n"):
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


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
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
			main.select(_id("Terminal"))
			await wait(1.0)
			await shot("05-tree")
			report.append("tree: " + _tree_text())
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
