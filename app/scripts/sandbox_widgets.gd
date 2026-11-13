extends RefCounted
## The Sandboxes page's drawn pieces: the inventory, one line per sandbox ever made from here with its life over the
## last thirty days as a bar (owner, 2026-11-12: « il faut toujours avoir l'inventaire »). Drawn by hand, like the
## engine room's dashboard. What it shows is worked out in scripts/sandbox_view.gd, where the cases check it.
## Loaded with preload, not by a class name (see setup_probe.gd).

const SandboxView := preload("res://scripts/sandbox_view.gd")
const HostView := preload("res://scripts/host_view.gd")


## One line per sandbox: its state (a sign and its word), its name, its size and region, then its life: a bar from
## thirty days ago to now, filled where its machine ran, with a mark where it was made and a cross where it was
## destroyed; then how long it ran in all and what that cost. A machine that runs now breathes at the bar's end.
class Life extends Control:
	const HEAD := 30.0
	const ROW := 34.0
	const STATE_W := 150.0
	const SIZE_W := 190.0
	const RAN_W := 96.0
	const COST_W := 84.0
	var rows: Array = []
	var now: float
	var bias: int
	var hover := -1
	var font: Font
	var bold: Font

	func _init(inv: Dictionary, the_bias: int) -> void:
		rows = SandboxView.order(inv.get("sandboxes", []))
		now = float(inv.get("now", Time.get_unix_time_from_system()))
		bias = the_bias
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size.y = HEAD + rows.size() * ROW + 6.0
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_exited.connect(func() -> void:
			hover = -1
			queue_redraw())
		set_process(rows.any(func(r: Dictionary) -> bool: return bool(r.get("running_now", false))))

	var _since := 0.0

	func _process(delta: float) -> void:  # an animation: 30 images a second, and only while it is seen
		_since += delta
		if _since >= 1.0 / 30.0 and is_visible_in_tree():
			_since = 0.0
			queue_redraw()

	func row_at(y: float) -> int:
		var i := int(floor((y - HEAD) / ROW)) if y >= HEAD else -1
		return i if i < rows.size() else -1

	func _get_tooltip(at: Vector2) -> String:
		var i := row_at(at.y)
		return SandboxView.tip(rows[i], now, bias) if i >= 0 else ""

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseMotion:
			var i := row_at(e.position.y)
			if i != hover:
				hover = i
				queue_redraw()

	## Narrow (a column of the dashboard): the state is its sign alone and the size goes to the tooltip.
	func narrow() -> bool:
		return size.x < 1000.0

	func state_w() -> float:
		return 30.0 if narrow() else STATE_W

	func size_w() -> float:
		return 0.0 if narrow() else SIZE_W

	func name_w() -> float:
		return clampf(size.x * 0.2, 130.0, 300.0)

	func bar_rect(y: float) -> Rect2:
		var x := state_w() + name_w() + size_w()
		return Rect2(x, y + ROW / 2.0 - 5.0, maxf(120.0, size.x - x - RAN_W - COST_W - 18.0), 10.0)

	func _draw() -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var faint := AmTheme.col("FAINT")
		var line := Color(AmTheme.col("BORDER"), 0.55)
		var bar := bar_rect(0.0)
		var heads := [[state_w(), "Sandbox"]] if narrow() else [[8.0, "State"], [STATE_W, "Sandbox"], [STATE_W + name_w(), "Size, region"]]
		for h in heads:
			draw_string(font, Vector2(float(h[0]), 18.0), str(h[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, muted)
		draw_string(font, Vector2(bar.position.x, 18.0), "%d days ago" % SandboxView.DAYS, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, muted)
		draw_string(font, Vector2(bar.end.x - 60.0, 18.0), "now", HORIZONTAL_ALIGNMENT_RIGHT, 60.0, 11, muted)
		draw_string(font, Vector2(bar.end.x + 18.0, 18.0), "Ran for", HORIZONTAL_ALIGNMENT_RIGHT, RAN_W - 14.0, 11, muted)
		draw_string(font, Vector2(bar.end.x + 18.0 + RAN_W, 18.0), "Cost", HORIZONTAL_ALIGNMENT_RIGHT, COST_W - 14.0, 11, muted)
		draw_line(Vector2(0, HEAD - 1.0), Vector2(size.x, HEAD - 1.0), line, 1.0)
		var breath := 0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.004)
		for i in rows.size():
			var row: Dictionary = rows[i]
			var y := HEAD + i * ROW
			var st: Dictionary = SandboxView.state_of(row)
			var lv := str(st["level"])
			var col: Color = {"ok": AmTheme.col("MINT"), "warn": AmTheme.col("WARN"), "bad": AmTheme.col("ERROR")}.get(lv, faint)
			var gone := lv == "off"
			if i == hover:
				draw_style_box(AmTheme.box(AmTheme.col("PANEL_2"), 6, Color(0, 0, 0, 0), 0, 0), Rect2(0, y + 1.0, size.x, ROW - 2.0))
			# the state: a disc when it runs, a ring when it is paused, a cross when it is gone, a line through when destroyed
			var c := Vector2(16.0, y + ROW / 2.0)
			if lv == "ok":
				draw_circle(c, 5.0, Color(col, breath))
			elif lv == "warn":
				draw_arc(c, 4.5, 0.0, TAU, 20, col, 2.0, true)
			elif lv == "bad":
				draw_line(c + Vector2(-4, -4), c + Vector2(4, 4), col, 2.0, true)
				draw_line(c + Vector2(-4, 4), c + Vector2(4, -4), col, 2.0, true)
			else:
				draw_arc(c, 4.5, 0.0, TAU, 20, faint, 1.5, true)
				draw_line(c + Vector2(-6, 0), c + Vector2(6, 0), faint, 1.5, true)
			if not narrow():
				draw_string(font, Vector2(30.0, y + ROW / 2.0 + 5.0), str(st["text"]), HORIZONTAL_ALIGNMENT_LEFT, STATE_W - 36.0, 13, faint if gone else col)
			draw_string(font if gone else bold, Vector2(state_w(), y + ROW / 2.0 + 5.0), SandboxView.name_of(row), HORIZONTAL_ALIGNMENT_LEFT, name_w() - 12.0, 13, muted if gone else ink)
			# its size as a chip, its region beside (when there is room)
			var words: String = SandboxView.size_words(str(row.get("size", "")))
			var sx := STATE_W + name_w()
			if narrow():
				words = ""
			var cw := minf(font.get_string_size(words, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 16.0, SIZE_W - 56.0)
			if words != "":
				draw_style_box(AmTheme.box(Color(AmTheme.col("PANEL_2"), 0.5 if gone else 1.0), 6, line, 1, 0), Rect2(sx, y + ROW / 2.0 - 10.0, cw, 20.0))
				draw_string(font, Vector2(sx + 8.0, y + ROW / 2.0 + 4.0), words, HORIZONTAL_ALIGNMENT_LEFT, cw - 12.0, 11, muted)
				draw_string(font, Vector2(sx + cw + 8.0, y + ROW / 2.0 + 4.0), str(row.get("region", "")), HORIZONTAL_ALIGNMENT_LEFT, 44.0, 11, faint)
			# its life over thirty days
			var b := bar_rect(y)
			draw_rect(b, Color(AmTheme.col("BORDER"), 0.45))
			for week in range(1, 4):  # a faint mark each week back from now
				var wx := b.end.x - b.size.x * week * 7.0 / SandboxView.DAYS
				draw_line(Vector2(wx, b.position.y - 2.0), Vector2(wx, b.end.y + 2.0), Color(AmTheme.col("BG"), 0.9), 1.0)
			var life: Dictionary = SandboxView.life(row, now)
			var run_col := Color(AmTheme.col("MINT"), 0.45 if gone else 0.9)
			for r in life["runs"]:
				var x0 := b.position.x + b.size.x * float(r[0])
				var x1 := maxf(x0 + 2.0, b.position.x + b.size.x * float(r[1]))   # a run of a minute still shows
				draw_rect(Rect2(x0, b.position.y, x1 - x0, b.size.y), run_col)
				if r[2]:  # it runs now: its end breathes
					draw_circle(Vector2(b.end.x, b.position.y + b.size.y / 2.0), 6.0, Color(AmTheme.col("MINT"), breath))
			if float(life["made"]) >= 0.0:  # where it was made: a small triangle under the bar
				var mx := b.position.x + b.size.x * float(life["made"])
				draw_colored_polygon(PackedVector2Array([Vector2(mx, b.end.y + 2.0), Vector2(mx - 4.0, b.end.y + 8.0), Vector2(mx + 4.0, b.end.y + 8.0)]), muted)
			if float(life["ended"]) >= 0.0:  # where it was destroyed: a cross on the bar
				var ex := b.position.x + b.size.x * float(life["ended"])
				var mid := b.position.y + b.size.y / 2.0
				draw_line(Vector2(ex - 5.0, mid - 5.0), Vector2(ex + 5.0, mid + 5.0), ink, 2.0, true)
				draw_line(Vector2(ex - 5.0, mid + 5.0), Vector2(ex + 5.0, mid - 5.0), ink, 2.0, true)
			var ran := "–" if int(row.get("run_seconds", 0)) <= 0 else HostView.span(float(row["run_seconds"]))
			draw_string(font, Vector2(b.end.x + 18.0, y + ROW / 2.0 + 5.0), ran, HORIZONTAL_ALIGNMENT_RIGHT, RAN_W - 14.0, 12, muted if gone else ink)
			draw_string(font, Vector2(b.end.x + 18.0 + RAN_W, y + ROW / 2.0 + 5.0), SandboxView.money(float(row.get("cost_usd", 0.0))), HORIZONTAL_ALIGNMENT_RIGHT, COST_W - 14.0, 12, muted if gone else ink)
			draw_line(Vector2(0, y + ROW - 0.5), Vector2(size.x, y + ROW - 0.5), Color(line, 0.3), 1.0)


## The wires between this computer and a sandbox: one per port brought here. At the left, the address on this
## computer; at the right, the program and its port in the sandbox; on the wire, what passes: dots that run toward
## the sandbox for what is sent and back for what is received, faster when more passes, and both rates in figures
## with the totals. A paused port is a dashed grey wire that carries nothing.
class Wire extends Control:
	const ROW := 34.0
	const PAD := 10.0
	const SIDE := 210.0
	var rows: Array
	var name_there: String
	var font: Font
	var bold: Font

	func _init(the_rows: Array, sandbox_name: String) -> void:
		rows = the_rows
		name_there = sandbox_name
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size.y = PAD * 2.0 + 20.0 + rows.size() * ROW
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(true)   # the dots run

	var _since := 0.0

	func _process(delta: float) -> void:  # an animation: 30 images a second, and only while it is seen
		_since += delta
		if _since >= 1.0 / 30.0 and is_visible_in_tree():
			_since = 0.0
			queue_redraw()

	## How fast the dots run for a rate: slowly for a few bytes, a little faster each time it is ten times more.
	static func speed(per_second: float) -> float:
		return 0.0 if per_second < 0.5 else clampf(0.12 + 0.1 * log(per_second) / log(10.0), 0.12, 0.9)

	func _draw() -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var here := Rect2(0, 0, SIDE, size.y)
		var there := Rect2(size.x - SIDE, 0, SIDE, size.y)
		for box in [here, there]:
			draw_style_box(AmTheme.box(AmTheme.col("PANEL_2"), 10, AmTheme.col("BORDER"), 1, 0), box)
		draw_string(bold, Vector2(here.position.x + 12.0, 22.0), "This computer", HORIZONTAL_ALIGNMENT_LEFT, SIDE - 20.0, 12, ink)
		draw_string(bold, Vector2(there.position.x + 12.0, 22.0), "☁ " + name_there, HORIZONTAL_ALIGNMENT_LEFT, SIDE - 20.0, 12, ink)
		var t := Time.get_ticks_msec() / 1000.0
		for i in rows.size():
			var row: Dictionary = rows[i]
			var y := PAD + 26.0 + i * ROW + ROW / 2.0 - 6.0
			var x0 := here.end.x
			var x1 := there.position.x
			var paused := str(row["state"]) == "paused"
			var back := str(row.get("kind", "in")) == "out"   # a rule: the sandbox reaches a program of this computer
			draw_string(font, Vector2(here.position.x + 12.0, y + 5.0), str(row.get("left", "")), HORIZONTAL_ALIGNMENT_LEFT, SIDE - 20.0, 12, muted if paused else ink)
			draw_string(font, Vector2(there.position.x + 12.0, y + 5.0), str(row.get("right", "")), HORIZONTAL_ALIGNMENT_LEFT, SIDE - 20.0, 12, muted if paused else ink)
			if paused:
				draw_dashed_line(Vector2(x0, y), Vector2(x1, y), AmTheme.col("FAINT"), 2.0, 6.0)
				draw_string(font, Vector2(x0, y - 7.0), "paused", HORIZONTAL_ALIGNMENT_CENTER, x1 - x0, 11, AmTheme.col("FAINT"))
				continue
			draw_line(Vector2(x0, y), Vector2(x1, y), Color(AmTheme.col("BORDER"), 0.9), 2.0, true)
			var so := speed(float(row["sent_rate"]))
			var si := speed(float(row["received_rate"]))
			# what is asked runs toward the program that answers, a little above the wire; what it answers runs back, a
			# little under. For a port of the sandbox the program is there; for a rule, it is here.
			var from := x1 if back else x0
			var to := x0 if back else x1
			for k in 5:
				if so > 0.0:
					draw_circle(Vector2(lerpf(from, to, fposmod(t * so + k / 5.0, 1.0)), y - 3.0), 2.5, AmTheme.col("INFO"))
				if si > 0.0:
					draw_circle(Vector2(lerpf(to, from, fposmod(t * si + k / 5.0, 1.0)), y + 3.0), 2.5, AmTheme.col("MINT"))
			var figures := ("asked %s (%s)   ·   answered %s (%s)%s" if back else "sent %s (%s)   ·   received %s (%s)%s") % [SandboxView.rate(float(row["sent_rate"])), SandboxView.amount(float(row["sent"])),
				SandboxView.rate(float(row["received_rate"])), SandboxView.amount(float(row["received"])),
				("   ·   %d open now" % int(row["open_now"])) if int(row["open_now"]) > 0 else ""]
			draw_string(font, Vector2(x0, y - 9.0), figures, HORIZONTAL_ALIGNMENT_CENTER, x1 - x0, 11, muted)


## The sizes a sandbox can have, one card each: its kind, processors and memory, what it costs a month and an hour
## while it runs, and a bar of that price against the dearest, so the gap shows at a glance. The chosen one is lit;
## a click chooses another (for the next sandboxes: one that runs keeps its size).
class Sizes extends Control:
	signal picked(id: String)
	const H := 96.0
	const GAP := 8.0
	var rows: Array
	var chosen: String
	var hover := -1
	var font: Font
	var bold: Font

	func _init(sizes: Dictionary) -> void:
		rows = sizes.get("sizes", [])
		chosen = str(sizes.get("chosen", ""))
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size.y = H
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_exited.connect(func() -> void:
			hover = -1
			queue_redraw())

	## The cards in even rows (6, 3, 2 or 1 a row: never five and a lonely one), each at least 150 px wide.
	func cols() -> int:
		var n := maxi(rows.size(), 1)
		for c in range(n, 0, -1):
			if n % c == 0 and (size.x - GAP * (c - 1)) / c >= 150.0:
				return c
		return 1

	func card_w() -> float:
		return (size.x - GAP * (cols() - 1)) / cols()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			var lines := int(ceil(rows.size() / float(cols())))
			custom_minimum_size.y = lines * H + maxf(0.0, lines - 1.0) * GAP

	func cell(i: int) -> Vector2:
		return Vector2((i % cols()) * (card_w() + GAP), (i / cols()) * (H + GAP))

	func at_point(p: Vector2) -> int:
		for i in rows.size():
			if Rect2(cell(i), Vector2(card_w(), H)).has_point(p):
				return i
		return -1

	func at(x: float) -> int:
		return at_point(Vector2(x, H / 2.0))

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseMotion:
			var i := at_point(e.position)
			if i != hover:
				hover = i
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if i >= 0 else Control.CURSOR_ARROW
				queue_redraw()
		elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			var i := at_point(e.position)
			if i >= 0 and str(rows[i]["id"]) != chosen:
				picked.emit(str(rows[i]["id"]))

	func _get_tooltip(pos: Vector2) -> String:
		var i := at_point(pos)
		if i < 0:
			return ""
		var r: Dictionary = rows[i]
		return "%s\n%s processor%s, %s of memory\n≈ %s a month, ≈ %s an hour, ≈ %s a day while it runs" % [str(r["id"]), str(r["cpus"]),
			"" if int(r["cpus"]) == 1 else "s", HostView.mem(float(r["memory_mb"]) * 1048576.0), SandboxView.money(float(r["month"])),
			SandboxView.money(float(r["per_hour"])), SandboxView.money(float(r["per_day_on"]))]

	func _draw() -> void:
		var top := 0.0
		for r in rows:
			top = maxf(top, float(r["month"]))
		var w := card_w()
		for i in rows.size():
			var r: Dictionary = rows[i]
			var c := cell(i)
			var x := c.x
			var on := str(r["id"]) == chosen
			var perf := str(r["kind"]) == "performance"
			draw_set_transform(Vector2(0, c.y))
			var edge := AmTheme.col("MINT") if on else (AmTheme.col("FOREST_LIGHT") if i == hover else AmTheme.col("BORDER"))
			draw_style_box(AmTheme.box(AmTheme.col("PANEL_2") if on else AmTheme.col("PANEL"), 10, edge, 2 if on else 1, 0), Rect2(x, 0, w, H))
			draw_string(font, Vector2(x + 12.0, 20.0), ("✓ " if on else "") + ("performance" if perf else "shared"), HORIZONTAL_ALIGNMENT_LEFT, w - 20.0, 11, AmTheme.col("WARM") if perf else AmTheme.col("MUTED"))
			draw_string(bold, Vector2(x + 12.0, 42.0), "%d CPU · %s" % [int(r["cpus"]), HostView.mem(float(r["memory_mb"]) * 1048576.0)], HORIZONTAL_ALIGNMENT_LEFT, w - 20.0, 14, AmTheme.col("TEXT"))
			draw_string(bold, Vector2(x + 12.0, 64.0), SandboxView.money(float(r["month"])) + " / month", HORIZONTAL_ALIGNMENT_LEFT, w - 20.0, 13, AmTheme.col("TEXT"))
			draw_string(font, Vector2(x + 12.0, 80.0), "≈ %s an hour" % SandboxView.money(float(r["per_hour"])), HORIZONTAL_ALIGNMENT_LEFT, w - 20.0, 11, AmTheme.col("MUTED"))
			var track := Rect2(x + 12.0, H - 9.0, w - 24.0, 3.0)
			draw_rect(track, Color(AmTheme.col("BORDER"), 0.7))
			draw_rect(Rect2(track.position, Vector2(track.size.x * float(r["month"]) / maxf(top, 0.01), 3.0)), AmTheme.col("WARM") if perf else AmTheme.col("MINT"))
		draw_set_transform(Vector2.ZERO)


## One sandbox's life over the last thirty days, as a thin bar for its line: filled where its machine ran, a mark
## where it was made, a cross where it was destroyed; the end breathes while it runs.
class LifeBar extends Control:
	var row: Dictionary
	var now: float

	func _init(the_row: Dictionary, the_now: float, width: float) -> void:
		row = the_row
		now = the_now
		custom_minimum_size = Vector2(width, 30)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(bool(row.get("running_now", false)))

	var _since := 0.0

	func _process(delta: float) -> void:  # an animation: 30 images a second, and only while it is seen
		_since += delta
		if _since >= 1.0 / 30.0 and is_visible_in_tree():
			_since = 0.0
			queue_redraw()

	func _draw() -> void:
		var gone := bool(row.get("destroyed", false))
		var b := Rect2(0, size.y / 2.0 - 4.0, size.x - 8.0, 8.0)
		draw_rect(b, Color(AmTheme.col("BORDER"), 0.45))
		for week in range(1, 4):
			var wx := b.end.x - b.size.x * week * 7.0 / SandboxView.DAYS
			draw_line(Vector2(wx, b.position.y - 2.0), Vector2(wx, b.end.y + 2.0), Color(AmTheme.col("BG"), 0.9), 1.0)
		var life: Dictionary = SandboxView.life(row, now)
		for r in life["runs"]:
			var x0 := b.position.x + b.size.x * float(r[0])
			var x1 := maxf(x0 + 2.0, b.position.x + b.size.x * float(r[1]))
			draw_rect(Rect2(x0, b.position.y, x1 - x0, b.size.y), Color(AmTheme.col("MINT"), 0.45 if gone else 0.9))
			if r[2]:
				draw_circle(Vector2(b.end.x, b.position.y + b.size.y / 2.0), 5.0, Color(AmTheme.col("MINT"), 0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.004)))
		if float(life["made"]) >= 0.0:
			var mx := b.position.x + b.size.x * float(life["made"])
			draw_colored_polygon(PackedVector2Array([Vector2(mx, b.end.y + 2.0), Vector2(mx - 4.0, b.end.y + 8.0), Vector2(mx + 4.0, b.end.y + 8.0)]), AmTheme.col("MUTED"))
		if float(life["ended"]) >= 0.0:
			var ex := b.position.x + b.size.x * float(life["ended"])
			var mid := b.position.y + b.size.y / 2.0
			draw_line(Vector2(ex - 5.0, mid - 5.0), Vector2(ex + 5.0, mid + 5.0), AmTheme.col("TEXT"), 2.0, true)
			draw_line(Vector2(ex - 5.0, mid + 5.0), Vector2(ex + 5.0, mid - 5.0), AmTheme.col("TEXT"), 2.0, true)


## How a running sandbox is doing, like htop: four small charts over the last fifteen minutes (its processors, its
## memory, its network in and out, its load) with the figure of now on each, and its busiest programs with a bar for
## the processor each takes and the memory it holds. Each chart's colour says how it is doing: calm, busy (amber),
## nearly full (red), with a word beside the figure, never the colour alone.
class Health extends Control:
	const CH := 92.0
	const GAP := 10.0
	var h: Dictionary
	var font: Font
	var bold: Font

	func _init(health: Dictionary) -> void:
		h = health
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fit()

	func wide() -> bool:
		return size.x >= 760.0

	func _fit() -> void:
		var charts := CH * 2.0 + GAP
		var procs := 26.0 + 22.0 * maxf((h.get("procs", []) as Array).size(), 1)
		custom_minimum_size.y = maxf(charts, procs) if wide() else charts + GAP + procs

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_fit()

	func series(key: String) -> Array:
		return (h.get("history", []) as Array).map(func(x: Dictionary) -> Variant: return x.get(key))

	## A chart: its title, the figure of now with its word, and the curve (a soft area and a line).
	func chart(r: Rect2, title: String, figure: String, values: Array, top: float, level: String, second: Array = []) -> void:
		var col: Color = {"busy": AmTheme.col("WARN"), "full": AmTheme.col("ERROR")}.get(level, AmTheme.col("MINT"))
		draw_style_box(AmTheme.box(AmTheme.col("PANEL_2"), 8, AmTheme.col("BORDER"), 1, 0), r)
		draw_string(font, r.position + Vector2(10, 18), title, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20.0, 11, AmTheme.col("MUTED"))
		var word: String = {"busy": "busy", "full": "nearly full"}.get(level, "")
		draw_string(bold, r.position + Vector2(10, 40), figure, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20.0, 16, AmTheme.col("TEXT"))
		if word != "":
			draw_string(font, r.position + Vector2(r.size.x - 90.0, 18), word, HORIZONTAL_ALIGNMENT_RIGHT, 80.0, 11, col)
		var plot := Rect2(r.position + Vector2(10, 48), Vector2(r.size.x - 20.0, r.size.y - 56.0))
		draw_line(Vector2(plot.position.x, plot.end.y), plot.end, Color(AmTheme.col("BORDER"), 0.8), 1.0)
		for pair in [[values, col], [second, AmTheme.col("INFO")]]:
			var vals: Array = pair[0]
			if vals.size() < 2 or top <= 0.0:
				continue
			var pts := PackedVector2Array()
			for i in vals.size():
				var v: float = 0.0 if vals[i] == null else float(vals[i])
				pts.append(Vector2(plot.position.x + plot.size.x * i / float(vals.size() - 1), plot.end.y - plot.size.y * clampf(v / top, 0.0, 1.0)))
			var area := PackedVector2Array(pts)
			area.append(Vector2(plot.end.x, plot.end.y))
			area.append(Vector2(plot.position.x, plot.end.y))
			draw_colored_polygon(area, Color(pair[1], 0.12))
			draw_polyline(pts, pair[1], 2.0, true)
		if values.size() < 2:
			draw_string(font, Vector2(plot.position.x, plot.end.y - 4.0), "the curve starts with the next readings", HORIZONTAL_ALIGNMENT_LEFT, plot.size.x, 10, AmTheme.col("FAINT"))

	func _draw() -> void:
		var cw := (size.x * (0.6 if wide() else 1.0) - GAP) / 2.0
		var cpu: Variant = h.get("cpu")
		var cpu_f := 0.0 if cpu == null else float(cpu)
		var cpus := int(h.get("cpus", 0))
		chart(Rect2(0, 0, cw, CH), "Processors%s" % ((" (%d)" % cpus) if cpus > 0 else ""), "…" if cpu == null else "%d %%" % int(round(cpu_f * 100.0)),
			series("cpu"), 1.0, "full" if cpu_f > 0.9 else ("busy" if cpu_f > 0.6 else ""))
		var total := float(h.get("memory_total", 0))
		var used := float(h.get("memory_used", 0))
		var share := used / total if total > 0.0 else 0.0
		chart(Rect2(cw + GAP, 0, cw, CH), "Memory", "%s of %s" % [HostView.mem(used), HostView.mem(total)], series("mem"), total,
			"full" if share > 0.9 else ("busy" if share > 0.75 else ""))
		var rx: Array = series("rx")
		var tx: Array = series("tx")
		var top := 1.0
		for v in rx + tx:
			if v != null:
				top = maxf(top, float(v))
		var rx_now: Variant = h.get("rx_rate")
		var tx_now: Variant = h.get("tx_rate")
		chart(Rect2(0, CH + GAP, cw, CH), "Network: in (green), out (blue)", "…" if rx_now == null else "↓ %s  ↑ %s" % [SandboxView.rate(float(rx_now)), SandboxView.rate(float(tx_now))],
			rx, HostView.nice(top * 1.15), "", tx)
		var load := float(h.get("load", 0.0))
		var ltop := maxf(float(maxi(cpus, 1)), 0.1)
		for v in series("load"):
			if v != null:
				ltop = maxf(ltop, float(v))
		chart(Rect2(cw + GAP, CH + GAP, cw, CH), "Load (programs wanting a processor)", "%.2f" % load, series("load"), ltop,
			"full" if cpus > 0 and load > cpus * 1.5 else ("busy" if cpus > 0 and load > cpus else ""))
		# the busiest programs, like htop
		var px := size.x * 0.6 + GAP if wide() else 0.0
		var py := 0.0 if wide() else CH * 2.0 + GAP * 2.0
		var pw := size.x - px
		draw_string(font, Vector2(px, py + 14.0), "Busiest programs", HORIZONTAL_ALIGNMENT_LEFT, pw * 0.5, 11, AmTheme.col("MUTED"))
		draw_string(font, Vector2(px + pw - 150.0, py + 14.0), "processor", HORIZONTAL_ALIGNMENT_LEFT, 70.0, 11, AmTheme.col("MUTED"))
		draw_string(font, Vector2(px + pw - 70.0, py + 14.0), "memory", HORIZONTAL_ALIGNMENT_RIGHT, 70.0, 11, AmTheme.col("MUTED"))
		var procs: Array = h.get("procs", [])
		for i in procs.size():
			var p: Dictionary = procs[i]
			var y := py + 26.0 + i * 22.0
			draw_string(font, Vector2(px, y + 12.0), "%s" % str(p["name"]), HORIZONTAL_ALIGNMENT_LEFT, pw - 170.0, 12, AmTheme.col("TEXT"))
			var bar := Rect2(px + pw - 150.0, y + 4.0, 60.0, 8.0)
			draw_rect(bar, Color(AmTheme.col("BORDER"), 0.6))
			var c := float(p["cpu"]) / (100.0 * maxf(float(cpus), 1.0))
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(c * maxf(float(cpus), 1.0), 0.0, 1.0), bar.size.y)), AmTheme.col("WARN") if float(p["cpu"]) > 80.0 else AmTheme.col("MINT"))
			draw_string(font, Vector2(bar.end.x + 4.0, y + 12.0), "%d%%" % int(round(float(p["cpu"]))), HORIZONTAL_ALIGNMENT_LEFT, 40.0, 10, AmTheme.col("MUTED"))
			draw_string(font, Vector2(px + pw - 70.0, y + 12.0), HostView.mem(float(p["rss"])), HORIZONTAL_ALIGNMENT_RIGHT, 70.0, 11, AmTheme.col("MUTED"))
		if procs.is_empty():
			draw_string(font, Vector2(px, py + 40.0), "not read yet", HORIZONTAL_ALIGNMENT_LEFT, pw, 12, AmTheme.col("FAINT"))


