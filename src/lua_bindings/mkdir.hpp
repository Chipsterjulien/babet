#ifndef MKDIR_HPP
#define MKDIR_HPP

#include <lua.hpp>
#include <optional>
#include <string>

/**
 * @brief Recursively create a directory path.
 *
 * Existing directories are accepted (mkdir -p semantics). If a regular file
 * or another non-directory entry blocks the path, an error is returned.
 *
 * @param path Directory path to create.
 * @return An error message on failure, or std::nullopt on success.
 */
std::optional<std::string> create_directory(const std::string &path);

/**
 * @brief Lua binding for recursive, idempotent directory creation.
 *
 * Lua usage: ok, err = babet.mkdir(path)
 *
 * @param L Lua state.
 * @return Two values: true/nil on success, nil/error on failure.
 */
int lua_mkdir(lua_State *L);

#endif // MKDIR_HPP
