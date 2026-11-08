"""Loop 10: API keys encrypted at rest and never returned; dictation through the engine (fake transcription)."""
import base64
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.request
import wave
import io

from engine.api import load_token, serve
from engine.keys import Keys
from engine.sessions import Sessions
from engine.store import Store
from engine.tmux import Tmux


class KeysTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-keys-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_key_is_never_stored_in_clear_where_windows_can_protect_it(self):
        k = Keys(self.tmp)
        k.set("openai", "sk-proj-SECRET-é")
        path = os.path.join(self.tmp, "keys", "api", "openai.json")
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")
        with open(path) as f:
            raw = f.read()
        if k.dpapi:
            self.assertNotIn("SECRET", raw)
        self.assertEqual(k.get("openai"), "sk-proj-SECRET-é")
        info = k.describe("openai")
        self.assertTrue(info["set"])
        self.assertNotIn("value", json.dumps(k.all()) if not k.dpapi else "")
        self.assertNotIn("SECRET", json.dumps(k.all()))           # the API never returns a value
        k.delete("openai")
        self.assertEqual(k.get("openai"), "")

    def test_bad_input_is_refused(self):
        k = Keys(self.tmp)
        with self.assertRaises(ValueError):
            k.set("nope", "x")
        with self.assertRaises(ValueError):
            k.set("fly", "line1\nline2")


@unittest.skipUnless(shutil.which("tmux"), "tmux is needed")
class VoiceApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agmgd-voice-")
        os.environ["AGMGD_VOICE_FAKE"] = "Ajoute un test pour le panier, s'il te plaît."
        self.tmux = Tmux("agmgd-voice", tmpdir=self.tmp)
        self.s = Sessions(Store(os.path.join(self.tmp, "s.sqlite3")), self.tmux, self.tmp)
        self.token = load_token(self.tmp)
        self.srv = serve(self.s, self.token, 0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        os.environ.pop("AGMGD_VOICE_FAKE", None)
        self.srv.shutdown()
        self.tmux.kill_server()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def call(self, method, path, body=None):
        req = urllib.request.Request(f"http://127.0.0.1:{self.srv.server_address[1]}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": "Bearer " + self.token})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())

    def test_dictation_returns_text_and_keys_are_listed_without_values(self):
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(b"\0\0" * 16000)
        out = self.call("POST", "/voice/transcribe", {"audio_b64": base64.b64encode(buf.getvalue()).decode(), "seconds": 1})
        self.assertEqual(out["text"], "Ajoute un test pour le panier, s'il te plaît.")
        listed = self.call("GET", "/keys")
        self.assertEqual({k["name"] for k in listed["keys"]}, {"openai", "fly", "anthropic"})
        self.assertTrue(all("value" not in k for k in listed["keys"]))


if __name__ == "__main__":
    unittest.main()


class VoiceErrorsTest(unittest.TestCase):
    def test_a_model_not_allowed_in_the_project_is_explained(self):
        import io
        import urllib.error
        from unittest import mock
        from engine import voice

        def refuse(req, timeout=0):
            body = io.BytesIO(b'{"error": {"message": "Project `proj_x` does not have access to model `m` (sk-proj-abc123)", "code": "model_not_found"}}')
            raise urllib.error.HTTPError(voice.URL, 403, "Forbidden", {}, body)
        with mock.patch("urllib.request.urlopen", refuse):
            with self.assertRaises(ValueError) as e:
                voice.transcribe(b"\0" * 4000, "sk-test-not-real", 1.0)
        self.assertIn("does not allow gpt-4o-mini-transcribe or whisper-1", str(e.exception))
        self.assertIn("Limits", str(e.exception))

