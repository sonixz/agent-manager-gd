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

## Loop 7: the context that survives (2026-11-08)

Wrap up: the engine types a request into the agent's session (write a Markdown summary to a file in our data folder:
what was done, decisions, files touched, what is left, how to continue; propose it with propose_item when the
session shares the Second Brain), shows « writing its summary », and when the file exists and the agent is no longer
working (its Stop hook), stores the summary (`summaries` table: session, conversation, folder, text) and archives the
session. History shows the latest summary (« Read » for all of it) and searches its text. A new Claude Code / Codex
session in the same folder can be briefed: its first message points to the latest summary (and to the Brain when
shared). Real check with Claude Code (one small prompt, owner-approved, Brain proposal off for the test): it wrote
its summary unasked for permission, the engine kept it and archived the session; the new-session dialog then offered
the brief. Tests: 31 (3 new with a fake agent). Captures in docs/screens/loop7.

## Loop 8: diff review with line comments (2026-11-08)

engine/review.py: a session's diff in three modes (uncommitted changes with new files included; since the commit the
session started from, now recorded at creation; its worktree branch against the repository's target), parsed from
`git diff` into files, hunks and numbered lines (renames, deletions, binary files, long files truncated). Line
comments are stored (`review_comments`: open, sent, handled); « Send review » types them into the agent's session as
one numbered request (file:line, the comment, the line's code). The Review view: file list with +/− and comment
counts, the coloured diff, click a line to comment, comment cards under their lines (Delete while open, Handled once
sent). Bug found by the tests: a binary file had no name (no ---/+++ lines): the path now also comes from the
`diff --git` header. Tests: 35. Captures in docs/screens/loop8.

## Loop 9: connected repositories and deploy keys (2026-11-08)

engine/repos.py: add a repository by its SSH address (https refused with the reason), an ed25519 deploy key per
repository (private key 0600 in our data folder, never in the database or a log), the public key and the GitHub
« Deploy keys » page link, Check (`git ls-remote` with that key only, a clear message when the key is not added yet),
Rotate (reminds the old fingerprint to delete) and Disconnect. A session started on a repository works in its folder
(cloned with the key on first use) and its tmux environment carries GIT_SSH_COMMAND with that key only
(IdentitiesOnly, our own known_hosts). The Repositories view (⎇ Repos) and the Repository choice in New session;
cards show « ⎇ <repository> ». docs/REPOSITORIES.md documents keys and connected repositories. Tests: 40 (a local
bare repository stands in for GitHub through file://, allowed only in tests). Bug found: the address parser kept
« .git ». The real GitHub check needs the owner to add a deploy key (★).

## Loop 10: Keys and voice dictation (2026-11-08)

engine/keys.py: the owner's API keys (OpenAI, Fly.io, Anthropic), encrypted at rest with Windows DPAPI through
PowerShell (the value goes base64-encoded on stdin, never on a command line; a non-ASCII round trip checked), 0600
files, never returned by the API (only set / when / how protected); plain 0600 files only on a Linux without Windows,
said on screen. engine/voice.py: a WAV to text through OpenAI's transcription endpoint (gpt-4o-mini-transcribe, then
whisper-1), with the estimated cost. The app: a Keys view (masked fields, Save, Remove with confirmation) and hold-F8
dictation: the microphone on a silent bus with a capture effect, a 16 kHz mono WAV, a « listening » overlay with a
level meter; the text is pasted (bracketed) into the active session's prompt, never sent with Enter. Checked with a
fake transcription: the dictated French text lands in a shell's prompt and is not executed; Windows headless still
loads. Tests: 43. The real voice test needs the owner's OpenAI key and microphone (★).

## Loop 11: voice commands and spoken status (2026-11-08)

Hold F9 for a command (F8 stays dictation). engine/voice_commands.py understands the transcribed sentence by plain
rules in French and English (approve, refuse, wrap up, go to, views, who is waiting, new session; a bare session name
opens it; an unknown session is never guessed; « approve » alone targets the only session waiting for an OK). The app
asks for a visible confirmation before approving, refusing or wrapping up. Spoken status uses the system's own voice
through Godot's text-to-speech (free, offline; a French voice when there is one), off by default, toggled in ◐ or the
palette; « who is waiting? » always answers aloud. Checked: the commands drive the app (grid view, open Build,
confirmation for « approve Themes », an unknown sentence ignored), the spoken answer text. Tests: 46.

## Loop 14, first part: agent usage from their own logs (2026-11-08)

engine/usage.py reads, read-only, the logs the agents write themselves: Claude Code's transcripts (assistant
messages' usage, counted once per message id: the same message is often written twice while streaming) and Codex's
rollouts (the last cumulative token_count). Tokens per session (through its recorded conversations), per day and per
tool; a session without a readable log says so. No money amount: the logs carry none, and on a subscription a price
would mislead. The Usage view: totals per tool, tokens per day (one series, thin bars, details on hover), a table
per session. Captured with a real log of this computer. The Fly.io cost part waits for the sandboxes (Loops 12–13).
Tests: 47.

## Loop 12: Fly.io sandbox go/no-go — GO (2026-11-08)

With the owner's org token (Keys, DPAPI) and his « agent-manager » organisation. flyctl v0.5.5 from the official
release (checksums checked). A machine from our own image (sandbox/Dockerfile: tmux, git, sshd on 2222, Node, Claude
Code, Codex; built by Fly's remote builder into the org's private registry) is ready in ≈ 30 s in Toronto (Montréal
is closed to new machines); the terminal attaches in 0.6 s with 45 ms key-to-echo; a reverse SSH tunnel makes the
sandbox's 127.0.0.1:8765 reach this computer (the Brain's path); the sandbox's tmux opens in Agent Manager. Fly's own
SSH (port 22) gives no usable pseudo-terminal to a program, hence our sshd on 2222 behind `flyctl proxy`. Cost ≈ $0.004;
the machines are stopped, not destroyed. Details: docs/research/SANDBOX-SPIKE.md.

