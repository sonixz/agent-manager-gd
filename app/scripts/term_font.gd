class_name TermFont
## The terminal font: JetBrains Mono (bundled, OFL) and system fallbacks for symbols, CJK and colour emoji.

static func make() -> Font:
	var main := FontFile.new()
	main.load_dynamic_font("res://assets/fonts/JetBrainsMonoNL-Regular.ttf")
	var fb: Array[Font] = []
	for names in [["Cascadia Mono", "DejaVu Sans Mono"], ["Segoe UI Symbol", "DejaVu Sans"], ["Yu Gothic", "Noto Sans CJK JP"],
			["Malgun Gothic", "Noto Sans CJK KR"], ["Segoe UI Emoji", "Noto Color Emoji"]]:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(names)
		fb.append(f)
	# WSL development: fontconfig does not see the Windows fonts; read them directly when present.
	if OS.get_name() != "Windows" and DirAccess.dir_exists_absolute("/mnt/c/Windows/Fonts"):
		for file in ["seguisym.ttf", "YuGothR.ttc", "malgun.ttf", "seguiemj.ttf"]:
			var ff := FontFile.new()
			if ff.load_dynamic_font("/mnt/c/Windows/Fonts/" + file) == OK:
				fb.append(ff)
	main.fallbacks = fb
	return main
