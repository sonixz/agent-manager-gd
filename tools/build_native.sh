#!/usr/bin/env bash
# Builds VtTerminal for Linux and Windows and copies it with libghostty-vt into app/addons/vtterm/bin (not committed).
#   tools/build_native.sh [template_debug|template_release]
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-template_debug}"
SCONS="${SCONS:-$HOME/.local/opt/scons-venv/bin/scons}"
OUT="$(pwd)/app/addons/vtterm/bin"
mkdir -p "$OUT"
(cd native/vtterm && "$SCONS" -j"$(nproc)" target="$TARGET" OUT="$OUT" >/dev/null)
(cd native/vtterm && "$SCONS" -j"$(nproc)" platform=windows use_mingw=yes mingw_prefix="$HOME/.local/opt/zigmingw" target="$TARGET" OUT="$OUT" >/dev/null)
cp "$HOME/src/ghostty/zig-out/lib/libghostty-vt.so.1.1.0" "$OUT/libghostty-vt.so.1"
cp "$HOME/src/ghostty/zig-out-win/bin/ghostty-vt.dll" "$OUT/"
rm -f "$OUT"/*.lib
ls -1 "$OUT"
