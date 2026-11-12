extends SceneTree
## The website screenshots (tools/showcase.sh): the real app on a private virtual display, with a fictional workspace
## (user « dev », projects in ~/code). Agent terminals replay recorded real screens (tools/showcase/bin/agent-replay).
## SHOW_STEP = measure | hero | … ; screenshots go to SHOW_OUT as webp.

const HostView := preload("res://scripts/host_view.gd")
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
	main.setup_at_start = false  # the steps ask for the ground's reading themselves, with their own answers
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
		"topbar":  # Loop 36: the top bar. One « View » button for the ways to look at the sessions, the managers beside it (a click opens, a second click comes back), the ground's button alive, and a narrow window
			main.select(made["Checkout flow"])
			await wait(1.5)
			report.append("topbar: at the start: %s" % _bar())
			main.view_btn.pressed.emit()
			await wait(0.3)
			var listed := []
			for x in main.SESSION_VIEWS:
				var row: Array = main.view_rows[x[0]]
				listed.append(("✓ " if (row[0] as Button).button_pressed else "") + (row[0] as Button).text + " · " + (row[1] as Label).text)
			var themes := []
			for t in AmTheme.THEMES:
				themes.append(("✓ " if (main.theme_chips[t] as Button).button_pressed else "") + (main.theme_chips[t] as Button).text)
			report.append("topbar: « View » opens: %s | themes: %s | the button still says the view: %s" % [" | ".join(listed), ", ".join(themes), main.view_btn.button_pressed])
			await shot("topbar-menu")
			# a theme: the window changes at once and the panel stays open for the next try
			var theme_was: String = AmTheme.current
			(main.theme_chips["paper"] as Button).pressed.emit()
			await wait(1.2)
			report.append("topbar: « Paper » clicked: theme « %s » | the panel is still open: %s | its mark moved: %s" % [AmTheme.current, main.view_panel.visible, (main.theme_chips["paper"] as Button).button_pressed and not (main.theme_chips[theme_was] as Button).button_pressed])
			await shot("topbar-menu-paper")
			(main.theme_chips["neon"] as Button).pressed.emit()
			await wait(1.2)
			var tried: String = AmTheme.current
			(main.theme_chips[theme_was] as Button).pressed.emit()
			await wait(1.2)
			report.append("topbar: then « Neon », then back: « %s », « %s » | the panel is still open: %s | the settings menu no longer lists themes: %s" % [tried, AmTheme.current, main.view_panel.visible,
				range(main.theme_menu.item_count).all(func(i: int) -> bool: return not AmTheme.LABELS.values().has(main.theme_menu.get_item_text(i)))])
			# a way to show the sessions: the panel closes and the sessions are shown that way
			(main.view_rows["grid"][0] as Button).pressed.emit()
			await wait(1.5)
			report.append("topbar: « Grid » chosen: view « %s » | the panel closed: %s | %s" % [main.view, not main.view_panel.visible, _bar()])
			main.view_buttons["sandboxes"].pressed.emit()
			await wait(0.8)
			report.append("topbar: « Sandboxes »: view « %s » | %s" % [main.view, _bar()])
			main.view_buttons["repos"].pressed.emit()
			await wait(0.8)
			var on_repos: String = main.view
			main.view_buttons["repos"].pressed.emit()
			await wait(1.0)
			report.append("topbar: « Repos » then « Repos » again: view « %s », then back to « %s » | %s" % [on_repos, main.view, _bar()])
			# the ground's button: first as this display's engine says, then with a made-up computer for the pictures
			await main._ground_poll()
			report.append("topbar: the ground's button, nothing read yet: level %s, a figure after its name: %s | « %s »" % [main.ground["level"], str(main.ground["text"]).length() > str(main.ground["short"]).length(), str(main.ground["tip"]).get_slice("\n", 0).left(12)])
			var rec := ProjectSettings.globalize_path("res://").path_join("../tools/setup/recorded")
			var win := FileAccess.get_file_as_string(rec.path_join("windows-en.txt"))
			var doc := FileAccess.get_file_as_string(rec.path_join("doctor.txt"))
			main.setup_probe.on_windows = true
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				return {"code": 0, "out": win if str(a[0]) == "powershell.exe" else doc}
			main._setup_read()
			while main.setup_thread != null:
				await process_frame
			await wait(0.6)  # the engine's own answer, asked with the reading, has come: the made-up one replaces it
			var moment := int(Time.get_unix_time_from_datetime_string("2026-11-12T15:20:00"))
			main.setup_host = _made_up_host(moment)
			main._render_ground_button()
			await wait(0.3)
			report.append("topbar: a disk nearly full: « %s », level %s | it says why: %s" % [main.view_buttons["setup"].text, main.ground["level"], str(main.ground["tip"]).contains("! Disk, free on C:")])
			main.set_view("focus")
			await wait(1.5)
			await shot("topbar")
			main.view_buttons["setup"].pressed.emit()
			while main.setup_thread != null:
				await process_frame
			await wait(0.4)
			main.setup_dash._timer.stop()
			main.setup_dash.bias = 0
			main.setup_host = _made_up_host(moment)
			main.setup_hist = _made_up_hour(moment)
			main._layout_view()
			main._render_ground_button()
			await wait(0.3)
			report.append("topbar: the ground's button opens its page: view « %s », titled « %s » | %s" % [main.view, (main.content.find_children("*", "Label", true, false)[0] as Label).text, _bar()])
			await shot("topbar-wsl")
			# a narrow window (here the app's own frame is narrowed: this display's window keeps its size): the
			# managers show their sign alone, and nothing is cut
			main.set_anchors_preset(Control.PRESET_TOP_LEFT)
			main.size = Vector2(1150, 1200)
			await wait(0.6)
			report.append("topbar: the app %d wide: compact: %s | %s | the bar fits: %s" % [int(main.size.x), main.header_compact, _bar(), main.header_box.get_combined_minimum_size().x <= main.header_box.size.x + 0.5])
			await shot("topbar-narrow")
			main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			await wait(0.6)
			report.append("topbar: wide again: compact: %s | %s" % [main.header_compact, _bar()])
			main.view_buttons["setup"].pressed.emit()
			await wait(1.0)
			var engine_was: bool = main.engine.connected
			main.engine.connected = false
			main._render_ground_button()
			report.append("topbar: back to « %s » | the engine not answering: « %s », level %s" % [main.view, main.view_buttons["setup"].text, main.ground["level"]])
			main.engine.connected = engine_was
			main._render_ground_button()
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
			# its bottom right corner makes it larger: pressed, moved, released with the mouse itself
			var corner: Vector2 = main.voice_grip.get_global_rect().get_center()
			var small: Vector2 = main.voice_overlay.size
			var stays: Vector2 = main.voice_overlay.position
			for step in [["down", Vector2.ZERO], ["move", Vector2(140, 110)], ["move", Vector2(280, 220)], ["up", Vector2(280, 220)]]:
				var ev: InputEvent
				if step[0] == "move":
					ev = InputEventMouseMotion.new()
					ev.relative = Vector2(140, 110)
					ev.button_mask = MOUSE_BUTTON_MASK_LEFT
				else:
					ev = InputEventMouseButton.new()
					ev.button_index = MOUSE_BUTTON_LEFT
					ev.pressed = step[0] == "down"
				ev.position = corner + step[1]
				ev.global_position = corner + step[1]
				Input.parse_input_event(ev)
				await process_frame
				await process_frame
			await wait(0.3)
			report.append("voice-box, its corner dragged with the mouse: from %s to %s | its top left corner did not move: %s | the size is remembered: %s" % [
				small, main.voice_overlay.size, main.voice_overlay.position == stays, main.voice_size != main.VOICE_SIZE])
			await shot("voice-box-large")
			var back := InputEventMouseButton.new()
			back.button_index = MOUSE_BUTTON_LEFT
			back.pressed = true
			back.double_click = true
			main._box_resize(back)
			await wait(0.2)
			report.append("voice-box, a double click on its corner: its own size again: %s" % (main.voice_overlay.size.distance_to(small) < 2.0))
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
		"voice-mute":  # a check: the key is held and the microphone gives nothing (Windows took the audio device away): the box must say so
			main.select(made["Checkout flow"])
			await wait(2.0)
			_hold("dictate")
			main.voice_mute = false
			var mic: Dictation = main.dictation
			mic._live = true
			mic._loudest = 0.0
			mic._fed_ms = Time.get_ticks_msec()
			mic._reopened = false
			mic._told = false
			await wait(4.5)
			report.append("voice-mute: after 4.5 s without a sound from the microphone: opened again once: %s | the box says: « %s » | status line: « %s »" % [
				mic._reopened, main.voice_label.text, main.status_label.text])
			await shot("voice-mute")
			await main._voice_stop()
		"voice-end":  # a check: the last words, short and said low, with the key released on them; and a piece that comes back late. Run with AGMGD_VOICE_FAKE="a first phrase" AGMGD_VOICE_FAKE_DELAY=6 AGMGD_VOICE_FAKE_WHOLE="A first phrase, and its last words." AGMGD_VOICE_FAKE_WHOLE_DELAY=0.5
			main.select(made["Checkout flow"])
			await wait(2.5)
			_hold("dictate")
			await _say(2.5)  # a phrase and its pause: a piece is cut there, and takes 6 s to be written down
			await _say(0.3, 0.0, 0.025)  # the last words: short, lower than what counts as speech
			var ear: Dictation = main.dictation
			var let_go := Time.get_ticks_usec()
			await main._voice_stop()
			report.append("voice-end: 3.7 s said, the key released on low last words: it listened %.2f s more | the whole recording holds %.2f s | its end, which no piece held: %.2f s | pieces shown: %d" % [
				_ms(let_go) / 1000.0, ear.whole.size() / 32000.0, ear.rest.size() / 32000.0, ear.pieces])
			await wait(1.5)
			report.append("voice-end, 1.5 s later, the piece still being written: the box holds « %s » | nothing is waited for: %s" % [
				main.voice_text.text, int(main.take.get("pending", 0)) == 0])
			await wait(6.5)
			report.append("voice-end, once the late piece is back: the box holds « %s » | kept for another try: %d | status line: « %s »" % [
				main.voice_text.text, main.voice_kept.size(), main.status_label.text])
			_hold("dictate")  # pressed again within the moment it still listens: the same dictation goes on
			await _say(1.0, 0.0)
			main._voice_stop()
			await wait(0.15)
			main._voice_start()
			await _say(1.0, 0.0)
			await main._voice_stop()
			report.append("voice-end, released and pressed again at once: one recording of %.2f s (2 s said)" % (ear.whole.size() / 32000.0))
			await wait(1.5)
			await shot("voice-end")
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
		"setup":  # Loop 36: the setup check read from the ground up. A check and its pictures: the Windows ladder from recorded outputs (there is no Windows on this display), read slowly on purpose; then WSL missing; then the engine down and started again
			var rec := ProjectSettings.globalize_path("res://").path_join("../tools/setup/recorded")
			var win := FileAccess.get_file_as_string(rec.path_join("windows-en.txt"))
			var doc := FileAccess.get_file_as_string(rec.path_join("doctor.txt"))
			main.setup_probe.on_windows = true
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				OS.delay_msec(3000 if str(a[0]) == "powershell.exe" else 400)  # as slow as the real ones
				return {"code": 0, "out": win if str(a[0]) == "powershell.exe" else doc}
			var began := Time.get_ticks_msec()
			main.set_view("setup")
			var open_ms := Time.get_ticks_msec() - began
			var worst := 0
			var drawn := 0
			var before := Time.get_ticks_msec()
			var pictured := false
			while main.setup_thread != null:
				await process_frame
				var now := Time.get_ticks_msec()
				worst = maxi(worst, now - before)
				before = now
				drawn += 1
				if not pictured and now - began > 600:
					pictured = true
					report.append("setup: while reading: %s" % _setup_marks())
					await shot("setup-reading")
					before = Time.get_ticks_msec()
			report.append("setup: the page opened in %d ms; the reading took %.1f s, during which %d frames were drawn, the longest in %d ms" % [open_ms, (Time.get_ticks_msec() - began) / 1000.0, drawn, worst])
			await wait(0.2)
			report.append("setup: everything there: %s | « %s »" % [_setup_marks(), _setup_text("Everything needed")])
			# with everything standing, the ladder is one line of marks; « Show every line » brings the lines back
			var marks_line: bool = main.content.find_child("SetupMarks", true, false) != null
			_find_button(main.content, "Show every line").pressed.emit()
			await wait(0.2)
			report.append("setup: all standing: one line of marks: %s | « Show every line »: %d lines, « %s » offered" % [marks_line, _setup_marks().length(), "Show less" if _find_button(main.content, "Show less") != null else "?"])
			await shot("setup-lines")
			_find_button(main.content, "Show less").pressed.emit()
			await wait(0.2)
			# --- the engine room's dashboard. First the engine's own answers on this display: real readings (every
			# 2 seconds here, 30 in the app), only their shape is reported. Then a made-up hour and a made-up week for
			# the pictures.
			var real: Dictionary = await main.engine.call_api("GET", "/host")
			var hist_real := {}
			var readings := 0
			for i in 40:
				hist_real = await main.engine.call_api("GET", "/host/history?seconds=3600&points=60")
				readings = 0
				for c in hist_real.get("readings", []):
					readings += int(c)
				if readings >= 3:
					break
				await wait(0.5)
			real = await main.engine.call_api("GET", "/host")
			report.append("setup: the engine's figures: memory %s | disk %s | %d sessions weighed, the lightest above 1 MB: %s" % [int(real["memory"]["total"]) > 0, int(real["disk"]["total"]) > 0, real["sessions"].size(), real["sessions"].all(func(x: Dictionary) -> bool: return int(x["bytes"]) > 1048576)])
			report.append("setup: readings over time: every %d s here | at least 3 readings: %s | sessions named in them: %d of %d running | each session's age and processor share known: %s | the engine weighs itself: %s" % [
				int(real["history"]["interval"]), readings >= 3, hist_real["sessions"].size(), real["sessions"].size(),
				real["sessions"].all(func(x: Dictionary) -> bool: return float(x["created"]) > 0.0 and x["cpu"] != null), int(real["engine"]["bytes"]) > 1048576])
			await main._setup_ask_host()
			await main._setup_ask_history()
			await wait(0.3)
			var dash = main.setup_dash
			var on_page: bool = is_instance_valid(dash) and dash.is_visible_in_tree()
			report.append("setup: the dashboard is on the page: %s | tiles: %s | bars: %d, with a reading: %d | lines in the table: %d" % [on_page,
				", ".join(dash._tiles.items.map(func(t: Dictionary) -> String: return str(t["id"]))), dash._chart.bars.size(),
				dash._chart.bars.filter(func(x: Variant) -> bool: return x != null).size(), dash._table.rows.size()])
			# its tick asks the engine again without laying the page out again (the page would jump back to its top)
			var page_before: Node = main.content.get_child(0)
			var now_before := float(dash.host.get("now", 0.0))
			await wait(1.1)
			await main._setup_tick()
			await wait(0.3)
			report.append("setup: a tick: newer figures: %s | the page was not laid out again: %s" % [float(dash.host.get("now", 0.0)) > now_before, main.content.get_child(0) == page_before])
			# a click on a running session's line shows that session
			var first_id := str(dash._table.rows[0]["id"])
			var selected_was: String = main.selected
			var move := InputEventMouseMotion.new()
			move.position = Vector2(60, dash._table.HEAD + dash._table.ROW * 0.5)
			dash._table._gui_input(move)
			var click := InputEventMouseButton.new()
			click.position = move.position
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			dash._table._gui_input(click)
			await wait(0.4)
			report.append("setup: a click on a session's line: the view is « %s », on that session: %s" % [main.view, main.selected == first_id])
			main.selected = selected_was  # as it was (no session was selected in this step): the pictures' header stays plain
			main.tree_sig = ""
			main._render_list()
			main._render_header()
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				return {"code": 0, "out": win if str(a[0]) == "powershell.exe" else doc}
			main.set_view("setup")
			while main.setup_thread != null:
				await process_frame
			await wait(0.3)
			report.append("setup: back on the page: the same dashboard is there: %s" % (main.setup_dash == dash and dash.is_visible_in_tree()))
			# another span: the engine is asked for it, and the choice is kept
			dash._buttons["7d"].button_pressed = true
			dash._buttons["7d"].pressed.emit()
			await wait(0.6)
			report.append("setup: « 7 days »: %d slices of %d s asked of the engine | kept as the chosen span: %s | shown at full strength again: %s" % [dash.hist.get("t", []).size(), int(dash.hist.get("step", 0)), main.setup_range == "7d", dash._chart.modulate.a == 1.0])
			dash._buttons["1h"].button_pressed = true
			dash._buttons["1h"].pressed.emit()
			await wait(0.6)
			# --- the pictures: a made-up hour, then a made-up week, at a made-up moment (so they do not change with the day they are taken)
			dash._timer.stop()
			dash.bias = 0
			dash._table.hover = -1
			var moment := int(Time.get_unix_time_from_datetime_string("2026-11-12T15:20:00"))
			main.setup_host = _made_up_host(moment)
			main.setup_hist = _made_up_hour(moment)
			main._layout_view()
			await wait(0.3)
			var tiles: Array = HostView.tiles(main.setup_facts, main.setup_host, main.setup_hist, true)
			report.append("setup: dashboard, a made-up hour: %s" % " | ".join(tiles.map(func(t: Dictionary) -> String: return "%s%s: %s (%s)" % ["! " if t["warn"] else "", t["label"], t["value"], t["note"]])))
			report.append("setup: under it: « %s » | « %s » | « %s »" % [_setup_text("work in a folder on the Windows disk"), _setup_text("No .wslconfig"), _setup_text("One reading every")])
			await shot("setup")
			# the pointer on a bar: the box says the slice's time and every piece of the pile
			var piece: Array = dash._chart.pieces(34)[1]
			var over := InputEventMouseMotion.new()
			over.position = (piece[0] as Rect2).get_center()
			dash._chart._gui_input(over)
			await wait(0.2)
			report.append("setup: the pointer on a bar: slice %d, on « %s »" % [dash._chart.hover, dash.name_of(str(piece[1]["id"]))])
			await shot("setup-hover")
			dash._chart.hover = -1
			# the same page on a light theme and on the palest dark one: the hues have their own steps there
			var theme_was: String = AmTheme.current
			for t in ["paper", "morning"]:
				await main.set_theme_name(t)
				await wait(0.3)
				report.append("setup: on « %s »: the same dashboard is there: %s, light hues: %s" % [t, main.setup_dash == dash and dash.is_visible_in_tree(), AmTheme.is_light()])
				await shot("setup-" + t)
			await main.set_theme_name(theme_was)
			await wait(0.3)
			main.setup_range = "7d"
			dash.set_range("7d")
			main.setup_hist = _made_up_week(moment)
			dash.set_history(main.setup_hist)
			await wait(0.3)
			var week: Dictionary = HostView.stack(main.setup_hist, dash.slots)
			report.append("setup: a made-up week: %d slices, %d without reading | hues given: %d, sessions drawn together as others: %d | the axis ends at %s of %s" % [week["bars"].size(),
				week["bars"].filter(func(x: Variant) -> bool: return x == null).size(), dash.slots.values().filter(func(v: int) -> bool: return v >= 0).size(),
				dash.slots.values().filter(func(v: int) -> bool: return v == HostView.OTHER).size(), HostView.mem(float(week["top"])), HostView.mem(float(main.setup_hist["total"]))])
			await shot("setup-week")
			main.setup_range = "1h"
			dash.set_range("1h")
			main.setup_hist = _made_up_hour(moment)
			dash.set_history(main.setup_hist)
			main._save("host_range", "1h")
			# « Restart WSL… »: nothing is run before the word is typed; a wrong word runs nothing
			var ran := []
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				ran.append(" ".join(a.slice(0, 2)))
				return {"code": 0, "out": win if str(a[0]) == "powershell.exe" else doc}
			_find_button(main.content, "Restart WSL…").pressed.emit()
			await wait(0.4)
			report.append("setup: restart WSL asks first: « %s »" % str(main.confirm_dialog.dialog_text).replace("\n", " / "))
			await shot("setup-restart-wsl")
			main.confirm_dialog.hide()
			main.confirm_done.call()
			await wait(0.4)
			var asks: String = main.ask_dialog.title
			main.ask_dialog.hide()
			main.ask_done.call("yes")
			await wait(0.4)
			report.append("setup: then « %s »; a wrong word: commands run: %s | status line: « %s »" % [asks, ran.filter(func(c: String) -> bool: return c.begins_with("wsl.exe --")), main.status_label.text])
			_find_button(main.content, "Restart WSL…").pressed.emit()
			await wait(0.4)
			main.confirm_dialog.hide()
			main.confirm_done.call()
			await wait(0.4)
			main.ask_dialog.hide()
			main.ask_done.call("restart")
			await wait(0.2)
			while main.setup_restart != null or main.setup_thread != null:
				await process_frame
			await wait(0.5)
			report.append("setup: the word typed: commands run: %s | status line: « %s »" % [ran.filter(func(c: String) -> bool: return c.begins_with("wsl.exe --")), main.status_label.text])
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				return {"code": 0, "out": win if str(a[0]) == "powershell.exe" else doc}
			# tmux and git are missing: the page offers to install them, shows the command, and runs it in a terminal here.
			# A stand-in plays the package manager: nothing is installed on this display.
			var installed := [false]
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				return {"code": 0, "out": win if str(a[0]) == "powershell.exe" else (doc if installed[0] else doc.replace("tmux=/usr/bin/tmux|3.4", "tmux=|").replace("git=/usr/bin/git|2.43.0", "git=|"))}
			main.engine.connected = false
			main._setup_read()
			while main.setup_thread != null:
				await process_frame
			await wait(0.2)
			main._layout_view()
			await wait(0.2)
			report.append("setup: tmux and git missing: %s | offered: « %s » | shown: « %s »" % [_setup_marks(), _find_button(main.content, "Install tmux, git") != null, _setup_text("setup_install.sh")])
			await shot("setup-missing")
			main.setup_install_argv = func(packages: Array) -> Array:
				return ["bash", "-c", "echo '→ apt-get update'; sleep 0.6; echo 'Get:1 http://archive.ubuntu.com/ubuntu noble InRelease [256 kB]'; sleep 0.6; echo '→ apt-get install -y %s'; sleep 0.8; echo 'Setting up tmux (3.4-1ubuntu0.1) ...'; echo 'Setting up git (1:2.43.0-1ubuntu7.3) ...'; sleep 0.6; echo; echo 'Installed: %s'" % [" ".join(packages), " ".join(packages)]]
			main._layout_view()
			await wait(0.2)
			_find_button(main.content, "Install tmux, git").pressed.emit()
			await wait(1.6)
			var mid: String = main.setup_term.get_screen_text().strip_edges().replace("\n", " / ")
			report.append("setup: installing: the terminal is on the page: %s, running: %s | it shows: « %s »" % [main.setup_term.is_inside_tree() and main.setup_term.get_parent() != main.parking, main.setup_term.is_running(), mid.left(90)])
			await shot("setup-installing")
			installed[0] = true
			while main.setup_term.is_running():
				await process_frame
			await wait(0.6)
			while main.setup_thread != null:
				await process_frame
			await wait(1.0)
			report.append("setup: installed: %s | the terminal says: « %s » | status line: « %s » | engine answers: %s" % [_setup_marks(), str(main.setup_term.get_screen_text()).strip_edges().get_slice("\n", str(main.setup_term.get_screen_text()).strip_edges().get_slice_count("\n") - 1), main.status_label.text, main.engine.connected])
			_find_button(main.content, "Hide this terminal").pressed.emit()
			await wait(0.3)
			report.append("setup: the terminal hidden: %s" % (not is_instance_valid(main.setup_term)))
			main.setup_install_argv = Callable()
			# WSL is not installed: Windows answers, and nothing is asked of WSL
			var asked := []
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				asked.append(str(a[0]))
				return {"code": 0, "out": "#windows 0\nbuild=26100\nvirt_firmware=True\nhypervisor=False\nservice=False\n#end 0\n"}
			main.engine.connected = false
			await main._setup_check_again()
			await wait(0.2)
			report.append("setup: WSL missing: %s | asked: %s | « %s »" % [_setup_marks(), ", ".join(asked), _setup_text("wsl --install")])
			await shot("setup-no-wsl")
			# the engine is down (its process is gone, its port closed): « Check again » starts it
			main.setup_probe.runner = func(a: Array) -> Dictionary:
				var here: bool = main.engine.connected
				return {"code": 0, "out": win if str(a[0]) == "powershell.exe" else (doc if here else doc.replace("engine-process=4242|", "engine-process=|").replace("engine-port=open|", "engine-port=|"))}
			main._setup_read()
			while main.setup_thread != null:
				await process_frame
			await wait(0.2)
			report.append("setup: engine down: %s | « %s »" % [_setup_marks(), _setup_text("not running")])
			await shot("setup-engine-down")
			await main._setup_check_again()
			while main.setup_thread != null:
				await process_frame
			await wait(0.3)
			report.append("setup: after « Check again »: %s | status line: « %s » | engine answers: %s" % [_setup_marks(), main.status_label.text, main.engine.connected])
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
	d.whole = PackedByteArray()
	d.rest = PackedByteArray()
	d.closing = false
	d.capture.clear_buffer()  # as start() does: the silence the bus gave before the key went down is not part of it
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
func _say(seconds: float, pause := 0.9, loud := 0.2) -> void:
	var rate := AudioServer.get_mix_rate()
	for part in [[seconds, loud], [pause, 0.0]]:
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
		main._card(s).free()
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
	# the gestures on groups: how long until the list shows the change, and until the engine has confirmed it
	var first: String = ids[0]
	var home_group := str(main._session(first).get("grp", ""))
	var other := "Pixel Forge" if home_group != "Pixel Forge" else "Orbit API"
	var seen := []
	var done := []
	for target in [other, home_group, other, home_group]:
		var t2 := Time.get_ticks_usec()
		main.call("_move", first, target, 0)  # returns when it first waits: what is on screen then is what the owner sees at once
		seen.append(_ms(t2) if str(main._session(first).get("grp", "")) == target else -1.0)
		while str(main._session(first).get("grp", "")) != target or int(main.get("local_wait") if main.get("local_wait") != null else 0) > 0:
			await process_frame
		await process_frame
		done.append(_ms(t2))
	var gname := "Speed %d" % n
	var t3 := Time.get_ticks_usec()
	if main.has_method("_new_group"):
		main.call("_new_group", gname)
	else:
		main.engine.call("call_api", "POST", "/groups", {"name": gname})
	var g_seen := _ms(t3) if main.tree.any(func(g): return str(g["name"]) == gname) else -1.0
	if not main.has_method("_new_group"):
		await wait(0.3)
		await main.refresh()
	while not main.tree.any(func(g): return str(g["name"]) == gname):
		await process_frame
	var g_done := _ms(t3)
	# a group folded by a click on its header, after a refresh has brought new data (the row itself is kept)
	await main.refresh()
	await wait(0.3)
	var folds := []
	for turn in 4:
		var head: Button = null
		for row in main.rows:
			if row[0] == "group" and row[1] == "Acme Store":
				head = row[3]
		var was: bool = main._group("Acme Store")["folded"]
		var shown: int = main.rows.size()
		var t4 := Time.get_ticks_usec()
		head.pressed.emit()
		folds.append(_ms(t4) if main._group("Acme Store")["folded"] != was and main.rows.size() != shown else -1.0)
		while main.local_wait > 0 or main._group("Acme Store")["folded"] == was:
			await process_frame
		await main.refresh()
		await wait(0.2)
	report.append("      groups | a group folded or opened by a click: on screen after %s" % (("%.1f" % _med(folds)) if folds.min() >= 0.0 else "the engine's answer"))
	report.append("      groups | a session moved to another group: on screen after %s, confirmed after %.0f | a group created: on screen after %s, confirmed after %.0f" % [
		("%.1f" % _med(seen)) if _med(seen) >= 0.0 else "the engine's answer", _med(done), ("%.1f" % g_seen) if g_seen >= 0.0 else "the engine's answer", g_done])


