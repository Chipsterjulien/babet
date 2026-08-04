#include "listFiles.hpp"
#include "lua_utils.hpp"

#include <climits>
#include <filesystem>
#include <new>
#include <optional>
#include <string>
#include <system_error>
#include <vector>

namespace fs = std::filesystem;

namespace
{
using optional_string = std::optional<std::string>;

optional_string validate_directory_path(const fs::path &path)
{
    std::error_code ec;
    if (!fs::is_directory(path, ec))
    {
        return ec ? ec.message() : "Path is not a directory";
    }
    return std::nullopt;
}

optional_string list_files_helper(const fs::path &base_path,
                                  const fs::path &path,
                                  std::vector<std::string> &results,
                                  bool recursive)
{
    try
    {
        for (const auto &entry : fs::directory_iterator(path))
        {
            if (fs::is_regular_file(entry))
            {
                // Purement lexical : ne résout pas les symlinks et conserve
                // leur position dans l'arbre parcouru.
                results.push_back(
                    entry.path().lexically_relative(base_path).string());
            }

            // Ne jamais suivre un symlink de dossier : cela empêcherait les
            // sorties d'arbre et les boucles de liens.
            if (recursive && fs::is_directory(entry) && !entry.is_symlink())
            {
                if (auto error = list_files_helper(base_path, entry.path(),
                                                   results, recursive))
                {
                    return error;
                }
            }
        }
    }
    catch (const std::bad_alloc &)
    {
        throw;
    }
    catch (const fs::filesystem_error &e)
    {
        return e.what();
    }
    return std::nullopt;
}

int lua_listFiles_impl(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L, "Expected one or two arguments");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as first argument (path)");
    }
    if (!lua_is_optional_strict_boolean(L, 2))
    {
        return luaL_error(L, "recursive must be a boolean or nil");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    const bool recursive = lua_is_strict_boolean(L, 2) &&
                           lua_toboolean(L, 2);

    const fs::path base_path(path);
    if (auto error = validate_directory_path(base_path))
    {
        return push_fail_protected(L, *error);
    }

    // Le parcours et tous ses itérateurs sont détruits avant la première
    // allocation Lua. Un LUA_ERRMEM pendant la construction de la table ne
    // peut donc plus sauter par-dessus un directory_iterator ou un string.
    std::vector<std::string> results;
    if (auto error = list_files_helper(base_path, base_path, results,
                                       recursive))
    {
        return push_fail_protected(L, *error);
    }

    auto builder = [&results](lua_State *Ls) noexcept -> int
    {
        const int array_hint = results.size() <= static_cast<std::size_t>(INT_MAX)
                                   ? static_cast<int>(results.size())
                                   : 0;
        lua_createtable(Ls, array_hint, 0);
        lua_Integer index = 1;
        for (const std::string &relative_path : results)
        {
            lua_pushlstring(Ls, relative_path.data(), relative_path.size());
            lua_rawseti(Ls, -2, index++);
        }
        lua_pushnil(Ls);
        return 2;
    };
    return lua_build_results_protected(L, builder, 2);
}
} // namespace

int lua_listFiles(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_listFiles_impl>(
        L, "listFiles: out of memory", "listFiles: internal failure",
        "listFiles: unknown internal failure");
}
