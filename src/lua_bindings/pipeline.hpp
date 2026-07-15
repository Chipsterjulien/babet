#ifndef BABET_PIPELINE_HPP
#define BABET_PIPELINE_HPP

#include <lua.hpp>

// Exécute un pipeline linéaire sans shell implicite.
// Lua: result, err = babet.pipeline(commands [, opts])
int lua_pipeline(lua_State *L);

// Lance le même pipeline avec des flux non bloquants pilotables depuis Lua.
// Lua: pipeline, err = babet.spawnPipeline(commands [, opts])
int lua_spawn_pipeline(lua_State *L);

// Enregistre babet.pipeline(), babet.spawnPipeline() et la métatable du
// userdata de pipeline en streaming.
void register_pipeline(lua_State *L);

#endif
