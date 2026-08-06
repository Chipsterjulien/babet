return function(test, context)
    local _ENV = test:environment(context)
-- =====================================================================
print("")
print("=== writeFileAtomic ===")

do
    local function read_binary(path)
        local file = assert(io.open(path, "rb"))
        local data = file:read("*a")
        file:close()
        return data
    end

    ok("writeFileAtomic is a function",
        type(babet.writeFileAtomic) == "function")

    local binary_path = sb("atomic-binary.dat")
    local binary = "header\0payload\255tail"
    ok_act("writeFileAtomic creates a binary file",
        babet.writeFileAtomic(binary_path, binary))
    ok("writeFileAtomic preserves embedded NUL and non-UTF-8 bytes",
        read_binary(binary_path) == binary)

    local preserved_ok, preserved_err = babet.writeFileAtomic(
        binary_path, "must-not-replace")
    ok_fail("writeFileAtomic refuses overwrite by default",
        preserved_ok, preserved_err)
    ok("writeFileAtomic keeps the previous destination on refusal",
        read_binary(binary_path) == binary)
    ok("writeFileAtomic default-overwrite error is explicit",
        type(preserved_err) == "string"
        and preserved_err:find("already exists", 1, true) ~= nil,
        tostring(preserved_err))

    ok_act("writeFileAtomic overwrite=true replaces atomically",
        babet.writeFileAtomic(binary_path, "replacement", {
            overwrite = true,
        }))
    ok("writeFileAtomic replacement content is complete",
        read_binary(binary_path) == "replacement")

    local mode_path = sb("atomic-mode.dat")
    ok_act("writeFileAtomic applies explicit permissions",
        babet.writeFileAtomic(mode_path, "secret", {
            permissions = tonumber("600", 8),
        }))
    local mode, mode_err = babet.getMode(mode_path)
    ok("writeFileAtomic permissions are exact despite umask",
        mode == tonumber("600", 8) and mode_err == nil,
        "mode=" .. tostring(mode) .. " err=" .. tostring(mode_err))

    local empty_path = sb("atomic-empty.dat")
    ok_act("writeFileAtomic accepts an empty binary string",
        babet.writeFileAtomic(empty_path, ""))
    ok("writeFileAtomic empty output has size zero",
        babet.fileSize(empty_path) == 0)

    local fast_path = sb("atomic-fast.dat")
    ok_act("writeFileAtomic durable=false keeps atomic publication",
        babet.writeFileAtomic(fast_path, "fast", {
            durable = false,
        }))
    ok("writeFileAtomic durable=false wrote complete content",
        read_binary(fast_path) == "fast")

    local nil_opts_path = sb("atomic-nil-opts.dat")
    ok_act("writeFileAtomic accepts explicit nil options",
        babet.writeFileAtomic(nil_opts_path, "nil-options", nil))

    local special_path = sb("atomic $;\"'*.dat")
    ok_act("writeFileAtomic treats special path bytes literally",
        babet.writeFileAtomic(special_path, "literal"))
    ok("writeFileAtomic special path content is correct",
        read_binary(special_path) == "literal")

    local missing_ok, missing_err = babet.writeFileAtomic(
        sb("missing-parent/file.dat"), "x")
    ok_fail("writeFileAtomic does not create missing parents",
        missing_ok, missing_err)
    ok("writeFileAtomic missing-parent failure creates no directory",
        babet.isDir(sb("missing-parent")) == false)

    local dotdot_ok, dotdot_err = babet.writeFileAtomic(
        SB .. "/sub/../atomic-dotdot.dat", "x")
    ok_fail("writeFileAtomic rejects '..' path components",
        dotdot_ok, dotdot_err)

    local target_path = sb("atomic-target.dat")
    ok_act("writeFileAtomic symlink target setup",
        babet.writeFileAtomic(target_path, "target"))
    local ln_result = babet.exec("ln", {
        "-s", "atomic-target.dat", sb("atomic-link.dat"),
    })
    if type(ln_result) == "table" and ln_result.code == 0 then
        local link_ok, link_err = babet.writeFileAtomic(
            sb("atomic-link.dat"), "attack", { overwrite = true })
        ok_fail("writeFileAtomic refuses a final symlink",
            link_ok, link_err)
        ok("writeFileAtomic never modifies a symlink target",
            read_binary(target_path) == "target")
    else
        print("[INFO] writeFileAtomic final symlink: SKIP (ln unavailable)")
    end

    ok_act("writeFileAtomic parent-symlink setup directory",
        babet.mkdir(sb("atomic-real-parent")))
    ln_result = babet.exec("ln", {
        "-s", "atomic-real-parent", sb("atomic-parent-link"),
    })
    if type(ln_result) == "table" and ln_result.code == 0 then
        local parent_ok, parent_err = babet.writeFileAtomic(
            sb("atomic-parent-link/escape.dat"), "attack")
        ok_fail("writeFileAtomic refuses symlinked parent components",
            parent_ok, parent_err)
        ok("writeFileAtomic creates nothing through a parent symlink",
            babet.fileExists(sb("atomic-real-parent/escape.dat")) == false)
    else
        print("[INFO] writeFileAtomic parent symlink: SKIP (ln unavailable)")
    end

    ok_act("writeFileAtomic directory-target setup",
        babet.mkdir(sb("atomic-directory-target")))
    local dir_ok, dir_err = babet.writeFileAtomic(
        sb("atomic-directory-target"), "x", { overwrite = true })
    ok_fail("writeFileAtomic refuses a directory destination",
        dir_ok, dir_err)

    local fifo_result = babet.exec("mkfifo", { sb("atomic-fifo") })
    if type(fifo_result) == "table" and fifo_result.code == 0 then
        local before = babet.time.monotonic()
        local fifo_ok, fifo_err = babet.writeFileAtomic(
            sb("atomic-fifo"), "x", { overwrite = true })
        local elapsed = babet.time.monotonic() - before
        ok_fail("writeFileAtomic refuses a FIFO destination",
            fifo_ok, fifo_err)
        ok("writeFileAtomic FIFO refusal never blocks",
            elapsed < 1.0, "elapsed=" .. tostring(elapsed))
        babet.exec("rm", { "-f", sb("atomic-fifo") })
    else
        print("[INFO] writeFileAtomic FIFO: SKIP (mkfifo unavailable)")
    end

    local leftovers = 0
    for _, path in ipairs(assert(babet.listFiles(SB))) do
        if path:find(".babet-write-", 1, true) then
            leftovers = leftovers + 1
        end
    end
    ok("writeFileAtomic leaves no temporary file after success/refusal",
        leftovers == 0, "leftovers=" .. tostring(leftovers))

    ok_raises("writeFileAtomic requires path and data",
        function() return babet.writeFileAtomic("only-path") end,
        "two or three arguments")
    ok_raises("writeFileAtomic rejects excess arguments",
        function()
            return babet.writeFileAtomic("a", "b", nil, "extra")
        end,
        "two or three arguments")
    ok_raises("writeFileAtomic path must be a strict string",
        function() return babet.writeFileAtomic(42, "x") end,
        "string")
    ok_raises("writeFileAtomic data must be a strict string",
        function() return babet.writeFileAtomic("x", 42) end,
        "string")
    ok_raises("writeFileAtomic rejects NUL in path",
        function()
            return babet.writeFileAtomic(sb("nul\0ignored"), "x")
        end,
        "NUL")
    ok_raises("writeFileAtomic opts must be a table",
        function() return babet.writeFileAtomic("x", "x", 42) end,
        "table")
    ok_raises("writeFileAtomic overwrite must be boolean",
        function()
            return babet.writeFileAtomic("x", "x", { overwrite = 1 })
        end,
        "opts.overwrite")
    ok_raises("writeFileAtomic durable must be boolean",
        function()
            return babet.writeFileAtomic("x", "x", { durable = 1 })
        end,
        "opts.durable")
    ok_raises("writeFileAtomic permissions must be integer",
        function()
            return babet.writeFileAtomic("x", "x", {
                permissions = "600",
            })
        end,
        "opts.permissions")
    ok_raises("writeFileAtomic rejects negative permissions",
        function()
            return babet.writeFileAtomic("x", "x", { permissions = -1 })
        end,
        "between 0 and 0777")
    ok_raises("writeFileAtomic rejects permissions above 0777",
        function()
            return babet.writeFileAtomic("x", "x", {
                permissions = tonumber("1000", 8),
            })
        end,
        "between 0 and 0777")
    ok_raises("writeFileAtomic rejects unknown options",
        function()
            return babet.writeFileAtomic("x", "x", { parents = true })
        end,
        "unknown option")
    ok_raises("writeFileAtomic rejects non-string option keys",
        function()
            return babet.writeFileAtomic("x", "x", { [1] = true })
        end,
        "keys must be strings")
