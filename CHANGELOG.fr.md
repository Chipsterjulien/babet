# Journal des modifications

Ce fichier décrit les changements notables de Babet.

Le projet suit le versionnage sémantique pour ses publications. Les notes de
migration et d’utilisation sont conservées avec chaque version lorsqu’un
nouveau contrat ou une règle opérationnelle peut affecter les scripts existants.

## [2.9.1] - 2026-07-24

### Correctif HTTP pour les réponses chunked et sans `Content-Length`

- correction d'une régression introduite par Babet 2.9.0 lors de la
  neutralisation de la limite interne de cpp-httplib 0.45.0 : la valeur `0`
  était interprétée comme une limite nulle sur les chemins de lecture
  `Transfer-Encoding: chunked` et sans `Content-Length`, provoquant
  `http: Failed to read connection` dès le premier octet reçu ;
- remplacement de cette valeur par la plus grande valeur `std::size_t`
  représentable, de sorte que les receivers de Babet restent l'unique autorité
  pour `max_body_size` et `max_file_size` ;
- conservation des garanties existantes : aucune réponse mémoire partielle,
  destination existante préservée après erreur, temporaire de téléchargement
  supprimé et diagnostic explicite en cas de dépassement ;
- ajout de tests locaux déterministes pour les réponses chunked de 128 Kio, les
  limites exactes et juste inférieures, les téléchargements, les chunks
  fragmentés avec extensions et trailers, les réponses délimitées par fermeture
  de connexion et les flux chunked tronqués ;
- ajout de gardes indépendantes dans `smoke_test_network.sh`, exécutées par
  `run_tests.sh --release`, qui vérifient les receivers mémoire et fichier en
  HTTPS local pour le cadrage chunked, puis en HTTP local pour le cadrage par
  fermeture de connexion ;
- correction validée pour le cas réel de l'API AUR utilisé par yaourt, sans
  dépendre de ce service externe dans les tests bloquants ;
- durcissement du bootstrap de Zstandard : une installation n'est désormais
  considérée complète que si `libzstd.a`, `zstd.h` et `zstd_errors.h` sont
  tous présents ; une extraction source interrompue ou incomplète est
  automatiquement remplacée par une réextraction propre dans un dossier
  temporaire ;
- ajout d'un préflight local sans réseau à `run_tests.sh --release`, couvrant
  l'installation partielle, la source partielle, la réutilisation d'une source
  complète et le refus d'une archive source mal formée.

## [2.9.0] - 2026-07-17

### Résumé de la version

Babet 2.9.0 renforce la supervision des processus, la manipulation des données
binaires, la publication atomique de fichiers et l'orchestration concurrente
des workers. Les appels historiques à `spawn()` et aux workers restent
compatibles par défaut, tandis que les nouvelles API optionnelles suppriment le
recours à une commande Base64 externe, évitent les pipes de journaux WebDriver
non drainés, permettent des attentes bornées et un arrêt coopératif des workers, puis autorisent une
communication MPMC directe sans relais par l'état Lua parent.

### Lot A — redirections configurables de `babet.spawn()`

- passage de la version source à 2.9.0 ;
- conservation stricte des trois pipes non bloquants comme comportement par
  défaut, sans modification des appels historiques ;
- ajout des modes `"pipe"`, `"inherit"` et `"null"` pour stdin, stdout et
  stderr ;
- ajout de la fusion `stderr = "stdout"`, appliquée après la configuration de
  stdout ;
- ajout des redirections directes de stdout et stderr vers un fichier régulier,
  avec troncature ou ajout, permissions de création bornées à `0777`,
  `O_CLOEXEC`, refus de la destination finale symbolique et vérification
  `fstat()` ;
- ouverture de toutes les destinations avant `fork()`, afin qu'une erreur
  d'ouverture empêche la création du processus enfant ;
- ajout de la raison stable `"not_piped"` pour les méthodes de streaming visant
  un flux hérité, nul, fusionné ou redirigé vers un fichier ;
- ajout de tests pour toutes les validations, les chemins spéciaux, troncature,
  ajout, permissions, fusion, `/dev/null`, héritage, refus des symlinks et
  compatibilité du comportement historique ;
- enrichissement synchronisé des documentations française et anglaise avec un
  exemple distinct pour chaque mode et un exemple combiné WebDriver/daemon.

### Lot B — module Base64 natif binaire

- ajout de `babet.base64.encode(data [, opts])` et
  `babet.base64.decode(text [, opts])`, disponibles dans l'état Lua principal
  comme dans chaque worker ;
- implémentation interne sans processus externe et sans dépendance
  supplémentaire, avec chaînes Lua binaires préservant les octets NUL et les
  données non UTF-8 ;
- prise en charge des alphabets RFC 4648 standard et URL-safe via
  `url_safe` ;
- ajout du contrôle du padding à l'encodage et du décodage explicite des
  formes non paddées via `padding` et `allow_unpadded` ;
- décodage canonique strict : alphabet exact, padding final uniquement,
  longueur cohérente, maximum de deux `=`, refus des groupes tronqués et des
  bits finaux inutilisés non nuls ;
- ajout de `ignore_whitespace` pour les six espaces ASCII, sans rendre le
  décodeur permissif sur les autres octets ;
- ajout de `max_output`, limite inclusive contrôlée après validation complète
  et avant l'allocation de la sortie décodée ;
- analyse du texte en deux passes sans copie ni table de positions
  proportionnelle à l'entrée, afin de conserver les offsets d'erreur exacts
  sans multiplier la mémoire ;
- validation stricte de l'arité, des types, des clés et des options inconnues,
  avec distinction entre erreurs d'appel levées et données invalides renvoyées
  sous forme `nil, err` ;
- ajout des vecteurs RFC 4648, des 256 octets, d'un gros buffer binaire, des
  alphabets, du padding, des espaces, des limites, des erreurs canoniques et de
  l'utilisation depuis un worker aux tests de non-régression ;
- ajout de pages française et anglaise détaillées, d'exemples séparés pour
  chaque option, d'un exemple combiné URL-safe sans padding et de l'intégration
  aux manuels PDF.


### Lot C — écriture atomique générique de fichiers

- ajout de `babet.writeFileAtomic(path, data [, opts])` dans l’état Lua principal et dans chaque worker ;
- prise en charge des chaînes Lua binaires, y compris les octets NUL et les données non UTF-8, sans copie intermédiaire proportionnelle dans le binding ;
- ajout des options strictes `overwrite` (`false`), `permissions` (`0644`) et `durable` (`true`) ;
- création d’un temporaire privé `0600` dans le dossier final, boucle d’écriture complète gérant `EINTR` et les écritures partielles, `fchmod()` avant synchronisation, puis publication atomique ;
- refus de l’écrasement par défaut avec publication `linkat()` sans remplacement, et remplacement explicite d’un fichier régulier par `renameat()` ;
- parcours du parent composant par composant avec `openat()`/`O_NOFOLLOW`, refus de `..`, des parents symboliques, de la destination finale symbolique et des dossiers, FIFO, sockets ou périphériques ;
- absence de création implicite des parents et suppression au mieux de tout temporaire après une erreur antérieure à la publication ;
- synchronisation par défaut du temporaire puis du dossier parent, avec diagnostic explicite si le fichier a déjà été publié mais que la persistance du renommage n’a pas pu être confirmée ;
- ajout des tests de contenu binaire, fichier vide, écrasement, permissions, durabilité désactivée, chemins spéciaux, symlinks, types spéciaux, validations, nettoyage et utilisation depuis un worker ;
- ajout d’un chapitre français et anglais détaillé, d’exemples séparés pour chaque option, d’un exemple combiné Base64/Selenium et de l’intégration aux manuels PDF.


### Lot D — cycle de vie robuste des workers

- refus strict de toute option inconnue ou de toute clé d’option non chaîne dans `babet.workers.spawn()`, y compris les noms contenant un suffixe NUL caché ;
- ajout de `job:status()`, non bloquant et non consommant, avec les états stables `"running"`, `"done"` et `"error"` ;
- extension de `job:join(timeout?)` avec timeout en secondes sur horloge monotone, `0` non bloquant et retour `(nil, "timeout")` sans fermeture, jointure ni consommation du résultat ;
- ajout d’un signal de terminaison pthread distinct des queues, protégé contre les réveils perdus et partagé par tous les chemins de succès, d’erreur Lua ou d’exception C++ ;
- ajout de l’annulation coopérative idempotente `job:cancel()` et de `worker.cancelled()` ;
- l’annulation ferme uniquement l’inbox, réveille `worker.recv()` avec `"cancelled"`, refuse les futurs `job:send()` avec la même raison et laisse l’outbox drainable pour un dernier message ;
- distinction documentée entre `close()` — fin normale des commandes avec drainage — et `cancel()` — abandon coopératif des commandes encore en attente ;
- le garbage collector demande désormais l’annulation avant de fermer les deux queues et de joindre le thread, sans introduire de terminaison forcée dangereuse ;
- ajout de tests de statut non consommant, timeouts immédiat et borné, messagerie toujours utilisable après timeout, erreurs finales, validations, annulation idempotente, réveil d’un `worker.recv()` bloqué, abandon des commandes encore en inbox, dernier message d’outbox et observation directe du drapeau ;
- mise à jour synchronisée des documentations française et anglaise, avec exemples séparés et exemples combinés `status`/`join(timeout)`/`cancel`.


