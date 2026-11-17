"""Captures only (Loop 49a): a small MCP server over Streamable HTTP on this computer, for the ⌁ MCP page's live
Test in the fictional workspace. It offers a few note tools and one prompt; nothing reaches the network.
  python3 tools/showcase/fake_mcp.py <port>"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOLS = ["search_notes", "read_note", "add_note", "list_tags", "link_notes"]


class Mcp(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        m, mid = msg.get("method"), msg.get("id")
        if self.path != "/mcp":
            return self._send(404, {})
        if mid is None:
            return self._send(202, None)
        if m == "initialize":
            res = {"protocolVersion": "2025-06-18", "serverInfo": {"name": "notes", "version": "0.4"}, "capabilities": {"tools": {}, "prompts": {}}}
        elif m == "tools/list":
            res = {"tools": [{"name": t, "description": t.replace("_", " ")} for t in TOOLS]}
        elif m == "prompts/list":
            res = {"prompts": [{"name": "start", "description": "Begin from today's notes"}]}
        else:
            return self._send(200, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown"}})
        self._send(200, {"jsonrpc": "2.0", "id": mid, "result": res})

    def _send(self, code, body):
        raw = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Mcp).serve_forever()
