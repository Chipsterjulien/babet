#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace babet::archive_tar
{
enum class Compression
{
    none,
    gzip,
    xz,
    bzip2,
    zstd,
};

enum class EntryType
{
    regular,
    directory,
    symlink,
    hardlink,
    fifo,
    character_device,
    block_device,
    socket,
    unsupported,
};

struct ScanLimits
{
    std::uint64_t max_entries;
    std::uint64_t max_entry_size;
    std::uint64_t max_total_size;
    std::uint64_t max_path_length;
    std::uint64_t max_total_name_bytes;
    double max_compression_ratio;
};

struct Entry
{
    std::string name;
    EntryType type = EntryType::unsupported;
    std::uint64_t size = 0;
    std::uint32_t unix_mode = 0;
    bool has_unix_mode = false;
    std::int64_t mtime = 0;
    long mtime_nsec = 0;
    bool has_mtime = false;
    std::int64_t uid = 0;
    std::int64_t gid = 0;
    bool has_uid = false;
    bool has_gid = false;
    bool sparse = false;
    bool has_link_target = false;
    std::string link_target;
};

struct ScanResult
{
    std::vector<Entry> entries;
    Compression compression = Compression::none;
    std::uint64_t total_size = 0;
    std::uint64_t total_name_bytes = 0;
    std::uint64_t archive_size = 0;
};

struct CreateEntry
{
    std::string name;
    bool directory = false;
    std::uint64_t size = 0;
    std::int64_t modified_seconds = 0;
    long modified_nanoseconds = 0;
};

class CreationSource
{
public:
    virtual ~CreationSource() = default;

    [[nodiscard]] virtual bool begin_file(std::size_t index,
                                          const CreateEntry &entry,
                                          std::string &err) = 0;
    [[nodiscard]] virtual bool read_file_block(void *buffer,
                                               std::size_t capacity,
                                               std::size_t &size,
                                               std::string &err) = 0;
    [[nodiscard]] virtual bool finish_file(std::size_t index,
                                           const CreateEntry &entry,
                                           std::string &err) = 0;
    virtual void abort_file() noexcept = 0;
};

class ExtractionSink
{
public:
    virtual ~ExtractionSink() = default;

    /**
     * Return true when the regular file at index must be forwarded to this
     * sink. Unselected regular files are still consumed and validated, but
     * their data is discarded.
     */
    [[nodiscard]] virtual bool wants_file(std::size_t index,
                                          const Entry &entry) const noexcept = 0;

    [[nodiscard]] virtual bool begin_file(std::size_t index,
                                          const Entry &entry,
                                          std::string &err) = 0;
    [[nodiscard]] virtual bool write_file_block(std::size_t index,
                                                const Entry &entry,
                                                std::uint64_t offset,
                                                const void *data,
                                                std::size_t size,
                                                std::string &err) = 0;
    [[nodiscard]] virtual bool finish_file(std::size_t index,
                                           const Entry &entry,
                                           std::string &err) = 0;
    virtual void abort_file() noexcept = 0;
};

/**
 * Inspect a TAR stream, optionally wrapped in gzip, xz, bzip2 or zstd, from an already-open
 * regular-file descriptor. The descriptor remains owned by the caller and must be
 * positioned at offset zero.
 *
 * Only the built-in "none", gzip, xz, bzip2 and zstd filters are enabled. No
 * external decompressor is permitted. Babet independently validates gzip
 * CRC/ISIZE with zlib because libarchive does not verify those trailer fields,
 * and validates complete zstd frame streams with libzstd before publication.
 * Other compressed TAR streams remain rejected.
 */
[[nodiscard]] bool scan_fd(int fd, std::uint64_t archive_size,
                           const std::string &display_path,
                           const ScanLimits &limits,
                           ScanResult &result, std::string &err);

/**
 * Re-read and extract the regular files of an already-scanned TAR stream.
 * Every header is compared with expected_entries before its data is optionally
 * forwarded to the sink, so a changed archive is rejected
 * before the corresponding entry is staged. Regular files not selected by
 * wants_file() are still consumed and validated.
 *
 * The descriptor remains owned by the caller and must refer to the same
 * regular file that was scanned. A sparse file is refused when selected by the
 * sink, while an unselected sparse member is consumed and validated.
 * Directories and all special types are consumed but never sent to the sink;
 * callers decide which entry set must be extractable before invoking this
 * function.
 */
[[nodiscard]] bool extract_fd(int fd, std::uint64_t archive_size,
                              const std::string &display_path,
                              const ScanLimits &limits,
                              Compression expected_compression,
                              const std::vector<Entry> &expected_entries,
                              ExtractionSink &sink, std::string &err);

/**
 * Create a POSIX pax TAR stream, optionally wrapped in gzip, xz, bzip2 or zstd, on an already-open
 * regular-file descriptor. Entry order is supplied by the caller and is preserved exactly.
 * The descriptor remains owned by the caller and is not closed.
 *
 * deterministic=true writes timestamp zero for every entry; otherwise the
 * supplied nanosecond-resolution modification times are emitted. Ownership,
 * ACLs, xattrs and source permission bits are intentionally not copied.
 */
[[nodiscard]] bool create_fd(int fd, const std::string &display_path,
                             const std::vector<CreateEntry> &entries,
                             Compression compression, int compression_level,
                             bool deterministic, CreationSource &source,
                             std::string &err);
}