## The top bar as it is: the « View » button, then each manager's button; a pressed one is in brackets.
func _bar() -> String:
	var o := []
	for b in [main.view_btn] + main.MANAGERS.map(func(m: Array) -> Button: return main.view_buttons[m[0]]):
		o.append(("[%s]" if (b as Button).button_pressed else "%s") % (b as Button).text)
	return "  ".join(o)


## The setup check as it is on screen: the marks of its lines in order, its last sentence, a line that holds a word.
func _setup_marks() -> String:
	var o := ""
	var line: Node = main.content.find_child("SetupMarks", true, false)  # all standing: one line of marks
	if line != null:
		for pair in line.get_children():
			o += (pair.get_child(0) as Label).text
		return o
	for g in main.content.find_children("*", "GridContainer", true, false):
		if (g as GridContainer).columns == 4:  # the ladder; the engine room's lines are in a grid of two
			for i in range(0, g.get_child_count(), 4):
				o += (g.get_child(i) as Label).text
	return o


func _setup_last() -> String:
	var labels: Array = main.content.find_children("*", "Label", true, false)
	return (labels[labels.size() - 1] as Label).text if labels.size() > 0 else ""


func _setup_text(part: String) -> String:
	for l in main.content.find_children("*", "Label", true, false):
		if (l as Label).text.contains(part):
			return (l as Label).text
	return ""


