#include "sha3_256.hpp"
#include "lua_utils.hpp"
#include "checksum_utils.hpp"

std::optional<std::string> sha3_256sum(const std::string &path)
{
    return calculate_checksum(path, EVP_sha3_256());
}

namespace
{
int lua_sha3_256sum_impl(lua_State *L)
{
    if (!lua_arity_is(L, 1) || !lua_is_strict_string(L, 1))
        return luaL_error(L, "Expected one string argument");

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    auto result = calculate_checksum_detailed(path, EVP_sha3_256());
    if (result.value.has_value())
        return push_string_result_protected(L, *result.value);
    return push_fail_protected(L, result.error);
}
} // namespace

int lua_sha3_256sum(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_sha3_256sum_impl>(
        L, "checksum: out of memory", "checksum: internal failure",
        "checksum: unknown internal failure");
}
