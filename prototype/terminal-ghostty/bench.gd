extends SceneTree
## Terminal bench, round 2: VtTerminal (libghostty-vt + our renderer) attached to tmux.
## BENCH_MODE = render | input | tui | mouse | perf | baseline. BENCH_OUT = captures and report.

const SOCK := "agmgd-bench2"
var out_dir := ""
var report: Array[String] = []
var sent := PackedByteArray()
var received := {}
var font: Font


func _initialize() -> void:
	out_dir = OS.get_environment("BENCH_OUT")
	DirAccess.make_dir_recursive_absolute(out_dir)
	font = make_font()
	_run.call_deferred(OS.get_environment("BENCH_MODE"))


func make_font() -> Font:
	var main := FontFile.new()
	main.load_dynamic_font("res://../terminal/addons/godot_xterm/themes/fonts/jet_brains_mono/jet_brains_mono_nl-regular-2.304.ttf")
	var fb: Array[Font] = []
	for path in ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/mnt/c/Windows/Fonts/seguisym.ttf",
			"/mnt/c/Windows/Fonts/YuGothR.ttc", "/mnt/c/Windows/Fonts/malgun.ttf", "/mnt/c/Windows/Fonts/seguiemj.ttf"]:
		if FileAccess.file_exists(path):
			var f := FontFile.new()
			if f.load_dynamic_font(path) == OK:
				fb.append(f)
	main.fallbacks = fb
	return main


func tmux(args: Array) -> String:
	var out := []
	OS.execute("tmux", ["-L", SOCK] + args, out, true)
	return "".join(out)


func make_term(name: String, rect: Rect2, cmd: String = "", cwd: String = "") -> Control:
	var t = ClassDB.instantiate("VtTerminal")
	t.name = name
	t.position = rect.position
	t.size = rect.size
	t.font = font
	t.font_size = 15
	root.add_child(t)
	received[name] = 0
	t.input_sent.connect(func(d: PackedByteArray) -> void: sent.append_array(d))
	t.output_received.connect(func(n: int) -> void: received[name] += n)
	await process_frame
	var args := ["-L", SOCK, "-f", ProjectSettings.globalize_path("res://tools/tmux.conf"), "new-session", "-A", "-s", name]
	if cmd != "":
		args.append(cmd)
	var ok: bool = t.start("/usr/bin/tmux", PackedStringArray(args), cwd if cwd != "" else ProjectSettings.globalize_path("res://"),
		PackedStringArray(["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=C.UTF-8", "LC_ALL=C.UTF-8"]))
	report.append("%s started=%s grid %dx%d cell %s" % [name, ok, t.get_cols(), t.get_rows(), t.get_cell_size()])
	return t


func wait(sec: float) -> void:
	await create_timer(sec).timeout


func shot(name: String) -> void:
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	report.append("capture " + name)


func send(name: String, text: String) -> void:
	tmux(["send-keys", "-t", name, "-l", text])
	tmux(["send-keys", "-t", name, "Enter"])


func key(t: Control, keycode: int, unicode: int = 0, ctrl := false, alt := false, shift := false) -> PackedByteArray:
	sent.clear()
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.key_label = keycode
	ev.unicode = unicode
	ev.ctrl_pressed = ctrl
	ev.alt_pressed = alt
	ev.shift_pressed = shift
	Input.parse_input_event(ev)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	return sent.duplicate()


