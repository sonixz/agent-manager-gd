extends Control
## Agent Manager GD, Loop 3: sessions on the left, the selected session's live terminal on the right.
## Sessions live in tmux (through the engine): closing the app leaves them running; reopening attaches again.

const C_BG := Color("0e1116")
const C_PANEL := Color("151a21")
const C_PANEL_2 := Color("1c232c")
const C_BORDER := Color("2a3441")
const C_TEXT := Color("e6edf3")
const C_MUTED := Color("8b98a8")
const C_ACCENT := Color("7dd3a8")
const C_WARN := Color("f2c66d")
const C_ERROR := Color("f47c7c")
const STATE_COLOR := {"running": C_ACCENT, "exited": C_WARN, "missing": C_ERROR}
const ANSI := ["1c232c", "f47c7c", "7dd3a8", "f2c66d", "79b8ff", "d2a8ff", "56d4dd", "c9d1d9",
	"4b5563", "ff9b9b", "a6f0c6", "ffe08a", "a5d0ff", "e2c5ff", "8ee8ee", "f0f6fc"]

var engine: EngineClient
var font: Font
var sessions: Array = []
var tree: Array = []          # [{name, folded, sessions: [...]}], "" = no group
var tree_sig := ""
var row_menu: PopupMenu
var group_menu: PopupMenu
var move_menu: PopupMenu
var menu_target := ""         # session id or group name under the menu
var ask_dialog: ConfirmationDialog
var ask_edit: LineEdit
var ask_done: Callable
var f_group: OptionButton
var terms := {}          # session id -> VtTerminal
var selected := ""
var list_box: VBoxContainer
var term_host: Control
var header_name: Label
var header_state: Label
var empty_label: Label
var status_label: Label
var new_dialog: AcceptDialog
var f_name: LineEdit
var f_tool: OptionButton
var f_cwd: LineEdit


func _ready() -> void:
	theme = _make_theme()
	font = TermFont.make()
	_build()
	engine = EngineClient.new()
	add_child(engine)
	status_label.text = "Starting the engine…"
	if not await engine.connect_engine():
		status_label.text = "The engine did not start (python3 and tmux are needed%s)." % (" in WSL" if engine.on_windows else "")
		return
	status_label.text = "Engine ready"
	await refresh()
	if sessions.size() > 0:
		select(str(sessions[0]["id"]))
	var timer := Timer.new()
	timer.wait_time = 2.0
	timer.autostart = true
	timer.timeout.connect(refresh)
	add_child(timer)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and engine:
		engine.stop_engine()  # the sessions stay in tmux


