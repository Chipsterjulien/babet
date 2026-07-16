#ifndef BABET_COMPRESSION_STREAM_HPP
#define BABET_COMPRESSION_STREAM_HPP

#include <cstdint>
#include <string>
#include <string_view>

namespace babet::compression_stream
{
enum class Format
{
    gzip,
    xz,
    bzip2,
    zstd,
};

[[nodiscard]] const char *format_name(Format format) noexcept;

[[nodiscard]] bool parse_format(std::string_view value, Format &format) noexcept;

struct CompressionLevelInfo
{
    int minimum;
    int maximum;
    int default_level;
};

/** Returns the supported encoder level range and the default level. */
[[nodiscard]] CompressionLevelInfo
compression_level_info(Format format) noexcept;

/**
 * Detects a supported standalone compressed stream from its magic bytes.
 * The descriptor is not repositioned.
 */
[[nodiscard]] bool detect_format_fd(int source_fd, Format &format,
                                    std::string &err);

/**
 * Compresses the regular-file bytes available from source_fd into output_fd.
 * Both descriptors must be positioned at offset zero. The function streams
 * data and never closes either descriptor.
 */
[[nodiscard]] bool compress_fd(int source_fd, int output_fd, Format format,
                               int compression_level,
                               std::uint64_t &input_bytes,
                               std::uint64_t &output_bytes,
                               std::string &err);

/**
 * Decompresses a supported standalone compressed stream into output_fd.
 * max_output_size is enforced before each write. Both descriptors must be
 * positioned at offset zero. The function never closes either descriptor.
 */
[[nodiscard]] bool decompress_fd(int source_fd, int output_fd, Format format,
                                 std::uint64_t max_output_size,
                                 std::uint64_t &input_bytes,
                                 std::uint64_t &output_bytes,
                                 std::string &err);

} // namespace babet::compression_stream

#endif // BABET_COMPRESSION_STREAM_HPP
