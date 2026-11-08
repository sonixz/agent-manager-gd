extends Control
## Agent Manager GD. Sidebar: waiting queue + project tree of live session cards. Main area: three views of the
## sessions' real terminals: Focus (one), Grid (up to four side by side), Board (tiles with live previews).
## Sessions live in tmux through the engine: closing the app leaves them running; reopening attaches again.

const SETTINGS := "user://settings.cfg"
const ACT_KEYS := ["working", "approval", "waiting", "done", "idle", "exited", "missing"]

var engine: EngineClient
var font: Font
var sessions: Array = []
var tree: Array = []          # [{name, folded, sessions}], "" = no group
var tree_sig := ""
var terms := {}               # session id -> VtTerminal (kept alive while hidden)
var selected := ""
var view := "focus"
var grid_ids: Array = []      # sessions shown in the grid, selected first
var last_activity := {}
var cards := {}               # id -> SessionCard

var side_box: VBoxContainer
var queue_box: VBoxContainer
var list_box: VBoxContainer
var status_label: Label
var header_name: Label
var header_meta: Label
var header_state: Label
var view_buttons := {}
var content: Control
var parking: Control          # hidden home of terminals not on screen
var empty_label: Label
var toast: PanelContainer
var toast_label: Label
var new_dialog: AcceptDialog
var f_name: LineEdit
var f_tool: OptionButton
var f_group: OptionButton
var f_cwd: LineEdit
var row_menu: PopupMenu
var group_menu: PopupMenu
var move_menu: PopupMenu
var theme_menu: PopupMenu
var menu_target := ""
var ask_dialog: ConfirmationDialog
var ask_edit: LineEdit
var ask_done: Callable
var palette: CommandPalette
var bg_rect: ColorRect
var board_previews := {}      # id -> Label (Board view)
var f_worktree: CheckBox
var f_brain: CheckBox
var brain_ok := false
var history_search: LineEdit
var history_list: VBoxContainer
var finish_dialog: ConfirmationDialog
var finish_info: Label
var finish_merge: CheckBox
var finish_delete: CheckBox


func activity_of(s: Dictionary) -> Array:
	var a := str(s.get("activity", s.get("state", "")))
	match a:
		"working": return [AmTheme.col("INFO"), "working"]
		"approval": return [approval_color(), "waits for your OK"]
		"waiting": return [AmTheme.col("WARN"), "waits for an answer"]
		"done": return [AmTheme.col("MINT") if not AmTheme.is_light() else AmTheme.col("FOREST_LIGHT"), "done"]
		"idle": return [AmTheme.col("FAINT"), "ready"]
		"exited": return [AmTheme.col("WARM").darkened(0.2), "ended"]
		"missing": return [AmTheme.col("ERROR"), "gone · Restart brings it back"]
	return [AmTheme.col("MUTED"), a]


func approval_color() -> Color:
	return Color("b4521a") if AmTheme.is_light() else Color("ff9e64")


func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	AmTheme.apply(str(cfg.get_value("ui", "theme", OS.get_environment("AGMGD_THEME") if OS.get_environment("AGMGD_THEME") != "" else "focus")))
	view = str(cfg.get_value("ui", "view", "focus"))
	theme = AmTheme.build()
	font = TermFont.make()
	_build()
	engine = EngineClient.new()
	add_child(engine)
	status_label.text = "Starting the engine…"
	if not await engine.connect_engine():
		status_label.text = "The engine did not start (python3 and tmux are needed%s)." % (" in WSL" if engine.on_windows else "")
		return
	var b := await engine.call_api("GET", "/brain")
	brain_ok = bool(b.get("connected", false))
	status_label.text = ("✦ Second Brain connected" if brain_ok else "Second Brain: " + str(b.get("reason", "not connected"))) + " · Ctrl+Shift+K for commands"
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


# ------------------------------------------------------------------ shortcuts
func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	var k := e as InputEventKey
	var in_terminal := get_viewport().gui_get_focus_owner() != null and get_viewport().gui_get_focus_owner().is_class("VtTerminal")
	if k.ctrl_pressed and (k.shift_pressed or not in_terminal):
		var handled := true
		match k.keycode:
			KEY_K: open_palette()
			KEY_N: _open_new()
			KEY_F: set_view("focus")
			KEY_G: set_view("grid")
			KEY_B: set_view("board")
			KEY_H: set_view("history")
			KEY_DOWN: _step(1)
			KEY_UP: _step(-1)
			KEY_A: _approve_first()
			_: handled = false
		if handled:
			get_viewport().set_input_as_handled()


func _step(d: int) -> void:
	if sessions.is_empty():
		return
	var ids := sessions.map(func(x): return str(x["id"]))
	var i := ids.find(selected)
	select(ids[(i + d + ids.size()) % ids.size()])


func _approve_first() -> void:
	for x in sessions:
		if str(x.get("activity", "")) == "approval":
			await _keys(str(x["id"]), ["Enter"])
			return


