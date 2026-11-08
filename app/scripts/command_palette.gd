class_name CommandPalette
extends PopupPanel
## Ctrl+Shift+K (or Ctrl+K outside a terminal): type a few letters, Enter runs the first match.
## Items are {"label", "hint", "run": Callable}; main fills them each time it opens.

var edit: LineEdit
var list: ItemList
var items: Array = []
var shown: Array = []


func _init() -> void:
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(560, 380)
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	edit = LineEdit.new()
	edit.placeholder_text = "Go to a session, run a command…"
	edit.add_theme_font_size_override("font_size", 16)
	v.add_child(edit)
	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.add_theme_font_size_override("font_size", 14)
	v.add_child(list)
	edit.text_changed.connect(_filter)
	edit.text_submitted.connect(func(_t: String) -> void: _run(0 if list.get_selected_items().is_empty() else list.get_selected_items()[0]))
	edit.gui_input.connect(_keys)
	list.item_activated.connect(_run)


func open(new_items: Array) -> void:
	items = new_items
	edit.text = ""
	_filter("")
	popup_centered()
	edit.grab_focus()


func _keys(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and list.item_count > 0:
		var cur := 0 if list.get_selected_items().is_empty() else list.get_selected_items()[0]
		if e.keycode == KEY_DOWN:
			list.select(mini(cur + 1, list.item_count - 1))
			list.ensure_current_is_visible()
			edit.accept_event()
		elif e.keycode == KEY_UP:
			list.select(maxi(cur - 1, 0))
			list.ensure_current_is_visible()
			edit.accept_event()


## Letters in order, not necessarily together ("bt" finds "Brain themes"); earlier, tighter matches first.
static func score(text: String, query: String) -> int:
	if query == "":
		return 1
	var t := text.to_lower()
	var q := query.to_lower()
	if t.contains(q):
		return 1000 - t.find(q)
	var pos := -1
	var gaps := 0
	for ch in q:
		var at := t.find(ch, pos + 1)
		if at < 0:
			return 0
		gaps += at - pos - 1
		pos = at
	return maxi(1, 500 - gaps)


func _filter(q: String) -> void:
	var scored := []
	for it in items:
		var sc := score(str(it["label"]) + " " + str(it.get("hint", "")), q)
		if sc > 0:
			scored.append([sc, it])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	shown = scored.map(func(x): return x[1])
	list.clear()
	for it in shown:
		list.add_item("%s      %s" % [it["label"], it.get("hint", "")])
	if list.item_count > 0:
		list.select(0)


func _run(i: int) -> void:
	if i < 0 or i >= shown.size():
		return
	hide()
	(shown[i]["run"] as Callable).call()
