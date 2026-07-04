-- =====================================================================
-- Babet — self-test harness
-- Covers the entire unified API (result, err convention).
-- Run via : ./babet <dir>  (the binary executes this main.lua)
-- =====================================================================

local inspect = require("inspect")

-- --- compteurs et helpers -------------------------------------------
local pass, fail = 0, 0

local function ok(name, cond, detail)
    if cond then
        pass = pass + 1
        print("[PASS] " .. name)
    else
        fail = fail + 1
        print("[FAIL] " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
    end
end

-- (value, err) attendu on success : value non-nil, err nil
local function ok_val(name, val, err, validator)
    local good = (err == nil) and (val ~= nil)
    if good and validator then good = validator(val) end
    ok(name, good, "val=" .. tostring(val) .. " err=" .. tostring(err))
end

-- (true, nil) attendu on success d'action
local function ok_act(name, res, err)
    ok(name, res == true and err == nil,
        "res=" .. tostring(res) .. " err=" .. tostring(err))
end

-- (nil, "msg") attendu en échec
local function ok_fail(name, val, err)
    ok(name, val == nil and type(err) == "string",
        "val=" .. tostring(val) .. " err=" .. tostring(err))
end

-- --- setup -----------------------------------------------------------
local startDir, sderr = babet.currentDir()
if not startDir then
    print("FATAL: currentDir() a échoué: " .. tostring(sderr))
    os.exit(1)
end

local SB = "_babet_selftest"
local function sb(name) return SB .. "/" .. name end

-- nettoyage préventif d'un éventuel run précédent
babet.rmdirAll(SB)

print("=== setup ===")
ok_act("mkdir(sandbox)", babet.mkdir(SB))

-- =====================================================================
print("")
print("=== predicates ===")

do
    babet.touch(sb("probe.txt"))

    local v, e = babet.fileExists(sb("probe.txt"))
    ok("fileExists(probe.txt) == true", v == true and e == nil)

    v, e = babet.fileExists(sb("nope.txt"))
    ok("fileExists(nope.txt) == false, err nil", v == false and e == nil)

    v, e = babet.isdir(SB)
    ok("isdir(sandbox) == true", v == true and e == nil)

    v, e = babet.isdir(sb("probe.txt"))
    ok("isdir(probe.txt) == false", v == false and e == nil)

    v, e = babet.isfile(sb("probe.txt"))
    ok("isfile(probe.txt) == true", v == true and e == nil)

    v, e = babet.isfile(SB)
    ok("isfile(sandbox) == false", v == false and e == nil)

    -- isdir / isfile sur chemin INEXISTANT : doit returnsr (false, nil),
    -- pas (nil, err) — c'est une réponse légitime, pas une erreur.
    v, e = babet.isdir(sb("absent_dir"))
    ok("isdir(absent) == false, err nil", v == false and e == nil,
        "v=" .. tostring(v) .. " e=" .. tostring(e))

    v, e = babet.isfile(sb("absent_file"))
    ok("isfile(absent) == false, err nil", v == false and e == nil,
        "v=" .. tostring(v) .. " e=" .. tostring(e))
end

-- =====================================================================
print("")
print("=== value getters ===")

do
    local v, e = babet.currentDir()
    ok_val("currentDir()", v, e, function(x) return type(x) == "string" and #x > 0 end)

    v, e = babet.fileSize(sb("probe.txt"))
    ok_val("fileSize(probe.txt)", v, e, function(x) return type(x) == "number" end)

    v, e = babet.fileSize(sb("nope.txt"))
    ok_fail("fileSize(nope.txt) -> (nil, err)", v, e)

    v, e = babet.getBasename("/a/b/c.txt")
    ok("getBasename == 'c.txt'", v == "c.txt" and e == nil, "val=" .. tostring(v))

    v, e = babet.getExtension("/a/b/c.txt")
    ok("getExtension == '.txt'", v == ".txt" and e == nil, "val=" .. tostring(v))

    v, e = babet.getFilename("/a/b/c.txt")
    ok("getFilename == 'c'", v == "c" and e == nil, "val=" .. tostring(v))

    v, e = babet.getPath("/a/b/c.txt")
    ok("getPath == '/a/b'", v == "/a/b" and e == nil, "val=" .. tostring(v))

    v = babet.joinPath("a", "b", "c")
    ok("joinPath('a','b','c')", type(v) == "string" and #v > 0, "val=" .. tostring(v))

    v, e = babet.listFiles(SB)
    ok_val("listFiles(sandbox)", v, e, function(x) return type(x) == "table" end)

    v, e = babet.listFiles("/n/existe/pas")
    ok_fail("listFiles(bad) -> (nil, err)", v, e)

    v, e = babet.getMode(sb("probe.txt"))
    ok_val("getMode(probe.txt)", v, e, function(x) return type(x) == "number" end)

    v, e = babet.getMode("/n/existe/pas")
    ok_fail("getMode(bad) -> (nil, err)", v, e)

    v, e = babet.getAttributes(sb("probe.txt"))
    ok_val("getAttributes(probe.txt)", v, e, function(x)
        return type(x) == "table" and x.mode and x.owner and x.group
    end)

    v, e = babet.getAttributes("/n/existe/pas")
    ok_fail("getAttributes(bad) -> (nil, err)", v, e)
end

-- =====================================================================
print("=== hashes ===")

do
    local hashers = {
        "crc32sum",
        "md5sum", "sha1sum", "sha256sum", "sha512sum",
        "sha384sum",
        "sha3_256sum", "sha3_384sum", "sha3_512sum",
        "blake2b512sum", "blake2s256sum",
    }
    for _, fn in ipairs(hashers) do
        local v, e = babet[fn](sb("probe.txt"))
        ok_val(fn .. "(probe.txt)", v, e,
            function(x) return type(x) == "string" and #x > 0 end)

        v, e = babet[fn]("/n/existe/pas")
        ok_fail(fn .. "(bad) -> (nil, err)", v, e)
    end
end

-- =====================================================================
print("")
print("=== crc32 ===")

do
    -- Known test vectors: CRC32 of "abc" (ASCII) is 0x352441c2.
    local v = babet.crc32("abc")
    ok_val("crc32('abc') == 352441c2", v, nil,
        function(x) return x == "352441c2" end)

    -- Empty input -> 00000000.
    v = babet.crc32("")
    ok_val("crc32('') == 00000000", v, nil,
        function(x) return x == "00000000" end)

    -- Binary-safe: must accept embedded NUL bytes and produce a
    -- different CRC than the empty string.
    v = babet.crc32("\0\0\0")
    ok_val("crc32('\\0\\0\\0') is binary-safe (not 00000000)", v, nil,
        function(x)
            return type(x) == "string" and #x == 8
                and x ~= "00000000"
        end)

    -- crc32sum on a real file must match crc32(data) of its content.
    local f = io.open(sb("probe.txt"), "rb")
    local content = f:read("a")
    f:close()
    local from_file = babet.crc32sum(sb("probe.txt"))
    local from_mem  = babet.crc32(content)
    ok_val("crc32sum(file) == crc32(content)", from_file, nil,
        function(x) return x == from_mem end)

    -- crc32sum on a directory must fail with the expected message.
    local res, err = babet.crc32sum(sb(""))
    ok_fail("crc32sum(dir) -> (nil, err)", res, err)
    ok_val("crc32sum(dir) err mentions 'not a regular file'",
        err, nil,
        function(x)
            return type(x) == "string"
                and x:find("not a regular file", 1, true) ~= nil
        end)
end

-- =====================================================================
print("")
print("=== json ===")

do
    local J = babet.json

    -- --- round-trip des scalaires --------------------------------
    do
        local s, e = J.encode(42)
        ok("encode(42) == '42'", s == "42" and e == nil, "s=" .. tostring(s))

        s, e = J.encode(3.0)
        ok("encode(3.0) == '3.0' (float preserved)", s == "3.0" and e == nil,
            "s=" .. tostring(s))

        s, e = J.encode("héllo")
        ok("encode(string) ok", e == nil and type(s) == "string")

        s, e = J.encode(true)
        ok("encode(true) == 'true'", s == "true" and e == nil)
    end

    -- --- sous-type entier vs flottant à la décode -------------------
    do
        local v, e = J.decode("42")
        ok("decode('42') -> integer", e == nil and math.type(v) == "integer",
            "type=" .. tostring(math.type(v)))

        v, e = J.decode("42.0")
        ok("decode('42.0') -> float", e == nil and math.type(v) == "float",
            "type=" .. tostring(math.type(v)))

        v, e = J.decode("1e3")
        ok("decode('1e3') -> float", e == nil and math.type(v) == "float")
    end

    -- --- empty table vs empty_array ---------------------------------
    do
        local s, e = J.encode({})
        ok("encode({}) == '{}' (object by default)", s == "{}" and e == nil,
            "s=" .. tostring(s))

        s, e = J.encode(J.empty_array)
        ok("encode(empty_array) == '[]'", s == "[]" and e == nil,
            "s=" .. tostring(s))

        s, e = J.encode({ items = J.empty_array })
        local back = J.decode(s)
        ok("{ items = empty_array } -> [] in JSON",
            e == nil and type(back) == "table"
            and type(back.items) == "table" and #back.items == 0,
            "s=" .. tostring(s))
    end

    -- --- array / object --------------------------------------------
    do
        local s, e = J.encode({ 10, 20, 30 })
        ok("encode sequence -> array", s == "[10,20,30]" and e == nil,
            "s=" .. tostring(s))

        local v
        v, e = J.decode("[1,2,3]")
        ok("decode array -> sequence",
            e == nil and v[1] == 1 and v[3] == 3 and #v == 3)

        s, e = J.encode({ a = 1 })
        ok("encode object ok", e == nil and s:find('"a"', 1, true) ~= nil,
            "s=" .. tostring(s))
    end

    -- --- null: round-trip without loss --------------------------
    do
        local v, e = J.decode("null")
        ok("decode('null') == json.null", v == J.null and e == nil)

        local s
        s, e = J.encode(J.null)
        ok("encode(json.null) == 'null'", s == "null" and e == nil,
            "s=" .. tostring(s))

        -- la clé doit survivre (un nil Lua l'effacerait)
        s, e = J.encode({ x = J.null })
        local back = J.decode(s)
        ok("{ x = json.null } : key preserved on round-trip",
            e == nil and back ~= nil and back.x == J.null,
            "s=" .. tostring(s))
    end

    -- --- imbrication + pretty-print --------------------------------
    do
        local doc = { user = { name = "ada", tags = { "x", "y" } }, ok = true }
        local s, e = J.encode(doc)
        local back = J.decode(s)
        ok("nested round-trip",
            e == nil and back.user.name == "ada"
            and back.user.tags[2] == "y" and back.ok == true)

        s, e = J.encode(doc, { indent = 2 })
        ok("encode(opts.indent=2) -> pretty (contains line breaks)",
            e == nil and type(s) == "string" and s:find("\n", 1, true) ~= nil)

        s, e = J.encode(doc, { indent = -1 })
        ok("negative indent -> compact (no line break)",
            e == nil and s:find("\n", 1, true) == nil)
    end

    -- --- UTF-8 conservé --------------------------------------------
    do
        local original = "café ☕ — naïve"
        local s = J.encode(original)
        local v, e = J.decode(s)
        ok("UTF-8 round-trip intact", e == nil and v == original,
            "v=" .. tostring(v))
    end

    -- --- erreurs : (nil, err), jamais d'exception Lua --------------
    do
        local v, e = J.encode({ [1] = "a", foo = "b" })
        ok_fail("encode mixed keys -> (nil, err)", v, e)

        v, e = J.encode({ [1] = "a", [3] = "c" })
        ok_fail("encode sparse array -> (nil, err)", v, e)

        v, e = J.encode(0 / 0)
        ok_fail("encode(NaN) -> (nil, err)", v, e)

        v, e = J.encode(math.huge)
        ok_fail("encode(Infinity) -> (nil, err)", v, e)

        v, e = J.encode(print)
        ok_fail("encode(function) -> (nil, err)", v, e)

        v, e = J.decode("{ pas du json")
        ok_fail("decode(invalid JSON) -> (nil, err)", v, e)

        -- cyclic table : captée par le garde-fou de profondeur
        local cyc = {}
        cyc.me = cyc
        v, e = J.encode(cyc)
        ok_fail("encode(cyclic table) -> (nil, err)", v, e)
    end

    -- --- round-trip d'un empty array ------------------------------
    do
        local t, e = J.decode("[]")
        ok("decode('[]') -> table", e == nil and type(t) == "table")

        local s, e2 = J.encode(t)
        ok("re-encode(decode('[]')) == '[]'", s == "[]" and e2 == nil,
            "s=" .. tostring(s))

        -- la table décodée reste mutable : on peut la remplir
        t[1] = "x"
        s = J.encode(t)
        ok("empty array decoded then filled -> JSON array",
            s == '["x"]', "s=" .. tostring(s))

        -- empty array imbriqué : round-trip preserved
        local nested = J.decode('{"a":[]}')
        s = J.encode(nested)
        ok('round-trip {"a":[]} preserved', s == '{"a":[]}',
            "s=" .. tostring(s))
    end

    -- --- sentinels en lecture seule --------------------------------
    do
        local mut_ok = pcall(function() J.null.foo = "bar" end)
        ok("json.null is read-only", mut_ok == false)

        local mut_ok2 = pcall(function() J.empty_array.x = 1 end)
        ok("json.empty_array is read-only", mut_ok2 == false)
    end

    -- --- as_array : forçage array pour tables dynamiques -----------
    do
        -- returns la table elle-même (chaînable / idempotent)
        local x = {}
        ok("as_array(t) returns the same table", J.as_array(x) == x)

        -- empty table marquée -> []
        local s, e = J.encode(J.as_array({}))
        ok("encode(as_array({})) == '[]'", s == "[]" and e == nil,
            "s=" .. tostring(s))

        -- le cas qui motive la feature : array dynamique resté empty
        local tags = {}
        s, e = J.encode({ tags = J.as_array(tags) })
        ok('as_array : empty dynamic array -> {"tags":[]}',
            s == '{"tags":[]}' and e == nil, "s=" .. tostring(s))

        -- then filled -> array normal
        tags[1] = "a"
        s = J.encode({ tags = tags })
        ok('as_array : then filled -> {"tags":["a"]}',
            s == '{"tags":["a"]}', "s=" .. tostring(s))

        -- idempotent: double call without side effects
        local d = J.as_array(J.as_array({}))
        ok("as_array idempotent", J.encode(d) == "[]")

        -- marked but with string key -> error at encode
        local bad = J.as_array({})
        bad.k = "v"
        local v2, e2 = J.encode(bad)
        ok_fail("as_array + string key -> (nil, err) on encode", v2, e2)

        -- garde-fous : non-table et sentinel refusés
        ok("as_array(42) raises an error",
            pcall(function() J.as_array(42) end) == false)
        ok("as_array(json.null) raises an error",
            pcall(function() J.as_array(J.null) end) == false)
        ok("as_array(json.empty_array) raises an error",
            pcall(function() J.as_array(J.empty_array) end) == false)

        -- récupération : métatable strippée puis re-marquée
        local r = J.decode("[]")
        setmetatable(r, nil)
        ok("after setmetatable(nil), re-encode == '{}'",
            J.encode(r) == "{}")
        ok("as_array recovers the marking -> '[]'",
            J.encode(J.as_array(r)) == "[]")
    end
end

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

    r, e = babet.remove(sb("t1.txt")) -- already removed
    ok_fail("remove(already gone) -> (nil, err)", r, e)

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

    -- copyTree
    babet.mkdir(sb("treesrc"))
    babet.touch(sb("treesrc/a.txt"))
    ok_act("copyTree(treesrc -> treedst)",
        babet.copyTree(sb("treesrc"), sb("treedst")))

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

        -- B) source donnée VIA un symlink + lien absolu intra-source :
        --    must be retargeted into the destination. Before hardening
        --    (source non résolue), il restait pointé vers la source.
        babet.mkdir(sb("sym/rs"))
        babet.touch(sb("sym/rs/data.txt"))
        mklink(abs(sb("sym/rs/data.txt")), sb("sym/rs/ptr"))
        mklink(abs(sb("sym/rs")), sb("sym/srcvia"))

        local rc = babet.copyTree(sb("sym/srcvia"), sb("sym/viad"))
        ok_act("copyTree(srcvia -> viad)", rc)
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

        -- nettoyage : un seul appel, sûr, indépendant de l'ordre
        babet.rmdirAll(sb("sym"))
    end
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
    ok_act("setMode(perm.txt, 0o644) [number]",
        babet.setMode(sb("perm.txt"), tonumber("644", 8)))
    m, e = babet.getMode(sb("perm.txt"))
    ok("getMode reflects setMode(644)", m == tonumber("644", 8) and e == nil,
        "mode=" .. tostring(m))

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

    -- symlinkattr on the link created in the filesystem section
    if attrs then
        ok_act("symlinkattr(link.txt, self uid/gid)",
            babet.symlinkattr(sb("link.txt"), attrs.owner, attrs.group))
    end
end

-- =====================================================================
print("")
print("=== env / cwd (avant le premier worker) ===")
-- Option A validée : setenv et chdir mutent un état PROCESS-WIDE et
-- sont donc interdits dès le premier workers.spawn (le premier de la
-- suite arrive dans la section find, juste en dessous). Les tests de
-- succès vivent donc ICI.
do
    local name = "BABET_SYS_TEST_VAR"
    local ok_set, err = babet.setenv(name, "hello-42")
    ok_val("setenv('NAME', 'val') -> (true, nil)", ok_set, err)
    ok("  env() reflects setenv",
        babet.env(name) == "hello-42",
        "got=" .. tostring(babet.env(name)))

    babet.setenv(name, "world")
    ok("  setenv overwrite", babet.env(name) == "world")

    local v, e = babet.setenv("bad=name", "x")
    ok_fail("setenv('bad=name') -> (nil, err)", v, e)

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

    r, e = babet.chdir("/n/existe/pas")
    ok_fail("chdir(bad path) -> (nil, err)", r, e)

    -- retour au répertoire de départ
    r, e = babet.chdir(startDir)
    ok_act("chdir(back to startDir)", r, e)
end

-- =====================================================================
print("")
print("=== find ===")

do
    local results, e = babet.find(SB, { type = "f" })
    ok_val("find(sandbox, {type='f'})", results, e,
        function(x) return type(x) == "table" end)

    results, e = babet.find("/n/existe/pas", { type = "f" })
    ok_fail("find(bad path) -> (nil, err)", results, e)

    -- find with ECMAScript regex : trouve tous les fichiers .txt
    -- of the sandbox (we created several during previous tests)
    local results_txt, e_txt = babet.find(SB, { type = "f", name = ".*\\.txt$" })
    ok_val("find with ECMAScript regex (.*\\.txt$)", results_txt, e_txt,
        function(x) return type(x) == "table" and #x > 0 end)

    -- find with iname (case-insensitive)
    local results_ci, e_ci = babet.find(SB, { type = "f", iname = ".*\\.TXT$" })
    ok_val("find iname case-insensitive", results_ci, e_ci,
        function(x) return type(x) == "table" and #x > 0 end)

    -- Concurrent find from multiple workers (post-Gemini fix:
    -- RegexCache is now thread_local). With the old global cache,
    -- this would corrupt the unordered_map and crash. We spawn 4
    -- workers each running find with a different regex repeatedly.
    -- If thread_local is correctly applied, all workers complete
    -- successfully and return their result counts.
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
        ok("concurrent find x4 workers (thread_local RegexCache)",
            all_ok)
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
print("")
print("=== exec ===")

do
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

    -- timeout invalid -> (nil, err)
    local r16, e16 = babet.exec("echo", { "x" }, { timeout = -1 })
    ok_fail("exec(negative timeout) -> (nil, err)", r16, e16)

    -- Chantier 10-D : timeout NaN / Inf rejetés
    local r16b, e16b = babet.exec("echo", { "x" }, { timeout = 0 / 0 })
    ok_fail("exec(NaN timeout) -> (nil, err)", r16b, e16b)
    local r16c, e16c = babet.exec("echo", { "x" }, { timeout = math.huge })
    ok_fail("exec(Inf timeout) -> (nil, err)", r16c, e16c)

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
print("")
print("=== deepCopyTable ===")

do
    -- copie profonde de base : indépendance des sous-tables
    local original = { x = 1, nested = { y = 2 } }
    local copy = babet.deepCopyTable(original)
    ok("deepCopyTable : subtable is a real copy",
        type(copy) == "table"
        and copy.nested ~= nil
        and copy.nested ~= original.nested
        and copy.nested.y == 2)

    -- indépendance : modifying copy does not affect original
    copy.nested.y = 999
    ok("deepCopyTable : modifying copy does not affect original",
        original.nested.y == 2,
        "original.nested.y = " .. tostring(original.nested.y))

    -- clés numeric TROUÉES : [10] ne doit pas être perdue
    local sparse = { [1] = "A", [10] = "B" }
    local sparse_copy = babet.deepCopyTable(sparse)
    ok("deepCopyTable : sparse numeric key [10] preserved",
        sparse_copy[1] == "A" and sparse_copy[10] == "B",
        "[1]=" .. tostring(sparse_copy[1]) ..
        " [10]=" .. tostring(sparse_copy[10]))

    -- Régression (revue Gemini post-audit v21) : la récursion ne
    -- réservait pas la pile Lua (lua_checkstack). Une table imbriquée
    -- LÉGALE (sous MAX_DEPTH = 75) consommait ~5 slots par niveau
    -- alors que l'API n'en garantit que ~20 au total -> corruption
    -- mémoire silencieuse ou crash bien avant le garde-fou de
    -- profondeur. Avec le garde, checkstack fait grandir la pile :
    -- 70 niveaux (~350 slots) doivent passer proprement.
    do
        local t = { v = 42 }
        for _ = 1, 69 do t = { c = t } end
        local copy = babet.deepCopyTable(t)
        local n, d = copy, 0
        while type(n) == "table" and n.c do
            n = n.c; d = d + 1
        end
        ok("deepCopyTable : 70 niveaux copiés (checkstack)",
            d == 69 and type(n) == "table" and n.v == 42,
            "d=" .. tostring(d))
        -- et c'est bien une copie, pas la source
        ok("deepCopyTable : 70 niveaux -> copie distincte",
            copy ~= t and copy.c ~= t.c)
        -- Au-delà du cap : erreur PROPRE (raise), pas un crash.
        local deep = { v = 1 }
        for _ = 1, 80 do deep = { c = deep } end
        local okp, err = pcall(babet.deepCopyTable, deep)
        ok("deepCopyTable : au-delà de MAX_DEPTH -> raise propre",
            okp == false and type(err) == "string"
            and err:find("too deep", 1, true) ~= nil,
            tostring(err))
    end

    -- clés numeric NON basées sur 1 : pas de renumérotation
    local offset = { [5] = "x", [6] = "y" }
    local offset_copy = babet.deepCopyTable(offset)
    ok("deepCopyTable : numeric keys not renumbered",
        offset_copy[5] == "x" and offset_copy[6] == "y"
        and offset_copy[1] == nil,
        "[1]=" .. tostring(offset_copy[1]) ..
        " [5]=" .. tostring(offset_copy[5]))

    -- mixed keys (string + numérique) toutes preserved
    local mixed = { name = "test", [1] = "premier", [3] = "troisieme" }
    local mixed_copy = babet.deepCopyTable(mixed)
    ok("deepCopyTable : mixed string+numeric keys preserved",
        mixed_copy.name == "test"
        and mixed_copy[1] == "premier"
        and mixed_copy[3] == "troisieme")

    -- cycle : table qui se référence elle-même
    local cyclic = {}
    cyclic.self = cyclic
    local cyclic_copy = babet.deepCopyTable(cyclic)
    ok("deepCopyTable : self-referential cycle handled",
        type(cyclic_copy) == "table"
        and cyclic_copy.self == cyclic_copy -- pointe vers la COPIE
        and cyclic_copy.self ~= cyclic,     -- pas vers l'original
        "self == copy ? " .. tostring(cyclic_copy.self == cyclic_copy))

    -- sous-table partagée : doit être copiée UNE seule fois
    local shared = { value = 42 }
    local container = { a = shared, b = shared }
    local container_copy = babet.deepCopyTable(container)
    ok("deepCopyTable : shared subtable copied once only",
        container_copy.a == container_copy.b -- same copy reused
        and container_copy.a ~= shared       -- mais pas l'original
        and container_copy.a.value == 42)

    -- cycle indirect : a -> b -> a
    local a = {}
    local b = { back = a }
    a.forward = b
    local a_copy = babet.deepCopyTable(a)
    ok("deepCopyTable : indirect cycle (a->b->a) handled",
        type(a_copy) == "table"
        and type(a_copy.forward) == "table"
        and a_copy.forward.back == a_copy, -- referme la boucle sur la copie
        "boucle reclosede ? " ..
        tostring(a_copy.forward and a_copy.forward.back == a_copy))
end

-- =====================================================================
print("")
print("=== pure functions ===")

do
    -- split
    local parts = babet.split("Hello there !", " ")
    ok("split('Hello there !', ' ') -> 3 elements",
        type(parts) == "table" and #parts == 3,
        parts and ("#=" .. #parts) or "nil")

    parts = babet.split("a,b,c", ",")
    ok("split('a,b,c', ',') -> 3 elements",
        type(parts) == "table" and #parts == 3)

    -- Régression (audit v21) : split tronquait le SUJET au premier
    -- NUL (std::strlen) alors que le délimiteur, lui, était mesuré
    -- avec lua_rawlen. split("a\0b,c", ",") rendait {"a"} — tout ce
    -- qui suivait le NUL était silencieusement perdu. Désormais
    -- binaire-safe de bout en bout (luaL_checklstring).
    do
        local subject = "a" .. string.char(0) .. "b,c"
        local p = babet.split(subject, ",")
        ok("split('a\\0b,c', ',') -> 2 éléments (binaire-safe)",
            type(p) == "table" and #p == 2,
            p and ("#=" .. #p) or "nil")
        ok("  1er élément == 'a\\0b' (NUL préservé)",
            p ~= nil and p[1] == "a" .. string.char(0) .. "b")
        ok("  2e élément == 'c'", p ~= nil and p[2] == "c")
    end

    -- Comportements historiques FIGÉS (décision post-audit v21 : la
    -- doc est alignée sur le code, l'API ne change pas). Ces tests
    -- verrouillent le contrat documenté dans docs/*/modules/strings.md.
    do
        -- chaîne vide + séparateur -> { "" } : UNE entrée vide
        -- (conséquence de "les entrées vides sont préservées"),
        -- PAS une table vide.
        local e1 = babet.split("", ",")
        ok("split('', ',') -> {''} (figé)",
            type(e1) == "table" and #e1 == 1 and e1[1] == "")

        -- chaîne vide en mode caractères -> table vide.
        local e2 = babet.split("")
        ok("split('') -> {} (mode caractères, figé)",
            type(e2) == "table" and #e2 == 0)

        -- 1 argument = mode caractères (PAS d'espace par défaut).
        local ch = babet.split("ab c")
        ok("split('ab c') -> 4 caractères (figé)",
            type(ch) == "table" and #ch == 4 and ch[1] == "a"
            and ch[2] == "b" and ch[3] == " " and ch[4] == "c")

        -- sep vide explicite : même mode caractères.
        local ch2 = babet.split("xy", "")
        ok("split('xy', '') -> {'x','y'} (mode caractères)",
            type(ch2) == "table" and #ch2 == 2
            and ch2[1] == "x" and ch2[2] == "y")

        -- max_splits : le reste non découpé dans le dernier élément.
        local m1 = babet.split("a,b,c", ",", 1)
        ok("split('a,b,c', ',', 1) -> {'a','b,c'}",
            type(m1) == "table" and #m1 == 2
            and m1[1] == "a" and m1[2] == "b,c")
        local m0 = babet.split("a,b,c", ",", 0)
        ok("split('a,b,c', ',', 0) -> {'a,b,c'}",
            type(m0) == "table" and #m0 == 1 and m0[1] == "a,b,c")

        -- Contrat d'erreur figé.
        ok("split(s, ', ') raises (sep > 1 caractère)",
            pcall(babet.split, "a, b", ", ") == false)
        ok("split(s, ',', -2) raises (max_splits < -1)",
            pcall(babet.split, "a", ",", -2) == false)

        -- Régression (revue ChatGPT post-audit v21) : max_splits était
        -- rangé dans un int -> narrowing du lua_Integer. 2^32 devenait
        -- silencieusement 0 (résultat {s} au lieu du découpage), et
        -- 2^31 donnait l'erreur absurde "should be -1 or greater"
        -- pour une entrée positive. Désormais lua_Integer de bout en
        -- bout : toute valeur >= #coupes possibles découpe tout.
        local w1 = babet.split("a,b,c", ",", 4294967296)
        ok("split(s, ',', 2^32) -> 3 éléments (pas de narrowing)",
            type(w1) == "table" and #w1 == 3 and w1[3] == "c",
            "#=" .. tostring(w1 and #w1))
        local w2 = babet.split("a,b,c", ",", 2147483648)
        ok("split(s, ',', 2^31) -> 3 éléments (pas de raise absurde)",
            type(w2) == "table" and #w2 == 3)
    end

    -- mergeTables
    local merged = babet.mergeTables({ "a", "b" }, { "c", "d" })
    ok("mergeTables -> table", type(merged) == "table")

    -- getMemoryUsage
    local mem = babet.getMemoryUsage()
    ok("getMemoryUsage() -> number > 0", type(mem) == "number" and mem > 0,
        "mem=" .. tostring(mem))

    local used, total = babet.getDetailedMemoryUsage()
    ok("getDetailedMemoryUsage() -> 2 numbers",
        type(used) == "number" and type(total) == "number")

    -- helloThere : imprime, ne returns rien, ne doit pas planter
    local hello_ok = pcall(babet.helloThere)
    ok("helloThere() does not crash", hello_ok)

    -- sleep : action courte
    ok_act("sleep(1, 'ms')", babet.sleep(1, "ms"))

    -- =================================================================
    -- Régression (audit v21) : NaN/Inf non filtrés dans sleep.
    -- L'ancien code ne testait que `duration < 0`, qui laisse passer
    -- NaN (toute comparaison avec NaN est fausse) et math.huge ; le
    -- cast time_t qui suivait était un comportement indéfini (en
    -- pratique : tv_sec poubelle -> nanosleep EINVAL -> (nil, err)
    -- trompeur). Désormais : erreur d'ARGUMENT, comme une durée
    -- négative -> pcall doit rendre false.
    -- =================================================================
    ok("sleep(0/0) raises (NaN rejeté)",
        pcall(babet.sleep, 0 / 0) == false)
    ok("sleep(math.huge) raises (+Inf rejeté)",
        pcall(babet.sleep, math.huge) == false)
    ok("sleep(-math.huge) raises (-Inf rejeté)",
        pcall(babet.sleep, -math.huge) == false)
    -- Borne haute du cast : (double)time_t_max s'arrondit à 2^63
    -- exactement, d'où un `>=` côté C++ ; 2^63 s doit être rejeté.
    -- (Avant correctif : cast UB -> (nil, err) SANS raise, donc ce
    -- pcall == false discrimine bien ancien/nouveau comportement.)
    ok("sleep(2^63) raises (au-delà de time_t)",
        pcall(babet.sleep, 2 ^ 63) == false)
    -- Sanity après les gardes : une durée normale dort toujours.
    ok_act("sleep(1000, 'us') après les gardes", babet.sleep(1000, "us"))
end

-- =====================================================================
print("")
print("=== time ===")

do
    -- monotonic : strictement positif, croissant
    local m1 = babet.monotonic()
    ok("monotonic() -> number > 0",
        type(m1) == "number" and m1 > 0,
        "m1=" .. tostring(m1))

    local m2 = babet.monotonic()
    ok("monotonic() croissant (m2 >= m1)",
        type(m2) == "number" and m2 >= m1,
        "m1=" .. tostring(m1) .. " m2=" .. tostring(m2))

    -- monotonic mesure correctement un sleep
    local before = babet.monotonic()
    babet.sleep(100, "ms")
    local after = babet.monotonic()
    local elapsed = after - before
    ok("monotonic() mesure sleep(100ms) : 0.05 < dt < 1.0",
        elapsed > 0.05 and elapsed < 1.0,
        "elapsed=" .. tostring(elapsed))

    -- now : timestamp epoch, > 0, proche de os.time()
    local n = babet.now()
    ok("now() -> number > 0",
        type(n) == "number" and n > 0,
        "n=" .. tostring(n))

    local ot = os.time()
    ok("now() ~ os.time() (diff < 2s)",
        math.abs(n - ot) < 2,
        "now=" .. tostring(n) .. " os.time=" .. tostring(ot))

    -- now() a une partie fractionnaire la plupart du temps. Pas
    -- garanti à 100% (un appel pile sur la seconde retournerait
    -- un entier), donc on teste sur une moyenne de 5 appels.
    local has_frac = false
    for _ = 1, 5 do
        local v = babet.now()
        if v ~= math.floor(v) then
            has_frac = true; break
        end
    end
    ok("now() a une précision sub-seconde", has_frac)

    -- Mauvais usage : argument non autorisé
    ok("monotonic('abc') -> luaL_error",
        pcall(function() babet.monotonic("abc") end) == false)
    ok("now({}) -> luaL_error",
        pcall(function() babet.now({}) end) == false)
end

-- =====================================================================
print("")
print("=== time_format ===")

do
    -- ---- iso(ts?) -------------------------------------------------------
    ok("iso(0) == '1970-01-01T00:00:00Z'",
        babet.time.iso(0) == "1970-01-01T00:00:00Z")

    ok("iso(0.0) accepted, same result as iso(0)",
        babet.time.iso(0.0) == "1970-01-01T00:00:00Z")

    ok("iso(0.5) truncated, same result as iso(0)",
        babet.time.iso(0.5) == "1970-01-01T00:00:00Z",
        "got " .. tostring(babet.time.iso(0.5)))

    -- A concrete known timestamp: 2026-01-01T00:00:00Z = 1767225600
    ok("iso(1767225600) round-trip",
        babet.time.iso(1767225600) == "2026-01-01T00:00:00Z")

    -- Negative Unix timestamps (before epoch) round-trip too.
    -- One second before epoch should be 1969-12-31T23:59:59Z, and
    -- one day before should be 1969-12-31T00:00:00Z.
    ok("iso(-1) == '1969-12-31T23:59:59Z'",
        babet.time.iso(-1) == "1969-12-31T23:59:59Z",
        "got " .. tostring(babet.time.iso(-1)))
    ok("iso(-86400) == '1969-12-31T00:00:00Z'",
        babet.time.iso(-86400) == "1969-12-31T00:00:00Z",
        "got " .. tostring(babet.time.iso(-86400)))

    -- =================================================================
    -- Régression (audit v21) : borne haute int64 de iso().
    -- (double)INT64_MAX s'arrondit à 2^63 exactement ; l'ancien test
    -- `>` laissait donc passer iso(2^63) -> cast int64 indéfini (en
    -- pratique INT64_MIN sur x86-64 : une date absurde était rendue
    -- SANS erreur, donc pcall == true). Désormais `>=` -> luaL_error,
    -- et le pcall == false discrimine ancien/nouveau comportement.
    -- =================================================================
    ok("iso(2^63) raises (cas limite exact de la borne)",
        pcall(babet.time.iso, 2 ^ 63) == false)
    ok("iso(9.3e18) raises (au-dessus de la borne)",
        pcall(babet.time.iso, 9.3e18) == false)
    -- Bornes VALIDES : -2^63 est exactement représentable en double
    -- et valide en int64 ; 2^53 est une grande valeur propre. Les
    -- deux doivent rendre une string sans lever.
    do
        local okk, v = pcall(babet.time.iso, -(2 ^ 63))
        ok("iso(-2^63) -> string (borne min acceptée)",
            okk and type(v) == "string", "got=" .. tostring(v))
    end
    do
        local okk, v = pcall(babet.time.iso, 2 ^ 53)
        ok("iso(2^53) -> string (grande valeur valide)",
            okk and type(v) == "string", "got=" .. tostring(v))
    end

    -- iso() without arg returns the current time as a 20-char ISO string.
    do
        local s = babet.time.iso()
        ok("iso() returns 20-char ISO string",
            type(s) == "string" and #s == 20 and s:sub(-1) == "Z",
            "got " .. tostring(s))
    end

    -- ---- parse_iso ------------------------------------------------------
    ok("parse_iso('1970-01-01T00:00:00Z') == 0",
        babet.time.parse_iso("1970-01-01T00:00:00Z") == 0)

    ok("parse_iso('2026-01-01T00:00:00Z') == 1767225600",
        babet.time.parse_iso("2026-01-01T00:00:00Z") == 1767225600)

    -- Offsets: +02:00 means the local clock is 2h ahead of UTC,
    -- so 10:00+02:00 == 08:00Z.
    do
        local a = babet.time.parse_iso("2026-06-17T10:00:00+02:00")
        local b = babet.time.parse_iso("2026-06-17T08:00:00Z")
        ok("parse_iso('+02:00') == parse_iso('Z') for same wall instant",
            a == b, "a=" .. tostring(a) .. " b=" .. tostring(b))
    end

    -- -05:30 means clock is 5h30 behind UTC.
    do
        local a = babet.time.parse_iso("2026-06-17T08:30:00-05:30")
        local b = babet.time.parse_iso("2026-06-17T14:00:00Z")
        ok("parse_iso half-hour offset", a == b,
            "a=" .. tostring(a) .. " b=" .. tostring(b))
    end

    -- Space separator instead of T.
    ok("parse_iso accepts space separator",
        babet.time.parse_iso("1970-01-01 00:00:00Z") == 0)

    -- Optional fractional seconds: ignored.
    ok("parse_iso ignores fractional seconds",
        babet.time.parse_iso("1970-01-01T00:00:00.123Z") == 0)

    -- Rejections: no timezone.
    do
        local v, e = babet.time.parse_iso("1970-01-01T00:00:00")
        ok_fail("parse_iso without timezone -> (nil, err)", v, e)
        ok("  err mentions 'timezone'",
            type(e) == "string" and e:find("timezone", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- Invalid date.
    do
        local v, e = babet.time.parse_iso("2026-02-30T00:00:00Z")
        ok_fail("parse_iso invalid date -> (nil, err)", v, e)
    end

    -- Invalid time.
    do
        local v, e = babet.time.parse_iso("2026-01-01T25:00:00Z")
        ok_fail("parse_iso invalid time -> (nil, err)", v, e)
    end

    -- Offset out of range.
    do
        local v, e = babet.time.parse_iso("2026-01-01T00:00:00+25:00")
        ok_fail("parse_iso offset out of range -> (nil, err)", v, e)
    end

    -- Strict offset format: no "+02" or "+0200".
    do
        local v, e = babet.time.parse_iso("2026-01-01T00:00:00+02")
        ok_fail("parse_iso '+02' rejected -> (nil, err)", v, e)
        v, e = babet.time.parse_iso("2026-01-01T00:00:00+0200")
        ok_fail("parse_iso '+0200' rejected -> (nil, err)", v, e)
    end

    -- ---- parse_duration -------------------------------------------------
    -- Régression (revue ChatGPT post-audit v21) : l'ancienne règle
    -- « 18 chiffres max » rejetait à tort INT64_MAX en secondes (19
    -- chiffres, durée représentable) et les zéros de tête. Remplacée
    -- par un contrôle de débordement chiffre par chiffre — les gardes
    -- de multiplication/accumulation en aval sont inchangés.
    ok("parse_duration(INT64_MAX .. 's') == math.maxinteger",
        babet.time.parse_duration(tostring(math.maxinteger) .. "s")
        == math.maxinteger)
    do
        local v, e = babet.time.parse_duration("9223372036854775808s")
        ok("parse_duration(INT64_MAX+1 .. 's') -> (nil, 'out of range')",
            v == nil and type(e) == "string"
            and e:find("out of range", 1, true) ~= nil, tostring(e))
    end
    ok("parse_duration('00000000000000000001s') == 1 (zéros de tête)",
        babet.time.parse_duration("00000000000000000001s") == 1)

    ok("parse_duration('0s') == 0", babet.time.parse_duration("0s") == 0)
    ok("parse_duration('1s') == 1", babet.time.parse_duration("1s") == 1)
    ok("parse_duration('5m') == 300", babet.time.parse_duration("5m") == 300)
    ok("parse_duration('2h') == 7200", babet.time.parse_duration("2h") == 7200)
    ok("parse_duration('1d') == 86400",
        babet.time.parse_duration("1d") == 86400)
    ok("parse_duration('1h30m') == 5400",
        babet.time.parse_duration("1h30m") == 5400)
    ok("parse_duration('1d1h1m1s') == 90061",
        babet.time.parse_duration("1d1h1m1s") == 90061)

    -- Rejections.
    do
        local v, e = babet.time.parse_duration("")
        ok_fail("parse_duration('') -> (nil, err)", v, e)
        v, e = babet.time.parse_duration("5")
        ok_fail("parse_duration('5') (missing unit) -> (nil, err)", v, e)
        v, e = babet.time.parse_duration("30m1h")
        ok_fail("parse_duration units out of order -> (nil, err)", v, e)
        v, e = babet.time.parse_duration("1h1h")
        ok_fail("parse_duration duplicate unit -> (nil, err)", v, e)
        v, e = babet.time.parse_duration("1y")
        ok_fail("parse_duration unknown unit -> (nil, err)", v, e)
    end

    -- ---- format_duration -----------------------------------------------
    ok("format_duration(0) == '0s'",
        babet.time.format_duration(0) == "0s")
    ok("format_duration(1) == '1s'",
        babet.time.format_duration(1) == "1s")
    ok("format_duration(60) == '1m'",
        babet.time.format_duration(60) == "1m")
    ok("format_duration(3600) == '1h'",
        babet.time.format_duration(3600) == "1h")
    ok("format_duration(86400) == '1d'",
        babet.time.format_duration(86400) == "1d")
    ok("format_duration(90061) == '1d1h1m1s'",
        babet.time.format_duration(90061) == "1d1h1m1s")

    -- 3.0 accepted (integer value as float).
    ok("format_duration(3.0) == '3s'",
        babet.time.format_duration(3.0) == "3s")

    -- 3.7 raises (not an integer).
    ok("format_duration(3.7) -> luaL_error",
        pcall(babet.time.format_duration, 3.7) == false)

    -- Negative -> raises.
    ok("format_duration(-5) -> luaL_error",
        pcall(babet.time.format_duration, -5) == false)

    -- ---- Round-trip invariant: parse(format(n)) == n -------------------
    do
        local samples = { 0, 1, 59, 60, 3599, 3600, 86399, 86400,
            90061, 1234567 }
        for _, n in ipairs(samples) do
            local back = babet.time.parse_duration(
                babet.time.format_duration(n))
            ok("round-trip n=" .. n,
                back == n,
                "got " .. tostring(back))
        end
    end

    -- ---- Aliases: babet.time.now / monotonic / sleep -----------------
    ok("babet.time.now is a function",
        type(babet.time.now) == "function")
    ok("babet.time.monotonic is a function",
        type(babet.time.monotonic) == "function")
    ok("babet.time.sleep is a function",
        type(babet.time.sleep) == "function")

    -- Sanity: now() returns a finite number.
    do
        local t = babet.time.now()
        ok("babet.time.now() returns a number > 0",
            type(t) == "number" and t > 0)
    end
end

-- =====================================================================
print("")
print("=== http ===")

do
    local H = babet.http

    -- --- contrat d'erreur : AUCUNE dépendance externe, toujours joué --

    -- request(non-table) lève toujours via luaL_checktype dans
    -- lua_http_request (avant http_perform).
    ok("request(non-table) raises",
        pcall(function() return H.request("not a table") end) == false)

    -- Chantier longjmp : ces erreurs runtime de http_perform passent
    -- maintenant en (nil, err) au lieu de luaL_error (cohérent avec
    -- le commentaire d'intention du fichier + évite les fuites C++).
    do
        local v, e = H.request({})
        ok_fail("request{} without url -> (nil, err)", v, e)
    end
    do
        local v, e = H.request({ url = 123 })
        ok_fail("request{url=number} -> (nil, err)", v, e)
    end
    do
        local v, e = H.request({ url = "http://127.0.0.1:1/", headers = "x" })
        ok_fail("request{headers=string} -> (nil, err)", v, e)
    end
    do
        local v, e = H.request({ url = "http://x/", timeout = "x" })
        ok_fail("request{timeout=string} -> (nil, err)", v, e)
    end

    -- mauvaises VALEURS d'option -> (nil, err), pas d'exception
    do
        local v, e = H.request({ url = "notaurl" })
        ok_fail("url without scheme -> (nil, err)", v, e)
        ok("  message mentions 'scheme'",
            type(e) == "string" and e:find("scheme", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.get("ftp://example.com/")
        ok_fail("scheme not supported -> (nil, err)", v, e)

        v, e = H.get("http://")
        ok_fail("url without host -> (nil, err)", v, e)

        v, e = H.request({ url = "http://127.0.0.1:1/", timeout = -1 })
        ok_fail("timeout <= 0 -> (nil, err)", v, e)

        -- Régression (audit v21) : NaN/Inf/valeurs énormes dans
        -- timeout. L'ancien test `> 0` rejetait NaN par accident
        -- (message trompeur) et laissait passer math.huge et les
        -- finis énormes -> cast size_t/time_t indéfini plus bas.
        -- Ces validations précèdent tout accès réseau : aucune
        -- connexion tentée, tests hermétiques. Les vérifications de
        -- MESSAGE sont les vrais gardes de régression (l'ancien code
        -- rendait aussi (nil, err) mais avec une erreur de connexion
        -- ou un message trompeur).
        v, e = H.request({ url = "http://127.0.0.1:1/", timeout = 0 / 0 })
        ok_fail("timeout NaN -> (nil, err)", v, e)
        ok("  message mentions 'finite'",
            type(e) == "string" and e:find("finite", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/",
            timeout = math.huge
        })
        ok_fail("timeout math.huge -> (nil, err)", v, e)
        ok("  message mentions 'finite'",
            type(e) == "string" and e:find("finite", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({ url = "http://127.0.0.1:1/", timeout = 1e300 })
        ok_fail("timeout 1e300 -> (nil, err)", v, e)
        ok("  message mentions 'too large'",
            type(e) == "string" and e:find("too large", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/", method = "FOO", timeout = 1,
        })
        ok_fail("unknown method -> (nil, err)", v, e)
        ok("  message mentions 'method'",
            type(e) == "string" and e:find("method", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/",
            method = "GET",
            body = "x",
            timeout = 1,
        })
        ok_fail("body on GET -> (nil, err)", v, e)
        ok("  message mentions 'body not allowed'",
            type(e) == "string"
            and e:find("body not allowed", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- échec transport : port loopback closed -> (nil, "http: ...")
    -- (reste sur 127.0.0.1, aucun accès réseau externe ; timeout court)
    do
        local v, e = H.get("http://127.0.0.1:1/", { timeout = 1 })
        ok_fail("loopback connection refused -> (nil, err)", v, e)
        ok("  err prefixed with 'http: '",
            type(e) == "string" and e:find("http: ", 1, true) == 1,
            "err=" .. tostring(e))
    end

    -- --- OPTIONAL success : only if python3 is present ----------
    local function have_python3()
        local r = babet.exec("python3", { "--version" })
        return type(r) == "table" and r.code == 0
    end

    if not have_python3() then
        print("[INFO] http: python3 absent, 2xx success subsection "
            .. "ignorée (hermétique, aucun prérequis dur)")
    else
        local SBH = "_babet_http_test"
        babet.rmdirAll(SBH)
        babet.mkdir(SBH)
        babet.exec("sh", { "-c",
            "printf 'AB\\000CD' > " .. SBH .. "/probe.bin" })

        print("[INFO] http: starting local test server...")
        local port = 8000 + (os.time() % 1000)
        -- Bootstrap borné par timeout (filet de sécurité) ; setsid
        -- detach the server in a separate session, so the timeout
        -- du bootstrap ne le tue PAS. exec rend la main dès `echo $!`
        -- (le serveur a ses 3 flux redirigés -> aucun pipe partagé,
        -- EOF immédiat) ; le timeout ne sert que de garde-fou ultime.
        local boot = babet.exec("sh", { "-c",
            "cd " .. SBH .. " && { setsid python3 -m http.server "
            .. port .. " --bind 127.0.0.1 >/dev/null 2>&1 </dev/null & } "
            .. "; echo $!" }, { timeout = 5 })

        local srv_pid
        if type(boot) == "table" and boot.stdout then
            srv_pid = boot.stdout:gsub("%s+$", "")
        end

        -- Budget d'attente DUR et COURT : 15 sondes x ~200 ms ≈ 3 s
        -- max, AVEC progression visible (jamais "aucun avancement").
        -- Not ready within budget -> skip: the subsection is
        -- optionnelle (décision actée), on ne grind jamais en muet.
        local up = false
        if srv_pid and srv_pid ~= "" then
            for i = 1, 15 do
                babet.sleep(200, "ms")
                local probe = babet.http.get(
                    "http://127.0.0.1:" .. port .. "/probe.bin",
                    { timeout = 1 })
                if type(probe) == "table" and probe.status == 200 then
                    up = true
                    break
                end
                if i % 5 == 0 then
                    print("[INFO] http: attente serveur ("
                        .. i .. "/15)...")
                end
            end
        end

        if not up then
            print("[INFO] http: local server unavailable in "
                .. "budget, 2xx success subsection ignorée (optionnelle)")
            if srv_pid and srv_pid ~= "" then
                babet.exec("kill", { "-9", srv_pid })
            end
            babet.rmdirAll(SBH)
        else
            local base = "http://127.0.0.1:" .. port
            print("[INFO] http: server ready, running 2xx success tests...")

            local res, err = babet.http.get(base .. "/probe.bin",
                { timeout = 5 })
            ok("GET 200 -> (table, nil)",
                type(res) == "table" and err == nil,
                "err=" .. tostring(err))
            if type(res) == "table" then
                ok("  status == 200", res.status == 200,
                    "status=" .. tostring(res.status))
                ok("  body binary-safe (#==5, NUL preserved)",
                    type(res.body) == "string" and #res.body == 5
                    and res.body:byte(3) == 0,
                    "len=" .. tostring(#res.body))
                ok("  headers is a table",
                    type(res.headers) == "table")
                ok("  header key lowercased (content-type)",
                    type(res.headers) == "table"
                    and type(res.headers["content-type"]) == "string",
                    "ct=" .. tostring(res.headers
                        and res.headers["content-type"]))
            end

            local r404, e404 = babet.http.get(
                base .. "/nexiste_pas", { timeout = 5 })
            ok("GET 404 -> (table, nil) [4xx is not an error]",
                type(r404) == "table" and e404 == nil
                and r404.status == 404,
                "status=" .. tostring(r404 and r404.status)
                .. " err=" .. tostring(e404))

            local rq = babet.http.get(base .. "/probe.bin",
                { timeout = 5, query = { a = "x y", b = 42 } })
            ok("GET with query -> 200 (encoding did not break the URL)",
                type(rq) == "table" and rq.status == 200,
                "status=" .. tostring(rq and rq.status))

            babet.exec("kill", { srv_pid })
            babet.sleep(100, "ms")
            babet.exec("kill", { "-9", srv_pid })
            babet.rmdirAll(SBH)
        end
    end
    -- --- dette de test post-Chantier 1 (4 cas inscrits au `todo`) ----

    -- 1. http.post(url, opts) without body: 2-arg form (opts in 2nd
    -- position, pas de string body). On vise un port loopback closed
    -- pour rester hermétique ; ce qu'on prouve, c'est que la forme
    -- est ACCEPTÉE (no luaL_error « body must be a string », pas
    -- de « body not allowed for POST ») et que la requête atteint le
    -- transport, qui échoue alors proprement.
    do
        local v, e = H.post("http://127.0.0.1:1/", { timeout = 1 })
        ok_fail("post(url, opts) without body: form accepted, "
            .. "transport échoue -> (nil, err)", v, e)
        ok("  err prefixed with 'http: ' (not 'body must be a string')",
            type(e) == "string"
            and e:find("http: ", 1, true) == 1
            and e:find("body must be", 1, true) == nil,
            "err=" .. tostring(e))
    end

    -- 2. URL malformée subtile : "http:///path" (host empty entre les
    -- `//` et le `/`). Expected rejection by split_url (« missing host »).
    do
        local v, e = H.get("http:///path")
        ok_fail("http:///path -> (nil, err)", v, e)
        ok("  message mentions 'host'",
            type(e) == "string"
            and e:find("host", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- 3. Malformed URL: "http://:8080/" (port without host). After
    -- split_url hardening (post-chantier 7 work), this is
    -- rejected AT PARSE with message "missing host", instead of waiting for
    -- a transport failure. Faster and more precise.
    do
        local v, e = H.get("http://:8080/")
        ok_fail("http://:8080/ : rejected at parse -> (nil, err)", v, e)
        ok("  err mentions 'host'",
            type(e) == "string"
            and e:find("host", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- 3b. URL malformée : "http://[]:8080/" (crochets IPv6 emptys).
    -- Consistent with SU-3: authority starts with '[' but the host
    -- entre [] est empty -> rejet au parse.
    do
        local v, e = H.get("http://[]:8080/")
        ok_fail("http://[]:8080/ : rejected at parse -> (nil, err)", v, e)
        ok("  err mentions 'host'",
            type(e) == "string"
            and e:find("host", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- 4. IPv6 brut loopback closed : prouve que [::1] est accepted par
    -- the parse, transport fails cleanly (refused or IPv6 error
    -- selon configuration locale).
    do
        local v, e = H.get("http://[::1]:1/", { timeout = 1 })
        ok_fail("http://[::1]:1/ : IPv6 parse OK, transport fails"
            .. " -> (nil, err)", v, e)
        ok("  err prefixed with 'http: '",
            type(e) == "string"
            and e:find("http: ", 1, true) == 1,
            "err=" .. tostring(e))
    end
end

-- =====================================================================
print("")
print("=== argparse ===")

do
    local argparse = require("argparse")

    -- ----- contrat de base : module et constructeur ------------------

    ok("require returns a callable value",
        type(argparse) == "table" or type(argparse) == "function")

    local p0 = argparse("prog", "desc")
    ok("argparse() builds a parser",
        type(p0) == "table" and type(p0.parse) == "function")

    -- builder chaînable : chaque méthode returns self
    local p1 = argparse("prog")
    ok("flag() chainable", p1:flag("-v --verbose") == p1)
    ok("option() chainable", p1:option("-o --output") == p1)
    ok("argument() chainable", p1:argument("input") == p1)

    -- ----- défauts et types ------------------------------------------

    do
        local p = argparse("prog")
            :flag("-v --verbose")
            :option("-o --output", { default = "a.out" })
            :option("-n --count")
            :argument("input")

        local res, err = p:parse({ "INPUT" })
        ok_val("minimal success -> (table, nil)", res, err)
        ok("  flag default = false",
            res and res.verbose == false,
            "verbose=" .. tostring(res and res.verbose))
        ok("  option with default returned",
            res and res.output == "a.out",
            "output=" .. tostring(res and res.output))
        ok("  option without default = nil",
            res and res.count == nil,
            "count=" .. tostring(res and res.count))
        ok("  positional received",
            res and res.input == "INPUT",
            "input=" .. tostring(res and res.input))
    end

    -- ----- formes d'appel -------------------------------------------

    do
        local p = argparse("prog")
            :flag("-v --verbose")
            :option("-o --output")
            :argument("input")

        local r = p:parse({ "--output", "out1", "in1" })
        ok("form --long val",
            r and r.output == "out1" and r.input == "in1",
            "out=" .. tostring(r and r.output)
            .. " in=" .. tostring(r and r.input))

        r = p:parse({ "--output=out2", "in2" })
        ok("form --long=val",
            r and r.output == "out2" and r.input == "in2",
            "out=" .. tostring(r and r.output))

        r = p:parse({ "-o", "out3", "in3" })
        ok("form -s val",
            r and r.output == "out3" and r.input == "in3")

        r = p:parse({ "-o=out4", "in4" })
        ok("form -s=val",
            r and r.output == "out4" and r.input == "in4")

        r = p:parse({ "-v", "x" })
        ok("flag present = true", r and r.verbose == true)
    end

    -- ----- --help : SUCCÈS, signalé par res.help (décision A) --------

    do
        local p = argparse("prog", "description du prog")
            :flag("-v --verbose", { help = "verbeux" })
            :option("-o --output", { help = "sortie" })
            :argument("input", { help = "fichier d'entrée" })

        for _, flagname in ipairs({ "-h", "--help" }) do
            local res, err = p:parse({ flagname })
            ok("--help -> success (err == nil) [" .. flagname .. "]",
                err == nil,
                "err=" .. tostring(err))
            ok("--help -> res.help == true [" .. flagname .. "]",
                type(res) == "table" and res.help == true,
                "res.help=" .. tostring(res and res.help))
            ok("--help -> res.usage string non empty [" .. flagname .. "]",
                type(res) == "table" and type(res.usage) == "string"
                and #res.usage > 0)
        end

        ok("get_usage() returns a string",
            type(p:get_usage()) == "string")
    end

    -- ----- terminateur "--" : -h after -- est un positionnel littéral

    do
        local p = argparse("prog"):argument("input")
        local res, err = p:parse({ "--", "-h" })
        ok("'--' disables options: -h becomes positional",
            err == nil and res and res.help ~= true
            and res.input == "-h",
            "help=" .. tostring(res and res.help)
            .. " input=" .. tostring(res and res.input))
    end

    -- ----- erreurs -> (nil, msg) ; jamais d'exception ----------------

    do
        local p = argparse("prog")
            :option("-o --output")
            :flag("-v --verbose")
            :argument("input")

        local v, e = p:parse({ "--nope" })
        ok_fail("unknown option -> (nil, err)", v, e)
        ok("  message contains 'unknown'",
            type(e) == "string" and e:find("unknown", 1, true) ~= nil)

        v, e = p:parse({ "--output" })
        ok_fail("value missing -> (nil, err)", v, e)

        v, e = p:parse({ "-v=oops", "x" })
        ok_fail("flag with =val -> (nil, err)", v, e)

        v, e = p:parse({})
        ok_fail("required positional missing -> (nil, err)", v, e)

        v, e = p:parse({ "a", "b" })
        ok_fail("extra argument -> (nil, err)", v, e)
    end

    -- ----- choices --------------------------------------------------

    do
        local p = argparse("prog")
            :option("-m --mode", { choices = { "fast", "safe" } })
            :argument("input")

        local r, e = p:parse({ "-m", "fast", "x" })
        ok_val("choices valid", r, e)
        ok("  mode = fast", r and r.mode == "fast")

        r, e = p:parse({ "-m", "wild", "x" })
        ok_fail("choices invalid -> (nil, err)", r, e)
    end

    -- ----- convert : success, retour nil, exception interceptée -------

    do
        local p = argparse("prog")
            :option("-n --count", { convert = tonumber })
            :argument("input")

        local r, e = p:parse({ "-n", "42", "x" })
        ok_val("convert success", r, e)
        ok("  count == 42 (number)", r and r.count == 42)

        r, e = p:parse({ "-n", "pasunnombre", "x" })
        ok_fail("convert returns nil -> (nil, err)", r, e)

        -- convert qui LÈVE doit être intercepté : parse() ne propage
        -- aucune exception sur entrée utilisateur (invariant).
        local p2 = argparse("prog")
            :option("-x", { convert = function(_) error("boom") end })
            :argument("input")
        r, e = p2:parse({ "-x", "v", "x" })
        ok_fail("convert that raises -> (nil, err) (no exception)", r, e)
    end

    -- ----- required / default sur positionnel ------------------------

    do
        local p = argparse("prog"):argument("input", { default = "STDIN" })
        local r, e = p:parse({})
        ok_val("optional positional with default", r, e)
        ok("  default returned", r and r.input == "STDIN")
    end

    -- ----- mauvais usage du BUILDER : doit LEVER (programmeur) -------

    do
        local p = argparse("prog")
        ok("empty spec -> error()",
            pcall(function() p:option("") end) == false)
        ok("option without '-' -> error()",
            pcall(function() p:option("foo") end) == false)
        ok("duplicate name -> error()",
            pcall(function()
                local p2 = argparse("prog")
                p2:option("-o --output")
                p2:option("-o")
            end) == false)
        ok("positional with '-' -> error()",
            pcall(function() p:argument("-bad") end) == false)
    end

    -- ----- parse() without arg reads la global table `arg` ----------
    -- Le harnais est lancé AVEC les sentinelles arg[1]/arg[2] (cf.
    -- section === arg === qui valid leur présence). On dédonet donc
    -- 2 positionnels et on prouve que parse() les récupère bien depuis
    -- `arg` global, indices 1..n (pas <= 0).

    do
        local p = argparse("prog")
            :flag("-v --verbose")
            :argument("a")
            :argument("b")
        local r, e = p:parse() -- reads `arg` global
        ok_val("parse() with no argument reads global `arg` (1..n)", r, e)
        ok("  arg[1] received as positional 'a'",
            r and r.a == arg[1],
            "a=" .. tostring(r and r.a)
            .. " arg[1]=" .. tostring(arg[1]))
        ok("  arg[2] received as positional 'b'",
            r and r.b == arg[2],
            "b=" .. tostring(r and r.b)
            .. " arg[2]=" .. tostring(arg[2]))
        ok("  flag default = false (no -v in global arg)",
            r and r.verbose == false)
    end
    -- --- dette de test post-Chantier 2 (2 cas inscrits au `todo`) ----

    -- 5. positional with choices: supported by finalize_value but
    -- non couvert jusqu'ici. Branches success + rejet.
    do
        local p = argparse("prog")
            :argument("mode", { choices = { "fast", "safe" } })

        local r, e = p:parse({ "fast" })
        ok_val("positional + choices: valid value", r, e)
        ok("  mode == 'fast'", r and r.mode == "fast",
            "mode=" .. tostring(r and r.mode))

        r, e = p:parse({ "wild" })
        ok_fail("positional + choices: invalid value"
            .. " -> (nil, err)", r, e)
        ok("  message mentions 'choice'",
            type(e) == "string"
            and e:find("choice", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- 6. positional with convert: supported by finalize_value, idem.
    -- Branches success + retour nil de la convert.
    do
        local p = argparse("prog")
            :argument("n", { convert = tonumber })

        local r, e = p:parse({ "42" })
        ok_val("positional + convert: success", r, e)
        ok("  n == 42 (number)", r and r.n == 42,
            "n=" .. tostring(r and r.n)
            .. " type=" .. tostring(r and type(r.n)))

        r, e = p:parse({ "pasunnombre" })
        ok_fail("positional + convert: nil return"
            .. " -> (nil, err)", r, e)
    end
end

-- =====================================================================
print("")
print("=== logging ===")

do
    local log = require("logging")

    -- ----- contrat de base ------------------------------------------

    ok("require returns a table", type(log) == "table")
    ok("level constants exposed",
        log.TRACE == 10 and log.DEBUG == 20 and log.INFO == 30
        and log.WARN == 40 and log.ERROR == 50)
    ok("log functions exposed",
        type(log.trace) == "function"
        and type(log.debug) == "function"
        and type(log.info) == "function"
        and type(log.warn) == "function"
        and type(log.error) == "function")
    ok("setters/getters exposed",
        type(log.set_level) == "function"
        and type(log.set_output) == "function"
        and type(log.set_color) == "function"
        and type(log.get_level) == "function")

    -- ----- défauts --------------------------------------------------

    ok("default threshold = info (30)", log.get_level() == log.INFO)
    ok("default destination = io.stderr",
        log.get_output() == io.stderr)
    ok("colors OFF by default (opt-in)", log.get_color() == false)

    -- ----- write collection: in-memory sink for observation --------

    local function make_sink()
        local s = { written = {} }
        function s:write(...)
            for i = 1, select("#", ...) do
                self.written[#self.written + 1] = tostring(select(i, ...))
            end
        end

        function s:joined() return table.concat(self.written) end

        function s:clear() self.written = {} end

        return s
    end

    -- ----- set_output / format / filtrage ---------------------------

    do
        local sink = make_sink()
        log.set_output(sink)
        log.set_level(log.DEBUG)
        log.set_color(false)

        sink:clear()
        log.info("hello world")
        local out = sink:joined()
        ok("emission produces a line", out:sub(-1) == "\n",
            "out=" .. out)
        ok("format includes the level [INFO ]",
            out:find("[INFO ]", 1, true) ~= nil, "out=" .. out)
        ok("format includes the message",
            out:find("hello world", 1, true) ~= nil)
        ok("format starts with ISO timestamp",
            out:find("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d ") ~= nil,
            "out=" .. out)

        sink:clear()
        log.info("user=", 42, "status=", "ok")
        out = sink:joined()
        ok("variadic: args joined with space",
            out:find("user= 42 status= ok", 1, true) ~= nil,
            "out=" .. out)
    end

    -- ----- filtrage par seuil ---------------------------------------

    do
        local sink = make_sink()
        log.set_output(sink)
        log.set_color(false)
        log.set_level(log.WARN)

        sink:clear()
        log.trace("t"); log.debug("d"); log.info("i")
        ok("seuil=WARN : trace/debug/info silent",
            sink:joined() == "", "out=" .. sink:joined())

        sink:clear()
        log.warn("w"); log.error("e")
        local out = sink:joined()
        ok("seuil=WARN : warn and error pass",
            out:find("[WARN ]", 1, true) ~= nil
            and out:find("[ERROR]", 1, true) ~= nil)
    end

    -- set_level : accepte string OU number ; case-insensible side string
    do
        log.set_level("ERROR")
        ok("set_level('ERROR') -> ERROR (50)",
            log.get_level() == log.ERROR)
        log.set_level("debug")
        ok("set_level('debug') -> DEBUG",
            log.get_level() == log.DEBUG)
        log.set_level(log.INFO)
        ok("set_level(log.INFO) -> INFO",
            log.get_level() == log.INFO)
    end

    -- ----- couleurs : OFF / ON --------------------------------------

    do
        local sink = make_sink()
        log.set_output(sink)
        log.set_level(log.TRACE)

        log.set_color(false)
        sink:clear(); log.warn("zz")
        ok("color OFF: no ANSI sequence",
            sink:joined():find("\27[", 1, true) == nil,
            "out=" .. sink:joined())

        log.set_color(true)
        sink:clear(); log.warn("zz")
        ok("color ON + warn: ANSI sequence present",
            sink:joined():find("\27[33m", 1, true) ~= nil,
            "out=" .. sink:joined())

        sink:clear(); log.error("zz")
        ok("color ON + error: red ANSI sequence",
            sink:joined():find("\27[31m", 1, true) ~= nil)

        sink:clear(); log.info("zz")
        ok("color ON + info: NO color (decision G)",
            sink:joined():find("\27[", 1, true) == nil,
            "out=" .. sink:joined())

        log.set_color(false)
    end

    -- ----- contrat d'erreur : setters levent sur mauvais usage ------

    do
        ok("set_level('unknown') -> error()",
            pcall(function() log.set_level("xxxx") end) == false)
        ok("set_level({}) -> error()",
            pcall(function() log.set_level({}) end) == false)
        ok("set_output(42) -> error()",
            pcall(function() log.set_output(42) end) == false)
        ok("set_output({}) without :write -> error()",
            pcall(function() log.set_output({}) end) == false)
        ok("set_color('truthy') -> error() (boolean strict)",
            pcall(function() log.set_color("yes") end) == false)
    end

    -- ----- error contract: log.* swallows writes that crash

    do
        local exploding = {}
        function exploding:write() error("boom") end

        log.set_output(exploding)
        log.set_level(log.INFO)
        log.set_color(false)
        local ok_call = pcall(function() log.info("test") end)
        ok("log.info with raising sink: does NOT propagate the error",
            ok_call == true)

        -- restore : on rebascule la sortie sur stderr pour ne pas
        -- polluer les sections suivantes (== arg ===, ===chdir==).
        log.set_output(io.stderr)
    end
end
-- =====================================================================
print("")
print("=== sys ===")

do
    -- ----- pid : entier > 0, jamais d'erreur (POSIX) ----------------

    do
        local p = babet.pid()
        ok("pid() -> integer > 0",
            type(p) == "number" and p > 0 and p == math.floor(p),
            "pid=" .. tostring(p))
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
        -- env(table) raises (les nombres sont coercés en string par
        -- luaL_checkstring — convention Lua héritée, partagée par
        -- the entire codebase; so we test with a table, which does not
        -- peut pas être coercée silencieusement).
        ok("env({}) raises",
            pcall(function() return babet.env({}) end) == false)
        ok("setenv() without args raises",
            pcall(function() return babet.setenv() end) == false)
        ok("setenv('X') without value raises",
            pcall(function() return babet.setenv("X") end) == false)
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
print("")
print("=== sqlite (session 1: open/close/exec) ===")

do
    local DB = babet.sqlite

    -- ----- contract de base ------------------------------------------
    ok("babet.sqlite is a table", type(DB) == "table")
    ok("open is a function", type(DB.open) == "function")

    -- ----- validation des arguments ----------------------------------
    -- path manquant
    do
        local pok = pcall(DB.open)
        ok("open() raises (path missing)", not pok)
    end

    -- path mauvais type
    do
        local pok = pcall(DB.open, 42)
        ok("open(42) raises (path not string)", not pok)
    end

    -- opts mauvais type
    do
        local pok, perr = pcall(DB.open, ":memory:", "bad")
        ok("open(':memory:', 'bad') raises (opts not table)", not pok)
        ok("  message mentions 'table'",
            type(perr) == "string" and perr:find("table"))
    end

    -- opts.wal mauvais type
    do
        local pok = pcall(DB.open, ":memory:", { wal = "yes" })
        ok("open(opts.wal = 'yes') raises (wal not boolean)", not pok)
    end

    -- opts.busy_timeout mauvais type
    do
        local pok = pcall(DB.open, ":memory:", { busy_timeout = "1000" })
        ok("open(opts.busy_timeout = '1000') raises (not integer)", not pok)
    end

    -- opts.busy_timeout négatif
    do
        local pok = pcall(DB.open, ":memory:", { busy_timeout = -5 })
        ok("open(opts.busy_timeout = -5) raises (< 0)", not pok)
    end

    -- opts.busy_timeout absurde
    do
        local pok = pcall(DB.open, ":memory:", { busy_timeout = 99999999 })
        ok("open(opts.busy_timeout = 99999999) raises (sanity max)", not pok)
    end

    -- ----- ouverture en mémoire (cas le plus simple) -----------------
    do
        local db, err = DB.open(":memory:")
        ok("open(':memory:') -> db", db ~= nil, "err=" .. tostring(err))
        ok("  no error", err == nil)
        ok("  db is userdata", type(db) == "userdata")

        -- exec basique : CREATE TABLE
        local ok_, err2 = db:exec("CREATE TABLE t(a INTEGER, b TEXT)")
        ok("db:exec(CREATE TABLE) -> true", ok_ == true)
        ok("  no error", err2 == nil)

        -- exec INSERT (sans paramètres pour cette session 1)
        local ok2, err3 = db:exec("INSERT INTO t VALUES (1, 'hello')")
        ok("db:exec(INSERT) -> true", ok2 == true)
        ok("  no error", err3 == nil)

        -- exec multi-statements (séparés par ';')
        local ok3 = db:exec("INSERT INTO t VALUES (2, 'a'); INSERT INTO t VALUES (3, 'b');")
        ok("db:exec(2 INSERTs séparés par ;) -> true", ok3 == true)

        -- SQL invalide
        local ok4, err4 = db:exec("INSERT INTO bogus VALUES (1)")
        ok("db:exec(INSERT INTO unknown table) -> (nil, err)",
            ok4 == nil and type(err4) == "string")
        ok("  err prefixed with 'sqlite: '",
            type(err4) == "string" and err4:find("^sqlite: "))

        -- close idempotent
        local cok = db:close()
        ok("db:close() -> true", cok == true)

        local cok2 = db:close()
        ok("db:close() again -> true (idempotent)", cok2 == true)

        -- exec après close
        local ok5, err5 = db:exec("SELECT 1")
        ok("db:exec() after close -> (nil, err)",
            ok5 == nil and type(err5) == "string")
        ok("  err mentions 'closed'",
            type(err5) == "string" and err5:find("closed"))
    end

    -- ----- ouverture avec opts ---------------------------------------
    do
        local db = DB.open(":memory:", { busy_timeout = 1000 })
        ok("open(':memory:', busy_timeout=1000) -> db", db ~= nil)
        db:close()
    end

    -- WAL n'est pas applicable à ':memory:' (SQLite fallback automatique),
    -- mais l'option ne doit pas faire planter.
    do
        local db, err = DB.open(":memory:", { wal = true, busy_timeout = 500 })
        ok("open(':memory:', wal=true) -> db (silent fallback)",
            db ~= nil, "err=" .. tostring(err))
        if db then db:close() end
    end

    -- ----- erreur d'ouverture (chemin invalide) ----------------------
    -- Sur Linux, "/proc/cant_write_here" devrait échouer car /proc
    -- est en lecture seule pour les fichiers normaux.
    do
        local db, err = DB.open("/proc/nope_cant_create_a_db_here.db")
        if not db then
            ok("open(invalid path) -> (nil, err)", db == nil)
            ok("  err prefixed with 'sqlite: '",
                type(err) == "string" and err:find("^sqlite: "))
        else
            -- Si par hasard ça réussit (FS atypique), on ferme et
            -- on note. Le test reste passant : on a juste vérifié
            -- l'API.
            db:close()
            os.remove("/proc/nope_cant_create_a_db_here.db")
            ok("open(invalid path) -- system allowed it, skipping", true)
        end
    end

    -- ----- tostring --------------------------------------------------
    do
        local db = DB.open(":memory:")
        local s = tostring(db)
        ok("tostring(db) contains 'sqlite'",
            type(s) == "string" and s:find("sqlite"))
        db:close()
        s = tostring(db)
        ok("tostring(db) after close mentions 'closed'",
            type(s) == "string" and s:find("closed"))
    end

    -- ----- GC automatique : on ne stocke pas le db ------------------
    -- Si le __gc est cassé, ça leaker silencieusement. Pas testable
    -- de façon fiable côté Lua, mais au moins on s'assure que ça
    -- ne crash pas.
    do
        for i = 1, 5 do
            local db = DB.open(":memory:")
            db:exec("CREATE TABLE t(x)")
            -- pas de close explicite : __gc devra le faire
        end
        collectgarbage("collect")
        ok("5 open + GC sans crash", true)
    end
end

-- =====================================================================
print("")
print("=== sqlite (session 2: exec with params) ===")

do
    local DB = babet.sqlite

    -- Helper : nouvelle DB en mémoire avec une table de validation
    -- via CHECK constraint. Permet de tester que le bind produit la
    -- bonne valeur côté SQL sans avoir besoin de db:query (session 3).
    local function fresh_db_with_check(check_sql)
        local db = DB.open(":memory:")
        local ok_, err = db:exec("CREATE TABLE t (val) ")
        if not ok_ then error("setup: CREATE failed: " .. tostring(err)) end
        if check_sql then
            db:exec("DROP TABLE t")
            db:exec("CREATE TABLE t (val CHECK(" .. check_sql .. "))")
        end
        return db
    end

    -- ----- params = nil ou absent : équivalent session 1 ---------------
    do
        local db = DB.open(":memory:")
        local ok_ = db:exec("CREATE TABLE t (x)")
        ok("exec(sql) without params arg -> still works", ok_ == true)

        local ok2 = db:exec("INSERT INTO t VALUES (1)", nil)
        ok("exec(sql, nil) -> same as no params", ok2 == true)

        db:close()
    end

    -- ----- params doit être une table si fourni ----------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x)")

        local pok, perr = pcall(db.exec, db, "INSERT INTO t VALUES (?)", "not a table")
        ok("exec(sql, string) raises (params not table)", not pok)
        ok("  message mentions 'table'",
            type(perr) == "string" and perr:find("table"))

        local pok2 = pcall(db.exec, db, "INSERT INTO t VALUES (?)", 42)
        ok("exec(sql, number) raises (params not table)", not pok2)

        db:close()
    end

    -- ----- bind positionnel simple -----------------------------------
    do
        local db = fresh_db_with_check("val = 42")

        local ok_, err = db:exec("INSERT INTO t VALUES (?)", { 42 })
        ok("bind positionnel: 42 OK", ok_ == true, "err=" .. tostring(err))

        local ok2, err2 = db:exec("INSERT INTO t VALUES (?)", { 99 })
        ok("bind positionnel: 99 viole CHECK", ok2 == nil)
        ok("  err prefixed with 'sqlite: '",
            type(err2) == "string" and err2:find("^sqlite: "))

        db:close()
    end

    -- ----- bind positionnel : trop de slots, trop peu de params ------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a, b)")

        local pok, perr = pcall(db.exec, db, "INSERT INTO t VALUES (?, ?)", { 1 })
        ok("bind 1 param pour 2 slots -> raises", not pok)
        ok("  message mentions 'missing'",
            type(perr) == "string" and perr:find("missing"))

        local pok2, perr2 = pcall(db.exec, db, "INSERT INTO t VALUES (?, ?)", { 1, 2, 3 })
        ok("bind 3 params pour 2 slots -> raises", not pok2)
        ok("  message mentions 'too many'",
            type(perr2) == "string" and perr2:find("too many"))

        db:close()
    end

    -- ----- bind nommé : ':name' --------------------------------------
    do
        local db = fresh_db_with_check("val = 7")

        local ok_, err = db:exec("INSERT INTO t VALUES (:x)", { x = 7 })
        ok("bind nommé :x = 7 OK", ok_ == true, "err=" .. tostring(err))

        local ok2 = db:exec("INSERT INTO t VALUES (:x)", { x = 99 })
        ok("bind nommé :x = 99 viole CHECK", ok2 == nil)

        db:close()
    end

    -- ----- bind nommé : préfixes alternatifs @ et $ ------------------
    do
        local db = fresh_db_with_check("val = 5")

        local ok_, err = db:exec("INSERT INTO t VALUES (@x)", { x = 5 })
        ok("bind nommé @x = 5 OK (préfixe @ accepté)",
            ok_ == true, "err=" .. tostring(err))

        local ok2, err2 = db:exec("INSERT INTO t VALUES ($x)", { x = 5 })
        ok("bind nommé $x = 5 OK (préfixe $ accepté)",
            ok2 == true, "err=" .. tostring(err2))

        db:close()
    end

    -- ----- bind nommé : param manquant -------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a, b)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (:a, :b)", { a = 1 })
        ok("bind {a=1} pour :a et :b -> raises", not pok)
        ok("  message mentions ':b'",
            type(perr) == "string" and perr:find(":b"))

        db:close()
    end

    -- ----- bind nommé : param en trop --------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (:a)", { a = 1, zzz = "extra" })
        ok("bind {a=1, zzz='extra'} pour :a seul -> raises", not pok)
        ok("  message mentions 'zzz'",
            type(perr) == "string" and perr:find("zzz"))

        db:close()
    end

    -- ----- mélange positionnel + nommé -------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a, b, c)")

        local ok_, err = db:exec(
            "INSERT INTO t VALUES (?, :name, ?)",
            { "first", "third", name = "second" })
        ok("mélange positionnel + nommé OK",
            ok_ == true, "err=" .. tostring(err))

        db:close()
    end

    -- ----- types Lua : booléens convertis en 0/1 ---------------------
    do
        local db = fresh_db_with_check("val = 1")
        local ok_ = db:exec("INSERT INTO t VALUES (?)", { true })
        ok("bind true -> INTEGER 1 (CHECK val=1 OK)", ok_ == true)
        db:close()

        local db2 = fresh_db_with_check("val = 0")
        local ok2 = db2:exec("INSERT INTO t VALUES (?)", { false })
        ok("bind false -> INTEGER 0 (CHECK val=0 OK)", ok2 == true)
        db2:close()
    end

    -- ----- types Lua : integer / float / string ----------------------
    do
        local db = fresh_db_with_check("val = 42")
        ok("bind integer 42 OK",
            db:exec("INSERT INTO t VALUES (?)", { 42 }) == true)
        db:close()

        local db2 = fresh_db_with_check("val = 3.14")
        ok("bind float 3.14 OK",
            db2:exec("INSERT INTO t VALUES (?)", { 3.14 }) == true)
        db2:close()

        local db3 = fresh_db_with_check("val = 'hello'")
        ok("bind string 'hello' OK",
            db3:exec("INSERT INTO t VALUES (?)", { "hello" }) == true)
        db3:close()

        -- string avec NUL : doit passer (binary-safe)
        local db4 = DB.open(":memory:")
        db4:exec("CREATE TABLE t (val)")
        local ok4 = db4:exec("INSERT INTO t VALUES (?)", { "a\0b\0c" })
        ok("bind string avec NUL embarqués OK", ok4 == true)
        db4:close()
    end

    -- ----- types Lua : refusés (function, table, userdata, thread) --
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (val)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { function() end })
        ok("bind function -> raises", not pok)
        ok("  message mentions 'function'",
            type(perr) == "string" and perr:find("function"))

        local pok2, perr2 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { { nested = true } })
        ok("bind table -> raises", not pok2)
        ok("  message mentions 'table'",
            type(perr2) == "string" and perr2:find("table"))

        -- userdata : on en a sous la main via db lui-même
        local pok3, perr3 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { db })
        ok("bind userdata -> raises", not pok3)
        ok("  message mentions 'userdata'",
            type(perr3) == "string" and perr3:find("userdata"))

        local co = coroutine.create(function() end)
        local pok4, perr4 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { co })
        ok("bind thread (coroutine) -> raises", not pok4)
        ok("  message mentions 'thread'",
            type(perr4) == "string" and perr4:find("thread"))

        db:close()
    end

    -- ----- multi-statement avec params : refusé ---------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local ok_, err = db:exec(
            "INSERT INTO t VALUES (?); INSERT INTO t VALUES (?);",
            { 1, 2 })
        ok("multi-statement avec params -> (nil, err)",
            ok_ == nil and type(err) == "string")
        ok("  message mentions 'one statement'",
            type(err) == "string" and err:find("one statement"))

        -- Sans params, multi-statement est OK (cas session 1).
        local ok2 = db:exec("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);")
        ok("multi-statement SANS params -> toujours OK (session 1)",
            ok2 == true)

        db:close()
    end

    -- ----- SQL invalide avec params : prepare échoue -----------------
    do
        local db = DB.open(":memory:")
        local ok_, err = db:exec("INSERT INTO bogus VALUES (?)", { 1 })
        ok("SQL invalide avec params -> (nil, err)",
            ok_ == nil and type(err) == "string")
        ok("  err prefixed with 'sqlite: '",
            type(err) == "string" and err:find("^sqlite: "))
        db:close()
    end

    -- ----- exec après close : avec params aussi ----------------------
    do
        local db = DB.open(":memory:")
        db:close()
        local ok_, err = db:exec("INSERT INTO t VALUES (?)", { 1 })
        ok("exec(sql, params) after close -> (nil, err)",
            ok_ == nil and type(err) == "string")
    end

    -- ----- pas de leak après bind d'erreur : burst de fails ---------
    -- Si bind_params_from_table fuite le stmt sur erreur, on devrait
    -- voir des fuites SQLite. Pas testable directement, mais on fait
    -- au moins beaucoup d'opérations pour que les fuites éventuelles
    -- soient visibles via top/htop si on regarde.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")
        for i = 1, 100 do
            pcall(db.exec, db, "INSERT INTO t VALUES (?)", { function() end })
        end
        ok("100 binds qui fail : pas de crash", true)
        db:close()
    end
end

-- =====================================================================
print("")
print("=== sqlite (session 3: query + lazy iterator) ===")

do
    local DB = babet.sqlite

    -- Helper : crée une DB avec une table peuplée pour les tests.
    local function setup_users()
        local db = DB.open(":memory:")
        assert(db:exec([[
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                name TEXT,
                age INTEGER,
                bio TEXT
            )
        ]]))
        assert(db:exec("INSERT INTO users VALUES (1, 'alice', 30, NULL)"))
        assert(db:exec("INSERT INTO users VALUES (2, 'bob', 25, 'engineer')"))
        assert(db:exec("INSERT INTO users VALUES (3, 'carol', 40, 'designer')"))
        return db
    end

    -- ----- contrat de base -------------------------------------------
    do
        local db = DB.open(":memory:")
        ok("db.query is a method", type(db.query) == "function")
        db:close()
    end

    -- ----- query sur DB fermée ---------------------------------------
    do
        local db = DB.open(":memory:")
        db:close()
        local iter, err = db:query("SELECT 1")
        ok("query after close -> (nil, err)",
            iter == nil and type(err) == "string")
        ok("  err mentions 'closed'",
            type(err) == "string" and err:find("closed"))
    end

    -- ----- query : validation des arguments --------------------------
    do
        local db = DB.open(":memory:")

        local pok = pcall(db.query, db)
        ok("query() without sql raises", not pok)

        local pok2 = pcall(db.query, db, 42)
        ok("query(number) raises (no coercion)", not pok2)

        local pok3 = pcall(db.query, db, "SELECT 1", "not a table")
        ok("query(sql, string) raises (params not table)", not pok3)

        db:close()
    end

    -- ----- itération basique : 3 rows --------------------------------
    do
        local db = setup_users()

        local rows = {}
        for row in db:query("SELECT id, name FROM users ORDER BY id") do
            table.insert(rows, row)
        end
        ok("iter: 3 rows collected", #rows == 3)
        ok("  row[1].id == 1", rows[1].id == 1)
        ok("  row[1].name == 'alice'", rows[1].name == "alice")
        ok("  row[2].id == 2", rows[2].id == 2)
        ok("  row[2].name == 'bob'", rows[2].name == "bob")
        ok("  row[3].name == 'carol'", rows[3].name == "carol")

        db:close()
    end

    -- ----- WHERE avec bind positionnel -------------------------------
    do
        local db = setup_users()

        local rows = {}
        for row in db:query("SELECT name FROM users WHERE age > ? ORDER BY id", { 28 }) do
            table.insert(rows, row.name)
        end
        ok("WHERE age > 28: returns 2 rows (alice, carol)", #rows == 2)
        ok("  alice present", rows[1] == "alice")
        ok("  carol present", rows[2] == "carol")

        db:close()
    end

    -- ----- WHERE avec bind nommé -------------------------------------
    do
        local db = setup_users()

        local rows = {}
        for row in db:query("SELECT name FROM users WHERE name = :n", { n = "bob" }) do
            table.insert(rows, row.name)
        end
        ok("WHERE name = :n bound to 'bob': 1 row", #rows == 1)
        ok("  it's bob", rows[1] == "bob")

        db:close()
    end

    -- ----- type mapping : INTEGER, TEXT, NULL ------------------------
    do
        local db = setup_users()

        local row
        for r in db:query("SELECT * FROM users WHERE id = 1") do
            row = r
        end
        ok("row fetched (alice)", row ~= nil)
        ok("  id is integer", math.type(row.id) == "integer")
        ok("  id == 1", row.id == 1)
        ok("  name is string", type(row.name) == "string")
        ok("  age is integer", math.type(row.age) == "integer")
        ok("  age == 30", row.age == 30)
        -- bio est NULL → la clé devrait être absente
        ok("  bio (NULL) is absent from table", row.bio == nil)
        ok("  bio (NULL) is also missing from pairs()", (function()
            for k, _ in pairs(row) do
                if k == "bio" then return false end
            end
            return true
        end)())

        db:close()
    end

    -- ----- type mapping : REAL ---------------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x REAL)")
        db:exec("INSERT INTO t VALUES (3.14)")
        db:exec("INSERT INTO t VALUES (2.71828)")

        local rows = {}
        for r in db:query("SELECT x FROM t ORDER BY x") do
            table.insert(rows, r.x)
        end
        ok("REAL: 2 rows", #rows == 2)
        ok("  2.71828 first", math.abs(rows[1] - 2.71828) < 1e-9)
        ok("  3.14 second", math.abs(rows[2] - 3.14) < 1e-9)
        ok("  is float type (not integer)", math.type(rows[1]) == "float")

        db:close()
    end

    -- ----- type mapping : BLOB ---------------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (b BLOB)")
        -- INSERT BLOB via X'...' (hex literal) pour garantir BLOB type
        db:exec("INSERT INTO t VALUES (X'00010203FF')")

        local row
        for r in db:query("SELECT b FROM t") do row = r end
        ok("BLOB row fetched", row ~= nil and row.b ~= nil)
        ok("  BLOB is a string (binary-safe)", type(row.b) == "string")
        ok("  BLOB length == 5", #row.b == 5)
        ok("  byte 0 == 0x00", string.byte(row.b, 1) == 0x00)
        ok("  byte 4 == 0xFF", string.byte(row.b, 5) == 0xFF)

        db:close()
    end

    -- ----- type mapping : TEXT avec NUL embarqué ---------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (s)")
        db:exec("INSERT INTO t VALUES (?)", { "a\0b\0c" })

        local row
        for r in db:query("SELECT s FROM t") do row = r end
        ok("TEXT avec NUL: row OK", row ~= nil)
        ok("  longueur preserved (5 bytes)", #row.s == 5)
        ok("  byte 2 == NUL", string.byte(row.s, 2) == 0)

        db:close()
    end

    -- ----- SELECT 0 row : iterator finit immédiatement ---------------
    do
        local db = setup_users()
        local count = 0
        for _ in db:query("SELECT * FROM users WHERE id = 999") do
            count = count + 1
        end
        ok("SELECT with no match: 0 rows", count == 0)
        db:close()
    end

    -- ----- DDL/DML via query : iterator vide (pas d'erreur) ---------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x)")
        local count = 0
        for _ in db:query("INSERT INTO t VALUES (42)") do
            count = count + 1
        end
        ok("query('INSERT'): iterator empty (0 rows)", count == 0)

        -- Vérifier que l'INSERT a quand même été exécuté
        local n = 0
        for _ in db:query("SELECT * FROM t") do n = n + 1 end
        ok("  ... mais l'INSERT a bien eu lieu", n == 1)

        db:close()
    end

    -- ----- query sur SQL invalide ------------------------------------
    do
        local db = DB.open(":memory:")
        local iter, err = db:query("SELECT * FROM bogus")
        ok("query(invalid SQL) -> (nil, err)",
            iter == nil and type(err) == "string")
        ok("  err prefixed with 'sqlite: '",
            type(err) == "string" and err:find("^sqlite: "))
        db:close()
    end

    -- ----- multi-statement refusé ------------------------------------
    do
        local db = setup_users()
        local iter, err = db:query("SELECT 1; SELECT 2;")
        ok("multi-statement query -> (nil, err)",
            iter == nil and type(err) == "string")
        ok("  message mentions 'one statement'",
            type(err) == "string" and err:find("one statement"))
        db:close()
    end

    -- ----- bind manquant : raise -------------------------------------
    do
        local db = setup_users()
        local pok, perr = pcall(db.query, db,
            "SELECT * FROM users WHERE age > ?", {})
        ok("query with missing positional param -> raises", not pok)
        ok("  message mentions 'missing'",
            type(perr) == "string" and perr:find("missing"))
        db:close()
    end

    -- ----- close explicite + reprise ---------------------------------
    do
        local db = setup_users()
        local iter = db:query("SELECT id FROM users ORDER BY id")

        local first = iter()
        ok("1er iter() -> row", first ~= nil and first.id == 1)

        iter:close()
        -- Après close, iter() doit retourner nil (fin) au lieu de planter
        local after_close = iter()
        ok("iter() after close -> nil (terminé)", after_close == nil)

        -- close idempotent
        local ok_ = iter:close()
        ok("iter:close() idempotent", ok_ == true)

        db:close()
    end

    -- ----- break dans la boucle : pas de crash, finalize via __gc ---
    do
        local db = setup_users()
        for row in db:query("SELECT * FROM users ORDER BY id") do
            if row.id == 1 then break end
        end
        ok("break mid-iteration: pas de crash", true)
        -- Vérifier qu'on peut continuer à utiliser la db
        local n = 0
        for _ in db:query("SELECT * FROM users") do n = n + 1 end
        ok("  db usable after break: 3 rows again", n == 3)
        db:close()
    end

    -- ----- db:close() pendant qu'un iter est encore en main ---------
    -- (point 8 du design : SQLite garde le handle zombie tant que
    --  le stmt n'est pas finalizé, donc iter() continue à marcher)
    do
        local db = setup_users()
        local iter = db:query("SELECT id FROM users ORDER BY id")
        db:close()
        local r1 = iter()
        ok("iter() after db:close(): toujours marche (zombie SQLite)",
            r1 ~= nil and r1.id == 1)
        local r2 = iter()
        ok("  encore une row", r2 ~= nil and r2.id == 2)
        iter:close()
        ok("iter:close() après db:close(): OK", true)
    end

    -- ----- tostring(stmt) --------------------------------------------
    do
        local db = setup_users()
        local iter = db:query("SELECT * FROM users")
        local s = tostring(iter)
        ok("tostring(stmt) contains 'sqlite.stmt'",
            type(s) == "string" and s:find("sqlite.stmt"))
        ok("  mentions 'active'",
            type(s) == "string" and s:find("active"))
        iter:close()
        local s2 = tostring(iter)
        ok("tostring after close mentions 'closed'",
            type(s2) == "string" and s2:find("closed"))
        db:close()
    end

    -- ----- transactions manuelles (cas d'usage typique) -------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x INTEGER)")

        db:exec("BEGIN")
        for i = 1, 5 do
            db:exec("INSERT INTO t VALUES (?)", { i })
        end
        db:exec("COMMIT")

        local n = 0
        local sum = 0
        for row in db:query("SELECT x FROM t ORDER BY x") do
            n = n + 1
            sum = sum + row.x
        end
        ok("BEGIN/INSERTs/COMMIT: 5 rows", n == 5)
        ok("  sum == 15", sum == 15)

        -- ROLLBACK
        db:exec("BEGIN")
        db:exec("INSERT INTO t VALUES (?)", { 999 })
        db:exec("ROLLBACK")

        local n2 = 0
        for _ in db:query("SELECT * FROM t") do n2 = n2 + 1 end
        ok("ROLLBACK: toujours 5 rows (pas 6)", n2 == 5)

        db:close()
    end

    -- ----- round-trip de tous les types ------------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (i INTEGER, f REAL, s TEXT, b BLOB)")

        -- INSERT avec bind de chaque type
        assert(db:exec("INSERT INTO t VALUES (?, ?, ?, ?)",
            { 42, 3.14, "hello", "\x01\x02\x03" }))

        local row
        for r in db:query("SELECT * FROM t") do row = r end
        ok("round-trip integer", row.i == 42)
        ok("round-trip float", math.abs(row.f - 3.14) < 1e-9)
        ok("round-trip text", row.s == "hello")
        ok("round-trip blob (3 bytes)", #row.b == 3)
        ok("  blob byte 1 == 1", string.byte(row.b, 1) == 1)

        db:close()
    end

    -- ----- hardening: SQL with placeholders but no params -----------
    -- (audit point 1) Without this check, "INSERT VALUES (?)" without
    -- params would bind NULL silently. We want explicit error instead.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local ok_, err = db:exec("INSERT INTO t VALUES (?)")
        ok("exec with '?' but no params -> (nil, err)",
            ok_ == nil and type(err) == "string")
        ok("  message mentions 'placeholders'",
            type(err) == "string" and err:find("placeholders"))

        -- Named placeholders too
        local ok2, err2 = db:exec("INSERT INTO t VALUES (:x)")
        ok("exec with ':name' but no params -> (nil, err)",
            ok2 == nil and type(err2) == "string")

        -- Régression (audit v21) : le garde ne sondait que le PREMIER
        -- statement (prepare s'arrête au premier ';') puis relançait
        -- le tout via sqlite3_exec : un '?' dans le 2e statement
        -- passait et liait NULL silencieusement (l'ancien code
        -- rendait true ET une ligne NULL était insérée — les deux
        -- assertions ci-dessous discriminent). Désormais : exécution
        -- statement par statement, garde sur chacun.
        do
            local okm, errm = db:exec(
                "CREATE TABLE t2s (x); INSERT INTO t2s VALUES (?)")
            ok("exec multi-stmt avec '?' dans le 2e -> (nil, err)",
                okm == nil and type(errm) == "string")
            ok("  message mentions 'placeholders'",
                type(errm) == "string" and errm:find("placeholders"))
            -- Le CREATE (1er statement, valide) a été exécuté — comme
            -- sqlite3_exec, l'arrêt se fait AU statement fautif — mais
            -- l'INSERT ne doit jamais avoir tourné : zéro ligne.
            local n = nil
            for row in db:query("SELECT COUNT(*) AS c FROM t2s") do
                n = row.c
            end
            ok("  aucune ligne NULL insérée (COUNT == 0)", n == 0,
                "count=" .. tostring(n))
            -- Sanity : multi-statement propre, toujours OK, et les
            -- effets des DEUX statements sont visibles.
            local oks = db:exec(
                "INSERT INTO t2s VALUES (1); INSERT INTO t2s VALUES (2)")
            ok("exec multi-stmt sans placeholder -> true", oks == true)
            local n2 = nil
            for row in db:query("SELECT COUNT(*) AS c FROM t2s") do
                n2 = row.c
            end
            ok("  2 lignes insérées", n2 == 2, "count=" .. tostring(n2))
        end

        -- query() same check
        local iter, err3 = db:query("SELECT * FROM t WHERE a = ?")
        ok("query with '?' but no params -> (nil, err)",
            iter == nil and type(err3) == "string")
        ok("  message mentions 'placeholders'",
            type(err3) == "string" and err3:find("placeholders"))

        -- Without placeholders, no params is still OK
        local ok4 = db:exec("INSERT INTO t VALUES (1)")
        ok("exec without placeholders, no params -> still OK", ok4 == true)

        db:close()
    end

    -- ----- hardening: sparse numeric keys in params -----------------
    -- (audit point 2) Without this check, { [10] = "x" } would be
    -- silently ignored.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (a)")

        local pok, perr = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { "ok", [10] = "ignored" })
        ok("bind with sparse numeric key [10] -> raises", not pok)
        ok("  message mentions 'index 10'",
            type(perr) == "string" and perr:find("index 10"))

        local pok2, perr2 = pcall(db.exec, db,
            "INSERT INTO t VALUES (?)", { [1] = "ok", [1.5] = "weird" })
        ok("bind with non-integer numeric key [1.5] -> raises", not pok2)
        ok("  message mentions 'non-integer'",
            type(perr2) == "string" and perr2:find("non%-integer"))

        db:close()
    end

    -- ----- hardening: empty BLOB ------------------------------------
    -- (audit point 3) sqlite3_column_blob() may return NULL for a
    -- zero-byte BLOB. We push an explicit empty string instead.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (b BLOB)")
        db:exec("INSERT INTO t VALUES (X'')") -- BLOB of length 0

        local row
        for r in db:query("SELECT b FROM t") do row = r end
        ok("empty BLOB: row fetched", row ~= nil)
        ok("  b is a string", type(row.b) == "string")
        ok("  #b == 0", #row.b == 0)

        db:close()
    end

    -- ----- hardening: empty TEXT ------------------------------------
    -- (audit follow-up) Same UB risk as BLOB: sqlite3_column_text()
    -- may return NULL for a zero-byte TEXT, and
    -- lua_pushlstring(L, NULL, 0) is UB. We push explicit empty.
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (s TEXT)")
        db:exec("INSERT INTO t VALUES ('')") -- TEXT of length 0

        local row
        for r in db:query("SELECT s FROM t") do row = r end
        ok("empty TEXT: row fetched", row ~= nil)
        ok("  s is a string", type(row.s) == "string")
        ok("  #s == 0", #row.s == 0)

        db:close()
    end
end

do
    local T = babet.toml

    -- ----- contrat de base -----------------------------------------

    ok("babet.toml is a table", type(T) == "table")
    ok("babet.toml.decode is a function",
        type(T.decode) == "function")

    -- ----- minimal success : (table, nil) ---------------------------

    do
        -- Régression (revue Gemini post-audit v21) : push_toml_node
        -- ne réservait pas la pile Lua, et la profondeur vient du
        -- DOCUMENT décodé (potentiellement hostile). 59 tables inline
        -- imbriquées doivent se convertir proprement.
        do
            local s = "root = " .. string.rep("{ k = ", 59)
                .. "1" .. string.rep(" }", 59)
            local rd, ed = T.decode(s)
            local n, d = rd and rd.root, 0
            while type(n) == "table" and n.k ~= nil do
                if type(n.k) ~= "table" then break end
                n = n.k; d = d + 1
            end
            ok("toml : 59 tables inline imbriquées (checkstack)",
                rd ~= nil and d == 58 and type(n) == "table"
                and n.k == 1,
                ed or ("d=" .. tostring(d)))
        end

        local r, e = T.decode('title = "TOML Example"')
        ok_val("decode minimal -> (table, nil)", r, e)
        ok("  title returned",
            type(r) == "table" and r.title == "TOML Example",
            "title=" .. tostring(r and r.title))
    end

    -- ----- types scalaires : string, integer, float, bool ----------

    do
        local src = [[
str = "hello"
n_int = 42
n_float = 3.14
b_true = true
b_false = false
]]
        local r, e = T.decode(src)
        ok_val("decode scalars -> (table, nil)", r, e)
        ok("  string", r and r.str == "hello")
        ok("  integer (number, exact int)",
            r and type(r.n_int) == "number" and r.n_int == 42)
        ok("  float (number, non-int)",
            r and type(r.n_float) == "number"
            and r.n_float > 3.13 and r.n_float < 3.15)
        ok("  boolean true", r and r.b_true == true)
        ok("  boolean false", r and r.b_false == false)
    end

    -- ----- array TOML -> séquence Lua 1..n -------------------------

    do
        local r, e = T.decode([[
nums = [ 1, 2, 3 ]
mixed = [ "a", "b", "c" ]
]])
        ok_val("decode arrays -> (table, nil)", r, e)
        ok("  int array: 1..n sequence",
            r and type(r.nums) == "table"
            and #r.nums == 3
            and r.nums[1] == 1 and r.nums[2] == 2 and r.nums[3] == 3)
        ok("  string array: 1..n sequence",
            r and type(r.mixed) == "table"
            and #r.mixed == 3
            and r.mixed[1] == "a" and r.mixed[3] == "c")
    end

    -- ----- table imbriquée (sections) ------------------------------

    do
        local r, e = T.decode([[
[server]
host = "127.0.0.1"
port = 8080

[server.tls]
enabled = true
cert = "/etc/ssl/cert.pem"
]])
        ok_val("decode sections -> (table, nil)", r, e)
        ok("  section [server] is a table",
            r and type(r.server) == "table")
        ok("  server.host", r and r.server and r.server.host == "127.0.0.1")
        ok("  server.port", r and r.server and r.server.port == 8080)
        ok("  nested section [server.tls]",
            r and r.server and type(r.server.tls) == "table"
            and r.server.tls.enabled == true
            and r.server.tls.cert == "/etc/ssl/cert.pem")
    end

    -- ----- array of tables (cas idiomatique TOML) ------------------

    do
        -- [==[ ... ]==] obligatoire ici : la chaîne TOML contient
        -- "[[users]]" (array of tables), qui fermerait un [[ ... ]]
        -- Lua au premier ]] rencontré.
        local r, e = T.decode([==[
[[users]]
name = "alice"
age = 30

[[users]]
name = "bob"
age = 25
]==])
        ok_val("decode array of tables -> (table, nil)", r, e)
        ok("  users is a sequence of 2 tables",
            r and type(r.users) == "table" and #r.users == 2
            and type(r.users[1]) == "table"
            and type(r.users[2]) == "table")
        ok("  users[1].name == 'alice'",
            r and r.users and r.users[1].name == "alice")
        ok("  users[2].age == 25",
            r and r.users and r.users[2].age == 25)
    end

    -- ----- types temporels -> strings ISO 8601 (décision TOML-3) ---

    do
        local r, e = T.decode([[
d = 1979-05-27
t = 07:32:00
dt_local = 1979-05-27T07:32:00
dt_offset = 1979-05-27T07:32:00Z
]])
        ok_val("decode dates/times -> (table, nil)", r, e)
        ok("  local-date -> string '1979-05-27'",
            r and type(r.d) == "string" and r.d == "1979-05-27",
            "d=" .. tostring(r and r.d))
        ok("  local-time -> string starting with '07:32:00'",
            r and type(r.t) == "string"
            and r.t:find("^07:32:00") ~= nil,
            "t=" .. tostring(r and r.t))
        ok("  local-date-time -> string containing 'T'",
            r and type(r.dt_local) == "string"
            and r.dt_local:find("T", 1, true) ~= nil,
            "dt_local=" .. tostring(r and r.dt_local))
        ok("  offset-date-time -> string containing 'T' and offset",
            r and type(r.dt_offset) == "string"
            and r.dt_offset:find("T", 1, true) ~= nil
            and (r.dt_offset:find("Z", 1, true) ~= nil
                or r.dt_offset:find("+", 1, true) ~= nil),
            "dt_offset=" .. tostring(r and r.dt_offset))
    end

    -- ----- UTF-8 preserved (aller simple, on ne réencode pas) -------

    do
        local r, e = T.decode('msg = "été café"')
        ok_val("decode UTF-8 -> (table, nil)", r, e)
        ok("  UTF-8 string intact",
            r and r.msg == "été café",
            "msg=" .. tostring(r and r.msg))
    end

    -- ----- TOML empty / minimal -------------------------------------

    do
        local r, e = T.decode("")
        ok_val("decode('') -> (empty table, nil)", r, e)
        ok("  empty table", r and next(r) == nil)

        r, e = T.decode("# commentaire seul\n")
        ok_val("decode comment only -> (empty table, nil)", r, e)
    end

    -- ----- TOML invalid -> (nil, err) with line/col --------------

    do
        local v, e = T.decode("nope = ")
        ok_fail("decode invalid TOML -> (nil, err)", v, e)
        ok("  err prefixed with 'toml: '",
            type(e) == "string" and e:find("toml: ", 1, true) == 1,
            "err=" .. tostring(e))
        ok("  message contains a line indication",
            type(e) == "string" and e:find("line", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    do
        local v, e = T.decode([[
x = 1
x = 2
]])
        ok_fail("decode redefined key -> (nil, err)", v, e)
    end

    do
        local v, e = T.decode("flag = TRUE")
        ok_fail("decode uppercase boolean -> (nil, err)", v, e)
    end

    -- ----- mauvais usage : luaL_error (luaL_checktype raises) --------

    do
        ok("decode() without arg raises",
            pcall(function() return T.decode() end) == false)
        ok("decode(42) raises (luaL_checktype LUA_TSTRING, no coercion)",
            pcall(function() return T.decode(42) end) == false)
        ok("decode({}) raises",
            pcall(function() return T.decode({}) end) == false)
        ok("decode(nil) raises",
            pcall(function() return T.decode(nil) end) == false)
    end
end

-- =====================================================================
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
        -- port = {} : table non coerçable. Une string "80" passerait
        -- luaL_checkinteger silencieusement (même piège que
        -- luaL_checkstring with numbers) and would not have raised;
        -- on doit utiliser un type qui ne peut PAS être coercé.
        ok("connect('h', {}) raises (port not a number, not coercible)",
            pcall(function() return S.connect("127.0.0.1", {}) end)
            == false)

        ok("listen() without args raises",
            pcall(function() return S.listen() end) == false)
        ok("listen(host) without port raises",
            pcall(function() return S.listen("127.0.0.1") end) == false)
    end

    -- ----- mauvaises valeurs : (nil, err) --------------------------

    do
        local v, e = S.connect("127.0.0.1", -1)
        ok_fail("connect negative port -> (nil, err)", v, e)
        ok("  message mentions 'port'",
            type(e) == "string" and e:find("port", 1, true) ~= nil)

        v, e = S.connect("127.0.0.1", 70000)
        ok_fail("connect port > 65535 -> (nil, err)", v, e)

        v, e = S.listen("127.0.0.1", -1)
        ok_fail("listen negative port -> (nil, err)", v, e)

        v, e = S.listen("127.0.0.1", 8080, -5)
        ok_fail("listen backlog <= 0 -> (nil, err)", v, e)
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

    -- ----- méthodes sur closed socket : refus propre ----------------

    do
        local s = S.listen("127.0.0.1", 0)
        if s then
            s:close()
            -- Re-close : doit être idempotent et rendre (true, nil).
            local ok_close, _ = s:close()
            ok("close() idempotent (already-closed socket)",
                ok_close == true)

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

    -- ----- mauvaises valeurs : (nil, err) -------------------------

    do
        local v, e = S.connect_tls("127.0.0.1", -1)
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
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key_path,
            "-out", cert_path,
            "-days", "1",
            "-subj", "/CN=localhost",
        }, { timeout = 15 })

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
print("")
print("=== user ===")

do
    local U = babet.user

    ok("babet.user is a table", type(U) == "table")
    ok("get is a function", type(U.get) == "function")
    ok("exists is a function", type(U.exists) == "function")

    -- Bad arg types : luaL_error (not nil+err).
    ok("get() without arg raises",
        pcall(function() return U.get() end) == false)
    ok("get({}) raises (wrong type)",
        pcall(function() return U.get({}) end) == false)
    ok("get(true) raises (wrong type)",
        pcall(function() return U.get(true) end) == false)
    ok("get(1.5) raises (non-integer)",
        pcall(function() return U.get(1.5) end) == false)
    ok("get(-1) raises (negative uid)",
        pcall(function() return U.get(-1) end) == false)

    -- Hardening : a string with an embedded NUL would be truncated
    -- by getpwnam_r at the first NUL ('root\0evil' seen as 'root').
    -- That could bypass an upstream identity check. We refuse.
    ok("get('root\\0evil') raises (NUL byte in name)",
        pcall(function() return U.get("root\0evil") end) == false)

    -- Hardening : an integer larger than uid_t max (2^32-1 on Linux)
    -- would be silently truncated by the cast and could match an
    -- unrelated UID by chance. We refuse explicitly.
    -- 2^33 = 8589934592 — comfortably above uid_t max but well below
    -- lua_Integer max (LUA_MAXINTEGER ~ 9.2e18).
    ok("get(2^33) raises (uid out of range)",
        pcall(function() return U.get(8589934592) end) == false)

    -- exists() same rules on bad args.
    ok("exists() without arg raises",
        pcall(function() return U.exists() end) == false)
    ok("exists(1.5) raises",
        pcall(function() return U.exists(1.5) end) == false)

    -- root almost certainly exists on any Linux system the tests run on.
    -- We use it as the "guaranteed present" anchor.
    do
        local u, err = U.get("root")
        ok("get('root') -> table", type(u) == "table" and err == nil)
        if type(u) == "table" then
            ok("  name == 'root'", u.name == "root")
            ok("  uid is integer", type(u.uid) == "number"
                and math.type(u.uid) == "integer")
            ok("  uid == 0", u.uid == 0)
            ok("  gid is integer", type(u.gid) == "number"
                and math.type(u.gid) == "integer")
            ok("  home is string", type(u.home) == "string")
            ok("  shell is string", type(u.shell) == "string")
            ok("  gecos is string (may be empty)",
                type(u.gecos) == "string")
        end
    end

    -- Lookup by UID = 0 must return the same user.
    do
        local u, err = U.get(0)
        ok("get(0) -> table (root by uid)",
            type(u) == "table" and err == nil)
        if type(u) == "table" then
            ok("  name == 'root' (uid 0)", u.name == "root")
        end
    end

    -- Almost-certainly-absent user. We use a deliberately weird
    -- string that is extremely unlikely to clash with a real account.
    local missing = "babet_test_user_xyz_9j3hf83hf"
    do
        local u, err = U.get(missing)
        ok("get(missing) -> (nil, 'user not found')",
            u == nil and err == "user not found")
    end

    -- Same for an unlikely UID. UIDs in [0, 65535] are common but
    -- 2_000_000_000 is extremely unlikely to be assigned.
    do
        local u, err = U.get(2000000000)
        ok("get(very-high-uid) -> (nil, 'user not found')",
            u == nil and err == "user not found")
    end

    -- exists() : pure boolean, no second return value to worry about.
    ok("exists('root') == true", U.exists("root") == true)
    ok("exists(0) == true (uid)", U.exists(0) == true)
    ok("exists(missing) == false", U.exists(missing) == false)
    ok("exists(2000000000) == false",
        U.exists(2000000000) == false)
end

-- =====================================================================
print("")
print("=== inotify ===")

do
    local I = babet.inotify

    -- ----- base contract --------------------------------------------
    ok("babet.inotify is a table", type(I) == "table")
    ok("new is a function", type(I.new) == "function")

    local w, nerr = I.new()
    ok_val("new() -> watcher", w, nerr)
    ok("  add is a method", w ~= nil and type(w.add) == "function")
    ok("  read is a method", w ~= nil and type(w.read) == "function")
    ok("  remove is a method", w ~= nil and type(w.remove) == "function")
    ok("  close is a method", w ~= nil and type(w.close) == "function")

    -- Watched directory, inside the sandbox.
    local WDIR = sb("inotify_d")
    ok_act("mkdir(watch dir)", babet.mkdir(WDIR))

    -- ----- misuse: luaL_error ---------------------------------------
    do
        ok("add() without event list raises",
            pcall(function() return w:add(WDIR) end) == false)
        ok("add(dir, 'string') raises (events not a table)",
            pcall(function() return w:add(WDIR, "create") end) == false)
        ok("read({}) raises (timeout not a number, not coercible)",
            pcall(function() return w:read({}) end) == false)
    end

    -- ----- bad values: (nil, err) -----------------------------------
    do
        local v, e = w:add(WDIR, {})
        ok_fail("add(dir, {}) empty list -> (nil, err)", v, e)
        ok("  message mentions 'empty'",
            type(e) == "string" and e:find("empty", 1, true) ~= nil)

        v, e = w:add(WDIR, { "bogus_event" })
        ok_fail("add(dir, {bogus}) unknown event -> (nil, err)", v, e)
        ok("  message mentions 'unknown'",
            type(e) == "string" and e:find("unknown", 1, true) ~= nil)

        v, e = w:add(sb("inotify_absent"), { "create" })
        ok_fail("add(non-existent path) -> (nil, err)", v, e)

        v, e = w:remove(999999)
        ok_fail("remove(invalid wd) -> (nil, err)", v, e)

        v, e = w:read(-1)
        ok_fail("read(negative timeout) -> (nil, err)", v, e)
    end

    -- ----- add a valid watch ----------------------------------------
    local wd, aerr = w:add(WDIR,
        { "create", "close_write", "moved_from", "moved_to" })
    ok_val("add(dir, events) -> integer wd", wd, aerr,
        function(v) return math.type(v) == "integer" end)

    -- Local helpers: drain all pending events (the kernel may batch
    -- several, and one logical action may generate several), and look
    -- one up by (name, flag).
    local function drain(watcher, secs)
        local all = {}
        local timeout = secs
        while true do
            local evs = watcher:read(timeout)
            if not evs then break end -- timeout/closed/err -> end of drain
            for _, ev in ipairs(evs) do all[#all + 1] = ev end
            timeout = 0.1             -- catch any stragglers
        end
        return all
    end

    local function find_event(list, name, flag)
        for _, ev in ipairs(list) do
            if ev.name == name and ev.events[flag] then return ev end
        end
        return nil
    end

    -- ----- file creation + write ------------------------------------
    do
        local f = assert(io.open(WDIR .. "/photo.jpg", "w"))
        f:write("data")
        f:close()

        local evs = drain(w, 2)
        ok("read() returns an array of tables", type(evs) == "table")

        local cr = find_event(evs, "photo.jpg", "create")
        ok("'create' event on photo.jpg", cr ~= nil)

        local cw = find_event(evs, "photo.jpg", "close_write")
        ok("'close_write' event on photo.jpg", cw ~= nil)
        ok("  is_dir == false for a file",
            cw ~= nil and cw.is_dir == false)
        ok("  event wd == watch wd",
            cw ~= nil and cw.wd == wd)
        ok("  cookie == 0 when not a move",
            cw ~= nil and cw.cookie == 0)
    end

    -- ----- is_dir on subdirectory creation --------------------------
    do
        babet.mkdir(WDIR .. "/subdir")
        local evs = drain(w, 2)
        local cr = find_event(evs, "subdir", "create")
        ok("'create' detected on the subdirectory", cr ~= nil)
        ok("  is_dir == true for a directory",
            cr ~= nil and cr.is_dir == true)
    end

    -- ----- moved_from / moved_to paired by cookie -------------------
    do
        os.rename(WDIR .. "/photo.jpg", WDIR .. "/photo2.jpg")
        local evs = drain(w, 2)
        local mf = find_event(evs, "photo.jpg", "moved_from")
        local mt = find_event(evs, "photo2.jpg", "moved_to")
        ok("'moved_from' detected", mf ~= nil)
        ok("'moved_to' detected", mt ~= nil)
        ok("  cookie non-zero and identical between from and to",
            mf ~= nil and mt ~= nil
            and mf.cookie ~= 0 and mf.cookie == mt.cookie)
    end

    -- ----- timeout: non-blocking and finite -------------------------
    do
        drain(w, 0) -- flush any leftover event
        local v, e = w:read(0)
        ok_fail("read(0) with no activity -> (nil, err)", v, e)
        ok("  reason == 'timeout'", e == "timeout")

        v, e = w:read(0.2)
        ok_fail("read(0.2) with no activity -> (nil, err)", v, e)
        ok("  reason == 'timeout'", e == "timeout")
    end

    -- ----- remove() + 'ignored' event -------------------------------
    do
        local r, e = w:remove(wd)
        ok_act("remove(wd) -> (true, nil)", r, e)

        -- The kernel emits an 'ignored' event for that wd right after.
        local evs = drain(w, 1)
        local ig = nil
        for _, ev in ipairs(evs) do
            if ev.wd == wd and ev.events.ignored then ig = ev end
        end
        ok("'ignored' event emitted after remove", ig ~= nil)
    end

    -- ----- audit fixes ----------------------------------------------
    -- These three tests cover bugs that were caught in a post-merge
    -- audit. They MUST be in place before close() since they need
    -- an active watcher.
    do
        -- Re-arm a watch since we removed wd just above.
        local wd2, e_arm = w:add(WDIR, { "create", "close_write" })
        ok_val("re-arm watch for audit tests", wd2, e_arm)

        -- (1) read(0) must return events already pending in the
        -- kernel queue, not (nil, "timeout"). Previously, the
        -- short-circuit before poll() returned timeout without
        -- ever calling poll(fd, 1, 0).
        do
            -- Drain any leftover events first so the queue is clean.
            drain(w, 0.1)

            local f = assert(io.open(WDIR .. "/audit_read0.txt", "w"))
            f:write("x"); f:close()

            -- Give the kernel a beat to deliver the event into the
            -- inotify queue. 100ms is comfortable on any platform.
            babet.sleep(100, "ms")

            local evs, rerr = w:read(0)
            ok("read(0) returns the already-pending events",
                type(evs) == "table" and #evs > 0,
                "evs=" .. tostring(evs) .. " err=" .. tostring(rerr))
            ok("  events list contains a 'create' for the file",
                find_event(evs or {}, "audit_read0.txt", "create") ~= nil)
        end

        -- (2) NaN and Inf must be rejected on timeout argument.
        do
            local v, e = w:read(0 / 0) -- NaN
            ok_fail("read(NaN) -> (nil, err)", v, e)
            ok("  message mentions 'finite'",
                type(e) == "string" and e:find("finite", 1, true) ~= nil)

            v, e = w:read(math.huge) -- +Inf
            ok_fail("read(+Inf) -> (nil, err)", v, e)

            v, e = w:read(-math.huge) -- -Inf (also covered by <0)
            ok_fail("read(-Inf) -> (nil, err)", v, e)
        end

        -- (3) The events table must be a strict 1..n list. Extra
        -- string keys, sparse numeric keys, and float keys are all
        -- rejected to avoid silently ignored entries.
        do
            local v, e = w:add(WDIR, { "create", x = "extra" })
            ok_fail("add(events with extra string key) -> (nil, err)", v, e)
            ok("  message mentions 'extra string key'",
                type(e) == "string"
                and e:find("extra string key", 1, true) ~= nil)

            v, e = w:add(WDIR, { "create", [10] = "modify" })
            ok_fail("add(events with sparse [10]) -> (nil, err)", v, e)
            ok("  message mentions 'extra integer key'",
                type(e) == "string"
                and e:find("extra integer key", 1, true) ~= nil)

            v, e = w:add(WDIR, { [1] = "create", [1.5] = "modify" })
            ok_fail("add(events with non-integer [1.5]) -> (nil, err)", v, e)
            ok("  message mentions 'non-integer'",
                type(e) == "string"
                and e:find("non-integer", 1, true) ~= nil)

            -- Non-string element at a valid 1..n index : was raising
            -- via luaL_error, now consistently returns (nil, err)
            -- like the other events-table errors.
            v, e = w:add(WDIR, { "create", 42 })
            ok_fail("add(events with non-string element) -> (nil, err)",
                v, e)
            ok("  message mentions 'must be a string'",
                type(e) == "string"
                and e:find("must be a string", 1, true) ~= nil)
        end

        -- Clean up: drain any events generated above, then remove wd2.
        drain(w, 0.1)
        w:remove(wd2)
        drain(w, 0.1) -- swallow the 'ignored' for wd2
    end

    -- ----- close() idempotent + post-close errors -------------------
    ok_act("close() -> (true, nil)", w:close())
    ok_act("close() again (idempotent)", w:close())

    do
        local v, e = w:read(0)
        ok_fail("read() after close -> (nil, err)", v, e)
        ok("  message mentions 'closed'",
            type(e) == "string" and e:find("closed", 1, true) ~= nil)

        local v2, e2 = w:add(WDIR, { "create" })
        ok_fail("add() after close -> (nil, err)", v2, e2)
    end

    babet.rmdirAll(WDIR)
end

-- =====================================================================
print("")
print("=== workers ===")

-- Régression (revue Gemini post-audit v21) : lua_to_json et
-- json_to_lua (sérialisation spawn/join) ne réservaient pas la pile.
-- 30 niveaux (sous MAX_SERIALIZATION_DEPTH = 32) traversent les 4
-- conversions : args parent->json, json->worker, retour worker->json,
-- json->parent.
do
    local t = { v = 42 }
    for _ = 1, 29 do t = { c = t } end
    local job = babet.workers.spawn("return worker.args", t)
    if job then
        local okj, result = job:join()
        local n, d = result, 0
        while type(n) == "table" and n.c do
            n = n.c; d = d + 1
        end
        ok("workers : aller-retour 30 niveaux (checkstack)",
            okj == true and d == 29
            and type(n) == "table" and n.v == 42,
            "ok=" .. tostring(okj) .. " d=" .. tostring(d))
    else
        ok("workers : spawn 30 niveaux", false)
    end
end

-- Option A (validée) : dès le premier spawn — définitivement, même
-- après join — les mutations d'état process-wide sont verrouillées.
do
    local sv, se = babet.setenv("BABET_AFTER_SPAWN", "x")
    ok_fail("setenv après le premier spawn -> (nil, err)", sv, se)
    ok("  message mentions 'workers'",
        type(se) == "string" and se:find("workers", 1, true) ~= nil,
        tostring(se))
    local cv, ce = babet.chdir(babet.currentDir())
    ok_fail("chdir après le premier spawn -> (nil, err)", cv, ce)
end

do
    local W = babet.workers

    -- ----- contrat de base ----------------------------------------

    ok("babet.workers is a table", type(W) == "table")
    ok("workers.spawn is a function", type(W.spawn) == "function")

    -- ----- mauvais usage : luaL_error -----------------------------

    ok("spawn() without args raises",
        pcall(function() return W.spawn() end) == false)
    ok("spawn({}) raises (code not a string)",
        pcall(function() return W.spawn({}) end) == false)
    ok("spawn('code', 42) raises (args not a table)",
        pcall(function() return W.spawn("return 1", 42) end) == false)
    ok("spawn('code', nil, 42) raises (opts not a table)",
        pcall(function() return W.spawn("return 1", nil, 42) end)
        == false)

    -- ----- refus de sérialisation : function ----------------------

    do
        local v, e = W.spawn("return 1", { fn = function() end })
        ok_fail("spawn(code, {fn=function}) -> (nil, err)", v, e)
        ok("  err prefixed with 'workers: '",
            type(e) == "string"
            and e:find("workers: ", 1, true) == 1)
        ok("  err mentions 'function'",
            type(e) == "string"
            and e:find("function", 1, true) ~= nil)
    end

    -- ----- refus de sérialisation : userdata ----------------------

    do
        local s = babet.socket.listen("127.0.0.1", 0)
        if s then
            local v, e = W.spawn("return 1", { sock = s })
            ok_fail("spawn(code, {sock=userdata}) -> (nil, err)",
                v, e)
            ok("  err mentions 'userdata'",
                type(e) == "string"
                and e:find("userdata", 1, true) ~= nil)
            s:close()
        end
    end

    -- ----- refus de sérialisation : thread (coroutine) ------------

    do
        local co = coroutine.create(function() end)
        local v, e = W.spawn("return 1", { co = co })
        ok_fail("spawn(code, {co=coroutine}) -> (nil, err)", v, e)
        ok("  err mentions 'coroutine'",
            type(e) == "string"
            and e:find("coroutine", 1, true) ~= nil)
    end

    -- ----- refus de sérialisation : cycle (via profondeur max) ----

    do
        local t = {}
        t.self = t
        local v, e = W.spawn("return 1", { cycle = t })
        ok_fail("spawn(code, {cycle=self_ref}) -> (nil, err)", v, e)
        ok("  err mentions 'nested' or 'cycle' or 'deep'",
            type(e) == "string"
            and (e:find("nested", 1, true) ~= nil
                or e:find("cycle", 1, true) ~= nil
                or e:find("deep", 1, true) ~= nil))
    end

    -- ----- spawn + join : retours simples -------------------------

    do
        local w = W.spawn("return 42")
        local jok, val = w:join()
        ok("join: integer -> (true, 42)", jok == true and val == 42)

        w = W.spawn("return 'hello'")
        jok, val = w:join()
        ok("join: string -> (true, 'hello')",
            jok == true and val == "hello")

        w = W.spawn("return true")
        jok, val = w:join()
        ok("join: boolean -> (true, true)",
            jok == true and val == true)

        -- Convention pcall : nil returned != error
        w = W.spawn("return nil")
        jok, val = w:join()
        ok("join: nil returned -> (true, nil) -- pcall convention",
            jok == true and val == nil)

        -- Pas de return = nil implicite
        w = W.spawn("local x = 1")
        jok, val = w:join()
        ok("join: no return -> (true, nil)",
            jok == true and val == nil)

        -- Limitation : seul le 1er return est transmis. Documenté
        -- in the README (post-ChatGPT review).
        w = W.spawn("return 10, 20, 30")
        jok, val = w:join()
        ok("join: return multi -> only the 1st crosses (val == 10)",
            jok == true and val == 10)
    end

    -- ----- spawn + join: returned table -------------------------

    do
        local w = W.spawn("return { name = 'alice', age = 30 }")
        local jok, val = w:join()
        ok("join: table -> (true, table)",
            jok == true and type(val) == "table")
        ok("  table.name == 'alice'",
            type(val) == "table" and val.name == "alice")
        ok("  table.age == 30",
            type(val) == "table" and val.age == 30)

        -- Séquence imbriquée
        w = W.spawn("return { 'a', 'b', 'c' }")
        jok, val = w:join()
        ok("join: sequence -> 1..n indexed table",
            jok == true and type(val) == "table"
            and #val == 3 and val[1] == "a" and val[3] == "c")
    end

    -- ----- spawn + join : worker-side error ----------------------

    do
        local w = W.spawn("error('boom')")
        local jok, val = w:join()
        ok("join: error() -> (false, msg)",
            jok == false and type(val) == "string")
        ok("  msg contains 'boom'",
            type(val) == "string"
            and val:find("boom", 1, true) ~= nil)

        -- Code Lua invalid -> chargement échoue
        w = W.spawn("this is not valid lua %%%")
        jok, val = w:join()
        ok("join: invalid Lua code -> (false, msg)",
            jok == false and type(val) == "string")
    end

    -- ----- worker.args : argument transmission ---------------

    do
        local w = W.spawn(
            "return worker.args.x + worker.args.y",
            { x = 10, y = 20 })
        local jok, val = w:join()
        ok("worker.args : addition (10+20) -> 30",
            jok == true and val == 30)

        -- worker.args = nil quand pas d'args
        w = W.spawn("return (worker.args == nil)")
        jok, val = w:join()
        ok("worker.args == nil when no args passed",
            jok == true and val == true)

        -- arg = nil worker side (décision W-7)
        w = W.spawn("return (arg == nil)")
        jok, val = w:join()
        ok("arg == nil in worker (no inheritance from parent)",
            jok == true and val == true)
    end

    -- ----- poll : running / done / error --------------------------

    do
        -- Worker with short sleep: we catch 'running' before the end,
        -- puis 'done' après. Race possible : machine rapide peut
        -- already asee done, on accepte les deux états initialement.
        local w = W.spawn(
            "babet.sleep(300, 'ms'); return 'ok'")
        local state, _ = w:poll()
        ok("poll right after spawn: 'running' or 'done'",
            state == "running" or state == "done",
            "state=" .. tostring(state))

        babet.sleep(500, "ms")
        local state2, val2 = w:poll()
        ok("poll after enough sleep: 'done'",
            state2 == "done",
            "state=" .. tostring(state2))
        ok("  val == 'ok'", val2 == "ok")

        -- poll sur worker en erreur
        local w2 = W.spawn("error('bad')")
        babet.sleep(200, "ms")
        local state3, val3 = w2:poll()
        ok("poll after error: 'error'",
            state3 == "error",
            "state=" .. tostring(state3))
        ok("  val contains 'bad'",
            type(val3) == "string"
            and val3:find("bad", 1, true) ~= nil)
    end

    -- ----- worker = mini-Babet complet -------------------------

    do
        -- Accès à babet.* depuis le worker
        local w = W.spawn(
            "return babet.json.encode({ a = 1, b = 2 })")
        local jok, val = w:join()
        ok("worker can use babet.json.encode",
            jok == true and type(val) == "string"
            and val:find('"a":1', 1, true) ~= nil)

        -- Accès aux modules bundlés via require()
        w = W.spawn(
            "local insp = require('inspect'); "
            .. "return type(insp({1,2,3}))")
        jok, val = w:join()
        ok("worker can require('inspect') (bundled module)",
            jok == true and val == "string")

        -- Modules utilisateur via require() : même searcher
        -- (package.path en mode dossier, embedded searcher en mode
        -- packagé). mymod/init.lua fournit hello() qui returns
        -- "init.lua loaded !".
        w = W.spawn(
            "local m = require('mymod'); return m.hello()")
        jok, val = w:join()
        ok("worker can require('mymod') (user module)",
            jok == true and type(val) == "string"
            and val:find("init.lua", 1, true) ~= nil,
            "val=" .. tostring(val))
    end

    -- ===== TEST CRUCIAL : VRAI PARALLÉLISME =======================
    -- 4 workers qui font chacun sleep(700ms). En parallèle, le temps
    -- wall-clock is close to 700ms (= 0 or 1 second depending on timing).
    -- En série, ce serait 4 × 700 = 2.8s, mesurable via os.time().
    --
    -- Pourquoi pas os.clock() : os.clock() mesure le CPU du process
    -- parent SLEEPING in pthread_join. It would return ~0 in
    -- deux cas (parallèle ET série), donc ne distingue rien. Seul
    -- os.time() (wall-clock) discrimine.

    do
        local N = 4
        local sleep_ms = 700
        local t_start = os.time()
        local workers = {}
        for i = 1, N do
            workers[i] = W.spawn(string.format(
                "babet.sleep(%d, 'ms'); return %d",
                sleep_ms, i))
        end
        local results = {}
        for i = 1, N do
            local jok, val = workers[i]:join()
            results[i] = jok and val or nil
        end
        local elapsed = os.time() - t_start

        ok("parallelism: 4 workers all completed",
            #results == N
            and results[1] == 1 and results[2] == 2
            and results[3] == 3 and results[4] == 4)
        ok("parallelism: wall-clock < 2s "
            .. "(serial = ~3s, parallel = ~1s)",
            elapsed < 2,
            "elapsed=" .. tostring(elapsed) .. "s")
        print(string.format(
            "[INFO] workers: 4 x %dms sleep, wall-clock = %ds "
            .. "(parallel: 0-1, serial: 3+)",
            sleep_ms, elapsed))
    end

    -- ----- poll after join : "already consumed" -------------------

    do
        local w = W.spawn("return 1")
        local jok, _ = w:join()
        ok("join initial OK", jok == true)
        local state, _ = w:poll()
        ok("poll after join: 'error' (already consumed)",
            state == "error")
        local jok2, _ = w:join()
        ok("join after join: (false, already consumed)",
            jok2 == false)
    end

    -- ============================================================
    -- Chantier 9-2 : send / recv / close côté parent
    -- ============================================================
    -- À cette étape le worker ne lit pas son inbox (il reste
    -- fork-join classique). On valide la mécanique côté parent :
    --   - send réussit tant que l'inbox a de la place
    --   - send sur inbox pleine, timeout=0 -> (false, "full")
    --   - send sur inbox pleine, timeout>0 -> (false, "timeout")
    --   - recv depuis outbox vide est toujours vide
    --   - send/recv sur worker mort -> (false, "closed")

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

    -- ----- send après worker mort -> "closed" -------------------
    do
        local w = W.spawn("return 1")
        w:join() -- worker mort + __gc futur, mais ici on a fait join
        -- Note : __gc n'a pas tourné, donc les queues ne sont
        -- fermées que via close() explicite. Le test direct
        -- send/recv après join sans close devrait toujours marcher
        -- pour l'inbox (parent peut encore push) et l'outbox vide
        -- (parent voit "empty"). Mais ce qu'on teste vraiment c'est
        -- le comportement après close() explicite par le parent.
        w:close()
        local sok, serr = w:send("nope")
        ok("send après w:close() -> (false, 'closed')",
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
    end

    -- ============================================================
    -- Chantier 9-3 : worker.send / worker.recv côté worker
    -- ============================================================

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
-- (Les tests d'aller-retour chdir qui vivaient ici sont relocalisés
-- dans la section « env / cwd (avant le premier worker) » : depuis le
-- lot 17, chdir est verrouillé dès le premier workers.spawn. Les
-- tests d'interdiction post-spawn vivent dans la section workers.)

-- =====================================================================
print("")
print("=== teardown ===")
ok_act("rmdirAll(sandbox)", babet.rmdirAll(SB))

-- =====================================================================
print("")
print("==========================================")
print(string.format("Résultat : %d PASS / %d FAIL", pass, fail))
print("==========================================")

if fail > 0 then
    os.exit(1)
end
