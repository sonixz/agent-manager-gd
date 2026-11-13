#!/usr/bin/env bash
# The app's two small sounds, generated once through the ElevenLabs API from tools/sound-prompts.txt into
# app/assets/audio/<name>.mp3 and committed: the app never calls ElevenLabs. Existing files are kept; --force or a
# name regenerates. The key comes from an encrypted .env through dotenvx (ELEVENLABS_API_KEY), never printed;
# KEY_DIR picks the project whose .env holds it (the owner chose Second Brain's: ../second-brain-gd).
#   tools/sounds.sh [--force] [name…]
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTENVX="${DOTENVX:-$HOME/.local/bin/dotenvx}"
KEY_DIR="${KEY_DIR:-$REPO/../second-brain-gd}"
if [[ -z "${ELEVENLABS_API_KEY:-}" ]]; then
  cd "$KEY_DIR" && exec "$DOTENVX" run -q -- "$REPO/tools/sounds.sh" "$@"
fi
cd "$REPO"
OUT="app/assets/audio"; mkdir -p "$OUT"
FORCE=0; ONLY=()
for a in "$@"; do [[ "$a" == --force ]] && FORCE=1 || ONLY+=("$a"); done
made=0; kept=0; failed=0
while IFS='|' read -r kind name seconds prompt; do
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  file="$OUT/$name.mp3"
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    hit=0; for o in "${ONLY[@]}"; do [[ "$o" == "$name" ]] && hit=1; done; [[ "$hit" == 1 ]] || continue
  elif [[ -f "$file" && "$FORCE" == 0 ]]; then kept=$((kept + 1)); continue; fi
  body=$(python3 -I -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "duration_seconds": float(sys.argv[2]), "prompt_influence": 0.5}))' "$prompt" "$seconds")
  code=$(curl -s -o "$file.tmp" -w "%{http_code}" -H "xi-api-key: $ELEVENLABS_API_KEY" -H "Content-Type: application/json" -d "$body" https://api.elevenlabs.io/v1/sound-generation)
  if [[ "$code" == "200" ]] && head -c 3 "$file.tmp" | grep -q -a -E 'ID3|^\xff'; then
    mv "$file.tmp" "$file"; echo "sounds.sh: $name ${seconds}s -> $file ($(stat -c %s "$file") bytes)"; made=$((made + 1))
  else
    echo "sounds.sh: FAILED $name (HTTP $code): $(head -c 160 "$file.tmp" 2>/dev/null)" >&2; rm -f "$file.tmp"; failed=$((failed + 1))
  fi
done < tools/sound-prompts.txt
echo "sounds.sh: $made generated, $kept kept, $failed failed"
[[ "$failed" == 0 ]]
