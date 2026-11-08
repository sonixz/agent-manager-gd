"""Sessions: a record (store) plus a tmux session named am_<id>. tmux is the truth for what is alive."""
from __future__ import annotations

import os
import re

from .store import Store
from .tmux import CONF, PREFIX, Tmux

# What each tool runs. The user's own installed CLI, with their own login and config: never a token of ours.
TOOLS = {
    "claude": {"label": "Claude Code", "command": ["claude"]},
    "codex": {"label": "Codex", "command": ["codex"]},
    "shell": {"label": "Shell", "command": []},
}
NAME_OK = re.compile(r"^[^\x00-\x1f]{1,60}$")
WIN_PATH = re.compile(r"^([A-Za-z]):[\\/](.*)$")


def host_path(path: str) -> str:
    """A Windows path (C:\\git\\x) as WSL sees it (/mnt/c/git/x); other paths unchanged."""
    m = WIN_PATH.match(path or "")
    if m and os.path.isdir("/mnt/" + m.group(1).lower()):
        return "/mnt/" + m.group(1).lower() + "/" + m.group(2).replace("\\", "/")
    return path


class Sessions:
    def __init__(self, store: Store, tmux: Tmux):
        self.store = store
        self.tmux = tmux

    @staticmethod
    def tmux_name(sid: str) -> str:
        return PREFIX + sid

    def create(self, name: str, tool: str, cwd: str, grp: str = "", width: int = 160, height: int = 48) -> dict:
        if tool not in TOOLS:
            raise ValueError(f"unknown tool: {tool}")
        if not NAME_OK.match(name or ""):
            raise ValueError("a name of 1 to 60 characters")
        cwd = os.path.expanduser(host_path((cwd or "~").strip()))
        if not os.path.isdir(cwd):
            raise ValueError(f"no such folder: {cwd}")
        rec = self.store.add(name.strip(), tool, cwd, grp)
        try:
            self.tmux.new_session(self.tmux_name(rec["id"]), cwd, TOOLS[tool]["command"],
                                  env={"AGMGD_SESSION": rec["id"]}, width=width, height=height)
        except Exception:
            self.store.delete(rec["id"])
            raise
        return self.describe(rec)

    def describe(self, rec: dict, live: dict | None = None) -> dict:
        live = self.tmux.sessions() if live is None else live
        t = live.get(self.tmux_name(rec["id"]))
        state = "missing" if t is None else ("exited" if t.pane_dead else "running")
        return {**rec, "tool_label": TOOLS.get(rec["tool"], {}).get("label", rec["tool"]), "state": state,
                "tmux": self.tmux_name(rec["id"]), "attached": bool(t and t.attached),
                "command": t.pane_command if t else ""}

    def list(self) -> list[dict]:
        live = self.tmux.sessions()
        return [self.describe(r, live) for r in self.store.all()]

    def get(self, sid: str) -> dict:
        rec = self.store.get(sid)
        if not rec:
            raise KeyError(sid)
        return self.describe(rec)

    def attach_command(self, sid: str) -> list[str]:
        """What a terminal runs to show this session (the app prefixes wsl.exe on Windows)."""
        self.get(sid)
        return [self.tmux.binary, "-L", self.tmux.socket, "-f", CONF, "attach-session", "-t", self.tmux_name(sid)]

    def preview(self, sid: str, lines: int = 30) -> str:
        if self.get(sid)["state"] == "missing":
            return ""
        return self.tmux.capture(self.tmux_name(sid), lines)

    def send(self, sid: str, text: str, enter: bool = True) -> None:
        if self.get(sid)["state"] != "running":
            raise ValueError("the session is not running")
        self.tmux.send_text(self.tmux_name(sid), text, enter)

    def restart(self, sid: str) -> dict:
        """Starts the tool again in the same session (fresh conversation); recreates the tmux session if it is gone."""
        d = self.get(sid)
        cmd = TOOLS[d["tool"]]["command"]
        if d["state"] == "missing":
            self.tmux.new_session(d["tmux"], d["cwd"], cmd, env={"AGMGD_SESSION": sid})
        else:
            self.tmux.respawn(d["tmux"], d["cwd"], cmd)
        return self.get(sid)

    def stop(self, sid: str) -> dict:
        self.tmux.kill(self.tmux_name(sid))
        return self.get(sid)

    def remove(self, sid: str) -> None:
        self.tmux.kill(self.tmux_name(sid))
        self.store.delete(sid)

    def tree(self) -> dict:
        """Groups in order, each with its sessions in order; sessions without a group first."""
        items = self.list()
        groups = [{"name": "", "folded": False, "sessions": [s for s in items if not s["grp"]]}]
        for g in self.store.groups():
            groups.append({"name": g["name"], "folded": bool(g["folded"]),
                           "sessions": [s for s in items if s["grp"] == g["name"]]})
        return {"groups": groups}

    def move(self, sid: str, grp: str, index: int) -> None:
        self.get(sid)
        if grp and not NAME_OK.match(grp):
            raise ValueError("a group name of 1 to 60 characters")
        self.store.move(sid, grp.strip(), index)

    def rename(self, sid: str, name: str) -> dict:
        if not NAME_OK.match(name or ""):
            raise ValueError("a name of 1 to 60 characters")
        self.get(sid)
        self.store.update(sid, name=name.strip())
        return self.get(sid)
