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

## Pour démarrer

- [`Premiers pas`](getting-started.md) — installation, premier script,
  exécution d’un fichier ou d’un dossier, création d’un exécutable embarqué et
  utilisation via le `PATH`.
- [`Sécurité`](security.md) — modèle de menace, protections réellement
  fournies, limites et règles de moindre privilège.
- [`Cookbook`](cookbook.md) — recettes complètes combinant plusieurs modules.

## Trouver une fonctionnalité

| Je cherche à… | Chapitre à consulter | Ce que j’y trouverai |
| --- | --- | --- |
| créer, supprimer, lister, rechercher, copier ou déplacer des fichiers | [`FS — système de fichiers`](modules/fs.md) | fichiers, dossiers, chemins, symlinks, `listFiles`, `find`, `copyTree`, permissions et checksums |
| lire les arguments d’un script | [`Argparse — ligne de commande`](modules/argparse.md) | flags, options, arguments positionnels, valeurs par défaut, choix et conversions |
| lancer un programme externe | [`Exec — processus`](modules/exec.md) | arguments sans shell, stdin, stdout/stderr, environnement, cwd, timeout et limite de sortie |
| manipuler l’environnement, identifier le processus ou mesurer la VM Lua | [`SYS - processus et machine`](modules/sys.md) | version du runtime, PID, hostname, `uname`, `PATH`, `env`, `setenv` et mémoire de l’état Lua |
| envoyer une requête web | [`HTTP — client web`](modules/http.md) | GET/POST et autres méthodes, query, headers validés, corps binaires, redirections, TLS, timeout et taille maximale |
| ouvrir une connexion TCP | [`Socket — TCP`](modules/socket.md) | client, serveur, acceptation, flux binaires, lignes, lecture jusqu’à EOF, timeouts, buffers et limites |
| chiffrer une connexion TCP ou faire STARTTLS | [`TLS — sockets sécurisées`](modules/tls.md) | TLS direct, STARTTLS, vérification, CA, hostname, SNI, versions, timeout et état après échec |
| stocker des données SQL localement | [`SQLite — base embarquée`](modules/sqlite.md) | ouverture, options, exécution, paramètres, requêtes, itérateurs et transactions |
| encoder ou décoder du JSON | [`JSON — données structurées`](modules/json.md) | scalaires, tableaux, objets, `null`, tableaux vides, pretty-print et erreurs |
| lire un fichier de configuration TOML | [`TOML — configuration`](modules/toml.md) | décodage, types TOML, tableaux, sections, dates et erreurs de parsing |
| surveiller un dossier | [`Inotify — événements fichiers`](modules/inotify.md) | watchers, événements, lectures avec timeout, moves, cookies et fermeture |
| gérer les signaux Unix | [`SIGNAL — arrêt propre et rechargement`](modules/signal.md) | `TERM`/`INT`/`HUP`/`USR1`/`USR2`/`PIPE`, callbacks différés, ordre fixe, coalescence, appels interruptibles et workers |
| paralléliser du Lua | [`WORKERS — threads OS et messages`](modules/workers.md) | états Lua isolés, `spawn`, `join`, `poll`, inbox/outbox, timeouts, fermeture, sérialisation et interblocages |
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
| [`Argparse — arguments de ligne de commande`](modules/argparse.md) | Déclarer des flags, options et positionnels ; générer l’aide ; valider les choix ; convertir les valeurs. |
| [`Exec — programmes externes et processus`](modules/exec.md) | Exécuter sans shell, transmettre argv/stdin/env/cwd, capturer stdout/stderr, limiter le temps et la sortie. |
| [`FS — fichiers, dossiers, chemins et attributs`](modules/fs.md) | Existence et types, création/suppression, chemins, listings, recherche, itérateur, copie/déplacement d’arbres, symlinks, modes Unix et checksums. |
| [`HTTP — requêtes web`](modules/http.md) | URL, méthodes, query, headers validés, corps binaires, réponses, redirections, vérification TLS, timeout et taille maximale. |
| [`Inotify — surveillance du système de fichiers`](modules/inotify.md) | Ajouter/retirer des watches, lire les événements, gérer timeouts, moves, cookies et fermeture. |
| [`JSON — encodage et décodage`](modules/json.md) | Types Lua/JSON, `null`, tableaux vides, marquage de tableaux, indentation, UTF-8, cycles et limites. |
| [`Logging — journalisation`](modules/logging.md) | Niveaux, filtrage, destination, couleurs et appels variadiques. |
| [`SIGNAL — signaux POSIX et arrêt propre`](modules/signal.md) | Installer, remplacer ou retirer un callback ; ignorer/restaurer ; ordre de dispatch, coalescence, interruptions et restrictions multithread. |
| [`Socket — TCP client et serveur`](modules/socket.md) | Connexion, écoute, acceptation, flux binaires, lectures par bloc/ligne/EOF, buffer partagé, adresses, fermeture et timeouts. |
| [`SQLite — base de données embarquée`](modules/sqlite.md) | Connexions, options WAL/timeout, SQL, paramètres positionnels/nommés, itération des lignes, types et transactions. |
| [`Strings — manipulation de chaînes`](modules/strings.md) | Découpage, mode caractères, séparateurs, limite de splits et contenu binaire. |
| [`SYS - processus, machine, environnement et mémoire Lua`](modules/sys.md) | Constantes de version, PID, hostname, `uname`, recherche d’exécutables, lecture/modification de l’environnement, interaction avec les workers et mémoire de l’état Lua. |
| [`Tables — manipulation de tables Lua`](modules/tables.md) | Fusion déterministe, clés listes/maps, copie profonde, cycles et partage de sous-tables. |
| [`Time — horloges, ISO et durées`](modules/time.md) | Temps réel et monotone, sommeil, formatage/parsing ISO-8601, parsing et rendu de durées. |
| [`TLS — connexions chiffrées`](modules/tls.md) | Connexion TLS directe, STARTTLS, vérification, CA, hostname, SNI, versions, deadlines et comportement fail-closed. |
| [`TOML — fichiers de configuration`](modules/toml.md) | Décodage TOML, scalaires, tableaux, tables, tableaux de tables, dates/heures et diagnostics. |
| [`USER - utilisateurs système via NSS`](modules/user.md) | Recherche par nom ou UID, existence, distinction absence/erreur NSS, champs passwd, workers et limites de sécurité. |
| [`WORKERS — threads OS et files de messages`](modules/workers.md) | États Lua isolés, transport JSON, résultat consommable, `poll`/`join`, inbox/outbox, timeouts, fermeture, GC et pièges d'interblocage. |

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
