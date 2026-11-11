# Working on this repository (for people and coding agents)

Read AI-NOTICE.md first: this is a lab, run on one person's computer. Never expose an engine, an MCP server or their ports beyond the local machine unless the owner asks for it explicitly (owner, 2026-11-10).

How to build, test and contribute: CONTRIBUTING.md. What the app protects: SECURITY.md.

- Godot 4.7 + Python. Local-first: nothing leaves the computer unless the user asks.
- The terminal must be impeccable: a change that degrades it (accents, colours, keys, speed) is a regression.
- Never open a Godot window unless the owner asks; captures run on a private virtual display (Xvfb).
- No secrets in the repository or in logs. Credentials go through dotenvx. Never print a key.
- Never require administrator rights by default.
- Never silently download an interpreter or run an unverified remote script. Third-party binaries are downloaded
  only after the owner agrees, pinned to a version and checked against a published checksum.
- Agent CLIs are launched as the user's own installed tools (their login, their config). The app never reads,
  copies or relays subscription login tokens.
- Never change the repository's visibility; no automatic publishing.
- main is pushed only through the push-main workflow (`.claude/skills/push-main/SKILL.md`, `tools/push_main.sh`):
  the website, its index with every loop, the Docs and the devlog follow the changes first, and each push needs the
  owner's OK (owner, 2026-11-11).
- Two things are called sandbox; never mix them up. « Sandboxes » are ours: Fly.io machines reached through an SSH
  tunnel. Claude Code's own sandbox (bubblewrap, socat) stays Claude Code's native feature: name it as such, never
  as ours, and never install its tools yourself (owner, 2026-11-11).
- Tests stay green; do not claim a test or a check that was not run.
