-- logging.lua — logger à niveaux en Lua pur, bundlé dans Babet via
-- tools/embed_lua_module.sh et chargé avec require("logging").
--
-- Contrat observable :
--
--   local log = require("logging")
--   log.info("user=", uid, "status=", status)
--   log.set_level("debug")                  -- ou log.DEBUG
--   log.set_output(io.open("app.log", "a")) -- objet avec :write()
--   log.set_color(true)                     -- ANSI opt-in
--
--   * Niveaux : trace=10, debug=20, info=30, warn=40, error=50.
--     Le seuil par défaut est info. Un message est émis lorsque son
--     niveau est >= au seuil courant.
--
--   * Destination par défaut : io.stderr. set_output accepte une table
--     ou un userdata dont le membre `write` est une fonction. Le module
--     ne ferme et ne flush jamais la destination.
--
--   * Format v1 :
--       "YYYY-MM-DD HH:MM:SS [LEVEL] message\n"
--     L'horodatage utilise l'heure locale de os.date. Les labels sont
--     paddés à cinq caractères : [TRACE] [DEBUG] [INFO ] [WARN ]
--     [ERROR].
--
--   * Couleurs ANSI (set_color(true)) : trace dim, debug cyan, info
--     sans couleur, warn jaune, error rouge. OFF par défaut ; aucune
--     détection automatique de terminal.
--
--   * Contrat d'erreur :
--       - Les setters/getters lèvent sur mauvaise arité ou valeur
--         invalide.
--       - trace/debug/info/warn/error ne lèvent jamais et ne renvoient
--         aucune valeur. La conversion tostring, l'horodatage et
--         l'écriture sont tous protégés ; un échec perd le message.
--
-- L'état est partagé par tous les require("logging") d'un même état
-- Lua. Chaque worker Babet possède son propre état Lua et donc son
-- propre seuil, sink et réglage de couleur.

local logging = {
    _VERSION = "babet logging 1.1.0",
    _DESCRIPTION = "leveled logger (pure Lua, bundled)",
}

logging.TRACE = 10
logging.DEBUG = 20
logging.INFO  = 30
logging.WARN  = 40
logging.ERROR = 50

local LEVEL_BY_NAME = {
    trace = logging.TRACE,
    debug = logging.DEBUG,
    info  = logging.INFO,
    warn  = logging.WARN,
    error = logging.ERROR,
}

local LABEL = {
    [logging.TRACE] = "TRACE",
    [logging.DEBUG] = "DEBUG",
    [logging.INFO]  = "INFO ",
    [logging.WARN]  = "WARN ",
    [logging.ERROR] = "ERROR",
}

local COLOR_ON = {
    [logging.TRACE] = "\27[2m",
    [logging.DEBUG] = "\27[36m",
    [logging.INFO]  = "",
    [logging.WARN]  = "\27[33m",
    [logging.ERROR] = "\27[31m",
}
local COLOR_RESET = "\27[0m"

local current_level  = logging.INFO
local current_output = io.stderr
local color_enabled  = false

-- --- helpers internes ------------------------------------------------

local function check_exact_args(name, expected, ...)
    local got = select("#", ...)
    if got ~= expected then
        local suffix = expected == 1 and "" or "s"
        error("logging: " .. name .. " expects exactly "
            .. tostring(expected) .. " argument" .. suffix
            .. ", got " .. tostring(got), 3)
    end
end

local function normalize_level(lvl)
    local t = type(lvl)
    if t == "number" then
        if lvl ~= lvl or lvl == math.huge or lvl == -math.huge then
            return nil, "logging: numeric level must be finite"
        end
        -- Les seuils intermédiaires restent autorisés (ex. 25.5).
        return lvl, nil
    end
    if t == "string" then
        local n = LEVEL_BY_NAME[lvl:lower()]
        if n then
            return n, nil
        end
        return nil, "logging: unknown level name '" .. lvl .. "'"
    end
    return nil, "logging: level must be a number or string, got " .. t
end

local function has_write_method(out)
    local ok, writer = pcall(function()
        return out.write
    end)
    return ok and type(writer) == "function"
end

local function format_message(...)
    local n = select("#", ...)
    if n == 0 then
        return ""
    end

    local parts = {}
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    return table.concat(parts, " ")
end

local function emit(level, msg)
    local prefix = os.date("%Y-%m-%d %H:%M:%S") .. " ["
        .. LABEL[level] .. "] "
    local line

    if color_enabled then
        local color = COLOR_ON[level]
        if color and color ~= "" then
            line = color .. prefix .. msg .. COLOR_RESET .. "\n"
        else
            line = prefix .. msg .. "\n"
        end
    else
        line = prefix .. msg .. "\n"
    end

    current_output:write(line)
end

local function make_log_fn(level)
    return function(...)
        if level < current_level then
            return
        end

        -- Tout le pipeline est protégé : un __tostring défaillant, un
        -- os.date remplacé ou un sink cassé ne doit jamais transformer
        -- un log raté en erreur métier.
        pcall(function(...)
            emit(level, format_message(...))
        end, ...)
    end
end

-- --- API publique ----------------------------------------------------

logging.trace = make_log_fn(logging.TRACE)
logging.debug = make_log_fn(logging.DEBUG)
logging.info  = make_log_fn(logging.INFO)
logging.warn  = make_log_fn(logging.WARN)
logging.error = make_log_fn(logging.ERROR)

function logging.set_level(...)
    check_exact_args("set_level", 1, ...)
    local lvl = ...
    local normalized, err = normalize_level(lvl)
    if normalized == nil then
        error(err, 2)
    end
    current_level = normalized
end

function logging.set_output(...)
    check_exact_args("set_output", 1, ...)
    local out = ...
    local t = type(out)
    if t ~= "table" and t ~= "userdata" then
        error("logging: output must be a writable object (table or "
            .. "userdata with :write), got " .. t, 2)
    end
    if not has_write_method(out) then
        error("logging: output must expose a callable :write method", 2)
    end
    current_output = out
end

function logging.set_color(...)
    check_exact_args("set_color", 1, ...)
    local on = ...
    if type(on) ~= "boolean" then
        error("logging: set_color expects a boolean, got "
            .. type(on), 2)
    end
    color_enabled = on
end

function logging.get_level(...)
    check_exact_args("get_level", 0, ...)
    return current_level
end

function logging.get_output(...)
    check_exact_args("get_output", 0, ...)
    return current_output
end

function logging.get_color(...)
    check_exact_args("get_color", 0, ...)
    return color_enabled
end

return logging
