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

## Loop 3: the engine and persistent sessions (2026-11-08)

engine/ (Python, standard library only): a private tmux server (`tmux -L agmgd`, sessions `am_<id>`, panes kept
when a program ends), session records in SQLite, a local API on 127.0.0.1 with a bearer token (file 0600, never
logged). States: running, exited (last screen kept), missing (after a reboot; restart brings it back).
app/ (Godot 4.7): the session list, the selected session's live VtTerminal attached to tmux, New session (Claude
Code, Codex, shell; Windows paths become WSL paths), Restart, Stop, Remove. Closing the app leaves the sessions
running; reopening attaches again with their screens. Checked end to end on Linux (virtual display, captures in
docs/screens/loop3) and with Windows Godot headless through ConPTY and wsl.exe (engine started by a login shell so
the user's claude is on PATH). 9 engine tests.

## Loop 4A: the project tree (2026-11-08)

Groups in the engine (order, folded state; sessions keep their order inside a group; deleting a group keeps its
sessions). The sidebar is a tree: fold a group with a click, drag a session onto another row or a group header,
drag a group header to reorder, right click for rename, move to group, restart, stop, remove; double click renames.
The 2-second refresh no longer rebuilds the rows when nothing changed or during a drag. Checked with a real mouse
drag on a virtual display: 10 sessions in 3 groups, order and folding survive reopening. 10 engine tests.

## Loop 4B: live states (2026-11-08)

Each session shows what it is doing: working, waits for your OK, waits for an answer, done, ready, ended, gone.
Claude Code reports through its own hooks, passed only for that launch with `--settings <file in our data folder>`
(never the user's settings); Codex through `-c notify=…`; engine/hook.py writes the state atomically, prints nothing
and never fails the agent. Fallbacks: terminal activity (tmux window_activity), the running program for shells, and
approval prompts in Codex's last lines. The session's conversation id is kept for resuming (Loop 5). Checked with the
real Claude Code (its SessionStart hook reaches the engine, no prompt, no cost) and simulated events for the other
states. Found and fixed: Godot 4.7's OS.execute/create_process re-split arguments containing double quotes, so the
engine launch no longer quotes (wsl.exe --cd on Windows). 15 engine tests (1 real-Claude test, opt-in).

## Loop 4C: quick reply, the waiting queue, alerts (2026-11-08)

« They wait for you » at the top of the sidebar: the sessions waiting for an OK (Approve sends Enter, the agent's
highlighted choice; Refuse sends Escape) or for an answer (Reply… writes without opening the terminal), at most four
cards. Quick reply also from the right-click menu. When a session starts waiting, a toast appears and, if the window
is not focused, its taskbar button flashes. The engine accepts named keys only (`POST /sessions/<id>/keys`), never
raw tmux key strings. Checked: the toast on a new approval, the queue, a quick reply reaching a shell. 16 engine tests.
Loop 4 is complete: next is the owner's first real test on Windows (★).

## Owner's first real test on Windows (2026-11-08)

The owner ran the app on Windows (RTX 3060): it worked (a Claude Code session made from the app). The Windows log
showed `Cannot find instance binding callbacks` for input events: clang (zig) drops godot-cpp's engine class
registrations, so keys and mouse events reaching the extension had no binding. The Windows build now generates and
calls a registration for every engine class (SConstruct). Checked headless on Windows: é, Shift+Tab, AltGr+E, Ctrl+C
and mouse motion reach VtTerminal with no error.
