#include "archive.hpp"
#include "lua_utils.hpp"
#include "project_core/archive_tar.hpp"
#include "project_core/safe_glob.hpp"

#include <miniz.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>

namespace fs = std::filesystem;

namespace
{
constexpr std::uint64_t DEFAULT_MAX_ENTRIES = 10000;
constexpr std::uint64_t DEFAULT_MAX_ENTRY_SIZE = 256ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t DEFAULT_MAX_TOTAL_SIZE = 1024ULL * 1024ULL * 1024ULL;
constexpr double DEFAULT_MAX_COMPRESSION_RATIO = 1000.0;
constexpr std::uint64_t DEFAULT_MAX_PATH_LENGTH = 64ULL * 1024ULL;
constexpr std::uint64_t DEFAULT_MAX_TOTAL_NAME_BYTES = 64ULL * 1024ULL * 1024ULL;
constexpr std::size_t MAX_SAFE_ARCHIVE_PATH_BYTES = 4096;

constexpr std::uint64_t HARD_MAX_ENTRIES = 100000;
constexpr std::uint64_t HARD_MAX_ENTRY_SIZE = 8ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t HARD_MAX_TOTAL_SIZE = 64ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr double HARD_MAX_COMPRESSION_RATIO = 1000000000.0;
constexpr std::uint64_t HARD_MAX_PATH_LENGTH = 1024ULL * 1024ULL;
constexpr std::uint64_t HARD_MAX_TOTAL_NAME_BYTES = 64ULL * 1024ULL * 1024ULL;
constexpr std::size_t HARD_MAX_OUTPUT_DIRECTORIES = 100000;
constexpr std::size_t HARD_MAX_CREATE_DEPTH = 256;
constexpr std::uint64_t HARD_MAX_SCANNED_SOURCE_NODES = 100000;
constexpr std::size_t HARD_MAX_ARCHIVE_FILTER_PATTERNS = 256;
constexpr std::uint64_t HARD_MAX_ARCHIVE_FILTER_BYTES = 256ULL * 1024ULL;
constexpr std::uint64_t HARD_MAX_ARCHIVE_FILTER_EVALUATIONS = 1000000ULL;
constexpr std::uint64_t HARD_MAX_ARCHIVE_FILTER_WORK = 100000000ULL;
constexpr std::uint64_t HARD_MAX_OUTPUT_DIRECTORY_PATH_BYTES =
    64ULL * 1024ULL * 1024ULL;
constexpr std::size_t HARD_MAX_MINIZ_ALLOCATED_BYTES =
    128ULL * 1024ULL * 1024ULL;

constexpr mode_t DEFAULT_FILE_MODE = 0644;
constexpr mode_t DEFAULT_DIRECTORY_MODE = 0755;
constexpr mode_t STAGING_DIRECTORY_MODE = 0700;
constexpr mode_t STAGING_FILE_MODE = 0600;

std::atomic<unsigned long long> archive_temp_counter{0};

struct ArchiveGlobFilter
{
    std::vector<babet::safe_glob::Pattern> include_patterns;
    std::vector<babet::safe_glob::Pattern> exclude_patterns;
    std::uint64_t evaluations = 0;
    std::uint64_t work = 0;

    [[nodiscard]] bool active() const noexcept
    {
        return !include_patterns.empty() || !exclude_patterns.empty();
    }
};

struct ArchiveOptions
{
    std::uint64_t max_entries = DEFAULT_MAX_ENTRIES;
    std::uint64_t max_entry_size = DEFAULT_MAX_ENTRY_SIZE;
    std::uint64_t max_total_size = DEFAULT_MAX_TOTAL_SIZE;
    std::uint64_t max_path_length = DEFAULT_MAX_PATH_LENGTH;
    std::uint64_t max_total_name_bytes = DEFAULT_MAX_TOTAL_NAME_BYTES;
    double max_compression_ratio = DEFAULT_MAX_COMPRESSION_RATIO;
    bool overwrite = false;
    bool preserve_permissions = false;
    bool dry_run = false;
    ArchiveGlobFilter filters;
};

enum class EntryKind
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

enum class ArchiveFormat
{
    zip,
    tar,
};

enum class ArchiveCompression
{
    none,
    gzip,
    xz,
    bzip2,
    zstd,
};

struct ArchiveEntry
{
    mz_uint index = 0;
    std::string name;
    std::string normalized;
    EntryKind kind = EntryKind::unsupported;
    std::uint64_t compressed_size = 0;
    bool has_compressed_size = true;
    std::uint64_t size = 0;
    std::uint32_t crc32 = 0;
    bool has_crc32 = true;
    std::uint16_t method = 0;
    bool has_compression_method = true;
    std::uint16_t bit_flags = 0;
    std::uint64_t local_header_offset = 0;
    std::uint16_t version_made_by = 0;
    std::uint32_t external_attributes = 0;
    mode_t unix_mode = 0;
    bool has_unix_mode = false;
    std::int64_t mtime = 0;
    long mtime_nsec = 0;
    bool has_mtime = false;
    bool has_mtime_nsec = false;
    std::int64_t uid = 0;
    std::int64_t gid = 0;
    bool has_uid = false;
    bool has_gid = false;
    bool valid_utf8 = false;
    bool duplicate = false;
    std::size_t duplicate_of = 0;
    bool conflict = false;
    std::size_t conflict_with = 0;
    std::string conflict_reason;
    bool encrypted = false;
    bool supported = false;
    bool safe_path = false;
    bool sparse = false;
    bool has_link_target = false;
    std::string link_target;
    std::string path_error;
};

struct ArchiveScan
{
    std::vector<ArchiveEntry> entries;
    std::uint64_t total_size = 0;
    std::uint64_t archive_size = 0;
    std::uint64_t total_name_bytes = 0;
    std::uint64_t duplicate_entries = 0;
    std::uint64_t conflicting_entries = 0;
    bool zip64 = false;
    ArchiveFormat format = ArchiveFormat::zip;
    ArchiveCompression compression = ArchiveCompression::none;
};

std::string errno_message(std::string_view action, const fs::path &path,
                          int error_number)
{
    std::string result(action);
    result += " '";
    result += path.string();
    result += "': ";
    result += std::strerror(error_number);
    return result;
}

struct MinizAllocationState
{
    std::size_t used = 0;
    std::size_t limit = HARD_MAX_MINIZ_ALLOCATED_BYTES;
};

struct alignas(std::max_align_t) MinizAllocationHeader
{
    std::size_t block_size = 0;
};

bool checked_allocation_size(std::size_t items, std::size_t item_size,
                             std::size_t &payload,
                             std::size_t &block_size) noexcept
{
    if (item_size != 0 &&
        items > std::numeric_limits<std::size_t>::max() / item_size)
    {
        return false;
    }
    payload = items * item_size;
    if (payload == 0)
    {
        payload = 1;
    }
    if (payload > std::numeric_limits<std::size_t>::max() -
                      sizeof(MinizAllocationHeader))
    {
        return false;
    }
    block_size = sizeof(MinizAllocationHeader) + payload;
    return true;
}

void *bounded_miniz_alloc(void *opaque, std::size_t items,
                          std::size_t item_size) noexcept
{
    auto *state = static_cast<MinizAllocationState *>(opaque);
    std::size_t payload = 0;
    std::size_t block_size = 0;
    if (state == nullptr || state->used > state->limit ||
        !checked_allocation_size(items, item_size, payload, block_size) ||
        block_size > state->limit - state->used)
    {
        return nullptr;
    }

    auto *header = static_cast<MinizAllocationHeader *>(
        std::malloc(block_size));
    if (header == nullptr)
    {
        return nullptr;
    }
    header->block_size = block_size;
    state->used += block_size;
    return header + 1;
}

void bounded_miniz_free(void *opaque, void *address) noexcept
{
    if (address == nullptr)
    {
        return;
    }
    auto *state = static_cast<MinizAllocationState *>(opaque);
    auto *header = static_cast<MinizAllocationHeader *>(address) - 1;
    if (state != nullptr)
    {
        state->used = header->block_size <= state->used
                          ? state->used - header->block_size
                          : 0;
    }
    std::free(header);
}

void *bounded_miniz_realloc(void *opaque, void *address,
                            std::size_t items,
                            std::size_t item_size) noexcept
{
    if (address == nullptr)
    {
        return bounded_miniz_alloc(opaque, items, item_size);
    }
    if (items == 0 || item_size == 0)
    {
        bounded_miniz_free(opaque, address);
        return nullptr;
    }

    auto *state = static_cast<MinizAllocationState *>(opaque);
    auto *old_header = static_cast<MinizAllocationHeader *>(address) - 1;
    const std::size_t old_size = old_header->block_size;
    std::size_t payload = 0;
    std::size_t new_size = 0;
    if (state == nullptr || old_size > state->used ||
        state->used > state->limit ||
        !checked_allocation_size(items, item_size, payload, new_size))
    {
        return nullptr;
    }
    if (new_size > old_size && new_size - old_size > state->limit - state->used)
    {
        return nullptr;
    }

    auto *new_header = static_cast<MinizAllocationHeader *>(
        std::realloc(old_header, new_size));
    if (new_header == nullptr)
    {
        return nullptr;
    }
    state->used = state->used - old_size + new_size;
    new_header->block_size = new_size;
    return new_header + 1;
}

std::string miniz_error(mz_zip_archive &zip, std::string_view action,
                        const std::string &path)
{
    const mz_zip_error code = mz_zip_peek_last_error(&zip);
    const char *detail = mz_zip_get_error_string(code);
    std::string result = "archive: ";
    result.append(action);
    result += " '";
    result += path;
    result += "'";
    if (detail != nullptr && *detail != '\0')
    {
        result += ": ";
        result += detail;
    }
    return result;
}

std::uint16_t read_zip_u16(const unsigned char *data) noexcept
{
    return static_cast<std::uint16_t>(data[0]) |
           (static_cast<std::uint16_t>(data[1]) << 8U);
}

std::uint32_t read_zip_u32(const unsigned char *data) noexcept
{
    return static_cast<std::uint32_t>(data[0]) |
           (static_cast<std::uint32_t>(data[1]) << 8U) |
           (static_cast<std::uint32_t>(data[2]) << 16U) |
           (static_cast<std::uint32_t>(data[3]) << 24U);
}

std::uint64_t read_zip_u64(const unsigned char *data) noexcept
{
    return static_cast<std::uint64_t>(read_zip_u32(data)) |
           (static_cast<std::uint64_t>(read_zip_u32(data + 4)) << 32U);
}

bool pread_archive_bytes(int fd, std::uint64_t offset, unsigned char *data,
                         std::size_t size, const std::string &path,
                         std::string &err)
{
    const auto off_max = static_cast<std::uint64_t>(
        std::numeric_limits<off_t>::max());
    if (offset > off_max || size > off_max - offset)
    {
        err = "archive: ZIP metadata offset is out of range in '" + path +
              "'";
        return false;
    }

    std::size_t completed = 0;
    while (completed < size)
    {
        const ssize_t amount = ::pread(
            fd, data + completed, size - completed,
            static_cast<off_t>(offset + completed));
        if (amount < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            err = "archive: " + errno_message(
                "cannot read ZIP metadata", path, errno);
            return false;
        }
        if (amount == 0)
        {
            err = "archive: truncated ZIP metadata in '" + path + "'";
            return false;
        }
        completed += static_cast<std::size_t>(amount);
    }
    return true;
}

bool reject_multi_volume_zip(int fd, const std::string &path,
                             std::string &err)
{
    constexpr std::uint32_t eocd_signature = 0x06054b50U;
    constexpr std::uint32_t zip64_eocd_signature = 0x06064b50U;
    constexpr std::uint32_t zip64_locator_signature = 0x07064b50U;
    constexpr std::size_t eocd_size = 22;
    constexpr std::size_t zip64_locator_size = 20;
    constexpr std::size_t zip64_eocd_min_size = 56;
    constexpr std::size_t max_zip_comment = 65535;

    struct stat st{};
    if (::fstat(fd, &st) != 0)
    {
        err = "archive: " + errno_message(
            "cannot inspect ZIP archive", path, errno);
        return false;
    }
    if (st.st_size < 0)
    {
        err = "archive: ZIP archive has a negative size: '" + path + "'";
        return false;
    }

    const std::uint64_t archive_size =
        static_cast<std::uint64_t>(st.st_size);
    if (archive_size < eocd_size)
    {
        return true; // Let miniz produce the ordinary malformed-ZIP error.
    }

    const std::size_t tail_size = static_cast<std::size_t>(
        std::min<std::uint64_t>(archive_size,
                                eocd_size + max_zip_comment));
    const std::uint64_t tail_offset = archive_size - tail_size;
    std::vector<unsigned char> tail(tail_size);
    if (!pread_archive_bytes(fd, tail_offset, tail.data(), tail.size(), path,
                             err))
    {
        return false;
    }

    std::optional<std::size_t> eocd_position;
    for (std::size_t position = tail_size - eocd_size;; --position)
    {
        if (read_zip_u32(tail.data() + position) == eocd_signature)
        {
            // Match miniz's EOCD search: the last signature within the
            // 64 KiB ZIP-comment window is the record it will inspect.
            eocd_position = position;
            break;
        }
        if (position == 0)
        {
            break;
        }
    }
    if (!eocd_position)
    {
        return true; // Let miniz reject a missing or malformed EOCD.
    }

    const unsigned char *eocd = tail.data() + *eocd_position;
    const std::uint16_t disk_number = read_zip_u16(eocd + 4);
    const std::uint16_t central_directory_disk = read_zip_u16(eocd + 6);
    const std::uint16_t entries_on_disk = read_zip_u16(eocd + 8);
    const std::uint16_t total_entries = read_zip_u16(eocd + 10);
    const std::uint32_t central_directory_size = read_zip_u32(eocd + 12);
    const std::uint32_t central_directory_offset = read_zip_u32(eocd + 16);

    const bool legacy_uses_zip64 =
        disk_number == 0xffffU || central_directory_disk == 0xffffU ||
        entries_on_disk == 0xffffU || total_entries == 0xffffU ||
        central_directory_size == 0xffffffffU ||
        central_directory_offset == 0xffffffffU;

    const auto reject = [&]() {
        err = "archive: split or multi-volume ZIP archives are not supported: '" +
              path + "'";
        return false;
    };

    if (!legacy_uses_zip64)
    {
        if (disk_number != 0 || central_directory_disk != 0 ||
            entries_on_disk != total_entries)
        {
            return reject();
        }
        return true;
    }

    if ((disk_number != 0 && disk_number != 0xffffU) ||
        (central_directory_disk != 0 &&
         central_directory_disk != 0xffffU) ||
        (entries_on_disk != total_entries && entries_on_disk != 0xffffU &&
         total_entries != 0xffffU))
    {
        return reject();
    }

    if (*eocd_position < zip64_locator_size)
    {
        return true; // miniz will reject the incomplete ZIP64 metadata.
    }

    const unsigned char *locator =
        tail.data() + *eocd_position - zip64_locator_size;
    if (read_zip_u32(locator) != zip64_locator_signature)
    {
        return true; // miniz will reject the missing ZIP64 locator.
    }

    const std::uint32_t zip64_eocd_disk = read_zip_u32(locator + 4);
    const std::uint64_t zip64_eocd_offset = read_zip_u64(locator + 8);
    const std::uint32_t total_disks = read_zip_u32(locator + 16);
    if (zip64_eocd_disk != 0 || total_disks != 1)
    {
        return reject();
    }

    unsigned char zip64_eocd[zip64_eocd_min_size]{};
    bool found_zip64_eocd = false;
    const std::uint64_t eocd_absolute = tail_offset + *eocd_position;
    if (eocd_absolute >= zip64_locator_size + zip64_eocd_min_size)
    {
        const std::uint64_t adjacent_offset =
            eocd_absolute - zip64_locator_size - zip64_eocd_min_size;
        if (!pread_archive_bytes(fd, adjacent_offset, zip64_eocd,
                                 sizeof(zip64_eocd), path, err))
        {
            return false;
        }
        found_zip64_eocd =
            read_zip_u32(zip64_eocd) == zip64_eocd_signature;
    }

    if (!found_zip64_eocd)
    {
        if (zip64_eocd_offset > archive_size ||
            archive_size - zip64_eocd_offset < zip64_eocd_min_size)
        {
            return true; // miniz will report malformed ZIP64 metadata.
        }
        if (!pread_archive_bytes(fd, zip64_eocd_offset, zip64_eocd,
                                 sizeof(zip64_eocd), path, err))
        {
            return false;
        }
    }
    if (read_zip_u32(zip64_eocd) != zip64_eocd_signature ||
        read_zip_u64(zip64_eocd + 4) < 44)
    {
        return true; // miniz will report malformed ZIP64 metadata.
    }

    const std::uint32_t zip64_disk_number = read_zip_u32(zip64_eocd + 16);
    const std::uint32_t zip64_central_directory_disk =
        read_zip_u32(zip64_eocd + 20);
    const std::uint64_t zip64_entries_on_disk = read_zip_u64(zip64_eocd + 24);
    const std::uint64_t zip64_total_entries = read_zip_u64(zip64_eocd + 32);
    if (zip64_disk_number != 0 || zip64_central_directory_disk != 0 ||
        zip64_entries_on_disk != zip64_total_entries)
    {
        return reject();
    }

    return true;
}

int duplicate_cloexec(int fd);

class PinnedArchiveSource
{
public:
    PinnedArchiveSource() = default;
    ~PinnedArchiveSource()
    {
        if (fd_ >= 0)
        {
            ::close(fd_);
        }
    }

    PinnedArchiveSource(const PinnedArchiveSource &) = delete;
    PinnedArchiveSource &operator=(const PinnedArchiveSource &) = delete;

    bool open(const std::string &path, std::string &err)
    {
        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0)
        {
            err = "archive: " + errno_message("cannot open archive", path,
                                                errno);
            return false;
        }

        struct stat st{};
        if (::fstat(fd, &st) != 0)
        {
            const int e = errno;
            ::close(fd);
            err = "archive: " + errno_message("cannot inspect archive", path,
                                                e);
            return false;
        }
        if (!S_ISREG(st.st_mode))
        {
            ::close(fd);
            err = "archive: archive source is not a regular file: '" + path +
                  "'";
            return false;
        }
        if (st.st_size < 0)
        {
            ::close(fd);
            err = "archive: archive source has a negative size: '" + path +
                  "'";
            return false;
        }

        fd_ = fd;
        size_ = static_cast<std::uint64_t>(st.st_size);
        path_ = path;
        return true;
    }

    int duplicate_rewound(std::string &err) const
    {
        if (::lseek(fd_, 0, SEEK_SET) < 0)
        {
            err = "archive: " + errno_message("cannot rewind archive", path_,
                                                errno);
            return -1;
        }
        const int duplicate = duplicate_cloexec(fd_);
        if (duplicate < 0)
        {
            err = "archive: " + errno_message(
                "cannot duplicate archive descriptor", path_, errno);
            return -1;
        }
        return duplicate;
    }

    [[nodiscard]] std::uint64_t size() const noexcept { return size_; }
    [[nodiscard]] const std::string &path() const noexcept { return path_; }

private:
    int fd_ = -1;
    std::uint64_t size_ = 0;
    std::string path_;
};

class ArchiveReader
{
public:
    ArchiveReader() = default;
    ~ArchiveReader()
    {
        if (opened_)
        {
            mz_zip_reader_end(&zip_);
        }
        if (file_ != nullptr)
        {
            std::fclose(file_);
        }
    }

    ArchiveReader(const ArchiveReader &) = delete;
    ArchiveReader &operator=(const ArchiveReader &) = delete;

    bool open(const std::string &path, std::string &err)
    {
        struct stat path_stat{};
        if (::stat(path.c_str(), &path_stat) != 0)
        {
            err = "archive: " + errno_message("cannot inspect ZIP archive",
                                                path, errno);
            return false;
        }
        if (!S_ISREG(path_stat.st_mode))
        {
            err = "archive: ZIP archive source is not a regular file: '" +
                  path + "'";
            return false;
        }

        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0)
        {
            err = "archive: " + errno_message("cannot open ZIP archive", path,
                                                errno);
            return false;
        }

        struct stat st{};
        if (::fstat(fd, &st) != 0)
        {
            const int e = errno;
            ::close(fd);
            err = "archive: " + errno_message("cannot inspect ZIP archive", path,
                                                e);
            return false;
        }
        if (!S_ISREG(st.st_mode))
        {
            ::close(fd);
            err = "archive: ZIP archive source is not a regular file: '" +
                  path + "'";
            return false;
        }

        return open_fd(fd, path, err);
    }

    bool open_fd(int fd, const std::string &path, std::string &err)
    {
        if (fd < 0)
        {
            err = "archive: invalid ZIP archive descriptor for '" + path +
                  "'";
            return false;
        }

        if (!reject_multi_volume_zip(fd, path, err))
        {
            ::close(fd);
            return false;
        }

        FILE *file = ::fdopen(fd, "rb");
        if (file == nullptr)
        {
            const int e = errno;
            ::close(fd);
            err = "archive: " + errno_message("cannot open ZIP archive stream",
                                                path, e);
            return false;
        }

        mz_zip_zero_struct(&zip_);
        allocation_state_ = {};
        zip_.m_pAlloc = bounded_miniz_alloc;
        zip_.m_pFree = bounded_miniz_free;
        zip_.m_pRealloc = bounded_miniz_realloc;
        zip_.m_pAlloc_opaque = &allocation_state_;
        if (!mz_zip_reader_init_cfile(&zip_, file, 0, 0))
        {
            err = miniz_error(zip_, "cannot open ZIP archive", path);
            if (zip_.m_pState != nullptr)
            {
                mz_zip_reader_end(&zip_);
            }
            std::fclose(file);
            return false;
        }
        file_ = file;
        opened_ = true;
        path_ = path;
        return true;
    }

    mz_zip_archive &zip() { return zip_; }
    const std::string &path() const { return path_; }

private:
    mz_zip_archive zip_{};
    MinizAllocationState allocation_state_{};
    FILE *file_ = nullptr;
    bool opened_ = false;
    std::string path_;
};

void raw_getfield(lua_State *L, int idx, const char *name)
{
    idx = lua_absindex(L, idx);
    lua_pushstring(L, name);
    lua_rawget(L, idx);
}

