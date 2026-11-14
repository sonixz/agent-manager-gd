#!/usr/bin/env bash
# Pushing main, the same way each time. First the website, its index with the loops list, the Docs and the devlog are
# brought up to date with what is about to go out (the steps: .claude/skills/push-main/SKILL.md); then this script
# checks everything and, only when asked, pushes. A failure is a fact (red tests, a secret, a push that is not a fast-forward). A warning is a
# judgement (« the app changed, the website did not »): someone reads it and says it is fine.
#   tools/push_main.sh              the report: what would go out and every gate. Changes nothing, pushes nothing.
#   tools/push_main.sh --push       the same gates, then git push origin main (fast-forward only, never forced)
#   tools/push_main.sh --after      after a push: GitHub's main, the tests there, the website online
#   --reviewed    with --push: « I read the warnings, they are fine »
#   --quick       the report without the engine tests (refused with --push)
# Needs git, python3 and tmux. Never prints a secret: a suspicious line is named by file and line number only.
set -uo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
SITE_URL="${SITE_URL:-https://sonixz.github.io/gd-project/agent-manager/}"   # published by gd-project's « Publish the site »

PUSH=0; REVIEWED=0; QUICK=0; AFTER=0
for a in "$@"; do
  case "$a" in
    --push) PUSH=1 ;;
    --reviewed) REVIEWED=1 ;;
    --quick) QUICK=1 ;;
    --after) AFTER=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
if (( PUSH && QUICK )); then echo "--quick is refused with --push: main does not go out without its tests" >&2; exit 2; fi

fails=0; warns=0
step() { printf '\n== %s\n' "$1"; }
ok()   { printf '   ok    %s\n' "$1"; }
warn() { printf '   WARN  %s\n' "$1"; warns=$((warns + 1)); }
bad()  { printf '   FAIL  %s\n' "$1"; fails=$((fails + 1)); }
remote_main() { git ls-remote origin refs/heads/main 2>/dev/null | cut -f1; }

if (( AFTER )); then
  step "After the push"
  head="$(git rev-parse HEAD)"; remote="$(remote_main)"
  if [[ "$remote" == "$head" ]]; then ok "GitHub's main is ${head:0:7}, like here"; else bad "GitHub's main is ${remote:0:7}, here it is ${head:0:7}"; fi
  slug="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
  run="$(curl -sS -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$slug/actions/runs?head_sha=$head&per_page=5" 2>/dev/null |
    python3 -c 'import json, sys
try:
    runs = json.load(sys.stdin).get("workflow_runs", [])
except Exception:
    runs = None
print("unreadable" if runs is None else "none" if not runs else " ".join(sorted({(r["conclusion"] or r["status"]) for r in runs})))')"
  case "$run" in
    success) ok "the tests on GitHub are green for ${head:0:7}" ;;
    none) warn "no run on GitHub for ${head:0:7} yet: look again in a minute" ;;
    unreadable) warn "GitHub's Actions could not be read from here" ;;
    *failure*|*cancelled*|*timed_out*) bad "the tests on GitHub for ${head:0:7}: $run" ;;
    *) warn "the tests on GitHub for ${head:0:7}: $run (not finished)" ;;
  esac
  for page in "" docs.html howto.html; do
    code="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$SITE_URL$page" || true)"
    if [[ "$code" == 200 ]]; then ok "$SITE_URL$page answers"; else bad "$SITE_URL$page answers $code"; fi
  done
  echo "   The website online is the last « Publish the site » of gd-project: it takes public/ from this main."
  echo "   If public/ changed in this push, that workflow must run once more (a push to gd-project, or by hand)."
  exit $(( fails > 0 ))
fi

step "1. Where we are"
branch="$(git symbolic-ref --quiet --short HEAD || echo detached)"
if [[ "$branch" == main ]]; then ok "on main"; else bad "on « $branch », not on main"; fi
if [[ -z "$(git status --porcelain)" ]]; then ok "nothing uncommitted"
else bad "uncommitted changes: commit them or put them aside first"; git status --short | head -15 | sed 's/^/           /'; fi
gitdir="$(git rev-parse --git-dir)"
if [[ -e "$gitdir/MERGE_HEAD" || -d "$gitdir/rebase-merge" || -d "$gitdir/rebase-apply" ]]; then bad "a merge or a rebase is in progress"; fi
waiting="$(git branch --no-merged main --format='%(refname:short)' | tr '\n' ' ')"
[[ -n "$waiting" ]] && echo "   note  not in main, so not in this push: $waiting"

