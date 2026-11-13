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
from contextlib import closing

from .relay import LOOPBACK, Relay, brain_paths

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


def parse_proc_net(text: str) -> list[dict]:
    """What listens, read from /proc/net/tcp and /proc/net/tcp6, which every Linux has: the sandbox's image has no
    `ss` (its Ubuntu base leaves it out; seen on the owner's first real sandbox, 2026-11-12). No program names there."""
    found: dict[int, dict] = {}
    for line in text.splitlines():
        f = line.split()
        if len(f) < 4 or f[3] != "0A" or ":" not in f[1]:   # 0A: LISTEN
            continue
        addr, _, port_hex = f[1].rpartition(":")
        try:
            n = int(port_hex, 16)
        except ValueError:
            continue
        if n in OURS:
            continue
        inside = addr in ("0100007F", "00000000000000000000000001000000") or (len(addr) == 8 and addr.endswith("7F"))
        row = found.setdefault(n, {"port": n, "program": "", "inside": True})
        if not inside:
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
    # the processors' time so far (busy, all), from /proc/stat's first line
    first = (parts[4] if len(parts) > 4 else "").split()
    if first[:1] == ["cpu"]:
        n = [int(x) for x in first[1:] if x.isdigit()]
        if len(n) >= 4:
            idle = n[3] + (n[4] if len(n) > 4 else 0)
            out["cpu_busy"], out["cpu_all"] = sum(n) - idle, sum(n)
    # the bytes in and out of every interface but the loopback, from /proc/net/dev
    rx = tx = 0
    for line in (parts[5] if len(parts) > 5 else "").splitlines():
        name, _, rest = line.partition(":")
        f = rest.split()
        if rest and name.strip() != "lo" and len(f) >= 9 and f[0].isdigit() and f[8].isdigit():
            rx, tx = rx + int(f[0]), tx + int(f[8])
    out["net_rx"], out["net_tx"] = rx, tx
    # the busiest programs, as `ps -eo pid=,comm=,pcpu=,rss= --sort=-pcpu` gives them
    procs = []
    for line in (parts[6] if len(parts) > 6 else "").splitlines():
        f = line.split()
        if len(f) >= 4 and f[0].isdigit() and f[-1].isdigit():
            try:
                procs.append({"pid": int(f[0]), "name": " ".join(f[1:-2]), "cpu": float(f[-2]), "rss": int(f[-1]) * 1024})
            except ValueError:
                continue
    out["procs"] = procs[:8]
    try:
        out["cpus"] = int((parts[7] if len(parts) > 7 else "").split()[0])
    except (IndexError, ValueError):
        out["cpus"] = 0
    return out


def reason(err: str) -> str:
    """Why a connection or a forward failed, said by its family (read from what OpenSSH prints)."""
    low = (err or "").lower()
    if "host key" in low or "remote host identification" in low:
        return "the sandbox's host key is not the one remembered at its first connection: nothing was opened"
    if "permission denied" in low or "publickey" in low:
        return "the sandbox refused the key: it is not the sandbox this key was made for, or its setup did not finish"
    if "connection refused" in low:
        return "the sandbox refused the connection: its SSH server is not up (yet)"
    if "could not resolve" in low or "name or service not known" in low:
        return "the sandbox's name was not found: Fly.io's private network is not reached"
    if "timed out" in low or "did not answer" in low:
        return "the sandbox did not answer in time"
    if "address already in use" in low or "cannot listen" in low or "port forwarding failed" in low:
        return "the port is already taken on the other side"
    text = (err or "").strip()
    return "the sandbox did not answer" + ((": " + text[-160:]) if text else "")


