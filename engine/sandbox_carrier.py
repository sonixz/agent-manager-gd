"""The carrier: one lasting SSH connection per sandbox, apart from its terminal, through which the sandbox's ports
are brought to this computer (owner, 2026-11-12: a sandbox as « l'extension de mon localhost »).

- It reaches the machine as the terminal does: `flyctl proxy` to the sandbox's own SSH server, then OpenSSH with the
  sandbox's key. The terminal keeps its own connection: nothing here can slow a key, and closing the terminal no
  longer closes what was opened.
- It never starts a machine: a paused sandbox stays paused, and says so.
- The sandbox's host key is remembered at the first connection (in the sandbox's key folder); a key that changed
  refuses, and says so. The terminal's own connection does not check it yet.
- A port of the sandbox is brought here in two hops: SSH forwards it to a private port on 127.0.0.1, and the relay
  (relay.py) listens in front of that, on the same number as in the sandbox when it is free. So what passes is
  counted, and the port can be paused or closed. Everything listens on 127.0.0.1 only.
- What listens in the sandbox and how the sandbox is doing are read through the same connection.

The two programs are given by path (`ssh`, `flyctl`) so the tests put stand-ins there: no SSH server is needed.
"""
from __future__ import annotations

import os
import re
import socket
import subprocess
import threading
import time

from .relay import LOOPBACK, Relay

OURS = {2222: "the sandbox's SSH server", 8765: "the way back to this computer"}   # never offered as ports to open


def free_port() -> int:
    s = socket.socket()
    s.bind((LOOPBACK, 0))
    p = s.getsockname()[1]
    s.close()
    return p


def parse_listening(text: str) -> list[dict]:
    """The answer of `ss -Hltnp` in the sandbox: one row per port that listens, with the program when it is told.
    Our own ports are left out. A port that listens on every address and one on the inside only are both reachable
    through the connection: `inside` says which."""
    found: dict[int, dict] = {}
    for line in text.splitlines():
        p = line.split()
        if len(p) < 4 or p[0] != "LISTEN":
            continue
        addr = p[3]
        host, _, port = addr.rpartition(":")
        if not port.isdigit():
            continue
        n = int(port)
        if n in OURS:
            continue
        m = re.search(r'users:\(\("([^"]+)"', line)
        row = found.setdefault(n, {"port": n, "program": m.group(1) if m else "", "inside": True})
        bare = host.strip("[]").split("%")[0]
        if not (bare.startswith("127.") or bare in ("::1", "localhost")):
            row["inside"] = False
    return [found[k] for k in sorted(found)]


def parse_health(text: str) -> dict:
    """What `cat /proc/meminfo; echo ---; cat /proc/loadavg; echo ---; cat /proc/uptime; echo ---; df -B1 -P <dir>`
    printed in the sandbox: memory, load, how long it has been up, the room on its disk."""
    parts = [x.strip() for x in text.split("---")]
    kb = {}
    for line in (parts[0] if parts else "").splitlines():
        name, _, rest = line.partition(":")
        num = rest.split()
        if num and num[0].isdigit():
            kb[name] = int(num[0]) * 1024
    out = {"memory_total": kb.get("MemTotal", 0), "memory_used": max(0, kb.get("MemTotal", 0) - kb.get("MemAvailable", 0)),
           "load": 0.0, "uptime": 0.0, "disk_total": 0, "disk_free": 0}
    try:
        out["load"] = float(parts[1].split()[0])
        out["uptime"] = float(parts[2].split()[0])
    except (IndexError, ValueError):
        pass
    rows = [x.split() for x in (parts[3] if len(parts) > 3 else "").splitlines()[1:]]
    if rows and len(rows[-1]) >= 4 and rows[-1][1].isdigit() and rows[-1][3].isdigit():
        out["disk_total"], out["disk_free"] = int(rows[-1][1]), int(rows[-1][3])
    return out


def _end(proc: subprocess.Popen | None) -> None:
    """Stops a process and takes its exit: none is left half-dead behind the engine."""
    if proc is None:
        return
    if proc.poll() is None:
        proc.kill()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    if proc.stderr is not None:
        proc.stderr.close()


