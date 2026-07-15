#ifndef ATTRIBUTES_HPP
#define ATTRIBUTES_HPP

#include <lua.hpp>

/**
 * Lua binding for babet.setAttributes(path, uid, gid [, mode]).
 *
 * The resolved target is followed once and pinned for owner/group, optional
 * mode, and rollback operations.
 *
 * @param L The Lua state.
 * @return Two Lua values: (true, nil) on success or (nil, error) on failure.
 */
int lua_setattr(lua_State *L);

/**
 * Lua binding for babet.getAttributes(path).
 *
 * @param L The Lua state.
 * @return Two Lua values: (attributes, nil) or (nil, error).
 */
int lua_getattr(lua_State *L);

#endif // ATTRIBUTES_HPP
