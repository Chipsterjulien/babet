return function(test, context)
    local _ENV = test:environment(context)
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
end
