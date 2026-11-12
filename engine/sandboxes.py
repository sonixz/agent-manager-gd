"""Cloud sandboxes on Fly.io (Loop 13): throw-away machines for agent sessions, managed by the owner.

One Fly app per Agent Manager install (« agmgd-<id> ») holds the sandbox machines and the image (built once by Fly's
remote builder into the organisation's private registry). One machine per sandbox, with its own SSH key (our sshd on
port 2222; Fly's own SSH on 22 gives programs no usable terminal). The session's terminal is a local tmux session
running engine/sandbox_attach.py: `flyctl proxy` + `ssh -t … tmux new -A -s am`, and the same connection carries the
reverse tunnel for the Second Brain (sandbox 127.0.0.1:8765 → the engine's /sandbox-brain/<secret>).

**Never destroyed automatically.** Destroy is the owner's act, confirmed, after Agent Manager showed the work not
pushed. Stop (pause) keeps the machine's files. Machines and apps of the organisation that Agent Manager does not know
are listed as orphans and never touched."""
from __future__ import annotations

import json
import os
import secrets
import shutil
import sqlite3
import subprocess
import time
from contextlib import closing

FLYCTL = os.environ.get("AGMGD_FLYCTL") or os.path.expanduser("~/.local/opt/flyctl/flyctl")
HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE_DIR = os.path.join(os.path.dirname(HERE), "sandbox")
# docs.fly.io/about/pricing, read 2026-11-08 (no date on the page): USD per month while started / per GB-month stopped
PRICES = {"shared-cpu-1x-1024": 6.70}
STOPPED_GB_MONTH = 0.15
PRICE_SOURCE = "docs.fly.io/about/pricing, read 2026-11-08"
SCHEMA = """
CREATE TABLE IF NOT EXISTS sandboxes (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL DEFAULT '',
    app TEXT NOT NULL,
    machine TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL,
    size TEXT NOT NULL,
    secret TEXT NOT NULL,
    brain_client TEXT NOT NULL DEFAULT '',
    repo_id TEXT NOT NULL DEFAULT '',
    workdir TEXT NOT NULL DEFAULT '/work',
    finished INTEGER NOT NULL DEFAULT 0,
    destroyed INTEGER NOT NULL DEFAULT 0,
    created REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS sandbox_config (k TEXT PRIMARY KEY, v TEXT NOT NULL);
-- Loop 16: every period a machine ran, copied from Fly's machine history (kept after the machine is destroyed)
CREATE TABLE IF NOT EXISTS sandbox_runs (sandbox TEXT NOT NULL, size TEXT NOT NULL, start REAL NOT NULL, stop REAL,
    PRIMARY KEY (sandbox, start));
"""
# What our image holds (sandbox/Dockerfile): shown before the owner deploys it
IMAGE_CONTENTS = [
    ("Ubuntu 24.04", "the base system"),
    ("tmux", "the session keeps running when the terminal closes"),
    ("git + OpenSSH", "clones your connected repository with its own deploy key"),
    ("SSH server, port 2222", "keys only, no password; one key per sandbox"),
    ("Node.js + Python 3", "for the agents and your tools"),
    ("Claude Code", "latest version at build time; uses your Anthropic key from Keys"),
    ("Codex", "latest version at build time; uses your OpenAI key from Keys"),
]
HOURS_PER_MONTH = 730
IMAGE_GB = 1.0  # a machine's root disk, roughly our image: what a stopped (paused) machine is billed for


