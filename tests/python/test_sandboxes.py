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
        self.ips = []

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
        if args[:2] == ("ips", "allocate-v6"):
            self.ips.append({"Address": "2a09:8280:1::1", "Type": "v6", "ID": "ip6"})
        if args[:2] == ("ips", "allocate-v4"):
            self.ips.append({"Address": "66.241.124.10", "Type": "shared_v4", "ID": ""})
        if args[:2] == ("ips", "release"):
            self.ips = [i for i in self.ips if i["Address"] != args[2]]
        if args[:2] == ("volumes", "create") and getattr(self, "fail_volume", False):
            return 1, "no capacity"
        return 0, "ok"

    def json(self, *args):
        self.calls.append(args)
        if args[:2] == ("orgs", "list"):
            return {"agent-manager": "Agent Manager"}
        if args[:2] == ("machine", "list"):
            return self.machines
        if args[:2] == ("ips", "list"):
            return list(self.ips)
        if args[:2] == ("apps", "list"):
            return [{"Name": "agmgd-spike-96416e", "Status": "deployed"}] + getattr(self, "apps_extra", [])
        return []


class FakeBrain:
    def __init__(self):
        self.revoked = []

    def connect(self, name):
        return "cbrain1"

    def revoke(self, cid):
        self.revoked.append(cid)
        return True

    def clients(self):
        return [{"id": c, "name": "Agent Manager · " + c, "created_at": "", "last_seen": None, "calls": 0}
                for c in ("cbrain1", "cold-test") if c not in self.revoked]

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

    def test_a_new_machine_that_is_not_in_the_list_at_once_is_still_found(self):
        self.s.sandboxes.prepare()
        listed, real = [], self.fly.json

        def late(*args):  # Fly's list shows the new machine only the second time it is asked
            out = real(*args)
            if args[:2] == ("machine", "list"):
                listed.append(1)
                if len(listed) == 1:
                    return [m for m in out if not m["name"].startswith("sandbox-") or m["name"] == "sandbox-old"]
            return out
        self.fly.json = late
        d = self.s.create("Slow list", "shell", "", host="sandbox")
        sb = self.s.sandboxes.by_session(d["id"])
        self.assertEqual(sb["machine"], "m-sandbox-" + sb["id"])  # before: recorded without its machine, never reachable

    def test_the_sandbox_terminal_says_what_it_does_reopens_its_tunnel_and_tries_again(self):
        from engine import sandbox_attach as sa

        class Tunnel:
            def __init__(self, fell):
                self.fell = fell

            def poll(self):
                return 1 if self.fell else None

        # the tunnel fell while the machine was starting: it is opened again, and the wait ends when the sandbox answers
        told, opened, answers = [], [], iter([False, False, True])
        ok, tunnel = sa.wait_until_reachable(lambda: next(answers), Tunnel(True), lambda: (opened.append(1), Tunnel(False))[1],
                                             pause=0, tell=told.append)
        self.assertEqual((ok, len(opened), tunnel.fell), (True, 1, False))
        # it never answers: a line every ten tries says so, then the wait gives up
        ok, _ = sa.wait_until_reachable(lambda: False, Tunnel(False), lambda: Tunnel(False), tries=20, pause=0, tell=told.append)
        self.assertFalse(ok)
        self.assertEqual(len([t for t in told if "still waiting" in t]), 2)

        def scripted(outcomes):
            calls, left = [], iter(outcomes)

            def connect(may_start):
                calls.append(may_start)
                o = next(left)
                if isinstance(o, Exception):
                    raise o
                return o
            return calls, connect

        # a failure, a lost connection, a failure: three tries, then it waits for Enter and tries again; never a traceback
        told, asked = [], []
        calls, connect = scripted([RuntimeError("it did not answer"), sa.SSH_LOST, RuntimeError("Traceback…\nno such tool"), 0])
        self.assertEqual(sa.keep_connected(connect, tell=told.append, ask=lambda: asked.append(1), pause=0), 0)
        self.assertEqual(calls, [True, False, False, True])  # only the first try and the one after Enter may start the machine
        self.assertEqual(len(asked), 1)
        self.assertIn("Press Enter to try again", told[2])
        self.assertIn("no such tool", told[2])
        self.assertNotIn("Traceback", "".join(told))
        # paused by a cap while connected: never started again by itself, it asks at once
        told, asked = [], []
        calls, connect = scripted([sa.SSH_LOST, sa.Paused(), 0])
        self.assertEqual(sa.keep_connected(connect, tell=told.append, ask=lambda: asked.append(1), pause=0), 0)
        self.assertEqual((calls, len(asked)), ([True, False, True], 1))
        self.assertIn("paused", told[-1])
        self.assertIn("Press Enter to start it", told[-1])

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

    def test_budget_refuses_new_sandboxes_and_caps_only_pause(self):
        self.s.sandboxes.prepare()
        d = self.s.create("Cloud work", "shell", "", host="sandbox")
        sb = self.s.sandboxes.by_session(d["id"])
        # the fake machine ran 1 h (then runs again): with a tiny budget, it is reached
        self.s.sandboxes.set_budget(0.001, 0, False)
        ov = self.s.sandboxes.overview()
        self.assertGreaterEqual(ov["budget_percent"], 100)
        with self.assertRaises(ValueError):
            self.s.create("Another", "shell", "", host="sandbox")
        self.s.sandboxes.set_budget(0.001, 30, True)
        stopped = self.s.sandboxes.enforce({sb["id"]: 3600})
        self.assertEqual(stopped, [sb["machine"]])
        self.assertTrue(any(c[:3] == ("machine", "stop", sb["machine"]) for c in self.fly.calls))
        self.assertFalse(any(c[:2] == ("machine", "destroy") for c in self.fly.calls))      # caps never destroy
        self.s.sandboxes.set_budget(0, 10, False)
        self.assertEqual(self.s.sandboxes.enforce({sb["id"]: 60}), [])                          # not idle long enough

    def test_orphans_are_destroyed_only_on_request_and_never_a_known_sandbox(self):
        self.s.sandboxes.prepare()
        d = self.s.create("Cloud work", "shell", "", host="sandbox")
        sb = self.s.sandboxes.by_session(d["id"])
        app = self.s.sandboxes.config("app")
        self.fly.apps_extra = [{"Name": app}]
        with self.assertRaises(ValueError):
            self.s.sandboxes.destroy_orphan(app, "orphan-1", False)                  # needs the confirmation
        with self.assertRaises(ValueError):
            self.s.sandboxes.destroy_orphan(app, sb["machine"], True)               # a known sandbox: from its card
        with self.assertRaises(ValueError):
            self.s.sandboxes.destroy_orphan(app, "", True)                          # the app in use
        with self.assertRaises(ValueError):
            self.s.sandboxes.destroy_orphan("someone-else", "", True)               # not an Agent Manager app
        self.assertEqual(self.s.sandboxes.destroy_orphan(app, "orphan-1", True), {"destroyed": "orphan-1"})
        self.assertEqual([m["id"] for m in self.s.sandboxes.orphan_contents("agmgd-spike-96416e")], [m["id"] for m in self.fly.machines])
        self.assertEqual(self.s.sandboxes.destroy_orphan("agmgd-spike-96416e", "", True), {"destroyed": "agmgd-spike-96416e"})
        self.assertIn(("apps", "destroy", "agmgd-spike-96416e", "--yes"), self.fly.calls)

    def test_only_unused_brain_keys_are_revoked(self):
        self.s.sandboxes.prepare()
        self.s.create("Cloud agent", "claude", "", host="sandbox")    # takes cbrain1
        keys = {k["id"]: k["used_by"] for k in self.s.brain_keys()}
        self.assertTrue(keys["cbrain1"])
        self.assertEqual(keys["cold-test"], "")
        with self.assertRaises(ValueError):
            self.s.revoke_brain_key("cbrain1", True)
        with self.assertRaises(ValueError):
            self.s.revoke_brain_key("cold-test", False)
        self.assertEqual(self.s.revoke_brain_key("cold-test", True), {"revoked": "cold-test"})
        self.assertEqual(self.brain.revoked, ["cold-test"])

    def test_a_sandbox_never_hides_behind_an_archived_session(self):
        self.s.sandboxes.prepare()
        d = self.s.create("Cloud agent", "claude", "", host="sandbox")
        with self.assertRaises(ValueError):
            self.s.archive(d["id"])
        with self.assertRaises(ValueError):
            self.s.wrap_up(d["id"])
        sb = self.s.sandboxes.by_session(d["id"])
        port_file = os.path.join(self.tmp, "runtime", f"sandbox-{sb['id']}.port")
        os.makedirs(os.path.dirname(port_file), exist_ok=True)
        open(port_file, "w").write("12345")
        self.s.sandboxes.destroy(sb["id"], True)
        self.assertFalse(os.path.exists(port_file))                          # nothing left behind
        self.assertEqual(self.s.archive(d["id"])["state"], "archived")

    def test_measured_costs_survive_the_machine_and_estimates_come_first(self):
        est = self.s.sandboxes.estimate()
        self.assertAlmostEqual(est["per_hour"], round(6.70 / 730, 4))
        self.assertGreater(est["paused_per_month"], 0)
        self.assertTrue(self.s.sandboxes.image_info()["contents"])
        self.s.sandboxes.prepare()
        d = self.s.create("Cloud work", "shell", "", host="sandbox")
        sb = self.s.sandboxes.by_session(d["id"])
        now = 1_000_000 + 7_200 + 1_800                         # the fake machine: ran 1 h, stopped 1 h, running again 30 min
        m = next(m for m in self.fly.machines if m["id"] == sb["machine"])
        self.assertEqual(self.s.sandboxes.intervals(m), [(1000.0, 4600.0), (8200.0, None)])
        self.s.sandboxes.sync_runs({sb["machine"]: m})
        self.s.sandboxes.destroy(sb["id"], True)                  # the history stays
        runs = self.s.sandboxes.runs()
        self.assertEqual(len(runs), 2)
        series = self.s.sandboxes.cost_series(days=3, now=now)
        self.assertEqual(len(series["day_cost"]), 3)
        self.assertGreater(series["per_sandbox"][sb["id"]]["total"], 0)
        self.assertIsNotNone(series["per_sandbox"][sb["id"]]["running_since"])

    def test_the_inventory_keeps_a_destroyed_sandbox_with_its_runs_and_its_cost(self):
        self.s.sandboxes.prepare()
        kept = self.s.create("Still there", "shell", "", host="sandbox")
        gone = self.s.create("Cloud work", "shell", "", host="sandbox")
        sb = self.s.sandboxes.by_session(gone["id"])
        m = next(m for m in self.fly.machines if m["id"] == sb["machine"])
        self.s.sandboxes.sync_runs({sb["machine"]: m})                  # ran 1 h, stopped 1 h, running again
        self.s.sandboxes.destroy(sb["id"], True)
        inv = self.s.sandboxes.overview()["inventory"]
        by = {r["id"]: r for r in inv["sandboxes"]}
        self.assertEqual(len(by), 2)                                     # the destroyed one is still listed
        dead = by[sb["id"]]
        self.assertEqual((dead["state"], dead["destroyed"], dead["running_now"]), ("destroyed", True, False))
        self.assertEqual(dead["runs"][0], [1000.0, 4600.0])              # each period its machine ran, as Fly.io told it
        self.assertEqual(dead["first_start"], 1000.0)
        self.assertGreaterEqual(dead["run_seconds"], 3600)
        self.assertGreater(dead["cost_usd"], 0)
        self.assertNotIn("secret", dead)                                 # nothing of its secret in what the page gets
        alive = by[self.s.sandboxes.by_session(kept["id"])["id"]]
        self.assertEqual((alive["state"], alive["destroyed"]), ("started", False))
        # what Fly.io holds now: asked and answered, a machine of ours, and one Agent Manager does not know
        self.assertEqual((inv["at_fly"]["reachable"], inv["at_fly"]["unknown_here"] >= 1), (True, True))
        self.assertGreaterEqual(inv["at_fly"]["machines"], 2)
        def no_network(*args):
            raise RuntimeError("no network")
        self.fly.json = no_network
        self.s.sandboxes.forget_machines()                               # nothing kept from before: Fly.io must be asked
        offline = self.s.sandboxes.overview()["inventory"]               # Fly.io not reached: the inventory is still there
        self.assertEqual((offline["at_fly"]["reachable"], len(offline["sandboxes"])), (False, 2))
        self.assertEqual({r["id"]: r["state"] for r in offline["sandboxes"]}[sb["id"]], "destroyed")

    def test_the_size_is_chosen_priced_and_given_to_fly(self):
        sz = self.s.sandboxes.sizes()
        self.assertEqual([x["id"] for x in sz["sizes"]][:3], ["shared-cpu-1x-256", "shared-cpu-1x-512", "shared-cpu-1x-1024"])
        self.assertEqual((sz["chosen"], sz["source"]), ("shared-cpu-1x-1024", "docs.fly.io/about/pricing, read 2026-11-12"))
        self.assertIn("floors", sz["region_note"])                       # yyz is not one of the regions the page prices
        with self.assertRaises(ValueError):
            self.s.sandboxes.choose_size("huge-cpu-64x")
        self.assertEqual(self.s.sandboxes.choose_size("performance-cpu-2x-4096")["chosen"], "performance-cpu-2x-4096")
        self.assertAlmostEqual(self.s.sandboxes.estimate()["per_month_on"], 66.00)
        self.s.sandboxes.prepare()
        d = self.s.create("Big work", "shell", "", host="sandbox")
        run = next(c for c in self.fly.calls if c[:2] == ("machine", "run"))
        self.assertEqual(run[run.index("--vm-cpu-kind") + 1:run.index("--vm-cpu-kind") + 6], ("performance", "--vm-cpus", "2", "--vm-memory", "4096"))
        self.assertEqual(self.s.sandboxes.by_session(d["id"])["size"], "performance-cpu-2x-4096")
        self.s.sandboxes.set_config("region", "iad")
        self.assertEqual(self.s.sandboxes.sizes()["region_note"], "")

    def test_fly_is_not_asked_at_every_look(self):
        self.s.sandboxes.prepare()
        asked = lambda: len([c for c in self.fly.calls if c[:2] == ("machine", "list")])   # noqa: E731
        self.s.sandboxes.overview()
        first = asked()
        self.s.sandboxes.overview()
        self.s.sandboxes.overview()
        self.assertEqual(asked(), first)                                  # kept: the page did not wait on Fly.io again
        self.s.create("Work", "shell", "", host="sandbox")                # a change made from here: asked again
        self.assertGreater(asked(), first)
        self.s.sandboxes.overview()
        self.s.sandboxes._machines = (self.s.sandboxes.config("app"), 0.0, self.s.sandboxes._machines[2])   # older than ten seconds
        n = asked()
        self.s.sandboxes.overview()                                       # given at once, asked aside
        import time
        end = time.monotonic() + 5
        while time.monotonic() < end and asked() == n:
            time.sleep(0.02)
        self.assertEqual(asked(), n + 1)

    def test_a_sandbox_session_started_again_reaches_its_sandbox_not_a_shell_here(self):
        self.s.sandboxes.prepare()
        for tool in ("shell", "claude"):
            d = self.s.create("Cloud " + tool, tool, "", host="sandbox")
            sb = self.s.sandboxes.by_session(d["id"])
            self.tmux.kill(d["tmux"])                                       # as after WSL was restarted
            self.assertEqual(self.s.get(d["id"])["state"], "missing")
            started = []
            real = self.tmux.new_session
            self.tmux.new_session = lambda name, cwd, cmd, env=None: (started.append((cwd, cmd)), real(name, cwd, cmd, env=env))[1]
            try:
                (self.s.restart if tool == "shell" else self.s.resume)(d["id"])
            finally:
                self.tmux.new_session = real
            cwd, cmd = started[-1]
            self.assertEqual(cmd[1:], [sessions_mod.SANDBOX_ATTACH, sb["id"]], tool)   # the terminal of the sandbox
            self.assertNotEqual(cwd, "/work")

    def test_several_sessions_on_one_sandbox_each_its_own_tmux_and_no_new_machine(self):
        """Loop 40 (owner, 2026-11-14: « ouvrir plusieurs sessions SSH sur la même VM Fly »)."""
        self.s.sandboxes.prepare()
        first = self.s.create("Backend", "claude", "", host="sandbox")
        sb = self.s.sandboxes.by_session(first["id"])
        self.assertTrue(sb["first"])
        runs = len([c for c in self.fly.calls if c[:2] == ("machine", "run")])
        started = []
        real = self.tmux.new_session
        self.tmux.new_session = lambda name, cwd, cmd, env=None: (started.append(cmd), real(name, cwd, cmd, env=env))[1]
        try:
            second = self.s.create("Frontend", "codex", "", host="sandbox", sandbox=sb["id"])
            third = self.s.create("Logs", "shell", "", host="sandbox", sandbox=sb["id"])
        finally:
            self.tmux.new_session = real
        self.assertEqual(len([c for c in self.fly.calls if c[:2] == ("machine", "run")]), runs)   # no new machine
        self.assertEqual(started[0][1:], [sessions_mod.SANDBOX_ATTACH, sb["id"], second["id"]])     # its own terminal
        self.assertEqual(self.s.sandboxes.sessions_on(sb["id"]), [first["id"], second["id"], third["id"]])
        self.assertEqual(second["host"], "sandbox")
        self.assertFalse(second["sandbox"]["first"])
        self.assertEqual(self.s.sandboxes.seat(sb["id"], first["id"])["tmux"], "am")             # existing sandboxes unchanged
        self.assertEqual(self.s.sandboxes.seat(sb["id"], second["id"]), {"tmux": "am-" + second["id"], "first": False, "worktree": False})
        over = {r["id"]: r for r in self.s.sandboxes.overview()["sandboxes"]}
        self.assertEqual(over[sb["id"]]["sessions"], [first["id"], second["id"], third["id"]])
        # started again (after WSL restarted): an added session reaches its own seat, not the first one's
        self.tmux.kill(second["tmux"])
        cmd, _ = self.s._in_sandbox(self.s.get(second["id"]))
        self.assertEqual(cmd[-2:], [sb["id"], second["id"]])
        # an added session may go; the first one keeps the sandbox in the list
        self.assertEqual(self.s.archive(third["id"])["state"], "archived")
        self.s.remove(second["id"])
        self.assertEqual(self.s.sandboxes.sessions_on(sb["id"]), [first["id"]])
        with self.assertRaises(ValueError):
            self.s.archive(first["id"])
        with self.assertRaises(ValueError):
            self.s.remove(first["id"])

    def test_an_added_session_gets_a_worktree_only_with_a_repository_and_a_cap_holds(self):
        from engine import sandboxes as sbmod
        self.s.sandboxes.prepare()
        first = self.s.create("Main", "shell", "", host="sandbox")
        sb = self.s.sandboxes.by_session(first["id"])
        self.s.sandboxes._set(sb["id"], repo_id="r1")
        a = self.s.create("Agent", "claude", "", host="sandbox", sandbox=sb["id"])
        b = self.s.create("Shell", "shell", "", host="sandbox", sandbox=sb["id"])
        self.assertTrue(self.s.sandboxes.seat(sb["id"], a["id"])["worktree"])     # an agent: its own worktree
        self.assertFalse(self.s.sandboxes.seat(sb["id"], b["id"])["worktree"])    # a shell: the sandbox's folder
        self.assertEqual(self.s.get(a["id"])["repo_id"], "r1")
        while len(self.s.sandboxes.sessions_on(sb["id"])) < sbmod.MAX_SESSIONS_PER_SANDBOX:
            self.s.create("More", "shell", "", host="sandbox", sandbox=sb["id"])
        before = len(self.s.store.all())
        with self.assertRaises(ValueError):
            self.s.create("One too many", "shell", "", host="sandbox", sandbox=sb["id"])
        self.assertEqual(len(self.s.store.all()), before)                           # nothing half made
        # an agent (a parent) may add a session to a sandbox, never make a machine
        with self.assertRaises(ValueError):
            self.s.create("Machine", "shell", "", host="sandbox", parent=first["id"])
        # destroyed: nobody can be added, and every session is free to go
        self.s.sandboxes.destroy(sb["id"], True)
        with self.assertRaises(ValueError):
            self.s.create("Late", "shell", "", host="sandbox", sandbox=sb["id"])
        self.assertIsNone(self.s.sandboxes.by_session(a["id"]))
        self.s.remove(a["id"])

    def test_the_idle_cap_looks_at_every_session_of_a_sandbox(self):
        self.s.sandboxes.prepare()
        first = self.s.create("Quiet", "shell", "", host="sandbox")
        sb = self.s.sandboxes.by_session(first["id"])
        busy = self.s.create("Busy", "shell", "", host="sandbox", sandbox=sb["id"])
        self.s.sandboxes.set_budget(0, 1, False)
        seen = {}
        self.s.sandboxes.enforce = lambda idle: seen.update(idle) or []

        class T:
            def __init__(self, activity):
                self.activity = activity
        import time as _t
        self.tmux.sessions = lambda: {self.s.tmux_name(first["id"]): T(_t.time() - 3600), self.s.tmux_name(busy["id"]): T(_t.time() - 5)}
        self.s._last_enforce = 0
        self.s.enforce_caps()
        self.assertLess(seen[sb["id"]], 60)        # before: only the first session's terminal counted (an hour idle)

    def test_an_added_sessions_terminal_starts_its_own_tool_and_is_found_again(self):
        """The command run in the machine, against a real tmux on this computer (no SSH, no Fly)."""
        from engine.sandbox_attach import seat_command, worktree_command
        import subprocess
        # Never the owner's tmux: inside a session of Agent Manager $TMUX names its server and wins over TMUX_TMPDIR
        # (a « kill-server » here once ended every session of the owner, 2026-11-14). A socket of this test only.
        env = {k: v for k, v in os.environ.items() if not k.startswith("TMUX")}
        env["TMUX_TMPDIR"] = self.tmp
        sock = os.path.join(self.tmp, f"tmux-{os.getuid()}", "default")
        work = os.path.join(self.tmp, "it's here")
        os.makedirs(work)
        cmd = seat_command("am-x1", work, "sleep 60").replace("exec tmux attach -t am-x1", "true")
        for _ in range(2):                                                  # the second time finds it, starts nothing more
            subprocess.run(["bash", "-c", cmd], env=env, check=True, timeout=20)
        out = subprocess.run(["tmux", "-S", sock, "list-panes", "-a", "-F", "#{session_name} #{pane_current_path}"], env=env,
                             capture_output=True, text=True, timeout=20).stdout.splitlines()
        subprocess.run(["tmux", "-S", sock, "kill-server"], env=env, capture_output=True, timeout=20)
        self.assertEqual(out, ["am-x1 " + work])
        # its worktree: made once beside the clone, on its own branch; asked again, it is there
        repo = os.path.join(self.tmp, "repo")
        subprocess.run(["git", "init", "-q", repo], check=True)
        subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        for _ in range(2):
            self.assertEqual(subprocess.run(["bash", "-c", worktree_command(repo, repo + "-x1", "am/s1-x1")]).returncode, 0)
        self.assertEqual(subprocess.run(["git", "-C", repo + "-x1", "branch", "--show-current"], capture_output=True, text=True).stdout.strip(), "am/s1-x1")

    def test_an_online_machine_has_its_own_app_a_volume_and_is_private_until_exposed(self):
        """Loop 41 (owner, 2026-11-14: « un service sur le port 443. Le reste ce serait en backend »; named « Online »)."""
        self.s.sandboxes.prepare()
        with self.assertRaises(ValueError):
            self.s.create_online_session("Bad Name!", "claude", "", 8080)
        with self.assertRaises(ValueError):
            self.s.create_online_session("shop", "claude", "", 2222)                  # SSH's port is never the service's
        d = self.s.create_online_session("shop", "claude", "", 8080, volume_gb=3)
        sb = self.s.sandboxes.by_session(d["id"])
        self.assertEqual(sb["kind"], "online")
        self.assertTrue(sb["app"].startswith("agmgd-on-shop-"))
        self.assertEqual(sb["workdir"], "/data/work")                                  # its work lives on the volume
        self.assertIn(("apps", "create", sb["app"], "--org", "agent-manager"), self.fly.calls)
        vol = next(c for c in self.fly.calls if c[:2] == ("volumes", "create"))
        self.assertEqual(vol[vol.index("--size") + 1], "3")
        run = next(c for c in self.fly.calls if c[:2] == ("machine", "run") and sb["app"] in c)
        ports = [run[i + 1] for i, a in enumerate(run) if a == "--port"]
        self.assertEqual(ports, ["443:8080/tcp:tls:http", "80:8080/tcp:http"])          # one door, toward its port
        self.assertIn("data:/data", run)
        self.assertFalse(any(c[:2] == ("ips", "allocate-v4") or c[:2] == ("ips", "allocate-v6") for c in self.fly.calls))  # private
        self.assertEqual(d["sandbox"]["kind"], "online")
        info = self.s.sandboxes.online_info(sb["id"])
        self.assertEqual((info["exposed"], info["url"]), (False, ""))
        # exposed only when confirmed; a sandbox is never exposed
        with self.assertRaises(ValueError):
            self.s.sandboxes.expose(sb["id"], confirmed=False)
        plain = self.s.create("Private", "shell", "", host="sandbox")
        with self.assertRaises(ValueError):
            self.s.sandboxes.expose(self.s.sandboxes.by_session(plain["id"])["id"], confirmed=True)
        info = self.s.sandboxes.expose(sb["id"], confirmed=True)
        self.assertEqual(info["url"], f"https://{sb['app']}.fly.dev")
        self.assertIn(("ips", "allocate-v4", "--shared", "--app", sb["app"]), self.fly.calls)   # shared: free
        self.s.sandboxes.expose(sb["id"], confirmed=True)                                 # again: no second address
        self.assertEqual(len([c for c in self.fly.calls if c[:2] == ("ips", "allocate-v6")]), 1)
        info = self.s.sandboxes.unexpose(sb["id"])
        self.assertEqual((info["exposed"], self.fly.ips), (False, []))
        # its app is not an orphan; pauses of the owner's caps never touch it
        over = self.s.sandboxes.overview()
        self.assertFalse(any(o["app"] == sb["app"] for o in over["orphans"]))
        self.assertEqual(next(r for r in over["sandboxes"] if r["id"] == sb["id"])["online"]["name"], "shop")
        self.s.sandboxes.set_budget(0, 1, False)
        self.assertEqual(self.s.sandboxes.enforce({sb["id"]: 99999}), [])
        self.assertNotIn(sb["machine"], self.s.sandboxes.stop_all())
        # destroyed: its whole app goes (volume and addresses with it)
        self.s.sandboxes.destroy(sb["id"], True)
        self.assertIn(("apps", "destroy", sb["app"], "--yes"), self.fly.calls)

    def test_an_online_machine_half_made_leaves_nothing_billed(self):
        self.s.sandboxes.prepare()
        self.fly.fail_volume = True
        before = len(self.s.store.all())
        with self.assertRaises(ValueError):
            self.s.create_online_session("blog", "shell", "", 3000)
        app = next(c[2] for c in self.fly.calls if c[:2] == ("apps", "create") and c[2].startswith("agmgd-on-"))
        self.assertIn(("apps", "destroy", app, "--yes"), self.fly.calls)
        self.assertEqual(len(self.s.store.all()), before)

    def test_the_owner_routes_answer_over_http(self):
        """The API routes themselves (a generic /sandboxes/<id>/<action> route once swallowed the orphan ones)."""
        tok = load_token(self.tmp)
        srv = serve(self.s, tok, 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_address[1]}"

        def call(method, path, body=None):
            req = urllib.request.Request(base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read())
        try:
            self.assertEqual(len(call("GET", "/sandboxes/orphans/agmgd-spike-96416e")["machines"]), 1)
            self.assertEqual(call("POST", "/sandboxes/orphans/destroy", {"app": "agmgd-spike-96416e", "machine": "", "confirmed": True}),
                             {"destroyed": "agmgd-spike-96416e"})
            self.assertEqual({k["id"] for k in call("GET", "/brain/keys")["keys"]}, {"cbrain1", "cold-test"})
            self.assertEqual(call("POST", "/brain/keys/cold-test/revoke", {"confirmed": True}), {"revoked": "cold-test"})
            self.assertEqual(call("POST", "/sandboxes/budget", {"monthly_usd": 5})["monthly_usd"], 5.0)
            self.assertEqual(call("POST", "/sandboxes/stop-all", {}), {"stopped": []})
        finally:
            srv.shutdown()

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
