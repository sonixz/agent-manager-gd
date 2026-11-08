"""Sessions: a record (store) plus a tmux session named am_<id>. tmux is the truth for what is alive."""
from __future__ import annotations

import json
import os
import re
import sys
import time
import uuid
import subprocess
import shutil

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


HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hook.py")
AGENTS_MCP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_agents.py")
SANDBOX_ATTACH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sandbox_attach.py")
CLAUDE_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop",
                 "SubagentStop", "PreCompact", "SessionEnd"]
SHELLS = {"bash", "zsh", "fish", "sh", "dash", "pwsh", "nu"}
APPROVAL_HINTS = re.compile(r"(allow|approve|run this command|would you like to|do you want to)", re.I)
ACTIVE_SECONDS = 2.5
CLAUDE_BUSY = re.compile(r"esc to interrupt", re.I)   # what Claude Code shows while it works
STALE_WORKING_SECONDS = 15

WRAPUP_PROMPT = (
    "Agent Manager GD is closing this session. Please write a short summary of it in Markdown to the file {path} "
    "with these sections: ## What was done, ## Decisions (and why), ## Files touched, ## What is left, "
    "## How to continue. Be concrete (names, paths, commands), at most about 300 words. "
    "{brain}Then answer only: summary written.")
BRAIN_HINT = ("If the second-brain MCP tools are available, also propose it with propose_item (title: "
              "\"Session summary · {name} · {date}\", the summary as its text) so the owner can approve it. ")
BRIEF_PROMPT = ("Context from earlier sessions on this project, kept by Agent Manager GD: read {path} (the latest "
                "session summary){brain}. Then say in two lines what you understood and wait for instructions.")


