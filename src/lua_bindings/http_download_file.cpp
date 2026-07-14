#include "http_download_file.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <limits>
#include <string>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
    std::atomic<unsigned long long> download_temp_counter{0};

    std::string system_error(const std::string &action,
                             const std::string &path, int error_number)
    {
        return "http: " + action + " '" + path + "': " +
               std::strerror(error_number);
    }

    int open_directory_start(bool absolute, std::string &error)
    {
        const char *start = absolute ? "/" : ".";
        int fd = ::open(start, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd < 0)
        {
            error = system_error("cannot open destination directory", start,
                                 errno);
        }
        return fd;
    }

    bool open_parent_without_symlinks(const fs::path &destination,
                                      int &parent_fd, std::string &leaf,
                                      std::string &error)
    {
        parent_fd = -1;
        leaf = destination.filename().string();
        if (destination.empty() || leaf.empty() || leaf == "." || leaf == "..")
        {
            error = "http: invalid download destination";
            return false;
        }

        fs::path parent = destination.parent_path();
        const bool absolute = destination.is_absolute();
        int current = open_directory_start(absolute, error);
        if (current < 0)
        {
            return false;
        }

        for (const fs::path &component_path : parent)
        {
            const std::string component = component_path.string();
            if (component.empty() || component == "/" || component == ".")
            {
                continue;
            }
            if (component == "..")
            {
                ::close(current);
                error = "http: download destination must not contain '..'";
                return false;
            }

            struct stat st{};
            if (::fstatat(current, component.c_str(), &st,
                          AT_SYMLINK_NOFOLLOW) != 0)
            {
                const int e = errno;
                ::close(current);
                error = system_error("cannot inspect destination directory",
                                     parent.string(), e);
                return false;
            }
            if (S_ISLNK(st.st_mode))
            {
                ::close(current);
                error = "http: download destination contains a symlink "
                        "directory component: '" + parent.string() + "'";
                return false;
            }
            if (!S_ISDIR(st.st_mode))
            {
                ::close(current);
                error = "http: download destination parent is not a directory: '" +
                        parent.string() + "'";
                return false;
            }

            int next = ::openat(current, component.c_str(),
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (next < 0)
            {
                const int e = errno;
                ::close(current);
                if (e == ELOOP)
                {
                    error = "http: download destination contains a symlink "
                            "directory component: '" + parent.string() + "'";
                }
                else
                {
                    error = system_error("cannot open destination directory",
                                         parent.string(), e);
                }
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
        const auto counter =
            download_temp_counter.fetch_add(1, std::memory_order_relaxed);
        return ".babet-download." + std::to_string(::getpid()) + "." +
               std::to_string(counter);
    }
}

HttpDownloadFile::~HttpDownloadFile()
{
    cleanup();
}

bool HttpDownloadFile::open(const std::string &destination,
                            std::uint64_t max_bytes, std::string &error)
{
    cleanup();
    destination_ = destination;
    max_bytes_ = max_bytes;
    bytes_written_ = 0;
    limit_exceeded_ = false;
    committed_ = false;
    write_error_.clear();

    if (!open_parent_without_symlinks(fs::path(destination), parent_fd_, leaf_,
                                      error))
    {
        return false;
    }

    for (int attempt = 0; attempt < 128; ++attempt)
    {
        temp_name_ = make_temp_name();
        file_fd_ = ::openat(parent_fd_, temp_name_.c_str(),
                            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
                                O_NOFOLLOW,
                            0666);
        if (file_fd_ >= 0)
        {
            return true;
        }
        if (errno != EEXIST)
        {
            const int e = errno;
            error = system_error("cannot create temporary download file",
                                 destination_, e);
            cleanup();
            return false;
        }
    }

    error = "http: cannot create a unique temporary download file for '" +
            destination_ + "'";
    cleanup();
    return false;
}

bool HttpDownloadFile::write(const char *data, std::size_t size)
{
    if (file_fd_ < 0 || committed_)
    {
        write_error_ = "http: download file is not open";
        return false;
    }

    if (bytes_written_ > max_bytes_ ||
        static_cast<std::uint64_t>(size) > max_bytes_ - bytes_written_)
    {
        limit_exceeded_ = true;
        return false;
    }

    std::size_t offset = 0;
    while (offset < size)
    {
        const std::size_t remaining = size - offset;
        const std::size_t chunk = std::min<std::size_t>(
            remaining, static_cast<std::size_t>(
                           std::numeric_limits<ssize_t>::max()));
        const ssize_t written = ::write(file_fd_, data + offset, chunk);
        if (written > 0)
        {
            offset += static_cast<std::size_t>(written);
            bytes_written_ += static_cast<std::uint64_t>(written);
            continue;
        }
        if (written < 0 && errno == EINTR)
        {
            continue;
        }

        const int e = (written < 0) ? errno : EIO;
        write_error_ = system_error("cannot write temporary download file",
                                    destination_, e);
        return false;
    }
    return true;
}

bool HttpDownloadFile::commit(std::string &error)
{
    if (file_fd_ < 0 || parent_fd_ < 0 || committed_)
    {
        error = "http: download file is not open";
        return false;
    }

    if (::fsync(file_fd_) != 0)
    {
        error = system_error("cannot sync temporary download file",
                             destination_, errno);
        return false;
    }
    if (::close(file_fd_) != 0)
    {
        const int e = errno;
        file_fd_ = -1;
        error = system_error("cannot close temporary download file",
                             destination_, e);
        return false;
    }
    file_fd_ = -1;

    if (::renameat(parent_fd_, temp_name_.c_str(), parent_fd_, leaf_.c_str()) !=
        0)
    {
        error = system_error("cannot replace download destination",
                             destination_, errno);
        return false;
    }

    committed_ = true;
    temp_name_.clear();
    if (parent_fd_ >= 0)
    {
        ::close(parent_fd_);
        parent_fd_ = -1;
    }
    leaf_.clear();
    destination_.clear();
    return true;
}

void HttpDownloadFile::discard() noexcept
{
    cleanup();
}

void HttpDownloadFile::cleanup() noexcept
{
    if (file_fd_ >= 0)
    {
        ::close(file_fd_);
        file_fd_ = -1;
    }
    if (!committed_ && parent_fd_ >= 0 && !temp_name_.empty())
    {
        ::unlinkat(parent_fd_, temp_name_.c_str(), 0);
    }
    if (parent_fd_ >= 0)
    {
        ::close(parent_fd_);
        parent_fd_ = -1;
    }
    temp_name_.clear();
    leaf_.clear();
    destination_.clear();
}