RETRY = (5.0, 15.0, 30.0, 60.0)   # after a connection is lost: when to try again, then every minute, ten times in all
SOCKS_PORT = 1080                 # the usual port of a SOCKS proxy; the next free one when it is taken


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
    def __init__(self, sandboxes, relay: Relay, home: str, ssh: str = "ssh", flyctl: str | None = None, engine_port: int = 0):
        self.sandboxes = sandboxes
        self.engine_port = engine_port   # the way back to the Second Brain leads there, through a guarded relay
        self.brain_port = 8765           # where the sandbox finds it (its MCP configuration says so)
        self.relay = relay
        self.home = home
        self.ssh = ssh
        self.flyctl = flyctl
        self.links: dict[str, dict] = {}    # sandbox id -> its connection: the two processes, the ports opened
        self.lost: dict[str, dict] = {}     # sandbox id -> a connection that fell: why, how many tries, when the next one
        self.lock = threading.Lock()
        self._watching = False
        with closing(self._db()) as db, db:
            # what was opened for a sandbox is remembered, and opened again when its connection comes back:
            # « in » a port of the sandbox brought here, « socks » its proxy, « out » a port of this computer the
            # sandbox may reach (a rule the owner made)
            db.execute("CREATE TABLE IF NOT EXISTS sandbox_ports (sandbox TEXT NOT NULL, kind TEXT NOT NULL, port INTEGER NOT NULL, "
                       "local INTEGER NOT NULL DEFAULT 0, label TEXT NOT NULL DEFAULT '', PRIMARY KEY (sandbox, kind, port))")

    def _db(self):
        return self.sandboxes._db()

    def _remember(self, sbid: str, kind: str, port: int, local: int, label: str) -> None:
        with closing(self._db()) as db, db:
            db.execute("INSERT OR REPLACE INTO sandbox_ports (sandbox, kind, port, local, label) VALUES (?, ?, ?, ?, ?)", (sbid, kind, port, local, label))

    def _forget(self, sbid: str, kind: str, port: int) -> None:
        with closing(self._db()) as db, db:
            db.execute("DELETE FROM sandbox_ports WHERE sandbox = ? AND kind = ? AND port = ?", (sbid, kind, port))

    def remembered(self, sbid: str) -> list[dict]:
        with closing(self._db()) as db, db:
            return [{"kind": r[0], "port": r[1], "local": r[2], "label": r[3]}
                    for r in db.execute("SELECT kind, port, local, label FROM sandbox_ports WHERE sandbox = ? ORDER BY kind, port", (sbid,))]

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
            raise ValueError(reason(err))
        with self.lock:
            self.links[sbid] = link
            self.lost.pop(sbid, None)
        self._hold_back(sbid)
        for r in self.remembered(sbid):   # what was open for this sandbox comes back with its connection
            try:
                if r["kind"] == "in":
                    self.open_port(sbid, r["port"], r["local"], r["label"])
                elif r["kind"] == "socks":
                    self.open_socks(sbid, r["local"])
                elif r["kind"] == "out":
                    self.open_back(sbid, r["port"], r["local"])
            except (ValueError, KeyError, OSError):
                pass   # a port taken meanwhile, a program gone: the line says so, the others still open
        self._watch()
        return self.describe(sbid)

    def _hold_back(self, sbid: str) -> None:
        """The way back to the Second Brain, carried by this lasting connection, so an agent in the sandbox keeps the
        Brain when its terminal is closed. It lands on a relay that lets through only the Brain's route and the
        health. When the terminal's connection holds the port already, this one waits and takes it over later."""
        if not self.engine_port:
            return
        with self.lock:
            link = self.links.get(sbid)
        if not link or (link.get("back") or {}).get("held"):
            return
        if not link.get("back"):
            ch = self.relay.open(self.engine_port, label="the way back to the Second Brain", guard=brain_paths)
            link["back"] = {"channel": ch["id"], "spec": f"{LOOPBACK}:{self.brain_port}:{LOOPBACK}:{ch['port']}", "held": False}
        rc, _, _ = self._run(link, "-O", "forward", "-R", link["back"]["spec"], "root@127.0.0.1")
        link["back"]["held"] = rc == 0

    def disconnect(self, sbid: str, forget_lost: bool = True) -> dict:
        with self.lock:
            link = self.links.pop(sbid, None)
            if forget_lost:
                self.lost.pop(sbid, None)   # asked for: nothing tries again
        if link:
            if link.get("back"):
                try:
                    self.relay.close(link["back"]["channel"], "the connection was closed")
                except KeyError:
                    pass
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
        link["ports"][port] = {"kind": "in", "port": port, "inner": inner, "flag": "-L", "spec": spec, "channel": ch["id"], "label": ch["label"]}
        self._remember(sbid, "in", port, ch["port"], ch["label"])   # the same address next time: a bookmark keeps working
        return self._port_row(link, port)

    def open_socks(self, sbid: str, local: int = 0) -> dict:
        """A SOCKS proxy toward the sandbox, on this computer only: through it, a program here reaches whatever
        the sandbox itself reaches (every port inside it, by one address)."""
        link = self._link(sbid)
        if "socks" in link["ports"]:
            return self._port_row(link, "socks")
        inner = free_port()
        spec = f"{LOOPBACK}:{inner}"
        rc, _, err = self._run(link, "-O", "forward", "-D", spec, "root@127.0.0.1")
        if rc != 0:
            raise ValueError(reason(err or "port forwarding failed"))
        ch = self.relay.open(inner, port=int(local) or SOCKS_PORT, label="SOCKS proxy")
        link["ports"]["socks"] = {"kind": "socks", "port": 0, "inner": inner, "flag": "-D", "spec": spec, "channel": ch["id"], "label": "SOCKS proxy"}
        self._remember(sbid, "socks", 0, ch["port"], "SOCKS proxy")
        return self._port_row(link, "socks")

    def open_back(self, sbid: str, port: int, there: int = 0, label: str = "") -> dict:
        """A rule the owner makes: a port of this computer becomes reachable from inside the sandbox, on the same
        number there (or `there`). Nothing of this computer is reachable from a sandbox without such a rule, except
        the way back to the Second Brain that every sandbox has. What passes is counted like the rest."""
        port = int(port)
        there = int(there) or port
        if not 1 <= port <= 65535 or there in OURS:
            raise ValueError("this port is not one to open")
        link = self._link(sbid)
        key = f"out:{port}"
        if key in link["ports"]:
            return self._port_row(link, key)
        ch = self.relay.open(port, label=label or f"this computer's {port}")   # the relay stands before the local program
        spec = f"{LOOPBACK}:{there}:{LOOPBACK}:{ch['port']}"
        rc, _, err = self._run(link, "-O", "forward", "-R", spec, "root@127.0.0.1")
        if rc != 0:
            self.relay.close(ch["id"])
            raise ValueError(reason(err or "port forwarding failed"))
        link["ports"][key] = {"kind": "out", "port": port, "there": there, "flag": "-R", "spec": spec, "channel": ch["id"], "label": ch["label"]}
        self._remember(sbid, "out", port, there, ch["label"])
        return self._port_row(link, key)

    def _close(self, sbid: str, key, kind: str, port: int) -> dict:
        link = self._link(sbid)
        row = link["ports"].pop(key, None)
        if row is None:
            raise KeyError(key)
        closed = self.relay.close(row["channel"])
        self._run(link, "-O", "cancel", row["flag"], row["spec"], "root@127.0.0.1")
        self._forget(sbid, kind, port)   # closed by the owner: not opened again by itself
        return {**closed, "kind": kind, "remote_port": row.get("there", row["port"])}

    def close_socks(self, sbid: str) -> dict:
        return self._close(sbid, "socks", "socks", 0)

    def close_back(self, sbid: str, port: int) -> dict:
        return self._close(sbid, f"out:{int(port)}", "out", int(port))

    def close_port(self, sbid: str, port: int) -> dict:
        return self._close(sbid, int(port), "in", int(port))

    def pause_port(self, sbid: str, port: int, paused: bool = True) -> dict:
        link = self._link(sbid)
        row = link["ports"][int(port)]
        (self.relay.pause if paused else self.relay.resume)(row["channel"])
        return self._port_row(link, int(port))

    def _port_row(self, link: dict, key) -> dict:
        row = link["ports"][key]
        ch = next((c for c in self.relay.describe() if c["id"] == row["channel"]), {})
        out = {**ch, "kind": row["kind"], "remote_port": row.get("there", row["port"])}
        if row["kind"] == "socks":
            out["address"] = f"socks5://{LOOPBACK}:{ch.get('port', 0)}"
        elif row["kind"] == "out":
            out["local_port"] = row["port"]   # the program of this computer the sandbox reaches
        return out

    # ---------------------------------------------------------------- what the sandbox tells
    def listening(self, sbid: str) -> list[dict]:
        """What listens in the sandbox now, with for each port whether it is brought here."""
        link = self._link(sbid)
        rc, out, _ = self._run(link, "root@127.0.0.1", "ss -Hltnp 2>/dev/null; echo ---PROC---; cat /proc/net/tcp /proc/net/tcp6 2>/dev/null")
        ss_part, _, proc_part = out.partition("---PROC---")
        rows = parse_listening(ss_part) if rc == 0 else []
        if rc == 0 and not rows:   # no `ss` there: the kernel's own list (without program names)
            rows = parse_proc_net(proc_part)
        for r in rows:
            r["open"] = r["port"] in link["ports"]
        # a port of this computer that the sandbox reaches listens there too: it is not one of the sandbox's own
        mine = {row.get("there") for row in link["ports"].values() if row["kind"] == "out"}
        rows = [r for r in rows if r["port"] not in mine]
        link["listening_last"] = rows
        return rows

    HEALTH_KEEP = 180   # readings kept per sandbox: fifteen minutes at one every five seconds

    def health(self, sbid: str, workdir: str = "/work") -> dict:
        """How the sandbox is doing now (one command, through the connection), with what it did lately: the share
        of its processors that was busy and the bytes in and out per second since the reading before, and the
        readings of the last fifteen minutes for the curves."""
        link = self._link(sbid)
        began = time.monotonic()
        rc, out, _ = self._run(link, "root@127.0.0.1",
                               "cat /proc/meminfo; echo ---; cat /proc/loadavg; echo ---; cat /proc/uptime; echo ---; df -B1 -P " + workdir
                               + " 2>/dev/null; echo ---; head -1 /proc/stat; echo ---; cat /proc/net/dev; echo ---;"
                               " ps -eo pid=,comm=,pcpu=,rss= --sort=-pcpu | head -8; echo ---; nproc")
        took = time.monotonic() - began
        if rc != 0:
            return {}
        h = {**parse_health(out), "round_trip_ms": round(took * 1000)}
        steady = time.monotonic()
        before = link.get("health_prev")
        h["cpu"] = None
        h["rx_rate"] = h["tx_rate"] = None
        if before and steady > before["at"]:
            dt = steady - before["at"]
            if h.get("cpu_all", 0) > before.get("cpu_all", 0):
                h["cpu"] = max(0.0, min(1.0, (h["cpu_busy"] - before["cpu_busy"]) / (h["cpu_all"] - before["cpu_all"])))
            if h["net_rx"] >= before["net_rx"] and h["net_tx"] >= before["net_tx"]:
                h["rx_rate"], h["tx_rate"] = (h["net_rx"] - before["net_rx"]) / dt, (h["net_tx"] - before["net_tx"]) / dt
        link["health_prev"] = {"at": steady, "cpu_busy": h.get("cpu_busy", 0), "cpu_all": h.get("cpu_all", 0), "net_rx": h["net_rx"], "net_tx": h["net_tx"]}
        hist = link.setdefault("health_hist", [])
        if h["cpu"] is not None and (not hist or steady - hist[-1]["at"] >= 2.0):
            hist.append({"at": steady, "t": time.time(), "cpu": h["cpu"], "mem": h["memory_used"], "rx": h["rx_rate"], "tx": h["tx_rate"], "load": h["load"]})
            del hist[:-self.HEALTH_KEEP]
        h["history"] = [{k: v for k, v in x.items() if k != "at"} for x in hist]
        link["health_last"] = h
        return h

    def last_read(self, sbid: str) -> tuple[dict, list]:
        """How the sandbox was doing and what listened there, as the watch last read them (every five seconds):
        what the page asks every few seconds is answered from here, without going to the sandbox each time."""
        with self.lock:
            link = self.links.get(sbid)
        if not link:
            return {}, []
        listening = [dict(r, open=r["port"] in link["ports"]) for r in link.get("listening_last", [])]
        return link.get("health_last", {}), listening

    def describe(self, sbid: str) -> dict:
        with self.lock:
            link = self.links.get(sbid)
            lost = dict(self.lost.get(sbid, {}))
        if not link:
            if lost:   # it fell: said with why, how many times it was tried, and when the next try comes
                return {"id": sbid, "state": "lost", "ports": [], "why": lost["why"], "tries": lost["tries"],
                        "retry_in": max(0.0, lost["next"] - time.monotonic()) if lost["tries"] < 10 else -1.0}
            return {"id": sbid, "state": "closed", "ports": []}
        up = link["master"] is not None and link["master"].poll() is None and link["proxy"].poll() is None
        ports = [self._port_row(link, p) for p in sorted(link["ports"], key=str)]
        b = link.get("back") or {}
        way = "carrier" if b.get("held") else ("terminal" if b else "none")
        refused = next((int(c.get("denied", 0)) for c in self.relay.describe() if c["id"] == b.get("channel")), 0)
        return {"id": sbid, "state": "open" if up else "lost", "since": link["since"], "ports": ports,
                "brain_way": way, "brain_refused": refused,
                "sent": sum(int(p.get("sent", 0)) for p in ports), "received": sum(int(p.get("received", 0)) for p in ports),
                "sent_rate": sum(float(p.get("sent_rate", 0.0)) for p in ports), "received_rate": sum(float(p.get("received_rate", 0.0)) for p in ports)}

    def watch_once(self) -> list[str]:
        """Looks at every connection: one that fell is closed properly and noted as lost; a lost one is tried again
        when its time has come (after 5, 15, 30 seconds, then every minute, ten times). Gives the ones it brought back.
        A connection the owner closed is never tried again, and a paused machine is never started."""
        with self.lock:
            fallen = [sbid for sbid, link in self.links.items() if link["master"].poll() is not None or link["proxy"].poll() is not None]
        for sbid in fallen:
            self.disconnect(sbid, forget_lost=False)
            with self.lock:
                self.lost[sbid] = {"why": "the connection fell", "tries": 0, "next": time.monotonic() + RETRY[0]}
        with self.lock:
            due_health = [sbid for sbid, link in self.links.items() if time.monotonic() - link.get("health_prev", {}).get("at", 0.0) >= 5.0]
        for sbid in due_health:
            try:
                self.health(sbid)
                self.listening(sbid)
            except (ValueError, OSError):
                pass
        with self.lock:
            waiting = [sbid for sbid, link in self.links.items() if link.get("back") and not link["back"]["held"]]
        for sbid in waiting:   # the terminal held the way back: take it over once it is free
            self._hold_back(sbid)
        back = []
        with self.lock:
            due = [sbid for sbid, x in self.lost.items() if x["tries"] < 10 and time.monotonic() >= x["next"]]
        for sbid in due:
            try:
                self.connect(sbid)
                back.append(sbid)
            except (ValueError, KeyError, OSError, RuntimeError) as e:
                with self.lock:
                    x = self.lost.setdefault(sbid, {"why": "", "tries": 0, "next": 0.0})
                    x["tries"] += 1
                    x["why"] = str(e)
                    x["next"] = time.monotonic() + RETRY[min(x["tries"], len(RETRY) - 1)]
        return back

    def _watch(self) -> None:
        if self._watching:
            return
        self._watching = True

        def loop() -> None:
            while True:
                time.sleep(3.0)
                try:
                    self.watch_once()
                except Exception:  # noqa: BLE001: the watch itself must not die
                    pass
        threading.Thread(target=loop, daemon=True, name="carrier-watch").start()

    def close_all(self) -> None:
        with self.lock:
            ids = list(self.links)
        for sbid in ids:
            self.disconnect(sbid)