class Fly:
    """flyctl with the owner's token from Keys, given through the environment only."""

    def __init__(self, token_fn):
        self.token_fn = token_fn

    def available(self) -> bool:
        return os.path.exists(FLYCTL) and bool(self.token_fn())

    def env(self) -> dict:
        return {**os.environ, "FLY_API_TOKEN": self.token_fn(), "FLY_NO_UPDATE_CHECK": "1"}

    def run(self, *args: str, timeout: int = 600, cwd: str | None = None, inp: str | None = None) -> tuple[int, str]:
        out = subprocess.run([FLYCTL, *args], capture_output=True, text=True, env=self.env(), timeout=timeout, cwd=cwd, input=inp)
        return out.returncode, (out.stdout + out.stderr).strip()

    def json(self, *args: str) -> object:
        rc, out = self.run(*args, "--json", timeout=120)
        if rc != 0:
            raise RuntimeError(out[-300:])
        start = min([i for i in (out.find("["), out.find("{")) if i >= 0] or [0])
        return json.loads(out[start:])


class DemoFly:
    """Captures only (AGMGD_DEMO_FLY=<json file>): machines, apps and health read from a file, every command a no-op.
    Never used unless that variable is set; nothing reaches Fly.io."""

    def __init__(self, path: str):
        self.path = path

    @property
    def data(self) -> dict:  # read on every call: the capture script writes it after the engine started
        try:
            with open(self.path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def available(self) -> bool:
        return True

    def env(self) -> dict:
        return dict(os.environ)

    def run(self, *args, timeout=0, cwd=None, inp=None):
        if args[:2] == ("machine", "run"):  # a real machine takes 6 to 30 seconds to start: the checks can ask for that wait
            time.sleep(float(os.environ.get("AGMGD_DEMO_FLY_DELAY") or 0))
        return 0, "demo"

    def json(self, *args):
        if args[:2] == ("machine", "list"):
            return self.data.get("machines", [])
        if args[:2] == ("apps", "list"):
            return self.data.get("apps", [])
        if args[:2] == ("orgs", "list"):
            return {"agent-manager": "Agent Manager"}
        return []


class Sandboxes:
    def __init__(self, db_path: str, home: str, keys, fly: Fly | None = None):
        self.db_path = db_path
        self.home = home
        self.keys = keys
        demo = os.environ.get("AGMGD_DEMO_FLY", "")
        self.fly = fly or (DemoFly(demo) if demo else Fly(lambda: keys.get("fly")))
        self.key_dir = os.path.join(home, "keys", "sandbox")
        self.health: dict[str, dict] = {}  # Loop 16: the last check of each running sandbox (sandbox_ops.monitor)
        with closing(self._db()) as db, db:
            db.executescript(SCHEMA)

    def _db(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    # ---------------------------------------------------------------- configuration
    def config(self, k: str, default: str = "") -> str:
        with closing(self._db()) as db:
            r = db.execute("SELECT v FROM sandbox_config WHERE k = ?", (k,)).fetchone()
        return r[0] if r else default

    def set_config(self, k: str, v: str) -> None:
        with closing(self._db()) as db, db:
            db.execute("INSERT OR REPLACE INTO sandbox_config VALUES (?, ?)", (k, v))

    _job: dict = {}   # the « prepare » job running in the background: {"state": preparing|error|done, "message"}

    def status(self) -> dict:
        ready = bool(self.config("image"))
        demo = isinstance(self.fly, DemoFly)
        return {"flyctl": demo or os.path.exists(FLYCTL), "token": demo or bool(self.keys.describe("fly")["set"]),
                "org": self.config("org"), "app": self.config("app"), "image": self.config("image"), "ready": ready,
                "region": self.config("region", "yyz"), "prices": PRICE_SOURCE, "job": dict(self._job)}

    def prepare_async(self, org: str = "", region: str = "yyz") -> dict:
        """Starts « prepare » in the background (the image build takes minutes); the status shows its progress."""
        import threading
        if self._job.get("state") == "preparing":
            return self.status()
        self._job.clear()
        self._job.update(state="preparing", message="creating the app and building our image (about 2 minutes)")

        def go():
            try:
                self.prepare(org, region)
                self._job.update(state="done", message="ready")
            except Exception as e:  # shown to the owner
                self._job.update(state="error", message=str(e)[:300])
        threading.Thread(target=go, daemon=True).start()
        return self.status()

    def prepare(self, org: str = "", region: str = "yyz") -> dict:
        """Once: the app for sandboxes in the organisation, and our image built by Fly into its private registry."""
        if not self.fly.available():
            raise ValueError("Fly.io is not ready: paste the Fly token in Keys (and flyctl must be installed)")
        if not org:
            orgs = self.fly.json("orgs", "list")
            org = sorted(orgs.keys())[0] if isinstance(orgs, dict) and orgs else ""
        if not org:
            raise ValueError("no Fly organisation found for this token")
        app = self.config("app") or "agmgd-" + secrets.token_hex(4)
        if not self.config("app"):
            rc, out = self.fly.run("apps", "create", app, "--org", org)
            if rc != 0:
                raise ValueError("could not create the Fly app: " + out[-200:])
        self.set_config("org", org)
        self.set_config("app", app)
        self.set_config("region", region)
        # a new app has no machine to take a configuration from: give flyctl a minimal fly.toml in a copy of the folder
        import tempfile
        with tempfile.TemporaryDirectory(prefix="agmgd-image-") as tmp:
            for name in os.listdir(IMAGE_DIR):
                shutil.copy(os.path.join(IMAGE_DIR, name), tmp)
            with open(os.path.join(tmp, "fly.toml"), "w", encoding="utf-8") as f:
                f.write(f'app = "{app}"\nprimary_region = "{region}"\n\n[build]\n  dockerfile = "Dockerfile"\n')
            rc, out = self.fly.run("deploy", "--build-only", "--push", "--remote-only", "--app", app, "--image-label", "v1",
                                   "--config", os.path.join(tmp, "fly.toml"), cwd=tmp, timeout=1800)
        if rc != 0:
            raise ValueError("the image did not build: " + out[-300:])
        self.set_config("image", f"registry.fly.io/{app}:v1")
        self.set_config("image_built", str(time.time()))
        return self.status()

    # ---------------------------------------------------------------- records
    def key_path(self, sbid: str) -> str:
        return os.path.join(self.key_dir, sbid, "id_ed25519")

    def get(self, sbid: str) -> dict:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM sandboxes WHERE id = ?", (sbid,)).fetchone()
        if not r:
            raise KeyError(sbid)
        return dict(r)

    def by_session(self, sid: str) -> dict | None:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM sandboxes WHERE session_id = ? AND destroyed = 0", (sid,)).fetchone()
        return dict(r) if r else None

    def by_secret(self, secret: str) -> dict | None:
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM sandboxes WHERE secret = ? AND destroyed = 0", (secret,)).fetchone()
        return dict(r) if r else None

    def all(self) -> list[dict]:
        with closing(self._db()) as db:
            return [dict(r) for r in db.execute("SELECT * FROM sandboxes ORDER BY created DESC")]

    def _set(self, sbid: str, **f) -> None:
        sets = ", ".join(f"{k} = ?" for k in f)
        with closing(self._db()) as db, db:
            db.execute(f"UPDATE sandboxes SET {sets} WHERE id = ?", (*f.values(), sbid))

    # ---------------------------------------------------------------- lifecycle
    def create(self, session_id: str, size: str = "shared-cpu-1x-1024", repo_id: str = "") -> dict:
        st = self.status()
        if not st["ready"]:
            raise ValueError("cloud sandboxes are not prepared yet (Sandboxes → Prepare)")
        self.guard_new()
        sbid = secrets.token_hex(4)
        os.makedirs(os.path.dirname(self.key_path(sbid)), mode=0o700, exist_ok=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"agent-manager-gd:sandbox-{sbid}",
                        "-f", self.key_path(sbid)], check=True, capture_output=True, timeout=30)
        with open(self.key_path(sbid) + ".pub", encoding="utf-8") as f:
            pub = f.read().strip()
        cpus, mem = "1", size.rsplit("-", 1)[-1]
        rc, out = self.fly.run("machine", "run", st["image"], "--app", st["app"], "--region", st["region"],
                               "--vm-cpus", cpus, "--vm-memory", mem, "--name", "sandbox-" + sbid,
                               "--env", "AGMGD_AUTHORIZED_KEY=" + pub, "--metadata", "agmgd=" + sbid, timeout=900)
        if rc != 0:
            shutil.rmtree(os.path.dirname(self.key_path(sbid)), ignore_errors=True)
            raise ValueError("the sandbox did not start: " + out[-300:])
        machine = ""
        for _ in range(1 if isinstance(self.fly, DemoFly) else 10):  # a new machine can take a few seconds to show in Fly's list
            machine = next((m["id"] for m in self.machines() if m.get("name") == "sandbox-" + sbid), "")
            if machine:  # without its id the sandbox could never be reached (the terminal looks it up again, by name)
                break
            time.sleep(1)
        with closing(self._db()) as db, db:
            db.execute("INSERT INTO sandboxes (id, session_id, app, machine, region, size, secret, repo_id, created) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (sbid, session_id, st["app"], machine, st["region"], size,
                                                               secrets.token_urlsafe(24), repo_id, time.time()))
        return self.get(sbid)

    def machines(self) -> list[dict]:
        app = self.config("app")
        return list(self.fly.json("machine", "list", "--app", app)) if app else []

    def start(self, sbid: str) -> dict:
        sb = self.get(sbid)
        rc, out = self.fly.run("machine", "start", sb["machine"], "--app", sb["app"], timeout=300)
        if rc != 0:
            raise ValueError(out[-200:])
        return self.get(sbid)

    def stop(self, sbid: str) -> dict:
        sb = self.get(sbid)
        rc, out = self.fly.run("machine", "stop", sb["machine"], "--app", sb["app"], timeout=300)
        if rc != 0:
            raise ValueError(out[-200:])
        return self.get(sbid)

    def mark_finished(self, sbid: str, finished: bool = True) -> None:
        self._set(sbid, finished=int(finished))

    def unpushed(self, sbid: str, ssh) -> dict:
        """What would be lost: uncommitted changes and commits not on their remote, per repository in the workdir."""
        sb = self.get(sbid)
        script = ("for d in " + sb["workdir"] + "/*/; do [ -d \"$d/.git\" ] || continue; echo \"== $d\"; "
                  "git -C \"$d\" status --porcelain | head -20; git -C \"$d\" log --oneline @{u}.. 2>/dev/null | head -20 "
                  "|| git -C \"$d\" log --oneline -5; done")
        rc, out = ssh(sbid, script)
        return {"checked": rc == 0, "report": out if rc == 0 else "could not reach the sandbox: " + out[-200:],
                "clean": rc == 0 and all(not l.strip() or l.startswith("==") for l in out.splitlines())}

    def destroy(self, sbid: str, confirmed: bool, brain=None) -> dict:
        """Only on the owner's confirmed request (the app asks, after showing unpushed work)."""
        if not confirmed:
            raise ValueError("destroying needs the owner's confirmation")
        sb = self.get(sbid)
        rc, out = self.fly.run("machine", "destroy", sb["machine"], "--app", sb["app"], "--force", timeout=300)
        if rc != 0 and "not found" not in out.lower():
            raise ValueError(out[-200:])
        if brain and sb["brain_client"]:
            brain.revoke(sb["brain_client"])
        shutil.rmtree(os.path.dirname(self.key_path(sbid)), ignore_errors=True)
        try:  # its terminal's proxy port, if one was left
            os.remove(os.path.join(self.home, "runtime", f"sandbox-{sbid}.port"))
        except OSError:
            pass
        self._set(sbid, destroyed=1)
        return self.get(sbid)

    # ---------------------------------------------------------------- Loop 16: image, estimates, measured costs
    def image_info(self) -> dict:
        built = float(self.config("image_built", "0") or 0)
        return {"name": "Agent Manager sandbox image", "recipe": "sandbox/Dockerfile", "contents": [list(c) for c in IMAGE_CONTENTS],
                "ready": bool(self.config("image")), "built": built, "image": self.config("image"),
                "build_note": "Fly builds it in your organisation's private registry, about 2 minutes, once"}

    def estimate(self, size: str = "shared-cpu-1x-1024") -> dict:
        """Before deploying: what a sandbox costs while it runs, and while it is paused (published prices)."""
        month = PRICES.get(size, 6.70)
        hour = month / HOURS_PER_MONTH
        return {"size": size, "per_hour": round(hour, 4), "per_day_on": round(hour * 24, 3), "per_month_on": month,
                "paused_per_month": round(STOPPED_GB_MONTH * IMAGE_GB, 2), "source": PRICE_SOURCE}

    @staticmethod
    def intervals(m: dict) -> list[tuple[float, float | None]]:
        """The periods a machine ran, from its event history (stop None: still running)."""
        evs = sorted(m.get("events") or [], key=lambda e: e.get("timestamp", 0))
        out, since = [], None
        for e in evs:
            t = float(e.get("timestamp", 0)) / 1000.0
            kind = str(e.get("type", ""))
            if kind in ("start", "launch") and since is None:
                since = t
            elif kind in ("stop", "exit", "destroy") and since is not None:
                out.append((since, t))
                since = None
        if since is not None and m.get("state") == "started":
            out.append((since, None))
        return out

    def sync_runs(self, live: dict) -> None:
        """Copies each known machine's run periods into sandbox_runs (they survive the machine)."""
        with closing(self._db()) as db, db:
            for sb in self.all():
                m = live.get(sb["machine"])
                if not m:
                    continue
                for start, stop in self.intervals(m):
                    db.execute("INSERT INTO sandbox_runs (sandbox, size, start, stop) VALUES (?, ?, ?, ?) "
                               "ON CONFLICT(sandbox, start) DO UPDATE SET stop = excluded.stop", (sb["id"], sb["size"], start, stop))
                # a period recorded as running whose machine is now stopped: close it at the last event
                if m.get("state") != "started":
                    last = max([float(e.get("timestamp", 0)) / 1000.0 for e in (m.get("events") or [])] or [time.time()])
                    db.execute("UPDATE sandbox_runs SET stop = ? WHERE sandbox = ? AND stop IS NULL", (last, sb["id"]))

    def runs(self) -> list[dict]:
        with closing(self._db()) as db:
            return [dict(r) for r in db.execute("SELECT * FROM sandbox_runs ORDER BY start")]

    def cost_series(self, days: int = 30, now: float | None = None) -> dict:
        """Measured cost per day (all sandboxes), this month's running total, and per sandbox today / this month.
        Measured = the running time in Fly's own machine history × the published price (not Fly's invoice)."""
        now = now or time.time()
        lt = time.localtime(now)
        today0 = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
        month0 = time.mktime((lt.tm_year, lt.tm_mon, 1, 0, 0, 0, 0, 0, -1))
        starts = [today0 - 86400 * i for i in range(days - 1, -1, -1)]
        day_cost = [0.0] * days
        per = {}
        for r in self.runs():
            a, b = r["start"], r["stop"] or now
            rate = PRICES.get(r["size"], 6.70) / (HOURS_PER_MONTH * 3600)
            for i, d0 in enumerate(starts):
                d1 = d0 + 86400
                ov = min(b, d1) - max(a, d0)
                if ov > 0:
                    day_cost[i] += ov * rate
            p = per.setdefault(r["sandbox"], {"today": 0.0, "month": 0.0, "total": 0.0, "running_since": None})
            p["today"] += max(0.0, min(b, now) - max(a, today0)) * rate
            p["month"] += max(0.0, min(b, now) - max(a, month0)) * rate
            p["total"] += max(0.0, b - a) * rate
            if r["stop"] is None:
                p["running_since"] = a
        cum, run = [], 0.0
        for d0, c in zip(starts, day_cost):
            run = run + c if d0 >= month0 else 0.0
            cum.append(round(run, 4))
        return {"days": [time.strftime("%Y-%m-%d", time.localtime(d)) for d in starts],
                "day_cost": [round(c, 4) for c in day_cost], "month_cumulative": cum,
                "today": round(sum(v["today"] for v in per.values()), 4), "month": round(sum(v["month"] for v in per.values()), 4),
                "per_sandbox": {k: {kk: (round(vv, 4) if isinstance(vv, float) and kk != "running_since" else vv) for kk, vv in v.items()} for k, v in per.items()},
                "measured_note": "measured: running time from Fly's machine history × published price; Fly's invoice is on its dashboard"}

    # ---------------------------------------------------------------- orphans: the owner may destroy them, confirmed
    def org(self) -> str:
        """The organisation: the one prepared, or (not prepared yet) the token's first one, to list leftovers."""
        if self.config("org") or not self.fly.available():
            return self.config("org")
        try:
            orgs = self.fly.json("orgs", "list")
        except (RuntimeError, ValueError, OSError):
            return ""
        return sorted(orgs.keys())[0] if isinstance(orgs, dict) and orgs else ""

    def _orphan_app(self, app: str) -> None:
        if not app.startswith("agmgd-"):
            raise ValueError("only Agent Manager's own Fly apps (agmgd-…) are handled here")
        apps = self.fly.json("apps", "list", "--org", self.org()) if self.org() else []
        if not any((a.get("Name") or a.get("name")) == app for a in (apps if isinstance(apps, list) else [])):
            raise ValueError(f"no app {app} in your organisation")

    def orphan_contents(self, app: str) -> list[dict]:
        """What an orphan app holds (its machines), shown before destroying it."""
        self._orphan_app(app)
        return [{"id": m["id"], "name": m.get("name", ""), "state": m.get("state", "")}
                for m in self.fly.json("machine", "list", "--app", app)]

    def destroy_orphan(self, app: str, machine: str, confirmed: bool) -> dict:
        """Only on the owner's confirmed request: a machine this Agent Manager does not know, or a whole other
        Agent Manager app (never the app in use, never a machine of a known sandbox)."""
        if not confirmed:
            raise ValueError("destroying needs the owner's confirmation")
        self._orphan_app(app)
        if machine and any(sb["machine"] == machine for sb in self.all()):
            raise ValueError("this machine is a known sandbox: destroy it from its card (shows its unpushed work)")
        if machine:
            if not any(m["id"] == machine for m in self.fly.json("machine", "list", "--app", app)):
                raise ValueError(f"no machine {machine} in {app}")
            rc, out = self.fly.run("machine", "destroy", machine, "--app", app, "--force", timeout=300)
        else:
            if app == self.config("app") or any(sb["app"] == app and not sb["destroyed"] for sb in self.all()):
                raise ValueError("this app holds sandboxes Agent Manager knows: destroy those from their cards")
            rc, out = self.fly.run("apps", "destroy", app, "--yes", timeout=300)
        if rc != 0:
            raise ValueError(out[-200:])
        return {"destroyed": machine or app}

    # ---------------------------------------------------------------- budget and caps (Loop 14): never destructive
    def budget(self) -> dict:
        return {"monthly_usd": float(self.config("budget_usd", "0") or 0),
                "stop_idle_minutes": int(self.config("stop_idle_minutes", "0") or 0),
                "stop_over_budget": self.config("stop_over_budget", "0") == "1"}

    def set_budget(self, monthly_usd: float, stop_idle_minutes: int, stop_over_budget: bool) -> dict:
        if monthly_usd < 0 or monthly_usd > 100000 or stop_idle_minutes < 0 or stop_idle_minutes > 100000:
            raise ValueError("a budget and minutes of 0 or more (0 = off)")
        self.set_config("budget_usd", str(monthly_usd))
        self.set_config("stop_idle_minutes", str(int(stop_idle_minutes)))
        self.set_config("stop_over_budget", "1" if stop_over_budget else "0")
        return self.budget()

    def month_spend(self, live: dict | None = None) -> float:
        """Estimated spend of this month's sandboxes (running time × published price)."""
        if live is None:
            try:
                live = {m["id"]: m for m in self.machines()}
            except (RuntimeError, ValueError, OSError):
                live = {}
        start = time.mktime(time.strptime(time.strftime("%Y-%m-01"), "%Y-%m-%d"))
        total = 0.0
        for sb in self.all():
            m = live.get(sb["machine"])
            if m and sb["created"] >= start:
                total += self.cost(sb["size"], self.running_seconds(m))
        return round(total, 4)

    def guard_new(self) -> None:
        b = self.budget()
        if b["monthly_usd"] > 0 and self.month_spend() >= b["monthly_usd"]:
            raise ValueError(f"the monthly sandbox budget (${b['monthly_usd']:.2f}) is reached: no new sandbox this month "
                             "(raise it in Sandboxes → Budget)")

    def stop_all(self) -> list[str]:
        """Pauses every started sandbox (nothing is destroyed)."""
        stopped = []
        for m in self.machines():
            if m.get("state") == "started" and any(sb["machine"] == m["id"] and not sb["destroyed"] for sb in self.all()):
                self.fly.run("machine", "stop", m["id"], "--app", self.config("app"), timeout=300)
                stopped.append(m["id"])
        return stopped

    def enforce(self, idle_seconds: dict) -> list[str]:
        """The owner's optional caps: pause a sandbox idle too long, or all of them over budget. Never destroys.
        idle_seconds: sandbox id -> seconds since its terminal last showed activity."""
        b = self.budget()
        paused = []
        if b["stop_over_budget"] and b["monthly_usd"] > 0 and self.month_spend() >= b["monthly_usd"]:
            return self.stop_all()
        if b["stop_idle_minutes"] > 0:
            started = {m["id"] for m in self.machines() if m.get("state") == "started"}
            for sb in self.all():
                if sb["machine"] in started and idle_seconds.get(sb["id"], 0) >= b["stop_idle_minutes"] * 60:
                    self.fly.run("machine", "stop", sb["machine"], "--app", sb["app"], timeout=300)
                    paused.append(sb["machine"])
        return paused

    # ---------------------------------------------------------------- the manager's view
    @staticmethod
    def running_seconds(m: dict, now: float | None = None) -> float:
        """Seconds the machine ran, from its event history (start/stop/exit events)."""
        now = now or time.time()
        evs = sorted(m.get("events") or [], key=lambda e: e.get("timestamp", 0))
        total, since = 0.0, None
        for e in evs:
            t = float(e.get("timestamp", 0)) / 1000.0
            kind = str(e.get("type", ""))
            if kind in ("start", "launch") and since is None:
                since = t
            elif kind in ("stop", "exit", "destroy") and since is not None:
                total += max(0.0, t - since)
                since = None
        if since is not None and m.get("state") == "started":
            total += max(0.0, now - since)
        return total

    def cost(self, size: str, seconds: float) -> float:
        return round(PRICES.get(size, 6.70) / (30 * 24 * 3600) * seconds, 4)

    # ---------------------------------------------------------------- the inventory: nothing made here is forgotten
    def inventory(self, rows: list[dict], reachable: bool, orphans: list[dict], now: float | None = None) -> dict:
        """Every sandbox ever made from here, the destroyed ones too (owner, 2026-11-12: « il faut toujours avoir
        l'inventaire »): its state, each period its machine ran (copied from Fly.io's own history, kept after the
        machine is gone), how long in all and what that cost at the published price. And what Fly.io holds now:
        whether it could be asked, how many machines live there, and those Agent Manager does not know.
        `rows` are the sandboxes as `overview` describes them (with their live state)."""
        now = time.time() if now is None else now
        by: dict[str, list[dict]] = {}
        for r in self.runs():
            by.setdefault(r["sandbox"], []).append(r)
        out = []
        for row in rows:
            runs = by.get(row["id"], [])
            seconds = 0.0
            cost = 0.0
            spans = []
            for r in runs:
                stop = float(r["stop"]) if r["stop"] is not None else now
                took = max(0.0, stop - float(r["start"]))
                seconds += took
                cost += self.cost(r["size"], took)
                spans.append([float(r["start"]), None if r["stop"] is None else float(r["stop"])])
            out.append({"id": row["id"], "session_id": row.get("session_id", ""), "app": row["app"], "machine": row["machine"],
                        "region": row["region"], "size": row["size"], "created": float(row["created"]), "state": row["state"],
                        "destroyed": bool(row["destroyed"]), "finished": bool(row.get("finished", 0)),
                        "runs": spans, "run_seconds": round(seconds), "cost_usd": round(cost, 4),
                        "first_start": spans[0][0] if spans else 0.0,
                        "last_stop": max((s[1] if s[1] is not None else now) for s in spans) if spans else 0.0,
                        "running_now": any(s[1] is None for s in spans) and row["state"] == "started"})
        live = [r for r in out if not r["destroyed"] and r["state"] not in ("gone", "unknown")]
        return {"sandboxes": out, "now": now,
                "at_fly": {"reachable": reachable, "app": self.config("app"), "machines": len(live) + len([o for o in orphans if o.get("machine")]),
                           "unknown_here": len(orphans)}}

    def overview(self) -> dict:
        """Every sandbox Agent Manager knows (with its machine's live state and cost), and the orphans."""
        try:
            live = {m["id"]: m for m in self.machines()}
            reachable = True
        except (RuntimeError, ValueError, OSError):
            live, reachable = {}, False
        known = set()
        rows = []
        for sb in self.all():
            m = live.get(sb["machine"], {})
            known.add(sb["machine"])
            secs = self.running_seconds(m) if m else 0.0
            rows.append({**{k: v for k, v in sb.items() if k != "secret"},
                         "state": "destroyed" if sb["destroyed"] else (m.get("state") or ("unknown" if not reachable else "gone")),
                         "running_seconds": round(secs), "cost_usd": self.cost(sb["size"], secs)})
        orphans = [{"app": self.config("app"), "machine": mid, "name": m.get("name", ""), "state": m.get("state", "")}
                   for mid, m in live.items() if mid not in known]
        try:  # other Agent Manager apps of the organisation (another computer, an earlier test)
            org = self.org()
            apps = self.fly.json("apps", "list", "--org", org) if org else []
            for a in apps if isinstance(apps, list) else []:
                name = a.get("Name") or a.get("name", "")
                if name.startswith("agmgd-") and name != self.config("app"):
                    orphans.append({"app": name, "machine": "", "name": "(another Agent Manager app)", "state": a.get("Status", "")})
        except (RuntimeError, ValueError, OSError):
            pass
        if reachable:
            self.sync_runs(live)
        series = self.cost_series()
        for row in rows:
            ps = series["per_sandbox"].get(row["id"], {})
            row["cost_today"] = ps.get("today", 0.0)
            row["cost_month"] = ps.get("month", 0.0)
            row["running_since"] = ps.get("running_since") if row["state"] == "started" else None
            row["health"] = self.health.get(row["id"])
            if row["health"] is None and isinstance(self.fly, DemoFly):
                demo_h = self.fly.data.get("health", {}).get(row["id"])
                row["health"] = {**demo_h, "checked": time.time() - 20} if demo_h else None
        b = self.budget()
        spend = self.month_spend(live)
        return {"sandboxes": rows, "orphans": orphans, "inventory": self.inventory(rows, reachable, orphans),
                "fly_reachable": reachable, **self.status(), "org": self.org(),
                "total_cost_usd": round(sum(r["cost_usd"] for r in rows), 4), "budget": b, "month_spend_usd": spend,
                "budget_percent": round(100 * spend / b["monthly_usd"], 1) if b["monthly_usd"] > 0 else None,
                "storage_note": f"stopped machines: ${STOPPED_GB_MONTH}/GB/month of root disk",
                "image_info": self.image_info(), "estimate": self.estimate(), "costs": series}
