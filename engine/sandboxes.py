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
import re
import secrets
import shutil
import sqlite3
import subprocess
import time
from contextlib import closing

FLYCTL = os.environ.get("AGMGD_FLYCTL") or os.path.expanduser("~/.local/opt/flyctl/flyctl")
HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE_DIR = os.path.join(os.path.dirname(HERE), "sandbox")
# The sizes a sandbox can have, with Fly.io's published price per month (30 days) while it runs, in its cheapest
# regions (Ashburn iad, Secaucus ewr): docs.fly.io/about/pricing, read 2026-11-12 (the page has no date). Fly.io
# says prices vary by region; its page does not list the others, so elsewhere the figure is a floor, and said so.
# Billed by the second while running; a paused machine bills only its root disk (STOPPED_GB_MONTH).
SIZES = [
    {"id": "shared-cpu-1x-256", "kind": "shared", "cpus": 1, "memory_mb": 256, "month": 2.19},
    {"id": "shared-cpu-1x-512", "kind": "shared", "cpus": 1, "memory_mb": 512, "month": 3.69},
    {"id": "shared-cpu-1x-1024", "kind": "shared", "cpus": 1, "memory_mb": 1024, "month": 6.70},
    {"id": "shared-cpu-2x-2048", "kind": "shared", "cpus": 2, "memory_mb": 2048, "month": 13.39},
    {"id": "performance-cpu-1x-2048", "kind": "performance", "cpus": 1, "memory_mb": 2048, "month": 33.00},
    {"id": "performance-cpu-2x-4096", "kind": "performance", "cpus": 2, "memory_mb": 4096, "month": 66.00},
]
PRICES = {s["id"]: s["month"] for s in SIZES}
DEFAULT_SIZE = "shared-cpu-1x-1024"
CHEAPEST_REGIONS = ("iad", "ewr")
STOPPED_GB_MONTH = 0.15
PRICE_SOURCE = "docs.fly.io/about/pricing, read 2026-11-12"


