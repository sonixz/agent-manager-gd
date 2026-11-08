// VtTerminal: a terminal Control for Godot. libghostty-vt keeps the terminal state; this node owns the
// pseudo-terminal, draws the grid with Godot (theme font and colours) and encodes keys, mouse, paste and focus.
#pragma once

#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

extern "C" {
#include <ghostty/vt.h>
}

namespace godot {

class VtTerminal : public Control {
	GDCLASS(VtTerminal, Control)

public:
	VtTerminal();
	~VtTerminal();

	void _ready() override;
	void _process(double delta) override;
	void _draw() override;
	void _gui_input(const Ref<InputEvent> &event) override;
	void _notification(int what);

	bool start(const String &program, const PackedStringArray &args, const String &cwd, const PackedStringArray &env);
	void feed(const PackedByteArray &data);          // VT bytes into the terminal (tests, replays)
	void write_input(const PackedByteArray &data);   // bytes to the program
	void paste_text(const String &text);             // bracketed when the program asked for it
	String get_selection_text() const;
	bool is_running() const { return pid > 0; }
	int get_cols() const { return cols; }
	int get_rows() const { return rows; }
	Vector2 get_cell_size() const { return Vector2(cell_w, cell_h); }
	double get_last_draw_ms() const { return last_draw_ms; }
	int get_draw_count() const { return draw_count; }

	void set_font(const Ref<Font> &f);
	Ref<Font> get_font() const { return font; }
	void set_font_size(int s);
	int get_font_size() const { return font_size; }
	void set_palette(const PackedColorArray &p);     // 16 ANSI colours from the theme
	PackedColorArray get_palette() const { return palette16; }
	void set_foreground(const Color &c);
	Color get_foreground() const { return fg_default; }
	void set_background(const Color &c);
	Color get_background() const { return bg_default; }

	void _on_write_pty(const uint8_t *data, size_t len);
	void _on_bell();
	void _on_title();

protected:
	static void _bind_methods();

private:
	GhosttyTerminal term = nullptr;
	GhosttyRenderState rstate = nullptr;
	GhosttyRenderStateRowIterator rows_it = nullptr;
	GhosttyRenderStateRowCells cells = nullptr;
	GhosttyKeyEncoder keys = nullptr;
	GhosttyMouseEncoder mouse = nullptr;

	int pty_fd = -1;
	int pid = -1;
	int cols = 80, rows = 24;
	float cell_w = 9, cell_h = 18, ascent = 14;
	bool needs_redraw = true;
	bool focused = false;
	bool mouse_pressed = false;
	bool selecting = false;
	Vector2i sel_anchor;
	double blink_t = 0.0;
	bool blink_on = true;
	double last_draw_ms = 0.0;
	int draw_count = 0;

	Ref<Font> font;
	int font_size = 15;
	PackedColorArray palette16;
	Color fg_default = Color(0.85, 0.87, 0.9);
	Color bg_default = Color(0.08, 0.09, 0.11);

	void _apply_size();
	void _apply_colors();
	void _pump();
	bool _mode(GhosttyMode m) const;
	void _send(const uint8_t *data, size_t len);
	bool _mouse_report(const Ref<InputEvent> &event);
	void _select_to(const Vector2 &pos, bool start);
	Vector2i _cell_at(const Vector2 &pos) const;
	bool _draw_box(char32_t cp, const Rect2 &r, const Color &c);
};

} // namespace godot
