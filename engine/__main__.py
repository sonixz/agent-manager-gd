"""python3 -m engine [--port 8790]: the Agent Manager GD engine (runs where tmux is: Linux or WSL)."""
from __future__ import annotations

import argparse
import os
import sys

from .api import load_token, port_free, serve
from .sessions import Sessions
from .store import Store
from .tmux import Tmux


def home() -> str:
    base = os.environ.get("AGMGD_HOME") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "agent-manager-gd")
    os.makedirs(base, exist_ok=True)
    return base


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="engine")
    ap.add_argument("--port", type=int, default=int(os.environ.get("AGMGD_PORT", "8790")))
    ap.add_argument("--socket", default=os.environ.get("AGMGD_TMUX_SOCKET", "agmgd"))
    a = ap.parse_args(argv)
    h = home()
    tmux = Tmux(a.socket)
    if not tmux.available():
        print("tmux is not installed (sudo apt install tmux, by you)", file=sys.stderr)
        return 2
    if not port_free(a.port):
        print(f"port {a.port} is busy: is the engine already running?", file=sys.stderr)
        return 3
    from .brain import Brain
    brain = Brain()
    sessions = Sessions(Store(os.path.join(h, "data", "sessions.sqlite3")), tmux, h, brain if brain.enabled else None)
    print("Second Brain: " + ("connected" if brain.enabled and brain.status()["connected"] else "not connected"), flush=True)
    sessions.port = a.port
    srv = serve(sessions, load_token(h), a.port)
    import threading
    from .sandbox_ops import monitor
    threading.Thread(target=monitor, args=(sessions,), daemon=True).start()  # Loop 16: sandbox health, once a minute
    from . import host_history
    sessions.host_watch = host_history.start(sessions, h)  # Loop 36: memory and sessions over time, every 30 seconds
    from .relay import Relay
    from .sandbox_carrier import Carrier
    # Loop 38: a sandbox's ports, brought to this computer. AGMGD_CARRIER_SSH puts a stand-in for ssh (captures only).
    sessions.carrier = Carrier(sessions.sandboxes, Relay(), h, ssh=os.environ.get("AGMGD_CARRIER_SSH") or "ssh")
    print(f"engine ready on 127.0.0.1:{a.port} (data: {h})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        sessions.carrier.close_all()   # what was opened toward the sandboxes does not outlive the engine
    return 0


if __name__ == "__main__":
    sys.exit(main())
