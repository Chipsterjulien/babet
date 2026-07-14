// toml++ est header-only, single-file ; inclus dans cette seule TU.
// (Pattern strict miroir de http.cpp et de l'usage nlohmann/json.)
//
// On force le mode NOEXCEPT de toml++ : en mode par défaut (avec
// exceptions C++ activées côté compilateur), toml::parse LÈVE
// toml::parse_error sur entrée invalide, et parse_result devient un
// alias direct de toml::table. Ce comportement contredit notre
// contrat (val, err) qui interdit toute exception traversant vers
// Lua. En forçant TOML_EXCEPTIONS=0 ici, toml::parse renvoie un VRAI
// parse_result distinct, qu'on peut tester via operator bool() et
// dont on extrait .error() / .table() proprement.
// Define LOCAL à cette TU (avant l'include) -> aucune influence sur
// les autres unités de compilation.
#define TOML_EXCEPTIONS 0
#include <toml++/toml.hpp>

#include "toml.hpp"
#include "lua_utils.hpp"

#include <cstdint>
#include <exception>
#include <stdexcept>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>

namespace
{

    // Pré-déclaration : la conversion est récursive (tables/arrays).
    void push_toml_node(lua_State *L, const toml::node &node);

    // --- helpers de formatage ISO 8601 pour les types temporels ----
    //
    // toml++ expose `date`, `time`, `date_time` ; on les rend en
    // strings ISO 8601 (décision TOML-3). On utilise std::ostringstream
    // pour bénéficier du operator<< natif de toml++ qui produit déjà
    // le bon format ISO. Plus simple et plus sûr que de reformatter à
    // la main (toml++ gère les fractions de seconde, l'offset, etc.).

    std::string date_to_iso(const toml::date &d)
    {
        std::ostringstream oss;
        oss << d;
        return oss.str();
    }

    std::string time_to_iso(const toml::time &t)
    {
        std::ostringstream oss;
        oss << t;
        return oss.str();
    }

    std::string date_time_to_iso(const toml::date_time &dt)
    {
        std::ostringstream oss;
        oss << dt;
        return oss.str();
    }

    // --- conversion table TOML -> table Lua à clés string ----------

    void push_toml_table(lua_State *L, const toml::table &tbl)
    {
        lua_newtable(L);
        for (const auto &[key, value] : tbl)
        {
            // Une clé TOML citée peut contenir n'importe quelle valeur
            // scalaire Unicode échappée, y compris U+0000. lua_setfield()
            // prend une chaîne C et tronquerait donc silencieusement une
            // telle clé. On pousse explicitement la longueur puis on fait
            // un rawset dans la table Lua fraîchement créée.
            const std::string_view k = key.str();
            lua_pushlstring(L, k.data(), k.size());
            push_toml_node(L, value);
            lua_rawset(L, -3);
        }
    }

    // --- conversion array TOML -> séquence Lua à clés 1..n ----------

    void push_toml_array(lua_State *L, const toml::array &arr)
    {
        lua_newtable(L);
        lua_Integer i = 1;
        for (const auto &elem : arr)
        {
            push_toml_node(L, elem);
            lua_rawseti(L, -2, i++);
        }
    }

    // --- dispatch principal ----------------------------------------

