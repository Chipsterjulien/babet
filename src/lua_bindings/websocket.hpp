#ifndef WEBSOCKET_HPP
#define WEBSOCKET_HPP

#include <lua.hpp>

/**
 * @brief RFC 6455 WebSocket client exposed as `babet.websocket`.
 *
 * Constructor:
 *   connect(url, opts?) -> websocket | (nil, err)
 *
 * Methods:
 *   send_text(data, timeout?)   -> bytes | (nil, err)
 *   send_binary(data, timeout?) -> bytes | (nil, err)
 *   recv(timeout?)              -> message | (nil, err)
 *   ping(data?, timeout?)       -> (true, nil) | (nil, err)
 *   close(code?, reason?, timeout?) -> (true, nil) | (nil, err)
 *   set_timeout(seconds)        -> (true, nil) | (nil, err)
 *
 * recv() returns a table with `type = "text"|"binary"|"close"`.
 * Text/binary messages include `data`; close messages include `code` when
 * present and `reason`. Ping frames are answered automatically with Pong.
 */
void register_websocket(lua_State *L);

#endif // WEBSOCKET_HPP
