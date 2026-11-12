"""The carrier: a sandbox's lasting connection and its ports brought here. No SSH server and no Fly.io: stand-ins
for `ssh` and `flyctl` (tests/python/standins), and a web server of this computer that stands for one in a sandbox.
The two readings (what listens, how the sandbox is doing) are parsed from texts in the shape the real commands
gave on a real Linux (ss -Hltnp, /proc, df), taken on 2026-11-12."""
import http.server
import os
import shutil
import tempfile
import threading
import time
import unittest
import urllib.request
from types import SimpleNamespace

from engine.relay import Relay
from engine.sandbox_carrier import Carrier, parse_health, parse_listening

HERE = os.path.dirname(os.path.abspath(__file__))
SS = """LISTEN 0      4096       127.0.0.54:53         0.0.0.0:*
LISTEN 0      128           0.0.0.0:2222       0.0.0.0:*    users:(("sshd",pid=41,fd=3))
LISTEN 0      128              [::]:2222          [::]:*    users:(("sshd",pid=41,fd=4))
LISTEN 0      5           127.0.0.1:8765       0.0.0.0:*    users:(("sshd",pid=77,fd=9))
LISTEN 0      511           0.0.0.0:8501       0.0.0.0:*    users:(("streamlit",pid=412,fd=6))
LISTEN 0      5           127.0.0.1:%d       0.0.0.0:*    users:(("python3",pid=500,fd=3))
"""
HEALTH = """MemTotal:        1009636 kB
MemFree:          211208 kB
MemAvailable:     604580 kB
---
0.42 0.31 0.12 1/97 2231
---
5123.40 9001.11
---
Filesystem      1-blocks       Used  Available Capacity Mounted on
/dev/vdb     8350298112 2147483648 5771362304      28% /
"""


