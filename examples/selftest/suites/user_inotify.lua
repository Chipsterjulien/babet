return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== user ===")

do
    local U = babet.user

    ok("babet.user is a table", type(U) == "table")
    ok("get is a function", type(U.get) == "function")
    ok("exists is a function", type(U.exists) == "function")

    -- Bad arg types : luaL_error (not nil+err).
    ok("get() without arg raises",
        pcall(function() return U.get() end) == false)
    ok("get({}) raises (wrong type)",
        pcall(function() return U.get({}) end) == false)
    ok("get(true) raises (wrong type)",
        pcall(function() return U.get(true) end) == false)
    ok("get(1.5) raises (non-integer)",
        pcall(function() return U.get(1.5) end) == false)
    ok("get(-1) raises (negative uid)",
        pcall(function() return U.get(-1) end) == false)

    -- Hardening : a string with an embedded NUL would be truncated
    -- by getpwnam_r at the first NUL ('root\0evil' seen as 'root').
    -- That could bypass an upstream identity check. We refuse.
    ok("get('root\\0evil') raises (NUL byte in name)",
        pcall(function() return U.get("root\0evil") end) == false)

    -- Hardening : an integer larger than uid_t max (2^32-1 on Linux)
    -- would be silently truncated by the cast and could match an
    -- unrelated UID by chance. We refuse explicitly.
    -- 2^33 = 8589934592 — comfortably above uid_t max but well below
    -- lua_Integer max (LUA_MAXINTEGER ~ 9.2e18).
    ok("get(2^33) raises (uid out of range)",
        pcall(function() return U.get(8589934592) end) == false)

    -- exists() same rules on bad args.
    ok("exists() without arg raises",
        pcall(function() return U.exists() end) == false)
    ok("exists(1.5) raises",
        pcall(function() return U.exists(1.5) end) == false)
    ok("exists('root\\0evil') raises",
        pcall(function() return U.exists("root\0evil") end) == false)
    ok("exists(2^33) raises",
        pcall(function() return U.exists(8589934592) end) == false)

    -- root almost certainly exists on any Linux system the tests run on.
    -- We use it as the "guaranteed present" anchor.
    do
        local u, err = U.get("root")
        ok("get('root') -> table", type(u) == "table" and err == nil)
        if type(u) == "table" then
            ok("  name == 'root'", u.name == "root")
            ok("  uid is integer", type(u.uid) == "number"
                and math.type(u.uid) == "integer")
            ok("  uid == 0", u.uid == 0)
            ok("  gid is integer", type(u.gid) == "number"
                and math.type(u.gid) == "integer")
            ok("  home is string", type(u.home) == "string")
            ok("  shell is string", type(u.shell) == "string")
            ok("  gecos is string (may be empty)",
                type(u.gecos) == "string")
        end
    end

    -- Lookup by UID = 0 must return the same user.
    do
        local u, err = U.get(0)
        ok("get(0) -> table (root by uid)",
            type(u) == "table" and err == nil)
        if type(u) == "table" then
            ok("  name == 'root' (uid 0)", u.name == "root")
        end
    end

    -- Almost-certainly-absent user. We use a deliberately weird
    -- string that is extremely unlikely to clash with a real account.
    local missing = "babet_test_user_xyz_9j3hf83hf"
    do
        local u, err = U.get(missing)
        ok("get(missing) -> (nil, 'user not found')",
            u == nil and err == "user not found")
    end

    -- Same for an unlikely UID. UIDs in [0, 65535] are common but
    -- 2_000_000_000 is extremely unlikely to be assigned.
    do
        local u, err = U.get(2000000000)
        ok("get(very-high-uid) -> (nil, 'user not found')",
            u == nil and err == "user not found")
    end

    -- exists() : pure boolean, no second return value to worry about.
    ok("exists('root') == true", U.exists("root") == true)
    ok("exists(0) == true (uid)", U.exists(0) == true)
    ok("exists(missing) == false", U.exists(missing) == false)
    ok("exists(2000000000) == false",
        U.exists(2000000000) == false)

    -- NSS lookups are available from worker-local Lua states too.
    do
        local w, err = babet.workers.spawn([[
            local u, lookup_err = babet.user.get("root")
            if not u then
                error(lookup_err)
            end
            return u.uid
        ]])
        ok_val("user.get() available in a worker", w, err)
        if w then
            local joined, uid = w:join()
            ok("  worker resolved root uid 0",
                joined == true and uid == 0,
                "joined=" .. tostring(joined)
                .. " uid=" .. tostring(uid))
        end
    end
