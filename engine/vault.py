"""The secrets vault (Loop 39): named secrets the owner keeps for their projects (an ElevenLabs key, a GitHub token,
a dotenvx private key), encrypted like the API keys, never shown again, never logged.

Owner, 2026-11-12: a key given to an agent through dotenvx « est enregistrée dans le WSL… accessible à travers WSL
pour tous les agents techniquement », and an agent « doit être en mesure de rouler GH… mais pas de voir la clé ».

- A secret has a name in the form of an environment variable (ELEVENLABS_API_KEY): that is how a session gets it.
- Its value is encrypted with Windows DPAPI where Windows is there (engine/keys.py does the same for the API keys);
  on a Linux computer without Windows it is only protected by the file's permissions (0600), and the page says so.
- The API never returns a value: only names, notes, dates, and who received it when (the journal).
- Values are read only to hand them to a session that was given them (engine/sessions.py, Loop 39 V2).
"""
from __future__ import annotations

import base64
import json
import os
import re
import threading
import time

from .keys import _DEC, _ENC, Keys

NAME = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")
# names a secret may not take: they would change how a program runs, or what Agent Manager tells a session
RESERVED = {"PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "PWD", "TMUX", "TMUX_PANE", "LD_PRELOAD", "LD_LIBRARY_PATH",
            "PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "GIT_SSH_COMMAND", "SSH_AUTH_SOCK", "DISPLAY", "BASH_ENV", "ENV"}
MAX_VALUE = 16000
JOURNAL_KEEP = 2000


class Vault:
    def __init__(self, home: str, keys: Keys | None = None):
        self.keys = keys or Keys(home)
        self.folder = os.path.join(home, "keys", "secrets")
        os.makedirs(self.folder, mode=0o700, exist_ok=True)
        self.journal_path = os.path.join(self.folder, "journal.jsonl")
        self.lock = threading.Lock()

    # ---------------------------------------------------------------- names
    @staticmethod
    def check_name(name: str) -> str:
        name = (name or "").strip()
        if not NAME.match(name):
            raise ValueError("a secret's name is in capitals, digits and _ (like ELEVENLABS_API_KEY), 2 to 64 long")
        if name in RESERVED or name.startswith("AGMGD_"):
            raise ValueError(f"{name} is not a name a secret may take: it would change how programs run")
        return name

    def _path(self, name: str) -> str:
        return os.path.join(self.folder, self.check_name(name) + ".json")

    def _read(self, name: str) -> dict | None:
        try:
            with open(self._path(name), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def _write(self, name: str, rec: dict) -> None:
        path = self._path(name)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f)
        os.replace(tmp, path)

    # ---------------------------------------------------------------- keeping
    def set(self, name: str, value: str, note: str = "") -> dict:
        """Adds a secret, or replaces its value (its note and its first date stay unless given)."""
        name = self.check_name(name)
        value = (value or "").strip("\r\n")
        if not value.strip():
            raise ValueError("paste the secret's value")
        if len(value) > MAX_VALUE or "\x00" in value:
            raise ValueError("this value is too long, or not text")
        note = " ".join((note or "").split())[:200]
        old = self._read(name) or {}
        if self.keys.dpapi:
            rec = {"protection": "dpapi", "blob": self.keys._ps(_ENC, base64.b64encode(value.encode()).decode())}
        else:
            rec = {"protection": "file", "value": value}
        now = time.time()
        rec.update(added_at=old.get("added_at", now), changed_at=now, note=note or old.get("note", ""))
        with self.lock:
            self._write(name, rec)
        self.log(name, "changed" if old else "added")
        return self.describe(name)

    def note(self, name: str, note: str) -> dict:
        rec = self._read(name)
        if rec is None:
            raise KeyError(name)
        rec["note"] = " ".join((note or "").split())[:200]
        with self.lock:
            self._write(name, rec)
        return self.describe(name)

    def delete(self, name: str) -> dict:
        name = self.check_name(name)
        try:
            os.remove(self._path(name))
            self.log(name, "deleted")
        except FileNotFoundError:
            pass
        return {"name": name, "deleted": True}

    def get(self, name: str) -> str:
        """The plain value, to hand to a session that was given it ('' when there is none). Never returned by the
        API, never logged."""
        rec = self._read(name)
        if not rec:
            return ""
        if rec.get("protection") == "dpapi":
            return base64.b64decode(self.keys._ps(_DEC, rec["blob"])).decode("utf-8")
        return str(rec.get("value", ""))

    def names(self) -> list[str]:
        out = []
        for f in os.listdir(self.folder):
            if f.endswith(".json") and NAME.match(f[:-5]):
                out.append(f[:-5])
        return sorted(out)

    def exists(self, name: str) -> bool:
        try:
            return os.path.exists(self._path(name))
        except ValueError:
            return False

    # ---------------------------------------------------------------- the journal: who received what, when
    def log(self, name: str, event: str, sid: str = "", session: str = "") -> None:
        """One line per event (added, changed, deleted, given): never a value."""
        line = json.dumps({"ts": time.time(), "name": name, "event": event, "sid": sid, "session": session})
        with self.lock:
            fd = os.open(self.journal_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a") as f:
                f.write(line + "\n")
            try:
                if os.path.getsize(self.journal_path) > JOURNAL_KEEP * 200:
                    with open(self.journal_path, encoding="utf-8") as f:
                        keep = f.readlines()[-JOURNAL_KEEP:]
                    tmp = self.journal_path + ".tmp"
                    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                    with os.fdopen(fd, "w") as f:
                        f.writelines(keep)
                    os.replace(tmp, self.journal_path)
            except OSError:
                pass

    def journal(self, name: str = "", limit: int = 200) -> list[dict]:
        try:
            with open(self.journal_path, encoding="utf-8") as f:
                lines = f.readlines()
        except OSError:
            return []
        out = []
        for line in reversed(lines):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if name and e.get("name") != name:
                continue
            out.append(e)
            if len(out) >= limit:
                break
        return out

    # ---------------------------------------------------------------- what the page shows
    def describe(self, name: str, journal: list[dict] | None = None) -> dict:
        rec = self._read(name) or {}
        events = [e for e in (journal if journal is not None else self.journal(name)) if e.get("name") == name]
        given = [e for e in events if e.get("event") == "given"]
        return {"name": name, "note": rec.get("note", ""), "protection": rec.get("protection", ""),
                "added_at": rec.get("added_at", 0), "changed_at": rec.get("changed_at", 0),
                "last_given": given[0]["ts"] if given else 0, "given_count": len(given),
                "given_to": sorted({e.get("session") or e.get("sid") for e in given if e.get("sid")})}

    def all(self) -> dict:
        journal = self.journal(limit=JOURNAL_KEEP)
        return {"secrets": [self.describe(n, journal) for n in self.names()],
                "protection": "Windows DPAPI (encrypted for your Windows user)" if self.keys.dpapi
                else "file permissions only (0600): not encrypted on this computer",
                "journal": journal[:50]}
