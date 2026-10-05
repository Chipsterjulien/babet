#ifndef BABET_RUNTIME_REGISTRATION_HPP
#define BABET_RUNTIME_REGISTRATION_HPP

#include "../lua_bindings/native_plugin.hpp"

#include <string_view>

struct lua_State;

// Registers the complete public `babet` table and its userdata metatables in
// an already-open Lua state. The caller owns luaL_openlibs() and any host-
// specific package.path / arg setup. Native plugins are explicitly enabled
// only by the normal CLI main state; generated apps, embedding and workers use
// their respective refusal modes.
void register_babet(lua_State *L,
                    NativePluginRuntime *plugin_runtime = nullptr,
                    NativePluginMode plugin_mode = NativePluginMode::embedding);

// Prepends an already-owned Lua module search prefix to package.path.
// The caller must execute this helper inside lua_run_setup_protected(); the
// helper itself creates no C++ owner around Lua operations that may longjmp.
void prepend_babet_package_path(lua_State *L, std::string_view prefix);

// CLI/generated applications only, immediately after luaL_openlibs() and
// inside the caller's protected setup. Keeps Lua's status/close arguments,
// restores Babet UI state and exits without process-wide native destructors.
// Embedding deliberately retains the host's standard Lua os.exit policy.
void register_cli_process_exit(lua_State *L);

// Shared terminal-aware Lua teardown used by the CLI and the embedding API.
// Lua finalizers run first so process userdata can return an interactive TTY;
// curses is then serviced/cleaned on the registered main thread.
void close_babet_lua_state(lua_State *L) noexcept;

#endif // BABET_RUNTIME_REGISTRATION_HPP
