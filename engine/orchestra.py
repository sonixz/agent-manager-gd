"""The orchestrator's routing (Loop 26): its plan, the owner's routing rules and the daily token budget, kept in one
small file of the data folder (orchestrator.json). The orchestrator reads the rules and writes its plan through
Agent Manager's MCP server; the owner edits the rules and the budget in the app. Tokens come from the agents' own
logs (engine/usage.py): no money amount is invented."""
from __future__ import annotations

import json
import os
import re
import time

TOOLS = ("claude", "codex", "shell")
STATUSES = ("planned", "running", "review", "done", "dropped")
DEFAULT_RULES = [
    {"when": "architecture, large refactors, hard bugs", "tool": "claude", "model": "opus"},
    {"when": "everyday features and fixes", "tool": "claude", "model": "sonnet"},
    {"when": "small edits, docs, renames", "tool": "claude", "model": "haiku"},
    {"when": "a second opinion, code review", "tool": "codex", "model": ""},
]


class Orchestra:
    def __init__(self, home: str):
        self.path = os.path.join(home, "data", "orchestrator.json")

    def _load(self) -> dict:
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            d = {}
        d.setdefault("plan", {"goal": "", "tasks": [], "updated": 0})
        d.setdefault("rules", [dict(r) for r in DEFAULT_RULES])
        d.setdefault("budget", {"daily_tokens": 0})
        return d

    def _save(self, d: dict) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)
        os.replace(tmp, self.path)

    # ---------------------------------------------------------------- the plan (written by the orchestrator)
    @staticmethod
    def _task(t: dict, i: int) -> dict:
        tool = str(t.get("tool", "claude"))
        status = str(t.get("status", "planned"))
        return {"id": str(t.get("id") or f"t{i + 1}")[:20], "title": " ".join(str(t.get("title", "")).split())[:120],
                "repo": str(t.get("repo", ""))[:80], "tool": tool if tool in TOOLS else "claude",
                "model": str(t.get("model", ""))[:40], "why": " ".join(str(t.get("why", "")).split())[:200],
                "status": status if status in STATUSES else "planned", "session": str(t.get("session", ""))[:20]}

    def plan(self) -> dict:
        return self._load()["plan"]

    def set_plan(self, goal: str, tasks: list) -> dict:
        if not isinstance(tasks, list) or not tasks or len(tasks) > 20:
            raise ValueError("a plan of 1 to 20 tasks")
        out = [self._task(t if isinstance(t, dict) else {"title": str(t)}, i) for i, t in enumerate(tasks)]
        if any(not t["title"] for t in out):
            raise ValueError("every task needs a title")
        d = self._load()
        d["plan"] = {"goal": " ".join(str(goal).split())[:200], "tasks": out, "updated": time.time()}
        self._save(d)
        return d["plan"]

    def update_task(self, tid: str, status: str = "", session: str = "", note: str = "") -> dict:
        d = self._load()
        task = next((t for t in d["plan"]["tasks"] if t["id"] == tid), None)
        if task is None:
            raise ValueError(f"no task {tid} in the plan")
        if status:
            if status not in STATUSES:
                raise ValueError("status must be one of " + ", ".join(STATUSES))
            task["status"] = status
        if session:
            task["session"] = session[:20]
        if note:
            task["why"] = " ".join(note.split())[:200]
        d["plan"]["updated"] = time.time()
        self._save(d)
        return task

    # ---------------------------------------------------------------- the owner's rules and budget
    def rules(self) -> list:
        return self._load()["rules"]

    def set_rules(self, rules: list) -> list:
        if not isinstance(rules, list) or len(rules) > 20:
            raise ValueError("at most 20 rules")
        out = []
        for r in rules:
            when = " ".join(str(r.get("when", "")).split())[:120]
            tool = str(r.get("tool", "claude"))
            model = str(r.get("model", "")).strip()[:40]
            if not when:
                continue
            if tool not in TOOLS:
                raise ValueError("a rule's tool is claude, codex or shell")
            if model and not re.match(r"^[A-Za-z0-9._\-\[\]]+$", model):
                raise ValueError("a model name of letters, digits, dots and dashes")
            out.append({"when": when, "tool": tool, "model": model})
        d = self._load()
        d["rules"] = out
        self._save(d)
        return out

    def budget(self) -> int:
        return int(self._load()["budget"].get("daily_tokens", 0) or 0)

    def set_budget(self, tokens: int) -> int:
        if tokens < 0:
            raise ValueError("a budget of 0 (none) or more tokens")
        d = self._load()
        d["budget"] = {"daily_tokens": int(tokens)}
        self._save(d)
        return int(tokens)


def today() -> str:
    """The agents' logs stamp their messages in UTC: « today » is the UTC day."""
    return time.strftime("%Y-%m-%d", time.gmtime())
