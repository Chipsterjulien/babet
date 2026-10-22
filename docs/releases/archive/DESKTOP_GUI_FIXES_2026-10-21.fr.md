# Correctifs du lot GTK4 desktop — 21 octobre 2026

Ce lot corrige les quatre défauts identifiés dans l'archive utilisateur
`v21 (Copie)(20261020-120142).zip`, dont le SHA-256 est :

`235a2cdc98fe3a29be77f96d1542ef01c24723b4838c36883c2eb7b081eba88a`

La version source reste 2.31.0 et les changements sont décrits dans
`[Unreleased]`. Aucun tag ni push n'a été effectué. Les PDF des manuels seront
à régénérer lors de la préparation de la prochaine release.

## Corrections

### Action finale du glisser-déposer

`GtkDropTarget::drop` retourne une acceptation booléenne. Le choix d'action
se fait pendant `enter`/`motion`. Dans `drop`, un retour `"copy"`, `"move"` ou
`"link"` différent de l'action reçue provoque désormais une erreur de callback
contenue et le refus du dépôt. Un retour `nil`, `true` ou la même action accepte ;
`false` refuse. Le modèle applicatif n'est jamais annulé automatiquement :
vérifier l'action avant de modifier ses données.

Les essais ont aussi reproduit sur GTK 4.14.2/X11 un signal de fin avec demande
de suppression malgré un refus du dépôt. Babet mémorise maintenant le résultat
du dépôt local, associé à l'objet GdkDrag, et interdit la suppression à la
source lorsque sa cible a refusé. Ce résultat est réinitialisé à chaque geste.
Cette protection concerne les transferts entre widgets Babet ; les transferts
vers une application externe conservent les indications fournies par GTK.
Le nom d'action peut rester celui négocié avant le refus et `cancel` n'est pas
garanti : utiliser le booléen de `onDragState("end", ...)` pour la suppression.

Tests : copie, déplacement, lien, sources COPY/LINK seules, changement d'action
au dépôt dans les deux sens, refus explicite, erreur Lua et refus suivi d'un
déplacement réussi. Le simulateur reproduit désormais le cas GTK/X11 où le
signal natif de fin conserve MOVE malgré le refus.

### Cycles de parenté

La recherche de cycles parcourt les enfants ordinaires, le Popover d'un
MenuButton et les popovers contextuels attachés directement. Elle reste
itérative, avec mémoire possédée par Lua et ensemble des éléments visités.
Les références d'aperçu de glisser et de fenêtre transitoire ne sont pas
considérées comme des liens parent/enfant.

`setPopover()` et `attachTo()` vérifient ces relations avant toute mutation.
Les tests couvrent les deux sens d'insertion, les chemins mixtes, Fixed,
Expander replié et la réutilisation des widgets après un refus.

### Destruction du parent d'un Popover

La destruction du parent détache explicitement ses popovers contextuels.
C'est nécessaire notamment pour GtkLabel et GtkButton, qui ne nettoient pas
automatiquement ces enfants arbitraires. Le Popover conserve sa référence
de construction et peut être attaché à un autre parent vivant.

Les tests attachent plusieurs popovers, ferment la fenêtre, les réutilisent
avec un autre parent puis ferment à nouveau. La boucle de nettoyage protège
les états logiques et reprend la liste après chaque détachement susceptible
de déclencher d'autres destructions.

### Allocation Lua dans setDragData

La recherche de l'icône personnalisée, susceptible d'allouer une chaîne Lua,
est effectuée avant la création du GtkDragSource. Le handle est revérifié après
les allocations et l'icône reste ancrée sur la pile pendant la construction.
Une erreur mémoire ne peut donc plus abandonner une source native sans propriétaire.

## Validation effectuée

Les sources GUI et leur chargeur réels sont compilés avec Lua 5.5.1 dans un
harnais isolé. Seuls les services étrangers à ces tests (curses et signaux)
sont remplacés par des stubs inactifs. Il ne s'agit pas d'une compilation du
runtime Babet complet ni d'un lancement intégral de `run_tests.sh --release`.

| Vérification | Normal | ASan + UBSan |
| --- | ---: | ---: |
| Tests GUI avec simulateur instrumenté en mode sanitizer | 68/68 | 68/68 |
| Tests GTK 4.14.2 réel, Xvfb et XTest | 28/28 | 28/28 |
| Groupes d'injection d'erreurs mémoire GUI | 5/5 | 5/5 |

Les contrats structurels GUI passent : **136/136**. La syntaxe Python et Bash
des outils modifiés est également vérifiée.

Le nouveau balayage `setDragData` comprend **1 cas avec erreur mémoire et
15 témoins**, avec nouvelle tentative et contrôle de libération des objets
natifs. Les quatre groupes mémoire préexistants passent aussi.

Les nouveaux tests échouent sur les sources exactes de l'archive d'origine :
cycle accepté, enfant contextuel restant après destruction, consigne de
suppression après une demande de copie au dépôt et objet natif non libéré
après erreur mémoire. Ils passent avec le correctif.

L'environnement interdit les sockets Unix ; le serveur Xvfb privé est utilisé
via TCP avec authentification. Cette adaptation ne modifie pas les assertions
des tests livrés. Les tests utilisateur gardent leur démarrage Xvfb habituel.

LeakSanitizer ne fonctionne pas dans cet environnement, confirmé par un petit
programme témoin : échec d'accès à `/proc/.../task`. Les essais ASan/UBSan sont
donc exécutés avec `detect_leaks=0`. La fuite corrigée est vérifiée séparément
par le compteur explicite des objets natifs du simulateur, pas par une absence
de diagnostic LeakSanitizer.

## Application et retour attendu

Extraire le ZIP des fichiers modifiés à la racine du projet, en conservant les
sous-dossiers et en remplaçant les fichiers correspondants. Aucun fichier
existant ne doit être supprimé. Le ZIP exclut les binaires et caches Python.

Depuis la racine du projet, dans Bash :

```bash
set -o pipefail
./run_tests.sh --release 2>&1 | tee babet-tests-desktop-correctifs.txt
```

Transmettre le fichier de sortie pour valider l'ensemble du runtime sur la
machine de développement avant de préparer la nouvelle release.
