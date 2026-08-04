#ifndef LUA_EXCEPTION_BOUNDARY_HPP
#define LUA_EXCEPTION_BOUNDARY_HPP

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <exception>
#include <new>

struct lua_State;

// Marker used after a lua_pcall-protected result builder failed. The Lua
// error object is already on the stack. It owns no resource, so it is safe to
// carry through C++ unwinding and re-raise only after all RAII owners died.
struct LuaProtectedCallFailure
{
};

struct LuaProtectedBuilderFailure
{
    static constexpr std::size_t capacity = 512;
    char message[capacity]{};

    explicit LuaProtectedBuilderFailure(const char *detail) noexcept
    {
        if (detail == nullptr)
            detail = "internal C++ failure while building Lua result";
        const std::size_t length =
            std::min(std::strlen(detail), capacity - 1);
        std::memcpy(message, detail, length);
        message[length] = '\0';
    }
};

enum class LuaCxxExceptionKind
{
    lua_error_pending,
    protected_builder_failure,
    out_of_memory,
    standard,
    unknown
};

/**
 * Executes a lua_CFunction implementation without allowing a C++ exception
 * to cross Lua's C frames. The caught exception is destroyed before the
 * reporter is called, so a Lua allocation failure cannot longjmp out of an
 * active C++ exception handler.
 */
template <int (*Fn)(lua_State *), typename Reporter>
inline int invoke_lua_cfunction_with_exception_boundary(
    lua_State *L, Reporter reporter)
{
    LuaCxxExceptionKind kind = LuaCxxExceptionKind::unknown;
    char protected_builder_message[LuaProtectedBuilderFailure::capacity]{};

    try
    {
        return Fn(L);
    }
    catch (const LuaProtectedCallFailure &)
    {
        kind = LuaCxxExceptionKind::lua_error_pending;
    }
    catch (const LuaProtectedBuilderFailure &failure)
    {
        kind = LuaCxxExceptionKind::protected_builder_failure;
        std::memcpy(protected_builder_message, failure.message,
                    sizeof(protected_builder_message));
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

    return reporter(L, kind, protected_builder_message);
}

#endif // LUA_EXCEPTION_BOUNDARY_HPP
