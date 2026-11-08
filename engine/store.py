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
CREATE TABLE IF NOT EXISTS conversations (
    session_id TEXT NOT NULL,
    tool TEXT NOT NULL,
    conversation TEXT NOT NULL,
    started REAL NOT NULL,
    last_seen REAL NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (session_id, conversation)
);
CREATE TABLE IF NOT EXISTS groups (
    name TEXT PRIMARY KEY,
    position INTEGER NOT NULL DEFAULT 0,
    folded INTEGER NOT NULL DEFAULT 0
);
"""


class Store:
    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with closing(self._db()) as db, db:
            db.executescript(SCHEMA)
            cols = {r[1] for r in db.execute("PRAGMA table_info(sessions)")}
            if "position" not in cols:  # Loop 4A: the order inside a group
                db.execute("ALTER TABLE sessions ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
            for col in ("parent", "worktree", "base_repo", "brain_client"):  # Loop 5 forks, worktrees; Loop 6 Brain
                if col not in cols:
                    db.execute(f"ALTER TABLE sessions ADD COLUMN {col} TEXT NOT NULL DEFAULT ''")
            if "archived_at" not in cols:
                db.execute("ALTER TABLE sessions ADD COLUMN archived_at REAL NOT NULL DEFAULT 0")

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        return db

    def add(self, name: str, tool: str, cwd: str, grp: str = "", parent: str = "", worktree: str = "",
            base_repo: str = "") -> dict:
        sid = secrets.token_hex(4)
        if grp:
            self.add_group(grp)
        with closing(self._db()) as db, db:
            pos = db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM sessions WHERE grp = ?", (grp,)).fetchone()[0]
            row = {"id": sid, "name": name, "tool": tool, "cwd": cwd, "grp": grp, "created": time.time(), "archived": 0,
                   "position": pos, "parent": parent, "worktree": worktree, "base_repo": base_repo, "archived_at": 0}
            db.execute("INSERT INTO sessions (id, name, tool, cwd, grp, created, archived, position, parent, worktree, "
                       "base_repo, archived_at) VALUES (:id, :name, :tool, :cwd, :grp, :created, :archived, :position, "
                       ":parent, :worktree, :base_repo, :archived_at)", row)
        return row

    def all(self, archived: bool = False) -> list[dict]:
        with closing(self._db()) as db:
            rows = db.execute("SELECT * FROM sessions WHERE archived = ? ORDER BY position, created",
                              (int(archived),)).fetchall()
        return [dict(r) for r in rows]

    def get(self, sid: str) -> dict | None:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM sessions WHERE id = ?", (sid,)).fetchone()
        return dict(r) if r else None

    def update(self, sid: str, **fields) -> None:
        allowed = {k: v for k, v in fields.items() if k in ("name", "grp", "archived", "archived_at", "cwd", "worktree",
                                                            "brain_client")}
        if not allowed:
            return
        sets = ", ".join(f"{k} = :{k}" for k in allowed)
        with closing(self._db()) as db, db:
            db.execute(f"UPDATE sessions SET {sets} WHERE id = :id", {**allowed, "id": sid})

    # ---------------------------------------------------------------- conversations (never lose one)
    def touch_conversation(self, sid: str, tool: str, conversation: str) -> bool:
        """Records a conversation id for a session; True when it is new."""
        if not conversation:
            return False
        now = time.time()
        with closing(self._db()) as db, db:
            cur = db.execute("UPDATE conversations SET last_seen = ? WHERE session_id = ? AND conversation = ?",
                             (now, sid, conversation))
            if cur.rowcount:
                return False
            db.execute("INSERT INTO conversations (session_id, tool, conversation, started, last_seen) "
                       "VALUES (?, ?, ?, ?, ?)", (sid, tool, conversation, now, now))
            return True

    def conversations(self, sid: str) -> list[dict]:
        with closing(self._db()) as db:
            return [dict(r) for r in db.execute("SELECT * FROM conversations WHERE session_id = ? ORDER BY last_seen DESC",
                                                (sid,))]

    def history(self, query: str = "") -> list[dict]:
        """Every session ever made (archived ones too), newest first, each with its conversations; filtered by text."""
        with closing(self._db()) as db:
            rows = [dict(r) for r in db.execute("SELECT * FROM sessions ORDER BY created DESC")]
            convs = [dict(r) for r in db.execute("SELECT * FROM conversations ORDER BY last_seen DESC")]
        by = {}
        for c in convs:
            by.setdefault(c["session_id"], []).append(c)
        q = query.strip().lower()
        out = []
        for r in rows:
            r["conversations"] = by.get(r["id"], [])
            hay = " ".join([r["name"], r["cwd"], r["grp"], r["tool"], r["id"]] +
                           [c["conversation"] + " " + c["note"] for c in r["conversations"]]).lower()
            if not q or all(w in hay for w in q.split()):
                out.append(r)
        return out

    # ---------------------------------------------------------------- groups (the project tree)
    def groups(self) -> list[dict]:
        with closing(self._db()) as db:
            return [dict(r) for r in db.execute("SELECT * FROM groups ORDER BY position, name")]

    def add_group(self, name: str) -> None:
        with closing(self._db()) as db, db:
            if not db.execute("SELECT 1 FROM groups WHERE name = ?", (name,)).fetchone():
                pos = db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM groups").fetchone()[0]
                db.execute("INSERT INTO groups (name, position) VALUES (?, ?)", (name, pos))

    def rename_group(self, old: str, new: str) -> None:
        with closing(self._db()) as db, db:
            if db.execute("SELECT 1 FROM groups WHERE name = ?", (new,)).fetchone():
                raise ValueError(f"a group named {new} already exists")
            db.execute("UPDATE groups SET name = ? WHERE name = ?", (new, old))
            db.execute("UPDATE sessions SET grp = ? WHERE grp = ?", (new, old))

    def delete_group(self, name: str) -> None:
        """The group goes; its sessions stay, moved to the end of the sessions without a group."""
        with closing(self._db()) as db, db:
            base = db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM sessions WHERE grp = ''").fetchone()[0]
            for i, (sid,) in enumerate(db.execute("SELECT id FROM sessions WHERE grp = ? ORDER BY position", (name,)).fetchall()):
                db.execute("UPDATE sessions SET grp = '', position = ? WHERE id = ?", (base + i, sid))
            db.execute("DELETE FROM groups WHERE name = ?", (name,))

    def fold_group(self, name: str, folded: bool) -> None:
        with closing(self._db()) as db, db:
            db.execute("UPDATE groups SET folded = ? WHERE name = ?", (int(folded), name))

    def order_groups(self, names: list[str]) -> None:
        with closing(self._db()) as db, db:
            for i, n in enumerate(names):
                db.execute("UPDATE groups SET position = ? WHERE name = ?", (i, n))

    def move(self, sid: str, grp: str, index: int) -> None:
        """Puts a session at `index` inside `grp` (renumbering that group)."""
        if grp:
            self.add_group(grp)
        with closing(self._db()) as db, db:
            ids = [r[0] for r in db.execute("SELECT id FROM sessions WHERE grp = ? AND id != ? AND archived = 0 "
                                            "ORDER BY position, created", (grp, sid))]
            index = max(0, min(index, len(ids)))
            ids.insert(index, sid)
            db.execute("UPDATE sessions SET grp = ? WHERE id = ?", (grp, sid))
            for i, x in enumerate(ids):
                db.execute("UPDATE sessions SET position = ? WHERE id = ?", (i, x))

    def delete(self, sid: str) -> None:
        with closing(self._db()) as db, db:
            db.execute("DELETE FROM sessions WHERE id = ?", (sid,))
