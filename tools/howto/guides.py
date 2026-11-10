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
    [("Claude Code is not found.", "Open <b>◐ › Setup check</b>: it says what is missing and the command to run "
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
      "add <kbd>Shift</kbd>. You can change any shortcut in <b>◐ › Shortcuts</b>.")],
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


guide(
    "history", "Resume, fork and find any conversation", "Work", 4,
    "Find an old session in the History, pick up its conversation where it stopped, or try another way on a copy.",
    [],
    [(f"Click <b>History</b> ({K('Ctrl', 'Shift', 'H')}).",
      "Every session ever made, the archived ones too, with each conversation the agent had in it. Nothing is "
      "forgotten: removing a session keeps its conversations here."),
     ("Type in the search box: a name, a folder, a group or a conversation id.",
      "The list narrows as you type. Each session shows its tool, folder and its conversations, newest first."),
     ("Click <b>Fork…</b> on a Claude Code session and name the copy.",
      "A new session starts on a copy of the conversation: the original stays as it was. Use it to try another "
      "approach without losing the first one."),
     ("To work without touching the main branch, tick <b>In its own git branch</b> in the New session dialog.",
      "The session gets a worktree beside the repository, on its own branch: its header shows the branch. Review "
      "shows only its changes."),
     ],
    [("Resume starts an empty conversation.", "The agent did not save that conversation (it ended before its "
      "first message). Pick another one under the session: <b>Resume this one</b>.")],
    [("History", "docs.html#history"), ("Worktrees", "docs.html#worktrees")])

guide(
    "connect-repo", "Connect a repository (SSH deploy key)", "Git", 5,
    "Give a GitHub repository its own SSH key, made and checked by Agent Manager, so sessions push without your own "
    "keys.",
    ["A GitHub repository you can administer (to add a deploy key)"],
    [("Click <b>⎇ Repos</b> at the top.",
      "Connected repositories, and a form: the repository's SSH address, and whether to use your own clone or let "
      "Agent Manager clone it."),
     ("Paste the address (<code>git@github.com:owner/repo.git</code>), choose your folder, and click "
      "<b>+ Add the repository</b>.",
      "Agent Manager makes a deploy key for this repository alone. Its public half is shown with a button to copy it, "
      "and the link to the repository's Deploy keys page on GitHub."),
     ("On GitHub, add the key (tick <i>Allow write access</i> if sessions should push), then click <b>Check</b>.",
      "The card says <i>connected</i> and <i>origin ✓</i>: the key reads and writes. It shows the key's "
      "fingerprint, the folder, and buttons to copy the key again, rotate it or disconnect."),
     ("Start a session on it: in New session, pick it under <b>Repository</b>.",
      "The session's git uses this key only, through <code>GIT_SSH_COMMAND</code>. Nothing is written in your "
      "<code>~/.ssh</code>, and the agent is told how git authenticates here."),
     ],
    [("Check says write is refused.", "On GitHub, the deploy key needs <i>Allow write access</i>."),
     ("<code>ssh -T git@github.com</code> shows another account.", "That command ignores the session's key. Check "
      "with <code>git ls-remote origin</code> instead.")],
    [("Repositories and deploy keys", "docs.html#repos")], real=False)

guide(
    "voice", "Talk to your agents", "Voice", 4,
    "Dictate into a terminal with F8, and drive the app with F9: approve, go to a session, ask who waits.",
    ["An OpenAI key in <b>◐ › Keys</b>, for the transcription (<a href=\"docs.html#keys\">Keys</a>)"],
    [("Open <b>◐ › Keys</b> and paste your OpenAI key.",
      "On Windows it is encrypted for your Windows user (DPAPI); on Linux, the file is readable by you only. It is "
      "never shown again, never written to a log. Your Second Brain keys are listed below it."),
     ("In a session, hold <kbd>F8</kbd> and speak. Release it when you are done.",
      "A listening overlay with a level meter. On release, what you said is written into the terminal, as if you had "
      "typed it: read it, then press <kbd>Enter</kbd>."),
     ("Hold <kbd>F9</kbd> and give a command: <span class=\"say\">approve Flaky tests</span>.",
      "Agent Manager asks before acting, with what it heard: « Approve “Flaky tests”? ». Other commands: <i>go to "
      "…</i>, <i>grid view</i>, <i>who is waiting</i>, <i>wrap up …</i>, <i>new session …</i>."),
     ("Click <b>OK</b>.",
      "The OK goes to that agent, and it carries on. A soft sound tells you when an agent waits for you; <b>♪</b> at "
      "the top right mutes it."),
     ],
    [("Nothing is written after F8.", "Check the key in <b>◐ › Keys</b>, and that the microphone is allowed for "
      "Agent Manager. The toast says what went wrong."),
     ("F9 typed my words into the terminal.", "When what you say is not a command, it is dictation: it goes to the "
      "active session.")],
    [("Voice", "docs.html#voice"), ("Keys", "docs.html#keys")], real=False)

