extends VBoxContainer
## The engine room as a dashboard (Loop 36): the figures of now in tiles, the memory in use over time as stacked
## bars (one colour per session), and the sessions in a table. Everything is drawn by hand, like the costs chart.
## It asks nothing itself: the page gives it what the setup probe read (`facts`), the engine's /host (`host`) and
## /host/history (`hist`), and listens to `tick`, `range_picked` and `session_picked`.
##
## The sums and the words are in scripts/host_view.gd, where the headless cases check them.
## Loaded with preload, not by a class name (see setup_probe.gd).

const View := preload("res://scripts/host_view.gd")

signal tick                          ## every 5 seconds while it is on screen: time to ask the engine again
signal range_picked(id: String)      ## another span was chosen
signal session_picked(id: String)    ## a running session was clicked, in the bars or in the table

var facts := {}
var host := {}
var hist := {}
var slots := {}        # session id -> its hue, kept as long as the session is shown
var range_id := "1h"
var bias := 0          # the time zone, minutes east of UTC
var loading := false   # another span was asked: the one shown stays, paler, until the new one comes

var font_r: Font
var font_b: Font
var _tiles: Tiles
var _buttons := {}
var _chart: Chart
var _legend: Legend
var _table: Table
var _about: Label
var _timer: Timer


func _init() -> void:
	font_r = AmTheme.ui_font(400)
	font_b = AmTheme.ui_font(650)
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = SIZE_EXPAND_FILL
	var zone: Dictionary = Time.get_time_zone_from_system()
	bias = int(zone.get("bias", 0))
	_tiles = Tiles.new(self)
	add_child(_tiles)
	# one row of spans above everything it scopes: the bars, the small curves, the peaks
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var over := Label.new()
	over.text = "Memory in use, by session"
	over.add_theme_font_override("font", font_b)
	over.add_theme_font_size_override("font_size", 13)
	over.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(over)
	var group := ButtonGroup.new()
	for r in View.RANGES:
		var b := Button.new()
		b.text = str(r["label"])
		b.toggle_mode = true
		b.button_group = group
		b.add_theme_font_size_override("font_size", 12)
		b.button_pressed = r["id"] == range_id
		b.pressed.connect(_pick_range.bind(str(r["id"])))
		row.add_child(b)
		_buttons[r["id"]] = b
	add_child(row)
	_chart = Chart.new(self)
	add_child(_chart)
	_legend = Legend.new(self)
	add_child(_legend)
	_table = Table.new(self)
	add_child(_table)
	_about = Label.new()
	_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_about.add_theme_font_size_override("font_size", 12)
	_about.add_theme_color_override("font_color", AmTheme.col("MUTED"))
	add_child(_about)
	_timer = Timer.new()
	_timer.wait_time = 5.0
	_timer.autostart = true
	_timer.timeout.connect(func() -> void:
		if is_visible_in_tree():
			tick.emit())
	add_child(_timer)


func _pick_range(id: String) -> void:
	if id == range_id:
		return
	range_id = id
	loading = true
	_fade()
	range_picked.emit(id)


func set_range(id: String) -> void:
	range_id = id
	for k in _buttons:
		_buttons[k].set_pressed_no_signal(k == id)


func set_all(f: Dictionary, h: Dictionary, history: Dictionary) -> void:
	facts = f
	host = h
	hist = history
	refresh()


func set_host(h: Dictionary) -> void:
	host = h
	refresh()


func set_history(history: Dictionary) -> void:
	hist = history
	loading = false
	refresh()


## The span asked for could not be had: what is shown stays, at full strength again.
func history_failed() -> void:
	loading = false
	_fade()


func _fade() -> void:
	# a new span keeps the frame: what was drawn stays, paler, with no jump
	var a := 0.5 if loading else 1.0
	_chart.modulate.a = a
	_legend.modulate.a = a
	_table.modulate.a = a


func long_span() -> bool:
	return int(View.range_of(range_id)["seconds"]) > 86400


func name_of(id: String) -> String:
	for s in hist.get("sessions", []):
		if str(s["id"]) == id:
			return str(s["name"])
	return id


func is_running(id: String) -> bool:
	for x in host.get("sessions", []):
		if str(x["id"]) == id:
			return true
	return false


func colour(slot: int) -> Color:
	if slot == View.REST:
		return Color(AmTheme.col("FAINT"), 0.55)
	if slot == View.OTHER:
		return AmTheme.col("MUTED")
	return View.hue(slot, AmTheme.is_light())


