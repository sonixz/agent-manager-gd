extends RefCounted
## The Repos page's drawn pieces (Loop 37): the tiles above the lines, and what stands in each column of a line: the
## host's chip, the key's state with how fresh its check is, what the key opens, the folder's branch and what waits
## in it, a dot per session, the sessions started day by day. Drawn by hand, like the engine room's dashboard.
##
## A state is never said by its colour alone: its shape or its words change with it. What each piece shows is worked
## out in scripts/repo_view.gd, where the headless cases check it.
## Loaded with preload, not by a class name (see setup_probe.gd).

const RepoView := preload("res://scripts/repo_view.gd")


# ====================================================================== the base of every piece in a line
class Piece extends Control:
	var font: Font  # kept for the piece's life: a font made inside _draw is freed before the frame is drawn
	var bold: Font

	func _init(width: float, tip := "") -> void:
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size = Vector2(width, 30)
		tooltip_text = tip
		mouse_filter = Control.MOUSE_FILTER_STOP  # so its tooltip shows

	func base() -> float:
		return size.y / 2.0 + 5.0

	func cy() -> float:
		return size.y / 2.0


# ====================================================================== the host
## A chip with the host's sign: a disc for GitHub, a diamond for Azure DevOps, a ring for another host.
class HostChip extends Piece:
	var label: String
	var kind: String

	func _init(r: Dictionary, width: float) -> void:
		super(width, str(r.get("host", "")))
		label = RepoView.host_label(r)
		kind = str(r.get("host_kind", ""))

	func _draw() -> void:
		var col: Color = {"github": AmTheme.col("MUTED"), "azure": AmTheme.col("INFO")}.get(kind, AmTheme.col("FAINT"))
		var w := minf(size.x - 8.0, font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 34.0)
		var box := Rect2(0, cy() - 11.0, w, 22.0)
		draw_style_box(AmTheme.box(Color(col, 0.13), 11, Color(col, 0.5), 1, 0), box)
		var c := Vector2(12.0, cy())
		if kind == "github":
			draw_circle(c, 4.0, col)
		elif kind == "azure":
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0)]), col)
		else:
			draw_arc(c, 4.0, 0.0, TAU, 20, col, 1.5, true)
		draw_string(font, Vector2(23.0, base() - 0.5), label, HORIZONTAL_ALIGNMENT_LEFT, w - 30.0, 12, AmTheme.col("TEXT"))


# ====================================================================== the key
## The key's state: its sign, its words, and under them a thin bar that empties in ten minutes, the age at which the
## page checks the key again. While it is being checked, the sign turns.
class KeyPill extends Piece:
	var words: String
	var level: String
	var fresh: float
	var busy: bool

	func _init(r: Dictionary, now: float, width: float) -> void:
		var cell: Dictionary = RepoView.key_cell(r, now)
		super(width, str(r.get("message", "")) if str(r.get("message", "")) != "" else str(cell["text"]) + "\nThe bar empties in ten minutes: the page then checks the key again when it is opened.")
		words = str(cell["text"])
		level = str(cell["level"])
		busy = (r.get("busy", []) as Array).has("key")
		fresh = RepoView.freshness(r, now)
		set_process(busy)

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var col: Color = {"warn": AmTheme.col("WARN"), "bad": AmTheme.col("ERROR")}.get(level, AmTheme.col("MINT"))
		var c := Vector2(8.0, cy())
		if busy:
			var a := Time.get_ticks_msec() * 0.007
			draw_arc(c, 5.5, a, a + 4.4, 18, col, 2.0, true)
		elif level == "bad":
			draw_line(c + Vector2(-4, -4), c + Vector2(4, 4), col, 2.0, true)
			draw_line(c + Vector2(-4, 4), c + Vector2(4, -4), col, 2.0, true)
		elif level == "warn":
			draw_arc(c, 4.5, 0.0, TAU, 20, col, 2.0, true)
		else:
			draw_circle(c, 4.5, col)
		draw_string(font, Vector2(21.0, base() - (2.0 if level == "ok" and not busy else 0.0)), words, HORIZONTAL_ALIGNMENT_LEFT, size.x - 26.0, 13, AmTheme.col("TEXT") if level == "ok" else col)
		if level == "ok" and not busy:
			var track := Rect2(21.0, size.y - 5.0, minf(96.0, size.x - 30.0), 2.0)
			draw_rect(track, Color(AmTheme.col("BORDER"), 0.8))
			if fresh > 0.0:
				draw_rect(Rect2(track.position, Vector2(track.size.x * fresh, 2.0)), col)


