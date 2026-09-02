# Étude du GC de sections Babet — Candidate 10

La Candidate 10 est une suite **uniquement expérimentale** de la Candidate 9.
La Candidate 9 a fermé la piste des `Configure no-*` OpenSSL : le plafond
raisonnablement supprimable sans perte reste sous 512 KiB, tandis que les
capacités TLS/PQC modernes et les diagnostics sont conservés. La Candidate 10
pose donc une autre question : « quel code est déjà inatteignable au lien final ? »

Au moment de la mesure Candidate 10, aucun flag de GC n'était activé dans le build Babet normal.

## Règle de décision fixée avant la mesure

- gain réel total **inférieur à 256 KiB** : STOP ;
- gain **au moins égal à 256 KiB** : revue d'adoption autorisée, jamais automatique ;
- une adoption exige toujours la surface `babet.*` exacte, les plugins natifs,
  l'embedding/packaging et les capacités TLS déterministes intacts.

Le seuil plus bas que Candidate 9 reflète une complexité permanente plus faible,
sans accepter pour autant un gain minuscule face au risque latent de code
d'enregistrement éliminé.

## Variantes

### Variante A

`-Wl,--gc-sections` seul. Elle mesure ce que le linker peut déjà retirer dans
les archives dont les producteurs ont découpé fonctions/données. Le premier
lien conserve aussi la sortie `--print-gc-sections`.

### Variante B

Variante A plus `-ffunction-sections -fdata-sections` sur les **sources propres
à Babet uniquement**. sqlite/miniz embarqués et les autres archives tierces ne
sont pas reclassés dans B, afin que le delta marginal A→B reste attribuable.

### Variante C

Variante B plus un build OpenSSL 3.5.8 séparé avec ces deux flags de compilation.
Les capacités et options `Configure` OpenSSL restent identiques. Au moment de Candidate 10, le
`build_local.sh` de production n'activait pas ces flags.

## Protection des enregistrements

Candidate 10 ajoute une régression runtime explicite de la surface top-level
`babet.*` attendue. Toute entrée absente ou inattendue fait échouer le test. Ce
garde-fou reste utile même si le GC est refusé.

Chaque binaire A/B/C passe aussi la régression runtime des plugins natifs, la
régression packaging `--create-exe` et la matrice TLS déterministe de Candidate 9.
Les campagnes complètes normal/sanitizers/release ne sont requises que si le
gain franchit le seuil et qu'une adoption est envisagée.

## Portée architecture

Les chiffres Candidate 10 sont spécifiques x86_64. Le découpage des archives et
l'assembleur OpenSSL diffèrent selon l'architecture ; aucune conclusion de taille
ARM n'en est déduite.


## Résultat mesuré et décision de la Candidate 10

La campagne x86_64/Ubuntu GCC 13.3 utilise la baseline OpenSSL 3.5.8 de
**15 563 592 octets** :

| Variante | Taille strippée | Gain vs baseline | Gain marginal |
|---|---:|---:|---:|
| A — linker `--gc-sections` seul | 14 445 384 | 1 118 208 (7,18 %) | 1 118 208 |
| B — A + sections fonctions/données Babet | 14 383 944 | 1 179 648 (7,58 %) | 61 440 vs A |
| C — B + OpenSSL découpé | 13 781 512 | 1 782 080 (11,45 %) | 602 432 vs B |

A franchit largement le seuil de revue de 256 Kio fixé avant mesure. B est
**STOP** : 61 440 octets marginaux ne justifient pas de découper en permanence
les unités de traduction de Babet. C n'est pas encore une mesure d'adoption,
car son build OpenSSL expérimental n'a pas démontré son identité de
configuration avec le build OpenSSL de production. La Candidate 11 isole donc
OpenSSL sans B et ajoute un témoin de production reconstruit à neuf.

A ne compile **pas** les sources propres à Babet avec
`-ffunction-sections`, mais les templates C++, fonctions inline, RTTI et autres
entités COMDAT vivent déjà dans des sections collectables séparément. L'audit
`--print-gc-sections` de Candidate 11 montre donc de nombreuses suppressions dans
`libbabet.a` lui-même, en plus de libstdc++/libarchive. Cela corrige l'hypothèse
initiale selon laquelle A ne pouvait agir que sur les dépendances tierces. Le
code Babet ordinaire hors COMDAT conserve le découpage normal du compilateur.
Le gain exact dépend de la toolchain et de l'architecture.

## Candidate 11 — revue d'adoption

Candidate 11 n'active toujours aucun GC dans le build normal. Elle :

1. reconstruit A et audite `--print-gc-sections`, avec échec si l'un des six
   symboles C exportés (`babet_version`, `babet_status_name`, quatre `babet_host_call_*`)
   ou une section init/fini/constructeur/destructeur est éliminé. Les noms C++ internes
   contenant `babet_` et les groupes COMDAT ne sont pas assimilés à la surface exportée ;
2. reconstruit OpenSSL 3.5.8 depuis le tarball épinglé avec la ligne de
   production **littérale** `./Configure no-shared --openssldir=/etc/ssl` et
   exige que ce témoin reproduise exactement la taille strippée de A ;
