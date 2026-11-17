"""Captures only (Loop 49a): MCP servers in a throw-away data folder, as if they had been added and tested: one on
the internet that answered (a Loop 0 like method server, at an example address), one that did not answer, one
started by a command and never tested. Nothing reaches the network.
  python3 tools/demo_mcp.py <data folder>"""
import json
import os
import sqlite3
import sys
import time

db = sqlite3.connect(os.path.join(sys.argv[1], "data", "sessions.sqlite3"))
now = time.time()
LOOP0_TOOLS = ["loop0_guide", "start_loop", "next_step", "render_mission", "review_loop", "list_loops", "read_loop", "improve", "close_loop"]
servers = [
    ("loop0", "http", "https://mcp.loop0.example/mcp", "", "[]", 0, "the Loop 0 method: from an idea to missions", now - 3 * 86400,
     {"ok": True, "at": now - 140, "server": "loop0", "version": "2.3.0", "ms": 145, "error": "",
      "tools": [{"name": t, "description": ""} for t in LOOP0_TOOLS],
      "prompts": [{"name": p, "description": ""} for p in ("start", "next", "improve")]}),
    ("docs-search", "http", "https://docs.example.dev/mcp", "", "[]", 0, "our internal docs", now - 2 * 86400,
     {"ok": False, "at": now - 900, "server": "", "version": "", "ms": 10000, "tools": [], "prompts": [], "error": "unreachable: timed out"}),
    ("files", "stdio", "", "npx", json.dumps(["-y", "@modelcontextprotocol/server-filesystem", "~/code"]), 0, "files of ~/code", now - 86400, None),
]
with db:
    for name, kind, url, cmd, args, every, note, added, test in servers:
        db.execute("INSERT OR REPLACE INTO mcp_servers (name, kind, url, command, args, everywhere, note, added, last_test) VALUES (?,?,?,?,?,?,?,?,?)",
                   (name, kind, url, cmd, args, every, note, added, json.dumps(test) if test else ""))
