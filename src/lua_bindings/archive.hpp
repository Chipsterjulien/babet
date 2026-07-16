#ifndef BABET_ARCHIVE_HPP
#define BABET_ARCHIVE_HPP

#include <lua.hpp>

/**
 * @brief Registers the secure ZIP/TAR archive API as `babet.archive`.
 *
 * Public functions:
 *   create(source, archive [, opts])
 *   list(archive [, opts])
 *   extract(archive, destination [, opts])
 *   extractFile(archive, entry, destination [, opts])
 *
 * ZIP creation, listing, and extraction use miniz. list(), extract(), and
 * extractFile() additionally detect TAR, optionally gzip-compressed, through
 * libarchive. Input
 * archives are pinned through a regular-file descriptor, unsafe paths and
 * unsupported entry types are rejected, configurable anti-bomb limits are
 * enforced, and extracted regular files use same-directory staging before
 * publication.
 * Archive creation remains ZIP-only in the current lot.
 */
void register_archive(lua_State *L);

#endif // BABET_ARCHIVE_HPP
