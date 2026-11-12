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
import urllib.error
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

    def _db(self):
        import sqlite3
        return sqlite3.connect(os.path.join(self.home, "s.sqlite3"), timeout=5)

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


class MoreTest(CarrierTest):
    """What was added after reading how another tunnel manager does it: a fallen connection comes back by itself,
    a failure says its family, what was open is remembered; then a SOCKS proxy, and a rule that lets the sandbox
    reach a port of this computer."""

    def fetch(self, address):
        with urllib.request.urlopen(address + "/", timeout=10) as r:
            return r.read()

    def until(self, check, sec=8.0):
        """Waits for a count to be written down: a byte is counted once it was handed on, a moment after the page
        is here; a fixed wait is too short when the computer is busy."""
        end = time.monotonic() + sec
        while time.monotonic() < end:
            if check():
                return True
            time.sleep(0.05)
        return False

    def test_a_failure_says_its_family(self):
        from engine.sandbox_carrier import reason
        self.assertIn("host key is not the one remembered", reason("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"))
        self.assertIn("refused the key", reason("root@127.0.0.1: Permission denied (publickey)."))
        self.assertIn("SSH server is not up", reason("ssh: connect to host 127.0.0.1 port 40123: Connection refused"))
        self.assertIn("private network is not reached", reason("ssh: Could not resolve hostname x.vm.app.internal"))
        self.assertIn("did not answer in time", reason("ssh: connect to host 127.0.0.1 port 1: Connection timed out"))
        self.assertIn("already taken on the other side", reason("Error: remote port forwarding failed for listen port 5432"))
        self.assertEqual(reason(""), "the sandbox did not answer")
        os.environ["STANDIN_UNREACHABLE"] = "1"                       # the stand-in refuses as a sandbox still starting would
        with self.assertRaises(ValueError) as e:
            self.carrier.connect("sb1")
        self.assertIn("SSH server is not up", str(e.exception))

    def test_what_was_open_comes_back_with_the_connection_on_the_same_address(self):
        self.carrier.connect("sb1")
        first = self.carrier.open_port("sb1", self.inside, label="dashboard")
        self.assertEqual(self.carrier.remembered("sb1"), [{"kind": "in", "port": self.inside, "local": first["port"], "label": "dashboard"}])
        self.carrier.disconnect("sb1")
        again = self.carrier.connect("sb1")                            # nothing asked: the port is there again
        self.assertEqual([(p["remote_port"], p["port"], p["label"]) for p in again["ports"]], [(self.inside, first["port"], "dashboard")])
        self.assertIn(b"Sales", self.fetch(first["address"]))          # the same address: a bookmark keeps working
        self.carrier.close_port("sb1", self.inside)                    # closed by hand: not opened again by itself
        self.carrier.disconnect("sb1")
        self.assertEqual(self.carrier.connect("sb1")["ports"], [])

    def test_a_connection_that_falls_comes_back_by_itself(self):
        import signal
        from engine import sandbox_carrier
        self.carrier.connect("sb1")
        opened = self.carrier.open_port("sb1", self.inside)
        pid = int(open(os.path.join(self.tmp, "runtime", "carrier-sb1.sock.pid")).read())
        os.kill(pid, signal.SIGKILL)                                   # the connection falls, as when the network drops
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.carrier.links["sb1"]["master"].poll() is None:
            time.sleep(0.05)
        old = sandbox_carrier.RETRY
        sandbox_carrier.RETRY = (3600.0, 0.0, 0.0, 0.0)               # the first try comes later; the next ones at once
        try:
            self.assertEqual(self.carrier.watch_once(), [])            # seen as fallen: what it carried is closed, and it is said
            lost = self.carrier.describe("sb1")
            self.assertEqual((lost["state"], lost["why"], lost["tries"]), ("lost", "the connection fell", 0))
            self.assertGreater(lost["retry_in"], 3000)
            with self.assertRaises(OSError):
                self.fetch(opened["address"])
            self.carrier.lost["sb1"]["next"] = 0.0                     # its time has come
            self.sbx.state = "stopped"                                 # paused meanwhile: tried, never started
            self.assertEqual(self.carrier.watch_once(), [])
            self.assertIn("never starts it", self.carrier.describe("sb1")["why"])
            self.sbx.state = "started"
            self.assertEqual(self.carrier.watch_once(), ["sb1"])       # back, with what it carried
        finally:
            sandbox_carrier.RETRY = old
        self.assertEqual(self.carrier.describe("sb1")["state"], "open")
        self.assertIn(b"Sales", self.fetch(opened["address"]))
        self.carrier.disconnect("sb1")                                 # closed by the owner: nothing tries again
        self.assertEqual((self.carrier.watch_once(), self.carrier.describe("sb1")["state"]), ([], "closed"))

    def test_two_sandboxes_with_the_same_port_each_get_their_own_address_here(self):
        self.carrier.connect("sb1")
        self.carrier.connect("sb2")
        from engine.sandbox_carrier import free_port
        wished = free_port()
        one = self.carrier.open_port("sb1", self.inside, wished, "dashboard")
        two = self.carrier.open_port("sb2", self.inside, wished, "dashboard")
        self.assertEqual(one["port"], wished)                          # the first keeps the number asked for
        self.assertGreater(two["port"], wished)                        # the second takes the next free one
        self.assertIn(b"Sales", self.fetch(one["address"]))
        self.assertIn(b"Sales", self.fetch(two["address"]))
        self.assertTrue(self.until(lambda: self.carrier.describe("sb1")["received"] > 30))   # each counted on its own
        self.assertTrue(self.until(lambda: self.carrier.describe("sb2")["received"] > 30))
        self.assertEqual(self.carrier.remembered("sb2")[0]["local"], two["port"])   # and each keeps its address next time
        self.carrier.disconnect("sb1")
        self.assertIn(b"Sales", self.fetch(two["address"]))            # closing one leaves the other

    def test_a_socks_proxy_reaches_what_is_inside_through_one_address(self):
        import socket
        import struct
        self.carrier.connect("sb1")
        proxy = self.carrier.open_socks("sb1", local=0)
        self.assertEqual((proxy["kind"], proxy["label"]), ("socks", "SOCKS proxy"))
        self.assertTrue(proxy["address"].startswith("socks5://127.0.0.1:"))
        with socket.create_connection(("127.0.0.1", proxy["port"]), timeout=10) as s:   # as a browser set on that proxy does
            s.sendall(b"\x05\x01\x00")
            self.assertEqual(s.recv(2), b"\x05\x00")
            s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", self.inside))
            self.assertEqual(s.recv(10)[:2], b"\x05\x00")
            s.sendall(b"GET / HTTP/1.0\r\n\r\n")
            page = b""
            while True:
                data = s.recv(65536)
                if not data:
                    break
                page += data
        self.assertIn(b"Sales, this week", page)
        self.assertTrue(self.until(lambda: [p for p in self.carrier.describe("sb1")["ports"] if p["kind"] == "socks"][0]["received"] > 30))   # counted like any port
        self.assertEqual(self.carrier.open_socks("sb1")["port"], proxy["port"])
        self.assertEqual(self.carrier.close_socks("sb1")["state"], "closed")
        self.assertEqual(self.carrier.remembered("sb1"), [])

    def test_the_sandbox_reaches_a_port_of_this_computer_only_by_a_rule(self):
        self.carrier.connect("sb1")
        self.assertEqual([p for p in self.carrier.describe("sb1")["ports"] if p["kind"] == "out"], [])   # none without a rule
        from engine.sandbox_carrier import free_port
        there = free_port()                                            # the number it will have inside the sandbox
        rule = self.carrier.open_back("sb1", self.inside, there, label="my database")
        self.assertEqual((rule["kind"], rule["local_port"], rule["remote_port"], rule["label"]), ("out", self.inside, there, "my database"))
        self.assertIn(b"Sales", self.fetch(f"http://127.0.0.1:{there}"))   # « from inside the sandbox »: this computer's program answers
        self.assertTrue(self.until(lambda: self.carrier.describe("sb1")["ports"][0]["received"] > 30))
        self.assertEqual(self.carrier.remembered("sb1"), [{"kind": "out", "port": self.inside, "local": there, "label": "my database"}])
        with open(os.environ["STANDIN_SS"], "a") as f:                 # it listens in the sandbox now: not one of the sandbox's own ports
            f.write('LISTEN 0 128 127.0.0.1:%d 0.0.0.0:* users:(("sshd",pid=41,fd=9))\n' % there)
        self.assertNotIn(there, [r["port"] for r in self.carrier.listening("sb1")])
        self.assertEqual(self.carrier.close_back("sb1", self.inside)["state"], "closed")
        with self.assertRaises(OSError):
            self.fetch(f"http://127.0.0.1:{there}")
        os.environ["STANDIN_PORT_TAKEN"] = str(there)                  # the number is taken inside the sandbox
        try:
            with self.assertRaises(ValueError) as e:
                self.carrier.open_back("sb1", self.inside, there)
            self.assertIn("already taken on the other side", str(e.exception))
        finally:
            os.environ.pop("STANDIN_PORT_TAKEN", None)
        self.assertEqual(self.carrier.describe("sb1")["ports"], [])    # and nothing was left half open here
        with self.assertRaises(ValueError):
            self.carrier.open_back("sb1", self.inside, 8765)           # never over the way back to the Second Brain


