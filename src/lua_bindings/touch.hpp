#ifndef TOUCH_HPP
#define TOUCH_HPP

#include <lua.hpp>
#include <string>

/**
 * Creates an empty regular file when the path is absent, or updates the
 * timestamp of an existing path without truncating its contents.
 *
 * @param path The filesystem path to touch.
 * @return An error message on failure, or an empty string on success.
 */
std::string touch(const std::string &path);

/**
 * Lua binding for babet.touch(path).
 *
 * @param L The Lua state.
 * @return Two Lua values: (true, nil) on success or (nil, error) on failure.
 */
int lua_touch(lua_State *L);

#endif // TOUCH_HPP
