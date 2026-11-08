#include "vt_terminal.h"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/input_event_mouse_button.hpp>
#include <godot_cpp/classes/input_event_mouse_motion.hpp>
#include <godot_cpp/classes/theme_db.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <string>
#include <cstring>
#include <vector>

#ifdef _WIN32
#include "vt_terminal_win.inc"
#else
#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace godot;

// ------------------------------------------------------------------ callbacks from libghostty-vt
static void cb_write_pty(GhosttyTerminal, void *ud, const uint8_t *data, size_t len) {
	static_cast<VtTerminal *>(ud)->_on_write_pty(data, len);
}
static void cb_bell(GhosttyTerminal, void *ud) { static_cast<VtTerminal *>(ud)->_on_bell(); }
static void cb_title(GhosttyTerminal, void *ud) { static_cast<VtTerminal *>(ud)->_on_title(); }

static const uint32_t XTERM16[16] = {0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
	0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea};

VtTerminal::VtTerminal() {
	for (uint32_t c : XTERM16) {
		palette16.push_back(Color(((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0));
	}
	ghostty_terminal_new(nullptr, &term, cols, rows);
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, this);
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)cb_write_pty);
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_BELL, (const void *)cb_bell);
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void *)cb_title);
	uint64_t max_lines = 10000;
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &max_lines);
	ghostty_render_state_new(nullptr, &rstate);
	ghostty_render_state_row_iterator_new(nullptr, &rows_it);
	ghostty_render_state_row_cells_new(nullptr, &cells);
	ghostty_key_encoder_new(nullptr, &keys);
	ghostty_mouse_encoder_new(nullptr, &mouse);
	set_focus_mode(FOCUS_ALL);
	set_clip_contents(true);
	set_process(true);
	_apply_colors();
}

VtTerminal::~VtTerminal() {
#ifdef _WIN32
	_win_close();
#else
	if (pid > 0) {
		kill(pid, SIGHUP);
		waitpid(pid, nullptr, WNOHANG);
	}
	if (pty_fd >= 0) close(pty_fd);
#endif
	ghostty_mouse_encoder_free(mouse);
	ghostty_key_encoder_free(keys);
	ghostty_render_state_row_cells_free(cells);
	ghostty_render_state_row_iterator_free(rows_it);
	ghostty_render_state_free(rstate);
	ghostty_terminal_free(term);
}

void VtTerminal::_ready() {
	if (font.is_null()) font = ThemeDB::get_singleton()->get_fallback_font();
	_apply_size();
}

void VtTerminal::_notification(int what) {
	switch (what) {
		case NOTIFICATION_RESIZED: _apply_size(); break;
		case NOTIFICATION_FOCUS_ENTER:
		case NOTIFICATION_FOCUS_EXIT: {
			focused = what == NOTIFICATION_FOCUS_ENTER;
			if (_mode(GHOSTTY_MODE_FOCUS_EVENT)) {
				uint8_t buf[8];
				size_t n = 0;
				if (ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, buf, sizeof(buf), &n) == GHOSTTY_SUCCESS) _send(buf, n);
			}
			needs_redraw = true;
		} break;
	}
}

// ------------------------------------------------------------------ process
bool VtTerminal::start(const String &program, const PackedStringArray &args, const String &cwd, const PackedStringArray &env) {
#ifdef _WIN32
	if (win) return false;
	win = win_start(program, args, cwd, env, cols, rows);
	if (!win) return false;
	pid = (int)win_pid(win);
	return true;
#else
	if (pid > 0) return false;
	struct winsize ws = {(unsigned short)rows, (unsigned short)cols, (unsigned short)(cols * cell_w), (unsigned short)(rows * cell_h)};
	std::vector<std::string> argv_s;
	argv_s.push_back(program.utf8().get_data());
	for (const String &a : args) argv_s.push_back(a.utf8().get_data());
	std::vector<std::string> env_s;
	for (const String &e : env) env_s.push_back(e.utf8().get_data());
	std::string cwd_s = cwd.utf8().get_data();
	int master = -1;
	pid_t child = forkpty(&master, nullptr, nullptr, &ws);
	if (child < 0) return false;
	if (child == 0) {
		for (auto &e : env_s) putenv(strdup(e.c_str()));
		if (!cwd_s.empty() && chdir(cwd_s.c_str()) != 0) _exit(126);
		std::vector<char *> argv;
		for (auto &a : argv_s) argv.push_back(const_cast<char *>(a.c_str()));
		argv.push_back(nullptr);
		execvp(argv[0], argv.data());
		_exit(127);
	}
	fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
	pty_fd = master;
	pid = child;
	return true;
#endif
}

