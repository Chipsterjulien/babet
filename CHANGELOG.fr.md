# Journal des modifications

Ce fichier décrit les changements notables de Babet.

Le projet suit le versionnage sémantique pour ses publications. Les notes de
migration et d’utilisation sont conservées avec chaque version lorsqu’un
nouveau contrat ou une règle opérationnelle peut affecter les scripts existants.

## [2.15.0] - 2026-08-04

### Résumé

Babet 2.15.0 audite les échecs d'allocation Lua qui utilisent un saut non local
au lieu de dérouler la pile C++. Elle protège l'état RAII possédé par les
bindings pendant l'allocation des résultats Lua, corrige l'annulation d'un
worker bloqué sur une outbox pleine et rend `createFileIterator` réellement
paresseux. Aucun mode de ligne de commande n'est ajouté et le code existant qui
ne lit qu'une valeur de `iterator:next()` reste compatible.

### Sûreté entre `longjmp` Lua et RAII C++

- ajout d'un builder de résultats Lua protégé : les allocations sont exécutées
  sous `lua_pcall`, `LUA_ERRMEM` est transporté par un marqueur C++ sans
  allocation, tous les propriétaires C++ actifs sont détruits, puis l'erreur
  Lua originale est relancée ;
- ajout d'états temporaires possédés par Lua lorsque les propriétaires natifs
  doivent survivre jusqu'à la copie finale des chaînes ou tables ;
- application du modèle audité aux chemins de résultats JSON, TOML, HTTP,
  Archive, Socket, SQLite, Workers, Base64, CRC32, MD5, SHA-1, SHA-2, SHA-3 et
  BLAKE2 ;
- extension du même audit aux 14 enregistrements de processus `spawn` et aux
  15 enregistrements de pipelines synchrones ou streaming, avec allocation
  protégée des userdata et construction protégée des tables de résultats ;
- nettoyage des finalizers processus et pipeline rendu sans allocation, puis
  passage de leurs `__gc` / `__close` par des frontières silencieuses
  `noexcept` ;
- ajout d'un état de construction explicite pour les userdata Socket et Worker,
  afin qu'un échec du placement-new ne puisse jamais faire détruire par `__gc`
  un objet dont la durée de vie n'a pas commencé ;
- passage des finalizers Channel, Worker, état HTTP et FileIterator par des
  frontières silencieuses ; justification écrite du maintien direct de Signal,
  qui ne conserve aucun propriétaire C++ non trivial autour d'une allocation
  Lua ;
- correction du snapshot TOML protégé : le type natif du nœud est désormais
  testé avant `value<T>()`, car toml++ autorise certaines conversions exactes
  comme booléen vers entier ; les booléens simples, clés pointées citées,
  tableaux hétérogènes et sections imbriquées conservent donc leur type Lua ;
- conservation des erreurs de programmation, des retours ordinaires
  `(nil, err)`, des chaînes binaires, tables HTTP, limites d'archives, timeouts
  socket et contrats SQLite ;
- protection des clients, requêtes, réponses et téléchargements HTTP, arbres
  TOML, valeurs JSON, messages workers et itérateurs de fichiers contre un saut
  d'allocation Lua qui contournerait leur nettoyage ;
- achèvement de l'audit sur `exec`, `find`, `listFiles`, `deepCopyTable`, SYS,
  Compression et Inotify : les parcours natifs sont terminés avant la
  construction des tables Lua, la table source est transmise explicitement à
  la frame protégée de `deepCopyTable`, les références du registre sont
  libérées sur tous les chemins et les résultats dynamiques sont émis sous
  `lua_pcall` ;
- correction du runner de parseur protégé afin que tous les arguments Lua
  d'origine soient transmis à sa frame `lua_pcall` sans changer leurs indices ;
  les arguments et options d'`exec`, les filtres de `find`, les options de
  Compression et les segments de `joinPath` restent ainsi fonctionnels tout en
  protégeant leurs propriétaires C++ ;
- protection du parsing des sources/options Archive et de la construction de
  la table passwd de `user.get`, ce qui ferme les derniers chemins OOM de
  parsing/résultat identifiés ;
- passage de tous les anciens enregistrements plats de `main.cpp` par une
  frontière C++ commune, interdiction globale des builders `push_fail()` et
  `push_action_result()` directs dans les bindings, et protection des phases
  d'initialisation des runtimes Lua principal et workers contre un panic OOM ;
- correction de la création des handles de channels workers : stockage brut
  avec drapeau `constructed`, métatable armée avant la construction du
  `shared_ptr`, destruction `noexcept` et transfert de propriété seulement
  après l'achèvement du userdata ;
