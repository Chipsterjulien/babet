#ifndef LUA_UTILS_HPP
#define LUA_UTILS_HPP

#include "lua_exception_boundary.hpp"

#include <lua.hpp>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>

/**
 * Small, allocation-free predicates shared by public Lua bindings.
 *
 * Lua's convenience checks are sometimes deliberately permissive:
 * lua_isstring() accepts numbers and lua_toboolean() accepts every value.
 * Babet's documented contracts use strict Lua types instead, so bindings
 * should use these helpers before converting a value.  They never raise a
 * Lua error and are therefore safe to call while C++ objects are alive.
 */
inline bool lua_arity_is(lua_State *L, int expected) noexcept
{
    return lua_gettop(L) == expected;
}

inline bool lua_arity_between(lua_State *L, int minimum, int maximum) noexcept
{
    const int argc = lua_gettop(L);
    return argc >= minimum && argc <= maximum;
}

inline bool lua_is_none_or_nil(lua_State *L, int idx) noexcept
{
    return lua_isnoneornil(L, idx) != 0;
}

inline bool lua_is_strict_string(lua_State *L, int idx) noexcept
{
    return lua_type(L, idx) == LUA_TSTRING;
}

inline bool lua_is_strict_number(lua_State *L, int idx) noexcept
{
    return lua_type(L, idx) == LUA_TNUMBER;
}

inline bool lua_is_strict_integer(lua_State *L, int idx) noexcept
{
    return lua_isinteger(L, idx) != 0;
}

inline bool lua_is_strict_boolean(lua_State *L, int idx) noexcept
{
    return lua_type(L, idx) == LUA_TBOOLEAN;
}

inline bool lua_is_optional_strict_string(lua_State *L, int idx) noexcept
{
    return lua_is_none_or_nil(L, idx) || lua_is_strict_string(L, idx);
}

inline bool lua_is_optional_strict_number(lua_State *L, int idx) noexcept
{
    return lua_is_none_or_nil(L, idx) || lua_is_strict_number(L, idx);
}

inline bool lua_is_optional_strict_integer(lua_State *L, int idx) noexcept
{
    return lua_is_none_or_nil(L, idx) || lua_is_strict_integer(L, idx);
}

inline bool lua_is_optional_strict_boolean(lua_State *L, int idx) noexcept
{
    return lua_is_none_or_nil(L, idx) || lua_is_strict_boolean(L, idx);
}

/**
 * @brief Pushes a single error message on the stack (legacy 1-return).
 * @return 1
 */
inline int push_error(lua_State *L, const std::string &message)
{
    lua_pushstring(L, message.c_str());
    return 1;
}

/**
 * @brief Pushes (true, nil) on the stack for an action that succeeded.
 * @return 2
 */
inline int push_ok(lua_State *L)
{
    lua_pushboolean(L, 1);
    lua_pushnil(L);
    return 2;
}

/**
 * @brief Pushes (nil, "err") on the stack for any failure.
 * @return 2
 */
inline int push_fail(lua_State *L, std::string_view message)
{
    lua_pushnil(L);
    lua_pushlstring(L, message.data(), message.size());
    return 2;
}

/**
 * @brief Prevents a C++ exception from crossing a lua_CFunction boundary.
 *
 * Lua is compiled as C in Babet. Letting a C++ exception escape through its C
 * frames is undefined behaviour, so every public binding that can allocate or
 * call throwing C++ code must enter Lua through this helper. The diagnostic
 * strings are supplied as non-owning views and the handlers perform no C++
 * allocation of their own.
 *
 * Programmer errors raised by luaL_error still follow Lua's protected-call
 * path; they are not C++ exceptions and are deliberately not translated here.
 */
struct LuaCfunctionExceptionReporter
{
    std::string_view out_of_memory;
    std::string_view internal_failure;
    std::string_view unknown_internal_failure;

    int operator()(lua_State *L, LuaCxxExceptionKind kind) const
    {
        switch (kind)
        {
        case LuaCxxExceptionKind::out_of_memory:
            return push_fail(L, out_of_memory);
        case LuaCxxExceptionKind::standard:
            return push_fail(L, internal_failure);
        case LuaCxxExceptionKind::unknown:
            return push_fail(L, unknown_internal_failure);
        }
        return push_fail(L, unknown_internal_failure);
    }
};

