> [English](../en/README.md) | **Français**

<p align="center">
  <img src="../assets/babet-closed.png" alt="Babet — pomme de pin" width="160">
</p>

# Babet — Manuel utilisateur

> *Babet*, n.m. — mot régional du sud-est de la France
> (Lyonnais, Forez, Dauphiné, Savoie, ainsi que la Suisse
> romande voisine) désignant une pomme de pin. Petit, léger,
> plein de graines, et capable d’allumer un feu — comme ce
> binaire.

Babet est un binaire Lua standalone pour le scripting et l’automatisation sous
Linux. Ce manuel est organisé par besoin et par module : la table des matières
ci-dessous indique non seulement le nom technique du module, mais aussi les
fonctionnalités qu’il contient.

Documentation de la version candidate **Babet 2.22.2**.

Babet 2.22.2 ajoute un client RFC 6455 natif via `babet.websocket`, avec
`ws://` et `wss://` vérifié, négociation stricte, framing borné, Ping/Pong
automatique, fragmentation, fermeture propre et disponibilité dans les workers.
Le harnais d'auto-test contient désormais 45 suites atteignables.

## Pour démarrer

- [`Premiers pas`](getting-started.md) — installation, premier script,
  exécution d’un fichier ou d’un dossier, création d’un exécutable embarqué et
  utilisation via le `PATH`.
- [`Sécurité`](security.md) — modèle de menace, protections réellement
  fournies, limites et règles de moindre privilège.
- [`Cookbook`](cookbook.md) — recettes complètes combinant plusieurs modules.
- [`Journal des modifications`](../../CHANGELOG.fr.md) — notes complètes de la 2.22.2 et historique des versions précédentes, migration, validation et limites connues.

## Trouver une fonctionnalité

| Je cherche à… | Chapitre à consulter | Ce que j’y trouverai |
| --- | --- | --- |
| créer, supprimer, lister, rechercher, copier ou déplacer des fichiers | [`FS — système de fichiers`](modules/fs.md) | fichiers, dossiers, chemins, symlinks, `listFiles`, `find` avec confinement `xdev`, `copyTree`, permissions et checksums |
| publier atomiquement une configuration ou un fichier binaire | [`writeFileAtomic — écriture atomique`](modules/write-file-atomic.md) | refus d’écrasement par défaut, permissions, durabilité, confinement des chemins, concurrence et workers |
| lire les arguments d’un script | [`Argparse — ligne de commande`](modules/argparse.md) | flags, options, arguments positionnels, valeurs par défaut, choix et conversions |
| construire une interface terminal | [`CURSES — interfaces utilisateur en terminal`](modules/curses.md) | affichage UTF-8, clavier symbolique, resize/suspension, handoff des enfants interactifs, workers et fallbacks terminfo autonomes |
| lancer un programme externe | [`Exec — processus`](modules/exec.md) | arguments sans shell, capture avec `exec`, streaming avec `spawn`, environnement, cwd et contrôle du processus |
| enchaîner plusieurs commandes | [`Pipelines de processus`](modules/pipeline.md) | capture complète ou streaming, stderr séparés, statuts individuels et nettoyage des groupes |
| créer ou inspecter/extraire des archives ZIP ou TAR | [`Archive — archives multi-formats sécurisées`](modules/archive.md) | création déterministe de ZIP et de TAR brut/gzip/xz/bzip2/zstd, listing, test intégral, extraction sélective, simulation `dry_run`, limites anti-bombe et publication atomique des fichiers |
| encoder ou décoder des données binaires en Base64 | [`Base64 — données binaires`](modules/base64.md) | alphabet standard ou URL-safe, padding optionnel, décodage canonique strict, espaces contrôlés et limite de sortie |
| compresser ou décompresser un fichier | [`Compression — flux autonomes`](modules/compression.md) | flux gzip, xz, bzip2 et zstd, détection par contenu, limites de sortie, membres concaténés, intégrité et publication atomique |
| manipuler l’environnement, identifier le processus ou mesurer la VM Lua | [`SYS - processus et machine`](modules/sys.md) | version du runtime, PID, hostname, `uname`, `PATH`, `env`, `setenv` et mémoire de l’état Lua |
| envoyer une requête web | [`HTTP — client web`](modules/http.md) | GET/POST et autres méthodes, query, headers validés, corps binaires, téléchargement atomique vers fichier, redirections, TLS, timeout et limites de taille |
| ouvrir une connexion TCP ou un socket Unix local | [`Socket — TCP et Unix`](modules/socket.md) | clients et serveurs TCP/Unix, acceptation, permissions locales, flux binaires, lignes, EOF, timeouts et nettoyage |
| utiliser WebSocket ou le transport WebDriver BiDi | [`WebSocket — client RFC 6455`](modules/websocket.md) | `ws://`, `wss://` vérifié, masquage, fragmentation, Ping/Pong, fermeture, timeouts et limites mémoire strictes |
| chiffrer une connexion TCP ou faire STARTTLS | [`TLS — sockets sécurisées`](modules/tls.md) | TLS direct, STARTTLS, vérification, CA, hostname, SNI, versions, timeout et état après échec |
| stocker des données SQL localement | [`SQLite — base embarquée`](modules/sqlite.md) | ouverture en lecture/écriture ou lecture seule, clés étrangères, compteurs de changements, paramètres stricts, sauvegarde atomique cohérente, valeurs `NULL` et BLOB explicites, statements préparés et transactions assistées |
| encoder ou décoder du JSON | [`JSON — données structurées`](modules/json.md) | scalaires, tableaux, objets, `null`, tableaux vides, pretty-print et erreurs |
| lire un fichier de configuration TOML | [`TOML — configuration`](modules/toml.md) | décodage, types TOML, tableaux, sections, dates et erreurs de parsing |
| surveiller un dossier | [`Inotify — événements fichiers`](modules/inotify.md) | watchers, événements, lectures avec timeout, moves, cookies et fermeture |
| gérer les signaux Unix | [`SIGNAL — arrêt propre et rechargement`](modules/signal.md) | `TERM`/`INT`/`HUP`/`USR1`/`USR2`/`PIPE`, callbacks différés, ordre fixe, coalescence, appels interruptibles et workers |
| paralléliser du Lua | [`WORKERS — threads OS, messages et channels`](modules/workers.md) | états Lua isolés, `spawn`, pool persistant borné, `cpu_count`, inbox/outbox et channels directs MPMC |
| obtenir ou formater le temps | [`Time — horloges et durées`](modules/time.md) | temps réel, monotone, sleep, ISO-8601, parsing et formatage de durées |
| rechercher un compte système par nom ou UID | [`USER - comptes système`](modules/user.md) | NSS, `get`, `exists`, UID, GID principal, GECOS, home, shell et erreurs de résolution |
| découper ou transformer des chaînes | [`Strings — chaînes`](modules/strings.md) | `split`, séparateurs, limites et chaînes binaires |
| copier, fusionner ou marquer des tables | [`Tables — tables Lua`](modules/tables.md) | `mergeTables`, `deepCopyTable`, cycles et structures partagées |
| produire des logs | [`Logging — journalisation`](modules/logging.md) | niveaux, seuil, sortie, couleurs et comportement en cas d’erreur du sink |

