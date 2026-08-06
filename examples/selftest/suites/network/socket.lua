return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== socket ===")

do
    local S = babet.socket

    -- ----- contrat de base ------------------------------------------

    ok("babet.socket is a table", type(S) == "table")
    ok("connect is a function", type(S.connect) == "function")
    ok("listen is a function", type(S.listen) == "function")

    -- ----- mauvais usage : luaL_error ------------------------------

    do
        ok("connect() without args raises",
            pcall(function() return S.connect() end) == false)
        ok("connect(host) without port raises",
            pcall(function() return S.connect("127.0.0.1") end) == false)
        ok("connect({}, 80) raises (host not a string)",
            pcall(function() return S.connect({}, 80) end) == false)
        ok("DOC 4 connect rejects numeric-string port",
            pcall(function()
                return S.connect("127.0.0.1", "80")
            end) == false)
        ok("DOC 4 connect rejects float port",
            pcall(function()
                return S.connect("127.0.0.1", 80.0)
            end) == false)

        ok("listen() without args raises",
            pcall(function() return S.listen() end) == false)
        ok("listen(host) without port raises",
            pcall(function() return S.listen("127.0.0.1") end) == false)
        ok("DOC 4 listen rejects numeric-string port",
            pcall(function()
                return S.listen("127.0.0.1", "0")
            end) == false)
        ok("DOC 4 listen rejects numeric-string backlog",
            pcall(function()
                return S.listen("127.0.0.1", 0, "16")
            end) == false)
    end

    -- ----- mauvaises valeurs : (nil, err) --------------------------

    do
        local v, e = S.connect("", 1, 0.1)
        ok_fail("DOC 4 connect rejects empty host", v, e)

        v, e = S.connect("127.0.0.1", -1)
        ok_fail("connect negative port -> (nil, err)", v, e)
        ok("  message mentions 'port'",
            type(e) == "string" and e:find("port", 1, true) ~= nil)

        v, e = S.connect("127.0.0.1", 70000)
        ok_fail("connect port > 65535 -> (nil, err)", v, e)

        v, e = S.listen("127.0.0.1", -1)
        ok_fail("listen negative port -> (nil, err)", v, e)

        v, e = S.listen("127.0.0.1", 8080, -5)
        ok_fail("listen backlog <= 0 -> (nil, err)", v, e)

        v, e = S.listen("127.0.0.1", 0, 2147483648)
        ok_fail("LOT 5B listen backlog overflow rejected", v, e)
        ok("  backlog error mentions range",
            type(e) == "string" and e:find("range", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = S.connect("127.0.0.1\0ignored", 1, 0.1)
        ok_fail("LOT 3 socket.connect: NUL in host rejected", v, e)
        v, e = S.listen("127.0.0.1\0ignored", 0)
        ok_fail("LOT 3 socket.listen: NUL in host rejected", v, e)
    end

    -- ----- échec transport : connect sur port loopback closed -------

    do
        -- Port 1 sur loopback : très improbable qu'il listening. timeout
        -- court pour rester rapide. Reste sur 127.0.0.1 : hermétique.
        local v, e = S.connect("127.0.0.1", 1, 0.5)
        ok_fail("connect 127.0.0.1:1 -> (nil, err) (refused or timeout)",
            v, e)
        ok("  err prefixed with 'socket: ' or 'timeout'",
            type(e) == "string"
            and (e:find("socket: ", 1, true) == 1 or e == "timeout"),
            "err=" .. tostring(e))
    end

    -- ----- pattern (b): listen -> connect -> accept in the same
    --       processus, synchrone en loopback. Le noyau accepte la
    --       connection in its queue as soon as `listen()`, so `connect`
    --       returns as soon as it's in the queue and `accept` dequeues.
    --       Pas de threads, pas de subprocess.

    do
        -- CORRECTIF (post-revue ChatGPT) : on demande au noyau un
        -- port libre via listen("127.0.0.1", 0), puis on récupère
        -- le port effectif via sockname(). Évite TOUTE collision
        -- even if previous runs overlap or if another
        -- processus listening sur un port haut.

        -- 1) Démarrer le serveur sur port 0 = "noyau choisit".
        --    SO_REUSEADDR enabled internally.
        local srv, err = S.listen("127.0.0.1", 0)
        ok_val("listen('127.0.0.1', 0) -> (socket, nil)", srv, err)

        if srv then
            -- Récupérer le port effectif attribué par le noyau.
            local a = srv:sockname()
            local port = a and tonumber(a.port)
            ok("  sockname() returns host + actual port > 0",
                type(a) == "table"
                and a.host ~= nil
                and type(port) == "number" and port > 0,
                "port=" .. tostring(port))

            -- 2) Le client se connecte. Comme listen() est already en
            --    place, le noyau accepte instantanément en loopback.
            local cli, cerr = S.connect("127.0.0.1", port, 2)
            ok_val("connect('127.0.0.1', port) -> (socket, nil)", cli, cerr)

            -- 3) Le serveur dépile la connexion. accept() rend tout
            --    immediately because the client is already in the queue.
            srv:set_timeout(2)
            local peer, perr = srv:accept()
            ok_val("srv:accept() -> (socket, nil)", peer, perr)

            if cli and peer then
                -- ----- types stricts des méthodes ------------------

                ok("DOC 4 send requires a string",
                    pcall(function() return cli:send(42) end) == false)
                ok("DOC 4 recv count requires a Lua integer",
                    pcall(function() return peer:recv("8") end) == false
                    and pcall(function() return peer:recv(8.0) end) == false)
                ok("DOC 4 set_timeout requires a number",
                    pcall(function() return peer:set_timeout("1") end) == false)

                local timeout_returns = table.pack(peer:set_timeout(2))
                ok("DOC 4 set_timeout success returns exactly true, nil",
                    timeout_returns.n == 2
                    and timeout_returns[1] == true
                    and timeout_returns[2] == nil)

                local bad_count, bad_count_err = peer:recv(0)
                ok_fail("DOC 4 recv rejects count <= 0",
                    bad_count, bad_count_err)
                bad_count, bad_count_err = peer:recv(16 * 1024 * 1024 + 1)
                ok_fail("DOC 4 recv enforces 16 MiB cap",
                    bad_count, bad_count_err)

                -- ----- échange de données : send / recv -----------

                local n, serr = cli:send("hello")
                ok_val("cli:send('hello') -> (5, nil)", n, serr)
                ok("  5 bytes sent", n == 5)

                peer:set_timeout(2)
                local data, rerr = peer:recv(1024)
                ok_val("peer:recv(1024) -> ('hello', nil)", data, rerr)
                ok("  data == 'hello'", data == "hello")

                -- ----- recv_line with transparent CRLF ------------

                cli:send("line1\r\nline2\n")
                local l1 = peer:recv_line()
                ok("recv_line() #1 : 'line1' (\\r stripped)",
                    l1 == "line1",
                    "l1=" .. tostring(l1))
                local l2 = peer:recv_line()
                ok("recv_line() #2: 'line2' (LF only)",
                    l2 == "line2",
                    "l2=" .. tostring(l2))

                -- ----- peer() / sockname() client side ------------

                local p = cli:peer()
                ok("cli:peer() -> { host, port }",
                    type(p) == "table"
                    and tonumber(p.port) == port)

                -- ----- binaire-safe : data contenant un NUL -------

                cli:send("AB\0CD")
                local bin = peer:recv(1024)
                ok("recv binary-safe: 5 bytes, NUL preserved",
                    type(bin) == "string"
                    and #bin == 5
                    and bin:byte(3) == 0,
                    "len=" .. tostring(bin and #bin))

                -- ----- timeout sur recv quand rien n'est sent ---

                peer:set_timeout(0.1) -- 100 ms
                local v, e = peer:recv(1024)
                ok_fail("recv with short timeout and nothing to read"
                    .. " -> (nil, 'timeout')", v, e)
                ok("  err == 'timeout'", e == "timeout")

                -- ----- EOF : cli close, peer recv -> closed -------

                cli:close()
                peer:set_timeout(2)
                local v2, e2 = peer:recv(1024)
                ok_fail("recv after client close -> (nil, 'closed')",
                    v2, e2)
                ok("  err == 'closed' (typed string)", e2 == "closed")

                -- ----- send on locally-closed socket -----------

                local v3, e3 = cli:send("x")
                ok_fail("send on locally-closed socket"
                    .. " -> (nil, err)", v3, e3)

                peer:close()
            end

            -- ----- recv_line with EOF mid-stream -------------

            -- Nouvel échange dédié : on envoie une demi-line (sans
            -- '\n') puis on ferme client side. recv_line server side
            -- doit rendre (nil, "closed", partial).
            do
                local c2, ce = S.connect("127.0.0.1", port, 2)
                ok_val("2nd connect (for EOF mid-line test)", c2, ce)
                local p2, pe = srv:accept()
                ok_val("2nd accept", p2, pe)
                if c2 and p2 then
                    c2:send("partial-no-newline")
                    c2:close()
                    p2:set_timeout(2)
                    local line, eerr, partial = p2:recv_line()
                    ok("recv_line EOF mid-line: 3 values",
                        line == nil and eerr == "closed"
                        and type(partial) == "string",
                        "line=" .. tostring(line)
                        .. " err=" .. tostring(eerr)
                        .. " partial=" .. tostring(partial))
                    ok("  partial contains bytes already read",
                        partial == "partial-no-newline",
                        "partial=" .. tostring(partial))
                    p2:close()
                end
            end

            -- ----- recv_line : DoS guard (8 MiB max line length) ----
            -- Audit security: a malicious peer that sends a flood
            -- without '\n' must not grow acc to OOM. The C++ code
            -- refuses with "line too long" past 8 MiB. We don't test
            -- 8 MiB literally (slow + memory-intensive), we just
            -- verify the normal path on a moderately sized buffer.
            --
            -- Payload size: 8 KiB. Reason: client and server are in
            -- the SAME process. If we send too much, the local TCP
            -- kernel buffer fills up before the server reads, and
            -- send() blocks → deadlock until the read-side
            -- timeout fires. On x86_64 the kernel TCP buffer is
            -- ~256 KB and 100 KiB worked; on Raspberry Pi 0 the
            -- buffer is smaller (~64 KB) and 100 KiB deadlocks.
            -- 8 KiB is well under any plausible kernel buffer
            -- ceiling. It still exercises the accumulator (many
            -- recv() iterations).
            do
                local c4, ce = S.connect("127.0.0.1", port, 2)
                ok_val("4th connect (for big-line test)", c4, ce)
                local p4, pe = srv:accept()
                ok_val("4th accept", p4, pe)
                if c4 and p4 then
                    local payload = string.rep("A", 8 * 1024)
                    c4:send(payload)
                    c4:close()
                    p4:set_timeout(2)
                    local line, eerr, partial = p4:recv_line()
                    ok("recv_line 8 KiB no-newline: closed with partial",
                        line == nil and eerr == "closed"
                        and type(partial) == "string"
                        and #partial == 8 * 1024)
                    p4:close()
                end
            end

            -- ----- recv_all : reads jusqu'à EOF du peer -------------

            do
                local c3, ce = S.connect("127.0.0.1", port, 2)
                ok_val("3rd connect (for recv_all test)", c3, ce)
                local p3, pe = srv:accept()
                ok_val("3rd accept", p3, pe)
                if c3 and p3 then
                    c3:send("alpha-beta-gamma")
                    c3:close() -- EOF déclenche fin de recv_all
                    p3:set_timeout(2)
                    local body, berr = p3:recv_all()
                    ok_val("recv_all -> (body, nil)", body, berr)
                    ok("  complete body retrieved",
                        body == "alpha-beta-gamma",
                        "body=" .. tostring(body))
                    p3:close()
                end
            end

            -- ----- LOT 5B recv_all : garde mémoire --------------------

            do
                local c5, ce = S.connect("127.0.0.1", port, 2)
                local p5, pe = srv:accept(2)
                ok("LOT 5B recv_all limit: paire connectée",
                    c5 ~= nil and p5 ~= nil,
                    "connect_err=" .. tostring(ce)
                    .. " accept_err=" .. tostring(pe))
                if c5 and p5 then
                    c5:send(string.rep("R", 8 * 1024))
                    c5:close()
                    local limited, limited_err = p5:recv_all(2, 4096)
                    ok_fail("LOT 5B recv_all stops at max_bytes",
                        limited, limited_err)
                    ok("  no partial data and explicit max_bytes error",
                        limited == nil and type(limited_err) == "string"
                        and limited_err:find("max_bytes", 1, true) ~= nil,
                        "err=" .. tostring(limited_err))
                    p5:close()
                end
            end

            do
                local c6, ce = S.connect("127.0.0.1", port, 2)
                local p6, pe = srv:accept(2)
                ok("LOT 5B recv_all custom limit: paire connectée",
                    c6 ~= nil and p6 ~= nil,
                    "connect_err=" .. tostring(ce)
                    .. " accept_err=" .. tostring(pe))
                if c6 and p6 then
                    local payload = string.rep("S", 8 * 1024)
                    c6:send(payload)
                    c6:close()
                    local full, full_err = p6:recv_all(2, 16 * 1024)
                    ok_val("LOT 5B recv_all custom max_bytes permits body",
                        full, full_err)
                    ok("  complete custom-limited body returned",
                        full == payload,
                        "len=" .. tostring(full and #full))
                    p6:close()
                end
            end

            do
                local c7 = S.connect("127.0.0.1", port, 2)
                local p7 = srv:accept(2)
                if c7 and p7 then
                    local iv, ie = p7:recv_all(0.1, 0)
                    ok_fail("LOT 5B recv_all rejects max_bytes <= 0",
                        iv, ie)
                    iv, ie = p7:recv_all(0.1, 1.5)
                    ok_fail("LOT 5B recv_all rejects non-integer max_bytes",
                        iv, ie)
                    iv, ie = p7:recv_all(0.1, 2^31 + 1)
                    ok_fail("LOT 5B recv_all rejects max_bytes > 2 GiB",
                        iv, ie)
                    c7:close()
                    p7:close()
                else
                    ok("LOT 5B recv_all invalid max_bytes setup", false)
                end
            end

            -- ----- DOC 4 : préservation et ordre du flux --------

            -- recv_line() peut avoir retiré des octets du noyau avant un
            -- timeout. Ils doivent rester visibles par recv(), pas seulement
            -- par un prochain recv_line().
            do
                local c8 = S.connect("127.0.0.1", port, 2)
                local p8 = srv:accept(2)
                ok("DOC 4 recv_line pending: paire connectée",
                    c8 ~= nil and p8 ~= nil)
                if c8 and p8 then
                    c8:send("abc")
                    local lv, le = p8:recv_line(0.05)
                    ok("DOC 4 recv_line timeout preserves partial bytes",
                        lv == nil and le == "timeout")
                    c8:send("def")
                    local first = p8:recv(3, 1)
                    local second = p8:recv(3, 1)
                    ok("DOC 4 recv after recv_line keeps stream order",
                        first == "abc" and second == "def",
                        "first=" .. tostring(first)
                        .. " second=" .. tostring(second))
                    c8:close()
                    p8:close()
                end
            end

            -- recv_all() conserve aussi les octets accumulés lors d'un
            -- timeout ; un nouvel appel peut reprendre sans perte.
            do
                local c9 = S.connect("127.0.0.1", port, 2)
                local p9 = srv:accept(2)
                ok("DOC 4 recv_all timeout: paire connectée",
                    c9 ~= nil and p9 ~= nil)
                if c9 and p9 then
                    c9:send("hello")
                    local av, ae = p9:recv_all(0.05, 100)
                    ok("DOC 4 recv_all timeout returns no partial body",
                        av == nil and ae == "timeout")
                    c9:send(" world")
                    c9:close()
                    local recovered, recovered_err = p9:recv_all(1, 100)
                    ok("DOC 4 recv_all retry recovers all buffered bytes",
                        recovered == "hello world" and recovered_err == nil,
                        "data=" .. tostring(recovered)
                        .. " err=" .. tostring(recovered_err))
                    p9:close()
                end
            end

            -- Le dépassement de max_bytes ne rend pas de résultat partiel,
            -- mais les octets déjà lus restent récupérables avec une limite
            -- plus grande.
            do
                local c10 = S.connect("127.0.0.1", port, 2)
                local p10 = srv:accept(2)
                ok("DOC 4 recv_all limit recovery: paire connectée",
                    c10 ~= nil and p10 ~= nil)
                if c10 and p10 then
                    c10:send("abcdef")
                    c10:close()
                    local av, ae = p10:recv_all(1, 3)
                    ok("DOC 4 recv_all max_bytes returns no partial body",
                        av == nil and type(ae) == "string"
                        and ae:find("max_bytes", 1, true) ~= nil)
                    local recovered = p10:recv_all(1, 10)
                    ok("DOC 4 recv_all larger retry recovers data",
                        recovered == "abcdef",
                        "data=" .. tostring(recovered))
                    p10:close()
                end
            end

            -- ----- accept with timeout: no client -> timeout --

            do
                srv:set_timeout(0.1)
                local v, e = srv:accept()
                ok_fail("accept with no client -> (nil, 'timeout')", v, e)
                ok("  err == 'timeout'", e == "timeout")
            end

            -- ----- set_timeout : valeur negative -> (nil, err) ----

            do
                local v, e = srv:set_timeout(-1)
                ok_fail("set_timeout(-1) -> (nil, err)", v, e)
            end

            srv:close()
        end
    end

    -- Régression LOT 5A : les timeouts positionnels des méthodes
    -- socket doivent réellement primer sur le timeout par défaut posé
    -- par set_timeout(). Avant le correctif, ces arguments étaient
    -- acceptés puis ignorés silencieusement.
    do
        local timeout_srv = S.listen("127.0.0.1", 0)
        ok("LOT 5A socket timeouts: listener créé", timeout_srv ~= nil)
        if timeout_srv then
            local addr = timeout_srv:sockname()
            local timeout_port = addr and tonumber(addr.port)

            timeout_srv:set_timeout(2)
            local t0 = babet.monotonic()
            local av, ae = timeout_srv:accept(0.1)
            local adt = babet.monotonic() - t0
            ok("LOT 5A accept(timeout) prime sur set_timeout",
                av == nil and ae == "timeout"
                and adt >= 0.05 and adt <= 1.5,
                "err=" .. tostring(ae) .. " dt=" .. tostring(adt))

            local timeout_cli = S.connect("127.0.0.1", timeout_port, 1)
            local timeout_peer = timeout_srv:accept(1)
            ok("LOT 5A socket timeouts: paire connectée",
                timeout_cli ~= nil and timeout_peer ~= nil)
            if timeout_cli and timeout_peer then
                timeout_peer:set_timeout(2)

                t0 = babet.monotonic()
                local rv, re = timeout_peer:recv(8, 0.1)
                local rdt = babet.monotonic() - t0
                ok("LOT 5A recv(n, timeout) effectif",
                    rv == nil and re == "timeout"
                    and rdt >= 0.05 and rdt <= 1.5,
                    "err=" .. tostring(re) .. " dt=" .. tostring(rdt))

                t0 = babet.monotonic()
                local lv, le = timeout_peer:recv_line(0.1)
                local ldt = babet.monotonic() - t0
                ok("LOT 5A recv_line(timeout) effectif",
                    lv == nil and le == "timeout"
                    and ldt >= 0.05 and ldt <= 1.5,
                    "err=" .. tostring(le) .. " dt=" .. tostring(ldt))

                t0 = babet.monotonic()
                local bv, be = timeout_peer:recv_all(0.1)
                local bdt = babet.monotonic() - t0
                ok("LOT 5A recv_all(timeout) effectif",
                    bv == nil and be == "timeout"
                    and bdt >= 0.05 and bdt <= 1.5,
                    "err=" .. tostring(be) .. " dt=" .. tostring(bdt))

                local badv, bade = timeout_peer:recv(8, "bad")
                ok_fail("LOT 5A timeout par appel invalide -> erreur",
                    badv, bade)

                timeout_cli:close()
                timeout_peer:close()
            end
            timeout_srv:close()
        end
    end

    -- ----- méthodes sur closed socket : refus propre ----------------

    do
        local s = S.listen("127.0.0.1", 0)
        if s then
            s:close()
            -- Re-close : doit être idempotent et rendre (true, nil).
            local close_returns = table.pack(s:close())
            ok("close() idempotent and returns exactly true, nil",
                close_returns.n == 2
                and close_returns[1] == true
                and close_returns[2] == nil)

            local v, e = s:accept()
            ok_fail("accept on closed socket -> (nil, err)", v, e)

            local v2, e2 = s:peer()
            ok_fail("peer on closed socket -> (nil, err)", v2, e2)
        end
    end

    -- ----- listen rejette send/recv (mauvaise direction) -----------

    do
        local lst = S.listen("127.0.0.1", 0)
        if lst then
            local v, e = lst:send("x")
            ok_fail("send on listening socket -> (nil, err)", v, e)
            local v2, e2 = lst:recv(10)
            ok_fail("recv on listening socket -> (nil, err)", v2, e2)
            lst:close()
        end
    end

    -- =================================================================
    -- Régression (audit v21, option A) : connect unifié.
    --   1. Deadline GLOBALE : timeout = T borne l'appel COMPLET,
    --      toutes adresses confondues (avant : deadline recréée par
    --      addrinfo, N × T possible).
    --   2. Connect bloquant interruptible : un signal géré pendant
    --      connect() sans timeout rend (nil, "interrupted") + dispatch
    --      (avant : "Interrupted system call" générique, callback
    --      perdu jusqu'au retour).
    -- Technique hermétique : listener backlog=1 jamais accepté ; une
    -- fois la file pleine, le kernel ignore les SYN entrants et le
    -- connect suivant reste en attente (comportement Linux standard,
    -- tcp_abort_on_overflow=0).
    -- =================================================================
    do
        local sat = S.listen("127.0.0.1", 0, 1)
        ok("connect-audit: listener backlog=1", sat ~= nil)
        if sat then
            local name = sat:sockname()
            local port = name and tonumber(name.port)
            ok("connect-audit: sockname -> port", port ~= nil)

            -- Saturer la file : quelques connects gardés ouverts.
            -- Les premiers réussissent vite ; timeout court sur les
            -- suivants (résultat ignoré, on veut juste remplir).
            local keep = {}
            for _ = 1, 4 do
                local c = S.connect("127.0.0.1", port, 0.3)
                if c then keep[#keep + 1] = c end
            end

            -- 1. Borne globale : timeout 0.6 s -> (nil, "timeout")
            --    en temps borné, mesuré en horloge monotone.
            local t0 = babet.monotonic()
            local c1, e1 = S.connect("127.0.0.1", port, 0.6)
            local dt = babet.monotonic() - t0
            ok("connect(saturé, 0.6) -> (nil, 'timeout')",
                c1 == nil and e1 == "timeout",
                "e=" .. tostring(e1))
            ok("  temps borné (0.5 <= dt <= 3)", dt >= 0.5 and dt <= 3,
                "dt=" .. tostring(dt))

            -- 2. Connect bloquant (SANS timeout) interrompu par un
            --    signal géré : USR1 tiré par un sous-shell détaché
            --    (fds redirigés -> exec rend la main tout de suite).
            local fired = false
            babet.signal.handle("USR1", function() fired = true end)
            -- Garde de sûreté : le connect ci-dessous est SANS
            -- timeout ; si le kill différé ne partait pas, la suite
            -- pendrait. On vérifie donc que le lanceur a démarré
            -- AVANT de bloquer, et on échoue explicitement sinon
            -- (pas de skip silencieux : sh manquant = environnement
            -- cassé, on veut le voir).
            local launcher = babet.exec("sh", { "-c",
                "( sleep 0.4; kill -USR1 " .. babet.pid()
                .. " ) >/dev/null 2>&1 &" })
            ok("connect-audit: lancement du kill différé",
                type(launcher) == "table")
            if type(launcher) == "table" then
                t0 = babet.monotonic()
                local c2, e2 = S.connect("127.0.0.1", port)
                dt = babet.monotonic() - t0
                ok("connect bloquant + USR1 -> (nil, 'interrupted')",
                    c2 == nil and e2 == "interrupted",
                    "e=" .. tostring(e2))
                ok("  callback USR1 dispatché", fired)
                ok("  réactivité (dt <= 3)", dt <= 3,
                    "dt=" .. tostring(dt))
            end
            babet.signal.handle("USR1", nil)

            for _, c in ipairs(keep) do c:close() end
            sat:close()
        end
    end
end

-- =====================================================================
end
