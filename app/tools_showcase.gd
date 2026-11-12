extends SceneTree
## The website screenshots (tools/showcase.sh): the real app on a private virtual display, with a fictional workspace
## (user « dev », projects in ~/code). Agent terminals replay recorded real screens (tools/showcase/bin/agent-replay).
## SHOW_STEP = measure | hero | … ; screenshots go to SHOW_OUT as webp.

var out := OS.get_environment("SHOW_OUT")
var report: Array[String] = []
var main: Control
var code := OS.get_environment("HOME").path_join("code")


func _initialize() -> void:
	_run.call_deferred()


func shot(name: String) -> void:
	for i in 3:
		await process_frame
	root.get_texture().get_image().save_webp(out.path_join(name + ".webp"), true, 0.86)
	report.append("capture " + name)


## A How-to step: the window at 1280×800, to public/assets/howto/<guide>/NN.webp.
func hshot(gid: String, n: int) -> void:
	for i in 3:
		await process_frame
	var dir := OS.get_environment("SHOW_HOWTO").path_join(gid)
	DirAccess.make_dir_recursive_absolute(dir)
	var img := root.get_texture().get_image()
	img.resize(1280, 800, Image.INTERPOLATE_LANCZOS)
	img.save_webp(dir.path_join("%02d.webp" % n), true, 0.88)
	report.append("howto %s %02d" % [gid, n])


func _sid(name: String) -> String:
	for x in main.sessions:
		if str(x["name"]) == name:
			return str(x["id"])
	return ""


## The gift card change in acme-store, for the Review view.
func _review_files() -> void:
	var repo := code.path_join("acme-store")
	_write(repo.path_join("src/checkout/giftcard.ts"), "export interface GiftCard { code: string; balance: number }\n\nexport function redeemGiftCard(total: number, card: GiftCard) {\n  const applied = Math.min(total, card.balance);\n  return { applied, remaining: total - applied, card: { ...card, balance: card.balance - applied } };\n}\n")
	_write(repo.path_join("tests/giftcard.test.ts"), "import { redeemGiftCard } from \"../src/checkout/giftcard\";\n\ntest(\"takes no more than the balance\", () => {\n  const r = redeemGiftCard(80, { code: \"GIFT-1234\", balance: 50 });\n  expect(r.applied).toBe(50);\n  expect(r.remaining).toBe(30);\n});\n")
	_write(repo.path_join("README.md"), "# Acme Store\nA small storefront: catalogue, cart and checkout.\n\nGift cards are redeemed at checkout, never for more than their balance.\n")


func _review_pick(part: String) -> void:
	for i in main.review_files.item_count:
		var t: String = main.review_files.get_item_text(i)
		if t.contains(part) and not (part == "giftcard.ts" and t.contains("test")):
			main.review_file = i
			main.review_files.select(i)
	main._render_review_file()


func wait(s: float) -> void:
	await create_timer(s).timeout


## Hook events give each agent its live state, as Claude Code itself would report it.
func _state(sid: String, tool: String, ev: Dictionary) -> void:
	var data := OS.get_environment("AGMGD_HOME")
	var hook := ProjectSettings.globalize_path("res://").path_join("../engine/hook.py").simplify_path()
	var pf := FileAccess.open(data.path_join("payload.json"), FileAccess.WRITE)
	pf.store_string(JSON.stringify(ev))
	pf.close()
	OS.execute("bash", ["-c", "AGMGD_SESSION=%s AGMGD_HOME=%s python3 %s %s < %s" % [sid, data, hook, tool, data.path_join("payload.json")]])


const WORKING := {"hook_event_name": "UserPromptSubmit", "prompt": "x"}
const DONE := {"hook_event_name": "Stop"}
const NEEDS_OK := {"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"}
const CODEX_DONE := {"type": "agent-turn-complete", "last-assistant-message": "Updated README.md: cart, Quebec sales tax, shipping zones, free shipping from $75."}
const NEEDS_ANSWER := {"hook_event_name": "Notification", "message": "Claude is waiting for your input"}


## The fictional workspace: groups, sessions (name, tool, project, scene, state), shell sessions running real commands.
func _workspace() -> Dictionary:
	for g in ["Acme Store", "Orbit API", "Pixel Forge"]:
		await main.engine.call_api("POST", "/groups", {"name": g})
	var plan := [
		["Checkout flow", "claude", "acme-store", "Acme Store", "checkout-working", WORKING],
		["Flaky tests", "claude", "acme-store", "Acme Store", "flaky-ok", NEEDS_OK],
		["Docs refresh", "codex", "acme-store", "Acme Store", "docs-done", CODEX_DONE],
		["Rate limiter", "claude", "orbit-api", "Orbit API", "limiter-question", NEEDS_ANSWER],
		["Test runner", "shell", "orbit-api", "Orbit API", "", {}],
		["Sparks", "claude", "pixel-forge", "Pixel Forge", "sparks-done", DONE],
	]
	var made := {}
	var map := OS.get_environment("SHOWCASE_MAP")
	for p in plan:
		var r: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": p[0], "tool": p[1], "cwd": code.path_join(p[2]), "group": p[3], "brain": p[1] != "shell", "document": p[0] in ["Checkout flow", "Sparks"]})
		var sid := str(r.get("id", ""))
		made[p[0]] = sid
		if p[4] != "":
			var f := FileAccess.open(map.path_join(sid), FileAccess.WRITE)
			f.store_string(p[4])
			f.close()
	await wait(2.0)
	for p in plan:
		if p[5]:
			_state(made[p[0]], p[1], p[5])
	await main.engine.call_api("POST", "/sessions/%s/send" % made["Test runner"], {"text": "clear; git log --oneline --decorate --color=always | head -5; python3 -m unittest -v 2>&1"})
	await wait(1.5)
	await main.refresh()
	return made


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _map(sid: String, scene: String) -> void:
	var f := FileAccess.open(OS.get_environment("SHOWCASE_MAP").path_join(sid), FileAccess.WRITE)
	f.store_string(scene)
	f.close()


