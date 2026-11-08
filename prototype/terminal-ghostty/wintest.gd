extends SceneTree
## Windows check without a window (--headless): VtTerminal through ConPTY. cmd, PowerShell, wsl.exe -> tmux.
var report: Array[String] = []
var exit_code := -999


func _initialize() -> void:
	_run.call_deferred()


func term() -> Control:
	var t = ClassDB.instantiate("VtTerminal")
	t.size = Vector2(1000, 600)
	root.add_child(t)
	return t


func wait_for(t: Control, needle: String, sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < sec * 1000:
		await process_frame
		if t.get_screen_text().contains(needle):
			return true
	return false


func check(name: String, ok: bool, detail: String = "") -> void:
	report.append("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _run() -> void:
	report.append("platform %s, VtTerminal %s" % [OS.get_name(), ClassDB.class_exists("VtTerminal")])
	# A: cmd output with accents and an emoji
	var a := term()
	check("start cmd", a.start("cmd.exe", PackedStringArray(["/d", "/c", "echo héllo ç — 😀 ok"]), "", PackedStringArray()))
	var ok_a := await wait_for(a, "ok", 5.0)
	check("cmd prints UTF-8 through ConPTY", ok_a and a.get_screen_text().contains("héllo ç — 😀"), "[%s]" % a.get_screen_text().strip_edges().left(60))
	a.queue_free()
	# B: PowerShell sees the terminal's width
	var b := term()
	b.start("powershell.exe", PackedStringArray(["-NoProfile", "-Command", "Write-Output ('width=' + $Host.UI.RawUI.WindowSize.Width + ' é ç « »')"]), "", PackedStringArray())
	var ok_b := await wait_for(b, "width=", 10.0)
	check("PowerShell: width and accents", ok_b and b.get_screen_text().contains("width=%d é ç « »" % b.get_cols()), "[%s] cols=%d" % [b.get_screen_text().strip_edges().left(60), b.get_cols()])
	b.queue_free()
	# C: typing into an interactive cmd
	var c := term()
	c.start("cmd.exe", PackedStringArray(["/d", "/q"]), "", PackedStringArray())
	await wait_for(c, ">", 5.0)
	c.write_input("echo tapé é ç\r".to_utf8_buffer())
	check("typed accents reach cmd and come back", await wait_for(c, "tapé é ç\n", 5.0) or await wait_for(c, "tapé é ç", 1.0), "")
	c.queue_free()
	# D: wsl.exe -> tmux: the path the app will use for persistent sessions
	var d := term()
	d.start("wsl.exe", PackedStringArray(["-e", "tmux", "-L", "agmgd-win", "-f", "/dev/null", "new-session", "-A", "-s", "w1"]), "", PackedStringArray())
	var ok_d := await wait_for(d, "$", 15.0)
	check("wsl.exe -> tmux starts", ok_d, "")
	d.write_input("clear; echo depuis WSL é ç 😀; echo cols=$(tput cols)\r".to_utf8_buffer())
	var ok_d2 := await wait_for(d, "cols=", 8.0)
	check("tmux in WSL: accents, emoji and width", ok_d2 and d.get_screen_text().contains("depuis WSL é ç 😀") and d.get_screen_text().contains("cols=%d" % d.get_cols()), "cols=%d [%s]" % [d.get_cols(), d.get_screen_text().strip_edges().left(80).replace("\n", " | ")])
	d.size = Vector2(600, 400)
	await create_timer(1.0).timeout
	d.write_input("clear; echo cols=$(tput cols)\r".to_utf8_buffer())
	await create_timer(1.5).timeout
	check("resize reaches tmux through ConPTY", d.get_screen_text().contains("cols=%d" % d.get_cols()), "cols=%d [%s]" % [d.get_cols(), d.get_screen_text().strip_edges().left(40)])
	d.queue_free()
	OS.execute("wsl.exe", ["-e", "tmux", "-L", "agmgd-win", "kill-server"])
	# E: exit code
	var e := term()
	e.exited.connect(func(code: int) -> void: exit_code = code)
	e.start("cmd.exe", PackedStringArray(["/d", "/c", "exit 3"]), "", PackedStringArray())
	var t0 := Time.get_ticks_msec()
	while exit_code == -999 and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	check("exit code comes back", exit_code == 3, "code=%d" % exit_code)
	var f := FileAccess.open("res://wintest-report.txt", FileAccess.WRITE)
	f.store_string("\n".join(report) + "\n")
	f.close()
	print("\n".join(report))
	quit()
