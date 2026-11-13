# Changelog

Agent Manager GD is built in short loops. Each one ships something you can use, with its tests and screenshots.
Newest first.

## Unreleased: alpha

### Sandboxes: the inventory, always · Loop 38 (first steps)
- **Bring it to my localhost** no longer takes a port a Windows program already holds (the engine runs in WSL and
  could not see it: the browser landed on the Windows program). It reads Windows' listeners, read only, and takes
  the next free number; the port's line then says why, in orange: « 8000 is held by a Windows program, so 8001 »
  (or « taken on this computer »).
- Fixed: a cloud sandbox listed no port at all, so no **Bring it to my localhost**: its image has no `ss`. The
  ports are now read from the kernel's own list. Tried on a real Fly.io sandbox: a web server on 8000 reached from
  Windows.
- New, on a running sandbox: **Tunnel and ports**. **Connect** opens one lasting SSH connection to the sandbox,
  apart from its terminal. The block lists what listens in the sandbox (a web server, a dashboard) and
  **Bring it to my localhost** opens that port on `127.0.0.1` of this computer, on the same number when it is
  free; **Open in the browser** shows it. A wire is drawn for each port brought here, with dots running each way
  for what is sent and received, both rates and the totals. **Pause**, **Close**, **Disconnect**. It also says how
  the sandbox is doing: memory, load, disk, the time of a round trip. Nothing is made public; the sandbox's host
  key is remembered and a changed one refuses; a paused sandbox is never started. Not tried against a real sandbox
  yet: only against stand-ins for Fly.io and SSH.
- A connection that falls comes back by itself, with what it carried, and the block says why it fell and when it
  tries again. What you opened for a sandbox is remembered and comes back on the same address at the next
  connection. A failure says its family: the key refused, the SSH server not up yet, no answer in time, the port
  already taken on the other side, the host key changed.
- The way back from a cloud sandbox to the Second Brain, through its SSH tunnel, is narrowed: it reaches only the
  Second Brain's route and the engine's health, request by request; anything else is refused before the engine, and
  counted. When the lasting SSH connection is open it carries that way too, so an agent in the cloud sandbox keeps
  the Second Brain when its terminal is closed; the block says who carries it.
- A sandbox's terminal now checks the sandbox's host key too, against the one remembered at the first connection.
  Before, it accepted any.
- Fixed: a cloud sandbox's session started again (after WSL was restarted, or with Restart or Resume) ran a shell
  of this computer instead of reaching its cloud sandbox, while it still said « in a cloud sandbox ». It now
  reaches its cloud sandbox, where tmux kept the agent and its conversation.
- **A click on a session answers at once.** The list marks it and the header names it straight away; where its
  terminal will be, a small turning sign says « Opening … » while the terminal starts (a second or two on Windows).
  Before, nothing moved until the terminal had started. The Sandboxes page shows « Asking Fly.io for your
  sandboxes… » until its first answer, and the app asks Fly.io once at start, so the page usually opens at once.
- **The Sandboxes page no longer piles up work.** Every time it was drawn it started a timer of its own that
  asked the engine again thirty seconds later; each click added one more, so eight clicks made ten reloads in
  thirty seconds, each one rebuilding the page. One clock now asks every thirty seconds. And the tunnel block's
  frequent question is answered from what the engine last read (every five seconds) instead of going to the cloud
  sandbox twice over SSH each time.
- **Clicks answer at once on the Sandboxes and Repos pages.** Unfolding a cloud sandbox, opening the image's contents
  or choosing a size waited for the engine to ask Fly.io again (up to a few seconds) before anything moved; they now
  draw at once. The engine keeps Fly.io's list of machines ten seconds and refreshes it aside. The tunnel block and
  the repository lines were rebuilt every few seconds, which swallowed a click that came meanwhile; now only their
  figures move, and they are rebuilt only when something they show changed. A tunnel action says « connecting… »
  at once.
- **A running sandbox's health, like htop**: in its card, four charts over the last fifteen minutes (processors,
  memory, network in and out, load), each with the figure of now and a word when it is busy or nearly full, and its
  busiest programs with their processor and memory. Read every five seconds through its lasting connection.
- **The size of a sandbox is yours to choose**: one card per Fly.io size (shared 1 CPU from 256 MB to 1 GB, shared
  2 CPU with 2 GB, performance 1 and 2 CPU), each with its price a month and an hour and a bar against the dearest.
  The next sandboxes get the one chosen, and the estimate follows. Prices are Fly.io's published ones, read
  2026-11-12, for its cheapest regions; elsewhere they are said to be floors. Before, every sandbox had 1 shared CPU
  and 1 GB.
- Two sandboxes that listen on the same port each get their own address on this computer: the first keeps the
  number, the second takes the next free one, and each keeps its own afterwards.
