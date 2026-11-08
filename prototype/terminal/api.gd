extends SceneTree
func _init() -> void:
	for c in ["Terminal", "PTY"]:
		print("== ", c, " exists=", ClassDB.class_exists(c), " parent=", ClassDB.get_parent_class(c))
		for m in ClassDB.class_get_method_list(c, true):
			var args := []
			for a in m["args"]:
				args.append(a["name"])
			print("  m ", m["name"], "(", ", ".join(args), ")")
		for p in ClassDB.class_get_property_list(c, true):
			print("  p ", p["name"], " t=", p["type"])
		for s in ClassDB.class_get_signal_list(c, true):
			print("  s ", s["name"])
		for k in ClassDB.class_get_integer_constant_list(c, true):
			print("  k ", k)
	quit()
