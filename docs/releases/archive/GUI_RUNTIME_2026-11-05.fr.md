# Ajouts GUI et runtime — 5 novembre 2026

Lot préparé sur `v21 (Copie)(20261031-164811).zip`, dont la version source est
2.34.0. Les ajouts restent dans « Non publié », prévus pour la 2.35.0. Aucun tag
n'est créé. L'historique des CHANGELOG depuis 2.34.0 est conservé à l'identique.

## Ce qui est livré

| Besoin | API ou changement |
| --- | --- |
| Choisir un dossier | `gui.selectFolder(opts, callback)`, GTK 4.10 optionnel |
| Attendre après une frappe | `gui.timeout(ms, fn)`, `gui.idle(fn)`, `gui.cancel(id)` |
| Suivre une compilation | `proc:onExit(fn)` pour les poignées de `babet.spawn` |
| Voir les erreurs | Traceback des callbacks GUI/signaux sur stderr ; `gui.onError(fn_or_nil)` |
| Lire les ressources d'une application générée | `babet.embedded.read(name)` et `babet.embedded.list()` |
| Identifier le mode de lancement | `babet.runtimeInfo()` : mode, dossier du projet, script et exécutable |
| Tester un fichier ou un dossier | `babet.exists(path)` ; `fileExists` garde son sens actuel |
| Demander la fermeture avec possibilité de veto | `window:requestClose()` |
| Réagir aux dimensions de la fenêtre | `window:onResize(fn_or_nil)` |
| Détecter les lectures de globales absentes | `babet.strict(true/false)`, facultatif et propre à chaque état Lua |
| Identifier les exigences binaires | Rapport `.abi.txt` de `release.sh`, également inclus dans le tarball |

Les contrats détaillés et exemples figurent dans les chapitres GUI et runtime
des manuels FR/EN. Les index et l'ordre de génération des manuels sont mis à
jour ; les PDF seront à régénérer au moment de préparer la publication.

## Choix de compatibilité

- Les minuteries sont à exécution unique et servies depuis la boucle GUI, avec
  un réveil borné à 25 ms hors travail bloquant. Les callbacks peuvent modifier
  les widgets. `onDraw` peut programmer un `idle`, mais ne peut toujours pas
  modifier directement les widgets.
- Les identifiants de rappel ne sont pas recyclés. Les rappels en attente sont
  annulés à la sortie de `gui.run()` et à la fermeture Lua. Ils ne maintiennent
  pas seuls une application sans fenêtre ni sélecteur en cours.
- `onExit` observe le statut sans le consommer et sans `waitpid(-1)`. Annuler
  l'observation ne tue pas une poignée conservée par l'application. Les tubes
  de sortie ne sont pas vidés automatiquement et peuvent bloquer le processus
  enfant ; le contrat de finalisation habituel de la poignée reste applicable.
  Les poignées de `spawnPipeline` ne sont pas prises en charge par cet ajout.
- Le sélecteur de dossier utilise les mêmes protections que les sélecteurs de
  fichiers : annulation à la destruction du parent, à la sortie de boucle et
  à la fermeture de Lua, sans callback tardif. Sans GTK 4.10, il retourne une
  erreur sans empêcher l'usage des widgets disponibles.
- `close()` garde sa destruction directe. Utiliser `requestClose()` lorsque
  l'application veut passer par `onCloseRequest`.
- L'arité stricte est conservée : `f((babet.getPath(x)))` transmet uniquement
  le premier résultat ; une variable intermédiaire permet de traiter l'erreur.
  Les arguments `nil` supplémentaires ne sont pas ignorés globalement.
- `runtimeInfo` renvoie une copie et les workers héritent du contexte de
  lancement. Les ressources restent accessibles par `/proc/self/exe`, y compris
  après remplacement du chemin du binaire ; aucun repli implicite sur les
  fichiers du projet. La lecture est binaire, sensible à la casse, limitée à
  16 Mio par ressource ; la liste est triée et exclut les répertoires.

## Vérifications effectuées