## Modules de référence

Chaque module possède une page autonome sous [`modules/`](modules/). Les
intitulés développés ci-dessous permettent de comprendre leur périmètre sans
avoir à ouvrir chaque fichier.

| Module | Périmètre détaillé |
| --- | --- |
| [`Archive — opérations ZIP, TAR, TAR gzip, TAR xz, TAR bzip2 et TAR zstd sécurisées`](modules/archive.md) | Créer des ZIP, TAR, TAR gzip, TAR xz, TAR bzip2 ou TAR zstd déterministes, les inspecter, tester et extraire sélectivement avec simulation `dry_run`, ressources bornées, chemins confinés et publication atomique fichier par fichier. |
| [`Base64 — encodage et décodage binaires`](modules/base64.md) | Encoder ou décoder des chaînes Lua binaires avec alphabet standard ou URL-safe, padding contrôlé, validation canonique, espaces optionnels et plafond `max_output`. |
| [`Compression — flux gzip, xz, bzip2 et zstd autonomes`](modules/compression.md) | Compresser ou décompresser un fichier régulier avec détection automatique, expansion bornée, vérification d’intégrité, refus des symlinks et publication atomique. |
| [`Argparse — arguments de ligne de commande`](modules/argparse.md) | Déclarer des flags, options et positionnels ; générer l’aide ; valider les choix ; convertir les valeurs. |
| [`Exec — programmes externes et processus`](modules/exec.md) | Exécuter sans shell avec `exec`, ou piloter stdin/stdout/stderr progressivement avec `spawn`. |
| [`Pipelines de processus`](modules/pipeline.md) | Relier plusieurs commandes sans shell, en capture complète ou en streaming, avec statuts par étape. |
| [`FS — fichiers, dossiers, chemins et attributs`](modules/fs.md) | Existence et types, création/suppression, chemins, listings, recherche, itérateur, copie/déplacement d’arbres, symlinks, modes Unix et checksums. |
| [`writeFileAtomic — écriture atomique et durable`](modules/write-file-atomic.md) | Publier une chaîne Lua binaire par temporaire privé et renommage atomique, avec écrasement explicite, permissions exactes, `fsync`, confinement des chemins et support des workers. |
| [`HTTP — requêtes web`](modules/http.md) | URL, méthodes, query, headers validés, corps binaires, réponses, téléchargement atomique vers fichier, redirections, vérification TLS, timeout et limites de taille. |
| [`Inotify — surveillance du système de fichiers`](modules/inotify.md) | Ajouter/retirer des watches, lire les événements, gérer timeouts, moves, cookies et fermeture. |
| [`JSON — encodage et décodage`](modules/json.md) | Types Lua/JSON, `null`, tableaux vides, marquage de tableaux, indentation, UTF-8, cycles et limites. |
| [`Logging — journalisation`](modules/logging.md) | Niveaux, filtrage, destination, couleurs et appels variadiques. |
| [`SIGNAL — signaux POSIX et arrêt propre`](modules/signal.md) | Installer, remplacer ou retirer un callback ; ignorer/restaurer ; ordre de dispatch, coalescence, interruptions et restrictions multithread. |
| [`Socket — TCP et sockets Unix`](modules/socket.md) | Connexion et écoute TCP/Unix, acceptation, permissions et nettoyage inode-sensible, flux binaires, lectures bloc/ligne/EOF, adresses et timeouts. |
| [`WebSocket — client RFC 6455`](modules/websocket.md) | Connexions clientes `ws://`/`wss://`, validation stricte de l’Upgrade, masquage client, fragmentation texte/binaire, Ping/Pong, Close, TLS, timeouts et plafonds de ressources. |
| [`SQLite — base de données embarquée`](modules/sqlite.md) | Connexions en lecture/écriture ou lecture seule, WAL/timeout, clés étrangères, compteurs de lignes, SQL direct, statements préparés réutilisables, BLOB explicites, sauvegardes WAL cohérentes, itération et transactions assistées. |
| [`Strings — manipulation de chaînes`](modules/strings.md) | Découpage, mode caractères, séparateurs, limite de splits et contenu binaire. |
| [`SYS - processus, machine, environnement et mémoire Lua`](modules/sys.md) | Constantes de version, PID, hostname, `uname`, recherche d’exécutables, lecture/modification de l’environnement, interaction avec les workers et mémoire de l’état Lua. |
| [`Tables — manipulation de tables Lua`](modules/tables.md) | Fusion déterministe, clés listes/maps, copie profonde, cycles et partage de sous-tables. |
| [`Time — horloges, ISO et durées`](modules/time.md) | Temps réel et monotone, sommeil, formatage/parsing ISO-8601, parsing et rendu de durées. |
| [`TLS — connexions chiffrées`](modules/tls.md) | Connexion TLS directe, STARTTLS, vérification, CA, hostname, SNI, versions, deadlines et comportement fail-closed. |
| [`TOML — fichiers de configuration`](modules/toml.md) | Décodage TOML, scalaires, tableaux, tables, tableaux de tables, dates/heures et diagnostics. |
| [`USER - utilisateurs système via NSS`](modules/user.md) | Recherche par nom ou UID, existence, distinction absence/erreur NSS, champs passwd, workers et limites de sécurité. |
| [`WORKERS — threads OS, files et channels`](modules/workers.md) | États Lua isolés, transport JSON, `status`, `done`, pool persistant borné, annulation coopérative, inbox/outbox, channels directs MPMC, fermeture, GC et interblocages. |

