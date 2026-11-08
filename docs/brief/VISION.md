# Agent Manager GD — Vision

**Date :** 2026-11-08 · **Statut :** Loop 1 (vision et plan), aucun code encore.

## En une phrase

Tes agents de code (Claude Code, Codex, et les autres) côte à côte dans **de vrais terminaux impeccables**, dans une
appli de bureau vivante et thémable, où chaque session persiste, se reprend, se ramifie, et **partage la mémoire
de ton Second Brain**.

## Le problème

Quand on fait travailler plusieurs agents en parallèle :
- on jongle entre des onglets de terminal pour savoir qui a fini, qui attend un OK, qui est bloqué ;
- une session fermée, c'est son contexte perdu ; reprendre demain veut dire tout réexpliquer ;
- chaque agent repart de zéro : ce que Claude a appris ce matin, Codex ne le sait pas cet après-midi ;
- on ne voit pas ce que chacun coûte.

Les outils actuels (agent-manager, agent-deck, Claude Squad) règlent la persistance et l'état avec tmux, mais
restent dans un terminal texte. Les applis de bureau (Conductor, Paradev) sont surtout sur Mac. Aucun ne donne une
**mémoire commune** aux agents (voir `docs/research/MARKET.md`).

## La référence : agent-manager (wainmann, Apache-2.0)

On reprend son concept et ses bonnes idées (licence Apache-2.0 : idées et code réutilisables avec attribution) :
- sessions tmux persistantes sur un serveur tmux à part (elles survivent à la fermeture de l'appli) ;
- arbre de projets (groupes repliables, réordonnables), état en direct par session ;
- **répondre sans entrer** (prompt rapide), ou lancer un agent dans le groupe choisi ;
- **ressusciter** une session morte sur sa conversation, **redémarrer** à vide, **fork** nommé ;
- une branche git à part (worktree) par session ;
- **revue de diff** avec commentaires par ligne renvoyés à l'agent ;
- un terminal shell sous un agent ;
- les agents se pilotent entre eux par MCP (lancer, écrire, attendre) ;
- modèle, effort, profil et profils d'environnement par session ; consignes sauvegardées.

## Ce que GD ajoute

1. **Une interface riche, vivante et thémable** (Godot) : les thèmes du Brain (Terminal, Néon, Papier…), des
   cartes d'état animées, la souris partout, sans perdre la vitesse du clavier.
2. **Le terminal impeccable** comme fondation : accents et touches mortes du clavier français, millions de
   couleurs, emojis, interfaces plein écran de Claude Code et Codex, copier-coller, souris, historique,
   redimensionnement, plusieurs terminaux fluides. C'est le critère « oui ou non » du projet.
3. **Le Second Brain branché d'office** : chaque session reçoit le MCP du Brain avec sa propre clé. Dans la
   frise du Brain, on voit quel agent a proposé quoi, et on défait par agent.
4. **Le contexte qui survit** : à l'archivage, le résumé d'une session (décisions, fichiers touchés, reste à
   faire) est proposé au Brain ; la session suivante, même avec un autre agent, le retrouve.
5. **Les coûts par agent** (ce qui manque à agent-manager), plus tard des budgets.
6. **Windows d'abord** : natif (psmux ou ConPTY) et WSL, là où la plupart des outils exigent Mac ou WSL.

## Principes

- **Local-first.** Rien ne quitte l'ordinateur sans que tu le demandes. Standards simples, open source possible.
- **Tes outils tels quels.** L'appli lance ton `claude`, ton `codex`, avec ta connexion et tes réglages, comme le
  ferait un terminal. Elle ne lit, ne copie et ne relaie jamais tes jetons de connexion d'abonnement. Les clés API
  éventuelles passent par dotenvx.
- **Aucun droit administrateur**, aucun téléchargement silencieux d'interpréteur, aucun script distant non vérifié.
- **Le terminal d'abord** : rien d'autre n'est construit tant que le terminal n'a pas passé sa grille.

## Hors périmètre (pour l'instant)

Nuage, équipes, mobile, galerie de modules. La publication du dépôt et sa licence sont des choix du propriétaire.

## Risques connus

- **Le terminal** : un émulateur impeccable est un gros morceau ; d'où le prototype « oui ou non » en Loop 2.
- **Les outils pilotés bougent vite** (Claude Code, Codex) : une petite couche d'adaptation par outil.
- **Les conditions d'utilisation** : jamais de jetons d'abonnement manipulés par l'appli (voir le principe plus haut).
- **La concurrence** : le créneau « lancer des agents » est encombré ; l'angle est le terminal riche + Windows +
  la mémoire du Brain.
- **La bande passante** : un projet de plus à côté du Brain, de TTS et de Typing Lab.