### Lot E — channels directs partagés entre workers

- ajout de `babet.workers.channel({ capacity = 64 })`, queue bornée de 1 à
  1 000 000 messages, thread-safe, FIFO, multi-producteurs et
  multi-consommateurs ;
- transmission explicite des handles par `workers.spawn(..., { channels = ... })`
  et exposition systématique de `worker.channels` dans chaque état Lua, sans
  modifier le contrat JSON de `worker.args` ;
- ajout de `channel:send(value, timeout?)`, `channel:recv(timeout?)`,
  `channel:close()` et `channel:is_closed()` avec les raisons stables
  `full`, `empty`, `timeout` et `closed` ;
- fermeture globale idempotente, réveil des producteurs et consommateurs
  bloqués, refus des nouveaux envois et drainage des messages déjà présents
  avant que `recv()` ne signale `closed` ;
- intégration à l'annulation coopérative : `job:cancel()` réveille le
  `channel:send()` ou `channel:recv()` bloqué du worker concerné avec
  `cancelled`, sans fermer le channel partagé pour les autres participants ;
- partage de la ressource C++ par références comptées : le GC d'un handle local
  ne ferme pas le channel pour les autres états, tandis que la dernière
  référence ferme et détruit proprement la queue ;
- extraction du contexte des erreurs de sérialisation workers afin que les
  diagnostics de channels identifient précisément `workers.channel.send` ou
  `workers.channel.recv` ;
- validation stricte des options, capacités, noms de channels, valeurs de
  `opts.channels`, arités et valeurs transférées, les channels restant
  volontairement non sérialisables comme messages ;
- ajout de tests parent vers worker, worker vers parent, worker vers worker,
  FIFO, `nil`, fermeture avec drainage, réveils bloqués, durée de vie des
  handles, deux producteurs/deux consommateurs et stress MPMC ;
- validation native de 100 000 messages, 2 000 courses d'annulation et
  1 000 courses de fermeture sous compilation normale, ASan+UBSan et
  ThreadSanitizer ;
- mise à jour synchronisée des README, documentations française et anglaise,
  exemples détaillés et manuels PDF.

### Validation de la version

Le candidat final a réussi :

- 3319 PASS / 0 FAIL en mode dossier ;
- 3306 PASS / 0 FAIL en mode embarqué ;
- 3306 PASS / 0 FAIL en mode embarqué via `PATH` ;
- 9/9 modes d'exécution sous ASan + UBSan ;
- 9/9 modes à nouveau avec le build normal final.

La barrière de publication complète, incluant les tests TLS locaux et les smoke
tests réseau, reste :

```sh
./run_tests.sh --release
```

## [2.8.0] - 2026-07-17

### Résumé de la version

Babet 2.8.0 complète le cycle de vie des archives avec une inspection bornée,
un test intégral d’intégrité et de sécurité, une extraction sélective et une
prévisualisation d’extraction sans écriture. Les lecteurs ZIP et TAR brut/gzip/
xz/bzip2/zstd partagent des limites strictes, des diagnostics déterministes,
la prise en charge des workers et la politique existante de confinement de la
destination.

La proposition optionnelle `archive.read()` en mémoire a été étudiée puis
volontairement différée : `extractFile()` couvre déjà l’extraction ciblée, alors
qu’une nouvelle API retournant une chaîne Lua ajouterait un autre contrat
d’allocation et de taille sans être nécessaire au thème de la 2.8.0.

### Lot 1 — inspection avancée des archives

- passage de la version source à 2.8.0 ;
- conservation de l’API historique bornée `babet.archive.list(archive [, opts])`
  et de sa table englobante `format`/`compression`/`entries`, sans ajout d’un
  itérateur redondant ;
- conservation stricte de l’ordre interne des entrées, sans tri ni
  déduplication ;
- ajout de `index` et `valid_utf8` à chaque entrée, avec conservation exacte
  des noms sous forme de chaînes Lua binaires et sans normalisation Unicode ;
- ajout des métadonnées `mtime`, `mtime_nsec`, `uid` et `gid` lorsqu’elles sont
  réellement fournies par le backend, avec `nil` explicite lorsqu’elles sont
  absentes ;
- ajout des diagnostics déterministes `duplicate`/`duplicate_of` pour les noms
  bruts répétés et `conflict`/`conflict_with`/`conflict_reason` pour les
  collisions de chemins normalisés ou fichier/répertoire ;
- ajout des agrégats `total_name_bytes`, `duplicates` et `conflicts` au résultat
  global ;
- ajout des limites strictes `max_path_length` (64 Kio par défaut, plafond
  1 Mio) et `max_total_name_bytes` (64 Mio par défaut et au maximum),
  mutualisées avec `extract()` et `extractFile()` ;
- maintien indépendant de la règle d’extractibilité à 4096 octets : un nom
  plus long peut être inspecté dans le budget de métadonnées mais reste
  `safe_path = false` ;
- bornage du graphe de préfixes utilisé pour diagnostiquer les collisions à
  100000 répertoires et 64 Mio de chemins cumulés ;
- clarification du contrat d’intégrité : `list()` inventorie et diagnostique
  les métadonnées ZIP sans décompresser tous les payloads, tandis que TAR doit
  être consommé jusqu’à son terme pour atteindre tous les en-têtes ;
- ajout de tests ZIP/TAR pour les métadonnées, l’ordre, UTF-8 invalide,
  doublons, collisions normalisées, archives fractionnées/tronquées, limites
  exactes et resserrées, workers et absence d’écriture avant extraction ;
- enrichissement systématique des documentations française et anglaise avec
  un exemple par option, des exemples combinés, des diagnostics de sécurité,
  les différences ZIP/TAR et l’usage dans les workers.

### Lot 2 — vérification complète d’intégrité et de sécurité

- ajout de `babet.archive.test(archive [, opts])`, disponible dans l’état Lua
  principal et les workers, avec retour strict `(result, nil)` ou
  `(nil, message)` ;
- détection du format et de la compression par contenu pour ZIP, TAR, TAR gzip,
  xz, bzip2 et zstd, sans aucune écriture ni création de dossier temporaire ;
- réutilisation stricte des limites `max_entries`, `max_entry_size`,
  `max_total_size`, `max_path_length`, `max_total_name_bytes` et
  `max_compression_ratio` déjà partagées par l’inspection et l’extraction ;
- validation ZIP complète des métadonnées EOCD/ZIP64, en-têtes locaux, noms,
  drapeaux, méthodes, tailles, CRC, champs ZIP64, data descriptors, bornes et
  chevauchements, puis décompression intégrale de chaque entrée non dossier ;
- consommation intégrale des TAR bruts et compressés avec vérification des
  en-têtes, checksums disponibles, troncatures, padding, corruption et données
  finales selon les garanties de libarchive, zlib, liblzma, libbz2 et libzstd ;
- verdict de sécurité strict : refus des chemins dangereux, doublons,
  collisions fichier/dossier, liens, fichiers sparse, objets spéciaux, entrées
  chiffrées et méthodes ZIP non prises en charge ;
- ajout d’un résumé déterministe `format`, `compression`, `entries`, `files`,
  `directories`, `total_size`, `archive_size`, `total_name_bytes` et `zip64` ;
- ajout de tests ZIP/TAR, archives vides, en-têtes locaux endommagés, data
  descriptors, CRC, corruption de chaque compression, limites, workers et
  absence totale d’effet de bord ;
- enrichissement synchronisé des documentations française et anglaise avec un
  exemple par limite, des exemples combinés, la distinction `list()`/`test()`
  et l’utilisation dans les workers.

### Lot 3 — extraction sélective par globs sûrs

- ajout des options strictes `include` et `exclude` à
  `babet.archive.extract()`, sans modifier `extractFile()` ni les appels
  historiques sans filtre ;
- mutualisation du parseur, de la compilation, des limites et du budget de
  calcul avec le moteur `safe_glob` déjà utilisé par `archive.create()` ;
