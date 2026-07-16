#ifndef BABET_ARCHIVE_HPP
#define BABET_ARCHIVE_HPP

#include <lua.hpp>

/**
 * @brief Registers the secure ZIP/TAR archive API as `babet.archive`.
 *
 * Public functions:
 *   create(source_or_sources, archive [, opts])
 *   list(archive [, opts])
 *   extract(archive, destination [, opts])
 *   extractFile(archive, entry, destination [, opts])
 *
 * ZIP creation, listing, and extraction use miniz. list(), extract(), and
 * extractFile() additionally detect TAR, optionally compressed, through
 * libarchive. create() accepts either the historical source-directory string
 * or a dense array of explicit regular-file/directory paths. Creation may
 * additionally select final archive paths through bounded safe-glob include
 * and exclude arrays. Input archives are pinned through a regular-file
 * descriptor, unsafe paths and
 * unsupported entry types are rejected, configurable anti-bomb limits are
 * enforced, and extracted regular files use same-directory staging before
 * publication.
 * Archive creation supports ZIP and TAR with gzip, xz, bzip2, or zstd.
 */
void register_archive(lua_State *L);

#endif // BABET_ARCHIVE_HPP
