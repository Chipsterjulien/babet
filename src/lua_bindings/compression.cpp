#include "compression.hpp"
#include "lua_utils.hpp"
#include "project_core/compression_stream.hpp"

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_set>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
constexpr std::uint64_t DEFAULT_MAX_OUTPUT_SIZE =
    1024ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t HARD_MAX_OUTPUT_SIZE =
    64ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr mode_t OUTPUT_MODE = 0644;
constexpr mode_t STAGING_MODE = 0600;

std::atomic<unsigned long long> compression_temp_counter{0};

struct CompressionOptions
{
    bool overwrite = false;
    std::optional<lua_Integer> level;
    std::uint64_t max_output_size = DEFAULT_MAX_OUTPUT_SIZE;
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

    [[nodiscard]] int get() const noexcept { return fd_; }

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

std::string path_error(std::string_view action, const fs::path &path,
                       int error_number)
{
    std::string result = "compression: ";
    result.append(action);
    result += " '";
    result += path.string();
    result += "': ";
    result += std::strerror(error_number);
    return result;
}

bool same_timespec(const timespec &left, const timespec &right) noexcept
{
    return left.tv_sec == right.tv_sec && left.tv_nsec == right.tv_nsec;
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
        err = "compression: " + std::string(label) + " must not be empty";
        return false;
    }

    ScopedFd current(::open(path.is_absolute() ? "/" : ".",
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (current.get() < 0)
    {
        err = path_error("cannot open", path, errno);
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
            err = "compression: " + std::string(label) +
                  " must not contain '..' components";
            return false;
        }

        const std::string component = component_path.string();
        struct stat st{};
        if (::fstatat(current.get(), component.c_str(), &st,
                      AT_SYMLINK_NOFOLLOW) != 0)
        {
            err = path_error("cannot inspect " + std::string(label),
                             traversed / component_path, errno);
            return false;
        }
        if (S_ISLNK(st.st_mode))
        {
            err = "compression: " + std::string(label) +
                  " contains a symlink component: '" +
                  (traversed / component_path).string() + "'";
            return false;
        }
        if (!S_ISDIR(st.st_mode))
        {
            err = "compression: " + std::string(label) +
                  " component is not a directory: '" +
                  (traversed / component_path).string() + "'";
            return false;
        }

        ScopedFd next(::openat(current.get(), component.c_str(),
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                   O_NOFOLLOW));
        if (next.get() < 0)
        {
            err = path_error("cannot securely open " + std::string(label),
                             traversed / component_path, errno);
            return false;
        }
        current = std::move(next);
        traversed /= component_path;
    }

    result = std::move(current);
    return true;
}

class PinnedSource
{
public:
    bool open(const fs::path &source, std::string &err)
    {
        source_ = source;
        const std::string leaf = source.filename().string();
        if (source.empty() || leaf.empty() || leaf == "." || leaf == "..")
        {
            err = "compression: source must name a regular file";
            return false;
        }

        fs::path parent = source.parent_path();
        if (parent.empty())
        {
            parent = ".";
        }
        ScopedFd parent_fd;
        if (!open_directory_without_symlinks(parent, parent_fd,
                                             "source parent", err))
        {
            return false;
        }

        const int fd = ::openat(parent_fd.get(), leaf.c_str(),
                                O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
                                    O_NONBLOCK);
        if (fd < 0)
        {
            err = path_error("cannot securely open source", source, errno);
            return false;
        }
        fd_.reset(fd);

        if (::fstat(fd_.get(), &initial_) != 0)
        {
            err = path_error("cannot inspect source", source, errno);
            return false;
        }
        if (!S_ISREG(initial_.st_mode))
        {
            err = "compression: source is not a regular file: '" +
                  source.string() + "'";
            return false;
        }
        if (initial_.st_size < 0)
        {
            err = "compression: source has a negative size: '" +
                  source.string() + "'";
            return false;
        }
        return true;
    }

    [[nodiscard]] int fd() const noexcept { return fd_.get(); }
    [[nodiscard]] const struct stat &stat() const noexcept { return initial_; }

    bool rewind(std::string &err) const
    {
        if (::lseek(fd_.get(), 0, SEEK_SET) < 0)
        {
            err = path_error("cannot rewind source", source_, errno);
            return false;
        }
        return true;
    }

