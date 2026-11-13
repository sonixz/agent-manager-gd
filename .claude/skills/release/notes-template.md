**Your agent lab.** Claude Code, Codex and your shells side by side: isolated, observed, in your control. Open source, local-first, bring your own keys.

It is an **alpha**, and it is a **lab**: run it on your own computer, and do not put it on the internet unless you know what you are doing ([AI notice](https://github.com/sonixz/agent-manager-gd/blob/main/AI-NOTICE.md)).

Website: https://sonixz.github.io/gd-project/agent-manager/

## Download

| File | For | SHA-256 |
|---|---|---|
| `AgentManagerGD-@VERSION@-win64.zip` | Windows, with WSL | `@SHA256@` |

Linux: no release build yet. Run it from the source with Godot 4.7 ([Docs › Install](https://sonixz.github.io/gd-project/agent-manager/docs.html#install)).

## Install or update on Windows

1. Unzip `AgentManagerGD-@VERSION@-win64.zip` anywhere.
2. Right-click `install.ps1` → *Run with PowerShell*. It installs for your user only, **without administrator rights**, and downloads nothing. To update, close the app first: your sessions keep running.
3. Start *Agent Manager GD* from the Start menu. The **Setup check** says what is missing and the command to run yourself.

The executable is not code-signed: Windows may ask you to confirm before it runs.

## What changed

@CHANGES@

Everything in detail: [CHANGELOG](https://github.com/sonixz/agent-manager-gd/blob/main/CHANGELOG.md) and the [Docs](https://sonixz.github.io/gd-project/agent-manager/docs.html).

## Known limits

- Alpha: it moves fast, expect rough edges, most of all in the orchestrator (beta).
- Windows needs WSL; the engine and your agents run inside it.

## Built from

Commit [`@COMMIT@`](https://github.com/sonixz/agent-manager-gd/commit/@COMMIT_FULL@), for which the tests on GitHub are green. Godot 4.7.2. Licence: MIT; third-party parts in `THIRD_PARTY_NOTICES.md`, inside the archive.
