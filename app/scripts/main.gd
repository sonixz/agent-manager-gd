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
var f_brief: CheckBox
var dictation: Dictation
var voice_mode := "dictate"     # F8 dictate, F9 command
var spoken := false
var last_spoken := ""
var voice_overlay: PanelContainer
var voice_label: Label
var voice_meter: ProgressBar
var keys_list: VBoxContainer
var usage_box: VBoxContainer
var sbx_box: VBoxContainer
var f_where: OptionButton
var repos_list: VBoxContainer
var repos_cache: Array = []
var f_repo: OptionButton
var confirm_dialog: ConfirmationDialog
var confirm_done: Callable
var review_data := {}
var review_mode := "uncommitted"
var review_file := 0
var review_files: ItemList
var review_lines: VBoxContainer
var review_send: Button
var review_info: Label
var read_dialog: AcceptDialog
var read_text: RichTextLabel
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
		"missing": return [AmTheme.col("ERROR"), "gone · Resume brings it back"]
		"wrapping": return [AmTheme.col("WARM"), "writing its summary"]
	return [AmTheme.col("MUTED"), a]


func approval_color() -> Color:
	return Color("b4521a") if AmTheme.is_light() else Color("ff9e64")


func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	AmTheme.apply(str(cfg.get_value("ui", "theme", OS.get_environment("AGMGD_THEME") if OS.get_environment("AGMGD_THEME") != "" else "focus")))
	view = str(cfg.get_value("ui", "view", "focus"))
	spoken = bool(cfg.get_value("ui", "spoken", false))
	_load_keymap()
	theme = AmTheme.build()
	font = TermFont.make()
	_build()
	engine = EngineClient.new()
	add_child(engine)
	status_label.text = "Starting the engine…"
	if not await engine.connect_engine():
		status_label.text = "The engine did not start: see the setup check."
		set_view("setup")
		return
	var b := await engine.call_api("GET", "/brain")
	brain_ok = bool(b.get("connected", false))
	status_label.text = ("✦ Second Brain connected" if brain_ok else "Second Brain: " + str(b.get("reason", "not connected"))) + " · %s for commands" % key_text("palette")
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
const DEFAULT_KEYS := {"palette": "Ctrl+K", "new": "Ctrl+N", "focus": "Ctrl+F", "grid": "Ctrl+G", "board": "Ctrl+B",
	"history": "Ctrl+H", "review": "Ctrl+R", "next": "Ctrl+Down", "prev": "Ctrl+Up", "approve": "Ctrl+A",
	"dictate": "F8", "command": "F9"}
const KEY_LABELS := {"palette": "Command palette", "new": "New session", "focus": "Focus view", "grid": "Grid view",
	"board": "Board view", "history": "History", "review": "Review", "next": "Next session", "prev": "Previous session",
	"approve": "Approve the first session waiting for an OK", "dictate": "Hold to dictate (voice)",
	"command": "Hold for a voice command"}
var keymap := DEFAULT_KEYS.duplicate()
var key_capture := ""  # the action waiting for its new key (Shortcuts screen)


func _load_keymap() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	for a in DEFAULT_KEYS:
		keymap[a] = str(cfg.get_value("keys", a, DEFAULT_KEYS[a]))


func _save_key(action: String, binding: String) -> void:
	keymap[action] = binding
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("keys", action, binding)
	cfg.save(SETTINGS)


func key_text(action: String) -> String:
	return str(keymap.get(action, ""))


func _run_action(a: String) -> void:
	match a:
		"palette": open_palette()
		"new": _open_new()
		"focus", "grid", "board", "history", "review": set_view(a)
		"next": _step(1)
		"prev": _step(-1)
		"approve": _approve_first()


func _input(e: InputEvent) -> void:
	if not (e is InputEventKey):
		return
	var k := e as InputEventKey
	if key_capture != "" and k.pressed and not k.echo:
		if k.keycode not in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			if k.keycode != KEY_ESCAPE:
				var t := k.as_text_keycode()
				if key_capture in ["dictate", "command"]:
					t = OS.get_keycode_string(k.keycode)  # a key you hold: no modifiers
				_save_key(key_capture, t)
			key_capture = ""
			if view == "shortcuts":
				_layout_view()
		get_viewport().set_input_as_handled()
		return
	# the voice keys: hold to talk (works even when the terminal has the focus)
	var single := OS.get_keycode_string(k.keycode)
	if not k.echo and (single == keymap["dictate"] or single == keymap["command"]):
		if k.pressed:
			voice_mode = "dictate" if single == keymap["dictate"] else "command"
			_voice_start()
		else:
			_voice_stop()
		get_viewport().set_input_as_handled()
		return
	if not (k.pressed and not k.echo):
		return
	var in_terminal := get_viewport().gui_get_focus_owner() != null and get_viewport().gui_get_focus_owner().is_class("VtTerminal")
	var t := k.as_text_keycode()
	# a terminal keeps its keys: there, only Ctrl+Shift shortcuts (or a Ctrl binding typed with Shift) and F-keys act
	var without_shift := t.replace("Shift+", "") if k.ctrl_pressed and k.shift_pressed else ""
	for a in keymap:
		if a in ["dictate", "command"]:
			continue
		var b := str(keymap[a])
		var ok := false
		if b == t:
			ok = not in_terminal or b.begins_with("Ctrl+Shift+") or (not b.contains("Ctrl+") and not b.contains("Alt+") and t.begins_with("F"))
		elif without_shift != "" and b == without_shift:
			ok = true
		if ok:
			_run_action(a)
			get_viewport().set_input_as_handled()
			return


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
	for v in [["focus", "Focus", "Ctrl+Shift+F"], ["grid", "Grid", "Ctrl+Shift+G"], ["board", "Board", "Ctrl+Shift+B"], ["history", "History", "Ctrl+Shift+H"], ["review", "Review", "Ctrl+Shift+R"]]:
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
	var sbx_btn := Button.new()
	sbx_btn.text = "☁ Sandboxes"
	sbx_btn.tooltip_text = "Cloud sandboxes: the manager and their connections"
	sbx_btn.toggle_mode = true
	sbx_btn.pressed.connect(set_view.bind("sandboxes"))
	hb.add_child(sbx_btn)
	view_buttons["sandboxes"] = sbx_btn
	var repos_btn := Button.new()
	repos_btn.text = "⎇ Repos"
	repos_btn.tooltip_text = "Connected repositories and their deploy keys"
	repos_btn.toggle_mode = true
	repos_btn.pressed.connect(set_view.bind("repos"))
	hb.add_child(repos_btn)
	view_buttons["repos"] = repos_btn
	var theme_btn := Button.new()
	theme_btn.text = "◐"
	theme_btn.tooltip_text = "Theme and keys"
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
	dictation = Dictation.new()
	add_child(dictation)
	_build_voice_overlay(area)
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
	g.add_child(_muted("Where"))
	f_where = OptionButton.new()
	f_where.add_item("This computer")
	f_where.set_item_metadata(0, "local")
	f_where.add_item("☁ A cloud sandbox (Fly.io)")
	f_where.set_item_metadata(1, "sandbox")
	f_where.tooltip_text = "A throw-away machine on Fly.io for this session; you destroy it yourself in Sandboxes"
	g.add_child(f_where)
	g.add_child(_muted("Repository"))
	f_repo = OptionButton.new()
	f_repo.tooltip_text = "A connected repository: the session works in its folder and git uses its deploy key"
	f_repo.item_selected.connect(func(_i: int) -> void:
		var on := str(f_repo.get_selected_metadata()) != ""
		f_cwd.editable = not on
		if on:
			for r in repos_cache:
				if str(r["id"]) == str(f_repo.get_selected_metadata()):
					f_cwd.text = str(r["local_path"]) if str(r["local_path"]) != "" else "(cloned on first use)"
		_check_brief())
	g.add_child(f_repo)
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
	g.add_child(Control.new())
	f_brief = CheckBox.new()
	f_brief.text = "Brief it with the latest summary of this folder"
	g.add_child(f_brief)
	f_cwd.text_changed.connect(func(_t: String) -> void: _check_brief())
	f_tool.item_selected.connect(func(_i: int) -> void: _check_brief())
	new_dialog.confirmed.connect(_create)


