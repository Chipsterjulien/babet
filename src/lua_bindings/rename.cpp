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
std::string rename_file(std::string_view old_path, std::string_view new_path) {
    std::error_code ec;

    // Check if the old path is empty
    if (old_path.empty()) {
        return "The old path is empty.";
    }

    // Check if the new path is empty
    if (new_path.empty()) {
        return "The new path is empty.";
    }

    // Check if the old path exists
    std::error_code exist_ec;
    if (!fs::exists(old_path, exist_ec)) {
        return "Source path does not exist: " + std::string(old_path);
    }

    // Check if the new path is different from the old path
    if (old_path == new_path) {
        return "The new path must be different from the old path.";
    }

    // Attempt to rename the file or directory
    try {
        fs::rename(old_path, new_path, ec);
    } catch (const fs::filesystem_error& e) {
        return "Filesystem error: " + std::string(e.what());
    }

    if (ec) {
        switch (ec.value()) {
            case static_cast<int>(std::errc::permission_denied):
                return "Permission denied: " + std::string(old_path);
            case static_cast<int>(std::errc::no_such_file_or_directory):
                return "No such file or directory: " + std::string(old_path);
            case static_cast<int>(std::errc::file_exists):
                return "File already exists at destination: " + std::string(new_path);
            default:
                return "cannot rename '" + std::string(old_path) + "' to '" + std::string(new_path) + "': " + ec.message();
        }
    }

    return "";
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
    int argc = lua_gettop(L);
    if (argc != 2)
    {
        return luaL_error(L, "Expected two arguments");
    }
    if (!lua_isstring(L, 1) || !lua_isstring(L, 2))
    {
        return luaL_error(L, "Expected two strings as arguments");
    }

    const char *old_path = lua_tostring(L, 1);
    const char *new_path = lua_tostring(L, 2);

    std::string error_message = rename_file(old_path, new_path);
    if (error_message.empty())
    {
        return push_ok(L);
    }
    return push_fail(L, error_message);
}
