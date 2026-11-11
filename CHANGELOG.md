# Changelog

Agent Manager GD is built in short loops. Each one ships something you can use, with its tests and screenshots.
Newest first.

## Unreleased: alpha

### File access · Loop 29
- In New session and Permissions…: Open, Contained (its file tools stay in its folder) or Read only, plus extra folders
  (read and write, or read only). Filled with Claude Code's own settings; Codex read only is its read-only sandbox.
  A child is never less restricted than its parent. A guard rail on file tools, not a sandbox for shell commands.

### Git rights per session · Loop 28
- In Permissions…: « Enable git push » and « Enable git merge and rebase », per session. The orchestrator's sessions
  start without them, yours with them; a box lifts or adds Claude Code's deny rules, applied on the same conversation.

### Permissions on an open agent · Loop 27
- Right click a session › Permissions…: change its level and apply it on the same conversation, at once when it is
  idle, at the end of its turn when it works, or at its next start. Its sessions above the new level come down to it.
- A new level, « Per my config »: Agent Manager passes no level option and your own Claude Code or Codex settings
  decide (sessions you start only).
- Each change is logged; the engine's API token is now refused to the agents' file tools too.

### Fixed
- An `ask_owner` question clears as soon as you answer, also when you type in the session's terminal; the state reads
  « asks you something » (the header: « asks you: … »).
- Claude Code's idle reminder after a turn no longer shows a session as asking you something.
- The orchestrator and the sessions it starts have Remote Control (a child follows its parent; `start_session` can
  force it); a child without a group is named « Parent · Session » in claude.ai/code.
- Under WSL the wall clock can step back; the engine now orders the agents' events with the system's monotonic clock,
  so a finished wrap-up is always archived and an answered approval always unsticks (it was the flaky test).

### Orchestrator (beta) · Loops 25–26
- One orchestrator session for all your connected repositories, in a floating window (◆ Orchestrator · beta, or
  Ctrl+O): its terminal, its plan, its sessions; move it, resize it, minimise it.
- It reads the Second Brain, proposes a plan and waits for your OK, then starts sessions in worktrees on the right
  repository with the right tool and model, follows them and hands you each result to review.
- Routing rules you edit (which tool and model for which kind of task), a live plan, a daily token budget read from
  the agents' own logs.
- Guard rails: it and its sessions are refused `git push`, `git merge` and `git rebase`; at most 4 sessions at once,
  2 levels deep, never more permissions than their parent; Stop all.

### Permission levels · Loop 24
- Ask before acting, Auto edits, Auto (default), No permission; a default per group.
- At every level, agents' file tools cannot read or change `~/.ssh`, `~/.aws`, `~/.gnupg`, `.env` files, Agent
  Manager's keys or the Second Brain's tokens.

### Approvals that unstick · Loop 23
- Approve and Refuse answer at once; ✕ hides a request from the queue (it stays on the agent's card).
- One notification per request: a soft sound (♪ mutes it), a taskbar flash, the count in the window title.

### The Second Brain, visible · Loop 22
- A live badge (connected, agents linked, proposals today) and a ✦ light per session: its own key, documenting, a
  pulse when it uses the Brain, a warning when it should document and does not.

### Website · Loops 17–21
- An index with an animated control room, twelve How-to guides with a real screenshot per step, the Docs, all
  regenerated and checked by `tools/site.sh`.

### Sandboxes, usage and installer · Loops 12–16
- Claude Code or Codex in a throw-away Fly.io machine, reached through an SSH tunnel; a manager with costs, caps that
  only pause, leftovers and keys to clean up.
- Token usage per session, day and tool, from the agents' own logs.
- A Windows installer for your user only, without administrator rights; a Setup check.
- Copy from any terminal, sign-in links included; repositories in your own folders.

### Voice · Loops 10–11
- Hold F8 to dictate into a session; hold F9 for a voice command (approve, refuse, go to, who waits for me).
- Your own API keys, encrypted on Windows, never shown again.

### Repositories, review and context · Loops 7–9
- Connect a repository: Agent Manager makes a deploy key for it only; agents use it for git.
- Review a session's diff and comment lines; the comments go to the agent as one request.
- Wrap up a session into a summary; brief the next one with it.

### Agents and the Second Brain · Loops 5–6
- Resume, fork, worktrees, and a history that never forgets.
- Each agent session gets its own Second Brain key; sessions can document themselves.
- Agents pilot agents through Agent Manager's own MCP server.

### The control room · Loops 1–4
- A real terminal in Godot on libghostty-vt, on Linux and native Windows.
- Sessions that survive in a private tmux server; a project tree with groups; live states (working, waits for your
  OK, waits for an answer, done); a queue of what waits for you; themes.
