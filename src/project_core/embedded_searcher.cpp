#include "embedded_searcher.hpp"
#include "embedded_lua.hpp"
#include "zip_utils.hpp"
#include "../lua_bindings/lua_utils.hpp"
#include <algorithm>
#include <cstring>
#include <string>
#include <optional>
#include <vector>

static int embedded_read_error_loader(lua_State *L)
{
    const char *message = lua_tostring(L, lua_upvalueindex(1));
    return luaL_error(L, "%s", message ? message : "embedded file read error");
}

static int embedded_lua_searcher_impl(lua_State *L)
{
    size_t module_len = 0;
    const char *moduleName = luaL_checklstring(L, 1, &module_len);
    const char *exePath = luaL_checkstring(L, lua_upvalueindex(1));
    if (std::memchr(moduleName, '\0', module_len) != nullptr)
    {
        lua_pushliteral(L, "\n\tembedded module name contains NUL byte");
        return 1;
    }

    // All allocating Lua operations below run under a protected builder.
    // A Lua longjmp becomes a C++ marker: buffers and strings unwind before
    // the searcher's exception boundary re-raises the original Lua error.
    // Merely putting the owners in a scope before lua_error is insufficient:
    // lua_pushlstring/lua_pushcclosure can themselves raise LUA_ERRMEM.

    // "foo.bar" -> "foo/bar"
    std::string base(moduleName, module_len);
    std::replace(base.begin(), base.end(), '.', '/');

    // Standard Lua order: foo/bar.lua, then foo/bar/init.lua.
    const std::string candidates[] = {
        base + ".lua",
        base + "/init.lua",
    };

    std::string tried;

    for (const auto &path : candidates)
    {
        std::string read_error;
        auto data = readEmbeddedFile(exePath, path, &read_error);
        if (!read_error.empty())
        {
            // A broken entry must stop require(), never fall through to a
            // same-named disk module. Preserve the existing error loader.
            auto builder = [&](lua_State *state) noexcept -> int
            {
                lua_pushlstring(state, read_error.data(), read_error.size());
                lua_pushcclosure(state, embedded_read_error_loader, 1);
                lua_pushlstring(state, path.data(), path.size());
                return 2;
            };
            return lua_build_results_protected(L, builder, 2);
        }
        if (data)
        {
            auto builder = [&](lua_State *state) noexcept -> int
            {
                if (load_embedded_lua(state, data->data(), data->size(),
                                      path.c_str()) != LUA_OK)
                    return lua_error(state);
                lua_pushlstring(state, path.data(), path.size());
                return 2;
            };
            return lua_build_results_protected(L, builder, 2);
        }
        tried += "\n\tno embedded file '" + path + "'";
    }

    return push_string_protected(L, tried);
}

struct EmbeddedSearcherExceptionReporter
{
    int operator()(lua_State *L, LuaCxxExceptionKind kind,
                   const char *detail) const
    {
        if (kind == LuaCxxExceptionKind::lua_error_pending)
            return lua_error(L);
        if (kind == LuaCxxExceptionKind::out_of_memory)
            lua_pushliteral(L, "embedded module loader: out of memory");
        else if (kind == LuaCxxExceptionKind::protected_builder_failure)
            lua_pushstring(L, detail);
        else
            lua_pushliteral(L, "embedded module loader: internal C++ failure");
        // Report after C++ exception destruction, and stop require() rather
        // than treating a native failure as an absent embedded module.
        return lua_error(L);
    }
};

static int embedded_lua_searcher(lua_State *L)
{
    return invoke_lua_cfunction_with_exception_boundary<embedded_lua_searcher_impl>(
        L, EmbeddedSearcherExceptionReporter{});
}

void register_embedded_searcher(lua_State *L, const char *exePath)
{
    lua_getglobal(L, "package");      // [package]
    lua_getfield(L, -1, "searchers"); // [package, searchers]

    int len = static_cast<int>(lua_rawlen(L, -1));

    // Décale les searchers existants d'un cran à partir de l'index 2,
    // pour libérer la place 2 (après package.preload qui reste en 1).
    for (int i = len; i >= 2; --i)
    {
        lua_rawgeti(L, -1, i);
        lua_rawseti(L, -2, i + 1);
    }

    lua_pushstring(L, exePath);
    lua_pushcclosure(L, embedded_lua_searcher, 1); // upvalue = exePath
    lua_rawseti(L, -2, 2);

    lua_pop(L, 2); // [package, searchers] → []
}
