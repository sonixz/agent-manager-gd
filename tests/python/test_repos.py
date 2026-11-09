"""Loop 9: connected repositories, one deploy key each, used by the sessions that work on them."""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

from engine.repos import parse_url
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux


def git(cwd, *a):
    return subprocess.run(["git", "-C", cwd, "-c", "user.name=t", "-c", "user.email=t@t", *a], check=True,
                          capture_output=True, text=True).stdout


@unittest.skipUnless(shutil.which("tmux") and shutil.which("ssh-keygen"), "tmux and ssh-keygen are needed")
class ReposTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-repo-")
        os.environ["AGMGD_ALLOW_FILE_REPOS"] = "1"
        self.tmux = Tmux("agmgd-repo", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)
        # a "remote" repository (a local bare one, reached through file:// in tests)
        work = os.path.join(self.tmp, "seed")
        os.makedirs(work)
        git(work, "init", "-q", "-b", "main")
        with open(os.path.join(work, "README.md"), "w") as f:
            f.write("# Shop\n")
        git(work, "add", ".")
        git(work, "commit", "-q", "-m", "start")
        self.bare = os.path.join(self.tmp, "shop.git")
        subprocess.run(["git", "clone", "-q", "--bare", work, self.bare], check=True)

    def tearDown(self):
        os.environ.pop("AGMGD_ALLOW_FILE_REPOS", None)
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_addresses(self):
        self.assertEqual(parse_url("git@github.com:sonixz/second-brain-gd.git"), ("github.com", "sonixz/second-brain-gd"))
        self.assertEqual(parse_url("ssh://git@gitlab.com/team/app.git"), ("gitlab.com", "team/app"))
        with self.assertRaises(ValueError):
            parse_url("https://github.com/sonixz/x.git")   # deploy keys work over SSH

    def test_a_repository_gets_its_own_key_and_a_link_to_add_it(self):
        r = self.s.repos.add("git@github.com:sonixz/demo-shop.git")
        key = self.s.repos.key_path(r["id"])
        self.assertEqual(stat.S_IMODE(os.stat(key).st_mode), 0o600)
        self.assertTrue(r["public_key"].startswith("ssh-ed25519 "))
        self.assertTrue(r["fingerprint"].startswith("SHA256:"))
        self.assertEqual(r["deploy_keys_page"], "https://github.com/sonixz/demo-shop/settings/keys/new")
        self.assertEqual(r["status"], "waiting")
        with open(key) as f:
            private = f.read()
        with open(os.path.join(self.tmp, "s.sqlite3"), "rb") as f:
            self.assertNotIn(private.encode(), f.read())             # the private key is never in the database
        with self.assertRaises(ValueError):
            self.s.repos.add("git@github.com:sonixz/demo-shop.git")  # already connected

    def test_check_explains_a_key_that_does_not_work(self):
        r = self.s.repos.add("git@nowhere.invalid:me/nothing.git")
        c = self.s.repos.check(r["id"])
        self.assertEqual(c["status"], "failed")
        self.assertTrue(c["message"])

    def test_an_agent_works_on_a_connected_repository_with_its_key(self):
        r = self.s.repos.add("file://" + self.bare)
        self.assertEqual(self.s.repos.check(r["id"])["status"], "connected")
        d = self.s.create("Shop agent", "shell", "", repo=r["id"])
        self.assertEqual(d["cwd"], os.path.join(self.tmp, "repos", "shop"))     # cloned on first use
        self.assertTrue(os.path.isfile(os.path.join(d["cwd"], "README.md")))
        self.assertEqual(d["repo_name"], "shop")
        env = self.tmux.run("show-environment", "-t", d["tmux"], "GIT_SSH_COMMAND")
        self.assertIn(self.s.repos.key_path(r["id"]), env)                       # git uses this repository's key
        self.assertIn("IdentitiesOnly=yes", env)
        w = self.s.create("Shop feature", "shell", "", repo=r["id"], worktree=True)
        self.assertTrue(w["cwd"].endswith("shop-worktrees/shop-feature"))
        self.assertEqual({x["name"] for x in self.s.repo_sessions(r["id"])}, {"Shop agent", "Shop feature"})

    def test_rotate_and_disconnect(self):
        r = self.s.repos.add("git@github.com:sonixz/demo-shop.git")
        new = self.s.repos.rotate(r["id"])
        self.assertNotEqual(new["fingerprint"], r["fingerprint"])
        self.assertIn(r["fingerprint"], new["message"])                          # reminds to delete the old one
        out = self.s.repos.disconnect(r["id"])
        self.assertFalse(os.path.exists(os.path.dirname(self.s.repos.key_path(r["id"]))))
        self.assertIn(new["fingerprint"], out["reminder"])


if __name__ == "__main__":
    unittest.main()


