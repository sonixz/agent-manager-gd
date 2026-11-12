"""Engine tests on a real, isolated tmux server (its own socket and TMUX_TMPDIR)."""
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
import urllib.request
from urllib.error import HTTPError

from engine.api import load_token, serve
from engine.sessions import ACTIVE_SECONDS as ACTIVE, Sessions
from engine.store import Store
from engine.tmux import Tmux


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class EngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-test-")
        self.tmux = Tmux("agmgd-test", tmpdir=self.tmp)
        self.sessions = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)

    def tearDown(self):
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def wait_for(self, sid, needle, sec=5.0):
        end = time.time() + sec
        while time.time() < end:
            if needle in self.sessions.preview(sid):
                return True
            time.sleep(0.1)
        return False

    def test_a_session_runs_in_tmux_and_outlives_its_records_reader(self):
        s = self.sessions.create("Shell é", "shell", self.tmp)
        self.assertEqual(s["state"], "running")
        self.assertTrue(s["tmux"].startswith("am_"))
        # a new engine (the app reopened) sees the same session alive
        again = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), Tmux("agmgd-test", tmpdir=self.tmp), self.tmp)
        self.assertEqual([x["state"] for x in again.list()], ["running"])
        self.assertEqual(again.list()[0]["name"], "Shell é")

    def test_text_sent_reaches_the_program_with_accents(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.sessions.send(s["id"], "echo déjà « vu » — ok")
        self.assertTrue(self.wait_for(s["id"], "déjà « vu » — ok"))

    def test_a_finished_program_keeps_its_last_screen_and_restarts(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.sessions.send(s["id"], "echo last words; exit")
        end = time.time() + 5
        while self.sessions.get(s["id"])["state"] != "exited" and time.time() < end:
            time.sleep(0.1)
        self.assertEqual(self.sessions.get(s["id"])["state"], "exited")
        self.assertIn("last words", self.sessions.preview(s["id"]))
        self.assertEqual(self.sessions.restart(s["id"])["state"], "running")

    def test_a_session_gone_from_tmux_is_missing_and_comes_back(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.tmux.kill_server()  # a reboot
        self.assertEqual(self.sessions.get(s["id"])["state"], "missing")
        self.assertEqual(self.sessions.restart(s["id"])["state"], "running")

    def test_folders_picked_from_windows_become_wsl_paths(self):
        from engine.sessions import host_path
        self.assertEqual(host_path("\\\\wsl.localhost\\Ubuntu\\home\\py\\proj"), "/home/py/proj")
        self.assertEqual(host_path("//wsl$/Ubuntu-24.04/home/py"), "/home/py")
        self.assertEqual(host_path("~/x"), "~/x")
        if os.path.isdir("/mnt/c"):
            self.assertEqual(host_path("C:/git-2026/gd-project"), "/mnt/c/git-2026/gd-project")

    def test_remote_control_is_remembered_and_named_for_claude_ai(self):
        rec = self.sessions.store.add("Site redesign", "claude", self.tmp, "GD Project")
        self.sessions.store.update(rec["id"], remote_control=1)
        rec = self.sessions.store.get(rec["id"])
        cmd = self.sessions.command_for(rec)
        self.assertIn("--remote-control", cmd)
        self.assertEqual(cmd[cmd.index("--remote-control") + 1], "GD Project · Site redesign")
        resumed = self.sessions.command_for(rec, "resume", "abc")            # a restart keeps it
        self.assertIn("--remote-control", resumed)
        plain = self.sessions.store.add("No remote", "claude", self.tmp)
        self.assertNotIn("--remote-control", self.sessions.command_for(plain))

    def test_a_stale_working_state_falls_back_to_idle(self):
        from types import SimpleNamespace
        s = self.sessions.create("Claude-like", "shell", self.tmp)
        rec = dict(self.sessions.store.get(s["id"]), tool="claude")
        old = time.time() - 60
        t = SimpleNamespace(activity=old, pane_command="claude")
        state, msg = self.sessions.activity(rec, t, {"state": "working", "time": old})
        self.assertEqual(state, "idle")                                       # no « esc to interrupt », quiet for a minute
        # the screen redraws (full-screen mode) but no « esc to interrupt »: still idle
        state, _ = self.sessions.activity(rec, SimpleNamespace(activity=time.time(), pane_command="claude"), {"state": "working", "time": old})
        self.assertEqual(state, "idle")
        # a fresh « working » from the hooks is trusted
        state, _ = self.sessions.activity(rec, SimpleNamespace(activity=time.time(), pane_command="claude"), {"state": "working", "time": time.time()})
        self.assertEqual(state, "working")
        # an old « working » with Claude Code's busy sign on screen: still working (a long command)
        self.sessions.send(s["id"], "echo 'Thinking… (esc to interrupt)'")
        self.assertTrue(self.wait_for(s["id"], "esc to interrupt"))
        state, _ = self.sessions.activity(rec, SimpleNamespace(activity=time.time(), pane_command="claude"), {"state": "working", "time": old})
        self.assertEqual(state, "working")

    def test_attach_command_names_the_private_server(self):
        s = self.sessions.create("t", "shell", self.tmp)
        cmd = self.sessions.attach_command(s["id"])
        self.assertIn("-L", cmd)
        self.assertIn("agmgd-test", cmd)
        self.assertEqual(cmd[-1], s["tmux"])

    def test_named_keys_only(self):
        s = self.sessions.create("k", "shell", self.tmp)
        self.sessions.send(s["id"], "read -r x; echo got:$x", enter=True)
        time.sleep(0.8)
        self.sessions.send(s["id"], "yes", enter=False)
        self.sessions.keys(s["id"], ["Enter"])
        self.assertTrue(self.wait_for(s["id"], "got:yes"))
        with self.assertRaises(ValueError):
            self.sessions.keys(s["id"], ["C-c; kill-server"])

    def test_bad_input_is_refused(self):
        with self.assertRaises(ValueError):
            self.sessions.create("t", "rm -rf", self.tmp)
        with self.assertRaises(ValueError):
            self.sessions.create("t", "shell", os.path.join(self.tmp, "nope"))
        with self.assertRaises(ValueError):
            self.sessions.create("", "shell", self.tmp)

    def test_windows_paths_become_wsl_paths(self):
        from engine.sessions import host_path
        if os.path.isdir("/mnt/c"):
            self.assertEqual(host_path("C:\\git-2026\\agent-manager-gd"), "/mnt/c/git-2026/agent-manager-gd")
            self.assertEqual(host_path("c:/Users"), "/mnt/c/Users")
        self.assertEqual(host_path("/home/x"), "/home/x")
        self.assertEqual(host_path("~"), "~")

    def test_remove_kills_and_forgets(self):
        s = self.sessions.create("t", "shell", self.tmp)
        self.sessions.remove(s["id"])
        self.assertEqual(self.sessions.list(), [])
        self.assertNotIn(s["tmux"], self.tmux.sessions())

    def test_the_project_tree_keeps_groups_order_and_folding(self):
        a = self.sessions.create("a", "shell", self.tmp, grp="Brain")
        b = self.sessions.create("b", "shell", self.tmp, grp="Brain")
        c = self.sessions.create("c", "shell", self.tmp, grp="TTS")
        loose = self.sessions.create("loose", "shell", self.tmp)
        self.sessions.move(b["id"], "Brain", 0)              # reorder inside a group
        self.sessions.move(loose["id"], "TTS", 1)            # into another group, after c
        self.sessions.store.order_groups(["TTS", "Brain"])
        self.sessions.store.fold_group("Brain", True)
        # a new engine (the app reopened) sees the same tree
        again = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), Tmux("agmgd-test", tmpdir=self.tmp), self.tmp)
        tree = again.tree()["groups"]
        self.assertEqual([g["name"] for g in tree], ["", "TTS", "Brain"])
        self.assertEqual([s["name"] for s in tree[1]["sessions"]], ["c", "loose"])
        self.assertEqual([s["name"] for s in tree[2]["sessions"]], ["b", "a"])
        self.assertTrue(tree[2]["folded"])
        self.sessions.store.rename_group("TTS", "Ticket System")
        self.assertEqual(self.sessions.get(c["id"])["grp"], "Ticket System")
        self.sessions.store.delete_group("Ticket System")    # sessions stay, ungrouped
        names = [s["name"] for s in self.sessions.tree()["groups"][0]["sessions"]]
        self.assertEqual(names, ["c", "loose"])
        self.assertEqual(len(self.sessions.list()), 4)

    def test_the_first_session_of_a_fresh_tmux_server_comes_with_its_start_and_is_asked_again_if_it_was_dying(self):
        calls, run = [], self.tmux.run

        def dying_once(*args, **kw):
            if "new-session" in args:
                calls.append(args)
                if len(calls) == 1:
                    raise RuntimeError("tmux start-server: server exited unexpectedly")
            return run(*args, **kw)
        self.tmux.run = dying_once
        try:
            s = self.sessions.create("again", "shell", self.tmp)
        finally:
            self.tmux.run = run
        self.assertEqual(s["state"], "running")
        self.assertEqual(len(calls), 2)                 # asked again, once
        self.assertEqual(calls[1][0], "start-server")   # the server's start and the session in one tmux call
        with self.assertRaises(RuntimeError) as e:      # any other refusal is raised as it is
            self.tmux.new_session(s["tmux"], self.tmp, [])
        self.assertIn("duplicate session", str(e.exception))

    def test_several_screens_are_read_in_one_tmux_call(self):
        a = self.sessions.create("a", "shell", self.tmp)
        b = self.sessions.create("b", "shell", self.tmp)
        self.sessions.send(a["id"], "echo screen-of-a")
        self.sessions.send(b["id"], "echo screen-of-b")
        self.assertTrue(self.wait_for(a["id"], "screen-of-a") and self.wait_for(b["id"], "screen-of-b"))
        calls, run = [], self.tmux.run
        self.tmux.run = lambda *args, **kw: (calls.append(args), run(*args, **kw))[1]
        try:
            got = self.tmux.screens([a["tmux"], b["tmux"]])
        finally:
            self.tmux.run = run
        self.assertEqual(len(calls), 1)
        self.assertIn("screen-of-a", got[a["tmux"]])
        self.assertNotIn("screen-of-b", got[a["tmux"]])
        self.assertIn("screen-of-b", got[b["tmux"]])
        # a session that is gone is absent from the answer, and so are those after it: the caller reads those itself
        self.assertEqual(list(self.tmux.screens([a["tmux"], "am_gone", b["tmux"]])), [a["tmux"]])
        self.assertEqual(self.tmux.screens([]), {})

    def test_the_list_looks_everybody_up_together(self):
        lead = self.sessions.create("lead", "shell", self.tmp)
        kid = self.sessions.create("kid", "shell", self.tmp, parent=lead["id"])
        self.sessions.store.touch_conversation(kid["id"], "claude", "conv-old")
        self.sessions.store.touch_conversation(kid["id"], "claude", "conv-new")
        one_by_one = {sid: self.sessions.get(sid) for sid in (lead["id"], kid["id"])}
        gets, get = [], self.sessions.store.get
        self.sessions.store.get = lambda sid: (gets.append(sid), get(sid))[1]
        try:
            listed = {s["id"]: s for s in self.sessions.list()}
        finally:
            self.sessions.store.get = get
        self.assertEqual(gets, [])  # no record is fetched one by one: the list already holds them all
        self.assertEqual(listed[kid["id"]]["last_conversation"], "conv-new")
        self.assertEqual(listed[lead["id"]]["last_conversation"], "")
        for sid, alone in one_by_one.items():  # and it says what each session says when asked alone
            for key in ("name", "parent", "git_rights", "last_conversation", "level", "access", "state"):
                self.assertEqual(listed[sid][key], alone[key], key)

    def test_a_conversation_is_marked_seen_once_a_minute_not_at_every_refresh(self):
        s = self.sessions.create("c", "shell", self.tmp)
        rec = {**self.sessions.store.get(s["id"]), "tool": "claude"}
        self.run_hook(s["id"], "claude", {"hook_event_name": "SessionStart", "session_id": "conv-1"})
        writes, touch = [], self.sessions.store.touch_conversation
        self.sessions.store.touch_conversation = lambda *a: (writes.append(a[2]), touch(*a))[1]
        try:
            for _ in range(3):  # three refreshes
                self.sessions.describe(rec, self.tmux.sessions())
            self.assertEqual(writes, ["conv-1"])  # written at once, then not again within the minute
            self.run_hook(s["id"], "claude", {"hook_event_name": "SessionStart", "session_id": "conv-2"})
            self.sessions.describe(rec, self.tmux.sessions())
            self.assertEqual(writes, ["conv-1", "conv-2"])  # a new conversation is written at once
            self.sessions._conv_seen[(s["id"], "conv-2")] -= 61  # a minute later
            self.sessions.describe(rec, self.tmux.sessions())
            self.assertEqual(writes, ["conv-1", "conv-2", "conv-2"])
        finally:
            self.sessions.store.touch_conversation = touch
        self.assertEqual(self.sessions.last_conversation(s["id"]), "conv-2")

    def run_hook(self, sid, tool, payload):
        import subprocess, sys
        from engine.sessions import HOOK
        env = {**os.environ, "AGMGD_SESSION": sid, "AGMGD_HOME": self.tmp}
        args = [sys.executable, HOOK, tool] + ([json.dumps(payload)] if tool == "codex" else [])
        out = subprocess.run(args, input=json.dumps(payload) if tool == "claude" else "", capture_output=True,
                             text=True, env=env, timeout=10)
        self.assertEqual((out.returncode, out.stdout), (0, ""))  # silent, never fails

    def test_claude_hooks_drive_the_live_state(self):
        s = self.sessions.create("c", "shell", self.tmp)
        self.sessions.store.update(s["id"])  # no-op
        rec = {**self.sessions.store.get(s["id"]), "tool": "claude"}
        steps = [({"hook_event_name": "SessionStart", "session_id": "conv-1"}, "idle"),
                 ({"hook_event_name": "UserPromptSubmit", "prompt": "x"}, "working"),
                 ({"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"}, "approval"),
                 ({"hook_event_name": "PreToolUse", "tool_name": "Bash"}, "working"),
                 ({"hook_event_name": "Stop"}, "done"),
                 # the idle reminder about 60 s after a turn is not a question: still done (before: « waiting »)
                 ({"hook_event_name": "Notification", "message": "Claude is waiting for your input"}, "done"),
                 ({"hook_event_name": "Notification", "message": "Claude is waiting for your input",
                   "notification_type": "idle_prompt"}, "done"),
                 ({"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash",
                   "notification_type": "permission_prompt"}, "approval"),
                 ({"hook_event_name": "Notification", "message": "MCP server requests input",
                   "notification_type": "elicitation_dialog"}, "waiting"),
                 ({"hook_event_name": "Notification", "message": "Signed in", "notification_type": "auth_success"}, "waiting"),
                 ({"hook_event_name": "Notification", "message": "", "notification_type": "elicitation_response"}, "working")]
        for payload, want in steps:
            self.run_hook(s["id"], "claude", payload)
            live = self.tmux.sessions()
            got = self.sessions.describe(rec, live)
            self.assertEqual(got["activity"], want, payload)
        self.assertEqual(got["conversation"], "conv-1")  # kept for resuming (Loop 5)

    def test_an_answer_from_the_app_unsticks_an_approval_until_the_next_request(self):
        s = self.sessions.create("c", "shell", self.tmp)
        rec = {**self.sessions.store.get(s["id"]), "tool": "claude"}
        self.run_hook(s["id"], "claude", {"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"})
        self.assertEqual(self.sessions.describe(rec)["activity"], "approval")
        time.sleep(0.05)
        self.sessions.keys(s["id"], ["Enter"])                    # Approve: Claude Code says nothing until the tool ends
        d = self.sessions.describe(rec)
        self.assertEqual((d["activity"], d["message"]), ("working", ""))
        time.sleep(0.05)
        self.run_hook(s["id"], "claude", {"hook_event_name": "Notification", "message": "Claude needs your permission to use Write"})
        self.assertEqual(self.sessions.describe(rec)["activity"], "approval")   # a new request comes back at once

    def test_a_question_clears_when_the_owner_answers_in_the_terminal(self):
        # the owner typed the answer straight into the orchestrator's terminal: no reply from the app, yet the
        # question must clear (before: « waits for an answer » stayed while it worked again)
        s = self.sessions.create("orch", "shell", self.tmp)
        rec = {**self.sessions.store.get(s["id"]), "tool": "claude"}
        self.run_hook(s["id"], "claude", {"hook_event_name": "UserPromptSubmit", "session_id": "c1"})  # an older prompt
        time.sleep(0.05)
        self.sessions.ask_owner(s["id"], "Plan: 2 tasks. OK?", ["Yes", "No"])
        self.run_hook(s["id"], "claude", {"hook_event_name": "PostToolUse"})   # ask_owner's own tool call ends
        self.run_hook(s["id"], "claude", {"hook_event_name": "Stop"})          # it stops and waits
        d = self.sessions.describe(rec)
        self.assertEqual((d["activity"], d["message"]), ("waiting", "Plan: 2 tasks. OK?  [Yes / No]"))
        self.run_hook(s["id"], "claude", {"hook_event_name": "UserPromptSubmit"})  # « Yes », typed in its terminal
        self.run_hook(s["id"], "claude", {"hook_event_name": "PreToolUse"})        # then it works (start_session…)
        d = self.sessions.describe(rec)
        self.assertEqual(d["activity"], "working")
        self.assertNotIn(s["id"], self.sessions._questions)
        # a review request (finish_session) is not an ask_owner question: only Finish or a reply clears it
        child = self.sessions.create("task", "shell", self.tmp, parent=s["id"])
        self.sessions.ready_for_review(child["id"], s["id"], "done")
        self.run_hook(child["id"], "claude", {"hook_event_name": "UserPromptSubmit"})
        crec = {**self.sessions.store.get(child["id"]), "tool": "claude"}
        self.assertEqual(self.sessions.describe(crec)["activity"], "waiting")

    def as_claude(self, sid):
        """A real tmux session (a shell) recorded as Claude Code, so nothing real is launched."""
        from contextlib import closing
        with closing(self.sessions.store._db()) as db, db:
            db.execute("UPDATE sessions SET tool = 'claude' WHERE id = ?", (sid,))

    def test_the_owner_changes_a_level_and_it_applies_on_the_same_conversation(self):
        relaunched = []
        self.sessions.tmux.respawn = lambda name, cwd, cmd: relaunched.append(cmd)
        lead = self.sessions.create("Lead", "shell", self.tmp)
        kid = self.sessions.create("Kid", "shell", self.tmp, parent=lead["id"], level="auto")
        for x in (lead, kid):
            self.as_claude(x["id"])
        self.sessions.store.touch_conversation(lead["id"], "claude", "conv-lead")
        for x in (lead, kid):
            self.run_hook(x["id"], "claude", {"hook_event_name": "SessionStart"})      # ready, nothing asked
        # idle: « Apply and restart » resumes at once, same conversation, new flags
        r = self.sessions.set_level(lead["id"], "ask", "turn")
        self.assertEqual((r["was"], r["level"], r["applied"]), ("auto", "ask", "restarted"))
        cmd = relaunched[0]                                                     # itself first, then its child
        self.assertEqual(cmd[cmd.index("--permission-mode") + 1], "default")
        self.assertEqual(cmd[cmd.index("--resume") + 1], "conv-lead")
        self.assertEqual(r["lowered"], [kid["id"]])                              # its child came down with it
        self.assertEqual(self.sessions.store.get(kid["id"])["level"], "ask")
        self.assertEqual(relaunched[1][relaunched[1].index("--permission-mode") + 1], "default")   # it restarted too
        # a child never above its parent, and never « per my config »
        with self.assertRaises(ValueError):
            self.sessions.set_level(kid["id"], "full")
        with self.assertRaises(ValueError):
            self.sessions.set_level(kid["id"], "config")
        # working: it waits for the end of its turn, then restarts by itself
        self.run_hook(lead["id"], "claude", {"hook_event_name": "PreToolUse"})
        n = len(relaunched)
        r = self.sessions.set_level(lead["id"], "config", "turn")
        self.assertEqual(r["applied"], "at the end of its turn")
        self.assertTrue(self.sessions.get(lead["id"])["level_pending"])
        self.assertEqual(len(relaunched), n)
        self.run_hook(lead["id"], "claude", {"hook_event_name": "Stop"})
        self.sessions.get(lead["id"])                                             # the app's next look applies it
        self.assertEqual(len(relaunched), n + 1)
        self.assertNotIn("--permission-mode", relaunched[-1])                      # « per my config »: no level option
        self.assertNotIn("--dangerously-skip-permissions", relaunched[-1])
        self.assertFalse(self.sessions.get(lead["id"])["level_pending"])
        # « next start » changes nothing now; every change is logged
        self.sessions.set_level(lead["id"], "edits", "next")
        self.assertEqual(len(relaunched), n + 1)
        self.assertEqual([e["level"] for e in self.sessions.level_log(lead["id"])],
                         [["auto", "ask"], ["ask", "config"], ["config", "edits"]])
        # a shell has no level; the engine's API token is out of reach of the agents' file tools
        sh = self.sessions.create("sh", "shell", self.tmp)
        with self.assertRaises(ValueError):
            self.sessions.set_level(sh["id"], "ask")
        self.assertIn("Read(/" + os.path.join(os.path.abspath(self.tmp), "runtime") + "/**)", self.sessions.deny_rules())

    def test_the_owner_enables_git_push_for_one_session(self):
        relaunched = []
        self.sessions.tmux.respawn = lambda name, cwd, cmd: relaunched.append(cmd)
        orch = self.sessions.create("Orchestrator", "shell", self.tmp, role="orchestrator")
        worker = self.sessions.create("Worker", "shell", self.tmp, parent=orch["id"])
        mine = self.sessions.create("Mine", "shell", self.tmp)
        for x in (orch, worker, mine):
            self.as_claude(x["id"])
            self.run_hook(x["id"], "claude", {"hook_event_name": "SessionStart"})
        deny = lambda sid: self.sessions.deny_rules(self.sessions.store.get(sid))  # noqa: E731
        # by default: the orchestrator's sessions may not push nor merge, a session the owner started may
        self.assertIn("Bash(git push *)", deny(worker["id"]))
        self.assertIn("Bash(git merge *)", deny(worker["id"]))
        self.assertNotIn("Bash(git push *)", deny(mine["id"]))
        self.assertEqual(self.sessions.get(worker["id"])["git_rights"], {"push": False, "merge": False, "default": False})
        # « Enable git push »: the push rules go, merge and rebase stay refused; it restarts on its conversation
        r = self.sessions.set_permissions(worker["id"], git_push=True)
        self.assertEqual((r["git"]["push"], r["git"]["merge"], r["applied"]), (True, False, "restarted"))
        self.assertNotIn("Bash(git push *)", deny(worker["id"]))
        self.assertNotIn("Bash(git push)", deny(worker["id"]))
        self.assertIn("Bash(git rebase *)", deny(worker["id"]))
        with open(relaunched[-1][2], encoding="utf-8") as f:                  # the native JSON it starts with
            self.assertNotIn("Bash(git push *)", json.load(f)["permissions"]["deny"])
        self.assertIn("Bash(git push *)", deny(orch["id"]))                    # its parent keeps its own rights
        # the owner can also refuse it to a session of their own; level and git change in one restart
        n = len(relaunched)
        r = self.sessions.set_permissions(mine["id"], level="ask", git_push=False, git_merge=False)
        self.assertEqual(len(relaunched), n + 1)
        self.assertIn("Bash(git push *)", deny(mine["id"]))
        self.assertEqual(self.sessions.store.get(mine["id"])["level"], "ask")
        self.assertEqual([list(e) for e in self.sessions.level_log(mine["id"])][0][2], "git")
        sh = self.sessions.create("sh", "shell", self.tmp)
        with self.assertRaises(ValueError):
            self.sessions.set_permissions(sh["id"], git_push=True)

    def test_file_access_presets_fill_the_native_settings(self):
        relaunched = []
        self.sessions.tmux.respawn = lambda name, cwd, cmd: relaunched.append(cmd)
        extra, docs = tempfile.mkdtemp(prefix="agmgd-extra-"), tempfile.mkdtemp(prefix="agmgd-docs-")  # outside its data
        for d in (extra, docs):
            self.addCleanup(shutil.rmtree, d, True)

        def perms(sid):
            with open(self.sessions.command_for({**self.sessions.store.get(sid), "tool": "claude"})[2], encoding="utf-8") as f:
                return json.load(f)["permissions"]
        lead = self.sessions.create("Lead", "shell", self.tmp)
        self.as_claude(lead["id"])
        self.run_hook(lead["id"], "claude", {"hook_event_name": "SessionStart"})
        p = perms(lead["id"])                                                     # open: nothing added (today's behaviour)
        self.assertNotIn("blockReadsOutsideWorkingDirectories", p)
        self.assertNotIn("additionalDirectories", p)
        # contained, with one extra folder read and write and one read only: Claude Code's own keys
        r = self.sessions.set_permissions(lead["id"], access="contained",
                                          extra_dirs=[{"path": extra, "write": True}, {"path": docs, "write": False}])
        self.assertEqual((r["access"], r["applied"]), ("contained", "restarted"))
        p = perms(lead["id"])
        self.assertTrue(p["blockReadsOutsideWorkingDirectories"] and p["blockWritesOutsideWorkingDirectories"])
        self.assertEqual(p["additionalDirectories"], [extra, docs])
        self.assertIn(f"Edit(/{docs}/**)", p["deny"])
        self.assertNotIn(f"Edit(/{extra}/**)", p["deny"])
        self.assertIn("Read(~/.ssh/**)", p["deny"])                                # the fixed rules stay
        # read only: no edit in its own folder either
        self.sessions.set_permissions(lead["id"], access="readonly")
        self.assertIn(f"Edit(/{os.path.abspath(self.tmp)}/**)", perms(lead["id"])["deny"])
        # a child is never less restricted than its parent; Codex read only is its own sandbox
        kid = self.sessions.create("Kid", "shell", self.tmp, parent=lead["id"], access="open")
        self.assertEqual(self.sessions.store.get(kid["id"])["access"], "readonly")
        with self.assertRaises(ValueError):
            self.as_claude(kid["id"])
            self.sessions.set_permissions(kid["id"], access="open")
        codex = self.sessions.command_for({**self.sessions.store.get(lead["id"]), "tool": "codex", "level": "full"})
        self.assertIn("read-only", codex)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", codex)
        # Agent Manager's own data and missing folders are refused
        for bad in ([{"path": self.tmp}], [{"path": os.path.join(self.tmp, "nope")}]):
            with self.assertRaises(ValueError):
                self.sessions.set_permissions(lead["id"], extra_dirs=bad)
        self.assertEqual([e.get("access") for e in self.sessions.level_log(lead["id"])], [["open", "contained"], ["contained", "readonly"]])

    def test_claude_codes_own_sandbox_is_offered_only_when_it_can_run(self):
        from unittest import mock
        import engine.sessions as es
        self.sessions.tmux.respawn = lambda name, cwd, cmd: None
        lead = self.sessions.create("Lead", "shell", self.tmp)
        self.as_claude(lead["id"])
        self.run_hook(lead["id"], "claude", {"hook_event_name": "SessionStart"})

        def settings(sid):
            with open(self.sessions.command_for({**self.sessions.store.get(sid), "tool": "claude"})[2], encoding="utf-8") as f:
                return json.load(f)
        # without bubblewrap and socat: refused, with how to install them; nothing is written
        with mock.patch.object(es.shutil, "which", return_value=None):
            info = self.sessions.native_sandbox()
            self.assertEqual((info["available"], info["missing"]), (False, ["bwrap", "socat"]))
            self.assertEqual(info["install"], "sudo apt-get install bubblewrap socat")
            with self.assertRaises(ValueError):
                self.sessions.set_permissions(lead["id"], os_sandbox=True)
        self.assertNotIn("sandbox", settings(lead["id"]))
        # with them: contained by the system, never a silent fallback, its home closed except its folder
        with mock.patch.object(es.shutil, "which", return_value="/usr/bin/x"), mock.patch.object(es.sys, "platform", "linux"):
            self.assertTrue(self.sessions.native_sandbox()["available"])
            self.sessions.set_permissions(lead["id"], access="contained")
            r = self.sessions.set_permissions(lead["id"], os_sandbox=True)
            self.assertTrue(r["os_sandbox"])
            sb = settings(lead["id"])["sandbox"]
            self.assertEqual((sb["enabled"], sb["failIfUnavailable"], sb["allowUnsandboxedCommands"]), (True, True, False))
            self.assertIn("~/", sb["filesystem"]["denyRead"])
            self.assertIn("~/.ssh", sb["filesystem"]["denyRead"])
            self.assertEqual(sb["filesystem"]["allowRead"], [os.path.abspath(self.tmp)])
            self.assertNotIn("denyWrite", sb["filesystem"])
            self.sessions.set_permissions(lead["id"], access="readonly")
            self.assertEqual(settings(lead["id"])["sandbox"]["filesystem"]["denyWrite"], [os.path.abspath(self.tmp)])
            # its child is contained too, and cannot be taken out
            kid = self.sessions.create("Kid", "shell", self.tmp, parent=lead["id"])
            self.assertTrue(self.sessions.store.get(kid["id"])["os_sandbox"])
            self.as_claude(kid["id"])
            with self.assertRaises(ValueError):
                self.sessions.set_permissions(kid["id"], os_sandbox=False)
            self.assertTrue(self.sessions.get(lead["id"])["os_sandbox"])

    def test_the_agent_permissions_overview_and_a_groups_default_file_access(self):
        self.sessions.store.set_group_access("Careful", "contained")
        a = self.sessions.create("In careful", "shell", self.tmp, grp="Careful")
        b = self.sessions.create("Elsewhere", "shell", self.tmp)
        self.assertEqual(self.sessions.store.get(a["id"])["access"], "contained")   # the group's default
        self.assertEqual(self.sessions.store.get(b["id"])["access"], "open")
        self.assertEqual(self.sessions.store.get(
            self.sessions.create("Asked", "shell", self.tmp, grp="Careful", access="readonly")["id"])["access"], "readonly")
        orch = self.sessions.create("Orchestrator", "shell", self.tmp, role="orchestrator")
        worker = self.sessions.create("Worker", "shell", self.tmp, parent=orch["id"])
        for x in (a, orch, worker):
            self.as_claude(x["id"])
        ov = self.sessions.permissions_overview()
        rows = {r["name"]: r for r in ov["agents"]}
        self.assertNotIn("Elsewhere", rows)                                  # shells have no permissions to show
        self.assertEqual((rows["In careful"]["access"], rows["In careful"]["level"]), ("contained", "auto"))
        self.assertFalse(rows["Worker"]["git_rights"]["push"])
        self.assertTrue(rows["In careful"]["git_rights"]["push"])
        self.assertEqual(ov["groups"], [{"name": "Careful", "level": "", "access": "contained"}])
        self.assertIn("available", ov["claude_sandbox"])

    def test_permission_levels_flags_denied_paths_group_default_and_child_cap(self):
        from engine.sessions import LEVEL_FLAGS
        cmd = self.sessions.command_for({"id": "lv000001", "tool": "claude", "level": "full"})
        self.assertIn("--dangerously-skip-permissions", cmd)
        with open(cmd[2], encoding="utf-8") as f:
            deny = json.load(f)["permissions"]["deny"]
        for rule in ("Read(~/.ssh/**)", "Edit(~/.ssh/**)", "Read(**/.env)", "Read(**/.env.keys)"):
            self.assertIn(rule, deny)                                       # at every level, « No permission » too
        self.assertIn("Read(/" + os.path.join(os.path.abspath(self.tmp), "keys") + "/**)", deny)   # //absolute: our keys
        self.assertEqual(self.sessions.command_for({"id": "lv000002", "tool": "claude"})[3:5], ["--permission-mode", "auto"])
        codex = self.sessions.command_for({"id": "lv000003", "tool": "codex", "level": "ask"})
        self.assertEqual(codex[3:7], LEVEL_FLAGS["codex"]["ask"])
        # the group's default, then a child never above its parent
        self.sessions.store.set_group_level("Careful", "ask")
        self.assertEqual(self.sessions.level_for("", "Careful"), "ask")
        self.assertEqual(self.sessions.level_for("", "Other"), "auto")
        parent = self.sessions.create("lead", "shell", self.tmp, grp="Careful")
        self.assertEqual(parent["level"], "ask")
        child = self.sessions.create("helper", "shell", self.tmp, parent=parent["id"], level="full")
        self.assertEqual(child["level"], "ask")
        with self.assertRaises(ValueError):
            self.sessions.level_for("root")

    def test_codex_notify_and_terminal_activity(self):
        s = self.sessions.create("x", "shell", self.tmp)
        rec = {**self.sessions.store.get(s["id"]), "tool": "codex"}
        # the shell's first prompt can come late under load: wait until the terminal has been quiet long enough
        end = time.time() + 15
        while self.sessions.describe(rec)["activity"] != "idle" and time.time() < end:
            time.sleep(0.3)
        self.assertEqual(self.sessions.describe(rec)["activity"], "idle")
        self.run_hook(s["id"], "codex", {"type": "agent-turn-complete", "thread-id": "t-9", "last-assistant-message": "Fini."})
        d = self.sessions.describe(rec)
        self.assertEqual((d["activity"], d["message"], d["conversation"]), ("done", "Fini.", "t-9"))

    def test_a_shell_running_a_program_is_working(self):
        s = self.sessions.create("sh", "shell", self.tmp)
        self.sessions.send(s["id"], "sleep 3")
        end = time.time() + 3
        while self.sessions.get(s["id"])["activity"] != "working" and time.time() < end:
            time.sleep(0.1)
        self.assertEqual(self.sessions.get(s["id"])["activity"], "working")

    def test_claude_is_launched_with_its_own_hooks_only(self):
        rec = {"id": "abcd1234", "tool": "claude"}
        cmd = self.sessions.command_for(rec)
        self.assertEqual(cmd[:2], ["claude", "--settings"])
        with open(cmd[2], encoding="utf-8") as f:
            hooks = json.load(f)["hooks"]
        self.assertIn("Stop", hooks)
        self.assertTrue(cmd[2].startswith(self.tmp))  # in our data folder, never ~/.claude
        codex = self.sessions.command_for({"id": "x", "tool": "codex"})
        self.assertTrue(codex[2].startswith("notify=["))

    @unittest.skipUnless(os.environ.get("AGMGD_TEST_CLAUDE_DIR"), "set AGMGD_TEST_CLAUDE_DIR to a folder Claude Code trusts")
    def test_real_claude_reports_session_start(self):
        """Starts the real Claude Code (no prompt, no cost): its SessionStart hook must reach the engine."""
        s = self.sessions.create("real", "claude", os.environ["AGMGD_TEST_CLAUDE_DIR"])
        end = time.time() + 30
        while not self.sessions.get(s["id"])["conversation"] and time.time() < end:
            time.sleep(0.3)
        d = self.sessions.get(s["id"])
        self.assertEqual(d["activity"], "idle")
        self.assertTrue(d["conversation"])

    def test_the_api_needs_its_token(self):
        token = load_token(self.tmp)
        self.assertEqual(oct(os.stat(os.path.join(self.tmp, "runtime", "api_token")).st_mode & 0o777), "0o600")
        srv = serve(self.sessions, token, 0)
        port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            def call(method, path, body=None, auth=True):
                req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method,
                                             data=json.dumps(body).encode() if body is not None else None)
                if auth:
                    req.add_header("Authorization", "Bearer " + token)
                with urllib.request.urlopen(req, timeout=5) as r:
                    return r.status, json.loads(r.read())
            self.assertEqual(call("GET", "/health", auth=False)[0], 200)
            with self.assertRaises(HTTPError) as e:
                call("GET", "/sessions", auth=False)
            self.assertEqual(e.exception.code, 401)
            code, made = call("POST", "/sessions", {"name": "API", "tool": "shell", "cwd": self.tmp})
            self.assertEqual((code, made["state"]), (201, "running"))
            self.assertEqual(call("GET", "/sessions")[1]["sessions"][0]["id"], made["id"])
            self.assertIn("attach-session", call("GET", f"/sessions/{made['id']}/attach")[1]["command"])
            with self.assertRaises(HTTPError) as e:
                call("POST", "/sessions", {"name": "x", "tool": "nope", "cwd": self.tmp})
            self.assertEqual(e.exception.code, 400)
            self.assertEqual(call("DELETE", f"/sessions/{made['id']}")[1], {"ok": True})
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main()
