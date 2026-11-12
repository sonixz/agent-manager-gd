extends RefCounted
## The Repos page, its words and its order: what each column of a repository's line says, which lines come first,
## the sentence above them, what the top bar's button says. Nothing here draws or asks anything, so the headless
## cases (tools_setup_check.gd) check every line. The page itself is in main.gd.
##
## Loaded with preload, not by a class name (see setup_probe.gd).

const HostView := preload("res://scripts/host_view.gd")

## The columns after the name, with their width. In a narrow window they leave in the order of `GIVE_UP`: the host
## last, because it is what tells a GitHub repository from an Azure DevOps one.
const COLUMNS := [["host", "Host", 116.0], ["key", "Key", 220.0], ["opens", "The key opens", 168.0], ["folder", "Folder", 250.0],
	["sessions", "Sessions", 116.0], ["used", "Started, 14 days", 116.0]]
const GIVE_UP := ["used", "sessions", "opens", "host"]
const NAME_MIN := 170.0
const FIXED := 26.0 + 118.0 + 40.0   # the mark, « New session », the arrow

const ADDRESS_HINT := "git@github.com:owner/repo.git   ·   Azure DevOps: git@ssh.dev.azure.com:v3/organization/project/repository"


static func host_label(r: Dictionary) -> String:
	var kind := str(r.get("host_kind", ""))
	if kind == "github":
		return "GitHub"
	if kind == "azure":
		return "Azure DevOps"
	return str(r.get("host", ""))


## What an address typed in the form will be, said before it is added: the host it names and what its key will open.
static func address_hint(text: String) -> String:
	var t := text.strip_edges().to_lower()
	if t == "":
		return ""
	if t.begins_with("http://") or t.begins_with("https://"):
		return "That is the web address: the SSH one is needed (Clone › SSH on the repository's page). Add it and it is worked out for you where it can be."
	if t.contains("ssh.dev.azure.com") or t.contains("vs-ssh.visualstudio.com"):
		return "Azure DevOps: an RSA key is made for it. It goes on your profile (User settings › SSH public keys) and opens everything your account reaches there, not this repository alone."
	if t.contains("github.com"):
		return "GitHub: a deploy key is made for this repository only. Tick « Allow write access » when you add it, so agents can push their branch."
	return "Another SSH git host: an ed25519 key is made for it; what it opens is that host's rule."


## The SSH address the engine proposes in its refusal of a web address, or "".
static func proposed_address(error: String) -> String:
	var at := error.find("not https: ")
	if at < 0:
		return ""
	var rest := error.substr(at + 11)
	var end := rest.find(". The key")
	rest = rest.substr(0, end) if end >= 0 else rest
	rest = rest.get_slice(" (", 0).strip_edges()
	return rest if rest.begins_with("git@") and not rest.contains("owner/repo") else ""


## ok, warn or bad: what sorts the lines and marks them.
static func level(r: Dictionary) -> String:
	var f: Dictionary = r.get("folder", {})
	if str(r.get("status", "")) == "failed" or str(f.get("origin_state", "")) == "other":
		return "bad"
	if str(r.get("status", "")) != "connected" or str(f.get("origin_state", "")) == "missing" or (bool(f.get("read", false)) and str(f.get("path", "")) != "" and not bool(f.get("exists", true))):
		return "warn"
	return "ok"


static func mark(lv: String) -> String:
	return {"ok": "●", "warn": "!", "bad": "✗"}.get(lv, "●")


## The key's state and how old that knowledge is.
static func key_cell(r: Dictionary, now: float) -> Dictionary:
	var st := str(r.get("status", ""))
	if r.get("busy", []).has("key"):
		return {"text": "checking…", "level": "ok" if st == "connected" else "warn"}
	if st == "connected":
		var at := float(r.get("checked_at", 0.0))
		return {"text": "works" + ((" · checked " + HostView.ago(now - at)) if at > 0.0 else ""), "level": "ok"}
	if st == "failed":
		return {"text": "does not work", "level": "bad"}
	return {"text": "waits to be added", "level": "warn"}


## What the key opens on its host: the difference between GitHub and Azure DevOps, said on every line.
static func opens_cell(r: Dictionary) -> String:
	var scope := str(r.get("key_scope", ""))
	if scope == "repository":
		return "this repository only"
	if scope == "account":
		return "your whole account"
	return "as its host decides"


