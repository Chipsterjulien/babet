return function(test, context)
    local _ENV = test:environment(context)
-- =====================================================================
print("")
print("=== arg ===")

do
    ok("arg: global table present", type(arg) == "table")
    ok("arg[0] is a string",
        type(arg) == "table" and type(arg[0]) == "string",
        "arg[0]=" .. tostring(arg and arg[0]))

    if arg and arg[1] == "__ARG__a" then
        -- Invocation via run_tests.sh (sentinelles connues) : on
        -- vérifie la convention complète, de façon déterministe et
        -- identical in the 3 modes (user args fall
        -- always in 1..n, whether the binary is packaged or runner).
        ok("arg[1] == sentinel 1", arg[1] == "__ARG__a")
        ok("arg[2] == sentinel 2", arg[2] == "__ARG__b",
            "arg[2]=" .. tostring(arg[2]))
        ok("arg[3] == nil (nothing past sentinels)",
            arg[3] == nil, "arg[3]=" .. tostring(arg[3]))

        if arg[-1] ~= nil then
            -- Runner de dossier : arg[-1]=binaire babet, arg[0]=<dir>
            ok("folder mode: arg[-1] (binaire) is a string",
                type(arg[-1]) == "string",
                "arg[-1]=" .. tostring(arg[-1]))
            ok("folder mode: arg[0] == '.' (folder launched)",
                arg[0] == ".", "arg[0]=" .. tostring(arg[0]))
        else
            -- Packagé : arg[0]=binaire, no index negative.
            ok("packaged mode: arg[0] (binary) non-empty",
                #arg[0] > 0, "arg[0]=" .. tostring(arg[0]))
            ok("packaged mode: no index -1", arg[-1] == nil)
        end
    else
        -- Run manuel hors run_tests.sh : positions non connues, on
        -- s'en tient aux invariants de structure (already testés ci-dessus).
        print("[INFO] arg: run hors run_tests.sh, "
            .. "vérifications positionnelles ignorées")
    end
end

-- =====================================================================
print("")
print("=== create-exe: publication atomique (lot 1) ===")

do
    -- Un exécutable embarqué transmet volontairement --create-exe à son
    -- propre main.lua au lieu de réactiver le mode constructeur du runtime.
    -- Relancer /proc/self/exe depuis ce mode exécuterait donc récursivement
    -- toute cette suite jusqu'au timeout. Le test de publication atomique
    -- n'a de sens qu'en mode dossier, où arg[-1] désigne le runner Babet.
    if not (arg and arg[-1] ~= nil) then
        print("[INFO] LOT 1 create-exe: ignoré en mode embarqué "
            .. "(testé en mode dossier)")
    else
        local function write_all(path, content)
            local f, err = io.open(path, "wb")
            if not f then return nil, err end
            local wrote, write_err = f:write(content)
            local closed, close_err = f:close()
            if not wrote then return nil, write_err end
            if closed == nil then return nil, close_err end
            return true
        end

        local function read_all(path)
            local f = io.open(path, "rb")
            if not f then return nil end
            local content = f:read("*a")
            f:close()
            return content
        end

        local function trimmed_stdout(result)
            if type(result) ~= "table" or type(result.stdout) ~= "string" then
                return nil
            end
            return (result.stdout:gsub("%s+$", ""))
        end

        -- Attention : `readlink /proc/self/exe` exécuté via babet.exec
        -- désignerait le binaire `readlink` lui-même. On cible explicitement
        -- le PID du processus Babet qui exécute ce main.lua.
        local proc_exe = "/proc/" .. tostring(babet.pid()) .. "/exe"
        local exe_result = babet.exec("readlink", { "-f", proc_exe })
        local current_exe = trimmed_stdout(exe_result)
        if not current_exe or current_exe == "" then
            ok("LOT 1 create-exe: chemin du binaire courant disponible",
                false, "readlink " .. proc_exe .. " a échoué")
        else
            local root = sb("lot1_atomic")
            local project = root .. "/project"
            local output = root .. "/atomic_app"
            local sentinel = "ANCIEN_EXECUTABLE_INTACT\n"

            babet.rmdirAll(root)
            babet.mkdir(project)
            local wrote_main, main_err = write_all(project .. "/main.lua",
                'print("LOT1_ATOMIC_NEW")\n')
            ok("LOT 1 create-exe: projet de test créé",
                wrote_main == true, main_err)
            local wrote_old, old_err = write_all(output, sentinel)
            ok("LOT 1 create-exe: ancien output préparé",
                wrote_old == true, old_err)

            -- RLIMIT_FSIZE limite le fichier à 64 blocs (32 Kio sur Linux).
            -- Le petit ZIP du projet est créé, puis l'écriture du binaire dans
            -- le temporaire de mergeFiles échoue avec EFBIG. SIGXFSZ est ignoré
            -- afin que write(2) rende une erreur capturable au lieu de tuer le
            -- processus avant les destructeurs RAII.
            local force_failure_script =
                'trap "" XFSZ; ulimit -f 64; '
                .. 'exec "$1" --create-exe "$2" "$3"'
            local forced = babet.exec("sh", {
                "-c", force_failure_script, "babet-lot1",
                current_exe, project, output,
            }, { timeout = 30 })

            ok("LOT 1 create-exe: échec d'écriture forcé atteint",
                type(forced) == "table" and forced.code ~= 0
                and type(forced.stderr) == "string"
                and forced.stderr:find(
                    "failed to build executable", 1, true) ~= nil,
                "code=" .. tostring(forced and forced.code)
                .. " stderr=" .. tostring(forced and forced.stderr))
            ok("  ancien output strictement intact après l'échec",
                read_all(output) == sentinel,
                "content=" .. tostring(read_all(output)))

            local find_temp_script =
                'find "$1" -maxdepth 1 -name ".babet-atomic_app.*" -print'
            local leftovers_after_failure = babet.exec("sh", {
                "-c", find_temp_script, "babet-lot1", root,
            }, { timeout = 5 })
            ok("  aucun temporaire partiel après l'échec",
                trimmed_stdout(leftovers_after_failure) == "",
                "files=" .. tostring(trimmed_stdout(leftovers_after_failure)))

            -- Publication réussie : remplace l'ancien output, produit un mode
            -- 0755, exécute le nouveau main.lua et ne laisse aucun temporaire.
            local built = babet.exec(current_exe, {
                "--create-exe", project, output,
            }, { timeout = 30 })
            ok("LOT 1 create-exe: remplacement atomique réussi",
                type(built) == "table" and built.code == 0,
                "code=" .. tostring(built and built.code)
                .. " stderr=" .. tostring(built and built.stderr))

            local mode, mode_err = babet.getMode(output)
            ok("  mode final == 0755",
                mode == tonumber("755", 8) and mode_err == nil,
                "mode=" .. tostring(mode) .. " err=" .. tostring(mode_err))

            local launched = babet.exec(output, {}, { timeout = 10 })
            ok("  nouvel exécutable utilisable",
                type(launched) == "table" and launched.code == 0
                and trimmed_stdout(launched) == "LOT1_ATOMIC_NEW",
                "code=" .. tostring(launched and launched.code)
                .. " stdout=" .. tostring(launched and launched.stdout)
                .. " stderr=" .. tostring(launched and launched.stderr))

            local leftovers_after_success = babet.exec("sh", {
                "-c", find_temp_script, "babet-lot1", root,
            }, { timeout = 5 })
            ok("  aucun temporaire après le succès",
                trimmed_stdout(leftovers_after_success) == "",
                "files=" .. tostring(trimmed_stdout(leftovers_after_success)))

            babet.rmdirAll(root)
        end
    end

end
end
