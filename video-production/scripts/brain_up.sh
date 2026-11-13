#!/usr/bin/env bash
# The showcase video V5, Second Brain side: a COPY of Second Brain GD (never the owner's checkout, never the owner's
# Brain) opened on a private virtual display with its English showcase Brain in a temporary home, filmed with Godot's
# movie mode, the real archivist (OpenAI key from the environment: run it under dotenvx, the key is never printed).
#   brain_up.sh <work dir>        writes <work>/brain-home, <work>/brain-frames/frame*.png, <work>/brain-marks.txt,
#                                 <work>/brain-ready once the Brain is open; runs until brain_film.gd ends
# SB_SRC (default /mnt/c/git-2026/second-brain-gd) is copied to <work>/sb (rsync, without .git and .env).
set -euo pipefail
WORK="$(realpath "$1")"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SB_SRC:-/mnt/c/git-2026/second-brain-gd}"
mkdir -p "$WORK"
rsync -a --delete --exclude .git --exclude '.env*' --exclude docs/screenshots --exclude dist "$SRC/" "$WORK/sb/"
cp "$HERE/brain_film.gd" "$WORK/sb/tools/brain_film.gd"
printf '[display]\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\nwindow/size/window_width_override=1920\nwindow/size/window_height_override=1080\n' > "$WORK/sb/override.cfg"
if [[ -z "${KEEP_HOME:-}" ]]; then rm -rf "$WORK/brain-home"; fi
rm -rf "$WORK/brain-frames" "$WORK/brain-marks.txt" "$WORK/brain-ready" "$WORK/brain-hold"
mkdir -p "$WORK/brain-home" "$WORK/brain-frames"
cd "$WORK/sb"
source tools/vdisplay.sh
vdisplay_start || { echo "no Xvfb" >&2; exit 2; }
trap 'vdisplay_stop' EXIT
godot --headless --path . --import >/dev/null 2>&1 || true
test -n "${OPENAI_API_KEY:-}" || { echo "no OpenAI key in the environment (run under dotenvx)" >&2; exit 2; }
DISPLAY="$VDISPLAY" WAYLAND_DISPLAY="" SBGD_UI_LANG=en SBGD_HOME="$WORK/brain-home" SBGD_PORT="${SBGD_PORT:-18768}" \
  SBGD_SHOT_SIZE=1920x1080 SBGD_CAPTURE_DIR="$WORK/brain-shots" SBGD_READY="$WORK/brain-ready" SBGD_MARKS="$WORK/brain-marks.txt" SBGD_HOLD="$WORK/brain-hold" \
  SBGD_KEYRING_SERVICE=SecondBrainGD-film env -u OPENAI_ADMIN_KEY \
  godot --display-driver x11 --audio-driver Dummy --rendering-driver opengl3 --resolution 1920x1080 --path . \
  ${BRAIN_MOVIE:+--write-movie "$WORK/brain-frames/frame.png" --fixed-fps 30} \
  --script res://tools/brain_film.gd > "$WORK/brain.log" 2>&1 || true
grep -E "mark |brain_film|ERROR|SCRIPT" "$WORK/brain.log" | head -40 || true