step "2. Where GitHub's main is"
remote="$(remote_main)"; RANGE=""
if [[ -z "$remote" ]]; then bad "origin cannot be read (git ls-remote origin)"
elif ! git cat-file -e "$remote^{commit}" 2>/dev/null; then bad "GitHub's main (${remote:0:7}) has commits this copy does not have: git pull --ff-only first"
elif ! git merge-base --is-ancestor "$remote" HEAD; then bad "main here and GitHub's main went separate ways: this push would not be a fast-forward"
else
  RANGE="$remote..HEAD"; n="$(git rev-list --count "$RANGE")"
  ok "GitHub's main is ${remote:0:7}; $n commit(s) to push"
  if (( n == 0 )); then echo; echo "Nothing to push."; exit $(( fails > 0 )); fi
fi
if [[ -z "$RANGE" ]]; then echo; echo "NOT READY: $fails failure(s). Without GitHub's main, the rest cannot be checked."; exit 1; fi

step "3. What goes out"
git log --format='   %h %ad %s' --date=short "$RANGE" | cut -c1-150
files="$(git diff --name-only "$RANGE")"
count() { grep -cE "$1" <<<"$files" || true; }
touched() { grep -qE "$1" <<<"$files"; }
product="$(count '^(app|engine|native|installer|sandbox)/')"
printf '   files: the app and its engine %s · the website %s · README, CHANGELOG and docs %s · tests %s · tools %s\n' \
  "$product" "$(count '^public/')" "$(count '^(README|CHANGELOG|SECURITY|AI-NOTICE|CONTRIBUTING|AGENTS)\.md$|^docs/')" "$(count '^tests/')" "$(count '^tools/')"

step "4. The public face follows the changes"
if (( product > 0 )); then
  if touched '^CHANGELOG\.md$'; then ok "CHANGELOG.md changed with the app"; else warn "the app or its engine changed, CHANGELOG.md did not"; fi
  pages="$(grep -oE '^public/(index|docs|howto)\.html$' <<<"$files" | sed 's#public/##' | tr '\n' ' ')"
  if [[ -n "$pages" ]]; then ok "the website changed with the app: $pages"; else warn "the app or its engine changed, the website (index, Docs, How-to) did not: does it need nothing?"; fi
else
  ok "no change in the app or its engine: the website has nothing to follow"
fi
if out="$(python3 tools/howto/build_page.py --check 2>&1)"; then ok "$out"; else bad "$out"; fi
# every loop going out is in the home page's loops list and in the devlog (kept beside the repository, not in it)
relay() { while IFS=$'\t' read -r kind msg; do
  case "$kind" in F) bad "$msg" ;; W) warn "$msg" ;; O) ok "$msg" ;; *) [[ -n "$kind" ]] && echo "           $kind" ;; esac
done; }
relay < <(python3 - "$RANGE" "${AGMGD_DEVLOG:-../$(basename "$PWD")-notes/DEVLOG.md}" <<'EOF'
import os, re, subprocess, sys

rng, devlog = sys.argv[1], sys.argv[2]
git = lambda *a: subprocess.run(["git", *a], capture_output=True, text=True, errors="replace").stdout
spans = lambda found: {n for a, b in found for n in range(int(a), int(b or a) + 1)}
names = lambda ns: ", ".join(f"Loop {n}" for n in sorted(ns))
going = {int(n) for n in re.findall(r"\bLoop (\d+)", git("log", "--format=%s", rng))}

page = open("public/index.html", encoding="utf-8").read()
listed = spans(re.findall(r'class="when">Loops? (\d+)(?:[–-](\d+))?', page))
told = spans(re.findall(r"^### .*\bLoops? (\d+)(?:[–-](\d+))?", open("CHANGELOG.md", encoding="utf-8").read(), re.M))
if going - listed:
    print(f"F\tnot in the home page's loops list (public/index.html, #loops): {names(going - listed)}")
elif told and listed and max(told) > max(listed):
    print(f"F\tthe CHANGELOG goes up to Loop {max(told)}, the home page's loops list stops at Loop {max(listed)}")
else:
    print(f"O\tthe home page's loops list goes up to Loop {max(listed)}" + (f" and holds {names(going)}" if going else ""))

if not os.path.exists(devlog):
    print(f"the devlog is kept outside the repository and is not here ({devlog}): not checked")
else:
    heads = re.findall(r"^## (.+)$", open(devlog, encoding="utf-8").read(), re.M)
    logged = {int(n) for h in heads for n in re.findall(r"\bLoop (\d+)", h)}
    dates = [d for h in heads for d in re.findall(r"\((\d{4}-\d{2}-\d{2})\)", h)]
    newest = git("log", "-1", "--format=%ad", "--date=short", rng).strip()
    if going - logged:
        print(f"F\tnot in the devlog ({devlog}): {names(going - logged)}")
    elif not dates or max(dates) < newest:
        print(f"W\tthe devlog's last entry is dated {max(dates) if dates else '?'}, the newest commit going out {newest}: does it tell this push?")
    else:
        print(f"O\tthe devlog goes up to {max(dates)}" + (f" and holds {names(going)}" if going else ""))
EOF
)

