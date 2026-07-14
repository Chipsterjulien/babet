#ifndef MERGE_TABLES_HPP
#define MERGE_TABLES_HPP

#include <lua.hpp>

/**
 * Lua binding for merging multiple tables.
 * @param L The Lua state.
 * @return Number of return values (1: the newly merged table).
 * Lua usage: mergedTable = babet.mergeTables(table1, table2, ...)
 */
int lua_mergeTables(lua_State *L);

#endif // MERGE_TABLES_HPP
