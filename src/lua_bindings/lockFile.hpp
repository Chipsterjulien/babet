#pragma once

struct lua_State;

// babet.lockFile(path) -> handle, nil | nil, "locked" | nil, diagnostic.
int lua_lockFile(lua_State *L);
