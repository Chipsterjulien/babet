# Babet — correctifs après revue des primitives GTK4 de bureau

Date : 21 octobre 2026. Lot incrémental à appliquer après
`Babet_correctifs_desktop_GTK4_fichiers_modifies_20261021.zip`.

## Base et portée

La base est l’archive `v21 (Copie)(20261020-120142).zip`, complétée par le
correctif précédent dont le SHA256 est
`2d4143e870597e9f9f89892f0ef2f8573df70a06e71cfc8603b6ead18da61d27`.
Les quatre corrections de ce précédent lot sont conservées. Le présent ZIP
contient uniquement les fichiers modifiés ou ajoutés depuis cette base.

La version source reste 2.31.0 et les changelogs restent dans leur section non
publiée. La préparation de la 2.32.0, des PDF et du tag est une étape ultérieure.

## Corrections

### Aperçu de glisser

La remarque sur un aperçu hors fenêtre est confirmée. Un GtkWidgetPaintable
peut être valide sans dessiner de contenu lorsque son widget n’est pas affiché.

La solution retenue est le repli sur la poignée source :

- `setDragIcon` et la première installation de `setDragData` utilisent la poignée
  si l’aperçu choisi n’est pas mappé par GTK ;
- le choix est réévalué à chaque début de glisser, car l’aperçu peut devenir
  affiché, masqué, détaché ou détruit entre sa configuration et le geste ;
- cette réévaluation fonctionne sans callback `onDragState` utilisateur ;
- la recherche Lua et toute erreur restent dans l’appel protégé existant ;
- aucun widget n’est reparenté pour fabriquer une image hors fenêtre.

Le seul symbole GTK ajouté est `gtk_widget_get_mapped`. Sa déclaration est
présente dans les en-têtes officiels de GTK 4.0.0 ; ce lot ne relève donc pas la
version minimale requise.

Les nouveaux tests couvrent six états : aperçu non parenté, affiché, masqué via
son ancêtre, détaché, détruit et réinitialisé par `nil`. Les cas de disparition
couvrent aussi un aperçu installé alors qu’il était déjà affiché. Le simulateur
vérifie le widget sélectionné et l’équilibre des références des paintables.

Sur GTK réel, le test maintient le bouton pendant le glisser et lit des pixels
dans l’écran Xvfb : poignée rouge, aperçu vert, cible bleue. Il vérifie donc
l’image effectivement dessinée, pas seulement la réussite du dépôt. Le bouton
est relâché même si ce contrôle échoue.

### Test desktop intermittent

Le test conserve l’appui comme première étape et ouvre/referme le popover au
relâchement du bouton. L’acquittement `REAL_GTK_DESKTOP_POINTER_OK` n’est envoyé
qu’après ce relâchement et le `popdown`. L’injection d’Échap attend toujours cet
acquittement. Aucune répétition automatique d’Échap n’a été ajoutée pour cacher
un événement perdu.

L’hypothèse d’un grab GTK encore actif lors de l’appui est cohérente avec le
scénario signalé. L’échec intermittent initial n’a pas été reproduit ici ; les
dix passages complets après correction sont une vérification de stabilité,
pas une preuve d’absence de toute intermittence sur chaque environnement.

### Journaux

`.gitignore` contient maintenant `babet-tests*.txt`, en conservant les autres
règles, notamment celles des caches Python. Le contrôle structurel crée un
dépôt Git temporaire et vérifie effectivement que les noms usuels de journaux
sont ignorés, sans masquer un fichier source Lua témoin.

L’ancien journal `babet-tests-desktop-correctifs.txt` se trouve sur le poste de
l’utilisateur ; il n’était pas dans la base source reconstituée ici. Un ZIP de
fichiers modifiés ne supprime pas les fichiers existants du poste cible.
Supprimer cet ancien journal à la racine avant publication :

```bash
rm -f -- babet-tests-desktop-correctifs.txt
```