- correspondance ancrée, orientée octets et sensible à la casse sur les chemins
  internes normalisés, avec les mêmes règles pour `*`, `**`, `?` et `\` ;
- priorité systématique de `exclude`, y compris pour l’élagage d’un répertoire
  et de tous ses descendants, même lorsque les parents sont implicites ;
- validation des types, doublons et collisions de sortie limitée aux entrées
  sélectionnées, tandis que les limites d’archive et l’analyse des en-têtes
  restent globales ;
- absence totale de création de destination lorsque des filtres actifs ne
  sélectionnent aucune entrée, et création des seuls parents nécessaires aux
  fichiers retenus ;
- ajout des champs de résultat `entries` et `skipped`, tout en conservant
  `files`, `directories`, `bytes` et `path` ;
- prise en charge identique de ZIP, TAR brut, TAR gzip, xz, bzip2 et zstd, ainsi
  que des workers ;
- ajout de tests ZIP/TAR complets pour inclusion seule, exclusion seule,
  priorité, sous-arbres, échappement, limites, sélection vide, doublons et
  collisions hors sélection, entrées dangereuses ou spéciales ignorées,
  formats compressés et workers ;
- enrichissement synchronisé de la documentation française et anglaise avec
  des exemples séparés et combinés, les effets de bord, les limites et la
  distinction entre extraction sélective et `archive.test()`.

### Lot 4 — simulation d’extraction sans modification du système de fichiers

- ajout de l’option booléenne stricte `dry_run` à `babet.archive.extract()`,
  sans l’exposer à `list()`, `test()` ni `extractFile()` ;
- réutilisation du même scan, des mêmes limites anti-bombe, des mêmes filtres
  `include`/`exclude`, de la même normalisation et du même plan de destination
  que l’extraction réelle ;
- parcours de la destination uniquement en lecture avec des descripteurs de
  répertoires, `openat`/`fstatat` et `O_NOFOLLOW`, sans `mkdir`, fichier
  temporaire, écriture, chmod, renommage, suppression ni publication ;
- ajout des compteurs `would_create`, `would_overwrite`, `would_skip` et du
  booléen `would_create_destination`, limités aux entrées explicites
  sélectionnées et absents du résultat historique d’une extraction réelle ;
- conservation stricte de la politique `overwrite` : un fichier existant reste
  une erreur sans autorisation, tandis qu’un répertoire explicite déjà présent
  est compté comme conservé ;
- vérification réelle des payloads ZIP sélectionnés vers un consommateur nul,
  avec contrôle de décompression et CRC, et seconde passe TAR intégrale sans
  transmission des données au système de fichiers ;
- maintien de la sélection vide comme opération inerte qui n’inspecte ni ne
  crée la destination, tandis qu’une archive vide non filtrée prévisualise la
  création éventuelle de sa racine ;
- ajout de tests ZIP/TAR et TAR compressés pour destination absente ou existante,
  overwrite actif ou non, filtres, limites, doublons, corruption, symlinks,
  conflits fichier/répertoire, workers et absence totale de mutation ;
- documentation explicite du caractère instantané de la prévisualisation :
  `dry_run` ne constitue pas une garantie contre les changements concurrents
  avant une extraction ultérieure.

### Audit final de publication

- audit de l’implémentation C++, de l’enregistrement Lua, de la validation
  stricte des options, des workers, des tests, des README, de l’aide en ligne,
  des scripts de build/test/release, des licences et des documentations
  française et anglaise contre le code et les tests réels ;
- confirmation que `archive.list()`, `archive.test()`, `archive.extract()` et
  `archive.extractFile()` n’exposent que leurs options et champs de retour
  documentés, `dry_run`, `include` et `exclude` restant réservés à l’extraction
  complète ;
- ajout des notes de publication dédiées `GITHUB_RELEASE_2.8.0.md` et
  finalisation de la checklist de release ;
- régénération des deux manuels PDF depuis les sources Markdown finales et
  contrôle visuel des rendus ;
- conservation des derniers résultats runtime validés : 3067 PASS / 0 FAIL en
  mode dossier, 3054 PASS / 0 FAIL en mode embarqué, 3054 PASS / 0 FAIL via
  `PATH`, et 9/9 modes sous ASan/UBSan comme avec le build normal.

## [2.7.0] - 2026-07-16

### Résumé de la version

Babet 2.7.0 ajoute une API sécurisée dédiée aux flux compressés autonomes et
étend la création d’archives aux sources explicites multi-racines ainsi qu’aux
filtres bornés d’inclusion/exclusion, tout en conservant les contrats ZIP et TAR
audités de la série 2.6.

- passage de la version source à 2.7.0 ;
- ajout de `babet.compression.compress(source, destination, format [, opts])` ;
- ajout de `babet.compression.decompress(source, destination [, opts])` ;
- prise en charge des flux autonomes gzip, xz, bzip2 et zstd ;
- détection du format de décompression par signature plutôt que par extension ;
- acceptation des membres/flux/frames concaténés valides et refus des octets
  arbitraires ajoutés en fin de flux ;
- vérification des informations d’intégrité et refus des flux corrompus ou
  tronqués ;
- traitement en streaming avec buffers bornés de 64 Kio, sans charger les
  fichiers complets dans Lua ;
- ajout de `max_output_size` pour la décompression (1 Gio par défaut, plafond
  dur de 64 Gio) ;
- épinglage des descripteurs source, refus des symlinks source/destination et
  des composants parents symlinkés, détection des destinations sur le même
  inode et revérification de la taille/des timestamps avant publication ;
- staging dans le dossier destination et publication atomique, avec
  `overwrite = false` par défaut ;
- enregistrement du module dans l’état Lua principal et les workers ;
- ajout de validations strictes et de tests binaires, fichiers vides, limites,
  corruption, données finales, symlinks, liens physiques, workers et nettoyage ;
- ajout de la documentation complète française et anglaise du module ;
- ajout de l’option stricte `level` avec des plages et valeurs par défaut
  stables : gzip 0-9 (défaut 6), xz 0-9 (défaut 6), bzip2 1-9 (défaut 9) et
  zstd 1-22 (défaut 3) ;
- refus des flottants, chaînes numériques et niveaux hors limites avant
  l’ouverture de la source, avec diagnostics propres au format et tests de
  régression ;
- extension de `babet.archive.create()` afin que son premier argument puisse
  être une table dense non vide de fichiers réguliers et répertoires explicites,
  tout en conservant le contrat historique à répertoire unique sous forme de
  chaîne ;
- placement de chaque source explicite sous son dernier composant, acceptation
  des chemins absolus sans exposer les préfixes hôte, conservation du préfixe
  des répertoires lorsque leurs entrées sont omises, et ajout de
  `result.sources` ;
- refus des listes vides, trouées ou hétérogènes, de `..`, des racines sans nom
  stable, des symlinks source ou parents, des objets non pris en charge, des
  doublons/collisions de noms racine et des destinations situées dans une
  source sélectionnée ;
- épinglage d’un descripteur racine par source, application globale des limites
  d’entrées/taille/nœuds/profondeur, tri indépendant de l’ordre de la liste et
  prise en charge identique de ZIP, TAR brut/compressé, workers, publication
  atomique et sortie déterministe ;
- ajout des tableaux denses stricts `include` et `exclude` à
  `archive.create()`, comparés de manière sensible à la casse aux chemins finaux
  de l’archive avec le moteur de glob sûr borné existant ; les exclusions
  gagnent toujours et les dossiers exclus sont élagués avant ouverture ;
- conservation des dossiers parents nécessaires aux correspondances profondes,
  prise en charge des dossiers vides sélectionnés et des archives vides valides,
  application cohérente aux sources historiques et listes explicites, et
  ignorance des objets spéciaux non sélectionnés tout en continuant à les
  refuser lorsqu’ils sont retenus ;
- bornage du filtrage à 4096 octets par motif, 256 motifs cumulés, 256 Kio de
  texte total, un million d’évaluations de motifs et un budget fixe de
  100 000 000 cellules, avec validation stricte
  des tableaux/chaînes/NUL/échappements, tests workers, parité ZIP/TAR, ordre
  déterministe et documentation française/anglaise synchronisée ;
- achèvement de l’audit final fonction par fonction des bindings C++ modifiés,
  tests Lua, exemples, documentations française/anglaise, notes de sécurité,
  procédure de publication et manuels PDF générés.

Validation fonctionnelle finale de cette version :

- 2844 PASS / 0 FAIL en mode dossier ;
- 2831 PASS / 0 FAIL en mode embarqué ;
- 2831 PASS / 0 FAIL en mode embarqué via `PATH` ;
- 9/9 modes validés sous ASan + UBSan ;
- 9/9 modes validés de nouveau avec le build normal final.

La barrière de publication exécute en plus les tests TLS locaux et les smoke
tests réseau via `./run_tests.sh --release` avant la création du tag.

## [2.6.1] - 2026-07-16

### Version de maintenance

- passage de la version patch à 2.6.1 ;
- régénération et republication des manuels PDF français et anglais afin que la
  documentation générée corresponde aux sources documentaires de la 2.6.0 ;
- aucune modification du runtime ni de l’API publique.

## [2.6.0] - 2026-07-16

### Résumé de la version

Babet 2.6.0 ajoute la prise en charge sécurisée des TAR multi-formats, des
filtres de noms bornés et une validation stricte cohérente des bindings Lua,
tout en préservant les contrats ZIP et API audités de la 2.5.0.

- passage de la version source à 2.6.0 ;
- intégration reproductible de libarchive 3.8.8 sous forme statique, à partir
  de la distribution officielle vérifiée par SHA-256 ;
- configuration initialement limitée au cœur de libarchive et aux TAR bruts,
  puis activation de gzip via une zlib statique épinglée, de xz via une
  XZ Utils/liblzma statique épinglée, de bzip2 via une libbz2 statique épinglée
  et de zstd via une libzstd statique épinglée ;
- contrôle au démarrage de la cohérence entre les en-têtes et la bibliothèque
  libarchive liés ;
- ajout de la notice de licence libarchive aux distributions binaires ;
- extension de `babet.archive.list()` avec détection par le contenu des archives
  TAR non compressées, tout en conservant miniz comme backend ZIP inchangé ;
- analyse progressive des métadonnées et données TAR avec libarchive, limites
  sur les entrées, tailles, somme des tailles, mémoire des chemins et détection
  des données tronquées ;
- ajout des champs canoniques `format` et `compression`, des types TAR, cibles
  de liens, métadonnées sparse et valeurs `nil` explicites pour les champs CRC
  et compression propres au ZIP ;
- ajout de l’extraction complète sécurisée des TAR non compressés, tout en
  conservant miniz comme backend d’extraction ZIP inchangé ;
- extraction TAR en deux passes : Babet inspecte l’archive épinglée en entier,
  valide chemins, limites, doublons, conflits et types de destination, puis
  relit le même descripteur et compare chaque en-tête avant préparation ;
- réutilisation pour TAR de la destination confinée par descripteurs, des
  temporaires `0600` dans le dossier final, écritures bornées, publication
  atomique fichier par fichier, nettoyage, workers et permissions sûres ;
- refus volontaire des fichiers TAR sparse, symlinks, hard links, FIFO,
  sockets, périphériques et types non pris en charge avant toute publication ;
- extension de `babet.archive.extractFile()` aux TAR non compressés avec
  sélection par nom brut exact, limites sur l’archive entière, seconde passe
  vérifiée, consommation en flux des données non sélectionnées et réutilisation
  de la destination confinée avec publication atomique ;
- possibilité de sélectionner un fichier régulier TAR sûr malgré des entrées
  non liées aux chemins dangereux, types spéciaux ou cartes sparse, tout en
  refusant un sparse sélectionné et toute donnée malformée dans l’archive ;
- extension de `babet.archive.create()` à la création déterministe de TAR non
  compressés avec le writer POSIX pax restreint de libarchive, tout en gardant
  miniz comme writer ZIP inchangé ;
- déduction du format TAR depuis `.tar`, ajout de l’option stricte
  `format = "zip" | "tar"`, conservation du ZIP comme repli compatible pour les
  autres extensions et, à ce stade, refus explicite des suffixes TAR compressés ;
- lecture en flux des fichiers source depuis des descripteurs épinglés, contrôle
  de l’inode, taille, mtime et ctime avant et après lecture, prise en charge des
  chemins pax longs, répertoires vides, workers, publication atomique de
  l’archive entière et métadonnées UID/GID/mode/date déterministes ;
- durcissement de `build_local.sh` par une empreinte du contenu de `src/` et
  de `CMakeLists.txt` ; lorsque des sources copiées depuis un ZIP conservent des
  dates anciennes trompeuses, Babet nettoie désormais uniquement ses propres
  objets CMake au lieu de réutiliser silencieusement un ancien code ;
- intégration statique reproductible de zlib 1.3.2, vérifiée par SHA-256,
  avec activation du seul filtre gzip interne de libarchive ;
- extension de `list()`, `extract()` et `extractFile()` aux TAR gzip détectés
  par le contenu, avec contrôle CRC/troncature du flux complet et les mêmes
  garanties de source épinglée, double passe, publication atomique, workers et
  refus des types spéciaux ;
- extension de `create()` avec déduction `.tar.gz`/`.tgz`, option stricte
  `format = "tar.gz"`, niveaux `0` à `9`, date gzip nulle en mode déterministe
  et sortie reproductible octet par octet ;
- application de `max_compression_ratio` aux TAR gzip sous forme d’un rapport
  global entre les octets annoncés des fichiers réguliers et la taille complète
  de l’archive compressée ;
- ajout d’un profil de build libarchive afin qu’un cache compilé sans les
  filtres gzip, xz, bzip2 ou zstd demandés soit automatiquement reconstruit lorsque la
  configuration des dépendances change ;
- intégration statique reproductible de XZ Utils/liblzma 5.8.3, vérifiée par
  SHA-256, avec utilisation forcée des en-têtes et de `liblzma.a` compilés
  localement plutôt que des versions de la distribution hôte ;
- extension de `list()`, `extract()` et `extractFile()` aux TAR xz détectés par
  le contenu, avec les mêmes garanties de validation du flux complet, source
  épinglée, double passe, publication atomique, workers et refus des types
  spéciaux ;
- extension de `create()` avec déduction `.tar.xz`/`.txz`, option stricte
  `format = "tar.xz"`, niveaux `0` à `9`, sortie déterministe et métadonnées de
  résultat explicites `format = "tar"` / `compression = "xz"` ;
- généralisation de `max_compression_ratio` aux TAR gzip, xz, bzip2 et zstd ;
- contrôle au démarrage de la cohérence entre les versions liblzma des
  en-têtes et de la bibliothèque liée, sur le même principe que zlib ;
- intégration statique reproductible de bzip2/libbz2 1.0.8 depuis la
  distribution officielle Sourceware, vérifiée par SHA-256, avec utilisation
  forcée de `bzlib.h` et `libbz2.a` compilés localement ;
- activation du seul filtre bzip2 interne de libarchive et extension de
  `list()`, `extract()` et `extractFile()` aux TAR bzip2 détectés par le contenu,
  avec les mêmes garanties de source épinglée, double passe, publication
  atomique, workers, détection des corruptions, limite de ratio et refus des
  types spéciaux que gzip et xz ;
- extension de `create()` avec déduction `.tar.bz2`/`.tbz2`/`.tbz`, option
  stricte `format = "tar.bz2"`, niveaux `1` à `9`, sortie déterministe et
  métadonnées `format = "tar"` / `compression = "bzip2"` ;
- contrôle au démarrage que la version libbz2 liée commence bien par la version
  1.0.8 épinglée et injectée par CMake ;
- intégration statique reproductible de Zstandard/libzstd 1.5.7, vérifiée par
  SHA-256, avec utilisation forcée des en-têtes et de `libzstd.a` compilés
  localement dans libarchive comme dans Babet ;
- activation du seul filtre zstd interne de libarchive et extension de
  `list()`, `extract()` et `extractFile()` aux TAR zstd détectés par le contenu,
  avec validation complète des frames par libzstd, prise en charge des frames
  concaténées, refus des corruptions et données finales étrangères, limite de
  ratio globale, source épinglée, double passe, publication atomique et workers ;
- extension de `create()` avec déduction `.tar.zst`/`.tar.zstd`/`.tzst`, option
  stricte `format = "tar.zst"`, niveaux `0` à `19`, sortie déterministe et
  métadonnées `format = "tar"` / `compression = "zstd"` ;
- contournement du problème de callback d’écriture personnalisé de libarchive
  3.8.8 pour zstd en utilisant son chemin intégré `archive_write_open_fd()`,
  tout en conservant le descripteur temporaire épinglé et la publication
  atomique de l’archive complète par Babet ;
- contrôle au démarrage de l’égalité exacte entre les versions libzstd des
  en-têtes et de la bibliothèque liée ;
- audit de tous les usages de `std::regex`, qui confirme que seul
  `babet.find()` l’utilisait ;
- ajout des filtres bornés `glob`, `iglob`, `path_glob` et `path_iglob` à
  `babet.find()` ;
- implémentation du glob sûr sous forme d’automate dynamique non récursif avec
  `*`, `**`, `?`, échappement par antislash, limite de 4096 octets, correspondance
  ancrée sur la chaîne entière, casse ASCII pour les variantes insensibles et
  absence de backtracking catastrophique ;
- remplacement de la dernière implémentation `std::regex` derrière `name`,
  `iname` et `path` par RE2 2025-11-05 et Abseil 20250814.2 liés statiquement,
  téléchargés et vérifiés par SHA-256 dans `build_local.sh` plutôt que pris sur
  le système hôte ;
- conservation des correspondances complètes de `name`/`iname` et de la
  recherche partielle de `path`, avec documentation des différences de syntaxe
  volontaires de RE2, notamment le refus des références arrière et des
  assertions d’anticipation ou de rétrospection ;
- limitation de chaque motif RE2 à 4096 octets et de chaque expression compilée
  à un budget mémoire de 1 Mio, en mode octets Latin-1 afin que les noms Linux
  non UTF-8 restent filtrables ;
- ajout de prédicats Lua partagés et sans allocation pour l’arité exacte ou
  bornée, les chaînes, nombres, entiers et booléens stricts, le `nil` facultatif
  et les chaînes sans octet NUL ;
- harmonisation des bindings publics autour de ces validateurs, suppression des
  conversions accidentelles nombre vers chaîne, refus des arguments en trop
  lorsque la signature documentée est fixe et conservation des chemins
  d’erreur sans `longjmp` pendant la vie d’objets C++ ;
- renforcement des tests de validation de `find`, des listings et itérateurs,
  copies d’arbres, `exec`, signaux, workers et options d’archives ;
- correction du paquet de release afin d’inclure le README français existant
  (`README.fr.md`) sous son véritable nom ;
- achèvement de l’audit final code/tests/documentation, synchronisation des
  références française et anglaise, correction de l’exemple d’échappement RE2
  et régénération des deux manuels PDF pour la 2.6.0 ;
- ajout de fixtures TAR déterministes en Lua pur pour les préfixes ustar, noms
  longs GNU, chemins pax, liens, fichiers sparse, types spéciaux, chemins
  dangereux, limites,
  corruptions, troncatures, archives concaténées, données finales étrangères,
  sources symlinkées, contenus extraits, permissions, écrasement, attaques par
  symlink de destination, nettoyage, sélection d’un seul fichier, archives
  mixtes et concaténées, politique sparse et workers.

La création, l’inspection et l’extraction ZIP continuent d’utiliser miniz avec
leurs contrats 2.5.0. La création, l’inspection, l’extraction complète et
l’extraction d’un fichier des TAR bruts, gzip, xz, bzip2 ou zstd utilisent
libarchive avec zlib, XZ Utils/liblzma, libbz2 et libzstd statiques. Les flux
compressés autonomes restent une décision ultérieure séparée.

## [2.5.0] - 2026-07-15

### Résumé de la version

Babet 2.5.0 ajoute deux capacités majeures entièrement auditées, tout en
poursuivant le durcissement local commencé avec les séries 2.3 et 2.4 :

- des pipelines de processus synchrones et en streaming, sans shell, avec
  statut par étape, entrées-sorties bornées, nettoyage des groupes de
  processus, rollback du lancement et prise en charge de Lua `<close>` ;
- la création, l'inspection et l'extraction de ZIP sécurisés, avec sortie
  déterministe, traitement progressif, limites anti-bombe, confinement strict
  des chemins, détection des mutations de la source et publication atomique ;
- des opérations de système de fichiers épinglées par descripteur pour
  `setAttributes()`, `touch()` et `--create-exe`, supprimant les dernières
  courses destructrices sur les chemins trouvées pendant la revue finale.

Validation fonctionnelle finale de cette version :

- 2235 PASS / 0 FAIL en mode dossier ;
- 2222 PASS / 0 FAIL en mode embarqué ;
- 2222 PASS / 0 FAIL en mode embarqué via `PATH` ;
- 9/9 modes validés sous ASan + UBSan ;
- 9/9 modes validés de nouveau avec le build normal final.

La barrière de publication exécute en plus les tests TLS locaux et les smoke
tests réseau via `./run_tests.sh --release` avant la création du tag.

### Notes de migration et d'utilisation

- `babet.pipeline()` et `babet.spawnPipeline()` n'invoquent jamais de shell.
  Les commandes et arguments doivent être fournis sous forme de chaînes
  séparées.
- Le code global d'un pipeline est celui de la dernière étape. Il faut consulter
  `all_succeeded`, `failed_index` et `stages` lorsqu'un échec intermédiaire est
  important.
- Avec les API de processus et pipelines en streaming, stdout et stderr doivent
  être drainés pendant l'exécution lorsqu'un volume important est possible.
- `babet.archive.create()` est déterministe par défaut et refuse les symlinks et
  objets spéciaux dans la source. Les archives existantes exposent leurs noms
  comme des octets ZIP ; les nouveaux noms créés doivent être en UTF-8 valide.
- `touch()` refuse désormais un symlink final pendant au lieu de créer sa cible.
- `setAttributes()` exige des integers Lua stricts pour l'UID, le GID et le
  mode ; les chaînes numériques ne sont plus converties.
- Les expressions régulières ECMAScript passées à `babet.find()` ne doivent pas
  provenir directement d'une personne non fiable, car `std::regex` n'impose
  aucune limite de temps d'exécution.


### Durcissement des courses sur le système de fichiers

- `setAttributes()` épingle désormais la cible résolue une seule fois et
  applique `fstat`, `chown`, le `chmod` éventuel et le rollback au même inode,
  empêchant un remplacement du chemin de rediriger une phase privilégiée.
- Correction d’une fuite Lua/C++ liée à `longjmp` en validant le chemin, UID,
  GID et mode avant de construire la chaîne propriétaire du chemin ; ces
  arguments conservent désormais leurs types Lua stricts documentés, sans
  conversion des chaînes numériques.
- Réécriture de `touch()` autour d’un parent épinglé, de `O_PATH` et de la
  création atomique `O_CREAT|O_EXCL` : plus de course entre test d’existence
  et ouverture tronquante, aucun fichier apparu concurremment n’est vidé, et
  les symlinks finaux pendants sont refusés.
- Documentation du risque de backtracking catastrophique pour les motifs
  ECMAScript non fiables transmis à `babet.find`, et correction des exemples
  de mode de `setAttributes()` dans la documentation utilisateur.
- `--create-exe` supprime désormais immédiatement le nom de son ZIP créé par
  `mkstemp`, puis transmet l’inode encore ouvert à miniz et à la fusion via
  `/proc/self/fd` ; l’archive temporaire ne peut plus être remplacée entre sa
  création et sa réouverture. La fusion finale épingle aussi le dossier de
  sortie, emploie un nom temporaire interne court et publie avec `renameat()` :
  le remplacement d’un parent symlinké ne peut plus rediriger le résultat et
  les sorties valides proches de `NAME_MAX` restent utilisables.

### Archives ZIP sécurisées

- Ajout de `babet.archive.create()` pour créer progressivement un ZIP depuis un répertoire, avec ordre et dates déterministes, compression de 0 à 9, entrées répertoire explicites, analyse source bornée, détection des modifications et publication atomique de l’archive complète.
- La création refuse les composants et entrées symlinkés, les types de fichiers non pris en charge, une sortie dans l’arbre source, les parents de destination dangereux, les symlinks cibles et toute mutation inattendue d’un fichier source.
- Ajout de `babet.archive.list()` pour inspecter les métadonnées ZIP, les types
  d’entrées, les tailles, méthodes, CRC, permissions Unix et chemins sans
  extraire.
- Ajout de `babet.archive.extract()` et `babet.archive.extractFile()` avec
  décompression progressive, limites anti-bombe configurables, contrôle CRC,
  fichiers temporaires dans le dossier final et publication atomique fichier
  par fichier.
- Refus des chemins absolus, composants `.`/`..`, backslashes, préfixes de
  lecteur, doublons, conflits fichier/répertoire, symlinks ZIP, entrées
  chiffrées et types spéciaux.
- Parcours sécurisé de la destination par descripteurs avec `openat`,
  `fstatat`, `O_NOFOLLOW` et `AT_SYMLINK_NOFOLLOW`, y compris pour les parents
  et cibles déjà présents.
- Ajout de limites sur le nombre d’entrées, la taille par entrée, la taille
  totale, le rapport de compression et la mémoire cumulée des noms, ainsi que
  d’un plafond de 128 Mio sur les allocations internes du lecteur miniz, et de
  bornes fixes sur l’arbre de répertoires implicites produit par l’extraction.
- Mise à jour de miniz 3.1.1 vers 3.1.2 afin d’intégrer les correctifs amont de
  lecture du répertoire central et de décompression avant d’exposer l’analyse
  d’archives non fiables.
- Ajout de tests déterministes construisant les fixtures ZIP en Lua pur :
  données binaires, DEFLATE, permissions, corruption CRC, écrasement,
  nettoyage, traversées, symlinks, doublons, limites et arguments stricts.
- Audit final P2-C : ouverture unique des archives via un descripteur de fichier
  régulier afin de refuser les FIFO sans blocage, validation UTF-8 des noms
  produits par `create()`, contrôle explicite de la plage de dates ZIP 1980-2107
  en mode non déterministe et noms temporaires indépendants du basename final
  pour prendre en charge les sorties proches de `NAME_MAX`.

### Pipelines de processus

- Ajout de `babet.pipeline()` pour les pipelines synchrones sans shell, avec
  pipes directs entre étapes, stdin binaire, capture du stdout final, stderr
  séparé par étape, capture bornée, timeout global et statuts individuels.
- Ajout de `babet.spawnPipeline()` pour piloter progressivement le premier
  stdin, le stdout final et chaque stderr séparé.
- Ajout des méthodes `read_stdout`, `read_stderr` indexé, `write` partiel,
  `close_stdin` idempotent, `is_running`, `pids`, `wait`, `terminate`, `kill` et
  `close`, avec nettoyage par `__gc` et Lua `<close>`.
- Le code global reste celui de la dernière étape ; `all_succeeded`,
  `failed_index` et `stages` conservent les échecs et signaux intermédiaires.
- Chaque étape possède son propre groupe de processus. Les échecs de lancement,
  timeouts, arrêts explicites, fermetures et nettoyages GC arrêtent les étapes
  déjà créées et leurs descendants restés dans ces groupes. Lors d'une fin
  normale, les descendants laissés en arrière-plan sont également supprimés
  avant la récupération du leader, sans risque de cibler un PID recyclé.
- Mutualisation des pipelines synchrones et streaming sur un lanceur
  multi-processus commun dans `process_common`, avec validation avant `fork` et
  rollback borné d'un lancement partiel.
- Ajout de tests déterministes pour les E/S binaires et partielles, les gros
  volumes stdin/stdout/stderr, SIGPIPE, les échecs intermédiaires, les erreurs de
  lancement, les timeouts, l'idempotence, les groupes, le GC et Lua `<close>`.
- Audit final P1-C : validation stricte des deux API et de toutes les méthodes,
  test des timeouts pendant `chdir`/`exec`, rollback d'un lancement partiel et
  de ses descendants, nettoyage d'un enfant en arrière-plan après une fin
  normale, protection lorsque les descripteurs standards 0/1/2 sont fermés,
  contrôle croisé code/tests/documentations FR-EN/exemples/manuels PDF.

## [2.4.0] - 2026-07-14

### Résumé de la release

Babet 2.4.0 supprime trois limites pratiques de la série 2.3 sans affaiblir les
garanties de sécurité établies par l’audit précédent :

- les programmes externes peuvent désormais être pilotés progressivement avec
  `babet.spawn`, sans conserver tout stdin, stdout ou stderr en mémoire ;
- les réponses HTTP et HTTPS peuvent être téléchargées directement vers un
  fichier avec une destination bornée, atomique et protégée contre les symlinks ;
- SQLite dispose maintenant de statements préparés réutilisables, de BLOB
  explicites et de transactions assistées avec rollback automatique sur erreur
  Lua.

Les contrats existants de `babet.exec`, `babet.http.request`, `db:exec` et
`db:query` restent disponibles. Les nouvelles API sont additives ; le moteur de
processus partagé et les smoke tests de release ont néanmoins été refactorisés
puis entièrement revalidés.

Validation finale de cette version :

- 1810 PASS / 0 FAIL en mode dossier ;
- 1797 PASS / 0 FAIL en mode embarqué ;
- 1797 PASS / 0 FAIL en mode embarqué via le `PATH` ;
- 9/9 modes d’exécution validés sous ASan + UBSan ;
- 9/9 modes de nouveau validés avec le build normal final ;
- smoke tests réseau : 6 contrôles bloquants réussis, 0 échec et 2 sondes
  publiques en avertissement informatif.

### Notes de mise à niveau et d’utilisation

Babet 2.4.0 est principalement additif, mais les règles suivantes sont
importantes lors de l’adoption des nouvelles API :

- `process:wait()` ne draine ni stdout ni stderr. Un enfant produisant beaucoup
  de sortie peut se bloquer tant que les deux flux ne sont pas lus ; les scripts
  longs doivent donc les drainer pendant l’exécution.
- `process:write()` peut n’écrire qu’une partie de la chaîne fournie. Il faut
  reprendre à partir du nombre d’octets renvoyé ou appliquer le motif write-all
  documenté.
- `babet.http.download()` ne valide la destination qu’après une réponse finale
  2xx complète. Un statut non-2xx renvoie des métadonnées avec `saved=false` ;
  une erreur transport, TLS, timeout, taille ou disque renvoie `(nil, err)` et
  préserve une destination existante.
- Les destinations de téléchargement refusent `..` et les composants de dossier
  parents symlinkés. Un symlink exactement à la destination finale est remplacé
  comme inode ; sa cible n’est pas modifiée.
- `db:transaction()` committe tout retour normal du callback, y compris `nil` et
  `false`. Il faut utiliser `assert` ou lever explicitement une erreur lorsqu’une
  opération renvoyant `(nil, err)` doit provoquer un rollback.
- Une seule itération de requête préparée peut être active par statement. Un
  reset ou une nouvelle exécution invalide l’itération précédente.
- Les chaînes Lua ordinaires restent bindées comme SQLite TEXT. Utiliser
  `babet.sqlite.blob(data)` lorsque la classe de stockage doit être BLOB.

### Statements SQLite, BLOB explicites et transactions

- Ajout de `db:prepare(sql)` pour créer un statement mono-instruction
  réutilisable avec `exec`, `query` appelable, `reset`, `close` et `finalize`.
- Les statements préparés sont automatiquement réinitialisés et débarrassés de
  leurs bindings entre deux exécutions ; une itération interrompue peut être
  réinitialisée explicitement ou remplacée par l'exécution suivante.
- Ajout de `babet.sqlite.blob(data)` pour binder une chaîne Lua binary-safe avec
  la classe de stockage SQLite BLOB, sans modifier le bind TEXT historique des
  chaînes ordinaires.
- Ajout de `db:transaction(callback [, mode])` avec les modes deferred,
  immediate et exclusive, rollback automatique sur erreur Lua du callback et
  restitution de ses valeurs après un booléen de succès.
- Ajout de `db:in_transaction()` et de protections contre les helpers imbriqués,
  leur utilisation dans une transaction manuelle existante et la fermeture de
  la connexion depuis le callback.
- Conservation du cycle de vie `sqlite3_close_v2` : un statement préparé avant
  `db:close()` reste utilisable jusqu'à sa finalisation.
- Ajout de 66 contrôles de non-régression couvrant réutilisation, rebinding,
  reset après break, erreurs de step, classes BLOB/TEXT, modes de transaction,
  rollback, erreurs du callback, imbrication, transaction manuelle et handles
  fermés.

### Téléchargements HTTP vers fichier

- Ajout de `babet.http.download(url, destination [, opts])` pour télécharger une
  réponse GET directement sur disque sans garder le corps complet en mémoire.
- Ajout de `max_file_size`, limité par défaut à 8 Gio et exigeant un entier Lua
  strictement positif ; la limite porte sur les octets réellement livrés par le
  client HTTP.
- Le téléchargement passe par un temporaire exclusif dans le même dossier et ne
  remplace atomiquement le chemin final qu'après une réponse finale 2xx complète.
- Une destination existante est préservée après erreur DNS, TCP, TLS, timeout,
  taille, écriture disque, statut non-2xx ou redirection non suivie ; tout
  temporaire inachevé est supprimé.
- Durcissement du chemin : le parent doit exister, `..` et les composants parents
  symlinkés sont refusés, tandis qu'un symlink exactement à la destination est
  remplacé sans modifier sa cible.
- Ajout d'un résultat compact (`status`, `saved`, `bytes`, `path`, `headers`,
  `headers_multi`) sans champ `body` en mémoire.
- Ajout de tests locaux déterministes pour fichiers binaires et vides,
  remplacement, redirections, erreurs HTTP, limite de taille, erreurs de
  transport et protections contre les symlinks, ainsi qu'un smoke test bloquant
  de téléchargement HTTPS local.

### Processus en streaming

- Ajout de `babet.spawn(command [, args] [, opts])`, qui renvoie un userdata
  processus avec des pipes stdin, stdout et stderr non bloquants.
- Ajout des lectures progressives `read_stdout`/`read_stderr` et de l'écriture
  partielle `write`, binary-safe, avec les résultats typés `timeout`, `closed`
  et `interrupted`.
- Ajout de `wait` borné, `terminate`/`kill` sur le groupe de processus,
  `close` idempotent, nettoyage automatique par le ramasse-miettes, PID et
  vérification non bloquante de l'état.
- Ajout de `launch_timeout`, qui borne la phase `chdir` + `exec`.
- Refactorisation de `babet.exec` et `babet.spawn` autour du même moteur de
  lancement durci : pipes CLOEXEC, environnement construit dans le parent,
  groupe de processus, diagnostic de lancement et nettoyage borné.
- Ajout de tests de non-régression pour stdin binaire, gros flux stdout/stderr
  séparés, timeouts, environnement/cwd, cycle de vie et validations.

## [2.3.0] - 2026-07-14

### Résumé de la version

Babet 2.3.0 est un audit complet du code, des tests et de la documentation, et
non une petite version fonctionnelle. Chaque module public a été comparé à son
implémentation C++ ou Lua, aux modes dossier et embarqué, ainsi qu’aux manuels
français et anglais.

Cette version apporte ou finalise notamment :

- une documentation bilingue exhaustive avec sommaire interne sur chaque page ;
- le durcissement du système de fichiers et de la création d’exécutables ;
- des contrats d’arguments Lua plus stricts et plus prévisibles ;
- des opérations bornées pour les processus, sockets, TLS, HTTP, inotify et
  workers ;
- une couverture de non-régression considérablement étendue ;
- une validation pré-release en une commande avec ASan, UBSan, reconstruction
  normale et smoke tests réseau.

Validation finale de cette version :

- 1637 PASS / 0 FAIL en mode dossier ;
- 1624 PASS / 0 FAIL en mode embarqué ;
- 1624 PASS / 0 FAIL en mode embarqué via le `PATH` ;
- 9/9 modes validés sous ASan + UBSan ;
- 9/9 modes de nouveau validés avec le build normal final ;
- smoke tests réseau : 4 contrôles bloquants validés, 0 échec et 2 sondes
  externes en avertissement informatif.

### Migration et contrats désormais plus stricts

Ces changements peuvent révéler des erreurs dans les scripts qui reposaient sur
des conversions implicites ou des arguments ignorés :

- Les fonctions publiques auditées refusent désormais les arguments
  supplémentaires non documentés au lieu de les ignorer silencieusement.
- Les API documentées avec des chaînes exigent en général de vraies chaînes Lua.
  Les conversions implicites nombre vers chaîne ne sont plus acceptées par
  `json.decode`, `split`, les parseurs de temps, les arguments de processus,
  les comptes système, les hôtes socket/TLS et les points d’entrée similaires.
- Les options numériques exigent désormais de vrais nombres ou entiers Lua
  finis. Les chaînes numériques, NaN, infinis, flottants à la place d’entiers et
  valeurs hors limites sont refusés lorsque le contrat le prévoit.
- `babet.sleep` conserve bien les unités `s`, `ms`, `us` et `ns`. Seules les
  formes implicites telles que `babet.sleep("1", "ms")` ou une unité numérique
  sont refusées.
- La suppression est explicite : `remove` supprime un fichier régulier ou un
  symlink, `rmdir` un vrai dossier vide, et `rmdirAll` un vrai dossier de façon
  récursive.
- Après le premier `workers.spawn`, `chdir` et les modifications de
  l’environnement du processus sont refusés afin d’éviter les races entre
  threads.
- Argparse refuse désormais les déclarations ambiguës : `-h`/`--help` réservés,
  noms ou destinations en doublon, `choices` troué, tableau de tokens invalide,
  ou positionnel requis après un positionnel optionnel.
- `logging.set_output` exige une méthode `write` appelable et
  `logging.set_level` refuse les seuils numériques non finis.
- `inotify.add(..., { onlydir = ... })` exige un booléen strict ; la chaîne
  `"false"` n’est plus considérée comme vraie.
- Les clés de tables JSON hors des formes tableau/objet documentées sont
  refusées, notamment zéro, flottants, booléens et formes mixtes invalides.
- `toml.decode`, JSON, Time, Inotify, Logging, Tables et Strings appliquent
  maintenant leur arité documentée.
- `babet.time.iso` arrondit les timestamps négatifs fractionnaires vers la
  seconde précédente, ce qui rend le formatage avant l’époque cohérent.

### Runtime et création d’exécutables

- Publication atomique de `babet --create-exe` : un ancien exécutable reste
  intact si la génération échoue.
- Refus d’écraser le binaire en cours d’exécution, y compris via un symlink
  équivalent.
- Exclusion de l’exécutable de sortie de son propre ZIP, pour des reconstructions
  stables.
- Exclusion récursive des métadonnées `.git`, `.svn` et `.hg`.
- Limite de taille par fichier embarqué avec diagnostic clair.
- Durcissement de l’analyse du ZIP ajouté au binaire : bornes, offsets et
  archives malformées.
- Agrandissement dynamique du buffer de `/proc/self/exe` au lieu de tronquer les
  chemins longs.
- En mode fichier, `require` trouve les modules voisins, `arg` est cohérent et
  les scripts `#!babet` sans extension `.lua` sont acceptés.
