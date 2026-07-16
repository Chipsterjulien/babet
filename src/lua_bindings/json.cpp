#include "json.hpp"
#include "lua_utils.hpp"

#include <nlohmann/json.hpp>

#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>

using nlohmann::json;

namespace
{

    constexpr lua_Integer MAX_JSON_INDENT = 256;

    // Profondeur d'imbrication max, dans les deux sens. Garde-fou : une
    // table Lua cyclique récurserait à l'infini -> on coupe net avec une
    // erreur propre plutôt qu'un débordement de pile C++. 1000 est très
    // au-delà de tout JSON de config réaliste.
    constexpr int MAX_DEPTH = 1000;

    // Adresses uniques servant de clés registry pour les sentinels
    // (lua_rawsetp/lua_rawgetp) : zéro collision possible avec une clé
    // string d'un autre morceau de code.
    const char NULL_SENTINEL_KEY = 0;
    const char EMPTY_ARRAY_SENTINEL_KEY = 0;

    // Métatable interne (identité seule, aucun champ) posée par
    // decode() sur les tables issues d'un array JSON VIDE. Elle dit à
    // encode() « sérialise-moi en [] même si je suis vide », ce qui
    // préserve l'aller-retour decode("[]") -> encode -> "[]". Les
    // arrays non vides et les objets vides s'auto-détectent déjà, donc
    // seules les tables d'array vide sont marquées.
    const char ARRAY_MT_KEY = 0;

    // Renvoie true si la valeur à l'index `idx` est, par identité, le
    // sentinel enregistré sous `key` dans le registry.
    bool is_sentinel(lua_State *L, int idx, const void *key)
    {
        idx = lua_absindex(L, idx);
        lua_rawgetp(L, LUA_REGISTRYINDEX, key);
        bool eq = lua_rawequal(L, idx, -1);
        lua_pop(L, 1);
        return eq;
    }

    // Renvoie true si la table à `idx` porte la métatable ARRAY_MT.
    bool has_array_mt(lua_State *L, int idx)
    {
        idx = lua_absindex(L, idx);
        if (lua_getmetatable(L, idx) == 0)
        {
            return false; // pas de métatable du tout
        }
        lua_rawgetp(L, LUA_REGISTRYINDEX, &ARRAY_MT_KEY);
        bool eq = lua_rawequal(L, -1, -2);
        lua_pop(L, 2); // dépile ARRAY_MT et la métatable de la table
        return eq;
    }

    enum class TableShape
    {
        EmptyObject, // {} -> {}  (décision actée : objet par défaut)
        Array,       // clés exactement 1..n
        Object,      // uniquement des clés string
    };

    // Classe une table NON marquée par un sentinel. Lève
    // std::runtime_error (capté plus haut -> (nil, err)) sur clés
    // mixtes / trouées / non représentables.
    TableShape classify_table(lua_State *L, int idx, lua_Integer &out_len)
    {
        idx = lua_absindex(L, idx);

        lua_Integer int_keys = 0;
        lua_Integer max_int_key = 0;
        long long str_keys = 0;
        bool has_bad_key = false;

        lua_pushnil(L);
        while (lua_next(L, idx) != 0)
        {
            // pile : ... clé(-2) valeur(-1)
            int kt = lua_type(L, -2);
            if (kt == LUA_TNUMBER && lua_is_strict_integer(L, -2))
            {
                lua_Integer k = lua_tointeger(L, -2);
                if (k >= 1)
                {
                    ++int_keys;
                    if (k > max_int_key)
                    {
                        max_int_key = k;
                    }
                }
                else
                {
                    has_bad_key = true; // entier <= 0 : pas un index de séquence
                }
            }
            else if (kt == LUA_TSTRING)
            {
                ++str_keys;
            }
            else
            {
                // float non entier, booléen, table, etc.
                has_bad_key = true;
            }
            lua_pop(L, 1); // retire la valeur, garde la clé pour lua_next
        }

        // Vérifier les clés invalides avant de conclure que la table est
        // vide. Une table qui ne contient que des clés non représentables
        // ([0], [1.5], [true], etc.) n'est pas un objet vide : elle doit
        // être refusée au lieu d'être silencieusement encodée en {}.
        if (has_bad_key)
        {
            throw std::runtime_error(
                "json: unsupported table key (keys must be positive "
                "integers for arrays, or strings for objects)");
        }

        if (str_keys == 0 && int_keys == 0)
        {
            return TableShape::EmptyObject;
        }

        if (str_keys > 0 && int_keys > 0)
        {
            throw std::runtime_error(
                "json: table mixes string and integer keys "
                "(cannot be a JSON array or object)");
        }

        if (str_keys > 0)
        {
            return TableShape::Object;
        }

        // Uniquement des clés entières >= 1. Les clés d'une table Lua
        // étant distinctes, "nombre de clés == plus grande clé" implique
        // exactement 1..n sans trou.
        if (max_int_key == int_keys)
        {
            out_len = max_int_key;
            return TableShape::Array;
        }

        throw std::runtime_error(
            "json: array has holes (sparse integer keys are not "
            "representable in JSON)");
    }

