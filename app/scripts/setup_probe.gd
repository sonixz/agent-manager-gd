extends RefCounted
## The ground under the app, read rung by rung: Windows, WSL, the Linux distribution, the programs, the engine, the
## agents. It only looks: it installs, downloads and changes nothing. It asks Windows and WSL themselves, never the
## engine, so it tells the truth when the engine is down.
##
## The reading takes a few seconds (PowerShell alone takes three): `read` is run in a thread, never while a frame is
## drawn. Before, the check ran while the page was drawn and the window froze for that long.
##
## It is loaded with preload, not by a class name: the app is also started straight from its sources, where a new
## class name is unknown until Godot has scanned the project again.

const MIN_BUILD := 19041  # Windows 10 version 2004: the first that runs WSL 2 and knows `wsl --install`
const REQUIRED := ["python3", "tmux", "git", "ssh"]
const OPTIONAL := ["claude", "codex", "flyctl"]

## What is asked of Windows, in one PowerShell call (starting PowerShell is the slow part). It prints sections,
## « #name exit-code » then the lines as they came; the reading of those lines is done here, where it can be checked
## against recorded outputs.
##  - WSL's command is only run when one of WSL's services exists. Where WSL is not installed, Windows keeps a
##    stand-in wsl.exe that offers to install it: a check that only looks must never start that.
##  - WSL_UTF8 makes wsl.exe write plain text instead of UTF-16 (measured, WSL 2.6.3). It is set inside this one
##    call, not for the app: the terminals keep what they have.
##  - For the engine room: this computer's memory, how much of it is free, and how much of it WSL holds right now
##    (the memory of the process Windows runs WSL in, vmmemWSL: readable without administrator rights; measured
##    2.4 GB while Linux used 1.0); each distribution's disk, which is one file on a Windows drive
##    (its size, and the room left on that drive: the true room, whatever Linux reports); and the few lines of the
##    user's .wslconfig that set limits. All read, none written. No folder's name is printed: only the drive.
##    No backslash is written in this script: one less thing to escape twice.
##  - Nothing here is read by its words: the table's titles and states follow Windows' language. Rows are found by
##    the distributions' names, the default by its star, the running ones by the list of names that run.
const WINDOWS_SCRIPT := """$ErrorActionPreference='SilentlyContinue'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding $false
$env:WSL_UTF8='1'
'#windows 0'
'build='+[Environment]::OSVersion.Version.Build
$p=Get-CimInstance Win32_Processor|Select-Object -First 1
$c=Get-CimInstance Win32_ComputerSystem
'virt_firmware='+$p.VirtualizationFirmwareEnabled
'hypervisor='+$c.HypervisorPresent
'ram='+$c.TotalPhysicalMemory
'free='+([int64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1024)
$v=Get-Process -Name vmmemWSL,vmmem|Sort-Object WorkingSet64 -Descending|Select-Object -First 1
'vmmem='+[int64]$v.WorkingSet64
$s=[bool](Get-Service WslService) -or [bool](Get-Service LxssManager)
'service='+$s
if($s -and (Get-Command wsl.exe)){
foreach($q in @(@('version','--version'),@('names','-l','-q'),@('table','-l','-v'),@('running','-l','-q','--running'))){
$a=@($q[1..($q.Length-1)])
$o=& wsl.exe @a 2>$null
'#'+$q[0]+' '+$LASTEXITCODE
$o
}}
'#disks 0'
$bs=[string][char]92
Get-ChildItem 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Lxss'|ForEach-Object{
$r=Get-ItemProperty $_.PSPath
$b=[string]$r.BasePath
if($b.StartsWith($bs+$bs+'?'+$bs)){$b=$b.Substring(4)}
$n=[string]$r.VhdFileName
if(-not $n){$n='ext4.vhdx'}
$f=Join-Path $b $n
$z=0
if(Test-Path -LiteralPath $f){$z=(Get-Item -LiteralPath $f).Length}
$d=Get-PSDrive -Name $b.Substring(0,1)
'disk='+$r.DistributionName+'|'+$b.Substring(0,2)+'|'+$z+'|'+$d.Free+'|'+($d.Used+$d.Free)
}
'#wslconfig 0'
$w=Join-Path $env:USERPROFILE '.wslconfig'
if(Test-Path -LiteralPath $w){'present=True'
Get-Content -LiteralPath $w|Where-Object{$_ -match '^[ ]*(memory|processors|swap|localhostForwarding|networkingMode|vmIdleTimeout)[ ]*='}
}else{'present=False'}
'#end 0'
"""

