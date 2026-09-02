# Architecture de Babet

Ce document donne le modèle produit en version courte. Les contrats détaillés
restent dans `INVARIANTS.md`, `EMBEDDING_DESIGN.md`, `NATIVE_PLUGIN_DESIGN.md`
et `GUI_DESIGN.md`.

## Cœur du projet : Lua -> un seul exécutable

Le modèle principal de Babet reste :

```text
projet Lua
   |
   v
Babet --create-exe
   |
   v
un seul exécutable généré
```

L'application générée contient le runtime complet du Babet qui l'a créée ainsi
que le projet Lua embarqué. `--create-exe` n'appelle ni compilateur ni linker
sur la machine où il s'exécute. Une application générée est finale et ne peut
pas elle-même fabriquer un autre exécutable ; il faut conserver/copier le Babet
original lorsqu'on a besoin d'un builder.

Hors intégrations système explicitement documentées comme `babet.gui`, ce modèle
doit rester déployable par simple copie de ce fichier unique.

## Plugins natifs : Babet charge du code natif externe

```text
CLI Babet original -> plugin.so
```

Les plugins natifs sont des extensions de confiance exécutées dans le processus
du CLI original. Ils servent notamment à des SDK natifs spécialisés ou
propriétaires ; ils ne servent pas à réduire la taille de Babet. Ce sont des
bibliothèques partagées externes et les applications générées par `--create-exe`
les refusent explicitement afin de préserver leur modèle mono-fichier.

## libbabet : un autre programme natif embarque Babet

```text
application hôte native
        |
        +-- libbabet.a
                |
                +-- runtime Babet + Lua
```

`libbabet.a` fonctionne dans le sens inverse d'un plugin : l'application externe
C/C++ (ou tout autre langage natif capable de consommer une ABI C) est le
programme principal et embarque Babet comme moteur. Le SDK développeur autonome
contient les headers C publics, un unique `libbabet.a` statique aplati, la
documentation, les exemples, la licence Babet et les notices tierces.

Après l'édition de liens statique finale, `libbabet.a` n'est pas un fichier à
conserver à côté de l'exécutable hôte.

Les builds de release publient le SDK par architecture, par exemple :

```text
babet-X.Y.Z-linux-x86_64-sdk.tar.gz
babet-X.Y.Z-linux-aarch64-sdk.tar.gz
babet-X.Y.Z-linux-armhf-sdk.tar.gz
```

Un SDK statique est propre à son architecture : une archive x86_64 ne peut pas
être réutilisée comme bibliothèque AArch64 ou armhf.

## GUI système optionnelle : Lua utilise GTK 4 via Babet

```text
Lua -> babet.gui -> dlopen/dlsym paresseux -> GTK 4 du système
```

GTK n'est ni lié dans Babet ni téléchargé par le build normal. Un script qui
n'utilise pas `babet.gui` conserve le contrat de déploiement habituel de Babet
et fonctionne sans GTK installé.

Un script utilisant `babet.gui` reste compatible avec `--create-exe` et produit
toujours un seul fichier applicatif, mais GTK 4 devient une dépendance runtime
explicite sur la machine cible. Si GTK 4 est absent, Babet renvoie une erreur
contrôlée avec des exemples d'installation.

C'est une exception volontaire, limitée à la GUI, à la promesse d'autonomie
habituelle. GTK 4 est aujourd'hui l'unique backend GUI supporté ; l'API ne
promet pas plusieurs toolkits interchangeables.

## Mesurer avant de créer les profils de build

La méthode mainteneur active est décrite dans
[`SIZE_PROFILES_STUDY.fr.md`](SIZE_PROFILES_STUDY.fr.md). L'attribution via map
du linker n'est que la phase 1 ; aucun switch de fonctionnalité supporté n'est
introduit avant des builds différentiels mesurant la taille réellement retirée
fonctionnalité par fonctionnalité.

## Modularité à la compilation : étude future, pas contrat actuel

Babet construit actuellement un runtime principal avec ses fonctionnalités
natives liées statiquement. Une future approche « façon Gentoo » pourra rendre
certains composants optionnels lors de la compilation de Babet. Si elle est
retenue, les applications générées hériteront exactement des fonctionnalités du
Babet constructeur, et `--create-exe` continuera donc à ne nécessiter aucune
toolchain externe. Aucun système de profils de ce type ne fait encore partie du
contrat actuel.

