"""The relay: what passes between this computer and a sandbox's port goes through it, so it can be counted, paused
and closed (owner, 2026-11-11: « J'aimerais être capable de gérer le trafic qui passe dans le tunnel SSH », and
2026-11-12: a sandbox as « l'extension de mon localhost »).

A channel is one listener on this computer, on 127.0.0.1 and nowhere else, in front of one target (the local end
of a sandbox's SSH forward). Whatever connects to the listener is carried to the target and back, byte for byte,
and every byte is counted in its direction. Nothing is read of what passes: only how much.

- « sent » goes from this computer toward the target (the sandbox); « received » comes back.
- A paused channel keeps its port but carries nothing: the connections it had are closed, new ones are refused.
- A closed channel gives its port back. Its figures stay readable until it is forgotten.
- Standard library only, a thread per direction of each connection: made for a dashboard or a web page under
  work, not for heavy traffic.
"""
from __future__ import annotations

import secrets
import socket
import threading
import time

LOOPBACK = "127.0.0.1"   # the only address a channel ever listens on (AGENTS.md: nothing beyond this computer)
CHUNK = 65536
KEEP = 300               # seconds of traffic kept second by second, for the small curves


HEAD_MAX = 65536          # an HTTP request whose head is longer than this is refused


def brain_paths(path: str) -> bool:
    """What a sandbox may ask of the engine through its way back: the engine's health, and the Second Brain route of
    a sandbox (which the engine guards with that sandbox's own secret). Nothing else reaches the engine."""
    p = path.split("?", 1)[0]
    return (p == "/health" or p.startswith("/sandbox-brain/")) and ".." not in p and "//" not in p


class Channel:
    def __init__(self, target_port: int, port: int, label: str, target_host: str = LOOPBACK):
        self.id = secrets.token_hex(4)
        self.label = label
        self.port = port
        self.target = (target_host, int(target_port))
        self.state = "open"            # open, paused, closed
        self.opened = time.time()
        self.closed = 0.0
        self.why = ""                  # why it closed, when something closed it: « idle », « asked »
        self.last = 0.0                # the last moment a byte passed (wall clock, to show)
        self.last_steady = time.monotonic()   # the same on the steady clock, to decide idleness
        self.sent = 0
        self.received = 0
        self.connections = 0           # ever accepted
        self.refused = 0               # arrived while paused, or the target did not answer
        self.live: set[socket.socket] = set()
        self.lock = threading.Lock()
        self.server: socket.socket | None = None
        self.series: list[tuple[int, int, int]] = []   # (second, sent in it, received in it), the last KEEP seconds
        self.guard = None              # when set: HTTP only, and only the requests whose path it accepts pass
        self.denied = 0                # requests refused by the guard (counted, never kept)
        self.wanted = port             # the port asked for on this computer (0: any)
        self.moved = ""                # why it is not on the port asked for: « windows » or « here »

    def count(self, n: int, toward_target: bool) -> None:
        now = time.time()
        with self.lock:
            if toward_target:
                self.sent += n
            else:
                self.received += n
            self.last = now
            self.last_steady = time.monotonic()
            sec = int(now)
            if self.series and self.series[-1][0] == sec:
                s, a, b = self.series[-1]
                self.series[-1] = (s, a + (n if toward_target else 0), b + (0 if toward_target else n))
            else:
                self.series.append((sec, n if toward_target else 0, 0 if toward_target else n))
                if len(self.series) > KEEP:
                    del self.series[:len(self.series) - KEEP]

    def describe(self, now: float | None = None) -> dict:
        now = time.time() if now is None else now
        with self.lock:
            # what passed in the last ten seconds, per second: the figure a bandwidth meter shows
            recent = [x for x in self.series if x[0] > int(now) - 10]
            return {"id": self.id, "label": self.label, "port": self.port, "target_host": self.target[0], "target_port": self.target[1],
                    "address": f"http://{LOOPBACK}:{self.port}", "state": self.state, "why": self.why,
                    "opened": self.opened, "closed": self.closed, "last": self.last,
                    "sent": self.sent, "received": self.received, "connections": self.connections, "refused": self.refused,
                    "denied": self.denied, "guarded": self.guard is not None, "wanted": self.wanted, "moved": self.moved,
                    "open_now": len(self.live) // 2, "sent_rate": sum(x[1] for x in recent) / 10.0, "received_rate": sum(x[2] for x in recent) / 10.0,
                    "series": [list(x) for x in self.series[-120:]]}