var on_windows := OS.get_name() == "Windows"
## Runs a command and gives {"code": int, "out": String}. The checks put their own here, which answers with
## recorded outputs.
var runner := Callable()


func run(argv: Array, with_errors := false) -> Dictionary:
	if runner.is_valid():
		return runner.call(argv)
	var out := []
	var code := OS.execute(str(argv[0]), argv.slice(1), out, with_errors)
	return {"code": code, "out": "".join(out)}


## The PowerShell call. The script goes as -EncodedCommand (base64 of its UTF-16 text): no quote and no space in the
## arguments, which Godot's OS.execute splits again when they hold quotes.
static func windows_argv() -> Array:
	return ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", Marshalls.raw_to_base64(WINDOWS_SCRIPT.to_utf16_buffer())]


## Whether the current WSL is installed, seen without running anything: the second witness, for when PowerShell does
## not answer. Only WSL's own folder is trusted: Windows keeps other traces of WSL (System32\\lxss) whether it is
## installed or not.
static func wsl_files() -> bool:
	var pf := OS.get_environment("ProgramFiles")
	return pf != "" and FileAccess.file_exists(pf.path_join("WSL/wsl.exe"))


## Everything, read now. `root` is the repository as the engine sees it; `port` the engine's. Blocking: call it in a
## thread.
func read(root: String, port: int) -> Dictionary:
	var f := {"port": port, "on_windows": on_windows, "read_at": Time.get_unix_time_from_system()}
	if on_windows:
		var r := run(windows_argv())
		var w := parse_windows(str(r["out"]))
		if w.is_empty():
			w = {"unread": true, "wsl": wsl_files()}
		f["windows"] = w
		if not bool(w.get("wsl", false)) or (not w.has("unread") and usable(w) == ""):
			return f  # no WSL, or no distribution to ask: nothing below can be read
	var argv: Array = ["bash", "-l", root.path_join("engine/doctor.sh"), str(port)]
	if on_windows:
		argv = ["wsl.exe", "-e"] + argv
	var l := run(argv, true)
	f["linux"] = {"code": int(l["code"]), "found": parse_programs(str(l["out"]))}
	return f


## Docker Desktop keeps distributions of its own in WSL. They are not a place to work in.
static func is_docker(name: String) -> bool:
	return name.begins_with("docker-desktop") or name.begins_with("rancher-desktop")


## The distribution the engine runs in: WSL's default one. "" when there is none to work in.
static func usable(w: Dictionary) -> String:
	var d := str(w.get("default", ""))
	return "" if d == "" or is_docker(d) else d


static func parse_windows(text: String) -> Dictionary:
	var sections := {}
	var codes := {}
	var cur := ""
	for raw in text.replace("\r", "").split("\n"):
		var line := raw.rstrip(" \t")
		if line.begins_with("#"):
			var head := line.substr(1).split(" ", false)
			cur = head[0] if head.size() > 0 else ""
			codes[cur] = int(head[1]) if head.size() > 1 else 0
			sections[cur] = []
		elif cur != "" and line.strip_edges() != "":
			sections[cur].append(line)
	if not sections.has("windows") or not sections.has("end"):
		return {}  # PowerShell did not run the script to its end
	var w := {"names": [], "running": [], "versions": {}, "default": "", "version": ""}
	for line in sections["windows"]:
		var kv: PackedStringArray = str(line).split("=", true, 1)
		if kv.size() == 2:
			w[kv[0].strip_edges()] = kv[1].strip_edges()
	w["build"] = int(str(w.get("build", "0")))
	w["ram"] = int(str(w.get("ram", "0")))
	w["free"] = int(str(w.get("free", "0")))
	w["vmmem"] = int(str(w.get("vmmem", "0")))
	w["disks"] = {}
	for line in sections.get("disks", []):
		var d: PackedStringArray = str(line).trim_prefix("disk=").split("|")
		if str(line).begins_with("disk=") and d.size() == 5:
			w["disks"][d[0]] = {"drive": d[1], "file": int(d[2]), "free": int(d[3]), "total": int(d[4])}
	var limits := []
	var present := false
	for line in sections.get("wslconfig", []):
		if str(line).strip_edges() == "present=True":
			present = true
		elif not str(line).begins_with("present="):
			limits.append(str(line).strip_edges().replace(" ", ""))
	w["wslconfig"] = {"present": present, "lines": limits}
	# A name of a distribution holds no space; a sentence (« there is no distribution », in any language) does.
	if int(codes.get("names", 1)) == 0:
		for line in sections.get("names", []):
			var n := str(line).strip_edges()
			if n != "" and not n.contains(" "):
				w["names"].append(n)
	for line in sections.get("running", []):
		if w["names"].has(str(line).strip_edges()):
			w["running"].append(str(line).strip_edges())
	var by_length: Array = w["names"].duplicate()
	by_length.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	for line in sections.get("table", []):
		var row := str(line).strip_edges()
		var star := row.begins_with("*")
		row = row.trim_prefix("*").strip_edges()
		for n in by_length:
			if row == n or row.begins_with(str(n) + " "):
				var last := row.get_slice(" ", row.get_slice_count(" ") - 1)
				if last.is_valid_int():
					w["versions"][n] = int(last)
				if star:
					w["default"] = n
				break
	if int(codes.get("version", 1)) == 0 and not sections.get("version", []).is_empty():
		var m := RegEx.create_from_string("\\d+(\\.\\d+)+").search(str(sections["version"][0]))
		if m:
			w["version"] = m.get_string()
	# WSL is there when its service exists and its command was run; the stand-in wsl.exe alone is not WSL.
	w["wsl"] = str(w.get("service", "")) == "True" and sections.has("names")
	return w


