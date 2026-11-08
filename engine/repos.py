"""Connected repositories (Loop 9): one deploy key per repository.

The user creates the repository (GitHub or any SSH git host) and gives its SSH address; Agent Manager makes an
ed25519 key for that repository only (private key in our data folder, 0600, never logged, never in a repository),
shows the public key to add as a deploy key (« Allow write access » so agents can push their branch), checks it
(`git ls-remote` with that key only) and gives it to the sessions working on that repository (GIT_SSH_COMMAND).
A deploy key opens one repository: a leaked key never opens the others."""
from __future__ import annotations

import os
import re
import secrets
import shlex
import shutil
import sqlite3
import subprocess
import time
from contextlib import closing

SSH_URL = re.compile(r"^(?:ssh://)?(?:[\w.-]+@)?([\w.-]+)[:/]([\w.-]+(?:/[\w.-]+)*)/?$")
SCHEMA = """
CREATE TABLE IF NOT EXISTS repos (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    url TEXT NOT NULL UNIQUE,
    local_path TEXT NOT NULL DEFAULT '',
    fingerprint TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'waiting',
    message TEXT NOT NULL DEFAULT '',
    created REAL NOT NULL,
    checked_at REAL NOT NULL DEFAULT 0,
    last_used REAL NOT NULL DEFAULT 0
);
"""


def parse_url(url: str) -> tuple[str, str]:
    """(host, owner/repo) of an SSH git address; file:// is accepted only for tests (AGMGD_ALLOW_FILE_REPOS=1)."""
    url = url.strip()
    if url.startswith("file://") and os.environ.get("AGMGD_ALLOW_FILE_REPOS") == "1":
        return "file", url[7:].rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    if url.startswith(("http://", "https://")):
        raise ValueError("use the SSH address (git@github.com:owner/repo.git), not https: deploy keys work over SSH")
    m = SSH_URL.match(url)
    if not m or "/" not in m.group(2) and m.group(1) in ("github.com", "gitlab.com", "bitbucket.org"):
        raise ValueError("an SSH address like git@github.com:owner/repo.git")
    return m.group(1), m.group(2).removesuffix(".git")


