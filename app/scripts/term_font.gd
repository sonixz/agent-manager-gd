class_name TermFont
## The terminal font: JetBrains Mono (bundled, OFL) and system fallbacks for symbols, CJK and colour emoji.

static func make() -> Font:
	# the imported resource (a release build has no raw .ttf inside); its own copy, as the fallbacks are set on it
	var main := (load("res://assets/fonts/JetBrainsMonoNL-Regular.ttf") as FontFile).duplicate() as FontFile
	# the same rendering as a font loaded from the raw file (the import's defaults differ)
	main.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	main.hinting = TextServer.HINTING_LIGHT
	main.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	main.keep_rounding_remainders = true
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
