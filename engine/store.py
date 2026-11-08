"""Session records (SQLite): what tmux does not know — the tool, the folder, the group, when it was made."""
from __future__ import annotations

import os
import secrets
import sqlite3
import time
from contextlib import closing

SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    tool TEXT NOT NULL,
    cwd TEXT NOT NULL,
    grp TEXT NOT NULL DEFAULT '',
    created REAL NOT NULL,
    archived INTEGER NOT NULL DEFAULT 0
);
"""


class Store:
    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with closing(self._db()) as db:
            db.executescript(SCHEMA)

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        return db

    def add(self, name: str, tool: str, cwd: str, grp: str = "") -> dict:
        sid = secrets.token_hex(4)
        row = {"id": sid, "name": name, "tool": tool, "cwd": cwd, "grp": grp, "created": time.time(), "archived": 0}
        with closing(self._db()) as db, db:
            db.execute("INSERT INTO sessions VALUES (:id, :name, :tool, :cwd, :grp, :created, :archived)", row)
        return row

    def all(self, archived: bool = False) -> list[dict]:
        with closing(self._db()) as db:
            rows = db.execute("SELECT * FROM sessions WHERE archived = ? ORDER BY created", (int(archived),)).fetchall()
        return [dict(r) for r in rows]

    def get(self, sid: str) -> dict | None:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM sessions WHERE id = ?", (sid,)).fetchone()
        return dict(r) if r else None

    def update(self, sid: str, **fields) -> None:
        allowed = {k: v for k, v in fields.items() if k in ("name", "grp", "archived")}
        if not allowed:
            return
        sets = ", ".join(f"{k} = :{k}" for k in allowed)
        with closing(self._db()) as db, db:
            db.execute(f"UPDATE sessions SET {sets} WHERE id = :id", {**allowed, "id": sid})

    def delete(self, sid: str) -> None:
        with closing(self._db()) as db, db:
            db.execute("DELETE FROM sessions WHERE id = ?", (sid,))
