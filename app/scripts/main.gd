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
var dismissed := {}         # session id -> the request (its « since ») you closed with ✕: off the queue, still on its card
var notified := {}          # session id -> the request already announced: one toast, one flash, one chime per request
var sound_on := true
var chime: AudioStreamPlayer
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
var f_remote: CheckBox
var f_level: OptionButton
var level_menu: PopupMenu
const LEVELS := {  # Loop 24: [menu label, card badge, what it means]
	"ask": ["Ask before acting", "asks first", "Asks before editing files or running commands"],
	"edits": ["Auto edits (asks for commands)", "auto edits", "Edits files without asking; asks before other commands"],
	"auto": ["Auto (Claude Code decides, its default)", "", "Claude Code's own judgment decides what needs your OK (Codex: works in its folder without asking)"],
	"full": ["No permission (skips every prompt)", "⚠ no permission", "Never asks: runs everything. Your keys, ~/.ssh and .env files stay out of reach of its file tools"],
}
var f_document: CheckBox
var f_browse: Button
var folder_dialog: FileDialog
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
var brain := {}             # GET /brain/activity: the Brain, each session's key and what it did with it (never a key)
var brain_seen := {}        # session id -> calls + proposals at the last check, to make its ✦ glow when it used the Brain
var brain_badge: Button
var brain_panel: PanelContainer
var brain_glyph: Label
var brain_line1: Label
var brain_line2: Label
var header_brain: Button
var orch_btn: Button
var orch_panel: PanelContainer   # Loop 25: the orchestrator, on the right (Ctrl+O): its terminal, its question, its sessions
var orch_head: Label
var orch_state: Label
var orch_start: Button
var orch_stop: Button
var orch_term_box: VBoxContainer
var orch_hint: Label
var orch_list: VBoxContainer
var orch_plan: VBoxContainer
var orch_brain: Label
var orch_sig := ""
var orch_min := false
var orch_tab := "terminal"   # what fills the window: its terminal, its plan or its sessions
var orch_tabs := {}          # tab name -> its button
var orch_lists: ScrollContainer
var orch_sub: Label        # minimised: only its title bar shows
var orch_body: Array = []    # what hides when it is minimised
var orch_drag := ""          # "move" or "size" while the mouse drags its title bar or its corner          # what the panel shows: rebuilt only when it changes (a rebuild resized the terminal: it jumped)
var orch_foot: Label
var orch_data := {}          # GET /orchestrator: its plan, the routing rules, the budget and today's tokens
var rules_dialog: AcceptDialog
var rules_rows: VBoxContainer
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
	if view in ["setup", "shortcuts", "connect"]:  # settings pages are not reopened at startup
		view = "focus"
	spoken = bool(cfg.get_value("ui", "spoken", false))
	sound_on = bool(cfg.get_value("ui", "sound", true))
	_load_keymap()
	theme = AmTheme.build()
	font = TermFont.make()
	_build()
	_build_orch_panel()
	engine = EngineClient.new()
	add_child(engine)
	status_label.text = "Starting the engine…"
	if not await engine.connect_engine():
		status_label.text = "The engine did not start: see the setup check."
		set_view("setup")
		return
	status_label.text = "%s for commands" % key_text("palette")
	await refresh_brain()
	var brain_timer := Timer.new()  # the Brain is checked again every 10 s: the badge and the ✦ lights always tell the truth
	brain_timer.wait_time = 10.0
	brain_timer.autostart = true
	brain_timer.timeout.connect(refresh_brain)
	brain_timer.timeout.connect(refresh_orchestrator)
	add_child(brain_timer)
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
	"dictate": "F8", "command": "F9", "orchestrator": "Ctrl+O"}
const KEY_LABELS := {"palette": "Command palette", "new": "New session", "focus": "Focus view", "grid": "Grid view",
	"board": "Board view", "history": "History", "review": "Review", "next": "Next session", "prev": "Previous session",
	"approve": "Approve the first session waiting for an OK", "dictate": "Hold to dictate (voice)",
	"command": "Hold for a voice command", "orchestrator": "Show or hide the orchestrator"}
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
		"orchestrator": toggle_orchestrator()


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
	brain_badge = Button.new()
	brain_badge.custom_minimum_size = Vector2(0, 54)
	brain_badge.tooltip_text = "The Second Brain: who holds a key, what the sessions proposed"
	brain_badge.pressed.connect(_toggle_brain_panel)
	side_box.add_child(brain_badge)
	var bh := HBoxContainer.new()
	bh.set_anchors_and_offsets_preset(PRESET_FULL_RECT, PRESET_MODE_MINSIZE, 10)
	bh.add_theme_constant_override("separation", 10)
	bh.mouse_filter = MOUSE_FILTER_IGNORE
	brain_badge.add_child(bh)
	brain_glyph = Label.new()
	brain_glyph.text = "✦"
	brain_glyph.add_theme_font_size_override("font_size", 24)
	brain_glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	brain_glyph.pivot_offset = Vector2(9, 16)
	bh.add_child(brain_glyph)
	var bv := VBoxContainer.new()
	bv.alignment = BoxContainer.ALIGNMENT_CENTER
	bv.add_theme_constant_override("separation", 0)
	bv.mouse_filter = MOUSE_FILTER_IGNORE
	bh.add_child(bv)
	brain_line1 = Label.new()
	brain_line1.text = "Second Brain · checking…"
	brain_line1.add_theme_font_size_override("font_size", 13)
	brain_line1.add_theme_font_override("font", AmTheme.ui_font(650))
	bv.add_child(brain_line1)
	brain_line2 = Label.new()
	brain_line2.add_theme_font_size_override("font_size", 11)
	bv.add_child(brain_line2)
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
	header_brain = Button.new()
	header_brain.flat = true
	header_brain.add_theme_font_size_override("font_size", 12)
	header_brain.pressed.connect(_toggle_brain_panel)
	hb.add_child(header_brain)
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
	orch_btn = Button.new()  # Loop 25: shows or hides the orchestrator's panel on the right
	orch_btn.text = "◆ Orchestrator · beta"
	orch_btn.tooltip_text = "The orchestrator: it plans, starts sessions and hands you their work (%s)" % key_text("orchestrator")
	orch_btn.toggle_mode = true
	orch_btn.pressed.connect(toggle_orchestrator)
	hb.add_child(orch_btn)
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
	toast.z_index = 10  # above the floating orchestrator
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
		f_browse.disabled = on  # a connected repository has its own folder
		if on:
			for r in repos_cache:
				if str(r["id"]) == str(f_repo.get_selected_metadata()):
					f_cwd.text = str(r["local_path"]) if str(r["local_path"]) != "" else "(cloned on first use)"
		_check_brief())
	g.add_child(f_repo)
	g.add_child(_muted("Folder"))
	var cwd_row := HBoxContainer.new()
	cwd_row.add_theme_constant_override("separation", 6)
	f_cwd = LineEdit.new()
	f_cwd.text = "~"
	f_cwd.placeholder_text = "C:\\git-2026\\my-project or ~/my-project"
	f_cwd.size_flags_horizontal = SIZE_EXPAND_FILL
	cwd_row.add_child(f_cwd)
	f_browse = Button.new()
	f_browse.text = "Browse…"
	f_browse.tooltip_text = "Pick the folder (a Windows folder, or one in WSL through \\\\wsl.localhost)"
	f_browse.pressed.connect(_pick_folder)
	cwd_row.add_child(f_browse)
	g.add_child(cwd_row)
	g.add_child(Control.new())
	f_worktree = CheckBox.new()
	f_worktree.text = "In its own git branch (a worktree beside the repository)"
	f_worktree.tooltip_text = "The session works in <repository>-worktrees/<name> on branch am/<name>; Finish merges it back."
	g.add_child(f_worktree)
	var lv_label := Label.new()
	lv_label.text = "Permissions"
	g.add_child(lv_label)
	f_level = OptionButton.new()
	for k in LEVELS:
		f_level.add_item(LEVELS[k][0])
		f_level.set_item_metadata(f_level.item_count - 1, k)
		f_level.set_item_tooltip(f_level.item_count - 1, LEVELS[k][2])
	f_level.select(2)
	f_level.tooltip_text = "What the agent may do without asking you. Paths with your keys are refused at every level. A session started by an agent never gets more than its parent."
	g.add_child(f_level)
	g.add_child(Control.new())
	f_brain = CheckBox.new()
	f_brain.text = "Share the Second Brain (a key of its own, proposals wait for your OK)"
	f_brain.toggled.connect(func(_on: bool) -> void: _check_document())
	g.add_child(f_brain)
	g.add_child(Control.new())
	f_document = CheckBox.new()  # under the Brain: the agent orients in the Brain first and documents as it works
	f_document.text = "↳ Document this session in the Brain as it works"
	g.add_child(f_document)
	g.add_child(Control.new())
	f_brief = CheckBox.new()
	f_brief.text = "Brief it with the latest summary of this folder"
	g.add_child(f_brief)
	g.add_child(Control.new())
	f_remote = CheckBox.new()  # Claude Code's Remote Control: on by default, untick to keep the session here only
	f_remote.text = "Remote Control: also on claude.ai/code and the Claude app"
	f_remote.button_pressed = true
	f_remote.tooltip_text = "The session appears in claude.ai/code under « Group · Name »; Claude Code only"
	g.add_child(f_remote)
	f_cwd.text_changed.connect(func(_t: String) -> void: _check_brief())
	f_tool.item_selected.connect(func(_i: int) -> void: _check_brief())
	f_where.item_selected.connect(func(_i: int) -> void: _check_remote())
	f_group.item_selected.connect(func(_i: int) -> void: _group_level_default())
	new_dialog.confirmed.connect(_create)


