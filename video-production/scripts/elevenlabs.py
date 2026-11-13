"""ElevenLabs calls for the showcase video: narration (text to speech), music and sound effects.
The key comes from the environment (dotenvx), never printed. Usage:
  elevenlabs.py say   <voice_id> <text_file> <out.mp3>
  elevenlabs.py music <prompt_file> <milliseconds> <out.mp3>
  elevenlabs.py sfx   <prompt> <seconds> <out.mp3>
"""
import json, os, sys, urllib.error, urllib.request

KEY = os.environ["ELEVENLABS_API_KEY"]


def post(path: str, body: dict) -> bytes:
    r = urllib.request.Request("https://api.elevenlabs.io" + path, data=json.dumps(body).encode(),
                               headers={"xi-api-key": KEY, "Content-Type": "application/json", "Accept": "audio/mpeg", "User-Agent": "video-tool"})
    try:
        with urllib.request.urlopen(r, timeout=300) as f:
            return f.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"ElevenLabs answered {e.code}: {e.read()[:300].decode(errors='replace')}")


def main() -> None:
    what = sys.argv[1]
    if what == "say":
        text = open(sys.argv[3], encoding="utf-8").read().strip()
        audio = post(f"/v1/text-to-speech/{sys.argv[2]}?output_format=mp3_44100_192", {"text": text, "model_id": os.environ.get("EL_MODEL", "eleven_multilingual_v2"),
                     "voice_settings": {"stability": 0.55, "similarity_boost": 0.75, "style": 0.2, "use_speaker_boost": True}})
        out = sys.argv[4]
    elif what == "music":
        audio = post("/v1/music?output_format=mp3_44100_192", {"prompt": open(sys.argv[2], encoding="utf-8").read().strip(), "music_length_ms": int(sys.argv[3]), "force_instrumental": True})
        out = sys.argv[4]
    elif what == "sfx":
        audio = post("/v1/sound-generation?output_format=mp3_44100_192", {"text": sys.argv[2], "duration_seconds": float(sys.argv[3]), "prompt_influence": 0.5})
        out = sys.argv[4]
    else:
        sys.exit(__doc__)
    with open(out, "wb") as f:
        f.write(audio)
    print("wrote", out, len(audio), "bytes")


if __name__ == "__main__":
    main()
