#pragma once

#include <string>

namespace babet_sqlite_backup
{

// Owns a same-directory temporary file and publishes it atomically as a
// SQLite backup destination. Parent directories and final entries are opened
// and inspected without following symbolic links. The published inode keeps
// the temporary file's private 0600 permissions.
class Destination
{
public:
    Destination() = default;
    ~Destination();

    Destination(const Destination &) = delete;
    Destination &operator=(const Destination &) = delete;

    bool prepare(const std::string &destination, bool overwrite,
                 const char *source_filename, std::string &error);

    [[nodiscard]] const std::string &sqlite_path() const noexcept
    {
        return sqlite_path_;
    }

    bool synchronize(std::string &error);
    bool publish(std::string &error);

private:
    int parent_fd_ = -1;
    int temp_fd_ = -1;
    bool overwrite_ = false;
    bool published_ = false;
    std::string display_path_;
    std::string leaf_;
    std::string temporary_;
    std::string sqlite_path_;

    void cleanup_temporary_best_effort() noexcept;
};

} // namespace babet_sqlite_backup