## The lines of engine/doctor.sh: name=path-or-empty|version. Anything else (a greeting printed by a login shell)
## is not one of them.
static func parse_programs(text: String) -> Dictionary:
	var found := {}
	var name := RegEx.create_from_string("^[a-z][a-z0-9-]*$")
	for line in text.replace("\r", "").split("\n", false):
		var kv := line.split("=", true, 1)
		if kv.size() == 2 and name.search(kv[0]) != null and kv[1].contains("|"):
			var pv := kv[1].split("|")
			found[kv[0]] = {"path": pv[0], "version": pv[1]}
	return found


const PURPOSE := {
	"python3": "Runs the engine (3.10 or newer).",
	"tmux": "Keeps every session alive when the app closes.",
	"git": "Branches per session, review, connected repositories.",
	"ssh": "Connected repositories and cloud sandboxes.",
	"claude": "Claude Code, your own install and login.",
	"codex": "Codex CLI, your own install and login.",
	"flyctl": "Only for cloud sandboxes.",
}
const HOW := {
	"python3": "sudo apt install python3",
	"tmux": "sudo apt install tmux",
	"git": "sudo apt install git",
	"ssh": "sudo apt install openssh-client",
	"claude": "see code.claude.com/docs (Claude Code)",
	"codex": "see github.com/openai/codex",
	"flyctl": "see fly.io/docs/flyctl/install · the app looks in ~/.local/opt/flyctl and on your PATH",
}


static func _rung(id: String, name: String, required: bool, state: String, note: String, how := "") -> Dictionary:
	return {"id": id, "name": name, "required": required, "state": state, "note": note, "how": how}


