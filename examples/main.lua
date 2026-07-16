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

-- erreur Lua attendue (validation stricte d'un argument)
local function ok_raises(name, fn, needle)
    local call_ok, err = pcall(fn)
    local good = call_ok == false and type(err) == "string"
    if good and needle then
        good = err:find(needle, 1, true) ~= nil
    end
    ok(name, good, tostring(err))
end

-- --- setup -----------------------------------------------------------
local startDir, sderr = babet.currentDir()
if not startDir then
    print("FATAL: currentDir() a échoué: " .. tostring(sderr))
    os.exit(1)
end

local SB = "_babet_selftest"
local function sb(name) return SB .. "/" .. name end

-- nettoyage préventif d'un éventuel run précédent. Depuis le LOT 6,
-- rmdirAll est strictement réservé aux vrais dossiers ; un ancien fichier ou
-- symlink portant le nom du sandbox est donc nettoyé avec remove().
local cleanup_ok = babet.rmdirAll(SB)
if cleanup_ok ~= true then
    babet.remove(SB)
end

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

    -- Alias camelCase canoniques (décision de nommage post-v2.1.1) :
    -- isFile/isDir/symlinkAttr sont les noms canoniques, les
    -- minuscules restent des alias dépréciés de la MÊME fonction C.
    ok("isFile (canonique) == isfile (alias)",
        babet.isFile(sb("probe.txt")) == true
        and babet.isFile(sb("probe.txt")) == babet.isfile(sb("probe.txt"))
        and babet.isFile(SB) == false)
    ok("isDir (canonique) == isdir (alias)",
        babet.isDir(SB) == true
        and babet.isDir(SB) == babet.isdir(SB)
        and babet.isDir(sb("probe.txt")) == false)

    for _, entry in ipairs({
        { "fileExists", babet.fileExists },
        { "isFile", babet.isFile },
        { "isDir", babet.isDir },
    }) do
        ok_raises("LOT 3 " .. entry[1] .. ": NUL path rejected",
            function() return entry[2](sb("probe.txt") .. "\0ignored") end,
            "NUL")
    end
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

    ok_raises("LOT 11 listFiles path is a strict string",
        function() return babet.listFiles(42) end,
        "string")
    ok_raises("LOT 11 listFiles recursive is a strict boolean",
        function() return babet.listFiles(SB, 1) end,
        "boolean")
    ok_raises("LOT 11 listFiles rejects excess arguments",
        function() return babet.listFiles(SB, false, "extra") end,
        "one or two arguments")

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

    for _, entry in ipairs({
        { "fileSize", babet.fileSize },
        { "getBasename", babet.getBasename },
        { "getExtension", babet.getExtension },
        { "getFilename", babet.getFilename },
        { "getPath", babet.getPath },
        { "listFiles", babet.listFiles },
        { "getMode", babet.getMode },
        { "getAttributes", babet.getAttributes },
    }) do
        ok_raises("LOT 3 " .. entry[1] .. ": NUL path rejected",
            function() return entry[2](sb("probe.txt") .. "\0ignored") end,
            "NUL")
    end

    local joined, joined_err = babet.joinPath("a", "b\0ignored")
    ok_fail("LOT 3 joinPath: NUL segment rejected", joined, joined_err)
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

        ok_raises("LOT 3 " .. fn .. ": NUL path rejected",
            function() return babet[fn](sb("probe.txt") .. "\0ignored") end,
            "NUL")
    end

    -- LOT 6 : les hash OpenSSL ne doivent jamais finaliser un digest après
    -- une erreur d'E/S, ni lire indéfiniment un pseudo-fichier.
    local crypto_hashers = {
        "md5sum", "sha1sum", "sha256sum", "sha512sum", "sha384sum",
        "sha3_256sum", "sha3_384sum", "sha3_512sum",
        "blake2b512sum", "blake2s256sum",
    }
    for _, fn in ipairs(crypto_hashers) do
        local v, e = babet[fn](SB)
        ok_fail("LOT 6 " .. fn .. ": directory rejected", v, e)
        ok("  directory error mentions regular file",
            type(e) == "string" and e:find("regular file", 1, true) ~= nil,
            tostring(e))
    end

    do
        local v, e = babet.sha256sum("/dev/zero")
        ok_fail("LOT 6 sha256sum: character device rejected", v, e)
        ok("  device error mentions regular file",
            type(e) == "string" and e:find("regular file", 1, true) ~= nil,
            tostring(e))

        v, e = babet.sha256sum("/proc/self/mem")
        ok_fail("LOT 6 sha256sum: read error is not a fake digest", v, e)
        ok("  read/open error is explicit",
            type(e) == "string"
            and (e:find("cannot read", 1, true)
                or e:find("cannot open", 1, true)),
            tostring(e))

        babet.exec("ln", { "-s", "probe.txt", sb("hash_link") })
        local direct, direct_err = babet.sha256sum(sb("probe.txt"))
        local via_link, link_err = babet.sha256sum(sb("hash_link"))
        ok("LOT 6 checksums keep symlinks to regular files supported",
            direct_err == nil and link_err == nil and direct == via_link,
            "direct=" .. tostring(direct) .. " link=" .. tostring(via_link)
                .. " err=" .. tostring(link_err))
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

        s, e = J.encode(nil)
        ok("encode(nil) == 'null'", s == "null" and e == nil,
            "s=" .. tostring(s))
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

        v, e = J.decode("9223372036854775808")
        ok("decode(unsigned > math.maxinteger) -> float",
            e == nil and math.type(v) == "float")
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

        s, e = J.encode(doc, { indent = 0 })
        ok("indent=0 -> formatted output with line breaks",
            e == nil and s:find("\n", 1, true) ~= nil)

        s, e = J.encode({ a = 1 }, { pretty = true })
        ok("unknown encode options are ignored (pretty is not supported)",
            e == nil and s:find("\n", 1, true) == nil)

        local indent_ok, indent_err = pcall(function()
            return J.encode(doc, { indent = 257 })
        end)
        ok("LOT 3 json: indent > 256 rejected cleanly",
            indent_ok == false and type(indent_err) == "string"
            and indent_err:find("too large", 1, true) ~= nil,
            tostring(indent_err))

        local huge_indent_ok, huge_indent_err = pcall(function()
            return J.encode(doc, { indent = math.maxinteger })
        end)
        ok("LOT 3 json: huge indent rejected before narrowing",
            huge_indent_ok == false and type(huge_indent_err) == "string"
            and huge_indent_err:find("too large", 1, true) ~= nil,
            tostring(huge_indent_err))
    end

    -- --- chaînes UTF-8 et binary-safe ------------------------------
    do
        local original = "café ☕ — naïve"
        local s = J.encode(original)
        local v, e = J.decode(s)
        ok("UTF-8 round-trip intact", e == nil and v == original,
            "v=" .. tostring(v))

        local with_nul = "a\0b"
        s, e = J.encode(with_nul)
        v = J.decode(s)
        ok("string with embedded NUL round-trips",
            e == nil and v == with_nul, "s=" .. tostring(s))

        s, e = J.encode({ [with_nul] = with_nul })
        local obj = J.decode(s)
        ok("object key with embedded NUL round-trips",
            e == nil and obj[with_nul] == with_nul,
            "s=" .. tostring(s))

        v, e = J.encode("\255")
        ok_fail("encode(invalid UTF-8) -> (nil, err)", v, e)

        v, e = J.decode('"' .. "\255" .. '"')
        ok_fail("decode(invalid UTF-8 string) -> (nil, err)", v, e)
    end

    -- --- erreurs : (nil, err), jamais d'exception Lua --------------
    do
        local v, e = J.encode({ [1] = "a", foo = "b" })
        ok_fail("encode mixed keys -> (nil, err)", v, e)

        v, e = J.encode({ [1] = "a", [3] = "c" })
        ok_fail("encode sparse array -> (nil, err)", v, e)

        v, e = J.encode({ [0] = "zero" })
        ok_fail("encode array key 0 -> (nil, err)", v, e)

        v, e = J.encode({ [1.5] = "float key" })
        ok_fail("encode float table key -> (nil, err)", v, e)

        v, e = J.encode({ [true] = "boolean key" })
        ok_fail("encode boolean table key -> (nil, err)", v, e)

        v, e = J.encode(0 / 0)
        ok_fail("encode(NaN) -> (nil, err)", v, e)

        v, e = J.encode(math.huge)
        ok_fail("encode(Infinity) -> (nil, err)", v, e)

        v, e = J.encode(print)
        ok_fail("encode(function) -> (nil, err)", v, e)

        v, e = J.decode("{ pas du json")
        ok_fail("decode(invalid JSON) -> (nil, err)", v, e)
        ok("decode parse error includes line and column",
            type(e) == "string"
            and e:find("line", 1, true) ~= nil
            and e:find("column", 1, true) ~= nil,
            tostring(e))

        v, e = J.decode("null true")
        ok_fail("decode(trailing data) -> (nil, err)", v, e)

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

        -- seuls les arrays vides décodés sont marqués. Un array non vide
        -- puis vidé redevient ambigu et doit être re-marqué explicitement.
        local emptied = J.decode("[1]")
        emptied[1] = nil
        ok("decoded non-empty array emptied later -> '{}'",
            J.encode(emptied) == "{}")
        ok("as_array restores [] after emptying a decoded array",
            J.encode(J.as_array(emptied)) == "[]")
    end

    -- --- objets : doublons -------------------------------------------
    do
        local obj, e = J.decode('{"x":1,"x":2}')
        ok("duplicate JSON object key: last value wins",
            e == nil and obj.x == 2)
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

        -- le marquage est la métatable et remplace celle déjà présente
        local previous_mt = {}
        local with_mt = setmetatable({}, previous_mt)
        J.as_array(with_mt)
        ok("as_array replaces an existing metatable",
            getmetatable(with_mt) ~= previous_mt
            and J.encode(with_mt) == "[]")

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

    -- --- validation stricte des arguments ----------------------------
    do
        ok("decode(number) raises instead of coercing to string",
            pcall(function() J.decode(42) end) == false)
        ok("encode() without a value raises",
            pcall(function() J.encode() end) == false)
        ok("encode(value, opts, extra) raises",
            pcall(function() J.encode(1, nil, "extra") end) == false)
        ok("encode(value, nil) remains valid",
            J.encode(1, nil) == "1")
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

        -- Restauration avant les assertions pour garantir le nettoyage.
        babet.setMode(locked_dir, "755")
        babet.rmdirAll(iter_err_dir)

        ok_fail("LOT 5B FileIterator preserves traversal errors",
            bad_it, bad_it_err)
        ok("  iterator error identifies a traversal failure",
            type(bad_it_err) == "string"
            and (bad_it_err:find("cannot continue", 1, true) ~= nil
                or bad_it_err:find("Permission denied", 1, true) ~= nil),
            "err=" .. tostring(bad_it_err))
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
print("")
print("=== process pipelines ===")

local function pipeline_test_pid_is_running(pid)
    local probe = babet.exec("ps", { "-o", "stat=", "-p", tostring(pid) })
    if type(probe) ~= "table" or probe.code ~= 0 then
        return false
    end
    local state = probe.stdout:match("%S+")
    return state ~= nil and state:sub(1, 1) ~= "Z"
end

local function pipeline_test_read_pid(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local pid = tonumber(file:read("*l"))
    file:close()
    return pid
end

do
    ok("babet.pipeline is a function", type(babet.pipeline) == "function")
    ok("pipeline without commands raises",
        pcall(function() babet.pipeline() end) == false)
    ok("pipeline commands must be a table",
        pcall(function() babet.pipeline("bad") end) == false)
    ok_raises("pipeline rejects extra arguments",
        function() babet.pipeline({}, {}, true) end)

    local max_stages = {}
    for i = 1, 32 do max_stages[i] = { "true" } end
    local r, e = babet.pipeline(max_stages)
    ok("pipeline accepts exactly 32 stages",
        type(r) == "table" and e == nil and #r.stages == 32)
    local too_many = {}
    for i = 1, 33 do too_many[i] = { "true" } end
    r, e = babet.pipeline(too_many)
    ok_fail("pipeline rejects more than 32 stages", r, e)
    r, e = babet.pipeline({ [1] = { "true" }, [3] = { "true" } })
    ok_fail("pipeline commands must be dense", r, e)
    r, e = babet.pipeline({ "true", { "cat" } })
    ok_fail("pipeline stage must be a table", r, e)
    r, e = babet.pipeline({ { "true", {}, {}, "extra" }, { "cat" } })
    ok_fail("pipeline stage rejects extra fields", r, e)
    r, e = babet.pipeline({ { 42 }, { "cat" } })
    ok_fail("pipeline command must be a string", r, e)
    r, e = babet.pipeline({ { "" }, { "cat" } })
    ok_fail("pipeline command must not be empty", r, e)
    r, e = babet.pipeline({ { "echo", "bad" }, { "cat" } })
    ok_fail("pipeline args must be a table", r, e)
    r, e = babet.pipeline({ { "echo", { true } }, { "cat" } })
    ok_fail("pipeline args contain strings only", r, e)
    r, e = babet.pipeline({ { "echo", { "x\0bad" } }, { "cat" } })
    ok_fail("pipeline argument rejects NUL", r, e)

    r, e = babet.pipeline({ { "echo" }, { "cat" } }, "bad")
    ok_fail("pipeline opts must be a table", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { cwd = 42 })
    ok_fail("pipeline cwd must be a string", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { cwd = "/tmp\0bad" })
    ok_fail("pipeline cwd rejects NUL", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = "bad" })
    ok_fail("pipeline env must be a table", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { [1] = "bad" } })
    ok_fail("pipeline env keys must be strings", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { BAD = true } })
    ok_fail("pipeline env values must be strings", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { [""] = "x" } })
    ok_fail("pipeline env key must not be empty", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { ["A=B"] = "x" } })
    ok_fail("pipeline env key rejects '='", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { ["A\0B"] = "x" } })
    ok_fail("pipeline env key rejects NUL", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { A = "x\0y" } })
    ok_fail("pipeline env value rejects NUL", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { stdin = true })
    ok_fail("pipeline stdin must be a string", r, e)

    for _, invalid in ipairs({ 0, -1, math.huge, -math.huge }) do
        r, e = babet.pipeline({ { "echo" }, { "cat" } }, { timeout = invalid })
        ok_fail("pipeline rejects invalid timeout " .. tostring(invalid), r, e)
    end
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { timeout = 0 / 0 })
    ok_fail("pipeline rejects NaN timeout", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, {
        timeout = 1000000000001,
    })
    ok_fail("pipeline rejects timeout above 10^12 seconds", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { max_output = 1.5 })
    ok_fail("pipeline max_output must be an integer", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { max_output = 0 })
    ok_fail("pipeline rejects max_output zero", r, e)
    r, e = babet.pipeline({ { "printf", { "x" } }, { "cat" } }, {
        max_output = 2147483648,
    })
    ok("pipeline accepts max_output at 2 GiB boundary",
        type(r) == "table" and e == nil and r.stdout == "x")
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { max_output = 2147483649 })
    ok_fail("pipeline rejects max_output above 2 GiB", r, e)
    r, e = babet.pipeline({ { "echo", {}, { cwd = 42 } }, { "cat" } })
    ok_fail("pipeline stage cwd must be a string", r, e)
    r, e = babet.pipeline({ { "echo", {}, { env = "bad" } }, { "cat" } })
    ok_fail("pipeline stage env must be a table", r, e)

    r, e = babet.pipeline({ { "cat" } })
    ok_fail("pipeline requires at least two stages", r, e)

    r, e = babet.pipeline({ { "printf", { "hello\nworld\n" } }, { "grep", { "world" } } })
    ok("pipeline basic stdout", type(r) == "table" and e == nil
        and r.stdout == "world\n" and r.code == 0
        and r.all_succeeded == true and r.failed_index == nil
        and #r.stages == 2 and #r.stderr == 2)

    r, e = babet.pipeline({ { "cat" }, { "tr", { "a-z", "A-Z" } } }, {
        stdin = "abc\0def\n",
    })
    ok("pipeline binary stdin/stdout", type(r) == "table" and e == nil
        and r.stdout == "ABC\0DEF\n")

    r, e = babet.pipeline({
        { "sh", { "-c", "printf first 1>&2; printf x" } },
        { "sh", { "-c", "cat; printf second 1>&2" } },
    })
    ok("pipeline separates stderr per stage", type(r) == "table" and e == nil
        and r.stdout == "x" and r.stderr[1] == "first"
        and r.stderr[2] == "second")

    r, e = babet.pipeline({
        { "sh", { "-c", "exit 7" } },
        { "cat" },
    })
    ok("pipeline exposes intermediate failure", type(r) == "table" and e == nil
        and r.code == 0 and r.all_succeeded == false
        and r.failed_index == 1 and r.stages[1].code == 7
        and r.stages[2].code == 0)

    r, e = babet.pipeline({
        { "printf", { "x\n" } },
        { "sh", { "-c", "cat >/dev/null; exit 5" } },
    })
    ok("pipeline global code is last stage code", type(r) == "table" and e == nil
        and r.code == 5 and r.failed_index == 2)

    r, e = babet.pipeline({
        { "pwd", {}, { cwd = "/tmp" } },
        { "cat" },
    })
    ok("pipeline per-stage cwd", type(r) == "table" and e == nil
        and r.stdout == "/tmp\n")

    r, e = babet.pipeline({
        { "sh", { "-c", "printf %s \"$BABET_PIPE_VAR\"" }, {
            env = { BABET_PIPE_VAR = "local" },
        } },
        { "cat" },
    }, { env = { BABET_PIPE_VAR = "global" } })
    ok("pipeline local env overrides global env", type(r) == "table" and e == nil
        and r.stdout == "local")

    local pipeline_path_dir = sb("pipeline_path")
    assert(babet.mkdir(pipeline_path_dir))
    local pipeline_path_tool = pipeline_path_dir .. "/private-tool"
    local pipeline_path_file = assert(io.open(pipeline_path_tool, "w"))
    pipeline_path_file:write("#!/bin/sh\nprintf pipeline-path")
    pipeline_path_file:close()
    assert(babet.setMode(pipeline_path_tool, "755"))
    r, e = babet.pipeline({ { "private-tool" }, { "cat" } }, {
        env = { PATH = pipeline_path_dir },
    })
    ok_fail("pipeline lookup does not use opts.env.PATH", r, e)
    r, e = babet.pipeline({ { pipeline_path_tool }, { "cat" } }, {
        env = { PATH = pipeline_path_dir },
    })
    ok("pipeline explicit command path uses overridden child environment",
        type(r) == "table" and e == nil and r.stdout == "pipeline-path")

    r, e = babet.pipeline({
        { "printf", { "abcdef" } },
        { "cat" },
    }, { max_output = 3 })
    ok("pipeline stdout truncation", type(r) == "table" and e == nil
        and r.stdout == "abc" and r.stdout_truncated == true)

    r, e = babet.pipeline({
        { "sh", { "-c", "printf abcdef 1>&2" } },
        { "cat" },
    }, { max_output = 3 })
    ok("pipeline stderr truncation", type(r) == "table" and e == nil
        and r.stderr[1] == "abc" and r.stderr_truncated[1] == true)

    local large = string.rep("pipeline-large-data\n", 20000)
    r, e = babet.pipeline({ { "cat" }, { "cat" }, { "cat" } }, {
        stdin = large,
        max_output = #large + 1,
        timeout = 10,
    })
    ok("pipeline large data has no deadlock", type(r) == "table" and e == nil
        and r.stdout == large and r.timed_out == false)

    r, e = babet.pipeline({
        { "sh", { "-c", "sleep 30 & wait" } },
        { "cat" },
    }, { timeout = 0.3 })
    ok("pipeline timeout kills all process groups", type(r) == "table" and e == nil
        and r.timed_out == true and r.all_succeeded == false)

    r, e = babet.pipeline({
        { "yes" },
        { "head", { "-n", "1" } },
    }, { timeout = 5, max_output = 1024 })
    ok("pipeline handles SIGPIPE from upstream", type(r) == "table" and e == nil
        and r.stdout == "y\n" and r.code == 0
        and r.stages[1].signaled == true)

    r, e = babet.pipeline({ { "printf", { "x" } }, { "__babet_missing_pipeline__" } })
    ok_fail("pipeline launch failure is returned", r, e)

    r, e = babet.pipeline({ { "pwd" }, { "cat" } }, { cwd = "/does/not/exist" })
    ok_fail("pipeline invalid global cwd is returned", r, e)

    r, e = babet.pipeline({ { "echo", { "x" } }, { "cat" } }, { unknown = true })
    ok_fail("pipeline rejects unknown global option", r, e)

    r, e = babet.pipeline({ { "echo", { "x" }, { unknown = true } }, { "cat" } })
    ok_fail("pipeline rejects unknown stage option", r, e)

    r, e = babet.pipeline({ { "echo", { [2] = "x" } }, { "cat" } })
    ok_fail("pipeline args must be dense", r, e)

    r, e = babet.pipeline({ { "echo\0bad" }, { "cat" } })
    ok_fail("pipeline command rejects NUL", r, e)

    r, e = babet.pipeline({ { "printf", { "ok" } }, { "cat" } })
    ok("pipeline default result exposes complete non-truncated shape",
        type(r) == "table" and e == nil and r.stdout == "ok"
        and r.timed_out == false and r.stdout_truncated == false
        and #r.stderr_truncated == 2
        and r.stderr_truncated[1] == false
        and r.stderr_truncated[2] == false
        and r.stages[1].launched == true
        and r.stages[1].exited == true
        and r.stages[1].signaled == false
        and r.stages[1].signal == nil)

    local sync_pid_path = sb("pipeline_sync_descendant.pid")
    os.remove(sync_pid_path)
    r, e = babet.pipeline({
        { "sh", { "-c",
            "sleep 30 >/dev/null 2>&1 & echo $! > " .. sync_pid_path .. "; exit 0" } },
        { "cat" },
    }, { timeout = 5 })
    local sync_descendant_pid = pipeline_test_read_pid(sync_pid_path)
    local sync_descendant_running = sync_descendant_pid
        and pipeline_test_pid_is_running(sync_descendant_pid)
    ok("pipeline normal completion cleans background descendants",
        type(r) == "table" and e == nil and sync_descendant_pid ~= nil
        and not sync_descendant_running,
        "pid=" .. tostring(sync_descendant_pid))
    if sync_descendant_running then
        babet.exec("kill", { "-9", tostring(sync_descendant_pid) })
    end
end

-- =====================================================================
print("")
print("=== pipeline streaming ===")

do
    local function drain_pipeline(pipeline, stage_count, timeout)
        local stdout_chunks = {}
        local stderr_chunks = {}
        local stderr_closed = {}
        for i = 1, stage_count do
            stderr_chunks[i] = {}
            stderr_closed[i] = false
        end
        local stdout_closed = false
        local deadline = babet.monotonic() + (timeout or 5)

        while not stdout_closed do
            local data, err = pipeline:read_stdout(65536, 0.01)
            if data then
                stdout_chunks[#stdout_chunks + 1] = data
            elseif err == "closed" then
                stdout_closed = true
            elseif err ~= "timeout" then
                return nil, nil, err
            end

            for i = 1, stage_count do
                if not stderr_closed[i] then
                    data, err = pipeline:read_stderr(i, 65536, 0)
                    if data then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = data
                    elseif err == "closed" then
                        stderr_closed[i] = true
                    elseif err ~= "timeout" then
                        return nil, nil, err
                    end
                end
            end

            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local pending = true
        while pending do
            pending = false
            for i = 1, stage_count do
                if not stderr_closed[i] then
                    pending = true
                    local data, err = pipeline:read_stderr(i, 65536, 0.01)
                    if data then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = data
                    elseif err == "closed" then
                        stderr_closed[i] = true
                    elseif err ~= "timeout" then
                        return nil, nil, err
                    end
                end
            end
            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local stderr_result = {}
        for i = 1, stage_count do
            stderr_result[i] = table.concat(stderr_chunks[i])
        end
        return table.concat(stdout_chunks), stderr_result, nil
    end

    local function write_all_and_drain(pipeline, data, stage_count, timeout)
        local stdout_chunks = {}
        local stderr_chunks = {}
        local stderr_closed = {}
        for i = 1, stage_count do
            stderr_chunks[i] = {}
            stderr_closed[i] = false
        end
        local stdout_closed = false
        local stdin_closed = false
        local offset = 1
        local deadline = babet.monotonic() + (timeout or 8)

        while not stdout_closed do
            if offset <= #data then
                local last = math.min(offset + 32767, #data)
                local written, err = pipeline:write(data:sub(offset, last), 0.01)
                if written then
                    if written == 0 then
                        return nil, nil, "zero-byte write"
                    end
                    offset = offset + written
                elseif err ~= "timeout" then
                    return nil, nil, err
                end
            elseif not stdin_closed then
                local closed, close_err = pipeline:close_stdin()
                if not closed then
                    return nil, nil, close_err
                end
                stdin_closed = true
            end

            local chunk, read_err = pipeline:read_stdout(65536, 0)
            if chunk then
                stdout_chunks[#stdout_chunks + 1] = chunk
            elseif read_err == "closed" then
                stdout_closed = true
            elseif read_err ~= "timeout" then
                return nil, nil, read_err
            end

            for i = 1, stage_count do
                if not stderr_closed[i] then
                    chunk, read_err = pipeline:read_stderr(i, 65536, 0)
                    if chunk then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = chunk
                    elseif read_err == "closed" then
                        stderr_closed[i] = true
                    elseif read_err ~= "timeout" then
                        return nil, nil, read_err
                    end
                end
            end

            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local pending = true
        while pending do
            pending = false
            for i = 1, stage_count do
                if not stderr_closed[i] then
                    pending = true
                    local chunk, read_err =
                        pipeline:read_stderr(i, 65536, 0.01)
                    if chunk then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = chunk
                    elseif read_err == "closed" then
                        stderr_closed[i] = true
                    elseif read_err ~= "timeout" then
                        return nil, nil, read_err
                    end
                end
            end
            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local stderr_result = {}
        for i = 1, stage_count do
            stderr_result[i] = table.concat(stderr_chunks[i])
        end
        return table.concat(stdout_chunks), stderr_result, nil
    end

    ok("babet.spawnPipeline is a function",
        type(babet.spawnPipeline) == "function")
    ok_raises("spawnPipeline without commands raises",
        function() babet.spawnPipeline() end)
    ok_raises("spawnPipeline commands must be a table",
        function() babet.spawnPipeline("bad") end)
    ok_raises("spawnPipeline rejects extra arguments",
        function() babet.spawnPipeline({}, {}, true) end)

    local p, e = babet.spawnPipeline({ { "cat" } })
    ok_fail("spawnPipeline requires at least two stages", p, e)

    local too_many = {}
    for i = 1, 33 do too_many[i] = { "true" } end
    p, e = babet.spawnPipeline(too_many)
    ok_fail("spawnPipeline rejects more than 32 stages", p, e)

    p, e = babet.spawnPipeline({ [1] = { "true" }, [3] = { "true" } })
    ok_fail("spawnPipeline commands must be dense", p, e)
    p, e = babet.spawnPipeline({ "true", { "cat" } })
    ok_fail("spawnPipeline stage must be a table", p, e)
    p, e = babet.spawnPipeline({ { "true", {}, {}, "extra" }, { "cat" } })
    ok_fail("spawnPipeline stage rejects extra fields", p, e)
    p, e = babet.spawnPipeline({ { 42 }, { "cat" } })
    ok_fail("spawnPipeline command must be a string", p, e)
    p, e = babet.spawnPipeline({ { "" }, { "cat" } })
    ok_fail("spawnPipeline command must not be empty", p, e)
    p, e = babet.spawnPipeline({ { "echo\0bad" }, { "cat" } })
    ok_fail("spawnPipeline command rejects NUL", p, e)
    p, e = babet.spawnPipeline({ { "echo", "bad" }, { "cat" } })
    ok_fail("spawnPipeline args must be a table", p, e)
    p, e = babet.spawnPipeline({ { "echo", { [2] = "bad" } }, { "cat" } })
    ok_fail("spawnPipeline args must be dense", p, e)
    p, e = babet.spawnPipeline({ { "echo", { true } }, { "cat" } })
    ok_fail("spawnPipeline args contain strings only", p, e)
    p, e = babet.spawnPipeline({ { "echo", { "x\0bad" } }, { "cat" } })
    ok_fail("spawnPipeline argument rejects NUL", p, e)

    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, "bad")
    ok_fail("spawnPipeline opts must be a table", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, { unknown = true })
    ok_fail("spawnPipeline rejects unknown global option", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, { cwd = 42 })
    ok_fail("spawnPipeline cwd must be a string", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        cwd = "/tmp\0bad",
    })
    ok_fail("spawnPipeline cwd rejects NUL", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, { env = "bad" })
    ok_fail("spawnPipeline env must be a table", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { [1] = "bad" },
    })
    ok_fail("spawnPipeline env keys must be strings", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { BABET_BAD = true },
    })
    ok_fail("spawnPipeline env values must be strings", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { [""] = "bad" },
    })
    ok_fail("spawnPipeline env key must not be empty", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { ["A=B"] = "bad" },
    })
    ok_fail("spawnPipeline env key rejects '='", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { ["A\0B"] = "bad" },
    })
    ok_fail("spawnPipeline env key rejects NUL", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { A = "x\0bad" },
    })
    ok_fail("spawnPipeline env value rejects NUL", p, e)

    for _, invalid in ipairs({ "1", 0, -1, 0 / 0, math.huge, 3000000 }) do
        p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
            launch_timeout = invalid,
        })
        ok_fail("spawnPipeline rejects invalid launch_timeout " .. tostring(invalid),
            p, e)
    end

    p, e = babet.spawnPipeline({
        { "echo", {}, { unknown = true } }, { "cat" },
    })
    ok_fail("spawnPipeline rejects unknown stage option", p, e)
    p, e = babet.spawnPipeline({
        { "echo", {}, { cwd = true } }, { "cat" },
    })
    ok_fail("spawnPipeline stage cwd must be a string", p, e)
    p, e = babet.spawnPipeline({
        { "echo", {}, { env = true } }, { "cat" },
    })
    ok_fail("spawnPipeline stage env must be a table", p, e)
    p, e = babet.spawnPipeline({
        { "printf", { "x" } }, { "__babet_missing_spawn_pipeline__" },
    })
    ok("spawnPipeline launch error identifies the failed stage",
        p == nil and type(e) == "string"
        and e:find("stage 2", 1, true) ~= nil, tostring(e))
    p, e = babet.spawnPipeline({ { "pwd" }, { "cat" } }, {
        cwd = "/does/not/exist",
    })
    ok_fail("spawnPipeline invalid cwd is returned", p, e)

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "cat; printf first-err >&2" } },
        { "sh", { "-c", "tr a-z A-Z; printf second-err >&2" } },
    })
    ok("spawnPipeline returns a userdata", p ~= nil and e == nil, tostring(e))
    ok("pipeline userdata tostring is informative",
        tostring(p):find("babet.pipeline_process", 1, true) ~= nil)
    local pids = p:pids()
    ok("pipeline pids() returns one PID per stage",
        type(pids) == "table" and #pids == 2)
    ok("pipeline pids are positive integers",
        math.type(pids[1]) == "integer" and pids[1] > 0
        and math.type(pids[2]) == "integer" and pids[2] > 0)
    ok("pipeline is_running() initially true", p:is_running() == true)
    ok("pipeline is_running(stage) initially true",
        p:is_running(1) == true and p:is_running(2) == true)
    ok_raises("pipeline pids rejects extra arguments",
        function() p:pids(true) end)
    ok_raises("pipeline is_running stage must be an integer",
        function() p:is_running("1") end)
    ok_raises("pipeline is_running rejects stage zero",
        function() p:is_running(0) end)
    ok_raises("pipeline is_running rejects stage above count",
        function() p:is_running(3) end)
    ok_raises("pipeline read_stderr stage must be an integer",
        function() p:read_stderr("1") end)
    ok_raises("pipeline read_stderr rejects stage zero",
        function() p:read_stderr(0) end)
    ok_raises("pipeline read_stderr rejects stage above count",
        function() p:read_stderr(3) end)

    local zero_written, zero_err = p:write("", 0)
    ok("pipeline write empty string returns 0",
        zero_written == 0 and zero_err == nil)
    local binary = "hello\0world"
    local offset = 1
    local write_error
    while offset <= #binary do
        local written
        written, write_error = p:write(binary:sub(offset), 1)
        if not written then break end
        offset = offset + written
    end
    ok("pipeline write accepts binary data",
        offset == #binary + 1 and write_error == nil, tostring(write_error))
    ok_act("pipeline close_stdin succeeds", p:close_stdin())
    ok_act("pipeline close_stdin is idempotent", p:close_stdin())

    local out, errs, stream_err = drain_pipeline(p, 2, 5)
    ok("pipeline stdout is streamed progressively",
        out == "HELLO\0WORLD" and stream_err == nil, tostring(stream_err))
    ok("pipeline stderr stage 1 remains separate",
        errs and errs[1] == "first-err", tostring(errs and errs[1]))
    ok("pipeline stderr stage 2 remains separate",
        errs and errs[2] == "second-err", tostring(errs and errs[2]))
    local result, wait_err = p:wait(2)
    ok("pipeline wait returns a result table",
        type(result) == "table" and wait_err == nil)
    ok("pipeline wait exposes the last-stage code",
        result and result.code == 0)
    ok("pipeline wait exposes all_succeeded",
        result and result.all_succeeded == true
        and result.failed_index == nil)
    ok("pipeline wait exposes every stage status",
        result and #result.stages == 2
        and result.stages[1].code == 0
        and result.stages[2].code == 0)
    local result2, wait_err2 = p:wait(0)
    ok("pipeline wait is idempotent",
        result2 and result2.code == 0 and wait_err2 == nil)
    ok("pipeline is_running() false after wait", p:is_running() == false)
    local eof_data, eof_err = p:read_stdout(1, 0)
    ok("pipeline read_stdout after EOF -> closed",
        eof_data == nil and eof_err == "closed")
    ok_act("pipeline close succeeds", p:close())
    ok_act("pipeline close is idempotent", p:close())
    local closed_write, closed_write_err = p:write("x", 0)
    ok("pipeline write after close -> closed",
        closed_write == nil and closed_write_err == "closed")

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "printf '%s|%s' \"$PWD\" \"$BABET_PIPE_ENV\"" }, {
            cwd = "/tmp",
            env = { BABET_PIPE_ENV = "local" },
        } },
        { "cat" },
    }, {
        cwd = "/",
        env = { BABET_PIPE_ENV = "global" },
    })
    ok("spawnPipeline accepts global and local cwd/env",
        p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("spawnPipeline local cwd/env override global values",
        out == "/tmp|local" and result.code == 0
        and errs[1] == "" and errs[2] == "", tostring(out))
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "exit 7" } }, { "cat" },
    })
    ok("spawnPipeline intermediate-failure fixture",
        p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("pipeline global code remains the last stage code",
        result and result.code == 0)
    ok("pipeline wait exposes intermediate failure",
        result and result.all_succeeded == false
        and result.failed_index == 1
        and result.stages[1].code == 7
        and result.stages[2].code == 0)
    p:close()

    local stream_pid_path = sb("pipeline_stream_descendant.pid")
    os.remove(stream_pid_path)
    p, e = babet.spawnPipeline({
        { "sh", { "-c",
            "sleep 30 >/dev/null 2>&1 & echo $! > " .. stream_pid_path .. "; exit 0" } },
        { "cat" },
    })
    ok("spawnPipeline background-descendant fixture",
        p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result, wait_err = p:wait(2)
    local stream_descendant_pid = pipeline_test_read_pid(stream_pid_path)
    local stream_descendant_running = stream_descendant_pid
        and pipeline_test_pid_is_running(stream_descendant_pid)
    ok("pipeline wait cleans descendants after direct stage exit",
        result and wait_err == nil and stream_descendant_pid ~= nil
        and not stream_descendant_running,
        "pid=" .. tostring(stream_descendant_pid))
    if stream_descendant_running then
        babet.exec("kill", { "-9", tostring(stream_descendant_pid) })
    end
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "sleep 0.3; printf done" } }, { "cat" },
    })
    ok("spawnPipeline delayed-output fixture", p ~= nil and e == nil, tostring(e))
    local t0 = babet.monotonic()
    local no_data, timeout_err = p:read_stdout(16, 0.03)
    local elapsed = babet.monotonic() - t0
    ok("pipeline read_stdout timeout is typed and bounded",
        no_data == nil and timeout_err == "timeout" and elapsed < 0.5,
        "err=" .. tostring(timeout_err) .. " dt=" .. tostring(elapsed))
    local no_wait, no_wait_err = p:wait(0)
    ok("pipeline wait(0) is non-blocking",
        no_wait == nil and no_wait_err == "timeout")
    ok("pipeline wait timeout does not terminate stages",
        p:is_running() == true)
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("pipeline remains usable after read/wait timeouts",
        out == "done" and result.code == 0 and stream_err == nil,
        tostring(stream_err))
    p:close()

    local large = string.rep("stream-pipeline-data\0", 25000)
    p, e = babet.spawnPipeline({ { "cat" }, { "cat" }, { "cat" } })
    ok("spawnPipeline large-stdin fixture", p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = write_all_and_drain(p, large, 3, 10)
    result = p:wait(3)
    ok("pipeline large stdin/stdout has no deadlock",
        out == large and result.code == 0 and stream_err == nil,
        "out=" .. tostring(out and #out) .. " err=" .. tostring(stream_err))
    ok("pipeline large binary transfer preserves byte count",
        out and #out == #large)
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "head -c 131072 /dev/zero >&2; printf x" } },
        { "sh", { "-c", "cat; head -c 131072 /dev/zero >&2" } },
    })
    ok("spawnPipeline large-stderr fixture", p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 8)
    result = p:wait(3)
    ok("pipeline drains stdout while both stderr streams are large",
        out == "x" and result.code == 0 and stream_err == nil,
        tostring(stream_err))
    ok("pipeline drains large stderr from stage 1",
        errs and #errs[1] == 131072, tostring(errs and #errs[1]))
    ok("pipeline drains large stderr from stage 2",
        errs and #errs[2] == 131072, tostring(errs and #errs[2]))
    p:close()

    p, e = babet.spawnPipeline({ { "yes" }, { "head", { "-n", "1" } } })
    ok("spawnPipeline SIGPIPE fixture", p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("pipeline handles premature downstream close",
        out == "y\n" and result.code == 0 and stream_err == nil,
        tostring(stream_err))
    ok("pipeline records upstream SIGPIPE/non-zero status",
        result and result.all_succeeded == false
        and result.failed_index == 1
        and result.stages[1].code ~= 0)
    p:close()

    p, e = babet.spawnPipeline({ { "sleep", { "10" } }, { "cat" } })
    ok("spawnPipeline kill fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:kill()
    ok("pipeline kill returns per-stage signaled statuses",
        result and wait_err == nil and result.all_succeeded == false
        and result.stages[1].signaled == true)
    ok("pipeline kill uses signal-derived codes",
        result and result.stages[1].code == 137)
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "sleep 10 & wait" } }, { "cat" },
    })
    ok("spawnPipeline terminate fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:terminate(0.05)
    ok("pipeline terminate returns a complete status table",
        result and wait_err == nil and #result.stages == 2)
    ok("pipeline terminate makes the pipeline unsuccessful",
        result and result.all_succeeded == false)
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "sleep 10 & wait" } }, { "cat" },
    })
    ok("spawnPipeline close-cleanup fixture", p ~= nil and e == nil, tostring(e))
    pids = p:pids()
    ok_act("pipeline close terminates active groups", p:close())
    local groups_dead = true
    for _, pid in ipairs(pids) do
        local probe = babet.exec("sh", {
            "-c", "kill -0 " .. tostring(pid) .. " 2>/dev/null",
        })
        groups_dead = groups_dead and type(probe) == "table" and probe.code ~= 0
    end
    ok("pipeline close reaps all direct children", groups_dead)
    ok("closed pipeline reports not running", p:is_running() == false)

    local auto_pids
    do
        local auto <close> = assert(babet.spawnPipeline({
            { "sleep", { "10" } }, { "cat" },
        }))
        auto_pids = auto:pids()
    end
    local auto_dead = true
    for _, pid in ipairs(auto_pids) do
        local probe = babet.exec("sh", {
            "-c", "kill -0 " .. tostring(pid) .. " 2>/dev/null",
        })
        auto_dead = auto_dead and type(probe) == "table" and probe.code ~= 0
    end
    ok("pipeline Lua <close> cleans active children", auto_dead)

    local gc_pids
    do
        local gc_pipeline = assert(babet.spawnPipeline({
            { "sleep", { "10" } }, { "cat" },
        }))
        gc_pids = gc_pipeline:pids()
        gc_pipeline = nil
    end
    collectgarbage("collect")
    collectgarbage("collect")
    local gc_dead = true
    for _, pid in ipairs(gc_pids) do
        gc_dead = gc_dead and not pipeline_test_pid_is_running(pid)
    end
    ok("pipeline GC cleans active direct children", gc_dead)
    if not gc_dead then
        for _, pid in ipairs(gc_pids) do
            babet.exec("kill", { "-9", tostring(pid) })
        end
    end

    p, e = babet.spawnPipeline({ { "cat" }, { "cat" } })
    ok("spawnPipeline method-validation fixture", p ~= nil and e == nil, tostring(e))
    ok_raises("pipeline read_stdout rejects extra arguments",
        function() p:read_stdout(1, 0, true) end)
    ok_raises("pipeline read_stderr rejects extra arguments",
        function() p:read_stderr(1, 1, 0, true) end)
    ok_raises("pipeline write rejects extra arguments",
        function() p:write("x", 0, true) end)
    ok_raises("pipeline is_running rejects extra arguments",
        function() p:is_running(1, true) end)
    ok_raises("pipeline terminate rejects extra arguments",
        function() p:terminate(0, true) end)
    ok_raises("pipeline read_stdout rejects max_bytes <= 0",
        function() p:read_stdout(0) end)
    ok_raises("pipeline read_stdout rejects max_bytes > 16 MiB",
        function() p:read_stdout(16 * 1024 * 1024 + 1) end)
    ok_raises("pipeline read_stderr rejects max_bytes <= 0",
        function() p:read_stderr(1, 0) end)
    ok_raises("pipeline read_stderr rejects max_bytes > 16 MiB",
        function() p:read_stderr(1, 16 * 1024 * 1024 + 1) end)
    local bad_read, bad_read_err = p:read_stdout(1, -1)
    ok("pipeline read_stdout rejects negative timeout cleanly",
        bad_read == nil and type(bad_read_err) == "string")
    bad_read, bad_read_err = p:read_stdout(1, 3000000)
    ok("pipeline read_stdout rejects timeout above INT_MAX ms",
        bad_read == nil and type(bad_read_err) == "string")
    bad_read, bad_read_err = p:read_stderr(1, 1, -1)
    ok("pipeline read_stderr rejects negative timeout cleanly",
        bad_read == nil and type(bad_read_err) == "string")
    bad_read, bad_read_err = p:read_stderr(1, 1, 3000000)
    ok("pipeline read_stderr rejects timeout above INT_MAX ms",
        bad_read == nil and type(bad_read_err) == "string")
    ok_raises("pipeline write requires a string",
        function() p:write(42) end)
    local bad_write, bad_write_err = p:write("x", -1)
    ok("pipeline write rejects negative timeout cleanly",
        bad_write == nil and type(bad_write_err) == "string")
    bad_write, bad_write_err = p:write("x", 3000000)
    ok("pipeline write rejects timeout above INT_MAX ms",
        bad_write == nil and type(bad_write_err) == "string")
    ok_raises("pipeline close_stdin rejects extra arguments",
        function() p:close_stdin(true) end)
    ok_raises("pipeline wait rejects extra arguments",
        function() p:wait(0, 1) end)
    local bad_wait, bad_wait_err = p:wait(-1)
    ok("pipeline wait rejects negative timeout cleanly",
        bad_wait == nil and type(bad_wait_err) == "string")
    bad_wait, bad_wait_err = p:wait(3000000)
    ok("pipeline wait rejects timeout above INT_MAX ms",
        bad_wait == nil and type(bad_wait_err) == "string")
    local bad_term, bad_term_err = p:terminate(-1)
    ok("pipeline terminate rejects negative grace cleanly",
        bad_term == nil and type(bad_term_err) == "string")
    bad_term, bad_term_err = p:terminate(3000000)
    ok("pipeline terminate rejects grace above INT_MAX ms",
        bad_term == nil and type(bad_term_err) == "string")
    ok_raises("pipeline kill rejects extra arguments",
        function() p:kill(true) end)
    ok_raises("pipeline close rejects extra arguments",
        function() p:close(true) end)
    p:close()
