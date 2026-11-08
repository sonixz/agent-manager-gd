"""Loop 11: spoken commands understood by plain rules, in French and English."""
import unittest

from engine.voice_commands import parse

SESSIONS = [
    {"id": "a1", "name": "Brain themes", "activity": "approval"},
    {"id": "b2", "name": "Docs", "activity": "done"},
    {"id": "c3", "name": "Cart refactor", "activity": "waiting"},
]


class VoiceCommandsTest(unittest.TestCase):
    def check(self, text, intent, **want):
        got = parse(text, SESSIONS)
        self.assertEqual(got["intent"], intent, got)
        for k, v in want.items():
            self.assertEqual(got[k], v, got)

    def test_french(self):
        self.check("Approuve Brain themes.", "approve", id="a1")
        self.check("approuve", "approve", id="a1")                    # the only one waiting for an OK
        self.check("Refuse la session Docs", "refuse", id="b2")
        self.check("Va sur le panier… cart refactor", "go_to", id="c3")
        self.check("Ouvre Docs", "go_to", id="b2")
        self.check("Vue grille", "view", view="grid")
        self.check("Affiche le tableau de bord", "view", view="board")
        self.check("Qui m'attend ?", "waiting")
        self.check("Clos la session Docs", "wrap_up", id="b2")
        self.check("Nouvelle session Tests du panier", "new_session", name="tests du panier")
        self.check("Docs", "go_to", id="b2")                          # a bare name opens it
        self.check("Écris-moi un poème", "unknown")

    def test_english(self):
        self.check("approve brain themes", "approve", id="a1")
        self.check("Who is waiting for me?", "waiting")
        self.check("go to cart refactor", "go_to", id="c3")
        self.check("show the history", "view", view="history")
        self.check("close Docs", "wrap_up", id="b2")

    def test_an_unknown_session_is_not_guessed(self):
        self.check("approuve Terminal", "unknown")


if __name__ == "__main__":
    unittest.main()
