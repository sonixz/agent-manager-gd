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

    # ---------------------------------------------------------------- the local folder (Loop 16d)
    @staticmethod
    def norm(path: str) -> str:
        """A folder as the engine sees it: a Windows path (C:\\x, \\\\wsl.localhost\\…) becomes its WSL path."""
        from .sessions import host_path
        p = os.path.expanduser(host_path((path or "").strip()))
        return p.rstrip("/") if len(p) > 1 else p

    @staticmethod
    def _git(path: str, *args: str) -> tuple[int, str]:
        out = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True, timeout=30)
        return out.returncode, out.stdout.strip()

    def check_folder(self, path: str) -> str:
        """An existing git repository (its top folder), or an empty folder to clone into; anything else is refused."""
        if not os.path.isdir(path):
            raise ValueError(f"no such folder: {path}")
        if os.path.isdir(os.path.join(path, ".git")):
            return "git"
        if not os.listdir(path):
            return "empty"
        rc, top = self._git(path, "rev-parse", "--show-toplevel")
        hint = f" (its top folder is {top})" if rc == 0 and top else ""
        raise ValueError(f"{path} is not the top folder of a git repository{hint}: choose that folder, or an empty one")

    @staticmethod
    def _same_remote(a: str, b: str) -> bool:
        clean = lambda u: u.strip().lower().removesuffix("/").removesuffix(".git").replace("ssh://", "").replace("git@", "")  # noqa: E731
        return clean(a).replace(":", "/") == clean(b).replace(":", "/")

    def folder_state(self, r: dict) -> dict:
        """What the folder holds: a git repository? its origin (the same address, none, another one), commits."""
        path = r.get("local_path") or ""
        st = {"path": path, "exists": bool(path) and os.path.isdir(path), "git": False, "origin": "", "origin_state": "",
              "managed": bool(path) and os.path.abspath(path).startswith(os.path.join(self.home, "repos") + os.sep)}
        if st["exists"] and os.path.isdir(os.path.join(path, ".git")):
            st["git"] = True
            rc, origin = self._git(path, "remote", "get-url", "origin")
            st["origin"] = origin if rc == 0 else ""
            st["origin_state"] = "same" if st["origin"] and self._same_remote(st["origin"], r["url"]) else ("missing" if not st["origin"] else "other")
            rc, n = self._git(path, "rev-list", "--count", "--all")
            st["commits"] = int(n) if rc == 0 and n.isdigit() else 0
        return st

    def owner_of(self, folder: str) -> str:
        """The connected repository a folder belongs to (its folder, a subfolder, or one of its worktrees), or ""."""
        f = os.path.realpath(folder)
        rc, common = self._git(f, "rev-parse", "--path-format=absolute", "--git-common-dir") if os.path.isdir(f) else (1, "")
        top = os.path.dirname(os.path.realpath(common)) if rc == 0 and common else ""
        for r in self.all():
            lp = os.path.realpath(r["local_path"]) if r["local_path"] else ""
            if lp and (f == lp or f.startswith(lp + os.sep) or top == lp):
                return r["id"]
        return ""

    def set_folder(self, rid: str, path: str) -> dict:
        """Points the repository at another folder (the owner's own clone); the previous copy is left as it is."""
        r = self.get(rid)
        new = self.norm(path)
        self.check_folder(new)
        self._set(rid, local_path=new)
        out = self.get(rid)
        old = r["local_path"]
        if old and old != new and r["folder"]["managed"] and os.path.isdir(old):
            out["previous_copy"] = old  # Agent Manager's own clone: the app offers to remove it, after showing it
        return out

    def set_origin(self, rid: str) -> dict:
        """The owner's folder has no remote yet: add the repository's address as « origin » (only on their click)."""
        r = self.get(rid)
        st = r["folder"]
        if not st["git"]:
            raise ValueError("the folder is not a git repository")
        if st["origin_state"] == "other":
            raise ValueError(f"its origin is another repository ({st['origin']}): change it yourself if you mean to")
        if st["origin_state"] == "missing":
            rc, _ = self._git(st["path"], "remote", "add", "origin", r["url"])
            if rc != 0:
                raise ValueError("git could not add the origin")
        return self.get(rid)

    def inspect_copy(self, path: str) -> dict:
        """One of Agent Manager's own clones: is there anything in it that would be lost?"""
        path = self._managed_copy(path)
        rc, dirty = self._git(path, "status", "--porcelain")
        rc2, unpushed = self._git(path, "log", "--oneline", "--branches", "--not", "--remotes")
        lines = [x for x in (dirty.splitlines() + unpushed.splitlines()) if x.strip()]
        return {"path": path, "clean": rc == 0 and rc2 == 0 and not lines, "report": "\n".join(lines[:30])}

    def remove_copy(self, path: str, confirmed: bool) -> dict:
        if not confirmed:
            raise ValueError("removing a copy needs the owner's confirmation")
        path = self._managed_copy(path)
        if any(r["local_path"] == path for r in self.all()):
            raise ValueError("a connected repository still uses this folder")
        shutil.rmtree(path)
        return {"removed": path}

    def _managed_copy(self, path: str) -> str:
        path = os.path.abspath(self.norm(path))
        if not path.startswith(os.path.join(self.home, "repos") + os.sep) or not os.path.isdir(path):
            raise ValueError("only a copy Agent Manager made itself (in its repos folder) can be removed here")
        return path

    # ---------------------------------------------------------------- records
    def add(self, url: str, local_path: str = "", name: str = "") -> dict:
        host, path = parse_url(url)
        local = self.norm(local_path) if local_path.strip() else ""
        if local:
            self.check_folder(local)  # the owner's own clone (or an empty folder to clone into)
        rid = secrets.token_hex(4)
        name = (name or path.rsplit("/", 1)[-1]).strip()[:60]
        fp = self._make_key(rid, name)
        try:
            with closing(self._db()) as db, db:
                db.execute("INSERT INTO repos (id, name, url, local_path, fingerprint, created) VALUES (?, ?, ?, ?, ?, ?)",
                           (rid, name, url.strip(), local, fp, time.time()))
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
        r["folder"] = self.folder_state(r)
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