void VtTerminal::_pump() {
#ifdef _WIN32
	if (!win) return;
	std::string chunk;
	bool ended = false;
	int code = -1;
	win_drain(win, chunk, ended, code);
	if (!chunk.empty()) {
		ghostty_terminal_vt_write(term, (const uint8_t *)chunk.data(), chunk.size());
		needs_redraw = true;
		emit_signal("output_received", (int64_t)chunk.size());
	}
	if (ended) {
		_win_close();
		pid = -1;
		emit_signal("exited", code);
	}
#else
	if (pty_fd < 0) return;
	uint8_t buf[65536];
	size_t total = 0;
	while (total < (1u << 22)) {  // at most 4 MiB a frame, the rest next frame
		ssize_t n = read(pty_fd, buf, sizeof(buf));
		if (n > 0) {
			ghostty_terminal_vt_write(term, buf, (size_t)n);
			total += (size_t)n;
			continue;
		}
		if (n < 0 && (errno == EAGAIN || errno == EINTR)) break;
		// EOF or EIO: the program ended
		int status = 0;
		waitpid(pid, &status, 0);
		close(pty_fd);
		pty_fd = -1;
		pid = -1;
		emit_signal("exited", WIFEXITED(status) ? WEXITSTATUS(status) : -1);
		break;
	}
	if (total > 0) {
		needs_redraw = true;
		emit_signal("output_received", (int64_t)total);
	}
#endif
}

void VtTerminal::_process(double delta) {
	_pump();
	blink_t += delta;
	if (blink_t > 0.6) {
		blink_t = 0;
		blink_on = !blink_on;
		if (focused) needs_redraw = true;
	}
	if (needs_redraw) {
		needs_redraw = false;
		queue_redraw();
	}
}

void VtTerminal::_send(const uint8_t *data, size_t len) {
	if (len == 0) return;
	PackedByteArray p;
	p.resize(len);
	memcpy(p.ptrw(), data, len);
	emit_signal("input_sent", p);
#ifdef _WIN32
	if (win) win_write(win, data, len);
#else
	if (pty_fd >= 0) {
		size_t off = 0;
		while (off < len) {
			ssize_t n = write(pty_fd, data + off, len - off);
			if (n > 0) off += (size_t)n;
			else if (n < 0 && errno == EAGAIN) usleep(1000);
			else break;
		}
	}
#endif
}

#ifdef _WIN32
void VtTerminal::_win_close() {
	if (win) win_close(win);
	win = nullptr;
}
#endif

void VtTerminal::_on_write_pty(const uint8_t *data, size_t len) { _send(data, len); }
void VtTerminal::_on_bell() { emit_signal("bell"); }
void VtTerminal::_on_title() { emit_signal("title_changed"); }

void VtTerminal::feed(const PackedByteArray &data) {
	ghostty_terminal_vt_write(term, data.ptr(), data.size());
	needs_redraw = true;
}

void VtTerminal::write_input(const PackedByteArray &data) { _send(data.ptr(), data.size()); }

bool VtTerminal::_mode(GhosttyMode m) const {
	GhosttyTerminalModeConfig q = {m, false};
	ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &q);
	return q.value;
}

void VtTerminal::paste_text(const String &text) {
	CharString u = text.utf8();
	std::vector<char> data(u.get_data(), u.get_data() + u.length());
	bool bracketed = _mode(GHOSTTY_MODE_BRACKETED_PASTE);
	size_t need = 0;
	ghostty_paste_encode(data.data(), data.size(), bracketed, nullptr, 0, &need);
	std::vector<uint8_t> out(need + 16);
	size_t n = 0;
	if (ghostty_paste_encode(data.data(), data.size(), bracketed, out.data(), out.size(), &n) == GHOSTTY_SUCCESS) _send(out.data(), n);
}

// ------------------------------------------------------------------ size and colours
void VtTerminal::_apply_size() {
	if (font.is_null()) return;
	Vector2 m = font->get_char_size('M', font_size);
	cell_w = std::ceil(m.x);
	cell_h = std::ceil(font->get_height(font_size));
	ascent = std::round(font->get_ascent(font_size));
	int c = MAX(2, (int)(get_size().x / cell_w));
	int r = MAX(1, (int)(get_size().y / cell_h));
	if (c == cols && r == rows && term) {
		needs_redraw = true;
		return;
	}
	cols = c;
	rows = r;
	ghostty_terminal_resize(term, cols, rows, (uint32_t)cell_w, (uint32_t)cell_h);
#ifndef _WIN32
	if (pty_fd >= 0) {
		struct winsize ws = {(unsigned short)rows, (unsigned short)cols, (unsigned short)(cols * cell_w), (unsigned short)(rows * cell_h)};
		ioctl(pty_fd, TIOCSWINSZ, &ws);
	}
#endif
#ifdef _WIN32
	if (win) win_resize(win, cols, rows);
#endif
	emit_signal("grid_resized", cols, rows);
	needs_redraw = true;
}

static GhosttyColorRgb to_rgb(const Color &c) {
	return GhosttyColorRgb{(uint8_t)CLAMP(c.r * 255.0 + 0.5, 0, 255), (uint8_t)CLAMP(c.g * 255.0 + 0.5, 0, 255), (uint8_t)CLAMP(c.b * 255.0 + 0.5, 0, 255)};
}

void VtTerminal::_apply_colors() {
	GhosttyColorRgb fg = to_rgb(fg_default), bg = to_rgb(bg_default);
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
	GhosttyColorRgb pal[256];
	ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, pal);
	for (int i = 0; i < 16 && i < palette16.size(); i++) pal[i] = to_rgb(palette16[i]);
	ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, pal);
	needs_redraw = true;
}

