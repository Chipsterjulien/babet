return function(test, context)
    local _ENV = test:environment(context)
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
end
