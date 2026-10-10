> **Archive historique.** Ce document décrit un lot de développement avant publication. Les consignes d’extraction, de patch et de validation ci-dessous ne doivent plus être suivies sur une version actuelle de Babet.

# Lot GUI 2 - DrawingArea et dessin Cairo

7 octobre 2026. Base : sources 2.25.0, avec le lot Entry déjà appliqué.
Ce lot n'est pas une publication : les changements sont dans « Non publié ».
La version source reste 2.25.0 ; aucun tag, push ou fichier de release n'est créé.

## Ce qui est livré

- `babet.gui.drawingArea({width=?, height=?})`, `onDraw(fn_ou_nil)`, `queueDraw()`.
- Contexte de dessin : chemins, segments, rectangles, arcs, contour, remplissage,
  couleurs RGB/RGBA, épaisseur, taille de police et texte UTF-8 simple.
- Le contexte est invalidé après le callback, même lors d'une erreur ou d'un
  manque de mémoire. Aucun pointeur Cairo n'est exposé à Lua.
- Les mutations de widgets pendant le dessin sont refusées. Les destructions
  dues au ramasse-miettes sont différées jusqu'au retour de GTK.
- Tests intégrés dans `run_tests.sh`, exemple `examples/gui_drawing`, guides
  français et anglais, PDF régénérés et feuille de route actualisée.

Les fonctions publiques gardent le camelCase de Babet : `drawingArea`, sans
alias `drawing_area`. GTK/Cairo restent chargés à la demande depuis le système,
sans en-têtes de développement ni liaison directe dans le runtime Babet.

## Vérifications effectuées ici

| Vérification | Résultat |
| --- | --- |
| Compilation ciblée C++23, avertissements en erreurs | OK, normal et ASan/UBSan |
| DrawingArea : arguments, callbacks, durée de vie et GC | 9/9, normal et ASan/UBSan |
| Exécution fichier, dossier, application générée sans sources | OK dans ces tests |
| Vrai Cairo sur surface image, avec faux GTK | Pixels du fond, rectangle, segment, cercle et texte vérifiés |
| Injection d'erreurs d'allocation Lua | 32 scénarios, dont 7 avec échec mémoire et 25 sans, normal et ASan/UBSan |
| Réutilisation des contextes périmés | Refus après retour, erreur et tentative de suspension |
| Cycles widget/callback | 150 créations/collectes, sans épuisement des slots natifs du harnais |
| Régressions Entry | 7/7, normal et ASan/UBSan |
| Régressions GUI existantes | 10/10, normal et ASan/UBSan |
| Chargeur GTK | 15/15 |
| Protection de l'état processus après chargement GTK | 150/150, normal |
| Contrats structurels GUI | 33 + 35 + 31 vérifications réussies |
| Contrats du builder de release | 13/13 |
| Exemple de courbe avec changement de données puis fermeture | OK sous faux GTK |
| Manuels PDF | Français 265 pages, anglais 244 pages ; pages DrawingArea vérifiées visuellement |

Les tests d'allocation affichent volontairement sept erreurs « not enough
memory » avant leur ligne PASS. Le programme de test appelle le callback natif
sans protection Lua extérieure : un longjmp qui sortirait du binding ferait
échouer le processus. Les 32 états Lua sont ensuite fermés sans widget restant.

Limites de la validation locale : le runner ciblé réutilise les objets inchangés
du runtime audité et recompile les deux unités GUI. Il ne remplace pas une
compilation CMake complète. GTK et un affichage graphique ne sont pas disponibles
ici ; le harnais utilise un faux GTK, avec test complémentaire du vrai Cairo.
ASan/UBSan ont été exécutés avec `detect_leaks=0` car l'environnement local ne
permet pas le contrôle LSan par `/proc`. Aucun succès d'une campagne complète
`--release` ni d'un essai réel sur ton bureau n'est annoncé pour ce nouveau lot.

