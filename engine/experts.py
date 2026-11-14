"""Experts (Loop 44; owner, 2026-11-14: « des agents spécialistes… on viendrait loader un agent, puis on viendrait
l'assigner à une session… agnostique du service, Codex ou Claude Code »; the name « Experts » is the owner's).

Three things:
- a skill: a folder of the open Agent Skills standard (agentskills.io): SKILL.md (a YAML front matter with its name
  and description, then instructions), maybe scripts and resources. Claude Code and Codex both read this format;
- an expert: a short context (its role, its rules), a list of skills, the names of the secrets it needs (Keys ›
  Secrets), a tool and a model by default;
- a launch: an expert started in a repository or a folder, with Claude Code or Codex.

Where they live: the experts' folder (by default in Agent Manager's data folder; better, the owner's own git
repository « agent-experts », so it is versioned and moves with them):
    sources.lock          the outside sources, each pinned to a commit (JSON)
    skills/<name>/        the owner's own skills
    experts/<name>/       expert.json and context.md
Outside sources are not copied there: each is a git clone in Agent Manager's cache at its pinned commit. Updates
are shown skill by skill (new, changed, removed, scripts added) and applied only on the owner's OK: a skill can
carry scripts the agent will run. Nothing is downloaded but on the owner's click.

At launch each tool gets the expert its own way: Claude Code a plugin folder of this session (--plugin-dir: nothing
is written in the repository) and the context appended to its system prompt; Codex the skills linked into
.agents/skills of its own folder (kept out of git by .git/info/exclude) and the context as developer instructions."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time

ANTHROPIC = {"id": "anthropic", "url": "https://github.com/anthropics/skills.git", "path": "skills",
             "title": "Anthropic's skills", "page": "https://github.com/anthropics/skills"}
NAME_OK = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
SECRET_OK = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")
SCRIPT_EXT = (".py", ".sh", ".js", ".mjs", ".cjs", ".ts", ".rb", ".pl", ".ps1", ".bat", ".exe")
# Three experts made of Anthropic's skills, to start with (owner, 2026-11-14: « commencer avec ceux-là d'Anthropic »)
STARTERS = [
    {"name": "frontend", "title": "Frontend", "glyph": "◈", "tool": "claude",
     "skills": ["anthropic/frontend-design", "anthropic/webapp-testing", "anthropic/theme-factory"],
     "context": "You are the frontend expert. You design and build interfaces that look deliberate, not generic, "
                "and you test them in a real browser before saying they work."},
    {"name": "documents", "title": "Documents", "glyph": "▤", "tool": "claude",
     "skills": ["anthropic/docx", "anthropic/pdf", "anthropic/pptx", "anthropic/xlsx", "anthropic/doc-coauthoring"],
     "context": "You are the documents expert: Word, PDF, PowerPoint and Excel files, made and edited with care. "
                "You check the file you produce by opening it again."},
    {"name": "mcp-builder", "title": "MCP builder", "glyph": "⬢", "tool": "claude",
     "skills": ["anthropic/mcp-builder", "anthropic/skill-creator"],
     "context": "You build MCP servers and new skills in the Agent Skills format, small, tested and documented."},
]


def _read(path: str, limit: int = -1) -> str:
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read(limit)


def front_matter(text: str) -> dict:
    """The YAML front matter of a SKILL.md, read for what the standard uses (name, description, license…): simple
    `key: value` lines, quoted values, and `|` or `>` blocks. Standard library only."""
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    out, key, block = {}, None, []
    for line in text[3:end].splitlines():
        if key and (line.startswith("  ") or line.startswith("\t") or not line.strip()):
            block.append(line.strip())
            continue
        if key:
            out[key] = " ".join(x for x in block if x).strip()
            key, block = None, []
        m = re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if v in ("|", ">", "|-", ">-", ""):
            key, block = k, []
            continue
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[k] = v
    if key:
        out[key] = " ".join(x for x in block if x).strip()
    return out


def license_of(folder: str, fm: dict) -> str:
    """What the skill says about its licence: Apache-2.0 / MIT when its LICENSE says so, else its own words."""
    for name in ("LICENSE.txt", "LICENSE", "LICENSE.md"):
        p = os.path.join(folder, name)
        if os.path.isfile(p):
            head = _read(p, 4000)
            if "Apache License" in head:
                return "Apache-2.0"
            if "MIT License" in head or "Permission is hereby granted, free of charge" in head:
                return "MIT"
            return "its own terms (" + name + ")"
    return str(fm.get("license", "")).strip()[:80] or "not stated"


def describe_skill(folder: str, sid: str, source: str) -> dict | None:
    """One skill as the page shows it: what it is, its licence, and what it holds (scripts first: they run)."""
    path = os.path.join(folder, "SKILL.md")
    if not os.path.isfile(path):
        return None
    text = _read(path)
    fm = front_matter(text)
    scripts, files, size = [], 0, 0
    for root, dirs, names in os.walk(folder):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for n in names:
            p = os.path.join(root, n)
            files += 1
            try:
                size += os.path.getsize(p)
            except OSError:
                pass
            rel = os.path.relpath(p, folder)
            if n.lower().endswith(SCRIPT_EXT) or (os.access(p, os.X_OK) and not n.lower().endswith((".md", ".txt"))):
                scripts.append(rel)
    return {"id": sid, "name": str(fm.get("name") or os.path.basename(folder)), "folder": os.path.basename(folder),
            "description": str(fm.get("description", ""))[:600], "license": license_of(folder, fm),
            "source": source, "scripts": sorted(scripts)[:40], "script_count": len(scripts), "files": files,
            "size": size, "path": folder, "lines": text.count("\n") + 1}


class Experts:
    def __init__(self, home: str):
        self.home = home
        self.cache = os.path.join(home, "skills-cache")
        self.config_path = os.path.join(home, "data", "experts.json")
        os.makedirs(os.path.dirname(self.config_path), exist_ok=True)

    # ---------------------------------------------------------------- where things live
    def _config(self) -> dict:
        try:
            return json.loads(_read(self.config_path))
        except (OSError, ValueError):
            return {}

    def root(self) -> str:
        r = self._config().get("root") or os.path.join(self.home, "experts")
        for d in ("skills", "experts"):
            os.makedirs(os.path.join(r, d), exist_ok=True)
        return r

    def set_root(self, path: str, repo_id: str = "") -> dict:
        """The experts' folder: Agent Manager's own, or the folder of a connected repository (« agent-experts »).
        What was in the old one is not moved: the page says so."""
        path = os.path.expanduser(path.strip())
        if not os.path.isdir(path):
            raise ValueError(f"no such folder: {path}")
        cfg = self._config()
        cfg.update(root=path, repo_id=repo_id)
        with open(self.config_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        return self.state()

    def _lock_path(self) -> str:
        return os.path.join(self.root(), "sources.lock")

    def sources(self) -> list[dict]:
        try:
            return list(json.loads(_read(self._lock_path())).get("sources", []))
        except (OSError, ValueError):
            return []

    def _save_sources(self, sources: list[dict]) -> None:
        with open(self._lock_path(), "w", encoding="utf-8") as f:
            json.dump({"about": "Outside skill sources, each pinned to a commit (Agent Manager GD, Experts)",
                       "sources": sources}, f, indent=2)
            f.write("\n")

    # ---------------------------------------------------------------- outside sources
    @staticmethod
    def _git(folder: str, *args: str, timeout: int = 300) -> tuple[int, str]:
        env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
        try:
            out = subprocess.run(["git", "-C", folder, *args], capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            return 124, "git did not answer in time"
        return out.returncode, (out.stdout + out.stderr).strip()

    def add_source(self, source: dict, confirmed: bool) -> dict:
        """On the owner's click only: a public git repository of skills cloned into the cache, pinned to the commit
        it is at now. Only https addresses (nothing of the owner's keys is used for a public source)."""
        if not confirmed:
            raise ValueError("adding a source downloads it: the owner's confirmation is needed")
        sid, url, sub = str(source.get("id", "")), str(source.get("url", "")), str(source.get("path", "")).strip("/")
        if not NAME_OK.match(sid):
            raise ValueError("a source id of lowercase letters, digits and dashes")
        if not re.match(r"^https://[\w.-]+/[\w./-]+$", url):
            raise ValueError("an https address of a public git repository")
        if any(s["id"] == sid for s in self.sources()):
            raise ValueError(f"the source {sid} is there already")
        dest = os.path.join(self.cache, sid)
        if os.path.isdir(dest):
            shutil.rmtree(dest, ignore_errors=True)
        os.makedirs(self.cache, exist_ok=True)
        try:
            out = subprocess.run(["git", "clone", "--quiet", url, dest], capture_output=True, text=True, timeout=600,
                                 env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
        except subprocess.TimeoutExpired:
            raise ValueError("the download took too long")
        if out.returncode != 0:
            shutil.rmtree(dest, ignore_errors=True)
            raise ValueError("could not download it: " + (out.stderr or out.stdout).strip()[-300:])
        rc, commit = self._git(dest, "rev-parse", "HEAD")
        entry = {"id": sid, "url": url, "path": sub, "commit": commit.strip(), "added": time.strftime("%Y-%m-%d"),
                 "title": str(source.get("title", sid)), "page": str(source.get("page", ""))}
        self._save_sources(self.sources() + [entry])
        return self.state()

    def _ensure_cache(self, s: dict) -> str:
        """The source's clone at its pinned commit (cloned again when the cache was cleared: the lock says what)."""
        dest = os.path.join(self.cache, s["id"])
        if not os.path.isdir(os.path.join(dest, ".git")):
            return ""
        rc, head = self._git(dest, "rev-parse", "HEAD")
        if head.strip() != s["commit"]:
            self._git(dest, "checkout", "--quiet", "--detach", s["commit"])
        return dest

    def check_updates(self, sid: str) -> dict:
        """What changed upstream since the pinned commit, skill by skill. Downloads the new commits into the cache
        (git fetch), changes nothing that is used."""
        s = next((x for x in self.sources() if x["id"] == sid), None)
        if not s:
            raise KeyError(sid)
        dest = self._ensure_cache(s)
        if not dest:
            raise ValueError("its copy is not in the cache: remove the source and add it again")
        rc, out = self._git(dest, "fetch", "--quiet", "origin")
        if rc != 0:
            raise ValueError("could not reach it: " + out[-200:])
        rc, latest = self._git(dest, "rev-parse", "origin/HEAD")
        if rc != 0:
            rc, latest = self._git(dest, "rev-parse", "FETCH_HEAD")
        latest = latest.strip()
        return {"id": sid, "pinned": s["commit"], "latest": latest, "changes": self._changes(dest, s, latest)}

    def _changes(self, dest: str, s: dict, latest: str) -> list[dict]:
        if latest == s["commit"]:
            return []
        prefix = (s["path"] + "/") if s["path"] else ""
        rc, out = self._git(dest, "diff", "--no-renames", "--name-status", s["commit"], latest, "--", s["path"] or ".")
        per: dict[str, dict] = {}
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            status, path = parts[0][0], parts[-1]
            rest = path[len(prefix):] if path.startswith(prefix) else path
            if "/" not in rest:
                continue
            skill, inner = rest.split("/", 1)
            c = per.setdefault(skill, {"skill": skill, "added": [], "changed": [], "removed": [], "scripts": []})
            {"A": c["added"], "D": c["removed"]}.get(status, c["changed"]).append(inner)
            if inner.lower().endswith(SCRIPT_EXT) and status != "D":
                c["scripts"].append(inner)
        out_list = []
        for c in per.values():
            whole = "SKILL.md" in c["added"] and not c["changed"] and not c["removed"]
            gone = "SKILL.md" in c["removed"]
            c["kind"] = "new skill" if whole else ("removed" if gone else "changed")
            out_list.append(c)
        return sorted(out_list, key=lambda c: (c["kind"] != "new skill", c["skill"]))

    def update(self, sid: str, commit: str, confirmed: bool) -> dict:
        """On the owner's OK: the source moves to that commit (already fetched by check_updates)."""
        if not confirmed:
            raise ValueError("an update changes what agents run: the owner's confirmation is needed")
        sources = self.sources()
        s = next((x for x in sources if x["id"] == sid), None)
        if not s:
            raise KeyError(sid)
        dest = os.path.join(self.cache, sid)
        rc, out = self._git(dest, "checkout", "--quiet", "--detach", commit)
        if rc != 0:
            raise ValueError("that commit is not in the cache: check for updates first")
        s.update(commit=commit, updated=time.strftime("%Y-%m-%d"))
        self._save_sources(sources)
        return self.state()

    def remove_source(self, sid: str, confirmed: bool) -> dict:
        if not confirmed:
            raise ValueError("the owner's confirmation is needed")
        used = [e["name"] for e in self.experts() if any(k.startswith(sid + "/") for k in e["skills"])]
        if used:
            raise ValueError("experts use it: " + ", ".join(used))
        self._save_sources([s for s in self.sources() if s["id"] != sid])
        shutil.rmtree(os.path.join(self.cache, sid), ignore_errors=True)
        return self.state()

    # ---------------------------------------------------------------- the library
    def skills(self) -> list[dict]:
        out = []
        for s in self.sources():
            dest = self._ensure_cache(s)
            base = os.path.join(dest, s["path"]) if dest else ""
            if not base or not os.path.isdir(base):
                continue
            for name in sorted(os.listdir(base)):
                d = describe_skill(os.path.join(base, name), f"{s['id']}/{name}", s["id"])
                if d:
                    d["commit"] = s["commit"][:7]
                    out.append(d)
        own = os.path.join(self.root(), "skills")
        for name in sorted(os.listdir(own)):
            d = describe_skill(os.path.join(own, name), f"own/{name}", "own")
            if d:
                out.append(d)
        used: dict[str, list[str]] = {}
        for e in self.experts():
            for k in e["skills"]:
                used.setdefault(k, []).append(e["name"])
        for d in out:
            d["used_by"] = used.get(d["id"], [])
        return out

    def skill(self, skill_id: str) -> dict:
        d = next((x for x in self.skills() if x["id"] == skill_id), None)
        if not d:
            raise KeyError(skill_id)
        d["text"] = _read(os.path.join(d["path"], "SKILL.md"))[:60000]
        return d

    # ---------------------------------------------------------------- experts
    def _expert_dir(self, name: str) -> str:
        return os.path.join(self.root(), "experts", name)

    def experts(self) -> list[dict]:
        out = []
        base = os.path.join(self.root(), "experts")
        for name in sorted(os.listdir(base)):
            p = os.path.join(base, name, "expert.json")
            if not os.path.isfile(p):
                continue
            try:
                e = json.loads(_read(p))
            except ValueError:
                continue
            ctx = os.path.join(base, name, "context.md")
            e["name"] = name
            e["context"] = _read(ctx) if os.path.isfile(ctx) else ""
            e.setdefault("skills", [])
            e.setdefault("secrets", [])
            e.setdefault("tool", "claude")
            e.setdefault("model", "")
            e.setdefault("title", name)
            e.setdefault("glyph", "◆")
            out.append(e)
        return out

    def expert(self, name: str) -> dict:
        e = next((x for x in self.experts() if x["name"] == name), None)
        if not e:
            raise KeyError(name)
        return e

    def save(self, name: str, title: str, context: str, skills: list, secrets: list | None = None, tool: str = "claude",
             model: str = "", glyph: str = "◆") -> dict:
        if not NAME_OK.match(name or ""):
            raise ValueError("a name of lowercase letters, digits and dashes (it is a folder)")
        if tool not in ("claude", "codex"):
            raise ValueError("Claude Code or Codex")
        known = {s["id"] for s in self.skills()}
        missing = [k for k in skills if k not in known]
        if missing:
            raise ValueError("unknown skills: " + ", ".join(missing))
        bad = [s for s in (secrets or []) if not SECRET_OK.match(str(s))]
        if bad:
            raise ValueError("secret names in capitals: " + ", ".join(bad))
        d = self._expert_dir(name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "expert.json"), "w", encoding="utf-8") as f:
            json.dump({"title": title.strip()[:60] or name, "glyph": (glyph or "◆")[:2], "tool": tool, "model": model[:60],
                       "skills": list(dict.fromkeys(skills)), "secrets": list(dict.fromkeys(secrets or []))}, f, indent=2)
            f.write("\n")
        with open(os.path.join(d, "context.md"), "w", encoding="utf-8") as f:
            f.write(context.strip()[:20000] + "\n")
        return self.expert(name)

    def delete(self, name: str, confirmed: bool) -> dict:
        if not confirmed:
            raise ValueError("the owner's confirmation is needed")
        self.expert(name)
        shutil.rmtree(self._expert_dir(name), ignore_errors=True)
        return self.state()

    def add_starters(self) -> dict:
        """The three experts made of Anthropic's skills, those whose skills are in the library; never overwritten."""
        have = {e["name"] for e in self.experts()}
        known = {s["id"] for s in self.skills()}
        made = []
        for st in STARTERS:
            if st["name"] in have:
                continue
            skills = [k for k in st["skills"] if k in known]
            if not skills:
                continue
            self.save(st["name"], st["title"], st["context"], skills, [], st["tool"], "", st["glyph"])
            made.append(st["name"])
        return {**self.state(), "made": made}

    def state(self) -> dict:
        cfg = self._config()
        sources = self.sources()
        return {"root": self.root(), "repo_id": cfg.get("repo_id", ""), "in_data_folder": not cfg.get("root"),
                "sources": sources, "anthropic": ANTHROPIC, "has_anthropic": any(s["id"] == "anthropic" for s in sources),
                "skills": [{k: v for k, v in s.items() if k != "path"} for s in self.skills()],
                "experts": self.experts(), "starters": [s["name"] for s in STARTERS]}

    # ---------------------------------------------------------------- a launch, for each tool
    def _skill_dirs(self, e: dict) -> list[tuple[str, str]]:
        by = {s["id"]: s for s in self.skills()}
        return [(by[k]["folder"], by[k]["path"]) for k in e["skills"] if k in by]

    def claude_parts(self, name: str, sid: str) -> dict:
        """Claude Code: a plugin folder of this session only (its skills linked there), loaded with --plugin-dir;
        the context goes with Agent Manager's own note in --append-system-prompt. Nothing in the repository."""
        e = self.expert(name)
        folder = os.path.join(self.home, "sessions", sid, "expert-plugin")
        shutil.rmtree(folder, ignore_errors=True)
        os.makedirs(os.path.join(folder, ".claude-plugin"))
        os.makedirs(os.path.join(folder, "skills"))
        with open(os.path.join(folder, ".claude-plugin", "plugin.json"), "w", encoding="utf-8") as f:
            json.dump({"name": f"expert-{name}", "description": f"Agent Manager GD expert « {e['title']} »", "version": "1.0.0"}, f)
        for short, path in self._skill_dirs(e):
            os.symlink(path, os.path.join(folder, "skills", short))
        return {"args": ["--plugin-dir", folder], "note": self.note(e), "folder": folder}

    def codex_parts(self, name: str, cwd: str) -> dict:
        """Codex: its skills linked into .agents/skills of its own folder (Codex reads them there), that folder kept
        out of git locally (.git/info/exclude, never committed); the context as developer instructions."""
        e = self.expert(name)
        dest = os.path.join(cwd, ".agents", "skills")
        os.makedirs(dest, exist_ok=True)
        for short, path in self._skill_dirs(e):
            link = os.path.join(dest, short)
            if os.path.islink(link):
                os.remove(link)
            if not os.path.exists(link):
                os.symlink(path, link)
        rc, ex = self._git(cwd, "rev-parse", "--git-path", "info/exclude", timeout=20)
        if rc == 0 and ex.strip():
            ex_path = ex.strip() if os.path.isabs(ex.strip()) else os.path.join(cwd, ex.strip())
            os.makedirs(os.path.dirname(ex_path), exist_ok=True)
            have = _read(ex_path) if os.path.exists(ex_path) else ""
            if ".agents/skills/" not in have.splitlines():
                with open(ex_path, "a", encoding="utf-8") as f:
                    f.write(("" if have.endswith("\n") or not have else "\n") + "# Agent Manager GD experts' skills (never committed)\n.agents/skills/\n")
        return {"args": ["-c", "developer_instructions=" + json.dumps(self.note(e))], "note": self.note(e), "folder": dest}

    @staticmethod
    def note(e: dict) -> str:
        names = ", ".join(k.split("/", 1)[-1] for k in e["skills"])
        return (f"Agent Manager: you work as the expert « {e['title']} ». {e['context'].strip()}\n"
                f"Your skills for this ({names}) are loaded: use them when the task matches."
                + (f" The secrets you need are in your environment: {', '.join(e['secrets'])} (never print them)." if e["secrets"] else ""))
