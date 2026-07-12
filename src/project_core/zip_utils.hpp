#ifndef ZIP_UTILS_HPP
#define ZIP_UTILS_HPP

#include <optional>
#include <string>
#include <vector>

/**
 * @brief Creates a ZIP archive from all regular files under `dir`.
 * @param excludePath If non-empty, any entry equivalent to this path
 *        (same inode, symlinks resolved) is skipped — used by
 *        --create-exe so a previous build's output living inside the
 *        packaged directory is never re-embedded.
 * @return true on success.
 */
bool createZipFromDirectory(const std::string &dir, const std::string &zipFileName,
                            const std::string &excludePath = "");

/**
 * @brief Concatenates exe + zip into output.
 * @throws std::system_error on I/O failure.
 */
void mergeFiles(const std::string &exe, const std::string &zip, const std::string &output);

/**
 * @brief Opens the zip appended to `exePath`, extracts the named entry into memory.
 *        This function is silent: callers are responsible for reporting failures.
 * @return The file contents, or std::nullopt on failure.
 */
std::optional<std::vector<char>> readEmbeddedFile(const std::string &exePath,
                                                  const std::string &archivePath);

#endif // ZIP_UTILS_HPP
