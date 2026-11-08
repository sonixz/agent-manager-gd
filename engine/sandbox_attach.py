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

TMUX_CLIPBOARD = ["set -s set-clipboard on", "set -s terminal-features[90] *:clipboard"]
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


def main() -> int:
    sbid = sys.argv[1]
    home = os.environ["AGMGD_HOME"]
    engine_port = int(os.environ.get("AGMGD_PORT", "8790"))
    keys = Keys(home)
    store = Store(os.path.join(home, "data", "sessions.sqlite3"))
    sbs = Sandboxes(store.path, home, keys)
    sb = sbs.get(sbid)
    rec = store.get(sb["session_id"]) or {}
    fly = Fly(lambda: keys.get("fly"))
    machines = {m["id"]: m for m in sbs.machines()}
    if machines.get(sb["machine"], {}).get("state") != "started":
        say("starting the sandbox…")
        fly.run("machine", "start", sb["machine"], "--app", sb["app"], timeout=300)
    port = free_port()
    proxy = subprocess.Popen([FLYCTL, "proxy", f"{port}:2222", f"{sb['machine']}.vm.{sb['app']}.internal", "--app", sb["app"]],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=fly.env())
    with open(os.path.join(home, "runtime", f"sandbox-{sbid}.port"), "w") as f:
        f.write(str(port))
    base = ssh_base(sbs.key_path(sbid), port)
    for _ in range(90):
        if subprocess.run(base + ["root@127.0.0.1", "true"], capture_output=True, timeout=20).returncode == 0:
            break
        time.sleep(1)
    else:
        say("the sandbox does not answer (yet): Agent Manager will retry")
        proxy.kill()
        return 1
    # tmux in the sandbox passes a program's « copy to clipboard » (OSC 52) on to Agent Manager's terminal
    subprocess.run(base + ["root@127.0.0.1", "printf '%s\\n' " + " ".join(f"'{line}'" for line in TMUX_CLIPBOARD)
                           + " > /root/.tmux.conf; tmux source-file /root/.tmux.conf 2>/dev/null; true"], capture_output=True, timeout=60)
    if subprocess.run(base + ["root@127.0.0.1", "test -e /root/.agmgd/ready"], capture_output=True).returncode != 0:
        say("first start: setting up the sandbox…")
        setup(sbs, sb, rec, keys, base, store)
    tunnel = ["-R", f"8765:127.0.0.1:{engine_port}"]
    cmd = base + tunnel + ["-t", "root@127.0.0.1", "cd " + sb["workdir"] + " 2>/dev/null; tmux new -A -s am"]
    rc = subprocess.call(cmd)
    proxy.kill()
    return rc


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