void VtTerminal::set_font(const Ref<Font> &f) { font = f; _apply_size(); }
void VtTerminal::set_font_size(int s) { font_size = MAX(6, s); _apply_size(); }
void VtTerminal::set_palette(const PackedColorArray &p) { palette16 = p; _apply_colors(); }
void VtTerminal::set_foreground(const Color &c) { fg_default = c; _apply_colors(); }
void VtTerminal::set_background(const Color &c) { bg_default = c; _apply_colors(); }

// ------------------------------------------------------------------ drawing
static Color rgb(const GhosttyColorRgb &c) { return Color(c.r / 255.0f, c.g / 255.0f, c.b / 255.0f); }

// Box drawing and block elements are drawn as shapes so lines join across cells (as Ghostty does).
bool VtTerminal::_draw_box(char32_t cp, const Rect2 &r, const Color &c) {
	const float x = r.position.x, y = r.position.y, w = r.size.x, h = r.size.y;
	const float cx = std::floor(x + w / 2), cy = std::floor(y + h / 2);
	const float lt = MAX(1.0f, std::round(cell_h / 16.0f));
	if (cp >= 0x2580 && cp <= 0x259F) {
		switch (cp) {
			case 0x2588: draw_rect(r, c); return true;                                   // full
			case 0x2580: draw_rect(Rect2(x, y, w, h / 2), c); return true;              // upper half
			case 0x2584: draw_rect(Rect2(x, y + h / 2, w, h - h / 2), c); return true;  // lower half
			case 0x258C: draw_rect(Rect2(x, y, w / 2, h), c); return true;              // left half
			case 0x2590: draw_rect(Rect2(x + w / 2, y, w - w / 2, h), c); return true;  // right half
			case 0x2591: draw_rect(r, Color(c, c.a * 0.25f)); return true;              // shades
			case 0x2592: draw_rect(r, Color(c, c.a * 0.5f)); return true;
			case 0x2593: draw_rect(r, Color(c, c.a * 0.75f)); return true;
		}
		if (cp >= 0x2581 && cp <= 0x2587) {  // lower eighths
			float f = (cp - 0x2580) / 8.0f;
			draw_rect(Rect2(x, y + h * (1 - f), w, h * f), c);
			return true;
		}
		if (cp >= 0x2589 && cp <= 0x258F) {  // left eighths
			float f = (0x2590 - cp) / 8.0f;
			draw_rect(Rect2(x, y, w * f, h), c);
			return true;
		}
		return false;
	}
	if (cp < 0x2500 || cp > 0x257F) return false;
	// weights: 0 none, 1 light, 2 heavy, 3 double, for left, right, up, down
	int L = 0, R = 0, U = 0, D = 0;
	bool arc = false;
	switch (cp) {
		case 0x2500: L = R = 1; break; case 0x2501: L = R = 2; break;
		case 0x2502: U = D = 1; break; case 0x2503: U = D = 2; break;
		case 0x250C: R = D = 1; break; case 0x250F: R = D = 2; break;
		case 0x2510: L = D = 1; break; case 0x2513: L = D = 2; break;
		case 0x2514: R = U = 1; break; case 0x2517: R = U = 2; break;
		case 0x2518: L = U = 1; break; case 0x251B: L = U = 2; break;
		case 0x251C: U = D = R = 1; break; case 0x2523: U = D = R = 2; break;
		case 0x2524: U = D = L = 1; break; case 0x252B: U = D = L = 2; break;
		case 0x252C: L = R = D = 1; break; case 0x2533: L = R = D = 2; break;
		case 0x2534: L = R = U = 1; break; case 0x253B: L = R = U = 2; break;
		case 0x253C: L = R = U = D = 1; break; case 0x254B: L = R = U = D = 2; break;
		case 0x2550: L = R = 3; break; case 0x2551: U = D = 3; break;
		case 0x2554: R = D = 3; break; case 0x2557: L = D = 3; break;
		case 0x255A: R = U = 3; break; case 0x255D: L = U = 3; break;
		case 0x2560: U = D = R = 3; break; case 0x2563: U = D = L = 3; break;
		case 0x2566: L = R = D = 3; break; case 0x2569: L = R = U = 3; break;
		case 0x256C: L = R = U = D = 3; break;
		case 0x256D: R = D = 1; arc = true; break; case 0x256E: L = D = 1; arc = true; break;
		case 0x256F: L = U = 1; arc = true; break; case 0x2570: R = U = 1; arc = true; break;
		case 0x2574: L = 1; break; case 0x2575: U = 1; break; case 0x2576: R = 1; break; case 0x2577: D = 1; break;
		case 0x2578: L = 2; break; case 0x2579: U = 2; break; case 0x257A: R = 2; break; case 0x257B: D = 2; break;
		case 0x2504: case 0x2508: case 0x254C: L = R = 1; break;
		case 0x2506: case 0x250A: case 0x254E: U = D = 1; break;
		default: return false;
	}
	auto thick = [&](int wgt) { return wgt == 2 ? lt * 2 : lt; };
	if (arc) {
		float rad = MIN(w, h) / 2;
		Vector2 ctr(L ? cx - rad + lt / 2 : cx + rad - lt / 2, U ? cy - rad + lt / 2 : cy + rad - lt / 2);
		// fall back to straight segments meeting at the centre (crisp at small sizes)
		(void)ctr;
	}
	auto hseg = [&](float x0, float x1, int wgt) {
		if (wgt == 3) {
			draw_rect(Rect2(x0, cy - lt * 1.5f, x1 - x0, lt), c);
			draw_rect(Rect2(x0, cy + lt * 0.5f, x1 - x0, lt), c);
		} else {
			float t = thick(wgt);
			draw_rect(Rect2(x0, cy - std::floor(t / 2), x1 - x0, t), c);
		}
	};
	auto vseg = [&](float y0, float y1, int wgt) {
		if (wgt == 3) {
			draw_rect(Rect2(cx - lt * 1.5f, y0, lt, y1 - y0), c);
			draw_rect(Rect2(cx + lt * 0.5f, y0, lt, y1 - y0), c);
		} else {
			float t = thick(wgt);
			draw_rect(Rect2(cx - std::floor(t / 2), y0, t, y1 - y0), c);
		}
	};
	float ext = lt;  // segments overlap the centre so corners close
	if (L) hseg(x, cx + (R ? 0 : ext), L);
	if (R) hseg(cx - (L ? 0 : ext), x + w, R);
	if (U) vseg(y, cy + (D ? 0 : ext), U);
	if (D) vseg(cy - (U ? 0 : ext), y + h, D);
	return true;
}

