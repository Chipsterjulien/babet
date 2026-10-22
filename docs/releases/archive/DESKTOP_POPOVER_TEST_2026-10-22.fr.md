# Test desktop : séparer popover et vérification clavier

Ce correctif s'applique après le correctif de préflight des journaux du
21 octobre 2026. Il ne modifie aucun fichier de `src/`.

## Constat et correction

La revue indépendante a reproduit des expirations du scénario desktop sous
ASan : le clic est reçu, mais le premier Échap n'atteint pas la fenêtre.
Déplacer `popup()` puis `popdown()` de l'appui vers le relâchement ne supprime
pas le déclencheur, puisque les deux appels restent dans le même callback.
L'hypothèse précédente d'un grab actif n'est donc pas retenue comme diagnostic.

Le scénario desktop conserve les vérifications du pointeur, du clavier, du
paned, de la géométrie et de l'attachement du menu contextuel. Il n'ouvre plus
le popover dans le callback du pointeur. Le pilote attend toujours
`REAL_GTK_DESKTOP_POINTER_OK`, puis injecte **un seul Échap**. Aucun renvoi de
touche ni allongement du délai ne masque une perte d'événement.

Une nuance par rapport à la revue : `popover_ownership.lua` vérifie les cycles
et la durée de vie, mais ne présente pas les popovers. Pour conserver une
couverture réelle de leur ouverture et de leur fermeture, un scénario distinct
`real_gtk_popover.lua` est ajouté :

1. attendre le premier dessin de la fenêtre ;
2. injecter un clic sur le bouton qui appelle `popup()` ;
3. attendre le premier dessin du contenu du popover ;
4. injecter Espace pour activer son bouton de fermeture, qui appelle `popdown()` ;
5. vérifier les étapes observées et terminer proprement.

Les deux appels s'exécutent donc lors d'événements séparés, avec
`autohide=true` conservé. Le nouveau scénario est intégré à la suite GTK réelle
appelée par `--release`. Les guides FR et EN déconseillent l'ouverture suivie
de la fermeture immédiate dans un même callback.

## Validation et limites

| Vérification | Résultat |
| --- | --- |
| Contrats structurels GUI | **138 PASS / 0 FAIL** |
| Suite entière sur GTK réel, mode normal | **35 PASS / 0 FAIL** |
| Suite entière sur GTK réel, ASan + UBSan | **6 passages consécutifs, 35 PASS / 0 FAIL chacun** |
| Syntaxes Lua, Python et Bash | OK |

Les répétitions vérifient la suite entière, avec tous les scénarios qui
précèdent le test desktop. Le nouveau scénario de popover passe également
à chaque exécution.

Les essais locaux utilisent GTK 4.14.5, Xvfb/XTest et les véritables bindings
GUI de Babet, compilés dans un petit exécutable avec Lua 5.5.1. Seuls les
services de terminal et de signaux, étrangers aux scénarios, sont remplacés
dans ce harnais. Le parcours complet de Babet n'a pas été recompilé ici.
ASan et UBSan instrumentent le code GUI C++ ; LeakSanitizer reste désactivé
pour cette intégration avec GTK système, comme dans le pilote livré.

L'environnement local impose X11 sur la boucle locale TCP plutôt que sur un
socket Unix. Cette adaptation ne touche ni les scénarios Lua ni les injections
et assertions du pilote livré. Elle peut toutefois changer les timings : les
trois essais de l'ancien scénario réalisés avant l'interruption ont également
réussi ici. Le défaut intermittent signalé par la revue n'a donc pas été
reproduit localement. Le correctif retire son déclencheur identifié ; les
répétitions sur la machine destinataire restent nécessaires.

## Application

Extraire les fichiers à la racine du projet, après les précédents correctifs.
La version et les PDF seront actualisés lors de la préparation de la 2.32.0.
Depuis la racine, dans Bash :

```bash
set -o pipefail
(
  set -e
  ./run_tests.sh --release
  for passage in 1 2 3; do
    printf '\n=== GTK réel ASan : répétition %s/3 ===\n' "$passage"
    ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
      python3 tools/test_gui_real_gtk.py ./build/project_build_sanitizers/babet
  done
) 2>&1 | tee babet-tests-popover-validation.txt
```

Les trois répétitions réutilisent le binaire ASan déjà compilé par `--release`.
Elles exécutent la suite GTK entière, car le scénario isolé ne reproduisait pas
le défaut signalé. La désactivation de LeakSanitizer concerne cette intégration
avec les bibliothèques graphiques système, comme dans le pilote existant ; les
tests hermétiques du parcours `--release` conservent leur propre configuration.

Transmettre `babet-tests-popover-validation.txt`, même en cas d'échec.
Ce journal est couvert par `babet-tests*.txt` et n'est pas inclus dans le ZIP.
