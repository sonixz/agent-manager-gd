extends SceneTree
## Terminal prototype bench (Loop 2): godot-xterm attached to tmux. BENCH_MODE = render | input | tui | perf.
## BENCH_OUT = folder for captures and the report. Runs on a virtual display; never opened on the desktop.

const SOCK := "agmgd-bench"
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


## The bundled mono font, then system fallbacks for symbols, CJK, Korean and emoji (read from the system, not shipped).
func make_font() -> Font:
	var main := FontFile.new()
	main.load_dynamic_font("res://addons/godot_xterm/themes/fonts/jet_brains_mono/jet_brains_mono_nl-regular-2.304.ttf")
	var fb: Array[Font] = []
	for path in ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/mnt/c/Windows/Fonts/seguisym.ttf",
			"/mnt/c/Windows/Fonts/YuGothR.ttc", "/mnt/c/Windows/Fonts/malgun.ttf", "/mnt/c/Windows/Fonts/seguiemj.ttf"]:
		if FileAccess.file_exists(path):
			var f := FontFile.new()
			if f.load_dynamic_font(path) == OK:
				fb.append(f)
	main.fallbacks = fb
	report.append("fonts: main + %d fallbacks" % fb.size())
	return main


func tmux(args: Array) -> String:
	var out := []
	OS.execute("tmux", ["-L", SOCK] + args, out, true)
	return "".join(out)


