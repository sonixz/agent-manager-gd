"""Run by the Second Brain's own Windows Python when the engine (in WSL) cannot reach the Brain directly.
  python.exe brain_call.py <brain home> <METHOD> <path>   (JSON body on stdin)
Reads the app token and the port from the Brain's own files (never from the command line), calls
http://127.0.0.1:<port><path>, prints the JSON answer with any "token" field removed. Standard library only."""
import json
import os
import sys
import urllib.error
import urllib.request


def scrub(x):
    if isinstance(x, dict):
        return {k: scrub(v) for k, v in x.items() if k != "token"}
    if isinstance(x, list):
        return [scrub(v) for v in x]
    return x


def main(argv):
    home, method, path = argv[1], argv[2], argv[3]
    with open(os.path.join(home, "runtime", "api_token"), encoding="utf-8") as f:
        token = f.read().strip()
    with open(os.path.join(home, "runtime", "server.json"), encoding="utf-8") as f:
        port = int(json.load(f)["port"])
    body = sys.stdin.buffer.read() or None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=body, method=method,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            out = {"status": r.status, "body": json.loads(r.read() or b"{}")}
    except urllib.error.HTTPError as e:
        out = {"status": e.code, "body": {"error": e.read().decode("utf-8", "replace")[:300]}}
    except OSError as e:
        out = {"status": 0, "body": {"error": str(e)[:300]}}
    sys.stdout.write(json.dumps(scrub(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
