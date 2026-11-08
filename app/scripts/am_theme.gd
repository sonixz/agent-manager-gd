class_name AmTheme
## The app's look: the Second Brain's seven palettes (same owner, same roles) and a few style tokens, for the
## interface and the terminal. Roles: BG/PANEL surfaces, FOREST(_LIGHT) primary, MINT accent, WARM second accent.

const THEMES := ["focus", "terminal", "neon", "evening", "forest", "morning", "paper"]
const LABELS := {"morning": "Morning", "focus": "Focus", "evening": "Evening", "forest": "Forest",
	"terminal": "Terminal", "paper": "Paper", "neon": "Neon"}

const PALETTES := {
	# Soft, felted blue: calm, cosy, not too dark. Sunrise peach as second accent.
	"morning": {"BG": "2b3c54", "BG_2": "31445e", "PANEL": "33475f", "PANEL_2": "3b5270", "BORDER": "4b6483",
		"FOREST": "3e6189", "FOREST_LIGHT": "79a5d3", "MINT": "a9d4ff", "MINT_SOFT": "d9edff", "WARM": "ffd2a1",
		"TEXT": "f1f6fc", "MUTED": "b5c6da", "FAINT": "8196ae", "WARN": "ffd27a", "ERROR": "ff9d9d",
		"INFO": "a6dcff", "ON_ACCENT": "13233a"},
	# Deeper night-blue with aqua: concentration.
	"focus": {"BG": "172331", "BG_2": "1b293a", "PANEL": "1f2f42", "PANEL_2": "263a51", "BORDER": "33506d",
		"FOREST": "2b5a7a", "FOREST_LIGHT": "5596bb", "MINT": "8fe3ef", "MINT_SOFT": "c9f4f9", "WARM": "c8b6ff",
		"TEXT": "e8f1f7", "MUTED": "9fb6c8", "FAINT": "617c92", "WARN": "f5cf74", "ERROR": "ff8f8f",
		"INFO": "93cff5", "ON_ACCENT": "0d1d26"},
	# Dusk indigo with amber: winding down.
	"evening": {"BG": "29233f", "BG_2": "2f2846", "PANEL": "352d4f", "PANEL_2": "3e355c", "BORDER": "554a78",
		"FOREST": "5b4a8c", "FOREST_LIGHT": "9483c9", "MINT": "ffc296", "MINT_SOFT": "ffe2cc", "WARM": "ffa9c6",
		"TEXT": "f6f0fb", "MUTED": "c6bad8", "FAINT": "8c80a6", "WARN": "ffd27a", "ERROR": "ff9a9a",
		"INFO": "b9c8ff", "ON_ACCENT": "2a1a14"},
	# The original Loop 0 identity.
	"forest": {"BG": "0a1310", "BG_2": "0d1914", "PANEL": "0f1d18", "PANEL_2": "14271f", "BORDER": "1f3a2f",
		"FOREST": "1e6b4c", "FOREST_LIGHT": "2f8f68", "MINT": "5ef2b0", "MINT_SOFT": "a8f7d3", "WARM": "f4d58d",
		"TEXT": "e4f1ea", "MUTED": "88a598", "FAINT": "4f6b5f", "WARN": "f4c35a", "ERROR": "ff6f6f",
		"INFO": "7cc8ff", "ON_ACCENT": "06110c"},
	# Green phosphor on black, amber for ideas: an old terminal.
	"terminal": {"BG": "0a0e0b", "BG_2": "0d130f", "PANEL": "101813", "PANEL_2": "15201a", "BORDER": "2a4233",
		"FOREST": "1d5a35", "FOREST_LIGHT": "3fa462", "MINT": "7dfa9b", "MINT_SOFT": "c2ffd1", "WARM": "ffb454",
		"TEXT": "d4f5dc", "MUTED": "8fb79b", "FAINT": "5c7a66", "WARN": "ffcc66", "ERROR": "ff7070",
		"INFO": "74d4ff", "ON_ACCENT": "04120a"},
	# The light one: warm paper, ink blue, rust for ideas. Accents are dark here (they are read on paper).
	"paper": {"BG": "efe9dc", "BG_2": "e7e0d0", "PANEL": "f8f4ea", "PANEL_2": "efe8d9", "BORDER": "cfc4ad",
		"FOREST": "b9c7d6", "FOREST_LIGHT": "5b7fa6", "MINT": "2a5d8f", "MINT_SOFT": "1d4670", "WARM": "a4521c",
		"TEXT": "26221c", "MUTED": "5f574a", "FAINT": "8a806e", "WARN": "8a5a00", "ERROR": "a8281f",
		"INFO": "1f6596", "ON_ACCENT": "fbf8f0"},
	# Night city: deep violet, hot pink and cyan.
	"neon": {"BG": "150f24", "BG_2": "1a132c", "PANEL": "1f1734", "PANEL_2": "281e42", "BORDER": "4a3577",
		"FOREST": "5a2a7a", "FOREST_LIGHT": "b45cff", "MINT": "ff5fc8", "MINT_SOFT": "ffb3e6", "WARM": "48e5ff",
		"TEXT": "f5eeff", "MUTED": "c3b2e3", "FAINT": "8572aa", "WARN": "ffd166", "ERROR": "ff6b8b",
		"INFO": "6fe6ff", "ON_ACCENT": "1a0820"},
}