- extension du préflight structurel à 161 contrats audités et ajout d'un
  auto-test OOM piloté par un véritable allocateur Lua, qui exerce maintenant
  les vrais chemins `exec`, `listFiles` et `deepCopyTable` en plus des
  propriétaires de pile C++ et userdata possédés par Lua ;
- suppression des quinze derniers builders `push_fail()` directs dans Archive
  et Socket, afin que leurs diagnostics soient eux aussi construits sous
  `lua_pcall` tant que des chaînes, vecteurs ou propriétaires RAII sont vivants ;
- documentation de la frontière directe volontaire de `json.as_array`, qui ne
  conserve aucun propriétaire C++ non trivial, et verrouillage des userdata :
  construction de `Sock` exigée `noexcept`, destruction de `Worker` exigée
  `noexcept`, avec initialisation explicite du drapeau `constructed` dans le
  stockage brut retourné par Lua.

### Compilation C++23

- classement du répertoire d’en-têtes `toml++` comme include CMake `SYSTEM` ;
  GCC 16 ne pollue plus les builds avec les avertissements
  `-Wdeprecated-literal-operator` provenant des opérateurs littéraux de la
  dépendance 3.4.0, sans désactiver les avertissements du code Babet.

### Workers

- correction de l'interblocage garanti `cancel()` / `join()` lorsqu'un worker
  attendait indéfiniment dans `worker.send()` sur une outbox pleine ;
- l'annulation réveille maintenant les attentes de l'outbox et renvoie
  `(false, "cancelled")` uniquement si l'envoi aurait dû rester bloqué ;
- conservation du dernier diagnostic documenté : si une place est déjà libre,
  le message entre encore dans l'outbox ouverte, et les messages présents avant
  l'annulation restent drainables par le parent ;
- maintien d'une annulation coopérative, sans `pthread_cancel()` ni interruption
  asynchrone de Lua, SQLite, transactions ou sections critiques C++ ;
- maintien explicite de la frontière de protocole : une commande extraite de
  l'inbox mais pas encore livrée lorsque l'annulation devient visible est
  abandonnée plutôt qu'exécutée après l'annulation ;
- ajout d'une régression déterministe de capacité 1 qui remplit l'outbox, bloque
  un second envoi, annule, rejoint avec délai puis draine le premier message.

### `FileIterator` paresseux

- remplacement du préchargement dans un `std::vector<std::string>` par un
  `directory_iterator` ou `recursive_directory_iterator` natif conservé dans
  le userdata Lua ;
- déplacement du parcours dans `iterator:next()` : la création ne parcourt plus
  tout l'arbre et ne garde plus tous les chemins en mémoire ;
- extension de `next()` avec `(chemin, nil)`, `(nil, err)` ou `(nil, nil)` à la
  fin normale ; les appels qui ne lisent que la première valeur gardent leur
  comportement historique, tandis que le nouveau code distingue une erreur de
  parcours différée de la fin ;
- conservation des règles sur fichiers réguliers et symlinks, arguments
  stricts, fermeture explicite, nettoyage GC et erreur Lua après fermeture.

### Diagnostic du `spawn` interactif

- maintien inchangé du moteur de terminal 2.14.0 : la régression PTY directe et
  une couche `sudo` facultative contrôlée ne reproduisent pas une seconde
  défaillance de groupe de premier plan ;
- affichage du chemin canonique du binaire Babet et de son SHA-256 à chaque test
  PTY, afin de ne pas confondre un runtime copié ou embarqué ancien avec le
  binaire compilé par la campagne de release ;
- conservation du délai anti-blocage et des scénarios de lecture directe,
  timeout, signal, arrêt, rafraîchissement d'état et restauration du terminal ;
- enregistrement du blocage interactif réel yaourt vers pacman comme non
  résolu : la 2.15.0 ne prétend pas corriger cette chaîne sans reproducer rouge
  identifiant le véritable groupe de processus au premier plan.

### Validation et documentation

- intégration de l'auto-test OOM/RAII Lua et du diagnostic PTY étendu dans les
  chemins normal et ASan/UBSan ;
- mise à jour synchronisée des références françaises et anglaises FS, Workers
  et processus, README, procédure de release, feuille de route, notices,
  changelogs, notes GitHub et manuels PDF ;
- plateforme Linux et versions des dépendances vendorisées inchangées.

## [2.14.0] - 2026-08-03

### Résumé

Babet 2.14.0 termine le chantier audité des frontières d’exception C++ pour les
quatre derniers modules de bindings publics et corrige la prise de contrôle du
terminal par les enfants interactifs de `babet.spawn`. Aucune fonction Lua,
option ou contrat de retour ordinaire n’est ajouté ni supprimé.

