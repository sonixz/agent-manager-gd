"""Loop 6: every agent session gets its own Second Brain key. A fake Brain (HTTP) records the calls."""
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from engine.brain import Brain
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux
from tests.python.test_history import FAKE

APP_TOKEN = "app-token-never-shown"
CLIENT_TOKEN = "sbmcp_secret_never_shown"


class FakeBrain(BaseHTTPRequestHandler):
    calls = []
    n = 0

    def log_message(self, *a):
        pass

    def _reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._reply({"status": "ok", "version": "test"})

    def do_POST(self):
        assert self.headers.get("Authorization") == "Bearer " + APP_TOKEN
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        FakeBrain.n += 1
        FakeBrain.calls.append(("POST", self.path, body))
        self._reply({"id": f"c{FakeBrain.n:03d}", "token": CLIENT_TOKEN, "level": body.get("level")})

    def do_DELETE(self):
        FakeBrain.calls.append(("DELETE", self.path, None))
        self._reply({"revoked": self.path.rsplit("/", 1)[-1]})


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class BrainTest(unittest.TestCase):
    def setUp(self):
        FakeBrain.calls, FakeBrain.n = [], 0
        self.tmp = tempfile.mkdtemp(prefix="agmgd-brain-")
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeBrain)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        bhome = os.path.join(self.tmp, "SecondBrainGD")
        os.makedirs(os.path.join(bhome, "runtime"))
        with open(os.path.join(bhome, "runtime", "server.json"), "w") as f:
            json.dump({"port": self.srv.server_address[1]}, f)
        with open(os.path.join(bhome, "runtime", "api_token"), "w") as f:
            f.write(APP_TOKEN)
        with open(os.path.join(bhome, "install_state.json"), "w") as f:
            json.dump({"venv_python": sys.executable}, f)
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        for tool in ("claude", "codex"):
            with open(os.path.join(bin_dir, tool), "w") as f:
                f.write(FAKE)
            os.chmod(os.path.join(bin_dir, tool), 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = bin_dir + os.pathsep + self.old_path
        self.brain = Brain(home=bhome, repo="/opt/second-brain-gd")
        self.tmux = Tmux("agmgd-brain", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp, self.brain)

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        self.tmux.kill_server()
        self.srv.shutdown()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def screen(self, sid, needle):
        end = time.time() + 5
        while time.time() < end:
            text = self.s.preview(sid)
            if needle in text:
                return text
            time.sleep(0.1)
        self.fail(f"{needle!r} not on screen")

    def test_each_agent_session_gets_its_own_key_and_the_relay(self):
        d = self.s.create("Brain themes", "claude", self.tmp)
        self.assertTrue(d["brain"])
        self.assertEqual(FakeBrain.calls[0], ("POST", "/mcp/clients", {"name": "Agent Manager · Brain themes", "level": "propose_items"}))
        self.screen(d["id"], "--mcp-config")
        with open(os.path.join(self.tmp, "sessions", d["id"], "mcp.json")) as f:
            server = json.load(f)["mcpServers"]["second-brain"]
        self.assertEqual(server["command"], sys.executable)
        self.assertEqual(server["args"], ["/opt/second-brain-gd/engine/mcp/relay.py", "--client", "c001"])
        # the key itself is never written anywhere by the engine: the Brain's relay reads it from the Brain's folder
        for root, _, files in os.walk(self.tmp):
            for name in files:
                if name.endswith((".json", ".sqlite3")):
                    with open(os.path.join(root, name), "rb") as f:
                        self.assertNotIn(CLIENT_TOKEN.encode(), f.read(), name)

    def test_codex_gets_the_brain_through_config_overrides(self):
        d = self.s.create("Codex work", "codex", self.tmp)
        text = self.screen(d["id"], "mcp_servers.second-brain.args=")
        self.assertIn("--client", text)

    def test_a_fork_gets_a_key_of_its_own_and_removing_revokes(self):
        d = self.s.create("Tree", "claude", self.tmp)
        f = self.s.fork(d["id"], "Tree, other idea")
        self.assertEqual([c[2]["name"] for c in FakeBrain.calls if c[0] == "POST"],
                         ["Agent Manager · Tree", "Agent Manager · Tree, other idea"])
        self.s.remove(f["id"])
        self.assertIn(("DELETE", "/mcp/clients/c002", None), FakeBrain.calls)

    def note(self, cmd):
        return cmd[cmd.index("--append-system-prompt") + 1] if "--append-system-prompt" in cmd else ""

    def test_a_session_asked_to_document_itself_gets_the_brain_directive(self):
        d = self.s.create("Docs", "claude", self.tmp, document=True)
        self.assertTrue(d["brain_document"])
        rec = self.s.store.get(d["id"])
        note = self.note(self.s.command_for(rec))
        self.assertIn("document this session in their Second Brain", note)
        self.assertIn("Orient first", note)                                  # read where the project stands first
        self.assertIn("git log", note)                                       # check the Brain against the repository
        self.assertIn("list_sessions", note)                                 # what the other agents are doing
        self.assertIn("propose_item", note)                                  # always through the archivist
        self.assertIn("« Session journal · Docs »", note)
        self.assertIn(f"« {os.path.basename(self.tmp)} »", note)             # the project: the folder's name here
        self.assertIn("Never put source code, secrets, keys or tokens", note)
        self.assertIn("document this session", self.note(self.s.command_for(rec, "resume", "abc")))   # a restart keeps it
        f = self.s.fork(d["id"], "Docs, other idea")                         # a fork keeps documenting, own key
        self.assertTrue(f["brain_document"])
        self.screen(d["id"], "Orient first")                                 # really passed at launch

    def test_the_directive_needs_the_option_the_brain_and_claude_code(self):
        plain = self.s.create("Plain", "claude", self.tmp)
        self.assertFalse(plain["brain_document"])
        self.assertNotIn("document this session", self.note(self.s.command_for(self.s.store.get(plain["id"]))))
        alone = self.s.create("Alone docs", "claude", self.tmp, brain=False, document=True)
        self.assertFalse(alone["brain_document"])                            # no Brain shared: nothing to document into
        self.assertNotIn("document this session", self.note(self.s.command_for(self.s.store.get(alone["id"]))))
        codex = self.s.create("Codex docs", "codex", self.tmp, document=True)
        self.assertFalse(codex["brain_document"])                            # Codex gets no instructions yet

    def test_shells_and_sessions_without_the_brain_get_no_key(self):
        self.s.create("Shell", "shell", self.tmp)
        d = self.s.create("Alone", "claude", self.tmp, brain=False)
        self.assertEqual(FakeBrain.calls, [])
        self.assertFalse(d["brain"])


if __name__ == "__main__":
    unittest.main()
