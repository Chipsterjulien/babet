return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== sqlite (session 2: exec with params) ===")

do
    local DB = babet.sqlite

    -- Helper : nouvelle DB en mémoire avec une table de validation
    -- via CHECK constraint. Permet de tester que le bind produit la
    -- bonne valeur côté SQL sans avoir besoin de db:query (session 3).
    local function fresh_db_with_check(check_sql)
        local db = DB.open(":memory:")
        local ok_, err = db:exec("CREATE TABLE t (val) ")
        if not ok_ then error("setup: CREATE failed: " .. tostring(err)) end
        if check_sql then
            db:exec("DROP TABLE t")
            db:exec("CREATE TABLE t (val CHECK(" .. check_sql .. "))")
        end
        return db
    end

    -- ----- params = nil ou absent : équivalent session 1 ---------------
    do
        local db = DB.open(":memory:")
        local ok_ = db:exec("CREATE TABLE t (x)")
        ok("exec(sql) without params arg -> still works", ok_ == true)

        local ok2 = db:exec("INSERT INTO t VALUES (1)", nil)
        ok("exec(sql, nil) -> same as no params", ok2 == true)

        db:close()
    end

    -- ----- params doit être une table si fourni ----------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x)")

        local pok, perr = pcall(db.exec, db, "INSERT INTO t VALUES (?)", "not a table")
        ok("exec(sql, string) raises (params not table)", not pok)
        ok("  message mentions 'table'",
            type(perr) == "string" and perr:find("table"))

        local pok2 = pcall(db.exec, db, "INSERT INTO t VALUES (?)", 42)
        ok("exec(sql, number) raises (params not table)", not pok2)

        db:close()
    end

    -- ----- LOT 5B : SQL contenant un NUL ----------------------------
    do
        local db = DB.open(":memory:")
        local ev, ee = db:exec(
            "CREATE TABLE nul_guard(x)\0; INSERT INTO nul_guard VALUES (1)")
        ok_fail("LOT 5B sqlite.exec rejects NUL in SQL text", ev, ee)
        ok("  NUL error is explicit",
            type(ee) == "string" and ee:find("NUL", 1, true) ~= nil,
            "err=" .. tostring(ee))

        local created = -1
        for row in db:query([[
            SELECT COUNT(*) AS n
            FROM sqlite_master
            WHERE type = 'table' AND name = 'nul_guard'
        ]]) do
            created = row.n
        end
        ok("  rejected SQL has no executed prefix", created == 0,
            "created=" .. tostring(created))

        local qi, qe = db:query("SELECT 1 AS x\0; SELECT 2 AS x")
        ok_fail("LOT 5B sqlite.query rejects NUL in SQL text", qi, qe)
        ok("  query NUL error is explicit",
            type(qe) == "string" and qe:find("NUL", 1, true) ~= nil,
            "err=" .. tostring(qe))
        db:close()
    end

    -- ----- SQL vide/commentaire avec params -------------------------
    do
        local db = DB.open(":memory:")
        local ok1, err1 = db:exec("", {})
        ok("exec('', {}) is a successful no-op", ok1 == true and err1 == nil,
            "err=" .. tostring(err1))
        local ok2, err2 = db:exec("-- commentaire seulement", {})
        ok("exec(comment-only, {}) is a successful no-op",
            ok2 == true and err2 == nil, "err=" .. tostring(err2))

        local pok, perr = pcall(db.exec, db, "", { 1 })
        ok("exec('', non-empty params) raises", not pok)
        ok("  message mentions no statement",
            type(perr) == "string" and perr:find("no statement", 1, true))
        db:close()
    end

    -- ----- bind positionnel simple -----------------------------------
    do
        local db = fresh_db_with_check("val = 42")

        local ok_, err = db:exec("INSERT INTO t VALUES (?)", { 42 })
        ok("bind positionnel: 42 OK", ok_ == true, "err=" .. tostring(err))

        local ok2, err2 = db:exec("INSERT INTO t VALUES (?)", { 99 })
        ok("bind positionnel: 99 viole CHECK", ok2 == nil)
        ok("  err prefixed with 'sqlite: '",
            type(err2) == "string" and err2:find("^sqlite: "))

        db:close()
    end

    -- ----- bind positionnel : trop de slots, trop peu de params ------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a, b)")

        local pok, perr = pcall(db.exec, db, "INSERT INTO t VALUES (?, ?)", { 1 })
        ok("bind 1 param pour 2 slots -> raises", not pok)
        ok("  message mentions 'missing'",
            type(perr) == "string" and perr:find("missing"))

        local pok2, perr2 = pcall(db.exec, db, "INSERT INTO t VALUES (?, ?)", { 1, 2, 3 })
        ok("bind 3 params pour 2 slots -> raises", not pok2)
        ok("  message mentions 'too many'",
            type(perr2) == "string" and perr2:find("too many"))

        db:close()
    end

    -- ----- bind nommé : ':name' --------------------------------------
    do
        local db = fresh_db_with_check("val = 7")

        local ok_, err = db:exec("INSERT INTO t VALUES (:x)", { x = 7 })
        ok("bind nommé :x = 7 OK", ok_ == true, "err=" .. tostring(err))

        local ok2 = db:exec("INSERT INTO t VALUES (:x)", { x = 99 })
        ok("bind nommé :x = 99 viole CHECK", ok2 == nil)

        db:close()
    end

    -- ----- bind nommé : préfixes alternatifs @ et $ ------------------
    do
        local db = fresh_db_with_check("val = 5")

        local ok_, err = db:exec("INSERT INTO t VALUES (@x)", { x = 5 })
        ok("bind nommé @x = 5 OK (préfixe @ accepté)",
            ok_ == true, "err=" .. tostring(err))

        local ok2, err2 = db:exec("INSERT INTO t VALUES ($x)", { x = 5 })
        ok("bind nommé $x = 5 OK (préfixe $ accepté)",
            ok2 == true, "err=" .. tostring(err2))

        db:close()
    end

    -- ----- bind nommé : param manquant -------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a, b)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (:a, :b)", { a = 1 })
        ok("bind {a=1} pour :a et :b -> raises", not pok)
        ok("  message mentions ':b'",
            type(perr) == "string" and perr:find(":b"))

        db:close()
    end

    -- ----- bind nommé : param en trop --------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (:a)", { a = 1, zzz = "extra" })
        ok("bind {a=1, zzz='extra'} pour :a seul -> raises", not pok)
        ok("  message mentions 'zzz'",
            type(perr) == "string" and perr:find("zzz"))

        local params_with_nul = { a = 1 }
        params_with_nul["a\0evil"] = "extra"
        local pok_nul, perr_nul = pcall(db.exec, db,
            "INSERT INTO t VALUES (:a)", params_with_nul)
        ok("LOT 3 sqlite: NUL in named parameter key is not truncated",
            not pok_nul)
        ok("  NUL key is reported as an extra parameter",
            type(perr_nul) == "string" and perr_nul:find("extra param", 1, true))

        db:close()
    end

    -- ----- mélange positionnel + nommé -------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a, b, c)")

        local ok_, err = db:exec(
            "INSERT INTO t VALUES (?, :name, ?)",
            { "first", "third", name = "second" })
        ok("mélange positionnel + nommé OK",
            ok_ == true, "err=" .. tostring(err))

        db:close()
    end

    -- ----- types Lua : booléens convertis en 0/1 ---------------------
    do
        local db = fresh_db_with_check("val = 1")
        local ok_ = db:exec("INSERT INTO t VALUES (?)", { true })
        ok("bind true -> INTEGER 1 (CHECK val=1 OK)", ok_ == true)
        db:close()

        local db2 = fresh_db_with_check("val = 0")
        local ok2 = db2:exec("INSERT INTO t VALUES (?)", { false })
        ok("bind false -> INTEGER 0 (CHECK val=0 OK)", ok2 == true)
        db2:close()
    end

    -- ----- types Lua : integer / float / string ----------------------
    do
        local db = fresh_db_with_check("val = 42")
        ok("bind integer 42 OK",
            db:exec("INSERT INTO t VALUES (?)", { 42 }) == true)
        db:close()

        local db2 = fresh_db_with_check("val = 3.14")
        ok("bind float 3.14 OK",
            db2:exec("INSERT INTO t VALUES (?)", { 3.14 }) == true)
        db2:close()

        local db3 = fresh_db_with_check("val = 'hello'")
        ok("bind string 'hello' OK",
            db3:exec("INSERT INTO t VALUES (?)", { "hello" }) == true)
        db3:close()

        -- string avec NUL : doit passer (binary-safe)
        local db4 = DB.open(":memory:")
        db4:exec("CREATE TABLE t (val)")
        local ok4 = db4:exec("INSERT INTO t VALUES (?)", { "a\0b\0c" })
        ok("bind string avec NUL embarqués OK", ok4 == true)
        db4:close()
    end

    -- ----- types Lua : refusés (function, table, userdata, thread) --
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (val)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { function() end })
        ok("bind function -> raises", not pok)
        ok("  message mentions 'function'",
            type(perr) == "string" and perr:find("function"))

        local pok2, perr2 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { { nested = true } })
        ok("bind table -> raises", not pok2)
        ok("  message mentions 'table'",
            type(perr2) == "string" and perr2:find("table"))

        -- userdata : on en a sous la main via db lui-même
        local pok3, perr3 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { db })
        ok("bind userdata -> raises", not pok3)
        ok("  message mentions 'userdata'",
            type(perr3) == "string" and perr3:find("userdata"))

        local co = coroutine.create(function() end)
        local pok4, perr4 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { co })
        ok("bind thread (coroutine) -> raises", not pok4)
        ok("  message mentions 'thread'",
            type(perr4) == "string" and perr4:find("thread"))

        db:close()
    end

    -- ----- audit intégral des nombres et de la table params ---------
    do
        local db = DB.open(":memory:")
        assert(db:exec("CREATE TABLE t(a, b, c)"))

        assert(db:exec("INSERT INTO t VALUES(?, ?, ?)",
            { math.mininteger, 0, math.maxinteger }))
        local row = db:query("SELECT a, c FROM t")()
        ok("bind signed 64-bit integers round-trips exactly",
            row.a == math.mininteger and row.c == math.maxinteger)

        local finite_ok = true
        local finite_errors = {}
        for i, value in ipairs({ 0 / 0, math.huge, -math.huge }) do
            local pok, perr = pcall(db.exec, db,
                "INSERT INTO t(a) VALUES(?)", { value })
            finite_ok = finite_ok and not pok
                and type(perr) == "string"
                and perr:find("finite", 1, true) ~= nil
            finite_errors[i] = tostring(perr)
        end
        ok("bind rejects NaN and infinities explicitly", finite_ok,
            table.concat(finite_errors, " | "))

        local false_key_ok, false_key_err = pcall(db.exec, db,
            "INSERT INTO t(a) VALUES(?)", { [1] = 1, [false] = 2 })
        local table_key = {}
        local table_key_ok, table_key_err = pcall(db.exec, db,
            "INSERT INTO t(a) VALUES(?)", { [1] = 1, [table_key] = 2 })
        ok("params table rejects unsupported key types",
            not false_key_ok and not table_key_ok
            and tostring(false_key_err):find("key", 1, true) ~= nil
            and tostring(table_key_err):find("key", 1, true) ~= nil,
            tostring(false_key_err) .. " | " .. tostring(table_key_err))

        local inherited = setmetatable({}, { __index = { value = 7 } })
        ok_raises("named binds use raw table entries, not __index",
            function()
                return db:exec(
                    "INSERT INTO t(a) VALUES(:value)", inherited)
            end,
            "missing param")

        ok_raises("numbered ?NNN placeholders are outside the contract",
            function()
                return db:exec("INSERT INTO t(a) VALUES(?2)", { 1, 2 })
            end,
            "?NNN")

        db:close()
    end

    -- ----- babet.sqlite.NULL : bind explicite et diagnostics --------
    do
        local db = DB.open(":memory:")
        assert(db:exec("CREATE TABLE nullable(a, b, c)"))

        local named_ok, named_err = db:exec(
            "INSERT INTO nullable(a, b) VALUES(:a, :b)",
            { a = "named", b = DB.NULL })
        local named_row = db:query(
            "SELECT a, b, typeof(b) AS b_type FROM nullable WHERE a = ?",
            { "named" })()
        ok("sqlite.NULL binds a named SQL NULL",
            named_ok == true and named_err == nil
            and named_row.a == "named" and named_row.b == nil
            and named_row.b_type == "null",
            "err=" .. tostring(named_err))

        local positional_ok, positional_err = db:exec(
            "INSERT INTO nullable VALUES(?, ?, ?)",
            { "left", DB.NULL, "right" })
        local positional_row = db:query([[
            SELECT a, b, c, typeof(b) AS b_type
            FROM nullable WHERE a = 'left'
        ]])()
        ok("sqlite.NULL fills a positional hole without weakening strict binds",
            positional_ok == true and positional_err == nil
            and positional_row.a == "left" and positional_row.b == nil
            and positional_row.c == "right"
            and positional_row.b_type == "null",
            "err=" .. tostring(positional_err))

        ok_raises("a real missing positional index remains rejected",
            function()
                return db:exec("INSERT INTO nullable VALUES(?, ?, ?)",
                    { [1] = "left", [3] = "right" })
            end,
            "missing positional param at index 2")

        local upvalue = 1
        local function holder() return upvalue end
        local foreign_lightuserdata = debug.upvalueid(holder, 1)
        ok_raises("unknown lightuserdata remains rejected as a bind value",
            function()
                return db:exec("INSERT INTO nullable(a) VALUES(?)",
                    { foreign_lightuserdata })
            end,
            "light userdata")

        local encoded, encode_err = babet.json.encode(DB.NULL)
        ok("json rejects sqlite.NULL with an explicit diagnostic",
            encoded == nil and type(encode_err) == "string"
            and encode_err:find("babet.sqlite.NULL", 1, true) ~= nil,
            tostring(encode_err))

        assert(db:exec("DELETE FROM nullable"))
        assert(db:exec("INSERT INTO nullable(a, b) VALUES(?, ?)",
            { true, false }))
        assert(db:exec("INSERT INTO nullable(a, b) VALUES(?, ?)",
            { DB.NULL, DB.NULL }))
        local bool_row = db:query([[
            SELECT a, b, typeof(a) AS a_type, typeof(b) AS b_type
            FROM nullable ORDER BY rowid LIMIT 1
        ]])()
        local null_row = db:query([[
            SELECT a, b, typeof(a) AS a_type, typeof(b) AS b_type
            FROM nullable ORDER BY rowid DESC LIMIT 1
        ]])()
        ok("boolean and NULL readback keeps the documented asymmetric mapping",
            bool_row.a == 1 and bool_row.b == 0
            and bool_row.a_type == "integer" and bool_row.b_type == "integer"
            and null_row.a == nil and null_row.b == nil
            and null_row.a_type == "null" and null_row.b_type == "null")

        db:close()
    end

    -- ----- multi-statement avec params : refusé ---------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local ok_, err = db:exec(
            "INSERT INTO t VALUES (?); INSERT INTO t VALUES (?);",
            { 1, 2 })
        ok("multi-statement avec params -> (nil, err)",
            ok_ == nil and type(err) == "string")
        ok("  message mentions 'one statement'",
            type(err) == "string" and err:find("one statement"))

        -- Sans params, multi-statement est OK (cas session 1).
        local ok2 = db:exec("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);")
        ok("multi-statement SANS params -> toujours OK (session 1)",
            ok2 == true)

        local ok3, err3 = db:exec(
            "INSERT INTO t VALUES (?); -- commentaire final\n", { 3 })
        ok("LOT 4 exec avec commentaire -- final accepté",
            ok3 == true and err3 == nil, "err=" .. tostring(err3))

        local ok4, err4 = db:exec(
            "INSERT INTO t VALUES (?); /* commentaire final */", { 4 })
        ok("LOT 4 exec avec commentaire /* */ final accepté",
            ok4 == true and err4 == nil, "err=" .. tostring(err4))

        db:close()
    end

    -- ----- SQL invalide avec params : prepare échoue -----------------
    do
        local db = DB.open(":memory:")
        local ok_, err = db:exec("INSERT INTO bogus VALUES (?)", { 1 })
        ok("SQL invalide avec params -> (nil, err)",
            ok_ == nil and type(err) == "string")
        ok("  err prefixed with 'sqlite: '",
            type(err) == "string" and err:find("^sqlite: "))
        db:close()
    end

    -- ----- exec après close : avec params aussi ----------------------
    do
        local db = DB.open(":memory:")
        db:close()
        local ok_, err = db:exec("INSERT INTO t VALUES (?)", { 1 })
        ok("exec(sql, params) after close -> (nil, err)",
            ok_ == nil and type(err) == "string")
    end

    -- ----- pas de leak après bind d'erreur : burst de fails ---------
    -- Si bind_params_from_table fuite le stmt sur erreur, on devrait
    -- voir des fuites SQLite. Pas testable directement, mais on fait
    -- au moins beaucoup d'opérations pour que les fuites éventuelles
    -- soient visibles via top/htop si on regarde.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")
        for i = 1, 100 do
            pcall(db.exec, db, "INSERT INTO t VALUES (?)", { function() end })
        end
        ok("100 binds qui fail : pas de crash", true)
        db:close()
    end
end

-- =====================================================================
end
