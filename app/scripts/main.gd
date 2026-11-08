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
	sv.add_child(new_btn)
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
	g.add_child(_label("Folder"))
	f_cwd = LineEdit.new()
	f_cwd.text = "~"
	f_cwd.placeholder_text = "/mnt/c/git-2026/my-project" if engine == null or engine.on_windows else "~/my-project"
	g.add_child(f_cwd)
	new_dialog.confirmed.connect(_create)


func _open_new() -> void:
	f_name.text = ""
	new_dialog.popup_centered()
	f_name.grab_focus()


# ------------------------------------------------------------------ sessions
func refresh() -> void:
	var r := await engine.call_api("GET", "/sessions")
	if r.has("error"):
		status_label.text = "Engine: " + str(r["error"])
		return
	sessions = r["sessions"]
	_render_list()
	_render_header()


func _render_list() -> void:
	for c in list_box.get_children():
		c.queue_free()
	for s in sessions:
		var row := Button.new()
		row.toggle_mode = true
		row.button_pressed = str(s["id"]) == selected
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.text = "     %s\n     %s · %s" % [s["name"], s["tool_label"], s["state"]]
		row.add_theme_color_override("font_color", C_TEXT)
		row.custom_minimum_size = Vector2(0, 52)
		row.tooltip_text = str(s["cwd"])
		var dot := STATE_COLOR.get(s["state"], C_MUTED) as Color
		row.set_meta("id", s["id"])
		row.pressed.connect(select.bind(str(s["id"])))
		list_box.add_child(row)
		# the coloured state dot
		var d := ColorRect.new()
		d.color = dot
		d.size = Vector2(8, 8)
		d.position = Vector2(14, 15)
		d.mouse_filter = MOUSE_FILTER_IGNORE
		row.add_child(d)
	empty_label.visible = sessions.is_empty()


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
	var r := await engine.call_api("POST", "/sessions", {"name": name, "tool": f_tool.get_selected_metadata(), "cwd": f_cwd.text.strip_edges()})
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