func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text:
			return n
	return null

## The engine's answer to /host for the pictures: five sessions of the fictional workspace at a made-up moment.
func _made_up_host(now: int) -> Dictionary:
	var gib := 1073741824
	var mib := 1048576
	return {"wsl": true, "distro": "Ubuntu-24.04", "now": float(now), "uptime": 26100.0, "load": 0.62, "processors": 16, "cpu": 0.07,
		"memory": {"total": 16 * gib, "available": 13.4 * gib, "used": 2.6 * gib, "held": 4.9 * gib, "swap_total": 4 * gib, "swap_used": 0},
		"disk": {"total": 1007 * gib, "free": 918 * gib}, "drives": [{"letter": "c", "total": 931 * gib, "free": 68 * gib}],
		"sessions": [
			{"id": "b", "name": "Flaky tests", "tool": "codex", "bytes": 612 * mib, "created": now - 24300, "activity": now - 4, "attached": 1, "drive": "c", "cpu": 0.41},
			{"id": "a", "name": "Checkout flow", "tool": "claude", "bytes": 548 * mib, "created": now - 25200, "activity": now - 95, "attached": 1, "drive": "c", "cpu": 0.06},
			{"id": "c", "name": "Rate limiter", "tool": "claude", "bytes": 402 * mib, "created": now - 2280, "activity": now - 610, "attached": 0, "drive": "", "cpu": 0.0},
			{"id": "d", "name": "Sparks", "tool": "claude", "bytes": 371 * mib, "created": now - 19800, "activity": now - 3900, "attached": 0, "drive": "", "cpu": 0.0}],
		"sessions_bytes": 1933 * mib, "on_windows_disk": [{"id": "a", "name": "Checkout flow", "drive": "c"}, {"id": "b", "name": "Flaky tests", "drive": "c"}],
		"engine": {"bytes": 31 * mib, "cpu": 0.0004}, "history": {"interval": 30, "keep": 604800, "since": now - 6 * 86400 - 7 * 3600, "readings": 9800, "error": ""}}


