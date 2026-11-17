"""Loop 49a: the owner's MCP servers, added once, given to the sessions they choose.

Owner, 2026-11-15: « J'aimerais ça être capable de le brancher en MCP. C'est un MCP HTTPS sans authentification.
J'aimerais être capable de l'intégrer et de partir une session avec. Puis même que ça soit scalable ».

A server is either reached over HTTP (Streamable HTTP, the MCP transport: one URL) or started on this computer by a
command (stdio). Each one is given to the sessions where it is ticked, or to every new session when the owner says so.
Agent Manager's own servers (agent-manager, second-brain) are not in this list and their names are kept.

Nothing is sent anywhere when a server is added: only « Test » talks to it (initialize, then the lists of its tools
and prompts), and only when the owner asks. What a server answers is data, never instructions.
"""
from __future__ import annotations

import json
import re
import shlex
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing

NAME_OK = re.compile(r"^[a-z0-9][a-z0-9_-]{0,39}$")
RESERVED = {"agent-manager", "second-brain"}
PROTOCOL = "2025-06-18"
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS mcp_servers (
    name TEXT PRIMARY KEY,
    kind TEXT NOT NULL,              -- http or stdio
    url TEXT NOT NULL DEFAULT '',
    command TEXT NOT NULL DEFAULT '',
    args TEXT NOT NULL DEFAULT '[]',
    everywhere INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '',
    added REAL NOT NULL DEFAULT 0,
    last_test TEXT NOT NULL DEFAULT ''
);
"""


def check_url(url: str) -> str:
    """An https address, or http only on this computer (a server being developed): anything else is refused."""
    url = (url or "").strip()
    u = urllib.parse.urlparse(url)
    if u.scheme not in ("https", "http") or not u.hostname:
        raise ValueError("an address that starts with https:// (for example https://example.com/mcp)")
    if u.scheme == "http" and u.hostname not in LOCAL_HOSTS:
        raise ValueError("http:// only for a server on this computer (localhost); a server elsewhere needs https://")
    if u.username or u.password:
        raise ValueError("no login in the address: Agent Manager keeps no password in its list")
    return url


class McpCatalog:
    def __init__(self, path: str):
        self.path = path
        with closing(self._db()) as db, db:
            db.executescript(SCHEMA)

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    # ---------------------------------------------------------------- the list
    @staticmethod
    def _row(r: sqlite3.Row) -> dict:
        d = dict(r)
        d["args"] = json.loads(d.get("args") or "[]")
        d["everywhere"] = bool(d["everywhere"])
        d["last_test"] = json.loads(d["last_test"]) if d.get("last_test") else None
        d["remote"] = d["kind"] == "http" and urllib.parse.urlparse(d["url"]).hostname not in LOCAL_HOSTS
        return d

    def all(self) -> list[dict]:
        with closing(self._db()) as db:
            return [self._row(r) for r in db.execute("SELECT * FROM mcp_servers ORDER BY name")]

    def get(self, name: str) -> dict:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM mcp_servers WHERE name = ?", (name,)).fetchone()
        if not r:
            raise KeyError(name)
        return self._row(r)

    def names(self) -> set[str]:
        return {s["name"] for s in self.all()}

    def add(self, name: str, url: str = "", command: str = "", everywhere: bool = False, note: str = "") -> dict:
        name = (name or "").strip().lower()
        if not NAME_OK.match(name):
            raise ValueError("a name of 1 to 40 characters: lowercase letters, digits, - and _ (agents see mcp__<name>__…)")
        if name in RESERVED:
            raise ValueError(f"« {name} » is Agent Manager's own server: choose another name")
        if bool(url.strip()) == bool(command.strip()):
            raise ValueError("an address (a server over HTTPS) or a command (a server started on this computer), one of the two")
        if url.strip():
            kind, url, cmd, args = "http", check_url(url), "", []
        else:
            try:
                words = shlex.split(command)
            except ValueError as e:
                raise ValueError(f"the command cannot be read: {e}")
            kind, cmd, args = "stdio", words[0], words[1:]
        with closing(self._db()) as db, db:
            if db.execute("SELECT 1 FROM mcp_servers WHERE name = ?", (name,)).fetchone():
                raise ValueError(f"« {name} » is already in the list")
            db.execute("INSERT INTO mcp_servers (name, kind, url, command, args, everywhere, note, added) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       (name, kind, url, cmd, json.dumps(args), int(bool(everywhere)), (note or "").strip()[:200], time.time()))
        return self.get(name)

    def remove(self, name: str) -> None:
        self.get(name)
        with closing(self._db()) as db, db:
            db.execute("DELETE FROM mcp_servers WHERE name = ?", (name,))

    def set_everywhere(self, name: str, on: bool) -> dict:
        self.get(name)
        with closing(self._db()) as db, db:
            db.execute("UPDATE mcp_servers SET everywhere = ? WHERE name = ?", (int(bool(on)), name))
        return self.get(name)

    # ---------------------------------------------------------------- what a session gets
    def for_session(self, chosen: list[str]) -> dict:
        """The servers a session starts with: those ticked for it, and those given to every session."""
        out = {}
        for s in self.all():
            if s["everywhere"] or s["name"] in chosen:
                out[s["name"]] = {"type": "http", "url": s["url"]} if s["kind"] == "http" else \
                                 {"type": "stdio", "command": s["command"], "args": s["args"]}
        return out

    def for_cloud(self, chosen: list[str]) -> tuple[dict, list[str]]:
        """Loop 49b: what a session on a cloud machine starts with. Only the servers on the internet: one on this
        computer (localhost, or started by a command) is not on the machine, whose localhost is its own."""
        given, left = {}, []
        for s in self.all():
            if s["everywhere"] or s["name"] in chosen:
                if s["remote"]:
                    given[s["name"]] = {"type": "http", "url": s["url"]}
                else:
                    left.append(s["name"])
        return given, left

    def clean(self, chosen) -> list[str]:
        known = self.names()
        return [str(n) for n in dict.fromkeys(chosen or []) if str(n) in known]

    # ---------------------------------------------------------------- Test
    def test(self, name: str, timeout: float = 10.0) -> dict:
        """Talks to the server, on the owner's request: initialize, then what it offers. Kept as its last test."""
        s = self.get(name)
        if s["kind"] != "http":
            res = {"ok": False, "at": time.time(), "error": "a server started by a command is tested when a session starts it"}
        else:
            res = probe(s["url"], timeout)
        with closing(self._db()) as db, db:
            db.execute("UPDATE mcp_servers SET last_test = ? WHERE name = ?", (json.dumps(res), name))
        return self.get(name)


