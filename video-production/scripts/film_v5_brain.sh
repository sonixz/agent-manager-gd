#!/usr/bin/env bash
# The showcase video V5, the Second Brain scene: both apps filmed at once, each on its own private virtual display.
#   1. a demo Second Brain (a copy, a temporary home, the real archivist) opens and waits (scripts/brain_up.sh);
#   2. Agent Manager's step « film-brain » starts a session with the Second Brain: the user's own Claude Code
#      (their login, never read here) works and proposes to the demo Brain; the Brain approves with its own button,
#      its archivist files the item, the Brain shows it and its timeline;
#   3. frames: captures/film-brain (Agent Manager), captures/film-brain-sb (Second Brain), marks in
#      build/showcase/report-film-brain.txt and captures/film-brain-sb/marks.txt.
# Run from the repository: video-production/scripts/film_v5_brain.sh   (the OpenAI and nothing else goes to the Brain,
# through dotenvx from the Second Brain's .env; no key is printed)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${V5_WORK:-/tmp/v5work}"
SB="${SB_SRC:-/mnt/c/git-2026/second-brain-gd}"
rm -rf "$REPO/video-production/captures/film-brain" "$REPO/video-production/captures/film-brain-sb"
( cd "$SB" && BRAIN_MOVIE=1 dotenvx run -q -f .env -- "$REPO/video-production/scripts/brain_up.sh" "$WORK" ) > "$WORK.brain-run.log" 2>&1 &
BPID=$!
sleep 5
timeout 1200 bash -c "until [ -f '$WORK/brain-ready' ]; do sleep 3; done"
echo "brain open: $(cat "$WORK/brain-marks.txt")"
cd "$REPO"
SHOW_MOVIE="$REPO/video-production/captures" SHOW_SIZE=1920x1080 SHOW_BRAIN_HOME="$WORK/brain-home" SHOW_BRAIN_REPO="$WORK/sb" \
  SHOWCASE_REAL_AGENT="$(command -v claude)" SHOWCASE_REAL_HOME="$HOME" SHOW_OUT="$WORK/shots" \
  tools/showcase.sh film-brain > "$WORK.am-run.log" 2>&1 || true
touch "$WORK/brain-hold"
wait "$BPID" || true
mkdir -p "$REPO/video-production/captures/film-brain-sb"
cp "$WORK"/brain-frames/frame*.png "$REPO/video-production/captures/film-brain-sb/"
cp "$WORK/brain-marks.txt" "$REPO/video-production/captures/film-brain-sb/marks.txt"
grep '^mark' build/showcase/report-film-brain.txt | tr '\n' ' '; echo
tr '\n' ' ' < "$WORK/brain-marks.txt"; echo
grep -E 'brain_film' "$WORK/brain.log" || true
