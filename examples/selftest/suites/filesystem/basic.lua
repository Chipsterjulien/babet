return function(test, context)
    local _ENV = test:environment(context)
-- =====================================================================
print("")
print("=== actions: filesystem ===")

do
    -- mkdir / rmdir
    ok_act("mkdir(sandbox/d1)", babet.mkdir(sb("d1")))
    ok_act("rmdir(sandbox/d1)", babet.rmdir(sb("d1")))

    local r, e = babet.rmdir(sb("d1")) -- already removed
    ok_fail("rmdir(already gone) -> (nil, err)", r, e)

    -- touch / remove
    ok_act("touch(sandbox/t1.txt)", babet.touch(sb("t1.txt")))
    ok_act("remove(sandbox/t1.txt)", babet.remove(sb("t1.txt")))

    ;(function()
        local keep_path = sb("touch_keep.txt")
        local keep = assert(io.open(keep_path, "wb"))
        keep:write("payload\0preserved")
        keep:close()
        local touch_ok, touch_err = babet.touch(keep_path)
        local check = assert(io.open(keep_path, "rb"))
        local contents = check:read("*a")
        check:close()
        ok("touch never truncates an existing file",
            touch_ok == true and touch_err == nil
            and contents == "payload\0preserved")

        local target_path = sb("touch_target.txt")
        local target = assert(io.open(target_path, "wb"))
        target:write("symlink-target")
        target:close()
        babet.exec("ln", { "-s", "touch_target.txt", sb("touch_link") })
        touch_ok, touch_err = babet.touch(sb("touch_link"))
        check = assert(io.open(target_path, "rb"))
        contents = check:read("*a")
        check:close()
        ok("touch follows a valid symlink without truncating its target",
            touch_ok == true and touch_err == nil
            and contents == "symlink-target")

        babet.exec("ln", { "-s", "touch_missing_target",
            sb("touch_dangling") })
        local dangling_ok, dangling_err = babet.touch(sb("touch_dangling"))
        ok_fail("touch safely refuses a dangling symlink",
            dangling_ok, dangling_err)
        ok("touch dangling-symlink refusal creates no target",
            babet.fileExists(sb("touch_missing_target")) == false)

        babet.exec("mkfifo", { sb("touch_fifo") })
        local before = babet.time.monotonic()
        touch_ok, touch_err = babet.touch(sb("touch_fifo"))
        local elapsed = babet.time.monotonic() - before
        ok("touch handles an existing FIFO without blocking",
            touch_ok == true and touch_err == nil and elapsed < 1.0,
            "elapsed=" .. tostring(elapsed) .. " err=" .. tostring(touch_err))
        babet.exec("rm", { "-f", sb("touch_fifo") })

        babet.mkdir(sb("touch_directory"))
        ok_act("touch still supports an existing directory",
            babet.touch(sb("touch_directory")))
    end)()

    r, e = babet.remove(sb("t1.txt")) -- already removed
    ok_fail("remove(already gone) -> (nil, err)", r, e)

    -- LOT 6 : contrats stricts remove/rmdir/rmdirAll.
    babet.mkdir(sb("lot6_remove_dir"))
    r, e = babet.remove(sb("lot6_remove_dir"))
    ok_fail("LOT 6 remove(directory) is rejected", r, e)
    ok("  directory remains after remove refusal",
        babet.isDir(sb("lot6_remove_dir")) == true)
    ok_act("  rmdir removes the empty directory",
        babet.rmdir(sb("lot6_remove_dir")))

    babet.touch(sb("lot6_rmdir_file"))
    r, e = babet.rmdir(sb("lot6_rmdir_file"))
    ok_fail("LOT 6 rmdir(file) is rejected", r, e)
    local ra, rea = babet.rmdirAll(sb("lot6_rmdir_file"))
    ok_fail("LOT 6 rmdirAll(file) is rejected", ra, rea)
    ok("  regular file remains after directory-operation refusals",
        babet.isFile(sb("lot6_rmdir_file")) == true)
    ok_act("  remove deletes the regular file",
        babet.remove(sb("lot6_rmdir_file")))

    babet.mkdir(sb("lot6_dir_target"))
    babet.exec("ln", { "-s", "lot6_dir_target", sb("lot6_dir_link") })
    r, e = babet.rmdir(sb("lot6_dir_link"))
    ok_fail("LOT 6 rmdir(directory symlink) is rejected", r, e)
    ra, rea = babet.rmdirAll(sb("lot6_dir_link"))
    ok_fail("LOT 6 rmdirAll(directory symlink) is rejected", ra, rea)
    ok("  directory target remains intact",
        babet.isDir(sb("lot6_dir_target")) == true)
    ok_act("  remove deletes the directory symlink itself",
        babet.remove(sb("lot6_dir_link")))
    ok_act("  cleanup real target directory",
        babet.rmdir(sb("lot6_dir_target")))

    babet.exec("ln", { "-s", "missing_target", sb("lot6_broken") })
    ok_act("LOT 6 remove(dangling symlink) succeeds",
        babet.remove(sb("lot6_broken")))

    babet.exec("ln", { "-s", "still_missing", sb("lot6_broken_old") })
    local rr, rre = babet.rename(
        sb("lot6_broken_old"), sb("lot6_broken_new"))
    ok_act("LOT 6 rename(dangling symlink) succeeds", rr, rre)
    local link_probe = babet.exec("readlink", { sb("lot6_broken_new") })
    ok("  renamed dangling symlink keeps its target",
        type(link_probe) == "table" and link_probe.code == 0
        and link_probe.stdout:find("still_missing", 1, true) ~= nil,
        type(link_probe) == "table" and link_probe.stdout or tostring(link_probe))
    ok_act("  cleanup renamed dangling symlink",
        babet.remove(sb("lot6_broken_new")))

    local fifo_create = babet.exec("mkfifo", { sb("lot6_fifo") })
    if type(fifo_create) == "table" and fifo_create.code == 0 then
        r, e = babet.remove(sb("lot6_fifo"))
        ok_fail("LOT 6 remove(FIFO) is rejected", r, e)
        babet.exec("rm", { "-f", sb("lot6_fifo") })
    else
        print("[INFO] LOT 6 remove(FIFO): SKIP (mkfifo unavailable)")
    end

    -- rename
    babet.touch(sb("old.txt"))
    ok_act("rename(old.txt -> new.txt)", babet.rename(sb("old.txt"), sb("new.txt")))

    r, e = babet.rename(sb("old.txt"), sb("x.txt")) -- source absente
    ok_fail("rename(missing source) -> (nil, err)", r, e)

    -- copy
    ok_act("copy(new.txt -> copy.txt)", babet.copy(sb("new.txt"), sb("copy.txt")))

    r, e = babet.copy(sb("nope.txt"), sb("x.txt"))
    ok_fail("copy(missing source) -> (nil, err)", r, e)

    -- link
    ok_act("link(new.txt -> link.txt)",
        babet.link(sb("new.txt"), sb("link.txt")))

    -- Régression (audit v21) : listFiles utilisait fs::relative, qui
    -- canonicalise et RÉSOUT les symlinks (même famille de bug que
    -- copyTree/moveTree/zip_utils). Un lien lfl/ln.txt -> ../out.txt
    -- était listé "../out_lfl.txt" (chemin de la CIBLE, sortant du
    -- dossier listé) au lieu de "ln.txt" (sa position). Désormais
    -- lexically_relative : la structure vue sur le disque.
    do
        babet.mkdir(sb("lfl"))
        babet.touch(sb("out_lfl.txt"))
        babet.touch(sb("lfl/real.txt"))
        ok_act("link relatif pour listFiles",
            babet.link("../out_lfl.txt", sb("lfl/ln.txt")))
        local files, lerr = babet.listFiles(sb("lfl"))
        ok_val("listFiles(lfl) -> table", files, lerr,
            function(x) return type(x) == "table" and #x == 2 end)
        local has_ln, has_dotdot = false, false
        if files then
            for _, f in ipairs(files) do
                if f == "ln.txt" then has_ln = true end
                if f:find("..", 1, true) then has_dotdot = true end
            end
        end
        ok("  contient 'ln.txt' (position du lien, pas sa cible)",
            has_ln)
        ok("  aucun chemin résolu sortant ('..')", not has_dotdot)
    end

    -- Régression (revue ChatGPT post-audit v21) : listFiles RÉCURSIF
    -- suivait les symlinks de dossiers (fs::is_directory suit les
    -- liens) : évasion hors de l'arbre listé, et une BOUCLE de liens
    -- (lfr/loop -> .) récursait jusqu'à ENAMETOOLONG au lieu d'un
    -- listing normal. Aligné sur find : liens de dossiers non suivis.
    -- Le premier test discrimine : l'ancien code rendait (nil, err).
    do
        babet.mkdir(sb("lfr/sub"))
        babet.mkdir(sb("lfr_out"))
        babet.touch(sb("lfr/real.txt"))
        babet.touch(sb("lfr/sub/inner.txt"))
        babet.touch(sb("lfr_out/ext.txt"))
        babet.link("../lfr_out", sb("lfr/goes_out"))
        babet.link(".", sb("lfr/loop"))
        local rfiles, rerr = babet.listFiles(sb("lfr"), true)
        ok_val("listFiles récursif + boucle de liens -> table propre",
            rfiles, rerr,
            function(x) return type(x) == "table" and #x == 2 end)
        local has_ext = false
        if rfiles then
            for _, f in ipairs(rfiles) do
                if f:find("ext.txt", 1, true) then has_ext = true end
            end
        end
        ok("  lien de dossier non suivi (ext.txt absent)", not has_ext)
    end

    -- mkdir : le contrat utile, verrouillé (la doc décrivait une
    -- option opts.parents qui n'a jamais existé — le code fait
    -- fs::create_directories, donc TOUJOURS récursif).
    do
        local r, e = babet.mkdir(sb("mkd/a/b/c"))
        ok_act("mkdir imbriqué nu (récursif d'office)", r, e)
        ok("  toute la chaîne existe",
            babet.isDir(sb("mkd/a/b/c")) == true)
        r, e = babet.mkdir(sb("mkd/a/b/c"))
        ok_act("mkdir(dossier existant) -> succès idempotent", r, e)
        babet.touch(sb("mkd/bloqueur"))
        local v2, e2 = babet.mkdir(sb("mkd/bloqueur/sous"))
        ok_fail("mkdir bloqué par un FICHIER -> (nil, err)", v2, e2)
        ok_raises("DOC FS mkdir: second argument rejected",
            function() return babet.mkdir(sb("mkd/extra"), true) end,
            "one argument")
    end

    -- copyTree
    babet.mkdir(sb("treesrc"))
    babet.touch(sb("treesrc/a.txt"))
    ok_act("copyTree(treesrc -> treedst)",
        babet.copyTree(sb("treesrc"), sb("treedst")))

    ok_raises("LOT 11 copyTree continue_on_error is a strict boolean",
        function()
            return babet.copyTree(sb("treesrc"), sb("treedst2"), 1)
        end,
        "boolean")
    ok_raises("LOT 11 copyTree rejects excess arguments",
        function()
            return babet.copyTree(
                sb("treesrc"), sb("treedst2"), false, "extra")
        end,
        "two string arguments")

    -- Audit documentation FS : le troisième argument vaut true par défaut.
    -- Un type d'entrée non pris en charge produit donc un warning, les autres
    -- entrées sont tout de même copiées, puis l'appel signale les warnings.
    do
        local default_src = sb("copytree_default_src")
        local default_dst = sb("copytree_default_dst")
        babet.mkdir(default_src)
        babet.touch(default_src .. "/visible.txt")
        local fifo_result = babet.exec("mkfifo", {
            default_src .. "/unsupported_fifo"
        })
        if type(fifo_result) == "table" and fifo_result.code == 0 then
            local dv, de = babet.copyTree(default_src, default_dst)
            ok_fail("DOC FS copyTree default continues and reports warnings",
                dv, de)
            ok("  default copied supported entries",
                babet.isFile(default_dst .. "/visible.txt") == true)
            ok("  default error mentions warnings",
                type(de) == "string"
                and de:find("warnings", 1, true) ~= nil,
                "err=" .. tostring(de))
            babet.exec("rm", { "-f", default_src .. "/unsupported_fifo" })
            babet.rmdirAll(default_src)
            babet.rmdirAll(default_dst)
        else
            print("[INFO] DOC FS copyTree default: SKIP (mkfifo unavailable)")
            babet.rmdirAll(default_src)
        end
    end

    -- LOT 6 : une copie crée un nouvel inode appartenant à l'appelant ; elle
    -- ne doit donc jamais recopier setuid/setgid/sticky depuis la source.
    babet.mkdir(sb("lot6_mode_src"))
    babet.touch(sb("lot6_mode_src/tool"))
    ok_act("LOT 6 setup: source mode 04755",
        babet.setMode(sb("lot6_mode_src/tool"), "4755"))
    local mode_copy, mode_copy_err = babet.copyTree(
        sb("lot6_mode_src"), sb("lot6_mode_dst"))
    ok_act("LOT 6 copyTree copies file with special mode safely",
        mode_copy, mode_copy_err)
    local copied_mode, copied_mode_err =
        babet.getMode(sb("lot6_mode_dst/tool"))
    ok("  copied inode keeps 0755 but drops special bits",
        copied_mode_err == nil and copied_mode == tonumber("755", 8),
        "mode=" .. tostring(copied_mode)
            .. " err=" .. tostring(copied_mode_err))

    -- moveTree
    babet.mkdir(sb("movesrc"))
    babet.touch(sb("movesrc/b.txt"))
    babet.mkdir(sb("movedst"))
    ok_act("moveTree(movesrc -> movedst)",
        babet.moveTree(sb("movesrc"), sb("movedst")))

    -- rmdirAll
    babet.mkdir(sb("deeptree"))
    babet.mkdir(sb("deeptree/sub"))
    babet.touch(sb("deeptree/sub/c.txt"))
    ok_act("rmdirAll(deeptree)", babet.rmdirAll(sb("deeptree")))

    -- moveTree fast path : destination INEXISTANTE, rename O(1) atomique
    babet.mkdir(sb("movefast"))
    babet.touch(sb("movefast/x.txt"))
    ok_act("moveTree(fast path: dest does not exist)",
        babet.moveTree(sb("movefast"), sb("movefast_new")))
    -- vérifie que le contenu est bien arrivé à destination
    local v_fast, _ = babet.fileExists(sb("movefast_new/x.txt"))
    ok("moveTree fast path: content moved", v_fast == true)
    -- et que la source a disparu
    local v_src, _ = babet.isdir(sb("movefast"))
    ok("moveTree fast path: source gone", v_src == false)

    -- moveTree échec : source inexistante -> (nil, err)
    local r_mv, e_mv = babet.moveTree(sb("n_existe_pas"), sb("dst"))
    ok_fail("moveTree(source does not exist) -> (nil, err)", r_mv, e_mv)

    -- garde-fou : destination inside source doit être refusée
    babet.mkdir(sb("nested_src"))
    babet.touch(sb("nested_src/file.txt"))

    local r_nest_mv, e_nest_mv = babet.moveTree(sb("nested_src"), sb("nested_src/backup"))
    ok_fail("moveTree(destination inside source) -> (nil, err)", r_nest_mv, e_nest_mv)
    ok("  message mentions 'inside'",
        type(e_nest_mv) == "string" and e_nest_mv:find("inside", 1, true) ~= nil,
        "err=" .. tostring(e_nest_mv))

    local r_nest_cp, e_nest_cp = babet.copyTree(sb("nested_src"), sb("nested_src/backup"), false)
    ok_fail("copyTree(destination inside source) -> (nil, err)", r_nest_cp, e_nest_cp)
    ok("  message mentions 'inside'",
        type(e_nest_cp) == "string" and e_nest_cp:find("inside", 1, true) ~= nil,
        "err=" .. tostring(e_nest_cp))

    -- nettoyage
    babet.rmdirAll(sb("nested_src"))

    -- --- durcissement symlinks (résolution réelle des chemins) -----
    -- Tout est confiné sous sb("sym") et nettoyé par UN seul rmdirAll :
    -- remove_all ne suit pas les liens et ne dépend pas de l'ordre, donc
    -- no dangling symlink can remain in the sandbox and bias
    -- une section ultérieure (ex. createFileIterator).
    local function mklink(target, linkpath)
        return babet.exec("ln", { "-s", target, linkpath })
    end
    local function readlink(p)
        local r = babet.exec("readlink", { p })
        return type(r) == "table" and (r.stdout:gsub("%s+$", "")) or nil
    end
    local function stdout_trim(r)
        if type(r) ~= "table" or type(r.stdout) ~= "string" then
            return nil
        end
        return (r.stdout:gsub("%s+$", ""))
    end
    local function realpath(p)
        return stdout_trim(babet.exec("readlink", { "-f", p }))
    end
    local function device_id(p)
        return stdout_trim(babet.exec("stat", { "-c", "%d", p }))
    end
    local cwd = babet.currentDir()
    local function abs(p) return cwd .. "/" .. p end

    do
        -- racine isolée, repartie de zéro même si un run précédent a coupé
        babet.rmdirAll(sb("sym"))
        babet.mkdir(sb("sym"))

        -- A) destination atteignant source VIA un symlink -> refus.
        --    Avant durcissement (comparaison lexicale), ce cas passait.
        babet.mkdir(sb("sym/hl_src"))
        babet.touch(sb("sym/hl_src/f.txt"))
        mklink(abs(sb("sym/hl_src")), sb("sym/hl_link"))

        local r1, e1 = babet.copyTree(sb("sym/hl_src"), sb("sym/hl_link/backup"))
        ok_fail("copyTree: dest via symlink to source -> refus", r1, e1)

        local r2, e2 = babet.moveTree(sb("sym/hl_src"), sb("sym/hl_link/backup"))
        ok_fail("moveTree: dest via symlink to source -> refus", r2, e2)

        -- B) LOT 6 : une racine source symbolique est refusée. Sinon,
        --    le fast path rename déplacerait le lien lui-même tandis que le
        --    fallback cross-filesystem copierait le contenu de sa cible.
        babet.mkdir(sb("sym/rs"))
        babet.touch(sb("sym/rs/data.txt"))
        mklink(abs(sb("sym/rs/data.txt")), sb("sym/rs/ptr"))
        mklink(abs(sb("sym/rs")), sb("sym/srcvia"))

        local src_link_copy, src_link_copy_err =
            babet.copyTree(sb("sym/srcvia"), sb("sym/viad_rejected"))
        ok_fail("LOT 6 copyTree: racine source symlink refusée",
            src_link_copy, src_link_copy_err)
        ok("  erreur copyTree mentionne symlink",
            type(src_link_copy_err) == "string"
            and src_link_copy_err:find("symlink", 1, true) ~= nil,
            tostring(src_link_copy_err))

        local src_link_move, src_link_move_err =
            babet.moveTree(sb("sym/srcvia"), sb("sym/moved_via_rejected"))
        ok_fail("LOT 6 moveTree: racine source symlink refusée",
            src_link_move, src_link_move_err)
        ok("  erreur moveTree mentionne symlink",
            type(src_link_move_err) == "string"
            and src_link_move_err:find("symlink", 1, true) ~= nil,
            tostring(src_link_move_err))
        ok("  lien source et cible restent intacts après refus",
            readlink(sb("sym/srcvia")) == abs(sb("sym/rs"))
            and babet.isFile(sb("sym/rs/data.txt")) == true)

        -- Les liens internes restent, eux, pris en charge et retargetés.
        local rc, rc_err = babet.copyTree(sb("sym/rs"), sb("sym/viad"))
        ok_act("copyTree(source réelle -> viad)", rc, rc_err)
        local tgt = readlink(sb("sym/viad/ptr"))
        ok("absolute intra-source link retargeted to destination",
            type(tgt) == "string"
            and tgt:find("viad/data.txt", 1, true) ~= nil
            and tgt:find("/rs/data.txt", 1, true) == nil,
            "tgt=" .. tostring(tgt))

        -- C) lien pointant HORS de source : conservé tel quel.
        babet.mkdir(sb("sym/os_src"))
        babet.touch(sb("sym/os_src/keep.txt"))
        mklink("/tmp", sb("sym/os_src/outside"))
        local rc2 = babet.copyTree(sb("sym/os_src"), sb("sym/os_dst"))
        ok_act("copyTree(os_src -> os_dst)", rc2)
        ok("out-of-source link preserved as-is",
            readlink(sb("sym/os_dst/outside")) == "/tmp",
            "tgt=" .. tostring(readlink(sb("sym/os_dst/outside"))))

        -- D) lien CASSÉ (cible inexistante) : moveTree le conserve,
        --    without error (decision #2 acted on).
        babet.mkdir(sb("sym/bk_src"))
        mklink("/n/existe/pas/cible", sb("sym/bk_src/broken"))
        local rm = babet.moveTree(sb("sym/bk_src"), sb("sym/bk_dst"))
        ok_act("moveTree with broken link: no error", rm)
        ok("broken link preserved identical",
            readlink(sb("sym/bk_dst/broken")) == "/n/existe/pas/cible",
            "tgt=" .. tostring(readlink(sb("sym/bk_dst/broken"))))

        -- E) piège du préfixe ".." : un composant "..data" commence par
        --    the characters ".." without being the parent. The destination is
        --    bien DANS source -> doit être refusée (before le fix par
        --    composant, ce cas passait à tort = trou du garde).
        babet.mkdir(sb("sym/dd_src"))
        babet.touch(sb("sym/dd_src/f.txt"))
        local rdd, edd = babet.copyTree(sb("sym/dd_src"), sb("sym/dd_src/..data"))
        ok_fail("copyTree: dest 'src/..data' (inside source) -> refus", rdd, edd)
        local rdm, edm = babet.moveTree(sb("sym/dd_src"), sb("sym/dd_src/..data"))
        ok_fail("moveTree: dest 'src/..data' (inside source) -> refus", rdm, edm)

        -- F) Régression LOT 1 : un lien absolu interne doit être
        --    réécrit de façon identique sur le même filesystem. Avant le
        --    correctif, le fast path fs::rename déplaçait le dossier en bloc
        --    et laissait le lien pointer vers l'ancien emplacement.
        babet.mkdir(sb("sym/lot1_same_src"))
        babet.touch(sb("sym/lot1_same_src/data.txt"))
        mklink(abs(sb("sym/lot1_same_src/data.txt")),
            sb("sym/lot1_same_src/ptr"))
        local mv_same, mv_same_err = babet.moveTree(
            sb("sym/lot1_same_src"), sb("sym/lot1_same_dst"))
        ok_act("LOT 1 moveTree: lien absolu interne (même FS)",
            mv_same, mv_same_err)
        local same_target = readlink(sb("sym/lot1_same_dst/ptr"))
        local same_expected_root = realpath(sb("sym/lot1_same_dst"))
        ok("  cible réécrite vers la destination",
            type(same_expected_root) == "string"
            and same_target == same_expected_root .. "/data.txt",
            "target=" .. tostring(same_target)
            .. " expected=" .. tostring(same_expected_root))
        ok("  lien déplacé résout le fichier",
            babet.isFile(sb("sym/lot1_same_dst/ptr")) == true)
        ok("  source supprimée après succès",
            babet.isDir(sb("sym/lot1_same_src")) == false)

        -- G) Régression LOT 1 : même sémantique lors d'un déplacement
        --    réellement cross-filesystem. Le test est ignoré proprement si
        --    /dev/shm n'est pas disponible, pas inscriptible, ou vit sur le
        --    même device que le sandbox.
        do
            local cross_dst = "/dev/shm/babet_lot1_move_"
                .. tostring(babet.pid())
            babet.rmdirAll(cross_dst)

            local probe_ok = babet.mkdir(cross_dst)
            local sandbox_dev = device_id(SB)
            local shm_dev = device_id(cross_dst)
            babet.rmdirAll(cross_dst)

            if probe_ok == true and sandbox_dev and shm_dev
                and sandbox_dev ~= shm_dev then
                babet.mkdir(sb("sym/lot1_cross_src"))
                babet.touch(sb("sym/lot1_cross_src/data.txt"))
                mklink(abs(sb("sym/lot1_cross_src/data.txt")),
                    sb("sym/lot1_cross_src/ptr"))

                local mv_cross, mv_cross_err = babet.moveTree(
                    sb("sym/lot1_cross_src"), cross_dst)
                ok_act("LOT 1 moveTree: lien absolu interne (cross-FS)",
                    mv_cross, mv_cross_err)

                local cross_target = readlink(cross_dst .. "/ptr")
                local cross_expected_root = realpath(cross_dst)
                ok("  cible cross-FS réécrite vers la destination",
                    type(cross_expected_root) == "string"
                    and cross_target == cross_expected_root .. "/data.txt",
                    "target=" .. tostring(cross_target)
                    .. " expected=" .. tostring(cross_expected_root))
                ok("  lien cross-FS résout le fichier",
                    babet.isFile(cross_dst .. "/ptr") == true)
                ok("  source cross-FS supprimée après succès",
                    babet.isDir(sb("sym/lot1_cross_src")) == false)
                babet.rmdirAll(cross_dst)

                local cross_mode_dst = "/dev/shm/babet_lot6_mode_"
                    .. tostring(babet.pid())
                babet.rmdirAll(cross_mode_dst)
                babet.mkdir(sb("sym/lot6_cross_mode_src"))
                babet.touch(sb("sym/lot6_cross_mode_src/tool"))
                babet.setMode(sb("sym/lot6_cross_mode_src/tool"), "4755")
                local mm, mme = babet.moveTree(
                    sb("sym/lot6_cross_mode_src"), cross_mode_dst)
                ok_act("LOT 6 moveTree cross-FS strips special bits",
                    mm, mme)
                local cross_mode, cross_mode_err =
                    babet.getMode(cross_mode_dst .. "/tool")
                ok("  cross-FS copied inode mode is 0755",
                    cross_mode_err == nil and cross_mode == tonumber("755", 8),
                    "mode=" .. tostring(cross_mode)
                        .. " err=" .. tostring(cross_mode_err))
                babet.rmdirAll(cross_mode_dst)
            else
                print("[INFO] LOT 1 moveTree cross-FS: SKIP "
                    .. "(/dev/shm indisponible ou même filesystem)")
            end
        end

        -- H) Régression LOT 1 : une collision pendant la création du lien
        --    destination ne doit supprimer NI le lien source, NI ses fichiers.
        --    Avant le correctif, remove_all(source) était exécuté avant
        --    create_symlink(destination), provoquant une perte de données.
        babet.mkdir(sb("sym/lot1_collision_src"))
        babet.touch(sb("sym/lot1_collision_src/data.txt"))
        local collision_original_target =
            abs(sb("sym/lot1_collision_src/data.txt"))
        mklink(collision_original_target,
            sb("sym/lot1_collision_src/ptr"))
        babet.mkdir(sb("sym/lot1_collision_dst"))
        do
            local f = assert(io.open(
                sb("sym/lot1_collision_dst/ptr"), "wb"))
            f:write("DESTINATION_INTACT")
            f:close()
        end

        local mv_collision, mv_collision_err = babet.moveTree(
            sb("sym/lot1_collision_src"),
            sb("sym/lot1_collision_dst"))
        ok_fail("LOT 1 moveTree: collision de lien -> échec propre",
            mv_collision, mv_collision_err)
        ok("  lien source toujours présent et inchangé",
            readlink(sb("sym/lot1_collision_src/ptr"))
                == collision_original_target,
            "target=" .. tostring(
                readlink(sb("sym/lot1_collision_src/ptr"))))
        ok("  fichier source toujours présent",
            babet.isFile(sb("sym/lot1_collision_src/data.txt")) == true)
        ok("  dossier source toujours présent",
            babet.isDir(sb("sym/lot1_collision_src")) == true)
        do
            local f = io.open(sb("sym/lot1_collision_dst/ptr"), "rb")
            local content = f and f:read("*a") or nil
            if f then f:close() end
            ok("  collision destination laissée intacte",
                content == "DESTINATION_INTACT",
                "content=" .. tostring(content))
        end

        -- I) Régression LOT 5A : une destination de fusion ne doit
        --    jamais traverser un symlink déjà présent. Les écritures
        --    restent confinées sous la racine destination, y compris
        --    pour le dernier composant (fichier symlinké).
        do
            local outside = sb("sym/lot5a_outside")
            babet.mkdir(outside)

            -- Dossier intermédiaire destination -> extérieur.
            babet.mkdir(sb("sym/lot5a_copy_src/sub"))
            babet.touch(sb("sym/lot5a_copy_src/sub/file.txt"))
            babet.mkdir(sb("sym/lot5a_copy_dst"))
            mklink(abs(outside), sb("sym/lot5a_copy_dst/sub"))

            local cp_escape, cp_escape_err = babet.copyTree(
                sb("sym/lot5a_copy_src"),
                sb("sym/lot5a_copy_dst"), false)
            ok_fail("LOT 5A copyTree: symlink de dossier destination refusé",
                cp_escape, cp_escape_err)
            ok("  erreur copyTree mentionne le symlink",
                type(cp_escape_err) == "string"
                and cp_escape_err:find("symlink", 1, true) ~= nil,
                "err=" .. tostring(cp_escape_err))
            ok("  aucun fichier écrit hors destination",
                babet.fileExists(outside .. "/file.txt") == false)
            ok("  source copyTree intacte après refus",
                babet.fileExists(sb("sym/lot5a_copy_src/sub/file.txt"))
                    == true)

            -- Dernier composant destination symlinké vers un fichier
            -- extérieur : la cible ne doit jamais être tronquée.
            babet.mkdir(sb("sym/lot5a_file_src"))
            do
                local f = assert(io.open(
                    sb("sym/lot5a_file_src/file.txt"), "wb"))
                f:write("NEW")
                f:close()
            end
            babet.mkdir(sb("sym/lot5a_file_dst"))
            do
                local f = assert(io.open(outside .. "/target.txt", "wb"))
                f:write("ORIGINAL")
                f:close()
            end
            mklink(abs(outside .. "/target.txt"),
                sb("sym/lot5a_file_dst/file.txt"))

            local cp_file, cp_file_err = babet.copyTree(
                sb("sym/lot5a_file_src"),
                sb("sym/lot5a_file_dst"), false)
            ok_fail("LOT 5A copyTree: fichier destination symlinké refusé",
                cp_file, cp_file_err)
            local target_file = io.open(outside .. "/target.txt", "rb")
            local target_content = target_file and target_file:read("*a")
                or nil
            if target_file then target_file:close() end
            ok("  cible extérieure strictement inchangée",
                target_content == "ORIGINAL",
                "content=" .. tostring(target_content))

            -- Même garde pour moveTree : le refus intervient avant le
            -- premier déplacement, donc source et extérieur restent intacts.
            babet.mkdir(sb("sym/lot5a_move_src/sub"))
            babet.touch(sb("sym/lot5a_move_src/sub/file.txt"))
            babet.mkdir(sb("sym/lot5a_move_dst"))
            mklink(abs(outside), sb("sym/lot5a_move_dst/sub"))

            local mv_escape, mv_escape_err = babet.moveTree(
                sb("sym/lot5a_move_src"),
                sb("sym/lot5a_move_dst"))
            ok_fail("LOT 5A moveTree: symlink de dossier destination refusé",
                mv_escape, mv_escape_err)
            ok("  erreur moveTree mentionne le symlink",
                type(mv_escape_err) == "string"
                and mv_escape_err:find("symlink", 1, true) ~= nil,
                "err=" .. tostring(mv_escape_err))
            ok("  extérieur intact après moveTree",
                babet.fileExists(outside .. "/file.txt") == false)
            ok("  source moveTree intacte après refus",
                babet.fileExists(sb("sym/lot5a_move_src/sub/file.txt"))
                    == true)

            -- Dernier composant symlinké : moveTree possède son propre
            -- chemin renameat/cross-device et doit appliquer la même garde.
            babet.mkdir(sb("sym/lot5a_move_file_src"))
            do
                local f = assert(io.open(
                    sb("sym/lot5a_move_file_src/file.txt"), "wb"))
                f:write("MOVE_NEW")
                f:close()
            end
            babet.mkdir(sb("sym/lot5a_move_file_dst"))
            do
                local f = assert(io.open(
                    outside .. "/move_target.txt", "wb"))
                f:write("MOVE_ORIGINAL")
                f:close()
            end
            mklink(abs(outside .. "/move_target.txt"),
                sb("sym/lot5a_move_file_dst/file.txt"))

            local mv_file, mv_file_err = babet.moveTree(
                sb("sym/lot5a_move_file_src"),
                sb("sym/lot5a_move_file_dst"))
            ok_fail("LOT 5A moveTree: fichier destination symlinké refusé",
                mv_file, mv_file_err)
            local move_target = io.open(
                outside .. "/move_target.txt", "rb")
            local move_target_content = move_target
                and move_target:read("*a") or nil
            if move_target then move_target:close() end
            ok("  cible extérieure moveTree inchangée",
                move_target_content == "MOVE_ORIGINAL",
                "content=" .. tostring(move_target_content))
            ok("  fichier source moveTree conservé après refus",
                babet.fileExists(
                    sb("sym/lot5a_move_file_src/file.txt")) == true)
        end

        -- nettoyage : un seul appel, sûr, indépendant de l'ordre
        babet.rmdirAll(sb("sym"))
    end

    -- Régression LOT 3 : aucun chemin Lua contenant un NUL ne doit être
    -- tronqué puis agir sur la partie située avant le NUL.
    for _, entry in ipairs({
        { "mkdir", function(p) return babet.mkdir(p) end },
        { "touch", function(p) return babet.touch(p) end },
        { "remove", function(p) return babet.remove(p) end },
        { "rmdir", function(p) return babet.rmdir(p) end },
        { "rmdirAll", function(p) return babet.rmdirAll(p) end },
    }) do
        ok_raises("LOT 3 " .. entry[1] .. ": NUL path rejected",
            function() return entry[2](sb("nul_target") .. "\0ignored") end,
            "NUL")
    end

    for _, entry in ipairs({
        { "copy", function(a, b) return babet.copy(a, b) end },
        { "rename", function(a, b) return babet.rename(a, b) end },
        { "link", function(a, b) return babet.link(a, b) end },
        { "copyTree", function(a, b) return babet.copyTree(a, b) end },
        { "moveTree", function(a, b) return babet.moveTree(a, b) end },
    }) do
        ok_raises("LOT 3 " .. entry[1] .. ": NUL source rejected",
            function() return entry[2](sb("probe.txt") .. "\0ignored",
                sb("nul_dest")) end, "NUL")
        ok_raises("LOT 3 " .. entry[1] .. ": NUL destination rejected",
            function() return entry[2](sb("probe.txt"),
                sb("nul_dest") .. "\0ignored") end, "NUL")
    end

    -- Régression LOT 1 : copyTree ne doit plus ignorer silencieusement
    -- une branche inaccessible. Sous root, chmod 000 ne discrimine pas le
    -- bug historique (root conserve l'accès), donc le cas est SKIP.
    do
        local id_result = babet.exec("id", { "-u" })
        local uid = tonumber(stdout_trim(id_result))
        if uid == 0 then
            print("[INFO] LOT 1 copyTree permissions: SKIP (root)")
        elseif uid == nil then
            print("[INFO] LOT 1 copyTree permissions: SKIP "
                .. "(UID indéterminable)")
        else
            local perm_src = sb("lot1_perm_src")
            local perm_strict = sb("lot1_perm_strict")
            local perm_continue = sb("lot1_perm_continue")

            babet.mkdir(perm_src .. "/locked")
            babet.touch(perm_src .. "/visible.txt")
            babet.touch(perm_src .. "/locked/secret.txt")
            ok_act("LOT 1 setup: verrouillage du sous-dossier",
                babet.setMode(perm_src .. "/locked", "000"))

            local strict_ok, strict_err = babet.copyTree(
                perm_src, perm_strict, false)
            ok_fail("LOT 1 copyTree strict: dossier illisible -> erreur",
                strict_ok, strict_err)
            ok("  erreur strict explicite",
                type(strict_err) == "string"
                and strict_err:find("cannot read directory", 1, true)
                    ~= nil,
                "err=" .. tostring(strict_err))

            local continue_ok, continue_err = babet.copyTree(
                perm_src, perm_continue, true)
            ok_fail("LOT 1 copyTree continue: warnings signalés",
                continue_ok, continue_err)
            ok("  résultat mentionne les warnings",
                type(continue_err) == "string"
                and continue_err:find("warnings", 1, true) ~= nil,
                "err=" .. tostring(continue_err))
            ok("  fichier accessible tout de même copié",
                babet.isFile(perm_continue .. "/visible.txt") == true)
            ok("  fichier inaccessible non copié",
                babet.fileExists(
                    perm_continue .. "/locked/secret.txt") == false)

            -- Restaurer avant le nettoyage, sinon rmdirAll peut échouer pour
            -- un utilisateur non privilégié.
            babet.setMode(perm_src .. "/locked", "700")
            babet.rmdirAll(perm_src)
            babet.rmdirAll(perm_strict)
            babet.rmdirAll(perm_continue)
        end
    end
end


end