func _muted(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	return l


func _check_brief() -> void:
	f_brief.disabled = true
	f_brief.button_pressed = false
	f_brief.text = "Brief it with the latest summary of this folder (none yet)"
	if str(f_tool.get_selected_metadata()) == "shell" or f_cwd.text.strip_edges() == "":
		return
	var cwd := f_cwd.text.strip_edges()
	var r := await engine.call_api("GET", "/summaries?cwd=" + cwd.uri_encode())
	if f_cwd.text.strip_edges() != cwd:
		return  # the folder changed while we asked
	var list: Array = r.get("summaries", [])
	if list.is_empty():
		return
	f_brief.disabled = false
	f_brief.button_pressed = true
	f_brief.text = "Brief it with the latest summary of this folder (%s, a short first message)" % _date(float(list[0]["created"]))


func _open_new() -> void:
	f_name.text = ""
	f_cwd.editable = true
	f_repo.clear()
	f_repo.add_item("(none: a folder)")
	f_repo.set_item_metadata(0, "")
	var rr := await engine.call_api("GET", "/repos")
	repos_cache = rr.get("repos", [])
	for r in repos_cache:
		if str(r["status"]) == "connected":
			f_repo.add_item("⎇ " + str(r["name"]))
			f_repo.set_item_metadata(f_repo.item_count - 1, str(r["id"]))
	f_worktree.button_pressed = false
	f_brain.disabled = not brain_ok
	f_brain.button_pressed = brain_ok
	f_brain.tooltip_text = "" if brain_ok else "The Second Brain is not running on this computer"
	_check_brief()
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
			_speak_transition(x, act)
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
	empty_label.visible = sessions.is_empty() and view not in ["history", "repos", "keys", "usage", "sandboxes", "setup", "shortcuts", "connect"]


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
	if view in ["board", "history", "repos", "keys", "usage", "sandboxes"]:
		view = "focus"  # picking a session opens it (Review follows the selected session)
	if view == "review":
		review_file = 0
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
	empty_label.visible = sessions.is_empty() and v not in ["history", "repos", "keys", "usage", "sandboxes", "setup", "shortcuts", "connect"]
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
	if sessions.is_empty() and view not in ["history", "repos", "keys", "usage", "sandboxes", "setup", "shortcuts", "connect"]:
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
		"review":
			content.add_child(_review_view())
			_load_review()
		"repos":
			content.add_child(_repos_view())
			_load_repos()
		"keys":
			content.add_child(_keys_view())
			_load_keys()
		"usage":
			content.add_child(_usage_view())
			_load_usage()
		"setup":
			content.add_child(_page(_setup_rows()))
		"shortcuts":
			content.add_child(_page(_shortcut_rows()))
		"connect":
			content.add_child(_page(_connect_rows()))
		"sandboxes":
			content.add_child(_sandboxes_view())
			_load_sandboxes()
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
	var sums: Array = h.get("summaries", [])
	if not sums.is_empty():
		var sp := PanelContainer.new()
		sp.add_theme_stylebox_override("panel", AmTheme.box(Color(AmTheme.col("WARM"), 0.08), 8, Color(AmTheme.col("WARM"), 0.35), 1, 10))
		var sv := VBoxContainer.new()
		sp.add_child(sv)
		var sh := HBoxContainer.new()
		sv.add_child(sh)
		var stl := Label.new()
		stl.text = "Summary · %s%s" % [_date(float(sums[0]["created"])), ("   (%d earlier)" % (sums.size() - 1)) if sums.size() > 1 else ""]
		stl.add_theme_color_override("font_color", AmTheme.col("WARM"))
		stl.add_theme_font_size_override("font_size", 12)
		stl.size_flags_horizontal = SIZE_EXPAND_FILL
		sh.add_child(stl)
		var full := str(sums[0]["text"])
		sh.add_child(_small("Read", func() -> void: _read(str(h["name"]), full)))
		var ex := Label.new()
		var lines := full.split("\n")
		ex.text = "\n".join(lines.slice(0, 5)) + ("\n…" if lines.size() > 5 else "")
		ex.add_theme_color_override("font_color", AmTheme.col("MUTED"))
		ex.add_theme_font_size_override("font_size", 12)
		ex.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sv.add_child(ex)
		v.add_child(sp)
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


func _read(title: String, text: String) -> void:
	read_dialog.title = "Summary · " + title
	read_text.text = text
	read_dialog.popup_centered(Vector2i(760, 560))


func _wrap_up(id: String) -> void:
	var r := await engine.call_api("POST", "/sessions/%s/wrapup" % id, {"archive": true})
	if r.has("error"):
		status_label.text = str(r["error"])
		return
	_toast("%s is writing its summary; it goes to History when done" % _session(id).get("name", ""))
	await refresh()


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


# ------------------------------------------------------------------ voice (Loop 10)
func _build_voice_overlay(area: Control) -> void:
	voice_overlay = PanelContainer.new()
	voice_overlay.set_anchors_preset(PRESET_CENTER_BOTTOM)
	voice_overlay.grow_horizontal = GROW_DIRECTION_BOTH
	voice_overlay.grow_vertical = GROW_DIRECTION_BEGIN
	voice_overlay.position.y = -40
	voice_overlay.visible = false
	voice_overlay.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL_2"), 14, AmTheme.col("MINT"), 1, 14))
	var v := VBoxContainer.new()
	voice_overlay.add_child(v)
	voice_label = Label.new()
	voice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	voice_label.add_theme_font_size_override("font_size", 15)
	v.add_child(voice_label)
	voice_meter = ProgressBar.new()
	voice_meter.custom_minimum_size = Vector2(360, 6)
	voice_meter.show_percentage = false
	voice_meter.max_value = 1.0
	v.add_child(voice_meter)
	area.add_child(voice_overlay)
	dictation.level.connect(func(x: float) -> void: voice_meter.value = lerpf(voice_meter.value, x * 3.0, 0.4))


func _voice_start() -> void:
	if dictation.recording or (voice_mode == "dictate" and (selected == "" or not terms.has(selected))):
		return
	if not dictation.available():
		_toast("No microphone found")
		return
	dictation.start()
	if voice_mode == "command":
		voice_label.text = "🎙  A command…  (« approve Themes », « go to Docs », « who is waiting? »)  release %s" % key_text("command")
	else:
		voice_label.text = "🎙  Listening to you for « %s »…  release %s to write it" % [_session(selected).get("name", ""), key_text("dictate")]
	voice_overlay.visible = true
	voice_overlay.reset_size()


func _voice_stop() -> void:
	if not dictation.recording:
		return
	var rec := dictation.stop()
	if float(rec["seconds"]) < 0.4:
		voice_overlay.visible = false
		return
	voice_label.text = "Writing it down…"
	var target := selected
	var r := await engine.call_api("POST", "/voice/transcribe", {"audio_b64": Marshalls.raw_to_base64(rec["wav"]), "seconds": rec["seconds"]})
	voice_overlay.visible = false
	if r.has("error"):
		_toast(str(r["error"]))
		if str(r["error"]).contains("Keys"):
			set_view("keys")
		return
	if voice_mode == "command":
		await run_voice_command(str(r.get("text", "")))
	else:
		on_transcribed(target, str(r.get("text", "")), float(r.get("cost_usd", 0)))


## The dictated text goes into the session's prompt as a paste: never with Enter. The owner reads, then sends.
func on_transcribed(id: String, text: String, cost: float) -> void:
	if text.strip_edges() == "" or not terms.has(id):
		return
	terms[id].paste_text(text.strip_edges())
	terms[id].grab_focus()
	_toast("Dictated into %s: read it, then Enter%s" % [_session(id).get("name", ""), ("   (≈ $%.4f)" % cost) if cost > 0 else ""])


# ------------------------------------------------------------------ voice commands and spoken status (Loop 11)
## Runs what was said. Actions that touch an agent always ask first (a visible confirmation).
func run_voice_command(text: String) -> void:
	if text.strip_edges() == "":
		return
	var c := await engine.call_api("POST", "/voice/command", {"text": text})
	var it := str(c.get("intent", "unknown"))
	var id := str(c.get("id", ""))
	var nm := str(c.get("name", ""))
	match it:
		"approve":
			_confirm("Approve « %s »?   (heard: « %s »)" % [nm, text], func() -> void: _keys(id, ["Enter"]))
		"refuse":
			_confirm("Refuse for « %s »?   (heard: « %s »)" % [nm, text], func() -> void: _keys(id, ["Escape"]))
		"wrap_up":
			_confirm("Wrap up « %s »: its summary, then archive?   (heard: « %s »)" % [nm, text], func() -> void: _wrap_up(id))
		"go_to":
			await select(id)
		"view":
			set_view(str(c["view"]))
		"waiting":
			var w := sessions.filter(func(x): return str(x.get("activity", "")) in ["approval", "waiting"])
			var line := "Nobody is waiting for you." if w.is_empty() else ", ".join(w.map(func(x): return "%s %s" % [x["name"], activity_of(x)[1]]))
			_toast(line)
			_speak(_spoken_waiting(w), true)
		"new_session":
			await _open_new()
			f_name.text = str(c.get("name", "")).capitalize()
		_:
			_toast("Heard « %s »: %s" % [text, c.get("reason", "not a command")])


func _speak(text: String, force := false) -> void:
	if not (spoken or force) or text == "":
		return
	last_spoken = text
	if OS.get_name() == "Linux" and not FileAccess.file_exists("/usr/bin/speech-dispatcher"):
		return  # no speech service on this Linux: the toast is enough
	var voices := DisplayServer.tts_get_voices_for_language("fr")
	if voices.is_empty():
		voices = DisplayServer.tts_get_voices_for_language("en")
	if voices.is_empty():
		return  # no system voice: the toast says it already
	DisplayServer.tts_stop()
	DisplayServer.tts_speak(text, voices[0])


func _spoken_waiting(w: Array) -> String:
	if w.is_empty():
		return "Personne ne t'attend."
	return ", ".join(w.map(func(x): return "%s %s" % [x["name"], "attend ton OK" if str(x["activity"]) == "approval" else "attend une réponse"])) + "."


func _speak_transition(x: Dictionary, act: String) -> void:
	match act:
		"approval": _speak("%s attend ton OK." % x["name"])
		"waiting": _speak("%s attend une réponse." % x["name"])
		"done": _speak("%s a fini." % x["name"])


func set_spoken(on: bool) -> void:
	spoken = on
	_save("spoken", on)
	_toast("Spoken status " + ("on: short spoken notices when an agent waits or finishes" if on else "off"))


# ------------------------------------------------------------------ cloud sandboxes (Loop 13)
func _sandboxes_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sbx_box = VBoxContainer.new()
	sbx_box.size_flags_horizontal = SIZE_EXPAND_FILL
	sbx_box.add_theme_constant_override("separation", 12)
	scroll.add_child(sbx_box)
	return scroll


func _load_sandboxes() -> void:
	var r := await engine.call_api("GET", "/sandboxes")
	if sbx_box == null or not is_instance_valid(sbx_box):
		return
	for c in sbx_box.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "Cloud sandboxes"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_font_override("font", AmTheme.ui_font(650))
	sbx_box.add_child(title)
	if r.has("error"):
		sbx_box.add_child(_muted(str(r["error"])))
		return
	var head := _muted("Fly.io · organisation %s · app %s · region %s · %s   ·   Agent Manager never destroys a sandbox on its own." % [
		r.get("org", "—") if str(r.get("org", "")) != "" else "—", r.get("app", "—") if str(r.get("app", "")) != "" else "—",
		r.get("region", "yyz"), "image ready" if r.get("ready", false) else "not prepared"])
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sbx_box.add_child(head)
	var job: Dictionary = r.get("job", {})
	if str(job.get("state", "")) == "preparing":
		sbx_box.add_child(_muted("⏳ Preparing: " + str(job.get("message", ""))))
		get_tree().create_timer(5.0).timeout.connect(func() -> void:
			if view == "sandboxes":
				_load_sandboxes())
	elif str(job.get("state", "")) == "error":
		var er := _muted("Preparing failed: " + str(job.get("message", "")))
		er.add_theme_color_override("font_color", AmTheme.col("ERROR"))
		er.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sbx_box.add_child(er)
	if not r.get("ready", false) and str(job.get("state", "")) != "preparing":
		var prep := Button.new()
		prep.text = "Prepare cloud sandboxes (once: an app and our image in your organisation)"
		prep.disabled = not (r.get("token", false) and r.get("flyctl", false))
		prep.tooltip_text = "" if not prep.disabled else "Paste the Fly.io token in Keys first"
		prep.pressed.connect(func() -> void:
			_toast("Preparing: Fly builds our image (about 2 minutes)…")
			await engine.call_api("POST", "/sandboxes/prepare", {})
			await _load_sandboxes())
		sbx_box.add_child(prep)
	var tot := Label.new()
	tot.text = "Estimated cost so far: $%.4f   (%s)" % [float(r.get("total_cost_usd", 0)), r.get("prices", "")]
	tot.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	tot.add_theme_font_size_override("font_size", 12)
	sbx_box.add_child(tot)
	sbx_box.add_child(_budget_panel(r))
	var finished: Array = (r.get("sandboxes", []) as Array).filter(func(x): return int(x["finished"]) == 1 and int(x["destroyed"]) == 0)
	if not finished.is_empty():
		sbx_box.add_child(_small("Destroy the finished ones (%d)…" % finished.size(), func() -> void:
			_confirm("Destroy %d finished sandbox(es): %s?\nTheir machines, files and keys are deleted for good." % [finished.size(), ", ".join(finished.map(func(x): return str(x["id"])))], func() -> void:
				for x in finished:
					await engine.call_api("POST", "/sandboxes/%s/destroy" % x["id"], {"confirmed": true})
				await refresh()
				await _load_sandboxes())))
	for sb in r.get("sandboxes", []):
		sbx_box.add_child(_sandbox_card(sb))
	var orph: Array = r.get("orphans", [])
	if not orph.is_empty():
		var ot := Label.new()
		ot.text = "Not known by this Agent Manager (listed, never touched)"
		ot.add_theme_font_override("font", AmTheme.ui_font(650))
		sbx_box.add_child(ot)
		for o in orph:
			var ol := _muted("• app %s %s %s   — destroy it from Fly's dashboard if you do not need it" % [o["app"], ("machine " + str(o["machine"])) if str(o["machine"]) != "" else "", ("(" + str(o["name"]) + ", " + str(o["state"]) + ")")])
			ol.add_theme_font_size_override("font_size", 12)
			sbx_box.add_child(ol)


func _budget_panel(r: Dictionary) -> Control:
	# Loop 14: a monthly budget (warning at 80 %, no new sandbox at 100 %), optional caps that only pause, "Stop everything"
	var b: Dictionary = r.get("budget", {})
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var spend := float(r.get("month_spend_usd", 0))
	var limit := float(b.get("monthly_usd", 0))
	var line := Label.new()
	line.add_theme_font_override("font", AmTheme.ui_font(650))
	if limit > 0:
		var pct := float(r.get("budget_percent", 0))
		line.text = "This month: $%.2f of $%.2f (%d %%)" % [spend, limit, int(pct)]
		if pct >= 100:
			line.text += "   — budget reached: no new sandbox this month"
			line.add_theme_color_override("font_color", AmTheme.col("ERROR"))
		elif pct >= 80:
			line.text += "   — over 80 %"
			line.add_theme_color_override("font_color", AmTheme.col("WARN"))
		box.add_child(line)
		var bar := ProgressBar.new()
		bar.max_value = 100
		bar.value = minf(pct, 100)
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 6)
		box.add_child(bar)
	else:
		line.text = "This month: $%.2f   (no budget set)" % spend
		box.add_child(line)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_muted("Monthly budget $"))
	var amt := SpinBox.new()
	amt.max_value = 10000
	amt.step = 1
	amt.value = limit
	amt.tooltip_text = "0 = no budget"
	row.add_child(amt)
	row.add_child(_muted("Pause a sandbox idle for"))
	var idle := SpinBox.new()
	idle.max_value = 1440
	idle.step = 5
	idle.value = int(b.get("stop_idle_minutes", 0))
	idle.suffix = "min"
	idle.tooltip_text = "0 = never (pause only, never destroy)"
	row.add_child(idle)
	var over := CheckBox.new()
	over.text = "Pause everything when the budget is reached"
	over.button_pressed = bool(b.get("stop_over_budget", false))
	row.add_child(over)
	row.add_child(_small("Save", func() -> void:
		var res := await engine.call_api("POST", "/sandboxes/budget", {"monthly_usd": amt.value, "stop_idle_minutes": int(idle.value), "stop_over_budget": over.button_pressed})
		_toast(str(res["error"]) if res.has("error") else "Budget saved")
		await _load_sandboxes()))
	box.add_child(row)
	var running: Array = (r.get("sandboxes", []) as Array).filter(func(x): return str(x["state"]) == "started")
	if not running.is_empty():
		box.add_child(_small("⏸ Stop everything (%d running)" % running.size(), func() -> void:
			_confirm("Pause the %d running sandbox(es)? Nothing is destroyed: start them again anytime." % running.size(), func() -> void:
				_toast("Pausing every sandbox…")
				await engine.call_api("POST", "/sandboxes/stop-all", {}, true, 300.0)
				await _load_sandboxes())))
	box.add_child(_muted(str(r.get("storage_note", ""))))
	return box


