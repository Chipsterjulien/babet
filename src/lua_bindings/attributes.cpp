#include "attributes.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
constexpr mode_t MODE_MASK = 07777;

/**
 * @brief Pushes a Lua table {mode, owner, group} on the stack.
 */
void push_attributes(lua_State *L, const struct stat &st)
{
    lua_newtable(L);

    lua_pushstring(L, "mode");
    lua_pushinteger(L, static_cast<lua_Integer>(st.st_mode & MODE_MASK));
    lua_settable(L, -3);

    lua_pushstring(L, "owner");
    lua_pushinteger(L, static_cast<lua_Integer>(st.st_uid));
    lua_settable(L, -3);

    lua_pushstring(L, "group");
    lua_pushinteger(L, static_cast<lua_Integer>(st.st_gid));
    lua_settable(L, -3);
}

std::string errno_message(int value)
{
    return std::generic_category().message(value);
}

/**
 * @brief Changes owner/group, then optionally permissions.
 *
 * POSIX does not provide an atomic chown+chmod primitive. We therefore
 * validate everything before the first mutation and, if chmod fails after a
 * successful chown, make a best-effort rollback to the exact original
 * owner/group/mode. A rollback failure is included in the returned error so
 * the caller is never told that the operation was cleanly reverted when it
 * was not.
 */
std::optional<std::string> set_attributes(const fs::path &path,
                                          uid_t owner,
                                          gid_t group,
                                          std::optional<mode_t> mode)
{
    struct stat original{};
    if (::stat(path.c_str(), &original) != 0)
    {
        return errno_message(errno);
    }

    if (::chown(path.c_str(), owner, group) != 0)
    {
        return errno_message(errno);
    }

    if (!mode)
    {
        return std::nullopt;
    }

    if (::chmod(path.c_str(), *mode) == 0)
    {
        return std::nullopt;
    }

    const int chmod_errno = errno;

    // chown may clear setuid/setgid bits, hence rollback order is owner/group
    // first, then mode, so the original special bits are restored last.
    const bool owner_restored =
        (::chown(path.c_str(), original.st_uid, original.st_gid) == 0);
    const int rollback_chown_errno = owner_restored ? 0 : errno;

    const bool mode_restored =
        (::chmod(path.c_str(), original.st_mode & MODE_MASK) == 0);
    const int rollback_chmod_errno = mode_restored ? 0 : errno;

    std::string message = "chmod failed after chown: ";
    message += errno_message(chmod_errno);

    if (!owner_restored || !mode_restored)
    {
        message += "; rollback incomplete";
        if (!owner_restored)
        {
            message += " (owner/group: ";
            message += errno_message(rollback_chown_errno);
            message += ")";
        }
        if (!mode_restored)
        {
            message += " (mode: ";
            message += errno_message(rollback_chmod_errno);
            message += ")";
        }
    }

    return message;
}
} // namespace

int lua_setattr(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (argc < 3 || argc > 4)
    {
        return luaL_error(L, "Expected three or four arguments");
    }

    const std::string path = luaL_checkstring_without_nul(L, 1, "path");
    const lua_Integer owner_raw = luaL_checkinteger(L, 2);
    const lua_Integer group_raw = luaL_checkinteger(L, 3);

    if (owner_raw < 0 || group_raw < 0)
    {
        return push_fail(L, "UID and GID must be non-negative");
    }

    using uid_limits = std::numeric_limits<uid_t>;
    using gid_limits = std::numeric_limits<gid_t>;
    if (static_cast<unsigned long long>(owner_raw) > uid_limits::max() ||
        static_cast<unsigned long long>(group_raw) > gid_limits::max())
    {
        return push_fail(L, "UID or GID out of range");
    }

    std::optional<mode_t> mode;
    if (argc == 4)
    {
        const lua_Integer mode_raw = luaL_checkinteger(L, 4);
        if (mode_raw < 0 || mode_raw > static_cast<lua_Integer>(MODE_MASK))
        {
            return push_fail(L, "mode must be an integer between 0 and 07777");
        }
        mode = static_cast<mode_t>(mode_raw);
    }

    return push_action_result(
        L, set_attributes(path,
                          static_cast<uid_t>(owner_raw),
                          static_cast<gid_t>(group_raw),
                          mode));
}

int lua_getattr(lua_State *L)
{
    if (lua_gettop(L) != 1 || !lua_isstring(L, 1))
    {
        return luaL_error(L, "Expected one string argument");
    }

    const std::string path = luaL_checkstring_without_nul(L, 1, "path");

    struct stat st{};
    if (::stat(path.c_str(), &st) != 0)
    {
        return push_fail(L, errno_message(errno));
    }

    push_attributes(L, st);
    lua_pushnil(L);
    return 2;
}