@unittest.skipUnless(shutil.which("tmux") and shutil.which("ssh-keygen"), "tmux and ssh-keygen are needed")
class OwnFolderTest(ReposTest):
    """Loop 16d: the owner's own clone instead of a second copy in Agent Manager's folder."""

    def own_repo(self, name="mine", origin=None):
        path = os.path.join(self.tmp, name)
        os.makedirs(path)
        git(path, "init", "-q", "-b", "main")
        with open(os.path.join(path, "index.html"), "w") as f:
            f.write("<h1>site</h1>\n")
        git(path, "add", ".")
        git(path, "commit", "-q", "-m", "site")
        if origin:
            git(path, "remote", "add", "origin", origin)
        return path

    def test_the_owners_folder_without_origin_gets_it_on_request(self):
        mine = self.own_repo()
        r = self.s.repos.add("file://" + self.bare, local_path=mine)
        self.assertEqual(r["local_path"], mine)
        self.assertEqual(r["folder"]["origin_state"], "missing")
        self.assertFalse(r["folder"]["managed"])
        r = self.s.repos.set_origin(r["id"])
        self.assertEqual(r["folder"]["origin_state"], "same")
        self.assertEqual(self.s.repos.ensure_clone(r["id"]), mine)            # no second copy
        self.assertNotIn("core.sshcommand", git(mine, "config", "--list").lower())   # the key never goes into the repo

    def test_a_session_on_a_connected_repository_is_told_how_git_authenticates(self):
        mine = self.own_repo()
        r = self.s.repos.add("file://" + self.bare, local_path=mine)
        rec = self.s.store.add("Work", "claude", mine, repo_id=r["id"])
        cmd = self.s.command_for(rec)
        note = cmd[cmd.index("--append-system-prompt") + 1]
        self.assertIn("GIT_SSH_COMMAND", note)
        self.assertIn("Never create SSH keys", note)
        self.assertIn("git ls-remote origin", note)                                     # the right way to check
        self.assertIn("--append-system-prompt", self.s.command_for(rec, "resume", "abc"))    # a restart keeps it
        plain = self.s.store.add("Plain", "claude", mine)
        self.assertNotIn("--append-system-prompt", self.s.command_for(plain))
        self.assertFalse(os.path.exists(os.path.join(mine, "CLAUDE.md")))                # nothing written in the repo

    def test_a_session_opened_by_folder_still_gets_the_repository_key(self):
        mine = self.own_repo()
        r = self.s.repos.add("file://" + self.bare, local_path=mine)
        os.makedirs(os.path.join(mine, "docs"))
        for folder in (mine, os.path.join(mine, "docs")):
            d = self.s.create("By folder", "shell", folder)                 # no « repo » given, only the folder
            self.assertEqual(self.s.store.get(d["id"])["repo_id"], r["id"])
            self.assertIn("GIT_SSH_COMMAND", self.s.session_env(d["id"]))
        wt = os.path.join(self.tmp, "mine-wt")
        git(mine, "worktree", "add", "-q", "-b", "am/x", wt)
        self.assertEqual(self.s.repos.owner_of(wt), r["id"])                  # a worktree of it too
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.makedirs(elsewhere)
        self.assertEqual(self.s.store.get(self.s.create("Other", "shell", elsewhere)["id"])["repo_id"], "")

    def test_another_origin_is_never_changed(self):
        mine = self.own_repo(origin="git@github.com:someone/else.git")
        r = self.s.repos.add("file://" + self.bare, local_path=mine)
        self.assertEqual(r["folder"]["origin_state"], "other")
        with self.assertRaises(ValueError):
            self.s.repos.set_origin(r["id"])
        self.assertIn("someone/else", git(mine, "remote", "get-url", "origin"))

    def test_a_subfolder_or_a_full_non_git_folder_is_refused(self):
        mine = self.own_repo()
        os.makedirs(os.path.join(mine, "docs"))
        with open(os.path.join(mine, "docs", "a.md"), "w") as f:
            f.write("x")
        with self.assertRaises(ValueError) as e:
            self.s.repos.add("file://" + self.bare, local_path=os.path.join(mine, "docs"))
        self.assertIn("top folder", str(e.exception))

    def test_switching_to_the_owners_folder_offers_to_remove_the_copy(self):
        r = self.s.repos.add("file://" + self.bare)
        copy = self.s.repos.ensure_clone(r["id"])                            # Agent Manager's own clone
        self.assertTrue(self.s.repos.get(r["id"])["folder"]["managed"])
        mine = self.own_repo(origin="file://" + self.bare)
        out = self.s.repos.set_folder(r["id"], mine)
        self.assertEqual(out["local_path"], mine)
        self.assertEqual(out["previous_copy"], copy)
        self.assertTrue(self.s.repos.inspect_copy(copy)["clean"])
        with open(os.path.join(copy, "work.txt"), "w") as f:
            f.write("not committed")
        self.assertFalse(self.s.repos.inspect_copy(copy)["clean"])            # shown before the owner confirms
        with self.assertRaises(ValueError):
            self.s.repos.remove_copy(copy, False)
        with self.assertRaises(ValueError):
            self.s.repos.remove_copy(mine, True)                              # never the owner's own folder
        self.assertEqual(self.s.repos.remove_copy(copy, True), {"removed": copy})
        self.assertFalse(os.path.exists(copy))