end

-- =====================================================================
print("")
print("=== actions: attributes ===")

do
    -- setMode / getMode : on teste les DEUX formes accepteds
    babet.touch(sb("perm.txt"))

    -- forme string (réflexe chmod)
    ok_act("setMode(perm.txt, '700') [string]",
        babet.setMode(sb("perm.txt"), "700"))
    local m, e = babet.getMode(sb("perm.txt"))
    ok("getMode reflects setMode('700')", m == tonumber("700", 8) and e == nil,
        "mode=" .. tostring(m))

    -- forme nombre
    ok_act("setMode(perm.txt, 0644 octal) [number]",
        babet.setMode(sb("perm.txt"), tonumber("644", 8)))
    m, e = babet.getMode(sb("perm.txt"))
    ok("getMode reflects setMode(644)", m == tonumber("644", 8) and e == nil,
        "mode=" .. tostring(m))

    -- LOT 4 : setMode acceptait déjà les bits spéciaux, mais getMode
    -- les masquait avec 0777. La lecture doit désormais être symétrique.
    ok_act("LOT 4 setMode(perm.txt, '4755')",
        babet.setMode(sb("perm.txt"), "4755"))
    m, e = babet.getMode(sb("perm.txt"))
    ok("LOT 4 getMode exposes setuid + permissions (04755)",
        m == tonumber("4755", 8) and e == nil,
        "mode=" .. tostring(m))
    local special_attrs, special_attrs_err =
        babet.getAttributes(sb("perm.txt"))
    ok("LOT 5B getAttributes exposes special mode bits (04755)",
        type(special_attrs) == "table"
        and special_attrs.mode == tonumber("4755", 8)
        and special_attrs_err == nil,
        "mode=" .. tostring(special_attrs and special_attrs.mode)
        .. " err=" .. tostring(special_attrs_err))
    ok_act("LOT 4 restore mode 0644",
        babet.setMode(sb("perm.txt"), "644"))

    -- string invalid -> (nil, err) propre
    local r, e2 = babet.setMode(sb("perm.txt"), "858")
    ok_fail("setMode(perm.txt, '858') -> (nil, err)", r, e2)

    -- setAttributes : chown vers son propre uid/gid (toujours autorisé)
    local attrs = babet.getAttributes(sb("perm.txt"))
    if attrs then
        ok_act("setAttributes(perm.txt, self uid/gid)",
            babet.setAttributes(sb("perm.txt"), attrs.owner, attrs.group))
    else
        ok("setAttributes (préparation)", false, "getAttributes a échoué")
    end

    local r2, e3 = babet.setAttributes("/n/existe/pas", 0, 0)
    ok_fail("setAttributes(bad path) -> (nil, err)", r2, e3)

    ;(function()
        local pinned_path = sb("setattr_mode000.txt")
        assert(babet.touch(pinned_path))
        assert(babet.setMode(pinned_path, "000"))
        local pinned_attrs = assert(babet.getAttributes(pinned_path))
        local pinned_ok, pinned_err = babet.setAttributes(
            pinned_path, pinned_attrs.owner, pinned_attrs.group,
            tonumber("640", 8))
        local pinned_mode = babet.getMode(pinned_path)
        ok("setAttributes works on an unreadable mode-000 file",
            pinned_ok == true and pinned_err == nil
            and pinned_mode == tonumber("640", 8))

        local symlink_target = sb("setattr_symlink_target.txt")
        assert(babet.touch(symlink_target))
        babet.exec("ln", { "-s", "setattr_symlink_target.txt",
            sb("setattr_symlink") })
        local target_attrs = assert(babet.getAttributes(symlink_target))
        local symlink_ok, symlink_err = babet.setAttributes(
            sb("setattr_symlink"), target_attrs.owner, target_attrs.group,
            tonumber("600", 8))
        local target_mode = babet.getMode(symlink_target)
        ok("setAttributes preserves its documented symlink-following contract",
            symlink_ok == true and symlink_err == nil
            and target_mode == tonumber("600", 8))

        local long_path = string.rep("longjmp-allocation-", 64)
        local function all_rejected(call)
            for _ = 1, 64 do
                if pcall(call) then
                    return false
                end
            end
            return true
        end
        ok("setAttributes path/owner type errors survive longjmp stress",
            all_rejected(function()
                babet.setAttributes(42, 0, 0)
            end)
            and all_rejected(function()
                babet.setAttributes(long_path, "1000", 0)
            end))
        ok("setAttributes group type errors survive longjmp stress",
            all_rejected(function()
                babet.setAttributes(long_path, 0, "1000")
            end))
        ok("setAttributes mode type errors survive longjmp stress",
            all_rejected(function()
                babet.setAttributes(long_path, 0, 0, "640")
            end))
    end)()

    -- LOT 5B : le mode doit être validé AVANT tout chown/stat utile.
    -- Le chemin inexistant rend le test discriminant : l'ancien code
    -- répondait ENOENT après avoir accepté la valeur hors plage.
    local bad_mode_v, bad_mode_e = babet.setAttributes(
        "/n/existe/pas", 0, 0, tonumber("10000", 8))
    ok_fail("LOT 5B setAttributes rejects mode > 07777",
        bad_mode_v, bad_mode_e)
    ok("  invalid mode detected before touching the path",
        type(bad_mode_e) == "string"
        and bad_mode_e:find("mode", 1, true) ~= nil,
        "err=" .. tostring(bad_mode_e))

    -- symlinkattr on the link created in the filesystem section
    if attrs then
        ok_act("symlinkattr(link.txt, self uid/gid)",
            babet.symlinkattr(sb("link.txt"), attrs.owner, attrs.group))
        ok_act("symlinkAttr (alias camelCase canonique) idem",
            babet.symlinkAttr(sb("link.txt"), attrs.owner, attrs.group))

        ok_raises("LOT 3 setAttributes: NUL path rejected",
            function() return babet.setAttributes(
                sb("perm.txt") .. "\0ignored",
                attrs.owner, attrs.group) end, "NUL")
        ok_raises("LOT 3 symlinkAttr: NUL path rejected",
            function() return babet.symlinkAttr(
                sb("link.txt") .. "\0ignored",
                attrs.owner, attrs.group) end, "NUL")
    end

    local mode_v, mode_e = babet.setMode(sb("perm.txt"), "700\0ignored")
    ok_fail("LOT 3 setMode: NUL in mode string rejected", mode_v, mode_e)
    ok_raises("LOT 3 setMode: NUL path rejected",
        function() return babet.setMode(
            sb("perm.txt") .. "\0ignored", "700") end, "NUL")