## One made-up series: `shape` gives the megabytes at a slice, or a negative figure where the session was not there.
func _made_up_series(id: String, name: String, n: int, read: Array, first: int, last: int, shape: Callable) -> Dictionary:
	var bytes := []
	var peak := 0.0
	for i in n:
		if not read[i]:
			bytes.append(null)
			continue
		var v := maxf(0.0, float(shape.call(i))) * 1048576.0
		bytes.append(v)
		peak = maxf(peak, v)
	return {"id": id, "name": name, "bytes": bytes, "cpu": [], "peak": peak * 1.06, "first": first, "last": last}


## What /host/history would answer, from made-up sessions: the slices that were read, what was in use (the sessions
## and about 650 MB beside them), the marks.
func _made_up_span(range_id: String, now: int, read: Array, sessions: Array, marks: Array) -> Dictionary:
	var r: Dictionary = HostView.range_of(range_id)
	var n: int = r["points"]
	var step: int = int(r["seconds"]) / n
	var b0 := (now - int(r["seconds"])) / step + 1
	var t := []
	var used := []
	var peak := []
	var cpu := []
	var counts := []
	var rng := RandomNumberGenerator.new()
	rng.seed = 36
	for i in n:
		t.append((b0 + i) * step)
		counts.append((step / 30) if read[i] else 0)
		if not read[i]:
			used.append(null)
			peak.append(null)
			cpu.append(null)
			continue
		var sum := (640.0 + 40.0 * sin(i * 0.31)) * 1048576.0
		for s in sessions:
			sum += float(s["bytes"][i])
		used.append(sum)
		peak.append(sum * (1.0 + 0.12 * rng.randf()))
		cpu.append(0.03 + 0.2 * rng.randf())
	return {"interval": 30, "keep": 604800, "step": step, "from": b0 * step, "to": now, "t": t, "readings": counts, "total": 16 * 1073741824,
		"used": used, "used_peak": peak, "held": used, "cpu": cpu, "load": cpu, "engine_bytes": [], "engine_cpu": [],
		"sessions": sessions, "marks": marks, "since": now - 6 * 86400 - 7 * 3600}