3. construit D = A + OpenSSL avec seulement
   `-ffunction-sections -fdata-sections`, sans découpage Babet ;
4. conserve le seuil de revue de 256 Kio ;
5. rejoue la matrice TLS déterministe sur A et D ;
6. benchmarke baseline/A/D sur la même fixture TLS locale avec warm-up et douze
   blocs entrelacés équilibrés couvrant les six ordres possibles. La charge est
   calibrée pour viser environ une seconde par échantillon (avec reprise
   automatique plus longue si nécessaire) ; le seuil inchangé de 10 % s'applique
   aux médianes globales et aux médianes appariées par bloc, tandis que minimum
   et MAD relative servent de diagnostic de bruit ;
7. exécute une campagne A complète sous une vraie locale UTF-8 non-C, puis les
   validations normales + ASan/UBSan + pré-release/réseau complètes sur A et D.

La passe locale cible précisément les facettes du runtime C++ susceptibles de
partir en A. Un hook interne permet au harnais de tester un binaire/build CMake
préconstruit : sans ces variables mainteneur, `run_tests.sh` conserve exactement
son comportement historique.


Note de build témoin Candidate 11 : les reconstructions OpenSSL témoin et sectionnée utilisent uniquement la cible standard `build_libs`. Elle produit les archives `libcrypto.a`/`libssl.a` requises sans compiler les applications ni les exécutables de test OpenSSL ; le contrat `Configure` reste identique à la production, hormis les deux flags de section pour D. Les arbres de travail sont créés sous `build/gc-sections-study/candidate11/` plutôt que dans `/tmp` et supprimés après copie des deux archives. Les avertissements `mkinstallvars.pl` propres à `build_libs` sur des variables d’installation non utilisées ne sont pas assimilés à une dérive de configuration : `configure.log` doit rester propre et le témoin doit reproduire A à l’octet près.

Si une exécution Candidate 11 s'est arrêtée après la mesure A/témoin/D mais avant
la validation finale, `tools/run_candidate11_gc_adoption.sh --resume` réutilise uniquement
des artefacts déjà présents après avoir exigé `matches_A_size=yes` et les quatre builds
normal/sanitizers. Il ne reconstruit alors ni la baseline ni OpenSSL.


## Adoption en production

Candidate 11 est entièrement verte sur la machine de référence x86_64
Ubuntu/GCC 13.3. Le témoin OpenSSL de production reconstruit reproduit A
**à l'octet près** à **14 445 384 octets**. D (A + OpenSSL découpé, sans
sectionnement des sources Babet) mesure **13 842 952 octets**, soit un gain de
**1 720 640 octets (11,06 %)** face à la baseline Candidate 11 de 15 563 592.
Le gain OpenSSL marginal de D face à A est de **602 432 octets**.

Le contrôle croisé Candidate 10/11 tombe lui aussi exactement : C vaut
13 781 512 octets et D 13 842 952 ; leur différence de **61 440 octets** est
précisément le gain marginal de B mesuré indépendamment. Les trois leviers sont
donc additifs sur le build de référence.

Tous les garde-fous d'adoption passent :

- aucun des six symboles C exportés ni aucune section init/fini/ctor/dtor n'est
  éliminé ;
- la matrice TLS reste à 7/7 sur A et D, y compris X25519MLKEM768 ;
- le benchmark TLS local initial reste sous le seuil médian de 10 % fixé avant
  mesure. Une première répétition d'intégration a montré que les anciens
  échantillons de 24 requêtes ne duraient qu'environ 50 à 90 ms et étaient
  dominés par le bruit ordonnanceur/CPU malgré l'équilibrage des ordres. Le
  contrôle permanent conserve donc exactement le seuil de 10 %, calibre la
  durée vers une seconde, relance automatiquement avec une cible plus longue si
  nécessaire et exige le passage des médianes globales **et** appariées par bloc,
  tout en rapportant minimum et MAD relative ;
- la campagne complète A sous une vraie locale `fr_FR.utf8` passe ;
- les validations normal + ASan/UBSan + release/réseau complètes passent sur A
  et D.

Décision produit Babet 2.23.0 :

- **adopter** `-Wl,--gc-sections` au lien final ;
- **adopter** `-ffunction-sections -fdata-sections` pour l'OpenSSL vendored ;
- **ne pas adopter** ces flags sur les sources propres à Babet (variante B) ;
- conserver un seul runtime officiel complet, sans profils
  `minimal`/`standard`/`full` et sans retrait de capacités OpenSSL.

`build_local.sh` empreinte désormais le contrat exact `Configure` d'OpenSSL et
reconstruit le cache 3.5.8 si l'empreinte manque ou diverge. Un ancien cache
compilé sans sectionnement ne peut donc pas neutraliser silencieusement D. Le
bootstrap OpenSSL normal utilise `build_libs`, Babet n'ayant besoin que de
`libcrypto.a` et `libssl.a`.

La référence D x86_64 est **1 154 176 octets (7,70 %) plus petite** que le
binaire 2.22.2 publié (14 997 128 octets), malgré les fonctionnalités ajoutées
depuis. Ce chiffre reste propre à la toolchain/architecture de référence : les
futurs builds aarch64/armhf devront être remesurés nativement.
