# The terminal: options and the go/no-go grid (Loop 2)

The terminal is the foundation: if it is not impeccable, the project stops or changes approach.

## Architecture

```
agent CLI (claude, codex…) ── runs in ── tmux session (private server: tmux -L agmgd)
                                              │  a tmux client attached through a PTY
                                              ▼
                       VT engine (parses escape sequences, keeps the screen grid)
                                              │
                                              ▼
                  Godot renders the grid (theme font and colours), sends keys, mouse, paste
```

tmux keeps sessions alive when the app closes. The app's terminal is a tmux client, so its quality is the VT
engine's quality.

## Candidates (state checked 2026-11-08)

| | godot-xterm | libghostty-vt (Ghostty) | pyte (Python) |
|---|---|---|---|
| What | Terminal node for Godot 4.3+ (GDExtension) | C/Zig library: VT parsing + terminal state, from the Ghostty terminal | Pure-Python VT emulator |
| Built on | libtsm, libuv, node-pty | Ghostty's own core | itself |
| Licence | MIT | MIT | LGPL-3.0 |
| Platforms | Linux (main), macOS, Windows ("partial") | macOS, Linux, Windows, WebAssembly | any |
| Maturity | v4.0.3 (2026-02-19), 199 stars, last push 2026-10-12 | "extremely stable" core (proven in Ghostty), **API signatures still in flux**; 63.8k stars | old, incomplete for modern TUIs |
| Integration work | Small: drop the addon in, attach a PTY | Large: a GDExtension (godot-cpp) wrapping the C API + our own grid renderer and PTY | Grid sent from Python to Godot: latency |
| Build tools needed | none if the release has prebuilt binaries | Zig toolchain, godot-cpp, SCons (none installed today) | none |
| Risk | libtsm's coverage (truecolor? modern sequences?) and Windows | effort; API churn | quality: excluded for "impeccable" |

Sources: https://github.com/lihop/godot-xterm (README: "Primarily developed and tested on Linux, it also supports
macOS and Windows with partial support for HTML5"), https://github.com/ghostty-org/ghostty (README, "libghostty"
section), https://mitchellh.com/writing/libghostty-is-coming, https://github.com/ghostty-org/ghostling.

Order: try godot-xterm first (cheap); if it fails the grid, build the libghostty-vt extension. pyte is out.

## The grid (every line must pass, measured, with a capture)

| # | Check | How it is tested |
|---|---|---|
| 1 | French text and keys: é è ê à ç œ « » —, dead keys (^ then e = ê), AltGr | type into `cat` and into Claude Code; compare bytes received |
| 2 | Colours: 16, 256 and 24-bit truecolor | a colour test script (gradients); Claude Code's own colours |
| 3 | Wide characters and emoji (CJK, ✓ ⏺ ⎿, emoji with ZWJ) aligned on the grid | a test file of known widths |
| 4 | Full-screen TUIs: Claude Code and Codex, alternate screen, synchronized output, no tearing | run both in tmux, scripted interaction |
| 5 | Copy (selection) and paste, bracketed paste (multi-line paste does not execute line by line) | paste a 3-line block into a shell and into Claude Code |
| 6 | Keys: Ctrl+C, Esc, arrows, Home/End, PgUp/PgDn, Tab, Shift+Tab, Ctrl+letters, Alt+letters | a key echo script (`showkey -a`-like) |
| 7 | Mouse: click, wheel, drag selection; mouse reporting passed to TUIs that ask | tmux mouse mode + a TUI |
| 8 | Scrollback: 10 000 lines, smooth scroll | `seq 1 10000` |
| 9 | Resize: window and pane resize reflow without garbage; tmux follows | scripted resizes |
| 10 | Speed: 4 terminals at 60 fps while one streams heavy output; key-to-screen latency under ~30 ms | built-in FPS + timestamped echo |
| 11 | Platforms: WSL (tmux) and native Windows (psmux or ConPTY) | owner test on Windows at the end, only if asked |
| 12 | Themes: font and colours come from the theme; the 16 ANSI colours map to the theme | Terminal, Neon, Paper captures |

The verdict (kept candidate, numbers, captures) is written at the end of this file.

## Environment (2026-11-08)

WSL: tmux 3.4, Godot 4.7.2, claude, codex, gcc. Not installed: SCons, CMake, Zig. Native Windows: no psmux, no
claude, no codex on PATH.

## Round 1: godot-xterm v4.0.3 (2026-11-08)

Downloaded from the official release with the owner's agreement, checked against its published SHA-256
(`3c41f533…d9ccae`), kept out of the repository. Bench: `prototype/terminal/` (`tools/bench.sh render|input|tui|mouse|perf|baseline`),
godot-xterm attached through its PTY to a private tmux server, on a virtual display (software rendering, no GPU).

| # | Check | Result |
|---|---|---|
| 1 | French text and keys | **Pass.** Every accent, « » — € œ renders; typed keys send the right UTF-8 (é = c3 a9…); Claude Code's input shows « Écris « déjà vu » — ça marche ? » exactly. Dead keys are composed by the OS before Godot: to confirm on Windows. |
| 2 | Colours | **Pass** for 16, 256 and 24-bit (smooth gradients). **Fail:** *dim* and *strikethrough* are not drawn (bold, italic, underline, inverse are). |
| 3 | Wide chars, emoji | **Partial.** Widths are right (CJK takes two cells, bars align) once system fonts are added as fallbacks. **Fail:** emoji are monochrome; ZWJ sequences and flags split into pieces (no grapheme clusters). Box-drawing lines (─) show gaps between cells: Claude Code's separators look dashed. |
| 4 | Full-screen TUIs | **Pass.** Claude Code (v2.1.319) and Codex render fully in tmux; typing works. |
| 5 | Copy / paste | Selection and copy exist in the API. **Missing:** no paste method and no bracketed paste: the app must add it (it can see the program ask for mode 2004 in the stream). |
| 6 | Keys | **29/30.** **Fail:** Shift+Tab sends a plain Tab (Claude Code uses Shift+Tab to change mode). Fixable in our key layer. |
| 7 | Mouse | **Fail.** tmux asks for mouse reports (1000/1006) but clicks and the wheel send nothing. Fixable in our layer (we know the cell size and the mode). |
| 8 | Scrollback | tmux keeps 10 000 lines; scrolling it needs the mouse wheel (see 7). |
| 9 | Resize | **Pass.** The terminal and tmux follow (79x22 after a resize). |
| 10 | Speed | Software rendering: empty scene 136 fps, **one idle terminal 43 fps**, four terminals with one streaming 12.5 fps. The terminal redraws every frame even when idle. To measure on a real GPU (Windows) before judging. |
| 11 | Platforms | Linux PTY works. The Windows DLL contains ConPTY code: untested. |
| 12 | Themes | Colours are theme overrides (`ansi_0_color`…); fonts are overrides: compatible. |

**Verdict, round 1: not impeccable as is.** Fixable in our own layer: Shift+Tab and other keys, mouse reports,
bracketed paste, focus events. Not fixable without changing the library: dim, strikethrough, continuous box drawing,
colour emoji and grapheme clusters, the idle redraw cost. libtsm (its VT core) is old and lacks modern sequences
(synchronized output, the Kitty keyboard protocol, grapheme clustering).

**Recommendation:** round 2 with libghostty-vt (modern, complete VT state, grapheme clusters, Kitty keyboard) and
our own renderer in a GDExtension (glyph atlas, box drawing drawn as shapes like Ghostty does, redraw only what
changed). godot-xterm stays the fallback and the development terminal meanwhile.
