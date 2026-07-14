#ifndef CHECKSUM_UTILS_HPP
#define CHECKSUM_UTILS_HPP

#include <openssl/evp.h>
#include <optional>
#include <string>

struct ChecksumResult
{
    std::optional<std::string> value;
    std::string error;
};

/**
 * Calculates a checksum while preserving a precise filesystem/OpenSSL error.
 * Only regular files are accepted. Symbolic links to regular files remain
 * supported because the opened descriptor is validated with fstat().
 */
ChecksumResult calculate_checksum_detailed(const std::string &path,
                                           const EVP_MD *md);

/** Backward-compatible C++ helper used by the algorithm-specific wrappers. */
std::optional<std::string> calculate_checksum(const std::string &path,
                                              const EVP_MD *md);

#endif // CHECKSUM_UTILS_HPP