# ------------------------------------------------------------------ layout
func _build() -> void:
	bg_rect = ColorRect.new()
	bg_rect.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg_rect)
	var root := HBoxContainer.new()
	root.name = "Root"
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	var side := PanelContainer.new()
	side.name = "Side"
	side.custom_minimum_size = Vector2(312, 0)
	root.add_child(side)
	side_box = VBoxContainer.new()
	side_box.add_theme_constant_override("separation", 10)
	side.add_child(side_box)
	var brand := HBoxContainer.new()
	side_box.add_child(brand)
	var logo := Label.new()
	logo.name = "Logo"
	logo.text = "◆ AGENT MANAGER"
	logo.add_theme_font_size_override("font_size", 13)
	logo.size_flags_horizontal = SIZE_EXPAND_FILL
	brand.add_child(logo)
	var gd := Label.new()
	gd.name = "Gd"
	gd.text = "GD"
	gd.add_theme_font_size_override("font_size", 13)
	brand.add_child(gd)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	side_box.add_child(top)
	var new_btn := Button.new()
	new_btn.text = "+  New session"
	new_btn.tooltip_text = "Ctrl+Shift+N"
	new_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	new_btn.pressed.connect(_open_new)
	top.add_child(new_btn)
	var grp_btn := Button.new()
	grp_btn.text = "+ Group"
	grp_btn.pressed.connect(func() -> void: _ask("New group", "", func(n: String) -> void:
		await engine.call_api("POST", "/groups", {"name": n})
		await refresh()))
	top.add_child(grp_btn)
	queue_box = VBoxContainer.new()
	queue_box.add_theme_constant_override("separation", 6)
	side_box.add_child(queue_box)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side_box.add_child(scroll)
	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = SIZE_EXPAND_FILL
	list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(list_box)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 11)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_box.add_child(status_label)
	# main area: header + content
	var main := VBoxContainer.new()
	main.name = "MainCol"
	main.size_flags_horizontal = SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 0)
	root.add_child(main)
	var header := PanelContainer.new()
	header.name = "Header"
	main.add_child(header)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	header.add_child(hb)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	hb.add_child(titles)
	header_name = Label.new()
	header_name.add_theme_font_size_override("font_size", 17)
	header_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	titles.add_child(header_name)
	header_meta = Label.new()
	header_meta.add_theme_font_size_override("font_size", 12)
	header_meta.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	titles.add_child(header_meta)
	header_state = Label.new()
	header_state.add_theme_font_size_override("font_size", 13)
	hb.add_child(header_state)
	var seg := HBoxContainer.new()
	seg.add_theme_constant_override("separation", 0)
	hb.add_child(seg)
	for v in [["focus", "Focus", "Ctrl+Shift+F"], ["grid", "Grid", "Ctrl+Shift+G"], ["board", "Board", "Ctrl+Shift+B"], ["history", "History", "Ctrl+Shift+H"]]:
		var b := Button.new()
		b.text = v[1]
		b.tooltip_text = v[2]
		b.toggle_mode = true
		b.pressed.connect(set_view.bind(v[0]))
		seg.add_child(b)
		view_buttons[v[0]] = b
	var resume_btn := Button.new()
	resume_btn.name = "ResumeBtn"
	resume_btn.text = "↻ Resume"
	resume_btn.tooltip_text = "Start it again on its own conversation"
	resume_btn.visible = false
	resume_btn.pressed.connect(func() -> void: _resume(selected, ""))
	hb.add_child(resume_btn)
	var theme_btn := Button.new()
	theme_btn.text = "◐"
	theme_btn.tooltip_text = "Theme"
	theme_btn.pressed.connect(func() -> void: theme_menu.popup(Rect2i(Vector2i(theme_btn.get_screen_position() + Vector2(0, theme_btn.size.y)), Vector2i.ZERO)))
	hb.add_child(theme_btn)
	var more := Button.new()
	more.text = "⋯"
	more.tooltip_text = "Restart, stop, remove…"
	more.pressed.connect(func() -> void:
		menu_target = selected
		row_menu.popup(Rect2i(Vector2i(more.get_screen_position() + Vector2(0, more.size.y)), Vector2i.ZERO)))
	hb.add_child(more)
	var area := Control.new()
	area.size_flags_vertical = SIZE_EXPAND_FILL
	area.clip_contents = true
	main.add_child(area)
	content = MarginContainer.new()
	content.set_anchors_preset(PRESET_FULL_RECT)
	for side_name in ["left", "right", "top", "bottom"]:
		content.add_theme_constant_override("margin_" + side_name, 10)
	area.add_child(content)
	parking = Control.new()
	parking.visible = false
	area.add_child(parking)
	empty_label = Label.new()
	empty_label.text = "No session yet.\nStart one with « + New session »: Claude Code, Codex or a shell, in the folder you choose."
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.set_anchors_preset(PRESET_CENTER)
	empty_label.grow_horizontal = GROW_DIRECTION_BOTH
	area.add_child(empty_label)
	toast = PanelContainer.new()
	toast.set_anchors_preset(PRESET_BOTTOM_RIGHT)
	toast.grow_horizontal = GROW_DIRECTION_BEGIN
	toast.grow_vertical = GROW_DIRECTION_BEGIN
	toast.position = Vector2(-24, -24)
	toast.visible = false
	toast_label = Label.new()
	toast.add_child(toast_label)
	area.add_child(toast)
	_build_new_dialog()
	_build_menus()
	palette = CommandPalette.new()
	add_child(palette)
	_restyle()


## Colours that are not in the Theme resource (panels, labels), applied again when the theme changes.
func _restyle() -> void:
	bg_rect.color = AmTheme.col("BG")
	(get_node("Root/Side") as PanelContainer).add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("BG_2"), 0, AmTheme.col("BORDER"), 0, 14))
	(get_node("Root/MainCol/Header") as PanelContainer).add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("BG_2"), 0, AmTheme.col("BORDER"), 0, 12))
	var logo: Label = side_box.get_child(0).get_node("Logo")
	logo.add_theme_color_override("font_color", AmTheme.col("MINT"))
	logo.add_theme_font_override("font", AmTheme.ui_font(700))
	var gd: Label = side_box.get_child(0).get_node("Gd")
	gd.add_theme_color_override("font_color", AmTheme.col("WARM"))
	gd.add_theme_font_override("font", AmTheme.ui_font(700))
	status_label.add_theme_color_override("font_color", AmTheme.col("FAINT"))
	header_meta.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	header_name.add_theme_font_override("font", AmTheme.ui_font(650))
	empty_label.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	toast.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL_2"), 10, approval_color(), 1, 12))
	for t in terms.values():
		_style_terminal(t)