## A small sign that something is on its way: a turning arc and a few words. Shown at once where a page or a
## terminal will be, so a click is answered at once even when what it asked for takes a moment.
class Loading extends Control:
	var words: String
	var font: Font
	var born := 0

	func _init(text: String, height := 120.0) -> void:
		words = text
		font = AmTheme.ui_font(400)
		born = Time.get_ticks_msec()
		custom_minimum_size = Vector2(0, height)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(true)

	var _since := 0.0

	func _process(delta: float) -> void:  # an animation: 30 images a second, and only while it is seen
		_since += delta
		if _since >= 1.0 / 30.0 and is_visible_in_tree():
			_since = 0.0
			queue_redraw()

	func _draw() -> void:
		var c := Vector2(size.x / 2.0, minf(size.y / 2.0, 80.0))
		var a := (Time.get_ticks_msec() - born) * 0.006
		draw_arc(c, 14.0, 0.0, TAU, 32, Color(AmTheme.col("BORDER"), 0.8), 3.0, true)
		draw_arc(c, 14.0, a, a + 1.9, 24, AmTheme.col("MINT"), 3.0, true)
		draw_string(font, Vector2(0, c.y + 40.0), words, HORIZONTAL_ALIGNMENT_CENTER, size.x, 13, AmTheme.col("MUTED"))