## The ladder, from the ground up. `f` is what `read` gave ({} while the first reading is on its way); `connected`
## is whether the engine answers the app. Each rung: id, name, required, state, note, how.
## States: ok · no (missing or broken) · warn (it works; look at it) · wait (being read) · after (a rung below it
## must stand first, so nothing can be said yet).
static func ladder(f: Dictionary, connected: bool, windows := OS.get_name() == "Windows") -> Array:
	var rungs: Array = []
	var waiting := f.is_empty()
	var port := int(f.get("port", 8790))
	var below := "ok"  # what the rungs under this one allow: ok, or after
	if windows:
		var w: Dictionary = f.get("windows", {})
		var name := usable(w)
		var works := name != "" and f.has("linux") and int(f["linux"]["code"]) == 0
		# --- Windows itself
		if waiting:
			rungs.append(_rung("windows", "Windows", true, "wait", "Runs WSL, where the engine and your agents live."))
		elif w.has("unread"):
			rungs.append(_rung("windows", "Windows", true, "warn", "Could not be read: PowerShell did not answer. What follows was read another way."))
		elif works or (int(w["build"]) >= MIN_BUILD and (str(w.get("virt_firmware", "")) == "True" or str(w.get("hypervisor", "")) == "True")):
			rungs.append(_rung("windows", "Windows build %d" % int(w["build"]), true, "ok", "Virtualization is on: WSL 2 can run."))
		elif int(w["build"]) < MIN_BUILD:
			rungs.append(_rung("windows", "Windows build %d" % int(w["build"]), true, "no", "Too old for WSL 2, which needs Windows 10 version 2004 (build %d) or newer." % MIN_BUILD, "Update Windows."))
			below = "after"
		else:
			rungs.append(_rung("windows", "Windows build %d" % int(w["build"]), true, "no", "Virtualization is switched off in this computer's firmware. WSL 2 cannot run without it.", "Switch it on in the BIOS/UEFI setup (Intel VT-x or AMD-V). No program can do it for you."))
			below = "after"
		# --- WSL
		if waiting or below == "after":
			rungs.append(_rung("wsl", "WSL", true, "wait" if waiting else "after", "Microsoft's Linux inside Windows."))
		elif bool(w.get("wsl", false)):
			var v := str(w.get("version", ""))
			rungs.append(_rung("wsl", ("WSL " + v) if v != "" else "WSL", true, "ok", "Microsoft's Linux inside Windows." if v != "" else "An older WSL, built into Windows. « wsl --update » brings the current one."))
		else:
			rungs.append(_rung("wsl", "WSL", true, "no", "WSL is not installed.", "Once, in an administrator PowerShell: wsl --install · then restart Windows. It is Microsoft's own installer."))
			below = "after"
		# --- the distribution
		if waiting or below == "after":
			rungs.append(_rung("distro", "Linux distribution", true, "wait" if waiting else "after", "Where the engine, tmux and your agents run."))
		elif w.has("unread"):
			var named := str(f.get("linux", {}).get("found", {}).get("distro", {}).get("path", ""))
			if f.has("linux") and int(f["linux"]["code"]) == 0:
				rungs.append(_rung("distro", named if named != "" else "Linux distribution", true, "ok", "It answers."))
			else:
				rungs.append(_rung("distro", "Linux distribution", true, "no", "WSL's default distribution does not answer (exit %d)." % int(f.get("linux", {}).get("code", -1)), "In PowerShell: wsl -l -v shows what is there · wsl --install -d Ubuntu-24.04 adds one."))
				below = "after"
		elif name == "":
			var real: Array = w["names"].filter(func(n: String) -> bool: return not is_docker(n))
			if real.is_empty():
				rungs.append(_rung("distro", "Linux distribution", true, "no", "WSL has no Linux distribution yet.", "In PowerShell: wsl --install -d Ubuntu-24.04 · it asks you for a user name and a password."))
			else:
				rungs.append(_rung("distro", "Linux distribution", true, "no", "WSL's default distribution is %s, which is not a place to work in." % (str(w["default"]) if str(w["default"]) != "" else "not set"), "In PowerShell: wsl --set-default %s" % str(real[0])))
			below = "after"
		elif not works:
			rungs.append(_rung("distro", name, true, "no", "It does not answer (exit %d)." % int(f.get("linux", {}).get("code", -1)), "In PowerShell: wsl -d %s to see what it says · wsl --shutdown restarts WSL (it stops every session)." % name))
			below = "after"
		elif int(w["versions"].get(name, 2)) == 1:
			rungs.append(_rung("distro", name, true, "warn", "It runs on WSL 1: slower, and never tried with this app.", "In PowerShell: wsl --set-version %s 2" % name))
		else:
			rungs.append(_rung("distro", name, true, "ok", "WSL 2 · the engine, tmux and your agents run here."))
	var linux: Dictionary = f.get("linux", {})
	var found: Dictionary = linux.get("found", {})
	if not windows and not waiting and int(linux.get("code", 0)) != 0:
		rungs.append(_rung("shell", "bash", true, "no", "bash did not run the check (exit %d)." % int(linux["code"])))
		below = "after"
	# --- the programs: every missing one is shown at once
	var engine_can := true
	for p in REQUIRED + OPTIONAL:
		var required := REQUIRED.has(p)
		var got: Dictionary = found.get(p, {"path": "", "version": ""})
		var label := ("%s %s" % [p, str(got["version"])]).strip_edges()
		if waiting or below == "after":
			rungs.append(_rung(p, p, required, "wait" if waiting else "after", PURPOSE[p]))
			continue
		var ok := str(got["path"]) != ""
		if p == "python3" and ok and str(got["version"]) != "":
			var v := str(got["version"]).split(".")
			ok = int(v[0]) > 3 or (int(v[0]) == 3 and int(v[1]) >= 10)
		if ok:
			rungs.append(_rung(p, label, required, "ok", PURPOSE[p], str(got["path"])))
		else:
			rungs.append(_rung(p, label, required, "no", PURPOSE[p], HOW[p]))
			if p in ["python3", "tmux"]:
				engine_can = false
	# --- the engine
	var at := "127.0.0.1:%d" % port
	var engine_rung: Dictionary
	if waiting and not connected:
		engine_rung = _rung("engine", "The engine", true, "wait", "Starts and keeps your sessions.")
	elif connected:
		engine_rung = _rung("engine", "The engine", true, "ok", "It answers on %s." % at)
	elif below == "after" or not engine_can:
		engine_rung = _rung("engine", "The engine", true, "after", "Starts and keeps your sessions.")
	else:
		var process := str(found.get("engine-process", {}).get("path", "")) != ""
		var listens := str(found.get("engine-port", {}).get("path", "")) != ""
		if process and listens:
			engine_rung = _rung("engine", "The engine", true, "no", "It runs and listens on port %d, but the app cannot reach it%s." % [port, " from Windows" if windows else ""],
				"Check again. If it stays: WSL passes 127.0.0.1 on to Windows unless « localhostForwarding=false » is in your .wslconfig." if windows else "Check again.")
		elif process:
			engine_rung = _rung("engine", "The engine", true, "no", "It is starting, or stuck: its process is there and port %d is closed." % port, "Check again in a moment.")
		elif listens:
			engine_rung = _rung("engine", "The engine", true, "no", "Another program holds port %d." % port, "Close it, or start the app with AGMGD_PORT set to a free port.")
		else:
			engine_rung = _rung("engine", "The engine", true, "no", "It is not running.", "« Check again » starts it.")
			engine_rung["start"] = true
	# it goes after the programs it needs and before the optional ones
	rungs.insert(rungs.size() - OPTIONAL.size(), engine_rung)
	return rungs


