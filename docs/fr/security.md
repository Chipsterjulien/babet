> [English](../en/security.md) | **Français**

# Modèle de sécurité

**Babet exécute des scripts Lua de confiance. Ce n'est pas une sandbox.**

Les scripts s'exécutent avec la bibliothèque standard Lua complète
(`luaL_openlibs`), et Babet expose en plus des primitives système
comme `exec`, `remove`, `rmdirAll` et `chdir`. Un script a donc les
mêmes privilèges que le processus qui le lance : il peut lire,
modifier ou supprimer des fichiers, et lancer des commandes
arbitraires. C'est volontaire — comme `make`, un script shell, ou
n'importe quel outil de build, Babet est conçu pour exécuter du
code que tu contrôles.

Ne lance que des `main.lua` et des modules `require` auxquels tu
fais confiance. **N'utilise pas** Babet pour exécuter du Lua
venant de sources non fiables ; il n'offre aucune isolation contre
du code hostile, et n'est pas pensé pour. Si tu dois exécuter des
scripts non fiables, utilise plutôt une sandbox Lua dédiée à cet
usage.

## Ce contre quoi le durcissement *protège*

Le travail de durcissement dans Babet protège les usages
*légitimes* contre les accidents et les attaques de supply chain :

- **Confinement de `copyTree` / `moveTree`** : la racine destination est
  ouverte une fois, puis chaque création, copie et déplacement est effectué
  relativement à ce descripteur avec `openat`/`mkdirat`/`renameat` et
  `O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW`. Un symlink préexistant ou remplacé
  pendant l'opération ne peut pas rediriger une écriture vers une cible
  extérieure. Les gardes `is_within()` empêchent en plus de choisir une
  destination résolue dans la source.
- **Création et extraction d’archives confinées** : `babet.archive` refuse les chemins de source de création et de
  destination de sortie/extraction lorsqu’ils sont symlinkés, les objets source sélectionnés non pris en charge, les noms
  source sélectionnés non UTF-8, une sortie dans l’arbre source, les chemins d’entrée absolus,
  les composants `.`/`..`, les backslashes, les doublons, les symlinks ZIP et
  les types spéciaux. Les archives à lire sont ouvertes une fois et doivent se
  résoudre vers un fichier régulier, ce qui écarte notamment les FIFO bloquants.
  La destination est parcourue avec des descripteurs et
  `O_NOFOLLOW`; chaque fichier est décompressé dans un temporaire du même
  répertoire, soumis à des limites anti-bombe, puis publié atomiquement. Les
  règles `include`/`exclude` de création réutilisent le moteur de glob sûr non
  récursif, élaguent les dossiers exclus avant ouverture et bornent chaque
  motif, le texte cumulé, les évaluations, le travail de correspondance et le
  nombre de motifs.
- **Confinement des flux compressés autonomes** : `babet.compression` accepte
  uniquement de véritables fichiers source réguliers, refuse les composants de
  chemin symlinkés et les destinations sur le même inode, épingle puis revérifie
  le descripteur source, borne la sortie décompressée, vérifie l’intégrité du
  codec, refuse les octets finaux parasites, prépare la sortie à côté de la
  destination et la publie atomiquement.
- **Écriture atomique générale** : `writeFileAtomic()` ouvre chaque parent sans suivre de symlink, refuse `..`, une destination finale symbolique ou non régulière et l’écrasement implicite. Les données sont écrites dans un temporaire privé du même dossier, les permissions sont appliquées, puis le fichier et le dossier sont synchronisés avant et après publication atomique.
- **Cleanup borné des groupes de processus** dans `babet.exec` couvre aussi
  la phase `chdir`/`exec`, les erreurs internes de polling et le cas où un
  enfant ferme ses pipes tout en continuant à tourner. Au timeout, TERM puis
  KILL visent le groupe entier ; Babet ne fait jamais de `waitpid` final
  illimité dans ces chemins d'erreur.
- **Limites de sortie** sur `babet.exec` bornent la quantité
  de stdout et stderr capturés en mémoire (par défaut 10 MiB
  chacun, configurable), pour qu'un sous-processus emballé ne
  puisse pas OOM le processus Babet.
- **Mises à jour locales épinglées** : `setAttributes` résout sa cible une
  seule fois et maintient `chown`, `chmod` et le rollback sur le même inode.
  `touch` crée avec `O_EXCL`, ne tronque jamais un fichier existant et épingle
  une cible existante avant de modifier son horodatage.
