"""Connected repositories (Loop 9): one key per repository.

The user creates the repository and gives its SSH address; Agent Manager makes a key for that repository only
(private key in our data folder, 0600, never logged, never in a repository), shows the public key to add on the
host, checks it (`git ls-remote` with that key only) and gives it to the sessions working on that repository
(GIT_SSH_COMMAND).

What the key opens depends on the host, and the app says which:
- GitHub: a deploy key opens one repository; a leaked key never opens the others. « Allow write access » lets
  agents push their branch.
- Azure DevOps has no key per repository: the key goes on the user's profile (User settings › SSH public keys) and
  opens everything that account reaches. It accepts RSA keys only (Microsoft's page, and its server's own answer,
  2026-11-12), so the key made for it is RSA 3072, as that page does; and its keys expire.
- Any other SSH git host: an ed25519 key, and what it opens is that host's business.

The list (`all`) runs no git command: what is slow to read (the folder's branch and state: up to 0.7 s per
repository on a Windows disk, measured) is read aside by `refresh` and served with its age.
"""
from __future__ import annotations

import os
import re
import secrets
import shlex
import shutil
import sqlite3
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from urllib.parse import unquote

SSH_URL = re.compile(r"^(?:ssh://)?(?:[\w.-]+@)?([\w.-]+)[:/]([\w.%-]+(?:/[\w.%-]+)*)/?$")
AZURE_HOSTS = ("ssh.dev.azure.com", "vs-ssh.visualstudio.com")
GITHUB_EXAMPLE = "git@github.com:owner/repo.git"
AZURE_EXAMPLE = "git@ssh.dev.azure.com:v3/organization/project/repository"
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
# Added later, to tables that exist already (see Repos.__init__): key_made, when the key in use was made (a
# rotation makes a new one); key_type, ed25519 or rsa.


def host_kind(host: str) -> str:
    """github, azure, or other: what decides the key's type, what it opens and the words shown."""
    h = host.lower()
    if h == "github.com":
        return "github"
    return "azure" if h in AZURE_HOSTS else "other"


def ssh_form(url: str) -> str:
    """The SSH address of a repository given by its web address, for the two hosts whose shape is known; "" otherwise."""
    m = re.match(r"^https?://(?:[^@/]+@)?github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", url)
    if m:
        return f"git@github.com:{m.group(1)}/{m.group(2)}.git"
    m = re.match(r"^https?://(?:[^@/]+@)?dev\.azure\.com/([\w.%-]+)/([\w.%-]+)/_git/([\w.%-]+)/?$", url)
    if m:
        return f"git@ssh.dev.azure.com:v3/{m.group(1)}/{m.group(2)}/{m.group(3)}"
    return ""


def parse_url(url: str) -> tuple[str, str]:
    """(host, path) of an SSH git address; file:// is accepted only for tests (AGMGD_ALLOW_FILE_REPOS=1)."""
    url = url.strip()
    if url.startswith("file://") and os.environ.get("AGMGD_ALLOW_FILE_REPOS") == "1":
        return "file", url[7:].rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    if url.startswith(("http://", "https://")):
        known = ssh_form(url)
        raise ValueError(f"use the SSH address, not https: {known or GITHUB_EXAMPLE}" + ("" if known else f" (Azure DevOps: {AZURE_EXAMPLE})")
                         + ". The key works over SSH")
    m = SSH_URL.match(url)
    if not m or "/" not in m.group(2) and m.group(1) in ("github.com", "gitlab.com", "bitbucket.org"):
        raise ValueError(f"an SSH address like {GITHUB_EXAMPLE}, or for Azure DevOps {AZURE_EXAMPLE}")
    host, path = m.group(1), m.group(2).removesuffix(".git")
    if host_kind(host) == "azure" and not re.match(r"^v3/[^/]+/[^/]+/[^/]+$", path):
        raise ValueError(f"an Azure DevOps SSH address like {AZURE_EXAMPLE} (Clone › SSH on the repository's page)")
    return host, path


