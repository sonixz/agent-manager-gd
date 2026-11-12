extends SceneTree
## The checks of the setup ladder (scripts/setup_probe.gd), without a window, an engine or a display:
##   godot --headless --path app --script res://tools_setup_check.gd            every case below; exit 1 when one fails
##   … --script res://tools_setup_check.gd -- argv                              the PowerShell call, to run it by hand
##   … --script res://tools_setup_check.gd -- parse <windows.txt> [doctor.txt]  the ladder read from saved outputs
##   … --script res://tools_setup_check.gd -- real                              the real reading, on this computer
## Two outputs were recorded on a real computer (tools/setup/recorded). The other states (no WSL, no distribution,
## Windows in French…) are written by hand from what the documentation says: they were never seen on a computer.

const Probe := preload("res://scripts/setup_probe.gd")
const View := preload("res://scripts/host_view.gd")
const Repo := preload("res://scripts/repo_view.gd")
const Sbx := preload("res://scripts/sandbox_view.gd")

var failed := 0
var passed := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	match (args[0] if args.size() > 0 else ""):
		"argv":
			print(" ".join(Probe.windows_argv()))
		"parse":
			var f := {"port": 8790, "windows": Probe.parse_windows(FileAccess.get_file_as_string(args[1]))}
			if args.size() > 2:
				f["linux"] = {"code": 0, "found": Probe.parse_programs(FileAccess.get_file_as_string(args[2]))}
			_show(f, false, true)
		"real":
			var p := Probe.new()
			var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
			if p.on_windows and root.length() > 1 and root[1] == ":":
				root = "/mnt/" + root[0].to_lower() + root.substr(2).replace("\\", "/")
			var t0 := Time.get_ticks_msec()
			var f := p.read(root, 8790)
			print("read in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
			print(JSON.stringify(f.get("windows", {})))
			print("(the engine itself is not asked here: its line is what the app would say if it did not answer)")
			_show(f, false, p.on_windows)
			for l in Probe.engine_room(f, {}, p.on_windows):
				print("room   %-24s %s%s" % [l["label"], l["text"], "  (!)" if l["warn"] else ""])
		_:
			_cases()
			_dashboard_cases()
			_repo_cases()
			_sandbox_cases()
			print("%d passed, %d failed" % [passed, failed])
			quit(1 if failed > 0 else 0)
			return
	quit(0)


func _show(f: Dictionary, connected: bool, windows: bool) -> void:
	var rungs := Probe.ladder(f, connected, windows)
	for r in rungs:
		print("%-6s %-24s %s%s" % [r["state"], r["name"], r["note"], ("  → " + str(r["how"])) if str(r["how"]) != "" else ""])
	print(Probe.verdict(rungs))


func check(what: String, ok: bool) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL  " + what)


func _state(rungs: Array, id: String) -> String:
	for r in rungs:
		if r["id"] == id:
			return str(r["state"])
	return "absent"


func _rung(rungs: Array, id: String) -> Dictionary:
	for r in rungs:
		if r["id"] == id:
			return r
	return {}


func _states(rungs: Array) -> String:
	var o := []
	for r in rungs:
		o.append("%s=%s" % [r["id"], r["state"]])
	return " ".join(o)


func _recorded(name: String) -> String:
	return FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../tools/setup/recorded").path_join(name))


## Windows' answer, written by hand: `head` holds the build and the two virtualization lines, then the sections.
func _windows(build: int, virt: bool, hyper: bool, service: bool, sections := "") -> String:
	var tf := func(b: bool) -> String: return "True" if b else "False"  # as PowerShell writes them
	return "#windows 0\nbuild=%d\nvirt_firmware=%s\nhypervisor=%s\nservice=%s\n%s#end 0\n" % [build, tf.call(virt), tf.call(hyper), tf.call(service), sections]


func _cases() -> void:
	var real_w := _recorded("windows-en.txt")
	var real_l := _recorded("doctor.txt")
	check("the two recorded outputs are there", real_w != "" and real_l != "")
	var w := Probe.parse_windows(real_w)
	var found := Probe.parse_programs(real_l)
	var linux := {"code": 0, "found": found}

	# --- the PowerShell call
	var argv := Probe.windows_argv()
	check("the PowerShell call holds no quote and no space in its arguments", not argv.any(func(a: String) -> bool: return a.contains("\"") or a.contains(" ")))
	check("its script comes back whole from base64", Marshalls.base64_to_raw(argv[4]).get_string_from_utf16() == Probe.WINDOWS_SCRIPT)
	check("wsl.exe is only run behind the test of WSL's services", Probe.WINDOWS_SCRIPT.find("if($s -and") < Probe.WINDOWS_SCRIPT.find("& wsl.exe") and Probe.WINDOWS_SCRIPT.count("wsl.exe") == 2)

	# --- recorded: a computer where everything is there
	check("recorded: WSL and its version are read", w.get("wsl", false) and str(w["version"]).begins_with("2."))
	check("recorded: one distribution, the default one, running, on WSL 2", w["names"].size() >= 1 and w["default"] == w["names"][0] and w["running"].has(w["default"]) and w["versions"][w["default"]] == 2)
	var all := Probe.ladder({"port": 8790, "windows": w, "linux": linux}, true, true)
	check("recorded: every rung stands (%s)" % _states(all), all.all(func(r: Dictionary) -> bool: return r["state"] == "ok"))
	check("recorded: the order goes from the ground up", _states(all).begins_with("windows=ok wsl=ok distro=ok python3=ok tmux=ok git=ok ssh=ok engine=ok claude=ok"))
	check("recorded: the verdict", Probe.verdict(all) == "Everything needed is there.")

	# --- the engine does not answer: four different reasons, four different sentences
	var down := {"port": 8790, "windows": w, "linux": linux}
	check("engine: it runs and listens, the app cannot reach it", str(_rung(Probe.ladder(down, false, true), "engine")["note"]).contains("cannot reach it from Windows"))
	var f2: Dictionary = found.duplicate(true)
	f2["engine-port"] = {"path": "", "version": ""}
	check("engine: its process is there, the port is closed", str(_rung(Probe.ladder({"port": 8790, "windows": w, "linux": {"code": 0, "found": f2}}, false, true), "engine")["note"]).contains("starting, or stuck"))
	var f3: Dictionary = found.duplicate(true)
	f3["engine-process"] = {"path": "", "version": ""}
	check("engine: another program holds the port", str(_rung(Probe.ladder({"port": 8790, "windows": w, "linux": {"code": 0, "found": f3}}, false, true), "engine")["note"]).contains("Another program holds port 8790"))
	var f4: Dictionary = f3.duplicate(true)
	f4["engine-port"] = {"path": "", "version": ""}
	var not_running := Probe.ladder({"port": 8790, "windows": w, "linux": {"code": 0, "found": f4}}, false, true)
	check("engine: it is not running", str(_rung(not_running, "engine")["note"]) == "It is not running." and _state(not_running, "engine") == "no")
	check("engine down: the verdict points at the first ✗, and speaks of no · line when there is none", Probe.verdict(not_running) == "Start with the first ✗.")

	# --- written by hand: no WSL at all (its services are not there: wsl.exe is never run)
	var no_wsl := Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_windows(26100, true, false, false))}, false, true)
	check("no WSL: it stops at WSL (%s)" % _states(no_wsl), _states(no_wsl).begins_with("windows=ok wsl=no distro=after python3=after tmux=after git=after ssh=after engine=after claude=after"))
	check("no WSL: the way to install it is said", str(_rung(no_wsl, "wsl")["how"]).contains("wsl --install"))
	check("no WSL: the verdict says why the lines under it are marked ·", Probe.verdict(no_wsl).contains("marked ·"))

	# --- written by hand: WSL without a distribution (wsl -l answers with a sentence and an error code)
	var none := "#version 0\nWSL version: 2.6.3.0\n#names -1\nWindows Subsystem for Linux has no installed distributions.\n#table -1\nWindows Subsystem for Linux has no installed distributions.\n#running -1\nThere are no running distributions.\n"
	var no_distro := Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_windows(26100, true, true, true, none))}, false, true)
	check("no distribution: it stops there (%s)" % _states(no_distro), _states(no_distro).begins_with("windows=ok wsl=ok distro=no python3=after") and str(_rung(no_distro, "distro")["how"]).contains("wsl --install -d Ubuntu-24.04"))
	# the same sentence with exit code 0 must not become a distribution's name
	check("a sentence is never a name", Probe.parse_windows(_windows(26100, true, true, true, none.replace("#names -1", "#names 0")))["names"].is_empty())

	# --- written by hand: Docker Desktop's distribution is the default one
	var docker := "#version 0\nWSL version: 2.6.3.0\n#names 0\ndocker-desktop\nUbuntu\nUbuntu-24.04\n#table 0\n  NAME              STATE           VERSION\n* docker-desktop    Running         2\n  Ubuntu            Stopped         1\n  Ubuntu-24.04      Stopped         2\n#running 0\ndocker-desktop\n"
	var dw := Probe.parse_windows(_windows(26100, true, true, true, docker))
	check("names that begin alike keep their own line", dw["versions"] == {"docker-desktop": 2, "Ubuntu": 1, "Ubuntu-24.04": 2} and dw["default"] == "docker-desktop")
	var by_docker := Probe.ladder({"port": 8790, "windows": dw}, false, true)
	check("Docker's distribution as default: said, with the way out", _state(by_docker, "distro") == "no" and str(_rung(by_docker, "distro")["how"]) == "In PowerShell: wsl --set-default Ubuntu")
	check("Docker's distribution alone is no distribution", str(_rung(Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_windows(26100, true, true, true, "#version 0\nWSL version: 2.6.3.0\n#names 0\ndocker-desktop\n#table 0\n* docker-desktop    Running         2\n#running 0\ndocker-desktop\n"))}, false, true), "distro")["note"]) == "WSL has no Linux distribution yet.")

	# --- written by hand: Windows in French (titles and states translated, the distribution stopped)
	var fr := "#version 0\nVersion WSL : 2.6.3.0\nVersion du noyau : 6.6.87.2-1\n#names 0\nUbuntu-24.04\n#table 0\n  NOM             ÉTAT            VERSION\n* Ubuntu-24.04    Arrêté          2\n#running -1\nAucune distribution n’est en cours d’exécution.\n"
	var fw := Probe.parse_windows(_windows(26200, true, true, true, fr))
	check("French: the same facts", fw["version"] == "2.6.3.0" and fw["default"] == "Ubuntu-24.04" and fw["versions"] == {"Ubuntu-24.04": 2} and fw["running"].is_empty())
	check("French: every rung stands, the distribution stopped or not", Probe.ladder({"port": 8790, "windows": fw, "linux": linux}, true, true).all(func(r: Dictionary) -> bool: return r["state"] == "ok"))

	# --- written by hand: the distribution does not answer; WSL 1; an old Windows; virtualization off; PowerShell silent
	var dead := Probe.ladder({"port": 8790, "windows": w, "linux": {"code": 1, "found": {}}}, false, true)
	check("the distribution does not answer: said on its rung", _state(dead, "distro") == "no" and str(_rung(dead, "distro")["note"]) == "It does not answer (exit 1)." and _state(dead, "tmux") == "after")
	var one := Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_windows(26100, true, true, true, docker.replace("* docker-desktop", "  docker-desktop").replace("  Ubuntu            Stopped", "* Ubuntu            Stopped"))), "linux": linux}, true, true)
	check("WSL 1: it works, with a warning", _state(one, "distro") == "warn" and Probe.verdict(one).contains("deserves a look"))
	var old := Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_windows(18363, true, false, false))}, false, true)
	check("an old Windows: it stops at the first rung (%s)" % _states(old), _states(old).begins_with("windows=no wsl=after distro=after"))
	var off := Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_windows(26100, false, false, false))}, false, true)
	check("virtualization off: said, and no program can change it", _state(off, "windows") == "no" and str(_rung(off, "windows")["how"]).contains("BIOS"))
	check("virtualization read as off while WSL works: WSL is believed", _state(Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_windows(26100, false, false, true, real_w.get_slice("#version", 1).insert(0, "#version").get_slice("#end", 0))), "linux": linux}, true, true), "windows") == "ok")
	check("PowerShell gave nothing: nothing is read from it", Probe.parse_windows("").is_empty() and Probe.parse_windows("#windows 0\nbuild=26100\n").is_empty())
	var silent := Probe.ladder({"port": 8790, "windows": {"unread": true, "wsl": true}, "linux": linux}, true, true)
	check("PowerShell silent, WSL's files there: the rest is read through WSL (%s)" % _states(silent), _states(silent).begins_with("windows=warn wsl=ok distro=ok python3=ok"))
	check("PowerShell silent, no file of WSL: WSL is missing", _state(Probe.ladder({"port": 8790, "windows": {"unread": true, "wsl": false}}, false, true), "wsl") == "no")

	# --- the programs
	var f5: Dictionary = found.duplicate(true)
	f5["tmux"] = {"path": "", "version": ""}
	f5["git"] = {"path": "", "version": ""}
	var no_tmux := Probe.ladder({"port": 8790, "windows": w, "linux": {"code": 0, "found": f5}}, false, true)
	check("two programs missing: both are shown, and the engine waits for tmux", _state(no_tmux, "tmux") == "no" and _state(no_tmux, "git") == "no" and _state(no_tmux, "engine") == "after" and str(_rung(no_tmux, "tmux")["how"]) == "sudo apt install tmux")
	var f6: Dictionary = found.duplicate(true)
	f6["python3"] = {"path": "/usr/bin/python3", "version": "3.8"}
	check("an old python3 is a missing python3", _state(Probe.ladder({"port": 8790, "windows": w, "linux": {"code": 0, "found": f6}}, false, true), "python3") == "no")
	var f7: Dictionary = found.duplicate(true)
	f7["codex"] = {"path": "", "version": ""}
	var no_codex := Probe.ladder({"port": 8790, "windows": w, "linux": {"code": 0, "found": f7}}, true, true)
	check("an optional program missing changes nothing to the verdict", _state(no_codex, "codex") == "no" and not _rung(no_codex, "codex")["required"] and Probe.verdict(no_codex) == "Everything needed is there.")
	check("flyctl: the app does not say it downloads it", not str(Probe.HOW["flyctl"]).contains("download"))
	var greeted := Probe.parse_programs("Welcome to Ubuntu 24.04.4 LTS\nPATH=/usr/bin: something a profile printed\n" + real_l)
	check("what a login shell prints before is not a program", greeted.size() == found.size() and not greeted.has("PATH"))

	# --- the engine room
	check("recorded: this computer's memory, the distribution's disk file and its drive are read", w["ram"] > 1073741824 and w["disks"].has(w["default"]) and w["disks"][w["default"]]["drive"] == "C:" and w["disks"][w["default"]]["file"] > 0 and w["disks"][w["default"]]["free"] < w["disks"][w["default"]]["total"])
	check("recorded: no .wslconfig", not w["wslconfig"]["present"] and w["wslconfig"]["lines"].is_empty())
	var gib := 1073741824
	var host := {"wsl": true, "distro": "Ubuntu-24.04", "uptime": 70200.0, "memory": {"total": 16 * gib, "available": 14 * gib, "used": 2 * gib, "swap_total": 4 * gib, "swap_used": 0},
		"disk": {"total": 1007 * gib, "free": 918 * gib}, "drives": [{"letter": "c", "total": 931 * gib, "free": 68 * gib}],
		"sessions": [{"id": "a", "name": "Checkout flow", "bytes": gib / 2}, {"id": "b", "name": "Flaky tests", "bytes": gib / 2}], "sessions_bytes": gib,
		"on_windows_disk": [{"id": "a", "name": "Checkout flow", "drive": "c"}]}
	var ww: Dictionary = w.duplicate(true)
	ww["ram"] = 32 * gib
	ww["disks"] = {"Ubuntu-24.04": {"drive": "C:", "file": 45 * gib, "free": 68 * gib, "total": 931 * gib}}
	var room := Probe.engine_room({"windows": ww}, host, true)
	var text := func(lines: Array, label: String) -> String:
		for l in lines:
			if l["label"] == label:
				return str(l["text"])
		return ""
	var warns := func(lines: Array, label: String) -> bool:
		for l in lines:
			if l["label"] == label:
				return bool(l["warn"])
		return false
	check("engine room: memory, here and for the whole computer", text.call(room, "Memory") == "2.0 of 16 GB used inside WSL · this computer has 32 GB.")
	check("engine room: what the sessions weigh, and how many more would fit", text.call(room, "Sessions") == "2 running, about 1.0 GB together: Checkout flow 0.5 GB, Flaky tests 0.5 GB. About 28 more of that weight would fit in the memory that is free.")
	check("engine room: the true room is the Windows drive's, said with a warning when it is nearly full", text.call(room, "Disk") == "Linux reports 918 GB free. Its disk is a 45 GB file on C:, where 68 GB are free (93 % full): that is the true room." and warns.call(room, "Disk"))
	check("engine room: sessions on the Windows disk", text.call(room, "Folders").begins_with("1 of 2 sessions work in a folder on the Windows disk (C:)"))
	check("engine room: no .wslconfig, WSL's defaults", text.call(room, "Limits").begins_with("No .wslconfig"))
	check("engine room: how long it has been up", text.call(room, "Up for") == "19 h (WSL).")
	var wc := Probe.parse_windows(_windows(26100, true, true, true, "#wslconfig 0\npresent=True\nmemory = 8GB\n  processors=4\n"))
	check("a .wslconfig's limits are read as they are written", text.call(Probe.engine_room({"windows": wc}, {}, true), "Limits") == "From your .wslconfig: memory=8GB · processors=4.")
	var down_room := Probe.engine_room({"windows": ww}, {}, true)
	check("engine room, engine down: only what Windows knows is said", text.call(down_room, "Memory, sessions") != "" and text.call(down_room, "Disk").begins_with("Its disk is a 45 GB file on C:") and text.call(down_room, "Memory") == "")
	var tight: Dictionary = host.duplicate(true)
	tight["memory"]["available"] = gib / 4
	check("engine room: no room for one more session is a warning", warns.call(Probe.engine_room({"windows": ww}, tight, true), "Sessions") and warns.call(Probe.engine_room({"windows": ww}, tight, true), "Memory"))
	var plain := Probe.engine_room({}, {"wsl": false, "distro": "", "uptime": 300000.0, "memory": {"total": 16 * gib, "available": 8 * gib, "used": 8 * gib, "swap_total": 0, "swap_used": 0}, "disk": {"total": 500 * gib, "free": 200 * gib}, "drives": [], "sessions": [], "sessions_bytes": 0, "on_windows_disk": []}, false)
	check("engine room on Linux: memory, no session, the disk as it is, no word of WSL", text.call(plain, "Memory") == "8.0 of 16 GB used." and text.call(plain, "Sessions") == "None is running." and text.call(plain, "Disk") == "200 GB free of 500." and text.call(plain, "Limits") == "" and text.call(plain, "Up for") == "3 days.")
	check("the registry and the settings file are read without a backslash in the script", not Probe.WINDOWS_SCRIPT.contains("\\"))

	# --- what the app offers to install on a click
	check("nothing is missing: nothing is offered", Probe.missing_packages({"linux": linux}).is_empty())
	check("tmux and git missing: their packages are offered, and ssh would be openssh-client", Probe.missing_packages({"linux": {"code": 0, "found": f5}}) == ["tmux", "git"] and Probe.PACKAGE["ssh"] == "openssh-client")
	check("an old python3 is not offered: its package would not make it newer", Probe.missing_packages({"linux": {"code": 0, "found": f6}}).is_empty())
	var no_apt: Dictionary = f5.duplicate(true)
	no_apt["apt"] = {"path": "", "version": ""}
	check("no apt-get in the distribution: nothing is offered", Probe.missing_packages({"linux": {"code": 0, "found": no_apt}}).is_empty())
	check("the check did not run: nothing is offered", Probe.missing_packages({"linux": {"code": 1, "found": f5}}).is_empty() and Probe.missing_packages({}).is_empty())
	check("inside WSL the command runs as the distribution's root, without a shell in between", Probe.install_argv(["tmux", "git"], "/mnt/c/Program Files/Agent Manager", true) == ["wsl.exe", "-u", "root", "-e", "bash", "/mnt/c/Program Files/Agent Manager/engine/setup_install.sh", "tmux", "git"])
	check("on Linux it goes through sudo", Probe.install_argv(["tmux"], "/opt/agent-manager", false) == ["sudo", "bash", "/opt/agent-manager/engine/setup_install.sh", "tmux"])

	# --- on Linux: no rung for Windows
	var on_linux := Probe.ladder({"port": 8790, "linux": linux}, true, false)
	check("Linux: the ladder starts at the programs (%s)" % _states(on_linux), _states(on_linux).begins_with("python3=ok tmux=ok git=ok ssh=ok engine=ok"))
	check("Linux: bash did not run the check", _states(Probe.ladder({"port": 8790, "linux": {"code": 127, "found": {}}}, false, false)).begins_with("shell=no python3=after"))

	# --- while the first reading is on its way
	var waiting := Probe.ladder({}, false, true)
	check("before the first answer: every rung is being read", waiting.all(func(r: Dictionary) -> bool: return r["state"] == "wait") and Probe.verdict(waiting) == "Looking…")
	check("before the first answer, an engine that answers is already shown", _state(Probe.ladder({}, true, true), "engine") == "ok")

	# --- reading with a runner of our own: the commands asked, in order, and nothing below a missing WSL
	var asked := []
	var p := Probe.new()
	p.on_windows = true
	p.runner = func(a: Array) -> Dictionary:
		asked.append(str(a[0]))
		return {"code": 0, "out": _windows(26100, true, false, false)} if str(a[0]) == "powershell.exe" else {"code": 0, "out": real_l}
	var got := p.read("/mnt/c/app", 8790)
	check("no WSL: Windows is asked, WSL is not", asked == ["powershell.exe"] and not got.has("linux"))
	asked.clear()
	p.runner = func(a: Array) -> Dictionary:
		asked.append(" ".join(a.slice(0, 3)) if str(a[0]) == "wsl.exe" else str(a[0]))
		return {"code": 0, "out": real_w} if str(a[0]) == "powershell.exe" else {"code": 0, "out": real_l}
	got = p.read("/mnt/c/app", 8790)
	check("WSL there: Windows, then the check inside WSL with the engine's port", asked == ["powershell.exe", "wsl.exe -e bash"] and got["linux"]["found"].has("engine-port"))


