return function(test, context)
    local _ENV = test:environment(context)
    local W = babet.workers
    -- ============================================================
    -- send / recv / close côté parent
    -- ============================================================
    -- On valide ici la mécanique des queues : capacités, timeouts,
    -- fermeture, drainage et conventions de retour.

    -- ----- send : succès tant qu'il reste de la place -----------
    do
        local w = W.spawn("babet.sleep(100, 'ms'); return 42",
            nil, { inbox_capacity = 4 })
        local sok, serr = w:send("hello")
        ok("send(value) sur worker vivant -> (true, nil)",
            sok == true and serr == nil,
            "sok=" .. tostring(sok) .. " serr=" .. tostring(serr))

        -- send d'une valeur plus complexe
        sok = w:send({ type = "ping", n = 42 })
        ok("send(table) -> (true, nil)", sok == true)

        -- send avec timeout > 0 (queue pas pleine, devrait passer immédiat)
        sok = w:send("with-timeout", 0.5)
        ok("send avec timeout > 0 sur queue non pleine -> (true, nil)",
            sok == true)

        w:join()
    end

    -- ----- send : queue pleine, timeout=0 -> "full" -------------
    do
        local w = W.spawn("babet.sleep(200, 'ms'); return 1",
            nil, { inbox_capacity = 2 })
        ok("send #1 sur cap=2 -> ok",
            w:send("m1") == true)
        ok("send #2 sur cap=2 -> ok",
            w:send("m2") == true)
        local sok, serr = w:send("m3", 0)
        ok("send #3 (cap dépassée) timeout=0 -> (false, 'full')",
            sok == false and serr == "full",
            "got=(" .. tostring(sok) .. ", " .. tostring(serr) .. ")")
        w:join()
    end

    -- ----- send : queue pleine, timeout>0 -> "timeout" ----------
    do
        local w = W.spawn("babet.sleep(500, 'ms'); return 1",
            nil, { inbox_capacity = 1 })
        w:send("only-slot")
        local t0 = os.time()
        local sok, serr = w:send("second", 0.2)
        local elapsed = os.time() - t0
        ok("send sur queue pleine, timeout>0 -> (false, 'timeout')",
            sok == false and serr == "timeout",
            "got=(" .. tostring(sok) .. ", " .. tostring(serr) .. ")")
        ok("send timeout : attente effective (elapsed >= 0s, < 2s)",
            elapsed >= 0 and elapsed < 2)
        w:join()
    end

    -- ----- recv : outbox vide -----------------------------------
    -- CORRECTIF (post-test Pi0) : le worker doit rester vivant
    -- significativement plus longtemps que le timeout du recv(),
    -- sinon il finit pile pendant l'attente et la outbox passe en
    -- "closed" au lieu de "timeout". Sur Pi0 (1 cœur ARMv6 lent),
    -- un sleep de 100ms côté worker + recv(0.1) côté parent
    -- produisait une race intermittente. 2s côté worker garantit
    -- qu'on observe bien le timeout.
    do
        local w = W.spawn("babet.sleep(2, 's'); return 1")
        local rok, rmsg = w:recv(0)
        ok("recv(0) sur outbox vide -> (false, 'empty')",
            rok == false and rmsg == "empty",
            "got=(" .. tostring(rok) .. ", " .. tostring(rmsg) .. ")")

        local t0 = os.time()
        rok, rmsg = w:recv(0.1)
        local elapsed = os.time() - t0
        ok("recv(0.1) sur outbox vide -> (false, 'timeout')",
            rok == false and rmsg == "timeout",
            "got=(" .. tostring(rok) .. ", " .. tostring(rmsg) .. ")")
        ok("recv timeout : attente effective (elapsed < 2s)",
            elapsed < 2)
        w:join()
    end

    -- ----- close() : idempotent, retourne (true, nil) -----------
    do
        local w = W.spawn("return 1")
        local cok, cerr = w:close()
        ok("close() -> (true, nil)",
            cok == true and cerr == nil)
        local cok2 = w:close()
        ok("close() idempotent (2e appel OK)", cok2 == true)
        w:join()
    end

    -- ----- le worker ferme automatiquement ses queues ------------
    do
        local w = W.spawn("return 1")
        w:join()
        local sok, serr = w:send("nope", 0)
        ok("DOC 3 send after worker completion -> (false, 'closed')",
            sok == false and serr == "closed",
            "got=(" .. tostring(sok) .. ", " .. tostring(serr) .. ")")
    end

    -- ----- send : refus de types non sérialisables --------------
    do
        local w = W.spawn("babet.sleep(100, 'ms'); return 1")
        local sok, serr = w:send(function() end)
        ok("send(function) -> (nil, err)",
            sok == nil and type(serr) == "string"
            and serr:find("function", 1, true) ~= nil,
            "got=(" .. tostring(sok) .. ", " .. tostring(serr) .. ")")
        w:join()
    end

    -- ----- mauvais usage : timeout non-numérique ----------------
    do
        local w = W.spawn("return 1")
        ok("send(value, 'abc') -> luaL_error",
            pcall(function() w:send("x", "abc") end) == false)
        ok("recv('abc') -> luaL_error",
            pcall(function() w:recv("abc") end) == false)
        ok("send(value, -1) -> luaL_error",
            pcall(function() w:send("x", -1) end) == false)
        ok("DOC 3 worker timeout numeric string rejected",
            pcall(function() w:recv("0.1") end) == false)
        ok("DOC 3 worker timeout > 24h rejected",
            pcall(function() w:recv(86400.001) end) == false)
        w:join()
    end

    -- Toute durée strictement positive reste une attente bornée, même
    -- sous la milliseconde. L'ancien floor la transformait en timeout=0.
    do
        local w = W.spawn("babet.sleep(200, 'ms'); return true",
            nil, { inbox_capacity = 1 })
        local first_ok = w:send("first", 0)
        local second_ok, second_err = w:send("second", 0.0001)
        ok("DOC 3 tiny positive worker timeout is not non-blocking",
            first_ok == true and second_ok == false
            and second_err == "timeout",
            "got=(" .. tostring(second_ok) .. ","
                .. tostring(second_err) .. ")")
        w:join()
    end

    -- ----- opts.inbox_capacity invalide -------------------------
    do
        ok("spawn(_, _, {inbox_capacity=0}) -> luaL_error",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = 0 })
            end) == false)
        ok("spawn(_, _, {inbox_capacity=-1}) -> luaL_error",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = -1 })
            end) == false)
        ok("spawn(_, _, {inbox_capacity='x'}) -> luaL_error",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = "x" })
            end) == false)
        ok("spawn(_, _, {inbox_capacity=1.5}) -> luaL_error",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = 1.5 })
            end) == false)
        ok("DOC 3 inbox_capacity numeric string rejected",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = "2" })
            end) == false)

        ok("LOT 11 inbox_capacity floating integer rejected",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = 2.0 })
            end) == false)
        ok("LOT 11 outbox_capacity floating integer rejected",
            pcall(function()
                W.spawn("return 1", nil, { outbox_capacity = 2.0 })
            end) == false)
        ok("DOC 3 inbox_capacity > 1000000 rejected",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = 1000001 })
            end) == false)
        ok("DOC 3 outbox_capacity > 1000000 rejected",
            pcall(function()
                W.spawn("return 1", nil, { outbox_capacity = 1000001 })
            end) == false)
    end

    -- ============================================================
    -- Chantier 9-3 : worker.send / worker.recv côté worker
    -- ============================================================

    -- ----- nil est une vraie valeur de message -------------------
    do
        local w = W.spawn([[
            local got, value = worker.recv()
            return { got = got, value_is_nil = value == nil }
        ]])
        local sent, send_err = w:send(nil)
        local joined, result = w:join()
        ok("DOC 3 workers can transfer a nil message",
            sent == true and send_err == nil and joined == true
            and type(result) == "table" and result.got == true
            and result.value_is_nil == true)
    end

    -- ----- close ferme l'inbox, pas l'outbox ----------------------
    do
        local w = W.spawn([[
            worker.send("ready")
            local got, reason = worker.recv()
            worker.send({ got = got, reason = reason })
            return "done"
        ]])
        local ready_ok, ready = w:recv(2)
        local close_result = table.pack(w:close())
        local report_ok, report = w:recv(2)
        local joined, result = w:join()
        ok("DOC 3 job:close returns (true, nil)",
            close_result.n == 2 and close_result[1] == true
            and close_result[2] == nil)
        ok("DOC 3 close keeps outbox drainable",
            ready_ok == true and ready == "ready"
            and report_ok == true and type(report) == "table"
            and report.got == false and report.reason == "closed"
            and joined == true and result == "done")
    end

    -- ----- Echo persistant (le pattern canonique) ---------------
    do
        local w = W.spawn([[
            while true do
                local ok, msg = worker.recv()
                if not ok then break end
                worker.send({ echo = msg })
            end
            return "exited cleanly"
        ]])

        -- Envoie 3 messages, lit 3 réponses dans l'ordre.
        w:send("hello")
        w:send("world")
        w:send(42)

        local rok1, r1 = w:recv(2)
        local rok2, r2 = w:recv(2)
        local rok3, r3 = w:recv(2)

        ok("echo worker: 3 messages reçus",
            rok1 == true and rok2 == true and rok3 == true)
        ok("echo worker: r1.echo == 'hello'",
            type(r1) == "table" and r1.echo == "hello",
            "r1=" .. tostring(r1 and r1.echo))
        ok("echo worker: r2.echo == 'world'",
            type(r2) == "table" and r2.echo == "world")
        ok("echo worker: r3.echo == 42",
            type(r3) == "table" and r3.echo == 42)

        -- close() -> worker.recv() retourne "closed" -> worker sort
        w:close()
        local jok, jval = w:join()
        ok("echo worker: join après close -> (true, 'exited cleanly')",
            jok == true and jval == "exited cleanly",
            "jok=" .. tostring(jok) .. " jval=" .. tostring(jval))
    end

    -- ----- Handler par type de message --------------------------
    do
        local w = W.spawn([[
            while true do
                local ok, msg = worker.recv()
                if not ok then break end
                if msg.type == "ping" then
                    worker.send({ type = "pong" })
                elseif msg.type == "add" then
                    worker.send({ type = "sum", result = msg.a + msg.b })
                end
            end
            return nil
        ]])

        w:send({ type = "ping" })
        local _, r1 = w:recv(2)
        ok("handler: ping -> pong",
            type(r1) == "table" and r1.type == "pong")

        w:send({ type = "add", a = 3, b = 4 })
        local _, r2 = w:recv(2)
        ok("handler: add(3,4) -> sum=7",
            type(r2) == "table" and r2.type == "sum"
            and r2.result == 7)

        w:close()
        w:join()
    end

    -- ----- worker.recv(0.1) timeout dans une boucle -------------
    do
        local w = W.spawn([[
            local n_timeouts = 0
            local n_msgs = 0
            while true do
                local ok, msg = worker.recv(0.1)
                if not ok then
                    if msg == "timeout" then
                        n_timeouts = n_timeouts + 1
                        if n_timeouts >= 3 then
                            -- Après 3 timeouts, on signale et sort.
                            worker.send({
                                timeouts = n_timeouts,
                                msgs = n_msgs,
                            })
                            return nil
                        end
                    else  -- "closed"
                        break
                    end
                else
                    n_msgs = n_msgs + 1
                end
            end
            return nil
        ]])

        local rok, summary = w:recv(2)
        ok("worker.recv(0.1) timeout boucle: récupéré n_timeouts",
            rok == true and type(summary) == "table"
            and summary.timeouts >= 3,
            "summary=" .. tostring(summary and summary.timeouts))
        w:join()
    end

    -- ----- annulation réveille une outbox pleine ----------------
    -- Régression Gemini 2.15.0 : worker.send() bloqué ne doit pas
    -- empêcher cancel() puis join(timeout) de terminer.
    do
        local ready = assert(W.channel({ capacity = 1 }))
        local w = W.spawn([[
            local first_ok, first_err = worker.send("first")
            assert(worker.channels.ready:send(true, 2))
            local second_ok, second_err = worker.send("second")
            return {
                first_ok = first_ok,
                first_err = first_err,
                second_ok = second_ok,
                second_err = second_err,
            }
        ]], nil, {
            outbox_capacity = 1,
            channels = { ready = ready },
        })

        local ready_ok, ready_value = ready:recv(2)
        ok("worker atteint l'envoi bloquant sur outbox pleine",
            ready_ok == true and ready_value == true)
        local cancelled, cancel_err = w:cancel()
        ok("cancel réveille worker.send sur outbox pleine",
            cancelled == true and cancel_err == nil,
            tostring(cancel_err))

        local joined, result = w:join(2)
        ok("cancel + join(timeout) ne deadlock plus",
            joined == true and type(result) == "table",
            tostring(result))
        ok("envoi déjà placé conservé, envoi bloqué annulé",
            result and result.first_ok == true
            and result.second_ok == false
            and result.second_err == "cancelled",
            tostring(result and result.second_err))

        local recv_ok, recv_value = w:recv(0)
        ok("diagnostic déjà présent dans l'outbox reste drainable",
            recv_ok == true and recv_value == "first",
            tostring(recv_value))
    end

    -- ----- worker meurt -> parent draine puis voit 'closed' -----
    -- (décision W2-I : drainage avant fermeture)
    do
        local w = W.spawn([[
            worker.send("a")
            worker.send("b")
            worker.send("c")
            return "done"
        ]])

        -- On laisse au worker le temps de finir et de close ses queues.
        local ok_join, val_join = w:join()
        ok("worker termine -> join (true, 'done')",
            ok_join == true and val_join == "done")

        -- Maintenant le worker est mort, mais l'outbox doit encore
        -- contenir les 3 messages. On les draine.
        local r1ok, r1 = w:recv(0)
        local r2ok, r2 = w:recv(0)
        local r3ok, r3 = w:recv(0)
        ok("drainage post-mort: 3 messages récupérés",
            r1ok and r2ok and r3ok,
            "got=(" .. tostring(r1ok) .. "," .. tostring(r2ok)
            .. "," .. tostring(r3ok) .. ")")
        ok("drainage post-mort: contenus 'a', 'b', 'c'",
            r1 == "a" and r2 == "b" and r3 == "c")

        -- Une fois drainé, recv() doit rendre 'closed'.
        local r4ok, r4err = w:recv(0)
        ok("après drainage: recv(0) -> (false, 'closed')",
            r4ok == false and r4err == "closed",
            "got=(" .. tostring(r4ok) .. "," .. tostring(r4err) .. ")")
    end

    -- ----- worker.recv() bloquant + w:close() -> 'closed' -------
    do
        local w = W.spawn([[
            local ok, msg = worker.recv()  -- bloque
            return { recv_ok = ok, recv_msg = msg }
        ]])

        -- Attendre un peu pour s'assurer que le worker est dans recv()
        babet.sleep(100, "ms")
        w:close() -- doit débloquer worker.recv()

        local jok, jval = w:join()
        ok("worker.recv() bloquant + w:close(): worker termine",
            jok == true and type(jval) == "table"
            and jval.recv_ok == false and jval.recv_msg == "closed",
            "jval=" .. tostring(jval))
    end

    -- ----- worker.send(function) -> (false, err) ----------------
    -- (Convention pcall-style côté worker, décision W3-A)
    do
        local w = W.spawn([[
            local ok, err = worker.send(function() end)
            return { ok = ok, err = err }
        ]])

        local jok, jval = w:join()
        ok("worker.send(function) -> (false, err)",
            jok == true and type(jval) == "table"
            and jval.ok == false and type(jval.err) == "string"
            and jval.err:find("function", 1, true) ~= nil,
            "jval.ok=" .. tostring(jval and jval.ok)
            .. " err=" .. tostring(jval and jval.err))
    end

    -- ----- Mauvais usage côté worker ----------------------------
    do
        local w = W.spawn([[
            local pcall_ok = pcall(function()
                worker.recv("abc")  -- bad timeout
            end)
            return { pcall_ok = pcall_ok }
        ]])

        local jok, jval = w:join()
        ok("worker.recv('abc') -> luaL_error (pcall.ok == false)",
            jok == true and type(jval) == "table"
            and jval.pcall_ok == false)
    end

    -- ----- 2 workers indépendants -------------------------------
    do
        local w1 = W.spawn([[
            local ok, msg = worker.recv()
            if ok then worker.send("w1-got:" .. msg) end
            return nil
        ]])
        local w2 = W.spawn([[
            local ok, msg = worker.recv()
            if ok then worker.send("w2-got:" .. msg) end
            return nil
        ]])

        w1:send("hello1")
        w2:send("hello2")

        local _, r1 = w1:recv(2)
        local _, r2 = w2:recv(2)
        ok("2 workers indépendants: w1 reçoit 'hello1'",
            r1 == "w1-got:hello1",
            "r1=" .. tostring(r1))
        ok("2 workers indépendants: w2 reçoit 'hello2'",
            r2 == "w2-got:hello2",
            "r2=" .. tostring(r2))

        w1:join()
        w2:join()
    end

end
