#ifndef BABET_WORKER_PROCESS_HPP
#define BABET_WORKER_PROCESS_HPP

struct lua_State;

// After luaL_openlibs, during protected worker setup only. Leaves the Lua
// stack unchanged. Main/embedding states keep their standard library APIs.
void register_worker_process_functions(lua_State *L);

#endif