class Repos:
    def __init__(self, db_path: str, home: str):
        self.db_path = db_path
        self.home = home
        self.keys = os.path.join(home, "keys")
        self._facts: dict[str, dict] = {}   # per repository: its folder as last read, when, and what is being read now
        self._lock = threading.Lock()
        self._pool: ThreadPoolExecutor | None = None
        with closing(self._db()) as db, db:
            db.executescript(SCHEMA)
            have = {row[1] for row in db.execute("PRAGMA table_info(repos)")}
            if "key_made" not in have:   # a table made before: the key in use was made when the repository was added
                db.execute("ALTER TABLE repos ADD COLUMN key_made REAL NOT NULL DEFAULT 0")
                db.execute("UPDATE repos SET key_made = created")
            if "key_type" not in have:
                db.execute("ALTER TABLE repos ADD COLUMN key_type TEXT NOT NULL DEFAULT 'ed25519'")

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    # ---------------------------------------------------------------- keys
    @staticmethod
    def key_type_for(host: str) -> str:
        return "rsa" if host_kind(host) == "azure" else "ed25519"

    def key_path(self, rid: str) -> str:
        folder = os.path.join(self.keys, rid)
        rsa = os.path.join(folder, "id_rsa")
        return rsa if os.path.exists(rsa) else os.path.join(folder, "id_ed25519")

    def _make_key(self, rid: str, name: str, kind: str = "ed25519") -> str:
        folder = os.path.join(self.keys, rid)
        shutil.rmtree(folder, ignore_errors=True)
        os.makedirs(folder, mode=0o700)
        path = os.path.join(folder, "id_rsa" if kind == "rsa" else "id_ed25519")
        how = ["-t", "rsa", "-b", "3072"] if kind == "rsa" else ["-t", "ed25519"]
        subprocess.run(["ssh-keygen", "-q", *how, "-N", "", "-C", f"agent-manager-gd:{name}", "-f", path],
                       check=True, capture_output=True, timeout=60)
        os.chmod(path, 0o600)
        out = subprocess.run(["ssh-keygen", "-lf", path + ".pub"], capture_output=True, text=True, timeout=10)
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

    def _folder_unread(self, r: dict) -> dict:
        """What can be said of the folder without running git: where it is, whether it is there."""
        path = r.get("local_path") or ""
        return {"path": path, "exists": bool(path) and os.path.isdir(path), "git": bool(path) and os.path.isdir(os.path.join(path, ".git")),
                "origin": "", "origin_state": "", "read": False,
                "managed": bool(path) and os.path.abspath(path).startswith(os.path.join(self.home, "repos") + os.sep)}

    def folder_state(self, r: dict) -> dict:
        """What the folder holds: a git repository? its origin (the same address, none, another one), its branch,
        how far it is from what it follows (from what is on the disk: nothing is fetched), how many files changed."""
        st = self._folder_unread(r)
        st["read"] = True
        path = st["path"]
        if st["git"]:
            rc, origin = self._git(path, "remote", "get-url", "origin")
            st["origin"] = origin if rc == 0 else ""
            st["origin_state"] = "same" if st["origin"] and self._same_remote(st["origin"], r["url"]) else ("missing" if not st["origin"] else "other")
            st.update(branch="", upstream="", ahead=0, behind=0, changed=0)
            rc, out = self._git(path, "status", "--porcelain=v2", "--branch")
            for line in out.splitlines() if rc == 0 else []:
                if line.startswith("# branch.head "):
                    head = line[14:].strip()
                    st["branch"] = "" if head == "(detached)" else head
                elif line.startswith("# branch.upstream "):
                    st["upstream"] = line[18:].strip()
                elif line.startswith("# branch.ab "):
                    ab = line[12:].split()
                    if len(ab) == 2:
                        st["ahead"], st["behind"] = abs(int(ab[0])), abs(int(ab[1]))
                elif line and not line.startswith("#"):
                    st["changed"] += 1
        with self._lock:
            f = self._facts.setdefault(r["id"], {"busy": set()})
            # two clocks: the wall's to show an age, the steady one to decide when to read again (the wall's may
            # be set back, in WSL after a sleep: an age would then look negative and nothing would be read)
            f["folder"], f["folder_at"], f["folder_read"] = st, time.time(), time.monotonic()
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
        name = (name or unquote(path.rsplit("/", 1)[-1])).strip()[:60]
        kind = self.key_type_for(host)
        fp = self._make_key(rid, name, kind)
        try:
            with closing(self._db()) as db, db:
                now = time.time()
                db.execute("INSERT INTO repos (id, name, url, local_path, fingerprint, created, key_made, key_type) "
                           "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (rid, name, url.strip(), local, fp, now, now, kind))
        except sqlite3.IntegrityError:
            shutil.rmtree(os.path.dirname(self.key_path(rid)), ignore_errors=True)
            raise ValueError("this repository is already connected")
        return self.get(rid)

    def get(self, rid: str) -> dict:
        """One repository, its folder read now."""
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM repos WHERE id = ?", (rid,)).fetchone()
        if not r:
            raise KeyError(rid)
        return self.describe(dict(r))

    def all(self) -> list[dict]:
        """Every repository, at once: no git command is run. The folder is as it was last read (see `refresh`)."""
        with closing(self._db()) as db:
            return [self.describe(dict(r), fresh=False) for r in db.execute("SELECT * FROM repos ORDER BY name")]

    def describe(self, r: dict, fresh: bool = True) -> dict:
        try:
            host, path = parse_url(r["url"])
        except ValueError:
            host, path = "", ""
        kind = host_kind(host)
        r["host"] = host
        r["host_kind"] = kind
        # what the key opens: one repository (a GitHub deploy key), everything the account reaches (Azure DevOps)
        r["key_scope"] = {"github": "repository", "azure": "account"}.get(kind, "unknown")
        r["key_page"] = ""
        if kind == "github":
            r["key_page"] = f"https://github.com/{path}/settings/keys/new"
        elif kind == "azure":   # the organization's page: from there, User settings › SSH public keys
            r["key_page"] = "https://dev.azure.com/" + path.split("/")[1]
        r["deploy_keys_page"] = r["key_page"] if kind == "github" else ""
        r["public_key"] = self.public_key(r["id"]) if os.path.exists(self.key_path(r["id"]) + ".pub") else ""
        r["cloned"] = bool(r["local_path"]) and os.path.isdir(os.path.join(r["local_path"], ".git"))
        if fresh:
            r["folder"] = self.folder_state(r)
        with self._lock:
            f = self._facts.setdefault(r["id"], {"busy": set()})
            if not fresh:
                kept = f.get("folder")
                # a folder that was changed since (another path) is not shown as the one read before
                r["folder"] = kept if kept and kept["path"] == (r.get("local_path") or "") else self._folder_unread(r)
            r["folder_at"] = float(f.get("folder_at", 0.0)) if r["folder"].get("read") else 0.0
            r["busy"] = sorted(f["busy"])
        return r

    # ---------------------------------------------------------------- what is slow, read aside
    def refresh(self, keys: bool = False, key_age: float = 600.0, folder_age: float = 30.0) -> dict:
        """Reads again, aside and four at a time, what is older than its age: each folder; and, when `keys` is asked
        for (the page was opened, or « Check all »), the keys that were checked once. A repository still waiting for
        its key is left alone: checking it would only turn « waiting » into « does not work ». Answers at once."""
        now = time.time()
        started = 0
        with closing(self._db()) as db:
            rows = [dict(r) for r in db.execute("SELECT id, status, checked_at, local_path FROM repos")]
        for r in rows:
            todo = []
            with self._lock:
                f = self._facts.setdefault(r["id"], {"busy": set()})
                moved = (f.get("folder") or {}).get("path") != (r["local_path"] or "")   # another folder since: read it now
                if "folder" not in f["busy"] and (moved or "folder_read" not in f or time.monotonic() - f["folder_read"] > folder_age):
                    todo.append("folder")
                if keys and "key" not in f["busy"] and r["status"] in ("connected", "failed") and now - float(r["checked_at"]) > key_age:
                    todo.append("key")
                f["busy"].update(todo)
            for what in todo:
                if self._pool is None:
                    self._pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="repos")
                self._pool.submit(self._refresh_one, r["id"], what)
                started += 1
        return {"started": started}

    def _refresh_one(self, rid: str, what: str) -> None:
        try:
            if what == "folder":
                self.get(rid)
            else:
                self._check_key(rid)
        except Exception:  # noqa: BLE001: a repository removed meanwhile, a folder gone: the next reading says so
            pass
        finally:
            with self._lock:
                self._facts.setdefault(rid, {"busy": set()})["busy"].discard(what)

    def _set(self, rid: str, **f) -> None:
        sets = ", ".join(f"{k} = ?" for k in f)
        with closing(self._db()) as db, db:
            db.execute(f"UPDATE repos SET {sets} WHERE id = ?", (*f.values(), rid))

    def check(self, rid: str) -> dict:
        """Can this key reach the repository? (read access; write access is shown by the first push)."""
        self._check_key(rid)
        return self.get(rid)

    @staticmethod
    def _hint(kind: str, err: str) -> str:
        """Why the key did not work, in words that say what to do, by host."""
        low = err.lower()
        if kind == "azure":
            if "expired" in low:
                return "this key has expired on Azure DevOps: Rotate the key, then add the new one to your profile"
            if "permission denied" in low or "publickey" in low or "public key authentication failed" in low:
                return ("the key is not on your Azure DevOps profile yet (User settings › SSH public keys › New Key), "
                        "or SSH is turned off for this organization: add it, then Check again")
            if "not found" in low or "does not exist" in low:
                return "Azure DevOps does not know this repository under this address, or this account cannot read it"
            return err[-300:]
        if "permission denied" in low or "publickey" in low or "not found" in low:
            return "the key is not on the repository yet: add it as a deploy key, then Check again"
        return err[-300:]

    def _check_key(self, rid: str) -> None:
        with closing(self._db()) as db:
            row = db.execute("SELECT url FROM repos WHERE id = ?", (rid,)).fetchone()
        if not row:
            raise KeyError(rid)
        url = row["url"]
        out = subprocess.run(["git", "ls-remote", "--heads", url], capture_output=True, text=True, timeout=45,
                             env={**os.environ, **self.env(rid)})
        if out.returncode == 0:
            self._set(rid, status="connected", message="", checked_at=time.time())
        else:
            try:
                kind = host_kind(parse_url(url)[0])
            except ValueError:
                kind = "other"
            self._set(rid, status="failed", message=self._hint(kind, out.stderr.strip()), checked_at=time.time())

    def rotate(self, rid: str) -> dict:
        r = self.get(rid)
        fp = self._make_key(rid, r["name"], self.key_type_for(r["host"]))
        where = "to your Azure DevOps profile" if r["host_kind"] == "azure" else "on the repository"
        self._set(rid, fingerprint=fp, status="waiting", key_made=time.time(), key_type=self.key_type_for(r["host"]),
                  message=f"new key: add it {where} and delete the old one ({r['fingerprint']})")
        return self.get(rid)

    def disconnect(self, rid: str) -> dict:
        r = self.get(rid)
        shutil.rmtree(os.path.dirname(self.key_path(rid)), ignore_errors=True)
        with closing(self._db()) as db, db:
            db.execute("DELETE FROM repos WHERE id = ?", (rid,))
        with self._lock:
            self._facts.pop(rid, None)
        if r["host_kind"] == "azure":
            return {"disconnected": rid, "reminder": f"delete the key {r['fingerprint']} from your Azure DevOps profile too (User settings › SSH public keys)"}
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