# ====================================================================== what the key opens
## One small square for « this repository only », a pile of them for « your whole account ».
class OpensMark extends Piece:
	var scope: String
	var words: String
	var host: String

	func _init(r: Dictionary, width: float) -> void:
		host = RepoView.host_label(r)
		scope = str(r.get("key_scope", ""))
		words = RepoView.opens_cell(r)
		var why := "The key Agent Manager made for it opens %s on %s." % ["only this repository" if scope == "repository" else "what that host lets it open", host]
		if scope == "account":
			why = "Azure DevOps has no key per repository: this key, on your profile, opens everything your account reaches there. To keep agents to chosen repositories, add it to an account made for them."
		super(width, why)

	func _draw() -> void:
		var wide := scope == "account"
		var col := AmTheme.col("WARN") if wide else AmTheme.col("MUTED")
		var at := Vector2(2.0, cy() - 5.0)
		if wide:
			for i in [2, 1, 0]:
				var b := Rect2(at + Vector2(i * 4.0, -i * 3.0 + 3.0), Vector2(10, 10))
				draw_rect(b, AmTheme.col("PANEL"))
				draw_rect(b, col, false, 1.5)
		elif scope == "repository":
			draw_rect(Rect2(at + Vector2(2, 0), Vector2(10, 10)), col, false, 1.5)
		else:
			draw_arc(at + Vector2(7, 5), 5.0, 0.0, TAU, 20, col, 1.5, true)
		draw_string(font, Vector2(26.0, base()), words, HORIZONTAL_ALIGNMENT_LEFT, size.x - 30.0, 13, AmTheme.col("TEXT") if wide else AmTheme.col("MUTED"))