func _muted(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	return l


## The folder picker (Windows' own dialog when available): it opens on the last folder chosen.
var folder_target: Callable


func _pick_folder() -> void:
	_pick_folder_then(f_cwd.text, func(dir: String) -> void:
		f_cwd.text = dir
		_check_brief())


## Opens the picker at `near` (or the last folder chosen) and gives the chosen folder (Windows form on Windows).
func _pick_folder_then(near: String, done: Callable) -> void:
	folder_target = done
	if folder_dialog == null:
		folder_dialog = FileDialog.new()
		folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
		folder_dialog.use_native_dialog = true
		folder_dialog.title = "Choose a folder"
		folder_dialog.dir_selected.connect(func(dir: String) -> void:
			_save("last_folder", dir)
			if folder_target.is_valid():
				folder_target.call(dir.replace("/", "\\") if engine.on_windows else dir))
		add_child(folder_dialog)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	var start := str(cfg.get_value("ui", "last_folder", ""))
	var typed := near.strip_edges()
	if typed.length() > 2 and (typed[1] == ":" or typed.begins_with("\\\\")):
		start = typed
	if start != "":
		folder_dialog.current_dir = start
	folder_dialog.popup_centered_ratio(0.6)


func _check_remote() -> void:
	var claude := str(f_tool.get_selected_metadata()) == "claude"
	var local := str(f_where.get_selected_metadata()) != "sandbox"
	f_remote.disabled = not (claude and local)
	f_remote.tooltip_text = "The session appears in claude.ai/code under « Group · Name »" if not f_remote.disabled else ("Claude Code only" if not claude else "Not in cloud sandboxes yet")
	_check_document()


func _check_document() -> void:
	var claude := str(f_tool.get_selected_metadata()) == "claude"
	var local := str(f_where.get_selected_metadata()) != "sandbox"
	f_document.disabled = not (f_brain.button_pressed and not f_brain.disabled and claude and local)
	if f_document.disabled:
		f_document.button_pressed = false
	f_document.tooltip_text = ("The agent first reads where the project stands in the Brain (its card, the last session, open questions), then proposes decisions, your words and a session journal at each milestone; proposals still go through the archivist" if not f_document.disabled
		else ("Share the Second Brain first" if not f_brain.button_pressed or f_brain.disabled else ("Claude Code only for now" if not claude else "Not in cloud sandboxes yet")))


func _check_brief() -> void:
	_check_remote()
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


func _open_new(where := "", tool := "") -> void:
	f_name.text = ""
	f_cwd.editable = true
	f_browse.disabled = false
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
	f_document.button_pressed = false
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
	_group_level_default()
	for i in f_where.item_count:  # Loop 16: « Deploy » from the Sandboxes tab opens it ready for the cloud
		if where != "" and str(f_where.get_item_metadata(i)) == where:
			f_where.select(i)
	for i in f_tool.item_count:
		if tool != "" and str(f_tool.get_item_metadata(i)) == tool:
			f_tool.select(i)
	f_remote.button_pressed = true
	_check_remote()
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
	_render_orchestrator()
	if view == "board":
		_refresh_previews()
	elif view == "grid":
		_update_grid_titles()


# ---------------------------------------------------------------- the orchestrator (Loop 25)
func orchestrator_session() -> Dictionary:
	for s in sessions:
		if str(s.get("role", "")) == "orchestrator":
			return s
	return {}


## Every session under the orchestrator (its children and their helpers), from the parent links.
func orchestrated() -> Array:
	var o := orchestrator_session()
	if o.is_empty():
		return []
	var ids := {str(o["id"]): true}
	var out := []
	var grew := true
	while grew:
		grew = false
		for s in sessions:
			if not ids.has(str(s["id"])) and ids.has(str(s.get("parent", ""))):
				ids[str(s["id"])] = true
				out.append(s)
				grew = true
	return out


func _build_orch_panel() -> void:
	orch_panel = PanelContainer.new()
	orch_panel.name = "Orchestrator"
	orch_panel.visible = false
	# a floating, slightly translucent window over the app (Loop 26c): it never squeezes the views; move it by its
	# title bar, resize it by its corner, minimise it to its title bar
	var st := AmTheme.box(Color(AmTheme.col("BG_2"), 0.94), 14, Color(AmTheme.col("MINT"), 0.45), 1, 12)
	st.shadow_color = Color(0, 0, 0, 0.45)
	st.shadow_size = 18
	orch_panel.add_theme_stylebox_override("panel", st)
	add_child(orch_panel)
	var vp := get_viewport_rect().size
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	var rr: Rect2 = cfg.get_value("orchestrator", "rect", Rect2(vp.x - 640, 64, 600, vp.y - 110))
	orch_panel.position = rr.position
	orch_panel.size = rr.size
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	orch_panel.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top.mouse_filter = MOUSE_FILTER_STOP
	top.mouse_default_cursor_shape = CURSOR_MOVE
	top.tooltip_text = "Drag to move it"
	top.gui_input.connect(func(e: InputEvent) -> void: _orch_drag_input(e, "move"))
	v.add_child(top)
	orch_head = Label.new()
	orch_head.text = "◆ Orchestrator"
	orch_head.add_theme_font_override("font", AmTheme.ui_font(700))
	orch_head.add_theme_font_size_override("font_size", 16)
	orch_head.add_theme_color_override("font_color", AmTheme.col("MINT"))
	top.add_child(orch_head)
	var beta := Label.new()
	beta.text = " BETA "
	beta.add_theme_font_size_override("font_size", 10)
	beta.add_theme_font_override("font", AmTheme.ui_font(700))
	beta.add_theme_color_override("font_color", AmTheme.col("ON_ACCENT"))
	var bs := AmTheme.box(AmTheme.col("WARN"), 5, AmTheme.col("WARN"), 0, 0)
	bs.content_margin_left = 6
	bs.content_margin_right = 6
	beta.add_theme_stylebox_override("normal", bs)
	beta.mouse_filter = MOUSE_FILTER_PASS
	beta.tooltip_text = "Powerful, still being tuned: watch what it does, and say what goes wrong"
	beta.size_flags_vertical = SIZE_SHRINK_CENTER
	top.add_child(beta)
	orch_state = Label.new()
	orch_state.size_flags_horizontal = SIZE_EXPAND_FILL
	orch_state.add_theme_font_size_override("font_size", 12)
	top.add_child(orch_state)
	orch_start = _small("Start", _start_orchestrator, "One orchestrator for all your connected repositories: it proposes a plan and waits for your OK")
	top.add_child(orch_start)
	orch_stop = _small("Stop all", func() -> void:
		_confirm("Stop the orchestrator and every session under it?\n\nThey stay in the list, ended; nothing is deleted.", func() -> void:
			await engine.call_api("POST", "/orchestrator/stop", {"confirmed": true})
			await refresh()), "Stops the orchestrator and every session it started")
	top.add_child(orch_stop)
	top.add_child(_small("⤢", func() -> void:
		var o := orchestrator_session()
		if not o.is_empty():
			set_view("focus")
			select(str(o["id"])), "Open it in the main area"))
	top.add_child(_small("—", _toggle_orch_min, "Minimise to its title bar"))
	top.add_child(_small("✕", toggle_orchestrator, "Hide (%s)" % key_text("orchestrator")))
	orch_brain = Label.new()
	orch_body.append(orch_brain)
	orch_brain.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	orch_brain.add_theme_font_size_override("font_size", 13)
	orch_brain.add_theme_font_override("font", AmTheme.ui_font(600))
	orch_brain.mouse_filter = MOUSE_FILTER_PASS
	v.add_child(orch_brain)
	orch_hint = _wrap("")
	v.add_child(orch_hint)
	# tabs: its terminal takes the whole window; its plan and its sessions each have their own tab
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	v.add_child(tabs)
	orch_body.append(tabs)
	for t in [["terminal", "Terminal"], ["plan", "Plan"], ["sessions", "Sessions"]]:
		var b := Button.new()
		b.text = t[1]
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_set_orch_tab.bind(t[0]))
		tabs.add_child(b)
		orch_tabs[t[0]] = b
	orch_term_box = VBoxContainer.new()
	orch_term_box.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(orch_term_box)
	var lists_scroll := ScrollContainer.new()
	lists_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	lists_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(lists_scroll)
	orch_lists = lists_scroll
	var lists := VBoxContainer.new()
	lists.size_flags_horizontal = SIZE_EXPAND_FILL
	lists.add_theme_constant_override("separation", 6)
	lists_scroll.add_child(lists)
	orch_plan = VBoxContainer.new()
	orch_plan.add_theme_constant_override("separation", 3)
	lists.add_child(orch_plan)
	var sub := Label.new()
	sub.text = "ITS SESSIONS"
	sub.name = "SubTitle"
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", AmTheme.col("MINT"))
	lists.add_child(sub)
	orch_sub = sub
	orch_list = VBoxContainer.new()
	orch_list.add_theme_constant_override("separation", 4)
	lists.add_child(orch_list)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	v.add_child(foot)
	orch_body.append(foot)
	orch_foot = Label.new()
	orch_foot.size_flags_horizontal = SIZE_EXPAND_FILL
	orch_foot.add_theme_font_size_override("font_size", 12)
	orch_foot.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	foot.add_child(orch_foot)
	foot.add_child(_small("Routing rules…", _open_rules, "Which tool and model for which kind of task: the orchestrator follows them"))
	foot.add_child(_small("Budget…", func() -> void:
		var cur := int((orch_data.get("budget", {}) as Dictionary).get("daily_tokens", 0))
		_ask("Daily token budget for the orchestrator and its sessions (millions of tokens, 0 = none)", str(cur / 1000000.0) if cur else "0", func(t: String) -> void:
			var r := await engine.call_api("POST", "/orchestrator/budget", {"daily_tokens": int(float(t.strip_edges().replace(",", ".")) * 1000000)})
			if r.has("error"):
				status_label.text = str(r["error"])
			await refresh_orchestrator()), "Once today's tokens reach it, the orchestrator cannot start sessions"))
	var grip := Label.new()
	grip.text = "◢"
	grip.add_theme_color_override("font_color", AmTheme.col("FAINT"))
	grip.mouse_filter = MOUSE_FILTER_STOP
	grip.mouse_default_cursor_shape = CURSOR_FDIAGSIZE
	grip.tooltip_text = "Drag to resize"
	grip.gui_input.connect(func(e: InputEvent) -> void: _orch_drag_input(e, "size"))
	foot.add_child(grip)
	# a little see-through when the mouse is elsewhere, solid under the mouse
	var fade := Timer.new()
	fade.wait_time = 0.15
	fade.autostart = true
	fade.timeout.connect(func() -> void:
		if orch_panel.visible:
			var over := orch_panel.get_global_rect().has_point(get_global_mouse_position()) or orch_drag != ""
			var want := 1.0 if over else 0.86
			if absf(orch_panel.modulate.a - want) > 0.01:
				create_tween().tween_property(orch_panel, "modulate:a", want, 0.2))
	add_child(fade)
	_build_rules_dialog()
	_set_orch_tab("terminal")


