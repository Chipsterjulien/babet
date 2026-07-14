#include "find.hpp"
#include "lua_utils.hpp"
#include <regex>
#include <limits>
#include <system_error>
#include <algorithm>
#include <filesystem>
#include <cstring>
#include <string>
#include <vector>
#include <iostream>
#include <optional>
#include <functional>

namespace fs = std::filesystem;

namespace
{

    struct FindOptions
    {
        // CORRECTIF (revue ChatGPT post-release, vérifié) : lua_Integer,
        // plus int — même narrowing que max_splits de split (déjà
        // corrigé) : find(dir, { maxdepth = 2^32 }) devenait
        // silencieusement maxdepth = 0 (tout élagué sous la racine),
        // et 2^31 donnait un maxdepth NÉGATIF (résultat vide).
        lua_Integer mindepth = 0;
        lua_Integer maxdepth = std::numeric_limits<lua_Integer>::max();
        std::string type;
        std::string name;  // ECMAScript regex (e.g. ".*\\.cpp$")
        std::string iname; // idem, case-insensitive
        std::string path;  // ECMAScript regex, searched on the full path
    };

    struct CompiledRegexes
    {
        std::optional<std::regex> name;
        std::optional<std::regex> iname;
        std::optional<std::regex> path;
    };

    std::optional<std::string>
    compile_regexes(const FindOptions &options, CompiledRegexes &compiled)
    {
        try
        {
            if (!options.name.empty())
            {
                compiled.name.emplace(options.name,
                                      std::regex_constants::ECMAScript);
            }
            if (!options.iname.empty())
            {
                compiled.iname.emplace(
                    options.iname,
                    std::regex_constants::ECMAScript |
                        std::regex_constants::icase);
            }
            if (!options.path.empty())
            {
                compiled.path.emplace(options.path,
                                      std::regex_constants::ECMAScript);
            }
        }
        catch (const std::regex_error &error)
        {
            return "find: invalid regular expression: " +
                   std::string(error.what());
        }
        return std::nullopt;
    }

    bool matches_options(const fs::directory_entry &entry,
                         const FindOptions &options,
                         const CompiledRegexes &compiled)
    {
        if (!options.type.empty())
        {
            if ((options.type == "f" && !fs::is_regular_file(entry)) ||
                (options.type == "d" && !fs::is_directory(entry)))
            {
                return false;
            }
        }

        if (compiled.name &&
            !std::regex_match(entry.path().filename().string(),
                              *compiled.name))
        {
            return false;
        }
        if (compiled.iname &&
            !std::regex_match(entry.path().filename().string(),
                              *compiled.iname))
        {
            return false;
        }
        if (compiled.path &&
            !std::regex_search(entry.path().string(), *compiled.path))
        {
            return false;
        }
        return true;
    }