step "5. Engine tests"
if (( QUICK )); then warn "not run (--quick)"
elif ! command -v tmux >/dev/null; then bad "tmux is needed: without it the engine tests are skipped, not passed"
else
  log="$(mktemp -t agmgd-push-tests-XXXX)"
  if python3 -m unittest discover -s tests/python -t . >"$log" 2>&1; then ok "$(grep -E '^Ran ' "$log" | tail -1) · $(tail -1 "$log")"
  else bad "the engine tests are red"; tail -25 "$log" | sed 's/^/           /'; fi
  rm -f "$log"
  # the setup check's reading (Windows, WSL, programs, engine) is checked in Godot, without a display
  if ! command -v godot >/dev/null; then warn "godot is not here: the setup check's cases were not run"
  elif out="$(godot --headless --path app --script res://tools_setup_check.gd 2>&1)"; then ok "the setup check's cases: $(tail -1 <<<"$out")"
  else bad "the setup check's cases fail"; grep -E "^FAIL|passed" <<<"$out" | sed 's/^/           /'; fi
fi

step "6. Website checks (tools/site.sh --check)"
if out="$(bash tools/site.sh --check 2>&1)"; then ok "How-to screenshots, links, images, nothing personal, weight $(tail -1 <<<"$out")"
else bad "the website checks fail"; tail -20 <<<"$out" | sed 's/^/           /'; fi

step "7. Nothing private goes out, and the words are right"
# A program the tests or the tools run must be executable in the repository: on the Windows disk a chmod is not
# recorded by git, and GitHub's tests failed on it twice (tools/release.sh 2026-11-13, standins/gh 2026-11-14).
noexec="$(git ls-files -s -- 'tools/*.sh' 'tests/python/standins/*' | awk '$1 != "100755" {print $4}')"
if [[ -n "$noexec" ]]; then
  bad "not executable in the repository (git update-index --chmod=+x <file>): $(echo $noexec)"
else
  ok "every script of tools/ and every stand-in of the tests is executable in the repository"
fi
relay < <(python3 - "$RANGE" <<'EOF'
import getpass, os, re, subprocess, sys

rng = sys.argv[1]
git = lambda *a: subprocess.run(["git", *a], capture_output=True, text=True, errors="replace").stdout
added = []   # (file, line number, text) for every line this push adds
path, n = "", 0
for line in git("diff", "-U0", "--no-color", rng).splitlines():
    if line.startswith("+++ "):
        path = line[6:] if line.startswith("+++ b/") else ""
    elif line.startswith("@@"):
        n = int(re.search(r"\+(\d+)", line).group(1))
    elif line.startswith("+") and path:
        added.append((path, n, line[1:])); n += 1

# 1. secrets and personal traces: the place is named, never the text
secret = {
    "a private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "something shaped like a token": re.compile(
        r"\b(sk-ant-[\w-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_\w{20,}|AKIA[0-9A-Z]{16}|xox[abp]-[\w-]{10,}|fm2_[\w+/=-]{20,})"),
    "this computer's home folder": re.compile(re.escape(os.path.expanduser("~")) + r"(?![\w-])"),
    "this computer's user name": re.compile(r"(?<![\w.-])" + re.escape(getpass.getuser()) + r"@(?!example\.)"),
}
hits = [f"{p}:{i}: {what}" for p, i, t in added for what, rx in secret.items() if rx.search(t)]
names = [p for p in git("diff", "--name-only", "--diff-filter=A", rng).splitlines()
         if re.search(r"(^|/)(\.env(\.(?!example$)[^/]*)?|api_token|id_(rsa|ed25519)[^/]*|[^/]*\.(pem|sqlite3))$", p)]
