#ifndef RENAME_HPP
#define RENAME_HPP

#include <lua.hpp>
#include <string>
#include <string_view>

/** Rename one directory entry, including a dangling symbolic link. */
std::string rename_file(std::string_view old_path, std::string_view new_path);

int lua_rename(lua_State *L);

#endif // RENAME_HPP
