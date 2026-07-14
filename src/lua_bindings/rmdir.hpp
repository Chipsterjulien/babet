#ifndef RMDIR_HPP
#define RMDIR_HPP

#include <lua.hpp>
#include <optional>
#include <string>
#include <string_view>

/** Remove one real, empty directory. Files and symlinks are rejected. */
std::optional<std::string> rmdir(std::string_view path);

/** Remove one real directory tree recursively. Files and symlinks are rejected. */
std::optional<std::string> rmdir_all(std::string_view path);

int lua_rmdir(lua_State *L);
int lua_rmdir_all(lua_State *L);

#endif // RMDIR_HPP
