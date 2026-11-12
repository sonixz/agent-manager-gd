"""The computer under the engine (Loop 36, the engine room): memory, disk, how long it has been up, what each
session weighs and how much processor it takes, which sessions work on the Windows disk. Read from /proc and the
file system: nothing is run, nothing is changed. What it was over time is kept by host_history.py."""
from __future__ import annotations

import os
import shutil
import time

from .tmux import PREFIX

PROC = "/proc"  # the tests point these two at folders of their own
MNT = "/mnt"


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def memory(proc: str = PROC) -> dict:
    """Bytes. « used » is what is not available: what a new program could not get without pushing something out."""
    kb = {}
    for line in _read(os.path.join(proc, "meminfo")).splitlines():
        name, _, rest = line.partition(":")
        num = rest.split()
        if num and num[0].isdigit():
            kb[name] = int(num[0]) * 1024
    total, free = kb.get("MemTotal", 0), kb.get("MemAvailable", 0)
    # « held » is what Linux keeps for itself, its file cache included: on WSL, close to what Windows has to give
    return {"total": total, "available": free, "used": max(0, total - free),
            "held": max(0, total - kb.get("MemFree", 0)) if total else 0,
            "swap_total": kb.get("SwapTotal", 0), "swap_used": max(0, kb.get("SwapTotal", 0) - kb.get("SwapFree", 0))}


def uptime(proc: str = PROC) -> float:
    first = _read(os.path.join(proc, "uptime")).split()
    try:
        return float(first[0]) if first else 0.0
    except ValueError:
        return 0.0


def scan(proc: str = PROC) -> dict[int, tuple[int, int, int, int]]:
    """pid -> (its parent, the memory it holds in bytes, the processor time it has used so far in clock ticks,
    when it started in clock ticks since the computer started)."""
    page = os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096
    out = {}
    try:
        names = os.listdir(proc)
    except OSError:
        return out
    for name in names:
        if not name.isdigit():
            continue
        stat = _read(os.path.join(proc, name, "stat"))
        statm = _read(os.path.join(proc, name, "statm")).split()
        # the program's name sits in brackets and may hold spaces and brackets: the fields start after the last one
        tail = stat.rpartition(")")[2].split()
        if len(tail) < 2 or len(statm) < 2 or not tail[1].lstrip("-").isdigit() or not statm[1].isdigit():
            continue  # the process ended while it was read
        num = [int(x) if x.lstrip("-").isdigit() else 0 for x in tail]
        ticks = (num[11] + num[12]) if len(num) > 12 else 0   # utime + stime: fields 14 and 15 of the whole line
        out[int(name)] = (num[1], int(statm[1]) * page, ticks, num[19] if len(num) > 19 else 0)
    return out


def processes(proc: str = PROC) -> dict[int, tuple[int, int]]:
    """pid -> (its parent, the memory it holds in bytes)."""
    return {pid: (v[0], v[1]) for pid, v in scan(proc).items()}


def family(pid: int, procs: dict[int, tuple]) -> set[int]:
    """A process and everything it started, however deep."""
    children: dict[int, list[int]] = {}
    for p, v in procs.items():
        children.setdefault(v[0], []).append(p)
    todo, seen = [pid], set()
    while todo:
        p = todo.pop()
        if p in seen or p not in procs:
            continue
        seen.add(p)
        todo.extend(children.get(p, []))
    return seen


def weight(pid: int, procs: dict[int, tuple]) -> int:
    """What a process and everything it started hold together."""
    return sum(procs[p][1] for p in family(pid, procs))


def cpu_times(proc: str = PROC) -> tuple[int, int]:
    """(busy, all) clock ticks of every processor together since the computer started; waiting for the disk is not
    busy."""
    for line in _read(os.path.join(proc, "stat")).splitlines():
        if line.startswith("cpu "):
            n = [int(x) for x in line.split()[1:] if x.isdigit()]
            if len(n) >= 4:
                idle = n[3] + (n[4] if len(n) > 4 else 0)
                return sum(n) - idle, sum(n)
    return 0, 0


def load(proc: str = PROC) -> float:
    """How many programs wanted a processor at once, on average over the last minute."""
    first = _read(os.path.join(proc, "loadavg")).split()
    try:
        return float(first[0]) if first else 0.0
    except ValueError:
        return 0.0


def is_wsl(proc: str = PROC) -> bool:
    return "microsoft" in _read(os.path.join(proc, "version")).lower()


def windows_drive(path: str, mnt: str = MNT) -> str:
    """« c » for a folder on the Windows disk C: as WSL shows it (/mnt/c/…); « » for a folder inside Linux."""
    rel = os.path.relpath(path, mnt) if path.startswith(mnt.rstrip("/") + "/") else ""
    first = rel.split(os.sep)[0] if rel else ""
    return first if len(first) == 1 and first.isalpha() else ""


def _usage(path: str) -> dict | None:
    try:
        u = shutil.disk_usage(path)
    except OSError:
        return None
    return {"total": u.total, "free": u.free}


def report(records: list[dict], live: dict, proc: str = PROC, mnt: str = MNT, root: str = "/",
           procs: dict[int, tuple] | None = None) -> dict:
    """`records`: the sessions as the store holds them (id, name, cwd). `live`: tmux's sessions by name, each with
    its pane's process (pane_pid) and whether that pane is dead. `procs`: a scan already made, when there is one."""
    wsl = is_wsl(proc)
    procs = scan(proc) if procs is None else procs
    weights, on_windows = [], []
    for r in records:
        t = live.get(PREFIX + str(r["id"]))
        if t is None or getattr(t, "pane_dead", False):
            continue
        drive = windows_drive(str(r.get("cwd", "")), mnt) if wsl else ""
        weights.append({"id": r["id"], "name": r.get("name", ""), "tool": r.get("tool", ""),
                        "bytes": weight(int(t.pane_pid), procs),
                        # when tmux made it, the last time its screen changed, how many screens show it now
                        "created": int(getattr(t, "created", 0) or 0), "activity": float(getattr(t, "activity", 0.0) or 0.0),
                        "attached": int(getattr(t, "attached", 0) or 0), "drive": drive})
        if drive:
            on_windows.append({"id": r["id"], "name": r.get("name", ""), "drive": drive})
    weights.sort(key=lambda w: -w["bytes"])
    drives = []
    if wsl:
        try:
            letters = sorted(d for d in os.listdir(mnt) if len(d) == 1 and d.isalpha())
        except OSError:
            letters = []
        for d in letters:
            u = _usage(os.path.join(mnt, d))
            if u and u["total"] > 0:
                drives.append({"letter": d, **u})
    return {"wsl": wsl, "distro": os.environ.get("WSL_DISTRO_NAME", "") if wsl else "", "now": time.time(),
            "memory": memory(proc), "uptime": uptime(proc), "load": load(proc), "processors": os.cpu_count() or 1,
            "disk": _usage(root) or {"total": 0, "free": 0},
            "drives": drives, "sessions": weights, "sessions_bytes": sum(w["bytes"] for w in weights),
            "on_windows_disk": on_windows}