## Validation native des artefacts de release par architecture

Le SDK statique officiel et le binaire de release sont des artefacts propres à
une architecture. Un build x86_64 réussi ou une cross-compilation ne vaut pas
preuve de release AArch64 ou armhf.

Chaque builder natif est validé par le mainteneur avec :

```bash
./tools/run_native_arch_release_validation.sh
```

Le runner identifie l'architecture locale, exécute toute la campagne
pré-release, vérifie sur le binaire natif final le contrat GC de sections du
linker/OpenSSL et la matrice TLS déterministe, puis empaquette exactement ce
build et contrôle le tarball binaire ainsi que le tarball SDK. Les exemples du
SDK empaqueté sont reconstruits et exécutés après extraction. Pour
`linux-armhf`, les attributs ELF doivent en plus annoncer la convention d'appel
hard-float VFP.

La sortie console complète est aussi conservée automatiquement dans
`native-arch-validation.log` à la racine du projet, afin qu’une coupure SSH ne
fasse pas perdre le diagnostic d’une campagne longue.

La couverture sanitizer de release dépend explicitement de l’architecture :
x86_64/AArch64 utilisent ASan + UBSan, tandis que `linux-armhf` utilise UBSan
seul. Ce n’est pas un skip silencieux : le rapport compact enregistre
`pre_release_sanitizers=UBSAN_ONLY`. L’exception ARMHF a été établie sur le
builder ARMv6 de référence avec des programmes minimaux indépendants de Babet :
ASan dynamique s’arrête avant `main()`, les contournements preload/statique
segfaultent, alors que `libatomic` isolé et UBSan passent.

Sur un petit ARM, la compilation sanitizer peut aussi priver un feeder de
watchdog de CPU assez longtemps pour provoquer un reset matériel. Le runner
natif propose donc un mode sûr explicite :

```bash
sudo -v
./tools/run_native_arch_release_validation.sh --suspend-watchdog
```

Il enregistre avant tout arrêt les services initialement actifs
`watchdog.service`/`wd_keepalive.service` dans un marqueur persistant, ne fait
jamais `disable`/`mask` et vérifie le désarmement matériel lorsque sysfs expose
l’état. Avant le `stop`, il lance aussi un gardien root détaché et attend un handshake `ready` écrit par le vrai processus privilégié (sans se fier au PID transitoire de `sudo`/`setsid`) : la restauration
ne dépend donc pas d’un timestamp sudo encore valide plusieurs heures plus tard
et s’exécute également si le parent reçoit `SIGKILL`. Le marqueur persistant
reste le secours après coupure électrique, reboot ou échec du gardien ; le run
suivant répare cet état avant toute opération coûteuse. Sur une machine sans
watchdog, l’option est un no-op.

La commande reste volontairement identique sur x86_64, AArch64 et armhf.
La matrice native finale 2.23.0 est désormais complète sur les trois
architectures Linux officielles à partir du même arbre source.

Résultats natifs finaux :

- `linux-x86_64` : 13 842 952 octets strippés, ASan+UBSan, contrat de production
  GC/OpenSSL PASS, matrice TLS déterministe 7/0/0 et exemples du SDK empaqueté
  7/7 PASS ;
- `linux-aarch64` : 12 487 256 octets strippés, ASan+UBSan, contrat de production
  GC/OpenSSL PASS, matrice TLS déterministe 7/0/0 et exemples du SDK empaqueté
  7/7 PASS ;
- `linux-armhf` : 9 861 000 octets strippés, UBSan seul sur le builder ARMv6,
  ABI hard-float PASS, contrat de production GC/OpenSSL PASS, matrice TLS
  déterministe 7/0/0 et exemples du SDK empaqueté 7/7 PASS. La suspension
  optionnelle du watchdog utilisée sur ce builder contraint est correctement
  restaurée après validation.

Le snapshot source identique propagé entre les builders natifs possède le
SHA-256
`8757524730661e81bb3e26cde1c0226d8140fa57227900e4fdad52f07213ce73`.
Aucune architecture native officielle ne reste à valider.
