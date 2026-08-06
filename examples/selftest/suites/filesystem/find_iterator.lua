return function(test, context)
    local _ENV = test:environment(context)
-- =====================================================================
print("")
print("=== find ===")

do
    local results, e = babet.find(SB, { type = "f" })
    ok_val("find(sandbox, {type='f'})", results, e,
        function(x) return type(x) == "table" end)

    local default_results, default_err = babet.find(SB)
    ok_val("LOT 5B find(path) accepts omitted opts",
        default_results, default_err,
        function(x) return type(x) == "table" and #x > 0 end)
    local nil_results, nil_err = babet.find(SB, nil)
    ok_val("LOT 5B find(path, nil) uses default opts",
        nil_results, nil_err,
        function(x) return type(x) == "table" and #x > 0 end)

    results, e = babet.find("/n/existe/pas", { type = "f" })
    ok_fail("find(bad path) -> (nil, err)", results, e)

    ok_raises("LOT 3 find: NUL root rejected",
        function() return babet.find(SB .. "\0ignored", { type = "f" }) end,
        "NUL")
    for _, field in ipairs({ "type", "name", "iname", "path", "glob", "iglob",
        "path_glob", "path_iglob" }) do
        local opts = {}
        opts[field] = "f\0ignored"
        local nv, ne = babet.find(SB, opts)
        ok_fail("LOT 3 find: NUL in option '" .. field .. "' rejected",
            nv, ne)
    end

    -- find with RE2 regex : trouve tous les fichiers .txt
    -- of the sandbox (we created several during previous tests)
    local results_txt, e_txt = babet.find(SB, { type = "f", name = ".*\\.txt$" })
    ok_val("find with RE2 regex (.*\\.txt$)", results_txt, e_txt,
        function(x) return type(x) == "table" and #x > 0 end)

    -- find with iname (case-insensitive)
    local results_ci, e_ci = babet.find(SB, { type = "f", iname = ".*\\.TXT$" })
    ok_val("find iname case-insensitive", results_ci, e_ci,
        function(x) return type(x) == "table" and #x > 0 end)

    -- LOT 4/6/10 : chaque regex RE2 est compilée une seule fois par appel,
    -- puis réutilisée pour toutes les entrées du parcours, sans cache permanent.
    local path_cache_ok = true
    for _ = 1, 50 do
        local pr, pe = babet.find(SB, { type = "f", path = ".*\\.txt$" })
        if type(pr) ~= "table" or pe ~= nil or #pr == 0 then
            path_cache_ok = false
            break
        end
    end
    ok("LOT 6 find path regex repeated (once per call)", path_cache_ok)

    local dynamic_regex_ok = true
    for i = 1, 500 do
        local dr, de = babet.find(SB, {
            type = "f",
            name = "^lot6_dynamic_pattern_" .. tostring(i) .. "$",
        })
        if type(dr) ~= "table" or de ~= nil then
            dynamic_regex_ok = false
            break
        end
    end
    ok("LOT 6 find accepts many distinct regexes without permanent cache",
        dynamic_regex_ok)

    -- Concurrent find from multiple workers. Les objets RE2 vivent seulement
    -- le temps d'un appel : aucun cache mutable n'est partagé entre workers.
    do
        local W = babet.workers
        local jobs = {}
        for i = 1, 4 do
            jobs[i] = W.spawn([[
                local sb = worker.args.sb
                local pat = worker.args.pat
                local count = 0
                for _ = 1, 20 do
                    local r, err = babet.find(sb, { type = "f", name = pat })
                    if not r then return { error = err } end
                    count = count + #r
                end
                return { count = count }
            ]], { sb = SB, pat = ".*\\.txt$" .. tostring(i) })
        end

        local all_ok = true
        for i = 1, 4 do
            local jok, jval = jobs[i]:join()
            if not (jok == true and type(jval) == "table"
                    and type(jval.count) == "number") then
                all_ok = false
            end
        end
        ok("concurrent find x4 workers (per-call RE2 objects)",
            all_ok)
    end

    -- Lot 9 : globs bornés, sans std::regex ni backtracking récursif.
    -- Le langage est volontairement réduit : '*', '**', '?', et '\\'
    -- pour échapper l'octet suivant. Les correspondances sont ancrées sur
    -- le nom ou le chemin complet selon l'option.
    do
        local G = sb("find_glob")
        assert(babet.mkdir(G .. "/sub/deep"))

        local function put(path, data)
            local file = assert(io.open(path, "wb"))
            assert(file:write(data or "x"))
            assert(file:close())
        end

        put(G .. "/root.lua")
        put(G .. "/root.txt")
        put(G .. "/sub/a.lua")
        put(G .. "/sub/deep/b.LUA")
        put(G .. "/sub/deep/photo.JPG")
        put(G .. "/sub/deep/literal*.txt")
        put(G .. "/sub/deep/[abc]")
        local byte_name = "byte_" .. string.char(255) .. ".txt"
        put(G .. "/" .. byte_name)
        -- A 200-byte basename makes the nested-repetition regression
        -- meaningful: std::regex could backtrack catastrophically here,
        -- whereas RE2 must finish in linear time.
        put(G .. "/" .. string.rep("a", 200))

        -- Lot 10 : les champs historiques utilisent RE2 avec un budget mémoire
        -- explicite. name/iname restent des correspondances complètes ; path
        -- reste une recherche partielle dans le chemin complet.
        local v, e = babet.find(G, { type = "f", name = "a\\.lua" })
        ok("LOT 10 RE2 name keeps full-match semantics",
            type(v) == "table" and e == nil and #v == 1)

        v, e = babet.find(G, { type = "f", name = "lua" })
        ok("LOT 10 RE2 name does not perform a partial search",
            type(v) == "table" and e == nil and #v == 0)

        v, e = babet.find(G, {
            type = "f",
            path = "find_glob/sub/deep",
        })
        ok("LOT 10 RE2 path keeps partial-search semantics",
            type(v) == "table" and e == nil and #v >= 4)

        v, e = babet.find(G, { type = "f", name = "(a)\\1" })
        ok_fail("LOT 10 RE2 rejects backreferences", v, e)

        v, e = babet.find(G, { type = "f", name = "a(?=\\.lua)" })
        ok_fail("LOT 10 RE2 rejects look-ahead assertions", v, e)

        v, e = babet.find(G, { type = "f", name = "(?<=a)\\.lua" })
        ok_fail("LOT 10 RE2 rejects look-behind assertions", v, e)

        v, e = babet.find(G, { type = "f", name = "(" })
        ok_fail("LOT 10 RE2 reports invalid syntax cleanly", v, e)

        v, e = babet.find(G, {
            type = "f",
            name = string.rep("a", 4097),
        })
        ok_fail("LOT 10 find enforces the 4096-byte regex limit", v, e)

        v, e = babet.find(G, {
            type = "f",
            name = string.rep("a", 4096),
        })
        ok("LOT 10 find accepts the exact regex size boundary",
            type(v) == "table" and e == nil and #v == 0)

        v, e = babet.find(G, {
            type = "f",
            name = "(a+)+b",
        })
        ok("LOT 10 nested repetitions remain bounded under RE2",
            type(v) == "table" and e == nil)

        v, e = babet.find(G, {
            type = "f",
            name = "byte_.*\\.txt",
        })
        ok("LOT 10 RE2 Latin-1 mode accepts non-UTF-8 path bytes",
            type(v) == "table" and e == nil and #v == 1)

        local re2_job = babet.workers.spawn([[
            local r, err = babet.find(worker.args.root, {
                type = "f",
                iname = ".*\\.LUA$",
            })
            if not r then return { error = err } end
            return { count = #r }
        ]], { root = G })
        local re2_joined, re2_value = re2_job:join()
        ok("LOT 10 RE2 matching works in a worker",
            re2_joined == true and type(re2_value) == "table"
            and re2_value.count == 3 and re2_value.error == nil)

        local v, e = babet.find(G, { type = "f", glob = "*.lua" })
        ok("LOT 9 find glob matches the complete basename",
            type(v) == "table" and e == nil and #v == 2)

        v, e = babet.find(G, { type = "f", iglob = "*.lua" })
        ok("LOT 9 find iglob is ASCII case-insensitive",
            type(v) == "table" and e == nil and #v == 3)

        v, e = babet.find(G, { type = "f", glob = "?.lua" })
        ok("LOT 9 find glob '?' matches exactly one byte",
            type(v) == "table" and e == nil and #v == 1)

        v, e = babet.find(G, {
            type = "f",
            glob = "literal\\*.txt",
        })
        ok("LOT 9 find glob backslash escapes a wildcard",
            type(v) == "table" and e == nil and #v == 1)

        v, e = babet.find(G, { type = "f", glob = "[abc]" })
        ok("LOT 9 find glob treats unsupported brackets literally",
            type(v) == "table" and e == nil and #v == 1)

        v, e = babet.find(G, {
            type = "f",
            path_glob = "**/find_glob/*/*.lua",
        })
        ok("LOT 9 path_glob '*' does not cross a slash",
            type(v) == "table" and e == nil and #v == 1)

        v, e = babet.find(G, {
            type = "f",
            path_iglob = "**/find_glob/**/*.lua",
        })
        ok("LOT 9 path_iglob '**' crosses directory separators",
            type(v) == "table" and e == nil and #v == 2)

        v, e = babet.find(G, {
            type = "f",
            path_glob = "find_glob/**/*.lua",
        })
        ok("LOT 9 path_glob is anchored to the complete path",
            type(v) == "table" and e == nil and #v == 0)

        v, e = babet.find(G, {
            type = "f",
            name = ".*\\.lua$",
            glob = "a*",
        })
        ok("LOT 9 regex and glob filters combine with logical AND",
            type(v) == "table" and e == nil and #v == 1)

        v, e = babet.find(G, { glob = "abc\\" })
        ok_fail("LOT 9 find rejects a trailing glob escape", v, e)

        v, e = babet.find(G, {
            glob = string.rep("a", 4097),
        })
        ok_fail("LOT 9 find enforces the 4096-byte glob limit", v, e)

        v, e = babet.find(G, {
            glob = string.rep("a", 4096),
        })
        ok("LOT 9 find accepts the exact glob size boundary",
            type(v) == "table" and e == nil and #v == 0)

        v, e = babet.find(G, {
            glob = string.rep("*a", 1000) .. "b",
        })
        ok("LOT 9 hostile-looking glob remains bounded",
            type(v) == "table" and e == nil)

        local job = babet.workers.spawn([[
            local r, err = babet.find(worker.args.root, {
                type = "f",
                glob = "*.lua",
            })
            if not r then return { error = err } end
            return { count = #r }
        ]], { root = G })
        local joined, value = job:join()
        ok("LOT 9 safe glob works in a worker",
            joined == true and type(value) == "table"
            and value.count == 2 and value.error == nil)
    end

    -- =================================================================
    -- Régression (audit v21) : élagage maxdepth via pop() cassé.
    -- L'ancien code faisait `it.pop(); continue;` : pop() avance DÉJÀ
    -- l'itérateur sur l'entrée suivante du parent, et le ++it de la
    -- boucle avançait une SECONDE fois. Deux symptômes reproduits :
    --   1. L'entrée suivant un dossier élagué NON VIDE était
    --      silencieusement absente du résultat.
    --   2. Si le dossier élagué non vide était la DERNIÈRE entrée du
    --      parent, find retournait (nil, "cannot increment recursive
    --      directory iterator") au lieu du résultat.
    -- Fixture : prune/{d1,d2,d3} tous non vides + f1..f3.txt à la
    -- racine. Quel que soit l'ordre readdir, chaque dossier non vide
    -- est suivi d'une entrée OU est en dernière position : l'ancien
    -- code ne peut donc jamais rendre 6 entrées sans erreur.
    -- =================================================================
    do
        local P = sb("prune")
        ok_act("find prune: mkdir fixture", babet.mkdir(P .. "/d1/deep"))
        babet.mkdir(P .. "/d2")
        babet.mkdir(P .. "/d3")
        babet.touch(P .. "/d1/c1.txt")
        babet.touch(P .. "/d1/deep/dd.txt")
        babet.touch(P .. "/d2/c2.txt")
        babet.touch(P .. "/d3/c3.txt")
        babet.touch(P .. "/f1.txt")
        babet.touch(P .. "/f2.txt")
        babet.touch(P .. "/f3.txt")

        -- maxdepth=0 : exactement les 6 entrées de la racine
        -- (3 dossiers + 3 fichiers), aucune sautée, aucune erreur.
        local r0, e0 = babet.find(P, { maxdepth = 0 })
        ok_val("find maxdepth=0 -> 6 entrées, aucune sautée", r0, e0,
            function(x) return type(x) == "table" and #x == 6 end)

        -- maxdepth=0 + type=f : exactement f1..f3.
        local rf, ef = babet.find(P, { maxdepth = 0, type = "f" })
        ok_val("find maxdepth=0 type=f -> 3 fichiers", rf, ef,
            function(x) return type(x) == "table" and #x == 3 end)

        -- maxdepth=1 : c1..c3 inclus (depth 1), deep/dd.txt (depth 2)
        -- exclu.
        local r1, e1 = babet.find(P, { maxdepth = 1, type = "f" })
        ok_val("find maxdepth=1 type=f -> 6 fichiers (dd.txt exclu)", r1, e1,
            function(x) return type(x) == "table" and #x == 6 end)

        -- mindepth=1 + maxdepth=1 : la traversée sous mindepth doit
        -- continuer (mindepth filtre les RÉSULTATS, pas la descente).
        local rm, em = babet.find(P, { mindepth = 1, maxdepth = 1, type = "f" })
        ok_val("find mindepth=1 maxdepth=1 type=f -> 3 fichiers", rm, em,
            function(x) return type(x) == "table" and #x == 3 end)

        -- mindepth=2 sans maxdepth : seulement dd.txt.
        local r2, e2 = babet.find(P, { mindepth = 2, type = "f" })
        ok_val("find mindepth=2 type=f -> dd.txt seul", r2, e2,
            function(x)
                return type(x) == "table" and #x == 1
                    and x[1]:find("dd.txt", 1, true) ~= nil
            end)

        -- Régression (revue ChatGPT post-release) : mindepth/maxdepth
        -- étaient rangés dans des int -> narrowing du lua_Integer,
        -- comme max_splits de split. maxdepth = 2^32 devenait 0 (tout
        -- élagué sous la racine) et 2^31 devenait négatif (résultat
        -- vide). Désormais lua_Integer de bout en bout.
        local rw, ew = babet.find(P, { maxdepth = 4294967296, type = "f" })
        ok_val("find maxdepth=2^32 -> tous les fichiers (pas de narrowing)",
            rw, ew, function(x) return type(x) == "table" and #x == 7 end)
        local rz, ez = babet.find(P, { maxdepth = 2147483648, type = "f" })
        ok_val("find maxdepth=2^31 -> tous les fichiers", rz, ez,
            function(x) return type(x) == "table" and #x == 7 end)

        -- Validation durcie (revue ChatGPT post-v2.2.0) : un nombre
        -- non entier était tronqué en silence par lua_tointeger
        -- (1.5 -> 0 : élagage total), et toute string passait pour
        -- 'type' (= aucun filtre). Désormais : erreurs explicites.
        local rv, ev = babet.find(P, { maxdepth = 1.5 })
        ok_fail("find maxdepth=1.5 -> (nil, err)", rv, ev)
        ok("  message mentionne 'integer'",
            tostring(ev):find("integer", 1, true) ~= nil,
            "err=" .. tostring(ev))
        rv, ev = babet.find(P, { mindepth = 1.5 })
        ok_fail("find mindepth=1.5 -> (nil, err)", rv, ev)
        rv, ev = babet.find(P, { type = "file" })
        ok_fail("find type='file' -> (nil, err)", rv, ev)
        ok("  message mentionne f/d",
            tostring(ev):find('"f" or "d"', 1, true) ~= nil,
            "err=" .. tostring(ev))
        rv, ev = babet.find(P, { type = 42 })
        ok_fail("LOT 11 find type=42 -> (nil, err)", rv, ev)
        ok("  message mentionne 'string'",
            tostring(ev):find("string", 1, true) ~= nil,
            "err=" .. tostring(ev))

        rv, ev = babet.find(P, { maxdepth = "1" })
        ok_fail("LOT 11 find maxdepth numeric string rejected", rv, ev)
        ok("  message mentionne 'integer'",
            tostring(ev):find("integer", 1, true) ~= nil,
            "err=" .. tostring(ev))

        for _, field in ipairs({
            "name", "iname", "path", "glob", "iglob",
            "path_glob", "path_iglob",
        }) do
            local opts = { [field] = 42 }
            local bad_value, bad_err = babet.find(P, opts)
            ok_fail("LOT 11 find " .. field .. " is a strict string",
                bad_value, bad_err)
            ok("  " .. field .. " error mentions string",
                tostring(bad_err):find("string", 1, true) ~= nil,
                "err=" .. tostring(bad_err))
        end

        ok_raises("LOT 11 find root is a strict string",
            function() return babet.find(42) end,
            "string")
        ok_raises("LOT 11 find rejects excess arguments",
            function() return babet.find(P, nil, "extra") end,
            "one or two arguments")

        rv, ev = babet.find(P, { xdev = 1 })
        ok_fail("find xdev is a strict boolean", rv, ev)
        ok("  xdev error mentions boolean",
            tostring(ev):find("boolean", 1, true) ~= nil,
            "err=" .. tostring(ev))

        local default_xdev, default_xdev_err = babet.find(P, {
            type = "f",
        })
        local explicit_false, explicit_false_err = babet.find(P, {
            type = "f",
            xdev = false,
        })
        local function same_paths(left, right)
            if type(left) ~= "table" or type(right) ~= "table"
                or #left ~= #right then
                return false
            end
            for i = 1, #left do
                if left[i] ~= right[i] then return false end
            end
            return true
        end
        ok("find xdev=false preserves historical traversal",
            default_xdev_err == nil and explicit_false_err == nil
            and same_paths(default_xdev, explicit_false))

        local same_device, same_device_err = babet.find(P, {
            type = "f",
            xdev = true,
        })
        ok("find xdev keeps same-device traversal unchanged",
            default_xdev_err == nil and same_device_err == nil
            and same_paths(default_xdev, same_device))
    end

    -- Babet 2.21.0 : test réellement discriminant de xdev sur le montage
    -- devpts. /dev/pts est un système de fichiers distinct de /dev sur un
    -- Linux normal, et /dev/pts/ptmx fournit une entrée stable à observer.
    -- Le point de montage doit rester visible ; seul son contenu est élagué.
    do
        local function trim_stdout(result)
            if type(result) ~= "table" or type(result.stdout) ~= "string" then
                return nil
            end
            return (result.stdout:gsub("%s+$", ""))
        end

        local function device_id(path)
            return trim_stdout(babet.exec("stat", { "-c", "%d", path }))
        end

        local function contains(list, expected)
            if type(list) ~= "table" then return false end
            for _, value in ipairs(list) do
                if value == expected then return true end
            end
            return false
        end

        local dev_device = device_id("/dev")
        local pts_device = device_id("/dev/pts")
        ok("find xdev fixture uses a real foreign device",
            type(dev_device) == "string" and dev_device ~= ""
            and type(pts_device) == "string" and pts_device ~= ""
            and dev_device ~= pts_device,
            "dev=" .. tostring(dev_device)
                .. " pts=" .. tostring(pts_device))

        local unrestricted, unrestricted_err = babet.find("/dev", {
            maxdepth = 1,
            path_glob = "/dev/pts/*",
        })
        ok("find without xdev descends into devpts",
            unrestricted_err == nil
            and contains(unrestricted, "/dev/pts/ptmx"),
            tostring(unrestricted_err))

        local pruned, pruned_err = babet.find("/dev", {
            maxdepth = 1,
            path_glob = "/dev/pts/*",
            xdev = true,
        })
        ok("find xdev prunes foreign-device children",
            type(pruned) == "table" and pruned_err == nil and #pruned == 0,
            tostring(pruned_err))

        local mountpoint, mountpoint_err = babet.find("/dev", {
            maxdepth = 0,
            type = "d",
            path_glob = "/dev/pts",
            xdev = true,
        })
        ok("find xdev keeps the foreign mount point visible",
            mountpoint_err == nil
            and contains(mountpoint, "/dev/pts"),
            tostring(mountpoint_err))

        local linked_root = sb("find_xdev_root_link")
        pcall(babet.remove, linked_root)
        local linked = babet.exec("ln", { "-s", "/dev", linked_root })
        local linked_children, linked_children_err = nil, "link failed"
        local linked_point, linked_point_err = nil, "link failed"
        if type(linked) == "table" and linked.code == 0 then
            linked_children, linked_children_err = babet.find(linked_root, {
                maxdepth = 1,
                path_glob = linked_root .. "/pts/*",
                xdev = true,
            })
            linked_point, linked_point_err = babet.find(linked_root, {
                maxdepth = 0,
                type = "d",
                path_glob = linked_root .. "/pts",
                xdev = true,
            })
        end
        ok("find xdev uses the target device of a root symlink",
            type(linked_children) == "table"
            and linked_children_err == nil and #linked_children == 0
            and linked_point_err == nil
            and contains(linked_point, linked_root .. "/pts"),
            tostring(linked_children_err or linked_point_err))
        pcall(babet.remove, linked_root)

        local worker_job = babet.workers.spawn([[
            local children, children_err = babet.find("/dev", {
                maxdepth = 1,
                path_glob = "/dev/pts/*",
                xdev = true,
            })
            local point, point_err = babet.find("/dev", {
                maxdepth = 0,
                type = "d",
                path_glob = "/dev/pts",
                xdev = true,
            })
            if not children then return { error = children_err } end
            if not point then return { error = point_err } end
            return { child_count = #children, point_count = #point }
        ]])
        ok("find xdev starts in a worker", worker_job ~= nil)
        local worker_ok, worker_value = false, nil
        if worker_job then
            worker_ok, worker_value = worker_job:join()
        end
        ok("find xdev keeps identical worker semantics",
            worker_ok == true and type(worker_value) == "table"
            and worker_value.error == nil
            and worker_value.child_count == 0
            and worker_value.point_count == 1,
            type(worker_value) == "table"
                and tostring(worker_value.error) or tostring(worker_value))
    end

    -- Régression fs:: jetants (revue ChatGPT post-v2.2.0) : sur un
    -- parent EACCES, les variantes sans error_code de fs::exists /
    -- fs::is_directory lèvent (fs::exists n'avale que not-found,
    -- pas les permissions) ; l'exception traversait la frontière
    -- lua_CFunction -> abort au lieu de (nil, err). Le lot 21 passe
    -- tous les sites en variantes error_code. On vérifie ici que le
    -- contrat (nil, err) tient face à un parent inaccessible, dans
    -- plusieurs bindings à la fois.
    --
    -- Restauration des droits en pcall obligatoire : si un test
    -- lève, la ligne setMode(755) ne s'exécute pas et le sandbox
    -- devient impossible à nettoyer (chmod 000 hérité entre runs).
    do
        local roleaks = sb("roleaks")
        assert(babet.mkdir(roleaks))
        babet.touch(roleaks .. "/inside.txt")
        assert(babet.setMode(roleaks, tonumber("000", 8)))

        local function body()
            local v, e
            local function not_missing_message(label, value, err)
                ok_fail(label, value, err)
                local lower = tostring(err):lower()
                ok("  LOT 4 erreur système non déguisée en chemin absent",
                    lower:find("does not exist", 1, true) == nil
                    and lower:find("not found", 1, true) == nil,
                    "err=" .. tostring(err))
            end

            v, e = babet.find(roleaks .. "/x", { type = "f" })
            not_missing_message(
                "find sous parent EACCES -> (nil, err) sans crash", v, e)
            v, e = babet.remove(roleaks .. "/inside.txt")
            not_missing_message(
                "remove sous parent EACCES -> (nil, err) sans crash", v, e)
            v, e = babet.rename(roleaks .. "/a", roleaks .. "/b")
            not_missing_message(
                "rename sous parent EACCES -> (nil, err) sans crash", v, e)
            v, e = babet.link(roleaks .. "/inside.txt", roleaks .. "/ln")
            not_missing_message(
                "link sous parent EACCES -> (nil, err) sans crash", v, e)
            v, e = babet.copy(roleaks .. "/inside.txt",
                sb("lot4_copy_target.txt"))
            not_missing_message(
                "copy sous parent EACCES -> (nil, err) sans crash", v, e)
            v, e = babet.fileSize(roleaks .. "/inside.txt")
            not_missing_message(
                "fileSize sous parent EACCES -> (nil, err) précis", v, e)
        end
        local ok_body, err_body = pcall(body)

        -- Restauration inconditionnelle (try/finally maison) avant
        -- toute propagation d'erreur potentielle
        babet.setMode(roleaks, tonumber("755", 8))
        pcall(babet.rmdirAll, roleaks)

        if not ok_body then
            error(err_body)
        end
    end
end

-- =====================================================================
print("")
print("=== createFileIterator ===")

do
    local it, e = babet.createFileIterator(SB, true)
    ok_val("createFileIterator(sandbox)", it, e,
        function(x) return x ~= nil end)

    if it then
        local count = 0
        while true do
            local f = it:next()
            if not f then break end
            count = count + 1
        end
        ok("iterator walks files", count > 0, "count=" .. count)
    end

    local it2, e2 = babet.createFileIterator("/n/existe/pas")
    ok_fail("createFileIterator(bad) -> (nil, err)", it2, e2)

    ok_raises("LOT 3 createFileIterator: NUL path rejected",
        function() return babet.createFileIterator(SB .. "\0ignored") end,
        "NUL")

    ok_raises("LOT 11 createFileIterator path is a strict string",
        function() return babet.createFileIterator(42) end,
        "string")
    ok_raises("LOT 11 createFileIterator recursive is a strict boolean",
        function() return babet.createFileIterator(SB, 1) end,
        "boolean")
    ok_raises("LOT 11 createFileIterator rejects excess arguments",
        function()
            return babet.createFileIterator(SB, false, "extra")
        end,
        "one or two arguments")

    -- LOT 5B : un lien cassé est une entrée valide, mais pas un fichier
    -- régulier utilisable. Il doit être ignoré sans faire échouer tout
    -- l'itérateur. Un lien valide vers un fichier conserve le comportement
    -- historique : le chemin du lien est renvoyé.
    local iter_link_dir = sb("iterator_symlinks")
    babet.mkdir(iter_link_dir)
    babet.touch(iter_link_dir .. "/real.txt")
    babet.link("real.txt", iter_link_dir .. "/valid-link")
    babet.link("missing-target", iter_link_dir .. "/broken-link")

    local link_it, link_it_err = babet.createFileIterator(iter_link_dir)
    ok_val("LOT 5B FileIterator ignores dangling symlinks",
        link_it, link_it_err, function(x) return x ~= nil end)
    if link_it then
        local seen = {}
        while true do
            local f = link_it:next()
            if not f then break end
            seen[f] = true
        end
        ok("  regular file returned",
            seen[iter_link_dir .. "/real.txt"] == true)
        ok("  valid symlink to regular file returned",
            seen[iter_link_dir .. "/valid-link"] == true)
        ok("  dangling symlink skipped",
            seen[iter_link_dir .. "/broken-link"] ~= true)
    end
    babet.rmdirAll(iter_link_dir)

    -- Une vraie erreur de parcours ne doit pas être effacée par une entrée
    -- suivante. Le cas chmod 000 n'est pas discriminant sous root.
    local id_result = babet.exec("id", { "-u" })
    local uid = type(id_result) == "table"
        and tonumber((id_result.stdout or ""):match("%d+")) or nil
    if uid == 0 then
        print("[INFO] LOT 5B FileIterator permission error: SKIP (root)")
    elseif uid == nil then
        print("[INFO] LOT 5B FileIterator permission error: SKIP "
            .. "(UID indéterminable)")
    else
        local iter_err_dir = sb("iterator_permission_error")
        local locked_dir = iter_err_dir .. "/locked"
        babet.mkdir(locked_dir)
        babet.touch(locked_dir .. "/secret.txt")
        babet.touch(iter_err_dir .. "/visible.txt")
        babet.setMode(locked_dir, "000")

        local bad_it, bad_it_err = babet.createFileIterator(
            iter_err_dir, true)
        ok_val("FileIterator creation is lazy despite a locked subtree",
            bad_it, bad_it_err, function(x) return x ~= nil end)

        local traversal_err
        if bad_it then
            while true do
                local path, next_err = bad_it:next()
                if next_err then
                    traversal_err = next_err
                    break
                end
                if not path then
                    break
                end
            end
        end

        -- Restauration inconditionnelle avant les assertions/nettoyage.
        babet.setMode(locked_dir, "755")
        babet.rmdirAll(iter_err_dir)

        ok("FileIterator reports traversal errors from next()",
            type(traversal_err) == "string"
            and (traversal_err:find("cannot continue", 1, true) ~= nil
                or traversal_err:find("Permission denied", 1, true) ~= nil),
            "err=" .. tostring(traversal_err))
    end

    -- :close() puis :next() doit lever une erreur Lua propre
    local it3 = babet.createFileIterator(SB)
    if it3 then
        it3:close()
        local raised = not pcall(function() it3:next() end)
        ok("iterator :next() after :close() raises an error", raised)
    end
end

-- =====================================================================
print("")
print("=== require(): user module in subfolder ===")

do
    -- mymod/init.lua doit être found via require("mymod"),
    -- aussi bien en mode dossier qu'en mode embarqué.
    local loaded, mod = pcall(require, "mymod")
    ok("require('mymod') does not raise", loaded,
        loaded and "" or tostring(mod))

    if loaded then
        ok("mymod.hello() returns the right value",
            type(mod) == "table" and mod.hello and mod.hello() == "init.lua loaded !",
            mod and mod.hello and tostring(mod.hello()) or "table/fonction absente")
    end

    -- inspect is hard-bundled in the binary: must work even
    -- without inspect.lua on disk.
    -- Note : inspect est une TABLE appelable (métatable __call),
    -- not a function — so we test its callability, not its type.
    local ok_callable = pcall(function() return inspect("test") end)
    ok("inspect (bundled) is loaded and callable", ok_callable)

    local repr = inspect({ a = 1, b = "deux" })
    ok("inspect({a=1, b='two'}) returns a non-empty string",
        type(repr) == "string" and #repr > 0,
        "len=" .. tostring(#repr))
end

-- =====================================================================
end