class Sessions:
    def __init__(self, store: Store, tmux: Tmux, home: str = "", brain=None):
        self.store = store
        self.tmux = tmux
        self.brain = brain  # engine.brain.Brain or None (tests, or the Brain switched off)
        self.home = home or os.path.dirname(os.path.dirname(store.path))
        from .repos import Repos
        from .keys import Keys
        self.repos = Repos(store.path, self.home)
        self.keys_store = Keys(self.home)
        from .sandboxes import Sandboxes
        self.sandboxes = Sandboxes(store.path, self.home, self.keys_store)

    # ---------------------------------------------------------------- launching
    @staticmethod
    def remote_name(rec: dict) -> str:
        """The name Remote Control shows in claude.ai/code: « Group · Session », or the session's name alone."""
        return (f"{rec['grp']} · {rec['name']}" if rec.get("grp") else rec["name"])[:80]

    def command_for(self, rec: dict, mode: str = "new", conversation: str = "") -> list[str]:
        """The tool's command with this session's hooks: options of this launch only, never the user's settings.
        mode: new (a fresh conversation), resume (its own conversation), fork (a copy of a conversation)."""
        hook = [sys.executable or "python3", HOOK]
        if rec["tool"] == "claude":
            cmd = " ".join(_q(c) for c in hook + ["claude"])
            settings = {"hooks": {e: [{"matcher": "", "hooks": [{"type": "command", "command": cmd, "timeout": 5}]}]
                                  for e in CLAUDE_EVENTS}}
            folder = os.path.join(self.home, "sessions", rec["id"])
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, "claude-settings.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(settings, f)
            base = ["claude", "--settings", path] + self._claude_mcp(rec)
            if rec.get("remote_control"):  # seen and driven from claude.ai/code or the Claude app, under this name
                base += ["--remote-control", self.remote_name(rec)]
            if mode == "resume" and conversation:
                return base + ["--resume", conversation]
            if mode == "fork" and conversation:
                return base + ["--resume", conversation, "--fork-session"]
            # a fresh conversation: we choose its id, so it is known (and kept) from the first second
            new_id = str(uuid.uuid4())
            self.store.touch_conversation(rec["id"], "claude", new_id)
            return base + ["--session-id", new_id]
        if rec["tool"] == "codex":
            notify = ["-c", "notify=" + json.dumps(hook + ["codex"])] + self._codex_mcp(rec)
            if mode == "resume":  # without a known id Codex shows its own picker
                return ["codex", "resume"] + notify + ([conversation] if conversation else [])
            if mode == "fork":
                return ["codex", "fork"] + notify + ([conversation] if conversation else [])
            return ["codex"] + notify
        return list(TOOLS[rec["tool"]]["command"])

    # ---------------------------------------------------------------- the Second Brain (Loop 6)
    def _servers(self, rec: dict) -> dict:
        """The MCP servers an agent session gets: Agent Manager itself (6C) and, when shared, the Second Brain."""
        out = {"agent-manager": {"command": sys.executable or "python3", "args": [AGENTS_MCP]}}
        spec = self._brain_spec(rec)
        if spec:
            out["second-brain"] = spec
        return out

    def _brain_spec(self, rec: dict) -> dict | None:
        cid = (self.store.get(rec["id"]) or {}).get("brain_client", "") if rec.get("id") else ""
        return self.brain.server_spec(cid) if (self.brain and cid) else None

    def _claude_mcp(self, rec: dict) -> list[str]:
        folder = os.path.join(self.home, "sessions", rec["id"])
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "mcp.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"mcpServers": {k: {"type": "stdio", **v} for k, v in self._servers(rec).items()}}, f)
        return ["--mcp-config", path]

    def _codex_mcp(self, rec: dict) -> list[str]:
        out = []
        for k, v in self._servers(rec).items():
            out += ["-c", f"mcp_servers.{k}.command=" + json.dumps(v["command"]),
                    "-c", f"mcp_servers.{k}.args=" + json.dumps(v["args"])]
        return out

    def _connect_brain(self, rec: dict) -> None:
        if self.brain and rec["tool"] in ("claude", "codex"):
            cid = self.brain.connect(rec["name"])
            if cid:
                self.store.update(rec["id"], brain_client=cid)

    port = 8790  # the engine's API port, for the agents' MCP server (set by __main__)

    def session_env(self, sid: str) -> dict:
        env = {"AGMGD_SESSION": sid, "AGMGD_HOME": self.home, "AGMGD_PORT": str(self.port)}
        rec = self.store.get(sid) or {}
        if rec.get("repo_id"):  # git in this session uses the repository's deploy key only
            try:
                env.update(self.repos.env(rec["repo_id"]))
            except KeyError:
                pass
        return env

    _branches: dict = {}

    def branch(self, cwd: str) -> str:
        """The folder's current git branch ('' outside a repository), cached for 15 seconds."""
        now = time.time()
        hit = self._branches.get(cwd)
        if hit and now - hit[0] < 15:
            return hit[1]
        import subprocess
        try:
            out = subprocess.run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True,
                                 text=True, timeout=3)
            name = out.stdout.strip() if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            name = ""
        self._branches[cwd] = (now, name)
        return name

    def hook_state(self, sid: str) -> dict:
        try:
            with open(os.path.join(self.home, "state", sid + ".json"), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    @staticmethod
    def tmux_name(sid: str) -> str:
        return PREFIX + sid

    def create(self, name: str, tool: str, cwd: str, grp: str = "", width: int = 160, height: int = 48,
               worktree: bool = False, brain: bool = True, parent: str = "", brief: bool = False,
               repo: str = "", host: str = "local", remote: bool = False) -> dict:
        if host == "sandbox":
            return self.create_sandbox_session(name, tool, grp, repo, brain)
        if tool not in TOOLS:
            raise ValueError(f"unknown tool: {tool}")
        if not NAME_OK.match(name or ""):
            raise ValueError("a name of 1 to 60 characters")
        if repo:  # a connected repository: its local folder (cloned with its key when needed)
            cwd = self.repos.ensure_clone(repo)
        cwd = os.path.expanduser(host_path((cwd or "~").strip()))
        if not os.path.isdir(cwd):
            raise ValueError(f"no such folder: {cwd}")
        wt, base = ("", "")
        if worktree:
            wt, base = self._add_worktree(cwd, name)
            cwd = wt
        if parent and not self.store.get(parent):
            raise ValueError("unknown parent session")
        from .review import head
        rec = self.store.add(name.strip(), tool, cwd, grp, worktree=wt, base_repo=base, parent=parent, start_commit=head(cwd),
                             repo_id=repo)
        if remote and tool == "claude":
            self.store.update(rec["id"], remote_control=1)
            rec = self.store.get(rec["id"])
        if brain:
            self._connect_brain(rec)
        cmd = self.command_for(rec)
        if brief and tool in ("claude", "codex"):
            last = self.store.summaries(cwd=cwd)
            if last:  # the first message: read the latest summary of this folder (a small prompt, owner-approved)
                hint = " and search the Second Brain for this project if you need more" if self.store.get(rec["id"]).get("brain_client") else ""
                cmd = cmd + [BRIEF_PROMPT.format(path=last[0]["path"], brain=hint)]
        try:
            self.tmux.new_session(self.tmux_name(rec["id"]), cwd, cmd,
                                  env=self.session_env(rec["id"]), width=width, height=height)
        except Exception:
            self.store.delete(rec["id"])
            raise
        return self.get(rec["id"])

    def describe(self, rec: dict, live: dict | None = None) -> dict:
        live = self.tmux.sessions() if live is None else live
        t = live.get(self.tmux_name(rec["id"]))
        state = "missing" if t is None else ("exited" if t.pane_dead else "running")
        sb_info = self.sandboxes.by_session(rec["id"]) if rec.get("cwd") == "/work" else None
        hs = self.hook_state(rec["id"])
        if hs.get("conversation"):
            self.store.touch_conversation(rec["id"], rec["tool"], hs["conversation"])
        activity, message = self.activity(rec, t, hs) if state == "running" else (state, "")
        if rec.get("archived"):
            state, activity = "archived", "archived"
        elif rec["id"] in self._wrapping and state == "running":
            activity, message = "wrapping", "writing its summary"
        return {**rec, "tool_label": TOOLS.get(rec["tool"], {}).get("label", rec["tool"]), "state": state,
                "activity": activity, "message": message, "conversation": hs.get("conversation", ""),
                "since": float(hs.get("time", 0) or (t.activity if t else 0) or rec["created"]),
                "last_conversation": self.last_conversation(rec["id"]),
                "brain": bool(rec.get("brain_client")),
                "remote_control": bool(rec.get("remote_control")),
                "repo_name": self._repo_name(rec.get("repo_id", "")),
                "host": "sandbox" if sb_info else "local",
                "sandbox": {k: sb_info[k] for k in ("id", "region", "finished", "destroyed", "machine")} if sb_info else None,
                "branch": self.branch(rec["cwd"]),
                "tmux": self.tmux_name(rec["id"]), "attached": bool(t and t.attached),
                "command": t.pane_command if t else ""}

    def _tail(self, rec: dict, lines: int = 15) -> str:
        try:
            return "\n".join(self.tmux.capture(self.tmux_name(rec["id"]), lines).splitlines()[-lines:])
        except Exception:
            return ""

    def activity(self, rec: dict, t, hs: dict) -> tuple[str, str]:
        """working | approval | waiting | done | idle, from the hooks first, the terminal second."""
        now = time.time()
        busy = bool(t and t.activity and now - t.activity < ACTIVE_SECONDS)
        if rec.get("cwd") == "/work" and self.sandboxes.by_session(rec["id"]):
            # no hooks in a sandbox: what the agent shows, not the screen's redraws
            if rec["tool"] == "shell":
                return ("working" if busy else "idle"), "in a cloud sandbox"
            tail = self._tail(rec) if t else ""
            if CLAUDE_BUSY.search(tail):
                return "working", "in a cloud sandbox"
            if APPROVAL_HINTS.search(tail):
                return "approval", "in a cloud sandbox"
            return "idle", "in a cloud sandbox"
        if rec["tool"] == "claude" and hs.get("state"):
            st = hs["state"]
            if st == "working" and t and not busy and now - max(t.activity or 0, hs.get("time", 0)) > STALE_WORKING_SECONDS \
                    and not CLAUDE_BUSY.search(self._tail(rec)):
                return "idle", "stopped (interrupted?)"  # e.g. Esc: Claude Code sends no Stop hook then
            return ("idle" if st == "ended" else st), str(hs.get("message", ""))
        if rec["tool"] == "codex":
            if busy and not (hs.get("state") == "done" and hs.get("time", 0) >= t.activity - 0.5):
                return "working", ""
            tail = "\n".join(self.tmux.capture(self.tmux_name(rec["id"]), 12).splitlines()[-12:]) if t else ""
            if APPROVAL_HINTS.search(tail):
                return "approval", ""
            if hs.get("state") == "done":
                return "done", str(hs.get("message", ""))
            return "idle", ""
        if t and t.pane_command and t.pane_command not in SHELLS:
            return "working", t.pane_command
        return ("working" if busy and rec["tool"] != "shell" else "idle"), ""

    # ---------------------------------------------------------------- the Brain keys Agent Manager made
    def brain_keys(self) -> list[dict]:
        """Each key with what uses it (a session, an archived one, a sandbox) or nothing: only unused keys are revocable."""
        used = {}
        for archived in (False, True):
            for r in self.store.all(archived=archived):
                if r.get("brain_client"):
                    used[r["brain_client"]] = ("archived session" if archived else "session") + " « %s »" % r["name"]
        for sb in self.sandboxes.all():
            if sb.get("brain_client") and not sb["destroyed"]:
                used.setdefault(sb["brain_client"], "sandbox %s" % sb["id"])
        return [{**{k: c.get(k) for k in ("id", "name", "created_at", "last_seen", "calls")},
                 "used_by": used.get(c["id"], "")} for c in self.brain.clients()]

    def revoke_brain_key(self, cid: str, confirmed: bool) -> dict:
        if not confirmed:
            raise ValueError("revoking needs the owner's confirmation")
        key = next((k for k in self.brain_keys() if k["id"] == cid), None)
        if key is None:
            raise ValueError("not a Brain key made by Agent Manager")
        if key["used_by"]:
            raise ValueError(f"this key is used by {key['used_by']}: remove that session or sandbox instead")
        if not self.brain.revoke(cid):
            raise ValueError("the Second Brain did not revoke it")
        return {"revoked": cid}

    _last_enforce = 0.0

    def enforce_caps(self) -> None:
        """At most every minute: the owner's optional sandbox caps (pause only), from the terminals' idle time."""
        if time.time() - self._last_enforce < 60 or not self.sandboxes.all():
            return
        self._last_enforce = time.time()
        b = self.sandboxes.budget()
        if not (b["stop_idle_minutes"] or b["stop_over_budget"]):
            return
        live = self.tmux.sessions()
        idle = {}
        for sb in self.sandboxes.all():
            t = live.get(self.tmux_name(sb["session_id"]))
            if t and t.activity:
                idle[sb["id"]] = time.time() - t.activity
        try:
            self.sandboxes.enforce(idle)
        except Exception:
            pass

    def list(self) -> list[dict]:
        self.check_wrapups()
        self.enforce_caps()
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

    KEYS = {"Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab", "y", "n", "1", "2", "3"}

    def keys(self, sid: str, keys: list[str]) -> None:
        """Named keys only (approve with Enter, refuse with Escape…): never arbitrary tmux key strings."""
        if self.get(sid)["state"] != "running":
            raise ValueError("the session is not running")
        bad = [k for k in keys if k not in self.KEYS]
        if bad or not keys or len(keys) > 8:
            raise ValueError("keys must be among " + ", ".join(sorted(self.KEYS)))
        self.tmux.run("send-keys", "-t", self.tmux_name(sid), *keys)

    def restart(self, sid: str) -> dict:
        """Starts the tool again in the same session (fresh conversation); recreates the tmux session if it is gone."""
        d = self.get(sid)
        cmd = self.command_for(d)
        try:
            os.remove(os.path.join(self.home, "state", sid + ".json"))
        except OSError:
            pass
        if d["state"] == "missing":
            self.tmux.new_session(d["tmux"], d["cwd"], cmd, env=self.session_env(sid))
        else:
            self.tmux.respawn(d["tmux"], d["cwd"], cmd)
        return self.get(sid)

    def stop(self, sid: str) -> dict:
        self.tmux.kill(self.tmux_name(sid))
        return self.get(sid)

    def remove(self, sid: str) -> None:
        rec = self.store.get(sid) or {}
        if self.sandboxes.by_session(sid):
            raise ValueError("this session has a cloud sandbox: destroy it first in Sandboxes")
        if self.brain and rec.get("brain_client"):
            self.brain.revoke(rec["brain_client"])  # its key stops working at once
        self.tmux.kill(self.tmux_name(sid))
        self.store.delete(sid)
        shutil.rmtree(os.path.join(self.home, "sessions", sid), ignore_errors=True)
        try:
            os.remove(os.path.join(self.home, "state", sid + ".json"))
        except OSError:
            pass

    # ---------------------------------------------------------------- cloud sandboxes (Loop 13)
    def create_sandbox_session(self, name: str, tool: str, grp: str, repo: str, brain: bool) -> dict:
        if tool not in TOOLS:
            raise ValueError(f"unknown tool: {tool}")
        if not NAME_OK.match(name or ""):
            raise ValueError("a name of 1 to 60 characters")
        rec = self.store.add(name.strip(), tool, "/work", grp, repo_id=repo)
        try:
            sb = self.sandboxes.create(rec["id"], repo_id=repo)
        except Exception:
            self.store.delete(rec["id"])
            raise
        if brain and self.brain and tool in ("claude", "codex"):
            cid = self.brain.connect(rec["name"] + " ☁")
            if cid:
                self.store.update(rec["id"], brain_client=cid)
                self.sandboxes._set(sb["id"], brain_client=cid)
        self.tmux.new_session(self.tmux_name(rec["id"]), self.home, [sys.executable or "python3", SANDBOX_ATTACH, sb["id"]],
                              env=self.session_env(rec["id"]))
        return self.get(rec["id"])

    # ---------------------------------------------------------------- history, resume, fork (Loop 5)
    def _repo_name(self, rid: str) -> str:
        if not rid:
            return ""
        try:
            return self.repos.get(rid)["name"]
        except KeyError:
            return ""

    def repo_sessions(self, rid: str) -> list[dict]:
        return [{"id": r["id"], "name": r["name"], "archived": r["archived"], "created": r["created"]}
                for r in self.store.history() if r.get("repo_id") == rid]

    def last_conversation(self, sid: str) -> str:
        convs = self.store.conversations(sid)
        return convs[0]["conversation"] if convs else ""

    def _launch(self, d: dict, cmd: list[str]) -> None:
        try:
            os.remove(os.path.join(self.home, "state", d["id"] + ".json"))
        except OSError:
            pass
        if d["state"] in ("missing", "archived") or d["tmux"] not in self.tmux.sessions():
            self.tmux.new_session(d["tmux"], d["cwd"], cmd, env=self.session_env(d["id"]))
        else:
            self.tmux.respawn(d["tmux"], d["cwd"], cmd)

    def resume(self, sid: str, conversation: str = "") -> dict:
        """Starts the session again on its own conversation (the latest one unless told), so no context is lost."""
        d = self.get(sid)
        if d["tool"] == "shell":
            return self.restart(sid)
        conv = conversation or self.last_conversation(sid)
        if conversation and conversation not in [c["conversation"] for c in self.store.conversations(sid)]:
            raise ValueError("not a conversation of this session")
        if d.get("archived"):
            self.store.update(sid, archived=0, archived_at=0)
            d = self.get(sid)
        self._launch(d, self.command_for(d, "resume", conv))
        return self.get(sid)

    def fork(self, sid: str, name: str = "", conversation: str = "") -> dict:
        """A new session continuing a copy of this session's conversation (same tool, folder and group)."""
        d = self.get(sid)
        if d["tool"] == "shell":
            raise ValueError("a shell has no conversation to fork")
        conv = conversation or self.last_conversation(sid)
        if not conv and d["tool"] == "claude":
            raise ValueError("no conversation recorded yet for this session")
        rec = self.store.add((name or d["name"] + " (fork)").strip()[:60], d["tool"], d["cwd"], d["grp"], parent=sid)
        if d.get("brain_client"):
            self._connect_brain(rec)
        self.tmux.new_session(self.tmux_name(rec["id"]), rec["cwd"], self.command_for(rec, "fork", conv),
                              env=self.session_env(rec["id"]))
        return self.get(rec["id"])

    # ---------------------------------------------------------------- wrap up (Loop 7)
    _wrapping: dict = {}   # session id -> (start time, summary path, archive afterwards)

    def wrap_up(self, sid: str, archive: bool = True) -> dict:
        """Asks the agent to write its own summary (and propose it to the Second Brain with its own key); when it is
        done, the summary is kept with the session (History) and the session is archived."""
        d = self.get(sid)
        self._no_hidden_sandbox(sid)
        if d["tool"] == "shell":
            raise ValueError("a shell has no conversation to summarise")
        if d["state"] != "running":
            raise ValueError("start the session first (Resume), then wrap it up")
        folder = os.path.join(self.home, "sessions", sid)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, time.strftime("summary-%Y%m%d-%H%M%S.md"))
        brain = BRAIN_HINT.format(name=d["name"], date=time.strftime("%Y-%m-%d")) if d.get("brain") else ""
        self._wrapping[sid] = (time.time(), path, archive)
        self.tmux.send_text(self.tmux_name(sid), WRAPUP_PROMPT.format(path=path, brain=brain))
        return {**self.get(sid), "summary_path": path}

    def check_wrapups(self) -> list[str]:
        """Called regularly: a wrap-up is finished when the summary file exists and the agent is no longer working."""
        finished = []
        for sid, (start, path, archive) in list(self._wrapping.items()):
            rec = self.store.get(sid)
            if not rec:
                self._wrapping.pop(sid, None)
                continue
            hs = self.hook_state(sid)
            settled = hs.get("state") in ("done", "waiting", "idle") and float(hs.get("time", 0)) > start + 1
            if os.path.exists(path) and (settled or time.time() - start > 900):
                with open(path, encoding="utf-8", errors="replace") as f:
                    text = f.read().strip()[:20000]
                self.store.add_summary(sid, self.last_conversation(sid), rec["cwd"], path, text)
                self._wrapping.pop(sid, None)
                if archive:
                    self.archive(sid)
                finished.append(sid)
            elif time.time() - start > 1800:  # gave up: the session stays as it is
                self._wrapping.pop(sid, None)
        return finished

    def _no_hidden_sandbox(self, sid: str) -> None:
        """Loop 16: a sandbox always has its session in the list; archiving it would hide a running cost."""
        if self.sandboxes.by_session(sid):
            raise ValueError("this session has a cloud sandbox: destroy the sandbox first (it shows the work not pushed), "
                             "then archive or wrap up")

    def archive(self, sid: str) -> dict:
        """Out of the way but never forgotten: the record and every conversation id stay (History)."""
        self.get(sid)
        self._no_hidden_sandbox(sid)
        self.tmux.kill(self.tmux_name(sid))
        self.store.update(sid, archived=1, archived_at=time.time())
        return self.get(sid)

    def history(self, query: str = "") -> list[dict]:
        return [{**r, "tool_label": TOOLS.get(r["tool"], {}).get("label", r["tool"])} for r in self.store.history(query)]

    # ---------------------------------------------------------------- git worktrees (Loop 5C)
    @staticmethod
    def _git(cwd: str, *args: str, check: bool = True) -> str:
        out = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=30)
        if check and out.returncode != 0:
            raise ValueError("git " + args[0] + ": " + (out.stderr.strip() or out.stdout.strip())[:300])
        return out.stdout.strip()

    def _add_worktree(self, cwd: str, name: str) -> tuple[str, str]:
        root = self._git(cwd, "rev-parse", "--show-toplevel")
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40] or "session"
        base_path = f"{root}-worktrees/{slug}"
        path, n = base_path, 2
        while os.path.exists(path) or self._git(root, "rev-parse", "--verify", "--quiet", f"am/{os.path.basename(path)}", check=False):
            path, n = f"{base_path}-{n}", n + 1
        self._git(root, "worktree", "add", "-b", f"am/{os.path.basename(path)}", path)
        return path, root

    def worktree_status(self, sid: str) -> dict:
        d = self.get(sid)
        if not d.get("worktree"):
            return {"worktree": ""}
        branch = self._git(d["worktree"], "rev-parse", "--abbrev-ref", "HEAD")
        target = self._git(d["base_repo"], "rev-parse", "--abbrev-ref", "HEAD")
        dirty = self._git(d["worktree"], "status", "--porcelain")
        ahead = int(self._git(d["base_repo"], "rev-list", "--count", f"{target}..{branch}") or 0)
        return {"worktree": d["worktree"], "base_repo": d["base_repo"], "branch": branch, "target": target,
                "uncommitted": len([x for x in dirty.splitlines() if x.strip()]), "commits_ahead": ahead}

    def finish(self, sid: str, merge: bool, delete_branch: bool) -> dict:
        """Ends a worktree session: optionally merges its branch into the repository's current branch, then removes
        the worktree. Refused while changes are uncommitted; a merge that conflicts is undone."""
        st = self.worktree_status(sid)
        if not st["worktree"]:
            raise ValueError("this session has no worktree of its own")
        if st["uncommitted"]:
            raise ValueError(f"{st['uncommitted']} uncommitted change(s) in the worktree: commit or discard them first")
        merged = False
        if merge and st["commits_ahead"]:
            if self._git(st["base_repo"], "status", "--porcelain"):
                raise ValueError("the main checkout has uncommitted changes: merge refused")
            out = subprocess.run(["git", "-C", st["base_repo"], "merge", "--no-edit", st["branch"]], capture_output=True,
                                 text=True, timeout=60)
            if out.returncode != 0:
                subprocess.run(["git", "-C", st["base_repo"], "merge", "--abort"], capture_output=True, timeout=30)
                raise ValueError("the merge conflicts; nothing was changed: " + (out.stdout + out.stderr).strip()[:300])
            merged = True
        self.tmux.kill(self.tmux_name(sid))
        self._git(st["base_repo"], "worktree", "remove", st["worktree"])
        deleted = False
        if delete_branch:
            deleted = subprocess.run(["git", "-C", st["base_repo"], "branch", "-d", st["branch"]], capture_output=True,
                                     timeout=30).returncode == 0  # -d: never deletes unmerged work
        self.store.update(sid, archived=1, archived_at=time.time(), cwd=st["base_repo"], worktree="")
        return {"merged": merged, "branch_deleted": deleted, "branch": st["branch"], "target": st["target"]}

    # ---------------------------------------------------------------- diff review (Loop 8)
    def diff(self, sid: str, mode: str = "uncommitted") -> dict:
        from . import review
        d = self.get(sid)
        if mode not in ("uncommitted", "session", "branch"):
            raise ValueError("mode: uncommitted, session or branch")
        target = ""
        if mode == "branch":
            if not d.get("worktree"):
                raise ValueError("this session has no git branch of its own: use « uncommitted » or « since start »")
            target = self._git(d["base_repo"], "rev-parse", "--abbrev-ref", "HEAD")
        return {**review.diff(d["cwd"], mode, d.get("start_commit", ""), target), "comments": self.store.comments(sid)}

    def send_review(self, sid: str) -> dict:
        from . import review
        d = self.get(sid)
        if d["state"] != "running":
            raise ValueError("the session is not running: Resume it first")
        open_ = [c for c in self.store.comments(sid) if c["status"] == "open"]
        if not open_:
            raise ValueError("no open comment to send")
        self.tmux.send_text(self.tmux_name(sid), review.compose(open_))
        for c in open_:
            self.store.set_comment(c["id"], status="sent")
        return {"sent": len(open_)}

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


def _q(s: str) -> str:
    if s and all(c.isalnum() or c in "-_./=:@%+," for c in s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"