### Frontières d’exception Lua/C++

- ajout d’un cœur commun de classification distinguant `std::bad_alloc`, une
  autre `std::exception` et une exception C++ inconnue, sans jamais les laisser
  traverser les frames C de Lua, et détruisant l’exception interceptée avant de
  demander à Lua d’empiler le diagnostic ;
- protection des deux fonctions `babet.compression`, en conservant le nettoyage
  RAII des descripteurs source et des sorties temporaires non publiées ;
- protection des six fonctions SYS plates : `which`, `env`, `setenv`,
  `hostname`, `uname` et `pid` ;
- protection de `babet.user.get` et `babet.user.exists` autour de leurs buffers
  NSS dynamiques et chaînes de diagnostic ;
- protection de la fabrique inotify, de `add`, `read`, `remove`, `close` et
  `__tostring`, avec une frontière `catch (...)` dédiée à `__gc`, sans
  allocation ni retour d’erreur ;
- traduction d’un échec d’allocation inattendu en `(nil, "<module>: out of
  memory")`, des autres exceptions standard en `(nil, "<module>: internal
  failure")` et des exceptions non standard en `(nil, "<module>: unknown
  internal failure")` ;
- conservation des erreurs de programmation sur leur chemin d’erreur Lua et de
  tous les retours ordinaires de succès, d’erreur runtime, de timeout,
  d’interruption et de NSS.

### Processus interactifs avec `babet.spawn`

- conservation du groupe de processus séparé de l’enfant, afin que
  `terminate()`, `kill()` et `close()` continuent de cibler aussi ses
  descendants ;
- lorsqu’un `stdin = "inherit"` désigne le terminal de contrôle dont Babet
  possède le premier plan, transfert synchronisé de ce terminal au groupe
  enfant seulement après la création effective de son groupe ;
- ajout d’un pipe de synchronisation `CLOEXEC` empêchant l’enfant de lire avant
  le `tcsetpgrp()` du parent et donc d’être suspendu par `SIGTTIN` ;
- restitution du premier plan et des attributs `termios` initiaux après
  `wait()`, `terminate()`, `kill()`, `close()`, le ramasse-miettes ou un échec
  de lancement ;
- blocage local de `SIGTTOU` autour des changements de groupe de premier plan,
  sans modifier le masque de signaux durable du processus ;
- absence de changement pour les flux capturés, les redirections vers fichier
  ou `/dev/null`, et un `stdin` hérité qui n’est pas un terminal ;
- les signaux générés par le terminal, notamment `Ctrl+C`, atteignent le groupe
  enfant de premier plan et conservent la convention de résultat
  `128 + signal`.

### Tests et documentation

- ajout d’un test de non-régression sous véritable pseudo-terminal : première
  lecture par le parent Lua, seconde lecture par l’enfant avec les trois flux
  hérités, contrôle d’un `wait(timeout)` suivi d’une reprise normale, livraison
  de `Ctrl+C`, vérification du code 130, suspension réelle par `Ctrl+Z`,
  récupération bornée par `kill()`, restauration après interrogation
  `is_running()`, modification puis restauration des attributs du terminal, et
  délai maximal anti-blocage ;
- documentation explicite de l’absence de job control complet, de la nécessité
  d’observer ou fermer un enfant terminé avant une nouvelle lecture du parent,
  et du caractère non interactif de `pipeline()` / `spawnPipeline()` ;
- intégration de ce test PTY aux validations normales et ASan/UBSan ;
- ajout d’un autotest autonome compilé couvrant le succès, `std::bad_alloc`,
  `std::exception` et une exception inconnue, tout en vérifiant que chaque
  rapporteur de diagnostic s’exécute après la sortie du `catch` C++ actif ;
- ajout d’un préflight de release exigeant une frontière pour chacune des 17
  fonctions auditées et refusant les anciens enregistrements directs ;
- aucune injection dans le binaire de production : l’autotest exerce le cœur
  commun dans son propre exécutable temporaire ;
- mise à jour des README anglais et français, références de modules, procédure
  de release, `todo`, en-tête des notices tierces et notes de release 2.14.0.

## [2.13.0] - 2026-08-03

### Résumé de la version

Babet 2.13.0 ajoute un helper SQLite de savepoint assisté et imbriquable. Les
scripts peuvent maintenant isoler une unité de travail récupérable sans
inventer d'identifiant SQL ni associer manuellement `ROLLBACK TO` et `RELEASE`,
y compris dans une transaction assistée ou manuelle déjà ouverte.

