// =====================================================================
// sqlite.cpp — implémentation des bindings SQLite
// =====================================================================
// Implémente open / close / exec / query, le bind des paramètres,
// l'itérateur paresseux de lignes et le mapping des types.
//
// Voir sqlite.hpp pour le contrat public.

#include "sqlite.hpp"
#include "lua_utils.hpp"
#include "sqlite_backup_file.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include "sqlite3.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <new>
#include <string>
#include <thread>

namespace
{

    constexpr const char *SAVEPOINT_TRANSACTION_ENDED_ERROR =
        "savepoint callback ended the transaction explicitly; "
        "managed savepoint no longer exists";

    // L'adresse seule porte l'identité publique de babet.sqlite.NULL.
    // L'objet n'est jamais lu ni exposé autrement.
    char SQLITE_NULL_SENTINEL_KEY = 0;
}

bool is_sqlite_null(lua_State *L, int idx) noexcept
{
    return lua_type(L, idx) == LUA_TLIGHTUSERDATA &&
           lua_touserdata(L, idx) == &SQLITE_NULL_SENTINEL_KEY;
}

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
        unsigned int savepoint_depth;
        unsigned long long savepoint_sequence;

        Db()
            : handle(nullptr), transaction_helper_active(false),
              savepoint_depth(0), savepoint_sequence(0) {}
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
        return push_fail_protected(L, full);
    }

    std::string strip_sqlite_backup_prefix(const std::string &message)
    {
        static constexpr const char prefix[] = "sqlite.backup: ";
        if (message.compare(0, sizeof(prefix) - 1, prefix) == 0)
        {
            return message.substr(sizeof(prefix) - 1);
        }
        return message;
    }

    // Toute fonction SQLite normale exposée à Lua passe par cette
    // frontière. Lua 5.5 est compilé en C dans Babet : une exception C++
    // ne doit jamais traverser une lua_CFunction. Les diagnostics restent
    // littéraux afin de ne pas réallouer côté C++ dans le handler OOM.
    template <int (*Fn)(lua_State *)>
    int sqlite_lua_boundary(lua_State *L)
    {
        return lua_cfunction_exception_boundary<Fn>(
            L, "sqlite: out of memory", "sqlite: internal C++ failure",
            "sqlite: unknown internal C++ failure");
    }

    // Les finalizers ne doivent jamais propager d'exception ni tenter de
    // produire un diagnostic Lua pendant une collecte mémoire.
    template <int (*Fn)(lua_State *)>
    int sqlite_gc_boundary(lua_State *L) noexcept
    {
        try
        {
            return Fn(L);
        }
        catch (...)
        {
            return 0;
        }
    }

    // Construit le diagnostic d'un sqlite3_step() avant tout reset ou
    // finalize. Le tampon renvoyé par sqlite3_errmsg() appartient à la
    // connexion et peut être invalidé par l'appel SQLite suivant : la copie
    // dans std::string doit donc être immédiate.
    std::string sqlite_step_error(sqlite3_stmt *stmt, int rc)
    {
        sqlite3 *db = sqlite3_db_handle(stmt);
        if (!db)
        {
            return sqlite3_errstr(rc);
        }

        const int db_rc = sqlite3_errcode(db);
        constexpr int primary_code_mask = 0xff;

        // rc et sqlite3_errcode() suivent tous deux le réglage des codes
        // étendus de la connexion. Le masque compare donc les codes
        // primaires quel que soit ce réglage. sqlite3_errstr() reçoit en
        // revanche le code complet, car il peut fournir un texte plus précis.
        if ((rc & primary_code_mask) != (db_rc & primary_code_mask))
        {
            return sqlite3_errstr(rc);
        }

        const char *message = sqlite3_errmsg(db);
        return message ? message : sqlite3_errstr(rc);
    }

    std::string sqlite_connection_error(sqlite3 *db, int rc)
    {
        if (!db)
        {
            return sqlite3_errstr(rc);
        }

        constexpr int primary_code_mask = 0xff;
        const int db_rc = sqlite3_errcode(db);
        if ((rc & primary_code_mask) != (db_rc & primary_code_mask))
        {
            return sqlite3_errstr(rc);
        }

        const char *message = sqlite3_errmsg(db);
        return message ? message : sqlite3_errstr(rc);
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
        bool readonly;
        bool foreign_keys;
        int busy_timeout_ms;

        OpenOpts()
            : wal(false), readonly(false), foreign_keys(false),
              busy_timeout_ms(0) {}
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

        idx = lua_absindex(L, idx);
        lua_pushnil(L);
        while (lua_next(L, idx) != 0)
        {
            if (lua_type(L, -2) != LUA_TSTRING)
            {
                lua_pop(L, 2);
                luaL_error(L,
                           "sqlite.open: option keys must be strings");
            }

            size_t key_len = 0;
            const char *key = lua_tolstring(L, -2, &key_len);
            const bool known =
                (key_len == 3 && std::memcmp(key, "wal", 3) == 0) ||
                (key_len == 8 &&
                 std::memcmp(key, "readonly", 8) == 0) ||
                (key_len == 12 &&
                 std::memcmp(key, "foreign_keys", 12) == 0) ||
                (key_len == 12 &&
                 std::memcmp(key, "busy_timeout", 12) == 0);
            if (!known)
            {
                char key_text[160];
                const size_t copy_len =
                    key_len < sizeof(key_text) - 1
                        ? key_len
                        : sizeof(key_text) - 1;
                std::memcpy(key_text, key, copy_len);
                key_text[copy_len] = '\0';
                lua_pop(L, 2);
                luaL_error(L, "sqlite.open: unknown option '%s'", key_text);
            }
            lua_pop(L, 1); // value; keep key for lua_next
        }

        // wal
        lua_pushliteral(L, "wal");
        lua_rawget(L, idx);
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

        // readonly
        lua_pushliteral(L, "readonly");
        lua_rawget(L, idx);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(L,
                           "sqlite.open: opts.readonly must be a boolean");
            }
            opts.readonly = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);

        // foreign_keys
        lua_pushliteral(L, "foreign_keys");
        lua_rawget(L, idx);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.open: opts.foreign_keys must be a boolean");
            }
            opts.foreign_keys = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);

        // busy_timeout
        lua_pushliteral(L, "busy_timeout");
        lua_rawget(L, idx);
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

        if (opts.readonly && opts.wal)
        {
            luaL_error(
                L,
                "sqlite.open: readonly=true cannot be combined with wal=true");
        }

        return opts;
    }

    struct BackupOpts
    {
        double timeout_seconds;
        int pages_per_step;
        double sleep_seconds;
        bool overwrite;

        BackupOpts()
            : timeout_seconds(5.0), pages_per_step(128),
              sleep_seconds(0.01), overwrite(false) {}
    };

    BackupOpts parse_backup_opts(lua_State *L, int idx)
    {
        BackupOpts opts;
        const int type = lua_type(L, idx);
        if (type == LUA_TNONE || type == LUA_TNIL)
        {
            return opts;
        }
        if (type != LUA_TTABLE)
        {
            luaL_error(L,
                       "sqlite.backup: opts must be a table or nil, got %s",
                       lua_typename(L, type));
        }

        idx = lua_absindex(L, idx);
        lua_pushnil(L);
        while (lua_next(L, idx) != 0)
        {
            if (lua_type(L, -2) != LUA_TSTRING)
            {
                lua_pop(L, 2);
                luaL_error(L,
                           "sqlite.backup: option keys must be strings");
            }

            size_t key_len = 0;
            const char *key = lua_tolstring(L, -2, &key_len);
            const bool known =
                (key_len == 7 &&
                 std::memcmp(key, "timeout", 7) == 0) ||
                (key_len == 14 &&
                 std::memcmp(key, "pages_per_step", 14) == 0) ||
                (key_len == 5 &&
                 std::memcmp(key, "sleep", 5) == 0) ||
                (key_len == 9 &&
                 std::memcmp(key, "overwrite", 9) == 0);
            if (!known)
            {
                char key_text[160];
                const size_t copy_len =
                    key_len < sizeof(key_text) - 1
                        ? key_len
                        : sizeof(key_text) - 1;
                std::memcpy(key_text, key, copy_len);
                key_text[copy_len] = '\0';
                lua_pop(L, 2);
                luaL_error(L, "sqlite.backup: unknown option '%s'",
                           key_text);
            }
            lua_pop(L, 1);
        }

        lua_pushliteral(L, "timeout");
        lua_rawget(L, idx);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_number(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(L,
                           "sqlite.backup: opts.timeout must be a number");
            }
            const double value = lua_tonumber(L, -1);
            if (!std::isfinite(value) || value < 0.0)
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.timeout must be a finite number >= 0");
            }
            if (value > 86400.0)
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.timeout too large (max 86400 seconds)");
            }
            opts.timeout_seconds = value;
        }
        lua_pop(L, 1);

        lua_pushliteral(L, "pages_per_step");
        lua_rawget(L, idx);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_integer(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.pages_per_step must be an integer");
            }
            const lua_Integer value = lua_tointeger(L, -1);
            if (value <= 0)
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.pages_per_step must be > 0");
            }
            if (value > INT_MAX)
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.pages_per_step exceeds INT_MAX");
            }
            opts.pages_per_step = static_cast<int>(value);
        }
        lua_pop(L, 1);

        lua_pushliteral(L, "sleep");
        lua_rawget(L, idx);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_number(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(L,
                           "sqlite.backup: opts.sleep must be a number");
            }
            const double value = lua_tonumber(L, -1);
            if (!std::isfinite(value) || value < 0.0)
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.sleep must be a finite number >= 0");
            }
            if (value > 60.0)
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.sleep too large (max 60 seconds)");
            }
            opts.sleep_seconds = value;
        }
        lua_pop(L, 1);

        lua_pushliteral(L, "overwrite");
        lua_rawget(L, idx);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
            {
                lua_pop(L, 1);
                luaL_error(
                    L,
                    "sqlite.backup: opts.overwrite must be a boolean");
            }
            opts.overwrite = lua_toboolean(L, -1) != 0;
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
    // Userdata Stmt : propriétaire d'un sqlite3_stmt
    // ============================================================
    //
    // Ce propriétaire sert à la fois aux itérateurs db:query() et aux
    // statements temporaires de db:exec(). Dans ce second cas, il reste
    // interne à la pile Lua : si une API Lua effectue un longjmp pendant le
    // bind, __gc possède déjà le handle et peut le finaliser.
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
    //      utiliser `babet.sqlite.blob(data)`.
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
    // G. babet.sqlite.NULL est la seule valeur lightuserdata acceptée et
    //    produit sqlite3_bind_null(). Un nil reste un paramètre manquant.

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
                        char *err, size_t err_size)
    {
        if (is_sqlite_null(L, idx))
        {
            int rc = sqlite3_bind_null(stmt, slot);
            if (rc != SQLITE_OK)
            {
                std::snprintf(
                    err, err_size,
                    "bind failed for babet.sqlite.NULL at slot %d: %s",
                    slot, sqlite3_errstr(rc));
                return false;
            }
            return true;
        }

        int t = lua_type(L, idx);
        int rc = SQLITE_OK;
        switch (t)
        {
        case LUA_TNIL:
            // Défensif : les callers distinguent déjà un paramètre absent.
            // Accepter nil ici affaiblirait ce contrat si un nouveau chemin
            // de bind oubliait un jour le contrôle amont.
            std::snprintf(
                err, err_size,
                "nil is a missing bind value at slot %d; "
                "use babet.sqlite.NULL for SQL NULL",
                slot);
            return false;
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
                const lua_Number value = lua_tonumber(L, idx);
                if (!std::isfinite(static_cast<double>(value)))
                {
                    std::snprintf(
                        err, err_size,
                        "cannot bind a non-finite number at slot %d", slot);
                    return false;
                }
                rc = sqlite3_bind_double(stmt, slot, value);
            }
            break;
        case LUA_TSTRING:
        {
            size_t len = 0;
            const char *s = lua_tolstring(L, idx, &len);
            if (len > static_cast<size_t>(0x7fffffff))
            {
                std::snprintf(
                    err, err_size,
                    "string too large to bind at slot %d", slot);
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

            if (t == LUA_TLIGHTUSERDATA)
            {
                std::snprintf(
                    err, err_size,
                    "cannot bind light userdata at slot %d; "
                    "only babet.sqlite.NULL is accepted",
                    slot);
                return false;
            }

            // function / table / unrelated full userdata / thread.
            std::snprintf(
                err, err_size,
                "cannot bind value of type '%s' at slot %d",
                lua_typename(L, t), slot);
            return false;
        }
        if (rc != SQLITE_OK)
        {
            std::snprintf(
                err, err_size,
                "bind failed at slot %d: %s", slot, sqlite3_errstr(rc));
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
                                int params_idx, char *err, size_t err_size)
    {
        params_idx = lua_absindex(L, params_idx);
        int n_params = sqlite3_bind_parameter_count(stmt);

        // Inventorier les slots. Aucun conteneur C++ propriétaire n'est gardé
        // pendant les futurs appels Lua : un longjmp ne peut donc contourner
        // aucun destructeur dans ce helper.
        int positional_count = 0;
        for (int i = 1; i <= n_params; ++i)
        {
            const char *name = sqlite3_bind_parameter_name(stmt, i);
            if (name)
            {
                if (name[0] == '?')
                {
                    std::snprintf(
                        err, err_size,
                        "numbered ?NNN placeholders are not supported; "
                        "use plain ? placeholders");
                    return false;
                }
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
                // Slot nommé : lookup brut params[name_sans_prefixe]. Une
                // métaméthode __index ne doit jamais fabriquer un paramètre
                // absent ni exécuter du Lua pendant le bind.
                lua_pushstring(L, name + 1);
                lua_rawget(L, params_idx);
                if (lua_isnil(L, -1))
                {
                    lua_pop(L, 1);
                    std::snprintf(
                        err, err_size, "missing param '%s'", name);
                    return false;
                }
                bool ok = bind_one_value(
                    L, stmt, i, -1, err, err_size);
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
                    std::snprintf(
                        err, err_size,
                        "missing positional param at index %d", pos_seen);
                    return false;
                }
                bool ok = bind_one_value(
                    L, stmt, i, -1, err, err_size);
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
            std::snprintf(
                err, err_size,
                "too many positional params (statement uses %d, "
                "got at least %d)",
                positional_count, pos_seen + 1);
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
                bool required = false;
                for (int i = 1; i <= n_params; ++i)
                {
                    const char *name =
                        sqlite3_bind_parameter_name(stmt, i);
                    if (!name || name[0] == '?')
                    {
                        continue;
                    }
                    const size_t name_len = std::strlen(name + 1);
                    if (name_len == key_len &&
                        std::memcmp(name + 1, key_data, key_len) == 0)
                    {
                        required = true;
                        break;
                    }
                }
                if (!required)
                {
                    const int shown =
                        key_len < 200 ? static_cast<int>(key_len) : 200;
                    std::snprintf(
                        err, err_size,
                        "extra param '%.*s' (not used by this SQL)",
                        shown, key_data);
                    lua_pop(L, 2); // value + key
                    return false;
                }
            }
            else if (kt == LUA_TNUMBER)
            {
                if (!lua_is_strict_integer(L, -2))
                {
                    std::snprintf(
                        err, err_size,
                        "params table has a non-integer numeric key");
                    lua_pop(L, 2);
                    return false;
                }
                lua_Integer idx = lua_tointeger(L, -2);
                if (idx < 1 || idx > pos_seen)
                {
                    std::snprintf(
                        err, err_size,
                        "extra positional param at index %lld "
                        "(statement uses %d)",
                        static_cast<long long>(idx), positional_count);
                    lua_pop(L, 2);
                    return false;
                }
            }
            else
            {
                std::snprintf(
                    err, err_size,
                    "params table has unsupported key type '%s'; "
                    "keys must be strings or positive integers",
                    lua_typename(L, kt));
                lua_pop(L, 2);
                return false;
            }
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
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L, "sqlite.close: expected only self");
        }
        Db *db = check_db(L, 1);
        if (db->transaction_helper_active)
        {
            return push_sqlite_fail(
                L, "cannot close connection during transaction callback");
        }
        if (db->savepoint_depth > 0)
        {
            return push_sqlite_fail(
                L, "cannot close connection during savepoint callback");
        }
        if (db->handle)
        {
            int rc = sqlite3_close_v2(db->handle);
            if (rc != SQLITE_OK)
            {
                // close_v2 ne devrait jamais échouer en pratique, mais
                // conserver le handle permet à __gc ou à un second close()
                // de retenter le nettoyage au lieu de perdre la ressource.
                return push_sqlite_fail(L, sqlite3_errstr(rc));
            }
            db->handle = nullptr;
        }
        return push_ok(L);
    }

    // db:last_insert_rowid() -> integer | (nil, err)
    //
    // Valeur propre à cette connexion, telle que définie par SQLite. Elle
    // reste inchangée après les statements qui n'insèrent pas de rowid et
    // après un rollback d'un INSERT réussi.
    int db_last_insert_rowid(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(
                L, "sqlite.last_insert_rowid: expected only self");
        }
        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }

        lua_pushinteger(
            L,
            static_cast<lua_Integer>(
                sqlite3_last_insert_rowid(db->handle)));
        return 1;
    }

    // db:changes() -> integer | (nil, err)
    // Nombre de lignes modifiées par le dernier INSERT/UPDATE/DELETE terminé
    // sur cette connexion. La variante 64 bits évite la saturation de
    // sqlite3_changes() pour les opérations exceptionnellement volumineuses.
    int db_changes(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L, "sqlite.changes: expected only self");
        }
        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }

        lua_pushinteger(
            L,
            static_cast<lua_Integer>(sqlite3_changes64(db->handle)));
        return 1;
    }

    // db:total_changes() -> integer | (nil, err)
    // Cumul des lignes modifiées depuis l'ouverture de cette connexion.
    int db_total_changes(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(
                L, "sqlite.total_changes: expected only self");
        }
        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }

        lua_pushinteger(
            L,
            static_cast<lua_Integer>(sqlite3_total_changes64(db->handle)));
        return 1;
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
        if (!lua_arity_between(L, 2, 3))
        {
            return luaL_error(
                L, "sqlite.exec: expected two or three arguments");
        }
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

        // db:exec() ne renvoie pas ce userdata, mais l'utilise comme
        // propriétaire interne. Il est construit et finalisable avant tout
        // sqlite3_prepare_v2() : une exception C++ ou un longjmp Lua pendant
        // le bind ne peut donc plus abandonner un sqlite3_stmt brut.
        Stmt *stmt_owner = static_cast<Stmt *>(
            lua_newuserdata(L, sizeof(Stmt)));
        new (stmt_owner) Stmt();
        luaL_getmetatable(L, STMT_MT);
        lua_setmetatable(L, -2);

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
                const char *tail = nullptr;
                int rc = sqlite3_prepare_v2(db->handle, cursor,
                                            static_cast<int>(sql_end - cursor),
                                            &stmt_owner->handle, &tail);
                if (rc != SQLITE_OK)
                {
                    std::string msg = sqlite3_errmsg(db->handle);
                    if (stmt_owner->handle)
                    {
                        sqlite3_finalize(stmt_owner->handle);
                        stmt_owner->handle = nullptr;
                    }
                    return push_sqlite_fail(L, msg);
                }
                if (!stmt_owner->handle)
                {
                    // Le reste n'est que blancs/commentaires. Garde
                    // anti-boucle : si le tail ne progresse pas, on
                    // sort (ne devrait pas arriver, ceinture).
                    if (tail == nullptr || tail <= cursor)
                        break;
                    cursor = tail;
                    continue;
                }

                if (sqlite3_bind_parameter_count(stmt_owner->handle) > 0)
                {
                    sqlite3_finalize(stmt_owner->handle);
                    stmt_owner->handle = nullptr;
                    return push_sqlite_fail(L,
                                            "SQL contains placeholders but no params table "
                                            "provided; pass params to bind, or remove "
                                            "placeholders from SQL");
                }

                while ((rc = sqlite3_step(stmt_owner->handle)) == SQLITE_ROW)
                {
                    // SELECT sans params : lignes ignorées, comme le
                    // faisait sqlite3_exec avec callback nul.
                }
                if (rc != SQLITE_DONE)
                {
                    std::string msg = sqlite_step_error(
                        stmt_owner->handle, rc);
                    sqlite3_finalize(stmt_owner->handle);
                    stmt_owner->handle = nullptr;
                    return push_sqlite_fail(L, msg);
                }
                sqlite3_finalize(stmt_owner->handle);
                stmt_owner->handle = nullptr;

                cursor = (tail != nullptr && tail > cursor) ? tail : sql_end;
            }
            return push_ok(L);
        }

        // -------------------------------------------------------
        // Cas avec params : prepare + bind + step + finalize.
        // -------------------------------------------------------
        const char *pzTail = nullptr;
        int rc = sqlite3_prepare_v2(db->handle, sql,
                                    static_cast<int>(sql_len),
                                    &stmt_owner->handle, &pzTail);
        if (rc != SQLITE_OK)
        {
            std::string msg = sqlite3_errmsg(db->handle);
            if (stmt_owner->handle)
            {
                sqlite3_finalize(stmt_owner->handle);
                stmt_owner->handle = nullptr;
            }
            return push_sqlite_fail(L, msg);
        }

        // Refuser le multi-statement avec params : pzTail doit être
        // soit nullptr, soit pointer sur du whitespace/commentaires
        // uniquement.
        if (!sql_tail_is_empty(pzTail))
        {
            if (stmt_owner->handle)
            {
                sqlite3_finalize(stmt_owner->handle);
                stmt_owner->handle = nullptr;
            }
            return push_sqlite_fail(L,
                                    "exec with params supports only one statement; "
                                    "use exec(sql) without params for multi-statement SQL");
        }

        // Un SQL vide ou composé uniquement de séparateurs/commentaires
        // ne produit aucun sqlite3_stmt. Sans paramètres, exec est déjà un
        // no-op réussi ; avec une table vide, on conserve la même sémantique.
        // Une table non vide reste une erreur de programmation explicite.
        if (!stmt_owner->handle)
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
        char bind_err[512] = {};
        bool bind_ok = bind_params_from_table(
            L, stmt_owner->handle, 3, bind_err, sizeof(bind_err));
        if (!bind_ok)
        {
            sqlite3_finalize(stmt_owner->handle);
            stmt_owner->handle = nullptr;
            luaL_error(L, "sqlite.exec: %s", bind_err);
            // unreachable
        }

        // Exécuter le statement.
        int step_rc = sqlite3_step(stmt_owner->handle);

        // SQLITE_DONE : DML/DDL OK.
        // SQLITE_ROW : SELECT a renvoyé une ligne (on l'ignore en
        //   mode exec, comme avec sqlite3_exec sans callback).
        //   On boucle pour épuiser le statement, sinon le finalize
        //   serait incomplet sur des SELECT.
        while (step_rc == SQLITE_ROW)
        {
            step_rc = sqlite3_step(stmt_owner->handle);
        }

        if (step_rc != SQLITE_DONE)
        {
            std::string msg = sqlite_step_error(
                stmt_owner->handle, step_rc);
            sqlite3_finalize(stmt_owner->handle);
            stmt_owner->handle = nullptr;
            return push_sqlite_fail(L, msg);
        }

        sqlite3_finalize(stmt_owner->handle);
        stmt_owner->handle = nullptr;
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
    // db:query renvoie aussi le Stmt comme quatrième valeur du for générique :
    // __close le finalise dès la sortie de boucle, y compris break/exception.
    // __gc reste le filet de sécurité pour un itérateur conservé séparément.
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
    //
    // Il ne faut donc ni stocker un Db* ni ancrer le userdata Lua parent :
    // le Db peut être détruit alors que la connexion native zombie reste
    // volontairement vivante, ce qui rendrait un Db* pendant ; l'ancrage
    // retarderait au contraire cette collecte sans apporter de garantie
    // supplémentaire au sqlite3_stmt, déjà protégé par SQLite.

    // Extrait la row courante (après SQLITE_ROW) en table dict.
    // NULL → la clé n'est pas posée (aucune sentinelle de lecture).
    //
    // **Comportement documenté** : les colonnes SQL NULL disparaissent
    // de la table Lua, car une table Lua ne peut pas stocker `nil`.
    //   - `row.col == nil` fonctionne toujours.
    //   - `pairs(row)` ne verra pas les colonnes NULL.
    // La sentinelle babet.sqlite.NULL reste volontairement réservée au bind :
    // la réutiliser à la lecture modifierait le contrat historique des rows.
    // Pour distinguer "colonne NULL" de "colonne inexistante", sélectionner
    // aussi typeof(colonne) ou un alias SQL explicite.
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
        std::string msg = sqlite_step_error(s->handle, rc);
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
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L, "sqlite query close: expected only self");
        }
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

    // Lua passes (self, error) to __close. Do not use stmt_close's strict
    // one-argument contract or destroy the userdata: references can survive
    // the scope, and __gc must remain safe after deterministic finalization.
    int stmt_scope_close(lua_State *L)
    {
        Stmt *s = check_stmt(L, 1);
        if (s->handle)
        {
            sqlite3_finalize(s->handle);
            s->handle = nullptr;
        }
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

    // db:query(sql, params?) → stmt, nil, nil, stmt | (nil, err)
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
        if (!lua_arity_between(L, 2, 3))
        {
            return luaL_error(
                L, "sqlite.query: expected two or three arguments");
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

        int top = lua_gettop(L);
        bool has_params = false;
        if (top >= 3 && !lua_isnil(L, 3))
        {
            luaL_checktype(L, 3, LUA_TTABLE);
            has_params = true;
        }

        // Construire d'abord le propriétaire vide et finalisable. Tout handle
        // produit ensuite par sqlite3_prepare_v2 est ainsi transféré
        // directement dans le userdata déjà muni de sa métatable.
        Stmt *s = static_cast<Stmt *>(lua_newuserdata(L, sizeof(Stmt)));
        new (s) Stmt();
        luaL_getmetatable(L, STMT_MT);
        lua_setmetatable(L, -2);

        const char *pzTail = nullptr;
        int rc = sqlite3_prepare_v2(db->handle, sql,
                                    static_cast<int>(sql_len),
                                    &s->handle, &pzTail);
        if (rc != SQLITE_OK)
        {
            std::string msg = sqlite3_errmsg(db->handle);
            if (s->handle)
            {
                sqlite3_finalize(s->handle);
                s->handle = nullptr;
            }
            return push_sqlite_fail(L, msg);
        }

        // Refuser le multi-statement (avec ou sans params).
        if (!sql_tail_is_empty(pzTail))
        {
            if (s->handle)
            {
                sqlite3_finalize(s->handle);
                s->handle = nullptr;
            }
            return push_sqlite_fail(L,
                                    "query supports only one statement; "
                                    "use exec(sql) for multi-statement SQL");
        }

        // Un SQL vide ou uniquement composé de commentaires prépare
        // un statement nul : query renvoie alors un itérateur déjà épuisé.
        // Si une table params non vide a été fournie, elle ne doit pas être
        // ignorée silencieusement.
        if (!s->handle)
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
            int n_placeholders = sqlite3_bind_parameter_count(s->handle);
            if (n_placeholders > 0)
            {
                sqlite3_finalize(s->handle);
                s->handle = nullptr;
                return push_sqlite_fail(L,
                                        "SQL contains placeholders but no params table "
                                        "provided; pass params to bind, or remove "
                                        "placeholders from SQL");
            }
        }

        if (has_params && s->handle)
        {
            char bind_err[512] = {};
            bool bind_ok = bind_params_from_table(
                L, s->handle, 3, bind_err, sizeof(bind_err));
            if (!bind_ok)
            {
                sqlite3_finalize(s->handle);
                s->handle = nullptr;
                luaL_error(L, "sqlite.query: %s", bind_err);
                // unreachable
            }
        }

        // Lua 5.4+ closes the fourth generic-for value on all loop exits.
        // The second value stays nil, preserving `local iter, err = query()`.
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushvalue(L, -3);
        return 4;
    }


    // ============================================================
    // Statements préparés réutilisables
    // ============================================================

    // Comme Stmt, Prepared ne conserve ni Db* ni ancrage Lua vers la
    // connexion parente. sqlite3_close_v2 garantit directement la durée de
    // vie native du statement ; un Db* pourrait devenir pendant après la
    // collecte du userdata, tandis qu'un ancrage retarderait inutilement le
    // passage volontaire de la connexion à l'état zombie.

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
                                               char *error,
                                               size_t error_size)
    {
        if (!has_params)
        {
            if (sqlite3_bind_parameter_count(stmt) > 0)
            {
                std::snprintf(
                    error, error_size,
                    "SQL contains placeholders but no params table provided; "
                    "pass params to bind, or remove placeholders from SQL");
                return PreparedBindStatus::OperationalError;
            }
            return PreparedBindStatus::Ok;
        }

        if (!bind_params_from_table(
                L, stmt, params_idx, error, error_size))
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

        // Le propriétaire vide est construit et rendu finalisable avant
        // l'acquisition du handle natif.
        Prepared *prepared = static_cast<Prepared *>(
            lua_newuserdata(L, sizeof(Prepared)));
        new (prepared) Prepared();
        luaL_getmetatable(L, PREPARED_MT);
        lua_setmetatable(L, -2);

        const char *tail = nullptr;
        int rc = sqlite3_prepare_v2(db->handle, sql,
                                    static_cast<int>(sql_len),
                                    &prepared->handle, &tail);
        if (rc != SQLITE_OK)
        {
            std::string msg = sqlite3_errmsg(db->handle);
            if (prepared->handle)
            {
                sqlite3_finalize(prepared->handle);
                prepared->handle = nullptr;
            }
            return push_sqlite_fail(L, msg);
        }

        if (!sql_tail_is_empty(tail))
        {
            if (prepared->handle)
            {
                sqlite3_finalize(prepared->handle);
                prepared->handle = nullptr;
            }
            return push_sqlite_fail(
                L, "prepare supports only one statement");
        }
        if (!prepared->handle)
        {
            return push_sqlite_fail(
                L, "prepare requires one non-empty SQL statement");
        }
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

        {
            std::string reuse_error;
            if (!prepared_clear_for_reuse(
                    prepared->handle, reuse_error))
            {
                return push_sqlite_fail(L, reuse_error);
            }
        }

        char bind_error[512] = {};
        PreparedBindStatus status = prepared_bind_for_use(
            L, prepared->handle, 2, has_params,
            bind_error, sizeof(bind_error));
        if (status == PreparedBindStatus::OperationalError)
        {
            return push_sqlite_fail(L, bind_error);
        }
        if (status == PreparedBindStatus::ProgrammerError)
        {
            return luaL_error(
                L, "sqlite prepared exec: %s", bind_error);
        }

        int rc = sqlite3_step(prepared->handle);
        while (rc == SQLITE_ROW)
        {
            rc = sqlite3_step(prepared->handle);
        }

        if (rc != SQLITE_DONE)
        {
            std::string msg = sqlite_step_error(prepared->handle, rc);
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

        {
            std::string reuse_error;
            if (!prepared_clear_for_reuse(
                    prepared->handle, reuse_error))
            {
                return push_sqlite_fail(L, reuse_error);
            }
        }

        char bind_error[512] = {};
        PreparedBindStatus status = prepared_bind_for_use(
            L, prepared->handle, 2, has_params,
            bind_error, sizeof(bind_error));
        if (status == PreparedBindStatus::OperationalError)
        {
            return push_sqlite_fail(L, bind_error);
        }
        if (status == PreparedBindStatus::ProgrammerError)
        {
            return luaL_error(
                L, "sqlite prepared query: %s", bind_error);
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
            std::string msg = sqlite_step_error(prepared->handle, rc);
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

    // Owns one Babet-generated savepoint after SAVEPOINT succeeds. Nested
    // helpers each have their own guard and increment the per-connection
    // depth. The destructor performs an allocation-free best-effort
    // ROLLBACK TO + RELEASE so a C++ exception cannot strand the savepoint.
    //
    // As with TransactionGuard, all Lua calls made while this guard is armed
    // must be protected by lua_pcall or have their stack capacity reserved
    // before SAVEPOINT.
    class SavepointGuard
    {
    public:
        SavepointGuard(Db *owner, const char *rollback_sql,
                       const char *release_sql) noexcept
            : owner_(owner), handle_(owner ? owner->handle : nullptr)
        {
            std::snprintf(rollback_sql_, sizeof(rollback_sql_), "%s",
                          rollback_sql);
            std::snprintf(release_sql_, sizeof(release_sql_), "%s",
                          release_sql);
            if (owner_)
            {
                ++owner_->savepoint_depth;
            }
        }

        SavepointGuard(const SavepointGuard &) = delete;
        SavepointGuard &operator=(const SavepointGuard &) = delete;

        ~SavepointGuard() noexcept
        {
            emergency_cleanup();
        }

        void release() noexcept
        {
            disarm();
        }

        void emergency_cleanup() noexcept
        {
            if (!armed_)
            {
                return;
            }

            // A full COMMIT or ROLLBACK performed by the callback destroys
            // every savepoint and restores autocommit. Do not issue two
            // guaranteed-to-fail statements in that already-clean state.
            if (handle_ && sqlite3_get_autocommit(handle_) == 0)
            {
                char *sqlite_error = nullptr;
                sqlite3_exec(handle_, rollback_sql_, nullptr, nullptr,
                             &sqlite_error);
                sqlite3_free(sqlite_error);

                sqlite_error = nullptr;
                sqlite3_exec(handle_, release_sql_, nullptr, nullptr,
                             &sqlite_error);
                sqlite3_free(sqlite_error);
            }
            disarm();
        }

    private:
        void disarm() noexcept
        {
            if (!armed_)
            {
                return;
            }
            if (owner_ && owner_->savepoint_depth > 0)
            {
                --owner_->savepoint_depth;
            }
            armed_ = false;
        }

        Db *owner_ = nullptr;
        sqlite3 *handle_ = nullptr;
        char rollback_sql_[160] = {};
        char release_sql_[160] = {};
        bool armed_ = true;
    };

    // Roll back the work performed since a savepoint, then remove its marker.
    // RELEASE is attempted even when ROLLBACK TO fails so a partially damaged
    // callback cannot leave an otherwise removable savepoint on the stack.
    bool rollback_and_release_savepoint(sqlite3 *db,
                                        const char *rollback_sql,
                                        const char *release_sql,
                                        std::string &error)
    {
        // The transaction may already have been ended explicitly inside the
        // callback. In that case the savepoint is gone and there is nothing
        // left to clean up. The caller is responsible for reporting the
        // contract violation when it observes this state after lua_pcall.
        if (!db || sqlite3_get_autocommit(db) != 0)
        {
            return true;
        }

        std::string rollback_error;
        const bool rollback_ok = exec_transaction_control(
            db, rollback_sql, "rollback to savepoint", rollback_error);

        std::string release_error;
        const bool release_ok = exec_transaction_control(
            db, release_sql, "release after rollback", release_error);

        if (!rollback_ok)
        {
            error = rollback_error;
        }
        if (!release_ok)
        {
            if (!error.empty())
            {
                error += "; ";
            }
            error += release_error;
        }
        return rollback_ok && release_ok;
    }

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
            return push_fail_protected(
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
                return push_fail_protected(L, mode_error);
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
        return db_transaction_impl(L);
    }

    // db:savepoint(fn) -> true, ...callback_results | (nil, err)
    //
    // Babet generates the SQL identifier. A normal callback return RELEASEs
    // the savepoint and forwards all values, including nil/false. A Lua error
    // or a failed outermost RELEASE rolls back to the marker and then removes
    // it. Nested helpers are intentionally supported.
    int db_savepoint_impl(lua_State *L)
    {
        if (!lua_arity_is(L, 2))
        {
            return luaL_error(
                L, "sqlite.savepoint: expected db and callback");
        }

        Db *db = check_db(L, 1);
        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }
        luaL_checktype(L, 2, LUA_TFUNCTION);

        if (db->savepoint_depth == UINT_MAX)
        {
            return push_sqlite_fail(L, "savepoint nesting limit reached");
        }
        if (db->savepoint_sequence == ULLONG_MAX)
        {
            return push_sqlite_fail(L, "savepoint identifier space exhausted");
        }

        // Reserve the callback function, its db argument and the leading
        // success boolean before opening the savepoint. No unprotected Lua
        // stack growth is then needed while the guard is armed.
        if (!lua_checkstack(L, 3))
        {
            return push_fail_protected(
                L, "sqlite: savepoint could not reserve Lua stack");
        }

        const unsigned long long sequence = ++db->savepoint_sequence;
        char savepoint_name[48];
        const int savepoint_name_len = std::snprintf(
            savepoint_name, sizeof(savepoint_name), "babet_sp_%llu",
            sequence);
        if (savepoint_name_len < 0 ||
            static_cast<size_t>(savepoint_name_len) >=
                sizeof(savepoint_name))
        {
            return push_sqlite_fail(
                L, "could not create internal savepoint identifier");
        }

        char begin_sql[160];
        char rollback_sql[160];
        char release_sql[160];
        const int begin_sql_len = std::snprintf(
            begin_sql, sizeof(begin_sql), "SAVEPOINT \"%s\"",
            savepoint_name);
        const int rollback_sql_len = std::snprintf(
            rollback_sql, sizeof(rollback_sql), "ROLLBACK TO \"%s\"",
            savepoint_name);
        const int release_sql_len = std::snprintf(
            release_sql, sizeof(release_sql), "RELEASE \"%s\"",
            savepoint_name);
        if (begin_sql_len < 0 || rollback_sql_len < 0 ||
            release_sql_len < 0 ||
            static_cast<size_t>(begin_sql_len) >= sizeof(begin_sql) ||
            static_cast<size_t>(rollback_sql_len) >=
                sizeof(rollback_sql) ||
            static_cast<size_t>(release_sql_len) >= sizeof(release_sql))
        {
            return push_sqlite_fail(
                L, "could not create internal savepoint statement");
        }

        {
            std::string begin_error;
            if (!exec_transaction_control(db->handle, begin_sql, "savepoint",
                                          begin_error))
            {
                return push_sqlite_fail(L, begin_error);
            }
        }

        SavepointGuard savepoint_guard(db, rollback_sql, release_sql);

        lua_settop(L, 2);
        lua_pushvalue(L, 2);
        lua_pushvalue(L, 1);

        const int call_status = lua_pcall(L, 1, LUA_MULTRET, 0);
        if (call_status != LUA_OK)
        {
            const bool transaction_ended =
                sqlite3_get_autocommit(db->handle) != 0;
            std::string cleanup_error;
            bool cleanup_ok = true;
            if (transaction_ended)
            {
                savepoint_guard.release();
            }
            else
            {
                cleanup_ok = rollback_and_release_savepoint(
                    db->handle, rollback_sql, release_sql, cleanup_error);
                if (cleanup_ok)
                {
                    savepoint_guard.release();
                }
                else
                {
                    savepoint_guard.emergency_cleanup();
                }
            }

            std::string callback_error =
                lua_value_to_display_string(L, -1);
            std::string message = "savepoint callback failed: ";
            message += callback_error;
            if (transaction_ended)
            {
                message += "; ";
                message += SAVEPOINT_TRANSACTION_ENDED_ERROR;
            }
            else if (!cleanup_ok)
            {
                message += "; ";
                message += cleanup_error;
            }
            lua_settop(L, 0);
            return push_sqlite_fail(L, message);
        }

        // COMMIT and ROLLBACK both destroy an outermost managed savepoint.
        // Detect that contract violation before RELEASE so the user receives
        // one stable Babet diagnostic rather than repeated SQLite failures
        // containing the generated identifier.
        if (sqlite3_get_autocommit(db->handle) != 0)
        {
            savepoint_guard.release();
            lua_settop(L, 0);
            return push_sqlite_fail(
                L, SAVEPOINT_TRANSACTION_ENDED_ERROR);
        }

        const int callback_results = lua_gettop(L) - 2;

        // Capacity was already reserved before SAVEPOINT. Keep this explicit
        // check symmetrical with db:transaction and defensive against future
        // changes to the callback setup.
        if (!lua_checkstack(L, 1))
        {
            std::string cleanup_error;
            const bool cleanup_ok = rollback_and_release_savepoint(
                db->handle, rollback_sql, release_sql, cleanup_error);
            if (cleanup_ok)
            {
                savepoint_guard.release();
            }
            else
            {
                savepoint_guard.emergency_cleanup();
            }

            std::string message =
                "savepoint could not reserve result stack";
            if (!cleanup_ok)
            {
                message += "; ";
                message += cleanup_error;
            }
            lua_settop(L, 0);
            return push_sqlite_fail(L, message);
        }

        std::string release_error;
        if (!exec_transaction_control(db->handle, release_sql, "release",
                                      release_error))
        {
            std::string cleanup_error;
            const bool cleanup_ok = rollback_and_release_savepoint(
                db->handle, rollback_sql, release_sql, cleanup_error);
            if (cleanup_ok)
            {
                savepoint_guard.release();
            }
            else
            {
                savepoint_guard.emergency_cleanup();
            }

            if (!cleanup_ok)
            {
                release_error += "; ";
                release_error += cleanup_error;
            }
            lua_settop(L, 0);
            return push_sqlite_fail(L, release_error);
        }

        savepoint_guard.release();

        lua_pushboolean(L, 1);
        lua_insert(L, 3);
        lua_remove(L, 1);
        lua_remove(L, 1);
        return callback_results + 1;
    }

    int db_savepoint(lua_State *L)
    {
        return db_savepoint_impl(L);
    }

    class SqliteHandleGuard
    {
    public:
        ~SqliteHandleGuard()
        {
            if (handle_)
            {
                sqlite3_close_v2(handle_);
            }
        }

        sqlite3 **out() noexcept { return &handle_; }
        sqlite3 *get() const noexcept { return handle_; }

        bool close(std::string &error)
        {
            if (!handle_)
            {
                return true;
            }
            const int rc = sqlite3_close(handle_);
            if (rc == SQLITE_OK)
            {
                handle_ = nullptr;
                return true;
            }
            error = sqlite_connection_error(handle_, rc);
            sqlite3_close_v2(handle_);
            handle_ = nullptr;
            return false;
        }

    private:
        sqlite3 *handle_ = nullptr;
    };

    class BackupHandleGuard
    {
    public:
        explicit BackupHandleGuard(sqlite3_backup *handle) noexcept
            : handle_(handle) {}

        ~BackupHandleGuard()
        {
            if (handle_)
            {
                sqlite3_backup_finish(handle_);
            }
        }

        sqlite3_backup *get() const noexcept { return handle_; }

        int finish() noexcept
        {
            if (!handle_)
            {
                return SQLITE_OK;
            }
            sqlite3_backup *handle = handle_;
            handle_ = nullptr;
            return sqlite3_backup_finish(handle);
        }

    private:
        sqlite3_backup *handle_;
    };

    class SqliteStatementGuard
    {
    public:
        ~SqliteStatementGuard()
        {
            if (handle_)
            {
                sqlite3_finalize(handle_);
            }
        }

        sqlite3_stmt **out() noexcept { return &handle_; }

        int finalize() noexcept
        {
            if (!handle_)
            {
                return SQLITE_OK;
            }
            sqlite3_stmt *handle = handle_;
            handle_ = nullptr;
            return sqlite3_finalize(handle);
        }

        sqlite3_stmt *get() const noexcept { return handle_; }

    private:
        sqlite3_stmt *handle_ = nullptr;
    };

    bool read_busy_timeout_ms(sqlite3 *handle, int &timeout_ms,
                              std::string &error)
    {
        SqliteStatementGuard statement;
        int rc = sqlite3_prepare_v2(handle, "PRAGMA busy_timeout", -1,
                                    statement.out(), nullptr);
        if (rc != SQLITE_OK)
        {
            error = sqlite_connection_error(handle, rc);
            return false;
        }

        rc = sqlite3_step(statement.get());
        if (rc != SQLITE_ROW)
        {
            error = sqlite_connection_error(handle, rc);
            return false;
        }

        const sqlite3_int64 value = sqlite3_column_int64(statement.get(), 0);
        if (value < 0 || value > INT_MAX)
        {
            error = "active PRAGMA busy_timeout is outside the supported "
                    "integer range";
            return false;
        }
        timeout_ms = static_cast<int>(value);

        rc = statement.finalize();
        if (rc != SQLITE_OK)
        {
            error = sqlite_connection_error(handle, rc);
            return false;
        }
        return true;
    }

    std::string backup_timeout_error(int rc)
    {
        std::string reason = "backup timed out before completion";
        if (rc == SQLITE_BUSY)
        {
            reason += " (SQLITE_BUSY)";
        }
        else if (rc == SQLITE_LOCKED)
        {
            reason += " (SQLITE_LOCKED)";
        }
        return reason;
    }

    class BusyTimeoutGuard
    {
    public:
        BusyTimeoutGuard(sqlite3 *handle, int restore_ms) noexcept
            : handle_(handle), restore_ms_(restore_ms) {}

        ~BusyTimeoutGuard()
        {
            if (active_)
            {
                sqlite3_busy_timeout(handle_, restore_ms_);
            }
        }

        bool disable(std::string &error)
        {
            const int rc = sqlite3_busy_timeout(handle_, 0);
            if (rc != SQLITE_OK)
            {
                error = sqlite_connection_error(handle_, rc);
                return false;
            }
            active_ = true;
            return true;
        }

        bool restore(std::string &error)
        {
            if (!active_)
            {
                return true;
            }
            const int rc = sqlite3_busy_timeout(handle_, restore_ms_);
            if (rc != SQLITE_OK)
            {
                error = sqlite_connection_error(handle_, rc);
                return false;
            }
            active_ = false;
            return true;
        }

    private:
        sqlite3 *handle_;
        int restore_ms_;
        bool active_ = false;
    };

    // db:backup(path, opts?) -> (true, nil) | (nil, err)
    //
    // The source is always the main database of the current connection. A
    // private same-directory file is populated with sqlite3_backup, closed,
    // synchronized and only then published atomically. Failed and timed-out
    // backups therefore leave the requested destination unchanged.
    int db_backup(lua_State *L)
    {
        if (!lua_arity_between(L, 2, 3))
        {
            return luaL_error(
                L, "sqlite.backup: expected db, destination and optional opts");
        }

        Db *db = check_db(L, 1);
        luaL_checktype(L, 2, LUA_TSTRING);

        // Parse every option before owning C++ strings. Contract errors use
        // luaL_error and must not jump over non-trivial owners.
        const BackupOpts opts = parse_backup_opts(L, 3);

        if (!db->handle)
        {
            return push_sqlite_fail(L, "connection closed");
        }

        std::string destination_path;
        std::string error;
        if (!lua_string_without_nul(L, 2, destination_path,
                                    "sqlite.backup: destination", error))
        {
            return push_fail_protected(L, error);
        }

        babet_sqlite_backup::Destination destination;
        const char *source_filename =
            sqlite3_db_filename(db->handle, "main");
        if (!destination.prepare(destination_path, opts.overwrite,
                                 source_filename, error))
        {
            return push_sqlite_fail(
                L, strip_sqlite_backup_prefix(error));
        }

        int active_busy_timeout_ms = 0;
        if (!read_busy_timeout_ms(db->handle, active_busy_timeout_ms, error))
        {
            return push_sqlite_fail(
                L, "backup could not read the source busy timeout: " + error);
        }

        BusyTimeoutGuard source_busy_timeout(db->handle,
                                             active_busy_timeout_ms);
        if (!source_busy_timeout.disable(error))
        {
            return push_sqlite_fail(
                L, "backup could not disable the source busy handler: " +
                       error);
        }

        SqliteHandleGuard destination_db;
        int rc = sqlite3_open_v2(destination.sqlite_path().c_str(),
                                 destination_db.out(),
                                 SQLITE_OPEN_READWRITE, nullptr);
        if (rc != SQLITE_OK)
        {
            return push_sqlite_fail(
                L, "backup destination open failed: " +
                       sqlite_connection_error(destination_db.get(), rc));
        }
        rc = sqlite3_extended_result_codes(destination_db.get(), 1);
        if (rc != SQLITE_OK)
        {
            return push_sqlite_fail(
                L, "backup destination could not enable extended result "
                   "codes: " +
                       sqlite_connection_error(destination_db.get(), rc));
        }

        rc = sqlite3_busy_timeout(destination_db.get(), 0);
        if (rc != SQLITE_OK)
        {
            return push_sqlite_fail(
                L, "backup destination could not disable its busy handler: " +
                       sqlite_connection_error(destination_db.get(), rc));
        }

        char *pragma_error = nullptr;
        rc = sqlite3_exec(destination_db.get(),
                          "PRAGMA journal_mode=OFF;"
                          "PRAGMA synchronous=OFF;",
                          nullptr, nullptr, &pragma_error);
        if (rc != SQLITE_OK)
        {
            std::string message = pragma_error
                                      ? pragma_error
                                      : sqlite_connection_error(
                                            destination_db.get(), rc);
            sqlite3_free(pragma_error);
            return push_sqlite_fail(
                L, "backup destination setup failed: " + message);
        }
        sqlite3_free(pragma_error);

        sqlite3_backup *raw_backup = sqlite3_backup_init(
            destination_db.get(), "main", db->handle, "main");
        if (!raw_backup)
        {
            return push_sqlite_fail(
                L, "backup initialization failed: " +
                       sqlite_connection_error(
                           destination_db.get(),
                           sqlite3_errcode(destination_db.get())));
        }
        BackupHandleGuard backup(raw_backup);

        using Clock = std::chrono::steady_clock;
        const auto timeout = std::chrono::duration<double>(
            opts.timeout_seconds);
        const auto deadline = Clock::now() +
                              std::chrono::duration_cast<Clock::duration>(
                                  timeout);

        for (;;)
        {
            rc = sqlite3_backup_step(backup.get(), opts.pages_per_step);
            if (rc == SQLITE_DONE)
            {
                break;
            }

            if (rc != SQLITE_OK && rc != SQLITE_BUSY &&
                rc != SQLITE_LOCKED)
            {
                const std::string message = sqlite_connection_error(
                    destination_db.get(), rc);
                return push_sqlite_fail(
                    L, "backup step failed: " + message);
            }

            const auto now = Clock::now();
            if (opts.timeout_seconds == 0.0 || now >= deadline)
            {
                return push_sqlite_fail(L, backup_timeout_error(rc));
            }

            const auto remaining = deadline - now;
            const auto requested_sleep =
                std::chrono::duration_cast<Clock::duration>(
                    std::chrono::duration<double>(opts.sleep_seconds));
            const auto actual_sleep = std::min(requested_sleep, remaining);
            if (actual_sleep > Clock::duration::zero())
            {
                std::this_thread::sleep_for(actual_sleep);
            }
            else
            {
                std::this_thread::yield();
            }

            // sleep_for() may wake slightly after the requested duration. Do
            // not begin another SQLite step once the global deadline passed.
            if (Clock::now() >= deadline)
            {
                return push_sqlite_fail(L, backup_timeout_error(rc));
            }
        }

        rc = backup.finish();
        if (rc != SQLITE_OK)
        {
            return push_sqlite_fail(
                L, "backup finalization failed: " +
                       sqlite_connection_error(destination_db.get(), rc));
        }

        if (!source_busy_timeout.restore(error))
        {
            return push_sqlite_fail(
                L, "backup completed but could not restore the source busy "
                   "handler: " + error);
        }

        if (!destination_db.close(error))
        {
            return push_sqlite_fail(
                L, "backup destination close failed: " + error);
        }

        if (!destination.synchronize(error))
        {
            return push_sqlite_fail(
                L, strip_sqlite_backup_prefix(error));
        }
        if (!destination.publish(error))
        {
            return push_sqlite_fail(
                L, strip_sqlite_backup_prefix(error));
        }

        return push_ok(L);
    }

    // ============================================================
    // API du module : babet.sqlite.open
    // ============================================================

    // babet.sqlite.open(path, opts?) → db | (nil, err)
    //
    // path : ":memory:" pour une DB en RAM (jetable),
    //        sinon un chemin de fichier (créé s'il n'existe pas).
    //
    // opts : { wal = bool, readonly = bool, foreign_keys = bool,
    //          busy_timeout = ms } — tous optionnels.
    int sqlite_open(lua_State *L)
    {
        if (!lua_arity_between(L, 1, 2))
        {
            return luaL_error(
                L, "sqlite.open: expected one or two arguments");
        }
        // luaL_checkstring convertit silencieusement les nombres en
        // strings (sémantique Lua par défaut). On veut rejeter
        // open(42) explicitement : c'est probablement un bug côté
        // appelant, pas une intention d'ouvrir un fichier nommé "42".
        // Pattern aligné sur toml.decode et workers.spawn.
        luaL_checktype(L, 1, LUA_TSTRING);

        // Parse opts first: it may raise a Lua error. No owning C++ string is
        // alive yet, so the longjmp cannot bypass a string destructor.
        OpenOpts opts = parse_open_opts(L, 2);

        // Construire le propriétaire vide et poser __gc avant d'acquérir la
        // connexion native. sqlite3_open() écrit ensuite directement dans le
        // handle du userdata : il n'existe aucune fenêtre où la ressource ne
        // serait pas finalisable.
        Db *db = static_cast<Db *>(lua_newuserdata(L, sizeof(Db)));
        new (db) Db();
        luaL_getmetatable(L, DB_MT);
        lua_setmetatable(L, -2);

        std::string path;
        std::string path_err;
        if (!lua_string_without_nul(L, 1, path,
                                    "sqlite: path", path_err))
        {
            return push_fail_protected(L, path_err);
        }

        // Sans readonly, conserver exactement la politique historique de
        // sqlite3_open() : READWRITE | CREATE. En lecture seule, ne jamais
        // créer le fichier et laisser SQLite refuser toute écriture.
        const int open_flags = opts.readonly
                                   ? SQLITE_OPEN_READONLY
                                   : SQLITE_OPEN_READWRITE |
                                         SQLITE_OPEN_CREATE;
        int rc = sqlite3_open_v2(
            path.c_str(), &db->handle, open_flags, nullptr);
        if (rc != SQLITE_OK)
        {
            std::string msg = db->handle
                                  ? sqlite3_errmsg(db->handle)
                                  : sqlite3_errstr(rc);
            if (db->handle)
            {
                sqlite3_close_v2(db->handle);
                db->handle = nullptr;
            }
            return push_sqlite_fail(L, msg);
        }

        // Appliquer busy_timeout AVANT WAL : si WAL bloque sur lock,
        // on veut le retry automatique.
        if (opts.busy_timeout_ms > 0)
        {
            rc = sqlite3_busy_timeout(db->handle, opts.busy_timeout_ms);
            if (rc != SQLITE_OK)
            {
                std::string msg = sqlite3_errmsg(db->handle);
                sqlite3_close_v2(db->handle);
                db->handle = nullptr;
                return push_sqlite_fail(L, "busy_timeout: " + msg);
            }
        }

        // Fixer explicitement le contrat de la connexion au lieu de dépendre
        // d'une éventuelle option de compilation SQLite. Ce réglage ne modifie
        // pas le fichier et fonctionne donc également en lecture seule.
        rc = sqlite3_db_config(
            db->handle, SQLITE_DBCONFIG_ENABLE_FKEY,
            opts.foreign_keys ? 1 : 0, nullptr);
        if (rc != SQLITE_OK)
        {
            std::string msg = sqlite3_errstr(rc);
            sqlite3_close_v2(db->handle);
            db->handle = nullptr;
            return push_sqlite_fail(L, "foreign_keys: " + msg);
        }

        // Activer WAL si demandé. PRAGMA journal_mode renvoie le mode
        // effectif (peut être "memory" pour :memory:, "wal" pour fichier).
        // On accepte tout retour non-erreur — un mode différent n'est
        // pas une erreur, juste un fallback géré par SQLite lui-même.
        if (opts.wal)
        {
            char *errmsg = nullptr;
            rc = sqlite3_exec(db->handle, "PRAGMA journal_mode=WAL;",
                              nullptr, nullptr, &errmsg);
            if (rc != SQLITE_OK)
            {
                std::string msg = errmsg
                                      ? errmsg
                                      : sqlite3_errmsg(db->handle);
                sqlite3_free(errmsg);
                sqlite3_close_v2(db->handle);
                db->handle = nullptr;
                return push_sqlite_fail(L, "enabling WAL: " + msg);
            }
            sqlite3_free(errmsg);
        }

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
        lua_pushcfunction(L, sqlite_gc_boundary<db_gc>);
        lua_setfield(L, -2, "__gc");

        // __tostring : pour print(db).
        lua_pushcfunction(L, sqlite_lua_boundary<db_tostring>);
        lua_setfield(L, -2, "__tostring");

        // Méthodes : fermeture, exécution, compteurs et transactions.
        lua_pushcfunction(L, sqlite_lua_boundary<db_close>);
        lua_setfield(L, -2, "close");

        lua_pushcfunction(L, sqlite_lua_boundary<db_exec>);
        lua_setfield(L, -2, "exec");

        lua_pushcfunction(L, sqlite_lua_boundary<db_query>);
        lua_setfield(L, -2, "query");

        lua_pushcfunction(L, sqlite_lua_boundary<db_prepare>);
        lua_setfield(L, -2, "prepare");

        lua_pushcfunction(L, sqlite_lua_boundary<db_backup>);
        lua_setfield(L, -2, "backup");

        lua_pushcfunction(L, sqlite_lua_boundary<db_transaction>);
        lua_setfield(L, -2, "transaction");

        lua_pushcfunction(L, sqlite_lua_boundary<db_savepoint>);
        lua_setfield(L, -2, "savepoint");

        lua_pushcfunction(L, sqlite_lua_boundary<db_in_transaction>);
        lua_setfield(L, -2, "in_transaction");

        lua_pushcfunction(L, sqlite_lua_boundary<db_last_insert_rowid>);
        lua_setfield(L, -2, "last_insert_rowid");

        lua_pushcfunction(L, sqlite_lua_boundary<db_changes>);
        lua_setfield(L, -2, "changes");

        lua_pushcfunction(L, sqlite_lua_boundary<db_total_changes>);
        lua_setfield(L, -2, "total_changes");

        // On dépile la métatable, elle reste en registry.
        lua_pop(L, 1);
    }

    void create_blob_metatable(lua_State *L)
    {
        luaL_newmetatable(L, BLOB_MT);

        lua_pushcfunction(L, sqlite_gc_boundary<blob_gc>);
        lua_setfield(L, -2, "__gc");

        lua_pushcfunction(L, sqlite_lua_boundary<blob_tostring>);
        lua_setfield(L, -2, "__tostring");

        // Opaque and immutable: no __index table and no exposed payload.
        lua_pop(L, 1);
    }

    void create_prepared_metatable(lua_State *L)
    {
        luaL_newmetatable(L, PREPARED_MT);

        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");

        lua_pushcfunction(L, sqlite_lua_boundary<prepared_call>);
        lua_setfield(L, -2, "__call");

        lua_pushcfunction(L, sqlite_gc_boundary<prepared_gc>);
        lua_setfield(L, -2, "__gc");

        lua_pushcfunction(L, sqlite_lua_boundary<prepared_tostring>);
        lua_setfield(L, -2, "__tostring");

        lua_pushcfunction(L, sqlite_lua_boundary<prepared_exec>);
        lua_setfield(L, -2, "exec");

        lua_pushcfunction(L, sqlite_lua_boundary<prepared_query>);
        lua_setfield(L, -2, "query");

        lua_pushcfunction(L, sqlite_lua_boundary<prepared_reset>);
        lua_setfield(L, -2, "reset");

        lua_pushcfunction(L, sqlite_lua_boundary<prepared_close>);
        lua_setfield(L, -2, "close");

        lua_pushcfunction(L, sqlite_lua_boundary<prepared_close>);
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
        lua_pushcfunction(L, sqlite_lua_boundary<stmt_call>);
        lua_setfield(L, -2, "__call");

        // __gc : finalize le sqlite3_stmt si pas déjà fait.
        lua_pushcfunction(L, sqlite_gc_boundary<stmt_gc>);
        lua_setfield(L, -2, "__gc");

        lua_pushcfunction(L, sqlite_lua_boundary<stmt_scope_close>);
        lua_setfield(L, -2, "__close");

        // __tostring : print(iter) lisible.
        lua_pushcfunction(L, sqlite_lua_boundary<stmt_tostring>);
        lua_setfield(L, -2, "__tostring");

        // Méthode explicite : close.
        lua_pushcfunction(L, sqlite_lua_boundary<stmt_close>);
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

    lua_pushcfunction(L, sqlite_lua_boundary<sqlite_open>);
    lua_setfield(L, -2, "open");

    lua_pushcfunction(L, sqlite_lua_boundary<sqlite_blob>);
    lua_setfield(L, -2, "blob");

    lua_pushlightuserdata(L, &SQLITE_NULL_SENTINEL_KEY);
    lua_setfield(L, -2, "NULL");

    lua_setfield(L, -2, "sqlite");
}
