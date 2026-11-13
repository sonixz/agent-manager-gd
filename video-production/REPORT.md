# Production report — showcase video (2026-11-12)

Brief: the owner's mission « Cinematic Product Showcase & Website Integration » (kept beside the repository:
`agent-manager-gd-notes/video/MISSION.md`). Made by Claude Code in the « site » session, branch am/site.

## What the video shows (all real app, filmed)

| Feature | Seen in the video | Source in the app |
|---|---|---|
| Control room, sessions | Grid of four live terminals, Board of six tiles, the session list with states | Focus/Grid/Board views |
| WSL and the computer | WSL memory, processors, disk; memory by session over an hour, with the pointer's tooltip | the ground button's page (host dashboard) |
| Repositories and git | GitHub and Azure DevOps lines, key states, a line unfolded with its public deploy key and the metro map of its branches (agent branches in worktrees) | Repos page |
| Cloud sandboxes | inventory tiles, size cards with Fly.io's published prices, a size chosen and the estimate updated, costs | Sandboxes page |
| Tunnel, proxy, local bridge | a running sandbox's health charts; a port brought to localhost (« Bring it to my localhost »), a SOCKS proxy, a rule that lets the sandbox reach a port of this computer | Sandboxes page › Tunnel and ports |

## How it was captured

- Godot's movie mode (`--write-movie`, 30 fps PNG frames) of the real app, on a private Xvfb display, at 1920×1080
  (`tools/showcase.sh` with `SHOW_MOVIE`; an `app/override.cfg` is written for the run and removed, because the movie
  mode ignores `--resolution`). No window was opened, nothing of the owner's own sessions or data was filmed.
- The interactions are scripted in five steps of `app/tools_showcase.gd` (`film-*`): view changes, the pointer over
  the memory chart (real mouse events sent to the chart), a repository unfolded, a size card chosen, the tunnel's
  connect, port, SOCKS and way-back calls. Each step writes frame marks used by the edit.
- Camera moves: computed on a 4× enlarged frame (`zoompan` after `scale=7680:4320`), so they glide without the
  half-pixel wobble of a plain zoompan (measured on a still: 0 backward steps over 180 frames, against 79 before).

## Demonstration data (documented, not real activity)

- The workspace is fictional: user « dev », three small git projects (`tools/showcase/make_workspace.sh`); the agents'
  terminals replay real recorded Claude Code / Codex screens (`tools/showcase/scenes`).
- WSL page: the figures are the made-up computer the website's screenshots already use (`_made_up_host`,
  `_made_up_hour` in `app/tools_showcase.gd`): 16 GB, four sessions. The page and its drawing are the app's own.
- Sandboxes: Fly.io, ssh and the sandbox are stand-ins (`tests/python/standins/flyctl`, `.../ssh`,
  `tools/demo_sandboxes.py`). **Nothing was deployed and nothing was billed.** The prices are Fly.io's published
  prices as the app shows them (docs.fly.io/about/pricing, read 2026-11-12). The tunnel's relay, its counting and the
  page are the real ones; the health figures move through `scripts/standin_health.py`.
- The SSH key on screen is the public key made for the fictional repository, never a private key.

## Tools

ffmpeg n8.1.3-35 (BtbN autobuild-2026-11-11-12-39, GPL build, sha256 checked against the published
checksums.sha256, installed in `~/.local/opt`, not in the repository), Godot 4.7.2 (movie mode), Python 3.12,
ElevenLabs API (voice, music, effects), Edge headless (page check).

## Audio and asset sources

| Asset | Source | Licence / terms |
|---|---|---|
| Narration (6 lines) | ElevenLabs text to speech, premade voice « Eric » (cjVigY5qzO86Huf0OWal), eleven_multilingual_v2, the owner's account | ElevenLabs terms for the owner's plan (see limits) |
| Music (`music-a.mp3`, 32 s, 120 BPM) | ElevenLabs Music, generated from `assets/audio/music-prompt.txt`, instrumental | same |
| Effects (impact, whoosh) | ElevenLabs sound effects | same |
| Title font | JetBrains Mono (`app/assets/fonts`) | SIL Open Font License 1.1 (`app/assets/fonts/OFL.txt`) |
| Logo | `public/assets/logo.svg`, the project's own | MIT, with the project |
| Footage | the app itself | MIT, with the project |

