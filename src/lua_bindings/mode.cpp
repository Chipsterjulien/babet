#include "mode.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <cstring>
#include <system_error>
#include <string>
#include <optional>
#include <lua.hpp>

namespace fs = std::filesystem;

namespace
{

    /**
     * @brief Résout le mode demandé en valeur numérique, quelle que soit la forme
     *        passée côté Lua.
     *
     * Accepte :
     *   - une string  : interprétée en base 8 ("755" -> 0o755). Réflexe chmod.
     *   - un nombre   : pris tel quel (l'utilisateur a déjà la valeur décimale,
     *                   p.ex. via tonumber("755", 8)).
     *
     * @return le mode (0..07777) en cas de succès, ou un message d'erreur.
     */
    std::optional<long> resolve_mode(lua_State *L, int index, std::string &error_out)
    {
        if (lua_type(L, index) == LUA_TSTRING)
        {
            size_t mode_len = 0;
            const char *mode_str = lua_tolstring(L, index, &mode_len);
            if (std::memchr(mode_str, '\0', mode_len) != nullptr)
            {
                error_out = "mode string must not contain NUL byte";
                return std::nullopt;
            }

            // Refuse une chaîne vide.
            if (mode_str[0] == '\0')
            {
                error_out = "mode string is empty";
                return std::nullopt;
            }

            char *endptr = nullptr;
            long mode = std::strtol(mode_str, &endptr, 8);

            // strtol s'arrête au premier caractère invalide. Si endptr ne pointe
            // pas sur le '\0' final, c'est qu'il y avait un caractère non-octal
            // (un '8', un '9', une lettre, un espace...).
            if (*endptr != '\0')
            {
                error_out = "invalid octal mode string: '" + std::string(mode_str) + "'";
                return std::nullopt;
            }

            return mode;
        }

        if (lua_type(L, index) == LUA_TNUMBER)
        {
            // On exige un entier : un mode 0.5 n'a aucun sens.
            if (!lua_isinteger(L, index))
            {
                error_out = "numeric mode must be an integer";
                return std::nullopt;
            }
            return static_cast<long>(lua_tointeger(L, index));
        }

        error_out = "mode must be a string (e.g. \"755\") or an integer";
        return std::nullopt;
    }

} // namespace

/**
 * @brief Changes the permissions of a file or directory.
 *
 * Lua usage:
 *   ok, err = babet.setMode(path, "755")   -- string, lue en octal
 *   ok, err = babet.setMode(path, 493)     -- nombre, pris tel quel
 *
 * @param L Lua state.
 * @return int Number of return values on the Lua stack (2: ok/nil, err/nil).
 */
int lua_setmode(lua_State *L)
{
    int argc = lua_gettop(L);
    if (argc != 2)
    {
        return luaL_error(L, "Expected two arguments: path and mode");
    }
    if (!lua_isstring(L, 1))
    {
        return luaL_error(L, "Expected a string as first argument (path)");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");

    std::string mode_error;
    auto mode_opt = resolve_mode(L, 2, mode_error);
    if (!mode_opt)
    {
        return push_fail(L, mode_error);
    }

    long mode = *mode_opt;
    if (mode < 0 || mode > 07777)
    {
        return push_fail(L, "mode out of range (must be between 0 and 0o7777)");
    }

    std::error_code ec;
    fs::permissions(path, static_cast<fs::perms>(mode), ec);
    if (ec)
    {
        return push_fail(L, ec.message());
    }
    return push_ok(L);
}

/**
 * @brief Gets the permissions of a file or directory.
 *
 * Lua usage: mode, err = babet.getMode(path)
 *   - mode : permission and special bits as an integer (0..0o7777)
 *
 * @param L Lua state.
 * @return int Number of return values on the Lua stack (2: mode/nil, err/nil).
 */
int lua_getmode(lua_State *L)
{
    int argc = lua_gettop(L);
    if (argc != 1)
    {
        return luaL_error(L, "Expected one argument");
    }
    if (!lua_isstring(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");

    std::error_code ec;
    auto perms = fs::status(path, ec).permissions();
    if (ec)
    {
        lua_pushnil(L);
        lua_pushstring(L, ec.message().c_str());
        return 2;
    }

    lua_pushinteger(L, static_cast<int>(perms) & 07777);
    lua_pushnil(L);
    return 2;
}
