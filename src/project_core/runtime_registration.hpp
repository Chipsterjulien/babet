#ifndef BABET_RUNTIME_REGISTRATION_HPP
#define BABET_RUNTIME_REGISTRATION_HPP

#include <string_view>

struct lua_State;

// Registers the complete public `babet` table and its userdata metatables in
// an already-open Lua state. The caller owns luaL_openlibs() and any host-
// specific package.path / arg setup.
void register_babet(lua_State *L);


// Prepends an already-owned Lua module search prefix to package.path.
// The caller must execute this helper inside lua_run_setup_protected(); the
// helper itself creates no C++ owner around Lua operations that may longjmp.
void prepend_babet_package_path(lua_State *L, std::string_view prefix);

// Shared terminal-aware Lua teardown used by the CLI and the embedding API.
// Lua finalizers run first so process userdata can return an interactive TTY;
// curses is then serviced/cleaned on the registered main thread.
void close_babet_lua_state(lua_State *L) noexcept;

#endif // BABET_RUNTIME_REGISTRATION_HPP