class Page(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        body = b"<title>Sales, this week</title>"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FakeSandboxes:
    def __init__(self, home):
        self.home = home
        self.state = "started"
        self.destroyed = 0
        self.fly = SimpleNamespace(env=lambda: dict(os.environ))

    def get(self, sbid):
        return {"id": sbid, "machine": "m-1", "app": "agmgd-test", "destroyed": self.destroyed}

    def key_path(self, sbid):
        return os.path.join(self.home, "keys", "sandbox-" + sbid, "id_ed25519")

    def machines(self):
        return [{"id": "m-1", "state": self.state}]


class ParsingTest(unittest.TestCase):
    def test_what_listens_in_a_sandbox(self):
        rows = parse_listening(SS % 8000)
        self.assertEqual([(r["port"], r["program"], r["inside"]) for r in rows],
                         [(53, "", True), (8000, "python3", True), (8501, "streamlit", False)])   # our own two ports are left out
        self.assertEqual(parse_listening("nothing of the kind\n"), [])

    def test_how_a_sandbox_is_doing(self):
        h = parse_health(HEALTH)
        self.assertEqual((h["memory_total"], h["memory_used"]), (1009636 * 1024, (1009636 - 604580) * 1024))
        self.assertEqual((h["load"], h["uptime"]), (0.42, 5123.40))
        self.assertEqual((h["disk_total"], h["disk_free"]), (8350298112, 5771362304))
        self.assertEqual(parse_health("")["memory_total"], 0)     # an answer that did not come says nothing, and breaks nothing


class CarrierTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-carrier-")
        self.web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        threading.Thread(target=self.web.serve_forever, daemon=True).start()
        self.inside = self.web.server_address[1]          # « a port of the sandbox »
        for name, text in (("ss.txt", SS % self.inside), ("health.txt", HEALTH)):
            with open(os.path.join(self.tmp, name), "w") as f:
                f.write(text)
        os.environ["STANDIN_SS"] = os.path.join(self.tmp, "ss.txt")
        os.environ["STANDIN_HEALTH"] = os.path.join(self.tmp, "health.txt")
        os.environ["STANDIN_HOST_KEY"] = "key-one"
        os.environ.pop("STANDIN_UNREACHABLE", None)
        self.sbx = FakeSandboxes(self.tmp)
        self.relay = Relay()
        self.carrier = Carrier(self.sbx, self.relay, self.tmp, ssh=os.path.join(HERE, "standins", "ssh"), flyctl=os.path.join(HERE, "standins", "flyctl"))

    def tearDown(self):
        self.carrier.close_all()
        self.relay.close_all()
        self.web.shutdown()
        self.web.server_close()
        for k in ("STANDIN_SS", "STANDIN_HEALTH", "STANDIN_HOST_KEY", "STANDIN_UNREACHABLE"):
            os.environ.pop(k, None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_paused_sandbox_is_never_started_by_a_connection(self):
        self.sbx.state = "stopped"
        with self.assertRaises(ValueError) as e:
            self.carrier.connect("sb1")
        self.assertIn("never starts it", str(e.exception))
        self.assertEqual(self.carrier.describe("sb1")["state"], "closed")
        self.sbx.destroyed = 1
        with self.assertRaises(ValueError):
            self.carrier.connect("sb1")

    def test_a_port_of_the_sandbox_is_brought_here_counted_paused_and_closed(self):
        link = self.carrier.connect("sb1")
        self.assertEqual((link["state"], link["ports"]), ("open", []))
        self.assertEqual(self.carrier.connect("sb1")["state"], "open")           # asked again: the same connection
        seen = {r["port"]: r for r in self.carrier.listening("sb1")}
        self.assertEqual((seen[self.inside]["program"], seen[self.inside]["open"], seen[8501]["open"]), ("python3", False, False))
        self.assertNotIn(2222, seen)
        opened = self.carrier.open_port("sb1", self.inside, label="dashboard")
        self.assertEqual((opened["remote_port"], opened["state"], opened["label"]), (self.inside, "open", "dashboard"))
        self.assertNotEqual(opened["port"], self.inside)                           # here that number is the stand-in's own: the next free one
        with urllib.request.urlopen(opened["address"] + "/", timeout=10) as r:
            self.assertEqual(r.read(), b"<title>Sales, this week</title>")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.carrier.describe("sb1")["received"] == 0:
            time.sleep(0.05)
        now = self.carrier.describe("sb1")
        self.assertEqual(len(now["ports"]), 1)
        self.assertGreater(now["received"], 30)                                    # the page and its headers, counted
        self.assertGreater(now["sent"], 0)
        self.assertTrue({r["port"]: r for r in self.carrier.listening("sb1")}[self.inside]["open"])
        self.assertEqual(self.carrier.open_port("sb1", self.inside)["port"], opened["port"])   # asked again: the same one
        self.assertEqual(self.carrier.pause_port("sb1", self.inside)["state"], "paused")
        with self.assertRaises(OSError):
            urllib.request.urlopen(opened["address"] + "/", timeout=5).read()
        self.assertEqual(self.carrier.pause_port("sb1", self.inside, False)["state"], "open")
        closed = self.carrier.close_port("sb1", self.inside)
        self.assertEqual((closed["state"], closed["remote_port"]), ("closed", self.inside))
        self.assertEqual(self.carrier.describe("sb1")["ports"], [])
        with self.assertRaises(ValueError):
            self.carrier.open_port("sb1", 2222)                                    # our own ports are not ones to open

    def test_how_the_sandbox_is_doing_is_read_through_the_connection(self):
        self.carrier.connect("sb1")
        h = self.carrier.health("sb1")
        self.assertEqual((h["memory_total"], h["load"], h["disk_free"]), (1009636 * 1024, 0.42, 5771362304))
        self.assertGreaterEqual(h["round_trip_ms"], 0)

    def test_closing_the_connection_closes_what_it_opened(self):
        self.carrier.connect("sb1")
        opened = self.carrier.open_port("sb1", self.inside)
        self.assertEqual(self.carrier.disconnect("sb1")["state"], "closed")
        with self.assertRaises(OSError):
            urllib.request.urlopen(opened["address"] + "/", timeout=3).read()
        with self.assertRaises(ValueError):
            self.carrier.listening("sb1")
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "runtime", "carrier-sb1.sock.pid")))

    def test_the_host_key_is_remembered_and_a_changed_one_refuses(self):
        self.carrier.connect("sb1")
        known = os.path.join(self.tmp, "keys", "sandbox-sb1", "known_hosts")
        self.assertIn("sandbox-sb1 ", open(known).read())                          # remembered under the sandbox's own name
        self.carrier.disconnect("sb1")
        self.assertEqual(self.carrier.connect("sb1")["state"], "open")            # the same key: it opens again
        self.carrier.disconnect("sb1")
        os.environ["STANDIN_HOST_KEY"] = "another-key"
        with self.assertRaises(ValueError) as e:
            self.carrier.connect("sb1")
        self.assertIn("host key is not the one remembered", str(e.exception))
        self.assertEqual(self.carrier.describe("sb1")["state"], "closed")