bool collect_archive_glob_list(
    lua_State *L, int options_index, const char *field_name,
    std::vector<babet::safe_glob::Pattern> &patterns,
    std::size_t &total_patterns, std::uint64_t &total_pattern_bytes,
    std::string &err)
{
    raw_getfield(L, options_index, field_name);
    if (lua_is_none_or_nil(L, -1))
    {
        lua_pop(L, 1);
        return true;
    }
    if (lua_type(L, -1) != LUA_TTABLE)
    {
        lua_pop(L, 1);
        err = std::string("opts.") + field_name +
              " must be a dense array of glob strings";
        return false;
    }

    const int list_index = lua_absindex(L, -1);
    const std::size_t count = lua_rawlen(L, list_index);
    std::size_t seen = 0;
    lua_pushnil(L);
    while (lua_next(L, list_index) != 0)
    {
        if (!lua_is_strict_integer(L, -2))
        {
            lua_pop(L, 3);
            err = std::string("opts.") + field_name +
                  " must be a dense array of glob strings";
            return false;
        }
        const lua_Integer key = lua_tointeger(L, -2);
        if (key < 1 || static_cast<std::size_t>(key) > count)
        {
            lua_pop(L, 3);
            err = std::string("opts.") + field_name +
                  " must be a dense array of glob strings";
            return false;
        }
        ++seen;
        lua_pop(L, 1);
    }
    if (seen != count)
    {
        lua_pop(L, 1);
        err = std::string("opts.") + field_name +
              " must be a dense array of glob strings";
        return false;
    }
    if (count > HARD_MAX_ARCHIVE_FILTER_PATTERNS - total_patterns)
    {
        lua_pop(L, 1);
        err = "archive: include/exclude filters exceed the internal 256-pattern limit";
        return false;
    }

    patterns.reserve(patterns.size() + count);
    for (std::size_t index = 1; index <= count; ++index)
    {
        lua_rawgeti(L, list_index, static_cast<lua_Integer>(index));
        if (!lua_is_strict_string(L, -1))
        {
            lua_pop(L, 2);
            err = std::string("opts.") + field_name + "[" +
                  std::to_string(index) + "] must be a string";
            return false;
        }
        size_t length = 0;
        const char *data = lua_tolstring(L, -1, &length);
        if (length == 0)
        {
            lua_pop(L, 2);
            err = std::string("opts.") + field_name + "[" +
                  std::to_string(index) + "] must not be empty";
            return false;
        }
        if (std::memchr(data, '\0', length) != nullptr)
        {
            lua_pop(L, 2);
            err = std::string("opts.") + field_name + "[" +
                  std::to_string(index) + "] must not contain NUL bytes";
            return false;
        }
        if (length > HARD_MAX_ARCHIVE_FILTER_BYTES - total_pattern_bytes)
        {
            lua_pop(L, 2);
            err = "archive: include/exclude filters exceed the internal 256 KiB pattern-byte limit";
            return false;
        }

        babet::safe_glob::Pattern compiled;
        const std::optional<std::string> compile_error =
            babet::safe_glob::compile(std::string_view(data, length), false,
                                      compiled);
        if (compile_error.has_value())
        {
            lua_pop(L, 2);
            err = std::string("opts.") + field_name + "[" +
                  std::to_string(index) + "]: " + *compile_error;
            return false;
        }
        lua_pop(L, 1);
        patterns.push_back(std::move(compiled));
        ++total_patterns;
        total_pattern_bytes += length;
    }
    lua_pop(L, 1);
    return true;
}

enum class ArchiveFilterDecision
{
    included,
    excluded,
    not_included,
};

bool consume_archive_filter_work(ArchiveGlobFilter &filters,
                                 const babet::safe_glob::Pattern &pattern,
                                 std::string_view text, std::string &err)
{
    const std::uint64_t states =
        static_cast<std::uint64_t>(pattern.token_count()) + 1;
    const std::uint64_t bytes = static_cast<std::uint64_t>(text.size()) + 1;
    if (states > HARD_MAX_ARCHIVE_FILTER_WORK / bytes)
    {
        err = "archive: glob filtering exceeds the internal 100000000-cell work limit";
        return false;
    }
    const std::uint64_t work = states * bytes;
    if (work > HARD_MAX_ARCHIVE_FILTER_WORK - filters.work)
    {
        err = "archive: glob filtering exceeds the internal 100000000-cell work limit";
        return false;
    }
    filters.work += work;
    return true;
}

bool archive_pattern_matches(ArchiveGlobFilter &filters,
                             const babet::safe_glob::Pattern &pattern,
                             std::string_view archive_path, bool directory,
                             bool &matched, std::string &err)
{
    if (filters.evaluations >= HARD_MAX_ARCHIVE_FILTER_EVALUATIONS)
    {
        err = "archive: glob filtering exceeds the internal 1000000-evaluation limit";
        return false;
    }
    ++filters.evaluations;
    if (!consume_archive_filter_work(filters, pattern, archive_path, err))
    {
        return false;
    }
    matched = pattern.matches(archive_path);
    if (matched || !directory)
    {
        return true;
    }

    std::string directory_path(archive_path);
    directory_path.push_back('/');
    if (!consume_archive_filter_work(filters, pattern, directory_path, err))
    {
        return false;
    }
    matched = pattern.matches(directory_path);
    return true;
}

bool archive_patterns_match_any(
    ArchiveGlobFilter &filters,
    const std::vector<babet::safe_glob::Pattern> &patterns,
    std::string_view archive_path, bool directory, bool &matched,
    std::string &err)
{
    matched = false;
    for (const babet::safe_glob::Pattern &pattern : patterns)
    {
        bool current = false;
        if (!archive_pattern_matches(filters, pattern, archive_path, directory,
                                     current, err))
        {
            return false;
        }
        if (current)
        {
            matched = true;
        }
    }
    return true;
}

bool classify_archive_path(ArchiveGlobFilter &filters,
                           std::string_view archive_path, bool directory,
                           ArchiveFilterDecision &decision, std::string &err)
{
    bool matched = false;
    if (!archive_patterns_match_any(filters, filters.exclude_patterns,
                                    archive_path, directory, matched, err))
    {
        return false;
    }
    if (matched)
    {
        decision = ArchiveFilterDecision::excluded;
        return true;
    }
    if (filters.include_patterns.empty())
    {
        decision = ArchiveFilterDecision::included;
        return true;
    }
    if (!archive_patterns_match_any(filters, filters.include_patterns,
                                    archive_path, directory, matched, err))
    {
        return false;
    }
    decision = matched ? ArchiveFilterDecision::included
                       : ArchiveFilterDecision::not_included;
    return true;
}

bool validate_option_keys(lua_State *L, int idx, bool extraction,
                          bool filtering, std::string &err)
{
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = "archive options must be a table";
        return false;
    }

    static const std::unordered_set<std::string> common = {
        "max_entries", "max_entry_size", "max_total_size",
        "max_path_length", "max_total_name_bytes",
        "max_compression_ratio"};
    static const std::unordered_set<std::string> extract = {
        "max_entries", "max_entry_size", "max_total_size",
        "max_path_length", "max_total_name_bytes",
        "max_compression_ratio", "overwrite", "preserve_permissions"};
    static const std::unordered_set<std::string> selective_extract = {
        "max_entries", "max_entry_size", "max_total_size",
        "max_path_length", "max_total_name_bytes",
        "max_compression_ratio", "overwrite", "preserve_permissions",
        "dry_run", "include", "exclude"};
    const auto &allowed = filtering ? selective_extract
                                    : extraction ? extract : common;

    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 2);
            err = "archive option keys must be strings";
            return false;
        }
        size_t length = 0;
        const char *data = lua_tolstring(L, -2, &length);
        const std::string key(data, length);
        if (!allowed.contains(key))
        {
            lua_pop(L, 2);
            err = "unknown archive option: " + key;
            return false;
        }
        lua_pop(L, 1);
    }
    return true;
}

bool parse_positive_integer(lua_State *L, int table_index, const char *field,
                            std::uint64_t hard_max, std::uint64_t &value,
                            std::string &err)
{
    raw_getfield(L, table_index, field);
    if (!lua_is_optional_strict_integer(L, -1))
    {
        lua_pop(L, 1);
        err = std::string("opts.") + field + " must be an integer";
        return false;
    }
    if (lua_is_none_or_nil(L, -1))
    {
        lua_pop(L, 1);
        return true;
    }
    const lua_Integer parsed = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (parsed < 1 || static_cast<unsigned long long>(parsed) > hard_max)
    {
        err = std::string("opts.") + field + " must be between 1 and " +
              std::to_string(hard_max);
        return false;
    }
    value = static_cast<std::uint64_t>(parsed);
    return true;
}

bool parse_strict_boolean(lua_State *L, int table_index, const char *field,
                          bool &value, std::string &err)
{
    raw_getfield(L, table_index, field);
    if (!lua_is_optional_strict_boolean(L, -1))
    {
        lua_pop(L, 1);
        err = std::string("opts.") + field + " must be a boolean";
        return false;
    }
    if (lua_is_none_or_nil(L, -1))
    {
        lua_pop(L, 1);
        return true;
    }
    value = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    return true;
}

bool collect_options(lua_State *L, int idx, bool extraction,
                     bool filtering, ArchiveOptions &options,
                     std::string &err)
{
    if (!validate_option_keys(L, idx, extraction, filtering, err))
    {
        return false;
    }
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    idx = lua_absindex(L, idx);

    if (!parse_positive_integer(L, idx, "max_entries", HARD_MAX_ENTRIES,
                                options.max_entries, err) ||
        !parse_positive_integer(L, idx, "max_entry_size",
                                HARD_MAX_ENTRY_SIZE,
                                options.max_entry_size, err) ||
        !parse_positive_integer(L, idx, "max_total_size",
                                HARD_MAX_TOTAL_SIZE,
                                options.max_total_size, err) ||
        !parse_positive_integer(L, idx, "max_path_length",
                                HARD_MAX_PATH_LENGTH,
                                options.max_path_length, err) ||
        !parse_positive_integer(L, idx, "max_total_name_bytes",
                                HARD_MAX_TOTAL_NAME_BYTES,
                                options.max_total_name_bytes, err))
    {
        return false;
    }

    raw_getfield(L, idx, "max_compression_ratio");
    if (!lua_is_optional_strict_number(L, -1))
    {
        lua_pop(L, 1);
        err = "opts.max_compression_ratio must be a number";
        return false;
    }
    if (!lua_is_none_or_nil(L, -1))
    {
        const double ratio = lua_tonumber(L, -1);
        lua_pop(L, 1);
        if (!std::isfinite(ratio) || ratio < 1.0 ||
            ratio > HARD_MAX_COMPRESSION_RATIO)
        {
            err = "opts.max_compression_ratio must be finite and between 1 and 1000000000";
            return false;
        }
        options.max_compression_ratio = ratio;
    }
    else
    {
        lua_pop(L, 1);
    }

    if (extraction &&
        (!parse_strict_boolean(L, idx, "overwrite", options.overwrite, err) ||
         !parse_strict_boolean(L, idx, "preserve_permissions",
                               options.preserve_permissions, err)))
    {
        return false;
    }
    if (filtering)
    {
        if (!parse_strict_boolean(L, idx, "dry_run", options.dry_run, err))
        {
            return false;
        }
        std::size_t total_patterns = 0;
        std::uint64_t total_pattern_bytes = 0;
        if (!collect_archive_glob_list(L, idx, "include",
                                       options.filters.include_patterns,
                                       total_patterns, total_pattern_bytes, err) ||
            !collect_archive_glob_list(L, idx, "exclude",
                                       options.filters.exclude_patterns,
                                       total_patterns, total_pattern_bytes, err))
        {
            return false;
        }
    }
    return true;
}

bool read_archive_filename(mz_zip_archive &zip, mz_uint index,
                           std::string &name, std::string &err)
{
    const mz_uint required =
        mz_zip_reader_get_filename(&zip, index, nullptr, 0);
    if (required == 0)
    {
        err = "archive: cannot read entry name at index " +
              std::to_string(index + 1);
        return false;
    }

    std::vector<char> buffer(static_cast<std::size_t>(required) + 1, '\0');
    const mz_uint copied = mz_zip_reader_get_filename(
        &zip, index, buffer.data(), static_cast<mz_uint>(buffer.size()));
    if (copied == 0)
    {
        err = "archive: cannot read entry name at index " +
              std::to_string(index + 1);
        return false;
    }

    const std::size_t length = strnlen(buffer.data(), buffer.size());
    if (length == buffer.size())
    {
        err = "archive: unterminated entry name at index " +
              std::to_string(index + 1);
        return false;
    }
    if (copied != length + 1)
    {
        err = "archive: entry name contains an embedded NUL byte at index " +
              std::to_string(index + 1);
        return false;
    }
    name.assign(buffer.data(), length);
    return true;
}

EntryKind detect_entry_kind(const mz_zip_archive_file_stat &stat,
                            mode_t &unix_mode, bool &has_unix_mode)
{
    unix_mode = 0;
    has_unix_mode = false;
    const unsigned host_system = stat.m_version_made_by >> 8U;
    if (host_system == 3U || host_system == 19U) // Unix or macOS.
    {
        unix_mode = static_cast<mode_t>((stat.m_external_attr >> 16U) & 0xFFFFU);
        has_unix_mode = unix_mode != 0;
        const mode_t type = unix_mode & S_IFMT;
        if (type == S_IFLNK)
        {
            return EntryKind::symlink;
        }
        if (type == S_IFDIR)
        {
            return EntryKind::directory;
        }
        if (type != 0 && type != S_IFREG)
        {
            return EntryKind::unsupported;
        }
    }

    if (stat.m_is_directory)
    {
        return EntryKind::directory;
    }
    return EntryKind::regular;
}

bool is_valid_utf8(std::string_view value) noexcept
{
    const auto continuation = [](unsigned char byte)
    {
        return byte >= 0x80U && byte <= 0xBFU;
    };

    std::size_t i = 0;
    while (i < value.size())
    {
        const unsigned char first = static_cast<unsigned char>(value[i]);
        if (first <= 0x7FU)
        {
            ++i;
            continue;
        }
        if (first >= 0xC2U && first <= 0xDFU)
        {
            if (i + 1 >= value.size() ||
                !continuation(static_cast<unsigned char>(value[i + 1])))
            {
                return false;
            }
            i += 2;
            continue;
        }
        if (first >= 0xE0U && first <= 0xEFU)
        {
            if (i + 2 >= value.size())
            {
                return false;
            }
            const unsigned char second =
                static_cast<unsigned char>(value[i + 1]);
            const unsigned char third =
                static_cast<unsigned char>(value[i + 2]);
            if (!continuation(third) ||
                (first == 0xE0U && (second < 0xA0U || second > 0xBFU)) ||
                (first == 0xEDU && (second < 0x80U || second > 0x9FU)) ||
                (first != 0xE0U && first != 0xEDU &&
                 !continuation(second)))
            {
                return false;
            }
            i += 3;
            continue;
        }
        if (first >= 0xF0U && first <= 0xF4U)
        {
            if (i + 3 >= value.size())
            {
                return false;
            }
            const unsigned char second =
                static_cast<unsigned char>(value[i + 1]);
            const unsigned char third =
                static_cast<unsigned char>(value[i + 2]);
            const unsigned char fourth =
                static_cast<unsigned char>(value[i + 3]);
            if (!continuation(third) || !continuation(fourth) ||
                (first == 0xF0U && (second < 0x90U || second > 0xBFU)) ||
                (first == 0xF4U && (second < 0x80U || second > 0x8FU)) ||
                (first != 0xF0U && first != 0xF4U &&
                 !continuation(second)))
            {
                return false;
            }
            i += 4;
            continue;
        }
        return false;
    }
    return true;
}

bool validate_entry_path(const std::string &name, EntryKind kind,
                         std::string &normalized, std::string &reason)
{
    normalized.clear();
    reason.clear();

    if (name.empty())
    {
        reason = "empty entry name";
        return false;
    }
    if (name.size() > MAX_SAFE_ARCHIVE_PATH_BYTES)
    {
        reason = "entry name exceeds 4096 bytes";
        return false;
    }
    if (name.find('\0') != std::string::npos)
    {
        reason = "entry name contains a NUL byte";
        return false;
    }
    if (name.find('\\') != std::string::npos)
    {
        reason = "entry name contains a backslash";
        return false;
    }
    if (name.front() == '/')
    {
        reason = "absolute entry path";
        return false;
    }

    const bool trailing_slash = name.back() == '/';
    if (trailing_slash && kind != EntryKind::directory)
    {
        reason = "non-directory entry name ends with '/'";
        return false;
    }

    std::size_t start = 0;
    bool first = true;
    while (start < name.size())
    {
        const std::size_t slash = name.find('/', start);
        const std::size_t end = slash == std::string::npos ? name.size() : slash;
        const std::string_view component(name.data() + start, end - start);

        if (component.empty())
        {
            if (slash == name.size() - 1 && kind == EntryKind::directory)
            {
                break;
            }
            reason = "entry path contains an empty component";
            return false;
        }
        if (component == "." || component == "..")
        {
            reason = "entry path contains '.' or '..'";
            return false;
        }
        if (first && component.size() >= 2 && component[1] == ':' &&
            ((component[0] >= 'A' && component[0] <= 'Z') ||
             (component[0] >= 'a' && component[0] <= 'z')))
        {
            reason = "entry path uses a drive prefix";
            return false;
        }

        if (!normalized.empty())
        {
            normalized.push_back('/');
        }
        normalized.append(component);
        first = false;

        if (slash == std::string::npos)
        {
            break;
        }
        start = slash + 1;
    }

    if (normalized.empty())
    {
        reason = "empty normalized entry path";
        return false;
    }
    return true;
}

std::string entry_kind_name(EntryKind kind)
{
    switch (kind)
    {
    case EntryKind::regular:
        return "file";
    case EntryKind::directory:
        return "directory";
    case EntryKind::symlink:
        return "symlink";
    case EntryKind::hardlink:
        return "hardlink";
    case EntryKind::fifo:
        return "fifo";
    case EntryKind::character_device:
        return "character_device";
    case EntryKind::block_device:
        return "block_device";
    case EntryKind::socket:
        return "socket";
    case EntryKind::unsupported:
        return "unsupported";
    }
    return "unsupported";
}

std::string extraction_rejection_reason(const ArchiveEntry &entry)
{
    if (!entry.safe_path)
    {
        return entry.path_error;
    }
    if (entry.encrypted)
    {
        return "encrypted entries are not supported";
    }
    if (!entry.supported)
    {
        return "compression method is not supported";
    }
    if (entry.kind == EntryKind::symlink)
    {
        return "symlink entries are refused";
    }
    if (entry.kind == EntryKind::hardlink)
    {
        return "hard link entries are refused";
    }
    if (entry.kind == EntryKind::fifo)
    {
        return "FIFO entries are refused";
    }
    if (entry.kind == EntryKind::character_device)
    {
        return "character-device entries are refused";
    }
    if (entry.kind == EntryKind::block_device)
    {
        return "block-device entries are refused";
    }
    if (entry.kind == EntryKind::socket)
    {
        return "socket entries are refused";
    }
    if (entry.kind == EntryKind::unsupported)
    {
        return "unsupported filesystem entry type";
    }
    if (entry.sparse)
    {
        return "sparse TAR entries are refused";
    }
    return {};
}

bool scan_zip_archive(ArchiveReader &reader, const ArchiveOptions &options,
                      ArchiveScan &scan, std::string &err)
{
    constexpr std::uint64_t central_header_disk_start_offset = 34;
    scan.format = ArchiveFormat::zip;
    scan.compression = ArchiveCompression::none;
    mz_zip_archive &zip = reader.zip();
    const mz_uint count = mz_zip_reader_get_num_files(&zip);
    if (static_cast<std::uint64_t>(count) > options.max_entries)
    {
        err = "archive: entry count exceeds max_entries (" +
              std::to_string(count) + " > " +
              std::to_string(options.max_entries) + ")";
        return false;
    }

    scan.archive_size = mz_zip_get_archive_size(&zip);
    scan.zip64 = mz_zip_is_zip64(&zip) != 0;
    scan.entries.reserve(count);

    std::uint64_t total = 0;
    std::uint64_t total_name_bytes = 0;
    for (mz_uint index = 0; index < count; ++index)
    {
        mz_zip_archive_file_stat stat{};
        if (!mz_zip_reader_file_stat(&zip, index, &stat))
        {
            err = miniz_error(zip, "cannot inspect ZIP entry", reader.path());
            return false;
        }

        if (stat.m_central_dir_ofs >
                std::numeric_limits<std::uint64_t>::max() -
                    zip.m_central_directory_file_ofs ||
            zip.m_central_directory_file_ofs + stat.m_central_dir_ofs >
                std::numeric_limits<std::uint64_t>::max() -
                    central_header_disk_start_offset)
        {
            err = "archive: ZIP central-directory offset is out of range in '" +
                  reader.path() + "'";
            return false;
        }
        const std::uint64_t disk_start_offset =
            zip.m_central_directory_file_ofs + stat.m_central_dir_ofs +
            central_header_disk_start_offset;
        unsigned char disk_start_bytes[2]{};
        if (mz_zip_read_archive_data(&zip, disk_start_offset,
                                     disk_start_bytes,
                                     sizeof(disk_start_bytes)) !=
            sizeof(disk_start_bytes))
        {
            err = "archive: cannot inspect ZIP disk metadata in '" +
                  reader.path() + "'";
            return false;
        }
        if (read_zip_u16(disk_start_bytes) != 0)
        {
            err = "archive: split or multi-volume ZIP archives are not supported: '" +
                  reader.path() + "' (entry " +
                  std::to_string(index + 1) + " starts on another disk)";
            return false;
        }

        ArchiveEntry entry;
        entry.index = index;
        if (!read_archive_filename(zip, index, entry.name, err))
        {
            return false;
        }
        if (entry.name.size() > options.max_path_length)
        {
            err = "archive: entry name at index " +
                  std::to_string(index + 1) +
                  " exceeds max_path_length (" +
                  std::to_string(entry.name.size()) + " > " +
                  std::to_string(options.max_path_length) + ")";
            return false;
        }
        if (total_name_bytes > options.max_total_name_bytes ||
            entry.name.size() > options.max_total_name_bytes - total_name_bytes)
        {
            err = "archive: cumulative entry-name size exceeds max_total_name_bytes";
            return false;
        }
        total_name_bytes += entry.name.size();
        entry.valid_utf8 = is_valid_utf8(entry.name);
        entry.kind = detect_entry_kind(stat, entry.unix_mode,
                                       entry.has_unix_mode);
        entry.compressed_size = stat.m_comp_size;
        entry.size = stat.m_uncomp_size;
        entry.crc32 = stat.m_crc32;
        entry.method = stat.m_method;
        entry.bit_flags = stat.m_bit_flag;
        entry.local_header_offset = stat.m_local_header_ofs;
        entry.version_made_by = stat.m_version_made_by;
        entry.external_attributes = stat.m_external_attr;
#ifndef MINIZ_NO_TIME
        entry.mtime = static_cast<std::int64_t>(stat.m_time);
        entry.has_mtime = true;
#endif
        entry.encrypted = stat.m_is_encrypted != 0;
        entry.supported = stat.m_is_supported != 0;
        entry.safe_path = validate_entry_path(entry.name, entry.kind,
                                              entry.normalized,
                                              entry.path_error);

        if (entry.kind != EntryKind::directory)
        {
            if (entry.size > options.max_entry_size)
            {
                err = "archive: entry '" + entry.name +
                      "' exceeds max_entry_size (" +
                      std::to_string(entry.size) + " > " +
                      std::to_string(options.max_entry_size) + ")";
                return false;
            }
            if (entry.size > 0)
            {
                if (entry.compressed_size == 0)
                {
                    err = "archive: entry '" + entry.name +
                          "' has a zero compressed size and a non-zero expanded size";
                    return false;
                }
                const long double ratio =
                    static_cast<long double>(entry.size) /
                    static_cast<long double>(entry.compressed_size);
                if (ratio > static_cast<long double>(
                                options.max_compression_ratio))
                {
                    err = "archive: entry '" + entry.name +
                          "' exceeds max_compression_ratio";
                    return false;
                }
            }
            if (entry.size > options.max_total_size - total)
            {
                err = "archive: total expanded size exceeds max_total_size";
                return false;
            }
            total += entry.size;
        }
        scan.entries.push_back(std::move(entry));
    }
    scan.total_size = total;
    scan.total_name_bytes = total_name_bytes;
    return true;
}

