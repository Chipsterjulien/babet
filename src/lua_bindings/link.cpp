#include "link.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <string>
#include <system_error>
#include <lua.hpp>

namespace fs = std::filesystem;

/**
 * @brief Creates a symbolic link.
 *
 * On NE résout PAS la cible (pas de weakly_canonical) : un symlink peut
 * légitimement être relatif (lien -> ../truc) ou pointer vers une cible
 * encore absente. Résoudre dénaturerait le lien (relatif -> absolu) ou
 * échouerait à tort. On pose `target` tel quel, exactement comme
 * `ln -s` : c'est la sémantique attendue d'un lien symbolique.
 *
 * Le répertoire parent du lien n'est créé que s'il est EXPLICITE : pour
 * "mon_lien", parent_path() est vide (lien dans le cwd), il n'y a rien
 * à créer — fs::create_directories("") positionnerait une erreur à
 * tort.
 *
 * Tous les appels filesystem passent par l'overload std::error_code :
 * rien ne lève, donc pas de try/catch (un catch qui ne peut rien
 * attraper serait du code mort trompeur).
 *
 * @param target The target path for the symbolic link (posé tel quel).
 * @param linkpath The path where the symbolic link will be created.
 * @return std::optional<std::string> An optional error message if an
 *         error occurs, std::nullopt on success.
 */
std::optional<std::string> create_symlink(const std::string &target, const std::string &linkpath)
{
    if (target.empty() || linkpath.empty())
    {
        return "Target path and link path cannot be empty";
    }

    std::error_code ec;

    std::error_code exist_ec;
    const bool link_exists = fs::exists(linkpath, exist_ec);
    if (exist_ec)
    {
        return "Failed to inspect link path: " + exist_ec.message();
    }
    if (link_exists)
    {
        return "Link path already exists";
    }

    fs::path parent = fs::path(linkpath).parent_path();
    if (!parent.empty())
    {
        fs::create_directories(parent, ec);
        if (ec)
        {
            return "Failed to create parent directories: " + ec.message();
        }
    }

    fs::create_symlink(fs::path(target), fs::path(linkpath), ec);
    if (ec)
    {
        return "Failed to create symbolic link: " + ec.message();
    }

    return std::nullopt;
}

int lua_link(lua_State *L)
{
    luaL_argcheck(L, lua_arity_is(L, 2), 1, "Expected two arguments");

    const std::string_view target =
        luaL_checkstring_view_without_nul(L, 1, "target");
    const std::string_view linkpath =
        luaL_checkstring_view_without_nul(L, 2, "link path");

    return push_action_result_protected(
        L, create_symlink(std::string(target), std::string(linkpath)));
}