void VtTerminal::_draw() {
	uint64_t t0 = Time::get_singleton()->get_ticks_usec();
	if (font.is_null()) return;
	ghostty_render_state_update(rstate, term);
	GhosttyRenderStateColors colors;
	memset(&colors, 0, sizeof(colors));
	colors.size = sizeof(colors);
	ghostty_render_state_get(rstate, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
	const Color dbg = rgb(colors.background), dfg = rgb(colors.foreground);
	draw_rect(Rect2(Vector2(), get_size()), dbg);

	ghostty_render_state_get(rstate, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows_it);
	int y = 0;
	uint32_t cps[32];
	while (ghostty_render_state_row_iterator_next(rows_it)) {
		ghostty_render_state_row_get(rows_it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells);
		int x = 0;
		const float py = y * cell_h;
		while (ghostty_render_state_row_cells_next(cells)) {
			GhosttyCell raw = 0;
			ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
			GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
			ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
			if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
				x++;
				continue;
			}
			const float px = x * cell_w;
			const float cw = cell_w * (wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1);
			GhosttyStyle st;
			memset(&st, 0, sizeof(st));
			ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st);
			GhosttyColorRgb c;
			Color fg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &c) == GHOSTTY_SUCCESS ? rgb(c) : dfg;
			bool has_bg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS;
			Color bg = has_bg ? rgb(c) : dbg;
			bool selected = false;
			ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected);
			if (st.flags & GHOSTTY_STYLE_FLAG_INVERSE) {
				std::swap(fg, bg);
				has_bg = true;
			}
			if (selected) {
				bg = fg.lerp(bg, 0.35f);
				fg = dbg;
				has_bg = true;
			}
			if (has_bg) draw_rect(Rect2(px, py, cw, cell_h), bg);
			if (st.flags & GHOSTTY_STYLE_FLAG_FAINT) fg = fg.lerp(bg, 0.45f);
			uint32_t glen = 0;
			ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
			if (glen > 0 && !(st.flags & GHOSTTY_STYLE_FLAG_INVISIBLE)) {
				GhosttyCodepointBuffer gb = {cps, 32, 0};
				ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &gb);
				size_t n = MIN((size_t)gb.len, (size_t)32);
				if (!(n == 1 && _draw_box(cps[0], Rect2(px, py, cw, cell_h), fg))) {
					String s;
					for (size_t i = 0; i < n; i++) s += String::chr(cps[i]);
					Vector2 pos(px, py + ascent);
					font->draw_string(get_canvas_item(), pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, fg);
					if (st.flags & GHOSTTY_STYLE_FLAG_BOLD) font->draw_string(get_canvas_item(), pos + Vector2(0.6f, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, fg);
				}
			}
			const float lw = MAX(1.0f, std::round(cell_h / 18.0f));
			int ul = GHOSTTY_STYLE_UNDERLINE(st);
			if (ul) {
				Color uc = fg;
				if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &c) == GHOSTTY_SUCCESS && st.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB) uc = rgb(st.underline_color.value.rgb);
				float uy = py + ascent + lw * 1.5f;
				if (ul == 2) {  // double
					draw_rect(Rect2(px, uy, cw, lw), uc);
					draw_rect(Rect2(px, uy + lw * 2, cw, lw), uc);
				} else if (ul == 3) {  // curly
					PackedVector2Array pts;
					for (int k = 0; k <= 8; k++) pts.push_back(Vector2(px + cw * k / 8.0f, uy + lw + std::sin(k * 3.14159265f / 2) * lw * 1.2f));
					draw_polyline(pts, uc, lw, true);
				} else if (ul == 4 || ul == 5) {  // dotted, dashed
					float seg = ul == 4 ? lw * 2 : cw / 3;
					for (float sx = px; sx < px + cw; sx += seg * 2) draw_rect(Rect2(sx, uy, MIN(seg, px + cw - sx), lw), uc);
				} else {
					draw_rect(Rect2(px, uy, cw, lw), uc);
				}
			}
			if (st.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) draw_rect(Rect2(px, py + std::round(cell_h * 0.55f), cw, lw), fg);
			if (st.flags & GHOSTTY_STYLE_FLAG_OVERLINE) draw_rect(Rect2(px, py, cw, lw), fg);
			x++;
		}
		bool row_clean = false;
		ghostty_render_state_row_set(rows_it, GHOSTTY_RENDER_STATE_ROW_OPT_DIRTY, &row_clean);
		y++;
	}
	// cursor
	GhosttyRenderStateCursor cur;
	memset(&cur, 0, sizeof(cur));
	cur.size = sizeof(cur);
	ghostty_render_state_get(rstate, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cur);
	if (cur.visible && cur.viewport_has_value && (!cur.blinking || blink_on || !focused)) {
		GhosttyCursorStyle style = GHOSTTY_CURSOR_STYLE_BLOCK;
		ghostty_render_state_get(rstate, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style);
		Color cc = colors.cursor_has_value ? rgb(colors.cursor) : dfg;
		Rect2 cr(cur.viewport_x * cell_w, cur.viewport_y * cell_h, cell_w, cell_h);
		if (!focused) draw_rect(cr, cc, false, 1.0f);
		else if (style == GHOSTTY_CURSOR_STYLE_BAR) draw_rect(Rect2(cr.position, Vector2(MAX(2.0f, cell_w / 6), cell_h)), cc);
		else if (style == GHOSTTY_CURSOR_STYLE_UNDERLINE) draw_rect(Rect2(cr.position.x, cr.position.y + cell_h - 2, cell_w, 2), cc);
		else if (style == GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW) draw_rect(cr, cc, false, 1.0f);
		else draw_rect(cr, Color(cc, 0.75f));
	}
	GhosttyRenderStateDirty clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
	ghostty_render_state_set(rstate, GHOSTTY_RENDER_STATE_OPT_DIRTY, &clean);
	last_draw_ms = (Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
	draw_count++;
}

