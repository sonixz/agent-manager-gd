extends "res://tools/capture_base.gd"
## The showcase video V5: the Second Brain side, filmed (Godot's movie mode) in a COPY of Second Brain GD with its
## English showcase Brain in a temporary home. The archivist is the real one (SBGD_ASSISTANT_PROVIDER=openai, the
## key from the environment through dotenvx). It waits for a proposal from an Agent Manager session, opens the AI
## tools window, approves it with the window's own button, lets the archivist file it, shows the item, then the
## timeline of who did what. Copied into <copy>/tools/ by video-production/scripts/film_v5.sh.
## Environment: SBGD_READY (a file written when the Brain is open), SBGD_MARKS (« mark <name> <frame> » lines).

var marks_path := ""


func _mark(name: String) -> void:
	var line := "mark %s %d" % [name, Engine.get_frames_drawn()]
	print(line)
	if marks_path != "":
		var f := FileAccess.open(marks_path, FileAccess.READ_WRITE if FileAccess.file_exists(marks_path) else FileAccess.WRITE)
		f.seek_end()
		f.store_line(line)
		f.close()


func _run() -> void:
	OS.set_environment("SBGD_ASSISTANT_PROVIDER", "openai")   # the real archivist, not the scripted stand-in
	marks_path = OS.get_environment("SBGD_MARKS")
	boot_env()
	if not await open_brain():
		quit(1)
		return
	var ready := FileAccess.open(OS.get_environment("SBGD_READY"), FileAccess.WRITE)
	ready.store_string("open")
	ready.close()
	_mark("ready")
	var lights: Button = b.get("mcp_lights")
	# the Brain at rest while the agent works; the « in » light shows its calls
	var pid := ""
	var title := ""
	var deadline := Time.get_ticks_msec() + 900000
	while Time.get_ticks_msec() < deadline:
		var r: Dictionary = await app.backend.api.call_api("/mcp/proposals", true)
		var rows: Array = (r.get("data", {}) as Dictionary).get("proposals", []) if r.get("ok", false) else []
		for p in rows:
			if str((p as Dictionary).get("client_name", "")).begins_with("Agent Manager"):
				pid = str(p["id"])
				title = str(((p as Dictionary).get("payload", {}) as Dictionary).get("title", ""))
		if pid != "":
			break
		await lights.call("poll")
		await pause(1.0)
	if pid == "":
		push_error("brain_film: no proposal from Agent Manager")
		quit(1)
		return
	_mark("proposal")
	await lights.call("poll")
	var dlg: AcceptDialog = lights.call("open_dialog")
	await pause(3.5)
	_mark("dialog")
	var approve: Button = null
	for bt in dlg.find_children("*", "Button", true, false):
		if (bt as Button).text == I18n.t("Approve") and approve == null:
			approve = bt
	if approve == null:
		push_error("brain_film: no Approve button")
	else:
		# the waiting proposal sits under the list of keys: scroll the window to it, let it be read, then approve
		var sc: Node = approve.get_parent()
		while sc != null and not (sc is ScrollContainer):
			sc = sc.get_parent()
		if sc != null:
			(sc as ScrollContainer).ensure_control_visible(approve)
		await pause(2.5)
		_mark("waiting")
		approve.pressed.emit()
	_mark("approved")
	# the archivist files it (a real model call): wait for the proposal to be applied
	deadline = Time.get_ticks_msec() + 180000
	var item := ""
	var note_id := ""
	while Time.get_ticks_msec() < deadline:
		var r2: Dictionary = await app.backend.api.call_api("/mcp/proposals?status=all", true)
		for p in (r2.get("data", {}) as Dictionary).get("proposals", []) if r2.get("ok", false) else []:
			if str((p as Dictionary).get("id", "")) == pid and str(p.get("status", "")) in ["applied", "failed", "rejected"]:
				item = str(p.get("status", ""))
				note_id = str(p.get("note_id", ""))
		if item != "":
			break
		await pause(0.5)
	print("brain_film: proposal %s" % item)
	await pause(3.0)
	_mark("filed")
	dlg.hide()
	await b.call("refresh_graph")
	await pause(1.5)
	await settle()
	# the archivist renamed it: find it by its id (the graph's key ends with it), else by the proposed title
	var node := ""
	for k in g.nodes:
		if note_id != "" and str(k).ends_with(note_id):
			node = str(k)
	if node == "":
		node = g.find_node(title)
	print("brain_film: item %s node %s" % [note_id, node])
	if node != "":
		g.zoom_level("read", node)
	await pause(4.0)
	_mark("item")
	var tl: AcceptDialog = lights.call("open_timeline")
	await pause(4.0)
	_mark("timeline")
	tl.hide()
	_mark("end")
	# stays open (its engine answering Agent Manager) until the other film is over: SBGD_HOLD appears, or 10 minutes
	var hold := OS.get_environment("SBGD_HOLD")
	var until := Time.get_ticks_msec() + 600000
	while hold != "" and not FileAccess.file_exists(hold) and Time.get_ticks_msec() < until:
		await pause(1.0)
	await pause(0.5)
	await finish()
