#!/usr/bin/env bash
# A release, the same way each time (the steps and the judgement in between: .claude/skills/release/SKILL.md).
# A release is cut from a commit GitHub's main already holds, with its tests green there. This script builds the
# Windows archive from that commit, checks it, and publishes it only when asked: each release needs the owner's OK.
#   tools/release.sh <version>             the report: builds dist/AgentManagerGD-<version>-win64.zip and checks it.
#                                          Publishes nothing.
#   tools/release.sh <version> --check     the same checks on the archive already built (no build)
#   tools/release.sh <version> --publish   the same checks, then the GitHub release v<version> with the archive and
#                                          build/release/NOTES-<version>.md (a pre-release when the version has a suffix)
#   tools/release.sh <version> --after     after publishing: the release as GitHub shows it, the archive downloaded
#                                          again and compared
# <version>: 0.<loop>.0-alpha while in alpha (0.39.0-alpha held the loops up to 39); a fix between two loops raises
# the last number. Needs: godot 4.7.2 with its Windows export template, the toolchain of tools/build_native.sh, and for
# --publish and --after gh signed in with the right to write this repository's contents.
set -uo pipefail
cd "$(dirname "$0")/.."
VER="${1:-}"; MODE="${2:-}"
if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$ ]]; then
  echo "usage: tools/release.sh <version> [--check|--publish|--after]   (a version like 0.40.0-alpha)" >&2; exit 2
fi
case "$MODE" in ""|--check|--publish|--after) ;; *) echo "unknown option: $MODE" >&2; exit 2 ;; esac
ZIP="dist/AgentManagerGD-$VER-win64.zip"
OUT="build/release"; NOTES="$OUT/NOTES-$VER.md"; STAMP="$OUT/$VER.stamp"
SLUG="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
mkdir -p "$OUT"

fails=0; warns=0
step() { printf '\n== %s\n' "$1"; }
ok()   { printf '   ok    %s\n' "$1"; }
warn() { printf '   WARN  %s\n' "$1"; warns=$((warns + 1)); }
bad()  { printf '   FAIL  %s\n' "$1"; fails=$((fails + 1)); }
sha()  { sha256sum "$1" | cut -d' ' -f1; }

if [[ "$MODE" == --after ]]; then
  step "After publishing v$VER"
  shown="$(gh release view "v$VER" -R "$SLUG" --json tagName,isPrerelease,isDraft,targetCommitish,url,assets \
    --jq '"\(.url) · target \(.targetCommitish[0:7]) · prerelease \(.isPrerelease) · draft \(.isDraft) · \([.assets[].name] | join(", "))"' 2>&1)" \
    && ok "$shown" || bad "GitHub shows no release v$VER: $shown"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if curl -sS -L -m 600 -o "$tmp/a.zip" "https://github.com/$SLUG/releases/download/v$VER/$(basename "$ZIP")" && [[ -f "$ZIP" ]]; then
    if [[ "$(sha "$tmp/a.zip")" == "$(sha "$ZIP")" ]]; then ok "the archive downloaded from GitHub is the one built here ($(sha "$ZIP"))"
    else bad "the archive downloaded from GitHub differs from $ZIP"; fi
  else warn "could not compare the published archive with $ZIP"; fi
  echo "   Not checked here: the app itself. Try the archive on a Windows machine (the list in the release skill)."
  exit $(( fails > 0 ))
fi

step "1. The commit to release"
head="$(git rev-parse HEAD)"
remote="$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)"
if [[ -n "$(git status --porcelain)" ]]; then bad "uncommitted changes: a release is built from a commit"; else ok "nothing uncommitted"; fi
if [[ "$remote" == "$head" ]]; then ok "this commit, ${head:0:7}, is GitHub's main"
else bad "GitHub's main is ${remote:0:7}, here it is ${head:0:7}: a release is cut from what is pushed (push-main first)"; fi
run="$(curl -sS -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$SLUG/actions/runs?head_sha=$head&per_page=10" 2>/dev/null |
  python3 -c 'import json, sys
try:
    runs = [r for r in json.load(sys.stdin).get("workflow_runs", []) if r.get("name") == "tests"]
except Exception:
    runs = None