func _sandbox_card(sb: Dictionary) -> Control:
	var sbid := str(sb["id"])
	var st := str(sb["state"])
	var col: Color = {"started": AmTheme.col("MINT"), "stopped": AmTheme.col("WARN"), "destroyed": AmTheme.col("FAINT")}.get(st, AmTheme.col("ERROR"))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 10, Color(col, 0.6), 1, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	card.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	v.add_child(top)
	var sess := _session(str(sb["session_id"]))
	var n := Label.new()
	n.text = "☁ " + str(sess.get("name", "session " + str(sb["session_id"])))
	n.add_theme_font_size_override("font_size", 16)
	n.add_theme_font_override("font", AmTheme.ui_font(650))
	top.add_child(n)
	var chip := Label.new()
	chip.text = "● " + st + ("  · finished, ready to destroy" if int(sb["finished"]) == 1 and st != "destroyed" else "")
	chip.add_theme_color_override("font_color", col)
	chip.add_theme_font_size_override("font_size", 12)
	chip.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(chip)
	var secs := int(sb["running_seconds"])
	var meta := _muted("sandbox %s · machine %s · %s · %s · ran %dh%02dm · ≈ $%.4f · made %s" % [sbid, sb["machine"], sb["region"], sb["size"], secs / 3600, (secs % 3600) / 60, float(sb["cost_usd"]), _date(float(sb["created"]))])
	meta.add_theme_font_size_override("font_size", 12)
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(meta)
	var conn := _muted("Connection: not checked yet")
	conn.add_theme_font_size_override("font_size", 12)
	v.add_child(conn)
	if st != "destroyed":
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		v.add_child(row)
		row.add_child(_small("Open", func() -> void: select(str(sb["session_id"]))))
		row.add_child(_small("Check connection", func() -> void:
			conn.text = "Connection: checking…"
			var c := await engine.call_api("GET", "/sandboxes/%s/connection" % sbid, null, true, 90.0)
			conn.text = "Connection: machine %s · terminal %s · tunnel %s%s · Second Brain %s" % [c.get("machine", "?"), "open" if c.get("terminal", false) else "closed", c.get("tunnel", "?"), ("  (%d ms)" % int(c["latency_ms"])) if c.get("latency_ms") != null else "", {true: "reachable", false: "not reachable"}.get(c.get("brain"), "—")]))
		if st == "stopped":
			row.add_child(_small("Start", func() -> void:
				await engine.call_api("POST", "/sandboxes/%s/start" % sbid, {}, true, 120.0)
				await _load_sandboxes()))
		elif st == "started":
			row.add_child(_small("Stop (pause)", func() -> void:
				await engine.call_api("POST", "/sandboxes/%s/stop" % sbid, {}, true, 120.0)
				await _load_sandboxes()))
		row.add_child(_small("Not finished" if int(sb["finished"]) == 1 else "Mark finished", func() -> void:
			await engine.call_api("POST", "/sandboxes/%s/finish" % sbid, {"finished": int(sb["finished"]) == 0})
			await _load_sandboxes()))
		row.add_child(_small("Destroy…", func() -> void:
			_toast("Checking for work not pushed…")
			var u := await engine.call_api("GET", "/sandboxes/%s/unpushed" % sbid, null, true, 120.0)
			var rep := str(u.get("report", u.get("error", "")))
			var warn := "Nothing unsaved found." if u.get("clean", false) else ("Work that would be LOST:\n" + rep.left(900) if u.get("checked", false) else "Could not check the sandbox (%s): its work may be lost." % rep.left(200))
			_confirm("Destroy the sandbox of « %s »? Its machine, files and key are deleted for good.\n\n%s" % [sess.get("name", sbid), warn], func() -> void:
				var d := await engine.call_api("POST", "/sandboxes/%s/destroy" % sbid, {"confirmed": true}, true, 120.0)
				_toast(str(d.get("error", "Sandbox destroyed")))
				await refresh()
				await _load_sandboxes())))
	return card