### Helper de savepoint imbriqué

- ajout de `db:savepoint(callback)`, qui renvoie `true` puis toutes les valeurs
  d'un callback terminé normalement, y compris `nil` et `false` explicites ;
- génération intégrale des identifiants de savepoint dans Babet, à partir d'une
  séquence monotone propre à la connexion et sans identifiant SQL contrôlé par
  l'utilisateur ;
- prise en charge des savepoints autonomes, dans `db:transaction()`, dans une
  transaction SQL manuelle et récursivement dans d'autres helpers ;
- maintien de `db:in_transaction()` à `true` pendant un savepoint autonome et
  conservation de la transaction externe après le `RELEASE` interne ;
- conversion des erreurs Lua du callback en `(nil, err)` après `ROLLBACK TO`
  puis `RELEASE`, afin qu'un helper interne en échec n'annule que son travail ;
- abandon des résultats du callback lorsque le `RELEASE` du savepoint le plus
  externe échoue, puis tentative du même nettoyage avant de renvoyer l'erreur
  SQLite ;
- refus de `db:close()` pendant tout callback de savepoint, sans modifier les
  règles du helper de transaction de la 2.12.0.

### Sûreté aux exceptions et récupération de l'état

- suivi de la profondeur active et de la séquence de noms sur chaque connexion
  native, sans état global ;
- ajout d'une garde RAII d'urgence sans allocation, qui tente `ROLLBACK TO` puis
  `RELEASE` si une exception C++ s'échappe après `SAVEPOINT` ;
- détection des callbacks qui terminent explicitement la transaction avant
  toute tentative de nettoyage, avec une erreur stable unique, sans identifiant
  généré ni répétition de `no such savepoint` ;
- réduction des noms générés à la forme locale `babet_sp_<séquence>`, sans
  adresse native, et contrôle explicite de chaque résultat de formatage ;
- réservation de la pile Lua avant la prise de possession du savepoint et appel
  du callback avec `lua_pcall`, afin qu'un longjmp Lua ne contourne pas le
  nettoyage natif ;
- maintien de tous les points d'entrée publics sous la frontière d'exception
  SQLite commune et vérification de la réutilisation après erreurs du callback,
  du `RELEASE` et d'une contrainte différée.

### Tests et documentation

- ajout de 37 assertions couvrant valeurs normales, `nil`/`false` explicites,
  rollback du callback, réutilisation, trois niveaux imbriqués, échecs intérieur
  et extérieur, transactions assistées et manuelles, contraintes différées au
  `RELEASE` et au `COMMIT` externe, `ROLLBACK` explicite dans le callback sur
  les chemins de retour normal et d'erreur Lua, arité stricte, connexion
  fermée, refus de fermeture et workers ;
- enregistrement d'une sonde rouge avant implémentation, puis compilation du
  `sqlite.cpp` final en C++23 avec `-Wall -Wextra -Werror` et exécution de la
  campagne Lua complète avec un binaire entièrement lié ;
- enrichissement synchronisé des chapitres SQLite français et anglais avec des
  exemples distincts : autonome, rollback, imbrication, transaction et
  contrainte différée ;
- mise à jour des métadonnées de version, README, procédure de publication,
  notes GitHub et manuels PDF pour 2.13.0.

## [2.12.0] - 2026-08-03

### Résumé de la version

Babet 2.12.0 étend la surface SQLite auditée avec trois compteurs propres à la
connexion et deux options d'ouverture strictes. L'ouverture en lecture/écriture
reste le comportement par défaut ; un script peut maintenant demander un
handle réellement en lecture seule et activer les clés étrangères avant la
première instruction, sans SQL de configuration.

### Options de connexion SQLite

- ajout de l'option booléenne stricte `opts.readonly`, fondée sur
  `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)` ; elle ne crée jamais une
  base absente et SQLite refuse les écritures via le handle obtenu ;
- conservation des flags historiques `READWRITE | CREATE` lorsque `readonly`
  est absent ou vaut `false` ;
- ajout de l'option booléenne stricte `opts.foreign_keys`, configurée
  directement sur chaque connexion native avant WAL ou le SQL utilisateur ;
  son défaut explicite à `false` conserve le comportement précédent ;
- combinaison possible de `readonly` avec `busy_timeout` et `foreign_keys`,
  mais refus de la combinaison contradictoire
  `readonly = true, wal = true` avant l'ouverture d'un handle natif ; précision
  que seul le changement de mode est refusé, pas la lecture d'une base déjà en
  WAL ;