class WayBackTest(CarrierTest):
    """The way back to the Second Brain: carried by the lasting connection so an agent keeps the Brain when its
    terminal is closed, and narrowed to the Brain's route and the health."""

    def setUp(self):
        super().setUp()
        from engine.sandbox_carrier import free_port
        self.carrier.engine_port = self.inside            # the web server stands for the engine here
        self.carrier.brain_port = free_port()              # where the sandbox would find it (8765 there)

    def ask(self, path):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{self.carrier.brain_port}{path}", timeout=10) as r:
                return r.status
        except urllib.error.HTTPError as e:
            return e.code

    def test_the_way_back_passes_the_brain_route_only(self):
        self.assertEqual(self.carrier.connect("sb1")["brain_way"], "carrier")
        self.assertEqual(self.ask("/sandbox-brain/s3cret/mcp"), 200)
        self.assertEqual(self.ask("/health"), 200)
        self.assertEqual(self.ask("/sessions"), 403)       # refused before the engine
        self.assertEqual(self.carrier.describe("sb1")["brain_refused"], 1)

    def test_when_the_terminal_holds_the_way_back_the_connection_takes_it_over_once_it_is_free(self):
        os.environ["STANDIN_PORT_TAKEN"] = str(self.carrier.brain_port)
        try:
            self.assertEqual(self.carrier.connect("sb1")["brain_way"], "terminal")
        finally:
            os.environ.pop("STANDIN_PORT_TAKEN", None)     # the terminal was closed
        self.carrier.watch_once()
        self.assertEqual(self.carrier.describe("sb1")["brain_way"], "carrier")
        self.assertEqual(self.ask("/sandbox-brain/s3cret/mcp"), 200)

    def test_the_terminal_checks_the_host_key_too(self):
        from engine.sandbox_attach import ssh_base
        base = " ".join(ssh_base(os.path.join(self.tmp, "keys", "sb1", "id_ed25519"), 4000))
        self.assertIn("StrictHostKeyChecking=accept-new", base)
        self.assertIn("HostKeyAlias=sandbox-sb1", base)
        self.assertIn(os.path.join(self.tmp, "keys", "sb1", "known_hosts"), base)
        self.assertNotIn("/dev/null", base)


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
            link = {}
            for _ in range(100):   # the count is written a moment after the page is here
                link = call("GET", "/sandboxes/sb1/tunnel")
                if link.get("received", 0) > 30:
                    break
                time.sleep(0.05)
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
