// =====================================================================
// sqlite.cpp — implémentation des bindings SQLite
// =====================================================================
// Implémente open / close / exec / query, le bind des paramètres,
// l'itérateur paresseux de lignes et le mapping des types.
//
// Voir sqlite.hpp pour le contrat public.

#include "sqlite.hpp"
#include "lua_utils.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include "sqlite3.h"

#include <climits>
#include <cstdio>
#include <cstring>
#include <new>
#include <set>
#include <string>

namespace
{

    // ============================================================
    // Userdata Db : handle vers une connexion SQLite
    // ============================================================
    //
    // Le userdata Lua contient un Db par valeur (pas un pointeur),
    // créé via lua_newuserdata + placement new.
    //
    // Quand le user appelle db:close(), on ferme sqlite3 et on
    // positionne handle = nullptr. Toute opération ultérieure
    // retourne (nil, "sqlite: connection closed").
    //
    // À la fin, le __gc Lua appelle Db::~Db qui ferme handle s'il
    // n'a pas été closé explicitement. Cohérent avec le pattern Sock
    // dans socket.cpp.

    struct Db
    {
        sqlite3 *handle;
        bool transaction_helper_active;

        Db() : handle(nullptr), transaction_helper_active(false) {}
        ~Db()
        {
            if (handle)
            {
                // sqlite3_close_v2 est la variante "tolérante" : elle
                // marque la connexion comme zombie si un itérateur query
                // possède encore un statement actif, puis libère réellement
                // le handle quand le dernier statement est finalisé.
                sqlite3_close_v2(handle);
                handle = nullptr;
            }
        }
    };

    // Métaclé du userdata Db. L'adresse de cette variable sert d'ID
    // unique dans le registre Lua (idiome standard).
    const char *DB_MT = "babet.sqlite.db";

    Db *check_db(lua_State *L, int idx)
    {
        return static_cast<Db *>(luaL_checkudata(L, idx, DB_MT));
    }

    // ============================================================
    // Helpers d'erreur
    // ============================================================

    // Pose (nil, "sqlite: <msg>") sur la pile et renvoie 2 (nombre
    // de valeurs Lua à retourner). Cohérent avec le contrat Babet.
    int push_sqlite_fail(lua_State *L, const std::string &msg)
    {
        std::string full = "sqlite: ";
        full += msg;
        return push_fail(L, full);
    }

    // SQLite's prepare APIs take an int byte count and still treat the first
    // NUL as the end of the SQL text. Rejecting NUL avoids silently executing
    // only a prefix such as "SELECT 1\0; DROP TABLE ...". The INT_MAX guard
    // also prevents size_t -> int narrowing before sqlite3_prepare_v2().
    bool get_checked_sql(lua_State *L, int idx,
                         const char *&sql, size_t &sql_len,
                         std::string &error)
    {
        sql = lua_tolstring(L, idx, &sql_len);
        if (std::memchr(sql, '\0', sql_len) != nullptr)
        {
            error = "SQL text must not contain NUL byte";
            return false;
        }
        if (sql_len > static_cast<size_t>(INT_MAX))
        {
            error = "SQL text is too large (maximum INT_MAX bytes)";
            return false;
        }
        return true;
    }

    // Renvoie true lorsque le tail laissé par sqlite3_prepare_v2 ne
    // contient que des séparateurs autorisés : espaces, points-virgules
    // et commentaires SQL. Les commentaires `-- ...` vont jusqu'à la fin
    // de ligne ; les commentaires `/* ... */` sont traités comme des
    // blancs, y compris s'ils se terminent avec la fin de la chaîne.
    // Toute autre donnée signifie qu'un second statement est présent.
    bool sql_tail_is_empty(const char *tail)
    {
        if (tail == nullptr)
        {
            return true;
        }

        const char *p = tail;
        for (;;)
        {
            while (*p == ' ' || *p == '\t' || *p == '\n' ||
                   *p == '\r' || *p == '\f' || *p == '\v' ||
                   *p == ';')
            {
                ++p;
            }

            if (*p == '\0')
            {
                return true;
            }

            if (p[0] == '-' && p[1] == '-')
            {
                p += 2;
                while (*p != '\0' && *p != '\n' && *p != '\r')
                {
                    ++p;
                }
                continue;
            }

            if (p[0] == '/' && p[1] == '*')
            {
                p += 2;
                while (*p != '\0' && !(p[0] == '*' && p[1] == '/'))
                {
                    ++p;
                }
                if (*p == '\0')
                {
                    return true;
                }
                p += 2;
                continue;
            }

            return false;
        }
    }

    // ============================================================
    // Parsing des opts pour open
    // ============================================================

    struct OpenOpts
    {
        bool wal;
        int busy_timeout_ms;

        OpenOpts() : wal(false), busy_timeout_ms(0) {}
    };

