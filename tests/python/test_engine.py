"""Engine tests on a real, isolated tmux server (its own socket and TMUX_TMPDIR)."""
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
import urllib.request
from urllib.error import HTTPError

from engine.api import load_token, serve
from engine.sessions import ACTIVE_SECONDS as ACTIVE, Sessions
from engine.store import Store
from engine.tmux import Tmux


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class EngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-test-")
        self.tmux = Tmux("agmgd-test", tmpdir=self.tmp)
        self.sessions = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)

    def tearDown(self):
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def wait_for(self, sid, needle, sec=5.0):
        end = time.time() + sec
        while time.time() < end:
            if needle in self.sessions.preview(sid):
                return True
            time.sleep(0.1)
        return False

    def test_a_session_runs_in_tmux_and_outlives_its_records_reader(self):
        s = self.sessions.create("Shell é", "shell", self.tmp)
        self.assertEqual(s["state"], "running")
        self.assertTrue(s["tmux"].startswith("am_"))
        # a new engine (the app reopened) sees the same session alive
        again = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), Tmux("agmgd-test", tmpdir=self.tmp), self.tmp)
        self.assertEqual([x["state"] for x in again.list()], ["running"])
        self.assertEqual(again.list()[0]["name"], "Shell é")

    def test_text_sent_reaches_the_program_with_accents(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.sessions.send(s["id"], "echo déjà « vu » — ok")
        self.assertTrue(self.wait_for(s["id"], "déjà « vu » — ok"))

    def test_a_finished_program_keeps_its_last_screen_and_restarts(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.sessions.send(s["id"], "echo last words; exit")
        end = time.time() + 5
        while self.sessions.get(s["id"])["state"] != "exited" and time.time() < end:
            time.sleep(0.1)
        self.assertEqual(self.sessions.get(s["id"])["state"], "exited")
        self.assertIn("last words", self.sessions.preview(s["id"]))
        self.assertEqual(self.sessions.restart(s["id"])["state"], "running")

    def test_a_session_gone_from_tmux_is_missing_and_comes_back(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.tmux.kill_server()  # a reboot
        self.assertEqual(self.sessions.get(s["id"])["state"], "missing")
        self.assertEqual(self.sessions.restart(s["id"])["state"], "running")

    def test_attach_command_names_the_private_server(self):
        s = self.sessions.create("t", "shell", self.tmp)
        cmd = self.sessions.attach_command(s["id"])
        self.assertIn("-L", cmd)
        self.assertIn("agmgd-test", cmd)
        self.assertEqual(cmd[-1], s["tmux"])

    def test_named_keys_only(self):
        s = self.sessions.create("k", "shell", self.tmp)
        self.sessions.send(s["id"], "read -r x; echo got:$x", enter=True)
        time.sleep(0.3)
        self.sessions.send(s["id"], "yes", enter=False)
        self.sessions.keys(s["id"], ["Enter"])
        self.assertTrue(self.wait_for(s["id"], "got:yes"))
        with self.assertRaises(ValueError):
            self.sessions.keys(s["id"], ["C-c; kill-server"])

    def test_bad_input_is_refused(self):
        with self.assertRaises(ValueError):
            self.sessions.create("t", "rm -rf", self.tmp)
        with self.assertRaises(ValueError):
            self.sessions.create("t", "shell", os.path.join(self.tmp, "nope"))
        with self.assertRaises(ValueError):
            self.sessions.create("", "shell", self.tmp)

    def test_windows_paths_become_wsl_paths(self):
        from engine.sessions import host_path
        if os.path.isdir("/mnt/c"):
            self.assertEqual(host_path("C:\\git-2026\\agent-manager-gd"), "/mnt/c/git-2026/agent-manager-gd")
            self.assertEqual(host_path("c:/Users"), "/mnt/c/Users")
        self.assertEqual(host_path("/home/x"), "/home/x")
        self.assertEqual(host_path("~"), "~")

    def test_remove_kills_and_forgets(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.sessions.remove(s["id"])
        self.assertEqual(self.sessions.list(), [])
        self.assertNotIn(s["tmux"], self.tmux.sessions())

    def test_the_project_tree_keeps_groups_order_and_folding(self):
        a = self.sessions.create("a", "shell", self.tmp, grp="Brain")
        b = self.sessions.create("b", "shell", self.tmp, grp="Brain")
        c = self.sessions.create("c", "shell", self.tmp, grp="TTS")
        loose = self.sessions.create("loose", "shell", self.tmp)
        self.sessions.move(b["id"], "Brain", 0)              # reorder inside a group
        self.sessions.move(loose["id"], "TTS", 1)            # into another group, after c
        self.sessions.store.order_groups(["TTS", "Brain"])
        self.sessions.store.fold_group("Brain", True)
        # a new engine (the app reopened) sees the same tree
        again = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), Tmux("agmgd-test", tmpdir=self.tmp), self.tmp)
        tree = again.tree()["groups"]
        self.assertEqual([g["name"] for g in tree], ["", "TTS", "Brain"])
        self.assertEqual([s["name"] for s in tree[1]["sessions"]], ["c", "loose"])
        self.assertEqual([s["name"] for s in tree[2]["sessions"]], ["b", "a"])
        self.assertTrue(tree[2]["folded"])
        self.sessions.store.rename_group("TTS", "Ticket System")
        self.assertEqual(self.sessions.get(c["id"])["grp"], "Ticket System")
        self.sessions.store.delete_group("Ticket System")    # sessions stay, ungrouped
        names = [s["name"] for s in self.sessions.tree()["groups"][0]["sessions"]]
        self.assertEqual(names, ["c", "loose"])
        self.assertEqual(len(self.sessions.list()), 4)

    def run_hook(self, sid, tool, payload):
        import subprocess, sys
        from engine.sessions import HOOK
        env = {**os.environ, "AGMGD_SESSION": sid, "AGMGD_HOME": self.tmp}
        args = [sys.executable, HOOK, tool] + ([json.dumps(payload)] if tool == "codex" else [])
        out = subprocess.run(args, input=json.dumps(payload) if tool == "claude" else "", capture_output=True,
                             text=True, env=env, timeout=10)
        self.assertEqual((out.returncode, out.stdout), (0, ""))  # silent, never fails

    def test_claude_hooks_drive_the_live_state(self):
        s = self.sessions.create("c", "shell", self.tmp)
        self.sessions.store.update(s["id"])  # no-op
        rec = {**self.sessions.store.get(s["id"]), "tool": "claude"}
        steps = [({"hook_event_name": "SessionStart", "session_id": "conv-1"}, "idle"),
                 ({"hook_event_name": "UserPromptSubmit", "prompt": "x"}, "working"),
                 ({"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"}, "approval"),
                 ({"hook_event_name": "PreToolUse", "tool_name": "Bash"}, "working"),
                 ({"hook_event_name": "Stop"}, "done"),
                 ({"hook_event_name": "Notification", "message": "Claude is waiting for your input"}, "waiting")]
        for payload, want in steps:
            self.run_hook(s["id"], "claude", payload)
            live = self.tmux.sessions()
            got = self.sessions.describe(rec, live)
            self.assertEqual(got["activity"], want, payload)
        self.assertEqual(got["conversation"], "conv-1")  # kept for resuming (Loop 5)

    def test_codex_notify_and_terminal_activity(self):
        s = self.sessions.create("x", "shell", self.tmp)
        rec = {**self.sessions.store.get(s["id"]), "tool": "codex"}
        time.sleep(ACTIVE + 0.2)
        self.assertEqual(self.sessions.describe(rec)["activity"], "idle")
        self.run_hook(s["id"], "codex", {"type": "agent-turn-complete", "thread-id": "t-9", "last-assistant-message": "Fini."})
        d = self.sessions.describe(rec)
        self.assertEqual((d["activity"], d["message"], d["conversation"]), ("done", "Fini.", "t-9"))

    def test_a_shell_running_a_program_is_working(self):
        s = self.sessions.create("sh", "shell", self.tmp)
        self.sessions.send(s["id"], "sleep 3")
        end = time.time() + 3
        while self.sessions.get(s["id"])["activity"] != "working" and time.time() < end:
            time.sleep(0.1)
        self.assertEqual(self.sessions.get(s["id"])["activity"], "working")

    def test_claude_is_launched_with_its_own_hooks_only(self):
        rec = {"id": "abcd1234", "tool": "claude"}
        cmd = self.sessions.command_for(rec)
        self.assertEqual(cmd[:2], ["claude", "--settings"])
        with open(cmd[2], encoding="utf-8") as f:
            hooks = json.load(f)["hooks"]
        self.assertIn("Stop", hooks)
        self.assertTrue(cmd[2].startswith(self.tmp))  # in our data folder, never ~/.claude
        codex = self.sessions.command_for({"id": "x", "tool": "codex"})
        self.assertTrue(codex[2].startswith("notify=["))

    @unittest.skipUnless(os.environ.get("AGMGD_TEST_CLAUDE_DIR"), "set AGMGD_TEST_CLAUDE_DIR to a folder Claude Code trusts")
    def test_real_claude_reports_session_start(self):
        """Starts the real Claude Code (no prompt, no cost): its SessionStart hook must reach the engine."""
        s = self.sessions.create("real", "claude", os.environ["AGMGD_TEST_CLAUDE_DIR"])
        end = time.time() + 30
        while not self.sessions.get(s["id"])["conversation"] and time.time() < end:
            time.sleep(0.3)
        d = self.sessions.get(s["id"])
        self.assertEqual(d["activity"], "idle")
        self.assertTrue(d["conversation"])

    def test_the_api_needs_its_token(self):
        token = load_token(self.tmp)
        self.assertEqual(oct(os.stat(os.path.join(self.tmp, "runtime", "api_token")).st_mode & 0o777), "0o600")
        srv = serve(self.sessions, token, 0)
        port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            def call(method, path, body=None, auth=True):
                req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method,
                                             data=json.dumps(body).encode() if body is not None else None)
                if auth:
                    req.add_header("Authorization", "Bearer " + token)
                with urllib.request.urlopen(req, timeout=5) as r:
                    return r.status, json.loads(r.read())
            self.assertEqual(call("GET", "/health", auth=False)[0], 200)
            with self.assertRaises(HTTPError) as e:
                call("GET", "/sessions", auth=False)
            self.assertEqual(e.exception.code, 401)
            code, made = call("POST", "/sessions", {"name": "API", "tool": "shell", "cwd": self.tmp})
            self.assertEqual((code, made["state"]), (201, "running"))
            self.assertEqual(call("GET", "/sessions")[1]["sessions"][0]["id"], made["id"])
            self.assertIn("attach-session", call("GET", f"/sessions/{made['id']}/attach")[1]["command"])
            with self.assertRaises(HTTPError) as e:
                call("POST", "/sessions", {"name": "x", "tool": "nope", "cwd": self.tmp})
            self.assertEqual(e.exception.code, 400)
            self.assertEqual(call("DELETE", f"/sessions/{made['id']}")[1], {"ok": True})
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main()
