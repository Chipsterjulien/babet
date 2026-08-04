#include "copy.hpp"
#include "lua_utils.hpp"
#include "fileOperations.hpp"
#include <filesystem>
#include <optional>
#include <string>

/**
 * @brief Lua-accessible function to copy a file.
 *
 * This function is called from Lua and uses the custom_copy_file function to copy a file.
 * It expects to receive two strings as arguments.
 * If the arguments are not strings, a Lua error is raised.
 *
 * @param L Pointer to the Lua state.
 * @return Number of return values on the Lua stack (1: error message or nil).
 */
int lua_copy_file(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_string(L, 1) || !lua_is_strict_string(L, 2))
    {
        return luaL_error(L, "Expected two string arguments: source and destination paths");
    }

    const std::string_view source =
        luaL_checkstring_view_without_nul(L, 1, "source");
    const std::string_view destination =
        luaL_checkstring_view_without_nul(L, 2, "destination");

    return push_action_result_protected(
        L, custom_copy_file(std::filesystem::path(source),
                            std::filesystem::path(destination)));
}
