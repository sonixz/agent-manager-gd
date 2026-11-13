# The showcase video

The 30-second video on the home page (`public/index.html#showcase`, files in `public/assets/video/`). Everything in it
is the real app, filmed on a private virtual display (Xvfb, never a window) with the fictional workspace the website
screenshots use (user « dev », projects in `~/code`). Only the titles, the closing card and the sound are added.

## Remake it

Needs: `tools/build_native.sh` run once in this checkout (or the terminals film empty), ffmpeg (the pinned build:
`~/.local/opt/ffmpeg-n8.1.3-35`, BtbN autobuild-2026-11-11-12-39, sha256 checked; another path with `FFMPEG=`).

```bash
# 1. film the five scenes (about 10 min): frames in video-production/captures/<step>/, marks in build/showcase/report-<step>.txt
SHOW_SIZE=1920x1080 SHOW_MOVIE=$PWD/video-production/captures \
  tools/showcase.sh film-control film-wsl film-repos film-sandbox film-tunnel
# 2. cut and mix (about 1 min): video-production/output/agent-manager-showcase.mp4 (master, about 18 MB)
python3 video-production/scripts/compose.py
# 3. the website's files (about 2 min): public/assets/video/showcase.mp4 (3.5 MB) and showcase-poster.webp
video-production/scripts/render.sh
```

When the app's look changes, steps 1 to 3 are enough: the audio is kept (`assets/audio/`). Shots are picked by the
marks the film steps leave (`mark <name> <frame> [x y w h]`), so they follow the app when a page moves.

## Change the words or the sound

- Narration: edit `narration.txt`, then for each line (the key never printed, through dotenvx):
  `cd /mnt/c/git-2026/second-brain-gd && dotenvx run -q -f .env -- python3 -I <repo>/video-production/scripts/elevenlabs.py say cjVigY5qzO86Huf0OWal <line.txt> <repo>/video-production/assets/audio/vo-<id>.mp3`
  A longer line may need a longer shot: the plan is in `scripts/compose.py` (`plan`, `titles`, `vo`).
- Music: `elevenlabs.py music assets/audio/music-prompt.txt 32000 assets/audio/music-a.mp3` (a new take each time).
- Effects: `elevenlabs.py sfx "<description>" <seconds> assets/audio/sfx-<name>.mp3`.

## Files

| Path | What |
|---|---|
| `storyboard.md` | the video as it is, second by second |
| `narration.txt` | the spoken words |
| `REPORT.md` | how it was made, sources and licences, checks, limits |
| `scripts/compose.py` | the edit: shots, glide zooms, titles, mix |
| `scripts/render.sh` | web encode and poster |
| `scripts/elevenlabs.py` | voice, music, effects |
| `scripts/standin_health.py` | the stand-in sandbox's moving health readings (tunnel scene) |
| `scripts/logo_png.gd` | `public/assets/logo.svg` as a PNG for the closing card |
| `assets/audio/` | the exact takes used, and the music prompt |
| `captures/`, `work/`, `output/` | made by the scripts, not in git |

## Stills on the website

Four screenshots of the home page are single frames of these films (1920x1080, WebP quality 80), taken from
`captures/<step>/frameNNNNNNNN.png` near the step's marks: `film-wsl` 460 → `public/assets/showcase/film-wsl.webp`,
`film-repos` 520 → `film-repos-metro.webp`, `film-sandbox` 380 → `film-sandbox-size.webp`, `film-tunnel` 1030 →
`film-tunnel-wire.webp`. `tools/site.sh` does not remake them; after
a new film, take them again with ffmpeg (`-i frame.png -c:v libwebp -quality 80 out.webp`).
