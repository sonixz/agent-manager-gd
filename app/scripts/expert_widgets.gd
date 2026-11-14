extends RefCounted
## The Experts page's drawn pieces (Loop 44; owner, 2026-11-14: « n'oublie pas qu'on est dans Godot, il faut que ça
## soit vraiment clean »). Drawn by hand like Repos and Sandboxes; still unless the pointer is on them (the app's
## low-processor mode: nothing is drawn when nothing changes).
## Loaded with preload, not by a class name (see setup_probe.gd).


## An expert's emblem: its glyph in a disc, its skills as beads on a ring around it, the secrets it needs as small
## keys under it. A bead with scripts is warmer: it runs code.
class Emblem extends Control:
	var glyph := "◆"
	var beads: Array = []      # [{"name", "scripts"}]
	var keys := 0
	var tint: Color
	var font: Font
	var bold: Font

	func _init(the_glyph: String, the_beads: Array, the_keys: int, the_tint: Color) -> void:
		glyph = the_glyph
		beads = the_beads
		keys = the_keys
		tint = the_tint
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size = Vector2(96, 96)
		tooltip_text = "%d skill(s)%s" % [beads.size(), (" · %d secret(s) needed" % keys) if keys > 0 else ""]

	func _draw() -> void:
		var c := Vector2(48, 44)
		draw_circle(c, 30, Color(tint, 0.10))
		draw_arc(c, 30, 0, TAU, 48, Color(tint, 0.35), 1.2, true)
		draw_circle(c, 19, Color(tint, 0.22))
		draw_arc(c, 19, 0, TAU, 40, tint, 1.6, true)
		var g := glyph if glyph != "" else "◆"
		var w := bold.get_string_size(g, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
		draw_string(bold, c + Vector2(-w / 2.0, 7), g, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, AmTheme.col("TEXT"))
		var n := beads.size()
		for i in n:
			var a := -PI / 2.0 + TAU * float(i) / maxf(1.0, float(n))
			var p := c + Vector2(cos(a), sin(a)) * 30.0
			var warm := int(beads[i].get("scripts", 0)) > 0
			draw_circle(p, 5.0, AmTheme.col("PANEL"))
			draw_circle(p, 4.0, AmTheme.col("WARM") if warm else AmTheme.col("MINT"))
		for k in mini(keys, 5):   # the secrets it needs, as small keys
			var x := 48.0 - (mini(keys, 5) - 1) * 7.0 + k * 14.0
			draw_circle(Vector2(x, 86), 3.0, Color(0, 0, 0, 0))
			draw_arc(Vector2(x, 86), 3.0, 0, TAU, 12, AmTheme.col("WARN"), 1.4, true)
			draw_line(Vector2(x + 3, 86), Vector2(x + 7, 86), AmTheme.col("WARN"), 1.4)


## A skill's card face: its name, two lines of what it is for, then its marks: the licence (a mint dot for Apache or
## MIT, amber otherwise), the scripts it holds (they run: amber), and the experts that use it.
class SkillFace extends Control:
	var skill: Dictionary
	var font: Font
	var bold: Font
	var hover := false

	func _init(the_skill: Dictionary) -> void:
		skill = the_skill
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size = Vector2(250, 112)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_entered.connect(func() -> void:
			hover = true
			queue_redraw())
		mouse_exited.connect(func() -> void:
			hover = false
			queue_redraw())
		var sc: Array = skill.get("scripts", [])
		tooltip_text = str(skill.get("description", "")) + ("\n\nScripts it holds (they run when the agent uses it):\n" + "\n".join(sc) if not sc.is_empty() else "\n\nNo script: instructions only.")

	func _wrap_lines(text: String, width: float, size_px: int, max_lines: int) -> Array:
		var out: Array = []
		var line := ""
		for word in text.split(" ", false):
			var tryit := (line + " " + word).strip_edges()
			if font.get_string_size(tryit, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x > width and line != "":
				out.append(line)
				line = word
				if out.size() == max_lines:
					break
			else:
				line = tryit
		if out.size() < max_lines and line != "":
			out.append(line)
		elif out.size() == max_lines and line != "":
			out[-1] = str(out[-1]).left(maxi(0, str(out[-1]).length() - 1)) + "…"
		return out

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var edge := AmTheme.col("MINT") if hover else Color(AmTheme.col("FAINT"), 0.5)
		draw_style_box(AmTheme.box(AmTheme.col("PANEL"), 10, edge, 1, 0), r)
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		draw_string(bold, Vector2(14, 24), str(skill.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, size.x - 90, 14, ink)
		var src := str(skill.get("source", ""))
		var tag := ("own" if src == "own" else src + " · " + str(skill.get("commit", "")))
		var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		draw_string(font, Vector2(size.x - tw - 12, 22), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, AmTheme.col("FAINT"))
		var y := 44.0
		for l in _wrap_lines(str(skill.get("description", "")), size.x - 28, 11, 2):
			draw_string(font, Vector2(14, y), str(l), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, muted)
			y += 15.0
		# the marks
		var lic := str(skill.get("license", ""))
		var open := lic in ["Apache-2.0", "MIT"]
		var x := 14.0
		var by := size.y - 16.0
		draw_circle(Vector2(x + 4, by - 4), 4.0, AmTheme.col("MINT") if open else AmTheme.col("WARN"))
		var lt := lic if lic.length() <= 22 else lic.left(21) + "…"
		draw_string(font, Vector2(x + 13, by), lt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, muted)
		x += 22.0 + font.get_string_size(lt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		var n := int(skill.get("script_count", 0))
		var st := ("%d script%s" % [n, "s" if n > 1 else ""]) if n > 0 else "instructions only"
		draw_rect(Rect2(x, by - 8, 8, 8), AmTheme.col("WARM") if n > 0 else Color(AmTheme.col("FAINT"), 0.6), n > 0)
		draw_string(font, Vector2(x + 13, by), st, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, AmTheme.col("WARM") if n > 0 else muted)
		x += 24.0 + font.get_string_size(st, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		var used: Array = skill.get("used_by", [])
		if not used.is_empty():
			var ut := "✦ " + ", ".join(used)
			draw_string(font, Vector2(x, by), ut, HORIZONTAL_ALIGNMENT_LEFT, maxf(20.0, size.x - x - 10), 10, AmTheme.col("MINT"))