EntryKind tar_entry_kind(babet::archive_tar::EntryType type)
{
    using TarType = babet::archive_tar::EntryType;
    switch (type)
    {
    case TarType::regular:
        return EntryKind::regular;
    case TarType::directory:
        return EntryKind::directory;
    case TarType::symlink:
        return EntryKind::symlink;
    case TarType::hardlink:
        return EntryKind::hardlink;
    case TarType::fifo:
        return EntryKind::fifo;
    case TarType::character_device:
        return EntryKind::character_device;
    case TarType::block_device:
        return EntryKind::block_device;
    case TarType::socket:
        return EntryKind::socket;
    case TarType::unsupported:
        return EntryKind::unsupported;
    }
    return EntryKind::unsupported;
}

bool scan_tar_archive(PinnedArchiveSource &source,
                      const ArchiveOptions &options, ArchiveScan &scan,
                      std::string &err,
                      babet::archive_tar::ScanResult *raw_result = nullptr)
{
    const int fd = source.duplicate_rewound(err);
    if (fd < 0)
    {
        return false;
    }

    babet::archive_tar::ScanResult tar_scan;
    const babet::archive_tar::ScanLimits limits{
        .max_entries = options.max_entries,
        .max_entry_size = options.max_entry_size,
        .max_total_size = options.max_total_size,
        .max_path_length = options.max_path_length,
        .max_total_name_bytes = options.max_total_name_bytes,
        .max_compression_ratio = options.max_compression_ratio,
    };
    const bool scanned = babet::archive_tar::scan_fd(
        fd, source.size(), source.path(), limits, tar_scan, err);
    ::close(fd);
    if (!scanned)
    {
        return false;
    }

    scan = {};
    scan.format = ArchiveFormat::tar;
    scan.compression =
        tar_scan.compression == babet::archive_tar::Compression::gzip
            ? ArchiveCompression::gzip
            : tar_scan.compression == babet::archive_tar::Compression::xz
                  ? ArchiveCompression::xz
                  : tar_scan.compression ==
                            babet::archive_tar::Compression::bzip2
                        ? ArchiveCompression::bzip2
                        : tar_scan.compression ==
                                  babet::archive_tar::Compression::zstd
                              ? ArchiveCompression::zstd
                              : ArchiveCompression::none;
    scan.total_size = tar_scan.total_size;
    scan.archive_size = tar_scan.archive_size;
    scan.total_name_bytes = tar_scan.total_name_bytes;
    scan.entries.reserve(tar_scan.entries.size());
    for (std::size_t index = 0; index < tar_scan.entries.size(); ++index)
    {
        const babet::archive_tar::Entry &tar_entry = tar_scan.entries[index];
        ArchiveEntry entry;
        entry.index = static_cast<mz_uint>(index);
        entry.name = tar_entry.name;
        entry.kind = tar_entry_kind(tar_entry.type);
        entry.size = tar_entry.size;
        entry.has_compressed_size = false;
        entry.has_crc32 = false;
        entry.has_compression_method = false;
        entry.unix_mode = static_cast<mode_t>(tar_entry.unix_mode);
        entry.has_unix_mode = tar_entry.has_unix_mode;
        entry.mtime = tar_entry.mtime;
        entry.mtime_nsec = tar_entry.mtime_nsec;
        entry.has_mtime = tar_entry.has_mtime;
        entry.has_mtime_nsec = tar_entry.has_mtime;
        entry.uid = tar_entry.uid;
        entry.gid = tar_entry.gid;
        entry.has_uid = tar_entry.has_uid;
        entry.has_gid = tar_entry.has_gid;
        entry.valid_utf8 = is_valid_utf8(entry.name);
        entry.encrypted = false;
        entry.supported = true;
        entry.sparse = tar_entry.sparse;
        entry.has_link_target = tar_entry.has_link_target;
        entry.link_target = tar_entry.link_target;
        entry.safe_path = validate_entry_path(entry.name, entry.kind,
                                              entry.normalized,
                                              entry.path_error);
        scan.entries.push_back(std::move(entry));
    }
    if (raw_result != nullptr)
    {
        *raw_result = std::move(tar_scan);
    }
    return true;
}

bool annotate_list_conflicts(ArchiveScan &scan, std::string &err)
{
    std::unordered_map<std::string, std::size_t> first_raw_name;
    std::unordered_map<std::string, std::size_t> explicit_paths;
    std::unordered_map<std::string, std::size_t> directories;
    std::unordered_map<std::string, std::size_t> files;
    std::uint64_t directory_path_bytes = 0;

    const auto remember_directory = [&](const std::string &path,
                                        std::size_t index) -> bool
    {
        const auto [unused, inserted] = directories.emplace(path, index);
        (void)unused;
        if (!inserted)
        {
            return true;
        }
        if (directories.size() > HARD_MAX_OUTPUT_DIRECTORIES)
        {
            err = "archive: inspection path graph exceeds the internal "
                  "100000-directory limit";
            return false;
        }
        if (directory_path_bytes > HARD_MAX_OUTPUT_DIRECTORY_PATH_BYTES ||
            path.size() > HARD_MAX_OUTPUT_DIRECTORY_PATH_BYTES -
                              directory_path_bytes)
        {
            err = "archive: cumulative inspection directory paths exceed "
                  "the internal 64 MiB limit";
            return false;
        }
        directory_path_bytes += path.size();
        return true;
    };

    for (std::size_t index = 0; index < scan.entries.size(); ++index)
    {
        ArchiveEntry &entry = scan.entries[index];
        const auto [raw_it, raw_inserted] =
            first_raw_name.emplace(entry.name, index);
        if (!raw_inserted)
        {
            entry.duplicate = true;
            entry.duplicate_of = raw_it->second + 1;
            ++scan.duplicate_entries;
        }

        if (!entry.safe_path)
        {
            continue;
        }

        std::optional<std::size_t> conflicting_index;
        std::string reason;
        const auto note_conflict = [&](std::size_t candidate,
                                       std::string_view candidate_reason)
        {
            if (!conflicting_index.has_value() || candidate < *conflicting_index)
            {
                conflicting_index = candidate;
                reason.assign(candidate_reason);
            }
        };

        const auto explicit_it = explicit_paths.find(entry.normalized);
        if (explicit_it != explicit_paths.end())
        {
            const ArchiveEntry &previous = scan.entries[explicit_it->second];
            const bool directory_mismatch =
                (previous.kind == EntryKind::directory) !=
                (entry.kind == EntryKind::directory);
            note_conflict(
                explicit_it->second,
                directory_mismatch ? "file/directory path conflict"
                                   : "duplicate output path");
        }

        std::size_t pos = 0;
        while ((pos = entry.normalized.find('/', pos)) != std::string::npos)
        {
            const std::string prefix = entry.normalized.substr(0, pos);
            const auto file_it = files.find(prefix);
            if (file_it != files.end())
            {
                note_conflict(file_it->second,
                              "file/directory path conflict");
            }
            if (!remember_directory(prefix, index))
            {
                return false;
            }
            ++pos;
        }

        if (entry.kind == EntryKind::directory)
        {
            const auto file_it = files.find(entry.normalized);
            if (file_it != files.end())
            {
                note_conflict(file_it->second,
                              "file/directory path conflict");
            }
            if (!remember_directory(entry.normalized, index))
            {
                return false;
            }
        }
        else
        {
            const auto directory_it = directories.find(entry.normalized);
            if (directory_it != directories.end())
            {
                note_conflict(directory_it->second,
                              "file/directory path conflict");
            }
            files.emplace(entry.normalized, index);
        }
        explicit_paths.emplace(entry.normalized, index);

        if (conflicting_index.has_value())
        {
            entry.conflict = true;
            entry.conflict_with = *conflicting_index + 1;
            entry.conflict_reason = std::move(reason);
            ++scan.conflicting_entries;
        }
    }
    return true;
}

bool validate_selected_entries(const std::vector<const ArchiveEntry *> &entries,
                               std::string &err)
{
    std::unordered_set<std::string> explicit_paths;
    std::unordered_set<std::string> directories;
    std::unordered_set<std::string> files;
    std::uint64_t directory_path_bytes = 0;

    auto remember_directory = [&](const std::string &path) -> bool
    {
        const auto [unused, inserted] = directories.insert(path);
        (void)unused;
        if (!inserted)
        {
            return true;
        }
        if (directories.size() > HARD_MAX_OUTPUT_DIRECTORIES)
        {
            err = "archive: output tree exceeds the internal 100000-directory limit";
            return false;
        }
        if (directory_path_bytes > HARD_MAX_OUTPUT_DIRECTORY_PATH_BYTES ||
            path.size() > HARD_MAX_OUTPUT_DIRECTORY_PATH_BYTES -
                              directory_path_bytes)
        {
            err = "archive: cumulative output-directory paths exceed the internal 64 MiB limit";
            return false;
        }
        directory_path_bytes += path.size();
        return true;
    };

    for (const ArchiveEntry *entry : entries)
    {
        const std::string rejection = extraction_rejection_reason(*entry);
        if (!rejection.empty())
        {
            err = "archive: entry '" + entry->name + "' cannot be extracted: " +
                  rejection;
            return false;
        }

        if (!explicit_paths.insert(entry->normalized).second)
        {
            err = "archive: duplicate output path '" + entry->normalized + "'";
            return false;
        }

        std::size_t pos = 0;
        while ((pos = entry->normalized.find('/', pos)) != std::string::npos)
        {
            const std::string prefix = entry->normalized.substr(0, pos);
            if (files.contains(prefix))
            {
                err = "archive: path conflict between file '" + prefix +
                      "' and entry '" + entry->normalized + "'";
                return false;
            }
            if (!remember_directory(prefix))
            {
                return false;
            }
            ++pos;
        }

        if (entry->kind == EntryKind::directory)
        {
            if (files.contains(entry->normalized))
            {
                err = "archive: path conflict at '" + entry->normalized + "'";
                return false;
            }
            if (!remember_directory(entry->normalized))
            {
                return false;
            }
        }
        else
        {
            if (directories.contains(entry->normalized))
            {
                err = "archive: path conflict at '" + entry->normalized + "'";
                return false;
            }
            files.insert(entry->normalized);
        }
    }
    return true;
}

int duplicate_cloexec(int fd)
{
#ifdef F_DUPFD_CLOEXEC
    return ::fcntl(fd, F_DUPFD_CLOEXEC, 3);
#else
    int result = ::dup(fd);
    if (result >= 0)
    {
        const int flags = ::fcntl(result, F_GETFD, 0);
        if (flags >= 0)
        {
            ::fcntl(result, F_SETFD, flags | FD_CLOEXEC);
        }
    }
    return result;
#endif
}

struct StagedFile
{
    fs::path relative;
    std::string temporary;
};

enum class DestinationAction
{
    create,
    overwrite,
    skip,
};

struct ExtractCallbackState
{
    int fd = -1;
    std::uint64_t expected = 0;
    std::uint64_t written = 0;
    int error_number = 0;
};

struct VerifyCallbackState
{
    std::uint64_t expected = 0;
    std::uint64_t read = 0;
    bool invalid_layout = false;
};

struct ZipEntryRange
{
    std::uint64_t begin = 0;
    std::uint64_t end = 0;
    std::string_view name;
};

bool checked_zip_add(std::uint64_t left, std::uint64_t right,
                     std::uint64_t &result) noexcept
{
    if (left > std::numeric_limits<std::uint64_t>::max() - right)
    {
        return false;
    }
    result = left + right;
    return true;
}

bool read_zip_exact(mz_zip_archive &zip, std::uint64_t offset, void *buffer,
                    std::size_t size, const ArchiveEntry &entry,
                    std::string_view subject, std::string &err)
{
    if (size != 0 && mz_zip_read_archive_data(&zip, offset, buffer, size) != size)
    {
        err = "archive: cannot read ZIP " + std::string(subject) +
              " for entry '" + entry.name + "'";
        return false;
    }
    return true;
}

bool read_zip64_local_sizes(const std::vector<unsigned char> &extra,
                            std::uint32_t size32,
                            std::uint32_t compressed_size32,
                            std::uint64_t &size,
                            std::uint64_t &compressed_size,
                            const ArchiveEntry &entry, std::string &err)
{
    size = size32;
    compressed_size = compressed_size32;
    if (size32 != std::numeric_limits<std::uint32_t>::max() &&
        compressed_size32 != std::numeric_limits<std::uint32_t>::max())
    {
        return true;
    }

    std::size_t offset = 0;
    while (offset < extra.size())
    {
        if (extra.size() - offset < 4)
        {
            err = "archive: truncated ZIP local extra field for entry '" +
                  entry.name + "'";
            return false;
        }
        const std::uint16_t field_id = read_zip_u16(extra.data() + offset);
        const std::uint16_t field_size =
            read_zip_u16(extra.data() + offset + 2);
        offset += 4;
        if (field_size > extra.size() - offset)
        {
            err = "archive: truncated ZIP local extra field for entry '" +
                  entry.name + "'";
            return false;
        }
        if (field_id == 0x0001)
        {
            std::size_t field_offset = offset;
            const std::size_t field_end = offset + field_size;
            if (size32 == std::numeric_limits<std::uint32_t>::max())
            {
                if (field_end - field_offset < 8)
                {
                    err = "archive: incomplete ZIP64 local size for entry '" +
                          entry.name + "'";
                    return false;
                }
                size = read_zip_u64(extra.data() + field_offset);
                field_offset += 8;
            }
            if (compressed_size32 ==
                std::numeric_limits<std::uint32_t>::max())
            {
                if (field_end - field_offset < 8)
                {
                    err = "archive: incomplete ZIP64 local compressed size for entry '" +
                          entry.name + "'";
                    return false;
                }
                compressed_size = read_zip_u64(extra.data() + field_offset);
            }
            return true;
        }
        offset += field_size;
    }

    err = "archive: missing ZIP64 local size metadata for entry '" +
          entry.name + "'";
    return false;
}

bool validate_zip_data_descriptor(mz_zip_archive &zip,
                                  const ArchiveEntry &entry,
                                  std::uint64_t descriptor_offset,
                                  std::uint64_t archive_size,
                                  std::uint64_t &descriptor_size,
                                  std::string &err)
{
    if (descriptor_offset > archive_size)
    {
        err = "archive: ZIP data descriptor is outside the archive for entry '" +
              entry.name + "'";
        return false;
    }
    const std::uint64_t available = archive_size - descriptor_offset;
    const std::size_t wanted = static_cast<std::size_t>(
        std::min<std::uint64_t>(available, 24));
    std::array<unsigned char, 24> data{};
    if (!read_zip_exact(zip, descriptor_offset, data.data(), wanted, entry,
                        "data descriptor", err))
    {
        return false;
    }

    const auto matches32 = [&](std::size_t base) {
        return wanted >= base + 12 &&
               read_zip_u32(data.data() + base) == entry.crc32 &&
               entry.compressed_size <=
                   std::numeric_limits<std::uint32_t>::max() &&
               entry.size <= std::numeric_limits<std::uint32_t>::max() &&
               read_zip_u32(data.data() + base + 4) == entry.compressed_size &&
               read_zip_u32(data.data() + base + 8) == entry.size;
    };
    const auto matches64 = [&](std::size_t base) {
        return wanted >= base + 20 &&
               read_zip_u32(data.data() + base) == entry.crc32 &&
               read_zip_u64(data.data() + base + 4) == entry.compressed_size &&
               read_zip_u64(data.data() + base + 12) == entry.size;
    };

    const bool signature_candidate =
        wanted >= 4 && read_zip_u32(data.data()) == 0x08074b50U;
    if (signature_candidate && matches32(4))
    {
        descriptor_size = 16;
        return true;
    }
    if (signature_candidate && matches64(4))
    {
        descriptor_size = 24;
        return true;
    }
    // A descriptor without an optional signature may legitimately have a CRC
    // equal to 0x08074b50. Try the unsigned layout as well instead of treating
    // the first CRC word as an unambiguous signature.
    if (matches32(0))
    {
        descriptor_size = 12;
        return true;
    }
    if (matches64(0))
    {
        descriptor_size = 20;
        return true;
    }

    err = "archive: ZIP data descriptor disagrees with the central directory for entry '" +
          entry.name + "'";
    return false;
}

bool validate_zip_local_header(mz_zip_archive &zip,
                               const ArchiveEntry &entry,
                               std::uint64_t archive_size,
                               std::uint64_t central_directory_offset,
                               ZipEntryRange &range, std::string &err)
{
    constexpr std::size_t header_size = 30;
    std::array<unsigned char, header_size> header{};
    if (!read_zip_exact(zip, entry.local_header_offset, header.data(),
                        header.size(), entry, "local header", err))
    {
        return false;
    }
    if (read_zip_u32(header.data()) != 0x04034b50U)
    {
        err = "archive: invalid ZIP local-header signature for entry '" +
              entry.name + "'";
        return false;
    }

    const std::uint16_t local_flags = read_zip_u16(header.data() + 6);
    const std::uint16_t local_method = read_zip_u16(header.data() + 8);
    const std::uint32_t local_crc = read_zip_u32(header.data() + 14);
    const std::uint32_t local_compressed_size32 =
        read_zip_u32(header.data() + 18);
    const std::uint32_t local_size32 = read_zip_u32(header.data() + 22);
    const std::uint16_t name_size = read_zip_u16(header.data() + 26);
    const std::uint16_t extra_size = read_zip_u16(header.data() + 28);

    if (local_flags != entry.bit_flags || local_method != entry.method)
    {
        err = "archive: ZIP local header disagrees with the central directory for entry '" +
              entry.name + "'";
        return false;
    }
    if (name_size != entry.name.size())
    {
        err = "archive: ZIP local filename length disagrees with the central directory for entry '" +
              entry.name + "'";
        return false;
    }

    std::uint64_t name_offset = 0;
    std::uint64_t extra_offset = 0;
    std::uint64_t data_offset = 0;
    std::uint64_t data_end = 0;
    if (!checked_zip_add(entry.local_header_offset, header_size, name_offset) ||
        !checked_zip_add(name_offset, name_size, extra_offset) ||
        !checked_zip_add(extra_offset, extra_size, data_offset) ||
        !checked_zip_add(data_offset, entry.compressed_size, data_end) ||
        data_end > archive_size || data_end > central_directory_offset)
    {
        err = "archive: ZIP local entry range is out of bounds for entry '" +
              entry.name + "'";
        return false;
    }

    std::vector<unsigned char> local_name(name_size);
    if (!read_zip_exact(zip, name_offset, local_name.data(), local_name.size(),
                        entry, "local filename", err))
    {
        return false;
    }
    if (!std::equal(local_name.begin(), local_name.end(), entry.name.begin(),
                    entry.name.end()))
    {
        err = "archive: ZIP local filename disagrees with the central directory for entry '" +
              entry.name + "'";
        return false;
    }

    std::vector<unsigned char> extra(extra_size);
    if (!read_zip_exact(zip, extra_offset, extra.data(), extra.size(), entry,
                        "local extra field", err))
    {
        return false;
    }
    std::uint64_t local_size = 0;
    std::uint64_t local_compressed_size = 0;
    if (!read_zip64_local_sizes(extra, local_size32,
                                local_compressed_size32, local_size,
                                local_compressed_size, entry, err))
    {
        return false;
    }

    std::uint64_t descriptor_size = 0;
    if ((local_flags & 0x0008U) != 0)
    {
        const bool local_values_are_permitted =
            (local_crc == 0 || local_crc == entry.crc32) &&
            (local_compressed_size == 0 ||
             local_compressed_size == entry.compressed_size) &&
            (local_size == 0 || local_size == entry.size);
        if (!local_values_are_permitted ||
            !validate_zip_data_descriptor(zip, entry, data_end, archive_size,
                                          descriptor_size, err))
        {
            if (!local_values_are_permitted)
            {
                err = "archive: ZIP local sizes disagree with the central directory for entry '" +
                      entry.name + "'";
            }
            return false;
        }
    }
    else if (local_crc != entry.crc32 ||
             local_compressed_size != entry.compressed_size ||
             local_size != entry.size)
    {
        err = "archive: ZIP local sizes or CRC disagree with the central directory for entry '" +
              entry.name + "'";
        return false;
    }

    std::uint64_t range_end = 0;
    if (!checked_zip_add(data_end, descriptor_size, range_end) ||
        range_end > central_directory_offset)
    {
        err = "archive: ZIP entry overlaps the central directory for entry '" +
              entry.name + "'";
        return false;
    }
    range = {entry.local_header_offset, range_end, entry.name};
    return true;
}

size_t verify_read_callback(void *opaque, mz_uint64 file_offset,
                            const void *buffer, size_t size)
{
    auto *state = static_cast<VerifyCallbackState *>(opaque);
    if ((buffer == nullptr && size != 0) ||
        state->read > state->expected ||
        file_offset != state->read ||
        size > state->expected - state->read)
    {
        state->invalid_layout = true;
        return 0;
    }
    state->read += size;
    return size;
}

