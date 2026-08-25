#ifndef LOADLUAFILE_HPP
#define LOADLUAFILE_HPP

#include <lua.hpp>
#include <string>

/**
 * @brief Loads and executes a Lua file.
 * @param error Receives a display-ready diagnostic on failure.
 * @return true on success, false on error. The caller owns diagnostic output
 *         so terminal state can be restored before anything is printed.
 */
bool loadLuaFile(lua_State *L, const std::string &filename, std::string &error);

#endif // LOADLUAFILE_HPP