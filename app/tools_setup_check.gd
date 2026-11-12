extends SceneTree
## The checks of the setup ladder (scripts/setup_probe.gd), without a window, an engine or a display:
##   godot --headless --path app --script res://tools_setup_check.gd            every case below; exit 1 when one fails
##   … --script res://tools_setup_check.gd -- argv                              the PowerShell call, to run it by hand
##   … --script res://tools_setup_check.gd -- parse <windows.txt> [doctor.txt]  the ladder read from saved outputs
##   … --script res://tools_setup_check.gd -- real                              the real reading, on this computer
## Two outputs were recorded on a real computer (tools/setup/recorded). The other states (no WSL, no distribution,
## Windows in French…) are written by hand from what the documentation says: they were never seen on a computer.

const Probe := preload("res://scripts/setup_probe.gd")

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