# ------------------------------------------------------------------ layout
func _build() -> void:
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	var root := HBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	# sidebar
	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(280, 0)
	side.add_theme_stylebox_override("panel", _box(C_PANEL, 0, C_BORDER, 0))
	root.add_child(side)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 10)
	side.add_child(sv)
	var title := Label.new()
	title.text = "AGENT MANAGER GD"
	title.add_theme_color_override("font_color", C_ACCENT)
	title.add_theme_font_size_override("font_size", 13)
	sv.add_child(title)
	var new_btn := Button.new()
	new_btn.text = "+  New session"
	new_btn.pressed.connect(_open_new)
	new_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top.add_child(new_btn)
	var grp_btn := Button.new()
	grp_btn.text = "+ Group"
	grp_btn.tooltip_text = "A new group in the project tree"
	grp_btn.pressed.connect(func() -> void: _ask("New group", "", func(n: String) -> void:
		await engine.call_api("POST", "/groups", {"name": n})
		await refresh()))
	top.add_child(grp_btn)
	sv.add_child(top)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sv.add_child(scroll)
	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = SIZE_EXPAND_FILL
	list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(list_box)
	status_label = Label.new()
	status_label.add_theme_color_override("font_color", C_MUTED)
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sv.add_child(status_label)
	# main area
	var main := VBoxContainer.new()
	main.size_flags_horizontal = SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 0)
	root.add_child(main)
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", _box(C_PANEL_2, 0, C_BORDER, 0, 10))
	main.add_child(header)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	header.add_child(hb)
	header_name = Label.new()
	header_name.add_theme_font_size_override("font_size", 16)
	header_name.size_flags_horizontal = SIZE_EXPAND_FILL
	hb.add_child(header_name)
	header_state = Label.new()
	hb.add_child(header_state)
	for spec in [["Restart", _restart], ["Stop", _stop], ["Remove", _remove]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		hb.add_child(b)
	term_host = Control.new()
	var term_bg := ColorRect.new()
	term_bg.color = C_BG
	term_bg.set_anchors_preset(PRESET_FULL_RECT)
	term_host.add_child(term_bg)
	term_host.size_flags_vertical = SIZE_EXPAND_FILL
	term_host.clip_contents = true
	main.add_child(term_host)
	empty_label = Label.new()
	empty_label.text = "No session yet. Start one with « + New session »: Claude Code, Codex or a shell, in the folder you choose."
	empty_label.add_theme_color_override("font_color", C_MUTED)
	empty_label.set_anchors_preset(PRESET_CENTER)
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	term_host.add_child(empty_label)
	_build_new_dialog()
	_build_menus()


func _build_new_dialog() -> void:
	new_dialog = AcceptDialog.new()
	new_dialog.title = "New session"
	new_dialog.ok_button_text = "Start"
	add_child(new_dialog)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 10)
	new_dialog.add_child(g)
	g.add_child(_label("Name"))
	f_name = LineEdit.new()
	f_name.custom_minimum_size = Vector2(360, 0)
	f_name.placeholder_text = "for example: Brain themes"
	g.add_child(f_name)
	g.add_child(_label("Tool"))
	f_tool = OptionButton.new()
	for t in [["claude", "Claude Code"], ["codex", "Codex"], ["shell", "Shell"]]:
		f_tool.add_item(t[1])
		f_tool.set_item_metadata(f_tool.item_count - 1, t[0])
	g.add_child(f_tool)
	g.add_child(_label("Group"))
	f_group = OptionButton.new()
	g.add_child(f_group)
	g.add_child(_label("Folder"))
	f_cwd = LineEdit.new()
	f_cwd.text = "~"
	f_cwd.placeholder_text = "/mnt/c/git-2026/my-project" if engine == null or engine.on_windows else "~/my-project"
	g.add_child(f_cwd)
	new_dialog.confirmed.connect(_create)


func _open_new() -> void:
	f_name.text = ""
	f_group.clear()
	f_group.add_item("(no group)")
	f_group.set_item_metadata(0, "")
	for g in tree:
		if str(g["name"]) != "":
			f_group.add_item(str(g["name"]))
			f_group.set_item_metadata(f_group.item_count - 1, str(g["name"]))
	var cur := str(_session(selected).get("grp", ""))
	for i in f_group.item_count:
		if str(f_group.get_item_metadata(i)) == cur:
			f_group.select(i)
	new_dialog.popup_centered()
	f_name.grab_focus()


# ------------------------------------------------------------------ sessions
func refresh() -> void:
	var r := await engine.call_api("GET", "/tree")
	if r.has("error"):
		status_label.text = "Engine: " + str(r["error"])
		return
	tree = r["groups"]
	sessions = []
	for g in tree:
		sessions.append_array(g["sessions"])
	var sig := JSON.stringify(tree) + selected
	# rebuilding the rows during a drag would drop it; an unchanged tree needs no rebuild
	if sig != tree_sig and not get_viewport().gui_is_dragging():
		tree_sig = sig
		_render_list()
	_render_header()


func _render_list() -> void:
	for c in list_box.get_children():
		c.queue_free()
	for g in tree:
		var gname := str(g["name"])
		if gname != "" or tree.size() == 1 or not (g["sessions"] as Array).is_empty():
			if gname != "":
				list_box.add_child(_group_header(g))
		if bool(g["folded"]):
			continue
		var i := 0
		for s in g["sessions"]:
			list_box.add_child(_session_row(s, gname, i))
			i += 1
		if gname != "" and (g["sessions"] as Array).is_empty():
			var hint := Label.new()
			hint.text = "      drop a session here"
			hint.add_theme_color_override("font_color", C_MUTED)
			hint.add_theme_font_size_override("font_size", 12)
			list_box.add_child(hint)
	empty_label.visible = sessions.is_empty()


