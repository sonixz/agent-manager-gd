# Contributing

Thank you for helping. Issues, ideas and pull requests are welcome; small, focused changes are the easiest to review.

## Set up

- Python 3.10+ (standard library only) and tmux where the engine runs (Linux, or WSL on Windows); git.
- Godot 4.7 for the app.
- The terminal extension, built once: `tools/build_native.sh` (toolchain in `native/vtterm/README.md`).

Run the app with `godot --path app` (or open `app/` in Godot). It starts the engine (`python3 -m engine`) itself.

## Tests

```bash
python3 -m unittest discover -s tests/python -t .
```

They need tmux; a fake Claude Code and Codex stand in for the real ones. Keep them green, and add a test with each
engine change.

## Screenshots and the website

`public/` is the website (home, How-to, Docs). Screenshots come from the real app on a private virtual display (Xvfb),
on a fictional workspace with recorded agent screens:

```bash
tools/showcase.sh <step…>      # one or more screenshots (see app/tools_showcase.gd)
tools/site.sh                  # everything, then the checks (links, images, nothing personal, weight)
tools/site.sh --check          # the checks only
```

How-to guides are data in `tools/howto/guides.py`; `python3 tools/howto/build_page.py` writes `public/howto.html`.

## Rules of the house

- The terminal must stay impeccable: accents, colours, keys and speed are not negotiable.
- Local-first, no secrets in the repository or in logs, no administrator rights, no silent downloads, agent CLIs run
  as the user's own tools. The full list is in [AGENTS.md](AGENTS.md).
- Commit messages say what changed and why, in plain words.
- By contributing, you agree that your contribution is licensed under the MIT licence of this project.
