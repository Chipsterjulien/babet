return function(test, context)
    local _ENV = test:environment(context)
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

    local join_len_called = false
    local raw_segments = setmetatable({ "a", "b", "c" }, {
        __len = function()
            join_len_called = true
            error("joinPath must not invoke __len")
        end,
        __index = function()
            error("joinPath must not invoke __index for stored segments")
        end,
    })
    local raw_call_ok, raw_joined, raw_joined_err =
        pcall(babet.joinPath, raw_segments)
    ok("joinPath table form ignores __len/__index metamethods",
        raw_call_ok and raw_joined == "a/b/c" and raw_joined_err == nil
        and join_len_called == false)

    local join_index_called = false
    local sparse_segments = setmetatable({ [1] = "a" }, {
        __len = function() return 2 end,
        __index = function(_, key)
            join_index_called = true
            return key == 2 and "b" or nil
        end,
    })
    local sparse_joined, sparse_joined_err = babet.joinPath(sparse_segments)
    ok("joinPath rejects sparse tables without invoking __index",
        sparse_joined == nil and type(sparse_joined_err) == "string"
        and join_index_called == false)

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
print("=== base64 ===")

do
    local B = babet.base64

    ok("babet.base64 is a table", type(B) == "table")
    ok("babet.base64.encode is a function", type(B.encode) == "function")
    ok("babet.base64.decode is a function", type(B.decode) == "function")

    -- Vecteurs canoniques RFC 4648.
    local vectors = {
        { "", "" },
        { "f", "Zg==" },
        { "fo", "Zm8=" },
        { "foo", "Zm9v" },
        { "foob", "Zm9vYg==" },
        { "fooba", "Zm9vYmE=" },
        { "foobar", "Zm9vYmFy" },
    }
    for _, vector in ipairs(vectors) do
        local encoded, encode_err = B.encode(vector[1])
        ok("base64 RFC 4648 encode " .. string.format("%q", vector[1]),
            encoded == vector[2] and encode_err == nil,
            "encoded=" .. tostring(encoded) .. " err=" .. tostring(encode_err))

        local decoded, decode_err = B.decode(vector[2])
        ok("base64 RFC 4648 decode " .. string.format("%q", vector[2]),
            decoded == vector[1] and decode_err == nil,
            "decoded=" .. tostring(decoded) .. " err=" .. tostring(decode_err))
    end

    -- Chaînes Lua binaires : tous les octets, NUL inclus.
    local bytes = {}
    for value = 0, 255 do
        bytes[#bytes + 1] = string.char(value)
    end
    local binary = table.concat(bytes)
    local encoded, err = B.encode(binary)
    local decoded, decode_err = B.decode(encoded)
    ok("base64 round-trip preserves all 256 byte values",
        err == nil and decode_err == nil and decoded == binary,
        "encode_err=" .. tostring(err) .. " decode_err=" .. tostring(decode_err))

    local large_binary = string.rep("\0\255abc", 200000)
    encoded, err = B.encode(large_binary)
    decoded, decode_err = B.decode(encoded, {
        max_output = #large_binary,
    })
    ok("base64 round-trip preserves a large binary buffer",
        err == nil and decode_err == nil and decoded == large_binary,
        "size=" .. tostring(#large_binary)
        .. " encode_err=" .. tostring(err)
        .. " decode_err=" .. tostring(decode_err))

    encoded, err = B.encode("\0\1\2abc\255")
    decoded, decode_err = B.decode(encoded)
    ok("base64 strings are binary-safe including embedded NUL",
        err == nil and decode_err == nil and decoded == "\0\1\2abc\255")

    -- Alphabet URL-safe et padding optionnel.
    encoded, err = B.encode("\251\255", { url_safe = true })
    ok("base64 URL-safe alphabet uses '-' and '_'",
        encoded == "-_8=" and err == nil, tostring(encoded))

    decoded, decode_err = B.decode("-_8=", { url_safe = true })
    ok("base64 URL-safe decode", decoded == "\251\255" and decode_err == nil,
        tostring(decode_err))

    encoded, err = B.encode("hello", { padding = false })
    ok("base64 encode without padding", encoded == "aGVsbG8" and err == nil,
        tostring(encoded))

    decoded, decode_err = B.decode("aGVsbG8")
    ok_fail("base64 unpadded tail is rejected by default",
        decoded, decode_err)

    decoded, decode_err = B.decode("aGVsbG8", { allow_unpadded = true })
    ok("base64 allow_unpadded accepts a canonical tail",
        decoded == "hello" and decode_err == nil, tostring(decode_err))

    encoded, err = B.encode("\251\255", {
        url_safe = true,
        padding = false,
    })
    decoded, decode_err = B.decode(encoded, {
        url_safe = true,
        allow_unpadded = true,
    })
    ok("base64 combined URL-safe and unpadded round-trip",
        encoded == "-_8" and err == nil
        and decoded == "\251\255" and decode_err == nil,
        "encoded=" .. tostring(encoded) .. " err=" .. tostring(decode_err))

    -- Espaces ASCII : stricts par défaut, option explicite pour les ignorer.
    decoded, decode_err = B.decode("Zm9v\nYmFy")
    ok_fail("base64 whitespace is rejected by default", decoded, decode_err)
    ok("base64 invalid-character error reports the original byte",
        type(decode_err) == "string"
        and decode_err:find("byte 5", 1, true) ~= nil,
        tostring(decode_err))

    decoded, decode_err = B.decode(" Zm9v\tYmFy\r\n", {
        ignore_whitespace = true,
    })
    ok("base64 ignore_whitespace accepts ASCII whitespace",
        decoded == "foobar" and decode_err == nil, tostring(decode_err))

    decoded, decode_err = B.decode(" Z g = = ", {
        ignore_whitespace = true,
    })
    ok("base64 ignore_whitespace also works around padding",
        decoded == "f" and decode_err == nil, tostring(decode_err))

    -- Les alphabets standard et URL-safe restent distincts.
    decoded, decode_err = B.decode("-_8=")
    ok_fail("base64 standard mode rejects URL-safe characters",
        decoded, decode_err)
    decoded, decode_err = B.decode("+/8=", { url_safe = true })
    ok_fail("base64 URL-safe mode rejects standard '+' and '/'",
        decoded, decode_err)

    -- Padding, troncature et bits inutilisés : décodage canonique strict.
    for _, invalid in ipairs({
        "=", "A===", "AA=A", "A=AA", "Zg=", "Zg===", "Z===",
    }) do
        decoded, decode_err = B.decode(invalid)
        ok_fail("base64 rejects invalid padding " .. string.format("%q", invalid),
            decoded, decode_err)
    end

    decoded, decode_err = B.decode("A", { allow_unpadded = true })
    ok_fail("base64 rejects a one-symbol truncated quantum",
        decoded, decode_err)

    decoded, decode_err = B.decode("Zh==")
    ok_fail("base64 rejects non-zero trailing bits with two '='",
        decoded, decode_err)

    decoded, decode_err = B.decode("Zm9=")
    ok_fail("base64 rejects non-zero trailing bits with one '='",
        decoded, decode_err)

    decoded, decode_err = B.decode("Zh", { allow_unpadded = true })
    ok_fail("base64 rejects non-zero trailing bits without padding",
        decoded, decode_err)

    decoded, decode_err = B.decode("%%%")
    ok_fail("base64 rejects invalid characters", decoded, decode_err)
    ok("base64 invalid-character error includes its byte offset",
        type(decode_err) == "string"
        and decode_err:find("byte 1", 1, true) ~= nil,
        tostring(decode_err))

    -- Limite de sortie calculée avant l'allocation du résultat décodé.
    decoded, decode_err = B.decode("Zm9v", { max_output = 2 })
    ok_fail("base64 max_output rejects output above the limit",
        decoded, decode_err)
    ok("base64 max_output has a stable reason",
        decode_err == "base64: decoded output exceeds max_output",
        tostring(decode_err))

    decoded, decode_err = B.decode("Zm9v", { max_output = 3 })
    ok("base64 max_output accepts output exactly at the limit",
        decoded == "foo" and decode_err == nil, tostring(decode_err))

    decoded, decode_err = B.decode("Zm9v", { max_output = 4 })
    ok("base64 max_output accepts output just below the limit",
        decoded == "foo" and decode_err == nil, tostring(decode_err))

    decoded, decode_err = B.decode("Zm9v", {
        max_output = math.maxinteger,
    })
    ok("base64 max_output accepts math.maxinteger without narrowing",
        decoded == "foo" and decode_err == nil, tostring(decode_err))

    decoded, decode_err = B.decode("", { max_output = 0 })
    ok("base64 max_output=0 accepts empty output",
        decoded == "" and decode_err == nil, tostring(decode_err))

    -- Validation stricte : erreurs de programmation levées côté Lua.
    ok_raises("base64 encode requires an argument",
        function() B.encode() end, "expects one or two arguments")
    ok_raises("base64 encode rejects extra arguments",
        function() B.encode("x", nil, true) end, "expects one or two arguments")
    ok_raises("base64 encode data must be a strict string",
        function() B.encode(42) end, "string expected")
    ok_raises("base64 encode opts must be a table",
        function() B.encode("x", true) end, "table expected")
    ok_raises("base64 encode url_safe must be a boolean",
        function() B.encode("x", { url_safe = 1 }) end, "boolean")
    ok_raises("base64 encode padding must be a boolean",
        function() B.encode("x", { padding = "no" }) end, "boolean")
    ok_raises("base64 encode rejects unknown options",
        function() B.encode("x", { unknown = true }) end, "unknown")
    ok_raises("base64 encode rejects non-string option keys",
        function() B.encode("x", { [1] = true }) end, "keys")
    ok("base64 encode accepts an explicit nil options argument",
        B.encode("x", nil) == "eA==")

    ok_raises("base64 decode requires an argument",
        function() B.decode() end, "expects one or two arguments")
    ok_raises("base64 decode rejects extra arguments",
        function() B.decode("", nil, true) end, "expects one or two arguments")
    ok_raises("base64 decode text must be a strict string",
        function() B.decode(42) end, "string expected")
    ok_raises("base64 decode opts must be a table",
        function() B.decode("", true) end, "table expected")
    ok_raises("base64 decode url_safe must be a boolean",
        function() B.decode("", { url_safe = 1 }) end, "boolean")
    ok_raises("base64 decode allow_unpadded must be a boolean",
        function() B.decode("", { allow_unpadded = 1 }) end, "boolean")
    ok_raises("base64 decode ignore_whitespace must be a boolean",
        function() B.decode("", { ignore_whitespace = "yes" }) end,
        "boolean")
    ok_raises("base64 decode max_output must be an integer",
        function() B.decode("", { max_output = 1.5 }) end, "integer")
    ok_raises("base64 decode max_output must be non-negative",
        function() B.decode("", { max_output = -1 }) end, "non-negative")
    ok_raises("base64 decode rejects unknown options",
        function() B.decode("", { unknown = true }) end, "unknown")
    ok_raises("base64 decode rejects non-string option keys",
        function() B.decode("", { [1] = true }) end, "keys")
    ok("base64 decode accepts an explicit nil options argument",
        B.decode("eA==", nil) == "x")
end

end
