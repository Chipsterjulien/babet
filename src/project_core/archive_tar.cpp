#include "archive_tar.hpp"

#include <archive.h>
#include <archive_entry.h>
#include <zlib.h>
#include <zstd.h>

#include <array>
#include <cerrno>
#include <ctime>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <utility>

#include <sys/stat.h>
#include <unistd.h>

namespace babet::archive_tar
{
namespace
{
constexpr std::size_t READ_BLOCK_SIZE = 64U * 1024U;
constexpr std::uint64_t COMPRESSED_METADATA_HEADROOM_PER_ENTRY = 64U * 1024U;
constexpr std::uint64_t COMPRESSED_FIXED_HEADROOM = 1024U * 1024U;

class ArchiveHandle
{
public:
    ArchiveHandle() : value_(archive_read_new()) {}

    ~ArchiveHandle()
    {
        if (value_ != nullptr)
        {
            archive_read_free(value_);
        }
    }

    ArchiveHandle(const ArchiveHandle &) = delete;
    ArchiveHandle &operator=(const ArchiveHandle &) = delete;

    [[nodiscard]] archive *get() const noexcept { return value_; }

private:
    archive *value_ = nullptr;
};

std::string archive_detail(archive *reader)
{
    const char *detail = archive_error_string(reader);
    return detail == nullptr || *detail == '\0' ? "unknown libarchive error"
                                                 : std::string(detail);
}

std::string operation_error(archive *reader, const std::string &action,
                            const std::string &path)
{
    return "archive: " + action + " '" + path + "': " +
           archive_detail(reader);
}

bool verify_source_size(int fd, std::uint64_t archive_size,
                        const std::string &display_path,
                        const char *phase, std::string &err)
{
    struct stat st{};
    if (::fstat(fd, &st) != 0)
    {
        err = "archive: cannot inspect TAR source " + std::string(phase) +
              " '" + display_path + "': " + std::strerror(errno);
        return false;
    }
    if (!S_ISREG(st.st_mode) || st.st_size < 0)
    {
        err = "archive: TAR source changed to an invalid filesystem type " +
              std::string(phase) + ": '" + display_path + "'";
        return false;
    }
    if (static_cast<std::uint64_t>(st.st_size) != archive_size)
    {
        err = "archive: TAR source size changed " + std::string(phase) +
              ": '" + display_path + "'";
        return false;
    }
    return true;
}

bool checked_add_u64(std::uint64_t left, std::uint64_t right,
                     std::uint64_t &result) noexcept
{
    if (right > std::numeric_limits<std::uint64_t>::max() - left)
    {
        return false;
    }
    result = left + right;
    return true;
}

bool compressed_raw_stream_limit(const ScanLimits &limits, std::uint64_t &result,
                           std::string &err)
{
    if (limits.max_entries >
        std::numeric_limits<std::uint64_t>::max() /
            COMPRESSED_METADATA_HEADROOM_PER_ENTRY)
    {
        err = "archive: compressed TAR validation limit overflow";
        return false;
    }
    const std::uint64_t per_entry =
        limits.max_entries * COMPRESSED_METADATA_HEADROOM_PER_ENTRY;

    result = limits.max_total_size;
    if (!checked_add_u64(result, limits.max_total_name_bytes, result) ||
        !checked_add_u64(result, per_entry, result) ||
        !checked_add_u64(result, COMPRESSED_FIXED_HEADROOM, result))
    {
        err = "archive: compressed TAR validation limit overflow";
        return false;
    }
    return true;
}

bool validate_one_gzip_member(int fd, std::uint64_t archive_size,
                              std::uint64_t start_offset,
                              std::uint64_t raw_limit,
                              std::uint64_t &raw_total,
                              std::uint64_t &next_offset,
                              const std::string &display_path,
                              std::string &err)
{
    z_stream stream{};
    const int init_status = inflateInit2(&stream, 16 + MAX_WBITS);
    if (init_status != Z_OK)
    {
        err = "archive: cannot initialise gzip validation for '" +
              display_path + "'";
        return false;
    }

    std::array<unsigned char, READ_BLOCK_SIZE> input{};
    std::array<unsigned char, READ_BLOCK_SIZE> output{};
    std::uint64_t read_offset = start_offset;
    bool success = false;

    for (;;)
    {
        if (stream.avail_in == 0)
        {
            if (read_offset >= archive_size)
            {
                err = "archive: truncated gzip stream in '" + display_path +
                      "'";
                break;
            }
            const std::uint64_t remaining = archive_size - read_offset;
            const std::size_t wanted = static_cast<std::size_t>(
                std::min<std::uint64_t>(remaining, input.size()));
            const ssize_t count = ::pread(fd, input.data(), wanted,
                                          static_cast<off_t>(read_offset));
            if (count < 0)
            {
                err = "archive: cannot read gzip stream '" + display_path +
                      "': " + std::strerror(errno);
                break;
            }
            if (count == 0)
            {
                err = "archive: truncated gzip stream in '" + display_path +
                      "'";
                break;
            }
            const auto supplied = static_cast<std::size_t>(count);
            read_offset += supplied;
            stream.next_in = input.data();
            stream.avail_in = static_cast<uInt>(supplied);
        }

        stream.next_out = output.data();
        stream.avail_out = static_cast<uInt>(output.size());
        const int status = inflate(&stream, Z_NO_FLUSH);
        const std::uint64_t produced = output.size() - stream.avail_out;
        if (raw_total > raw_limit || produced > raw_limit - raw_total)
        {
            err = "archive: gzip-compressed TAR expands beyond its internal "
                  "raw-stream limit";
            break;
        }
        raw_total += produced;

        if (status == Z_STREAM_END)
        {
            next_offset = read_offset - stream.avail_in;
            success = true;
            break;
        }
        if (status != Z_OK)
        {
            const char *detail = stream.msg;
            err = "archive: invalid gzip stream '" + display_path + "'";
            if (detail != nullptr && *detail != '\0')
            {
                err += ": ";
                err += detail;
            }
            break;
        }
        if (produced == 0 && stream.avail_in == 0 &&
            read_offset >= archive_size)
        {
            err = "archive: truncated gzip stream in '" + display_path +
                  "'";
            break;
        }
    }

    const int end_status = inflateEnd(&stream);
    if (success && end_status != Z_OK)
    {
        err = "archive: cannot finalise gzip validation for '" +
              display_path + "'";
        return false;
    }
    return success;
}

bool read_byte_at(int fd, std::uint64_t offset, unsigned char &value,
                  const std::string &display_path, std::string &err)
{
    const ssize_t count = ::pread(fd, &value, 1, static_cast<off_t>(offset));
    if (count == 1)
    {
        return true;
    }
    if (count < 0)
    {
        err = "archive: cannot read gzip stream '" + display_path + "': " +
              std::strerror(errno);
    }
    else
    {
        err = "archive: truncated gzip stream in '" + display_path + "'";
    }
    return false;
}

bool validate_gzip_stream_fd(int fd, std::uint64_t archive_size,
                             const ScanLimits &limits,
                             const std::string &display_path,
                             std::string &err)
{
    std::uint64_t raw_limit = 0;
    if (!compressed_raw_stream_limit(limits, raw_limit, err))
    {
        return false;
    }

    std::uint64_t raw_total = 0;
    std::uint64_t offset = 0;
    bool saw_member = false;
    while (offset < archive_size)
    {
        unsigned char first = 0;
        if (!read_byte_at(fd, offset, first, display_path, err))
        {
            return false;
        }
        if (first == 0)
        {
            ++offset;
            continue;
        }

        unsigned char second = 0;
        if (offset + 1 >= archive_size ||
            !read_byte_at(fd, offset + 1, second, display_path, err))
        {
            return false;
        }
        if (first != 0x1f || second != 0x8b)
        {
            err = "archive: non-gzip trailing data after gzip TAR stream in '" +
                  display_path + "'";
            return false;
        }

        std::uint64_t next_offset = 0;
        if (!validate_one_gzip_member(fd, archive_size, offset, raw_limit,
                                      raw_total, next_offset, display_path,
                                      err))
        {
            return false;
        }
        if (next_offset <= offset)
        {
            err = "archive: gzip validation made no progress for '" +
                  display_path + "'";
            return false;
        }
        saw_member = true;
        offset = next_offset;
    }

    if (!saw_member)
    {
        err = "archive: gzip TAR contains no gzip member: '" + display_path +
              "'";
        return false;
    }
    return true;
}

bool validate_zstd_stream_fd(int fd, std::uint64_t archive_size,
                             const ScanLimits &limits,
                             const std::string &display_path,
                             std::string &err)
{
    std::uint64_t raw_limit = 0;
    if (!compressed_raw_stream_limit(limits, raw_limit, err))
    {
        return false;
    }

    ZSTD_DStream *stream = ZSTD_createDStream();
    if (stream == nullptr)
    {
        err = "archive: cannot initialise zstd validation for '" +
              display_path + "'";
        return false;
    }

    const size_t init_status = ZSTD_initDStream(stream);
    if (ZSTD_isError(init_status))
    {
        err = "archive: cannot initialise zstd validation for '" +
              display_path + "': " + ZSTD_getErrorName(init_status);
        ZSTD_freeDStream(stream);
        return false;
    }

    std::array<unsigned char, READ_BLOCK_SIZE> input{};
    std::array<unsigned char, READ_BLOCK_SIZE> output{};
    std::uint64_t read_offset = 0;
    std::uint64_t raw_total = 0;
    bool saw_frame = false;
    bool frame_finished = false;
    bool success = false;
    ZSTD_inBuffer in{input.data(), 0, 0};

    for (;;)
    {
        if (in.pos == in.size)
        {
            if (read_offset >= archive_size)
            {
                if (saw_frame && frame_finished)
                {
                    success = true;
                }
                else
                {
                    err = "archive: truncated zstd stream in '" +
                          display_path + "'";
                }
                break;
            }
            const std::uint64_t remaining = archive_size - read_offset;
            const std::size_t wanted = static_cast<std::size_t>(
                std::min<std::uint64_t>(remaining, input.size()));
            const ssize_t count = ::pread(fd, input.data(), wanted,
                                          static_cast<off_t>(read_offset));
            if (count < 0)
            {
                err = "archive: cannot read zstd stream '" + display_path +
                      "': " + std::strerror(errno);
                break;
            }
            if (count == 0)
            {
                err = "archive: truncated zstd stream in '" + display_path +
                      "'";
                break;
            }
            const auto supplied = static_cast<std::size_t>(count);
            read_offset += supplied;
            in.src = input.data();
            in.size = supplied;
            in.pos = 0;
        }

        ZSTD_outBuffer out{output.data(), output.size(), 0};
        const size_t status = ZSTD_decompressStream(stream, &out, &in);
        if (ZSTD_isError(status))
        {
            err = "archive: invalid zstd stream '" + display_path +
                  "': " + ZSTD_getErrorName(status);
            break;
        }
        if (raw_total > raw_limit || out.pos > raw_limit - raw_total)
        {
            err = "archive: zstd-compressed TAR expands beyond its internal "
                  "raw-stream limit";
            break;
        }
        raw_total += out.pos;
        frame_finished = status == 0;
        if (frame_finished)
        {
            saw_frame = true;
        }

        if (out.pos == 0 && in.pos == in.size &&
            read_offset >= archive_size && !frame_finished)
        {
            err = "archive: truncated zstd stream in '" + display_path +
                  "'";
            break;
        }
    }

    ZSTD_freeDStream(stream);
    if (!success && err.empty())
    {
        err = "archive: invalid zstd stream '" + display_path + "'";
    }
    return success;
}

bool initialise_reader(ArchiveHandle &handle, int fd,
                       const std::string &display_path,
                       archive *&reader, Compression &compression,
                       std::string &err)
{
    if (::lseek(fd, 0, SEEK_SET) < 0)
    {
        err = "archive: cannot rewind archive '" + display_path + "': " +
              std::strerror(errno);
        return false;
    }

    reader = handle.get();
    if (reader == nullptr)
    {
        err = "archive: cannot allocate the libarchive TAR reader";
        return false;
    }

    if (archive_read_support_filter_none(reader) != ARCHIVE_OK ||
        archive_read_support_filter_gzip(reader) != ARCHIVE_OK ||
        archive_read_support_filter_xz(reader) != ARCHIVE_OK ||
        archive_read_support_filter_bzip2(reader) != ARCHIVE_OK ||
        archive_read_support_filter_zstd(reader) != ARCHIVE_OK ||
        archive_read_support_format_tar(reader) != ARCHIVE_OK)
    {
        err = operation_error(reader, "cannot initialise TAR reader for",
                              display_path);
        return false;
    }

    if (archive_read_set_format_option(
            reader, "tar", "read_concatenated_archives", "1") != ARCHIVE_OK)
    {
        err = operation_error(reader,
                              "cannot enable concatenated TAR inspection for",
                              display_path);
        return false;
    }

    if (archive_read_open_fd(reader, fd, READ_BLOCK_SIZE) != ARCHIVE_OK)
    {
        err = operation_error(reader, "cannot open TAR archive",
                              display_path);
        return false;
    }

    const int filter_code = archive_filter_code(reader, 0);
    if (filter_code == ARCHIVE_FILTER_NONE)
    {
        compression = Compression::none;
    }
    else if (filter_code == ARCHIVE_FILTER_GZIP)
    {
        compression = Compression::gzip;
    }
    else if (filter_code == ARCHIVE_FILTER_XZ)
    {
        compression = Compression::xz;
    }
    else if (filter_code == ARCHIVE_FILTER_BZIP2)
    {
        compression = Compression::bzip2;
    }
    else if (filter_code == ARCHIVE_FILTER_ZSTD)
    {
        compression = Compression::zstd;
    }
    else
    {
        err = "archive: TAR compression filter is not supported for '" +
              display_path + "'";
        return false;
    }
    return true;
}

EntryType detect_type(archive_entry *entry)
{
    if (archive_entry_hardlink(entry) != nullptr)
    {
        return EntryType::hardlink;
    }

    switch (archive_entry_filetype(entry))
    {
    case AE_IFREG:
        return EntryType::regular;
    case AE_IFDIR:
        return EntryType::directory;
    case AE_IFLNK:
        return EntryType::symlink;
    case AE_IFIFO:
        return EntryType::fifo;
    case AE_IFCHR:
        return EntryType::character_device;
    case AE_IFBLK:
        return EntryType::block_device;
#ifdef AE_IFSOCK
    case AE_IFSOCK:
        return EntryType::socket;
#endif
    default:
        return EntryType::unsupported;
    }
}

bool decode_entry(archive_entry *raw_entry, std::size_t index,
                  Entry &entry, std::string &err)
{
    const char *pathname = archive_entry_pathname(raw_entry);
    if (pathname == nullptr)
    {
        err = "archive: TAR entry at index " + std::to_string(index + 1) +
              " has no pathname";
        return false;
    }

    entry = {};
    entry.name = pathname;
    entry.type = detect_type(raw_entry);
    entry.unix_mode =
        static_cast<std::uint32_t>(archive_entry_mode(raw_entry) & 07777U);
    entry.has_unix_mode = archive_entry_perm_is_set(raw_entry) != 0;
    entry.has_mtime = archive_entry_mtime_is_set(raw_entry) != 0;
    if (entry.has_mtime)
    {
        entry.mtime = static_cast<std::int64_t>(archive_entry_mtime(raw_entry));
        entry.mtime_nsec = archive_entry_mtime_nsec(raw_entry);
    }
    entry.has_uid = archive_entry_uid_is_set(raw_entry) != 0;
    if (entry.has_uid)
    {
        entry.uid = static_cast<std::int64_t>(archive_entry_uid(raw_entry));
    }
    entry.has_gid = archive_entry_gid_is_set(raw_entry) != 0;
    if (entry.has_gid)
    {
        entry.gid = static_cast<std::int64_t>(archive_entry_gid(raw_entry));
    }
    entry.sparse = archive_entry_sparse_count(raw_entry) > 0;

    const char *target = entry.type == EntryType::hardlink
                             ? archive_entry_hardlink(raw_entry)
                             : archive_entry_symlink(raw_entry);
    if (target != nullptr)
    {
        entry.has_link_target = true;
        entry.link_target = target;
    }

    if (archive_entry_size_is_set(raw_entry) != 0)
    {
        const la_int64_t announced_size = archive_entry_size(raw_entry);
        if (announced_size < 0)
        {
            err = "archive: TAR entry '" + entry.name +
                  "' announces a negative size";
            return false;
        }
        entry.size = static_cast<std::uint64_t>(announced_size);
    }

    if (entry.type != EntryType::regular && entry.size != 0)
    {
        err = "archive: non-regular TAR entry '" + entry.name +
              "' announces a non-zero data size";
        return false;
    }
    return true;
}

bool account_entry(const Entry &entry, std::size_t index,
                   const ScanLimits &limits,
                   std::uint64_t &total_size,
                   std::uint64_t &total_name_bytes,
                   std::string &err)
{
    if (index >= limits.max_entries)
    {
        err = "archive: entry count exceeds max_entries (" +
              std::to_string(index + 1) + " > " +
              std::to_string(limits.max_entries) + ")";
        return false;
    }

    if (entry.name.size() > limits.max_path_length)
    {
        err = "archive: entry name at index " +
              std::to_string(index + 1) +
              " exceeds max_path_length (" +
              std::to_string(entry.name.size()) + " > " +
              std::to_string(limits.max_path_length) + ")";
        return false;
    }

    if (total_name_bytes > limits.max_total_name_bytes ||
        entry.name.size() > limits.max_total_name_bytes - total_name_bytes)
    {
        err = "archive: cumulative entry-name size exceeds max_total_name_bytes";
        return false;
    }
    total_name_bytes += entry.name.size();

    if (entry.type != EntryType::directory)
    {
        if (entry.size > limits.max_entry_size)
        {
            err = "archive: entry '" + entry.name +
                  "' exceeds max_entry_size (" +
                  std::to_string(entry.size) + " > " +
                  std::to_string(limits.max_entry_size) + ")";
            return false;
        }
        if (total_size > limits.max_total_size ||
            entry.size > limits.max_total_size - total_size)
        {
            err = "archive: total expanded size exceeds max_total_size";
            return false;
        }
        total_size += entry.size;
    }
    return true;
}

bool entries_equal(const Entry &actual, const Entry &expected) noexcept
{
    return actual.name == expected.name && actual.type == expected.type &&
           actual.size == expected.size &&
           actual.unix_mode == expected.unix_mode &&
           actual.has_unix_mode == expected.has_unix_mode &&
           actual.mtime == expected.mtime &&
           actual.mtime_nsec == expected.mtime_nsec &&
           actual.has_mtime == expected.has_mtime &&
           actual.uid == expected.uid && actual.gid == expected.gid &&
           actual.has_uid == expected.has_uid &&
           actual.has_gid == expected.has_gid &&
           actual.sparse == expected.sparse &&
           actual.has_link_target == expected.has_link_target &&
           actual.link_target == expected.link_target;
}

bool consume_entry_data(archive *reader, const Entry &entry,
                        std::size_t index,
                        const std::string &display_path,
                        ExtractionSink *sink, std::string &err)
{
    std::uint64_t previous_end = 0;
    for (;;)
    {
        const void *buffer = nullptr;
        std::size_t block_size = 0;
        la_int64_t block_offset = 0;
        const int status = archive_read_data_block(
            reader, &buffer, &block_size, &block_offset);
        if (status == ARCHIVE_EOF)
        {
            if (entry.type == EntryType::regular && !entry.sparse &&
                previous_end != entry.size)
            {
                err = "archive: TAR entry '" + entry.name +
                      "' ended before its announced size";
                return false;
            }
            return true;
        }
        if (status != ARCHIVE_OK)
        {
            err = operation_error(reader, "cannot read TAR entry data from",
                                  display_path);
            return false;
        }
        if (buffer == nullptr && block_size != 0)
        {
            err = "archive: libarchive returned a null TAR data block for entry '" +
                  entry.name + "'";
            return false;
        }
        if (block_offset < 0)
        {
            err = "archive: TAR entry '" + entry.name +
                  "' contains a negative data offset";
            return false;
        }

        const auto offset = static_cast<std::uint64_t>(block_offset);
        if (offset < previous_end ||
            block_size > std::numeric_limits<std::uint64_t>::max() - offset)
        {
            err = "archive: TAR entry '" + entry.name +
                  "' contains overlapping or overflowing data blocks";
            return false;
        }
        if (!entry.sparse && offset != previous_end)
        {
            err = "archive: TAR entry '" + entry.name +
                  "' contains an unexpected gap in its data";
            return false;
        }
        const std::uint64_t end = offset + block_size;
        if (end > entry.size)
        {
            err = "archive: TAR entry '" + entry.name +
                  "' contains data beyond its announced size";
            return false;
        }

        if (sink != nullptr && block_size != 0 &&
            !sink->write_file_block(index, entry, offset, buffer,
                                    block_size, err))
        {
            return false;
        }
        previous_end = end;
    }
}
}

bool scan_fd(int fd, std::uint64_t archive_size,
             const std::string &display_path, const ScanLimits &limits,
             ScanResult &result, std::string &err)
{
    result = {};
    result.archive_size = archive_size;

    if (!verify_source_size(fd, archive_size, display_path,
                            "before inspection", err))
    {
        return false;
    }

    ArchiveHandle handle;
    archive *reader = nullptr;
    Compression compression = Compression::none;
    if (!initialise_reader(handle, fd, display_path, reader, compression, err))
    {
        return false;
    }
    result.compression = compression;

    std::uint64_t total_size = 0;
    std::uint64_t total_name_bytes = 0;
    for (;;)
    {
        archive_entry *raw_entry = nullptr;
        const int status = archive_read_next_header(reader, &raw_entry);
        if (status == ARCHIVE_EOF)
        {
            if (!verify_source_size(fd, archive_size, display_path,
                                    "after inspection", err))
            {
                return false;
            }
            if (compression != Compression::none && total_size != 0)
            {
                if (archive_size == 0)
                {
                    err = "archive: compressed TAR has a zero compressed size";
                    return false;
                }
                const long double ratio =
                    static_cast<long double>(total_size) /
                    static_cast<long double>(archive_size);
                if (ratio > static_cast<long double>(
                                limits.max_compression_ratio))
                {
                    err = "archive: compressed TAR exceeds max_compression_ratio";
                    return false;
                }
            }
            if (compression == Compression::gzip &&
                !validate_gzip_stream_fd(fd, archive_size, limits,
                                         display_path, err))
            {
                return false;
            }
            if (compression == Compression::zstd &&
                !validate_zstd_stream_fd(fd, archive_size, limits,
                                         display_path, err))
            {
                return false;
            }
            if (!verify_source_size(fd, archive_size, display_path,
                                    "after compressed-stream validation", err))
            {
                return false;
            }
            result.total_size = total_size;
            result.total_name_bytes = total_name_bytes;
            return true;
        }
        if (status != ARCHIVE_OK || raw_entry == nullptr)
        {
            err = operation_error(reader,
                                  "cannot inspect TAR archive",
                                  display_path);
            return false;
        }

        Entry entry;
        const std::size_t index = result.entries.size();
        if (!decode_entry(raw_entry, index, entry, err) ||
            !account_entry(entry, index, limits, total_size,
                           total_name_bytes, err) ||
            !consume_entry_data(reader, entry, index, display_path,
                                nullptr, err))
        {
            return false;
        }
        result.entries.push_back(std::move(entry));
    }
}

bool extract_fd(int fd, std::uint64_t archive_size,
                const std::string &display_path, const ScanLimits &limits,
                Compression expected_compression,
                const std::vector<Entry> &expected_entries,
                ExtractionSink &sink, std::string &err)
{
    if (!verify_source_size(fd, archive_size, display_path,
                            "before extraction", err))
    {
        return false;
    }

    ArchiveHandle handle;
    archive *reader = nullptr;
    Compression compression = Compression::none;
    if (!initialise_reader(handle, fd, display_path, reader, compression, err))
    {
        return false;
    }
    if (compression != expected_compression)
    {
        err = "archive: TAR compression changed between inspection and extraction";
        return false;
    }

    std::uint64_t total_size = 0;
    std::uint64_t total_name_bytes = 0;
    std::size_t index = 0;
    for (;;)
    {
        archive_entry *raw_entry = nullptr;
        const int status = archive_read_next_header(reader, &raw_entry);
        if (status == ARCHIVE_EOF)
        {
            if (index != expected_entries.size())
            {
                err = "archive: TAR source changed between inspection and extraction";
                return false;
            }
            if (!verify_source_size(fd, archive_size, display_path,
                                    "after extraction", err))
            {
                return false;
            }
            if (compression == Compression::gzip &&
                !validate_gzip_stream_fd(fd, archive_size, limits,
                                         display_path, err))
            {
                sink.abort_file();
                return false;
            }
            if (compression == Compression::zstd &&
                !validate_zstd_stream_fd(fd, archive_size, limits,
                                         display_path, err))
            {
                sink.abort_file();
                return false;
            }
            if (!verify_source_size(fd, archive_size, display_path,
                                    "after compressed-stream validation", err))
            {
                sink.abort_file();
                return false;
            }
            return true;
        }
        if (status != ARCHIVE_OK || raw_entry == nullptr)
        {
            err = operation_error(reader,
                                  "cannot extract TAR archive",
                                  display_path);
            return false;
        }

        Entry entry;
        if (!decode_entry(raw_entry, index, entry, err) ||
            !account_entry(entry, index, limits, total_size,
                           total_name_bytes, err))
        {
            return false;
        }
        if (index >= expected_entries.size() ||
            !entries_equal(entry, expected_entries[index]))
        {
            err = "archive: TAR source changed between inspection and extraction at entry " +
                  std::to_string(index + 1);
            return false;
        }

        if (entry.type == EntryType::regular)
        {
            const bool selected = sink.wants_file(index, entry);
            if (selected && entry.sparse)
            {
                err = "archive: sparse TAR entry '" + entry.name +
                      "' cannot be extracted";
                return false;
            }
            if (selected)
            {
                if (!sink.begin_file(index, entry, err))
                {
                    return false;
                }
                if (!consume_entry_data(reader, entry, index, display_path,
                                        &sink, err) ||
                    !sink.finish_file(index, entry, err))
                {
                    sink.abort_file();
                    return false;
                }
            }
            else if (!consume_entry_data(reader, entry, index, display_path,
                                         nullptr, err))
            {
                return false;
            }
        }
        else if (!consume_entry_data(reader, entry, index, display_path,
                                     nullptr, err))
        {
            return false;
        }
        ++index;
    }
}

namespace
{
constexpr std::size_t WRITE_BLOCK_SIZE = 64U * 1024U;
constexpr mode_t CREATED_FILE_MODE = 0644;
constexpr mode_t CREATED_DIRECTORY_MODE = 0755;

class WriteArchiveHandle
{
public:
    WriteArchiveHandle() : value_(archive_write_new()) {}

