extends RefCounted
## 🔌 MCP, in words and sums (Loop 49a). What each drawn piece shows is worked out here, where the headless cases check
## it; the drawing is in scripts/mcp_widgets.gd.
##
## Owner, 2026-11-15: « J'aimerais ça être capable de le brancher en MCP. C'est un MCP HTTPS sans authentification.
## J'aimerais être capable de l'intégrer et de partir une session avec. Puis même que ça soit scalable ».
## Loaded with preload, not by a class name (see setup_probe.gd).

const NAME_RE := "^[a-z0-9][a-z0-9_-]{0,39}$"
const RESERVED := ["agent-manager", "second-brain"]
const LOCAL := ["localhost", "127.0.0.1", "[::1]"]


## What a name typed in the form will be: "" when it is good, else why not (the engine says the same).
static func name_problem(name: String) -> String:
	if name == "":
		return "a short name, like loop0: agents call its tools mcp__<name>__…"
	var re := RegEx.new()
	re.compile(NAME_RE)
	if re.search(name) == null:
		return "lowercase letters, digits, - and _ only, 40 at most"
	if name in RESERVED:
		return "« %s » is Agent Manager's own server: pick another name" % name
	return ""


## A name typed freely, made into the form a server's name takes (« Loop 0 » → loop-0).
static func tidy_name(text: String) -> String:
	var out := ""
	for ch in text.strip_edges().to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
		elif ch == " " or ch == ".":
			out += "-"
	return out.left(40)


## The second box holds an address (a server over HTTPS) or a command (a server started on this computer).
static func is_address(text: String) -> bool:
	var t := text.strip_edges().to_lower()
	return t.begins_with("https://") or t.begins_with("http://")


static func host_of(url: String) -> String:
	var rest := url.strip_edges().split("://", true, 1)
	if rest.size() < 2:
		return ""
	var h := rest[1].split("/", true, 1)[0]
	if h.begins_with("["):
		return h.split("]")[0] + "]"
	return h.split(":")[0].to_lower()


## "" when the address can be added, else why not (the engine says the same).
static func address_problem(text: String) -> String:
	var t := text.strip_edges()
	if t == "":
		return "its address (https://…/mcp), or the command that starts it"
	if not is_address(t):
		return ""   # a command
	if host_of(t) == "":
		return "an address like https://example.com/mcp"
	if "@" in t.split("://", true, 1)[1].split("/", true, 1)[0]:
		return "no login in the address: Agent Manager keeps no password in its list"
	if t.to_lower().begins_with("http://") and not (host_of(t) in LOCAL):
		return "http:// only for a server on this computer; a server elsewhere needs https://"
	return ""


## The sessions a server goes to: [{id, name, running}], running ones first. « every » ones count every agent session.
static func users(server: Dictionary, sessions: Array) -> Array:
	var name := str(server.get("name", ""))
	var out := []
	for s in sessions:
		if not (str(s.get("tool", "")) in ["claude", "codex"]):
			continue
		if str(s.get("cwd", "")) == "/work" and not bool(server.get("remote", false)):
			continue   # Loop 49b: a cloud machine gets only the servers on the internet
		if bool(server.get("everywhere", false)) or name in (s.get("mcps", []) as Array):
			out.append({"id": str(s["id"]), "name": str(s.get("name", "")), "running": str(s.get("state", "")) == "running"})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"] if a["running"] == b["running"] else a["running"])
	return out


## The state of its last test: "ok", "bad" or "never".
static func state(server: Variant) -> String:
	var t: Variant = (server as Dictionary).get("last_test")
	if t == null or not (t is Dictionary):
		return "never"
	return "ok" if bool((t as Dictionary).get("ok", false)) else "bad"


## Its line under the card, in plain words.
static func words(server: Dictionary, now: float) -> String:
	var where := ("on the internet: what an agent asks it leaves this computer" if bool(server.get("remote", false))
		else ("on this computer" if str(server.get("kind", "")) == "http" else "started on this computer by its command"))
	var t: Variant = server.get("last_test")
	var tested := "never tested"
	if t is Dictionary:
		var ago := _ago(now - float((t as Dictionary).get("at", now)))
		if bool(t.get("ok", false)):
			tested = "answered %s ago in %d ms: %s" % [ago, int(t.get("ms", 0)), offers(t)]
		else:
			tested = "did not answer %s ago: %s" % [ago, str(t.get("error", ""))]
	return "%s · %s" % [where, tested]


