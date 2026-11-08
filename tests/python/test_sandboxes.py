"""Loop 13: the sandbox manager against a fake Fly (every command recorded)."""
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.request
from urllib.error import HTTPError

import engine.sessions as sessions_mod
from engine.api import load_token, serve
from engine.keys import Keys
from engine.sandboxes import Sandboxes
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux


class FakeFly:
    def __init__(self):
        self.calls = []
        self.machines = [{"id": "orphan-1", "name": "sandbox-old", "state": "stopped", "events": []}]

    def available(self):
        return True

    def env(self):
        return dict(os.environ)

    def run(self, *args, timeout=0, cwd=None, inp=None):
        self.calls.append(args)
        if args[:2] == ("machine", "run"):
            name = args[args.index("--name") + 1]
            self.machines.append({"id": "m-" + name, "name": name, "state": "started", "events": [
                {"type": "launch", "timestamp": 1_000_000}, {"type": "stop", "timestamp": 1_000_000 + 3_600_000},
                {"type": "start", "timestamp": 1_000_000 + 7_200_000}]})
        if args[:2] == ("machine", "destroy"):
            self.machines = [m for m in self.machines if m["id"] != args[2]]
        return 0, "ok"

    def json(self, *args):
        self.calls.append(args)
        if args[:2] == ("orgs", "list"):
            return {"agent-manager": "Agent Manager"}
        if args[:2] == ("machine", "list"):
            return self.machines
        if args[:2] == ("apps", "list"):
            return [{"Name": "agmgd-spike-96416e", "Status": "deployed"}]
        return []


class FakeBrain:
    def __init__(self):
        self.revoked = []

    def connect(self, name):
        return "cbrain1"

    def revoke(self, cid):
        self.revoked.append(cid)

    def status(self):
        return {"connected": True}

    def mcp_forward(self, cid, body, session):
        return {"status": 200, "text": json.dumps({"client": cid, "echo": json.loads(body)}), "session": "s1"}

    def server_spec(self, cid):
        return {"command": "x", "args": []}


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class SandboxesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-sbx-")
        os.environ["AGMGD_KEYS_PLAIN"] = "1"
        self.old_attach = sessions_mod.SANDBOX_ATTACH
        dummy = os.path.join(self.tmp, "attach.py")
        with open(dummy, "w") as f:
            f.write("import time\nprint('attached')\ntime.sleep(600)\n")
        sessions_mod.SANDBOX_ATTACH = dummy
        self.tmux = Tmux("agmgd-sbx", tmpdir=self.tmp)
        self.brain = FakeBrain()
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp, self.brain)
        self.fly = FakeFly()
        self.s.sandboxes = Sandboxes(self.s.store.path, self.tmp, Keys(self.tmp), fly=self.fly)
        self.s.keys_store.set("fly", "FlyV1 fake-token")

    def tearDown(self):
        sessions_mod.SANDBOX_ATTACH = self.old_attach
        os.environ.pop("AGMGD_KEYS_PLAIN", None)
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_prepare_then_a_sandbox_session_with_its_own_key_and_brain(self):
        with self.assertRaises(ValueError):
            self.s.create("Cloud", "claude", "", host="sandbox")          # not prepared yet
        st = self.s.sandboxes.prepare()
        self.assertTrue(st["ready"])
        self.assertTrue(st["app"].startswith("agmgd-"))
        self.assertIn(("apps", "create", st["app"], "--org", "agent-manager"), self.fly.calls)
        d = self.s.create("Cloud work", "claude", "", host="sandbox")
        self.assertEqual(d["host"], "sandbox")
        sb = self.s.sandboxes.by_session(d["id"])
        self.assertTrue(os.path.exists(self.s.sandboxes.key_path(sb["id"])))
        run = next(c for c in self.fly.calls if c[:2] == ("machine", "run"))
        self.assertIn("--region", run)
        self.assertTrue(any(a.startswith("AGMGD_AUTHORIZED_KEY=ssh-ed25519") for a in run))   # a public key, not a secret
        self.assertFalse(any("fake-token" in a for c in self.fly.calls for a in c))            # the Fly token never in arguments
        self.assertEqual(sb["brain_client"], "cbrain1")

    def test_overview_costs_and_orphans_never_touched(self):
        self.s.sandboxes.prepare()
        d = self.s.create("Cloud work", "shell", "", host="sandbox")
        ov = self.s.sandboxes.overview()
        row = ov["sandboxes"][0]
        self.assertGreaterEqual(row["running_seconds"], 3600)            # 1 h before the stop, then running again
        self.assertGreater(row["cost_usd"], 0)
        names = {(o["app"], o["name"]) for o in ov["orphans"]}
        self.assertIn(("agmgd-spike-96416e", "(another Agent Manager app)"), names)
        self.assertTrue(any(o["machine"] == "orphan-1" for o in ov["orphans"]))
        self.assertFalse(any(c[:2] == ("machine", "destroy") for c in self.fly.calls))   # nothing destroyed on its own

    def test_destroy_only_when_confirmed_and_the_session_cannot_be_removed_before(self):
        self.s.sandboxes.prepare()
        d = self.s.create("Cloud work", "claude", "", host="sandbox")
        sb = self.s.sandboxes.by_session(d["id"])
        with self.assertRaises(ValueError):
            self.s.remove(d["id"])
        with self.assertRaises(ValueError):
            self.s.sandboxes.destroy(sb["id"], confirmed=False)
        self.s.sandboxes.destroy(sb["id"], confirmed=True, brain=self.brain)
        self.assertIn(("machine", "destroy", sb["machine"], "--app", sb["app"], "--force"), self.fly.calls)
        self.assertEqual(self.brain.revoked, ["cbrain1"])
        self.assertFalse(os.path.exists(self.s.sandboxes.key_path(sb["id"])))
        self.s.remove(d["id"])                                            # now it can go

    def test_the_brain_relay_answers_only_to_a_sandbox_secret(self):
        self.s.sandboxes.prepare()
        d = self.s.create("Cloud work", "claude", "", host="sandbox")
        secret = self.s.sandboxes.by_session(d["id"])["secret"]
        srv = serve(self.s, load_token(self.tmp), 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_address[1]}/sandbox-brain"
        try:
            with urllib.request.urlopen(base + f"/{secret}/health", timeout=5) as r:
                self.assertTrue(json.loads(r.read())["brain"])
            req = urllib.request.Request(base + f"/{secret}/mcp", data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}).encode(), method="POST")
            with urllib.request.urlopen(req, timeout=5) as r:
                self.assertEqual(json.loads(r.read())["client"], "cbrain1")
                self.assertEqual(r.headers["Mcp-Session-Id"], "s1")
            with self.assertRaises(HTTPError) as e:
                urllib.request.urlopen(base + "/wrong-secret/health", timeout=5)
            self.assertEqual(e.exception.code, 404)
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main()