bool verify_zip_payloads(ArchiveReader &reader, const ArchiveScan &scan,
                         std::string &err)
{
    mz_zip_archive &zip = reader.zip();
    std::vector<ZipEntryRange> ranges;
    ranges.reserve(scan.entries.size());

    for (const ArchiveEntry &entry : scan.entries)
    {
        if (entry.encrypted)
        {
            err = "archive: cannot fully test encrypted ZIP entry '" +
                  entry.name + "'";
            return false;
        }
        if (!entry.supported)
        {
            err = "archive: cannot fully test ZIP entry '" + entry.name +
                  "': compression method is not supported";
            return false;
        }
        if (entry.kind == EntryKind::directory &&
            (entry.size != 0 || entry.compressed_size != 0))
        {
            err = "archive: ZIP directory entry '" + entry.name +
                  "' unexpectedly contains file data";
            return false;
        }
        if (entry.size == 0 && entry.crc32 != 0)
        {
            err = "archive: zero-length ZIP entry '" + entry.name +
                  "' has a non-zero CRC";
            return false;
        }

        ZipEntryRange range;
        if (!validate_zip_local_header(zip, entry, scan.archive_size,
                                       zip.m_central_directory_file_ofs,
                                       range, err))
        {
            return false;
        }
        ranges.push_back(range);

        if (entry.kind == EntryKind::directory)
        {
            continue;
        }
        VerifyCallbackState state;
        state.expected = entry.size;
        const mz_bool extracted = mz_zip_reader_extract_to_callback(
            &zip, entry.index, verify_read_callback, &state, 0);
        if (!extracted || state.read != entry.size)
        {
            if (state.invalid_layout)
            {
                err = "archive: ZIP entry '" + entry.name +
                      "' returned invalid or non-contiguous data while testing";
            }
            else
            {
                err = miniz_error(zip, "cannot fully test ZIP entry",
                                  entry.name);
            }
            return false;
        }
    }

    std::sort(ranges.begin(), ranges.end(),
              [](const ZipEntryRange &left, const ZipEntryRange &right) {
                  return left.begin < right.begin;
              });
    for (std::size_t index = 1; index < ranges.size(); ++index)
    {
        if (ranges[index].begin < ranges[index - 1].end)
        {
            err = "archive: overlapping ZIP local entries '" +
                  std::string(ranges[index - 1].name) + "' and '" +
                  std::string(ranges[index].name) + "'";
            return false;
        }
    }
    return true;
}

bool verify_selected_zip_payloads(
    ArchiveReader &reader, const std::vector<const ArchiveEntry *> &entries,
    std::string &err)
{
    mz_zip_archive &zip = reader.zip();
    for (const ArchiveEntry *entry : entries)
    {
        if (entry->kind != EntryKind::regular)
        {
            continue;
        }
        VerifyCallbackState state;
        state.expected = entry->size;
        const mz_bool extracted = mz_zip_reader_extract_to_callback(
            &zip, entry->index, verify_read_callback, &state, 0);
        if (!extracted || state.read != entry->size)
        {
            if (state.invalid_layout)
            {
                err = "archive: ZIP entry '" + entry->name +
                      "' returned invalid or non-contiguous data during dry run";
            }
            else
            {
                err = miniz_error(zip, "cannot simulate ZIP extraction",
                                  entry->name);
            }
            return false;
        }
    }
    return true;
}

size_t extract_write_callback(void *opaque, mz_uint64 file_offset,
                              const void *buffer, size_t size)
{
    auto *state = static_cast<ExtractCallbackState *>(opaque);
    if (state->written > state->expected ||
        file_offset != state->written ||
        size > state->expected - state->written)
    {
        state->error_number = EFBIG;
        return 0;
    }

    const char *data = static_cast<const char *>(buffer);
    std::size_t offset = 0;
    while (offset < size)
    {
        const ssize_t result = ::pwrite(
            state->fd, data + offset, size - offset,
            static_cast<off_t>(file_offset + offset));
        if (result > 0)
        {
            offset += static_cast<std::size_t>(result);
            continue;
        }
        if (result < 0 && errno == EINTR)
        {
            continue;
        }
        state->error_number = result < 0 ? errno : EIO;
        return 0;
    }
    state->written += size;
    return size;
}

class SecureArchiveDestination
{
public:
    SecureArchiveDestination() = default;
    ~SecureArchiveDestination()
    {
        abort_active_staged_file();
        cleanup_staged();
        cleanup_created_directories();
        if (root_fd_ >= 0)
        {
            ::close(root_fd_);
        }
    }

    SecureArchiveDestination(const SecureArchiveDestination &) = delete;
    SecureArchiveDestination &operator=(const SecureArchiveDestination &) = delete;

    bool open_root(const fs::path &root, std::string &err)
    {
        return open_root(root, true, err);
    }

    bool open_root(const fs::path &root, bool create_missing,
                   std::string &err)
    {
        display_root_ = root.empty() ? fs::path(".") : root;
        const fs::path normalized = display_root_.lexically_normal();
        const bool absolute = normalized.is_absolute();
        int current = ::open(absolute ? "/" : ".",
                             O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (current < 0)
        {
            err = "archive: " + errno_message(
                "cannot open destination traversal root",
                absolute ? fs::path("/") : fs::path("."), errno);
            return false;
        }

        const fs::path components = absolute ? normalized.relative_path()
                                             : normalized;
        for (const fs::path &component_path : components)
        {
            const std::string component = component_path.string();
            if (component.empty() || component == ".")
            {
                continue;
            }

            struct stat st{};
            if (::fstatat(current, component.c_str(), &st,
                          AT_SYMLINK_NOFOLLOW) != 0)
            {
                if (errno != ENOENT)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot inspect destination root component",
                        display_root_, e);
                    return false;
                }
                if (!create_missing)
                {
                    ::close(current);
                    root_exists_ = false;
                    root_fd_ = -1;
                    return true;
                }
                if (::mkdirat(current, component.c_str(),
                              DEFAULT_DIRECTORY_MODE) != 0 &&
                    errno != EEXIST)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot create destination root component",
                        display_root_, e);
                    return false;
                }
                if (::fstatat(current, component.c_str(), &st,
                              AT_SYMLINK_NOFOLLOW) != 0)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot inspect created destination root component",
                        display_root_, e);
                    return false;
                }
            }
            if (S_ISLNK(st.st_mode))
            {
                ::close(current);
                err = "archive: destination root contains a symlink component: '" +
                      display_root_.string() + "'";
                return false;
            }
            if (!S_ISDIR(st.st_mode))
            {
                ::close(current);
                err = "archive: destination root component is not a directory: '" +
                      display_root_.string() + "'";
                return false;
            }

            int next = ::openat(current, component.c_str(),
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                    O_NOFOLLOW);
            if (next < 0)
            {
                const int e = errno;
                ::close(current);
                err = "archive: " + errno_message(
                    "cannot securely open destination root component",
                    display_root_, e);
                return false;
            }
            ::close(current);
            current = next;
        }

        root_fd_ = current;
        root_exists_ = true;
        return true;
    }

    [[nodiscard]] bool root_exists() const noexcept
    {
        return root_exists_;
    }

    bool preflight(const fs::path &relative, EntryKind kind, bool overwrite,
                   std::string &err,
                   DestinationAction *action = nullptr)
    {
        reserved_output_paths_.insert(relative.generic_string());
        const auto note_action = [&](DestinationAction value)
        {
            if (action != nullptr)
            {
                *action = value;
            }
        };

        if (!root_exists_)
        {
            note_action(DestinationAction::create);
            return true;
        }

        int parent_fd = -1;
        std::string leaf;
        bool parent_missing = false;
        if (!open_parent(relative, false, parent_fd, leaf, parent_missing, err))
        {
            return false;
        }
        if (parent_missing)
        {
            note_action(DestinationAction::create);
            return true;
        }

        struct stat st{};
        if (::fstatat(parent_fd, leaf.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            const int e = errno;
            ::close(parent_fd);
            if (e == ENOENT)
            {
                note_action(DestinationAction::create);
                return true;
            }
            err = "archive: " + errno_message(
                "cannot inspect destination entry", display_root_ / relative,
                e);
            return false;
        }
        ::close(parent_fd);

        if (S_ISLNK(st.st_mode))
        {
            err = "archive: destination entry must not be a symlink: '" +
                  (display_root_ / relative).string() + "'";
            return false;
        }
        if (kind == EntryKind::directory)
        {
            if (!S_ISDIR(st.st_mode))
            {
                err = "archive: destination entry is not a directory: '" +
                      (display_root_ / relative).string() + "'";
                return false;
            }
            note_action(DestinationAction::skip);
            return true;
        }
        if (!S_ISREG(st.st_mode))
        {
            err = "archive: destination entry is not a regular file: '" +
                  (display_root_ / relative).string() + "'";
            return false;
        }
        if (!overwrite)
        {
            err = "archive: destination entry already exists: '" +
                  (display_root_ / relative).string() + "'";
            return false;
        }
        note_action(DestinationAction::overwrite);
        return true;
    }

    bool ensure_directory(const fs::path &relative, mode_t desired_mode,
                          std::string &err, bool set_desired_mode = true)
    {
        int current = duplicate_cloexec(root_fd_);
        if (current < 0)
        {
            err = "archive: " + errno_message(
                "cannot duplicate destination root descriptor", display_root_,
                errno);
            return false;
        }

        fs::path traversed;
        for (const fs::path &component_path : relative)
        {
            const std::string component = component_path.string();
            traversed /= component_path;
            struct stat st{};
            bool created = false;
            if (::fstatat(current, component.c_str(), &st,
                          AT_SYMLINK_NOFOLLOW) != 0)
            {
                if (errno != ENOENT)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot inspect destination directory",
                        display_root_ / traversed, e);
                    return false;
                }
                if (::mkdirat(current, component.c_str(),
                              STAGING_DIRECTORY_MODE) != 0)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot create destination directory",
                        display_root_ / traversed, e);
                    return false;
                }
                created = true;
                if (::fstatat(current, component.c_str(), &st,
                              AT_SYMLINK_NOFOLLOW) != 0)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot inspect created destination directory",
                        display_root_ / traversed, e);
                    return false;
                }
            }
            if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode))
            {
                ::close(current);
                err = "archive: destination directory path is unsafe: '" +
                      (display_root_ / traversed).string() + "'";
                return false;
            }

            int next = ::openat(current, component.c_str(),
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                    O_NOFOLLOW);
            if (next < 0)
            {
                const int e = errno;
                ::close(current);
                err = "archive: " + errno_message(
                    "cannot securely open destination directory",
                    display_root_ / traversed, e);
                return false;
            }
            ::close(current);
            current = next;

            if (created)
            {
                const std::string key = traversed.generic_string();
                created_directories_.push_back(traversed);
                desired_directory_modes_[key] = DEFAULT_DIRECTORY_MODE;
            }
        }
        ::close(current);

        const std::string final_key = relative.generic_string();
        if (set_desired_mode && desired_directory_modes_.contains(final_key))
        {
            desired_directory_modes_[final_key] = desired_mode;
        }
        return true;
    }

    bool begin_stream_file(const fs::path &relative,
                           std::uint64_t expected_size,
                           std::string &err)
    {
        return begin_staged_file(relative, expected_size, err);
    }

    bool write_stream_block(std::uint64_t offset, const void *buffer,
                            std::size_t size, std::string &err)
    {
        if (active_fd_ < 0 || active_parent_fd_ < 0 ||
            offset != active_written_ || active_written_ > active_expected_ ||
            size > active_expected_ - active_written_)
        {
            err = "archive: invalid streamed extraction block for '" +
                  (display_root_ / active_relative_).string() + "'";
            return false;
        }
        if (buffer == nullptr && size != 0)
        {
            err = "archive: null streamed extraction block for '" +
                  (display_root_ / active_relative_).string() + "'";
            return false;
        }

        const char *data = static_cast<const char *>(buffer);
        std::size_t written = 0;
        while (written < size)
        {
            const std::uint64_t position = offset + written;
            if (position > static_cast<std::uint64_t>(
                               std::numeric_limits<off_t>::max()))
            {
                err = "archive: streamed extraction offset is too large for '" +
                      (display_root_ / active_relative_).string() + "'";
                return false;
            }
            const ssize_t result = ::pwrite(
                active_fd_, data + written, size - written,
                static_cast<off_t>(position));
            if (result > 0)
            {
                written += static_cast<std::size_t>(result);
                continue;
            }
            if (result < 0 && errno == EINTR)
            {
                continue;
            }
            const int e = result < 0 ? errno : EIO;
            err = "archive: " + errno_message(
                "cannot write extracted file",
                display_root_ / active_relative_, e);
            return false;
        }
        active_written_ += size;
        return true;
    }

    bool finish_stream_file(mode_t mode, std::string &err)
    {
        if (active_fd_ < 0 || active_parent_fd_ < 0 ||
            active_written_ != active_expected_)
        {
            err = "archive: streamed extraction ended before its announced size for '" +
                  (display_root_ / active_relative_).string() + "'";
            return false;
        }
        if (::fchmod(active_fd_, mode & 0777) != 0)
        {
            const int e = errno;
            err = "archive: " + errno_message(
                "cannot set extracted file permissions",
                display_root_ / active_relative_, e);
            return false;
        }
        if (::close(active_fd_) != 0)
        {
            const int e = errno;
            active_fd_ = -1;
            err = "archive: " + errno_message(
                "cannot close temporary extraction file",
                display_root_ / active_relative_, e);
            return false;
        }
        active_fd_ = -1;
        ::close(active_parent_fd_);
        active_parent_fd_ = -1;

        staged_.push_back(StagedFile{active_relative_, active_temporary_});
        active_relative_.clear();
        active_temporary_.clear();
        active_expected_ = 0;
        active_written_ = 0;
        return true;
    }

    void abort_stream_file() noexcept
    {
        abort_active_staged_file();
    }

    bool stage_file(mz_zip_archive &zip, const ArchiveEntry &entry,
                    mode_t mode, std::string &err)
    {
        const fs::path relative(entry.normalized);
        if (!begin_staged_file(relative, entry.size, err))
        {
            return false;
        }

        ExtractCallbackState state;
        state.fd = active_fd_;
        state.expected = entry.size;
        const mz_bool extracted = mz_zip_reader_extract_to_callback(
            &zip, entry.index, extract_write_callback, &state, 0);
        if (!extracted || state.written != entry.size)
        {
            const int callback_error = state.error_number;
            abort_active_staged_file();
            if (callback_error != 0)
            {
                err = "archive: " + errno_message(
                    "cannot write extracted file", display_root_ / relative,
                    callback_error);
            }
            else
            {
                err = miniz_error(zip, "cannot extract ZIP entry", entry.name);
            }
            return false;
        }
        active_written_ = state.written;
        if (!finish_stream_file(mode, err))
        {
            abort_active_staged_file();
            return false;
        }
        return true;
    }

    bool publish(bool overwrite, std::string &err)
    {
        for (std::size_t i = 0; i < staged_.size(); ++i)
        {
            StagedFile &file = staged_[i];
            int parent_fd = -1;
            std::string leaf;
            bool missing = false;
            if (!open_parent(file.relative, false, parent_fd, leaf, missing,
                             err) ||
                missing)
            {
                if (err.empty())
                {
                    err = "archive: destination parent disappeared while publishing '" +
                          (display_root_ / file.relative).string() + "'";
                }
                return false;
            }

            if (overwrite)
            {
                struct stat existing{};
                if (::fstatat(parent_fd, leaf.c_str(), &existing,
                              AT_SYMLINK_NOFOLLOW) == 0)
                {
                    if (S_ISLNK(existing.st_mode) ||
                        !S_ISREG(existing.st_mode))
                    {
                        ::close(parent_fd);
                        err = "archive: destination changed to an unsafe type while publishing: '" +
                              (display_root_ / file.relative).string() + "'";
                        return false;
                    }
                }
                else if (errno != ENOENT)
                {
                    const int e = errno;
                    ::close(parent_fd);
                    err = "archive: " + errno_message(
                        "cannot inspect destination while publishing",
                        display_root_ / file.relative, e);
                    return false;
                }

                if (::renameat(parent_fd, file.temporary.c_str(), parent_fd,
                               leaf.c_str()) != 0)
                {
                    const int e = errno;
                    ::close(parent_fd);
                    err = "archive: " + errno_message(
                        "cannot publish extracted file",
                        display_root_ / file.relative, e);
                    return false;
                }
            }
            else
            {
                if (::linkat(parent_fd, file.temporary.c_str(), parent_fd,
                             leaf.c_str(), 0) != 0)
                {
                    const int e = errno;
                    ::close(parent_fd);
                    err = "archive: " + errno_message(
                        "cannot publish extracted file without overwriting",
                        display_root_ / file.relative, e);
                    return false;
                }
                if (::unlinkat(parent_fd, file.temporary.c_str(), 0) != 0)
                {
                    const int e = errno;
                    ::close(parent_fd);
                    err = "archive: " + errno_message(
                        "cannot remove extraction staging link",
                        display_root_ / file.relative, e);
                    return false;
                }
            }
            ::close(parent_fd);
            file.temporary.clear();
        }
        return true;
    }

    bool finalize_directory_modes(std::string &err)
    {
        std::vector<fs::path> paths = created_directories_;
        std::sort(paths.begin(), paths.end(), [](const fs::path &a,
                                                 const fs::path &b)
                  { return a.native().size() > b.native().size(); });

        for (const fs::path &relative : paths)
        {
            int fd = open_directory(relative, err);
            if (fd < 0)
            {
                return false;
            }
            const auto it = desired_directory_modes_.find(
                relative.generic_string());
            const mode_t mode = it == desired_directory_modes_.end()
                                    ? DEFAULT_DIRECTORY_MODE
                                    : it->second;
            if (::fchmod(fd, mode & 0777) != 0)
            {
                const int e = errno;
                ::close(fd);
                err = "archive: " + errno_message(
                    "cannot set extracted directory permissions",
                    display_root_ / relative, e);
                return false;
            }
            ::close(fd);
        }
        return true;
    }

    void commit()
    {
        abort_active_staged_file();
        staged_.clear();
        created_directories_.clear();
        desired_directory_modes_.clear();
        reserved_output_paths_.clear();
    }

private:
    bool begin_staged_file(const fs::path &relative,
                           std::uint64_t expected_size,
                           std::string &err)
    {
        if (active_fd_ >= 0 || active_parent_fd_ >= 0)
        {
            err = "archive: internal extraction staging state is already active";
            return false;
        }

        const fs::path parent = relative.parent_path();
        if (!parent.empty() &&
            !ensure_directory(parent, DEFAULT_DIRECTORY_MODE, err, false))
        {
            return false;
        }

        int parent_fd = -1;
        std::string leaf;
        bool missing = false;
        if (!open_parent(relative, true, parent_fd, leaf, missing, err))
        {
            return false;
        }

        struct stat existing{};
        if (::fstatat(parent_fd, leaf.c_str(), &existing,
                      AT_SYMLINK_NOFOLLOW) != 0 &&
            errno != ENOENT)
        {
            const int e = errno;
            ::close(parent_fd);
            err = "archive: " + errno_message(
                "cannot inspect destination file", display_root_ / relative,
                e);
            return false;
        }

        std::string temporary;
        int temp_fd = -1;
        int filesystem_collisions = 0;
        while (filesystem_collisions < 64)
        {
            const unsigned long long id = archive_temp_counter.fetch_add(
                1, std::memory_order_relaxed);
            temporary = ".babet-archive-" + std::to_string(::getpid()) +
                        "-" + std::to_string(id);
            const fs::path temporary_relative = parent / temporary;
            if (reserved_output_paths_.contains(
                    temporary_relative.generic_string()))
            {
                continue;
            }

            temp_fd = ::openat(parent_fd, temporary.c_str(),
                               O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
                                   O_NOFOLLOW,
                               STAGING_FILE_MODE);
            if (temp_fd >= 0 || errno != EEXIST)
            {
                break;
            }
            ++filesystem_collisions;
        }
        if (temp_fd < 0)
        {
            const int e = errno;
            ::close(parent_fd);
            err = "archive: " + errno_message(
                "cannot create temporary extraction file",
                display_root_ / relative, e);
            return false;
        }

        active_fd_ = temp_fd;
        active_parent_fd_ = parent_fd;
        active_relative_ = relative;
        active_temporary_ = std::move(temporary);
        active_expected_ = expected_size;
        active_written_ = 0;
        return true;
    }

    void abort_active_staged_file() noexcept
    {
        if (active_fd_ >= 0)
        {
            ::close(active_fd_);
            active_fd_ = -1;
        }
        if (active_parent_fd_ >= 0)
        {
            if (!active_temporary_.empty())
            {
                ::unlinkat(active_parent_fd_, active_temporary_.c_str(), 0);
            }
            ::close(active_parent_fd_);
            active_parent_fd_ = -1;
        }
        active_relative_.clear();
        active_temporary_.clear();
        active_expected_ = 0;
        active_written_ = 0;
    }

    bool open_parent(const fs::path &relative, bool create,
                     int &parent_fd, std::string &leaf,
                     bool &parent_missing, std::string &err)
    {
        parent_fd = -1;
        parent_missing = false;
        leaf = relative.filename().string();
        if (root_fd_ < 0 || relative.empty() || leaf.empty())
        {
            err = "archive: invalid destination-relative path '" +
                  relative.string() + "'";
            return false;
        }

        int current = duplicate_cloexec(root_fd_);
        if (current < 0)
        {
            err = "archive: " + errno_message(
                "cannot duplicate destination root descriptor", display_root_,
                errno);
            return false;
        }

        fs::path traversed;
        for (const fs::path &component_path : relative.parent_path())
        {
            const std::string component = component_path.string();
            traversed /= component_path;
            struct stat st{};
            if (::fstatat(current, component.c_str(), &st,
                          AT_SYMLINK_NOFOLLOW) != 0)
            {
                if (errno == ENOENT && !create)
                {
                    ::close(current);
                    parent_missing = true;
                    return true;
                }
                if (errno != ENOENT)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot inspect destination path component",
                        display_root_ / traversed, e);
                    return false;
                }
                if (::mkdirat(current, component.c_str(),
                              STAGING_DIRECTORY_MODE) != 0)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot create destination path component",
                        display_root_ / traversed, e);
                    return false;
                }
                created_directories_.push_back(traversed);
                desired_directory_modes_[traversed.generic_string()] =
                    DEFAULT_DIRECTORY_MODE;
                if (::fstatat(current, component.c_str(), &st,
                              AT_SYMLINK_NOFOLLOW) != 0)
                {
                    const int e = errno;
                    ::close(current);
                    err = "archive: " + errno_message(
                        "cannot inspect created destination path component",
                        display_root_ / traversed, e);
                    return false;
                }
            }
            if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode))
            {
                ::close(current);
                err = "archive: destination contains a symlink or non-directory component: '" +
                      (display_root_ / traversed).string() + "'";
                return false;
            }
            int next = ::openat(current, component.c_str(),
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                    O_NOFOLLOW);
            if (next < 0)
            {
                const int e = errno;
                ::close(current);
                err = "archive: " + errno_message(
                    "cannot securely open destination path component",
                    display_root_ / traversed, e);
                return false;
            }
            ::close(current);
            current = next;
        }
        parent_fd = current;
        return true;
    }

    int open_directory(const fs::path &relative, std::string &err) const
    {
        int current = duplicate_cloexec(root_fd_);
        if (current < 0)
        {
            err = "archive: " + errno_message(
                "cannot duplicate destination root descriptor", display_root_,
                errno);
            return -1;
        }
        fs::path traversed;
        for (const fs::path &component_path : relative)
        {
            traversed /= component_path;
            const std::string component = component_path.string();
            int next = ::openat(current, component.c_str(),
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                    O_NOFOLLOW);
            if (next < 0)
            {
                const int e = errno;
                ::close(current);
                err = "archive: " + errno_message(
                    "cannot securely open extracted directory",
                    display_root_ / traversed, e);
                return -1;
            }
            ::close(current);
            current = next;
        }
        return current;
    }

    void cleanup_staged() noexcept
    {
        for (StagedFile &file : staged_)
        {
            if (file.temporary.empty())
            {
                continue;
            }
            int parent_fd = -1;
            std::string leaf;
            bool missing = false;
            std::string ignored;
            if (open_parent(file.relative, false, parent_fd, leaf, missing,
                            ignored) &&
                !missing)
            {
                ::unlinkat(parent_fd, file.temporary.c_str(), 0);
                ::close(parent_fd);
            }
        }
    }

    void cleanup_created_directories() noexcept
    {
        std::vector<fs::path> paths = created_directories_;
        std::sort(paths.begin(), paths.end(), [](const fs::path &a,
                                                 const fs::path &b)
                  { return a.native().size() > b.native().size(); });
        for (const fs::path &relative : paths)
        {
            int parent_fd = -1;
            std::string leaf;
            bool missing = false;
            std::string ignored;
            if (open_parent(relative, false, parent_fd, leaf, missing,
                            ignored) &&
                !missing)
            {
                ::unlinkat(parent_fd, leaf.c_str(), AT_REMOVEDIR);
                ::close(parent_fd);
            }
        }
    }

    int root_fd_ = -1;
    bool root_exists_ = false;
    fs::path display_root_;
    std::vector<StagedFile> staged_;
    std::vector<fs::path> created_directories_;
    std::unordered_map<std::string, mode_t> desired_directory_modes_;
    std::unordered_set<std::string> reserved_output_paths_;
    int active_fd_ = -1;
    int active_parent_fd_ = -1;
    fs::path active_relative_;
    std::string active_temporary_;
    std::uint64_t active_expected_ = 0;
    std::uint64_t active_written_ = 0;
};

