#ifndef FILEEXISTS_HPP
#define FILEEXISTS_HPP

#include <lua.hpp>

/**
 * @brief Lua binding for checking if a path is an existing regular file.
 *
 * Lua usage: exists, err = babet.fileExists(path)
 *   - exists = true   : path is an existing regular file
 *   - exists = false  : path does not exist, or is not a regular file
 *   - exists = nil    : a filesystem error occurred (err holds the message)
 */
int lua_fileExists(lua_State *L);

int lua_exists(lua_State*);
#endif // FILEEXISTS_HPP
