#!/usr/bin/env bash
# The website (public/), all of it in one command: every screenshot from the real app on a private virtual display
# (no window), the How-to page generated from tools/howto/guides.py, then the checks. Nothing is published.
#   tools/site.sh            screenshots + How-to page + checks (about 15 minutes)
#   tools/site.sh --check    the checks only
# Needs tools/build_native.sh first (the terminal extension), Xvfb, tmux, git, python3.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--check" ]]; then
  # the home page's screenshots, then one run per How-to guide
  tools/showcase.sh hero new-session agents repos brain-keys review voice sandboxes palette
  tools/showcase.sh $(python3 tools/howto/guides.py --ids | tr ' ' '\n' | sed 's/^/howto-/')
  python3 tools/howto/build_page.py
fi
fail=0
echo "== every How-to step has its screenshot"
python3 tools/howto/guides.py --check >/dev/null || { python3 tools/howto/guides.py --check | grep BAD; fail=1; }
echo "== every link to a section leads somewhere, every image file exists and has a text alternative"
python3 - <<'EOF' || fail=1
import glob, os, re, sys
root = "public/"
pages = {os.path.basename(f): open(f, encoding="utf-8").read() for f in glob.glob(root + "*.html")}
ids = {p: set(re.findall(r'id="([^"]+)"', s)) for p, s in pages.items()}
bad = []
for p, s in pages.items():
    for page, anchor in re.findall(r'href="([^"#:]*\.html)?#([^"]+)"', s):
        if anchor not in ids.get(page or p, set()):
            bad.append(f"{p}: link to {page or p}#{anchor}")
    for page in re.findall(r'href="([^"#:]+\.html)"', s):
        if page not in pages:
            bad.append(f"{p}: link to {page}")
    for tag in re.findall(r"<img\b[^>]*>", s):
        if "alt=" not in tag:
            bad.append(f"{p}: image without alt: {tag[:80]}")
        src = re.search(r'src="([^"]+)"', tag)
        if src and not src.group(1).startswith(("http", "data:")) and not os.path.exists(root + src.group(1)):
            bad.append(f"{p}: missing {src.group(1)}")
print("\n".join(bad) or "ok")
sys.exit(1 if bad else 0)
EOF
echo "== nothing personal in the capture reports"
if grep -rlaE "$HOME|$(whoami)@|pmastery" build/showcase/report-*.txt 2>/dev/null; then fail=1; else echo ok; fi
echo "== weight (under 10 MB)"
kb=$(du -sk public | cut -f1); echo "${kb} KB"; (( kb < 10240 )) || fail=1
exit $fail
