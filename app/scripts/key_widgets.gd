extends RefCounted
## The Keys page drawn as steps (owner, 2026-11-13): « clairement expliquer l'étape 1 qui est la clé pour la
## transcription… la clé 2 pour Fly.io quand tu veux utiliser les sandbox… en bas, dotenvx ».
## A rail on the left of each step: its number in a disc (filled when the step is done, outlined when it waits,
## dashed when it is optional and empty), and a line down to the next step.


class StepRail extends Control:
	var number := 1
	var state := "todo"  # "done", "todo", "optional"
	var last := false

	func _init(n: int, s: String, is_last: bool) -> void:
		number = n
		state = s
		last = is_last
		custom_minimum_size = Vector2(44, 44)
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := Vector2(size.x / 2.0, 20)
		var mint := AmTheme.col("MINT")
		var faint := AmTheme.col("FAINT")
		if not last:
			draw_line(Vector2(c.x, 40), Vector2(c.x, size.y), AmTheme.col("BORDER"), 2.0)
		var font := AmTheme.ui_font(700)
		var fs := 16
		var text := "✓" if state == "done" else str(number)
		var ink := faint
		if state == "done":
			draw_circle(c, 17, mint)
			ink = AmTheme.col("ON_ACCENT")
		elif state == "optional":
			for i in 24:  # dashed: the step can wait
				if i % 2 == 0:
					draw_arc(c, 16, TAU * i / 24.0, TAU * (i + 1) / 24.0, 4, faint, 2.0, true)
		else:
			draw_arc(c, 16, 0, TAU, 48, AmTheme.col("FOREST_LIGHT"), 2.5, true)
			ink = AmTheme.col("FOREST_LIGHT")
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2(c.x - w / 2.0, c.y + fs * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


## What a step's pill says, from the keys it needs.
static func step_state(keys: Dictionary, needed: Array, optional := false) -> String:
	for n in needed:
		if bool(keys.get(n, {}).get("set", false)):
			return "done"
	return "optional" if optional else "todo"
