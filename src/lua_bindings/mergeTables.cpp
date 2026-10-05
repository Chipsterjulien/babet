#include "mergeTables.hpp"
#include "lua_utils.hpp"

#include <cstddef>
#include <cstring>
#include <limits>
#include <new>

namespace
{
// This storage belongs to Lua, including if a later Lua allocation longjmps.
// No C++ container or destructor must survive across an allocating Lua call.
lua_Integer *new_key_buffer(lua_State *L, std::size_t capacity)
{
    constexpr std::size_t maximum =
        static_cast<std::size_t>(std::numeric_limits<std::ptrdiff_t>::max()) /
        sizeof(lua_Integer);
    if (capacity > maximum)
        luaL_error(L, "mergeTables: too many positive integer keys");
    void *memory = lua_newuserdatauv(L, capacity * sizeof(lua_Integer), 0);
    return new (memory) lua_Integer[capacity];
}

void sift_down(lua_Integer *keys, std::size_t root, std::size_t count) noexcept
{
    while (root < count / 2)
    {
        std::size_t child = root * 2 + 1;
        if (child + 1 < count && keys[child] < keys[child + 1]) ++child;
        if (keys[root] >= keys[child]) return;
        const lua_Integer value = keys[root];
        keys[root] = keys[child];
        keys[child] = value;
        root = child;
    }
}

// In-place heapsort: bounded O(k log k), no allocation, recursion or Lua calls.
void sort_keys(lua_Integer *keys, std::size_t count) noexcept
{
    for (std::size_t root = count / 2; root > 0; --root)
        sift_down(keys, root - 1, count);
    for (std::size_t end = count; end > 1; --end)
    {
        const lua_Integer value = keys[0];
        keys[0] = keys[end - 1];
        keys[end - 1] = value;
        sift_down(keys, 0, end - 1);
    }
}

void append_value(lua_State *L, int result, lua_Integer &last_index)
{
    if (last_index == LUA_MAXINTEGER)
        luaL_error(L, "mergeTables: too many result elements");
    lua_rawseti(L, result, ++last_index);
}
}

// Positive integer keys are sorted per source and appended compactly. Other
// keys keep last-writer-wins semantics. All reads are raw; source metatables
// and Lua's ambiguous length border for sparse tables are irrelevant.
int lua_mergeTables(lua_State *L)
{
    const int argument_count = lua_gettop(L);
    if (argument_count < 2)
        return luaL_error(L, "Expected at least two tables as arguments");
    for (int i = 1; i <= argument_count; ++i)
        if (!lua_istable(L, i))
            return luaL_error(L, "Expected all arguments to be tables");

    lua_newtable(L);
    const int result_index = lua_absindex(L, -1);
    lua_Integer last_index = 0;
    for (int source = 1; source <= argument_count; ++source)
    {
        std::size_t positive_count = 0;
        lua_Integer maximum_key = 0;
        lua_pushnil(L);
        while (lua_next(L, source) != 0)
        {
            if (lua_is_strict_integer(L, -2))
            {
                const lua_Integer key = lua_tointeger(L, -2);
                if (key > 0)
                {
                    ++positive_count;
                    if (key > maximum_key) maximum_key = key;
                }
            }
            lua_pop(L, 1);
        }

        // Unique positive integers with maximum == count are exactly 1..n.
        // Compare without narrowing a 64-bit Lua key to size_t on ARM32.
        if (positive_count <= static_cast<lua_Unsigned>(LUA_MAXINTEGER) &&
            maximum_key == static_cast<lua_Integer>(positive_count))
        {
            for (std::size_t i = 0; i < positive_count; ++i)
            {
                lua_rawgeti(L, source, static_cast<lua_Integer>(i) + 1);
                append_value(L, result_index, last_index);
            }
        }
        else
        {
            std::size_t capacity = positive_count;
            lua_Integer *keys = new_key_buffer(L, capacity);
            const int buffer_index = lua_absindex(L, -1);
            std::size_t count = 0;
            lua_pushnil(L);
            while (lua_next(L, source) != 0)
            {
                if (lua_is_strict_integer(L, -2) && lua_tointeger(L, -2) > 0)
                {
                    if (count == capacity)
                    {
                        // Allocating the userdata can run a Lua finalizer
                        // that changes the source. Never overrun the estimate.
                        constexpr std::size_t maximum =
                            static_cast<std::size_t>(std::numeric_limits<std::ptrdiff_t>::max()) /
                            sizeof(lua_Integer);
                        if (capacity == maximum)
                            return luaL_error(L, "mergeTables: too many positive integer keys");
                        const std::size_t next_capacity =
                            capacity > maximum / 2 ? maximum : capacity * 2;
                        lua_Integer *next = new_key_buffer(L, next_capacity);
                        std::memcpy(next, keys, count * sizeof(lua_Integer));
                        lua_replace(L, buffer_index);
                        keys = next;
                        capacity = next_capacity;
                    }
                    keys[count++] = lua_tointeger(L, -2);
                }
                lua_pop(L, 1);
            }
            sort_keys(keys, count);
            for (std::size_t i = 0; i < count; ++i)
            {
                lua_rawgeti(L, source, keys[i]);
                append_value(L, result_index, last_index);
            }
            lua_pop(L, 1); // release the temporary key buffer to Lua's GC
        }

        lua_pushnil(L);
        while (lua_next(L, source) != 0)
        {
            if (!lua_is_strict_integer(L, -2) || lua_tointeger(L, -2) <= 0)
            {
                lua_pushvalue(L, -2);
                lua_pushvalue(L, -2);
                lua_rawset(L, result_index);
            }
            lua_pop(L, 1);
        }
    }
    return 1;
}
