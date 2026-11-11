class_name SessionCard
extends PanelContainer
## One session in the sidebar. As a tile: tool badge, name, what it is doing (animated dot), the agent's last words,
## time in this state, folder and git branch. As a line (the compact list, one session per line): state dot, tool,
## name, short marks and the state in a word; the rest is in its tooltip. Main wires clicks, drag and drop and the menu.

signal picked(id: String)
signal menu(id: String)
signal rename(id: String)

const LEVEL_BADGE := {  # Loop 24: the permission level, when it is not « auto » (Claude Code's own default)
	"ask": ["asks first", "Asks before editing files or running commands"],
	"edits": ["auto edits", "Auto edits: edits files without asking, asks before other commands"],
	"full": ["⚠ no permission", "Never asks. Your keys, ~/.ssh and .env files stay out of reach of its file tools; a script it runs is not stopped"],
	"config": ["your config", "Agent Manager passes no permission option: your own Claude Code or Codex settings decide"],
}
const TOOL_BADGE := {"claude": ["✻", Color("d97757")], "codex": ["◎", Color("10a37f")], "shell": ["❯", Color("8b98a8")]}
# On a line there is room for a word, not a sentence.
const LINE_LEVEL := {"ask": "asks", "edits": "edits", "full": "⚠", "config": "config"}
const LINE_STATE := {"waits for your OK": "your OK", "asks you something": "asks you", "gone · Resume brings it back": "gone", "writing its summary": "summary"}

var id := ""
var data := {}
var dot: Panel
var brain_mark: Label
var _pulse: Tween
var _glow: Tween


func setup(s: Dictionary, selected: bool, activity: Array, line := false) -> void:
	data = s
	id = str(s["id"])
	mouse_filter = MOUSE_FILTER_STOP
	if line:
		_setup_line(s, selected, activity)
		return
	var acc: Color = activity[0]
	var attention := str(s.get("activity", "")) in ["approval", "waiting"]
	var bg := AmTheme.col("PANEL_2") if selected else AmTheme.col("PANEL")
	var border := AmTheme.col("MINT") if selected else (acc.darkened(0.15) if attention else AmTheme.col("BORDER"))
	add_theme_stylebox_override("panel", AmTheme.box(bg, 10, border, 1, 10))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(h)
	# tool badge with the state dot on its corner
	var badge := Panel.new()
	badge.custom_minimum_size = Vector2(34, 34)
	badge.mouse_filter = MOUSE_FILTER_IGNORE
	var tb: Array = TOOL_BADGE.get(str(s["tool"]), ["•", AmTheme.col("MUTED")])
	badge.add_theme_stylebox_override("panel", AmTheme.box(Color(tb[1], 0.18), 9, Color(tb[1], 0.55), 1, 0))
	var glyph := Label.new()
	glyph.text = tb[0]
	glyph.add_theme_color_override("font_color", tb[1])
	glyph.add_theme_font_size_override("font_size", 17)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.set_anchors_preset(PRESET_FULL_RECT)
	glyph.mouse_filter = MOUSE_FILTER_IGNORE
	badge.add_child(glyph)
	dot = Panel.new()
	dot.size = Vector2(11, 11)
	dot.position = Vector2(26, -3)
	dot.mouse_filter = MOUSE_FILTER_IGNORE
	var ds := StyleBoxFlat.new()
	ds.bg_color = acc
	ds.set_corner_radius_all(6)
	ds.border_color = bg
	ds.set_border_width_all(2)
	dot.add_theme_stylebox_override("panel", ds)
	badge.add_child(dot)
	var badge_wrap := VBoxContainer.new()
	badge_wrap.mouse_filter = MOUSE_FILTER_IGNORE
	badge_wrap.add_child(badge)
	h.add_child(badge_wrap)
	# text column
	var v := VBoxContainer.new()
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 1)
	v.mouse_filter = MOUSE_FILTER_IGNORE
	h.add_child(v)
	var top := HBoxContainer.new()
	top.mouse_filter = MOUSE_FILTER_IGNORE
	v.add_child(top)
	var name := _label(("☁ " if str(s.get("host", "")) == "sandbox" else "") + str(s["name"]), AmTheme.col("TEXT"), 14, 600)
	name.size_flags_horizontal = SIZE_EXPAND_FILL
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.add_child(name)
	top.add_child(_label(_ago(float(s.get("since", 0))), AmTheme.col("FAINT"), 11))
	var lv := str(s.get("level", "auto"))
	if str(s.get("tool", "")) != "shell" and lv in LEVEL_BADGE:
		var b: Array = LEVEL_BADGE[lv]
		var lm := _label(b[0], AmTheme.col("WARM") if lv == "full" else AmTheme.col("MUTED"), 11, 650 if lv == "full" else 400)
		lm.mouse_filter = MOUSE_FILTER_PASS
		lm.tooltip_text = b[1]
		top.add_child(lm)
	var access := str(s.get("access", "open"))
	if str(s.get("tool", "")) != "shell" and access in ["contained", "readonly"]:   # Loop 29
		var sys_on := bool(s.get("os_sandbox", false))
		var am := _label(("■ " if sys_on else "▣ ") + ("contained" if access == "contained" else "read only"), AmTheme.col("MUTED"), 11)
		am.mouse_filter = MOUSE_FILTER_PASS
		am.tooltip_text = "Its file tools stay in its folder (and the extra ones)" + (", without editing" if access == "readonly" else "") + (". Shell commands too: contained by the system (Claude Code's sandbox)." if sys_on else ". Shell commands are not contained: a guard rail.")
		top.add_child(am)
	var gr: Dictionary = s.get("git_rights", {})
	if str(s.get("tool", "")) == "claude" and not gr.is_empty() and bool(gr.get("push", false)) and not bool(gr.get("default", true)):
		var gp := _label("⇡ may push", AmTheme.col("WARM"), 11)   # Loop 28: the owner enabled git push for it
		gp.mouse_filter = MOUSE_FILTER_PASS
		gp.tooltip_text = "You enabled git push for this session (the orchestrator's sessions may not by default)"
		top.add_child(gp)
	if s.get("level_pending", false):  # Loop 27: a new level waits for the end of its turn
		var pm := _label("↻ new level after this turn", AmTheme.col("MUTED"), 11)
		pm.mouse_filter = MOUSE_FILTER_PASS
		pm.tooltip_text = "It starts again on its own conversation with its new permission level when its turn ends"
		top.add_child(pm)
	brain_mark = _label("", AmTheme.col("FAINT"), 15)
	brain_mark.mouse_filter = MOUSE_FILTER_PASS
	brain_mark.pivot_offset = Vector2(6, 9)
	top.add_child(brain_mark)
	v.add_child(_label("%s · %s" % [s["tool_label"], activity[1]], acc if attention or str(s.get("activity", "")) == "working" else AmTheme.col("MUTED"), 12))
	var msg := str(s.get("message", "")).replace("\n", " ").strip_edges()
	if msg != "":
		var m := _label(("runs " + msg) if str(s["tool"]) == "shell" else "“%s”" % msg, AmTheme.col("MUTED"), 11)
		m.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		m.custom_minimum_size = Vector2(10, 0)
		v.add_child(m)
	var w := _label(_where(s), AmTheme.col("FAINT"), 11)
	w.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	w.custom_minimum_size = Vector2(10, 0)
	w.tooltip_text = str(s["cwd"])
	v.add_child(w)
	tooltip_text = str(s["cwd"])
	dot.pivot_offset = dot.size / 2
	_animate(str(s.get("activity", "")), attention)