func _set_orch_tab(tab: String) -> void:
	orch_tab = tab
	for k in orch_tabs:
		orch_tabs[k].set_pressed_no_signal(k == tab)
	orch_term_box.visible = tab == "terminal" and not orch_min
	orch_lists.visible = tab != "terminal" and not orch_min
	orch_plan.visible = tab == "plan"
	orch_sub.visible = tab == "sessions"
	orch_list.visible = tab == "sessions"


func _orch_drag_input(e: InputEvent, what: String) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		orch_drag = what if e.pressed else ""
		if not e.pressed:
			_save_orch_rect()
	elif e is InputEventMouseMotion and orch_drag == what:
		var vp := get_viewport_rect().size
		if what == "move":
			orch_panel.position = (orch_panel.position + e.relative).clamp(Vector2(-orch_panel.size.x + 120, 0), vp - Vector2(120, 40))
		else:
			orch_panel.size = (orch_panel.size + e.relative).clamp(Vector2(420, 260), vp - orch_panel.position)


func _save_orch_rect() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("orchestrator", "rect", Rect2(orch_panel.position, orch_panel.size if not orch_min else cfg.get_value("orchestrator", "rect", Rect2(0, 0, 600, 700)).size))
	cfg.save(SETTINGS)


var _orch_full := Vector2.ZERO
func _toggle_orch_min() -> void:
	orch_min = not orch_min
	for n in orch_body:
		n.visible = not orch_min
	orch_hint.visible = not orch_min and orch_hint.text != ""
	_set_orch_tab(orch_tab)
	if orch_min:
		_orch_full = orch_panel.size
		orch_panel.size = Vector2(orch_panel.size.x, 0)
		orch_panel.reset_size()
	else:
		orch_panel.size = _orch_full if _orch_full != Vector2.ZERO else Vector2(600, get_viewport_rect().size.y - 110)
		_mount_orchestrator()


func toggle_orchestrator() -> void:
	orch_panel.visible = not orch_panel.visible
	if orch_panel.visible:  # the screen may be smaller than when it was placed: keep it whole and in view
		var vp := get_viewport_rect().size
		orch_panel.size = orch_panel.size.clamp(Vector2(420, 260), vp - Vector2(16, 72))
		orch_panel.position = orch_panel.position.clamp(Vector2(0, 56), vp - orch_panel.size - Vector2(8, 8))
	orch_btn.set_pressed_no_signal(orch_panel.visible)
	if orch_panel.visible:
		await refresh_orchestrator()
		var o := orchestrator_session()
		if not o.is_empty() and str(o.get("state", "")) == "running":
			await _ensure_terminal(str(o["id"]))
	_layout_view()


## It works with the Second Brain from its first step: said at the top of its panel, in the Brain's violet.
func _render_brain_line(o: Dictionary) -> void:
	var info := brain_info(str(o.get("id", "")))
	if not brain_ok:
		orch_brain.text = "✦ Second Brain not connected: it would work without the project's memory"
		orch_brain.add_theme_color_override("font_color", AmTheme.col("WARN"))
	elif o.is_empty():
		orch_brain.text = "✦ Starts connected to your Second Brain: it reads the project cards first, then records its plan, its routing choices and its journal"
		orch_brain.add_theme_color_override("font_color", AmTheme.brain())
	elif info.is_empty() or str(info.get("problem", "")) != "":
		orch_brain.text = "✦ Second Brain: " + (str(info.get("problem", "")) if not info.is_empty() else "no key for it (start it again to get one)")
		orch_brain.add_theme_color_override("font_color", AmTheme.col("WARN"))
	else:
		orch_brain.text = "✦ Connected to your Second Brain%s · %d calls · %d proposals" % [" · it documents" if info.get("document", false) else "", int(info.get("calls", 0)), int(info.get("proposals", 0))]
		orch_brain.add_theme_color_override("font_color", AmTheme.brain())
	orch_brain.tooltip_text = SessionCard.brain_look(info, true)[2] if not info.is_empty() else ""
	var c: Color = orch_brain.get_theme_color("font_color")
	orch_brain.add_theme_stylebox_override("normal", AmTheme.box(Color(c, 0.09), 9, Color(c, 0.55), 1, 9))


## Its plan, live: each task with its state, tool and model, and its session's state; a click opens the session.
func _render_plan() -> void:
	for c in orch_plan.get_children():
		orch_plan.remove_child(c)
		c.queue_free()
	var plan: Dictionary = orch_data.get("plan", {})
	var tasks: Array = plan.get("tasks", [])
	if tasks.is_empty():
		orch_plan.add_child(_wrap("No plan yet: it proposes one, waits for your OK, then writes it here and keeps it current."))
		return
	var h := Label.new()
	h.text = str(plan.get("goal", "")) if str(plan.get("goal", "")) != "" else "Its plan"
	h.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_theme_font_size_override("font_size", 11)
	h.add_theme_color_override("font_color", AmTheme.col("MINT"))
	orch_plan.add_child(h)
	var icons := {"planned": "○", "running": "●", "review": "◐", "done": "✓", "dropped": "✕"}
	for t in tasks:
		var st := str(t.get("status", "planned"))
		var sess := _session(str(t.get("session", "")))
		var colour: Color = activity_of(sess)[0] if not sess.is_empty() and st == "running" else ({"done": activity_of({"activity": "done"})[0], "review": AmTheme.col("WARN"), "dropped": AmTheme.col("FAINT")}.get(st, AmTheme.col("MUTED")))
		var b := Button.new()
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var who := str(t.get("tool", "claude")).replace("claude", "Claude Code").replace("codex", "Codex") + ((" · " + str(t["model"])) if str(t.get("model", "")) != "" else "")
		b.text = "%s  %s   ·  %s%s" % [icons.get(st, "○"), t.get("title", ""), who, ("  ·  " + str(activity_of(sess)[1])) if not sess.is_empty() and st == "running" else ("  ·  " + st if st != "planned" else "")]
		b.add_theme_color_override("font_color", colour)
		b.add_theme_font_size_override("font_size", 12)
		b.tooltip_text = ("Why: " + str(t.get("why", ""))) if str(t.get("why", "")) != "" else ""
		var sid := str(t.get("session", ""))
		if sid != "":
			b.pressed.connect(func() -> void:
				set_view("focus")
				select(sid))
		orch_plan.add_child(b)