func _run(mode: String) -> void:
	tmux(["kill-server"])
	var full := Rect2(Vector2.ZERO, Vector2(root.size))
	match mode:
		"render":
			await make_term("render", full)
			await wait(1.5)
			send("render", "clear; cat tools/sample.txt; python3 tools/colors.py; printf '\\e[4:3mcurly\\e[0m \\e[21mdouble\\e[0m \\e[53moverline\\e[0m\\n'; printf '┌──┬──┐\\n│ab│cd│\\n├──┼──┤\\n╰──┴──╯ ═══ ║ ▁▂▃▄▅▆▇█\\n'")
			await wait(2.0)
			await shot("01-render")
		"input":
			var t = await make_term("input", full)
			t.grab_focus()
			await wait(1.0)
			send("input", "clear; cat -v")
			await wait(0.5)
			await _input_cases(t)
			await wait(0.5)
			await shot("04-input")
		"tui":
			var trusted := OS.get_environment("BENCH_TRUSTED")
			var c = await make_term("claude", full, "claude", trusted)
			c.grab_focus()
			await wait(12.0)
			await shot("02-claude")
			for ch in "Écris « déjà vu » — ça marche ? 😀":
				key(c, 0, ch.unicode_at(0))
			key(c, KEY_TAB, 0, false, false, true)  # Shift+Tab: Claude Code changes mode
			await wait(1.5)
			await shot("02b-claude-typed")
			key(c, KEY_ESCAPE)
			key(c, KEY_ESCAPE)
			c.queue_free()
			tmux(["kill-session", "-t", "claude"])
			await wait(0.5)
			var x = await make_term("codex", full, "codex", trusted)
			await wait(12.0)
			await shot("03-codex")
		"mouse":
			var t = await make_term("mouse", full)
			t.grab_focus()
			await wait(1.0)
			send("mouse", "clear; seq 1 300")
			await wait(0.8)
			for spec in [["click", MOUSE_BUTTON_LEFT], ["wheel up", MOUSE_BUTTON_WHEEL_UP], ["right", MOUSE_BUTTON_RIGHT]]:
				sent.clear()
				var ev := InputEventMouseButton.new()
				ev.button_index = spec[1]
				ev.pressed = true
				ev.position = Vector2(205, 105)
				ev.global_position = ev.position
				Input.parse_input_event(ev)
				var up := ev.duplicate() as InputEventMouseButton
				up.pressed = false
				Input.parse_input_event(up)
				Input.flush_buffered_events()
				await process_frame
				report.append("mouse %s -> %s" % [spec[0], sent.get_string_from_ascii().c_escape() if sent.size() > 0 else "(nothing sent)"])
			await wait(0.5)
			await shot("06a-wheel-scrolled-in-tmux")
			key(t, KEY_Q)
			# bracketed paste: bash enables it; a 3-line paste must arrive wrapped
			send("mouse", "clear")
			await wait(0.5)
			sent.clear()
			t.paste_text("echo one\necho two\necho three")
			report.append("paste -> %s" % sent.get_string_from_utf8().c_escape())
			await wait(0.5)
			key(t, KEY_C, 0x63, true)
			t.size = Vector2(800, 500)
			await wait(1.0)
			report.append("resize: terminal %dx%d, tmux says %s" % [t.get_cols(), t.get_rows(), tmux(["display", "-p", "-t", "mouse", "#{window_width}x#{window_height}"]).strip_edges()])
			await shot("06-resized")
		"perf":
			await _perf(full)
		"theme":
			# The Brain's Neon and Terminal themes: background, text and the 16 ANSI colours come from the theme.
			var half := Rect2(Vector2.ZERO, Vector2(full.size.x, full.size.y / 2 - 2))
			var neon = await make_term("neon", half)
			neon.background = Color("150f24")
			neon.foreground = Color("f5eeff")
			neon.palette = PackedColorArray([Color("1f1734"), Color("ff6b8b"), Color("6fe6a0"), Color("ffd166"), Color("6fa8ff"), Color("ff5fc8"), Color("48e5ff"), Color("c3b2e3"),
				Color("4a3577"), Color("ff8fa8"), Color("9dffc4"), Color("ffe199"), Color("9cc4ff"), Color("ffb3e6"), Color("8ff0ff"), Color("f5eeff")])
			var termi = await make_term("termi", Rect2(Vector2(0, full.size.y / 2 + 2), half.size))
			termi.background = Color("0a0e0b")
			termi.foreground = Color("d4f5dc")
			termi.palette = PackedColorArray([Color("101813"), Color("ff7070"), Color("7dfa9b"), Color("ffb454"), Color("74d4ff"), Color("c39bff"), Color("5fe0c0"), Color("8fb79b"),
				Color("2a4233"), Color("ff9a9a"), Color("c2ffd1"), Color("ffcc66"), Color("a6e4ff"), Color("dcc4ff"), Color("9ff5e0"), Color("d4f5dc")])
			await wait(1.5)
			for n in ["neon", "termi"]:
				send(n, "clear; cat tools/sample.txt; for i in 0 1 2 3 4 5 6 7; do printf '\\e[4%sm  \\e[10%sm  ' $i $i; done; printf '\\e[0m\\n'; ls --color=always /usr/bin | head -3")
			await wait(2.0)
			await shot("07-themes")
		"baseline":
			var t = await make_term("solo", full)
			await wait(1.5)
			var n := 0
			var d0: int = t.get_draw_count()
			var b0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - b0 < 4000:
				await process_frame
				n += 1
			report.append("baseline: one idle terminal %.1f fps, %d redraws in 4 s (cursor blink only)" % [n / 4.0, t.get_draw_count() - d0])
	tmux(["kill-server"])
	var f := FileAccess.open(out_dir.path_join("report-%s.txt" % mode), FileAccess.WRITE)
	f.store_string("\n".join(report) + "\n")
	f.close()
	print("\n".join(report))
	quit()