print("unreadable" if runs is None else "none" if not runs else " ".join(sorted({(r["conclusion"] or r["status"]) for r in runs})))')"
case "$run" in
  success) ok "the tests on GitHub are green for ${head:0:7}" ;;
  *failure*|*cancelled*|*timed_out*) bad "the tests on GitHub for ${head:0:7}: $run" ;;
  *) bad "the tests on GitHub for ${head:0:7}: $run (a release waits for them to be green)" ;;
esac
if git ls-remote --tags origin "refs/tags/v$VER" 2>/dev/null | grep -q .; then
  if [[ "$MODE" == --publish || -z "$MODE" ]]; then bad "v$VER already exists on GitHub: a published version is never replaced, take the next number"; fi
else ok "v$VER is free"; fi
if grep -qE "^## ${VER//./\\.}( |$)" CHANGELOG.md; then ok "CHANGELOG.md has a heading for $VER (the archive ships it)"
else bad "CHANGELOG.md has no « ## $VER » heading: write it, push it (push-main), then release that commit"; fi

if [[ -z "$MODE" ]]; then
  step "2. Build"
  lib="app/addons/vtterm/bin/libvtterm.windows.template_release.x86_64.dll"
  src_time="$(git log -1 --format=%ct -- native/ 2>/dev/null || echo 0)"
  if [[ -f "$lib" && "$(stat -c %Y "$lib")" -ge "$src_time" ]] && ! grep -qaF "$HOME" "$lib"; then
    ok "the terminal library is newer than its source and holds no path of this home folder: kept"
  else
    echo "   building the terminal library (tools/build_native.sh template_release): several minutes"
    if tools/build_native.sh template_release >"$OUT/native.log" 2>&1; then ok "the terminal library is built"; else bad "tools/build_native.sh template_release failed (see $OUT/native.log)"; fi
  fi
  if tools/build_release.sh "$VER" >"$OUT/build.log" 2>&1 && [[ -f "$ZIP" ]]; then ok "$ZIP is built"; else bad "tools/build_release.sh $VER failed (see $OUT/build.log)"; fi
fi

step "3. The archive"
if [[ ! -f "$ZIP" ]]; then bad "$ZIP is not there: run tools/release.sh $VER first"
else
relay() { while IFS=$'\t' read -r kind msg; do
  case "$kind" in F) bad "$msg" ;; W) warn "$msg" ;; O) ok "$msg" ;; *) [[ -n "$kind" ]] && echo "           $kind" ;; esac
done; }
relay < <(python3 - "$ZIP" "$VER" "$HOME" "$(whoami)" <<'EOF'
import re, subprocess, sys, zipfile

path, ver, home, user = sys.argv[1:5]
top = "AgentManagerGD-win64/"
git = lambda *a: subprocess.run(["git", *a], capture_output=True).stdout
try:
    z = zipfile.ZipFile(path)
    broken = z.testzip()
except Exception as e:
    print(f"F\tthe archive cannot be read: {e}"); sys.exit()
names = set(z.namelist())
print(f"F\tthe archive is damaged at {broken}" if broken else f"O\tthe archive opens, {len(names)} entries")

need = ["AgentManagerGD.exe", "ghostty-vt.dll", "libvtterm.windows.template_release.x86_64.dll", "install.ps1", "uninstall.ps1",
        "VERSION", "README.md", "CHANGELOG.md", "LICENSE", "SECURITY.md", "THIRD_PARTY_NOTICES.md", "engine/__main__.py", "sandbox/Dockerfile"]
missing = [n for n in need if top + n not in names]
print(f"F\tmissing from the archive: {', '.join(missing)}" if missing else "O\tthe app, both terminal libraries, the engine, the installers and the notices are there")
if top + "VERSION" in names:
    said = z.read(top + "VERSION").decode().strip()
    print(f"O\tVERSION says {said}" if said == ver else f"F\tVERSION says {said}, not {ver}")

# built from this commit: what the archive ships as text is what HEAD holds
shipped = [n[len(top):] for n in names if n.startswith(top + "engine/") and not n.endswith("/")] + ["CHANGELOG.md", "README.md", "installer/install.ps1"]
differ = []
for rel in shipped:
    inzip = top + (rel.split("/", 1)[1] if rel.startswith("installer/") else rel)
    if inzip in names and z.read(inzip) != git("show", f"HEAD:{rel}"):
        differ.append(rel)
print(f"F\tnot built from this commit: {', '.join(differ[:6])} differ from HEAD" if differ else f"O\tthe engine ({len(shipped) - 3} files), the CHANGELOG, the README and the installer are HEAD's")

exe = z.read(top + "AgentManagerGD.exe") if top + "AgentManagerGD.exe" in names else b""
tools = sorted(set(m.decode() for m in re.findall(rb"tools_[a-z_]+\.gd", exe)))
print(f"F\tcapture tools are packed in the app: {', '.join(tools)}" if tools else "O\tno capture tool (tools_*.gd) is packed in the app")

# nothing of the builder, no key. (The app's TLS library carries the words « BEGIN RSA PRIVATE KEY » as constants: not a key.)
traces = {"this home folder": re.escape(home.encode()), "this user's Windows folder": rb"[A-Za-z]:\\Users\\" + re.escape(user.encode()),
          "a GitHub token": rb"gh[opsu]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}", "an OpenAI or Anthropic key": rb"sk-[A-Za-z0-9_-]{30,}",
          "an SSH private key": rb"BEGIN OPENSSH PRIVATE KEY", "a .env file": None}
found = []
for n in sorted(names):
    if n.endswith("/"):
        continue
    if re.search(r"(^|/)\.env(\.|$)", n):
        found.append(f"a .env file: {n}")
    data = z.read(n)
    for what, pat in traces.items():
        if pat and re.search(pat, data):
            found.append(f"{what} in {n[len(top):]}")
print(("F\tthe archive holds: " + "; ".join(found[:8])) if found else "O\tno path of the builder's folders, no key, no token, no .env in the archive")
EOF
)
fi

