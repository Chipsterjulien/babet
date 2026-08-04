#ifndef BABET_COMPRESSION_HPP
#define BABET_COMPRESSION_HPP

#include <lua.hpp>

/**
 * Registers standalone stream compression as `babet.compression`.
 *
 * Public functions:
 *   compress(source, destination, format [, opts])
 *   decompress(source, destination [, opts])
 *
 * Both registrations use the common Lua/C++ exception boundary. Unexpected
 * C++ failures return a stable module-prefixed (nil, err) diagnostic.
 */
void register_compression(lua_State *L);

#endif // BABET_COMPRESSION_HPP
