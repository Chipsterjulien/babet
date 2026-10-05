#ifndef ZIP_UTILS_HPP
#define ZIP_UTILS_HPP

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// Embedded entries are Lua source files loaded entirely in memory before
// compilation. 16 MiB is deliberately generous for source code while still
// preventing a forged ZIP metadata field from requesting an unbounded
// allocation.
inline constexpr std::size_t MAX_EMBEDDED_FILE_SIZE =
    16ull * 1024ull * 1024ull;

/**
 * @brief Creates a ZIP archive from all regular files under `dir`.
 *        Directories named .git, .svn or .hg are skipped recursively at
 *        every depth.
 *        Lua entries (*.lua) larger than MAX_EMBEDDED_FILE_SIZE are rejected
 *        before publication, including a check of the completed archive.
 * @param excludePath If non-empty, any entry equivalent to this path
 *        (same inode, symlinks resolved) is skipped — used by
 *        --create-exe so a previous build's output living inside the
 *        packaged directory is never re-embedded.
 * @return true on success.
 */
bool createZipFromDirectory(const std::string &dir, const std::string &zipFileName,
                            const std::string &excludePath = "");

/**
 * @brief Copies exe + zip into a same-directory temporary file, patches its
 *        unique bare-runtime descriptor with the archive bounds, sets mode
 *        0755 and fsyncs it, then atomically replaces output.
 * @throws std::system_error on I/O, permission, sync or rename failure.
 * @throws std::runtime_error on an absent, ambiguous or invalid descriptor.
 */
void mergeFiles(const std::string &exe, const std::string &zip,
                const std::string &output);

// Read from the loaded image, independently of the appended ZIP. The builder
// patches this descriptor in its output copy before atomic publication.
struct EmbeddedImageLayout
{
    bool generated = false;
    std::uint64_t archive_offset = 0;
    std::uint64_t archive_size = 0;
};
std::optional<EmbeddedImageLayout> runningEmbeddedImageLayout(
    std::string *error = nullptr);

/**
 * @brief Opens the zip appended to `exePath`, extracts the named entry into memory.
 * @param error Optional detailed error. It remains empty when the executable has
 *        no archive or the requested entry simply does not exist. Failure to
 *        open/read the executable and other reader errors produce a diagnostic;
 *        A supplied layout is authoritative: a bare runtime never interprets
 *        incidental ZIP bytes, and a generated image must match its bounds.
 *        Generic callers without a layout accept only a ZIP with an empty
 *        comment ending exactly at EOF (the Babet packaging convention).
 * @return The file contents, or std::nullopt on absence/failure.
 */
std::optional<std::vector<char>> readEmbeddedFile(
    const std::string &exePath,
    const std::string &archivePath,
    std::string *error = nullptr,
    const EmbeddedImageLayout *layout = nullptr);

#endif // ZIP_UTILS_HPP