class RoutesTest(unittest.TestCase):
    """The same, asked of the engine's local API as the app will."""

    def test_the_routes_open_a_port_and_tell_what_passes(self):
        import json
        from engine.api import load_token, serve
        tmp = tempfile.mkdtemp(prefix="agmgd-carrier-api-")
        web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        threading.Thread(target=web.serve_forever, daemon=True).start()
        inside = web.server_address[1]
        for name, text in (("ss.txt", SS % inside), ("health.txt", HEALTH)):
            with open(os.path.join(tmp, name), "w") as f:
                f.write(text)
        os.environ.update(STANDIN_SS=os.path.join(tmp, "ss.txt"), STANDIN_HEALTH=os.path.join(tmp, "health.txt"), STANDIN_HOST_KEY="key-one")
        sbx = FakeSandboxes(tmp)
        sbx.get = lambda sbid: {"id": sbid, "machine": "m-1", "app": "agmgd-test", "destroyed": 0, "workdir": "/work"}
        carrier = Carrier(sbx, Relay(), tmp, ssh=os.path.join(HERE, "standins", "ssh"), flyctl=os.path.join(HERE, "standins", "flyctl"))
        sessions = SimpleNamespace(carrier=carrier, sandboxes=sbx)
        token = load_token(tmp)
        srv = serve(sessions, token, 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()

        def call(method, path, body=None):
            req = urllib.request.Request(f"http://127.0.0.1:{srv.server_address[1]}{path}", method=method,
                                         data=json.dumps(body).encode() if body is not None else (b"{}" if method == "POST" else None))
            req.add_header("Authorization", "Bearer " + token)
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        try:
            self.assertEqual(call("GET", "/sandboxes/sb1/tunnel")["state"], "closed")
            self.assertEqual(call("POST", "/sandboxes/sb1/tunnel/connect")["state"], "open")
            opened = call("POST", f"/sandboxes/sb1/ports/{inside}/open", {"label": "dashboard"})
            with urllib.request.urlopen(opened["address"] + "/", timeout=10) as r:
                self.assertIn(b"Sales", r.read())
            time.sleep(0.3)
            link = call("GET", "/sandboxes/sb1/tunnel")
            self.assertEqual((link["state"], link["ports"][0]["label"], link["ports"][0]["remote_port"]), ("open", "dashboard", inside))
            self.assertGreater(link["received"], 30)
            self.assertEqual(link["health"]["load"], 0.42)
            self.assertTrue({r["port"]: r for r in link["listening"]}[inside]["open"])
            self.assertEqual(call("POST", f"/sandboxes/sb1/ports/{inside}/pause")["state"], "paused")
            self.assertEqual(call("POST", f"/sandboxes/sb1/ports/{inside}/resume")["state"], "open")
            self.assertEqual(call("POST", f"/sandboxes/sb1/ports/{inside}/close")["state"], "closed")
            self.assertEqual(call("POST", "/sandboxes/sb1/tunnel/disconnect")["state"], "closed")
        finally:
            carrier.close_all()
            srv.shutdown()
            srv.server_close()
            web.shutdown()
            web.server_close()
            for k in ("STANDIN_SS", "STANDIN_HEALTH", "STANDIN_HOST_KEY"):
                os.environ.pop(k, None)
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
