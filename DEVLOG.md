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

## Loop 4D: the design pass (2026-11-08)

The interface gets an identity: the Second Brain's seven palettes and style tokens (AmTheme), also driving the
terminal's background, text and 16 ANSI colours (darkened on the light Paper theme). Session cards: tool badge
(✻ Claude Code, ◎ Codex, ❯ shell) with an animated state dot (slow pulse while working, a beat while waiting), the
agent's last words, time in this state, folder and git branch; a soft flash when the state changes. Three views of the
real terminals: Focus, Grid (up to four side by side, titled, ⤢ to open alone) and Board (tiles with a live preview of
each screen). A command palette (Ctrl+Shift+K) with fuzzy matching for sessions, approvals, replies, views and themes,
and shortcuts. Found and fixed on the way: selecting a card on press rebuilt the list mid-drag (now on release);
headless runs have a 64x64 window, so the drive script sets a real size. Checked: tree drag and click, create/reopen on
Linux and Windows headless, captures of the three views, the palette and three themes in docs/screens/loop4d.

## Loop 5: resume, fork, worktrees and a history that never forgets (2026-11-08)

Every conversation id is kept (`conversations` table): Claude Code sessions get theirs from the app at launch
(`--session-id <uuid>`), so it is known from the first second; Codex's arrives through `notify`. Resume (`claude
--resume <id>`, `codex resume <id>`, or Codex's own picker when no id was seen) works after an exit, a reboot or from
the archive; Fork (`--resume <id> --fork-session`, `codex fork <id>`) makes a new session with a parent link.
Archive takes a session out of the sidebar and keeps its record and conversations; History lists every session ever
made with its conversations, searchable, each resumable or forkable, ids copyable. Worktrees: a session can start in
`<repo>-worktrees/<name>` on `am/<name>`; Finish shows commits ahead and uncommitted changes, merges into the
repository's current branch on request (aborted on conflict), removes the worktree, deletes the branch with `-d` only.
Dialog windows now take the theme. Engine tests: 21 (5 new with fake claude/codex printing their options, and a real
temporary git repository). Captures in docs/screens/loop5.

## Loop 6A–6B: the Second Brain in every session (2026-11-08)

engine/brain.py finds the Second Brain (Windows %LOCALAPPDATA%\SecondBrainGD from WSL, or a Linux install), its Python
(install_state.json) and its repository (from its install log, for the relay). The Brain needed no change: it already
creates (`POST /mcp/clients`) and revokes (`DELETE /mcp/clients/<id>`) keys and ships a stdio relay. From WSL the
Brain's 127.0.0.1 is not reachable, so calls go through the Brain's own Windows Python (engine/brain_call.py), which
reads the app token from the Brain's files itself and strips any token from its answer: no key in an argument, a log
or our files. Each Claude Code / Codex session gets its own key at creation (level propose_items), passed with
`--mcp-config <file with the relay command>` or `-c mcp_servers.second-brain.*`; a fork gets a new key; removing a
session revokes its key. Live check against the owner's running Brain: a key created, the relay answering with the
Brain's 13 tools (propose_item included), refused once revoked; an app session started Claude Code which launched the
relay. 25 engine tests (4 with a fake Brain recording the calls). The Brain timeline per agent (6B) is the Brain's
existing feature: the client name carries the session name.

## Loop 6C: agents pilot agents (2026-11-08)

engine/mcp_agents.py, a small stdio MCP server offered to every Claude Code / Codex session next to the Second Brain
(`--mcp-config`, `-c mcp_servers.agent-manager.*`). It talks to the engine's API with the engine token; the session id,
data folder and port come from the session's environment (AGMGD_PORT added). Tools: list_sessions, session_status,
read_screen (any session), start_session (a child: parent link, the parent's folder and group by default),
send_to_session and wait_for_session (children only). No key-pressing tool: an agent cannot approve for another.
Cards show « ↳ parent ». Tests: 28 (a lead starts a child, writes to it, waits and reads « déjà-fini »; writing to a
session it did not start is refused).