## The engine room's dashboard (scripts/host_view.gd): its words, its colours, its bars, its tiles, its table.
func _dashboard_cases() -> void:
	var gib := 1073741824.0
	var mib := 1048576.0
	check("dashboard: memory is written in MB under one GB, in GB above", View.mem(520 * mib) == "520 MB" and View.mem(1.3 * gib) == "1.3 GB" and View.mem(15.6 * gib) == "16 GB")
	check("dashboard: durations", View.span(40) == "40 s" and View.span(12 * 60 + 5) == "12 min" and View.span(3 * 3600 + 5 * 60) == "3 h 05" and View.span(2 * 86400 + 4 * 3600) == "2 d 4 h")
	check("dashboard: how long ago", View.ago(3) == "now" and View.ago(300) == "5 min ago")
	check("dashboard: a share of one processor", View.share(null) == "…" and View.share(0.034) == "3.4 %" and View.share(0.5) == "50 %" and View.share(2.4) == "240 %" and View.share(0.0) == "0 %" and View.share(0.0002) == "under 0.1 %")
	# 1 800 000 000 is January 15, 2027, 08:00 UTC
	check("dashboard: the hour in the computer's time zone, the day too for a long span", View.clock(1800000000, false, 0) == "08:00" and View.clock(1800000000, false, -300) == "03:00" and View.clock(1800000000, true, -300) == "Jan 15, 03:00")
	check("dashboard: the axis ends on a round figure above the tallest bar", View.top_of(1.3 * gib) == 1.5 * gib and View.top_of(2.2 * gib) == 2.5 * gib and View.top_of(2.8 * gib) == 3 * gib and View.top_of(7 * gib) == 8 * gib and View.top_of(310 * mib) == 400 * mib and View.top_of(0) == mib)
	check("dashboard: an unknown span is the first one", View.range_of("nope")["id"] == "1h" and View.range_of("7d")["seconds"] == 604800)
	# --- colours: a session keeps its hue
	var first := View.assign({}, ["a", "b", "c"])
	check("dashboard: hues are given in a fixed order", first == {"a": 0, "b": 1, "c": 2})
	var then := View.assign(first, ["b", "c", "d"])
	check("dashboard: who stays keeps its hue, who comes takes the one given back", then == {"b": 1, "c": 2, "d": 0})
	var many := View.assign({}, ["s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9"])
	check("dashboard: past the eighth, a session joins the others", many["s7"] == 7 and many["s8"] == View.OTHER and many["s9"] == View.OTHER)
	check("dashboard: the running sessions are served before the ended ones", View.ids_to_show({"sessions": [{"id": "run"}]}, {"sessions": [{"id": "old"}, {"id": "run"}]}) == ["run", "old"])
	check("dashboard: light and dark themes each have their own steps of the same hues", View.hue(0, false) == Color.html("3987e5") and View.hue(0, true) == Color.html("2a78d6") and View.HUES_DARK.size() == View.HUES_LIGHT.size())
	# --- the bars
	var hist := {"used": [4 * gib, null, 3 * gib], "sessions": [
		{"id": "aa", "name": "Checkout flow", "bytes": [1 * gib, null, 2 * gib], "peak": 2.5 * gib, "first": 100, "last": 400},
		{"id": "bb", "name": "Docs refresh", "bytes": [0.5 * gib, null, 0], "peak": 0.6 * gib, "first": 100, "last": 200}]}
	var st := View.stack(hist, {"aa": 1, "bb": 0})
	var b0: Dictionary = st["bars"][0]
	check("dashboard: a bar piles the sessions in the order of their hues, then the rest", b0["segs"].map(func(x: Dictionary) -> int: return x["slot"]) == [0, 1, View.REST] and b0["segs"][2]["bytes"] == 2.5 * gib and b0["sum"] == 4 * gib)
	check("dashboard: a time without reading has no bar", st["bars"][1] == null)
	check("dashboard: a session that ended is no longer in the pile", st["bars"][2]["segs"].map(func(x: Dictionary) -> String: return x["id"]) == ["aa", ""])
	check("dashboard: the axis follows the tallest bar", st["top"] == 4 * gib)
	var near: Dictionary = hist.duplicate(true)
	near["total"] = 6 * gib
	check("dashboard: near all the memory there is, the axis is that memory", View.stack(near, {"aa": 1, "bb": 0})["top"] == 6 * gib)
	near["total"] = 16 * gib
	check("dashboard: far from it, the axis stays on the bars", View.stack(near, {"aa": 1, "bb": 0})["top"] == 4 * gib)
	var over := View.stack({"used": [1 * gib], "sessions": [{"id": "aa", "bytes": [1.5 * gib]}]}, {"aa": 0})
	check("dashboard: sessions that weigh more together than what is in use leave no rest", over["bars"][0]["segs"].size() == 1 and over["bars"][0]["sum"] == 1.5 * gib and over["bars"][0]["used"] == 1 * gib)
	var crowd := View.stack({"used": [3 * gib], "sessions": [{"id": "x", "bytes": [0.5 * gib]}, {"id": "y", "bytes": [0.25 * gib]}, {"id": "z", "bytes": [0.25 * gib]}]}, {"x": 0, "y": View.OTHER, "z": View.OTHER})
	check("dashboard: the sessions past the eighth are one piece", crowd["bars"][0]["segs"].map(func(x: Dictionary) -> Array: return [x["slot"], x["bytes"]]) == [[0, 0.5 * gib], [View.OTHER, 0.5 * gib], [View.REST, 2 * gib]])
	check("dashboard: nothing to show gives no bar", View.stack({}, {})["bars"].is_empty())
	check("dashboard: the last figure of a series", View.last_of([1, null, 3, null]) == 3 and View.last_of([null]) == null)
	# --- the tiles
	var f := {"windows": {"ram": 32 * gib, "vmmem": 2.4 * gib, "default": "Ubuntu-24.04", "disks": {"Ubuntu-24.04": {"drive": "C:", "file": 45 * gib, "free": 67 * gib, "total": 950 * gib}}}}
	var host := {"wsl": true, "distro": "Ubuntu-24.04", "now": 10000.0, "uptime": 11520.0, "load": 0.52, "processors": 16, "cpu": 0.034,
		"memory": {"total": 15.5 * gib, "available": 14.5 * gib, "used": 1.0 * gib, "held": 2.1 * gib, "swap_total": 4 * gib, "swap_used": 0},
		"disk": {"total": 1007 * gib, "free": 918 * gib}, "sessions_bytes": 1.3 * gib,
		"sessions": [{"id": "aa", "name": "Checkout flow", "tool": "claude", "bytes": 0.8 * gib, "created": 4000.0, "activity": 9880.0, "attached": 1, "drive": "c", "cpu": 0.5},
			{"id": "cc", "name": "Flaky tests", "tool": "codex", "bytes": 0.5 * gib, "created": 9000.0, "activity": 9998.0, "attached": 0, "drive": "", "cpu": null}],
		"engine": {"bytes": 28 * mib, "cpu": 0.0002}, "history": {"interval": 30, "keep": 604800, "since": 1800000000, "readings": 120, "error": ""}}
	var tiles := View.tiles(f, host, hist, true)
	var tile := func(id: String) -> Dictionary:
		for t in tiles:
			if t["id"] == id:
				return t
		return {}
	check("dashboard: the tiles, in their order", tiles.map(func(t: Dictionary) -> String: return t["id"]) == ["memory", "sessions", "processors", "disk", "up"])
	check("dashboard: memory in use, of what, and what Windows gives WSL", tile.call("memory")["value"] == "1.0 GB" and tile.call("memory")["note"] == "of 16 GB inside WSL · Windows gives WSL 2.4 GB" and not tile.call("memory")["warn"] and tile.call("memory")["spark"] == hist["used"])
	check("dashboard: the sessions, their weight together and the room left", tile.call("sessions")["value"] == "2" and tile.call("sessions")["note"] == "1.3 GB together · room for about 22 more")
	check("dashboard: how busy the processors are", tile.call("processors")["value"] == "3.4 %" and tile.call("processors")["note"] == "of 16 processors · 0.5 programs wanting one")
	check("dashboard: the true room is the Windows drive's, with a mark when it is nearly full", tile.call("disk")["label"] == "Disk, free on C:" and tile.call("disk")["value"] == "67 GB" and tile.call("disk")["note"] == "93 % full · WSL's disk is a 45 GB file there" and tile.call("disk")["warn"])
	check("dashboard: how long WSL has been up", tile.call("up")["value"] == "3 h 12" and tile.call("up")["note"] == "since WSL started")
	check("dashboard: no engine, no tile", View.tiles(f, {}, {}, true).is_empty())
	var tight: Dictionary = host.duplicate(true)
	tight["memory"]["available"] = 0.4 * gib
	tight["cpu"] = null
	var tt := View.tiles({}, tight, {}, false)
	check("dashboard: memory nearly gone and no room for one more session are marked", tt[0]["warn"] and tt[1]["warn"] and tt[1]["note"].ends_with("no room for one more"))
	check("dashboard: before two readings, the processors' share is not guessed", tt[2]["value"] == "…")
	check("dashboard: without Windows' figures, the disk is the one Linux reports", tt[3]["label"] == "Disk, free" and tt[3]["value"] == "918 GB" and tt[3]["note"] == "9 % full" and not tt[3]["warn"])
	# --- the table
	var rows := View.rows(host, hist, {"aa": 0, "bb": 1, "cc": 2}, 10000.0)
	check("dashboard: the running sessions first, then the ones that ended in the span", rows.map(func(r: Dictionary) -> String: return r["name"]) == ["Checkout flow", "Flaky tests", "Docs refresh"] and rows.map(func(r: Dictionary) -> bool: return r["running"]) == [true, true, false])
	check("dashboard: a session's age, its last activity, its weight now and at the most", rows[0]["open"] == 6000.0 and rows[0]["idle"] == 120.0 and rows[0]["bytes"] == 0.8 * gib and rows[0]["peak"] == 2.5 * gib and rows[0]["cpu"] == 0.5 and rows[0]["drive"] == "c")
	check("dashboard: a session the readings do not know yet still has its line", rows[1]["peak"] == 0.5 * gib and rows[1]["spark"].is_empty() and rows[1]["cpu"] == null)
	check("dashboard: an ended session says how long it ran and when it ended", rows[2]["open"] == 100.0 and rows[2]["idle"] == 9800.0 and rows[2]["peak"] == 0.6 * gib and rows[2]["slot"] == 1)
	# --- what the readings cost
	check("dashboard: the readings' sentence", View.about(host, 0) == "One reading every 30 s, kept 7 days, since Jan 15, 08:00. The engine itself holds 28 MB and takes under 0.1 % of one processor.")
	var off: Dictionary = host.duplicate(true)
	off["history"] = {}
	check("dashboard: readings turned off are said", View.about(off, 0).begins_with("The readings over time are off"))
	off.erase("history")
	check("dashboard: an engine older than the readings is said, with the way out", View.about(off, 0).contains("started before the readings over time existed") and View.about(off, 0).contains("close it and open it again"))
	var failed_h: Dictionary = host.duplicate(true)
	failed_h["history"]["error"] = "OSError: disk full"
	check("dashboard: a reading that failed is said", View.about(failed_h, 0).ends_with("The last reading failed: OSError: disk full."))
	# --- the top bar's button
	var ok_rungs := Probe.ladder({"port": 8790, "windows": Probe.parse_windows(_recorded("windows-en.txt")), "linux": {"code": 0, "found": Probe.parse_programs(_recorded("doctor.txt"))}}, true, true)
	var calm: Dictionary = host.duplicate(true)
	var b := View.button("WSL", {}, calm, true, ok_rungs, true)
	check("top bar: all standing: a dot, the name, the memory in use", b["level"] == "ok" and b["text"] == "● WSL  1.0 GB" and b["short"] == "● WSL" and str(b["tip"]).begins_with("WSL: 1.0 GB of 16 GB in use · 2 sessions running"))
	b = View.button("WSL", f, calm, true, ok_rungs, true)
	check("top bar: a disk nearly full is a mark and a reason, not a colour alone", b["level"] == "warn" and b["text"] == "! WSL  1.0 GB" and str(b["tip"]).contains("! Disk, free on C:: 67 GB (93 % full"))
	b = View.button("WSL", f, calm, false, ok_rungs, true)
	check("top bar: an engine that does not answer is said, without its last figure", b["level"] == "bad" and b["text"] == "✗ WSL" and str(b["tip"]).contains("✗ The engine does not answer.") and not str(b["tip"]).contains("in use"))
	var no_tmux := Probe.ladder({"port": 8790, "linux": {"code": 0, "found": {"python3": {"path": "/usr/bin/python3", "version": "3.12"}}}}, false, false)
	b = View.button("Computer", {}, {}, false, no_tmux, false)
	check("top bar: a missing program is said by its name, once", b["level"] == "bad" and b["text"] == "✗ Computer" and str(b["tip"]).contains("✗ tmux") and not str(b["tip"]).contains("The engine does not answer"))
	b = View.button("WSL", {}, {}, true, [], true)
	check("top bar: before anything was read, nothing is claimed", b["level"] == "ok" and b["text"] == "● WSL" and str(b["tip"]).begins_with("WSL: Not read yet."))



