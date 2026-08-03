#ifndef BABET_ARCHIVE_HPP
#define BABET_ARCHIVE_HPP

#include <lua.hpp>

/**
 * @brief Registers the secure ZIP/TAR archive API as `babet.archive`.
 *
 * Public functions:
 *   create(source_or_sources, archive [, opts])
 *   list(archive [, opts])
 *   read(archive, entry_name_or_index [, opts])
 *   test(archive [, opts])
 *   extract(archive, destination [, opts])
 *   extractFile(archive, entry, destination [, opts])
 *
 * ZIP creation, listing, verification, and extraction use miniz. list(),
 * test(), extract(), and extractFile() additionally detect TAR, optionally
 * compressed, through libarchive. list() preserves archive order, exposes
 * bounded metadata,
 * reports exact duplicates and normalised output-path conflicts, and never
 * writes to the filesystem. read() returns one regular entry as a bounded
 * binary Lua string. It selects by exact raw name or by the one-based index
 * exposed by list(); ambiguous names are refused while an explicit index can
 * disambiguate duplicate entries. Its max_size limit is enforced both against
 * metadata and against bytes actually produced, and unsafe path syntax is
 * preserved because no filesystem path is created. test() fully validates ZIP
 * local headers, descriptors, payload sizes and CRCs, fully consumes TAR
 * streams, then applies the same aggregate path/type/collision policy as
 * extraction without writing.
 * create() accepts either the historical
 * source-directory string or a dense array of explicit regular-file/directory
 * paths. Creation may additionally select final archive paths through bounded
 * safe-glob include and exclude arrays. extract() reuses that same bounded
 * matcher against normalised internal paths, with exclusion priority and
 * selected-entry-only output collision/type validation. Its dry_run option
 * executes the same archive, selection, payload, overwrite, and destination
 * preflight logic through a read-only destination traversal, returning planned
 * create/overwrite/skip counts without creating files or directories. Input
 * archives are
 * pinned through a regular-file descriptor, unsafe selected paths and
 * unsupported selected entry types are rejected, configurable anti-bomb
 * limits are enforced, and
 * extracted regular files use same-directory staging before publication.
 * Archive creation supports ZIP and TAR with gzip, xz, bzip2, or zstd.
 */
void register_archive(lua_State *L);

#endif // BABET_ARCHIVE_HPP
