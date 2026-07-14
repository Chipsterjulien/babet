#ifndef COPYTREE_HPP
#define COPYTREE_HPP

#include <filesystem>
#include <lua.hpp>
#include <optional>
#include <string>

/**
 * @brief Recursively copy a directory tree.
 *
 * Directories, regular files, and symbolic links are handled explicitly.
 * Destination writes are confined by SecureDestination. Per-entry failures
 * either stop immediately or are reported as warnings while other entries
 * continue.
 *
 * @param source Source directory. The root itself must not be a symlink.
 * @param destination Destination directory. The root must not be a symlink.
 * @param continue_on_error Continue after per-entry errors. Defaults to true.
 * @return An error/warning summary on failure, or std::nullopt on full success.
 */
std::optional<std::string>
copy_directory(const std::filesystem::path &source,
               const std::filesystem::path &destination,
               bool continue_on_error = true);

/**
 * @brief Lua binding for recursive directory copying.
 *
 * Lua usage:
 *   ok, err = babet.copyTree(source, destination)
 *   ok, err = babet.copyTree(source, destination, continue_on_error)
 *
 * The optional third argument defaults to true.
 *
 * @param L Lua state.
 * @return Two values: true/nil on complete success, nil/error otherwise.
 */
int lua_copyTree(lua_State *L);

#endif // COPYTREE_HPP
