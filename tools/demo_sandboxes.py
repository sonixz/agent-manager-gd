"""Captures only: fills a throw-away data folder with two demo sandboxes, a month of run history, a budget, and the
file the engine's demo Fly reads (AGMGD_DEMO_FLY). Nothing reaches Fly.io.
  python3 tools/demo_sandboxes.py <data folder> <session id running> <session id paused> [<added session id>…]
  -> prints the demo file path. Added sessions (Loop 40) go on the running sandbox, as « + a session on this machine »
  records them; all its sessions are marked as living in the sandbox (/work)."""
import json
import os
import random
import sqlite3
import sys
import time

home, s_run, s_paused = sys.argv[1], sys.argv[2], sys.argv[3]
now = time.time()
db = sqlite3.connect(os.path.join(home, "data", "sessions.sqlite3"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from engine.sandboxes import SCHEMA  # noqa: E402
db.executescript(SCHEMA)
for k, v in {"org": "agent-manager", "app": "agmgd-demo0001", "image": "registry.fly.io/agmgd-demo0001:v1",
             "image_built": str(now - 3 * 86400), "region": "yyz", "budget_usd": "5", "stop_idle_minutes": "30"}.items():
    db.execute("INSERT OR REPLACE INTO sandbox_config VALUES (?, ?)", (k, v))
rows = [("a1c4e9f2", s_run, "e7843a1f0c2d98", now - 86400 * 2), ("b07d3e55", s_paused, "9185b2e4d01376", now - 86400 * 6)]
for sbid, sid, mid, created in rows:
    db.execute("INSERT OR REPLACE INTO sandboxes (id, session_id, app, machine, region, size, secret, workdir, created) "
               "VALUES (?, ?, 'agmgd-demo0001', ?, 'yyz', 'shared-cpu-1x-1024', 'demo', '/work/gd-project', ?)", (sbid, sid, mid, created))
# a third one, destroyed nine days ago: it stays in the inventory with the runs it had
db.execute("INSERT OR REPLACE INTO sandboxes (id, session_id, app, machine, region, size, secret, workdir, destroyed, created) "
           "VALUES ('old-5e21', '', 'agmgd-demo0001', '3d8c0b77a1e254', 'yyz', 'shared-cpu-1x-1024', 'demo', '/work', 1, ?)", (now - 86400 * 26,))
db.execute("UPDATE sessions SET brain_client = 'demo-key' WHERE id = ?", (s_run,))
added = sys.argv[4:]
for i, sid in enumerate(added):   # the first added one is an agent (its own worktree), the others shells
    db.execute("INSERT OR REPLACE INTO sandbox_sessions VALUES (?, 'a1c4e9f2', ?, ?, ?)", (sid, "am-" + sid, int(i == 0), now - 600 + i))
if added:
    for sid in [s_run] + added:
        db.execute("UPDATE sessions SET cwd = '/work' WHERE id = ?", (sid,))
# a month of past runs: a few hours most working days
random.seed(7)
for d in range(1, 26):
    if random.random() < 0.3:
        continue
    day0 = now - d * 86400
    start = day0 - random.uniform(2, 8) * 3600
    db.execute("INSERT OR REPLACE INTO sandbox_runs VALUES (?, 'shared-cpu-1x-1024', ?, ?)",
               (random.choice(["a1c4e9f2", "b07d3e55", "old-5e21"]) if d > 9 else random.choice(["a1c4e9f2", "b07d3e55"]),
                start, start + random.uniform(1.5, 9) * 3600))   # nothing of the destroyed one after its end
db.commit()
ms = lambda t: int(t * 1000)  # noqa: E731
demo = {"machines": [
    {"id": "e7843a1f0c2d98", "name": "sandbox-a1c4e9f2", "state": "started",
     "events": [{"type": "launch", "timestamp": ms(now - 5100)}]},
    {"id": "9185b2e4d01376", "name": "sandbox-b07d3e55", "state": "stopped",
     "events": [{"type": "start", "timestamp": ms(now - 9 * 3600)}, {"type": "stop", "timestamp": ms(now - 6.5 * 3600)}]}],
    "apps": [{"Name": "agmgd-demo0001", "Status": "deployed"}],
    "health": {"a1c4e9f2": {"machine": "started", "terminal": True, "tunnel": "up", "latency_ms": 48, "brain": True,
                            "mcp": True, "branch": "am/a1c4e9f2", "dirty": 2, "unpushed": 3}}}
path = os.path.join(home, "demo-fly.json")
with open(path, "w") as f:
    json.dump(demo, f)
print(path)
