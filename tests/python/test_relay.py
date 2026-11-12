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


if __name__ == "__main__":
    unittest.main()
