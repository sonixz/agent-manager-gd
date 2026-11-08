"""Loop 5: history, resume, fork, archive, worktrees. Fake claude/codex print the options they were given."""
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux

FAKE = """#!/bin/sh
echo "FAKE-$(basename "$0") $*"
exec sleep 600
"""


@unittest.skipUnless(shutil.which("tmux") and shutil.which("git"), "tmux and git are needed")
class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-hist-")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        for tool in ("claude", "codex"):
            path = os.path.join(bin_dir, tool)
            with open(path, "w") as f:
                f.write(FAKE)
            os.chmod(path, 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = bin_dir + os.pathsep + self.old_path
        self.tmux = Tmux("agmgd-hist", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def screen(self, sid, needle, sec=5.0):
        end = time.time() + sec
        text = ""
        while time.time() < end:
            text = self.s.preview(sid)
            if needle in text:
                return text
            time.sleep(0.1)
        self.fail(f"{needle!r} not on screen: {text[-300:]!r}")

    def test_a_new_claude_session_knows_its_conversation_from_the_start(self):
        d = self.s.create("Brain themes", "claude", self.tmp)
        conv = d["last_conversation"]
        self.assertRegex(conv, r"^[0-9a-f-]{36}$")
        self.screen(d["id"], f"--session-id {conv}")

    def test_resume_goes_back_to_its_own_conversation_even_from_the_archive(self):
        d = self.s.create("Docs", "claude", self.tmp)
        conv = d["last_conversation"]
        self.s.archive(d["id"])
        self.assertEqual(self.s.get(d["id"])["state"], "archived")
        self.assertNotIn(d["id"], [x["id"] for x in self.s.list()])        # out of the way…
        hist = self.s.history("docs")
        self.assertEqual([h["id"] for h in hist], [d["id"]])                # …never forgotten
        self.assertEqual(hist[0]["conversations"][0]["conversation"], conv)
        self.assertEqual(self.s.history(conv[:8])[0]["id"], d["id"])         # found by its conversation id
        back = self.s.resume(d["id"])
        self.assertEqual(back["state"], "running")
        self.screen(d["id"], f"--resume {conv}")

    def test_fork_starts_a_new_session_on_a_copy_of_the_conversation(self):
        d = self.s.create("Tree", "claude", self.tmp, grp="Agent Manager")
        f = self.s.fork(d["id"], "Tree, other idea")
        self.assertEqual((f["parent"], f["grp"], f["cwd"]), (d["id"], "Agent Manager", d["cwd"]))
        self.screen(f["id"], f"--resume {d['last_conversation']} --fork-session")

    def test_codex_resumes_its_thread_or_shows_its_picker(self):
        d = self.s.create("Codex work", "codex", self.tmp)
        self.s.resume(d["id"])                       # no thread id seen yet: Codex's own picker
        self.screen(d["id"], "FAKE-codex resume -c notify=")
        self.s.store.touch_conversation(d["id"], "codex", "019a-thread")
        self.s.resume(d["id"])
        self.screen(d["id"], "019a-thread")

    def test_a_worktree_session_works_on_its_own_branch_and_finishes_cleanly(self):
        repo = os.path.join(self.tmp, "repo")
        os.makedirs(repo)
        git = lambda cwd, *a: subprocess.run(["git", "-C", cwd, *a], check=True, capture_output=True, text=True).stdout
        git(repo, "init", "-q", "-b", "main")
        git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "start")
        d = self.s.create("Fix login", "shell", repo, worktree=True)
        self.assertTrue(d["cwd"].endswith("repo-worktrees/fix-login"))
        self.assertEqual(d["branch"], "am/fix-login")
        with open(os.path.join(d["cwd"], "a.txt"), "w") as f:
            f.write("x")
        with self.assertRaises(ValueError):          # uncommitted work is never thrown away
            self.s.finish(d["id"], merge=True, delete_branch=True)
        git(d["cwd"], "add", "a.txt")
        git(d["cwd"], "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix")
        st = self.s.worktree_status(d["id"])
        self.assertEqual((st["commits_ahead"], st["uncommitted"], st["target"]), (1, 0, "main"))
        res = self.s.finish(d["id"], merge=True, delete_branch=True)
        self.assertEqual((res["merged"], res["branch_deleted"]), (True, True))
        self.assertIn("fix", git(repo, "log", "--oneline"))
        self.assertFalse(os.path.exists(d["cwd"]))
        self.assertEqual(self.s.get(d["id"])["state"], "archived")


if __name__ == "__main__":
    unittest.main()
