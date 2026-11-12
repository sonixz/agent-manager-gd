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


class VoicePiecesTest(unittest.TestCase):
    """Loop 34: a dictation comes in pieces, cut at each pause; each piece is written down with what was said before."""

    def test_a_piece_goes_out_with_the_words_said_just_before(self):
        import io
        from unittest import mock
        from engine import voice
        self.assertEqual(voice.prompt_for(""), voice.PROMPT)
        told = voice.prompt_for("Ajoute une carte cadeau.\n   Elle ne prend jamais plus que son solde.")
        self.assertTrue(told.startswith(voice.PROMPT))
        self.assertIn("« Ajoute une carte cadeau. Elle ne prend jamais plus que son solde. »", told)
        self.assertLess(len(voice.prompt_for("mot " * 2000)), len(voice.PROMPT) + 520)  # the last words only
        self.assertIn("pas de majuscule au début", told)  # a piece that goes on with the same sentence
        once = voice.prompt_for("Ajoute une carte cadeau.", whole=True)  # the recording in one piece: no such hint
        self.assertIn("« Ajoute une carte cadeau. »", once)
        self.assertNotIn("majuscule", once)
        sent = {}

        def answer(req, timeout=0):
            sent["body"] = req.data
            return io.BytesIO(json.dumps({"text": "  et écris les tests avant le code. "}).encode())
        with mock.patch("urllib.request.urlopen", answer), mock.patch.object(voice, "allowed_models", lambda k: ["gpt-transcribe"]), \
                mock.patch.dict(os.environ, clear=False) as env:
            env.pop("AGMGD_VOICE_FAKE", None)
            out = voice.transcribe(b"\0" * 4000, "sk-test-not-real", 2.0, "", "Ajoute une carte cadeau.")
        self.assertEqual(out["text"], "et écris les tests avant le code.")
        self.assertIn("Ajoute une carte cadeau.".encode(), sent["body"])
        self.assertNotIn(b"sk-test-not-real", sent["body"])  # the key travels in a header, never in the form

    def test_the_fake_voice_of_the_checks_gives_one_phrase_per_piece(self):
        from unittest import mock
        from engine import voice
        with mock.patch.dict(os.environ, {"AGMGD_VOICE_FAKE": "un | deux | trois"}), mock.patch.object(voice, "_fake_turn", 0):
            said = [voice.transcribe(b"", "", 1.0)["text"] for _ in range(4)]
        self.assertEqual(said, ["un", "deux", "trois", "un"])
        with mock.patch.dict(os.environ, {"AGMGD_VOICE_FAKE": "un | deux", "AGMGD_VOICE_FAKE_WHOLE": "un, deux."}):
            self.assertEqual(voice.transcribe(b"", "", 1.0, whole=True)["text"], "un, deux.")


class VoiceErrorsTest(unittest.TestCase):
    def test_a_model_not_allowed_in_the_project_is_explained(self):
        import io
        import urllib.error
        from unittest import mock
        from engine import voice

        def refuse(req, timeout=0):
            body = io.BytesIO(b'{"error": {"message": "Project `proj_x` does not have access to model `m` (sk-proj-abc123)", "code": "model_not_found"}}')
            raise urllib.error.HTTPError(voice.URL, 403, "Forbidden", {}, body)
        with mock.patch("urllib.request.urlopen", refuse), mock.patch.object(voice, "allowed_models", lambda k: ["gpt-transcribe", "whisper-1"]):
            with self.assertRaises(ValueError) as e:
                voice.transcribe(b"\0" * 4000, "sk-test-not-real", 1.0)
        self.assertIn("does not allow gpt-transcribe or whisper-1", str(e.exception))
        self.assertIn("Limits", str(e.exception))

    def test_the_first_model_the_project_allows_is_used_like_the_brain(self):
        import io
        import json as _json
        from unittest import mock
        from engine import voice
        voice._allowed_cache.clear()
        sent = []

        class Resp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def api(req, timeout=0):
            if req.full_url.endswith("/models"):
                return Resp(_json.dumps({"data": [{"id": "gpt-transcribe"}, {"id": "gpt-4o"}]}).encode())
            sent.append(req.data)
            return Resp(b'{"text": "bonjour"}')
        with mock.patch("urllib.request.urlopen", api):
            out = voice.transcribe(b"\0" * 4000, "sk-test-not-real", 2.0, "fr")
        self.assertEqual(out["model"], "gpt-transcribe")
        self.assertIn(b'name="languages[]"', sent[0])
        self.assertEqual(voice.allowed_models("sk-test-not-real"), ["gpt-transcribe"])

