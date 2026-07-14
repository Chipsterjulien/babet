#ifndef REMOVE_HPP
#define REMOVE_HPP

#include <lua.hpp>
#include <string>

/** Remove a regular file or a symbolic link, including a dangling symlink. */
std::string remove_file(const std::string &path);

int lua_remove_file(lua_State *L);

#endif // REMOVE_HPP
