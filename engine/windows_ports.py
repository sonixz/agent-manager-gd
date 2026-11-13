"""Ports already taken on the Windows side of this computer (owner, 2026-11-12: « Je peux pas avoir deux localhosts
sur le port 8000 »).

The engine runs in WSL. A port it opens on WSL's 127.0.0.1 reaches Windows through WSL's own localhost bridge
(wslrelay.exe), but WSL does not see Windows' own listeners: a Windows program already on 8000 would win in the
browser while the engine believed 8000 was its own. So before choosing a port, the engine reads Windows' listeners,
read only, with Windows' own netstat. The bridge's listeners are WSL's ports, not Windows programs: they are left out.

Outside WSL, or when Windows cannot be asked, the answer is an empty set: nothing more is checked than before.
"""
from __future__ import annotations

import shutil
import subprocess
import threading
import time

LOCAL = ("0.0.0.0", "127.0.0.1", "[::]", "[::1]")   # what « localhost » in a Windows browser can land on
KEEP = 3.0                                          # seconds an answer is reused

_lock = threading.Lock()
_last: tuple[float, set[int]] = (-1e9, set())


def parse_netstat(text: str, skip_pids: set[str] = frozenset()) -> set[int]:
    """The local ports listened on for localhost in `netstat -ano` output, without the given processes."""
    out: set[int] = set()
    for line in text.splitlines():
        f = line.split()
        if len(f) != 5 or not f[0].startswith("TCP") or f[3] != "LISTENING" or f[4] in skip_pids:
            continue
        addr, _, port = f[1].rpartition(":")
        if addr in LOCAL and port.isdigit():
            out.add(int(port))
    return out


def parse_relays(text: str) -> set[str]:
    """The process numbers of wslrelay.exe in `tasklist /FO CSV /NH` output."""
    pids = set()
    for line in text.splitlines():
        f = [x.strip('"') for x in line.split('","')]
        if len(f) > 1 and f[0].strip('"').lower() == "wslrelay.exe" and f[1].isdigit():
            pids.add(f[1])
    return pids


def _ask() -> set[int]:
    if not shutil.which("netstat.exe"):
        return set()
    try:
        relays = set()
        if shutil.which("tasklist.exe"):
            t = subprocess.run(["tasklist.exe", "/FI", "IMAGENAME eq wslrelay.exe", "/FO", "CSV", "/NH"],
                               capture_output=True, timeout=5)
            relays = parse_relays(t.stdout.decode("utf-8", "replace"))
        n = subprocess.run(["netstat.exe", "-ano"], capture_output=True, timeout=5)
        return parse_netstat(n.stdout.decode("utf-8", "replace"), relays)
    except (OSError, subprocess.SubprocessError):
        return set()


def taken() -> set[int]:
    """Ports a Windows program already listens on for localhost (reused for a few seconds)."""
    global _last
    with _lock:
        if time.monotonic() - _last[0] < KEEP:
            return set(_last[1])
    found = _ask()
    with _lock:
        _last = (time.monotonic(), found)
    return set(found)