- Erreurs claires pour chemin absent, dossier sans `main.lua` et `main.lua` qui
  est lui-même un dossier.
- Diagnostics utiles pour les erreurs Lua non textuelles, en mode normal comme
  embarqué.

### Système de fichiers, chemins, attributs et sommes de contrôle

- Rejet cohérent des octets NUL dans les chemins, modes, champs
  d’environnement, options regex et chaînes associées.
- Durcissement de `copyTree` et `moveTree` contre les destinations redirigées
  par symlink, les destinations internes à la source, les racines source
  symlinkées et les collisions pouvant écrire hors de l’arbre demandé.
- Ajout de helpers de destination sécurisée et préparation orientée rollback.
- Conservation et réécriture des liens absolus internes lors des copies ou
  déplacements, tout en préservant les liens externes et cassés.
- Amélioration de `moveTree` entre systèmes de fichiers et conservation de la
  source en cas d’échec ou de collision.
- Suppression des bits setuid, setgid et sticky sur les fichiers copiés, tout en
  conservant les permissions ordinaires.
- Le mode continuation de `copyTree` remonte désormais les avertissements au
  lieu d’ignorer silencieusement les entrées non supportées ou illisibles.
- Distinction stricte de `remove`, `rmdir` et `rmdirAll`, y compris pour
  symlinks, FIFO et liens cassés.