    json lua_to_json(lua_State *L, int idx, int depth);

    json lua_table_to_json(lua_State *L, int idx, int depth)
    {
        idx = lua_absindex(L, idx);

        // Une table marquée ARRAY_MT (issue de decode("[]")) doit
        // ressortir en array même vide.
        bool force_array = has_array_mt(L, idx);

        lua_Integer len = 0;
        TableShape shape = classify_table(L, idx, len);

        if (shape == TableShape::EmptyObject)
        {
            return force_array ? json::array() : json::object();
        }

        if (force_array && shape == TableShape::Object)
        {
            throw std::runtime_error(
                "json: array-tagged table has non-array (string) keys");
        }

        if (shape == TableShape::Array)
        {
            json arr = json::array();
            for (lua_Integer i = 1; i <= len; ++i)
            {
                lua_geti(L, idx, i);
                arr.push_back(lua_to_json(L, -1, depth + 1));
                lua_pop(L, 1);
            }
            return arr;
        }

        // Object : uniquement des clés string (garanti par classify).
        json obj = json::object();
        lua_pushnil(L);
        while (lua_next(L, idx) != 0)
        {
            // La clé est forcément une string ici : lua_tolstring ne mute
            // donc pas la clé et ne perturbe pas lua_next.
            size_t klen = 0;
            const char *k = lua_tolstring(L, -2, &klen);
            obj[std::string(k, klen)] = lua_to_json(L, -1, depth + 1);
            lua_pop(L, 1);
        }
        return obj;
    }

    json lua_to_json(lua_State *L, int idx, int depth)
    {
        if (depth > MAX_DEPTH)
        {
            throw std::runtime_error(
                "json: nesting too deep (over " +
                std::to_string(MAX_DEPTH) +
                " levels — cyclic table?)");
        }

        // CORRECTIF longjmp (post-revue Gemini) : luaL_checkstack
        // utilise longjmp() si la pile ne peut pas grandir, ce qui
        // ne déroule PAS les destructeurs C++. La fonction est
        // récursive et alloue des std::string / json en chemin, qui
        // fuiraient. On utilise lua_checkstack (variante silencieuse,
        // renvoie 0 en échec) et on remonte l'erreur via la voie
        // normale du module : exception C++ attrapée par
        // lua_json_encode (try/catch std::exception en sortie).
        if (!lua_checkstack(L, 4))
        {
            throw std::runtime_error("json: lua stack overflow during encode");
        }
        idx = lua_absindex(L, idx);

        // Sentinels d'abord : ce sont des tables, donc à tester avant le
        // cas LUA_TTABLE générique.
        if (is_sentinel(L, idx, &NULL_SENTINEL_KEY))
        {
            return json(nullptr);
        }
        if (is_sentinel(L, idx, &EMPTY_ARRAY_SENTINEL_KEY))
        {
            return json::array();
        }

        switch (lua_type(L, idx))
        {
        case LUA_TNIL:
            // Seulement atteignable au niveau racine (une valeur nil dans
            // une table efface la clé, jamais rencontrée en descente).
            return json(nullptr);

        case LUA_TBOOLEAN:
            return json(static_cast<bool>(lua_toboolean(L, idx)));

        case LUA_TNUMBER:
            if (lua_is_strict_integer(L, idx))
            {
                return json(static_cast<std::int64_t>(lua_tointeger(L, idx)));
            }
            else
            {
                double d = lua_tonumber(L, idx);
                if (!std::isfinite(d))
                {
                    throw std::runtime_error(
                        "json: cannot encode NaN or Infinity "
                        "(not representable in JSON)");
                }
                return json(d);
            }

        case LUA_TSTRING:
        {
            size_t n = 0;
            const char *s = lua_tolstring(L, idx, &n);
            return json(std::string(s, n));
        }

        case LUA_TTABLE:
            return lua_table_to_json(L, idx, depth);

        default:
            throw std::runtime_error(
                std::string("json: cannot encode value of type '") +
                lua_typename(L, lua_type(L, idx)) + "'");
        }
    }

