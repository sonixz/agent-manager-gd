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

    def mcp(self, calls, me=None):
        env = {**os.environ, "AGMGD_SESSION": self.parent["id"] if me is None else me, "AGMGD_HOME": self.tmp,
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

    def test_an_outside_tool_looks_and_starts_but_never_types(self):
        listed, started = self.mcp([("list_sessions", {}), ("start_session", {"name": "From outside", "tool": "shell", "cwd": self.tmp})], me="")
        self.assertEqual(listed["me"], "")
        self.assertEqual(started["parent"], "")
        sent_other, sent_own = self.mcp([("send_to_session", {"id": self.other["id"], "text": "ls"}),
                                         ("send_to_session", {"id": started["id"], "text": "ls"})], me="")
        self.assertIn("error", sent_other)
        self.assertIn("error", sent_own)

    def test_the_orchestrator_asks_the_owner_finishes_children_and_is_capped(self):
        orch = self.s.create("Orchestrator", "shell", self.tmp, role="orchestrator")
        me = orch["id"]
        repos, asked, child = self.mcp([("list_repos", {}), ("ask_owner", {"question": "Plan: 2 tasks. OK?", "options": ["Yes", "No"]}),
                                        ("start_session", {"name": "Task 1", "tool": "shell", "level": "full"})], me=me)
        self.assertEqual(repos, {"repos": []})
        self.assertTrue(asked["asked"])
        d = self.s.get(me)
        self.assertEqual((d["activity"], d["message"]), ("waiting", "Plan: 2 tasks. OK?  [Yes / No]"))
        self.s.send(me, "Yes")                                                    # the owner's answer clears it
        self.assertNotEqual(self.s.get(me)["activity"], "waiting")
        self.assertEqual(child["level"], "auto")                                  # never above its parent
        (done,) = self.mcp([("finish_session", {"id": child["id"], "note": "tests pass"})], me=me)
        self.assertTrue(done["ok"])
        self.assertIn("ready for your review: tests pass", self.s.get(child["id"])["message"])
        # pushing and merging are the owner's, for the orchestrator and every session under it
        with open(self.s.command_for({**self.s.store.get(child["id"]), "tool": "claude"})[2]) as f:
            self.assertIn("Bash(git push *)", json.load(f)["permissions"]["deny"])
        # the orchestrator's own tools are refused to other agents
        (refused,) = self.mcp([("ask_owner", {"question": "x"})])
        self.assertIn("orchestrator only", refused["error"])
        # caps: not deeper than two levels, not more than four running under one root
        grandchild = self.s.create("Helper", "shell", self.tmp, parent=child["id"])
        with self.assertRaises(ValueError):
            self.s.create("Too deep", "shell", self.tmp, parent=grandchild["id"])
        self.s.create("Task 2", "shell", self.tmp, parent=me)
        self.s.create("Task 3", "shell", self.tmp, parent=me)
        with self.assertRaises(ValueError):                                       # 4 already run under the orchestrator
            self.s.create("Task 4", "shell", self.tmp, parent=me)
        self.assertEqual(len(self.s.stop_orchestrator()), 5)                      # itself and the 4 under it

    def test_routing_rules_plan_and_daily_budget(self):
        orch = self.s.create("Orchestrator", "shell", self.tmp, role="orchestrator")
        rules, plan, task, used = self.mcp([
            ("routing_rules", {}),
            ("set_plan", {"goal": "Gift cards", "tasks": [{"title": "Gift cards at checkout", "repo": "acme", "tool": "claude", "model": "opus", "why": "a hard bug"},
                                                          {"title": "Review", "tool": "codex"}]}),
            ("update_task", {"id": "t1", "status": "running", "session": "abc123"}),
            ("usage", {})], me=orch["id"])
        self.assertEqual(rules["rules"][0]["model"], "opus")                          # the default rules
        self.assertEqual([t["id"] for t in plan["tasks"]], ["t1", "t2"])
        self.assertEqual((task["status"], task["session"]), ("running", "abc123"))
        self.assertEqual(used, {"daily_tokens": 0, "used_today": 0})
        self.s.orchestra.set_rules([{"when": "everything", "tool": "codex", "model": "gpt-5"}])
        self.assertEqual(self.s.orchestra.rules(), [{"when": "everything", "tool": "codex", "model": "gpt-5"}])
        # the budget: once spent, the orchestrator's sessions cannot start
        self.s.orchestra.set_budget(1000)
        self.s.orchestrated_tokens_today = lambda: 1200
        with self.assertRaises(ValueError) as e:
            self.s.create("One more", "shell", self.tmp, parent=orch["id"])
        self.assertIn("budget", str(e.exception))
        self.s.create("Not under it", "shell", self.tmp, parent=self.parent["id"])  # other agents are not concerned

    def test_every_agent_session_is_offered_the_server(self):
        cmd = self.s.command_for({"id": "x1", "tool": "claude", "name": "x"})
        with open(cmd[cmd.index("--mcp-config") + 1]) as f:
            servers = json.load(f)["mcpServers"]
        self.assertEqual(servers["agent-manager"]["args"], [AGENTS_MCP])


if __name__ == "__main__":
    unittest.main()
