return function(test, context)
    local _ENV = test:environment(context)
-- =====================================================================
print("")
print("=== embedded ZIP size limit (lot 3) ===")

do
    -- La construction d'un exécutable n'est disponible qu'en mode dossier.
    -- Le test produit un module Lua de 16 MiB + quelques octets, très
    -- compressible, puis vérifie que le binaire embarqué le refuse avant
    -- toute allocation géante ou compilation Lua.
    if not (arg and arg[-1] ~= nil) then
        print("[INFO] LOT 3 ZIP limit: ignoré en mode embarqué "
            .. "(testé en mode dossier)")
    else
        local function write_text(path, content)
            local f, err = io.open(path, "wb")
            if not f then return nil, err end
            local wrote, write_err = f:write(content)
            local closed, close_err = f:close()
            if not wrote then return nil, write_err end
            if closed == nil then return nil, close_err end
            return true
        end

        local function write_oversized_module(path)
            local f, err = io.open(path, "wb")
            if not f then return nil, err end
            if not f:write("--") then
                f:close()
                return nil, "cannot write module prefix"
            end
            local chunk = string.rep("x", 1024)
            -- 16 MiB + 1 KiB, sans allouer une chaîne de 16 MiB en Lua.
            for _ = 1, 16 * 1024 + 1 do
                local wrote, write_err = f:write(chunk)
                if not wrote then
                    f:close()
                    return nil, write_err
                end
            end
            local wrote, write_err = f:write("\nreturn true\n")
            local closed, close_err = f:close()
            if not wrote then return nil, write_err end
            if closed == nil then return nil, close_err end
            return true
        end

        local function trimmed_stdout(result)
            if type(result) ~= "table" or type(result.stdout) ~= "string" then
                return nil
            end
            return (result.stdout:gsub("%s+$", ""))
        end

        local proc_exe = "/proc/" .. tostring(babet.pid()) .. "/exe"
        local exe_result = babet.exec("readlink", { "-f", proc_exe })
        local current_exe = trimmed_stdout(exe_result)
        local root = sb("lot3_zip_limit")
        local project = root .. "/project"
        local output = root .. "/oversized_app"

        babet.rmdirAll(root)
        babet.mkdir(project)

        local main_ok, main_err = write_text(project .. "/main.lua",
            'local v = require("huge")\nprint(v)\n')
        ok_in("folder", "LOT 3 ZIP limit: main.lua created", main_ok == true, main_err)

        local huge_ok, huge_err = write_oversized_module(project .. "/huge.lua")
        ok_in("folder", "LOT 3 ZIP limit: oversized module created",
            huge_ok == true, huge_err)

        if not current_exe or current_exe == "" then
            ok_in("folder", "LOT 3 ZIP limit: current executable resolved", false,
                "readlink failed")
        else
            local built = babet.exec(current_exe, {
                "--create-exe", project, output,
            }, { timeout = 60 })
            ok_in("folder", "LOT 3 ZIP limit: executable built",
                type(built) == "table" and built.code == 0,
                "code=" .. tostring(built and built.code)
                .. " stderr=" .. tostring(built and built.stderr))

            local launched = babet.exec(output, {}, { timeout = 15 })
            ok_in("folder", "LOT 3 ZIP limit: oversized embedded module rejected",
                type(launched) == "table" and launched.code ~= 0
                and type(launched.stderr) == "string"
                and launched.stderr:find(
                    "exceeds maximum embedded file size of 16 MiB",
                    1, true) ~= nil,
                "code=" .. tostring(launched and launched.code)
                .. " stderr=" .. tostring(launched and launched.stderr))
        end

        babet.rmdirAll(root)
    end
end

-- =====================================================================
-- (Les tests d'aller-retour chdir qui vivaient ici sont relocalisés
-- dans la section « env / cwd (avant le premier worker) » : depuis le
-- lot 17, chdir est verrouillé dès le premier workers.spawn. Les
-- tests d'interdiction post-spawn vivent dans la section workers.)

-- =====================================================================
end
