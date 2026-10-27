# Verrou de fichier : documentation publiée et écritures indépendantes

## Base et portée

Le ZIP complet fourni le 27 octobre contient les fichiers du lot verrou et
ses deux correctifs précédents, mais pas les huit fichiers corrigés décrits
dans la revue de Claude. Cette livraison applique les corrections à cette
base, après comparaison avec le tag public `v2.33.0`.

Les fichiers de la GUI sont identiques au tag publié. La version CMake reste
2.33.0 : le lot verrou est un ajout non publié prévu pour la 2.34.0, pas une
publication complète de cette nouvelle version.

## Corrections

- Restauration des deux changelogs depuis `v2.33.0`, puis ajout du seul lot
  verrou dans la rubrique non publiée. Tout l'historique à partir du titre
  `[2.33.0] - 2026-10-25` est conservé à l'identique, y compris la description
  finale du correctif des cibles de glisser-déposer imbriquées.
- Restauration des deux index de manuel publiés ; leur seule différence est
  la ligne vers le chapitre `lockFile`, explicitement prévu pour la 2.34.0.
- Les chapitres FR/EN précisent que `lockFile` n'existe pas dans la 2.33.0
  publiée. Ils décrivent aussi la portée de l'attente sur les appels système.
- Retrait du verrou interne de registre autour de `pwrite` et `ftruncate`.
  La poignée reste attachée à son état Lua ; aucun appel Lua pendant ces
  entrées-sorties ne peut réentrer dans sa fermeture ou sa finalisation.
  Le nettoyage après `fork` ne modifie que la copie de l'enfant. Le verrou
  `flock` lui-même reste tenu pendant toute l'écriture, y compris en erreur.
- L'acquisition et la fermeture conservent leur synchronisation avec `fork`.
  Des appels système lents à ces endroits peuvent encore retarder les autres
  acquisitions, fermetures et forks : leur durée n'est pas garantie courte.

## Nouveau test natif

Un sixième groupe bloque successivement `pwrite` et `ftruncate` dans un état
Lua. Avant de libérer cette écriture, le test exige :

1. l'acquisition, l'écriture et la fermeture d'un autre verrou dans un autre
   état Lua et un autre thread ;
2. un `fork`, le nettoyage de l'enfant et sa fin ;
3. le maintien du verrou réel du parent pendant cette attente.

La libération se fait par un signal explicite, pas après une durée simulée
d'écriture. Un délai maximal de cinq secondes borne les attentes d'échec.
Après libération et fermeture, les deux fichiers peuvent être verrouillés
et le nombre de descripteurs revient à sa valeur initiale.

Le même test compilé avec l'ancien `lockFile.cpp` échoue avec :
`slow lock:write blocked an independent lock acquisition`.

## Vérifications effectuées

- Tests natifs : 6/6 en normal, UBSan, et ASan + UBSan.
- Intégration Python : 9/9 en normal et ASan + UBSan, workers compris, avec
  un exécutable ciblé compilant les vrais fichiers `lockFile.cpp`,
  `workers.cpp`, `worker_process.cpp`, `process_state.cpp` et les modules Lua
  embarqués. Les fonctions hors périmètre du lanceur ne simulent pas les
  verrous ni les workers ; les chemins de chargement non utilisés s'arrêtent
  s'ils sont atteints. Il ne s'agit pas du binaire Babet complet.
- Contrats release : 13/13 ; runtime GUI : 35/35 ; widgets GUI : 159/159 ;
  frontières d'exception : 230/230.
- Comparaison exacte de l'historique des deux changelogs avec le tag publié.
  Comparaison exacte des deux index après retrait de la seule ligne ajoutée.

## Limites et validation à réaliser

LeakSanitizer échoue ici en essayant d'ouvrir `/proc/.../task`. Les essais
ASan locaux ont donc été réalisés avec `detect_leaks=0`, après constat de
cette erreur d'environnement. La détection des erreurs mémoire et UBSan
restent actives ; les scripts du projet n'ont pas été modifiés pour désactiver
la détection des fuites. Ces essais utilisent la bibliothèque Lua 5.5.1 déjà
compilée, et ne remplacent pas une compilation complète instrumentée.

La suite complète `--release` n'a pas été exécutée pour ce correctif.
Après extraction du ZIP à la racine du projet, en remplaçant les fichiers :

```bash
./run_tests.sh --release
```

Le journal attendu contient six lignes `[PASS] file lock native:` et
`File lock integration: 9 PASS / 0 FAIL` dans chacun des deux modes de la
validation release. La conclusion finale de cette validation reste nécessaire.

## Contenu de l'archive de correctif

Huit fichiers modifiés et cette note ajoutée, avec leurs chemins relatifs à
la racine du projet. Aucun cache Python, binaire, journal de test, fichier
temporaire, suppression ou changement de version n'est inclus.
