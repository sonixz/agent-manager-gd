# Agent security: what an agent may touch (proposal, not built)

Recorded 2026-11-08 at the owner's request: « modifions rien pour l'instant, consigne-le ». Nothing below is built.

## The concern

A local coding agent (Claude Code, Codex) started by Agent Manager runs with the owner's own rights. In auto mode it
can read and change files outside its project, install Python or npm packages, and run code anywhere the owner can.
Cloud sandboxes (Fly.io) are already isolated (their own machine, only the repository and its deploy key); the gap is
the local sessions.

## What exists today (verified in Claude Code 2.1.319)

- **Permission rules** (standard, per user, project or session): `allow` / `ask` / `deny` with patterns
  (`Read(~/.ssh/**)`, `Bash(git push *)`), modes `manual`, `acceptEdits`, `auto`, `plan`, `bypassPermissions`. File tools
  are bound to the working directories (`--add-dir` adds more). Limit: a shell command acts with the owner's full
  rights; Bash rules filter command patterns, they are not a wall.
- **Claude Code's own OS sandbox** (`sandbox.enabled`, `sandbox.filesystem`, `sandbox.network`,
  `autoAllowBashIfSandboxed`): on Linux it uses bubblewrap: shell commands may write only in the project and reach only
  allowed domains. Needs `bubblewrap` and `socat` in WSL (not installed on the owner's machine; he installs them himself).
- **Codex**: `--sandbox read-only | workspace-write | danger-full-access` and an approval policy.
- Agent Manager already gives each Claude Code session its own `--settings` file (for hooks): a per-session policy can
  go there without touching the owner's settings.

## Proposed direction (to discuss before building)

A per-session « Access » setting, with a default per repository:

| Level | Write | Read | Shell |
|---|---|---|---|
| This folder only | the folder | the folder | OS sandbox when available |
| This folder, read elsewhere (default) | the folder | everywhere but secrets | OS sandbox when available |
| Full access (today) | everywhere | everywhere | free |

- Always denied, at every level: `~/.ssh`, Agent Manager's `keys/`, the Second Brain's tokens, `.env` files, `~/.aws`…
  (the deploy key reaches sessions through the environment; the agent never needs the file).
- The OS sandbox switched on when bubblewrap is present; the setup check says whether it is.
- The same policy mapped onto Codex's options. The session card shows its level.
- Open questions from the owner: package installs (pip / npm) and code run outside the project are the real risk; a
  per-project virtual environment or the OS sandbox are the candidates. Cloud sandboxes stay the place for full auto.