func _sizes() -> String:
	var o := []
	OS.execute("tmux", ["-L", OS.get_environment("AGMGD_TMUX_SOCKET"), "list-windows", "-a", "-F", "#{session_name} #{window_width}x#{window_height}"], o)
	return "".join(o).strip_edges().replace("\n", " | ")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	var t0 := Time.get_ticks_msec()
	while (main.engine == null or not main.engine.connected) and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
	report.append("engine connected: %s" % (main.engine != null and main.engine.connected))
	await wait(1.0)
	var made := await _workspace()
	match OS.get_environment("SHOW_STEP"):
		"measure":
			main.select(made["Checkout flow"])
			await wait(3.0)
			report.append("focus: " + _sizes())
			await shot("measure-focus")
			main.grid_ids = [made["Checkout flow"], made["Flaky tests"], made["Rate limiter"], made["Test runner"]]
			main.set_view("grid")
			await wait(3.0)
			report.append("grid: " + _sizes())
			await shot("measure-grid")
		"hero":
			main.grid_ids = [made["Checkout flow"], made["Flaky tests"], made["Rate limiter"], made["Test runner"]]
			main.selected = made["Checkout flow"]
			main.set_view("grid")
			await wait(4.0)
			await main.refresh()
			await shot("hero-grid")
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await wait(3.0)
			await shot("focus-working")
			main.set_view("board")
			await wait(4.0)
			await main.refresh()
			await wait(1.0)
			await shot("board")
		"orchestrator":  # Loop 25: the panel on the right, its question to the owner, its sessions
			var map := OS.get_environment("SHOWCASE_MAP")
			var o: Dictionary = await main.engine.call_api("POST", "/orchestrator/start", {"cwd": code})
			var oid := str(o.get("id", ""))
			var f0 := FileAccess.open(map.path_join(oid), FileAccess.WRITE)
			f0.store_string("idle-claude")
			f0 = null
			var kid_ids := []
			for p in [["Gift cards", "acme-store", "Acme Store", "checkout-working", "opus"], ["Flaky cart test", "acme-store", "Acme Store", "flaky-ok", "sonnet"]]:
				var c: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": p[0], "tool": "claude", "cwd": code.path_join(p[1]), "group": p[2], "parent": oid, "model": p[4], "brain": true})
				kid_ids.append(str(c.get("id", "")))
				var f1 := FileAccess.open(map.path_join(str(c.get("id", ""))), FileAccess.WRITE)
				f1.store_string(p[3])
			await main.engine.call_api("POST", "/orchestrator/plan", {"goal": "Gift cards and a steady test suite", "tasks": [
				{"title": "Gift cards at checkout", "repo": "acme-store", "tool": "claude", "model": "opus", "why": "touches the money path: the owner's rule « hard bugs » → Opus"},
				{"title": "Fix the flaky cart test", "repo": "acme-store", "tool": "claude", "model": "sonnet", "why": "everyday fix → Sonnet"},
				{"title": "Second opinion on the gift card diff", "repo": "acme-store", "tool": "codex", "why": "the owner's rule « code review » → Codex"}]})
			await main.engine.call_api("POST", "/orchestrator/tasks/t1/update", {"status": "running", "session": kid_ids[0]})
			await main.engine.call_api("POST", "/orchestrator/tasks/t2/update", {"status": "running", "session": kid_ids[1]})
			await main.engine.call_api("POST", "/orchestrator/budget", {"daily_tokens": 5000000})
			await main.engine.call_api("POST", "/sessions/%s/ask" % oid, {"question": "Plan for today: 1) gift cards at checkout (Claude Code, Opus, worktree), 2) the flaky cart test (Claude Code, Sonnet). Start both?", "options": ["Yes", "Only 1", "No"]})
			await main.refresh()
			main.set_view("focus")
			main.select(made["Checkout flow"])
			main.toggle_orchestrator()
			await wait(3.0)
			await main.refresh()
			await wait(1.0)
			await shot("orchestrator-panel")
			var sizes := []  # the panel's terminal must keep its size across refreshes (it used to jump every 2 s)
			for i in 6:
				await main.refresh()
				await main.refresh_orchestrator()
				await wait(0.05)
				sizes.append(main.terms[oid].size if main.terms.has(oid) else Vector2.ZERO)
			print("orchestrator terminal sizes: ", sizes)
			main._set_orch_tab("plan")
			await wait(0.5)
			await shot("orchestrator-plan")
			main._set_orch_tab("terminal")
			main._toggle_orch_min()
			await wait(0.6)
			await shot("orchestrator-min")
			main._toggle_orch_min()
			await wait(0.4)
			var was := AmTheme.current
			await main.set_theme_name("paper")   # its window follows the theme
			await wait(1.0)
			await shot("orchestrator-paper")
			await main.set_theme_name(was)
			await wait(0.5)
			await main._open_rules()
			await wait(0.6)
			await shot("routing-rules")
			main.rules_dialog.hide()
		"list":  # Loop 32: twenty sessions, one per line; then the same list as tiles
			var more := [
				["Cart totals", "claude", "acme-store", "Acme Store", WORKING, {}], ["Coupon codes", "claude", "acme-store", "Acme Store", DONE, {}],
				["Search index", "codex", "acme-store", "Acme Store", CODEX_DONE, {}], ["Image pipeline", "claude", "acme-store", "Acme Store", WORKING, {"level": "edits"}],
				["Auth tokens", "claude", "orbit-api", "Orbit API", NEEDS_ANSWER, {}], ["Pagination", "claude", "orbit-api", "Orbit API", DONE, {"access": "contained"}],
				["Webhooks", "codex", "orbit-api", "Orbit API", CODEX_DONE, {}], ["Load test", "shell", "orbit-api", "Orbit API", {}, {}],
				["Particles", "claude", "pixel-forge", "Pixel Forge", WORKING, {}], ["Shader cache", "claude", "pixel-forge", "Pixel Forge", NEEDS_OK, {"level": "ask"}],
				["Level editor", "claude", "pixel-forge", "Pixel Forge", DONE, {}], ["Save files", "codex", "pixel-forge", "Pixel Forge", CODEX_DONE, {}],
				["Gamepad input", "claude", "pixel-forge", "Pixel Forge", WORKING, {"level": "full", "access": "readonly"}], ["Build script", "shell", "pixel-forge", "Pixel Forge", {}, {}],
			]
			var ids := {}
			for p in more:
				var body := {"name": p[0], "tool": p[1], "cwd": code.path_join(p[2]), "group": p[3], "brain": p[1] != "shell"}
				body.merge(p[5])
				var r: Dictionary = await main.engine.call_api("POST", "/sessions", body)
				ids[p[0]] = str(r.get("id", ""))
			await wait(2.5)
			for p in more:
				if p[4]:
					_state(ids[p[0]], p[1], p[4])
			await main.refresh()
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await wait(3.0)
			await main.refresh()
			main.set_list("line")
			await wait(0.8)
			report.append("list: %d sessions" % main.sessions.size())
			await shot("list-line")
			main.set_list("tile")
			await wait(0.8)
			await shot("list-tile")
			main.set_list("line")
		"voice-theme":  # a check: the voice panel (F8, F9) follows a theme change: neon first, then the green one
			main.select(made["Checkout flow"])
			await wait(2.5)
			await main.set_theme_name("neon")
			await wait(0.4)
			await main.set_theme_name("forest")
			await wait(0.6)
			_hold("command")
			main.voice_meter.value = 0.62
			await wait(0.6)
			var box: StyleBoxFlat = main.voice_overlay.get_theme_stylebox("panel")
			report.append("voice-theme: theme %s | the box's border is the theme's own: %s | its background too: %s" % [
				AmTheme.current, Color(box.border_color, 1.0).is_equal_approx(AmTheme.col("MINT")), Color(box.bg_color, 1.0).is_equal_approx(AmTheme.col("PANEL_2"))])
			await shot("voice-theme")
			main.dictation.recording = false
			main.voice_live.visible = false
			main.voice_overlay.visible = false
		"typing":  # a check: keys pressed on the keyboard reach the selected session's terminal, the way the window receives them
			main.select(made["Test runner"])
			await wait(2.5)
			await main.engine.call_api("POST", "/sessions/%s/send" % made["Test runner"], {"text": "clear"})
			await wait(0.8)
			var holder := root.gui_get_focus_owner()
			report.append("typing: the keyboard is on: %s" % (holder.get_class() if holder else "nothing"))
			for ch in "echo typed-by-keys":
				var ev := InputEventKey.new()
				ev.pressed = true
				ev.unicode = ch.unicode_at(0)
				ev.keycode = KEY_SPACE if ch == " " else (KEY_MINUS if ch == "-" else OS.find_keycode_from_string(ch.to_upper()))
				ev.physical_keycode = ev.keycode
				Input.parse_input_event(ev)
				await process_frame
				var up: InputEventKey = ev.duplicate()
				up.pressed = false
				Input.parse_input_event(up)
				await process_frame
			await wait(1.2)
			var typed: Dictionary = await main.engine.call_api("GET", "/sessions/%s/preview?lines=14" % made["Test runner"])
			report.append("typing: the terminal shows what was typed: %s" % str(typed.get("text", "")).contains("echo typed-by-keys"))
			await shot("typing")
		"voice-box":  # Loop 34: the dictation box, from the first word to Enter. Run with AGMGD_VOICE_FAKE="one | two | three | four" (a small delay shows it writing)
			main.select(made["Test runner"])
			await wait(2.5)
			await main.engine.call_api("POST", "/sessions/%s/send" % made["Test runner"], {"text": "clear"})
			main.select(made["Checkout flow"])
			await wait(2.0)
			_hold("dictate")
			await _say(2.5)
			await _say(3.0)
			await wait(1.5)
			await _say(1.8, 0.0)  # the third phrase is still being said
			report.append("voice-box, while speaking: %d pieces given, under the text: « %s »" % [main.dictation.pieces, main.voice_live.text])
			await shot("voice-box-listening")
			await _say(0.6)
			await main._voice_stop()
			await wait(2.5)
			var held: String = main.voice_text.text
			report.append("voice-box, key released: the box holds « %s » | it has the keyboard: %s | saved on disk: %s | sent to the agent: no" % [
				held, main.voice_text.has_focus(), FileAccess.get_file_as_string(main.DRAFT_FILE) == held])
			await shot("voice-box-ready")
			# the box is moved by its top line, stays where it was put, and a double click sends it back
			var home: Vector2 = main.voice_overlay.position
			var press := InputEventMouseButton.new()
			press.button_index = MOUSE_BUTTON_LEFT
			press.pressed = true
			main._box_drag(press)
			var drag := InputEventMouseMotion.new()
			drag.relative = Vector2(-700, -640)
			main._box_drag(drag)
			var release := InputEventMouseButton.new()
			release.button_index = MOUSE_BUTTON_LEFT
			main._box_drag(release)
			await wait(0.4)
			var put: Vector2 = main.voice_overlay.position
			main._box_show(true)
			report.append("voice-box, dragged by its top line: from %s to %s | it stays there when shown again: %s | its place is remembered: %s" % [
				home, put, main.voice_overlay.position == put, main.voice_place == put])
			await shot("voice-box-moved")
			var twice := InputEventMouseButton.new()
			twice.button_index = MOUSE_BUTTON_LEFT
			twice.pressed = true
			twice.double_click = true
			main._box_drag(twice)
			report.append("voice-box, a double click on its top line: back to its own place: %s" % (main.voice_overlay.position.distance_to(home) < 2.0))
			# and with the mouse itself, as the window receives it: press on the top line, move, release
			var grip: Vector2 = main.voice_label.get_global_rect().get_center()
			var was: Vector2 = main.voice_overlay.position
			for step in [["down", Vector2.ZERO], ["move", Vector2(-120, -90)], ["move", Vector2(-240, -180)], ["up", Vector2(-240, -180)]]:
				var ev: InputEvent
				if step[0] == "move":
					ev = InputEventMouseMotion.new()
					ev.relative = Vector2(-120, -90)
					ev.button_mask = MOUSE_BUTTON_MASK_LEFT
				else:
					ev = InputEventMouseButton.new()
					ev.button_index = MOUSE_BUTTON_LEFT
					ev.pressed = step[0] == "down"
				ev.position = grip + step[1]
				ev.global_position = grip + step[1]
				Input.parse_input_event(ev)
				await process_frame
				await process_frame
			report.append("voice-box, dragged with the mouse itself: moved by %s | solid while it has the keyboard: %s" % [main.voice_overlay.position - was, main.voice_solid])
			main._box_drag(twice)
			_hold("dictate")  # a second dictation adds to the first
			await _say(2.2)
			await main._voice_stop()
			await wait(2.0)
			report.append("voice-box, a second dictation: the box holds « %s »" % main.voice_text.text)
			var all: String = main.voice_text.text
			main.select(made["Test runner"])  # into a shell: written, never run
			await wait(1.5)
			await main._draft_send()
			await wait(1.5)
			var seen: Dictionary = await main.engine.call_api("GET", "/sessions/%s/preview?lines=14" % made["Test runner"])
			report.append("voice-box, Enter with a shell selected: its prompt holds the text: %s | the box is empty and hidden: %s | kept in Earlier: %s" % [
				str(seen.get("text", "")).replace("\n", "").contains(all.left(40)), main.voice_text.text == "" and not main.voice_overlay.visible, main.earlier.size()])
			await shot("voice-box-sent")
			main._draft_add(all)  # to an agent: sent
			main.select(made["Checkout flow"])
			await wait(1.5)
			await main._draft_send()
			await wait(1.0)
			report.append("voice-box, Enter with an agent selected: the box is empty and hidden: %s | kept in Earlier: %s | status line: « %s »" % [
				main.voice_text.text == "" and not main.voice_overlay.visible, main.earlier.size(), main.status_label.text])
		"voice-long":  # a check: a long dictation whose writing is slow (AGMGD_VOICE_FAKE="a | b | c" AGMGD_VOICE_FAKE_DELAY=<s>): every phrase must arrive, in order
			main.select(made["Checkout flow"])
			await wait(2.5)
			var began := Time.get_ticks_msec()
			_hold("dictate")
			for i in 6:
				await _say(6.0)
			await main._voice_stop()
			while int(main.take.get("pending", 0)) > 0 and Time.get_ticks_msec() - began < 120000:
				await wait(0.5)
			await wait(1.0)
			report.append("voice-long: 6 phrases, 40 s of speech, all written after %.0f s | the box holds « %s » | kept for another try: %d" % [
				(Time.get_ticks_msec() - began) / 1000.0, main.voice_text.text, main.voice_kept.size()])
			await shot("voice-long")
		"sandbox-open":  # a check: « Deploy + agentic coding session » from the Sandboxes tab must end on the new session, opened
			var a: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Load tests", "tool": "claude", "cwd": "~", "group": "Orbit API", "brain": false})
			var b: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Asset bake", "tool": "shell", "cwd": "~", "group": "Pixel Forge"})
			OS.execute("python3", [ProjectSettings.globalize_path("res://").path_join("../tools/demo_sandboxes.py"), OS.get_environment("AGMGD_HOME"), str(a["id"]), str(b["id"])], [])
			await main.refresh()
			main.set_view("sandboxes")
			await wait(2.0)
			await main._open_new("sandbox", "claude")
			await wait(0.5)
			main.f_name.text = "Cloud check"
			main.new_dialog.hide()
			var began := Time.get_ticks_msec()
			await main._create()
			var took := (Time.get_ticks_msec() - began) / 1000.0
			await wait(2.0)
			var sid := _sid("Cloud check")
			var mounted: bool = sid != "" and main.terms.has(sid) and is_instance_valid(main.terms[sid]) and main.terms[sid].get_parent() != main.parking
			report.append("sandbox-open: creation answered after %.0f s | session made: %s | selected: %s | view: %s | its terminal on screen: %s | status line: « %s »" % [
				took, sid != "", sid != "" and main.selected == sid, main.view, mounted, main.status_label.text])
			await shot("sandbox-open")
			# here Fly is a fake one, so its terminal cannot connect: it must say so in plain words, try again, then
			# wait for Enter, and the session must stay alive (before: a traceback and « Pane is dead »)
			await wait(13.0)
			await main.refresh()
			report.append("sandbox-open, 15 s later: the session is « %s »" % str(main._session(sid).get("state", "?")))
			await shot("sandbox-open-later")
		"speed":  # Loop 33: how long the common gestures take with 6, 12 and 20 sessions (numbers in the report, no picture)
			var ids: Array = made.values()
			await _speed(ids)
			for i in 14:
				var r: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Task %02d" % (i + 1), "tool": "shell" if i % 4 == 3 else "claude",
					"cwd": code.path_join(["acme-store", "orbit-api", "pixel-forge"][i % 3]), "group": ["Acme Store", "Orbit API", "Pixel Forge"][i % 3], "brain": false})
				ids.append(str(r.get("id", "")))
				if ids.size() in [12, 20]:
					await wait(2.5)
					await main.refresh()
					await _speed(ids)
		"permissions":  # Loop 24: the level at creation, its confirmation, the badge on the card
			await main.engine.call_api("POST", "/sessions", {"name": "Night refactor", "tool": "claude", "cwd": code.path_join("pixel-forge"), "group": "Pixel Forge", "brain": true, "level": "full"})
			await main.engine.call_api("POST", "/sessions", {"name": "Careful fix", "tool": "claude", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "brain": true, "level": "ask"})
			await main.refresh()
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await wait(2.0)
			await main._open_new("", "claude")
			await wait(0.5)
			main.f_name.text = "Night refactor"
			main.f_level.select(3)
			await wait(0.4)
			await shot("level-form")
			main.new_dialog.hide()
			main._create()
			await wait(0.6)
			await shot("level-confirm")
			main.confirm_dialog.hide()
			await wait(0.4)
			await shot("level-badges")
		"permissions-change":  # Loop 27: an open agent's level, changed and applied on the same conversation
			var careful: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Careful fix", "tool": "claude", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "brain": true, "level": "ask", "access": "contained"})
			await main.refresh()
			main.set_view("focus")
			main.select(str(careful["id"]))
			await wait(2.0)
			main._open_permissions(str(careful["id"]))
			await wait(0.5)
			await shot("permissions-change")
			main.perm_dialog.hide()
		"permissions-overview":  # Loop 31: every agent and what it may do
			await main.engine.call_api("POST", "/sessions", {"name": "Careful fix", "tool": "claude", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "brain": true, "level": "ask", "access": "contained"})
			await main.engine.call_api("POST", "/sessions", {"name": "Night refactor", "tool": "claude", "cwd": code.path_join("pixel-forge"), "group": "Pixel Forge", "brain": true, "level": "full", "access": "readonly"})
			await main.refresh()
			main.set_view("permissions")
			await wait(2.0)
			await shot("permissions-overview")
		"approvals":  # Loop 23: Approve answers at once and the card leaves; ✕ hides a request from the queue only
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await wait(2.0)
			await shot("queue-before")
			var appr := _find_button(main.queue_box, "Approve")
			if appr:
				appr.pressed.emit()
			await wait(0.35)
			await shot("approve-feedback")
			await wait(2.5)
			var x := _find_button(main.queue_box, "✕")
			if x:
				x.pressed.emit()
			await wait(0.6)
			await shot("queue-dismissed")
		"brain-visible":  # the Brain made visible: the badge, the ✦ lights, the header pill and the panel
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await main.refresh_brain()
			await wait(2.0)
			await main.refresh_brain()
			await shot("brain-lights")
			await main._show_brain_panel()
			await wait(1.0)
			await shot("brain-panel")
			main._toggle_brain_panel()
		"new-session":
			main.select(made["Checkout flow"])
			await wait(2.0)
			await main._open_new("", "claude")
			await wait(0.6)
			main.f_name.text = "Checkout, second pass"
			main.f_cwd.text = "~/code/acme-store"
			main.f_brain.button_pressed = true
			main.f_document.button_pressed = true
			main.f_worktree.button_pressed = true
			await wait(0.6)
			await shot("new-session")
			main.new_dialog.hide()
		"agents":
			var lead: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Release lead", "tool": "claude", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "brain": true})
			_map(str(lead["id"]), "lead-done")
			# what the lead's start_session does through Agent Manager's MCP server
			var h1: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Helper · tests", "tool": "shell", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "parent": lead["id"]})
			var h2: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Helper · changelog", "tool": "shell", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "parent": lead["id"]})
			await wait(1.5)
			_state(str(lead["id"]), "claude", DONE)
			await main.engine.call_api("POST", "/sessions/%s/send" % h1["id"], {"text": "clear; python3 -m unittest -v 2>&1"})
			await main.engine.call_api("POST", "/sessions/%s/send" % h2["id"], {"text": "clear; git log --format='- %s (%h)' --color=always"})
			await wait(1.5)
			await main.refresh()
			main.grid_ids = [str(lead["id"]), str(h1["id"]), str(h2["id"]), made["Rate limiter"]]
			main.selected = str(lead["id"])
			main.set_view("grid")
			await wait(4.0)
			await main.refresh()
			await shot("agents")
		"repos":
			for p in ["acme-store", "orbit-api"]:
				var r: Dictionary = await main.engine.call_api("POST", "/repos", {"url": "git@github.com:acme/%s.git" % p, "local_path": code.path_join(p)})
				await main.engine.call_api("POST", "/repos/%s/check" % r["id"], {})
			await main.engine.call_api("POST", "/repos", {"url": "git@github.com:acme/pixel-forge.git", "local_path": code.path_join("pixel-forge")})
			await main.refresh()
			main.set_view("repos")
			await wait(2.5)
			await shot("repos")
		"brain-keys":
			# the Keys tab: the keys this computer keeps, then the Second Brain keys, one per agent session
			main.set_view("keys")
			await wait(3.0)
			await shot("brain-keys")
		"review":
			var repo := code.path_join("acme-store")
			_write(repo.path_join("src/checkout/giftcard.ts"), "export interface GiftCard { code: string; balance: number }\n\nexport function redeemGiftCard(total: number, card: GiftCard) {\n  const applied = Math.min(total, card.balance);\n  return { applied, remaining: total - applied, card: { ...card, balance: card.balance - applied } };\n}\n")
			_write(repo.path_join("tests/giftcard.test.ts"), "import { redeemGiftCard } from \"../src/checkout/giftcard\";\n\ntest(\"takes no more than the balance\", () => {\n  const r = redeemGiftCard(80, { code: \"GIFT-1234\", balance: 50 });\n  expect(r.applied).toBe(50);\n  expect(r.remaining).toBe(30);\n});\n")
			_write(repo.path_join("README.md"), "# Acme Store\nA small storefront: catalogue, cart and checkout.\n\nGift cards are redeemed at checkout, never for more than their balance.\n")
			var sid: String = made["Checkout flow"]
			main.select(sid)
			await wait(1.0)
			main.set_view("review")
			await wait(1.5)
			await main.engine.call_api("POST", "/sessions/%s/comments" % sid, {"path": "src/checkout/giftcard.ts", "line": 4, "code": "  const applied = Math.min(total, card.balance);", "text": "Round to cents: totals come in as floats"})
			await main.engine.call_api("POST", "/sessions/%s/comments" % sid, {"path": "src/checkout/giftcard.ts", "line": 5, "code": "  return { applied, remaining: total - applied, card: { ...card, balance: card.balance - applied } };", "text": "Also refuse an expired card"})
			await main._load_review()
			for i in main.review_files.item_count:
				if main.review_files.get_item_text(i).contains("giftcard.ts") and not main.review_files.get_item_text(i).contains("test"):
					main.review_file = i
					main.review_files.select(i)
			main._render_review_file()
			await wait(1.2)
			await shot("review")
		"voice":
			main.select(made["Checkout flow"])
			await wait(2.5)
			_hold("dictate")
			main.take["texts"] = ["Add a gift card to the checkout, redeemed at payment."]
			main._take_show(main.take)
			main.voice_meter.value = 0.62
			await wait(0.6)
			await shot("voice")
			main.dictation.recording = false
			main.voice_live.visible = false
			main.voice_overlay.visible = false
			await main.run_voice_command("approve Flaky tests")
			await wait(0.8)
			await shot("voice-confirm")
			main.confirm_dialog.hide()
		"sandboxes":
			var a: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Load tests", "tool": "claude", "cwd": "~", "group": "Orbit API", "brain": false})
			var b: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Asset bake", "tool": "shell", "cwd": "~", "group": "Pixel Forge"})
			_map(str(a["id"]), "limiter-question")
			var o := []
			OS.execute("python3", [ProjectSettings.globalize_path("res://").path_join("../tools/demo_sandboxes.py"), OS.get_environment("AGMGD_HOME"), str(a["id"]), str(b["id"])], o)
			await main.refresh()
			main.set_view("sandboxes")
			await wait(3.0)
			await main._load_sandboxes()
			await wait(2.5)
			await shot("sandboxes")
		"palette":
			main.select(made["Sparks"])
			await wait(2.0)
			main.open_palette()
			main.palette.edit.text = "gr"
			main.palette._filter("gr")
			await wait(0.6)
			await shot("palette")
			main.palette.hide()
			for t in ["terminal", "neon", "paper"]:
				await main.set_theme_name(t)
				main.grid_ids = [made["Checkout flow"], made["Flaky tests"], made["Rate limiter"], made["Test runner"]]
				main.set_view("grid")
				await wait(2.5)
				await shot("theme-%s" % t)
			await main.set_theme_name("focus")
		# ---------------------------------------------------------------- How-to guides (tools/howto/guides.py)
		"howto-first-minutes":
			var g := "first-minutes"
			main.select(made["Checkout flow"])  # the new session goes into the selected session's group
			await wait(2.0)
			await main._open_new("", "claude")
			await wait(0.6)
			main.f_name.text = "Gift card"
			main.f_cwd.text = "~/code/acme-store"
			await wait(0.4)
			await hshot(g, 1)
			main.new_dialog.hide()
			main.f_cwd.text = code.path_join("acme-store")
			await main._create()
			var sid := _sid("Gift card")
			_map(sid, "idle-claude")
			_state(sid, "claude", {"hook_event_name": "SessionStart"})  # as Claude Code says when it starts
			await wait(3.0)
			await main.refresh()
			await hshot(g, 2)
			_map(sid, "checkout-working")
			_state(sid, "claude", WORKING)
			await wait(2.0)
			await main.refresh()
			await hshot(g, 3)
			main.select(made["Checkout flow"])
			await wait(1.5)
			main._toast("Flaky tests waits for your OK")
			await main.refresh()
			await hshot(g, 4)
			_state(sid, "claude", DONE)
			await main.refresh()
			main.select(made["Sparks"])
			await wait(2.0)
			main._toast("Gift card is done")
			await hshot(g, 5)
		"howto-answer-fast":
			var g := "answer-fast"
			main.select(made["Checkout flow"])
			await wait(2.5)
			await hshot(g, 1)
			_state(made["Flaky tests"], "claude", WORKING)
			await main.refresh()
			main._toast("Approved: Flaky tests carries on")
			await wait(0.8)
			await hshot(g, 2)
			main._quick_reply(made["Rate limiter"])
			main.ask_edit.text = "Per API key, with the client IP as a fallback"
			await wait(0.6)
			await hshot(g, 3)
			main.ask_dialog.hide()
			main.select(made["Rate limiter"])
			await wait(2.5)
			await hshot(g, 4)
		"howto-views":
			var g := "views"
			main.select(made["Checkout flow"])
			await wait(2.5)
			await hshot(g, 1)
			main.grid_ids = [made["Checkout flow"], made["Flaky tests"], made["Rate limiter"], made["Test runner"]]
			main.set_view("grid")
			await wait(3.5)
			await main.refresh()
			await hshot(g, 2)
			main.set_view("board")
			await wait(3.5)
			await main.refresh()
			await wait(1.0)
			await hshot(g, 3)
			main.set_view("focus")
			main.select(made["Sparks"])
			await wait(2.0)
			main.open_palette()
			main.palette.edit.text = "gr"
			main.palette._filter("gr")
			await wait(0.6)
			await hshot(g, 4)
			main.palette.hide()
		"howto-review":
			var g := "review"
			_review_files()
			var sid: String = made["Checkout flow"]
			main.select(sid)
			await wait(1.0)
			main.set_view("review")
			await wait(1.5)
			await main._load_review()
			await wait(0.8)
			await hshot(g, 1)
			_review_pick("giftcard.ts")
			await wait(0.8)
			await hshot(g, 2)
			await main.engine.call_api("POST", "/sessions/%s/comments" % sid, {"path": "src/checkout/giftcard.ts", "line": 4, "code": "  const applied = Math.min(total, card.balance);", "text": "Round to cents: totals come in as floats"})
			await main.engine.call_api("POST", "/sessions/%s/comments" % sid, {"path": "src/checkout/giftcard.ts", "line": 5, "code": "  return { applied, remaining: total - applied, card: { ...card, balance: card.balance - applied } };", "text": "Also refuse an expired card"})
			await main._load_review()
			_review_pick("giftcard.ts")
			await wait(0.8)
			await hshot(g, 3)
			await main._send_review()
			await wait(0.8)
			await hshot(g, 4)
		"howto-history":
			var g := "history"
			main.set_view("history")
			await wait(2.5)
			await hshot(g, 1)
			main.history_search.text = "acme"
			await main._load_history()
			await wait(1.5)
			await hshot(g, 2)
			main.set_view("focus")
			main._fork(made["Checkout flow"])
			await wait(0.5)
			main.ask_dialog.hide()
			var fk: Dictionary = await main.engine.call_api("POST", "/sessions/%s/fork" % made["Checkout flow"], {"name": "Checkout flow (fork)"})
			_map(str(fk.get("id", "")), "checkout-working")
			_state(str(fk.get("id", "")), "claude", WORKING)
			await wait(1.0)
			await main.refresh()
			main.select(str(fk.get("id", "")))
			await wait(3.0)
			await hshot(g, 3)
			var wt: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Tax rules", "tool": "claude", "cwd": code.path_join("acme-store"), "group": "Acme Store", "brain": true, "worktree": true})
			_map(str(wt.get("id", "")), "idle-claude")
			_state(str(wt.get("id", "")), "claude", {"hook_event_name": "SessionStart"})
			await wait(2.0)
			await main.refresh()
			main.select(str(wt.get("id", "")))
			await wait(2.5)
			await hshot(g, 4)
		"howto-connect-repo":
			var g := "connect-repo"
			main.set_view("repos")
			await wait(2.0)
			await hshot(g, 1)
			for le in main.find_children("*", "LineEdit", true, false):
				if (le as LineEdit).placeholder_text.begins_with("git@github.com"):
					le.text = "git@github.com:acme/acme-store.git"
				elif (le as LineEdit).placeholder_text.begins_with("your folder"):
					le.text = "~/code/acme-store"
			await wait(0.5)
			await hshot(g, 2)
			var r: Dictionary = await main.engine.call_api("POST", "/repos", {"url": "git@github.com:acme/acme-store.git", "local_path": code.path_join("acme-store")})
			await main.engine.call_api("POST", "/repos/%s/check" % r["id"], {})
			await main.refresh()
			main.set_view("repos")
			await wait(2.5)
			await hshot(g, 3)
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await wait(1.5)
			await main._open_new("", "claude")
			await wait(0.5)
			for i in main.f_repo.item_count:
				if str(main.f_repo.get_item_text(i)).contains("acme-store"):
					main.f_repo.select(i)
					main.f_repo.item_selected.emit(i)
			main.f_name.text = "Release notes"
			main.f_cwd.text = "~/code/acme-store"  # the app shows the full path; the demo's lives in a temporary folder
			await wait(0.6)
			await hshot(g, 4)
			main.new_dialog.hide()
		"howto-voice":
			var g := "voice"
			main.set_view("keys")
			await wait(2.5)
			await hshot(g, 1)
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await wait(2.5)
			_hold("dictate")
			main.take["texts"] = ["Add a gift card to the checkout, redeemed at payment."]
			main._take_show(main.take)
			main.voice_meter.value = 0.58
			await wait(0.6)
			await hshot(g, 2)
			main.dictation.recording = false
			main.voice_live.visible = false
			main.voice_overlay.visible = false
			await main.run_voice_command("approve Flaky tests")
			await wait(0.8)
			await hshot(g, 3)
			main.confirm_dialog.hide()
			_state(made["Flaky tests"], "claude", WORKING)
			await main.refresh()
			main._toast("Approved: Flaky tests carries on")
			await wait(0.8)
			await hshot(g, 4)
		"howto-agents":
			var g := "agents"
			var lead: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Release lead", "tool": "claude", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "brain": true})
			_map(str(lead["id"]), "lead-done")
			_state(str(lead["id"]), "claude", WORKING)
			await wait(1.5)
			await main.refresh()
			main.select(str(lead["id"]))
			await wait(2.5)
			await hshot(g, 1)
			var h1: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Helper · tests", "tool": "shell", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "parent": lead["id"]})
			var h2: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Helper · changelog", "tool": "shell", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "parent": lead["id"]})
			await wait(1.2)
			await main.engine.call_api("POST", "/sessions/%s/send" % h1["id"], {"text": "clear; python3 -m unittest -v 2>&1"})
			await main.engine.call_api("POST", "/sessions/%s/send" % h2["id"], {"text": "clear; git log --format='- %s (%h)' --color=always"})
			await wait(1.5)
			await main.refresh()
			main.select(str(h1["id"]))
			await wait(2.0)
			await hshot(g, 2)
			_state(str(lead["id"]), "claude", DONE)
			main.grid_ids = [str(lead["id"]), str(h1["id"]), str(h2["id"]), made["Rate limiter"]]
			main.selected = str(lead["id"])
			main.set_view("grid")
			await wait(3.5)
			await main.refresh()
			await hshot(g, 3)
		"howto-brain-document":
			var g := "brain-document"
			main.select(made["Checkout flow"])
			await wait(1.5)
			await main._open_new("", "claude")
			await wait(0.5)
			main.f_name.text = "Shipping zones"
			main.f_cwd.text = "~/code/acme-store"
			main.f_brain.button_pressed = true
			main.f_document.button_pressed = true
			await wait(0.6)
			await hshot(g, 1)
			main.new_dialog.hide()
			var d: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Shipping zones", "tool": "claude", "cwd": code.path_join("acme-store"), "group": "Acme Store", "brain": true, "document": true})
			_map(str(d["id"]), "checkout-working")
			_state(str(d["id"]), "claude", WORKING)
			await wait(1.5)
			await main.refresh()
			main.select(str(d["id"]))
			await wait(2.5)
			await hshot(g, 2)
			main.set_view("keys")
			await wait(3.0)
			await hshot(g, 3)
			# the Brain's side: Second Brain's own screenshot (from its website), the same size as a step
			var img := Image.load_from_file(ProjectSettings.globalize_path("res://").path_join("../public/assets/brain/mcp-proposals.webp"))
			img.resize(1280, 800, Image.INTERPOLATE_LANCZOS)
			img.save_webp(OS.get_environment("SHOW_HOWTO").path_join(g).path_join("04.webp"), true, 0.88)
			report.append("howto %s 04 (Second Brain's own screenshot)" % g)
		"howto-remote-control":
			var g := "remote-control"
			main.select(made["Checkout flow"])
			await wait(1.5)
			await main._open_new("", "claude")
			await wait(0.5)
			main.f_name.text = "Night run"
			main.f_cwd.text = "~/code/orbit-api"
			await wait(0.6)
			await hshot(g, 1)
			main.new_dialog.hide()
			var rc: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Night run", "tool": "claude", "cwd": code.path_join("orbit-api"), "group": "Orbit API", "brain": true, "remote": true})
			_map(str(rc["id"]), "lead-done")
			_state(str(rc["id"]), "claude", DONE)
			await wait(1.5)
			await main.refresh()
			main.select(str(rc["id"]))
			await wait(2.5)
			await hshot(g, 2)
		"howto-sandbox":
			var g := "sandbox"
			var a: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Load tests", "tool": "claude", "cwd": "~", "group": "Orbit API", "brain": false})
			var b: Dictionary = await main.engine.call_api("POST", "/sessions", {"name": "Asset bake", "tool": "shell", "cwd": "~", "group": "Pixel Forge"})
			_map(str(a["id"]), "limiter-question")
			OS.execute("python3", [ProjectSettings.globalize_path("res://").path_join("../tools/demo_sandboxes.py"), OS.get_environment("AGMGD_HOME"), str(a["id"]), str(b["id"])], [])
			await main.refresh()
			main.set_view("sandboxes")
			await wait(3.0)
			await main._load_sandboxes()
			await wait(2.5)
			await hshot(g, 1)
			main.set_view("focus")
			main.select(made["Checkout flow"])
			await wait(1.5)
			await main._open_new("", "claude")
			await wait(0.5)
			for i in main.f_where.item_count:
				if str(main.f_where.get_item_text(i)).contains("cloud"):
					main.f_where.select(i)
					main.f_where.item_selected.emit(i)
			main.f_name.text = "Load tests, round 2"
			await wait(0.6)
			await hshot(g, 2)
			main.new_dialog.hide()
		"howto-make-it-yours":
			var g := "make-it-yours"
			await main.set_theme_name("neon")
			main.grid_ids = [made["Checkout flow"], made["Flaky tests"], made["Rate limiter"], made["Test runner"]]
			main.set_view("grid")
			await wait(3.0)
			await hshot(g, 1)
			await main.set_theme_name("focus")
			main.set_view("shortcuts")
			await wait(2.0)
			await hshot(g, 2)
	for x in main.sessions.duplicate():
		await main.engine.call_api("DELETE", "/sessions/%s" % x["id"])
	var f := FileAccess.open(OS.get_environment("SHOW_REPORTS").path_join("report-%s.txt" % OS.get_environment("SHOW_STEP")), FileAccess.WRITE)
	f.store_string("\n".join(report) + "\n")
	f.close()
	print("\n".join(report))
	quit()