template <int (*Fn)(lua_State *)>
inline int lua_cfunction_exception_boundary(
    lua_State *L, std::string_view out_of_memory,
    std::string_view internal_failure,
    std::string_view unknown_internal_failure)
{
    return invoke_lua_cfunction_with_exception_boundary<Fn>(
        L, LuaCfunctionExceptionReporter{out_of_memory, internal_failure,
                                        unknown_internal_failure});
}

/**
 * @brief Convenience: takes an optional error from a C++ function and converts to (ok, err) Lua return.
 *        If `error` has a value, returns (nil, *error). Otherwise returns (true, nil).
 */
inline int push_action_result(lua_State *L, const std::optional<std::string> &error)
{
    if (error)
    {
        return push_fail(L, *error);
    }
    return push_ok(L);
}

// Protected wrapper around luaL_tolstring. Error objects in Lua may be any
// value (`error({code = 42})` is legal), and calling lua_tostring directly
// returns nullptr for tables/functions/userdata. luaL_tolstring provides the
// usual `table: 0x...` representation and honours __tostring; the pcall in
// lua_value_to_display_string prevents a broken __tostring metamethod from
// replacing the original diagnostic with another unhandled Lua error.
inline int lua_value_to_display_string_impl(lua_State *L)
{
    luaL_tolstring(L, 1, nullptr);
    return 1;
}

inline std::string lua_value_to_display_string(lua_State *L, int idx)
{
    idx = lua_absindex(L, idx);

    lua_pushcfunction(L, lua_value_to_display_string_impl);
    lua_pushvalue(L, idx);
    if (lua_pcall(L, 1, 1, 0) == LUA_OK)
    {
        size_t len = 0;
        const char *data = lua_tolstring(L, -1, &len);
        std::string result = data ? std::string(data, len)
                                  : std::string("<unprintable Lua value>");
        lua_pop(L, 1);
        return result;
    }

    // Pop the secondary __tostring failure and retain a deterministic
    // description of the original error object's type.
    lua_pop(L, 1);
    std::string result = "<Lua error object of type ";
    result += luaL_typename(L, idx);
    result += ">";
    return result;
}

/**
 * @brief Copies a Lua string without losing embedded bytes and rejects NUL.
 *
 * Many POSIX/OpenSSL/SQLite APIs consume NUL-terminated C strings. Passing a
 * Lua string through lua_tostring() would silently truncate it at the first
 * embedded NUL. The helper validates the strict Lua string type itself before
 * forwarding the value to a C-string API.
 *
 * @param label User-facing field name used in the error message.
 * @return true on success; false with `err` filled for a wrong type or a NUL byte.
 */
inline bool lua_string_without_nul(lua_State *L, int idx,
                                   std::string &out,
                                   std::string_view label,
                                   std::string &err)
{
    if (!lua_is_strict_string(L, idx))
    {
        err.assign(label);
        err += " must be a string";
        return false;
    }

    size_t len = 0;
    const char *data = lua_tolstring(L, idx, &len);
    if (std::memchr(data, '\0', len) != nullptr)
    {
        err.assign(label);
        err += " must not contain NUL byte";
        return false;
    }
    out.assign(data, len);
    return true;
}

/**
 * @brief Strict string checker for APIs that already use luaL_checkstring.
 *
 * Wrong types and embedded NUL bytes are programmer errors and therefore
 * raise a Lua error, matching luaL_checkstring's existing contract. The NUL
 * check happens before any std::string object is constructed, so the Lua
 * longjmp does not bypass a C++ destructor in this helper.
 */
inline std::string_view luaL_checkstring_view_without_nul(
    lua_State *L, int idx, const char *label)
{
    if (!lua_is_strict_string(L, idx))
    {
        luaL_typeerror(L, idx, "string");
        return {};
    }

    size_t len = 0;
    const char *data = lua_tolstring(L, idx, &len);
    if (std::memchr(data, '\0', len) != nullptr)
    {
        luaL_error(L, "%s must not contain NUL byte", label);
        return {};
    }
    return std::string_view(data, len);
}

inline std::string luaL_checkstring_without_nul(lua_State *L, int idx,
                                                const char *label)
{
    const std::string_view value =
        luaL_checkstring_view_without_nul(L, idx, label);
    return std::string(value);
}

#endif // LUA_UTILS_HPP
