#include "fileExists.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <system_error>
#include <string>
#include <string_view>

namespace fs = std::filesystem;

int lua_fileExists(lua_State *L)
{
    if (!lua_arity_is(L, 1) || !lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected one string argument");
    }

    fs::path path(luaL_checkstring_without_nul(L, 1, "path"));

    std::error_code ec;
    fs::file_status status = fs::status(path, ec);

    // "N'existe pas" n'est PAS une erreur : c'est une réponse légitime (false).
    // On ne remonte une vraie erreur que si ec est positionné ET que ce n'est
    // pas un simple "fichier introuvable".
    if (ec && ec != std::errc::no_such_file_or_directory)
    {
        return push_fail_protected(L, "cannot check '" + path.string() + "': " + ec.message());
    }

    // À ce stade : soit le fichier existe (status valide), soit il n'existe pas
    // (status == not_found). is_regular_file gère les deux cas proprement.
    bool is_regular = fs::is_regular_file(status);

    lua_pushboolean(L, is_regular);
    lua_pushnil(L);
    return 2;
}