## The package that brings each required program, in Ubuntu's and Debian's names.
const PACKAGE := {"python3": "python3", "tmux": "tmux", "git": "git", "ssh": "openssh-client"}


## The required programs that are missing and that the app can install on a click: only where the check ran and the
## distribution has apt-get. A python3 that is there but too old is not one of them: its package would not make it
## newer.
static func missing_packages(f: Dictionary) -> Array:
	var linux: Dictionary = f.get("linux", {})
	var found: Dictionary = linux.get("found", {})
	var out: Array = []
	if int(linux.get("code", 1)) != 0 or str(found.get("apt", {}).get("path", "")) == "":
		return out
	for p in REQUIRED:
		if str(found.get(p, {}).get("path", "")) == "":
			out.append(PACKAGE[p])
	return out


## The command that installs them, exactly as it is shown and run. Inside WSL it runs as the distribution's root,
## which needs no Windows administrator and no password; on Linux through sudo, which asks for the user's password in
## the terminal. engine/setup_install.sh refuses any name that is not one of the four packages.
static func install_argv(packages: Array, root: String, windows := OS.get_name() == "Windows") -> Array:
	var script := root.path_join("engine/setup_install.sh")
	return (["wsl.exe", "-u", "root", "-e", "bash", script] if windows else ["sudo", "bash", script]) + packages


static func gb(bytes: int) -> String:
	var v := bytes / 1073741824.0
	return ("%.1f" % v) if v < 10.0 else ("%d" % int(round(v)))


static func _line(label: String, text: String, warn := false) -> Dictionary:
	return {"label": label, "text": text, "warn": warn}


static func _span(seconds: float) -> String:
	if seconds < 3600.0:
		return "%d min" % int(seconds / 60.0)
	if seconds < 172800.0:
		return "%d h" % int(seconds / 3600.0)
	return "%d days" % int(seconds / 86400.0)


