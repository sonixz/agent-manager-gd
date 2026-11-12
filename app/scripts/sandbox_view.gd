extends RefCounted
## The Sandboxes page, its words and its sums: the inventory of every sandbox made from here (the destroyed ones
## too), the life of each over the last thirty days, the tiles above. Nothing here draws or asks anything: the
## headless cases (tools_setup_check.gd) check every line. The drawing is scripts/sandbox_widgets.gd.
##
## Loaded with preload, not by a class name (see setup_probe.gd).

const HostView := preload("res://scripts/host_view.gd")
const DAYS := 30


## A sandbox's state in words, with its level: ok (running), warn (paused, or Fly.io not reached), bad (its machine
## is gone at Fly.io though it was not destroyed from here), off (destroyed).
static func state_of(row: Dictionary) -> Dictionary:
	if bool(row.get("destroyed", false)):
		return {"text": "destroyed", "level": "off"}
	var st := str(row.get("state", ""))
	if st == "started":
		return {"text": "running", "level": "ok"}
	if st in ["stopped", "suspended", "stopping", "suspending"]:
		return {"text": "paused", "level": "warn"}
	if st == "gone":
		return {"text": "gone at Fly.io", "level": "bad"}
	if st == "unknown":
		return {"text": "Fly.io not reached", "level": "warn"}
	return {"text": st if st != "" else "not known", "level": "warn"}


static func name_of(row: Dictionary) -> String:
	return str(row.get("name", "")) if str(row.get("name", "")) != "" else "sandbox " + str(row.get("id", ""))


## shared-cpu-1x-1024 as people read it: « shared · 1 CPU · 1 GB ».
static func size_words(size: String) -> String:
	var m := RegEx.create_from_string("^(shared|performance)-cpu-(\\d+)x(?:-(\\d+))?$").search(size)
	if m == null:
		return size
	var out := "%s · %s CPU" % [m.get_string(1), m.get_string(2)]
	if m.get_string(3) != "":
		var mb := int(m.get_string(3))
		out += " · " + (("%d GB" % (mb / 1024)) if mb % 1024 == 0 else ("%d MB" % mb))
	return out


static func money(v: float) -> String:
	if v <= 0.0:
		return "$0"
	return ("$%.3f" % v) if v < 0.1 else ("$%.2f" % v)


## The order of the inventory: running, then paused and the like, then destroyed; in each, the latest activity first.
static func order(rows: Array) -> Array:
	var out := rows.duplicate()
	var rank := func(r: Dictionary) -> int:
		return {"ok": 0, "warn": 1, "bad": 1, "off": 2}[state_of(r)["level"]]
	var last := func(r: Dictionary) -> float:
		return maxf(float(r.get("last_stop", 0.0)), float(r.get("created", 0.0)))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = rank.call(a)
		var rb: int = rank.call(b)
		return ra < rb if ra != rb else last.call(a) > last.call(b))
	return out


## A sandbox's life over the last `days` days, for its bar: each period its machine ran as a pair of places between
## 0 (that many days ago) and 1 (now), the last one marked when it still runs; where it was made, and where it
## ended when it was destroyed (-1 when that is before the bar's start).
static func life(row: Dictionary, now: float, days := DAYS) -> Dictionary:
	var from := now - days * 86400.0
	var place := func(t: float) -> float:
		return clampf((t - from) / (now - from), 0.0, 1.0)
	var runs := []
	for r in row.get("runs", []):
		var stop: float = now if r[1] == null else float(r[1])
		if stop < from:
			continue
		runs.append([place.call(float(r[0])), place.call(stop), r[1] == null and not bool(row.get("destroyed", false))])
	var made := float(row.get("created", 0.0))
	var ended := float(row.get("last_stop", 0.0)) if bool(row.get("destroyed", false)) else 0.0
	return {"runs": runs, "made": place.call(made) if made >= from else -1.0,
		"ended": place.call(maxf(ended, made)) if bool(row.get("destroyed", false)) and maxf(ended, made) >= from else -1.0}


## A line of the inventory in words, for the pointer.
static func tip(row: Dictionary, now: float, bias: int) -> String:
	var out := "%s · %s" % [name_of(row), state_of(row)["text"]]
	out += "\n%s · %s · made %s" % [size_words(str(row.get("size", ""))), str(row.get("region", "")), HostView.clock(int(row.get("created", 0)), true, bias)]
	var n: int = row.get("runs", []).size()
	if n == 0:
		out += "\nIts machine never ran, as far as Fly.io told."
	else:
		out += "\nIts machine ran %d time%s, %s in all: %s at Fly.io's published price." % [n, "" if n == 1 else "s", HostView.span(float(row.get("run_seconds", 0))), money(float(row.get("cost_usd", 0.0)))]
		out += "\nLast: %s." % ("running now" if bool(row.get("running_now", false)) else HostView.ago(now - float(row.get("last_stop", now))))
	out += "\nMachine %s in %s" % [str(row.get("machine", "")) if str(row.get("machine", "")) != "" else "(none)", str(row.get("app", ""))]
	return out


