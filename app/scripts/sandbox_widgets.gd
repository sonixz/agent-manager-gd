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

	func _process(_delta: float) -> void:
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

	func name_w() -> float:
		return clampf(size.x * 0.2, 150.0, 300.0)

	func bar_rect(y: float) -> Rect2:
		var x := STATE_W + name_w() + SIZE_W
		return Rect2(x, y + ROW / 2.0 - 5.0, maxf(120.0, size.x - x - RAN_W - COST_W - 18.0), 10.0)

	func _draw() -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var faint := AmTheme.col("FAINT")
		var line := Color(AmTheme.col("BORDER"), 0.55)
		var bar := bar_rect(0.0)
		var heads := [[8.0, "State"], [STATE_W, "Sandbox"], [STATE_W + name_w(), "Size, region"]]
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
			draw_string(font, Vector2(30.0, y + ROW / 2.0 + 5.0), str(st["text"]), HORIZONTAL_ALIGNMENT_LEFT, STATE_W - 36.0, 13, faint if gone else col)
			draw_string(font if gone else bold, Vector2(STATE_W, y + ROW / 2.0 + 5.0), SandboxView.name_of(row), HORIZONTAL_ALIGNMENT_LEFT, name_w() - 12.0, 13, muted if gone else ink)
			# its size as a chip, its region beside
			var words: String = SandboxView.size_words(str(row.get("size", "")))
			var sx := STATE_W + name_w()
			var cw := minf(font.get_string_size(words, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 16.0, SIZE_W - 56.0)
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
