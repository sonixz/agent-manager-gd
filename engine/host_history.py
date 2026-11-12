"""What the computer under the engine was over time (Loop 36, the dashboard): one reading every 30 seconds, kept
seven days (owner, 2026-11-12), in a database of its own beside the sessions'. It only reads /proc and asks tmux
which sessions live. Deleting the file loses the curves and nothing else.

Settings (environment): AGMGD_HOST_SAMPLE is the number of seconds between two readings (30); 0 or off stops them.
"""
from __future__ import annotations

import math
import os
import sqlite3
import threading
import time
from contextlib import closing

from . import host
from .tmux import PREFIX

INTERVAL = 30
KEEP = 7 * 86400

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    ts INTEGER PRIMARY KEY,
    mem_total INTEGER NOT NULL,
    mem_used INTEGER NOT NULL,
    mem_held INTEGER NOT NULL,
    swap_used INTEGER NOT NULL,
    load REAL NOT NULL,
    cpu REAL,
    sessions INTEGER NOT NULL,
    sessions_bytes INTEGER NOT NULL,
    engine_bytes INTEGER NOT NULL,
    engine_cpu REAL
);
CREATE TABLE IF NOT EXISTS session_samples (
    ts INTEGER NOT NULL,
    sid TEXT NOT NULL,
    bytes INTEGER NOT NULL,
    cpu REAL,
    PRIMARY KEY (ts, sid)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS session_names (
    sid TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    first_ts INTEGER NOT NULL,
    last_ts INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS marks (
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    PRIMARY KEY (ts, kind)
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""
# samples.cpu: the share of all the processors that was busy since the reading before, 0 to 1.
# session_samples.cpu and samples.engine_cpu: processors' worth, 1.0 is one processor busy the whole time.
# marks: « engine » when the engine started reading, « boot » when the computer (on Windows: WSL) had started anew.


def interval_from_env() -> int:
    raw = os.environ.get("AGMGD_HOST_SAMPLE", "").strip().lower()
    if raw in ("off", "no", "false"):
        return 0
    try:
        return max(0, int(float(raw))) if raw else INTERVAL
    except ValueError:
        return INTERVAL


class Watch:
    def __init__(self, path: str, interval: int = INTERVAL, keep: int = KEEP, proc: str = host.PROC, pid: int | None = None):
        self.path = path
        self.interval = max(1, int(interval))
        self.keep = int(keep)
        self.proc = proc
        self.pid = os.getpid() if pid is None else pid   # the engine itself: what the reading costs is shown too
        self.hz = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
        self.prev: dict | None = None   # the reading before, to tell processor time apart: uptime, per process, all
        self.last: dict = {}            # what the last reading found, for /host: the processor shares it worked out
        self.error = ""
        self._pruned = 0.0
        self._started = False
        self._lock = threading.Lock()
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with closing(self._db()) as db, db:
            db.executescript(SCHEMA)

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=5)
        db.execute("PRAGMA journal_mode=WAL")   # the page reads while a reading is written
        return db

    # ---------------------------------------------------------------- one reading
    def _busy(self, pids, procs: dict, elapsed: float) -> float | None:
        """Processors' worth this family used since the reading before; None when there is nothing to compare with."""
        prev = self.prev
        if prev is None or elapsed <= 0:
            return None
        ticks = 0
        for p in pids:
            now_ticks, start = procs[p][2], procs[p][3]
            before = prev["procs"].get(p)
            if before is not None and before[1] == start:
                ticks += max(0, now_ticks - before[0])
            elif start >= prev["up"] * self.hz:   # it started since the reading before: all its time counts
                ticks += now_ticks
        return ticks / self.hz / elapsed

    def tick(self, records: list[dict], live: dict, now: float | None = None) -> dict:
        """One reading, written down. `records` and `live` as in host.report."""
        with self._lock:
            now = int(time.time() if now is None else now)
            procs = host.scan(self.proc)
            up = host.uptime(self.proc)
            busy, every = host.cpu_times(self.proc)
            mem = host.memory(self.proc)
            prev = self.prev
            elapsed = (up - prev["up"]) if prev else 0.0   # the computer's own clock: the wall clock may be set back
            cpu = None
            if prev and elapsed > 0 and every > prev["every"]:
                cpu = min(1.0, max(0.0, (busy - prev["busy"]) / (every - prev["every"])))
            rows, shares = [], {}
            for r in records:
                t = live.get(PREFIX + str(r["id"]))
                if t is None or getattr(t, "pane_dead", False):
                    continue
                fam = host.family(int(t.pane_pid), procs)
                share = self._busy(fam, procs, elapsed)
                rows.append((str(r["id"]), str(r.get("name", "")), sum(procs[p][1] for p in fam), share))
                shares[str(r["id"])] = share
            mine = host.family(self.pid, procs)
            engine = {"bytes": sum(procs[p][1] for p in mine), "cpu": self._busy(mine, procs, elapsed)}
            boot = host._read(os.path.join(self.proc, "sys", "kernel", "random", "boot_id")).strip()
            with closing(self._db()) as db, db:
                if not self._started:
                    db.execute("INSERT OR IGNORE INTO marks (ts, kind) VALUES (?, 'engine')", (now,))
                    self._started = True
                known = db.execute("SELECT value FROM meta WHERE key = 'boot_id'").fetchone()
                if boot and (known is None or known[0] != boot):
                    if known is not None:   # the first reading ever knows of no start before it
                        db.execute("INSERT OR IGNORE INTO marks (ts, kind) VALUES (?, 'boot')", (max(0, now - int(up)),))
                    db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('boot_id', ?)", (boot,))
                db.execute("INSERT OR REPLACE INTO samples (ts, mem_total, mem_used, mem_held, swap_used, load, cpu, sessions, "
                           "sessions_bytes, engine_bytes, engine_cpu) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           (now, mem["total"], mem["used"], mem["held"], mem["swap_used"], host.load(self.proc), cpu,
                            len(rows), sum(x[2] for x in rows), engine["bytes"], engine["cpu"]))
                db.executemany("INSERT OR REPLACE INTO session_samples (ts, sid, bytes, cpu) VALUES (?, ?, ?, ?)",
                               [(now, sid, b, share) for sid, _, b, share in rows])
                db.executemany("INSERT INTO session_names (sid, name, first_ts, last_ts) VALUES (?, ?, ?, ?) "
                               "ON CONFLICT(sid) DO UPDATE SET name = excluded.name, last_ts = excluded.last_ts",
                               [(sid, name, now, now) for sid, name, _, _ in rows])
                if time.monotonic() - self._pruned > 3600 or self._pruned == 0.0:
                    self._prune(db, now)
                    self._pruned = time.monotonic()
            self.prev = {"up": up, "busy": busy, "every": every, "procs": {p: (v[2], v[3]) for p, v in procs.items()}}
            self.last = {"ts": now, "cpu": cpu, "sessions": shares, "engine": engine}
            self.error = ""
            return self.last

    def _prune(self, db: sqlite3.Connection, now: int) -> None:
        old = now - self.keep
        db.execute("DELETE FROM samples WHERE ts < ?", (old,))
        db.execute("DELETE FROM session_samples WHERE ts < ?", (old,))
        db.execute("DELETE FROM marks WHERE ts < ?", (old,))
        db.execute("DELETE FROM session_names WHERE last_ts < ?", (old,))

    # ---------------------------------------------------------------- what the page asks
    def about(self) -> dict:
        with closing(self._db()) as db:
            first, count = db.execute("SELECT MIN(ts), COUNT(*) FROM samples").fetchone()
        return {"interval": self.interval, "keep": self.keep, "since": int(first or 0), "readings": int(count or 0),
                "error": self.error}

    def series(self, seconds: int = 3600, points: int = 60, now: float | None = None) -> dict:
        """The last `seconds`, cut in at most about `points` equal slices that start on round times, so a slice does
        not slide as time passes. Each slice gives the average of its readings; None where there was no reading
        (the engine was not running). A session's memory is averaged over the slice's readings, the ones before it
        started or after it ended counting as nothing, so the sessions of a slice add up to their total."""
        now = int(time.time() if now is None else now)
        seconds = max(self.interval, min(int(seconds), self.keep))
        step = max(1, math.ceil(seconds / max(1, int(points)) / self.interval)) * self.interval
        b1 = now // step
        b0 = (now - seconds) // step + 1
        n = b1 - b0 + 1
        blank = [None] * n
        out = {"interval": self.interval, "keep": self.keep, "step": step, "from": b0 * step, "to": now,
               "t": [(b0 + i) * step for i in range(n)], "readings": [0] * n, "total": 0,
               "used": list(blank), "used_peak": list(blank), "held": list(blank), "cpu": list(blank),
               "load": list(blank), "engine_bytes": list(blank), "engine_cpu": list(blank),
               "sessions": [], "marks": [], "since": 0}   # no « error » key: to the app, an answer that has one failed
        with closing(self._db()) as db:
            for b, c, used, peak, held, cpu, load, total, eb, ec in db.execute(
                    "SELECT ts / ?, COUNT(*), AVG(mem_used), MAX(mem_used), AVG(mem_held), AVG(cpu), AVG(load), "
                    "MAX(mem_total), AVG(engine_bytes), AVG(engine_cpu) FROM samples WHERE ts >= ? AND ts <= ? "
                    "GROUP BY 1", (step, b0 * step, now)):
                i = b - b0
                out["readings"][i] = c
                out["used"][i], out["used_peak"][i], out["held"][i] = int(used), int(peak), int(held)
                out["cpu"][i], out["load"][i] = cpu, load
                out["engine_bytes"][i], out["engine_cpu"][i] = int(eb), ec
                out["total"] = max(out["total"], int(total or 0))
            by: dict[str, dict] = {}
            for b, sid, total_bytes, peak, cpu in db.execute(
                    "SELECT ts / ?, sid, SUM(bytes), MAX(bytes), SUM(cpu) FROM session_samples WHERE ts >= ? AND ts <= ? "
                    "GROUP BY 1, 2", (step, b0 * step, now)):
                i = b - b0
                s = by.setdefault(sid, {"id": sid, "name": "", "bytes": [0 if c else None for c in out["readings"]],
                                        "cpu": [None] * n, "peak": 0, "first": 0, "last": 0})
                c = out["readings"][i] or 1
                s["bytes"][i] = int(total_bytes / c)
                s["cpu"][i] = None if cpu is None else cpu / c
                s["peak"] = max(s["peak"], int(peak))
            if by:
                marks = ",".join("?" * len(by))
                for sid, name, first, last in db.execute(
                        f"SELECT sid, name, first_ts, last_ts FROM session_names WHERE sid IN ({marks})", list(by)):
                    by[sid].update(name=name, first=first, last=last)
            out["sessions"] = sorted(by.values(), key=lambda s: (s["first"], s["id"]))   # an order that does not move
            out["marks"] = [{"ts": ts, "kind": kind} for ts, kind in db.execute(
                "SELECT ts, kind FROM marks WHERE ts >= ? AND ts <= ? ORDER BY ts", (b0 * step, now))]
            out["since"] = int(db.execute("SELECT MIN(ts) FROM samples").fetchone()[0] or 0)
        return out


def run(watch: Watch, sessions) -> None:
    """The engine's reading thread. A reading that fails is said on the page and never stops the engine."""
    while True:
        started = time.monotonic()
        try:
            watch.tick(sessions.store.all(), sessions.tmux.sessions())
        except Exception as e:  # noqa: BLE001: whatever it is, the next reading tries again
            watch.error = f"{type(e).__name__}: {e}"[:200]
        time.sleep(max(1.0, watch.interval - (time.monotonic() - started)))


def start(sessions, home: str) -> Watch | None:
    """Starts the readings for this engine, unless the setting says not to."""
    every = interval_from_env()
    if every <= 0:
        return None
    watch = Watch(os.path.join(home, "data", "host_history.sqlite3"), every)
    threading.Thread(target=run, args=(watch, sessions), daemon=True, name="host-history").start()
    return watch
