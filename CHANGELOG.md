# Changelog

Agent Manager GD is built in short loops. Each one ships something you can use, with its tests and screenshots.
Newest first.

## Unreleased: alpha

### What you do shows at once · Loop 35
- Creating a group, folding one, moving a session or a group: the list changes at once, and the engine is told after.
  Before, nothing moved until the engine had answered twice. Measured with twenty sessions on the test display: a
  moved session was on screen after 250 ms, now after 10.
- The list keeps every row that did not change, also when rows change place.
- A dictation said in several pieces is written down once more, in one piece, when you release the key: that text
  replaces what was shown while you spoke, which was written piece by piece and read badly. If the final writing
  fails, the pieces stay.

### The dictation box · Loop 34
- Hold F8 and speak: a small see-through box at the bottom shows what you say, phrase by phrase, a moment after each
  pause. On release the text stays in the box: read it, correct it, hold F8 again to add more. Enter sends all of it
  to the selected session; nothing goes to an agent before your Enter. Into a shell it is only written at the prompt.
- The box's text is saved on your computer and survives closing the app; Earlier brings back what you sent or emptied.
- F9 uses the same box: a command runs (it still asks first), anything else joins the text.
- A dictation is written down piece by piece, cut at each pause, each piece with the words said just before: a long
  one never waits for one long transcription.
- The box goes where you want: drag it by its top line, anywhere in the window; it remembers its place, and a double
  click sends it back. See-through while it waits, solid while you use it.
- A pause in the middle of a sentence no longer leaves a full stop there, and a pause must last a little longer
  (0.9 s) to cut.

### Faster · Loop 33
- Picking a session, changing view and the 2-second refresh no longer stutter. Measured with twenty sessions on the
  test display: opening a session again 80 ms → 8 ms, for the first time 216 ms → 51 ms, the Board 140 ms → 61 ms, a
  refresh that found a change 290 ms → 75 ms.
- Why: each bold text made a new font (3 to 5 ms each, a dozen per click); every click redrew every row of the list;
  the engine wrote to its database once per agent at every refresh and read each working agent's screen with its own
  tmux call; each call to the engine advanced one step per drawn frame. Fonts are now made once, only the rows that
  changed are redrawn, the engine looks everybody up together, and calls to it run in their own thread.
- A view no longer fades in from nothing (0.18 s): it is there at once.

### One session per line · Loop 32
- The session list shows one session per line: state dot, tool, name, short marks and the state in a word. Twenty
  sessions fit where eight tiles did; the rest is in the line's tooltip. ◐ › One session per line (or the palette)
  switches back to the tiles; your choice is remembered.
- « They wait for you » follows: one request per line, the agent's name (it opens the session), Approve and Refuse
  or Reply… beside it, what it asks in the tooltip. Up to eight requests show, where four tiles did.

### Website
- The home page shows the orchestrator and the permissions, tells the dictation box and the list in lines, and its
  list of loops goes up to Loop 35. Every screenshot is retaken with the session list in lines.

### Agent permissions · Loop 31
- ◐ › Agent permissions…: every agent with its level, file access, Claude Code's sandbox and git rights, and Edit…
  for each; a default file access per group (right click the group), beside its default level.

### Shell commands contained · Loop 30 (ready, waiting for bubblewrap)
- In Permissions…: « Contain shell commands too », Claude Code's own sandbox, filled from the file access (its home
  closed except its folder, keys never readable, read-only folders not writable), never a silent fallback. Offered only
  when bubblewrap and socat are installed (by you: they need administrator rights); otherwise greyed out with the command.

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
- Folding or opening a group by a click waited for the engine before anything moved: its header acted on an old copy
  of the list. It now folds at once.
- When the microphone gives nothing (Windows changed the audio device, a headset went off), the dictation box says so
  after a few seconds and opens the microphone again once. Before, it listened, nothing came, and nothing said why.
- The first session started on a fresh tmux server (after a reboot) could fail with « server exited unexpectedly »:
  the server and its first session are now started in one tmux call, and asked once more if the server was dying.
- A long dictation was thrown away: the app waited 10 seconds for the text while the writing of a long recording
  takes longer, then said « engine unreachable ». It now waits as long as the writing may take. A recording that
  cannot be written down is kept (Ctrl+K › Send my last recording again); the panel shows how long it has been
  listening and stops by itself after 5 minutes; nothing heard, or a terminal closed meanwhile, is said.
- The same 10 seconds applied to every action (a merge, a clone, a restart on a slow disk): actions now get 60.
- The voice panel (F8, F9) kept the theme the app had started with; it now follows a theme change at once, like
  three dialog texts that kept the old text colour.
- A cloud sandbox whose terminal could not connect ended on « Pane is dead », sometimes with a Python error, and the
  session looked ended although the machine was there. Its terminal now says what it does (« connecting… », « still
  waiting… »), reopens its tunnel when it fell, tries three times, then waits for Enter: the session stays alive. A
  lost connection reconnects by itself, to the same session in the sandbox. A sandbox paused by a cap or by you is
  never started again without you: its terminal asks first.
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
