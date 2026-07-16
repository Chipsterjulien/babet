#ifndef BABET_COMPRESSION_HPP
#define BABET_COMPRESSION_HPP

#include <lua.hpp>

/**
 * Registers standalone stream compression as `babet.compression`.
 *
 * Public functions:
 *   compress(source, destination, format [, opts])
 *   decompress(source, destination [, opts])
 */
void register_compression(lua_State *L);

#endif // BABET_COMPRESSION_HPP
