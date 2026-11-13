"""Starts a session's program with the secrets it was given (Loop 39), and nothing else of them anywhere.

The engine puts this in front of the program's command: `secret_launch.py <port> <ticket> -- <program…>`. The ticket
is single-use and lives a minute; this exchanges it with the engine (127.0.0.1 only) for the values, sets them in its
own environment, and becomes the program (exec). So the values are in no file, not in tmux's environment (which every
session of the same tmux could read), not on a command line. The program, and what it starts, has them, as a program
given a key always does.

If the engine cannot be reached, the program starts without them and the terminal says so in one line.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request


def main(argv: list[str]) -> int:
    if len(argv) < 4 or "--" not in argv:
        print("usage: secret_launch.py <port> <ticket> -- <program…>", file=sys.stderr)
        return 2
    cut = argv.index("--")
    port, ticket, command = argv[0], argv[1], argv[cut + 1:]
    if not command:
        return 2
    names = []
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{int(port)}/secret-ticket", method="POST",
                                     data=json.dumps({"ticket": ticket}).encode())
        with urllib.request.urlopen(req, timeout=60) as r:
            got = json.loads(r.read())
        env = got.get("env") or {}
        for k, v in env.items():
            os.environ[str(k)] = str(v)
        names = sorted(env)
        missing = got.get("missing") or []
        if missing:
            print("Agent Manager: no longer in the vault, not given: " + ", ".join(missing), file=sys.stderr)
    except (OSError, ValueError) as e:
        print(f"Agent Manager: the secrets for this session could not be fetched ({e.__class__.__name__}); "
              "it starts without them", file=sys.stderr)
    if names:
        os.environ["AGMGD_SECRETS"] = ",".join(names)   # their names only, so a script can tell what it has
    try:
        os.execvp(command[0], command)
    except OSError as e:
        print(f"Agent Manager: could not start {command[0]}: {e}", file=sys.stderr)
        return 127
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
