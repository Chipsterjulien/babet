#include "fileUtils.hpp"
#include "lua_utils.hpp"
#include <functional>

namespace fs = std::filesystem;

using PathFunction = std::optional<std::string>(std::string_view);

/**
 * @brief Get the basename (filename with extension) from a full path.
 * @param fullPath The full path of the file.
 * @return An optional string with the basename, or an empty optional if an error occurs.
 */
std::optional<std::string> getBasename(std::string_view fullPath) {
    auto path = fs::path(fullPath).filename().string();
    return !path.empty() ? std::make_optional(path) : std::nullopt;
}

/**
 * @brief Get the extension of the file from a full path.
 * @param fullPath The full path of the file.
 * @return An optional string with the extension, or an empty optional if an error occurs.
 */
std::optional<std::string> getExtension(std::string_view fullPath) {
    auto ext = fs::path(fullPath).extension().string();
    return !ext.empty() ? std::make_optional(ext) : std::nullopt;
}

/**
 * @brief Get the filename without extension from a full path.
 * @param fullPath The full path of the file.
 * @return An optional string with the filename without extension, or an empty optional if an error occurs.
 */
std::optional<std::string> getFilename(std::string_view fullPath) {
    auto stem = fs::path(fullPath).stem().string();
    return !stem.empty() ? std::make_optional(stem) : std::nullopt;
}

/**
 * @brief Get the parent path from a full path.
 * @param fullPath The full path of the file.
 * @return An optional string with the parent path, or an empty optional if an error occurs.
 */
std::optional<std::string> getPath(std::string_view fullPath) {
    auto parent = fs::path(fullPath).parent_path().string();
    return !parent.empty() ? std::make_optional(parent) : std::nullopt;
}

/**
 * @brief Generic function for calling a file path function and pushing results onto the Lua stack.
 * @param L The Lua state.
 * @param func The function to call which processes the file path.
 * @return Number of return values (2: result string and error message or nil).
 */
template<typename Func>
int lua_genericFunction(lua_State* L, Func func) {
    if (lua_gettop(L) != 1 || !lua_isstring(L, 1)) {
        return luaL_error(L, "Expected one string argument");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    auto result = func(path);

    if (result) {
        lua_pushstring(L, result->c_str());
        lua_pushnil(L);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, "cannot extract path component");
    }
    return 2;
}

/**
 * @brief Lua binding for getting the basename.
 * @param L The Lua state.
 * @return Number of return values (2: basename, error).
 *         Lua usage: basename, err = lua_getBasename(path)
 */
int lua_getBasename(lua_State* L) {
    return lua_genericFunction(L, getBasename);
}

/**
 * @brief Lua binding for getting the extension.
 * @param L The Lua state.
 * @return Number of return values (2: extension, error).
 *         Lua usage: extension, err = lua_getExtension(path)
 */
int lua_getExtension(lua_State* L) {
    return lua_genericFunction(L, getExtension);
}

/**
 * @brief Lua binding for getting the filename without extension.
 * @param L The Lua state.
 * @return Number of return values (2: filename without extension, error).
 *         Lua usage: filename, err = lua_getFilename(path)
 */
int lua_getFilename(lua_State* L) {
    return lua_genericFunction(L, getFilename);
}

/**
 * @brief Lua binding for getting the parent path.
 * @param L The Lua state.
 * @return Number of return values (2: parent path, error).
 *         Lua usage: parentPath, err = lua_getPath(path)
 */
int lua_getPath(lua_State* L) {
    return lua_genericFunction(L, getPath);
}
