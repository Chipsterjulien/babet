# Préparation de Babet 2.35.0 — 5 novembre 2026

Cette préparation part du dernier lot GUI/runtime validé, livré dans
`babet-ajouts-gui-runtime.zip`. Elle ne modifie aucun fichier de `src/` ni les
tests de ce lot. Elle fixe la version source à 2.35.0 avant la compilation et
la création du tag par le mainteneur.

## Fichiers de publication

- `CMakeLists.txt`, README et index des manuels annoncent 2.35.0.
- Les deux CHANGELOG publient les ajouts sous `[2.35.0] - 2026-11-05`.
  Leur historique à partir de la section 2.34.0 est conservé à l'identique.
- Les chapitres concernés présentent les API comme disponibles depuis 2.35.0.
  L'exemple de `--version` du guide de démarrage est également actualisé.
- Le préprocesseur PDF reconnaît les chapitres runtime et file-lock pour
  produire des liens internes. Les deux manuels PDF sont régénérés.
- Le guide de publication prévoit l'interface web GitHub et les archives
  runtime/SDK accompagnées de leurs sommes SHA256.

Les anciennes notes archivées décrivent leur état de préparation au moment
de leur rédaction ; leurs limites de validation ne sont pas réécrites.

## Validation du lot fonctionnel fournie par le mainteneur

Les journaux transmis avant cette préparation se terminent avec succès pour
`./run_tests.sh --release` : validation ASan + UBSan, reconstruction normale,
tests réseau et tests du runtime complet. Ils couvrent notamment :

- boucle GUI : 4/4 ; ressources et contexte : 3/3, avec les workers ;
- widgets : 74/74 ; images et fichiers : 30/30 ; texte enrichi : 24/24 ;
- GTK réel : 36/36 ; images et sélecteurs réels : 7/7 ;
- workers : 234/234 ; tests réseau : 11/11 ;
- les groupes natifs et d'injection d'erreurs mémoire, dont les rappels
  différés et la reprise par un autre état Lua.

Le scénario sudo sous pseudo-terminal peut être ignoré faute d'autorisation
non interactive. UPX est exercé en mode normal, pas sous ASan. Ces exclusions
ne sont pas des tests réussis ni des échecs du lot.

## Contrôles de cette préparation

Les contrats release (13), GUI widgets (159), GUI runtime (35) et GUI design
(33) passent. Les deux PDF ont été générés et leurs pages modifiées ainsi que
les liens des nouveaux chapitres ont été contrôlés. Les fichiers C++ restent
identiques au lot validé.

La compilation complète avec le numéro 2.35.0 et la fabrication des artefacts
de distribution restent à exécuter sur la machine de publication. Le tag doit
viser le commit contenant ces fichiers et les ajouts fonctionnels précédents.
Aucun commit, tag ni envoi vers GitHub n'est effectué par cette préparation.

Le rapport ABI décrit les exigences du binaire construit ; cette préparation
ne réduit pas la version minimale de glibc et ne fournit pas de binaire pour
une autre distribution ou architecture.