Les tests fonctionnels locaux utilisent un exécutable ciblé compilant les
véritables liaisons GUI, processus, signaux et ressources, avec Lua 5.5.1 et
miniz. Le terminal est remplacé par des stubs dans ce harnais. Il ne remplace
pas la compilation et les tests du runtime complet.

| Vérification | Résultat local |
| --- | --- |
| Boucle GUI : minuteries, annulation, processus, erreurs, dessin, redimensionnement, fermeture | 4/4, normal et ASan + UBSan |
| Images et sélecteurs, dont six cas de sélection de dossier | 30/30, normal et ASan + UBSan |
| Contexte, `exists`, globales strictes et ressources : fichier, dossier, exécutable sans sources | 3/3, normal et ASan + UBSan, hors workers dans ce harnais |
| Widgets existants | 74/74, normal et ASan + UBSan |
| Texte enrichi et dépôts de fichiers | 24/24, normal |
| Allocations des callbacks et durée de vie | 12 groupes PASS, normal et ASan + UBSan |
| Nouveau balayage d'allocations différées | 26 erreurs injectées / 166 témoins, minuteries, idle et dossier |
| Reprise de la GUI par un autre état Lua après annulation du dernier rappel | PASS dans les deux modes |
| Contrats structurels GUI widgets / runtime / release | 159 / 35 / 13 PASS |
| Chargeur embarqué et erreurs d'allocation d'archive | PASS ; 9 essais d'archive, aucun descripteur perdu |
| Rapport ABI | PASS : imports uniquement, faux texte et symboles exportés ignorés, faux ELF refusé |
| Compilation syntaxique de `main.cpp`, workers et enregistrement, avertissements traités en erreurs | PASS |
| Syntaxe Bash/Python des scripts modifiés, espaces en fin de ligne et conservation de l'historique publié | PASS |

La vérification ASan du faux GTK a conduit à corriger sa gestion des références
de fenêtre : un `close()` depuis `onCloseRequest` doit laisser vivre la référence
temporaire du signal jusqu'à son retour. Le test exerce aussi cette fermeture
réentrante. Aucun contournement correspondant n'est introduit dans le runtime.

## Limites et validation restante

- LeakSanitizer ne peut pas inspecter `/proc` dans cet environnement. Les essais
  locaux ASan + UBSan passent avec `ASAN_OPTIONS=detect_leaks=0`. Ce réglage
  local n'est pas ajouté à `run_tests.sh` : la détection de fuites reste active
  dans la validation release habituelle. Les harnais vérifient aussi les
  compteurs de widgets, copies GLib, erreurs natives et sessions résiduelles.
- Xvfb n'est pas disponible ici : les nouveaux essais sur GTK réel sont ajoutés
  mais non exécutés localement. `test_gui_real_files.py` signale explicitement
  ce SKIP. Il couvre désormais le dossier et un scénario autonome de boucle,
  redimensionnement, fermeture et fin de processus.
- La compilation complète et l'héritage du contexte dans de vrais workers
  restent à confirmer par `./run_tests.sh --release`. Le test de contexte
  exerce automatiquement les workers lorsque le runtime complet est fourni.
- Le rapport ABI décrit les versions importées du binaire inspecté. Il ne
  produit pas de binaire compatible avec une glibc plus ancienne et ne couvre
  pas les dépendances transitives ni GTK chargé dynamiquement. Pour Debian 12
  ou Ubuntu 24.04, reconstruire toutes les dépendances sur la base cible la
  plus ancienne et y tester le résultat. Le diagnostic précis concernant
  `cfgetospeed` n'est pas confirmé sans le binaire concerné.

## Application et retour demandé

L'archive contient uniquement les fichiers ajoutés ou modifiés, avec leurs
chemins relatifs à la racine du projet. Aucun fichier à supprimer, cache Python,
journal de test ni binaire de compilation n'est livré. Extraire à la racine de
la copie de travail correspondant au ZIP de départ, puis lancer dans Bash :

```bash
set -o pipefail
./run_tests.sh --release 2>&1 | tee babet-tests-gui-runtime.txt
```

Transmettre le journal complet, y compris les éventuels SKIP. Attendre cette
validation avant de préparer la version, les PDF, le commit et le tag 2.35.0.