class Relay:
    def __init__(self) -> None:
        self.channels: dict[str, Channel] = {}
        self.lock = threading.Lock()

    # ---------------------------------------------------------------- opening
    @staticmethod
    def _listen(port: int) -> socket.socket:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((LOOPBACK, port))
        s.listen(64)
        return s

    def open(self, target_port: int, port: int = 0, label: str = "", target_host: str = LOOPBACK, tries: int = 20, guard=None,
             taken_elsewhere=None) -> dict:
        """Opens a channel in front of `target_port`. `port` is the port wished for on this computer (usually the
        same number as in the sandbox, so a dashboard keeps its usual address): when it is taken, the next free one
        is used; 0 lets the system choose. `taken_elsewhere`, when given, says which ports are taken where this
        side cannot see (Windows, for an engine in WSL): those are passed over too, and the channel says why it
        moved."""
        server = None
        moved = ""
        elsewhere = set(taken_elsewhere() or ()) if (port and taken_elsewhere) else set()
        if port:
            for p in range(int(port), int(port) + max(1, tries)):
                if p > 65535:
                    break
                if p in elsewhere:
                    moved = moved or "windows"
                    continue
                try:
                    server = self._listen(p)
                    break
                except OSError:
                    moved = moved or "here"
                    continue
        if server is None:
            server = self._listen(0)
        ch = Channel(target_port, server.getsockname()[1], label, target_host)
        ch.wanted = int(port)
        ch.moved = moved if (port and ch.port != int(port)) else ""
        ch.server = server
        ch.guard = guard
        with self.lock:
            self.channels[ch.id] = ch
        threading.Thread(target=self._accept, args=(ch, server), daemon=True, name=f"relay-{ch.port}").start()
        return ch.describe()

    # ---------------------------------------------------------------- carrying
    def _accept(self, ch: Channel, server: socket.socket) -> None:
        while True:
            try:
                client, _ = server.accept()
            except OSError:
                return  # the listener was closed
            if ch.state != "open":
                with ch.lock:
                    ch.refused += 1
                client.close()
                continue
            try:
                target = socket.create_connection(ch.target, timeout=10)
                target.settimeout(None)
            except OSError:
                with ch.lock:
                    ch.refused += 1
                client.close()
                continue
            with ch.lock:
                ch.connections += 1
                ch.live.update((client, target))
            way_in = self._filter if ch.guard is not None else self._pump
            threading.Thread(target=way_in, args=(ch, client, target, True), daemon=True).start()
            threading.Thread(target=self._pump, args=(ch, target, client, False), daemon=True).start()

    @staticmethod
    def _pump(ch: Channel, src: socket.socket, dst: socket.socket, toward_target: bool) -> None:
        try:
            while True:
                data = src.recv(CHUNK)
                if not data:
                    break
                dst.sendall(data)
                ch.count(len(data), toward_target)
        except OSError:
            pass
        finally:
            # one side has no more to say: the other is told so, and may still finish what it was sending
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            with ch.lock:
                ch.live.discard(src)
                mate_gone = dst not in ch.live
            if mate_gone:
                for s in (src, dst):
                    try:
                        s.close()
                    except OSError:
                        pass

    @classmethod
    def _filter(cls, ch: Channel, src: socket.socket, dst: socket.socket, toward_target: bool) -> None:
        """Toward the target, request by request: each request's head is read, its path is asked of the guard, then
        the request and its body (by its length, or chunk by chunk) are handed on. A request the guard refuses is
        answered 403 here, and the connection is closed: nothing of it reaches the target, nor what follows on the
        same connection."""
        buf = b""

        def more() -> bool:
            nonlocal buf
            data = src.recv(CHUNK)
            if not data:
                return False
            buf += data
            return True

        def hand(n: int) -> None:   # hands on n bytes of the body, as they come
            nonlocal buf
            while n > 0:
                if not buf and not more():
                    raise OSError("the request ended in its body")
                part, buf = buf[:n], buf[n:]
                dst.sendall(part)
                ch.count(len(part), True)
                n -= len(part)

        def line() -> bytes:
            nonlocal buf
            while b"\r\n" not in buf:
                if len(buf) > HEAD_MAX or not more():
                    raise OSError("no line")
            ln, buf = buf.split(b"\r\n", 1)
            return ln

        try:
            while True:
                while b"\r\n\r\n" not in buf:
                    if len(buf) > HEAD_MAX:
                        raise PermissionError("head too long")
                    if not more():
                        if buf:
                            raise PermissionError("cut in its head")
                        return   # the client said all it had to say, between two requests
                head, buf = buf.split(b"\r\n\r\n", 1)
                first, *fields = head.split(b"\r\n")
                parts = first.split(b" ")
                if len(parts) != 3 or not ch.guard(parts[1].decode("latin-1")):
                    raise PermissionError("path")
                names = {}
                for f in fields:
                    k, _, v = f.partition(b":")
                    names[k.strip().lower()] = v.strip().lower()
                dst.sendall(head + b"\r\n\r\n")
                ch.count(len(head) + 4, True)
                if b"chunked" in names.get(b"transfer-encoding", b""):
                    while True:
                        size_line = line()
                        dst.sendall(size_line + b"\r\n")
                        ch.count(len(size_line) + 2, True)
                        size = int(size_line.split(b";")[0].strip() or b"0", 16)
                        if size == 0:
                            while True:   # the trailers, up to an empty line
                                t = line()
                                dst.sendall(t + b"\r\n")
                                ch.count(len(t) + 2, True)
                                if not t:
                                    break
                            break
                        hand(size + 2)   # the chunk and its line end
                else:
                    hand(int(names.get(b"content-length", b"0") or b"0"))
        except PermissionError:
            with ch.lock:
                ch.denied += 1
            try:
                body = b"refused: a sandbox reaches only the Second Brain through this way\n"
                src.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            except OSError:
                pass
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        except (OSError, ValueError):
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            with ch.lock:
                ch.live.discard(src)
                mate_gone = dst not in ch.live
            if mate_gone:
                for s in (src, dst):
                    try:
                        s.close()
                    except OSError:
                        pass

    @staticmethod
    def _drop(ch: Channel) -> None:
        with ch.lock:
            live = list(ch.live)
            ch.live.clear()
        for s in live:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass

    # ---------------------------------------------------------------- steering
    def _get(self, cid: str) -> Channel:
        with self.lock:
            ch = self.channels.get(cid)
        if ch is None:
            raise KeyError(cid)
        return ch

    def pause(self, cid: str) -> dict:
        ch = self._get(cid)
        if ch.state == "open":
            ch.state = "paused"
            self._drop(ch)
        return ch.describe()

    def resume(self, cid: str) -> dict:
        ch = self._get(cid)
        if ch.state == "paused":
            ch.state = "open"
        return ch.describe()

    def close(self, cid: str, why: str = "asked") -> dict:
        ch = self._get(cid)
        if ch.state != "closed":
            ch.state = "closed"
            ch.why = why
            ch.closed = time.time()
            if ch.server is not None:
                # shut down first: a thread waits in accept() on it, and closing alone would leave the port taken
                # until that wait ends (seen in the tests: a closed channel still accepted a connection)
                for end in (lambda: ch.server.shutdown(socket.SHUT_RDWR), ch.server.close):
                    try:
                        end()
                    except OSError:
                        pass
            self._drop(ch)
        return ch.describe()

    def forget(self, cid: str) -> None:
        """A closed channel's figures are dropped."""
        ch = self._get(cid)
        if ch.state != "closed":
            raise ValueError("close the channel first")
        with self.lock:
            self.channels.pop(cid, None)

    def close_idle(self, seconds: float) -> list[str]:
        """Closes the open channels through which nothing passed for `seconds` and that carry no connection now.
        Gives the ones it closed."""
        out = []
        now = time.monotonic()
        with self.lock:
            every = list(self.channels.values())
        for ch in every:
            with ch.lock:
                quiet = ch.state == "open" and not ch.live and now - ch.last_steady > seconds
            if quiet:
                self.close(ch.id, "idle")
                out.append(ch.id)
        return out

    def describe(self, now: float | None = None) -> list[dict]:
        with self.lock:
            every = list(self.channels.values())
        return [ch.describe(now) for ch in sorted(every, key=lambda c: c.opened)]

    def close_all(self) -> None:
        with self.lock:
            ids = list(self.channels)
        for cid in ids:
            self.close(cid, "the engine stops")