Les nouveaux journaux pourront rester localement et seront ignorés par Git.
Une règle d’exclusion ne retire pas un fichier déjà suivi : si un journal a déjà
été ajouté à Git, le retirer également de l’index avant de publier.
Ce ZIP ne contient aucun journal ni cache Python.

### Documentation

Les guides français et anglais précisent désormais :

- le repli de l’aperçu de glisser lorsque le widget choisi n’est pas affiché ;
- la consommation des caractères par Entry/TextView avant leurs callbacks
  `onKey`, et l’usage d’`onChanged` pour suivre le texte ;
- le lien entre `getSize`, `translatePoint`, `pick` et la dernière mise en page
  terminée par GTK ;
- toutes les valeurs par défaut de Paned, dont `resizeStart=false` ;
- la poursuite de la fermeture si le callback `onCloseRequest` lève une erreur.

## Vérifications réalisées

| Vérification | Résultat |
| --- | --- |
| Widgets avec GTK simulé, normal | 74 PASS / 0 FAIL |
| Widgets ASan + UBSan, simulateur également instrumenté | 74 PASS / 0 FAIL |
| GTK réel 4.14.2, Xvfb/XTest, normal | 34 PASS / 0 FAIL |
| GTK réel, ASan + UBSan | 10 suites complètes réussies, 34 PASS / 0 FAIL chacune |
| Allocations des callbacks, normal et ASan + UBSan | 5 groupes PASS dans chaque mode |
| Contrats structurels GUI, exclusion des journaux comprise | 137 PASS / 0 FAIL |
| Chargeur GTK autonome | 17 PASS / 0 FAIL |
| Syntaxe Python et Bash des scripts modifiés ; espaces de fin de ligne | OK |

Contre-épreuves sur le code précédent :

- le nouveau test simulé refuse l’utilisation de l’aperçu non parenté ;
- le contrôle visuel réel échoue avec zéro pixel de la couleur attendue ;
- l’ancienne règle `.gitignore` ne couvre pas le journal nommé
  `babet-tests-desktop-correctifs.txt`.

## Limites et validation sur le poste utilisateur

Les tests locaux utilisent un exécutable de test avec les vrais fichiers GUI,
le chargeur et Lua 5.5.1. Les services terminal et de dispatch des signaux sont
neutralisés dans cet exécutable. Il ne remplace pas la compilation complète de
Babet et `./run_tests.sh --release` reste à exécuter sur le projet complet.

L’environnement local interdit les sockets Unix. Le serveur Xvfb de validation
utilise donc TCP local avec un cookie Xauthority privé ; cette adaptation reste
dans l’outillage de travail et ne modifie pas le pilote livré. Le rendu natif a
été contrôlé sur X11 avec le moteur Cairo, pas sur Wayland.

LeakSanitizer ne fonctionne pas dans cet environnement : un petit programme
contenant volontairement une fuite s’arrête avec une erreur d’accès à
`/proc/.../task`. Les tests instrumentés ont donc utilisé `detect_leaks=0`.
ASan/UBSan et les compteurs explicites d’objets du simulateur sont actifs.
Aucune conclusion générale « aucune fuite » n’est déduite de ces exécutions.

Extraire le ZIP directement à la racine du projet en conservant les chemins,
y compris le fichier caché `.gitignore`, puis exécuter :

```bash
set -o pipefail
./run_tests.sh --release 2>&1 | tee babet-tests-desktop-validation.txt
```

UPX étant maintenant installé sur le poste utilisateur, son test optionnel
pourra également être exécuté dans la phase normale de cette validation.
Les PDF sont à régénérer lors de la préparation de la release.

## Références techniques

- [GtkWidgetPaintable](https://docs.gtk.org/gtk4/class.WidgetPaintable.html)
- [GtkDragSource.set_icon](https://docs.gtk.org/gtk4/method.DragSource.set_icon.html)
- [En-tête GtkWidget de GTK 4.0.0](https://raw.githubusercontent.com/GNOME/gtk/4.0.0/gtk/gtkwidget.h)
