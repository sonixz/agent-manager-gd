"""Captures only (Loop 41): two Online machines in a throw-away data folder already filled by demo_sandboxes.py: « shop »,
exposed, and « blog », private, each with its own app, volume and session. Nothing reaches Fly.io.
  python3 tools/demo_online.py <data folder> <session id of shop> <session id of blog>"""
import json
import os
import sqlite3
import sys
import time

home, s_shop, s_blog = sys.argv[1], sys.argv[2], sys.argv[3]
now = time.time()
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from engine.sandboxes import ONLINE_COLUMNS, SCHEMA  # noqa: E402
db = sqlite3.connect(os.path.join(home, "data", "sessions.sqlite3"))
db.executescript(SCHEMA)
have = {r[1] for r in db.execute("PRAGMA table_info(sandboxes)")}
for col, decl in ONLINE_COLUMNS:
    if col not in have:
        db.execute(f"ALTER TABLE sandboxes ADD COLUMN {col} {decl}")
rows = [("c51e0a77", s_shop, "agmgd-on-shop-c51e0a77", "4d27e118a0b9c3", "shop", 8080, 3, 1, now - 86400 * 4),
        ("d903b2f1", s_blog, "agmgd-on-blog-d903b2f1", "6a1f93c2d47e05", "blog", 3000, 1, 0, now - 86400)]
for sbid, sid, app, mid, name, port, vol, exposed, created in rows:
    db.execute("INSERT OR REPLACE INTO sandboxes (id, session_id, app, machine, region, size, secret, workdir, created, kind, name, "
               "port, volume_gb, exposed) VALUES (?, ?, ?, ?, 'yyz', 'shared-cpu-1x-1024', 'demo', '/data/work', ?, 'online', ?, ?, ?, ?)",
               (sbid, sid, app, mid, created, name, port, vol, exposed))
    db.execute("UPDATE sessions SET cwd = '/work', grp = 'Online' WHERE id = ?", (sid,))
    db.execute("INSERT OR REPLACE INTO sandbox_runs VALUES (?, 'shared-cpu-1x-1024', ?, NULL)", (sbid, created + 120))
db.execute("INSERT OR IGNORE INTO groups (name, position) VALUES ('Online', 9)")   # as store.add makes it
db.commit()
path = os.path.join(home, "demo-fly.json")
demo = json.load(open(path)) if os.path.exists(path) else {"machines": [], "apps": []}
ms = lambda t: int(t * 1000)  # noqa: E731
demo["machines"] += [{"id": r[3], "name": "sandbox-" + r[0], "state": "started", "events": [{"type": "launch", "timestamp": ms(r[8] + 120)}]} for r in rows]
demo["apps"] += [{"Name": r[2], "Status": "deployed"} for r in rows]
demo.setdefault("health", {})["c51e0a77"] = {"machine": "started", "terminal": True, "tunnel": "up", "latency_ms": 41, "brain": True,
                                             "mcp": True, "branch": "am/c51e0a77", "dirty": 0, "unpushed": 1,
                                             "start_script": True,
                                             "service_log": "== boot 2026-11-14T15:02:11Z\npostgres: ready on 127.0.0.1:5432\nshop: listening on 0.0.0.0:8080"}
json.dump(demo, open(path, "w"))
print(path)