## Whose folder it is, its branch and what waits in it.
static func folder_cell(r: Dictionary) -> Dictionary:
	var f: Dictionary = r.get("folder", {})
	if str(f.get("path", "")) == "":
		return {"text": "cloned on first use", "level": "ok"}
	var who := "its copy" if bool(f.get("managed", false)) else "yours"
	if not bool(f.get("read", false)):
		return {"text": who + (" · reading…" if bool(f.get("git", false)) else ""), "level": "ok"}
	if not bool(f.get("exists", false)):
		return {"text": "the folder is gone", "level": "warn"}
	if not bool(f.get("git", false)):
		return {"text": who + " · empty, cloned on first use", "level": "ok"}
	var o := str(f.get("origin_state", ""))
	if o == "other":
		return {"text": who + " · another repository's folder", "level": "bad"}
	if o == "missing":
		return {"text": who + " · no remote yet", "level": "warn"}
	var bits := [who, str(f.get("branch", "")) if str(f.get("branch", "")) != "" else "no branch"]
	var move := ""
	if int(f.get("ahead", 0)) > 0:
		move += "↑%d" % int(f["ahead"])
	if int(f.get("behind", 0)) > 0:
		move += (" " if move != "" else "") + "↓%d" % int(f["behind"])
	if move != "":
		bits.append(move)
	if int(f.get("changed", 0)) > 0:
		bits.append("%d changed" % int(f["changed"]))
	return {"text": " · ".join(bits), "level": "ok"}


## The same, in a sentence, for the tooltip: the arrows are said in words.
static func folder_tip(r: Dictionary) -> String:
	var f: Dictionary = r.get("folder", {})
	if not bool(f.get("read", false)) or not bool(f.get("git", false)):
		return str(f.get("path", ""))
	var out := str(f.get("path", ""))
	if int(f.get("ahead", 0)) > 0:
		out += "\n%d commit%s not pushed" % [int(f["ahead"]), "" if int(f["ahead"]) == 1 else "s"]
	if int(f.get("behind", 0)) > 0:
		out += "\n%d commit%s behind what was last fetched" % [int(f["behind"]), "" if int(f["behind"]) == 1 else "s"]
	if int(f.get("changed", 0)) > 0:
		out += "\n%d file%s changed or new, not committed" % [int(f["changed"]), "" if int(f["changed"]) == 1 else "s"]
	if str(f.get("upstream", "")) == "" and str(f.get("branch", "")) != "":
		out += "\nThis branch follows no remote branch."
	return out + "\nRead from the disk: nothing is fetched."


## How many of its sessions run now. `states` is the app's own list: session id -> its state.
static func sessions_cell(r: Dictionary, states: Dictionary) -> String:
	var running := 0
	var open := 0
	for s in r.get("sessions", []):
		if int(s.get("archived", 0)) == 1:
			continue
		open += 1
		if str(states.get(str(s["id"]), "")) == "running":
			running += 1
	if running > 0:
		return "%d running" % running
	return "–" if open == 0 else "%d, none running" % open


static func used_cell(r: Dictionary, now: float) -> String:
	var at := float(r.get("last_used", 0.0))
	return "never" if at <= 0.0 else HostView.ago(now - at)


## The key in one line, for the unfolded part: its kind, its print, its age; and that Azure DevOps keys expire.
static func key_line(r: Dictionary, now: float) -> String:
	var kind := "RSA 3072" if str(r.get("key_type", "")) == "rsa" else "ed25519"
	var made := float(r.get("key_made", 0.0))
	var out := "%s · %s" % [kind, str(r.get("fingerprint", ""))]
	if made > 0.0:
		out += " · made " + HostView.ago(now - made)
	if str(r.get("host_kind", "")) == "azure":
		out += " · Azure DevOps keys expire: it warns you by e-mail seven days before"
	return out


## Where to add the public key, by host: the button's words and what to do once there.
static func add_key_help(r: Dictionary) -> Dictionary:
	var kind := str(r.get("host_kind", ""))
	if kind == "github":
		return {"button": "Open GitHub's Deploy keys page", "then": "Paste the key, tick « Allow write access » so agents can push their branch, then Check."}
	if kind == "azure":
		return {"button": "Open Azure DevOps", "then": "There: User settings (the icon beside your picture) › SSH public keys › New Key. Paste the key, then Check. It opens everything your account reaches: to keep agents to chosen repositories, add it to an account made for them."}
	return {"button": "", "then": "Add the key on the repository's host, where it keeps SSH keys, then Check."}


## The lines in their order: what needs a hand first, then by name.
static func order(repos: Array) -> Array:
	var out := repos.duplicate()
	var rank := {"bad": 0, "warn": 1, "ok": 2}
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = rank[level(a)]
		var rb: int = rank[level(b)]
		return ra < rb if ra != rb else str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0)
	return out


