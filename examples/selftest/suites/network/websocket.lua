return function(test, context)
    local _ENV = test:environment(context)

print("")
print("=== websocket ===")

do
    local W = babet.websocket
    ok("websocket namespace exists", type(W) == "table")
    ok("websocket.connect is a function", type(W.connect) == "function")

    ok("websocket.connect requires a URL",
        pcall(function() return W.connect() end) == false)
    ok("websocket.connect URL is a strict string",
        pcall(function() return W.connect(42) end) == false)
    ok("websocket.connect rejects excess arguments",
        pcall(function() return W.connect("ws://127.0.0.1/", {}, true) end) == false)

    local value, err = W.connect("http://127.0.0.1/")
    ok_fail("websocket rejects non-WebSocket schemes", value, err)
    value, err = W.connect("ws://")
    ok_fail("websocket rejects an empty host", value, err)
    value, err = W.connect("ws://user@127.0.0.1/")
    ok_fail("websocket rejects URL userinfo", value, err)
    value, err = W.connect("ws://127.0.0.1/#fragment")
    ok_fail("websocket rejects URL fragments", value, err)
    value, err = W.connect("ws://127.0.0.1:abc/")
    ok_fail("websocket rejects a non-numeric port", value, err)
    value, err = W.connect("ws://127.0.0.1:65536/")
    ok_fail("websocket rejects an out-of-range port", value, err)
    value, err = W.connect("ws://127.0.0.1/a b")
    ok_fail("websocket rejects an unescaped space in target", value, err)
    value, err = W.connect("ws://bad host/")
    ok_fail("websocket rejects an unescaped space in authority", value, err)
    value, err = W.connect("ws://bad\r\nInjected: yes/")
    ok_fail("websocket rejects control bytes in authority", value, err)
    value, err = W.connect("ws://bad\0host/")
    ok_fail("websocket rejects NUL in URL", value, err)

    value, err = W.connect("ws://127.0.0.1:1/", "bad")
    ok_fail("websocket opts must be a table", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { unknown = true })
    ok_fail("websocket rejects unknown options", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { [1] = true })
    ok_fail("websocket rejects non-string option names", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { verify = 1 })
    ok_fail("websocket verify is a strict boolean", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { timeout = "1" })
    ok_fail("websocket timeout is a strict number", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { timeout = -1 })
    ok_fail("websocket rejects negative timeout", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { timeout = 0/0 })
    ok_fail("websocket rejects NaN timeout", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { timeout = math.huge })
    ok_fail("websocket rejects infinite timeout", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { min_version = "1.1" })
    ok_fail("websocket rejects TLS versions below 1.2", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", { max_message_bytes = 0 })
    ok_fail("websocket rejects zero max_message_bytes", value, err)
    value, err = W.connect("ws://127.0.0.1:1/", {
        max_message_bytes = 1024,
        max_frame_bytes = 2048,
    })
    ok_fail("websocket frame cap cannot exceed message cap", value, err)

    local index_calls = 0
    local raw_opts = setmetatable({ unknown = true }, {
        __index = function()
            index_calls = index_calls + 1
            error("websocket options must not invoke __index")
        end,
    })
    value, err = W.connect("ws://127.0.0.1:1/", raw_opts)
    ok_fail("websocket reads only raw option entries", value, err)
    ok("websocket did not invoke opts.__index", index_calls == 0,
        "calls=" .. tostring(index_calls))

    local worker = babet.workers.spawn([[
        return type(babet.websocket) == "table"
            and type(babet.websocket.connect) == "function"
    ]])
    ok("websocket module is registered in workers", worker ~= nil)
    local worker_ok, worker_value = false, nil
    if worker then
        worker_ok, worker_value = worker:join()
    end
    ok("worker sees the websocket client API",
        worker_ok == true and worker_value == true, tostring(worker_value))
end

end
