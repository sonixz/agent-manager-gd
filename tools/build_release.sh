#!/usr/bin/env bash
# Release build (Loop 15): exports the app for Windows (and Linux when its export template is installed), ships the
# engine next to the executable, adds the per-user installer, and zips it. Run tools/build_native.sh template_release first.
#   tools/build_release.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:-$(date +%Y.%m.%d)}"
TPL="$HOME/.local/share/godot/export_templates/4.7.2.stable"
rm -rf dist; mkdir -p dist
godot --headless --path app --import >/dev/null 2>&1 || true
ship() {  # $1 folder: the engine, the sandbox image recipe, docs
  mkdir -p "$1/engine" "$1/sandbox"
  cp engine/*.py engine/doctor.sh "$1/engine/"
  cp sandbox/* "$1/sandbox/"
  cp README.md THIRD_PARTY_NOTICES.md LICENSE CHANGELOG.md SECURITY.md "$1/"
  echo "$VER" > "$1/VERSION"
}
W=dist/AgentManagerGD-win64
mkdir -p "$W"
godot --headless --path app --export-release Windows "../$W/AgentManagerGD.exe" 2>&1 | grep -iE "error|fail" || true
test -f "$W/AgentManagerGD.exe"
ship "$W"
cp installer/install.ps1 installer/uninstall.ps1 "$W/"
(cd dist && python3 -c "import shutil,sys; shutil.make_archive(sys.argv[1], 'zip', '.', sys.argv[2])" "AgentManagerGD-$VER-win64" AgentManagerGD-win64)
if [ -f "$TPL/linux_release.x86_64" ]; then
  L=dist/AgentManagerGD-linux; mkdir -p "$L"
  godot --headless --path app --export-release Linux "../$L/AgentManagerGD.x86_64" 2>&1 | grep -iE "error|fail" || true
  ship "$L"
  tar -C dist -czf "dist/AgentManagerGD-$VER-linux-x86_64.tar.gz" AgentManagerGD-linux
else
  echo "Linux: no export template for 4.7.2 installed (skipped)"
fi
ls -la dist
