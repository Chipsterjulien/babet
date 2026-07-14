#include "mergeTables.hpp"

#include <limits>

/**
 * Lua binding for merging multiple tables.
 *
 * Stable numeric-key contract:
 *   - every positive integer key is treated as a list element;
 *   - sparse keys are visited in ascending numeric order and compacted into
 *     the result;
 *   - all other keys (strings, floats, zero and negative integers) keep their
 *     key, with later tables overwriting earlier ones.
 *
 * This avoids luaL_len's undefined-border behaviour on sparse tables, which
 * previously made the result depend on Lua's internal table layout.
 *
 * The ascending traversal deliberately uses repeated lua_next scans instead
 * of a C++ vector. Lua allocation failures use longjmp; keeping a heap-owning
 * C++ container alive across lua_rawseti could therefore skip its destructor.
 * The O(n²) scan is acceptable for a small table helper and keeps the binding
 * longjmp-safe.
 */
int lua_mergeTables(lua_State *L)
{
    const int argument_count = lua_gettop(L);
    if (argument_count < 2)
    {
        return luaL_error(L, "Expected at least two tables as arguments");
    }

    for (int i = 1; i <= argument_count; ++i)
    {
        if (!lua_istable(L, i))
        {
            return luaL_error(L, "Expected all arguments to be tables");
        }
    }

    lua_newtable(L);
    const int result_index = lua_absindex(L, -1);
    lua_Integer next_index = 1;

    for (int argument = 1; argument <= argument_count; ++argument)
    {
        const int source_index = lua_absindex(L, argument);
        lua_Integer previous_key = 0;

        // Append positive integer keys in a deterministic ascending order.
        for (;;)
        {
            bool found = false;
            lua_Integer selected_key =
                std::numeric_limits<lua_Integer>::max();

            lua_pushnil(L);
            while (lua_next(L, source_index) != 0)
            {
                if (lua_isinteger(L, -2))
                {
                    const lua_Integer key = lua_tointeger(L, -2);
                    if (key >= 1 && key > previous_key &&
                        (!found || key < selected_key))
                    {
                        selected_key = key;
                        found = true;
                    }
                }
                lua_pop(L, 1); // value; keep key for lua_next
            }

            if (!found)
            {
                break;
            }

            lua_rawgeti(L, source_index, selected_key);
            lua_rawseti(L, result_index, next_index++);
            previous_key = selected_key;
        }

        // Map-like keys: all non-positive-integer keys retain their key and
        // normal last-writer-wins semantics.
        lua_pushnil(L);
        while (lua_next(L, source_index) != 0)
        {
            bool appended_numeric_key = false;
            if (lua_isinteger(L, -2))
            {
                appended_numeric_key = lua_tointeger(L, -2) >= 1;
            }

            if (appended_numeric_key)
            {
                lua_pop(L, 1); // value; keep key
                continue;
            }

            lua_pushvalue(L, -2);       // duplicate key
            lua_pushvalue(L, -2);       // duplicate value
            lua_settable(L, result_index);
            lua_pop(L, 1);              // original value; keep key
        }
    }

    return 1;
}
