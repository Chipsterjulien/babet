> **Archive historique.** Ce document décrit un lot de développement avant publication. Les consignes d’extraction, de patch et de validation ci-dessous ne doivent plus être suivies sur une version actuelle de Babet.

# GUI — lot 1 : Entry

Date : 2026-10-06. Base : sources 2.24.2 corrigées et auditées.

Ce lot ajoute la saisie de texte demandée dans le récapitulatif transmis.
À la livraison initiale, CMake restait à **2.24.2**, avec les nouveautés dans
« Non publié / Unreleased ». Voir l’actualisation ci-dessous pour la 2.25.0.

## API livrée

```lua
local gui = babet.gui
assert(gui.init())
local saisie = assert(gui.entry {
    text = "", placeholder = "Nom", editable = true,
})
assert(saisie:onChanged(function() print(saisie:getText()) end))
assert(saisie:onActivate(function() print("Validé :", saisie:getText()) end))
```

Méthodes : `getText`, `setText`, `setPlaceholder`, `setEditable`,
`onChanged` et `onActivate`. Les noms suivent le camelCase déjà utilisé par
`setText` et `onClick`. `getText` renvoie une seule chaîne ; les setters
renvoient `true, nil`. `onChanged(nil)` et `onActivate(nil)` retirent leur
callback respectif. Le texte attendu est de l'UTF-8 adapté à GTK sans NUL
embarqué. Aucune logique de validation métier n'est imposée.

GTK reste chargé à la demande, sans liaison directe ni headers de
développement GTK. Le constructeur et les méthodes exigent le thread OS
principal. Les workers sont refusés. Les callbacks sont protégés ; une erreur
ou un yield ne traverse pas GTK. `setText` peut appeler `onChanged` avant de
retourner, sur le thread Lua appelant. Les événements de `gui.run` s'exécutent
sur le thread Lua principal.

## Durée de vie et corrections associées

- Un setter garde le widget natif et son état valides pendant une notification
  synchrone, même si le callback ferme la fenêtre ou finalise explicitement le
  handle Lua. Les handles détruits restent inutilisables ensuite.
- Les callbacks appartiennent au handle Lua ; une table faible permet de les
  retrouver depuis GTK. Un callback qui capture son propre widget ne le
  conserve plus indéfiniment. Les enfants d'un parent vivant restent conservés.
  Ce correctif concerne aussi les boutons existants. Un contrôle indépendant
  échoue sur l'ancien runtime (`BUTTON_CALLBACK_CYCLE_LEAK`) et passe sur le
  nouveau (`BUTTON_CYCLE_OK`).
- L'échec d'allocation de l'état C++ libère le widget natif déjà créé. Les
  échecs de connexion des signaux Entry libèrent immédiatement leurs ressources.

## Vérifications réalisées ici

Compilation des unités GUI modifiées avec `-Wall -Wextra -Werror`, dans un
runtime de test ciblé fondé sur Lua 5.5.1. Les autres unités compilées ont été
réutilisées : une comparaison confirme que le delta `src/` avec ce runtime
concerne uniquement `gui.cpp`, `gui_gtk_loader.cpp` et son header.

| Vérification | Résultat |
| --- | --- |
| Entry : valeurs, types, arité, NUL, callbacks, coroutine/worker, fermetures, GC, modes fichier/dossier/embarqué, échecs de connexion | 7 groupes PASS / 0 FAIL |
| Même campagne avec ASan/UBSan, y compris le substitut GTK instrumenté | 7 groupes PASS / 0 FAIL |
| Runtime GUI préexistant, normal puis ASan/UBSan | 10 PASS / 0 FAIL dans chaque mode |
| État global du processus après GTK, normal puis ASan/UBSan | 150 PASS / 0 FAIL dans chaque mode |
| Chargeur GTK, dont symbole Entry absent | 15 PASS / 0 FAIL |
| Contrats structurels widgets / runtime / conception | 31 / 35 / 33 PASS, aucun échec |
| Exemple Entry exécuté avec le substitut GTK | PASS |
| Contrôle négatif Entry sur l'ancien runtime | Échec attendu : `gui.entry` absent |
| Syntaxe Bash des scripts modifiés et syntaxe Python du nouveau test | PASS |

Les tests GTK utilisent un substitut dynamique, sans écran. Ils ne valident
pas la saisie réelle, le focus ou le rendu d'une fenêtre GTK. La compilation
CMake complète et `./run_tests.sh --release` restent à lancer sur le poste du
mainteneur. LeakSanitizer ne peut pas inspecter `/proc/<pid>/task` dans cet
environnement : les campagnes ASan/UBSan locales utilisent `detect_leaks=0`.
Cela ne remplace pas la validation complète des fuites sur le poste cible.

## Application et retour attendu

Extraire le ZIP **à la racine du projet**, en conservant les chemins internes
et en remplaçant les fichiers correspondants, puis lancer :

```sh
./run_tests.sh --release
```

Le script intègre désormais `tools/test_gui_entry.py` et enregistre le retour
dans `babet-tests.txt`. Le ZIP ne contient que les fichiers ajoutés/modifiés,
aucun binaire ni cache Python.

Après un résultat vert, utiliser le binaire fraîchement compilé depuis la
racine du projet :

```sh
./test/babet examples/gui_entry
```

Sur une session graphique avec GTK 4, vérifier le texte en direct, la
validation par Entrée, la bascule lecture seule/édition, le bouton qui modifie
le texte depuis Lua même en lecture seule, puis la fermeture de la fenêtre.
Les manuels Markdown français et anglais et l'exemple sont inclus ; les PDF
de la release 2.24.2 ne sont pas régénérés pour ce lot de développement.

La suite prévue reste : SpinButton, Calendar, DrawingArea avec une petite
surface Cairo, puis marges/expansion. Les contraintes de la future application
SQLite de suivi du poids sont conservées dans `GUI_DESIGN.md` : plusieurs
mesures par jour, conservation des identifiants, dates antérieures et graphique
respectant les intervalles réels entre dates. Ces lots ne sont pas encore livrés.

## Actualisation après validation par le mainteneur

Le journal `babet-tests(20261006-114705).txt` valide le `--release` complet :
ASan/UBSan, build normal final et tests réseau sont OK. Entry passe 7/7 dans
les deux builds, les régressions GUI 10/10, l'état processus 150/150, les modes
9/9 et le réseau 11/11. Les scénarios optionnels UPX et sudo/PTY ont été ignorés
selon leurs prérequis. Le mainteneur indique également que l'exemple semble
fonctionner dans sa session graphique. Aucun nouvel échec n'est signalé.

La publication préparée est **2.25.0**, avec CMake, README, changelogs, index et
PDF alignés. Aucun code runtime supplémentaire n'est modifié depuis ce retour.
Le chapitre GUI, auparavant absent de l'ordre des chapitres PDF, est maintenant
inclus. Reconstruction et contrôle de la version finale précèdent le commit et
le tag ; voir `docs/releases/2.25.0.fr.md`.
