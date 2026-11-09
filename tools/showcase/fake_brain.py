#!/usr/bin/env python3
"""A stand-in Second Brain for the website screenshots: the few HTTP calls Agent Manager makes (/health, its MCP keys),
on 127.0.0.1, with a home folder laid out like the real Brain's. Nothing is read from or written to the owner's Brain.
  fake_brain.py <home> <repo> <port>      (runs until killed)
"""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

home, repo, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(os.path.join(home, "runtime"), exist_ok=True)
os.makedirs(os.path.join(repo, "engine", "mcp"), exist_ok=True)
with open(os.path.join(home, "runtime", "api_token"), "w") as f:
    f.write("showcase-only")
with open(os.path.join(home, "runtime", "server.json"), "w") as f:
    json.dump({"port": port}, f)
with open(os.path.join(home, "install_state.json"), "w") as f:
    json.dump({"venv_python": sys.executable}, f)
with open(os.path.join(repo, "engine", "mcp", "relay.py"), "w") as f:
    f.write("# showcase stand-in\n")

# one key nothing uses any more, so the Keys tab shows what « unused » looks like
clients = {"5e1f0c2a": {"id": "5e1f0c2a", "name": "Agent Manager · Spike: search", "created": "2026-10-02T10:12:00",
                        "last_seen": "2026-10-03T17:40:00", "calls": 41}}


def _new(name: str) -> dict:
    h = hashlib.sha1(name.encode()).hexdigest()
    return {"id": h[:8], "name": name, "created": "2026-10-14T09:00:00",
            "last_seen": "2026-10-14T16:%02d:00" % (int(h[8:10], 16) % 60), "calls": 3 + int(h[10:12], 16) % 60}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "version": "showcase"})
        if self.path == "/mcp/clients":
            return self._send(200, {"clients": list(clients.values())})
        self._send(404, {"error": "not here"})

    def do_POST(self):
        if self.path == "/mcp/clients":
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            c = _new(str(body.get("name", "client")))
            clients[c["id"]] = c
            return self._send(200, {"id": c["id"], "token": "showcase-only"})
        self._send(404, {"error": "not here"})

    def do_DELETE(self):
        cid = self.path.rsplit("/", 1)[-1]
        return self._send(200, {"ok": True}) if clients.pop(cid, None) else self._send(404, {"error": "unknown key"})


ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
