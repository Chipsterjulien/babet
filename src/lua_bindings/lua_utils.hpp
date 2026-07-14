#ifndef LUA_UTILS_HPP
#define LUA_UTILS_HPP

#include <lua.hpp>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>

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
 * embedded NUL. Callers must first validate the Lua type themselves, then use
 * this helper before forwarding the value to a C-string API.
 *
 * @param label User-facing field name used in the error message.
 * @return true on success; false with `err` filled when a NUL byte is present.
 */
inline bool lua_string_without_nul(lua_State *L, int idx,
                                   std::string &out,
                                   std::string_view label,
                                   std::string &err)
{
    size_t len = 0;
    const char *data = lua_tolstring(L, idx, &len);
    if (data == nullptr)
    {
        err.assign(label);
        err += " must be a string";
        return false;
    }
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
    size_t len = 0;
    const char *data = luaL_checklstring(L, idx, &len);
    if (std::memchr(data, '\0', len) != nullptr)
    {
        luaL_error(L, "%s must not contain NUL byte", label);
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
