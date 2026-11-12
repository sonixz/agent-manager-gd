"""Loop 36: engine/setup_install.sh, with a stand-in for apt-get (nothing is installed)."""
import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "engine", "setup_install.sh")


class SetupInstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-install-")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.tmp, "calls")
        self._apt("exit 0")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _apt(self, end):
        path = os.path.join(self.bin, "apt-get")
        with open(path, "w") as f:
            f.write(f'#!/bin/sh\necho "$DEBIAN_FRONTEND|$*" >> "{self.log}"\n{end}\n')
        os.chmod(path, 0o755)

    def _run(self, *names, path=None):
        env = {"PATH": path if path is not None else self.bin + ":/usr/bin:/bin"}
        return subprocess.run(["bash", SCRIPT, *names], capture_output=True, text=True, env=env, timeout=20)

    def _calls(self):
        return open(self.log).read().splitlines() if os.path.exists(self.log) else []

    def test_updates_then_installs_the_names_given(self):
        r = self._run("tmux", "git")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._calls(), ["noninteractive|update", "noninteractive|install -y tmux git"])
        self.assertIn("Installed: tmux git", r.stdout)

    def test_refuses_a_name_that_is_not_one_of_the_four(self):
        for bad in (["tmux", "curl"], ["--allow-unauthenticated"], ["tmux; rm -rf x"], ["../x"]):
            r = self._run(*bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertEqual(self._calls(), [], bad)          # the package manager was not even started

    def test_nothing_asked_nothing_done(self):
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self._calls(), [])

    def test_a_failed_update_installs_nothing(self):
        self._apt('[ "$1" = update ] && exit 100; exit 0')
        r = self._run("tmux")
        self.assertEqual(r.returncode, 100)
        self.assertEqual(self._calls(), ["noninteractive|update"])
        self.assertNotIn("Installed:", r.stdout)

    def test_a_distribution_without_apt_get_is_told_so(self):
        empty = os.path.join(self.tmp, "empty")
        os.makedirs(empty)
        bash = shutil.which("bash")
        r = subprocess.run([bash, SCRIPT, "tmux"], capture_output=True, text=True, env={"PATH": empty}, timeout=20)
        self.assertEqual(r.returncode, 3)
        self.assertIn("no apt-get", r.stderr)


if __name__ == "__main__":
    unittest.main()