    bool unchanged(std::string &err) const
    {
        struct stat current{};
        if (::fstat(fd_.get(), &current) != 0)
        {
            err = path_error("cannot re-inspect source", source_, errno);
            return false;
        }
        if (!S_ISREG(current.st_mode) || current.st_dev != initial_.st_dev ||
            current.st_ino != initial_.st_ino ||
            current.st_size != initial_.st_size ||
            !same_timespec(current.st_mtim, initial_.st_mtim) ||
            !same_timespec(current.st_ctim, initial_.st_ctim))
        {
            err = "compression: source changed while it was being processed: '" +
                  source_.string() + "'";
            return false;
        }
        return true;
    }

private:
    fs::path source_;
    ScopedFd fd_;
    struct stat initial_{};
};

class AtomicOutput
{
public:
    ~AtomicOutput()
    {
        cleanup();
    }

    bool open(const fs::path &destination, bool overwrite,
              const struct stat &source_stat, std::string &err)
    {
        destination_ = destination;
        leaf_ = destination.filename().string();
        if (destination.empty() || leaf_.empty() || leaf_ == "." ||
            leaf_ == "..")
        {
            err = "compression: destination must name a regular file";
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
            if (existing.st_dev == source_stat.st_dev &&
                existing.st_ino == source_stat.st_ino)
            {
                err = "compression: source and destination must be different files";
                return false;
            }
            if (S_ISLNK(existing.st_mode))
            {
                err = "compression: destination must not be a symlink: '" +
                      destination.string() + "'";
                return false;
            }
            if (!S_ISREG(existing.st_mode))
            {
                err = "compression: destination is not a regular file: '" +
                      destination.string() + "'";
                return false;
            }
            if (!overwrite)
            {
                err = "compression: destination already exists: '" +
                      destination.string() + "'";
                return false;
            }
        }
        else if (errno != ENOENT)
        {
            err = path_error("cannot inspect destination", destination, errno);
            return false;
        }
        overwrite_ = overwrite;

        for (unsigned int attempt = 0; attempt < 128; ++attempt)
        {
            const unsigned long long serial =
                compression_temp_counter.fetch_add(1,
                                                   std::memory_order_relaxed);
            temporary_ = ".babet-compression-" +
                         std::to_string(static_cast<long long>(::getpid())) +
                         "-" + std::to_string(serial);
            if (temporary_ == leaf_)
            {
                continue;
            }
            const int fd = ::openat(parent_fd_.get(), temporary_.c_str(),
                                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC |
                                        O_NOFOLLOW,
                                    STAGING_MODE);
            if (fd >= 0)
            {
                temp_fd_.reset(fd);
                return true;
            }
            if (errno != EEXIST)
            {
                err = path_error("cannot create temporary destination",
                                 parent / temporary_, errno);
                return false;
            }
        }

        err = "compression: cannot allocate a unique temporary destination name";
        return false;
    }

    [[nodiscard]] int fd() const noexcept { return temp_fd_.get(); }

