"""Loop 36: the computer under the engine, read from a made-up /proc and /mnt (nothing of the real one)."""
import os
import shutil
import tempfile
import unittest
from types import SimpleNamespace

from engine import host

PAGE = os.sysconf("SC_PAGE_SIZE")


class HostTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-host-")
        self.proc = os.path.join(self.tmp, "proc")
        self.mnt = os.path.join(self.tmp, "mnt")
        os.makedirs(os.path.join(self.mnt, "c", "code", "shop"))
        os.makedirs(os.path.join(self.mnt, "wsl"))  # WSL's own folder there is not a drive
        os.makedirs(self.proc)
        self._file("meminfo", "MemTotal:       16000000 kB\nMemFree:         9000000 kB\nMemAvailable:   12000000 kB\n"
                              "SwapTotal:       4000000 kB\nSwapFree:        3000000 kB\n")
        self._file("uptime", "65940.12 791000.00\n")
        self._file("version", "Linux version 6.6.87.2-microsoft-standard-WSL2 (root@x) #1 SMP\n")
        # 100 is a session's pane (a shell); it started the agent 101, which started a helper 102. 200 is another
        # session. 300 belongs to nobody here. The name of 101 holds a space and brackets, as a real one may.
        for pid, parent, name, pages in [(100, 1, "bash", 1000), (101, 100, "claude (v2) x", 100000), (102, 101, "node", 20000),
                                         (200, 1, "codex", 50000), (300, 1, "sshd", 7000)]:
            os.makedirs(os.path.join(self.proc, str(pid)))
            self._file(f"{pid}/stat", f"{pid} ({name}) S {parent} {pid} {pid} 0 -1 4194304 100 0 0 0 1 1 0 0 20 0 1 0 5 1000 {pages}\n")
            self._file(f"{pid}/statm", f"{pages * 3} {pages} 500 1 0 900 0\n")
        os.makedirs(os.path.join(self.proc, "self"))  # not a number: not a process

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _file(self, rel, text):
        with open(os.path.join(self.proc, rel), "w") as f:
            f.write(text)

    def test_memory_and_uptime(self):
        m = host.memory(self.proc)
        self.assertEqual(m["total"], 16000000 * 1024)
        self.assertEqual(m["used"], 4000000 * 1024)          # what is not available, not « total minus free »
        self.assertEqual(m["swap_used"], 1000000 * 1024)
        self.assertAlmostEqual(host.uptime(self.proc), 65940.12)
        self.assertEqual(host.memory(os.path.join(self.tmp, "nowhere"))["total"], 0)
        self.assertEqual(host.uptime(os.path.join(self.tmp, "nowhere")), 0.0)

    def test_a_session_weighs_its_whole_family(self):
        procs = host.processes(self.proc)
        self.assertEqual(procs[101], (100, 100000 * PAGE))    # the name with a space and brackets did not shift the fields
        self.assertEqual(host.weight(100, procs), (1000 + 100000 + 20000) * PAGE)
        self.assertEqual(host.weight(200, procs), 50000 * PAGE)
        self.assertEqual(host.weight(999, procs), 0)          # a process that is gone weighs nothing

    def test_folders_on_the_windows_disk(self):
        self.assertEqual(host.windows_drive(os.path.join(self.mnt, "c", "code", "shop"), self.mnt), "c")
        self.assertEqual(host.windows_drive(os.path.join(self.mnt, "wsl", "x"), self.mnt), "")
        self.assertEqual(host.windows_drive("/home/dev/code/shop", self.mnt), "")
        self.assertEqual(host.windows_drive(self.mnt + "c/x", self.mnt), "")

    def test_report(self):
        records = [{"id": "aa", "name": "Checkout flow", "cwd": os.path.join(self.mnt, "c", "code", "shop")},
                   {"id": "bb", "name": "Docs refresh", "cwd": "/home/dev/code/docs"},
                   {"id": "cc", "name": "Ended", "cwd": os.path.join(self.mnt, "c", "code", "shop")},
                   {"id": "dd", "name": "Not in tmux", "cwd": "/home/dev"}]
        live = {"am_aa": SimpleNamespace(pane_pid=100, pane_dead=False), "am_bb": SimpleNamespace(pane_pid=200, pane_dead=False),
                "am_cc": SimpleNamespace(pane_pid=300, pane_dead=True)}
        r = host.report(records, live, self.proc, self.mnt, self.tmp)
        self.assertTrue(r["wsl"])
        self.assertEqual([s["name"] for s in r["sessions"]], ["Checkout flow", "Docs refresh"])   # the heaviest first; ended ones are left out
        self.assertEqual(r["sessions_bytes"], (121000 + 50000) * PAGE)
        self.assertEqual(r["on_windows_disk"], [{"id": "aa", "name": "Checkout flow", "drive": "c"}])
        self.assertEqual([d["letter"] for d in r["drives"]], ["c"])
        self.assertGreater(r["drives"][0]["total"], 0)
        self.assertGreater(r["disk"]["total"], 0)

    def test_on_linux_alone_nothing_is_a_windows_disk(self):
        self._file("version", "Linux version 6.8.0-45-generic (buildd@lcy02) #45-Ubuntu SMP\n")
        records = [{"id": "aa", "name": "Checkout flow", "cwd": os.path.join(self.mnt, "c", "code", "shop")}]
        r = host.report(records, {"am_aa": SimpleNamespace(pane_pid=100, pane_dead=False)}, self.proc, self.mnt, self.tmp)
        self.assertFalse(r["wsl"])
        self.assertEqual(r["on_windows_disk"], [])
        self.assertEqual(r["drives"], [])
        self.assertEqual(r["distro"], "")


if __name__ == "__main__":
    unittest.main()
