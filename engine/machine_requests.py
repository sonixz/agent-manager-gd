"""Agents asking for cloud machines (Loop 46; mission « étendre le MCP d'Agent Manager aux sandboxes Fly.io », the
owner's « Yes, lance la loop 46 »). What costs money or faces the internet is asked, never done, by an agent:

- create a machine (a private sandbox, or an Online machine that can face the internet), destroy one, expose one:
  a request the owner approves or refuses in the app (« They wait for you »). The engine does it only once approved;
- stop, start (within the budget) and unexpose: done at once, on the agent's own machines only;
- a machine is an agent's own when its first session descends from the agent's root session; at most
  MAX_PER_ROOT machines per root session, requests waiting counted.
Kept in the sessions' database: the owner can see every request, its answer and what it made."""
from __future__ import annotations

import json
import secrets as _rand
import sqlite3
import threading
import time
from contextlib import closing

MAX_PER_ROOT = 2
KINDS = ("create", "destroy", "expose")
SCHEMA = """
CREATE TABLE IF NOT EXISTS machine_requests (
    id TEXT PRIMARY KEY,
    sid TEXT NOT NULL,
    kind TEXT NOT NULL,
    params TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'pending',
    result TEXT NOT NULL DEFAULT '{}',
    created REAL NOT NULL,
    decided REAL NOT NULL DEFAULT 0
);
"""


class Requests:
    def __init__(self, db_path: str):
        self.db_path = db_path
        with closing(self._db()) as db, db:
            db.executescript(SCHEMA)

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    @staticmethod
    def _row(r) -> dict:
        d = dict(r)
        d["params"] = json.loads(d["params"] or "{}")
        d["result"] = json.loads(d["result"] or "{}")
        return d

    def add(self, sid: str, kind: str, params: dict) -> dict:
        rid = _rand.token_hex(4)
        with closing(self._db()) as db, db:
            db.execute("INSERT INTO machine_requests (id, sid, kind, params, created) VALUES (?, ?, ?, ?, ?)",
                       (rid, sid, kind, json.dumps(params), time.time()))
        return self.get(rid)

    def get(self, rid: str) -> dict:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM machine_requests WHERE id = ?", (rid,)).fetchone()
        if not r:
            raise KeyError(rid)
        return self._row(r)

    def set(self, rid: str, **f) -> None:
        if "result" in f:
            f["result"] = json.dumps(f["result"])
        sets = ", ".join(f"{k} = ?" for k in f)
        with closing(self._db()) as db, db:
            db.execute(f"UPDATE machine_requests SET {sets} WHERE id = ?", (*f.values(), rid))

    def pending(self) -> list[dict]:
        with closing(self._db()) as db:
            return [self._row(r) for r in db.execute("SELECT * FROM machine_requests WHERE status = 'pending' ORDER BY created")]

    def active(self) -> list[dict]:
        """Waiting for the owner, or approved and being done: both count against the caps."""
        with closing(self._db()) as db:
            return [self._row(r) for r in db.execute("SELECT * FROM machine_requests WHERE status IN ('pending', 'running') ORDER BY created")]

    def recent(self, limit: int = 30) -> list[dict]:
        with closing(self._db()) as db:
            return [self._row(r) for r in db.execute("SELECT * FROM machine_requests ORDER BY created DESC LIMIT ?", (limit,))]


def describe(req: dict) -> str:
    """The request in the owner's words, for the approval card."""
    p = req["params"]
    if req["kind"] == "create":
        what = "an Online machine (it can face the internet once exposed)" if p.get("kind") == "online" else "a private cloud sandbox"
        extra = []
        if p.get("repo_name"):
            extra.append("repository " + p["repo_name"])
        if p.get("kind") == "online":
            extra.append(f"service port {p.get('port', 8080)}, volume {p.get('volume_gb', 1)} GB")
        if p.get("expert"):
            extra.append("as the expert " + p["expert"])
        if p.get("secrets"):
            extra.append("secrets " + ", ".join(p["secrets"]))
        cost = f" · about ${p.get('month', 0):.2f} a month while it runs" if p.get("month") else ""
        return f"create {what}, {p.get('size', '')}, session « {p.get('name', '')} » ({p.get('tool', 'shell')})" + \
            ("; " + "; ".join(extra) if extra else "") + cost
    if req["kind"] == "destroy":
        return f"destroy the machine {p.get('sandbox', '')} (« {p.get('label', '')} »): its files and keys are deleted for good"
    if req["kind"] == "expose":
        return f"bind port {p.get('port', '')} of the machine « {p.get('label', '')} » to its public URL: https://{p.get('app', '')}.fly.dev reaches it from the internet"
    return req["kind"]


def run_later(fn) -> None:
    threading.Thread(target=fn, daemon=True).start()