## The tiles above the inventory: running, paused, destroyed and kept, and what Fly.io holds now.
static func tiles(inv: Dictionary) -> Array:
	var rows: Array = inv.get("sandboxes", [])
	var running := []
	var paused := []
	var destroyed := 0
	var cost := 0.0
	for r in rows:
		cost += float(r.get("cost_usd", 0.0))
		var lv := str(state_of(r)["level"])
		if lv == "ok":
			running.append(name_of(r))
		elif lv == "off":
			destroyed += 1
		else:
			paused.append(name_of(r))
	var fly: Dictionary = inv.get("at_fly", {})
	var known := int(fly.get("unknown_here", 0))
	var at_fly := {"id": "fly", "label": "At Fly.io now", "value": str(int(fly.get("machines", 0))), "level": "ok",
		"note": "machine%s · none that Agent Manager does not know" % ("" if int(fly.get("machines", 0)) == 1 else "s")}
	if not bool(fly.get("reachable", false)):
		at_fly = {"id": "fly", "label": "At Fly.io now", "value": "?", "note": "Fly.io was not reached: what is listed is what was last known", "level": "warn"}
	elif known > 0:
		at_fly["note"] = "machine%s · %d that Agent Manager does not know: see below" % ["" if int(fly.get("machines", 0)) == 1 else "s", known]
		at_fly["level"] = "warn"
	return [
		{"id": "running", "label": "Running now", "value": str(running.size()), "note": "none: nothing is billed for running" if running.is_empty() else ", ".join(running.slice(0, 3)), "level": "ok"},
		{"id": "paused", "label": "Paused", "value": str(paused.size()), "note": "none" if paused.is_empty() else ", ".join(paused.slice(0, 3)) + " · only their disk is billed", "level": "ok"},
		{"id": "destroyed", "label": "Destroyed, kept here", "value": str(destroyed), "note": "%s measured in all, the destroyed ones included" % money(cost), "level": "ok"},
		at_fly,
	]


# ---------------------------------------------------------------- tunnels and ports
## 0, 850 B/s, 1.2 kB/s, 3.4 MB/s.
static func rate(per_second: float) -> String:
	if per_second < 0.5:
		return "0"
	if per_second < 1000.0:
		return "%d B/s" % int(round(per_second))
	if per_second < 1000000.0:
		return "%.1f kB/s" % (per_second / 1000.0)
	return "%.1f MB/s" % (per_second / 1000000.0)


## 0, 512 B, 12 kB, 3.4 MB, 1.2 GB.
static func amount(bytes: float) -> String:
	if bytes < 1.0:
		return "0"
	if bytes < 1000.0:
		return "%d B" % int(bytes)
	if bytes < 1000000.0:
		return "%d kB" % int(round(bytes / 1000.0))
	if bytes < 1000000000.0:
		return "%.1f MB" % (bytes / 1000000.0)
	return "%.1f GB" % (bytes / 1000000000.0)


## The connection to a sandbox in words, with its level.
static func link_of(tunnel: Dictionary) -> Dictionary:
	var st := str(tunnel.get("state", "closed"))
	if st == "open":
		var n: int = tunnel.get("ports", []).size()
		return {"text": "connected · %s" % ("no port brought here yet" if n == 0 else "%d port%s on your localhost" % [n, "" if n == 1 else "s"]), "level": "ok"}
	if st == "lost":
		return {"text": "the connection was lost: connect again", "level": "bad"}
	return {"text": "not connected: its ports are not reachable from here", "level": "off"}


## Every port worth a line: what listens in the sandbox, and what is brought here (a port brought here whose program
## stopped listening stays listed: it is still open on this side). Brought ones first, then by number.
## Each: {"port", "program", "inside", "open", "state", "address", "local", "sent", "received", "sent_rate", "received_rate", "open_now"}.
static func port_rows(tunnel: Dictionary) -> Array:
	var by := {}
	for l in tunnel.get("listening", []):
		by[int(l["port"])] = {"port": int(l["port"]), "program": str(l.get("program", "")), "inside": bool(l.get("inside", false)), "listening": true,
			"open": false, "state": "", "address": "", "local": 0, "sent": 0.0, "received": 0.0, "sent_rate": 0.0, "received_rate": 0.0, "open_now": 0, "label": ""}
	for p in tunnel.get("ports", []):
		var n := int(p.get("remote_port", 0))
		var row: Dictionary = by.get(n, {"port": n, "program": "", "inside": true, "listening": false})
		row.merge({"open": true, "state": str(p.get("state", "")), "address": str(p.get("address", "")), "local": int(p.get("port", 0)),
			"sent": float(p.get("sent", 0)), "received": float(p.get("received", 0)), "sent_rate": float(p.get("sent_rate", 0.0)),
			"received_rate": float(p.get("received_rate", 0.0)), "open_now": int(p.get("open_now", 0)), "label": str(p.get("label", ""))}, true)
		by[n] = row
	var out := by.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["port"] < b["port"] if a["open"] == b["open"] else a["open"])
	return out


## A port's line in words.
static func port_words(row: Dictionary) -> String:
	var what := str(row["program"]) if str(row["program"]) != "" else "a program"
	if not row["open"]:
		return "%s listens on %d%s" % [what, row["port"], " (inside the sandbox only)" if row["inside"] else ""]
	var out := "%s on %d is on your localhost:%d" % [what, row["port"], row["local"]]
	if str(row["state"]) == "paused":
		out += " · paused: it carries nothing"
	if not bool(row.get("listening", true)):
		out += " · nothing listens there any more"
	return out


## How the sandbox is doing, in three short figures.
static func health_words(h: Dictionary) -> Array:
	if h.is_empty():
		return []
	var out := []
	if float(h.get("memory_total", 0)) > 0.0:
		out.append(["Memory", "%s of %s" % [HostView.mem(float(h["memory_used"])), HostView.mem(float(h["memory_total"]))], float(h["memory_used"]) / float(h["memory_total"]) > 0.92])
	out.append(["Load", "%.2f" % float(h.get("load", 0.0)), false])
	if float(h.get("disk_total", 0)) > 0.0:
		out.append(["Disk free", HostView.mem(float(h["disk_free"])), float(h["disk_free"]) / float(h["disk_total"]) < 0.1])
	out.append(["Round trip", "%d ms" % int(h.get("round_trip_ms", 0)), int(h.get("round_trip_ms", 0)) > 800])
	return out

