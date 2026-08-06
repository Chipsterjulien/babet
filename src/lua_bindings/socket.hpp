#ifndef SOCKET_HPP
#define SOCKET_HPP

#include <lua.hpp>

/**
 * @brief TCP, TLS and Unix-domain stream bindings exposed as `babet.socket`.
 *
 * Constructors:
 *   connect(host, port, timeout?)       -> socket | (nil, err)
 *   listen(host, port, backlog?)        -> server_socket | (nil, err)
 *   connect_unix(path, timeout?)        -> socket | (nil, err)
 *   listen_unix(path, opts?)            -> server_socket | (nil, err)
 *   connect_tls(host, port, opts?)      -> tls_socket | (nil, err)
 *
 * Stream methods:
 *   send(data)                          -> bytes | (nil, err)
 *   recv(count, timeout?)               -> data | (nil, err)
 *   recv_line(timeout?)                 -> line | (nil, err[, partial])
 *   recv_all(timeout?, max_bytes?)      -> data | (nil, err)
 *   set_timeout(seconds)                -> (true, nil) | (nil, err)
 *   starttls(opts?)                     -> (true, nil) | (nil, err)
 *   peer(), sockname(), close()
 *
 * Server method:
 *   accept(timeout?)                    -> socket | (nil, err)
 *
 * Observable contracts:
 *   - Stream sockets only: TCP/TLS and pathname-based AF_UNIX. UDP and
 *     Linux abstract Unix sockets are not exposed.
 *   - Unix listeners refuse every pre-existing pathname, apply exact
 *     permissions, and remove only the socket inode they created.
 *   - All I/O is synchronous. A timeout is one absolute budget for the
 *     complete call, not a fresh duration for every chunk.
 *   - A positional recv/recv_line/recv_all/accept timeout overrides the
 *     socket default for that call. Explicit 0 means infinite.
 *   - EOF is reported as `(nil, "closed")`, except recv_all where EOF is
 *     the successful terminator and recv_line where partial EOF adds a third
 *     return value.
 *   - Bytes consumed before a timeout/interruption remain internally queued
 *     and are delivered before later receive operations.
 *   - `send` transmits the whole Lua string or fails; payloads are binary-safe.
 *   - Userdata owns its FD/SSL object and `__gc` closes forgotten sockets.
 *     Constructors establish that Lua ownership before acquiring the resource,
 *     so a Lua memory-error longjmp cannot abandon an unowned FD or SSL object.
 *   - Internal C++ exceptions are converted to fixed `(nil, err)` results and
 *     never cross the Lua C boundary.
 *   - Created/accepted FDs are close-on-exec. Listening sockets use
 *     SO_REUSEADDR internally.
 *   - TLS verification is enabled by default with TLS 1.2 minimum. SNI is
 *     independent from certificate verification.
 *
 * Wrong positional argument types raise a Lua error. Invalid runtime values,
 * transport failures, timeouts, TLS failures and invalid option fields return
 * `(nil, err)`.
 */

int lua_socket_connect(lua_State *L);
int lua_socket_listen(lua_State *L);
int lua_socket_connect_unix(lua_State *L);
int lua_socket_listen_unix(lua_State *L);
int lua_socket_connect_tls(lua_State *L);

/**
 * @brief Registers the shared socket userdata metatable and attaches the
 * `socket` subtable to the Babet table currently at the top of the Lua stack.
 */
void register_socket(lua_State *L);

#endif // SOCKET_HPP
