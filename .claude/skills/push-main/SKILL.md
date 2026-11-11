---
name: push-main
description: Push main to GitHub the reproducible way. Bring the website (index, Docs, How-to, screenshots), the CHANGELOG and the README up to date with the commits about to go out, run every gate with tools/push_main.sh, get the owner's OK, push, then check GitHub and the website online. Use when the owner asks to push main (« pousse main », « prépare le push », « mets le site à jour avant de pousser ») or invokes /push-main.
---

# Push main

The rule (owner, 2026-11-11): main never goes out as is. First the website, its index with the loops list, the Docs
and the devlog follow what changed, where needed; then main is pushed. The same steps each time, in this order. `tools/push_main.sh` checks and
pushes; the judgement in between (what must the public face say now?) is yours.

Never here: a forced push, another branch, a tag, a GitHub Release, the repository's visibility. Those are the
owner's.

## 1. See where things stand

```bash
tools/push_main.sh --quick      # the report without the tests: changes nothing, pushes nothing
```

- Not on main, a merge in progress, or main and GitHub's main went separate ways: stop and tell the owner.
- « not in main, so not in this push »: work waits on a branch. Say so. Merging it into main is the owner's decision
  (Finish in Agent Manager, or their word in this conversation); never merge on your own.
- « Nothing to push »: say so and stop.

## 2. Read what goes out

Section 3 of the report lists the commits. For each one, answer: what does someone using the app see? A new feature,
a behaviour that changed, a menu or a key renamed, a fix, or nothing.

## 3. Bring the public face up to date, where needed

| What changed | Where it must show |
|---|---|
| A loop (a commit named « Loop N ») | the loops list of `public/index.html` (`#loops`): one line per loop or group of loops. Every loop is published there |
| Every push | the devlog, kept beside the repository, not in it (`../agent-manager-gd-notes/DEVLOG.md`): one entry per loop, newest last, with the owner's words, what was built, what was not verified |
| Anything a user sees | `CHANGELOG.md`, under Unreleased, newest first, in plain words |
| A new feature or setting, a renamed menu or key | `public/docs.html`, in its section; names exactly as the app shows them |
| A path of several steps | a How-to guide: `tools/howto/guides.py` (the data), a `howto-<id>` step in `app/tools_showcase.gd`, `tools/showcase.sh howto-<id>`, then `python3 tools/howto/build_page.py` |
| Something worth the home page | `public/index.html`: its section, its screenshot, the loops list (`#loops`) |
| The look of a view | retake only the screenshots that show it: `tools/showcase.sh <step…>` |
| What the app protects or promises (permissions, keys, ports, data) | `SECURITY.md`, « In this repository » in `AI-NOTICE.md`, `public/docs.html#security` |
| Install or requirements | `README.md`, `docs/INSTALL.md`, `public/docs.html#install` |
| The list of what the app does | `README.md` |

- « Nothing to change » is a valid answer for a commit. Keep the reason: the owner will ask.
- Check each claim in the code before writing it. The Docs describe what the app does, not what was planned.
- Screenshots come from the real app on a private virtual display, on the fictional workspace. Never open a Godot
  window, never capture the owner's own sessions. `tools/build_native.sh` must have run once. Everything at once:
  `tools/site.sh` (about 15 minutes).
- Two things are called sandbox; a sentence must say which one it means. « Sandboxes » are ours: Fly.io machines
  reached through an SSH tunnel. Claude Code's own sandbox (bubblewrap, socat) is Claude Code's native feature:
  always named as such, never as ours.

## 4. Commit the public face

One commit, in plain words, that says what the website and the Docs now show. Nothing uncommitted may remain: the
push takes main as committed.

## 5. Run every gate

```bash
tools/push_main.sh              # about a minute: what goes out, CHANGELOG and website follow, How-to page,
                                # every loop in the index's list and in the devlog, engine tests, website checks,
                                # no secret or personal trace, commit identity, words
```

- A FAIL is a fact: fix it and run again. Never work around a gate.
- A WARN is a judgement: read it. It is fine only if you can say why in one sentence.

## 6. The owner's OK

Show the owner, briefly: the commits going out; what changed on the public face, or why nothing had to; the verdict;
each warning with your reading of it. Then ask. Every push needs its own OK: an earlier one does not count.

## 7. Push

```bash
tools/push_main.sh --push               # the same gates again, then git push origin main (fast-forward only)
tools/push_main.sh --push --reviewed    # when the owner accepted the warnings
```

If the push is refused for write access: the owner ticks « Allow write access » on the repository's deploy key.

## 8. After

```bash
tools/push_main.sh --after      # GitHub's main, the tests on GitHub for that commit, the website's pages
```

- The website online is published by gd-project's « Publish the site » workflow, which takes `public/` from this
  repository's main. It runs on a push to gd-project's main, or by hand (Actions › Publish the site › Run workflow).
  When `public/` changed in this push, tell the owner it must run once more, then run `--after` again.
- Second Brain: a session journal entry (the commits pushed, what changed on the website, what is left) and an
  update of the project card.