func _style_terminal(t: Control) -> void:
	t.background = AmTheme.col("BG")
	t.foreground = AmTheme.col("TEXT")
	t.palette = AmTheme.ansi()


func set_theme_name(name: String) -> void:
	AmTheme.apply(name)
	theme = AmTheme.build()
	_save("theme", name)
	_restyle()
	tree_sig = ""
	await refresh()
	_layout_view()


func _save(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("ui", key, value)
	cfg.save(SETTINGS)


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
	g.add_child(_muted("Name"))
	f_name = LineEdit.new()
	f_name.custom_minimum_size = Vector2(380, 0)
	f_name.placeholder_text = "for example: Brain themes"
	g.add_child(f_name)
	g.add_child(_muted("Tool"))
	f_tool = OptionButton.new()
	for t in [["claude", "✻  Claude Code"], ["codex", "◎  Codex"], ["shell", "❯  Shell"]]:
		f_tool.add_item(t[1])
		f_tool.set_item_metadata(f_tool.item_count - 1, t[0])
	g.add_child(f_tool)
	g.add_child(_muted("Group"))
	f_group = OptionButton.new()
	g.add_child(f_group)
	g.add_child(_muted("Folder"))
	f_cwd = LineEdit.new()
	f_cwd.text = "~"
	f_cwd.placeholder_text = "C:\\git-2026\\my-project or ~/my-project"
	g.add_child(f_cwd)
	g.add_child(Control.new())
	f_worktree = CheckBox.new()
	f_worktree.text = "In its own git branch (a worktree beside the repository)"
	f_worktree.tooltip_text = "The session works in <repository>-worktrees/<name> on branch am/<name>; Finish merges it back."
	g.add_child(f_worktree)
	g.add_child(Control.new())
	f_brain = CheckBox.new()
	f_brain.text = "Share the Second Brain (a key of its own, proposals wait for your OK)"
	g.add_child(f_brain)
	new_dialog.confirmed.connect(_create)


func _muted(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	return l


func _open_new() -> void:
	f_name.text = ""
	f_worktree.button_pressed = false
	f_brain.disabled = not brain_ok
	f_brain.button_pressed = brain_ok
	f_brain.tooltip_text = "" if brain_ok else "The Second Brain is not running on this computer"
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


# ------------------------------------------------------------------ data
func refresh() -> void:
	var r := await engine.call_api("GET", "/tree")
	if r.has("error"):
		status_label.text = "Engine: " + str(r["error"])
		return
	tree = r["groups"]
	sessions = []
	for g in tree:
		sessions.append_array(g["sessions"])
	var names := {}
	for x in sessions:
		names[str(x["id"])] = str(x["name"])
	for x in sessions:  # a session started by an agent shows who started it
		x["parent_name"] = names.get(str(x.get("parent", "")), "")
	var changed := _watch_transitions()
	var sig := JSON.stringify(tree) + selected + AmTheme.current
	if sig != tree_sig and not get_viewport().gui_is_dragging():
		tree_sig = sig
		_render_list()
		for id in changed:
			if cards.has(id):
				cards[id].flash(activity_of(_session(id))[0])
	_render_header()
	if view == "board":
		_refresh_previews()
	elif view == "grid":
		_update_grid_titles()


func _watch_transitions() -> Array:
	var changed := []
	for x in sessions:
		var id := str(x["id"])
		var act := str(x.get("activity", ""))
		var before := str(last_activity.get(id, ""))
		if before != "" and act != before:
			changed.append(id)
			if act in ["approval", "waiting"]:
				_toast("%s %s" % [x["name"], activity_of(x)[1]])
				if not get_window().has_focus():
					DisplayServer.window_request_attention()
		last_activity[id] = act
	return changed


func _toast(text: String) -> void:
	toast_label.text = text
	toast.visible = true
	toast.reset_size()
	toast.modulate.a = 0.0
	create_tween().tween_property(toast, "modulate:a", 1.0, 0.25)
	get_tree().create_timer(6.0).timeout.connect(func() -> void:
		if toast_label.text == text:
			var t := create_tween()
			t.tween_property(toast, "modulate:a", 0.0, 0.4)
			t.tween_callback(func() -> void: toast.visible = false))


func _session(id: String) -> Dictionary:
	for s in sessions:
		if str(s["id"]) == id:
			return s
	return {}


# ------------------------------------------------------------------ sidebar
func _render_list() -> void:
	_render_queue()
	for c in list_box.get_children():
		c.queue_free()
	cards.clear()
	for g in tree:
		var gname := str(g["name"])
		if gname != "":
			list_box.add_child(_group_header(g))
		if bool(g["folded"]):
			continue
		var i := 0
		for s in g["sessions"]:
			list_box.add_child(_card(s, gname, i))
			i += 1
		if gname != "" and (g["sessions"] as Array).is_empty():
			var hint := Label.new()
			hint.text = "    drop a session here"
			hint.add_theme_color_override("font_color", AmTheme.col("FAINT"))
			hint.add_theme_font_size_override("font_size", 12)
			list_box.add_child(hint)
	empty_label.visible = sessions.is_empty()


func _card(s: Dictionary, gname: String, index: int) -> SessionCard:
	var id := str(s["id"])
	var card := SessionCard.new()
	card.setup(s, id == selected, activity_of(s))
	card.picked.connect(select)
	card.rename.connect(_rename_session)
	card.menu.connect(func(sid: String) -> void:
		menu_target = sid
		row_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO)))
	card.set_drag_forwarding(
		func(_at: Vector2) -> Variant:
			var prev := Label.new()
			prev.text = "  " + str(s["name"])
			card.set_drag_preview(prev)
			return {"type": "session", "id": id},
		func(_at: Vector2, d: Variant) -> bool: return d is Dictionary and d.get("type") == "session" and d.get("id") != id,
		func(at: Vector2, d: Variant) -> void: _move(str(d["id"]), gname, index + (1 if at.y > card.size.y / 2 else 0)))
	cards[id] = card
	return card