guide(
    "agents", "Let an agent start helpers (MCP)", "Agents", 4,
    "Have a lead agent split a job and start helper sessions of its own, which you can watch and take over.",
    ["Claude Code or Codex (each session is offered Agent Manager's MCP server)"],
    [("Ask a lead agent for a job that splits well: <span class=\"say\">prepare the release: run the tests in one "
      "helper and draft the changelog in another</span>.",
      "The agent sees Agent Manager's tools: list the sessions, read a screen, start a session, send to its own "
      "children, wait for one."),
     ("Watch the list.",
      "Its helpers appear under it, marked <i>↳ Release lead</i>, in real terminals. Open any of them: you can type "
      "in it, stop it, take over."),
     ("Open the Grid view on the lead and its helpers.",
      "The lead reads its helpers' screens and waits for them; it never types into a session that is not its own, "
      "and never approves anything."),
     ],
    [("The agent says it has no such tool.", "The session was started before the MCP server was offered: "
      "<b>Restart</b> it."),
     ("You want the same tools outside the app.", "<b>◐ › Connect other tools</b> gives the command for Claude "
      "Code, Codex or any MCP client.")],
    [("The MCP server", "docs.html#mcp")])

guide(
    "brain-document", "A session that documents itself in the Brain", "Second Brain", 4,
    "Start an agent that reads where the project stands in your Second Brain, then proposes your words, its decisions "
    "and a journal as it works.",
    ["<b>Second Brain GD</b> running on the same "
     "computer: the status bar says <i>✦ Second Brain connected</i>"],
    [("In New session, keep <b>Share the Second Brain</b> ticked and tick <b>↳ Document this session in the Brain as "
      "it works</b>.",
      "The session gets a Brain key of its own, at the « propose » level: it can read and search, and what it "
      "proposes waits for the Brain's archivist."),
     ("Start it.",
      "Its card shows <i>✦ Brain</i> and its header <i>shares the Second Brain</i>. Before changing anything, the "
      "agent reads the project card, the last journal and the open questions, and checks them against "
      "<code>git log</code>."),
     ("Open <b>◐ › Keys</b>.",
      "Under <i>Second Brain keys made by Agent Manager</i>, one key per session, with its calls. A key nothing uses "
      "any more can be revoked; removing a session revokes its key."),
     ("In your Second Brain, open <b>AI tools and your Brain</b>.",
      "What sessions proposed: your directives, their decisions, a journal at each commit, each with who proposed it "
      "and why. Approve, reject, or let the archivist file them with your rules."),
     ],
    [("The Brain options are greyed out.", "Second Brain is not running, or not found: the status bar says why."),
     ("Document is greyed out.", "Claude Code only for now, on this computer.")],
    [("Second Brain", "docs.html#brain")])

guide(
    "remote-control", "Follow a session from your phone", "Agents", 2,
    "Keep an eye on a Claude Code session, and answer it, from claude.ai/code or the Claude app while you are away.",
    ["Claude Code signed in with a Claude account that has Remote Control"],
    [("In New session, keep <b>Remote Control: also on claude.ai/code and the Claude app</b> ticked (it is on by "
      "default for Claude Code).",
      "The session is started with Claude Code's own Remote Control, under the name <i>Group · Session</i>, so you "
      "recognise it on the other side."),
     ("Start it, then open claude.ai/code or the Claude app on your phone.",
      "Its card shows <i>⇄ claude.ai</i>. The same conversation is there, live: read it, answer it. Back at your "
      "desk, the terminal shows what happened."),
     ],
    [("The session is not on claude.ai.", "Remote Control is Claude Code's own feature and needs your Claude "
      "account to have it. Untick it for sessions that should stay on this computer only.")],
    [("Remote Control", "docs.html#remote-control")])

guide(
    "sandbox", "Run an agent in a cloud sandbox", "Cloud", 6,
    "Give an agent a throw-away machine on Fly.io, see what it costs as it runs, and keep a budget that only pauses.",
    ["A Fly.io account and its API token in <b>◐ › Keys</b>",
     "An Anthropic API key (Claude Code) or OpenAI key (Codex) in Keys, for the agent in the cloud"],
    [("Open <b>☁ Sandboxes</b>.",
      "Three steps: the image (what it holds: Ubuntu, tmux, git, Claude Code, Codex), deploy with an estimate first, "
      "and this month's costs against your budget. Below, a live card per sandbox: the machine, the SSH tunnel and "
      "its latency, the branch, files not committed, commits not pushed, and what it cost today."),
     ("Click <b>Deploy + agentic coding session</b>, or pick <b>☁ A cloud sandbox</b> under <b>Where</b> in New "
      "session.",
      "The same dialog as for this computer. The machine starts in about 30 seconds; the session's terminal is the "
      "agent's terminal in the cloud, through an SSH tunnel. It reaches your Second Brain through that tunnel, with a "
      "key of its own."),
     ],
    [("Deploy is refused.", "The month's budget is reached: raise it, or wait. Budgets and caps only pause machines, "
      "never destroy them."),
     ("Costs differ from Fly's invoice.", "Agent Manager measures running time from Fly's machine history × the "
      "published price. The invoice stays on Fly's dashboard.")],
    [("Cloud sandboxes", "docs.html#sandboxes"), ("Keys", "docs.html#keys")], real=False)

guide(
    "make-it-yours", "Themes and shortcuts", "Start", 2,
    "Pick a look among seven themes and change any shortcut.",
    [],
    [("Click <b>◐</b> at the top, or type <span class=\"say\">theme</span> in the command palette.",
      "Seven themes, the same as Second Brain's: interface and terminal colours change together. Here, Neon."),
     ("Open <b>◐ › Shortcuts</b>, click an action, and press the new key.",
      "Every shortcut, and the voice keys (hold to talk). With <kbd>Shift</kbd> added, they also work inside a "
      "terminal."),
     ],
    [], [("Shortcuts", "docs.html#shortcuts")], real=False)

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
