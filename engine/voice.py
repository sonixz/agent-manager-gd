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
MODELS = ["gpt-4o-mini-transcribe", "whisper-1"]   # first that works; the setting AGMGD_VOICE_MODEL overrides
PRICE_PER_MIN = {"gpt-4o-mini-transcribe": 0.003, "whisper-1": 0.006}   # USD, OpenAI's price list (estimate shown)
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


def transcribe(wav: bytes, key: str, seconds: float, language: str = "") -> dict:
    fake = os.environ.get("AGMGD_VOICE_FAKE")
    if fake:
        return {"text": fake, "model": "fake", "cost_usd": 0.0}
    if not key:
        raise ValueError("no OpenAI key yet: paste one in Keys to use the voice")
    if len(wav) > MAX_BYTES or len(wav) < 1000:
        raise ValueError("the recording is empty or too long")
    models = [os.environ["AGMGD_VOICE_MODEL"]] if os.environ.get("AGMGD_VOICE_MODEL") else MODELS
    last = ""
    denied: list[str] = []
    for model in models:
        fields = {"model": model, "response_format": "json",
                  "prompt": "Dictée pour un agent de code. Ponctuation et accents français. Noms de fichiers et de commandes exacts."}
        if language:
            fields["language"] = language
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
                         "Settings → Projects → (the key's project) → Limits, allow one of them, then try again")
    raise ValueError("no transcription model available (" + last + ")")


def _openai_error(e) -> dict:
    """OpenAI's error object ({message, code}), without anything that looks like a key."""
    import json
    import re
    try:
        err = json.loads(e.read().decode("utf-8", "replace")).get("error") or {}
    except (ValueError, OSError, AttributeError):
        return {}
    return {"code": str(err.get("code") or ""), "message": re.sub(r"sk-[A-Za-z0-9_\-*]+", "sk-…", str(err.get("message") or ""))[:300]}