## The voice key goes down, as far as the app can tell: there is no microphone on the virtual display.
func _hold(mode: String) -> void:
	main.voice_mode = mode
	main.take = {"mode": mode, "texts": [], "pending": 0, "ended": false, "failed": [], "cost": 0.0}
	var d: Dictation = main.dictation
	d.frames = PackedVector2Array()
	d.pieces = 0
	d._heard = false
	d._ever = false
	d._quiet = 0.0
	d.recording = true
	d.started_ms = Time.get_ticks_msec()
	main.voice_live.text = "…"
	main.voice_live.visible = true
	main._box_show(false)


## Someone speaks for `seconds`, then pauses: a tone loud enough to count as speech, then quiet, given to the
## dictation in 20 ms chunks as the microphone would. A pause of 0 leaves the phrase unfinished.
func _say(seconds: float, pause := 0.9) -> void:
	var rate := AudioServer.get_mix_rate()
	for part in [[seconds, 0.2], [pause, 0.0]]:
		var left := int(rate * float(part[0]))
		while left > 0:
			var chunk := PackedVector2Array()
			chunk.resize(mini(int(rate / 50), left))
			for i in chunk.size():
				var v := float(part[1]) * sin(i * 0.2)
				chunk[i] = Vector2(v, v)
			main.dictation.feed(chunk)
			left -= chunk.size()
		await process_frame