    // Empile sur la pile Lua la valeur correspondant à `j`. Laisse
    // exactement une valeur sur la pile en cas de succès.
    void json_to_lua(lua_State *L, const json &j, int depth)
    {
        if (depth > MAX_DEPTH)
        {
            throw std::runtime_error(
                "json: nesting too deep (over " +
                std::to_string(MAX_DEPTH) + " levels)");
        }

        // CORRECTIF longjmp (post-revue Gemini) : même raison que dans
        // lua_to_json. lua_checkstack silencieux + throw cohérent
        // avec le reste du module.
        if (!lua_checkstack(L, 4))
        {
            throw std::runtime_error("json: lua stack overflow during decode");
        }

        switch (j.type())
        {
        case json::value_t::null:
            // null -> le sentinel partagé (même objet que
            // babet.json.null), pour un aller-retour sans perte.
            lua_rawgetp(L, LUA_REGISTRYINDEX, &NULL_SENTINEL_KEY);
            break;

        case json::value_t::boolean:
            lua_pushboolean(L, j.get<bool>() ? 1 : 0);
            break;

        case json::value_t::number_integer:
            lua_pushinteger(L, static_cast<lua_Integer>(j.get<std::int64_t>()));
            break;

        case json::value_t::number_unsigned:
        {
            std::uint64_t u = j.get<std::uint64_t>();
            if (u > static_cast<std::uint64_t>(
                        std::numeric_limits<lua_Integer>::max()))
            {
                // Dépasse lua_Integer : float plutôt qu'un wrap négatif
                // silencieux.
                lua_pushnumber(L, static_cast<lua_Number>(u));
            }
            else
            {
                lua_pushinteger(L, static_cast<lua_Integer>(u));
            }
            break;
        }

        case json::value_t::number_float:
            lua_pushnumber(L, static_cast<lua_Number>(j.get<double>()));
            break;

        case json::value_t::string:
        {
            const std::string &s = j.get_ref<const std::string &>();
            lua_pushlstring(L, s.data(), s.size());
            break;
        }

        case json::value_t::array:
        {
            if (j.empty())
            {
                // [] -> table NEUVE marquée ARRAY_MT. Neuve (et non le
                // sentinel partagé) : elle reste mutable et sûre à
                // manipuler ; le marquage garantit que re-encode donne
                // "[]" et pas "{}".
                lua_newtable(L);
                lua_rawgetp(L, LUA_REGISTRYINDEX, &ARRAY_MT_KEY);
                lua_setmetatable(L, -2);
                break;
            }
            lua_createtable(L, static_cast<int>(j.size()), 0);
            lua_Integer i = 1;
            for (const auto &el : j)
            {
                json_to_lua(L, el, depth + 1);
                lua_seti(L, -2, i++);
            }
            break;
        }

        case json::value_t::object:
        {
            lua_createtable(L, 0, static_cast<int>(j.size()));
            for (auto it = j.begin(); it != j.end(); ++it)
            {
                const std::string &key = it.key();
                // lua_pushlstring + lua_settable plutôt que
                // lua_setfield(key.c_str()) : une clé JSON peut contenir
                // un octet NUL (JSON l'autorise), c_str() la
                // tronquerait.
                lua_pushlstring(L, key.data(), key.size());
                json_to_lua(L, it.value(), depth + 1);
                lua_settable(L, -3);
            }
            break;
        }

        default:
            // binary / discarded : ne devrait pas survenir depuis un
            // parse JSON standard.
            throw std::runtime_error(
                "json: unsupported JSON value type after parsing");
        }
    }

    std::string normalize_err(const std::string &what)
    {
        if (what.rfind("json:", 0) == 0)
        {
            return what;
        }
        return "json: " + what;
    }

} // namespace

int lua_json_encode(lua_State *L)
{
    int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L, "Expected one or two arguments");
    }

    int indent = -1; // -1 = compact
    if (argc >= 2 && !lua_isnil(L, 2))
    {
        if (!lua_istable(L, 2))
        {
            return luaL_error(L, "Expected an options table as second argument");
        }
        lua_getfield(L, 2, "indent");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_integer(L, -1))
            {
                lua_pop(L, 1);
                return luaL_error(L, "opts.indent must be an integer");
            }
            lua_Integer requested_indent = lua_tointeger(L, -1);
            if (requested_indent < 0)
            {
                indent = -1; // négatif traité comme compact
            }
            else if (requested_indent > MAX_JSON_INDENT)
            {
                lua_pop(L, 1);
                return luaL_error(
                    L, "opts.indent too large (maximum is 256)");
            }
            else
            {
                indent = static_cast<int>(requested_indent);
            }
        }
        lua_pop(L, 1);
    }

    try
    {
        json j = lua_to_json(L, 1, 0);
        std::string s = (indent < 0)
                            ? j.dump()
                            : j.dump(indent);
        lua_pushlstring(L, s.data(), s.size());
        lua_pushnil(L);
        return 2;
    }
    catch (const std::exception &e)
    {
        lua_settop(L, argc); // nettoie tout résidu de pile
        lua_pushnil(L);
        std::string msg = normalize_err(e.what());
        lua_pushlstring(L, msg.data(), msg.size());
        return 2;
    }
}