## One session per line: the state dot, the tool, the name, short marks, the ✦ light and the state in a word.
func _setup_line(s: Dictionary, selected: bool, activity: Array) -> void:
	var acc: Color = activity[0]
	var act := str(s.get("activity", ""))
	var attention := act in ["approval", "waiting"]
	var agent := str(s.get("tool", "")) != "shell"
	var sb := StyleBoxFlat.new()
	sb.bg_color = AmTheme.col("PANEL_2") if selected else (Color(acc, 0.10) if attention else Color(AmTheme.col("PANEL"), 0.0))
	sb.border_color = AmTheme.col("MINT") if selected else (acc.darkened(0.15) if attention else Color(0, 0, 0, 0))
	sb.set_border_width_all(1)  # always there, so a line never moves when it is selected
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	sb.anti_aliasing = true
	add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 7)
	h.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(h)
	if str(s.get("parent_name", "")) != "":  # started by an agent: under it
		h.add_child(_label("↳", AmTheme.col("FAINT"), 12))
	var dw := CenterContainer.new()
	dw.mouse_filter = MOUSE_FILTER_IGNORE
	dw.custom_minimum_size = Vector2(11, 0)
	dot = Panel.new()
	dot.custom_minimum_size = Vector2(9, 9)
	dot.pivot_offset = Vector2(4.5, 4.5)
	dot.mouse_filter = MOUSE_FILTER_IGNORE
	var ds := StyleBoxFlat.new()
	ds.bg_color = acc
	ds.set_corner_radius_all(5)
	dot.add_theme_stylebox_override("panel", ds)
	dw.add_child(dot)
	h.add_child(dw)
	var tb: Array = TOOL_BADGE.get(str(s["tool"]), ["•", AmTheme.col("MUTED")])
	var glyph := _label(tb[0], tb[1], 13)
	glyph.custom_minimum_size = Vector2(14, 0)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	h.add_child(glyph)
	var quiet := act in ["exited", "missing", "archived"] or str(s.get("state", "")) in ["exited", "missing"]
	var name := _label(("☁ " if str(s.get("host", "")) == "sandbox" else "") + str(s["name"]), AmTheme.col("MUTED") if quiet else AmTheme.col("TEXT"), 13, 600 if selected or attention else 400)
	name.size_flags_horizontal = SIZE_EXPAND_FILL
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name.custom_minimum_size = Vector2(10, 0)
	h.add_child(name)
	var lv := str(s.get("level", "auto"))
	if agent and lv in LINE_LEVEL:
		h.add_child(_label(LINE_LEVEL[lv], AmTheme.col("WARM") if lv == "full" else AmTheme.col("MUTED"), 11, 650 if lv == "full" else 400))
	var access := str(s.get("access", "open"))
	if agent and access in ["contained", "readonly"]:
		h.add_child(_label("■" if bool(s.get("os_sandbox", false)) else "▣", AmTheme.col("MUTED"), 11))
	if _may_push(s):
		h.add_child(_label("⇡", AmTheme.col("WARM"), 11))
	if s.get("level_pending", false):
		h.add_child(_label("↻", AmTheme.col("MUTED"), 11))
	brain_mark = _label("", AmTheme.col("FAINT"), 13)
	brain_mark.mouse_filter = MOUSE_FILTER_PASS
	brain_mark.pivot_offset = Vector2(5, 8)
	h.add_child(brain_mark)
	var st := _label(LINE_STATE.get(str(activity[1]), str(activity[1])), acc if attention or act == "working" else AmTheme.col("MUTED"), 11)
	st.custom_minimum_size = Vector2(50, 0)  # one column for the states, so the marks before it line up too
	st.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(st)
	tooltip_text = _details(s, activity)
	_animate(act, attention)


