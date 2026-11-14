"""Talking to a running sandbox from the engine: one SSH command, and the connection report (Loop 13)."""
from __future__ import annotations

import os
import subprocess
import time

from .sandboxes import FLYCTL
from .sandbox_attach import free_port, ssh_base


def _port(sbx, sbid: str) -> int:
    """The local proxy port of one of the sandbox's open terminals (its first session's, or an added one's)."""
    import glob
    run = os.path.join(sbx.home, "runtime")
    for path in [os.path.join(run, f"sandbox-{sbid}.port")] + sorted(glob.glob(os.path.join(run, f"sandbox-{sbid}~*.port"))):
        try:
            with open(path) as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            continue
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


def health(sbx, sbid: str, mcp_expected: bool) -> dict:
    """Loop 16: one SSH round trip for everything the card shows: tunnel and Brain, the agent's MCP configuration,
    the repository's branch, uncommitted files and commits not pushed. Cached in sbx.health."""
    rep = connection(sbx, sbid)
    rep.update({"mcp": None, "branch": "", "dirty": None, "unpushed": None, "checked": time.time()})
    if rep["tunnel"] == "up":
        sb = sbx.get(sbid)
        wd = sb["workdir"]
        cmd = (f"test -s /root/.agmgd/mcp.json && grep -q second-brain /root/.agmgd/mcp.json && echo MCP-CONF; echo ---; "
               f"cd {wd} 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 && "
               f"git rev-parse --abbrev-ref HEAD && git status --porcelain | wc -l && "
               f"(git rev-list --count @{{u}}..HEAD 2>/dev/null || git rev-list --count HEAD --not --remotes)")
        rc, out = ssh_run(sbx, sbid, cmd, 30)
        if rc in (0, 1):
            head, _, git = out.partition("---")
            rep["mcp"] = ("MCP-CONF" in head and bool(rep["brain"])) if mcp_expected else None
            lines = [x.strip() for x in git.strip().splitlines() if x.strip()]
            if len(lines) >= 3:
                rep["branch"], rep["dirty"], rep["unpushed"] = lines[0], int(lines[1]), int(lines[2])
    sbx.health[sbid] = rep
    return rep


def monitor(sessions, every: float = 60.0) -> None:
    """Background loop (engine only): checks each running sandbox whose terminal is open, about once a minute."""
    while True:
        time.sleep(every)
        try:
            for sb in sessions.sandboxes.all():
                if sb["destroyed"] or not attach_running(sb["id"]):
                    continue
                rec = sessions.store.get(sb["session_id"]) or {}
                health(sessions.sandboxes, sb["id"], bool(rec.get("brain_client")))
        except Exception:
            pass


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
