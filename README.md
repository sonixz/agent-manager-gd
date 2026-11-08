# Agent Manager GD

Your AI coding agents, side by side, in a live and themable desktop app.

Run Claude Code, Codex and other agent CLIs in real terminals inside one window: every session persists in tmux,
shows its live state, revives on its own conversation, forks, and works in its own git worktree. Every session is
wired to your [Second Brain](https://github.com/sonixz/second-brain-gd) over MCP, so what one agent learns, the next
one knows.

Status: **pre-alpha, private.** Loops 1 to 3 done: the plan (`docs/brief/`), an impeccable terminal on Ghostty's
engine (`native/vtterm`, `docs/research/TERMINAL.md`), and persistent sessions (`engine/`, `app/`).

## Run it (development)

Needs, where tmux lives (Linux, or WSL on Windows): `python3` (3.10+, standard library only) and `tmux`.

1. Build the terminal extension once: `tools/build_native.sh` (see `native/vtterm/README.md` for the toolchain).
2. Open `app/` with Godot 4.7 (Linux, or Windows with WSL) and run it. The app starts the engine
   (`python3 -m engine`, 127.0.0.1:8790, a token in `~/.local/share/agent-manager-gd/runtime/`) through WSL on Windows.
3. « + New session »: Claude Code, Codex or a shell, in a folder (a Windows path is fine). Close the app: the sessions
   keep running in a private tmux server (`tmux -L agmgd ls`); reopen it and they are there.

## Using it

- **Views** (top right): **Focus** one terminal · **Grid** up to four terminals side by side (right click a session →
  Show in grid) · **Board** a tile per session with a live preview of its screen.
- **Themes** (◐): the Second Brain's seven themes (Focus, Terminal, Neon, Evening, Forest, Morning, Paper) for the
  interface and the terminal's colours.
- **Never lose a conversation**: every session keeps every conversation id it ever had (Claude Code gets its id from
  the app at launch; Codex reports it). **Resume** starts a session again on its own conversation — after a reboot,
  after it ended, or from the archive. **Fork…** opens a new session on a copy of a conversation. **Archive** puts a
  session away; **History** (Ctrl+Shift+H) lists every session ever made with its conversations, searchable by name,
  folder, group or id, each resumable at any time.
- **Git branch per session**: tick « In its own git branch » when creating a session: it works in
  `<repository>-worktrees/<name>` on branch `am/<name>`. **Finish its git branch…** shows what is ahead and
  uncommitted, can merge it into the repository's current branch (a conflicting merge is undone) and removes the
  worktree; uncommitted work blocks it, and the branch is deleted only if merged.
- **They wait for you**: sessions waiting for your OK (Approve / Refuse) or an answer (Reply… without opening them).
- **Shortcuts** (Ctrl alone works outside a terminal; with Shift they work everywhere, since a terminal keeps plain
  Ctrl keys for its programs): Ctrl+Shift+K command palette · Ctrl+Shift+N new session · Ctrl+Shift+F / G / B Focus,
  Grid, Board · Ctrl+Shift+↑ / ↓ previous / next session · Ctrl+Shift+A approve the first waiting session.
  In a terminal: Ctrl+Shift+C / V copy and paste, Shift+drag selects even when the program uses the mouse.

Tests: `python3 -m unittest discover -s tests/python -t .`; the app end to end on a virtual display:
`tools/app_shots.sh <out-dir> [a folder Claude Code already trusts]`.

Stack: Godot 4.7 (interface) + Python (engine), local-first. Licence: to be chosen by the owner.
