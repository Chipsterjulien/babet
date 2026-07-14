// =====================================================================
// inotify.hpp — bindings Lua pour inotify(7) (surveillance de FS Linux)
// =====================================================================
//
// Expose la sous-table babet.inotify avec une fonction fabrique :
//
//   babet.inotify.new() -> watcher | (nil, err)
//     Crée une instance inotify (un FD noyau). Erreur runtime
//     (EMFILE/ENFILE = trop de FD/instances) -> (nil, err).
//
// Méthodes du userdata watcher (métatable "LuapilotInotify") :
//
//   w:add(path, events [, opts]) -> wd | (nil, err)
//     Pose une surveillance sur `path`. `events` est une LISTE
//     OBLIGATOIRE et non vide de noms d'événements (array de strings).
//     `opts` (table optionnelle) accepte `onlydir` (booléen strict),
//     qui ajoute IN_ONLYDIR. Les autres champs sont ignorés. Renvoie
//     le watch descriptor (integer) en succès.
//
//   w:read([timeout]) -> events | (nil, "timeout")
//                              | (nil, "interrupted")
//                              | (nil, err)
//     Lit les événements en attente. `timeout` en secondes (float) ;
//     absent/nil = bloquant infini. Renvoie un ARRAY d'événements
//     batchés (le noyau en groupe plusieurs par read()).
//
//   w:remove(wd) -> (true, nil) | (nil, err)
//     Retire une surveillance par son watch descriptor. Le noyau
//     émet un événement `ignored` pour ce wd juste après.
//
//   w:close() -> (true, nil)
//     Ferme le FD inotify. Idempotent. Filet __gc si oublié.
//
// ---------------------------------------------------------------------
// Décisions actées (toutes observables)
// ---------------------------------------------------------------------
//
//   INOT-A  Non-récursif en v1. inotify(7) lui-même ne l'est pas :
//           un watch = un répertoire (ou un fichier), jamais un
//           sous-arbre. La récursion propre (tree-walk + ajout
//           dynamique de watches sur création de sous-dossier +
//           gestion fine de l'overflow) est un vrai chantier de
//           design, reporté — constructible en Lua pur par-dessus.
//   INOT-B  Liste d'événements OBLIGATOIRE et explicite dans add().
//           Pas d'implicite « tout » : ça inonderait la queue.
//           Esprit « pas de comportement silencieux » du projet.
//   INOT-C  read() pilote le blocage via poll() sur un FD ouvert en
//           IN_NONBLOCK (même modèle que socket : poll + read).
//           Cela donne timeout ET interruption signal gratuitement,
//           via la même mécanique wait_ready_deadline / signal.
//   INOT-D  Overflow (IN_Q_OVERFLOW) REMONTÉ EXPLICITEMENT via un
//           événement { events = { overflow = true }, wd = -1 }.
//           Jamais avalé : c'est le seul cas où inotify perd
//           silencieusement des événements, donc le seul moment où
//           le script DOIT savoir qu'il faut rescanner.
//   INOT-E  POSIX/Linux direct, zéro dépendance externe (comme
//           socket et signal). Babet assume déjà d'être Linux-only.
//   INOT-F  IN_CLOEXEC sur le FD inotify : pas d'héritage par les
//           sous-processus de babet.exec (même rationale que les
//           sockets, cf. socket.cpp).
//
// ---------------------------------------------------------------------
// Forme d'un événement (table renvoyée dans l'array de read())
// ---------------------------------------------------------------------
//
//   {
//     wd     = 1,                       -- watch descriptor d'origine (-1 si overflow)
//     name   = "photo.jpg",             -- entrée concernée ("" si la cible elle-même)
//     events = { close_write = true },  -- masque décodé en flags lisibles
//     is_dir = false,                   -- IN_ISDIR
//     cookie = 0,                       -- != 0 pour apparier moved_from / moved_to
//   }
//
// ---------------------------------------------------------------------
// Conventions d'erreur (miroir de socket / http / toml)
// ---------------------------------------------------------------------
//
//   - Mauvais NOMBRE/TYPE d'argument  -> luaL_error (raise).
//   - Mauvaise VALEUR / erreur runtime -> (nil, err).
//   - Action réussie (remove/close)    -> (true, nil).
//   - Nom d'événement inconnu dans add() -> (nil, err) (miroir de la
//     « méthode HTTP inconnue » de http, qui renvoie (nil, err)).
//
// ---------------------------------------------------------------------
// Interruption par signal
// ---------------------------------------------------------------------
//
// Comme socket:recv et babet.sleep : si un signal géré par
// babet.signal arrive pendant un w:read() bloquant, l'appel
// renvoie immédiatement (nil, "interrupted") et le callback Lua
// s'exécute avant le retour. Permet d'arrêter proprement un watcher
// de longue durée sur SIGTERM sans attendre l'expiration du timeout.
//
// ---------------------------------------------------------------------
// Hors v1 (additif plus tard sous SemVer)
// ---------------------------------------------------------------------
//
//   - Surveillance récursive (cf. INOT-A).
//   - Modifieurs add() supplémentaires : dont_follow (IN_DONT_FOLLOW),
//     oneshot (IN_ONESHOT), mask_add (IN_MASK_ADD). Ajoutables sans
//     casser le contrat ; v1 expose le minimum utile (onlydir).
//   - fanotify (surveillance à l'échelle d'un montage, nécessite
//     CAP_SYS_ADMIN) — autre API, autre cas d'usage.

#ifndef LUA_BINDINGS_INOTIFY_HPP
#define LUA_BINDINGS_INOTIFY_HPP

struct lua_State;

// Crée la sous-table babet.inotify (fonction `new`) et pose la
// métatable "LuapilotInotify" dans le registry Lua (méthodes add/
// read/remove/close + __gc).
//
// Précondition de pile : la table babet est au sommet (-1), comme
// register_socket / register_signal / register_sqlite.
// Postcondition : la pile est inchangée (la sous-table est posée
// comme champ "inotify" de babet).
void register_inotify(lua_State *L);

#endif // LUA_BINDINGS_INOTIFY_HPP
