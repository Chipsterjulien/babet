# Réparation du cache de compilation bzip2 — 10 novembre 2026

Correctif préparé sur `v21 (Copie)(20261110-062928).zip`, en version 2.35.0.
Il conserve les améliorations présentes dans cette archive et ne modifie ni
le C++ ni le numéro de version. Les CHANGELOG ajoutent une entrée non publiée.

## Diagnostic

Le journal fourni échoue avant la compilation de Babet, pendant l'installation
de bzip2 1.0.8 : `make` considère `libbz2.a` à jour, puis `cp` ne trouve pas
`bzlib.h`. Le dossier des sources existe déjà et `build_local.sh` vérifie
uniquement son existence pour décider de ne pas extraire l'archive.

Un dossier contenant seulement un ancien `libbz2.a`, sans Makefile ni en-tête,
reproduit exactement cette séquence. L'échec de `make clean` était ignoré ;
le `make libbz2.a` suivant acceptait le fichier existant sans rien compiler.
Le journal ne permet pas de déterminer ce qui a rendu le cache incomplet.

La réponse HTTP 404 de la première URL zlib n'est pas bloquante : le journal
montre que le téléchargement de secours et le contrôle SHA256 réussissent.
Les sondes CMake signalées « Failed » ne sont pas, à elles seules, des erreurs
de compilation ; la construction de liblzma se termine bien.

## Correction

- Vérification des onze entrées nécessaires au Makefile bzip2 : Makefile,
  deux en-têtes, sept sources C et `words0`.
- Réextraction d'un cache incomplet dans un dossier temporaire unique, puis
  vérification avant remplacement de l'ancien arbre. Les anciens objets et
  archives sont éliminés avec cet arbre incomplet.
- Conservation de l'ancien arbre si l'extraction ou sa validation échoue.
- Maintien du SHA256 épinglé, vérifié avant toute réparation.
- Arrêt explicite du build si `make clean` échoue.
- Réutilisation inchangée d'une installation complète. Aucune purge globale
  des dépendances n'est nécessaire.

## Vérifications

| Vérification | Résultat |
| --- | --- |
| Nouveau test hors réseau `tools/test_bzip2_bootstrap.sh` | 12 PASS / 0 FAIL |
| Même test, helpers corrigés mais bloc bzip2 original | Échec attendu : `bzlib.h` absent, reproduisant le journal |
| Archive officielle bzip2 1.0.8 | SHA256 identique à la valeur épinglée |
| Bloc corrigé avec la véritable archive et un cache incomplet | Compilation et installation de libbz2 réussies |
| `make test` amont après cette réparation | Compression/décompression et comparaisons des trois échantillons réussies |
| Bootstrap ncurses / Zstandard | 11 / 5 PASS |
| Contrats release / orchestration des échecs de release | 13 / 9 PASS |
| Syntaxe des scripts Bash modifiés | OK |

Les essais de réparation comprennent des chemins avec espaces et apostrophe.
Le test hors réseau exerce le bloc réel de `build_local.sh` et sa fonction de
vérification SHA256, avec un petit Makefile de simulation ; la compilation de
la véritable bibliothèque est une vérification locale distincte.

Le nouveau test est intégré au préflight de `run_tests.sh`, donc également à
`--release`. La compilation complète de Babet n'a pas été relancée ici ; elle
reste à vérifier sur la machine du mainteneur avec les nouvelles améliorations.

## Application

Décompresser le ZIP des fichiers modifiés à la racine du projet, en remplaçant
les fichiers existants. Il ne contient ni dépendances compilées ni journaux.

```bash
bash tools/test_bzip2_bootstrap.sh && ./run_tests.sh --release
```

Le build réparera automatiquement les sources bzip2 si nécessaire. Transmettre
ensuite `babet-tests.txt`, qui contient le résultat de la campagne complète.
