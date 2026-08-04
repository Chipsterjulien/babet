#ifndef LUA_EXCEPTION_BOUNDARY_HPP
#define LUA_EXCEPTION_BOUNDARY_HPP

#include <exception>
#include <new>

struct lua_State;

enum class LuaCxxExceptionKind
{
    out_of_memory,
    standard,
    unknown
};

/**
 * Executes a lua_CFunction implementation without allowing a C++ exception
 * to cross Lua's C frames. The reporter must itself avoid throwing C++
 * exceptions; Babet's reporter only pushes literal diagnostics to Lua. The
 * caught exception is destroyed before the reporter is called, so a Lua
 * allocation failure cannot longjmp out of an active C++ exception handler.
 */
template <int (*Fn)(lua_State *), typename Reporter>
inline int invoke_lua_cfunction_with_exception_boundary(
    lua_State *L, Reporter reporter)
{
    LuaCxxExceptionKind kind = LuaCxxExceptionKind::unknown;

    try
    {
        return Fn(L);
    }
    catch (const std::bad_alloc &)
    {
        kind = LuaCxxExceptionKind::out_of_memory;
    }
    catch (const std::exception &)
    {
        kind = LuaCxxExceptionKind::standard;
    }
    catch (...)
    {
        kind = LuaCxxExceptionKind::unknown;
    }

    return reporter(L, kind);
}

#endif // LUA_EXCEPTION_BOUNDARY_HPP
