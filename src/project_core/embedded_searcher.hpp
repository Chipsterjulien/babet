#ifndef EMBEDDED_SEARCHER_HPP
#define EMBEDDED_SEARCHER_HPP

#include <lua.hpp>

/**
 * Adds a custom package.searcher that resolves require() calls
 * against files embedded in the zip appended to the executable.
 *
 * Insertion position: 2 (after package.preload, before the on-disk searchers).
 *
 * The executable path is captured as an upvalue, so no global state is needed.
 * Allocation/native failures raise a Lua error after releasing C++ owners;
 * an unreadable embedded entry never falls through to a disk module.
 */
void register_embedded_searcher(lua_State *L, const char *exePath);

#endif // EMBEDDED_SEARCHER_HPP