## Style tokens per theme (from the Brain): corners, borders, the interface font.
const STYLES := {
	"terminal": {"radius": 0.0, "border": 1.0, "mono_ui": true},
	"paper": {"radius": 0.6, "border": 1.0},
	"neon": {"radius": 1.3, "border": 1.5},
}

static var current := "focus"
static var c := {}  # role -> Color


static func apply(name: String) -> void:
	current = name if PALETTES.has(name) else "focus"
	c.clear()
	for k in PALETTES[current]:
		c[k] = Color(str(PALETTES[current][k]))


static func col(role: String) -> Color:
	return c.get(role, Color.MAGENTA)


static func style(key: String, default: Variant) -> Variant:
	return (STYLES.get(current, {}) as Dictionary).get(key, default)


static func is_light() -> bool:
	return col("BG").get_luminance() > 0.5


static func r(px: float) -> int:
	return roundi(px * float(style("radius", 1.0)))


static func box(bg: Color, radius := 10, border := Color(0, 0, 0, 0), bw := 0, pad := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(r(radius))
	s.border_color = border
	s.set_border_width_all(0 if bw == 0 else maxi(1, roundi(bw * float(style("border", 1.0)))))
	s.set_content_margin_all(pad)
	s.anti_aliasing = true
	return s


static func ui_font(weight := 400) -> Font:
	var f := SystemFont.new()
	if style("mono_ui", false):
		f.font_names = PackedStringArray(["Cascadia Mono", "Consolas", "JetBrains Mono", "DejaVu Sans Mono"])
	else:
		f.font_names = PackedStringArray(["Segoe UI Variable Text", "Segoe UI", "Inter", "Ubuntu", "DejaVu Sans"])
	f.font_weight = weight
	return f


## The terminal's 16 ANSI colours: recognisable hues tuned to the theme (darker on a light theme).
static func ansi() -> PackedColorArray:
	var green := col("MINT") if current in ["terminal", "forest"] else Color("7dd3a8")
	var base := [col("PANEL_2"), col("ERROR"), green, col("WARN"), col("INFO"), Color("c8a2ff"), Color("5fd4dd"), col("MUTED"),
		col("FAINT"), col("ERROR").lightened(0.2), green.lightened(0.2), col("WARN").lightened(0.2), col("INFO").lightened(0.2),
		Color("dcc4ff"), Color("8eecf0"), col("TEXT")]
	var out := PackedColorArray()
	for i in base.size():
		var x: Color = base[i]
		if is_light() and i not in [0, 7, 8, 15]:
			x = x.darkened(0.45)
		out.append(x)
	if is_light():
		out[0] = col("TEXT")
		out[7] = col("MUTED")
		out[8] = col("FAINT")
		out[15] = col("TEXT").darkened(0.2)
	return out


static func build() -> Theme:
	var t := Theme.new()
	t.default_font = ui_font()
	t.default_font_size = 14
	t.set_color("font_color", "Label", col("TEXT"))
	t.set_stylebox("normal", "Button", box(col("PANEL_2"), 8, col("BORDER"), 1, 9))
	t.set_stylebox("hover", "Button", box(col("PANEL_2").lightened(0.04), 8, col("FOREST_LIGHT"), 1, 9))
	t.set_stylebox("pressed", "Button", box(col("PANEL_2").lightened(0.07), 8, col("MINT"), 1, 9))
	t.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), 8, Color(col("MINT"), 0.6), 1, 9))
	t.set_stylebox("disabled", "Button", box(col("PANEL"), 8, col("BORDER"), 1, 9))
	for k in ["font_color", "font_pressed_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(k, "Button", col("TEXT"))
	t.set_color("font_disabled_color", "Button", col("FAINT"))
	for k in ["icon_normal_color", "icon_pressed_color", "icon_hover_color", "icon_focus_color"]:
		t.set_color(k, "Button", col("TEXT"))
	t.set_stylebox("normal", "LineEdit", box(col("BG"), 6, col("BORDER"), 1, 8))
	t.set_stylebox("focus", "LineEdit", box(col("BG"), 6, col("MINT"), 1, 8))
	t.set_color("font_color", "LineEdit", col("TEXT"))
	t.set_color("font_placeholder_color", "LineEdit", col("FAINT"))
	t.set_color("caret_color", "LineEdit", col("MINT"))
	t.set_color("selection_color", "LineEdit", Color(col("MINT"), 0.3))
	t.set_stylebox("normal", "OptionButton", box(col("PANEL_2"), 6, col("BORDER"), 1, 8))
	t.set_stylebox("hover", "OptionButton", box(col("PANEL_2").lightened(0.04), 6, col("FOREST_LIGHT"), 1, 8))
	t.set_color("font_color", "OptionButton", col("TEXT"))
	t.set_stylebox("panel", "AcceptDialog", box(col("PANEL"), 10, col("BORDER"), 1, 16))
	t.set_stylebox("panel", "PopupPanel", box(col("PANEL"), 12, col("BORDER"), 1, 10))
	t.set_stylebox("panel", "PopupMenu", box(col("PANEL_2"), 6, col("BORDER"), 1, 6))
	t.set_stylebox("hover", "PopupMenu", box(Color(col("MINT"), 0.15), 4, Color(0, 0, 0, 0), 0, 6))
	t.set_color("font_color", "PopupMenu", col("TEXT"))
	t.set_color("font_hover_color", "PopupMenu", col("TEXT"))
	t.set_stylebox("panel", "ItemList", box(col("BG"), 8, col("BORDER"), 1, 6))
	t.set_stylebox("selected", "ItemList", box(Color(col("MINT"), 0.18), 4, Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("selected_focus", "ItemList", box(Color(col("MINT"), 0.22), 4, Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("hovered", "ItemList", box(Color(col("TEXT"), 0.05), 4, Color(0, 0, 0, 0), 0, 4))
	t.set_color("font_color", "ItemList", col("TEXT"))
	t.set_color("font_selected_color", "ItemList", col("TEXT"))
	# dialog windows: the frame and title bar take the theme too (Godot's default is a grey frame)
	var frame := box(col("PANEL"), 12, col("BORDER"), 1, 0)
	frame.expand_margin_top = 34
	frame.expand_margin_left = 6
	frame.expand_margin_right = 6
	frame.expand_margin_bottom = 6
	frame.shadow_color = Color(0, 0, 0, 0.35)
	frame.shadow_size = 18
	t.set_stylebox("embedded_border", "Window", frame)
	t.set_stylebox("embedded_unfocused_border", "Window", frame)
	t.set_color("title_color", "Window", col("TEXT"))
	t.set_font("title_font", "Window", ui_font(650))
	t.set_constant("title_height", "Window", 32)
	t.set_stylebox("panel", "TooltipPanel", box(col("PANEL_2"), 6, col("BORDER"), 1, 8))
	t.set_color("font_color", "TooltipLabel", col("TEXT"))
	t.set_color("font_color", "CheckBox", col("TEXT"))
	return t
