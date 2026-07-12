#include "mkdir.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <system_error>

namespace fs = std::filesystem;

/**
 * @brief Create a directory path.
 *
 * This function attempts to create the specified directory path. If the directory already exists
 * and ignore_if_exists is true, no error is returned.
 *
 * @param path The directory path to create.
 * @param ignore_if_exists If true, does not return an error if the directory already exists.
 * @return std::optional<std::string> An error message if present, or std::nullopt if successful.
 */
std::optional<std::string> create_directory(const std::string& path, bool ignore_if_exists) {
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
                    if (!ignore_if_exists) {
                        return "The path already exists and is not a directory: " + dir_path.string();
                    }
                    break;
                default:
                    return "cannot create directory '" + dir_path.string() + "': " + ec.message();
            }
        }
    }

    return std::nullopt;
}

/**
 * @brief Lua binding for creating a directory path.
 *
 * This function can be called from Lua to create a directory. It returns nil if successful,
 * or an error message if it fails.
 *
 * Lua usage: error_message = lua_mkdir(path, ignore_if_exists)
 *
 * @param L The Lua state.
 * @return int Number of return values (1: error message or nil).
 */
int lua_mkdir(lua_State *L)
{
    int argc = lua_gettop(L);
    if (argc < 1)
    {
        return luaL_error(L, "Expected one argument");
    }
    if (!lua_isstring(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    const char *path = luaL_checkstring(L, 1);
    bool ignore_if_exists = (argc > 1) ? lua_toboolean(L, 2) : false;

    return push_action_result(L, create_directory(path, ignore_if_exists));
}
