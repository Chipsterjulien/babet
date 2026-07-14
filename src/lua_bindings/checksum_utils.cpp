#include "checksum_utils.hpp"
#include "evp_md_ctx_raii.hpp"

#include <openssl/err.h>
#include <openssl/evp.h>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace
{
std::string errno_message(const std::string &prefix, const std::string &path,
                          int error_number)
{
    return prefix + " '" + path + "': " + std::strerror(error_number);
}

std::string openssl_message(const std::string &operation)
{
    const unsigned long code = ERR_get_error();
    if (code == 0)
    {
        return "checksum: " + operation + " failed";
    }

    char buffer[256];
    ERR_error_string_n(code, buffer, sizeof(buffer));
    return "checksum: " + operation + " failed: " + std::string(buffer);
}

class FileDescriptor
{
  public:
    explicit FileDescriptor(int fd) noexcept : fd_(fd) {}
    ~FileDescriptor()
    {
        if (fd_ >= 0)
        {
            ::close(fd_);
        }
    }

    FileDescriptor(const FileDescriptor &) = delete;
    FileDescriptor &operator=(const FileDescriptor &) = delete;

    int get() const noexcept { return fd_; }

  private:
    int fd_;
};
} // namespace

ChecksumResult calculate_checksum_detailed(const std::string &path,
                                           const EVP_MD *md)
{
    if (md == nullptr)
    {
        return {std::nullopt, "checksum: digest algorithm is unavailable"};
    }

    // O_NONBLOCK prevents a path swapped to a FIFO/device between validation
    // and open() from blocking the process. It has no effect on regular files.
    const int raw_fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (raw_fd < 0)
    {
        return {std::nullopt,
                errno_message("cannot open file", path, errno)};
    }
    FileDescriptor fd(raw_fd);

    struct stat info
    {
    };
    if (::fstat(fd.get(), &info) != 0)
    {
        return {std::nullopt,
                errno_message("cannot inspect file", path, errno)};
    }
    if (!S_ISREG(info.st_mode))
    {
        return {std::nullopt,
                "path is not a regular file: " + path};
    }

    ERR_clear_error();
    EVP_MD_CTX_RAII mdctx;
    if (mdctx.get() == nullptr)
    {
        return {std::nullopt, openssl_message("EVP_MD_CTX creation")};
    }
    if (EVP_DigestInit_ex(mdctx.get(), md, nullptr) != 1)
    {
        return {std::nullopt, openssl_message("digest initialization")};
    }

    unsigned char buffer[64 * 1024];
    for (;;)
    {
        const ssize_t count = ::read(fd.get(), buffer, sizeof(buffer));
        if (count > 0)
        {
            if (EVP_DigestUpdate(mdctx.get(), buffer,
                                 static_cast<std::size_t>(count)) != 1)
            {
                return {std::nullopt, openssl_message("digest update")};
            }
            continue;
        }
        if (count == 0)
        {
            break;
        }
        if (errno == EINTR)
        {
            continue;
        }
        return {std::nullopt,
                errno_message("cannot read file", path, errno)};
    }

    unsigned char result[EVP_MAX_MD_SIZE];
    unsigned int result_length = 0;
    if (EVP_DigestFinal_ex(mdctx.get(), result, &result_length) != 1)
    {
        return {std::nullopt, openssl_message("digest finalization")};
    }

    std::ostringstream hexadecimal;
    hexadecimal << std::hex << std::setfill('0');
    for (unsigned int i = 0; i < result_length; ++i)
    {
        hexadecimal << std::setw(2) << static_cast<unsigned int>(result[i]);
    }

    return {hexadecimal.str(), {}};
}

std::optional<std::string> calculate_checksum(const std::string &path,
                                              const EVP_MD *md)
{
    return calculate_checksum_detailed(path, md).value;
}