func _group_header(g: Dictionary) -> Button:
	var gname := str(g["name"])
	var b := Button.new()
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var n := (g["sessions"] as Array).size()
	var waiting := (g["sessions"] as Array).filter(func(x): return str(x.get("activity", "")) in ["approval", "waiting"]).size()
	b.text = "%s  %s   %d%s" % ["▸" if bool(g["folded"]) else "▾", gname.to_upper(), n, ("  · %d waiting" % waiting) if waiting else ""]
	b.add_theme_color_override("font_color", AmTheme.col("MINT") if not AmTheme.is_light() else AmTheme.col("FOREST_LIGHT"))
	b.add_theme_color_override("font_hover_color", AmTheme.col("TEXT"))
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_font_override("font", AmTheme.ui_font(700))
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


func _render_queue() -> void:
	for c in queue_box.get_children():
		c.queue_free()
	var waiting := sessions.filter(func(x): return str(x.get("activity", "")) in ["approval", "waiting"])
	if waiting.is_empty():
		return
	var title := Label.new()
	title.text = "THEY WAIT FOR YOU   %d" % waiting.size()
	title.add_theme_color_override("font_color", approval_color())
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_font_override("font", AmTheme.ui_font(700))
	queue_box.add_child(title)
	for x in waiting.slice(0, 4):
		var id := str(x["id"])
		var act := activity_of(x)
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", AmTheme.box(Color(act[0], 0.10), 10, Color(act[0], 0.7), 1, 9))
		var v := VBoxContainer.new()
		card.add_child(v)
		var l := Label.new()
		l.text = "%s · %s" % [x["name"], act[1]]
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_font_override("font", AmTheme.ui_font(600))
		v.add_child(l)
		var msg := str(x.get("message", ""))
		if msg != "":
			var m := Label.new()
			m.text = msg.left(110)
			m.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			m.add_theme_color_override("font_color", AmTheme.col("MUTED"))
			m.add_theme_font_size_override("font_size", 12)
			v.add_child(m)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		v.add_child(h)
		if str(x["activity"]) == "approval":
			h.add_child(_small("Approve", func() -> void: _keys(id, ["Enter"]), "Enter: the agent's highlighted choice (Yes) · Ctrl+Shift+A"))
			h.add_child(_small("Refuse", func() -> void: _keys(id, ["Escape"]), "Escape"))
		else:
			h.add_child(_small("Reply…", func() -> void: _quick_reply(id), "Write to the agent without opening its terminal"))
		h.add_child(_small("Open", func() -> void: select(id)))
		queue_box.add_child(card)
	if waiting.size() > 4:
		var more := Label.new()
		more.text = "+ %d more in the list below" % (waiting.size() - 4)
		more.add_theme_color_override("font_color", AmTheme.col("FAINT"))
		more.add_theme_font_size_override("font_size", 12)
		queue_box.add_child(more)