# ====================================================================== the folder
## Whose folder it is, its branch in a chip, then what waits in it: commits not pushed, commits behind, files changed.
class FolderMark extends Piece:
	var f: Dictionary
	var cell: Dictionary

	func _init(r: Dictionary, width: float) -> void:
		super(width, RepoView.folder_tip(r))
		f = r.get("folder", {})
		cell = RepoView.folder_cell(r)

	func _draw() -> void:
		var muted := AmTheme.col("MUTED")
		var plain := not bool(f.get("read", false)) or not bool(f.get("git", false)) or str(f.get("origin_state", "")) != "same" or str(f.get("path", "")) == ""
		if plain:  # nothing to draw a branch from: the words say what there is
			var col: Color = {"warn": AmTheme.col("WARN"), "bad": AmTheme.col("ERROR")}.get(cell["level"], muted)
			draw_string(font, Vector2(0, base()), str(cell["text"]), HORIZONTAL_ALIGNMENT_LEFT, size.x - 6.0, 13, col)
			return
		var who := "its copy" if bool(f.get("managed", false)) else "yours"
		draw_string(font, Vector2(0, base()), who, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, muted)
		var x := font.get_string_size(who, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 8.0
		var branch := str(f.get("branch", "")) if str(f.get("branch", "")) != "" else "no branch"
		var bw := minf(font.get_string_size(branch, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 16.0, maxf(40.0, size.x - x - 96.0))
		draw_style_box(AmTheme.box(AmTheme.col("PANEL_2"), 6, AmTheme.col("BORDER"), 1, 0), Rect2(x, cy() - 10.0, bw, 20.0))
		draw_string(font, Vector2(x + 8.0, base() - 0.5), branch, HORIZONTAL_ALIGNMENT_LEFT, bw - 14.0, 12, AmTheme.col("TEXT"))
		x += bw + 9.0
		var ahead := int(f.get("ahead", 0))
		var behind := int(f.get("behind", 0))
		var changed := int(f.get("changed", 0))
		if ahead > 0:  # a triangle that points up: commits not pushed
			draw_colored_polygon(PackedVector2Array([Vector2(x, cy() + 4), Vector2(x + 8, cy() + 4), Vector2(x + 4, cy() - 4)]), AmTheme.col("MINT"))
			draw_string(bold, Vector2(x + 11.0, base()), str(ahead), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AmTheme.col("TEXT"))
			x += 13.0 + bold.get_string_size(str(ahead), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 8.0
		if behind > 0:  # one that points down: commits behind what was last fetched
			draw_colored_polygon(PackedVector2Array([Vector2(x, cy() - 4), Vector2(x + 8, cy() - 4), Vector2(x + 4, cy() + 4)]), AmTheme.col("INFO"))
			draw_string(bold, Vector2(x + 11.0, base()), str(behind), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AmTheme.col("TEXT"))
			x += 13.0 + bold.get_string_size(str(behind), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 8.0
		if changed > 0:  # a small square: files changed or new, not committed
			draw_rect(Rect2(x, cy() - 4.0, 8, 8), AmTheme.col("WARN"))
			draw_string(bold, Vector2(x + 12.0, base()), str(changed), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AmTheme.col("TEXT"))


# ====================================================================== the sessions
## A dot per open session, in the colour the session list gives its state; the running ones first, and a session
## at work breathes. A click on a running one shows it. Past six, a figure says how many more.
class SessionDots extends Piece:
	signal picked(id: String)
	const STEP := 15.0
	const MAX := 6
	var dots: Array
	var colours: Array  # one per dot: what the app's own list shows for that session's state

	func _init(the_dots: Array, the_colours: Array, width: float) -> void:
		var tip := []
		for d in the_dots:
			tip.append("%s: %s" % [d["name"], "not running" if not d["running"] else (str(d["activity"]) if str(d["activity"]) != "" else "running")])
		super(width, "\n".join(tip) + ("\nClick a running one to show it." if the_dots.any(func(d: Dictionary) -> bool: return d["running"]) else "") if not tip.is_empty() else "No session is open on it.")
		dots = the_dots
		colours = the_colours
		set_process(dots.any(func(d: Dictionary) -> bool: return d["running"] and str(d["activity"]) == "working"))

	func _process(_delta: float) -> void:
		queue_redraw()

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			var i := int(floor((e.position.x - 1.0) / STEP))
			if i >= 0 and i < mini(dots.size(), MAX) and dots[i]["running"]:
				picked.emit(str(dots[i]["id"]))

	func _draw() -> void:
		if dots.is_empty():
			draw_string(font, Vector2(2, base()), "–", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AmTheme.col("FAINT"))
			return
		var breath := 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.004)
		for i in mini(dots.size(), MAX):
			var c := Vector2(7.0 + i * STEP, cy())
			var d: Dictionary = dots[i]
			var col: Color = colours[i]
			if not d["running"]:
				draw_arc(c, 4.0, 0.0, TAU, 18, AmTheme.col("FAINT"), 1.5, true)  # open, not running: a ring
			elif str(d["activity"]) == "working":
				draw_circle(c, 5.0, Color(col, breath))
			else:
				draw_circle(c, 5.0, col)
		if dots.size() > MAX:
			draw_string(font, Vector2(7.0 + MAX * STEP, base()), "+%d" % (dots.size() - MAX), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AmTheme.col("MUTED"))


# ====================================================================== the sessions started, day by day
## Fourteen thin bars: the sessions started on it each day, today at the right. A day without any is a faint mark.
class StartedStrip extends Piece:
	var counts: Array

	func _init(the_counts: Array, last_used: String, width: float) -> void:
		var total := 0
		for c in the_counts:
			total += int(c)
		super(width, "%d session%s started on it in the last %d days, day by day, today at the right.\nIts key was last used: %s." % [total, "" if total == 1 else "s", the_counts.size(), last_used])
		counts = the_counts

	func _draw() -> void:
		var top := 1
		for c in counts:
			top = maxi(top, int(c))
		var slot := 6.0
		var h := 18.0
		for i in counts.size():
			var x := 2.0 + i * slot
			var v := int(counts[i])
			if v <= 0:
				draw_rect(Rect2(x, cy() + h / 2.0 - 2.0, 4, 2), Color(AmTheme.col("FAINT"), 0.55))
			else:
				var bh := maxf(4.0, h * v / float(top))
				draw_rect(Rect2(x, cy() + h / 2.0 - bh, 4, bh), AmTheme.col("MINT"))


# ====================================================================== the tiles above the lines
class Tiles extends Control:
	const H := 74.0
	const GAP := 10.0
	var items: Array = []
	var font: Font
	var bold: Font

	func _init(the_items: Array) -> void:
		items = the_items
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size.y = H
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var n := maxi(items.size(), 1)
		var w := (size.x - GAP * (n - 1)) / n
		for i in items.size():
			var t: Dictionary = items[i]
			var at := Vector2(i * (w + GAP), 0)
			var lv := str(t["level"])
			var col: Color = {"warn": AmTheme.col("WARN"), "bad": AmTheme.col("ERROR")}.get(lv, AmTheme.col("BORDER"))
			draw_style_box(AmTheme.box(AmTheme.col("PANEL"), 10, col, 1, 0), Rect2(at, Vector2(w, H)))
			var x := at.x + 14.0
			if lv != "ok":  # a state is never said by its colour alone
				draw_string(bold, Vector2(x, at.y + 22.0), "!" if lv == "warn" else "✗", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
				x += 13.0
			draw_string(font, Vector2(x, at.y + 22.0), str(t["label"]), HORIZONTAL_ALIGNMENT_LEFT, w - 28.0, 12, AmTheme.col("MUTED"))
			draw_string(bold, Vector2(at.x + 14.0, at.y + 48.0), str(t["value"]), HORIZONTAL_ALIGNMENT_LEFT, 60.0, 22, AmTheme.col("TEXT"))
			var vw := bold.get_string_size(str(t["value"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
			draw_string(font, Vector2(at.x + 14.0 + vw + 10.0, at.y + 47.0), str(t["note"]), HORIZONTAL_ALIGNMENT_LEFT, w - 38.0 - vw, 12, AmTheme.col("MUTED"))