func _group_header(g: Dictionary) -> Button:
	var gname := str(g["name"])
	var b := Button.new()
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = "%s  %s   %d" % ["▸" if bool(g["folded"]) else "▾", gname.to_upper(), (g["sessions"] as Array).size()]
	b.add_theme_color_override("font_color", C_ACCENT)
	b.add_theme_color_override("font_hover_color", C_TEXT)
	b.add_theme_font_size_override("font_size", 12)
	b.tooltip_text = "Click to fold · drag to reorder · right click for more"
	b.pressed.connect(func() -> void:
		await engine.call_api("POST", "/groups/%s/fold" % gname.uri_encode(), {"folded": not bool(g["folded"])})
		await refresh())
	b.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			menu_target = gname
			group_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO)))
	b.set_drag_forwarding(
		func(_at: Vector2) -> Variant:
			var prev := Label.new()
			prev.text = gname
			b.set_drag_preview(prev)
			return {"type": "group", "name": gname},
		func(_at: Vector2, d: Variant) -> bool: return d is Dictionary and d.get("type") in ["group", "session"],
		func(_at: Vector2, d: Variant) -> void: _drop_on_group(gname, d))
	return b


func _session_row(s: Dictionary, gname: String, index: int) -> Button:
	var id := str(s["id"])
	var row := Button.new()
	row.toggle_mode = true
	row.button_pressed = id == selected
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.text = "     %s\n     %s · %s" % [s["name"], s["tool_label"], s["state"]]
	row.add_theme_color_override("font_color", C_TEXT)
	row.custom_minimum_size = Vector2(0, 52)
	row.tooltip_text = str(s["cwd"])
	row.pressed.connect(select.bind(id))
	row.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			menu_target = id
			row_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))
		elif e is InputEventMouseButton and e.double_click and e.button_index == MOUSE_BUTTON_LEFT:
			_rename_session(id))
	row.set_drag_forwarding(
		func(_at: Vector2) -> Variant:
			var prev := Label.new()
			prev.text = "  " + str(s["name"])
			row.set_drag_preview(prev)
			return {"type": "session", "id": id},
		func(_at: Vector2, d: Variant) -> bool: return d is Dictionary and d.get("type") == "session" and d.get("id") != id,
		func(at: Vector2, d: Variant) -> void:
			# dropped on the lower half: after this row
			_move(str(d["id"]), gname, index + (1 if at.y > row.size.y / 2 else 0)))
	var d := ColorRect.new()
	d.color = STATE_COLOR.get(s["state"], C_MUTED) as Color
	d.size = Vector2(8, 8)
	d.position = Vector2(14, 15)
	d.mouse_filter = MOUSE_FILTER_IGNORE
	row.add_child(d)
	return row


func _drop_on_group(gname: String, d: Dictionary) -> void:
	if d["type"] == "session":
		await _move(str(d["id"]), gname, 1 << 20)  # at the end of the group
	elif d["type"] == "group" and str(d["name"]) != gname:
		var names: Array = []
		for g in tree:
			if str(g["name"]) != "" and str(g["name"]) != str(d["name"]):
				names.append(str(g["name"]))
		names.insert(names.find(gname), str(d["name"]))  # before the group it was dropped on
		await engine.call_api("POST", "/groups/order", {"names": names})
		await refresh()


func _move(id: String, gname: String, index: int) -> void:
	# moving down inside the same group: the row itself leaves a gap above
	var cur := _session(id)
	if str(cur.get("grp", "")) == gname:
		for g in tree:
			if str(g["name"]) == gname:
				var at := (g["sessions"] as Array).map(func(x): return str(x["id"])).find(id)
				if at >= 0 and at < index:
					index -= 1
	var r := await engine.call_api("POST", "/sessions/%s/move" % id, {"group": gname, "index": index})
	if r.has("error"):
		status_label.text = str(r["error"])
	await refresh()


