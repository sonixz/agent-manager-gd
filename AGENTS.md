# Working on this repository (for people and coding agents)

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
- Tests stay green; do not claim a test or a check that was not run.