func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


func _med(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2] if not b.is_empty() else 0.0


## Times, in milliseconds, of what the owner does all day: the engine's answer to « the whole tree », redrawing the
## list, a refresh that found a change, opening a session for the first time and again, changing view. On the virtual
## display a frame is drawn by the processor, so « frame » is given too: gestures cannot be faster than one frame.
func _speed(ids: Array) -> void:
	var n: int = main.sessions.size()
	var frame := []
	for i in 10:
		var t0 := Time.get_ticks_usec()
		await process_frame
		frame.append(_ms(t0))
	var api := []
	for i in 8:
		var t0 := Time.get_ticks_usec()
		await main.engine.call_api("GET", "/tree")
		api.append(_ms(t0))
	var list := []
	for i in 8:
		var t0 := Time.get_ticks_usec()
		main._render_list()
		list.append(_ms(t0))
		await process_frame
	var changed := []
	for i in 6:
		main.tree_sig = ""  # as when a state changed
		var t0 := Time.get_ticks_usec()
		await main.refresh()
		changed.append(_ms(t0))
	var same := []
	for i in 6:
		var t0 := Time.get_ticks_usec()
		await main.refresh()
		same.append(_ms(t0))
	main.set_view("focus")
	await wait(0.5)
	var cold := []
	for id in ids:
		if not main.terms.has(id) and cold.size() < 4:
			var t0 := Time.get_ticks_usec()
			await main.select(id)
			cold.append(_ms(t0))
			await wait(0.4)
	var warm := []
	for i in 12:
		var id: String = ids[(i * 5) % ids.size()]
		if not main.terms.has(id):
			await main.select(id)
			await wait(0.4)
		var t0 := Time.get_ticks_usec()
		await main.select(id)
		warm.append(_ms(t0))
		await process_frame
	var views := {}
	for v in ["grid", "focus", "board", "focus"]:
		var t0 := Time.get_ticks_usec()
		await main.set_view(v)
		views[v + ("2" if views.has(v) else "")] = _ms(t0)
		await wait(0.5)
	report.append("speed %2d sessions, %2d terminals | frame %.0f | tree from the engine %.0f (max %.0f) | list redrawn %.1f | refresh, changed %.0f, unchanged %.0f | open first time %.0f | open again %.1f (max %.1f) | to grid %.0f, to focus %.0f, to board %.0f" % [
		n, main.terms.size(), _med(frame), _med(api), api.max(), _med(list), _med(changed), _med(same), _med(cold), _med(warm), warm.max(), views.get("grid", 0.0), views.get("focus", 0.0), views.get("board", 0.0)])
	# where the list's time goes: a font, the queue, a group's header, one session
	var parts := {}
	var t1 := Time.get_ticks_usec()
	for i in 20:
		AmTheme.ui_font(600)
	parts["font"] = _ms(t1) / 20.0
	t1 = Time.get_ticks_usec()
	for i in 5:
		main._render_queue()
	parts["queue"] = _ms(t1) / 5.0
	t1 = Time.get_ticks_usec()
	for i in 10:
		main._group_header(main.tree[1]).free()
	parts["header"] = _ms(t1) / 10.0
	t1 = Time.get_ticks_usec()
	for s in main.sessions:
		main._card(s, "", 0).free()
	parts["session"] = _ms(t1) / maxf(1.0, n)
	main.tree_sig = ""
	await main.refresh()
	t1 = Time.get_ticks_usec()
	main._render_header()
	parts["top"] = _ms(t1)
	t1 = Time.get_ticks_usec()
	main._layout_view()
	parts["layout"] = _ms(t1)
	report.append("      where it goes | a font %.2f | the queue %.1f | a group's header %.2f | one session %.2f | the header %.1f | laying out the view %.1f" % [
		parts["font"], parts["queue"], parts["header"], parts["session"], parts["top"], parts["layout"]])


func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text:
			return n
	return null
