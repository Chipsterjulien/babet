#include "embedded_searcher.hpp"
#include "zip_utils.hpp"
#include <algorithm>
#include <cstring>
#include <string>
#include <optional>
#include <vector>

static int embedded_read_error_loader(lua_State *L)
{
    const char *message = lua_tostring(L, lua_upvalueindex(1));
    return luaL_error(L, "%s", message ? message : "embedded file read error");
}

static int embedded_lua_searcher(lua_State *L)
{
    size_t module_len = 0;
    const char *moduleName = luaL_checklstring(L, 1, &module_len);
    const char *exePath = luaL_checkstring(L, lua_upvalueindex(1));
    if (std::memchr(moduleName, '\0', module_len) != nullptr)
    {
        lua_pushliteral(L, "\n\tembedded module name contains NUL byte");
        return 1;
    }

    // CORRECTIF longjmp (post-revue Gemini) : si luaL_loadbuffer
    // échoue (erreur de syntaxe dans un .lua embarqué), on doit
    // appeler lua_error() qui fait un longjmp. Ce longjmp ne déroule
    // PAS les destructeurs C++ — donc base / candidates / tried / data
    // fuiraient. On force la destruction de TOUS les objets C++
    // AVANT d'appeler lua_error, via un scope dédié et un retour
    // différé : on note si le load a échoué, on sort du scope (les
    // destructeurs tournent), PUIS on appelle lua_error.
    //
    // Note pratique : ce bug est de toute façon terminal (un module
    // embarqué avec une erreur de syntaxe = binaire qui meurt au
    // require()). Mais on respecte la cohérence avec le reste du
    // code, et ça nous évite une fuite microscopique au cas où un
    // futur appelant attraperait l'erreur via pcall.
    bool load_failed = false;
    bool found = false;

    {
        // "foo.bar" -> "foo/bar"
        std::string base(moduleName, module_len);
        std::replace(base.begin(), base.end(), '.', '/');

        // On tente, dans l'ordre, les deux conventions Lua standard :
        //   1. foo/bar.lua
        //   2. foo/bar/init.lua
        // Identique à package.path en mode dossier.
        const std::string candidates[] = {
            base + ".lua",
            base + "/init.lua",
        };

        std::string tried;

        for (const auto &path : candidates)
        {
            std::string read_error;
            auto data = readEmbeddedFile(exePath, path, &read_error);
            if (!read_error.empty())
            {
                // L'entrée existe mais ne peut pas être chargée (taille
                // excessive, archive corrompue, allocation impossible).
                // Renvoyer un loader qui lève garantit que require() ne
                // contourne pas l'erreur en cherchant un module homonyme
                // dans package.path après l'archive embarquée.
                lua_pushlstring(L, read_error.data(), read_error.size());
                lua_pushcclosure(L, embedded_read_error_loader, 1);
                lua_pushlstring(L, path.data(), path.size());
                found = true;
                break;
            }
            if (data)
            {
                found = true;
                if (luaL_loadbuffer(L, data->data(), data->size(),
                                    path.c_str()) != LUA_OK)
                {
                    // L'erreur est déjà sur la pile Lua (poussée par
                    // luaL_loadbuffer). On note l'échec et on sort
                    // du scope pour laisser les destructeurs tourner.
                    load_failed = true;
                    break;
                }
                lua_pushstring(L, path.c_str());
                // Tous les objets C++ vont être détruits proprement
                // en sortie de scope, puis on return 2.
                break;
            }
            tried += "\n\tno embedded file '" + path + "'";
        }

        if (!found)
        {
            // Aucun candidat : on push le message agrégé. Lua le
            // concatènera aux messages des autres searchers.
            lua_pushstring(L, tried.c_str());
            // Idem : les destructeurs tournent en sortie de scope,
            // puis return 1.
        }
    } // ← base, candidates[], tried, data tous détruits ici.

    if (load_failed)
    {
        // Maintenant que la pile C++ est nettoyée, le longjmp de
        // lua_error est sûr. L'erreur est déjà sur la pile Lua.
        return lua_error(L);
    }
    if (!found)
    {
        return 1; // message d'agrégation déjà poussé
    }
    return 2; // (chunk, path) déjà poussés
}

void register_embedded_searcher(lua_State *L, const char *exePath)
{
    lua_getglobal(L, "package");      // [package]
    lua_getfield(L, -1, "searchers"); // [package, searchers]

    int len = static_cast<int>(lua_rawlen(L, -1));

    // Décale les searchers existants d'un cran à partir de l'index 2,
    // pour libérer la place 2 (après package.preload qui reste en 1).
    for (int i = len; i >= 2; --i)
    {
        lua_rawgeti(L, -1, i);
        lua_rawseti(L, -2, i + 1);
    }

    lua_pushstring(L, exePath);
    lua_pushcclosure(L, embedded_lua_searcher, 1); // upvalue = exePath
    lua_rawseti(L, -2, 2);

    lua_pop(L, 2); // [package, searchers] → []
}
