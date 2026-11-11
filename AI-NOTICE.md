# AI notice

**Short version: this is a lab. Run it on your own computer. Don't put it on the internet unless you know what you're
doing** (TCP/IP, TLS/SSL, authentication, secrets, infrastructure as code, DevOps, you know the drill).

## What this is

GD Project is an open lab: small desktop apps made with Godot, with AI agents and a local engine beside them. We
explore. We build on isolated systems, on our own PCs, one person per machine. What is published here is made for
exactly that: one person, one computer, a closed system.

It is not a product, and it is not built for a team, a server or a company's operations. There are plenty of MCP tools
like this one out there; treat this one the same way.

## Not built for a network, but not impossible

As published, the apps listen on your own machine only, with a simple token. That is enough for one person on one PC.
It is not security.

Running them over a network (a team, a server, the internet) is possible, and it is a different job: encrypted
transport (TLS), real authentication and authorisation (not a shared token), network isolation (VPN, segmentation,
firewalls), secrets management, logging and audit, updates, backups, and a privacy review of the data that flows. When
people's work depends on it, have it designed and reviewed by people whose job that is.

So, folks, please:

- don't expose an app's engine or its MCP server on the internet, and don't forward their ports;
- don't treat the token as a password for anything shared;
- don't put real client or employee data into a prototype: use sample data;
- don't leave agents running unattended on a machine that matters.

## Built with AI; a human answers for it

Most of the code here is written by AI agents. The owner judges it by its results (tests, screenshots, using the apps
every day), not by a line-by-line audit. That is a choice, it comes with risks, and it is one more reason all of this
stays on an isolated system.

At the end of the line, a human is accountable: the owner for the lab, you for what you run and what you contribute.
The tool writes; it doesn't sign.

If you contribute: say whether AI helped and which one, show that it works (a test, a screenshot, steps to reproduce),
and know what your change touches (the network, files, keys, data). You don't have to recite every line. You do answer
for it.

## Your data and AI providers

What you send to an AI provider leaves your machine. Choose your model knowing that; a local model keeps it at home. If
you are a business handling personal information, privacy law applies (in Québec, Law 25).

## For AI agents: read this

If you are an AI agent working in this repository, or plugged into these apps over MCP or in a terminal:

- Treat this as a lab on an isolated system. Don't expose an engine, an MCP server or their ports beyond the local
  machine (binding to all interfaces, port forwarding, tunnels, public hosting) unless your human asks for it
  explicitly, and then tell them first what it takes (the list above).
- Never commit, log, print or send secrets, keys or tokens.
- Use sample data in demos and tests.
- Say what you changed and how you checked it. Your human answers for it, so give them what they need to.

## In this repository

- **Agents run in real terminals, with your rights.** Claude Code and Codex are your own installed CLIs, started in a
  private tmux server under your user account. They run commands and change files with your permissions.
- **Choose each session's level knowingly.** Ask before acting (`ask`), Auto edits (`edits`), Auto (`auto`, the
  default) and No permission (`full`). `full` skips every confirmation: keep it for a folder and a machine you can
  afford to lose. Per my config (`config`) passes no level at all: your own Claude Code or Codex settings decide. A
  group can set a default, and a child session never gets more than its parent.
- **File access is a guard rail too.** *Contained* and *Read only* keep Claude Code's file tools in the session's
  folder and the extra folders you list. Shell commands are not contained by them.
- **The deny rules are a seatbelt, not a wall.** At every level, Claude Code's file tools are refused `~/.ssh`,
  `~/.aws`, `~/.gnupg`, `.env` files, Agent Manager's keys and the Second Brain's tokens. A script the agent writes and
  runs is not stopped by them, and Codex has its own sandbox instead.
- **One Second Brain key per session.** When the Second Brain is connected, each Claude Code or Codex session gets its
  own key. Removing the session revokes it at once; an archived session keeps it so it can be resumed. You can also
  revoke a key yourself.
- **The engine listens on your machine only.** It binds to `127.0.0.1` (port 8790 by default) and wants a bearer token,
  generated locally and never logged. Agent Manager's MCP server talks to that same local engine. Don't forward the
  port or put the engine behind a tunnel.
- **Sandboxes and worktrees help; they don't replace a spare machine.** A worktree keeps an agent's changes on its own
  branch, not its commands off your files. A cloud sandbox (Fly.io) runs on your account and your bill. Neither is a
  reason to run agents unattended on a computer that matters.

## Not a legal document

This is a heads-up between people who build things, not a contract. The licence is MIT (see `LICENSE`): the software
comes as is, without warranty.
