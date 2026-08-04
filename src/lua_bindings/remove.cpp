#include "remove.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace
{
std::string system_error(const std::string &prefix, const std::string &path,
                         int error_number)
{
    return prefix + " '" + path + "': " + std::strerror(error_number);
}
} // namespace

std::string remove_file(const std::string &path)
{
    struct stat status
    {
    };
    if (::lstat(path.c_str(), &status) != 0)
    {
        return system_error("cannot inspect file", path, errno);
    }

    // remove() is deliberately the non-directory primitive. lstat() means a
    // symlink to a directory, including a dangling symlink, is still removed
    // as a symlink rather than followed.
    if (S_ISDIR(status.st_mode))
    {
        return "path is a directory; use rmdir or rmdirAll: " + path;
    }
    if (!S_ISREG(status.st_mode) && !S_ISLNK(status.st_mode))
    {
        return "path is neither a regular file nor a symlink: " + path;
    }

    if (::unlink(path.c_str()) != 0)
    {
        return system_error("cannot remove file", path, errno);
    }
    return {};
}

int lua_remove_file(lua_State *L)
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
    const std::string error_message = remove_file(path);
    if (error_message.empty())
    {
        return push_ok(L);
    }
    return push_fail_protected(L, error_message);
}