- conservation d'une lecture brute et stricte des options : champs inconnus,
  clés non chaîne, valeurs fournies par une métatable et valeurs non booléennes
  restent refusés.

### Compteurs de connexion

- ajout de `db:last_insert_rowid()` avec la valeur ROWID signée 64 bits propre
  à la connexion SQLite ;
- ajout de `db:changes()` et `db:total_changes()` via leurs APIs SQLite 64 bits,
  avec retour sous forme d'entiers Lua ;
- documentation et test du cas où `INSERT OR IGNORE` réussit avec zéro
  modification tandis que `last_insert_rowid()` conserve le ROWID de
  l'insertion précédente ;
- application de l'arité exacte et du contrat de connexion fermée aux trois
  méthodes ;
- exposition des mêmes méthodes et options d'ouverture dans les états Lua des
  workers.

### Durcissement hérité du module d'archives

- extension de la frontière d'exception C++ de `read()` aux six points d'entrée
  publics du module, afin qu'aucune exception d'allocation ou autre exception
  C++ ne traverse la frontière Lua ;
- ajout d'un état explicite de complétude pour l'entrée sélectionnée dans le
  sink TAR en mémoire, puis contrôle final par `read()`, symétrique avec le
  contrôle du nombre d'octets du chemin ZIP ;
- nouvelle vérification que le journal fixe `babet-tests.txt` est ignoré par
  Git et absent des deux archives de livraison.

### Tests et documentation

- ajout de 36 assertions ciblées couvrant types et combinaisons d'options,
  lecture/écriture/création en lecture seule, clés étrangères activées ou non,
  valeurs initiales, cumulées et supérieures à 32 bits des compteurs,
  statements multi-lignes, handles fermés, arités strictes, insertions
  ignorées, échec d'une clé étrangère différée au `COMMIT` et disponibilité dans
  les workers ;
- preuve du passage rouge vers vert : 0 PASS / 5 FAIL avant l'exposition de la
  surface publique, puis 5 PASS / 0 FAIL avec l'implémentation ;
- enrichissement synchronisé des chapitres SQLite français et anglais avec un
  exemple distinct pour chaque option et compteur, puis des exemples combinés
  pour une connexion d'écriture, un lecteur et les trois compteurs ;
- mise à jour des métadonnées de version, README, procédure de publication,
  notes GitHub et manuels PDF pour 2.12.0.

## [2.11.0] - 2026-08-02

### Résumé de la version

Babet 2.11.0 ajoute la lecture bornée d’une entrée d’archive en mémoire avec
`babet.archive.read()`. L’API conserve les noms bruts, rend les doublons
explicitement désambiguïsables par index, borne les octets réellement produits
et n’effectue aucune écriture. Le contrat enrichi de `archive.list()` introduit
en 2.8.0 reste inchangé et sert directement de catalogue à cette nouvelle
lecture.

### Lecture binaire bornée

- ajout de `babet.archive.read(archive, nom_ou_index [, opts])`, avec retour
  strict `(chaîne_binaire, nil)` ou `(nil, message)` et prise en charge des
  fichiers vides, octets NUL et données non UTF-8 ;
- sélection sensible à la casse par nom brut exact ou par index 1-based exposé
  par `archive.list()` ; refus d’un nom brut présent plusieurs fois et
  possibilité de choisir explicitement chaque occurrence par index ;
- absence de tri, déduplication, normalisation Unicode ou assainissement de
  chemin : une entrée régulière au nom dangereux peut être lue comme donnée
  sans jamais devenir un chemin de destination, tandis que `valid_utf8` et
  `safe_path` restent exposés par `list()` ;
- refus des répertoires, liens symboliques ou physiques, FIFO, sockets,
  périphériques, types inconnus, entrées ZIP chiffrées, méthodes ZIP non prises
  en charge et fichiers TAR sparse ;
- ajout de l’option entière stricte `max_size`, à 8 Mio par défaut et 256 Mio
  au maximum, indépendante des six limites globales déjà partagées par les
  autres lecteurs d’archives ;
- contrôle précoce de la taille annoncée, puis contrôle du nombre d’octets
  réellement remis par le callback de décompression, y compris lorsqu’un ZIP
  mensonger annonce une taille inférieure à sa sortie réelle ;
- copie directe vers un tampon préalloué borné : aucun agrandissement et aucune
  allocation sur le chemin de copie nominal du callback C de miniz ou du sink
  TAR.

### Formats, intégrité et workers

- parité complète pour ZIP, TAR brut, TAR gzip, TAR xz, TAR bzip2 et TAR zstd,
  avec détection par contenu et fonctionnement identique dans les états Lua des
  workers ;