## À faire après extraction du ZIP à la racine du projet

```sh
./run_tests.sh --release
```

Envoyer le fichier `babet-tests.txt`. Si tout passe, lancer sur le bureau :

```sh
./test/babet examples/gui_drawing
```

Vérifier : présence de la courbe et de ses légendes, changement des données
avec le bouton, redimensionnement sans anomalie et fermeture normale. L'exemple
contient des données de démonstration ; il ne constitue pas encore le logiciel
SQLite de suivi du poids.

## Suite, après validation de ce lot

1. Retrait/vidage des enfants de Box et ScrolledWindow pour rafraîchir l'historique.
2. SpinButton pour saisir le poids.
3. Calendar pour choisir une date, y compris passée.
4. Propriétés communes de mise en page : expansion, marges, visibilité, sensibilité.

Les identifiants SQLite stables, plusieurs pesées par jour, les modifications
et suppressions restent des responsabilités de l'application. La courbe doit
respecter les intervalles réels entre dates et adapter son axe vertical.

La prochaine publication sera préparée après validation, avec CMake, README,
documentation et tag alignés ensemble.

## Correctif 2b - retour du 7 octobre 2026

Le journal `babet-tests(20261007-052321).txt` montre un échec de la campagne
ASan/UBSan au test avec le vrai Cairo : les assertions Lua terminent avec
`DRAWING_CONTRACT_OK`, puis LeakSanitizer signale 9 192 octets dans 133 allocations,
avec des piles Fontconfig liées au rendu du texte. Les huit groupes DrawingArea
précédents passent. Le build normal final et les 11 tests réseau passent aussi.
La validation complète reste donc en échec ; les tests ASan situés après ce
point n'ont pas été exécutés pendant cette campagne.

Le harnais libérait son contexte et sa surface Cairo, mais conservait les
caches de polices. Dans la variante de test « faux GTK + vrai Cairo », il appelle
maintenant `cairo_debug_reset_static_data()` après destruction de ces objets,
puis `FcFini()`. Il initialise Fontconfig au début du dessin suivant.
Ce harnais isolé est seul propriétaire des objets Cairo et des usages Fontconfig
de son processus. Le nettoyage global n'est jamais ajouté au runtime GTK réel.

La documentation officielle de Cairo réserve ce nettoyage aux contrôles mémoire
et exige qu'il ne reste aucun objet Cairo actif :
<https://www.cairographics.org/manual/cairo-Error-handling.html>.
Le contrat de finalisation de Fontconfig est décrit dans sa référence officielle :
<https://fontconfig.pages.freedesktop.org/fontconfig/fontconfig-devel/>.

Le test réel requiert les runtimes Cairo et Fontconfig, sans leurs en-têtes de
développement. Il ajoute douze redessins de texte sur trois fenêtres successives,
avec nettoyage et réinitialisation des caches entre chaque dessin. Les diagnostics
stderr des sous-processus sont désormais conservés intégralement en cas d'échec,
pour éviter de tronquer le début d'un rapport sanitizer.

Vérification locale du correctif : 10/10 groupes DrawingArea réussis, en normal
et avec ASan/UBSan. Les 12 redessins de texte passent avec le vrai Cairo.
Le runtime et `run_tests.sh` sont strictement inchangés ; aucune suppression LSan
ni désactivation de la détection de fuites n'est livrée.

La tentative locale avec `detect_leaks=1` est bloquée par l'accès du détecteur
à `/proc/<pid>/task`, avant même le test Cairo. Les résultats locaux utilisent
donc `detect_leaks=0` comme au lot initial ; ils ne prouvent pas encore que le
bilan LeakSanitizer est propre chez le mainteneur. Ce dernier point doit être
confirmé par une nouvelle exécution complète de `./run_tests.sh --release`.
Rester sur ce correctif avant de commencer Box/ScrolledWindow.
