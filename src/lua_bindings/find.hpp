#ifndef FIND_HPP
#define FIND_HPP

#include <lua.hpp>

/**
 * @brief Lua binding for the find function.
 *
 * Expected Lua signature: results, err = babet.find(rootPath, options)
 *   - rootPath: string
 *   - options:  table { mindepth, maxdepth, type, name, iname, path,
 *                    glob, iglob, path_glob, path_iglob, xdev }
 */
int lua_find(lua_State *L);

#endif // FIND_HPP