## Loop 13: the sandbox manager, tunnels, connections, supervision with the Brain (2026-11-08)

engine/sandboxes.py: « Prepare » (an app « agmgd-… » in the owner's organisation and our image built by Fly into its
private registry; a minimal fly.toml because a new app has no machine to take a configuration from; run in the
background with its progress shown), one machine per sandbox with its own SSH key, records, Start, Stop, Mark
finished, the work not pushed (git status and unpushed commits over SSH), Destroy only when confirmed (revokes the
sandbox's Brain key, deletes its SSH key), orphans (machines and Agent Manager apps it does not know) listed and never
touched, running time from the machine's events and the estimated cost from Fly's published prices.
engine/sandbox_attach.py: the session's terminal (starts the machine if stopped, flyctl proxy to our sshd, first-run
setup — the agents' API keys and the repository's deploy key travel on ssh's stdin into 0600 files, the repository
cloned on am/<sandbox>, the agent started in tmux — then ssh -t with a reverse tunnel). The engine's
/sandbox-brain/<secret>/ forwards MCP calls to the Brain through the Brain's own Windows Python, which reads the
client's token itself. Connection report: machine, terminal, tunnel, latency, Brain reachable. The ☁ Sandboxes view
and « Where » in New session. A session cannot be removed while its sandbox exists. Real check on the owner's account:
two sandboxes (a shell, Claude Code sharing the Brain), terminals open, tunnels up, the Brain reachable from the
Claude sandbox, a wrong secret refused, orphans listed, machines stopped (not destroyed). Bugs found on the way:
prepare failed on a new app (fly.toml), and the app gave up after 10 s while a sandbox takes ~20 s to start
(timeouts per call now). The test that failed now and then was caught: a shell's first prompt can come late under
load. Tests: 51.

## Loop 14, Fly.io part: budget and caps that only pause (2026-11-08)

engine/sandboxes.py: a monthly budget (sandbox_config), this month's estimated spend (running time from the machines'
events × the published price), new sandboxes refused once it is reached, « Stop everything » (pauses every started
sandbox), and two optional caps the owner turns on: pause a sandbox whose terminal has been idle N minutes, or pause
all of them when the budget is reached. The engine checks them at most once a minute. Nothing in this path can
destroy: a test checks no destroy call is ever made. API: POST /sandboxes/budget, POST /sandboxes/stop-all. The ☁
Sandboxes view gets the budget line (amber past 80 %, red at 100 %), its settings and the Stop everything button
(confirmed). Capture on the owner's real (stopped) Fly app, read-only: docs/screens/loop14/42-sandbox-budget.png.
Tests: 52.

## Loop 15: finish and installer (2026-11-08)

- **Setup check**: engine/doctor.sh (read-only) finds python3 (3.10+), tmux, git, ssh, and the optional claude, codex
  and flyctl, inside WSL on Windows. The ◐ menu's « Setup check… » shows each one found or missing with the command
  to run yourself; it opens on its own when the engine cannot start, and says how to get WSL when it is missing.
  Nothing is installed or downloaded.
- **Shortcuts**: every shortcut is now a setting (◐ → Shortcuts…): click it, press the new keys, Escape cancels, back
  to the defaults. A terminal keeps its keys: Ctrl shortcuts act there with Shift added. The palette, the voice
  overlay and the status line show your keys.
- **Connect other tools**: Agent Manager's MCP (engine/mcp_agents.py) offered to tools outside the app, with the
  commands for Claude Code, Codex and any MCP client, copy buttons. Without a session of its own such a tool can
  look and start sessions but never type into one (test). It finds the engine's data folder on its own.
- **Release build**: export presets (Windows; Linux waits for Godot's Linux export template), release builds of
  VtTerminal, tools/build_release.sh (the app, its libraries, engine/ and the sandbox recipe next to the executable,
  a zip), installer/install.ps1 and uninstall.ps1 (per user, no administrator rights). In a release build the app
  starts the engine from its own folder. The terminal font is now loaded as an imported resource (a release has no
  raw .ttf inside: found by the first headless run). Checked on Windows, headless: the release and an installed copy
  each start their engine from their own folder through WSL (own port and data folder), then everything removed.
- Docs: docs/INSTALL.md, README. Captures: docs/screens/loop15. Tests: 53.
