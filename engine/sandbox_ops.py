"""Talking to a running sandbox from the engine: one SSH command, and the connection report (Loop 13)."""
from __future__ import annotations

import os
import subprocess
import time

from .sandboxes import FLYCTL
from .sandbox_attach import free_port, ssh_base


def _port(sbx, sbid: str) -> int:
    try:
        with open(os.path.join(sbx.home, "runtime", f"sandbox-{sbid}.port")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 0


def attach_running(sbid: str) -> bool:
    return subprocess.run(["pgrep", "-f", f"sandbox_attach.py {sbid}"], capture_output=True).returncode == 0


def ssh_run(sbx, sbid: str, command: str, timeout: int = 60) -> tuple[int, str]:
    """Runs one command in the sandbox: through the open session's proxy, or a short-lived one."""
    sb = sbx.get(sbid)
    port = _port(sbx, sbid) if attach_running(sbid) else 0
    proxy = None
    if not port:
        port = free_port()
        proxy = subprocess.Popen([FLYCTL, "proxy", f"{port}:2222", f"{sb['machine']}.vm.{sb['app']}.internal", "--app", sb["app"]],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=sbx.fly.env())
        time.sleep(2.5)
    try:
        out = subprocess.run(ssh_base(sbx.key_path(sbid), port) + ["root@127.0.0.1", command], capture_output=True, text=True, timeout=timeout)
        return out.returncode, (out.stdout + out.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    finally:
        if proxy:
            proxy.kill()


def connection(sbx, sbid: str) -> dict:
    """Machine state, tunnel (the session's SSH with its reverse port), latency, the Brain reachable from inside."""
    sb = sbx.get(sbid)
    try:
        m = next((x for x in sbx.machines() if x["id"] == sb["machine"]), {})
        machine = m.get("state", "gone")
    except Exception:
        machine = "unknown (Fly unreachable)"
    rep = {"machine": machine, "terminal": attach_running(sbid), "tunnel": "down", "latency_ms": None, "brain": None}
    if machine != "started" or not rep["terminal"]:
        rep["tunnel"] = "down (no open terminal)" if machine == "started" else "down (machine " + machine + ")"
        return rep
    t0 = time.time()
    rc, out = ssh_run(sbx, sbid, f"curl -s -m 5 http://127.0.0.1:8765/sandbox-brain/{sb['secret']}/health || echo NO-TUNNEL", 30)
    rep["latency_ms"] = round((time.time() - t0) * 1000)
    if rc == 0 and "NO-TUNNEL" not in out:
        rep["tunnel"] = "up"
        rep["brain"] = '"brain": true' in out.replace("'", '"') or '"brain":true' in out
    elif rc == 0:
        rep["tunnel"] = "reconnecting"
    return rep
