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
			main.voice_label.text = "🎙  Listening to you for « Checkout flow »…  release F8 to write it"
			main.voice_meter.value = 0.62
			main.voice_overlay.visible = true
			main.voice_overlay.reset_size()
			await wait(0.6)
			await shot("voice")
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
			main.voice_label.text = "🎙  Listening to you for « Checkout flow »…  release F8 to write it"
			main.voice_meter.value = 0.58
			main.voice_overlay.visible = true
			main.voice_overlay.reset_size()
			await wait(0.6)
			await hshot(g, 2)
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


func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text:
			return n
	return null
