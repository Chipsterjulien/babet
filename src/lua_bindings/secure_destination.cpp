#include "secure_destination.hpp"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <string>
#include <system_error>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
    std::atomic<unsigned long long> temp_counter{0};

    std::string destination_error(const fs::path &path,
                                  const std::string &action,
                                  int error_number)
    {
        return action + " '" + path.string() + "': " +
               std::strerror(error_number);
    }

    int duplicate_cloexec(int fd)
    {
#ifdef F_DUPFD_CLOEXEC
        return ::fcntl(fd, F_DUPFD_CLOEXEC, 3);
#else
        int copy = ::dup(fd);
        if (copy >= 0)
        {
            int flags = ::fcntl(copy, F_GETFD, 0);
            if (flags >= 0)
            {
                ::fcntl(copy, F_SETFD, flags | FD_CLOEXEC);
            }
        }
        return copy;
#endif
    }

    bool write_all(int fd, const char *data, std::size_t size,
                   int &error_number)
    {
        std::size_t offset = 0;
        while (offset < size)
        {
            ssize_t written = ::write(fd, data + offset, size - offset);
            if (written > 0)
            {
                offset += static_cast<std::size_t>(written);
                continue;
            }
            if (written < 0 && errno == EINTR)
            {
                continue;
            }
            error_number = (written < 0) ? errno : EIO;
            return false;
        }
        return true;
    }
}

SecureDestination::~SecureDestination()
{
    if (root_fd_ >= 0)
    {
        ::close(root_fd_);
    }
}

SecureDestination::SecureDestination(SecureDestination &&other) noexcept
    : root_fd_(other.root_fd_), root_path_(std::move(other.root_path_))
{
    other.root_fd_ = -1;
}

SecureDestination &
SecureDestination::operator=(SecureDestination &&other) noexcept
{
    if (this != &other)
    {
        if (root_fd_ >= 0)
        {
            ::close(root_fd_);
        }
        root_fd_ = other.root_fd_;
        root_path_ = std::move(other.root_path_);
        other.root_fd_ = -1;
    }
    return *this;
}

std::optional<std::string>
SecureDestination::validate_relative(const fs::path &relative_path) const
{
    if (relative_path.empty() || relative_path.is_absolute())
    {
        return "invalid destination-relative path: '" +
               relative_path.string() + "'";
    }

    for (const fs::path &component : relative_path)
    {
        if (component.empty() || component == fs::path(".") ||
            component == fs::path(".."))
        {
            return "invalid destination-relative path component in '" +
                   relative_path.string() + "'";
        }
    }
    return std::nullopt;
}

std::optional<std::string>
SecureDestination::open_root(const fs::path &root)
{
    if (root_fd_ >= 0)
    {
        ::close(root_fd_);
        root_fd_ = -1;
    }

    std::error_code ec;
    fs::file_status status = fs::symlink_status(root, ec);
    if (ec && ec != std::errc::no_such_file_or_directory)
    {
        return "cannot inspect destination root '" + root.string() +
               "': " + ec.message();
    }

    if (!ec && fs::is_symlink(status))
    {
        return "destination root must not be a symlink: '" +
               root.string() + "'";
    }

    if (ec == std::errc::no_such_file_or_directory ||
        (!ec && !fs::exists(status)))
    {
        ec.clear();
        fs::create_directories(root, ec);
        if (ec)
        {
            return "cannot create destination root '" + root.string() +
                   "': " + ec.message();
        }
    }
    else if (!fs::is_directory(status))
    {
        return "destination root is not a directory: '" +
               root.string() + "'";
    }

    int fd = ::open(root.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                      O_NOFOLLOW);
    if (fd < 0)
    {
        return destination_error(root, "cannot securely open destination root",
                                 errno);
    }

    root_fd_ = fd;
    root_path_ = root;
    return std::nullopt;
}

