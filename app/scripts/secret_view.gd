extends RefCounted
## The secrets vault's page, in words and sums (Loop 39). What each drawn piece shows is worked out here, where the
## headless cases check it; the drawing is in scripts/secret_widgets.gd.
##
## Owner, 2026-11-12: a key given through dotenvx « est enregistrée dans le WSL… accessible à travers WSL pour tous
## les agents ». Here a secret is kept encrypted and goes only to the sessions it is given to.
## Loaded with preload, not by a class name (see setup_probe.gd).

const DAY := 86400.0
const NAME_RE := "^[A-Z][A-Z0-9_]{1,63}$"
const RESERVED := ["PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "PWD", "TMUX", "TMUX_PANE", "LD_PRELOAD", "LD_LIBRARY_PATH",
	"PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "GIT_SSH_COMMAND", "SSH_AUTH_SOCK", "DISPLAY", "BASH_ENV", "ENV"]


## What a name typed in the form will be: "" when it is good, else why not (the engine says the same).
static func name_problem(name: String) -> String:
	if name == "":
		return "a name like ELEVENLABS_API_KEY"
	var re := RegEx.new()
	re.compile(NAME_RE)
	if re.search(name) == null:
		return "capitals, digits and _ only, starting with a letter (like ELEVENLABS_API_KEY)"
	if name in RESERVED or name.begins_with("AGMGD_"):
		return "%s would change how programs run: pick another name" % name
	return ""


## A name typed freely, made into the form a secret's name takes (« elevenlabs api key » → ELEVENLABS_API_KEY).
static func tidy_name(text: String) -> String:
	var out := ""
	for ch in text.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_":
			out += ch
		elif ch == " " or ch == "-" or ch == ".":
			out += "_"
	return out


## The sessions given a secret: [{id, name, running}], the running ones first.
static func holders(name: String, sessions: Array) -> Array:
	var out := []
	for s in sessions:
		if name in (s.get("secrets", []) as Array):
			out.append({"id": str(s["id"]), "name": str(s.get("name", "")), "running": str(s.get("state", "")) == "running"})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"] if a["running"] == b["running"] else a["running"])
	return out


## How many times a secret was given, day by day, the last `n` days, today last (from the journal's « given » lines).
static func days(journal: Array, name: String, now: float, n := 14) -> Array:
	var out := []
	out.resize(n)
	out.fill(0)
	for e in journal:
		if str(e.get("name", "")) != name or str(e.get("event", "")) != "given":
			continue
		var age := now - float(e.get("ts", 0.0))
		var back := 0 if age >= -300.0 and age < 0.0 else int(floor(age / DAY))   # a little ahead: the clock stepped back
		if back >= 0 and back < n:
			out[n - 1 - back] += 1
	return out


## The tiles above the secrets: how many are kept and how, how many sessions hold one, how many were given lately.
static func tiles(data: Dictionary, sessions: Array, now: float) -> Array:
	var secrets: Array = data.get("secrets", [])
	var encrypted := str(data.get("protection", "")).begins_with("Windows")
	var holding := {}
	var running := {}
	for x in secrets:
		for h in holders(str(x["name"]), sessions):
			holding[h["id"]] = true
			if h["running"]:
				running[h["id"]] = true
	var lately := 0
	for e in data.get("journal", []):
		var age := now - float(e.get("ts", 0.0))
		if str(e.get("event", "")) == "given" and age >= -300.0 and age < DAY:   # a little ahead: the clock stepped back
			lately += 1
	var never := secrets.filter(func(x: Dictionary) -> bool: return holders(str(x["name"]), sessions).is_empty()).size()
	return [
		{"label": "Secrets kept", "value": str(secrets.size()), "level": "ok" if encrypted or secrets.is_empty() else "warn",
			"note": "encrypted for your Windows user" if encrypted else "not encrypted on this computer: file permissions only"},
		{"label": "Sessions holding one", "value": str(holding.size()), "level": "ok",
			"note": ("%d running" % running.size()) if holding.size() > 0 else "none: no session has any"},
		{"label": "Given, last 24 hours", "value": str(lately), "level": "ok", "note": "each start of a session given one counts"},
		{"label": "Given to no session", "value": str(never), "level": "ok", "note": "kept, not given" if never > 0 else "every secret is in use"},
	]


## A secret's line in words, beside its drawing.
static func words(x: Dictionary, held: Array, now: float) -> String:
	var parts := []
	if held.is_empty():
		parts.append("given to no session")
	else:
		parts.append("given to " + ", ".join(held.map(func(h: Dictionary) -> String: return str(h["name"]))))
	if float(x.get("last_given", 0.0)) > 0.0:
		parts.append("last handed over " + ago(now - float(x["last_given"])))
	if float(x.get("changed_at", 0.0)) > 0.0:
		parts.append("value set " + ago(now - float(x["changed_at"])))
	return " · ".join(parts)


static func ago(seconds: float) -> String:
	var s := maxf(0.0, seconds)   # WSL's wall clock steps back now and then: never a negative age
	if s < 60.0:
		return "just now"
	if s < 3600.0:
		return "%d min ago" % int(s / 60.0)
	if s < DAY:
		return "%d h ago" % int(s / 3600.0)
	return "%d days ago" % int(s / DAY)


## What « New session » says under its secrets' boxes.
static func session_words(names: Array) -> String:
	if names.is_empty():
		return "No secret: this session gets none of the vault's."
	return "Only this session gets %s, in its program's environment; the others do not. The agent can read what it is given." % ", ".join(names)
