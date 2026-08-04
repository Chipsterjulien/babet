// =====================================================================
// sqlite.hpp — bindings Lua pour SQLite 3 (amalgamation embarquée)
// =====================================================================
//
// Expose la sous-table babet.sqlite avec une API haut niveau :
//
//   db, err = babet.sqlite.open(path, opts?)
//   blob = babet.sqlite.blob(data)
//   ok, err = db:exec(sql, params?)
//   for row in db:query(sql, params?) do ... end
//   stmt, err = db:prepare(sql)
//   rowid, err = db:last_insert_rowid()
//   count, err = db:changes()
//   total, err = db:total_changes()
//   ok, err = stmt:exec(params?)
//   for row in stmt:query(params?) do ... end
//   ok, result = db:transaction(function(tx) ... end, mode?)
//   ok, result = db:savepoint(function(tx) ... end)
//   ok, err = db:close()
//
// Le userdata "db" est un handle vers une connexion SQLite. Il est
// automatiquement fermé par __gc s'il n'est pas explicitement close().
//
// ---------------------------------------------------------------------
// Contrats principaux
// ---------------------------------------------------------------------
//
// Les chaînes Lua ordinaires sont bindées comme TEXT. Le wrapper
// babet.sqlite.blob(data) force un bind BLOB binary-safe.
// babet.sqlite.NULL est un lightuserdata privé accepté uniquement comme
// valeur de bind explicite pour SQL NULL.
//
// db:query() crée un itérateur temporaire à usage unique. db:prepare()
// crée un statement réutilisable avec exec/query/reset/finalize.
//
// db:transaction(callback, mode?) exécute BEGIN/COMMIT et rollback sur
// erreur Lua du callback. Un retour normal nil/false reste un succès.
// db:savepoint(callback) utilise un nom interne, accepte l'imbrication et
// exécute ROLLBACK TO puis RELEASE sur erreur Lua du callback.
//
// Types en lecture :
//          NULL → clé absente de la table Lua
//          INTEGER → integer Lua
//          REAL → number Lua (float)
//          TEXT / BLOB → string Lua (binary-safe)
//
// Options open :
//   wal           : bool (par défaut false) — demande journal_mode=WAL
//   busy_timeout  : int 0..3600000 ms (par défaut 0)
//   readonly      : bool (par défaut false) — aucune création/écriture
//   foreign_keys  : bool (par défaut false) — intégrité référentielle
//
// Concurrence : aucun lock Babet global. SQLite gère ses propres
// verrous fichier. Mode WAL recommandé pour multi-readers + 1 writer.

#ifndef LUA_BINDINGS_SQLITE_HPP
#define LUA_BINDINGS_SQLITE_HPP

struct lua_State;

// Crée la sous-table babet.sqlite avec les fonctions exposées.
// Précondition de pile : la table babet est au sommet.
// Postcondition : pile inchangée (la sous-table est posée comme
// champ "sqlite" de babet).
void register_sqlite(lua_State *L);

// Reconnaît la sentinelle par identité exacte. Ce helper permet aux autres
// modules de la refuser avec un diagnostic stable sans exposer son adresse.
bool is_sqlite_null(lua_State *L, int idx) noexcept;

#endif // LUA_BINDINGS_SQLITE_HPP