func _small(text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(cb)
	return b


func _render_header() -> void:
	var s := _session(selected)
	header_name.text = str(s.get("name", "Agent Manager GD"))
	var meta := ""
	if s:
		meta = "%s  ·  %s" % [s["tool_label"], s["cwd"]]
		if str(s.get("branch", "")) != "":
			meta += "  ·  ⎇ " + str(s["branch"])
		if s.get("brain", false):
			meta += "  ·  ✦ shares the Second Brain"
	header_meta.text = meta
	var act := activity_of(s) if s else [AmTheme.col("MUTED"), ""]
	var msg := str(s.get("message", ""))
	header_state.text = ("● " + str(act[1]) if s else "") + (("  ·  " + msg.left(60)) if msg != "" and str(s.get("activity", "")) in ["approval", "waiting"] else "")
	header_state.add_theme_color_override("font_color", act[0])
	for k in view_buttons:
		view_buttons[k].button_pressed = k == view
	var rb: Button = get_node("Root/MainCol/Header").find_child("ResumeBtn", true, false)
	if rb:
		rb.visible = s and str(s.get("tool", "")) != "shell" and str(s.get("state", "")) in ["exited", "missing"]


# ------------------------------------------------------------------ views
func select(id: String) -> void:
	selected = id
	if not grid_ids.has(id):
		grid_ids.push_front(id)
	grid_ids = grid_ids.slice(0, 4)
	if view in ["board", "history"]:
		view = "focus"  # picking a session opens it
	await _ensure_terminal(id)
	_layout_view()
	if terms.has(id):
		terms[id].grab_focus()
	tree_sig = ""
	_render_list()
	_render_header()


func set_view(v: String) -> void:
	view = v
	_save("view", v)
	if v == "grid":
		# fill the grid with the selected session and the most recent others
		for x in sessions:
			if grid_ids.size() >= 4:
				break
			if not grid_ids.has(str(x["id"])) and str(x["state"]) != "missing":
				grid_ids.append(str(x["id"]))
		for id in grid_ids:
			await _ensure_terminal(id)
	content.modulate.a = 0.0
	_layout_view()
	create_tween().tween_property(content, "modulate:a", 1.0, 0.18)
	_render_header()
	if v == "board":
		_refresh_previews()


func _ensure_terminal(id: String) -> void:
	if terms.has(id) and is_instance_valid(terms[id]) and terms[id].is_running():
		return
	if terms.has(id) and is_instance_valid(terms[id]):
		terms[id].queue_free()
	var r := await engine.call_api("GET", "/sessions/%s/attach" % id)
	if r.has("error"):
		status_label.text = str(r["error"])
		return
	var t = ClassDB.instantiate("VtTerminal")
	t.font = font
	t.font_size = 15
	_style_terminal(t)
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	t.size_flags_vertical = SIZE_EXPAND_FILL
	parking.add_child(t)
	terms[id] = t
	t.size = Vector2(1000, 700)
	await get_tree().process_frame
	var cmd: Array = engine.host_command(r["command"])
	t.start(cmd[0], PackedStringArray(cmd.slice(1)), "", PackedStringArray(["TERM=xterm-256color", "COLORTERM=truecolor"]))
	t.exited.connect(func(_c: int) -> void: refresh())


func _park_all() -> void:
	for t in terms.values():
		if is_instance_valid(t) and t.get_parent() != parking:
			t.reparent(parking, false)
			if content.size.x > 200:  # off screen, keep a sensible size (tmux follows it)
				t.size = content.size - Vector2(20, 20)
	for c in content.get_children():
		c.queue_free()
	board_previews.clear()


func _layout_view() -> void:
	_park_all()
	if sessions.is_empty() and view != "history":
		return
	match view:
		"focus":
			if terms.has(selected) and is_instance_valid(terms[selected]):
				var frame := _frame(selected, false)
				content.add_child(frame)
		"grid":
			var g := GridContainer.new()
			g.columns = 1 if grid_ids.size() <= 1 else 2
			g.add_theme_constant_override("h_separation", 10)
			g.add_theme_constant_override("v_separation", 10)
			content.add_child(g)
			for id in grid_ids:
				if terms.has(id) and is_instance_valid(terms[id]):
					var f := _frame(id, true)
					f.size_flags_horizontal = SIZE_EXPAND_FILL
					f.size_flags_vertical = SIZE_EXPAND_FILL
					g.add_child(f)
		"history":
			content.add_child(_history_view())
			_load_history()
		"board":
			var scroll := ScrollContainer.new()
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			content.add_child(scroll)
			var g := GridContainer.new()
			g.columns = 3
			g.size_flags_horizontal = SIZE_EXPAND_FILL
			g.add_theme_constant_override("h_separation", 12)
			g.add_theme_constant_override("v_separation", 12)
			scroll.add_child(g)
			for s in sessions:
				g.add_child(_tile(s))


## A terminal in a frame; in the grid, a title bar shows which session it is.
func _frame(id: String, titled: bool) -> Control:
	var s := _session(id)
	var outer := PanelContainer.new()
	var focused := id == selected
	outer.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("BG"), 10, AmTheme.col("MINT") if focused and titled else AmTheme.col("BORDER"), 1, 8))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	outer.add_child(v)
	if titled:
		var bar := HBoxContainer.new()
		bar.name = "Bar"
		var act := activity_of(s)
		var dot := Label.new()
		dot.name = "Dot"
		dot.text = "●"
		dot.add_theme_color_override("font_color", act[0])
		bar.add_child(dot)
		var t := Label.new()
		t.name = "Title"
		t.text = "%s  ·  %s" % [s.get("name", ""), act[1]]
		t.add_theme_font_size_override("font_size", 13)
		t.size_flags_horizontal = SIZE_EXPAND_FILL
		bar.add_child(t)
		var focus_btn := _small("⤢", func() -> void:
			selected = id
			set_view("focus"), "Open alone")
		bar.add_child(focus_btn)
		bar.set_meta("id", id)
		v.add_child(bar)
	var t2: Control = terms[id]
	t2.reparent(v, false)
	t2.size_flags_vertical = SIZE_EXPAND_FILL
	t2.size_flags_horizontal = SIZE_EXPAND_FILL
	t2.focus_entered.connect(func() -> void:
		if selected != id:
			selected = id
			tree_sig = ""
			_render_list()
			_render_header(), CONNECT_ONE_SHOT)
	return outer


func _update_grid_titles() -> void:
	for f in content.get_children():
		for cell in (f.get_children() if f is GridContainer else []):
			var bar: Node = cell.get_child(0).get_node_or_null("Bar")
			if bar:
				var s := _session(str(bar.get_meta("id")))
				var act := activity_of(s)
				(bar.get_node("Dot") as Label).add_theme_color_override("font_color", act[0])
				(bar.get_node("Title") as Label).text = "%s  ·  %s" % [s.get("name", ""), act[1]]


