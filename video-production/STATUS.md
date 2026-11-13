# Showcase video — status (the /loop reads this first)

Mission: /mnt/c/git-2026/agent-manager-gd-notes/video/MISSION.md (owner's brief, 2026-11-12).

| # | Step | State |
|---|---|---|
| 1 | Inspect: features, license (MIT, verified: LICENSE + GitHub says MIT, repo public), logo (public/assets/logo.svg), site | done |
| 2 | Film steps film-control, film-wsl, film-repos, film-sandbox, film-tunnel in app/tools_showcase.gd, with frame marks | done |
| 3 | Film them (SHOW_SIZE=1920x1080 SHOW_MOVIE=…) and review frames | done |
| 4 | Narration (ElevenLabs, voice Eric), music + SFX (licensed), license record | done |
| 5 | Compose script (scripts/compose.py → ffmpeg), titles, closing card with logo | done |
| 6 | Render final + web encode + poster; QA (frames, durations, loudness, no secrets) | done |
| 7 | Website: showcase section near the top of public/index.html, player, MIT line | done |
| 8 | Docs: README (reproduce), storyboard (final timestamps), narration, report | done |
| 9 | Brain journal; tell the owner; nothing merged or pushed without OK | todo |

## Notes
- 2026-11-12: first full cut 30.25 s; web encode 3.5 MB; site check passes (9.6 MB). See REPORT.md for limits.
- Waiting on the owner: ElevenLabs plan (commercial use of the audio), « G.D. » by ear, the video itself; merge/push only with OK.
- CHANGELOG: my section « Website: the showcase video » sits right under « Unreleased »; main's Loop 39 section was
  added at the same place by the agent-manager-gd session, so a merge will ask to keep both (keep both, mine first or second).
- The Loop 39 line in index.html #loops: to add at push time (asked by the agent-manager-gd session).