// ------------------------------------------------------------------ input
static int to_ghostty_key(Key k) {
	if (k >= KEY_A && k <= KEY_Z) return GHOSTTY_KEY_A + (k - KEY_A);
	if (k >= KEY_0 && k <= KEY_9) return GHOSTTY_KEY_DIGIT_0 + (k - KEY_0);
	if (k >= KEY_F1 && k <= KEY_F12) return GHOSTTY_KEY_F1 + (k - KEY_F1);
	switch (k) {
		case KEY_ENTER: return GHOSTTY_KEY_ENTER;
		case KEY_KP_ENTER: return GHOSTTY_KEY_NUMPAD_ENTER;
		case KEY_TAB: case KEY_BACKTAB: return GHOSTTY_KEY_TAB;
		case KEY_BACKSPACE: return GHOSTTY_KEY_BACKSPACE;
		case KEY_ESCAPE: return GHOSTTY_KEY_ESCAPE;
		case KEY_SPACE: return GHOSTTY_KEY_SPACE;
		case KEY_UP: return GHOSTTY_KEY_ARROW_UP;
		case KEY_DOWN: return GHOSTTY_KEY_ARROW_DOWN;
		case KEY_LEFT: return GHOSTTY_KEY_ARROW_LEFT;
		case KEY_RIGHT: return GHOSTTY_KEY_ARROW_RIGHT;
		case KEY_HOME: return GHOSTTY_KEY_HOME;
		case KEY_END: return GHOSTTY_KEY_END;
		case KEY_PAGEUP: return GHOSTTY_KEY_PAGE_UP;
		case KEY_PAGEDOWN: return GHOSTTY_KEY_PAGE_DOWN;
		case KEY_INSERT: return GHOSTTY_KEY_INSERT;
		case KEY_DELETE: return GHOSTTY_KEY_DELETE;
		case KEY_MINUS: return GHOSTTY_KEY_MINUS;
		case KEY_EQUAL: return GHOSTTY_KEY_EQUAL;
		case KEY_BRACKETLEFT: return GHOSTTY_KEY_BRACKET_LEFT;
		case KEY_BRACKETRIGHT: return GHOSTTY_KEY_BRACKET_RIGHT;
		case KEY_BACKSLASH: return GHOSTTY_KEY_BACKSLASH;
		case KEY_SEMICOLON: return GHOSTTY_KEY_SEMICOLON;
		case KEY_APOSTROPHE: return GHOSTTY_KEY_QUOTE;
		case KEY_QUOTELEFT: return GHOSTTY_KEY_BACKQUOTE;
		case KEY_COMMA: return GHOSTTY_KEY_COMMA;
		case KEY_PERIOD: return GHOSTTY_KEY_PERIOD;
		case KEY_SLASH: return GHOSTTY_KEY_SLASH;
		default: break;
	}
	return 0;  // unidentified: the text alone is sent
}

