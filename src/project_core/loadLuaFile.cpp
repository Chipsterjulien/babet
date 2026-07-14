#include "loadLuaFile.hpp"
#include "../lua_bindings/lua_utils.hpp"
#include <iostream>

bool loadLuaFile(lua_State *L, const std::string &filename)
{
    if (luaL_dofile(L, filename.c_str()) != LUA_OK)
    {
        std::cerr << "Failed to load " << filename << ": "
                  << lua_value_to_display_string(L, -1) << std::endl;
        lua_pop(L, 1);
        return false;
    }
    return true;
}