class Carrier:
    def __init__(self, sandboxes, relay: Relay, home: str, ssh: str = "ssh", flyctl: str | None = None):
        self.sandboxes = sandboxes
        self.relay = relay
        self.home = home
        self.ssh = ssh
        self.flyctl = flyctl
        self.links: dict[str, dict] = {}    # sandbox id -> its connection: the two processes, the ports opened
        self.lock = threading.Lock()

    # ---------------------------------------------------------------- the connection
    def _base(self, sbid: str, port: int) -> list[str]:
        folder = os.path.dirname(self.sandboxes.key_path(sbid))
        os.makedirs(os.path.join(self.home, "runtime"), exist_ok=True)
        return [self.ssh, "-i", self.sandboxes.key_path(sbid), "-p", str(port), "-S", os.path.join(self.home, "runtime", f"carrier-{sbid}.sock"),
                "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ServerAliveInterval=20", "-o", "ConnectTimeout=10",
                # the host key: remembered at the first connection under the sandbox's own name (the address is
                # always 127.0.0.1 with a port that changes), refused when it is no longer the same
                "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={os.path.join(folder, 'known_hosts')}",
                "-o", f"HostKeyAlias=sandbox-{sbid}"]

    def _run(self, link: dict, *args: str, timeout: float = 20.0) -> tuple[int, str, str]:
        try:
            out = subprocess.run(link["base"] + list(args), capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return 124, "", "it did not answer in time"
        return out.returncode, out.stdout, out.stderr

    def connect(self, sbid: str) -> dict:
        """Opens the sandbox's lasting connection, when its machine runs. Does nothing when it is already open."""
        with self.lock:
            link = self.links.get(sbid)
        if link and link["master"].poll() is None:
            return self.describe(sbid)
        if link:
            self.disconnect(sbid)
        sb = self.sandboxes.get(sbid)
        if sb.get("destroyed"):
            raise ValueError("this sandbox was destroyed")
        state = {m["id"]: m for m in self.sandboxes.machines()}.get(sb["machine"], {}).get("state")
        if state != "started":
            raise ValueError("the sandbox is not running (%s): start it first; opening a connection never starts it" % (state or "gone at Fly.io"))
        port = free_port()
        flyctl = self.flyctl or __import__("engine.sandboxes", fromlist=["FLYCTL"]).FLYCTL
        proxy = subprocess.Popen([flyctl, "proxy", f"{port}:2222", f"{sb['machine']}.vm.{sb['app']}.internal", "--app", sb["app"]],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.sandboxes.fly.env())
        base = self._base(sbid, port)
        link = {"proxy": proxy, "port": port, "base": base, "master": None, "since": time.time(), "ports": {}, "why": ""}
        # the master: it carries nothing itself; forwards are added to it and taken from it while it lives
        err = ""
        for _ in range(6):   # a machine that just started does not always answer at once
            master = subprocess.Popen(base + ["-M", "-N", "root@127.0.0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            link["master"] = master
            deadline = time.monotonic() + 12.0
            up = False
            while time.monotonic() < deadline and master.poll() is None:
                if self._run(link, "-O", "check", "root@127.0.0.1", timeout=5.0)[0] == 0:
                    up = True
                    break
                time.sleep(0.2)
            if up:
                break
            if master.poll() is None:
                master.kill()
            master.wait()
            err = (master.stderr.read() if master.stderr else "") or err
            master.stderr.close()
            if "host key" in err.lower() or "REMOTE HOST IDENTIFICATION" in err:
                break   # asking again would change nothing: the key is not the one remembered
            if proxy.poll() is not None:
                break
            time.sleep(1.0)
        else:
            up = False
        if not up:
            _end(proxy)
            if "host key" in err.lower() or "REMOTE HOST IDENTIFICATION" in err:
                raise ValueError("the sandbox's host key is not the one remembered at its first connection: nothing was opened")
            raise ValueError("the sandbox did not answer" + ((": " + err.strip()[-200:]) if err.strip() else ""))
        with self.lock:
            self.links[sbid] = link
        return self.describe(sbid)

    def disconnect(self, sbid: str) -> dict:
        with self.lock:
            link = self.links.pop(sbid, None)
        if link:
            for row in list(link["ports"].values()):
                try:
                    self.relay.close(row["channel"], "the connection was closed")
                except KeyError:
                    pass
            if link["master"] is not None and link["master"].poll() is None:
                self._run(link, "-O", "exit", "root@127.0.0.1", timeout=5.0)
                try:
                    link["master"].wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            _end(link["master"])
            _end(link["proxy"])
            try:
                os.remove(os.path.join(self.home, "runtime", f"carrier-{sbid}.sock"))
            except OSError:
                pass
        return {"id": sbid, "state": "closed", "ports": []}

    def _link(self, sbid: str) -> dict:
        with self.lock:
            link = self.links.get(sbid)
        if not link or link["master"].poll() is not None:
            raise ValueError("the connection to this sandbox is not open")
        return link

    # ---------------------------------------------------------------- the ports
    def open_port(self, sbid: str, port: int, local: int = 0, label: str = "") -> dict:
        """Brings a port of the sandbox here: on the same number when it is free, else the next free one."""
        port = int(port)
        if port in OURS or not 1 <= port <= 65535:
            raise ValueError("this port is not one to open")
        link = self._link(sbid)
        if port in link["ports"]:
            return self._port_row(link, port)
        inner = free_port()
        spec = f"{LOOPBACK}:{inner}:{LOOPBACK}:{port}"
        rc, _, err = self._run(link, "-O", "forward", "-L", spec, "root@127.0.0.1")
        if rc != 0:
            raise ValueError("the port could not be brought here" + ((": " + err.strip()[-160:]) if err.strip() else ""))
        ch = self.relay.open(inner, port=int(local) or port, label=label or f"port {port}")
        link["ports"][port] = {"port": port, "inner": inner, "spec": spec, "channel": ch["id"], "label": ch["label"]}
        return self._port_row(link, port)

    def close_port(self, sbid: str, port: int) -> dict:
        link = self._link(sbid)
        row = link["ports"].pop(int(port), None)
        if row is None:
            raise KeyError(port)
        closed = self.relay.close(row["channel"])
        self._run(link, "-O", "cancel", "-L", row["spec"], "root@127.0.0.1")
        return {**closed, "remote_port": row["port"]}

    def pause_port(self, sbid: str, port: int, paused: bool = True) -> dict:
        link = self._link(sbid)
        row = link["ports"][int(port)]
        (self.relay.pause if paused else self.relay.resume)(row["channel"])
        return self._port_row(link, int(port))

    def _port_row(self, link: dict, port: int) -> dict:
        row = link["ports"][port]
        ch = next((c for c in self.relay.describe() if c["id"] == row["channel"]), {})
        return {**ch, "remote_port": port}

    # ---------------------------------------------------------------- what the sandbox tells
    def listening(self, sbid: str) -> list[dict]:
        """What listens in the sandbox now, with for each port whether it is brought here."""
        link = self._link(sbid)
        rc, out, _ = self._run(link, "root@127.0.0.1", "ss -Hltnp 2>/dev/null")
        rows = parse_listening(out) if rc == 0 else []
        for r in rows:
            r["open"] = r["port"] in link["ports"]
        return rows

    def health(self, sbid: str, workdir: str = "/work") -> dict:
        link = self._link(sbid)
        began = time.monotonic()
        rc, out, _ = self._run(link, "root@127.0.0.1",
                               "cat /proc/meminfo; echo ---; cat /proc/loadavg; echo ---; cat /proc/uptime; echo ---; df -B1 -P " + workdir + " 2>/dev/null")
        took = time.monotonic() - began
        if rc != 0:
            return {}
        return {**parse_health(out), "round_trip_ms": round(took * 1000)}

    def describe(self, sbid: str) -> dict:
        with self.lock:
            link = self.links.get(sbid)
        if not link:
            return {"id": sbid, "state": "closed", "ports": []}
        up = link["master"] is not None and link["master"].poll() is None and link["proxy"].poll() is None
        ports = [self._port_row(link, p) for p in sorted(link["ports"])]
        return {"id": sbid, "state": "open" if up else "lost", "since": link["since"], "ports": ports,
                "sent": sum(int(p.get("sent", 0)) for p in ports), "received": sum(int(p.get("received", 0)) for p in ports),
                "sent_rate": sum(float(p.get("sent_rate", 0.0)) for p in ports), "received_rate": sum(float(p.get("received_rate", 0.0)) for p in ports)}

    def close_all(self) -> None:
        with self.lock:
            ids = list(self.links)
        for sbid in ids:
            self.disconnect(sbid)
