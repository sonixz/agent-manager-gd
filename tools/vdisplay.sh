# Copied from the-ticket-system/tools/vdisplay.sh (same owner).
# Sourced by the capture tools: a private virtual X display (Xvfb) so a
# rendered run never opens a window on the desktop. Sets $VDISPLAY.
#   source tools/vdisplay.sh; vdisplay_start && trap vdisplay_stop EXIT
VDISPLAY=""
_VPID=""
vdisplay_start() {
  local bin="${XVFB:-}"
  [[ -z "$bin" ]] && bin="$(command -v Xvfb || true)"
  [[ -z "$bin" && -x "$HOME/.local/bin/xvfb-local" ]] && bin="$HOME/.local/bin/xvfb-local"
  [[ -z "$bin" ]] && return 1
  local n
  for n in $(seq 90 110); do
    if [[ ! -e "/tmp/.X$n-lock" ]]; then
      "$bin" ":$n" -screen 0 2560x1440x24 -nolisten tcp >/dev/null 2>&1 &
      _VPID=$!
      sleep 1.5
      if kill -0 "$_VPID" 2>/dev/null; then VDISPLAY=":$n"; return 0; fi
    fi
  done
  return 1
}
vdisplay_stop() {
  [[ -n "$_VPID" ]] && kill "$_VPID" 2>/dev/null || true
  _VPID=""
}
