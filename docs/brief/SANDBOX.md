# Repositories and cloud sandboxes — design notes (draft v2, 2026-11-08)

Not built yet. Owner's decisions: the user creates the repositories himself; Agent Manager connects them (a deploy
key per repository) and launches agents on them, locally or in a sandbox with access to the Brain. A sandbox is a
**cheap, non-persistent instance**, not a persistent host. Agent Manager manages the Fly.io costs.

## 1. Connected repositories (local and cloud)

**« Add a repository »** (a Repositories view):
1. The user gives the repository's SSH address (`git@github.com:org/repo.git`) and, optionally, a local folder where
   it is (or should be) cloned.
2. Agent Manager makes a **deploy key** for that repository only (ed25519): the private key stays in Agent Manager's
   data folder (file 0600, never in a log, never in the repository); the public key is shown with a « Copy » button
   and a link to the repository's GitHub page *Settings → Deploy keys* (tick « Allow write access » so agents can
   push their branch).
3. « Check »: Agent Manager tests the key (`git ls-remote` with that key only) and records it as connected.

The Repositories view documents each one: address, local folder, key fingerprint, added on, last used, the sessions
that worked on it; **Rotate key** (a new key, the old one to remove on GitHub, shown step by step) and **Disconnect**
(the key file deleted; reminder to delete it on GitHub). A deploy key opens one repository only: a leaked key never
opens the others.

**Start an agent on a repository**: pick the repository instead of a folder, then *Local* (its local folder; a git
worktree per session as today) or *Sandbox* (below). Git commands of that session use its deploy key
(`GIT_SSH_COMMAND` with that key only), not the user's personal keys.

## 2. Sandboxes: cheap, throw-away instances

One sandbox = one Fly Machine for one session. **Agent Manager never destroys a sandbox on its own**: destroying is
always the owner's act, in the sandbox manager (section 5).

1. **Start**: a small machine from our image (tmux, git, Claude Code, Codex, Python, our mini engine); the
   repository's deploy key and the agent's credentials are given as machine secrets; the repository is cloned and a
   branch `am/<session>` created; the agent starts in tmux. The terminal opens in Agent Manager like any session
   (badge ☁, through `fly ssh console`).
2. **Work**: states, approvals, the Brain (through the tunnel, below), Board and Grid views as for local sessions.
3. **Finish**: Wrap up (the agent's summary), the agent commits and pushes its branch with the deploy key; Agent
   Manager shows the branch's diff (Loop 8) and can open the pull request link; the summary comes back to History and
   is proposed to the Brain; the sandbox is marked **finished, ready to destroy** in the sandbox manager. It is
   destroyed (machine, volume and secrets) only when the owner says so.

**Logging in once, with throw-away machines**: a login made inside a machine would vanish with it. So the
credentials are given once to Agent Manager (dotenvx or the system keyring) and injected into each sandbox as
secrets: **API keys** (`ANTHROPIC_API_KEY` for Claude Code, `CODEX_API_KEY`/`OPENAI_API_KEY` for Codex), billed per
use. Agent Manager never copies a subscription login (claude.ai, ChatGPT) into the cloud: Anthropic's terms forbid
third-party products from relaying it. (`claude setup-token` exists for automation; whether using it from a
third-party tool is allowed must be checked with Anthropic first: off by default.)

## 3. The Second Brain through a tunnel

The Brain listens only on 127.0.0.1 of the owner's computer. While Agent Manager is open it keeps an **SSH reverse
tunnel** to each running sandbox (Windows' own `ssh.exe` over `fly proxy`, so it reaches the Brain on Windows'
localhost): the sandbox's 127.0.0.1:8765 leads to the Brain's `/mcp`. Each sandbox session gets its own Brain key
(level « propose items »), revoked when the owner destroys the sandbox. App closed: no tunnel, the agent gets « Brain
unreachable » and keeps working; its summary is proposed to the Brain when it comes back.

## 4. Fly.io costs in Agent Manager

- A live counter per sandbox and a total per day and month: running seconds × the machine size's price from Fly's
  published price list (shown as an estimate, with the date of the price list).
- **Caps, never destructive**: a monthly budget (warning at 80 %, new sandboxes refused at 100 %); optionally, the
  owner can let Agent Manager **stop** (pause, not destroy) a sandbox idle for N minutes or over budget — a stopped
  machine keeps its files and costs only its storage, and starts again on demand.
- **Stop everything**: one button stops (pauses) every running sandbox; nothing is destroyed.
- A history of past sandboxes: repository, duration, estimated cost, outcome (branch pushed or not).

## 5. The sandbox manager

A view listing every sandbox, running, stopped or finished:
- repository, session, branch, size, age, state of the machine and of its tunnel, Brain reachable or not, cost so
  far, last activity, last summary, whether its branch is pushed;
- actions: open its terminal, **Start**, **Stop** (pause), **Destroy** (always confirmed; before destroying, Agent
  Manager checks for uncommitted changes and commits not pushed and shows them, so no work is lost by mistake),
  **Destroy the finished ones** (a list to tick, confirmed);
- **orphans**: machines in the Fly account tagged as Agent Manager's but unknown locally (made from another computer,
  or left after a crash) are listed, never touched without the owner.

## 6. Needed from the owner

A Fly.io account and API token (dotenvx), the agreement to install `flyctl` (a download, checked), a registry for the
image (Fly's or GHCR; visibility is the owner's choice), API keys for the agents used in sandboxes, a test budget.

## 7. Milestones

1. **Repositories and deploy keys** (local only): add, check, rotate, disconnect; agents launched on a repository.
2. **Sandbox go/no-go**: one machine from our image, a session's terminal attached, a branch pushed with the deploy
   key, the Brain through the tunnel, destroyed by the owner from the sandbox manager. Measured: start time, terminal latency, cost per run.
3. **The sandbox manager, Fly.io costs and caps**, then several sandboxes in parallel.
