#include "atomic_file.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <limits>
#include <string>
#include <system_error>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace babet_atomic_file
{
namespace
{
std::atomic<unsigned long long> temp_counter{0};

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

    ScopedFd(ScopedFd &&other) noexcept : fd_(other.fd_)
    {
        other.fd_ = -1;
    }

    ScopedFd &operator=(ScopedFd &&other) noexcept
    {
        if (this != &other)
        {
            if (fd_ >= 0)
            {
                ::close(fd_);
            }
            fd_ = other.fd_;
            other.fd_ = -1;
        }
        return *this;
    }

    [[nodiscard]] int get() const noexcept { return fd_; }

    int release() noexcept
    {
        const int value = fd_;
        fd_ = -1;
        return value;
    }

  private:
    int fd_;
};

std::string errno_text(int error_number)
{
    return std::generic_category().message(error_number);
}

std::string quoted(const std::string &path)
{
    return "'" + path + "'";
}

std::string system_error(const std::string &action,
                         const std::string &path, int error_number)
{
    return "writeFileAtomic: " + action + " " + quoted(path) + ": " +
           errno_text(error_number);
}

bool open_parent_without_symlinks(const fs::path &destination,
                                  ScopedFd &parent_fd, std::string &leaf,
                                  std::string &error)
{
    leaf = destination.filename().string();
    if (destination.empty() || leaf.empty() || leaf == "." || leaf == "..")
    {
        error = "writeFileAtomic: invalid destination path";
        return false;
    }

    const bool absolute = destination.is_absolute();
    const char *start = absolute ? "/" : ".";
    ScopedFd current(::open(start, O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (current.get() < 0)
    {
        error = system_error("cannot open destination directory", start,
                             errno);
        return false;
    }

    const fs::path parent = destination.parent_path();
    fs::path traversed = absolute ? fs::path("/") : fs::path(".");

    for (const fs::path &component_path : parent)
    {
        const std::string component = component_path.string();
        if (component.empty() || component == "/" || component == ".")
        {
            continue;
        }
        if (component == "..")
        {
            error = "writeFileAtomic: destination must not contain '..': " +
                    quoted(destination.string());
            return false;
        }

        traversed /= component;
        struct stat st{};
        if (::fstatat(current.get(), component.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            error = system_error("cannot inspect destination directory",
                                 traversed.string(), errno);
            return false;
        }
        if (S_ISLNK(st.st_mode))
        {
            error = "writeFileAtomic: destination contains a symbolic-link "
                    "directory component: " + quoted(traversed.string());
            return false;
        }
        if (!S_ISDIR(st.st_mode))
        {
            error = "writeFileAtomic: destination parent component is not a "
                    "directory: " + quoted(traversed.string());
            return false;
        }

        ScopedFd next(::openat(current.get(), component.c_str(),
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                   O_NOFOLLOW));
        if (next.get() < 0)
        {
            if (errno == ELOOP)
            {
                error = "writeFileAtomic: destination contains a symbolic-link "
                        "directory component: " + quoted(traversed.string());
            }
            else
            {
                error = system_error("cannot open destination directory",
                                     traversed.string(), errno);
            }
            return false;
        }
        current = std::move(next);
    }

    parent_fd = std::move(current);
    return true;
}

bool inspect_destination(int parent_fd, const std::string &leaf,
                         const std::string &display_path, bool overwrite,
                         std::string &error)
{
    struct stat st{};
    if (::fstatat(parent_fd, leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0)
    {
        if (S_ISLNK(st.st_mode))
        {
            error = "writeFileAtomic: destination must not be a symbolic "
                    "link: " + quoted(display_path);
            return false;
        }
        if (!S_ISREG(st.st_mode))
        {
            error = "writeFileAtomic: destination is not a regular file: " +
                    quoted(display_path);
            return false;
        }
        if (!overwrite)
        {
            error = "writeFileAtomic: destination already exists: " +
                    quoted(display_path);
            return false;
        }
        return true;
    }

    if (errno == ENOENT)
    {
        return true;
    }

    error = system_error("cannot inspect destination", display_path, errno);
    return false;
}

std::string make_temp_name()
{
    const unsigned long long serial =
        temp_counter.fetch_add(1, std::memory_order_relaxed);
    return ".babet-write-" +
           std::to_string(static_cast<long long>(::getpid())) + "-" +
           std::to_string(serial);
}

bool write_all(int fd, std::string_view data, const std::string &destination,
               std::string &error)
{
    std::size_t offset = 0;
    while (offset < data.size())
    {
        const std::size_t remaining = data.size() - offset;
        const std::size_t chunk = std::min<std::size_t>(
            remaining,
            static_cast<std::size_t>(std::numeric_limits<ssize_t>::max()));
        const ssize_t written = ::write(fd, data.data() + offset, chunk);
        if (written > 0)
        {
            offset += static_cast<std::size_t>(written);
            continue;
        }
        if (written < 0 && errno == EINTR)
        {
            continue;
        }

        const int saved_errno = written < 0 ? errno : EIO;
        error = system_error("cannot write temporary destination",
                             destination, saved_errno);
        return false;
    }
    return true;
}

bool same_entry(int parent_fd, const std::string &left,
                const std::string &right) noexcept
{
    struct stat left_stat{};
    struct stat right_stat{};
    if (::fstatat(parent_fd, left.c_str(), &left_stat,
                  AT_SYMLINK_NOFOLLOW) != 0 ||
        ::fstatat(parent_fd, right.c_str(), &right_stat,
                  AT_SYMLINK_NOFOLLOW) != 0)
    {
        return false;
    }
    return left_stat.st_dev == right_stat.st_dev &&
           left_stat.st_ino == right_stat.st_ino;
}
} // namespace

bool write_file_atomic(const std::string &destination, std::string_view data,
                       const Options &options, std::string &error)
{
    error.clear();
    if (destination.empty())
    {
        error = "writeFileAtomic: destination path must not be empty";
        return false;
    }

    ScopedFd parent_fd;
    std::string leaf;
    if (!open_parent_without_symlinks(fs::path(destination), parent_fd, leaf,
                                      error))
    {
        return false;
    }

    if (!inspect_destination(parent_fd.get(), leaf, destination,
                             options.overwrite, error))
    {
        return false;
    }

    std::string temporary;
    ScopedFd temp_fd;
    for (unsigned int attempt = 0; attempt < 128; ++attempt)
    {
        temporary = make_temp_name();
        if (temporary == leaf)
        {
            continue;
        }
        const int fd = ::openat(parent_fd.get(), temporary.c_str(),
                                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
                                    O_NOFOLLOW | O_NOCTTY | O_NONBLOCK,
                                0600);
        if (fd >= 0)
        {
            temp_fd = ScopedFd(fd);
            break;
        }
        if (errno != EEXIST)
        {
            error = system_error("cannot create temporary destination",
                                 destination, errno);
            return false;
        }
    }

    if (temp_fd.get() < 0)
    {
        error = "writeFileAtomic: cannot allocate a unique temporary "
                "destination name for " + quoted(destination);
        return false;
    }

    auto cleanup_temp = [&]() noexcept
    {
        if (!temporary.empty())
        {
            ::unlinkat(parent_fd.get(), temporary.c_str(), 0);
        }
    };

    if (!write_all(temp_fd.get(), data, destination, error))
    {
        cleanup_temp();
        return false;
    }

    if (::fchmod(temp_fd.get(), options.permissions & 0777) != 0)
    {
        error = system_error("cannot set destination permissions",
                             destination, errno);
        cleanup_temp();
        return false;
    }

    if (options.durable && ::fsync(temp_fd.get()) != 0)
    {
        error = system_error("cannot synchronize temporary destination",
                             destination, errno);
        cleanup_temp();
        return false;
    }

    const int fd_to_close = temp_fd.release();
    if (::close(fd_to_close) != 0)
    {
        error = system_error("cannot close temporary destination",
                             destination, errno);
        cleanup_temp();
        return false;
    }

    // Recheck the final entry immediately before publication. This catches
    // ordinary concurrent creations/replacements while linkat below still
    // provides the definitive no-overwrite guarantee.
    if (!inspect_destination(parent_fd.get(), leaf, destination,
                             options.overwrite, error))
    {
        cleanup_temp();
        return false;
    }

    if (options.overwrite)
    {
        if (::renameat(parent_fd.get(), temporary.c_str(), parent_fd.get(),
                       leaf.c_str()) != 0)
        {
            error = system_error("cannot atomically publish destination",
                                 destination, errno);
            cleanup_temp();
            return false;
        }
    }
    else
    {
        if (::linkat(parent_fd.get(), temporary.c_str(), parent_fd.get(),
                     leaf.c_str(), 0) != 0)
        {
            if (errno == EEXIST)
            {
                error = "writeFileAtomic: destination already exists: " +
                        quoted(destination);
            }
            else
            {
                error = system_error(
                    "cannot publish destination without overwriting",
                    destination, errno);
            }
            cleanup_temp();
            return false;
        }

        if (::unlinkat(parent_fd.get(), temporary.c_str(), 0) != 0)
        {
            const int saved_errno = errno;
            if (same_entry(parent_fd.get(), temporary, leaf))
            {
                ::unlinkat(parent_fd.get(), leaf.c_str(), 0);
            }
            error = system_error("cannot remove temporary destination link",
                                 destination, saved_errno);
            cleanup_temp();
            return false;
        }
    }

    temporary.clear();
    if (options.durable && ::fsync(parent_fd.get()) != 0)
    {
        error = "writeFileAtomic: destination was published atomically but "
                "the destination directory could not be synchronized: " +
                quoted(destination) + ": " + errno_text(errno);
        return false;
    }

    return true;
}
} // namespace babet_atomic_file
