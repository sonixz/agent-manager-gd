"""The relay that carries and counts what passes toward a sandbox's port. Everything here is on this computer: an
echo server and a small web server stand for what would run in a sandbox."""
import http.server
import os
import socket
import socketserver
import threading
import time
import unittest
import urllib.request

from engine import relay as relay_mod
from engine.relay import Relay


class Echo(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


class Quiet(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        body = b"<title>Sales, this week</title>" + b"x" * 5000
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def wait_for(check, sec=5.0):
    end = time.monotonic() + sec
    while time.monotonic() < end:
        if check():
            return True
        time.sleep(0.02)
    return False


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.echo = Echo(("127.0.0.1", 0), EchoHandler)
        threading.Thread(target=self.echo.serve_forever, daemon=True).start()
        self.target = self.echo.server_address[1]
        self.relay = Relay()

    def tearDown(self):
        self.relay.close_all()
        self.echo.shutdown()
        self.echo.server_close()

    def talk(self, port, payload):
        """Sends `payload`, says it has no more to send, and reads everything that comes back. A connection the
        relay lets go at once (a paused channel, a target that does not answer) gives nothing back: that is not an
        error here, whatever the moment the system notices it."""
        with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
            back = b""
            try:
                s.sendall(payload)
                s.shutdown(socket.SHUT_WR)
                while True:
                    data = s.recv(65536)
                    if not data:
                        return back
                    back += data
            except OSError:
                return back

    def channel(self, cid):
        return next(c for c in self.relay.describe() if c["id"] == cid)

    def test_every_byte_is_carried_and_counted_in_its_direction(self):
        ch = self.relay.open(self.target, label="echo")
        payload = os.urandom(1_000_003)           # an odd size on purpose, larger than one read
        self.assertEqual(self.talk(ch["port"], payload), payload)
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["open_now"] == 0))
        now = self.channel(ch["id"])
        self.assertEqual((now["sent"], now["received"]), (1_000_003, 1_000_003))    # exactly: not one more, not one less
        self.assertEqual((now["connections"], now["refused"], now["state"], now["label"]), (1, 0, "open", "echo"))
        self.assertEqual(sum(x[1] for x in now["series"]), 1_000_003)                # second by second, the same total
        self.assertGreater(now["last"], now["opened"] - 5)

    def test_it_listens_on_this_computer_only(self):
        ch = self.relay.open(self.target)
        server = self.relay.channels[ch["id"]].server
        self.assertEqual(server.getsockname()[0], "127.0.0.1")       # never on every address
        self.assertEqual(relay_mod.LOOPBACK, "127.0.0.1")
        self.assertEqual(ch["address"], f"http://127.0.0.1:{ch['port']}")

    def test_the_wished_port_is_kept_when_free_and_the_next_one_is_taken_when_not(self):
        holder = socket.socket()
        holder.bind(("127.0.0.1", 0))
        holder.listen(1)
        taken = holder.getsockname()[1]
        try:
            ch = self.relay.open(self.target, port=taken)
            self.assertGreater(ch["port"], taken)                   # the same number was not free
            self.assertLess(ch["port"], taken + 20)
            self.assertEqual(self.talk(ch["port"], b"hello"), b"hello")
        finally:
            holder.close()
        probe = socket.socket()               # a port the system says is free right now
        probe.bind(("127.0.0.1", 0))
        wished = probe.getsockname()[1]
        probe.close()
        self.assertEqual(self.relay.open(self.target, port=wished)["port"], wished)

    def test_a_channel_says_why_it_is_not_on_the_port_asked_for(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        wished = probe.getsockname()[1]
        probe.close()
        ch = self.relay.open(self.target, port=wished, taken_elsewhere=lambda: {wished})   # a Windows program holds it
        self.assertNotEqual(ch["port"], wished)
        self.assertEqual((ch["wanted"], ch["moved"]), (wished, "windows"))
        self.assertEqual(self.talk(ch["port"], b"hi"), b"hi")
        holder = socket.socket()
        holder.bind(("127.0.0.1", 0))
        holder.listen(1)
        try:
            ch = self.relay.open(self.target, port=holder.getsockname()[1], taken_elsewhere=lambda: set())
            self.assertEqual(ch["moved"], "here")
        finally:
            holder.close()
        free = self.relay.open(self.target, port=0, taken_elsewhere=lambda: set())
        self.assertEqual((free["wanted"], free["moved"]), (0, ""))

    def test_ports_windows_holds_are_read_from_its_netstat(self):
        from engine.windows_ports import parse_netstat, parse_relays
        netstat = """
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1620
  TCP    127.0.0.1:8000         0.0.0.0:0              LISTENING       27304
  TCP    127.0.0.1:9010         0.0.0.0:0              LISTENING       28828
  TCP    192.168.2.212:8800     0.0.0.0:0              LISTENING       4896
  TCP    127.0.0.1:9010         127.0.0.1:50000        ESTABLISHED     28828
  TCP    [::1]:5173             [::]:0                 LISTENING       777
  TCP    [::]:445               [::]:0                 LISTENING       4
  UDP    0.0.0.0:5353           *:*                                    999
"""
        relays = parse_relays('"wslrelay.exe","27304","Console","1","11 748 K"\r\n')
        self.assertEqual(relays, {"27304"})
        # 8000 is WSL's own port seen through its bridge; 8800 is on the network address, not localhost
        self.assertEqual(parse_netstat(netstat, relays), {135, 9010, 5173, 445})
        self.assertEqual(parse_relays("INFO: No tasks are running which match the specified criteria."), set())

    def test_two_at_once_are_counted_together_and_shown_while_open(self):
        ch = self.relay.open(self.target)
        a = socket.create_connection(("127.0.0.1", ch["port"]))
        b = socket.create_connection(("127.0.0.1", ch["port"]))
        a.sendall(b"aaaa")
        b.sendall(b"bb")
        self.assertEqual((a.recv(10), b.recv(10)), (b"aaaa", b"bb"))
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["open_now"] == 2))
        # a byte is counted once it was handed on: the echo may be back here a moment before its own way out is counted
        self.assertTrue(wait_for(lambda: (self.channel(ch["id"])["sent"], self.channel(ch["id"])["received"]) == (6, 6)))
        now = self.channel(ch["id"])
        self.assertEqual((now["sent"], now["received"], now["connections"]), (6, 6, 2))
        a.close()
        b.close()
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["open_now"] == 0))

    def test_a_paused_channel_carries_nothing_and_resumes(self):
        ch = self.relay.open(self.target)
        held = socket.create_connection(("127.0.0.1", ch["port"]))
        held.sendall(b"one")
        self.assertEqual(held.recv(10), b"one")
        self.assertEqual(self.relay.pause(ch["id"])["state"], "paused")
        held.settimeout(3)
        self.assertEqual(held.recv(10), b"")                         # the connection it had was closed
        held.close()
        self.assertEqual(self.talk(ch["port"], b"while paused"), b"")   # a new one is let go at once
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["refused"] == 1))
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["sent"] == 3))
        self.assertEqual(self.channel(ch["id"])["sent"], 3)           # nothing passed meanwhile
        self.assertEqual(self.relay.resume(ch["id"])["state"], "open")
        self.assertEqual(self.talk(ch["port"], b"again"), b"again")

    def test_a_closed_channel_gives_its_port_back_and_keeps_its_figures(self):
        ch = self.relay.open(self.target)
        self.assertEqual(self.talk(ch["port"], b"12345"), b"12345")
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["sent"] == 5))
        closed = self.relay.close(ch["id"])
        self.assertEqual((closed["state"], closed["why"], closed["sent"]), ("closed", "asked", 5))
        self.assertGreater(closed["closed"], 0)
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", ch["port"]), timeout=2)
        again = socket.socket()                                       # the port is free for whoever wants it
        again.bind(("127.0.0.1", ch["port"]))
        again.close()
        with self.assertRaises(ValueError):
            self.relay.forget(self.relay.open(self.target)["id"])      # an open one is not forgotten
        self.relay.forget(ch["id"])
        with self.assertRaises(KeyError):
            self.relay.pause(ch["id"])

    def test_a_target_that_does_not_answer_is_counted_and_breaks_nothing(self):
        dead = socket.socket()
        dead.bind(("127.0.0.1", 0))
        port = dead.getsockname()[1]
        dead.close()                                                  # nothing listens there now
        ch = self.relay.open(port)
        self.assertEqual(self.talk(ch["port"], b"anyone?"), b"")
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["refused"] == 1))
        self.assertEqual((self.channel(ch["id"])["connections"], self.channel(ch["id"])["sent"]), (0, 0))

    def test_a_channel_nothing_passes_through_is_closed_after_its_time(self):
        quiet = self.relay.open(self.target)
        busy = self.relay.open(self.target)
        held = socket.create_connection(("127.0.0.1", busy["port"]))   # an open connection keeps its channel
        self.assertTrue(wait_for(lambda: self.channel(busy["id"])["open_now"] == 1))
        self.assertEqual(self.relay.close_idle(3600), [])              # not yet their time
        time.sleep(0.15)
        self.assertEqual(self.relay.close_idle(0.1), [quiet["id"]])
        self.assertEqual((self.channel(quiet["id"])["state"], self.channel(quiet["id"])["why"]), ("closed", "idle"))
        self.assertEqual(self.channel(busy["id"])["state"], "open")
        held.close()

    def test_a_web_page_passes_as_it_is(self):
        web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
        threading.Thread(target=web.serve_forever, daemon=True).start()
        try:
            ch = self.relay.open(web.server_address[1], label="dashboard")
            with urllib.request.urlopen(ch["address"] + "/", timeout=10) as r:
                page = r.read()
            self.assertTrue(page.startswith(b"<title>Sales, this week</title>"))
            self.assertEqual(len(page), 31 + 5000)
            self.assertTrue(wait_for(lambda: self.channel(ch["id"])["received"] > 5031))   # the page and its headers
            self.assertGreater(self.channel(ch["id"])["sent"], 0)                            # the request
        finally:
            web.shutdown()
            web.server_close()

    def test_what_passed_lately_is_said_per_second(self):
        ch = self.relay.open(self.target)
        self.talk(ch["port"], b"z" * 5000)
        self.assertTrue(wait_for(lambda: self.channel(ch["id"])["received"] == 5000))
        now = self.channel(ch["id"])
        self.assertAlmostEqual(now["sent_rate"], 500.0)               # 5000 bytes in the last ten seconds
        self.assertAlmostEqual(now["received_rate"], 500.0)
        later = self.relay.describe(now=time.time() + 60)[0]          # a minute on: nothing passes any more
        self.assertEqual((later["sent_rate"], later["received_rate"], later["sent"]), (0.0, 0.0, 5000))