- **Open a SOCKS proxy**: one address on this computer through which a program set on it reaches everything inside
  the cloud sandbox.
- **Let the sandbox reach a port of this computer…**: a rule, for one port and one cloud sandbox. Without a rule a
  cloud sandbox reaches nothing of this computer but its way back to the Second Brain. The rule has its wire, with what is asked
  and answered, and stays until you close it.
- The tab is denser: four tiles across, then two columns. On the left what you use to make one: deploy with the
  sizes, the costs, the image (one line once it is built). On the right the sandboxes, one per line like the
  repositories, the destroyed ones too, each with its life over thirty days; a line unfolds to everything about
  its sandbox, its tunnel and ports included. In a narrow window the columns stack.
- The **☁ Sandboxes** tab opens on an **Inventory** that is always there: every sandbox made from this computer,
  the destroyed ones too. Before, a destroyed sandbox left the page, and with all of them destroyed the page listed
  nothing. Four tiles: running now, paused, destroyed and kept (with what was measured in all), and **At Fly.io
  now**, the machines Fly.io holds at this moment, marked when one is unknown to Agent Manager.
- One line per sandbox, drawn: its state, its name, its size and region, and its life over the last 30 days as a
  bar: filled where its machine ran, a mark where it was made, a cross where it was destroyed; then how long it ran
  in all and what that cost at Fly.io's published price. The runs come from Fly.io's own machine history, kept
  after the machine is gone. When Fly.io cannot be reached, what was last known is shown, and said to be so.

### Repositories, a line each, and Azure DevOps · Loop 37
- New, in a repository's unfolded line: **Branches and their folders**, a map drawn like a metro's. The base branch
  is the line at the top, its latest commits as stations, now at the right. Each branch that has commits of its
  own, a folder of its own (a worktree) or an open session leaves it where it was made and runs under it, one
  station per commit, in its own colour. At the right of each line: its name, its commits, what the base made
  since, a small folder for a worktree, and a dot per session working there, breathing while it works. Rest the
  pointer on a line for its words; click a line whose session runs to show that session. Read from the disk:
  nothing is fetched.
- The **⎇ Repos** page is drawn, like the engine room. Four tiles on top: the keys that work, the repositories
  that need a hand, the sessions running, the hosts. Then one repository per line, each column a small drawing: the
  host as a chip; the key's state (a disc, a ring, a cross) with a thin bar that empties in ten minutes, and a sign
  that turns while the key is checked; what the key opens (one square, or a pile of them for a whole account); the
  folder's branch in a chip with what is not pushed and what changed; a dot per open session in the colour of its
  state, breathing while it works, and a click shows it; the sessions started day by day over fourteen days. The repositories that need a hand come first and
  are unfolded. A click on a name or its arrow unfolds the rest: the public key, where to add it, **Check**,
  **Rotate the key**, **Disconnect**, the folder. In a narrow window some columns leave, the host last.
- **Azure DevOps** repositories can be connected: `git@ssh.dev.azure.com:v3/organization/project/repository`
  (names with spaces too). Agent Manager makes the RSA key Azure DevOps asks for, says where to add it (User
  settings › SSH public keys) and explains a key that does not work in Azure's own terms (not on the profile,
  expired, repository not known). Azure DevOps has no key per repository: **the key opens everything your account
  reaches**, and the line says so. Not tried yet against a real Azure DevOps repository.
- The form says, as you type, which host an address names and what its key will open. A web address
  (`https://…`) is answered with its SSH form, filled in for you.
- Opening the page reads each folder again and checks again the keys checked more than ten minutes ago; each line
  says *checking…*, then how old its answer is. **Check all** does it at once. Nothing is checked while the page is
  closed, and a repository still waiting for its key is left alone until you press **Check**.
- The page no longer waits on git: listing the repositories ran two git commands each (about a second for four
  repositories on a Windows disk); it now takes a few milliseconds, and the folders are read aside.
- The **⎇ Repos** button of the top bar carries a **!** or a **✗** when a repository needs a hand; its tooltip says
  which.
- Corrected on the website: it said a check tells read and write access. A check tells that the key reaches the
  repository; whether it may push is known at the first push.

### The setup check reads from the ground up, and its engine room · Loop 36 (first steps)
- The themes moved from the ◐ menu into the **View ▾** panel: seven chips, each drawn in its own colours. Click one
  and the window changes at once; the panel stays open, so you can try them one after the other. ◐ keeps the
  settings (the list, usage, agent permissions, keys, shortcuts, connections, setup check).
- The top bar is arranged for more to come. **View ▾** replaces the five buttons Focus, Grid, Board, History and
  Review: it names the way the sessions are shown and opens the list of the five, each with its shortcut (the
  shortcuts have not changed). Beside it stand the managers, one button each: **WSL** (on Linux: **Computer**),
  **☁ Sandboxes**, **⎇ Repos**. A click opens a manager's page; a second click on it comes back to the sessions as
  they were shown. In a narrow window the managers show their sign alone.