func make_term(name: String, rect: Rect2, cmd: String = "", cwd: String = "") -> Terminal:
	var t := Terminal.new()
	t.name = name
	t.position = rect.position
	t.size = rect.size
	for k in ["normal_font", "bold_font", "italics_font", "bold_italics_font"]:
		t.add_theme_font_override(k, font)
	for k in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		t.add_theme_font_size_override(k, 15)
	t.focus_mode = Control.FOCUS_ALL
	root.add_child(t)
	var p := PTY.new()
	p.use_os_env = true
	p.env = {"TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}
	t.add_child(p)
	received[name] = PackedByteArray()
	p.data_received.connect(func(d: PackedByteArray) -> void:
		t.write(d)
		received[name].append_array(d))
	t.data_sent.connect(func(d: PackedByteArray) -> void:
		sent.append_array(d)
		p.write(d))
	t.size_changed.connect(func(s: Vector2) -> void: p.resizev(s))
	await process_frame
	await process_frame
	var args := ["-L", SOCK, "-f", ProjectSettings.globalize_path("res://tools/tmux.conf"), "new-session", "-A", "-s", name]
	if cmd != "":
		args.append(cmd)
	p.fork("/usr/bin/tmux", args, cwd if cwd != "" else ProjectSettings.globalize_path("res://"), t.get_cols(), t.get_rows())
	t.set_meta("pty", p)
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


func _run(mode: String) -> void:
	tmux(["kill-server"])
	var full := Rect2(Vector2.ZERO, Vector2(root.size))
	match mode:
		"render":
			var t := await make_term("render", full)
			await wait(1.5)
			send("render", "clear; cat tools/sample.txt; python3 tools/colors.py")
			await wait(2.0)
			await shot("01-render")
			report.append("grid %dx%d cell %s" % [t.get_cols(), t.get_rows(), t.get_cell_size()])
		"input":
			await _input_test(await make_term("input", full))
		"tui":
			var trusted := OS.get_environment("BENCH_TRUSTED")
			var c := await make_term("claude", full, "claude", trusted)
			await wait(12.0)
			await shot("02-claude")
			c.grab_focus()
			for ch in "Écris « déjà vu » — ça marche ? 😀":
				key(c, 0, ch.unicode_at(0))
			await wait(1.5)
			await shot("02b-claude-typed")
			key(c, KEY_ESCAPE)
			key(c, KEY_ESCAPE)
			c.queue_free()
			tmux(["kill-session", "-t", "claude"])
			await wait(0.5)
			var x := await make_term("codex", full, "codex", trusted)
			await wait(12.0)
			await shot("03-codex")
		"perf":
			await _perf_test(full)
		"mouse":
			var t := await make_term("mouse", full)
			t.grab_focus()
			await wait(1.0)
			# tmux runs with mouse on: it asks the terminal for mouse reports (SGR 1006).
			var modes: String = received["mouse"].get_string_from_utf8()
			report.append("app asked: mouse=%s sgr=%s bracketed_paste=%s focus=%s" % [modes.contains("[?1000h") or modes.contains("[?1002h") or modes.contains("[?1003h"),
				modes.contains("[?1006h"), modes.contains("[?2004h"), modes.contains("[?1004h")])
			for spec in [["click", MOUSE_BUTTON_LEFT], ["wheel up", MOUSE_BUTTON_WHEEL_UP], ["right", MOUSE_BUTTON_RIGHT]]:
				sent.clear()
				var ev := InputEventMouseButton.new()
				ev.button_index = spec[1]
				ev.pressed = true
				ev.position = Vector2(200, 100)
				ev.global_position = ev.position
				t._on_gui_input(ev)
				var up := ev.duplicate() as InputEventMouseButton
				up.pressed = false
				t._on_gui_input(up)
				report.append("mouse %s -> %s" % [spec[0], sent.get_string_from_ascii().c_escape() if sent.size() > 0 else "(nothing sent)"])
			# resize: tmux must follow
			t.size = Vector2(800, 500)
			await wait(1.0)
			report.append("resize: terminal %dx%d, tmux says %s" % [t.get_cols(), t.get_rows(), tmux(["display", "-p", "-t", "mouse", "#{window_width}x#{window_height}"]).strip_edges()])
			await shot("06-resized")
		"baseline":
			var cr := ColorRect.new()
			cr.color = Color(0.2, 0.2, 0.2)
			cr.size = full.size
			root.add_child(cr)
			await wait(1.0)
			var n := 0
			var b0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - b0 < 4000:
				await process_frame
				n += 1
			report.append("baseline: empty scene %.1f fps on this display" % (n / 4.0))
			var one := await make_term("solo", full)
			await wait(1.0)
			n = 0
			b0 = Time.get_ticks_msec()
			while Time.get_ticks_msec() - b0 < 4000:
				await process_frame
				n += 1
			report.append("baseline: one idle terminal %.1f fps" % (n / 4.0))
	tmux(["kill-server"])
	var f := FileAccess.open(out_dir.path_join("report-%s.txt" % mode), FileAccess.WRITE)
	f.store_string("\n".join(report) + "\n")
	f.close()
	print("\n".join(report))
	quit()


func key(t: Terminal, keycode: int, unicode: int = 0, ctrl := false, alt := false, shift := false) -> PackedByteArray:
	sent.clear()
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.unicode = unicode
	ev.ctrl_pressed = ctrl
	ev.alt_pressed = alt
	ev.shift_pressed = shift
	t._on_gui_input(ev)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	t._on_gui_input(up)
	return sent.duplicate()


func _input_test(t: Terminal) -> void:
	t.grab_focus()
	await wait(1.0)
	send("input", "clear; cat -v")
	await wait(0.5)
	var cases := [
		["é", 0, 0xE9, false, false, false, "c3a9"], ["è", 0, 0xE8, false, false, false, "c3a8"],
		["ç", 0, 0xE7, false, false, false, "c3a7"], ["œ", 0, 0x153, false, false, false, "c593"],
		["«", 0, 0xAB, false, false, false, "c2ab"], ["—", 0, 0x2014, false, false, false, "e28094"],
		["€", 0, 0x20AC, false, false, false, "e282ac"], ["É (shift)", 0, 0xC9, false, false, true, "c389"],
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
	]
	var ok := 0
	for c in cases:
		var got := key(t, c[1], c[2], c[3], c[4], c[5]).hex_encode()
		var pass_: bool = got in str(c[6]).split("|")
		ok += int(pass_)
		report.append("%s %-12s got=%-14s want=%s" % ["PASS" if pass_ else "FAIL", c[0], got, c[6]])
	report.append("input: %d/%d" % [ok, cases.size()])
	await wait(0.5)
	await shot("04-input")


func _perf_test(full: Rect2) -> void:
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
	var p3: Terminal = ts[3]
	while Time.get_ticks_msec() - t0 < 6000:
		await process_frame
		frames += 1
		if frames % 30 == 0:
			received["p3"] = PackedByteArray()
			var k0 := Time.get_ticks_usec()
			key(p3, KEY_X, 0x78)
			while received["p3"].find(0x78) < 0 and Time.get_ticks_usec() - k0 < 500000:
				await process_frame
			lat.append((Time.get_ticks_usec() - k0) / 1000.0)
	var fps := frames / 6.0
	lat.sort()
	report.append("perf: 4 terminals, one streaming: %.1f fps (virtual display, software rendering)" % fps)
	if lat.size() > 0:
		report.append("key echo latency through tmux (ms): median %.1f, worst %.1f, n=%d" % [lat[lat.size() / 2], lat[-1], lat.size()])
	await shot("05-perf")
