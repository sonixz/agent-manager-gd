#!/usr/bin/env bash
# From the master (scripts/compose.py) to what the website serves: a lighter H.264 for the page and a poster image.
#   video-production/scripts/render.sh     → output/agent-manager-showcase-web.mp4, public/assets/video/{showcase.mp4,showcase-poster.webp}
set -euo pipefail
cd "$(dirname "$0")/.."
FF="${FFMPEG:-$HOME/.local/opt/ffmpeg-n8.1.3-35/bin/ffmpeg}"
mkdir -p ../public/assets/video
# two passes at about 820 kb/s: about 3.5 MB, so public/ stays under the site check's 10 MB (tools/site.sh --check)
(cd work && "$FF" -hide_banner -loglevel error -y -i ../output/agent-manager-showcase.mp4 -c:v libx264 -preset veryslow -b:v 820k -tune stillimage \
  -pass 1 -passlogfile x264 -an -f mp4 /dev/null)
(cd work && "$FF" -hide_banner -loglevel error -y -i ../output/agent-manager-showcase.mp4 -c:v libx264 -preset veryslow -b:v 820k -maxrate 2500k -bufsize 5000k \
  -tune stillimage -pass 2 -passlogfile x264 -profile:v high -level 4.1 -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart ../output/agent-manager-showcase-web.mp4)
cp output/agent-manager-showcase-web.mp4 ../public/assets/video/showcase.mp4
# the poster: the control room as filmed (no title on it), the frame where the grid is settled
F=$(python3 -c "import json;print(json.load(open('work/marks.json'))['film-control']['grid']['frame']+45)")
"$FF" -hide_banner -loglevel error -y -i "captures/film-control/frame$(printf %08d "$F").png" -c:v libwebp -quality 82 ../public/assets/video/showcase-poster.webp
ls -la output/agent-manager-showcase*.mp4 ../public/assets/video/
