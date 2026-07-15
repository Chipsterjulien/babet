#ifndef BABET_ARCHIVE_HPP
#define BABET_ARCHIVE_HPP

#include <lua.hpp>

/**
 * @brief Registers the secure ZIP archive API as `babet.archive`.
 *
 * Public functions:
 *   create(source, archive [, opts])
 *   list(archive [, opts])
 *   extract(archive, destination [, opts])
 *   extractFile(archive, entry, destination [, opts])
 *
 * The implementation is ZIP-only, uses miniz, opens input archives through a
 * single regular-file stream, validates the whole selected entry set before
 * writing, rejects unsafe paths and unsupported entry types, enforces
 * configurable anti-bomb limits, requires valid UTF-8 names for newly created
 * archives, and publishes regular files atomically through same-directory
 * temporary files.
 */
void register_archive(lua_State *L);

#endif // BABET_ARCHIVE_HPP