static func offers(t: Dictionary) -> String:
	var nt := (t.get("tools", []) as Array).size()
	var np := (t.get("prompts", []) as Array).size()
	return "%d tool%s, %d prompt%s" % [nt, "" if nt == 1 else "s", np, "" if np == 1 else "s"]


## The first message for « Start a session with it »: the server's own prompt to begin, when it has one.
## Claude Code calls an MCP prompt as /mcp__<server>__<prompt>.
static func first_prompt(server: Dictionary, idea: String) -> String:
	var t: Variant = server.get("last_test")
	if not (t is Dictionary):
		return ""
	var names := (t.get("prompts", []) as Array).map(func(p: Dictionary) -> String: return str(p.get("name", "")))
	for pick in ["start", "begin", "new"]:
		if pick in names:
			var cmd := "/mcp__%s__%s" % [str(server["name"]), pick]
			return cmd + (" \"%s\"" % idea.replace("\"", "'") if idea.strip_edges() != "" else "")
	return ""


## The four tiles at the top of the page.
static func tiles(servers: Array, sessions: Array) -> Array:
	var tools := 0
	var failing := 0
	var never := 0
	var remote := 0
	var using := {}
	for s in servers:
		match state(s):
			"ok":
				tools += (s["last_test"].get("tools", []) as Array).size()
			"bad":
				failing += 1
			_:
				never += 1
		if bool(s.get("remote", false)):
			remote += 1
		for u in users(s, sessions):
			using[u["id"]] = true
	return [
		{"label": "Servers", "value": str(servers.size()), "note": ("%d on the internet" % remote) if remote > 0 else "none on the internet", "level": "ok"},
		{"label": "Tools offered", "value": str(tools), "note": "by those that answered", "level": "ok"},
		{"label": "Agent sessions using one", "value": str(using.size()), "note": "ticked, or every session", "level": "ok"},
		{"label": "Last test", "value": str(failing) if failing > 0 else ("✓" if never == 0 and servers.size() > 0 else "—"),
			"note": ("did not answer" if failing > 0 else ("%d never tested" % never if never > 0 else ("all answered" if servers.size() > 0 else "nothing to test"))),
			"level": "bad" if failing > 0 else ("warn" if never > 0 else "ok")},
	]


## New session: the words under the boxes. On a cloud machine (Loop 49b) only the servers on the internet go: one on
## this computer (localhost, or a command) is not on the machine.
static func session_words(ticked: Array, servers: Array, cloud := false) -> String:
	var every := servers.filter(func(s: Dictionary) -> bool: return bool(s.get("everywhere", false))).map(func(s: Dictionary) -> String: return str(s["name"]))
	if cloud:
		var remote := {}
		for s in servers:
			remote[str(s["name"])] = bool(s.get("remote", false))
		var all: Array = ticked + every.filter(func(n: String) -> bool: return not (n in ticked))
		var go := all.filter(func(n: String) -> bool: return remote.get(n, false))
		var stay := all.filter(func(n: String) -> bool: return not remote.get(n, false))
		if all.is_empty():
			return "No MCP server of yours: tick one, or add some in ⌁ MCP. On a cloud machine, those on the internet go."
		var w := ("On the cloud machine it gets " + ", ".join(go)) if not go.is_empty() else "None of these reaches a cloud machine"
		if not stay.is_empty():
			w += "; " + ", ".join(stay) + (" stays" if stay.size() == 1 else " stay") + " on this computer (not on the machine)"
		return w + "."
	var parts := []
	if not ticked.is_empty():
		parts.append("This session gets " + ", ".join(ticked))
	if not every.is_empty():
		parts.append(("every agent session gets " if ticked.is_empty() else "and every agent session gets ") + ", ".join(every))
	if parts.is_empty():
		return "No MCP server of yours: tick one, or add some in 🔌 MCP."
	return "; ".join(parts) + ". Claude Code and Codex only."


static func _ago(sec: float) -> String:
	sec = maxf(sec, 0.0)   # the clock may step back (WSL)
	if sec < 60.0:
		return "%d s" % int(sec)
	if sec < 3600.0:
		return "%d min" % int(sec / 60.0)
	if sec < 86400.0:
		return "%d h" % int(sec / 3600.0)
	return "%d d" % int(sec / 86400.0)