std::optional<std::string>
SecureDestination::open_parent(const fs::path &relative_path,
                               int &parent_fd, std::string &leaf,
                               bool create_parents) const
{
    parent_fd = -1;
    leaf.clear();

    if (root_fd_ < 0)
    {
        return "destination root is not open";
    }
    if (auto invalid = validate_relative(relative_path); invalid)
    {
        return invalid;
    }

    fs::path normalized = relative_path.lexically_normal();
    fs::path parent = normalized.parent_path();
    leaf = normalized.filename().string();
    if (leaf.empty())
    {
        return "invalid empty destination filename in '" +
               relative_path.string() + "'";
    }

    int current = duplicate_cloexec(root_fd_);
    if (current < 0)
    {
        return destination_error(root_path_,
                                 "cannot duplicate destination root descriptor",
                                 errno);
    }

    for (const fs::path &component_path : parent)
    {
        const std::string component = component_path.string();
        struct stat st{};
        if (::fstatat(current, component.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            if (errno != ENOENT || !create_parents)
            {
                int e = errno;
                ::close(current);
                return destination_error(root_path_ / parent,
                                         "cannot inspect destination component",
                                         e);
            }

            if (::mkdirat(current, component.c_str(), 0777) != 0 &&
                errno != EEXIST)
            {
                int e = errno;
                ::close(current);
                return destination_error(root_path_ / parent,
                                         "cannot create destination directory",
                                         e);
            }

            if (::fstatat(current, component.c_str(), &st,
                          AT_SYMLINK_NOFOLLOW) != 0)
            {
                int e = errno;
                ::close(current);
                return destination_error(root_path_ / parent,
                                         "cannot inspect created destination directory",
                                         e);
            }
        }

        if (S_ISLNK(st.st_mode))
        {
            ::close(current);
            return "destination contains a symlink component: '" +
                   (root_path_ / parent).string() + "'";
        }
        if (!S_ISDIR(st.st_mode))
        {
            ::close(current);
            return "destination component is not a directory: '" +
                   (root_path_ / parent).string() + "'";
        }

        int next = ::openat(current, component.c_str(),
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (next < 0)
        {
            int e = errno;
            ::close(current);
            if (e == ELOOP)
            {
                return "destination contains a symlink component: '" +
                       (root_path_ / parent).string() + "'";
            }
            return destination_error(root_path_ / parent,
                                     "cannot securely open destination directory",
                                     e);
        }
        ::close(current);
        current = next;
    }

    parent_fd = current;
    return std::nullopt;
}

std::optional<std::string>
SecureDestination::ensure_directory(const fs::path &relative_path)
{
    if (auto invalid = validate_relative(relative_path); invalid)
    {
        return invalid;
    }

    int current = duplicate_cloexec(root_fd_);
    if (current < 0)
    {
        return destination_error(root_path_,
                                 "cannot duplicate destination root descriptor",
                                 errno);
    }

    fs::path traversed;
    for (const fs::path &component_path : relative_path.lexically_normal())
    {
        const std::string component = component_path.string();
        traversed /= component_path;

        struct stat st{};
        if (::fstatat(current, component.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            if (errno != ENOENT)
            {
                int e = errno;
                ::close(current);
                return destination_error(root_path_ / traversed,
                                         "cannot inspect destination directory",
                                         e);
            }
            if (::mkdirat(current, component.c_str(), 0777) != 0 &&
                errno != EEXIST)
            {
                int e = errno;
                ::close(current);
                return destination_error(root_path_ / traversed,
                                         "cannot create destination directory",
                                         e);
            }
            if (::fstatat(current, component.c_str(), &st,
                          AT_SYMLINK_NOFOLLOW) != 0)
            {
                int e = errno;
                ::close(current);
                return destination_error(root_path_ / traversed,
                                         "cannot inspect created destination directory",
                                         e);
            }
        }

        if (S_ISLNK(st.st_mode))
        {
            ::close(current);
            return "destination contains a symlink component: '" +
                   (root_path_ / traversed).string() + "'";
        }
        if (!S_ISDIR(st.st_mode))
        {
            ::close(current);
            return "destination component is not a directory: '" +
                   (root_path_ / traversed).string() + "'";
        }

        int next = ::openat(current, component.c_str(),
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (next < 0)
        {
            int e = errno;
            ::close(current);
            if (e == ELOOP)
            {
                return "destination contains a symlink component: '" +
                       (root_path_ / traversed).string() + "'";
            }
            return destination_error(root_path_ / traversed,
                                     "cannot securely open destination directory",
                                     e);
        }
        ::close(current);
        current = next;
    }

    ::close(current);
    return std::nullopt;
}

std::optional<std::string>
SecureDestination::copy_regular_file(
    const fs::path &source, const fs::path &relative_destination)
{
    int source_fd = ::open(source.c_str(), O_RDONLY | O_CLOEXEC);
    if (source_fd < 0)
    {
        return destination_error(source, "cannot open source file", errno);
    }

    struct stat source_stat{};
    if (::fstat(source_fd, &source_stat) != 0)
    {
        int e = errno;
        ::close(source_fd);
        return destination_error(source, "cannot inspect source file", e);
    }
    if (!S_ISREG(source_stat.st_mode))
    {
        ::close(source_fd);
        return "source is not a regular file: '" + source.string() + "'";
    }

    int parent_fd = -1;
    std::string leaf;
    if (auto error = open_parent(relative_destination, parent_fd, leaf, true);
        error)
    {
        ::close(source_fd);
        return error;
    }

    struct stat existing{};
    int destination_stat = ::fstatat(parent_fd, leaf.c_str(), &existing,
                                     AT_SYMLINK_NOFOLLOW);
    if (destination_stat == 0 && S_ISLNK(existing.st_mode))
    {
        ::close(parent_fd);
        ::close(source_fd);
        return "destination file must not be a symlink: '" +
               (root_path_ / relative_destination).string() + "'";
    }
    if (destination_stat != 0 && errno != ENOENT)
    {
        int e = errno;
        ::close(parent_fd);
        ::close(source_fd);
        return destination_error(root_path_ / relative_destination,
                                 "cannot inspect destination file", e);
    }

    std::string temp_name;
    int temp_fd = -1;
    for (int attempt = 0; attempt < 32; ++attempt)
    {
        unsigned long long id = temp_counter.fetch_add(1,
                                                        std::memory_order_relaxed);
        temp_name = ".babet-copy-" + std::to_string(::getpid()) + "-" +
                    std::to_string(id);
        temp_fd = ::openat(parent_fd, temp_name.c_str(),
                           O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
                               O_NOFOLLOW,
                           0600);
        if (temp_fd >= 0 || errno != EEXIST)
        {
            break;
        }
    }
    if (temp_fd < 0)
    {
        int e = errno;
        ::close(parent_fd);
        ::close(source_fd);
        return destination_error(root_path_ / relative_destination,
                                 "cannot create temporary destination file",
                                 e);
    }

    auto cleanup_temp = [&]()
    {
        ::close(temp_fd);
        ::unlinkat(parent_fd, temp_name.c_str(), 0);
        ::close(parent_fd);
        ::close(source_fd);
    };

    char buffer[64 * 1024];
    for (;;)
    {
        ssize_t got = ::read(source_fd, buffer, sizeof(buffer));
        if (got > 0)
        {
            int e = 0;
            if (!write_all(temp_fd, buffer, static_cast<std::size_t>(got), e))
            {
                cleanup_temp();
                return destination_error(root_path_ / relative_destination,
                                         "cannot write destination file", e);
            }
            continue;
        }
        if (got == 0)
        {
            break;
        }
        if (errno == EINTR)
        {
            continue;
        }
        int e = errno;
        cleanup_temp();
        return destination_error(source, "cannot read source file", e);
    }

    if (::fchmod(temp_fd, source_stat.st_mode & 0777) != 0)
    {
        int e = errno;
        cleanup_temp();
        return destination_error(root_path_ / relative_destination,
                                 "cannot apply destination file mode", e);
    }

    if (::close(temp_fd) != 0)
    {
        int e = errno;
        temp_fd = -1;
        ::unlinkat(parent_fd, temp_name.c_str(), 0);
        ::close(parent_fd);
        ::close(source_fd);
        return destination_error(root_path_ / relative_destination,
                                 "cannot close destination file", e);
    }
    temp_fd = -1;

    if (::renameat(parent_fd, temp_name.c_str(), parent_fd,
                   leaf.c_str()) != 0)
    {
        int e = errno;
        ::unlinkat(parent_fd, temp_name.c_str(), 0);
        ::close(parent_fd);
        ::close(source_fd);
        return destination_error(root_path_ / relative_destination,
                                 "cannot publish destination file", e);
    }

    ::close(parent_fd);
    ::close(source_fd);
    return std::nullopt;
}

std::optional<std::string>
SecureDestination::move_entry(const fs::path &source,
                              const fs::path &relative_destination)
{
    int parent_fd = -1;
    std::string leaf;
    if (auto error = open_parent(relative_destination, parent_fd, leaf, true);
        error)
    {
        return error;
    }

    struct stat existing{};
    int stat_result = ::fstatat(parent_fd, leaf.c_str(), &existing,
                                AT_SYMLINK_NOFOLLOW);
    if (stat_result == 0 && S_ISLNK(existing.st_mode))
    {
        ::close(parent_fd);
        return "destination entry must not be a symlink: '" +
               (root_path_ / relative_destination).string() + "'";
    }
    if (stat_result != 0 && errno != ENOENT)
    {
        int e = errno;
        ::close(parent_fd);
        return destination_error(root_path_ / relative_destination,
                                 "cannot inspect destination entry", e);
    }

    if (::renameat(AT_FDCWD, source.c_str(), parent_fd, leaf.c_str()) == 0)
    {
        ::close(parent_fd);
        return std::nullopt;
    }

    int rename_error = errno;
    ::close(parent_fd);
    if (rename_error != EXDEV)
    {
        return destination_error(root_path_ / relative_destination,
                                 "cannot move source entry", rename_error);
    }

    if (auto error = copy_regular_file(source, relative_destination); error)
    {
        return error;
    }
    if (::unlink(source.c_str()) != 0)
    {
        return destination_error(source,
                                 "cannot remove source file after copy", errno);
    }
    return std::nullopt;
}

std::optional<std::string>
SecureDestination::create_symlink(
    const fs::path &target, const fs::path &relative_destination)
{
    int parent_fd = -1;
    std::string leaf;
    if (auto error = open_parent(relative_destination, parent_fd, leaf, true);
        error)
    {
        return error;
    }

    if (::symlinkat(target.c_str(), parent_fd, leaf.c_str()) != 0)
    {
        int e = errno;
        ::close(parent_fd);
        return destination_error(root_path_ / relative_destination,
                                 "cannot create destination symlink", e);
    }

    ::close(parent_fd);
    return std::nullopt;
}

void SecureDestination::remove_entry_best_effort(
    const fs::path &relative_destination) noexcept
{
    int parent_fd = -1;
    std::string leaf;
    if (open_parent(relative_destination, parent_fd, leaf, false))
    {
        return;
    }
    ::unlinkat(parent_fd, leaf.c_str(), 0);
    ::close(parent_fd);
}
