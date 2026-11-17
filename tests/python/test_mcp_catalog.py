"""Loop 49a: the owner's MCP servers (owner, 2026-11-15: « J'aimerais ça être capable de le brancher en MCP. C'est un
MCP HTTPS sans authentification… de partir une session avec »). A stand-in MCP server over Streamable HTTP answers
the Test; fake Claude Code and Codex show what a session is given."""
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from engine.mcp_catalog import McpCatalog, check_url, probe
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux
from tests.python.test_history import FAKE


class StandIn(BaseHTTPRequestHandler):
    """A small MCP server: initialize in JSON with a session id, tools/list as server-sent events, prompts in JSON."""
    seen = []
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
        StandIn.seen.append((msg.get("method"), self.headers.get("Mcp-Session-Id"), self.headers.get("Accept")))
        if self.path != "/mcp":
            return self._send(404, b"", "text/plain")
        m = msg.get("method")
        if m == "notifications/initialized":
            return self._send(202, b"", "text/plain")
        if m == "initialize":
            body = {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2025-06-18", "serverInfo": {"name": "loop0", "version": "2.3"},
                                                                  "capabilities": {"tools": {}, "prompts": {}}}}
            return self._send(200, json.dumps(body).encode(), "application/json", {"Mcp-Session-Id": "abc"})
        if m == "tools/list":
            body = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [{"name": "loop0_guide", "description": "The method"},
                                                                            {"name": "render_mission", "description": "A mission"}]}}
            return self._send(200, b"event: message\ndata: " + json.dumps(body).encode() + b"\n\n", "text/event-stream")
        if m == "prompts/list":
            body = {"jsonrpc": "2.0", "id": msg["id"], "result": {"prompts": [{"name": "start", "description": "Loop 0 from an idea"}]}}
            return self._send(200, json.dumps(body).encode(), "application/json")
        self._send(400, b"{}", "application/json")

    def _send(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-mcp-")
        self.c = McpCatalog(os.path.join(self.tmp, "s.sqlite3"))
        StandIn.seen = []
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), StandIn)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}/mcp"

    def tearDown(self):
        self.srv.shutdown()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_addresses_https_or_this_computer_and_names_agents_can_call(self):
        self.assertEqual(check_url("https://loop0.example/mcp"), "https://loop0.example/mcp")
        self.assertEqual(check_url("http://localhost:3000/mcp"), "http://localhost:3000/mcp")
        for bad in ("http://loop0.example/mcp", "ftp://x/mcp", "https://user:pw@x/mcp", "loop0.example/mcp"):
            with self.assertRaises(ValueError, msg=bad):
                check_url(bad)
        for bad in ("Loop 0", "", "second-brain", "agent-manager", "x" * 41):
            with self.assertRaises(ValueError, msg=bad):
                self.c.add(bad, url="https://x.example/mcp")
        with self.assertRaises(ValueError):
            self.c.add("both", url="https://x.example/mcp", command="npx thing")
        s = self.c.add("loop0", url="https://loop0.example/mcp", note="Loop 0 method")
        self.assertEqual((s["kind"], s["remote"], s["everywhere"], s["last_test"]), ("http", True, False, None))
        with self.assertRaises(ValueError):
            self.c.add("loop0", url="https://other.example/mcp")
        t = self.c.add("files", command="npx -y @modelcontextprotocol/server-filesystem '/home/me/My docs'")
        self.assertEqual((t["kind"], t["command"], t["args"]), ("stdio", "npx", ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/My docs"]))
        self.assertEqual([x["name"] for x in self.c.all()], ["files", "loop0"])

    def test_a_session_gets_the_servers_ticked_for_it_and_those_given_to_everyone(self):
        self.c.add("loop0", url="https://loop0.example/mcp")
        self.c.add("files", command="npx files-server")
        self.assertEqual(self.c.for_session([]), {})
        self.assertEqual(self.c.for_session(["loop0"]), {"loop0": {"type": "http", "url": "https://loop0.example/mcp"}})
        self.c.set_everywhere("files", True)
        self.assertEqual(set(self.c.for_session([])), {"files"})
        self.assertEqual(self.c.for_session([])["files"], {"type": "stdio", "command": "npx", "args": ["files-server"]})
        self.assertEqual(self.c.clean(["loop0", "gone", "loop0"]), ["loop0"])

    def test_test_talks_mcp_and_keeps_what_the_server_offers(self):
        self.c.add("loop0", url=self.url)
        before = list(StandIn.seen)
        self.assertEqual(before, [])                                     # adding sends nothing
        s = self.c.test("loop0")
        t = s["last_test"]
        self.assertTrue(t["ok"], t)
        self.assertEqual((t["server"], t["version"]), ("loop0", "2.3"))
        self.assertEqual([x["name"] for x in t["tools"]], ["loop0_guide", "render_mission"])   # read from server-sent events
        self.assertEqual([x["name"] for x in t["prompts"]], ["start"])
        self.assertEqual([m for m, _, _ in StandIn.seen], ["initialize", "notifications/initialized", "tools/list", "prompts/list"])
        self.assertEqual([sid for _, sid, _ in StandIn.seen], [None, "abc", "abc", "abc"])     # its session id is sent back
        self.assertIn("text/event-stream", StandIn.seen[0][2])
        self.assertEqual(self.c.get("loop0")["last_test"]["tools"][0]["name"], "loop0_guide")  # kept

    def test_an_unreachable_or_wrong_server_is_said_plainly(self):
        bad = probe(self.url.replace("/mcp", "/nothing"), timeout=3)
        self.assertEqual((bad["ok"], bad["error"]), (False, "HTTP 404 Not Found"))
        self.srv.shutdown()
        self.srv.server_close()
        gone = probe(self.url, timeout=3)
        self.assertFalse(gone["ok"])
        self.assertTrue(gone["error"].startswith("unreachable"))


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class SessionsGetTheirServersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-mcps-")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        for tool in ("claude", "codex"):
            with open(os.path.join(bin_dir, tool), "w") as f:
                f.write(FAKE)
            os.chmod(os.path.join(bin_dir, tool), 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = bin_dir + os.pathsep + self.old_path
        self.tmux = Tmux("agmgd-mcps", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)
        self.s.mcp.add("loop0", url="https://loop0.example/mcp")

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def config(self, sid):
        path = os.path.join(self.tmp, "sessions", sid, "mcp.json")
        end = time.monotonic() + 5
        while not os.path.exists(path) and time.monotonic() < end:
            time.sleep(0.05)
        with open(path) as f:
            return json.load(f)["mcpServers"]

    def test_claude_code_starts_with_loop0_only_where_it_is_ticked(self):
        with_it = self.s.create("New idea", "claude", self.tmp, mcps=["loop0"])
        without = self.s.create("Other", "claude", self.tmp)
        self.assertEqual(with_it["mcps"], ["loop0"])
        self.assertEqual(self.config(with_it["id"])["loop0"], {"type": "http", "url": "https://loop0.example/mcp"})
        self.assertEqual(self.config(with_it["id"])["agent-manager"]["type"], "stdio")         # its own servers still there
        self.assertNotIn("loop0", self.config(without["id"]))
        with self.assertRaises(ValueError):
            self.s.create("Typo", "claude", self.tmp, mcps=["lopo0"])
        # ticked afterwards: from its next start
        self.assertEqual(self.s.set_mcps(without["id"], ["loop0"]), {"id": without["id"], "mcps": ["loop0"], "from": "its next start"})
        self.s.restart(without["id"])
        self.assertIn("loop0", self.config(without["id"]))

    def test_an_mcp_prompt_as_first_message_is_typed_once_the_servers_are_there(self):
        # Claude Code reads a command-line prompt before its MCP servers connect: « Unknown command » (seen 2026-11-16).
        slow = os.path.join(self.tmp, "bin", "claude")
        with open(slow, "w") as f:
            f.write("""#!/usr/bin/env python3
import json, os, sys, time
start = time.monotonic()
print("ARGS", sys.argv[1:], flush=True)
time.sleep(0.5)
os.makedirs(os.path.join(os.environ["AGMGD_HOME"], "state"), exist_ok=True)
with open(os.path.join(os.environ["AGMGD_HOME"], "state", os.environ["AGMGD_SESSION"] + ".json"), "w") as f:
    json.dump({"state": "idle", "time": time.time()}, f)
for line in sys.stdin:
    if time.monotonic() - start < 3.0:
        print("Unknown command: " + line.split()[0], flush=True)
    else:
        print("RAN " + line.strip(), flush=True)
""")
        os.chmod(slow, 0o755)
        self.s.FIRST_SETTLE_S, self.s.FIRST_RETRY_S = 0.3, 0.8
        d = self.s.create("Idea", "claude", self.tmp, mcps=["loop0"], first='/mcp__loop0__start "a habit tracker"')
        end = time.monotonic() + 15
        while "RAN" not in self.s.preview(d["id"], 40) and time.monotonic() < end:
            time.sleep(0.2)
        screen = self.s.preview(d["id"], 40)
        self.assertNotIn("mcp__loop0__start", screen.split("ARGS")[1].splitlines()[0])   # not on its command line
        self.assertIn('RAN /mcp__loop0__start "a habit tracker"', screen)               # typed once it was ready
        self.assertEqual(screen.count("RAN "), 1)                                       # and not again after
        plain = self.s.create("Plain", "claude", self.tmp, first="Read the README")
        time.sleep(0.6)
        self.assertIn("Read the README", self.s.preview(plain["id"], 40).split("ARGS")[1].splitlines()[0])   # words: on its command line

    def test_given_to_every_session_and_codex_reaches_it_by_its_url(self):
        self.s.mcp.set_everywhere("loop0", True)
        d = self.s.create("Codex", "codex", self.tmp)
        flags = self.s._codex_mcp(self.s.store.get(d["id"]))
        self.assertIn('mcp_servers.loop0.url="https://loop0.example/mcp"', flags)
        self.assertNotIn("mcp_servers.loop0.command", " ".join(flags))
        self.assertIn("mcp_servers.agent-manager.command", " ".join(flags))


if __name__ == "__main__":
    unittest.main()