int lua_json_decode(lua_State *L)
{
    int argc = lua_gettop(L);
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected one argument");
    }
    // lua_isstring() accepte aussi les nombres et les convertirait
    // implicitement en texte. decode() exige volontairement une vraie
    // chaîne Lua afin que les erreurs de type ne soient pas masquées.
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    size_t n = 0;
    const char *s = lua_tolstring(L, 1, &n);

    try
    {
        // parse(first, last) : gère la longueur (y compris d'éventuels
        // octets NUL) sans dépendre d'un terminateur.
        json j = json::parse(s, s + n);
        json_to_lua(L, j, 0);
        lua_pushnil(L);
        return 2;
    }
    catch (const std::exception &e)
    {
        lua_settop(L, argc); // efface ce que json_to_lua aurait empilé
        lua_pushnil(L);
        std::string msg = normalize_err(e.what());
        lua_pushlstring(L, msg.data(), msg.size());
        return 2;
    }
}

int lua_json_as_array(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected one argument");
    }
    if (!lua_istable(L, 1))
    {
        return luaL_error(L, "Expected a table as argument");
    }
    // Refus des sentinels : lua_setmetatable (API C) contourne le
    // __metatable / __newindex protégés, donc sans ce garde-fou
    // as_array(json.null) déprotégerait silencieusement le sentinel.
    if (is_sentinel(L, 1, &NULL_SENTINEL_KEY) ||
        is_sentinel(L, 1, &EMPTY_ARRAY_SENTINEL_KEY))
    {
        return luaL_error(
            L, "babet.json.as_array: cannot tag a json sentinel");
    }

    lua_settop(L, 1); // ne garde que la table
    lua_rawgetp(L, LUA_REGISTRYINDEX, &ARRAY_MT_KEY);
    lua_setmetatable(L, 1); // pose ARRAY_MT (idempotent), dépile la mt
    return 1;               // renvoie la table elle-même (chaînable)
}

namespace
{

    // Métatable partagée par les deux sentinels : __tostring lisible
    // (print(babet.json.null) -> "babet.json.null") et
    // __metatable verrouillée pour qu'un script ne puisse pas la
    // trafiquer (même esprit que EVP_MD_CTX_RAII non-copiable).
    //
    // Précondition : le sentinel (une table) est au sommet de la pile.
    // Postcondition : pile inchangée, metatable attachée au sentinel.
    void set_sentinel_metatable(lua_State *L, const char *label)
    {
        lua_newtable(L); // [sentinel, metatable]

        // __tostring : closure avec le label en upvalue.
        lua_pushstring(L, label);
        lua_pushcclosure(
            L,
            [](lua_State *Ls) -> int
            {
                lua_pushvalue(Ls, lua_upvalueindex(1));
                return 1;
            },
            1);
        lua_setfield(L, -2, "__tostring");

        // getmetatable(sentinel) renverra false au lieu de la metatable.
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "__metatable");

        // __newindex : un sentinel est une constante. Toute écriture
        // (babet.json.null.foo = ...) lève une erreur Lua claire
        // plutôt que de muter silencieusement le singleton partagé.
        lua_pushcfunction(
            L,
            [](lua_State *Ls) -> int
            {
                return luaL_error(
                    Ls, "babet.json sentinel is read-only");
            });
        lua_setfield(L, -2, "__newindex");

        lua_setmetatable(L, -2); // attache au sentinel, dépile la metatable
    }

} // namespace

void register_json(lua_State *L)
{
    // Précondition : table babet au sommet (-1).
    lua_newtable(L); // [babet, json]

    lua_pushcfunction(L, lua_json_encode);
    lua_setfield(L, -2, "encode");

    lua_pushcfunction(L, lua_json_decode);
    lua_setfield(L, -2, "decode");

    lua_pushcfunction(L, lua_json_as_array);
    lua_setfield(L, -2, "as_array");

    // Métatable interne ARRAY_MT (identité seule). Stockée dans le
    // registry ; posée par decode() sur les arrays vides.
    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &ARRAY_MT_KEY);

    // --- sentinel null ------------------------------------------------
    lua_newtable(L); // [babet, json, null]
    set_sentinel_metatable(L, "babet.json.null");
    lua_pushvalue(L, -1); // [babet, json, null, null]
    lua_rawsetp(L, LUA_REGISTRYINDEX, &NULL_SENTINEL_KEY);
    lua_setfield(L, -2, "null"); // json.null = sentinel

    // --- sentinel empty_array ----------------------------------------
    lua_newtable(L);
    set_sentinel_metatable(L, "babet.json.empty_array");
    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &EMPTY_ARRAY_SENTINEL_KEY);
    lua_setfield(L, -2, "empty_array");

    lua_setfield(L, -2, "json"); // babet.json = json ; pile revient à [babet]
}
