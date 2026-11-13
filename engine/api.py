"""Local API on 127.0.0.1 with a bearer token (standard library HTTP server). JSON in, JSON out."""
from __future__ import annotations

import hmac
import json
import os
import secrets
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .sessions import TOOLS, Sessions

VERSION = "0.1.0"


def load_token(home: str) -> str:
    path = os.path.join(home, "runtime", "api_token")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(secrets.token_urlsafe(32))
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def make_handler(sessions: Sessions, token: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "agmgd/" + VERSION

        def log_message(self, fmt, *args):  # no request logs (paths only, never the token)
            pass

        def _reply(self, code: int, body) -> None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _authorised(self) -> bool:
            got = self.headers.get("Authorization", "")
            return hmac.compare_digest(got, "Bearer " + token)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if n > (30_000_000 if self.path.startswith("/voice") else 1_000_000):
                raise ValueError("request too large")
            raw = self.rfile.read(n) if n else b"{}"
            data = json.loads(raw.decode("utf-8") or "{}")
            if not isinstance(data, dict):
                raise ValueError("a JSON object")
            return data

        def _route(self, method: str) -> None:
            url = urlparse(self.path)
            parts = [p for p in url.path.split("/") if p]
            if parts == ["health"]:
                return self._reply(200, {"ok": True, "version": VERSION, "tmux": sessions.tmux.version()})
            if len(parts) >= 3 and parts[0] == "sandbox-brain":
                return self._sandbox_brain(method, parts)
            if not self._authorised():
                return self._reply(401, {"error": "unauthorised"})
            try:
                if parts == ["tools"] and method == "GET":
                    return self._reply(200, {k: v["label"] for k, v in TOOLS.items()})
                if parts == ["sessions"] and method == "GET":
                    return self._reply(200, {"sessions": sessions.list()})
                if parts == ["repos"] and method == "GET":
                    return self._reply(200, {"repos": [{**r, "sessions": sessions.repo_sessions(r["id"])} for r in sessions.repos.all()]})
                if parts == ["repos"] and method == "POST":
                    b = self._body()
                    return self._reply(201, sessions.repos.add(str(b.get("url", "")), str(b.get("local_path", "")), str(b.get("name", ""))))
                if len(parts) == 3 and parts[0] == "repos" and parts[2] == "branches" and method == "GET":  # the map of its branches
                    return self._reply(200, sessions.repo_branches(parts[1]))
                if parts == ["repos", "refresh"] and method == "POST":  # the slow facts, read aside: answers at once
                    b = self._body()
                    if b.get("force"):   # « Check all »: whatever their age
                        return self._reply(200, sessions.repos.refresh(True, key_age=-1.0, folder_age=-1.0))
                    return self._reply(200, sessions.repos.refresh(bool(b.get("keys", False))))
                if parts == ["repos", "copy", "inspect"] and method == "POST":  # before /repos/<id>/<action>
                    return self._reply(200, sessions.repos.inspect_copy(str(self._body().get("path", ""))))
                if parts == ["repos", "copy", "remove"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.repos.remove_copy(str(b.get("path", "")), bool(b.get("confirmed", False))))
                if len(parts) == 3 and parts[0] == "repos" and method == "POST":
                    rid, act = parts[1], parts[2]
                    if act == "folder":
                        return self._reply(200, sessions.repos.set_folder(rid, str(self._body().get("path", ""))))
                    if act == "origin":
                        return self._reply(200, sessions.repos.set_origin(rid))
                    if act == "check":
                        return self._reply(200, sessions.repos.check(rid))
                    if act == "rotate":
                        return self._reply(200, sessions.repos.rotate(rid))
                    if act == "disconnect":
                        return self._reply(200, sessions.repos.disconnect(rid))
                    return self._reply(404, {"error": "not found"})
                if parts == ["keys"] and method == "GET":
                    return self._reply(200, sessions.keys_store.all())
                if parts == ["keys"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.keys_store.set(str(b.get("name", "")), str(b.get("value", ""))))
                if len(parts) == 2 and parts[0] == "keys" and method == "DELETE":
                    return self._reply(200, sessions.keys_store.delete(parts[1]))
                # the secrets vault (Loop 39): names, notes, dates and the journal; a value goes in, never out
                if parts == ["secrets"] and method == "GET":
                    return self._reply(200, sessions.vault.all())
                if parts == ["secrets"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.vault.set(str(b.get("name", "")), str(b.get("value", "")), str(b.get("note", ""))))
                if len(parts) == 3 and parts[0] == "secrets" and parts[2] == "note" and method == "POST":
                    try:
                        return self._reply(200, sessions.vault.note(parts[1], str(self._body().get("note", ""))))
                    except KeyError:
                        return self._reply(404, {"error": "no such secret"})
                if len(parts) == 2 and parts[0] == "secrets" and method == "DELETE":
                    return self._reply(200, sessions.vault.delete(parts[1]))
                if parts == ["voice", "transcribe"] and method == "POST":
                    import base64 as _b64
                    from . import voice
                    b = self._body()
                    wav = _b64.b64decode(str(b.get("audio_b64", "")) or b"")
                    key = "" if os.environ.get("AGMGD_VOICE_FAKE") else sessions.keys_store.get("openai")
                    return self._reply(200, voice.transcribe(wav, key, float(b.get("seconds", 0)), str(b.get("language", "")),
                                                             str(b.get("context", "")), bool(b.get("whole", False))))
                if parts == ["voice", "command"] and method == "POST":
                    from . import voice_commands
                    return self._reply(200, voice_commands.parse(str(self._body().get("text", "")), sessions.list()))
                if parts == ["host"] and method == "GET":  # the engine room: memory, disk, what each session weighs
                    from . import host
                    rep = host.report(sessions.store.all(), sessions.tmux.sessions())
                    watch = getattr(sessions, "host_watch", None)
                    last = watch.last if watch else {}
                    # the processor shares come from the last two readings: one look cannot tell them
                    rep["cpu"] = last.get("cpu")
                    rep["engine"] = last.get("engine", {})
                    for x in rep["sessions"]:
                        x["cpu"] = last.get("sessions", {}).get(str(x["id"]))
                    rep["history"] = watch.about() if watch else {}
                    return self._reply(200, rep)
                if parts == ["host", "history"] and method == "GET":  # the same, over time (Loop 36, the dashboard)
                    watch = getattr(sessions, "host_watch", None)
                    if watch is None:
                        return self._reply(200, {"off": True})
                    q = parse_qs(url.query)
                    try:
                        seconds, points = int(q.get("seconds", ["3600"])[0]), int(q.get("points", ["60"])[0])
                    except ValueError:
                        return self._reply(400, {"error": "seconds and points are whole numbers"})
                    return self._reply(200, watch.series(seconds, max(1, min(points, 600))))
                if parts == ["usage"] and method == "GET":
                    from . import usage
                    return self._reply(200, usage.report(sessions.store.history()))
                if parts == ["sandboxes"] and method == "GET":
                    over = sessions.sandboxes.overview()
                    names = {r["id"]: r["name"] for r in sessions.store.history()}   # a destroyed sandbox keeps its session's name
                    for row in over["inventory"]["sandboxes"]:
                        row["name"] = names.get(row["session_id"], "")
                    return self._reply(200, over)
                # Loop 38: a sandbox's lasting connection and its ports brought here (sandbox_carrier.py)
                if len(parts) >= 3 and parts[0] == "sandboxes" and parts[2] in ("tunnel", "ports", "socks", "back"):
                    carrier = getattr(sessions, "carrier", None)
                    if carrier is None:
                        return self._reply(503, {"error": "this engine was started without the carrier"})
                    sbid = parts[1]
                    if parts[2:] == ["tunnel"] and method == "GET":
                        link = carrier.describe(sbid)
                        if link["state"] == "open":
                            # what listens there and how it is doing, as last read (every five seconds); read now only
                            # the first time. Before, each look went to the sandbox twice over SSH.
                            health, listening = carrier.last_read(sbid)
                            if not health:
                                listening = carrier.listening(sbid)
                                health = carrier.health(sbid, sessions.sandboxes.get(sbid).get("workdir") or "/work")
                            link["listening"], link["health"] = listening, health
                        return self._reply(200, link)
                    if parts[2:] == ["tunnel", "connect"] and method == "POST":
                        return self._reply(200, carrier.connect(sbid))
                    if parts[2:] == ["tunnel", "disconnect"] and method == "POST":
                        return self._reply(200, carrier.disconnect(sbid))
                    if parts[2:] == ["socks", "open"] and method == "POST":   # a SOCKS proxy toward the sandbox, on this computer only
                        return self._reply(200, carrier.open_socks(sbid, int(self._body().get("local", 0) or 0)))
                    if parts[2:] == ["socks", "close"] and method == "POST":
                        return self._reply(200, carrier.close_socks(sbid))
                    if len(parts) == 5 and parts[2] == "back" and parts[3].isdigit() and method == "POST":
                        # a rule the owner makes: this port of this computer becomes reachable from inside the sandbox
                        if parts[4] == "open":
                            b = self._body()
                            return self._reply(200, carrier.open_back(sbid, int(parts[3]), int(b.get("there", 0) or 0), str(b.get("label", ""))))
                        if parts[4] == "close":
                            return self._reply(200, carrier.close_back(sbid, int(parts[3])))
                    if len(parts) == 5 and parts[2] == "ports" and parts[3].isdigit() and method == "POST":
                        port, act = int(parts[3]), parts[4]
                        if act == "open":
                            b = self._body()
                            return self._reply(200, carrier.open_port(sbid, port, int(b.get("local", 0) or 0), str(b.get("label", ""))))
                        if act == "close":
                            return self._reply(200, carrier.close_port(sbid, port))
                        if act in ("pause", "resume"):
                            return self._reply(200, carrier.pause_port(sbid, port, act == "pause"))
                if parts == ["sandboxes", "size"] and method == "POST":   # the size the next sandboxes get
                    return self._reply(200, sessions.sandboxes.choose_size(str(self._body().get("size", ""))))
                if parts == ["sandboxes", "budget"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.sandboxes.set_budget(float(b.get("monthly_usd", 0)), int(b.get("stop_idle_minutes", 0)),
                                                                          bool(b.get("stop_over_budget", False))))
                if parts == ["sandboxes", "stop-all"] and method == "POST":
                    return self._reply(200, {"stopped": sessions.sandboxes.stop_all()})
                if parts == ["sandboxes", "prepare"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.sandboxes.prepare_async(str(b.get("org", "")), str(b.get("region", "yyz"))))
                if len(parts) == 3 and parts[:2] == ["sandboxes", "orphans"] and method == "GET":
                    return self._reply(200, {"machines": sessions.sandboxes.orphan_contents(parts[2])})
                if parts == ["sandboxes", "orphans", "destroy"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.sandboxes.destroy_orphan(str(b.get("app", "")), str(b.get("machine", "")),
                                                                               bool(b.get("confirmed", False))))
                if len(parts) == 3 and parts[0] == "sandboxes":
                    sbid, act = parts[1], parts[2]
                    sbx = sessions.sandboxes
                    if act == "start" and method == "POST":
                        return self._reply(200, sbx.start(sbid))
                    if act == "stop" and method == "POST":
                        return self._reply(200, sbx.stop(sbid))
                    if act == "finish" and method == "POST":
                        sbx.mark_finished(sbid, bool(self._body().get("finished", True)))
                        return self._reply(200, sbx.get(sbid) | {"secret": ""})
                    if act == "unpushed" and method == "GET":
                        from .sandbox_ops import ssh_run
                        return self._reply(200, sbx.unpushed(sbid, lambda i, c: ssh_run(sbx, i, c)))
                    if act == "connection" and method == "GET":
                        from .sandbox_ops import health
                        rec = sessions.store.get(sbx.get(sbid)["session_id"]) or {}
                        return self._reply(200, health(sbx, sbid, bool(rec.get("brain_client"))))
                    if act == "destroy" and method == "POST":
                        out = sbx.destroy(sbid, bool(self._body().get("confirmed", False)), sessions.brain)
                        sessions.tmux.kill(sessions.tmux_name(out["session_id"]))
                        return self._reply(200, {k: v for k, v in out.items() if k != "secret"})
                if parts == ["brain", "keys"] and method == "GET":
                    return self._reply(200, {"keys": sessions.brain_keys()})
                if len(parts) == 4 and parts[:2] == ["brain", "keys"] and parts[3] == "revoke" and method == "POST":
                    return self._reply(200, sessions.revoke_brain_key(parts[2], bool(self._body().get("confirmed", False))))
                if parts == ["brain", "activity"] and method == "GET":
                    return self._reply(200, sessions.brain_activity())
                if parts == ["brain"] and method == "GET":
                    return self._reply(200, sessions.brain.status() if sessions.brain else {"connected": False, "reason": "off"})
                if parts == ["summaries"] and method == "GET":
                    from .sessions import host_path
                    cwd = os.path.expanduser(host_path(parse_qs(url.query).get("cwd", [""])[0]))
                    return self._reply(200, {"summaries": sessions.store.summaries(cwd=cwd)[:5]})
                if parts == ["history"] and method == "GET":
                    q = parse_qs(url.query).get("q", [""])[0]
                    return self._reply(200, {"sessions": sessions.history(q)})
                if parts == ["permissions"] and method == "GET":   # Loop 31: the Agent Permissions view
                    return self._reply(200, sessions.permissions_overview())
                if parts == ["claude-sandbox"] and method == "GET":   # Loop 30: can Claude Code's own sandbox run here?
                    return self._reply(200, sessions.native_sandbox())
                if parts == ["orchestrator"] and method == "GET":
                    from .sessions import MAX_RUNNING_CHILDREN, MAX_DEPTH
                    o = sessions.orchestrator()
                    kids = [sessions.describe(r) for r in sessions.descendants(o["id"])] if o else []
                    orc = sessions.orchestra
                    return self._reply(200, {"orchestrator": o, "sessions": kids,
                                             "caps": {"running": MAX_RUNNING_CHILDREN, "depth": MAX_DEPTH},
                                             "plan": orc.plan(), "rules": orc.rules(),
                                             "budget": {"daily_tokens": orc.budget(),
                                                        "used_today": sessions.orchestrated_tokens_today()}})
                if parts == ["orchestrator", "plan"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.orchestra.set_plan(str(b.get("goal", "")), b.get("tasks") or []))
                if len(parts) == 4 and parts[:2] == ["orchestrator", "tasks"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.orchestra.update_task(parts[2] if parts[3] == "update" else "", str(b.get("status", "")),
                                                                           str(b.get("session", "")), str(b.get("note", ""))))
                if parts == ["orchestrator", "rules"] and method == "POST":
                    return self._reply(200, {"rules": sessions.orchestra.set_rules(self._body().get("rules") or [])})
                if parts == ["orchestrator", "budget"] and method == "POST":
                    return self._reply(200, {"daily_tokens": sessions.orchestra.set_budget(int(self._body().get("daily_tokens", 0)))})
                if parts == ["orchestrator", "start"] and method == "POST":
                    b = self._body()
                    return self._reply(200, sessions.start_orchestrator(str(b.get("cwd", "~")), str(b.get("level", "auto")),
                                                                        str(b.get("model", ""))))
                if parts == ["orchestrator", "stop"] and method == "POST":
                    if not bool(self._body().get("confirmed", False)):
                        raise ValueError("stopping the orchestrator needs the owner's confirmation")
                    return self._reply(200, {"stopped": sessions.stop_orchestrator()})
                if parts == ["tree"] and method == "GET":
                    return self._reply(200, sessions.tree())
                if parts == ["groups"] and method == "POST":
                    name = str(self._body().get("name", "")).strip()
                    if not name or len(name) > 60:
                        raise ValueError("a group name of 1 to 60 characters")
                    sessions.store.add_group(name)
                    return self._reply(201, sessions.tree())
                if parts == ["groups", "order"] and method == "POST":
                    sessions.store.order_groups([str(n) for n in self._body().get("names", [])])
                    return self._reply(200, sessions.tree())
                if len(parts) == 3 and parts[0] == "groups" and method == "POST":
                    g, act, b = parts[1], parts[2], self._body()
                    from urllib.parse import unquote
                    g = unquote(g)
                    if act == "rename":
                        new = str(b.get("name", "")).strip()
                        if not new or len(new) > 60:
                            raise ValueError("a group name of 1 to 60 characters")
                        sessions.store.rename_group(g, new)
                    elif act == "level":
                        lv = str(b.get("level", ""))
                        if lv and lv not in ("ask", "edits", "auto", "full", "config"):
                            raise ValueError("level must be ask, edits, auto, full or config")
                        sessions.store.set_group_level(g, lv)
                    elif act == "access":
                        ac = str(b.get("access", ""))
                        if ac and ac not in ("open", "contained", "readonly"):
                            raise ValueError("access must be open, contained or readonly")
                        sessions.store.set_group_access(g, ac)
                    elif act == "fold":
                        sessions.store.fold_group(g, bool(b.get("folded", True)))
                    elif act == "delete":
                        sessions.store.delete_group(g)
                    else:
                        return self._reply(404, {"error": "not found"})
                    return self._reply(200, sessions.tree())
                if parts == ["sessions"] and method == "POST":
                    b = self._body()
                    return self._reply(201, sessions.create(str(b.get("name", "")), str(b.get("tool", "shell")),
                                                            str(b.get("cwd", "~")), str(b.get("group", "")),
                                                            int(b.get("width", 160)), int(b.get("height", 48)),
                                                            bool(b.get("worktree", False)), bool(b.get("brain", True)),
                                                            str(b.get("parent", "")), bool(b.get("brief", False)),
                                                            str(b.get("repo", "")), str(b.get("host", "local")),
                                                            (bool(b["remote"]) if "remote" in b else None), bool(b.get("document", False)),
                                                            str(b.get("level", "")), str(b.get("model", "")), "",
                                                            str(b.get("access", "")), b.get("extra_dirs") or [],
                                                            bool(b.get("os_sandbox", False))))
                if len(parts) >= 2 and parts[0] == "sessions":
                    sid = parts[1]
                    action = parts[2] if len(parts) > 2 else ""
                    if method == "GET" and action == "":
                        return self._reply(200, sessions.get(sid))
                    if method == "GET" and action == "attach":
                        return self._reply(200, {"command": sessions.attach_command(sid)})
                    if method == "GET" and action == "preview":
                        q = parse_qs(url.query)
                        return self._reply(200, {"text": sessions.preview(sid, int(q.get("lines", ["30"])[0]))})
                    if method == "POST" and action == "send":
                        b = self._body()
                        sessions.send(sid, str(b.get("text", "")), bool(b.get("enter", True)))
                        return self._reply(200, {"ok": True})
                    if method == "POST" and action == "ask":
                        b = self._body()
                        return self._reply(200, sessions.ask_owner(sid, str(b.get("question", "")), list(b.get("options") or [])))
                    if method == "POST" and action == "ready":
                        b = self._body()
                        return self._reply(200, sessions.ready_for_review(sid, str(b.get("by", "")), str(b.get("note", ""))))
                    if method == "POST" and action == "keys":
                        sessions.keys(sid, [str(k) for k in self._body().get("keys", [])])
                        return self._reply(200, {"ok": True})
                    if method == "POST" and action == "level":   # Loop 27: the owner, from the app
                        b = self._body()
                        return self._reply(200, sessions.set_level(sid, str(b.get("level", "")), str(b.get("when", "turn"))))
                    if method == "POST" and action == "permissions":   # Loop 28: level and git rights at once
                        b = self._body()
                        opt = lambda k: bool(b[k]) if k in b else None  # noqa: E731
                        return self._reply(200, sessions.set_permissions(sid, str(b.get("level", "")), opt("git_push"),
                                                                         opt("git_merge"), str(b.get("when", "turn")),
                                                                         str(b.get("access", "")),
                                                                         b["extra_dirs"] if isinstance(b.get("extra_dirs"), list) else None,
                                                                         opt("os_sandbox")))
                    if method == "GET" and action == "level":
                        return self._reply(200, {"log": sessions.level_log(sid)})
                    if method == "POST" and action == "resume":
                        return self._reply(200, sessions.resume(sid, str(self._body().get("conversation", ""))))
                    if method == "POST" and action == "fork":
                        b = self._body()
                        return self._reply(201, sessions.fork(sid, str(b.get("name", "")), str(b.get("conversation", ""))))
                    if method == "GET" and action == "diff":
                        q = parse_qs(url.query)
                        return self._reply(200, sessions.diff(sid, q.get("mode", ["uncommitted"])[0]))
                    if method == "GET" and action == "comments":
                        return self._reply(200, {"comments": sessions.store.comments(sid)})
                    if method == "POST" and action == "comments":
                        b = self._body()
                        sessions.get(sid)
                        text = str(b.get("text", "")).strip()
                        if not text or len(text) > 4000:
                            raise ValueError("a comment of 1 to 4000 characters")
                        cid = sessions.store.add_comment(sid, str(b.get("path", ""))[:500], int(b.get("line", 0)),
                                                         str(b.get("code", ""))[:500], text)
                        return self._reply(201, {"id": cid, "comments": sessions.store.comments(sid)})
                    if method == "POST" and action == "comment":
                        b = self._body()
                        cid = int(b.get("id", 0))
                        if b.get("delete"):
                            sessions.store.delete_comment(cid)
                        else:
                            st = str(b.get("status", ""))
                            if st and st not in ("open", "sent", "handled"):
                                raise ValueError("status: open, sent or handled")
                            sessions.store.set_comment(cid, status=st, text=str(b.get("text", "")))
                        return self._reply(200, {"comments": sessions.store.comments(sid)})
                    if method == "POST" and action == "review":
                        return self._reply(200, sessions.send_review(sid))
                    if method == "POST" and action == "wrapup":
                        return self._reply(200, sessions.wrap_up(sid, bool(self._body().get("archive", True))))
                    if method == "GET" and action == "summaries":
                        return self._reply(200, {"summaries": sessions.store.summaries(sid=sid)})
                    if method == "POST" and action == "archive":
                        return self._reply(200, sessions.archive(sid))
                    if method == "GET" and action == "conversations":
                        return self._reply(200, {"conversations": sessions.store.conversations(sid)})
                    if method == "GET" and action == "worktree":
                        return self._reply(200, sessions.worktree_status(sid))
                    if method == "POST" and action == "finish":
                        b = self._body()
                        return self._reply(200, sessions.finish(sid, bool(b.get("merge", False)), bool(b.get("delete_branch", False))))
                    if method == "POST" and action == "restart":
                        return self._reply(200, sessions.restart(sid))
                    if method == "POST" and action == "stop":
                        return self._reply(200, sessions.stop(sid))
                    if method == "POST" and action == "move":
                        b = self._body()
                        sessions.move(sid, str(b.get("group", "")), int(b.get("index", 0)))
                        return self._reply(200, sessions.tree())
                    if method == "POST" and action == "rename":
                        return self._reply(200, sessions.rename(sid, str(self._body().get("name", ""))))
                    if method == "DELETE" and action == "":
                        sessions.remove(sid)
                        return self._reply(200, {"ok": True})
                return self._reply(404, {"error": "not found"})
            except KeyError:
                return self._reply(404, {"error": "no such session"})
            except (ValueError, json.JSONDecodeError) as e:
                return self._reply(400, {"error": str(e)})
            except RuntimeError as e:
                return self._reply(500, {"error": str(e)})

        def _sandbox_brain(self, method: str, parts: list) -> None:
            """The Brain for a sandbox, through its reverse tunnel. Authenticated by the sandbox's own secret (in its
            URL), never by the engine's token; answers only for a live sandbox with a Brain key."""
            sb = sessions.sandboxes.by_secret(parts[1])
            if not sb or not sb["brain_client"] or not sessions.brain:
                return self._reply(404, {"error": "unknown sandbox"})
            if parts[2] == "health" and method == "GET":
                return self._reply(200, {"ok": True, "brain": sessions.brain.status().get("connected", False)})
            if parts[2] == "mcp" and method == "POST":
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(min(n, 4_000_000)) if n else b""
                res = sessions.brain.mcp_forward(sb["brain_client"], body, self.headers.get("Mcp-Session-Id", ""))
                data = str(res.get("text", "")).encode("utf-8")
                self.send_response(int(res.get("status", 502)) or 502)
                self.send_header("Content-Type", "application/json")
                if res.get("session"):
                    self.send_header("Mcp-Session-Id", res["session"])
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            return self._reply(404, {"error": "not found"})

        def do_GET(self):
            self._route("GET")

        def do_POST(self):
            self._route("POST")

        def do_DELETE(self):
            self._route("DELETE")

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(sessions: Sessions, token: str, port: int) -> Server:
    srv = Server(("127.0.0.1", port), make_handler(sessions, token))
    return srv


def port_free(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) != 0
