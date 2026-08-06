return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== exec ===")

do
    -- Documentation lot 3 : contrat précis des signatures. Seul le
    -- premier argument invalide lève ; les erreurs de validation des
    -- arguments/options suivants sont renvoyées sous forme (nil, err).
    ok("DOC 3 exec: missing command raises",
        pcall(function() return babet.exec() end) == false)
    ok("DOC 3 exec: command must be a strict string",
        pcall(function() return babet.exec(42) end) == false)

    ok("LOT 11 exec rejects excess arguments",
        pcall(function()
            return babet.exec("echo", {}, {}, "extra")
        end) == false)

    local bad_args, bad_args_err = babet.exec("echo", "hello")
    ok_fail("DOC 3 exec: args non-table -> (nil, err)",
        bad_args, bad_args_err)

    local bad_arg_value, bad_arg_value_err = babet.exec(
        "echo", { "ok", 42 })
    ok_fail("DOC 3 exec: args elements must be strings",
        bad_arg_value, bad_arg_value_err)

    local sparse_args, sparse_args_err = babet.exec(
        "echo", { [2] = "x" })
    ok_fail("DOC 3 exec: args must be a dense array",
        sparse_args, sparse_args_err)

    local extra_key_args, extra_key_args_err = babet.exec(
        "echo", { "x", metadata = true })
    ok_fail("DOC 3 exec: args reject keys outside the sequence",
        extra_key_args, extra_key_args_err)

    local bad_opts, bad_opts_err = babet.exec("echo", {}, "opts")
    ok_fail("DOC 3 exec: opts non-table -> (nil, err)",
        bad_opts, bad_opts_err)

    local bad_cwd_type, bad_cwd_type_err = babet.exec(
        "echo", {}, { cwd = 42 })
    ok_fail("DOC 3 exec: opts.cwd must be a string",
        bad_cwd_type, bad_cwd_type_err)

    local bad_env_type, bad_env_type_err = babet.exec(
        "echo", {}, { env = "bad" })
    ok_fail("DOC 3 exec: opts.env must be a table",
        bad_env_type, bad_env_type_err)

    local bad_env_value, bad_env_value_err = babet.exec(
        "echo", {}, { env = { BABET_VALUE = 42 } })
    ok_fail("DOC 3 exec: env values must be strings",
        bad_env_value, bad_env_value_err)

    -- commande simple qui succeededt
    local r, e = babet.exec("echo", { "hello" })
    ok("exec('echo hello') -> (table, nil)",
        type(r) == "table" and e == nil,
        "r=" .. tostring(r) .. " e=" .. tostring(e))
    if type(r) == "table" then
        ok("  stdout contains 'hello'",
            type(r.stdout) == "string" and r.stdout:find("hello", 1, true) ~= nil,
            "stdout=" .. tostring(r.stdout))
        ok("  code == 0", r.code == 0, "code=" .. tostring(r.code))
        ok("  stderr empty", r.stderr == "", "stderr=" .. tostring(r.stderr))
    end

    -- code de sortie != 0 : ce n'est PAS une erreur d'exec
    local r2 = babet.exec("sh", { "-c", "exit 3" })
    ok("exec('sh -c \"exit 3\"'): code == 3, no err",
        type(r2) == "table" and r2.code == 3,
        "code=" .. tostring(r2 and r2.code))

    -- stderr captured separately from stdout
    local r3 = babet.exec("sh", { "-c", "echo oops 1>&2" })
    ok("exec: stderr captured separately from stdout",
        type(r3) == "table"
        and r3.stderr:find("oops", 1, true) ~= nil
        and r3.stdout == "",
        "stdout=" .. tostring(r3 and r3.stdout) ..
        " stderr=" .. tostring(r3 and r3.stderr))

    -- binaire introuvable -> (nil, err)
    local r4, e4 = babet.exec("ce_binaire_nexiste_pas_12345")
    ok_fail("exec(nonexistent binary) -> (nil, err)", r4, e4)

    -- option cwd
    local r5 = babet.exec("pwd", {}, { cwd = "/tmp" })
    ok("exec('pwd', cwd=/tmp): stdout contains /tmp",
        type(r5) == "table" and r5.stdout:find("/tmp", 1, true) ~= nil,
        "stdout=" .. tostring(r5 and r5.stdout))

    -- invalid cwd -> (nil, err)
    local r6, e6 = babet.exec("pwd", {}, { cwd = "/n/existe/pas" })
    ok_fail("exec(invalid cwd) -> (nil, err)", r6, e6)

    -- env option (merged with existing environment)
    local r7 = babet.exec("sh", { "-c", "echo $BABET_TEST_VAR" },
        { env = { BABET_TEST_VAR = "ok42" } })
    ok("exec: environment variable transmitted",
        type(r7) == "table" and r7.stdout:find("ok42", 1, true) ~= nil,
        "stdout=" .. tostring(r7 and r7.stdout))

    -- Babet 2.17 : la recherche utilise le PATH de l'environnement final
    -- transmis à l'enfant, et non plus le PATH du processus Babet.
    local exec_path_dir = sb("exec_path")
    assert(babet.mkdir(exec_path_dir))
    local exec_path_tool = exec_path_dir .. "/private-exec-tool"
    local exec_path_file = assert(io.open(exec_path_tool, "w"))
    exec_path_file:write("#!/bin/sh\nprintf exec-path")
    exec_path_file:close()
    assert(babet.setMode(exec_path_tool, "755"))
    local exec_path_result, exec_path_err = babet.exec(
        "private-exec-tool", {}, { env = { PATH = exec_path_dir } })
    ok("exec lookup uses opts.env.PATH",
        type(exec_path_result) == "table" and exec_path_err == nil
        and exec_path_result.stdout == "exec-path"
        and exec_path_result.code == 0, tostring(exec_path_err))

    local exec_cwd_dir = sb("exec_path_cwd")
    assert(babet.mkdir(exec_cwd_dir))
    local exec_cwd_tool = exec_cwd_dir .. "/cwd-exec-tool"
    local exec_cwd_file = assert(io.open(exec_cwd_tool, "w"))
    exec_cwd_file:write("#!/bin/sh\nprintf cwd-path")
    exec_cwd_file:close()
    assert(babet.setMode(exec_cwd_tool, "755"))
    local exec_cwd_result, exec_cwd_err = babet.exec(
        "cwd-exec-tool", {}, {
            cwd = exec_cwd_dir,
            env = { PATH = ":/usr/bin:/bin" },
        })
    ok("exec empty PATH component follows opts.cwd",
        type(exec_cwd_result) == "table" and exec_cwd_err == nil
        and exec_cwd_result.stdout == "cwd-path"
        and exec_cwd_result.code == 0, tostring(exec_cwd_err))

    local exec_relative_bin = exec_cwd_dir .. "/bin"
    assert(babet.mkdir(exec_relative_bin))
    local exec_relative_tool = exec_relative_bin .. "/relative-exec-tool"
    local exec_relative_file = assert(io.open(exec_relative_tool, "w"))
    exec_relative_file:write("#!/bin/sh\nprintf relative-path")
    exec_relative_file:close()
    assert(babet.setMode(exec_relative_tool, "755"))
    local exec_relative_result, exec_relative_err = babet.exec(
        "relative-exec-tool", {}, {
            cwd = exec_cwd_dir,
            env = { PATH = "bin:/usr/bin:/bin" },
        })
    ok("exec relative PATH component follows opts.cwd",
        type(exec_relative_result) == "table" and exec_relative_err == nil
        and exec_relative_result.stdout == "relative-path"
        and exec_relative_result.code == 0, tostring(exec_relative_err))

    local denied_path_dir = sb("exec_path_denied")
    local allowed_path_dir = sb("exec_path_allowed")
    assert(babet.mkdir(denied_path_dir))
    assert(babet.mkdir(allowed_path_dir))
    local denied_tool = denied_path_dir .. "/path-priority-tool"
    local allowed_tool = allowed_path_dir .. "/path-priority-tool"
    assert(write_test_file(denied_tool, "not executable\n"))
    assert(babet.setMode(denied_tool, "644"))
    assert(write_test_file(allowed_tool,
        "#!/bin/sh\nprintf eacces-then-success"))
    assert(babet.setMode(allowed_tool, "755"))
    local priority_result, priority_err = babet.exec(
        "path-priority-tool", {}, {
            env = {
                PATH = denied_path_dir .. ":" .. allowed_path_dir,
            },
        })
    ok("exec skips an EACCES candidate when a later PATH entry works",
        type(priority_result) == "table" and priority_err == nil
        and priority_result.stdout == "eacces-then-success"
        and priority_result.code == 0, tostring(priority_err))
    local denied_result, denied_err = babet.exec(
        "path-priority-tool", {}, { env = { PATH = denied_path_dir } })
    ok_fail("exec reports failure when PATH only contains EACCES",
        denied_result, denied_err)

    local r7_empty = babet.exec("sh", { "-c", [[
        if [ "${BABET_EMPTY+x}" = x ] && [ -z "$BABET_EMPTY" ]; then
            printf empty-but-defined
        fi
    ]] }, { env = { BABET_EMPTY = "" } })
    ok("DOC 3 exec: empty env value stays defined",
        type(r7_empty) == "table"
        and r7_empty.stdout == "empty-but-defined",
        "stdout=" .. tostring(r7_empty and r7_empty.stdout))

    local binary_stdout = babet.exec("sh", { "-c",
        "printf 'a\\000b'" })
    ok("DOC 3 exec: stdout capture is binary-safe",
        type(binary_stdout) == "table"
        and binary_stdout.stdout == "a\0b"
        and #binary_stdout.stdout == 3,
        "len=" .. tostring(binary_stdout and binary_stdout.stdout
            and #binary_stdout.stdout))

    -- grosse sortie : vérifie l'absence de deadlock (drain before waitpid)
    local r8 = babet.exec("sh",
        { "-c", "for i in $(seq 1 50000); do echo line$i; done" })
    ok("exec: large output without deadlock",
        type(r8) == "table" and r8.code == 0 and #r8.stdout > 100000,
        "len=" .. tostring(r8 and r8.stdout and #r8.stdout))

    -- stdin : transmis au process
    local r9 = babet.exec("cat", {}, { stdin = "contenu via stdin" })
    ok("exec('cat', stdin=...): stdout == stdin",
        type(r9) == "table" and r9.stdout == "contenu via stdin",
        "stdout=" .. tostring(r9 and r9.stdout))

    -- stdin consommé par un filtre
    local r10 = babet.exec("grep", { "foo" },
        { stdin = "line1\nfoo bar\nline3\nfoo again\n" })
    ok("exec('grep foo', stdin=...): filters 2 lines",
        type(r10) == "table"
        and select(2, r10.stdout:gsub("\n", "\n")) == 2,
        "stdout=" .. tostring(r10 and r10.stdout))

    -- large stdin: no deadlock (write while reading)
    local big = string.rep("x", 500000)
    local r11 = babet.exec("cat", {}, { stdin = big })
    ok("exec: large stdin without deadlock",
        type(r11) == "table" and #r11.stdout == 500000,
        "len=" .. tostring(r11 and r11.stdout and #r11.stdout))

    -- stdin sent à un process qui ne le reads pas (EPIPE géré, pas de crash)
    local r12 = babet.exec("true", {}, { stdin = "ignoré" })
    ok("exec: stdin to process that ignores it (EPIPE handled)",
        type(r12) == "table" and r12.code == 0,
        "code=" .. tostring(r12 and r12.code))

    -- timeout : un process qui dépasse est arrêté
    local r13 = babet.exec("sleep", { "10" }, { timeout = 0.5 })
    ok("exec('sleep 10', timeout=0.5): timed_out == true",
        type(r13) == "table" and r13.timed_out == true,
        "timed_out=" .. tostring(r13 and r13.timed_out) ..
        " code=" .. tostring(r13 and r13.code))

    -- un process rapide n'est PAS marqué timed_out
    local r14 = babet.exec("echo", { "vite" }, { timeout = 5 })
    ok("exec('echo', timeout=5): timed_out == false",
        type(r14) == "table" and r14.timed_out == false and r14.code == 0,
        "timed_out=" .. tostring(r14 and r14.timed_out))

    -- output produced BEFORE the timeout is correctly retrieved
    local r15 = babet.exec("sh",
        { "-c", "echo avant_timeout; sleep 10" }, { timeout = 0.5 })
    ok("exec: stdout before timeout is preserved",
        type(r15) == "table"
        and r15.timed_out == true
        and r15.stdout:find("avant_timeout", 1, true) ~= nil,
        "stdout=" .. tostring(r15 and r15.stdout))

    -- Régression LOT 5A : le timeout doit continuer à s'appliquer si le
    -- child ferme stdin/stdout/stderr puis reste vivant. Avant le correctif,
    -- la boucle d'I/O se terminait et le waitpid final redevenait bloquant.
    local t_closed_fds = babet.monotonic()
    local r_closed_fds = babet.exec("sh", {
        "-c", "exec 0<&- 1>&- 2>&-; sleep 5",
    }, { timeout = 0.2 })
    local dt_closed_fds = babet.monotonic() - t_closed_fds
    ok("LOT 5A exec: timeout après fermeture précoce des pipes",
        type(r_closed_fds) == "table"
        and r_closed_fds.timed_out == true
        and dt_closed_fds < 3.0,
        "dt=" .. tostring(dt_closed_fds)
        .. " timed_out=" .. tostring(r_closed_fds
            and r_closed_fds.timed_out))

    -- timeout invalid -> (nil, err)
    local r16, e16 = babet.exec("echo", { "x" }, { timeout = -1 })
    ok_fail("exec(negative timeout) -> (nil, err)", r16, e16)

    -- Chantier 10-D : timeout NaN / Inf rejetés
    local r16b, e16b = babet.exec("echo", { "x" }, { timeout = 0 / 0 })
    ok_fail("exec(NaN timeout) -> (nil, err)", r16b, e16b)
    local r16c, e16c = babet.exec("echo", { "x" }, { timeout = math.huge })
    ok_fail("exec(Inf timeout) -> (nil, err)", r16c, e16c)

    local r16d, e16d = babet.exec("echo", { "x" }, { timeout = 1e300 })
    ok_fail("LOT 3 exec: huge finite timeout rejected", r16d, e16d)
    ok("  huge timeout message mentions 'too large'",
        type(e16d) == "string" and e16d:find("too large", 1, true) ~= nil,
        tostring(e16d))

    local nul_cmd, nul_cmd_err = babet.exec("echo\0ignored", { "x" })
    ok_fail("LOT 3 exec: NUL in command rejected", nul_cmd, nul_cmd_err)
    local nul_arg, nul_arg_err = babet.exec("echo", { "x\0ignored" })
    ok_fail("LOT 3 exec: NUL in argument rejected", nul_arg, nul_arg_err)
    local nul_cwd, nul_cwd_err = babet.exec("pwd", {}, { cwd = "/tmp\0ignored" })
    ok_fail("LOT 3 exec: NUL in cwd rejected", nul_cwd, nul_cwd_err)
    local nul_env_key, nul_env_key_err = babet.exec("true", {}, {
        env = { ["BABET_BAD\0KEY"] = "x" },
    })
    ok_fail("LOT 3 exec: NUL in env key rejected",
        nul_env_key, nul_env_key_err)
    local nul_env_val, nul_env_val_err = babet.exec("true", {}, {
        env = { BABET_BAD_VALUE = "x\0ignored" },
    })
    ok_fail("LOT 3 exec: NUL in env value rejected",
        nul_env_val, nul_env_val_err)

    local binary_stdin = "a\0b\0c"
    local binary_echo = babet.exec("cat", {}, { stdin = binary_stdin })
    ok("LOT 3 exec: stdin remains binary-safe",
        type(binary_echo) == "table" and binary_echo.stdout == binary_stdin,
        "len=" .. tostring(binary_echo and binary_echo.stdout
            and #binary_echo.stdout))

    -- Chantier 10-D : opts.env clé invalide rejetée
    local rE1, eE1 = babet.exec("echo", { "x" }, { env = { ["A=B"] = "v" } })
    ok_fail("exec(env key contains '=') -> (nil, err)", rE1, eE1)
    local rE2, eE2 = babet.exec("echo", { "x" }, { env = { [""] = "v" } })
    ok_fail("exec(env empty key) -> (nil, err)", rE2, eE2)

    -- without timeout, the timed_out field exists and is false
    local r17 = babet.exec("echo", { "x" })
    ok("exec no timeout: timed_out == false",
        type(r17) == "table" and r17.timed_out == false,
        "timed_out=" .. tostring(r17 and r17.timed_out))

    -- process killed by signal (the shell SIGKILLs itself)
    -- Convention shell : code de sortie = 128 + numéro du signal
    -- SIGKILL = 9 -> code attendu = 137
    local r_sig = babet.exec("sh", { "-c", "kill -9 $$" })
    ok("exec: process killed by signal -> code = 128 + signal",
        type(r_sig) == "table" and r_sig.code == 137,
        "code=" .. tostring(r_sig and r_sig.code))

    -- max_output : sortie coupée aux PREMIERS octets + flag séparé, le
    -- process est mené à terme (on draine le reste), pas de deadlock.
    local r_mo = babet.exec("sh",
        { "-c", "for i in $(seq 1 100000); do echo AAAAAAAA; done" },
        { max_output = 1024 })
    ok("exec max_output: stdout cut at limit",
        type(r_mo) == "table" and #r_mo.stdout == 1024,
        "len=" .. tostring(r_mo and r_mo.stdout and #r_mo.stdout))
    ok("exec max_output: stdout_truncated == true",
        type(r_mo) == "table" and r_mo.stdout_truncated == true)
    ok("exec max_output: stderr_truncated == false (stderr empty)",
        type(r_mo) == "table" and r_mo.stderr_truncated == false)
    ok("exec max_output: process terminates normally (code 0)",
        type(r_mo) == "table" and r_mo.code == 0,
        "code=" .. tostring(r_mo and r_mo.code))

    -- max_output invalid -> (nil, err)
    local r_mo_bad, e_mo_bad = babet.exec("echo", { "x" },
        { max_output = 0 })
    ok_fail("exec(max_output <= 0) -> (nil, err)", r_mo_bad, e_mo_bad)

    local r_mo_frac, e_mo_frac = babet.exec("echo", { "x" },
        { max_output = 3.7 })
    ok_fail("exec(max_output non-integer) -> (nil, err)", r_mo_frac, e_mo_frac)

    local r_mo_huge, e_mo_huge = babet.exec("echo", { "x" },
        { max_output = 3 * 1024 * 1024 * 1024 })
    ok_fail("exec(max_output > 2 Gio) -> (nil, err)", r_mo_huge, e_mo_huge)

    -- without max_output: truncation flags present and false
    local r_mo_def = babet.exec("echo", { "court" })
    ok("exec without max_output: truncation flags false",
        type(r_mo_def) == "table"
        and r_mo_def.stdout_truncated == false
        and r_mo_def.stderr_truncated == false)

    -- timeout : tout le GROUPE est tué, y compris un petit-enfant en
    -- arrière-plan qui garde le pipe ouvert. Sans groupe de process,
    -- exec resterait bloqué ~30s ; avec, il rend la main vite.
    local t0 = os.time()
    local r_pg = babet.exec("sh",
        { "-c", "sleep 30 & wait" }, { timeout = 0.5 })
    local dt = os.time() - t0
    ok("exec timeout kills the whole group (no grandchild hang)",
        type(r_pg) == "table" and r_pg.timed_out == true and dt < 10,
        "dt=" .. tostring(dt) .. "s timed_out=" ..
        tostring(r_pg and r_pg.timed_out))
end

-- =====================================================================
end
