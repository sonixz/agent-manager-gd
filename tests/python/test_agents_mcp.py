"""Loop 6C: an agent pilots its own child sessions through Agent Manager's MCP server (engine/mcp_agents.py)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

from engine.api import load_token, serve
from engine.sessions import AGENTS_MCP, Sessions
from engine.store import Store
from engine.tmux import Tmux


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class AgentsMcpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-amcp-")
        self.tmux = Tmux("agmgd-amcp", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)
        self.srv = serve(self.s, load_token(self.tmp), 0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.parent = self.s.create("Lead", "shell", self.tmp)
        self.other = self.s.create("Someone else", "shell", self.tmp)

    def tearDown(self):
        self.srv.shutdown()
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def mcp(self, calls):
        env = {**os.environ, "AGMGD_SESSION": self.parent["id"], "AGMGD_HOME": self.tmp,
               "AGMGD_PORT": str(self.srv.server_address[1])}
        msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"}]
        msgs += [{"jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": {"name": n, "arguments": a}}
                 for i, (n, a) in enumerate(calls)]
        out = subprocess.run([sys.executable, AGENTS_MCP], input="\n".join(json.dumps(m) for m in msgs) + "\n",
                             capture_output=True, text=True, env=env, timeout=120)
        replies = {r["id"]: r for r in map(json.loads, out.stdout.splitlines())}
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "agent-manager")
        return [json.loads(replies[i + 1]["result"]["content"][0]["text"]) for i in range(len(calls))]

    def test_an_agent_starts_a_child_writes_to_it_and_reads_the_result(self):
        listed, child = self.mcp([("list_sessions", {}), ("start_session", {"name": "Helper", "tool": "shell"})])
        self.assertEqual(listed["me"], self.parent["id"])
        self.assertEqual(child["parent"], self.parent["id"])
        self.assertEqual(child["cwd"], self.parent["cwd"])             # the parent's folder by default
        sent, waited = self.mcp([("send_to_session", {"id": child["id"], "text": "echo déjà-fini"}),
                                 ("wait_for_session", {"id": child["id"], "timeout_s": 20})])
        self.assertEqual(sent, {"ok": True})
        self.assertFalse(waited["timed_out"])
        self.assertIn("déjà-fini", waited["screen"])

    def test_an_agent_cannot_write_to_a_session_it_did_not_start(self):
        (refused,) = self.mcp([("send_to_session", {"id": self.other["id"], "text": "rm -rf ~"})])
        self.assertIn("only write to sessions you started", refused["error"])

    def test_every_agent_session_is_offered_the_server(self):
        cmd = self.s.command_for({"id": "x1", "tool": "claude", "name": "x"})
        with open(cmd[cmd.index("--mcp-config") + 1]) as f:
            servers = json.load(f)["mcpServers"]
        self.assertEqual(servers["agent-manager"]["args"], [AGENTS_MCP])


if __name__ == "__main__":
    unittest.main()
