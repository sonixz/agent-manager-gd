"""The private tmux server (tmux -L <socket>): sessions survive the app, never mix with the user's own tmux."""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass

PREFIX = "am_"
CONF = os.path.join(os.path.dirname(__file__), "tmux.conf")


@dataclass
class TmuxSession:
    name: str
    created: int
    attached: int
    pane_dead: bool
    pane_pid: int
    pane_command: str
    width: int
    height: int
    activity: float = 0.0


class Tmux:
    def __init__(self, socket: str = "agmgd", binary: str | None = None, tmpdir: str | None = None):
        self.socket = socket
        self.binary = binary or shutil.which("tmux") or "tmux"
        self.env = dict(os.environ)
        if tmpdir:  # tests: an isolated server folder
            self.env["TMUX_TMPDIR"] = tmpdir
        self.env.pop("TMUX", None)

    def run(self, *args: str, check: bool = True) -> str:
        out = subprocess.run([self.binary, "-L", self.socket, "-f", CONF, *args], capture_output=True, text=True,
                             encoding="utf-8", errors="replace", env=self.env, timeout=10)
        if check and out.returncode != 0:
            raise RuntimeError(f"tmux {args[0]}: {out.stderr.strip() or out.returncode}")
        return out.stdout

    def available(self) -> bool:
        return shutil.which(self.binary) is not None or os.path.exists(self.binary)

    def version(self) -> str:
        return subprocess.run([self.binary, "-V"], capture_output=True, text=True).stdout.strip()

    def new_session(self, name: str, cwd: str, command: list[str], env: dict[str, str] | None = None,
                    width: int = 160, height: int = 48) -> None:
        args = ["new-session", "-d", "-s", name, "-c", cwd, "-x", str(width), "-y", str(height)]
        for k, v in (env or {}).items():
            args += ["-e", f"{k}={v}"]
        if command:
            args.append(" ".join(_shell_quote(c) for c in command))
        self.run(*args)
        # a program's « copy to clipboard » (OSC 52) reaches Agent Manager's terminal through tmux
        self.run("set-option", "-s", "set-clipboard", "on")
        self.run("set-option", "-s", "terminal-features[90]", "*:clipboard")
        # keep the pane when the program ends, so a finished agent's last screen stays readable (and revivable)
        self.run("set-option", "-t", name, "remain-on-exit", "on")

    def sessions(self) -> dict[str, TmuxSession]:
        fmt = ("#{session_name}\t#{session_created}\t#{session_attached}\t#{pane_dead}\t#{pane_pid}\t"
               "#{pane_current_command}\t#{window_width}\t#{window_height}\t#{window_activity}")
        try:
            out = self.run("list-panes", "-a", "-F", fmt, check=True)
        except RuntimeError:  # no server yet
            return {}
        found: dict[str, TmuxSession] = {}
        for line in out.splitlines():
            p = line.split("\t")
            if len(p) < 8 or not p[0].startswith(PREFIX) or p[0] in found:
                continue
            found[p[0]] = TmuxSession(p[0], int(p[1] or 0), int(p[2] or 0), p[3] == "1", int(p[4] or 0), p[5],
                                      int(p[6] or 0), int(p[7] or 0), float(p[8] or 0) if len(p) > 8 else 0.0)
        return found

    def capture(self, name: str, lines: int = 40) -> str:
        return self.run("capture-pane", "-p", "-J", "-t", name, "-S", f"-{lines}")

    def send_text(self, name: str, text: str, enter: bool = True) -> None:
        self.run("send-keys", "-t", name, "-l", text)
        if enter:
            self.run("send-keys", "-t", name, "Enter")

    def kill(self, name: str) -> None:
        self.run("kill-session", "-t", name, check=False)

    def respawn(self, name: str, cwd: str, command: list[str]) -> None:
        args = ["respawn-pane", "-k", "-t", name, "-c", cwd]
        if command:
            args.append(" ".join(_shell_quote(c) for c in command))
        self.run(*args)

    def kill_server(self) -> None:
        self.run("kill-server", check=False)


def _shell_quote(s: str) -> str:
    if s and all(c.isalnum() or c in "-_./=:@%+," for c in s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"