    // Lit opts depuis la pile (table à idx, ou nil/absent → defaults).
    // En cas d'option invalide, lance une erreur Lua (luaL_error).
    OpenOpts parse_open_opts(lua_State *L, int idx)
    {
        OpenOpts opts;
        int t = lua_type(L, idx);
        if (t == LUA_TNONE || t == LUA_TNIL)
        {
            return opts;
        }
        if (t != LUA_TTABLE)
        {
            luaL_error(L, "sqlite.open: opts must be a table or nil, got %s",
                       lua_typename(L, t));
        }

        // wal
        lua_getfield(L, idx, "wal");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(L, "sqlite.open: opts.wal must be a boolean");
            }
            opts.wal = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);

        // busy_timeout
        lua_getfield(L, idx, "busy_timeout");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_integer(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(L, "sqlite.open: opts.busy_timeout must be an integer (ms)");
            }
            lua_Integer v = lua_tointeger(L, -1);
            if (v < 0)
            {
                lua_pop(L, 1);
                luaL_error(L, "sqlite.open: opts.busy_timeout must be >= 0");
            }
            if (v > 60 * 60 * 1000) // 1h max, valeur sanity
            {
                lua_pop(L, 1);
                luaL_error(L, "sqlite.open: opts.busy_timeout too large (max 3600000 ms)");
            }
            opts.busy_timeout_ms = static_cast<int>(v);
        }
        lua_pop(L, 1);

        return opts;
    }

    // ============================================================
    // Méthodes du userdata Db
    // ============================================================

    // Vérifie si une table Lua ne contient aucune paire clé/valeur.
    // L'index est converti en index absolu car lua_next modifie la pile.
    bool lua_table_is_empty(lua_State *L, int idx)
    {
        idx = lua_absindex(L, idx);
        lua_pushnil(L);
        if (lua_next(L, idx) != 0)
        {
            lua_pop(L, 2); // value + key
            return false;
        }
        return true;
    }

    // ============================================================
    // Wrapper explicite BLOB
    // ============================================================
    //
    // Une chaîne Lua ordinaire reste bindée comme TEXT afin de préserver
    // le contrat historique. `babet.sqlite.blob(data)` crée un userdata
    // immuable qui demande explicitement sqlite3_bind_blob64().

    struct Blob
    {
        std::string data;

        Blob(const char *bytes, size_t len) : data(bytes, len) {}
        ~Blob() = default;
    };

    const char *BLOB_MT = "babet.sqlite.blob";

    Blob *test_blob(lua_State *L, int idx)
    {
        return static_cast<Blob *>(luaL_testudata(L, idx, BLOB_MT));
    }

    Blob *check_blob(lua_State *L, int idx)
    {
        return static_cast<Blob *>(luaL_checkudata(L, idx, BLOB_MT));
    }

    int sqlite_blob(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L, "sqlite.blob: expected exactly one argument");
        }
        luaL_checktype(L, 1, LUA_TSTRING);

        size_t len = 0;
        const char *bytes = lua_tolstring(L, 1, &len);
        Blob *blob = static_cast<Blob *>(lua_newuserdata(L, sizeof(Blob)));
        new (blob) Blob(bytes ? bytes : "", len);

        luaL_getmetatable(L, BLOB_MT);
        lua_setmetatable(L, -2);
        return 1;
    }

    int blob_gc(lua_State *L)
    {
        Blob *blob = check_blob(L, 1);
        blob->~Blob();
        return 0;
    }

    int blob_tostring(lua_State *L)
    {
        Blob *blob = check_blob(L, 1);
        char text[96];
        std::snprintf(text, sizeof(text),
                      "babet.sqlite.blob (%llu bytes)",
                      static_cast<unsigned long long>(blob->data.size()));
        lua_pushstring(L, text);
        return 1;
    }

    // ============================================================
    // Helpers de bind
    // ============================================================
    //
    // Le bind suit les contrats validés en design :
    //
    //   A. string Lua → TEXT (toujours). Pas de détection
    //      heuristique TEXT vs BLOB. Pour binder un BLOB strict,
    //      attendre une future API `babet.sqlite.blob(data)`.
    //
    //   B. SQL : '?', ':name', '@name', '$name' tous acceptés.
    //      Côté table Lua : clé sans préfixe (params.name pour
    //      :name / @name / $name).
    //
    //   C. Mélange positionnel + nommé autorisé.
    //
    //   D. function / table / userdata / thread → erreur Lua.
    //
    //   E. params absent ou nil → pas de bind (cohérent avec
    //      l'usage db:exec("BEGIN") sans params).
    //
    //   F. Paramètres manquants → erreur. Pas de NULL implicite.
    //
    // Limitation : impossible de binder explicitement NULL via la
    // table Lua (car { x = nil } est équivalent à {} en Lua). Pour
    // un NULL, utiliser un littéral SQL (NULL, COALESCE(?, NULL)).
    // À ajouter en V2 : sentinel `babet.sqlite.null` (idem json.null).

    // Bind une seule valeur Lua à un slot de prepared statement.
    // Convention de retour :
    //   true   → bind OK.
    //   false  → erreur (message dans `err`). Le caller doit
    //            finaliser le stmt avant de propager l'erreur.
    //
    // **Important** : on ne fait PAS luaL_error ici. Lua est
    // compilé en C dans Babet (via `make linux`), donc luaL_error
    // utilise longjmp pur qui ne déroule pas la pile C++. Tout
    // sqlite3_stmt en attente fuiterait. On signale l'erreur via
    // un bool + std::string, et db_exec finalise proprement avant
    // de raise.
    //
    // SQLITE_TRANSIENT : SQLite copie la string immédiatement. On ne
    // peut pas utiliser SQLITE_STATIC car les strings Lua peuvent
    // être collectées par le GC entre le bind et le step.
    bool bind_one_value(lua_State *L, sqlite3_stmt *stmt, int slot, int idx,
                        std::string &err)
    {
        int t = lua_type(L, idx);
        int rc = SQLITE_OK;
        switch (t)
        {
        case LUA_TNIL:
            // Ne devrait pas arriver (contrat F : caller détecte
            // missing en amont), mais on accepte tant pis et on
            // bind NULL.
            rc = sqlite3_bind_null(stmt, slot);
            break;
        case LUA_TBOOLEAN:
            rc = sqlite3_bind_int(stmt, slot, lua_toboolean(L, idx) ? 1 : 0);
            break;
        case LUA_TNUMBER:
            if (lua_is_strict_integer(L, idx))
            {
                rc = sqlite3_bind_int64(stmt, slot, lua_tointeger(L, idx));
            }
            else
            {
                rc = sqlite3_bind_double(stmt, slot, lua_tonumber(L, idx));
            }
            break;
        case LUA_TSTRING:
        {
            size_t len = 0;
            const char *s = lua_tolstring(L, idx, &len);
            if (len > static_cast<size_t>(0x7fffffff))
            {
                err = "string too large to bind at slot " +
                      std::to_string(slot);
                return false;
            }
            rc = sqlite3_bind_text(stmt, slot, s,
                                   static_cast<int>(len),
                                   SQLITE_TRANSIENT);
            break;
        }
        default:
            if (t == LUA_TUSERDATA)
            {
                if (Blob *blob = test_blob(L, idx))
                {
                    const char *data = blob->data.empty()
                                           ? ""
                                           : blob->data.data();
                    rc = sqlite3_bind_blob64(
                        stmt, slot, data,
                        static_cast<sqlite3_uint64>(blob->data.size()),
                        SQLITE_TRANSIENT);
                    break;
                }
            }

            // function / table / unrelated userdata / thread / lightuserdata.
            err = "cannot bind value of type '";
            err += lua_typename(L, t);
            err += "' at slot " + std::to_string(slot);
            return false;
        }
        if (rc != SQLITE_OK)
        {
            err = "bind failed at slot " + std::to_string(slot) +
                  ": " + sqlite3_errstr(rc);
            return false;
        }
        return true;
    }

    // Bind tous les paramètres du statement depuis la table à
    // params_idx. Implémente les contrats C, D, E, F.
    //
    // Algorithme :
    //   1. Inventorier les slots du statement (positionnels vs nommés).
    //   2. Pour chaque slot, récupérer la valeur dans la table :
    //      - Positionnel ('?') : params[N] où N est le rang d'apparition
    //        du '?' (1-based, comme convention Lua).
    //      - Nommé : params[name_sans_prefixe].
    //   3. Si une valeur manque (nil dans la table) → false (F).
    //   4. Vérifier qu'il n'y a pas de clés en trop dans la table
    //      (positionnels au-delà de N, noms inconnus) → false.
    //
    // Retour :
    //   true  → bind complet OK.
    //   false → erreur, message dans `err`. Le caller finalise le
    //           stmt avant de propager.
    bool bind_params_from_table(lua_State *L, sqlite3_stmt *stmt,
                                int params_idx, std::string &err)
    {
        int n_params = sqlite3_bind_parameter_count(stmt);

        // Inventorier les slots et collecter les noms requis.
        int positional_count = 0;
        std::set<std::string> required_names;
        for (int i = 1; i <= n_params; ++i)
        {
            const char *name = sqlite3_bind_parameter_name(stmt, i);
            if (name)
            {
                // name commence par :, @ ou $. On stocke sans préfixe.
                required_names.insert(name + 1);
            }
            else
            {
                positional_count++;
            }
        }

        // Binder slot par slot.
        int pos_seen = 0;
        for (int i = 1; i <= n_params; ++i)
        {
            const char *name = sqlite3_bind_parameter_name(stmt, i);
            if (name)
            {
                // Slot nommé : lookup params[name_sans_prefixe].
                lua_getfield(L, params_idx, name + 1);
                if (lua_isnil(L, -1))
                {
                    lua_pop(L, 1);
                    err = "missing param '";
                    err += name;
                    err += "'";
                    return false;
                }
                bool ok = bind_one_value(L, stmt, i, -1, err);
                lua_pop(L, 1);
                if (!ok)
                    return false;
            }
            else
            {
                // Slot positionnel : prendre le prochain index.
                ++pos_seen;
                lua_rawgeti(L, params_idx, pos_seen);
                if (lua_isnil(L, -1))
                {
                    lua_pop(L, 1);
                    err = "missing positional param at index " +
                          std::to_string(pos_seen);
                    return false;
                }
                bool ok = bind_one_value(L, stmt, i, -1, err);
                lua_pop(L, 1);
                if (!ok)
                    return false;
            }
        }

        // Vérifier les extras positionnels : params[pos_seen+1]
        // ne doit pas exister.
        lua_rawgeti(L, params_idx, pos_seen + 1);
        bool has_extra_pos = !lua_isnil(L, -1);
        lua_pop(L, 1);
        if (has_extra_pos)
        {
            err = "too many positional params (statement uses " +
                  std::to_string(positional_count) +
                  ", got at least " +
                  std::to_string(pos_seen + 1) + ")";
            return false;
        }

        // Vérifier les extras nommés ET les clés numériques sparse :
        // itérer sur toute la table, ignorer les clés numériques
        // dans la plage [1..pos_seen] (déjà consommées), refuser
        // tout le reste.
        //
        // Couvre :
        //   { "a", "b" } pour 1 slot  → "extra positional at 2"
        //   { "a", [10] = "x" } pour 1 slot → "extra positional at 10"
        //   { a = 1, zzz = "x" } pour :a → "extra named 'zzz'"
        //   { [1.5] = "x" }            → "non-integer numeric key"
        lua_pushnil(L); // first key
        while (lua_next(L, params_idx) != 0)
        {
            // -2 = key, -1 = value
            int kt = lua_type(L, -2);
            if (kt == LUA_TSTRING)
            {
                size_t key_len = 0;
                const char *key_data = lua_tolstring(L, -2, &key_len);
                std::string key(key_data, key_len);
                if (required_names.find(key) == required_names.end())
                {
                    err = "extra param '";
                    err.append(key_data, key_len);
                    err += "' (not used by this SQL)";
                    lua_pop(L, 2); // value + key
                    return false;
                }
            }
            else if (kt == LUA_TNUMBER)
            {
                if (!lua_is_strict_integer(L, -2))
                {
                    err = "params table has a non-integer numeric key";
                    lua_pop(L, 2);
                    return false;
                }
                lua_Integer idx = lua_tointeger(L, -2);
                if (idx < 1 || idx > pos_seen)
                {
                    err = "extra positional param at index " +
                          std::to_string(idx) +
                          " (statement uses " +
                          std::to_string(positional_count) + ")";
                    lua_pop(L, 2);
                    return false;
                }
            }
            // Autres types de clés (table, boolean...) : très rare et
            // sans signification ici. On les ignore silencieusement
            // plutôt que de raise pour rester pragmatique.
            // Pop value, keep key for next iteration.
            lua_pop(L, 1);
        }

        return true;
    }

    // ============================================================
    // db_exec : avec ou sans params, prepare+step statement par
    // statement (audit v21 : sqlite3_exec abandonné, cf. db_exec).
    // ============================================================

    // db:close() → (true, nil) | (nil, err)
    //
    // Idempotent : un second close() retourne (true, nil) sans rien
    // faire. Cohérent avec sock:close().
    int db_close(lua_State *L)
    {
        Db *db = check_db(L, 1);
        if (db->transaction_helper_active)
        {
            return push_sqlite_fail(
                L, "cannot close connection during transaction callback");
        }
        if (db->handle)
        {
            int rc = sqlite3_close_v2(db->handle);
            db->handle = nullptr;
            if (rc != SQLITE_OK)
            {
                // close_v2 ne devrait jamais échouer en pratique, mais
                // on retourne quand même l'info.
                return push_sqlite_fail(L, sqlite3_errstr(rc));
            }
        }
        return push_ok(L);
    }

    // db:exec(sql, params?) → (true, nil) | (nil, err)
    //
    // Sans params : boucle prepare/step statement par statement,
    //   avec garde anti-placeholder sur CHACUN. Supporte plusieurs
    //   statements séparés par ';' (utile pour CREATE TABLE ... ;
    //   CREATE INDEX ... d'un coup).
    //
    // Avec params : sqlite3_prepare_v2 + bind + step + finalize.
    //   Un SEUL statement supporté (pzTail non vide → erreur).
    //
    // Pour les SELECT, exec exécute mais ignore les résultats.
    // Utiliser db:query() pour lire les rows.
    int db_exec(lua_State *L)
    {
        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }

        // Strict : pas de coercion number→string. Cohérent avec
        // sqlite.open et toml.decode.
        luaL_checktype(L, 2, LUA_TSTRING);
        size_t sql_len = 0;
        const char *sql = nullptr;
        {
            std::string sql_error;
            if (!get_checked_sql(L, 2, sql, sql_len, sql_error))
            {
                return push_sqlite_fail(L, sql_error);
            }
        }

        // Détecter si on a des params : 3e argument fourni ET non-nil.
        // Si params est fourni mais pas une table → raise (cohérent
        // avec les autres APIs Babet).
        int top = lua_gettop(L);
        bool has_params = false;
        if (top >= 3 && !lua_isnil(L, 3))
        {
            luaL_checktype(L, 3, LUA_TTABLE);
            has_params = true;
        }

        // -------------------------------------------------------
        // Cas simple : pas de params → exécution statement par
        // statement, avec garde anti-placeholder sur CHACUN.
        //
        // Sans ce check, "INSERT INTO t VALUES (?)" sans params
        // bind silencieusement NULL — typiquement un bug de
        // copier-coller chez l'appelant qui insère du NULL
        // silencieusement. On préfère raise.
        //
        // CORRECTIF (audit v21) : l'ancienne version ne sondait que
        // le PREMIER statement (sqlite3_prepare_v2 s'arrête au
        // premier ';') puis relançait le tout via sqlite3_exec. Un
        // placeholder dans un statement SUIVANT
        // ("CREATE TABLE t(x); INSERT INTO t VALUES(?)") échappait
        // au garde-fou et sqlite3_exec liait NULL silencieusement —
        // exactement le bug que la sonde voulait empêcher.
        //
        // On ne peut pas non plus sonder tous les statements
        // d'avance : le 2e peut référencer une table créée par le
        // 1er (prepare rendrait "no such table" avant toute
        // exécution). La seule approche correcte est la boucle
        // prepare → check placeholders → step → finalize → avancer
        // sur le tail, qui remplace sqlite3_exec. Sémantique
        // conservée : exécution en ordre, arrêt à la première
        // erreur (les statements déjà exécutés restent acquis,
        // comme avec sqlite3_exec), lignes de SELECT ignorées
        // (comme sqlite3_exec avec callback nul).
        // -------------------------------------------------------
        if (!has_params)
        {
            const char *cursor = sql;
            const char *sql_end = sql + sql_len;
            while (cursor < sql_end)
            {
                sqlite3_stmt *stmt = nullptr;
                const char *tail = nullptr;
                int rc = sqlite3_prepare_v2(db->handle, cursor,
                                            static_cast<int>(sql_end - cursor),
                                            &stmt, &tail);
                if (rc != SQLITE_OK)
                {
                    std::string msg = sqlite3_errmsg(db->handle);
                    if (stmt)
                        sqlite3_finalize(stmt);
                    return push_sqlite_fail(L, msg);
                }
                if (!stmt)
                {
                    // Le reste n'est que blancs/commentaires. Garde
                    // anti-boucle : si le tail ne progresse pas, on
                    // sort (ne devrait pas arriver, ceinture).
                    if (tail == nullptr || tail <= cursor)
                        break;
                    cursor = tail;
                    continue;
                }

                if (sqlite3_bind_parameter_count(stmt) > 0)
                {
                    sqlite3_finalize(stmt);
                    return push_sqlite_fail(L,
                                            "SQL contains placeholders but no params table "
                                            "provided; pass params to bind, or remove "
                                            "placeholders from SQL");
                }

                while ((rc = sqlite3_step(stmt)) == SQLITE_ROW)
                {
                    // SELECT sans params : lignes ignorées, comme le
                    // faisait sqlite3_exec avec callback nul.
                }
                if (rc != SQLITE_DONE)
                {
                    std::string msg = sqlite3_errmsg(db->handle);
                    sqlite3_finalize(stmt);
                    return push_sqlite_fail(L, msg);
                }
                sqlite3_finalize(stmt);

                cursor = (tail != nullptr && tail > cursor) ? tail : sql_end;
            }
            return push_ok(L);
        }

        // -------------------------------------------------------
        // Cas avec params : prepare + bind + step + finalize.
        // -------------------------------------------------------
        sqlite3_stmt *stmt = nullptr;
        const char *pzTail = nullptr;
        int rc = sqlite3_prepare_v2(db->handle, sql,
                                    static_cast<int>(sql_len),
                                    &stmt, &pzTail);
        if (rc != SQLITE_OK)
        {
            std::string msg = sqlite3_errmsg(db->handle);
            if (stmt)
                sqlite3_finalize(stmt);
            return push_sqlite_fail(L, msg);
        }

        // Refuser le multi-statement avec params : pzTail doit être
        // soit nullptr, soit pointer sur du whitespace/commentaires
        // uniquement.
        if (!sql_tail_is_empty(pzTail))
        {
            sqlite3_finalize(stmt);
            return push_sqlite_fail(L,
                                    "exec with params supports only one statement; "
                                    "use exec(sql) without params for multi-statement SQL");
        }

        // Un SQL vide ou composé uniquement de séparateurs/commentaires
        // ne produit aucun sqlite3_stmt. Sans paramètres, exec est déjà un
        // no-op réussi ; avec une table vide, on conserve la même sémantique.
        // Une table non vide reste une erreur de programmation explicite.
        if (!stmt)
        {
            if (!lua_table_is_empty(L, 3))
            {
                luaL_error(L,
                           "sqlite.exec: params table is not empty but SQL contains no statement");
            }
            return push_ok(L);
        }

        // Bind : retourne false + message si erreur. Avant de raise
        // côté Lua il faut absolument finaliser le stmt (sinon leak,
        // car luaL_error fait un longjmp qui ne déroule pas la pile
        // C++ — Lua est compilé en C dans Babet).
        std::string bind_err;
        bool bind_ok = bind_params_from_table(L, stmt, 3, bind_err);
        if (!bind_ok)
        {
            sqlite3_finalize(stmt);
            // luaL_error fait un longjmp ; la std::string `bind_err`
            // serait encore vivante sur la pile et son heap fuirait
            // (le destructeur C++ n'est pas appelé). On copie le
            // message dans un buffer C local, on libère explicitement
            // le heap de bind_err via swap, puis seulement on raise.
            char err_msg[512];
            std::snprintf(err_msg, sizeof(err_msg),
                          "sqlite.exec: %s", bind_err.c_str());
            std::string().swap(bind_err); // libère le heap interne
            luaL_error(L, "%s", err_msg);
            // unreachable
        }

        // Exécuter le statement.
        int step_rc = sqlite3_step(stmt);

        // SQLITE_DONE : DML/DDL OK.
        // SQLITE_ROW : SELECT a renvoyé une ligne (on l'ignore en
        //   mode exec, comme avec sqlite3_exec sans callback).
        //   On boucle pour épuiser le statement, sinon le finalize
        //   serait incomplet sur des SELECT.
        while (step_rc == SQLITE_ROW)
        {
            step_rc = sqlite3_step(stmt);
        }

        if (step_rc != SQLITE_DONE)
        {
            std::string msg = sqlite3_errmsg(db->handle);
            sqlite3_finalize(stmt);
            return push_sqlite_fail(L, msg);
        }

        sqlite3_finalize(stmt);
        return push_ok(L);
    }

    // __gc : ferme automatiquement la DB si pas déjà close().
    int db_gc(lua_State *L)
    {
        Db *db = check_db(L, 1);
        db->~Db();
        return 0;
    }

    // __tostring : utile pour le debug. Affiche l'état de la
    // connexion.
    int db_tostring(lua_State *L)
    {
        Db *db = check_db(L, 1);
        if (db->handle)
        {
            lua_pushfstring(L, "babet.sqlite.db (open, %p)", db->handle);
        }
        else
        {
            lua_pushliteral(L, "babet.sqlite.db (closed)");
        }
        return 1;
    }

    // ============================================================
    // Userdata Stmt : itérateur pour db:query()
    // ============================================================
    //
    // Un Stmt encapsule un sqlite3_stmt prêt à itérer. Il est
    // callable (métatable __call) ce qui permet l'idiome Lua :
    //
    //   for row in db:query("SELECT ...", { ... }) do ... end
    //
    // À chaque appel, sqlite3_step est invoqué :
    //   SQLITE_ROW  → extrait la ligne en table dict {col=val, ...},
    //                 returne la table.
    //   SQLITE_DONE → finalize maintenant pour libérer les ressources
    //                 tôt, retourne nil (signal de fin pour for-loop).
    //   erreur      → finalize, puis luaL_error pour propager.
    //
    // Le Stmt est aussi finalize par __gc en cas de break, exception,
    // ou simple oubli de l'itérateur (GC du Lua qui ramasse l'iter).
    //
    // ---------------------------------------------------------------
    // Lifetime vs Db
    // ---------------------------------------------------------------
    //
    // Un Stmt ne référence pas explicitement son Db parent. C'est
    // possible parce que sqlite3_close_v2 (utilisé dans db_close et
    // Db::~Db) ne libère pas vraiment le handle SQLite tant qu'il y
    // a un sqlite3_stmt actif — il marque le handle "zombie" et le
    // libère quand le dernier stmt est finalize.
    //
    // Conséquence pratique : si le user fait `db:close()` puis
    // continue à appeler `iter()`, ça marche (le handle est zombie
    // mais le stmt est encore valide). C'est le comportement SQLite
    // natif, documenté dans README.

    struct Stmt
    {
        sqlite3_stmt *handle;

        Stmt() : handle(nullptr) {}
        ~Stmt()
        {
            if (handle)
            {
                sqlite3_finalize(handle);
                handle = nullptr;
            }
        }
    };

    const char *STMT_MT = "babet.sqlite.stmt";

    Stmt *check_stmt(lua_State *L, int idx)
    {
        return static_cast<Stmt *>(luaL_checkudata(L, idx, STMT_MT));
    }

    // Extrait la row courante (après SQLITE_ROW) en table dict.
    // NULL → la clé n'est pas posée (pas de sentinel V1).
    //
    // **Comportement documenté** : les colonnes SQL NULL disparaissent
    // de la table Lua, car une table Lua ne peut pas stocker `nil`.
    //   - `row.col == nil` fonctionne toujours.
    //   - `pairs(row)` ne verra pas les colonnes NULL.
    // Pour distinguer "colonne NULL" de "colonne inexistante", il
    // faudrait un sentinel `babet.sqlite.null`. TODO V2 si besoin
    // concret apparaît.
    //
    // Colonnes dupliquées (SELECT a, a FROM t) : la deuxième écrase
    // la première dans la table dict. SQLite ne détecte pas ça lors
    // du prepare, donc on ne peut rien faire de mieux. Documenté.
    void extract_row(lua_State *L, sqlite3_stmt *stmt)
    {
        int n_cols = sqlite3_column_count(stmt);
        lua_createtable(L, 0, n_cols);

        for (int i = 0; i < n_cols; ++i)
        {
            const char *col_name = sqlite3_column_name(stmt, i);
            if (!col_name)
            {
                // sqlite3_column_name peut renvoyer NULL en cas d'OOM.
                // On skippe la colonne plutôt que de raise.
                continue;
            }

            int t = sqlite3_column_type(stmt, i);
            switch (t)
            {
            case SQLITE_NULL:
                // Skip : la clé reste absente de la table Lua.
                continue;
            case SQLITE_INTEGER:
                lua_pushinteger(L, sqlite3_column_int64(stmt, i));
                break;
            case SQLITE_FLOAT:
                lua_pushnumber(L, sqlite3_column_double(stmt, i));
                break;
            case SQLITE_TEXT:
            {
                // CORRECTIF (revue Gemini post-audit v21) : la doc
                // SQLite exige d'appeler column_text/column_blob
                // AVANT column_bytes (une conversion peut modifier la
                // longueur). Ici le type brut est déjà vérifié donc
                // aucune conversion n'avait lieu en pratique — ordre
                // corrigé pour la pureté sémantique et la robustesse
                // aux évolutions.
                const unsigned char *text = sqlite3_column_text(stmt, i);
                int len = sqlite3_column_bytes(stmt, i);
                if (len == 0 || text == nullptr)
                {
                    // sqlite3_column_text() peut retourner NULL pour
                    // un TEXT de 0 octet (même cas que BLOB ci-dessous).
                    // lua_pushlstring(L, NULL, 0) est UB selon la doc
                    // Lua, on pousse explicitement une string vide.
                    lua_pushliteral(L, "");
                }
                else
                {
                    lua_pushlstring(L,
                                    reinterpret_cast<const char *>(text),
                                    static_cast<size_t>(len));
                }
                break;
            }
            case SQLITE_BLOB:
            {
                // Même ordre pointeur-puis-longueur que TEXT ci-dessus.
                const void *blob = sqlite3_column_blob(stmt, i);
                int len = sqlite3_column_bytes(stmt, i);
                if (len == 0 || blob == nullptr)
                {
                    // sqlite3_column_blob() peut retourner NULL pour
                    // un BLOB de 0 octets. lua_pushlstring(L, NULL, 0)
                    // est UB selon la doc Lua, même si la plupart des
                    // implémentations le tolèrent. Mieux : pousser
                    // explicitement une string vide.
                    lua_pushliteral(L, "");
                }
                else
                {
                    lua_pushlstring(L,
                                    static_cast<const char *>(blob),
                                    static_cast<size_t>(len));
                }
                break;
            }
            default:
                // SQLite n'a que 5 types ; ce default est défensif.
                continue;
            }

            lua_setfield(L, -2, col_name);
        }
    }

    // Appelé via __call quand la boucle `for row in stmt do` itère.
    // Retourne la prochaine row ou nil pour signaler la fin.
    int stmt_call(lua_State *L)
    {
        Stmt *s = check_stmt(L, 1);
        if (!s->handle)
        {
            // Stmt déjà finalize : fin de l'itération.
            lua_pushnil(L);
            return 1;
        }

        int rc = sqlite3_step(s->handle);
        if (rc == SQLITE_DONE)
        {
            // Fin naturelle. Finalize dès maintenant pour libérer
            // les ressources tôt (libère le verrou DB, le handle
            // zombie si db_close avait été appelé, etc.). __gc le
            // ferait aussi mais peut-être beaucoup plus tard.
            sqlite3_finalize(s->handle);
            s->handle = nullptr;
            lua_pushnil(L);
            return 1;
        }
        if (rc == SQLITE_ROW)
        {
            extract_row(L, s->handle);
            return 1;
        }

        // Erreur runtime pendant l'itération. On récupère le handle
        // SQLite via sqlite3_db_handle (depuis le stmt), pour ne pas
        // dépendre du Db userdata (qui peut être close).
        std::string msg = sqlite3_errmsg(sqlite3_db_handle(s->handle));
        sqlite3_finalize(s->handle);
        s->handle = nullptr;

        // Pas de (nil, err) ici : le contrat `for row in ...` ne
        // permet pas de signaler une erreur en cours d'itération.
        // luaL_error est ce qui fait sens, et le user peut rattraper
        // avec pcall autour de la boucle.
        //
        // Même précaution que db_exec et db_query : luaL_error fait
        // un longjmp qui ne déroule pas la pile C++. La std::string
        // `msg` fuirait. On copie dans un buffer C local, on libère
        // le heap via swap, puis on raise.
        char err_msg[512];
        std::snprintf(err_msg, sizeof(err_msg),
                      "sqlite.query: step failed: %s", msg.c_str());
        std::string().swap(msg);
        luaL_error(L, "%s", err_msg);
        return 0; // unreachable
    }

    // stmt:close() → (true, nil)
    //
    // Idempotent. Permet de libérer les ressources tôt sans
    // attendre le GC, utile par exemple si on garde l'itérateur
    // dans une variable et qu'on veut s'assurer qu'il est libéré.
    int stmt_close(lua_State *L)
    {
        Stmt *s = check_stmt(L, 1);
        if (s->handle)
        {
            sqlite3_finalize(s->handle);
            s->handle = nullptr;
        }
        return push_ok(L);
    }

    int stmt_gc(lua_State *L)
    {
        Stmt *s = check_stmt(L, 1);
        s->~Stmt();
        return 0;
    }

    int stmt_tostring(lua_State *L)
    {
        Stmt *s = check_stmt(L, 1);
        if (s->handle)
        {
            lua_pushfstring(L, "babet.sqlite.stmt (active, %p)", s->handle);
        }
        else
        {
            lua_pushliteral(L, "babet.sqlite.stmt (closed)");
        }
        return 1;
    }

    // db:query(sql, params?) → stmt (callable iterator) | (nil, err)
    //
    // Prépare le SQL, bind les params si fournis, retourne un Stmt
    // callable. Une erreur de préparation renvoie (nil, err) ; une
    // table params invalide lève une erreur Lua après finalisation.
    //
    // Refuse le multi-statement même sans params : un SELECT itéré
    // multiple n'a pas de sens pour la boucle `for row in ...`.
    // Cohérent avec exec(sql, params).
    //
    // Erreurs runtime pendant le step : remontées via luaL_error
    // dans stmt_call (pas un (nil, err)).
    int db_query(lua_State *L)
    {
        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }

        luaL_checktype(L, 2, LUA_TSTRING);
        size_t sql_len = 0;
        const char *sql = nullptr;
        {
            std::string sql_error;
            if (!get_checked_sql(L, 2, sql, sql_len, sql_error))
            {
                return push_sqlite_fail(L, sql_error);
            }
        }

        int top = lua_gettop(L);
        bool has_params = false;
        if (top >= 3 && !lua_isnil(L, 3))
        {
            luaL_checktype(L, 3, LUA_TTABLE);
            has_params = true;
        }

        sqlite3_stmt *stmt = nullptr;
        const char *pzTail = nullptr;
        int rc = sqlite3_prepare_v2(db->handle, sql,
                                    static_cast<int>(sql_len),
                                    &stmt, &pzTail);
        if (rc != SQLITE_OK)
        {
            std::string msg = sqlite3_errmsg(db->handle);
            if (stmt)
                sqlite3_finalize(stmt);
            return push_sqlite_fail(L, msg);
        }

        // Refuser le multi-statement (avec ou sans params).
        if (!sql_tail_is_empty(pzTail))
        {
            sqlite3_finalize(stmt);
            return push_sqlite_fail(L,
                                    "query supports only one statement; "
                                    "use exec(sql) for multi-statement SQL");
        }

        // Un SQL vide ou uniquement composé de commentaires prépare
        // un statement nul : query renvoie alors un itérateur déjà épuisé.
        // Si une table params non vide a été fournie, elle ne doit pas être
        // ignorée silencieusement.
        if (!stmt)
        {
            if (has_params && !lua_table_is_empty(L, 3))
            {
                luaL_error(L,
                           "sqlite.query: params table is not empty but SQL contains no statement");
            }
        }
        // Si pas de params fournis mais le statement a des placeholders,
        // renvoyer une erreur plutôt que de binder NULL implicitement.
        else if (!has_params)
        {
            int n_placeholders = sqlite3_bind_parameter_count(stmt);
            if (n_placeholders > 0)
            {
                sqlite3_finalize(stmt);
                return push_sqlite_fail(L,
                                        "SQL contains placeholders but no params table "
                                        "provided; pass params to bind, or remove "
                                        "placeholders from SQL");
            }
        }

        if (has_params && stmt)
        {
            std::string bind_err;
            bool bind_ok = bind_params_from_table(L, stmt, 3, bind_err);
            if (!bind_ok)
            {
                sqlite3_finalize(stmt);
                // Même précaution que db_exec : libérer le heap de
                // bind_err avant le longjmp pour éviter la fuite.
                char err_msg[512];
                std::snprintf(err_msg, sizeof(err_msg),
                              "sqlite.query: %s", bind_err.c_str());
                std::string().swap(bind_err);
                luaL_error(L, "%s", err_msg);
                // unreachable
            }
        }

        // Allouer le userdata Stmt et lui transférer l'ownership
        // du sqlite3_stmt. À partir d'ici, le Stmt::~Stmt() (ou
        // un finalize explicite dans stmt_call/stmt_close) prend
        // en charge le cleanup.
        Stmt *s = static_cast<Stmt *>(lua_newuserdata(L, sizeof(Stmt)));
        new (s) Stmt();
        s->handle = stmt;

        luaL_getmetatable(L, STMT_MT);
        lua_setmetatable(L, -2);

        return 1;
    }


    // ============================================================
    // Statements préparés réutilisables
    // ============================================================

    struct Prepared
    {
        sqlite3_stmt *handle;
        bool query_active;

        Prepared() : handle(nullptr), query_active(false) {}
        ~Prepared()
        {
            if (handle)
            {
                sqlite3_finalize(handle);
                handle = nullptr;
            }
        }
    };

    const char *PREPARED_MT = "babet.sqlite.prepared";

    Prepared *check_prepared(lua_State *L, int idx)
    {
        return static_cast<Prepared *>(
            luaL_checkudata(L, idx, PREPARED_MT));
    }

    int push_prepared_closed(lua_State *L)
    {
        return push_sqlite_fail(L, "statement closed");
    }

    // Replace all prior execution state with a clean statement ready for a
    // new bind. sqlite3_reset() returns the previous step error even though
    // it still resets the statement, so automatic reuse intentionally ignores
    // that return code and reports errors at the step that caused them.
    bool prepared_clear_for_reuse(sqlite3_stmt *stmt, std::string &err)
    {
        sqlite3_reset(stmt);
        int rc = sqlite3_clear_bindings(stmt);
        if (rc != SQLITE_OK)
        {
            err = "clear bindings failed: ";
            err += sqlite3_errstr(rc);
            return false;
        }
        return true;
    }

    enum class PreparedBindStatus
    {
        Ok,
        OperationalError,
        ProgrammerError,
    };

    // Bind params for prepared:exec/query without raising. This matters because
    // Lua is built as C and luaL_error uses longjmp: every owning C++ object
    // must leave scope normally before the caller raises a programmer error.
    PreparedBindStatus prepared_bind_for_use(lua_State *L,
                                               sqlite3_stmt *stmt,
                                               int params_idx,
                                               bool has_params,
                                               std::string &error)
    {
        if (!has_params)
        {
            if (sqlite3_bind_parameter_count(stmt) > 0)
            {
                error =
                    "SQL contains placeholders but no params table provided; "
                    "pass params to bind, or remove placeholders from SQL";
                return PreparedBindStatus::OperationalError;
            }
            return PreparedBindStatus::Ok;
        }

        if (!bind_params_from_table(L, stmt, params_idx, error))
        {
            sqlite3_reset(stmt);
            sqlite3_clear_bindings(stmt);
            return PreparedBindStatus::ProgrammerError;
        }
        return PreparedBindStatus::Ok;
    }

    // db:prepare(sql) -> prepared | (nil, err)
    int db_prepare(lua_State *L)
    {
        if (!lua_arity_is(L, 2))
        {
            return luaL_error(L,
                              "sqlite.prepare: expected db and one SQL string");
        }

        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }

        luaL_checktype(L, 2, LUA_TSTRING);
        size_t sql_len = 0;
        const char *sql = nullptr;
        {
            std::string sql_error;
            if (!get_checked_sql(L, 2, sql, sql_len, sql_error))
            {
                return push_sqlite_fail(L, sql_error);
            }
        }

        sqlite3_stmt *stmt = nullptr;
        const char *tail = nullptr;
        int rc = sqlite3_prepare_v2(db->handle, sql,
                                    static_cast<int>(sql_len),
                                    &stmt, &tail);
        if (rc != SQLITE_OK)
        {
            std::string msg = sqlite3_errmsg(db->handle);
            if (stmt)
            {
                sqlite3_finalize(stmt);
            }
            return push_sqlite_fail(L, msg);
        }

        if (!sql_tail_is_empty(tail))
        {
            sqlite3_finalize(stmt);
            return push_sqlite_fail(
                L, "prepare supports only one statement");
        }
        if (!stmt)
        {
            return push_sqlite_fail(
                L, "prepare requires one non-empty SQL statement");
        }

        Prepared *prepared = static_cast<Prepared *>(
            lua_newuserdata(L, sizeof(Prepared)));
        new (prepared) Prepared();
        prepared->handle = stmt;

        luaL_getmetatable(L, PREPARED_MT);
        lua_setmetatable(L, -2);
        return 1;
    }

    // prepared:exec(params?) -> (true, nil) | (nil, err)
    int prepared_exec(lua_State *L)
    {
        int top = lua_gettop(L);
        if (top < 1 || top > 2)
        {
            return luaL_error(
                L, "sqlite prepared exec: expected self and optional params");
        }

        Prepared *prepared = check_prepared(L, 1);
        if (!prepared->handle)
        {
            return push_prepared_closed(L);
        }
        prepared->query_active = false;

        bool has_params = top == 2 && !lua_isnil(L, 2);
        if (has_params)
        {
            luaL_checktype(L, 2, LUA_TTABLE);
        }

        char programmer_error[512] = {};
        {
            std::string error;
            if (!prepared_clear_for_reuse(prepared->handle, error))
            {
                return push_sqlite_fail(L, error);
            }

            PreparedBindStatus status = prepared_bind_for_use(
                L, prepared->handle, 2, has_params, error);
            if (status == PreparedBindStatus::OperationalError)
            {
                return push_sqlite_fail(L, error);
            }
            if (status == PreparedBindStatus::ProgrammerError)
            {
                std::snprintf(programmer_error,
                              sizeof(programmer_error),
                              "sqlite prepared exec: %s",
                              error.c_str());
            }
        }
        if (programmer_error[0] != '\0')
        {
            return luaL_error(L, "%s", programmer_error);
        }

        int rc = sqlite3_step(prepared->handle);
        while (rc == SQLITE_ROW)
        {
            rc = sqlite3_step(prepared->handle);
        }

        if (rc != SQLITE_DONE)
        {
            std::string msg = sqlite3_errmsg(
                sqlite3_db_handle(prepared->handle));
            sqlite3_reset(prepared->handle);
            sqlite3_clear_bindings(prepared->handle);
            return push_sqlite_fail(L, msg);
        }

        sqlite3_reset(prepared->handle);
        sqlite3_clear_bindings(prepared->handle);
        return push_ok(L);
    }

    // prepared:query(params?) -> self | (nil, err)
    // The returned userdata is callable and remains reusable after exhaustion.
    int prepared_query(lua_State *L)
    {
        int top = lua_gettop(L);
        if (top < 1 || top > 2)
        {
            return luaL_error(
                L, "sqlite prepared query: expected self and optional params");
        }

        Prepared *prepared = check_prepared(L, 1);
        if (!prepared->handle)
        {
            return push_prepared_closed(L);
        }
        prepared->query_active = false;

        bool has_params = top == 2 && !lua_isnil(L, 2);
        if (has_params)
        {
            luaL_checktype(L, 2, LUA_TTABLE);
        }

        char programmer_error[512] = {};
        {
            std::string error;
            if (!prepared_clear_for_reuse(prepared->handle, error))
            {
                return push_sqlite_fail(L, error);
            }

            PreparedBindStatus status = prepared_bind_for_use(
                L, prepared->handle, 2, has_params, error);
            if (status == PreparedBindStatus::OperationalError)
            {
                return push_sqlite_fail(L, error);
            }
            if (status == PreparedBindStatus::ProgrammerError)
            {
                std::snprintf(programmer_error,
                              sizeof(programmer_error),
                              "sqlite prepared query: %s",
                              error.c_str());
            }
        }
        if (programmer_error[0] != '\0')
        {
            return luaL_error(L, "%s", programmer_error);
        }

        prepared->query_active = true;
        lua_settop(L, 1);
        return 1;
    }

    // __call used by `for row in prepared:query(params) do ... end`.
    int prepared_call(lua_State *L)
    {
        Prepared *prepared = check_prepared(L, 1);
        if (!prepared->handle || !prepared->query_active)
        {
            lua_pushnil(L);
            return 1;
        }

        int rc = sqlite3_step(prepared->handle);
        if (rc == SQLITE_ROW)
        {
            extract_row(L, prepared->handle);
            return 1;
        }
        if (rc == SQLITE_DONE)
        {
            sqlite3_reset(prepared->handle);
            sqlite3_clear_bindings(prepared->handle);
            prepared->query_active = false;
            lua_pushnil(L);
            return 1;
        }

        char err_msg[512];
        {
            std::string msg = sqlite3_errmsg(
                sqlite3_db_handle(prepared->handle));
            sqlite3_reset(prepared->handle);
            sqlite3_clear_bindings(prepared->handle);
            prepared->query_active = false;
            std::snprintf(err_msg, sizeof(err_msg),
                          "sqlite prepared query: step failed: %s",
                          msg.c_str());
        }
        luaL_error(L, "%s", err_msg);
        return 0;
    }

    // prepared:reset() -> (true, nil) | (nil, err)
    int prepared_reset(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L,
                              "sqlite prepared reset: expected only self");
        }
        Prepared *prepared = check_prepared(L, 1);
        if (!prepared->handle)
        {
            return push_prepared_closed(L);
        }
        prepared->query_active = false;

        int reset_rc = sqlite3_reset(prepared->handle);
        int clear_rc = sqlite3_clear_bindings(prepared->handle);
        if (clear_rc != SQLITE_OK)
        {
            return push_sqlite_fail(
                L, std::string("clear bindings failed: ") +
                       sqlite3_errstr(clear_rc));
        }
        if (reset_rc != SQLITE_OK)
        {
            return push_sqlite_fail(
                L, std::string("reset reported previous step error: ") +
                       sqlite3_errstr(reset_rc));
        }
        return push_ok(L);
    }

    // prepared:close()/finalize() -> (true, nil), idempotent.
    int prepared_close(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L,
                              "sqlite prepared close: expected only self");
        }
        Prepared *prepared = check_prepared(L, 1);
        prepared->query_active = false;
        if (prepared->handle)
        {
            int rc = sqlite3_finalize(prepared->handle);
            prepared->handle = nullptr;
            if (rc != SQLITE_OK)
            {
                return push_sqlite_fail(L, sqlite3_errstr(rc));
            }
        }
        return push_ok(L);
    }

    int prepared_gc(lua_State *L)
    {
        Prepared *prepared = check_prepared(L, 1);
        prepared->~Prepared();
        return 0;
    }

    int prepared_tostring(lua_State *L)
    {
        Prepared *prepared = check_prepared(L, 1);
        if (!prepared->handle)
        {
            lua_pushliteral(L, "babet.sqlite.prepared (closed)");
            return 1;
        }
        lua_pushfstring(L, "babet.sqlite.prepared (%s, %p)",
                        prepared->query_active ? "iterating" : "ready",
                        prepared->handle);
        return 1;
    }

    // ============================================================
    // Transaction helper
    // ============================================================

    bool exec_transaction_control(sqlite3 *db, const char *sql,
                                  const char *context,
                                  std::string &error)
    {
        char *sqlite_error = nullptr;
        int rc = sqlite3_exec(db, sql, nullptr, nullptr, &sqlite_error);
        if (rc == SQLITE_OK)
        {
            sqlite3_free(sqlite_error);
            return true;
        }

        error = context;
        error += ": ";
        error += sqlite_error ? sqlite_error : sqlite3_errmsg(db);
        sqlite3_free(sqlite_error);
        return false;
    }

    // Owns the explicit transaction after BEGIN succeeds. The destructor is
    // deliberately allocation-free on the C++ side: if an exception escapes
    // any diagnostic or callback-processing allocation, it attempts an
    // immediate ROLLBACK and always clears the helper-active flag.
    //
    // Lua is compiled as C and longjmp does not run C++ destructors. Therefore
    // db_transaction_impl must not call any unprotected Lua API while this
    // guard is armed. The two fixed pushes before lua_pcall are reserved before
    // BEGIN; lua_pcall itself contains callback errors.
    class TransactionGuard
    {
    public:
        explicit TransactionGuard(Db *owner) noexcept
            : owner_(owner), handle_(owner ? owner->handle : nullptr)
        {
        }

        TransactionGuard(const TransactionGuard &) = delete;
        TransactionGuard &operator=(const TransactionGuard &) = delete;

        ~TransactionGuard() noexcept
        {
            rollback_now();
        }

        void callback_started() noexcept
        {
            if (owner_)
            {
                owner_->transaction_helper_active = true;
            }
        }

        void callback_finished() noexcept
        {
            if (owner_)
            {
                owner_->transaction_helper_active = false;
            }
        }

        void release() noexcept
        {
            callback_finished();
            armed_ = false;
        }

        // Performs one best-effort emergency rollback and disarms the guard.
        // The return value tells the caller whether SQLite is back in
        // autocommit mode afterwards.
        bool rollback_now() noexcept
        {
            callback_finished();
            if (!armed_)
            {
                return true;
            }

            if (handle_ && sqlite3_get_autocommit(handle_) == 0)
            {
                char *sqlite_error = nullptr;
                sqlite3_exec(handle_, "ROLLBACK", nullptr, nullptr,
                             &sqlite_error);
                sqlite3_free(sqlite_error);
            }

            const bool clean =
                !handle_ || sqlite3_get_autocommit(handle_) != 0;
            armed_ = false;
            return clean;
        }

    private:
        Db *owner_ = nullptr;
        sqlite3 *handle_ = nullptr;
        bool armed_ = true;
    };

    // db:in_transaction() -> boolean | (nil, err)
    int db_in_transaction(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L,
                              "sqlite.in_transaction: expected only self");
        }
        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }
        lua_pushboolean(L, sqlite3_get_autocommit(db->handle) == 0);
        return 1;
    }

    // db:transaction(fn, mode?) -> true, ...callback_results | (nil, err)
    // Only a Lua error rolls back. Normal callback returns, including nil or
    // false values, are committed and forwarded after the leading true.
    int db_transaction_impl(lua_State *L)
    {
        int top = lua_gettop(L);
        if (top < 2 || top > 3)
        {
            return luaL_error(
                L, "sqlite.transaction: expected db, callback and optional mode");
        }

        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }
        luaL_checktype(L, 2, LUA_TFUNCTION);

        if (db->transaction_helper_active)
        {
            return push_sqlite_fail(
                L, "nested transaction helper is not supported");
        }
        if (sqlite3_get_autocommit(db->handle) == 0)
        {
            return push_sqlite_fail(
                L, "connection is already inside a transaction");
        }

        // Reserve the two fixed stack slots needed to invoke callback(db)
        // before BEGIN. lua_checkstack reports failure instead of longjmp, so
        // no transaction can be left open by a stack-growth failure here.
        if (!lua_checkstack(L, 2))
        {
            return push_fail(
                L, "sqlite: transaction could not reserve Lua stack");
        }

        const char *begin_sql = "BEGIN DEFERRED";
        if (top == 3 && !lua_isnil(L, 3))
        {
            luaL_checktype(L, 3, LUA_TSTRING);
            std::string mode;
            std::string mode_error;
            if (!lua_string_without_nul(L, 3, mode,
                                        "sqlite.transaction: mode",
                                        mode_error))
            {
                return push_fail(L, mode_error);
            }

            if (mode == "deferred")
            {
                begin_sql = "BEGIN DEFERRED";
            }
            else if (mode == "immediate")
            {
                begin_sql = "BEGIN IMMEDIATE";
            }
            else if (mode == "exclusive")
            {
                begin_sql = "BEGIN EXCLUSIVE";
            }
            else
            {
                return push_sqlite_fail(
                    L, "transaction mode must be 'deferred', 'immediate' "
                       "or 'exclusive'");
            }
        }

        {
            std::string begin_error;
            if (!exec_transaction_control(db->handle, begin_sql, "begin",
                                          begin_error))
            {
                return push_sqlite_fail(L, begin_error);
            }
        }

        TransactionGuard transaction_guard(db);

        // Keep only db and callback below the callback results.
        // The required capacity was reserved before BEGIN, so these fixed
        // stack operations cannot allocate while the guard is armed.
        lua_settop(L, 2);
        lua_pushvalue(L, 2);
        lua_pushvalue(L, 1);

        transaction_guard.callback_started();
        int call_status = lua_pcall(L, 1, LUA_MULTRET, 0);
        transaction_guard.callback_finished();

        if (call_status != LUA_OK)
        {
            std::string rollback_error;
            bool rollback_ok = exec_transaction_control(
                db->handle, "ROLLBACK", "rollback", rollback_error);

            bool connection_clean =
                sqlite3_get_autocommit(db->handle) != 0;
            if (connection_clean)
            {
                transaction_guard.release();
            }
            else
            {
                connection_clean = transaction_guard.rollback_now();
            }

            // The transaction is now closed, or an explicit warning will be
            // appended. Lua diagnostics may allocate from this point onward.
            std::string callback_error =
                lua_value_to_display_string(L, -1);

            std::string message = "transaction callback failed: ";
            message += callback_error;
            if (!rollback_ok)
            {
                message += "; ";
                message += rollback_error;
            }
            if (!connection_clean)
            {
                message +=
                    "; emergency rollback failed; connection remains inside "
                    "a transaction";
            }
            lua_settop(L, 0);
            return push_sqlite_fail(L, message);
        }

        int callback_results = lua_gettop(L) - 2;

        // Reserve the leading success boolean before COMMIT. A failure here
        // still permits a normal rollback without any unprotected Lua call.
        if (!lua_checkstack(L, 1))
        {
            std::string rollback_error;
            bool rollback_ok = exec_transaction_control(
                db->handle, "ROLLBACK", "rollback", rollback_error);
            bool connection_clean =
                sqlite3_get_autocommit(db->handle) != 0;
            if (connection_clean)
            {
                transaction_guard.release();
            }
            else
            {
                connection_clean = transaction_guard.rollback_now();
            }

            std::string message =
                "transaction could not reserve result stack";
            if (!rollback_ok)
            {
                message += "; ";
                message += rollback_error;
            }
            if (!connection_clean)
            {
                message +=
                    "; emergency rollback failed; connection remains inside "
                    "a transaction";
            }
            lua_settop(L, 0);
            return push_sqlite_fail(L, message);
        }

        std::string commit_error;
        if (!exec_transaction_control(db->handle, "COMMIT", "commit",
                                      commit_error))
        {
            std::string rollback_error;
            bool rollback_ok = exec_transaction_control(
                db->handle, "ROLLBACK", "rollback", rollback_error);

            bool connection_clean =
                sqlite3_get_autocommit(db->handle) != 0;
            if (connection_clean)
            {
                transaction_guard.release();
            }
            else
            {
                connection_clean = transaction_guard.rollback_now();
            }
            if (!rollback_ok)
            {
                commit_error += "; ";
                commit_error += rollback_error;
            }
            if (!connection_clean)
            {
                commit_error +=
                    "; emergency rollback failed; connection remains inside "
                    "a transaction";
            }
            lua_settop(L, 0);
            return push_sqlite_fail(L, commit_error);
        }

        transaction_guard.release();

        lua_pushboolean(L, 1);
        lua_insert(L, 3);
        lua_remove(L, 1);
        lua_remove(L, 1);
        return callback_results + 1;
    }

    int db_transaction(lua_State *L)
    {
        try
        {
            return db_transaction_impl(L);
        }
        catch (const std::bad_alloc &)
        {
            return push_fail(
                L, "sqlite: transaction out of memory");
        }
        catch (...)
        {
            return push_fail(
                L, "sqlite: internal transaction failure");
        }
    }

    // ============================================================
    // API du module : babet.sqlite.open
    // ============================================================

    // babet.sqlite.open(path, opts?) → db | (nil, err)
    //
    // path : ":memory:" pour une DB en RAM (jetable),
    //        sinon un chemin de fichier (créé s'il n'existe pas).
    //
    // opts : { wal = bool, busy_timeout = ms } — tous optionnels.
    int sqlite_open(lua_State *L)
    {
        // luaL_checkstring convertit silencieusement les nombres en
        // strings (sémantique Lua par défaut). On veut rejeter
        // open(42) explicitement : c'est probablement un bug côté
        // appelant, pas une intention d'ouvrir un fichier nommé "42".
        // Pattern aligné sur toml.decode et workers.spawn.
        luaL_checktype(L, 1, LUA_TSTRING);

        // Parse opts first: it may raise a Lua error. No owning C++ string is
        // alive yet, so the longjmp cannot bypass a string destructor.
        OpenOpts opts = parse_open_opts(L, 2);

        std::string path;
        std::string path_err;
        if (!lua_string_without_nul(L, 1, path,
                                    "sqlite: path", path_err))
        {
            return push_fail(L, path_err);
        }

        // Ouverture avec les flags par défaut équivalents à sqlite3_open :
        //   CREATE | READWRITE.
        // sqlite3_open_v2 permettrait de durcir avec NOMUTEX par exemple,
        // mais on garde le défaut pour cohérence avec SQLITE_THREADSAFE=1.
        sqlite3 *handle = nullptr;
        int rc = sqlite3_open(path.c_str(), &handle);
        if (rc != SQLITE_OK)
        {
            std::string msg = handle ? sqlite3_errmsg(handle) : sqlite3_errstr(rc);
            if (handle)
            {
                sqlite3_close_v2(handle);
            }
            return push_sqlite_fail(L, msg);
        }

        // Appliquer busy_timeout AVANT WAL : si WAL bloque sur lock,
        // on veut le retry automatique.
        if (opts.busy_timeout_ms > 0)
        {
            rc = sqlite3_busy_timeout(handle, opts.busy_timeout_ms);
            if (rc != SQLITE_OK)
            {
                std::string msg = sqlite3_errmsg(handle);
                sqlite3_close_v2(handle);
                return push_sqlite_fail(L, "busy_timeout: " + msg);
            }
        }

        // Activer WAL si demandé. PRAGMA journal_mode renvoie le mode
        // effectif (peut être "memory" pour :memory:, "wal" pour fichier).
        // On accepte tout retour non-erreur — un mode différent n'est
        // pas une erreur, juste un fallback géré par SQLite lui-même.
        if (opts.wal)
        {
            char *errmsg = nullptr;
            rc = sqlite3_exec(handle, "PRAGMA journal_mode=WAL;",
                              nullptr, nullptr, &errmsg);
            if (rc != SQLITE_OK)
            {
                std::string msg = errmsg ? errmsg : sqlite3_errmsg(handle);
                sqlite3_free(errmsg);
                sqlite3_close_v2(handle);
                return push_sqlite_fail(L, "enabling WAL: " + msg);
            }
            sqlite3_free(errmsg);
        }

        // Allouer le userdata Db et y poser handle.
        // Placement new pour initialiser correctement le struct
        // (cohérent avec push_new_sock dans socket.cpp).
        Db *db = static_cast<Db *>(lua_newuserdata(L, sizeof(Db)));
        new (db) Db();
        db->handle = handle;

        // Attacher la métatable (créée à register_sqlite).
        luaL_getmetatable(L, DB_MT);
        lua_setmetatable(L, -2);

        return 1;
    }

    // ============================================================
    // Construction de la métatable + sous-table babet.sqlite
    // ============================================================

    void create_db_metatable(lua_State *L)
    {
        // Crée la métatable et l'enregistre dans le registry sous
        // la clé DB_MT.
        luaL_newmetatable(L, DB_MT);

        // __index = self (les méthodes sont des champs directs de
        // la métatable).
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");

        // __gc : appelé par Lua quand le userdata est collecté.
        lua_pushcfunction(L, db_gc);
        lua_setfield(L, -2, "__gc");

        // __tostring : pour print(db).
        lua_pushcfunction(L, db_tostring);
        lua_setfield(L, -2, "__tostring");

        // Méthodes : close, exec, query, prepare et transactions.
        lua_pushcfunction(L, db_close);
        lua_setfield(L, -2, "close");

        lua_pushcfunction(L, db_exec);
        lua_setfield(L, -2, "exec");

        lua_pushcfunction(L, db_query);
        lua_setfield(L, -2, "query");

        lua_pushcfunction(L, db_prepare);
        lua_setfield(L, -2, "prepare");

        lua_pushcfunction(L, db_transaction);
        lua_setfield(L, -2, "transaction");

        lua_pushcfunction(L, db_in_transaction);
        lua_setfield(L, -2, "in_transaction");

        // On dépile la métatable, elle reste en registry.
        lua_pop(L, 1);
    }

    void create_blob_metatable(lua_State *L)
    {
        luaL_newmetatable(L, BLOB_MT);

        lua_pushcfunction(L, blob_gc);
        lua_setfield(L, -2, "__gc");

        lua_pushcfunction(L, blob_tostring);
        lua_setfield(L, -2, "__tostring");

        // Opaque and immutable: no __index table and no exposed payload.
        lua_pop(L, 1);
    }

    void create_prepared_metatable(lua_State *L)
    {
        luaL_newmetatable(L, PREPARED_MT);

        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");

        lua_pushcfunction(L, prepared_call);
        lua_setfield(L, -2, "__call");

        lua_pushcfunction(L, prepared_gc);
        lua_setfield(L, -2, "__gc");

        lua_pushcfunction(L, prepared_tostring);
        lua_setfield(L, -2, "__tostring");

        lua_pushcfunction(L, prepared_exec);
        lua_setfield(L, -2, "exec");

        lua_pushcfunction(L, prepared_query);
        lua_setfield(L, -2, "query");

        lua_pushcfunction(L, prepared_reset);
        lua_setfield(L, -2, "reset");

        lua_pushcfunction(L, prepared_close);
        lua_setfield(L, -2, "close");

        lua_pushcfunction(L, prepared_close);
        lua_setfield(L, -2, "finalize");

        lua_pop(L, 1);
    }

    void create_stmt_metatable(lua_State *L)
    {
        luaL_newmetatable(L, STMT_MT);

        // __index = self : permet stmt:close() etc.
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");

        // __call : permet for row in stmt do ... end.
        lua_pushcfunction(L, stmt_call);
        lua_setfield(L, -2, "__call");

        // __gc : finalize le sqlite3_stmt si pas déjà fait.
        lua_pushcfunction(L, stmt_gc);
        lua_setfield(L, -2, "__gc");

        // __tostring : print(iter) lisible.
        lua_pushcfunction(L, stmt_tostring);
        lua_setfield(L, -2, "__tostring");

        // Méthode explicite : close.
        lua_pushcfunction(L, stmt_close);
        lua_setfield(L, -2, "close");

        lua_pop(L, 1);
    }

} // namespace anonyme

// ============================================================
// Fonction exportée (déclarée dans sqlite.hpp)
// ============================================================

void register_sqlite(lua_State *L)
{
    // Précondition : la table babet est au sommet.

    // Créer les métatables des userdatas (en registry).
    create_db_metatable(L);
    create_stmt_metatable(L);
    create_prepared_metatable(L);
    create_blob_metatable(L);

    // Sous-table babet.sqlite.
    lua_newtable(L);

    lua_pushcfunction(L, sqlite_open);
    lua_setfield(L, -2, "open");

    lua_pushcfunction(L, sqlite_blob);
    lua_setfield(L, -2, "blob");

    lua_setfield(L, -2, "sqlite");
}
