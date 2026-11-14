"""Loop 44: experts and their skills. The outside source is a local git repository reached through an https address
that git itself redirects (url.<base>.insteadOf): the real download path, nothing leaves this computer."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

from engine.experts import Experts, front_matter
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux

URL = "https://skills.example.test/anthropics/skills.git"
APACHE = "                                 Apache License\n                           Version 2.0, January 2004\n"


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, "-c", "user.name=t", "-c", "user.email=t@t", *args], check=True, capture_output=True)


def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


def skill_md(name, desc):
    return f"---\nname: {name}\ndescription: {desc}\nlicense: Complete terms in LICENSE.txt\n---\n\n# {name}\n\nDo it well.\n"


class FrontMatterTest(unittest.TestCase):
    def test_the_standard_fields_quoted_and_folded(self):
        fm = front_matter('---\nname: pdf\ndescription: "Read: and write PDFs"\nlicense: >\n  Proprietary.\n  See LICENSE.txt\n---\nbody')
        self.assertEqual(fm, {"name": "pdf", "description": "Read: and write PDFs", "license": "Proprietary. See LICENSE.txt"})
        self.assertEqual(front_matter("no front matter"), {})


class ExpertsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-exp-")
        self.upstream = os.path.join(self.tmp, "upstream")
        os.makedirs(self.upstream)
        git(self.upstream, "init", "-q", "-b", "main")
        write(os.path.join(self.upstream, "skills", "frontend-design", "SKILL.md"), skill_md("frontend-design", "Design interfaces"))
        write(os.path.join(self.upstream, "skills", "frontend-design", "LICENSE.txt"), APACHE)
        write(os.path.join(self.upstream, "skills", "pdf", "SKILL.md"), skill_md("pdf", "PDF files"))
        write(os.path.join(self.upstream, "skills", "pdf", "scripts", "fill.py"), "print('x')\n")
        write(os.path.join(self.upstream, "skills", "pdf", "LICENSE.txt"), "All rights reserved.\n")
        write(os.path.join(self.upstream, "README.md"), "skills\n")
        git(self.upstream, "add", "-A")
        git(self.upstream, "commit", "-q", "-m", "first")
        # git sends the https address to the local repository: the clone path is the real one
        self.old_env = {k: os.environ.get(k) for k in ("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0")}
        os.environ.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0=f"url.{self.upstream}.insteadOf", GIT_CONFIG_VALUE_0=URL)
        self.home = os.path.join(self.tmp, "home")
        self.x = Experts(self.home)
        self.src = {"id": "anthropic", "url": URL, "path": "skills", "title": "Anthropic's skills"}

    def tearDown(self):
        for k, v in self.old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_source_is_downloaded_only_when_confirmed_and_pinned(self):
        with self.assertRaises(ValueError):
            self.x.add_source(self.src, confirmed=False)
        with self.assertRaises(ValueError):
            self.x.add_source({**self.src, "url": "git@github.com:a/b.git"}, confirmed=True)   # https only
        st = self.x.add_source(self.src, confirmed=True)
        head = subprocess.run(["git", "-C", self.upstream, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(st["sources"][0]["commit"], head)
        lock = json.load(open(os.path.join(self.x.root(), "sources.lock")))
        self.assertEqual(lock["sources"][0]["url"], URL)
        by = {s["id"]: s for s in st["skills"]}
        self.assertEqual(set(by), {"anthropic/frontend-design", "anthropic/pdf"})
        self.assertEqual(by["anthropic/frontend-design"]["license"], "Apache-2.0")
        self.assertEqual(by["anthropic/pdf"]["license"], "its own terms (LICENSE.txt)")
        self.assertEqual((by["anthropic/pdf"]["script_count"], by["anthropic/pdf"]["scripts"]), (1, ["scripts/fill.py"]))
        self.assertEqual(by["anthropic/frontend-design"]["script_count"], 0)
        self.assertIn("Do it well", self.x.skill("anthropic/pdf")["text"])
        write(os.path.join(self.x.root(), "skills", "discord-moderation", "SKILL.md"), skill_md("discord-moderation", "Moderate"))
        self.assertIn("own/discord-moderation", {s["id"] for s in self.x.skills()})

    def test_updates_are_shown_skill_by_skill_and_applied_only_on_ok(self):
        self.x.add_source(self.src, confirmed=True)
        pinned = self.x.sources()[0]["commit"]
        write(os.path.join(self.upstream, "skills", "frontend-design", "run.sh"), "echo hi\n")    # a script appears
        write(os.path.join(self.upstream, "skills", "xlsx", "SKILL.md"), skill_md("xlsx", "Sheets"))  # a new skill
        shutil.rmtree(os.path.join(self.upstream, "skills", "pdf"))                                  # one goes
        git(self.upstream, "add", "-A")
        git(self.upstream, "commit", "-q", "-m", "second")
        up = self.x.check_updates("anthropic")
        kinds = {c["skill"]: c for c in up["changes"]}
        self.assertEqual(kinds["xlsx"]["kind"], "new skill")
        self.assertEqual(kinds["pdf"]["kind"], "removed")
        self.assertEqual((kinds["frontend-design"]["kind"], kinds["frontend-design"]["scripts"]), ("changed", ["run.sh"]))
        self.assertEqual(self.x.sources()[0]["commit"], pinned)                     # nothing used has changed yet
        self.assertIn("anthropic/pdf", {s["id"] for s in self.x.skills()})
        with self.assertRaises(ValueError):
            self.x.update("anthropic", up["latest"], confirmed=False)
        self.x.update("anthropic", up["latest"], confirmed=True)
        self.assertEqual(self.x.sources()[0]["commit"], up["latest"])
        self.assertEqual({s["id"] for s in self.x.skills()}, {"anthropic/frontend-design", "anthropic/xlsx"})
        self.assertEqual(self.x.check_updates("anthropic")["changes"], [])

    def test_experts_are_made_of_known_skills_and_the_starters_take_what_is_there(self):
        self.x.add_source(self.src, confirmed=True)
        with self.assertRaises(ValueError):
            self.x.save("Bad Name", "x", "", [])
        with self.assertRaises(ValueError):
            self.x.save("web", "Web", "ctx", ["anthropic/nothing"])
        with self.assertRaises(ValueError):
            self.x.save("web", "Web", "ctx", ["anthropic/pdf"], ["lowercase"])
        e = self.x.save("web", "Web", "You build the web.", ["anthropic/frontend-design"], ["FIGMA_TOKEN"])
        self.assertEqual((e["skills"], e["secrets"], e["context"].strip()), (["anthropic/frontend-design"], ["FIGMA_TOKEN"], "You build the web."))
        made = self.x.add_starters()["made"]
        self.assertEqual(made, ["frontend", "documents"])          # mcp-builder's skills are not in this library
        self.assertEqual(self.x.expert("documents")["skills"], ["anthropic/pdf"])
        self.assertEqual(self.x.add_starters()["made"], [])          # never made twice, never overwritten
        with self.assertRaises(ValueError):
            self.x.remove_source("anthropic", confirmed=True)       # experts use it
        with self.assertRaises(ValueError):
            self.x.delete("web", confirmed=False)
        self.x.delete("web", confirmed=True)
        self.assertNotIn("web", {e["name"] for e in self.x.experts()})
        self.assertEqual({s["id"]: s["used_by"] for s in self.x.skills()}["anthropic/pdf"], ["documents"])

    def test_skills_are_imported_from_a_folder_one_or_many_never_overwritten_unless_asked(self):
        one = os.path.join(self.tmp, "mine", "Release Notes")
        write(os.path.join(one, "SKILL.md"), skill_md("release-notes", "Write release notes"))
        write(os.path.join(one, ".git", "HEAD"), "ref: x\n")                       # never copied
        st = self.x.import_folder(one)
        self.assertEqual(st["imported"], ["release-notes"])                         # named by its SKILL.md
        self.assertFalse(os.path.exists(os.path.join(self.x.root(), "skills", "release-notes", ".git")))
        many = os.path.join(self.tmp, "pack")
        write(os.path.join(many, "a", "SKILL.md"), skill_md("alpha", "A"))
        write(os.path.join(many, "b", "SKILL.md"), skill_md("release-notes", "Changed"))
        write(os.path.join(many, "notes.txt"), "not a skill\n")
        st = self.x.import_folder(many)
        self.assertEqual((st["imported"], st["kept"]), (["alpha"], ["release-notes"]))
        self.assertIn("Write release notes", self.x.skill("own/release-notes")["description"])
        self.assertEqual(self.x.import_folder(many, replace=True)["imported"], ["alpha", "release-notes"])
        self.assertEqual(self.x.skill("own/release-notes")["description"], "Changed")
        with self.assertRaises(ValueError):
            self.x.import_folder(os.path.join(self.tmp, "upstream", "README.md"))
        with self.assertRaises(ValueError):
            self.x.import_folder(self.tmp + "/nothing-here")

    def test_claude_gets_a_plugin_of_the_session_and_codex_links_out_of_git(self):
        self.x.add_source(self.src, confirmed=True)
        self.x.save("web", "Web", "You build the web.", ["anthropic/frontend-design", "anthropic/pdf"])
        c = self.x.claude_parts("web", "s1")
        self.assertEqual(c["args"][0], "--plugin-dir")
        plugin = c["folder"]
        self.assertEqual(json.load(open(os.path.join(plugin, ".claude-plugin", "plugin.json")))["name"], "expert-web")
        self.assertTrue(os.path.isfile(os.path.join(plugin, "skills", "pdf", "SKILL.md")))
        self.assertIn("« Web »", c["note"])
        if shutil.which("claude"):   # Claude Code's own check of the folder, offline
            v = subprocess.run(["claude", "plugin", "validate", plugin], capture_output=True, text=True, timeout=60)
            self.assertEqual(v.returncode, 0, v.stdout + v.stderr)
        work = os.path.join(self.tmp, "work")
        os.makedirs(work)
        git(work, "init", "-q")
        git(work, "commit", "-q", "--allow-empty", "-m", "x")
        p = self.x.codex_parts("web", work)
        self.assertEqual(p["args"][0], "-c")
        self.assertTrue(p["args"][1].startswith("developer_instructions="))
        json.loads(p["args"][1].split("=", 1)[1])                   # a quoted string Codex's TOML reads
        self.assertTrue(os.path.isfile(os.path.join(work, ".agents", "skills", "frontend-design", "SKILL.md")))
        status = subprocess.run(["git", "-C", work, "status", "--porcelain"], capture_output=True, text=True).stdout
        self.assertEqual(status, "")                                  # never committed, never even seen by git
        self.x.codex_parts("web", work)                               # again: one exclude line, links in place
        ex = open(os.path.join(work, ".git", "info", "exclude")).read()
        self.assertEqual(ex.count(".agents/skills/"), 1)


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class LaunchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-exl-")
        os.environ["AGMGD_KEYS_PLAIN"] = "1"
        self.tmux = Tmux("agmgd-exl-test", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp, None)
        own = os.path.join(self.s.experts.root(), "skills", "discord-api")
        write(os.path.join(own, "SKILL.md"), skill_md("discord-api", "Discord's API"))
        self.s.experts.save("discord", "Discord", "You run Discord bots.", ["own/discord-api"], ["DISCORD_BOT_TOKEN"])
        self.work = os.path.join(self.tmp, "bot")
        os.makedirs(self.work)
        git(self.work, "init", "-q")
        git(self.work, "commit", "-q", "--allow-empty", "-m", "x")

    def tearDown(self):
        os.environ.pop("AGMGD_KEYS_PLAIN", None)
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_an_expert_launch_needs_its_secrets_then_carries_them_and_its_skills(self):
        with self.assertRaises(ValueError) as e:
            self.s.create("Bot", "claude", self.work, expert="discord", brain=False)
        self.assertIn("DISCORD_BOT_TOKEN", str(e.exception))
        self.s.vault.set("DISCORD_BOT_TOKEN", "t0ken", "")
        d = self.s.create("Bot", "claude", self.work, expert="discord", brain=False)
        rec = self.s.store.get(d["id"])
        self.assertEqual((rec["expert"], json.loads(rec["secrets"])), ("discord", ["DISCORD_BOT_TOKEN"]))
        cmd = self.s.command_for(rec)
        self.assertIn("--plugin-dir", cmd)
        self.assertIn("You run Discord bots.", cmd[cmd.index("--append-system-prompt") + 1])
        self.assertFalse(any("t0ken" in a for a in cmd))             # a value never on a command line

    def test_codex_as_an_expert_gets_its_own_worktree(self):
        self.s.vault.set("DISCORD_BOT_TOKEN", "t0ken", "")
        d = self.s.create("Bot codex", "codex", self.work, expert="discord", brain=False)
        rec = self.s.store.get(d["id"])
        self.assertTrue(rec["worktree"])                              # no other session sees its skills
        self.assertTrue(os.path.isfile(os.path.join(rec["cwd"], ".agents", "skills", "discord-api", "SKILL.md")))
        self.assertFalse(os.path.exists(os.path.join(self.work, ".agents")))
        cmd = self.s.command_for(rec)
        self.assertTrue(any(a.startswith("developer_instructions=") for a in cmd))
        with self.assertRaises(ValueError):
            self.s.create("Shell", "shell", self.work, expert="discord", brain=False)