## A made-up hour: four sessions run, one of them started 38 minutes ago, one ran its tests a while (a bump), and
## « Docs refresh » ended 20 minutes ago.
func _made_up_hour(now: int) -> Dictionary:
	var n := 60
	var read := []
	read.resize(n)
	read.fill(true)
	var sessions := [
		_made_up_series("a", "Checkout flow", n, read, now - 25200, now, func(i: int) -> float: return 430.0 + i * 2.0 + 14.0 * sin(i * 0.7)),
		_made_up_series("b", "Flaky tests", n, read, now - 24300, now, func(i: int) -> float: return 410.0 + (520.0 * sin((i - 28) * PI / 12.0) if i >= 28 and i <= 40 else 0.0) + (200.0 if i > 52 else 0.0) + 10.0 * cos(i * 0.9)),
		_made_up_series("c", "Rate limiter", n, read, now - 2280, now, func(i: int) -> float: return (-1.0 if i < 22 else 300.0 + minf(100.0, (i - 22) * 9.0))),
		_made_up_series("d", "Sparks", n, read, now - 19800, now, func(i: int) -> float: return 368.0 + 6.0 * sin(i * 0.4)),
		_made_up_series("e", "Docs refresh", n, read, now - 9000, now - 1200, func(i: int) -> float: return (96.0 + 8.0 * sin(i * 0.5)) if i < 40 else -1.0)]
	return _made_up_span("1h", now, read, sessions, [])


