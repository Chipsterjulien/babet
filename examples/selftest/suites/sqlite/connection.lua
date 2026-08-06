return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== sqlite (session 1: open/close/exec) ===")

do
    local DB = babet.sqlite

    -- ----- contract de base ------------------------------------------
    ok("babet.sqlite is a table", type(DB) == "table")
    ok("open is a function", type(DB.open) == "function")
    ok("sqlite.NULL is an exported lightuserdata sentinel",
        type(DB.NULL) == "userdata" and rawequal(DB.NULL, DB.NULL))

    -- ----- validation des arguments ----------------------------------
    -- path manquant
    do
        local pok = pcall(DB.open)
        ok("open() raises (path missing)", not pok)
    end

    -- path mauvais type
    do
        local pok = pcall(DB.open, 42)
        ok("open(42) raises (path not string)", not pok)
    end

    -- opts mauvais type
    do
        local pok, perr = pcall(DB.open, ":memory:", "bad")
        ok("open(':memory:', 'bad') raises (opts not table)", not pok)
        ok("  message mentions 'table'",
            type(perr) == "string" and perr:find("table"))
    end

    ok_raises("open rejects excess arguments",
        function() return DB.open(":memory:", nil, true) end,
        "one or two arguments")

    ok_raises("open rejects unknown options",
        function() return DB.open(":memory:", { typo = true }) end,
        "unknown option")

    ok_raises("open rejects non-string option keys",
        function() return DB.open(":memory:", { [1] = true }) end,
        "option keys must be strings")

    do
        local hostile_opts = setmetatable({}, {
            __index = function()
                error("sqlite.open must not invoke opts.__index")
            end,
        })
        local db, err = DB.open(":memory:", hostile_opts)
        ok("open options use raw table entries, not __index",
            db ~= nil, tostring(err))
        if db then db:close() end
    end

    -- opts.wal mauvais type
    do
        local pok = pcall(DB.open, ":memory:", { wal = "yes" })
        ok("open(opts.wal = 'yes') raises (wal not boolean)", not pok)
    end

    -- opts.readonly / opts.foreign_keys mauvais types
    ok_raises("open rejects non-boolean opts.readonly",
        function() return DB.open(":memory:", { readonly = 1 }) end,
        "opts.readonly must be a boolean")

    ok_raises("open rejects non-boolean opts.foreign_keys",
        function() return DB.open(":memory:", { foreign_keys = "yes" }) end,
        "opts.foreign_keys must be a boolean")

    ok_raises("open rejects readonly=true combined with wal=true",
        function()
            return DB.open(":memory:", { readonly = true, wal = true })
        end,
        "readonly=true cannot be combined with wal=true")

    -- opts.busy_timeout mauvais type
    do
        local pok = pcall(DB.open, ":memory:", { busy_timeout = "1000" })
        ok("open(opts.busy_timeout = '1000') raises (not integer)", not pok)
    end

    -- opts.busy_timeout négatif
    do
        local pok = pcall(DB.open, ":memory:", { busy_timeout = -5 })
        ok("open(opts.busy_timeout = -5) raises (< 0)", not pok)
    end

    -- opts.busy_timeout absurde
    do
        local pok = pcall(DB.open, ":memory:", { busy_timeout = 99999999 })
        ok("open(opts.busy_timeout = 99999999) raises (sanity max)", not pok)
    end

    -- borne exacte documentée : 0..3 600 000 ms
    do
        local db = DB.open(":memory:", { busy_timeout = 3600000 })
        ok("open(opts.busy_timeout = 3600000) accepted", db ~= nil)
        if db then db:close() end

        local pok = pcall(DB.open, ":memory:", { busy_timeout = 3600001 })
        ok("open(opts.busy_timeout = 3600001) raises", not pok)
    end

    -- ----- ouverture en mémoire (cas le plus simple) -----------------
    do
        local db, err = DB.open(":memory:")
        ok("open(':memory:') -> db", db ~= nil, "err=" .. tostring(err))
        ok("  no error", err == nil)
        ok("  db is userdata", type(db) == "userdata")

        -- exec basique : CREATE TABLE
        local ok_, err2 = db:exec("CREATE TABLE t(a INTEGER, b TEXT)")
        ok("db:exec(CREATE TABLE) -> true", ok_ == true)
        ok("  no error", err2 == nil)

        -- exec INSERT (sans paramètres pour cette session 1)
        local ok2, err3 = db:exec("INSERT INTO t VALUES (1, 'hello')")
        ok("db:exec(INSERT) -> true", ok2 == true)
        ok("  no error", err3 == nil)

        ok_raises("db:exec rejects excess arguments",
            function() return db:exec("SELECT 1", nil, true) end,
            "two or three arguments")
        ok_raises("db:query rejects excess arguments",
            function() return db:query("SELECT 1", nil, true) end,
            "two or three arguments")
        ok_raises("db:close rejects excess arguments",
            function() return db:close(true) end,
            "expected only self")

        -- exec multi-statements (séparés par ';')
        local ok3 = db:exec("INSERT INTO t VALUES (2, 'a'); INSERT INTO t VALUES (3, 'b');")
        ok("db:exec(2 INSERTs séparés par ;) -> true", ok3 == true)

        -- SQL invalide
        local ok4, err4 = db:exec("INSERT INTO bogus VALUES (1)")
        ok("db:exec(INSERT INTO unknown table) -> (nil, err)",
            ok4 == nil and type(err4) == "string")
        ok("  err prefixed with 'sqlite: '",
            type(err4) == "string" and err4:find("^sqlite: "))

        -- close idempotent
        local cok = db:close()
        ok("db:close() -> true", cok == true)

        local cok2 = db:close()
        ok("db:close() again -> true (idempotent)", cok2 == true)

        -- exec après close
        local ok5, err5 = db:exec("SELECT 1")
        ok("db:exec() after close -> (nil, err)",
            ok5 == nil and type(err5) == "string")
        ok("  err mentions 'closed'",
            type(err5) == "string" and err5:find("closed"))

        local closed_prepare, closed_prepare_err = db:prepare("SELECT 1")
        ok("db:prepare() after close -> (nil, err)",
            closed_prepare == nil and type(closed_prepare_err) == "string"
            and closed_prepare_err:find("closed", 1, true) ~= nil)

        local closed_tx, closed_tx_err = db:transaction(function() end)
        ok("db:transaction() after close -> (nil, err)",
            closed_tx == nil and type(closed_tx_err) == "string"
            and closed_tx_err:find("closed", 1, true) ~= nil)

        local closed_state, closed_state_err = db:in_transaction()
        ok("db:in_transaction() after close -> (nil, err)",
            closed_state == nil and type(closed_state_err) == "string"
            and closed_state_err:find("closed", 1, true) ~= nil)

        for _, method in ipairs({
            "last_insert_rowid", "changes", "total_changes",
        }) do
            local value, value_err = db[method](db)
            ok("db:" .. method .. "() after close -> (nil, err)",
                value == nil and type(value_err) == "string"
                and value_err:find("closed", 1, true) ~= nil)
        end
    end

    -- ----- compteurs de connexion ----------------------------------
    do
        local db = assert(DB.open(":memory:"))

        ok("db.last_insert_rowid is a function",
            type(db.last_insert_rowid) == "function")
        ok("db.changes is a function", type(db.changes) == "function")
        ok("db.total_changes is a function",
            type(db.total_changes) == "function")

        ok_raises("db:last_insert_rowid rejects excess arguments",
            function() return db:last_insert_rowid(true) end,
            "expected only self")
        ok_raises("db:changes rejects excess arguments",
            function() return db:changes(true) end,
            "expected only self")
        ok_raises("db:total_changes rejects excess arguments",
            function() return db:total_changes(true) end,
            "expected only self")

        local rowid0, changes0, total0 =
            db:last_insert_rowid(), db:changes(), db:total_changes()
        ok("SQLite counters start at integer zero",
            rowid0 == 0 and changes0 == 0 and total0 == 0
            and math.type(rowid0) == "integer"
            and math.type(changes0) == "integer"
            and math.type(total0) == "integer")

        assert(db:exec(
            "CREATE TABLE counters(id INTEGER PRIMARY KEY, value TEXT)"))
        assert(db:exec(
            "INSERT INTO counters(value) VALUES ('one')"))
        ok("last_insert_rowid reports the latest rowid",
            db:last_insert_rowid() == 1)
        ok("changes reports the latest statement",
            db:changes() == 1)
        ok("total_changes accumulates connection changes",
            db:total_changes() == 1)

        assert(db:exec([[
            INSERT INTO counters(value) VALUES ('two'), ('three')
        ]]))
        ok("last_insert_rowid follows a multi-row INSERT",
            db:last_insert_rowid() == 3)
        ok("changes counts every row changed by the latest statement",
            db:changes() == 2)
        ok("total_changes remains cumulative",
            db:total_changes() == 3)

        assert(db:exec("DELETE FROM counters WHERE id IN (1, 3)"))
        ok("changes counts DELETE rows", db:changes() == 2)
        ok("total_changes includes INSERT and DELETE rows",
            db:total_changes() == 5)

        assert(db:exec(
            "INSERT INTO counters(id, value) VALUES(?, ?)",
            { 5000000000, "wide-rowid" }))
        ok("SQLite counters preserve a rowid above 32 bits",
            db:last_insert_rowid() == 5000000000
            and math.type(db:last_insert_rowid()) == "integer"
            and db:changes() == 1 and db:total_changes() == 6)

        assert(db:exec([[
            CREATE TABLE ignored_inserts(
                id INTEGER PRIMARY KEY,
                value TEXT UNIQUE NOT NULL
            )
        ]]))
        assert(db:exec(
            "INSERT INTO ignored_inserts(id, value) VALUES(?, ?)",
            { 101, "kept" }))
        local rowid_before_ignore = db:last_insert_rowid()
        local total_before_ignore = db:total_changes()
        local ignored_ok, ignored_err = db:exec(
            "INSERT OR IGNORE INTO ignored_inserts(id, value) VALUES(?, ?)",
            { 202, "kept" })
        ok("INSERT OR IGNORE can succeed without inserting a row",
            ignored_ok == true and ignored_err == nil)
        ok("ignored INSERT reports zero changes",
            db:changes() == 0
            and db:total_changes() == total_before_ignore)
        ok("ignored INSERT leaves last_insert_rowid unchanged",
            rowid_before_ignore == 101
            and db:last_insert_rowid() == rowid_before_ignore)

        assert(db:close())
    end

    -- ----- ouverture avec opts ---------------------------------------
    do
        local db = DB.open(":memory:", { busy_timeout = 1000 })
        ok("open(':memory:', busy_timeout=1000) -> db", db ~= nil)
        db:close()
    end

    -- WAL n'est pas applicable à ':memory:' (SQLite fallback automatique),
    -- mais l'option ne doit pas faire planter.
    do
        local db, err = DB.open(":memory:", { wal = true, busy_timeout = 500 })
        ok("open(':memory:', wal=true) -> db (silent fallback)",
            db ~= nil, "err=" .. tostring(err))
        if db then db:close() end
    end

    -- ----- clés étrangères à l'ouverture ----------------------------
    do
        local default_db = assert(DB.open(":memory:"))
        local default_fk
        for row in default_db:query("PRAGMA foreign_keys") do
            default_fk = row.foreign_keys
        end
        ok("foreign_keys defaults to SQLite-compatible false",
            default_fk == 0)
        default_db:close()

        local disabled_db = assert(DB.open(
            ":memory:", { foreign_keys = false }))
        local disabled_fk
        for row in disabled_db:query("PRAGMA foreign_keys") do
            disabled_fk = row.foreign_keys
        end
        ok("foreign_keys=false leaves enforcement disabled",
            disabled_fk == 0)
        disabled_db:close()

        local db = assert(DB.open(
            ":memory:", { foreign_keys = true }))
        local enabled_fk
        for row in db:query("PRAGMA foreign_keys") do
            enabled_fk = row.foreign_keys
        end
        ok("foreign_keys=true enables enforcement at open",
            enabled_fk == 1)

        assert(db:exec([[
            CREATE TABLE parent(id INTEGER PRIMARY KEY);
            CREATE TABLE child(
                id INTEGER PRIMARY KEY,
                parent_id INTEGER REFERENCES parent(id)
            )
        ]]))
        local inserted, insert_err = db:exec(
            "INSERT INTO child(id, parent_id) VALUES(1, 999)")
        ok("foreign_keys=true rejects an orphan row",
            inserted == nil and type(insert_err) == "string"
            and insert_err:find("FOREIGN KEY", 1, true) ~= nil,
            tostring(insert_err))
        db:close()
    end

    -- ----- ouverture strictement en lecture seule -------------------
    do
        local path = sb("sqlite-readonly.db")
        babet.remove(path)

        local writer = assert(DB.open(path))
        assert(writer:exec([[
            CREATE TABLE readonly_probe(id INTEGER PRIMARY KEY, value TEXT);
            INSERT INTO readonly_probe(value) VALUES ('persisted');
        ]]))
        assert(writer:close())

        local reader, reader_err = DB.open(path, {
            readonly = true,
            busy_timeout = 250,
            foreign_keys = true,
        })
        ok("readonly=true opens an existing database",
            reader ~= nil and reader_err == nil, tostring(reader_err))
        if reader then
            local value
            for row in reader:query(
                "SELECT value FROM readonly_probe WHERE id = 1") do
                value = row.value
            end
            ok("readonly connection can query", value == "persisted")

            local wrote, write_err = reader:exec(
                "INSERT INTO readonly_probe(value) VALUES ('forbidden')")
            ok("readonly connection rejects writes",
                wrote == nil and type(write_err) == "string"
                and write_err:find("readonly", 1, true) ~= nil,
                tostring(write_err))
            reader:close()
        end

        local missing = sb("sqlite-readonly-missing.db")
        babet.remove(missing)
        local absent_db, absent_err = DB.open(missing, { readonly = true })
        ok("readonly=true does not create a missing database",
            absent_db == nil and type(absent_err) == "string")
        ok("readonly failure leaves no file behind",
            babet.fileExists(missing) == false)

        babet.remove(path)
    end

    do
        local db, err = DB.open(":memory:\0on-disk")
        ok_fail("LOT 3 sqlite.open: NUL in path rejected", db, err)
    end

    -- ----- erreur d'ouverture (chemin invalide) ----------------------
    -- Sur Linux, "/proc/cant_write_here" devrait échouer car /proc
    -- est en lecture seule pour les fichiers normaux.
    do
        local db, err = DB.open("/proc/nope_cant_create_a_db_here.db")
        if not db then
            ok("open(invalid path) -> (nil, err)", db == nil)
            ok("  err prefixed with 'sqlite: '",
                type(err) == "string" and err:find("^sqlite: "))
        else
            -- Si par hasard ça réussit (FS atypique), on ferme et
            -- on note. Le test reste passant : on a juste vérifié
            -- l'API.
            db:close()
            os.remove("/proc/nope_cant_create_a_db_here.db")
            ok("open(invalid path) -- system allowed it, skipping", true)
        end
    end

    -- ----- tostring --------------------------------------------------
    do
        local db = DB.open(":memory:")
        local s = tostring(db)
        ok("tostring(db) contains 'sqlite'",
            type(s) == "string" and s:find("sqlite"))
        db:close()
        s = tostring(db)
        ok("tostring(db) after close mentions 'closed'",
            type(s) == "string" and s:find("closed"))
    end

    -- ----- GC automatique : on ne stocke pas le db ------------------
    -- Si le __gc est cassé, ça leaker silencieusement. Pas testable
    -- de façon fiable côté Lua, mais au moins on s'assure que ça
    -- ne crash pas.
    do
        for i = 1, 5 do
            local db = DB.open(":memory:")
            db:exec("CREATE TABLE t(x)")
            -- pas de close explicite : __gc devra le faire
        end
        collectgarbage("collect")
        ok("5 open + GC sans crash", true)
    end
end

-- =====================================================================
end
