#include "chdir.hpp"
#include "workers.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <string>
#include <system_error>
#include <optional>
#include <lua.hpp>
#include <cstring>

namespace fs = std::filesystem;

/**
 * @brief Change the current working directory.
 *
 * @param path The directory path to change to.
 * @return std::optional<std::string> An optional string containing an error message if any, or an empty optional if successful.
 */
std::optional<std::string> chdir(const fs::path &path)
{
    std::error_code ec;

    // Convert relative path to absolute path and then to canonical path
    fs::path absolute_path = fs::absolute(path, ec);
    if (ec)
    {
        return "cannot resolve absolute path for '" + path.string() + "': " + ec.message();
    }

    fs::path canonical_path = fs::canonical(absolute_path, ec);
    if (ec)
    {
        return "cannot resolve canonical path '" + absolute_path.string() + "': " + ec.message();
    }

    // Check if the path is a directory
    if (!fs::is_directory(canonical_path, ec))
    {
        return "Path '" + canonical_path.string() + "' is not a directory or cannot be accessed: " + ec.message();
    }

    // Change current working directory
    fs::current_path(canonical_path, ec);
    if (ec)
    {
        return "cannot change directory to '" + canonical_path.string() + "': " + ec.message();
    }
    return std::nullopt;
}

/**
 * @brief Lua binding for changing the current working directory.
 *
 * @param L The Lua state.
 * @return int Number of return values (1: error message or nil).
 * @note Lua usage: error_message = lua_chdir(path)
 *   - path: The directory path to change to.
 */
int lua_chdir(lua_State *L)
{
    std::string path_string =
        luaL_checkstring_without_nul(L, 1, "path");
    fs::path path(path_string);

    // CORRECTIF (option A validée, revue Gemini triée) : le CWD est
    // PROCESS-WIDE — un chdir, même depuis le main thread, change la
    // résolution des chemins relatifs de TOUS les workers en vol.
    // Même règle que setenv : autorisé avant le premier spawn/chargement GTK,
    // interdit ensuite, sous le même verrou. AUCUNE opération Lua
    // sous le verrou (résultat capturé dans une locale).
    std::optional<std::string> res;
    if (!with_process_env_lock([&]()
                               { res = chdir(path); }))
    {
        return push_fail_protected(L,
                         "chdir: forbidden after workers.spawn or GTK loading (the working "
                         "directory is shared across threads; change it "
                         "before workers or gui.available/gui.init)");
    }
    return push_action_result_protected(L, res);
}
