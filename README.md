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

Tests: `python3 -m unittest discover -s tests/python -t .`; the app end to end on a virtual display:
`tools/app_shots.sh <out-dir> [a folder Claude Code already trusts]`.

Stack: Godot 4.7 (interface) + Python (engine), local-first. Licence: to be chosen by the owner.
