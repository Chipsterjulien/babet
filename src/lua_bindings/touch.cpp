#include "touch.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <fcntl.h>
#include <filesystem>
#include <string>
#include <sys/stat.h>
#include <system_error>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
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

std::string errno_message(int value)
{
    return std::generic_category().message(value);
}

std::string proc_fd_path(int fd)
{
    return "/proc/self/fd/" + std::to_string(fd);
}

std::string touch_pinned_fd(int fd, const std::string &display_path)
{
    const std::string pinned_path = proc_fd_path(fd);
    if (::utimensat(AT_FDCWD, pinned_path.c_str(), nullptr, 0) != 0)
    {
        return "cannot update timestamp of '" + display_path + "': " +
               errno_message(errno);
    }
    return "";
}
} // namespace

/**
 * Function to create or update a path (à la `touch`).
 *
 * The parent directory is opened once and pinned. Existing entries are opened
 * with O_PATH, which neither reads their contents nor blocks on FIFOs/devices.
 * Their timestamp is then changed through /proc/self/fd/<n>, keeping the
 * operation attached to the same inode even if the pathname is concurrently
 * replaced. Missing files are created atomically with O_CREAT|O_EXCL: no path
 * is ever opened with O_TRUNC, so a file appearing in the race window cannot
 * be emptied.
 *
 * A valid final symlink is followed, matching the historical/Unix behavior.
 * A dangling final symlink is refused because safely creating its missing
 * target would require resolving the link again through a mutable pathname.
 */
std::string touch(const std::string &path)
{
    if (path.empty())
    {
        return "path cannot be empty";
    }

    const fs::path fs_path(path);
    const fs::path basename = fs_path.filename();

    // A trailing slash (or root such as "/") has no basename and therefore
    // cannot name a new regular file. It may still designate an existing path,
    // which O_PATH can safely pin and touch.
    if (basename.empty())
    {
        ScopedFd existing(::open(path.c_str(), O_PATH | O_CLOEXEC));
        if (existing.get() < 0)
        {
            return "cannot open '" + path + "': " + errno_message(errno);
        }
        return touch_pinned_fd(existing.get(), path);
    }

    const fs::path parent = fs_path.parent_path().empty()
                                ? fs::path(".")
                                : fs_path.parent_path();
    ScopedFd parent_fd(
        ::open(parent.c_str(), O_PATH | O_DIRECTORY | O_CLOEXEC));
    if (parent_fd.get() < 0)
    {
        if (errno == ENOENT)
        {
            return "Parent directory does not exist: " + parent.string();
        }
        return "cannot open parent directory '" + parent.string() + "': " +
               errno_message(errno);
    }

    const std::string name = basename.string();
    constexpr int MAX_RACE_RETRIES = 16;

    for (int attempt = 0; attempt < MAX_RACE_RETRIES; ++attempt)
    {
        ScopedFd existing(
            ::openat(parent_fd.get(), name.c_str(), O_PATH | O_CLOEXEC));
        if (existing.get() >= 0)
        {
            return touch_pinned_fd(existing.get(), path);
        }

        const int open_errno = errno;
        if (open_errno != ENOENT)
        {
            return "cannot open '" + path + "': " +
                   errno_message(open_errno);
        }

        ScopedFd created(::openat(parent_fd.get(), name.c_str(),
                                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                                      O_NOCTTY | O_NONBLOCK | O_CLOEXEC,
                                  0666));
        if (created.get() >= 0)
        {
            return "";
        }

        const int create_errno = errno;
        if (create_errno != EEXIST)
        {
            return "Failed to create the file: " + path + ": " +
                   errno_message(create_errno);
        }

        struct stat link_stat{};
        if (::fstatat(parent_fd.get(), name.c_str(), &link_stat,
                      AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISLNK(link_stat.st_mode))
        {
            return "cannot touch dangling symbolic link: " + path;
        }

        // Another actor created a non-symlink entry after our O_PATH lookup.
        // Retry and pin that entry; O_EXCL guarantees it was never truncated.
    }

    return "path changed repeatedly while touching: " + path;
}

/**
 * Lua binding for the touch function.
 * @param L The Lua state.
 * @return Number of return values (2: ok/nil, err/nil).
 * Lua usage: ok, err = babet.touch(path)
 *   - path: The file path to touch.
 */
int lua_touch(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_argerror(L, 1, "Expected one argument: string path");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_argerror(L, 1, "Expected a string as argument");
    }

    const std::string path = luaL_checkstring_without_nul(L, 1, "path");
    const std::string error_message = touch(path);
    if (error_message.empty())
    {
        return push_ok(L);
    }
    return push_fail_protected(L, error_message);
}
