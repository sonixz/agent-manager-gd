"""Sessions: a record (store) plus a tmux session named am_<id>. tmux is the truth for what is alive."""
from __future__ import annotations

import json
import os
import re
import sys
import threading
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
WSL_UNC = re.compile(r"^[\\/]{2}wsl(?:\.localhost|\$)[\\/][^\\/]+(?:[\\/](.*))?$", re.I)  # \\wsl.localhost\Ubuntu\home\x


def host_path(path: str) -> str:
    """A Windows path (C:\\git\\x) as WSL sees it (/mnt/c/git/x); other paths unchanged."""
    m = WIN_PATH.match(path or "")
    if m and os.path.isdir("/mnt/" + m.group(1).lower()):
        return "/mnt/" + m.group(1).lower() + "/" + m.group(2).replace("\\", "/")
    u = WSL_UNC.match(path or "")  # a WSL folder picked from Windows: the same folder inside WSL
    if u:
        return "/" + (u.group(1) or "").replace("\\", "/").rstrip("/")
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

# Loop 25: the orchestrator. Sessions started by agents are capped: how many run at once under one root session, and
# how deep the tree goes (the orchestrator, its sessions, their helpers). Pushing and merging stay the owner's.
MAX_RUNNING_CHILDREN = 4
MAX_DEPTH = 2
GIT_PUSH_RULES = ["Bash(git push)", "Bash(git push *)"]
GIT_MERGE_RULES = ["Bash(git merge *)", "Bash(git rebase *)"]
OWNER_ONLY_GIT = GIT_PUSH_RULES + GIT_MERGE_RULES
ORCH_NOTE = (
    "You are the orchestrator of Agent Manager GD: you plan, delegate, follow up and check; you rarely code yourself. "
    "Your agent-manager MCP tools: list_repos, list_sessions, start_session (repo, worktree, level, model, document), "
    "send_to_session, wait_for_session, read_screen, ask_owner, finish_session. How you work: "
    "1. Orient: the Second Brain (project cards, open questions, recent decisions) if you have it, then list_repos and "
    "list_sessions. "
    "2. Before starting anything, propose a short plan to the owner: the tasks, the repository, the tool and model for "
    "each and why; then call ask_owner with it and stop until the owner's answer arrives in your terminal. "
    "3. Delegate each task to its own session with start_session, in a worktree (worktree: true) on the right "
    "repository, with a precise brief and how to check it. At most {max_children} of your sessions run at once; they "
    "cannot start sessions of their own beyond one level. "
    "4. Follow them with wait_for_session and read_screen; send corrections with send_to_session. Their permission "
    "requests go to the owner, not to you. "
    "5. When a task is done, check it (tests, the diff), then call finish_session: the owner reviews and merges. You and "
    "your sessions never push nor merge (it is refused). "
    "6. Report briefly to the owner, and record the plan, your routing choices and a journal in the Second Brain. "
    "Routing: call routing_rules first and follow the owner's rules to choose each task's tool and model; say why when "
    "you depart from them. After the owner's OK, write the plan with set_plan (each task: title, repo, tool, model, "
    "why) and keep it current with update_task (running with its session id, review, done). Check usage before "
    "starting sessions: when today's token budget is spent, sessions cannot be started.")

# Loop 24: permission levels, from the fewest rights to the most. Claude Code and Codex flags of this launch only.
LEVELS = ["ask", "edits", "auto", "full"]
# « config » (Loop 27): Agent Manager passes no level option, so the owner's own Claude Code or Codex settings decide;
# only for a session the owner starts (an agent's child gets a known level)
OWNER_LEVELS = LEVELS + ["config"]
LEVEL_FLAGS = {
    "claude": {"ask": ["--permission-mode", "default"], "edits": ["--permission-mode", "acceptEdits"],
               "auto": ["--permission-mode", "auto"], "full": ["--dangerously-skip-permissions"], "config": []},
    "codex": {"ask": ["-a", "on-request", "-s", "workspace-write"], "edits": ["-a", "never", "-s", "workspace-write"],
              "auto": ["-a", "never", "-s", "workspace-write"], "full": ["--dangerously-bypass-approvals-and-sandbox"],
              "config": []},
}
APPLY_WHEN = ("now", "turn", "next")
# Loop 29: file access, from the least to the most restricted. Claude Code's own keys do it (v2.1.314+): its file tools
# refuse reads and writes outside its working directories; « readonly » also refuses edits inside. Shell commands are not
# covered (only an OS sandbox does that, Loop 30). Codex: readonly is its own read-only sandbox.
ACCESS = ["open", "contained", "readonly"]   # restart at once, at the end of its turn, or at its next start


def level_rank(level: str) -> int:
    """For caps: « config » counts as « auto » (what Claude Code does by default)."""
    return LEVELS.index(level if level in LEVELS else "auto")

WRAPUP_PROMPT = (
    "Agent Manager GD is closing this session. Please write a short summary of it in Markdown to the file {path} "
    "with these sections: ## What was done, ## Decisions (and why), ## Files touched, ## What is left, "
    "## How to continue. Be concrete (names, paths, commands), at most about 300 words. "
    "{brain}Then answer only: summary written.")
BRAIN_HINT = ("If the second-brain MCP tools are available, also propose it with propose_item (title: "
              "\"Session summary · {name} · {date}\", the summary as its text) so the owner can approve it. ")
BRAIN_DOCUMENT_NOTE = (
    "Agent Manager: the owner asked you to document this session in their Second Brain, in real time, through the "
    "second-brain MCP tools. The Brain's archivist is the only door: you propose (propose_item), it files and links; "
    "never write project notes anywhere else. The repository holds the code; the Brain holds the project: vision, "
    "decisions, the owner's words, where things stand, what each session did. "
    "1. Orient first, before changing anything: call overview, search the Brain for this project (« {project} ») and "
    "read its project card, its latest session journal, its open questions and recent decisions, and the "
    "documentation guidelines note if there is one (follow it: it is the owner's method and wins over this summary). "
    "Check that context against the repository: compare the last commit the Brain knows with `git log` and say so "
    "if work is missing from the Brain. See what other agents are doing: their journals in the Brain, and live "
    "sessions with the agent-manager list_sessions tool. Then tell the user in two lines where the project stands. "
    "2. While you work, propose at milestones, not after every prompt: the owner's directives, wishes and refusals "
    "at once (close to their words, dated); each decision (context, choice, why, alternatives, who decided); a "
    "session journal entry at each commit or finished task (title « Session journal · {name} », with goal, done, "
    "decisions, commits, what is left, how to continue); a pitfall as soon as one bites. "
    "3. Before the session ends, complete the journal (how to continue) and propose an update to the project card. "
    "Ask for an update of the existing item rather than a duplicate; cite your sources (file, commit, date); mark "
    "each claim as established, a hypothesis or a wish. Never put source code, secrets, keys or tokens in the Brain. "
    "If the second-brain tools are missing, say so once and carry on with the work.")