- Durcissement de `find` : profondeurs, types, durée de vie des regex, erreurs de
  parcours, pruning et appels concurrents.
- Nettoyage et remontée d’erreurs renforcés pour `FileIterator`.
- Les checksums refusent les fichiers non réguliers et ne renvoient jamais un
  faux digest après une erreur de lecture ; les symlinks vers un fichier
  régulier restent acceptés.
- Rollback de `setAttributes` lorsqu’une modification partielle a réussi avant
  une erreur ultérieure.

### Processus externes (`exec`)

- Validation stricte de la commande, des arguments, options, environnement,
  cwd, stdin, timeout et limite de sortie.
- Entrées/sorties binaires robustes pour les gros volumes, les fermetures
  précoces de pipes et `EPIPE`.
- Timeout couvrant toute la séquence, y compris la préparation enfant, `chdir`
  et `exec`.
- Arrêt et récupération de tout le groupe de processus lors d’un timeout afin
  qu’un petit-enfant ne maintienne pas les pipes ouverts.
- Conservation de la sortie produite avant timeout et indicateurs de troncature
  avec `max_output`.
- Code de sortie normalisé à `128 + signal` lors d’une terminaison par signal.
- Nettoyage renforcé après erreur de `poll` et test d’injection déterministe
  dans le build normal.
