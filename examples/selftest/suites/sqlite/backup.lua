return function(test)
    local _ENV = test:environment()

    print("\n=== sqlite backup ===")

    local DB = babet.sqlite
    local root = sb("sqlite_backup")
    babet.rmdirAll(root)
    assert(babet.mkdir(root))

    local function scalar(db, sql, column, params)
        local value
        for row in assert(db:query(sql, params)) do
            value = row[column]
            break
        end
        return value
    end

    local function read_bytes(path)
        local file = assert(io.open(path, "rb"))
        local data = file:read("*a")
        file:close()
        return data
    end

    local function backup_temp_count(directory)
        local count = 0
        for _, item in ipairs(babet.listFiles(directory) or {}) do
            local name = babet.getBasename(item)
            if type(name) == "string"
                and name:find(".babet-sqlite-backup-", 1, true) == 1 then
                count = count + 1
            end
        end
        return count
    end

    local function remove_if_present(path)
        if babet.fileExists(path) then
            babet.remove(path)
        end
    end

    local validation_db = assert(DB.open(":memory:"))
    ok("db.backup is a function", type(validation_db.backup) == "function")

    ok_raises("db:backup requires a destination",
        function() return validation_db:backup() end,
        "destination")
    ok_raises("db:backup destination is a strict string",
        function() return validation_db:backup(42) end,
        "string")
    ok_raises("db:backup rejects excess arguments",
        function()
            return validation_db:backup(root .. "/too-many.db", nil, "extra")
        end,
        "optional opts")
    ok_raises("db:backup opts must be a table",
        function() return validation_db:backup(root .. "/bad.db", 42) end,
        "table")
    ok_raises("db:backup rejects unknown options",
        function()
            return validation_db:backup(root .. "/bad.db", { bogus = true })
        end,
        "unknown option")
    ok_raises("db:backup rejects non-string option keys",
        function()
            return validation_db:backup(root .. "/bad.db", { [1] = true })
        end,
        "keys must be strings")
    ok_raises("db:backup timeout is a strict number",
        function()
            return validation_db:backup(root .. "/bad.db", {
                timeout = "1",
            })
        end,
        "timeout must be a number")
    ok_raises("db:backup rejects negative timeout",
        function()
            return validation_db:backup(root .. "/bad.db", {
                timeout = -1,
            })
        end,
        "finite number >= 0")
    ok_raises("db:backup rejects NaN timeout",
        function()
            return validation_db:backup(root .. "/bad.db", {
                timeout = 0 / 0,
            })
        end,
        "finite number >= 0")
    ok_raises("db:backup rejects infinite timeout",
        function()
            return validation_db:backup(root .. "/bad.db", {
                timeout = math.huge,
            })
        end,
        "finite number >= 0")
    ok_raises("db:backup rejects timeout above 24 hours",
        function()
            return validation_db:backup(root .. "/bad.db", {
                timeout = 86400.1,
            })
        end,
        "max 86400")
    ok_raises("db:backup pages_per_step is a strict integer",
        function()
            return validation_db:backup(root .. "/bad.db", {
                pages_per_step = 1.5,
            })
        end,
        "must be an integer")
    ok_raises("db:backup rejects pages_per_step zero",
        function()
            return validation_db:backup(root .. "/bad.db", {
                pages_per_step = 0,
            })
        end,
        "must be > 0")
    ok_raises("db:backup rejects pages_per_step above INT_MAX",
        function()
            return validation_db:backup(root .. "/bad.db", {
                pages_per_step = math.maxinteger,
            })
        end,
        "INT_MAX")
    ok_raises("db:backup sleep is a strict number",
        function()
            return validation_db:backup(root .. "/bad.db", {
                sleep = "0.01",
            })
        end,
        "sleep must be a number")
    ok_raises("db:backup rejects negative sleep",
        function()
            return validation_db:backup(root .. "/bad.db", {
                sleep = -0.01,
            })
        end,
        "finite number >= 0")
    ok_raises("db:backup rejects infinite sleep",
        function()
            return validation_db:backup(root .. "/bad.db", {
                sleep = math.huge,
            })
        end,
        "finite number >= 0")
    ok_raises("db:backup rejects sleep above 60 seconds",
        function()
            return validation_db:backup(root .. "/bad.db", {
                sleep = 60.1,
            })
        end,
        "max 60")
    ok_raises("db:backup overwrite is a strict boolean",
        function()
            return validation_db:backup(root .. "/bad.db", {
                overwrite = 1,
            })
        end,
        "overwrite must be a boolean")

    local nul_value, nul_err = validation_db:backup(root .. "/nul\0.db")
    ok_fail("db:backup rejects NUL in destination", nul_value, nul_err)
    ok("db:backup NUL diagnostic is explicit",
        type(nul_err) == "string" and nul_err:find("NUL", 1, true) ~= nil,
        tostring(nul_err))

    local empty_value, empty_err = validation_db:backup("")
    ok_fail("db:backup rejects an empty destination", empty_value, empty_err)
    local memory_value, memory_err = validation_db:backup(":memory:")
    ok_fail("db:backup destination must be a filesystem path",
        memory_value, memory_err)

    local meta_calls = 0
    local raw_opts_path = root .. "/raw-options.db"
    local raw_opts = setmetatable({}, {
        __index = function()
            meta_calls = meta_calls + 1
            error("backup options must use raw access")
        end,
    })
    local raw_ok, raw_err = validation_db:backup(raw_opts_path, raw_opts)
    ok_act("db:backup options use raw entries, not __index", raw_ok, raw_err)
    ok("db:backup did not invoke opts.__index", meta_calls == 0,
        "calls=" .. tostring(meta_calls))
    remove_if_present(raw_opts_path)

    local boundary_path = root .. "/boundary-options.db"
    local boundary_ok, boundary_err = validation_db:backup(boundary_path, {
        timeout = 86400,
        pages_per_step = 2147483647,
        sleep = 60,
    })
    ok_act("db:backup accepts exact numeric option boundaries",
        boundary_ok, boundary_err)
    remove_if_present(boundary_path)

    assert(validation_db:close())
    local closed_value, closed_err = validation_db:backup(
        root .. "/closed.db")
    ok_fail("db:backup after close -> (nil, err)",
        closed_value, closed_err)
    ok("db:backup closed diagnostic is explicit",
        type(closed_err) == "string"
            and closed_err:find("closed", 1, true) ~= nil,
        tostring(closed_err))

    -- Empty in-memory database -> real persistent SQLite file.
    local empty_source = assert(DB.open(":memory:"))
    local empty_backup = root .. "/empty.db"
    local empty_ok, empty_backup_err = empty_source:backup(empty_backup)
    ok_act("backup of an empty database succeeds",
        empty_ok, empty_backup_err)
    local empty_mode, empty_mode_err = babet.getMode(empty_backup)
    ok("new SQLite backup is private mode 0600",
        empty_mode == tonumber("600", 8) and empty_mode_err == nil,
        "mode=" .. tostring(empty_mode)
            .. " err=" .. tostring(empty_mode_err))
    assert(empty_source:close())

    local empty_check = assert(DB.open(empty_backup, { readonly = true }))
    ok("empty backup passes PRAGMA integrity_check",
        scalar(empty_check, "PRAGMA integrity_check", "integrity_check")
            == "ok")
    ok("empty backup contains no user schema",
        scalar(empty_check,
            "SELECT COUNT(*) AS n FROM sqlite_master "
                .. "WHERE name NOT LIKE 'sqlite_%'",
            "n") == 0)
    assert(empty_check:close())

    -- Data, schema, index, trigger, reopen and restoration.
    local source_path = root .. "/source.db"
    local backup_path = root .. "/snapshot.db"
    local restore_path = root .. "/restored.db"
    local source = assert(DB.open(source_path, {
        wal = true,
        busy_timeout = 1000,
        foreign_keys = true,
    }))
    assert(source:exec([[
        CREATE TABLE items (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            quantity INTEGER NOT NULL
        );
        CREATE INDEX idx_items_quantity ON items(quantity);
        CREATE TABLE audit (
            item_id INTEGER NOT NULL,
            action TEXT NOT NULL
        );
        CREATE TRIGGER items_after_insert
        AFTER INSERT ON items
        BEGIN
            INSERT INTO audit(item_id, action)
            VALUES (new.id, 'insert');
        END;
        INSERT INTO items(name, quantity) VALUES
            ('alpha', 10), ('beta', 20), ('gamma', 30);
    ]]))

    local backup_ok, backup_err = source:backup(backup_path, {
        timeout = 5,
        pages_per_step = 2,
        sleep = 0.001,
    })
    ok_act("backup with data and options succeeds", backup_ok, backup_err)
    ok("source remains usable after backup",
        scalar(source, "SELECT COUNT(*) AS n FROM items", "n") == 3)

    local snapshot = assert(DB.open(backup_path))
    ok("backup reopens and contains every row",
        scalar(snapshot, "SELECT COUNT(*) AS n FROM items", "n") == 3)
    ok("backup preserves logical data",
        scalar(snapshot,
            "SELECT SUM(quantity) AS total FROM items", "total") == 60)
    ok("backup preserves the explicit index",
        scalar(snapshot,
            "SELECT COUNT(*) AS n FROM sqlite_master "
                .. "WHERE type='index' AND name='idx_items_quantity'",
            "n") == 1)
    ok("backup preserves the trigger",
        scalar(snapshot,
            "SELECT COUNT(*) AS n FROM sqlite_master "
                .. "WHERE type='trigger' AND name='items_after_insert'",
            "n") == 1)
    assert(snapshot:exec(
        "INSERT INTO items(name, quantity) VALUES('delta', 40)"))
    ok("restored trigger executes in the backup",
        scalar(snapshot,
            "SELECT COUNT(*) AS n FROM audit WHERE item_id=4",
            "n") == 1)

    local restore_ok, restore_err = snapshot:backup(restore_path, {
        pages_per_step = 1,
        sleep = 0,
    })
    ok_act("a produced backup can itself be restored",
        restore_ok, restore_err)
    assert(snapshot:close())

    local restored = assert(DB.open(restore_path, { readonly = true }))
    ok("restored copy is readable",
        scalar(restored, "SELECT COUNT(*) AS n FROM items", "n") == 4)
    ok("restored copy keeps the trigger-generated row",
        scalar(restored, "SELECT COUNT(*) AS n FROM audit", "n") == 4)
    assert(restored:close())

    -- Existing destination: refusal by default, explicit atomic replacement.
    local existing_path = root .. "/existing.db"
    assert(write_test_file(existing_path, "sentinel-not-sqlite"))
    local exists_value, exists_err = source:backup(existing_path)
    ok_fail("db:backup refuses an existing destination by default",
        exists_value, exists_err)
    ok("existing destination is unchanged after refusal",
        read_bytes(existing_path) == "sentinel-not-sqlite")

    remove_if_present(existing_path)
    local old_destination = assert(DB.open(existing_path))
    assert(old_destination:exec(
        "CREATE TABLE obsolete(x); INSERT INTO obsolete VALUES(1)"))
    assert(old_destination:close())
    local overwrite_ok, overwrite_err = source:backup(existing_path, {
        overwrite = true,
    })
    ok_act("db:backup overwrite=true replaces atomically",
        overwrite_ok, overwrite_err)
    local overwrite_mode, overwrite_mode_err = babet.getMode(existing_path)
    ok("overwritten SQLite backup is republished as private mode 0600",
        overwrite_mode == tonumber("600", 8)
            and overwrite_mode_err == nil,
        "mode=" .. tostring(overwrite_mode)
            .. " err=" .. tostring(overwrite_mode_err))
    local overwritten = assert(DB.open(existing_path, { readonly = true }))
    ok("overwritten destination now contains the source schema",
        scalar(overwritten, "SELECT COUNT(*) AS n FROM items", "n") == 3)
    ok("overwritten destination no longer contains the old schema",
        scalar(overwritten,
            "SELECT COUNT(*) AS n FROM sqlite_master "
                .. "WHERE name='obsolete'",
            "n") == 0)
    assert(overwritten:close())

    local same_value, same_err = source:backup(source_path, {
        overwrite = true,
    })
    ok_fail("db:backup refuses to replace its source database",
        same_value, same_err)
    ok("source survives same-path refusal",
        scalar(source, "SELECT COUNT(*) AS n FROM items", "n") == 3)

    local hardlink_path = root .. "/source-hardlink.db"
    local hardlink_result = babet.exec("ln", { source_path, hardlink_path })
    if type(hardlink_result) == "table" and hardlink_result.code == 0 then
        local hardlink_value, hardlink_err = source:backup(hardlink_path, {
            overwrite = true,
        })
        ok_fail("db:backup detects a hard link to the source",
            hardlink_value, hardlink_err)
        babet.exec("rm", { "-f", hardlink_path })
    else
        print("[INFO] sqlite backup hard-link test: SKIP (ln unavailable)")
    end

    local sidecar_destination = root .. "/sidecar-destination.db"
    local sidecar_old = assert(DB.open(sidecar_destination))
    assert(sidecar_old:exec("CREATE TABLE old(x)"))
    assert(sidecar_old:close())
    assert(write_test_file(sidecar_destination .. "-wal", "stale"))
    local sidecar_value, sidecar_err = source:backup(sidecar_destination, {
        overwrite = true,
    })
    ok_fail("db:backup refuses a destination with SQLite sidecars",
        sidecar_value, sidecar_err)
    ok("sidecar refusal leaves the existing database intact",
        babet.fileExists(sidecar_destination)
            and read_bytes(sidecar_destination .. "-wal") == "stale")
    remove_if_present(sidecar_destination .. "-wal")

    local symlink_target = root .. "/symlink-target.db"
    local symlink_destination = root .. "/symlink-destination.db"
    assert(write_test_file(symlink_target, "symlink-target"))
    local symlink_result = babet.exec(
        "ln", { "-s", symlink_target, symlink_destination })
    if type(symlink_result) == "table" and symlink_result.code == 0 then
        local symlink_value, symlink_err = source:backup(
            symlink_destination, { overwrite = true })
        ok_fail("db:backup refuses a final destination symlink",
            symlink_value, symlink_err)
        ok("destination symlink target remains unchanged",
            read_bytes(symlink_target) == "symlink-target")
        babet.exec("rm", { "-f", symlink_destination })
    else
        print("[INFO] sqlite backup symlink test: SKIP (ln unavailable)")
    end

    local real_parent = root .. "/real-parent"
    local symlink_parent = root .. "/parent-link"
    assert(babet.mkdir(real_parent))
    local parent_link_result = babet.exec(
        "ln", { "-s", real_parent, symlink_parent })
    if type(parent_link_result) == "table" and parent_link_result.code == 0 then
        local parent_value, parent_err = source:backup(
            symlink_parent .. "/through-link.db")
        ok_fail("db:backup refuses a symlinked parent component",
            parent_value, parent_err)
        ok("symlinked parent receives no backup",
            not babet.fileExists(real_parent .. "/through-link.db"))
        babet.exec("rm", { "-f", symlink_parent })
    else
        print("[INFO] sqlite backup parent-symlink test: SKIP (ln unavailable)")
    end

    local missing_value, missing_err = source:backup(
        root .. "/missing-parent/out.db")
    ok_fail("db:backup does not create missing parents",
        missing_value, missing_err)

    local directory_destination = root .. "/directory-destination"
    assert(babet.mkdir(directory_destination))
    local directory_value, directory_err = source:backup(
        directory_destination, { overwrite = true })
    ok_fail("db:backup refuses a directory destination",
        directory_value, directory_err)

    local fifo_destination = root .. "/fifo-destination"
    local fifo_result = babet.exec("mkfifo", { fifo_destination })
    if type(fifo_result) == "table" and fifo_result.code == 0 then
        local fifo_before = babet.time.monotonic()
        local fifo_value, fifo_err = source:backup(
            fifo_destination, { overwrite = true })
        local fifo_elapsed = babet.time.monotonic() - fifo_before
        ok_fail("db:backup refuses a FIFO destination without blocking",
            fifo_value, fifo_err)
        ok("db:backup FIFO refusal remains bounded",
            fifo_elapsed < 1.0, "elapsed=" .. tostring(fifo_elapsed))
        babet.exec("rm", { "-f", fifo_destination })
    else
        print("[INFO] sqlite backup FIFO test: SKIP (mkfifo unavailable)")
    end

    local readonly_directory = root .. "/readonly-directory"
    assert(babet.mkdir(readonly_directory))
    assert(babet.setMode(readonly_directory, "500"))
    local readonly_value, readonly_err = source:backup(
        readonly_directory .. "/out.db")
    assert(babet.setMode(readonly_directory, "700"))
    local id_result = babet.exec("id", { "-u" })
    local running_as_root = type(id_result) == "table"
        and id_result.code == 0
        and tonumber(id_result.stdout) == 0
    if running_as_root then
        ok("db:backup non-writable destination test skipped as root", true)
        remove_if_present(readonly_directory .. "/out.db")
    else
        ok_fail("db:backup rejects a non-writable destination",
            readonly_value, readonly_err)
    end

    -- Real non-blocking attempt and timeout after partial progress.
    local large_source = assert(DB.open(":memory:"))
    assert(large_source:exec(
        "CREATE TABLE payload(id INTEGER PRIMARY KEY, data TEXT)"))
    local insert = assert(large_source:prepare(
        "INSERT INTO payload(data) VALUES(?)"))
    local payload = string.rep("x", 4096)
    for _ = 1, 512 do
        assert(insert:exec({ payload }))
    end
    assert(insert:close())

    local nonblocking_path = root .. "/nonblocking.db"
    local nonblocking_before = babet.time.monotonic()
    local nonblocking_value, nonblocking_err = large_source:backup(
        nonblocking_path, {
            timeout = 0,
            pages_per_step = 1,
            sleep = 0,
        })
    local nonblocking_elapsed = babet.time.monotonic() - nonblocking_before
    ok_fail("db:backup timeout=0 is a real non-blocking attempt",
        nonblocking_value, nonblocking_err)
    ok("db:backup timeout=0 remains bounded",
        nonblocking_elapsed < 1.0,
        "elapsed=" .. tostring(nonblocking_elapsed))
    ok("non-blocking failure publishes no partial destination",
        not babet.fileExists(nonblocking_path))

    local timeout_path = root .. "/timeout.db"
    local timeout_value, timeout_err = large_source:backup(timeout_path, {
        timeout = 0.01,
        pages_per_step = 1,
        sleep = 0.01,
    })
    ok_fail("db:backup expires a global monotonic deadline",
        timeout_value, timeout_err)
    ok("timeout diagnostic is explicit",
        type(timeout_err) == "string"
            and timeout_err:find("timed out", 1, true) ~= nil,
        tostring(timeout_err))
    ok("mid-backup timeout leaves no partial destination",
        not babet.fileExists(timeout_path))
    ok("mid-backup timeout cleans its temporary file",
        backup_temp_count(root) == 0,
        "temporaries=" .. tostring(backup_temp_count(root)))

    local complete_large_path = root .. "/large-complete.db"
    local complete_large_ok, complete_large_err = large_source:backup(
        complete_large_path, {
            timeout = 5,
            pages_per_step = 64,
            sleep = 0,
        })
    ok_act("large backup succeeds with a sufficient deadline",
        complete_large_ok, complete_large_err)
    assert(large_source:close())

    -- SQLITE_BUSY from another connection and restoration of busy_timeout.
    local busy_path = root .. "/busy-source.db"
    local busy_source = assert(DB.open(busy_path, { busy_timeout = 200 }))
    assert(busy_source:exec(
        "CREATE TABLE t(x); INSERT INTO t VALUES(1)"))
    assert(busy_source:exec("PRAGMA busy_timeout=350"))
    local locker = assert(DB.open(busy_path))
    assert(locker:exec("BEGIN EXCLUSIVE"))

    local busy_backup_path = root .. "/busy-backup.db"
    local busy_before = babet.time.monotonic()
    local busy_value, busy_err = busy_source:backup(busy_backup_path, {
        timeout = 0.05,
        pages_per_step = 1,
        sleep = 0.005,
    })
    local busy_elapsed = babet.time.monotonic() - busy_before
    ok_fail("db:backup handles SQLITE_BUSY with a bounded deadline",
        busy_value, busy_err)
    ok("SQLITE_BUSY diagnostic is preserved",
        type(busy_err) == "string"
            and busy_err:find("SQLITE_BUSY", 1, true) ~= nil,
        tostring(busy_err))
    ok("SQLITE_BUSY handling does not inherit the source busy_timeout",
        busy_elapsed < 0.5,
        "elapsed=" .. tostring(busy_elapsed))
    ok("SQLITE_BUSY failure leaves no destination or temporary",
        not babet.fileExists(busy_backup_path)
            and backup_temp_count(root) == 0)
    assert(locker:exec("ROLLBACK"))

    assert(locker:exec("BEGIN EXCLUSIVE"))
    local restore_before = babet.time.monotonic()
    local blocked_exec, blocked_exec_err = busy_source:exec(
        "INSERT INTO t VALUES(2)")
    local restore_elapsed = babet.time.monotonic() - restore_before
    ok_fail("source operation remains bounded after backup",
        blocked_exec, blocked_exec_err)
    ok("db:backup restores the active PRAGMA busy_timeout",
        restore_elapsed >= 0.30 and restore_elapsed < 1.0,
        "elapsed=" .. tostring(restore_elapsed))
    assert(locker:exec("ROLLBACK"))

    -- SQLite may return BUSY or LOCKED for a write transaction owned by the
    -- source connection depending on its build and locking mode. Babet handles
    -- both codes through the same global deadline.
    assert(busy_source:exec("BEGIN IMMEDIATE; INSERT INTO t VALUES(3)"))
    local self_lock_path = root .. "/self-lock.db"
    local self_lock_value, self_lock_err = busy_source:backup(self_lock_path, {
        timeout = 0.02,
        pages_per_step = 1,
        sleep = 0.002,
    })
    ok_fail("db:backup handles a source write transaction",
        self_lock_value, self_lock_err)
    ok("source write transaction reports SQLITE_BUSY or SQLITE_LOCKED",
        type(self_lock_err) == "string"
            and (self_lock_err:find("SQLITE_BUSY", 1, true) ~= nil
                or self_lock_err:find("SQLITE_LOCKED", 1, true) ~= nil),
        tostring(self_lock_err))
    assert(busy_source:exec("ROLLBACK"))
    assert(locker:close())
    assert(busy_source:close())

    -- WAL source modified by another connection while pages are copied.
    local live_path = root .. "/live-wal.db"
    local live_backup_path = root .. "/live-wal-backup.db"
    local live = assert(DB.open(live_path, {
        wal = true,
        busy_timeout = 2000,
    }))
    assert(live:exec([[
        CREATE TABLE live_rows (
            id INTEGER PRIMARY KEY,
            generation INTEGER NOT NULL,
            payload TEXT NOT NULL
        )
    ]]))
    local live_insert = assert(live:prepare(
        "INSERT INTO live_rows(generation, payload) VALUES(1, ?)"))
    local live_payload = string.rep("z", 2048)
    for _ = 1, 1500 do
        assert(live_insert:exec({ live_payload }))
    end
    assert(live_insert:close())

    local writer = assert(babet.workers.spawn([[
        local root = worker.args.root
        local path = worker.args.path
        local deadline = babet.time.monotonic() + 8
        local observed = false
        while babet.time.monotonic() < deadline do
            local files = babet.listFiles(root) or {}
            for _, item in ipairs(files) do
                local name = babet.getBasename(item)
                if type(name) == "string"
                    and name:find(".babet-sqlite-backup-", 1, true) == 1 then
                    -- listFiles(root) returns paths relative to root. Resolve
                    -- the candidate before querying its size; using `item`
                    -- directly would inspect the process current directory.
                    local size = babet.fileSize(root .. "/" .. item)
                    if type(size) == "number" and size >= 65536 then
                        observed = true
                        break
                    end
                end
            end
            if observed then break end
            babet.sleep(1, "ms")
        end
        if not observed then
            return { ok = false, error = "backup temporary was not observed" }
        end

        local db, open_err = babet.sqlite.open(path, {
            wal = true,
            busy_timeout = 2000,
        })
        if not db then return { ok = false, error = open_err } end
        local began, begin_err = db:exec("BEGIN IMMEDIATE")
        if not began then
            db:close()
            return { ok = false, error = begin_err }
        end
        local updated, update_err = db:exec(
            "UPDATE live_rows SET generation=2")
        if not updated then
            db:exec("ROLLBACK")
            db:close()
            return { ok = false, error = update_err }
        end
        local committed, commit_err = db:exec("COMMIT")
        db:close()
        if not committed then
            return { ok = false, error = commit_err }
        end
        return { ok = true }
    ]], {
        root = root,
        path = live_path,
    }))

    local live_ok, live_err = live:backup(live_backup_path, {
        timeout = 10,
        pages_per_step = 1,
        sleep = 0.002,
    })
    ok_act("WAL backup tolerates concurrent committed writes",
        live_ok, live_err)
    local writer_joined, writer_result = writer:join(10)
    ok("concurrent writer observed and modified the live backup source",
        writer_joined == true and type(writer_result) == "table"
            and writer_result.ok == true,
        "joined=" .. tostring(writer_joined)
            .. " result=" .. tostring(writer_result)
            .. " error=" .. tostring(
                type(writer_result) == "table" and writer_result.error))
    ok("live WAL source contains the committed generation",
        scalar(live,
            "SELECT COUNT(*) AS n FROM live_rows WHERE generation=2",
            "n") == 1500)

    local live_snapshot = assert(DB.open(live_backup_path, {
        readonly = true,
    }))
    ok("concurrent WAL backup remains logically consistent",
        scalar(live_snapshot,
            "SELECT COUNT(DISTINCT generation) AS n FROM live_rows",
            "n") == 1)
    ok("concurrent WAL backup contains every row",
        scalar(live_snapshot,
            "SELECT COUNT(*) AS n FROM live_rows", "n") == 1500)
    ok("concurrent WAL backup passes integrity_check",
        scalar(live_snapshot,
            "PRAGMA integrity_check", "integrity_check") == "ok")
    assert(live_snapshot:close())
    assert(live:close())

    ok("SQLite backup leaves no temporary files after all paths",
        backup_temp_count(root) == 0,
        "temporaries=" .. tostring(backup_temp_count(root)))

    assert(source:close())
    assert(babet.rmdirAll(root))
end
