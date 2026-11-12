# Security

Agent Manager GD runs coding agents on your computer, can let them start other agents, and holds a few keys. This
page says what it protects, what it does not, and how to report a problem.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting (the repository's **Security** tab ›
*Report a vulnerability*). You will get an answer as soon as possible; a fix comes before any public detail.

## What it protects

- **The local engine** listens on 127.0.0.1 only and answers only with its token (a file readable by your user only).
- **Your keys** (OpenAI, Fly.io, Anthropic) are encrypted with Windows DPAPI for your user on Windows; on Linux they are
  files readable by your user only (0600). They are never shown again and never written to a log.
- **Repository keys**: each connected repository gets its own key; your personal SSH key is never used or read.
  On GitHub it is a deploy key, which opens that repository only. Azure DevOps has no key per repository: the key
  goes on your profile and opens everything your account reaches there, and the repository's line says so; to keep
  agents to chosen repositories, add it to an account made for them. A key is checked by one SSH connection to the
  repository's host with that key (`git ls-remote`), when you open the Repos page, on « Check all » or on
  « Check »; never while the page is closed.
- **A sandbox's ports on this computer**: a port of a sandbox is brought here only when asked, through one lasting
  SSH connection per sandbox. It listens on `127.0.0.1` and nowhere else; what passes is counted, never read; it can
  be paused or closed. No public address is ever made. The sandbox's host key is remembered at that connection's
  first use, and a key that changed refuses. Opening a connection never starts a paused machine. A SOCKS proxy toward
  a cloud sandbox, when you open one, is on `127.0.0.1` too. In the other direction, a cloud sandbox reaches nothing
  of this computer except its way back to the engine, through its SSH tunnel, and the engine answers it on two
  addresses only (its health, and that cloud sandbox's own Second Brain route, guarded by its secret). Anything else
  needs a rule you make for one port of this computer and one cloud sandbox; it is listed, counted, and stays until you close it. You ask for it in
  ☁ Sandboxes, « Tunnel and ports ». Not tried against a real sandbox yet.
- **Agents' logins**: agent CLIs run with their own login; Agent Manager never reads, copies or relays those tokens.
- **Second Brain keys**: one per session, at the « propose » level (read, search, propose; the Brain's archivist files
  proposals with your rules); removing a session revokes its key.
- **Paths no agent may touch**: at every permission level, *No permission* included, Claude Code sessions get deny
  rules for `~/.ssh`, `~/.aws`, `~/.gnupg`, the GitHub CLI's login, `.env` files, Agent Manager's keys and the Second
  Brain's tokens.
- **File access per session**: *Contained* and *Read only* keep Claude Code's file tools inside the session's folder
  and the extra folders you list; a session started by an agent is never less restricted than its parent.
- **Agents that start agents**: a session started by an agent never gets more permissions than its parent; by default
  the orchestrator and its sessions are refused `git push`, `git merge` and `git rebase`; at most 4 run at once under
  one root session, 2 levels deep. An agent can only write to sessions it started, and never presses keys (approvals) for
  another session.
- **What it reads of your system** (the WSL page: Setup check, Engine room; read when that page opens and once a
  few seconds after the app starts, for the top bar's button): Windows' version and whether virtualization is on,
  WSL's version and distributions, the size and drive of a distribution's disk file, the lines of your `.wslconfig`
  that set limits, memory and disk figures. None of it is sent anywhere, and what Windows tells stays in the window.
  One thing is kept on your disk: every 30 seconds the engine writes down the memory in use, how busy the
  processors are and what each running session weighs (its name, its memory, its share of a processor), for seven
  days, in `data/host_history.sqlite3` in the engine's data folder. Older readings are deleted; deleting the file
  loses the curves and nothing else; `AGMGD_HOST_SAMPLE=0` stops the readings. The app changes nothing of your
  system by itself. Two actions exist there, each on your click only. **Install …** installs python3, tmux, git or
  openssh-client, and nothing else, with the distribution's own package manager: the command is shown first and
  runs in a terminal you see, as the distribution's root inside WSL (no Windows administrator) or through `sudo` on
  Linux. **Restart WSL…** runs WSL's own `wsl --shutdown` after you typed « restart ».

## What it does not protect

- **Scripts an agent writes and runs.** Deny rules cover Claude Code's file tools and the file commands it recognises
  in a shell, not a program that opens files itself. Only an operating-system sandbox stops that (Claude Code's
  own sandbox; on Linux and WSL it needs bubblewrap and socat, which you install yourself). Use *No permission* only
  on projects you trust, ideally in a worktree.
- **Codex** has no deny rules: its own sandbox limits where it writes, not what it reads.
- **What agents send to their providers.** Your prompts and the files agents read go to their providers under your
  account, as with the CLIs alone.
- **Cloud sandboxes** run on your Fly.io account; destroying them is always your action.