    // CORRECTIF Gemini (longjmp/C++) : parse_options NE FAIT PLUS de
    // luaL_error elle-même. Si elle le faisait, le longjmp aurait
    // contourné le destructeur de FindOptions (4 std::string), fuyant
    // leur mémoire. À la place, elle retourne un bool : true si OK
    // (out est rempli), false si erreur (err pointe vers un literal
    // C-string statiquement alloué, donc sûr à propager sans
    // ownership). Le caller décide alors quoi faire — par exemple
    // push_fail() qui ne fait PAS de longjmp.
    //
    // Les literals de message sont stockés dans la section .rodata
    // du binaire, leur durée de vie est celle du programme, donc on
    // peut les passer par pointeur sans copie ni risque.
    bool parse_options(lua_State *L, int index, FindOptions &out,
                       const char *&err)
    {
        auto assign_string = [&](int stack_index, std::string &dest,
                                 const char *nul_error) -> bool
        {
            size_t len = 0;
            const char *data = lua_tolstring(L, stack_index, &len);
            if (std::memchr(data, '\0', len) != nullptr)
            {
                err = nul_error;
                return false;
            }
            dest.assign(data, len);
            return true;
        };

        // CORRECTIF (revue ChatGPT post-v2.2.0, vérifié) :
        // lua_isinteger, plus lua_isnumber. find(".", {maxdepth=1.5})
        // passait le test isnumber puis lua_tointeger rendait 0 —
        // la demande devenait silencieusement maxdepth = 0 (élagage
        // total). Un nombre non entier est désormais une erreur
        // explicite, pas une troncature muette. (Idem mindepth.)
        lua_getfield(L, index, "mindepth");
        if (lua_isinteger(L, -1))
        {
            out.mindepth = lua_tointeger(L, -1);
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'mindepth' must be an integer";
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "maxdepth");
        if (lua_isinteger(L, -1))
        {
            out.maxdepth = lua_tointeger(L, -1);
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'maxdepth' must be an integer";
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "type");
        if (lua_isstring(L, -1))
        {
            if (!assign_string(-1, out.type,
                               "find: 'type' must not contain NUL byte"))
            {
                lua_pop(L, 1);
                return false;
            }
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'type' must be a string";
            return false;
        }
        lua_pop(L, 1);

        // CORRECTIF (revue ChatGPT post-v2.2.0) : valider la VALEUR
        // de type, pas seulement son genre. Toute string autre que
        // "f"/"d" était acceptée et revenait à ne poser aucun
        // filtre : find(".", { type = "file" }) rendait tout, en
        // silence. (Nota : lua_isstring accepte aussi les nombres
        // par coercition — type = 42 devient "42" et tombe ici.)
        if (!out.type.empty() && out.type != "f" && out.type != "d")
        {
            err = "find: 'type' must be \"f\" or \"d\"";
            return false;
        }

        lua_getfield(L, index, "name");
        if (lua_isstring(L, -1))
        {
            if (!assign_string(-1, out.name,
                               "find: 'name' must not contain NUL byte"))
            {
                lua_pop(L, 1);
                return false;
            }
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'name' must be a string";
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "iname");
        if (lua_isstring(L, -1))
        {
            if (!assign_string(-1, out.iname,
                               "find: 'iname' must not contain NUL byte"))
            {
                lua_pop(L, 1);
                return false;
            }
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'iname' must be a string";
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "path");
        if (lua_isstring(L, -1))
        {
            if (!assign_string(-1, out.path,
                               "find: 'path' must not contain NUL byte"))
            {
                lua_pop(L, 1);
                return false;
            }
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'path' must be a string";
            return false;
        }
        lua_pop(L, 1);

        return true;
    }

