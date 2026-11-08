"""Hook for agent CLIs: records what a session is doing, for the engine to read. Standalone (no package import).

Claude Code calls it for its hook events (JSON on stdin); Codex calls it as `notify` (JSON as the last argument).
It writes $AGMGD_HOME/state/<session>.json atomically, prints nothing (Claude Code would add stdout to the
conversation for some events) and always exits 0 so it can never block an agent.
  python3 hook.py claude    |    python3 hook.py codex '<json>'
"""
import json
import os
import sys
import time

CLAUDE = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "SubagentStop": "working",
    "PreCompact": "working",
    "Stop": "done",
    "SessionEnd": "ended",
}


def state_for(tool, payload):
    """(state, message, conversation id) for one event."""
    if tool == "claude":
        event = str(payload.get("hook_event_name", ""))
        message = str(payload.get("message", ""))[:300]
        if event == "Notification":
            low = message.lower()
            state = "approval" if ("permission" in low or "approve" in low or "allow" in low) else "waiting"
        else:
            state = CLAUDE.get(event, "")
        return state, message, str(payload.get("session_id", ""))
    if tool == "codex":
        kind = str(payload.get("type", ""))
        state = "done" if kind == "agent-turn-complete" else ""
        message = str(payload.get("last-assistant-message", "") or "")[:300]
        return state, message, str(payload.get("thread-id", "") or payload.get("session-id", "") or "")
    return "", "", ""


def main(argv):
    try:
        tool = argv[1] if len(argv) > 1 else ""
        sid = os.environ.get("AGMGD_SESSION", "")
        home = os.environ.get("AGMGD_HOME", "")
        if not sid or not home:
            return 0
        raw = argv[2] if len(argv) > 2 else sys.stdin.read()
        payload = json.loads(raw or "{}")
        state, message, conv = state_for(tool, payload if isinstance(payload, dict) else {})
        if not state:
            return 0
        folder = os.path.join(home, "state")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, sid + ".json")
        old = {}
        try:
            with open(path, encoding="utf-8") as f:
                old = json.load(f)
        except (OSError, ValueError):
            pass
        rec = {"state": state, "message": message, "time": time.time(), "tool": tool,
               "conversation": conv or old.get("conversation", "")}
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:  # never break the agent
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
