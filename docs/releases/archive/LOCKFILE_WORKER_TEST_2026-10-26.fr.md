# Lot verrou — correction du test worker, 26 octobre 2026

Ce correctif s'applique après le lot verrou du 25 octobre et le correctif
des frontières C++/Lua du 26 octobre. Il contient le test Lua modifié et cette
note ; aucun changement de code C++ ni de version.

## Diagnostic du journal reçu

Dans `babet-tests(20261026-072217).txt`, les compilations ASan/UBSan et normale
réussissent. Les huit premiers groupes de tests du verrou passent dans les
deux modes. Le neuvième s'arrête avec :

```text
workers.spawn: args must be a table
```

Le test passait directement la chaîne du chemin en deuxième argument de
`babet.workers.spawn`. Le contrat de cette API exige une table ou nil.
L'erreur est dans le test livré, avant l'exécution du worker ; elle ne
démontre pas un défaut du mécanisme de verrou. Les tests suivants et les
smoke tests réseau n'ont pas été atteints.

## Correction

Le test transmet maintenant `{path = path}` et lit `worker.args.path` dans
le worker. Il garde ses vérifications : le worker constate le verrou du
parent, prend un verrou indépendant, puis sa fermeture libère ce dernier
sans libérer le verrou du parent.

## Validation locale

- Ancien test : reproduction exacte de `args must be a table`.
- Nouveau test : 9/9 groupes du pilote `tools/test_file_lock.py` passent en
  normal et sous ASan + UBSan, sans sauter le cas worker.
- Le harnais ciblé compile les sources réelles `workers.cpp`,
  `worker_process.cpp`, `process_state.cpp`, `lockFile.cpp` et les modules
  embarqués, avec Lua 5.5.1. Les workers sont donc de véritables threads avec
  sérialisation des arguments, attente `join` et fermeture de leur état Lua.
- L'enregistrement du runtime dans ce harnais est limité aux deux API testées.
  SQLite et le chargement de projets/ZIP ne sont pas exercés. Cela ne remplace
  pas une validation du binaire Babet complet.
- Comme pour le correctif précédent, la détection LeakSanitizer est désactivée
  uniquement dans les essais locaux (`detect_leaks=0`), en raison de la
  restriction d'accès à `/proc/.../task`. La configuration livrée est inchangée.

## Application

Extraire les fichiers à la racine du projet, en conservant les chemins et en
remplaçant le test existant. Le binaire normal déjà construit dans le journal
reçu permet de vérifier immédiatement le correctif, puis de relancer la suite :

```bash
python3 tools/test_file_lock.py ./test/babet &&
./run_tests.sh --release
```

Transmettre ensuite le nouveau `babet-tests.txt`.