for h in hits[:15]:
    print("F\t" + h)
for p in names:
    print(f"F\t{p}: a file that never goes in the repository")
if not hits and not names:
    print(f"O\tno key, token, personal path or secret file in the {len(added)} added lines")

# 2. the commits' identity: a GitHub noreply address, never a personal one (the address itself is not shown)
odd = [h for h, ae, ce in (l.split() for l in git("log", "--format=%h %ae %ce", rng).splitlines())
       if not all(e.endswith("@users.noreply.github.com") or e == "noreply@github.com" for e in (ae, ce))]
print("F\tcommits signed with another address than a GitHub noreply one: " + " ".join(odd) if odd
      else "O\tevery commit carries a GitHub noreply address")

# 3. two things are called sandbox; a new line must say which one it means
face = re.compile(r"^(README|CHANGELOG|SECURITY|AI-NOTICE|CONTRIBUTING)\.md$|^docs/|^public/[^/]+\.html$|^tools/howto/guides\.py$")
ours = re.compile(r"Fly|cloud|Sandboxes|throw-away|SSH|tunnel", re.I)
native = re.compile(r"Claude Code|Codex|bubblewrap|bwrap|socat|native", re.I)
named = re.compile(r"bubblewrap|bwrap|socat|(own|native|Code's|Codex's) sandbox", re.I)
tip, whole = rng.split("..")[1], {}


def around(p: str, i: int) -> str:
    """A sentence wraps: the two lines before and the two after say which sandbox it is, too."""
    lines = whole.setdefault(p, git("show", f"{tip}:{p}").splitlines())
    return " ".join(lines[max(0, i - 3): i + 2])


unclear = []
for p, i, t in added:
    if not (face.search(p) and re.search(r"sandbox", t, re.I)):
        continue
    if named.search(t) and ours.search(t):
        why = "both on one line"
    elif not ours.search(around(p, i)) and not native.search(around(p, i)):
        why = "which one?"
    else:
        continue
    text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", t)).strip()
    unclear.append(f"{p}:{i}: {why} · {text[:110]}")
if unclear:
    print(f"W\t« sandbox » on {len(unclear)} new line(s) of the public face does not say which one it is")
    print("« Sandboxes » are ours: Fly.io machines through an SSH tunnel. Claude Code's own sandbox (bubblewrap,")
    print("socat) is Claude Code's native feature and is always named as such.")
    for u in unclear[:12]:
        print(u)
    if len(unclear) > 12:
        print(f"… and {len(unclear) - 12} more")
else:
    print("O\tevery new « sandbox » on the public face says which one it is (ours on Fly.io, or Claude Code's own)")
EOF
)

step "Verdict"
if (( fails )); then echo "   NOT READY: $fails failure(s), $warns warning(s). Nothing was pushed."; exit 1; fi
if (( ! PUSH )); then
  echo "   READY: no failure, $warns warning(s) to read. Nothing was pushed."
  echo "   To push, with the owner's OK for this push: tools/push_main.sh --push$( (( warns )) && echo ' --reviewed')"
  exit 0
fi
if (( warns && ! REVIEWED )); then
  echo "   NOT PUSHED: $warns warning(s). Read them; if they are fine: tools/push_main.sh --push --reviewed"; exit 1
fi
if ! git push origin main; then
  echo "   The push was refused. If it is write access: tick « Allow write access » on the repository's deploy key."; exit 1
fi
now="$(remote_main)"
if [[ "$now" == "$(git rev-parse HEAD)" ]]; then echo "   PUSHED: GitHub's main is ${now:0:7}."
else echo "   Pushed, but GitHub's main reads ${now:0:7}: look at it."; exit 1; fi
echo "   Next: tools/push_main.sh --after (the tests on GitHub, the website online)."