mode_t file_mode_for_entry(const ArchiveEntry &entry,
                           const ArchiveOptions &options);

class TarExtractionSink final : public babet::archive_tar::ExtractionSink
{
public:
    TarExtractionSink(SecureArchiveDestination &destination,
                      const ArchiveScan &scan,
                      const ArchiveOptions &options,
                      const std::vector<unsigned char> *selected = nullptr)
        : destination_(destination), scan_(scan), options_(options),
          selected_(selected)
    {
    }

    TarExtractionSink(SecureArchiveDestination &destination,
                      const ArchiveScan &scan,
                      const ArchiveOptions &options,
                      std::size_t selected_index,
                      fs::path selected_relative)
        : destination_(destination), scan_(scan), options_(options),
          selected_index_(selected_index),
          selected_relative_(std::move(selected_relative))
    {
    }

    bool wants_file(std::size_t index,
                    const babet::archive_tar::Entry &entry) const noexcept override
    {
        (void)entry;
        if (selected_index_.has_value())
        {
            return *selected_index_ == index;
        }
        return selected_ == nullptr ||
               (index < selected_->size() && (*selected_)[index] != 0);
    }

    bool begin_file(std::size_t index,
                    const babet::archive_tar::Entry &entry,
                    std::string &err) override
    {
        if (index >= scan_.entries.size() ||
            scan_.entries[index].kind != EntryKind::regular ||
            scan_.entries[index].size != entry.size ||
            (selected_index_.has_value() && *selected_index_ != index) ||
            (!selected_index_.has_value() && selected_ != nullptr &&
             (index >= selected_->size() || (*selected_)[index] == 0)))
        {
            err = "archive: internal TAR extraction plan mismatch";
            return false;
        }
        const fs::path relative = selected_index_.has_value()
                                      ? selected_relative_
                                      : fs::path(scan_.entries[index].normalized);
        active_ = true;
        if (!destination_.begin_stream_file(relative, entry.size, err))
        {
            active_ = false;
            return false;
        }
        return true;
    }

    bool write_file_block(std::size_t index,
                          const babet::archive_tar::Entry &entry,
                          std::uint64_t offset, const void *data,
                          std::size_t size, std::string &err) override
    {
        (void)index;
        (void)entry;
        if (!active_)
        {
            err = "archive: internal TAR extraction plan mismatch";
            return false;
        }
        return destination_.write_stream_block(offset, data, size, err);
    }

    bool finish_file(std::size_t index,
                     const babet::archive_tar::Entry &entry,
                     std::string &err) override
    {
        (void)entry;
        if (!active_ || index >= scan_.entries.size())
        {
            err = "archive: internal TAR extraction plan mismatch";
            return false;
        }
        const bool finished = destination_.finish_stream_file(
            file_mode_for_entry(scan_.entries[index], options_), err);
        if (finished)
        {
            active_ = false;
        }
        return finished;
    }

    void abort_file() noexcept override
    {
        if (active_)
        {
            destination_.abort_stream_file();
            active_ = false;
        }
    }

private:
    SecureArchiveDestination &destination_;
    const ArchiveScan &scan_;
    const ArchiveOptions &options_;
    const std::vector<unsigned char> *selected_ = nullptr;
    std::optional<std::size_t> selected_index_;
    fs::path selected_relative_;
    bool active_ = false;
};

class TarDryRunSink final : public babet::archive_tar::ExtractionSink
{
public:
    explicit TarDryRunSink(const std::vector<unsigned char> &selected)
        : selected_(selected)
    {
    }

    bool wants_file(std::size_t index,
                    const babet::archive_tar::Entry &entry) const noexcept override
    {
        (void)entry;
        return index < selected_.size() && selected_[index] != 0;
    }

    bool begin_file(std::size_t index,
                    const babet::archive_tar::Entry &entry,
                    std::string &err) override
    {
        if (!wants_file(index, entry) || active_)
        {
            err = "archive: internal TAR dry-run plan mismatch";
            return false;
        }
        active_ = true;
        active_index_ = index;
        expected_ = entry.size;
        read_ = 0;
        return true;
    }

    bool write_file_block(std::size_t index,
                          const babet::archive_tar::Entry &entry,
                          std::uint64_t offset, const void *data,
                          std::size_t size, std::string &err) override
    {
        (void)entry;
        if (!active_ || index != active_index_ ||
            (data == nullptr && size != 0) || offset != read_ ||
            read_ > expected_ || size > expected_ - read_)
        {
            err = "archive: TAR entry returned invalid or non-contiguous data during dry run";
            return false;
        }
        read_ += size;
        return true;
    }

    bool finish_file(std::size_t index,
                     const babet::archive_tar::Entry &entry,
                     std::string &err) override
    {
        (void)entry;
        if (!active_ || index != active_index_ || read_ != expected_)
        {
            err = "archive: TAR entry ended before its announced size during dry run";
            return false;
        }
        active_ = false;
        active_index_ = 0;
        expected_ = 0;
        read_ = 0;
        return true;
    }

    void abort_file() noexcept override
    {
        active_ = false;
        active_index_ = 0;
        expected_ = 0;
        read_ = 0;
    }

private:
    const std::vector<unsigned char> &selected_;
    bool active_ = false;
    std::size_t active_index_ = 0;
    std::uint64_t expected_ = 0;
    std::uint64_t read_ = 0;
};

void push_u64(lua_State *L, std::uint64_t value);

enum class CreateArchiveFormat
{
    zip,
    tar,
    tar_gzip,
    tar_xz,
    tar_bzip2,
    tar_zstd,
};

struct ArchiveCreateOptions
{
    std::uint64_t max_entries = DEFAULT_MAX_ENTRIES;
    std::uint64_t max_file_size = DEFAULT_MAX_ENTRY_SIZE;
    std::uint64_t max_total_size = DEFAULT_MAX_TOTAL_SIZE;
    int compression_level = MZ_DEFAULT_LEVEL;
    bool compression_level_explicit = false;
    bool overwrite = false;
    bool deterministic = true;
    bool include_directories = true;
    ArchiveGlobFilter filters;
    CreateArchiveFormat format = CreateArchiveFormat::zip;
    bool format_explicit = false;
};

enum class CreateEntryKind
{
    regular,
    directory,
};

struct CreateEntry
{
    // Path stored in the archive. For the historical string form this is
    // relative to the source directory. For an explicit source list it is
    // rooted at the selected source basename.
    fs::path relative;
    // Path used to reopen the pinned source from source_roots[source_index].
    fs::path source_relative;
    std::size_t source_index = 0;
    CreateEntryKind kind = CreateEntryKind::regular;
    std::uint64_t size = 0;
    dev_t device = 0;
    ino_t inode = 0;
    timespec modified{};
    timespec changed{};
};

class ScopedFd
{
public:
    explicit ScopedFd(int fd = -1) noexcept : fd_(fd) {}
    ~ScopedFd()
    {
        if (fd_ >= 0)
        {
            ::close(fd_);
        }
    }
    ScopedFd(const ScopedFd &) = delete;
    ScopedFd &operator=(const ScopedFd &) = delete;
    ScopedFd(ScopedFd &&other) noexcept : fd_(other.release()) {}
    ScopedFd &operator=(ScopedFd &&other) noexcept
    {
        if (this != &other)
        {
            reset(other.release());
        }
        return *this;
    }
    int get() const noexcept { return fd_; }
    int release() noexcept
    {
        const int result = fd_;
        fd_ = -1;
        return result;
    }
    void reset(int fd = -1) noexcept
    {
        if (fd_ >= 0)
        {
            ::close(fd_);
        }
        fd_ = fd;
    }

private:
    int fd_ = -1;
};

class ScopedFile
{
public:
    explicit ScopedFile(FILE *file = nullptr) noexcept : file_(file) {}
    ~ScopedFile()
    {
        if (file_ != nullptr)
        {
            std::fclose(file_);
        }
    }
    ScopedFile(const ScopedFile &) = delete;
    ScopedFile &operator=(const ScopedFile &) = delete;
    FILE *get() const noexcept { return file_; }
    FILE *release() noexcept
    {
        FILE *result = file_;
        file_ = nullptr;
        return result;
    }

private:
    FILE *file_ = nullptr;
};

bool same_timespec(const timespec &a, const timespec &b) noexcept
{
    return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec;
}

bool validate_create_option_keys(lua_State *L, int idx, std::string &err)
{
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = "archive create options must be a table";
        return false;
    }
    static const std::unordered_set<std::string> allowed = {
        "max_entries", "max_file_size", "max_total_size",
        "compression_level", "overwrite", "deterministic",
        "include_directories", "include", "exclude", "format"};
    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 2);
            err = "archive create option keys must be strings";
            return false;
        }
        size_t length = 0;
        const char *data = lua_tolstring(L, -2, &length);
        const std::string key(data, length);
        if (!allowed.contains(key))
        {
            lua_pop(L, 2);
            err = "unknown archive create option: " + key;
            return false;
        }
        lua_pop(L, 1);
    }
    return true;
}

bool collect_create_options(lua_State *L, int idx,
                            ArchiveCreateOptions &options,
                            std::string &err)
{
    if (!validate_create_option_keys(L, idx, err))
    {
        return false;
    }
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    idx = lua_absindex(L, idx);
    if (!parse_positive_integer(L, idx, "max_entries", HARD_MAX_ENTRIES,
                                options.max_entries, err) ||
        !parse_positive_integer(L, idx, "max_file_size",
                                HARD_MAX_ENTRY_SIZE,
                                options.max_file_size, err) ||
        !parse_positive_integer(L, idx, "max_total_size",
                                HARD_MAX_TOTAL_SIZE,
                                options.max_total_size, err) ||
        !parse_strict_boolean(L, idx, "overwrite", options.overwrite, err) ||
        !parse_strict_boolean(L, idx, "deterministic",
                              options.deterministic, err) ||
        !parse_strict_boolean(L, idx, "include_directories",
                              options.include_directories, err))
    {
        return false;
    }

    std::size_t total_patterns = 0;
    std::uint64_t total_pattern_bytes = 0;
    if (!collect_archive_glob_list(L, idx, "include",
                                   options.filters.include_patterns, total_patterns,
                                  total_pattern_bytes, err) ||
        !collect_archive_glob_list(L, idx, "exclude",
                                   options.filters.exclude_patterns, total_patterns,
                                  total_pattern_bytes, err))
    {
        return false;
    }
    raw_getfield(L, idx, "compression_level");
    if (!lua_is_optional_strict_integer(L, -1))
    {
        lua_pop(L, 1);
        err = "opts.compression_level must be an integer";
        return false;
    }
    if (!lua_is_none_or_nil(L, -1))
    {
        const lua_Integer level = lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (level < 0 || level > 19)
        {
            err = "opts.compression_level must be between 0 and 19";
            return false;
        }
        options.compression_level = static_cast<int>(level);
        options.compression_level_explicit = true;
    }
    else
    {
        lua_pop(L, 1);
    }

    raw_getfield(L, idx, "format");
    if (!lua_is_optional_strict_string(L, -1))
    {
        lua_pop(L, 1);
        err = "opts.format must be a string";
        return false;
    }
    if (!lua_is_none_or_nil(L, -1))
    {
        std::string format;
        if (!lua_string_without_nul(L, -1, format, "opts.format", err))
        {
            lua_pop(L, 1);
            return false;
        }
        lua_pop(L, 1);
        if (format == "zip")
        {
            options.format = CreateArchiveFormat::zip;
        }
        else if (format == "tar")
        {
            options.format = CreateArchiveFormat::tar;
        }
        else if (format == "tar.gz")
        {
            options.format = CreateArchiveFormat::tar_gzip;
        }
        else if (format == "tar.xz")
        {
            options.format = CreateArchiveFormat::tar_xz;
        }
        else if (format == "tar.bz2")
        {
            options.format = CreateArchiveFormat::tar_bzip2;
        }
        else if (format == "tar.zst")
        {
            options.format = CreateArchiveFormat::tar_zstd;
        }
        else
        {
            err = "opts.format must be 'zip', 'tar', 'tar.gz', 'tar.xz', 'tar.bz2', or 'tar.zst'";
            return false;
        }
        options.format_explicit = true;
    }
    else
    {
        lua_pop(L, 1);
    }
    return true;
}

bool collect_explicit_create_sources(lua_State *L, int idx,
                                     std::vector<fs::path> &sources,
                                     std::string &err)
{
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = "archive: source must be a directory string or a dense array of paths";
        return false;
    }
    idx = lua_absindex(L, idx);
    const std::size_t count = lua_rawlen(L, idx);
    if (count == 0)
    {
        err = "archive: explicit source list must not be empty";
        return false;
    }
    if (count > static_cast<std::size_t>(HARD_MAX_ENTRIES))
    {
        err = "archive: explicit source list exceeds the internal 100000-source limit";
        return false;
    }

    std::size_t seen = 0;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (!lua_is_strict_integer(L, -2))
        {
            lua_pop(L, 2);
            err = "archive: explicit source list must be a dense array of strings";
            return false;
        }
        const lua_Integer key = lua_tointeger(L, -2);
        if (key < 1 || static_cast<std::size_t>(key) > count)
        {
            lua_pop(L, 2);
            err = "archive: explicit source list must be a dense array of strings";
            return false;
        }
        ++seen;
        lua_pop(L, 1);
    }
    if (seen != count)
    {
        err = "archive: explicit source list must be a dense array of strings";
        return false;
    }

    sources.clear();
    sources.reserve(count);
    for (std::size_t i = 1; i <= count; ++i)
    {
        lua_geti(L, idx, static_cast<lua_Integer>(i));
        if (!lua_is_strict_string(L, -1))
        {
            lua_pop(L, 1);
            err = "archive: explicit source list must contain only strings";
            return false;
        }
        std::size_t length = 0;
        const char *data = lua_tolstring(L, -1, &length);
        if (data == nullptr || std::memchr(data, '\0', length) != nullptr)
        {
            lua_pop(L, 1);
            err = "archive: explicit source path must not contain NUL bytes";
            return false;
        }
        if (length == 0)
        {
            lua_pop(L, 1);
            err = "archive: explicit source path must not be empty";
            return false;
        }
        sources.emplace_back(std::string(data, length));
        lua_pop(L, 1);
    }
    return true;
}

bool is_dot_component(const fs::path &component)
{
    return component.empty() || component == ".";
}