func _tile(s: Dictionary) -> Control:
	var id := str(s["id"])
	var act := activity_of(s)
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(0, 250)
	tile.size_flags_horizontal = SIZE_EXPAND_FILL
	var attention := str(s.get("activity", "")) in ["approval", "waiting"]
	tile.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 12, act[0] if attention else AmTheme.col("BORDER"), 1, 12))
	tile.mouse_filter = MOUSE_FILTER_STOP
	tile.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			view = "focus"
			select(id))
	var v := VBoxContainer.new()
	v.mouse_filter = MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 6)
	tile.add_child(v)
	var h := HBoxContainer.new()
	h.mouse_filter = MOUSE_FILTER_IGNORE
	v.add_child(h)
	var tb: Array = SessionCard.TOOL_BADGE.get(str(s["tool"]), ["•", AmTheme.col("MUTED")])
	var g := Label.new()
	g.text = tb[0]
	g.add_theme_color_override("font_color", tb[1])
	g.add_theme_font_size_override("font_size", 18)
	h.add_child(g)
	var n := Label.new()
	n.text = str(s["name"])
	n.add_theme_font_size_override("font_size", 15)
	n.add_theme_font_override("font", AmTheme.ui_font(650))
	n.size_flags_horizontal = SIZE_EXPAND_FILL
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(n)
	var st := Label.new()
	st.text = "● " + str(act[1])
	st.add_theme_color_override("font_color", act[0])
	st.add_theme_font_size_override("font_size", 12)
	h.add_child(st)
	var meta := Label.new()
	meta.text = "%s%s" % [str(s["cwd"]).get_file(), ("  ·  ⎇ " + str(s["branch"])) if str(s.get("branch", "")) != "" else ""]
	meta.add_theme_color_override("font_color", AmTheme.col("FAINT"))
	meta.add_theme_font_size_override("font_size", 11)
	v.add_child(meta)
	var pv := PanelContainer.new()
	pv.size_flags_vertical = SIZE_EXPAND_FILL
	pv.mouse_filter = MOUSE_FILTER_IGNORE
	pv.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("BG"), 8, Color(0, 0, 0, 0), 0, 8))
	v.add_child(pv)
	var pl := Label.new()
	pl.add_theme_font_override("font", font)
	pl.add_theme_font_size_override("font_size", 10)
	pl.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	pl.clip_text = true
	pl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	pl.size_flags_vertical = SIZE_EXPAND_FILL
	pl.mouse_filter = MOUSE_FILTER_IGNORE
	pv.add_child(pl)
	board_previews[id] = pl
	return tile


func _refresh_previews() -> void:
	for id in board_previews.keys():
		var r := await engine.call_api("GET", "/sessions/%s/preview?lines=14" % id)
		if board_previews.has(id) and is_instance_valid(board_previews[id]) and not r.has("error"):
			var lines := str(r.get("text", "")).rstrip("\n").split("\n")
			var keep: Array = []
			for line in lines.slice(maxi(0, lines.size() - 12)):
				keep.append(line.left(90))
			board_previews[id].text = "\n".join(keep)


# ------------------------------------------------------------------ history (Loop 5): nothing is ever lost
func _history_view() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	var top := HBoxContainer.new()
	v.add_child(top)
	var title := Label.new()
	title.text = "Every session, every conversation"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_font_override("font", AmTheme.ui_font(650))
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(title)
	history_search = LineEdit.new()
	history_search.placeholder_text = "Search a name, folder, group or conversation id…"
	history_search.custom_minimum_size = Vector2(380, 0)
	history_search.text_changed.connect(func(_t: String) -> void: _load_history())
	top.add_child(history_search)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	history_list = VBoxContainer.new()
	history_list.size_flags_horizontal = SIZE_EXPAND_FILL
	history_list.add_theme_constant_override("separation", 8)
	scroll.add_child(history_list)
	return v


func _load_history() -> void:
	if history_list == null or not is_instance_valid(history_list):
		return
	var q := history_search.text.strip_edges() if is_instance_valid(history_search) else ""
	var r := await engine.call_api("GET", "/history?q=" + q.uri_encode())
	if r.has("error") or not is_instance_valid(history_list):
		return
	for c in history_list.get_children():
		c.queue_free()
	for h in r["sessions"]:
		history_list.add_child(_history_row(h))
	if (r["sessions"] as Array).is_empty():
		var none := Label.new()
		none.text = "Nothing matches."
		none.add_theme_color_override("font_color", AmTheme.col("MUTED"))
		history_list.add_child(none)


func _history_row(h: Dictionary) -> Control:
	var id := str(h["id"])
	var archived := int(h.get("archived", 0)) == 1
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 10, AmTheme.col("BORDER"), 1, 12))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	row.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	v.add_child(top)
	var tb: Array = SessionCard.TOOL_BADGE.get(str(h["tool"]), ["•", AmTheme.col("MUTED")])
	var g := Label.new()
	g.text = tb[0]
	g.add_theme_color_override("font_color", tb[1])
	g.add_theme_font_size_override("font_size", 18)
	top.add_child(g)
	var n := Label.new()
	n.text = str(h["name"])
	n.add_theme_font_size_override("font_size", 15)
	n.add_theme_font_override("font", AmTheme.ui_font(650))
	top.add_child(n)
	var st := Label.new()
	st.text = "archived " + _date(float(h.get("archived_at", 0))) if archived else "in the sidebar"
	st.add_theme_color_override("font_color", AmTheme.col("FAINT") if archived else AmTheme.col("MINT"))
	st.add_theme_font_size_override("font_size", 12)
	st.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(st)
	if str(h["tool"]) != "shell":
		top.add_child(_small("Resume", func() -> void: _resume(id, ""), "Starts it again on its latest conversation"))
		top.add_child(_small("Fork…", func() -> void: _fork(id), "A new session on a copy of the conversation"))
	elif archived:
		top.add_child(_small("Restore", func() -> void: _resume(id, ""), "Back to the sidebar, a fresh shell"))
	var meta := Label.new()
	meta.text = "%s  ·  %s%s  ·  made %s%s" % [h["tool_label"], h["cwd"], ("  ·  " + str(h["grp"])) if str(h["grp"]) != "" else "", _date(float(h["created"])), ("  ·  fork of " + str(h["parent"])) if str(h.get("parent", "")) != "" else ""]
	meta.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	meta.add_theme_font_size_override("font_size", 12)
	v.add_child(meta)
	for c in (h["conversations"] as Array).slice(0, 6):
		var cr := HBoxContainer.new()
		cr.add_theme_constant_override("separation", 8)
		var cl := Label.new()
		cl.text = "   ↳ %s   last seen %s" % [c["conversation"], _date(float(c["last_seen"]))]
		cl.add_theme_font_override("font", font)
		cl.add_theme_font_size_override("font_size", 12)
		cl.add_theme_color_override("font_color", AmTheme.col("FAINT"))
		cl.size_flags_horizontal = SIZE_EXPAND_FILL
		cr.add_child(cl)
		var conv := str(c["conversation"])
		cr.add_child(_small("Resume this one", func() -> void: _resume(id, conv)))
		cr.add_child(_small("Copy id", func() -> void:
			DisplayServer.clipboard_set(conv)
			_toast("Conversation id copied")))
		v.add_child(cr)
	return row