- décompression complète et vérification CRC du payload ZIP sélectionné ;
- conservation du modèle TAR en deux passes : inspection et consommation
  intégrales, comparaison de chaque en-tête lors de la seconde passe,
  transmission en mémoire de la seule entrée choisie et validations gzip/zstd
  jusqu’à la fin du flux ;
- distinction documentée avec `archive.test()`, qui reste la fonction de
  validation exhaustive de tous les payloads ZIP et du verdict global de
  sécurité ;
- frontière d’exception C++ dédiée au nouveau point d’entrée Lua, distinguant
  manque de mémoire, exception standard et exception inconnue.

### Tests et documentation

- ajout de 61 assertions fonctionnelles dédiées couvrant sélection par nom et
  index, doublons ZIP/TAR, noms dangereux et non UTF-8, données binaires et
  vides, liens refusés, limites exactes et invalides, sortie décompressée
  mensongère, CRC corrompu, options/arités strictes, six formats, workers et
  absence de temporaires ;
- validation ciblée du nouveau lot à 64 PASS / 0 FAIL avec les trois contrôles
  d’enregistrement du sous-module ;
- enrichissement synchronisé des manuels français et anglais avec un exemple
  distinct par mode de sélection, l’option `max_size`, les doublons, les noms
  dangereux, les workers et un exemple combinant toutes les limites ;
- mise à jour des README, métadonnées de version, procédure de publication,
  notes GitHub et manuels PDF pour 2.11.0.

## [2.10.0] - 2026-08-02

### Résumé de la version

Babet 2.10.0 achève un audit complet, de la source aux tests, de
`babet.sqlite`. La seule nouvelle API publique est `babet.sqlite.NULL` ; le
reste de la version rend explicites et impose mécaniquement les contrats
existants de connexion, statements, paramètres, cycle de vie, diagnostics et
sûreté aux exceptions.

### NULL SQL explicite et contrats de bind

- ajout du singleton lightuserdata `babet.sqlite.NULL` pour les binds nommés,
  positionnels, directs et préparés, sans relâcher la règle d'exactitude de la
  table de paramètres ;
- conservation d'une conversion volontairement asymétrique à la lecture : SQL
  `NULL` produit toujours une clé Lua absente, tandis que les INTEGER SQLite
  issus de booleans sont relus comme des entiers ;
- conservation exacte des entiers signés 64 bits et refus de NaN et des deux
  infinis avant leur arrivée dans SQLite ;
- lecture brute des paramètres nommés, afin que `__index` ne puisse ni fournir
  ni perturber un bind, et refus des types de clés non supportés, indices
  numériques sparse ou non entiers, valeurs manquantes ou en trop et
  placeholders numérotés `?NNN` ;
- distinction entre la sentinelle NULL exacte et tout autre lightuserdata, qui
  reste un type de bind non supporté ;
- refus explicite de `babet.sqlite.NULL` par JSON, les arguments/messages des
  workers et les channels, avec vérification de l'atomicité d'un envoi refusé.

### Cycle de vie, diagnostics et sûreté aux exceptions

- conservation du diagnostic SQLite de `step` avant `reset` ou `finalize` et
  utilisation du code retour lorsque `sqlite3_errcode()` est déjà devenu
  `SQLITE_MISUSE`, ce qui corrige les erreurs de contrainte après collecte du
  userdata `Db` parent ;
- passage des 19 points d'entrée Lua SQLite ordinaires par une frontière
  d'exception C++ commune et des quatre finalizers par une frontière silencieuse
  `noexcept`, afin qu'une allocation défaillante ne traverse jamais une
  `lua_CFunction` compilée comme du C ;
- mise en état finalisable de chaque handle natif avant acquisition ou transfert
  dans les chemins d'erreur de `open`, `query` direct, `prepare` et `exec`
  paramétré ;
- justification de l'absence volontaire de `Db*` brut ou d'ancrage Lua dans les
  statements temporaires et préparés : `sqlite3_close_v2` possède le cycle de
  vie de la connexion zombie jusqu'à la finalisation du dernier statement ;
- conservation du handle de connexion lorsque `sqlite3_close_v2` signale un
  échec, au lieu de déclarer fermé un handle encore possédé ;
- contrôles d'arité exacte sur l'API publique et refus par `open` des options
  inconnues, clés d'option non chaînes, mauvais types et délais hors limites.

### Tests et documentation

- ajout de cinq régressions après collecte du parent : deux utilisations réussies
  de la connexion zombie et trois diagnostics de contrainte, chacune prouvant
  par une table faible que le userdata parent a réellement été collecté ;
