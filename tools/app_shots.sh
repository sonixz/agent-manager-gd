#!/usr/bin/env bash
# Runs the real app twice on a private virtual display: create sessions, close; reopen and find them again.
# Own engine port, data folder and tmux socket. Needs tools/build_native.sh first.
#   tools/app_shots.sh <out-dir> [trusted-folder-for-claude]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; TRUSTED="${2:-$HOME}"
source tools/vdisplay.sh
vdisplay_start || { echo "no Xvfb" >&2; exit 2; }
DATA="$(mktemp -d -t agmgd-shots-XXXX)"
cleanup() { tmux -L agmgd-shots kill-server 2>/dev/null || true; vdisplay_stop; rm -rf "$DATA"; }
trap cleanup EXIT
godot --headless --path app --import >/dev/null 2>&1 || true
for step in ${STEPS:-create reopen}; do
  DISPLAY="$VDISPLAY" WAYLAND_DISPLAY="" AGMGD_DEMO_FLY="${DEMO_FLY:+$DATA/demo-fly.json}" AGMGD_HOME="$DATA" AGMGD_PORT=18790 AGMGD_TMUX_SOCKET=agmgd-shots \
    DRIVE_STEP=$step DRIVE_OUT="$OUT" DRIVE_TRUSTED="$TRUSTED" \
    godot --display-driver x11 --audio-driver Dummy --rendering-driver opengl3 --resolution 1440x900 --path app \
    --script res://tools_drive.gd 2>&1 | grep -vE "^Godot Engine|^OpenGL|V-Sync|set_use_vsync|^$" || true
  sleep 1
done
