#include "rename.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <string>
#include <system_error>
#include <iostream>

namespace fs = std::filesystem;

/**
 * @brief Function to rename a file or directory
 *
 * This function takes two strings representing the old path and the new path,
 * and renames the file or directory.
 *
 * @param old_path The current name of the file or directory
 * @param new_path The new name of the file or directory
 * @return A string with the error message if any, or an empty string if successful.
 */
std::string rename_file(std::string_view old_path, std::string_view new_path)
{
    if (old_path.empty())
    {
        return "The old path is empty.";
    }
    if (new_path.empty())
    {
        return "The new path is empty.";
    }
    if (old_path == new_path)
    {
        return "The new path must be different from the old path.";
    }

    // Do not pre-check with exists(): it follows symlinks and would reject a
    // dangling symlink even though rename(2) can rename the directory entry.
    std::error_code ec;
    fs::rename(fs::path(old_path), fs::path(new_path), ec);
    if (!ec)
    {
        return {};
    }

    if (ec == std::errc::permission_denied)
    {
        return "Permission denied: " + std::string(old_path);
    }
    if (ec == std::errc::no_such_file_or_directory)
    {
        return "No such file or directory: " + std::string(old_path);
    }
    if (ec == std::errc::file_exists)
    {
        return "File already exists at destination: " +
               std::string(new_path);
    }
    return "cannot rename '" + std::string(old_path) + "' to '" +
           std::string(new_path) + "': " + ec.message();
}

/**
 * @brief Lua-accessible function to rename a file or directory
 *
 * This function is called from Lua and uses the rename_file function to rename a file or directory.
 * It expects to receive two strings as arguments.
 * If the arguments are not strings, a Lua error is raised.
 *
 * @param L Pointer to the Lua state
 * @return Number of return values on the Lua stack (1: error message or nil).
 */
int lua_rename(lua_State *L)
{
    if (!lua_arity_is(L, 2))
    {
        return luaL_error(L, "Expected two arguments");
    }
    if (!lua_is_strict_string(L, 1) || !lua_is_strict_string(L, 2))
    {
        return luaL_error(L, "Expected two strings as arguments");
    }

    const std::string_view old_path =
        luaL_checkstring_view_without_nul(L, 1, "source");
    const std::string_view new_path =
        luaL_checkstring_view_without_nul(L, 2, "destination");

    std::string error_message =
        rename_file(std::string(old_path), std::string(new_path));
    if (error_message.empty())
    {
        return push_ok(L);
    }
    return push_fail_protected(L, error_message);
}
