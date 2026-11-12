"""Loop 36, the dashboard: the computer over time. Most cases read a made-up /proc that changes between two
readings (nothing of the real one); the last one reads the real /proc under a real session, in an isolated tmux."""
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
import urllib.request
from types import SimpleNamespace
from unittest import mock

from engine import host, host_history
from engine.api import load_token, serve
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux

PAGE = os.sysconf("SC_PAGE_SIZE")
HZ = os.sysconf("SC_CLK_TCK")
T0 = 1_800_000_000   # a round time: 30-second slices start on it


class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-hist-")
        self.proc = os.path.join(self.tmp, "proc")
        os.makedirs(os.path.join(self.proc, "sys", "kernel", "random"))
        self.boot("boot-one")
        self.machine(up=1000.0, busy=0, idle=0, used_kb=4_000_000)
        self.watch = host_history.Watch(os.path.join(self.tmp, "data", "h.sqlite3"), 30, proc=self.proc, pid=900)
        self.records = [{"id": "aa", "name": "Checkout flow"}, {"id": "bb", "name": "Docs refresh"}]
        self.live = {"am_aa": SimpleNamespace(pane_pid=100, pane_dead=False), "am_bb": SimpleNamespace(pane_pid=200, pane_dead=False)}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _file(self, rel, text):
        path = os.path.join(self.proc, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def boot(self, ident):
        self._file("sys/kernel/random/boot_id", ident + "\n")

    def machine(self, up, busy, idle, used_kb, total_kb=16_000_000):
        """The computer as a whole: seconds since it started, processor ticks busy and idle, memory in use."""
        self._file("uptime", f"{up:.2f} 0.00\n")
        self._file("stat", f"cpu  {busy} 0 0 {idle} 0 0 0 0 0 0\ncpu0 {busy} 0 0 {idle} 0 0 0 0 0 0\n")
        self._file("loadavg", "0.50 0.40 0.30 1/200 999\n")
        self._file("meminfo", f"MemTotal:       {total_kb} kB\nMemFree:        {total_kb - used_kb - 1_000_000} kB\n"
                              f"MemAvailable:   {total_kb - used_kb} kB\nSwapTotal:       0 kB\nSwapFree:        0 kB\n")

    def process(self, pid, parent, pages, ticks, start=5):
        """One process: its parent, the memory it holds in pages, the processor ticks it used, when it started."""
        self._file(f"{pid}/stat", f"{pid} (a (b) c) S {parent} {pid} {pid} 0 -1 4194304 100 0 0 0 {ticks} 0 0 0 20 0 1 0 {start} 1000 {pages}\n")
        self._file(f"{pid}/statm", f"{pages * 3} {pages} 500 1 0 900 0\n")

    def gone(self, pid):
        shutil.rmtree(os.path.join(self.proc, str(pid)))

    # ---------------------------------------------------------------- one reading, then another
    def test_the_processor_share_needs_two_readings(self):
        self.process(100, 1, 1000, ticks=10)
        self.process(101, 100, 100_000, ticks=500)      # the agent the session's shell started
        self.process(200, 1, 50_000, ticks=0)
        self.process(900, 1, 7000, ticks=40)            # the engine itself
        first = self.watch.tick(self.records, self.live, now=T0)
        self.assertEqual(first["sessions"], {"aa": None, "bb": None})   # one look cannot tell a share
        self.assertIsNone(first["cpu"])
        # 30 seconds later: the agent used 15 seconds of a processor, the shell none; of 4 processors, 1 was busy
        self.machine(up=1030.0, busy=30 * HZ, idle=90 * HZ, used_kb=5_000_000)
        self.process(101, 100, 120_000, ticks=500 + 15 * HZ)
        self.process(900, 1, 7000, ticks=40 + 3)
        second = self.watch.tick(self.records, self.live, now=T0 + 30)
        self.assertAlmostEqual(second["sessions"]["aa"], 0.5)
        self.assertAlmostEqual(second["sessions"]["bb"], 0.0)
        self.assertAlmostEqual(second["cpu"], 0.25)
        self.assertAlmostEqual(second["engine"]["cpu"], 3 / HZ / 30)
        self.assertEqual(second["engine"]["bytes"], 7000 * PAGE)

    def test_a_process_started_since_counts_whole_and_one_that_ended_takes_nothing_back(self):
        self.process(100, 1, 1000, ticks=10)
        self.process(101, 100, 1000, ticks=900)
        self.watch.tick(self.records, self.live, now=T0)
        self.machine(up=1030.0, busy=0, idle=100, used_kb=4_000_000)
        self.gone(101)                                                    # it ended: its 900 ticks are not owed back
        self.process(102, 100, 1000, ticks=6 * HZ, start=int(1010 * HZ))  # started 20 s ago: all its time is new
        self.process(103, 100, 1000, ticks=99 * HZ, start=5)             # an old process that joined: its past is not ours
        got = self.watch.tick(self.records, self.live, now=T0 + 30)
        self.assertAlmostEqual(got["sessions"]["aa"], 6 / 30)

    def test_a_number_given_again_to_another_process_is_not_mistaken_for_the_old_one(self):
        self.process(100, 1, 1000, ticks=10)
        self.process(101, 100, 1000, ticks=50 * HZ, start=5)
        self.watch.tick(self.records, self.live, now=T0)
        self.machine(up=1030.0, busy=0, idle=100, used_kb=4_000_000)
        self.process(101, 100, 1000, ticks=3 * HZ, start=int(1020 * HZ))  # the same number, a new program
        got = self.watch.tick(self.records, self.live, now=T0 + 30)
        self.assertAlmostEqual(got["sessions"]["aa"], 3 / 30)             # not « minus 47 seconds », and not zero

    # ---------------------------------------------------------------- over time
    def _three_readings(self):
        self.process(100, 1, 100_000, ticks=0)
        self.process(200, 1, 50_000, ticks=0)
        self.watch.tick(self.records, self.live, now=T0)                                   # slice 1
        self.machine(up=1030.0, busy=0, idle=100, used_kb=6_000_000)
        self.process(100, 1, 300_000, ticks=0)
        self.watch.tick(self.records, self.live, now=T0 + 30)                              # slice 1 too, at 60 s a slice
        self.machine(up=1150.0, busy=0, idle=200, used_kb=5_000_000)
        self.gone(200)                                                                     # « Docs refresh » ended
        self.watch.tick(self.records[:1], {"am_aa": self.live["am_aa"]}, now=T0 + 150)     # slice 3: slice 2 had no reading

    def test_slices_start_on_round_times_and_a_time_without_reading_stays_empty(self):
        self._three_readings()
        s = self.watch.series(seconds=180, points=3, now=T0 + 170)
        self.assertEqual(s["step"], 60)
        self.assertEqual(s["t"], [T0, T0 + 60, T0 + 120])
        self.assertEqual(s["readings"], [2, 0, 1])
        self.assertEqual(s["used"], [5_000_000 * 1024, None, 5_000_000 * 1024])            # the average of 4 and 6 GB
        self.assertEqual(s["used_peak"][0], 6_000_000 * 1024)
        self.assertIsNone(s["held"][1])
        self.assertEqual(s["total"], 16_000_000 * 1024)
        self.assertEqual([x["name"] for x in s["sessions"]], ["Checkout flow", "Docs refresh"])
        aa, bb = s["sessions"]
        self.assertEqual(aa["bytes"], [200_000 * PAGE, None, 300_000 * PAGE])
        self.assertEqual(aa["peak"], 300_000 * PAGE)
        self.assertEqual(bb["bytes"], [50_000 * PAGE, None, 0])      # ended: nothing in a slice that was read, its name kept
        self.assertEqual((bb["first"], bb["last"]), (T0, T0 + 30))
        self.assertEqual(s["since"], T0)
        self.assertNotIn("error", s)   # the app reads an answer that holds « error » as a failed call

    def test_the_sessions_of_a_slice_add_up_when_one_started_in_its_middle(self):
        self.process(100, 1, 100_000, ticks=0)
        self.watch.tick(self.records[:1], {"am_aa": self.live["am_aa"]}, now=T0)
        self.machine(up=1030.0, busy=0, idle=100, used_kb=4_000_000)
        self.process(200, 1, 60_000, ticks=0)
        self.watch.tick(self.records, self.live, now=T0 + 30)
        s = self.watch.series(seconds=60, points=1, now=T0 + 59)
        self.assertEqual([x["bytes"] for x in s["sessions"]], [[100_000 * PAGE], [30_000 * PAGE]])   # half the slice: half

    def test_the_asked_span_stays_within_what_is_kept(self):
        self.process(100, 1, 1000, ticks=0)
        self.watch.tick(self.records, self.live, now=T0)
        week = self.watch.series(seconds=10**9, points=168, now=T0 + 10)
        self.assertEqual(week["step"], 3600)
        self.assertEqual(len(week["t"]), 168)
        self.assertEqual(self.watch.series(seconds=1, points=5000, now=T0 + 10)["step"], 30)   # never finer than a reading

    def test_marks_say_when_the_engine_started_reading_and_when_the_computer_started_anew(self):
        self.process(100, 1, 1000, ticks=0)
        self.watch.tick(self.records, self.live, now=T0)
        self.watch.tick(self.records, self.live, now=T0 + 30)
        self.assertEqual(self.watch.series(600, 10, now=T0 + 40)["marks"], [{"ts": T0, "kind": "engine"}])
        # WSL was restarted: another engine reads, 20 seconds after the new start
        self.boot("boot-two")
        self.machine(up=20.0, busy=0, idle=10, used_kb=1_000_000)
        again = host_history.Watch(self.watch.path, 30, proc=self.proc, pid=900)
        got = again.tick(self.records, self.live, now=T0 + 300)
        self.assertEqual(got["sessions"], {"aa": None, "bb": None})
        self.assertEqual(again.series(600, 10, now=T0 + 310)["marks"],
                         [{"ts": T0, "kind": "engine"}, {"ts": T0 + 280, "kind": "boot"}, {"ts": T0 + 300, "kind": "engine"}])

    def test_seven_days_are_kept_and_no_more(self):
        self.process(100, 1, 1000, ticks=0)
        self.watch.tick(self.records, self.live, now=T0)
        self.watch._pruned = 0.0
        self.watch.tick(self.records, self.live, now=T0 + host_history.KEEP + 60)
        about = self.watch.about()
        self.assertEqual((about["readings"], about["since"]), (1, T0 + host_history.KEEP + 60))
        self.assertEqual((about["interval"], about["keep"]), (30, 7 * 86400))

    def test_the_setting(self):
        for raw, want in [("", 30), ("5", 5), ("0", 0), ("off", 0), ("nonsense", 30), ("-3", 0)]:
            with mock.patch.dict(os.environ, {"AGMGD_HOST_SAMPLE": raw}):
                self.assertEqual(host_history.interval_from_env(), want, raw)

    def test_a_reading_that_fails_is_said_and_the_next_one_still_runs(self):
        calls = []

        class Stop(BaseException):
            pass

        def tick(records, live):
            calls.append(1)
            if len(calls) == 1:
                raise OSError("disk full")
            raise Stop()

        sessions = SimpleNamespace(store=SimpleNamespace(all=lambda: []), tmux=SimpleNamespace(sessions=lambda: {}))
        self.watch.interval = 1
        with mock.patch.object(self.watch, "tick", tick), mock.patch.object(host_history.time, "sleep", lambda s: None):
            with self.assertRaises(Stop):
                host_history.run(self.watch, sessions)
        self.assertEqual(self.watch.error, "OSError: disk full")
        self.assertEqual(len(calls), 2)


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class RealHistoryTest(unittest.TestCase):
    """The real /proc under a real session, and the two routes of the local API."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-hist-real-")
        self.tmux = Tmux("agmgd-test-hist", tmpdir=self.tmp)
        self.sessions = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)

    def tearDown(self):
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_busy_session_shows_in_the_readings_and_through_the_api(self):
        busy = self.sessions.create("Busy", "shell", self.tmp)
        quiet = self.sessions.create("Quiet", "shell", self.tmp)
        self.tmux.run("send-keys", "-t", busy["tmux"], "while :; do :; done", "Enter")
        watch = host_history.Watch(os.path.join(self.tmp, "data", "h.sqlite3"), 1)
        self.sessions.host_watch = watch
        time.sleep(0.5)
        watch.tick(self.sessions.store.all(), self.tmux.sessions())
        time.sleep(1.2)
        got = watch.tick(self.sessions.store.all(), self.tmux.sessions())
        self.assertGreater(got["sessions"][busy["id"]], 0.5)     # a loop that never rests takes about one processor
        self.assertLess(got["sessions"][quiet["id"]], 0.2)
        self.assertGreater(got["engine"]["bytes"], 1_000_000)    # this very test, as the engine
        token = load_token(self.tmp)
        srv = serve(self.sessions, token, 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            def get(path):
                req = urllib.request.Request(f"http://127.0.0.1:{srv.server_address[1]}{path}")
                req.add_header("Authorization", "Bearer " + token)
                with urllib.request.urlopen(req, timeout=5) as r:
                    return json.loads(r.read())
            rep = get("/host")
            by = {s["id"]: s for s in rep["sessions"]}
            self.assertGreater(by[busy["id"]]["cpu"], 0.5)
            self.assertGreater(by[busy["id"]]["bytes"], 0)
            self.assertGreater(by[busy["id"]]["created"], time.time() - 60)
            self.assertEqual(by[busy["id"]]["tool"], "shell")
            self.assertEqual(rep["history"]["interval"], 1)
            self.assertEqual(rep["history"]["readings"], 2)
            self.assertGreaterEqual(rep["processors"], 1)
            hist = get("/host/history?seconds=60&points=60")
            self.assertEqual(sorted(s["name"] for s in hist["sessions"]), ["Busy", "Quiet"])
            self.assertEqual(sum(hist["readings"]), 2)
            self.assertGreater(max(x for x in hist["used"] if x is not None), 0)
            self.sessions.host_watch = None                       # the readings are off (AGMGD_HOST_SAMPLE=0)
            self.assertEqual(get("/host/history"), {"off": True})
            self.assertEqual(get("/host")["history"], {})
        finally:
            srv.shutdown()
            srv.server_close()


class HostExtrasTest(unittest.TestCase):
    def test_processor_times_and_load_of_a_place_that_is_not_there(self):
        self.assertEqual(host.cpu_times("/nowhere-at-all"), (0, 0))
        self.assertEqual(host.load("/nowhere-at-all"), 0.0)
        self.assertEqual(host.scan("/nowhere-at-all"), {})


if __name__ == "__main__":
    unittest.main()
