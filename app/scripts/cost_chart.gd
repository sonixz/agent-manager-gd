class_name CostChart
extends Control
## Loop 16: the sandboxes' measured cost, last 30 days, drawn by hand.
## Bars: cost per day. Line: this month's running total (one shared $ axis: the total is what the budget is about).
## Dashed line: the monthly budget, when set. Hover a day for its numbers.

var days: PackedStringArray = []
var day_cost: Array = []
var cumulative: Array = []
var budget := 0.0
var hover := -1
var font_r: Font  # kept for the chart's life: a font made inside _draw is freed before the frame is drawn
var font_b: Font

const PAD_L := 56.0
const PAD_R := 16.0
const PAD_T := 14.0
const PAD_B := 26.0


func set_data(costs: Dictionary, monthly_budget: float) -> void:
	days = PackedStringArray(costs.get("days", []))
	day_cost = costs.get("day_cost", [])
	cumulative = costs.get("month_cumulative", [])
	budget = monthly_budget
	tooltip_text = ""
	queue_redraw()


func _ready() -> void:
	font_r = AmTheme.ui_font(400)
	font_b = AmTheme.ui_font(650)
	custom_minimum_size = Vector2(0, 220)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(func() -> void:
		hover = -1
		queue_redraw())


func _top_value() -> float:
	var m := 0.0
	for v in day_cost:
		m = maxf(m, float(v))
	for v in cumulative:
		m = maxf(m, float(v))
	if _budget_on_scale():
		m = maxf(m, budget)
	return _nice(maxf(m, 0.01))


func _budget_on_scale() -> bool:
	var month := float(cumulative[cumulative.size() - 1]) if cumulative.size() > 0 else 0.0
	return budget > 0 and month >= 0.25 * budget


static func _nice(v: float) -> float:
	# 1, 2, 2.5, 5 × a power of ten, at or above v
	var p := pow(10.0, floor(log(v) / log(10.0)))
	for f in [1.0, 2.0, 2.5, 5.0, 10.0]:
		if f * p >= v:
			return f * p
	return 10.0 * p


static func money(v: float) -> String:
	if v == 0.0:
		return "$0"
	if v < 0.1:
		return "$%.3f" % v
	if v < 10.0:
		return "$%.2f" % v
	return "$%.0f" % v


func _plot() -> Rect2:
	return Rect2(PAD_L, PAD_T, maxf(10.0, size.x - PAD_L - PAD_R), maxf(10.0, size.y - PAD_T - PAD_B))


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and days.size() > 0:
		var r := _plot()
		var i := int(floor((e.position.x - r.position.x) / (r.size.x / days.size())))
		i = clampi(i, -1, days.size() - 1) if r.has_point(e.position) else -1
		if i != hover:
			hover = i
			queue_redraw()


func _draw() -> void:
	var font := font_r
	var bold := font_b
	var ink := AmTheme.col("TEXT")
	var muted := AmTheme.col("MUTED")
	var grid := Color(AmTheme.col("BORDER"), 0.55)
	var bar_col := AmTheme.col("FOREST_LIGHT")
	var line_col := AmTheme.col("MINT")
	var budget_col := AmTheme.col("WARN")
	var r := _plot()
	var n := days.size()
	if n == 0:
		draw_string(font, Vector2(r.position.x, r.position.y + 20), "No sandbox has run yet: costs appear here as soon as one does.", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, muted)
		return
	var top := _top_value()
	var y_of := func(v: float) -> float: return r.end.y - r.size.y * clampf(v / top, 0.0, 1.05)
	# recessive grid and $ axis: 0, ½, top
	for f in [0.0, 0.5, 1.0]:
		var y: float = y_of.call(top * f)
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), grid, 1.0)
		draw_string(font, Vector2(4, y + 4), money(top * f), HORIZONTAL_ALIGNMENT_RIGHT, PAD_L - 10, 11, muted)
	var slot := r.size.x / n
	var bw := maxf(2.0, slot - 2.0)  # a 2 px gap between bars
	# bars: cost per day, rounded at the data end, anchored to the baseline
	for i in n:
		var v := float(day_cost[i])
		if v <= 0.0:
			continue
		var y0: float = y_of.call(v)
		var h := maxf(2.0, r.end.y - y0)
		var rect := Rect2(r.position.x + i * slot + 1.0, r.end.y - h, bw, h)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(bar_col, 1.0 if i == hover else 0.75)
		var rad := int(minf(4.0, bw / 2.0))
		sb.corner_radius_top_left = rad
		sb.corner_radius_top_right = rad
		draw_style_box(sb, rect)
	# budget: dashed, labelled directly
	if _budget_on_scale():
		var by: float = y_of.call(budget)
		draw_dashed_line(Vector2(r.position.x, by), Vector2(r.end.x, by), budget_col, 1.5, 6.0)
		draw_string(bold, Vector2(r.end.x - 160, by - 5), "budget " + money(budget) + "/month", HORIZONTAL_ALIGNMENT_RIGHT, 160, 11, budget_col)

	# the month's running total: 2 px line, a marker at today
	var pts := PackedVector2Array()
	for i in n:
		pts.append(Vector2(r.position.x + (i + 0.5) * slot, y_of.call(float(cumulative[i]))))
	for i in range(1, pts.size()):
		if float(cumulative[i]) == 0.0 and float(cumulative[i - 1]) == 0.0:
			continue
		if float(cumulative[i]) < float(cumulative[i - 1]):  # a new month starts from zero
			continue
		draw_line(pts[i - 1], pts[i], line_col, 2.0, true)
	var last := pts[pts.size() - 1]
	draw_circle(last, 5.0, AmTheme.col("PANEL"))
	draw_circle(last, 4.0, line_col)
	draw_string(bold, last + Vector2(-150, -10), "this month " + money(float(cumulative[n - 1])), HORIZONTAL_ALIGNMENT_RIGHT, 144, 12, ink)
	# x labels: first, middle, last day
	for i in [0, n / 2, n - 1]:
		var d := days[i].substr(5).replace("-", "/")
		draw_string(font, Vector2(r.position.x + i * slot, size.y - 6), d, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, muted)
	# hover: a crosshair and the day's numbers
	if hover >= 0:
		var x := r.position.x + (hover + 0.5) * slot
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(muted, 0.6), 1.0)
		var lines := ["%s" % days[hover], "that day: " + money(float(day_cost[hover])), "month so far: " + money(float(cumulative[hover]))]
		var w := 170.0
		var bx := clampf(x + 10, r.position.x, r.end.x - w)
		var box := Rect2(bx, r.position.y + 4, w, 62)
		draw_style_box(AmTheme.box(AmTheme.col("PANEL_2"), 8, AmTheme.col("BORDER"), 1, 8), box)
		for j in lines.size():
			draw_string(bold if j == 0 else font, Vector2(bx + 10, r.position.y + 22 + j * 17), lines[j], HORIZONTAL_ALIGNMENT_LEFT, w - 16, 12, ink if j == 0 else muted)
