#include "sha1.hpp"
#include "lua_utils.hpp"
#include "checksum_utils.hpp"

std::optional<std::string> sha1sum(const std::string &path)
{
    return calculate_checksum(path, EVP_sha1());
}

int lua_sha1sum(lua_State *L)
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
    auto result = calculate_checksum_detailed(path, EVP_sha1());

    if (result.value.has_value())
    {
        lua_pushstring(L, result.value->c_str());
        lua_pushnil(L);
    }
    else
    {
        lua_pushnil(L);
        lua_pushstring(L, result.error.c_str());
    }
    return 2;
}