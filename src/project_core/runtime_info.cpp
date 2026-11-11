#include "runtime_info.hpp"
#include "zip_utils.hpp"
#include "executable_path.hpp"
#include "../lua_bindings/lua_utils.hpp"
#include <lua.hpp>
namespace {
char context_key,strict_key;
int runtime_info(lua_State *L) {
    if(!lua_arity_is(L,0))return luaL_error(L,"runtimeInfo expects no arguments");
    lua_newtable(L);const int result=lua_gettop(L);lua_rawgetp(L,LUA_REGISTRYINDEX,&context_key);
    if(lua_istable(L,-1)) {
        const int source=lua_gettop(L);
        for(const char *key:{"mode","projectDir","scriptPath","executablePath"}){lua_getfield(L,source,key);lua_setfield(L,result,key);}
    } else {lua_pushliteral(L,"host");lua_setfield(L,result,"mode");}
    lua_settop(L,result);lua_pushnil(L);return 2;
}
int embedded_read(lua_State *L) {
    if(!lua_arity_is(L,1)||lua_type(L,1)!=LUA_TSTRING)return luaL_error(L,"embedded.read expects one name");
    const std::string name=luaL_checkstring_without_nul(L,1,"name");
    std::string error;const auto layout=runningEmbeddedImageLayout(&error);
    if(!layout)return push_fail_protected(L,error);
    if(!layout->generated)return push_fail_protected(L,"embedded.read: no embedded resources in this mode");
    const auto bytes=readEmbeddedResource(RUNNING_EXECUTABLE_CONTENT,name,&error,&*layout);
    if(!bytes)return push_fail_protected(L,error.empty()?"embedded.read: resource not found":error);
    auto build=[&](lua_State *s){lua_pushlstring(s,bytes->empty()?"":bytes->data(),bytes->size());lua_pushnil(s);return 2;};
    return lua_build_results_protected(L,build,2);
}
int embedded_list(lua_State *L) {
    if(!lua_arity_is(L,0))return luaL_error(L,"embedded.list expects no arguments");
    std::string error;const auto layout=runningEmbeddedImageLayout(&error);
    if(!layout)return push_fail_protected(L,error);
    if(!layout->generated)return push_fail_protected(L,"embedded.list: no embedded resources in this mode");
    const auto names=listEmbeddedFiles(RUNNING_EXECUTABLE_CONTENT,&error,&*layout);
    if(!names)return push_fail_protected(L,error);
    auto build=[&](lua_State *s){lua_newtable(s);lua_Integer i=0;for(const auto &name:*names){lua_pushlstring(s,name.data(),name.size());lua_rawseti(s,-2,++i);}lua_pushnil(s);return 2;};
    return lua_build_results_protected(L,build,2);
}
int undefined_global(lua_State *L) {
    if(lua_type(L,2)==LUA_TSTRING)return luaL_error(L,"undefined global variable: %s",lua_tostring(L,2));
    return luaL_error(L,"undefined global variable");
}
int strict(lua_State *L) {
    if(!lua_arity_between(L,0,1)||(lua_gettop(L)==1&&!lua_isboolean(L,1)))return luaL_error(L,"strict expects an optional boolean");
    const bool enable=lua_gettop(L)==0||lua_toboolean(L,1);
    lua_pushglobaltable(L);const int globals=lua_gettop(L);const bool has=lua_getmetatable(L,globals);
    lua_rawgetp(L,LUA_REGISTRYINDEX,&strict_key);const bool ours=has&&lua_rawequal(L,-1,-2);lua_pop(L,1);
    if(has&&!ours)return push_fail_protected(L,"strict: the global table already has a metatable");
    if(enable&&!has){lua_newtable(L);lua_pushcfunction(L,undefined_global);lua_setfield(L,-2,"__index");lua_pushvalue(L,-1);lua_rawsetp(L,LUA_REGISTRYINDEX,&strict_key);lua_setmetatable(L,globals);}
    else if(!enable&&ours){lua_pushnil(L);lua_setmetatable(L,globals);}
    return push_ok_protected(L);
}
template<int(*Fn)(lua_State*)>int boundary(lua_State *L){return lua_cfunction_exception_boundary<Fn>(L,"runtime: out of memory","runtime: C++ failure","runtime: unknown failure");}
}
void set_babet_runtime_info(lua_State *L,const char *mode,const char *dir,const char *script,const char *exe){
    lua_newtable(L);lua_pushstring(L,mode);lua_setfield(L,-2,"mode");
    lua_pushstring(L,dir&&*dir?dir:nullptr);lua_setfield(L,-2,"projectDir");
    lua_pushstring(L,script&&*script?script:nullptr);lua_setfield(L,-2,"scriptPath");
    lua_pushstring(L,exe&&*exe?exe:nullptr);lua_setfield(L,-2,"executablePath");lua_rawsetp(L,LUA_REGISTRYINDEX,&context_key);
}
void register_babet_runtime_info(lua_State *L){
    lua_pushcfunction(L,boundary<runtime_info>);lua_setfield(L,-2,"runtimeInfo");
    lua_pushcfunction(L,boundary<strict>);lua_setfield(L,-2,"strict");lua_newtable(L);
    lua_pushcfunction(L,boundary<embedded_read>);lua_setfield(L,-2,"read");
    lua_pushcfunction(L,boundary<embedded_list>);lua_setfield(L,-2,"list");lua_setfield(L,-2,"embedded");
}
