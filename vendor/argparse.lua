-- argparse.lua — analyseur d'arguments en ligne de commande, Lua pur,
-- bundlé dans Babet via tools/embed_lua_module.sh (require("argparse")).
--
-- Contrat observable :
--
--   local argparse = require("argparse")
--   local p = argparse("prog", "description")
--   p:flag("-v --verbose", { help = "..." })
--   p:option("-o --output", { default = "a.out" })
--   p:argument("input", { help = "..." })
--   local res, err = p:parse()
--
--   * parse() lit la table globale `arg` aux indices 1..n par défaut.
--     Les indices <= 0 sont ignorés. p:parse(t) exige un array dense
--     de strings.
--   * Succès    : res = { dest = valeur, ... }, err = nil
--   * -h/--help : res = { help = true, usage = "<texte>" }, err = nil
--   * Échec     : res = nil, err = "message lisible"
--
-- Les erreurs d'entrée utilisateur restent des retours (nil, err).
-- Les erreurs de construction du parseur (spec/options invalides,
-- destination dupliquée, mauvaise arité des méthodes) lèvent error().
--
-- Périmètre v1 : flags booléens, options à valeur, arguments
-- positionnels, required, default, choices, convert. `choices` est
-- testé sur la string brute, puis `convert` est appliqué. Hors v1 :
-- sous-commandes, nargs variadiques, options courtes agglomérées et
-- valeur courte collée (-fvalue).

local argparse = {
  _VERSION = "babet argparse 1.1.0",
  _DESCRIPTION = "command-line argument parser (pure Lua, bundled)",
}

local Parser = {}
Parser.__index = Parser

local RESERVED_DEST = {
  help = true,
  usage = true,
}

local COMMON_OPT_FIELDS = {
  help = true,
  default = true,
  dest = true,
  required = true,
}

local VALUE_OPT_FIELDS = {
  help = true,
  default = true,
  dest = true,
  required = true,
  choices = true,
  convert = true,
}

-- --- helpers internes ------------------------------------------------

local function arg_count_error(label, expected, level)
  error("argparse: " .. label .. " expects " .. expected, level or 3)
end

local function validate_arg_count(label, n, min_count, max_count, level)
  if n < min_count or n > max_count then
    local expected
    if min_count == max_count then
      expected = tostring(min_count) .. " argument"
      if min_count ~= 1 then
        expected = expected .. "s"
      end
    elseif min_count == 0 then
      expected = "at most " .. tostring(max_count) .. " arguments"
    else
      expected = tostring(min_count) .. " or "
          .. tostring(max_count) .. " arguments"
    end
    arg_count_error(label, expected, level or 3)
  end
end

local function safe_tostring(value)
  local ok, result = pcall(tostring, value)
  if ok then
    return result
  end
  return "<unprintable value>"
end

