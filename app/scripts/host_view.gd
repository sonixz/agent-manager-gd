extends RefCounted
## The engine room's dashboard, its sums and its words (Loop 36): what the tiles say, how a span of readings becomes
## stacked bars, which colour a session keeps, how a duration is written. Nothing here draws or asks anything, so
## the headless cases (tools_setup_check.gd) can check every line. The drawing is scripts/host_dash.gd.
##
## Loaded with preload, not by a class name (see setup_probe.gd).

const Probe := preload("res://scripts/setup_probe.gd")

## The spans the page offers. The slices are what the engine is asked for: about one bar per minute, five minutes,
## fifteen minutes, hour.
const RANGES := [
	{"id": "1h", "label": "Last hour", "seconds": 3600, "points": 60},
	{"id": "6h", "label": "6 hours", "seconds": 21600, "points": 72},
	{"id": "24h", "label": "24 hours", "seconds": 86400, "points": 96},
	{"id": "7d", "label": "7 days", "seconds": 604800, "points": 168},
]

## Eight hues in a fixed order, never cycled: a ninth session joins « other sessions ». The order is what keeps
## neighbours apart for colour-blind eyes; both sets were checked against every theme's surface (2026-11-12: every
## hard check passes; where a hue is under 3:1 against the surface, the names and figures in the table stand in).
const HUES_DARK := ["3987e5", "d95926", "199e70", "c98500", "d55181", "008300", "9085e9", "e66767"]
const HUES_LIGHT := ["2a78d6", "eb6834", "1baf7a", "eda100", "e87ba4", "008300", "6250d6", "e34948"]
const OTHER := -1   # the sessions past the eighth, drawn together
const REST := -2    # what runs beside the sessions: the engine, tmux, other programs


static func range_of(id: String) -> Dictionary:
	for r in RANGES:
		if r["id"] == id:
			return r
	return RANGES[0]


# ---------------------------------------------------------------- words
## 520 MB, 1.3 GB, 16 GB.
static func mem(bytes: float) -> String:
	if bytes < 0.95 * 1073741824.0:
		return "%d MB" % int(round(bytes / 1048576.0))
	var v := bytes / 1073741824.0
	return ("%.1f GB" % v) if v < 9.95 else ("%d GB" % int(round(v)))


## 40 s, 12 min, 3 h 05, 2 d 4 h.
static func span(seconds: float) -> String:
	var s := int(maxf(seconds, 0.0))
	if s < 60:
		return "%d s" % s
	if s < 3600:
		return "%d min" % (s / 60)
	if s < 86400:
		return "%d h %02d" % [s / 3600, (s % 3600) / 60]
	return "%d d %d h" % [s / 86400, (s % 86400) / 3600]


static func ago(seconds: float) -> String:
	return "now" if seconds < 10.0 else span(seconds) + " ago"


## A share of one processor as a percentage: 0.5 is « 50 % », 2.4 is « 240 % » (more than two processors busy).
static func share(v: Variant) -> String:
	if v == null:
		return "…"
	var p := float(v) * 100.0
	if p > 0.0 and p < 0.05:
		return "under 0.1 %"
	return ("%.1f %%" % p) if p < 9.95 and p >= 0.05 else ("%d %%" % int(round(p)))