def _post(url: str, body: dict, headers: dict, timeout: float) -> tuple[int, dict, dict | None]:
    data = json.dumps(body).encode()
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
         "User-Agent": "agent-manager-gd", **headers}
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read(2_000_000).decode("utf-8", "replace")
        got = {k.lower(): v for k, v in r.headers.items()}
        status = r.status
    if not raw.strip():
        return status, got, None
    if "text/event-stream" in got.get("content-type", ""):
        # the answer as server-sent events: the JSON-RPC message is in a « data: » line
        for line in raw.splitlines():
            if line.startswith("data:"):
                try:
                    msg = json.loads(line[5:].strip())
                except ValueError:
                    continue
                if isinstance(msg, dict) and msg.get("id") == body.get("id"):
                    return status, got, msg
        return status, got, None
    return status, got, json.loads(raw)


def probe(url: str, timeout: float = 10.0) -> dict:
    """initialize, notifications/initialized, tools/list and prompts/list over Streamable HTTP."""
    t0 = time.monotonic()
    out = {"ok": False, "at": time.time(), "server": "", "version": "", "tools": [], "prompts": [], "ms": 0, "error": ""}
    try:
        _, h, init = _post(url, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                 "params": {"protocolVersion": PROTOCOL, "capabilities": {},
                                            "clientInfo": {"name": "agent-manager-gd", "version": "1"}}}, {}, timeout)
        out["ms"] = round((time.monotonic() - t0) * 1000)
        if not init or "result" not in init:
            out["error"] = "it did not answer as an MCP server: " + json.dumps((init or {}).get("error", "no answer"))[:200]
            return out
        info = init["result"].get("serverInfo") or {}
        out["server"], out["version"] = str(info.get("name", ""))[:80], str(info.get("version", ""))[:40]
        caps = init["result"].get("capabilities") or {}
        more = {"MCP-Protocol-Version": str(init["result"].get("protocolVersion") or PROTOCOL)}
        if h.get("mcp-session-id"):
            more["Mcp-Session-Id"] = h["mcp-session-id"]
        try:
            _post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, more, timeout)
        except urllib.error.HTTPError:
            pass
        for key, method, nid in (("tools", "tools/list", 2), ("prompts", "prompts/list", 3)):
            if key not in caps:
                continue
            _, _, got = _post(url, {"jsonrpc": "2.0", "id": nid, "method": method, "params": {}}, more, timeout)
            items = ((got or {}).get("result") or {}).get(key) or []
            out[key] = [{"name": str(i.get("name", ""))[:80], "description": str(i.get("description", ""))[:200]}
                        for i in items[:100] if isinstance(i, dict)]
        out["ok"] = True
    except urllib.error.HTTPError as e:
        out["error"] = f"HTTP {e.code} {e.reason}"
    except (urllib.error.URLError, OSError) as e:
        out["error"] = "unreachable: " + str(getattr(e, "reason", e))[:200]
    except ValueError as e:
        out["error"] = "an answer that is not JSON: " + str(e)[:120]
    out["ms"] = out["ms"] or round((time.monotonic() - t0) * 1000)
    return out