- Préparation des arguments et de l’environnement avant `fork` pour réduire le
  travail non sûr dans l’enfant d’un processus multithread.

### Signaux et workers

- Ensemble POSIX supporté, noms stricts, modification depuis le thread principal
  uniquement, ordre fixe de dispatch, callbacks sans argument et livraison
  différée documentés et testés.
- Préservation des handlers lors de plusieurs `exec` concurrents et suppression
  des races globales autour de `SIGPIPE`.
- Durcissement de la pile et des limites de profondeur pendant la
  sérialisation/désérialisation des workers.
- Meilleurs diagnostics pour les erreurs worker non textuelles et les
  exceptions internes.
- Arguments de spawn et messages limités aux formes JSON denses documentées.
- Capacités inbox/outbox bornées et validation stricte des timeouts.
- Contrat clarifié pour `poll`, le résultat consommable de `join`, la fermeture,
  le drainage et les états `closed`/`full`/`timeout`.
- Transmission explicite de messages `nil`, tout en refusant les valeurs Lua
  non supportées.
- Verrouillage définitif du cwd et de l’environnement après le premier worker.
- Tests étendus sur le parallélisme réel, les workers indépendants, les files,
  la fermeture, les délais et les chemins d’erreur.

### Sockets TCP

- Validation stricte des hôtes, ports, backlog, délais, tailles et compteurs.
- Timeouts par appel pour `accept`, `recv`, `recv_line` et `recv_all`, prioritaires
  sur le délai par défaut du socket.