## Organisation d’une page de module

Les pages détaillées sont progressivement alignées sur la structure suivante :

1. **Périmètre** — ce que couvre le module et ce qu’il ne couvre pas ;
2. **Table des matières interne** — accès direct à chaque groupe et fonction ;
3. **Vue d’ensemble de l’API** — signatures et résultats ;
4. **Comportement détaillé** — valeurs par défaut, symlinks, récursivité,
   limites et effets de bord ;
5. **Exemples** — un exemple par mode ou option importante ;
6. **Contrat d’erreur** — erreurs levées et erreurs renvoyées ;
7. **Décisions et limites** — choix d’API et éléments volontairement absents.

L’objectif est qu’une fonction puisse être utilisée sans lire son code source
et sans devoir deviner ses valeurs par défaut.

## Génération du PDF

Le manuel peut être exporté en un seul PDF :

```sh
cd docs
./build_doc.sh
```

L’ordre des chapitres français est défini dans
[`manual_order_fr.txt`](../manual_order_fr.txt). Le script de génération ajoute
ensuite la table des matières du PDF à partir des titres et sous-titres.

## Méthodologie de vérification

La documentation est vérifiée module par module selon trois sources :

- l’implémentation C/C++ réellement enregistrée dans `babet` ;
- les tests de non-régression de `examples/main.lua` et `run_tests.sh` ;
- les pages française et anglaise, qui doivent décrire le même contrat.

Une divergence découverte pendant cette vérification est traitée comme une
incohérence à corriger, et non comme un détail rédactionnel à masquer.