func refresh() -> void:
	slots = View.assign(slots, View.ids_to_show(host, hist))
	_tiles.set_items(View.tiles(facts, host, hist))
	_chart.set_data(View.stack(hist, slots))
	_legend.rebuild()
	_table.set_rows(View.rows(host, hist, slots, float(host.get("now", Time.get_unix_time_from_system()))))
	_about.text = View.about(host, bias)
	_about.add_theme_color_override("font_color", AmTheme.col("MUTED"))  # again: the theme may have changed since
	_fade()


## A figure over the span, small: one thin column per pixel, as tall as the largest value that falls there; nothing
## where there was no reading. Columns, not a line: a week has more nights than days, and a line across them would
## either lie (joined) or crumble into dots (broken).
static func spark(on: CanvasItem, r: Rect2, values: Array, col: Color) -> void:
	var top := 0.0
	for v in values:
		if v != null:
			top = maxf(top, float(v))
	var n := values.size()
	if n < 2 or top <= 0.0:
		return
	var w := int(r.size.x)
	for px in w:
		var from := int(floor(px * n / float(w)))
		var to := maxi(from + 1, int(floor((px + 1) * n / float(w))))
		var best := -1.0
		for i in range(from, mini(to, n)):
			if values[i] != null:
				best = maxf(best, float(values[i]))
		if best <= 0.0:  # no reading there, or nothing to show: no column, not a dot on the floor
			continue
		var h := maxf(1.0, r.size.y * best / top)
		on.draw_rect(Rect2(r.position.x + px, r.end.y - h, 1.0, h), col)


# ====================================================================== the tiles
class Tiles extends Control:
	const H := 96.0
	const GAP := 10.0
	const MIN_W := 205.0
	var dash
	var items: Array = []

	func _init(d) -> void:
		dash = d
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_EXPAND_FILL

	func set_items(a: Array) -> void:
		items = a
		_fit()
		queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_fit()

	func cols() -> int:
		return clampi(int(floor((size.x + GAP) / (MIN_W + GAP))), 1, maxi(items.size(), 1))

	func _fit() -> void:
		var rows := int(ceil(items.size() / float(cols())))
		custom_minimum_size.y = rows * H + maxf(0.0, rows - 1.0) * GAP

	func _draw() -> void:
		var n := cols()
		var w := (size.x - GAP * (n - 1)) / n
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var warn := AmTheme.col("WARN")
		for i in items.size():
			var t: Dictionary = items[i]
			var at := Vector2((i % n) * (w + GAP), (i / n) * (H + GAP))
			draw_style_box(AmTheme.box(AmTheme.col("PANEL"), 10, warn if t["warn"] else AmTheme.col("BORDER"), 1, 0), Rect2(at, Vector2(w, H)))
			var x := at.x + 14.0
			if t["warn"]:  # a state is never said by its colour alone
				draw_string(dash.font_b, Vector2(x, at.y + 24.0), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, warn)
				x += 12.0
			var curve: Array = t["spark"]
			var room := w - 28.0 - (86.0 if curve.size() > 1 else 0.0)
			draw_string(dash.font_r, Vector2(x, at.y + 24.0), str(t["label"]), HORIZONTAL_ALIGNMENT_LEFT, room - (x - at.x - 14.0), 12, muted)
			draw_string(dash.font_b, Vector2(at.x + 14.0, at.y + 54.0), str(t["value"]), HORIZONTAL_ALIGNMENT_LEFT, w - 28.0, 22, ink)
			draw_multiline_string(dash.font_r, Vector2(at.x + 14.0, at.y + 72.0), str(t["note"]), HORIZONTAL_ALIGNMENT_LEFT, w - 28.0, 11, 2, muted)
			if curve.size() > 1:
				dash.spark(self, Rect2(at.x + w - 14.0 - 72.0, at.y + 12.0, 72.0, 20.0), curve, AmTheme.col("MINT"))


