// =====================================================================
// sqlite.hpp — bindings Lua pour SQLite 3 (amalgamation embarquée)
// =====================================================================
//
// Expose la sous-table babet.sqlite avec une API haut niveau :
//
//   db, err = babet.sqlite.open(path, opts?)
//   ok, err = db:exec(sql, params?)
//   for row in db:query(sql, params?) do ... end
//   ok, err = db:close()
//
// Le userdata "db" est un handle vers une connexion SQLite. Il est
// automatiquement fermé par __gc s'il n'est pas explicitement close().
//
// ---------------------------------------------------------------------
// Design V1 (figé pour cette release)
// ---------------------------------------------------------------------
//
// Style :  haut niveau seulement (pas de prepare/bind/step/finalize
//          exposés en V1). Les prepared statements sont créés et
//          libérés en interne à chaque exec/query.
//
// Types en lecture :
//          NULL → clé absente de la table Lua
//          INTEGER → integer Lua
//          REAL → number Lua (float)
//          TEXT / BLOB → string Lua (binary-safe)
// Types en bind : bool → INTEGER 0/1, integer/float → numérique SQLite,
//                 string Lua → TEXT (jamais BLOB en V1).
//
// Erreurs : les erreurs opérationnelles de open/exec/query/close sont
//           renvoyées sous forme (nil, "sqlite: <msg>"). Les mauvais
//           types, les tables params invalides et les erreurs survenant
//           pendant l'itération lèvent une erreur Lua.
//
// Options open :
//   wal           : bool (par défaut false) — demande journal_mode=WAL
//   busy_timeout  : int 0..3600000 ms (par défaut 0)
//
// Concurrence : aucun lock Babet global. SQLite gère ses propres
//   verrous fichier. Mode WAL recommandé pour multi-readers + 1 writer.
//   Pour multi-workers qui écrivent : pattern "1 worker = DB-owner".
//   Voir README pour les détails.

#ifndef LUA_BINDINGS_SQLITE_HPP
#define LUA_BINDINGS_SQLITE_HPP

struct lua_State;

// Crée la sous-table babet.sqlite avec les fonctions exposées.
// Précondition de pile : la table babet est au sommet.
// Postcondition : pile inchangée (la sous-table est posée comme
// champ "sqlite" de babet).
void register_sqlite(lua_State *L);

#endif // LUA_BINDINGS_SQLITE_HPP
