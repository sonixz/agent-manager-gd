"""Voice dictation (Loop 10): a WAV recorded by the app -> text, through OpenAI's transcription API, with the
OpenAI key the owner pasted in « Keys ». The text goes into the active session's prompt; it is never sent with
Enter by Agent Manager: the owner reads it and presses Enter himself.

AGMGD_VOICE_FAKE=<text> returns that text without any call (tests, captures)."""
from __future__ import annotations

import json
import os
import secrets
import urllib.error
import urllib.request

URL = "https://api.openai.com/v1/audio/transcriptions"
# The Second Brain's order (engine/sources/audio.py): the first one the key's project allows; AGMGD_VOICE_MODEL overrides
MODELS = ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
PRICE_PER_MIN = {"gpt-transcribe": 0.0045, "gpt-4o-transcribe": 0.006, "gpt-4o-mini-transcribe": 0.003, "whisper-1": 0.006}  # USD
_allowed_cache: dict[str, list[str]] = {}  # key fingerprint -> models in order, asked once per engine run
MAX_BYTES = 20 * 1024 * 1024


def _multipart(fields: dict, file_bytes: bytes) -> tuple[bytes, str]:
    b = "----agmgd" + secrets.token_hex(8)
    parts = []
    for k, v in fields.items():
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="speech.wav"\r\n'
                 f"Content-Type: audio/wav\r\n\r\n".encode() + file_bytes + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    return b"".join(parts), b


PROMPT = "Dictée pour un agent de code. Ponctuation et accents français. Noms de fichiers et de commandes exacts."
_fake_turn = 0


def prompt_for(context: str, whole: bool = False) -> str:
    """What the model is told with the audio. A dictation comes in pieces, cut at each pause: the words said just
    before go with each piece, so a sentence that spans two pieces keeps its spelling, its names and its punctuation.
    The recording written in one piece (whole) only gets what the box already held."""
    said = " ".join((context or "").split())[-300:]
    if not said:
        return PROMPT
    if whole:
        return PROMPT + " Ce qui a été dit avant, à ne pas répéter : « " + said + " »"
    return PROMPT + (" Ce qui vient d'être dit juste avant, à ne pas répéter : « " + said + " ». Ce morceau peut continuer "
                     "la même phrase : dans ce cas, pas de majuscule au début.")


def transcribe(wav: bytes, key: str, seconds: float, language: str = "", context: str = "", whole: bool = False) -> dict:
    fake = os.environ.get("AGMGD_VOICE_FAKE")
    if fake:
        import time
        global _fake_turn
        time.sleep(float(os.environ.get("AGMGD_VOICE_FAKE_DELAY") or 0))  # checks: a long dictation takes a while to write down
        if whole and os.environ.get("AGMGD_VOICE_FAKE_WHOLE"):  # checks: the recording in one piece reads better than its pieces
            return {"text": os.environ["AGMGD_VOICE_FAKE_WHOLE"], "model": "fake", "cost_usd": 0.0}
        said = [p.strip() for p in fake.split("|")]  # checks: « a | b | c » gives one phrase per piece, in turn
        _fake_turn += 1
        return {"text": said[(_fake_turn - 1) % len(said)], "model": "fake", "cost_usd": 0.0}
    if not key:
        raise ValueError("no OpenAI key yet: paste one in Keys to use the voice")
    if len(wav) > MAX_BYTES or len(wav) < 1000:
        raise ValueError("the recording is empty or too long")
    models = [os.environ["AGMGD_VOICE_MODEL"]] if os.environ.get("AGMGD_VOICE_MODEL") else allowed_models(key)
    last = ""
    denied: list[str] = []
    for model in models:
        fields = {"model": model, "response_format": "json", "prompt": prompt_for(context, whole)}
        if language:
            fields["languages[]" if model == "gpt-transcribe" else "language"] = language
        body, boundary = _multipart(fields, wav)
        req = urllib.request.Request(URL, data=body, method="POST", headers={
            "Authorization": "Bearer " + key, "Content-Type": "multipart/form-data; boundary=" + boundary})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                text = str(json.loads(r.read()).get("text", "")).strip()
            return {"text": text, "model": model,
                    "cost_usd": round(PRICE_PER_MIN.get(model, 0.006) * max(seconds, 1.0) / 60.0, 5)}
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
            detail = _openai_error(e)
            if e.code in (400, 404) or (e.code == 403 and detail.get("code") == "model_not_found"):
                # this model is not available (or not allowed in the key's project): try the next one
                if e.code == 403:
                    denied.append(model)
                continue
            if e.code == 401:
                raise ValueError("OpenAI refused the key (401): paste it again in Keys")
            raise ValueError("transcription failed: " + last)
        except OSError as e:
            raise ValueError("transcription failed: " + str(e)[:120])
    if denied:
        raise ValueError("your OpenAI project does not allow " + " or ".join(denied) + ": on platform.openai.com, open "
                         "Settings → Projects → (the key's project) → Limits, allow gpt-transcribe (or another), then try again")
    raise ValueError("no transcription model available (" + last + ")")


def allowed_models(key: str) -> list[str]:
    """Our models in order, keeping those the key may use (GET /models: free, nothing sent). If the list cannot be
    read, all of them, tried in order."""
    import hashlib
    fp = hashlib.sha256(key.encode()).hexdigest()[:16]
    if fp in _allowed_cache:
        return _allowed_cache[fp]
    try:
        req = urllib.request.Request("https://api.openai.com/v1/models", headers={"Authorization": "Bearer " + key})
        with urllib.request.urlopen(req, timeout=20) as r:
            ids = {m.get("id") for m in json.loads(r.read()).get("data", [])}
        found = [m for m in MODELS if m in ids]
    except (urllib.error.URLError, OSError, ValueError):
        return list(MODELS)
    _allowed_cache[fp] = found or list(MODELS)
    return _allowed_cache[fp]


def _openai_error(e) -> dict:
    """OpenAI's error object ({message, code}), without anything that looks like a key."""
    import json
    import re
    try:
        err = json.loads(e.read().decode("utf-8", "replace")).get("error") or {}
    except (ValueError, OSError, AttributeError):
        return {}
    return {"code": str(err.get("code") or ""), "message": re.sub(r"sk-[A-Za-z0-9_\-*]+", "sk-…", str(err.get("message") or ""))[:300]}