## A made-up week, hour by hour: the computer is on from 8 to 19 on working days (elsewhere there is no reading,
## and WSL starts anew each morning); the four sessions of today were resumed each day; seven others came and went,
## so three of them are drawn together as « other sessions »; on Tuesday afternoon « Flaky tests » grew to 9 GB.
func _made_up_week(now: int) -> Dictionary:
	var n := 168
	var step := 3600
	var b0 := (now - 604800) / step + 1
	var read := []
	var marks := []
	var day_of := []  # for each slice: the day's number when it was read, -1 otherwise
	var was := false
	for i in n:
		var d := Time.get_datetime_dict_from_unix_time((b0 + i) * step)
		var on := int(d["weekday"]) >= 1 and int(d["weekday"]) <= 5 and int(d["hour"]) >= 8 and int(d["hour"]) < 19 and (b0 + i) * step <= now
		read.append(on)
		day_of.append(int(d["weekday"]) if on else -1)
		if on and not was:
			marks.append({"ts": (b0 + i) * step + 120, "kind": "boot"})
			marks.append({"ts": (b0 + i) * step + 180, "kind": "engine"})
		was = on
	var first := b0 * step
	var daily := func(base: float, days: Array, grow := 0.0) -> Callable:
		return func(i: int) -> float: return (base + grow * (i % 24) + 12.0 * sin(i * 0.8)) if day_of[i] in days else -1.0
	var sessions := [
		_made_up_series("a", "Checkout flow", n, read, first, now, daily.call(440.0, [1, 2, 3, 4, 5], 6.0)),
		_made_up_series("b", "Flaky tests", n, read, first, now, func(i: int) -> float:
			if day_of[i] < 0:
				return -1.0
			var hour := int(Time.get_datetime_dict_from_unix_time((b0 + i) * step)["hour"])
			return 420.0 + (1750.0 * (hour - 11) if day_of[i] == 2 and hour >= 12 and hour <= 16 else 0.0)),
		_made_up_series("c", "Rate limiter", n, read, now - 2280, now, daily.call(390.0, [4])),
		_made_up_series("d", "Sparks", n, read, first + 86400, now, daily.call(365.0, [2, 3, 4])),
		_made_up_series("e", "Docs refresh", n, read, first, now - 1200, daily.call(98.0, [1, 3, 4])),
		_made_up_series("f", "Login form", n, read, first + 3600, first + 2 * 86400, daily.call(510.0, [5, 1])),
		_made_up_series("g", "Image cache", n, read, first + 7200, first + 4 * 86400, daily.call(330.0, [5, 1, 2])),
		_made_up_series("h", "Billing export", n, read, first + 3 * 86400, first + 5 * 86400, daily.call(610.0, [1, 2])),
		_made_up_series("i", "Search index", n, read, first + 4 * 86400, first + 6 * 86400, daily.call(280.0, [2, 3])),
		_made_up_series("j", "Onboarding", n, read, first + 5 * 86400, first + 6 * 86400, daily.call(240.0, [3])),
		_made_up_series("k", "Changelog", n, read, first + 5 * 86400 + 3600, first + 6 * 86400, daily.call(120.0, [3]))]
	return _made_up_span("7d", now, read, sessions, marks)
