extends SceneTree
## Windows check (headless): keys and mouse reach VtTerminal (engine class bindings present).
var sent := PackedByteArray()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var t = ClassDB.instantiate("VtTerminal")
	t.size = Vector2(800, 400)
	t.font = TermFont.make()
	root.add_child(t)
	t.input_sent.connect(func(d: PackedByteArray) -> void: sent.append_array(d))
	t.start("cmd.exe", PackedStringArray(["/d", "/q"]), "", PackedStringArray())
	await create_timer(1.0).timeout
	t.grab_focus()
	var results := []
	for c in [[KEY_NONE, 0xE9, false, false, false, "c3a9"], [KEY_TAB, 0, false, false, true, "1b5b5a"], [KEY_E, 0x20AC, true, true, false, "e282ac"], [KEY_C, 0x63, true, false, false, "03"]]:
		sent.clear()
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.keycode = c[0]
		ev.physical_keycode = c[0]
		ev.unicode = c[1]
		ev.ctrl_pressed = c[2]
		ev.alt_pressed = c[3]
		ev.shift_pressed = c[4]
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
		await process_frame
		results.append("%s %s" % ["PASS" if sent.hex_encode() == c[5] else "FAIL", sent.hex_encode()])
	var m := InputEventMouseMotion.new()
	m.position = Vector2(50, 50)
	m.global_position = m.position
	Input.parse_input_event(m)
	Input.flush_buffered_events()
	await process_frame
	print("keys: ", results)
	quit()
