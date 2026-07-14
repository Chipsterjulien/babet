#ifndef ZIP_UTILS_HPP
#define ZIP_UTILS_HPP

#include <cstddef>
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
 * @param excludePath If non-empty, any entry equivalent to this path
 *        (same inode, symlinks resolved) is skipped — used by
 *        --create-exe so a previous build's output living inside the
 *        packaged directory is never re-embedded.
 * @return true on success.
 */
bool createZipFromDirectory(const std::string &dir, const std::string &zipFileName,
                            const std::string &excludePath = "");

/**
 * @brief Concatenates exe + zip into a same-directory temporary file,
 *        fsyncs it, sets mode 0755, then atomically replaces output.
 * @throws std::system_error on I/O, permission, sync or rename failure.
 */
void mergeFiles(const std::string &exe, const std::string &zip,
                const std::string &output);

/**
 * @brief Opens the zip appended to `exePath`, extracts the named entry into memory.
 * @param error Optional detailed error. It remains empty when the executable has
 *        no readable archive or the requested entry simply does not exist.
 * @return The file contents, or std::nullopt on absence/failure.
 */
std::optional<std::vector<char>> readEmbeddedFile(
    const std::string &exePath,
    const std::string &archivePath,
    std::string *error = nullptr);

#endif // ZIP_UTILS_HPP
