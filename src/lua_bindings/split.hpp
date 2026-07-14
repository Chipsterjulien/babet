#ifndef SPLIT_HPP
#define SPLIT_HPP

#include <lua.hpp>

/**
 * @brief Split a Lua string into a dense array of substrings.
 *
 * Lua signature:
 *   babet.split(subject [, separator [, max_splits]]) -> table
 *
 * - subject must be an actual Lua string and is handled with its exact byte
 *   length, including embedded NUL bytes.
 * - separator, when present, must be an actual Lua string containing either
 *   zero bytes (byte mode) or exactly one byte (literal separator mode).
 *   Omitting it also selects byte mode; there is no default space separator.
 * - max_splits must be a Lua integer >= -1. It limits cuts only in literal
 *   separator mode; -1 means unlimited and 0 returns the whole subject as the
 *   sole element.
 *
 * Empty fields are preserved. In byte mode, an empty subject yields an empty
 * table; with a non-empty separator, an empty subject yields { "" }.
 *
 * @param L The Lua state.
 * @return 1 (the result table).
 *
 * @throws luaL_error For invalid arity, types, separator byte length, or a
 *         max_splits value below -1.
 */
int lua_split(lua_State *L);

#endif // SPLIT_HPP
