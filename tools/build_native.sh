#!/usr/bin/env bash
# Builds VtTerminal for Linux and Windows and copies it with libghostty-vt into app/addons/vtterm/bin (not committed).
#   tools/build_native.sh [template_debug|template_release]
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-template_debug}"
SCONS="${SCONS:-$HOME/.local/opt/scons-venv/bin/scons}"
OUT="$(pwd)/app/addons/vtterm/bin"
mkdir -p "$OUT"
MINGW="$HOME/.local/opt/zigmingw"
# A release library is published, and godot-cpp's headers write the path of each source file into it: built as is, it
# would say where the builder's home folder is. For template_release the same compilers are called through wrappers
# that map that folder out (-ffile-prefix-map); tools/release.sh checks the archive holds no such path.
if [[ "$TARGET" == template_release ]]; then
  CLEAN="${XDG_CACHE_HOME:-$HOME/.cache}/agmgd-build/mingw"
  mkdir -p "$CLEAN/bin"
  for tool in "$MINGW"/bin/*; do
    name="$(basename "$tool")"
    case "$name" in
      *gcc|*g++) printf '#!/usr/bin/env bash\nexec %q "$@" -ffile-prefix-map=%q=/src -ffile-prefix-map=%q=/build\n' "$tool" "$HOME/src" "$HOME" ;;
      *)         printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$tool" ;;
    esac > "$CLEAN/bin/$name"
    chmod +x "$CLEAN/bin/$name"
  done
  MINGW="$CLEAN"
fi
(cd native/vtterm && "$SCONS" -j"$(nproc)" target="$TARGET" OUT="$OUT" >/dev/null)
(cd native/vtterm && "$SCONS" -j"$(nproc)" platform=windows use_mingw=yes mingw_prefix="$MINGW" target="$TARGET" OUT="$OUT" >/dev/null)
# copied only when it changed: a running app on Windows holds ghostty-vt.dll locked, and the same file needs no copy
same_or_cp() { cmp -s "$1" "$2" || cp "$1" "$2"; }
same_or_cp "$HOME/src/ghostty/zig-out/lib/libghostty-vt.so.1.1.0" "$OUT/libghostty-vt.so.1"
same_or_cp "$HOME/src/ghostty/zig-out-win/bin/ghostty-vt.dll" "$OUT/ghostty-vt.dll"
rm -f "$OUT"/*.lib
ls -1 "$OUT"
