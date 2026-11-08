"""Diff review (Loop 8): a session's changes, file by file, and the owner's line comments sent back as one request.

Modes: "uncommitted" (working tree against HEAD, new files included), "session" (everything since the commit the
session started from), "branch" (the session's branch and working tree against the repository's target branch,
for worktree sessions). Read-only git commands; nothing is ever changed in the repository."""
from __future__ import annotations

import os
import re
import subprocess

MAX_FILE_LINES = 3000
MAX_UNTRACKED_BYTES = 200_000
HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$")


def git(cwd: str, *args: str, check: bool = True) -> str:
    out = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, encoding="utf-8",
                         errors="replace", timeout=60)
    if check and out.returncode != 0:
        raise ValueError("git " + args[0] + ": " + (out.stderr.strip() or out.stdout.strip())[:300])
    return out.stdout


def is_repo(cwd: str) -> bool:
    return subprocess.run(["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"], capture_output=True,
                          timeout=10).returncode == 0


def head(cwd: str) -> str:
    return git(cwd, "rev-parse", "HEAD", check=False).strip() if is_repo(cwd) else ""


def parse(diff_text: str) -> list[dict]:
    """Unified diff -> [{path, old_path, status, additions, deletions, hunks: [{header, lines: [{t, old, new, text}]}]}]."""
    files: list[dict] = []
    cur = None
    old_no = new_no = 0
    for raw in diff_text.splitlines():
        if raw.startswith("diff --git "):
            m = re.match(r"^diff --git a/(.*) b/(.*)$", raw)
            cur = {"path": "", "old_path": "", "status": "modified", "additions": 0, "deletions": 0, "hunks": [],
                   "binary": False, "truncated": False, "_count": 0, "_header": m.group(2) if m else ""}
            files.append(cur)
            continue
        if cur is None:
            continue
        if raw.startswith("new file mode"):
            cur["status"] = "added"
        elif raw.startswith("deleted file mode"):
            cur["status"] = "deleted"
        elif raw.startswith("rename from "):
            cur["status"], cur["old_path"] = "renamed", raw[12:]
        elif raw.startswith("rename to "):
            cur["path"] = raw[10:]
        elif raw.startswith("Binary files"):
            cur["binary"] = True
        elif raw.startswith("--- "):
            p = raw[4:]
            cur["old_path"] = cur["old_path"] or (p[2:] if p.startswith("a/") else "")
        elif raw.startswith("+++ "):
            p = raw[4:]
            cur["path"] = cur["path"] or (p[2:] if p.startswith("b/") else cur["old_path"])
        elif raw.startswith("@@"):
            m = HUNK.match(raw)
            if m:
                old_no, new_no = int(m.group(1)), int(m.group(2))
                cur["hunks"].append({"header": raw, "lines": []})
        elif cur["hunks"] and raw[:1] in ("+", "-", " ", "\\"):
            if raw.startswith("\\"):
                continue
            cur["_count"] += 1
            if cur["_count"] > MAX_FILE_LINES:
                cur["truncated"] = True
                continue
            t = raw[0]
            line = {"t": t, "old": old_no if t != "+" else 0, "new": new_no if t != "-" else 0, "text": raw[1:]}
            cur["hunks"][-1]["lines"].append(line)
            if t == "+":
                cur["additions"] += 1
                new_no += 1
            elif t == "-":
                cur["deletions"] += 1
                old_no += 1
            else:
                old_no += 1
                new_no += 1
    for f in files:
        f.pop("_count", None)
        f["path"] = f["path"] or f["old_path"] or f.pop("_header", "")
        f.pop("_header", None)
    return files


def untracked(cwd: str) -> list[dict]:
    out = []
    for path in git(cwd, "ls-files", "--others", "--exclude-standard").splitlines():
        full = os.path.join(cwd, path)
        try:
            if os.path.getsize(full) > MAX_UNTRACKED_BYTES:
                out.append({"path": path, "old_path": "", "status": "added", "additions": 0, "deletions": 0,
                            "hunks": [], "binary": False, "truncated": True})
                continue
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if b"\0" in data[:4096]:
            out.append({"path": path, "old_path": "", "status": "added", "additions": 0, "deletions": 0,
                        "hunks": [], "binary": True, "truncated": False})
            continue
        lines = data.decode("utf-8", "replace").splitlines()
        shown = lines[:MAX_FILE_LINES]
        out.append({"path": path, "old_path": "", "status": "added", "additions": len(lines), "deletions": 0,
                    "binary": False, "truncated": len(lines) > MAX_FILE_LINES,
                    "hunks": [{"header": f"@@ -0,0 +1,{len(lines)} @@ new file", "lines": [
                        {"t": "+", "old": 0, "new": i + 1, "text": t} for i, t in enumerate(shown)]}]})
    return out


def diff(cwd: str, mode: str, start_commit: str = "", target: str = "") -> dict:
    if not is_repo(cwd):
        return {"mode": mode, "files": [], "note": "not a git repository: nothing to compare"}
    base = "HEAD"
    if mode == "session":
        base = start_commit or "HEAD"
    elif mode == "branch":
        if not target:
            raise ValueError("this session has no target branch (it has no worktree of its own)")
        base = git(cwd, "merge-base", target, "HEAD").strip()
    has_head = bool(head(cwd))
    args = ["diff", "--no-color", "--no-ext-diff", "-U3", "-M"] + ([base] if has_head else ["--cached"])
    files = parse(git(cwd, *args))
    files += untracked(cwd)
    files.sort(key=lambda f: f["path"])
    return {"mode": mode, "base": base if has_head else "", "files": files,
            "additions": sum(f["additions"] for f in files), "deletions": sum(f["deletions"] for f in files)}


def compose(comments: list[dict]) -> str:
    """The review as one message to the agent: numbered, each with its file, line and the line's code."""
    parts = ["Review of your changes from the owner (via Agent Manager GD). Please address each point, then say "
             "which ones you changed:"]
    for i, c in enumerate(comments, 1):
        where = f"{c['path']}:{c['line']}" if int(c.get("line") or 0) else c["path"]
        code = f'  (line: "{c["code"].strip()[:120]}")' if c.get("code", "").strip() else ""
        parts.append(f"{i}. {where} — {c['text'].strip()}{code}")
    return " ".join(parts)