bool open_directory_without_symlinks(const fs::path &path, ScopedFd &result,
                                     std::string_view label,
                                     std::string &err)
{
    if (path.empty())
    {
        err = "archive: " + std::string(label) + " must not be empty";
        return false;
    }
    ScopedFd current(::open(path.is_absolute() ? "/" : ".",
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (current.get() < 0)
    {
        err = "archive: " + errno_message("cannot open", path, errno);
        return false;
    }

    const fs::path components = path.is_absolute() ? path.relative_path() : path;
    fs::path traversed = path.is_absolute() ? fs::path("/") : fs::path(".");
    for (const fs::path &component_path : components)
    {
        if (is_dot_component(component_path))
        {
            continue;
        }
        if (component_path == "..")
        {
            err = "archive: " + std::string(label) +
                  " must not contain '..' components";
            return false;
        }
        const std::string component = component_path.string();
        struct stat st{};
        if (::fstatat(current.get(), component.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            err = "archive: " + errno_message(
                "cannot inspect " + std::string(label), traversed / component_path,
                errno);
            return false;
        }
        if (S_ISLNK(st.st_mode))
        {
            err = "archive: " + std::string(label) +
                  " contains a symlink component: '" +
                  (traversed / component_path).string() + "'";
            return false;
        }
        if (!S_ISDIR(st.st_mode))
        {
            err = "archive: " + std::string(label) +
                  " component is not a directory: '" +
                  (traversed / component_path).string() + "'";
            return false;
        }
        ScopedFd next(::openat(current.get(), component.c_str(),
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                   O_NOFOLLOW));
        if (next.get() < 0)
        {
            err = "archive: " + errno_message(
                "cannot securely open " + std::string(label),
                traversed / component_path, errno);
            return false;
        }
        current = std::move(next);
        traversed /= component_path;
    }
    result = std::move(current);
    return true;
}

bool path_is_within(const fs::path &candidate, const fs::path &root,
                    bool &within, std::string &err)
{
    std::error_code candidate_error;
    std::error_code root_error;
    const fs::path normalized_candidate =
        fs::absolute(candidate, candidate_error).lexically_normal();
    const fs::path normalized_root =
        fs::absolute(root, root_error).lexically_normal();
    if (candidate_error || root_error)
    {
        const std::error_code &failure = candidate_error ? candidate_error
                                                         : root_error;
        err = "archive: cannot resolve source and destination paths: " +
              failure.message();
        return false;
    }

    auto ci = normalized_candidate.begin();
    auto ri = normalized_root.begin();
    for (; ri != normalized_root.end(); ++ri, ++ci)
    {
        if (ci == normalized_candidate.end() || *ci != *ri)
        {
            within = false;
            return true;
        }
    }
    within = true;
    return true;
}

std::string lowercase_ascii(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c)
                   {
                       return c >= 'A' && c <= 'Z'
                                  ? static_cast<char>(c - 'A' + 'a')
                                  : static_cast<char>(c);
                   });
    return value;
}

bool has_suffix(std::string_view value, std::string_view suffix) noexcept
{
    return value.size() >= suffix.size() &&
           value.substr(value.size() - suffix.size()) == suffix;
}

bool validate_create_compression_level(const ArchiveCreateOptions &options,
                                       std::string &err)
{
    if (!options.compression_level_explicit)
    {
        return true;
    }
    if (options.format == CreateArchiveFormat::tar)
    {
        err = "opts.compression_level is only valid for ZIP, gzip, xz, bzip2, or zstd creation";
        return false;
    }
    if (options.format == CreateArchiveFormat::tar_bzip2 &&
        (options.compression_level < 1 || options.compression_level > 9))
    {
        err = "opts.compression_level must be between 1 and 9 for bzip2";
        return false;
    }
    if ((options.format == CreateArchiveFormat::zip ||
         options.format == CreateArchiveFormat::tar_gzip ||
         options.format == CreateArchiveFormat::tar_xz) &&
        options.compression_level > 9)
    {
        err = "opts.compression_level must be between 0 and 9 for ZIP, gzip, or xz";
        return false;
    }
    return true;
}

bool resolve_create_format(const fs::path &destination,
                           ArchiveCreateOptions &options,
                           std::string &err)
{
    const std::string name = lowercase_ascii(destination.filename().string());
    const bool gzip_tar_suffix =
        has_suffix(name, ".tar.gz") || has_suffix(name, ".tgz");
    const bool xz_tar_suffix = has_suffix(name, ".tar.xz") ||
                               has_suffix(name, ".txz");
    const bool bzip2_tar_suffix =
        has_suffix(name, ".tar.bz2") || has_suffix(name, ".tbz2") ||
        has_suffix(name, ".tbz");
    const bool zstd_tar_suffix =
        has_suffix(name, ".tar.zst") || has_suffix(name, ".tar.zstd") ||
        has_suffix(name, ".tzst");

    if (options.format_explicit)
    {
        return validate_create_compression_level(options, err);
    }
    if (gzip_tar_suffix)
    {
        options.format = CreateArchiveFormat::tar_gzip;
        return validate_create_compression_level(options, err);
    }
    if (xz_tar_suffix)
    {
        options.format = CreateArchiveFormat::tar_xz;
        return validate_create_compression_level(options, err);
    }
    if (bzip2_tar_suffix)
    {
        options.format = CreateArchiveFormat::tar_bzip2;
        return validate_create_compression_level(options, err);
    }
    if (zstd_tar_suffix)
    {
        options.format = CreateArchiveFormat::tar_zstd;
        return validate_create_compression_level(options, err);
    }
    if (has_suffix(name, ".tar"))
    {
        options.format = CreateArchiveFormat::tar;
        return validate_create_compression_level(options, err);
    }

    // Backward compatibility: before TAR creation existed, archive.create()
    // always produced ZIP regardless of the destination extension. Only
    // unambiguous TAR suffixes change the inferred format.
    options.format = CreateArchiveFormat::zip;
    return validate_create_compression_level(options, err);
}

bool fixed_deterministic_time(MZ_TIME_T &result, std::string &err)
{
    std::tm local_time{};
    local_time.tm_year = 1980 - 1900;
    local_time.tm_mon = 0;
    local_time.tm_mday = 1;
    local_time.tm_hour = 0;
    local_time.tm_min = 0;
    local_time.tm_sec = 0;
    local_time.tm_isdst = -1;
    const std::time_t timestamp = std::mktime(&local_time);
    if (timestamp == static_cast<std::time_t>(-1) ||
        local_time.tm_year != 1980 - 1900 || local_time.tm_mon != 0 ||
        local_time.tm_mday != 1 || local_time.tm_hour != 0 ||
        local_time.tm_min != 0 || local_time.tm_sec != 0)
    {
        err = "archive: cannot represent the deterministic ZIP timestamp";
        return false;
    }
    result = static_cast<MZ_TIME_T>(timestamp);
    return true;
}

bool validate_source_zip_timestamp(const CreateEntry &entry,
                                   std::string &err)
{
    const std::time_t timestamp = entry.modified.tv_sec;
    std::tm local_time{};
    if (::localtime_r(&timestamp, &local_time) == nullptr)
    {
        err = "archive: cannot represent source modification time in ZIP entry '" +
              entry.relative.generic_string() + "'";
        return false;
    }
    const int year = local_time.tm_year + 1900;
    if (year < 1980 || year > 2107)
    {
        err = "archive: source modification time is outside the ZIP range "
              "1980-2107: '" + entry.relative.generic_string() + "'";
        return false;
    }
    return true;
}

bool create_requires_zip64(const std::vector<CreateEntry> &entries,
                           std::uint64_t total_size) noexcept
{
    constexpr std::uint64_t conservative_size_threshold =
        3ULL * 1024ULL * 1024ULL * 1024ULL;
    if (total_size > conservative_size_threshold ||
        entries.size() >= 65535)
    {
        return true;
    }
    return std::any_of(entries.begin(), entries.end(),
                       [](const CreateEntry &entry)
                       {
                           return entry.kind == CreateEntryKind::regular &&
                                  entry.size >= 0xFFFFFFFFULL;
                       });
}

bool checked_add_total(std::uint64_t current, std::uint64_t added,
                       std::uint64_t limit, std::uint64_t &result)
{
    if (added > limit || current > limit - added)
    {
        return false;
    }
    result = current + added;
    return true;
}

bool validate_create_archive_path(const fs::path &archive_path,
                                  CreateEntryKind kind,
                                  std::string &err)
{
    const std::string name = archive_path.generic_string();
    if (name.empty() || name.size() > MAX_SAFE_ARCHIVE_PATH_BYTES)
    {
        err = "archive: source entry path is empty or exceeds 4096 bytes: '" +
              name + "'";
        return false;
    }
    if (!is_valid_utf8(name))
    {
        err = "archive: source entry path contains invalid UTF-8 bytes";
        return false;
    }
    std::string normalized;
    std::string reason;
    const EntryKind path_kind = kind == CreateEntryKind::directory
                                    ? EntryKind::directory
                                    : EntryKind::regular;
    if (!validate_entry_path(name, path_kind, normalized, reason) ||
        normalized != name)
    {
        err = "archive: unsafe source entry path '" + name + "': " + reason;
        return false;
    }
    return true;
}

bool append_create_entry(const fs::path &archive_path,
                         const fs::path &source_relative,
                         std::size_t source_index,
                         CreateEntryKind kind, const struct stat &st,
                         const ArchiveCreateOptions &options,
                         std::vector<CreateEntry> &entries,
                         std::uint64_t &total_size,
                         std::uint64_t &total_name_bytes,
                         std::string &err)
{
    if (!validate_create_archive_path(archive_path, kind, err))
    {
        return false;
    }
    if (entries.size() >= options.max_entries)
    {
        err = "archive: source exceeds opts.max_entries";
        return false;
    }

    const std::string archive_name = archive_path.generic_string();
    std::uint64_t updated_names = 0;
    if (!checked_add_total(total_name_bytes, archive_name.size(),
                           HARD_MAX_TOTAL_NAME_BYTES, updated_names))
    {
        err = "archive: source entry names exceed the internal 64 MiB limit";
        return false;
    }

    std::uint64_t size = 0;
    if (kind == CreateEntryKind::regular)
    {
        if (st.st_size < 0 ||
            static_cast<std::uint64_t>(st.st_size) > options.max_file_size)
        {
            err = "archive: source file exceeds opts.max_file_size: '" +
                  archive_name + "'";
            return false;
        }
        size = static_cast<std::uint64_t>(st.st_size);
        std::uint64_t updated_total = 0;
        if (!checked_add_total(total_size, size, options.max_total_size,
                               updated_total))
        {
            err = "archive: source exceeds opts.max_total_size";
            return false;
        }
        total_size = updated_total;
    }

    total_name_bytes = updated_names;
    CreateEntry item;
    item.relative = archive_path;
    item.source_relative = source_relative;
    item.source_index = source_index;
    item.kind = kind;
    item.size = size;
    item.device = st.st_dev;
    item.inode = st.st_ino;
    item.modified = st.st_mtim;
    item.changed = st.st_ctim;
    entries.push_back(std::move(item));
    return true;
}

bool classify_create_path(ArchiveCreateOptions &options,
                          const fs::path &archive_path, bool directory,
                          ArchiveFilterDecision &decision, std::string &err)
{
    const std::string name = archive_path.generic_string();
    return classify_archive_path(options.filters, name, directory, decision,
                                 err);
}

bool scan_create_directory(int directory_fd,
                           const fs::path &archive_relative,
                           const fs::path &source_relative,
                           std::size_t source_index, std::size_t depth,
                           ArchiveCreateOptions &options,
                           std::vector<CreateEntry> &entries,
                           std::uint64_t &total_size,
                           std::uint64_t &total_name_bytes,
                           std::uint64_t &scanned_nodes,
                           bool &selected_any,
                           std::string &err)
{
    selected_any = false;
    const int duplicate = ::openat(directory_fd, ".",
                                   O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                       O_NOFOLLOW);
    if (duplicate < 0)
    {
        err = "archive: cannot open source directory stream: " +
              std::string(std::strerror(errno));
        return false;
    }
    DIR *raw_directory = ::fdopendir(duplicate);
    if (raw_directory == nullptr)
    {
        const int e = errno;
        ::close(duplicate);
        err = "archive: cannot read source directory: " +
              std::string(std::strerror(e));
        return false;
    }

    std::vector<std::string> names;
    errno = 0;
    while (dirent *entry = ::readdir(raw_directory))
    {
        const std::string name(entry->d_name);
        if (name != "." && name != "..")
        {
            if (scanned_nodes >= HARD_MAX_SCANNED_SOURCE_NODES)
            {
                ::closedir(raw_directory);
                err = "archive: source tree exceeds the internal 100000-node scan limit";
                return false;
            }
            ++scanned_nodes;
            names.push_back(name);
        }
        errno = 0;
    }
    const int read_error = errno;
    ::closedir(raw_directory);
    if (read_error != 0)
    {
        err = "archive: cannot enumerate source directory: " +
              std::string(std::strerror(read_error));
        return false;
    }
    std::sort(names.begin(), names.end());

    for (const std::string &name : names)
    {
        struct stat st{};
        if (::fstatat(directory_fd, name.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            err = "archive: cannot inspect source entry '" +
                  (archive_relative / name).generic_string() + "': " +
                  std::strerror(errno);
            return false;
        }
        const fs::path archive_child = archive_relative / name;
        const fs::path source_child = source_relative / name;
        const bool is_directory = S_ISDIR(st.st_mode);
        ArchiveFilterDecision filter_decision =
            ArchiveFilterDecision::not_included;
        if (!classify_create_path(options, archive_child, is_directory,
                                  filter_decision, err))
        {
            return false;
        }
        if (filter_decision == ArchiveFilterDecision::excluded)
        {
            // Excluded directories are deliberately pruned before opening.
            // Excluded non-directories, including special objects, are ignored.
            continue;
        }

        if (is_directory)
        {
            ScopedFd child_fd(::openat(directory_fd, name.c_str(),
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                           O_NOFOLLOW));
            if (child_fd.get() < 0)
            {
                err = "archive: cannot securely open source directory '" +
                      archive_child.generic_string() + "': " +
                      std::strerror(errno);
                return false;
            }
            if (depth >= HARD_MAX_CREATE_DEPTH)
            {
                err = "archive: source tree exceeds the internal depth limit of 256";
                return false;
            }

            bool child_selected = false;
            if (!scan_create_directory(child_fd.get(), archive_child,
                                       source_child, source_index, depth + 1,
                                       options, entries, total_size,
                                       total_name_bytes, scanned_nodes,
                                       child_selected, err))
            {
                return false;
            }

            bool directory_added = false;
            if (options.include_directories &&
                (filter_decision == ArchiveFilterDecision::included ||
                 child_selected))
            {
                if (!append_create_entry(archive_child, source_child,
                                         source_index,
                                         CreateEntryKind::directory, st,
                                         options, entries, total_size,
                                         total_name_bytes, err))
                {
                    return false;
                }
                directory_added = true;
            }
            if (child_selected || directory_added)
            {
                selected_any = true;
            }
            continue;
        }

        if (filter_decision == ArchiveFilterDecision::not_included)
        {
            continue;
        }
        if (S_ISLNK(st.st_mode))
        {
            err = "archive: source contains a symlink entry: '" +
                  archive_child.generic_string() + "'";
            return false;
        }
        if (!S_ISREG(st.st_mode))
        {
            err = "archive: unsupported source entry type: '" +
                  archive_child.generic_string() + "'";
            return false;
        }
        if (!append_create_entry(archive_child, source_child, source_index,
                                 CreateEntryKind::regular, st, options,
                                 entries, total_size, total_name_bytes, err))
        {
            return false;
        }
        selected_any = true;
    }
    return true;
}

bool normalize_explicit_source_path(const fs::path &input,
                                    fs::path &normalized,
                                    std::string &archive_root,
                                    std::string &err)
{
    if (input.empty())
    {
        err = "archive: explicit source path must not be empty";
        return false;
    }
    for (const fs::path &component : input)
    {
        if (component == "..")
        {
            err = "archive: explicit source paths must not contain '..' components";
            return false;
        }
    }
    normalized = input.lexically_normal();
    while (!normalized.empty() && normalized.filename().empty() &&
           normalized != normalized.root_path())
    {
        normalized = normalized.parent_path();
    }
    if (normalized.empty() || normalized == "." ||
        normalized == normalized.root_path())
    {
        err = "archive: explicit source path must have a stable final name";
        return false;
    }
    const fs::path leaf = normalized.filename();
    if (leaf.empty() || leaf == "." || leaf == "..")
    {
        err = "archive: explicit source path must have a stable final name";
        return false;
    }
    archive_root = leaf.generic_string();
    return true;
}

bool create_entries_have_unique_names(const std::vector<CreateEntry> &entries,
                                      std::string &err)
{
    std::unordered_set<std::string> names;
    names.reserve(entries.size());
    for (const CreateEntry &entry : entries)
    {
        const std::string name = entry.relative.generic_string();
        if (!names.insert(name).second)
        {
            err = "archive: source list produces a duplicate archive entry: '" +
                  name + "'";
            return false;
        }
    }
    return true;
}

bool open_source_entry(const std::vector<ScopedFd> &source_roots,
                       const CreateEntry &entry, ScopedFd &result,
                       std::string &err)
{
    if (entry.source_index >= source_roots.size())
    {
        err = "archive: internal source plan mismatch";
        return false;
    }
    ScopedFd current(::fcntl(source_roots[entry.source_index].get(),
                             F_DUPFD_CLOEXEC, 3));
    if (current.get() < 0)
    {
        err = "archive: cannot duplicate source root descriptor: " +
              std::string(std::strerror(errno));
        return false;
    }
    std::vector<fs::path> components;
    for (const fs::path &component : entry.source_relative)
    {
        if (!is_dot_component(component))
        {
            components.push_back(component);
        }
    }
    for (std::size_t i = 0; i < components.size(); ++i)
    {
        const std::string name = components[i].string();
        const bool leaf = i + 1 == components.size();
        const int flags = leaf
                              ? O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                              : O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW;
        ScopedFd next(::openat(current.get(), name.c_str(), flags));
        if (next.get() < 0)
        {
            err = "archive: cannot securely open source entry '" +
                  entry.relative.generic_string() + "': " +
                  std::strerror(errno);
            return false;
        }
        current = std::move(next);
    }
    struct stat st{};
    if (::fstat(current.get(), &st) != 0)
    {
        err = "archive: cannot inspect opened source entry '" +
              entry.relative.generic_string() + "': " +
              std::strerror(errno);
        return false;
    }
    if (!S_ISREG(st.st_mode) || st.st_dev != entry.device ||
        st.st_ino != entry.inode || st.st_size < 0 ||
        static_cast<std::uint64_t>(st.st_size) != entry.size ||
        !same_timespec(st.st_mtim, entry.modified) ||
        !same_timespec(st.st_ctim, entry.changed))
    {
        err = "archive: source entry changed during archive creation: '" +
              entry.relative.generic_string() + "'";
        return false;
    }
    result = std::move(current);
    return true;
}

class AtomicArchiveOutput
{
public:
    ~AtomicArchiveOutput()
    {
        cleanup();
    }

    bool open(const fs::path &destination, bool overwrite, std::string &err)
    {
        destination_ = destination;
        leaf_ = destination.filename().string();
        if (destination.empty() || leaf_.empty() || leaf_ == "." ||
            leaf_ == "..")
        {
            err = "archive: destination must name an archive file";
            return false;
        }
        fs::path parent = destination.parent_path();
        if (parent.empty())
        {
            parent = ".";
        }
        if (!open_directory_without_symlinks(parent, parent_fd_,
                                             "destination parent", err))
        {
            return false;
        }
        struct stat existing{};
        if (::fstatat(parent_fd_.get(), leaf_.c_str(), &existing,
                      AT_SYMLINK_NOFOLLOW) == 0)
        {
            if (S_ISLNK(existing.st_mode))
            {
                err = "archive: destination must not be a symlink: '" +
                      destination.string() + "'";
                return false;
            }
            if (!S_ISREG(existing.st_mode))
            {
                err = "archive: destination is not a regular file: '" +
                      destination.string() + "'";
                return false;
            }
            if (!overwrite)
            {
                err = "archive: destination already exists: '" +
                      destination.string() + "'";
                return false;
            }
        }
        else if (errno != ENOENT)
        {
            err = "archive: " + errno_message("cannot inspect destination",
                                               destination, errno);
            return false;
        }
        overwrite_ = overwrite;

        for (unsigned attempt = 0; attempt < 128; ++attempt)
        {
            const unsigned long long serial =
                archive_temp_counter.fetch_add(1, std::memory_order_relaxed);
            temporary_ = ".babet-create-" +
                         std::to_string(static_cast<long long>(::getpid())) +
                         "-" + std::to_string(serial);
            if (temporary_ == leaf_)
            {
                continue;
            }
            const int fd = ::openat(parent_fd_.get(), temporary_.c_str(),
                                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC |
                                        O_NOFOLLOW,
                                    STAGING_FILE_MODE);
            if (fd >= 0)
            {
                temp_fd_.reset(fd);
                return true;
            }
            if (errno != EEXIST)
            {
                err = "archive: " + errno_message(
                    "cannot create temporary archive", parent / temporary_,
                    errno);
                return false;
            }
        }
        err = "archive: cannot allocate a unique temporary archive name";
        return false;
    }

    int fd() const noexcept { return temp_fd_.get(); }

    bool publish(std::string &err)
    {
        if (::fchmod(temp_fd_.get(), DEFAULT_FILE_MODE) != 0)
        {
            err = "archive: " + errno_message(
                "cannot set archive permissions", destination_, errno);
            return false;
        }
        if (::fsync(temp_fd_.get()) != 0)
        {
            err = "archive: " + errno_message("cannot sync archive",
                                               destination_, errno);
            return false;
        }
        if (overwrite_)
        {
            if (::renameat(parent_fd_.get(), temporary_.c_str(),
                           parent_fd_.get(), leaf_.c_str()) != 0)
            {
                err = "archive: " + errno_message(
                    "cannot atomically publish archive", destination_, errno);
                return false;
            }
        }
        else
        {
            if (::linkat(parent_fd_.get(), temporary_.c_str(),
                         parent_fd_.get(), leaf_.c_str(), 0) != 0)
            {
                err = "archive: " + errno_message(
                    "cannot publish archive without overwriting",
                    destination_, errno);
                return false;
            }
            if (::unlinkat(parent_fd_.get(), temporary_.c_str(), 0) != 0)
            {
                const int e = errno;
                ::unlinkat(parent_fd_.get(), leaf_.c_str(), 0);
                err = "archive: " + errno_message(
                    "cannot remove temporary archive link", destination_, e);
                return false;
            }
        }
        temporary_.clear();
        if (::fsync(parent_fd_.get()) != 0)
        {
            err = "archive: " + errno_message(
                "cannot sync archive destination directory", destination_,
                errno);
            return false;
        }
        return true;
    }

private:
    void cleanup() noexcept
    {
        if (!temporary_.empty() && parent_fd_.get() >= 0)
        {
            ::unlinkat(parent_fd_.get(), temporary_.c_str(), 0);
        }
    }

    fs::path destination_;
    std::string leaf_;
    std::string temporary_;
    ScopedFd parent_fd_;
    ScopedFd temp_fd_;
    bool overwrite_ = false;
};

class ArchiveWriter
{
public:
    ~ArchiveWriter()
    {
        if (initialized_)
        {
            mz_zip_writer_end(&zip_);
        }
    }

    bool init(FILE *file, bool zip64, std::string &err)
    {
        mz_zip_zero_struct(&zip_);
        allocation_state_ = {};
        zip_.m_pAlloc = bounded_miniz_alloc;
        zip_.m_pFree = bounded_miniz_free;
        zip_.m_pRealloc = bounded_miniz_realloc;
        zip_.m_pAlloc_opaque = &allocation_state_;
        const mz_uint flags = zip64 ? MZ_ZIP_FLAG_WRITE_ZIP64 : 0;
        if (!mz_zip_writer_init_cfile(&zip_, file, flags))
        {
            err = miniz_error(zip_, "cannot initialize ZIP writer", "output");
            return false;
        }
        initialized_ = true;
        return true;
    }

    bool add_directory(const std::string &name, const MZ_TIME_T *timestamp,
                       std::string &err)
    {
        static constexpr unsigned char empty_payload = 0;
        if (!mz_zip_writer_add_mem_ex_v2(
                &zip_, name.c_str(), &empty_payload, 0, nullptr, 0,
                MZ_NO_COMPRESSION, 0, 0,
                const_cast<MZ_TIME_T *>(timestamp), nullptr, 0, nullptr, 0))
        {
            err = miniz_error(zip_, "cannot add directory entry", name);
            return false;
        }
        return true;
    }

    bool add_file(const std::string &name, FILE *source,
                  std::uint64_t size, const MZ_TIME_T *timestamp,
                  int compression_level, std::string &err)
    {
        if (!mz_zip_writer_add_cfile(
                &zip_, name.c_str(), source, size, timestamp, nullptr, 0,
                static_cast<mz_uint>(compression_level), nullptr, 0, nullptr,
                0))
        {
            err = miniz_error(zip_, "cannot add source file", name);
            return false;
        }
        return true;
    }

    bool finalize_and_end(std::string &err)
    {
        if (!mz_zip_writer_finalize_archive(&zip_))
        {
            err = miniz_error(zip_, "cannot finalize ZIP archive", "output");
            return false;
        }
        if (!mz_zip_writer_end(&zip_))
        {
            initialized_ = false;
            err = "archive: cannot close ZIP writer";
            return false;
        }
        initialized_ = false;
        return true;
    }

private:
    mz_zip_archive zip_{};
    MinizAllocationState allocation_state_{};
    bool initialized_ = false;
};

bool source_file_unchanged(int fd, const CreateEntry &entry,
                           std::string &err)
{
    struct stat st{};
    if (::fstat(fd, &st) != 0)
    {
        err = "archive: cannot re-inspect source entry '" +
              entry.relative.generic_string() + "': " +
              std::strerror(errno);
        return false;
    }
    if (!S_ISREG(st.st_mode) || st.st_dev != entry.device ||
        st.st_ino != entry.inode || st.st_size < 0 ||
        static_cast<std::uint64_t>(st.st_size) != entry.size ||
        !same_timespec(st.st_mtim, entry.modified) ||
        !same_timespec(st.st_ctim, entry.changed))
    {
        err = "archive: source entry changed during archive creation: '" +
              entry.relative.generic_string() + "'";
        return false;
    }
    return true;
}

class TarCreationSource final : public babet::archive_tar::CreationSource
{
public:
    TarCreationSource(const std::vector<ScopedFd> &source_roots,
                      const std::vector<CreateEntry> &entries) noexcept
        : source_roots_(source_roots), entries_(entries)
    {
    }

    [[nodiscard]] bool begin_file(
        std::size_t index, const babet::archive_tar::CreateEntry &entry,
        std::string &err) override
    {
        if (active_fd_.get() >= 0 || index >= entries_.size())
        {
            err = "archive: internal TAR creation plan mismatch";
            return false;
        }
        const CreateEntry &planned = entries_[index];
        if (planned.kind != CreateEntryKind::regular ||
            planned.relative.generic_string() != entry.name ||
            planned.size != entry.size)
        {
            err = "archive: internal TAR creation plan mismatch";
            return false;
        }
        if (!open_source_entry(source_roots_, planned, active_fd_, err))
        {
            return false;
        }
        active_index_ = index;
        return true;
    }

    [[nodiscard]] bool read_file_block(void *buffer, std::size_t capacity,
                                       std::size_t &size,
                                       std::string &err) override
    {
        size = 0;
        if (active_fd_.get() < 0 || buffer == nullptr || capacity == 0)
        {
            err = "archive: invalid TAR source stream state";
            return false;
        }
        for (;;)
        {
            const ssize_t count = ::read(active_fd_.get(), buffer, capacity);
            if (count >= 0)
            {
                size = static_cast<std::size_t>(count);
                return true;
            }
            if (errno != EINTR)
            {
                err = "archive: cannot read source entry for TAR creation: " +
                      std::string(std::strerror(errno));
                return false;
            }
        }
    }

    [[nodiscard]] bool finish_file(
        std::size_t index, const babet::archive_tar::CreateEntry &entry,
        std::string &err) override
    {
        if (active_fd_.get() < 0 || !active_index_.has_value() ||
            *active_index_ != index || index >= entries_.size() ||
            entries_[index].relative.generic_string() != entry.name)
        {
            err = "archive: internal TAR creation plan mismatch";
            return false;
        }
        if (!source_file_unchanged(active_fd_.get(), entries_[index], err))
        {
            return false;
        }
        active_fd_.reset();
        active_index_.reset();
        return true;
    }

    void abort_file() noexcept override
    {
        active_fd_.reset();
        active_index_.reset();
    }

private:
    const std::vector<ScopedFd> &source_roots_;
    const std::vector<CreateEntry> &entries_;
    ScopedFd active_fd_;
    std::optional<std::size_t> active_index_;
};

std::vector<babet::archive_tar::CreateEntry> make_tar_create_entries(
    const std::vector<CreateEntry> &entries)
{
    std::vector<babet::archive_tar::CreateEntry> result;
    result.reserve(entries.size());
    for (const CreateEntry &entry : entries)
    {
        babet::archive_tar::CreateEntry item;
        item.name = entry.relative.generic_string();
        item.directory = entry.kind == CreateEntryKind::directory;
        if (item.directory)
        {
            item.name += "/";
        }
        item.size = entry.size;
        item.modified_seconds = static_cast<std::int64_t>(entry.modified.tv_sec);
        item.modified_nanoseconds = entry.modified.tv_nsec;
        result.push_back(std::move(item));
    }
    return result;
}

int lua_archive_create(lua_State *L)
{
    if (!lua_arity_between(L, 2, 3))
    {
        return luaL_error(L, "archive.create expects 2 or 3 arguments");
    }
    const int source_type = lua_type(L, 1);
    if (source_type != LUA_TSTRING && source_type != LUA_TTABLE)
    {
        return luaL_error(
            L, "archive.create source must be a directory string or a dense array of paths");
    }
    const bool legacy_directory_source = source_type == LUA_TSTRING;
    const std::string_view legacy_source_view = legacy_directory_source
                                                    ? luaL_checkstring_view_without_nul(
                                                          L, 1, "source directory")
                                                    : std::string_view{};
    const std::string_view destination_view =
        luaL_checkstring_view_without_nul(L, 2, "archive destination");

    std::vector<fs::path> source_paths;
    std::string err;
    if (legacy_directory_source)
    {
        if (legacy_source_view.empty())
        {
            return push_fail(L, "archive: source directory must not be empty");
        }
        source_paths.emplace_back(std::string(legacy_source_view));
    }
    else if (!collect_explicit_create_sources(L, 1, source_paths, err))
    {
        return push_fail(L, err);
    }

    ArchiveCreateOptions options;
    if (!collect_create_options(L, 3, options, err))
    {
        return push_fail(L, err);
    }
    if (destination_view.empty())
    {
        return push_fail(L, "archive: archive destination must not be empty");
    }

    const fs::path destination{std::string(destination_view)};
    if (!resolve_create_format(destination, options, err))
    {
        return push_fail(L, err);
    }

    std::vector<ScopedFd> source_roots;
    source_roots.reserve(source_paths.size());
    std::vector<CreateEntry> entries;
    std::uint64_t total_size = 0;
    std::uint64_t total_name_bytes = 0;
    std::uint64_t scanned_nodes = 0;

    if (legacy_directory_source)
    {
        bool destination_inside_source = false;
        if (!path_is_within(destination, source_paths[0],
                            destination_inside_source, err))
        {
            return push_fail(L, err);
        }
        if (destination_inside_source)
        {
            return push_fail(
                L, "archive: archive destination must not be inside the source directory");
        }

        ScopedFd source_fd;
        if (!open_directory_without_symlinks(source_paths[0], source_fd,
                                             "source directory", err))
        {
            return push_fail(L, err);
        }
        source_roots.push_back(std::move(source_fd));
        bool selected_any = false;
        if (!scan_create_directory(source_roots[0].get(), fs::path(),
                                   fs::path(), 0, 0, options, entries,
                                   total_size, total_name_bytes, scanned_nodes,
                                   selected_any, err))
        {
            return push_fail(L, err);
        }
    }
    else
    {
        std::unordered_set<std::string> top_level_names;
        top_level_names.reserve(source_paths.size());
        for (std::size_t source_index = 0;
             source_index < source_paths.size(); ++source_index)
        {
            if (scanned_nodes >= HARD_MAX_SCANNED_SOURCE_NODES)
            {
                return push_fail(
                    L, "archive: source list exceeds the internal 100000-node scan limit");
            }
            ++scanned_nodes;

            fs::path normalized_source;
            std::string archive_root;
            if (!normalize_explicit_source_path(source_paths[source_index],
                                                normalized_source,
                                                archive_root, err))
            {
                return push_fail(L, err);
            }
            if (!top_level_names.insert(archive_root).second)
            {
                return push_fail(
                    L, "archive: explicit sources have a colliding top-level name: '" +
                           archive_root + "'");
            }

            bool destination_inside_source = false;
            if (!path_is_within(destination, normalized_source,
                                destination_inside_source, err))
            {
                return push_fail(L, err);
            }
            if (destination_inside_source)
            {
                return push_fail(
                    L, "archive: archive destination must not be inside an explicit source");
            }

            fs::path parent = normalized_source.parent_path();
            if (parent.empty())
            {
                parent = ".";
            }
            const std::string leaf = normalized_source.filename().string();
            ScopedFd parent_fd;
            if (!open_directory_without_symlinks(parent, parent_fd,
                                                 "explicit source parent", err))
            {
                return push_fail(L, err);
            }
            struct stat st{};
            if (::fstatat(parent_fd.get(), leaf.c_str(), &st,
                          AT_SYMLINK_NOFOLLOW) != 0)
            {
                return push_fail(
                    L, "archive: cannot inspect explicit source '" +
                           normalized_source.string() + "': " +
                           std::strerror(errno));
            }
            if (S_ISLNK(st.st_mode))
            {
                return push_fail(
                    L, "archive: explicit source must not be a symlink: '" +
                           normalized_source.string() + "'");
            }

            if (S_ISREG(st.st_mode))
            {
                source_roots.push_back(std::move(parent_fd));
                ArchiveFilterDecision filter_decision =
                    ArchiveFilterDecision::not_included;
                if (!classify_create_path(options, fs::path(archive_root),
                                          false, filter_decision, err))
                {
                    return push_fail(L, err);
                }
                if (filter_decision == ArchiveFilterDecision::included &&
                    !append_create_entry(fs::path(archive_root),
                                         fs::path(leaf), source_index,
                                         CreateEntryKind::regular, st, options,
                                         entries, total_size,
                                         total_name_bytes, err))
                {
                    return push_fail(L, err);
                }
                continue;
            }
            if (!S_ISDIR(st.st_mode))
            {
                return push_fail(
                    L, "archive: unsupported explicit source type: '" +
                           normalized_source.string() + "'");
            }

            ScopedFd directory_fd(::openat(
                parent_fd.get(), leaf.c_str(),
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
            if (directory_fd.get() < 0)
            {
                return push_fail(
                    L, "archive: cannot securely open explicit source directory '" +
                           normalized_source.string() + "': " +
                           std::strerror(errno));
            }
            struct stat opened_directory{};
            if (::fstat(directory_fd.get(), &opened_directory) != 0 ||
                !S_ISDIR(opened_directory.st_mode) ||
                opened_directory.st_dev != st.st_dev ||
                opened_directory.st_ino != st.st_ino)
            {
                return push_fail(
                    L, "archive: explicit source directory changed while being opened: '" +
                           normalized_source.string() + "'");
            }
            source_roots.push_back(std::move(directory_fd));
            ArchiveFilterDecision root_filter =
                ArchiveFilterDecision::not_included;
            if (!classify_create_path(options, fs::path(archive_root), true,
                                      root_filter, err))
            {
                return push_fail(L, err);
            }
            if (root_filter == ArchiveFilterDecision::excluded)
            {
                continue;
            }

            bool descendants_selected = false;
            if (!scan_create_directory(
                    source_roots.back().get(), fs::path(archive_root),
                    fs::path(), source_index, 0, options, entries, total_size,
                    total_name_bytes, scanned_nodes, descendants_selected,
                    err))
            {
                return push_fail(L, err);
            }
            if (options.include_directories &&
                (root_filter == ArchiveFilterDecision::included ||
                 descendants_selected) &&
                !append_create_entry(fs::path(archive_root), fs::path(),
                                     source_index, CreateEntryKind::directory,
                                     st, options, entries, total_size,
                                     total_name_bytes, err))
            {
                return push_fail(L, err);
            }
        }
    }

    std::sort(entries.begin(), entries.end(),
              [](const CreateEntry &a, const CreateEntry &b)
              {
                  return a.relative.generic_string() <
                         b.relative.generic_string();
              });
    if (!create_entries_have_unique_names(entries, err))
    {
        return push_fail(L, err);
    }

    MZ_TIME_T fixed_time{};
    bool write_zip64 = false;
    if (options.format == CreateArchiveFormat::zip)
    {
        if (options.deterministic)
        {
            if (!fixed_deterministic_time(fixed_time, err))
            {
                return push_fail(L, err);
            }
        }
        else
        {
            for (const CreateEntry &entry : entries)
            {
                if (!validate_source_zip_timestamp(entry, err))
                {
                    return push_fail(L, err);
                }
            }
        }
        write_zip64 = create_requires_zip64(entries, total_size);
    }

    AtomicArchiveOutput output;
    if (!output.open(destination, options.overwrite, err))
    {
        return push_fail(L, err);
    }

    std::uint64_t files = 0;
    std::uint64_t directories = 0;
    if (options.format == CreateArchiveFormat::tar ||
        options.format == CreateArchiveFormat::tar_gzip ||
        options.format == CreateArchiveFormat::tar_xz ||
        options.format == CreateArchiveFormat::tar_bzip2 ||
        options.format == CreateArchiveFormat::tar_zstd)
    {
        const std::vector<babet::archive_tar::CreateEntry> tar_entries =
            make_tar_create_entries(entries);
        TarCreationSource tar_source(source_roots, entries);
        const babet::archive_tar::Compression tar_compression =
            options.format == CreateArchiveFormat::tar_gzip
                ? babet::archive_tar::Compression::gzip
                : options.format == CreateArchiveFormat::tar_xz
                      ? babet::archive_tar::Compression::xz
                      : options.format == CreateArchiveFormat::tar_bzip2
                            ? babet::archive_tar::Compression::bzip2
                            : options.format == CreateArchiveFormat::tar_zstd
                                  ? babet::archive_tar::Compression::zstd
                                  : babet::archive_tar::Compression::none;
        if (!babet::archive_tar::create_fd(
                output.fd(), destination.string(), tar_entries,
                tar_compression, options.compression_level,
                options.deterministic, tar_source, err))
        {
            return push_fail(L, err);
        }
        for (const CreateEntry &entry : entries)
        {
            if (entry.kind == CreateEntryKind::directory)
            {
                ++directories;
            }
            else
            {
                ++files;
            }
        }
    }
    else
    {
        const int stream_fd = ::dup(output.fd());
        if (stream_fd < 0)
        {
            return push_fail(
                L, "archive: cannot duplicate temporary archive descriptor: " +
                       std::string(std::strerror(errno)));
        }
        ScopedFile output_file(::fdopen(stream_fd, "w+b"));
        if (output_file.get() == nullptr)
        {
            const int e = errno;
            ::close(stream_fd);
            return push_fail(
                L, "archive: cannot open temporary archive stream: " +
                       std::string(std::strerror(e)));
        }

        ArchiveWriter writer;
        if (!writer.init(output_file.get(), write_zip64, err))
        {
            return push_fail(L, err);
        }
        for (const CreateEntry &entry : entries)
        {
            std::string archive_name = entry.relative.generic_string();
            if (entry.kind == CreateEntryKind::directory)
            {
                archive_name += "/";
                const MZ_TIME_T timestamp =
                    options.deterministic
                        ? fixed_time
                        : static_cast<MZ_TIME_T>(entry.modified.tv_sec);
                if (!writer.add_directory(archive_name, &timestamp, err))
                {
                    return push_fail(L, err);
                }
                ++directories;
                continue;
            }

            ScopedFd input_fd;
            if (!open_source_entry(source_roots, entry, input_fd, err))
            {
                return push_fail(L, err);
            }
            const int file_stream_fd = ::dup(input_fd.get());
            if (file_stream_fd < 0)
            {
                return push_fail(
                    L, "archive: cannot duplicate source file descriptor: " +
                           std::string(std::strerror(errno)));
            }
            ScopedFile input_file(::fdopen(file_stream_fd, "rb"));
            if (input_file.get() == nullptr)
            {
                const int e = errno;
                ::close(file_stream_fd);
                return push_fail(
                    L, "archive: cannot open source file stream: " +
                           std::string(std::strerror(e)));
            }
            const MZ_TIME_T timestamp =
                options.deterministic
                    ? fixed_time
                    : static_cast<MZ_TIME_T>(entry.modified.tv_sec);
            if (!writer.add_file(archive_name, input_file.get(), entry.size,
                                 &timestamp, options.compression_level, err) ||
                !source_file_unchanged(input_fd.get(), entry, err))
            {
                return push_fail(L, err);
            }
            ++files;
        }
        if (!writer.finalize_and_end(err))
        {
            return push_fail(L, err);
        }
        if (std::fflush(output_file.get()) != 0)
        {
            return push_fail(L,
                             "archive: cannot flush temporary archive: " +
                                 std::string(std::strerror(errno)));
        }
    }

    if (!output.publish(err))
    {
        return push_fail(L, err);
    }

    lua_newtable(L);
    push_u64(L, files);
    lua_setfield(L, -2, "files");
    push_u64(L, directories);
    lua_setfield(L, -2, "directories");
    push_u64(L, total_size);
    lua_setfield(L, -2, "bytes");
    push_u64(L, source_paths.size());
    lua_setfield(L, -2, "sources");
    lua_pushlstring(L, destination_view.data(), destination_view.size());
    lua_setfield(L, -2, "path");
    lua_pushstring(L, options.format == CreateArchiveFormat::zip ? "zip"
                                                                  : "tar");
    lua_setfield(L, -2, "format");
    lua_pushstring(L, options.format == CreateArchiveFormat::tar_gzip
                          ? "gzip"
                          : options.format == CreateArchiveFormat::tar_xz
                                ? "xz"
                                : options.format ==
                                          CreateArchiveFormat::tar_bzip2
                                      ? "bzip2"
                                      : options.format ==
                                                CreateArchiveFormat::tar_zstd
                                            ? "zstd"
                                            : "none");
    lua_setfield(L, -2, "compression");
    if (options.format == CreateArchiveFormat::zip ||
        options.format == CreateArchiveFormat::tar_gzip ||
        options.format == CreateArchiveFormat::tar_xz ||
        options.format == CreateArchiveFormat::tar_bzip2 ||
        options.format == CreateArchiveFormat::tar_zstd)
    {
        lua_pushinteger(L, options.compression_level);
    }
    else
    {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "compression_level");
    lua_pushboolean(L, options.deterministic);
    lua_setfield(L, -2, "deterministic");
    push_u64(L, options.filters.include_patterns.size());
    lua_setfield(L, -2, "include_patterns");
    push_u64(L, options.filters.exclude_patterns.size());
    lua_setfield(L, -2, "exclude_patterns");
    lua_pushnil(L);
    return 2;
}

mode_t file_mode_for_entry(const ArchiveEntry &entry,
                           const ArchiveOptions &options)
{
    if (!options.preserve_permissions || entry.unix_mode == 0)
    {
        return DEFAULT_FILE_MODE;
    }
    return entry.unix_mode & 0777;
}

mode_t directory_mode_for_entry(const ArchiveEntry &entry,
                                const ArchiveOptions &options)
{
    if (!options.preserve_permissions || entry.unix_mode == 0)
    {
        return DEFAULT_DIRECTORY_MODE;
    }
    return entry.unix_mode & 0777;
}

void push_u64(lua_State *L, std::uint64_t value)
{
    lua_pushinteger(L, static_cast<lua_Integer>(value));
}

void push_list_result(lua_State *L, const ArchiveScan &scan)
{
    lua_newtable(L);
    const char *format = scan.format == ArchiveFormat::zip ? "zip" : "tar";
    lua_pushstring(L, format);
    lua_setfield(L, -2, "format");
    lua_pushstring(L, scan.compression == ArchiveCompression::gzip
                          ? "gzip"
                          : scan.compression == ArchiveCompression::xz
                                ? "xz"
                                : scan.compression ==
                                          ArchiveCompression::bzip2
                                      ? "bzip2"
                                      : scan.compression ==
                                                ArchiveCompression::zstd
                                            ? "zstd"
                                            : "none");
    lua_setfield(L, -2, "compression");
    lua_createtable(L, static_cast<int>(scan.entries.size()), 0);
    for (std::size_t i = 0; i < scan.entries.size(); ++i)
    {
        const ArchiveEntry &entry = scan.entries[i];
        lua_newtable(L);
        push_u64(L, i + 1);
        lua_setfield(L, -2, "index");
        lua_pushlstring(L, entry.name.data(), entry.name.size());
        lua_setfield(L, -2, "name");
        lua_pushlstring(L, entry.normalized.data(), entry.normalized.size());
        lua_setfield(L, -2, "path");
        lua_pushboolean(L, entry.valid_utf8);
        lua_setfield(L, -2, "valid_utf8");
        const std::string type = entry_kind_name(entry.kind);
        lua_pushlstring(L, type.data(), type.size());
        lua_setfield(L, -2, "type");
        push_u64(L, entry.size);
        lua_setfield(L, -2, "size");
        if (entry.has_compressed_size)
        {
            push_u64(L, entry.compressed_size);
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "compressed_size");
        if (entry.has_crc32)
        {
            lua_pushinteger(L, entry.crc32);
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "crc32");
        if (entry.has_compression_method)
        {
            lua_pushinteger(L, entry.method);
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "compression_method");
        lua_pushboolean(L, entry.encrypted);
        lua_setfield(L, -2, "encrypted");
        lua_pushboolean(L, entry.supported);
        lua_setfield(L, -2, "supported");
        lua_pushboolean(L, entry.safe_path);
        lua_setfield(L, -2, "safe_path");
        const std::string rejection = extraction_rejection_reason(entry);
        lua_pushboolean(L, rejection.empty());
        lua_setfield(L, -2, "extractable");
        if (rejection.empty())
        {
            lua_pushnil(L);
        }
        else
        {
            lua_pushlstring(L, rejection.data(), rejection.size());
        }
        lua_setfield(L, -2, "reason");
        if (entry.has_unix_mode)
        {
            lua_pushinteger(L, entry.unix_mode & 07777);
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "unix_mode");
        if (entry.has_mtime)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(entry.mtime));
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "mtime");
        if (entry.has_mtime_nsec)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(entry.mtime_nsec));
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "mtime_nsec");
        if (entry.has_uid)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(entry.uid));
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "uid");
        if (entry.has_gid)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(entry.gid));
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "gid");
        lua_pushboolean(L, entry.sparse);
        lua_setfield(L, -2, "sparse");
        if (!entry.has_link_target)
        {
            lua_pushnil(L);
        }
        else
        {
            lua_pushlstring(L, entry.link_target.data(),
                            entry.link_target.size());
        }
        lua_setfield(L, -2, "link_target");
        lua_pushboolean(L, entry.duplicate);
        lua_setfield(L, -2, "duplicate");
        if (entry.duplicate)
        {
            push_u64(L, entry.duplicate_of);
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "duplicate_of");
        lua_pushboolean(L, entry.conflict);
        lua_setfield(L, -2, "conflict");
        if (entry.conflict)
        {
            push_u64(L, entry.conflict_with);
        }
        else
        {
            lua_pushnil(L);
        }
        lua_setfield(L, -2, "conflict_with");
        if (entry.conflict_reason.empty())
        {
            lua_pushnil(L);
        }
        else
        {
            lua_pushlstring(L, entry.conflict_reason.data(),
                            entry.conflict_reason.size());
        }
        lua_setfield(L, -2, "conflict_reason");
        lua_seti(L, -2, static_cast<lua_Integer>(i + 1));
    }
    lua_setfield(L, -2, "entries");
    push_u64(L, scan.entries.size());
    lua_setfield(L, -2, "count");
    push_u64(L, scan.total_size);
    lua_setfield(L, -2, "total_size");
    push_u64(L, scan.archive_size);
    lua_setfield(L, -2, "archive_size");
    push_u64(L, scan.total_name_bytes);
    lua_setfield(L, -2, "total_name_bytes");
    push_u64(L, scan.duplicate_entries);
    lua_setfield(L, -2, "duplicates");
    push_u64(L, scan.conflicting_entries);
    lua_setfield(L, -2, "conflicts");
    if (scan.format == ArchiveFormat::zip)
    {
        lua_pushboolean(L, scan.zip64);
    }
    else
    {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "zip64");
}

