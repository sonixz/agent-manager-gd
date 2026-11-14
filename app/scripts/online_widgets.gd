extends RefCounted
## The Online page's drawn pieces (Loop 41). An Online machine serves the internet through one door, 443, toward one
## port inside; everything else in it listens on 127.0.0.1 and stays private; Agent Manager reaches it by SSH over
## Fly's private network (owner, 2026-11-14: « un service sur le port 443. Le reste ce serait en backend »).
## Loaded with preload, not by a class name (see setup_probe.gd).


## The door, drawn: the internet on the left, the gate (open and lit when exposed, shut when private), the service's
## port inside the machine, what stays private under it, and Agent Manager's own way in from below.
class Door extends Control:
	var exposed := false
	var port := 8080
	var app := ""
	var font: Font
	var bold: Font
	var _t := 0.0

	func _init(is_exposed: bool, inner_port: int, app_name: String) -> void:
		exposed = is_exposed
		port = inner_port
		app = app_name
		font = AmTheme.ui_font(400)
		bold = AmTheme.ui_font(650)
		custom_minimum_size = Vector2(560, 150)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		set_process(exposed)
		tooltip_text = ("Public: https://%s.fly.dev reaches port %d inside, nothing else." % [app, port]) if exposed \
			else "Private: no public address. Only Agent Manager reaches it, over Fly's private network."

	func _process(delta: float) -> void:  # visitors flowing in: 30 images a second, only while it is seen
		_t += delta
		if is_visible_in_tree() and Engine.get_process_frames() % 2 == 0:
			queue_redraw()

	func _text(at: Vector2, s: String, size_px: int, col: Color, f: Font = null) -> void:
		draw_string(f if f else font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, col)

	func _draw() -> void:
		var w := size.x
		var ink := AmTheme.col("TEXT")
		var faint := AmTheme.col("FAINT")
		var live := AmTheme.col("WARN") if exposed else faint
		var mint := AmTheme.col("MINT")
		# the internet
		var globe := Vector2(44, 52)
		draw_circle(globe, 26, Color(live, 0.12))
		draw_arc(globe, 26, 0, TAU, 40, live, 1.6, true)
		draw_line(globe + Vector2(-26, 0), globe + Vector2(26, 0), Color(live, 0.6), 1.0, true)
		draw_line(globe + Vector2(0, -26), globe + Vector2(0, 26), Color(live, 0.6), 1.0, true)
		_text(Vector2(12, 96), "internet", 12, live)
		# the machine
		var box := Rect2(Vector2(220, 10), Vector2(maxf(w - 232, 300), 104))
		draw_rect(box, Color(AmTheme.col("PANEL"), 0.6), true)
		draw_rect(box, Color(mint, 0.5), false, 1.2)
		_text(box.position + Vector2(10, 18), "Online machine · " + app, 12, AmTheme.col("MUTED"))
		# the gate: 443 on the machine's edge
		var gate := Rect2(Vector2(box.position.x - 34, 34), Vector2(68, 36))
		draw_rect(gate, Color(live, 0.18) if exposed else Color(faint, 0.08), true)
		draw_rect(gate, live, false, 1.6)
		_text(gate.position + Vector2(10, 16), "443", 14, live if exposed else faint, bold)
		_text(gate.position + Vector2(10, 31), "HTTPS", 10, live if exposed else faint)
		if not exposed:  # shut: a bar across
			draw_line(gate.position + Vector2(4, 4), gate.end - Vector2(4, 4), Color(faint, 0.8), 2.0, true)
		# from the internet to the gate
		var a := globe + Vector2(30, 0)
		var b := Vector2(gate.position.x - 2, 52)
		if exposed:
			draw_line(a, b, Color(live, 0.7), 2.0, true)
			for i in 4:  # requests on their way in
				var k := fposmod(_t * 0.6 + i / 4.0, 1.0)
				draw_circle(a.lerp(b, k), 3.0, live)
		else:
			var x := a.x
			while x < b.x:
				draw_line(Vector2(x, a.y), Vector2(minf(x + 6, b.x), a.y), Color(faint, 0.6), 1.0)
				x += 12
		# the service inside
		var svc := Rect2(Vector2(gate.end.x + 50, 34), Vector2(150, 36))
		draw_rect(svc, Color(mint, 0.14), true)
		draw_rect(svc, mint, false, 1.4)
		_text(svc.position + Vector2(10, 16), "your service", 12, ink, bold)
		_text(svc.position + Vector2(10, 31), "listens on :%d" % port, 11, AmTheme.col("MUTED"))
		draw_line(Vector2(gate.end.x + 2, 52), Vector2(svc.position.x - 2, 52), Color(live if exposed else faint, 0.7), 1.6, true)
		# what stays private
		var px := svc.end.x + 24
		if px + 200 < box.end.x:
			_text(Vector2(px, 46), "127.0.0.1 only, never public:", 11, AmTheme.col("MUTED"))
			_text(Vector2(px, 64), "database · cache · workers", 12, ink)
		_text(box.position + Vector2(10, 98), "/data: the volume, kept across restarts", 11, AmTheme.col("MUTED"))
		# Agent Manager's own way in, from below
		var am := Vector2(box.position.x + box.size.x * 0.62, box.end.y)
		draw_line(am, am + Vector2(0, 26), Color(mint, 0.8), 1.6, true)
		_text(am + Vector2(8, 22), "Agent Manager · SSH 2222 over Fly's private network (never public)", 11, mint)
		# the address
		var said := ("PUBLIC · https://%s.fly.dev" % app) if exposed else "PRIVATE · no public address"
		_text(Vector2(12, 140), said, 12, live if exposed else faint, bold)
