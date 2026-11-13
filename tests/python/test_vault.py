"""Loop 39: the secrets vault. Named secrets, encrypted where Windows can, never returned, a journal without values."""
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

from engine.vault import Vault


class VaultTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-vault-")
        self.v = Vault(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_secret_is_kept_encrypted_where_windows_can_and_never_shown(self):
        info = self.v.set("ELEVENLABS_API_KEY", "el-SECRET-é", "voices for the trailer")
        path = os.path.join(self.tmp, "keys", "secrets", "ELEVENLABS_API_KEY.json")
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")
        self.assertEqual(oct(os.stat(os.path.dirname(path)).st_mode & 0o777), "0o700")
        if self.v.keys.dpapi:
            self.assertNotIn("SECRET", open(path).read())
            self.assertEqual(info["protection"], "dpapi")
        self.assertEqual(self.v.get("ELEVENLABS_API_KEY"), "el-SECRET-é")
        everything = json.dumps(self.v.all())
        self.assertNotIn("SECRET", everything)                       # names, notes, dates: never a value
        self.assertIn("voices for the trailer", everything)
        self.assertNotIn("SECRET", open(self.v.journal_path).read())

    def test_a_new_value_keeps_its_first_date_and_note_and_the_journal_says_what_happened(self):
        first = self.v.set("GH_TOKEN", "one", "fine-grained, repo gd-project")
        again = self.v.set("GH_TOKEN", "two")
        self.assertEqual(again["added_at"], first["added_at"])
        self.assertEqual(again["note"], "fine-grained, repo gd-project")
        self.assertEqual(self.v.get("GH_TOKEN"), "two")
        self.v.log("GH_TOKEN", "given", "ab12cd34", "site")
        d = self.v.describe("GH_TOKEN")
        self.assertEqual((d["given_count"], d["given_to"]), (1, ["site"]))
        self.v.delete("GH_TOKEN")
        self.assertEqual(self.v.get("GH_TOKEN"), "")
        self.assertEqual([e["event"] for e in self.v.journal("GH_TOKEN")], ["deleted", "given", "changed", "added"])
        self.assertEqual(self.v.names(), [])

    def test_names_and_values_that_would_change_how_programs_run_are_refused(self):
        for bad in ["lower", "A", "PATH", "LD_PRELOAD", "AGMGD_PORT", "GIT_SSH_COMMAND", "../X", "X-Y", ""]:
            with self.assertRaises(ValueError, msg=bad):
                self.v.set(bad, "x")
        with self.assertRaises(ValueError):
            self.v.set("EMPTY_ONE", "  \n")
        with self.assertRaises(ValueError):
            self.v.set("TOO_LONG", "x" * 20000)
        self.v.set("A_PEM_KEY", "-----BEGIN-----\nabc\n-----END-----\n")   # a value on several lines is fine
        self.assertEqual(self.v.get("A_PEM_KEY"), "-----BEGIN-----\nabc\n-----END-----")


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class VaultApiTest(unittest.TestCase):
    def setUp(self):
        from engine.api import load_token, serve
        from engine.sessions import Sessions
        from engine.store import Store
        from engine.tmux import Tmux
        self.tmp = tempfile.mkdtemp(prefix="agmgd-vault-api-")
        os.environ["AGMGD_KEYS_PLAIN"] = "1"
        self.tmux = Tmux("agmgd-test-vault", tmpdir=self.tmp)
        self.sessions = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)
        self.token = load_token(self.tmp)
        self.srv = serve(self.sessions, self.token, 0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.tmux.kill_server()
        os.environ.pop("AGMGD_KEYS_PLAIN", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def call(self, method, path, body=None):
        req = urllib.request.Request(f"http://127.0.0.1:{self.srv.server_address[1]}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_a_value_goes_in_and_never_comes_out(self):
        code, got = self.call("POST", "/secrets", {"name": "ELEVENLABS_API_KEY", "value": "el-SECRET", "note": "voices"})
        self.assertEqual(code, 200)
        self.assertNotIn("SECRET", json.dumps(got))
        code, listed = self.call("GET", "/secrets")
        self.assertEqual([s["name"] for s in listed["secrets"]], ["ELEVENLABS_API_KEY"])
        self.assertNotIn("SECRET", json.dumps(listed))
        self.assertEqual(self.call("POST", "/secrets/ELEVENLABS_API_KEY/note", {"note": "the trailer's voices"})[1]["note"], "the trailer's voices")
        self.assertEqual(self.call("POST", "/secrets", {"name": "PATH", "value": "x"})[0], 400)
        self.assertEqual(self.call("POST", "/secrets/NOPE_NOPE/note", {"note": "x"})[0], 404)
        self.assertEqual(self.call("DELETE", "/secrets/ELEVENLABS_API_KEY")[0], 200)
        self.assertEqual(self.call("GET", "/secrets")[1]["secrets"], [])


if __name__ == "__main__":
    unittest.main()