- ajout de 32 assertions par mode de test fonctionnel pour NULL, les options et
  arités strictes, la forme des tables de paramètres, les nombres non finis,
  les limites 64 bits, la lecture brute des noms, `?NNN`, les handles fermés et
  les refus entre sous-systèmes ;
- enrichissement des manuels SQLite français et anglais avec exemples séparés
  pour chaque option, usages de NULL explicite, règles de lecture, garanties de
  cycle de vie, diagnostics, exclusions volontaires et exemples combinés ;
- régénération des deux manuels PDF et mise à jour des métadonnées et notes de
  version pour 2.10.0.

## [2.9.2] - 2026-08-01

### Résumé de la version

Babet 2.9.2 est une version de durcissement et de couverture de non-régression
pour Babet 2.9.1. Elle ne modifie pas l'API Lua. Elle renforce la sérialisation
des workers, le nettoyage des processus et pipelines, la récupération des
transactions SQLite, les frontières d'exception HTTP/sockets, le décodage
inotify et la validation de release.

### Durcissement du build et des tests de non-régression

- extension du préflight Zstandard local sans réseau aux tests ordinaires et
  aux deux builds de validation de release ;
- correction d'un diagnostic vide lorsqu'un TAR gzip était suivi d'un seul
  octet non nul, avec vérification des cas à un et deux octets résiduels ;
- durcissement du décodage des buffers inotify : copie alignée de l'en-tête,
  contrôle des en-têtes et noms tronqués, progression bornée et test
  d'intégration vérifiant plusieurs événements dans une même lecture ;
- durcissement du helper de tests `ok_fail()`, qui refuse désormais les chaînes
  d'erreur vides ;
- audit des 132 assertions `ok_raises()` : les 36 appels qui vérifiaient
  seulement qu'une erreur Lua quelconque était levée exigent désormais un
  fragment de diagnostic stable, et le helper refuse tout nouvel appel sans
  motif non vide ;
- ajout d'un préflight hermétique de huit cas pour le décodeur inotify et d'un
  smoke test TLS vérifiant un certificat avec SAN IP via l'OpenSSL statique
  réellement lié à Babet ;
- réalignement des documentations workers française et anglaise sur la séquence
  réelle de `__gc`, avec l'étape initiale de demande d'annulation et une
  précision indiquant que le timeout de `join()` ne borne pas un futur
  `pthread_join()` déclenché par le ramasse-miettes.

### Durcissement de la sérialisation workers

- interception sans allocation C++ supplémentaire des exceptions produites
  pendant la construction ou l'encodage JSON des arguments de `spawn`, de
  `job:send` et de `worker.send`, afin qu'aucune exception ne traverse une
  `lua_CFunction` ;
- ajout d'un budget symétrique par opération, limité à 1 000 000 de valeurs
  développées et 64 Mio estimés, appliqué avant la copie des chaînes et avant
  la publication dans les queues ;
- protection contre l'amplification exponentielle provoquée par des sous-tables
  ou chaînes partagées, avec garantie qu'un message refusé n'est pas publié ;
- correction de l'ordre de traitement des entiers JSON non signés et signés ;
- ajout de tests d'intégration pour la fidélité exacte des entiers 64 bits, le
  refus de `NaN` et des infinis sur les cinq chemins de transfert, le budget
  d'octets et l'atomicité des envois refusés ;
- ajout d'un préflight hermétique pour les frontières des budgets de nœuds et
  d'octets, complété par un unique test du chemin Lua public au-delà du million
  de nœuds, activé seulement dans le mode dossier du build normal ;
- clarification du contrat de période de grâce des pipelines : tous les membres
  reçoivent `SIGTERM` immédiatement, tandis que les leaders zombies préservent
  le PGID jusqu'au signal final éventuel.

### Sûreté aux exceptions des processus et pipelines

- protection des frontières Lua de `spawn`, `exec`, `pipeline` et
  `spawnPipeline` contre toute exception C++ issue du lancement ou de la phase
  synchrone, avec diagnostics littéraux n'exigeant aucune allocation C++ ;
- ajout d'un nettoyage d'urgence sans allocation après `fork()` : fermeture des
  descripteurs, `SIGKILL` immédiat du groupe et tentative de récupération
  bornée, sans appliquer la période de grâce réservée à `terminate()` ;
- ajout de gardes RAII autour des allocations nominales de `exec()` et
  `pipeline()` - croissance des sorties, vecteurs de `poll()` et tableaux de
  statuts - afin qu'un échec d'allocation ne puisse abandonner des enfants ou
  des pipes ;
