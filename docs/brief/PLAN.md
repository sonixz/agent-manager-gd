# Agent Manager GD — Plan des loops

Chaque loop se termine par une revue du propriétaire (captures, rapport en français) avant la suivante.

| Loop | But | Fini quand |
|---|---|---|
| **1** ✅ | Vision, plan, recherches (marché, terminal) | Ce dossier `docs/` existe et le propriétaire l'a lu |
| **2** ✅ | **Prototype du terminal, « oui ou non »** | Un candidat passe toute la grille de `docs/research/TERMINAL.md`, mesurée, avec captures ; sinon on s'arrête ou on change d'approche |
| 3 ✅ | Moteur Python + sessions tmux persistantes | Lancer, fermer l'appli, rouvrir : les sessions sont là, avec leur terminal |
| 4 ✅ | Vivre avec plusieurs sessions | voir le détail plus bas |
| 5 ✅ | Reprendre et ramifier | voir le détail plus bas |
| 6 ✅ | Le Brain branché d'office | voir le détail plus bas |
| 7 ✅ | Le contexte qui survit | voir le détail plus bas |
| 8 | Revue de diff avec commentaires | voir « Loops 8 à 15 » plus bas |
| 9 | Dépôts connectés et clés de déploiement | idem |
| 10 | La voix : dictée vers les terminaux | idem |
| 11 | La voix : commandes et état parlé | idem |
| 12 | Sandbox Fly.io, « oui ou non » | idem |
| 13 | Sandboxes complètes : gestionnaire de sandboxes, tunnels, connexions, supervision avec le Brain | idem |
| 14 | Coûts : Fly.io et agents, budgets | idem |
| 15 | Finition et installeur | idem |

## Loops 4 à 10 en détail (structuré le 2026-11-08)

Règles pour toutes : chaque sous-loop finit par des tests verts, des captures (écran virtuel) et un rapport ; un essai
réel sur le PC du propriétaire aux points de contrôle (★), seulement quand il le demande. Rien ne modifie les réglages
personnels de Claude Code ou de Codex : tout passe par des options de lancement propres à chaque session.

### Loop 4 · Vivre avec plusieurs sessions
- **4A Arbre de projets** : groupes repliables et réordonnables (glisser), une session déplaçable d'un groupe à
  l'autre, renommer. Fini quand : 10 sessions dans 3 groupes restent lisibles et l'ordre survit à la réouverture.
- **4B États en direct** : « travaille », « attend ton OK », « attend une réponse », « fini », « erreur ».
  Source fiable d'abord : les crochets (hooks) de Claude Code passés par `--settings` au lancement et le `notify` de
  Codex passé par `-c`, qui appellent l'API du moteur ; en secours, l'activité du terminal. Fini quand : les cinq
  états sont justes sur un scénario scripté pour Claude Code, Codex et un shell.
- **4C Prompt rapide et file d'attente** : répondre à une session sans y entrer ; une file « ils t'attendent »
  qui regroupe les sessions en attente de ton OK ; notification de bureau quand une session attend. Fini quand :
  on approuve ou répond à trois agents sans ouvrir leur terminal.
