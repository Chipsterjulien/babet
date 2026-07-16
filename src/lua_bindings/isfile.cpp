#include "isfile.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <string>
#include <string_view>
#include <system_error>
#include <stdexcept>

namespace fs = std::filesystem;

bool is_file(const std::string_view &path)
{
    if (path.empty())
    {
        throw std::invalid_argument("path cannot be empty");
    }

    std::error_code ec;
    fs::file_status status = fs::status(fs::path(path), ec);
    if (ec && ec != std::errc::no_such_file_or_directory)
    {
        throw std::system_error(ec, "cannot check file");
    }
    return fs::is_regular_file(status);
}

int lua_isFile(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected one argument");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as argument");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");

    try
    {
        bool result = is_file(path);
        lua_pushboolean(L, result);
        lua_pushnil(L);
        return 2;
    }
    catch (const std::exception &e)
    {
        return push_fail(L, e.what());
    }
}
