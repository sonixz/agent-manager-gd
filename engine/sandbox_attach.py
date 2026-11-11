"""A sandbox session's terminal (run by the session's local tmux pane): start the machine if it is stopped, open
`flyctl proxy` to its sshd, set it up the first time, then `ssh -t … tmux new -A -s am` with the reverse tunnel that
lets the sandbox reach the Second Brain through the engine (sandbox 127.0.0.1:8765 → engine /sandbox-brain/<secret>).
Secrets travel on ssh's standard input into 0600 files, never on a command line.
  python3 sandbox_attach.py <sandbox id>      (AGMGD_HOME and AGMGD_PORT from the session's environment)"""
import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from engine.keys import Keys                      # noqa: E402
from engine.sandboxes import FLYCTL, Fly, Sandboxes  # noqa: E402
from engine.store import Store                    # noqa: E402

def _forget_port(home: str, sbid: str) -> None:
    """The terminal is closed: its local proxy port means nothing any more."""
    try:
        os.remove(os.path.join(home, "runtime", f"sandbox-{sbid}.port"))
    except OSError:
        pass


TMUX_CLIPBOARD = ["set -s set-clipboard on", "set -s terminal-features[90] *:clipboard", "set -g mouse on",
                  "set -g history-limit 50000"]
AGENT_CMD = {"claude": "claude --mcp-config /root/.agmgd/mcp.json", "codex": "codex", "shell": "bash -l"}


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def ssh_base(key: str, port: int) -> list:
    return ["ssh", "-i", key, "-p", str(port), "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ServerAliveInterval=20",
            "-o", "ConnectTimeout=10"]


def say(msg: str) -> None:
    sys.stdout.write("\r\n\x1b[36m☁ " + msg + "\x1b[0m\r\n")
    sys.stdout.flush()


SSH_LOST = 255  # ssh's own exit code when the connection could not be made or was lost


def wait_until_reachable(reachable, proxy, reopen, tries: int = 90, pause: float = 1.0, tell=say, clock=time.monotonic):
    """Waits for the sandbox to answer: (True, the tunnel) once it does, (False, the tunnel) after `tries`.
    The tunnel is opened again when it fell: a machine that just started is not always reachable at once, and
    flyctl proxy gives up when it is not. Before, the wait went on against a dead tunnel and said nothing."""
    began = clock()
    for i in range(tries):
        if proxy.poll() is not None:
            proxy = reopen()
        if reachable():
            return True, proxy
        if i % 10 == 9:
            tell("still waiting for the sandbox to answer (%d s)…" % (clock() - began))
        time.sleep(pause)
    return False, proxy


class Paused(Exception):
    """The machine is stopped and this try may not start it."""


def keep_connected(connect, tell=say, ask=input, pause: float = 5.0, rounds: int = 3) -> int:
    """Connects, and connects again when it could not or when the connection was lost: three tries, then it waits
    for Enter, as long as the owner wants. The terminal never ends on an error; it ends when the session inside
    the sandbox ends. (`tmux new -A` in the sandbox finds the same session again: nothing is lost on a reconnect.)
    Only the first try, and a try the owner asked for with Enter, may start a stopped machine: a sandbox paused by a
    cap (idle, budget) or by the owner is never started again behind their back."""
    failed, may_start = 0, True
    while True:
        try:
            rc = connect(may_start)
            if rc != SSH_LOST:
                return rc
            why = "the connection to the sandbox was lost"
        except Paused:
            why, failed = "the sandbox is paused", rounds  # no point in trying again by itself: it would stay paused
        except Exception as e:  # a missing tool, a timeout, a refusal from Fly: said in plain words, never a traceback
            why = "the sandbox could not be reached: " + (str(e).strip().splitlines() or [type(e).__name__])[-1][:200]
        failed += 1
        if failed < rounds:
            tell("%s. Trying again in %d seconds (%d of %d)…" % (why, pause, failed + 1, rounds))
            time.sleep(pause)
            may_start = False
            continue
        tell(why + ". The sandbox itself is still there (☁ Sandboxes shows it). Press Enter to "
             + ("start it and connect again." if why.endswith("paused") else "try again."))
        try:
            ask()
        except (EOFError, KeyboardInterrupt):
            return 1
        failed, may_start = 0, True


