# Decisions

- **2026-11-08 · Separate project, not a Second Brain module.** Code modules in the Brain are parked; the agent
  manager is its own app and talks to the Brain over MCP.
- **2026-11-08 · Real terminals, via tmux.** The owner wants the agents' own terminals (not JSON event cards).
  tmux (private server) keeps sessions alive; the app's terminal is a tmux client.
- **2026-11-08 · Terminal first, go/no-go.** Nothing else is built until a VT engine passes the grid in
  docs/research/TERMINAL.md. Order: godot-xterm, then libghostty-vt; pyte excluded.
- **2026-11-08 · Reference: wainmann/agent-manager (Apache-2.0).** Ideas reused; any code reused keeps its notice.
- **2026-11-08 · Local only.** Local git repo, no remote yet; visibility and licence are the owner's choice.
