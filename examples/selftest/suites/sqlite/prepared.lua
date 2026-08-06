return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== sqlite (session 4: prepared/blob/transactions) ===")

do
    local DB = babet.sqlite

    -- ----- explicit BLOB wrapper ------------------------------------
    ok("sqlite.blob is a function", type(DB.blob) == "function")

    do
        local pok0 = pcall(DB.blob)
        ok("sqlite.blob requires exactly one argument", not pok0)

        local pok1 = pcall(DB.blob, 42)
        ok("sqlite.blob requires a strict string", not pok1)

        local pok2 = pcall(DB.blob, "x", "extra")
        ok("sqlite.blob rejects extra arguments", not pok2)

        local blob = DB.blob("a\0b")
        ok("sqlite.blob returns userdata", type(blob) == "userdata")
        ok("sqlite.blob tostring is informative",
            tostring(blob):find("sqlite.blob") ~= nil
            and tostring(blob):find("3 bytes") ~= nil)
    end

    -- ----- parent Db collection and SQLite zombie handles ----------
    -- Each of the five tests below keeps the Db only through a weak value.
    -- The first full collection runs the Db __gc finalizer and therefore
    -- sqlite3_close_v2(); the second releases the finalized userdata and
    -- removes it from the weak table. Every test includes `parent_collected`
    -- in its own assertion so it cannot pass while the Db is still reachable.
    local function collect_sqlite_parent(weak)
        collectgarbage("collect")
        collectgarbage("collect")
        return weak[1] == nil
    end

    do
        local weak = setmetatable({}, { __mode = "v" })
        local db = assert(DB.open(":memory:"))
        local prepared = assert(db:prepare("SELECT 42 AS answer"))
        weak[1] = db
        db = nil

        local parent_collected = collect_sqlite_parent(weak)
        local iter, query_err = prepared:query()
        local row = iter and iter()
        ok("prepared remains usable after parent Db collection",
            parent_collected and query_err == nil
            and row ~= nil and row.answer == 42,
            "parent_collected=" .. tostring(parent_collected)
            .. " err=" .. tostring(query_err)
            .. " row=" .. tostring(row))
        prepared:finalize()
    end

    do
        local weak = setmetatable({}, { __mode = "v" })
        local db = assert(DB.open(":memory:"))
        local iter = assert(db:query("SELECT 43 AS answer"))
        weak[1] = db
        db = nil

        local parent_collected = collect_sqlite_parent(weak)
        local row = iter()
        ok("iterator remains usable after parent Db collection",
            parent_collected and row ~= nil and row.answer == 43,
            "parent_collected=" .. tostring(parent_collected)
            .. " row=" .. tostring(row))
        iter:close()
    end

    do
        local weak = setmetatable({}, { __mode = "v" })
        local db = assert(DB.open(":memory:"))
        assert(db:exec("CREATE TABLE unique_values(v TEXT UNIQUE)"))
        assert(db:exec("INSERT INTO unique_values VALUES('duplicate')"))
        local iter = assert(db:query([[
            INSERT INTO unique_values VALUES('duplicate') RETURNING v
        ]]))
        weak[1] = db
        db = nil

        local parent_collected = collect_sqlite_parent(weak)
        local call_ok, err = pcall(iter)
        ok("iterator keeps constraint diagnostic after parent Db collection",
            parent_collected and call_ok == false
            and type(err) == "string"
            and err:find("constraint", 1, true) ~= nil
            and err:find("API misuse", 1, true) == nil,
            "parent_collected=" .. tostring(parent_collected)
            .. " call_ok=" .. tostring(call_ok)
            .. " err=" .. tostring(err))
        iter:close()
    end

    do
        local weak = setmetatable({}, { __mode = "v" })
        local db = assert(DB.open(":memory:"))
        assert(db:exec("CREATE TABLE unique_values(v TEXT UNIQUE)"))
        assert(db:exec("INSERT INTO unique_values VALUES('duplicate')"))
        local prepared = assert(db:prepare(
            "INSERT INTO unique_values VALUES(?)"))
        weak[1] = db
        db = nil

        local parent_collected = collect_sqlite_parent(weak)
        local result, err = prepared:exec({ "duplicate" })
        ok("prepared:exec keeps constraint diagnostic after parent Db collection",
            parent_collected and result == nil
            and type(err) == "string"
            and err:find("constraint", 1, true) ~= nil
            and err:find("API misuse", 1, true) == nil,
            "parent_collected=" .. tostring(parent_collected)
            .. " result=" .. tostring(result)
            .. " err=" .. tostring(err))
        prepared:finalize()
    end

    do
        local weak = setmetatable({}, { __mode = "v" })
        local db = assert(DB.open(":memory:"))
        assert(db:exec("CREATE TABLE unique_values(v TEXT UNIQUE)"))
        assert(db:exec("INSERT INTO unique_values VALUES('duplicate')"))
        local prepared = assert(db:prepare([[
            INSERT INTO unique_values VALUES(?) RETURNING v
        ]]))
        local iter = assert(prepared:query({ "duplicate" }))
        weak[1] = db
        db = nil

        local parent_collected = collect_sqlite_parent(weak)
        local call_ok, err = pcall(iter)
        ok("prepared iterator keeps constraint diagnostic after parent Db collection",
            parent_collected and call_ok == false
            and type(err) == "string"
            and err:find("constraint", 1, true) ~= nil
            and err:find("API misuse", 1, true) == nil,
            "parent_collected=" .. tostring(parent_collected)
            .. " call_ok=" .. tostring(call_ok)
            .. " err=" .. tostring(err))
        prepared:finalize()
    end

    -- ----- prepare contract and reusable exec/query ----------------
    do
        local db = assert(DB.open(":memory:"))
        ok("db.prepare is a function", type(db.prepare) == "function")
        ok("db.transaction is a function", type(db.transaction) == "function")
        ok("db.in_transaction is a function",
            type(db.in_transaction) == "function")

        local pok0 = pcall(db.prepare, db)
        ok("db:prepare requires SQL", not pok0)

        local pok1 = pcall(db.prepare, db, 42)
        ok("db:prepare SQL is a strict string", not pok1)

        local pok2 = pcall(db.prepare, db, "SELECT 1", "extra")
        ok("db:prepare rejects extra arguments", not pok2)

        local nul_stmt, nul_err = db:prepare("SELECT 1\0; SELECT 2")
        ok("db:prepare rejects NUL in SQL",
            nul_stmt == nil and type(nul_err) == "string"
            and nul_err:find("NUL"))

        local empty_stmt, empty_err = db:prepare(" -- comment only")
        ok("db:prepare rejects empty/comment-only SQL",
            empty_stmt == nil and type(empty_err) == "string")

        local multi_stmt, multi_err = db:prepare("SELECT 1; SELECT 2")
        ok("db:prepare rejects multiple statements",
            multi_stmt == nil and type(multi_err) == "string"
            and multi_err:find("one statement"))

        local invalid_stmt, invalid_err = db:prepare("SELECT * FROM absent")
        ok("db:prepare invalid SQL -> (nil, err)",
            invalid_stmt == nil and type(invalid_err) == "string"
            and invalid_err:find("^sqlite: "))

        assert(db:exec([[
            CREATE TABLE items (
                id INTEGER PRIMARY KEY,
                payload BLOB NOT NULL,
                label TEXT NOT NULL UNIQUE
            )
        ]]))

        local ins = assert(db:prepare(
            "INSERT INTO items(id, payload, label) VALUES(?, ?, ?)"))
        ok("prepare returns reusable userdata", type(ins) == "userdata")
        ok("prepared tostring mentions ready",
            tostring(ins):find("sqlite.prepared") ~= nil
            and tostring(ins):find("ready") ~= nil)
        ok("prepared methods are exposed",
            type(ins.exec) == "function"
            and type(ins.query) == "function"
            and type(ins.reset) == "function"
            and type(ins.close) == "function"
            and type(ins.finalize) == "function")
        ok("prepared userdata is inert before query()", ins() == nil)

        assert(ins:exec({ 1, DB.blob("\0A"), "one" }))
        assert(ins:exec({ 2, DB.blob("B\0C"), "two" }))
        assert(ins:exec({ 3, DB.blob(""), "three" }))
        ok("prepared:exec can be reused", true)

        assert(db:exec([[
            CREATE TABLE nullable_values (
                id INTEGER PRIMARY KEY,
                payload BLOB
            )
        ]]))
        local nullable = assert(db:prepare(
            "INSERT INTO nullable_values(id, payload) VALUES(?, ?)"))
        assert(nullable:exec({ 1, DB.blob("value") }))
        assert(nullable:exec({ 2, DB.NULL }))
        assert(nullable:exec({ 3, DB.blob("again") }))
        local null_storage = {}
        for row in db:query([[
            SELECT typeof(payload) AS storage
            FROM nullable_values ORDER BY id
        ]]) do
            null_storage[#null_storage + 1] = row.storage
        end
        ok("prepared statement alternates ordinary values and sqlite.NULL",
            #null_storage == 3
            and null_storage[1] == "blob"
            and null_storage[2] == "null"
            and null_storage[3] == "blob")
        nullable:finalize()

        local no_params, no_params_err = ins:exec()
        ok("prepared:exec detects omitted params",
            no_params == nil and type(no_params_err) == "string"
            and no_params_err:find("placeholders"))

        local pok3 = pcall(ins.exec, ins, "bad")
        ok("prepared:exec params must be a table", not pok3)

        local pok4, perr4 = pcall(ins.exec, ins,
            { 4, DB.blob("x"), "four", "extra" })
        ok("prepared:exec rejects extra params",
            not pok4 and type(perr4) == "string"
            and perr4:find("too many"))

        local dup_ok, dup_err = ins:exec({ 4, DB.blob("x"), "one" })
        ok("prepared:exec reports SQLite constraint errors",
            dup_ok == nil and type(dup_err) == "string")
        assert(ins:exec({ 4, DB.blob("x"), "four" }))
        ok("prepared statement remains reusable after step error", true)

        local q = assert(db:prepare([[
            SELECT id, payload, label, typeof(payload) AS payload_type
            FROM items
            WHERE id >= ?
            ORDER BY id
        ]]))

        local iterator = assert(q:query({ 2 }))
        ok("prepared:query returns the same userdata", iterator == q)

        ok_raises("prepared:exec rejects excess arguments",
            function() return q:exec({}, true) end,
            "optional params")
        ok_raises("prepared:query rejects excess arguments",
            function() return q:query({}, true) end,
            "optional params")

        local ids = {}
        local storage_ok = true
        for row in iterator do
            ids[#ids + 1] = row.id
            storage_ok = storage_ok and row.payload_type == "blob"
        end
        ok("prepared query streams rows", #ids == 3
            and ids[1] == 2 and ids[3] == 4)
        ok("explicit blob values use SQLite BLOB storage", storage_ok)
        ok("prepared userdata is inert after query exhaustion", q() == nil)

        local only_four
        for row in q:query({ 4 }) do only_four = row end
        ok("prepared query can be rebound and reused",
            only_four and only_four.id == 4 and only_four.label == "four")

        -- Break early, then reset explicitly before the next execution.
        for _ in q:query({ 1 }) do break end
        local reset_ok, reset_err = q:reset()
        ok("prepared:reset aborts an active iteration",
            reset_ok == true and reset_err == nil)

        ok_raises("prepared:reset rejects excess arguments",
            function() return q:reset(true) end,
            "expected only self")
        ok_raises("prepared:close rejects excess arguments",
            function() return q:close(true) end,
            "expected only self")
        ok_raises("prepared:finalize rejects excess arguments",
            function() return q:finalize(true) end,
            "expected only self")

        local count = 0
        for _ in q:query({ 1 }) do count = count + 1 end
        ok("prepared query works after reset", count == 4)

        -- Starting a new query also resets any previous partial iteration.
        local first = q:query({ 1 })()
        local last = q:query({ 4 })()
        ok("prepared:query automatically resets previous state",
            first and first.id == 1 and last and last.id == 4)
        q:reset()

        local q_missing, q_missing_err = q:query()
        ok("prepared:query detects omitted params",
            q_missing == nil and type(q_missing_err) == "string"
            and q_missing_err:find("placeholders"))

        assert(q:exec({ 1 }))
        ok("prepared:exec exhausts SELECT rows and remains reusable", true)

        -- A prepared statement survives db:close() through close_v2.
        local zombie = assert(db:prepare(
            "SELECT label FROM items WHERE id = ?"))
        assert(db:close())
        local zombie_row = zombie:query({ 2 })()
        ok("prepared statement remains usable after db:close()",
            zombie_row and zombie_row.label == "two")
        zombie:reset()
        assert(zombie:finalize())

        assert(ins:close())
        assert(ins:close())
        ok("prepared close is idempotent", true)
        ok("prepared tostring mentions closed",
            tostring(ins):find("closed") ~= nil)

        local closed_exec, closed_exec_err = ins:exec({})
        ok("prepared:exec after close -> (nil, err)",
            closed_exec == nil and type(closed_exec_err) == "string"
            and closed_exec_err:find("closed"))
        ok("calling a closed prepared iterator returns nil", ins() == nil)
    end

    -- ----- TEXT remains TEXT; sqlite.blob forces BLOB ---------------
    do
        local db = assert(DB.open(":memory:"))
        assert(db:exec("CREATE TABLE values_test(v)"))
        local stmt = assert(db:prepare("INSERT INTO values_test VALUES(?)"))
        assert(stmt:exec({ "a\0b" }))
        assert(stmt:exec({ DB.blob("a\0b") }))
        assert(stmt:exec({ DB.blob("") }))

        local types = {}
        local lengths = {}
        for row in db:query([[
            SELECT rowid, typeof(v) AS storage,
                   length(CAST(v AS BLOB)) AS len
            FROM values_test ORDER BY rowid
        ]]) do
            types[#types + 1] = row.storage
            lengths[#lengths + 1] = row.len
        end
        ok("plain Lua strings still bind as TEXT",
            types[1] == "text" and lengths[1] == 3)
        ok("sqlite.blob binds the same bytes as BLOB",
            types[2] == "blob" and lengths[2] == 3)
        ok("sqlite.blob preserves an empty BLOB storage class",
            types[3] == "blob" and lengths[3] == 0)

        stmt:finalize()
        db:close()
    end

    -- ----- transaction helper ---------------------------------------
    do
        local db = assert(DB.open(
            ":memory:", { foreign_keys = true }))
        assert(db:exec([[
            CREATE TABLE tx_log (
                id INTEGER PRIMARY KEY,
                value TEXT UNIQUE NOT NULL
            )
        ]]))

        local transaction_fk
        for row in db:query("PRAGMA foreign_keys") do
            transaction_fk = row.foreign_keys
        end
        ok("transaction tests use foreign_keys=true from open",
            transaction_fk == 1)

        ok("in_transaction is false outside a transaction",
            db:in_transaction() == false)
        ok_raises("in_transaction rejects excess arguments",
            function() return db:in_transaction(true) end,
            "expected only self")

        local tx_ok, a, b, c = db:transaction(function(tx)
            ok("in_transaction is true inside callback",
                tx:in_transaction() == true)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 1, "committed" }))
            return "result", nil, false
        end, "immediate")
        ok("transaction commits and forwards callback values",
            tx_ok == true and a == "result" and b == nil and c == false)
        ok("in_transaction is false after commit",
            db:in_transaction() == false)

        local false_ok, false_value = db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 2, "false-return" }))
            return false
        end)
        ok("normal false callback return still commits",
            false_ok == true and false_value == false)

        local rollback_ok, rollback_err = db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 3, "rolled-back" }))
            error({ code = 99 })
        end, "exclusive")
        ok("transaction callback error returns (nil, err)",
            rollback_ok == nil and type(rollback_err) == "string"
            and rollback_err:find("callback failed"))

        local present = {}
        for row in db:query("SELECT id FROM tx_log ORDER BY id") do
            present[#present + 1] = row.id
        end
        ok("callback error rolls back all writes",
            #present == 2 and present[1] == 1 and present[2] == 2)

        local constraint_ok, constraint_err = db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 4, "committed" })) -- duplicate UNIQUE value
        end)
        ok("asserted SQLite failure rolls transaction back",
            constraint_ok == nil and type(constraint_err) == "string")

        local row4
        for row in db:query("SELECT id FROM tx_log WHERE id = 4") do
            row4 = row
        end
        ok("failed transaction inserted no partial row", row4 == nil)

        -- A deferred foreign-key violation is reported only by COMMIT. The
        -- helper must discard callback results, roll back the write, leave
        -- autocommit restored and keep the connection reusable.
        assert(db:exec([[
            CREATE TABLE tx_parent(id INTEGER PRIMARY KEY);
            CREATE TABLE tx_child(
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL,
                FOREIGN KEY(parent_id) REFERENCES tx_parent(id)
                    DEFERRABLE INITIALLY DEFERRED
            )
        ]]))

        local commit_fail_ok, commit_fail_err, leaked_callback_result =
            db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_child(id, parent_id) VALUES(?, ?)",
                { 1, 999 }))
            return "must-not-be-forwarded"
        end)
        ok("transaction commit failure returns (nil, err)",
            commit_fail_ok == nil
            and type(commit_fail_err) == "string"
            and commit_fail_err:find("commit", 1, true) ~= nil
            and leaked_callback_result == nil)

        local child_count = -1
        for row in db:query("SELECT COUNT(*) AS n FROM tx_child") do
            child_count = row.n
        end
        ok("failed commit rolls back deferred writes", child_count == 0)
        ok("failed commit restores autocommit",
            db:in_transaction() == false)

        local commit_reuse_ok = db:transaction(function(tx)
            assert(tx:exec("INSERT INTO tx_parent(id) VALUES(?)", { 999 }))
            assert(tx:exec(
                "INSERT INTO tx_child(id, parent_id) VALUES(?, ?)",
                { 2, 999 }))
        end)
        ok("connection is reusable after failed commit",
            commit_reuse_ok == true)

        -- A prepared statement used by a failing callback must be reset by
        -- SQLite's rollback and remain reusable afterwards.
        local reusable_stmt = assert(db:prepare(
            "INSERT INTO tx_log(id, value) VALUES(?, ?)"))
        local prepared_tx_ok, prepared_tx_err = db:transaction(function()
            assert(reusable_stmt:exec({ 40, "prepared-rolled-back" }))
            error("prepared callback failure")
        end)
        ok("prepared statement callback error triggers rollback",
            prepared_tx_ok == nil and type(prepared_tx_err) == "string"
            and prepared_tx_err:find("callback failed", 1, true) ~= nil)

        local prepared_rolled_back
        for row in db:query("SELECT id FROM tx_log WHERE id = 40") do
            prepared_rolled_back = row
        end
        ok("prepared statement write is rolled back",
            prepared_rolled_back == nil)

        local prepared_reuse_ok, prepared_reuse_err =
            reusable_stmt:exec({ 41, "prepared-reused" })
        ok("prepared statement is reusable after rollback",
            prepared_reuse_ok == true and prepared_reuse_err == nil)
        reusable_stmt:finalize()

        -- A read iterator may remain active while COMMIT completes; it must
        -- continue from the same statement afterwards.
        local active_iter
        local iter_tx_ok, first_iter_id = db:transaction(function(tx)
            active_iter = assert(tx:query(
                "SELECT id FROM tx_log ORDER BY id"))
            local first = active_iter()
            return first and first.id
        end)
        local second_iter_row = active_iter and active_iter()
        ok("active read iterator survives transaction commit",
            iter_tx_ok == true and first_iter_id == 1
            and type(second_iter_row) == "table"
            and second_iter_row.id == 2)
        if active_iter then active_iter:close() end

        -- Defensive branch coverage: manual transaction control is forbidden
        -- by the public contract, but a callback that already rolled back must
        -- still produce a combined diagnostic and leave the DB reusable.
        local rollback_fail_ok, rollback_fail_err = db:transaction(function(tx)
            assert(tx:exec("ROLLBACK"))
            error("forced callback error after manual control")
        end)
        ok("transaction reports callback and rollback failures",
            rollback_fail_ok == nil
            and type(rollback_fail_err) == "string"
            and rollback_fail_err:find("callback failed", 1, true) ~= nil
            and rollback_fail_err:find("rollback:", 1, true) ~= nil)
        ok("rollback failure path leaves autocommit restored",
            db:in_transaction() == false)

        local rollback_reuse_ok = db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 50, "after-rollback-failure" }))
        end)
        ok("connection is reusable after rollback failure",
            rollback_reuse_ok == true)

        -- Every documented transaction mode is accepted.
        for i, mode in ipairs({ "deferred", "immediate", "exclusive" }) do
            local mode_ok = db:transaction(function(tx)
                assert(tx:exec(
                    "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                    { 10 + i, mode }))
            end, mode)
            ok("transaction mode " .. mode .. " succeeds", mode_ok == true)
        end

        local bad_mode_ok, bad_mode_err = db:transaction(function() end, "bad")
        ok("transaction rejects unknown mode",
            bad_mode_ok == nil and type(bad_mode_err) == "string"
            and bad_mode_err:find("mode"))

        local nul_mode_ok, nul_mode_err = db:transaction(
            function() end, "immediate\0ignored")
        ok("transaction rejects NUL in mode",
            nul_mode_ok == nil and type(nul_mode_err) == "string"
            and nul_mode_err:find("NUL"))

        local pok_cb = pcall(db.transaction, db, "not a function")
        ok("transaction callback must be a function", not pok_cb)

        local pok_mode = pcall(db.transaction, db, function() end, 42)
        ok("transaction mode must be a strict string", not pok_mode)

        local pok_extra = pcall(db.transaction, db,
            function() end, "deferred", "extra")
        ok("transaction rejects extra arguments", not pok_extra)

        -- Nested helper is refused without corrupting the outer helper.
        local outer_ok, nested_ok, nested_err = db:transaction(function(tx)
            return tx:transaction(function() end)
        end)
        ok("nested transaction helper is refused",
            outer_ok == true and nested_ok == nil
            and type(nested_err) == "string"
            and nested_err:find("nested"))

        assert(db:exec("BEGIN"))
        local manual_ok, manual_err = db:transaction(function() end)
        ok("transaction helper refuses an existing manual transaction",
            manual_ok == nil and type(manual_err) == "string"
            and manual_err:find("already"))
        assert(db:exec("ROLLBACK"))

        local close_result, close_error
        local close_tx_ok = db:transaction(function(tx)
            close_result, close_error = tx:close()
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 30, "close-refused" }))
        end)
        ok("db:close is refused inside transaction callback",
            close_tx_ok == true and close_result == nil
            and type(close_error) == "string"
            and close_error:find("transaction callback"))

        assert(db:close())
        local closed_tx, closed_tx_err = db:transaction(function() end)
        ok("transaction after db close -> (nil, err)",
            closed_tx == nil and type(closed_tx_err) == "string"
            and closed_tx_err:find("closed"))
        local closed_state, closed_state_err = db:in_transaction()
        ok("in_transaction after db close -> (nil, err)",
            closed_state == nil and type(closed_state_err) == "string"
            and closed_state_err:find("closed"))
    end

    -- ----- nested savepoint helper ---------------------------------
    do
        local db = assert(DB.open(
            ":memory:", { foreign_keys = true }))
        ok("db.savepoint is a function", type(db.savepoint) == "function")

        assert(db:exec([[
            CREATE TABLE savepoint_log (
                id INTEGER PRIMARY KEY,
                value TEXT UNIQUE NOT NULL
            );
            CREATE TABLE savepoint_parent(id INTEGER PRIMARY KEY);
            CREATE TABLE savepoint_child(
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL,
                FOREIGN KEY(parent_id) REFERENCES savepoint_parent(id)
                    DEFERRABLE INITIALLY DEFERRED
            );
        ]]))

        local save_ok, a, b, c = db:savepoint(function(tx)
            ok("in_transaction is true inside outermost savepoint",
                tx:in_transaction() == true)
            assert(tx:exec(
                "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                { 1, "committed" }))
            return "result", nil, false
        end)
        ok("savepoint releases and forwards callback values",
            save_ok == true and a == "result" and b == nil and c == false)
        ok("outermost savepoint restores autocommit after release",
            db:in_transaction() == false)

        local nil_ok, nil_value, false_value = db:savepoint(function()
            return nil, false
        end)
        ok("normal nil and false callback values still release savepoint",
            nil_ok == true and nil_value == nil and false_value == false)

        local rollback_ok, rollback_err = db:savepoint(function(tx)
            assert(tx:exec(
                "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                { 2, "rolled-back" }))
            error({ code = 99 })
        end)
        ok("savepoint callback error returns (nil, err)",
            rollback_ok == nil and type(rollback_err) == "string"
            and rollback_err:find("callback failed", 1, true) ~= nil)

        local row2
        for row in db:query(
            "SELECT id FROM savepoint_log WHERE id = 2") do
            row2 = row
        end
        ok("savepoint callback error rolls back its writes", row2 == nil)
        ok("outermost savepoint rollback restores autocommit",
            db:in_transaction() == false)

        local reuse_ok, reuse_err = db:savepoint(function(tx)
            assert(tx:exec(
                "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                { 3, "reused" }))
        end)
        ok("connection is reusable after savepoint rollback",
            reuse_ok == true and reuse_err == nil)

        local outer_ok, inner_ok, inner_err = db:savepoint(function(tx)
            assert(tx:exec(
                "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                { 4, "outer-before" }))
            local nested_ok, nested_err = tx:savepoint(function(inner)
                assert(inner:exec(
                    "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                    { 5, "inner-rolled-back" }))
                error("inner failure")
            end)
            assert(tx:exec(
                "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                { 6, "outer-after" }))
            return nested_ok, nested_err
        end)
        ok("failed inner savepoint does not abort outer savepoint",
            outer_ok == true and inner_ok == nil
            and type(inner_err) == "string"
            and inner_err:find("callback failed", 1, true) ~= nil)

        local nested_rows = {}
        for row in db:query([[
            SELECT id FROM savepoint_log WHERE id BETWEEN 4 AND 6 ORDER BY id
        ]]) do
            nested_rows[#nested_rows + 1] = row.id
        end
        ok("inner rollback preserves surrounding savepoint writes",
            #nested_rows == 2
            and nested_rows[1] == 4 and nested_rows[2] == 6)

        local outer_fail_ok, outer_fail_err = db:savepoint(function(tx)
            assert(tx:savepoint(function(inner)
                assert(inner:exec(
                    "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                    { 7, "inner-released" }))
            end))
            error("outer failure")
        end)
        ok("outer savepoint error is reported after inner release",
            outer_fail_ok == nil and type(outer_fail_err) == "string"
            and outer_fail_err:find("outer failure", 1, true) ~= nil)

        local row7
        for row in db:query(
            "SELECT id FROM savepoint_log WHERE id = 7") do
            row7 = row
        end
        ok("outer rollback undoes a released inner savepoint", row7 == nil)

        local three_ok, level2_ok, level3_ok, three_value =
            db:savepoint(function(level1)
            return level1:savepoint(function(level2)
                return level2:savepoint(function(level3)
                    assert(level3:exec(
                        "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                        { 8, "three-levels" }))
                    return "deep"
                end)
            end)
        end)
        ok("three nested savepoints succeed",
            three_ok == true and level2_ok == true
            and level3_ok == true and three_value == "deep")

        local row8
        for row in db:query(
            "SELECT value FROM savepoint_log WHERE id = 8") do
            row8 = row
        end
        ok("three nested savepoints persist the deepest write",
            row8 and row8.value == "three-levels")

        local transaction_ok, transaction_err = db:transaction(function(tx)
            local nested_ok, nested_value = tx:savepoint(function(inner)
                assert(inner:exec(
                    "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                    { 9, "inside-transaction" }))
                return "nested"
            end)
            assert(nested_ok == true and nested_value == "nested")
            ok("savepoint release keeps outer transaction active",
                tx:in_transaction() == true)
            error("rollback outer transaction")
        end)
        ok("outer transaction reports failure after savepoint release",
            transaction_ok == nil and type(transaction_err) == "string")

        local row9
        for row in db:query(
            "SELECT id FROM savepoint_log WHERE id = 9") do
            row9 = row
        end
        ok("outer transaction rollback undoes released savepoint", row9 == nil)

        assert(db:exec("BEGIN"))
        local manual_ok, manual_value = db:savepoint(function(tx)
            assert(tx:exec(
                "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                { 10, "inside-manual" }))
            return "manual"
        end)
        ok("savepoint works inside a manual transaction",
            manual_ok == true and manual_value == "manual"
            and db:in_transaction() == true)
        assert(db:exec("ROLLBACK"))

        local row10
        for row in db:query(
            "SELECT id FROM savepoint_log WHERE id = 10") do
            row10 = row
        end
        ok("manual rollback undoes released savepoint", row10 == nil)

        local explicit_rollback_ok, explicit_rollback_err, leaked_value =
            db:savepoint(function(tx)
                assert(tx:exec(
                    "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                    { 12, "explicit-rollback" }))
                assert(tx:exec("ROLLBACK"))
                return "must-not-be-forwarded"
            end)
        local ended_cause_count = 0
        if type(explicit_rollback_err) == "string" then
            local _
            _, ended_cause_count = explicit_rollback_err:gsub(
                "managed savepoint no longer exists", "")
        end
        ok("explicit rollback returns one clear managed-savepoint error",
            explicit_rollback_ok == nil
            and type(explicit_rollback_err) == "string"
            and explicit_rollback_err:find(
                "ended the transaction explicitly", 1, true) ~= nil
            and explicit_rollback_err:find(
                "no such savepoint", 1, true) == nil
            and explicit_rollback_err:find("babet_sp_", 1, true) == nil
            and ended_cause_count == 1 and leaked_value == nil)
        ok("explicit rollback restores autocommit without extra cleanup",
            db:in_transaction() == false)

        local row12
        for row in db:query(
            "SELECT id FROM savepoint_log WHERE id = 12") do
            row12 = row
        end
        ok("explicit rollback undoes managed-savepoint writes", row12 == nil)

        local after_rollback_ok, after_rollback_value =
            db:savepoint(function(tx)
                assert(tx:exec(
                    "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                    { 13, "after-explicit-rollback" }))
                return "reusable"
            end)
        ok("connection is reusable after explicit callback rollback",
            after_rollback_ok == true
            and after_rollback_value == "reusable")

        local rollback_error_ok, rollback_error_err, rollback_error_extra =
            db:savepoint(function(tx)
                assert(tx:exec(
                    "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                    { 14, "explicit-rollback-then-error" }))
                assert(tx:exec("ROLLBACK"))
                error("boom")
            end)
        local rollback_error_cause_count = 0
        if type(rollback_error_err) == "string" then
            local _
            _, rollback_error_cause_count = rollback_error_err:gsub(
                "managed savepoint no longer exists", "")
        end
        local row14
        for row in db:query(
            "SELECT id FROM savepoint_log WHERE id = 14") do
            row14 = row
        end
        ok("explicit rollback followed by Lua error composes one clear diagnostic",
            rollback_error_ok == nil
            and type(rollback_error_err) == "string"
            and rollback_error_err:find(
                "sqlite: savepoint callback failed:", 1, true) == 1
            and rollback_error_err:find(
                "boom; savepoint callback ended the transaction explicitly; "
                .. "managed savepoint no longer exists", 1, true) ~= nil
            and rollback_error_err:find(
                "no such savepoint", 1, true) == nil
            and rollback_error_err:find("babet_sp_", 1, true) == nil
            and rollback_error_cause_count == 1
            and rollback_error_extra == nil
            and db:in_transaction() == false
            and row14 == nil)

        local release_fail_ok, release_fail_err, leaked_result =
            db:savepoint(function(tx)
                assert(tx:exec([[
                    INSERT INTO savepoint_child(id, parent_id)
                    VALUES(1, 999)
                ]]))
                return "must-not-be-forwarded"
            end)
        ok("outermost savepoint release failure returns (nil, err)",
            release_fail_ok == nil
            and type(release_fail_err) == "string"
            and release_fail_err:find("release", 1, true) ~= nil
            and leaked_result == nil)
        ok("failed outermost release restores autocommit",
            db:in_transaction() == false)

        local child_count = -1
        for row in db:query(
            "SELECT COUNT(*) AS n FROM savepoint_child") do
            child_count = row.n
        end
        ok("failed outermost release rolls back deferred writes",
            child_count == 0)

        local deferred_tx_ok, deferred_tx_err = db:transaction(function(tx)
            local nested_ok, nested_err = tx:savepoint(function(inner)
                assert(inner:exec([[
                    INSERT INTO savepoint_child(id, parent_id)
                    VALUES(2, 999)
                ]]))
            end)
            assert(nested_ok == true, nested_err)
        end)
        ok("inner release defers foreign-key failure to outer commit",
            deferred_tx_ok == nil and type(deferred_tx_err) == "string"
            and deferred_tx_err:find("commit", 1, true) ~= nil)

        child_count = -1
        for row in db:query(
            "SELECT COUNT(*) AS n FROM savepoint_child") do
            child_count = row.n
        end
        ok("failed outer commit rolls back released savepoint writes",
            child_count == 0 and db:in_transaction() == false)

        local close_result, close_error
        local close_savepoint_ok = db:savepoint(function(tx)
            close_result, close_error = tx:close()
            assert(tx:exec(
                "INSERT INTO savepoint_log(id, value) VALUES(?, ?)",
                { 11, "close-refused" }))
        end)
        ok("db:close is refused inside savepoint callback",
            close_savepoint_ok == true and close_result == nil
            and type(close_error) == "string"
            and close_error:find("savepoint callback", 1, true) ~= nil)

        local nested_tx_outer_ok, nested_tx_ok, nested_tx_err =
            db:savepoint(function(tx)
                return tx:transaction(function() end)
            end)
        ok("transaction helper is refused inside savepoint callback",
            nested_tx_outer_ok == true and nested_tx_ok == nil
            and type(nested_tx_err) == "string"
            and nested_tx_err:find("already", 1, true) ~= nil)

        local pok_missing = pcall(db.savepoint, db)
        ok("savepoint requires a callback", not pok_missing)

        local pok_callback = pcall(db.savepoint, db, "not a function")
        ok("savepoint callback must be a function", not pok_callback)

        local pok_extra = pcall(db.savepoint, db, function() end, "extra")
        ok("savepoint rejects extra arguments", not pok_extra)

        assert(db:close())
        local closed_savepoint, closed_savepoint_err =
            db:savepoint(function() end)
        ok("savepoint after db close -> (nil, err)",
            closed_savepoint == nil
            and type(closed_savepoint_err) == "string"
            and closed_savepoint_err:find("closed", 1, true) ~= nil)
    end
end

end