## The Repos page (scripts/repo_view.gd): what a line says, in which order, and what GitHub and Azure DevOps change.
func _repo_cases() -> void:
	var now := 1800000000.0
	var gh := {"id": "a1", "name": "acme-store", "host": "github.com", "host_kind": "github", "key_scope": "repository", "key_type": "ed25519",
		"status": "connected", "checked_at": now - 125.0, "last_used": now - 3 * 3600.0, "key_made": now - 3 * 86400.0, "fingerprint": "SHA256:abc", "busy": [],
		"folder": {"path": "/home/dev/code/acme-store", "exists": true, "git": true, "read": true, "managed": false, "origin_state": "same", "branch": "main", "upstream": "origin/main", "ahead": 2, "behind": 0, "changed": 3},
		"sessions": [{"id": "s1", "name": "Checkout flow", "archived": 0}, {"id": "s2", "name": "Docs", "archived": 0}, {"id": "s3", "name": "Old", "archived": 1}]}
	var az := {"id": "b2", "name": "Client Portal", "host": "ssh.dev.azure.com", "host_kind": "azure", "key_scope": "account", "key_type": "rsa",
		"status": "waiting", "checked_at": 0.0, "last_used": 0.0, "key_made": now - 40.0, "fingerprint": "SHA256:def", "busy": [],
		"folder": {"path": "", "exists": false, "git": false, "read": true, "managed": false, "origin_state": ""}, "sessions": []}
	var broken: Dictionary = gh.duplicate(true)
	broken.merge({"id": "c3", "name": "zeta", "status": "failed", "message": "the key is not on the repository yet"}, true)
	var other := {"id": "d4", "name": "tools", "host": "git.example.org", "host_kind": "other", "key_scope": "unknown", "key_type": "ed25519", "status": "connected", "checked_at": 0.0, "busy": ["key"],
		"folder": {"path": "/data/repos/tools", "exists": true, "git": true, "read": false, "managed": true, "origin_state": ""}, "sessions": []}
	check("repos: the host is named as people name it", Repo.host_label(gh) == "GitHub" and Repo.host_label(az) == "Azure DevOps" and Repo.host_label(other) == "git.example.org")
	check("repos: a key that works says how old that knowledge is", Repo.key_cell(gh, now) == {"text": "works · checked 2 min ago", "level": "ok"})
	check("repos: a key not added yet waits, one that fails is said, one being checked too", Repo.key_cell(az, now) == {"text": "waits to be added", "level": "warn"} and Repo.key_cell(broken, now) == {"text": "does not work", "level": "bad"} and Repo.key_cell(other, now)["text"] == "checking…")
	check("repos: what the key opens is said on every line", Repo.opens_cell(gh) == "this repository only" and Repo.opens_cell(az) == "your whole account" and Repo.opens_cell(other) == "as its host decides")
	check("repos: the folder: whose it is, its branch, what is not pushed, what changed", Repo.folder_cell(gh) == {"text": "yours · main · ↑2 · 3 changed", "level": "ok"})
	check("repos: the folder's arrows are said in words in its tooltip", Repo.folder_tip(gh).contains("2 commits not pushed") and Repo.folder_tip(gh).contains("3 files changed or new") and Repo.folder_tip(gh).ends_with("nothing is fetched."))
	check("repos: no folder yet, and a folder not read yet", Repo.folder_cell(az)["text"] == "cloned on first use" and Repo.folder_cell(other)["text"] == "its copy · reading…")
	var gone: Dictionary = gh.duplicate(true)
	gone["folder"] = {"path": "/x", "exists": false, "git": false, "read": true, "managed": false, "origin_state": ""}
	var stray: Dictionary = gh.duplicate(true)
	stray["folder"]["origin_state"] = "other"
	var bare: Dictionary = gh.duplicate(true)
	bare["folder"]["origin_state"] = "missing"
	var detached: Dictionary = gh.duplicate(true)
	detached["folder"].merge({"branch": "", "ahead": 0, "behind": 4, "changed": 0}, true)
	check("repos: a folder that is gone, another repository's folder, no remote, no branch", Repo.folder_cell(gone) == {"text": "the folder is gone", "level": "warn"} and Repo.folder_cell(stray)["level"] == "bad" and Repo.folder_cell(bare) == {"text": "yours · no remote yet", "level": "warn"} and Repo.folder_cell(detached)["text"] == "yours · no branch · ↓4")
	check("repos: how many of its sessions run now", Repo.sessions_cell(gh, {"s1": "running", "s2": "exited", "s3": "running"}) == "1 running" and Repo.sessions_cell(gh, {}) == "2, none running" and Repo.sessions_cell(az, {}) == "–")
	check("repos: when it was last used", Repo.used_cell(gh, now) == "3 h 00 ago" and Repo.used_cell(az, now) == "never")
	check("repos: an age from a clock set back is « now », never a negative figure", Repo.used_cell(gh, now - 3 * 3600.0 - 2.0) == "now" and Repo.key_cell(gh, now - 130.0)["text"] == "works · checked now")
	check("repos: what needs a hand comes first, then by name", Repo.order([gh, other, az, broken]).map(func(r: Dictionary) -> String: return r["name"]) == ["zeta", "Client Portal", "acme-store", "tools"])
	check("repos: the levels", Repo.level(gh) == "ok" and Repo.level(az) == "warn" and Repo.level(broken) == "bad" and Repo.level(stray) == "bad" and Repo.level(gone) == "warn" and Repo.mark("warn") == "!")
	check("repos: the sentence above the lines", Repo.summary([gh, other, az, broken]) == "4 repositories: 2 connected · 1 waits for its key · 1 with a key that does not work" and Repo.summary([gh]) == "1 repository: 1 connected" and Repo.summary([]) == "No repository yet." and Repo.summary([az, az]).ends_with("2 wait for their keys"))
	check("repos: the key in one line, and that an Azure DevOps key expires", Repo.key_line(gh, now) == "ed25519 · SHA256:abc · made 3 d 0 h ago" and Repo.key_line(az, now).begins_with("RSA 3072 · SHA256:def · made 40 s ago · Azure DevOps keys expire"))
	check("repos: where to add the key, by host", Repo.add_key_help(gh)["button"] == "Open GitHub's Deploy keys page" and str(Repo.add_key_help(az)["then"]).contains("User settings (the icon beside your picture) › SSH public keys › New Key") and str(Repo.add_key_help(az)["then"]).contains("an account made for them") and Repo.add_key_help(other)["button"] == "")
	check("repos: an address being typed says what it will be", Repo.address_hint("git@ssh.dev.azure.com:v3/acme/Portal/portal").begins_with("Azure DevOps: an RSA key") and Repo.address_hint("git@github.com:acme/shop.git").begins_with("GitHub: a deploy key") and Repo.address_hint("https://github.com/acme/shop").begins_with("That is the web address") and Repo.address_hint("  ") == "" and Repo.address_hint("git@git.example.org:a/b.git").begins_with("Another SSH git host"))
	check("repos: the SSH address the engine proposes for a web one is taken, an example is not", Repo.proposed_address("use the SSH address, not https: git@ssh.dev.azure.com:v3/acme/My%20Project/portal. The key works over SSH") == "git@ssh.dev.azure.com:v3/acme/My%20Project/portal" and Repo.proposed_address("use the SSH address, not https: git@github.com:owner/repo.git (Azure DevOps: git@ssh.dev.azure.com:v3/organization/project/repository). The key works over SSH") == "" and Repo.proposed_address("no such folder") == "")
	var wide: Dictionary = Repo.fit(1600.0)
	var narrow: Dictionary = Repo.fit(950.0)
	check("repos: a wide window shows every column", wide["shown"] == ["host", "key", "opens", "folder", "sessions", "used"] and wide["name"] == 320.0)
	check("repos: a narrow one lets columns go, the host last", narrow["shown"] == ["host", "key", "folder"] and Repo.fit(600.0)["shown"] == ["key", "folder"] and narrow["name"] >= Repo.NAME_MIN)
	var bar := Repo.button([gh, az, broken])
	check("repos: the bar's button is marked when a repository needs a hand, and says which", bar["level"] == "bad" and bar["mark"] == "✗" and str(bar["tip"]).contains("✗ zeta: does not work") and str(bar["tip"]).contains("! Client Portal: waits to be added"))
	check("repos: all well, the bar's button has no mark", Repo.button([gh])["mark"] == "" and Repo.button([])["level"] == "ok")
	# --- what the drawn pieces show
	var live := {"s1": {"state": "running", "activity": "working"}, "s2": {"state": "exited", "activity": "done"}, "s3": {"state": "running", "activity": "working"}}
	var dots := Repo.session_dots(gh, live)
	check("repos: a dot per open session, the running ones first, none for an archived one", dots.map(func(d: Dictionary) -> String: return "%s:%s" % [d["id"], d["activity"]]) == ["s1:working", "s2:off"])
	var dated: Dictionary = gh.duplicate(true)
	dated["sessions"] = [{"id": "x", "created": now - 3600.0}, {"id": "y", "created": now - 7200.0}, {"id": "z", "created": now - 3 * 86400.0 - 60.0}, {"id": "o", "created": now - 40 * 86400.0}, {"id": "f", "created": now + 5.0}]
	var days := Repo.started_days(dated, now)
	check("repos: sessions started per day, today last; older than the span is left out; a clock set back counts as today", days.size() == 14 and days[13] == 3 and days[10] == 1 and days.reduce(func(a: int, b: int) -> int: return a + b, 0) == 4)
	var fresh: Dictionary = gh.duplicate(true)
	fresh["checked_at"] = now - 300.0
	check("repos: how fresh a check is: half way at five minutes, nothing at ten, nothing for a key that waits", is_equal_approx(Repo.freshness(fresh, now), 0.5) and Repo.freshness(fresh, now + 400.0) == 0.0 and Repo.freshness(az, now) == 0.0)
	var top := Repo.tiles([gh, az, broken, other], live)
	check("repos: the tiles: keys that work, who needs a hand, sessions running, hosts", top.map(func(t: Dictionary) -> String: return "%s=%s" % [t["id"], t["value"]]) == ["connected=2", "hand=2", "running=2", "hosts=3"] and top[1]["note"] == "Client Portal, zeta" and top[1]["level"] == "bad" and top[3]["note"] == "GitHub 2 · Azure DevOps 1 · git.example.org 1")
	check("repos: the tiles when all is well and nothing runs", Repo.tiles([gh], {})[1]["note"] == "none" and Repo.tiles([gh], {})[1]["level"] == "ok" and Repo.tiles([gh], {})[2]["note"] == "on no repository" and Repo.tiles([gh], {})[0]["note"] == "of 1 repository")
	# --- the map of the branches
	var graph := {"read": true, "worktrees": 3, "more": 1, "base": {"name": "main", "tip": "abc", "date": now - 600.0, "subject": "main moves on", "worktree": "/code/shop", "sessions": [{"id": "s2", "name": "Docs"}]},
		"branches": [
			{"name": "am/tax-rules", "ahead": 0, "behind": 0, "date": now - 100.0, "subject": "main moves on", "worktree": "/wt/tax", "upstream": "", "sessions": [{"id": "s9", "name": "Tax rules"}]},
			{"name": "am/gift-cards", "ahead": 3, "behind": 2, "date": now - 50.0, "subject": "gift 3", "worktree": "/wt/gift", "upstream": "", "sessions": [{"id": "s1", "name": "Gift cards"}]},
			{"name": "spike", "ahead": 40, "behind": 90, "date": now - 9 * 86400.0, "subject": "try", "worktree": "", "upstream": "origin/spike", "sessions": []},
			{"name": "old", "ahead": 0, "behind": 12, "date": now - 30 * 86400.0, "subject": "done", "worktree": "", "upstream": "", "sessions": []}]}
	var map := Repo.metro(graph, live)
	check("map: the lines worth a look, the one with a running session first, then the ones with a folder, then by last commit", map["lines"].map(func(l: Dictionary) -> String: return l["name"]) == ["am/gift-cards", "am/tax-rules", "spike"])
	check("map: a merged branch with no folder and no session is counted, not drawn", map["merged"] == 1 and map["more"] == 1)
	check("map: each line has its place's hue, and the base line shows no more than its latest commits", map["lines"].map(func(l: Dictionary) -> int: return l["slot"]) == [0, 1, 2] and map["span"] == Repo.METRO_SPAN)
	check("map: the base and who works in its folder", map["base"]["name"] == "main" and map["base"]["dots"].size() == 1 and map["base"]["dots"][0]["running"] == false)
	check("map: a line in words", Repo.metro_tip(map["lines"][0], "main", now) == "am/gift-cards\n3 commits of its own · main made 2 since it left\nLast: gift 3 (50 s ago)\nIts folder: /wt/gift\n● Gift cards: working")
	check("map: a branch with a folder and nothing of its own yet is said so", Repo.metro_tip(map["lines"][1], "main", now).contains("no commit of its own yet") and Repo.metro_tip(map["lines"][1], "main", now).contains("● Tax rules: not running"))
	check("map: no folder, no map, and why", Repo.metro({"read": false, "why": "no folder yet"}, {})["why"] == "no folder yet" and Repo.metro({"read": true, "base": null, "branches": []}, {})["read"] == false)
	var many := {"read": true, "base": graph["base"], "branches": [], "more": 0}
	for i in 10:
		many["branches"].append({"name": "b%d" % i, "ahead": 1, "behind": 1, "date": now - i, "subject": "", "worktree": "", "sessions": []})
	check("map: past eight lines, the others are grey", Repo.metro(many, {})["lines"].map(func(l: Dictionary) -> int: return l["slot"]) == [0, 1, 2, 3, 4, 5, 6, 7, -1, -1])