## One sentence above the lines.
static func summary(repos: Array) -> String:
	if repos.is_empty():
		return "No repository yet."
	var n := {"connected": 0, "waiting": 0, "failed": 0}
	for r in repos:
		var st := str(r.get("status", "waiting"))
		n[st if n.has(st) else "waiting"] += 1
	var bits := []
	if n["connected"] > 0:
		bits.append("%d connected" % n["connected"])
	if n["waiting"] > 0:
		bits.append("1 waits for its key" if n["waiting"] == 1 else "%d wait for their keys" % n["waiting"])
	if n["failed"] > 0:
		bits.append("%d with a key that does not work" % n["failed"])
	return "%d repositor%s: %s" % [repos.size(), "y" if repos.size() == 1 else "ies", " · ".join(bits)]


## Which columns fit in `width`, and the room left for the name. The ones that leave say so in the line's tooltip.
static func fit(width: float) -> Dictionary:
	var shown := []
	for c in COLUMNS:
		shown.append(str(c[0]))
	var need := func() -> float:
		var w := FIXED + NAME_MIN
		for c in COLUMNS:
			if shown.has(str(c[0])):
				w += float(c[2])
		return w
	for id in GIVE_UP:
		if need.call() <= width:
			break
		shown.erase(id)
	return {"shown": shown, "name": maxf(NAME_MIN, minf(320.0, width - (need.call() - NAME_MIN)))}


## The top bar's « Repos » button: a mark when a repository needs a hand, and which ones in its tooltip.
static func button(repos: Array) -> Dictionary:
	var worst := "ok"
	var why := []
	for r in order(repos):
		var lv := level(r)
		if lv == "ok":
			continue
		if lv == "bad" or worst == "ok":
			worst = lv if worst != "bad" else worst
		why.append("%s %s: %s" % [mark(lv), str(r.get("name", "")), str(key_cell(r, 0.0)["text"]) if str(r.get("status", "")) != "connected" else str(folder_cell(r)["text"])])
	var tip := "Connected repositories and their keys. " + summary(repos)
	for w in why:
		tip += "\n" + str(w)
	return {"level": worst, "mark": "" if worst == "ok" else mark(worst), "tip": tip}


# ---------------------------------------------------------------- what the drawn pieces show
## A repository's open sessions as dots, the running ones first. `by_id` is the app's own list: session id -> the
## session as the app knows it now (its state, what it is doing). An archived session has no dot.
static func session_dots(r: Dictionary, by_id: Dictionary) -> Array:
	var running := []
	var others := []
	for s in r.get("sessions", []):
		if int(s.get("archived", 0)) == 1:
			continue
		var live: Dictionary = by_id.get(str(s["id"]), {})
		var on := str(live.get("state", "")) == "running"
		var dot := {"id": str(s["id"]), "name": str(s.get("name", "")), "running": on, "activity": str(live.get("activity", "")) if on else "off"}
		if on:
			running.append(dot)
		else:
			others.append(dot)
	return running + others


## How many sessions were started on it in each of the last `days` spans of 24 hours, the latest last.
static func started_days(r: Dictionary, now: float, days := 14) -> Array:
	var counts := []
	counts.resize(days)
	counts.fill(0)
	for s in r.get("sessions", []):
		var d := int(floor((now - float(s.get("created", 0.0))) / 86400.0))
		if d < 0:
			d = 0  # a clock set back a little: it is today
		if d < days:
			counts[days - 1 - d] += 1
	return counts


## How fresh the key's last check is: 1 just checked, 0 at ten minutes (when the page checks it again) or never.
static func freshness(r: Dictionary, now: float) -> float:
	var at := float(r.get("checked_at", 0.0))
	if at <= 0.0 or str(r.get("status", "")) != "connected":
		return 0.0
	return clampf(1.0 - (now - at) / 600.0, 0.0, 1.0)


