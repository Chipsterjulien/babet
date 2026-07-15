#include "attributes.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <fcntl.h>
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

class ScopedFd
{
  public:
    explicit ScopedFd(int fd = -1) noexcept : fd_(fd) {}

    ~ScopedFd()
    {
        if (fd_ >= 0)
        {
            ::close(fd_);
        }
    }

    ScopedFd(const ScopedFd &) = delete;
    ScopedFd &operator=(const ScopedFd &) = delete;

    int get() const noexcept { return fd_; }

  private:
    int fd_;
};

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

std::string proc_fd_path(int fd)
{
    return "/proc/self/fd/" + std::to_string(fd);
}

/**
 * @brief Applies a mode to the inode pinned by an O_PATH descriptor.
 *
 * Linux does not provide fchmod() support for O_PATH descriptors, and
 * fchmodat(..., AT_EMPTY_PATH) is not available on every supported kernel.
 * /proc/self/fd/<n> is a magic link to the already-open file description: it
 * therefore keeps the operation bound to the same inode even if the original
 * pathname is renamed or replaced concurrently.
 */
bool chmod_pinned_fd(int fd, mode_t mode)
{
    const std::string path = proc_fd_path(fd);
    return ::chmod(path.c_str(), mode) == 0;
}

/**
 * @brief Changes owner/group, then optionally permissions on one pinned inode.
 *
 * POSIX does not provide an atomic chown+chmod primitive. The pathname is
 * resolved once with O_PATH (following the documented final symlink), then
 * fstat/fchownat/chmod-through-/proc all operate on that same open file
 * description. If chmod fails after a successful chown, rollback is attempted
 * on the exact same inode rather than resolving the caller's pathname again.
 */
std::optional<std::string> set_attributes(const fs::path &path,
                                          uid_t owner,
                                          gid_t group,
                                          std::optional<mode_t> mode)
{
    ScopedFd fd(::open(path.c_str(), O_PATH | O_CLOEXEC));
    if (fd.get() < 0)
    {
        return errno_message(errno);
    }

    struct stat original{};
    if (::fstat(fd.get(), &original) != 0)
    {
        return errno_message(errno);
    }

    if (::fchownat(fd.get(), "", owner, group, AT_EMPTY_PATH) != 0)
    {
        return errno_message(errno);
    }

    if (!mode)
    {
        return std::nullopt;
    }

    if (chmod_pinned_fd(fd.get(), *mode))
    {
        return std::nullopt;
    }

    const int chmod_errno = errno;

    // chown may clear setuid/setgid bits, hence rollback order is owner/group
    // first, then mode, so the original special bits are restored last.
    const bool owner_restored =
        (::fchownat(fd.get(), "", original.st_uid, original.st_gid,
                    AT_EMPTY_PATH) == 0);
    const int rollback_chown_errno = owner_restored ? 0 : errno;

    const bool mode_restored =
        chmod_pinned_fd(fd.get(), original.st_mode & MODE_MASK);
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

    // Validate every argument that may raise before constructing an owning
    // C++ string. luaL_error uses a non-local jump and would otherwise bypass
    // that string's destructor when UID/GID/mode has the wrong Lua type.
    if (lua_type(L, 1) != LUA_TSTRING)
    {
        return luaL_error(L, "path must be a string");
    }
    if (!lua_isinteger(L, 2))
    {
        return luaL_error(L, "UID must be an integer");
    }
    if (!lua_isinteger(L, 3))
    {
        return luaL_error(L, "GID must be an integer");
    }
    if (argc == 4 && !lua_isinteger(L, 4))
    {
        return luaL_error(L, "mode must be an integer");
    }

    const std::string_view path_view =
        luaL_checkstring_view_without_nul(L, 1, "path");
    const lua_Integer owner_raw = lua_tointeger(L, 2);
    const lua_Integer group_raw = lua_tointeger(L, 3);

    std::optional<mode_t> mode;
    lua_Integer mode_raw = 0;
    if (argc == 4)
    {
        mode_raw = lua_tointeger(L, 4);
    }

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

    if (argc == 4)
    {
        if (mode_raw < 0 || mode_raw > static_cast<lua_Integer>(MODE_MASK))
        {
            return push_fail(L, "mode must be an integer between 0 and 07777");
        }
        mode = static_cast<mode_t>(mode_raw);
    }

    const std::string path(path_view);
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