## The owner's routing rules: « when » (a kind of task), the tool, the model; the orchestrator reads them live.
func _build_rules_dialog() -> void:
	rules_dialog = AcceptDialog.new()
	rules_dialog.title = "Routing rules"
	rules_dialog.ok_button_text = "Save"
	rules_dialog.min_size = Vector2i(720, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	rules_dialog.add_child(v)
	var intro := _wrap("Which tool and model for which kind of task. The orchestrator reads these before choosing, and says why when it departs from them. A model is a name its tool knows (opus, sonnet, haiku for Claude Code); empty means the tool's default.")
	intro.custom_minimum_size = Vector2(680, 0)
	v.add_child(intro)
	rules_rows = VBoxContainer.new()
	rules_rows.add_theme_constant_override("separation", 6)
	v.add_child(rules_rows)
	v.add_child(_small("+ Add a rule", func() -> void: _rule_row({"when": "", "tool": "claude", "model": ""})))
	rules_dialog.confirmed.connect(func() -> void:
		var out := []
		for row in rules_rows.get_children():
			if row.is_queued_for_deletion():
				continue
			var w: LineEdit = row.get_child(0)
			var tool: OptionButton = row.get_child(1)
			var m: LineEdit = row.get_child(2)
			out.append({"when": w.text, "tool": str(tool.get_selected_metadata()), "model": m.text.strip_edges()})
		var r := await engine.call_api("POST", "/orchestrator/rules", {"rules": out})
		if r.has("error"):
			status_label.text = "Routing rules: " + str(r["error"])
		else:
			_toast("Routing rules saved: the orchestrator reads them before its next choice")
		await refresh_orchestrator())
	add_child(rules_dialog)


func _rule_row(rule: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var w := LineEdit.new()
	w.text = str(rule.get("when", ""))
	w.placeholder_text = "a kind of task, e.g. hard bugs"
	w.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(w)
	var tool := OptionButton.new()
	for k in [["claude", "Claude Code"], ["codex", "Codex"], ["shell", "Shell"]]:
		tool.add_item(k[1])
		tool.set_item_metadata(tool.item_count - 1, k[0])
		if k[0] == str(rule.get("tool", "claude")):
			tool.select(tool.item_count - 1)
	row.add_child(tool)
	var m := LineEdit.new()
	m.text = str(rule.get("model", ""))
	m.placeholder_text = "model (default)"
	m.custom_minimum_size = Vector2(150, 0)
	row.add_child(m)
	row.add_child(_small("✕", func() -> void: row.queue_free(), "Remove this rule"))
	rules_rows.add_child(row)


func _open_rules() -> void:
	await refresh_orchestrator()
	for c in rules_rows.get_children():
		c.queue_free()
	for r in orch_data.get("rules", []):
		_rule_row(r)
	rules_dialog.popup_centered()


func _start_orchestrator() -> void:
	_toast("Starting the orchestrator…")
	var r := await engine.call_api("POST", "/orchestrator/start", {"cwd": "~"}, true, 60.0)
	if r.has("error"):
		status_label.text = "Orchestrator: " + str(r["error"])
		return
	await refresh()
	await _ensure_terminal(str(r["id"]))
	_layout_view()


## Its terminal goes in the panel, unless the main area shows it already (Focus or Grid on the orchestrator).
func _mount_orchestrator() -> void:
	if orch_panel == null or not orch_panel.visible:
		return
	var id := str(orchestrator_session().get("id", ""))
	if id == "" or not terms.has(id) or not is_instance_valid(terms[id]):
		return
	if (view == "focus" and selected == id) or (view == "grid" and grid_ids.has(id)):
		return
	var t: Control = terms[id]
	if t.get_parent() != orch_term_box:
		t.reparent(orch_term_box, false)
	t.size_flags_vertical = SIZE_EXPAND_FILL
	t.size_flags_horizontal = SIZE_EXPAND_FILL


func refresh_orchestrator() -> void:
	if orch_panel == null or not orch_panel.visible:
		return
	var r := await engine.call_api("GET", "/orchestrator", null, true, 30.0)
	if not r.has("error"):
		orch_data = r
	_render_orchestrator()


static func _tokens(n: int) -> String:
	return ("%.1fM" % (n / 1000000.0)) if n >= 1000000 else (("%dk" % (n / 1000)) if n >= 1000 else str(n))


func _render_orchestrator() -> void:
	if orch_panel == null or not orch_panel.visible:
		return
	var o := orchestrator_session()
	var sig := JSON.stringify([o.get("id", ""), o.get("state", ""), o.get("activity", ""), o.get("message", ""), orch_data.get("plan", {}),
		orch_data.get("budget", {}), brain_ok, brain_info(str(o.get("id", ""))),
		orchestrated().map(func(k): return [k["id"], k.get("activity", ""), k.get("state", ""), k.get("branch", ""), k.get("message", "")]),
		sessions.map(func(k): return [k["id"], k.get("activity", "")])])
	if sig == orch_sig:
		return
	orch_sig = sig
	_render_brain_line(o)
	_render_plan()
	var running := not o.is_empty() and str(o.get("state", "")) == "running"
	orch_start.visible = not running
	orch_start.text = "Start" if o.is_empty() else "Resume"
	orch_stop.visible = running
	if o.is_empty():
		orch_state.text = ""
		orch_hint.text = "One orchestrator for all your connected repositories. It reads the Second Brain, proposes a plan and waits for your OK, then starts sessions in worktrees, follows them and hands you each result to review. It never pushes nor merges; at most 4 of its sessions run at once."
	else:
		var act := activity_of(o)
		orch_state.text = "● " + str(act[1])
		orch_state.add_theme_color_override("font_color", act[0])
		var msg := str(o.get("message", ""))
		orch_hint.text = ("It asks you: " + msg + "\n(answer in its terminal below, or with Reply… in the queue)") if str(o.get("activity", "")) == "waiting" and msg != "" else ""
		if running and not terms.has(str(o["id"])):
			_ensure_terminal(str(o["id"]))
	orch_hint.visible = orch_hint.text != "" and not orch_min
	for c in orch_list.get_children():
		orch_list.remove_child(c)
		c.queue_free()
	var kids := orchestrated()
	var live := kids.filter(func(x): return str(x.get("state", "")) == "running").size()
	(orch_panel.find_child("SubTitle", true, false) as Label).text = ("%d running, 4 at most" % live) if not kids.is_empty() else "None yet: it starts sessions after your OK"
	var tasks: Array = (orch_data.get("plan", {}) as Dictionary).get("tasks", [])
	var done := tasks.filter(func(t): return str(t.get("status", "")) in ["done", "dropped"]).size()
	orch_tabs["plan"].text = ("Plan  %d/%d" % [done, tasks.size()]) if not tasks.is_empty() else "Plan"
	orch_tabs["sessions"].text = ("Sessions  %d" % kids.size()) if not kids.is_empty() else "Sessions"
	var b0: Dictionary = orch_data.get("budget", {})
	var used := int(b0.get("used_today", 0))
	var cap := int(b0.get("daily_tokens", 0))
	orch_foot.text = "Today: %s tokens%s" % [_tokens(used), (" of %s" % _tokens(cap)) if cap else " · no budget"]
	orch_foot.add_theme_color_override("font_color", AmTheme.col("WARN") if cap and used >= cap * 0.8 else AmTheme.col("MUTED"))
	for k in kids:
		var b := Button.new()
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var act := activity_of(k)
		var tool := str(k.get("tool_label", ""))
		if str(k.get("model", "")) != "":
			tool += " · " + str(k["model"])
		b.text = "%s●  %s  ·  %s  ·  %s%s" % ["      " if str(k.get("parent", "")) != str(o.get("id", "")) else "", k["name"], tool, act[1], ("  ·  ⎇ " + str(k["branch"])) if str(k.get("branch", "")) != "" else ""]
		b.add_theme_color_override("font_color", act[0])
		b.add_theme_font_size_override("font_size", 12)
		b.tooltip_text = str(k.get("message", ""))
		var kid := str(k["id"])
		b.pressed.connect(func() -> void:
			set_view("focus")
			select(kid))
		orch_list.add_child(b)


# ---------------------------------------------------------------- the Second Brain, visible
func brain_info(id: String) -> Dictionary:
	return (brain.get("sessions", {}) as Dictionary).get(id, {})


func _brain_mark(l: Label, s: Dictionary) -> void:
	var look := SessionCard.brain_look(brain_info(str(s.get("id", ""))), str(s.get("tool", "")) != "shell")
	l.text = look[0]
	l.tooltip_text = look[2]
	l.add_theme_color_override("font_color", look[1])


func refresh_brain() -> void:
	var r := await engine.call_api("GET", "/brain/activity", null, true, 30.0)
	if r.has("error"):
		return
	brain = r
	brain_ok = bool(r.get("connected", false))
	var any_glow := false
	var per: Dictionary = r.get("sessions", {})
	for id in per:
		var n := int(per[id].get("calls", 0)) + int(per[id].get("proposals", 0))
		var glow: bool = brain_seen.has(id) and n > int(brain_seen[id])
		brain_seen[id] = n
		any_glow = any_glow or glow
		if cards.has(id) and is_instance_valid(cards[id]):
			cards[id].set_brain(per[id], glow)
	for id in cards:  # sessions without a key (or that lost it) too
		if not per.has(id) and is_instance_valid(cards[id]):
			cards[id].set_brain({}, false)
	_render_brain_badge(any_glow)
	_render_header()
	if view == "grid":
		_update_grid_titles()


func _render_brain_badge(glow: bool) -> void:
	var v := AmTheme.brain()
	var per: Dictionary = brain.get("sessions", {})
	var linked := per.values().filter(func(x): return str(x.get("problem", "")) == "").size()
	var trouble := per.size() - linked
	var colour := v
	if brain_ok:
		brain_line1.text = "Second Brain  ● connected"
		brain_line2.text = "%d of %d agents linked  ·  %d proposal%s today" % [linked, int(brain.get("agents", 0)), int(brain.get("today", 0)), "" if int(brain.get("today", 0)) == 1 else "s"]
	else:
		colour = AmTheme.col("FAINT")
		brain_line1.text = "Second Brain  ○ " + ("off" if str(brain.get("reason", "")).begins_with("off") else "not running")
		brain_line2.text = ("%d session%s count%s on it" % [trouble, "" if trouble == 1 else "s", "s" if trouble == 1 else ""]) if trouble > 0 else "Click for details"
	brain_glyph.add_theme_color_override("font_color", colour)
	brain_line1.add_theme_color_override("font_color", colour if not brain_ok else AmTheme.col("TEXT"))
	brain_line2.add_theme_color_override("font_color", AmTheme.col("MUTED"))

	for st in ["normal", "hover", "pressed", "focus"]:
		var a := 0.07 if st == "normal" else 0.14
		brain_badge.add_theme_stylebox_override(st, AmTheme.box(Color(colour, a), 10, Color(colour, 0.45 if brain_ok else 0.25), 1, 9))
	if glow:
		var t := create_tween()
		for i in 2:
			t.tween_property(brain_glyph, "scale", Vector2(1.4, 1.4), 0.35).set_trans(Tween.TRANS_SINE)
			t.tween_property(brain_glyph, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_SINE)


## The small Brain panel (from the badge or the header): the connection, each session's light, the latest proposals.
func _toggle_brain_panel() -> void:
	if brain_panel and brain_panel.visible:
		brain_panel.queue_free()
		brain_panel = null
	else:
		_show_brain_panel()


func _show_brain_panel() -> void:
	if brain_panel:
		brain_panel.queue_free()
	brain_panel = PanelContainer.new()
	brain_panel.top_level = true
	brain_panel.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 12, Color(AmTheme.brain(), 0.6), 1, 14))
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(420, 0)
	v.add_theme_constant_override("separation", 6)
	brain_panel.add_child(v)
	var title := Label.new()
	title.text = "✦ Second Brain"
	title.add_theme_font_override("font", AmTheme.ui_font(700))
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", AmTheme.brain())
	v.add_child(title)
	var sub := _wrap(("Connected on this computer. Each session holds a key of its own, read-and-propose only: the Brain's archivist files what they propose, with your rules." if brain_ok
		else "Not connected: " + str(brain.get("reason", "")) + ". Sessions that count on it cannot read or propose until it runs again."))
	v.add_child(sub)
	sub.custom_minimum_size = Vector2(400, 0)
	var head := Label.new()
	head.text = "SESSIONS"
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", AmTheme.col("MINT"))
	v.add_child(head)
	for s in sessions:
		if str(s.get("tool", "")) == "shell":
			continue
		var info := brain_info(str(s["id"]))
		var look := SessionCard.brain_look(info, true)
		var row := HBoxContainer.new()
		var g := Label.new()
		g.text = look[0]
		g.add_theme_color_override("font_color", look[1])
		row.add_child(g)
		var n := Label.new()
		n.text = str(s["name"])
		n.size_flags_horizontal = SIZE_EXPAND_FILL
		n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(n)
		var d := Label.new()
		d.text = ("no Brain" if info.is_empty() else (str(info["problem"]) if str(info.get("problem", "")) != "" else
			"%s%d call%s · %d proposal%s" % ["documents · " if info.get("document", false) else "", int(info.get("calls", 0)), "" if int(info.get("calls", 0)) == 1 else "s", int(info.get("proposals", 0)), "" if int(info.get("proposals", 0)) == 1 else "s"]))
		d.add_theme_font_size_override("font_size", 12)
		d.add_theme_color_override("font_color", AmTheme.col("MUTED"))
		row.add_child(d)
		row.tooltip_text = look[2]
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		v.add_child(row)
	var recent: Array = brain.get("recent", [])
	if recent.size() > 0:
		var h2 := head.duplicate() as Label
		h2.text = "LATEST PROPOSALS"
		v.add_child(h2)
		for p in recent:
			var l := Label.new()
			var mark: String = {"applied": "✓", "pending": "…", "rejected": "✕", "failed": "✕"}.get(str(p["status"]), "·")
			l.text = "%s  %s  ·  %s  ·  %s" % [mark, str(p["title"]), str(p["session"]), SessionCard._ago(float(p["at"]))]
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			l.custom_minimum_size = Vector2(10, 0)
			l.add_theme_font_size_override("font_size", 12)
			l.add_theme_color_override("font_color", AmTheme.col("TEXT") if str(p["status"]) != "pending" else AmTheme.col("WARN"))
			v.add_child(l)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	v.add_child(btns)
	btns.add_child(_small("Brain keys…", func() -> void:
		_toggle_brain_panel()
		set_view("keys"), "Every key Agent Manager made; unused ones can be revoked"))
	btns.add_child(_small("Check now", func() -> void:
		await refresh_brain()
		_show_brain_panel()))
	btns.add_child(_small("Close", _toggle_brain_panel))
	add_child(brain_panel)
	await get_tree().process_frame
	brain_panel.reset_size()  # once the text knows its width, the panel takes the height it needs
	await get_tree().process_frame
	brain_panel.reset_size()
	var at := brain_badge.get_global_rect()
	brain_panel.position = Vector2(at.position.x, at.position.y - brain_panel.size.y - 8)


