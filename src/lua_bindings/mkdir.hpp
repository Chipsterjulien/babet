#ifndef MKDIR_HPP
#define MKDIR_HPP

#include <string>
#include <optional>
#include <lua.hpp>

/**
 * @brief Create a directory path.
 *
 * This function attempts to create the specified directory path. If the directory already exists
 * and ignore_if_exists is true, no error is returned.
 *
 * @param path The directory path to create.
 * @param ignore_if_exists If true, does not return an error if the directory already exists.
 * @return std::optional<std::string> An error message if present, or std::nullopt if successful.
 */
std::optional<std::string> create_directory(const std::string &path, bool ignore_if_exists);

/**
 * @brief Lua binding for creating a directory path.
 *
 * This function can be called from Lua to create a directory. It returns nil if successful,
 * or an error message if it fails.
 *
 * Lua usage: error_message = lua_mkdir(path, ignore_if_exists)
 *
 * @param L The Lua state.
 * @return int Number of return values (1: error message or nil).
 */
int lua_mkdir(lua_State *L);

#endif // MKDIR_HPP