def connect(sbid: str, home: str, engine_port: int, may_start: bool = True) -> int:
    """One connection, from the machine's start to the end of the terminal in the sandbox: ssh's exit code."""
    keys = Keys(home)
    store = Store(os.path.join(home, "data", "sessions.sqlite3"))
    sbs = Sandboxes(store.path, home, keys)
    sb = sbs.get(sbid)
    rec = store.get(sb["session_id"]) or {}
    fly = Fly(lambda: keys.get("fly"))
    machines = sbs.machines()
    if not sb["machine"]:  # the machine was not in Fly's list yet when the sandbox was made: find it by its name
        found = next((m["id"] for m in machines if m.get("name") == "sandbox-" + sbid), "")
        if not found:
            raise RuntimeError("its machine is not in Fly's list (yet)")
        sbs._set(sbid, machine=found)
        sb = sbs.get(sbid)
    state = {m["id"]: m for m in machines}.get(sb["machine"], {}).get("state")
    if state != "started":
        if not may_start and state in ("stopped", "suspended"):
            raise Paused()
        if may_start:
            say("starting the sandbox…")
            fly.run("machine", "start", sb["machine"], "--app", sb["app"], timeout=300)
    port = free_port()

    def open_tunnel():
        return subprocess.Popen([FLYCTL, "proxy", f"{port}:2222", f"{sb['machine']}.vm.{sb['app']}.internal", "--app", sb["app"]],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=fly.env())

    base = ssh_base(sbs.key_path(sbid), port)

    def answers() -> bool:
        try:
            return subprocess.run(base + ["root@127.0.0.1", "true"], capture_output=True, timeout=20).returncode == 0
        except subprocess.TimeoutExpired:
            return False

    proxy = open_tunnel()
    try:
        with open(os.path.join(home, "runtime", f"sandbox-{sbid}.port"), "w") as f:
            f.write(str(port))
        say("connecting to the sandbox…")
        ok, proxy = wait_until_reachable(answers, proxy, open_tunnel)
        if not ok:
            raise RuntimeError("it did not answer")
        # tmux in the sandbox passes a program's « copy to clipboard » (OSC 52) on to Agent Manager's terminal
        subprocess.run(base + ["root@127.0.0.1", "printf '%s\\n' " + " ".join(f"'{line}'" for line in TMUX_CLIPBOARD)
                               + " > /root/.tmux.conf; tmux source-file /root/.tmux.conf 2>/dev/null; true"], capture_output=True, timeout=60)
        if subprocess.run(base + ["root@127.0.0.1", "test -e /root/.agmgd/ready"], capture_output=True, timeout=60).returncode != 0:
            say("first start: setting up the sandbox…")
            setup(sbs, sb, rec, keys, base, store)
            sb = sbs.get(sbid)  # the setup chose its working folder
        tunnel = ["-R", f"8765:127.0.0.1:{engine_port}"]
        return subprocess.call(base + tunnel + ["-t", "root@127.0.0.1", "cd " + sb["workdir"] + " 2>/dev/null; tmux new -A -s am"])
    finally:
        proxy.kill()
        _forget_port(home, sbid)


def main() -> int:
    sbid = sys.argv[1]
    home = os.environ["AGMGD_HOME"]
    engine_port = int(os.environ.get("AGMGD_PORT", "8790"))
    return keep_connected(lambda may_start: connect(sbid, home, engine_port, may_start))


def setup(sbs, sb, rec, keys, base, store) -> None:
    secret_files = {}
    if keys.get("anthropic"):
        secret_files["ANTHROPIC_API_KEY"] = keys.get("anthropic")
    if keys.get("openai"):
        secret_files["OPENAI_API_KEY"] = keys.get("openai")
        secret_files["CODEX_API_KEY"] = keys.get("openai")
    env_text = "".join(f"export {k}={json.dumps(v)}\n" for k, v in secret_files.items())
    subprocess.run(base + ["root@127.0.0.1", "mkdir -p /root/.agmgd && umask 077 && cat > /root/.agmgd/env"], input=env_text,
                   text=True, timeout=60)
    mcp = {"mcpServers": {}}
    if sb["brain_client"]:
        mcp["mcpServers"]["second-brain"] = {"type": "http", "url": f"http://127.0.0.1:8765/sandbox-brain/{sb['secret']}/mcp"}
    subprocess.run(base + ["root@127.0.0.1", "umask 077 && cat > /root/.agmgd/mcp.json"], input=json.dumps(mcp), text=True, timeout=60)
    workdir = "/work/project"
    if sb["repo_id"]:
        from engine.repos import Repos
        repos = Repos(store.path, sbs.home)
        r = repos.get(sb["repo_id"])
        with open(repos.key_path(sb["repo_id"]), encoding="utf-8") as f:
            subprocess.run(base + ["root@127.0.0.1", "umask 077 && cat > /root/.ssh/repo_key"], input=f.read(), text=True, timeout=60)
        name = r["name"]
        workdir = f"/work/{name}"
        clone = (f"export GIT_SSH_COMMAND='ssh -i /root/.ssh/repo_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' && "
                 f"git clone {json.dumps(r['url'])} {workdir} && git -C {workdir} switch -c am/{sb['id']} && "
                 f"git -C {workdir} config core.sshCommand \"$GIT_SSH_COMMAND\"")
        subprocess.run(base + ["root@127.0.0.1", clone], capture_output=True, text=True, timeout=600)
    else:
        subprocess.run(base + ["root@127.0.0.1", f"mkdir -p {workdir}"], timeout=60)
    sbs._set(sb["id"], workdir=workdir)
    agent = AGENT_CMD.get(rec.get("tool", "shell"), "bash -l")
    start = (f"tmux has-session -t am 2>/dev/null || tmux new -d -s am -c {workdir} "
             f"\"bash -lc '. /root/.agmgd/env; {agent}; exec bash -l'\"; touch /root/.agmgd/ready")
    subprocess.run(base + ["root@127.0.0.1", start], timeout=60)


if __name__ == "__main__":
    sys.exit(main())
