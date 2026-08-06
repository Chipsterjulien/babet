return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== sqlite (session 3: query + lazy iterator) ===")

do
    local DB = babet.sqlite

    -- Helper : crée une DB avec une table peuplée pour les tests.
    local function setup_users()
        local db = DB.open(":memory:")
        assert(db:exec([[
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                name TEXT,
                age INTEGER,
                bio TEXT
            )
        ]]))
        assert(db:exec("INSERT INTO users VALUES (1, 'alice', 30, NULL)"))
        assert(db:exec("INSERT INTO users VALUES (2, 'bob', 25, 'engineer')"))
        assert(db:exec("INSERT INTO users VALUES (3, 'carol', 40, 'designer')"))
        return db
    end

    -- ----- contrat de base -------------------------------------------
    do
        local db = DB.open(":memory:")
        ok("db.query is a method", type(db.query) == "function")
        db:close()
    end

    -- ----- query sur DB fermée ---------------------------------------
    do
        local db = DB.open(":memory:")
        db:close()
        local iter, err = db:query("SELECT 1")
        ok("query after close -> (nil, err)",
            iter == nil and type(err) == "string")
        ok("  err mentions 'closed'",
            type(err) == "string" and err:find("closed"))
    end

    -- ----- query : validation des arguments --------------------------
    do
        local db = DB.open(":memory:")

        local pok = pcall(db.query, db)
        ok("query() without sql raises", not pok)

        local pok2 = pcall(db.query, db, 42)
        ok("query(number) raises (no coercion)", not pok2)

        local pok3 = pcall(db.query, db, "SELECT 1", "not a table")
        ok("query(sql, string) raises (params not table)", not pok3)

        db:close()
    end

    -- ----- itération basique : 3 rows --------------------------------
    do
        local db = setup_users()

        local rows = {}
        for row in db:query("SELECT id, name FROM users ORDER BY id") do
            table.insert(rows, row)
        end
        ok("iter: 3 rows collected", #rows == 3)
        ok("  row[1].id == 1", rows[1].id == 1)
        ok("  row[1].name == 'alice'", rows[1].name == "alice")
        ok("  row[2].id == 2", rows[2].id == 2)
        ok("  row[2].name == 'bob'", rows[2].name == "bob")
        ok("  row[3].name == 'carol'", rows[3].name == "carol")

        db:close()
    end

    -- ----- WHERE avec bind positionnel -------------------------------
    do
        local db = setup_users()

        local rows = {}
        for row in db:query("SELECT name FROM users WHERE age > ? ORDER BY id", { 28 }) do
            table.insert(rows, row.name)
        end
        ok("WHERE age > 28: returns 2 rows (alice, carol)", #rows == 2)
        ok("  alice present", rows[1] == "alice")
        ok("  carol present", rows[2] == "carol")

        db:close()
    end

    -- ----- WHERE avec bind nommé -------------------------------------
    do
        local db = setup_users()

        local rows = {}
        for row in db:query("SELECT name FROM users WHERE name = :n", { n = "bob" }) do
            table.insert(rows, row.name)
        end
        ok("WHERE name = :n bound to 'bob': 1 row", #rows == 1)
        ok("  it's bob", rows[1] == "bob")

        db:close()
    end

    -- ----- type mapping : INTEGER, TEXT, NULL ------------------------
    do
        local db = setup_users()

        local row
        for r in db:query("SELECT * FROM users WHERE id = 1") do
            row = r
        end
        ok("row fetched (alice)", row ~= nil)
        ok("  id is integer", math.type(row.id) == "integer")
        ok("  id == 1", row.id == 1)
        ok("  name is string", type(row.name) == "string")
        ok("  age is integer", math.type(row.age) == "integer")
        ok("  age == 30", row.age == 30)
        -- bio est NULL → la clé devrait être absente
        ok("  bio (NULL) is absent from table", row.bio == nil)
        ok("  bio (NULL) is also missing from pairs()", (function()
            for k, _ in pairs(row) do
                if k == "bio" then return false end
            end
            return true
        end)())

        db:close()
    end

    -- ----- type mapping : REAL ---------------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x REAL)")
        db:exec("INSERT INTO t VALUES (3.14)")
        db:exec("INSERT INTO t VALUES (2.71828)")

        local rows = {}
        for r in db:query("SELECT x FROM t ORDER BY x") do
            table.insert(rows, r.x)
        end
        ok("REAL: 2 rows", #rows == 2)
        ok("  2.71828 first", math.abs(rows[1] - 2.71828) < 1e-9)
        ok("  3.14 second", math.abs(rows[2] - 3.14) < 1e-9)
        ok("  is float type (not integer)", math.type(rows[1]) == "float")

        db:close()
    end

    -- ----- type mapping : BLOB ---------------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (b BLOB)")
        -- INSERT BLOB via X'...' (hex literal) pour garantir BLOB type
        db:exec("INSERT INTO t VALUES (X'00010203FF')")

        local row
        for r in db:query("SELECT b FROM t") do row = r end
        ok("BLOB row fetched", row ~= nil and row.b ~= nil)
        ok("  BLOB is a string (binary-safe)", type(row.b) == "string")
        ok("  BLOB length == 5", #row.b == 5)
        ok("  byte 0 == 0x00", string.byte(row.b, 1) == 0x00)
        ok("  byte 4 == 0xFF", string.byte(row.b, 5) == 0xFF)

        db:close()
    end

    -- ----- type mapping : TEXT avec NUL embarqué ---------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (s)")
        db:exec("INSERT INTO t VALUES (?)", { "a\0b\0c" })

        local row
        for r in db:query("SELECT s FROM t") do row = r end
        ok("TEXT avec NUL: row OK", row ~= nil)
        ok("  longueur preserved (5 bytes)", #row.s == 5)
        ok("  byte 2 == NUL", string.byte(row.s, 2) == 0)

        db:close()
    end

    -- ----- SELECT 0 row : iterator finit immédiatement ---------------
    do
        local db = setup_users()
        local count = 0
        for _ in db:query("SELECT * FROM users WHERE id = 999") do
            count = count + 1
        end
        ok("SELECT with no match: 0 rows", count == 0)
        db:close()
    end

    -- ----- DDL/DML via query : iterator vide (pas d'erreur) ---------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x)")
        local count = 0
        for _ in db:query("INSERT INTO t VALUES (42)") do
            count = count + 1
        end
        ok("query('INSERT'): iterator empty (0 rows)", count == 0)

        -- Vérifier que l'INSERT a quand même été exécuté
        local n = 0
        for _ in db:query("SELECT * FROM t") do n = n + 1 end
        ok("  ... mais l'INSERT a bien eu lieu", n == 1)

        db:close()
    end

    -- ----- query vide/commentaire : itérateur déjà épuisé ----------
    do
        local db = DB.open(":memory:")
        local iter, err = db:query("-- commentaire seulement", {})
        ok("query(comment-only, {}) returns an iterator",
            type(iter) == "userdata" and err == nil,
            "err=" .. tostring(err))
        ok("  iterator is already exhausted", iter() == nil)

        local pok, perr = pcall(db.query, db, "", { x = 1 })
        ok("query('', non-empty params) raises", not pok)
        ok("  message mentions no statement",
            type(perr) == "string" and perr:find("no statement", 1, true))
        db:close()
    end

    -- ----- query est réellement paresseux ----------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x INTEGER)")
        local iter = assert(db:query("INSERT INTO t VALUES (7)"))

        local before
        for row in db:query("SELECT COUNT(*) AS n FROM t") do before = row.n end
        ok("query DML is not stepped before iterator call", before == 0)

        ok("first iterator call executes DML and returns nil", iter() == nil)
        local after
        for row in db:query("SELECT COUNT(*) AS n FROM t") do after = row.n end
        ok("query DML effect visible after iterator call", after == 1)
        db:close()
    end

    -- ----- noms de colonnes dupliqués -------------------------------
    do
        local db = DB.open(":memory:")
        local row
        for r in db:query("SELECT 1 AS x, 2 AS x") do row = r end
        ok("duplicate column names: last value wins", row.x == 2,
            "x=" .. tostring(row and row.x))
        db:close()
    end

    -- ----- erreur au step de l'itérateur ----------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x INTEGER CHECK (x > 0))")
        local iter = assert(db:query("INSERT INTO t VALUES (?)", { -1 }))
        local pok, perr = pcall(iter)
        ok("query step error raises", not pok)
        ok("  message is prefixed with sqlite.query",
            type(perr) == "string" and perr:find("sqlite.query", 1, true))
        db:close()
    end

    -- ----- query sur SQL invalide ------------------------------------
    do
        local db = DB.open(":memory:")
        local iter, err = db:query("SELECT * FROM bogus")
        ok("query(invalid SQL) -> (nil, err)",
            iter == nil and type(err) == "string")
        ok("  err prefixed with 'sqlite: '",
            type(err) == "string" and err:find("^sqlite: "))
        db:close()
    end

    -- ----- multi-statement refusé ------------------------------------
    do
        local db = setup_users()
        local iter, err = db:query("SELECT 1; SELECT 2;")
        ok("multi-statement query -> (nil, err)",
            iter == nil and type(err) == "string")
        ok("  message mentions 'one statement'",
            type(err) == "string" and err:find("one statement"))

        local iter2, err2 = db:query(
            "SELECT 42 AS answer; -- commentaire final\n")
        local row2 = iter2 and iter2()
        ok("LOT 4 query avec commentaire -- final accepté",
            type(iter2) == "userdata" and err2 == nil
            and type(row2) == "table" and row2.answer == 42,
            "err=" .. tostring(err2))
        if iter2 then iter2:close() end

        local iter3, err3 = db:query(
            "SELECT 43 AS answer; /* commentaire final */")
        local row3 = iter3 and iter3()
        ok("LOT 4 query avec commentaire /* */ final accepté",
            type(iter3) == "userdata" and err3 == nil
            and type(row3) == "table" and row3.answer == 43,
            "err=" .. tostring(err3))
        if iter3 then iter3:close() end

        db:close()
    end

    -- ----- bind manquant : raise -------------------------------------
    do
        local db = setup_users()
        local pok, perr = pcall(db.query, db,
            "SELECT * FROM users WHERE age > ?", {})
        ok("query with missing positional param -> raises", not pok)
        ok("  message mentions 'missing'",
            type(perr) == "string" and perr:find("missing"))
        db:close()
    end

    -- ----- close explicite + reprise ---------------------------------
    do
        local db = setup_users()
        local iter = db:query("SELECT id FROM users ORDER BY id")

        local first = iter()
        ok("1er iter() -> row", first ~= nil and first.id == 1)

        iter:close()
        ok_raises("iterator close rejects excess arguments",
            function() return iter:close(true) end,
            "expected only self")
        -- Après close, iter() doit retourner nil (fin) au lieu de planter
        local after_close = iter()
        ok("iter() after close -> nil (terminé)", after_close == nil)

        -- close idempotent
        local ok_ = iter:close()
        ok("iter:close() idempotent", ok_ == true)

        db:close()
    end

    -- ----- break dans la boucle : pas de crash, finalize via __gc ---
    do
        local db = setup_users()
        for row in db:query("SELECT * FROM users ORDER BY id") do
            if row.id == 1 then break end
        end
        ok("break mid-iteration: pas de crash", true)
        -- Vérifier qu'on peut continuer à utiliser la db
        local n = 0
        for _ in db:query("SELECT * FROM users") do n = n + 1 end
        ok("  db usable after break: 3 rows again", n == 3)
        db:close()
    end

    -- ----- db:close() pendant qu'un iter est encore en main ---------
    -- (point 8 du design : SQLite garde le handle zombie tant que
    --  le stmt n'est pas finalizé, donc iter() continue à marcher)
    do
        local db = setup_users()
        local iter = db:query("SELECT id FROM users ORDER BY id")
        db:close()
        local r1 = iter()
        ok("iter() after db:close(): toujours marche (zombie SQLite)",
            r1 ~= nil and r1.id == 1)
        local r2 = iter()
        ok("  encore une row", r2 ~= nil and r2.id == 2)
        iter:close()
        ok("iter:close() après db:close(): OK", true)
    end

    -- ----- tostring(stmt) --------------------------------------------
    do
        local db = setup_users()
        local iter = db:query("SELECT * FROM users")
        local s = tostring(iter)
        ok("tostring(stmt) contains 'sqlite.stmt'",
            type(s) == "string" and s:find("sqlite.stmt"))
        ok("  mentions 'active'",
            type(s) == "string" and s:find("active"))
        iter:close()
        local s2 = tostring(iter)
        ok("tostring after close mentions 'closed'",
            type(s2) == "string" and s2:find("closed"))
        db:close()
    end

    -- ----- transactions manuelles (cas d'usage typique) -------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x INTEGER)")

        db:exec("BEGIN")
        for i = 1, 5 do
            db:exec("INSERT INTO t VALUES (?)", { i })
        end
        db:exec("COMMIT")

        local n = 0
        local sum = 0
        for row in db:query("SELECT x FROM t ORDER BY x") do
            n = n + 1
            sum = sum + row.x
        end
        ok("BEGIN/INSERTs/COMMIT: 5 rows", n == 5)
        ok("  sum == 15", sum == 15)

        -- ROLLBACK
        db:exec("BEGIN")
        db:exec("INSERT INTO t VALUES (?)", { 999 })
        db:exec("ROLLBACK")

        local n2 = 0
        for _ in db:query("SELECT * FROM t") do n2 = n2 + 1 end
        ok("ROLLBACK: toujours 5 rows (pas 6)", n2 == 5)

        db:close()
    end

    -- ----- round-trip de tous les types ------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (i INTEGER, f REAL, s TEXT, b BLOB)")

        -- INSERT avec bind de chaque type
        assert(db:exec("INSERT INTO t VALUES (?, ?, ?, ?)",
            { 42, 3.14, "hello", "\x01\x02\x03" }))

        local row
        for r in db:query(
            "SELECT *, typeof(b) AS b_storage_class FROM t") do
            row = r
        end
        ok("round-trip integer", row.i == 42)
        ok("round-trip float", math.abs(row.f - 3.14) < 1e-9)
        ok("round-trip text", row.s == "hello")
        ok("string bound in BLOB-affinity column keeps 3 bytes", #row.b == 3)
        ok("  first byte == 1", string.byte(row.b, 1) == 1)
        ok("  bound Lua string is stored as SQLite TEXT",
            row.b_storage_class == "text",
            "typeof(b)=" .. tostring(row.b_storage_class))

        db:close()
    end

    -- ----- hardening: SQL with placeholders but no params -----------
    -- (audit point 1) Without this check, "INSERT VALUES (?)" without
    -- params would bind NULL silently. We want explicit error instead.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local ok_, err = db:exec("INSERT INTO t VALUES (?)")
        ok("exec with '?' but no params -> (nil, err)",
            ok_ == nil and type(err) == "string")
        ok("  message mentions 'placeholders'",
            type(err) == "string" and err:find("placeholders"))

        -- Named placeholders too
        local ok2, err2 = db:exec("INSERT INTO t VALUES (:x)")
        ok("exec with ':name' but no params -> (nil, err)",
            ok2 == nil and type(err2) == "string")

        -- Régression (audit v21) : le garde ne sondait que le PREMIER
        -- statement (prepare s'arrête au premier ';') puis relançait
        -- le tout via sqlite3_exec : un '?' dans le 2e statement
        -- passait et liait NULL silencieusement (l'ancien code
        -- rendait true ET une ligne NULL était insérée — les deux
        -- assertions ci-dessous discriminent). Désormais : exécution
        -- statement par statement, garde sur chacun.
        do
            local okm, errm = db:exec(
                "CREATE TABLE t2s (x); INSERT INTO t2s VALUES (?)")
            ok("exec multi-stmt avec '?' dans le 2e -> (nil, err)",
                okm == nil and type(errm) == "string")
            ok("  message mentions 'placeholders'",
                type(errm) == "string" and errm:find("placeholders"))
            -- Le CREATE (1er statement, valide) a été exécuté — comme
            -- sqlite3_exec, l'arrêt se fait AU statement fautif — mais
            -- l'INSERT ne doit jamais avoir tourné : zéro ligne.
            local n = nil
            for row in db:query("SELECT COUNT(*) AS c FROM t2s") do
                n = row.c
            end
            ok("  aucune ligne NULL insérée (COUNT == 0)", n == 0,
                "count=" .. tostring(n))
            -- Sanity : multi-statement propre, toujours OK, et les
            -- effets des DEUX statements sont visibles.
            local oks = db:exec(
                "INSERT INTO t2s VALUES (1); INSERT INTO t2s VALUES (2)")
            ok("exec multi-stmt sans placeholder -> true", oks == true)
            local n2 = nil
            for row in db:query("SELECT COUNT(*) AS c FROM t2s") do
                n2 = row.c
            end
            ok("  2 lignes insérées", n2 == 2, "count=" .. tostring(n2))
        end

        -- query() same check
        local iter, err3 = db:query("SELECT * FROM t WHERE a = ?")
        ok("query with '?' but no params -> (nil, err)",
            iter == nil and type(err3) == "string")
        ok("  message mentions 'placeholders'",
            type(err3) == "string" and err3:find("placeholders"))

        -- Without placeholders, no params is still OK
        local ok4 = db:exec("INSERT INTO t VALUES (1)")
        ok("exec without placeholders, no params -> still OK", ok4 == true)

        db:close()
    end

    -- ----- hardening: sparse numeric keys in params -----------------
    -- (audit point 2) Without this check, { [10] = "x" } would be
    -- silently ignored.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { "ok", [10] = "ignored" })
        ok("bind with sparse numeric key [10] -> raises", not pok)
        ok("  message mentions 'index 10'",
            type(perr) == "string" and perr:find("index 10"))

        local pok2, perr2 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { [1] = "ok", [1.5] = "weird" })
        ok("bind with non-integer numeric key [1.5] -> raises", not pok2)
        ok("  message mentions 'non-integer'",
            type(perr2) == "string" and perr2:find("non%-integer"))

        db:close()
    end

    -- ----- hardening: empty BLOB ------------------------------------
    -- (audit point 3) sqlite3_column_blob() may return NULL for a
    -- zero-byte BLOB. We push an explicit empty string instead.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (b BLOB)")
        db:exec("INSERT INTO t VALUES (X'')") -- BLOB of length 0

        local row
        for r in db:query("SELECT b FROM t") do row = r end
        ok("empty BLOB: row fetched", row ~= nil)
        ok("  b is a string", type(row.b) == "string")
        ok("  #b == 0", #row.b == 0)

        db:close()
    end

    -- ----- hardening: empty TEXT ------------------------------------
    -- (audit follow-up) Same UB risk as BLOB: sqlite3_column_text()
    -- may return NULL for a zero-byte TEXT, and
    -- lua_pushlstring(L, NULL, 0) is UB. We push explicit empty.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (s TEXT)")
        db:exec("INSERT INTO t VALUES ('')") -- TEXT of length 0

        local row
        for r in db:query("SELECT s FROM t") do row = r end
        ok("empty TEXT: row fetched", row ~= nil)
        ok("  s is a string", type(row.s) == "string")
        ok("  #s == 0", #row.s == 0)

        db:close()
    end
end

-- =====================================================================
end
