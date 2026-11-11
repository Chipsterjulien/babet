#pragma once
#include <lua.hpp>
#include <cstdio>
namespace babet_callbacks {
inline char handler_key;
inline thread_local bool reporting = false;
inline int traceback(lua_State *L) {
    luaL_traceback(L, L, lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : "non-string Lua error", 1);
    return 1;
}
inline int pcall(lua_State *L, int args, int results) noexcept {
    if (!lua_checkstack(L, 1)) return lua_pcall(L, args, results, 0);
    const int base = lua_gettop(L) - args;
    lua_pushcfunction(L, traceback); lua_insert(L, base);
    const int status = lua_pcall(L, args, results, base);
    lua_remove(L, base); return status;
}
// The prefix is part of the documented stderr contract: each module passes its
// own ("babet.gui callback error: ", "babet.signal callback error: ").
inline void print(lua_State *L, int index, const char *prefix) noexcept {
    std::fputs(prefix, stderr);
    if (lua_type(L, index) == LUA_TSTRING) {
        size_t n=0; const char *s=lua_tolstring(L,index,&n); std::fwrite(s,1,n,stderr);
    } else std::fputs("non-string Lua error", stderr);
    std::fputc('\n',stderr); std::fflush(stderr);
}
inline void report(lua_State *L, const char *prefix) noexcept {
    const int base=lua_gettop(L);
    if (!reporting && lua_checkstack(L,3)) {
        lua_rawgetp(L,LUA_REGISTRYINDEX,&handler_key);
        if (lua_isfunction(L,-1)) {
            lua_pushvalue(L,base); reporting=true;
            const int status=pcall(L,1,0); reporting=false;
            if (status==LUA_OK) { lua_settop(L,base); return; }
            print(L,-1,prefix);
        }
        lua_settop(L,base);
    }
    print(L,base,prefix);
}
}