    std::optional<std::string> find(
        const fs::path &root, const FindOptions &options,
        const std::function<void(const fs::path &)> &callback)
    {
        std::error_code check_ec;
        bool root_exists = fs::exists(root, check_ec);
        if (check_ec)
        {
            return "cannot inspect path '" + root.string() +
                   "': " + check_ec.message();
        }
        if (!root_exists)
        {
            return "path does not exist: " + root.string();
        }

        bool root_is_directory = fs::is_directory(root, check_ec);
        if (check_ec)
        {
            return "cannot inspect path '" + root.string() +
                   "': " + check_ec.message();
        }
        if (!root_is_directory)
        {
            return "path is not a directory: " + root.string();
        }

        CompiledRegexes compiled;
        if (auto regex_error = compile_regexes(options, compiled); regex_error)
        {
            return regex_error;
        }

        try
        {
            for (auto it = fs::recursive_directory_iterator(root);
                 it != fs::recursive_directory_iterator(); ++it)
            {
                // lua_Integer pour comparer sans narrowing avec les
                // bornes (it.depth() rend un int, l'élargissement est
                // sans perte).
                lua_Integer depth = it.depth();

                // CORRECTIF (audit v21) : élagage maxdepth par PRÉVENTION
                // de la descente, plus par pop().
                //
                // L'ancien code faisait `it.pop(); continue;` quand
                // depth > maxdepth. Or pop() avance DÉJÀ l'itérateur sur
                // l'entrée suivante du parent ; le ++it du for avançait
                // une SECONDE fois. Deux symptômes reproduits :
                //   1. Dossier élagué non vide suivi d'un frère : le
                //      frère était silencieusement absent du résultat
                //      (root/{sub/x.txt, a.txt, b.txt}, maxdepth=0 ->
                //      a.txt manquant).
                //   2. Dossier élagué non vide en DERNIÈRE position :
                //      pop() rendait l'itérateur end, et ++it sur end
                //      jetait filesystem_error ("cannot increment
                //      recursive directory iterator") -> find retournait
                //      une erreur parasite au lieu du résultat.
                //
                // Nouvelle stratégie : ne JAMAIS descendre au-delà de
                // maxdepth. Si l'entrée courante est un dossier situé à
                // depth >= maxdepth, ses enfants seraient à depth+1 >
                // maxdepth : on annule la récursion en attente AVANT
                // l'incrément via disable_recursion_pending(). Ainsi
                // aucune entrée ne dépasse maxdepth (hors maxdepth < 0,
                // couvert par le filtre ci-dessous), pop() disparaît, et
                // l'incrément du for reste le SEUL à faire avancer
                // l'itérateur.
                //
                // Ce test est fait AVANT le filtre mindepth : un dossier
                // sous mindepth doit quand même être traversé (mindepth
                // filtre les RÉSULTATS, pas la descente). NB : les
                // symlinks vers des dossiers ne sont pas suivis par
                // recursive_directory_iterator (comportement par défaut,
                // inchangé) ; leur appliquer disable_recursion_pending
                // est un no-op inoffensif.
                if (depth >= options.maxdepth && it->is_directory())
                {
                    it.disable_recursion_pending();
                }

                if (depth < options.mindepth || depth > options.maxdepth)
                {
                    continue;
                }

                if (matches_options(*it, options, compiled))
                {
                    callback(it->path());
                }
            }
        }
        catch (const std::exception &e)
        {
            return std::string(e.what());
        }
        catch (...)
        {
            return "unknown error";
        }

        return std::nullopt;
    }

} // namespace

int lua_find(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (argc < 1)
    {
        return luaL_error(L, "Expected at least one argument");
    }

    if (!lua_isstring(L, 1))
    {
        return luaL_error(L, "Expected a string as the first argument");
    }

    if (argc >= 2 && !lua_isnoneornil(L, 2) && !lua_istable(L, 2))
    {
        return luaL_error(
            L, "Expected a table or nil as the second argument");
    }

    std::string root = luaL_checkstring_without_nul(L, 1, "root");

    // opts est réellement facultatif : find(path) et find(path, nil)
    // utilisent les valeurs par défaut documentées.
    FindOptions options;
    if (argc >= 2 && lua_istable(L, 2))
    {
        // CORRECTIF Gemini (longjmp/C++) : parse_options ne fait plus de
        // luaL_error. On reçoit (ok, err_msg) et on remonte l'erreur via
        // push_fail() qui ne fait PAS de longjmp — donc FindOptions se
        // détruira proprement à la sortie de cette fonction.
        const char *parse_err = nullptr;
        if (!parse_options(L, 2, options, parse_err))
        {
            return push_fail(L, parse_err);
        }
    }

    lua_newtable(L);
    int result_index = lua_gettop(L);

    int file_index = 1;

    auto callback = [L, result_index, &file_index](const fs::path &path)
    {
        lua_pushstring(L, path.string().c_str());
        lua_rawseti(L, result_index, file_index++);
    };

    if (auto error_message = find(root, options, callback))
    {
        lua_pushnil(L);
        lua_pushstring(L, error_message->c_str());
        return 2;
    }

    lua_pushnil(L);
    return 2;
}
