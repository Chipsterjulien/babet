return function(test, context)
    local _ENV = test:environment(context)

print("=== sys ===")

do
    -- ----- constantes de version -----------------------------------

    do
        ok("VERSION is a non-empty string",
            type(babet.VERSION) == "string" and #babet.VERSION > 0)
        ok("VERSION components are integers",
            math.type(babet.VERSION_MAJOR) == "integer"
            and math.type(babet.VERSION_MINOR) == "integer"
            and math.type(babet.VERSION_PATCH) == "integer")
        local rebuilt = string.format("%d.%d.%d",
            babet.VERSION_MAJOR, babet.VERSION_MINOR, babet.VERSION_PATCH)
        ok("VERSION matches MAJOR.MINOR.PATCH", babet.VERSION == rebuilt,
            "VERSION=" .. tostring(babet.VERSION)
            .. " rebuilt=" .. rebuilt)
    end

    -- ----- pid : entier > 0, jamais d'erreur (POSIX) ----------------

    do
        local p = babet.pid()
        ok("pid() -> integer > 0",
            type(p) == "number" and p > 0 and p == math.floor(p),
            "pid=" .. tostring(p))
    end

    -- Workers are OS threads in the same process: same PID.
    do
        local main_pid = babet.pid()
        local w, err = babet.workers.spawn("return babet.pid()")
        ok_val("worker spawned for PID check", w, err)
        if w then
            local joined, worker_pid = w:join()
            ok("worker pid() equals main pid()",
                joined == true and worker_pid == main_pid,
                "main=" .. tostring(main_pid)
                .. " worker=" .. tostring(worker_pid))
        end
    end

    -- ----- hostname : string non empty ------------------------------

    do
        local h, err = babet.hostname()
        ok("hostname() -> non-empty string",
            type(h) == "string" and #h > 0 and err == nil,
            "h=" .. tostring(h) .. " err=" .. tostring(err))
    end

    -- ----- uname: table with 5 non-empty string fields --------------

    do
        local u, err = babet.uname()
        ok_val("uname() -> table", u, err)
        if type(u) == "table" then
            for _, field in ipairs({ "sysname", "nodename",
                "release", "version", "machine" }) do
                ok("  uname." .. field .. " est a string non empty",
                    type(u[field]) == "string" and #u[field] > 0,
                    field .. "=" .. tostring(u[field]))
            end
        end
    end

    -- ----- env : variable absente = nil seul (décision UTIL-4) -----

    do
        local v = babet.env("BABET_VAR_QUI_NEXISTE_PAS_42")
        ok("env(absent) -> nil only (no error message)",
            v == nil,
            "v=" .. tostring(v))

        local p = babet.env("PATH")
        ok("env('PATH') -> non-empty string",
            type(p) == "string" and #p > 0)


        local env_nul_ok, env_nul_err = pcall(function()
            return babet.env("PATH\0ignored")
        end)
        ok("LOT 3 env: NUL in name raises cleanly",
            env_nul_ok == false and type(env_nul_err) == "string"
            and env_nul_err:find("NUL", 1, true) ~= nil,
            tostring(env_nul_err))

        local wp, we = babet.which("sh\0ignored")
        ok_fail("LOT 3 which: NUL in name rejected", wp, we)
    end

    -- ----- setenv : tests de MUTATION déplacés avant le premier ----
    -- worker (section « env / cwd », avant find) : option A validée,
    -- setenv/chdir sont verrouillés dès le premier workers.spawn, et
    -- le premier spawn de la suite (find concurrent) précède cette
    -- section. Les tests d'interdiction post-spawn vivent dans la
    -- section workers. Les tests d'arité ci-dessous restent valides
    -- ici : ils lèvent à la validation d'arguments, avant le verrou.

    -- ----- which : found / pas found / chemin direct --------------

    do
        local p, err = babet.which("sh")
        ok_val("which('sh') -> path", p, err)
        ok("  which('sh') returns an absolute path",
            type(p) == "string" and p:sub(1, 1) == "/",
            "p=" .. tostring(p))

        local v, e = babet.which("babet_binaire_qui_nexiste_pas_42")
        ok_fail("which(absent) -> (nil, err)", v, e)
        ok("  message mentions 'PATH' or 'not found'",
            type(e) == "string" and (e:find("PATH", 1, true) ~= nil
                or e:find("not found", 1, true) ~= nil),
            "err=" .. tostring(e))

        local p2, err2 = babet.which("/bin/sh")
        ok_val("which('/bin/sh') -> direct path accepted", p2, err2)
    end

    -- ----- mauvais usage : luaL_error ------------------------------

    do
        ok("which() with no arg raises",
            pcall(function() return babet.which() end) == false)
        -- env/which/setenv use luaL_checktype(LUA_TSTRING): numbers
        -- are rejected rather than coerced to strings.
        ok("env({}) raises",
            pcall(function() return babet.env({}) end) == false)
        ok("env(42) raises (strict string, no coercion)",
            pcall(function() return babet.env(42) end) == false)
        ok("which(42) raises (strict string, no coercion)",
            pcall(function() return babet.which(42) end) == false)
        ok("setenv() without args raises",
            pcall(function() return babet.setenv() end) == false)
        ok("setenv('X') without value raises",
            pcall(function() return babet.setenv("X") end) == false)
        ok("setenv(42, 'x') raises (strict name string)",
            pcall(function() return babet.setenv(42, "x") end) == false)
        ok("setenv('X', 42) raises (strict value string)",
            pcall(function() return babet.setenv("X", 42) end) == false)
    end
end

-- =====================================================================
print("")
print("=== signal ===")

do
    local S = babet.signal

    -- ----- contract de base -----------------------------------------
    ok("babet.signal is a table", type(S) == "table")
    ok("handle is a function", type(S.handle) == "function")
    ok("ignore is a function", type(S.ignore) == "function")
    ok("default is a function", type(S.default) == "function")

    -- Documentation lot 3 : les succès renvoient exactement une
    -- valeur (`true`), pas un couple `(true, nil)`.
    local handle_n = select("#", S.handle("USR1", function() end))
    ok("DOC 3 signal.handle success returns one value", handle_n == 1)
    S.handle("USR1", nil)

    local ignore_n = select("#", S.ignore("USR1"))
    ok("DOC 3 signal.ignore success returns one value", ignore_n == 1)
    local default_n = select("#", S.default("USR1"))
    ok("DOC 3 signal.default success returns one value", default_n == 1)

    ok("DOC 3 signal name is a strict string",
        pcall(S.ignore, 15) == false)

    ok("LOT 11 signal.handle rejects excess arguments",
        pcall(S.handle, "USR1", nil, "extra") == false)
    ok("LOT 11 signal.ignore rejects excess arguments",
        pcall(S.ignore, "USR1", "extra") == false)
    ok("LOT 11 signal.default rejects excess arguments",
        pcall(S.default, "USR1", "extra") == false)

    -- ----- validation des arguments ---------------------------------
    -- Signal inconnu : luaL_error -> pcall.ok == false
    do
        local pok, perr = pcall(S.handle, "BOGUS", function() end)
        ok("handle('BOGUS', fn) raises", not pok)
        ok("  message mentions 'unsupported' or 'supported'",
            type(perr) == "string"
            and (perr:find("unsupported") or perr:find("supported")))
    end

    do
        local pok = pcall(S.ignore, "BOGUS")
        ok("ignore('BOGUS') raises", not pok)
    end

    do
        local pok = pcall(S.default, "BOGUS")
        ok("default('BOGUS') raises", not pok)
    end

    ok_raises("LOT 3 signal: NUL in name rejected",
        function() return S.ignore("USR1\0ignored") end, "NUL")

    -- Handler de type incorrect : luaL_error
    do
        local pok, perr = pcall(S.handle, "USR1", 42)
        ok("handle('USR1', 42) raises (handler not function/nil)", not pok)
        ok("  message mentions 'function or nil'",
            type(perr) == "string" and perr:find("function or nil"))
    end

    do
        local pok = pcall(S.handle, "USR1", "string")
        ok("handle('USR1', 'string') raises", not pok)
    end

    -- ----- enregistrement effectif ----------------------------------
    -- On utilise USR1 et USR2 pour les tests : ces signaux n'ont
    -- pas de comportement par défaut "tuer le process" sur la plupart
    -- des systèmes Linux modernes (USR1 par défaut = term, mais on
    -- installe nos handlers donc ça n'a pas d'incidence ici).
    ok("handle('USR1', fn) -> true",
        S.handle("USR1", function() end) == true)
    ok("handle('USR1', nil) -> true (uninstall)",
        S.handle("USR1", nil) == true)

    ok("handle('USR2', fn) -> true",
        S.handle("USR2", function() end) == true)
    -- Re-install : doit marcher (remplace le précédent handler)
    ok("handle('USR2', fn) again -> true (replace)",
        S.handle("USR2", function() end) == true)
    ok("handle('USR2', nil) -> true",
        S.handle("USR2", nil) == true)

    -- ignore / default
    ok("ignore('USR1') -> true", S.ignore("USR1") == true)
    ok("default('USR1') -> true", S.default("USR1") == true)

    -- PIPE : cas d'usage typique (on l'ignore pour éviter que SIGPIPE
    -- tue le process sur un write vers une socket fermée). Notre
    -- code socket gère déjà EPIPE proprement donc c'est juste un
    -- exemple — la fonction doit accepter.
    ok("ignore('PIPE') -> true (cas d'usage typique)",
        S.ignore("PIPE") == true)
    ok("default('PIPE') -> true (restauration)",
        S.default("PIPE") == true)

    -- Tous les signaux supportés sont acceptés
    for _, name in ipairs({ "TERM", "INT", "HUP", "USR1", "USR2", "PIPE" }) do
        ok("handle('" .. name .. "', fn) accepted",
            S.handle(name, function() end) == true)
        -- Nettoyage : on désinstalle pour ne pas perturber les tests
        -- suivants si une partie du harnais déclenche un de ces
        -- signaux (genre Ctrl-C de l'utilisateur).
        S.handle(name, nil)
    end

    -- Les signaux dangereux ou non interceptables sont refusés
    for _, name in ipairs({ "KILL", "STOP", "SEGV", "CHLD", "ALRM" }) do
        local pok = pcall(S.handle, name, function() end)
        ok("handle('" .. name .. "', fn) refused", not pok)
    end

    -- ----- hardening: handle(name) without 2nd arg refused ----------
    -- (audit point 5) handle("TERM") with no 2nd arg used to be
    -- equivalent to handle("TERM", nil), which silently uninstalls
    -- the handler. Now requires explicit arg.
    do
        local pok, perr = pcall(S.handle, "USR1")
        ok("handle('USR1') without 2nd arg -> raises", not pok)
        ok("  message mentions 'missing handler'",
            type(perr) == "string" and perr:find("missing handler"))
    end

    -- ----- dispatch différé : ordre fixe et zéro argument -----------
    do
        local events = {}
        local argc = nil
        S.handle("TERM", function(...)
            events[#events + 1] = "TERM"
            argc = select("#", ...)
        end)
        S.handle("USR1", function(...)
            events[#events + 1] = "USR1"
            argc = math.max(argc or 0, select("#", ...))
        end)

        -- Les deux signaux arrivent pendant os.execute(), donc avant que
        -- le hook Lua ne puisse dispatcher. USR1 est envoyé en premier,
        -- mais la table interne fixe TERM avant USR1.
        os.execute("kill -USR1 " .. tostring(babet.pid())
            .. "; kill -TERM " .. tostring(babet.pid()))

        local deadline = babet.monotonic() + 1
        while #events < 2 and babet.monotonic() < deadline do
            local accumulator = 0
            for i = 1, 20000 do accumulator = accumulator + i end
        end

        ok("DOC 3 signal callbacks receive no arguments", argc == 0,
            "argc=" .. tostring(argc))
        ok("DOC 3 signal dispatch uses fixed supported-signal order",
            events[1] == "TERM" and events[2] == "USR1",
            "events=" .. table.concat(events, ","))

        S.handle("TERM", nil)
        S.handle("USR1", nil)
    end

    -- ----- hardening: signal.* refused from workers -----------------
    -- (audit point 4) POSIX signal handlers are process-wide; calling
    -- handle/ignore/default from a worker installs a system handler
    -- but stores the Lua callback in the worker's registry — and
    -- since workers block signals via pthread_sigmask, the callback
    -- never fires. Refuse this with a clear error.
    do
        local W = babet.workers
        local w = W.spawn([[
            local ok, err = pcall(babet.signal.handle, "USR1", function() end)
            return { ok = ok, err = err }
        ]])
        local ok_, res = w:join()
        ok("worker spawn + join OK", ok_ == true and type(res) == "table")
        ok("  worker's signal.handle pcall returned false", res.ok == false)
        ok("  err mentions 'main thread'",
            type(res.err) == "string" and res.err:find("main thread"))

        -- ignore and default same check
        local w2 = W.spawn([[
            local ok, err = pcall(babet.signal.ignore, "USR1")
            return { ok = ok, err = err }
        ]])
        local _, res2 = w2:join()
        ok("worker's signal.ignore -> raises 'main thread'",
            res2.ok == false and res2.err:find("main thread"))

        local w3 = W.spawn([[
            local ok, err = pcall(babet.signal.default, "USR1")
            return { ok = ok, err = err }
        ]])
        local _, res3 = w3:join()
        ok("worker's signal.default -> raises 'main thread'",
            res3.ok == false and res3.err:find("main thread"))
    end
end

-- =====================================================================
end
