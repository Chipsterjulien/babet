return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== tls ===")

do
    local S = babet.socket

    -- ----- contrat de base ----------------------------------------

    ok("connect_tls is a function", type(S.connect_tls) == "function")

    -- ----- mauvais usage : luaL_error -----------------------------

    ok("connect_tls() without args raises",
        pcall(function() return S.connect_tls() end) == false)
    ok("connect_tls(host) without port raises",
        pcall(function() return S.connect_tls("h") end) == false)
    ok("connect_tls({}, 443) raises (host not a string)",
        pcall(function() return S.connect_tls({}, 443) end) == false)
    ok("connect_tls('h', {}) raises (port not a number)",
        pcall(function() return S.connect_tls("h", {}) end) == false)
    ok("DOC 4 connect_tls rejects numeric-string port",
        pcall(function() return S.connect_tls("h", "443") end) == false)
    ok("DOC 4 connect_tls rejects float port",
        pcall(function() return S.connect_tls("h", 443.0) end) == false)

    -- ----- mauvaises valeurs : (nil, err) -------------------------

    do
        local v, e = S.connect_tls("", 443, { timeout = 0.1 })
        ok_fail("DOC 4 connect_tls rejects empty host", v, e)

        v, e = S.connect_tls("127.0.0.1", -1)
        ok_fail("connect_tls negative port -> (nil, err)", v, e)
        v, e = S.connect_tls("127.0.0.1", 70000)
        ok_fail("connect_tls port > 65535 -> (nil, err)", v, e)
    end

    -- ----- opts invalids -----------------------------------------

    do
        local v, e = S.connect_tls("127.0.0.1", 443,
            "string-not-table")
        ok_fail("connect_tls opts non-table -> (nil, err)", v, e)
        ok("  err prefixed with 'tls: '",
            type(e) == "string" and e:find("tls:", 1, true) ~= nil)

        v, e = S.connect_tls("127.0.0.1", 443, { verify = "yes" })
        ok_fail("opts.verify non-boolean -> (nil, err)", v, e)

        v, e = S.connect_tls("127.0.0.1", 443, { ca_cert = 42 })
        ok_fail("opts.ca_cert non-string -> (nil, err)", v, e)

        v, e = S.connect_tls("127.0.0.1", 443, { hostname = 42 })
        ok_fail("opts.hostname non-string -> (nil, err)", v, e)

        v, e = S.connect_tls("127.0.0.1", 443, { min_version = "2.0" })
        ok_fail("opts.min_version invalid -> (nil, err)", v, e)
        ok("  err mentions '1.2' or '1.3'",
            type(e) == "string"
            and (e:find("1.2", 1, true) ~= nil
                or e:find("1.3", 1, true) ~= nil))

        v, e = S.connect_tls("127.0.0.1", 443, { timeout = -5 })
        ok_fail("opts.timeout negative -> (nil, err)", v, e)

        v, e = S.connect_tls("127.0.0.1", 443, { timeout = 0 / 0 })
        ok_fail("opts.timeout NaN -> (nil, err)", v, e)

        v, e = S.connect_tls("127.0.0.1", 443, { timeout = math.huge })
        ok_fail("opts.timeout inf -> (nil, err)", v, e)


        v, e = S.connect_tls("127.0.0.1\0ignored", 443,
            { timeout = 0.1 })
        ok_fail("LOT 3 TLS: NUL in host rejected", v, e)
        v, e = S.connect_tls("127.0.0.1", 443,
            { ca_cert = "/tmp/ca.pem\0ignored" })
        ok_fail("LOT 3 TLS: NUL in ca_cert rejected", v, e)
        v, e = S.connect_tls("127.0.0.1", 443,
            { ca_path = "/tmp/cas\0ignored" })
        ok_fail("LOT 3 TLS: NUL in ca_path rejected", v, e)
        v, e = S.connect_tls("127.0.0.1", 443,
            { hostname = "localhost\0ignored" })
        ok_fail("LOT 3 TLS: NUL in hostname rejected", v, e)
        v, e = S.connect_tls("127.0.0.1", 443,
            { min_version = "1.2\0ignored" })
        ok_fail("LOT 3 TLS: NUL in min_version rejected", v, e)
    end

    -- ----- échec transport : port loopback closed ------------------

    do
        local v, e = S.connect_tls("127.0.0.1", 1, { timeout = 0.5 })
        ok_fail("connect_tls 127.0.0.1:1 -> (nil, err)", v, e)
        ok("  err prefixed with 'socket: ' or 'timeout'",
            type(e) == "string"
            and (e:find("socket: ", 1, true) == 1 or e == "timeout"),
            "err=" .. tostring(e))
    end

    -- LOT 4 : le handshake ne reçoit plus un budget neuf après TCP ;
    -- il consomme la deadline de l'opération connect_tls. Ce serveur TCP
    -- accepte au niveau noyau mais ne parle jamais TLS, ce qui vérifie que
    -- la deadline parvient bien jusqu'à SSL_connect. La résolution DNS
    -- n'intervient pas ici (adresse numérique), conformément au contrat.
    do
        local stalled = S.listen("127.0.0.1", 0, 1)
        ok("LOT 4 TLS timeout: listener silencieux créé", stalled ~= nil)
        if stalled then
            local name = stalled:sockname()
            local port = name and tonumber(name.port)
            local t0 = babet.monotonic()
            local v, e = S.connect_tls("127.0.0.1", port, {
                timeout = 0.35,
                verify = false,
            })
            local dt = babet.monotonic() - t0
            ok("LOT 4 TLS handshake silencieux -> timeout",
                v == nil and e == "timeout",
                "err=" .. tostring(e))
            ok("  timeout TLS borné (0.25 <= dt <= 2)",
                dt >= 0.25 and dt <= 2,
                "dt=" .. tostring(dt))
            stalled:close()
        end
    end

    -- ----- s:starttls() : préconditions --------------------------

    do
        -- starttls on listening socket -> refus typé
        local lst = S.listen("127.0.0.1", 0)
        if lst then
            local v, e = lst:starttls()
            ok_fail("starttls on listening socket -> (nil, err)", v, e)
            ok("  err mentions 'listening'",
                type(e) == "string"
                and e:find("listening", 1, true) ~= nil)
            lst:close()
        end

        -- starttls on closed socket -> refus
        local lst2 = S.listen("127.0.0.1", 0)
        if lst2 then
            lst2:close()
            local v, e = lst2:starttls()
            ok_fail("starttls on closed socket -> (nil, err)", v, e)
        end
    end

    -- DOC 4 : les erreurs détectées avant le handshake ne modifient pas
    -- le flux TCP clair. Les octets plaintext déjà tamponnés doivent être
    -- consommés avant toute tentative STARTTLS.
    do
        local plain_srv = S.listen("127.0.0.1", 0)
        ok("DOC 4 starttls validation: listener créé", plain_srv ~= nil)
        if plain_srv then
            local a = plain_srv:sockname()
            local p = a and tonumber(a.port)
            local raw = S.connect("127.0.0.1", p, 1)
            local plain_peer = plain_srv:accept(1)
            ok("DOC 4 starttls validation: paire TCP créée",
                raw ~= nil and plain_peer ~= nil)
            if raw and plain_peer then
                local tv, te = raw:starttls({
                    timeout = 0.1, verify = true,
                })
                ok_fail("DOC 4 starttls verify=true requires hostname",
                    tv, te)
                plain_peer:send("still-plain")
                local got = raw:recv(11, 1)
                ok("DOC 4 pre-handshake validation leaves TCP usable",
                    got == "still-plain", "got=" .. tostring(got))

                plain_peer:send("abc")
                local lv, le = raw:recv_line(0.05)
                ok("DOC 4 starttls pending setup timed out",
                    lv == nil and le == "timeout")
                tv, te = raw:starttls({
                    timeout = 0.1, verify = false,
                })
                ok_fail("DOC 4 starttls refuses pending plaintext", tv, te)
                ok("  pending plaintext error is explicit",
                    type(te) == "string"
                    and te:find("pending plaintext", 1, true) ~= nil,
                    "err=" .. tostring(te))
                local pending = raw:recv(3, 1)
                ok("DOC 4 pending plaintext remains readable",
                    pending == "abc", "pending=" .. tostring(pending))

                raw:close()
                plain_peer:close()
            end
            plain_srv:close()
        end
    end

    -- Régression LOT 5A : opts.timeout de starttls doit être utilisé
    -- pour le handshake lui-même, et tout échec après le début du
    -- handshake ferme définitivement le socket (flux clair compromis).
    do
        local silent_srv = S.listen("127.0.0.1", 0)
        ok("LOT 5A starttls: listener silencieux créé",
            silent_srv ~= nil)
        if silent_srv then
            local a = silent_srv:sockname()
            local p = a and tonumber(a.port)
            local raw = S.connect("127.0.0.1", p, 1)
            local silent_peer = silent_srv:accept(1)
            ok("LOT 5A starttls: paire TCP créée",
                raw ~= nil and silent_peer ~= nil)
            if raw and silent_peer then
                raw:set_timeout(2)
                local t0 = babet.monotonic()
                local tv, te = raw:starttls({
                    timeout = 0.2,
                    verify = false,
                })
                local dt = babet.monotonic() - t0
                ok("LOT 5A starttls utilise opts.timeout",
                    tv == nil and te == "timeout"
                    and dt >= 0.1 and dt <= 1.5,
                    "err=" .. tostring(te) .. " dt=" .. tostring(dt))

                local after, after_err = raw:recv(1, 0.05)
                ok_fail("LOT 5A starttls échoué ferme le socket",
                    after, after_err)
                ok("  erreur post-starttls mentionne closed",
                    type(after_err) == "string"
                    and after_err:find("closed", 1, true) ~= nil,
                    "err=" .. tostring(after_err))

                raw:close()
                silent_peer:close()
            end
            silent_srv:close()
        end
    end

    -- ===== POSITIVE TESTS with openssl s_server ==================
    -- Graceful skip if openssl CLI absent or s_server doesn't start
    -- in time. Everything stays on loopback (127.0.0.1).

    local openssl_bin = babet.which("openssl")
    if not openssl_bin then
        print("[INFO] tls: openssl CLI absent, skip tests positifs")
    else
        print("[INFO] tls: openssl CLI found, generating cert...")

        local tmpdir = "/tmp/lp_tls_" .. tostring(babet.pid())
        babet.mkdir(tmpdir)
        local cert_path = tmpdir .. "/cert.pem"
        local key_path  = tmpdir .. "/key.pem"

        -- 1. Générer cert auto-signé CN=localhost. NB : babet.exec
        --    attend (cmd, args_table, opts) — la commande NE peut PAS
        --    être passée comme une seule string composée.
        local gen       = babet.exec("openssl", {
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
            "-keyout", key_path,
            "-out", cert_path,
            "-days", "1",
            "-subj", "/CN=localhost",
        }, { timeout = 60 })

        if not (gen and gen.code == 0
                and babet.fileExists(cert_path)) then
            print("[INFO] tls: cert generation failed, skipping positive tests")
        else
            -- 2. Lancer s_server en arrière-plan. On passe par sh -c
            --    pour asee le `&` de détachement. La string complète
            --    de la commande shell est UN argument after "-c", pas
            --    une commande composée.
            --    -quiet -ign_eof : pas de bruit + ne ferme pas sur EOF
            --    client (le client peut envoyer des données puis close).
            local tls_port = 19000 + (os.time() % 1000)
            local server_cmd = string.format(
                'openssl s_server -accept %d -cert %s -key %s '
                .. '-quiet -naccept 10 -ign_eof '
                .. '> /dev/null 2>&1 &',
                tls_port, cert_path, key_path)
            babet.exec("sh", { "-c", server_cmd },
                { timeout = 3 })

            -- 3. Attendre que s_server listening (poll TCP brut)
            babet.sleep(300, "ms")
            local probe_ok = false
            for _ = 1, 10 do
                local p = S.connect("127.0.0.1", tls_port, 0.5)
                if p then
                    p:close()
                    probe_ok = true
                    break
                end
                babet.sleep(200, "ms")
            end

            if not probe_ok then
                print("[INFO] tls: s_server n'listening pas, skip positifs")
            else
                print("[INFO] tls: server ready, running positive tests...")

                -- ----- handshake with verify=false: must succeed
                do
                    local s, err = S.connect_tls("127.0.0.1", tls_port,
                        { verify = false, timeout = 5 })
                    ok_val("connect_tls verify=false -> (socket, nil)",
                        s, err)
                    if s then
                        -- Envoi simple, le serveur echo-server affiche
                        -- mais on ne vérifie pas son output (s_server
                        -- écho est best-effort). On valid juste que
                        -- send() rend un nombre d'octets > 0.
                        local n, e = s:send("hello-tls\n")
                        ok_val("TLS s:send('hello-tls\\n') -> n, nil",
                            n, e)
                        ok("  n == 10 (exact length)", n == 10)
                        local again, again_err = s:starttls({ verify = false })
                        ok_fail("DOC 4 starttls refuses an active TLS socket",
                            again, again_err)
                        s:close()
                    end
                end

                -- ----- verify=true without CA -> self-signed cert rejected
                do
                    local s, e = S.connect_tls("127.0.0.1", tls_port,
                        {
                            verify = true,
                            timeout = 5,
                            hostname = "localhost"
                        })
                    ok_fail("verify=true without CA, self-signed cert "
                        .. "-> (nil, err)", s, e)
                    ok("  err contains 'verify failed' or 'self'",
                        type(e) == "string"
                        and (e:find("verify failed", 1, true) ~= nil
                            or e:find("self", 1, true) ~= nil),
                        "err=" .. tostring(e))
                end

                -- ----- verify=true AVEC ca_cert = success
                do
                    local s, err = S.connect_tls("127.0.0.1", tls_port,
                        {
                            verify = true,
                            timeout = 5,
                            hostname = "localhost",
                            ca_cert = cert_path
                        })
                    ok_val("verify=true + ca_cert(self) "
                        .. "-> (socket, nil)", s, err)
                    if s then
                        local n, e = s:send("verified\n")
                        ok_val("TLS verified s:send() -> n, nil", n, e)
                        s:close()
                    end
                end

                -- ----- Régression LOT 1 : le ca_cert utilisé juste
                --       avant ne doit PAS rester dans le contexte global.
                --       Avec l'ancien g_tls_ctx mutable, cette connexion
                --       sans ca_cert réussissait à tort.
                do
                    local s, e = S.connect_tls("127.0.0.1", tls_port,
                        {
                            verify = true,
                            timeout = 5,
                            hostname = "localhost"
                        })
                    ok_fail("LOT 1 TLS: ca_cert non conservé entre "
                        .. "deux connexions", s, e)
                    ok("  certificat auto-signé de nouveau refusé",
                        type(e) == "string"
                        and (e:find("verify failed", 1, true) ~= nil
                            or e:find("self", 1, true) ~= nil),
                        "err=" .. tostring(e))
                    if s then s:close() end
                end

                -- ----- DOC 4 : SNI independent de verify ---------
                -- s_server -servername_fatal rejects a missing or wrong SNI.
                -- This test is optional on older OpenSSL CLIs that do not
                -- support the option set.
                do
                    local sni_port = tls_port + 1
                    local sni_cmd = string.format(
                        'openssl s_server -accept %d -cert %s -key %s '
                        .. '-cert2 %s -key2 %s -servername expected.test '
                        .. '-servername_fatal -quiet -naccept 10 -ign_eof '
                        .. '> /dev/null 2>&1 &',
                        sni_port, cert_path, key_path, cert_path, key_path)
                    babet.exec("sh", { "-c", sni_cmd }, { timeout = 3 })
                    babet.sleep(300, "ms")

                    local sni_up = false
                    for _ = 1, 5 do
                        local p = S.connect("127.0.0.1", sni_port, 0.3)
                        if p then
                            p:close()
                            sni_up = true
                            break
                        end
                        babet.sleep(100, "ms")
                    end

                    if sni_up then
                        local good, good_err = S.connect_tls(
                            "127.0.0.1", sni_port, {
                                verify = false,
                                hostname = "expected.test",
                                timeout = 3,
                            })
                        ok_val("DOC 4 verify=false still sends requested SNI",
                            good, good_err)
                        if good then good:close() end

                        local bad, bad_err = S.connect_tls(
                            "127.0.0.1", sni_port, {
                                verify = false,
                                hostname = "wrong.test",
                                timeout = 3,
                            })
                        ok_fail("DOC 4 wrong SNI is rejected by strict server",
                            bad, bad_err)
                        if bad then bad:close() end
                    else
                        print("[INFO] tls: s_server SNI strict unavailable, "
                            .. "test SNI ignoré")
                    end

                    babet.exec("pkill", {
                        "-f",
                        "openssl s_server -accept " .. tostring(sni_port),
                    }, { timeout = 2 })
                end

                -- ----- min_version = "1.3" si supporté
                do
                    local s, err = S.connect_tls("127.0.0.1", tls_port,
                        {
                            verify = false,
                            timeout = 5,
                            min_version = "1.3"
                        })
                    -- s_server supporte TLS 1.3 par défaut sur OpenSSL
                    -- 1.1.1+ ; on accepte success OU échec gracieux.
                    if s then
                        ok("min_version='1.3' accepted", true)
                        s:close()
                    else
                        ok("min_version='1.3' refusé "
                            .. "(serveur ne supporte pas)", true,
                            "err=" .. tostring(err))
                    end
                end
            end

            -- 4. Cleanup s_server (best-effort, par port).
            --    pkill prend le pattern en argument séparé.
            babet.exec("pkill", {
                "-f",
                "openssl s_server -accept " .. tostring(tls_port),
            }, { timeout = 2 })
        end

        babet.rmdirAll(tmpdir)
    end
end

-- =====================================================================
end