local function split_spec(spec)
  local names = {}
  for token in spec:gmatch("%S+") do
    names[#names + 1] = token
  end
  return names
end

local function is_optional(name)
  return name:sub(1, 1) == "-"
end

local function validate_destination(dest)
  if type(dest) ~= "string" or dest == "" then
    error("argparse: dest must be a non-empty string", 4)
  end
  if RESERVED_DEST[dest] then
    error("argparse: destination '" .. dest
        .. "' is reserved for the built-in help result", 4)
  end
end

local function copy_choices(choices)
  if type(choices) ~= "table" then
    error("argparse: choices must be an array of strings", 4)
  end

  local count = 0
  local max_index = 0
  for key, value in next, choices do
    if type(key) ~= "number" or math.type(key) ~= "integer"
        or key < 1 then
      error("argparse: choices must be a dense array of strings", 4)
    end
    if type(value) ~= "string" then
      error("argparse: every choice must be a string", 4)
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end

  if max_index ~= count then
    error("argparse: choices must be a dense array of strings", 4)
  end

  local result = {}
  for i = 1, max_index do
    result[i] = rawget(choices, i)
  end
  return result
end

local function validate_opts(opts, takes_value)
  if opts == nil then
    return {}
  end
  if type(opts) ~= "table" then
    error("argparse: opts must be a table or nil", 4)
  end

  local allowed = takes_value and VALUE_OPT_FIELDS or COMMON_OPT_FIELDS
  for key in next, opts do
    if type(key) ~= "string" then
      error("argparse: option field names must be strings", 4)
    end
    if not allowed[key] then
      error("argparse: unknown option field '" .. key .. "'", 4)
    end
  end

  local normalized = {
    help = rawget(opts, "help"),
    default = rawget(opts, "default"),
    dest = rawget(opts, "dest"),
    required = rawget(opts, "required"),
    choices = rawget(opts, "choices"),
    convert = rawget(opts, "convert"),
  }

  if normalized.help ~= nil and type(normalized.help) ~= "string" then
    error("argparse: help must be a string", 4)
  end
  if normalized.dest ~= nil then
    validate_destination(normalized.dest)
  end
  if normalized.required ~= nil
      and type(normalized.required) ~= "boolean" then
    error("argparse: required must be a boolean", 4)
  end
  if takes_value and normalized.choices ~= nil then
    normalized.choices = copy_choices(normalized.choices)
  end
  if takes_value and normalized.convert ~= nil
      and type(normalized.convert) ~= "function" then
    error("argparse: convert must be a function", 4)
  end

  return normalized
end

local function validate_option_name(name)
  if name == "-" or name == "--" then
    error("argparse: option name '" .. name .. "' is reserved", 4)
  end
  if name == "-h" or name == "--help" then
    error("argparse: option name '" .. name
        .. "' is reserved for built-in help", 4)
  end
  if name:find("=", 1, true) then
    error("argparse: option names cannot contain '=': " .. name, 4)
  end
  if name:sub(1, 2) == "--" then
    if #name < 3 or name:sub(3, 3) == "-" then
      error("argparse: invalid long option name: " .. name, 4)
    end
  elseif name:sub(1, 1) == "-" then
    if #name < 2 or name:sub(2, 2) == "-" then
      error("argparse: invalid short option name: " .. name, 4)
    end
  else
    error("argparse: option name must start with '-': " .. name, 4)
  end
end

local function derive_dest(names, opts)
  if opts.dest ~= nil then
    return opts.dest
  end
  for _, name in ipairs(names) do
    if name:sub(1, 2) == "--" then
      return name:sub(3)
    end
  end
  return names[1]:sub(2)
end

local function reserve_destination(self, dest)
  validate_destination(dest)
  if self._destinations[dest] then
    error("argparse: duplicate destination: " .. dest, 4)
  end
end

-- --- construction ----------------------------------------------------

local function new_parser(prog, description)
  local self = setmetatable({}, Parser)
  self._prog = prog or "prog"
  self._description = description
  self._options = {}
  self._by_name = {}
  self._positionals = {}
  self._destinations = {}
  self._has_optional_positional = false
  return self
end

function Parser:_add_optional(spec, opts, takes_value)
  if type(spec) ~= "string" then
    error("argparse: option spec must be a string", 3)
  end
  opts = validate_opts(opts, takes_value)

  local names = split_spec(spec)
  if #names == 0 then
    error("argparse: empty option spec", 3)
  end

  local local_names = {}
  for _, name in ipairs(names) do
    validate_option_name(name)
    if local_names[name] then
      error("argparse: duplicate option name in spec: " .. name, 3)
    end
    if self._by_name[name] then
      error("argparse: duplicate option name: " .. name, 3)
    end
    local_names[name] = true
  end

  local dest = derive_dest(names, opts)
  reserve_destination(self, dest)

  local entry = {
    names = names,
    dest = dest,
    takes_value = takes_value,
    help = opts.help,
    default = opts.default,
    required = opts.required == true,
    choices = opts.choices,
    convert = opts.convert,
  }

  -- Mutation seulement après toutes les validations : si le builder
  -- lève et que le script intercepte l'erreur, le parseur reste intact.
  self._options[#self._options + 1] = entry
  self._destinations[dest] = true
  for _, name in ipairs(names) do
    self._by_name[name] = entry
  end
  return self
end

function Parser:option(...)
  local n = select("#", ...)
  validate_arg_count("option", n, 1, 2, 2)
  local spec, opts = ...
  return self:_add_optional(spec, opts, true)
end

function Parser:flag(...)
  local n = select("#", ...)
  validate_arg_count("flag", n, 1, 2, 2)
  local spec, opts = ...
  return self:_add_optional(spec, opts, false)
end

function Parser:argument(...)
  local n = select("#", ...)
  validate_arg_count("argument", n, 1, 2, 2)
  local name, opts = ...

  if type(name) ~= "string" or name == "" or is_optional(name)
      or name:find("%s") then
    error("argparse: positional name must be a non-empty string "
      .. "without whitespace and not starting with '-'", 2)
  end
  opts = validate_opts(opts, true)

  local dest = opts.dest or name
  reserve_destination(self, dest)

  local required
  if opts.required ~= nil then
    required = opts.required
  else
    required = opts.default == nil
  end
  if required and self._has_optional_positional then
    error("argparse: a required positional cannot follow an optional one", 2)
  end

  local entry = {
    name = name,
    dest = dest,
    help = opts.help,
    default = opts.default,
    required = required,
    choices = opts.choices,
    convert = opts.convert,
  }

  self._positionals[#self._positionals + 1] = entry
  self._destinations[dest] = true
  if not required then
    self._has_optional_positional = true
  end
  return self
end

-- --- usage -----------------------------------------------------------

function Parser:get_usage(...)
  validate_arg_count("get_usage", select("#", ...), 0, 0, 2)

  local parts = { "Usage: " .. self._prog .. " [options]" }
  for _, argument in ipairs(self._positionals) do
    if argument.required then
      parts[#parts + 1] = "<" .. argument.name .. ">"
    else
      parts[#parts + 1] = "[" .. argument.name .. "]"
    end
  end

  local lines = { table.concat(parts, " ") }
  if self._description ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = self._description
  end
  if #self._positionals > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Arguments:"
    for _, argument in ipairs(self._positionals) do
      lines[#lines + 1] = "  " .. argument.name
          .. (argument.help and ("  " .. argument.help) or "")
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Options:"
  lines[#lines + 1] = "  -h, --help  show this help"
  for _, option in ipairs(self._options) do
    lines[#lines + 1] = "  " .. table.concat(option.names, ", ")
        .. (option.takes_value and " <value>" or "")
        .. (option.help and ("  " .. option.help) or "")
  end
  return table.concat(lines, "\n")
end

-- --- parsing ---------------------------------------------------------

local function collect_explicit_args(src)
  if type(src) ~= "table" then
    return nil, "argparse: parse source must be a dense array of strings"
  end

  local count = 0
  local max_index = 0
  for key, value in next, src do
    if type(key) ~= "number" or math.type(key) ~= "integer"
        or key < 1 then
      return nil, "argparse: parse source must be a dense array of strings"
    end
    if type(value) ~= "string" then
      return nil, "argparse: argument #" .. tostring(key)
          .. " must be a string"
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end

  if max_index ~= count then
    return nil, "argparse: parse source must not contain holes"
  end

  local result = {}
  for i = 1, max_index do
    result[i] = rawget(src, i)
  end
  return result, nil
end

local function collect_global_args()
  local result = {}
  local global_args = arg
  if type(global_args) ~= "table" then
    return result, nil
  end

  local i = 1
  while rawget(global_args, i) ~= nil do
    local value = rawget(global_args, i)
    if type(value) ~= "string" then
      return nil, "argparse: global arg[" .. tostring(i)
          .. "] must be a string"
    end
    result[i] = value
    i = i + 1
  end
  return result, nil
end

local function finalize_value(entry, raw, label)
  if entry.choices then
    local valid = false
    for _, choice in ipairs(entry.choices) do
      if raw == choice then
        valid = true
        break
      end
    end
    if not valid then
      return nil, label .. ": invalid choice '" .. raw .. "'"
    end
  end

  if entry.convert then
    local ok, converted, conversion_error = pcall(entry.convert, raw)
    if not ok then
      return nil, label .. ": conversion error"
    end
    if converted == nil then
      return nil, label .. ": "
          .. (conversion_error ~= nil and safe_tostring(conversion_error)
              or "invalid value")
    end
    return converted, nil
  end

  return raw, nil
end

function Parser:parse(...)
  local n = select("#", ...)
  validate_arg_count("parse", n, 0, 1, 2)
  local src = ...

  local args, collect_error
  if n == 0 or src == nil then
    args, collect_error = collect_global_args()
  else
    args, collect_error = collect_explicit_args(src)
  end
  if not args then
    return nil, collect_error
  end

  local result = {}
  local seen = {}

  for _, option in ipairs(self._options) do
    if option.takes_value then
      result[option.dest] = option.default
    else
      result[option.dest] = option.default ~= nil
          and option.default or false
    end
  end

  local positional_values = {}
  local i = 1
  local no_more_options = false
  local count = #args

  while i <= count do
    local token = args[i]

    if not no_more_options and token == "--" then
      no_more_options = true
      i = i + 1
    elseif not no_more_options
        and (token == "-h" or token == "--help") then
      return { help = true, usage = self:get_usage() }, nil
    elseif not no_more_options and is_optional(token) and token ~= "-" then
      local key, inline = token:match("^([^=]+)=(.*)$")
      if not key then
        key = token
      end

      local entry = self._by_name[key]
      if not entry then
        return nil, "unknown option '" .. key .. "'"
      end

      if entry.takes_value then
        local raw
        if inline ~= nil then
          raw = inline
        else
          if i + 1 > count then
            return nil, "option '" .. key .. "' requires a value"
          end
          raw = args[i + 1]
          i = i + 1
        end

        local value, value_error = finalize_value(
            entry, raw, "option '" .. key .. "'")
        if value == nil and value_error then
          return nil, value_error
        end
        result[entry.dest] = value
      else
        if inline ~= nil then
          return nil, "flag '" .. key .. "' does not take a value"
        end
        result[entry.dest] = true
      end

      seen[entry] = true
      i = i + 1
    else
      positional_values[#positional_values + 1] = token
      i = i + 1
    end
  end

  for _, option in ipairs(self._options) do
    if option.required and not seen[option] then
      return nil, "missing required option '"
          .. (option.names[#option.names] or option.dest) .. "'"
    end
  end

  for index, entry in ipairs(self._positionals) do
    local raw = positional_values[index]
    if raw == nil then
      if entry.required then
        return nil, "missing required argument '" .. entry.name .. "'"
      end
      result[entry.dest] = entry.default
    else
      local value, value_error = finalize_value(
          entry, raw, "argument '" .. entry.name .. "'")
      if value == nil and value_error then
        return nil, value_error
      end
      result[entry.dest] = value
    end
  end

  if #positional_values > #self._positionals then
    local extra = positional_values[#self._positionals + 1]
    return nil, "unexpected argument '" .. extra .. "'"
  end

  return result, nil
end

return setmetatable(argparse, {
  __call = function(_, ...)
    local n = select("#", ...)
    validate_arg_count("constructor", n, 0, 2, 2)
    local prog, description = ...
    if prog ~= nil and type(prog) ~= "string" then
      error("argparse: prog must be a string or nil", 2)
    end
    if description ~= nil and type(description) ~= "string" then
      error("argparse: description must be a string or nil", 2)
    end
    return new_parser(prog, description)
  end,
})
