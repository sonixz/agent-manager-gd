#!/usr/bin/env bash
# Installs the programs Agent Manager GD needs, with the distribution's own package manager (Loop 36). The app runs
# it only on a click, in a terminal the user sees, with the command shown first: as the distribution's root inside
# WSL (wsl.exe -u root: no Windows administrator), or through sudo on Linux. It installs nothing but the names below.
set -eu
allowed=" python3 tmux git openssh-client "
[ "$#" -gt 0 ] || { echo "Nothing to install."; exit 0; }
for p in "$@"; do
  case "$allowed" in *" $p "*) ;; *) echo "Not installed: « $p » is not one of:$allowed" >&2; exit 2;; esac
done
command -v apt-get >/dev/null || { echo "This distribution has no apt-get: install $* with its own package manager." >&2; exit 3; }
export DEBIAN_FRONTEND=noninteractive
echo "→ apt-get update"
apt-get update
echo "→ apt-get install -y $*"
apt-get install -y "$@"
echo
echo "Installed: $*"