func _watch_transitions() -> Array:
	var changed := []
	for x in sessions:
		var id := str(x["id"])
		var act := str(x.get("activity", ""))
		var before := str(last_activity.get(id, ""))
		if before != "" and act != before:
			changed.append(id)
			_speak_transition(x, act)
			if act in ["approval", "waiting"] and str(notified.get(id, "")) != str(x.get("since", "")):
				notified[id] = str(x.get("since", ""))
				_toast("%s %s" % [x["name"], activity_of(x)[1]])
				if not get_window().has_focus():
					DisplayServer.window_request_attention()
				if sound_on:
					_chime()
		last_activity[id] = act
	var n := sessions.filter(func(y): return str(y.get("activity", "")) in ["approval", "waiting"]).size()
	get_window().title = ("(%d) " % n if n > 0 else "") + "Agent Manager GD"
	return changed


## A soft two-note chime made here (no sound file): when an agent starts waiting for you.
func _chime() -> void:
	if chime == null:
		var rate := 22050
		var data := PackedByteArray()
		for i in int(rate * 0.32):
			var t := float(i) / rate
			var f := 880.0 if t < 0.14 else 659.0
			var env := exp(-9.0 * fmod(t, 0.14 if t < 0.14 else 1.0)) * 0.35
			var v := int(clamp(sin(TAU * f * t) * env, -1.0, 1.0) * 32767)
			data.append(v & 0xff)
			data.append((v >> 8) & 0xff)
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.mix_rate = rate
		w.data = data
		chime = AudioStreamPlayer.new()
		chime.stream = w
		chime.volume_db = -8.0
		add_child(chime)
	chime.play()


func set_sound(on: bool) -> void:
	sound_on = on
	_save("sound", on)
	_toast("Chime " + ("on: a soft sound when an agent waits for you" if on else "off"))


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
	card.set_brain(brain_info(id), false)
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
	var all_waiting := sessions.filter(func(x): return str(x.get("activity", "")) in ["approval", "waiting"])
	var waiting := all_waiting.filter(func(x): return str(dismissed.get(str(x["id"]), "-")) != str(x.get("since", "")))
	var hidden := all_waiting.size() - waiting.size()
	if waiting.is_empty() and hidden == 0:
		return
	if waiting.is_empty():
		queue_box.add_child(_small("%d request%s hidden · show" % [hidden, "" if hidden == 1 else "s"], func() -> void:
			dismissed.clear()
			_render_queue(), "Requests you closed with ✕ (they are still on the agents' cards)"))
		return
	var title := Label.new()
	title.text = "THEY WAIT FOR YOU   %d" % waiting.size() + ("   · %d hidden" % hidden if hidden else "")
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
		var top := HBoxContainer.new()
		v.add_child(top)
		var l := Label.new()
		l.text = "%s · %s" % [x["name"], act[1]]
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_font_override("font", AmTheme.ui_font(600))
		l.size_flags_horizontal = SIZE_EXPAND_FILL
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		top.add_child(l)
		var since := str(x.get("since", ""))
		var close := Button.new()
		close.text = "✕"
		close.flat = true
		close.tooltip_text = "Hide it here: the request stays on the agent's card and comes back if it asks again"
		close.add_theme_font_size_override("font_size", 12)
		close.add_theme_color_override("font_color", AmTheme.col("MUTED"))
		close.pressed.connect(func() -> void:
			dismissed[id] = since
			_render_queue())
		top.add_child(close)
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
			h.add_child(_small("Approve", func() -> void: _answer(id, ["Enter"], card, "✓  Approved · %s carries on" % x["name"]), "Enter: the agent's highlighted choice (Yes) · Ctrl+Shift+A"))
			h.add_child(_small("Refuse", func() -> void: _answer(id, ["Escape"], card, "✕  Refused · %s stops this step" % x["name"]), "Escape"))
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


## A folder under the home folder is shown as ~/… (Linux, where the app and the engine share HOME).
func short_path(p: String) -> String:
	var home := OS.get_environment("HOME") if OS.get_name() != "Windows" else ""
	if home != "" and home != "/" and (p == home or p.begins_with(home + "/")):
		return "~" + p.substr(home.length())
	return p


func _render_header() -> void:
	var s := _session(selected)
	header_name.text = str(s.get("name", "Agent Manager GD"))
	var meta := ""
	if s:
		meta = "%s  ·  %s" % [s["tool_label"], short_path(str(s["cwd"]))]
		if str(s.get("branch", "")) != "":
			meta += "  ·  ⎇ " + str(s["branch"])
		if str(s.get("tool", "")) != "shell":
			meta += "  ·  " + str(LEVELS.get(str(s.get("level", "auto")), LEVELS["auto"])[0]).get_slice(" (", 0).to_lower()
	header_meta.text = meta
	var look := SessionCard.brain_look(brain_info(str(s.get("id", ""))), s and str(s.get("tool", "")) != "shell")
	header_brain.visible = s and look[0] != ""
	if header_brain.visible:
		var info := brain_info(str(s["id"]))
		header_brain.text = look[0] + (" Brain · documents" if info.get("document", false) else (" Brain" if not info.is_empty() else " no Brain"))
		header_brain.tooltip_text = look[2]
		header_brain.add_theme_color_override("font_color", look[1])
		header_brain.add_theme_color_override("font_hover_color", look[1].lightened(0.2))
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
	_mount_orchestrator.call_deferred()
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
		var bm := Label.new()
		bm.name = "Brain"
		bm.mouse_filter = MOUSE_FILTER_PASS
		_brain_mark(bm, s)
		bar.add_child(bm)
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
				_brain_mark(bar.get_node("Brain") as Label, s)


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
	meta.text = "%s  ·  %s%s  ·  made %s%s" % [h["tool_label"], short_path(str(h["cwd"])), ("  ·  " + str(h["grp"])) if str(h["grp"]) != "" else "", _date(float(h["created"])), ("  ·  fork of " + str(h["parent"])) if str(h.get("parent", "")) != "" else ""]
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
			# not a command: what you said is for the agent, written into the active session like a dictation
			if selected != "" and terms.has(selected) and text.strip_edges() != "":
				on_transcribed(selected, text, 0.0)
			else:
				_toast("Heard « %s »: %s (select a session to write it there)" % [text, c.get("reason", "not a command")])


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


var sbx_live: Array = []  # [Label, running_since] pairs ticking every second
var sbx_tick: Timer