end

-- =====================================================================
print("")
print("=== inotify ===")

do
    local I = babet.inotify

    -- ----- base contract --------------------------------------------
    ok("babet.inotify is a table", type(I) == "table")
    ok("new is a function", type(I.new) == "function")

    local w, nerr = I.new()
    ok_val("new() -> watcher", w, nerr)
    ok("  add is a method", w ~= nil and type(w.add) == "function")
    ok("  read is a method", w ~= nil and type(w.read) == "function")
    ok("  remove is a method", w ~= nil and type(w.remove) == "function")
    ok("  close is a method", w ~= nil and type(w.close) == "function")

    -- Watched directory, inside the sandbox.
    local WDIR = sb("inotify_d")
    ok_act("mkdir(watch dir)", babet.mkdir(WDIR))

    -- ----- misuse: luaL_error ---------------------------------------
    do
        ok("add() without event list raises",
            pcall(function() return w:add(WDIR) end) == false)
        ok("add(dir, 'string') raises (events not a table)",
            pcall(function() return w:add(WDIR, "create") end) == false)
        ok("read({}) raises (timeout not a number, not coercible)",
            pcall(function() return w:read({}) end) == false)
        ok("new(extra) raises instead of ignoring the argument",
            pcall(function() return I.new(true) end) == false)
        ok("add(path, events, opts, extra) raises",
            pcall(function()
                return w:add(WDIR, { "create" }, nil, true)
            end) == false)
        ok("read(timeout, extra) raises",
            pcall(function() return w:read(0, true) end) == false)
        ok("remove(wd, extra) raises",
            pcall(function() return w:remove(1, true) end) == false)
        ok("close(extra) raises",
            pcall(function() return w:close(true) end) == false)
    end

    -- ----- bad values: (nil, err) -----------------------------------
    do
        local v, e = w:add(WDIR, {})
        ok_fail("add(dir, {}) empty list -> (nil, err)", v, e)
        ok("  message mentions 'empty'",
            type(e) == "string" and e:find("empty", 1, true) ~= nil)

        v, e = w:add(WDIR, { "bogus_event" })
        ok_fail("add(dir, {bogus}) unknown event -> (nil, err)", v, e)
        ok("  message mentions 'unknown'",
            type(e) == "string" and e:find("unknown", 1, true) ~= nil)

        v, e = w:add(sb("inotify_absent"), { "create" })
        ok_fail("add(non-existent path) -> (nil, err)", v, e)

        v, e = w:remove(999999)
        ok_fail("remove(invalid wd) -> (nil, err)", v, e)

        v, e = w:read(-1)
        ok_fail("read(negative timeout) -> (nil, err)", v, e)


        v, e = w:read(1e300)
        ok_fail("LOT 3 inotify.read: huge timeout rejected", v, e)
        ok("  huge timeout message mentions 'too large'",
            type(e) == "string" and e:find("too large", 1, true) ~= nil,
            tostring(e))

        v, e = w:remove(math.maxinteger)
        ok_fail("LOT 3 inotify.remove: wd overflow rejected", v, e)
        ok("  wd overflow message mentions 'range'",
            type(e) == "string" and e:find("range", 1, true) ~= nil,
            tostring(e))

        v, e = w:add(WDIR .. "\0ignored", { "create" })
        ok_fail("LOT 3 inotify.add: NUL in path rejected", v, e)
        v, e = w:add(WDIR, { "create\0ignored" })
        ok_fail("LOT 3 inotify.add: NUL in event rejected", v, e)

        v, e = w:add(WDIR, { "create" }, { onlydir = "false" })
        ok_fail("inotify.add opts.onlydir must be a strict boolean", v, e)
        ok("  onlydir error mentions boolean",
            type(e) == "string" and e:find("boolean", 1, true) ~= nil,
            tostring(e))
    end

    -- ----- onlydir option -------------------------------------------
    do
        local FILE_PATH = WDIR .. "/onlydir-file.txt"
        local f = assert(io.open(FILE_PATH, "w")); f:close()

        local v, e = w:add(FILE_PATH, { "modify" }, { onlydir = true })
        ok_fail("add(file, ..., {onlydir=true}) rejects a non-directory", v, e)

        local file_wd, file_err = w:add(FILE_PATH, { "modify" },
            { onlydir = false })
        ok_val("add(file, ..., {onlydir=false}) remains valid",
            file_wd, file_err,
            function(x) return math.type(x) == "integer" end)
        if file_wd then
            ok_act("remove(file watch)", w:remove(file_wd))
            w:read(0.2) -- consume the kernel-generated ignored event
        end
    end

    -- ----- add a valid watch ----------------------------------------
    local wd, aerr = w:add(WDIR,
        { "create", "close_write", "moved_from", "moved_to" })
    ok_val("add(dir, events) -> integer wd", wd, aerr,
        function(v) return math.type(v) == "integer" end)

    -- Local helpers: drain all pending events (the kernel may batch
    -- several, and one logical action may generate several), and look
    -- one up by (name, flag).
    local function drain(watcher, secs)
        local all = {}
        local timeout = secs
        while true do
            local evs = watcher:read(timeout)
            if not evs then break end -- timeout/closed/err -> end of drain
            for _, ev in ipairs(evs) do all[#all + 1] = ev end
            timeout = 0.1             -- catch any stragglers
        end
        return all
    end

    local function find_event(list, name, flag)
        for _, ev in ipairs(list) do
            if ev.name == name and ev.events[flag] then return ev end
        end
        return nil
    end

    -- ----- file creation + write ------------------------------------
    do
        local f = assert(io.open(WDIR .. "/photo.jpg", "w"))
        f:write("data")
        f:close()

        local evs = drain(w, 2)
        ok("read() returns an array of tables", type(evs) == "table")

        local cr = find_event(evs, "photo.jpg", "create")
        ok("'create' event on photo.jpg", cr ~= nil)

        local cw = find_event(evs, "photo.jpg", "close_write")
        ok("'close_write' event on photo.jpg", cw ~= nil)
        ok("  is_dir == false for a file",
            cw ~= nil and cw.is_dir == false)
        ok("  event wd == watch wd",
            cw ~= nil and cw.wd == wd)
        ok("  cookie == 0 when not a move",
            cw ~= nil and cw.cookie == 0)
    end

    -- ----- is_dir on subdirectory creation --------------------------
    do
        babet.mkdir(WDIR .. "/subdir")
        local evs = drain(w, 2)
        local cr = find_event(evs, "subdir", "create")
        ok("'create' detected on the subdirectory", cr ~= nil)
        ok("  is_dir == true for a directory",
            cr ~= nil and cr.is_dir == true)
    end

    -- ----- moved_from / moved_to paired by cookie -------------------
    do
        os.rename(WDIR .. "/photo.jpg", WDIR .. "/photo2.jpg")
        local evs = drain(w, 2)
        local mf = find_event(evs, "photo.jpg", "moved_from")
        local mt = find_event(evs, "photo2.jpg", "moved_to")
        ok("'moved_from' detected", mf ~= nil)
        ok("'moved_to' detected", mt ~= nil)
        ok("  cookie non-zero and identical between from and to",
            mf ~= nil and mt ~= nil
            and mf.cookie ~= 0 and mf.cookie == mt.cookie)
    end

    -- ----- timeout: non-blocking and finite -------------------------
    do
        drain(w, 0) -- flush any leftover event
        local v, e = w:read(0)
        ok_fail("read(0) with no activity -> (nil, err)", v, e)
        ok("  reason == 'timeout'", e == "timeout")

        v, e = w:read(0.2)
        ok_fail("read(0.2) with no activity -> (nil, err)", v, e)
        ok("  reason == 'timeout'", e == "timeout")
    end

    -- ----- remove() + 'ignored' event -------------------------------
    do
        local r, e = w:remove(wd)
        ok_act("remove(wd) -> (true, nil)", r, e)

        -- The kernel emits an 'ignored' event for that wd right after.
        local evs = drain(w, 1)
        local ig = nil
        for _, ev in ipairs(evs) do
            if ev.wd == wd and ev.events.ignored then ig = ev end
        end
        ok("'ignored' event emitted after remove", ig ~= nil)
    end

    -- ----- audit fixes ----------------------------------------------
    -- These three tests cover bugs that were caught in a post-merge
    -- audit. They MUST be in place before close() since they need
    -- an active watcher.
    do
        -- Re-arm a watch since we removed wd just above.
        local wd2, e_arm = w:add(WDIR, { "create", "close_write" })
        ok_val("re-arm watch for audit tests", wd2, e_arm)

        -- (1) read(0) must return events already pending in the
        -- kernel queue, not (nil, "timeout"). Previously, the
        -- short-circuit before poll() returned timeout without
        -- ever calling poll(fd, 1, 0).
        do
            -- Drain any leftover events first so the queue is clean.
            drain(w, 0.1)

            local f = assert(io.open(WDIR .. "/audit_read0.txt", "w"))
            f:write("x"); f:close()

            -- Give the kernel a beat to deliver the event into the
            -- inotify queue. 100ms is comfortable on any platform.
            babet.sleep(100, "ms")

            local evs, rerr = w:read(0)
            ok("read(0) returns the already-pending events",
                type(evs) == "table" and #evs > 0,
                "evs=" .. tostring(evs) .. " err=" .. tostring(rerr))
            ok("  events list contains a 'create' for the file",
                find_event(evs or {}, "audit_read0.txt", "create") ~= nil)
            ok("  the same read() returns both create and close_write",
                find_event(evs or {}, "audit_read0.txt", "create") ~= nil
                and find_event(evs or {}, "audit_read0.txt", "close_write") ~= nil)
        end

        -- (2) NaN and Inf must be rejected on timeout argument.
        do
            local v, e = w:read(0 / 0) -- NaN
            ok_fail("read(NaN) -> (nil, err)", v, e)
            ok("  message mentions 'finite'",
                type(e) == "string" and e:find("finite", 1, true) ~= nil)

            v, e = w:read(math.huge) -- +Inf
            ok_fail("read(+Inf) -> (nil, err)", v, e)

            v, e = w:read(-math.huge) -- -Inf (also covered by <0)
            ok_fail("read(-Inf) -> (nil, err)", v, e)
        end

        -- (3) The events table must be a strict 1..n list. Extra
        -- string keys, sparse numeric keys, and float keys are all
        -- rejected to avoid silently ignored entries.
        do
            local v, e = w:add(WDIR, { "create", x = "extra" })
            ok_fail("add(events with extra string key) -> (nil, err)", v, e)
            ok("  message mentions 'extra string key'",
                type(e) == "string"
                and e:find("extra string key", 1, true) ~= nil)

            v, e = w:add(WDIR, { "create", [10] = "modify" })
            ok_fail("add(events with sparse [10]) -> (nil, err)", v, e)
            ok("  message mentions 'extra integer key'",
                type(e) == "string"
                and e:find("extra integer key", 1, true) ~= nil)

            v, e = w:add(WDIR, { [1] = "create", [1.5] = "modify" })
            ok_fail("add(events with non-integer [1.5]) -> (nil, err)", v, e)
            ok("  message mentions 'non-integer'",
                type(e) == "string"
                and e:find("non-integer", 1, true) ~= nil)

            -- Non-string element at a valid 1..n index : was raising
            -- via luaL_error, now consistently returns (nil, err)
            -- like the other events-table errors.
            v, e = w:add(WDIR, { "create", 42 })
            ok_fail("add(events with non-string element) -> (nil, err)",
                v, e)
            ok("  message mentions 'must be a string'",
                type(e) == "string"
                and e:find("must be a string", 1, true) ~= nil)
        end

        -- Clean up: drain any events generated above, then remove wd2.
        drain(w, 0.1)
        w:remove(wd2)
        drain(w, 0.1) -- swallow the 'ignored' for wd2
    end

    -- ----- close() idempotent + post-close errors -------------------
    ok("tostring(active watcher) mentions inotify and fd",
        tostring(w):find("inotify", 1, true) ~= nil
        and tostring(w):find("fd=", 1, true) ~= nil)
    ok_act("close() -> (true, nil)", w:close())
    ok_act("close() again (idempotent)", w:close())
    ok("tostring(closed watcher) mentions closed",
        tostring(w):find("closed", 1, true) ~= nil)

    do
        local v, e = w:read(0)
        ok_fail("read() after close -> (nil, err)", v, e)
        ok("  message mentions 'closed'",
            type(e) == "string" and e:find("closed", 1, true) ~= nil)

        local v2, e2 = w:add(WDIR, { "create" })
        ok_fail("add() after close -> (nil, err)", v2, e2)

        local v3, e3 = w:remove(1)
        ok_fail("remove() after close -> (nil, err)", v3, e3)
    end

    babet.rmdirAll(WDIR)
end

end