# ------------------------------------------------------------------ usage (Loop 14)
func _usage_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	usage_box = VBoxContainer.new()
	usage_box.size_flags_horizontal = SIZE_EXPAND_FILL
	usage_box.add_theme_constant_override("separation", 12)
	scroll.add_child(usage_box)
	return scroll


static func _tok(n: int) -> String:
	if n >= 1_000_000:
		return "%.1fM" % (n / 1_000_000.0)
	if n >= 1000:
		return "%.1fk" % (n / 1000.0)
	return str(n)


func _load_usage() -> void:
	var r := await engine.call_api("GET", "/usage")
	if r.has("error") or usage_box == null or not is_instance_valid(usage_box):
		return
	for c in usage_box.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "Usage · tokens"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_font_override("font", AmTheme.ui_font(650))
	usage_box.add_child(title)
	var note := _muted(str(r.get("note", "")))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	usage_box.add_child(note)
	var tools: Dictionary = r.get("tools", {})
	var totals := HBoxContainer.new()
	totals.add_theme_constant_override("separation", 12)
	usage_box.add_child(totals)
	for t in [["claude", "✻ Claude Code"], ["codex", "◎ Codex"]]:
		var tile := PanelContainer.new()
		tile.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 10, AmTheme.col("BORDER"), 1, 14))
		var tv := VBoxContainer.new()
		tile.add_child(tv)
		tv.add_child(_muted(t[1]))
		var big := Label.new()
		big.text = _tok(int(tools.get(t[0], 0)))
		big.add_theme_font_size_override("font_size", 28)
		big.add_theme_font_override("font", AmTheme.ui_font(650))
		tv.add_child(big)
		tv.add_child(_muted("tokens, all sessions"))
		totals.add_child(tile)
	# tokens per day: one series, thin bars on a shared baseline, a value on hover
	var days: Array = (r.get("days", []) as Array).slice(maxi(0, (r.get("days", []) as Array).size() - 21))
	if not days.is_empty():
		usage_box.add_child(_muted("Tokens per day (last %d days with activity)" % days.size()))
		var chart := HBoxContainer.new()
		chart.custom_minimum_size = Vector2(0, 160)
		chart.add_theme_constant_override("separation", 4)
		chart.alignment = BoxContainer.ALIGNMENT_BEGIN
		var top := 1
		for d in days:
			top = maxi(top, int(d["total"]))
		for d in days:
			var col := VBoxContainer.new()
			col.custom_minimum_size = Vector2(34, 160)
			col.alignment = BoxContainer.ALIGNMENT_END
			var bar := Panel.new()
			var sb := StyleBoxFlat.new()
			sb.bg_color = AmTheme.col("INFO")
			sb.corner_radius_top_left = 4
			sb.corner_radius_top_right = 4
			bar.add_theme_stylebox_override("panel", sb)
			bar.custom_minimum_size = Vector2(26, maxf(2.0, 130.0 * int(d["total"]) / top))
			bar.size_flags_horizontal = SIZE_SHRINK_CENTER
			bar.tooltip_text = "%s · %s tokens (in %s, out %s, cache read %s, cache write %s)" % [d["day"], _tok(int(d["total"])), _tok(int(d.get("input", 0))), _tok(int(d.get("output", 0))), _tok(int(d.get("cache_read", 0))), _tok(int(d.get("cache_write", 0)))]
			col.add_child(bar)
			var dl := Label.new()
			dl.text = str(d["day"]).substr(5)
			dl.add_theme_font_size_override("font_size", 10)
			dl.add_theme_color_override("font_color", AmTheme.col("FAINT"))
			dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			col.add_child(dl)
			chart.add_child(col)
		usage_box.add_child(chart)
	# per session
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 22)
	grid.add_theme_constant_override("v_separation", 6)
	usage_box.add_child(grid)
	for h in ["Session", "Total", "Input", "Output", "Cache read", "Cache write"]:
		var hl := _muted(h)
		hl.add_theme_font_size_override("font_size", 12)
		grid.add_child(hl)
	for s0 in r.get("sessions", []):
		var tk: Dictionary = s0["tokens"]
		var name := Label.new()
		name.text = "%s %s%s" % [SessionCard.TOOL_BADGE.get(str(s0["tool"]), ["•"])[0], s0["name"], ("   (no log found)" if int(s0["logs_found"]) == 0 else "")]
		grid.add_child(name)
		for v in [s0["total"], tk.get("input", 0), tk.get("output", 0), tk.get("cache_read", 0), tk.get("cache_write", 0)]:
			var vl := Label.new()
			vl.text = _tok(int(v))
			vl.add_theme_font_override("font", font)
			vl.add_theme_font_size_override("font_size", 13)
			grid.add_child(vl)


