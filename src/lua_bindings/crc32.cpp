#include "crc32.hpp"
#include "lua_utils.hpp"

#include <miniz.h>

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <vector>

namespace fs = std::filesystem;

namespace
{

    // Chunk size for streaming reads. 64 KiB is a good compromise between
    // syscall overhead and memory footprint, and matches what miniz uses
    // internally for compression streams.
    constexpr size_t kChunkSize = 64 * 1024;

    /**
     * Format a 32-bit value as a lowercase 8-character hex string,
     * zero-padded on the left. Same shape as md5sum / sha256sum output
     * but truncated to the size of a CRC32.
     */
    std::string to_hex8(uint32_t value)
    {
        char buf[9];
        std::snprintf(buf, sizeof(buf), "%08x", value);
        return std::string(buf);
    }

} // namespace

std::string crc32_hex(const unsigned char *data, size_t len)
{
    mz_ulong crc = mz_crc32(MZ_CRC32_INIT, data, len);
    return to_hex8(static_cast<uint32_t>(crc));
}

std::optional<std::string> crc32sum(const std::string &path,
                                    std::string &err_out)
{
    // Refuse explicitly anything that is not a regular file.
    // fs::status follows symlinks, which is what we want here: a
    // symlink pointing at a real file is fine.
    std::error_code ec;
    auto status = fs::status(path, ec);
    if (ec)
    {
        err_out = "crc32sum: " + ec.message();
        return std::nullopt;
    }
    if (!fs::exists(status))
    {
        err_out = "crc32sum: no such file or directory";
        return std::nullopt;
    }
    if (!fs::is_regular_file(status))
    {
        err_out = "crc32sum: not a regular file";
        return std::nullopt;
    }

    std::ifstream file(path, std::ios::binary);
    if (!file)
    {
        err_out = "crc32sum: cannot open file";
        return std::nullopt;
    }

    mz_ulong crc = MZ_CRC32_INIT;
    std::vector<unsigned char> buffer(kChunkSize);

    // read() may set eof when reading the last partial chunk, so we
    // keep going as long as gcount() > 0. file.bad() catches actual
    // I/O errors (distinct from EOF).
    while (file.read(reinterpret_cast<char *>(buffer.data()), kChunkSize) ||
           file.gcount() > 0)
    {
        const auto n = static_cast<size_t>(file.gcount());
        crc = mz_crc32(crc, buffer.data(), n);
    }

    if (file.bad())
    {
        err_out = "crc32sum: read error";
        return std::nullopt;
    }

    return to_hex8(static_cast<uint32_t>(crc));
}

namespace
{
int lua_crc32_impl(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "Expected one argument");
    if (!lua_is_strict_string(L, 1))
        return luaL_error(L, "Expected a string as argument");

    size_t len = 0;
    const char *data = lua_tolstring(L, 1, &len);
    std::string hex = crc32_hex(
        reinterpret_cast<const unsigned char *>(data), len);
    auto builder = [&hex](lua_State *Ls) noexcept -> int
    {
        lua_pushlstring(Ls, hex.data(), hex.size());
        return 1;
    };
    return lua_build_results_protected(L, builder, 1);
}

int lua_crc32sum_impl(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "Expected one argument");
    if (!lua_is_strict_string(L, 1))
        return luaL_error(L, "Expected a string as argument");

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    std::string err_msg;
    auto result = crc32sum(path, err_msg);
    if (result.has_value())
        return push_string_result_protected(L, *result);
    return push_fail_protected(L, err_msg);
}
} // namespace

int lua_crc32(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_crc32_impl>(
        L, "crc32: out of memory", "crc32: internal failure",
        "crc32: unknown internal failure");
}

int lua_crc32sum(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_crc32sum_impl>(
        L, "crc32sum: out of memory", "crc32sum: internal failure",
        "crc32sum: unknown internal failure");
}