func _load_sandboxes() -> void:
	var r := await engine.call_api("GET", "/sandboxes", null, true, 60.0)
	if sbx_box == null or not is_instance_valid(sbx_box):
		return
	for c in sbx_box.get_children():
		c.queue_free()
	sbx_live.clear()
	if sbx_tick == null:
		sbx_tick = Timer.new()
		sbx_tick.wait_time = 1.0
		add_child(sbx_tick)
		sbx_tick.timeout.connect(_sbx_second)
		sbx_tick.start()
	var title := Label.new()
	title.text = "Cloud sandboxes"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_font_override("font", AmTheme.ui_font(650))
	sbx_box.add_child(title)
	if r.has("error"):
		sbx_box.add_child(_muted(str(r["error"])))
		return
	var head := _wrap("Fly.io · organisation %s · region %s · one sandbox per agent session, always listed on the left · Agent Manager never destroys a sandbox on its own." % [
		r.get("org", "—") if str(r.get("org", "")) != "" else "—", r.get("region", "yyz")])
	head.add_theme_font_size_override("font_size", 12)
	sbx_box.add_child(head)
	if not (r.get("token", false) and r.get("flyctl", false)):
		var need := _wrap("First paste your Fly.io token in Keys (◐ → Keys…).")
		need.add_theme_color_override("font_color", AmTheme.col("WARN"))
		sbx_box.add_child(need)
	sbx_box.add_child(_sbx_image_step(r))
	sbx_box.add_child(_sbx_deploy_step(r))
	sbx_box.add_child(_sbx_costs(r))
	var rows: Array = r.get("sandboxes", [])
	var alive: Array = rows.filter(func(x): return int(x["destroyed"]) == 0)
	if not alive.is_empty():
		sbx_box.add_child(_section_label("Your sandboxes (%d)" % alive.size()))
	for sb in alive:
		sbx_box.add_child(_sandbox_card(sb, r))
	var finished: Array = alive.filter(func(x): return int(x["finished"]) == 1)
	if not finished.is_empty():
		var fb := _small("Destroy the finished ones (%d)…" % finished.size(), func() -> void:
			_confirm("Destroy %d finished sandbox(es): %s?\nTheir machines, files and keys are deleted for good." % [finished.size(), ", ".join(finished.map(func(x): return str(x["id"])))], func() -> void:
				for x in finished:
					await engine.call_api("POST", "/sandboxes/%s/destroy" % x["id"], {"confirmed": true}, true, 120.0)
				await refresh()
				await _load_sandboxes()))
		fb.size_flags_horizontal = SIZE_SHRINK_BEGIN
		sbx_box.add_child(fb)
	_sbx_orphans(r)
	# keep the view current while it is shown
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		if view == "sandboxes" and is_instance_valid(sbx_box):
			_load_sandboxes())


func _sbx_second() -> void:
	if view != "sandboxes":
		return
	for pair in sbx_live:
		var l: Label = pair[0]
		if is_instance_valid(l):
			l.text = "on for " + _span(Time.get_unix_time_from_system() - float(pair[1]))


static func _span(sec: float) -> String:
	var s := int(maxf(0.0, sec))
	if s < 60:
		return "%ds" % s
	if s >= 86400:
		return "%dd %02dh" % [s / 86400, (s % 86400) / 3600]
	if s >= 3600:
		return "%dh %02dm" % [s / 3600, (s % 3600) / 60]
	return "%dm %02ds" % [s / 60, s % 60]


func _section_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_font_override("font", AmTheme.ui_font(650))
	return l


func _step_panel(step: String, title: String, done: bool) -> Array:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 10, AmTheme.col("MINT") if done else AmTheme.col("BORDER"), 1, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	card.add_child(v)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var num := Label.new()
	num.text = "✓" if done else step
	num.add_theme_color_override("font_color", AmTheme.col("MINT") if done else AmTheme.col("FAINT"))
	num.add_theme_font_override("font", AmTheme.ui_font(650))
	h.add_child(num)
	var t := Label.new()
	t.text = title
	t.add_theme_font_override("font", AmTheme.ui_font(650))
	t.add_theme_font_size_override("font_size", 15)
	h.add_child(t)
	v.add_child(h)
	return [card, v, h]


func _sbx_image_step(r: Dictionary) -> Control:
	var info: Dictionary = r.get("image_info", {})
	var ready := bool(info.get("ready", false))
	var job: Dictionary = r.get("job", {})
	var parts := _step_panel("1", "The image: what each sandbox starts from", ready)
	var v: VBoxContainer = parts[1]
	var h: HBoxContainer = parts[2]
	var st := _muted(("ready · built " + _date(float(info.get("built", 0)))) if ready and float(info.get("built", 0)) > 0 else ("ready" if ready else "not deployed yet"))
	st.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(st)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 4)
	for c in info.get("contents", []):
		var k := Label.new()
		k.text = "• " + str(c[0])
		k.add_theme_font_size_override("font_size", 13)
		grid.add_child(k)
		var d := _muted(str(c[1]))
		d.add_theme_font_size_override("font_size", 13)
		grid.add_child(d)
	v.add_child(grid)
	v.add_child(_muted("We provide it: %s, built by Fly in your organisation's private registry (about 2 minutes, once)." % str(info.get("recipe", "sandbox/Dockerfile"))))
	if str(job.get("state", "")) == "preparing":
		v.add_child(_muted("⏳ " + str(job.get("message", "building…"))))
	elif str(job.get("state", "")) == "error":
		var er := _wrap("The build failed: " + str(job.get("message", "")))
		er.add_theme_color_override("font_color", AmTheme.col("ERROR"))
		v.add_child(er)
	if str(job.get("state", "")) != "preparing":
		var btn := _small("Rebuild (newer Claude Code and Codex)" if ready else "Use this image → Deploy it", func() -> void:
			_toast("Fly builds the image (about 2 minutes)…")
			await engine.call_api("POST", "/sandboxes/prepare", {})
			await _load_sandboxes())
		btn.disabled = not (r.get("token", false) and r.get("flyctl", false))
		btn.size_flags_horizontal = SIZE_SHRINK_BEGIN
		v.add_child(btn)
	return parts[0]


func _sbx_deploy_step(r: Dictionary) -> Control:
	var e: Dictionary = r.get("estimate", {})
	var ready := bool(r.get("ready", false))
	var parts := _step_panel("2", "Deploy a sandbox for an agent", false)
	var v: VBoxContainer = parts[1]
	var est := _wrap("Estimated, before you deploy (%s, %s): ≈ %s an hour while it runs · ≈ %s a day if left on · ≈ %s a month paused (its disk only)." % [
		str(e.get("size", "")), str(e.get("source", "")), CostChart.money(float(e.get("per_hour", 0))), CostChart.money(float(e.get("per_day_on", 0))), CostChart.money(float(e.get("paused_per_month", 0)))])
	v.add_child(est)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var a := _small("☁ Deploy + open a shell", func() -> void: _open_new("sandbox", "shell"))
	var b := _small("☁ Deploy + agentic coding session", func() -> void: _open_new("sandbox", "claude"))
	for x in [a, b]:
		x.disabled = not ready
		x.tooltip_text = "" if ready else "Deploy the image first (step 1)"
		row.add_child(x)
	v.add_child(row)
	v.add_child(_muted("Each sandbox belongs to its session: it is on the left with ☁, and goes away only when you destroy it."))
	return parts[0]


func _sbx_costs(r: Dictionary) -> Control:
	var costs: Dictionary = r.get("costs", {})
	var b: Dictionary = r.get("budget", {})
	var limit := float(b.get("monthly_usd", 0))
	var parts := _step_panel("3", "Costs", false)
	var v: VBoxContainer = parts[1]
	(parts[2] as HBoxContainer).get_child(0).text = "$"
	var nums := HBoxContainer.new()
	nums.add_theme_constant_override("separation", 28)
	var month := float(costs.get("month", 0))
	for kv in [["Today", float(costs.get("today", 0))], ["This month", month], ["Budget", limit]]:
		var col := VBoxContainer.new()
		var big := Label.new()
		big.text = CostChart.money(kv[1]) if not (kv[0] == "Budget" and limit <= 0) else "none"
		big.add_theme_font_size_override("font_size", 22)
		big.add_theme_font_override("font", AmTheme.ui_font(650))
		if kv[0] == "This month" and limit > 0:
			big.add_theme_color_override("font_color", AmTheme.col("ERROR") if month >= limit else (AmTheme.col("WARN") if month >= 0.8 * limit else AmTheme.col("TEXT")))
		col.add_child(big)
		col.add_child(_muted(kv[0] + ((" · %d %%" % int(100 * month / limit)) if kv[0] == "This month" and limit > 0 else "")))
		nums.add_child(col)
	v.add_child(nums)
	var chart := CostChart.new()
	chart.set_data(costs, limit)
	v.add_child(chart)
	var key := _muted("Bars: cost per day · line: this month's running total%s. %s." % [(" · dashed: your budget" if month >= 0.25 * limit else " · your budget is far above, so it is not drawn") if limit > 0 else "", str(costs.get("measured_note", ""))])
	key.add_theme_font_size_override("font_size", 12)
	key.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(key)
	v.add_child(_budget_panel(r))
	return parts[0]


func _sbx_orphans(r: Dictionary) -> void:
	var orph: Array = r.get("orphans", [])
	if orph.is_empty():
		return
	sbx_box.add_child(_section_label("Not known by this Agent Manager (never touched unless you destroy them)"))
	for o in orph:
		var orow := HBoxContainer.new()
		orow.add_theme_constant_override("separation", 10)
		var ol := _muted("• app %s %s %s" % [o["app"], ("machine " + str(o["machine"])) if str(o["machine"]) != "" else "", ("(" + str(o["name"]) + ", " + str(o["state"]) + ")")])
		ol.add_theme_font_size_override("font_size", 12)
		orow.add_child(ol)
		var oapp := str(o["app"])
		var omac := str(o["machine"])
		orow.add_child(_small("Destroy…", func() -> void:
			var what := "the machine %s of %s" % [omac, oapp]
			if omac == "":
				var c := await engine.call_api("GET", "/sandboxes/orphans/" + oapp, null, true, 60.0)
				if c.has("error"):
					_toast(str(c["error"]))
					return
				var ms: Array = c.get("machines", [])
				what = "the whole app %s and its %d machine(s)%s" % [oapp, ms.size(), (":\n" + "\n".join(ms.map(func(m): return "• %s %s (%s)" % [m["id"], m["name"], m["state"]]))) if not ms.is_empty() else ""]
			_confirm("Destroy %s?\nNot known by this Agent Manager: its files are deleted for good, nothing is checked for unpushed work." % what, func() -> void:
				_toast("Destroying…")
				var res := await engine.call_api("POST", "/sandboxes/orphans/destroy", {"app": oapp, "machine": omac, "confirmed": true}, true, 300.0)
				_toast(str(res["error"]) if res.has("error") else "Destroyed")
				await _load_sandboxes())))
		sbx_box.add_child(orow)