if [[ -f "$ZIP" && $fails -eq 0 ]]; then
  printf 'version %s\ncommit %s\nsha256 %s\n' "$VER" "$head" "$(sha "$ZIP")" > "$STAMP"
  ok "checksum $(sha "$ZIP") (kept in $STAMP)"
fi

step "4. The notes"
if [[ ! -f "$NOTES" && -f "$ZIP" ]]; then
  python3 - "$VER" "$head" "$(sha "$ZIP")" "$NOTES" <<'EOF'
import re, sys
ver, head, digest, out = sys.argv[1:5]
tpl = open(".claude/skills/release/notes-template.md", encoding="utf-8").read()
log = open("CHANGELOG.md", encoding="utf-8").read()
m = re.search(rf"^## {re.escape(ver)}[^\n]*\n(.*?)(?=^## |\Z)", log, re.S | re.M)
changes = (m.group(1).strip() if m else "").strip() or "(write what changed for someone using the app)"
open(out, "w", encoding="utf-8").write(tpl.replace("@VERSION@", ver).replace("@SHA256@", digest).replace("@COMMIT_FULL@", head)
                                      .replace("@COMMIT@", head[:7]).replace("@CHANGES@", changes))
EOF
  warn "the notes were drafted from the template and the CHANGELOG: read and edit $NOTES before publishing"
elif [[ -f "$NOTES" ]]; then
  if grep -q '@[A-Z_]*@' "$NOTES"; then bad "$NOTES still has a placeholder"; else ok "$NOTES is written"; fi
  if [[ -f "$ZIP" ]] && ! grep -qF "$(sha "$ZIP")" "$NOTES"; then bad "$NOTES does not give this archive's checksum (the archive was rebuilt: put $(sha "$ZIP"))"; fi
fi

step "Verdict"
if (( fails )); then echo "   NOT READY: $fails failure(s), $warns warning(s). Nothing was published."; exit 1; fi
if [[ "$MODE" != --publish ]]; then
  echo "   READY to publish: no failure, $warns warning(s) to read. Nothing was published."
  echo "   Not checked here: the app itself was not launched. With the owner's OK for this release: tools/release.sh $VER --publish"
  exit 0
fi
if (( warns )); then echo "   $warns warning(s): settle them, then publish. Nothing was published."; exit 1; fi
kind=(); [[ "$VER" == *-* ]] && kind=(--prerelease)
if gh release create "v$VER" "$ZIP" -R "$SLUG" --target "$head" --title "Agent Manager GD $VER" --notes-file "$NOTES" "${kind[@]}"; then
  echo "   PUBLISHED: v$VER from ${head:0:7}."
  echo "   Next: tools/release.sh $VER --after, then the owner's try on a Windows machine."
else
  echo "   The release was NOT made (gh refused: see above)."; exit 1
fi
