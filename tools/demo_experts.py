"""Captures only (Loop 44): a library of skills and three experts in a throw-away data folder, as « Add Anthropic's
skills » leaves them, without downloading anything: the cache is a small local git repository whose skills carry the
names of Anthropic's but descriptions written here. Nothing reaches the network.
  python3 tools/demo_experts.py <data folder>"""
import json
import os
import subprocess
import sys

home = sys.argv[1]
cache = os.path.join(home, "skills-cache", "anthropic")
SKILLS = {
    "frontend-design": ("Interfaces that look designed, not generic: layout, type, colour and motion.", []),
    "webapp-testing": ("Drive a real browser to check that a web app works, with screenshots.", ["scripts/with_server.py"]),
    "theme-factory": ("Ready themes for slides, documents and pages, applied in one step.", []),
    "docx": ("Make and edit Word documents, tracked changes included.", ["scripts/document.py", "ooxml/unpack.py"]),
    "pdf": ("Read, fill, merge and split PDF files.", ["scripts/fill_form.py"]),
    "pptx": ("Build and edit PowerPoint decks from a layout.", ["scripts/thumbnail.py"]),
    "xlsx": ("Spreadsheets with formulas that stay formulas.", ["recalc.py"]),
    "doc-coauthoring": ("Write a long document together, section by section.", []),
    "mcp-builder": ("Plan, build and test an MCP server that agents can use well.", ["scripts/evaluation.py"]),
    "skill-creator": ("Make a new skill in the Agent Skills format, and test it.", ["scripts/init_skill.py"]),
}
os.makedirs(cache, exist_ok=True)
for name, (desc, scripts) in SKILLS.items():
    d = os.path.join(cache, "skills", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "SKILL.md"), "w") as f:
        f.write(f"---\nname: {name}\ndescription: {desc}\n---\n\n# {name}\n\n(Demo copy for the website's pictures.)\n")
    with open(os.path.join(d, "LICENSE.txt"), "w") as f:
        f.write("                                 Apache License\n                           Version 2.0, January 2004\n")
    for s in scripts:
        p = os.path.join(d, s)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write("# demo\n")
env = {**os.environ, "GIT_AUTHOR_NAME": "demo", "GIT_AUTHOR_EMAIL": "demo@example.com",
       "GIT_COMMITTER_NAME": "demo", "GIT_COMMITTER_EMAIL": "demo@example.com"}
subprocess.run(["git", "init", "-q", cache], check=True, env=env)
subprocess.run(["git", "-C", cache, "add", "-A"], check=True, env=env)
subprocess.run(["git", "-C", cache, "commit", "-q", "-m", "demo"], check=True, env=env)
commit = subprocess.run(["git", "-C", cache, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
root = os.path.join(home, "experts")
os.makedirs(os.path.join(root, "skills"), exist_ok=True)
with open(os.path.join(root, "sources.lock"), "w") as f:
    json.dump({"sources": [{"id": "anthropic", "url": "https://github.com/anthropics/skills.git", "path": "skills",
                            "commit": commit, "added": "2026-11-14", "title": "Anthropic's skills",
                            "page": "https://github.com/anthropics/skills"}]}, f)
own = os.path.join(root, "skills", "discord-moderation")
os.makedirs(own, exist_ok=True)
with open(os.path.join(own, "SKILL.md"), "w") as f:
    f.write("---\nname: discord-moderation\ndescription: Our rules for the community servers: roles, slow mode, what a bot may delete.\n---\n\n# Moderation\n")
print(commit)
