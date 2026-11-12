#!/usr/bin/env bash
# First-run check (Loop 15): what Agent Manager GD needs, found or not. Read-only: nothing is installed or downloaded.
# One line per item: name=path-or-empty|version
# With the engine's port as first argument, it also says whether the engine's process is there and whether something
# listens on that port (Loop 36): the app asks this when the engine does not answer, so it cannot ask the engine.
for c in python3 tmux git ssh claude codex; do
  p="$(command -v "$c" 2>/dev/null)"; v=""
  case "$c" in
    python3) [ -n "$p" ] && v="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')";;
    tmux) [ -n "$p" ] && v="$(tmux -V | cut -d' ' -f2)";;
    git) [ -n "$p" ] && v="$(git --version | cut -d' ' -f3)";;
  esac
  echo "$c=$p|$v"
done
f="$HOME/.local/opt/flyctl/flyctl"; [ -x "$f" ] || f="$(command -v flyctl 2>/dev/null)"
echo "flyctl=$f|$([ -n "$f" ] && "$f" version 2>/dev/null | head -1 | cut -d' ' -f2)"
echo "apt=$(command -v apt-get 2>/dev/null)|"
echo "distro=${WSL_DISTRO_NAME:-}|$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}")"
if [ -n "${1:-}" ]; then
  echo "engine-process=$(pgrep -f "python3 -m engine --port $1\$" | head -1)|"
  if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then echo "engine-port=open|"; else echo "engine-port=|"; fi
fi