class Seen(http.server.BaseHTTPRequestHandler):
    """Stands for the engine: answers every request, and writes down each path that reached it."""
    protocol_version = "HTTP/1.1"
    paths = []

    def log_message(self, fmt, *args):
        pass

    def answer(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            body = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        Seen.paths.append((self.command, self.path, body))
        out = b"ok " + body
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    do_GET = do_POST = answer


class GuardTest(unittest.TestCase):
    """The way back of a sandbox: only the Second Brain's route and the health pass, request by request."""

    def setUp(self):
        Seen.paths = []
        self.engine = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Seen)
        threading.Thread(target=self.engine.serve_forever, daemon=True).start()
        self.relay = Relay()
        self.ch = self.relay.open(self.engine.server_address[1], label="the way back", guard=relay_mod.brain_paths)

    def tearDown(self):
        self.relay.close_all()
        self.engine.shutdown()
        self.engine.server_close()

    def raw(self, data):
        with socket.create_connection(("127.0.0.1", self.ch["port"]), timeout=10) as s:
            s.sendall(data)
            s.shutdown(socket.SHUT_WR)
            back = b""
            while True:
                try:
                    d = s.recv(65536)
                except OSError:
                    return back
                if not d:
                    return back
                back += d

    def test_the_paths(self):
        ok = relay_mod.brain_paths
        self.assertTrue(ok("/health") and ok("/sandbox-brain/s3cret/mcp") and ok("/sandbox-brain/s3cret/health?x=1"))
        self.assertFalse(ok("/sessions") or ok("/host") or ok("/sandbox-brain/../sessions") or ok("//sandbox-brain/x") or ok("/healthz"))

    def test_the_brain_route_passes_and_the_rest_is_refused_before_the_engine(self):
        back = self.raw(b"POST /sandbox-brain/s3cret/mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        self.assertIn(b"200", back.split(b"\r\n")[0])
        self.assertTrue(back.endswith(b"ok hello"))
        back = self.raw(b"GET /sessions HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertTrue(back.startswith(b"HTTP/1.1 403"))
        self.assertEqual([p[1] for p in Seen.paths], ["/sandbox-brain/s3cret/mcp"])     # /sessions never reached it
        now = self.relay.describe()[0]
        self.assertEqual((now["denied"], now["guarded"]), (1, True))

    def test_a_refused_request_hidden_behind_an_allowed_one_on_the_same_connection_never_reaches_the_engine(self):
        back = self.raw(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
                        b"POST /sessions HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")
        self.assertIn(b"403", back)
        self.assertEqual([p[1] for p in Seen.paths], ["/health"])

    def test_bodies_by_length_and_by_chunks_pass_whole_and_two_requests_in_a_row_too(self):
        back = self.raw(b"POST /sandbox-brain/k/mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                        b"4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
                        b"POST /sandbox-brain/k/mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc")
        self.assertEqual([(p[1], p[2]) for p in Seen.paths], [("/sandbox-brain/k/mcp", b"Wikipedia"), ("/sandbox-brain/k/mcp", b"abc")])
        self.assertIn(b"ok Wikipedia", back)
        self.assertIn(b"ok abc", back)
        self.assertEqual(self.relay.describe()[0]["denied"], 0)

    def test_a_head_that_never_ends_is_refused(self):
        back = self.raw(b"GET /health HTTP/1.1\r\nX: " + b"a" * 70000)
        self.assertTrue(back.startswith(b"HTTP/1.1 403"))
        self.assertEqual(Seen.paths, [])


if __name__ == "__main__":
    unittest.main()
