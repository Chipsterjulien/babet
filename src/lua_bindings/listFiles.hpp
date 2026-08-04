#ifndef LISTFILES_HPP
#define LISTFILES_HPP

#include <lua.hpp>

/**
 * @brief Lists the regular files contained in a directory.
 *
 * Lua API: files, err = babet.listFiles(path [, recursive])
 *
 * Directory traversal is completed on the C++ side before the Lua result
 * table is built, so an allocation failure in Lua cannot bypass native
 * iterator or string destructors.
 */
int lua_listFiles(lua_State *L);

#endif // LISTFILES_HPP
