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
- **Repository deploy keys**: each connected repository gets its own key, which opens that repository only; your
  personal SSH key is never used or read.
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
- **What it reads of your system** (Setup check, Engine room): Windows' version and whether virtualization is on,
  WSL's version and distributions, the size and drive of a distribution's disk file, the lines of your `.wslconfig`
  that set limits, memory and disk figures. All of it stays in the window: none is stored or sent. It changes none
  of it. Two actions exist there, each on your click only. **Install …** installs python3, tmux, git or
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
