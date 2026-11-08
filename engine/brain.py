"""The Second Brain connection: one MCP key per session, so every agent shares the Brain's memory and the Brain's
timeline shows which session proposed what. Nothing changes in the Brain: it already creates (POST /mcp/clients) and
revokes (DELETE /mcp/clients/<id>) keys and ships a stdio relay for tools started in WSL.

Where the Brain runs:
- Windows (the usual case, the engine in WSL): calls go through the Brain's own Windows Python (brain_call.py),
  which reads the app token from the Brain's files itself; agents reach the Brain through its relay.
- Linux: direct HTTP on 127.0.0.1 with the app token file; agents use the same relay with the Brain's Python.
Settings (environment): AGMGD_BRAIN=off disables it; AGMGD_BRAIN_HOME, AGMGD_BRAIN_REPO override the detection.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import urllib.error
import urllib.request

LEVEL = "propose_items"   # read and search, propose new items: proposals wait for the owner's approval in the Brain
HERE = os.path.dirname(os.path.abspath(__file__))


def _wslpath(flag: str, path: str) -> str:
    out = subprocess.run(["wslpath", flag, path], capture_output=True, text=True, timeout=5)
    return out.stdout.strip() if out.returncode == 0 else ""


class Brain:
    def __init__(self, home: str = "", repo: str = ""):
        self.enabled = os.environ.get("AGMGD_BRAIN", "auto").lower() not in ("off", "0", "no", "false")
        self.home = home or os.environ.get("AGMGD_BRAIN_HOME", "") or self._find_home()
        self.windows = self.home.startswith("/mnt/")
        self.repo = repo or os.environ.get("AGMGD_BRAIN_REPO", "") or self._find_repo()
        self.python = self._find_python()

    # ---------------------------------------------------------------- discovery
    @staticmethod
    def _find_home() -> str:
        if shutil.which("cmd.exe"):  # WSL: the Windows user's %LOCALAPPDATA%
            try:
                out = subprocess.run(["cmd.exe", "/c", "echo %LOCALAPPDATA%"], capture_output=True, text=True,
                                     timeout=10, cwd="/mnt/c")
                local = out.stdout.strip().splitlines()[-1].strip() if out.stdout.strip() else ""
                if local and "%" not in local:
                    p = os.path.join(_wslpath("-u", local), "SecondBrainGD")
                    if os.path.isdir(p):
                        return p
            except (OSError, subprocess.SubprocessError, IndexError):
                pass
        p = os.path.expanduser("~/.local/share/SecondBrainGD")
        return p if os.path.isdir(p) else ""

    def _find_repo(self) -> str:
        """The Brain's repository (for its relay), from its install log: the last requirements file it installed."""
        log = os.path.join(self.home, "logs", "bootstrap.log") if self.home else ""
        try:
            with open(log, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            return ""
        found = re.findall(r"([A-Za-z]:(?:\\\\|\\)[^\"'\s]*?|/[^\"'\s]*?)(?:\\\\|\\|/)engine(?:\\\\|\\|/)requirements\.lock", text)
        return found[-1].replace("\\\\", "\\") if found else ""

    def _find_python(self) -> str:
        try:
            with open(os.path.join(self.home, "install_state.json"), encoding="utf-8") as f:
                py = str(json.load(f).get("venv_python", ""))
        except (OSError, ValueError):
            return ""
        return _wslpath("-u", py) if self.windows and re.match(r"^[A-Za-z]:", py) else py

    def relay_path(self) -> str:
        if not self.repo:
            return ""
        sep = "\\" if re.match(r"^[A-Za-z]:", self.repo) else "/"
        return self.repo + sep + sep.join(["engine", "mcp", "relay.py"])

    # ---------------------------------------------------------------- calls
    def call(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        data = json.dumps(body).encode() if body is not None else b""
        if self.windows:
            win_home = _wslpath("-w", self.home)
            helper = _wslpath("-w", os.path.join(HERE, "brain_call.py"))
            try:
                out = subprocess.run([self.python, helper, win_home, method, path], input=data, capture_output=True,
                                     timeout=40, cwd="/mnt/c")
                res = json.loads(out.stdout.decode("utf-8", "replace") or "{}")
                return int(res.get("status", 0)), res.get("body", {})
            except (OSError, subprocess.SubprocessError, ValueError) as e:
                return 0, {"error": str(e)[:200]}
        try:
            with open(os.path.join(self.home, "runtime", "api_token"), encoding="utf-8") as f:
                token = f.read().strip()
            with open(os.path.join(self.home, "runtime", "server.json"), encoding="utf-8") as f:
                port = int(json.load(f)["port"])
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data or None, method=method,
                                         headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, {k: v for k, v in json.loads(r.read() or b"{}").items() if k != "token"}
        except urllib.error.HTTPError as e:
            return e.code, {"error": e.read().decode("utf-8", "replace")[:200]}
        except (OSError, ValueError, KeyError) as e:
            return 0, {"error": str(e)[:200]}

    def mcp_forward(self, client_id: str, body: bytes, session: str = "") -> dict:
        """One MCP message for a client, sent to the Brain (the client's token is read on the Brain's side)."""
        if self.windows:
            out = subprocess.run([self.python, _wslpath("-w", os.path.join(HERE, "brain_call.py")), _wslpath("-w", self.home),
                                  "MCP", client_id] + ([session] if session else []), input=body, capture_output=True,
                                 timeout=150, cwd="/mnt/c")
            try:
                return json.loads(out.stdout.decode("utf-8", "replace") or "{}")
            except ValueError:
                return {"status": 502, "text": "", "session": ""}
        import importlib.util
        spec = importlib.util.spec_from_file_location("brain_call", os.path.join(HERE, "brain_call.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.mcp(self.home, client_id, body, session)

    def status(self) -> dict:
        if not self.enabled:
            return {"connected": False, "reason": "off (AGMGD_BRAIN=off)"}
        if not (self.home and self.python and self.relay_path()):
            return {"connected": False, "reason": "Second Brain not found on this computer"}
        code, body = self.call("GET", "/health")
        if code != 200:
            return {"connected": False, "reason": "Second Brain is not running"}
        return {"connected": True, "home": self.home, "relay": self.relay_path(), "version": body.get("version", "")}

    def connect(self, session_name: str) -> str:
        """A new MCP key for a session; returns the Brain's client id ('' when the Brain is not available)."""
        if not self.status()["connected"]:
            return ""
        code, body = self.call("POST", "/mcp/clients", {"name": ("Agent Manager · " + session_name)[:60], "level": LEVEL})
        return str(body.get("id", "")) if code == 200 else ""

    def revoke(self, client_id: str) -> bool:
        if not client_id:
            return False
        code, _ = self.call("DELETE", f"/mcp/clients/{client_id}")
        return code == 200

    def server_spec(self, client_id: str) -> dict:
        """How an agent starts the Brain's MCP server: the relay, run by the Brain's Python, with this session's key."""
        return {"command": self.python, "args": [self.relay_path(), "--client", client_id]}