## Everything a tile shows, for a line's tooltip.
func _details(s: Dictionary, activity: Array) -> String:
	var agent := str(s.get("tool", "")) != "shell"
	var since := _ago(float(s.get("since", 0)))
	var lines := PackedStringArray(["%s · %s · %s%s" % [s["name"], s["tool_label"], activity[1], (" · " + since) if since != "" else ""]])
	var msg := str(s.get("message", "")).replace("\n", " ").strip_edges()
	if msg != "":
		msg = msg.left(180) + ("…" if msg.length() > 180 else "")
		lines.append(("runs " + msg) if not agent else "“%s”" % msg)
	lines.append(_where(s))
	var lv := str(s.get("level", "auto"))
	if agent and lv in LEVEL_BADGE:
		lines.append("%s: %s" % [LEVEL_BADGE[lv][0], LEVEL_BADGE[lv][1]])
	var access := str(s.get("access", "open"))
	if agent and access in ["contained", "readonly"]:
		lines.append(("■ " if bool(s.get("os_sandbox", false)) else "▣ ") + ("contained: its file tools stay in its folder" if access == "contained" else "read only: its folder only, no edits"))
	if _may_push(s):
		lines.append("⇡ may push: you enabled git push for this session")
	if s.get("level_pending", false):
		lines.append("↻ a new permission level applies at the end of its turn")
	lines.append(str(s["cwd"]))
	return "\n".join(lines)


## Where it works: its repository or folder, its branch, Remote Control, and the agent that started it.
func _where(s: Dictionary) -> String:
	var where := ("⎇ " + str(s["repo_name"])) if str(s.get("repo_name", "")) != "" else (str(s["cwd"]).get_file() if str(s["cwd"]).get_file() != "" else str(s["cwd"]))
	var meta := "▸ " + where + ("   ⎇ " + str(s["branch"]) if str(s.get("branch", "")) != "" else "")  + ("   ⇄ claude.ai" if s.get("remote_control", false) else "")
	if str(s.get("parent_name", "")) != "":
		meta = "↳ " + str(s["parent_name"]) + "   " + meta
	return meta


## Loop 28: the owner enabled git push for a session that may not by default.
func _may_push(s: Dictionary) -> bool:
	var gr: Dictionary = s.get("git_rights", {})
	return str(s.get("tool", "")) == "claude" and not gr.is_empty() and bool(gr.get("push", false)) and not bool(gr.get("default", true))


## The dot breathes while the agent works and beats when it waits for you.
func _animate(act: String, attention: bool) -> void:
	if act == "working":
		_pulse = create_tween().set_loops()
		_pulse.tween_property(dot, "modulate:a", 0.25, 0.7).set_trans(Tween.TRANS_SINE)
		_pulse.tween_property(dot, "modulate:a", 1.0, 0.7).set_trans(Tween.TRANS_SINE)
	elif attention:
		_pulse = create_tween().set_loops()
		_pulse.tween_property(dot, "scale", Vector2(1.35, 1.35), 0.45).set_trans(Tween.TRANS_BACK)
		_pulse.tween_property(dot, "scale", Vector2.ONE, 0.45)