func _build_menus() -> void:
	row_menu = PopupMenu.new()
	row_menu.add_item("Rename…", 0)
	row_menu.add_submenu_node_item("Move to group", _make_move_menu(), 1)
	row_menu.add_separator()
	row_menu.add_item("Restart", 2)
	row_menu.add_item("Stop", 3)
	row_menu.add_item("Remove", 4)
	row_menu.id_pressed.connect(_on_row_menu)
	add_child(row_menu)
	group_menu = PopupMenu.new()
	group_menu.add_item("Rename group…", 0)
	group_menu.add_item("Delete group (its sessions stay)", 1)
	group_menu.id_pressed.connect(func(mid: int) -> void:
		var gname := menu_target
		if mid == 0:
			_ask("Rename group", gname, func(n: String) -> void:
				var r := await engine.call_api("POST", "/groups/%s/rename" % gname.uri_encode(), {"name": n})
				if r.has("error"):
					status_label.text = str(r["error"])
				await refresh())
		elif mid == 1:
			await engine.call_api("POST", "/groups/%s/delete" % gname.uri_encode(), {})
			await refresh())
	add_child(group_menu)
	ask_dialog = ConfirmationDialog.new()
	ask_edit = LineEdit.new()
	ask_edit.custom_minimum_size = Vector2(320, 0)
	ask_dialog.add_child(ask_edit)
	ask_dialog.confirmed.connect(func() -> void:
		var v := ask_edit.text.strip_edges()
		if v != "" and ask_done.is_valid():
			ask_done.call(v))
	ask_edit.text_submitted.connect(func(_t: String) -> void:
		ask_dialog.hide()
		ask_dialog.confirmed.emit())
	add_child(ask_dialog)


func _on_row_menu(mid: int) -> void:
	if mid == 0:
		_rename_session(menu_target)
		return
	if mid in [2, 3, 4]:
		selected = menu_target
	if mid == 2:
		_restart()
	elif mid == 3:
		_stop()
	elif mid == 4:
		_remove()


func _make_move_menu() -> PopupMenu:
	move_menu = PopupMenu.new()
	move_menu.about_to_popup.connect(func() -> void:
		move_menu.clear()
		move_menu.add_item("(no group)")
		move_menu.set_item_metadata(0, "")
		for g in tree:
			if str(g["name"]) != "":
				move_menu.add_item(str(g["name"]))
				move_menu.set_item_metadata(move_menu.item_count - 1, str(g["name"])))
	move_menu.index_pressed.connect(func(i: int) -> void: _move(menu_target, str(move_menu.get_item_metadata(i)), 1 << 20))
	return move_menu


func _ask(title: String, value: String, done: Callable) -> void:
	ask_dialog.title = title
	ask_edit.text = value
	ask_done = done
	ask_dialog.popup_centered()
	ask_edit.grab_focus()
	ask_edit.select_all()


func _rename_session(id: String) -> void:
	_ask("Rename session", str(_session(id).get("name", "")), func(n: String) -> void:
		var r := await engine.call_api("POST", "/sessions/%s/rename" % id, {"name": n})
		if r.has("error"):
			status_label.text = str(r["error"])
		await refresh())


func _session(id: String) -> Dictionary:
	for s in sessions:
		if str(s["id"]) == id:
			return s
	return {}


func _render_header() -> void:
	var s := _session(selected)
	header_name.text = str(s.get("name", "")) + ("   " + str(s.get("cwd", "")) if s else "")
	header_state.text = str(s.get("state", ""))
	header_state.add_theme_color_override("font_color", STATE_COLOR.get(s.get("state", ""), C_MUTED))


func select(id: String) -> void:
	selected = id
	for t in terms.values():
		t.visible = false
	if not terms.has(id) or not is_instance_valid(terms[id]) or not terms[id].is_running():
		await _attach(id)
	if terms.has(id):
		terms[id].visible = true
		terms[id].grab_focus()
	tree_sig = ""
	_render_list()
	_render_header()


