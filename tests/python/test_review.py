"""Loop 8: a session's diff (three modes) and line comments sent to the agent as one request."""
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from engine import review
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux


def git(cwd, *a):
    return subprocess.run(["git", "-C", cwd, "-c", "user.name=t", "-c", "user.email=t@t", *a], check=True,
                          capture_output=True, text=True).stdout


@unittest.skipUnless(shutil.which("tmux") and shutil.which("git"), "tmux and git are needed")
class ReviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-rev-")
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        git(self.repo, "init", "-q", "-b", "main")
        with open(os.path.join(self.repo, "app.py"), "w") as f:
            f.write("def hello():\n    return 'bonjour'\n\nprint(hello())\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "start")
        self.tmux = Tmux("agmgd-rev", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)

    def tearDown(self):
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_uncommitted_and_since_start_diffs_with_line_numbers(self):
        d = self.s.create("Agent", "shell", self.repo)
        self.assertEqual(d["start_commit"], git(self.repo, "rev-parse", "HEAD").strip())
        with open(os.path.join(self.repo, "app.py"), "w") as f:
            f.write("def hello(name):\n    return f'bonjour {name}'\n\nprint(hello('é'))\n")
        git(self.repo, "commit", "-q", "-am", "names")
        with open(os.path.join(self.repo, "app.py"), "a") as f:
            f.write("print('encore')\n")
        with open(os.path.join(self.repo, "notes.md"), "w") as f:
            f.write("# Notes\nà faire\n")
        unc = self.s.diff(d["id"], "uncommitted")
        self.assertEqual([f["path"] for f in unc["files"]], ["app.py", "notes.md"])
        app = unc["files"][0]
        self.assertEqual((app["additions"], app["deletions"]), (1, 0))
        added = [l for h in app["hunks"] for l in h["lines"] if l["t"] == "+"]
        self.assertEqual((added[0]["new"], added[0]["text"]), (5, "print('encore')"))
        self.assertEqual(unc["files"][1]["status"], "added")                      # new files are shown too
        since = self.s.diff(d["id"], "session")                                   # the commit made meanwhile counts
        self.assertEqual(since["files"][0]["additions"], 4)  # 3 changed lines + the appended one
        self.assertIn("bonjour {name}", "".join(l["text"] for h in since["files"][0]["hunks"] for l in h["lines"]))

    def test_branch_mode_needs_a_worktree_and_compares_to_the_target(self):
        d = self.s.create("Plain", "shell", self.repo)
        with self.assertRaises(ValueError):
            self.s.diff(d["id"], "branch")
        w = self.s.create("Feature", "shell", self.repo, worktree=True)
        with open(os.path.join(w["cwd"], "feature.py"), "w") as f:
            f.write("x = 1\n")
        git(w["cwd"], "add", ".")
        git(w["cwd"], "commit", "-q", "-m", "feature")
        files = self.s.diff(w["id"], "branch")["files"]
        self.assertEqual([(f["path"], f["status"]) for f in files], [("feature.py", "added")])

    def test_comments_are_sent_as_one_request_and_stay_visible(self):
        d = self.s.create("Agent", "shell", self.repo)
        self.s.store.add_comment(d["id"], "app.py", 2, "    return 'bonjour'", "Translate to English")
        self.s.store.add_comment(d["id"], "app.py", 4, "print(hello())", "Use logging, not print")
        self.s.send_review(d["id"])
        end = time.time() + 5
        while "Use logging" not in self.s.preview(d["id"]) and time.time() < end:
            time.sleep(0.1)
        screen = self.s.preview(d["id"]).replace("\n", "")
        self.assertIn("1. app.py:2 — Translate to English", screen)
        self.assertIn("2. app.py:4 — Use logging", screen)
        self.assertEqual({c["status"] for c in self.s.store.comments(d["id"])}, {"sent"})
        with self.assertRaises(ValueError):                                       # nothing open left to send
            self.s.send_review(d["id"])

    def test_parse_handles_renames_deletions_and_binary(self):
        text = ("diff --git a/old.txt b/new.txt\nsimilarity index 90%\nrename from old.txt\nrename to new.txt\n"
                "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n"
                "@@ -1 +0,0 @@\n-bye\n"
                "diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n")
        files = review.parse(text)
        self.assertEqual([(f["path"], f["status"]) for f in files], [("new.txt", "renamed"), ("gone.txt", "deleted"), ("img.png", "modified")])
        self.assertTrue(files[2]["binary"])
        self.assertEqual(files[1]["deletions"], 1)


if __name__ == "__main__":
    unittest.main()
