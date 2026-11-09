# Agent Manager GD

Your AI coding agents, side by side, in a live and themable desktop app.

Run Claude Code, Codex and other agent CLIs in real terminals inside one window: every session persists in tmux,
shows its live state, revives on its own conversation, forks, and works in its own git worktree. Every session is
wired to your [Second Brain](https://github.com/sonixz/second-brain-gd) over MCP, so what one agent learns, the next
one knows.

Status: **alpha.** Open source under the MIT licence (`LICENSE`). Loops 1 to 15 of the plan (`docs/brief/PLAN.md`) are done; the story is in `DEVLOG.md`.

## Install (Windows)

`tools/build_release.sh` makes `dist/AgentManagerGD-<version>-win64.zip`. Unzip it, then right-click `install.ps1` →
*Run with PowerShell*: it copies the app to `%LOCALAPPDATA%\Programs\AgentManagerGD` and adds a Start menu shortcut,
for your user only, **without administrator rights**, and downloads nothing. `uninstall.ps1` removes it (your
sessions, keys and settings stay). The first launch opens the **Setup check** if something is missing (WSL, python3,
tmux, git, ssh; Claude Code, Codex and flyctl are optional). Details: `docs/INSTALL.md`.

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
- **The Second Brain in every session**: when the Second Brain runs on this computer, each Claude Code or Codex
  session gets an MCP key of its own (named « Agent Manager · <session> », level « propose items »: it reads and
  searches the Brain, and what it proposes waits for your OK in the Brain). The key is passed at launch only
  (`--mcp-config` / `-c mcp_servers…`) through the Brain's own relay; a fork gets its own key; removing a session
  revokes it. The Brain's timeline shows which session proposed what. `AGMGD_BRAIN=off` turns it off.
- **Sessions that document themselves** (New session → « ↳ Document this session in the Brain as it works », under
  the Brain, Claude Code only for now): the agent gets a directive at launch (`--append-system-prompt`, never written
  into the repository). It orients in the Brain first (the project card, the last session journal, open questions,
  recent decisions, your documentation guidelines note), checks that against `git log` and the other live sessions,
  says where the project stands, then proposes your words, decisions and a session journal at each milestone, and
  updates the journal and the project card before the end. Everything still goes through the Brain's archivist.
- **Agents pilot agents**: every agent session is also offered Agent Manager's own MCP server (`agent-manager`):
  `list_sessions`, `session_status`, `read_screen` for any session; `start_session` makes a child session (shown
  « ↳ parent » on its card), `send_to_session` and `wait_for_session` work on its own children only. No tool presses
  keys for another session, so an agent never approves on someone else's behalf.
- **Context that survives**: **Wrap up** (right click) asks the agent to write its own summary (what was done,
  decisions, files touched, what is left, how to continue) to a file and, when the session shares the Second Brain, to
  propose it there with its own key (you approve it in the Brain). When the agent is done, the summary is kept with
  the session (History, searchable, « Read ») and the session is archived. A new session in the same folder can start
  from it: « Brief it with the latest summary of this folder » sends a short first message pointing to that summary.
- **Review** (Ctrl+Shift+R): the selected session's changes, file by file (arrow keys), coloured, with line numbers:
  uncommitted changes, everything since the session started, or its branch against the target. Click a line to
  comment it (or comment the whole file); **Send review** sends the open comments to the agent as one numbered request
  (file:line, the comment, the line's code); sent comments stay visible until marked handled.
- **Shortcuts** (◐ → Shortcuts…): change any shortcut (click it, press the new keys); the voice keys are held keys.
- **Connect other tools** (◐ → Connect other tools (MCP)…): the command to plug Agent Manager's MCP into Claude Code,
  Codex or any MCP client outside the app. Such a tool may list sessions, read their screens and start new ones; it
  can never type into a session or approve anything.
- **Setup check** (◐ → Setup check…): what is found, what is missing, and the command to run yourself.
- **Second Brain keys** (◐ → Keys…, below your API keys): every Brain key Agent Manager made, with the session or
  sandbox using it. Unused ones can be revoked (one, or all unused at once, confirmed); a key in use goes away with
  its session or sandbox.
- **Keys** (◐ → Keys…): paste your own API keys (OpenAI for the voice, Fly.io and Anthropic for cloud sandboxes).
  On Windows they are encrypted with DPAPI for your Windows user; they are never shown again or logged, and are read
  only when a feature needs them.
- **Dictation**: hold **F8** and speak; on release the text is written into the active session's prompt (as a paste,
  never with Enter): you read it and press Enter yourself. Transcription by OpenAI with your key (≈ $0.003/min, shown).
- **Voice commands**: hold **F9** and say « approve Themes », « refuse Docs », « go to Cart refactor », « grid view »,
  « who is waiting? », « wrap up Docs », « new session … » (French or English). Understood by plain rules, no model.
  Approving, refusing and wrapping up always ask for a visible confirmation first.
- **Spoken status** (◐ → Spoken status, off by default): short spoken notices with your system's own voice (free,
  offline): « Themes attend ton OK », « Docs a fini ».
- **Usage** (◐ → Usage…): tokens per session, per day and per tool, read from the agents' own logs (Claude Code,
  Codex) on this computer. No money amount is shown for agents: their logs carry none (and subscriptions have no
  per-token price).
- **Cloud sandboxes** (☁ Sandboxes; New session → Where: a cloud sandbox): a throw-away Fly.io machine for one session,
  with your Fly token (Keys). « Prepare » once makes an app and our image (`sandbox/Dockerfile`) in your organisation's
  private registry; then a sandbox is ready in about 30 s. Its terminal opens like any session; the same SSH
  connection carries a tunnel so the agent reaches your Second Brain (through the engine, authenticated by the
  sandbox's own secret; the Brain's keys never leave Windows). The manager shows each sandbox's machine, running time,
  estimated cost, and its connection (terminal, tunnel, latency, Brain reachable); Start, Stop (pause), Mark finished,
  **Destroy** — only by you, confirmed, after Agent Manager showed the work not pushed. Machines of your organisation
  it does not know are listed, never touched unless you destroy them (« Destroy… », confirmed, after listing what an
  app holds). Agent Manager never destroys a sandbox on its own.
  The tab works in steps: the image (what it holds, deploy it once, rebuild), deploy a sandbox (the estimate first,
  then a shell or an agentic coding session), costs (today, this month, a chart; measured from Fly's machine history),
  and a live card per sandbox (time on, tunnel, MCP, branch, unpushed work, cost). A sandbox always keeps its session
  in the list. **Budget**: a monthly amount (this month's estimate shown against it, a warning past 80 %, no new sandbox at
  100 %), and two caps you can turn on that only *pause*: a sandbox idle for N minutes, or every sandbox once the
  budget is reached. « Stop everything » pauses all running sandboxes.
- **Connected repositories** (⎇ Repos): add a repository's SSH address; Agent Manager makes a deploy key for it only,
  shows the public key to add on GitHub (*Deploy keys*, with write access), checks it, and sessions started on that
  repository use that key only. Rotate or disconnect any time. Details: `docs/REPOSITORIES.md`.
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

Stack: Godot 4.7 (interface) + Python (engine), local-first. Licence: MIT (`LICENSE`); third-party parts in `THIRD_PARTY_NOTICES.md`. Part of [GD Project](https://github.com/sonixz/gd-project).