bool validate_test_safety(ArchiveScan &scan, std::string &err)
{
    if (!annotate_list_conflicts(scan, err))
    {
        return false;
    }

    std::vector<const ArchiveEntry *> entries;
    entries.reserve(scan.entries.size());
    for (const ArchiveEntry &entry : scan.entries)
    {
        entries.push_back(&entry);
    }
    return validate_selected_entries(entries, err);
}

void push_test_result(lua_State *L, const ArchiveScan &scan)
{
    std::uint64_t files = 0;
    std::uint64_t directories = 0;
    for (const ArchiveEntry &entry : scan.entries)
    {
        if (entry.kind == EntryKind::regular)
        {
            ++files;
        }
        else if (entry.kind == EntryKind::directory)
        {
            ++directories;
        }
    }

    lua_newtable(L);
    lua_pushstring(L, scan.format == ArchiveFormat::zip ? "zip" : "tar");
    lua_setfield(L, -2, "format");
    lua_pushstring(L, scan.compression == ArchiveCompression::gzip
                          ? "gzip"
                          : scan.compression == ArchiveCompression::xz
                                ? "xz"
                                : scan.compression ==
                                          ArchiveCompression::bzip2
                                      ? "bzip2"
                                      : scan.compression ==
                                                ArchiveCompression::zstd
                                            ? "zstd"
                                            : "none");
    lua_setfield(L, -2, "compression");
    push_u64(L, scan.entries.size());
    lua_setfield(L, -2, "entries");
    push_u64(L, files);
    lua_setfield(L, -2, "files");
    push_u64(L, directories);
    lua_setfield(L, -2, "directories");
    push_u64(L, scan.total_size);
    lua_setfield(L, -2, "total_size");
    push_u64(L, scan.archive_size);
    lua_setfield(L, -2, "archive_size");
    push_u64(L, scan.total_name_bytes);
    lua_setfield(L, -2, "total_name_bytes");
    if (scan.format == ArchiveFormat::zip)
    {
        lua_pushboolean(L, scan.zip64);
    }
    else
    {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "zip64");
}