- Limite de 16 Mio pour `recv` et limite configurable et bornée pour `recv_all`.
- Conservation des octets tamponnés après timeout de `recv_line` et lors d’un
  appel ultérieur à `recv` ou `recv_all`.
- Les erreurs de timeout ou de taille de `recv_all` sont récupérables sans
  exposer de corps partiel.
- Résultats typés homogènes : `timeout`, `closed` et `interrupted`.
- Connexion bloquante interruptible par les signaux Babet et connexion vers un
  backlog saturé correctement bornée.
- Opérations sur socket fermé ou d’écoute durcies et `close` idempotent.

### TLS

- Connexion TLS directe et STARTTLS sur un socket TCP existant.
- Vérification de la chaîne et du nom d’hôte activée par défaut, avec recherche
  du trust store système.
- SNI indépendant de la vérification, y compris pour les connexions de test en
  `verify=false`.
- Isolation de `ca_cert`/`ca_path` dans un `SSL_CTX` privé par connexion : une CA
  personnalisée ne fuit plus vers les connexions suivantes et ne crée plus de
  race entre workers.
- TLS 1.2 minimum par défaut et option pour exiger au moins TLS 1.3.
- Deadline globale du handshake et délais pour les entrées/sorties TLS.
- Refus de STARTTLS si du plaintext reste tamponné, sans perdre ces octets.
- Échec STARTTLS fail-closed après le début du handshake ; les erreurs de
  validation antérieures laissent le TCP utilisable.
