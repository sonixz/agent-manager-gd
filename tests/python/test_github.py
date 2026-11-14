"""Loop 42: GitHub's CLI under Repos, against a stand-in gh (tests/python/standins/gh). No token exists here."""
import json
import os
import shutil
import tempfile
import unittest

from engine.gh import GitHub, parse_status
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux

STANDIN = os.path.join(os.path.dirname(__file__), "standins", "gh")


class StatusTextTest(unittest.TestCase):
    def test_the_status_says_who_where_and_scopes_never_the_token(self):
        text = ("github.com\n  ✓ Logged in to github.com account sonixz (/home/dev/.config/gh/hosts.yml)\n"
                "  - Active account: true\n  - Git operations protocol: ssh\n  - Token: gho_****\n"
                "  - Token scopes: 'gist', 'read:org', 'repo'\n")
        st = parse_status(text)
        self.assertEqual((st["logged_in"], st["account"], st["storage"], st["protocol"]), (True, "sonixz", "file", "ssh"))
        self.assertEqual(st["scopes"], ["gist", "read:org", "repo"])
        self.assertNotIn("gho_", json.dumps(st))
        self.assertEqual(parse_status("  ✓ Logged in to github.com account a (keyring)")["storage"], "keyring")
        self.assertFalse(parse_status("You are not logged into any GitHub hosts.")["logged_in"])


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class GitHubTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-gh-")
        self.state = os.path.join(self.tmp, "gh.json")
        os.environ["GH_STANDIN"] = self.state
        os.environ["GH_TOKEN"] = "must-not-reach-gh"     # gh runs with the owner's own login, never a token from here
        self.tmux = Tmux("agmgd-gh-test", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp, None)
        self.s.github = GitHub(STANDIN)
        self.s.repos._check_key = lambda rid: self.s.repos._set(rid, status="connected", message="")

    def tearDown(self):
        os.environ.pop("GH_STANDIN", None)
        os.environ.pop("GH_TOKEN", None)
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, **st):
        json.dump(st, open(self.state, "w"))
        self.s.github.forget()

    def calls(self):
        return [json.loads(l) for l in open(self.state + ".calls")] if os.path.exists(self.state + ".calls") else []

    def test_not_installed_then_not_logged_in_then_logged_in_with_a_plain_file(self):
        self.assertFalse(GitHub(os.path.join(self.tmp, "nothing")).status()["installed"])
        self.write(logged_in=False)
        st = self.s.github.status()
        self.assertEqual((st["installed"], st["version"], st["logged_in"]), (True, "2.45.0", False))
        self.write(logged_in=True, account="dev", where="/home/dev/.config/gh/hosts.yml", scopes=["repo", "read:org"])
        st = self.s.github.status()
        self.assertEqual((st["account"], st["storage"], st["can_add_keys"], st["can_create"]), ("dev", "file", True, True))
        self.assertIn("plain file", st["note"])                          # said, so the owner can choose the keyring
        self.assertFalse(any(c["gh_token_seen"] for c in self.calls()))
        self.write(logged_in=True, scopes=["read:org"])
        self.assertFalse(self.s.github.status()["can_add_keys"])          # a token that cannot add keys says so

    def test_a_deploy_key_in_one_click_with_write_access_read_back_from_github(self):
        self.write(logged_in=True, repos={"dev/shop": []})
        r = self.s.repos.add("git@github.com:dev/shop.git")
        self.assertEqual(self.s.github_key_state(r["id"])["found"], False)
        out = self.s.github_deploy_key(r["id"], write=True)
        self.assertEqual((out["deploy_key"]["found"], out["deploy_key"]["write"]), (True, True))
        self.assertEqual(out["repo"]["status"], "connected")
        add = next(c["args"] for c in self.calls() if c["args"][:3] == ["repo", "deploy-key", "add"])
        self.assertIn("--allow-write", add)
        self.assertTrue(add[3].endswith(".pub"))                          # the public key only, never the private one
        with self.assertRaises(ValueError):                                # gh adds keys on GitHub only
            self.s.github_deploy_key(self.s.repos.add("git@ssh.dev.azure.com:v3/o/p/r")["id"], True)

    def test_a_new_repository_is_private_unless_chosen_and_comes_connected(self):
        self.write(logged_in=True, account="dev", repos={})
        with self.assertRaises(ValueError):
            self.s.github_create("bad name!")
        out = self.s.github_create("blog")
        self.assertEqual(out["created"], {"owner_repo": "dev/blog", "url": "git@github.com:dev/blog.git", "visibility": "private"})
        st = json.load(open(self.state))
        self.assertEqual(st["visibility"]["dev/blog"], "private")
        self.assertEqual((out["deploy_key"]["found"], out["deploy_key"]["write"]), (True, True))
        self.assertEqual(out["repo"]["url"], "git@github.com:dev/blog.git")
        self.s.github_create("site", visibility="public")
        self.assertEqual(json.load(open(self.state))["visibility"]["dev/site"], "public")
        self.assertFalse(any("edit" in c["args"] or "--visibility" in c["args"] for c in self.calls()))   # never changes one

    def test_login_happens_in_a_terminal_the_owner_sees(self):
        self.write(logged_in=False)
        d = self.s.github_terminal("login")
        self.assertEqual((d["tool"], d["name"]), ("shell", "GitHub login"))
        import time
        time.sleep(0.8)
        self.assertIn("gh auth login --hostname github.com --web", self.tmux.capture(d["tmux"], 20))
        self.assertIn(STANDIN, self.tmux.capture(d["tmux"], 20))          # the stand-in: a test never logs in for real
        with self.assertRaises(ValueError):
            self.s.github_terminal("token")
