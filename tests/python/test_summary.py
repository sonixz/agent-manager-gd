"""Loop 7: the agent writes its own summary when the session closes; the next session starts from it."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from engine.sessions import HOOK, Sessions
from engine.store import Store
from engine.tmux import Tmux
from tests.python.test_history import FAKE


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class SummaryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-sum-")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        for tool in ("claude", "codex"):
            with open(os.path.join(bin_dir, tool), "w") as f:
                f.write(FAKE)
            os.chmod(os.path.join(bin_dir, tool), 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = bin_dir + os.pathsep + self.old_path
        self.project = os.path.join(self.tmp, "project")
        os.makedirs(self.project)
        self.tmux = Tmux("agmgd-sum", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def agent_finishes(self, sid, path, text):
        """What the real agent does: writes the file, then its Stop hook fires."""
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        time.sleep(1.1)
        env = {**os.environ, "AGMGD_SESSION": sid, "AGMGD_HOME": self.tmp}
        subprocess.run([sys.executable, HOOK, "claude"], input=json.dumps({"hook_event_name": "Stop"}), text=True, env=env, timeout=10)

    def test_wrap_up_keeps_the_agents_summary_and_archives_the_session(self):
        d = self.s.create("Login fix", "claude", self.project)
        w = self.s.wrap_up(d["id"])
        self.assertEqual(self.s.get(d["id"])["activity"], "wrapping")
        time.sleep(0.5)
        self.assertIn(w["summary_path"], self.s.preview(d["id"]).replace("\n", ""))   # the request reached the agent
        self.agent_finishes(d["id"], w["summary_path"], "## What was done\nFixed the login redirect.\n## What is left\nTests for SSO.")
        self.s.list()
        got = self.s.get(d["id"])
        self.assertEqual(got["state"], "archived", (self.s.hook_state(d["id"]), os.path.exists(w["summary_path"]), dict(self.s._wrapping)))
        (summary,) = self.s.store.summaries(sid=d["id"])
        self.assertIn("SSO", summary["text"])
        self.assertEqual(summary["conversation"], d["last_conversation"])
        self.assertEqual(self.s.history("redirect")[0]["id"], d["id"])                 # summaries are searchable

    def test_a_new_session_in_the_same_folder_starts_from_the_latest_summary(self):
        d = self.s.create("Login fix", "claude", self.project)
        w = self.s.wrap_up(d["id"])
        self.agent_finishes(d["id"], w["summary_path"], "## What is left\nTests for SSO.")
        self.s.list()
        n = self.s.create("Login, part 2", "codex", self.project, brief=True)
        end = time.time() + 5
        while w["summary_path"] not in self.s.preview(n["id"]).replace("\n", "") and time.time() < end:
            time.sleep(0.1)
        self.assertIn("read " + w["summary_path"], self.s.preview(n["id"]).replace("\n", ""))

    def test_a_shell_or_a_stopped_session_cannot_be_wrapped_up(self):
        sh = self.s.create("sh", "shell", self.project)
        with self.assertRaises(ValueError):
            self.s.wrap_up(sh["id"])


if __name__ == "__main__":
    unittest.main()