## Website changes

- `public/index.html`: a `#showcase` section right under the hero: « Built for AI Builders. », « Every agent. Every
  environment. One control room. », the description, the video (controls, `playsinline`, `preload="none"`, poster,
  16:9, a text description, a download link as fallback; no autoplay), « Open Source · MIT Licensed », links to the
  GitHub repository and to the features.
- `public/css/style.css`: the player's styles (the site's terminal frame), stylesheet version bumped.
- `public/assets/video/`: `showcase.mp4` (H.264 High, 1920×1080, 30 fps, AAC 96 kb/s, 3.5 MB, faststart) and
  `showcase-poster.webp` (an untitled frame of the filmed control room).

## Checks run

- Master: 30.25 s, H.264 High 1920×1080 30 fps, AAC stereo 48 kHz; loudness −13.3 LUFS integrated, peak −1.2 dBFS.
- Picture: one frame per second reviewed (contact sheet), the zoomed tunnel and size frames read at full size;
  web encode read at full size (repository line, health charts): legible.
- License: `LICENSE` is MIT; GitHub reports the repository public with the MIT licence.
- No secret on screen: fictional workspace only; the only key shown is a public deploy key made for it.
- Website: `tools/site.sh --check` passes (links, images, nothing personal in reports, weight 9.6 MB < 10 MB);
  rendered in Edge headless at 1440 px and 480 px wide.

## Limits and deviations

- **Licence of the ElevenLabs audio not verified**: the API key is scoped and cannot read the account's plan. On
  paid plans ElevenLabs grants commercial use; on the free plan it asks for attribution and allows no commercial use.
  The owner should confirm the plan before the video is published.
- **Pronunciation of « G.D. » not heard**: the key cannot use speech to text, and the agent cannot listen. To check by ear.
- The music has no built-in final hit at the logo; an ElevenLabs impact effect is placed on the logo instead.
- The sandbox scene shows the size choice and the cost estimate, not a provisioning sequence: with stand-ins the
  deploy would end on a terminal that cannot connect, which would misrepresent the real flow. No real deployment
  was made (no authorisation for charges).
- The film's clock: Godot films slower than real time (about 20 %), so processes outside Godot (the replayed
  terminals, the stand-in readings) move faster in the film than in reality. Nothing on screen depends on it.
- The website check's 10 MB limit sets the web encode at about 820 kb/s (two passes); the master is kept locally.

# V5 (2026-11-13): Agent Manager GD with Second Brain GD, 48.25 s

**Genuinely executed** (established): a session started from Agent Manager's New session with « Share the Second Brain »
and « Document this session »; the user's own Claude Code (v2.1.323, Opus 5.5, auto mode) edited README.md of the
demo project and proposed the decision through the Second Brain's MCP (`propose_item`); the demo Second Brain (a copy
of Second Brain GD, a temporary home, its showcase Brain) showed « 1 proposals wait for your approval »; its own
Approve button was pressed by the film script, as the owner would; the real archivist (OpenAI) filed it as « Acme
Store gift card balance and remainder rule » in Projects › Acme Store, a place it created; the item is shown in the
graph. Both apps were filmed at the same time; the side-by-side shot uses both films of that moment.

**Illustration, not footage**: the frames around the two apps and the light that travels between them in the side-by-side
shot; the titles; the closing card.

**Stand-ins** (as in V1): Fly.io, ssh and the sandbox (nothing deployed, nothing billed); the other agents' terminals
replay recorded screens; Keys › Secrets shows made-up values and a made-up journal of handovers.

**Approvals**: tested before for real (a Claude Code session in « Ask before acting »: Enter approved, Escape refused);
the film's approval is the app's own Approve button on a replayed agent.

**Limits found**: Second Brain's timeline shows a French line in the English interface (« Avant les changements de… »,
a restore point's label): left out of the cut, to report to the Second Brain project. A folder Claude Code does not
trust yet asks first with « No, exit » highlighted and no hook fires: the film step answers it (Down, Enter) off camera.

**Licences**: Agent Manager GD and Second Brain GD are both MIT and public (GitHub, checked 2026-11-13). Audio: ElevenLabs
(voice Eric, Music, effects) on the owner's account; the plan, and so the commercial use, is still to confirm.
