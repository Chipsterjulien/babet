#ifndef BASE64_HPP
#define BASE64_HPP

#include <lua.hpp>

/**
 * @brief Lua binding: encoded, err = babet.base64.encode(data [, opts])
 *
 * `data` is a binary-safe Lua string. Supported options:
 *   - url_safe (boolean, default false): RFC 4648 URL/file-name alphabet.
 *   - padding  (boolean, default true): append canonical '=' padding.
 *
 * Wrong argument types, wrong arity and unknown options are programmer
 * errors and raise a Lua error. Runtime failures are returned as (nil, err).
 */
int lua_base64_encode(lua_State *L);

/**
 * @brief Lua binding: decoded, err = babet.base64.decode(text [, opts])
 *
 * `text` must use the selected RFC 4648 alphabet. Supported options:
 *   - url_safe          (boolean, default false)
 *   - allow_unpadded    (boolean, default false)
 *   - ignore_whitespace (boolean, default false)
 *   - max_output        (non-negative integer, optional)
 *
 * The decoder is strict: padding placement and unused trailing bits are
 * validated. Invalid Base64 is a data error returned as (nil, err).
 */
int lua_base64_decode(lua_State *L);

/**
 * @brief Registers babet.base64.encode and babet.base64.decode.
 *
 * Precondition: the babet table is on top of the Lua stack. The stack is
 * unchanged after the call.
 */
void register_base64(lua_State *L);

#endif // BASE64_HPP