bool scan_archive_for_list(const std::string &archive_path,
                           const ArchiveOptions &options, ArchiveScan &scan,
                           std::string &err)
{
    PinnedArchiveSource source;
    if (!source.open(archive_path, err))
    {
        return false;
    }

    std::string zip_error;
    {
        const int zip_fd = source.duplicate_rewound(err);
        if (zip_fd < 0)
        {
            return false;
        }
        ArchiveReader reader;
        if (reader.open_fd(zip_fd, archive_path, zip_error))
        {
            if (!scan_zip_archive(reader, options, scan, zip_error))
            {
                err = std::move(zip_error);
                return false;
            }
            return true;
        }
    }

    std::string tar_error;
    if (scan_tar_archive(source, options, scan, tar_error))
    {
        return true;
    }

    err = "archive: unsupported or malformed archive '" + archive_path +
          "' (ZIP: " + zip_error + "; TAR: " + tar_error + ")";
    return false;
}

int lua_archive_list(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L, "archive.list expects 1 or 2 arguments");
    }
    const std::string archive_path =
        luaL_checkstring_without_nul(L, 1, "archive path");

    ArchiveOptions options;
    std::string err;
    if (!collect_options(L, 2, false, false, options, err))
    {
        return push_fail(L, err);
    }

    ArchiveScan scan;
    if (!scan_archive_for_list(archive_path, options, scan, err))
    {
        return push_fail(L, err);
    }

    if (!annotate_list_conflicts(scan, err))
    {
        return push_fail(L, err);
    }
    push_list_result(L, scan);
    lua_pushnil(L);
    return 2;
}

int lua_archive_test(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L, "archive.test expects 1 or 2 arguments");
    }
    const std::string archive_path =
        luaL_checkstring_without_nul(L, 1, "archive path");

    ArchiveOptions options;
    std::string err;
    if (!collect_options(L, 2, false, false, options, err))
    {
        return push_fail(L, err);
    }

    PinnedArchiveSource source;
    if (!source.open(archive_path, err))
    {
        return push_fail(L, err);
    }

    ArchiveReader zip_reader;
    ArchiveScan scan;
    bool zip_backend = false;
    std::string zip_error;
    {
        const int zip_fd = source.duplicate_rewound(err);
        if (zip_fd < 0)
        {
            return push_fail(L, err);
        }
        if (zip_reader.open_fd(zip_fd, archive_path, zip_error))
        {
            if (!scan_zip_archive(zip_reader, options, scan, zip_error))
            {
                return push_fail(L, zip_error);
            }
            zip_backend = true;
        }
    }

    if (zip_backend)
    {
        if (!verify_zip_payloads(zip_reader, scan, err))
        {
            return push_fail(L, err);
        }
    }
    else
    {
        std::string tar_error;
        if (!scan_tar_archive(source, options, scan, tar_error))
        {
            err = "archive: unsupported or malformed archive '" +
                  archive_path + "' (ZIP: " + zip_error + "; TAR: " +
                  tar_error + ")";
            return push_fail(L, err);
        }
    }

    if (!validate_test_safety(scan, err))
    {
        return push_fail(L, err);
    }

    push_test_result(L, scan);
    lua_pushnil(L);
    return 2;
}

struct ExtractSelection
{
    std::vector<const ArchiveEntry *> entries;
    std::vector<unsigned char> selected_indices;
    std::uint64_t skipped = 0;
};

bool remember_extract_directory(std::unordered_set<std::string> &directories,
                                std::uint64_t &directory_path_bytes,
                                const std::string &path, std::string &err)
{
    const auto [unused, inserted] = directories.insert(path);
    (void)unused;
    if (!inserted)
    {
        return true;
    }
    if (directories.size() > HARD_MAX_OUTPUT_DIRECTORIES)
    {
        err = "archive: filtering path graph exceeds the internal 100000-directory limit";
        return false;
    }
    if (directory_path_bytes > HARD_MAX_OUTPUT_DIRECTORY_PATH_BYTES ||
        path.size() > HARD_MAX_OUTPUT_DIRECTORY_PATH_BYTES -
                          directory_path_bytes)
    {
        err = "archive: cumulative filtering directory paths exceed the internal 64 MiB limit";
        return false;
    }
    directory_path_bytes += path.size();
    return true;
}

bool build_extract_selection(ArchiveScan &scan, ArchiveOptions &options,
                             ExtractSelection &selection, std::string &err)
{
    selection = {};
    selection.selected_indices.assign(scan.entries.size(), 0);
    selection.entries.reserve(scan.entries.size());

    if (!options.filters.active())
    {
        for (std::size_t index = 0; index < scan.entries.size(); ++index)
        {
            selection.entries.push_back(&scan.entries[index]);
            selection.selected_indices[index] = 1;
        }
        return true;
    }

    std::unordered_set<std::string> directory_set;
    std::uint64_t directory_path_bytes = 0;
    for (const ArchiveEntry &entry : scan.entries)
    {
        if (!entry.safe_path)
        {
            continue;
        }
        std::size_t pos = 0;
        while ((pos = entry.normalized.find('/', pos)) != std::string::npos)
        {
            if (!remember_extract_directory(
                    directory_set, directory_path_bytes,
                    entry.normalized.substr(0, pos), err))
            {
                return false;
            }
            ++pos;
        }
        if (entry.kind == EntryKind::directory &&
            !remember_extract_directory(directory_set, directory_path_bytes,
                                        entry.normalized, err))
        {
            return false;
        }
    }

    std::vector<std::string> directory_paths(directory_set.begin(),
                                             directory_set.end());
    std::sort(directory_paths.begin(), directory_paths.end(),
              [](const std::string &lhs, const std::string &rhs)
              {
                  if (lhs.size() != rhs.size())
                  {
                      return lhs.size() < rhs.size();
                  }
                  return lhs < rhs;
              });

    std::unordered_map<std::string, ArchiveFilterDecision> directory_decisions;
    directory_decisions.reserve(directory_paths.size());
    for (const std::string &path : directory_paths)
    {
        ArchiveFilterDecision decision = ArchiveFilterDecision::not_included;
        const std::size_t slash = path.rfind('/');
        if (slash != std::string::npos)
        {
            const auto parent = directory_decisions.find(path.substr(0, slash));
            if (parent != directory_decisions.end() &&
                parent->second == ArchiveFilterDecision::excluded)
            {
                decision = ArchiveFilterDecision::excluded;
                directory_decisions.emplace(path, decision);
                continue;
            }
        }
        if (!classify_archive_path(options.filters, path, true, decision, err))
        {
            return false;
        }
        directory_decisions.emplace(path, decision);
    }

    for (std::size_t index = 0; index < scan.entries.size(); ++index)
    {
        ArchiveEntry &entry = scan.entries[index];
        ArchiveFilterDecision decision = ArchiveFilterDecision::not_included;
        if (!entry.safe_path)
        {
            // Filtering is defined on normalized names. An unsafe name has no
            // normalized representation and can only remain selected when no
            // include list narrows the historical "all entries" behaviour.
            decision = options.filters.include_patterns.empty()
                           ? ArchiveFilterDecision::included
                           : ArchiveFilterDecision::not_included;
        }
        else if (entry.kind == EntryKind::directory)
        {
            const auto found = directory_decisions.find(entry.normalized);
            if (found == directory_decisions.end())
            {
                err = "archive: internal extraction filter plan mismatch";
                return false;
            }
            decision = found->second;
        }
        else
        {
            const std::size_t slash = entry.normalized.rfind('/');
            if (slash != std::string::npos)
            {
                const auto parent =
                    directory_decisions.find(entry.normalized.substr(0, slash));
                if (parent != directory_decisions.end() &&
                    parent->second == ArchiveFilterDecision::excluded)
                {
                    decision = ArchiveFilterDecision::excluded;
                }
                else if (!classify_archive_path(options.filters,
                                                entry.normalized, false,
                                                decision, err))
                {
                    return false;
                }
            }
            else if (!classify_archive_path(options.filters, entry.normalized,
                                            false, decision, err))
            {
                return false;
            }
        }

        if (decision == ArchiveFilterDecision::included)
        {
            selection.entries.push_back(&entry);
            selection.selected_indices[index] = 1;
        }
    }
    selection.skipped = static_cast<std::uint64_t>(scan.entries.size()) -
                        static_cast<std::uint64_t>(selection.entries.size());
    return true;
}

struct ExtractPreview
{
    std::uint64_t would_create = 0;
    std::uint64_t would_overwrite = 0;
    std::uint64_t would_skip = 0;
    bool would_create_destination = false;
};

void push_extract_result(lua_State *L, const std::string &destination,
                         std::uint64_t entries, std::uint64_t files,
                         std::uint64_t directories, std::uint64_t skipped,
                         std::uint64_t bytes,
                         const ExtractPreview *preview = nullptr)
{
    lua_newtable(L);
    push_u64(L, entries);
    lua_setfield(L, -2, "entries");
    push_u64(L, files);
    lua_setfield(L, -2, "files");
    push_u64(L, directories);
    lua_setfield(L, -2, "directories");
    push_u64(L, skipped);
    lua_setfield(L, -2, "skipped");
    push_u64(L, bytes);
    lua_setfield(L, -2, "bytes");
    lua_pushlstring(L, destination.data(), destination.size());
    lua_setfield(L, -2, "path");
    if (preview != nullptr)
    {
        lua_pushboolean(L, 1);
        lua_setfield(L, -2, "dry_run");
        push_u64(L, preview->would_create);
        lua_setfield(L, -2, "would_create");
        push_u64(L, preview->would_overwrite);
        lua_setfield(L, -2, "would_overwrite");
        push_u64(L, preview->would_skip);
        lua_setfield(L, -2, "would_skip");
        lua_pushboolean(L, preview->would_create_destination);
        lua_setfield(L, -2, "would_create_destination");
    }
}

int lua_archive_extract(lua_State *L)
{
    if (!lua_arity_between(L, 2, 3))
    {
        return luaL_error(L, "archive.extract expects 2 or 3 arguments");
    }
    const std::string_view archive_path_view =
        luaL_checkstring_view_without_nul(L, 1, "archive path");
    const std::string_view destination_view =
        luaL_checkstring_view_without_nul(L, 2, "destination");
    if (destination_view.empty())
    {
        return push_fail(L, "archive: destination must not be empty");
    }

    const std::string archive_path(archive_path_view);
    const std::string destination(destination_view);

    ArchiveOptions options;
    std::string err;
    if (!collect_options(L, 3, true, true, options, err))
    {
        return push_fail(L, err);
    }

    PinnedArchiveSource source;
    if (!source.open(archive_path, err))
    {
        return push_fail(L, err);
    }

    ArchiveReader zip_reader;
    ArchiveScan scan;
    babet::archive_tar::ScanResult tar_scan;
    bool zip_backend = false;
    std::string zip_error;
    {
        const int zip_fd = source.duplicate_rewound(err);
        if (zip_fd < 0)
        {
            return push_fail(L, err);
        }
        if (zip_reader.open_fd(zip_fd, archive_path, zip_error))
        {
            if (!scan_zip_archive(zip_reader, options, scan, zip_error))
            {
                return push_fail(L, zip_error);
            }
            zip_backend = true;
        }
    }

    if (!zip_backend)
    {
        std::string tar_error;
        if (!scan_tar_archive(source, options, scan, tar_error, &tar_scan))
        {
            err = "archive: unsupported or malformed archive '" +
                  archive_path + "' (ZIP: " + zip_error + "; TAR: " +
                  tar_error + ")";
            return push_fail(L, err);
        }
    }

    ExtractSelection selection;
    if (!build_extract_selection(scan, options, selection, err) ||
        !validate_selected_entries(selection.entries, err))
    {
        return push_fail(L, err);
    }

    if (options.filters.active() && selection.entries.empty())
    {
        ExtractPreview preview;
        push_extract_result(L, destination, 0, 0, 0, selection.skipped, 0,
                            options.dry_run ? &preview : nullptr);
        lua_pushnil(L);
        return 2;
    }

    const std::vector<const ArchiveEntry *> &selected = selection.entries;
    std::uint64_t files = 0;
    std::uint64_t directories = 0;
    std::uint64_t bytes = 0;
    for (const ArchiveEntry *entry : selected)
    {
        if (entry->kind == EntryKind::directory)
        {
            ++directories;
        }
        else if (entry->kind == EntryKind::regular)
        {
            ++files;
            bytes += entry->size;
        }
    }

    SecureArchiveDestination output;
    if (!output.open_root(destination, !options.dry_run, err))
    {
        return push_fail(L, err);
    }

    ExtractPreview preview;
    preview.would_create_destination =
        options.dry_run && !output.root_exists();
    for (const ArchiveEntry *entry : selected)
    {
        DestinationAction action = DestinationAction::create;
        if (!output.preflight(fs::path(entry->normalized), entry->kind,
                              options.overwrite, err,
                              options.dry_run ? &action : nullptr))
        {
            return push_fail(L, err);
        }
        if (options.dry_run)
        {
            switch (action)
            {
            case DestinationAction::create:
                ++preview.would_create;
                break;
            case DestinationAction::overwrite:
                ++preview.would_overwrite;
                break;
            case DestinationAction::skip:
                ++preview.would_skip;
                break;
            }
        }
    }

    if (options.dry_run)
    {
        if (zip_backend)
        {
            if (!verify_selected_zip_payloads(zip_reader, selected, err))
            {
                return push_fail(L, err);
            }
        }
        else
        {
            const int tar_fd = source.duplicate_rewound(err);
            if (tar_fd < 0)
            {
                return push_fail(L, err);
            }
            const babet::archive_tar::ScanLimits limits{
                .max_entries = options.max_entries,
                .max_entry_size = options.max_entry_size,
                .max_total_size = options.max_total_size,
                .max_path_length = options.max_path_length,
                .max_total_name_bytes = options.max_total_name_bytes,
                .max_compression_ratio = options.max_compression_ratio,
            };
            TarDryRunSink sink(selection.selected_indices);
            const bool verified = babet::archive_tar::extract_fd(
                tar_fd, source.size(), source.path(), limits,
                tar_scan.compression, tar_scan.entries, sink, err);
            ::close(tar_fd);
            if (!verified)
            {
                return push_fail(L, err);
            }
        }

        push_extract_result(L, destination, selected.size(), files,
                            directories, selection.skipped, bytes, &preview);
        lua_pushnil(L);
        return 2;
    }

    for (const ArchiveEntry *entry : selected)
    {
        if (entry->kind != EntryKind::directory)
        {
            continue;
        }
        if (!output.ensure_directory(
                fs::path(entry->normalized),
                directory_mode_for_entry(*entry, options), err))
        {
            return push_fail(L, err);
        }
    }

    if (zip_backend)
    {
        for (const ArchiveEntry *entry : selected)
        {
            if (entry->kind != EntryKind::regular)
            {
                continue;
            }
            if (!output.stage_file(zip_reader.zip(), *entry,
                                   file_mode_for_entry(*entry, options), err))
            {
                return push_fail(L, err);
            }
        }
    }
    else
    {
        const int tar_fd = source.duplicate_rewound(err);
        if (tar_fd < 0)
        {
            return push_fail(L, err);
        }
        const babet::archive_tar::ScanLimits limits{
            .max_entries = options.max_entries,
            .max_entry_size = options.max_entry_size,
            .max_total_size = options.max_total_size,
            .max_path_length = options.max_path_length,
            .max_total_name_bytes = options.max_total_name_bytes,
            .max_compression_ratio = options.max_compression_ratio,
        };
        TarExtractionSink sink(output, scan, options,
                               &selection.selected_indices);
        const bool extracted = babet::archive_tar::extract_fd(
            tar_fd, source.size(), source.path(), limits,
            tar_scan.compression, tar_scan.entries, sink, err);
        ::close(tar_fd);
        if (!extracted)
        {
            return push_fail(L, err);
        }
    }

    if (!output.publish(options.overwrite, err) ||
        !output.finalize_directory_modes(err))
    {
        return push_fail(L, err);
    }
    output.commit();

    push_extract_result(L, destination, selected.size(), files, directories,
                        selection.skipped, bytes);
    lua_pushnil(L);
    return 2;
}

int lua_archive_extract_file(lua_State *L)
{
    if (!lua_arity_between(L, 3, 4))
    {
        return luaL_error(L, "archive.extractFile expects 3 or 4 arguments");
    }
    const std::string_view archive_path_view =
        luaL_checkstring_view_without_nul(L, 1, "archive path");
    const std::string_view requested_view =
        luaL_checkstring_view_without_nul(L, 2, "archive entry");
    const std::string_view destination_view =
        luaL_checkstring_view_without_nul(L, 3, "destination");

    const std::string archive_path(archive_path_view);
    const std::string requested(requested_view);
    const std::string destination(destination_view);

    ArchiveOptions options;
    std::string err;
    if (!collect_options(L, 4, true, false, options, err))
    {
        return push_fail(L, err);
    }

    PinnedArchiveSource source;
    if (!source.open(archive_path, err))
    {
        return push_fail(L, err);
    }

    ArchiveReader zip_reader;
    ArchiveScan scan;
    babet::archive_tar::ScanResult tar_scan;
    bool zip_backend = false;
    std::string zip_error;
    {
        const int zip_fd = source.duplicate_rewound(err);
        if (zip_fd < 0)
        {
            return push_fail(L, err);
        }
        if (zip_reader.open_fd(zip_fd, archive_path, zip_error))
        {
            if (!scan_zip_archive(zip_reader, options, scan, zip_error))
            {
                return push_fail(L, zip_error);
            }
            zip_backend = true;
        }
    }

    if (!zip_backend)
    {
        std::string tar_error;
        if (!scan_tar_archive(source, options, scan, tar_error, &tar_scan))
        {
            err = "archive: unsupported or malformed archive '" +
                  archive_path + "' (ZIP: " + zip_error + "; TAR: " +
                  tar_error + ")";
            return push_fail(L, err);
        }
    }

    const ArchiveEntry *selected = nullptr;
    std::size_t selected_index = 0;
    for (std::size_t index = 0; index < scan.entries.size(); ++index)
    {
        const ArchiveEntry &entry = scan.entries[index];
        if (entry.name == requested)
        {
            if (selected != nullptr)
            {
                return push_fail(L, "archive: requested entry is ambiguous because it appears more than once");
            }
            selected = &entry;
            selected_index = index;
        }
    }
    if (selected == nullptr)
    {
        return push_fail(L, "archive: entry not found: '" + requested + "'");
    }
    std::vector<const ArchiveEntry *> selected_entries = {selected};
    if (!validate_selected_entries(selected_entries, err))
    {
        return push_fail(L, err);
    }
    if (selected->kind != EntryKind::regular)
    {
        return push_fail(L, "archive: extractFile only accepts a regular file entry");
    }

    const fs::path destination_path(destination);
    const fs::path leaf = destination_path.filename();
    if (destination_path.empty() || leaf.empty() || leaf == "." ||
        leaf == "..")
    {
        return push_fail(L, "archive: destination must name a regular file");
    }
    fs::path parent = destination_path.parent_path();
    if (parent.empty())
    {
        parent = ".";
    }

    SecureArchiveDestination output;
    if (!output.open_root(parent, err) ||
        !output.preflight(leaf, EntryKind::regular, options.overwrite, err))
    {
        return push_fail(L, err);
    }

    if (zip_backend)
    {
        ArchiveEntry mapped = *selected;
        mapped.normalized = leaf.string();
        if (!output.stage_file(zip_reader.zip(), mapped,
                               file_mode_for_entry(*selected, options), err))
        {
            return push_fail(L, err);
        }
    }
    else
    {
        const int tar_fd = source.duplicate_rewound(err);
        if (tar_fd < 0)
        {
            return push_fail(L, err);
        }
        const babet::archive_tar::ScanLimits limits{
            .max_entries = options.max_entries,
            .max_entry_size = options.max_entry_size,
            .max_total_size = options.max_total_size,
            .max_path_length = options.max_path_length,
            .max_total_name_bytes = options.max_total_name_bytes,
            .max_compression_ratio = options.max_compression_ratio,
        };
        TarExtractionSink sink(output, scan, options, selected_index, leaf);
        const bool extracted = babet::archive_tar::extract_fd(
            tar_fd, source.size(), source.path(), limits,
            tar_scan.compression, tar_scan.entries, sink, err);
        ::close(tar_fd);
        if (!extracted)
        {
            return push_fail(L, err);
        }
    }

    if (!output.publish(options.overwrite, err) ||
        !output.finalize_directory_modes(err))
    {
        return push_fail(L, err);
    }
    output.commit();

    lua_newtable(L);
    push_u64(L, selected->size);
    lua_setfield(L, -2, "bytes");
    lua_pushlstring(L, destination.data(), destination.size());
    lua_setfield(L, -2, "path");
    lua_pushlstring(L, selected->name.data(), selected->name.size());
    lua_setfield(L, -2, "entry");
    lua_pushnil(L);
    return 2;
}

} // namespace

void register_archive(lua_State *L)
{
    lua_newtable(L);

    lua_pushcfunction(L, lua_archive_create);
    lua_setfield(L, -2, "create");

    lua_pushcfunction(L, lua_archive_list);
    lua_setfield(L, -2, "list");

    lua_pushcfunction(L, lua_archive_test);
    lua_setfield(L, -2, "test");

    lua_pushcfunction(L, lua_archive_extract);
    lua_setfield(L, -2, "extract");

    lua_pushcfunction(L, lua_archive_extract_file);
    lua_setfield(L, -2, "extractFile");

    lua_setfield(L, -2, "archive");
}
