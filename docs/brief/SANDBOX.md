# Cloud sandboxes on Fly.io — design notes (draft, 2026-11-08)

Not built yet. The owner's input: log the agents in once, for good; projects come from many repositories (and some
are not git at all), so the code flow must not assume one repository; the Second Brain should reach the cloud
through a tunnel.

## 1. A cloud host, not a cloud session

A Fly Machine with a persistent volume is a **cloud host**, like a remote WSL: our image (tmux, git, Claude Code,
Codex, Python, sshd) runs **our own engine**, and Agent Manager talks to it exactly as it talks to the local one.
Every feature (tree, states, history, resume, Brain, summaries) works the same; a session simply lives on a host
(« Local » or « Cloud · <name> », badge ☁).

- **Log in once, for good**: the home folder is on the volume (`~/.claude`, `~/.codex`, `~/.config/gh`). The first
  time, the owner logs in himself in a terminal of that host (`claude`, `codex login`, `gh auth login`); it stays.
  Agent Manager never copies, reads or relays a login token.
- **Many projects on one host**: each session has its own folder on the volume (`~/projects/<name>`); one machine,
  many sessions, as locally.
- **Cost**: the machine stops when no session works (auto-stop), restarts on demand; the cost shows on the host,
  with a monthly cap set by the owner.
- **Isolation, later**: throw-away machines per risky task (a copy of a project, destroyed after).

## 2. Code in both directions, per session (no single repository assumed)

When starting a cloud session, the owner picks where its code comes from:

| Source | In | Back |
|---|---|---|
| A git remote (GitHub, GitLab…) | `git clone` on the host (git credentials logged in once, on the volume) | the agent pushes a branch; or the local repo fetches it from the host through the tunnel (`git fetch sandbox am/<name>`) |
| A local folder (git or not) | uploaded as a snapshot over SSH (a tar, `.gitignore` respected) | reviewed as a diff in Agent Manager (Loop 8), then applied locally on approval; never synced silently |
| Nothing | an empty folder | download the folder |

Live two-way sync (rsync or mutagen) stays out at first: it hides who changed what. The diff review is the gate.

## 3. The Second Brain through a tunnel

The Brain only listens on 127.0.0.1 of the owner's computer. While Agent Manager is open, it keeps an **SSH reverse
tunnel** to each cloud host (Windows' own `ssh.exe` over `fly proxy`, so it reaches the Brain on Windows' localhost):
the host's 127.0.0.1:8765 leads to the Brain's `/mcp`. Each cloud session gets its own Brain key as today (level
« propose items », revoked when the session is removed), used over HTTP through the tunnel. When the app is closed
the tunnel is down: the agent gets a clear « Brain unreachable » and keeps working; its end-of-session summary is
brought back and proposed to the Brain locally.

## 4. What is needed from the owner

A Fly.io account and its API token (dotenvx), the agreement to install `flyctl` (a download, checked), a registry for
the image (Fly's or GHCR; visibility is the owner's choice), and a small test budget with a cap.

## 5. First milestone (go/no-go, like the terminal)

One host: create the machine and volume from our image, log in once, a session's terminal attached in Agent Manager,
stop and restart it with the login kept, the Brain reachable through the tunnel, destroy it. Measured: start time,
terminal latency, cost per hour.
