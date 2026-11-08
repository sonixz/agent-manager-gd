#!/usr/bin/env bash
# Runs the terminal bench on a private virtual display (no window on the desktop).
#   tools/bench.sh <render|input|tui|perf> <out-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/vdisplay.sh
vdisplay_start || { echo "no Xvfb" >&2; exit 2; }
trap vdisplay_stop EXIT
godot --headless --path . --import >/dev/null 2>&1 || true
DISPLAY="$VDISPLAY" WAYLAND_DISPLAY="" BENCH_MODE="$1" BENCH_OUT="$2" godot --display-driver x11 --audio-driver Dummy \
  --rendering-driver opengl3 --resolution 1600x1000 --path . --script res://bench.gd 2>&1 | grep -vE "^Godot Engine|^OpenGL|^$" || true