end

-- =====================================================================
print("")
print("=== process streaming ===")

do
    local function read_both(process, timeout)
        local stdout_chunks, stderr_chunks = {}, {}
        local stdout_closed, stderr_closed = false, false
        local deadline = babet.monotonic() + (timeout or 5)

        while not stdout_closed or not stderr_closed do
            if not stdout_closed then
                local data, err = process:read_stdout(65536, 0.05)
                if data then
                    stdout_chunks[#stdout_chunks + 1] = data
                elseif err == "closed" then
                    stdout_closed = true
                elseif err ~= "timeout" then
                    return nil, nil, err
                end
            end

            if not stderr_closed then
                local data, err = process:read_stderr(65536, 0.05)
                if data then
                    stderr_chunks[#stderr_chunks + 1] = data
                elseif err == "closed" then
                    stderr_closed = true
                elseif err ~= "timeout" then
                    return nil, nil, err
                end
            end

            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        return table.concat(stdout_chunks), table.concat(stderr_chunks), nil
    end

    local function write_all(process, data)
        local offset = 1
        while offset <= #data do
            local written, err = process:write(data:sub(offset), 1)
            if not written then
                return nil, err
            end
            if written == 0 then
                return nil, "zero-byte write"
            end
            offset = offset + written
        end
        return true
    end

    ok("babet.spawn is a function", type(babet.spawn) == "function")
    ok("spawn() without command raises",
        pcall(function() babet.spawn() end) == false)
    ok("spawn command is a strict string",
        pcall(function() babet.spawn(42) end) == false)

    local p, e = babet.spawn("echo", "bad")
    ok_fail("spawn args must be a table", p, e)
    p, e = babet.spawn("echo", { [2] = "bad" })
    ok_fail("spawn args must be a dense array", p, e)
    p, e = babet.spawn("echo", { true })
    ok_fail("spawn args contain strings only", p, e)
    p, e = babet.spawn("echo", {}, "bad")
    ok_fail("spawn opts must be a table", p, e)
    p, e = babet.spawn("echo", {}, { unknown = true })
    ok_fail("spawn rejects unknown options", p, e)
    p, e = babet.spawn("echo", {}, { launch_timeout = 0 })
    ok_fail("spawn launch_timeout must be > 0", p, e)
    p, e = babet.spawn("echo", {}, { launch_timeout = "1" })
    ok_fail("spawn launch_timeout is a strict number", p, e)
    p, e = babet.spawn("__babet_missing_command__")
    ok_fail("spawn missing command -> (nil, err)", p, e)

    p, e = babet.spawn("sh", {
        "-c",
        "printf 'OUT'; printf 'ERR' >&2; sleep 0.2",
    })
    ok("spawn basic process returns userdata", p ~= nil and e == nil,
        tostring(e))
    ok("process tostring is informative",
        tostring(p):find("babet.process", 1, true) ~= nil)
    ok("process pid() returns an integer",
        math.type(p:pid()) == "integer" and p:pid() > 0)
    ok("process is_running() initially true", p:is_running() == true)

    local out, errout, stream_err = read_both(p, 3)
    ok("stream stdout is captured progressively",
        out == "OUT" and stream_err == nil, tostring(stream_err))
    ok("stream stderr is captured separately",
        errout == "ERR" and stream_err == nil, tostring(stream_err))

    local result, wait_err = p:wait(2)
    ok("process wait returns a result table",
        type(result) == "table" and wait_err == nil)
    ok("process normal exit code == 0",
        result and result.code == 0 and result.exited == true
        and result.signaled == false)
    ok("process is_running() false after wait", p:is_running() == false)
    local result2, wait_err2 = p:wait(0)
    ok("process wait is idempotent",
        result2 and result2.code == 0 and wait_err2 == nil)
    ok_act("process close() succeeds", p:close())
    ok_act("process close() is idempotent", p:close())
    local closed_data, closed_err = p:read_stdout(1, 0)
    ok("read_stdout after close -> closed",
        closed_data == nil and closed_err == "closed")

    -- cwd + env overlay.
    p, e = babet.spawn("sh", {
        "-c", "printf '%s|%s' \"$PWD\" \"$BABET_SPAWN_ENV\"",
    }, {
        cwd = "/tmp",
        env = { BABET_SPAWN_ENV = "ok" },
    })
    ok("spawn accepts cwd and env", p ~= nil and e == nil, tostring(e))
    out, errout, stream_err = read_both(p, 3)
    result = p:wait(2)
    ok("spawn cwd/env reach the child",
        out == "/tmp|ok" and errout == "" and result.code == 0,
        tostring(out))
    p:close()

    -- Lecture non bloquante et wait borné ne tuent pas le processus.
    p, e = babet.spawn("sh", { "-c", "sleep 0.4; printf done" })
    ok("spawn delayed-output fixture", p ~= nil and e == nil, tostring(e))
    local t0 = babet.monotonic()
    local no_data, timeout_err = p:read_stdout(16, 0.05)
    local dt = babet.monotonic() - t0
    ok("read_stdout timeout is typed and bounded",
        no_data == nil and timeout_err == "timeout" and dt < 0.5,
        "err=" .. tostring(timeout_err) .. " dt=" .. tostring(dt))
    local no_wait, no_wait_err = p:wait(0)
    ok("wait(0) is non-blocking",
        no_wait == nil and no_wait_err == "timeout")
    ok("wait timeout does not terminate the process", p:is_running() == true)
    out, errout, stream_err = read_both(p, 3)
    result = p:wait(2)
    ok("process remains usable after timeouts",
        out == "done" and errout == "" and result.code == 0,
        tostring(stream_err))
    p:close()

    -- stdin binary-safe et écriture progressive.
    p, e = babet.spawn("cat")
    ok("spawn cat for streaming stdin", p ~= nil and e == nil, tostring(e))
    local binary = "alpha\0beta\n"
    local wrote, write_err = write_all(p, binary)
    ok("process write_all accepts binary data", wrote == true,
        tostring(write_err))
    local zero_written, zero_err = p:write("", 0)
    ok("process write empty string returns 0",
        zero_written == 0 and zero_err == nil)
    ok_act("process close_stdin succeeds", p:close_stdin())
    ok_act("process close_stdin is idempotent", p:close_stdin())
    out, errout, stream_err = read_both(p, 3)
    result = p:wait(2)
    ok("process stdin/stdout round-trip is binary-safe",
        out == binary and errout == "" and result.code == 0,
        tostring(stream_err))
    local write_closed, write_closed_err = p:write("x", 0)
    ok("write after close_stdin -> closed",
        write_closed == nil and write_closed_err == "closed")
    p:close()

    -- Gros flux sur stdout ET stderr : les deux doivent être drainés.
    p, e = babet.spawn("sh", {
        "-c",
        "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2",
    })
    ok("spawn large dual-stream fixture", p ~= nil and e == nil, tostring(e))
    out, errout, stream_err = read_both(p, 5)
    result = p:wait(2)
    ok("large stdout streaming does not deadlock",
        out and #out == 262144 and result.code == 0,
        "size=" .. tostring(out and #out) .. " err=" .. tostring(stream_err))
    ok("large stderr streaming does not deadlock",
        errout and #errout == 262144,
        "size=" .. tostring(errout and #errout))
    p:close()

    -- terminate / kill ciblent le groupe et rendent un code 128+signal.
    p, e = babet.spawn("sh", { "-c", "sleep 10" })
    ok("spawn terminate fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:terminate(0.2)
    ok("process terminate returns a signaled result",
        result and wait_err == nil and result.signaled == true
        and (result.code == 143 or result.code == 137),
        tostring(wait_err))
    p:close()

    p, e = babet.spawn("sh", { "-c", "sleep 10" })
    ok("spawn kill fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:kill()
    ok("process kill returns code 137",
        result and wait_err == nil and result.code == 137
        and result.signal == 9)
    p:close()

    -- close() nettoie automatiquement un processus encore actif.
    p, e = babet.spawn("sh", { "-c", "sleep 10" })
    ok("spawn close cleanup fixture", p ~= nil and e == nil, tostring(e))
    local cleanup_pid = p:pid()
    ok_act("process close terminates an active child", p:close())
    ok("closed process reports not running", p:is_running() == false)
    local probe = babet.exec("sh", {
        "-c", "kill -0 " .. tostring(cleanup_pid) .. " 2>/dev/null",
    })
    ok("closed child is no longer alive",
        type(probe) == "table" and probe.code ~= 0)

    -- Arity / value guards on methods.
    p, e = babet.spawn("cat")
    ok("spawn validation-method fixture", p ~= nil and e == nil, tostring(e))
    ok("read_stdout rejects max_bytes <= 0",
        pcall(function() p:read_stdout(0) end) == false)
    ok("read_stdout rejects max_bytes > 16 MiB",
        pcall(function() p:read_stdout(16 * 1024 * 1024 + 1) end) == false)
    local bad_timeout, bad_timeout_err = p:read_stdout(1, -1)
    ok("read_stdout rejects negative timeout cleanly",
        bad_timeout == nil and type(bad_timeout_err) == "string")
    ok("write requires a string",
        pcall(function() p:write(42) end) == false)
    ok("pid rejects extra arguments",
        pcall(function() p:pid(true) end) == false)
    ok("wait rejects extra arguments",
        pcall(function() p:wait(0, 1) end) == false)
    p:close()
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
        while type(n) == "table" and n.c do n = n.c; d = d + 1 end
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

    -- Audit documentation Tables : contrat d'appel et valeur de retour.
    ok("DOC TABLES deepCopyTable without argument raises",
        pcall(babet.deepCopyTable) == false)
    ok("DOC TABLES deepCopyTable rejects extra arguments",
        pcall(babet.deepCopyTable, {}, {}) == false)
    ok("DOC TABLES deepCopyTable rejects a non-table",
        pcall(babet.deepCopyTable, 42) == false)
    ok("DOC TABLES deepCopyTable returns exactly one value",
        select("#", babet.deepCopyTable({})) == 1)

    -- Les VALEURS table sont copiées, mais les clés table sont conservées
    -- par référence. Si la même table apparaît à la fois comme clé et comme
    -- valeur, ces deux positions ne pointent donc plus vers le même objet.
    do
        local key = { id = 7 }
        local src = { [key] = "under-original-key", key_as_value = key }
        local dst = babet.deepCopyTable(src)
        ok("DOC TABLES table-valued key is preserved by reference",
            dst[key] == "under-original-key")
        ok("DOC TABLES table value is copied even when also used as a key",
            dst.key_as_value ~= key and dst.key_as_value.id == 7)
        ok("DOC TABLES copied table value is not substituted as the key",
            dst[dst.key_as_value] == nil)
    end

    -- Le parcours est brut : __index/__pairs ne créent pas de champs dans la
    -- copie. La métatable réelle est toutefois partagée avec la source.
    do
        local mt = { __index = { virtual = 12 } }
        local src = setmetatable({ stored = 1 }, mt)
        local dst = babet.deepCopyTable(src)
        ok("DOC TABLES deepCopyTable shares the metatable object",
            getmetatable(dst) == mt and getmetatable(src) == mt)
        ok("DOC TABLES deepCopyTable copies only raw stored entries",
            rawget(dst, "stored") == 1 and rawget(dst, "virtual") == nil)
        ok("DOC TABLES shared __index still applies to the copy",
            dst.virtual == 12)
        mt.extra = "shared"
        ok("DOC TABLES mutating the shared metatable affects both",
            getmetatable(src).extra == "shared"
            and getmetatable(dst).extra == "shared")
    end

    -- Les valeurs non-table sont réutilisées telles quelles.
    do
        local fn = function() return 42 end
        local co = coroutine.create(function() end)
        local dst = babet.deepCopyTable({ fn = fn, co = co })
        ok("DOC TABLES function values are shared",
            dst.fn == fn and dst.fn() == 42)
        ok("DOC TABLES thread values are shared",
            dst.co == co)
    end

    -- MAX_DEPTH = 75 autorise 75 descentes sous la racine. Le retour d'un
    -- cycle à depth 76 doit réutiliser la racine déjà copiée au lieu d'être
    -- rejeté comme une nouvelle table trop profonde.
    do
        local root = {}
        local node = root
        for _ = 1, 75 do
            node.child = {}
            node = node.child
        end
        node.back = root
        local okp, copied = pcall(babet.deepCopyTable, root)
        ok("DOC TABLES cycle closing at the exact depth limit is accepted",
            okp == true and type(copied) == "table", tostring(copied))
        if okp then
            local tail = copied
            for _ = 1, 75 do tail = tail.child end
            ok("DOC TABLES boundary cycle closes on the copied root",
                tail.back == copied)
        else
            ok("DOC TABLES boundary cycle closes on the copied root", false)
        end

        local too_deep = {}
        node = too_deep
        for _ = 1, 76 do
            node.child = {}
            node = node.child
        end
        local okdeep, errdeep = pcall(babet.deepCopyTable, too_deep)
        ok("DOC TABLES one additional unique table level is rejected",
            okdeep == false and type(errdeep) == "string"
            and errdeep:find("max depth 75", 1, true) ~= nil,
            tostring(errdeep))
    end
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

        local nul_sep = babet.split("a\0b", "\0")
        ok("LOT 3 split: NUL delimiter remains binary-safe",
            type(nul_sep) == "table" and #nul_sep == 2
            and nul_sep[1] == "a" and nul_sep[2] == "b")
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

    -- Audit documentation Strings : arité, types stricts et cas limites
    -- observables qui n'étaient pas encore verrouillés par le harnais.
    ok("DOC STRINGS split() without subject raises",
        pcall(babet.split) == false)
    ok("DOC STRINGS split rejects a fourth argument",
        pcall(babet.split, "a,b", ",", 1, true) == false)
    ok("DOC STRINGS subject must be a strict Lua string",
        pcall(babet.split, 123, ",") == false)
    ok("DOC STRINGS boolean subject is rejected",
        pcall(babet.split, true, ",") == false)
    ok("DOC STRINGS separator must be a strict Lua string",
        pcall(babet.split, "123", 2) == false)
    ok("DOC STRINGS explicit nil separator is rejected",
        pcall(babet.split, "abc", nil) == false)
    ok("DOC STRINGS max_splits rejects numeric strings",
        pcall(babet.split, "a,b", ",", "1") == false)
    ok("DOC STRINGS max_splits rejects floats",
        pcall(babet.split, "a,b", ",", 1.0) == false)
    ok("DOC STRINGS explicit nil max_splits is rejected",
        pcall(babet.split, "a,b", ",", nil) == false)

    local literal_dot = babet.split("a.b.c", ".")
    ok("DOC STRINGS separator is literal, not a Lua pattern",
        #literal_dot == 3 and literal_dot[1] == "a"
        and literal_dot[2] == "b" and literal_dot[3] == "c")

    local leading = babet.split(",a", ",")
    ok("DOC STRINGS preserves a leading empty field",
        #leading == 2 and leading[1] == "" and leading[2] == "a")
    local repeated = babet.split("a,,b", ",")
    ok("DOC STRINGS preserves empty fields between separators",
        #repeated == 3 and repeated[1] == "a"
        and repeated[2] == "" and repeated[3] == "b")
    local trailing = babet.split("a,", ",")
    ok("DOC STRINGS preserves a trailing empty field",
        #trailing == 2 and trailing[1] == "a" and trailing[2] == "")

    local absent = babet.split("abc", ",")
    ok("DOC STRINGS absent separator returns the whole subject",
        #absent == 1 and absent[1] == "abc")
    local unlimited = babet.split("a,b,c", ",", -1)
    ok("DOC STRINGS max_splits=-1 means unlimited",
        #unlimited == 3 and unlimited[3] == "c")
    local bounded = babet.split("a,b,c,d", ",", 2)
    ok("DOC STRINGS max_splits counts cuts, remainder stays whole",
        #bounded == 3 and bounded[1] == "a"
        and bounded[2] == "b" and bounded[3] == "c,d")

    local chars_with_limit = babet.split("abc", "", 0)
    ok("DOC STRINGS max_splits is unused in byte mode",
        #chars_with_limit == 3 and table.concat(chars_with_limit) == "abc")

    local utf8_subject = "été"
    local utf8_parts = babet.split(utf8_subject .. ":ok", ":")
    ok("DOC STRINGS UTF-8 bytes are preserved around an ASCII separator",
        #utf8_parts == 2 and utf8_parts[1] == utf8_subject
        and utf8_parts[2] == "ok")
    local utf8_bytes = babet.split("é")
    ok("DOC STRINGS character mode splits UTF-8 by bytes",
        #utf8_bytes == #"é" and #utf8_bytes == 2
        and #utf8_bytes[1] == 1 and #utf8_bytes[2] == 1
        and table.concat(utf8_bytes) == "é")
    ok("DOC STRINGS multi-byte UTF-8 separator is rejected",
        pcall(babet.split, "aéb", "é") == false)

    ok("DOC STRINGS split returns exactly one value",
        select("#", babet.split("a,b", ",")) == 1)
    local empty_chars = babet.split("", "")
    ok("DOC STRINGS empty subject with empty separator -> empty table",
        type(empty_chars) == "table" and #empty_chars == 0)

    -- mergeTables
    local merged = babet.mergeTables({ "a", "b" }, { "c", "d" })
    ok("mergeTables -> table", type(merged) == "table")

    local sparse = babet.mergeTables(
        { [4] = "d", [2] = "b", label = "first", [0] = "zero-a" },
        { [7] = "g", [1] = "a", label = "second", [0] = "zero-b" })
    ok("LOT 5B mergeTables compacts sparse positive integer keys",
        sparse[1] == "b" and sparse[2] == "d"
        and sparse[3] == "a" and sparse[4] == "g"
        and sparse[5] == nil,
        "values=" .. tostring(sparse[1]) .. "," .. tostring(sparse[2])
        .. "," .. tostring(sparse[3]) .. "," .. tostring(sparse[4]))
    ok("LOT 5B mergeTables keeps non-list keys last-writer-wins",
        sparse.label == "second" and sparse[0] == "zero-b")

    -- Audit documentation Tables : contrat d'appel et règles exactes.
    ok("DOC TABLES mergeTables without arguments raises",
        pcall(babet.mergeTables) == false)
    ok("DOC TABLES mergeTables requires at least two tables",
        pcall(babet.mergeTables, {}) == false)
    ok("DOC TABLES mergeTables rejects any non-table argument",
        pcall(babet.mergeTables, {}, 42) == false)
    ok("DOC TABLES mergeTables returns exactly one value",
        select("#", babet.mergeTables({}, {})) == 1)
    local empty_merge = babet.mergeTables({}, {})
    ok("DOC TABLES two empty tables produce a plain empty table",
        type(empty_merge) == "table" and next(empty_merge) == nil
        and getmetatable(empty_merge) == nil)

    do
        local nested = { value = 1 }
        local left = { label = "left", nested = nested, [2] = "b" }
        local right = { label = "right", [1] = "a" }
        local result = babet.mergeTables(left, right)
        ok("DOC TABLES mergeTables leaves its inputs unchanged",
            left.label == "left" and left[1] == nil and left[2] == "b"
            and right.label == "right" and right[1] == "a")
        ok("DOC TABLES mergeTables is shallow for table values",
            result.nested == nested)
        result.nested.value = 99
        ok("DOC TABLES shallow result mutations reach the source subtable",
            left.nested.value == 99)
    end

    do
        local mt = {
            __index = { virtual = "not stored" },
            __pairs = function()
                return next, { forged = true }, nil
            end,
        }
        local src = setmetatable({ stored = true }, mt)
        local result = babet.mergeTables(src, {})
        ok("DOC TABLES mergeTables ignores source metatables",
            getmetatable(result) == nil)
        ok("DOC TABLES mergeTables traverses raw stored entries only",
            result.stored == true and rawget(result, "virtual") == nil
            and rawget(result, "forged") == nil)
    end

    do
        local table_key = {}
        local function_key = function() end
        local r = babet.mergeTables(
            {
                [true] = "bool-a",
                [table_key] = "table-a",
                [function_key] = "function-a",
                [-1] = "neg-a",
                [0] = "zero-a",
                [1.5] = "float-a",
                ["1"] = "string-a",
            },
            {
                [true] = "bool-b",
                [table_key] = "table-b",
                [function_key] = "function-b",
                [-1] = "neg-b",
                [0] = "zero-b",
                [1.5] = "float-b",
                ["1"] = "string-b",
            })
        ok("DOC TABLES boolean map keys use last-writer-wins",
            r[true] == "bool-b")
        ok("DOC TABLES table map keys keep identity and overwrite",
            r[table_key] == "table-b")
        ok("DOC TABLES function map keys keep identity and overwrite",
            r[function_key] == "function-b")
        ok("DOC TABLES non-list numeric keys remain map keys",
            r[-1] == "neg-b" and r[0] == "zero-b"
            and r[1.5] == "float-b")
        ok("DOC TABLES numeric-looking string keys remain map keys",
            r["1"] == "string-b")
    end

    do
        local a = { [3] = "a3", [1] = "a1" }
        local b = { [2.0] = "b2", [1] = "b1" }
        local r = babet.mergeTables(a, b)
        ok("DOC TABLES positive integer keys are sorted per source",
            r[1] == "a1" and r[2] == "a3")
        ok("DOC TABLES integral float keys are canonical integer list keys",
            r[3] == "b1" and r[4] == "b2" and r[5] == nil)
    end

    do
        local shared_value = { n = 1 }
        local r = babet.mergeTables({ [1] = shared_value }, { [1] = shared_value })
        ok("DOC TABLES duplicate positive keys append both values",
            r[1] == shared_value and r[2] == shared_value and r[3] == nil)
    end

    -- getMemoryUsage
    local mem = babet.getMemoryUsage()
    ok("getMemoryUsage() -> number > 0", type(mem) == "number" and mem > 0,
        "mem=" .. tostring(mem))

    local used, total = babet.getDetailedMemoryUsage()
    ok("getDetailedMemoryUsage() -> 2 integers",
        math.type(used) == "integer" and math.type(total) == "integer")
    ok("getDetailedMemoryUsage() values are currently identical",
        used == total, "used=" .. tostring(used)
        .. " total=" .. tostring(total))

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
    ok_raises("LOT 3 sleep: NUL in unit rejected",
        function() return babet.sleep(0, "ms\0ignored") end, "NUL")

    -- Audit documentation Time : types et arité stricts. Les helpers
    -- lua_isnumber/lua_isstring de Lua accepteraient sinon des coercitions
    -- implicites contraires aux signatures publiques.
    ok("DOC TIME sleep() without duration raises",
        pcall(babet.sleep) == false)
    ok("DOC TIME sleep rejects extra arguments",
        pcall(babet.sleep, 0, "s", true) == false)
    ok("DOC TIME sleep rejects numeric strings",
        pcall(babet.sleep, "1", "ms") == false)
    ok("DOC TIME sleep rejects a numeric unit",
        pcall(babet.sleep, 1, 42) == false)
    do
        local v, e = babet.sleep(0, "minutes")
        ok("DOC TIME unknown textual sleep unit -> (nil, err)",
            v == nil and e == "Invalid time unit",
            "v=" .. tostring(v) .. " err=" .. tostring(e))
    end
    do
        local v, e = babet.sleep(0)
        ok("DOC TIME sleep(0) succeeds immediately",
            v == true and e == nil,
            "v=" .. tostring(v) .. " err=" .. tostring(e))
    end
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

    ok("DOC TIME monotonic success returns exactly one value",
        select("#", babet.monotonic()) == 1)
    ok("DOC TIME now success returns exactly one value",
        select("#", babet.now()) == 1)
    ok("DOC TIME babet.time.monotonic keeps strict arity",
        pcall(babet.time.monotonic, true) == false)
    ok("DOC TIME babet.time.now keeps strict arity",
        pcall(babet.time.now, true) == false)
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
    ok("DOC TIME iso(-0.5) floors to the previous second",
        babet.time.iso(-0.5) == "1969-12-31T23:59:59Z",
        "got " .. tostring(babet.time.iso(-0.5)))
    ok("DOC TIME iso rejects a numeric string",
        pcall(babet.time.iso, "0") == false)
    ok("DOC TIME iso rejects extra arguments",
        pcall(babet.time.iso, 0, 1) == false)
    ok("DOC TIME iso success returns exactly one value",
        select("#", babet.time.iso(0)) == 1)

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

    -- Types et arité sont stricts : aucune coercition number -> string.
    ok("DOC TIME parse_iso rejects a number",
        pcall(babet.time.parse_iso, 1970) == false)
    ok("DOC TIME parse_iso rejects extra arguments",
        pcall(babet.time.parse_iso,
            "1970-01-01T00:00:00Z", true) == false)

    -- Limites exactes du sous-ensemble ISO accepté.
    do
        local v, e = babet.time.parse_iso("0000-01-01T00:00:00Z")
        ok_fail("DOC TIME parse_iso rejects year 0000", v, e)
    end
    do
        local v, e = babet.time.parse_iso("2016-12-31T23:59:60Z")
        ok_fail("DOC TIME parse_iso rejects leap seconds", v, e)
    end
    do
        local v, e = babet.time.parse_iso("1970-01-01T00:00:00z")
        ok_fail("DOC TIME parse_iso requires uppercase Z", v, e)
    end
    do
        local v, e = babet.time.parse_iso("1970-01-01T00:00:00.Z")
        ok_fail("DOC TIME parse_iso requires digits after decimal point", v, e)
    end
    ok("DOC TIME parse_iso accepts offset +23:59",
        babet.time.parse_iso("1970-01-01T23:59:00+23:59") == 0)
    do
        local count = select("#",
            babet.time.parse_iso("1970-01-01T00:00:00Z"))
        local value, err = babet.time.parse_iso("1970-01-01T00:00:00Z")
        ok("DOC TIME parse_iso success returns (integer, nil)",
            count == 2 and value == 0 and err == nil,
            "count=" .. tostring(count) .. " err=" .. tostring(err))
    end
    do
        local v, e = babet.time.parse_iso(
            "1970-01-01T00:00:00Z\0trailing")
        ok_fail("DOC TIME parse_iso does not truncate embedded NUL", v, e)
    end

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
    ok("DOC TIME parse_duration rejects a number",
        pcall(babet.time.parse_duration, 5) == false)
    ok("DOC TIME parse_duration rejects extra arguments",
        pcall(babet.time.parse_duration, "5s", true) == false)

    ok("parse_duration('0s') == 0", babet.time.parse_duration("0s") == 0)
    ok("DOC TIME parse_duration accepts non-normalized components",
        babet.time.parse_duration("1h90m") == 9000)
    ok("DOC TIME parse_duration accepts ordered zero chunks",
        babet.time.parse_duration("0d0h0m0s") == 0)
    do
        local count = select("#", babet.time.parse_duration("1s"))
        local value, err = babet.time.parse_duration("1s")
        ok("DOC TIME parse_duration success returns (integer, nil)",
            count == 2 and value == 1 and err == nil,
            "count=" .. tostring(count) .. " err=" .. tostring(err))
    end
    do
        local v, e = babet.time.parse_duration("1s\0trailing")
        ok_fail("DOC TIME parse_duration does not truncate embedded NUL", v, e)
    end
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
        v, e = babet.time.parse_duration("1h 30m")
        ok_fail("DOC TIME parse_duration rejects whitespace", v, e)
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
    ok("DOC TIME format_duration rejects a numeric string",
        pcall(babet.time.format_duration, "60") == false)
    ok("DOC TIME format_duration rejects extra arguments",
        pcall(babet.time.format_duration, 60, true) == false)
    ok("DOC TIME format_duration success returns exactly one value",
        select("#", babet.time.format_duration(60)) == 1)
    do
        local max_text = babet.time.format_duration(math.maxinteger)
        ok("DOC TIME format_duration accepts math.maxinteger",
            type(max_text) == "string" and #max_text > 0,
            "value=" .. tostring(max_text))
        ok("DOC TIME max duration round-trips",
            babet.time.parse_duration(max_text) == math.maxinteger,
            "value=" .. tostring(max_text))
    end

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
    ok("DOC 4 get rejects non-string URL",
        pcall(function() return H.get(42) end) == false)
    ok("DOC 4 get rejects non-table opts",
        pcall(function() return H.get("http://127.0.0.1/", "bad") end) == false)
    ok("DOC 4 post rejects non-string body",
        pcall(function()
            return H.post("http://127.0.0.1/", 42)
        end) == false)

    -- --- download(): signature and pre-network validation -----------
    ok("HTTP download is exposed",
        type(H.download) == "function")
    ok("HTTP download requires URL and destination",
        pcall(function() return H.download() end) == false)
    ok("HTTP download rejects a missing destination",
        pcall(function() return H.download("http://127.0.0.1/") end) == false)
    ok("HTTP download URL is a strict string",
        pcall(function() return H.download(42, "out.bin") end) == false)
    ok("HTTP download destination is a strict string",
        pcall(function()
            return H.download("http://127.0.0.1/", 42)
        end) == false)
    ok("HTTP download opts must be a table",
        pcall(function()
            return H.download("http://127.0.0.1/", "out.bin", "bad")
        end) == false)
    ok("HTTP download rejects extra arguments",
        pcall(function()
            return H.download("http://127.0.0.1/", "out.bin", {}, true)
        end) == false)
    ok("HTTP download rejects NUL in destination",
        pcall(function()
            return H.download("http://127.0.0.1/", "out\0ignored")
        end) == false)

    do
        local validation_path = "_babet_http_download_validation.tmp"
        babet.remove(validation_path)

        local v, e = H.download("http://127.0.0.1:1/", validation_path, {
            max_file_size = "1024",
        })
        ok_fail("HTTP download max_file_size is a strict integer", v, e)

        v, e = H.download("http://127.0.0.1:1/", validation_path, {
            max_file_size = 0,
        })
        ok_fail("HTTP download rejects max_file_size <= 0", v, e)

        v, e = H.download("http://127.0.0.1:1/", validation_path, {
            max_file_size = 1.5,
        })
        ok_fail("HTTP download rejects fractional max_file_size", v, e)

        v, e = H.download("http://127.0.0.1:1/", validation_path, {
            body = "not allowed on GET",
        })
        ok_fail("HTTP download rejects a request body", v, e)

        v, e = H.download("http://127.0.0.1:1/",
            "_babet_missing_download_parent/out.bin", { timeout = 1 })
        ok_fail("HTTP download requires an existing parent directory", v, e)

        v, e = H.download("http://127.0.0.1:1/",
            "_babet_http_test/../out.bin", { timeout = 1 })
        ok_fail("HTTP download rejects '..' in destination", v, e)

        ok("HTTP download validation leaves no destination",
            not babet.fileExists(validation_path))
    end

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

    do
        local v, e = H.request({
            url = "http://127.0.0.1:1/", verify = 1,
        })
        ok_fail("LOT 4 http.verify non-boolean -> (nil, err)", v, e)
        ok("  verify error mentions boolean",
            tostring(e):find("boolean", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/", follow_redirects = "yes",
        })
        ok_fail("LOT 4 http.follow_redirects non-boolean -> (nil, err)", v, e)
        ok("  follow_redirects error mentions boolean",
            tostring(e):find("boolean", 1, true) ~= nil,
            "err=" .. tostring(e))

        for _, bad in ipairs({ 0, -1, 1.5, 2147483649 }) do
            v, e = H.request({
                url = "http://127.0.0.1:1/", max_body_size = bad,
            })
            ok_fail("LOT 4 http.max_body_size rejected: " .. tostring(bad),
                v, e)
        end
    end

    do
        local v, e = H.request({ url = "http://127.0.0.1/\0ignored" })
        ok_fail("LOT 3 http: NUL in URL rejected", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            method = "GET\0POST",
        })
        ok_fail("LOT 3 http: NUL in method rejected", v, e)

        v, e = H.request({
            url = "https://127.0.0.1/",
            ca_cert = "/tmp/ca.pem\0ignored",
        })
        ok_fail("LOT 3 http: NUL in ca_cert rejected", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-Test\0Ignored"] = "ok" },
        })
        ok_fail("LOT 3 http: NUL in header name rejected", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-Test"] = "ok\0ignored" },
        })
        ok_fail("LOT 3 http: NUL in header value rejected", v, e)

        v, e = H.get("http://127.0.0.1/\r\nX-Evil: yes")
        ok_fail("DOC 4 HTTP rejects CR/LF in URL", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["Bad Header"] = "x" },
        })
        ok_fail("DOC 4 HTTP rejects invalid header name", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-é"] = "x" },
        })
        ok_fail("DOC 4 HTTP rejects non-ASCII header name", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-Test"] = "ok\r\nX-Evil: yes" },
        })
        ok_fail("DOC 4 HTTP rejects CR/LF in header value", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            query = { [{}] = "bad" },
        })
        ok_fail("DOC 4 HTTP rejects non-string query key", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            query = { bad = {} },
        })
        ok_fail("DOC 4 HTTP rejects non scalar query value", v, e)
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

        local server_file = assert(io.open(SBH .. "/server.py", "wb"))
        server_file:write([[
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
import time

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _send(self, status, body=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def _echo(self):
        body = self._read_body()
        self._send(200, body, [
            ("Content-Type", "application/octet-stream"),
            ("X-Method", self.command),
            ("X-Request-Content-Type", self.headers.get("Content-Type", "")),
            ("X-Request-Number", self.headers.get("X-Number", "")),
        ])

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/probe.bin":
            self._send(200, b"AB\x00CD",
                       [("Content-Type", "application/octet-stream")])
        elif path == "/multi":
            self._send(200, b"ok", [
                ("Content-Type", "text/plain"),
                ("Set-Cookie", "a=1"),
                ("Set-Cookie", "b=2"),
            ])
        elif path == "/large":
            self._send(200, b"x" * 4096,
                       [("Content-Type", "application/octet-stream")])
        elif path == "/empty":
            self._send(204, b"",
                       [("Content-Type", "application/octet-stream")])
        elif path == "/query":
            self._send(200, self.path.encode("ascii"),
                       [("Content-Type", "text/plain")])
        elif path == "/redirect":
            self._send(302, b"redirect-body",
                       [("Location", "/probe.bin")])
        elif path == "/slow":
            time.sleep(0.5)
            self._send(200, b"slow", [("Content-Type", "text/plain")])
        else:
            self._send(404, b"not found",
                       [("Content-Type", "text/plain")])

    def do_HEAD(self):
        self._send(200, b"head-body", [("Content-Type", "text/plain")])

    def do_OPTIONS(self):
        self._send(204, b"", [("Allow", "GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE")])

    def do_POST(self):
        self._echo()

    def do_PUT(self):
        self._echo()

    def do_PATCH(self):
        self._echo()

    def do_DELETE(self):
        self._echo()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
    port_file.flush()
server.serve_forever()
]])
        server_file:close()

        print("[INFO] http: starting local test server...")
        local port_file = SBH .. "/port.txt"

        -- Port éphémère attribué par le noyau : les trois exécutions
        -- successives du harnais ne peuvent plus se disputer un port
        -- calculé à partir de os.time(). Le userdata process garantit
        -- aussi que le serveur est réellement terminé avant la relance.
        local server_proc, server_err = babet.spawn("python3", {
            "server.py", "port.txt",
        }, {
            cwd = SBH,
            launch_timeout = 5,
        })

        -- Budget d'attente DUR et COURT : 15 sondes x ~200 ms ≈ 3 s
        -- max, AVEC progression visible (jamais "aucun avancement").
        -- Not ready within budget -> skip: the subsection is
        -- optionnelle (décision actée), on ne grind jamais en muet.
        local port
        local up = false
        if server_proc then
            for i = 1, 15 do
                babet.sleep(200, "ms")

                local pf = io.open(port_file, "rb")
                if pf then
                    local raw_port = pf:read("*a")
                    pf:close()
                    port = tonumber(raw_port)
                end

                if port and port >= 1 and port <= 65535 then
                    local probe = babet.http.get(
                        "http://127.0.0.1:" .. port .. "/probe.bin",
                        { timeout = 1 })
                    if type(probe) == "table" and probe.status == 200 then
                        up = true
                        break
                    end
                end

                if i % 5 == 0 then
                    print("[INFO] http: attente serveur ("
                        .. i .. "/15)...")
                end
            end
        end

        if not up then
            print("[INFO] http: local server unavailable in "
                .. "budget, 2xx success subsection ignorée (optionnelle)"
                .. "; err=" .. tostring(server_err))
            if server_proc then
                server_proc:close()
            end
            babet.rmdirAll(SBH)
        else
            local base = "http://127.0.0.1:" .. port
            print("[INFO] http: server ready, running 2xx success tests...")

            local download_dir = SBH .. "/downloads"
            assert(babet.mkdir(download_dir))

            local function read_binary(path)
                local file = assert(io.open(path, "rb"))
                local data = file:read("*a")
                file:close()
                return data
            end

            local function write_binary(path, data)
                local file = assert(io.open(path, "wb"))
                file:write(data)
                file:close()
            end

            local function count_download_temps(path)
                local files = babet.listFiles(path) or {}
                local count = 0
                for _, item in ipairs(files) do
                    local name = babet.getBasename(item)
                    if type(name) == "string"
                        and name:find(".babet-download.", 1, true) == 1 then
                        count = count + 1
                    end
                end
                return count
            end

            local download_path = download_dir .. "/probe.bin"
            local downloaded, download_err = H.download(
                base .. "/probe.bin", download_path, { timeout = 5 })
            ok("HTTP download 200 -> (table, nil)",
                type(downloaded) == "table" and download_err == nil,
                "err=" .. tostring(download_err))
            ok("HTTP download status == 200",
                type(downloaded) == "table" and downloaded.status == 200)
            ok("HTTP download reports saved=true",
                type(downloaded) == "table" and downloaded.saved == true)
            ok("HTTP download reports exact byte count",
                type(downloaded) == "table" and downloaded.bytes == 5,
                "bytes=" .. tostring(downloaded and downloaded.bytes))
            ok("HTTP download returns the destination path",
                type(downloaded) == "table"
                and downloaded.path == download_path)
            ok("HTTP download result does not expose an in-memory body",
                type(downloaded) == "table" and downloaded.body == nil)
            ok("HTTP download returns response headers",
                type(downloaded) == "table"
                and type(downloaded.headers) == "table"
                and downloaded.headers["content-type"]
                    == "application/octet-stream")
            ok("HTTP download returns headers_multi",
                type(downloaded) == "table"
                and type(downloaded.headers_multi) == "table"
                and type(downloaded.headers_multi["content-type"])
                    == "table")
            ok("HTTP download writes binary-safe content",
                read_binary(download_path) == "AB\0CD")

            write_binary(download_path, "OLD")
            local replaced, replace_err = H.download(
                base .. "/probe.bin", download_path, { timeout = 5 })
            ok("HTTP download atomically replaces an existing file",
                type(replaced) == "table" and replace_err == nil
                and replaced.saved == true
                and read_binary(download_path) == "AB\0CD",
                "err=" .. tostring(replace_err))

            local error_path = download_dir .. "/preserved.bin"
            write_binary(error_path, "KEEP")
            local not_found, not_found_err = H.download(
                base .. "/missing", error_path, { timeout = 5 })
            ok("HTTP download 404 returns response metadata",
                type(not_found) == "table" and not_found_err == nil
                and not_found.status == 404,
                "err=" .. tostring(not_found_err))
            ok("HTTP download 404 reports saved=false",
                type(not_found) == "table" and not_found.saved == false)
            ok("HTTP download 404 reports received bytes",
                type(not_found) == "table" and not_found.bytes == 9,
                "bytes=" .. tostring(not_found and not_found.bytes))
            ok("HTTP download 404 exposes no destination path",
                type(not_found) == "table" and not_found.path == nil)
            ok("HTTP download 404 preserves the existing destination",
                read_binary(error_path) == "KEEP")
            ok("HTTP download 404 leaves no temporary file",
                count_download_temps(download_dir) == 0)

            local limited_path = download_dir .. "/limited.bin"
            write_binary(limited_path, "ORIGINAL")
            local limited, limited_err = H.download(
                base .. "/large", limited_path, {
                    timeout = 5,
                    max_file_size = 1024,
                })
            ok_fail("HTTP download enforces max_file_size",
                limited, limited_err)
            ok("HTTP download max_file_size error is explicit",
                limited == nil
                and tostring(limited_err):find(
                    "max_file_size", 1, true) ~= nil,
                "err=" .. tostring(limited_err))
            ok("HTTP download size failure preserves destination",
                read_binary(limited_path) == "ORIGINAL")
            ok("HTTP download size failure removes temporary file",
                count_download_temps(download_dir) == 0)

            local redirect_path = download_dir .. "/redirect.bin"
            write_binary(redirect_path, "REDIRECT-OLD")
            local redirect_result, redirect_err = H.download(
                base .. "/redirect", redirect_path, { timeout = 5 })
            ok("HTTP download does not follow redirects by default",
                type(redirect_result) == "table" and redirect_err == nil
                and redirect_result.status == 302
                and redirect_result.saved == false,
                "err=" .. tostring(redirect_err))
            ok("HTTP download unfollowed redirect preserves destination",
                read_binary(redirect_path) == "REDIRECT-OLD")

            local followed_download, followed_download_err = H.download(
                base .. "/redirect", redirect_path, {
                    timeout = 5,
                    follow_redirects = true,
                })
            ok("HTTP download follows redirects when requested",
                type(followed_download) == "table"
                and followed_download_err == nil
                and followed_download.status == 200
                and followed_download.saved == true
                and read_binary(redirect_path) == "AB\0CD",
                "err=" .. tostring(followed_download_err))

            local empty_path = download_dir .. "/empty.bin"
            local empty_result, empty_err = H.download(
                base .. "/empty", empty_path, { timeout = 5 })
            ok("HTTP download saves an empty 204 response",
                type(empty_result) == "table" and empty_err == nil
                and empty_result.status == 204
                and empty_result.saved == true
                and empty_result.bytes == 0,
                "err=" .. tostring(empty_err))
            ok("HTTP download creates an empty destination file",
                babet.fileExists(empty_path)
                and babet.fileSize(empty_path) == 0)

            local query_path = download_dir .. "/query.txt"
            local query_download, query_download_err = H.download(
                base .. "/query", query_path, {
                    timeout = 5,
                    query = { a = "x y" },
                })
            ok("HTTP download supports query options",
                type(query_download) == "table"
                and query_download_err == nil
                and read_binary(query_path):find("a=x+y", 1, true) ~= nil,
                "err=" .. tostring(query_download_err))

            local real_parent = SBH .. "/download-real-parent"
            local linked_parent = SBH .. "/download-linked-parent"
            assert(babet.mkdir(real_parent))
            assert(babet.link(real_parent, linked_parent))
            local through_link, through_link_err = H.download(
                base .. "/probe.bin", linked_parent .. "/blocked.bin", {
                    timeout = 5,
                })
            ok_fail("HTTP download rejects a symlink parent component",
                through_link, through_link_err)
            ok("HTTP download symlink-parent error is explicit",
                through_link == nil
                and tostring(through_link_err):find(
                    "symlink", 1, true) ~= nil,
                "err=" .. tostring(through_link_err))
            ok("HTTP download never writes through a symlink parent",
                not babet.fileExists(real_parent .. "/blocked.bin"))

            local symlink_target = download_dir .. "/target.bin"
            local symlink_destination = download_dir .. "/destination.bin"
            write_binary(symlink_target, "TARGET")
            assert(babet.link(symlink_target, symlink_destination))
            local symlink_result, symlink_err = H.download(
                base .. "/probe.bin", symlink_destination, { timeout = 5 })
            local no_longer_link = babet.exec("test", {
                "!", "-L", symlink_destination,
            })
            ok("HTTP download safely replaces a destination symlink",
                type(symlink_result) == "table" and symlink_err == nil
                and symlink_result.saved == true,
                "err=" .. tostring(symlink_err))
            ok("HTTP download leaves the symlink target untouched",
                read_binary(symlink_target) == "TARGET")
            ok("HTTP download destination now contains response data",
                read_binary(symlink_destination) == "AB\0CD")
            ok("HTTP download replaces the symlink inode itself",
                type(no_longer_link) == "table" and no_longer_link.code == 0)

            local transport_path = download_dir .. "/transport.bin"
            write_binary(transport_path, "STILL-HERE")
            local transport, transport_err = H.download(
                "http://127.0.0.1:1/", transport_path, { timeout = 1 })
            ok_fail("HTTP download transport failure -> (nil, err)",
                transport, transport_err)
            ok("HTTP download transport failure preserves destination",
                read_binary(transport_path) == "STILL-HERE")
            ok("HTTP download transport failure removes temporary file",
                count_download_temps(download_dir) == 0)

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
                ok("LOT 4 headers_multi contains single-valued headers",
                    type(res.headers_multi) == "table"
                    and type(res.headers_multi["content-type"]) == "table"
                    and #res.headers_multi["content-type"] == 1,
                    "headers_multi=" .. tostring(res.headers_multi))
            end

            local multi, multi_err = babet.http.get(base .. "/multi",
                { timeout = 5 })
            local cookies = type(multi) == "table"
                and type(multi.headers_multi) == "table"
                and multi.headers_multi["set-cookie"] or nil
            local saw_cookie_a, saw_cookie_b = false, false
            if type(cookies) == "table" then
                for _, cookie in ipairs(cookies) do
                    saw_cookie_a = saw_cookie_a or cookie == "a=1"
                    saw_cookie_b = saw_cookie_b or cookie == "b=2"
                end
            end
            ok("LOT 4 repeated response headers -> headers_multi",
                type(multi) == "table" and multi_err == nil
                and type(multi.headers["set-cookie"]) == "string"
                and type(cookies) == "table" and #cookies == 2
                and saw_cookie_a and saw_cookie_b,
                "err=" .. tostring(multi_err))

            local too_big, too_big_err = babet.http.get(base .. "/large",
                { timeout = 5, max_body_size = 1024 })
            ok_fail("LOT 4 HTTP body over max_body_size -> (nil, err)",
                too_big, too_big_err)
            ok("  no partial body and explicit max_body_size error",
                too_big == nil
                and tostring(too_big_err):find("max_body_size", 1, true) ~= nil,
                "err=" .. tostring(too_big_err))

            local large_ok, large_err = babet.http.get(base .. "/large",
                { timeout = 5, max_body_size = 8192 })
            ok("LOT 4 custom max_body_size permits response",
                type(large_ok) == "table" and large_err == nil
                and type(large_ok.body) == "string"
                and #large_ok.body == 4096,
                "err=" .. tostring(large_err))

            local r404, e404 = babet.http.get(
                base .. "/nexiste_pas", { timeout = 5 })
            ok("GET 404 -> (table, nil) [4xx is not an error]",
                type(r404) == "table" and e404 == nil
                and r404.status == 404,
                "status=" .. tostring(r404 and r404.status)
                .. " err=" .. tostring(e404))

            local rq = babet.http.get(base .. "/query",
                { timeout = 5, query = { a = "x y", b = 42 } })
            ok("DOC 4 GET query uses documented normalization",
                type(rq) == "table" and rq.status == 200
                and rq.body:find("a=x+y", 1, true) ~= nil
                and rq.body:find("b=42", 1, true) ~= nil,
                "body=" .. tostring(rq and rq.body))

            local rq_utf8 = babet.http.get(base .. "/query", {
                timeout = 5, query = { word = "café" },
            })
            ok("DOC 4 GET query percent-encodes UTF-8 bytes",
                type(rq_utf8) == "table" and rq_utf8.status == 200
                and rq_utf8.body:find("word=caf%%C3%%A9") ~= nil,
                "body=" .. tostring(rq_utf8 and rq_utf8.body))

            local rq2 = babet.http.get(
                base .. "/query?already=hello%20world#ignored", {
                    timeout = 5, query = { more = "a/b" },
                })
            ok("DOC 4 query merges existing query and strips fragment",
                type(rq2) == "table"
                and rq2.body:find("already=hello+world", 1, true) ~= nil
                and rq2.body:find("more=a/b", 1, true) ~= nil
                and rq2.body:find("ignored", 1, true) == nil,
                "body=" .. tostring(rq2 and rq2.body))

            local post1, post1_err = babet.http.post(base .. "/echo",
                "AB\0CD", { timeout = 5, headers = { ["X-Number"] = 42 } })
            ok("DOC 4 post(url, body, opts) is binary-safe",
                type(post1) == "table" and post1_err == nil
                and post1.body == "AB\0CD",
                "err=" .. tostring(post1_err))
            ok("DOC 4 body defaults to application/octet-stream",
                type(post1) == "table"
                and post1.headers["x-request-content-type"]
                    == "application/octet-stream")
            ok("DOC 4 numeric request header is converted to text",
                type(post1) == "table"
                and post1.headers["x-request-number"] == "42")

            local post2 = babet.http.post(base .. "/echo", {
                timeout = 5,
                body = "from-opts",
                headers = { ["Content-Type"] = "text/plain" },
            })
            ok("DOC 4 post(url, opts) uses opts.body",
                type(post2) == "table" and post2.body == "from-opts")
            ok("DOC 4 explicit Content-Type is preserved",
                type(post2) == "table"
                and post2.headers["x-request-content-type"] == "text/plain")

            local post3 = babet.http.post(base .. "/echo", "argument", {
                timeout = 5, body = "ignored-option",
            })
            ok("DOC 4 positional POST body overrides opts.body",
                type(post3) == "table" and post3.body == "argument")

            local put = babet.http.request({
                url = base .. "/echo", method = "put", body = "payload",
                timeout = 5,
            })
            ok("DOC 4 method is case-insensitive and normalized",
                type(put) == "table" and put.body == "payload"
                and put.headers["x-method"] == "PUT")

            local redir = babet.http.get(base .. "/redirect", { timeout = 5 })
            ok("DOC 4 redirects are not followed by default",
                type(redir) == "table" and redir.status == 302
                and redir.headers.location == "/probe.bin")
            local followed, followed_err = babet.http.get(
                base .. "/redirect", {
                    timeout = 5, follow_redirects = true,
                })
            ok("DOC 4 follow_redirects=true follows redirect",
                type(followed) == "table" and followed.status == 200
                and followed.body == "AB\0CD",
                "status=" .. tostring(followed and followed.status)
                .. " body=" .. tostring(followed and followed.body)
                .. " err=" .. tostring(followed_err))

            local head = babet.http.request({
                url = base .. "/anything", method = "HEAD", timeout = 5,
            })
            ok("DOC 4 HEAD returns headers with an empty body",
                type(head) == "table" and head.status == 200
                and head.body == "")

            local slow_started = babet.time.monotonic()
            local slow, slow_err = babet.http.get(base .. "/slow",
                { timeout = 0.1 })
            local slow_elapsed = babet.time.monotonic() - slow_started
            ok_fail("DOC 4 HTTP timeout covers the request", slow, slow_err)
            ok("  timeout remains bounded",
                slow == nil and slow_elapsed < 2.0,
                "elapsed=" .. tostring(slow_elapsed)
                .. " err=" .. tostring(slow_err))

            -- close() termine et reap le groupe de processus avant de
            -- supprimer les fichiers du serveur. Aucun serveur résiduel
            -- ne peut donc perturber l'exécution embarquée via PATH.
            server_proc:close()
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

    -- ----- audit documentation Argparse -----------------------------

    ok("DOC ARGPARSE metadata renamed to Babet",
        argparse._VERSION == "babet argparse 1.1.0",
        "version=" .. tostring(argparse._VERSION))

    do
        local p = argparse()
        ok("DOC ARGPARSE constructor default program is 'prog'",
            p:get_usage():find("Usage: prog [options]", 1, true) == 1)
    end

    ok("DOC ARGPARSE constructor requires a string program",
        pcall(function() argparse(42) end) == false)
    ok("DOC ARGPARSE constructor requires a string description",
        pcall(function() argparse("prog", false) end) == false)
    ok("DOC ARGPARSE constructor rejects extra arguments",
        pcall(function() argparse("prog", "desc", "extra") end) == false)
    ok("DOC ARGPARSE flag enforces its arity",
        pcall(function() argparse("prog"):flag() end) == false)
    ok("DOC ARGPARSE option enforces its arity",
        pcall(function()
            argparse("prog"):option("-o", {}, "extra")
        end) == false)
    ok("DOC ARGPARSE argument enforces its arity",
        pcall(function()
            argparse("prog"):argument("input", {}, "extra")
        end) == false)
    ok("DOC ARGPARSE get_usage enforces its arity",
        pcall(function() argparse("prog"):get_usage("extra") end) == false)
    ok("DOC ARGPARSE parse enforces its arity",
        pcall(function() argparse("prog"):parse({}, {}) end) == false)

    ok("DOC ARGPARSE option spec is a strict string",
        pcall(function() argparse("prog"):flag(42) end) == false)
    ok("DOC ARGPARSE opts must be a table",
        pcall(function() argparse("prog"):flag("-v", true) end) == false)
    ok("DOC ARGPARSE unknown opts fields are rejected",
        pcall(function()
            argparse("prog"):flag("-v", { hlep = "typo" })
        end) == false)
    ok("DOC ARGPARSE help must be a string",
        pcall(function()
            argparse("prog"):flag("-v", { help = 42 })
        end) == false)
    ok("DOC ARGPARSE required must be a boolean",
        pcall(function()
            argparse("prog"):flag("-v", { required = "false" })
        end) == false)
    ok("DOC ARGPARSE dest must be a non-empty string",
        pcall(function()
            argparse("prog"):flag("-v", { dest = 42 })
        end) == false)
    ok("DOC ARGPARSE flags reject choices",
        pcall(function()
            argparse("prog"):flag("-v", { choices = { "x" } })
        end) == false)
    ok("DOC ARGPARSE choices must be a table",
        pcall(function()
            argparse("prog"):option("-o", { choices = "x" })
        end) == false)
    ok("DOC ARGPARSE choices must be dense",
        pcall(function()
            argparse("prog"):option("-o", { choices = { [2] = "x" } })
        end) == false)
    ok("DOC ARGPARSE choices contain strings only",
        pcall(function()
            argparse("prog"):option("-o", { choices = { 1 } })
        end) == false)
    ok("DOC ARGPARSE convert must be a function",
        pcall(function()
            argparse("prog"):option("-o", { convert = 42 })
        end) == false)

    ok("DOC ARGPARSE '-h' is reserved",
        pcall(function() argparse("prog"):flag("-h") end) == false)
    ok("DOC ARGPARSE '--help' is reserved",
        pcall(function() argparse("prog"):flag("--help") end) == false)
    ok("DOC ARGPARSE '-' cannot be declared as an option",
        pcall(function() argparse("prog"):flag("-") end) == false)
    ok("DOC ARGPARSE '--' cannot be declared as an option",
        pcall(function() argparse("prog"):flag("--") end) == false)
    ok("DOC ARGPARSE option names cannot contain '='",
        pcall(function() argparse("prog"):flag("--x=y") end) == false)
    ok("DOC ARGPARSE duplicate name inside one spec is rejected",
        pcall(function() argparse("prog"):flag("-v -v") end) == false)
    ok("DOC ARGPARSE duplicate destinations are rejected",
        pcall(function()
            argparse("prog")
                :flag("-a", { dest = "same" })
                :option("-b", { dest = "same" })
        end) == false)
    ok("DOC ARGPARSE help destination is reserved",
        pcall(function()
            argparse("prog"):argument("input", { dest = "help" })
        end) == false)
    ok("DOC ARGPARSE required positional cannot follow optional",
        pcall(function()
            argparse("prog")
                :argument("first", { required = false })
                :argument("second")
        end) == false)

    do
        local p = argparse("prog"):flag("-a")
        local caught = pcall(function() p:flag("-b -a") end)
        ok("DOC ARGPARSE duplicate builder error is raised",
            caught == false)
        ok("DOC ARGPARSE failed builder leaves usage intact",
            p:get_usage():find("-b", 1, true) == nil)
        local r, e = p:parse({ "-b" })
        ok_fail("DOC ARGPARSE failed builder leaves no partial alias",
            r, e)
    end

    do
        local p = argparse("prog")
        local r, e = p:parse("abc")
        ok_fail("DOC ARGPARSE parse source must be an array", r, e)
        r, e = p:parse({ 42 })
        ok_fail("DOC ARGPARSE parse tokens must be strings", r, e)
        r, e = p:parse({ [1] = "a", [3] = "b" })
        ok_fail("DOC ARGPARSE parse source rejects holes", r, e)
    end

    do
        local p = argparse("prog")
            :flag("-v")
            :option("-o")
            :option("-n", { convert = tonumber })
            :argument("input")

        local r, e = p:parse({ "file", "-v" })
        ok_val("DOC ARGPARSE options remain active after positionals", r, e)
        ok("  option after positional was parsed",
            r and r.input == "file" and r.v == true)

        r, e = p:parse({ "-o=", "file" })
        ok_val("DOC ARGPARSE inline empty option value is accepted", r, e)
        ok("  inline empty value is preserved", r and r.o == "")

        r, e = p:parse({ "-n", "-5", "file" })
        ok_val("DOC ARGPARSE negative option value is accepted", r, e)
        ok("  negative option value was converted", r and r.n == -5)

        r, e = p:parse({ "-5" })
        ok_fail("DOC ARGPARSE negative positional needs '--'", r, e)
        r, e = p:parse({ "--", "-5" })
        ok_val("DOC ARGPARSE '--' permits a negative positional", r, e)
        ok("  negative positional is preserved", r and r.input == "-5")

        r, e = p:parse({ "-" })
        ok_val("DOC ARGPARSE lone '-' is positional", r, e)
        ok("  lone '-' is preserved", r and r.input == "-")

        r, e = p:parse({ "file", "--help", "--unknown" })
        ok_val("DOC ARGPARSE help returns immediately", r, e)
        ok("  help result has only the help contract",
            r and r.help == true and type(r.usage) == "string")

        r, e = p:parse({ "--", "--help" })
        ok_val("DOC ARGPARSE help after '--' is positional", r, e)
        ok("  literal --help is preserved",
            r and r.input == "--help" and r.help == nil)
    end

    do
        local p = argparse("prog")
            :flag("-f", { default = "auto" })
            :option("-o", { required = true, default = "unused" })

        local r, e = p:parse({})
        ok_fail("DOC ARGPARSE required option beats its default", r, e)
        r, e = p:parse({ "-o", "yes" })
        ok_val("DOC ARGPARSE arbitrary flag default is preserved", r, e)
        ok("  absent flag keeps its default", r and r.f == "auto")
    end

    do
        local p = argparse("prog"):option("-o")
        local r, e = p:parse({ "-o", "a", "-o", "b" })
        ok_val("DOC ARGPARSE repeated option is accepted", r, e)
        ok("  repeated option uses the last value", r and r.o == "b")
    end

    do
        local choices = { "1", "2" }
        local p = argparse("prog"):option("-n", {
            choices = choices,
            convert = tonumber,
            default = "raw",
        })
        choices[1] = "9"

        local r, e = p:parse({ "-n", "1" })
        ok_val("DOC ARGPARSE choices are copied by the builder", r, e)
        ok("  original choices mutation has no effect", r and r.n == 1)

        r, e = p:parse({})
        ok_val("DOC ARGPARSE default bypasses choices and convert", r, e)
        ok("  default keeps its original type",
            r and r.n == "raw" and type(r.n) == "string")
    end

    do
        local p = argparse("prog"):option("-x", {
            convert = function() return false end,
        })
        local r, e = p:parse({ "-x", "value" })
        ok_val("DOC ARGPARSE converter may return false", r, e)
        ok("  false is a successful converted value",
            r and r.x == false)
    end

    do
        local p = argparse("prog"):option("-o"):flag("-v")
        local r, e = p:parse({ "-o", "-v" })
        ok_val("DOC ARGPARSE option-looking token can be a value", r, e)
        ok("  option-looking value is consumed literally",
            r and r.o == "-v" and r.v == false)

        r, e = p:parse({ "-o", "--", "-v" })
        ok_val("DOC ARGPARSE '--' can itself be an option value", r, e)
        ok("  parsing continues after consumed value",
            r and r.o == "--" and r.v == true)
    end

    do
        local previous_arg = arg
        arg = { [0] = "internal", [1] = "A", [2] = "B" }
        local p = argparse("prog"):argument("a"):argument("b")
        local r, e = p:parse(nil)
        ok_val("DOC ARGPARSE parse(nil) reads global arg", r, e)
        ok("  global arg indices 1..n are used",
            r and r.a == "A" and r.b == "B")
        arg = previous_arg
    end
end

-- =====================================================================
print("")
print("=== logging ===")

do
    local log = require("logging")

    -- ----- contrat de base ------------------------------------------

    ok("require returns a table", type(log) == "table")
    ok("require is cached in the current Lua state",
        require("logging") == log)
    ok("module metadata names Babet",
        log._VERSION == "babet logging 1.1.0"
        and type(log._DESCRIPTION) == "string")
    ok("level constants exposed",
        log.TRACE == 10 and log.DEBUG == 20 and log.INFO == 30
        and log.WARN == 40 and log.ERROR == 50)
    ok("five log functions exposed, no fatal level",
        type(log.trace) == "function"
        and type(log.debug) == "function"
        and type(log.info) == "function"
        and type(log.warn) == "function"
        and type(log.error) == "function"
        and log.fatal == nil)
    ok("setters/getters exposed",
        type(log.set_level) == "function"
        and type(log.set_output) == "function"
        and type(log.set_color) == "function"
        and type(log.get_level) == "function"
        and type(log.get_output) == "function"
        and type(log.get_color) == "function")

    -- ----- défauts --------------------------------------------------

    ok("default threshold = info (30)", log.get_level() == log.INFO)
    ok("default destination = io.stderr",
        log.get_output() == io.stderr)
    ok("colors OFF by default (opt-in)", log.get_color() == false)
    ok("getters return exactly one value",
        select("#", log.get_level()) == 1
        and select("#", log.get_output()) == 1
        and select("#", log.get_color()) == 1)

    -- ----- write collection: in-memory sink for observation --------

    local function make_sink()
        local s = { written = {}, calls = 0 }
        function s:write(...)
            self.calls = self.calls + 1
            for i = 1, select("#", ...) do
                self.written[#self.written + 1] = select(i, ...)
            end
            return true
        end

        function s:joined() return table.concat(self.written) end

        function s:clear()
            self.written = {}
            self.calls = 0
        end

        return s
    end

    -- ----- set_output / format -------------------------------------

    do
        local sink = make_sink()
        ok("set_output returns no values",
            select("#", log.set_output(sink)) == 0)
        ok("set_output does not write during validation", sink.calls == 0)
        ok("get_output returns the exact sink", log.get_output() == sink)
        log.set_level(log.DEBUG)
        log.set_color(false)

        sink:clear()
        ok("log function returns no values",
            select("#", log.info("hello world")) == 0)
        local out = sink:joined()
        ok("emission performs one write call", sink.calls == 1)
        ok("emission produces a newline-terminated line",
            out:sub(-1) == "\n", "out=" .. out)
        ok("format includes the level [INFO ]",
            out:find("[INFO ]", 1, true) ~= nil, "out=" .. out)
        ok("format includes the message",
            out:find("hello world", 1, true) ~= nil)
        ok("format starts with a local date/time timestamp",
            out:find("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d ") ~= nil,
            "out=" .. out)

        sink:clear()
        log.info("user=", 42, "status=", "ok")
        out = sink:joined()
        ok("variadic arguments are joined with spaces",
            out:find("user= 42 status= ok", 1, true) ~= nil,
            "out=" .. out)

        sink:clear()
        log.info("a", nil, false)
        ok("nil and booleans are formatted through tostring",
            sink:joined():find("a nil false", 1, true) ~= nil)

        sink:clear()
        log.info()
        out = sink:joined()
        ok("zero message arguments still emit an empty message line",
            out:find("[INFO ] \n", 1, true) ~= nil, "out=" .. out)

        sink:clear()
        log.info("a\0b")
        out = sink:joined()
        ok("messages preserve embedded NUL bytes",
            out:find("a\0b", 1, true) ~= nil)

        sink:clear()
        log.info("line1\nline2")
        out = sink:joined()
        ok("embedded newlines are not escaped",
            out:find("line1\nline2", 1, true) ~= nil)
    end

    -- ----- filtrage par seuil ---------------------------------------

    do
        local sink = make_sink()
        log.set_output(sink)
        log.set_color(false)
        log.set_level(log.WARN)

        sink:clear()
        log.trace("t"); log.debug("d"); log.info("i")
        ok("threshold WARN filters trace/debug/info",
            sink:joined() == "", "out=" .. sink:joined())

        sink:clear()
        log.warn("w"); log.error("e")
        local out = sink:joined()
        ok("threshold WARN keeps warn and error",
            out:find("[WARN ]", 1, true) ~= nil
            and out:find("[ERROR]", 1, true) ~= nil)

        local tostring_calls = 0
        local lazy = setmetatable({}, {
            __tostring = function()
                tostring_calls = tostring_calls + 1
                return "lazy"
            end,
        })
        sink:clear()
        log.set_level(log.ERROR)
        log.info(lazy)
        ok("filtered messages do not evaluate tostring",
            tostring_calls == 0 and sink:joined() == "")

        log.set_level(35)
        sink:clear()
        log.info("i"); log.warn("w")
        ok("custom numeric threshold participates in comparison",
            sink:joined():find("[INFO ]", 1, true) == nil
            and sink:joined():find("[WARN ]", 1, true) ~= nil)

        log.set_level(25.5)
        ok("finite fractional thresholds remain supported",
            log.get_level() == 25.5)
    end

    -- ----- set_level ------------------------------------------------

    do
        ok("set_level returns no values",
            select("#", log.set_level("ERROR")) == 0)
        ok("set_level is case-insensitive for names",
            log.get_level() == log.ERROR)
        log.set_level("debug")
        ok("set_level('debug') -> DEBUG", log.get_level() == log.DEBUG)
        log.set_level(log.INFO)
        ok("set_level(log.INFO) -> INFO", log.get_level() == log.INFO)

        local before = log.get_level()
        ok("set_level rejects NaN",
            pcall(function() log.set_level(0 / 0) end) == false)
        ok("set_level rejects +infinity",
            pcall(function() log.set_level(math.huge) end) == false)
        ok("set_level rejects -infinity",
            pcall(function() log.set_level(-math.huge) end) == false)
        ok("invalid numeric levels leave the threshold unchanged",
            log.get_level() == before)
        ok("numeric strings are not coerced to thresholds",
            pcall(function() log.set_level("30") end) == false)
        ok("level names are not whitespace-trimmed",
            pcall(function() log.set_level(" info ") end) == false)
        ok("set_level rejects unknown names",
            pcall(function() log.set_level("xxxx") end) == false)
        ok("set_level rejects unrelated types",
            pcall(function() log.set_level({}) end) == false)
    end

    -- ----- couleurs -------------------------------------------------

    do
        local sink = make_sink()
        log.set_output(sink)
        log.set_level(log.TRACE)

        ok("set_color returns no values",
            select("#", log.set_color(false)) == 0)
        sink:clear(); log.warn("zz")
        ok("color OFF emits no ANSI sequence",
            sink:joined():find("\27[", 1, true) == nil,
            "out=" .. sink:joined())

        log.set_color(true)
        ok("get_color reflects enabled state", log.get_color() == true)

        sink:clear(); log.trace("zz")
        ok("color ON + trace uses dim ANSI",
            sink:joined():find("\27[2m", 1, true) ~= nil)

        sink:clear(); log.debug("zz")
        ok("color ON + debug uses cyan ANSI",
            sink:joined():find("\27[36m", 1, true) ~= nil)

        sink:clear(); log.warn("zz")
        ok("color ON + warn uses yellow ANSI",
            sink:joined():find("\27[33m", 1, true) ~= nil)

        sink:clear(); log.error("zz")
        ok("color ON + error uses red ANSI",
            sink:joined():find("\27[31m", 1, true) ~= nil)

        sink:clear(); log.info("zz")
        ok("color ON + info remains uncolored",
            sink:joined():find("\27[", 1, true) == nil,
            "out=" .. sink:joined())

        sink:clear(); log.warn("zz")
        ok("colored lines reset ANSI before the newline",
            sink:joined():find("\27[0m\n", 1, true) ~= nil)

        log.set_color(false)
        ok("get_color reflects disabled state", log.get_color() == false)
        ok("set_color is strict boolean",
            pcall(function() log.set_color("yes") end) == false)
    end

    -- ----- validation des sinks ------------------------------------

    do
        local sink = make_sink()
        log.set_output(sink)

        ok("set_output rejects primitive values",
            pcall(function() log.set_output(42) end) == false)
        ok("set_output rejects a table without write",
            pcall(function() log.set_output({}) end) == false)
        ok("set_output rejects a non-callable write member",
            pcall(function() log.set_output({ write = true }) end) == false)

        local inherited = setmetatable({ written = {} }, {
            __index = {
                write = function(self, line)
                    self.written[#self.written + 1] = line
                end,
            },
        })
        ok("set_output accepts a write method supplied by __index",
            pcall(function() log.set_output(inherited) end) == true)
        log.set_level(log.INFO)
        log.info("inherited")
        ok("inherited write method is used with colon semantics",
            #inherited.written == 1
            and inherited.written[1]:find("inherited", 1, true) ~= nil)

        local hostile = setmetatable({}, {
            __index = function() error("hostile __index") end,
        })
        local before = log.get_output()
        ok("set_output controls errors raised while looking up write",
            pcall(function() log.set_output(hostile) end) == false)
        ok("failed set_output leaves the previous sink installed",
            log.get_output() == before)

        local db = assert(babet.sqlite.open(":memory:"))
        ok("set_output rejects userdata without a write method",
            pcall(function() log.set_output(db) end) == false)
        db:close()

        log.set_output(sink)
    end

    -- ----- arités strictes ------------------------------------------

    do
        ok("set_level requires exactly one argument",
            pcall(function() log.set_level() end) == false
            and pcall(function() log.set_level("info", "extra") end)
                == false)
        ok("set_output requires exactly one argument",
            pcall(function() log.set_output() end) == false
            and pcall(function() log.set_output(io.stderr, "extra") end)
                == false)
        ok("set_color requires exactly one argument",
            pcall(function() log.set_color() end) == false
            and pcall(function() log.set_color(false, true) end) == false)
        ok("get_level rejects extra arguments",
            pcall(function() log.get_level(true) end) == false)
        ok("get_output rejects extra arguments",
            pcall(function() log.get_output(true) end) == false)
        ok("get_color rejects extra arguments",
            pcall(function() log.get_color(true) end) == false)
    end

    -- ----- contrat no-throw des fonctions d'émission ----------------

    do
        local sink = make_sink()
        log.set_output(sink)
        log.set_level(log.INFO)
        log.set_color(false)

        local exploding_value = setmetatable({}, {
            __tostring = function() error("boom tostring") end,
        })
        sink:clear()
        ok("raising __tostring does not escape log.info",
            pcall(function() log.info(exploding_value) end) == true)
        ok("failed tostring drops the whole message",
            sink:joined() == "")

        local old_date = os.date
        os.date = function() error("boom date") end
        local date_call_ok = pcall(function() log.info("test") end)
        os.date = old_date
        ok("raising os.date does not escape log.info", date_call_ok)

        local exploding_sink = { write = function() error("boom write") end }
        log.set_output(exploding_sink)
        ok("raising sink does not escape log.info",
            pcall(function() log.info("test") end) == true)

        local mutable_sink = make_sink()
        log.set_output(mutable_sink)
        mutable_sink.write = nil
        ok("sink mutated after set_output is still failure-safe",
            pcall(function() log.info("test") end) == true)

        log.set_output(io.stderr)
        log.set_level(log.INFO)
        log.set_color(false)
    end
end
-- =====================================================================
print("")

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

    -- borne exacte documentée : 0..3 600 000 ms
    do
        local db = DB.open(":memory:", { busy_timeout = 3600000 })
        ok("open(opts.busy_timeout = 3600000) accepted", db ~= nil)
        if db then db:close() end

        local pok = pcall(DB.open, ":memory:", { busy_timeout = 3600001 })
        ok("open(opts.busy_timeout = 3600001) raises", not pok)
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

    do
        local db, err = DB.open(":memory:\0on-disk")
        ok_fail("LOT 3 sqlite.open: NUL in path rejected", db, err)
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

    -- ----- LOT 5B : SQL contenant un NUL ----------------------------
    do
        local db = DB.open(":memory:")
        local ev, ee = db:exec(
            "CREATE TABLE nul_guard(x)\0; INSERT INTO nul_guard VALUES (1)")
        ok_fail("LOT 5B sqlite.exec rejects NUL in SQL text", ev, ee)
        ok("  NUL error is explicit",
            type(ee) == "string" and ee:find("NUL", 1, true) ~= nil,
            "err=" .. tostring(ee))

        local created = -1
        for row in db:query([[
            SELECT COUNT(*) AS n
            FROM sqlite_master
            WHERE type = 'table' AND name = 'nul_guard'
        ]]) do
            created = row.n
        end
        ok("  rejected SQL has no executed prefix", created == 0,
            "created=" .. tostring(created))

        local qi, qe = db:query("SELECT 1 AS x\0; SELECT 2 AS x")
        ok_fail("LOT 5B sqlite.query rejects NUL in SQL text", qi, qe)
        ok("  query NUL error is explicit",
            type(qe) == "string" and qe:find("NUL", 1, true) ~= nil,
            "err=" .. tostring(qe))
        db:close()
    end

    -- ----- SQL vide/commentaire avec params -------------------------
    do
        local db = DB.open(":memory:")
        local ok1, err1 = db:exec("", {})
        ok("exec('', {}) is a successful no-op", ok1 == true and err1 == nil,
            "err=" .. tostring(err1))
        local ok2, err2 = db:exec("-- commentaire seulement", {})
        ok("exec(comment-only, {}) is a successful no-op",
            ok2 == true and err2 == nil, "err=" .. tostring(err2))

        local pok, perr = pcall(db.exec, db, "", { 1 })
        ok("exec('', non-empty params) raises", not pok)
        ok("  message mentions no statement",
            type(perr) == "string" and perr:find("no statement", 1, true))
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

        local params_with_nul = { a = 1 }
        params_with_nul["a\0evil"] = "extra"
        local pok_nul, perr_nul = pcall(db.exec, db,
            "INSERT INTO t VALUES (:a)", params_with_nul)
        ok("LOT 3 sqlite: NUL in named parameter key is not truncated",
            not pok_nul)
        ok("  NUL key is reported as an extra parameter",
            type(perr_nul) == "string" and perr_nul:find("extra param", 1, true))

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

        local ok3, err3 = db:exec(
            "INSERT INTO t VALUES (?); -- commentaire final\n", { 3 })
        ok("LOT 4 exec avec commentaire -- final accepté",
            ok3 == true and err3 == nil, "err=" .. tostring(err3))

        local ok4, err4 = db:exec(
            "INSERT INTO t VALUES (?); /* commentaire final */", { 4 })
        ok("LOT 4 exec avec commentaire /* */ final accepté",
            ok4 == true and err4 == nil, "err=" .. tostring(err4))

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

    -- ----- query vide/commentaire : itérateur déjà épuisé ----------
    do
        local db = DB.open(":memory:")
        local iter, err = db:query("-- commentaire seulement", {})
        ok("query(comment-only, {}) returns an iterator",
            type(iter) == "userdata" and err == nil,
            "err=" .. tostring(err))
        ok("  iterator is already exhausted", iter() == nil)

        local pok, perr = pcall(db.query, db, "", { x = 1 })
        ok("query('', non-empty params) raises", not pok)
        ok("  message mentions no statement",
            type(perr) == "string" and perr:find("no statement", 1, true))
        db:close()
    end

    -- ----- query est réellement paresseux ----------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x INTEGER)")
        local iter = assert(db:query("INSERT INTO t VALUES (7)"))

        local before
        for row in db:query("SELECT COUNT(*) AS n FROM t") do before = row.n end
        ok("query DML is not stepped before iterator call", before == 0)

        ok("first iterator call executes DML and returns nil", iter() == nil)
        local after
        for row in db:query("SELECT COUNT(*) AS n FROM t") do after = row.n end
        ok("query DML effect visible after iterator call", after == 1)
        db:close()
    end

    -- ----- noms de colonnes dupliqués -------------------------------
    do
        local db = DB.open(":memory:")
        local row
        for r in db:query("SELECT 1 AS x, 2 AS x") do row = r end
        ok("duplicate column names: last value wins", row.x == 2,
            "x=" .. tostring(row and row.x))
        db:close()
    end

    -- ----- erreur au step de l'itérateur ----------------------------
    do
        local db = DB.open(":memory:")
        db:exec("CREATE TABLE t (x INTEGER CHECK (x > 0))")
        local iter = assert(db:query("INSERT INTO t VALUES (?)", { -1 }))
        local pok, perr = pcall(iter)
        ok("query step error raises", not pok)
        ok("  message is prefixed with sqlite.query",
            type(perr) == "string" and perr:find("sqlite.query", 1, true))
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

        local iter2, err2 = db:query(
            "SELECT 42 AS answer; -- commentaire final\n")
        local row2 = iter2 and iter2()
        ok("LOT 4 query avec commentaire -- final accepté",
            type(iter2) == "userdata" and err2 == nil
            and type(row2) == "table" and row2.answer == 42,
            "err=" .. tostring(err2))
        if iter2 then iter2:close() end

        local iter3, err3 = db:query(
            "SELECT 43 AS answer; /* commentaire final */")
        local row3 = iter3 and iter3()
        ok("LOT 4 query avec commentaire /* */ final accepté",
            type(iter3) == "userdata" and err3 == nil
            and type(row3) == "table" and row3.answer == 43,
            "err=" .. tostring(err3))
        if iter3 then iter3:close() end

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
        for r in db:query(
            "SELECT *, typeof(b) AS b_storage_class FROM t") do
            row = r
        end
        ok("round-trip integer", row.i == 42)
        ok("round-trip float", math.abs(row.f - 3.14) < 1e-9)
        ok("round-trip text", row.s == "hello")
        ok("string bound in BLOB-affinity column keeps 3 bytes", #row.b == 3)
        ok("  first byte == 1", string.byte(row.b, 1) == 1)
        ok("  bound Lua string is stored as SQLite TEXT",
            row.b_storage_class == "text",
            "typeof(b)=" .. tostring(row.b_storage_class))

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

-- =====================================================================
print("")
print("=== sqlite (session 4: prepared/blob/transactions) ===")

do
    local DB = babet.sqlite

    -- ----- explicit BLOB wrapper ------------------------------------
    ok("sqlite.blob is a function", type(DB.blob) == "function")

    do
        local pok0 = pcall(DB.blob)
        ok("sqlite.blob requires exactly one argument", not pok0)

        local pok1 = pcall(DB.blob, 42)
        ok("sqlite.blob requires a strict string", not pok1)

        local pok2 = pcall(DB.blob, "x", "extra")
        ok("sqlite.blob rejects extra arguments", not pok2)

        local blob = DB.blob("a\0b")
        ok("sqlite.blob returns userdata", type(blob) == "userdata")
        ok("sqlite.blob tostring is informative",
            tostring(blob):find("sqlite.blob") ~= nil
            and tostring(blob):find("3 bytes") ~= nil)
    end

    -- ----- prepare contract and reusable exec/query ----------------
    do
        local db = assert(DB.open(":memory:"))
        ok("db.prepare is a function", type(db.prepare) == "function")
        ok("db.transaction is a function", type(db.transaction) == "function")
        ok("db.in_transaction is a function",
            type(db.in_transaction) == "function")

        local pok0 = pcall(db.prepare, db)
        ok("db:prepare requires SQL", not pok0)

        local pok1 = pcall(db.prepare, db, 42)
        ok("db:prepare SQL is a strict string", not pok1)

        local pok2 = pcall(db.prepare, db, "SELECT 1", "extra")
        ok("db:prepare rejects extra arguments", not pok2)

        local nul_stmt, nul_err = db:prepare("SELECT 1\0; SELECT 2")
        ok("db:prepare rejects NUL in SQL",
            nul_stmt == nil and type(nul_err) == "string"
            and nul_err:find("NUL"))

        local empty_stmt, empty_err = db:prepare(" -- comment only")
        ok("db:prepare rejects empty/comment-only SQL",
            empty_stmt == nil and type(empty_err) == "string")

        local multi_stmt, multi_err = db:prepare("SELECT 1; SELECT 2")
        ok("db:prepare rejects multiple statements",
            multi_stmt == nil and type(multi_err) == "string"
            and multi_err:find("one statement"))

        local invalid_stmt, invalid_err = db:prepare("SELECT * FROM absent")
        ok("db:prepare invalid SQL -> (nil, err)",
            invalid_stmt == nil and type(invalid_err) == "string"
            and invalid_err:find("^sqlite: "))

        assert(db:exec([[
            CREATE TABLE items (
                id INTEGER PRIMARY KEY,
                payload BLOB NOT NULL,
                label TEXT NOT NULL UNIQUE
            )
        ]]))

        local ins = assert(db:prepare(
            "INSERT INTO items(id, payload, label) VALUES(?, ?, ?)"))
        ok("prepare returns reusable userdata", type(ins) == "userdata")
        ok("prepared tostring mentions ready",
            tostring(ins):find("sqlite.prepared") ~= nil
            and tostring(ins):find("ready") ~= nil)
        ok("prepared methods are exposed",
            type(ins.exec) == "function"
            and type(ins.query) == "function"
            and type(ins.reset) == "function"
            and type(ins.close) == "function"
            and type(ins.finalize) == "function")
        ok("prepared userdata is inert before query()", ins() == nil)

        assert(ins:exec({ 1, DB.blob("\0A"), "one" }))
        assert(ins:exec({ 2, DB.blob("B\0C"), "two" }))
        assert(ins:exec({ 3, DB.blob(""), "three" }))
        ok("prepared:exec can be reused", true)

        local no_params, no_params_err = ins:exec()
        ok("prepared:exec detects omitted params",
            no_params == nil and type(no_params_err) == "string"
            and no_params_err:find("placeholders"))

        local pok3 = pcall(ins.exec, ins, "bad")
        ok("prepared:exec params must be a table", not pok3)

        local pok4, perr4 = pcall(ins.exec, ins,
            { 4, DB.blob("x"), "four", "extra" })
        ok("prepared:exec rejects extra params",
            not pok4 and type(perr4) == "string"
            and perr4:find("too many"))

        local dup_ok, dup_err = ins:exec({ 4, DB.blob("x"), "one" })
        ok("prepared:exec reports SQLite constraint errors",
            dup_ok == nil and type(dup_err) == "string")
        assert(ins:exec({ 4, DB.blob("x"), "four" }))
        ok("prepared statement remains reusable after step error", true)

        local q = assert(db:prepare([[
            SELECT id, payload, label, typeof(payload) AS payload_type
            FROM items
            WHERE id >= ?
            ORDER BY id
        ]]))

        local iterator = assert(q:query({ 2 }))
        ok("prepared:query returns the same userdata", iterator == q)

        local ids = {}
        local storage_ok = true
        for row in iterator do
            ids[#ids + 1] = row.id
            storage_ok = storage_ok and row.payload_type == "blob"
        end
        ok("prepared query streams rows", #ids == 3
            and ids[1] == 2 and ids[3] == 4)
        ok("explicit blob values use SQLite BLOB storage", storage_ok)
        ok("prepared userdata is inert after query exhaustion", q() == nil)

        local only_four
        for row in q:query({ 4 }) do only_four = row end
        ok("prepared query can be rebound and reused",
            only_four and only_four.id == 4 and only_four.label == "four")

        -- Break early, then reset explicitly before the next execution.
        for _ in q:query({ 1 }) do break end
        local reset_ok, reset_err = q:reset()
        ok("prepared:reset aborts an active iteration",
            reset_ok == true and reset_err == nil)

        local count = 0
        for _ in q:query({ 1 }) do count = count + 1 end
        ok("prepared query works after reset", count == 4)

        -- Starting a new query also resets any previous partial iteration.
        local first = q:query({ 1 })()
        local last = q:query({ 4 })()
        ok("prepared:query automatically resets previous state",
            first and first.id == 1 and last and last.id == 4)
        q:reset()

        local q_missing, q_missing_err = q:query()
        ok("prepared:query detects omitted params",
            q_missing == nil and type(q_missing_err) == "string"
            and q_missing_err:find("placeholders"))

        assert(q:exec({ 1 }))
        ok("prepared:exec exhausts SELECT rows and remains reusable", true)

        -- A prepared statement survives db:close() through close_v2.
        local zombie = assert(db:prepare(
            "SELECT label FROM items WHERE id = ?"))
        assert(db:close())
        local zombie_row = zombie:query({ 2 })()
        ok("prepared statement remains usable after db:close()",
            zombie_row and zombie_row.label == "two")
        zombie:reset()
        assert(zombie:finalize())

        assert(ins:close())
        assert(ins:close())
        ok("prepared close is idempotent", true)
        ok("prepared tostring mentions closed",
            tostring(ins):find("closed") ~= nil)

        local closed_exec, closed_exec_err = ins:exec({})
        ok("prepared:exec after close -> (nil, err)",
            closed_exec == nil and type(closed_exec_err) == "string"
            and closed_exec_err:find("closed"))
        ok("calling a closed prepared iterator returns nil", ins() == nil)
    end

    -- ----- TEXT remains TEXT; sqlite.blob forces BLOB ---------------
    do
        local db = assert(DB.open(":memory:"))
        assert(db:exec("CREATE TABLE values_test(v)"))
        local stmt = assert(db:prepare("INSERT INTO values_test VALUES(?)"))
        assert(stmt:exec({ "a\0b" }))
        assert(stmt:exec({ DB.blob("a\0b") }))
        assert(stmt:exec({ DB.blob("") }))

        local types = {}
        local lengths = {}
        for row in db:query([[
            SELECT rowid, typeof(v) AS storage,
                   length(CAST(v AS BLOB)) AS len
            FROM values_test ORDER BY rowid
        ]]) do
            types[#types + 1] = row.storage
            lengths[#lengths + 1] = row.len
        end
        ok("plain Lua strings still bind as TEXT",
            types[1] == "text" and lengths[1] == 3)
        ok("sqlite.blob binds the same bytes as BLOB",
            types[2] == "blob" and lengths[2] == 3)
        ok("sqlite.blob preserves an empty BLOB storage class",
            types[3] == "blob" and lengths[3] == 0)

        stmt:finalize()
        db:close()
    end

    -- ----- transaction helper ---------------------------------------
    do
        local db = assert(DB.open(":memory:"))
        assert(db:exec([[
            CREATE TABLE tx_log (
                id INTEGER PRIMARY KEY,
                value TEXT UNIQUE NOT NULL
            )
        ]]))

        ok("in_transaction is false outside a transaction",
            db:in_transaction() == false)

        local tx_ok, a, b, c = db:transaction(function(tx)
            ok("in_transaction is true inside callback",
                tx:in_transaction() == true)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 1, "committed" }))
            return "result", nil, false
        end, "immediate")
        ok("transaction commits and forwards callback values",
            tx_ok == true and a == "result" and b == nil and c == false)
        ok("in_transaction is false after commit",
            db:in_transaction() == false)

        local false_ok, false_value = db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 2, "false-return" }))
            return false
        end)
        ok("normal false callback return still commits",
            false_ok == true and false_value == false)

        local rollback_ok, rollback_err = db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 3, "rolled-back" }))
            error({ code = 99 })
        end, "exclusive")
        ok("transaction callback error returns (nil, err)",
            rollback_ok == nil and type(rollback_err) == "string"
            and rollback_err:find("callback failed"))

        local present = {}
        for row in db:query("SELECT id FROM tx_log ORDER BY id") do
            present[#present + 1] = row.id
        end
        ok("callback error rolls back all writes",
            #present == 2 and present[1] == 1 and present[2] == 2)

        local constraint_ok, constraint_err = db:transaction(function(tx)
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 4, "committed" })) -- duplicate UNIQUE value
        end)
        ok("asserted SQLite failure rolls transaction back",
            constraint_ok == nil and type(constraint_err) == "string")

        local row4
        for row in db:query("SELECT id FROM tx_log WHERE id = 4") do
            row4 = row
        end
        ok("failed transaction inserted no partial row", row4 == nil)

        -- Every documented transaction mode is accepted.
        for i, mode in ipairs({ "deferred", "immediate", "exclusive" }) do
            local mode_ok = db:transaction(function(tx)
                assert(tx:exec(
                    "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                    { 10 + i, mode }))
            end, mode)
            ok("transaction mode " .. mode .. " succeeds", mode_ok == true)
        end

        local bad_mode_ok, bad_mode_err = db:transaction(function() end, "bad")
        ok("transaction rejects unknown mode",
            bad_mode_ok == nil and type(bad_mode_err) == "string"
            and bad_mode_err:find("mode"))

        local nul_mode_ok, nul_mode_err = db:transaction(
            function() end, "immediate\0ignored")
        ok("transaction rejects NUL in mode",
            nul_mode_ok == nil and type(nul_mode_err) == "string"
            and nul_mode_err:find("NUL"))

        local pok_cb = pcall(db.transaction, db, "not a function")
        ok("transaction callback must be a function", not pok_cb)

        local pok_mode = pcall(db.transaction, db, function() end, 42)
        ok("transaction mode must be a strict string", not pok_mode)

        local pok_extra = pcall(db.transaction, db,
            function() end, "deferred", "extra")
        ok("transaction rejects extra arguments", not pok_extra)

        -- Nested helper is refused without corrupting the outer helper.
        local outer_ok, nested_ok, nested_err = db:transaction(function(tx)
            return tx:transaction(function() end)
        end)
        ok("nested transaction helper is refused",
            outer_ok == true and nested_ok == nil
            and type(nested_err) == "string"
            and nested_err:find("nested"))

        assert(db:exec("BEGIN"))
        local manual_ok, manual_err = db:transaction(function() end)
        ok("transaction helper refuses an existing manual transaction",
            manual_ok == nil and type(manual_err) == "string"
            and manual_err:find("already"))
        assert(db:exec("ROLLBACK"))

        local close_result, close_error
        local close_tx_ok = db:transaction(function(tx)
            close_result, close_error = tx:close()
            assert(tx:exec(
                "INSERT INTO tx_log(id, value) VALUES(?, ?)",
                { 30, "close-refused" }))
        end)
        ok("db:close is refused inside transaction callback",
            close_tx_ok == true and close_result == nil
            and type(close_error) == "string"
            and close_error:find("transaction callback"))

        assert(db:close())
        local closed_tx, closed_tx_err = db:transaction(function() end)
        ok("transaction after db close -> (nil, err)",
            closed_tx == nil and type(closed_tx_err) == "string"
            and closed_tx_err:find("closed"))
        local closed_state, closed_state_err = db:in_transaction()
        ok("in_transaction after db close -> (nil, err)",
            closed_state == nil and type(closed_state_err) == "string"
            and closed_state_err:find("closed"))
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

    -- ----- nombres : int64 exacts, bases, inf et nan ---------------

    do
        local r, e = T.decode([[
max = 9223372036854775807
min = -9223372036854775808
hex = 0xDEAD_BEEF
oct = 0o755
bin = 0b11010110
pos_inf = inf
plus_inf = +inf
neg_inf = -inf
not_a_number = nan
]])
        ok_val("decode numeric limits and special floats", r, e)
        ok("  TOML int64 max -> math.maxinteger",
            r and r.max == math.maxinteger,
            "max=" .. tostring(r and r.max))
        ok("  TOML int64 min -> math.mininteger",
            r and r.min == math.mininteger,
            "min=" .. tostring(r and r.min))
        ok("  hexadecimal integer normalized",
            r and r.hex == 0xDEADBEEF)
        ok("  octal integer normalized", r and r.oct == 493)
        ok("  binary integer normalized", r and r.bin == 214)
        ok("  inf and +inf -> math.huge",
            r and r.pos_inf == math.huge and r.plus_inf == math.huge)
        ok("  -inf -> -math.huge", r and r.neg_inf == -math.huge)
        ok("  nan -> Lua NaN", r and r.not_a_number ~= r.not_a_number)

        local v
        v, e = T.decode("n = 9223372036854775808")
        ok_fail("integer above int64 max -> (nil, err)", v, e)
        v, e = T.decode("n = -9223372036854775809")
        ok_fail("integer below int64 min -> (nil, err)", v, e)
    end

    -- ----- clés et chaînes binary-safe -------------------------------

    do
        local r, e = T.decode([[
"" = "empty key"
"a.b" = "literal dot"
"clé été" = "unicode"
"a\u0000b" = 7
nul_value = "x\u0000y"
]])
        ok_val("decode quoted, Unicode and NUL keys", r, e)
        ok("  empty quoted key preserved", r and r[""] == "empty key")
        ok("  dot in quoted key is not a dotted path",
            r and r["a.b"] == "literal dot")
        ok("  Unicode quoted key preserved",
            r and r["clé été"] == "unicode")
        ok("  escaped NUL in key is binary-safe",
            r and r["a\0b"] == 7 and r.a == nil,
            "nul-key=" .. tostring(r and r["a\0b"]))
        ok("  escaped NUL in value is binary-safe",
            r and type(r.nul_value) == "string"
            and #r.nul_value == 3 and r.nul_value == "x\0y")
    end

    do
        local r, e = T.decode([[
site."google.com" = true
physical.color = "orange"
physical.shape = "round"
]])
        ok_val("decode dotted keys", r, e)
        ok("  quoted dotted component preserved",
            r and r.site and r.site["google.com"] == true)
        ok("  dotted keys create nested Lua tables",
            r and r.physical and r.physical.color == "orange"
            and r.physical.shape == "round")
    end

    do
        local src = "ok = 1\n" .. string.char(0) .. "bad = 2\n"
        local v, e = T.decode(src)
        ok_fail("raw NUL in TOML text is rejected, not truncated", v, e)

        src = 'msg = "' .. string.char(0xFF) .. '"'
        v, e = T.decode(src)
        ok_fail("invalid UTF-8 TOML is rejected", v, e)
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

    -- ----- tableaux hétérogènes et conteneurs vides ----------------

    do
        local r, e = T.decode([[
values = [1, "two", true, { x = 3 }]
empty_array = []
empty_table = {}
]])
        ok_val("decode heterogeneous and empty containers", r, e)
        ok("  TOML 1.0 heterogeneous array preserved",
            r and type(r.values) == "table" and #r.values == 4
            and r.values[1] == 1 and r.values[2] == "two"
            and r.values[3] == true
            and type(r.values[4]) == "table" and r.values[4].x == 3)
        ok("  empty TOML array -> empty Lua table",
            r and type(r.empty_array) == "table"
            and next(r.empty_array) == nil)
        ok("  empty inline table -> empty Lua table",
            r and type(r.empty_table) == "table"
            and next(r.empty_table) == nil)
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

    -- ----- profil TOML 1.0 : extensions hors profil désactivées -------

    do
        local v, e = T.decode("short_time = 07:32")
        ok_fail("optional-seconds extension is rejected", v, e)
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
        ok("decode(text, extra) raises",
            pcall(function() return T.decode("x = 1", true) end) == false)
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
    ok("exists('root\\0evil') raises",
        pcall(function() return U.exists("root\0evil") end) == false)
    ok("exists(2^33) raises",
        pcall(function() return U.exists(8589934592) end) == false)

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

    -- NSS lookups are available from worker-local Lua states too.
    do
        local w, err = babet.workers.spawn([[
            local u, lookup_err = babet.user.get("root")
            if not u then
                error(lookup_err)
            end
            return u.uid
        ]])
        ok_val("user.get() available in a worker", w, err)
        if w then
            local joined, uid = w:join()
            ok("  worker resolved root uid 0",
                joined == true and uid == 0,
                "joined=" .. tostring(joined)
                .. " uid=" .. tostring(uid))
        end
    end
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
        ok("new(extra) raises instead of ignoring the argument",
            pcall(function() return I.new(true) end) == false)
        ok("add(path, events, opts, extra) raises",
            pcall(function()
                return w:add(WDIR, { "create" }, nil, true)
            end) == false)
        ok("read(timeout, extra) raises",
            pcall(function() return w:read(0, true) end) == false)
        ok("remove(wd, extra) raises",
            pcall(function() return w:remove(1, true) end) == false)
        ok("close(extra) raises",
            pcall(function() return w:close(true) end) == false)
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


        v, e = w:read(1e300)
        ok_fail("LOT 3 inotify.read: huge timeout rejected", v, e)
        ok("  huge timeout message mentions 'too large'",
            type(e) == "string" and e:find("too large", 1, true) ~= nil,
            tostring(e))

        v, e = w:remove(math.maxinteger)
        ok_fail("LOT 3 inotify.remove: wd overflow rejected", v, e)
        ok("  wd overflow message mentions 'range'",
            type(e) == "string" and e:find("range", 1, true) ~= nil,
            tostring(e))

        v, e = w:add(WDIR .. "\0ignored", { "create" })
        ok_fail("LOT 3 inotify.add: NUL in path rejected", v, e)
        v, e = w:add(WDIR, { "create\0ignored" })
        ok_fail("LOT 3 inotify.add: NUL in event rejected", v, e)

        v, e = w:add(WDIR, { "create" }, { onlydir = "false" })
        ok_fail("inotify.add opts.onlydir must be a strict boolean", v, e)
        ok("  onlydir error mentions boolean",
            type(e) == "string" and e:find("boolean", 1, true) ~= nil,
            tostring(e))
    end

    -- ----- onlydir option -------------------------------------------
    do
        local FILE_PATH = WDIR .. "/onlydir-file.txt"
        local f = assert(io.open(FILE_PATH, "w")); f:close()

        local v, e = w:add(FILE_PATH, { "modify" }, { onlydir = true })
        ok_fail("add(file, ..., {onlydir=true}) rejects a non-directory", v, e)

        local file_wd, file_err = w:add(FILE_PATH, { "modify" },
            { onlydir = false })
        ok_val("add(file, ..., {onlydir=false}) remains valid",
            file_wd, file_err,
            function(x) return math.type(x) == "integer" end)
        if file_wd then
            ok_act("remove(file watch)", w:remove(file_wd))
            w:read(0.2) -- consume the kernel-generated ignored event
        end
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
    ok("tostring(active watcher) mentions inotify and fd",
        tostring(w):find("inotify", 1, true) ~= nil
        and tostring(w):find("fd=", 1, true) ~= nil)
    ok_act("close() -> (true, nil)", w:close())
    ok_act("close() again (idempotent)", w:close())
    ok("tostring(closed watcher) mentions closed",
        tostring(w):find("closed", 1, true) ~= nil)

    do
        local v, e = w:read(0)
        ok_fail("read() after close -> (nil, err)", v, e)
        ok("  message mentions 'closed'",
            type(e) == "string" and e:find("closed", 1, true) ~= nil)

        local v2, e2 = w:add(WDIR, { "create" })
        ok_fail("add() after close -> (nil, err)", v2, e2)

        local v3, e3 = w:remove(1)
        ok_fail("remove() after close -> (nil, err)", v3, e3)
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
        while type(n) == "table" and n.c do n = n.c; d = d + 1 end
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
    ok("DOC 3 spawn(42) raises (strict code string)",
        pcall(function() return W.spawn(42) end) == false)
    ok("spawn('code', 42) raises (args not a table)",
        pcall(function() return W.spawn("return 1", 42) end) == false)
    ok("spawn('code', nil, 42) raises (opts not a table)",
        pcall(function() return W.spawn("return 1", nil, 42) end)
        == false)

    ok("LOT 11 workers.spawn rejects excess arguments",
        pcall(function()
            return W.spawn("return 1", nil, nil, "extra")
        end) == false)

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

    -- ----- formes de tables et chaînes transférables -------------

    do
        local sparse, sparse_err = W.spawn("return 1", { [2] = "x" })
        ok_fail("DOC 3 workers: sparse args table rejected",
            sparse, sparse_err)

        local mixed, mixed_err = W.spawn("return 1",
            { [1] = "x", name = "mixed" })
        ok_fail("DOC 3 workers: mixed list/map args rejected",
            mixed, mixed_err)

        local nul_value, nul_value_err = W.spawn("return 1",
            { value = "a\0b" })
        ok_fail("DOC 3 workers: NUL string in args rejected",
            nul_value, nul_value_err)
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

        w = W.spawn("error({ code = 42 })")
        jok, val = w:join()
        ok("LOT 5B worker non-string error has a useful diagnostic",
            jok == false and type(val) == "string"
            and (val:find("table:", 1, true) ~= nil
                 or val:find("type table", 1, true) ~= nil),
            "ok=" .. tostring(jok) .. " val=" .. tostring(val))

        -- Code Lua invalid -> chargement échoue
        w = W.spawn("this is not valid lua %%%")
        jok, val = w:join()
        ok("join: invalid Lua code -> (false, msg)",
            jok == false and type(val) == "string")

        -- Régression lot 2 : une exception C++ produite pendant la
        -- sérialisation du résultat ne doit jamais sortir de la pthread
        -- et appeler std::terminate(). nlohmann/json refuse l'UTF-8
        -- invalide lors de dump(), ce qui fournit un cas reproductible.
        w = W.spawn("return string.char(0xc0, 0x80)")
        jok, val = w:join()
        ok("LOT 2 worker: exception C++ interne -> erreur explicite",
            jok == false and type(val) == "string"
            and val:find("unhandled C++ exception", 1, true) ~= nil,
            "ok=" .. tostring(jok) .. " val=" .. tostring(val))
        ok("  processus toujours vivant après l'exception worker",
            babet.pid() > 0)
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
        -- poll() consomme le résultat dès qu'il renvoie done/error.
        -- Le premier appel peut déjà voir done sur une machine rapide :
        -- dans ce cas, on utilise immédiatement sa valeur et on ne poll
        -- pas une deuxième fois comme si le résultat était encore présent.
        local w = W.spawn(
            "babet.sleep(300, 'ms'); return 'ok'")
        local state, value = w:poll()
        ok("poll right after spawn: 'running' or 'done'",
            state == "running" or state == "done",
            "state=" .. tostring(state))

        if state == "running" then
            babet.sleep(500, "ms")
            state, value = w:poll()
        end
        ok("poll final state: 'done'",
            state == "done",
            "state=" .. tostring(state))
        ok("  val == 'ok'", value == "ok")

        local joined_after_poll, join_err = w:join()
        ok("DOC 3 join after poll(done) reports already consumed",
            joined_after_poll == false
            and type(join_err) == "string"
            and join_err:find("already consumed", 1, true) ~= nil)

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

    -- ----- lot 2 : SIGPIPE reste process-wide intact -------------
    -- Ancien bug : chaque babet.exec() faisait temporairement
    -- sigaction(SIGPIPE, SIG_IGN). Deux exec concurrents pouvaient
    -- s'entrelacer ainsi : A sauve le handler, B sauve SIG_IGN,
    -- A restaure le handler, puis B restaure SIG_IGN définitivement.
    --
    -- Les deux shells sont bloqués par des fichiers de libération pour
    -- imposer exactement cet ordre, sans dépendre du scheduler.
    do
        local marker_a = sb("lot2_sigpipe_a_started")
        local marker_b = sb("lot2_sigpipe_b_started")
        local release_a = sb("lot2_sigpipe_a_release")
        local release_b = sb("lot2_sigpipe_b_release")

        local function wait_file(path, timeout)
            local deadline = babet.monotonic() + timeout
            while babet.monotonic() < deadline do
                local exists = babet.fileExists(path)
                if exists == true then return true end
                babet.sleep(10, "ms")
            end
            return false
        end

        local pipe_fired = false
        local handler_ok = babet.signal.handle("PIPE", function()
            pipe_fired = true
        end)
        ok("LOT 2 SIGPIPE: handler installé", handler_ok == true)

        local worker_code = [[
            local command = "printf x > " .. worker.args.marker
                .. "; while [ ! -e " .. worker.args.release
                .. " ]; do sleep 0.01; done"
            local result, err = babet.exec(
                "sh", { "-c", command }, { timeout = 5 })
            if not result then return { ok = false, err = err } end
            return { ok = result.code == 0, code = result.code }
        ]]

        local wa = W.spawn(worker_code,
            { marker = marker_a, release = release_a })
        local a_started = wa ~= nil and wait_file(marker_a, 2)
        ok("LOT 2 SIGPIPE: exec A actif", a_started)

        local wb
        local b_started = false
        if a_started then
            wb = W.spawn(worker_code,
                { marker = marker_b, release = release_b })
            b_started = wb ~= nil and wait_file(marker_b, 2)
        end
        ok("LOT 2 SIGPIPE: exec B actif pendant A", b_started)

        -- A se termine d'abord, puis B : ordre qui laissait SIGPIPE
        -- définitivement ignoré dans l'ancienne implémentation.
        babet.touch(release_a)
        local a_ok, a_result = false, nil
        if wa then a_ok, a_result = wa:join() end

        babet.touch(release_b)
        local b_ok, b_result = false, nil
        if wb then b_ok, b_result = wb:join() end

        ok("LOT 2 SIGPIPE: deux exec concurrents terminés",
            a_ok == true and type(a_result) == "table" and a_result.ok
            and b_ok == true and type(b_result) == "table" and b_result.ok)

        -- os.execute est utilisé volontairement : appeler babet.exec ici
        -- masquerait le bug historique en modifiant lui-même SIGPIPE.
        if handler_ok == true then
            os.execute("kill -PIPE " .. tostring(babet.pid()))

            -- Le module signal distribue les callbacks via un hook Lua.
            -- Cette boucle exécute assez d'instructions pour le déclencher.
            local dispatch_deadline = babet.monotonic() + 1
            while not pipe_fired
                and babet.monotonic() < dispatch_deadline do
                local accumulator = 0
                for i = 1, 20000 do accumulator = accumulator + i end
            end
        end

        ok("LOT 2 SIGPIPE: handler préservé après exec concurrents",
            handler_ok == true and pipe_fired == true)
        if handler_ok == true then
            babet.signal.handle("PIPE", nil)
        end
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
    -- send / recv / close côté parent
    -- ============================================================
    -- On valide ici la mécanique des queues : capacités, timeouts,
    -- fermeture, drainage et conventions de retour.

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

    -- ----- le worker ferme automatiquement ses queues ------------
    do
        local w = W.spawn("return 1")
        w:join()
        local sok, serr = w:send("nope", 0)
        ok("DOC 3 send after worker completion -> (false, 'closed')",
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
        ok("DOC 3 worker timeout numeric string rejected",
            pcall(function() w:recv("0.1") end) == false)
        ok("DOC 3 worker timeout > 24h rejected",
            pcall(function() w:recv(86400.001) end) == false)
        w:join()
    end

    -- Toute durée strictement positive reste une attente bornée, même
    -- sous la milliseconde. L'ancien floor la transformait en timeout=0.
    do
        local w = W.spawn("babet.sleep(200, 'ms'); return true",
            nil, { inbox_capacity = 1 })
        local first_ok = w:send("first", 0)
        local second_ok, second_err = w:send("second", 0.0001)
        ok("DOC 3 tiny positive worker timeout is not non-blocking",
            first_ok == true and second_ok == false
            and second_err == "timeout",
            "got=(" .. tostring(second_ok) .. ","
                .. tostring(second_err) .. ")")
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
        ok("DOC 3 inbox_capacity numeric string rejected",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = "2" })
            end) == false)

        ok("LOT 11 inbox_capacity floating integer rejected",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = 2.0 })
            end) == false)
        ok("LOT 11 outbox_capacity floating integer rejected",
            pcall(function()
                W.spawn("return 1", nil, { outbox_capacity = 2.0 })
            end) == false)
        ok("DOC 3 inbox_capacity > 1000000 rejected",
            pcall(function()
                W.spawn("return 1", nil, { inbox_capacity = 1000001 })
            end) == false)
        ok("DOC 3 outbox_capacity > 1000000 rejected",
            pcall(function()
                W.spawn("return 1", nil, { outbox_capacity = 1000001 })
            end) == false)
    end

    -- ============================================================
    -- Chantier 9-3 : worker.send / worker.recv côté worker
    -- ============================================================

    -- ----- nil est une vraie valeur de message -------------------
    do
        local w = W.spawn([[
            local got, value = worker.recv()
            return { got = got, value_is_nil = value == nil }
        ]])
        local sent, send_err = w:send(nil)
        local joined, result = w:join()
        ok("DOC 3 workers can transfer a nil message",
            sent == true and send_err == nil and joined == true
            and type(result) == "table" and result.got == true
            and result.value_is_nil == true)
    end

    -- ----- close ferme l'inbox, pas l'outbox ----------------------
    do
        local w = W.spawn([[
            worker.send("ready")
            local got, reason = worker.recv()
            worker.send({ got = got, reason = reason })
            return "done"
        ]])
        local ready_ok, ready = w:recv(2)
        local close_result = table.pack(w:close())
        local report_ok, report = w:recv(2)
        local joined, result = w:join()
        ok("DOC 3 job:close returns (true, nil)",
            close_result.n == 2 and close_result[1] == true
            and close_result[2] == nil)
        ok("DOC 3 close keeps outbox drainable",
            ready_ok == true and ready == "ready"
            and report_ok == true and type(report) == "table"
            and report.got == false and report.reason == "closed"
            and joined == true and result == "done")
    end

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

