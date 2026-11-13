---
name: release
description: Make a GitHub release of Agent Manager GD the reproducible way. Build the Windows archive from the commit GitHub's main holds, check it with tools/release.sh (contents, version, built from that commit, nothing personal, no key), write the notes, get the owner's OK, publish, then check what GitHub serves. Use when the owner asks for a release (« prépare la release », « publie la release », « on sort une version ») or invokes /release.
---

# Release

The rule (owner, 2026-11-13): a release is cut from a commit, and that commit is already pushed. The same steps each
time, in this order. `tools/release.sh` builds, checks and publishes; the judgement in between (the version, the
notes, what was not verified) is yours. Each release needs the owner's OK: an earlier one does not count.

Never here: a release from a commit GitHub's main does not hold, a published version replaced or its tag moved, a
release deleted, the repository's visibility. Those are the owner's. main itself goes out through push-main.

## 1. The commit and the version

- The commit is GitHub's main, with its tests green there. Work that is not pushed is not in the release: say so,
  and push first (push-main, with its own OK) when the owner wants it in.
- The version: `0.<loop>.0-alpha` while in alpha, the loop being the highest one the commit holds (0.39.0-alpha held
  the loops up to 39). A release between two loops raises the last number (0.39.1-alpha). A version with a suffix is
  published as a pre-release. A published version is never reused.
- `CHANGELOG.md` gets its heading before the release, in the commit that is released, because the archive ships that
  file: `## <version> · <date>` above what the release holds, and a line saying where to download it. What comes
  later starts again under `## Unreleased`. Push that through push-main.

## 2. Build and check

```bash
tools/release.sh <version>      # builds dist/AgentManagerGD-<version>-win64.zip and checks it; publishes nothing
```

- It refuses a tree with uncommitted changes, a commit that is not GitHub's main, tests that are not green there, a
  version already published, a CHANGELOG without the version's heading.
- It rebuilds the terminal library (`tools/build_native.sh template_release`, several minutes) when the one at hand
  is older than `native/` or carries a path of the builder's home folder. godot-cpp's headers write source paths
  into the library: the release build maps the home folder out, and the check proves it.
- The archive is checked: it opens; the app, both terminal libraries, the engine, the installers and the notices are
  there; VERSION says the version; the engine, the CHANGELOG, the README and the installer are HEAD's (built from
  this commit); no capture tool is packed; no path of the builder's folders, no key, no token, no `.env`.
- A FAIL is a fact: fix it and run again. Never work around a check. `--check` runs the checks again without building.
- Linux: no release build while Godot's Linux export template is not installed. Say so in the notes.

## 3. The notes

The first run drafts `build/release/NOTES-<version>.md` from `notes-template.md` and the CHANGELOG's section for the
version. Read it as someone who will install it:

- « What changed » says what a user sees, in plain words, not the list of commits.
- « Known limits » is true today: what is beta, what was found and not fixed, what does not work yet.
- Nothing is claimed that was not checked. The notes carry the archive's checksum: if the archive is rebuilt, the
  check refuses notes that give another one.

## 4. What this cannot check, said to the owner

The app is not launched here: no Godot window is opened on the owner's computer, and a second app could reach the
running engine. So the archive is checked, not the app. The owner tries it on a Windows machine, a clean one when it
can be, before or right after publishing (their choice, each time):

1. Unzip, run `install.ps1` (no administrator question must come), start it from the Start menu.
2. The Setup check reads the machine and says what is missing.
3. A shell session opens a terminal that answers; a Claude Code or Codex session shows its state.
4. Close the app and start it again: the sessions are still there.

## 5. The owner's OK

Show the owner, briefly: the commit and the version; what the release holds and what it does not (work not pushed);
the verdict of the checks; what was not verified; the notes. Then ask.

## 6. Publish

```bash
tools/release.sh <version> --publish    # the same checks, then the GitHub release with the archive and the notes
tools/release.sh <version> --after      # the release as GitHub shows it; the archive downloaded again and compared
```

GitHub creates the tag `v<version>` on the released commit. Nothing is tagged by hand.

## 7. After

- The website and the Docs link to the Releases page, not to one version: nothing to change there for a new release.
- The devlog (`../agent-manager-gd-notes/DEVLOG.md`): an entry with the owner's words, what was published, what was
  not verified.
- Second Brain: a session journal entry (version, commit, checksum, what was checked, what was not) and an update of
  the project card.
- A release that proves wrong is not replaced: tell the owner, say it in its notes on GitHub, fix on main, and
  publish the next number.
