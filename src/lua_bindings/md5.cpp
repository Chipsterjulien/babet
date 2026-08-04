#include "md5.hpp"
#include "lua_utils.hpp"
#include "checksum_utils.hpp"

std::optional<std::string> md5sum(const std::string &path)
{
    return calculate_checksum(path, EVP_md5());
}

namespace
{
int lua_md5sum_impl(lua_State *L)
{
    if (!lua_arity_is(L, 1) || !lua_is_strict_string(L, 1))
        return luaL_error(L, "Expected one string argument");

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    auto result = calculate_checksum_detailed(path, EVP_md5());
    if (result.value.has_value())
        return push_string_result_protected(L, *result.value);
    return push_fail_protected(L, result.error);
}
} // namespace

int lua_md5sum(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_md5sum_impl>(
        L, "checksum: out of memory", "checksum: internal failure",
        "checksum: unknown internal failure");
}