## The ✦ light (main calls it at each Brain check): its look, its details on hover, a glow when it just used the Brain.
func set_brain(info: Dictionary, glow: bool) -> void:
	var look := brain_look(info, str(data.get("tool", "")) != "shell")
	brain_mark.text = look[0]
	brain_mark.add_theme_color_override("font_color", look[1])
	brain_mark.tooltip_text = look[2]
	if glow and look[0] != "":
		if _glow:
			_glow.kill()
		_glow = create_tween()
		for i in 3:
			_glow.tween_property(brain_mark, "scale", Vector2(1.45, 1.45), 0.35).set_trans(Tween.TRANS_SINE)
			_glow.tween_property(brain_mark, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_SINE)


## How a session's ✦ looks, as [glyph, colour, details]: ✧ faint (an agent without the Brain), ✦ soft violet (a key
## of its own), ✦ violet (it also documents: the directive is in its instructions), ✦ amber (it documents but has
## proposed nothing for a while), ✦ soft red (its key no longer works, or the Brain stopped). Never the key itself.
static func brain_look(info: Dictionary, agent: bool) -> Array:
	if info.is_empty():
		return ["✧", Color(AmTheme.col("FAINT"), 0.7), "No Second Brain for this session"] if agent else ["", Color.TRANSPARENT, ""]
	var doc := bool(info.get("document", false))
	var lines := PackedStringArray(["✦ Second Brain: a key of its own, for this session only" + ("\nIt documents its work: the directive is in its instructions" if doc else "")])
	var calls := int(info.get("calls", 0))
	var seen := float(info.get("last_seen", 0))
	lines.append("%d call%s to the Brain%s" % [calls, "" if calls == 1 else "s", (", the last " + _ago(seen) + (" ago" if _ago(seen) != "now" else "")) if seen > 0 else ""])
	var n := int(info.get("proposals", 0))
	if n > 0:
		lines.append("%d proposal%s: %d accepted, %d waiting, %d refused" % [n, "" if n == 1 else "s", int(info.get("applied", 0)), int(info.get("pending", 0)), int(info.get("refused", 0))])
	else:
		lines.append("No proposal yet")
	var problem := str(info.get("problem", ""))
	if problem != "":
		lines.insert(0, "Problem: " + problem)
		return ["✦", Color(AmTheme.col("ERROR"), 0.85), "\n".join(lines)]
	if bool(info.get("quiet", false)):
		lines.append("It documents, but has proposed nothing for a while: ask it for its session journal?")
		return ["✦", AmTheme.col("WARN"), "\n".join(lines)]
	return ["✦", AmTheme.brain() if doc else Color(AmTheme.brain(), 0.55), "\n".join(lines)]


## A soft flash when the state changes (main calls it).
func flash(color: Color) -> void:
	var ov := Panel.new()
	ov.mouse_filter = MOUSE_FILTER_IGNORE
	ov.set_anchors_preset(PRESET_FULL_RECT)
	ov.add_theme_stylebox_override("panel", AmTheme.box(Color(color, 0.22), 10, Color(0, 0, 0, 0), 0, 0))
	add_child(ov)
	var t := create_tween()
	t.tween_property(ov, "modulate:a", 0.0, 0.9).set_trans(Tween.TRANS_QUAD)
	t.tween_callback(ov.queue_free)


func _gui_input(e: InputEvent) -> void:
	if not e is InputEventMouseButton:
		return
	# Selecting rebuilds the list, so it happens on release: on press it would free this card mid-drag.
	if e.pressed and e.button_index == MOUSE_BUTTON_LEFT and e.double_click:
		rename.emit(id)
	elif not e.pressed and e.button_index == MOUSE_BUTTON_LEFT and not get_viewport().gui_is_dragging():
		picked.emit(id)
	elif e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
		menu.emit(id)


func _label(t: String, color: Color, size: int, weight := 400) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	if weight != 400:
		l.add_theme_font_override("font", AmTheme.ui_font(weight))
	l.mouse_filter = MOUSE_FILTER_IGNORE
	return l


static func _ago(t: float) -> String:
	if t <= 0:
		return ""
	var d := int(Time.get_unix_time_from_system() - t)
	if d < 60:
		return "now"
	if d < 3600:
		return "%d min" % (d / 60)
	if d < 86400:
		return "%d h" % (d / 3600)
	return "%d d" % (d / 86400)
