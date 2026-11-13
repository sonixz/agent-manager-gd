extends RefCounted
## The secrets vault's drawn pieces (Loop 39): one card per secret, with a padlock (closed and green when Windows
## encrypts it, open and amber when only file permissions protect it), its name and note, a chip per session that holds
## it (a filled dot when that session runs), and fourteen small bars, one per day, for how often it was handed over.
## A state is never said by its colour alone. The words and sums are in scripts/secret_view.gd.
## Loaded with preload, not by a class name (see setup_probe.gd).

const SecretView := preload("res://scripts/secret_view.gd")


class Card extends Control:
	const H := 66.0
	var secret: Dictionary
	var held: Array
	var bars: Array
	var encrypted: bool
	var font: Font
	var bold: Font
	var mono: Font

	func _init(x: Dictionary, the_held: Array, the_bars: Array, is_encrypted: bool) -> void:
		secret = x
		held = the_held
		bars = the_bars
		encrypted = is_encrypted
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		mono = AmTheme.ui_font(650)
		custom_minimum_size = Vector2(0, H)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		tooltip_text = "%s · %s" % [str(x["name"]), "encrypted with Windows DPAPI" if encrypted else "protected by file permissions only"]

	func _draw() -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var lock_col := AmTheme.col("MINT") if encrypted else AmTheme.col("WARN")
		# the padlock: its body, and its shackle closed (encrypted) or lifted open (not)
		var c := Vector2(20.0, H / 2.0 + 4.0)
		draw_style_box(AmTheme.box(Color(lock_col, 0.22), 3, lock_col, 1, 0), Rect2(c - Vector2(8, 5), Vector2(16, 12)))
		if encrypted:
			draw_arc(c + Vector2(0, -5), 5.5, PI, TAU, 14, lock_col, 2.0, true)
		else:
			draw_arc(c + Vector2(5, -9), 5.5, PI, TAU - 0.4, 14, lock_col, 2.0, true)
		draw_circle(c + Vector2(0, 1), 1.6, lock_col)
		# its name and note
		var x0 := 42.0
		draw_string(mono, Vector2(x0, 24.0), str(secret["name"]), HORIZONTAL_ALIGNMENT_LEFT, size.x * 0.42, 14, ink)
		var note := str(secret.get("note", ""))
		draw_string(font, Vector2(x0, 44.0), note if note != "" else "no note", HORIZONTAL_ALIGNMENT_LEFT, size.x * 0.42, 12, muted if note != "" else AmTheme.col("FAINT"))
		# a chip per session that holds it
		var bars_w := 14.0 * 7.0
		var x := x0 + size.x * 0.42 + 16.0
		var right := size.x - bars_w - 24.0
		if held.is_empty():
			draw_string(font, Vector2(x, H / 2.0 + 5.0), "given to no session", HORIZONTAL_ALIGNMENT_LEFT, right - x, 12, AmTheme.col("FAINT"))
		for h in held:
			var label := str(h["name"])
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 30.0
			if x + w > right:
				draw_string(font, Vector2(x, H / 2.0 + 5.0), "+%d" % (held.size() - held.find(h)), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, muted)
				break
			var col := AmTheme.col("MINT") if h["running"] else AmTheme.col("FAINT")
			draw_style_box(AmTheme.box(Color(col, 0.12), 11, Color(col, 0.55), 1, 0), Rect2(x, H / 2.0 - 11.0, w, 22.0))
			if h["running"]:
				draw_circle(Vector2(x + 11.0, H / 2.0), 4.0, col)
			else:
				draw_arc(Vector2(x + 11.0, H / 2.0), 3.5, 0.0, TAU, 16, col, 1.5, true)
			draw_string(font, Vector2(x + 20.0, H / 2.0 + 4.5), label, HORIZONTAL_ALIGNMENT_LEFT, w - 24.0, 12, ink)
			x += w + 6.0
		# fourteen days of handing over: one bar per day, today at the right
		var top := 1
		for b in bars:
			top = maxi(top, int(b))
		var bx := size.x - bars_w - 8.0
		var base := H - 16.0
		for i in bars.size():
			var v := int(bars[i])
			var hgt := 3.0 if v == 0 else 6.0 + 26.0 * v / float(top)
			var col := AmTheme.col("MINT") if v > 0 else AmTheme.col("BORDER")
			draw_rect(Rect2(bx + i * 7.0, base - hgt, 5.0, hgt), col)
		draw_string(font, Vector2(bx, H - 3.0), "14 days", HORIZONTAL_ALIGNMENT_LEFT, bars_w, 10, AmTheme.col("FAINT"))