# ====================================================================== the bars
class Chart extends Control:
	const PAD_L := 60.0
	const PAD_R := 14.0
	const PAD_T := 16.0
	const PAD_B := 28.0
	var dash
	var bars: Array = []
	var top := 1.0
	var hover := -1
	var hover_seg := -1

	func _init(d) -> void:
		dash = d
		custom_minimum_size = Vector2(0, 260)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_exited.connect(func() -> void:
			hover = -1
			hover_seg = -1
			mouse_default_cursor_shape = Control.CURSOR_ARROW
			queue_redraw())

	func set_data(d: Dictionary) -> void:
		bars = d["bars"]
		top = float(d["top"])
		if hover >= bars.size():
			hover = -1
		queue_redraw()

	func plot() -> Rect2:
		return Rect2(PAD_L, PAD_T, maxf(10.0, size.x - PAD_L - PAD_R), maxf(10.0, size.y - PAD_T - PAD_B))

	## Where each piece of a bar is drawn, from the baseline up: [[Rect2, piece]…]. The same sums serve the drawing
	## and the pointer. A 2 px gap of the surface keeps two pieces apart, when the piece is tall enough to spare it.
	func pieces(i: int) -> Array:
		var out := []
		if i < 0 or i >= bars.size() or bars[i] == null:
			return out
		var r := plot()
		var slot := r.size.x / bars.size()
		var bw := maxf(1.0, slot - (2.0 if slot >= 4.0 else 1.0))
		var x := r.position.x + i * slot + (slot - bw) / 2.0
		var y := r.end.y
		for seg in bars[i]["segs"]:
			var h := r.size.y * float(seg["bytes"]) / top
			y -= h
			out.append([Rect2(x, y + (2.0 if h >= 5.0 else 0.0), bw, maxf(1.0, h - (2.0 if h >= 5.0 else 0.0))), seg])
		return out

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseMotion and bars.size() > 0:
			var r := plot()
			var i := int(floor((e.position.x - r.position.x) / (r.size.x / bars.size()))) if r.grow(2.0).has_point(e.position) else -1
			i = clampi(i, -1, bars.size() - 1)
			var seg := -1
			var list := pieces(i)
			for j in list.size():
				var box: Rect2 = list[j][0]
				if e.position.y >= box.position.y - 2.0 and e.position.y <= box.end.y:
					seg = j
			if i != hover or seg != hover_seg:
				hover = i
				hover_seg = seg
				var id := str(list[seg][1]["id"]) if seg >= 0 else ""
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if id != "" and dash.is_running(id) else Control.CURSOR_ARROW
				queue_redraw()
		elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and hover >= 0 and hover_seg >= 0:
			var list := pieces(hover)
			if hover_seg < list.size():
				var id := str(list[hover_seg][1]["id"])
				if id != "" and dash.is_running(id):
					dash.session_picked.emit(id)

	func _draw() -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var grid := Color(AmTheme.col("BORDER"), 0.55)
		var r := plot()
		var hist: Dictionary = dash.hist
		var n := bars.size()
		if hist.get("off", false) or n == 0 or not bars.any(func(b: Variant) -> bool: return b != null):
			var why := "No reading yet in this span: the first one comes within half a minute of the engine's start."
			if hist.get("off", false):
				why = "The readings over time are off (AGMGD_HOST_SAMPLE=0)."
			elif hist.is_empty():
				why = "The engine has not told its readings yet."
			draw_string(dash.font_r, Vector2(r.position.x, r.position.y + 22.0), why, HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 13, muted)
			return
		# the axis: 0, half, top. Hairlines, one shade off the surface
		for f in [0.0, 0.5, 1.0]:
			var y: float = r.end.y - r.size.y * float(f)
			draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), grid, 1.0)
			draw_string(dash.font_r, Vector2(4, y + 4.0), "0" if f == 0.0 else View.mem(top * f), HORIZONTAL_ALIGNMENT_RIGHT, PAD_L - 12.0, 11, muted)
		# all the memory there is, when the bars come near it: a threshold, so dashed and named
		var total := float(hist.get("total", 0))
		if total > 0.0 and total <= top * 1.02:
			var ty := r.end.y - r.size.y * total / top
			draw_dashed_line(Vector2(r.position.x, ty), Vector2(r.end.x, ty), AmTheme.col("WARN"), 1.5, 6.0)
			draw_string(dash.font_b, Vector2(r.end.x - 260.0, ty - 5.0), "all the memory there is: " + View.mem(total), HORIZONTAL_ALIGNMENT_RIGHT, 260.0, 11, muted)
		var slot := r.size.x / n
		if hover >= 0:  # the bar under the pointer answers: its column is lit
			draw_rect(Rect2(r.position.x + hover * slot, r.position.y, slot, r.size.y), Color(AmTheme.col("PANEL_2"), 0.6))
		for i in n:
			var list := pieces(i)
			for j in list.size():
				var box: Rect2 = list[j][0]
				var col: Color = dash.colour(int(list[j][1]["slot"]))
				if i == hover:
					col = col.lightened(0.14)
				if j == list.size() - 1 and box.size.x >= 6.0 and box.size.y >= 4.0:  # the top of the pile is rounded
					var sb := StyleBoxFlat.new()
					sb.bg_color = col
					sb.corner_radius_top_left = int(minf(4.0, box.size.x / 2.0))
					sb.corner_radius_top_right = sb.corner_radius_top_left
					draw_style_box(sb, box)
				else:
					draw_rect(box, col)
		# the moments worth a mark: the engine started reading, the computer (WSL) started anew
		var t: Array = hist.get("t", [])
		var step := float(hist.get("step", 60))
		for m in hist.get("marks", []):
			if t.is_empty():
				break
			var mx := r.position.x + (float(m["ts"]) - float(t[0])) / step * slot
			if mx >= r.position.x and mx <= r.end.x:
				draw_colored_polygon(PackedVector2Array([Vector2(mx, r.end.y + 3.0), Vector2(mx - 4.0, r.end.y + 10.0), Vector2(mx + 4.0, r.end.y + 10.0)]),
					ink if str(m["kind"]) == "boot" else muted)
		# the time axis: the first slice, the middle one, now
		var long: bool = dash.long_span()
		for k in [0, n / 2, n - 1]:
			var label: String = "now" if k == n - 1 else View.clock(int(t[k]), long, dash.bias)
			var align := HORIZONTAL_ALIGNMENT_RIGHT if k == n - 1 else HORIZONTAL_ALIGNMENT_LEFT
			var lx: float = (r.end.x - 120.0) if k == n - 1 else (r.position.x + k * slot)
			draw_string(dash.font_r, Vector2(lx, size.y - 6.0), label, align, 120.0, 11, muted)
		if hover >= 0:
			_draw_box(r, slot, t, step, long)

	## The box beside the pointed bar: the slice's time, what was in use, then every piece of the pile, the figure
	## first. It only repeats what the table and the axis already say.
	func _draw_box(r: Rect2, slot: float, t: Array, step: float, long: bool) -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var hist: Dictionary = dash.hist
		var lines := []  # [slot or null, figure, words]
		var from: String = View.clock(int(t[hover]), long, dash.bias)
		var to: String = View.clock(int(t[hover] + step), false, dash.bias)
		var title := "%s to %s" % [from, to]
		var bar: Variant = bars[hover]
		if bar == null:
			lines.append([null, "", "No reading: the engine was not running."])
		else:
			var peak: Variant = hist.get("used_peak", [])[hover] if hover < hist.get("used_peak", []).size() else null
			var words := "in use"
			if peak != null and float(peak) > float(bar["used"]) * 1.05:
				words += " on average, %s at the most" % View.mem(float(peak))
			lines.append([null, View.mem(float(bar["used"])), words])
			var segs: Array = bar["segs"].duplicate()
			segs.reverse()  # as the pile reads, from its top
			for seg in segs:
				var what := "everything else"
				if int(seg["slot"]) == View.OTHER:
					what = "other sessions"
				elif str(seg["id"]) != "":
					what = dash.name_of(str(seg["id"]))
				lines.append([int(seg["slot"]), View.mem(float(seg["bytes"])), what])
		for m in hist.get("marks", []):
			if float(m["ts"]) >= float(t[hover]) and float(m["ts"]) < float(t[hover]) + step:
				lines.append([null, "", ("WSL started here." if dash.host.get("wsl", false) else "This computer started here.") if str(m["kind"]) == "boot" else "The engine started reading here."])
		var fig_w := 0.0
		var word_w: float = dash.font_b.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x - 26.0
		for l in lines:
			fig_w = maxf(fig_w, dash.font_b.get_string_size(str(l[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
		for l in lines:
			word_w = maxf(word_w, dash.font_r.get_string_size(str(l[2]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x - (0.0 if str(l[1]) != "" else fig_w + 8.0))
		var w := minf(26.0 + fig_w + 8.0 + word_w + 14.0, r.size.x)
		var h := 30.0 + lines.size() * 18.0
		var x := r.position.x + (hover + 1) * slot + 8.0
		if x + w > r.end.x:
			x = r.position.x + hover * slot - 8.0 - w
		x = clampf(x, r.position.x, maxf(r.position.x, r.end.x - w))
		var box := Rect2(x, r.position.y + 2.0, w, h)
		draw_style_box(AmTheme.box(AmTheme.col("PANEL_2"), 8, AmTheme.col("BORDER"), 1, 0), box)
		draw_string(dash.font_b, Vector2(x + 12.0, box.position.y + 19.0), title, HORIZONTAL_ALIGNMENT_LEFT, w - 24.0, 12, ink)
		for j in lines.size():
			var y := box.position.y + 38.0 + j * 18.0
			var l: Array = lines[j]
			if l[0] != null:  # a short stroke of the piece's colour, not a filled box
				draw_line(Vector2(x + 12.0, y - 4.0), Vector2(x + 22.0, y - 4.0), dash.colour(int(l[0])), 3.0)
			if str(l[1]) == "":
				draw_string(dash.font_r, Vector2(x + 12.0, y), str(l[2]), HORIZONTAL_ALIGNMENT_LEFT, w - 24.0, 12, muted)
			else:
				draw_string(dash.font_b, Vector2(x + 26.0, y), str(l[1]), HORIZONTAL_ALIGNMENT_RIGHT, fig_w, 12, ink)
				draw_string(dash.font_r, Vector2(x + 26.0 + fig_w + 8.0, y), str(l[2]), HORIZONTAL_ALIGNMENT_LEFT, w - 26.0 - fig_w - 20.0, 12, muted)


# ====================================================================== the legend
class Legend extends Control:
	const ROW := 20.0
	var dash
	var entries: Array = []  # [slot, words]

	func _init(d) -> void:
		dash = d
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_EXPAND_FILL

	func rebuild() -> void:
		entries = []
		var named := []
		var others := 0
		for s in dash.hist.get("sessions", []):
			var slot := int(dash.slots.get(str(s["id"]), View.OTHER))
			if slot == View.OTHER:
				others += 1
			else:
				named.append([slot, str(s["name"])])
		named.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		entries = named
		if others > 0:
			entries.append([View.OTHER, "%d other session%s" % [others, "" if others == 1 else "s"]])
		if not dash.hist.get("used", []).is_empty():
			entries.append([View.REST, "everything else in use: the engine, tmux, other programs"])
		_fit()
		queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_fit()

	## Where each entry goes, row after row: [[x, row]…].
	func places() -> Array:
		var out := []
		var x := Chart.PAD_L
		var row := 0
		for e in entries:
			var w: float = 16.0 + dash.font_r.get_string_size(str(e[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 20.0
			if x + w > size.x and x > Chart.PAD_L:
				x = Chart.PAD_L
				row += 1
			out.append([x, row])
			x += w
		return out

	func _fit() -> void:
		var p := places()
		custom_minimum_size.y = 0.0 if p.is_empty() else (int(p[p.size() - 1][1]) + 1) * ROW

	func _draw() -> void:
		var p := places()
		for i in entries.size():
			var at := Vector2(float(p[i][0]), int(p[i][1]) * ROW)
			var sb := StyleBoxFlat.new()  # a small block, as the bars are blocks
			sb.bg_color = dash.colour(int(entries[i][0]))
			sb.set_corner_radius_all(2)
			draw_style_box(sb, Rect2(at.x, at.y + 5.0, 10.0, 10.0))
			draw_string(dash.font_r, Vector2(at.x + 16.0, at.y + 14.0), str(entries[i][1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AmTheme.col("MUTED"))


# ====================================================================== the table
class Table extends Control:
	const HEAD := 28.0
	const ROW := 32.0
	## The columns after the name, each with its width; the figures are set to the right so they line up.
	const COLS := [["open", "Open for", 92.0], ["idle", "Last active", 118.0], ["bytes", "Memory", 84.0], ["spark", "", 96.0],
		["peak", "At the most", 96.0], ["cpu", "Of a processor", 104.0], ["where", "Folder", 150.0]]
	var dash
	var rows: Array = []
	var hover := -1

	func _init(d) -> void:
		dash = d
		clip_contents = true
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_exited.connect(func() -> void:
			hover = -1
			mouse_default_cursor_shape = Control.CURSOR_ARROW
			queue_redraw())

	func set_rows(a: Array) -> void:
		rows = a
		custom_minimum_size.y = HEAD + maxi(rows.size(), 1) * ROW
		if hover >= rows.size():
			hover = -1
		queue_redraw()

	func name_width() -> float:
		var fixed := 0.0
		for c in COLS:
			fixed += float(c[2])
		return clampf(size.x - fixed, 170.0, 420.0)  # not wider: a figure far from its name is hard to follow across

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseMotion:
			var i := int(floor((e.position.y - HEAD) / ROW)) if e.position.y >= HEAD else -1
			i = i if i < rows.size() else -1
			if i != hover:
				hover = i
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if i >= 0 and rows[i]["running"] else Control.CURSOR_ARROW
				queue_redraw()
		elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and hover >= 0 and rows[hover]["running"]:
			dash.session_picked.emit(str(rows[hover]["id"]))

	func _cell(row: Dictionary, key: String) -> String:
		var running: bool = row["running"]
		match key:
			"open":
				return "–" if float(row["open"]) < 0.0 else View.span(float(row["open"]))
			"idle":
				if float(row["idle"]) < 0.0:
					return "–"
				return View.ago(float(row["idle"])) if running else "ended " + View.ago(float(row["idle"]))
			"bytes":
				return View.mem(float(row["bytes"])) if running else "–"
			"peak":
				return View.mem(float(row["peak"]))
			"cpu":
				return View.share(row["cpu"]) if running else "–"
		return ""

	func _draw() -> void:
		var ink := AmTheme.col("TEXT")
		var muted := AmTheme.col("MUTED")
		var faint := AmTheme.col("FAINT")
		var line := Color(AmTheme.col("BORDER"), 0.55)
		var nw := name_width()
		draw_string(dash.font_r, Vector2(22.0, 18.0), "Session", HORIZONTAL_ALIGNMENT_LEFT, nw - 22.0, 11, muted)
		var x := nw
		for c in COLS:
			var right: bool = c[0] in ["bytes", "peak", "cpu"]
			draw_string(dash.font_r, Vector2(x, 18.0), str(c[1]), HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT, float(c[2]) - 14.0, 11, muted)
			x += float(c[2])
		draw_line(Vector2(0, HEAD - 1.0), Vector2(size.x, HEAD - 1.0), line, 1.0)
		if rows.is_empty():
			draw_string(dash.font_r, Vector2(22.0, HEAD + 20.0), "No session is running, and none ran in this span.", HORIZONTAL_ALIGNMENT_LEFT, size.x - 22.0, 13, muted)
			return
		for i in rows.size():
			var row: Dictionary = rows[i]
			var y := HEAD + i * ROW
			var running: bool = row["running"]
			if i == hover and running:
				draw_style_box(AmTheme.box(AmTheme.col("PANEL_2"), 6, Color(0, 0, 0, 0), 0, 0), Rect2(0, y + 1.0, size.x, ROW - 2.0))
			var sb := StyleBoxFlat.new()
			sb.bg_color = dash.colour(int(row["slot"]))
			sb.set_corner_radius_all(2)
			draw_style_box(sb, Rect2(6.0, y + 11.0, 10.0, 10.0))
			var name := str(row["name"])
			var name_w: float = minf(dash.font_b.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x, nw - 34.0)
			draw_string(dash.font_b if running else dash.font_r, Vector2(22.0, y + 21.0), name, HORIZONTAL_ALIGNMENT_LEFT, nw - 34.0, 13, ink if running else muted)
			if str(row["tool"]) != "" and 22.0 + name_w + 12.0 < nw - 60.0:
				draw_string(dash.font_r, Vector2(22.0 + name_w + 10.0, y + 21.0), str(row["tool"]), HORIZONTAL_ALIGNMENT_LEFT, nw - 34.0 - name_w - 10.0, 11, faint)
			x = nw
			for c in COLS:
				var key := str(c[0])
				var w := float(c[2])
				if key == "spark":
					dash.spark(self, Rect2(x, y + 8.0, w - 22.0, ROW - 16.0), row["spark"], dash.colour(int(row["slot"])))
				elif key == "where":
					if str(row["drive"]) != "":  # git is slower on the Windows disk: said with a mark, not by a colour alone
						draw_string(dash.font_b, Vector2(x, y + 21.0), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AmTheme.col("WARN"))
						draw_string(dash.font_r, Vector2(x + 12.0, y + 21.0), "on %s: · git is slower" % str(row["drive"]).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, w - 14.0, 12, muted)
					elif running and dash.host.get("wsl", false):
						draw_string(dash.font_r, Vector2(x, y + 21.0), "inside Linux", HORIZONTAL_ALIGNMENT_LEFT, w - 2.0, 12, faint)
				else:
					var right: bool = key in ["bytes", "peak", "cpu"]
					draw_string(dash.font_r, Vector2(x, y + 21.0), _cell(row, key), HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT, w - 14.0, 12, ink if running and key != "peak" else muted)
				x += w
			draw_line(Vector2(0, y + ROW - 0.5), Vector2(size.x, y + ROW - 0.5), Color(line, 0.3), 1.0)
