# Devlog

## Loop 1: vision, plan, research (2026-11-08)

Repository created (local only). docs/brief/VISION.md and PLAN.md, docs/research/MARKET.md (market scan) and
TERMINAL.md (the VT engine candidates and the 12-line go/no-go grid), docs/DECISIONS.md, AGENTS.md. No code yet.

## Loop 2, round 1: godot-xterm on the bench (2026-11-08)

prototype/terminal: a bench attaching godot-xterm v4.0.3 (downloaded with the owner's agreement, checksum checked,
not committed) to a private tmux server, scripted on a virtual display: render, keys, Claude Code and Codex,
mouse, resize, speed. French accents, truecolor, widths, full-screen TUIs and resize pass; dim, strikethrough,
box-drawing gaps, colour emoji, Shift+Tab, mouse and paste fail; idle redraw is costly. Verdict and table in
docs/research/TERMINAL.md: not impeccable as is; round 2 proposed with libghostty-vt.

## Loop 2, round 2: our own terminal on libghostty-vt: GO on Linux (2026-11-08)

native/vtterm: a C++ GDExtension (VtTerminal) on libghostty-vt (Ghostty e035beb9) with our own renderer, PTY and
input encoders. The grid passes on WSL: accents and AltGr, colour emoji, every text style, continuous box drawing,
31/31 keys (Shift+Tab, Shift+Enter), mouse reports, bracketed paste, resize, themes; idle 131 fps and four terminals
with one streaming at 52 fps on software rendering (godot-xterm: 43 and 12.5). Native Windows (ConPTY) is next.

## Loop 2c: the terminal on native Windows (2026-11-08)

VtTerminal gets a ConPTY backend; libghostty-vt, godot-cpp and the extension are cross-built for Windows with Zig.
Headless checks with Windows Godot pass 8/8: UTF-8 from cmd and PowerShell, typed accents, wsl.exe → tmux with
accents, emoji and width, resize through ConPTY, exit codes. Fixed: inherited standard handles, font class bindings.
