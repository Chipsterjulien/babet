#include "loadLuaFile.hpp"
#include "../lua_bindings/lua_utils.hpp"
bool loadLuaFile(lua_State *L, const std::string &filename, std::string &error)
{
    if (luaL_dofile(L, filename.c_str()) != LUA_OK)
    {
        error = "Failed to load " + filename + ": " +
                lua_value_to_display_string(L, -1);
        lua_pop(L, 1);
        return false;
    }
    error.clear();
    return true;
}