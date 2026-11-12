"""Loop 9: connected repositories, one deploy key each, used by the sessions that work on them."""
import os
import time
import sqlite3
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

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



@unittest.skipUnless(shutil.which("ssh-keygen") and shutil.which("git"), "ssh-keygen and git are needed")
class HostsAndListTest(unittest.TestCase):
    """The hosts (GitHub, Azure DevOps), the key each one takes, and the list that runs no git command."""

    def setUp(self):
        from engine.repos import Repos
        self.tmp = tempfile.mkdtemp(prefix="agmgd-repo2-")
        os.environ["AGMGD_ALLOW_FILE_REPOS"] = "1"
        self.repos = Repos(os.path.join(self.tmp, "s.sqlite3"), self.tmp)
        self.work = os.path.join(self.tmp, "shop")
        os.makedirs(self.work)
        git(self.work, "init", "-q", "-b", "main")
        with open(os.path.join(self.work, "README.md"), "w") as f:
            f.write("# Shop\n")
        git(self.work, "add", ".")
        git(self.work, "commit", "-q", "-m", "start")
        self.bare = os.path.join(self.tmp, "shop.git")
        subprocess.run(["git", "clone", "-q", "--bare", self.work, self.bare], check=True)
        git(self.work, "remote", "add", "origin", "file://" + self.bare)
        git(self.work, "fetch", "-q", "origin")
        git(self.work, "branch", "-q", "--set-upstream-to=origin/main", "main")

    def tearDown(self):
        os.environ.pop("AGMGD_ALLOW_FILE_REPOS", None)
        if self.repos._pool:
            self.repos._pool.shutdown(wait=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def settle(self, sec=20.0):
        """Waits for what is read aside to be read."""
        end = time.time() + sec
        while time.time() < end:
            if not any(r["busy"] for r in self.repos.all()):
                return
            time.sleep(0.05)
        self.fail("the readings aside did not end")

    def test_azure_devops_addresses(self):
        from engine.repos import host_kind, parse_url
        self.assertEqual(parse_url("git@ssh.dev.azure.com:v3/fabrikam/FabrikamFiber/Shop"), ("ssh.dev.azure.com", "v3/fabrikam/FabrikamFiber/Shop"))
        self.assertEqual(parse_url("git@ssh.dev.azure.com:v3/fabrikam/My%20Project/My%20Repo")[1], "v3/fabrikam/My%20Project/My%20Repo")
        self.assertEqual(parse_url("ssh://git@ssh.dev.azure.com/v3/fabrikam/Proj/Repo")[0], "ssh.dev.azure.com")
        self.assertEqual(host_kind("vs-ssh.visualstudio.com"), "azure")
        self.assertEqual((host_kind("github.com"), host_kind("gitlab.com")), ("github", "other"))
        with self.assertRaises(ValueError) as e:   # an Azure address that is not « v3/organization/project/repository »
            parse_url("git@ssh.dev.azure.com:fabrikam/Shop")
        self.assertIn("git@ssh.dev.azure.com:v3/organization/project/repository", str(e.exception))

    def test_a_web_address_is_answered_with_its_ssh_form(self):
        from engine.repos import parse_url
        for web, ssh in [("https://github.com/acme/shop", "git@github.com:acme/shop.git"),
                         ("https://github.com/acme/shop.git", "git@github.com:acme/shop.git"),
                         ("https://dev.azure.com/fabrikam/Fiber/_git/Shop", "git@ssh.dev.azure.com:v3/fabrikam/Fiber/Shop"),
                         ("https://fabrikam@dev.azure.com/fabrikam/My%20Project/_git/Shop", "git@ssh.dev.azure.com:v3/fabrikam/My%20Project/Shop")]:
            with self.assertRaises(ValueError) as e:
                parse_url(web)
            self.assertIn("not https: " + ssh, str(e.exception), web)
        with self.assertRaises(ValueError) as e:   # a host whose shape is not known: both examples are given
            parse_url("https://git.example.org/acme/shop")
        self.assertIn("git@github.com:owner/repo.git", str(e.exception))
        self.assertIn("git@ssh.dev.azure.com:v3/", str(e.exception))

    def test_azure_devops_gets_an_rsa_key_and_is_told_it_opens_the_account(self):
        r = self.repos.add("git@ssh.dev.azure.com:v3/fabrikam/My%20Project/Client%20Portal")
        self.assertEqual(r["name"], "Client Portal")                       # the name is read as a person would
        self.assertEqual((r["host_kind"], r["key_type"], r["key_scope"]), ("azure", "rsa", "account"))
        self.assertTrue(r["public_key"].startswith("ssh-rsa "))           # the only kind Azure DevOps accepts
        key = self.repos.key_path(r["id"])
        self.assertTrue(key.endswith("id_rsa"))
        self.assertEqual(oct(os.stat(key).st_mode & 0o777), "0o600")
        self.assertIn("3072", subprocess.run(["ssh-keygen", "-lf", key + ".pub"], capture_output=True, text=True).stdout)
        self.assertEqual(r["key_page"], "https://dev.azure.com/fabrikam")  # no page per repository there
        self.assertEqual(r["deploy_keys_page"], "")
        self.assertIn(key, self.repos.ssh_command(r["id"]))
        again = self.repos.rotate(r["id"])
        self.assertTrue(again["public_key"].startswith("ssh-rsa "))       # a rotation keeps the kind the host takes
        self.assertNotEqual(again["fingerprint"], r["fingerprint"])
        self.assertIn("to your Azure DevOps profile", again["message"])
        self.assertNotEqual(again["key_made"], r["key_made"])              # a new date for the new key (not « later »: in WSL the wall clock steps back now and then)
        self.assertIn("Azure DevOps profile", self.repos.disconnect(r["id"])["reminder"])

    def test_github_keeps_its_key_per_repository(self):
        r = self.repos.add("git@github.com:acme/shop.git")
        self.assertEqual((r["host_kind"], r["key_type"], r["key_scope"]), ("github", "ed25519", "repository"))
        self.assertTrue(r["public_key"].startswith("ssh-ed25519 "))
        self.assertEqual(r["key_page"], "https://github.com/acme/shop/settings/keys/new")
        self.assertEqual(r["deploy_keys_page"], r["key_page"])
        self.assertAlmostEqual(r["key_made"], r["created"], delta=1.0)

    def test_why_an_azure_key_does_not_work_is_said_in_its_own_words(self):
        from engine import repos as mod
        r = self.repos.add("git@ssh.dev.azure.com:v3/fabrikam/Fiber/Shop")
        real = subprocess.run
        answers = iter(["remote: Public key authentication failed.\nfatal: Could not read from remote repository.",
                        "remote: Authentication failed: your SSH key has expired. To restore access, visit https://aka.ms/ado-ssh-public-key-expired for guidance.\nremote: Public key authentication failed.",
                        "remote: TF401019: The Git repository with name or identifier Shop does not exist or you do not have permissions."])

        def fake(argv, **kw):   # only the call to the host is answered here: Microsoft's own sentences, from its page
            if argv[:2] == ["git", "ls-remote"]:
                return subprocess.CompletedProcess(argv, 128, "", next(answers))
            return real(argv, **kw)

        with mock.patch.object(mod.subprocess, "run", fake):
            self.assertIn("User settings › SSH public keys", self.repos.check(r["id"])["message"])
            self.assertIn("expired on Azure DevOps: Rotate the key", self.repos.check(r["id"])["message"])
            self.assertIn("does not know this repository", self.repos.check(r["id"])["message"])
        self.assertEqual(self.repos.get(r["id"])["status"], "failed")

    def test_a_table_made_before_gains_its_columns(self):
        from engine.repos import Repos
        old = os.path.join(self.tmp, "old.sqlite3")
        db = sqlite3.connect(old)
        db.executescript("CREATE TABLE repos (id TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL UNIQUE, local_path TEXT NOT NULL DEFAULT '', "
                         "fingerprint TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'waiting', message TEXT NOT NULL DEFAULT '', "
                         "created REAL NOT NULL, checked_at REAL NOT NULL DEFAULT 0, last_used REAL NOT NULL DEFAULT 0);"
                         "INSERT INTO repos (id, name, url, created) VALUES ('aa', 'shop', 'git@github.com:acme/shop.git', 1700000000.0);")
        db.commit()
        db.close()
        r = Repos(old, self.tmp).all()[0]
        self.assertEqual((r["key_made"], r["key_type"], r["host_kind"]), (1700000000.0, "ed25519", "github"))
        self.assertEqual(Repos(old, self.tmp).all()[0]["key_made"], 1700000000.0)   # opened again: nothing is added twice

    def test_the_list_runs_no_git_and_the_folder_is_read_aside(self):
        r = self.repos.add("file://" + self.bare, self.work)
        self.repos._facts.clear()                       # as after the engine's start: nothing was read yet
        with mock.patch.object(self.repos, "_git", side_effect=AssertionError("the list ran git")):
            listed = self.repos.all()[0]
        self.assertEqual((listed["folder"]["read"], listed["folder"]["git"], listed["folder_at"], listed["busy"]), (False, True, 0.0, []))
        self.assertEqual(self.repos.refresh(), {"started": 1})
        self.settle()
        f = self.repos.all()[0]["folder"]
        self.assertEqual((f["read"], f["branch"], f["upstream"], f["ahead"], f["behind"], f["changed"], f["origin_state"]),
                         (True, "main", "origin/main", 0, 0, 0, "same"))
        self.assertEqual(self.repos.refresh(), {"started": 0})          # read a moment ago: not read again
        # one commit not pushed, one file changed, one new file
        with open(os.path.join(self.work, "a.txt"), "w") as fh:
            fh.write("a\n")
        git(self.work, "add", "a.txt")
        git(self.work, "commit", "-q", "-m", "a")
        with open(os.path.join(self.work, "README.md"), "a") as fh:
            fh.write("more\n")
        with open(os.path.join(self.work, "new.txt"), "w") as fh:
            fh.write("n\n")
        self.assertEqual(self.repos.refresh(folder_age=0.0), {"started": 1})
        self.settle()
        listed = self.repos.all()[0]
        self.assertEqual((listed["folder"]["ahead"], listed["folder"]["changed"]), (1, 2))
        self.assertGreater(listed["folder_at"], time.time() - 30)
        git(self.work, "checkout", "-q", "--detach")                     # no branch: said as none, not as a branch named so
        self.assertEqual(self.repos.get(r["id"])["folder"]["branch"], "")

    def test_a_folder_given_since_the_last_reading_is_read_at_once(self):
        r = self.repos.add("file://" + self.bare)                        # no folder yet: read as such a moment ago
        self.repos._set(r["id"], local_path=self.work)                   # as after the first clone
        self.assertFalse(self.repos.all()[0]["folder"]["read"])          # what was read is not shown for another folder
        self.assertEqual(self.repos.refresh(), {"started": 1})           # and it is not left for thirty seconds
        self.settle()
        self.assertEqual(self.repos.all()[0]["folder"]["branch"], "main")

    def test_a_folder_that_is_gone_is_said_and_nothing_breaks(self):
        r = self.repos.add("file://" + self.bare, self.work)
        shutil.rmtree(self.work)
        self.repos.refresh(folder_age=0.0)
        self.settle()
        f = self.repos.all()[0]["folder"]
        self.assertEqual((f["read"], f["exists"], f["git"]), (True, False, False))
        self.assertEqual(self.repos.all()[0]["id"], r["id"])

    def test_keys_are_checked_again_only_when_asked_and_only_those_checked_once(self):
        ok = self.repos.add("file://" + self.bare, self.work)
        waiting = self.repos.add("git@github.com:acme/never-added.git")
        self.assertEqual(self.repos.check(ok["id"])["status"], "connected")
        self.settle()
        first = self.repos.get(ok["id"])["checked_at"]
        self.repos.refresh(folder_age=1e9)                               # not asked for the keys: none is checked
        self.settle()
        self.assertEqual(self.repos.get(ok["id"])["checked_at"], first)
        self.repos.refresh(keys=True, folder_age=1e9)                    # asked, but checked a moment ago
        self.settle()
        self.assertEqual(self.repos.get(ok["id"])["checked_at"], first)
        # « older than minus one second »: every key counts as old, whatever the wall clock does meanwhile (in WSL it
        # is set back by small steps now and then)
        self.assertEqual(self.repos.refresh(keys=True, key_age=-1.0, folder_age=1e9), {"started": 1})   # the waiting one is left alone
        self.settle()
        self.assertNotEqual(self.repos.get(ok["id"])["checked_at"], first)
        self.assertEqual((self.repos.get(waiting["id"])["status"], self.repos.get(waiting["id"])["checked_at"]), ("waiting", 0.0))

    def test_a_reading_that_fails_does_not_stop_the_others(self):
        a = self.repos.add("file://" + self.bare, self.work)
        b = self.repos.add("git@github.com:acme/other.git")
        real = self.repos.get

        def get(rid):
            if rid == b["id"]:
                raise OSError("disk went away")
            return real(rid)

        self.repos._facts.clear()
        with mock.patch.object(self.repos, "get", get):
            self.assertEqual(self.repos.refresh(), {"started": 2})
            end = time.time() + 20
            while time.time() < end and any(f["busy"] for f in self.repos._facts.values()):
                time.sleep(0.05)
        by = {r["id"]: r for r in self.repos.all()}
        self.assertTrue(by[a["id"]]["folder"]["read"])
        self.assertEqual((by[b["id"]]["folder"]["read"], by[b["id"]]["busy"]), (False, []))


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