    bool publish(std::string &err)
    {
        if (::fchmod(temp_fd_.get(), OUTPUT_MODE) != 0)
        {
            err = path_error("cannot set destination permissions",
                             destination_, errno);
            return false;
        }
        if (::fsync(temp_fd_.get()) != 0)
        {
            err = path_error("cannot sync temporary destination",
                             destination_, errno);
            return false;
        }

        if (overwrite_)
        {
            if (::renameat(parent_fd_.get(), temporary_.c_str(),
                           parent_fd_.get(), leaf_.c_str()) != 0)
            {
                err = path_error("cannot atomically publish destination",
                                 destination_, errno);
                return false;
            }
        }
        else
        {
            if (::linkat(parent_fd_.get(), temporary_.c_str(),
                         parent_fd_.get(), leaf_.c_str(), 0) != 0)
            {
                err = path_error("cannot publish destination without overwriting",
                                 destination_, errno);
                return false;
            }
            if (::unlinkat(parent_fd_.get(), temporary_.c_str(), 0) != 0)
            {
                const int saved_errno = errno;
                ::unlinkat(parent_fd_.get(), leaf_.c_str(), 0);
                err = path_error("cannot remove temporary destination link",
                                 destination_, saved_errno);
                return false;
            }
        }

        temporary_.clear();
        if (::fsync(parent_fd_.get()) != 0)
        {
            err = path_error("cannot sync destination directory",
                             destination_, errno);
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

void raw_getfield(lua_State *L, int index, const char *name)
{
    index = lua_absindex(L, index);
    lua_pushstring(L, name);
    lua_rawget(L, index);
}

bool validate_option_keys(lua_State *L, int index, bool decompression,
                          std::string &err)
{
    if (lua_is_none_or_nil(L, index))
    {
        return true;
    }
    if (lua_type(L, index) != LUA_TTABLE)
    {
        err = "compression options must be a table";
        return false;
    }

    static const std::unordered_set<std::string> compress_allowed = {
        "overwrite", "level"};
    static const std::unordered_set<std::string> decompress_allowed = {
        "overwrite", "max_output_size"};
    const auto &allowed = decompression ? decompress_allowed : compress_allowed;

    index = lua_absindex(L, index);
    lua_pushnil(L);
    while (lua_next(L, index) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 2);
            err = "compression option keys must be strings";
            return false;
        }
        std::size_t length = 0;
        const char *data = lua_tolstring(L, -2, &length);
        const std::string key(data, length);
        if (!allowed.contains(key))
        {
            lua_pop(L, 2);
            err = "unknown compression option: " + key;
            return false;
        }
        lua_pop(L, 1);
    }
    return true;
}

bool parse_options(lua_State *L, int index, bool decompression,
                   CompressionOptions &options, std::string &err)
{
    if (!validate_option_keys(L, index, decompression, err))
    {
        return false;
    }
    if (lua_is_none_or_nil(L, index))
    {
        return true;
    }
    index = lua_absindex(L, index);

    raw_getfield(L, index, "overwrite");
    if (!lua_is_optional_strict_boolean(L, -1))
    {
        lua_pop(L, 1);
        err = "opts.overwrite must be a boolean";
        return false;
    }
    if (!lua_is_none_or_nil(L, -1))
    {
        options.overwrite = lua_toboolean(L, -1) != 0;
    }
    lua_pop(L, 1);

    if (!decompression)
    {
        raw_getfield(L, index, "level");
        if (!lua_is_optional_strict_integer(L, -1))
        {
            lua_pop(L, 1);
            err = "opts.level must be an integer";
            return false;
        }
        if (!lua_is_none_or_nil(L, -1))
        {
            options.level = lua_tointeger(L, -1);
        }
        lua_pop(L, 1);
        return true;
    }

    raw_getfield(L, index, "max_output_size");
    if (!lua_is_optional_strict_integer(L, -1))
    {
        lua_pop(L, 1);
        err = "opts.max_output_size must be an integer";
        return false;
    }
    if (!lua_is_none_or_nil(L, -1))
    {
        const lua_Integer parsed = lua_tointeger(L, -1);
        if (parsed < 1 ||
            static_cast<unsigned long long>(parsed) > HARD_MAX_OUTPUT_SIZE)
        {
            lua_pop(L, 1);
            err = "opts.max_output_size must be between 1 and " +
                  std::to_string(HARD_MAX_OUTPUT_SIZE);
            return false;
        }
        options.max_output_size = static_cast<std::uint64_t>(parsed);
    }
    lua_pop(L, 1);
    return true;
}

int lua_compress(lua_State *L)
{
    if (!lua_arity_between(L, 3, 4))
    {
        return luaL_error(L,
                          "compression.compress expects 3 or 4 arguments");
    }

    const std::string_view source_view =
        luaL_checkstring_view_without_nul(L, 1, "source path");
    const std::string_view destination_view =
        luaL_checkstring_view_without_nul(L, 2, "destination path");
    const std::string_view format_view =
        luaL_checkstring_view_without_nul(L, 3, "compression format");

    if (source_view.empty())
    {
        return push_fail_protected(L, "compression: source path must not be empty");
    }
    if (destination_view.empty())
    {
        return push_fail_protected(L,
                         "compression: destination path must not be empty");
    }

    babet::compression_stream::Format format{};
    if (!babet::compression_stream::parse_format(format_view, format))
    {
        return push_fail_protected(
            L,
            "compression: format must be 'gzip', 'xz', 'bzip2', or 'zstd'");
    }

    CompressionOptions options;
    std::string err;
    bool options_ok = false;
    auto parser = [&](lua_State *Ls)
    {
        options_ok = parse_options(Ls, 4, false, options, err);
    };
    lua_run_protected(L, parser);
    if (!options_ok)
    {
        return push_fail_protected(L, err);
    }

    const babet::compression_stream::CompressionLevelInfo level_info =
        babet::compression_stream::compression_level_info(format);
    int compression_level = level_info.default_level;
    if (options.level.has_value())
    {
        const lua_Integer requested = *options.level;
        if (requested < static_cast<lua_Integer>(level_info.minimum) ||
            requested > static_cast<lua_Integer>(level_info.maximum))
        {
            err = "opts.level for ";
            err += babet::compression_stream::format_name(format);
            err += " must be between ";
            err += std::to_string(level_info.minimum);
            err += " and ";
            err += std::to_string(level_info.maximum);
            return push_fail_protected(L, err);
        }
        compression_level = static_cast<int>(requested);
    }

    PinnedSource source;
    if (!source.open(fs::path(std::string(source_view)), err))
    {
        return push_fail_protected(L, err);
    }

    AtomicOutput output;
    if (!output.open(fs::path(std::string(destination_view)),
                     options.overwrite, source.stat(), err) ||
        !source.rewind(err))
    {
        return push_fail_protected(L, err);
    }

    std::uint64_t input_bytes = 0;
    std::uint64_t output_bytes = 0;
    if (!babet::compression_stream::compress_fd(
            source.fd(), output.fd(), format, compression_level, input_bytes,
            output_bytes, err) ||
        !source.unchanged(err) || !output.publish(err))
    {
        return push_fail_protected(L, err);
    }

    return push_ok_protected(L);
}

int lua_decompress(lua_State *L)
{
    if (!lua_arity_between(L, 2, 3))
    {
        return luaL_error(L,
                          "compression.decompress expects 2 or 3 arguments");
    }

    const std::string_view source_view =
        luaL_checkstring_view_without_nul(L, 1, "source path");
    const std::string_view destination_view =
        luaL_checkstring_view_without_nul(L, 2, "destination path");

    if (source_view.empty())
    {
        return push_fail_protected(L, "compression: source path must not be empty");
    }
    if (destination_view.empty())
    {
        return push_fail_protected(L,
                         "compression: destination path must not be empty");
    }

    CompressionOptions options;
    std::string err;
    bool options_ok = false;
    auto parser = [&](lua_State *Ls)
    {
        options_ok = parse_options(Ls, 3, true, options, err);
    };
    lua_run_protected(L, parser);
    if (!options_ok)
    {
        return push_fail_protected(L, err);
    }

    PinnedSource source;
    if (!source.open(fs::path(std::string(source_view)), err))
    {
        return push_fail_protected(L, err);
    }

    babet::compression_stream::Format format{};
    if (!babet::compression_stream::detect_format_fd(source.fd(), format,
                                                       err))
    {
        return push_fail_protected(L, err);
    }

    AtomicOutput output;
    if (!output.open(fs::path(std::string(destination_view)),
                     options.overwrite, source.stat(), err) ||
        !source.rewind(err))
    {
        return push_fail_protected(L, err);
    }

    std::uint64_t input_bytes = 0;
    std::uint64_t output_bytes = 0;
    if (!babet::compression_stream::decompress_fd(
            source.fd(), output.fd(), format, options.max_output_size,
            input_bytes, output_bytes, err) ||
        !source.unchanged(err) || !output.publish(err))
    {
        return push_fail_protected(L, err);
    }

    return push_ok_protected(L);
}

template <int (*Fn)(lua_State *)>
int compression_lua_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "compression: out of memory", "compression: internal failure",
        "compression: unknown internal failure");
}

} // namespace

void register_compression(lua_State *L)
{
    lua_newtable(L);

    lua_pushcfunction(L, compression_lua_boundary<lua_compress>);
    lua_setfield(L, -2, "compress");

    lua_pushcfunction(L, compression_lua_boundary<lua_decompress>);
    lua_setfield(L, -2, "decompress");

    lua_setfield(L, -2, "compression");
}
