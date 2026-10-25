# Babet 2.33.0, lot 1 — isolation du test des sélecteurs

## Problème et correction

Le journal `babet-tests(20261024-075622).txt` confirme les compilations normale
et ASan/UBSan, les 24 tests images/fichiers sur faux GTK, les 74 tests de widgets
et les 35 tests GTK réels existants. Le test réel des images passe également.
Les deux passages s'arrêtent ensuite sur le sélecteur `open` : sa fenêtre est
introuvable sur le serveur Xvfb privé. Les tests suivants ne sont pas validés.

Le pilote héritait du bus de session du bureau et utilisait `GTK_USE_PORTAL=0`.
Dans GTK 4.14.5, `GtkFileDialog` privilégie pourtant le portail, sauf si
`GDK_DEBUG=no-portals` est actif. Un service de portail peut présenter le
sélecteur sur un autre écran. Le journal seul ne permet pas d'observer ce
service chez l'utilisateur ; le même échec a été reproduit localement avec
GTK réel et un portail D-Bus simulé qui reçoit la requête sans créer de fenêtre
sur le serveur Xvfb.

Le pilote corrigé impose `GDK_DEBUG=no-portals`, un bus de session volontairement
inaccessible et le rendu logiciel Cairo. Il retire les paramètres hérités de
démarrage D-Bus/Wayland et les injections des faux GTK, fixe la langue des
raccourcis et utilise des dossiers temporaires pour les préférences, fichiers
récents et caches. Il conserve les options ASan/UBSan et `fatal-criticals`.
Ces réglages concernent uniquement les processus de test : aucune modification
de `src/`, de l'API ni du comportement des applications Babet.

Quatre tests d'isolation sans GTK sont ajoutés au préflight de `run_tests.sh`.
Ils vérifient l'environnement réellement reçu par un processus enfant, la
préservation de l'environnement parent et des sanitizers, le nettoyage des
dossiers temporaires et l'absence de découverte automatique du bus de session.

## Vérifications

- Ancien pilote + GTK 4.14.5 + portail simulé : échec reproduit sur `open`,
  avec réception effective de `OpenFile` par le portail.
- Pilote corrigé, même portail disponible, paramètres hérités forçant les
  portails : **5/5** en normal, **5/5** sous ASan/UBSan, **aucun SKIP** et aucune
  requête au portail. Cas : image PNG/JPEG, ouverture, sélection multiple,
  enregistrement et annulation. L'enregistrement ne crée pas de fichier.
- Tests d'isolation : **4/4**.
- Contrats GUI : **140/140** ; cohérence des versions : **13/13**.
- Syntaxe Python/shell et contrôle des espaces du diff : PASS.

Les essais natifs utilisent les sources GUI/chargeur inchangées de ce lot,
Lua 5.5.1 et un exécutable ciblé ; les services de signaux et l'état curses sont
remplacés par des stubs. Le serveur Xvfb local utilise TCP en raison des limites
de l'environnement de préparation ; le pilote livré conserve le serveur privé
habituel du projet. Ce n'est pas un passage complet de `--release`.
LeakSanitizer est désactivé uniquement dans ces essais avec le GTK système,
selon la politique existante du pilote. Les contrôles ASan/UBSan restent actifs.

Référence de la décision de GTK :
[gtkfiledialog.c, tag 4.14.5](https://github.com/GNOME/gtk/blob/4.14.5/gtk/gtkfiledialog.c),
dans la préparation du `GtkFileChooserNative` et le contrôle `NO_PORTALS`.

## Application

Ce correctif complète le lot 1 et le correctif des versions déjà appliqués.
Extraire les quatre fichiers à la racine du projet, puis exécuter :

```bash
./run_tests.sh --release
```

Transmettre le nouveau journal. La version reste 2.33.0 en préparation ; les
lots 2 et 3 ne sont pas inclus, aucun tag ni publication n'est créé.