## The Sandboxes page's inventory (scripts/sandbox_view.gd): states, order, a sandbox's life as a bar, the tiles.
func _sandbox_cases() -> void:
	var now := 1800000000.0
	var day := 86400.0
	var up := {"id": "sb1", "name": "Cloud work", "state": "started", "destroyed": false, "size": "shared-cpu-1x-1024", "region": "yyz", "app": "agmgd-x", "machine": "m1",
		"created": now - 3 * day, "runs": [[now - 3 * day, now - 2 * day], [now - 3600.0, null]], "run_seconds": 90000, "cost_usd": 0.2295, "first_start": now - 3 * day, "last_stop": now, "running_now": true}
	var paused: Dictionary = up.duplicate(true)
	paused.merge({"id": "sb2", "name": "", "state": "stopped", "running_now": false, "runs": [[now - 10 * day, now - 9 * day]], "created": now - 10 * day, "last_stop": now - 9 * day, "run_seconds": 86400, "cost_usd": 0.22}, true)
	var dead: Dictionary = up.duplicate(true)
	dead.merge({"id": "sb3", "name": "Old spike", "state": "destroyed", "destroyed": true, "running_now": false, "size": "performance-cpu-2x-4096",
		"runs": [[now - 40 * day, now - 39 * day], [now - 15 * day, now - 15 * day + 60.0]], "created": now - 40 * day, "last_stop": now - 15 * day + 60.0, "run_seconds": 86460, "cost_usd": 1.5}, true)
	var lost: Dictionary = paused.duplicate(true)
	lost.merge({"id": "sb4", "name": "Lost", "state": "gone", "created": now - 5 * day, "last_stop": 0.0, "runs": [], "run_seconds": 0, "cost_usd": 0.0}, true)
	check("sandboxes: a state in words: running, paused, destroyed, gone at Fly.io, Fly.io not reached", Sbx.state_of(up) == {"text": "running", "level": "ok"} and Sbx.state_of(paused)["text"] == "paused" and Sbx.state_of(dead) == {"text": "destroyed", "level": "off"} and Sbx.state_of(lost) == {"text": "gone at Fly.io", "level": "bad"} and Sbx.state_of({"state": "unknown"})["text"] == "Fly.io not reached")
	check("sandboxes: a sandbox without a session's name still has one", Sbx.name_of(up) == "Cloud work" and Sbx.name_of(paused) == "sandbox sb2")
	check("sandboxes: a size as people read it", Sbx.size_words("shared-cpu-1x-1024") == "shared · 1 CPU · 1 GB" and Sbx.size_words("performance-cpu-2x-4096") == "performance · 2 CPU · 4 GB" and Sbx.size_words("shared-cpu-1x-256") == "shared · 1 CPU · 256 MB" and Sbx.size_words("odd") == "odd")
	check("sandboxes: money", Sbx.money(0.0) == "$0" and Sbx.money(0.0123) == "$0.012" and Sbx.money(1.5) == "$1.50")
	check("sandboxes: the inventory's order: running, then paused or lost, then destroyed", Sbx.order([dead, lost, paused, up]).map(func(r: Dictionary) -> String: return r["id"]) == ["sb1", "sb4", "sb2", "sb3"])
	var l: Dictionary = Sbx.life(up, now)
	check("sandboxes: a life as a bar: each run between thirty days ago and now, the one still running marked", l["runs"].size() == 2 and is_equal_approx(l["runs"][0][0], 0.9) and is_equal_approx(l["runs"][1][1], 1.0) and l["runs"][1][2] == true and l["runs"][0][2] == false and is_equal_approx(l["made"], 0.9) and l["ended"] == -1.0)
	var ld: Dictionary = Sbx.life(dead, now)
	check("sandboxes: a destroyed one keeps the runs inside the bar, its end marked; what is older is left out", ld["runs"].size() == 1 and is_equal_approx(ld["runs"][0][0], 0.5) and ld["made"] == -1.0 and absf(ld["ended"] - 0.5) < 0.001 and ld["runs"][0][2] == false)
	check("sandboxes: a sandbox whose machine never ran has an empty bar", Sbx.life(lost, now)["runs"].is_empty() and Sbx.tip(lost, now, 0).contains("never ran"))
	check("sandboxes: a line in words", Sbx.tip(dead, now, 0).begins_with("Old spike · destroyed\nperformance · 2 CPU · 4 GB · yyz · made ") and Sbx.tip(dead, now, 0).contains("ran 2 times, 1 d 0 h in all: $1.50") and Sbx.tip(up, now, 0).contains("Last: running now."))
	var inv := {"sandboxes": [up, paused, dead, lost], "at_fly": {"reachable": true, "machines": 2, "unknown_here": 0}}
	var t := Sbx.tiles(inv)
	check("sandboxes: the tiles: running, paused, destroyed and kept, at Fly.io now", t.map(func(x: Dictionary) -> String: return "%s=%s" % [x["id"], x["value"]]) == ["running=1", "paused=2", "destroyed=1", "fly=2"] and t[0]["note"] == "Cloud work" and str(t[2]["note"]).begins_with("$1.95 measured in all") and str(t[3]["note"]).ends_with("none that Agent Manager does not know"))
	inv["at_fly"]["unknown_here"] = 1
	check("sandboxes: a machine Agent Manager does not know is marked", Sbx.tiles(inv)[3]["level"] == "warn" and str(Sbx.tiles(inv)[3]["note"]).contains("1 that Agent Manager does not know"))
	inv["at_fly"]["reachable"] = false
	check("sandboxes: Fly.io not reached is said, and nothing is claimed", Sbx.tiles(inv)[3]["value"] == "?" and Sbx.tiles(inv)[3]["level"] == "warn")
	check("sandboxes: nothing running says that nothing is billed for running", Sbx.tiles({"sandboxes": [dead], "at_fly": {"reachable": true, "machines": 0, "unknown_here": 0}})[0]["note"].begins_with("none: nothing is billed"))
	# --- tunnels and ports
	check("ports: a rate and an amount in words", Sbx.rate(0.2) == "0" and Sbx.rate(850) == "850 B/s" and Sbx.rate(1234) == "1.2 kB/s" and Sbx.rate(3400000) == "3.4 MB/s" and Sbx.amount(0) == "0" and Sbx.amount(512) == "512 B" and Sbx.amount(12345) == "12 kB" and Sbx.amount(3400000) == "3.4 MB" and Sbx.amount(1200000000) == "1.2 GB")
	var tun := {"state": "open", "ports": [{"remote_port": 8501, "port": 8501, "state": "open", "address": "http://127.0.0.1:8501", "sent": 1200, "received": 250000, "sent_rate": 40.0, "received_rate": 9000.0, "open_now": 2, "label": "dashboard"},
			{"remote_port": 9000, "port": 9001, "state": "paused", "address": "http://127.0.0.1:9001", "sent": 0, "received": 0, "sent_rate": 0.0, "received_rate": 0.0, "open_now": 0, "label": ""}],
		"listening": [{"port": 53, "program": "", "inside": true, "open": false}, {"port": 8000, "program": "python3", "inside": true, "open": false}, {"port": 8501, "program": "streamlit", "inside": false, "open": true}]}
	check("ports: the connection in words", Sbx.link_of(tun) == {"text": "connected · 2 ports on your localhost", "level": "ok"} and Sbx.link_of({"state": "open", "ports": []})["text"] == "connected · no port brought here yet" and Sbx.link_of({})["level"] == "off" and Sbx.link_of({"state": "lost"})["level"] == "bad")
	var pr := Sbx.port_rows(tun)
	check("ports: what is brought here first, then what listens, by number", pr.map(func(r: Dictionary) -> int: return r["port"]) == [8501, 9000, 53, 8000] and pr[0]["program"] == "streamlit" and pr[0]["local"] == 8501 and pr[0]["received_rate"] == 9000.0)
	check("ports: a port brought here whose program no longer listens stays listed, and says so", pr[1]["listening"] == false and Sbx.port_words(pr[1]) == "a program on 9000 is on your localhost:9001 · paused: it carries nothing · nothing listens there any more")
	check("ports: a line in words", Sbx.port_words(pr[0]) == "streamlit on 8501 is on your localhost:8501" and Sbx.port_words(pr[3]) == "python3 listens on 8000 (inside the sandbox only)")
	var hw := Sbx.health_words({"memory_total": 1009636 * 1024.0, "memory_used": 405056 * 1024.0, "load": 0.42, "disk_total": 8350298112.0, "disk_free": 5771362304.0, "round_trip_ms": 48})
	check("ports: how the sandbox is doing, in four figures", hw.map(func(x: Array) -> String: return "%s %s" % [x[0], x[1]]) == ["Memory 396 MB of 1.0 GB", "Load 0.42", "Disk free 5.4 GB", "Round trip 48 ms"] and not hw[0][2] and Sbx.health_words({}).is_empty())

