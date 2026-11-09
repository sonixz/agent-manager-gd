# Handoff: Agent Manager GD (2026-11-08)

Written by the agent that built Loops 1 to 16 before the owner moved to working through Agent Manager itself. Read it
with AGENTS.md (the rules), README.md (what the app does), DEVLOG.md (every loop, newest last) and docs/brief/PLAN.md.

## State

- Local git only, branch main, nothing uncommitted. **No remote yet**: the owner creates the GitHub repository; never
  push or change visibility without his word. Licence MIT. Commits as sonixz with the session attribution lines.
- Done: Loops 1–15 of the plan, then 16 (Sandboxes tab as a control room), 16b (copy: OSC 52, rejoined rows), 16c
  (Remote Control on by default, stale « working » fixed, sandbox scrolling, F9 falls back to dictation), 16d
  (repositories in the owner's own folders), plus the voice models aligned with the Second Brain (gpt-transcribe first).
- Tests: `python3 -m unittest discover -s tests/python` (about 72; one test failed once in nine runs and could not be
  identified: watch for it). Engine stdlib only.

## Running and checking

- Owner's Windows launcher: `C:\Users\pyfor\dust\qa-win\agent-manager-gd.cmd` (Godot 4.7.2 on `app/`). The engine
  (WSL, `python3 -m engine`, 127.0.0.1:8790) starts with the app and stops with it; tmux sessions survive.
- **No Godot window unless the owner asks.** Captures: `STEPS=<scenario> tools/app_shots.sh <out>` on a private Xvfb
  (scenarios in `app/tools_drive.gd`); `DEMO_FLY=1` uses a fake Fly (`tools/demo_sandboxes.py`), nothing reaches Fly.io.
- Native terminal: `tools/build_native.sh [template_debug|template_release]` (Zig toolchain, see native/vtterm). The
  Windows DLL is locked while the app runs: build into a staging folder, swap it when the app is closed.
- Release: `tools/build_release.sh <version>` → `dist/` zip with installer/install.ps1 (per user, no admin). Linux
  export needs Godot's Linux template (a download: ask first).

## Gotchas learned the hard way

- Godot's OS.execute / create_process re-split arguments containing double quotes: never quote.
- API routing in engine/api.py is first-match: put specific routes (`/sandboxes/orphans/...`, `/repos/copy/...`)
  **before** the generic `/<thing>/<id>/<action>` ones (a real bug once). The HTTP route tests catch it.
- A capture run killed mid-way leaves a test engine on port 18790: `pkill -f "^python3 -m engine --port 18790"`.
  Anchor pgrep/pkill patterns (`^…`), or they match your own shell.
- A font made inside `_draw` is freed before the frame: keep fonts as members (CostChart).
- Claude Code in full-screen mode redraws by itself: screen activity is not « working »; read « esc to interrupt ».
- Fly: region yyz, our sshd on 2222 (Fly's own uses 22), token only via FLY_API_TOKEN, flyctl has no billing command
  (costs are measured from machine history × published price).

## Waiting on the owner

- His last test round (the list he got on 2026-11-08): repos « Change folder… » to C:\git-2026\gd-project + « Add it
  as origin », Remote Control in claude.ai/code (untested for real), stale state after Esc, voice F8/F9, copy, a real
  sandbox (its live health checks never ran on a real machine yet), Remove and forget's confirmation.
- Creating the GitHub repository (sonixz/agent-manager-gd) and saying when to push.
- Proposed, not started: Loop 17 (a ✦ Brain tab: connection, who holds a key, proposals from our sessions, timeline,
  settings; a first-run « Are you using Second Brain? »; « Resume all » after a reboot). Agent security:
  docs/brief/AGENT-SECURITY.md, recorded only, **do not build until he asks**.
