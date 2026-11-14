#!/usr/bin/env bash
# Records real agent screens for the website (run by hand, with the owner's agreement: it uses his own Claude Code /
# Codex login on the fictional projects). Its own tmux socket; the projects live in ~/.cache/agmgd-showcase/code
# (a short path, scrubbed to ~/code). Screens are saved as tools/showcase/scenes/<scene>@<cols>x<rows>.ans.
#   record.sh setup                               fresh fictional projects
#   record.sh start <name> <project> <cmd...>     an agent in a tmux session (110x36)
#   record.sh type <name> <text>                  type a prompt and press Enter
#   record.sh keys <name> <tmux keys...>          raw keys (Down, Enter, BTab…)
#   record.sh snap <name> <scene> <cols> <rows>   resize, let it redraw, save the scrubbed screen
#   record.sh show <name>                         print the screen (plain)
#   record.sh stop                                end every recording session
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$HOME/.cache/agmgd-showcase"; T=(tmux -L agmgd-rec)
scrub() {  # personal paths become /home/dev; inside a box, a shorter path is padded so the box keeps its columns
  python3 -c '
import os, re, sys
home = os.path.expanduser("~")
pairs = [(home + "/.cache/AGENTS.md ", ""), (home + "/.cache/agmgd-showcase/AGENTS.md ", ""),
         (home + "/.cache/agmgd-showcase/code", "/home/dev/code"), ("~/.cache/agmgd-showcase/code", "~/code"), (home, "/home/dev")]
for line in sys.stdin.read().split("\n"):
    for a, b in pairs:
        pad = " " * (len(a) - len(b)) if "\u2502" in line else ""  # only inside a box (│ … │)
        line = re.sub(re.escape(a) + r"(\S*)", lambda m: b + m.group(1) + pad, line)
    print(line)
' | sed -e "s#$(whoami)@$(hostname)#dev@workstation#g" \
        -e 's/\x1b\[48;5;22m/\x1b[48;2;27;58;38m/g' -e 's/\x1b\[48;5;52m/\x1b[48;2;66;31;38m/g'
  # capture-pane gives Claude Code's dark diff backgrounds as 256-colour green and red (22, 52): back to dark tones
}
case "$1" in
  setup) rm -rf "$R"; "$HERE/make_workspace.sh" "$R" >/dev/null; mv "$R/home/dev/code" "$R/code"; ls "$R/code" ;;
  start) n="$2"; p="$3"; shift 3
         "${T[@]}" new-session -d -s "$n" -x 110 -y 36 -c "$R/code/$p" "env -u AGMGD_SESSION -u AGMGD_HOME -u AGMGD_PORT $*" ;;
  type)  "${T[@]}" send-keys -t "$2" -l "$3"; sleep 0.4; "${T[@]}" send-keys -t "$2" Enter ;;
  keys)  n="$2"; shift 2; "${T[@]}" send-keys -t "$n" "$@" ;;
  snap)  "${T[@]}" resize-window -t "$2" -x "$4" -y "$5"; sleep 2.5
         "${T[@]}" capture-pane -e -p -t "$2" | scrub > "$HERE/scenes/$3@$4x$5.ans"
         if grep -qE "$HOME|$(whoami)@|agmgd-showcase" "$HERE/scenes/$3@$4x$5.ans"; then echo "personal text left in $3" >&2; exit 1; fi
         echo "saved $3@$4x$5" ;;
  show)  "${T[@]}" capture-pane -p -t "$2" | scrub ;;
  stop)  "${T[@]}" kill-server 2>/dev/null || true ;;
esac