- exclusion systématique des PID déjà récupérés lors des signaux de nettoyage,
  pour ne jamais viser un identifiant recyclé ;
- déplacement de la limite de 32 étapes vers le lanceur commun et validation
  locale avant toute création de pipe ou tout `fork()` ;
- documentation explicite de l'invariant interdisant les appels Lua dans les
  régions protégées par RAII, car une erreur Lua utilise `longjmp` et
  contournerait les destructeurs C++ ;
- documentation explicite du fait que la sûreté OOM après `fork()` repose sur
  la revue structurelle, la compilation stricte et un nettoyage sans allocation,
  et non sur une injection déterministe d'échec d'allocation.

### Durcissement de l'état transactionnel SQLite

- ajout d'une possession RAII explicite après tout `BEGIN` réussi, avec
  tentative immédiate de rollback après exception C++ et remise à zéro garantie
  du marqueur de callback transactionnel actif ;
- réservation des deux cases de pile nécessaires au callback avant `BEGIN`,
  puis de la case du booléen de succès avant `COMMIT`, afin d'éviter tout
  `longjmp` Lua non protégé pendant que la garde transactionnelle est armée ;
- report du formatage de l'erreur du callback après la tentative de rollback,
  pour qu'un objet d'erreur Lua inhabituel ne puisse laisser une transaction
  ouverte ;
- conservation conjointe des diagnostics de `COMMIT` et de `ROLLBACK`, ajout
  d'une dernière tentative de rollback sans allocation C++ et signalement
  explicite si la connexion reste malgré tout dans une transaction ;
- ajout de tests d'intégration couvrant l'échec de `COMMIT` sur contrainte
  différée, le diagnostic d'échec de rollback, le retour en autocommit, la
  réutilisation de la connexion, la réutilisation d'un statement préparé après
  rollback et un itérateur de lecture restant actif pendant un commit réussi ;
- documentation du fait que la sûreté aux exceptions de `TransactionGuard`
  repose sur la revue structurelle et la compilation stricte, et non sur une
  injection déterministe de `bad_alloc` ; les tests valident les états obtenus,
  le nettoyage et la réutilisation de la connexion.

### Sûreté aux exceptions HTTP et sockets

- correction du handler d'exception HTTP qui concaténait encore une
  `std::string` après interception de `std::bad_alloc`, avec un diagnostic OOM
  littéral ne nécessitant aucune allocation C++ supplémentaire ;
- conversion des autres exceptions HTTP en diagnostic Lua sans concaténation
  C++ dans le handler ;
- ajout d'une frontière anti-exception commune à toutes les fonctions et
  méthodes publiques de `babet.socket`, empêchant toute exception C++ de
  traverser une `lua_CFunction` alors que Lua est compilé en C ;
- création du userdata propriétaire avant l'acquisition d'un FD ou d'un objet
  OpenSSL pour `connect`, `listen`, `accept` et `connect_tls`, afin qu'une erreur
  mémoire Lua par `longjmp` ne puisse abandonner une ressource sans propriétaire ;
- ajout d'une garde dédiée à `starttls`, qui restaure les flags avant le début
  du handshake et ferme le flux si une exception survient après le premier
  échange TLS ;
- ajout d'un test local vérifiant qu'une redirection HTTP vers une autre origine
  ne retransmet pas le header `Authorization` ;
- documentation du fait que la sûreté OOM des sockets repose sur la revue
  structurelle, la compilation stricte et l'analyse statique, sans injection
  déterministe de `bad_alloc`.

### Validation de la release

L'arbre exact de Babet 2.9.2 a validé :

- 3370 PASS / 0 FAIL en mode dossier sous ASan + UBSan ;
- 3357 PASS / 0 FAIL en mode embarqué sous ASan + UBSan ;
- 3357 PASS / 0 FAIL en mode embarqué via `PATH` sous ASan + UBSan ;
- 3371 PASS / 0 FAIL en mode dossier avec le build normal final ;
- 3357 PASS / 0 FAIL en mode embarqué avec le build normal final ;
- 3357 PASS / 0 FAIL en mode embarqué via `PATH` avec le build normal final ;
- 5/5 tests du préflight de bootstrap Zstandard ;
- 8/8 tests du préflight de décodage inotify ;
- 9/9 tests du préflight des budgets de sérialisation workers ;
- 11 PASS / 0 FAIL / 0 WARN dans les smoke tests réseau finaux.

L'écart d'un test entre les modes dossier normal et sanitizers est attendu :
le test workers au-delà d'un million de nœuds n'est activé qu'une seule fois,
dans le mode dossier du build normal.

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
