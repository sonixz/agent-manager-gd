extends RefCounted
## 🔌 MCP's drawn pieces (Loop 49a): one card per server. At the left a plug at the end of its cable, lit green when
## its last test answered, red with a cross when it did not, grey with a question mark when it was never tested; a
## globe or a small house says whether it is on the internet or on this computer. Then its name and address, a bead
## per tool and a triangle per prompt it offers, a chip per session it goes to (a filled dot when that session runs),
## and at the right how fast it answered, as a gauge. While a test runs, a pulse travels along the cable to the plug.
## A state is never said by its colour alone. The words and sums are in scripts/mcp_view.gd.
## Loaded with preload, not by a class name (see setup_probe.gd).

const McpView := preload("res://scripts/mcp_view.gd")


class Card extends Control:
	const H := 78.0
	var server: Dictionary
	var users: Array
	var testing := false
	var phase := 0.0
	var font: Font
	var bold: Font

	func _init(s: Dictionary, the_users: Array) -> void:
		server = s
		users = the_users
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size = Vector2(0, H)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		set_process(false)
		var t: Variant = s.get("last_test")
		var tip := str(s["name"]) + " · " + (str(s.get("url", "")) if str(s.get("kind", "")) == "http" else str(s.get("command", "")))
		if t is Dictionary and bool(t.get("ok", false)):
			var names := (t.get("tools", []) as Array).map(func(x: Dictionary) -> String: return str(x.get("name", "")))
			tip += "\ntools: " + ", ".join(names)
			var pr := (t.get("prompts", []) as Array).map(func(x: Dictionary) -> String: return "/mcp__%s__%s" % [str(s["name"]), str(x.get("name", ""))])
			if not pr.is_empty():
				tip += "\nprompts: " + ", ".join(pr)
		tooltip_text = tip

	func set_testing(on: bool) -> void:
		testing = on
		phase = 0.0
		set_process(on)
		queue_redraw()

	func _process(delta: float) -> void:
		phase = fmod(phase + delta * 0.9, 1.0)
		queue_redraw()

	func _draw() -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var faint := AmTheme.col("FAINT")
		var st := McpView.state(server)
		var col: Color = {"ok": AmTheme.col("MINT"), "bad": AmTheme.col("ERROR")}.get(st, faint)
		if testing:
			col = AmTheme.col("INFO")
		var cy := H / 2.0
		# the cable, from the left edge to the plug, a gentle curve; the pulse while testing
		var pts := PackedVector2Array()
		for i in 13:
			var u := i / 12.0
			pts.append(Vector2(4.0 + u * 22.0, cy + 10.0 - 10.0 * sin(u * PI * 0.5)))
		draw_polyline(pts, Color(col, 0.7), 2.0, true)
		if testing:
			var k := int(phase * 12.0)
			draw_circle(pts[clampi(k, 0, 12)], 3.0, col)
		# the plug: its body and two prongs
		var px := 26.0
		draw_style_box(AmTheme.box(Color(col, 0.22), 4, col, 1, 0), Rect2(px, cy - 9.0, 16.0, 18.0))
		draw_line(Vector2(px + 16.0, cy - 4.0), Vector2(px + 23.0, cy - 4.0), col, 2.0)
		draw_line(Vector2(px + 16.0, cy + 4.0), Vector2(px + 23.0, cy + 4.0), col, 2.0)
		var glyph: String = "…" if testing else {"ok": "✓", "bad": "✗"}.get(st, "?")
		draw_string(bold, Vector2(px + 3.5, cy + 4.5), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ink)
		# where it is: a globe (the internet) or a house (this computer)
		var wx := 64.0
		if bool(server.get("remote", false)):
			draw_arc(Vector2(wx, cy - 14.0), 6.0, 0.0, TAU, 18, muted, 1.2, true)
			draw_line(Vector2(wx - 6.0, cy - 14.0), Vector2(wx + 6.0, cy - 14.0), muted, 1.0)
			draw_arc(Vector2(wx, cy - 14.0), 6.0, -PI / 2.0, PI / 2.0, 10, muted, 1.0, true)
			draw_line(Vector2(wx, cy - 20.0), Vector2(wx, cy - 8.0), muted, 1.0)
		else:
			draw_polyline(PackedVector2Array([Vector2(wx - 6, cy - 12), Vector2(wx, cy - 19), Vector2(wx + 6, cy - 12)]), muted, 1.2, true)
			draw_rect(Rect2(wx - 4.5, cy - 12.0, 9.0, 7.0), muted, false, 1.2)
		# its name and address
		var x0 := 80.0
		var name_w := size.x * 0.34
		draw_string(bold, Vector2(x0, 26.0), str(server["name"]), HORIZONTAL_ALIGNMENT_LEFT, name_w, 15, ink)
		var addr := str(server.get("url", "")) if str(server.get("kind", "")) == "http" else "$ " + str(server.get("command", "")) + " " + " ".join(server.get("args", []))
		draw_string(font, Vector2(x0, 45.0), addr, HORIZONTAL_ALIGNMENT_LEFT, name_w, 11, muted)
		var note := str(server.get("note", ""))
		draw_string(font, Vector2(x0, 63.0), note if note != "" else ("every agent session" if bool(server.get("everywhere", false)) else "ticked session by session"),
			HORIZONTAL_ALIGNMENT_LEFT, name_w, 11, faint)
		# what it offers: a bead per tool, a triangle per prompt
		var gauge_w := 70.0
		var bx := x0 + name_w + 14.0
		var right := size.x - gauge_w - 18.0
		var t: Variant = server.get("last_test")
		if t is Dictionary and bool(t.get("ok", false)):
			var x := bx
			for i in (t.get("tools", []) as Array).size():
				if x + 9.0 > right:
					break
				draw_style_box(AmTheme.box(Color(AmTheme.col("MINT"), 0.25), 2, AmTheme.col("MINT"), 1, 0), Rect2(x, 14.0, 8.0, 8.0))
				x += 11.0
			for i in (t.get("prompts", []) as Array).size():
				if x + 10.0 > right:
					break
				var a := Vector2(x + 1.0, 13.0)
				draw_colored_polygon(PackedVector2Array([a, a + Vector2(8, 5), a + Vector2(0, 10)]), AmTheme.col("INFO"))
				x += 12.0
			draw_string(font, Vector2(bx, 38.0), McpView.offers(t), HORIZONTAL_ALIGNMENT_LEFT, right - bx, 11, muted)
		elif t is Dictionary:
			draw_string(font, Vector2(bx, 24.0), str(t.get("error", "")), HORIZONTAL_ALIGNMENT_LEFT, right - bx, 11, AmTheme.col("ERROR"))
		else:
			draw_string(font, Vector2(bx, 24.0), "press Test to see what it offers", HORIZONTAL_ALIGNMENT_LEFT, right - bx, 11, faint)
		# a chip per session it goes to
		var cx := bx
		var chip_y := 50.0
		if users.is_empty():
			draw_string(font, Vector2(cx, chip_y + 15.0), "no agent session has it yet", HORIZONTAL_ALIGNMENT_LEFT, right - cx, 11, faint)
		for u in users:
			var label := str(u["name"])
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 26.0
			if cx + w > right:
				draw_string(font, Vector2(cx, chip_y + 15.0), "+%d" % (users.size() - users.find(u)), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, muted)
				break
			var uc := AmTheme.col("MINT") if u["running"] else faint
			draw_style_box(AmTheme.box(Color(uc, 0.12), 10, Color(uc, 0.55), 1, 0), Rect2(cx, chip_y, w, 20.0))
			if u["running"]:
				draw_circle(Vector2(cx + 10.0, chip_y + 10.0), 3.5, uc)
			else:
				draw_arc(Vector2(cx + 10.0, chip_y + 10.0), 3.0, 0.0, TAU, 14, uc, 1.4, true)
			draw_string(font, Vector2(cx + 18.0, chip_y + 14.5), label, HORIZONTAL_ALIGNMENT_LEFT, w - 22.0, 11, ink)
			cx += w + 6.0
		# how fast it answered: a half gauge, full at 1 s and more
		var gc := Vector2(size.x - gauge_w / 2.0 - 8.0, cy + 6.0)
		draw_arc(gc, 24.0, PI, TAU, 24, AmTheme.col("BORDER"), 5.0, true)
		if t is Dictionary and bool(t.get("ok", false)):
			var ms := float(t.get("ms", 0))
			var f := clampf(ms / 1000.0, 0.03, 1.0)
			var gcol := AmTheme.col("MINT") if ms < 300.0 else (AmTheme.col("WARN") if ms < 1000.0 else AmTheme.col("ERROR"))
			draw_arc(gc, 24.0, PI, PI + PI * f, 24, gcol, 5.0, true)
			draw_string(bold, gc + Vector2(-gauge_w / 2.0, 2.0), "%d ms" % int(ms), HORIZONTAL_ALIGNMENT_CENTER, gauge_w, 12, ink)
		else:
			draw_string(font, gc + Vector2(-gauge_w / 2.0, 2.0), "—", HORIZONTAL_ALIGNMENT_CENTER, gauge_w, 12, faint)
