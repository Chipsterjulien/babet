#include "compression_stream.hpp"

#include <bzlib.h>
#include <lzma.h>
#include <zlib.h>
#include <zstd.h>

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <string_view>

#include <unistd.h>

namespace babet::compression_stream
{
namespace
{
constexpr std::size_t BUFFER_SIZE = 64U * 1024U;
constexpr std::uint64_t XZ_DECODER_MEMORY_LIMIT =
    256ULL * 1024ULL * 1024ULL;
constexpr int ZSTD_DECODER_WINDOW_LOG_MAX = 27; // 128 MiB

bool checked_add(std::uint64_t &value, std::size_t amount,
                 std::string_view what, std::string &err)
{
    if (amount > std::numeric_limits<std::uint64_t>::max() - value)
    {
        err = "compression: " + std::string(what) + " byte count overflow";
        return false;
    }
    value += static_cast<std::uint64_t>(amount);
    return true;
}

bool read_some(int fd, void *buffer, std::size_t capacity,
               std::size_t &read_size, std::string &err)
{
    for (;;)
    {
        const ssize_t result = ::read(fd, buffer, capacity);
        if (result >= 0)
        {
            read_size = static_cast<std::size_t>(result);
            return true;
        }
        if (errno == EINTR)
        {
            continue;
        }
        err = "compression: cannot read source stream: ";
        err += std::strerror(errno);
        return false;
    }
}

bool write_all(int fd, const void *buffer, std::size_t size,
               std::uint64_t &written, std::string &err)
{
    const auto *data = static_cast<const unsigned char *>(buffer);
    std::size_t offset = 0;
    while (offset < size)
    {
        const ssize_t result = ::write(fd, data + offset, size - offset);
        if (result > 0)
        {
            offset += static_cast<std::size_t>(result);
            if (!checked_add(written, static_cast<std::size_t>(result),
                             "output", err))
            {
                return false;
            }
            continue;
        }
        if (result < 0 && errno == EINTR)
        {
            continue;
        }
        err = "compression: cannot write destination stream: ";
        err += result == 0 ? "short write" : std::strerror(errno);
        return false;
    }
    return true;
}

bool write_bounded(int fd, const void *buffer, std::size_t size,
                   std::uint64_t max_output_size,
                   std::uint64_t &written, std::string &err)
{
    if (written > max_output_size ||
        size > max_output_size - written)
    {
        err = "compression: decompressed output exceeds opts.max_output_size";
        return false;
    }
    return write_all(fd, buffer, size, written, err);
}

std::string zlib_detail(int code, const z_stream &stream)
{
    if (stream.msg != nullptr && *stream.msg != '\0')
    {
        return stream.msg;
    }
    switch (code)
    {
    case Z_ERRNO:
        return std::strerror(errno);
    case Z_STREAM_ERROR:
        return "invalid zlib stream state";
    case Z_DATA_ERROR:
        return "invalid or corrupted gzip stream";
    case Z_MEM_ERROR:
        return "out of memory";
    case Z_BUF_ERROR:
        return "truncated gzip stream";
    case Z_VERSION_ERROR:
        return "zlib version mismatch";
    default:
        return "zlib error " + std::to_string(code);
    }
}

std::string lzma_detail(lzma_ret code)
{
    switch (code)
    {
    case LZMA_MEM_ERROR:
        return "out of memory";
    case LZMA_MEMLIMIT_ERROR:
        return "decoder memory limit exceeded";
    case LZMA_FORMAT_ERROR:
        return "input is not an xz stream";
    case LZMA_OPTIONS_ERROR:
        return "unsupported xz options";
    case LZMA_DATA_ERROR:
        return "invalid or corrupted xz stream";
    case LZMA_BUF_ERROR:
        return "truncated xz stream";
    case LZMA_PROG_ERROR:
        return "internal liblzma programming error";
    default:
        return "liblzma error " + std::to_string(static_cast<int>(code));
    }
}

std::string bzip2_detail(int code)
{
    switch (code)
    {
    case BZ_CONFIG_ERROR:
        return "libbz2 configuration error";
    case BZ_PARAM_ERROR:
        return "invalid libbz2 parameter";
    case BZ_MEM_ERROR:
        return "out of memory";
    case BZ_DATA_ERROR:
        return "invalid or corrupted bzip2 stream";
    case BZ_DATA_ERROR_MAGIC:
        return "input is not a bzip2 stream";
    case BZ_UNEXPECTED_EOF:
        return "truncated bzip2 stream";
    case BZ_SEQUENCE_ERROR:
        return "invalid libbz2 stream state";
    default:
        return "libbz2 error " + std::to_string(code);
    }
}

bool compress_gzip(int source_fd, int output_fd, int compression_level,
                   std::uint64_t &input_bytes,
                   std::uint64_t &output_bytes, std::string &err)
{
    z_stream stream{};
    const int init = ::deflateInit2(&stream, compression_level,
                                    Z_DEFLATED, 15 + 16, 8,
                                    Z_DEFAULT_STRATEGY);
    if (init != Z_OK)
    {
        err = "compression: cannot initialise gzip encoder: " +
              zlib_detail(init, stream);
        return false;
    }

    std::array<unsigned char, BUFFER_SIZE> input{};
    std::array<unsigned char, BUFFER_SIZE> output{};
    bool success = false;
    bool eof = false;

    while (!success)
    {
        std::size_t input_size = 0;
        if (!eof)
        {
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
            stream.next_in = input.data();
            stream.avail_in = static_cast<uInt>(input_size);
        }

        const int flush = eof ? Z_FINISH : Z_NO_FLUSH;
        do
        {
            stream.next_out = output.data();
            stream.avail_out = static_cast<uInt>(output.size());
            const int status = ::deflate(&stream, flush);
            if (status != Z_OK && status != Z_STREAM_END)
            {
                err = "compression: gzip encoding failed: " +
                      zlib_detail(status, stream);
                goto cleanup;
            }
            const std::size_t produced = output.size() - stream.avail_out;
            if (!write_all(output_fd, output.data(), produced, output_bytes,
                           err))
            {
                goto cleanup;
            }
            if (status == Z_STREAM_END)
            {
                success = true;
                break;
            }
        } while (stream.avail_in != 0 ||
                 (eof && stream.avail_out == 0));
    }

cleanup:
    {
        const int end_status = ::deflateEnd(&stream);
        if (success && end_status != Z_OK)
        {
            err = "compression: cannot finalise gzip encoder: " +
                  zlib_detail(end_status, stream);
            success = false;
        }
    }
    return success;
}

bool decompress_gzip(int source_fd, int output_fd,
                     std::uint64_t max_output_size,
                     std::uint64_t &input_bytes,
                     std::uint64_t &output_bytes, std::string &err)
{
    z_stream stream{};
    int status = ::inflateInit2(&stream, 15 + 16);
    if (status != Z_OK)
    {
        err = "compression: cannot initialise gzip decoder: " +
              zlib_detail(status, stream);
        return false;
    }

    std::array<unsigned char, BUFFER_SIZE> input{};
    std::array<unsigned char, BUFFER_SIZE> output{};
    bool eof = false;
    bool at_member_boundary = false;
    std::uint64_t members = 0;
    bool success = false;

    for (;;)
    {
        if (stream.avail_in == 0 && !eof)
        {
            std::size_t input_size = 0;
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
            stream.next_in = input.data();
            stream.avail_in = static_cast<uInt>(input_size);
        }

        if (stream.avail_in == 0 && eof)
        {
            if (at_member_boundary && members > 0)
            {
                success = true;
            }
            else
            {
                err = "compression: truncated gzip stream";
            }
            break;
        }

        stream.next_out = output.data();
        stream.avail_out = static_cast<uInt>(output.size());
        status = ::inflate(&stream, Z_NO_FLUSH);
        const std::size_t produced = output.size() - stream.avail_out;
        if (!write_bounded(output_fd, output.data(), produced,
                           max_output_size, output_bytes, err))
        {
            break;
        }

        if (status == Z_STREAM_END)
        {
            ++members;
            at_member_boundary = true;
            Bytef *remaining_data = stream.next_in;
            const uInt remaining_size = stream.avail_in;
            status = ::inflateReset2(&stream, 15 + 16);
            if (status != Z_OK)
            {
                err = "compression: cannot reset gzip decoder: " +
                      zlib_detail(status, stream);
                break;
            }
            stream.next_in = remaining_data;
            stream.avail_in = remaining_size;
            continue;
        }
        if (status != Z_OK)
        {
            err = "compression: gzip decoding failed: " +
                  zlib_detail(status, stream);
            break;
        }
        at_member_boundary = false;

        if (produced == 0 && stream.avail_in == 0 && eof)
        {
            err = "compression: truncated gzip stream";
            break;
        }
    }

    const int end_status = ::inflateEnd(&stream);
    if (success && end_status != Z_OK)
    {
        err = "compression: cannot finalise gzip decoder: " +
              zlib_detail(end_status, stream);
        success = false;
    }
    return success;
}

bool compress_xz(int source_fd, int output_fd, int compression_level,
                 std::uint64_t &input_bytes,
                 std::uint64_t &output_bytes, std::string &err)
{
    lzma_stream stream = LZMA_STREAM_INIT;
    lzma_ret status = ::lzma_easy_encoder(
        &stream, static_cast<std::uint32_t>(compression_level),
        LZMA_CHECK_CRC64);
    if (status != LZMA_OK)
    {
        err = "compression: cannot initialise xz encoder: " +
              lzma_detail(status);
        return false;
    }

    std::array<std::uint8_t, BUFFER_SIZE> input{};
    std::array<std::uint8_t, BUFFER_SIZE> output{};
    bool eof = false;
    bool success = false;

    while (!success)
    {
        if (stream.avail_in == 0 && !eof)
        {
            std::size_t input_size = 0;
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
            stream.next_in = input.data();
            stream.avail_in = input_size;
        }

        stream.next_out = output.data();
        stream.avail_out = output.size();
        status = ::lzma_code(&stream, eof ? LZMA_FINISH : LZMA_RUN);
        const std::size_t produced = output.size() - stream.avail_out;
        if (!write_all(output_fd, output.data(), produced, output_bytes, err))
        {
            break;
        }
        if (status == LZMA_STREAM_END)
        {
            success = true;
            break;
        }
        if (status != LZMA_OK)
        {
            err = "compression: xz encoding failed: " + lzma_detail(status);
            break;
        }
    }

    ::lzma_end(&stream);
    return success;
}

bool decompress_xz(int source_fd, int output_fd,
                   std::uint64_t max_output_size,
                   std::uint64_t &input_bytes,
                   std::uint64_t &output_bytes, std::string &err)
{
    lzma_stream stream = LZMA_STREAM_INIT;
    lzma_ret status = ::lzma_stream_decoder(
        &stream, XZ_DECODER_MEMORY_LIMIT, LZMA_CONCATENATED);
    if (status != LZMA_OK)
    {
        err = "compression: cannot initialise xz decoder: " +
              lzma_detail(status);
        return false;
    }

    std::array<std::uint8_t, BUFFER_SIZE> input{};
    std::array<std::uint8_t, BUFFER_SIZE> output{};
    bool eof = false;
    bool success = false;

    for (;;)
    {
        if (stream.avail_in == 0 && !eof)
        {
            std::size_t input_size = 0;
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
            stream.next_in = input.data();
            stream.avail_in = input_size;
        }

        stream.next_out = output.data();
        stream.avail_out = output.size();
        status = ::lzma_code(&stream, eof ? LZMA_FINISH : LZMA_RUN);
        const std::size_t produced = output.size() - stream.avail_out;
        if (!write_bounded(output_fd, output.data(), produced,
                           max_output_size, output_bytes, err))
        {
            break;
        }
        if (status == LZMA_STREAM_END)
        {
            success = true;
            break;
        }
        if (status != LZMA_OK)
        {
            err = "compression: xz decoding failed: " +
                  lzma_detail(status);
            break;
        }
        if (eof && produced == 0 && stream.avail_in == 0)
        {
            err = "compression: truncated xz stream";
            break;
        }
    }

    ::lzma_end(&stream);
    return success;
}

bool compress_bzip2(int source_fd, int output_fd, int compression_level,
                    std::uint64_t &input_bytes,
                    std::uint64_t &output_bytes, std::string &err)
{
    bz_stream stream{};
    int status = ::BZ2_bzCompressInit(&stream, compression_level, 0, 30);
    if (status != BZ_OK)
    {
        err = "compression: cannot initialise bzip2 encoder: " +
              bzip2_detail(status);
        return false;
    }

    std::array<char, BUFFER_SIZE> input{};
    std::array<char, BUFFER_SIZE> output{};
    bool eof = false;
    bool success = false;

    while (!success)
    {
        if (stream.avail_in == 0 && !eof)
        {
            std::size_t input_size = 0;
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
            stream.next_in = input.data();
            stream.avail_in = static_cast<unsigned int>(input_size);
        }

        stream.next_out = output.data();
        stream.avail_out = static_cast<unsigned int>(output.size());
        status = ::BZ2_bzCompress(&stream, eof ? BZ_FINISH : BZ_RUN);
        const std::size_t produced = output.size() - stream.avail_out;
        if (!write_all(output_fd, output.data(), produced, output_bytes, err))
        {
            break;
        }
        if (status == BZ_STREAM_END)
        {
            success = true;
            break;
        }
        if (status != (eof ? BZ_FINISH_OK : BZ_RUN_OK))
        {
            err = "compression: bzip2 encoding failed: " +
                  bzip2_detail(status);
            break;
        }
    }

    const int end_status = ::BZ2_bzCompressEnd(&stream);
    if (success && end_status != BZ_OK)
    {
        err = "compression: cannot finalise bzip2 encoder: " +
              bzip2_detail(end_status);
        success = false;
    }
    return success;
}

bool decompress_bzip2(int source_fd, int output_fd,
                      std::uint64_t max_output_size,
                      std::uint64_t &input_bytes,
                      std::uint64_t &output_bytes, std::string &err)
{
    bz_stream stream{};
    int status = ::BZ2_bzDecompressInit(&stream, 0, 0);
    if (status != BZ_OK)
    {
        err = "compression: cannot initialise bzip2 decoder: " +
              bzip2_detail(status);
        return false;
    }

    std::array<char, BUFFER_SIZE> input{};
    std::array<char, BUFFER_SIZE> output{};
    bool eof = false;
    bool at_member_boundary = false;
    std::uint64_t members = 0;
    bool success = false;

    for (;;)
    {
        if (stream.avail_in == 0 && !eof)
        {
            std::size_t input_size = 0;
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
            stream.next_in = input.data();
            stream.avail_in = static_cast<unsigned int>(input_size);
        }

        if (stream.avail_in == 0 && eof)
        {
            if (at_member_boundary && members > 0)
            {
                success = true;
            }
            else
            {
                err = "compression: truncated bzip2 stream";
            }
            break;
        }

        stream.next_out = output.data();
        stream.avail_out = static_cast<unsigned int>(output.size());
        status = ::BZ2_bzDecompress(&stream);
        const std::size_t produced = output.size() - stream.avail_out;
        if (!write_bounded(output_fd, output.data(), produced,
                           max_output_size, output_bytes, err))
        {
            break;
        }

        if (status == BZ_STREAM_END)
        {
            ++members;
            at_member_boundary = true;
            char *remaining_data = stream.next_in;
            const unsigned int remaining_size = stream.avail_in;
            const int end_status = ::BZ2_bzDecompressEnd(&stream);
            if (end_status != BZ_OK)
            {
                err = "compression: cannot finalise bzip2 member: " +
                      bzip2_detail(end_status);
                break;
            }
            stream = {};
            status = ::BZ2_bzDecompressInit(&stream, 0, 0);
            if (status != BZ_OK)
            {
                err = "compression: cannot reset bzip2 decoder: " +
                      bzip2_detail(status);
                break;
            }
            stream.next_in = remaining_data;
            stream.avail_in = remaining_size;
            continue;
        }
        if (status != BZ_OK)
        {
            err = "compression: bzip2 decoding failed: " +
                  bzip2_detail(status);
            break;
        }
        at_member_boundary = false;

        if (eof && produced == 0 && stream.avail_in == 0)
        {
            err = "compression: truncated bzip2 stream";
            break;
        }
    }

    const int end_status = ::BZ2_bzDecompressEnd(&stream);
    if (success && end_status != BZ_OK)
    {
        err = "compression: cannot finalise bzip2 decoder: " +
              bzip2_detail(end_status);
        success = false;
    }
    return success;
}

bool compress_zstd(int source_fd, int output_fd, int compression_level,
                   std::uint64_t &input_bytes,
                   std::uint64_t &output_bytes, std::string &err)
{
    ZSTD_CStream *stream = ::ZSTD_createCStream();
    if (stream == nullptr)
    {
        err = "compression: cannot allocate zstd encoder";
        return false;
    }
    std::size_t status = ::ZSTD_initCStream(stream, compression_level);
    if (::ZSTD_isError(status) == 0)
    {
        // Babet-generated zstd frames carry a content checksum. External
        // frames without that optional field remain readable, but enabling it
        // here gives our own outputs end-to-end corruption detection.
        status = ::ZSTD_CCtx_setParameter(stream, ZSTD_c_checksumFlag, 1);
    }
    if (::ZSTD_isError(status) != 0)
    {
        err = "compression: cannot initialise zstd encoder: ";
        err += ::ZSTD_getErrorName(status);
        ::ZSTD_freeCStream(stream);
        return false;
    }

    std::array<unsigned char, BUFFER_SIZE> input{};
    std::array<unsigned char, BUFFER_SIZE> output{};
    bool eof = false;
    bool success = false;

    while (!success)
    {
        std::size_t input_size = 0;
        if (!eof)
        {
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
        }

        ZSTD_inBuffer in{input.data(), input_size, 0};
        const ZSTD_EndDirective directive =
            eof ? ZSTD_e_end : ZSTD_e_continue;
        do
        {
            ZSTD_outBuffer out{output.data(), output.size(), 0};
            status = ::ZSTD_compressStream2(stream, &out, &in, directive);
            if (::ZSTD_isError(status) != 0)
            {
                err = "compression: zstd encoding failed: ";
                err += ::ZSTD_getErrorName(status);
                goto cleanup;
            }
            if (!write_all(output_fd, output.data(), out.pos, output_bytes,
                           err))
            {
                goto cleanup;
            }
            if (eof && status == 0)
            {
                success = true;
                break;
            }
        } while (in.pos < in.size || (eof && status != 0));
    }

cleanup:
    {
        const std::size_t free_status = ::ZSTD_freeCStream(stream);
        if (success && ::ZSTD_isError(free_status) != 0)
        {
            err = "compression: cannot finalise zstd encoder: ";
            err += ::ZSTD_getErrorName(free_status);
            success = false;
        }
    }
    return success;
}

bool decompress_zstd(int source_fd, int output_fd,
                     std::uint64_t max_output_size,
                     std::uint64_t &input_bytes,
                     std::uint64_t &output_bytes, std::string &err)
{
    ZSTD_DStream *stream = ::ZSTD_createDStream();
    if (stream == nullptr)
    {
        err = "compression: cannot allocate zstd decoder";
        return false;
    }
    std::size_t status = ::ZSTD_DCtx_setParameter(
        stream, ZSTD_d_windowLogMax, ZSTD_DECODER_WINDOW_LOG_MAX);
    if (::ZSTD_isError(status) == 0)
    {
        status = ::ZSTD_initDStream(stream);
    }
    if (::ZSTD_isError(status) != 0)
    {
        err = "compression: cannot initialise zstd decoder: ";
        err += ::ZSTD_getErrorName(status);
        ::ZSTD_freeDStream(stream);
        return false;
    }

    std::array<unsigned char, BUFFER_SIZE> input{};
    std::array<unsigned char, BUFFER_SIZE> output{};
    bool eof = false;
    bool at_frame_boundary = false;
    std::uint64_t frames = 0;
    bool success = false;

    for (;;)
    {
        std::size_t input_size = 0;
        if (!eof)
        {
            if (!read_some(source_fd, input.data(), input.size(), input_size,
                           err) ||
                !checked_add(input_bytes, input_size, "input", err))
            {
                break;
            }
            eof = input_size == 0;
        }

        if (eof && input_size == 0)
        {
            if (at_frame_boundary && frames > 0)
            {
                success = true;
            }
            else
            {
                err = "compression: truncated zstd stream";
            }
            break;
        }

        ZSTD_inBuffer in{input.data(), input_size, 0};
        while (in.pos < in.size)
        {
            ZSTD_outBuffer out{output.data(), output.size(), 0};
            status = ::ZSTD_decompressStream(stream, &out, &in);
            if (::ZSTD_isError(status) != 0)
            {
                err = "compression: zstd decoding failed: ";
                err += ::ZSTD_getErrorName(status);
                goto cleanup;
            }
            if (!write_bounded(output_fd, output.data(), out.pos,
                               max_output_size, output_bytes, err))
            {
                goto cleanup;
            }
            if (status == 0)
            {
                ++frames;
                at_frame_boundary = true;
            }
            else
            {
                at_frame_boundary = false;
            }
            if (out.pos == 0 && in.pos == in.size)
            {
                break;
            }
        }
    }

cleanup:
    {
        const std::size_t free_status = ::ZSTD_freeDStream(stream);
        if (success && ::ZSTD_isError(free_status) != 0)
        {
            err = "compression: cannot finalise zstd decoder: ";
            err += ::ZSTD_getErrorName(free_status);
            success = false;
        }
    }
    return success;
}

} // namespace

const char *format_name(Format format) noexcept
{
    switch (format)
    {
    case Format::gzip:
        return "gzip";
    case Format::xz:
        return "xz";
    case Format::bzip2:
        return "bzip2";
    case Format::zstd:
        return "zstd";
    }
    return "unknown";
}

bool parse_format(std::string_view value, Format &format) noexcept
{
    if (value == "gzip")
    {
        format = Format::gzip;
        return true;
    }
    if (value == "xz")
    {
        format = Format::xz;
        return true;
    }
    if (value == "bzip2")
    {
        format = Format::bzip2;
        return true;
    }
    if (value == "zstd")
    {
        format = Format::zstd;
        return true;
    }
    return false;
}

CompressionLevelInfo compression_level_info(Format format) noexcept
{
    switch (format)
    {
    case Format::gzip:
        return {0, 9, 6};
    case Format::xz:
        return {0, 9, static_cast<int>(LZMA_PRESET_DEFAULT)};
    case Format::bzip2:
        return {1, 9, 9};
    case Format::zstd:
        return {1, 22, ZSTD_CLEVEL_DEFAULT};
    }
    return {0, 0, 0};
}

bool detect_format_fd(int source_fd, Format &format, std::string &err)
{
    std::array<unsigned char, 8> magic{};
    ssize_t result = 0;
    do
    {
        result = ::pread(source_fd, magic.data(), magic.size(), 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0)
    {
        err = "compression: cannot inspect source stream: ";
        err += std::strerror(errno);
        return false;
    }
    const std::size_t size = static_cast<std::size_t>(result);
    if (size >= 2 && magic[0] == 0x1f && magic[1] == 0x8b)
    {
        format = Format::gzip;
        return true;
    }
    if (size >= 6 && magic[0] == 0xfd && magic[1] == 0x37 &&
        magic[2] == 0x7a && magic[3] == 0x58 && magic[4] == 0x5a &&
        magic[5] == 0x00)
    {
        format = Format::xz;
        return true;
    }
    if (size >= 4 && magic[0] == 'B' && magic[1] == 'Z' &&
        magic[2] == 'h' && magic[3] >= '1' && magic[3] <= '9')
    {
        format = Format::bzip2;
        return true;
    }
    const bool zstd_frame =
        size >= 4 && magic[0] == 0x28 && magic[1] == 0xb5 &&
        magic[2] == 0x2f && magic[3] == 0xfd;
    const bool zstd_skippable_frame =
        size >= 4 && magic[0] >= 0x50 && magic[0] <= 0x5f &&
        magic[1] == 0x2a && magic[2] == 0x4d && magic[3] == 0x18;
    if (zstd_frame || zstd_skippable_frame)
    {
        format = Format::zstd;
        return true;
    }
    err = "compression: unsupported or unrecognised compressed stream";
    return false;
}

bool compress_fd(int source_fd, int output_fd, Format format,
                 int compression_level, std::uint64_t &input_bytes,
                 std::uint64_t &output_bytes, std::string &err)
{
    input_bytes = 0;
    output_bytes = 0;

    const CompressionLevelInfo level_info = compression_level_info(format);
    if (compression_level < level_info.minimum ||
        compression_level > level_info.maximum)
    {
        err = "compression: internal compression level is outside the "
              "supported range";
        return false;
    }

    switch (format)
    {
    case Format::gzip:
        return compress_gzip(source_fd, output_fd, compression_level,
                             input_bytes, output_bytes, err);
    case Format::xz:
        return compress_xz(source_fd, output_fd, compression_level,
                           input_bytes, output_bytes, err);
    case Format::bzip2:
        return compress_bzip2(source_fd, output_fd, compression_level,
                              input_bytes, output_bytes, err);
    case Format::zstd:
        return compress_zstd(source_fd, output_fd, compression_level,
                             input_bytes, output_bytes, err);
    }
    err = "compression: unsupported compression format";
    return false;
}

bool decompress_fd(int source_fd, int output_fd, Format format,
                   std::uint64_t max_output_size,
                   std::uint64_t &input_bytes,
                   std::uint64_t &output_bytes, std::string &err)
{
    input_bytes = 0;
    output_bytes = 0;
    switch (format)
    {
    case Format::gzip:
        return decompress_gzip(source_fd, output_fd, max_output_size,
                               input_bytes, output_bytes, err);
    case Format::xz:
        return decompress_xz(source_fd, output_fd, max_output_size,
                             input_bytes, output_bytes, err);
    case Format::bzip2:
        return decompress_bzip2(source_fd, output_fd, max_output_size,
                                input_bytes, output_bytes, err);
    case Format::zstd:
        return decompress_zstd(source_fd, output_fd, max_output_size,
                               input_bytes, output_bytes, err);
    }
    err = "compression: unsupported compression format";
    return false;
}

} // namespace babet::compression_stream
