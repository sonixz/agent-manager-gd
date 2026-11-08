"""Voice commands (Loop 11): a transcribed sentence -> an intent, by plain rules (French and English), no model.

Intents: approve, refuse (need a visible confirmation in the app), wrap_up (confirmation), go_to, view, waiting
(who waits for me), new_session, dictate_hint, unknown. A session is named by its name, matched loosely."""
from __future__ import annotations

import re
import unicodedata

VIEWS = {"grille": "grid", "grid": "grid", "tableau": "board", "board": "board", "tableau de bord": "board",
         "focus": "focus", "historique": "history", "history": "history", "revue": "review", "review": "review",
         "depots": "repos", "repos": "repos", "cles": "keys", "keys": "keys"}
RULES = [
    ("approve", r"^(?:approuve|approuver|accepte|valide|oui pour|approve|accept|yes for)\b\s*(.*)$"),
    ("refuse", r"^(?:refuse|refuser|rejette|non pour|deny|refuse|reject|no for)\b\s*(.*)$"),
    ("wrap_up", r"^(?:clos|clore|ferme|termine|wrap up|close)\b(?:\s+la session)?\s*(.*)$"),
    ("waiting", r"^(?:qui m'?attend|qui attend|qu'est-ce qui m'?attend|who(?:'s| is)? waiting(?: for me)?|what(?:'s| is)? waiting)\b.*$"),
    ("new_session", r"^(?:nouvelle session|new session|cree une session|create a session)\b\s*(.*)$"),
    ("view", r"^(?:vue|view|affiche|show|montre)\b\s*(?:la |le |l'|the )?(.*)$"),
    ("go_to", r"^(?:va sur|va a|vas sur|ouvre|aller sur|go to|open|switch to)\b\s*(.*)$"),
]


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[«»\"“”.,!?;:]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def match_session(words: str, sessions: list[dict]) -> dict | None:
    """The session whose name fits best: exact, then contained, then most shared words."""
    w = norm(words)
    w = re.sub(r"^(?:la session |session |le |la |l'|the )", "", w).strip()
    if not w:
        return None
    best, score = None, 0
    for s in sessions:
        n = norm(str(s.get("name", "")))
        if not n:
            continue
        if n == w:
            return s
        sc = 0
        if w in n or n in w:
            sc = 80
        shared = set(w.split()) & set(n.split())
        sc = max(sc, 30 * len(shared))
        if sc > score:
            best, score = s, sc
    return best if score >= 30 else None


def parse(text: str, sessions: list[dict]) -> dict:
    t = norm(text)
    for intent, rx in RULES:
        m = re.match(rx, t)
        if not m:
            continue
        rest = m.group(1).strip() if m.groups() else ""
        if intent == "view":
            v = VIEWS.get(rest) or next((VIEWS[k] for k in VIEWS if k in rest), "")
            if v:
                return {"intent": "view", "view": v, "text": text}
            continue  # "show Themes" falls through to go_to
        if intent == "waiting":
            return {"intent": "waiting", "text": text}
        if intent == "new_session":
            return {"intent": "new_session", "name": rest, "text": text}
        target = match_session(rest, sessions) if rest else None
        if intent in ("approve", "refuse") and target is None and rest == "":
            waiting = [s for s in sessions if s.get("activity") == "approval"]
            target = waiting[0] if len(waiting) == 1 else None   # « approuve » alone: the only one waiting
        if target is None:
            return {"intent": "unknown", "text": text, "reason": f"no session named « {rest} »" if rest else "which session?"}
        return {"intent": intent, "id": target["id"], "name": target["name"], "text": text}
    # a bare session name means « go to »
    target = match_session(t, sessions)
    if target:
        return {"intent": "go_to", "id": target["id"], "name": target["name"], "text": text}
    return {"intent": "unknown", "text": text, "reason": "not a command"}
