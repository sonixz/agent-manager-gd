#!/usr/bin/env bash
# The website screenshots (public/assets/showcase/), from the real app on a private virtual display (no window).
# A fictional user « dev » (own HOME, projects in ~/code, git identity dev@example.com); agent terminals replay
# real recorded screens (tools/showcase/scenes, tools/showcase/record.sh). Own engine port, data and tmux socket;
# a stand-in Second Brain (tools/showcase/fake_brain.py): no key is ever made in the owner's Brain. Needs tools/build_native.sh first.
#   tools/showcase.sh [step ...]        (steps in app/tools_showcase.gd; default: hero)
#   SHOW_OUT=<dir> to write elsewhere than public/assets/showcase (reports: build/showcase); SHOW_SIZE=1920x1200 (default)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; OUT="${SHOW_OUT:-$REPO/public/assets/showcase}"; REPORTS="$REPO/build/showcase"; mkdir -p "$OUT" "$REPORTS"
source tools/vdisplay.sh
vdisplay_start || { echo "no Xvfb" >&2; exit 2; }
ROOT=""
cleanup() {
  tmux -L agmgd-showcase kill-server 2>/dev/null || true
  pkill -f "^python3 -m engine --port 18791" 2>/dev/null || true
  pkill -f "fake_brain.py .* 18792$" 2>/dev/null || true
  if [[ -n "$ROOT" ]]; then cp "$ROOT/godot.log" "$REPORTS/godot-last.log" 2>/dev/null || true; rm -rf "$ROOT"; fi
}
trap 'cleanup; vdisplay_stop' EXIT
godot --headless --path app --import >/dev/null 2>&1 || true
for step in "${@:-hero}"; do
  # each step starts from nothing: a fresh fictional workspace, data folder and tmux server
  cleanup
  ROOT="$(mktemp -d -t agmgd-showcase-XXXX)"
  DEV_HOME="$(tools/showcase/make_workspace.sh "$ROOT")"
  python3 tools/showcase/fake_brain.py "$ROOT/brain" "$ROOT/brain-repo" 18792 &
  env -i PATH="$REPO/tools/showcase/bin:/usr/local/bin:/usr/bin:/bin:$(dirname "$(command -v godot)")" \
    HOME="$DEV_HOME" USER=dev LANG=C.UTF-8 TERM=xterm-256color DISPLAY="$VDISPLAY" \
    SHOWCASE_SCENES="$REPO/tools/showcase/scenes" SHOWCASE_MAP="$ROOT/map" SHOWCASE_REMOTES="$ROOT/remote" \
    AGMGD_HOME="$ROOT/data" AGMGD_PORT=18791 AGMGD_TMUX_SOCKET=agmgd-showcase AGMGD_BRAIN_HOME="$ROOT/brain" AGMGD_BRAIN_REPO="$ROOT/brain-repo" AGMGD_KEYS_PLAIN=1 \
    AGMGD_DEMO_FLY="$ROOT/data/demo-fly.json" AGMGD_DEMO_FLY_DELAY="${AGMGD_DEMO_FLY_DELAY:-}" SHOW_STEP="$step" SHOW_OUT="$OUT" SHOW_HOWTO="${SHOW_HOWTO:-$REPO/public/assets/howto}" SHOW_REPORTS="$REPORTS" \
    godot --display-driver x11 --audio-driver Dummy --rendering-driver opengl3 --resolution "${SHOW_SIZE:-1920x1200}" --path app \
    --script res://tools_showcase.gd > "$ROOT/godot.log" 2>&1 || true   # a file, not a pipe: the engine outlives Godot
  grep -vE "^Godot Engine|^OpenGL|V-Sync|set_use_vsync|libspeechd|^$" "$ROOT/godot.log" || true
done
# nothing personal may reach the website
if grep -rlaE "$HOME|$(whoami)@" "$REPORTS"/report-*.txt 2>/dev/null; then echo "personal text in a report" >&2; exit 1; fi
