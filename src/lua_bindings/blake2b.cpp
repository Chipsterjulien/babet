#include "blake2b.hpp"
#include "lua_utils.hpp"
#include "checksum_utils.hpp"

std::optional<std::string> blake2b512sum(const std::string &path)
{
    return calculate_checksum(path, EVP_blake2b512());
}

int lua_blake2b512sum(lua_State *L)
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
    auto result = calculate_checksum_detailed(path, EVP_blake2b512());

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
