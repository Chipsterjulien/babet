#include "fileSize.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <system_error>
#include <limits>

namespace fs = std::filesystem;

/**
 * @brief Check if a file exists and is a regular file, and get its size.
 *
 * This legacy C++ helper keeps its boolean contract. The Lua binding below
 * performs the same operation directly so it can preserve the precise system
 * error instead of collapsing EACCES/EIO into "path does not exist".
 *
 * @param path The file path to check.
 * @param size Reference to store the size of the file if successful.
 * @return bool True on success, false otherwise.
 */
bool getFileSize(std::string_view path, uintmax_t &size)
{
    std::error_code ec;
    const fs::file_status status = fs::status(fs::path(path), ec);
    if (ec || !fs::is_regular_file(status))
    {
        return false;
    }

    size = fs::file_size(fs::path(path), ec);
    return !ec;
}

/**
 * @brief Lua binding for getting the size of a regular file.
 *
 * @param L The Lua state.
 * @return int Number of return values (2: size/nil, err/nil).
 */
int lua_fileSize(lua_State *L)
{
    if (!lua_arity_is(L, 1) || !lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected one string argument");
    }

    const std::string path =
        luaL_checkstring_without_nul(L, 1, "path");
    const fs::path file_path(path);

    std::error_code ec;
    const fs::file_status status = fs::status(file_path, ec);
    if (ec)
    {
        if (ec == std::errc::no_such_file_or_directory ||
            ec == std::errc::not_a_directory)
        {
            return push_fail(L, "path does not exist");
        }
        return push_fail(L, "cannot inspect file '" + path + "': " +
                                ec.message());
    }

    if (!fs::is_regular_file(status))
    {
        return push_fail(L, "path is not a regular file");
    }

    const uintmax_t size = fs::file_size(file_path, ec);
    if (ec)
    {
        return push_fail(L, "cannot get size of file '" + path + "': " +
                                ec.message());
    }

    if (size > static_cast<uintmax_t>(
                   std::numeric_limits<lua_Integer>::max()))
    {
        return push_fail(L, "file size is out of Lua integer range");
    }

    lua_pushinteger(L, static_cast<lua_Integer>(size));
    lua_pushnil(L);
    return 2;
}