# ------------------------------------------------------------------ keys (Loop 10)
func _keys_view() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = "Keys"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_font_override("font", AmTheme.ui_font(650))
	v.add_child(title)
	var intro := _muted("Paste your own API keys here. They are encrypted on this computer, never shown again, never written to a log; Agent Manager reads one only when a feature needs it (the voice, cloud sandboxes).")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(intro)
	keys_list = VBoxContainer.new()
	keys_list.add_theme_constant_override("separation", 10)
	v.add_child(keys_list)
	return v


func _load_keys() -> void:
	var r := await engine.call_api("GET", "/keys")
	if r.has("error") or keys_list == null or not is_instance_valid(keys_list):
		return
	for c in keys_list.get_children():
		c.queue_free()
	var prot := _muted("Protection: " + str(r.get("protection", "")))
	prot.add_theme_font_size_override("font_size", 12)
	keys_list.add_child(prot)
	for k in r["keys"]:
		keys_list.add_child(_key_card(k))


func _key_card(k: Dictionary) -> Control:
	var name := str(k["name"])
	var card := PanelContainer.new()
	var is_set := bool(k["set"])
	card.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 10, AmTheme.col("MINT") if is_set else AmTheme.col("BORDER"), 1, 14))
	var v := VBoxContainer.new()
	card.add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var l := Label.new()
	l.text = str(k["label"])
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_font_override("font", AmTheme.ui_font(650))
	top.add_child(l)
	var st := Label.new()
	st.text = ("   ● set on " + _date(float(k["set_at"]))) if is_set else "   ○ not set"
	st.add_theme_color_override("font_color", AmTheme.col("MINT") if is_set else AmTheme.col("FAINT"))
	st.add_theme_font_size_override("font_size", 12)
	st.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(st)
	v.add_child(_muted("Used for: " + str(k["use"])))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	var edit := LineEdit.new()
	edit.secret = true
	edit.placeholder_text = "paste a new key to replace it" if is_set else "paste the key"
	edit.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(edit)
	row.add_child(_small("Save", func() -> void:
		var value := edit.text
		edit.text = ""
		var r := await engine.call_api("POST", "/keys", {"name": name, "value": value})
		_toast(str(r.get("error", "Saved: %s (encrypted)" % k["label"])))
		await _load_keys()))
	if is_set:
		row.add_child(_small("Remove", func() -> void:
			_confirm("Remove the %s key from this computer?" % k["label"], func() -> void:
				await engine.call_api("DELETE", "/keys/" + name)
				await _load_keys())))
	return card


# ------------------------------------------------------------------ repositories (Loop 9)
func _repos_view() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = "Connected repositories"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_font_override("font", AmTheme.ui_font(650))
	v.add_child(title)
	var intro := _muted("Create the repository yourself (GitHub or any SSH git host), add its SSH address here: Agent Manager makes a deploy key for it only. Add that key on the repository (tick « Allow write access » so agents can push their branch), then Check.")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(intro)
	var form := HBoxContainer.new()
	form.add_theme_constant_override("separation", 8)
	v.add_child(form)
	var url := LineEdit.new()
	url.placeholder_text = "git@github.com:owner/repo.git"
	url.size_flags_horizontal = SIZE_EXPAND_FILL
	form.add_child(url)
	var path := LineEdit.new()
	path.placeholder_text = "local folder (optional: cloned on first use)"
	path.custom_minimum_size = Vector2(340, 0)
	form.add_child(path)
	var add := Button.new()
	add.text = "+ Add a repository"
	add.pressed.connect(func() -> void:
		var r := await engine.call_api("POST", "/repos", {"url": url.text.strip_edges(), "local_path": path.text.strip_edges()})
		if r.has("error"):
			_toast(str(r["error"]))
			return
		url.text = ""
		path.text = ""
		await _load_repos())
	form.add_child(add)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	repos_list = VBoxContainer.new()
	repos_list.size_flags_horizontal = SIZE_EXPAND_FILL
	repos_list.add_theme_constant_override("separation", 10)
	scroll.add_child(repos_list)
	return v


func _load_repos() -> void:
	var r := await engine.call_api("GET", "/repos")
	if r.has("error") or repos_list == null or not is_instance_valid(repos_list):
		return
	repos_cache = r["repos"]
	for c in repos_list.get_children():
		c.queue_free()
	for repo in repos_cache:
		repos_list.add_child(_repo_card(repo))
	if repos_cache.is_empty():
		repos_list.add_child(_muted("No repository yet."))


