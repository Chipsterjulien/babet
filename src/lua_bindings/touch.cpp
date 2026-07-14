#include "touch.hpp"
#include "lua_utils.hpp"
#include <filesystem>
#include <fstream>
#include <system_error>

namespace fs = std::filesystem;

/**
 * Function to create or update a file (à la `touch`).
 *
 * Aucun pré-check de permissions sur le répertoire parent : il serait
 * (a) TOCTOU — l'état peut changer entre le check et l'écriture — et
 * (b) faux, car ne regarder que le bit owner_write ignore les droits
 * accordés via le groupe ou other. On laisse l'OS trancher au moment
 * de l'ouverture / de la mise à jour, qui est la seule réponse fiable.
 *
 * Le répertoire parent n'est testé que s'il est EXPLICITE : pour
 * "test.txt", parent_path() est vide (le fichier va dans le cwd), il
 * n'y a donc rien à vérifier — appeler fs::status("") renverrait un
 * statut d'erreur sur lequel on ne doit pas raisonner.
 *
 * Tous les appels filesystem passent par l'overload std::error_code :
 * rien ne lève, donc pas de try/catch (un catch qui ne peut rien
 * attraper serait du code mort trompeur).
 *
 * @param path The file path.
 * @return A string containing an error message if any, or an empty
 *         string if successful.
 */
std::string touch(const std::string &path)
{
    // Rejet explicite du chemin vide : cohérent avec le garde
    // équivalent de link.cpp (target/linkpath non vides), et message
    // clair plutôt qu'un échec générique d'ofstream sur "".
    if (path.empty())
    {
        return "path cannot be empty";
    }

    std::error_code ec;

    fs::path parent_path = fs::path(path).parent_path();
    if (!parent_path.empty())
    {
        bool parent_exists = fs::exists(parent_path, ec);
        if (ec)
        {
            return "cannot stat parent directory '" +
                   parent_path.string() + "': " + ec.message();
        }
        if (!parent_exists)
        {
            return "Parent directory does not exist: " +
                   parent_path.string();
        }
    }

    bool exists = fs::exists(path, ec);
    if (ec)
    {
        return "cannot stat '" + path + "': " + ec.message();
    }

    if (exists)
    {
        // Met à jour la date de dernière modification.
        fs::last_write_time(path, fs::file_time_type::clock::now(), ec);
        if (ec)
        {
            return "cannot update timestamp of '" + path + "': " +
                   ec.message();
        }
    }
    else
    {
        // Crée un fichier vide. C'est l'ouverture elle-même qui décide :
        // si les permissions manquent, ofstream échoue ici, proprement.
        // std::ios::binary : sans effet sur un fichier vide (aucun octet
        // écrit, donc aucune traduction de fin de ligne) ; posé par
        // cohérence d'intention — touch crée un conteneur d'octets neutre.
        std::ofstream file(path, std::ios::binary);
        if (!file)
        {
            return "Failed to create the file: " + path;
        }
    }

    return "";
}

/**
 * Lua binding for the touch function.
 * @param L The Lua state.
 * @return Number of return values (2: ok/nil, err/nil).
 * Lua usage: ok, err = babet.touch(path)
 *   - path: The file path to touch.
 */
int lua_touch(lua_State *L)
{
    int argc = lua_gettop(L);
    if (argc != 1)
    {
        return luaL_argerror(L, 1, "Expected one argument: string path");
    }
    if (!lua_isstring(L, 1))
    {
        return luaL_argerror(L, 1, "Expected a string as argument");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    std::string error_message = touch(path);
    if (error_message.empty())
    {
        return push_ok(L);
    }
    return push_fail(L, error_message);
}