-- =====================================================================
print("")
print("=== secure archives (ZIP and TAR) ===")

do
    local root = sb("archive")
    babet.rmdirAll(root)
    assert(babet.mkdir(root))

    local function write_bytes(path, data)
        local file, open_err = io.open(path, "wb")
        if not file then return nil, open_err end
        local wrote, write_err = file:write(data)
        local closed, close_err = file:close()
        if not wrote then return nil, write_err end
        if closed == nil then return nil, close_err end
        return true
    end

    local function read_bytes(path)
        local file, open_err = io.open(path, "rb")
        if not file then return nil, open_err end
        local data = file:read("a")
        local closed, close_err = file:close()
        if data == nil then return nil, "cannot read file" end
        if closed == nil then return nil, close_err end
        return data
    end

    local function crc32_number(data)
        return assert(tonumber(babet.crc32(data), 16))
    end

    local function zip_mode(type_bits, permissions)
        return ((type_bits | permissions) & 0xffff) << 16
    end

    local function make_zip(path, entries)
        local local_parts = {}
        local central_parts = {}
        local local_offset = 0
        local dos_time = 0
        local dos_date = 0x21 -- 1980-01-01

        for _, entry in ipairs(entries) do
            local name = assert(entry.name)
            local data = entry.data or ""
            local payload = entry.payload or data
            local method = entry.method
            if method == nil then method = entry.payload and 8 or 0 end
            local flags = entry.flags or 0
            local crc = entry.crc32
            if crc == nil then crc = crc32_number(data) end
            local compressed_size = entry.compressed_size or #payload
            local expanded_size = entry.size or #data
            local version_made_by = entry.version_made_by or ((3 << 8) | 20)
            local external = entry.external_attributes
            if external == nil then
                if name:sub(-1) == "/" then
                    external = zip_mode(0x4000, entry.permissions or tonumber("755", 8)) | 0x10
                else
                    external = zip_mode(0x8000, entry.permissions or tonumber("644", 8))
                end
            end

            local local_header = string.pack(
                "<I4I2I2I2I2I2I4I4I4I2I2",
                0x04034b50, 20, flags, method, dos_time, dos_date,
                crc, compressed_size, expanded_size, #name, 0)
            local local_record = local_header .. name .. payload
            local_parts[#local_parts + 1] = local_record

            local central_header = string.pack(
                "<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4",
                0x02014b50, version_made_by, 20, flags, method,
                dos_time, dos_date, crc, compressed_size, expanded_size,
                #name, 0, 0, 0, 0, external, local_offset)
            central_parts[#central_parts + 1] = central_header .. name
            local_offset = local_offset + #local_record
        end

        local local_blob = table.concat(local_parts)
        local central_blob = table.concat(central_parts)
        local eocd = string.pack(
            "<I4I2I2I2I2I4I4I2",
            0x06054b50, 0, 0, #entries, #entries,
            #central_blob, #local_blob, 0)
        return write_bytes(path, local_blob .. central_blob .. eocd)
    end

    local function make_empty_zip64(path)
        local zip64_eocd = string.pack(
            "<I4I8I2I2I4I4I8I8I8I8",
            0x06064b50, 44, 45, 45, 0, 0, 0, 0, 0, 0)
        local locator = string.pack(
            "<I4I4I8I4", 0x07064b50, 0, 0, 1)
        local eocd = string.pack(
            "<I4I2I2I2I2I4I4I2",
            0x06054b50, 0, 0, 0xffff, 0xffff,
            0xffffffff, 0xffffffff, 0)
        return write_bytes(path, zip64_eocd .. locator .. eocd)
    end

    local function tar_text_field(value, width)
        value = value or ""
        assert(#value <= width, "TAR field is too long")
        return value .. string.rep("\0", width - #value)
    end

    local function tar_octal_field(value, width)
        value = value or 0
        local digits = string.format("%0" .. tostring(width - 1) .. "o", value)
        assert(#digits <= width - 1, "TAR octal field is too large")
        return digits .. "\0"
    end

    local function tar_name_fields(name)
        if #name <= 100 then return name, "" end
        for i = #name, 1, -1 do
            if name:sub(i, i) == "/" then
                local prefix = name:sub(1, i - 1)
                local leaf = name:sub(i + 1)
                if #prefix <= 155 and #leaf <= 100 and #leaf > 0 then
                    return leaf, prefix
                end
            end
        end
        error("TAR path does not fit in a ustar header: " .. name)
    end

    local function tar_header(entry)
        local name, prefix = tar_name_fields(assert(entry.name))
        local typeflag = entry.typeflag or "0"
        local data = entry.data or ""
        local size = entry.size
        if size == nil then
            size = (typeflag == "0" or typeflag == "\0" or typeflag == "x"
                or typeflag == "L") and #data or 0
        end

        local header = table.concat({
            tar_text_field(name, 100),
            tar_octal_field(entry.mode or tonumber("644", 8), 8),
            tar_octal_field(entry.uid or 0, 8),
            tar_octal_field(entry.gid or 0, 8),
            tar_octal_field(size, 12),
            tar_octal_field(entry.mtime or 0, 12),
            string.rep(" ", 8),
            typeflag,
            tar_text_field(entry.linkname, 100),
            "ustar\0",
            "00",
            tar_text_field(entry.uname or "root", 32),
            tar_text_field(entry.gname or "root", 32),
            tar_octal_field(entry.devmajor or 0, 8),
            tar_octal_field(entry.devminor or 0, 8),
            tar_text_field(prefix, 155),
            string.rep("\0", 12),
        })
        assert(#header == 512)

        local checksum = 0
        for i = 1, #header do checksum = checksum + header:byte(i) end
        local encoded_checksum = string.format("%06o\0 ", checksum)
        assert(#encoded_checksum == 8)
        header = header:sub(1, 148) .. encoded_checksum .. header:sub(157)
        return header, data, size
    end

    local function pax_record(key, value)
        local body = key .. "=" .. value .. "\n"
        local length = #body + 2
        while true do
            local record = tostring(length) .. " " .. body
            if #record == length then return record end
            length = #record
        end
    end

    local function make_tar(path, entries, opts)
        opts = opts or {}
        local parts = {}

        local function emit(entry)
            local header, data, size = tar_header(entry)
            parts[#parts + 1] = header
            parts[#parts + 1] = data
            local padding = (512 - (size % 512)) % 512
            if padding > 0 then
                parts[#parts + 1] = string.rep("\0", padding)
            end
        end

        for index, source_entry in ipairs(entries) do
            local entry = {}
            for key, value in pairs(source_entry) do entry[key] = value end

            if source_entry.gnu_longname then
                emit({
                    name = "././@LongLink",
                    typeflag = "L",
                    mode = tonumber("644", 8),
                    data = source_entry.name .. "\0",
                })
                entry.name = "gnu-long-name-" .. tostring(index)
                entry.gnu_longname = nil
            elseif source_entry.pax_path then
                emit({
                    name = "PaxHeader/path-" .. tostring(index),
                    typeflag = "x",
                    mode = tonumber("644", 8),
                    data = pax_record("path", source_entry.name),
                })
                entry.name = "pax-path-" .. tostring(index)
                entry.pax_path = nil
            end
            emit(entry)
        end

        if not opts.omit_end_blocks then
            parts[#parts + 1] = string.rep("\0", 1024)
        end
        return write_bytes(path, table.concat(parts))
    end

    local function make_old_gnu_sparse_tar(path)
        local sparse_descriptor = tar_octal_field(1024, 12)
            .. tar_octal_field(4, 12)
        local empty_descriptor = tar_octal_field(0, 12)
            .. tar_octal_field(0, 12)
        local header = table.concat({
            tar_text_field("sparse.bin", 100),
            tar_octal_field(tonumber("644", 8), 8),
            tar_octal_field(0, 8),
            tar_octal_field(0, 8),
            tar_octal_field(4, 12), -- condensed payload size
            tar_octal_field(0, 12),
            string.rep(" ", 8),
            "S", -- old GNU sparse regular file
            tar_text_field("", 100),
            "ustar  \0",
            tar_text_field("root", 32),
            tar_text_field("root", 32),
            tar_octal_field(0, 8),
            tar_octal_field(0, 8),
            tar_octal_field(0, 12), -- atime
            tar_octal_field(0, 12), -- ctime
            tar_octal_field(0, 12), -- legacy offset field
            string.rep("\0", 4),
            "\0",
            sparse_descriptor,
            empty_descriptor,
            empty_descriptor,
            empty_descriptor,
            "\0", -- no extended sparse map block
            tar_octal_field(2048, 12), -- expanded size
            string.rep("\0", 17),
        })
        assert(#header == 512)
        local checksum = 0
        for i = 1, #header do checksum = checksum + header:byte(i) end
        local encoded_checksum = string.format("%06o\0 ", checksum)
        header = header:sub(1, 148) .. encoded_checksum .. header:sub(157)
        return write_bytes(path,
            header .. "DATA" .. string.rep("\0", 508)
            .. string.rep("\0", 1024))
    end

    local function no_archive_temporaries(path)
        local result = babet.exec("find", {
            path, "-name", ".babet-archive-*", "-print",
        }, { timeout = 5 })
        return type(result) == "table" and result.code == 0
            and result.stdout == ""
    end

    local deflated_4096_a =
        "\xED\xC1\x01\x0D\x00\x00\x00\xC2\xA0\x6C\xEF\x5F" ..
        "\xCA\x1E\x0E\x28\x00\x00\x00\xE0\xDD\x00"

    ok("archive submodule registered",
        type(babet.archive) == "table"
        and type(babet.archive.create) == "function"
        and type(babet.archive.list) == "function"
        and type(babet.archive.extract) == "function"
        and type(babet.archive.extractFile) == "function")

    local archive_worker, archive_worker_err = babet.workers.spawn([[
        return type(babet.archive) == "table"
            and type(babet.archive.create) == "function"
            and type(babet.archive.list) == "function"
            and type(babet.archive.extract) == "function"
            and type(babet.archive.extractFile) == "function"
    ]])
    ok_val("archive submodule registered in worker states",
        archive_worker, archive_worker_err)
    if archive_worker then
        local joined, available = archive_worker:join()
        ok("archive functions available in a worker",
            joined == true and available == true,
            "joined=" .. tostring(joined)
            .. " available=" .. tostring(available))
    end

    ;(function()
    -- TAR listing and extraction --------------------------------------
    -- ZIP remains handled by miniz. libarchive handles TAR streams with
    -- either no outer compression or the built-in gzip filter. Other filters
    -- remain disabled until their dedicated lots.
    local ustar_long_name = string.rep("p", 120) .. "/" .. string.rep("n", 80)
    local gnu_long_name = string.rep("g", 130) .. "/"
        .. string.rep("h", 130) .. "/file.txt"
    local pax_long_name = string.rep("x", 140) .. "/"
        .. string.rep("y", 140) .. "/data.bin"
    local valid_tar = root .. "/valid-tar.data"
    assert(make_tar(valid_tar, {
        { name = "dir/", typeflag = "5", mode = tonumber("711", 8) },
        { name = "dir/hello.txt", data = "bonjour\n", mode = tonumber("640", 8) },
        { name = "binary.bin", data = "\0A\0B", mode = tonumber("601", 8) },
        { name = "hello-link", typeflag = "2", linkname = "dir/hello.txt",
          mode = tonumber("777", 8) },
        { name = "hello-hardlink", typeflag = "1", linkname = "dir/hello.txt",
          mode = tonumber("644", 8) },
        { name = "named-pipe", typeflag = "6", mode = tonumber("600", 8) },
        { name = "char-device", typeflag = "3", devmajor = 1, devminor = 3,
          mode = tonumber("600", 8) },
        { name = "block-device", typeflag = "4", devmajor = 8, devminor = 0,
          mode = tonumber("600", 8) },
        { name = ustar_long_name, data = "ustar", mode = tonumber("644", 8) },
        { name = gnu_long_name, data = "gnu", gnu_longname = true,
          mode = tonumber("644", 8) },
        { name = pax_long_name, data = "pax", pax_path = true,
          mode = tonumber("644", 8) },
    }))

    local tar_list, tar_list_err = babet.archive.list(valid_tar)
    ok_val("archive.list detects uncompressed TAR by content",
        tar_list, tar_list_err, function(value)
            return value.format == "tar"
                and value.compression == "none"
                and value.count == 11
                and value.total_size == 23
                and value.archive_size == babet.fileSize(valid_tar)
                and value.zip64 == nil
        end)
    ok("archive.list keeps ZIP-only metadata nil for TAR entries",
        tar_list and tar_list.entries[2]
        and tar_list.entries[2].compressed_size == nil
        and tar_list.entries[2].crc32 == nil
        and tar_list.entries[2].compression_method == nil
        and tar_list.entries[2].encrypted == false
        and tar_list.entries[2].supported == true
        and tar_list.entries[2].sparse == false)
    ok("archive.list reports TAR regular-file metadata",
        tar_list and tar_list.entries[2]
        and tar_list.entries[2].name == "dir/hello.txt"
        and tar_list.entries[2].path == "dir/hello.txt"
        and tar_list.entries[2].type == "file"
        and tar_list.entries[2].size == 8
        and tar_list.entries[2].unix_mode == tonumber("640", 8)
        and tar_list.entries[2].safe_path == true
        and tar_list.entries[2].extractable == true
        and tar_list.entries[2].reason == nil)
    ok("archive.list reports TAR symlink target and refusal",
        tar_list and tar_list.entries[4]
        and tar_list.entries[4].type == "symlink"
        and tar_list.entries[4].link_target == "dir/hello.txt"
        and tar_list.entries[4].extractable == false
        and tar_list.entries[4].reason == "symlink entries are refused")
    ok("archive.list reports TAR hard-link target and refusal",
        tar_list and tar_list.entries[5]
        and tar_list.entries[5].type == "hardlink"
        and tar_list.entries[5].link_target == "dir/hello.txt"
        and tar_list.entries[5].extractable == false
        and tar_list.entries[5].reason == "hard link entries are refused")
    ok("archive.list identifies TAR special filesystem types",
        tar_list and tar_list.entries[6].type == "fifo"
        and tar_list.entries[7].type == "character_device"
        and tar_list.entries[8].type == "block_device"
        and tar_list.entries[6].extractable == false
        and tar_list.entries[7].extractable == false
        and tar_list.entries[8].extractable == false)
    ok("archive.list supports ustar prefix paths",
        tar_list and tar_list.entries[9].name == ustar_long_name
        and tar_list.entries[9].safe_path == true)
    ok("archive.list supports GNU TAR long names",
        tar_list and tar_list.entries[10].name == gnu_long_name
        and tar_list.entries[10].size == 3)
    ok("archive.list supports pax path headers",
        tar_list and tar_list.entries[11].name == pax_long_name
        and tar_list.entries[11].size == 3)

    local safe_tar = root .. "/safe.tar"
    assert(make_tar(safe_tar, {
        { name = "dir/", typeflag = "5", mode = tonumber("2711", 8) },
        { name = "dir/hello.txt", data = "bonjour\n",
          mode = tonumber("4640", 8) },
        { name = "binary.bin", data = "\0A\0B", mode = tonumber("601", 8) },
        { name = "empty.txt", data = "", mode = tonumber("600", 8) },
        { name = "implicit/deep/file.txt", data = "deep",
          mode = tonumber("644", 8) },
    }))
    local safe_tar_list, safe_tar_list_err = babet.archive.list(safe_tar)
    ok_val("archive.list marks safe TAR files and directories extractable",
        safe_tar_list, safe_tar_list_err, function(value)
            return value.format == "tar" and value.count == 5
                and value.entries[1].extractable == true
                and value.entries[2].extractable == true
                and value.entries[1].reason == nil
                and value.entries[2].reason == nil
        end)

    local tar_default_out = root .. "/tar-default"
    local tar_default, tar_default_err = babet.archive.extract(
        safe_tar, tar_default_out)
    ok_val("archive.extract extracts an uncompressed TAR",
        tar_default, tar_default_err, function(value)
            return value.files == 4 and value.directories == 1
                and value.bytes == 16 and value.path == tar_default_out
        end)
    ok("archive.extract TAR preserves text, binary and empty contents",
        read_bytes(tar_default_out .. "/dir/hello.txt") == "bonjour\n"
        and read_bytes(tar_default_out .. "/binary.bin") == "\0A\0B"
        and read_bytes(tar_default_out .. "/empty.txt") == ""
        and read_bytes(tar_default_out .. "/implicit/deep/file.txt") == "deep")
    ok("archive.extract TAR creates implicit parent directories safely",
        babet.isDir(tar_default_out .. "/implicit") == true
        and babet.isDir(tar_default_out .. "/implicit/deep") == true)
    ok("archive.extract TAR uses safe default permissions",
        babet.getMode(tar_default_out .. "/dir") == tonumber("755", 8)
        and babet.getMode(tar_default_out .. "/dir/hello.txt")
            == tonumber("644", 8))
    ok("archive.extract TAR leaves no staging files",
        no_archive_temporaries(tar_default_out))

    local tar_again, tar_again_err = babet.archive.extract(
        safe_tar, tar_default_out)
    ok_fail("archive.extract TAR refuses overwrite by default",
        tar_again, tar_again_err)
    ok("failed TAR overwrite preserves existing contents",
        read_bytes(tar_default_out .. "/dir/hello.txt") == "bonjour\n")

    local tar_preserve_out = root .. "/tar-preserve"
    local tar_preserve, tar_preserve_err = babet.archive.extract(
        safe_tar, tar_preserve_out, { preserve_permissions = true })
    ok_val("archive.extract TAR preserves safe Unix permissions",
        tar_preserve, tar_preserve_err)
    ok("archive.extract TAR strips setuid/setgid bits",
        babet.getMode(tar_preserve_out .. "/dir") == tonumber("711", 8)
        and babet.getMode(tar_preserve_out .. "/dir/hello.txt")
            == tonumber("640", 8)
        and babet.getMode(tar_preserve_out .. "/binary.bin")
            == tonumber("601", 8))

    local tar_replacement = root .. "/tar-replacement.tar"
    assert(make_tar(tar_replacement, {
        { name = "dir/", typeflag = "5" },
        { name = "dir/hello.txt", data = "remplacé\n" },
    }))
    local tar_replaced, tar_replaced_err = babet.archive.extract(
        tar_replacement, tar_default_out, { overwrite = true })
    ok_val("archive.extract TAR overwrite=true publishes atomically",
        tar_replaced, tar_replaced_err, function(value)
            return value.files == 1 and value.directories == 1
                and value.bytes == 10
        end)
    ok("archive.extract TAR overwrite replaces only selected paths",
        read_bytes(tar_default_out .. "/dir/hello.txt") == "remplacé\n"
        and read_bytes(tar_default_out .. "/binary.bin") == "\0A\0B")

    local tar_worker, tar_worker_err = babet.workers.spawn([[
local info, err = babet.archive.list(worker.args.path)
if not info then error(err) end
return { format = info.format, count = info.count, total_size = info.total_size }
]], { path = valid_tar })
    ok("archive.list TAR starts in a worker",
        tar_worker ~= nil and tar_worker_err == nil, tostring(tar_worker_err))
    if tar_worker then
        local joined, value = tar_worker:join()
        ok("archive.list TAR succeeds in a worker",
            joined == true and type(value) == "table"
            and value.format == "tar" and value.count == 11
            and value.total_size == 23,
            inspect(value))
    end

    local worker_extract_out = root .. "/tar-worker-out"
    local tar_extract_worker, tar_extract_worker_err = babet.workers.spawn([[
local result, err = babet.archive.extract(
    worker.args.archive, worker.args.destination)
if not result then error(err) end
return result
]], { archive = safe_tar, destination = worker_extract_out })
    ok("archive.extract TAR starts in a worker",
        tar_extract_worker ~= nil and tar_extract_worker_err == nil,
        tostring(tar_extract_worker_err))
    if tar_extract_worker then
        local joined, value = tar_extract_worker:join()
        ok("archive.extract TAR succeeds in a worker",
            joined == true and type(value) == "table"
            and value.files == 4 and value.directories == 1
            and value.bytes == 16,
            inspect(value))
        ok("archive.extract TAR worker publishes expected data",
            read_bytes(worker_extract_out .. "/dir/hello.txt") == "bonjour\n")
    end

    local concat_first = root .. "/concat-first.tar"
    local concat_second = root .. "/concat-second.tar"
    local concatenated_tar = root .. "/concatenated.tar"
    assert(make_tar(concat_first, {
        { name = "first.txt", data = "first" },
    }))
    assert(make_tar(concat_second, {
        { name = "second.txt", data = "second" },
    }))
    assert(write_bytes(concatenated_tar,
        assert(read_bytes(concat_first)) .. assert(read_bytes(concat_second))))
    local concatenated_list, concatenated_err =
        babet.archive.list(concatenated_tar)
    ok_val("archive.list inspects concatenated TAR archives",
        concatenated_list, concatenated_err, function(value)
            return value.format == "tar" and value.count == 2
                and value.total_size == 11
                and value.entries[1].name == "first.txt"
                and value.entries[2].name == "second.txt"
        end)
    local concatenated_out = root .. "/concatenated-out"
    local concatenated_extract, concatenated_extract_err =
        babet.archive.extract(concatenated_tar, concatenated_out)
    ok_val("archive.extract traverses concatenated TAR archives",
        concatenated_extract, concatenated_extract_err, function(value)
            return value.files == 2 and value.directories == 0
                and value.bytes == 11
        end)
    ok("archive.extract publishes every concatenated TAR member",
        read_bytes(concatenated_out .. "/first.txt") == "first"
        and read_bytes(concatenated_out .. "/second.txt") == "second")

    local sparse_tar = root .. "/sparse.tar"
    assert(make_old_gnu_sparse_tar(sparse_tar))
    local sparse_tar_list, sparse_tar_list_err = babet.archive.list(sparse_tar)
    ok_val("archive.list identifies an old GNU sparse TAR entry",
        sparse_tar_list, sparse_tar_list_err, function(value)
            return value.format == "tar" and value.count == 1
                and value.total_size == 2048
                and value.entries[1].name == "sparse.bin"
                and value.entries[1].size == 2048
                and value.entries[1].sparse == true
                and value.entries[1].extractable == false
                and value.entries[1].reason == "sparse TAR entries are refused"
        end)
    local sparse_tar_out = root .. "/sparse-tar-out"
    local sparse_tar_extract, sparse_tar_extract_err = babet.archive.extract(
        sparse_tar, sparse_tar_out)
    ok_fail("archive.extract refuses sparse TAR files before writing",
        sparse_tar_extract, sparse_tar_extract_err)
    ok("sparse TAR refusal creates no destination",
        babet.fileExists(sparse_tar_out) == false)

    local compressed_tar = root .. "/empty.tar.gz"
    assert(write_bytes(compressed_tar, string.char(
        31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 99, 96, 24, 5, 163,
        96, 20, 140, 84, 0, 0, 46, 175, 181, 239, 0, 4, 0, 0)))
    local compressed_tar_list, compressed_tar_err =
        babet.archive.list(compressed_tar)
    ok_val("archive.list accepts gzip-compressed TAR by content",
        compressed_tar_list, compressed_tar_err, function(value)
            return value.format == "tar" and value.compression == "gzip"
                and value.count == 0 and value.total_size == 0
        end)

    local empty_tar = root .. "/empty.tar"
    assert(write_bytes(empty_tar, string.rep("\0", 1024)))
    local empty_tar_list, empty_tar_err = babet.archive.list(empty_tar)
    ok_val("archive.list accepts a standard empty TAR",
        empty_tar_list, empty_tar_err, function(value)
            return value.format == "tar" and value.count == 0
                and value.total_size == 0 and #value.entries == 0
        end)
    local empty_tar_out = root .. "/empty-tar-out"
    local empty_tar_extract, empty_tar_extract_err = babet.archive.extract(
        empty_tar, empty_tar_out)
    ok_val("archive.extract accepts an empty TAR",
        empty_tar_extract, empty_tar_extract_err, function(value)
            return value.files == 0 and value.directories == 0
                and value.bytes == 0
        end)
    ok("archive.extract empty TAR creates the destination root",
        babet.isDir(empty_tar_out) == true)

    local unsafe_tar = root .. "/unsafe.tar"
    assert(make_tar(unsafe_tar, {
        { name = "../escape", data = "1" },
        { name = "/absolute", data = "2" },
        { name = "a\\b", data = "3" },
        { name = "C:/drive", data = "4" },
        { name = "a//b", data = "5" },
        { name = "a/./b", data = "6" },
    }))
    local unsafe_tar_list, unsafe_tar_err = babet.archive.list(unsafe_tar)
    ok_val("archive.list inspects unsafe TAR paths without extracting",
        unsafe_tar_list, unsafe_tar_err,
        function(value) return value.count == 6 end)
    ok("archive.list applies ZIP path policy to TAR entries",
        unsafe_tar_list
        and unsafe_tar_list.entries[1].safe_path == false
        and unsafe_tar_list.entries[2].safe_path == false
        and unsafe_tar_list.entries[3].safe_path == false
        and unsafe_tar_list.entries[4].safe_path == false
        and unsafe_tar_list.entries[5].safe_path == false
        and unsafe_tar_list.entries[6].safe_path == false)
    local unsafe_tar_out = root .. "/unsafe-tar-out"
    local unsafe_tar_extract, unsafe_tar_extract_err = babet.archive.extract(
        unsafe_tar, unsafe_tar_out)
    ok_fail("archive.extract refuses unsafe TAR paths before writing",
        unsafe_tar_extract, unsafe_tar_extract_err)
    ok("unsafe TAR extraction creates no destination",
        babet.fileExists(unsafe_tar_out) == false)

    local tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_entries = 10 })
    ok_fail("archive.list TAR enforces max_entries",
        tar_limited, tar_limited_err)
    tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_entry_size = 7 })
    ok_fail("archive.list TAR enforces max_entry_size",
        tar_limited, tar_limited_err)
    tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_total_size = 22 })
    ok_fail("archive.list TAR enforces max_total_size",
        tar_limited, tar_limited_err)
    local tar_exact, tar_exact_err = babet.archive.list(valid_tar, {
        max_entries = 11,
        max_entry_size = 8,
        max_total_size = 23,
        max_compression_ratio = 1,
    })
    ok_val("archive.list TAR accepts exact limits",
        tar_exact, tar_exact_err,
        function(value) return value.count == 11 and value.total_size == 23 end)
    local tar_limited_out = root .. "/tar-limited-out"
    local tar_extract_limited, tar_extract_limited_err = babet.archive.extract(
        safe_tar, tar_limited_out, { max_total_size = 15 })
    ok_fail("archive.extract TAR applies anti-bomb limits before writing",
        tar_extract_limited, tar_extract_limited_err)
    ok("archive.extract TAR limit failure creates no destination",
        babet.fileExists(tar_limited_out) == false)

    local linked_tar = root .. "/valid-tar-link"
    local tar_link_created = babet.exec("ln", { "-s", "valid-tar.data", linked_tar })
    ok("TAR archive symlink fixture created",
        type(tar_link_created) == "table" and tar_link_created.code == 0)
    local linked_tar_list, linked_tar_err = babet.archive.list(linked_tar)
    ok_val("archive.list follows a symlink to a regular TAR",
        linked_tar_list, linked_tar_err,
        function(value) return value.format == "tar" and value.count == 11 end)
    local linked_safe_tar = root .. "/safe-tar-link"
    local linked_safe_created = babet.exec(
        "ln", { "-s", "safe.tar", linked_safe_tar })
    ok("safe TAR archive symlink fixture created",
        type(linked_safe_created) == "table" and linked_safe_created.code == 0)
    local linked_safe_out = root .. "/linked-safe-out"
    local linked_safe_extract, linked_safe_extract_err = babet.archive.extract(
        linked_safe_tar, linked_safe_out)
    ok_val("archive.extract follows a symlink to a regular TAR",
        linked_safe_extract, linked_safe_extract_err,
        function(value) return value.files == 4 and value.bytes == 16 end)
    ok("archive.extract symlinked TAR source content",
        read_bytes(linked_safe_out .. "/binary.bin") == "\0A\0B")

    local duplicate_tar = root .. "/duplicate.tar"
    assert(make_tar(duplicate_tar, {
        { name = "same.txt", data = "first" },
        { name = "same.txt", data = "second" },
    }))
    local duplicate_tar_out = root .. "/duplicate-tar-out"
    local duplicate_tar_extract, duplicate_tar_extract_err =
        babet.archive.extract(duplicate_tar, duplicate_tar_out)
    ok_fail("archive.extract refuses duplicate TAR output paths",
        duplicate_tar_extract, duplicate_tar_extract_err)
    ok("duplicate TAR refusal creates no destination",
        babet.fileExists(duplicate_tar_out) == false)

    local conflict_tar = root .. "/conflict.tar"
    assert(make_tar(conflict_tar, {
        { name = "node", data = "file" },
        { name = "node/child.txt", data = "child" },
    }))
    local conflict_tar_out = root .. "/conflict-tar-out"
    local conflict_tar_extract, conflict_tar_extract_err =
        babet.archive.extract(conflict_tar, conflict_tar_out)
    ok_fail("archive.extract refuses TAR file/directory conflicts",
        conflict_tar_extract, conflict_tar_extract_err)
    ok("TAR path-conflict refusal creates no destination",
        babet.fileExists(conflict_tar_out) == false)

    local tar_parent_target = root .. "/tar-parent-target"
    assert(babet.mkdir(tar_parent_target))
    local tar_parent_link = root .. "/tar-parent-link"
    local tar_parent_linked = babet.exec(
        "ln", { "-s", "tar-parent-target", tar_parent_link })
    ok("TAR destination-parent symlink fixture created",
        type(tar_parent_linked) == "table" and tar_parent_linked.code == 0)
    local tar_parent_attack, tar_parent_attack_err = babet.archive.extract(
        safe_tar, tar_parent_link .. "/out")
    ok_fail("archive.extract TAR refuses a symlinked destination parent",
        tar_parent_attack, tar_parent_attack_err)
    ok("TAR destination-parent refusal writes nothing through the symlink",
        babet.fileExists(tar_parent_target .. "/out") == false)

    local nonregular_payload_tar = root .. "/nonregular-payload.tar"
    assert(make_tar(nonregular_payload_tar, {
        { name = "directory/", typeflag = "5", size = 1, data = "x" },
    }))
    local nonregular_payload_list, nonregular_payload_err =
        babet.archive.list(nonregular_payload_tar)
    ok_fail("archive.list rejects data attached to a non-regular TAR entry",
        nonregular_payload_list, nonregular_payload_err)

    local damaged_tar = root .. "/damaged.tar"
    local valid_tar_bytes = assert(read_bytes(valid_tar))
    assert(write_bytes(damaged_tar, "X" .. valid_tar_bytes:sub(2)))
    local damaged_tar_list, damaged_tar_err = babet.archive.list(damaged_tar)
    ok_fail("archive.list rejects a TAR with an invalid header checksum",
        damaged_tar_list, damaged_tar_err)

    local trailing_tar = root .. "/trailing-garbage.tar"
    assert(write_bytes(trailing_tar, valid_tar_bytes .. "NOT-A-TAR"))
    local trailing_tar_list, trailing_tar_err = babet.archive.list(trailing_tar)
    ok_fail("archive.list rejects non-TAR trailing data",
        trailing_tar_list, trailing_tar_err)

    local truncated_tar = root .. "/truncated.tar"
    assert(make_tar(truncated_tar, {
        { name = "truncated.bin", data = "short", size = 1024 },
    }, { omit_end_blocks = true }))
    local truncated_tar_list, truncated_tar_err = babet.archive.list(truncated_tar)
    ok_fail("archive.list detects truncated TAR entry data",
        truncated_tar_list, truncated_tar_err)

    local tar_extract_out = root .. "/tar-special-out"
    local tar_extract, tar_extract_err = babet.archive.extract(
        valid_tar, tar_extract_out)
    ok_fail("archive.extract TAR refuses links and special filesystem types",
        tar_extract, tar_extract_err)
    ok("refused special TAR extraction creates no destination",
        babet.fileExists(tar_extract_out) == false)

    local compressed_tar_out = root .. "/compressed-tar-out"
    local compressed_tar_extract, compressed_tar_extract_err =
        babet.archive.extract(compressed_tar, compressed_tar_out)
    ok_val("archive.extract accepts an empty gzip-compressed TAR",
        compressed_tar_extract, compressed_tar_extract_err,
        function(value)
            return value.files == 0 and value.directories == 0
                and value.bytes == 0
        end)
    ok("empty gzip-compressed TAR creates the destination root",
        babet.isDir(compressed_tar_out) == true)

    local truncated_tar_out = root .. "/truncated-tar-out"
    local truncated_tar_extract, truncated_tar_extract_err =
        babet.archive.extract(truncated_tar, truncated_tar_out)
    ok_fail("archive.extract rejects truncated TAR data before publication",
        truncated_tar_extract, truncated_tar_extract_err)
    ok("truncated TAR extraction creates no destination",
        babet.fileExists(truncated_tar_out) == false)

    local tar_single_path = root .. "/tar-single.txt"
    local tar_single, tar_single_err = babet.archive.extractFile(
        valid_tar, "dir/hello.txt", tar_single_path)
    ok_val("archive.extractFile extracts one TAR entry from a mixed archive",
        tar_single, tar_single_err, function(value)
            return value.bytes == 8 and value.path == tar_single_path
                and value.entry == "dir/hello.txt"
        end)
    ok("archive.extractFile TAR content is binary-safe and independently named",
        read_bytes(tar_single_path) == "bonjour\n"
        and babet.fileExists(root .. "/dir/hello.txt") == false)
    ok("archive.extractFile TAR uses safe default permissions",
        babet.getMode(tar_single_path) == tonumber("644", 8))
    ok("archive.extractFile TAR leaves no staging files",
        no_archive_temporaries(root))

    assert(write_bytes(tar_single_path, "existing"))
    local tar_single_again, tar_single_again_err = babet.archive.extractFile(
        safe_tar, "dir/hello.txt", tar_single_path)
    ok_fail("archive.extractFile TAR refuses overwrite by default",
        tar_single_again, tar_single_again_err)
    ok("failed TAR extractFile preserves the existing destination",
        read_bytes(tar_single_path) == "existing")
    local tar_single_overwrite, tar_single_overwrite_err =
        babet.archive.extractFile(safe_tar, "dir/hello.txt", tar_single_path, {
            overwrite = true,
        })
    ok_val("archive.extractFile TAR overwrite=true",
        tar_single_overwrite, tar_single_overwrite_err,
        function(value) return value.bytes == 8 end)
    ok("archive.extractFile TAR overwrite publishes atomically",
        read_bytes(tar_single_path) == "bonjour\n")

    local tar_single_mode_path = root .. "/tar-single-mode.txt"
    local tar_single_mode, tar_single_mode_err = babet.archive.extractFile(
        safe_tar, "dir/hello.txt", tar_single_mode_path, {
            preserve_permissions = true,
        })
    ok_val("archive.extractFile TAR preserve_permissions",
        tar_single_mode, tar_single_mode_err)
    ok("archive.extractFile TAR preserves only ordinary permission bits",
        babet.getMode(tar_single_mode_path) == tonumber("640", 8))

    local tar_binary_path = root .. "/tar-single-binary.bin"
    local tar_binary, tar_binary_err = babet.archive.extractFile(
        safe_tar, "binary.bin", tar_binary_path)
    ok_val("archive.extractFile TAR extracts binary data",
        tar_binary, tar_binary_err,
        function(value) return value.bytes == 4 end)
    ok("archive.extractFile TAR preserves embedded NUL bytes",
        read_bytes(tar_binary_path) == "\0A\0B")

    local tar_empty_path = root .. "/tar-single-empty.txt"
    local tar_empty_file, tar_empty_file_err = babet.archive.extractFile(
        safe_tar, "empty.txt", tar_empty_path)
    ok_val("archive.extractFile TAR extracts an empty regular file",
        tar_empty_file, tar_empty_file_err,
        function(value) return value.bytes == 0 end)
    ok("archive.extractFile TAR publishes the empty file",
        read_bytes(tar_empty_path) == "")

    local tar_long_path = root .. "/tar-single-long.txt"
    local tar_long, tar_long_err = babet.archive.extractFile(
        valid_tar, pax_long_name, tar_long_path)
    ok_val("archive.extractFile TAR selects the decoded pax pathname",
        tar_long, tar_long_err,
        function(value) return value.entry == pax_long_name and value.bytes == 3 end)
    ok("archive.extractFile TAR pax content",
        read_bytes(tar_long_path) == "pax")

    local tar_missing_path = root .. "/tar-single-missing.txt"
    local tar_missing, tar_missing_err = babet.archive.extractFile(
        safe_tar, "missing.txt", tar_missing_path)
    ok_fail("archive.extractFile TAR reports a missing entry",
        tar_missing, tar_missing_err)
    ok("missing TAR extractFile creates no output",
        babet.fileExists(tar_missing_path) == false)

    local tar_directory_path = root .. "/tar-single-directory"
    local tar_directory, tar_directory_err = babet.archive.extractFile(
        safe_tar, "dir/", tar_directory_path)
    ok_fail("archive.extractFile TAR refuses a directory entry",
        tar_directory, tar_directory_err)
    ok("directory TAR extractFile creates no output",
        babet.fileExists(tar_directory_path) == false)

    local tar_symlink_path = root .. "/tar-single-symlink"
    local tar_symlink, tar_symlink_err = babet.archive.extractFile(
        valid_tar, "hello-link", tar_symlink_path)
    ok_fail("archive.extractFile TAR refuses a symlink entry",
        tar_symlink, tar_symlink_err)
    ok("symlink TAR extractFile creates no output",
        babet.fileExists(tar_symlink_path) == false)

    local tar_duplicate_path = root .. "/tar-single-duplicate.txt"
    local tar_duplicate, tar_duplicate_err = babet.archive.extractFile(
        duplicate_tar, "same.txt", tar_duplicate_path)
    ok_fail("archive.extractFile TAR refuses an ambiguous duplicate name",
        tar_duplicate, tar_duplicate_err)
    ok("ambiguous TAR extractFile creates no output",
        babet.fileExists(tar_duplicate_path) == false)

    local tar_unsafe_path = root .. "/tar-single-unsafe.txt"
    local tar_unsafe, tar_unsafe_err = babet.archive.extractFile(
        unsafe_tar, "../escape", tar_unsafe_path)
    ok_fail("archive.extractFile TAR refuses a selected unsafe path",
        tar_unsafe, tar_unsafe_err)
    ok("unsafe TAR extractFile creates no output",
        babet.fileExists(tar_unsafe_path) == false)

    local mixed_path_tar = root .. "/mixed-path.tar"
    assert(make_tar(mixed_path_tar, {
        { name = "../unsafe.txt", data = "unsafe" },
        { name = "safe.txt", data = "safe" },
    }))
    local mixed_safe_path = root .. "/tar-single-safe.txt"
    local mixed_safe, mixed_safe_err = babet.archive.extractFile(
        mixed_path_tar, "safe.txt", mixed_safe_path)
    ok_val("archive.extractFile TAR may select a safe entry from a mixed archive",
        mixed_safe, mixed_safe_err,
        function(value) return value.bytes == 4 end)
    ok("archive.extractFile TAR mixed-archive content",
        read_bytes(mixed_safe_path) == "safe"
        and babet.fileExists(root .. "/unsafe.txt") == false)

    local tar_limited_single_path = root .. "/tar-single-limited.txt"
    local tar_limited_single, tar_limited_single_err = babet.archive.extractFile(
        safe_tar, "empty.txt", tar_limited_single_path, {
            max_total_size = 15,
        })
    ok_fail("archive.extractFile TAR applies limits to the whole archive",
        tar_limited_single, tar_limited_single_err)
    ok("limited TAR extractFile creates no output",
        babet.fileExists(tar_limited_single_path) == false)

    local tar_sparse_path = root .. "/tar-single-sparse.bin"
    local tar_sparse, tar_sparse_err = babet.archive.extractFile(
        sparse_tar, "sparse.bin", tar_sparse_path)
    ok_fail("archive.extractFile TAR refuses a selected sparse file",
        tar_sparse, tar_sparse_err)
    ok("selected sparse TAR extractFile creates no output",
        babet.fileExists(tar_sparse_path) == false)

    local sparse_then_safe_tar = root .. "/sparse-then-safe.tar"
    assert(write_bytes(sparse_then_safe_tar,
        assert(read_bytes(sparse_tar)) .. assert(read_bytes(concat_second))))
    local after_sparse_path = root .. "/tar-single-after-sparse.txt"
    local after_sparse, after_sparse_err = babet.archive.extractFile(
        sparse_then_safe_tar, "second.txt", after_sparse_path)
    ok_val("archive.extractFile TAR skips an unrelated sparse member safely",
        after_sparse, after_sparse_err,
        function(value) return value.bytes == 6 end)
    ok("archive.extractFile TAR reads a selected concatenated member",
        read_bytes(after_sparse_path) == "second")

    local tar_compressed_single_path = root .. "/tar-single-compressed"
    local tar_compressed_single, tar_compressed_single_err =
        babet.archive.extractFile(
            compressed_tar, "anything", tar_compressed_single_path)
    ok_fail("archive.extractFile reports a missing entry in an empty gzip TAR",
        tar_compressed_single, tar_compressed_single_err)
    ok("missing gzip TAR extractFile creates no output",
        babet.fileExists(tar_compressed_single_path) == false)

    local tar_truncated_single_path = root .. "/tar-single-truncated"
    local tar_truncated_single, tar_truncated_single_err =
        babet.archive.extractFile(
            truncated_tar, "truncated.bin", tar_truncated_single_path)
    ok_fail("archive.extractFile rejects truncated TAR before publication",
        tar_truncated_single, tar_truncated_single_err)
    ok("truncated TAR extractFile creates no output",
        babet.fileExists(tar_truncated_single_path) == false)

    local tar_link_single_path = root .. "/tar-single-linked-source.txt"
    local tar_link_single, tar_link_single_err = babet.archive.extractFile(
        linked_safe_tar, "dir/hello.txt", tar_link_single_path)
    ok_val("archive.extractFile follows a symlink to a regular TAR",
        tar_link_single, tar_link_single_err,
        function(value) return value.bytes == 8 end)
    ok("archive.extractFile linked TAR source content",
        read_bytes(tar_link_single_path) == "bonjour\n")

    local tar_single_target = root .. "/tar-single-target.txt"
    assert(write_bytes(tar_single_target, "outside"))
    local tar_single_link = root .. "/tar-single-link.txt"
    local tar_single_linked = babet.exec(
        "ln", { "-s", "tar-single-target.txt", tar_single_link })
    ok("TAR extractFile destination symlink fixture created",
        type(tar_single_linked) == "table" and tar_single_linked.code == 0)
    local tar_link_attack, tar_link_attack_err = babet.archive.extractFile(
        safe_tar, "dir/hello.txt", tar_single_link, { overwrite = true })
    ok_fail("archive.extractFile TAR refuses a symlink destination",
        tar_link_attack, tar_link_attack_err)
    ok("TAR extractFile symlink target remains unchanged",
        read_bytes(tar_single_target) == "outside")

    local tar_extract_file_worker_path = root .. "/tar-single-worker.txt"
    local tar_extract_file_worker, tar_extract_file_worker_err =
        babet.workers.spawn([[
local result, err = babet.archive.extractFile(
    worker.args.archive, worker.args.entry, worker.args.destination)
if not result then error(err) end
return result
]], {
            archive = safe_tar,
            entry = "dir/hello.txt",
            destination = tar_extract_file_worker_path,
        })
    ok("archive.extractFile TAR starts in a worker",
        tar_extract_file_worker ~= nil and tar_extract_file_worker_err == nil,
        tostring(tar_extract_file_worker_err))
    if tar_extract_file_worker then
        local joined, value = tar_extract_file_worker:join()
        ok("archive.extractFile TAR succeeds in a worker",
            joined == true and type(value) == "table"
            and value.bytes == 8 and value.entry == "dir/hello.txt",
            inspect(value))
        ok("archive.extractFile TAR worker publishes expected data",
            read_bytes(tar_extract_file_worker_path) == "bonjour\n")
    end
    end)()

    local empty_zip = root .. "/empty.zip"
    assert(make_zip(empty_zip, {}))
    local empty_list, empty_list_err = babet.archive.list(empty_zip)
    ok_val("archive.list(empty ZIP)", empty_list, empty_list_err,
        function(value)
            return value.format == "zip" and value.compression == "none"
                and value.count == 0 and value.total_size == 0
                and #value.entries == 0 and value.zip64 == false
        end)
    local empty_out = root .. "/empty-out"
    local empty_extract, empty_extract_err = babet.archive.extract(
        empty_zip, empty_out)
    ok_val("archive.extract(empty ZIP)", empty_extract, empty_extract_err,
        function(value)
            return value.files == 0 and value.directories == 0
                and value.bytes == 0
        end)
    ok("archive.extract(empty ZIP) creates destination root",
        babet.isDir(empty_out) == true)

    local empty_zip64 = root .. "/empty-zip64.zip"
    assert(make_empty_zip64(empty_zip64))
    local zip64_list, zip64_list_err = babet.archive.list(empty_zip64)
    ok_val("archive.list(empty ZIP64)", zip64_list, zip64_list_err,
        function(value)
            return value.count == 0 and value.total_size == 0
                and value.zip64 == true
        end)

    local valid_zip = root .. "/valid.zip"
    local valid_entries = {
        { name = "dir/", permissions = tonumber("711", 8) },
        { name = "dir/hello.txt", data = "bonjour\n", permissions = tonumber("640", 8) },
        { name = "binary.bin", data = "\0A\0B", permissions = tonumber("701", 8) },
        { name = "empty.txt", data = "", permissions = tonumber("600", 8) },
        {
            name = "compressed.txt",
            data = string.rep("A", 4096),
            payload = deflated_4096_a,
            method = 8,
            permissions = tonumber("600", 8),
        },
    }
    local made, make_err = make_zip(valid_zip, valid_entries)
    ok("archive fixture created", made == true, make_err)

    local listed, list_err = babet.archive.list(valid_zip)
    ok_val("archive.list(valid)", listed, list_err, function(value)
        return type(value) == "table"
            and type(value.entries) == "table"
            and value.format == "zip"
            and value.compression == "none"
            and value.count == 5
            and value.total_size == 4108
            and value.archive_size == babet.fileSize(valid_zip)
            and value.zip64 == false
    end)
    ok("archive.list directory metadata",
        listed and listed.entries[1]
        and listed.entries[1].name == "dir/"
        and listed.entries[1].path == "dir"
        and listed.entries[1].type == "directory"
        and listed.entries[1].size == 0
        and listed.entries[1].safe_path == true
        and listed.entries[1].extractable == true
        and listed.entries[1].reason == nil
        and listed.entries[1].unix_mode == tonumber("711", 8))
    ok("archive.list regular-file metadata",
        listed and listed.entries[2]
        and listed.entries[2].name == "dir/hello.txt"
        and listed.entries[2].type == "file"
        and listed.entries[2].size == 8
        and listed.entries[2].compressed_size == 8
        and listed.entries[2].crc32 == crc32_number("bonjour\n")
        and listed.entries[2].compression_method == 0
        and listed.entries[2].encrypted == false
        and listed.entries[2].supported == true
        and listed.entries[2].unix_mode == tonumber("640", 8))
    ok("archive.list DEFLATE metadata",
        listed and listed.entries[5]
        and listed.entries[5].size == 4096
        and listed.entries[5].compressed_size == #deflated_4096_a
        and listed.entries[5].compression_method == 8
        and listed.entries[5].extractable == true)

    -- Les noms temporaires internes ne doivent jamais entrer en conflit avec
    -- un nom de sortie contrôlé par l'archive. Le compteur vaut encore zéro :
    -- les extractions précédentes ne contenaient aucun fichier.
    local proc_stat = read_bytes("/proc/self/stat")
    local self_pid = proc_stat and proc_stat:match("^(%d+)")
    ok("archive temporary collision fixture can identify current PID",
        self_pid ~= nil)
    if self_pid then
        local temp_prefix = ".babet-archive-" .. self_pid .. "-"
        local collision_zip = root .. "/temporary-name-collision.zip"
        assert(make_zip(collision_zip, {
            { name = temp_prefix .. "1", data = "first" },
            { name = temp_prefix .. "0", data = "second" },
        }))
        local collision_out = root .. "/temporary-name-collision-out"
        local collision_result, collision_err = babet.archive.extract(
            collision_zip, collision_out)
        ok_val("archive staging names never collide with archive outputs",
            collision_result, collision_err,
            function(value) return value.files == 2 end)
        local collision_files = babet.listFiles(collision_out) or {}
        local collision_seen = {}
        for _, name in ipairs(collision_files) do collision_seen[name] = true end
        ok("archive output names resembling staging files are preserved",
            read_bytes(collision_out .. "/" .. temp_prefix .. "1") == "first"
            and read_bytes(collision_out .. "/" .. temp_prefix .. "0") == "second"
            and #collision_files == 2
            and collision_seen[temp_prefix .. "1"] == true
            and collision_seen[temp_prefix .. "0"] == true)
    end

    local extract_dir = root .. "/extract-default"
    local extracted, extract_err = babet.archive.extract(valid_zip, extract_dir)
    ok_val("archive.extract(valid)", extracted, extract_err, function(value)
        return value.files == 4 and value.directories == 1
            and value.bytes == 4108 and value.path == extract_dir
    end)
    ok("archive.extract text content",
        read_bytes(extract_dir .. "/dir/hello.txt") == "bonjour\n")
    ok("archive.extract binary and NUL content",
        read_bytes(extract_dir .. "/binary.bin") == "\0A\0B")
    ok("archive.extract empty file",
        read_bytes(extract_dir .. "/empty.txt") == "")
    ok("archive.extract DEFLATE content",
        read_bytes(extract_dir .. "/compressed.txt") == string.rep("A", 4096))
    local default_file_mode = babet.getMode(extract_dir .. "/binary.bin")
    local default_dir_mode = babet.getMode(extract_dir .. "/dir")
    ok("archive.extract uses safe default file mode",
        default_file_mode == tonumber("644", 8), tostring(default_file_mode))
    ok("archive.extract uses safe default directory mode",
        default_dir_mode == tonumber("755", 8), tostring(default_dir_mode))
    ok("archive.extract leaves no staging files",
        no_archive_temporaries(extract_dir))

    local refused, refused_err = babet.archive.extract(valid_zip, extract_dir)
    ok_fail("archive.extract refuses overwrite by default", refused, refused_err)
    ok("archive.extract failed overwrite preserves content",
        read_bytes(extract_dir .. "/dir/hello.txt") == "bonjour\n")

    local replacement_zip = root .. "/replacement.zip"
    assert(make_zip(replacement_zip, {
        { name = "dir/" },
        { name = "dir/hello.txt", data = "remplacé\n" },
    }))
    local replaced, replaced_err = babet.archive.extract(
        replacement_zip, extract_dir, { overwrite = true })
    ok_val("archive.extract overwrite=true", replaced, replaced_err,
        function(value) return value.files == 1 and value.directories == 1 end)
    ok("archive.extract overwrite replaces atomically",
        read_bytes(extract_dir .. "/dir/hello.txt") == "remplacé\n")

    local preserve_dir = root .. "/extract-preserve"
    local preserved, preserved_err = babet.archive.extract(
        valid_zip, preserve_dir, { preserve_permissions = true })
    ok_val("archive.extract preserve_permissions", preserved, preserved_err)
    local preserved_file_mode = babet.getMode(preserve_dir .. "/binary.bin")
    local preserved_dir_mode = babet.getMode(preserve_dir .. "/dir")
    ok("archive.extract preserves regular permissions",
        preserved_file_mode == tonumber("701", 8), tostring(preserved_file_mode))
    ok("archive.extract preserves directory permissions",
        preserved_dir_mode == tonumber("711", 8), tostring(preserved_dir_mode))

    local special_zip = root .. "/special-modes.zip"
    assert(make_zip(special_zip, {
        { name = "special/", permissions = tonumber("2777", 8) },
        { name = "special/tool", data = "x", permissions = tonumber("4755", 8) },
    }))
    local special_dir = root .. "/special-modes"
    local special_result, special_err = babet.archive.extract(
        special_zip, special_dir, { preserve_permissions = true })
    ok_val("archive.extract strips special permission bits", special_result, special_err)
    ok("archive directory setgid bit stripped",
        babet.getMode(special_dir .. "/special") == tonumber("777", 8))
    ok("archive file setuid bit stripped",
        babet.getMode(special_dir .. "/special/tool") == tonumber("755", 8))

    local existing_dir = root .. "/existing-dir"
    assert(babet.mkdir(existing_dir))
    assert(babet.mkdir(existing_dir .. "/kept"))
    assert(babet.setMode(existing_dir .. "/kept", "700"))
    local existing_zip = root .. "/existing-dir.zip"
    assert(make_zip(existing_zip, {
        { name = "kept/", permissions = tonumber("777", 8) },
        { name = "kept/file.txt", data = "ok" },
    }))
    local existing_result, existing_err = babet.archive.extract(
        existing_zip, existing_dir, { preserve_permissions = true })
    ok_val("archive.extract accepts an existing safe directory", existing_result, existing_err)
    ok("archive.extract does not chmod pre-existing directories",
        babet.getMode(existing_dir .. "/kept") == tonumber("700", 8))

    local single_parent = root .. "/single/nested"
    local single_path = single_parent .. "/renamed.dat"
    local single, single_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_path)
    ok_val("archive.extractFile extracts and renames one entry", single, single_err,
        function(value)
            return value.bytes == 4 and value.path == single_path
                and value.entry == "binary.bin"
        end)
    ok("archive.extractFile content is binary-safe",
        read_bytes(single_path) == "\0A\0B")
    ok("archive.extractFile uses basename, not archive path",
        babet.fileExists(single_parent .. "/binary.bin") == false)
    local single_again, single_again_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_path)
    ok_fail("archive.extractFile refuses overwrite by default",
        single_again, single_again_err)
    local single_overwrite, single_overwrite_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_path, { overwrite = true })
    ok_val("archive.extractFile overwrite=true",
        single_overwrite, single_overwrite_err)

    local single_mode_path = root .. "/single-mode.bin"
    local single_mode, single_mode_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_mode_path,
        { preserve_permissions = true })
    ok_val("archive.extractFile preserve_permissions",
        single_mode, single_mode_err)
    ok("archive.extractFile preserves regular permissions",
        babet.getMode(single_mode_path) == tonumber("701", 8),
        tostring(babet.getMode(single_mode_path)))

    local missing, missing_err = babet.archive.extractFile(
        valid_zip, "missing.txt", root .. "/missing.txt")
    ok_fail("archive.extractFile missing entry", missing, missing_err)
    local directory_file, directory_file_err = babet.archive.extractFile(
        valid_zip, "dir/", root .. "/not-a-file")
    ok_fail("archive.extractFile refuses a directory entry",
        directory_file, directory_file_err)

    local duplicate_zip = root .. "/duplicate.zip"
    assert(make_zip(duplicate_zip, {
        { name = "same.txt", data = "one" },
        { name = "same.txt", data = "two" },
    }))
    local duplicate_list, duplicate_list_err = babet.archive.list(duplicate_zip)
    ok_val("archive.list reports duplicate names", duplicate_list, duplicate_list_err,
        function(value) return value.count == 2 end)
    local duplicate_extract, duplicate_extract_err = babet.archive.extract(
        duplicate_zip, root .. "/duplicate-out")
    ok_fail("archive.extract refuses duplicate output paths",
        duplicate_extract, duplicate_extract_err)
    local duplicate_one, duplicate_one_err = babet.archive.extractFile(
        duplicate_zip, "same.txt", root .. "/ambiguous.txt")
    ok_fail("archive.extractFile refuses an ambiguous duplicate name",
        duplicate_one, duplicate_one_err)

    local conflict_zip = root .. "/conflict.zip"
    assert(make_zip(conflict_zip, {
        { name = "node", data = "file" },
        { name = "node/child.txt", data = "child" },
    }))
    local conflict, conflict_err = babet.archive.extract(
        conflict_zip, root .. "/conflict-out")
    ok_fail("archive.extract refuses file/directory path conflicts",
        conflict, conflict_err)

    local unsafe_zip = root .. "/unsafe.zip"
    local long_name = string.rep("a", 4097)
    assert(make_zip(unsafe_zip, {
        { name = "../escape.txt", data = "x" },
        { name = "/absolute.txt", data = "x" },
        { name = "dir\\windows.txt", data = "x" },
        { name = "C:/drive.txt", data = "x" },
        { name = "D:drive-relative.txt", data = "x" },
        { name = "a//empty.txt", data = "x" },
        { name = "a/./dot.txt", data = "x" },
        { name = "a/../parent.txt", data = "x" },
        { name = long_name, data = "x" },
        { name = "safe.txt", data = "safe" },
    }))
    local unsafe_list, unsafe_list_err = babet.archive.list(unsafe_zip)
    ok_val("archive.list inspects unsafe paths without extracting",
        unsafe_list, unsafe_list_err, function(value) return value.count == 10 end)
    ok("archive.list marks traversal unsafe",
        unsafe_list and unsafe_list.entries[1].safe_path == false
        and unsafe_list.entries[1].extractable == false
        and type(unsafe_list.entries[1].reason) == "string")
    ok("archive.list marks absolute paths unsafe",
        unsafe_list and unsafe_list.entries[2].safe_path == false)
    ok("archive.list marks backslashes unsafe",
        unsafe_list and unsafe_list.entries[3].safe_path == false)
    ok("archive.list marks drive prefixes unsafe",
        unsafe_list and unsafe_list.entries[4].safe_path == false
        and unsafe_list.entries[5].safe_path == false)
    ok("archive.list marks empty components unsafe",
        unsafe_list and unsafe_list.entries[6].safe_path == false)
    ok("archive.list marks dot components unsafe",
        unsafe_list and unsafe_list.entries[7].safe_path == false
        and unsafe_list.entries[8].safe_path == false)
    ok("archive.list marks oversized names unsafe",
        unsafe_list and unsafe_list.entries[9].safe_path == false)
    local unsafe_out = root .. "/unsafe-out"
    local unsafe_extract, unsafe_extract_err = babet.archive.extract(
        unsafe_zip, unsafe_out)
    ok_fail("archive.extract refuses unsafe archive paths",
        unsafe_extract, unsafe_extract_err)
    ok("archive path validation happens before destination creation",
        babet.fileExists(unsafe_out) == false)
    local selected_unsafe, selected_unsafe_err = babet.archive.extractFile(
        unsafe_zip, "../escape.txt", root .. "/selected-unsafe.txt")
    ok_fail("archive.extractFile refuses a selected unsafe entry",
        selected_unsafe, selected_unsafe_err)
    local selected_safe, selected_safe_err = babet.archive.extractFile(
        unsafe_zip, "safe.txt", root .. "/selected-safe.txt")
    ok_val("archive.extractFile may select a safe entry from a mixed archive",
        selected_safe, selected_safe_err)
    ok("selected safe entry content", read_bytes(root .. "/selected-safe.txt") == "safe")

    local nul_name_zip = root .. "/nul-name.zip"
    assert(make_zip(nul_name_zip, {
        { name = "visible.txt\0hidden.txt", data = "x" },
    }))
    local nul_name, nul_name_err = babet.archive.list(nul_name_zip)
    ok_fail("archive.list refuses an embedded NUL in a ZIP entry name",
        nul_name, nul_name_err)
    ok("archive embedded-NUL diagnostic is explicit",
        type(nul_name_err) == "string"
        and nul_name_err:find("embedded NUL", 1, true) ~= nil,
        tostring(nul_name_err))

    local symlink_zip = root .. "/symlink-entry.zip"
    assert(make_zip(symlink_zip, {
        {
            name = "link",
            data = "target.txt",
            external_attributes = zip_mode(0xA000, tonumber("777", 8)),
        },
    }))
    local symlink_list, symlink_list_err = babet.archive.list(symlink_zip)
    ok_val("archive.list identifies a ZIP symlink", symlink_list, symlink_list_err)
    ok("ZIP symlink is never extractable",
        symlink_list and symlink_list.entries[1].type == "symlink"
        and symlink_list.entries[1].extractable == false)
    local symlink_entry, symlink_entry_err = babet.archive.extract(
        symlink_zip, root .. "/symlink-entry-out")
    ok_fail("archive.extract refuses ZIP symlink entries",
        symlink_entry, symlink_entry_err)

    local symlink_file, symlink_file_err = babet.archive.extractFile(
        symlink_zip, "link", root .. "/symlink-as-file")
    ok_fail("archive.extractFile refuses a ZIP symlink entry",
        symlink_file, symlink_file_err)

    local mac_symlink_zip = root .. "/mac-symlink-entry.zip"
    assert(make_zip(mac_symlink_zip, {
        {
            name = "mac-link",
            data = "target.txt",
            version_made_by = ((19 << 8) | 20),
            external_attributes = zip_mode(0xA000, tonumber("777", 8)),
        },
    }))
    local mac_symlink_list, mac_symlink_list_err =
        babet.archive.list(mac_symlink_zip)
    ok_val("archive.list identifies a macOS ZIP symlink",
        mac_symlink_list, mac_symlink_list_err)
    ok("macOS ZIP symlink is never extractable",
        mac_symlink_list
        and mac_symlink_list.entries[1].type == "symlink"
        and mac_symlink_list.entries[1].extractable == false)

    local special_type_zip = root .. "/special-type.zip"
    assert(make_zip(special_type_zip, {
        {
            name = "fifo",
            data = "",
            external_attributes = zip_mode(0x1000, tonumber("644", 8)),
        },
    }))
    local special_type_list, special_type_list_err = babet.archive.list(special_type_zip)
    ok_val("archive.list identifies unsupported filesystem types",
        special_type_list, special_type_list_err)
    ok("unsupported filesystem type is not extractable",
        special_type_list and special_type_list.entries[1].type == "unsupported"
        and special_type_list.entries[1].extractable == false)
    local special_type, special_type_err = babet.archive.extract(
        special_type_zip, root .. "/special-type-out")
    ok_fail("archive.extract refuses unsupported filesystem types",
        special_type, special_type_err)

    local encrypted_zip = root .. "/encrypted.zip"
    assert(make_zip(encrypted_zip, {
        { name = "secret.txt", data = "secret", flags = 1 },
    }))
    local encrypted_list, encrypted_list_err = babet.archive.list(encrypted_zip)
    ok_val("archive.list reports encryption", encrypted_list, encrypted_list_err)
    ok("encrypted entry is not extractable",
        encrypted_list and encrypted_list.entries[1].encrypted == true
        and encrypted_list.entries[1].extractable == false)
    local encrypted, encrypted_err = babet.archive.extract(
        encrypted_zip, root .. "/encrypted-out")
    ok_fail("archive.extract refuses encrypted entries", encrypted, encrypted_err)

    local unsupported_zip = root .. "/unsupported-method.zip"
    assert(make_zip(unsupported_zip, {
        { name = "method.bin", data = "abc", method = 99 },
    }))
    local unsupported_list, unsupported_list_err = babet.archive.list(unsupported_zip)
    ok_val("archive.list reports unsupported compression",
        unsupported_list, unsupported_list_err)
    ok("unsupported compression is not extractable",
        unsupported_list and unsupported_list.entries[1].supported == false
        and unsupported_list.entries[1].extractable == false)
    local unsupported, unsupported_err = babet.archive.extract(
        unsupported_zip, root .. "/unsupported-out")
    ok_fail("archive.extract refuses unsupported compression",
        unsupported, unsupported_err)

    local ratio_zip = root .. "/ratio.zip"
    assert(make_zip(ratio_zip, {
        {
            name = "ratio.txt", data = string.rep("A", 4096),
            payload = deflated_4096_a, method = 8,
        },
    }))
    local ratio_default, ratio_default_err = babet.archive.list(ratio_zip)
    ok_val("archive default compression ratio accepts normal DEFLATE",
        ratio_default, ratio_default_err)
    local ratio_limited, ratio_limited_err = babet.archive.list(
        ratio_zip, { max_compression_ratio = 100 })
    ok_fail("archive max_compression_ratio rejects suspicious expansion",
        ratio_limited, ratio_limited_err)

    local limited, limited_err = babet.archive.list(valid_zip, { max_entries = 4 })
    ok_fail("archive max_entries enforced", limited, limited_err)
    limited, limited_err = babet.archive.list(valid_zip, { max_entry_size = 4095 })
    ok_fail("archive max_entry_size enforced", limited, limited_err)
    limited, limited_err = babet.archive.list(valid_zip, { max_total_size = 4107 })
    ok_fail("archive max_total_size enforced", limited, limited_err)
    local exact_limits, exact_limits_err = babet.archive.list(valid_zip, {
        max_entries = 5,
        max_entry_size = 4096,
        max_total_size = 4108,
    })
    ok_val("archive anti-bomb integer limits are inclusive at the boundary",
        exact_limits, exact_limits_err,
        function(value) return value.count == 5 and value.total_size == 4108 end)

    local limited_out = root .. "/limited-out"
    limited, limited_err = babet.archive.extract(
        valid_zip, limited_out, { max_entries = 4 })
    ok_fail("archive.extract applies anti-bomb limits before writing",
        limited, limited_err)
    ok("archive.extract limit failure creates no destination",
        babet.fileExists(limited_out) == false)
    limited, limited_err = babet.archive.extractFile(
        valid_zip, "binary.bin", root .. "/limited-single.bin",
        { max_total_size = 4 })
    ok_fail("archive.extractFile applies limits to the whole archive",
        limited, limited_err)

    local corrupt_zip = root .. "/corrupt.zip"
    local bad_data = "corrupted"
    assert(make_zip(corrupt_zip, {
        { name = "folder/", data = "" },
        { name = "folder/good.txt", data = "good" },
        {
            name = "folder/bad.txt",
            data = bad_data,
            crc32 = (crc32_number(bad_data) + 1) & 0xffffffff,
        },
    }))
    local corrupt_out = root .. "/corrupt-out"
    local corrupt, corrupt_err = babet.archive.extract(corrupt_zip, corrupt_out)
    ok_fail("archive extraction detects corrupt data/CRC", corrupt, corrupt_err)
    ok("corrupt extraction publishes no earlier staged file",
        babet.fileExists(corrupt_out .. "/folder/good.txt") == false)
    ok("corrupt extraction publishes no bad file",
        babet.fileExists(corrupt_out .. "/folder/bad.txt") == false)
    ok("corrupt extraction removes staging files",
        no_archive_temporaries(corrupt_out))
    ok("corrupt extraction removes newly created empty subdirectories",
        babet.fileExists(corrupt_out .. "/folder") == false)

    local not_zip = root .. "/not-a-zip.bin"
    assert(write_bytes(not_zip, "not a ZIP archive"))
    local invalid, invalid_err = babet.archive.list(not_zip)
    ok_fail("archive.list rejects malformed ZIP", invalid, invalid_err)
    invalid, invalid_err = babet.archive.list(root .. "/missing.zip")
    ok_fail("archive.list rejects missing archive", invalid, invalid_err)

    invalid, invalid_err = babet.archive.list(root)
    ok_fail("archive.list rejects a directory as archive source",
        invalid, invalid_err)

    local archive_fifo = root .. "/archive-input-fifo"
    local archive_fifo_created = babet.exec("mkfifo", { archive_fifo })
    ok("archive reader FIFO fixture created",
        type(archive_fifo_created) == "table" and archive_fifo_created.code == 0)
    local fifo_started = babet.time.monotonic()
    invalid, invalid_err = babet.archive.list(archive_fifo)
    local fifo_elapsed = babet.time.monotonic() - fifo_started
    ok_fail("archive.list rejects a FIFO as archive source",
        invalid, invalid_err)
    ok("archive.list rejects a FIFO without blocking",
        fifo_elapsed < 2, tostring(fifo_elapsed))
    babet.exec("rm", { "-f", archive_fifo })

    local archive_input_link = root .. "/archive-input-link.zip"
    local archive_link_created = babet.exec("ln", {
        "-s", "valid.zip", archive_input_link,
    })
    ok("archive reader symlink fixture created",
        type(archive_link_created) == "table" and archive_link_created.code == 0)
    local linked_archive, linked_archive_err = babet.archive.list(archive_input_link)
    ok_val("archive.list follows a read-only symlink to a regular ZIP",
        linked_archive, linked_archive_err,
        function(value) return value.count == 5 end)

    local outside = root .. "/outside"
    local symlink_dest = root .. "/symlink-dest"
    assert(babet.mkdir(outside))
    assert(babet.mkdir(symlink_dest))
    assert(write_bytes(outside .. "/sentinel.txt", "unchanged"))
    local ln_parent = babet.exec("ln", {
        "-s", "../outside", symlink_dest .. "/dir",
    })
    ok("archive symlink-parent fixture created",
        type(ln_parent) == "table" and ln_parent.code == 0,
        ln_parent and ln_parent.stderr)
    local parent_attack, parent_attack_err = babet.archive.extract(
        valid_zip, symlink_dest, { overwrite = true })
    ok_fail("archive.extract refuses a symlinked destination parent",
        parent_attack, parent_attack_err)
    ok("symlinked parent cannot redirect extraction outside",
        read_bytes(outside .. "/sentinel.txt") == "unchanged"
        and babet.fileExists(outside .. "/hello.txt") == false)

    local root_link = root .. "/root-link"
    local ln_root = babet.exec("ln", { "-s", "outside", root_link })
    ok("archive symlink-root fixture created",
        type(ln_root) == "table" and ln_root.code == 0)
    local root_attack, root_attack_err = babet.archive.extract(
        valid_zip, root_link, { overwrite = true })
    ok_fail("archive.extract refuses a symlink in destination root",
        root_attack, root_attack_err)

    local leaf_dest = root .. "/leaf-dest"
    assert(babet.mkdir(leaf_dest))
    assert(write_bytes(outside .. "/leaf.txt", "outside"))
    local ln_leaf = babet.exec("ln", {
        "-s", "../outside/leaf.txt", leaf_dest .. "/binary.bin",
    })
    ok("archive symlink-leaf fixture created",
        type(ln_leaf) == "table" and ln_leaf.code == 0)
    local leaf_attack, leaf_attack_err = babet.archive.extractFile(
        valid_zip, "binary.bin", leaf_dest .. "/binary.bin",
        { overwrite = true })
    ok_fail("archive.extractFile refuses a symlink destination",
        leaf_attack, leaf_attack_err)
    ok("symlink destination target remains unchanged",
        read_bytes(outside .. "/leaf.txt") == "outside")

    local empty_destination, empty_destination_err =
        babet.archive.extract(valid_zip, "")
    ok_fail("archive.extract rejects an empty destination",
        empty_destination, empty_destination_err)

    local bad, bad_err = babet.archive.list(valid_zip, "bad")
    ok_fail("archive.list opts must be a table", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { overwrite = true })
    ok_fail("archive.list rejects extraction-only options", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { unknown = true })
    ok_fail("archive.list rejects unknown options", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { [1] = true })
    ok_fail("archive options require string keys", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        overwrite = 1,
    })
    ok_fail("archive overwrite option is strictly boolean", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        preserve_permissions = "yes",
    })
    ok_fail("archive preserve_permissions option is strictly boolean", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_entries = 1.0 })
    ok_fail("archive integer limits reject floating-point numbers", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_entries = 0 })
    ok_fail("archive integer limits reject zero", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_entries = 100001 })
    ok_fail("archive max_entries hard ceiling enforced", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_compression_ratio = 0.5,
    })
    ok_fail("archive ratio rejects values below one", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_compression_ratio = 0 / 0,
    })
    ok_fail("archive ratio rejects NaN", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_compression_ratio = math.huge,
    })
    ok_fail("archive ratio rejects infinity", bad, bad_err)

    ok_raises("archive.list enforces arity",
        function() return babet.archive.list() end,
        "expects 1 or 2 arguments")
    ok_raises("archive.list rejects excess arguments",
        function() return babet.archive.list(valid_zip, nil, true) end,
        "expects 1 or 2 arguments")
    ok_raises("archive.extract enforces arity",
        function() return babet.archive.extract(valid_zip) end,
        "expects 2 or 3 arguments")
    ok_raises("archive.extract rejects excess arguments",
        function()
            return babet.archive.extract(valid_zip, root .. "/x", nil, true)
        end,
        "expects 2 or 3 arguments")
    ok_raises("archive.extractFile enforces arity",
        function() return babet.archive.extractFile(valid_zip, "x") end,
        "expects 3 or 4 arguments")
    ok_raises("archive.extractFile rejects excess arguments",
        function()
            return babet.archive.extractFile(
                valid_zip, "binary.bin", root .. "/x", nil, true)
        end,
        "expects 3 or 4 arguments")
    ok_raises("archive.list rejects non-string path",
        function() return babet.archive.list({}) end)
    ok_raises("archive.list rejects NUL in archive path",
        function() return babet.archive.list(valid_zip .. "\0ignored") end,
        "NUL")
    ok_raises("archive.extract rejects NUL in destination",
        function()
            return babet.archive.extract(valid_zip, root .. "\0ignored")
        end,
        "NUL")
    ok_raises("archive.extractFile rejects NUL in entry name",
        function()
            return babet.archive.extractFile(
                valid_zip, "binary.bin\0ignored", root .. "/nul")
        end,
        "NUL")
    ok_raises("archive.extractFile rejects NUL in destination",
        function()
            return babet.archive.extractFile(
                valid_zip, "binary.bin", root .. "/nul\0ignored")
        end,
        "NUL")


    ;(function()
    -- archive.create ---------------------------------------------------
    local create_source = root .. "/create-source"
    assert(babet.mkdir(create_source .. "/nested/empty"))
    assert(write_bytes(create_source .. "/alpha.txt", "alpha\n"))
    assert(write_bytes(create_source .. "/nested/binary.bin", "A\0B\255C"))
    assert(write_bytes(create_source .. "/nested/repeated.txt",
        string.rep("compress-me-", 2048)))

    local worker_create_code = [[
local result, err = babet.archive.create(worker.args.source, worker.args.destination)
if not result then error(err) end
return result.files
]]
    local create_worker_a, create_worker_a_err = babet.workers.spawn(
        worker_create_code,
        { source = create_source, destination = root .. "/worker-a.zip" })
    local create_worker_b, create_worker_b_err = babet.workers.spawn(
        worker_create_code,
        { source = create_source, destination = root .. "/worker-b.zip" })
    ok("archive.create starts safely in concurrent workers",
        create_worker_a ~= nil and create_worker_a_err == nil
        and create_worker_b ~= nil and create_worker_b_err == nil)
    local worker_a_ok, worker_a_files = create_worker_a:join()
    local worker_b_ok, worker_b_files = create_worker_b:join()
    ok("archive.create succeeds concurrently in worker states",
        worker_a_ok == true and worker_a_files == 3
        and worker_b_ok == true and worker_b_files == 3)
    ok("concurrent deterministic archive.create outputs are identical",
        read_bytes(root .. "/worker-a.zip") == read_bytes(root .. "/worker-b.zip"))

    local created_zip = root .. "/created.zip"
    local created, created_err = babet.archive.create(
        create_source, created_zip)
    ok_val("archive.create creates a ZIP from a directory",
        created, created_err, function(value)
            return value.files == 3 and value.directories == 2
                and value.bytes == 6 + 5 + #(string.rep("compress-me-", 2048))
                and value.path == created_zip
                and value.format == "zip"
                and value.compression == "none"
                and value.compression_level == 6
                and value.deterministic == true
        end)
    ok("archive.create publishes the destination", babet.isFile(created_zip) == true)
    local created_mode, created_mode_err = babet.getMode(created_zip)
    ok("archive.create publishes archives with mode 0644",
        created_mode == tonumber("644", 8) and created_mode_err == nil,
        tostring(created_mode_err))

    local created_list, created_list_err = babet.archive.list(created_zip)
    ok_val("archive.create output is readable by archive.list",
        created_list, created_list_err,
        function(value) return value.count == 5 end)
    ok("archive.create orders entries deterministically",
        created_list
        and created_list.entries[1].name == "alpha.txt"
        and created_list.entries[2].name == "nested/"
        and created_list.entries[3].name == "nested/binary.bin"
        and created_list.entries[4].name == "nested/empty/"
        and created_list.entries[5].name == "nested/repeated.txt")
    ok("archive.create does not copy source permission metadata",
        created_list and created_list.entries[1].unix_mode == nil)
    ok("archive.create uses DEFLATE by default for compressible files",
        created_list and created_list.entries[5].compression_method == 8,
        tostring(created_list and created_list.entries[5].compression_method))
    local created_raw = read_bytes(created_zip)
    local dos_time_lo, dos_time_hi, dos_date_lo, dos_date_hi
    if created_raw then
        dos_time_lo, dos_time_hi, dos_date_lo, dos_date_hi =
            string.byte(created_raw, 11, 14)
    end
    ok("archive.create deterministic timestamp is timezone-independent",
        dos_time_lo == 0 and dos_time_hi == 0
        and dos_date_lo == 33 and dos_date_hi == 0,
        string.format("%s,%s,%s,%s", tostring(dos_time_lo),
            tostring(dos_time_hi), tostring(dos_date_lo),
            tostring(dos_date_hi)))

    local create_roundtrip = root .. "/create-roundtrip"
    local roundtrip, roundtrip_err = babet.archive.extract(
        created_zip, create_roundtrip)
    ok_val("archive.create output extracts successfully", roundtrip, roundtrip_err)
    ok("archive.create round-trip preserves text",
        read_bytes(create_roundtrip .. "/alpha.txt") == "alpha\n")
    ok("archive.create round-trip preserves binary bytes",
        read_bytes(create_roundtrip .. "/nested/binary.bin") == "A\0B\255C")
    ok("archive.create round-trip preserves empty directories",
        babet.isDir(create_roundtrip .. "/nested/empty") == true)

    -- archive.create TAR (lot 4) --------------------------------------
    do
        local created_tar = root .. "/created.tar"
        local tar_created, tar_created_err = babet.archive.create(
            create_source, created_tar)
        ok_val("archive.create infers uncompressed TAR from .tar",
            tar_created, tar_created_err, function(value)
                return value.files == 3 and value.directories == 2
                    and value.bytes == 6 + 5 + #(string.rep("compress-me-", 2048))
                    and value.path == created_tar
                    and value.format == "tar"
                    and value.compression == "none"
                    and value.compression_level == nil
                    and value.deterministic == true
            end)
        ok("archive.create TAR publishes the destination",
            babet.isFile(created_tar) == true)
        local created_tar_mode, created_tar_mode_err = babet.getMode(created_tar)
        ok("archive.create TAR publishes with mode 0644",
            created_tar_mode == tonumber("644", 8) and created_tar_mode_err == nil,
            tostring(created_tar_mode_err))

        local created_tar_list, created_tar_list_err = babet.archive.list(created_tar)
        ok_val("archive.create TAR output is readable by archive.list",
            created_tar_list, created_tar_list_err,
            function(value)
                return value.format == "tar" and value.compression == "none"
                    and value.count == 5
            end)
        ok("archive.create TAR orders entries deterministically",
            created_tar_list
            and created_tar_list.entries[1].name == "alpha.txt"
            and created_tar_list.entries[2].name == "nested/"
            and created_tar_list.entries[3].name == "nested/binary.bin"
            and created_tar_list.entries[4].name == "nested/empty/"
            and created_tar_list.entries[5].name == "nested/repeated.txt")
        ok("archive.create TAR writes safe portable permission metadata",
            created_tar_list
            and created_tar_list.entries[1].unix_mode == tonumber("644", 8)
            and created_tar_list.entries[2].unix_mode == tonumber("755", 8))

        local tar_roundtrip = root .. "/tar-create-roundtrip"
        local tar_roundtrip_result, tar_roundtrip_err = babet.archive.extract(
            created_tar, tar_roundtrip)
        ok_val("archive.create TAR output extracts successfully",
            tar_roundtrip_result, tar_roundtrip_err)
        ok("archive.create TAR round-trip preserves text",
            read_bytes(tar_roundtrip .. "/alpha.txt") == "alpha\n")
        ok("archive.create TAR round-trip preserves binary bytes",
            read_bytes(tar_roundtrip .. "/nested/binary.bin") == "A\0B\255C")
        ok("archive.create TAR round-trip preserves empty directories",
            babet.isDir(tar_roundtrip .. "/nested/empty") == true)

        local tar_deterministic_a = root .. "/deterministic-a.tar"
        local tar_deterministic_b = root .. "/deterministic-b.tar"
        local tda, tda_err = babet.archive.create(create_source, tar_deterministic_a)
        local tdb, tdb_err = babet.archive.create(create_source, tar_deterministic_b)
        ok_val("archive.create TAR deterministic fixture A", tda, tda_err)
        ok_val("archive.create TAR deterministic fixture B", tdb, tdb_err)
        ok("archive.create TAR is byte-for-byte deterministic by default",
            read_bytes(tar_deterministic_a) == read_bytes(tar_deterministic_b))

        local function raw_tar_mtime(path)
            local raw = read_bytes(path)
            if not raw or #raw < 148 then return nil end
            local field = raw:sub(137, 148):gsub("%z.*", ""):gsub(" ", "")
            if field == "" then return 0 end
            return tonumber(field, 8)
        end
        ok("archive.create TAR deterministic timestamp is Unix epoch zero",
            raw_tar_mtime(created_tar) == 0,
            tostring(raw_tar_mtime(created_tar)))

        local tar_timestamp_source = root .. "/tar-timestamp-source"
        assert(babet.mkdir(tar_timestamp_source))
        assert(write_bytes(tar_timestamp_source .. "/stamp.txt", "timestamp"))
        local tar_timestamp_set = babet.exec("touch", {
            "-m", "-t", "200102030405.06", tar_timestamp_source .. "/stamp.txt",
        })
        ok("archive.create TAR source timestamp fixture created",
            type(tar_timestamp_set) == "table" and tar_timestamp_set.code == 0,
            tar_timestamp_set and tar_timestamp_set.stderr)
        local tar_stat = babet.exec("stat", {
            "-c", "%Y", tar_timestamp_source .. "/stamp.txt",
        })
        local tar_expected_mtime = tar_stat and tonumber(tar_stat.stdout)
        local nondeterministic_tar = root .. "/nondeterministic.tar"
        local ntar, ntar_err = babet.archive.create(
            tar_timestamp_source, nondeterministic_tar,
            { deterministic = false })
        ok_val("archive.create TAR accepts deterministic=false",
            ntar, ntar_err,
            function(value)
                return value.format == "tar" and value.deterministic == false
            end)
        ok("archive.create TAR deterministic=false stores source mtime",
            tar_expected_mtime ~= nil
            and raw_tar_mtime(nondeterministic_tar) == tar_expected_mtime,
            string.format("actual=%s expected=%s",
                tostring(raw_tar_mtime(nondeterministic_tar)),
                tostring(tar_expected_mtime)))

        local tar_old_source = root .. "/tar-old-source"
        assert(babet.mkdir(tar_old_source))
        assert(write_bytes(tar_old_source .. "/old.txt", "old"))
        local tar_old_set = babet.exec("touch", {
            "-m", "-d", "@0", tar_old_source .. "/old.txt",
        })
        ok("archive.create TAR pre-1980 timestamp fixture created",
            type(tar_old_set) == "table" and tar_old_set.code == 0,
            tar_old_set and tar_old_set.stderr)
        local tar_old_result, tar_old_err = babet.archive.create(
            tar_old_source, root .. "/old-timestamp.tar",
            { deterministic = false })
        ok_val("archive.create TAR accepts timestamps outside the ZIP DOS range",
            tar_old_result, tar_old_err)
        ok("archive.create TAR preserves the 1970 timestamp",
            raw_tar_mtime(root .. "/old-timestamp.tar") == 0,
            tostring(raw_tar_mtime(root .. "/old-timestamp.tar")))

        local tar_without_dirs = root .. "/without-directories.tar"
        local tar_no_dirs, tar_no_dirs_err = babet.archive.create(
            create_source, tar_without_dirs, { include_directories = false })
        ok_val("archive.create TAR include_directories=false",
            tar_no_dirs, tar_no_dirs_err,
            function(value)
                return value.files == 3 and value.directories == 0
            end)
        local tar_no_dirs_list = babet.archive.list(tar_without_dirs)
        ok("archive.create TAR omits explicit directories when requested",
            tar_no_dirs_list and tar_no_dirs_list.count == 3)
        local tar_no_dirs_out = root .. "/tar-no-dirs-out"
        local tar_no_dirs_extract = babet.archive.extract(
            tar_without_dirs, tar_no_dirs_out)
        ok("archive.create TAR without directory entries still extracts",
            tar_no_dirs_extract ~= nil
            and read_bytes(tar_no_dirs_out .. "/nested/binary.bin") == "A\0B\255C")
        ok("archive.create TAR cannot represent omitted empty directories",
            babet.isDir(tar_no_dirs_out .. "/nested/empty") == false)

        local uppercase_tar = root .. "/uppercase.TAR"
        local uppercase_tar_result, uppercase_tar_err = babet.archive.create(
            create_source, uppercase_tar)
        ok_val("archive.create infers TAR from a case-insensitive .tar suffix",
            uppercase_tar_result, uppercase_tar_err,
            function(value) return value.format == "tar" end)

        local explicit_tar = root .. "/explicit-format.data"
        local explicit_tar_result, explicit_tar_err = babet.archive.create(
            create_source, explicit_tar, { format = "tar" })
        ok_val("archive.create format='tar' overrides an unknown extension",
            explicit_tar_result, explicit_tar_err,
            function(value) return value.format == "tar" end)
        local explicit_tar_list = babet.archive.list(explicit_tar)
        ok("archive.create explicit TAR is detected from content",
            explicit_tar_list and explicit_tar_list.format == "tar")

        local explicit_zip = root .. "/explicit-zip.tar.gz"
        local explicit_zip_result, explicit_zip_err = babet.archive.create(
            create_source, explicit_zip, { format = "zip" })
        ok_val("archive.create format='zip' overrides a compressed TAR-looking extension",
            explicit_zip_result, explicit_zip_err,
            function(value) return value.format == "zip" end)
        local explicit_zip_list = babet.archive.list(explicit_zip)
        ok("archive.create explicit ZIP is detected from content",
            explicit_zip_list and explicit_zip_list.format == "zip")

        local legacy_extension = root .. "/legacy-extension.data"
        local legacy_zip, legacy_zip_err = babet.archive.create(
            create_source, legacy_extension)
        ok_val("archive.create keeps ZIP as the fallback for unknown extensions",
            legacy_zip, legacy_zip_err,
            function(value) return value.format == "zip" end)
        local legacy_zip_list = babet.archive.list(legacy_extension)
        ok("archive.create unknown-extension fallback is a ZIP",
            legacy_zip_list and legacy_zip_list.format == "zip")

        do
            local gzip_tar = root .. "/created.tar.gz"
            local gzip_created, gzip_created_err = babet.archive.create(
                create_source, gzip_tar)
            ok_val("archive.create infers gzip TAR from .tar.gz",
                gzip_created, gzip_created_err, function(value)
                    return value.files == 3 and value.directories == 2
                        and value.format == "tar"
                        and value.compression == "gzip"
                        and value.compression_level == 6
                        and value.deterministic == true
                end)
            local gzip_raw = read_bytes(gzip_tar)
            ok("archive.create gzip TAR writes the gzip signature",
                gzip_raw and gzip_raw:byte(1) == 0x1f
                and gzip_raw:byte(2) == 0x8b)
            local gz_mtime_1, gz_mtime_2, gz_mtime_3, gz_mtime_4
            if gzip_raw then
                gz_mtime_1, gz_mtime_2, gz_mtime_3, gz_mtime_4 =
                    gzip_raw:byte(5, 8)
            end
            ok("archive.create gzip header omits wall-clock timestamps",
                gz_mtime_1 == 0 and gz_mtime_2 == 0
                and gz_mtime_3 == 0 and gz_mtime_4 == 0)

            local gzip_list, gzip_list_err = babet.archive.list(gzip_tar)
            ok_val("archive.list detects created gzip TAR",
                gzip_list, gzip_list_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                        and value.count == 5
                        and value.total_size == 6 + 5
                            + #(string.rep("compress-me-", 2048))
                        and value.zip64 == nil
                end)
            ok("archive.list gzip TAR keeps ZIP-only entry metadata nil",
                gzip_list and gzip_list.entries[1]
                and gzip_list.entries[1].compressed_size == nil
                and gzip_list.entries[1].crc32 == nil
                and gzip_list.entries[1].compression_method == nil)

            local disguised_gzip = root .. "/gzip-content.data"
            assert(write_bytes(disguised_gzip, assert(gzip_raw)))
            local disguised_list, disguised_list_err =
                babet.archive.list(disguised_gzip)
            ok_val("archive.list detects gzip TAR independently of extension",
                disguised_list, disguised_list_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                end)

            local tgz_path = root .. "/created-alias.tgz"
            local tgz_result, tgz_err = babet.archive.create(
                create_source, tgz_path)
            ok_val("archive.create infers gzip TAR from .tgz",
                tgz_result, tgz_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                end)
            local tgz_list = babet.archive.list(tgz_path)
            ok("archive.create .tgz output is detected as gzip TAR",
                tgz_list and tgz_list.compression == "gzip")

            local uppercase_tgz = root .. "/uppercase.TAR.GZ"
            local uppercase_gzip, uppercase_gzip_err = babet.archive.create(
                create_source, uppercase_tgz)
            ok_val("archive.create gzip TAR suffix matching is case-insensitive",
                uppercase_gzip, uppercase_gzip_err,
                function(value) return value.compression == "gzip" end)

            local explicit_gzip = root .. "/explicit-gzip.data"
            local explicit_gzip_result, explicit_gzip_err =
                babet.archive.create(create_source, explicit_gzip, {
                    format = "tar.gz",
                    compression_level = 9,
                })
            ok_val("archive.create format='tar.gz' overrides extension",
                explicit_gzip_result, explicit_gzip_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                        and value.compression_level == 9
                end)
            local explicit_gzip_list = babet.archive.list(explicit_gzip)
            ok("archive.create explicit gzip TAR is detected from content",
                explicit_gzip_list
                and explicit_gzip_list.compression == "gzip")

            local explicit_plain_tgz = root .. "/explicit-plain.tgz"
            local explicit_plain_result, explicit_plain_err =
                babet.archive.create(create_source, explicit_plain_tgz, {
                    format = "tar",
                })
            ok_val("archive.create format='tar' overrides a .tgz suffix",
                explicit_plain_result, explicit_plain_err,
                function(value) return value.compression == "none" end)
            local explicit_plain_list = babet.archive.list(explicit_plain_tgz)
            ok("explicit uncompressed TAR is detected from content",
                explicit_plain_list
                and explicit_plain_list.compression == "none")

            local gzip_deterministic_a = root .. "/gzip-deterministic-a.tar.gz"
            local gzip_deterministic_b = root .. "/gzip-deterministic-b.tar.gz"
            local gda, gda_err = babet.archive.create(
                create_source, gzip_deterministic_a)
            local gdb, gdb_err = babet.archive.create(
                create_source, gzip_deterministic_b)
            ok_val("archive.create gzip deterministic fixture A", gda, gda_err)
            ok_val("archive.create gzip deterministic fixture B", gdb, gdb_err)
            ok("archive.create gzip TAR is byte-for-byte deterministic",
                read_bytes(gzip_deterministic_a)
                    == read_bytes(gzip_deterministic_b))

            local concatenated_gzip = root .. "/concatenated-gzip.tar.gz"
            assert(write_bytes(concatenated_gzip,
                assert(read_bytes(gzip_deterministic_a))
                    .. assert(read_bytes(gzip_deterministic_b))))
            local concatenated_gzip_list, concatenated_gzip_list_err =
                babet.archive.list(concatenated_gzip)
            ok_val("archive.list traverses concatenated gzip members and TAR streams",
                concatenated_gzip_list, concatenated_gzip_list_err,
                function(value)
                    return value.compression == "gzip" and value.count == 10
                end)
            local concatenated_gzip_out = root .. "/concatenated-gzip-out"
            local concatenated_gzip_extract, concatenated_gzip_extract_err =
                babet.archive.extract(
                    concatenated_gzip, concatenated_gzip_out)
            ok_fail("archive.extract rejects duplicate paths across concatenated gzip TAR streams",
                concatenated_gzip_extract, concatenated_gzip_extract_err)
            ok("concatenated gzip duplicate refusal creates no destination",
                babet.fileExists(concatenated_gzip_out) == false)

            local gzip_stored = root .. "/gzip-level-zero.tar.gz"
            local gzip_stored_result, gzip_stored_err = babet.archive.create(
                create_source, gzip_stored, { compression_level = 0 })
            ok_val("archive.create gzip accepts compression_level=0",
                gzip_stored_result, gzip_stored_err,
                function(value) return value.compression_level == 0 end)
            ok("archive.create gzip level zero remains readable",
                babet.archive.list(gzip_stored) ~= nil)

            local gzip_roundtrip = root .. "/gzip-roundtrip"
            local gzip_extract, gzip_extract_err = babet.archive.extract(
                gzip_tar, gzip_roundtrip)
            ok_val("archive.extract extracts a gzip TAR",
                gzip_extract, gzip_extract_err, function(value)
                    return value.files == 3 and value.directories == 2
                end)
            ok("archive.extract gzip TAR preserves text and binary data",
                read_bytes(gzip_roundtrip .. "/alpha.txt") == "alpha\n"
                and read_bytes(gzip_roundtrip .. "/nested/binary.bin")
                    == "A\0B\255C")
            ok("archive.extract gzip TAR preserves empty directories",
                babet.isDir(gzip_roundtrip .. "/nested/empty") == true)

            local gzip_single = root .. "/gzip-single.bin"
            local gzip_single_result, gzip_single_err =
                babet.archive.extractFile(
                    gzip_tar, "nested/binary.bin", gzip_single)
            ok_val("archive.extractFile extracts from a gzip TAR",
                gzip_single_result, gzip_single_err,
                function(value) return value.bytes == 5 end)
            ok("archive.extractFile gzip TAR is binary-safe",
                read_bytes(gzip_single) == "A\0B\255C")

            local gzip_ratio_source = root .. "/gzip-ratio-source"
            assert(babet.mkdir(gzip_ratio_source))
            assert(write_bytes(gzip_ratio_source .. "/large.txt",
                string.rep("A", 256 * 1024)))
            local gzip_ratio_archive = root .. "/gzip-ratio.tar.gz"
            assert(babet.archive.create(
                gzip_ratio_source, gzip_ratio_archive,
                { compression_level = 9 }))
            ok("archive.list gzip TAR accepts the default ratio limit",
                babet.archive.list(gzip_ratio_archive) ~= nil)
            local gzip_ratio_rejected, gzip_ratio_rejected_err =
                babet.archive.list(gzip_ratio_archive, {
                    max_compression_ratio = 2,
                })
            ok_fail("archive.list gzip TAR enforces max_compression_ratio",
                gzip_ratio_rejected, gzip_ratio_rejected_err)
            local gzip_ratio_out = root .. "/gzip-ratio-out"
            local gzip_ratio_extract, gzip_ratio_extract_err =
                babet.archive.extract(gzip_ratio_archive, gzip_ratio_out, {
                    max_compression_ratio = 2,
                })
            ok_fail("archive.extract gzip TAR applies ratio limits before writing",
                gzip_ratio_extract, gzip_ratio_extract_err)
            ok("gzip ratio refusal creates no destination",
                babet.fileExists(gzip_ratio_out) == false)
            local gzip_ratio_single = root .. "/gzip-ratio-single"
            local gzip_ratio_file, gzip_ratio_file_err =
                babet.archive.extractFile(
                    gzip_ratio_archive, "large.txt", gzip_ratio_single, {
                        max_compression_ratio = 2,
                    })
            ok_fail("archive.extractFile gzip TAR applies ratio limits to the whole archive",
                gzip_ratio_file, gzip_ratio_file_err)
            ok("gzip ratio extractFile refusal creates no output",
                babet.fileExists(gzip_ratio_single) == false)

            local padded_gzip = root .. "/padded.tar.gz"
            assert(write_bytes(padded_gzip, gzip_raw .. string.rep("\0", 32)))
            local padded_gzip_list, padded_gzip_err =
                babet.archive.list(padded_gzip)
            ok_val("archive.list accepts standard zero padding after a gzip member",
                padded_gzip_list, padded_gzip_err,
                function(value) return value.compression == "gzip" end)

            local trailing_gzip = root .. "/trailing-garbage.tar.gz"
            assert(write_bytes(trailing_gzip, gzip_raw .. "X"))
            local trailing_gzip_list, trailing_gzip_err =
                babet.archive.list(trailing_gzip)
            ok_fail("archive.list rejects non-gzip trailing data after a gzip member",
                trailing_gzip_list, trailing_gzip_err)

            local corrupt_gzip = root .. "/corrupt.tar.gz"
            local crc_position = #gzip_raw - 7
            local corrupted = gzip_raw:sub(1, crc_position - 1)
                .. string.char(gzip_raw:byte(crc_position) ~ 1)
                .. gzip_raw:sub(crc_position + 1)
            assert(write_bytes(corrupt_gzip, corrupted))
            local corrupt_gzip_list, corrupt_gzip_list_err =
                babet.archive.list(corrupt_gzip)
            ok_fail("archive.list rejects a gzip TAR with a corrupt trailer",
                corrupt_gzip_list, corrupt_gzip_list_err)
            local corrupt_gzip_out = root .. "/corrupt-gzip-out"
            local corrupt_gzip_extract, corrupt_gzip_extract_err =
                babet.archive.extract(corrupt_gzip, corrupt_gzip_out)
            ok_fail("archive.extract rejects corrupt gzip before publication",
                corrupt_gzip_extract, corrupt_gzip_extract_err)
            ok("corrupt gzip extraction creates no destination",
                babet.fileExists(corrupt_gzip_out) == false)
            local corrupt_gzip_single = root .. "/corrupt-gzip-single"
            local corrupt_gzip_file, corrupt_gzip_file_err =
                babet.archive.extractFile(
                    corrupt_gzip, "alpha.txt", corrupt_gzip_single)
            ok_fail("archive.extractFile rejects corrupt gzip before publication",
                corrupt_gzip_file, corrupt_gzip_file_err)
            ok("corrupt gzip extractFile creates no output",
                babet.fileExists(corrupt_gzip_single) == false)

            local gzip_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.gz" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
            local gzip_worker = babet.workers.spawn(gzip_worker_code, {
                source = create_source,
                archive = root .. "/worker.tar.gz",
                output = root .. "/worker-gzip-alpha.txt",
            })
            ok("gzip TAR operations start in a worker", gzip_worker ~= nil)
            local gzip_worker_ok, gzip_worker_compression = false, nil
            if gzip_worker then
                gzip_worker_ok, gzip_worker_compression = gzip_worker:join()
            end
            ok("gzip TAR operations succeed in a worker",
                gzip_worker_ok == true
                and gzip_worker_compression == "gzip")
            ok("gzip TAR worker publishes expected data",
                read_bytes(root .. "/worker-gzip-alpha.txt") == "alpha\n");

            -- Keep the separator: the next parenthesized function is a new
            -- statement, not a call on the nil result returned by ok().
            (function()
                local xz_tar = root .. "/created.tar.xz"
                local xz_created, xz_created_err = babet.archive.create(
                    create_source, xz_tar)
                ok_val("archive.create infers xz TAR from .tar.xz",
                    xz_created, xz_created_err, function(value)
                        return value.files == 3 and value.directories == 2
                            and value.format == "tar"
                            and value.compression == "xz"
                            and value.compression_level == 6
                            and value.deterministic == true
                    end)
                local xz_raw = read_bytes(xz_tar)
                ok("archive.create xz TAR writes the xz signature",
                    xz_raw and xz_raw:sub(1, 6) == string.char(0xFD) .. "7zXZ\0")

                local xz_list, xz_list_err = babet.archive.list(xz_tar)
                ok_val("archive.list detects created xz TAR",
                    xz_list, xz_list_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                            and value.count == 5
                            and value.total_size == 6 + 5
                                + #(string.rep("compress-me-", 2048))
                    end)
                ok("archive.list xz TAR keeps ZIP-only metadata nil",
                    xz_list and xz_list.entries[1]
                    and xz_list.entries[1].compressed_size == nil
                    and xz_list.entries[1].crc32 == nil
                    and xz_list.entries[1].compression_method == nil)

                local disguised_xz = root .. "/xz-content.data"
                assert(write_bytes(disguised_xz, assert(xz_raw)))
                local disguised_xz_list, disguised_xz_err =
                    babet.archive.list(disguised_xz)
                ok_val("archive.list detects xz TAR independently of extension",
                    disguised_xz_list, disguised_xz_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                    end)

                local txz_path = root .. "/created-alias.txz"
                local txz_result, txz_err = babet.archive.create(
                    create_source, txz_path)
                ok_val("archive.create infers xz TAR from .txz",
                    txz_result, txz_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                    end)
                local txz_list = babet.archive.list(txz_path)
                ok("archive.create .txz output is detected as xz TAR",
                    txz_list and txz_list.compression == "xz")

                local uppercase_xz = root .. "/uppercase.TAR.XZ"
                local uppercase_xz_result, uppercase_xz_err =
                    babet.archive.create(create_source, uppercase_xz)
                ok_val("archive.create xz suffix matching is case-insensitive",
                    uppercase_xz_result, uppercase_xz_err,
                    function(value) return value.compression == "xz" end)

                local explicit_xz = root .. "/explicit-xz.data"
                local explicit_xz_result, explicit_xz_err =
                    babet.archive.create(create_source, explicit_xz, {
                        format = "tar.xz",
                        compression_level = 9,
                    })
                ok_val("archive.create format='tar.xz' overrides extension",
                    explicit_xz_result, explicit_xz_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                            and value.compression_level == 9
                    end)
                local explicit_xz_list = babet.archive.list(explicit_xz)
                ok("archive.create explicit xz TAR is detected from content",
                    explicit_xz_list
                    and explicit_xz_list.compression == "xz")

                local explicit_plain_txz = root .. "/explicit-plain.txz"
                local explicit_plain_txz_result, explicit_plain_txz_err =
                    babet.archive.create(create_source, explicit_plain_txz, {
                        format = "tar",
                    })
                ok_val("archive.create format='tar' overrides a .txz suffix",
                    explicit_plain_txz_result, explicit_plain_txz_err,
                    function(value) return value.compression == "none" end)
                local explicit_plain_txz_list =
                    babet.archive.list(explicit_plain_txz)
                ok("explicit uncompressed .txz is detected from content",
                    explicit_plain_txz_list
                    and explicit_plain_txz_list.compression == "none")

                local xz_deterministic_a = root .. "/xz-deterministic-a.tar.xz"
                local xz_deterministic_b = root .. "/xz-deterministic-b.tar.xz"
                local xda, xda_err = babet.archive.create(
                    create_source, xz_deterministic_a)
                local xdb, xdb_err = babet.archive.create(
                    create_source, xz_deterministic_b)
                ok_val("archive.create xz deterministic fixture A", xda, xda_err)
                ok_val("archive.create xz deterministic fixture B", xdb, xdb_err)
                ok("archive.create xz TAR is byte-for-byte deterministic",
                    read_bytes(xz_deterministic_a)
                        == read_bytes(xz_deterministic_b))

                local xz_level_zero = root .. "/xz-level-zero.tar.xz"
                local xz_zero, xz_zero_err = babet.archive.create(
                    create_source, xz_level_zero,
                    { compression_level = 0 })
                ok_val("archive.create xz accepts compression_level=0",
                    xz_zero, xz_zero_err,
                    function(value) return value.compression_level == 0 end)
                ok("archive.create xz level zero remains readable",
                    babet.archive.list(xz_level_zero) ~= nil)

                local xz_roundtrip = root .. "/xz-roundtrip"
                local xz_extract, xz_extract_err = babet.archive.extract(
                    xz_tar, xz_roundtrip)
                ok_val("archive.extract extracts an xz TAR",
                    xz_extract, xz_extract_err, function(value)
                        return value.files == 3 and value.directories == 2
                    end)
                ok("archive.extract xz TAR preserves text and binary data",
                    read_bytes(xz_roundtrip .. "/alpha.txt") == "alpha\n"
                    and read_bytes(xz_roundtrip .. "/nested/binary.bin")
                        == "A\0B\255C")
                ok("archive.extract xz TAR preserves empty directories",
                    babet.isDir(xz_roundtrip .. "/nested/empty") == true)

                local xz_single = root .. "/xz-single.bin"
                local xz_single_result, xz_single_err =
                    babet.archive.extractFile(
                        xz_tar, "nested/binary.bin", xz_single)
                ok_val("archive.extractFile extracts from an xz TAR",
                    xz_single_result, xz_single_err,
                    function(value) return value.bytes == 5 end)
                ok("archive.extractFile xz TAR is binary-safe",
                    read_bytes(xz_single) == "A\0B\255C")

                local xz_ratio_source = root .. "/xz-ratio-source"
                assert(babet.mkdir(xz_ratio_source))
                assert(write_bytes(xz_ratio_source .. "/large.txt",
                    string.rep("A", 16 * 1024)))
                local xz_ratio_archive = root .. "/xz-ratio.tar.xz"
                assert(babet.archive.create(
                    xz_ratio_source, xz_ratio_archive,
                    { compression_level = 9 }))
                ok("archive.list xz TAR accepts the default ratio limit",
                    babet.archive.list(xz_ratio_archive) ~= nil)
                local xz_ratio_rejected, xz_ratio_rejected_err =
                    babet.archive.list(xz_ratio_archive, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.list xz TAR enforces max_compression_ratio",
                    xz_ratio_rejected, xz_ratio_rejected_err)
                local xz_ratio_out = root .. "/xz-ratio-out"
                local xz_ratio_extract, xz_ratio_extract_err =
                    babet.archive.extract(xz_ratio_archive, xz_ratio_out, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.extract xz TAR applies ratio limits before writing",
                    xz_ratio_extract, xz_ratio_extract_err)
                ok("xz ratio refusal creates no destination",
                    babet.fileExists(xz_ratio_out) == false)
                local xz_ratio_single = root .. "/xz-ratio-single"
                local xz_ratio_file, xz_ratio_file_err =
                    babet.archive.extractFile(
                        xz_ratio_archive, "large.txt", xz_ratio_single, {
                            max_compression_ratio = 2,
                        })
                ok_fail("archive.extractFile xz TAR applies ratio limits to the whole archive",
                    xz_ratio_file, xz_ratio_file_err)
                ok("xz ratio extractFile refusal creates no output",
                    babet.fileExists(xz_ratio_single) == false)

                local corrupt_xz = root .. "/corrupt.tar.xz"
                local corrupt_position = math.max(13, #xz_raw // 2)
                local corrupt_xz_raw = xz_raw:sub(1, corrupt_position - 1)
                    .. string.char(xz_raw:byte(corrupt_position) ~ 1)
                    .. xz_raw:sub(corrupt_position + 1)
                assert(write_bytes(corrupt_xz, corrupt_xz_raw))
                local corrupt_xz_list, corrupt_xz_list_err =
                    babet.archive.list(corrupt_xz)
                ok_fail("archive.list rejects a corrupt xz TAR",
                    corrupt_xz_list, corrupt_xz_list_err)
                local corrupt_xz_out = root .. "/corrupt-xz-out"
                local corrupt_xz_extract, corrupt_xz_extract_err =
                    babet.archive.extract(corrupt_xz, corrupt_xz_out)
                ok_fail("archive.extract rejects corrupt xz before publication",
                    corrupt_xz_extract, corrupt_xz_extract_err)
                ok("corrupt xz extraction creates no destination",
                    babet.fileExists(corrupt_xz_out) == false)
                local corrupt_xz_single = root .. "/corrupt-xz-single"
                local corrupt_xz_file, corrupt_xz_file_err =
                    babet.archive.extractFile(
                        corrupt_xz, "alpha.txt", corrupt_xz_single)
                ok_fail("archive.extractFile rejects corrupt xz before publication",
                    corrupt_xz_file, corrupt_xz_file_err)
                ok("corrupt xz extractFile creates no output",
                    babet.fileExists(corrupt_xz_single) == false)

                local xz_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.xz" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
                local xz_worker = babet.workers.spawn(xz_worker_code, {
                    source = create_source,
                    archive = root .. "/worker.tar.xz",
                    output = root .. "/worker-xz-alpha.txt",
                })
                ok("xz TAR operations start in a worker", xz_worker ~= nil)
                local xz_worker_ok, xz_worker_compression = false, nil
                if xz_worker then
                    xz_worker_ok, xz_worker_compression = xz_worker:join()
                end
                ok("xz TAR operations succeed in a worker",
                    xz_worker_ok == true
                    and xz_worker_compression == "xz")
                ok("xz TAR worker publishes expected data",
                    read_bytes(root .. "/worker-xz-alpha.txt") == "alpha\n")
            end)()

            ;(function()
                local bzip2_tar = root .. "/created.tar.bz2"
                local bzip2_created, bzip2_created_err = babet.archive.create(
                    create_source, bzip2_tar)
                ok_val("archive.create infers bzip2 TAR from .tar.bz2",
                    bzip2_created, bzip2_created_err, function(value)
                        return value.files == 3 and value.directories == 2
                            and value.format == "tar"
                            and value.compression == "bzip2"
                            and value.compression_level == 6
                            and value.deterministic == true
                    end)
                local bzip2_raw = read_bytes(bzip2_tar)
                ok("archive.create bzip2 TAR writes the BZh signature",
                    bzip2_raw and bzip2_raw:sub(1, 3) == "BZh")

                local bzip2_list, bzip2_list_err =
                    babet.archive.list(bzip2_tar)
                ok_val("archive.list detects created bzip2 TAR",
                    bzip2_list, bzip2_list_err, function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                            and value.count == 5
                            and value.total_size == 6 + 5
                                + #(string.rep("compress-me-", 2048))
                    end)
                ok("archive.list bzip2 TAR keeps ZIP-only metadata nil",
                    bzip2_list and bzip2_list.entries[1]
                    and bzip2_list.entries[1].compressed_size == nil
                    and bzip2_list.entries[1].crc32 == nil
                    and bzip2_list.entries[1].compression_method == nil)

                local disguised_bzip2 = root .. "/bzip2-content.data"
                assert(write_bytes(disguised_bzip2, assert(bzip2_raw)))
                local disguised_bzip2_list, disguised_bzip2_err =
                    babet.archive.list(disguised_bzip2)
                ok_val("archive.list detects bzip2 TAR independently of extension",
                    disguised_bzip2_list, disguised_bzip2_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                    end)

                local tbz2_path = root .. "/created-alias.tbz2"
                local tbz2_result, tbz2_err = babet.archive.create(
                    create_source, tbz2_path)
                ok_val("archive.create infers bzip2 TAR from .tbz2",
                    tbz2_result, tbz2_err, function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                    end)
                local tbz2_list = babet.archive.list(tbz2_path)
                ok("archive.create .tbz2 output is detected as bzip2 TAR",
                    tbz2_list and tbz2_list.compression == "bzip2")

                local tbz_path = root .. "/created-short-alias.tbz"
                local tbz_result, tbz_err = babet.archive.create(
                    create_source, tbz_path)
                ok_val("archive.create infers bzip2 TAR from .tbz",
                    tbz_result, tbz_err, function(value)
                        return value.compression == "bzip2"
                    end)

                local uppercase_bzip2 = root .. "/uppercase.TAR.BZ2"
                local uppercase_bzip2_result, uppercase_bzip2_err =
                    babet.archive.create(create_source, uppercase_bzip2)
                ok_val("archive.create bzip2 suffix matching is case-insensitive",
                    uppercase_bzip2_result, uppercase_bzip2_err,
                    function(value) return value.compression == "bzip2" end)

                local explicit_bzip2 = root .. "/explicit-bzip2.data"
                local explicit_bzip2_result, explicit_bzip2_err =
                    babet.archive.create(create_source, explicit_bzip2, {
                        format = "tar.bz2",
                        compression_level = 9,
                    })
                ok_val("archive.create format='tar.bz2' overrides extension",
                    explicit_bzip2_result, explicit_bzip2_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                            and value.compression_level == 9
                    end)
                local explicit_bzip2_list =
                    babet.archive.list(explicit_bzip2)
                ok("archive.create explicit bzip2 TAR is detected from content",
                    explicit_bzip2_list
                    and explicit_bzip2_list.compression == "bzip2")

                local explicit_plain_tbz2 = root .. "/explicit-plain.tbz2"
                local explicit_plain_tbz2_result, explicit_plain_tbz2_err =
                    babet.archive.create(create_source, explicit_plain_tbz2, {
                        format = "tar",
                    })
                ok_val("archive.create format='tar' overrides a .tbz2 suffix",
                    explicit_plain_tbz2_result, explicit_plain_tbz2_err,
                    function(value) return value.compression == "none" end)
                local explicit_plain_tbz2_list =
                    babet.archive.list(explicit_plain_tbz2)
                ok("explicit uncompressed .tbz2 is detected from content",
                    explicit_plain_tbz2_list
                    and explicit_plain_tbz2_list.compression == "none")

                local bzip2_deterministic_a =
                    root .. "/bzip2-deterministic-a.tar.bz2"
                local bzip2_deterministic_b =
                    root .. "/bzip2-deterministic-b.tar.bz2"
                local bda, bda_err = babet.archive.create(
                    create_source, bzip2_deterministic_a)
                local bdb, bdb_err = babet.archive.create(
                    create_source, bzip2_deterministic_b)
                ok_val("archive.create bzip2 deterministic fixture A",
                    bda, bda_err)
                ok_val("archive.create bzip2 deterministic fixture B",
                    bdb, bdb_err)
                ok("archive.create bzip2 TAR is byte-for-byte deterministic",
                    read_bytes(bzip2_deterministic_a)
                        == read_bytes(bzip2_deterministic_b))

                local bzip2_level_one = root .. "/bzip2-level-one.tar.bz2"
                local bzip2_one, bzip2_one_err = babet.archive.create(
                    create_source, bzip2_level_one,
                    { compression_level = 1 })
                ok_val("archive.create bzip2 accepts compression_level=1",
                    bzip2_one, bzip2_one_err,
                    function(value) return value.compression_level == 1 end)
                ok("archive.create bzip2 level one remains readable",
                    babet.archive.list(bzip2_level_one) ~= nil)

                local bzip2_zero, bzip2_zero_err = babet.archive.create(
                    create_source, root .. "/bzip2-level-zero.tar.bz2",
                    { compression_level = 0 })
                ok_fail("archive.create bzip2 rejects compression_level=0",
                    bzip2_zero, bzip2_zero_err)

                local bzip2_out = root .. "/bzip2-out"
                local bzip2_extract, bzip2_extract_err =
                    babet.archive.extract(bzip2_tar, bzip2_out)
                ok_val("archive.extract extracts a bzip2 TAR",
                    bzip2_extract, bzip2_extract_err)
                ok("archive.extract bzip2 TAR preserves text and binary data",
                    read_bytes(bzip2_out .. "/alpha.txt") == "alpha\n"
                    and read_bytes(bzip2_out .. "/nested/binary.bin")
                        == "A\0B\255C")
                ok("archive.extract bzip2 TAR preserves empty directories",
                    babet.isDir(bzip2_out .. "/nested/empty") == true)

                local bzip2_single = root .. "/bzip2-single.bin"
                local bzip2_file, bzip2_file_err = babet.archive.extractFile(
                    bzip2_tar, "nested/binary.bin", bzip2_single)
                ok_val("archive.extractFile extracts from a bzip2 TAR",
                    bzip2_file, bzip2_file_err)
                ok("archive.extractFile bzip2 TAR is binary-safe",
                    read_bytes(bzip2_single) == "A\0B\255C")

                local ratio_source = root .. "/bzip2-ratio-source"
                assert(babet.mkdir(ratio_source))
                assert(write_bytes(ratio_source .. "/ratio.txt",
                    string.rep("A", 16 * 1024)))
                local ratio_archive = root .. "/bzip2-ratio.tar.bz2"
                local ratio_created, ratio_created_err =
                    babet.archive.create(ratio_source, ratio_archive, {
                        compression_level = 9,
                    })
                ok_val("archive.create bzip2 ratio fixture",
                    ratio_created, ratio_created_err)
                local ratio_default, ratio_default_err =
                    babet.archive.list(ratio_archive)
                ok_val("archive.list bzip2 TAR accepts the default ratio limit",
                    ratio_default, ratio_default_err)
                local ratio_limited, ratio_limited_err =
                    babet.archive.list(ratio_archive, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.list bzip2 TAR enforces max_compression_ratio",
                    ratio_limited, ratio_limited_err)
                local ratio_out = root .. "/bzip2-ratio-out"
                local ratio_extract, ratio_extract_err =
                    babet.archive.extract(ratio_archive, ratio_out, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.extract bzip2 TAR applies ratio limits before writing",
                    ratio_extract, ratio_extract_err)
                ok("bzip2 ratio refusal creates no destination",
                    babet.fileExists(ratio_out) == false)
                local ratio_single = root .. "/bzip2-ratio-single"
                local ratio_file, ratio_file_err =
                    babet.archive.extractFile(
                        ratio_archive, "ratio.txt", ratio_single, {
                            max_compression_ratio = 2,
                        })
                ok_fail("archive.extractFile bzip2 TAR applies ratio limits to the whole archive",
                    ratio_file, ratio_file_err)
                ok("bzip2 ratio extractFile refusal creates no output",
                    babet.fileExists(ratio_single) == false)

                local corrupt_bzip2 = root .. "/corrupt.tar.bz2"
                local corrupt_position = 20
                local corrupt_bzip2_raw = bzip2_raw:sub(1, corrupt_position - 1)
                    .. string.char(bzip2_raw:byte(corrupt_position) ~ 1)
                    .. bzip2_raw:sub(corrupt_position + 1)
                assert(write_bytes(corrupt_bzip2, corrupt_bzip2_raw))
                local corrupt_bzip2_list, corrupt_bzip2_list_err =
                    babet.archive.list(corrupt_bzip2)
                ok_fail("archive.list rejects a corrupt bzip2 TAR",
                    corrupt_bzip2_list, corrupt_bzip2_list_err)
                local corrupt_bzip2_out = root .. "/corrupt-bzip2-out"
                local corrupt_bzip2_extract, corrupt_bzip2_extract_err =
                    babet.archive.extract(corrupt_bzip2, corrupt_bzip2_out)
                ok_fail("archive.extract rejects corrupt bzip2 before publication",
                    corrupt_bzip2_extract, corrupt_bzip2_extract_err)
                ok("corrupt bzip2 extraction creates no destination",
                    babet.fileExists(corrupt_bzip2_out) == false)
                local corrupt_bzip2_single =
                    root .. "/corrupt-bzip2-single"
                local corrupt_bzip2_file, corrupt_bzip2_file_err =
                    babet.archive.extractFile(
                        corrupt_bzip2, "alpha.txt", corrupt_bzip2_single)
                ok_fail("archive.extractFile rejects corrupt bzip2 before publication",
                    corrupt_bzip2_file, corrupt_bzip2_file_err)
                ok("corrupt bzip2 extractFile creates no output",
                    babet.fileExists(corrupt_bzip2_single) == false)

                local bzip2_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.bz2" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
                local bzip2_worker = babet.workers.spawn(bzip2_worker_code, {
                    source = create_source,
                    archive = root .. "/worker.tar.bz2",
                    output = root .. "/worker-bzip2-alpha.txt",
                })
                ok("bzip2 TAR operations start in a worker",
                    bzip2_worker ~= nil)
                local bzip2_worker_ok, bzip2_worker_compression = false, nil
                if bzip2_worker then
                    bzip2_worker_ok, bzip2_worker_compression =
                        bzip2_worker:join()
                end
                ok("bzip2 TAR operations succeed in a worker",
                    bzip2_worker_ok == true
                    and bzip2_worker_compression == "bzip2")
                ok("bzip2 TAR worker publishes expected data",
                    read_bytes(root .. "/worker-bzip2-alpha.txt")
                        == "alpha\n")
            end)()

            ;(function()
                local zstd_tar = root .. "/created.tar.zst"
                local zstd_created, zstd_created_err = babet.archive.create(
                    create_source, zstd_tar)
                ok_val("archive.create infers zstd TAR from .tar.zst",
                    zstd_created, zstd_created_err, function(value)
                        return value.files == 3 and value.directories == 2
                            and value.format == "tar"
                            and value.compression == "zstd"
                            and value.compression_level == 6
                            and value.deterministic == true
                    end)
                local zstd_raw = read_bytes(zstd_tar)
                ok("archive.create zstd TAR writes the zstd signature",
                    zstd_raw and zstd_raw:sub(1, 4)
                        == string.char(0x28, 0xB5, 0x2F, 0xFD))

                local zstd_list, zstd_list_err =
                    babet.archive.list(zstd_tar)
                ok_val("archive.list detects created zstd TAR",
                    zstd_list, zstd_list_err, function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                            and value.count == 5
                            and value.total_size == 6 + 5
                                + #(string.rep("compress-me-", 2048))
                    end)
                ok("archive.list zstd TAR keeps ZIP-only metadata nil",
                    zstd_list and zstd_list.entries[1]
                    and zstd_list.entries[1].compressed_size == nil
                    and zstd_list.entries[1].crc32 == nil
                    and zstd_list.entries[1].compression_method == nil)

                local disguised_zstd = root .. "/zstd-content.data"
                assert(write_bytes(disguised_zstd, assert(zstd_raw)))
                local disguised_zstd_list, disguised_zstd_err =
                    babet.archive.list(disguised_zstd)
                ok_val("archive.list detects zstd TAR independently of extension",
                    disguised_zstd_list, disguised_zstd_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                    end)

                local tzst_path = root .. "/created-alias.tzst"
                local tzst_result, tzst_err = babet.archive.create(
                    create_source, tzst_path)
                ok_val("archive.create infers zstd TAR from .tzst",
                    tzst_result, tzst_err, function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                    end)
                local tzst_list = babet.archive.list(tzst_path)
                ok("archive.create .tzst output is detected as zstd TAR",
                    tzst_list and tzst_list.compression == "zstd")

                local tar_zstd_path = root .. "/created-long-alias.tar.zstd"
                local tar_zstd_result, tar_zstd_err = babet.archive.create(
                    create_source, tar_zstd_path)
                ok_val("archive.create infers zstd TAR from .tar.zstd",
                    tar_zstd_result, tar_zstd_err, function(value)
                        return value.compression == "zstd"
                    end)

                local uppercase_zstd = root .. "/uppercase.TAR.ZST"
                local uppercase_zstd_result, uppercase_zstd_err =
                    babet.archive.create(create_source, uppercase_zstd)
                ok_val("archive.create zstd suffix matching is case-insensitive",
                    uppercase_zstd_result, uppercase_zstd_err,
                    function(value) return value.compression == "zstd" end)

                local explicit_zstd = root .. "/explicit-zstd.data"
                local explicit_zstd_result, explicit_zstd_err =
                    babet.archive.create(create_source, explicit_zstd, {
                        format = "tar.zst",
                        compression_level = 19,
                    })
                ok_val("archive.create format='tar.zst' overrides extension",
                    explicit_zstd_result, explicit_zstd_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                            and value.compression_level == 19
                    end)
                local explicit_zstd_list = babet.archive.list(explicit_zstd)
                ok("archive.create explicit zstd TAR is detected from content",
                    explicit_zstd_list
                    and explicit_zstd_list.compression == "zstd")

                local explicit_plain_tzst = root .. "/explicit-plain.tzst"
                local explicit_plain_tzst_result, explicit_plain_tzst_err =
                    babet.archive.create(create_source, explicit_plain_tzst, {
                        format = "tar",
                    })
                ok_val("archive.create format='tar' overrides a .tzst suffix",
                    explicit_plain_tzst_result, explicit_plain_tzst_err,
                    function(value) return value.compression == "none" end)
                local explicit_plain_tzst_list =
                    babet.archive.list(explicit_plain_tzst)
                ok("explicit uncompressed .tzst is detected from content",
                    explicit_plain_tzst_list
                    and explicit_plain_tzst_list.compression == "none")

                local zstd_deterministic_a =
                    root .. "/zstd-deterministic-a.tar.zst"
                local zstd_deterministic_b =
                    root .. "/zstd-deterministic-b.tar.zst"
                local zda, zda_err = babet.archive.create(
                    create_source, zstd_deterministic_a)
                local zdb, zdb_err = babet.archive.create(
                    create_source, zstd_deterministic_b)
                ok_val("archive.create zstd deterministic fixture A",
                    zda, zda_err)
                ok_val("archive.create zstd deterministic fixture B",
                    zdb, zdb_err)
                ok("archive.create zstd TAR is byte-for-byte deterministic",
                    read_bytes(zstd_deterministic_a)
                        == read_bytes(zstd_deterministic_b))

                local zstd_level_zero = root .. "/zstd-level-zero.tar.zst"
                local zstd_zero, zstd_zero_err = babet.archive.create(
                    create_source, zstd_level_zero,
                    { compression_level = 0 })
                ok_val("archive.create zstd accepts compression_level=0",
                    zstd_zero, zstd_zero_err,
                    function(value) return value.compression_level == 0 end)
                ok("archive.create zstd level zero remains readable",
                    babet.archive.list(zstd_level_zero) ~= nil)

                local zstd_level_nineteen =
                    root .. "/zstd-level-nineteen.tar.zst"
                local zstd_nineteen, zstd_nineteen_err =
                    babet.archive.create(create_source, zstd_level_nineteen,
                        { compression_level = 19 })
                ok_val("archive.create zstd accepts compression_level=19",
                    zstd_nineteen, zstd_nineteen_err,
                    function(value) return value.compression_level == 19 end)

                local zstd_twenty, zstd_twenty_err = babet.archive.create(
                    create_source, root .. "/zstd-level-twenty.tar.zst",
                    { compression_level = 20 })
                ok_fail("archive.create zstd rejects compression_level=20",
                    zstd_twenty, zstd_twenty_err)

                local zstd_out = root .. "/zstd-out"
                local zstd_extract, zstd_extract_err =
                    babet.archive.extract(zstd_tar, zstd_out)
                ok_val("archive.extract extracts a zstd TAR",
                    zstd_extract, zstd_extract_err)
                ok("archive.extract zstd TAR preserves text and binary data",
                    read_bytes(zstd_out .. "/alpha.txt") == "alpha\n"
                    and read_bytes(zstd_out .. "/nested/binary.bin")
                        == "A\0B\255C")
                ok("archive.extract zstd TAR preserves empty directories",
                    babet.isDir(zstd_out .. "/nested/empty") == true)

                local zstd_single = root .. "/zstd-single.bin"
                local zstd_file, zstd_file_err = babet.archive.extractFile(
                    zstd_tar, "nested/binary.bin", zstd_single)
                ok_val("archive.extractFile extracts from a zstd TAR",
                    zstd_file, zstd_file_err)
                ok("archive.extractFile zstd TAR is binary-safe",
                    read_bytes(zstd_single) == "A\0B\255C")

                local ratio_source = root .. "/zstd-ratio-source"
                assert(babet.mkdir(ratio_source))
                assert(write_bytes(ratio_source .. "/ratio.txt",
                    string.rep("A", 16 * 1024)))
                local ratio_archive = root .. "/zstd-ratio.tar.zst"
                local ratio_created, ratio_created_err =
                    babet.archive.create(ratio_source, ratio_archive, {
                        compression_level = 19,
                    })
                ok_val("archive.create zstd ratio fixture",
                    ratio_created, ratio_created_err)
                local ratio_default, ratio_default_err =
                    babet.archive.list(ratio_archive)
                ok_val("archive.list zstd TAR accepts the default ratio limit",
                    ratio_default, ratio_default_err)
                local ratio_limited, ratio_limited_err =
                    babet.archive.list(ratio_archive, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.list zstd TAR enforces max_compression_ratio",
                    ratio_limited, ratio_limited_err)
                local ratio_out = root .. "/zstd-ratio-out"
                local ratio_extract, ratio_extract_err =
                    babet.archive.extract(ratio_archive, ratio_out, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.extract zstd TAR applies ratio limits before writing",
                    ratio_extract, ratio_extract_err)
                ok("zstd ratio refusal creates no destination",
                    babet.fileExists(ratio_out) == false)
                local ratio_single = root .. "/zstd-ratio-single"
                local ratio_file, ratio_file_err =
                    babet.archive.extractFile(
                        ratio_archive, "ratio.txt", ratio_single, {
                            max_compression_ratio = 2,
                        })
                ok_fail("archive.extractFile zstd TAR applies ratio limits to the whole archive",
                    ratio_file, ratio_file_err)
                ok("zstd ratio extractFile refusal creates no output",
                    babet.fileExists(ratio_single) == false)

                local concatenated_zstd = root .. "/concatenated.tar.zst"
                local second_zstd_raw = read_bytes(zstd_deterministic_b)
                assert(write_bytes(concatenated_zstd,
                    assert(zstd_raw) .. assert(second_zstd_raw)))
                local concatenated_list, concatenated_list_err =
                    babet.archive.list(concatenated_zstd)
                ok_val("archive.list traverses concatenated zstd frames and TAR streams",
                    concatenated_list, concatenated_list_err,
                    function(value) return value.count == 10 end)
                local concatenated_out = root .. "/concatenated-zstd-out"
                local concatenated_extract, concatenated_extract_err =
                    babet.archive.extract(concatenated_zstd, concatenated_out)
                ok_fail("archive.extract rejects duplicate paths across concatenated zstd TAR streams",
                    concatenated_extract, concatenated_extract_err)
                ok("concatenated zstd duplicate refusal creates no destination",
                    babet.fileExists(concatenated_out) == false)

                local trailing_zstd = root .. "/trailing.tar.zst"
                assert(write_bytes(trailing_zstd, assert(zstd_raw) .. "X"))
                local trailing_zstd_list, trailing_zstd_list_err =
                    babet.archive.list(trailing_zstd)
                ok_fail("archive.list rejects non-zstd trailing data after a zstd TAR",
                    trailing_zstd_list, trailing_zstd_list_err)
                local trailing_zstd_out = root .. "/trailing-zstd-out"
                local trailing_zstd_extract, trailing_zstd_extract_err =
                    babet.archive.extract(trailing_zstd, trailing_zstd_out)
                ok_fail("archive.extract rejects zstd trailing data before publication",
                    trailing_zstd_extract, trailing_zstd_extract_err)
                ok("zstd trailing-data refusal creates no destination",
                    babet.fileExists(trailing_zstd_out) == false)

                local corrupt_zstd = root .. "/corrupt.tar.zst"
                local corrupt_position = #zstd_raw - 2
                local corrupt_zstd_raw = zstd_raw:sub(1, corrupt_position - 1)
                    .. string.char(zstd_raw:byte(corrupt_position) ~ 1)
                    .. zstd_raw:sub(corrupt_position + 1)
                assert(write_bytes(corrupt_zstd, corrupt_zstd_raw))
                local corrupt_zstd_list, corrupt_zstd_list_err =
                    babet.archive.list(corrupt_zstd)
                ok_fail("archive.list rejects a corrupt zstd TAR",
                    corrupt_zstd_list, corrupt_zstd_list_err)
                local corrupt_zstd_out = root .. "/corrupt-zstd-out"
                local corrupt_zstd_extract, corrupt_zstd_extract_err =
                    babet.archive.extract(corrupt_zstd, corrupt_zstd_out)
                ok_fail("archive.extract rejects corrupt zstd before publication",
                    corrupt_zstd_extract, corrupt_zstd_extract_err)
                ok("corrupt zstd extraction creates no destination",
                    babet.fileExists(corrupt_zstd_out) == false)
                local corrupt_zstd_single = root .. "/corrupt-zstd-single"
                local corrupt_zstd_file, corrupt_zstd_file_err =
                    babet.archive.extractFile(
                        corrupt_zstd, "alpha.txt", corrupt_zstd_single)
                ok_fail("archive.extractFile rejects corrupt zstd before publication",
                    corrupt_zstd_file, corrupt_zstd_file_err)
                ok("corrupt zstd extractFile creates no output",
                    babet.fileExists(corrupt_zstd_single) == false)

                local zstd_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.zst" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
                local zstd_worker = babet.workers.spawn(zstd_worker_code, {
                    source = create_source,
                    archive = root .. "/worker.tar.zst",
                    output = root .. "/worker-zstd-alpha.txt",
                })
                ok("zstd TAR operations start in a worker",
                    zstd_worker ~= nil)
                local zstd_worker_ok, zstd_worker_compression = false, nil
                if zstd_worker then
                    zstd_worker_ok, zstd_worker_compression =
                        zstd_worker:join()
                end
                ok("zstd TAR operations succeed in a worker",
                    zstd_worker_ok == true
                    and zstd_worker_compression == "zstd")
                ok("zstd TAR worker publishes expected data",
                    read_bytes(root .. "/worker-zstd-alpha.txt")
                        == "alpha\n")
            end)()
        end

        local tar_level, tar_level_err = babet.archive.create(
            create_source, root .. "/invalid-level.tar",
            { compression_level = 0 })
        ok_fail("archive.create rejects compression_level for inferred TAR",
            tar_level, tar_level_err)
        local explicit_tar_level, explicit_tar_level_err = babet.archive.create(
            create_source, root .. "/invalid-explicit-level.data",
            { format = "tar", compression_level = 0 })
        ok_fail("archive.create rejects compression_level for explicit TAR",
            explicit_tar_level, explicit_tar_level_err)

        local tar_overwrite_path = root .. "/overwrite.tar"
        assert(write_bytes(tar_overwrite_path, "keep"))
        local tar_overwrite_refused, tar_overwrite_refused_err =
            babet.archive.create(create_source, tar_overwrite_path)
        ok_fail("archive.create TAR refuses overwrite by default",
            tar_overwrite_refused, tar_overwrite_refused_err)
        ok("archive.create TAR overwrite refusal preserves destination",
            read_bytes(tar_overwrite_path) == "keep")
        local tar_overwrite, tar_overwrite_err = babet.archive.create(
            create_source, tar_overwrite_path, { overwrite = true })
        ok_val("archive.create TAR overwrite=true publishes atomically",
            tar_overwrite, tar_overwrite_err)
        ok("archive.create TAR overwritten output is valid",
            babet.archive.list(tar_overwrite_path) ~= nil)

        local empty_tar_source = root .. "/empty-tar-source"
        assert(babet.mkdir(empty_tar_source))
        local empty_created_tar = root .. "/empty-created.tar"
        local empty_tar, empty_tar_err = babet.archive.create(
            empty_tar_source, empty_created_tar)
        ok_val("archive.create supports an empty TAR source directory",
            empty_tar, empty_tar_err,
            function(value)
                return value.files == 0 and value.directories == 0
            end)
        local empty_tar_list = babet.archive.list(empty_created_tar)
        ok("archive.create empty TAR produces an empty archive",
            empty_tar_list and empty_tar_list.count == 0)

        local long_tar_source = root .. "/long-tar-source"
        local long_tar_component = string.rep("p", 180)
        assert(babet.mkdir(long_tar_source .. "/" .. long_tar_component))
        assert(write_bytes(long_tar_source .. "/" .. long_tar_component .. "/x.txt",
            "pax-long-name"))
        local long_tar = root .. "/long-path.tar"
        local long_tar_result, long_tar_err = babet.archive.create(
            long_tar_source, long_tar)
        ok_val("archive.create TAR emits pax headers for long paths",
            long_tar_result, long_tar_err)
        local long_tar_list = babet.archive.list(long_tar)
        ok("archive.create TAR preserves a path longer than ustar name fields",
            long_tar_list and long_tar_list.entries[2]
            and long_tar_list.entries[2].name == long_tar_component .. "/x.txt")
        local long_tar_out = root .. "/long-tar-out"
        local long_tar_extract = babet.archive.extract(long_tar, long_tar_out)
        ok("archive.create TAR long-path archive extracts safely",
            long_tar_extract ~= nil
            and read_bytes(long_tar_out .. "/" .. long_tar_component .. "/x.txt")
                == "pax-long-name")

        local tar_worker_code = [[
    local result, err = babet.archive.create(
        worker.args.source, worker.args.destination, { format = "tar" })
    if not result then error(err) end
    return result.format
    ]]
        local tar_worker_a = babet.workers.spawn(tar_worker_code, {
            source = create_source, destination = root .. "/worker-a.tar",
        })
        local tar_worker_b = babet.workers.spawn(tar_worker_code, {
            source = create_source, destination = root .. "/worker-b.tar",
        })
        ok("archive.create TAR starts safely in concurrent workers",
            tar_worker_a ~= nil and tar_worker_b ~= nil)
        local tar_worker_a_ok, tar_worker_a_format = false, nil
        local tar_worker_b_ok, tar_worker_b_format = false, nil
        if tar_worker_a and tar_worker_b then
            tar_worker_a_ok, tar_worker_a_format = tar_worker_a:join()
            tar_worker_b_ok, tar_worker_b_format = tar_worker_b:join()
        end
        ok("archive.create TAR succeeds concurrently in worker states",
            tar_worker_a_ok == true and tar_worker_a_format == "tar"
            and tar_worker_b_ok == true and tar_worker_b_format == "tar")
        ok("concurrent deterministic TAR outputs are identical",
            read_bytes(root .. "/worker-a.tar")
                == read_bytes(root .. "/worker-b.tar"))
    end

    local deterministic_a = root .. "/deterministic-a.zip"
    local deterministic_b = root .. "/deterministic-b.zip"
    local da, da_err = babet.archive.create(create_source, deterministic_a)
    local db, db_err = babet.archive.create(create_source, deterministic_b)
    ok_val("archive.create deterministic fixture A", da, da_err)
    ok_val("archive.create deterministic fixture B", db, db_err)
    ok("archive.create is byte-for-byte deterministic by default",
        read_bytes(deterministic_a) == read_bytes(deterministic_b))
    local timestamp_source = root .. "/timestamp-source"
    assert(babet.mkdir(timestamp_source))
    assert(write_bytes(timestamp_source .. "/stamp.txt", "timestamp"))
    local timestamp_set = babet.exec("touch", {
        "-m", "-t", "200102030405.06", timestamp_source .. "/stamp.txt",
    })
    ok("archive.create source timestamp fixture created",
        type(timestamp_set) == "table" and timestamp_set.code == 0,
        timestamp_set and timestamp_set.stderr)
    local nondeterministic_zip = root .. "/nondeterministic.zip"
    local nondeterministic, nondeterministic_err = babet.archive.create(
        timestamp_source, nondeterministic_zip, { deterministic = false })
    ok_val("archive.create accepts deterministic=false",
        nondeterministic, nondeterministic_err,
        function(value) return value.deterministic == false end)
    local nondeterministic_raw = read_bytes(nondeterministic_zip)
    local nd_time_lo, nd_time_hi, nd_date_lo, nd_date_hi
    if nondeterministic_raw then
        nd_time_lo, nd_time_hi, nd_date_lo, nd_date_hi =
            string.byte(nondeterministic_raw, 11, 14)
    end
    ok("archive.create deterministic=false stores the exact source timestamp",
        nd_time_lo == 0xA3 and nd_time_hi == 0x20
        and nd_date_lo == 0x43 and nd_date_hi == 0x2A,
        string.format("%s,%s,%s,%s", tostring(nd_time_lo),
            tostring(nd_time_hi), tostring(nd_date_lo), tostring(nd_date_hi)))

    local old_timestamp_source = root .. "/old-timestamp-source"
    assert(babet.mkdir(old_timestamp_source))
    assert(write_bytes(old_timestamp_source .. "/old.txt", "old"))
    local old_timestamp_set = babet.exec("touch", {
        "-m", "-t", "197001010000.00", old_timestamp_source .. "/old.txt",
    })
    ok("archive.create pre-1980 timestamp fixture created",
        type(old_timestamp_set) == "table" and old_timestamp_set.code == 0,
        old_timestamp_set and old_timestamp_set.stderr)
    local old_timestamp_zip = root .. "/old-timestamp.zip"
    local old_timestamp, old_timestamp_err = babet.archive.create(
        old_timestamp_source, old_timestamp_zip, { deterministic = false })
    ok_fail("archive.create rejects source timestamps outside the ZIP range",
        old_timestamp, old_timestamp_err)
    ok("archive.create timestamp-range failure leaves no output",
        babet.fileExists(old_timestamp_zip) == false)
    local old_deterministic, old_deterministic_err = babet.archive.create(
        old_timestamp_source, root .. "/old-deterministic.zip")
    ok_val("archive.create deterministic mode ignores unrepresentable source times",
        old_deterministic, old_deterministic_err)

    local stored_zip = root .. "/stored.zip"
    local stored, stored_err = babet.archive.create(create_source, stored_zip, {
        compression_level = 0,
        include_directories = false,
    })
    ok_val("archive.create accepts compression_level=0",
        stored, stored_err, function(value)
            return value.compression_level == 0 and value.directories == 0
        end)
    local stored_list, stored_list_err = babet.archive.list(stored_zip)
    ok_val("archive.create stored archive is readable", stored_list, stored_list_err)
    ok("archive.create compression_level=0 stores files",
        stored_list and stored_list.entries[3].compression_method == 0,
        tostring(stored_list and stored_list.entries[3].compression_method))
    ok("archive.create include_directories=false omits directory entries",
        stored_list and stored_list.count == 3
        and stored_list.entries[1].name == "alpha.txt"
        and stored_list.entries[2].name == "nested/binary.bin"
        and stored_list.entries[3].name == "nested/repeated.txt")
    local implicit_out = root .. "/implicit-directories"
    local implicit, implicit_err = babet.archive.extract(stored_zip, implicit_out)
    ok_val("archive without directory entries still extracts", implicit, implicit_err)
    ok("implicit directories are created during extraction",
        read_bytes(implicit_out .. "/nested/binary.bin") == "A\0B\255C")

    assert(write_bytes(root .. "/overwrite.zip", "sentinel"))
    local refused_create, refused_create_err = babet.archive.create(
        create_source, root .. "/overwrite.zip")
    ok_fail("archive.create refuses overwrite by default",
        refused_create, refused_create_err)
    ok("archive.create refusal preserves existing destination",
        read_bytes(root .. "/overwrite.zip") == "sentinel")
    local overwritten, overwritten_err = babet.archive.create(
        create_source, root .. "/overwrite.zip", { overwrite = true })
    ok_val("archive.create overwrite=true replaces atomically",
        overwritten, overwritten_err)
    ok("archive.create overwrite result is a valid ZIP",
        type(babet.archive.list(root .. "/overwrite.zip")) == "table")

    local empty_source = root .. "/empty-source"
    assert(babet.mkdir(empty_source))
    local empty_created, empty_created_err = babet.archive.create(
        empty_source, root .. "/empty-created.zip")
    ok_val("archive.create supports an empty source directory",
        empty_created, empty_created_err,
        function(value) return value.files == 0 and value.directories == 0 end)
    local empty_created_list = babet.archive.list(root .. "/empty-created.zip")
    ok("archive.create empty source produces an empty ZIP",
        type(empty_created_list) == "table" and empty_created_list.count == 0)

    local inside, inside_err = babet.archive.create(
        create_source, create_source .. "/inside.zip")
    ok_fail("archive.create refuses an output inside the source",
        inside, inside_err)
    ok("archive.create inside-source refusal leaves no output",
        babet.fileExists(create_source .. "/inside.zip") == false)

    local source_link = root .. "/create-source-link"
    local make_source_link = babet.exec("ln", { "-s", "create-source", source_link })
    ok("archive.create source symlink fixture created",
        type(make_source_link) == "table" and make_source_link.code == 0)
    local linked_source, linked_source_err = babet.archive.create(
        source_link, root .. "/linked-source.zip")
    ok_fail("archive.create refuses a symlink source root",
        linked_source, linked_source_err)

    local entry_link = babet.exec("ln", {
        "-s", "alpha.txt", create_source .. "/entry-link",
    })
    ok("archive.create source-entry symlink fixture created",
        type(entry_link) == "table" and entry_link.code == 0)
    local linked_entry, linked_entry_err = babet.archive.create(
        create_source, root .. "/linked-entry.zip")
    ok_fail("archive.create refuses symlink entries",
        linked_entry, linked_entry_err)
    babet.remove(create_source .. "/entry-link")

    local fifo_created = babet.exec("mkfifo", { create_source .. "/pipe" })
    ok("archive.create FIFO fixture created",
        type(fifo_created) == "table" and fifo_created.code == 0)
    local fifo_archive, fifo_archive_err = babet.archive.create(
        create_source, root .. "/fifo.zip")
    ok_fail("archive.create refuses unsupported filesystem types",
        fifo_archive, fifo_archive_err)
    babet.exec("rm", { "-f", create_source .. "/pipe" })

    assert(write_bytes(create_source .. "/unsafe\\name", "bad"))
    local unsafe_name, unsafe_name_err = babet.archive.create(
        create_source, root .. "/unsafe-name.zip")
    ok_fail("archive.create refuses backslashes in source entry names",
        unsafe_name, unsafe_name_err)
    babet.remove(create_source .. "/unsafe\\name")
    assert(write_bytes(create_source .. "/C:drive", "bad"))
    local drive_name, drive_name_err = babet.archive.create(
        create_source, root .. "/drive-name.zip")
    ok_fail("archive.create refuses drive-prefixed source entry names",
        drive_name, drive_name_err)
    babet.remove(create_source .. "/C:drive")

    local unicode_source = root .. "/unicode-create-source"
    assert(babet.mkdir(unicode_source))
    local unicode_name = "café-雪.txt"
    assert(write_bytes(unicode_source .. "/" .. unicode_name, "unicode"))
    local unicode_zip = root .. "/unicode-create.zip"
    local unicode_created, unicode_created_err = babet.archive.create(
        unicode_source, unicode_zip)
    ok_val("archive.create accepts valid UTF-8 source entry names",
        unicode_created, unicode_created_err)
    local unicode_list, unicode_list_err = babet.archive.list(unicode_zip)
    ok_val("archive.create preserves valid UTF-8 entry names",
        unicode_list, unicode_list_err,
        function(value)
            return value.count == 1 and value.entries[1].name == unicode_name
        end)

    local invalid_utf8_name = "invalid-\255.txt"
    assert(write_bytes(create_source .. "/" .. invalid_utf8_name, "bad"))
    local invalid_utf8_zip = root .. "/invalid-utf8-create.zip"
    local invalid_utf8, invalid_utf8_err = babet.archive.create(
        create_source, invalid_utf8_zip)
    ok_fail("archive.create refuses invalid UTF-8 source entry names",
        invalid_utf8, invalid_utf8_err)
    ok("archive.create invalid UTF-8 diagnostic is explicit",
        type(invalid_utf8_err) == "string"
        and invalid_utf8_err:find("UTF%-8") ~= nil,
        tostring(invalid_utf8_err))
    ok("archive.create invalid UTF-8 failure leaves no output",
        babet.fileExists(invalid_utf8_zip) == false)
    babet.remove(create_source .. "/" .. invalid_utf8_name)

    local deep_source = root .. "/deep-create-source"
    local deep_leaf = deep_source .. string.rep("/d", 257)
    assert(babet.mkdir(deep_leaf))
    local deep_create, deep_create_err = babet.archive.create(
        deep_source, root .. "/deep-create.zip")
    ok_fail("archive.create enforces its internal source-depth limit",
        deep_create, deep_create_err)

    local destination_target = root .. "/destination-target.zip"
    assert(write_bytes(destination_target, "outside"))
    local destination_link = root .. "/destination-link.zip"
    local make_destination_link = babet.exec("ln", {
        "-s", "destination-target.zip", destination_link,
    })
    ok("archive.create destination symlink fixture created",
        type(make_destination_link) == "table" and make_destination_link.code == 0)
    local symlink_destination, symlink_destination_err = babet.archive.create(
        create_source, destination_link, { overwrite = true })
    ok_fail("archive.create refuses a destination symlink",
        symlink_destination, symlink_destination_err)
    ok("archive.create never writes through destination symlinks",
        read_bytes(destination_target) == "outside")

    local parent_target = root .. "/parent-target"
    assert(babet.mkdir(parent_target))
    local parent_link = root .. "/parent-link"
    local make_parent_link = babet.exec("ln", { "-s", "parent-target", parent_link })
    ok("archive.create destination-parent symlink fixture created",
        type(make_parent_link) == "table" and make_parent_link.code == 0)
    local parent_attack, parent_attack_err = babet.archive.create(
        create_source, parent_link .. "/attack.zip")
    ok_fail("archive.create refuses symlinked destination parents",
        parent_attack, parent_attack_err)
    ok("archive.create symlink-parent refusal writes nothing outside",
        babet.fileExists(parent_target .. "/attack.zip") == false)

    local missing_parent, missing_parent_err = babet.archive.create(
        create_source, root .. "/missing-parent/out.zip")
    ok_fail("archive.create requires an existing destination parent",
        missing_parent, missing_parent_err)
    local dotdot_destination, dotdot_destination_err = babet.archive.create(
        create_source, root .. "/sub/../dotdot.zip")
    ok_fail("archive.create rejects '..' in destination parents",
        dotdot_destination, dotdot_destination_err)
    local dotdot_source, dotdot_source_err = babet.archive.create(
        root .. "/other/../create-source", root .. "/dotdot-source.zip")
    ok_fail("archive.create rejects '..' in source paths",
        dotdot_source, dotdot_source_err)
    assert(babet.mkdir(root .. "/destination-directory"))
    local directory_destination, directory_destination_err = babet.archive.create(
        create_source, root .. "/destination-directory", { overwrite = true })
    ok_fail("archive.create refuses a directory destination",
        directory_destination, directory_destination_err)

    local limit, limit_err = babet.archive.create(
        create_source, root .. "/limit-entry.zip", { max_file_size = 4 })
    ok_fail("archive.create enforces max_file_size before writing", limit, limit_err)
    ok("archive.create max_file_size failure leaves no output",
        babet.fileExists(root .. "/limit-entry.zip") == false)
    limit, limit_err = babet.archive.create(
        create_source, root .. "/limit-total.zip", { max_total_size = 5 })
    ok_fail("archive.create enforces max_total_size before writing", limit, limit_err)
    limit, limit_err = babet.archive.create(
        create_source, root .. "/limit-count.zip", { max_entries = 2 })
    ok_fail("archive.create enforces max_entries before writing", limit, limit_err)
    local exact_create_limits, exact_create_limits_err = babet.archive.create(
        create_source, root .. "/exact-create-limits.zip", {
            max_entries = 5,
            max_file_size = #(string.rep("compress-me-", 2048)),
            max_total_size = 6 + 5 + #(string.rep("compress-me-", 2048)),
        })
    ok_val("archive.create size and entry limits are inclusive at the boundary",
        exact_create_limits, exact_create_limits_err)

    local long_destination_name = string.rep("z", 240) .. ".zip"
    local long_destination = root .. "/" .. long_destination_name
    local long_created, long_created_err = babet.archive.create(
        create_source, long_destination)
    ok_val("archive.create supports a valid near-NAME_MAX destination name",
        long_created, long_created_err)
    ok("archive.create near-NAME_MAX output is readable",
        babet.archive.list(long_destination) ~= nil)

    local create_temp_check = babet.exec("find", {
        root, "-maxdepth", "1", "-name", ".babet-create-*", "-print",
    }, { timeout = 5 })
    ok("archive.create leaves no temporary files after success or failure",
        type(create_temp_check) == "table" and create_temp_check.code == 0
        and create_temp_check.stdout == "",
        tostring(create_temp_check and create_temp_check.stdout))

    local nil_options_zip = root .. "/nil-options.zip"
    local nil_options_result = table.pack(
        babet.archive.create(create_source, nil_options_zip, nil))
    ok("archive.create accepts explicit nil options and returns exactly two values",
        nil_options_result.n == 2 and type(nil_options_result[1]) == "table"
        and nil_options_result[2] == nil)
    local list_return_contract = table.pack(babet.archive.list(nil_options_zip, nil))
    ok("archive.list accepts explicit nil options and returns exactly two values",
        list_return_contract.n == 2 and type(list_return_contract[1]) == "table"
        and list_return_contract[2] == nil)

    local create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", "bad")
    ok_fail("archive.create opts must be a table", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { unknown = true })
    ok_fail("archive.create rejects unknown options", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { [1] = true })
    ok_fail("archive.create option keys must be strings", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { format = 42 })
    ok_fail("archive.create format is a strict string",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { format = "rar" })
    ok_fail("archive.create rejects an unknown format",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { format = "tar\0zip" })
    ok_fail("archive.create rejects NUL in format",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { compression_level = 1.0 })
    ok_fail("archive.create compression_level is a strict integer",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { compression_level = -1 })
    ok_fail("archive.create rejects negative compression levels",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { compression_level = 10 })
    ok_fail("archive.create rejects compression levels above 9",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { overwrite = 1 })
    ok_fail("archive.create overwrite is strictly boolean",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { deterministic = 1 })
    ok_fail("archive.create deterministic is strictly boolean",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { include_directories = 1 })
    ok_fail("archive.create include_directories is strictly boolean",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { max_file_size = 1.0 })
    ok_fail("archive.create size limits require strict integers",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { max_file_size = 0 })
    ok_fail("archive.create limits reject zero", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { max_entries = 100001 })
    ok_fail("archive.create max_entries hard ceiling enforced",
        create_bad, create_bad_err)

    ok_raises("archive.create enforces arity",
        function() return babet.archive.create(create_source) end,
        "expects 2 or 3 arguments")
    ok_raises("archive.create rejects excess arguments",
        function()
            return babet.archive.create(create_source, root .. "/x.zip", nil, true)
        end,
        "expects 2 or 3 arguments")
    ok_raises("archive.create source is a strict string",
        function() return babet.archive.create({}, root .. "/x.zip") end)
    ok_raises("archive.create destination is a strict string",
        function() return babet.archive.create(create_source, {}) end)
    ok_raises("archive.create rejects NUL in source",
        function()
            return babet.archive.create(create_source .. "\0ignored", root .. "/x.zip")
        end,
        "NUL")
    ok_raises("archive.create rejects NUL in destination",
        function()
            return babet.archive.create(create_source, root .. "/x.zip\0ignored")
        end,
        "NUL")
    local empty_source_arg, empty_source_arg_err = babet.archive.create(
        "", root .. "/empty-source-arg.zip")
    ok_fail("archive.create rejects an empty source path",
        empty_source_arg, empty_source_arg_err)
    local empty_destination_arg, empty_destination_arg_err = babet.archive.create(
        create_source, "")
    ok_fail("archive.create rejects an empty destination path",
        empty_destination_arg, empty_destination_arg_err)
    local missing_source, missing_source_err = babet.archive.create(
        root .. "/missing-source", root .. "/missing-source.zip")
    ok_fail("archive.create rejects a missing source directory",
        missing_source, missing_source_err)
    local file_source, file_source_err = babet.archive.create(
        create_source .. "/alpha.txt", root .. "/file-source.zip")
    ok_fail("archive.create rejects a regular-file source",
        file_source, file_source_err)
    end)()

    babet.rmdirAll(root)
end

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
        ok("LOT 3 ZIP limit: main.lua created", main_ok == true, main_err)

        local huge_ok, huge_err = write_oversized_module(project .. "/huge.lua")
        ok("LOT 3 ZIP limit: oversized module created",
            huge_ok == true, huge_err)

        if not current_exe or current_exe == "" then
            ok("LOT 3 ZIP limit: current executable resolved", false,
                "readlink failed")
        else
            local built = babet.exec(current_exe, {
                "--create-exe", project, output,
            }, { timeout = 60 })
            ok("LOT 3 ZIP limit: executable built",
                type(built) == "table" and built.code == 0,
                "code=" .. tostring(built and built.code)
                .. " stderr=" .. tostring(built and built.stderr))

            local launched = babet.exec(output, {}, { timeout = 15 })
            ok("LOT 3 ZIP limit: oversized embedded module rejected",
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
