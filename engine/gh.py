"""GitHub's own CLI under Repos (Loop 42; plan of 2026-11-12: an agent « doit être en mesure de rouler GH… mais pas
de voir la clé »).

What it does, with the owner's own `gh` (their login, their config), never reading its token:
- reads its state: installed, version, the account logged in, the token's scopes and where gh keeps it (the system's
  keyring, or a plain file every program of this user can read), from `gh auth status`, which masks the token;
- logging in and out happen in a terminal the owner sees (`gh auth login --web`, `gh auth logout`): the app types
  the command, the owner answers;
- adds a connected repository's deploy key in one click (`gh repo deploy-key add`, write access when asked), then
  reads back from GitHub's API that the key is there and whether it may push;
- creates a repository, private by default, and connects it. The visibility of an existing repository is never
  changed.
The token never passes through Agent Manager: gh runs as the owner's program and keeps it where it always does."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time

GH = os.environ.get("AGMGD_GH") or "gh"
LOGIN = "gh auth login --hostname github.com --web --git-protocol ssh"
LOGOUT = "gh auth logout --hostname github.com"
NAME_OK = re.compile(r"^[A-Za-z0-9._-]{1,100}$")


def parse_status(text: str) -> dict:
    """`gh auth status` in words: the account, where its token is kept, its scopes. The token line is never kept."""
    out = {"logged_in": False, "account": "", "storage": "", "scopes": [], "protocol": ""}
    for line in text.splitlines():
        s = line.strip().lstrip("✓✗X-* ").strip()
        m = re.match(r"Logged in to github\.com (?:account|as) (\S+) \(([^)]*)\)", s)
        if m:
            out["logged_in"] = True
            out["account"] = m.group(1)
            where = m.group(2)
            out["storage"] = "keyring" if where == "keyring" else ("environment" if where.upper() in ("GH_TOKEN", "GITHUB_TOKEN") else "file")
            continue
        m = re.match(r"Token scopes: (.*)$", s)
        if m:
            out["scopes"] = [x.strip(" '\"") for x in m.group(1).split(",") if x.strip(" '\"")]
            continue
        m = re.match(r"Git operations protocol: (\S+)", s)
        if m:
            out["protocol"] = m.group(1)
    return out


class GitHub:
    def __init__(self, gh: str = ""):
        self.gh = gh or GH
        self._state: tuple[float, dict] | None = None

    def _run(self, *args: str, timeout: int = 60, inp: str | None = None) -> tuple[int, str]:
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}  # the owner's own login
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        try:
            out = subprocess.run([self.gh, *args], capture_output=True, text=True, timeout=timeout, env=env, input=inp)
        except FileNotFoundError:
            return 127, "gh is not installed"
        except subprocess.TimeoutExpired:
            return 124, "gh did not answer in time"
        return out.returncode, (out.stdout + out.stderr).strip()

    def command(self, what: str) -> str:
        """The command typed in the owner's terminal to log in or out, with this gh (a stand-in in the tests)."""
        import shlex
        base = {"login": LOGIN, "logout": LOGOUT}.get(what)
        if not base:
            raise ValueError("login or logout")
        return (shlex.quote(self.gh) if self.gh != "gh" else "gh") + base[len("gh"):]

    def installed(self) -> bool:
        return bool(shutil.which(self.gh)) or os.path.isfile(self.gh)

    def status(self, fresh: bool = False) -> dict:
        """What the Repos page shows, kept a minute (gh asks GitHub)."""
        if self._state and not fresh and time.monotonic() - self._state[0] < 60:
            return self._state[1]
        st = {"installed": self.installed(), "version": "", "logged_in": False, "account": "", "storage": "",
              "scopes": [], "protocol": "", "login": LOGIN, "logout": LOGOUT, "can_add_keys": False, "can_create": False,
              "install": "sudo apt install gh  (or https://cli.github.com)", "note": ""}
        if st["installed"]:
            rc, out = self._run("--version", timeout=20)
            st["version"] = out.splitlines()[0].replace("gh version ", "").split(" ")[0] if rc == 0 and out else ""
            rc, out = self._run("auth", "status", "--hostname", "github.com", timeout=30)
            st.update(parse_status(out))
            scopes = set(st["scopes"])
            st["can_add_keys"] = st["logged_in"] and bool(scopes & {"repo", "admin:public_key"} or not scopes)
            st["can_create"] = st["logged_in"] and ("repo" in scopes or not scopes)
            if st["storage"] == "file":
                st["note"] = ("gh keeps its token in a plain file of your home folder: every program you run, agents "
                              "included, can read it. `gh auth login` on a system with a keyring keeps it there instead.")
        self._state = (time.monotonic(), st)
        return st

    def forget(self) -> None:
        self._state = None

    # ---------------------------------------------------------------- a connected repository's deploy key
    def add_deploy_key(self, owner_repo: str, pub_path: str, title: str, write: bool) -> dict:
        args = ["repo", "deploy-key", "add", pub_path, "--repo", owner_repo, "--title", title[:100]]
        if write:
            args.append("--allow-write")
        rc, out = self._run(*args, timeout=60)
        if rc != 0 and "already in use" not in out.lower() and "key is already" not in out.lower():
            raise ValueError("gh could not add the deploy key: " + out[-300:])
        return self.deploy_key(owner_repo, pub_path)

    def deploy_key(self, owner_repo: str, pub_path: str) -> dict:
        """Is our key among the repository's deploy keys, and may it push? Read from GitHub's API."""
        with open(pub_path, encoding="utf-8") as f:
            ours = " ".join(f.read().split()[:2])
        rc, out = self._run("api", f"repos/{owner_repo}/keys", timeout=60)
        if rc != 0:
            return {"found": None, "write": None, "error": out[-200:]}
        try:
            keys = json.loads(out)
        except ValueError:
            return {"found": None, "write": None, "error": "GitHub's answer could not be read"}
        mine = next((k for k in keys if " ".join(str(k.get("key", "")).split()[:2]) == ours), None)
        return {"found": bool(mine), "write": (not mine.get("read_only", True)) if mine else None,
                "title": mine.get("title", "") if mine else "", "error": ""}

    # ---------------------------------------------------------------- a new repository
    def create_repo(self, name: str, visibility: str = "private", description: str = "") -> dict:
        """A new repository under the account logged in: private unless the owner chose public. Its SSH address."""
        if not NAME_OK.match(name or ""):
            raise ValueError("a repository name of letters, digits, dots, dashes or underscores")
        if visibility not in ("private", "public"):
            raise ValueError("private or public")
        args = ["repo", "create", name, "--" + visibility]
        if description:
            args += ["--description", description[:300]]
        rc, out = self._run(*args, timeout=90)
        if rc != 0:
            raise ValueError("gh could not create the repository: " + out[-300:])
        m = re.search(r"https://github\.com/([\w.-]+/[\w.-]+)", out)
        owner_repo = m.group(1) if m else f"{self.status().get('account', '')}/{name}"
        return {"owner_repo": owner_repo, "url": f"git@github.com:{owner_repo}.git", "visibility": visibility}