static func _date(t: float) -> String:
	if t <= 0:
		return ""
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(int(t) + bias, true).left(16)


func _resume(id: String, conversation: String) -> void:
	var r := await engine.call_api("POST", "/sessions/%s/resume" % id, {"conversation": conversation})
	if r.has("error"):
		status_label.text = str(r["error"])
		return
	if terms.has(id):
		terms[id].queue_free()
		terms.erase(id)
	view = "focus"
	await refresh()
	await select(id)


func _fork(id: String) -> void:
	_ask("Fork " + str(_session(id).get("name", "")), str(_session(id).get("name", "session")) + " (fork)", func(n: String) -> void:
		var r := await engine.call_api("POST", "/sessions/%s/fork" % id, {"name": n})
		if r.has("error"):
			status_label.text = str(r["error"])
			return
		view = "focus"
		await refresh()
		await select(str(r["id"])))


func _archive(id: String) -> void:
	await engine.call_api("POST", "/sessions/%s/archive" % id)
	if terms.has(id):
		terms[id].queue_free()
		terms.erase(id)
	grid_ids.erase(id)
	if selected == id:
		selected = ""
	await refresh()
	_toast("Archived: kept in History with its conversations")
	if selected == "" and sessions.size() > 0:
		await select(str(sessions[0]["id"]))
	else:
		_layout_view()


func _open_finish(id: String) -> void:
	var r := await engine.call_api("GET", "/sessions/%s/worktree" % id)
	if r.has("error") or str(r.get("worktree", "")) == "":
		status_label.text = "This session has no git branch of its own."
		return
	menu_target = id
	finish_info.text = "Branch %s · %d commit(s) not in %s · %d uncommitted change(s)\n%s" % [r["branch"], r["commits_ahead"], r["target"], r["uncommitted"], r["worktree"]]
	finish_merge.text = "Merge %s into %s first" % [r["branch"], r["target"]]
	finish_merge.button_pressed = int(r["commits_ahead"]) > 0
	finish_merge.disabled = int(r["commits_ahead"]) == 0
	finish_dialog.get_ok_button().disabled = int(r["uncommitted"]) > 0
	finish_dialog.popup_centered()


# ------------------------------------------------------------------ palette
func open_palette() -> void:
	var items: Array = []
	for s in sessions:
		var sid := str(s["id"])
		items.append({"label": "Go to " + str(s["name"]), "hint": "%s · %s" % [s["tool_label"], activity_of(s)[1]], "run": select.bind(sid)})
		if str(s.get("activity", "")) == "approval":
			items.append({"label": "Approve " + str(s["name"]), "hint": str(s.get("message", "")).left(50), "run": func() -> void: _keys(sid, ["Enter"])})
		items.append({"label": "Reply to " + str(s["name"]), "hint": "without opening it", "run": func() -> void: _quick_reply(sid)})
	items.append({"label": "History", "hint": "every session and conversation · Ctrl+Shift+H", "run": set_view.bind("history")})
	items.append({"label": "New session", "hint": "Ctrl+Shift+N", "run": _open_new})
	items.append({"label": "New group", "hint": "", "run": func() -> void: _ask("New group", "", func(n: String) -> void:
		await engine.call_api("POST", "/groups", {"name": n})
		await refresh())})
	for v in [["focus", "Focus view", "Ctrl+Shift+F"], ["grid", "Grid view", "Ctrl+Shift+G"], ["board", "Board view", "Ctrl+Shift+B"]]:
		items.append({"label": v[1], "hint": v[2], "run": set_view.bind(v[0])})
	for t in AmTheme.THEMES:
		items.append({"label": "Theme: " + AmTheme.LABELS[t], "hint": "", "run": set_theme_name.bind(t)})
	if selected != "":
		var sname := str(_session(selected).get("name", ""))
		var sid2 := selected
		if str(_session(selected).get("tool", "")) != "shell":
			items.append({"label": "Resume " + sname, "hint": "its own conversation", "run": func() -> void: _resume(sid2, "")})
			items.append({"label": "Fork " + sname, "hint": "a copy of the conversation", "run": func() -> void: _fork(sid2)})
		items.append({"label": "Archive " + sname, "hint": "kept in History", "run": func() -> void: _archive(sid2)})
		items.append({"label": "Restart " + sname + " fresh", "hint": "a new conversation", "run": _restart})
		items.append({"label": "Rename " + str(_session(selected).get("name", "")), "hint": "", "run": func() -> void: _rename_session(selected)})
	palette.open(items)


# ------------------------------------------------------------------ actions
func _create() -> void:
	var name := f_name.text.strip_edges()
	if name == "":
		name = str(f_tool.get_item_text(f_tool.selected)).substr(3)
	var r := await engine.call_api("POST", "/sessions", {"name": name, "tool": f_tool.get_selected_metadata(), "cwd": f_cwd.text.strip_edges(), "group": str(f_group.get_selected_metadata()) if f_group.item_count > 0 else "", "worktree": f_worktree.button_pressed, "brain": f_brain.button_pressed})
	if r.has("error"):
		status_label.text = "Not started: " + str(r["error"])
		return
	await refresh()
	await select(str(r["id"]))