void VtTerminal::_gui_input(const Ref<InputEvent> &event) {
	Ref<InputEventKey> k = event;
	if (k.is_valid()) {
		if (!k->is_pressed() && !k->is_echo()) {
			accept_event();
			return;  // releases matter only with the Kitty protocol's event types (not requested here)
		}
		const bool ctrl = k->is_ctrl_pressed(), shift = k->is_shift_pressed(), alt = k->is_alt_pressed();
		// Copy and paste: Ctrl+Shift+C / Ctrl+Shift+V (and Shift+Insert)
		if (ctrl && shift && k->get_keycode() == KEY_C) {
			String s = get_selection_text();
			if (!s.is_empty()) DisplayServer::get_singleton()->clipboard_set(s);
			accept_event();
			return;
		}
		if ((ctrl && shift && k->get_keycode() == KEY_V) || (shift && k->get_keycode() == KEY_INSERT)) {
			paste_text(DisplayServer::get_singleton()->clipboard_get());
			accept_event();
			return;
		}
		Key phys = k->get_physical_keycode() != KEY_NONE ? k->get_physical_keycode() : k->get_keycode();
		char32_t uc = k->get_unicode();
		int gk = to_ghostty_key(phys);
		uint16_t mods = (shift ? GHOSTTY_MODS_SHIFT : 0) | (ctrl ? GHOSTTY_MODS_CTRL : 0) | (alt ? GHOSTTY_MODS_ALT : 0) | (k->is_meta_pressed() ? GHOSTTY_MODS_SUPER : 0);
		uint16_t consumed = 0;
		const bool altgr = ctrl && alt && uc >= 0x20 && uc != 0x7f;  // AltGr on Windows arrives as Ctrl+Alt with text
		if (altgr) mods &= ~(GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT);
		if (uc >= 0x20 && uc != 0x7f && shift) consumed |= GHOSTTY_MODS_SHIFT;
		GhosttyKeyEvent ev;
		ghostty_key_event_new(nullptr, &ev);
		ghostty_key_event_set_action(ev, k->is_echo() ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS);
		ghostty_key_event_set_key(ev, (GhosttyKey)gk);
		ghostty_key_event_set_mods(ev, mods);
		ghostty_key_event_set_consumed_mods(ev, consumed);
		Key label = k->get_key_label();
		char32_t unshifted = (label >= 0x20 && label < 0x110000 && !(label & KEY_SPECIAL)) ? String::chr((char32_t)label).to_lower()[0] : 0;
		if (unshifted) ghostty_key_event_set_unshifted_codepoint(ev, unshifted);
		CharString utf;
		if (uc >= 0x20 && uc != 0x7f && (altgr || !ctrl)) {
			utf = String::chr(uc).utf8();
			GhosttyString gs = {(const uint8_t *)utf.get_data(), (size_t)utf.length()};
			ghostty_key_event_set_utf8(ev, gs);
		}
		ghostty_key_encoder_set_from_terminal(keys, term);
		uint8_t buf[128];
		size_t n = 0;
		if (ghostty_key_encoder_encode(keys, ev, buf, sizeof(buf), &n) == GHOSTTY_SUCCESS && n > 0) {
			_send(buf, n);
			GhosttyTerminalScrollViewport bottom = {GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, {0}};
			ghostty_terminal_scroll_viewport(term, bottom);
		}
		ghostty_key_event_free(ev);
		accept_event();
		return;
	}
	Ref<InputEventMouseButton> mb = event;
	Ref<InputEventMouseMotion> mm = event;
	if (mb.is_valid() && mb->is_pressed()) grab_focus();
	if ((mb.is_valid() || mm.is_valid()) && _mouse_report(event)) {
		accept_event();
		return;
	}
	if (mb.is_valid()) {
		if (mb->get_button_index() == MOUSE_BUTTON_WHEEL_UP || mb->get_button_index() == MOUSE_BUTTON_WHEEL_DOWN) {
			if (mb->is_pressed()) {
				GhosttyTerminalScrollViewport d = {GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, {0}};
				d.value.delta = mb->get_button_index() == MOUSE_BUTTON_WHEEL_UP ? -3 : 3;
				ghostty_terminal_scroll_viewport(term, d);
				needs_redraw = true;
			}
		} else if (mb->get_button_index() == MOUSE_BUTTON_LEFT) {
			if (mb->is_pressed()) _select_to(mb->get_position(), true);
			selecting = mb->is_pressed();
		} else if (mb->get_button_index() == MOUSE_BUTTON_MIDDLE && mb->is_pressed()) {
			paste_text(DisplayServer::get_singleton()->clipboard_get());
		}
		accept_event();
	} else if (mm.is_valid() && selecting) {
		_select_to(mm->get_position(), false);
		accept_event();
	}
}