def size_parts(size: str) -> tuple[str, int, int]:
    """(cpu kind, cpus, memory in MB) of a size's name; the default one's for a name that is not one."""
    m = re.match(r"^(shared|performance)-cpu-(\d+)x-(\d+)$", size or "")
    return (m.group(1), int(m.group(2)), int(m.group(3))) if m else ("shared", 1, 1024)
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
-- Loop 40: more sessions on the same machine (owner, 2026-11-14: « ouvrir plusieurs sessions SSH sur la même VM »).
-- The first session stays in sandboxes.session_id; each added one has its row, its own tmux session in the machine
-- (am-<session id>) and its folder (its own git worktree when the sandbox has a repository).
CREATE TABLE IF NOT EXISTS sandbox_sessions (session_id TEXT PRIMARY KEY, sandbox TEXT NOT NULL, tmux TEXT NOT NULL,
    worktree INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
"""
# Loop 41 (owner, 2026-11-14: « quand on va lancer des VM comme ça, ce serait pour lancer des services en ligne… un
# service sur le port 443. Le reste ce serait en backend, sur la même VM »; the name « Online » is the owner's). An
# Online machine is a sandbox record of kind « online »: the same terminal, sessions, tunnel and inventory, but its own
# Fly app (so its own address, <app>.fly.dev), a volume for what must last (/data), and one public door when exposed:
# 443 (HTTPS, Fly's certificate) and 80 (sent on to HTTPS) toward one port inside. Everything else listens on
# 127.0.0.1 in the machine and is never public; SSH stays on Fly's private network. Exposed only when the owner asks.
ONLINE_COLUMNS = [("kind", "TEXT NOT NULL DEFAULT 'sandbox'"), ("name", "TEXT NOT NULL DEFAULT ''"),
                  ("port", "INTEGER NOT NULL DEFAULT 0"), ("volume_gb", "INTEGER NOT NULL DEFAULT 0"),
                  ("exposed", "INTEGER NOT NULL DEFAULT 0")]
ONLINE_PREFIX = "agmgd-on-"
VOLUME_GB_MONTH = 0.15   # Fly.io's published price of a volume, per GB and month (docs.fly.io/about/pricing)
MAX_SESSIONS_PER_SANDBOX = 8   # the first one and seven added: each runs an agent on the same machine
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
            have = {row[1] for row in db.execute("PRAGMA table_info(sandboxes)")}
            for col, decl in ONLINE_COLUMNS:   # Loop 41
                if col not in have:
                    db.execute(f"ALTER TABLE sandboxes ADD COLUMN {col} {decl}")

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
        """The live sandbox a session works in, its first session or one added to it (Loop 40), with « first »."""
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM sandboxes WHERE session_id = ? AND destroyed = 0", (sid,)).fetchone()
            if r:
                return {**dict(r), "first": True}
            r = db.execute("SELECT s.* FROM sandboxes s JOIN sandbox_sessions x ON x.sandbox = s.id "
                           "WHERE x.session_id = ? AND s.destroyed = 0", (sid,)).fetchone()
        return {**dict(r), "first": False} if r else None

    # ---------------------------------------------------------------- Loop 40: several sessions on one machine
    def sessions_on(self, sbid: str) -> list[str]:
        """Every session of a sandbox: its first one, then those added, oldest first."""
        sb = self.get(sbid)
        with closing(self._db()) as db:
            added = [r[0] for r in db.execute("SELECT session_id FROM sandbox_sessions WHERE sandbox = ? ORDER BY created, rowid", (sbid,))]
        return ([sb["session_id"]] if sb["session_id"] else []) + added

    def seat(self, sbid: str, sid: str) -> dict:
        """Where a session lives in the machine: its tmux session's name, whether it has its own worktree."""
        sb = self.get(sbid)
        if sid in ("", sb["session_id"]):
            return {"tmux": "am", "first": True, "worktree": False}
        with closing(self._db()) as db:
            r = db.execute("SELECT * FROM sandbox_sessions WHERE sandbox = ? AND session_id = ?", (sbid, sid)).fetchone()
        if not r:
            raise KeyError(f"session {sid} is not on sandbox {sbid}")
        return {"tmux": r["tmux"], "first": False, "worktree": bool(r["worktree"])}

    def add_session(self, sbid: str, sid: str, worktree: bool = False) -> dict:
        """One more session on a live sandbox: no new machine, its own tmux session in it."""
        sb = self.get(sbid)
        if sb["destroyed"]:
            raise ValueError("this sandbox was destroyed")
        if len(self.sessions_on(sbid)) >= MAX_SESSIONS_PER_SANDBOX:
            raise ValueError(f"at most {MAX_SESSIONS_PER_SANDBOX} sessions on one sandbox")
        with closing(self._db()) as db, db:
            db.execute("INSERT INTO sandbox_sessions (session_id, sandbox, tmux, worktree, created) VALUES (?, ?, ?, ?, ?)",
                       (sid, sbid, "am-" + sid, int(bool(worktree and sb["repo_id"])), time.time()))
        return self.seat(sbid, sid)

    def drop_session(self, sid: str) -> None:
        with closing(self._db()) as db, db:
            db.execute("DELETE FROM sandbox_sessions WHERE session_id = ?", (sid,))

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
    def create(self, session_id: str, size: str = "", repo_id: str = "") -> dict:
        size = size or self.config("size", DEFAULT_SIZE)
        if size not in PRICES:
            raise ValueError(f"not a size Agent Manager knows: {size}")
        st = self.status()
        if not st["ready"]:
            raise ValueError("cloud sandboxes are not prepared yet (Sandboxes → Prepare)")
        self.guard_new()
        sbid = secrets.token_hex(4)
        machine = self._launch(sbid, st["app"], size, [])
        with closing(self._db()) as db, db:
            db.execute("INSERT INTO sandboxes (id, session_id, app, machine, region, size, secret, repo_id, created) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (sbid, session_id, st["app"], machine, st["region"], size,
                                                               secrets.token_urlsafe(24), repo_id, time.time()))
        self.forget_machines()
        return self.get(sbid)

    def _launch(self, sbid: str, app: str, size: str, more: list[str]) -> str:
        """One machine from our image, with the sandbox's own SSH key: its machine id (found again by name when Fly's
        list is late). Its key folder is removed when the machine did not start."""
        st = self.status()
        os.makedirs(os.path.dirname(self.key_path(sbid)), mode=0o700, exist_ok=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"agent-manager-gd:sandbox-{sbid}",
                        "-f", self.key_path(sbid)], check=True, capture_output=True, timeout=30)
        with open(self.key_path(sbid) + ".pub", encoding="utf-8") as f:
            pub = f.read().strip()
        kind, cpus, mem = size_parts(size)
        rc, out = self.fly.run("machine", "run", st["image"], "--app", app, "--region", st["region"],
                               "--vm-cpu-kind", kind, "--vm-cpus", str(cpus), "--vm-memory", str(mem), "--name", "sandbox-" + sbid,
                               "--env", "AGMGD_AUTHORIZED_KEY=" + pub, "--metadata", "agmgd=" + sbid, *more, timeout=900)
        if rc != 0:
            shutil.rmtree(os.path.dirname(self.key_path(sbid)), ignore_errors=True)
            raise ValueError("the machine did not start: " + out[-300:])
        machine = ""
        for _ in range(1 if isinstance(self.fly, DemoFly) else 10):  # a new machine can take a few seconds to show in Fly's list
            machine = next((m["id"] for m in self.machines(fresh=True, app=app) if m.get("name") == "sandbox-" + sbid), "")
            if machine:  # without its id the sandbox could never be reached (the terminal looks it up again, by name)
                break
            time.sleep(1)
        return machine

    # ---------------------------------------------------------------- Loop 41: Online machines
    def create_online(self, session_id: str, name: str, port: int, size: str = "", volume_gb: int = 1, repo_id: str = "") -> dict:
        """A machine for a service online, private until exposed: its own app, a volume mounted on /data, and the
        services 443 (HTTPS) and 80 declared toward `port` inside. Without a public address nothing reaches them."""
        if not re.match(r"^[a-z0-9][a-z0-9-]{0,28}[a-z0-9]$|^[a-z0-9]$", name or ""):
            raise ValueError("a name of 1 to 30 lowercase letters, digits or dashes (it goes in the address)")
        if not 1 <= int(port) <= 65535 or int(port) in (2222, 22):
            raise ValueError("the port your service listens on inside the machine (not 22 nor 2222: SSH)")
        if not 1 <= int(volume_gb) <= 500:
            raise ValueError("a volume of 1 to 500 GB")
        size = size or self.config("size", DEFAULT_SIZE)
        if size not in PRICES:
            raise ValueError(f"not a size Agent Manager knows: {size}")
        st = self.status()
        if not st["ready"]:
            raise ValueError("cloud machines are not prepared yet (Sandboxes → Prepare: it builds the image)")
        if any(sb.get("kind") == "online" and sb.get("name") == name and not sb["destroyed"] for sb in self.all()):
            raise ValueError(f"an Online machine is already called {name}")
        self.guard_new()
        sbid = secrets.token_hex(4)
        app = f"{ONLINE_PREFIX}{name}-{sbid}"[:63]
        rc, out = self.fly.run("apps", "create", app, "--org", st["org"])
        if rc != 0:
            raise ValueError("could not create its Fly app: " + out[-200:])
        try:
            rc, out = self.fly.run("volumes", "create", "data", "--app", app, "--region", st["region"], "--size", str(int(volume_gb)),
                                   "--yes", timeout=300)
            if rc != 0:
                raise ValueError("could not create its volume: " + out[-200:])
            p = str(int(port))
            machine = self._launch(sbid, app, size, ["--volume", "data:/data", "--port", f"443:{p}/tcp:tls:http",
                                                     "--port", f"80:{p}/tcp:http"])
        except Exception:
            self.fly.run("apps", "destroy", app, "--yes", timeout=300)   # nothing half made is left billed
            raise
        with closing(self._db()) as db, db:
            db.execute("INSERT INTO sandboxes (id, session_id, app, machine, region, size, secret, repo_id, workdir, created, "
                       "kind, name, port, volume_gb) VALUES (?, ?, ?, ?, ?, ?, ?, ?, '/data/work', ?, 'online', ?, ?, ?)",
                       (sbid, session_id, app, machine, st["region"], size, secrets.token_urlsafe(24), repo_id, time.time(),
                        name, int(port), int(volume_gb)))
        self.forget_machines()
        return self.get(sbid)

    def public_ips(self, sbid: str) -> list[dict]:
        sb = self._online(sbid)
        got = self.fly.json("ips", "list", "--app", sb["app"])
        return [{"address": i.get("Address") or i.get("address", ""), "type": i.get("Type") or i.get("type", ""),
                 "id": i.get("ID") or i.get("id", "")} for i in (got if isinstance(got, list) else [])]

    def _online(self, sbid: str) -> dict:
        sb = self.get(sbid)
        if sb.get("kind") != "online":
            raise ValueError("this is a sandbox, never public: only an Online machine can be exposed")
        if sb["destroyed"]:
            raise ValueError("this machine was destroyed")
        return sb

    def expose(self, sbid: str, confirmed: bool) -> dict:
        """On the owner's confirmed request only: public addresses for its app (IPv6, and a shared IPv4, both free),
        so https://<app>.fly.dev reaches port 443 → the service. SSH and every other port stay private."""
        if not confirmed:
            raise ValueError("exposing to the internet needs the owner's confirmation")
        sb = self._online(sbid)
        have = {i["type"].lower() for i in self.public_ips(sbid)}
        if not any("v6" in t for t in have):
            rc, out = self.fly.run("ips", "allocate-v6", "--app", sb["app"], timeout=120)
            if rc != 0:
                raise ValueError("Fly.io gave no IPv6 address: " + out[-200:])
        if not any("v4" in t for t in have):
            rc, out = self.fly.run("ips", "allocate-v4", "--shared", "--app", sb["app"], timeout=120)
            if rc != 0:
                raise ValueError("Fly.io gave no shared IPv4 address: " + out[-200:])
        self._set(sbid, exposed=1)
        return self.online_info(sbid)

    def unexpose(self, sbid: str) -> dict:
        """Its public addresses given back: nothing of it is reachable from the internet any more (always allowed)."""
        sb = self._online(sbid)
        for ip in self.public_ips(sbid):
            if ip["address"]:
                self.fly.run("ips", "release", ip["address"], "--app", sb["app"], timeout=120)
        self._set(sbid, exposed=0)
        return self.online_info(sbid)

    def online_info(self, sbid: str) -> dict:
        sb = self.get(sbid)
        return {"id": sbid, "name": sb.get("name", ""), "app": sb["app"], "port": sb.get("port", 0), "exposed": bool(sb.get("exposed")),
                "url": f"https://{sb['app']}.fly.dev" if sb.get("exposed") else "", "volume_gb": sb.get("volume_gb", 0),
                "volume_month": round(VOLUME_GB_MONTH * int(sb.get("volume_gb") or 0), 2)}

    MACHINES_FRESH = 10.0   # seconds a list of machines from Fly.io is used as it is

    def machines(self, fresh: bool = False, app: str = "") -> list[dict]:
        """The app's machines at Fly.io. Asking Fly.io takes one to a few seconds: the list is kept ten seconds, and
        when it is older the last one is given at once while a new one is asked aside (the page no longer waits on
        Fly.io at every click). The first time, and when `fresh` is asked, it waits for Fly.io. `app`: an Online
        machine's own app (Loop 41); the sandboxes' app by default."""
        if app and app != self.config("app"):
            return self._other_machines(app, fresh)
        app = self.config("app")
        if not app:
            return []
        import threading
        cache = getattr(self, "_machines", None)
        now = time.monotonic()
        if fresh or cache is None or cache[0] != app:
            got = list(self.fly.json("machine", "list", "--app", app))
            self._machines = (app, now, got)
            return got
        if now - cache[1] > self.MACHINES_FRESH and not getattr(self, "_machines_asking", False):
            self._machines_asking = True

            def ask() -> None:
                try:
                    self._machines = (app, time.monotonic(), list(self.fly.json("machine", "list", "--app", app)))
                except (RuntimeError, ValueError, OSError):
                    pass
                finally:
                    self._machines_asking = False
            threading.Thread(target=ask, daemon=True).start()
        return cache[2]

    def forget_machines(self) -> None:
        """Something changed at Fly.io from here (a machine made, started, stopped, destroyed): ask again next time."""
        self._machines = None
        self._others = {}

    def _other_machines(self, app: str, fresh: bool = False) -> list[dict]:
        """An Online machine's app, kept ten seconds like the sandboxes' list (one app, one machine: a short ask)."""
        others = getattr(self, "_others", None)
        if others is None:
            others = self._others = {}
        got = others.get(app)
        if fresh or got is None or time.monotonic() - got[0] > self.MACHINES_FRESH:
            got = others[app] = (time.monotonic(), list(self.fly.json("machine", "list", "--app", app)))
        return got[1]

    def live_machines(self) -> dict:
        """Every machine Agent Manager may know, by id: the sandboxes' app, and each live Online machine's own app."""
        live = {m["id"]: m for m in self.machines()}
        for sb in self.all():
            if sb.get("kind") == "online" and not sb["destroyed"]:
                try:
                    live.update({m["id"]: m for m in self._other_machines(sb["app"])})
                except (RuntimeError, ValueError, OSError):
                    pass
        return live

    def start(self, sbid: str) -> dict:
        sb = self.get(sbid)
        rc, out = self.fly.run("machine", "start", sb["machine"], "--app", sb["app"], timeout=300)
        if rc != 0:
            raise ValueError(out[-200:])
        self.forget_machines()
        return self.get(sbid)

    def stop(self, sbid: str) -> dict:
        sb = self.get(sbid)
        rc, out = self.fly.run("machine", "stop", sb["machine"], "--app", sb["app"], timeout=300)
        if rc != 0:
            raise ValueError(out[-200:])
        self.forget_machines()
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
        if sb["machine"]:
            rc, out = self.fly.run("machine", "destroy", sb["machine"], "--app", sb["app"], "--force", timeout=300)
            if rc != 0 and "not found" not in out.lower():
                raise ValueError(out[-200:])
        if sb.get("kind") == "online" and sb["app"].startswith(ONLINE_PREFIX):
            # its own app: the volume and the public addresses go with it (nothing of it is left billed)
            rc, out = self.fly.run("apps", "destroy", sb["app"], "--yes", timeout=300)
            if rc != 0 and "not found" not in out.lower():
                raise ValueError("the machine is destroyed but not its app (its volume may still be billed): " + out[-200:])
        if brain and sb["brain_client"]:
            brain.revoke(sb["brain_client"])
        shutil.rmtree(os.path.dirname(self.key_path(sbid)), ignore_errors=True)
        import glob
        run = os.path.join(self.home, "runtime")
        for left in [os.path.join(run, f"sandbox-{sbid}.port")] + glob.glob(os.path.join(run, f"sandbox-{sbid}~*.port")):  # its terminals' proxy ports
            try:
                os.remove(left)
            except OSError:
                pass
        self._set(sbid, destroyed=1)
        self.forget_machines()
        return self.get(sbid)

    # ---------------------------------------------------------------- Loop 16: image, estimates, measured costs
    def image_info(self) -> dict:
        built = float(self.config("image_built", "0") or 0)
        return {"name": "Agent Manager sandbox image", "recipe": "sandbox/Dockerfile", "contents": [list(c) for c in IMAGE_CONTENTS],
                "ready": bool(self.config("image")), "built": built, "image": self.config("image"),
                "build_note": "Fly builds it in your organisation's private registry, about 2 minutes, once"}

    def sizes(self) -> dict:
        """The sizes to choose from, each with what it costs, the one chosen, and the region with its price caveat."""
        region = self.config("region", "yyz")
        rows = []
        for s in SIZES:
            hour = s["month"] / HOURS_PER_MONTH
            rows.append({**s, "per_hour": round(hour, 4), "per_day_on": round(hour * 24, 3)})
        return {"sizes": rows, "chosen": self.config("size", DEFAULT_SIZE), "region": region,
                "cheapest_region": region in CHEAPEST_REGIONS, "paused_per_month": round(STOPPED_GB_MONTH * IMAGE_GB, 2),
                "source": PRICE_SOURCE,
                "region_note": "" if region in CHEAPEST_REGIONS else
                f"Fly.io's prices vary by region and its page gives only those of iad and ewr, its cheapest: in {region} these are floors."}

    def choose_size(self, size: str) -> dict:
        if size not in PRICES:
            raise ValueError(f"not a size Agent Manager knows: {size}")
        self.set_config("size", size)
        return self.sizes()

    def estimate(self, size: str = "") -> dict:
        """Before deploying: what a sandbox costs while it runs, and while it is paused (published prices)."""
        size = size or self.config("size", DEFAULT_SIZE)
        month = PRICES.get(size, PRICES[DEFAULT_SIZE])
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
            rate = PRICES.get(r["size"], PRICES[DEFAULT_SIZE]) / (HOURS_PER_MONTH * 3600)
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
                live = self.live_machines()
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
        """Pauses every started sandbox (nothing is destroyed). Never an Online machine: it serves the public, and
        only its owner pauses it, from its card."""
        stopped = []
        for m in self.machines():
            if m.get("state") == "started" and any(sb["machine"] == m["id"] and not sb["destroyed"] and sb.get("kind", "sandbox") == "sandbox" for sb in self.all()):
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
                if sb.get("kind", "sandbox") != "sandbox":   # an Online service is not idle when nobody types in it
                    continue
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
        return round(PRICES.get(size, PRICES[DEFAULT_SIZE]) / (30 * 24 * 3600) * seconds, 4)

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
            out.append({"id": row["id"], "kind": row.get("kind", "sandbox"), "name": row.get("name", ""),
                        "session_id": row.get("session_id", ""), "app": row["app"], "machine": row["machine"],
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
            live = self.live_machines()
            reachable = True
        except (RuntimeError, ValueError, OSError):
            live, reachable = {}, False
        known = set()
        rows = []
        for sb in self.all():
            m = live.get(sb["machine"], {})
            known.add(sb["machine"])
            secs = self.running_seconds(m) if m else 0.0
            rows.append({**{k: v for k, v in sb.items() if k != "secret"}, "sessions": self.sessions_on(sb["id"]),
                         "online": self.online_info(sb["id"]) if sb.get("kind") == "online" else None,
                         "state": "destroyed" if sb["destroyed"] else (m.get("state") or ("unknown" if not reachable else "gone")),
                         "running_seconds": round(secs), "cost_usd": self.cost(sb["size"], secs)})
        orphans = [{"app": self.config("app"), "machine": mid, "name": m.get("name", ""), "state": m.get("state", "")}
                   for mid, m in live.items() if mid not in known]
        online_apps = {sb["app"] for sb in self.all() if sb.get("kind") == "online" and not sb["destroyed"]}
        try:  # other Agent Manager apps of the organisation (another computer, an earlier test)
            org = self.org()
            apps = self.fly.json("apps", "list", "--org", org) if org else []
            for a in apps if isinstance(apps, list) else []:
                name = a.get("Name") or a.get("name", "")
                if name.startswith("agmgd-") and name != self.config("app") and name not in online_apps:
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
                "image_info": self.image_info(), "estimate": self.estimate(), "sizes": self.sizes(), "costs": series}
