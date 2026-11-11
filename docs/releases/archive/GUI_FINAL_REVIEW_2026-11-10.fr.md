# Correctifs GUI avant publication de Babet 2.35.0

## Base et application

Ce lot part de l'archive complète du 10 novembre 2026, après application des
correctifs de compilation bzip2 et des caches de dépendances du même jour.
Il conserve la version 2.35.0 et les corrections déjà présentes dans cette base.

L'archive contient uniquement les neuf fichiers modifiés ou ajoutés par ce lot.
Extraire son contenu à la racine du projet en conservant les sous-dossiers,
puis lancer :

```bash
set -o pipefail
./run_tests.sh --release 2>&1 | tee babet-tests-gui-final.txt
```

## Corrections

### Propriétaire GUI après une erreur de boucle

Après disparition du dernier widget pendant `gui.run()`, une allocation Lua
pouvait échouer avant la fin de l'itération. Si aucun dialogue ni aucune tâche
ne restait à annuler, leur nettoyage ne libérait pas le propriétaire GUI.
Un autre état Lua vivant recevait alors « another Lua state currently owns
the GUI » malgré l'absence de widget.

Toutes les sorties de boucle exécutent maintenant le même contrôle final de
libération. Il conserve le propriétaire si un widget, une tâche, un dialogue
ou une boucle active en a encore besoin.

Le test natif provoque une véritable erreur d'allocation dans le code de
dispatch de la boucle, après fermeture de la fenêtre. Il couvre quatre cas :
avec ou sans widget conservé, et avec ou sans tâche en attente. Il vérifie le
transfert vers un second état Lua avant de fermer le premier, l'annulation de
la tâche et la libération de sa capture. Le cas avec widget conservé vérifie
que le transfert reste interdit jusqu'à sa destruction.

### Diagnostics des parents de sélecteurs

`gui.selectFolder` utilisait encore le nom `gui.openFile` pour un parent du
mauvais type ou déjà détruit. Les deux étapes de validation utilisent maintenant
le nom du sélecteur réellement appelé. Les tests couvrent `selectFolder`,
`openFile` et `saveFile`, avec un label puis une fenêtre détruite comme parent.

### Pile et frontières d'exception

- L'annulation des tâches réserve quatre emplacements Lua : la table, la clé
  d'itération, sa copie et la valeur `nil` utilisée pour supprimer l'entrée.
- Le contrôle des frontières d'exception couvre quatorze inscriptions nouvelles
  ou récemment ajoutées : timers, annulation, erreurs, sélecteur de dossier,
  redimensionnement, fermeture demandée, observation des processus, contexte
  d'exécution, ressources embarquées, mode strict et existence d'un chemin.
- Un contrôle supplémentaire vérifie que la frontière du contexte d'exécution
  délègue bien au traitement commun des exceptions C++.
- Les CHANGELOG FR/EN précisent que les erreurs de callbacks de signaux sont
  écrites sur stderr même dans les programmes sans GUI.

## Validation réalisée

| Vérification | Résultat |
| --- | --- |
| Allocations et callbacks GUI, normal | 13 lignes PASS, dont les quatre nouveaux cas de sortie en erreur |
| Allocations et callbacks GUI, ASan + UBSan | 13 lignes PASS |
| Boucle GUI, normal et ASan + UBSan | 4/4 dans chaque mode |
| Images et sélecteurs, normal et ASan + UBSan | 30/30 dans chaque mode |
| Contexte et ressources embarquées, normal et ASan + UBSan | 4/4 dans chaque mode |
| Contrats des frontières d'exception | 245/245 |
| Contrats GUI runtime et widgets | 35/35 et 160/160 |
| Rappels différés et quatre cas de sortie en erreur avec Lua 5.5.1 compilé avec `LUA_USE_APICHECK` | PASS |

Le test de transfert de propriétaire échoue avec le `gui.cpp` précédent sur le
message « another Lua state currently owns the GUI ». Le nouveau contrat des
parents échoue avec le code précédent sur « gui.openFile parent ». Les quinze
nouveaux contrôles des frontières ont aussi été vérifiés par mutations isolées :
retirer chaque protection provoque bien l'échec attendu.

Les injections mémoire produisent volontairement des diagnostics « not enough
memory » sur stderr. Leur présence est attendue dans ces tests ; leur résultat
est donné par les lignes PASS et le code de sortie.

## Limites

Ces vérifications locales utilisent les bindings de production et le faux GTK.
La compilation complète et les tests sur un vrai GTK restent à relancer avec
`./run_tests.sh --release` sur la machine de développement après application.

LeakSanitizer ne fonctionne pas dans l'environnement de préparation. Les essais
ASan + UBSan ont été lancés avec `ASAN_OPTIONS=detect_leaks=0`. Cette limitation
n'est pas inscrite dans les scripts livrés et ne désactive pas la détection des
fuites sur la machine de développement.