- **Staging anonyme et publication épinglée des exécutables** : `--create-exe`
  supprime le nom de son ZIP temporaire immédiatement après `mkstemp`, puis
  laisse miniz et la fusion rouvrir l’inode encore vivant via `/proc/self/fd`,
  jamais par un chemin temporaire remplaçable. La fusion finale épingle le
  dossier de sortie et publie avec `renameat()` ; modifier un parent symlinké ne
  peut donc pas rediriger l’exécutable.
- **Checksums des dépendances** : chaque dépendance embarquée est
  SHA256-pinnée dans `build_local.sh`. Un hash vide refuse la
  build. Un mismatch supprime le fichier téléchargé et sort en
  erreur. Ça protège contre un upstream compromis ou une archive
  Wayback Machine altérée (source de fallback).
- **Vérification TLS** est activée par défaut (`verify=true`). La
  désactiver demande un `verify=false` explicite par appel — pas
  de fallback silencieux. Pour les sockets TLS, des CA supplémentaires
  peuvent être passées via `ca_cert` ou `ca_path`; HTTP expose
  `ca_cert`. Les variables OpenSSL `SSL_CERT_FILE` / `SSL_CERT_DIR`
  restent également disponibles. SNI est envoyé indépendamment de la
  vérification lorsqu'un hostname DNS est connu.
- **Validation des lignes HTTP** : les URL et valeurs de headers refusent
  CR/LF, et les noms de headers doivent respecter la grammaire HTTP `token`.
  Une valeur contrôlée par un utilisateur ne peut donc pas injecter un header
  ou une seconde ligne de requête via ces champs.
- **Limites réseau en mémoire** : `socket:recv_line`, `socket:recv_all` et
  `http.max_body_size` bornent les accumulations principales. Après un timeout
  de lecture socket, les octets déjà consommés restent dans un buffer commun
  afin de ne pas être perdus ou réordonnés si le script change de méthode.
- **Filtrage borné des noms** : les champs regex `name`, `iname` et `path`
  de `babet.find` utilisent RE2 avec une limite de 4096 octets et un budget
  mémoire de 1 Mio par expression ; les globs sûrs de `babet.find` et de la
  création d’archives disposent eux aussi d’une limite de 4096 octets et d’un
  automate non récursif. Les listes de création ajoutent des plafonds cumulés
  sur le nombre, les octets et le travail de correspondance. Les références arrière
  et assertions d’anticipation/rétrospection ne font volontairement pas partie
  de la syntaxe RE2.

## Ce contre quoi il *ne protège pas*

- Un script malveillant. Babet n’a pas de sandbox. `babet.exec` n’invoque pas
  de shell, mais laisser une entrée non fiable choisir l’exécutable ou ses
  arguments peut tout de même permettre l’exécution d’un programme arbitraire
  ou une injection d’options. Transmettre du texte non fiable à `load` donne
  une exécution arbitraire de code Lua.
- Un attaquant déterminé qui a déjà obtenu une exécution de code
  sur la machine qui fait tourner Babet. Le durcissement rend
  les erreurs accidentelles visibles, pas les attaques
  adversariales impossibles.
- Les problèmes OS-level (exploits kernel, évasions de
  conteneur, escalade de privilèges). Babet est un binaire
  userland ordinaire.

## Pattern recommandé : moindre privilège

Quand tu fais tourner Babet en service, traite-le comme
n'importe quel processus non privilégié :

```sh
# En root, crée un user système dédié, sans shell.
useradd --system \
        --home-dir /var/lib/myapp \
        --create-home \
        --shell /usr/sbin/nologin \
        --comment "myapp Babet service" \
        myapp

# Utilise babet.user.exists("myapp") dans ton script d'install
# pour vérifier que le user est provisionné avant de lancer le
# daemon.
```

Combine ça avec des options de unit `systemd` comme `User=myapp`,
`PrivateTmp=yes`, `ProtectSystem=strict`, `NoNewPrivileges=yes`,
et `CapabilityBoundingSet=` (vide sauf si tu as vraiment besoin
d'une capability). Le kernel fait bien plus que Babet ne peut
le faire pour contenir un script qui se comporte mal ; laisse-le
faire.