func _input_cases(t: Control) -> void:
	var cases := [
		["é", 0, 0xE9, false, false, false, "c3a9"], ["è", 0, 0xE8, false, false, false, "c3a8"],
		["ç", 0, 0xE7, false, false, false, "c3a7"], ["œ", 0, 0x153, false, false, false, "c593"],
		["«", 0, 0xAB, false, false, false, "c2ab"], ["—", 0, 0x2014, false, false, false, "e28094"],
		["€ (AltGr)", KEY_E, 0x20AC, true, true, false, "e282ac"], ["É (shift)", 0, 0xC9, false, false, true, "c389"],
		["emoji 😀", 0, 0x1F600, false, false, false, "f09f9880"],
		["a", KEY_A, 0x61, false, false, false, "61"],
		["Enter", KEY_ENTER, 0, false, false, false, "0d"], ["Tab", KEY_TAB, 0, false, false, false, "09"],
		["Shift+Tab", KEY_TAB, 0, false, false, true, "1b5b5a"], ["Backspace", KEY_BACKSPACE, 0, false, false, false, "7f"],
		["Esc", KEY_ESCAPE, 0, false, false, false, "1b"], ["Ctrl+C", KEY_C, 0x63, true, false, false, "03"],
		["Ctrl+D", KEY_D, 0x64, true, false, false, "04"], ["Ctrl+R", KEY_R, 0x72, true, false, false, "12"],
		["Alt+b", KEY_B, 0x62, false, true, false, "1b62"],
		["Up", KEY_UP, 0, false, false, false, "1b5b41|1b4f41"], ["Down", KEY_DOWN, 0, false, false, false, "1b5b42|1b4f42"],
		["Right", KEY_RIGHT, 0, false, false, false, "1b5b43|1b4f43"], ["Left", KEY_LEFT, 0, false, false, false, "1b5b44|1b4f44"],
		["Home", KEY_HOME, 0, false, false, false, "1b5b48|1b4f48|1b5b317e"], ["End", KEY_END, 0, false, false, false, "1b5b46|1b4f46|1b5b347e"],
		["PgUp", KEY_PAGEUP, 0, false, false, false, "1b5b357e"], ["PgDn", KEY_PAGEDOWN, 0, false, false, false, "1b5b367e"],
		["Delete", KEY_DELETE, 0, false, false, false, "1b5b337e"],
		["Ctrl+Left", KEY_LEFT, 0, true, false, false, "1b5b313b3544"], ["F1", KEY_F1, 0, false, false, false, "1b4f50"],
		["Shift+Enter", KEY_ENTER, 0, false, false, true, "0d|1b5b31333b3275|1b0d|1b5b32373b323b31337e"],
	]
	var ok := 0
	for c in cases:
		var got := key(t, c[1], c[2], c[3], c[4], c[5]).hex_encode()
		var pass_: bool = got in str(c[6]).split("|")
		ok += int(pass_)
		report.append("%s %-12s got=%-14s want=%s" % ["PASS" if pass_ else "FAIL", c[0], got, c[6]])
	report.append("input: %d/%d" % [ok, cases.size()])


func _perf(full: Rect2) -> void:
	var half := full.size / 2
	var ts := []
	for i in 4:
		var r := Rect2(Vector2(i % 2, i / 2) * half, half - Vector2(4, 4))
		ts.append(await make_term("p%d" % i, r))
	await wait(1.5)
	send("p3", "cat")
	send("p0", "python3 tools/stream.py 6")
	send("p1", "python3 tools/colors.py; cat tools/sample.txt")
	send("p2", "seq 1 20000 | tail -n 30")
	var frames := 0
	var t0 := Time.get_ticks_msec()
	var lat: Array[float] = []
	var draw_ms: Array[float] = []
	var p3 = ts[3]
	p3.grab_focus()
	while Time.get_ticks_msec() - t0 < 6000:
		await process_frame
		frames += 1
		draw_ms.append(ts[0].get_last_draw_ms())
		if frames % 20 == 0:
			var before: int = received["p3"]
			var k0 := Time.get_ticks_usec()
			key(p3, KEY_X, 0x78)
			while received["p3"] == before and Time.get_ticks_usec() - k0 < 500000:
				await process_frame
			lat.append((Time.get_ticks_usec() - k0) / 1000.0)
	lat.sort()
	draw_ms.sort()
	report.append("perf: 4 terminals, one streaming: %.1f fps (virtual display, software rendering)" % (frames / 6.0))
	report.append("streaming terminal draw time (ms): median %.2f, p95 %.2f" % [draw_ms[draw_ms.size() / 2], draw_ms[int(draw_ms.size() * 0.95)]])
	if lat.size() > 0:
		report.append("key -> echo back through tmux, frame-quantised (ms): median %.1f, worst %.1f, n=%d" % [lat[lat.size() / 2], lat[-1], lat.size()])
	await shot("05-perf")
