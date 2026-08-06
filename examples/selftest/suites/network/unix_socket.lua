return function(test, context)
    local _ENV = test:environment(context)

print("")
print("=== unix sockets ===")

do
    local S = babet.socket
    local W = babet.workers
    local root = sb("unix_socket")
    ok_act("unix socket fixture directory", babet.mkdir(root))

    -- fileExists() répond uniquement à la question « fichier régulier ? ».
    -- Un pathname de socket Unix existant renvoie donc false. Utiliser
    -- getMode() pour distinguer une entrée existante de son absence.
    local function path_exists(path)
        local mode, err = babet.getMode(path)
        return mode ~= nil and err == nil
    end

    local function absent(path)
        return not path_exists(path)
    end

    local function cleanup(path)
        pcall(os.remove, path)
    end

    ok("connect_unix is a function", type(S.connect_unix) == "function")
    ok("listen_unix is a function", type(S.listen_unix) == "function")

    -- Strict call shapes and value validation.
    ok("connect_unix requires a path",
        pcall(function() return S.connect_unix() end) == false)
    ok("connect_unix path is a strict string",
        pcall(function() return S.connect_unix(42) end) == false)
    ok("connect_unix rejects excess arguments",
        pcall(function() return S.connect_unix("x", 1, true) end) == false)
    ok("listen_unix requires a path",
        pcall(function() return S.listen_unix() end) == false)
    ok("listen_unix path is a strict string",
        pcall(function() return S.listen_unix({}) end) == false)
    ok("listen_unix rejects excess arguments",
        pcall(function() return S.listen_unix("x", {}, true) end) == false)

    local value, err = S.connect_unix("")
    ok_fail("connect_unix rejects an empty path", value, err)
    value, err = S.listen_unix("")
    ok_fail("listen_unix rejects an empty path", value, err)
    value, err = S.connect_unix("bad\0path")
    ok_fail("connect_unix rejects NUL in path", value, err)
    value, err = S.listen_unix("bad\0path")
    ok_fail("listen_unix rejects NUL in path", value, err)

    value, err = S.connect_unix(root .. "/missing.sock", -1)
    ok_fail("connect_unix rejects a negative timeout", value, err)
    value, err = S.connect_unix(root .. "/missing.sock", 0/0)
    ok_fail("connect_unix rejects NaN timeout", value, err)
    value, err = S.connect_unix(root .. "/missing.sock", math.huge)
    ok_fail("connect_unix rejects infinite timeout", value, err)
    value, err = S.connect_unix(root .. "/missing.sock", 3000000)
    ok_fail("connect_unix rejects an oversized timeout", value, err)

    value, err = S.listen_unix(root .. "/opts.sock", "bad")
    ok_fail("listen_unix opts must be a table", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", { unknown = true })
    ok_fail("listen_unix rejects unknown options", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", { [1] = true })
    ok_fail("listen_unix rejects non-string option names", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", { backlog = "16" })
    ok_fail("listen_unix backlog is a strict integer", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", { backlog = 0 })
    ok_fail("listen_unix rejects backlog zero", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", { backlog = 2147483648 })
    ok_fail("listen_unix rejects backlog overflow", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", { permissions = "600" })
    ok_fail("listen_unix permissions are a strict integer", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", {
        permissions = tonumber("1000", 8),
    })
    ok_fail("listen_unix rejects permissions above 0777", value, err)
    value, err = S.listen_unix(root .. "/opts.sock", {
        unlink_on_close = 1,
    })
    ok_fail("listen_unix unlink_on_close is a strict boolean", value, err)

    local index_calls = 0
    local raw_opts = setmetatable({}, {
        __index = function()
            index_calls = index_calls + 1
            error("listen_unix must not invoke __index")
        end,
    })
    local raw_path = root .. "/raw.sock"
    local raw_server, raw_err = S.listen_unix(raw_path, raw_opts)
    ok_val("listen_unix reads only raw option entries", raw_server, raw_err)
    ok("listen_unix did not invoke opts.__index", index_calls == 0,
        "calls=" .. tostring(index_calls))
    if raw_server then raw_server:close() end
    ok("raw-options listener path cleaned", absent(raw_path))

    -- Kernel pathname boundary: 107 bytes on Linux (sun_path includes NUL).
    local exact_path = string.rep("u", 107)
    cleanup(exact_path)
    local exact_server, exact_err = S.listen_unix(exact_path)
    ok_val("listen_unix accepts the exact sockaddr_un path boundary",
        exact_server, exact_err)
    if exact_server then exact_server:close() end
    ok("exact-boundary socket path cleaned", absent(exact_path))
    value, err = S.listen_unix(string.rep("v", 108))
    ok_fail("listen_unix rejects a path beyond sockaddr_un", value, err)

    value, err = S.connect_unix(root .. "/missing.sock", 0.1)
    ok_fail("connect_unix reports a missing listener", value, err)

    -- Basic local stream exchange and address introspection.
    local path = root .. "/basic.sock"
    local server, server_err = S.listen_unix(path, {
        backlog = 8,
        permissions = tonumber("600", 8),
    })
    ok_val("listen_unix creates a local stream listener", server, server_err)

    if server then
        local mode, mode_err = babet.getMode(path)
        ok("Unix listener default/private permissions are exact",
            mode == tonumber("600", 8) and mode_err == nil,
            "mode=" .. tostring(mode) .. " err=" .. tostring(mode_err))

        local local_addr = server:sockname()
        ok("Unix listener sockname returns its path",
            type(local_addr) == "table" and local_addr.path == path,
            "path=" .. tostring(local_addr and local_addr.path))
        ok("Unix listener tostring identifies its domain",
            tostring(server):find("unix%-listening") ~= nil,
            tostring(server))

        local duplicate, duplicate_err = S.listen_unix(path)
        ok_fail("listen_unix refuses every pre-existing pathname",
            duplicate, duplicate_err)
        ok("duplicate refusal preserves the active listener",
            path_exists(path))

        local client, client_err = S.connect_unix(path, 2)
        ok_val("connect_unix reaches the local listener", client, client_err)
        server:set_timeout(2)
        local accepted, accept_err = server:accept()
        ok_val("Unix listener accepts a stream", accepted, accept_err)

        if client and accepted then
            ok("Unix stream tostring identifies its domain",
                tostring(client):find("unix%-stream") ~= nil,
                tostring(client))

            local peer_addr = client:peer()
            ok("Unix client peer returns the server path",
                type(peer_addr) == "table" and peer_addr.path == path,
                "path=" .. tostring(peer_addr and peer_addr.path))
            local client_addr = client:sockname()
            ok("unbound Unix client sockname returns an empty path",
                type(client_addr) == "table" and client_addr.path == "",
                "path=" .. tostring(client_addr and client_addr.path))
            local accepted_name = accepted:sockname()
            ok("accepted Unix stream keeps the listener pathname",
                type(accepted_name) == "table" and accepted_name.path == path)
            local accepted_peer = accepted:peer()
            ok("accepted Unix stream reports an unnamed client",
                type(accepted_peer) == "table" and accepted_peer.path == "")

            local n, send_err = client:send("A\0B")
            ok("Unix send remains binary-safe",
                n == 3 and send_err == nil)
            accepted:set_timeout(2)
            local payload, recv_err = accepted:recv(3)
            ok("Unix recv preserves embedded NUL bytes",
                payload == "A\0B" and recv_err == nil)

            local tls_ok, tls_err = client:starttls({
                verify = false,
                timeout = 0.1,
            })
            ok_fail("STARTTLS is refused on Unix sockets", tls_ok, tls_err)
            ok("STARTTLS refusal is explicit",
                type(tls_err) == "string"
                and tls_err:find("only on TCP", 1, true) ~= nil,
                tostring(tls_err))
            local reply_n = accepted:send("still-open")
            local reply = client:recv(32, 2)
            ok("STARTTLS refusal leaves the Unix stream usable",
                reply_n == 10 and reply == "still-open")

            accepted:close()
            client:close()
        end

        ok("closing an accepted stream does not unlink the listener",
            path_exists(path))
        server:close()
        ok("closing the Unix listener unlinks its owned pathname",
            absent(path))
        server:close()
        ok("Unix listener close remains idempotent", absent(path))
    end

    -- Custom permissions and explicit stale-path retention.
    local retained_path = root .. "/retained.sock"
    local retained, retained_err = S.listen_unix(retained_path, {
        permissions = tonumber("660", 8),
        unlink_on_close = false,
    })
    ok_val("listen_unix accepts custom permissions and retention",
        retained, retained_err)
    if retained then
        local retained_mode = babet.getMode(retained_path)
        ok("listen_unix applies custom permissions exactly",
            retained_mode == tonumber("660", 8), tostring(retained_mode))
        retained:close()
        ok("unlink_on_close=false retains the socket pathname",
            path_exists(retained_path))
        local stale, stale_err = S.listen_unix(retained_path)
        ok_fail("retained stale pathname must be removed explicitly",
            stale, stale_err)
        cleanup(retained_path)
        ok("explicit stale-path cleanup succeeds", absent(retained_path))
    end

    -- A replacement at the original name must never be removed by close().
    local protected_path = root .. "/owned.sock"
    local moved_path = root .. "/moved.sock"
    cleanup(protected_path)
    cleanup(moved_path)
    local protected, protected_err = S.listen_unix(protected_path)
    ok_val("replacement-safety listener created", protected, protected_err)
    if protected then
        local renamed, rename_err = os.rename(protected_path, moved_path)
        ok("owned Unix socket pathname can be moved for replacement test",
            renamed == true, tostring(rename_err))
        local wrote, write_err = write_test_file(protected_path, "replacement")
        ok("replacement regular file created", wrote == true,
            tostring(write_err))
        protected:close()
        local replacement = io.open(protected_path, "rb")
        local replacement_data = replacement and replacement:read("a")
        if replacement then replacement:close() end
        ok("listener close never deletes a replacement entry",
            replacement_data == "replacement")
        cleanup(protected_path)
        cleanup(moved_path)
    end

    -- Pre-existing special entries and missing parents are rejected without
    -- changing the filesystem.
    local regular_path = root .. "/regular.sock"
    assert(write_test_file(regular_path, "keep"))
    value, err = S.listen_unix(regular_path)
    ok_fail("listen_unix refuses a pre-existing regular file", value, err)
    local regular = io.open(regular_path, "rb")
    local regular_data = regular and regular:read("a")
    if regular then regular:close() end
    ok("regular file survives listener refusal", regular_data == "keep")
    cleanup(regular_path)

    local missing_parent_path = root .. "/missing/child.sock"
    value, err = S.listen_unix(missing_parent_path)
    ok_fail("listen_unix does not create missing parents", value, err)
    ok("missing-parent failure leaves no socket", absent(missing_parent_path))

    -- GC owns the same inode-sensitive cleanup contract as close().
    local gc_path = root .. "/gc.sock"
    do
        local gc_listener = S.listen_unix(gc_path)
        ok("Unix listener created for GC cleanup", gc_listener ~= nil)
        gc_listener = nil
    end
    collectgarbage("collect")
    collectgarbage("collect")
    ok("Unix listener GC removes its owned pathname", absent(gc_path))

    -- Real worker interoperability proves registration in worker Lua states.
    local worker_path = root .. "/worker.sock"
    local worker_server, worker_server_err = S.listen_unix(worker_path)
    ok_val("Unix worker fixture listener created",
        worker_server, worker_server_err)
    if worker_server then
        local job, job_err = W.spawn([[
            local S = babet.socket
            local sock, err = S.connect_unix(worker.args.path, 2)
            if not sock then return { ok = false, err = err } end
            local n, send_err = sock:send("from-worker")
            if not n then
                sock:close()
                return { ok = false, err = send_err }
            end
            local reply, recv_err = sock:recv(64, 2)
            sock:close()
            return {
                ok = reply == "from-parent",
                reply = reply,
                err = recv_err,
            }
        ]], { path = worker_path })
        ok_val("worker starts a Unix-domain client", job, job_err)
        worker_server:set_timeout(2)
        local peer, peer_err = worker_server:accept()
        ok_val("parent accepts the worker Unix client", peer, peer_err)
        if peer then
            peer:set_timeout(2)
            local message = peer:recv(64)
            ok("worker sends data through Unix socket",
                message == "from-worker", tostring(message))
            peer:send("from-parent")
            peer:close()
        end
        if job then
            local joined, result = job:join(3)
            ok("worker completes the Unix socket round-trip",
                joined == true and type(result) == "table"
                and result.ok == true,
                "joined=" .. tostring(joined)
                .. " result=" .. tostring(result)
                .. " err=" .. tostring(type(result) == "table" and result.err))
        end
        worker_server:close()
        ok("worker fixture listener path cleaned", absent(worker_path))
    end

    babet.rmdirAll(root)
end

end