func _repo_card(r: Dictionary) -> Control:
	var rid := str(r["id"])
	var st := str(r["status"])
	var col: Color = {"connected": AmTheme.col("MINT"), "failed": AmTheme.col("ERROR")}.get(st, AmTheme.col("WARN"))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 10, Color(col, 0.55), 1, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	card.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	v.add_child(top)
	var n := Label.new()
	n.text = "⎇ " + str(r["name"])
	n.add_theme_font_size_override("font_size", 16)
	n.add_theme_font_override("font", AmTheme.ui_font(650))
	top.add_child(n)
	var chip := Label.new()
	chip.text = {"connected": "● connected", "failed": "● the key does not work", "waiting": "● waiting for the key on the repository"}.get(st, st)
	chip.add_theme_color_override("font_color", col)
	chip.add_theme_font_size_override("font_size", 12)
	chip.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(chip)
	top.add_child(_small("New session on it", func() -> void:
		await _open_new()
		for i in f_repo.item_count:
			if str(f_repo.get_item_metadata(i)) == rid:
				f_repo.select(i)
				f_repo.item_selected.emit(i)
		f_name.text = str(r["name"])))
	var meta := _muted("%s   ·   %s   ·   key %s   ·   added %s%s" % [r["url"], (str(r["local_path"]) + (" (cloned)" if r["cloned"] else " (not cloned yet)")) if str(r["local_path"]) != "" else "cloned on first use", r["fingerprint"], _date(float(r["created"])), ("   ·   last used " + _date(float(r["last_used"]))) if float(r["last_used"]) > 0 else ""])
	meta.add_theme_font_size_override("font_size", 12)
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(meta)
	if str(r["message"]) != "":
		var m := Label.new()
		m.text = str(r["message"])
		m.add_theme_color_override("font_color", col)
		m.add_theme_font_size_override("font_size", 12)
		m.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(m)
	var key := LineEdit.new()
	key.text = str(r["public_key"])
	key.editable = false
	key.add_theme_font_override("font", font)
	key.add_theme_font_size_override("font_size", 11)
	key.tooltip_text = "The PUBLIC key: safe to copy. The private key never leaves Agent Manager's data folder."
	v.add_child(key)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	var pub := str(r["public_key"])
	row.add_child(_small("Copy the public key", func() -> void:
		DisplayServer.clipboard_set(pub)
		_toast("Public key copied: add it as a deploy key on the repository")))
	if str(r["deploy_keys_page"]) != "":
		var page := str(r["deploy_keys_page"])
		row.add_child(_small("Open GitHub's Deploy keys page", func() -> void: OS.shell_open(page)))
	row.add_child(_small("Check", func() -> void:
		var c := await engine.call_api("POST", "/repos/%s/check" % rid, {})
		_toast("%s: %s" % [r["name"], c.get("status", c.get("error", ""))])
		await _load_repos()))
	row.add_child(_small("Rotate the key", func() -> void:
		_confirm("Make a new key for %s? The old one stops being used here; delete it on the repository." % r["name"], func() -> void:
			await engine.call_api("POST", "/repos/%s/rotate" % rid, {})
			await _load_repos())))
	row.add_child(_small("Disconnect", func() -> void:
		_confirm("Disconnect %s? Its key is deleted here (delete it on the repository too). Its sessions stay in History." % r["name"], func() -> void:
			var d := await engine.call_api("POST", "/repos/%s/disconnect" % rid, {})
			_toast(str(d.get("reminder", d.get("error", ""))))
			await _load_repos())))
	var sess: Array = r.get("sessions", [])
	if not sess.is_empty():
		var l := _muted("Sessions on it: " + ", ".join(sess.map(func(x): return str(x["name"]) + (" (archived)" if int(x["archived"]) == 1 else ""))))
		l.add_theme_font_size_override("font_size", 12)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(l)
	return card


func _confirm(text: String, done: Callable) -> void:
	confirm_dialog.dialog_text = text
	confirm_done = done
	confirm_dialog.popup_centered()


# ------------------------------------------------------------------ review (Loop 8)
func _review_view() -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(270, 0)
	root.add_child(left)
	var mode := OptionButton.new()
	for m in [["uncommitted", "Uncommitted changes"], ["session", "Since the session started"], ["branch", "Its branch vs the target"]]:
		mode.add_item(m[1])
		mode.set_item_metadata(mode.item_count - 1, m[0])
		if m[0] == review_mode:
			mode.select(mode.item_count - 1)
	mode.item_selected.connect(func(i: int) -> void:
		review_mode = str(mode.get_item_metadata(i))
		review_file = 0
		_load_review())
	left.add_child(mode)
	review_info = Label.new()
	review_info.add_theme_font_size_override("font_size", 12)
	review_info.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	review_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(review_info)
	review_files = ItemList.new()
	review_files.size_flags_vertical = SIZE_EXPAND_FILL
	review_files.add_theme_font_override("font", font)
	review_files.add_theme_font_size_override("font_size", 12)
	review_files.item_selected.connect(func(i: int) -> void:
		review_file = i
		_render_review_file())
	left.add_child(review_files)
	var row := HBoxContainer.new()
	left.add_child(row)
	row.add_child(_small("Refresh", _load_review))
	row.add_child(_small("Comment the file…", func() -> void: _comment_on(_review_path(), 0, "")))
	review_send = Button.new()
	review_send.text = "Send review"
	review_send.tooltip_text = "The open comments, as one numbered request to the agent"
	review_send.pressed.connect(_send_review)
	left.add_child(review_send)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	root.add_child(scroll)
	review_lines = VBoxContainer.new()
	review_lines.size_flags_horizontal = SIZE_EXPAND_FILL
	review_lines.add_theme_constant_override("separation", 0)
	scroll.add_child(review_lines)
	return root


func _review_path() -> String:
	var files: Array = review_data.get("files", [])
	return str(files[review_file]["path"]) if review_file < files.size() else ""


func _load_review() -> void:
	if selected == "" or review_files == null or not is_instance_valid(review_files):
		return
	var r := await engine.call_api("GET", "/sessions/%s/diff?mode=%s" % [selected, review_mode])
	if not is_instance_valid(review_files):
		return
	if r.has("error"):
		review_data = {}
		review_info.text = str(r["error"])
		review_files.clear()
		for c in review_lines.get_children():
			c.queue_free()
		return
	review_data = r
	review_files.clear()
	var comments: Array = r.get("comments", [])
	for f in r["files"]:
		var n := comments.filter(func(c): return str(c["path"]) == str(f["path"]) and str(c["status"]) != "handled").size()
		var mark: String = {"added": "A", "deleted": "D", "renamed": "R"}.get(str(f["status"]), "M")
		review_files.add_item("%s %s  +%d −%d%s" % [mark, f["path"], int(f["additions"]), int(f["deletions"]), ("  ✎%d" % n) if n else ""])
	var open_n := comments.filter(func(c): return str(c["status"]) == "open").size()
	review_info.text = "%s · %d file(s) · +%d −%d%s" % [_session(selected).get("name", ""), (r["files"] as Array).size(), int(r.get("additions", 0)), int(r.get("deletions", 0)), ("\n" + str(r["note"])) if r.has("note") else ""]
	review_send.text = "Send review (%d)" % open_n
	review_send.disabled = open_n == 0
	if review_files.item_count > 0:
		review_file = mini(review_file, review_files.item_count - 1)
		review_files.select(review_file)
	_render_review_file()