- The **WSL** button is alive: **●** when everything stands, **!** when something deserves a look (a disk nearly
  full), **✗** when something is missing or the engine does not answer, then the memory in use; its tooltip says
  why. It opens the page that was only under ◐ › Setup check (still there too), now titled **WSL**. For it, the
  ground is read once a few seconds after the app starts, aside, and the engine is asked every 30 seconds.
- The **Engine room** is now a dashboard, under the Setup check. Five tiles say the moment: memory in use, sessions
  running, how busy the processors are, the room left on the disk, how long it has been up. Under them, **Memory in
  use, by session**: one bar per slice of time, one colour per session, over the last hour, 6 hours, 24 hours or
  7 days. Point at a bar and it says the time and what each session held. A time when the engine was not running
  stays empty; a small mark under the axis says where WSL (or the computer) started anew.
- Under the bars, the sessions in a table: how long each has been open, when its screen last changed, its memory
  now and at the most in the span, its share of a processor, and whether it works on the Windows disk. The sessions
  that ended within the span are listed after the running ones. Click a running session to open it.
- For that, the engine now keeps what it reads: one reading every 30 seconds, seven days of them, in a file of its
  own in its data folder (`data/host_history.sqlite3`). Older readings are deleted. Measured here: a reading takes
  about 6 ms of processor, a full week with five sessions is 5 MB. `AGMGD_HOST_SAMPLE=0` stops the readings. The
  bars begin when the engine starts with this version (it starts anew with the app): nothing is known of before.
- On Windows the memory tile also says how much memory Windows gives WSL at that moment, which is more than what
  Linux uses: Linux keeps files in memory, and Windows counts that too.
- When everything the app needs is there, the ladder is one line of marks; **Show every line** brings the lines
  back, and they come back by themselves when something is missing.
- Not seen in the real Windows window yet: the dashboard was checked on the test display, with real readings every
  2 seconds for its plumbing and made-up figures for its pictures.
- Also in the Engine room: the sessions that work on the Windows disk, where git is slower, and the limits your
  `.wslconfig` sets (read, never changed).
- On Windows the disk line tells the true room: WSL keeps a distribution's disk in one file on a Windows drive, and
  Linux may report hundreds of gigabytes free on a drive that has few left. The line is a warning when that drive is
  nearly full.
- When python3, tmux, git or ssh is missing, the check offers to install them: it shows the exact command, and
  **Install …** runs it in a terminal on the page, with the distribution's own package manager. Inside WSL it needs
  no Windows administrator and no password; on Linux `sudo` asks for yours in that terminal. Then the check reads
  again and starts the engine. Not tried for real yet: only against a stand-in for the package manager.
- **Restart WSL…** stops WSL and starts the engine again. It names the sessions that would stop, then asks you to
  type « restart ». Not tried for real yet: only against a stand-in for WSL's command.
- On Windows, the Setup check now starts with Windows itself (its version, virtualization), then WSL, then the Linux
  distribution, before the programs, the engine and the agents. It stops at the first thing that is missing and
  says what to run; the lines under it are marked « · ».
- When the engine does not answer, it says why: not running (« Check again » starts it), starting or stuck, another
  program on its port, or running inside WSL where Windows cannot reach it. Before, the app only said « engine
  unreachable ».
- The window no longer freezes while the check reads: the reading takes about three seconds on Windows and is done
  aside. On the test display the page opens in 7 ms while a three-second reading goes on.
- WSL's own command is never run where WSL is not installed: Windows keeps a stand-in there that offers to install
  it, and a check that only looks must not start that.
- Corrected: the app, the install guide and the Docs said that the app downloads flyctl itself (pinned version,
  checksum checked). It never did: it looks for a flyctl you installed. The sentence is gone until it is true.
- Not tried: a Windows without WSL, without a distribution, or in another language. Those cases are checked against
  outputs written by hand from the documentation; only « everything is there » was read on a real Windows.

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
- A pause in the middle of a sentence no longer leaves a full stop there.
- The box grows: drag its bottom right corner to see more of a long text; its size is remembered, and a double
  click on the corner gives it its own size back.
- The words follow the voice more closely: a phrase is shown after half a second of quiet, or at the first dip of
  the voice once it is four seconds long. What is kept still comes from the whole recording, written in one piece.
- The last words are no longer lost. The box goes on listening for a moment after you release the key, and the end
  of the recording, however short or low, is always written down: the text that is kept now always comes from the
  whole recording. Before, what was said between the last pause and the release was dropped when it was short or
  said low. The text is in the box as soon as the whole recording is written, without waiting for a piece still on
  its way.

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
