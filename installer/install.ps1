# Agent Manager GD: install for the current Windows user only. No administrator rights, nothing downloaded.
# Copies this folder to %LOCALAPPDATA%\Programs\AgentManagerGD and adds a Start menu shortcut.
#   Right-click > Run with PowerShell   (or: powershell -ExecutionPolicy Bypass -File install.ps1)
param([string]$Target = (Join-Path $env:LOCALAPPDATA "Programs\AgentManagerGD"), [switch]$NoShortcut)
$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$dst = $Target
Get-Process AgentManagerGD -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "Agent Manager GD is open: close it first (your sessions keep running in tmux)."; exit 1 }
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item -Path (Join-Path $src "*") -Destination $dst -Recurse -Force -Exclude "install.ps1"
if (-not $NoShortcut) {
$menu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Agent Manager GD.lnk"
$sh = (New-Object -ComObject WScript.Shell).CreateShortcut($menu)
$sh.TargetPath = Join-Path $dst "AgentManagerGD.exe"
$sh.WorkingDirectory = $dst
$sh.Description = "Agent Manager GD"
$sh.Save()
}
Write-Host "Installed in $dst"
Write-Host "Start menu: Agent Manager GD. It needs WSL with python3, tmux, git and ssh: the app's Setup check tells you what is missing."
