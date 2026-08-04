#include "mkdir.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <system_error>

namespace fs = std::filesystem;

/**
 * @brief Recursively create a directory path (mkdir -p semantics).
 *
 * Existing directories are accepted. A regular file or another non-directory
 * entry anywhere in the path is an error.
 *
 * @param path Directory path to create.
 * @return An error message on failure, or std::nullopt on success.
 */
std::optional<std::string> create_directory(const std::string &path) {
    std::error_code ec;
    std::error_code abs_ec;
    fs::path dir_path = fs::absolute(path, abs_ec);
    if (abs_ec) dir_path = fs::path(path);

    // Attempt to create the directory
    if (!fs::create_directories(dir_path, ec)) {
        if (ec) {
            switch (ec.value()) {
                case static_cast<int>(std::errc::no_such_file_or_directory):
                    return "The parent directory does not exist: " + dir_path.parent_path().string();
                case static_cast<int>(std::errc::permission_denied):
                    return "Permission denied: " + dir_path.string();
                case static_cast<int>(std::errc::no_space_on_device):
                    return "No space left on device: " + dir_path.string();
                case static_cast<int>(std::errc::file_exists):
                    return "The path already exists and is not a directory: " + dir_path.string();
                default:
                    return "cannot create directory '" + dir_path.string() + "': " + ec.message();
            }
        }
    }

    return std::nullopt;
}

/**
 * @brief Lua binding for recursive, idempotent directory creation.
 *
 * Lua usage: ok, err = babet.mkdir(path)
 *
 * @param L Lua state.
 * @return Two values: true/nil on success, nil/error on failure.
 */
int lua_mkdir(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected exactly one argument");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    return push_action_result_protected(L, create_directory(path));
}
