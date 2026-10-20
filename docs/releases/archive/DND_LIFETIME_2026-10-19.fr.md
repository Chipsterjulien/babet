# Correctif du cycle de vie du glisser-déposer natif

Base : archive `v21 (Copie)(20261019-112413).zip` fournie par Julien.
La version source reste 2.30.0 ; ces changements figurent dans « Non publié ».

## Corrections

- `onDrop(nil)` désactive maintenant la cible GTK elle-même (action MOVE et
  préchargement), au lieu de supprimer seulement son callback Lua. Une cible
  enfant désactivée ne doit plus absorber un dépôt destiné à son parent.
- Une désactivation depuis un callback invalide sa réponse, même si la cible
  est réactivée immédiatement. Le contrôleur peut être réutilisé au geste suivant.
  Pendant le signal `drop`, Babet laisse GTK terminer son traitement avant de
  libérer son transfert ; hors de ce signal, le survol est rejeté immédiatement.
- Une nouvelle cible reste désactivée tant que l'enregistrement du callback Lua
  n'a pas réussi. Une erreur mémoire interceptée ne laisse donc pas de cible
  native active sans callback.
- Le faux GTK possède désormais une copie indépendante de la donnée transférée
  et maintient les références nécessaires pendant les callbacks. Cela corrige
  les accès après libération du simulateur quand le callback ferme une fenêtre
  ou efface/remplace la donnée source. Ces deux défauts mémoire étaient dans le
  simulateur, pas des crashs démontrés du runtime avec le vrai GTK.
- Le simulateur n'arrête plus automatiquement le geste au premier refus de
  survol. Les guides FR/EN et les manuels PDF précisent qu'il faut toujours
  vérifier l'identifiant et la position au dépôt final.

## Vérifications effectuées ici

Les tests exécutables utilisent Lua 5.5.1 et les fichiers de production
`gui.cpp`, `gui_gtk_loader.cpp`, `main_thread.cpp` et `process_state.cpp`.
Un petit hôte remplace uniquement les services de signaux/curses non concernés.
Ce n'est pas une compilation complète de Babet.

| Vérification | Résultat |
| --- | --- |
| Régressions widgets avec faux GTK, normal | 41 PASS / 0 FAIL |
| Mêmes régressions avec ASan + UBSan sur l'hôte et le faux GTK | 41 PASS / 0 FAIL |
| Injection d'erreurs mémoire, ASan + UBSan | 4 groupes PASS |
| Chargeur GTK dynamique | 17 PASS / 0 FAIL |
| Contrats structurels GUI | 99 PASS / 0 FAIL |
| Contrats d'étude taille/profils | 18 PASS / 0 FAIL |
| Syntaxe des scripts shell et Python modifiés | OK |
| Génération des manuels FR et EN | OK |

L'injection mémoire couvre `onDrag` (2 cas avec erreur, 30 témoins), TextView
(3 cas avec erreur, 2 témoins), `onDrop` (5 cas avec erreur, 27 témoins) et
l'installation du callback de dépôt (1 cas avec erreur, 7 témoins). Après
chaque scénario, les compteurs vérifient la libération des objets natifs et
des copies de texte. Les cycles Lua callback/handle sont aussi collectés.

Le nouveau scénario « cible enfant désactivée » échoue avec le `gui.cpp`
original de l'archive et réussit avec le correctif : il détecte bien le défaut.

## Limites et validation chez Julien

Les essais locaux ASan ont été lancés avec `detect_leaks=0` : ils ne constituent
pas une validation LeakSanitizer. Les compteurs de ressources testés sont propres.
Les réglages habituels de `run_tests.sh --release` restent conservés.

Xvfb n'est pas disponible dans cet environnement. Les sept scénarios de DND
sur le vrai GTK ont été ajoutés à la suite existante, mais restent à exécuter
chez Julien : dépôt normal, cible désactivée, réactivation, désactivation dans
`enter` ou `drop`, effacement de la source, fermeture dans `drop`.
La suite optionnelle signale explicitement les prérequis manquants.

L'archive de correctifs contient uniquement les fichiers modifiés ou ajoutés,
avec leurs chemins relatifs. Elle n'impose aucune suppression et n'inclut ni
binaire, ni cache Python, ni répertoire de compilation. Après extraction à la
racine du projet en remplaçant les fichiers existants, lancer :

```bash
./run_tests.sh --release
```

Transmettre le journal complet, y compris les éventuelles lignes `SKIP`, pour
valider la compilation complète et la couverture disponible sur cette machine.
