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
