# Sources des dépendances incomplètes en cache — 10 novembre 2026

Ce lot complète le correctif bzip2 du même jour. Il part de l'archive du projet
transmise le 10 novembre, avec ce premier correctif appliqué. Le ZIP livré est
cumulatif : il contient aussi le correctif et le test bzip2. La version reste
2.35.0 ; aucun fichier C++ n'est modifié.

## Diagnostic du nouveau journal

Le journal `babet-tests(20261110-071425).txt` confirme que les douze tests bzip2
passent, que les sources incomplètes sont réparées et que bzip2 est installé.
Zstandard est ensuite compilé et installé.

L'arrêt suivant concerne Lua : après la vérification SHA256, la compilation
échoue sur `make clean` avec « aucune règle pour fabriquer la cible clean ».
La préparation Lua acceptait tout dossier existant. Les modifications de
`src/Makefile` pouvaient réussir alors que le Makefile à la racine manquait.
Ce cas reproduit exactement le nouvel échec. Le journal ne permet pas de
déterminer ce qui a rendu plusieurs caches incomplets.

L'expiration du délai de connexion à lua.org n'est pas la cause finale : le
téléchargement de secours réussit et son SHA256 correspond à celui épinglé.

## Changement de préparation

- Lua doit disposer de `liblua.a` et de ses quatre en-têtes publics :
  `lua.h`, `lauxlib.h`, `lualib.h` et `luaconf.h`.
- Si l'un manque, le script réextrait l'archive vérifiée dans un dossier
  temporaire, valide les fichiers d'entrée, remplace les anciennes sources
  puis compile. Les produits sont également vérifiés après compilation.
- Les reconstructions zlib, XZ, Abseil, RE2 et libarchive repartent elles aussi
  de sources réextraites. SQLite réextrait son amalgamation si un fichier manque.
  Ces étapes ne se contentent plus de constater l'existence du dossier source.
- Une installation complète reste en cache. Il n'y a pas de purge globale
  des dépendances ni de modification de leurs versions, SHA256 ou options.
- Une erreur d'extraction ou un fichier d'entrée manquant dans l'archive
  n'efface pas l'ancien arbre. Le dossier temporaire est nettoyé.

Les réparations existantes de bzip2, ncurses et Zstandard restent en place.
OpenSSL repartait déjà d'un arbre neuf lorsqu'une reconstruction était requise ;
miniz réextrayait déjà ses sources et les dépendances header-only recopiaient
leur en-tête manquant.

## Vérifications

| Vérification | Résultat |
| --- | --- |
| Nouveau test `tools/test_dependency_bootstrap.py` | 26 PASS / 0 FAIL |
| Même test sur le script précédant ce lot | Échec attendu sur Lua : aucune règle `clean` |
| Archive réelle Lua 5.5.1 | SHA256 identique à celui épinglé |
| Bloc Lua corrigé avec sources réelles et Makefile racine manquant | Compilation de `liblua.a` réussie |
| Petit programme C lié à cette bibliothèque | Chargement des bibliothèques, table, UTF-8 et GC : PASS |
| Régression bzip2 du lot précédent | 12 PASS / 0 FAIL |
| Bootstrap ncurses / Zstandard | 11 / 5 PASS |
| Contrats release / orchestration des échecs de release | 13 / 9 PASS |
| Contrat de production GC/OpenSSL | 48 PASS |

Les 26 tests sont hors réseau et n'écrivent pas dans le `build/` du projet.
Ils couvrent les archives gzip, xz et ZIP, les extractions échouées, la
conservation des anciens fichiers, ainsi que les blocs réels de préparation
Lua, zlib, XZ, Abseil, RE2, libarchive et SQLite. Ils utilisent un petit
Makefile de simulation pour Lua et un simulateur CMake pour les cinq dépendances
CMake. Ces cas ne sont pas des compilations de ces cinq bibliothèques.

La compilation de la vraie Lua constitue un essai local distinct, dans un
chemin contenant espaces et apostrophe. La compilation complète de Babet et
la campagne `--release` restent à relancer sur la machine du mainteneur.

## Application

Décompresser les fichiers à la racine du projet en remplaçant les fichiers
existants, puis lancer :

```bash
./run_tests.sh --release
```

Le nouveau préflight et les réparations de cache sont automatiques. Il n'est
pas nécessaire de supprimer `build/` ni `downloads/`. Le journal à transmettre
reste `babet-tests.txt`.
