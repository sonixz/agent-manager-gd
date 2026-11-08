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
"""


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


class Sandboxes:
    def __init__(self, db_path: str, home: str, keys, fly: Fly | None = None):
        self.db_path = db_path
        self.home = home
        self.keys = keys
        self.fly = fly or Fly(lambda: keys.get("fly"))
        self.key_dir = os.path.join(home, "keys", "sandbox")
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
        return {"flyctl": os.path.exists(FLYCTL), "token": bool(self.keys.describe("fly")["set"]),
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
        machine = next((m["id"] for m in self.machines() if m.get("name") == "sandbox-" + sbid), "")
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
        self._set(sbid, destroyed=1)
        return self.get(sbid)

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
            org = self.config("org")
            apps = self.fly.json("apps", "list", "--org", org) if org else []
            for a in apps if isinstance(apps, list) else []:
                name = a.get("Name") or a.get("name", "")
                if name.startswith("agmgd-") and name != self.config("app"):
                    orphans.append({"app": name, "machine": "", "name": "(another Agent Manager app)", "state": a.get("Status", "")})
        except (RuntimeError, ValueError, OSError):
            pass
        return {"sandboxes": rows, "orphans": orphans, "fly_reachable": reachable, **self.status(),
                "total_cost_usd": round(sum(r["cost_usd"] for r in rows), 4)}
