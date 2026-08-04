#ifndef LUA_UTILS_HPP
#define LUA_UTILS_HPP

#include "lua_exception_boundary.hpp"

#include <lua.hpp>
#include <algorithm>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>

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

    int operator()(lua_State *L, LuaCxxExceptionKind kind,
                   const char *detail) const
    {
        switch (kind)
        {
        case LuaCxxExceptionKind::lua_error_pending:
            return lua_error(L);
        case LuaCxxExceptionKind::protected_builder_failure:
            return push_fail(L, detail);
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
 * Builds Lua return values under lua_pcall.
 *
 * Owners must be created before this function. The builder and everything it
 * calls must be a pure Lua emitter: it may only refer to already-owned C++
 * values and must not construct a non-trivial owner across an allocating Lua
 * API call. LUA_ERRMEM is caught by lua_pcall, then converted to a C++ marker
 * so the caller's RAII objects are destroyed before lua_error is re-raised.
 */
enum class LuaProtectedBuilderCxxFailure
{
    none,
    out_of_memory,
    standard,
    unknown,
};

template <typename Builder>
struct LuaProtectedBuilderContext
{
    Builder *builder = nullptr;
    LuaProtectedBuilderCxxFailure failure =
        LuaProtectedBuilderCxxFailure::none;
    char message[LuaProtectedBuilderFailure::capacity]{};
};

inline void lua_copy_protected_builder_message(
    char *destination, std::size_t capacity, const char *message) noexcept
{
    if (capacity == 0)
        return;
    if (message == nullptr)
        message = "internal C++ failure while building Lua result";
    const std::size_t length = std::min(std::strlen(message), capacity - 1);
    std::memcpy(destination, message, length);
    destination[length] = '\0';
}

template <typename Builder>
inline int lua_protected_builder_thunk(lua_State *L) noexcept
{
    auto *context = static_cast<LuaProtectedBuilderContext<Builder> *>(
        lua_touserdata(L, 1));
    try
    {
        return (*context->builder)(L);
    }
    catch (const LuaProtectedBuilderFailure &failure)
    {
        context->failure = LuaProtectedBuilderCxxFailure::standard;
        lua_copy_protected_builder_message(
            context->message, sizeof(context->message), failure.message);
    }
    catch (const std::bad_alloc &)
    {
        context->failure = LuaProtectedBuilderCxxFailure::out_of_memory;
    }
    catch (const std::exception &e)
    {
        context->failure = LuaProtectedBuilderCxxFailure::standard;
        lua_copy_protected_builder_message(
            context->message, sizeof(context->message), e.what());
    }
    catch (...)
    {
        context->failure = LuaProtectedBuilderCxxFailure::unknown;
    }
    return 0;
}

template <typename Builder>
inline int lua_build_results_protected(lua_State *L, Builder &builder,
                                       int expected_results)
{
    static_assert(std::is_nothrow_destructible_v<Builder>,
                  "protected Lua result builders must be nothrow destructible");
    if (!lua_checkstack(L, 2))
        throw std::bad_alloc();

    LuaProtectedBuilderContext<Builder> context;
    context.builder = &builder;
    lua_pushcfunction(L, lua_protected_builder_thunk<Builder>);
    lua_pushlightuserdata(L, &context);
    const int status = lua_pcall(L, 1, expected_results, 0);
    if (status != LUA_OK)
        throw LuaProtectedCallFailure{};

    switch (context.failure)
    {
    case LuaProtectedBuilderCxxFailure::none:
        return expected_results;
    case LuaProtectedBuilderCxxFailure::out_of_memory:
        throw std::bad_alloc();
    case LuaProtectedBuilderCxxFailure::standard:
        throw LuaProtectedBuilderFailure(context.message);
    case LuaProtectedBuilderCxxFailure::unknown:
        throw LuaProtectedBuilderFailure(
            "unknown C++ failure while building Lua result");
    }
    throw LuaProtectedBuilderFailure(
        "invalid protected Lua builder failure state");
}

/**
 * Builds Lua return values under lua_pcall while forwarding one existing
 * stack value to the protected builder.
 *
 * The forwarded value becomes argument 2 in the builder frame because
 * argument 1 is reserved for the internal builder context. This is useful
 * when the protected operation must still inspect an original Lua value (for
 * example deepCopyTable's source table) instead of only emitting already
 * owned C++ data.
 */
template <typename Builder>
inline int lua_build_results_protected_with_stack_value(
    lua_State *L, Builder &builder, int expected_results, int value_index)
{
    static_assert(std::is_nothrow_destructible_v<Builder>,
                  "protected Lua result builders must be nothrow destructible");
    value_index = lua_absindex(L, value_index);
    if (!lua_checkstack(L, 3))
        throw std::bad_alloc();

    LuaProtectedBuilderContext<Builder> context;
    context.builder = &builder;
    lua_pushcfunction(L, lua_protected_builder_thunk<Builder>);
    lua_pushlightuserdata(L, &context);
    lua_pushvalue(L, value_index);
    const int status = lua_pcall(L, 2, expected_results, 0);
    if (status != LUA_OK)
        throw LuaProtectedCallFailure{};

    switch (context.failure)
    {
    case LuaProtectedBuilderCxxFailure::none:
        return expected_results;
    case LuaProtectedBuilderCxxFailure::out_of_memory:
        throw std::bad_alloc();
    case LuaProtectedBuilderCxxFailure::standard:
        throw LuaProtectedBuilderFailure(context.message);
    case LuaProtectedBuilderCxxFailure::unknown:
        throw LuaProtectedBuilderFailure(
            "unknown C++ failure while building Lua result");
    }
    throw LuaProtectedBuilderFailure(
        "invalid protected Lua builder failure state");
}

inline int push_fail_protected(lua_State *L, std::string_view message)
{
    auto builder = [message](lua_State *Ls) noexcept -> int
    {
        lua_pushnil(Ls);
        lua_pushlstring(Ls, message.data(), message.size());
        return 2;
    };
    return lua_build_results_protected(L, builder, 2);
}

inline int push_ok_protected(lua_State *L)
{
    auto builder = [](lua_State *Ls) noexcept -> int
    {
        lua_pushboolean(Ls, 1);
        lua_pushnil(Ls);
        return 2;
    };
    return lua_build_results_protected(L, builder, 2);
}

inline int push_string_result_protected(lua_State *L, std::string_view value)
{
    auto builder = [value](lua_State *Ls) noexcept -> int
    {
        lua_pushlstring(Ls, value.data(), value.size());
        lua_pushnil(Ls);
        return 2;
    };
    return lua_build_results_protected(L, builder, 2);
}

inline int push_string_protected(lua_State *L, std::string_view value)
{
    auto builder = [value](lua_State *Ls) noexcept -> int
    {
        lua_pushlstring(Ls, value.data(), value.size());
        return 1;
    };
    return lua_build_results_protected(L, builder, 1);
}

/**
 * Runs a Lua-stack operation under lua_pcall while its C++ outputs are owned
 * by the caller.
 *
 * Every value from the caller's current Lua frame is forwarded to the
 * protected frame, and the internal context argument is removed before the
 * operation runs. The operation therefore sees exactly the same argument
 * indices as the public binding (argument 1 remains at index 1, etc.). This
 * is essential for option/table parsers: a plain lua_pcall frame otherwise
 * contains only the internal context at index 1 and silently loses the
 * binding's original arguments.
 *
 * The operation returns no Lua results. Any temporary values it leaves in the
 * protected frame are discarded when the thunk returns 0.
 */
template <typename Operation>
inline void lua_run_protected(lua_State *L, Operation &operation)
{
    static_assert(std::is_nothrow_destructible_v<Operation>,
                  "protected Lua operations must be nothrow destructible");

    const int argument_count = lua_gettop(L);
    if (!lua_checkstack(L, argument_count + 2))
        throw std::bad_alloc();

    auto builder = [&operation](lua_State *Ls) -> int
    {
        // lua_protected_builder_thunk has already read the context pointer.
        // Remove it so the forwarded caller arguments recover their original
        // 1-based indices before the parser/operation inspects the stack.
        lua_rotate(Ls, 1, -1);
        lua_pop(Ls, 1);
        operation(Ls);
        return 0;
    };

    LuaProtectedBuilderContext<decltype(builder)> context;
    context.builder = &builder;
    lua_pushcfunction(L, lua_protected_builder_thunk<decltype(builder)>);
    lua_pushlightuserdata(L, &context);
    for (int index = 1; index <= argument_count; ++index)
        lua_pushvalue(L, index);

    const int status = lua_pcall(L, argument_count + 1, 0, 0);
    if (status != LUA_OK)
        throw LuaProtectedCallFailure{};

    switch (context.failure)
    {
    case LuaProtectedBuilderCxxFailure::none:
        return;
    case LuaProtectedBuilderCxxFailure::out_of_memory:
        throw std::bad_alloc();
    case LuaProtectedBuilderCxxFailure::standard:
        throw LuaProtectedBuilderFailure(context.message);
    case LuaProtectedBuilderCxxFailure::unknown:
        throw LuaProtectedBuilderFailure(
            "unknown C++ failure while running protected Lua operation");
    }
    throw LuaProtectedBuilderFailure(
        "invalid protected Lua operation failure state");
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

inline int push_action_result_protected(
    lua_State *L, const std::optional<std::string> &error)
{
    if (error)
    {
        return push_fail_protected(L, *error);
    }
    return push_ok_protected(L);
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
 * Runs a Lua-state setup phase under lua_pcall and turns a Lua allocation
 * failure into a normal C++-owned diagnostic after the protected-call marker
 * has been destroyed. The operation may capture C++ owners from the caller,
 * but it must not construct a non-trivial local owner around an allocating
 * Lua API call.
 */
template <typename Operation>
inline bool lua_run_setup_protected(
    lua_State *L, Operation &operation,
    std::string_view label, std::string &error)
{
    enum class Failure
    {
        none,
        lua,
        builder,
    };

    Failure failure = Failure::none;
    char builder_message[LuaProtectedBuilderFailure::capacity]{};
    try
    {
        lua_run_protected(L, operation);
    }
    catch (const LuaProtectedCallFailure &)
    {
        // Keep the Lua error object on the stack and defer every allocation
        // until the marker has left this catch scope.
        failure = Failure::lua;
    }
    catch (const LuaProtectedBuilderFailure &caught)
    {
        std::memcpy(builder_message, caught.message,
                    sizeof(builder_message));
        failure = Failure::builder;
    }

    if (failure == Failure::none)
    {
        return true;
    }

    error.assign(label.data(), label.size());
    error += ": ";
    if (failure == Failure::lua)
    {
        error += lua_value_to_display_string(L, -1);
        lua_pop(L, 1);
    }
    else
    {
        error += builder_message[0] != '\0'
                     ? builder_message
                     : "internal Lua setup failure";
    }
    return false;
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