BRIEF_PROMPT = ("Context from earlier sessions on this project, kept by Agent Manager GD: read {path} (the latest "
                "session summary){brain}. Then say in two lines what you understood and wait for instructions.")



def _epoch(iso) -> float:
    """The Brain's UTC times (2026-11-09T14:02:11.123Z) as seconds; 0 when missing or unreadable."""
    import datetime
    try:
        d = datetime.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        return (d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)).timestamp()
    except ValueError:
        return 0.0


def _after(ours: tuple, hs: dict, margin: float = 0.0, hook_first: bool = False) -> bool:
    """Event order between something the engine did (ours: wall time, monotonic time) and the agent's last hook.
    hook_first=False: our action came after the hook; True: the hook came more than `margin` after our action.
    The monotonic clock is used when the hook wrote it (the wall clock can step back under WSL)."""
    if "mono" in hs:
        a, b = ours[1], float(hs["mono"])
    else:
        a, b = ours[0], float(hs.get("time", 0) or 0)
    return b > a + margin if hook_first else a > b


class Sessions:
    def __init__(self, store: Store, tmux: Tmux, home: str = "", brain=None):
        from .orchestra import Orchestra
        self.orchestra = Orchestra(home or os.path.dirname(os.path.dirname(store.path)))
        self._wrapping: dict = {}  # per engine (the class-level dict was shared by every instance in one process)
        self._pending_level: dict[str, bool] = {}  # session id -> a new level waits for the end of its turn (Loop 27)
        self._questions: dict[str, dict] = {}  # session id -> its pending question for the owner (ask_owner, finish_session)
        self._conv_seen: dict[tuple, float] = {}  # (session id, conversation) -> when « seen now » was last written
        self._once = threading.local()  # what list() looks up once for everybody, in the thread that runs it
        self._answered: dict[str, tuple] = {}  # session id -> (wall time, monotonic time) of your answer from the app  # session id -> when you answered it (Approve, Refuse, a reply) from the app
        self.store = store
        self.tmux = tmux
        self.brain = brain  # engine.brain.Brain or None (tests, or the Brain switched off)
        self.home = home or os.path.dirname(os.path.dirname(store.path))
        from .repos import Repos
        from .keys import Keys
        self.repos = Repos(store.path, self.home)
        self.keys_store = Keys(self.home)
        from .vault import Vault
        self.vault = Vault(self.home, self.keys_store)   # named secrets, given session by session (Loop 39)
        from .sandboxes import Sandboxes
        self.sandboxes = Sandboxes(store.path, self.home, self.keys_store)

    # ---------------------------------------------------------------- launching
    def repo_note(self, rec: dict) -> str:
        """For a session on a connected repository: one paragraph added to the agent's instructions (this launch
        only, never written into the repository)."""
        if not rec.get("repo_id"):
            return ""
        try:
            r = self.repos.get(rec["repo_id"])
        except KeyError:
            return ""
        return (f"Agent Manager: this session works in the connected repository « {r['name']} » ({r['url']}). git already "
                "authenticates with that repository's own deploy key through the GIT_SSH_COMMAND environment variable: "
                "use plain git fetch, pull and push. To check access, run `git ls-remote origin` (a bare `ssh -T "
                "git@github.com` ignores GIT_SSH_COMMAND and shows another key). Never create SSH keys, never edit ~/.ssh "
                "and never look into Agent Manager's key folder. If a push is refused for write access, tell the user to "
                "tick « Allow write access » on the repository's deploy key.")

    def brain_note(self, rec: dict) -> str:
        """For a session asked to document itself in the Second Brain (and sharing it): how to orient in the Brain,
        what to propose and when. This launch only, never written into the repository."""
        rec = (self.store.get(rec["id"]) or rec) if rec.get("id") else rec   # the key is stored after the record
        if not (rec.get("brain_document") and rec.get("brain_client")):
            return ""
        project = self._repo_name(rec.get("repo_id", "")) or os.path.basename((rec.get("base_repo") or rec.get("cwd") or "").rstrip("/"))
        return BRAIN_DOCUMENT_NOTE.format(project=project or rec["name"], name=rec["name"])

    def remote_name(self, rec: dict) -> str:
        """The name Remote Control shows in claude.ai/code: « Group · Session »; without a group, a child is named after
        its parent (« Orchestrator · Task 1 »); otherwise the session's name alone."""
        parent = (self.store.get(rec["parent"]) or {}) if rec.get("parent") else {}
        prefix = rec.get("grp") or parent.get("name", "")
        return (f"{prefix} · {rec['name']}" if prefix else rec["name"])[:80]

    def level_for(self, level: str, grp: str = "", parent: str = "") -> str:
        """The level asked for, or the group's default, or « auto » (Claude Code's own default in its terminal);
        never more rights than the session that starts it (an agent's children stay at or below its level)."""
        if level and level not in OWNER_LEVELS:
            raise ValueError("level must be one of " + ", ".join(OWNER_LEVELS))
        if not level:
            level = next((g.get("level", "") for g in self.store.groups() if g["name"] == grp), "") or "auto"
        if parent:
            cap = self._cap(parent)
            if level == "config" or level_rank(level) > level_rank(cap):
                level = cap
        return level

    def _group_access(self, grp: str) -> str:
        return next((g.get("access", "") for g in self.store.groups() if g["name"] == grp), "") if grp else ""

    def permissions_overview(self) -> dict:
        """Loop 31: every agent with what it may do (the Agent Permissions view), and each group's defaults."""
        rows = []
        for d in self.list():
            if d["tool"] == "shell" or d.get("archived"):
                continue
            rows.append({k: d.get(k) for k in ("id", "name", "tool", "grp", "parent", "state", "activity", "level",
                                              "level_pending", "access", "extra_dirs", "os_sandbox", "git_rights", "role")})
        groups = [{"name": g["name"], "level": g.get("level", ""), "access": g.get("access", "")}
                  for g in self.store.groups() if g["name"]]
        return {"agents": rows, "groups": groups, "claude_sandbox": self.native_sandbox()}

    def access_for(self, access: str, parent: str = "") -> str:
        """The file access asked for (« open » by default); a child is never less restricted than its parent."""
        if access and access not in ACCESS:
            raise ValueError("access must be one of " + ", ".join(ACCESS))
        access = access or "open"
        if parent:
            floor = self.access_of(self.store.get(parent) or {})
            if ACCESS.index(access) < ACCESS.index(floor):
                access = floor
        return access

    def os_sandbox_for(self, wanted: bool, parent: str = "") -> bool:
        """Its own sandbox when asked, or when its parent has one (a child is never less contained)."""
        on = bool(wanted) or bool(parent and (self.store.get(parent) or {}).get("os_sandbox"))
        if on and not self.native_sandbox()["available"]:
            if wanted:
                raise ValueError("Claude Code's sandbox needs " + " and ".join(self.native_sandbox()["missing"]) +
                                 " (install: " + self.native_sandbox()["install"] + ")")
        return on

    def _cap(self, parent: str) -> str:
        """The most a child of `parent` may get: its level (« config » counts as « auto »)."""
        cap = (self.store.get(parent) or {}).get("level") or "auto"
        return cap if cap in LEVELS else "auto"

    def set_permissions(self, sid: str, level: str = "", git_push: bool | None = None, git_merge: bool | None = None,
                        when: str = "turn", access: str = "", extra_dirs: list | None = None,
                        os_sandbox: bool | None = None) -> dict:
        """Loop 27-28: the owner's permissions for one agent (from the app; no agent tool does this): its level, and
        its git rights (« Enable git push », « Enable git merge and rebase », Claude Code only: they lift the deny rules).
        Applied like a level, on the same conversation."""
        rec = self.store.get(sid)
        if not rec:
            raise ValueError("no such session")
        if os_sandbox is not None:
            self._set_os_sandbox(rec, os_sandbox)
            if not access and extra_dirs is None and git_push is None and git_merge is None and \
                    (not level or level == (rec.get("level") or "auto")):
                return {"id": sid, "level": rec.get("level") or "auto", "was": rec.get("level") or "auto",
                        "os_sandbox": os_sandbox, "applied": self._apply_level(sid, when), "lowered": [], "children": {}}
        if access or extra_dirs is not None:
            self._set_access(rec, access, extra_dirs)
            if git_push is None and git_merge is None and (not level or level == (rec.get("level") or "auto")):
                return {"id": sid, "level": rec.get("level") or "auto", "was": rec.get("level") or "auto",
                        "access": self.access_of(self.store.get(sid)), "applied": self._apply_level(sid, when),
                        "lowered": [], "children": {}}
        if git_push is None and git_merge is None:
            return self.set_level(sid, level or rec.get("level") or "auto", when)
        if rec["tool"] != "claude":
            raise ValueError("git rights are Claude Code deny rules; Codex and shells have none")
        before = self.git_rights(rec)
        self.store.update(sid, **{f"git_{k}": ("on" if v else "off") for k, v in (("push", git_push), ("merge", git_merge))
                                  if v is not None})
        after = self.git_rights(self.store.get(sid))
        self._log(sid, {"git": [{k: before[k] for k in ("push", "merge")}, {k: after[k] for k in ("push", "merge")}]})
        if level and level != (rec.get("level") or "auto"):
            return self.set_level(sid, level, when)   # restarts once, with both changes
        return {"id": sid, "level": rec.get("level") or "auto", "was": rec.get("level") or "auto", "git": after,
                "applied": self._apply_level(sid, when), "lowered": [], "children": {}}

    def _set_os_sandbox(self, rec: dict, on: bool) -> None:
        if rec["tool"] != "claude":
            raise ValueError("this sandbox is Claude Code's (Codex has its own)")
        if not on and rec.get("parent") and (self.store.get(rec["parent"]) or {}).get("os_sandbox"):
            raise ValueError("its parent is contained by the system: it stays contained too")
        self.os_sandbox_for(on)          # refuses when bubblewrap or socat is missing
        self.store.update(rec["id"], os_sandbox=int(on))
        if on:
            for d in self.descendants(rec["id"]):
                if not d.get("os_sandbox") and d["tool"] == "claude":
                    self.store.update(d["id"], os_sandbox=1)
                    self._apply_level(d["id"], "turn")
        self._log(rec["id"], {"os_sandbox": [bool(rec.get("os_sandbox")), on]})

    def _set_access(self, rec: dict, access: str, extra_dirs: list | None) -> None:
        """Loop 29: its file access and extra folders. Never less restricted than its parent; its children follow."""
        if rec["tool"] not in ("claude", "codex"):
            raise ValueError("a shell has no file access setting")
        sid, old = rec["id"], self.access_of(rec)
        new = self.access_for(access or old, rec.get("parent", ""))
        if access and new != access:
            raise ValueError(f"never less restricted than the session that started it ({new})")
        fields = {"access": new}
        if extra_dirs is not None:
            fields["extra_dirs"] = json.dumps(self._clean_dirs(extra_dirs))
        self.store.update(sid, **fields)
        for d in self.descendants(sid):
            if ACCESS.index(self.access_of(d)) < ACCESS.index(new):
                self.store.update(d["id"], access=new)
                self._apply_level(d["id"], "turn")
        self._log(sid, {"access": [old, new], **({"extra_dirs": json.loads(fields["extra_dirs"])} if "extra_dirs" in fields else {})})

    def set_level(self, sid: str, level: str, when: str = "turn") -> dict:
        """Loop 27: the owner changes an agent's permission level (from the app; no agent tool does this). A level is
        set at launch, so it applies when the session starts again on its own conversation (resume): now, at the end
        of its turn, or at its next start. Its children above the new level come down to it too."""
        rec = self.store.get(sid)
        if not rec:
            raise ValueError("no such session")
        if rec["tool"] not in ("claude", "codex"):
            raise ValueError("a shell has no permission level")
        if level not in OWNER_LEVELS:
            raise ValueError("level must be one of " + ", ".join(OWNER_LEVELS))
        if when not in APPLY_WHEN:
            raise ValueError("when must be one of " + ", ".join(APPLY_WHEN))
        if rec.get("parent"):
            cap = self._cap(rec["parent"])
            if level == "config":
                raise ValueError("« per my config » is for sessions you start; an agent's child gets a known level")
            if level_rank(level) > level_rank(cap):
                raise ValueError(f"never more than the session that started it ({cap})")
        old = rec.get("level") or "auto"
        self.store.update(sid, level=level)
        lowered = []
        for d in self.descendants(sid):
            if level_rank(d.get("level") or "auto") > level_rank(level) or d.get("level") == "config":
                self.store.update(d["id"], level=self._cap(d["parent"]))
                lowered.append(d["id"])
        self._log(sid, {"level": [old, level], "children_lowered": lowered})
        applied = {sid: self._apply_level(sid, when)}
        for c in lowered:
            applied[c] = self._apply_level(c, "turn" if when == "now" else when)
        return {"id": sid, "level": level, "was": old, "applied": applied[sid], "lowered": lowered, "children": applied}

    def _apply_level(self, sid: str, when: str) -> str:
        """« restarted », « at the end of its turn » or « at its next start »."""
        d = self.get(sid)
        if d["state"] != "running" or when == "next":
            self._pending_level.pop(sid, None)
            return "at its next start"
        if when == "turn" and d["activity"] in ("working", "approval", "wrapping"):
            self._pending_level[sid] = True
            return "at the end of its turn"
        self._pending_level.pop(sid, None)
        self.resume(sid)
        return "restarted"

    def _log(self, sid: str, change: dict) -> None:
        """Each change is kept in the session's folder (permissions.log, one JSON line each)."""
        folder = os.path.join(self.home, "sessions", sid)
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "permissions.log"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"at": time.time(), "by": "owner", **change}) + "\n")

    def level_log(self, sid: str) -> list[dict]:
        try:
            with open(os.path.join(self.home, "sessions", sid, "permissions.log"), encoding="utf-8") as f:
                return [json.loads(x) for x in f if x.strip()]
        except (OSError, ValueError):
            return []

    # ---------------------------------------------------------------- the session tree (Loop 25)
    def root_of(self, sid: str) -> str:
        seen = set()
        while sid and sid not in seen:
            seen.add(sid)
            parent = (self._rec(sid) or {}).get("parent", "")
            if not parent:
                return sid
            sid = parent
        return sid

    def depth_of(self, sid: str) -> int:
        d, seen = 0, set()
        while sid and sid not in seen:
            seen.add(sid)
            sid = (self.store.get(sid) or {}).get("parent", "")
            d += 1 if sid else 0
        return d

    def descendants(self, sid: str) -> list[dict]:
        out, todo = [], [sid]
        rows = self.store.all()
        while todo:
            cur = todo.pop()
            kids = [r for r in rows if r.get("parent") == cur]
            out += kids
            todo += [k["id"] for k in kids]
        return out

    def under_orchestrator(self, sid: str) -> bool:
        return (self._rec(self.root_of(sid)) or {}).get("role") == "orchestrator" if sid else False

    def check_caps(self, parent: str) -> None:
        """A session started by an agent: not deeper than MAX_DEPTH, not more than MAX_RUNNING_CHILDREN running at once
        under the same root session."""
        if self.depth_of(parent) + 1 > MAX_DEPTH:
            raise ValueError(f"too deep: sessions started by agents stop at {MAX_DEPTH} levels")
        live = self.tmux.sessions()
        running = [r for r in self.descendants(self.root_of(parent))
                   if (t := live.get(self.tmux_name(r["id"]))) is not None and not t.pane_dead]
        if self.under_orchestrator(parent):
            budget, used = self.orchestra.budget(), self.orchestrated_tokens_today()
            if budget and used >= budget:
                raise ValueError(f"today's token budget is spent ({used:,} of {budget:,} tokens): the owner can raise it")
        if len(running) >= MAX_RUNNING_CHILDREN:
            raise ValueError(f"already {len(running)} sessions running under this one (the limit is "
                             f"{MAX_RUNNING_CHILDREN}): wait for one to finish, or finish one")

    def orchestrated_tokens_today(self) -> int:
        """Tokens the orchestrator and every session under it used today (UTC day), from the agents' own logs."""
        o = next((r for r in self.store.all() if r.get("role") == "orchestrator"), None)
        if not o:
            return 0
        from . import usage
        from .orchestra import today
        ids = {o["id"]} | {r["id"] for r in self.descendants(o["id"])}
        total = 0
        for s in self.store.history():
            if s["id"] not in ids:
                continue
            for c in s.get("conversations", []):
                u = usage.conversation_usage(s["tool"], c["conversation"])
                if u:
                    total += usage.total(u["days"].get(today(), {}))
        return total

    # ---------------------------------------------------------------- the orchestrator (Loop 25)
    def orchestrator(self) -> dict | None:
        rec = next((r for r in self.store.all() if r.get("role") == "orchestrator"), None)
        return self.describe(rec) if rec else None

    def start_orchestrator(self, cwd: str = "~", level: str = "auto", model: str = "") -> dict:
        """The one orchestrator: started once, then resumed on its own conversation when it is not running."""
        cur = self.orchestrator()
        if cur and cur["state"] == "running":
            return cur
        if cur:
            if not cur.get("remote_control"):  # an orchestrator started before it had Remote Control gets it now
                self.store.update(cur["id"], remote_control=1)
            return self.resume(cur["id"]) if hasattr(self, "resume") else cur
        # Remote Control like the app's default: the owner follows and answers it from claude.ai/code or the Claude app
        return self.create("Orchestrator", "claude", cwd, "", brain=True, document=True, level=level or "auto",
                           model=model, role="orchestrator", remote=True)

    def stop_orchestrator(self) -> list[str]:
        """Stops the orchestrator and every session under it (they stay in the list, ended; nothing is deleted)."""
        cur = self.orchestrator()
        if not cur:
            return []
        stopped = []
        for r in [cur] + self.descendants(cur["id"]):
            try:
                self.tmux.kill(self.tmux_name(r["id"]))
                stopped.append(r["id"])
            except Exception:
                pass
        return stopped

    def ask_owner(self, sid: str, question: str, options: list | None = None) -> dict:
        """A question for the owner: the session shows « asks you something » with it until the owner replies, from the
        app (send) or in its terminal (its next prompt, seen by the UserPromptSubmit hook)."""
        q = " ".join(str(question).split())[:400]
        if not q:
            raise ValueError("an empty question")
        opts = [str(o)[:80] for o in (options or [])][:6]
        self._questions[sid] = {"question": q, "options": opts, "at": time.time(), "mono": time.monotonic()}
        return {"asked": True, "note": "the owner's answer will arrive as a message in your terminal; stop until then"}

    def ready_for_review(self, child: str, by: str, note: str = "") -> dict:
        """finish_session: a child's work is done; the owner reviews and merges it (never the agent)."""
        rec = self.store.get(child)
        if not rec or rec.get("parent") != by:
            raise ValueError("you may only finish sessions you started")
        what = f"ready for your review: {note.strip()[:200]}" if note.strip() else "ready for your review"
        how = " · Finish merges its branch" if rec.get("worktree") else ""
        self._questions[child] = {"question": what + how, "options": [], "at": time.time(), "review": True}
        return {"ok": True, "note": "the owner reviews and merges it; you do not push nor merge"}

    @staticmethod
    def extra_dirs(rec: dict) -> list[dict]:
        raw = rec.get("extra_dirs") or "[]"   # JSON in the store, already a list in a described session
        try:
            dirs = raw if isinstance(raw, list) else json.loads(raw)
        except ValueError:
            return []
        return [d for d in dirs if isinstance(d, dict) and d.get("path")]

    def _clean_dirs(self, dirs: list) -> list[dict]:
        """Extra folders: absolute, existing, never Agent Manager's own data; each read and write or read only."""
        out = []
        for d in dirs or []:
            path, write = (d.get("path", ""), bool(d.get("write", True))) if isinstance(d, dict) else (str(d), True)
            path = os.path.abspath(os.path.expanduser(str(path).strip()))
            if not str(path).strip() or not os.path.isdir(path):
                raise ValueError(f"not a folder: {path}")
            home = os.path.abspath(self.home)
            if path == home or path.startswith(home + os.sep) or home.startswith(path + os.sep):
                raise ValueError("Agent Manager's own data folder cannot be given to an agent")
            if path not in [x["path"] for x in out]:
                out.append({"path": path, "write": write})
        return out[:12]

    def access_of(self, rec: dict) -> str:
        return rec.get("access") if rec.get("access") in ACCESS else "open"

    @staticmethod
    def native_sandbox() -> dict:
        """Loop 30: can Claude Code's own sandbox run here? Linux and WSL2 need bubblewrap and socat (installed by the
        owner: they need administrator rights; Agent Manager never installs them)."""
        missing = [b for b in ("bwrap", "socat") if not shutil.which(b)]
        ok = sys.platform.startswith("linux") and not missing
        return {"available": ok, "missing": missing,
                "install": "" if ok else "sudo apt-get install " + " ".join({"bwrap": "bubblewrap"}.get(m, m) for m in missing)}

    def sandbox_settings(self, rec: dict) -> dict:
        """Claude Code's « sandbox » block for its shell commands: the operating system (bubblewrap) refuses what its
        file access says, scripts included. Never a silent fallback: if the sandbox cannot start, Claude Code stops
        (failIfUnavailable) and no command runs outside it (allowUnsandboxedCommands false)."""
        access, cwd = self.access_of(rec), os.path.abspath(os.path.expanduser(rec["cwd"]))
        dirs = self.extra_dirs(rec)
        fs: dict = {"denyRead": ["~/.ssh", "~/.aws", "~/.gnupg", "~/.config/gh", os.path.join(os.path.abspath(self.home), "keys"),
                                 os.path.join(os.path.abspath(self.home), "runtime")]}
        if access in ("contained", "readonly"):
            fs["denyRead"].append("~/")   # its home is closed; its folder and extra folders are opened again below
            fs["allowRead"] = [cwd] + [d["path"] for d in dirs]
        if access == "readonly":
            fs["denyWrite"] = [cwd] + [d["path"] for d in dirs]
        else:
            ro = [d["path"] for d in dirs if not d["write"]]
            if ro:
                fs["denyWrite"] = ro
        return {"enabled": True, "failIfUnavailable": True, "allowUnsandboxedCommands": False, "filesystem": fs}

    def access_settings(self, rec: dict) -> dict:
        """The native permissions keys for its file access (merged into its per-launch settings)."""
        access, out, deny = self.access_of(rec), {}, []
        dirs = self.extra_dirs(rec)
        if dirs:
            out["additionalDirectories"] = [d["path"] for d in dirs]
            deny += [f"Edit(/{d['path']}/**)" for d in dirs if not d["write"]]
        if access in ("contained", "readonly"):
            out["blockReadsOutsideWorkingDirectories"] = True
            out["blockWritesOutsideWorkingDirectories"] = True
        if access == "readonly":
            deny.append(f"Edit(/{os.path.abspath(os.path.expanduser(rec['cwd']))}/**)")
            deny += [f"Edit(/{d['path']}/**)" for d in dirs if d["write"]]
        return {"keys": out, "deny": deny}

    def deny_rules(self, rec: dict | None = None) -> list[str]:
        """Paths no agent may read or change, at every level, « No permission » included (Claude Code applies deny
        rules in every mode). Its built-in file tools and the file commands it recognises in Bash are covered; a
        script that opens files itself is not (only an OS sandbox would stop that)."""
        paths = ["~/.ssh/**", "~/.aws/**", "~/.gnupg/**", "~/.config/gh/**", "**/.env", "**/.env.keys", "**/.env.local",
                 "/" + os.path.join(os.path.abspath(self.home), "keys") + "/**",
                 # the engine's API token: with it an agent could call the app's own routes (change its level, Loop 27)
                 "/" + os.path.join(os.path.abspath(self.home), "runtime") + "/**"]
        if self.brain and getattr(self.brain, "home", ""):
            for sub in ("runtime", "mcp"):
                paths.append("/" + os.path.join(os.path.abspath(self.brain.home), sub) + "/**")
        out = [f"Read({p})" for p in paths] + [f"Edit({p})" for p in paths]
        if rec and rec.get("id"):
            rights = self.git_rights(rec)
            out += ([] if rights["push"] else GIT_PUSH_RULES) + ([] if rights["merge"] else GIT_MERGE_RULES)
        return out

    def git_rights(self, rec: dict) -> dict:
        """Loop 28: may it push, merge and rebase? By default the orchestrator and its sessions may not (pushing and
        merging are the owner's), a session the owner started may; the owner's checkbox (on / off) wins either way."""
        default = not self.under_orchestrator(rec["id"])
        return {k: {"on": True, "off": False}.get(rec.get("git_" + k) or "", default) for k in ("push", "merge")} | \
            {"default": default}

    def command_for(self, rec: dict, mode: str = "new", conversation: str = "") -> list[str]:
        """The tool's command with this session's hooks: options of this launch only, never the user's settings.
        mode: new (a fresh conversation), resume (its own conversation), fork (a copy of a conversation)."""
        hook = [sys.executable or "python3", HOOK]
        if rec["tool"] == "claude":
            cmd = " ".join(_q(c) for c in hook + ["claude"])
            settings = {"hooks": {e: [{"matcher": "", "hooks": [{"type": "command", "command": cmd, "timeout": 5}]}]
                                  for e in CLAUDE_EVENTS},
                        "permissions": {"deny": self.deny_rules(rec)}}
            acc = self.access_settings(rec)
            settings["permissions"].update(acc["keys"])
            settings["permissions"]["deny"] += acc["deny"]
            if rec.get("os_sandbox"):
                settings["sandbox"] = self.sandbox_settings(rec)
            folder = os.path.join(self.home, "sessions", rec["id"])
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, "claude-settings.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(settings, f)
            base = ["claude", "--settings", path] + LEVEL_FLAGS["claude"][rec.get("level") or "auto"] + self._claude_mcp(rec)
            if rec.get("model"):
                base += ["--model", rec["model"]]
            if rec.get("remote_control"):  # seen and driven from claude.ai/code or the Claude app, under this name
                base += ["--remote-control", self.remote_name(rec)]
            # how git already authenticates here (the agent never goes looking for a key in ~/.ssh), and, when asked,
            # how to document the session in the Second Brain: one --append-system-prompt for both
            orch = ORCH_NOTE.format(max_children=MAX_RUNNING_CHILDREN) if rec.get("role") == "orchestrator" else ""
            note = "\n\n".join(n for n in (orch, self.repo_note(rec), self.brain_note(rec)) if n)
            if note:
                base += ["--append-system-prompt", note]
            if mode == "resume" and conversation:
                return base + ["--resume", conversation]
            if mode == "fork" and conversation:
                return base + ["--resume", conversation, "--fork-session"]
            # a fresh conversation: we choose its id, so it is known (and kept) from the first second
            new_id = str(uuid.uuid4())
            self.store.touch_conversation(rec["id"], "claude", new_id)
            return base + ["--session-id", new_id]
        if rec["tool"] == "codex":
            flags = LEVEL_FLAGS["codex"][rec.get("level") or "auto"]
            if self.access_of(rec) == "readonly":   # Codex's own read-only sandbox, whatever its level
                flags = ["-a", flags[1] if flags[:1] == ["-a"] else "never", "-s", "read-only"]
            notify = ["-c", "notify=" + json.dumps(hook + ["codex"])] + flags + self._codex_mcp(rec)
            if rec.get("model"):
                notify += ["-m", rec["model"]]
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
               repo: str = "", host: str = "local", remote: bool | None = None, document: bool = False,
               level: str = "", model: str = "", role: str = "", access: str = "", extra_dirs: list | None = None,
               os_sandbox: bool = False) -> dict:
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
        if not repo:  # a folder that belongs to a connected repository: the session gets that repository's key too
            repo = self.repos.owner_of(cwd)
        wt, base = ("", "")
        if worktree:
            wt, base = self._add_worktree(cwd, name)
            cwd = wt
        if parent and not self.store.get(parent):
            raise ValueError("unknown parent session")
        level = self.level_for(level, grp, parent)
        if parent:
            self.check_caps(parent)
        if model and not re.match(r"^[A-Za-z0-9._\-\[\]]{1,60}$", model):
            raise ValueError("a model name of letters, digits, dots and dashes")
        from .review import head
        rec = self.store.add(name.strip(), tool, cwd, grp, worktree=wt, base_repo=base, parent=parent, start_commit=head(cwd),
                             repo_id=repo)
        self.store.update(rec["id"], level=level, model=model, role=role, access=self.access_for(access or self._group_access(grp), parent),
                          extra_dirs=json.dumps(self._clean_dirs(extra_dirs or [])),
                          os_sandbox=int(self.os_sandbox_for(os_sandbox, parent)))
        rec = self.store.get(rec["id"])
        if remote is None:  # not said: a child follows its parent (the orchestrator's children too), else no
            remote = bool(parent and (self.store.get(parent) or {}).get("remote_control"))
        if remote and tool == "claude":
            self.store.update(rec["id"], remote_control=1)
            rec = self.store.get(rec["id"])
        if brain:
            self._connect_brain(rec)
            if document and tool == "claude" and (self.store.get(rec["id"]) or {}).get("brain_client"):
                self.store.update(rec["id"], brain_document=1)   # Claude Code only: Codex gets no instructions yet
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
            # « seen now » is written at once for a new conversation, then at most once a minute: written at every
            # refresh it was a database commit per agent every 2 seconds (about 12 ms each, measured in Loop 33)
            key, now = (rec["id"], hs["conversation"]), time.monotonic()
            if now - self._conv_seen.get(key, -1e9) > 60:
                self._conv_seen[key] = now
                self.store.touch_conversation(rec["id"], rec["tool"], hs["conversation"])
        activity, message = self.activity(rec, t, hs) if state == "running" else (state, "")
        if rec.get("archived"):
            state, activity = "archived", "archived"
        elif rec["id"] in self._wrapping and state == "running":
            activity, message = "wrapping", "writing its summary"
        elif rec["id"] in self._questions and state == "running" and not self._answered_in_terminal(rec["id"], hs):
            q = self._questions[rec["id"]]
            activity, message = "waiting", q["question"] + ("  [" + " / ".join(q["options"]) + "]" if q["options"] else "")
        if rec["id"] in self._pending_level and state == "running" and activity in ("done", "idle", "waiting"):
            self._pending_level.pop(rec["id"], None)   # its turn is over: start it again with its new level
            try:
                self.resume(rec["id"])
            except Exception:
                pass
        return {**rec, "tool_label": TOOLS.get(rec["tool"], {}).get("label", rec["tool"]), "state": state,
                "activity": activity, "message": message, "conversation": hs.get("conversation", ""),
                "since": float(hs.get("time", 0) or (t.activity if t else 0) or rec["created"]),
                "last_conversation": self.last_conversation(rec["id"]),
                "brain": bool(rec.get("brain_client")),
                "brain_document": bool(rec.get("brain_client") and rec.get("brain_document")),
                "level": rec.get("level") or "auto",
                "level_pending": rec["id"] in self._pending_level,
                "git_rights": self.git_rights(rec),
                "access": self.access_of(rec), "extra_dirs": self.extra_dirs(rec),
                "os_sandbox": bool(rec.get("os_sandbox")),
                "remote_control": bool(rec.get("remote_control")),
                "repo_name": self._repo_name(rec.get("repo_id", "")),
                "host": "sandbox" if sb_info else "local",
                "sandbox": {k: sb_info[k] for k in ("id", "region", "finished", "destroyed", "machine")} if sb_info else None,
                "branch": self.branch(rec["cwd"]),
                "tmux": self.tmux_name(rec["id"]), "attached": bool(t and t.attached),
                "command": t.pane_command if t else ""}

    def _answered_in_terminal(self, sid: str, hs: dict) -> bool:
        """The owner answered an ask_owner question by typing in the session's terminal: a prompt reached the agent
        after the question (before: only a reply from the app cleared it, and « waits for an answer » stayed)."""
        q = self._questions.get(sid)
        if not q or q.get("review") or "prompt_mono" not in hs:
            return False
        prompt = {"time": hs.get("prompt_time", 0), "mono": hs["prompt_mono"]}
        if not _after((q["at"], q.get("mono", 0.0)), prompt, hook_first=True):
            return False
        self._questions.pop(sid, None)
        return True

    def _screen(self, rec: dict) -> str:
        """The whole visible screen (no history): where Claude Code shows « esc to interrupt ». During list(), the
        first session that needs its screen has every agent's screen read in one tmux call, kept for that refresh."""
        name, snap = self.tmux_name(rec["id"]), self._snap()
        if snap is not None:
            if snap["screens"] is None:
                recs, live = snap["recs"], snap["live"]
                snap["screens"] = self.tmux.screens([n for n, t in live.items() if not t.pane_dead
                                                     and (recs.get(n[len(PREFIX):]) or {}).get("tool") in ("claude", "codex")])
            if name in snap["screens"]:
                return snap["screens"][name]
        try:
            return self.tmux.run("capture-pane", "-p", "-J", "-t", name)
        except Exception:
            return ""

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
            if CLAUDE_BUSY.search(self._screen(rec) if t else ""):
                return "working", "in a cloud sandbox"
            if APPROVAL_HINTS.search(tail):
                return "approval", "in a cloud sandbox"
            return "idle", "in a cloud sandbox"
        if rec["tool"] == "claude" and hs.get("state"):
            st, since, message = hs["state"], float(hs.get("time", 0) or 0), str(hs.get("message", ""))
            if st in ("approval", "waiting"):
                # Claude Code says nothing between your answer and the end of the tool you allowed (a test run can take
                # minutes): answered from the app, or the prompt is gone and it works again (answered in its terminal)
                answered = self._answered.get(rec["id"])
                if answered and _after(answered, hs):
                    st, since, message = "working", answered[0], ""
                elif t and now - since > 3:
                    screen = self._screen(rec)
                    if CLAUDE_BUSY.search(screen) and not APPROVAL_HINTS.search("\n".join(screen.splitlines()[-12:])):
                        st, message = "working", ""
            # the last hook said « working » a while ago and Claude Code does not show « esc to interrupt »: the turn
            # ended without a Stop hook (Esc, an error). Screen redraws do not count: full-screen mode redraws by itself.
            if st == "working" and t and now - since > STALE_WORKING_SECONDS \
                    and not CLAUDE_BUSY.search(self._screen(rec)):
                return "idle", "stopped (interrupted?)"
            return ("idle" if st == "ended" else st), message
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

    QUIET = 30 * 60  # a documenting session that worked this long after its last proposal gets a gentle hint

    def brain_activity(self, now: float | None = None) -> dict:
        """The Second Brain as the app shows it: is it there, which sessions hold a key, what each one did with it
        (calls, last use, proposals and how they ended), today's proposals and the latest ones. Never a key."""
        now = now or time.time()
        recs = [r for r in self.store.all() if r.get("brain_client")]
        st = self.brain.status() if self.brain else {"connected": False, "reason": "off"}
        keys, props = ({}, [])
        if st["connected"]:
            keys, props = self.brain.keys_activity(), self.brain.proposals()
        by_key = {r["brain_client"]: r for r in recs}
        lt = time.localtime(now)
        midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
        sessions = {}
        for r in recs:
            cid, k = r["brain_client"], keys.get(r["brain_client"])
            mine = [p for p in props if p["client_id"] == cid]
            last_p = max((_epoch(p["created_at"]) for p in mine), default=0.0)
            problem = ("" if k else "its key no longer works") if st["connected"] else "the Second Brain is not running"
            worked = float(self.hook_state(r["id"]).get("time", 0) or 0)
            doc = bool(r.get("brain_document"))
            sessions[r["id"]] = {
                "document": doc, "problem": problem,
                "calls": int(k.get("calls", 0) or 0) if k else 0, "last_seen": _epoch(k.get("last_seen")) if k else 0.0,
                "proposals": len(mine), "applied": sum(p["status"] == "applied" for p in mine),
                "pending": sum(p["status"] == "pending" for p in mine),
                "refused": sum(p["status"] in ("rejected", "failed") for p in mine), "last_proposal": last_p,
                "quiet": bool(doc and not problem and worked - (last_p or float(r["created"])) > self.QUIET)}
        ours = [p for p in props if p["client_id"] in by_key]
        return {"connected": bool(st["connected"]), "reason": st.get("reason", ""), "sessions": sessions,
                "agents": sum(1 for r in self.store.all() if r["tool"] != "shell"),
                "today": sum(1 for p in ours if _epoch(p["created_at"]) >= midnight),
                "recent": [{"title": p["title"], "session": by_key[p["client_id"]]["name"], "status": p["status"],
                            "at": _epoch(p["created_at"])} for p in ours[:6]]}

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
        """Every session, described. The app asks every 2 seconds, so everybody is looked up together (Loop 33): the
        records and each session's last conversation in two database calls, the screens that must be read in one
        tmux call. Before, it was two database calls and up to one tmux call per session."""
        self.check_wrapups()
        self.enforce_caps()
        live = self.tmux.sessions()
        recs = self.store.all()
        self._once.snap = {"recs": {r["id"]: r for r in recs},
                           "convs": self.store.last_conversations([r["id"] for r in recs]),
                           "live": live, "screens": None}
        try:
            return [self.describe(r, live) for r in recs]
        finally:
            self._once.snap = None

    def _snap(self) -> dict | None:
        """What list() looked up for everybody, while it runs (in its own thread only)."""
        return getattr(self._once, "snap", None)

    def _rec(self, sid: str) -> dict | None:
        snap = self._snap()
        if snap and sid in snap["recs"]:
            return snap["recs"][sid]
        return self.store.get(sid)

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
        self._answered[sid] = (time.time(), time.monotonic())
        self._questions.pop(sid, None)

    KEYS = {"Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab", "y", "n", "1", "2", "3"}

    def keys(self, sid: str, keys: list[str]) -> None:
        """Named keys only (approve with Enter, refuse with Escape…): never arbitrary tmux key strings."""
        if self.get(sid)["state"] != "running":
            raise ValueError("the session is not running")
        bad = [k for k in keys if k not in self.KEYS]
        if bad or not keys or len(keys) > 8:
            raise ValueError("keys must be among " + ", ".join(sorted(self.KEYS)))
        self.tmux.run("send-keys", "-t", self.tmux_name(sid), *keys)
        self._answered[sid] = (time.time(), time.monotonic())

    def _in_sandbox(self, d: dict) -> tuple[list[str], str] | None:
        """For a session that lives in a cloud sandbox: its terminal's command (which reaches the sandbox) and the
        folder to start it in. Before, starting such a session again (after WSL restarted, or « Resume ») ran the
        tool here, in a shell of this computer, while the session still said « in a cloud sandbox »."""
        sb = self.sandboxes.by_session(d["id"]) if d.get("cwd") == "/work" else None
        if not sb or sb.get("destroyed"):
            return None
        return [sys.executable or "python3", SANDBOX_ATTACH, sb["id"]], self.home

    def restart(self, sid: str) -> dict:
        """Starts the tool again in the same session (fresh conversation); recreates the tmux session if it is gone."""
        d = self.get(sid)
        cmd = self.command_for(d)
        there = self._in_sandbox(d)
        if there:
            cmd, folder = there
            if d["state"] == "missing":
                self.tmux.new_session(d["tmux"], folder, cmd, env=self.session_env(sid))
            else:
                self.tmux.respawn(d["tmux"], folder, cmd)
            return self.get(sid)
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

    def repo_branches(self, rid: str) -> dict:
        """The repository's branch map, with the open sessions that work in each branch's folder."""
        data = self.repos.branches(rid)
        if not data.get("read") or not data.get("base"):
            return data
        by_folder: dict[str, list[dict]] = {}
        for s in self.store.history():
            if s.get("archived") or s.get("repo_id") != rid and not s.get("worktree"):
                continue
            folder = s.get("worktree") or s.get("cwd") or ""
            if folder:
                by_folder.setdefault(os.path.realpath(folder), []).append({"id": s["id"], "name": s["name"]})
        for b in [data["base"]] + data["branches"]:
            b["sessions"] = by_folder.get(os.path.realpath(b["worktree"]), []) if b["worktree"] else []
        return data

    def repo_sessions(self, rid: str) -> list[dict]:
        return [{"id": r["id"], "name": r["name"], "archived": r["archived"], "created": r["created"]}
                for r in self.store.history() if r.get("repo_id") == rid]

    def last_conversation(self, sid: str) -> str:
        snap = self._snap()
        if snap and sid in snap["recs"]:
            return snap["convs"].get(sid, "")
        convs = self.store.conversations(sid)
        return convs[0]["conversation"] if convs else ""

    def _launch(self, d: dict, cmd: list[str]) -> None:
        try:
            os.remove(os.path.join(self.home, "state", d["id"] + ".json"))
        except OSError:
            pass
        there = self._in_sandbox(d)
        if there:   # its terminal reaches the sandbox, where tmux keeps the agent and its conversation
            cmd = there[0]
            d = {**d, "cwd": there[1]}
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
            if d.get("brain_document"):  # a fork keeps documenting, with a key of its own
                self.store.update(rec["id"], brain_document=1)
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
        self._wrapping[sid] = ((time.time(), time.monotonic()), path, archive)
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
            settled = hs.get("state") in ("done", "waiting", "idle") and _after(start, hs, 1.0, hook_first=True)
            waited = time.monotonic() - start[1]
            if os.path.exists(path) and (settled or waited > 900):
                with open(path, encoding="utf-8", errors="replace") as f:
                    text = f.read().strip()[:20000]
                self.store.add_summary(sid, self.last_conversation(sid), rec["cwd"], path, text)
                self._wrapping.pop(sid, None)
                if archive:
                    self.archive(sid)
                finished.append(sid)
            elif waited > 1800:  # gave up: the session stays as it is
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
            groups.append({"name": g["name"], "folded": bool(g["folded"]), "level": g.get("level", ""), "access": g.get("access", ""),
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
