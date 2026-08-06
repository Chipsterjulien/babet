#include "sqlite_backup_file.hpp"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <string>
#include <system_error>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace babet_sqlite_backup
{
namespace
{
std::atomic<unsigned long long> temp_counter{0};

std::string errno_text(int error_number)
{
    return std::generic_category().message(error_number);
}

std::string quote_path(const std::string &path)
{
    return "'" + path + "'";
}

std::string system_error(const std::string &action,
                         const std::string &path, int error_number)
{
    return "sqlite.backup: " + action + " " + quote_path(path) + ": " +
           errno_text(error_number);
}


bool inspect_regular_destination(int parent_fd, const std::string &leaf,
                                 const std::string &display_path,
                                 bool overwrite, bool &exists,
                                 std::string &error)
{
    exists = false;
    struct stat st{};
    if (::fstatat(parent_fd, leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0)
    {
        exists = true;
        if (S_ISLNK(st.st_mode))
        {
            error = "sqlite.backup: destination must not be a symbolic link: " +
                    quote_path(display_path);
            return false;
        }
        if (!S_ISREG(st.st_mode))
        {
            error = "sqlite.backup: destination is not a regular file: " +
                    quote_path(display_path);
            return false;
        }
        if (!overwrite)
        {
            error = "sqlite.backup: destination already exists: " +
                    quote_path(display_path);
            return false;
        }
        return true;
    }

    const int saved_errno = errno;
    if (saved_errno == ENOENT)
    {
        return true;
    }

    error = system_error("cannot inspect destination", display_path,
                         saved_errno);
    return false;
}

bool reject_sqlite_sidecars(int parent_fd, const std::string &leaf,
                            const std::string &display_path,
                            std::string &error)
{
    static constexpr const char *suffixes[] = {
        "-journal", "-wal", "-shm",
    };

    for (const char *suffix : suffixes)
    {
        const std::string sidecar = leaf + suffix;
        struct stat st{};
        if (::fstatat(parent_fd, sidecar.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) == 0)
        {
            error = "sqlite.backup: destination has an existing SQLite "
                    "sidecar file; close and checkpoint the destination "
                    "before replacing it: " + quote_path(display_path + suffix);
            return false;
        }
        if (errno != ENOENT)
        {
            error = system_error("cannot inspect destination sidecar",
                                 display_path + suffix, errno);
            return false;
        }
    }
    return true;
}

bool same_file_as_source(int parent_fd, const std::string &leaf,
                         const char *source_filename,
                         const std::string &display_path,
                         std::string &error)
{
    if (source_filename == nullptr || source_filename[0] == '\0')
    {
        return false;
    }

    struct stat source_stat{};
    if (::stat(source_filename, &source_stat) != 0)
    {
        return false;
    }

    struct stat destination_stat{};
    if (::fstatat(parent_fd, leaf.c_str(), &destination_stat,
                  AT_SYMLINK_NOFOLLOW) != 0)
    {
        return false;
    }

    if (source_stat.st_dev == destination_stat.st_dev &&
        source_stat.st_ino == destination_stat.st_ino)
    {
        error = "sqlite.backup: destination refers to the source database: " +
                quote_path(display_path);
        return true;
    }
    return false;
}

bool open_parent_without_symlinks(const fs::path &destination,
                                  int &parent_fd, std::string &leaf,
                                  std::string &error)
{
    parent_fd = -1;
    leaf = destination.filename().string();
    if (destination.empty() || leaf.empty() || leaf == "." || leaf == "..")
    {
        error = "sqlite.backup: invalid destination path";
        return false;
    }

    const bool absolute = destination.is_absolute();
    const char *start = absolute ? "/" : ".";
    int current = ::open(start, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (current < 0)
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
            error = "sqlite.backup: destination must not contain '..': " +
                    quote_path(destination.string());
            ::close(current);
            return false;
        }

        traversed /= component;
        struct stat st{};
        if (::fstatat(current, component.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            const int saved_errno = errno;
            error = system_error("cannot inspect destination directory",
                                 traversed.string(), saved_errno);
            ::close(current);
            return false;
        }
        if (S_ISLNK(st.st_mode))
        {
            error = "sqlite.backup: destination contains a symbolic-link "
                    "directory component: " + quote_path(traversed.string());
            ::close(current);
            return false;
        }
        if (!S_ISDIR(st.st_mode))
        {
            error = "sqlite.backup: destination parent component is not a "
                    "directory: " + quote_path(traversed.string());
            ::close(current);
            return false;
        }

        const int next = ::openat(current, component.c_str(),
                                  O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                      O_NOFOLLOW);
        if (next < 0)
        {
            const int saved_errno = errno;
            if (saved_errno == ELOOP)
            {
                error = "sqlite.backup: destination contains a symbolic-link "
                        "directory component: " + quote_path(traversed.string());
            }
            else
            {
                error = system_error("cannot open destination directory",
                                     traversed.string(), saved_errno);
            }
            ::close(current);
            return false;
        }
        ::close(current);
        current = next;
    }

    parent_fd = current;
    return true;
}

std::string make_temp_name()
{
    const unsigned long long serial =
        temp_counter.fetch_add(1, std::memory_order_relaxed);
    return ".babet-sqlite-backup-" +
           std::to_string(static_cast<long long>(::getpid())) + "-" +
           std::to_string(serial);
}

void unlink_companions(int parent_fd, const std::string &temporary) noexcept
{
    if (parent_fd < 0 || temporary.empty())
    {
        return;
    }
    ::unlinkat(parent_fd, (temporary + "-journal").c_str(), 0);
    ::unlinkat(parent_fd, (temporary + "-wal").c_str(), 0);
    ::unlinkat(parent_fd, (temporary + "-shm").c_str(), 0);
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

Destination::~Destination()
{
    cleanup_temporary_best_effort();
    if (temp_fd_ >= 0)
    {
        ::close(temp_fd_);
    }
    if (parent_fd_ >= 0)
    {
        ::close(parent_fd_);
    }
}

void Destination::cleanup_temporary_best_effort() noexcept
{
    if (!published_ && parent_fd_ >= 0 && !temporary_.empty())
    {
        unlink_companions(parent_fd_, temporary_);
        ::unlinkat(parent_fd_, temporary_.c_str(), 0);
    }
}

bool Destination::prepare(const std::string &destination, bool overwrite,
                          const char *source_filename, std::string &error)
{
    error.clear();
    display_path_ = destination;
    overwrite_ = overwrite;

    if (destination.empty())
    {
        error = "sqlite.backup: destination path must not be empty";
        return false;
    }
    if (destination == ":memory:")
    {
        error = "sqlite.backup: destination must be a filesystem path, not "
                "':memory:'";
        return false;
    }

    if (!open_parent_without_symlinks(fs::path(destination), parent_fd_,
                                      leaf_, error))
    {
        return false;
    }

    bool destination_exists = false;
    if (!inspect_regular_destination(parent_fd_, leaf_, display_path_,
                                     true, destination_exists, error))
    {
        return false;
    }

    if (destination_exists &&
        same_file_as_source(parent_fd_, leaf_, source_filename,
                            display_path_, error))
    {
        return false;
    }
    if (destination_exists && !overwrite_)
    {
        error = "sqlite.backup: destination already exists: " +
                quote_path(display_path_);
        return false;
    }

    if (!reject_sqlite_sidecars(parent_fd_, leaf_, display_path_, error))
    {
        return false;
    }

    for (unsigned int attempt = 0; attempt < 128; ++attempt)
    {
        temporary_ = make_temp_name();
        if (temporary_ == leaf_)
        {
            continue;
        }
        temp_fd_ = ::openat(parent_fd_, temporary_.c_str(),
                            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC |
                                O_NOFOLLOW | O_NOCTTY,
                            0600);
        if (temp_fd_ >= 0)
        {
            break;
        }
        if (errno != EEXIST)
        {
            error = system_error("cannot create temporary destination",
                                 display_path_, errno);
            return false;
        }
    }

    if (temp_fd_ < 0)
    {
        error = "sqlite.backup: cannot allocate a unique temporary "
                "destination name for " + quote_path(display_path_);
        return false;
    }

    // Linux-specific, deliberately matching Babet's platform contract. The
    // descriptor pins the already-validated parent directory even if its
    // pathname is concurrently replaced.
    sqlite_path_ = "/proc/self/fd/" + std::to_string(parent_fd_) + "/" +
                   temporary_;
    return true;
}

bool Destination::synchronize(std::string &error)
{
    error.clear();
    if (temp_fd_ < 0)
    {
        error = "sqlite.backup: temporary destination is not open";
        return false;
    }
    if (::fsync(temp_fd_) != 0)
    {
        error = system_error("cannot synchronize temporary destination",
                             display_path_, errno);
        return false;
    }
    return true;
}

bool Destination::publish(std::string &error)
{
    error.clear();
    if (parent_fd_ < 0 || temporary_.empty())
    {
        error = "sqlite.backup: temporary destination is not prepared";
        return false;
    }

    unlink_companions(parent_fd_, temporary_);

    bool destination_exists = false;
    if (!inspect_regular_destination(parent_fd_, leaf_, display_path_,
                                     overwrite_, destination_exists, error))
    {
        return false;
    }
    if (!reject_sqlite_sidecars(parent_fd_, leaf_, display_path_, error))
    {
        return false;
    }

    if (overwrite_)
    {
        if (::renameat(parent_fd_, temporary_.c_str(), parent_fd_,
                       leaf_.c_str()) != 0)
        {
            error = system_error("cannot atomically publish destination",
                                 display_path_, errno);
            return false;
        }
    }
    else
    {
        if (::linkat(parent_fd_, temporary_.c_str(), parent_fd_, leaf_.c_str(),
                     0) != 0)
        {
            if (errno == EEXIST)
            {
                error = "sqlite.backup: destination already exists: " +
                        quote_path(display_path_);
            }
            else
            {
                error = system_error(
                    "cannot publish destination without overwriting",
                    display_path_, errno);
            }
            return false;
        }

        if (::unlinkat(parent_fd_, temporary_.c_str(), 0) != 0)
        {
            const int saved_errno = errno;
            if (same_entry(parent_fd_, temporary_, leaf_))
            {
                ::unlinkat(parent_fd_, leaf_.c_str(), 0);
            }
            error = system_error("cannot remove temporary destination link",
                                 display_path_, saved_errno);
            return false;
        }
    }

    published_ = true;
    temporary_.clear();

    if (::fsync(parent_fd_) != 0)
    {
        error = "sqlite.backup: destination was published atomically but "
                "the destination directory could not be synchronized: " +
                quote_path(display_path_) + ": " + errno_text(errno);
        return false;
    }
    return true;
}

} // namespace babet_sqlite_backup
