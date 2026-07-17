#ifndef WRITEFILEATOMIC_HPP
#define WRITEFILEATOMIC_HPP

#include <lua.hpp>

/**
 * Lua binding for:
 *   ok, err = babet.writeFileAtomic(path, data [, opts])
 */
int lua_writeFileAtomic(lua_State *L);

#endif // WRITEFILEATOMIC_HPP
