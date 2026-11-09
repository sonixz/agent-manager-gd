"""The How-to guides as data: their text, step by step. Each step's screenshot is captured by the real app on a
private virtual display (tools/showcase.sh howto-<id>, steps in app/tools_showcase.gd, same step numbers) into
public/assets/howto/<id>/NN.webp. tools/howto/build_page.py turns this file into public/howto.html.

Agents in the screenshots replay real recorded screens of Claude Code and Codex (tools/showcase/scenes): « Real
screens ». Guides that only show the app are « App only ».
  python3 tools/howto/guides.py --ids          the guide ids, in page order
  python3 tools/howto/guides.py --check        each guide has one screenshot per step?
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDES: list[dict] = []


def guide(id: str, title: str, group: str, minutes: int, goal: str, needs: list[str],
          steps: list[tuple[str, str]], trouble: list[tuple[str, str]], docs: list[tuple[str, str]],
          real: bool = True) -> None:
    """steps: (what you do, what you see). trouble: (symptom, what to do). docs: (label, link)."""
    GUIDES.append({"id": id, "title": title, "group": group, "minutes": minutes, "goal": goal, "needs": needs,
                   "steps": steps, "trouble": trouble, "docs": docs, "real": real})


K = lambda *keys: "+".join(f"<kbd>{k}</kbd>" for k in keys)  # noqa: E731

# ---------------------------------------------------------------- the guides, in page order
guide(
    "first-minutes", "Your first five minutes", "Start", 5,
    "Start a Claude Code session in a project, give it a task, and follow it from the list without watching it.",
    ["Agent Manager GD installed, with Claude Code or Codex already installed and signed in "
     "(<a href=\"docs.html#install\">Install</a>)"],
    [(f"Click <b>+ New session</b> at the top of the list (or press {K('Ctrl', 'Shift', 'N')}). Give it a name, "
      "pick <b>Claude Code</b>, a group and the project's folder.",
      "The New session dialog. Below the folder, what the session gets: its own git branch, the Second Brain, a "
      "journal in the Brain, Remote Control. The defaults are fine to start."),
     ("Click <b>Start</b>.",
      "The session opens in Focus view: Claude Code itself, in a real terminal, with your own login and settings. "
      "Its card in the list says <i>ready</i>."),
     ("Type what you want in the terminal, as you always do, and press <kbd>Enter</kbd>.",
      "Its state turns to <i>working</i>, in the header and on its card. You can leave it: the list keeps telling "
      "you where it is."),
     ("Work on something else, in another session. When an agent needs you, you see it without looking for it.",
      "The card moves up into <b>They wait for you</b>, in orange for an OK, in yellow for a question, with what "
      "the agent asks. A toast says it too."),
     ("When it is finished, its card says <i>done</i>.",
      "Close the app if you like: the session lives on in its own terminal server. Open the app again and every "
      "agent is where you left it."),
     ],
    [("Claude Code is not found.", "Open <b>⋯ › Setup check</b>: it says what is missing and the command to run "
      "yourself (<a href=\"docs.html#setup-check\">Setup check</a>)."),
     ("The state stays on <i>ready</i> while the agent works.", "States come from the agent's own hooks, which "
      "Agent Manager installs for that session only. A session started before an update needs <b>Restart</b>."),
     ("The text looks wrong in the terminal.", "That is a bug: tell us. The terminal must be impeccable "
      "(accents, colours, emoji, mouse).")],
    [("Sessions and states", "docs.html#states"), ("The terminal", "docs.html#terminal")])

guide(
    "answer-fast", "Answer without opening a terminal", "Start", 3,
    "Approve a command or answer a question from the list, while you keep reading something else.",
    ["Two or more sessions running (<a href=\"#first-minutes\">Your first five minutes</a>)"],
    [("Look at the top of the list.",
      "<b>They wait for you</b> holds every session that needs you, first come first: here, one waits for your OK "
      "to run a command, another asks a question."),
     (f"Click <b>Approve</b> on the one that waits for your OK (or press {K('Ctrl', 'Shift', 'A')} for the first "
      "one).",
      "Agent Manager presses the agent's highlighted choice for you (its <i>Yes</i>). The card leaves the queue and "
      "the session is <i>working</i> again."),
     ("On the one with a question, click <b>Reply…</b>.",
      "A small box: write your answer and press <kbd>Enter</kbd>. It goes to that agent's terminal as if you had "
      "typed it there."),
     ("Want to read before you answer? Click <b>Open</b>.",
      "The session opens in Focus view on its question: here, a choice between three ways to identify a client, "
      "which you answer with the arrow keys."),
     ],
    [("Approve picked the wrong choice.", "Approve presses <kbd>Enter</kbd>, the agent's highlighted choice. When "
      "you want another one, use <b>Open</b> and choose yourself."),
     ("A session waits but is not in the queue.", "Only agents with hooks report a state (Claude Code, Codex). A "
      "shell has no state.")],
    [("Live states", "docs.html#states"), ("Shortcuts", "docs.html#shortcuts")])

guide(
    "views", "Focus, Grid and Board", "Start", 3,
    "See one agent, four at once, or a live tile for every session, and move between them with the keyboard.",
    [],
    [(f"<b>Focus</b> ({K('Ctrl', 'Shift', 'F')}): one session, full size.",
      "The terminal takes the whole space; the header says its tool, folder, branch, whether it shares the Second "
      "Brain, and its state."),
     (f"<b>Grid</b> ({K('Ctrl', 'Shift', 'G')}): up to four sessions side by side.",
      "Each terminal is real and live: type in any of them. Its title bar shows its state. Choose which ones from "
      "the list."),
     (f"<b>Board</b> ({K('Ctrl', 'Shift', 'B')}): a tile per session.",
      "A live preview of each terminal and its state. Click a tile to open it in Focus."),
     (f"{K('Ctrl', 'Shift', '↓')} and {K('Ctrl', 'Shift', '↑')} go to the next and the previous session; "
      f"{K('Ctrl', 'Shift', 'K')} opens the command palette.",
      "Type a few letters of any action or session name: <i>gr</i> finds Grid view and the sessions in a group."),
     ],
    [("A shortcut does nothing in a terminal.", "In a terminal, plain <kbd>Ctrl</kbd> keys belong to its programs: "
      "add <kbd>Shift</kbd>. You can change any shortcut in <b>⋯ › Shortcuts</b>.")],
    [("Views", "docs.html#views"), ("Shortcuts", "docs.html#shortcuts")], real=True)

guide(
    "review", "Review a diff and send comments", "Work", 4,
    "Read what an agent changed, file by file, comment on lines, and send your comments to it in one go.",
    ["A session that changed files in a git repository"],
    [(f"Select the session and click <b>Review</b> ({K('Ctrl', 'Shift', 'R')}).",
      "The files the agent changed since its branch started, with their added and removed lines, and the diff of "
      "the first file."),
     ("Click a file in the list.",
      "Its diff, line by line, in the terminal's font. New files show whole."),
     ("Click a line (or <b>Comment the file…</b>) and write what you think of it.",
      "Your comment sits under the line, with the code it is about. Add as many as you like, on any file."),
     ("Click <b>Send review</b>.",
      "Every comment goes to the agent at once, each with its file, line and code, as one message in its terminal, "
      "and is marked <i>sent to the agent</i>. When the agent has dealt with one, mark it <b>Handled</b>."),
     ],
    [("Review is empty.", "The folder is not a git repository, or nothing changed yet. A session in its own branch "
      "(worktree) shows only its own changes.")],
    [("Review", "docs.html#review"), ("Worktrees", "docs.html#worktrees")])


def by_id(gid: str) -> dict:
    for g in GUIDES:
        if g["id"] == gid:
            return g
    raise SystemExit(f"no guide {gid}")


if __name__ == "__main__":
    if "--ids" in sys.argv:
        print(" ".join(g["id"] for g in GUIDES))
    elif "--check" in sys.argv:
        bad = 0
        for g in GUIDES:
            have = len(list((ROOT / "public" / "assets" / "howto" / g["id"]).glob("*.webp")))
            ok = have == len(g["steps"])
            bad += not ok
            print(f"{'ok ' if ok else 'BAD'} {g['id']}: {have} screenshots, {len(g['steps'])} steps")
        sys.exit(1 if bad else 0)