## The engine room: how the ground is doing. `f` is what `read` gave; `host` is the engine's answer to /host ({}
## when the engine does not answer: then only what Windows knows is said). Each line: label, text, warn.
static func engine_room(f: Dictionary, host: Dictionary, windows := OS.get_name() == "Windows") -> Array:
	var lines: Array = []
	var w: Dictionary = f.get("windows", {})
	var inside := " inside WSL" if bool(host.get("wsl", false)) else ""
	if host.is_empty():
		lines.append(_line("Memory, sessions", "The engine tells them, once it answers."))
	else:
		var m: Dictionary = host["memory"]
		var text := "%s of %s GB used%s" % [gb(int(m["used"])), gb(int(m["total"])), inside]
		if int(w.get("ram", 0)) > 0:
			text += " · this computer has %s GB" % gb(int(w["ram"]))
		if int(m["swap_used"]) > 104857600:
			text += " · %s GB of swap in use" % gb(int(m["swap_used"]))
		lines.append(_line("Memory", text + ".", int(m["total"]) > 0 and float(m["available"]) / float(m["total"]) < 0.08))
		var ss: Array = host.get("sessions", [])
		if ss.is_empty():
			lines.append(_line("Sessions", "None is running."))
		else:
			var top := []
			for x in ss.slice(0, 3):
				top.append("%s %s GB" % [str(x["name"]), gb(int(x["bytes"]))])
			var each := int(host["sessions_bytes"]) / ss.size()
			var more := int(m["available"]) / maxi(each, 1)
			lines.append(_line("Sessions", "%d running, about %s GB together: %s%s. %s" % [ss.size(), gb(int(host["sessions_bytes"])), ", ".join(top), " and others" if ss.size() > 3 else "",
				("About %d more of that weight would fit in the memory that is free." % more) if more >= 1 else "There is no room left for one more of that weight."], more < 1))
	# --- the disk: on Windows, the distribution's disk is one file on a Windows drive, and that drive's room is the true one
	var name := str(host.get("distro", "")) if str(host.get("distro", "")) != "" else usable(w)
	var d: Dictionary = w.get("disks", {}).get(name, {})
	var linux_free := ("Linux reports %s GB free. " % gb(int(host["disk"]["free"]))) if not host.is_empty() else ""
	if not d.is_empty() and int(d["total"]) > 0:
		var full := int(round(100.0 * (1.0 - float(d["free"]) / float(d["total"]))))
		lines.append(_line("Disk", "%sIts disk is a %s GB file on %s, where %s GB are free (%d %% full): that is the true room." % [linux_free, gb(int(d["file"])), str(d["drive"]), gb(int(d["free"])), full],
			full >= 90 or int(d["free"]) < 21474836480))
	elif not host.is_empty():
		var disk: Dictionary = host["disk"]
		lines.append(_line("Disk", "%s GB free of %s." % [gb(int(disk["free"])), gb(int(disk["total"]))], int(disk["total"]) > 0 and float(disk["free"]) / float(disk["total"]) < 0.1))
	var on_win: Array = host.get("on_windows_disk", [])
	if not on_win.is_empty():
		var letters := {}
		for x in on_win:
			letters[str(x["drive"]).to_upper() + ":"] = true
		lines.append(_line("Folders", "%d of %d sessions work in a folder on the Windows disk (%s): git is slower there than in a folder inside Linux." % [on_win.size(), host.get("sessions", []).size(), ", ".join(letters.keys())]))
	if windows and w.has("wslconfig"):
		var c: Dictionary = w["wslconfig"]
		if not bool(c["present"]):
			lines.append(_line("Limits", "No .wslconfig: WSL's defaults apply (it may take up to half of this computer's memory)."))
		elif c["lines"].is_empty():
			lines.append(_line("Limits", "Your .wslconfig sets no limit on memory, processors or swap."))
		else:
			lines.append(_line("Limits", "From your .wslconfig: %s." % " · ".join(c["lines"])))
	if not host.is_empty() and float(host.get("uptime", 0.0)) > 0.0:
		lines.append(_line("Up for", _span(float(host["uptime"])) + ("" if inside == "" else " (WSL)") + "."))
	return lines


## One sentence for the whole ladder.
static func verdict(rungs: Array) -> String:
	if rungs.any(func(r: Dictionary) -> bool: return r["state"] == "wait"):
		return "Looking…"
	for r in rungs:
		if r["required"] and r["state"] == "no":
			if rungs.any(func(x: Dictionary) -> bool: return x["state"] == "after"):
				return "Start with the first ✗: the lines marked · can only be read once it stands."
			return "Start with the first ✗."
	if rungs.any(func(r: Dictionary) -> bool: return r["state"] == "warn"):
		return "Everything needed is there. One line deserves a look (!)."
	return "Everything needed is there."
