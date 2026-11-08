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
            if n > 1_000_000:
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
            if not self._authorised():
                return self._reply(401, {"error": "unauthorised"})
            try:
                if parts == ["tools"] and method == "GET":
                    return self._reply(200, {k: v["label"] for k, v in TOOLS.items()})
                if parts == ["sessions"] and method == "GET":
                    return self._reply(200, {"sessions": sessions.list()})
                if parts == ["brain"] and method == "GET":
                    return self._reply(200, sessions.brain.status() if sessions.brain else {"connected": False, "reason": "off"})
                if parts == ["summaries"] and method == "GET":
                    from .sessions import host_path
                    cwd = os.path.expanduser(host_path(parse_qs(url.query).get("cwd", [""])[0]))
                    return self._reply(200, {"summaries": sessions.store.summaries(cwd=cwd)[:5]})
                if parts == ["history"] and method == "GET":
                    q = parse_qs(url.query).get("q", [""])[0]
                    return self._reply(200, {"sessions": sessions.history(q)})
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
                                                            str(b.get("parent", "")), bool(b.get("brief", False))))
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
                    if method == "POST" and action == "keys":
                        sessions.keys(sid, [str(k) for k in self._body().get("keys", [])])
                        return self._reply(200, {"ok": True})
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
