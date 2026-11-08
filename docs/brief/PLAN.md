# Agent Manager GD — Plan des loops

Chaque loop se termine par une revue du propriétaire (captures, rapport en français) avant la suivante.

| Loop | But | Fini quand |
|---|---|---|
| **1** | Vision, plan, recherches (marché, terminal) | Ce dossier `docs/` existe et le propriétaire l'a lu |
| **2** | **Prototype du terminal, « oui ou non »** | Un candidat passe toute la grille de `docs/research/TERMINAL.md`, mesurée, avec captures ; sinon on s'arrête ou on change d'approche |
| 3 | Moteur Python + sessions tmux persistantes | Lancer, fermer l'appli, rouvrir : les sessions sont là, avec leur terminal |
| 4 | Arbre de projets, états en direct, prompt rapide | On voit qui travaille / attend / a fini, on répond sans entrer |
| 5 | Ressusciter, redémarrer, fork, worktrees | Une session morte revit sur sa conversation ; un fork a sa branche |
| 6 | **Brain branché d'office** | Chaque session a le MCP du Brain avec sa clé ; la frise du Brain montre l'agent |
| 7 | **Contexte qui survit** | Le résumé d'une session archivée est proposé au Brain et retrouvé par la suivante |
| 8 | Revue de diff avec commentaires | Les commentaires par ligne repartent à l'agent en une demande |
| 9 | Coûts par agent | Coût par session et par jour, lu depuis les outils, sans estimation inventée |
| 10 | Thèmes du Brain, finition, installeur | Terminal, Néon, Papier… ; installation sans droits admin |

## Loop 2 en détail : le prototype du terminal

1. **Deux candidats** (voir `docs/research/TERMINAL.md`) :
   - **godot-xterm** (MIT) : terminal pour Godot 4 déjà fait ; rapide à essayer ;
   - **le moteur VT de Ghostty** (libghostty-vt, MIT) branché par une extension native (GDExtension) ; le plus
     fidèle, plus de travail.
2. **Téléchargements** : chaque binaire ou dépôt tiers n'est récupéré qu'avec l'accord du propriétaire, à une
   version épinglée, vérifié par somme de contrôle, hors du dépôt (`vendor-cache/`).
3. **Banc d'essai** : une scène Godot avec 1 puis 4 terminaux attachés à tmux (serveur à part, `-L agmgd`),
   des scripts de test reproductibles (accents, couleurs, emojis, plein écran, collage, souris, redimensionnement)
   et une mesure d'images par seconde et de latence clavier.
4. **Captures** sur écran virtuel (Xvfb), et un test manuel par le propriétaire sur Windows à la fin
   (seulement s'il le demande : aucune fenêtre ouverte sans demande).
5. **Verdict** écrit dans `docs/research/TERMINAL.md` : le candidat retenu, ou l'arrêt.
