#include "sha3_384.hpp"
#include "lua_utils.hpp"
#include "checksum_utils.hpp"

std::optional<std::string> sha3_384sum(const std::string &path)
{
    return calculate_checksum(path, EVP_sha3_384());
}

int lua_sha3_384sum(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected one argument");
    }

    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    auto result = calculate_checksum_detailed(path, EVP_sha3_384());

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
