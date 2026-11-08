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
		"history":
			var data := OS.get_environment("AGMGD_HOME")
			var repo := data.path_join("demo-repo")
			OS.execute("bash", ["-c", "mkdir -p %s && cd %s && git init -q -b main && git -c user.name=demo -c user.email=d@d commit -q --allow-empty -m start" % [repo, repo]])
			var trusted := OS.get_environment("DRIVE_TRUSTED")
			var a: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Brain themes", "tool": "claude", "cwd": trusted, "group": "Second Brain"})
			var b: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Fix login", "tool": "shell", "cwd": repo, "worktree": true, "group": "Demo"})
			var n: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Old notes", "tool": "claude", "cwd": trusted})
			report.append("worktree session cwd: %s" % b.get("cwd", b.get("error", "")))
			await wait(4.0)
			await main.refresh()
			await main._archive(str(n["id"]))
			await main.engine.call_api("POST", "/sessions/%s/send" % b["id"], {"text": "echo fix > login.txt && git add login.txt && git -c user.name=demo -c user.email=d@d commit -q -m 'Fix the login' && git log --oneline"})
			await wait(1.5)
			main.set_view("history")
			await wait(2.0)
			await shot("15-history")
			main.history_search.text = "notes"
			await main._load_history()
			await wait(0.8)
			await shot("16-history-search")
			main.select(str(b["id"]))
			await wait(1.0)
			await main._open_finish(str(b["id"]))
			await wait(0.6)
			await shot("17-finish-branch")
			main.finish_dialog.hide()
			main.finish_dialog.confirmed.emit()
			await wait(2.0)
			var out := []
			OS.execute("git", ["-C", repo, "log", "--oneline"], out)
			report.append("main after finishing: %s" % "".join(out).strip_edges().replace("\n", " | "))
			report.append("worktree folder gone: %s" % (not DirAccess.dir_exists_absolute(str(b["cwd"]))))
			await shot("18-after-finish")
		"brain":
			# the real Second Brain (on Windows): a Claude Code session gets its own key and connects to it
			var trusted := OS.get_environment("DRIVE_TRUSTED")
			report.append("brain status: %s" % main.status_label.text)
			main.f_name.text = "Brain themes"
			main._open_new()
			main.f_name.text = "Brain themes"
			main.f_tool.select(0)
			main.f_cwd.text = trusted
			main.new_dialog.hide()
			await main._create()
			var sh: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Build", "tool": "shell", "cwd": trusted})
			await wait(12.0)
			await main.refresh()
			var s0: Dictionary = main._session(main.selected)
			report.append("session shares the Brain: %s" % s0.get("brain", false))
			var ps := []
			OS.execute("bash", ["-c", "ps -eo args | grep -c [r]elay.py.--client"], ps)
			report.append("Brain relays started by Claude Code: %s" % "".join(ps).strip_edges())
			await shot("19-brain-session")
			main._open_new()
			await wait(0.5)
			await shot("20-new-session-dialog")
			main.new_dialog.hide()
			for x in main.sessions.duplicate():  # removing revokes the test sessions' Brain keys (never the owner's)
				await main.engine.call_api("DELETE", "/sessions/%s" % x["id"])
			report.append("test sessions removed, their Brain keys revoked")
		"agents":
			var home := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
			var lead: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Lead agent", "tool": "shell", "cwd": home, "group": "Agent Manager"})
			# what an agent's start_session does through Agent Manager's MCP server
			var h1: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Helper · tests", "tool": "shell", "cwd": home, "group": "Agent Manager", "parent": lead["id"]})
			var h2: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Helper · docs", "tool": "shell", "cwd": home, "group": "Agent Manager", "parent": lead["id"]})
			await main.engine.call_api("POST", "/sessions/%s/send" % h1["id"], {"text": "python3 -m unittest discover -s tests/python -t . 2>&1 | tail -3"})
			await wait(1.0)
			await main.refresh()
			main.grid_ids = [str(lead["id"]), str(h1["id"]), str(h2["id"])]
			main.selected = str(lead["id"])
			main.set_view("grid")
			await wait(20.0)
			await main.refresh()
			await shot("21-agents-children")
			report.append("children: %s" % ", ".join(main.sessions.filter(func(x): return str(x.get("parent", "")) != "").map(func(x): return "%s<-%s" % [x["name"], x["parent_name"]])))
		"summary":
			# a REAL Claude Code writes its own summary (one small prompt, owner-approved); no Brain proposal in this test
			var trusted := OS.get_environment("DRIVE_TRUSTED")
			var c: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Summary demo", "tool": "claude", "cwd": trusted, "brain": false, "group": "Ticket System"})
			var cid := str(c["id"])
			var w0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - w0 < 40000:
				await wait(1.0)
				await main.refresh()
				if str(main._session(cid).get("conversation", "")) != "":
					break
			main.select(cid)
			await wait(1.0)
			await main._wrap_up(cid)
			await wait(4.0)
			await main.refresh()
			await shot("22-wrapping")
			var approved := 0
			w0 = Time.get_ticks_msec()
			while Time.get_ticks_msec() - w0 < 240000:
				await wait(2.0)
				await main.refresh()
				var s0: Dictionary = main._session(cid)
				if s0.is_empty():
					break  # archived: gone from the sidebar
				if str(s0.get("activity", "")) == "approval" and approved < 3:
					approved += 1
					await main.engine.call_api("POST", "/sessions/%s/keys" % cid, {"keys": ["Enter"]})
			var sums: Dictionary = await main.engine.call_api("GET", "/sessions/%s/summaries" % cid)
			report.append("approvals pressed by the test: %d" % approved)
			report.append("summary kept: %s" % (not (sums.get("summaries", []) as Array).is_empty()))
			if not (sums.get("summaries", []) as Array).is_empty():
				report.append("summary starts: %s" % str(sums["summaries"][0]["text"]).left(160).replace("\n", " | "))
			main.set_view("history")
			await wait(2.5)
			await shot("23-history-summary")
			if not (sums.get("summaries", []) as Array).is_empty():
				main._read("Summary demo", str(sums["summaries"][0]["text"]))
				await wait(0.8)
				await shot("24-read-summary")
				main.read_dialog.hide()
			main._open_new()
			main.f_cwd.text = trusted
			main.f_tool.select(0)
			await main._check_brief()
			await wait(0.6)
			report.append("brief offered: %s" % (not main.f_brief.disabled))
			await shot("25-new-session-brief")
			main.new_dialog.hide()
		"review":
			var data := OS.get_environment("AGMGD_HOME")
			var repo := data.path_join("shop")
			OS.execute("bash", ["-c", "mkdir -p %s && cd %s && git init -q -b main && printf 'def total(items):\\n    s = 0\\n    for i in items:\\n        s = s + i.price\\n    return s\\n' > cart.py && printf '# Shop\\n' > README.md && git add . && git -c user.name=d -c user.email=d@d commit -q -m start" % [repo, repo]])
			var a: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Cart refactor", "tool": "shell", "cwd": repo, "group": "Shop"})
			OS.execute("bash", ["-c", "cd %s && printf 'def total(items, tax=0.15):\\n    \\\"\\\"\\\"Sum of prices, with tax.\\\"\\\"\\\"\\n    s = sum(i.price for i in items)\\n    return round(s * (1 + tax), 2)\\n' > cart.py && printf '# Shop\\n\\nRun: python3 -m shop\\n' > README.md && printf 'def test_total():\\n    assert True\\n' > test_cart.py" % repo])
			await main.refresh()
			main.select(str(a["id"]))
			await wait(1.0)
			main.set_view("review")
			await wait(1.5)
			var sid := str(a["id"])
			await main.engine.call_api("POST", "/sessions/%s/comments" % sid, {"path": "cart.py", "line": 1, "code": "def total(items, tax=0.15):", "text": "Tax should come from the settings, not a default"})
			await main.engine.call_api("POST", "/sessions/%s/comments" % sid, {"path": "cart.py", "line": 4, "code": "    return round(s * (1 + tax), 2)", "text": "Use Decimal for money"})
			await main.engine.call_api("POST", "/sessions/%s/comments" % sid, {"path": "test_cart.py", "line": 2, "code": "    assert True", "text": "This test checks nothing"})
			await main._load_review()
			main.review_file = 1
			main.review_files.select(1)
			main._render_review_file()
			await wait(1.0)
			await shot("26-review")
			await main._send_review()
			await wait(1.5)
			await shot("27-review-sent")
			main.set_view("focus")
			await wait(1.5)
			await shot("28-review-in-terminal")
			report.append("review sent: %s" % main.terms[sid].get_screen_text().contains("Use Decimal for money"))
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
