"""Agent usage (Loop 14): the tokens each session used, read from the logs Claude Code and Codex write themselves
(read-only, on this computer). Only what the logs say: tokens, by session, day and tool. The logs carry no money
amount, so none is invented (many users are on a subscription, where a « price » would mislead).

Claude Code: ~/.claude/projects/*/<conversation id>.jsonl, assistant messages' `usage` (counted once per message id).
Codex: ~/.codex/sessions/**/rollout-*<thread id>.jsonl, the last `token_count` event's `total_token_usage`.
AGMGD_CLAUDE_DIR and AGMGD_CODEX_DIR override the folders (tests)."""
from __future__ import annotations

import glob
import json
import os
from collections import defaultdict

_cache: dict = {}


def _claude_dir() -> str:
    return os.environ.get("AGMGD_CLAUDE_DIR") or os.path.expanduser("~/.claude/projects")


def _codex_dir() -> str:
    return os.environ.get("AGMGD_CODEX_DIR") or os.path.expanduser("~/.codex/sessions")


def _cached(path: str, reader):
    try:
        mt = os.path.getmtime(path)
    except OSError:
        return None
    hit = _cache.get(path)
    if hit and hit[0] == mt:
        return hit[1]
    data = reader(path)
    _cache[path] = (mt, data)
    return data


def _read_claude(path: str) -> dict:
    seen = set()
    days: dict = defaultdict(lambda: defaultdict(int))
    models: dict = defaultdict(int)
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            m = d.get("message") if isinstance(d.get("message"), dict) else None
            if d.get("type") != "assistant" or not m or not isinstance(m.get("usage"), dict):
                continue
            mid = m.get("id") or d.get("uuid")
            if mid in seen:
                continue
            seen.add(mid)
            u = m["usage"]
            day = str(d.get("timestamp", ""))[:10]
            row = days[day]
            row["input"] += int(u.get("input_tokens") or 0)
            row["output"] += int(u.get("output_tokens") or 0)
            row["cache_write"] += int(u.get("cache_creation_input_tokens") or 0)
            row["cache_read"] += int(u.get("cache_read_input_tokens") or 0)
            models[str(m.get("model", ""))] += int(u.get("output_tokens") or 0)
    return {"days": {k: dict(v) for k, v in days.items()}, "models": dict(models)}


def _read_codex(path: str) -> dict:
    last, day = None, ""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "token_count" not in line and "session_meta" not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            p = d.get("payload") if isinstance(d.get("payload"), dict) else {}
            if d.get("type") == "session_meta":
                day = str(p.get("timestamp", d.get("timestamp", "")))[:10]
            if p.get("type") == "token_count" and isinstance(p.get("info"), dict):
                last = p["info"].get("total_token_usage") or last
    if not last:
        return {"days": {}, "models": {}}
    row = {"input": int(last.get("input_tokens") or 0) - int(last.get("cached_input_tokens") or 0),
           "output": int(last.get("output_tokens") or 0),
           "cache_write": int(last.get("cache_write_input_tokens") or 0),
           "cache_read": int(last.get("cached_input_tokens") or 0)}
    return {"days": {day: row}, "models": {}}


def conversation_usage(tool: str, conversation: str) -> dict | None:
    if not conversation:
        return None
    if tool == "claude":
        files = glob.glob(os.path.join(_claude_dir(), "*", conversation + ".jsonl"))
        return _cached(files[0], _read_claude) if files else None
    if tool == "codex":
        files = glob.glob(os.path.join(_codex_dir(), "**", f"rollout-*{conversation}.jsonl"), recursive=True)
        return _cached(files[0], _read_codex) if files else None
    return None


def total(row: dict) -> int:
    return sum(int(row.get(k, 0)) for k in ("input", "output", "cache_write", "cache_read"))


def report(history: list[dict]) -> dict:
    """Per session (with its conversations), per day, per tool. Sessions without a readable log say so."""
    by_day: dict = defaultdict(lambda: defaultdict(int))
    by_tool: dict = defaultdict(int)
    sessions = []
    for s in history:
        if s["tool"] not in ("claude", "codex"):
            continue
        rows = defaultdict(int)
        found = 0
        for c in s.get("conversations", []):
            u = conversation_usage(s["tool"], c["conversation"])
            if not u:
                continue
            found += 1
            for day, r in u["days"].items():
                for k, v in r.items():
                    rows[k] += v
                    by_day[day][k] += v
        t = total(rows)
        by_tool[s["tool"]] += t
        sessions.append({"id": s["id"], "name": s["name"], "tool": s["tool"], "archived": s.get("archived", 0),
                         "tokens": dict(rows), "total": t, "logs_found": found,
                         "conversations": len(s.get("conversations", []))})
    sessions.sort(key=lambda x: -x["total"])
    days = [{"day": d, **dict(r), "total": total(r)} for d, r in sorted(by_day.items()) if d]
    return {"sessions": sessions, "days": days, "tools": dict(by_tool),
            "note": "Tokens read from the agents' own logs. No money amount: the logs carry none."}