class Repos:
    def __init__(self, db_path: str, home: str):
        self.db_path = db_path
        self.home = home
        self.keys = os.path.join(home, "keys")
        with closing(self._db()) as db, db:
            db.executescript(SCHEMA)

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    # ---------------------------------------------------------------- keys
    def key_path(self, rid: str) -> str:
        return os.path.join(self.keys, rid, "id_ed25519")

    def _make_key(self, rid: str, name: str) -> str:
        folder = os.path.dirname(self.key_path(rid))
        shutil.rmtree(folder, ignore_errors=True)
        os.makedirs(folder, mode=0o700)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"agent-manager-gd:{name}",
                        "-f", self.key_path(rid)], check=True, capture_output=True, timeout=30)
        os.chmod(self.key_path(rid), 0o600)
        out = subprocess.run(["ssh-keygen", "-lf", self.key_path(rid) + ".pub"], capture_output=True, text=True, timeout=10)
        return out.stdout.split()[1] if out.stdout.split() else ""

    def public_key(self, rid: str) -> str:
        with open(self.key_path(rid) + ".pub", encoding="utf-8") as f:
            return f.read().strip()

    def ssh_command(self, rid: str) -> str:
        """For GIT_SSH_COMMAND: this repository's key only, its own known_hosts (host keys accepted on first use)."""
        known = os.path.join(self.keys, "known_hosts")
        return " ".join(shlex.quote(x) for x in ["ssh", "-i", self.key_path(rid), "-o", "IdentitiesOnly=yes",
                                                 "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={known}",
                                                 "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"])

    def env(self, rid: str) -> dict:
        return {"GIT_SSH_COMMAND": self.ssh_command(rid)}

    # ---------------------------------------------------------------- records
    def add(self, url: str, local_path: str = "", name: str = "") -> dict:
        host, path = parse_url(url)
        rid = secrets.token_hex(4)
        name = (name or path.rsplit("/", 1)[-1]).strip()[:60]
        fp = self._make_key(rid, name)
        try:
            with closing(self._db()) as db, db:
                db.execute("INSERT INTO repos (id, name, url, local_path, fingerprint, created) VALUES (?, ?, ?, ?, ?, ?)",
                           (rid, name, url.strip(), os.path.expanduser(local_path.strip()), fp, time.time()))
        except sqlite3.IntegrityError:
            shutil.rmtree(os.path.dirname(self.key_path(rid)), ignore_errors=True)
            raise ValueError("this repository is already connected")
        return self.get(rid)

    def get(self, rid: str) -> dict:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM repos WHERE id = ?", (rid,)).fetchone()
        if not r:
            raise KeyError(rid)
        return self.describe(dict(r))

    def all(self) -> list[dict]:
        with closing(self._db()) as db:
            return [self.describe(dict(r)) for r in db.execute("SELECT * FROM repos ORDER BY name")]

    def describe(self, r: dict) -> dict:
        try:
            host, path = parse_url(r["url"])
        except ValueError:
            host, path = "", ""
        r["host"] = host
        r["deploy_keys_page"] = f"https://github.com/{path}/settings/keys/new" if host == "github.com" else ""
        r["public_key"] = self.public_key(r["id"]) if os.path.exists(self.key_path(r["id"]) + ".pub") else ""
        r["cloned"] = bool(r["local_path"]) and os.path.isdir(os.path.join(r["local_path"], ".git"))
        return r

    def _set(self, rid: str, **f) -> None:
        sets = ", ".join(f"{k} = ?" for k in f)
        with closing(self._db()) as db, db:
            db.execute(f"UPDATE repos SET {sets} WHERE id = ?", (*f.values(), rid))

    def check(self, rid: str) -> dict:
        """Can this key reach the repository? (read access; write access is shown by the first push)."""
        r = self.get(rid)
        out = subprocess.run(["git", "ls-remote", "--heads", r["url"]], capture_output=True, text=True, timeout=45,
                             env={**os.environ, **self.env(rid)})
        if out.returncode == 0:
            self._set(rid, status="connected", message="", checked_at=time.time())
        else:
            err = out.stderr.strip()
            hint = ("the key is not on the repository yet: add it as a deploy key, then Check again"
                    if "Permission denied" in err or "publickey" in err or "not found" in err.lower() else err[-300:])
            self._set(rid, status="failed", message=hint, checked_at=time.time())
        return self.get(rid)

    def rotate(self, rid: str) -> dict:
        r = self.get(rid)
        fp = self._make_key(rid, r["name"])
        self._set(rid, fingerprint=fp, status="waiting",
                  message=f"new key: add it on the repository and delete the old one ({r['fingerprint']})")
        return self.get(rid)

    def disconnect(self, rid: str) -> dict:
        r = self.get(rid)
        shutil.rmtree(os.path.dirname(self.key_path(rid)), ignore_errors=True)
        with closing(self._db()) as db, db:
            db.execute("DELETE FROM repos WHERE id = ?", (rid,))
        return {"disconnected": rid, "reminder": f"delete the deploy key {r['fingerprint']} on the repository too"}

    def ensure_clone(self, rid: str) -> str:
        """The repository's local folder, cloned with its key when it is not there yet."""
        r = self.get(rid)
        path = r["local_path"] or os.path.join(self.home, "repos", r["name"])
        if not os.path.isdir(os.path.join(path, ".git")):
            if os.path.exists(path) and os.listdir(path):
                raise ValueError(f"{path} exists and is not a git repository")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            out = subprocess.run(["git", "clone", r["url"], path], capture_output=True, text=True, timeout=600,
                                 env={**os.environ, **self.env(rid)})
            if out.returncode != 0:
                raise ValueError("clone failed: " + out.stderr.strip()[-300:])
            if not r["local_path"]:
                self._set(rid, local_path=path)
        self._set(rid, last_used=time.time())
        return path
