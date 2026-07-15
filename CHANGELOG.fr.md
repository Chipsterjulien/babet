# Journal des modifications

Ce fichier décrit les changements notables de Babet.

Le projet suit le versionnage sémantique pour ses publications. Les notes de
migration et d’utilisation sont conservées avec chaque version lorsqu’un
nouveau contrat ou une règle opérationnelle peut affecter les scripts existants.

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