func _attach(id: String) -> void:
	if terms.has(id) and is_instance_valid(terms[id]):
		terms[id].queue_free()
	var r := await engine.call_api("GET", "/sessions/%s/attach" % id)
	if r.has("error"):
		status_label.text = str(r["error"])
		return
	var t = ClassDB.instantiate("VtTerminal")
	t.set_anchors_preset(PRESET_FULL_RECT)
	t.offset_left = 10
	t.offset_top = 8
	t.offset_right = -6
	t.font = font
	t.font_size = 15
	t.background = C_BG
	t.foreground = C_TEXT
	var pal := PackedColorArray()
	for h in ANSI:
		pal.append(Color(h))
	t.palette = pal
	term_host.add_child(t)
	terms[id] = t
	await get_tree().process_frame
	var cmd: Array = engine.host_command(r["command"])
	t.start(cmd[0], PackedStringArray(cmd.slice(1)), "", PackedStringArray(["TERM=xterm-256color", "COLORTERM=truecolor"]))
	t.exited.connect(func(_c: int) -> void: refresh())


func _create() -> void:
	var name := f_name.text.strip_edges()
	if name == "":
		name = str(f_tool.get_item_text(f_tool.selected))
	var r := await engine.call_api("POST", "/sessions", {"name": name, "tool": f_tool.get_selected_metadata(), "cwd": f_cwd.text.strip_edges(), "group": str(f_group.get_selected_metadata()) if f_group.item_count > 0 else ""})
	if r.has("error"):
		status_label.text = "Not started: " + str(r["error"])
		return
	await refresh()
	select(str(r["id"]))


func _restart() -> void:
	if selected == "":
		return
	await engine.call_api("POST", "/sessions/%s/restart" % selected)
	await refresh()
	await _attach(selected)
	select(selected)


func _stop() -> void:
	if selected == "":
		return
	await engine.call_api("POST", "/sessions/%s/stop" % selected)
	await refresh()


func _remove() -> void:
	if selected == "":
		return
	await engine.call_api("DELETE", "/sessions/%s" % selected)
	if terms.has(selected):
		terms[selected].queue_free()
		terms.erase(selected)
	selected = ""
	await refresh()
	if sessions.size() > 0:
		select(str(sessions[0]["id"]))


# ------------------------------------------------------------------ look
func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", C_MUTED)
	return l


func _box(c: Color, radius: int, border: Color, bw: int, pad := 14) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_content_margin_all(pad)
	return s


func _make_theme() -> Theme:
	var t := Theme.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Segoe UI Variable Text", "Segoe UI", "Inter", "Ubuntu", "DejaVu Sans"])
	t.default_font = f
	t.default_font_size = 14
	t.set_color("font_color", "Label", C_TEXT)
	t.set_stylebox("normal", "Button", _box(C_PANEL_2, 8, C_BORDER, 1, 10))
	t.set_stylebox("hover", "Button", _box(C_PANEL_2.lightened(0.05), 8, C_ACCENT.darkened(0.3), 1, 10))
	t.set_stylebox("pressed", "Button", _box(C_PANEL_2.lightened(0.08), 8, C_ACCENT, 1, 10))
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), 8, C_ACCENT.darkened(0.2), 1, 10))
	for c in ["font_color", "font_pressed_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(c, "Button", C_TEXT)
	t.set_stylebox("normal", "LineEdit", _box(C_BG, 6, C_BORDER, 1, 8))
	t.set_stylebox("focus", "LineEdit", _box(C_BG, 6, C_ACCENT, 1, 8))
	t.set_color("font_color", "LineEdit", C_TEXT)
	t.set_stylebox("normal", "OptionButton", _box(C_PANEL_2, 6, C_BORDER, 1, 8))
	t.set_stylebox("panel", "AcceptDialog", _box(C_PANEL, 10, C_BORDER, 1, 16))
	t.set_stylebox("panel", "PopupMenu", _box(C_PANEL_2, 6, C_BORDER, 1, 6))
	return t
