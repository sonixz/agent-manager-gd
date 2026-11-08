# Agent Manager GD: removes the program and its Start menu shortcut (current user).
# Your data stays (sessions, keys, settings): in WSL ~/.local/share/agent-manager-gd and %APPDATA%\Godot\app_userdata\Agent Manager GD.
$ErrorActionPreference = "Stop"
$dst = Join-Path $env:LOCALAPPDATA "Programs\AgentManagerGD"
Remove-Item (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Agent Manager GD.lnk") -ErrorAction SilentlyContinue
if (Test-Path $dst) { Set-Location $env:TEMP; Remove-Item $dst -Recurse -Force }
Write-Host "Agent Manager GD removed. Your data was kept."
