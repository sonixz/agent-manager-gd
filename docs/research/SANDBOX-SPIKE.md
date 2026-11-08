# Loop 12 — Fly.io sandbox go/no-go (2026-11-08)

With the owner's agreement (his org-scoped token pasted in Keys, a « agent-manager » organisation, a few dollars).
flyctl v0.5.5 installed from the official GitHub release, both checksums checked, in the user's folder (no admin, no
install script). The token is read from Keys (DPAPI) and given to flyctl through its environment only.

## What was measured

| Step | Result |
|---|---|
| Create an app in the organisation | 1.2 s |
| Region | `yul` (Montréal) is closed to new machines: `yyz` (Toronto) |
| Machine from a public Ubuntu image, until started | 13.5 s — but installing tmux, git, Node, Claude Code and Codex at boot took ~7 min: too slow for throw-away sandboxes |
| **Our image** (`sandbox/Dockerfile`: tmux, git, sshd, Node, Claude Code 2.1.319, Codex 0.167.0) built by Fly's remote builder into the org's private registry (`registry.fly.io`) | 134 s once, 545 MB, builders and registry storage currently free |
| Machine from our image, until started | **17.3 s** |
| Then proxy + SSH ready, agents present | 11.2 s (≈ 30 s from « run » to a ready sandbox) |
| `git clone` of a public repository inside | 1.6 s |
| Terminal: attach to tmux in the sandbox | **0.6 s** |
| Key → echo, flyctl proxy + SSH + tmux, from Québec to Toronto | **45 ms median** (35 best, 61 worst, n=12) |
| **Reverse tunnel** (`ssh -R 8765:…` through the proxy): the sandbox's 127.0.0.1:8765 reaches this computer | works — the Brain's path |
| Inside Agent Manager | the sandbox's tmux opens in a real VtTerminal (capture `docs/screens/loop12`) |

## Lessons (built into Loop 13)

- Fly's own SSH (« hallpass ») listens on port 22 and accepts only Fly certificates; `flyctl ssh console` gave no
  usable pseudo-terminal to a program (« not a terminal » with `-C`). So the sandbox runs **our sshd on port 2222**
  (keys only, a key per sandbox, the public key given as the machine's environment) and Agent Manager reaches it
  with `flyctl proxy <port>:2222 <machine>.vm.<app>.internal` and plain OpenSSH (`ssh -t … tmux new -A -s am`,
  `ssh -N -R …` for the Brain).
- A prebuilt image is required (30 s instead of 7 min). Fly's registry is private to the organisation: no registry
  decision needed for the owner's use.
- The Brain tunnel will end at the engine (in WSL), which forwards the MCP calls to the Brain through the Brain's own
  Windows Python, as the local sessions do: no Windows SSH client, no key on the Windows side.

## Cost of this test

Prices from docs.fly.io/about/pricing (no date on the page): shared-cpu-1x 1 GB started $6.70/month (billed by the
second while running), stopped machines $0.15/GB/month of rootfs, builders and registry storage free. Running time
≈ 20 min + 4 min ⇒ **≈ $0.004**. The two machines are **stopped, not destroyed** (Agent Manager never destroys on its
own): ≈ $0.08/month each while kept. The app `agmgd-spike-96416e` stays for the owner to destroy from the sandbox
manager (Loop 13).

## Verdict

**GO.** Fast enough (≈ 30 s to a ready sandbox), a good terminal (45 ms), the Brain reachable through a tunnel,
negligible cost. Still to prove in Loop 13: a branch pushed with a repository's deploy key (needs a connected
repository), agents logged in with API keys (an Anthropic key in Keys), the sandbox manager.
