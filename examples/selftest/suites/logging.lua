return function(test, context)
    local _ENV = test:environment(context)
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
end