    void push_toml_node(lua_State *L, const toml::node &node)
    {
        // CORRECTIF (revue Gemini post-audit v21, vérifié) : réserver
        // la pile avant de pousser. push_toml_node / push_toml_table
        // se récursent mutuellement (~2 slots simultanés par niveau :
        // table + clé + valeur ; 5 avec marge) et la profondeur vient du
        // document TOML DÉCODÉ — donc potentiellement hostile. Le
        // throw rejoint le try/catch de lua_toml_decode -> (nil,
        // "toml: ..."), le canal d'erreur existant du module.
        if (!lua_checkstack(L, 5))
        {
            throw std::runtime_error("lua stack overflow during toml conversion");
        }

        // Le test des types se fait via is_X() ; la récupération de
        // la valeur via value<T>() (qui renvoie std::optional<T>).
        if (node.is_table())
        {
            push_toml_table(L, *node.as_table());
            return;
        }
        if (node.is_array())
        {
            push_toml_array(L, *node.as_array());
            return;
        }
        if (node.is_string())
        {
            // value<string> : copie ; on passe par value_or pour
            // éviter optional (le is_string() garantit la présence).
            auto v = node.value<std::string>();
            if (v.has_value())
            {
                lua_pushlstring(L, v->data(), v->size());
            }
            else
            {
                lua_pushstring(L, ""); // défensif : ne devrait jamais arriver
            }
            return;
        }
        if (node.is_integer())
        {
            auto v = node.value<int64_t>();
            lua_pushinteger(L, v.value_or(0));
            return;
        }
        if (node.is_floating_point())
        {
            auto v = node.value<double>();
            lua_pushnumber(L, v.value_or(0.0));
            return;
        }
        if (node.is_boolean())
        {
            auto v = node.value<bool>();
            lua_pushboolean(L, v.value_or(false) ? 1 : 0);
            return;
        }
        // Types temporels : ISO 8601 (décision TOML-3).
        if (node.is_date())
        {
            auto v = node.value<toml::date>();
            std::string s = v.has_value() ? date_to_iso(*v) : "";
            lua_pushlstring(L, s.data(), s.size());
            return;
        }
        if (node.is_time())
        {
            auto v = node.value<toml::time>();
            std::string s = v.has_value() ? time_to_iso(*v) : "";
            lua_pushlstring(L, s.data(), s.size());
            return;
        }
        if (node.is_date_time())
        {
            auto v = node.value<toml::date_time>();
            std::string s = v.has_value() ? date_time_to_iso(*v) : "";
            lua_pushlstring(L, s.data(), s.size());
            return;
        }
        // Garde-fou : type non reconnu (ne devrait pas arriver, la
        // liste ci-dessus couvre tous les types TOML). On pousse nil
        // plutôt que de planter — invariant : ne jamais propager
        // d'exception ni laisser un état de pile incohérent.
        lua_pushnil(L);
    }

} // namespace

int lua_toml_decode(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (argc != 1)
    {
        return luaL_error(L, "Expected one argument");
    }

    // Mauvais type -> luaL_error. luaL_checktype lève strictement
    // (pas de coercition silencieuse des nombres comme avec
    // luaL_checkstring) : decode attend une vraie chaîne Lua.
    luaL_checktype(L, 1, LUA_TSTRING);
    size_t len = 0;
    const char *s = lua_tolstring(L, 1, &len);
    std::string_view src(s, len);

    try
    {
        toml::parse_result result = toml::parse(src);
        if (!result)
        {
            // result.error() est un toml::parse_error qui expose
            // .description() et .source() (région avec ligne/col).
            const toml::parse_error &err = result.error();
            const auto &src_region = err.source();
            std::string msg = "toml: ";
            msg.append(err.description());
            msg += " (line ";
            msg += std::to_string(src_region.begin.line);
            msg += ", col ";
            msg += std::to_string(src_region.begin.column);
            msg += ")";
            lua_settop(L, argc);
            return push_fail(L, msg);
        }
        // Succès : result se convertit implicitement en toml::table&.
        // (Un document TOML a TOUJOURS une table racine, jamais un
        // scalaire ; cohérent avec la décision TOML-4.)
        const toml::table &root = result.table();
        push_toml_table(L, root);
        lua_pushnil(L);
        return 2;
    }
    catch (const std::exception &e)
    {
        // TOML_EXCEPTIONS=0 empêche les erreurs de parsing de lever,
        // mais nos helpers de conversion peuvent encore produire une
        // exception C++ (par exemple le garde-fou de pile Lua).
        // Nettoyer les tables partielles garantit un retour stable.
        lua_settop(L, argc);
        return push_fail(L, std::string("toml: ") + e.what());
    }
    catch (...)
    {
        lua_settop(L, argc);
        return push_fail(L, "toml: unknown error");
    }
}

void register_toml(lua_State *L)
{
    // Précondition : table babet au sommet (-1), comme
    // register_json / register_http.
    lua_newtable(L);

    lua_pushcfunction(L, lua_toml_decode);
    lua_setfield(L, -2, "decode");

    lua_setfield(L, -2, "toml");
}
