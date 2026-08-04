#include "rmdir.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <cstring>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
std::optional<std::string> require_real_directory(std::string_view path)
{
    struct stat status
    {
    };
    const std::string owned(path);
    if (::lstat(owned.c_str(), &status) != 0)
    {
        return "cannot inspect directory '" + owned + "': " +
               std::strerror(errno);
    }
    if (!S_ISDIR(status.st_mode))
    {
        return "path is not a directory: " + owned;
    }
    return std::nullopt;
}
} // namespace

std::optional<std::string> rmdir(std::string_view path)
{
    if (auto error = require_real_directory(path); error)
    {
        return error;
    }

    const std::string owned(path);
    if (::rmdir(owned.c_str()) != 0)
    {
        return "cannot remove directory '" + owned + "': " +
               std::strerror(errno);
    }
    return std::nullopt;
}

std::optional<std::string> rmdir_all(std::string_view path)
{
    if (auto error = require_real_directory(path); error)
    {
        return error;
    }

    std::error_code ec;
    const auto count = fs::remove_all(fs::path(path), ec);
    if (ec)
    {
        return "cannot remove directory '" + std::string(path) + "': " +
               ec.message();
    }
    if (count == 0)
    {
        return "cannot remove directory '" + std::string(path) +
               "': no such file or directory";
    }
    return std::nullopt;
}

int lua_rmdir(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected one argument");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    const std::string path = luaL_checkstring_without_nul(L, 1, "path");
    return push_action_result_protected(L, rmdir(path));
}

int lua_rmdir_all(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected one argument");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    const std::string path = luaL_checkstring_without_nul(L, 1, "path");
    return push_action_result_protected(L, rmdir_all(path));
}