## The figures above the lines, one tile each: label, value, a sentence, a level.
static func tiles(repos: Array, by_id: Dictionary) -> Array:
	var connected := 0
	var hand := []
	var worst := "ok"
	var hosts := {}
	var running := 0
	var busy_repos := 0
	for r in repos:
		if str(r.get("status", "")) == "connected":
			connected += 1
		var lv := level(r)
		if lv != "ok":
			hand.append(str(r.get("name", "")))
			worst = "bad" if lv == "bad" or worst == "bad" else "warn"
		var h := host_label(r)
		hosts[h] = int(hosts.get(h, 0)) + 1
		var n := session_dots(r, by_id).filter(func(d: Dictionary) -> bool: return d["running"]).size()
		running += n
		if n > 0:
			busy_repos += 1
	var where := []
	for h in hosts:
		where.append("%s %d" % [h, hosts[h]])
	return [
		{"id": "connected", "label": "Keys that work", "value": str(connected), "note": "of %d repositor%s" % [repos.size(), "y" if repos.size() == 1 else "ies"], "level": "ok"},
		{"id": "hand", "label": "Need a hand", "value": str(hand.size()), "note": "none" if hand.is_empty() else ", ".join(hand.slice(0, 3)) + (" and others" if hand.size() > 3 else ""), "level": worst},
		{"id": "running", "label": "Sessions running", "value": str(running), "note": "on no repository" if busy_repos == 0 else "on %d repositor%s" % [busy_repos, "y" if busy_repos == 1 else "ies"], "level": "ok"},
		{"id": "hosts", "label": "Hosts", "value": str(hosts.size()), "note": " · ".join(where), "level": "ok"},
	]


# ---------------------------------------------------------------- the map of the branches
const METRO_SPAN := 24     # the base line shows that many of its latest commits; a branch that left before is drawn at its start
const METRO_AHEAD := 14    # a branch shows that many stations of its own; past it, a figure says how many more
const METRO_LINES := 8     # as many hues as the engine room has: past them, the lines are grey

## What the map draws, from the engine's answer (/repos/<id>/branches) and the app's own sessions (id -> session).
## The lines worth a look: a branch that has commits of its own, or a folder (a worktree), or an open session.
## A branch merged and left with none of these is only counted. The order: the ones with a running session, then
## the ones with a folder, then by their last commit. Each line keeps its place's hue.
## Gives {"read", "why", "base": {...}, "lines": [...], "span", "merged", "more"}.
static func metro(data: Dictionary, by_id: Dictionary) -> Dictionary:
	if not bool(data.get("read", false)) or data.get("base") == null:
		return {"read": false, "why": str(data.get("why", "This repository has no branch yet.")), "lines": [], "span": 0, "merged": 0, "more": 0}
	var dots := func(b: Dictionary) -> Array:
		return session_dots({"sessions": b.get("sessions", [])}, by_id)
	var lines := []
	var merged := 0
	var far := 1
	for b in data.get("branches", []):
		var d: Array = dots.call(b)
		if int(b.get("ahead", 0)) == 0 and str(b.get("worktree", "")) == "" and d.is_empty():
			merged += 1
			continue
		var running: bool = d.any(func(x: Dictionary) -> bool: return x["running"])
		lines.append({"name": str(b["name"]), "ahead": int(b.get("ahead", 0)), "behind": int(b.get("behind", 0)), "date": float(b.get("date", 0.0)),
			"subject": str(b.get("subject", "")), "worktree": str(b.get("worktree", "")), "upstream": str(b.get("upstream", "")),
			"dots": d, "rank": 0 if running else (1 if str(b.get("worktree", "")) != "" else 2)})
		far = maxi(far, mini(int(b.get("behind", 0)), METRO_SPAN))
	lines.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["rank"] < b["rank"] if a["rank"] != b["rank"] else a["date"] > b["date"])
	for i in lines.size():
		lines[i]["slot"] = i if i < METRO_LINES else -1
	var base: Dictionary = data["base"]
	return {"read": true, "why": "", "base": {"name": str(base["name"]), "subject": str(base.get("subject", "")), "date": float(base.get("date", 0.0)),
			"worktree": str(base.get("worktree", "")), "dots": dots.call(base)},
		"lines": lines, "span": far, "merged": merged, "more": int(data.get("more", 0))}


## A line of the map in words, for the pointer: what it is, what it holds, where it is checked out, who works there.
static func metro_tip(line: Dictionary, base_name: String, now: float) -> String:
	var out := str(line["name"])
	var ahead := int(line.get("ahead", 0))
	var behind := int(line.get("behind", 0))
	out += "\n%s" % ("no commit of its own yet" if ahead == 0 else "%d commit%s of its own" % [ahead, "" if ahead == 1 else "s"])
	if behind > 0:
		out += " · %s made %d since it left" % [base_name, behind]
	if str(line.get("subject", "")) != "":
		out += "\nLast: %s%s" % [str(line["subject"]), (" (" + HostView.ago(now - float(line["date"])) + ")") if float(line.get("date", 0.0)) > 0.0 else ""]
	if str(line.get("worktree", "")) != "":
		out += "\nIts folder: " + str(line["worktree"])
	for d in line.get("dots", []):
		out += "\n● %s: %s" % [d["name"], "not running" if not d["running"] else (str(d["activity"]) if str(d["activity"]) != "" else "running")]
	return out