- Validation stricte des hôtes, ports, options de vérification, CA, hostname,
  version, timeout et octets NUL.

### HTTP

- Alignement complet des URL, méthodes, headers, query, corps, TLS,
  redirections, timeout et limites avec l’implémentation.
- Validation stricte de l’autorité et du host, rejet CR/LF, noms de headers
  validés et query limitée aux scalaires.
- Normalisation de la query, encodage UTF-8, fusion avec une query existante et
  suppression du fragment documentés et testés.
- Corps de requête et réponses binaires.
- `headers_multi` pour les headers répétés, avec conservation du mapping simple
  `headers`.
- `max_body_size` borné et rejet d’une réponse trop grande sans corps partiel.
- Timeout global couvrant connexion, TLS, envoi et réception.
- Contrat clarifié pour redirections, casse des méthodes, HEAD et surcharge des
  différentes formes de POST.

### SQLite

- Suppression de la documentation d’une API inexistante
  `prepare`/`step`/`finalize`, remplacée par le vrai contrat
  `open`/`exec`/`query` et itérateur.
- Distinction entre `exec(sql)` multi-instructions et la forme paramétrée limitée
  à une instruction.
- Correction du SQL vide ou composé seulement de commentaires avec paramètres :
  aucun statement SQLite nul n’est désormais déréférencé.
- Les chaînes Lua sont bindées comme TEXT ; les BLOB lus depuis SQLite restent
  des chaînes Lua binaires.
- Documentation des binds positionnels/nommés, placeholders, colonnes en
  doublon, `NULL`, TEXT/BLOB vides, DML paresseux et durée de vie d’un itérateur
  après `db:close`.
- Options strictes, rejet des NUL SQL, busy timeout borné, nettoyage des
  itérateurs et erreurs sur `step` couverts par les tests.

### JSON

- `json.decode` exige une vraie chaîne Lua et `json.encode` applique son arité.
- Correction des tables ne contenant que des clés invalides : elles échouent au
  lieu d’être encodées en `{}`.
- Documentation exacte des formes tableau/objet, du `nil` racine, de
  `json.null`, des tableaux vides, doublons, UTF-8, NUL binaires, grands entiers,
  cycles, indentation et profondeur.
- `as_array` remplace la métatable ; un ancien tableau décodé non vide puis vidé
  doit être marqué de nouveau pour redevenir `[]`.

### TOML

- `toml.decode` exige exactement une vraie chaîne Lua.
- Conservation des clés TOML citées contenant `\u0000` grâce à une insertion
  Lua tenant compte de la longueur au lieu d’une API de chaîne C.
- Documentation des entiers signés 64 bits, bases, infinis, NaN, Unicode, clés
  citées, dotted keys, arrays hétérogènes, dates/heures, conteneurs vides et
  informations perdues lors de la conversion Lua.

### Inotify

- Arités strictes pour le watcher et ses méthodes.
- `opts.onlydir` exige un booléen strict.
- Documentation des watches fichier/dossier, du remplacement de masque, des
  lectures par lots, événements `ignored`, `unmount`, overflow, interruption par
  signal, watches multiples et instances multiples.
- Correction d’une fuite détectée par LeakSanitizer : un longjmp Lua évitait le
  destructeur d’une `std::string` vivante dans un chemin d’erreur d’argument.

### Temps et sommeil

- Suppression des conversions implicites chaîne/nombre dans Sleep, ISO et les
  durées.
- Conservation inchangée des unités `s`, `ms`, `us` et `ns`.
- Arrondi cohérent vers le bas des timestamps négatifs fractionnaires.
- Documentation des horloges temps réel/monotone, de la grammaire ISO exacte,
  des offsets, années avant/après l’époque, durées non normalisées, forme
  canonique et contrats d’erreur.

### Argparse

- Métadonnée renommée de LuaPilot vers Babet et version du module portée à
  1.1.0.
- Arités strictes et validation complète des champs d’options.
- Rejet des noms/destinations réservés, malformés, dupliqués ou ambigus.
- Construction atomique : une erreur interceptée avec `pcall` ne laisse aucune
  option ni aucun alias partiellement enregistré.
- Ordre strict des positionnels et tableau explicite de tokens dense.
- Conservation des comportements utiles : valeurs inline, valeurs négatives,
  options répétées (dernière valeur gagnante), tokens ressemblant à des options
  et `--`.
- Clarification : les valeurs par défaut ne passent ni par `choices` ni par
  `convert`.

### Chaînes et tables

- `split` exige de vraies chaînes Lua tout en conservant données binaires, NUL,
  séparateur littéral d’un octet, champs vides et mode par octets.
- Documentation complète de `mergeTables` : ordre, compaction, dernier écrivain
  gagnant, références superficielles, parcours brut et métatables ignorées.
- Documentation complète de `deepCopyTable` : cycles, valeurs partagées, entrées
  brutes, clés tables non copiées, métatables partagées et limite de 75 niveaux.
- Correction d’un cycle se refermant exactement à la profondeur maximale : la
  copie existante est réutilisée avant de refuser une nouvelle table réellement
  plus profonde.

### Logging

- Métadonnée renommée de LuaPilot vers Babet et version du module portée à
  1.1.0.
- Protection de toute la chaîne de log : `tostring`, horodatage et écriture du
  sink ne peuvent plus faire remonter une erreur.
- `set_output` vérifie une méthode `write` appelable, y compris via `__index`.
- Arités strictes et rejet des seuils non finis, tout en conservant les niveaux
  numériques personnalisés finis.
- Documentation des heures locales, messages multilignes/binaires, couleurs,
  état partagé dans un état Lua, isolation des workers et absence de niveau
  `fatal`.

### Documentation et validation

- Réécriture des manuels FR/EN face au code et aux tests pour tous les modules :
  FS, SYS, USER, EXEC, SIGNAL, WORKERS, SOCKET, TLS, HTTP, SQLite, JSON, TOML,
  Inotify, Time, Argparse, Strings, Tables et Logging.
- Index descriptifs et sommaire interne stable sur chaque page de module.
- Régénération des PDF complets avec liens internes fonctionnels.
- Harnais porté à 1637 contrôles en mode dossier et 1624 dans chacun des modes
  embarqués.
- Ajout de `./run_tests.sh --release` : ASan + UBSan, restauration et validation
  du build normal, puis smoke tests réseau sur le binaire final.
- Sondes bloquantes sur le contrat Babet et sondes Google/AUR informatives ;
  `BABET_SMOKE_STRICT_EXTERNAL=1` les rend bloquantes.

### Limites connues conservées

- Babet reste ciblé Linux/glibc ; aucune portabilité macOS/BSD n’est annoncée.
- `exec` utilise encore `execvpe` de glibc ; résoudre complètement le PATH dans
  le parent puis utiliser seulement `execve` reste un hardening supplémentaire
  possible.
- Les channels worker-à-worker et l’arrêt forcé d’un thread ne sont pas fournis :
  les échanges passent par le parent et la fermeture exige la coopération du
  worker.
- Les helpers Lua ZIP/TAR ne font pas encore partie de l’API publique.
- Valgrind est facultatif ; ASan et UBSan sont les validations mémoire et
  comportement indéfini principales de la release.