func _render_review_file() -> void:
	for c in review_lines.get_children():
		c.queue_free()
	var files: Array = review_data.get("files", [])
	if review_file >= files.size():
		var none := Label.new()
		none.text = "No change to review." if review_data.has("files") else ""
		none.add_theme_color_override("font_color", AmTheme.col("MUTED"))
		review_lines.add_child(none)
		return
	var f: Dictionary = files[review_file]
	var comments: Array = (review_data.get("comments", []) as Array).filter(func(c): return str(c["path"]) == str(f["path"]))
	var title := Label.new()
	title.text = "%s%s" % [f["path"], ("   (renamed from %s)" % f["old_path"]) if str(f["status"]) == "renamed" else ""]
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_font_override("font", AmTheme.ui_font(650))
	review_lines.add_child(title)
	for c in comments.filter(func(x): return int(x["line"]) == 0):
		review_lines.add_child(_comment_card(c))
	if f.get("binary", false):
		review_lines.add_child(_muted("Binary file: not shown."))
	var plus := Color("3fb950", 0.16) if not AmTheme.is_light() else Color("2e7d32", 0.14)
	var minus := Color("f85149", 0.16) if not AmTheme.is_light() else Color("c62828", 0.12)
	for h in f["hunks"]:
		var hd := Label.new()
		hd.text = str(h["header"])
		hd.add_theme_font_override("font", font)
		hd.add_theme_font_size_override("font_size", 12)
		hd.add_theme_color_override("font_color", AmTheme.col("INFO"))
		review_lines.add_child(hd)
		for l in h["lines"]:
			var t := str(l["t"])
			var rowp := PanelContainer.new()
			rowp.add_theme_stylebox_override("panel", AmTheme.box(plus if t == "+" else (minus if t == "-" else Color(0, 0, 0, 0)), 0, Color(0, 0, 0, 0), 0, 1))
			rowp.mouse_filter = MOUSE_FILTER_STOP
			rowp.mouse_default_cursor_shape = CURSOR_POINTING_HAND
			rowp.tooltip_text = "Click to comment this line"
			var hb := HBoxContainer.new()
			hb.mouse_filter = MOUSE_FILTER_IGNORE
			rowp.add_child(hb)
			for n in [l["old"], l["new"]]:
				var nl := Label.new()
				nl.text = str(int(n)) if int(n) > 0 else ""
				nl.custom_minimum_size = Vector2(44, 0)
				nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				nl.add_theme_font_override("font", font)
				nl.add_theme_font_size_override("font_size", 12)
				nl.add_theme_color_override("font_color", AmTheme.col("FAINT"))
				nl.mouse_filter = MOUSE_FILTER_IGNORE
				hb.add_child(nl)
			var code := Label.new()
			code.text = " %s %s" % [t if t != " " else " ", str(l["text"]).replace("\t", "    ")]
			code.add_theme_font_override("font", font)
			code.add_theme_font_size_override("font_size", 13)
			code.add_theme_color_override("font_color", AmTheme.col("TEXT"))
			code.mouse_filter = MOUSE_FILTER_IGNORE
			hb.add_child(code)
			var line_no := int(l["new"]) if int(l["new"]) > 0 else int(l["old"])
			var path := str(f["path"])
			var text := str(l["text"])
			rowp.gui_input.connect(func(e: InputEvent) -> void:
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					_comment_on(path, line_no, text))
			review_lines.add_child(rowp)
			if t != "-":
				for c in comments.filter(func(x): return int(x["line"]) == int(l["new"]) and int(l["new"]) > 0):
					review_lines.add_child(_comment_card(c))
	if f.get("truncated", false):
		review_lines.add_child(_muted("… the rest of this file is not shown (too long)."))


func _comment_card(c: Dictionary) -> Control:
	var st := str(c["status"])
	var col: Color = {"open": AmTheme.col("WARN"), "sent": AmTheme.col("INFO"), "handled": AmTheme.col("FAINT")}.get(st, AmTheme.col("MUTED"))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", AmTheme.box(Color(col, 0.10), 8, Color(col, 0.6), 1, 8))
	var h := HBoxContainer.new()
	card.add_child(h)
	var l := Label.new()
	l.text = "✎ %s   · %s" % [c["text"], {"open": "to send", "sent": "sent to the agent", "handled": "handled"}.get(st, st)]
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 13)
	h.add_child(l)
	var cid := int(c["id"])
	if st == "open":
		h.add_child(_small("Delete", func() -> void: _set_comment({"id": cid, "delete": true})))
	elif st == "sent":
		h.add_child(_small("Handled", func() -> void: _set_comment({"id": cid, "status": "handled"})))
	return card


func _comment_on(path: String, line: int, code: String) -> void:
	if path == "":
		return
	_ask("Comment on %s%s" % [path, (":%d" % line) if line else ""], "", func(t: String) -> void:
		var r := await engine.call_api("POST", "/sessions/%s/comments" % selected, {"path": path, "line": line, "code": code, "text": t})
		if r.has("error"):
			status_label.text = str(r["error"])
		await _load_review())


func _set_comment(body: Dictionary) -> void:
	await engine.call_api("POST", "/sessions/%s/comment" % selected, body)
	await _load_review()


func _send_review() -> void:
	var r := await engine.call_api("POST", "/sessions/%s/review" % selected, {})
	if r.has("error"):
		status_label.text = str(r["error"])
		_toast(str(r["error"]))
		return
	_toast("Review sent to %s: %d point(s)" % [_session(selected).get("name", ""), int(r["sent"])])
	await _load_review()


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
	items.append({"label": "Review the changes", "hint": "diff and line comments · Ctrl+Shift+R", "run": set_view.bind("review")})
	items.append({"label": "Repositories", "hint": "connected repositories and deploy keys", "run": set_view.bind("repos")})
	items.append({"label": "Keys", "hint": "your API keys: OpenAI (voice), Fly.io, Anthropic", "run": set_view.bind("keys")})
	items.append({"label": "Usage", "hint": "tokens per session and per day, from the agents' logs", "run": set_view.bind("usage")})
	items.append({"label": "Sandboxes", "hint": "cloud sandboxes: manager, connections, costs", "run": set_view.bind("sandboxes")})
	items.append({"label": "Dictate (hold %s)" % key_text("dictate"), "hint": "speak into the active session; you press Enter", "run": func() -> void: _toast("Hold %s and speak, release to write it into the prompt" % key_text("dictate"))})
	items.append({"label": "Voice command (hold %s)" % key_text("command"), "hint": "« approve Themes », « go to Docs », « who is waiting? »", "run": func() -> void: _toast("Hold %s and say a command" % key_text("command"))})
	items.append({"label": "Shortcuts", "hint": "change the keyboard shortcuts", "run": set_view.bind("shortcuts")})
	items.append({"label": "Connect other tools (MCP)", "hint": "Agent Manager's MCP for Claude Code, Codex, any MCP client", "run": set_view.bind("connect")})
	items.append({"label": "Setup check", "hint": "python3, tmux, git, ssh, agents, flyctl: found or not", "run": set_view.bind("setup")})
	items.append({"label": "Spoken status: " + ("turn off" if spoken else "turn on"), "hint": "short spoken notices", "run": func() -> void: set_spoken(not spoken)})
	items.append({"label": "New session", "hint": key_text("new"), "run": _open_new})
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
		if str(_session(selected).get("tool", "")) != "shell":
			items.append({"label": "Wrap up " + sname, "hint": "its own summary, then archive", "run": func() -> void: _wrap_up(sid2)})
		items.append({"label": "Restart " + sname + " fresh", "hint": "a new conversation", "run": _restart})
		items.append({"label": "Rename " + str(_session(selected).get("name", "")), "hint": "", "run": func() -> void: _rename_session(selected)})
	palette.open(items)


# ------------------------------------------------------------------ actions
func _create() -> void:
	if str(f_where.get_selected_metadata()) == "sandbox":
		_toast("Starting a cloud sandbox… (about 30 seconds)")
	var name := f_name.text.strip_edges()
	if name == "":
		name = str(f_tool.get_item_text(f_tool.selected)).substr(3)
	var r := await engine.call_api("POST", "/sessions", {"name": name, "tool": f_tool.get_selected_metadata(), "cwd": f_cwd.text.strip_edges(), "group": str(f_group.get_selected_metadata()) if f_group.item_count > 0 else "", "worktree": f_worktree.button_pressed, "brain": f_brain.button_pressed, "brief": f_brief.button_pressed and not f_brief.disabled, "repo": str(f_repo.get_selected_metadata()) if f_repo.item_count > 0 else "", "host": str(f_where.get_selected_metadata())}, true, 240.0 if str(f_where.get_selected_metadata()) == "sandbox" else 30.0)
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
	row_menu.add_item("Wrap up: its summary, then archive", 11)
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
		row_menu.set_item_disabled(row_menu.get_item_index(9), str(s.get("worktree", "")) == "")
		row_menu.set_item_disabled(row_menu.get_item_index(11), not agent or str(s.get("state", "")) != "running"))
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
	theme_menu.add_separator()
	theme_menu.add_item("Spoken status (on / off)")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__spoken")
	theme_menu.add_item("Usage…")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__usage")
	theme_menu.add_item("Keys…")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__keys")
	theme_menu.add_item("Shortcuts…")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__shortcuts")
	theme_menu.add_item("Connect other tools (MCP)…")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__connect")
	theme_menu.add_item("Setup check…")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__setup")
	theme_menu.index_pressed.connect(func(i: int) -> void:
		var m := str(theme_menu.get_item_metadata(i))
		if m == "__keys":
			set_view("keys")
		elif m in ["__shortcuts", "__connect", "__setup"]:
			set_view(m.substr(2))
		elif m == "__usage":
			set_view("usage")
		elif m == "__spoken":
			set_spoken(not spoken)
		else:
			set_theme_name(m))
	add_child(theme_menu)
	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.title = "Please confirm"
	confirm_dialog.dialog_autowrap = true
	confirm_dialog.min_size = Vector2i(460, 0)
	confirm_dialog.confirmed.connect(func() -> void:
		if confirm_done.is_valid():
			confirm_done.call())
	add_child(confirm_dialog)
	read_dialog = AcceptDialog.new()
	read_text = RichTextLabel.new()
	read_text.custom_minimum_size = Vector2(700, 460)
	read_text.selection_enabled = true
	read_text.add_theme_color_override("default_color", AmTheme.col("TEXT"))
	read_dialog.add_child(read_text)
	add_child(read_dialog)
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
	if mid == 11:
		_wrap_up(menu_target)
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


