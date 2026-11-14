#!/usr/bin/env python3
"""A stand-in Second Brain for the website screenshots: the few HTTP calls Agent Manager makes (/health, its MCP keys),
on 127.0.0.1, with a home folder laid out like the real Brain's. Nothing is read from or written to the owner's Brain.
  fake_brain.py <home> <repo> <port>      (runs until killed)
"""
import hashlib
import json
import os
import sys
import time
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


def _iso(t: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))


# what the sessions proposed (by key name), newest first: [title, status, minutes ago]
PROPOSED = {"Checkout flow": [["Decision · gift cards never go above their balance", "applied", 4],
                              ["Session journal · acme-store", "pending", 1],
                              ["Expert · Frontend · check a checkout at phone width before calling it done", "applied", 30],
                              ["Expert · Frontend · keep focus rings: keyboard users pay with them", "applied", 95]],
            "Sparks": [["Session journal · pixel-forge", "applied", 9]],
            "Docs refresh": [["Owner wish · README in plain words", "applied", 22]]}


def _proposals() -> list:
    out = []
    for c in clients.values():
        for title, status, ago in PROPOSED.get(c["name"].replace("Agent Manager · ", ""), []):
            out.append({"id": hashlib.sha1(title.encode()).hexdigest()[:10], "client_id": c["id"], "client_name": c["name"],
                        "kind": "item", "status": status, "created_at": _iso(time.time() - ago * 60), "payload": {"title": title}})
    return sorted(out, key=lambda p: p["created_at"], reverse=True)


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
            for c in clients.values():  # the sessions' keys were used a moment ago
                if c["id"] != "5e1f0c2a":
                    c["last_seen"] = _iso(time.time() - 40 - int(c["id"][:2], 16))
            return self._send(200, {"clients": list(clients.values())})
        if self.path.startswith("/mcp/proposals"):
            return self._send(200, {"proposals": _proposals()})
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
