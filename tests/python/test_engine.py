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
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class EngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-test-")
        self.tmux = Tmux("agmgd-test", tmpdir=self.tmp)
        self.sessions = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux)

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
        again = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), Tmux("agmgd-test", tmpdir=self.tmp))
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