func _restart() -> void:
	if selected == "":
		return
	await engine.call_api("POST", "/sessions/%s/restart" % selected)
	if terms.has(selected):
		terms[selected].queue_free()
		terms.erase(selected)
	await refresh()
	await select(selected)


func _stop() -> void:
	if selected != "":
		await engine.call_api("POST", "/sessions/%s/stop" % selected)
		await refresh()


func _remove() -> void:
	if selected == "":
		return
	await engine.call_api("DELETE", "/sessions/%s" % selected)
	if terms.has(selected):
		terms[selected].queue_free()
		terms.erase(selected)
	grid_ids.erase(selected)
	selected = ""
	await refresh()
	if sessions.size() > 0:
		await select(str(sessions[0]["id"]))
	else:
		_layout_view()


func _keys(id: String, keys: Array) -> void:
	var r := await engine.call_api("POST", "/sessions/%s/keys" % id, {"keys": keys})
	if r.has("error"):
		status_label.text = str(r["error"])
	await get_tree().create_timer(0.6).timeout
	await refresh()


func _quick_reply(id: String) -> void:
	_ask("Reply to " + str(_session(id).get("name", "")), "", func(t: String) -> void:
		var r := await engine.call_api("POST", "/sessions/%s/send" % id, {"text": t})
		if r.has("error"):
			status_label.text = str(r["error"])
		await refresh())


func _drop_on_group(gname: String, d: Dictionary) -> void:
	if d["type"] == "session":
		await _move(str(d["id"]), gname, 1 << 20)
	elif d["type"] == "group" and str(d["name"]) != gname:
		var names: Array = []
		for g in tree:
			if str(g["name"]) != "" and str(g["name"]) != str(d["name"]):
				names.append(str(g["name"]))
		names.insert(names.find(gname), str(d["name"]))
		await engine.call_api("POST", "/groups/order", {"names": names})
		await refresh()


func _move(id: String, gname: String, index: int) -> void:
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
	row_menu.add_item("Quick reply…", 5)
	row_menu.add_item("Show in grid", 6)
	row_menu.add_item("Rename…", 0)
	row_menu.add_separator()
	row_menu.add_item("Resume its conversation", 7)
	row_menu.add_item("Fork…", 8)
	row_menu.add_item("Finish its git branch…", 9)
	row_menu.add_item("Archive (kept in History)", 10)
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
	row_menu.add_submenu_node_item("Move to group", move_menu, 1)
	row_menu.add_separator()
	row_menu.add_item("Restart fresh", 2)
	row_menu.add_item("Stop", 3)
	row_menu.add_item("Remove and forget", 4)
	row_menu.about_to_popup.connect(func() -> void:
		var s := _session(menu_target)
		var agent := str(s.get("tool", "")) != "shell"
		row_menu.set_item_disabled(row_menu.get_item_index(7), not agent)
		row_menu.set_item_disabled(row_menu.get_item_index(8), not agent)
		row_menu.set_item_disabled(row_menu.get_item_index(9), str(s.get("worktree", "")) == ""))
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
	theme_menu = PopupMenu.new()
	for t in AmTheme.THEMES:
		theme_menu.add_item(AmTheme.LABELS[t])
		theme_menu.set_item_metadata(theme_menu.item_count - 1, t)
	theme_menu.index_pressed.connect(func(i: int) -> void: set_theme_name(str(theme_menu.get_item_metadata(i))))
	add_child(theme_menu)
	finish_dialog = ConfirmationDialog.new()
	finish_dialog.title = "Finish this git branch"
	finish_dialog.ok_button_text = "Finish"
	var fv := VBoxContainer.new()
	fv.add_theme_constant_override("separation", 8)
	finish_info = Label.new()
	fv.add_child(finish_info)
	finish_merge = CheckBox.new()
	fv.add_child(finish_merge)
	finish_delete = CheckBox.new()
	finish_delete.text = "Delete the branch afterwards (only if merged)"
	finish_delete.button_pressed = true
	fv.add_child(finish_delete)
	var warn := Label.new()
	warn.text = "The worktree folder is removed; the session goes to History. Uncommitted changes block this."
	warn.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	warn.add_theme_font_size_override("font_size", 12)
	fv.add_child(warn)
	finish_dialog.add_child(fv)
	finish_dialog.confirmed.connect(func() -> void:
		var id := menu_target
		var r := await engine.call_api("POST", "/sessions/%s/finish" % id, {"merge": finish_merge.button_pressed, "delete_branch": finish_delete.button_pressed})
		if r.has("error"):
			status_label.text = str(r["error"])
			return
		_toast("Finished %s%s" % [r["branch"], (" · merged into " + str(r["target"])) if r["merged"] else ""])
		if terms.has(id):
			terms[id].queue_free()
			terms.erase(id)
		if selected == id:
			selected = ""
		await refresh()
		_layout_view())
	add_child(finish_dialog)
	ask_dialog = ConfirmationDialog.new()
	ask_edit = LineEdit.new()
	ask_edit.custom_minimum_size = Vector2(340, 0)
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
	if mid == 5:
		_quick_reply(menu_target)
		return
	if mid == 6:
		grid_ids.erase(menu_target)
		grid_ids.push_front(menu_target)
		grid_ids = grid_ids.slice(0, 4)
		await _ensure_terminal(menu_target)
		set_view("grid")
		return
	if mid == 0:
		_rename_session(menu_target)
		return
	if mid == 7:
		_resume(menu_target, "")
		return
	if mid == 8:
		_fork(menu_target)
		return
	if mid == 9:
		_open_finish(menu_target)
		return
	if mid == 10:
		_archive(menu_target)
		return
	selected = menu_target
	if mid == 2:
		_restart()
	elif mid == 3:
		_stop()
	elif mid == 4:
		_remove()


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