- ★ Point de contrôle : premier essai réel sur Windows (vitesse, touches mortes, usage d'une journée).

### Loop 5 · Reprendre et ramifier
- **5A Ressusciter** une session morte sur sa propre conversation (identifiant de conversation capté par le crochet
  de démarrage ; `claude --resume`, `codex resume`) ; **Redémarrer à vide** reste disponible.
- **5B Fork** : continuer une conversation dans une nouvelle session nommée (`--fork-session` pour Claude Code ;
  équivalent Codex selon sa version).
- **5C Branches git à part** : une session peut naître dans son propre worktree (`<dépôt>-worktrees/<nom>`, branche
  `am/<nom>`) ; « Terminer » propose de fusionner puis de nettoyer, toujours avec confirmation.
- Fini quand : après un redémarrage du PC, chaque session revient sur sa conversation ; deux agents travaillent dans
  deux branches du même dépôt sans se marcher dessus.

### Loop 6 · Le Brain branché d'office
- **6A Clé par session** : le moteur demande au Brain une clé MCP pour chaque session (le client porte le nom de la
  session) et la passe au lancement (`--mcp-config` pour Claude Code, `-c mcp_servers…` pour Codex). Clé révoquée
  quand la session est retirée. Aucune clé dans les journaux ni dans le dépôt.
- **6B La frise par agent** : dans le Brain, on voit quelle session a proposé quoi, et « revenir en arrière » par
  agent fonctionne (ce qui existe déjà côté Brain, vérifié de bout en bout).
- **6C Les agents se pilotent entre eux** (comme agent-manager) : le moteur expose un petit serveur MCP
  (lancer une session, lui écrire, attendre qu'elle ait fini), proposé à chaque session.
- ★ Point de contrôle : une vraie journée de travail avec le Brain branché.

### Loop 7 · Le contexte qui survit
- **7A Résumé de fin de session** : à l'archivage, l'agent rédige un court résumé (décisions, fichiers touchés,
  reste à faire), proposé au Brain via l'agent archiviste ; le propriétaire approuve comme d'habitude.
- **7B Démarrer avec le contexte** : une nouvelle session sur le même projet reçoit en consigne de départ de
  consulter le Brain pour ce projet, même avec un autre outil.
- Fini quand : une session Codex reprend le travail d'une session Claude Code de la veille sans réexplication.

### Loop 8 · Revue de diff avec commentaires
- Le diff d'une session (son worktree ou son dossier), fichier par fichier, coloré ; un commentaire par ligne ;
  « Envoyer la revue » les regroupe en une seule demande à l'agent ; les commentaires envoyés restent visibles
  (ouverts ou traités).

### Loop 9 · Coûts par agent
- Coût par session, par jour et par mois, lu dans ce que les outils écrivent eux-mêmes (journaux de session de
  Claude Code et de Codex), sans estimation inventée ; mention claire quand une donnée manque. Budgets ensuite.

### Loop 10 · Thèmes, finition, installeur
- Les thèmes du Brain (Matin, Focus, Soir, Forêt, Terminal, Papier, Néon) pour l'appli et la palette du terminal ;
  réglages (police, taille) ; raccourcis clavier configurables.
- Builds de version (release) Linux et Windows ; installation sans droits administrateur ; vérification au premier
  lancement (WSL, python3, tmux) avec des messages clairs et sans rien télécharger en silence.

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

## Loops 8 à 15 en détail (structuré le 2026-11-08, après la Loop 7)

Décisions du propriétaire : l'utilisateur crée ses dépôts, Agent Manager les connecte (une clé de déploiement par
dépôt) ; une sandbox est une instance Fly.io jetable, pas un hôte persistant ; le Brain rejoint les sandboxes par un
tunnel SSH, avec la gestion des tunnels, l'état des connexions et la supervision ; Agent Manager gère les coûts.
Détails : `docs/brief/SANDBOX.md`. Mêmes règles qu'avant (tests, captures, rapport ; essai réel du propriétaire aux ★).

### Loop 8 · Revue de diff avec commentaires
- 8A : le diff d'une session (son worktree, son dossier ou sa branche), fichier par fichier, coloré, côte à côte ou
  unifié ; navigation au clavier.
- 8B : un commentaire par ligne ; « Envoyer la revue » les regroupe en une seule demande à l'agent ; les commentaires
  envoyés restent visibles (ouverts ou traités).
- Fini quand : on relit le travail d'un agent et on lui renvoie trois remarques sans quitter Agent Manager.

### Loop 9 · Dépôts connectés et clés de déploiement (local)
- 9A : vue « Dépôts » : ajouter (adresse SSH, dossier local), clé ed25519 par dépôt (privée 0600 dans nos données,
  jamais dans un journal), clé publique à copier avec le lien GitHub *Deploy keys*, « Vérifier » (`git ls-remote`).
- 9B : lancer un agent sur un dépôt (worktree par session) ; les commandes git de la session utilisent sa clé seule
  (`GIT_SSH_COMMAND`) ; « Changer la clé », « Déconnecter », la documentation de chaque dépôt (empreinte, dates,
  sessions qui y ont travaillé).
- Fini quand : un dépôt créé par le propriétaire est connecté et un agent y pousse sa branche avec la clé du dépôt.

### Loop 10 · La voix : dictée vers les terminaux
- Reprise de la capture micro du Brain (Godot) et de sa transcription (clé OpenAI via dotenvx, coût affiché).
- Maintenir une touche, parler : le texte s'écrit dans l'invite de la session active ; on le relit et on valide
  (jamais d'Entrée automatique) ; accents et ponctuation française.
- Fini quand : on dicte une consigne à Claude Code en français et elle arrive exacte dans son invite.
- ★ Essai réel du propriétaire (micro, latence).

### Loop 11 · La voix : commandes et état parlé
- Commandes : « approuve Themes », « refuse », « va sur Docs », « vue grille », « qui m'attend ? », « clos la session ».
  Toujours une confirmation visible avant une action qui coûte ou qui efface.
- L'état parlé (voix courte, désactivable) : « Themes attend ton OK », « Docs a fini ».
- Option locale plus tard (whisper.cpp, après accord pour le téléchargement).

### Loop 12 · Sandbox Fly.io, « oui ou non »
- Notre image (tmux, git, Claude Code, Codex, Python, mini moteur, sshd), le registre choisi par le propriétaire.
- Une machine pour une session : secrets (clé du dépôt, clés API des agents), clonage, branche `am/<session>`,
  l'agent dans tmux, le terminal dans Agent Manager (badge ☁) ; fin : résumé, branche poussée, sandbox marquée
  « terminée, prête à détruire ». **Agent Manager ne détruit jamais une sandbox de lui-même.**
- Mesures : temps de démarrage, latence du terminal, coût par exécution. Verdict écrit.
- Besoins : compte et clé Fly (dotenvx), accord pour installer `flyctl`, clés API des agents, petit budget plafonné.

### Loop 13 · Sandboxes complètes : gestionnaire, tunnels, connexions, supervision avec le Brain
- 13 0 Gestionnaire de sandboxes : toutes les sandboxes (en cours, arrêtées, terminées) avec dépôt, session, branche,
  taille, âge, état de la machine et du tunnel, Brain joignable, coût, dernière activité, dernier résumé, branche
  poussée ou non ; Ouvrir, Démarrer, Arrêter (pause), Détruire (toujours confirmé, après vérification du travail non
  commité ou non poussé, montré) ; « Détruire les terminées » (liste à cocher, confirmée) ; les orphelines du compte
  Fly listées sans y toucher. Rien n'est jamais détruit automatiquement.
- 13A Tunnels : un tunnel SSH inversé par sandbox (`ssh.exe` de Windows via `fly proxy`) vers le `/mcp` du Brain ;
  clé du Brain par sandbox, révoquée quand le propriétaire la détruit ; reconnexion automatique.
- 13B Vue « Connexions » : pour chaque sandbox, l'état de la machine (démarre, travaille, arrêtée, détruite), l'état
  du tunnel (ouvert, en reconnexion, coupé) et sa latence, le Brain joignable ou non depuis la sandbox (test de santé
  à travers le tunnel), la dernière activité ; alertes quand un tunnel tombe ou qu'une sandbox ne répond plus.
- 13C Supervision : les sandboxes dans l'arbre, le Tableau de bord et la file « ils t'attendent » comme les sessions
  locales ; leurs propositions arrivent dans le Brain signées « Agent Manager · <session> ☁ » ; le résumé rapatrié
  et proposé au Brain même si le tunnel était coupé.
- Fini quand : deux sandboxes travaillent en parallèle sur deux dépôts, chacune proposant au Brain, et la coupure d'un
  tunnel se voit, se répare et ne perd rien.

### Loop 14 · Coûts : Fly.io et agents, budgets
- Fly.io : compteur en direct par sandbox, totaux jour et mois (estimation sur la grille publiée, datée), budget
  mensuel (alerte à 80 %, refus de nouvelles sandboxes à 100 %), et, si le propriétaire l'active, l'**arrêt** (pause,
  jamais la destruction) d'une sandbox inactive ou hors budget ; « Tout arrêter » met tout en pause ; historique.
- Agents : coût par session et par jour lu dans les journaux de Claude Code et de Codex (lecture seule), sans
  estimation inventée ; mention claire quand une donnée manque.

### Loop 15 · Finition et installeur
- Builds de version Linux et Windows ; installation sans droits administrateur ; vérification au premier lancement
  (WSL, python3, tmux, flyctl si sandboxes) avec des messages clairs et rien de téléchargé en silence ; raccourcis
  configurables ; le MCP d'Agent Manager proposé aussi aux outils extérieurs (bouton « Brancher »).