# ------------------------------------------------------------------ Loop 15: setup check, shortcuts, connect other tools
func _page(rows: Array) -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	for r in rows:
		if r is Button:
			r.size_flags_horizontal = SIZE_SHRINK_BEGIN
		box.add_child(r)
	scroll.add_child(box)
	return scroll


func _title(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_font_override("font", AmTheme.ui_font(650))
	return l


func _wrap(t: String) -> Label:
	var l := _muted(t)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Read-only: runs engine/doctor.sh where tmux lives (WSL on Windows). Nothing is installed or downloaded.
func setup_check() -> Dictionary:
	var out := []
	var argv := engine.host_command(["bash", "-l", engine.engine_root().path_join("engine/doctor.sh")])
	var code := OS.execute(argv[0], argv.slice(1), out, true)
	var found := {}
	if code == 0:
		for line in str(out[0] if out.size() else "").split("\n", false):
			var kv := line.split("=", true, 1)
			if kv.size() == 2:
				var pv := kv[1].split("|")
				found[kv[0]] = {"path": pv[0], "version": pv[1] if pv.size() > 1 else ""}
	return {"code": code, "found": found}


const SETUP_ITEMS := [
	["python3", true, "Runs the engine (3.10 or newer).", "sudo apt install python3"],
	["tmux", true, "Keeps every session alive when the app closes.", "sudo apt install tmux"],
	["git", true, "Branches per session, review, connected repositories.", "sudo apt install git"],
	["ssh", true, "Connected repositories and cloud sandboxes.", "sudo apt install openssh-client"],
	["claude", false, "Claude Code, your own install and login.", "see docs.anthropic.com (Claude Code)"],
	["codex", false, "Codex CLI, your own install and login.", "see github.com/openai/codex"],
	["flyctl", false, "Only for cloud sandboxes.", "the app asks before downloading it (pinned version, checksum checked)"],
]


func _setup_rows() -> Array:
	var rows: Array = [_title("Setup check"),
		_wrap("What Agent Manager GD needs%s. This check only looks: it installs and downloads nothing. Run the commands yourself in a terminal." % (" inside WSL" if engine.on_windows else ""))]
	var r := setup_check()
	if int(r["code"]) != 0:
		var msg := "WSL does not answer. Install it once from an administrator PowerShell: wsl --install (Microsoft's own installer), then restart." if engine.on_windows else "bash did not run the check (exit %d)." % int(r["code"])
		var er := _wrap(msg)
		er.add_theme_color_override("font_color", AmTheme.col("ERROR"))
		rows.append(er)
		return rows
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 8)
	var missing_required := false
	for it in SETUP_ITEMS:
		var f: Dictionary = r["found"].get(it[0], {"path": "", "version": ""})
		var ok := str(f["path"]) != ""
		if it[0] == "python3" and ok and str(f["version"]) != "":
			var v := str(f["version"]).split(".")
			ok = int(v[0]) > 3 or (int(v[0]) == 3 and int(v[1]) >= 10)
		missing_required = missing_required or (it[1] and not ok)
		var mark := Label.new()
		mark.text = "✓" if ok else ("✗" if it[1] else "–")
		mark.add_theme_color_override("font_color", AmTheme.col("MINT") if ok else (AmTheme.col("ERROR") if it[1] else AmTheme.col("FAINT")))
		grid.add_child(mark)
		var name := Label.new()
		name.text = "%s %s" % [it[0], str(f["version"])]
		name.add_theme_font_override("font", AmTheme.ui_font(650))
		grid.add_child(name)
		grid.add_child(_muted(("" if it[1] else "optional · ") + str(it[2])))
		grid.add_child(_muted(str(f["path"]) if ok else str(it[3])))
	rows.append(grid)
	rows.append(_wrap("Everything needed is there." if not missing_required else "Install what is marked ✗, then press Check again."))
	var again := _small("Check again", func() -> void:
		_layout_view()
		if not engine.connected and await engine.connect_engine():
			status_label.text = "Engine started."
			await refresh())
	rows.append(again)
	return rows


func _shortcut_rows() -> Array:
	var rows: Array = [_title("Shortcuts"),
		_wrap("Click a shortcut, then press the new keys (Escape cancels). In a terminal, Ctrl shortcuts act only with Shift added (Ctrl+Shift+K), so the terminal keeps its own keys. The voice keys are held: one key, no modifier.")]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	for a in DEFAULT_KEYS:
		grid.add_child(_muted(str(KEY_LABELS[a])))
		var action: String = a
		var b := Button.new()
		b.text = "Press the new keys…" if key_capture == a else key_text(a)
		b.custom_minimum_size = Vector2(200, 0)
		b.pressed.connect(func() -> void:
			key_capture = action
			_layout_view())
		grid.add_child(b)
	rows.append(grid)
	rows.append(_small("Back to the defaults", func() -> void:
		for a in DEFAULT_KEYS:
			_save_key(a, DEFAULT_KEYS[a])
		_layout_view()))
	return rows


## The Agent Manager MCP for tools outside the app (Claude Code, Codex, any MCP client): they may look at sessions
## and start new ones; they can never type into a session (that stays with a session's own parent agent).
func connect_commands() -> Dictionary:
	var script := engine.engine_root().path_join("engine/mcp_agents.py")
	var cmd := ["wsl.exe", "-e", "python3", script] if engine.on_windows else ["python3", script]
	var cfg := {"mcpServers": {"agent-manager": {"command": cmd[0], "args": cmd.slice(1)}}}
	return {
		"claude": "claude mcp add --scope user agent-manager -- %s" % " ".join(cmd),
		"codex": "[mcp_servers.agent-manager]\ncommand = \"%s\"\nargs = %s" % [cmd[0], JSON.stringify(cmd.slice(1))],
		"json": JSON.stringify(cfg, "  "),
	}


func _connect_rows() -> Array:
	var c := connect_commands()
	var rows: Array = [_title("Connect other tools to Agent Manager (MCP)"),
		_wrap("Sessions inside Agent Manager already have it. Plug it into a tool you run elsewhere: it can list sessions, read their screens and state, and start new sessions; it can never type into a session or approve anything. Local only: it talks to the engine on this computer with its own token.")]
	for item in [["Claude Code (run in a terminal)", "claude"], ["Codex (~/.codex/config.toml)", "codex"], ["Any MCP client (JSON)", "json"]]:
		var h := Label.new()
		h.text = item[0]
		h.add_theme_font_override("font", AmTheme.ui_font(650))
		rows.append(h)
		var te := TextEdit.new()
		te.text = c[item[1]]
		te.editable = false
		te.custom_minimum_size = Vector2(0, 40 + 25 * te.text.count("\n"))
		te.scroll_fit_content_height = true
		te.add_theme_font_override("font", font)
		rows.append(te)
		var txt: String = c[item[1]]
		rows.append(_small("Copy", func() -> void:
			DisplayServer.clipboard_set(txt)
			_toast("Copied")))
	return rows
