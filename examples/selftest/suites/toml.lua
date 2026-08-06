return function(test, context)
    local _ENV = test:environment(context)
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
end
