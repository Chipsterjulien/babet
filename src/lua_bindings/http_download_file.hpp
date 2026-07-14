#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

/**
 * Same-directory temporary file used by babet.http.download().
 *
 * The destination parent is opened component by component without following
 * symlinks. Data is written to an O_EXCL temporary inode in that directory,
 * fsynced, then atomically renamed over the destination. Until commit(), the
 * existing destination is untouched. The destructor removes any unfinished
 * temporary file.
 */
class HttpDownloadFile
{
public:
    HttpDownloadFile() = default;
    ~HttpDownloadFile();

    HttpDownloadFile(const HttpDownloadFile &) = delete;
    HttpDownloadFile &operator=(const HttpDownloadFile &) = delete;
    HttpDownloadFile(HttpDownloadFile &&) = delete;
    HttpDownloadFile &operator=(HttpDownloadFile &&) = delete;

    bool open(const std::string &destination, std::uint64_t max_bytes,
              std::string &error);
    bool write(const char *data, std::size_t size);
    bool commit(std::string &error);
    void discard() noexcept;

    [[nodiscard]] std::uint64_t bytes_written() const noexcept
    {
        return bytes_written_;
    }

    [[nodiscard]] bool limit_exceeded() const noexcept
    {
        return limit_exceeded_;
    }

    [[nodiscard]] const std::string &write_error() const noexcept
    {
        return write_error_;
    }

private:
    void cleanup() noexcept;

    int parent_fd_ = -1;
    int file_fd_ = -1;
    std::string destination_;
    std::string leaf_;
    std::string temp_name_;
    std::uint64_t max_bytes_ = 0;
    std::uint64_t bytes_written_ = 0;
    bool limit_exceeded_ = false;
    bool committed_ = false;
    std::string write_error_;
};