func _budget_panel(r: Dictionary) -> Control:
	# a monthly budget (warning at 80 %, no new sandbox at 100 %), optional caps that only pause, "Stop everything"
	var b: Dictionary = r.get("budget", {})
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_muted("Monthly budget $"))
	var amt := SpinBox.new()
	amt.max_value = 10000
	amt.step = 1
	amt.value = float(b.get("monthly_usd", 0))
	amt.tooltip_text = "0 = no budget. At 80 % a warning, at 100 % no new sandbox this month"
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
	over.text = "Pause everything at the budget"
	over.button_pressed = bool(b.get("stop_over_budget", false))
	row.add_child(over)
	row.add_child(_small("Save", func() -> void:
		var res := await engine.call_api("POST", "/sandboxes/budget", {"monthly_usd": amt.value, "stop_idle_minutes": int(idle.value), "stop_over_budget": over.button_pressed})
		_toast(str(res["error"]) if res.has("error") else "Budget saved")
		await _load_sandboxes()))
	box.add_child(row)
	var running: Array = (r.get("sandboxes", []) as Array).filter(func(x): return str(x["state"]) == "started")
	if not running.is_empty():
		var stop := _small("Stop everything (%d running)" % running.size(), func() -> void:
			_confirm("Pause the %d running sandbox(es)? Nothing is destroyed: start them again anytime." % running.size(), func() -> void:
				_toast("Pausing every sandbox…")
				await engine.call_api("POST", "/sandboxes/stop-all", {}, true, 300.0)
				await _load_sandboxes()))
		stop.size_flags_horizontal = SIZE_SHRINK_BEGIN
		box.add_child(stop)
	return box


func _chip(text: String, state) -> Label:
	# state: true (good), false (bad), "warn" (on purpose, e.g. paused), null (not known / not used)
	var l := Label.new()
	l.text = ("● " if state != null else "○ ") + text
	l.add_theme_font_size_override("font_size", 12)
	var c := AmTheme.col("FAINT")
	if state is bool:
		c = AmTheme.col("MINT") if state else AmTheme.col("ERROR")
	elif state is String and state == "warn":
		c = AmTheme.col("WARN")
	l.add_theme_color_override("font_color", c)
	return l


func _sandbox_card(sb: Dictionary, r: Dictionary) -> Control:
	var sbid := str(sb["id"])
	var st := str(sb["state"])
	var col: Color = {"started": AmTheme.col("MINT"), "stopped": AmTheme.col("WARN")}.get(st, AmTheme.col("ERROR"))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", AmTheme.box(AmTheme.col("PANEL"), 10, Color(col, 0.6), 1, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	card.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	v.add_child(top)
	var sess := _session(str(sb["session_id"]))
	var n := Label.new()
	n.text = "☁ " + str(sess.get("name", "session " + str(sb["session_id"])))
	n.add_theme_font_size_override("font_size", 16)
	n.add_theme_font_override("font", AmTheme.ui_font(650))
	top.add_child(n)
	var chip := Label.new()
	chip.text = {"started": "● running", "stopped": "● paused"}.get(st, "● " + st) + ("  · finished, ready to destroy" if int(sb["finished"]) == 1 else "")
	chip.add_theme_color_override("font_color", col)
	chip.add_theme_font_size_override("font_size", 12)
	top.add_child(chip)
	var live := Label.new()
	live.add_theme_font_override("font", AmTheme.ui_font(650))
	live.add_theme_font_size_override("font_size", 13)
	live.size_flags_horizontal = SIZE_EXPAND_FILL
	live.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if sb.get("running_since") != null:
		live.text = "on for " + _span(Time.get_unix_time_from_system() - float(sb["running_since"]))
		sbx_live.append([live, float(sb["running_since"])])
	else:
		live.text = "paused" if st == "stopped" else ""
	top.add_child(live)
	# health: what the monitor saw last (about once a minute while the terminal is open)
	var hl: Dictionary = sb.get("health") if sb.get("health") is Dictionary else {}
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 16)
	chips.add_child(_chip("machine " + {"started": "running", "stopped": "paused"}.get(st, st), true if st == "started" else ("warn" if st == "stopped" else false)))
	chips.add_child(_chip("terminal " + ("open" if hl.get("terminal", false) else "closed"), hl.get("terminal") if not hl.is_empty() else null))
	var tun := str(hl.get("tunnel", ""))
	chips.add_child(_chip("SSH tunnel " + (tun if tun != "" else "not checked") + (("  %d ms" % int(hl["latency_ms"])) if hl.get("latency_ms") != null else ""), (tun == "up") if tun != "" else null))
	var uses_brain := bool(sess.get("brain", false))
	chips.add_child(_chip("MCP Second Brain " + ("ready" if hl.get("mcp") == true else ("not ready" if hl.get("mcp") == false else ("not used" if not uses_brain else "not checked"))), hl.get("mcp") if uses_brain else null))
	if hl.has("checked"):
		chips.add_child(_muted("checked " + _span(Time.get_unix_time_from_system() - float(hl["checked"])) + " ago"))
	v.add_child(chips)
	# what is happening inside
	var what := HBoxContainer.new()
	what.add_theme_constant_override("separation", 18)
	var repo_name := str(sess.get("repo_name", ""))
	what.add_child(_muted("⎇ " + (repo_name + " · " if repo_name != "" else "") + (str(hl.get("branch", "")) if str(hl.get("branch", "")) != "" else "am/" + sbid)))
	if hl.get("dirty") != null:
		what.add_child(_muted("%d file(s) not committed · %d commit(s) not pushed" % [int(hl["dirty"]), int(hl["unpushed"])]))
	what.add_child(_muted(str(sess.get("tool_label", sess.get("tool", ""))) + " · " + str(sess.get("activity", sess.get("state", "")))))
	v.add_child(what)
	var money := _muted("cost today %s · this month %s · since it was made %s · %s %s · machine %s" % [
		CostChart.money(float(sb.get("cost_today", 0))), CostChart.money(float(sb.get("cost_month", 0))), CostChart.money(float(sb.get("cost_usd", 0))),
		str(sb["region"]), str(sb["size"]), str(sb["machine"])])
	money.add_theme_font_size_override("font_size", 12)
	money.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(money)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	row.add_child(_small("Open", func() -> void: select(str(sb["session_id"]))))
	row.add_child(_small("Check now", func() -> void:
		_toast("Checking the sandbox…")
		await engine.call_api("GET", "/sandboxes/%s/connection" % sbid, null, true, 90.0)
		await _load_sandboxes()))
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
	await _load_brain_keys()


## The Second Brain keys Agent Manager made (one per session or sandbox): what uses each one; unused ones can be
## revoked, one by one or all at once, always confirmed. A key in use goes away with its session or sandbox.
func _load_brain_keys() -> void:
	var r := await engine.call_api("GET", "/brain/keys", null, true, 30.0)
	if keys_list == null or not is_instance_valid(keys_list):
		return
	var t := Label.new()
	t.text = "Second Brain keys made by Agent Manager"
	t.add_theme_font_size_override("font_size", 15)
	t.add_theme_font_override("font", AmTheme.ui_font(650))
	keys_list.add_child(t)
	if r.has("error"):
		keys_list.add_child(_muted(str(r["error"])))
		return
	var keys: Array = r.get("keys", [])
	var unused: Array = keys.filter(func(k): return str(k["used_by"]) == "")
	keys_list.add_child(_muted("%d keys · %d in use · %d unused. A key in use goes away when its session or sandbox is removed." % [keys.size(), keys.size() - unused.size(), unused.size()]))
	if not unused.is_empty():
		var all_btn := _small("Revoke the %d unused keys…" % unused.size(), func() -> void:
			_confirm("Revoke %d Second Brain keys nothing uses any more?\n%s" % [unused.size(), "\n".join(unused.map(func(k): return "• %s (%s)" % [k["name"], k["id"]]))], func() -> void:
				for k in unused:
					await engine.call_api("POST", "/brain/keys/%s/revoke" % k["id"], {"confirmed": true}, true, 30.0)
				_toast("Revoked")
				await _load_keys()))
		all_btn.size_flags_horizontal = SIZE_SHRINK_BEGIN
		keys_list.add_child(all_btn)
	for k in keys:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var used := str(k["used_by"])
		var dot := Label.new()
		dot.text = "●" if used != "" else "○"
		dot.add_theme_color_override("font_color", AmTheme.col("MINT") if used != "" else AmTheme.col("FAINT"))
		row.add_child(dot)
		var n := Label.new()
		n.text = str(k["name"]).trim_prefix("Agent Manager · ")
		n.custom_minimum_size = Vector2(260, 0)
		row.add_child(n)
		var info := _muted(("used by " + used if used != "" else "unused") + "   ·   " + str(int(k.get("calls", 0) if k.get("calls") != null else 0)) + " calls" + ("   ·   last seen " + str(k["last_seen"]).substr(0, 16).replace("T", " ") if k.get("last_seen") else ""))
		info.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(info)
		if used == "":
			var cid := str(k["id"])
			var kname := str(k["name"])
			row.add_child(_small("Revoke…", func() -> void:
				_confirm("Revoke the Second Brain key « %s »?\nWhatever still holds it can no longer read or propose." % kname, func() -> void:
					var res := await engine.call_api("POST", "/brain/keys/%s/revoke" % cid, {"confirmed": true}, true, 30.0)
					_toast(str(res["error"]) if res.has("error") else "Revoked")
					await _load_keys())))
		keys_list.add_child(row)


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
	var where := OptionButton.new()
	where.add_item("I already have it on this computer")
	where.add_item("Clone it for me")
	where.tooltip_text = "Your own clone is used as it is (no second copy); otherwise Agent Manager clones it in its data folder"
	form.add_child(where)
	var form2 := HBoxContainer.new()
	form2.add_theme_constant_override("separation", 8)
	v.add_child(form2)
	var path := LineEdit.new()
	path.placeholder_text = "your folder: C:\\git-2026\\my-repo (its top folder)"
	path.size_flags_horizontal = SIZE_EXPAND_FILL
	form2.add_child(path)
	var browse := _small("Browse…", func() -> void:
		_pick_folder_then(path.text, func(dir: String) -> void: path.text = dir))
	form2.add_child(browse)
	where.item_selected.connect(func(i: int) -> void:
		path.visible = i == 0
		browse.visible = i == 0)
	var add := Button.new()
	add.text = "+ Add the repository"
	add.pressed.connect(func() -> void:
		var own := where.selected == 0
		if own and path.text.strip_edges() == "":
			_toast("Choose your folder (Browse…), or « Clone it for me »")
			return
		var r := await engine.call_api("POST", "/repos", {"url": url.text.strip_edges(), "local_path": path.text.strip_edges() if own else ""})
		if r.has("error"):
			_toast(str(r["error"]))
			return
		url.text = ""
		path.text = ""
		await _load_repos())
	form2.add_child(add)
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


