# Installing Agent Manager GD

## What it needs

Agent Manager GD is a Godot app (the window) and a small Python engine that runs where tmux lives.

| | Windows | Linux |
|---|---|---|
| The window | the release build (`AgentManagerGD.exe`) | Godot 4.7 on `app/` (a Linux release build needs Godot's Linux export template, not installed yet) |
| The engine | inside WSL: `python3` 3.10+, `tmux`, `git`, `ssh` | the same, directly |
| Agents (optional) | Claude Code and Codex installed and logged in **inside WSL**, as you use them today | the same |
| Cloud sandboxes (optional) | flyctl, installed by you (the app looks in `~/.local/opt/flyctl` and on your PATH; it does not download it) and a Fly.io token pasted in Keys | the same |

Nothing is installed or downloaded silently. The **Setup check** (◐ → Setup check…, and on its own at the first
launch if the engine cannot start) reads what the app stands on, from the ground up: on Windows, Windows itself
(its version, virtualization), WSL and its Linux distribution; then the programs, the engine, the agents. It
tells you the command to run at the first thing that is missing. When python3, tmux, git or ssh is missing, it
offers to install them itself: it shows the command and runs it on your click, in a terminal you see (as the
distribution's root inside WSL; through `sudo` on Linux). Under it, the **Engine room** is a dashboard of
that ground: memory in use by session, now and over the last seven days, what each session weighs, the true room on
the disk, the limits of your `.wslconfig`.

## Windows, step by step

1. Build or receive `AgentManagerGD-<version>-win64.zip` (`tools/build_release.sh <version>` after
   `tools/build_native.sh template_release`).
2. Unzip it anywhere and right-click `install.ps1` → *Run with PowerShell*
   (or `powershell -ExecutionPolicy Bypass -File install.ps1`).
   - Installs to `%LOCALAPPDATA%\Programs\AgentManagerGD` (your user only, no administrator rights).
   - Adds *Agent Manager GD* to the Start menu.
   - Options: `-Target <folder>` to install elsewhere, `-NoShortcut` to skip the shortcut.
3. Start it. If WSL is missing, the Setup check says so: WSL itself is Microsoft's (`wsl --install`, once, in an
   administrator PowerShell, then a restart); a Linux distribution comes next (`wsl --install -d Ubuntu-24.04`);
   everything else installs inside WSL with your own package manager
   (`sudo apt install python3 tmux git openssh-client`). The check stops at the first thing that is missing and
   says which.

The release folder holds the app, the terminal libraries (VtTerminal and libghostty-vt), and `engine/` — the app
starts that engine through `wsl.exe` from its own folder.

## Updating, removing

- Update: close the app (sessions keep running in tmux), run the new `install.ps1`.
- Remove: `uninstall.ps1` in the install folder. Your data stays: sessions, keys and settings in WSL
  (`~/.local/share/agent-manager-gd`) and the window's settings (`%APPDATA%\Godot\app_userdata\Agent Manager GD`).
  Delete those yourself to forget everything (the encrypted keys can only be read by your Windows user anyway).
