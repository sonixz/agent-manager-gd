"""The computer under the engine (Loop 36, the engine room): memory, disk, how long it has been up, what each
session weighs, which sessions work on the Windows disk. Read from /proc and the file system: nothing is run,
nothing is changed."""
from __future__ import annotations

import os
import shutil

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
    return {"total": total, "available": free, "used": max(0, total - free),
            "swap_total": kb.get("SwapTotal", 0), "swap_used": max(0, kb.get("SwapTotal", 0) - kb.get("SwapFree", 0))}


def uptime(proc: str = PROC) -> float:
    first = _read(os.path.join(proc, "uptime")).split()
    try:
        return float(first[0]) if first else 0.0
    except ValueError:
        return 0.0


def processes(proc: str = PROC) -> dict[int, tuple[int, int]]:
    """pid -> (its parent, the memory it holds in bytes)."""
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
        out[int(name)] = (int(tail[1]), int(statm[1]) * page)
    return out


def weight(pid: int, procs: dict[int, tuple[int, int]]) -> int:
    """What a process and everything it started hold together."""
    children: dict[int, list[int]] = {}
    for p, (parent, _) in procs.items():
        children.setdefault(parent, []).append(p)
    total, todo, seen = 0, [pid], set()
    while todo:
        p = todo.pop()
        if p in seen or p not in procs:
            continue
        seen.add(p)
        total += procs[p][1]
        todo.extend(children.get(p, []))
    return total


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


def report(records: list[dict], live: dict, proc: str = PROC, mnt: str = MNT, root: str = "/") -> dict:
    """`records`: the sessions as the store holds them (id, name, cwd). `live`: tmux's sessions by name, each with
    its pane's process (pane_pid) and whether that pane is dead."""
    wsl = is_wsl(proc)
    procs = processes(proc)
    weights, on_windows = [], []
    for r in records:
        t = live.get(PREFIX + str(r["id"]))
        if t is None or getattr(t, "pane_dead", False):
            continue
        weights.append({"id": r["id"], "name": r.get("name", ""), "bytes": weight(int(t.pane_pid), procs)})
        drive = windows_drive(str(r.get("cwd", "")), mnt) if wsl else ""
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
    return {"wsl": wsl, "distro": os.environ.get("WSL_DISTRO_NAME", "") if wsl else "",
            "memory": memory(proc), "uptime": uptime(proc), "disk": _usage(root) or {"total": 0, "free": 0},
            "drives": drives, "sessions": weights, "sessions_bytes": sum(w["bytes"] for w in weights),
            "on_windows_disk": on_windows}
