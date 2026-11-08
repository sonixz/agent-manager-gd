"""Loop 14: tokens per session from the agents' own logs (fake Claude Code and Codex logs)."""
import json
import os
import shutil
import tempfile
import unittest

from engine import usage
from engine.store import Store


class UsageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-usage-")
        self.claude = os.path.join(self.tmp, "claude", "-mnt-c-project")
        self.codex = os.path.join(self.tmp, "codex", "2026", "11", "08")
        os.makedirs(self.claude)
        os.makedirs(self.codex)
        os.environ["AGMGD_CLAUDE_DIR"] = os.path.join(self.tmp, "claude")
        os.environ["AGMGD_CODEX_DIR"] = os.path.join(self.tmp, "codex")
        usage._cache.clear()
        line = lambda mid, day, i, o, cw, cr: json.dumps({"type": "assistant", "timestamp": f"{day}T10:00:00Z", "message": {
            "id": mid, "model": "claude-x", "usage": {"input_tokens": i, "output_tokens": o, "cache_creation_input_tokens": cw, "cache_read_input_tokens": cr}}})
        with open(os.path.join(self.claude, "conv-1.jsonl"), "w") as f:
            f.write(line("m1", "2026-11-07", 10, 100, 1000, 5000) + "\n")
            f.write(line("m1", "2026-11-07", 10, 100, 1000, 5000) + "\n")   # the same message streamed twice: counted once
            f.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
            f.write(line("m2", "2026-11-08", 20, 200, 0, 6000) + "\n")
        with open(os.path.join(self.codex, "rollout-2026-11-08T09-00-00-th-9.jsonl"), "w") as f:
            f.write(json.dumps({"type": "session_meta", "payload": {"id": "th-9", "timestamp": "2026-11-08T09:00:00Z"}}) + "\n")
            f.write(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 300, "cached_input_tokens": 100, "output_tokens": 50}}}}) + "\n")
            f.write(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 900, "cached_input_tokens": 400, "output_tokens": 120}}}}) + "\n")
        self.store = Store(os.path.join(self.tmp, "s.sqlite3"))

    def tearDown(self):
        os.environ.pop("AGMGD_CLAUDE_DIR", None)
        os.environ.pop("AGMGD_CODEX_DIR", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_tokens_per_session_day_and_tool(self):
        a = self.store.add("Themes", "claude", self.tmp)
        b = self.store.add("Codex work", "codex", self.tmp)
        c = self.store.add("No log yet", "claude", self.tmp)
        self.store.add("Shell", "shell", self.tmp)
        self.store.touch_conversation(a["id"], "claude", "conv-1")
        self.store.touch_conversation(b["id"], "codex", "th-9")
        self.store.touch_conversation(c["id"], "claude", "conv-missing")
        r = usage.report(self.store.history())
        by = {s["name"]: s for s in r["sessions"]}
        self.assertEqual(by["Themes"]["tokens"], {"input": 30, "output": 300, "cache_write": 1000, "cache_read": 11000})
        self.assertEqual(by["Codex work"]["tokens"], {"input": 500, "output": 120, "cache_write": 0, "cache_read": 400})
        self.assertEqual((by["No log yet"]["total"], by["No log yet"]["logs_found"]), (0, 0))   # said, not guessed
        self.assertNotIn("Shell", by)
        self.assertEqual([d["day"] for d in r["days"]], ["2026-11-07", "2026-11-08"])
        self.assertEqual(r["tools"]["codex"], 1020)
        self.assertNotIn("usd", json.dumps(r).lower())                                             # no money invented


if __name__ == "__main__":
    unittest.main()