## A moment for the time axis and the hover box. `bias` is the time zone, in minutes east of UTC. Spans of a day or
## less say the hour; longer ones say the day too.
static func clock(ts: int, long_span: bool, bias: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(ts + bias * 60)
	var hm := "%02d:%02d" % [d["hour"], d["minute"]]
	if not long_span:
		return hm
	return "%s %d, %s" % [["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d["month"]], d["day"], hm]


## 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8 × a power of ten, at or above v: steps close enough that the tallest bar fills
## most of the height.
static func nice(v: float) -> float:
	if v <= 0.0:
		return 1.0
	var p := pow(10.0, floor(log(v) / log(10.0)))
	for f in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]:
		if f * p >= v * 0.999:
			return f * p
	return 10.0 * p


## The top of the memory axis, in bytes: a round number of GB (or of MB under one GB) above the tallest bar.
static func top_of(bytes: float) -> float:
	var unit := 1073741824.0 if bytes >= 0.8 * 1073741824.0 else 1048576.0
	return nice(maxf(bytes, 1048576.0) / unit) * unit


# ---------------------------------------------------------------- colours
## Which hue each session wears. A session keeps the one it has; a new one takes the first that is free; past the
## eighth it joins « other sessions ». `ids` is everybody to show, the ones to serve first at the start (the running
## ones, then the ended ones in the order they first appeared). Whoever is no longer shown gives its hue back.
static func assign(slots: Dictionary, ids: Array) -> Dictionary:
	var out := {}
	var taken := {}
	for id in ids:
		if slots.has(id) and int(slots[id]) >= 0:
			out[id] = int(slots[id])
			taken[int(slots[id])] = true
	for id in ids:
		if out.has(id):
			continue
		out[id] = OTHER
		for s in HUES_DARK.size():
			if not taken.has(s):
				out[id] = s
				taken[s] = true
				break
	return out


static func hue(slot: int, light: bool) -> Color:
	return Color.html((HUES_LIGHT if light else HUES_DARK)[clampi(slot, 0, HUES_DARK.size() - 1)])


# ---------------------------------------------------------------- the bars
## A span of readings as stacked bars. One bar per slice: the sessions in the order of their hues (so a session sits
## at the same height in the pile from one bar to the next), then the other sessions together, then the rest of
## what was in use. A slice without reading gives no bar (null): the engine was not running.
## Gives {"bars": [null or {"segs": [{"slot", "id", "bytes"}], "sum": bytes, "used": bytes}], "top": bytes}.
static func stack(hist: Dictionary, slots: Dictionary) -> Dictionary:
	var bars := []
	var tallest := 0.0
	var used: Array = hist.get("used", [])
	var by_slot := []
	for s in hist.get("sessions", []):
		by_slot.append([int(slots.get(str(s["id"]), OTHER)), s])
	by_slot.sort_custom(func(a: Array, b: Array) -> bool:
		var sa: int = a[0] if a[0] >= 0 else 99
		var sb: int = b[0] if b[0] >= 0 else 99
		return sa < sb)
	for i in used.size():
		if used[i] == null:
			bars.append(null)
			continue
		var segs := []
		var total := 0.0
		var other := 0.0
		for pair in by_slot:
			var b: Variant = pair[1]["bytes"][i] if i < pair[1]["bytes"].size() else null
			if b == null or float(b) <= 0.0:
				continue
			total += float(b)
			if pair[0] == OTHER:
				other += float(b)
			else:
				segs.append({"slot": pair[0], "id": str(pair[1]["id"]), "bytes": float(b)})
		if other > 0.0:
			segs.append({"slot": OTHER, "id": "", "bytes": other})
		# a session's memory counts the pages it shares with others once each, so the sessions together may pass
		# what the computer says is in use: then nothing is left to call « the rest »
		var rest := maxf(0.0, float(used[i]) - total)
		if rest > 0.0:
			segs.append({"slot": REST, "id": "", "bytes": rest})
		bars.append({"segs": segs, "sum": total + rest, "used": float(used[i])})
		tallest = maxf(tallest, total + rest)
	var top := top_of(tallest)
	# when the bars come near all the memory there is, the axis is that memory: how close it came is the point
	var all := float(hist.get("total", 0))
	if all > 0.0 and tallest >= 0.6 * all:
		top = maxf(all, tallest)
	return {"bars": bars, "top": top}


## The last value of a series that is not empty, or null.
static func last_of(values: Array) -> Variant:
	for i in range(values.size() - 1, -1, -1):
		if values[i] != null:
			return values[i]
	return null


# ---------------------------------------------------------------- the tiles
static func _tile(id: String, label: String, value: String, note: String, warn := false, spark: Array = []) -> Dictionary:
	return {"id": id, "label": label, "value": value, "note": note, "warn": warn, "spark": spark}


## The figures of now, one tile each: label, value, a sentence under it, whether it deserves a look, and the same
## figure over the span shown (for the small curve). `f` is what the setup probe read (Windows' side); `host` the
## engine's answer to /host; `hist` its answer to /host/history.
static func tiles(f: Dictionary, host: Dictionary, hist: Dictionary, windows := OS.get_name() == "Windows") -> Array:
	var out := []
	if host.is_empty():
		return out
	var w: Dictionary = f.get("windows", {})
	var wsl := bool(host.get("wsl", false))
	var m: Dictionary = host["memory"]
	var note := "of %s%s" % [mem(float(m["total"])), " inside WSL" if wsl else ""]
	if int(w.get("vmmem", 0)) > 0:
		note += " · Windows gives WSL %s" % mem(float(w["vmmem"]))
	elif int(m.get("swap_used", 0)) > 104857600:
		note += " · %s of swap in use" % mem(float(m["swap_used"]))
	out.append(_tile("memory", "Memory in use", mem(float(m["used"])), note,
		int(m["total"]) > 0 and float(m["available"]) / float(m["total"]) < 0.08, hist.get("used", [])))
	var ss: Array = host.get("sessions", [])
	if ss.is_empty():
		out.append(_tile("sessions", "Sessions running", "0", "none is running"))
	else:
		var each := float(host["sessions_bytes"]) / ss.size()
		var more := int(float(m["available"]) / maxf(each, 1.0))
		out.append(_tile("sessions", "Sessions running", str(ss.size()), "%s together · %s" % [mem(float(host["sessions_bytes"])),
			("room for about %d more" % more) if more >= 1 else "no room for one more"], more < 1))
	var n := int(host.get("processors", 1))
	var cpu: Variant = host.get("cpu")
	out.append(_tile("processors", "Processors busy", "…" if cpu == null else share(float(cpu)),
		"of %d processor%s · %.1f programs wanting one" % [n, "" if n == 1 else "s", float(host.get("load", 0.0))],
		cpu != null and float(cpu) > 0.9, hist.get("cpu", [])))
	# the disk: on Windows, the distribution's disk is one file on a Windows drive, and that drive's room is the true one
	var name := str(host.get("distro", "")) if str(host.get("distro", "")) != "" else Probe.usable(w)
	var d: Dictionary = w.get("disks", {}).get(name, {})
	if not d.is_empty() and int(d["total"]) > 0:
		var full := int(round(100.0 * (1.0 - float(d["free"]) / float(d["total"]))))
		out.append(_tile("disk", "Disk, free on %s" % str(d["drive"]), mem(float(d["free"])), "%d %% full · WSL's disk is a %s file there" % [full, mem(float(d["file"]))],
			full >= 90 or int(d["free"]) < 21474836480))
	else:
		var disk: Dictionary = host["disk"]
		var full2 := int(round(100.0 * (1.0 - float(disk["free"]) / maxf(float(disk["total"]), 1.0))))
		out.append(_tile("disk", "Disk, free", mem(float(disk["free"])), "%d %% full" % full2, int(disk["total"]) > 0 and full2 >= 90))
	out.append(_tile("up", "Up for", span(float(host.get("uptime", 0.0))), "since WSL started" if wsl else "since this computer started"))
	return out


# ---------------------------------------------------------------- the table
## One line per session of the span shown: the running ones first, the heaviest at the top, then the ones that ended
## within the span. `now` is the engine's clock (the readings' last moment), so an app and an engine whose clocks
## differ still say « 5 min ago » right.
static func rows(host: Dictionary, hist: Dictionary, slots: Dictionary, now: float) -> Array:
	var out := []
	var by := {}
	for s in hist.get("sessions", []):
		by[str(s["id"])] = s
	var live := {}
	for x in host.get("sessions", []):
		var id := str(x["id"])
		live[id] = true
		var h: Dictionary = by.get(id, {})
		out.append({"id": id, "name": str(x["name"]), "tool": str(x.get("tool", "")), "running": true, "slot": int(slots.get(id, OTHER)),
			"open": maxf(0.0, now - float(x.get("created", now))) if float(x.get("created", 0)) > 0.0 else -1.0,
			"idle": maxf(0.0, now - float(x.get("activity", now))) if float(x.get("activity", 0.0)) > 0.0 else -1.0,
			"bytes": float(x["bytes"]), "peak": maxf(float(h.get("peak", 0)), float(x["bytes"])), "cpu": x.get("cpu"),
			"drive": str(x.get("drive", "")), "spark": h.get("bytes", [])})
	var ended := []
	for id in by:
		if not live.has(id):
			var s: Dictionary = by[id]
			ended.append({"id": id, "name": str(s["name"]), "tool": "", "running": false, "slot": int(slots.get(id, OTHER)),
				"open": maxf(0.0, float(s["last"]) - float(s["first"])), "idle": maxf(0.0, now - float(s["last"])),
				"bytes": 0.0, "peak": float(s["peak"]), "cpu": null, "drive": "", "spark": s.get("bytes", [])})
	ended.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["idle"] < b["idle"])   # the last to end first
	return out + ended


## Who to give a hue to, in the order to serve them: the running sessions, then the ended ones as they first appeared.
static func ids_to_show(host: Dictionary, hist: Dictionary) -> Array:
	var ids := []
	for x in host.get("sessions", []):
		ids.append(str(x["id"]))
	for s in hist.get("sessions", []):
		if not ids.has(str(s["id"])):
			ids.append(str(s["id"]))
	return ids


## What the readings cost and how far back they go, in one sentence.
static func about(host: Dictionary, bias: int) -> String:
	if not host.has("history"):
		return "This engine was started before the readings over time existed: only this moment is shown. It starts anew with the app (close it and open it again)."
	var h: Dictionary = host["history"]
	if h.is_empty():
		return "The readings over time are off (AGMGD_HOST_SAMPLE=0): only this moment is shown."
	var e: Dictionary = host.get("engine", {})
	var cost := ""
	if not e.is_empty():
		cost = " The engine itself holds %s%s." % [mem(float(e.get("bytes", 0))), "" if e.get("cpu") == null else " and takes %s of one processor" % share(e["cpu"])]
	var since := ("since %s" % clock(int(h["since"]), true, bias)) if int(h.get("since", 0)) > 0 else "starting now"
	var problem := (" The last reading failed: %s." % str(h["error"])) if str(h.get("error", "")) != "" else ""
	return "One reading every %d s, kept %d days, %s.%s%s" % [int(h["interval"]), int(h["keep"]) / 86400, since, cost, problem]