Vector2i VtTerminal::_cell_at(const Vector2 &pos) const {
	return Vector2i(CLAMP((int)(pos.x / cell_w), 0, cols - 1), CLAMP((int)(pos.y / cell_h), 0, rows - 1));
}

void VtTerminal::_select_to(const Vector2 &pos, bool start) {
	Vector2i c = _cell_at(pos);
	if (start) {
		sel_anchor = c;
		GhosttySelection none;
		memset(&none, 0, sizeof(none));
		ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, nullptr);
		needs_redraw = true;
		return;
	}
	GhosttyPoint a = {GHOSTTY_POINT_TAG_VIEWPORT, {}};
	a.value.coordinate.x = sel_anchor.x;
	a.value.coordinate.y = sel_anchor.y;
	GhosttyPoint b = {GHOSTTY_POINT_TAG_VIEWPORT, {}};
	b.value.coordinate.x = c.x;
	b.value.coordinate.y = c.y;
	GhosttySelection sel;
	memset(&sel, 0, sizeof(sel));
	if (ghostty_terminal_grid_ref(term, a, &sel.start) == GHOSTTY_SUCCESS && ghostty_terminal_grid_ref(term, b, &sel.end) == GHOSTTY_SUCCESS) {
		ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
		needs_redraw = true;
	}
}

String VtTerminal::get_selection_text() const {
	GhosttySelection sel;
	memset(&sel, 0, sizeof(sel));
	if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != GHOSTTY_SUCCESS) return String();
	GhosttyFormatter f;
	if (ghostty_formatter_terminal_new(nullptr, &f, term) != GHOSTTY_SUCCESS) return String();
	GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
	bool trim = true;
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_SELECTION, &sel);
	uint8_t *buf = nullptr;
	size_t len = 0;
	String out;
	if (ghostty_formatter_format_alloc(f, nullptr, &buf, &len) == GHOSTTY_SUCCESS) {
		out = String::utf8((const char *)buf, len);
		ghostty_free(nullptr, buf, len);
	}
	ghostty_formatter_free(f);
	return out;
}

String VtTerminal::get_screen_text() const {
	GhosttyFormatter f;
	if (ghostty_formatter_terminal_new(nullptr, &f, term) != GHOSTTY_SUCCESS) return String();
	GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
	bool trim = true;
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
	uint8_t *buf = nullptr;
	size_t len = 0;
	String out;
	if (ghostty_formatter_format_alloc(f, nullptr, &buf, &len) == GHOSTTY_SUCCESS) {
		out = String::utf8((const char *)buf, len);
		ghostty_free(nullptr, buf, len);
	}
	ghostty_formatter_free(f);
	return out;
}

bool VtTerminal::_mouse_report(const Ref<InputEvent> &event) {
	ghostty_mouse_encoder_set_from_terminal(mouse, term);
	GhosttyMouseTrackingMode mode = GHOSTTY_MOUSE_TRACKING_NONE;
	GhosttyTerminalModeConfig q;
	(void)q;
	if (!(_mode(GHOSTTY_MODE_MOUSE_EVENT_NORMAL) || _mode(GHOSTTY_MODE_MOUSE_EVENT_BUTTON) || _mode(GHOSTTY_MODE_MOUSE_EVENT_ANY) || _mode(ghostty_mode_new(9, false)))) return false;
	(void)mode;
	Ref<InputEventMouse> me = event;
	if (me.is_valid() && me->is_shift_pressed()) return false;  // Shift: local selection, like other terminals
	GhosttyMouseEncoderSize sz;
	memset(&sz, 0, sizeof(sz));
	sz.size = sizeof(sz);
	sz.screen_width = (uint32_t)get_size().x;
	sz.screen_height = (uint32_t)get_size().y;
	sz.cell_width = (uint32_t)cell_w;
	sz.cell_height = (uint32_t)cell_h;
	ghostty_mouse_encoder_set(mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &sz);
	GhosttyMouseEvent ev;
	ghostty_mouse_event_new(nullptr, &ev);
	Ref<InputEventMouseButton> mb = event;
	Ref<InputEventMouseMotion> mm = event;
	uint16_t mods = 0;
	if (me->is_ctrl_pressed()) mods |= GHOSTTY_MODS_CTRL;
	if (me->is_alt_pressed()) mods |= GHOSTTY_MODS_ALT;
	ghostty_mouse_event_set_mods(ev, mods);
	ghostty_mouse_event_set_position(ev, GhosttyMousePosition{me->get_position().x, me->get_position().y});
	if (mb.is_valid()) {
		GhosttyMouseButton b = GHOSTTY_MOUSE_BUTTON_UNKNOWN;
		switch (mb->get_button_index()) {
			case MOUSE_BUTTON_LEFT: b = GHOSTTY_MOUSE_BUTTON_LEFT; break;
			case MOUSE_BUTTON_RIGHT: b = GHOSTTY_MOUSE_BUTTON_RIGHT; break;
			case MOUSE_BUTTON_MIDDLE: b = GHOSTTY_MOUSE_BUTTON_MIDDLE; break;
			case MOUSE_BUTTON_WHEEL_UP: b = GHOSTTY_MOUSE_BUTTON_FOUR; break;
			case MOUSE_BUTTON_WHEEL_DOWN: b = GHOSTTY_MOUSE_BUTTON_FIVE; break;
			case MOUSE_BUTTON_WHEEL_LEFT: b = GHOSTTY_MOUSE_BUTTON_SIX; break;
			case MOUSE_BUTTON_WHEEL_RIGHT: b = GHOSTTY_MOUSE_BUTTON_SEVEN; break;
			default: break;
		}
		if (!mb->is_pressed() && b >= GHOSTTY_MOUSE_BUTTON_FOUR) {  // a wheel has no release
			ghostty_mouse_event_free(ev);
			return true;
		}
		ghostty_mouse_event_set_button(ev, b);
		ghostty_mouse_event_set_action(ev, mb->is_pressed() ? GHOSTTY_MOUSE_ACTION_PRESS : GHOSTTY_MOUSE_ACTION_RELEASE);
		if (b <= GHOSTTY_MOUSE_BUTTON_MIDDLE) mouse_pressed = mb->is_pressed();
	} else {
		ghostty_mouse_event_set_action(ev, GHOSTTY_MOUSE_ACTION_MOTION);
		if (mm->get_button_mask().has_flag(MOUSE_BUTTON_MASK_LEFT)) ghostty_mouse_event_set_button(ev, GHOSTTY_MOUSE_BUTTON_LEFT);
		else ghostty_mouse_event_clear_button(ev);
	}
	bool any = mouse_pressed;
	ghostty_mouse_encoder_set(mouse, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any);
	uint8_t buf[64];
	size_t n = 0;
	if (ghostty_mouse_encoder_encode(mouse, ev, buf, sizeof(buf), &n) == GHOSTTY_SUCCESS) _send(buf, n);
	ghostty_mouse_event_free(ev);
	return true;
}