end

-- =====================================================================
print("")
print("=== env / cwd (avant le premier worker) ===")
-- Option A validée : setenv et chdir mutent un état PROCESS-WIDE et
-- sont donc interdits dès le premier workers.spawn (le premier de la
-- suite arrive dans la section find, juste en dessous). Les tests de
-- succès vivent donc ICI.
do
    local original_path = babet.env("PATH")
    local name = "BABET_SYS_TEST_VAR"
    local ok_set, err = babet.setenv(name, "hello-42")
    ok_val("setenv('NAME', 'val') -> (true, nil)", ok_set, err)
    ok("  env() reflects setenv",
        babet.env(name) == "hello-42",
        "got=" .. tostring(babet.env(name)))

    babet.setenv(name, "world")
    ok("  setenv overwrite", babet.env(name) == "world")

    local empty_name = "BABET_SYS_EMPTY_VALUE"
    local empty_ok, empty_err = babet.setenv(empty_name, "")
    ok_val("setenv(name, '') defines an empty value", empty_ok, empty_err)
    ok("  env(name) returns '' (not nil)", babet.env(empty_name) == "")

    local v, e = babet.setenv("", "x")
    ok_fail("setenv('', value) -> (nil, err)", v, e)

    v, e = babet.setenv("bad=name", "x")
    ok_fail("setenv('bad=name') -> (nil, err)", v, e)

    v, e = babet.setenv("BABET_BAD\0NAME", "x")
    ok_fail("LOT 3 setenv: NUL in name rejected", v, e)
    v, e = babet.setenv("BABET_BAD_VALUE", "x\0y")
    ok_fail("LOT 3 setenv: NUL in value rejected", v, e)

    local direct_probe = sb("sys_which_probe")
    do
        local f = assert(io.open(direct_probe, "wb"))
        assert(f:write("#!/bin/sh\nexit 0\n"))
        assert(f:close())
    end
    assert(babet.setMode(direct_probe, "644"))
    local probe_path, probe_err = babet.which(direct_probe)
    ok_fail("which(direct non-executable file) -> (nil, err)",
        probe_path, probe_err)
    assert(babet.setMode(direct_probe, "755"))
    probe_path, probe_err = babet.which(direct_probe)
    ok_val("which(direct executable file) -> path", probe_path, probe_err)
    ok("  direct executable path is absolute",
        type(probe_path) == "string" and probe_path:sub(1, 1) == "/",
        tostring(probe_path))

    -- chdir no-op (vers le CWD courant) : succès avant le premier
    -- worker, sans déplacer la suite.
    ok_act("chdir(currentDir()) avant le premier worker",
        babet.chdir(babet.currentDir()))

    -- Aller-retour RÉEL (bloc relocalisé depuis la fin de suite,
    -- lot 17 : chdir est verrouillé après le premier spawn). SB et
    -- startDir sont posés par le setup ; on revient à startDir dans
    -- ce même bloc, rien en aval n'est déplacé.
    local r, e = babet.chdir(SB)
    ok_act("chdir(sandbox)", r, e)

    local cwd = babet.currentDir()
    ok("currentDir() reflects chdir",
        type(cwd) == "string" and cwd:find(SB, 1, true) ~= nil,
        "cwd=" .. tostring(cwd))

    assert(type(original_path) == "string")
    assert(babet.setenv("PATH", ":"))
    local via_empty_path, via_empty_err = babet.which("sys_which_probe")
    ok_val("which respects empty PATH component as current directory",
        via_empty_path, via_empty_err)
    assert(babet.setenv("PATH", original_path))

    r, e = babet.chdir("/n/existe/pas")
    ok_fail("chdir(bad path) -> (nil, err)", r, e)

    ok_raises("LOT 3 chdir: NUL path rejected",
        function() return babet.chdir(startDir .. "\0ignored") end, "NUL")

    -- retour au répertoire de départ
    r, e = babet.chdir(startDir)
    ok_act("chdir(back to startDir)", r, e)
end

end