## Where the repository lives on this computer: the owner's own clone or Agent Manager's copy, its origin, and
## « Change folder… » (then the old copy can be removed, after showing what is in it).
func _repo_folder_row(r: Dictionary) -> Control:
	var rid := str(r["id"])
	var f: Dictionary = r.get("folder", {})
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var shown := short_path(_win_path(str(f.get("path", ""))))
	var label := ""
	if shown == "":
		label = "Folder: Agent Manager clones it on first use"
	elif bool(f.get("managed", false)):
		label = "Folder: Agent Manager's copy · " + shown
	else:
		label = "Folder: yours · " + shown
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 13)
	row.add_child(l)
	var o := str(f.get("origin_state", ""))
	if o == "same":
		var ok := _muted("origin ✓")
		ok.add_theme_color_override("font_color", AmTheme.col("MINT"))
		row.add_child(ok)
	elif o == "missing":
		var w := _muted("no remote yet")
		w.add_theme_color_override("font_color", AmTheme.col("WARN"))
		row.add_child(w)
		row.add_child(_small("Add it as origin", func() -> void:
			var res := await engine.call_api("POST", "/repos/%s/origin" % rid, {})
			_toast(str(res["error"]) if res.has("error") else "origin added: " + str(r["url"]))
			await _load_repos(), "git remote add origin " + str(r["url"]) + " (nothing else is changed)"))
	elif o == "other":
		var x := _muted("origin is another repository: " + str(f.get("origin", "")))
		x.add_theme_color_override("font_color", AmTheme.col("ERROR"))
		row.add_child(x)
	var change := _small("Change folder…", func() -> void:
		_pick_folder_then(shown, func(dir: String) -> void:
			var res := await engine.call_api("POST", "/repos/%s/folder" % rid, {"path": dir})
			if res.has("error"):
				_toast(str(res["error"]))
				return
			_toast("%s now uses %s" % [r["name"], dir])
			if str(res.get("previous_copy", "")) != "":
				await _offer_remove_copy(str(res["previous_copy"]))
			await _load_repos()))
	change.tooltip_text = "Use your own clone of this repository (a git repository's top folder, or an empty folder)"
	row.add_child(change)
	return row


## On Windows, a WSL path of a Windows drive (/mnt/c/x) shown as the owner knows it (C:\x).
func _win_path(p: String) -> String:
	if engine.on_windows and p.length() > 6 and p.begins_with("/mnt/") and p[6] == "/":
		return p[5].to_upper() + ":\\" + p.substr(7).replace("/", "\\")
	return p


func _offer_remove_copy(copy: String) -> void:
	var c := await engine.call_api("POST", "/repos/copy/inspect", {"path": copy})
	if c.has("error"):
		return
	var what := "Nothing in it would be lost." if c.get("clean", false) else ("It holds work that would be LOST:\n" + str(c.get("report", "")).left(800))
	_confirm("Remove Agent Manager's old copy?\n%s\n\n%s" % [copy, what], func() -> void:
		var d := await engine.call_api("POST", "/repos/copy/remove", {"path": copy, "confirmed": true})
		_toast(str(d["error"]) if d.has("error") else "Old copy removed"))


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
	var meta := _muted("%s   ·   key %s   ·   added %s%s" % [r["url"], r["fingerprint"], _date(float(r["created"])), ("   ·   last used " + _date(float(r["last_used"]))) if float(r["last_used"]) > 0 else ""])
	v.add_child(_repo_folder_row(r))
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
	items.append({"label": "Orchestrator", "hint": "show or hide its panel · " + key_text("orchestrator"), "run": toggle_orchestrator})
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
## The New session form follows the group's default permission level (« auto » when the group has none).
func _group_level_default() -> void:
	var gname := str(f_group.get_selected_metadata()) if f_group.item_count > 0 else ""
	var lv := "auto"
	for g in tree:
		if str(g["name"]) == gname and str(g.get("level", "")) != "":
			lv = str(g["level"])
	for i in f_level.item_count:
		if str(f_level.get_item_metadata(i)) == lv:
			f_level.select(i)


func _create() -> void:
	if str(f_level.get_selected_metadata()) == "full":
		_confirm("Start « %s » with no permission?\n\nIt will run every command and edit any file without asking you. Your keys, ~/.ssh and .env files stay out of reach of its file tools, but a script it runs could still read them. Use it on a project you trust, ideally in a worktree." % (f_name.text.strip_edges() if f_name.text.strip_edges() != "" else "this session"), _create_now)
		return
	await _create_now()


func _create_now() -> void:
	if str(f_where.get_selected_metadata()) == "sandbox":
		_toast("Starting a cloud sandbox… (about 30 seconds)")
	var name := f_name.text.strip_edges()
	if name == "":
		name = str(f_tool.get_item_text(f_tool.selected)).substr(3)
	var r := await engine.call_api("POST", "/sessions", {"name": name, "tool": f_tool.get_selected_metadata(), "cwd": f_cwd.text.strip_edges(), "group": str(f_group.get_selected_metadata()) if f_group.item_count > 0 else "", "worktree": f_worktree.button_pressed, "brain": f_brain.button_pressed, "brief": f_brief.button_pressed and not f_brief.disabled, "repo": str(f_repo.get_selected_metadata()) if f_repo.item_count > 0 else "", "host": str(f_where.get_selected_metadata()), "remote": f_remote.button_pressed and not f_remote.disabled, "document": f_document.button_pressed and not f_document.disabled, "level": str(f_level.get_selected_metadata())}, true, 240.0 if str(f_where.get_selected_metadata()) == "sandbox" else 30.0)
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
	var sid := selected
	var nm := str(_session(sid).get("name", sid))
	_confirm("Remove « %s » and forget it?\nIts terminal is closed and it leaves the list and History. The agent's own conversation stays in Claude Code / Codex (claude --resume)." % nm, func() -> void:
		await _remove_now(sid))


func _remove_now(sid: String) -> void:
	selected = sid
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


## Approve or Refuse from the queue: the card says so at once and fades out; the session shows « working » right away
## (the engine keeps it so until the agent's next event), and it comes back only if the agent asks again.
func _answer(id: String, keys: Array, card: PanelContainer, said: String) -> void:
	var ok: bool = str(keys[0]) == "Enter"
	var colour: Color = activity_of({"activity": "done"})[0] if ok else AmTheme.col("MUTED")
	for c in card.get_children():
		c.queue_free()
	var l := Label.new()
	l.text = said
	l.add_theme_font_override("font", AmTheme.ui_font(650))
	l.add_theme_color_override("font_color", colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.add_child(l)
	card.add_theme_stylebox_override("panel", AmTheme.box(Color(colour, 0.12), 10, colour, 1, 9))
	var s := _session(id)
	if s:
		s["activity"] = "working" if ok else "idle"
		last_activity[id] = s["activity"]
		if cards.has(id) and is_instance_valid(cards[id]):
			cards[id].flash(colour)
	var t := create_tween()
	t.tween_interval(0.9)
	t.tween_property(card, "modulate:a", 0.0, 0.35)
	t.tween_callback(func() -> void:
		tree_sig = ""
		_render_list())
	await _keys(id, keys)


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
	group_menu.add_item("Default permission level…", 2)
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
			await refresh()
		elif mid == 2:
			level_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO)))
	add_child(group_menu)
	level_menu = PopupMenu.new()  # a group's default level for its new sessions
	level_menu.add_item("No default (auto)")
	level_menu.set_item_metadata(0, "")
	for k in LEVELS:
		level_menu.add_item(LEVELS[k][0])
		level_menu.set_item_metadata(level_menu.item_count - 1, k)
	level_menu.index_pressed.connect(func(i: int) -> void:
		var r := await engine.call_api("POST", "/groups/%s/level" % menu_target.uri_encode(), {"level": str(level_menu.get_item_metadata(i))})
		if r.has("error"):
			status_label.text = str(r["error"])
		else:
			_toast("New sessions in « %s »: %s" % [menu_target, str(level_menu.get_item_text(i))])
		await refresh())
	add_child(level_menu)
	theme_menu = PopupMenu.new()
	for t in AmTheme.THEMES:
		theme_menu.add_item(AmTheme.LABELS[t])
		theme_menu.set_item_metadata(theme_menu.item_count - 1, t)
	theme_menu.add_separator()
	theme_menu.add_item("Spoken status (on / off)")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__spoken")
	theme_menu.add_item("Chime when an agent waits (on / off)")
	theme_menu.set_item_metadata(theme_menu.item_count - 1, "__sound")
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
		elif m == "__sound":
			set_sound(not sound_on)
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