// ------------------------------------------------------------------ binding
void VtTerminal::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "program", "args", "cwd", "env"), &VtTerminal::start);
	ClassDB::bind_method(D_METHOD("feed", "data"), &VtTerminal::feed);
	ClassDB::bind_method(D_METHOD("write_input", "data"), &VtTerminal::write_input);
	ClassDB::bind_method(D_METHOD("paste_text", "text"), &VtTerminal::paste_text);
	ClassDB::bind_method(D_METHOD("get_selection_text"), &VtTerminal::get_selection_text);
	ClassDB::bind_method(D_METHOD("get_screen_text"), &VtTerminal::get_screen_text);
	ClassDB::bind_method(D_METHOD("is_running"), &VtTerminal::is_running);
	ClassDB::bind_method(D_METHOD("get_cols"), &VtTerminal::get_cols);
	ClassDB::bind_method(D_METHOD("get_rows"), &VtTerminal::get_rows);
	ClassDB::bind_method(D_METHOD("get_cell_size"), &VtTerminal::get_cell_size);
	ClassDB::bind_method(D_METHOD("get_last_draw_ms"), &VtTerminal::get_last_draw_ms);
	ClassDB::bind_method(D_METHOD("get_draw_count"), &VtTerminal::get_draw_count);
	ClassDB::bind_method(D_METHOD("set_font", "font"), &VtTerminal::set_font);
	ClassDB::bind_method(D_METHOD("get_font"), &VtTerminal::get_font);
	ClassDB::bind_method(D_METHOD("set_font_size", "size"), &VtTerminal::set_font_size);
	ClassDB::bind_method(D_METHOD("get_font_size"), &VtTerminal::get_font_size);
	ClassDB::bind_method(D_METHOD("set_palette", "colors"), &VtTerminal::set_palette);
	ClassDB::bind_method(D_METHOD("get_palette"), &VtTerminal::get_palette);
	ClassDB::bind_method(D_METHOD("set_foreground", "color"), &VtTerminal::set_foreground);
	ClassDB::bind_method(D_METHOD("get_foreground"), &VtTerminal::get_foreground);
	ClassDB::bind_method(D_METHOD("set_background", "color"), &VtTerminal::set_background);
	ClassDB::bind_method(D_METHOD("get_background"), &VtTerminal::get_background);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "font", PROPERTY_HINT_RESOURCE_TYPE, "Font"), "set_font", "get_font");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "font_size"), "set_font_size", "get_font_size");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_COLOR_ARRAY, "palette"), "set_palette", "get_palette");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "foreground"), "set_foreground", "get_foreground");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "background"), "set_background", "get_background");
	ADD_SIGNAL(MethodInfo("exited", PropertyInfo(Variant::INT, "code")));
	ADD_SIGNAL(MethodInfo("output_received", PropertyInfo(Variant::INT, "bytes")));
	ADD_SIGNAL(MethodInfo("input_sent", PropertyInfo(Variant::PACKED_BYTE_ARRAY, "data")));
	ADD_SIGNAL(MethodInfo("grid_resized", PropertyInfo(Variant::INT, "cols"), PropertyInfo(Variant::INT, "rows")));
	ADD_SIGNAL(MethodInfo("bell"));
	ADD_SIGNAL(MethodInfo("title_changed"));
}