    ~WriteArchiveHandle()
    {
        if (value_ != nullptr)
        {
            archive_write_free(value_);
        }
    }

    WriteArchiveHandle(const WriteArchiveHandle &) = delete;
    WriteArchiveHandle &operator=(const WriteArchiveHandle &) = delete;

    [[nodiscard]] archive *get() const noexcept { return value_; }

private:
    archive *value_ = nullptr;
};

class ArchiveEntryHandle
{
public:
    ArchiveEntryHandle() : value_(archive_entry_new()) {}
    ~ArchiveEntryHandle()
    {
        if (value_ != nullptr)
        {
            archive_entry_free(value_);
        }
    }

    ArchiveEntryHandle(const ArchiveEntryHandle &) = delete;
    ArchiveEntryHandle &operator=(const ArchiveEntryHandle &) = delete;

    [[nodiscard]] archive_entry *get() const noexcept { return value_; }

private:
    archive_entry *value_ = nullptr;
};

struct WriteContext
{
    int fd = -1;
    const std::string *display_path = nullptr;
};

int writer_open_callback(archive *, void *) noexcept
{
    return ARCHIVE_OK;
}

la_ssize_t writer_write_callback(archive *writer, void *opaque,
                                  const void *buffer,
                                  std::size_t size) noexcept
{
    auto *context = static_cast<WriteContext *>(opaque);
    if (context == nullptr || context->fd < 0 ||
        (buffer == nullptr && size != 0) ||
        size > static_cast<std::size_t>(
                   std::numeric_limits<la_ssize_t>::max()))
    {
        archive_set_error(writer, EINVAL, "invalid TAR output callback state");
        return -1;
    }

    const auto *bytes = static_cast<const unsigned char *>(buffer);
    std::size_t written = 0;
    while (written < size)
    {
        const ssize_t count =
            ::write(context->fd, bytes + written, size - written);
        if (count > 0)
        {
            written += static_cast<std::size_t>(count);
            continue;
        }
        if (count < 0 && errno == EINTR)
        {
            continue;
        }
        const int e = count == 0 ? EIO : errno;
        const char *path = context->display_path == nullptr
                               ? "TAR output"
                               : context->display_path->c_str();
        archive_set_error(writer, e, "cannot write TAR output '%s': %s",
                          path, std::strerror(e));
        return -1;
    }
    return static_cast<la_ssize_t>(written);
}

int writer_close_callback(archive *, void *) noexcept
{
    return ARCHIVE_OK;
}

bool set_creation_timestamp(archive_entry *entry,
                            const CreateEntry &source_entry,
                            bool deterministic, std::string &err)
{
    const std::int64_t seconds =
        deterministic ? 0 : source_entry.modified_seconds;
    const long nanoseconds =
        deterministic ? 0L : source_entry.modified_nanoseconds;
    if (nanoseconds < 0 || nanoseconds > 999999999L)
    {
        err = "archive: invalid source modification nanoseconds for TAR entry '" +
              source_entry.name + "'";
        return false;
    }

    if constexpr (std::numeric_limits<std::time_t>::is_signed)
    {
        if (seconds < static_cast<std::int64_t>(
                          std::numeric_limits<std::time_t>::min()) ||
            seconds > static_cast<std::int64_t>(
                          std::numeric_limits<std::time_t>::max()))
        {
            err = "archive: source modification time is outside the TAR writer range: '" +
                  source_entry.name + "'";
            return false;
        }
    }
    else if (seconds < 0 ||
             static_cast<std::uint64_t>(seconds) >
                 std::numeric_limits<std::time_t>::max())
    {
        err = "archive: source modification time is outside the TAR writer range: '" +
              source_entry.name + "'";
        return false;
    }

    archive_entry_set_mtime(entry, static_cast<std::time_t>(seconds),
                            nanoseconds);
    return true;
}

bool write_all_entry_data(archive *writer, const void *buffer,
                          std::size_t size, const std::string &entry_name,
                          std::string &err)
{
    const auto *bytes = static_cast<const unsigned char *>(buffer);
    std::size_t consumed = 0;
    while (consumed < size)
    {
        const la_ssize_t count =
            archive_write_data(writer, bytes + consumed, size - consumed);
        if (count < 0)
        {
            err = operation_error(writer, "cannot write TAR entry data for",
                                  entry_name);
            return false;
        }
        if (count == 0)
        {
            err = "archive: libarchive made no progress while writing TAR entry '" +
                  entry_name + "'";
            return false;
        }
        const auto advanced = static_cast<std::size_t>(count);
        if (advanced > size - consumed)
        {
            err = "archive: libarchive reported an invalid TAR write count for entry '" +
                  entry_name + "'";
            return false;
        }
        consumed += advanced;
    }
    return true;
}
}

bool create_fd(int fd, const std::string &display_path,
               const std::vector<CreateEntry> &entries,
               Compression compression, int compression_level,
               bool deterministic, CreationSource &source,
               std::string &err)
{
    if (fd < 0)
    {
        err = "archive: invalid TAR output descriptor";
        return false;
    }
    if (::lseek(fd, 0, SEEK_SET) < 0 || ::ftruncate(fd, 0) != 0)
    {
        err = "archive: cannot initialise TAR output '" + display_path +
              "': " + std::strerror(errno);
        return false;
    }

    WriteArchiveHandle handle;
    archive *writer = handle.get();
    if (writer == nullptr)
    {
        err = "archive: cannot allocate the libarchive TAR writer";
        return false;
    }
    const int maximum_compression_level =
        compression == Compression::zstd ? 19 : 9;
    if (compression_level < 0 ||
        compression_level > maximum_compression_level)
    {
        err = "archive: invalid TAR compression level";
        return false;
    }

    int filter_status = ARCHIVE_FATAL;
    if (compression == Compression::none)
    {
        filter_status = archive_write_add_filter_none(writer);
    }
    else if (compression == Compression::gzip)
    {
        filter_status = archive_write_add_filter_gzip(writer);
        if (filter_status == ARCHIVE_OK)
        {
            const std::string level = std::to_string(compression_level);
            if (archive_write_set_filter_option(
                    writer, "gzip", "compression-level",
                    level.c_str()) != ARCHIVE_OK ||
                archive_write_set_filter_option(
                    writer, "gzip", "timestamp", nullptr) != ARCHIVE_OK ||
                archive_write_set_bytes_per_block(writer, 0) != ARCHIVE_OK)
            {
                err = operation_error(writer,
                                      "cannot configure gzip TAR writer for",
                                      display_path);
                return false;
            }
        }
    }
    else if (compression == Compression::xz)
    {
        filter_status = archive_write_add_filter_xz(writer);
        if (filter_status == ARCHIVE_OK)
        {
            const std::string level = std::to_string(compression_level);
            if (archive_write_set_filter_option(
                    writer, "xz", "compression-level",
                    level.c_str()) != ARCHIVE_OK ||
                archive_write_set_bytes_per_block(writer, 0) != ARCHIVE_OK)
            {
                err = operation_error(writer,
                                      "cannot configure xz TAR writer for",
                                      display_path);
                return false;
            }
        }
    }
    else if (compression == Compression::bzip2)
    {
        if (compression_level < 1)
        {
            err = "archive: bzip2 TAR compression level must be between 1 and 9";
            return false;
        }
        filter_status = archive_write_add_filter_bzip2(writer);
        if (filter_status == ARCHIVE_OK)
        {
            const std::string level = std::to_string(compression_level);
            if (archive_write_set_filter_option(
                    writer, "bzip2", "compression-level",
                    level.c_str()) != ARCHIVE_OK ||
                archive_write_set_bytes_per_block(writer, 0) != ARCHIVE_OK)
            {
                err = operation_error(writer,
                                      "cannot configure bzip2 TAR writer for",
                                      display_path);
                return false;
            }
        }
    }
    else if (compression == Compression::zstd)
    {
        if (compression_level < 0 || compression_level > 19)
        {
            err = "archive: zstd TAR compression level must be between 0 and 19";
            return false;
        }
        filter_status = archive_write_add_filter_zstd(writer);
        if (filter_status == ARCHIVE_OK)
        {
            const std::string level = std::to_string(compression_level);
            if (archive_write_set_filter_option(
                    writer, "zstd", "compression-level",
                    level.c_str()) != ARCHIVE_OK ||
                archive_write_set_bytes_per_block(writer, 0) != ARCHIVE_OK)
            {
                err = operation_error(writer,
                                      "cannot configure zstd TAR writer for",
                                      display_path);
                return false;
            }
        }
    }
    if (filter_status != ARCHIVE_OK ||
        archive_write_set_format_pax_restricted(writer) != ARCHIVE_OK)
    {
        err = operation_error(writer, "cannot initialise TAR writer for",
                              display_path);
        return false;
    }

    WriteContext context{fd, &display_path};
    // libarchive 3.8.8 can emit a corrupt zstd frame when the generic custom
    // write-callback path is used. Its built-in fd writer does not have that
    // defect and leaves ownership of fd with Babet, so the temporary inode and
    // atomic publication policy remain unchanged.
    const int open_status =
        compression == Compression::zstd
            ? archive_write_open_fd(writer, fd)
            : archive_write_open(writer, &context, writer_open_callback,
                                 writer_write_callback,
                                 writer_close_callback);
    if (open_status != ARCHIVE_OK)
    {
        err = operation_error(writer, "cannot open TAR writer for",
                              display_path);
        return false;
    }

    std::array<unsigned char, WRITE_BLOCK_SIZE> buffer{};
    for (std::size_t index = 0; index < entries.size(); ++index)
    {
        const CreateEntry &item = entries[index];
        ArchiveEntryHandle entry_handle;
        archive_entry *entry = entry_handle.get();
        if (entry == nullptr)
        {
            err = "archive: cannot allocate TAR entry metadata";
            return false;
        }

        archive_entry_set_pathname(entry, item.name.c_str());
        archive_entry_set_uid(entry, 0);
        archive_entry_set_gid(entry, 0);
        archive_entry_set_uname(entry, "");
        archive_entry_set_gname(entry, "");
        archive_entry_set_nlink(entry, 1);
        archive_entry_set_filetype(entry,
                                   item.directory ? AE_IFDIR : AE_IFREG);
        archive_entry_set_perm(entry, item.directory
                                          ? CREATED_DIRECTORY_MODE
                                          : CREATED_FILE_MODE);
        archive_entry_set_size(entry, item.directory
                                          ? 0
                                          : static_cast<la_int64_t>(item.size));
        if (!set_creation_timestamp(entry, item, deterministic, err))
        {
            return false;
        }

        if (archive_write_header(writer, entry) != ARCHIVE_OK)
        {
            err = operation_error(writer, "cannot write TAR header for",
                                  item.name);
            return false;
        }

        if (!item.directory)
        {
            if (!source.begin_file(index, item, err))
            {
                return false;
            }
            std::uint64_t total = 0;
            while (total < item.size)
            {
                std::size_t count = 0;
                if (!source.read_file_block(buffer.data(), buffer.size(),
                                            count, err))
                {
                    source.abort_file();
                    return false;
                }
                if (count == 0)
                {
                    source.abort_file();
                    err = "archive: source entry ended before its announced size: '" +
                          item.name + "'";
                    return false;
                }
                if (count > buffer.size() ||
                    count > item.size - total)
                {
                    source.abort_file();
                    err = "archive: source entry exceeded its announced size: '" +
                          item.name + "'";
                    return false;
                }
                if (!write_all_entry_data(writer, buffer.data(), count,
                                          item.name, err))
                {
                    source.abort_file();
                    return false;
                }
                total += count;
            }
            if (!source.finish_file(index, item, err))
            {
                source.abort_file();
                return false;
            }
        }

        if (archive_write_finish_entry(writer) != ARCHIVE_OK)
        {
            err = operation_error(writer, "cannot finish TAR entry",
                                  item.name);
            return false;
        }
    }

    if (archive_write_close(writer) != ARCHIVE_OK)
    {
        err = operation_error(writer, "cannot finalize TAR archive",
                              display_path);
        return false;
    }
    return true;
}
}
