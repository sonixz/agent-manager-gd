# Market scan (2026-11-07)

Done by web search; vendor blog comparisons were treated as leads, not facts. Star counts as fetched that day.

## Main tools

| Tool | Type | Windows | Licence | Vendors | Notes |
|---|---|---|---|---|---|
| **agent-manager** (wainmann) | tmux TUI (Go) | native via psmux, and WSL2 | Apache-2.0 | 13 CLIs | 646 stars, very active; diff review with comments, revive, fork, worktrees, agents pilot agents over MCP; **no cost tracking** (its README). https://github.com/wainmann/agent-manager |
| agent-deck | tmux TUI + local web UI (Go) | WSL | MIT | ~13 | 1.2k stars; cost dashboard and budgets, MCP manager, Docker sandboxes, conductors. https://github.com/asheshgoplani/agent-deck |
| Claude Squad | tmux TUI | no native Windows (open issue) | AGPL-3.0 | multi | 8.7k stars. https://github.com/smtg-ai/claude-squad |
| ccmanager | TUI without tmux | probably | MIT | 10 | 1.3k stars. https://github.com/kbwo/ccmanager |
| Conductor | desktop app | Mac only | closed | Claude, Codex, Cursor | funded. https://www.conductor.build/ |
| Paradev (ex-Superset) | Electron desktop | not yet (community port) | MIT | 20+ | 16.1k stars, funded. https://github.com/superset-sh/superset |
| Vibe Kanban | web kanban | ? | Apache-2.0 | 10+ | company shut down 2026-04-10; community-maintained. https://vibekanban.com/shutdown |
| Claude Code desktop / Agent View | vendor | yes | closed | Claude only | multi-session, "Needs input" grouping |
| Codex app | vendor | yes (2026-03) | closed app | Codex only | parallel agents, worktrees |
| GitHub Agent HQ | cloud | yes | closed | multi | PR-centric |

## Gaps

- Native Windows desktop, multi-vendor: almost nothing.
- One approval inbox across vendors: none found.
- Cost per agent: only agent-deck among open-source tools.
- Shared memory across agents and vendors: none found (the Second Brain angle; demand not proven).
- Durability: users burned by projects that folded (Vibe Kanban, Crystal).

## Terms of use (to respect)

- Anthropic does not allow third-party products to offer claude.ai login or use subscription tokens
  (https://code.claude.com/docs/en/agent-sdk/overview, https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access).
  Launching the user's own installed CLI in a terminal (what agent-manager, Claude Squad and terminals do) is the
  model here; the app never touches login tokens.
- Codex: an API key is the recommended path for automation; ChatGPT-managed auth is for trusted runners.

## Verdict

Room exists in a narrow slot: rich native-Windows interface, an impeccable terminal, and the Brain as shared memory.
A plain "launch agents with cards" clone is not worth building.
