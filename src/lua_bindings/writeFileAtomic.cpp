#include "writeFileAtomic.hpp"

#include "lua_utils.hpp"
#include "project_core/atomic_file.hpp"

#include <cstddef>
#include <new>
#include <string>
#include <string_view>

namespace
{
void raw_getfield(lua_State *L, int index, const char *name)
{
    index = lua_absindex(L, index);
    lua_pushstring(L, name);
    lua_rawget(L, index);
}

void validate_option_keys(lua_State *L, int index)
{
    index = lua_absindex(L, index);
    lua_pushnil(L);
    while (lua_next(L, index) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 2);
            luaL_error(L,
                       "babet.writeFileAtomic: option keys must be strings");
            return;
        }

        std::size_t length = 0;
        const char *data = lua_tolstring(L, -2, &length);
        const std::string_view key(data, length);
        if (key != "overwrite" && key != "permissions" &&
            key != "durable")
        {
            lua_pop(L, 2);
            luaL_error(L,
                       "babet.writeFileAtomic: unknown option '%.*s'",
                       static_cast<int>(length), data);
            return;
        }
        lua_pop(L, 1);
    }
}

bool read_boolean_option(lua_State *L, int opts_index, const char *name,
                         bool default_value)
{
    raw_getfield(L, opts_index, name);
    if (lua_isnil(L, -1))
    {
        lua_pop(L, 1);
        return default_value;
    }
    if (!lua_is_strict_boolean(L, -1))
    {
        lua_pop(L, 1);
        luaL_error(L,
                   "babet.writeFileAtomic: opts.%s must be a boolean", name);
        return default_value;
    }
    const bool value = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    return value;
}

babet_atomic_file::Options parse_options(lua_State *L)
{
    babet_atomic_file::Options options;
    if (lua_gettop(L) == 2 || lua_isnil(L, 3))
    {
        return options;
    }
    if (!lua_istable(L, 3))
    {
        luaL_typeerror(L, 3, "table");
        return options;
    }

    validate_option_keys(L, 3);
    options.overwrite = read_boolean_option(L, 3, "overwrite", false);
    options.durable = read_boolean_option(L, 3, "durable", true);

    raw_getfield(L, 3, "permissions");
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_integer(L, -1))
        {
            lua_pop(L, 1);
            luaL_error(
                L,
                "babet.writeFileAtomic: opts.permissions must be an integer "
                "between 0 and 0777");
            return options;
        }
        const lua_Integer value = lua_tointeger(L, -1);
        if (value < 0 || value > 0777)
        {
            lua_pop(L, 1);
            luaL_error(
                L,
                "babet.writeFileAtomic: opts.permissions must be between 0 "
                "and 0777");
            return options;
        }
        options.permissions = static_cast<mode_t>(value);
    }
    lua_pop(L, 1);
    return options;
}
} // namespace

int lua_writeFileAtomic(lua_State *L)
{
    if (!lua_arity_between(L, 2, 3))
    {
        return luaL_error(
            L,
            "babet.writeFileAtomic expects two or three arguments");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_typeerror(L, 1, "string");
    }
    if (!lua_is_strict_string(L, 2))
    {
        return luaL_typeerror(L, 2, "string");
    }

    const babet_atomic_file::Options options = parse_options(L);
    const std::string_view path_view =
        luaL_checkstring_view_without_nul(L, 1, "path");
    std::size_t data_size = 0;
    const char *data = lua_tolstring(L, 2, &data_size);

    try
    {
        const std::string path(path_view);
        std::string error;
        if (!babet_atomic_file::write_file_atomic(
                path, std::string_view(data, data_size), options, error))
        {
            return push_fail_protected(L, error);
        }
        return push_ok(L);
    }
    catch (const std::bad_alloc &)
    {
        return push_fail_protected(L, "writeFileAtomic: out of memory");
    }
    catch (...)
    {
        return push_fail_protected(L, "writeFileAtomic: unexpected internal error");
    }
}
