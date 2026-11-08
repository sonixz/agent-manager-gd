"""API keys pasted by the owner in Agent Manager (« Keys » screen): encrypted at rest, never shown again, never logged.

On Windows (the engine in WSL) a key is encrypted with DPAPI, the Windows user's own protection, through PowerShell
(ConvertFrom-SecureString): only this Windows user on this computer can decrypt it. The value travels to PowerShell
on its standard input, base64-encoded, never on a command line. On a Linux computer without Windows the file is only
protected by its permissions (0600) — the screen says so. Values are read only when a feature needs them."""
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import time

SLOTS = {
    "openai": {"label": "OpenAI", "use": "voice dictation (transcription); Codex in sandboxes"},
    "fly": {"label": "Fly.io API token", "use": "cloud sandboxes"},
    "anthropic": {"label": "Anthropic API key", "use": "Claude Code in cloud sandboxes"},
}
_ENC = ("$v=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd().Trim()));"
        "ConvertFrom-SecureString (ConvertTo-SecureString $v -AsPlainText -Force)")
_DEC = ("$s=ConvertTo-SecureString ([Console]::In.ReadToEnd().Trim());"
        "$p=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s));"
        "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p))")


class Keys:
    def __init__(self, home: str):
        self.folder = os.path.join(home, "keys", "api")
        os.makedirs(self.folder, mode=0o700, exist_ok=True)
        self.dpapi = bool(shutil.which("powershell.exe")) and os.environ.get("AGMGD_KEYS_PLAIN") != "1"

    def _ps(self, script: str, data: str) -> str:
        out = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script], input=data,
                             capture_output=True, text=True, timeout=60, cwd="/mnt/c")
        if out.returncode != 0:
            raise RuntimeError("Windows could not protect the key (DPAPI)")
        return out.stdout.replace("\r", "").strip()

    def _path(self, name: str) -> str:
        if name not in SLOTS:
            raise ValueError("unknown key: " + name)
        return os.path.join(self.folder, name + ".json")

    def set(self, name: str, value: str) -> dict:
        value = value.strip()
        if not value or len(value) > 4000 or any(c in value for c in "\r\n"):
            raise ValueError("paste the key on one line")
        if self.dpapi:
            rec = {"protection": "dpapi", "blob": self._ps(_ENC, base64.b64encode(value.encode()).decode())}
        else:
            rec = {"protection": "file", "value": value}
        rec["set_at"] = time.time()
        path = self._path(name)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f)
        os.replace(tmp, path)
        return self.describe(name)

    def get(self, name: str) -> str:
        """The plain value, for the feature that needs it now ('' when not set). Never logged or returned by the API."""
        try:
            with open(self._path(name), encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError):
            return ""
        if rec.get("protection") == "dpapi":
            return base64.b64decode(self._ps(_DEC, rec["blob"])).decode("utf-8")
        return str(rec.get("value", ""))

    def delete(self, name: str) -> dict:
        try:
            os.remove(self._path(name))
        except FileNotFoundError:
            pass
        return self.describe(name)

    def describe(self, name: str) -> dict:
        info = {"name": name, **SLOTS[name], "set": False, "set_at": 0, "protection": ""}
        try:
            with open(self._path(name), encoding="utf-8") as f:
                rec = json.load(f)
            info.update(set=True, set_at=rec.get("set_at", 0), protection=rec.get("protection", ""))
        except (OSError, ValueError):
            pass
        return info

    def all(self) -> dict:
        return {"keys": [self.describe(n) for n in SLOTS],
                "protection": "Windows DPAPI (encrypted for your Windows user)" if self.dpapi
                else "file permissions only (0600): not encrypted on this computer"}
