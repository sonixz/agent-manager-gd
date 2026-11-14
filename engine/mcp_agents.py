"""Agents piloting agents (Loop 6C): a small MCP server (stdio, newline-delimited JSON-RPC) offered to every agent
session. It talks to the engine's local API with the engine's token (same user, same computer).

Rules: an agent may look at every session (list, status, screen), but it may only start sessions of its own (they
become its children) and write to those children. It can never press keys for another session (no approvals on
someone else's behalf). Standard library only.
  python3 mcp_agents.py        (AGMGD_SESSION, AGMGD_HOME and AGMGD_PORT come from the session's environment)
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

PROTOCOL = "2025-06-18"
DONE = {"done", "waiting", "approval", "idle", "exited", "missing", "archived"}

TOOLS = [
    {"name": "list_sessions", "description": "Every session in Agent Manager GD: id, name, tool, group, folder, what it is doing.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "session_status", "description": "One session's state and its last message.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}},
    {"name": "read_screen", "description": "The last lines of a session's terminal (plain text).",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "lines": {"type": "integer", "minimum": 5, "maximum": 200}}, "required": ["id"]}},
    {"name": "start_session", "description": "Starts a new session as your child (Claude Code, Codex or a shell); you may then write to it. It has Remote Control when you do (unless `remote` says otherwise). It never gets more permissions than you, and at most a few run at once under the same root session.",
     "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}, "tool": {"type": "string", "enum": ["claude", "codex", "shell"]},
                     "cwd": {"type": "string", "description": "folder; yours by default"}, "group": {"type": "string"},
                     "repo": {"type": "string", "description": "a connected repository's id (list_repos): the session works in its folder, git uses its own key"},
                     "worktree": {"type": "boolean", "description": "its own git branch in a worktree beside the repository"},
                     "level": {"type": "string", "enum": ["ask", "edits", "auto", "full"], "description": "permissions; capped at yours"},
                     "model": {"type": "string", "description": "the model to run, e.g. opus, sonnet, haiku (Claude Code) or a Codex model"},
                     "document": {"type": "boolean", "description": "Claude Code: documents itself in the Second Brain"},
                     "access": {"type": "string", "enum": ["open", "contained", "readonly"], "description": "file access: open, contained (its file tools stay in its folder) or readonly; never less restricted than yours"},
                     "remote": {"type": "boolean", "description": "Claude Code: Remote Control, so the owner can follow it from claude.ai/code or the Claude app; yours by default"},
                     "sandbox": {"type": "string", "description": "a cloud sandbox's id (list_sessions shows each session's): the session runs on that machine, beside its other sessions, in its own git worktree; never a new machine"}}, "required": ["name", "tool"]}},
    {"name": "send_to_session", "description": "Types a message into one of YOUR child sessions and presses Enter.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "text": {"type": "string"}}, "required": ["id", "text"]}},
    {"name": "wait_for_session", "description": "Waits until a session stops working (done, waiting for an answer or an OK, ended), then returns its state and screen.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "timeout_s": {"type": "integer", "minimum": 5, "maximum": 900}}, "required": ["id"]}},
]


# the orchestrator's own tools (Loop 25)
ORCH_TOOLS = [
    {"name": "list_repos", "description": "The connected repositories: id, name, address, local folder, status, and the sessions working in each.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "ask_owner", "description": "Asks the owner something (your plan, a choice). Your session shows « asks you something » with it; the answer arrives as a message in your terminal. Stop working until it comes.",
     "inputSchema": {"type": "object", "properties": {"question": {"type": "string"}, "options": {"type": "array", "items": {"type": "string"}}}, "required": ["question"]}},
    {"name": "routing_rules", "description": "The owner's routing rules (which tool and model for which kind of task) and today's token budget. Read them before choosing.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "set_plan", "description": "Writes your plan, shown live to the owner in your panel (after the owner's OK). Each task: title, repo, tool, model, why.",
     "inputSchema": {"type": "object", "properties": {"goal": {"type": "string"}, "tasks": {"type": "array", "items": {"type": "object", "properties": {
         "id": {"type": "string"}, "title": {"type": "string"}, "repo": {"type": "string"}, "tool": {"type": "string", "enum": ["claude", "codex", "shell"]},
         "model": {"type": "string"}, "why": {"type": "string"}}, "required": ["title"]}}}, "required": ["tasks"]}},
    {"name": "update_task", "description": "Updates one task of your plan: status (planned, running, review, done, dropped), its session id, a note.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "status": {"type": "string", "enum": ["planned", "running", "review", "done", "dropped"]},
                     "session": {"type": "string"}, "note": {"type": "string"}}, "required": ["id"]}},
    {"name": "usage", "description": "Tokens you and your sessions used today (UTC day, from the agents' own logs) and the owner's daily budget (0 = none).",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "finish_session", "description": "Marks one of YOUR sessions as done and ready for the owner's review: the owner reviews and merges it (you never push nor merge).",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "note": {"type": "string", "description": "what was done and how it was checked"}}, "required": ["id"]}},
]


class Engine:
    def __init__(self):
        self.me = os.environ.get("AGMGD_SESSION", "")
        # a tool outside the app (Connect other tools) has no AGMGD_HOME: the engine's default data folder
        home = os.environ.get("AGMGD_HOME") or os.path.join(
            os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "agent-manager-gd")
        self.port = int(os.environ.get("AGMGD_PORT", "8790"))
        with open(os.path.join(home, "runtime", "api_token"), encoding="utf-8") as f:
            self.token = f.read().strip()

    def call(self, method, path, body=None):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                return {"error": json.loads(e.read()).get("error", f"HTTP {e.code}")}
            except ValueError:
                return {"error": f"HTTP {e.code}"}

    def role(self):
        if not self.me:
            return ""
        r = self.call("GET", f"/sessions/{self.me}")
        return "" if "error" in r else str(r.get("role", ""))

    @staticmethod
    def brief(s):
        out = {k: s.get(k) for k in ("id", "name", "tool", "grp", "cwd", "state", "activity", "message", "parent", "branch", "level", "model", "worktree")}
        if s.get("sandbox"):  # Loop 40: which machine it runs on (start_session can add a session there)
            out["sandbox"] = s["sandbox"].get("id")
        return out


def run_tool(eng, name, a):
    if name == "list_sessions":
        r = eng.call("GET", "/sessions")
        return r if "error" in r else {"me": eng.me, "sessions": [eng.brief(s) for s in r["sessions"]]}
    sid = str(a.get("id", ""))
    if name == "session_status":
        r = eng.call("GET", f"/sessions/{sid}")
        return r if "error" in r else eng.brief(r)
    if name == "read_screen":
        return eng.call("GET", f"/sessions/{sid}/preview?lines={int(a.get('lines', 40))}")
    if name == "start_session":
        mine = eng.call("GET", f"/sessions/{eng.me}") if eng.me else {}
        body = {"name": str(a.get("name", "")), "tool": str(a.get("tool", "shell")), "parent": eng.me,
                "cwd": str(a.get("cwd") or mine.get("cwd") or "~"), "group": str(a.get("group", mine.get("grp", ""))),
                "repo": str(a.get("repo", "")), "worktree": bool(a.get("worktree", False)), "level": str(a.get("level", "")),
                "model": str(a.get("model", "")), "document": bool(a.get("document", False))}
        if a.get("access"):
            body["access"] = str(a["access"])
        if "remote" in a:  # otherwise the engine gives the child its parent's Remote Control
            body["remote"] = bool(a["remote"])
        if a.get("sandbox"):  # Loop 40: on a sandbox that is there already
            body.update(host="sandbox", sandbox=str(a["sandbox"]))
        r = eng.call("POST", "/sessions", body)
        return r if "error" in r else eng.brief(r)
    if name == "send_to_session":
        target = eng.call("GET", f"/sessions/{sid}")
        if "error" in target:
            return target
        if not eng.me or target.get("parent") != eng.me:
            return {"error": "you may only write to sessions you started (start_session)"}
        return eng.call("POST", f"/sessions/{sid}/send", {"text": str(a.get("text", ""))})
    if name == "wait_for_session":
        end = time.time() + min(900, max(5, int(a.get("timeout_s", 300))))
        time.sleep(2.0)  # let a message just sent start the work
        while True:
            s = eng.call("GET", f"/sessions/{sid}")
            if "error" in s or s.get("activity") in DONE or time.time() > end:
                break
            time.sleep(2.0)
        if "error" in s:
            return s
        screen = eng.call("GET", f"/sessions/{sid}/preview?lines=30").get("text", "")
        return {**eng.brief(s), "timed_out": s.get("activity") not in DONE, "screen": screen}
    if name in ("list_repos", "ask_owner", "finish_session", "routing_rules", "set_plan", "update_task", "usage") and eng.role() != "orchestrator":
        return {"error": f"{name} is for the orchestrator only"}
    if name == "list_repos":
        r = eng.call("GET", "/repos")
        return r if "error" in r else {"repos": [{k: x.get(k) for k in ("id", "name", "url", "local_path", "status")} |
                                                 {"sessions": [y.get("name") for y in x.get("sessions", [])]} for x in r["repos"]]}
    if name == "ask_owner":
        return eng.call("POST", f"/sessions/{eng.me}/ask", {"question": str(a.get("question", "")), "options": a.get("options") or []})
    if name in ("routing_rules", "usage"):
        r = eng.call("GET", "/orchestrator")
        if "error" in r:
            return r
        return {"rules": r["rules"], "budget": r["budget"]} if name == "routing_rules" else r["budget"]
    if name == "set_plan":
        return eng.call("POST", "/orchestrator/plan", {"goal": str(a.get("goal", "")), "tasks": a.get("tasks") or []})
    if name == "update_task":
        return eng.call("POST", f"/orchestrator/tasks/{a.get('id', '')}/update",
                        {"status": str(a.get("status", "")), "session": str(a.get("session", "")), "note": str(a.get("note", ""))})
    if name == "finish_session":
        return eng.call("POST", f"/sessions/{sid}/ready", {"by": eng.me, "note": str(a.get("note", ""))})
    return {"error": f"unknown tool {name}"}


def handle(eng, msg):
    mid, method = msg.get("id"), msg.get("method", "")
    if mid is None:
        return None  # notifications
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": msg.get("params", {}).get("protocolVersion", PROTOCOL),
            "capabilities": {"tools": {}}, "serverInfo": {"name": "agent-manager", "title": "Agent Manager GD", "version": "0.1"},
            "instructions": "Sessions of Agent Manager GD. Look at any session; start child sessions and write only to them."}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS + (ORCH_TOOLS if eng.role() == "orchestrator" else [])}}
    if method == "tools/call":
        p = msg.get("params", {})
        try:
            data = run_tool(eng, p.get("name", ""), p.get("arguments") or {})
        except Exception as e:  # the model reads the error; the protocol stays healthy
            data = {"error": str(e)[:300]}
        return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}],
                                                          "isError": "error" in data}}
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}}


def main():
    for stream, kw in ((sys.stdin, {"encoding": "utf-8", "errors": "replace"}), (sys.stdout, {"encoding": "utf-8", "newline": "\n"})):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(**kw)
    eng = Engine()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            out = handle(eng, json.loads(line))
        except ValueError:
            out = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
        if out is not None:
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
