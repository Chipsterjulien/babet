#pragma once
struct lua_State;
// Call inside protected Lua setup; arguments are copied into this state's registry.
void set_babet_runtime_info(lua_State*,const char *mode,const char *project_dir,const char *script_path,const char *executable_path);
void register_babet_runtime_info(lua_State*);
