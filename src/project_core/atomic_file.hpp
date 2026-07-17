#pragma once

#include <string>
#include <string_view>
#include <sys/types.h>

namespace babet_atomic_file
{
struct Options
{
    bool overwrite = false;
    mode_t permissions = 0644;
    bool durable = true;
};

/**
 * Writes a binary buffer to a same-directory temporary regular file and
 * publishes it atomically at destination.
 *
 * Parent directory components are opened one by one without following
 * symbolic links. Missing parents are not created. The temporary inode is
 * always created privately, then receives the requested final permissions.
 *
 * @return true on success. On failure, returns false and fills error.
 */
bool write_file_atomic(const std::string &destination, std::string_view data,
                       const Options &options, std::string &error);
} // namespace babet_atomic_file
