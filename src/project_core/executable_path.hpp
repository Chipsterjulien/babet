#ifndef EXECUTABLE_PATH_HPP
#define EXECUTABLE_PATH_HPP

#include <string>
#include <stdexcept>

/**
 * @brief Gets the path of the currently running executable.
 *
 * This function reads the symbolic link /proc/self/exe to determine the path of the currently running executable.
 *
 * @return The path of the currently running executable.
 * @throws std::runtime_error if the executable path cannot be read.
 */
std::string getExecutablePath();

// Open this magic link directly when reading executable bytes. The path
// returned by getExecutablePath() is only a presentation/location path:
// after rename/unlink it can name a different inode or no longer exist.
// Linux keeps /proc/self/exe attached to the running image, including in
// worker threads. Do not canonicalize it before opening it.
inline constexpr const char *RUNNING_EXECUTABLE_CONTENT = "/proc/self/exe";

/**
 * @brief Gets the directory of the currently running executable.
 *
 * This function uses getExecutablePath to determine the directory containing the executable.
 *
 * @return The directory containing the currently running executable.
 */
std::string getExecutableDirectory();

#endif // EXECUTABLE_PATH_HPP
