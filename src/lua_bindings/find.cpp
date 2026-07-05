#include "find.hpp"
#include "lua_utils.hpp"
#include <regex>
#include <limits>
#include <system_error>
#include <algorithm>
#include <filesystem>
#include <string>
#include <vector>
#include <iostream>
#include <optional>
#include <functional>
#include <unordered_map>

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

    struct RegexCache
    {
        std::unordered_map<std::string, std::regex> name_regex;
        std::unordered_map<std::string, std::regex> iname_regex;
    };

    // CORRECTIF (post-revue Gemini) : depuis l'arrivée des workers
    // (Chantier 8), plusieurs threads peuvent appeler babet.find
    // simultanément. Un cache global non protégé corromprait la map
    // sur un try_emplace concurrent. La solution thread_local donne
    // à chaque worker son propre cache, sans surcoût de mutex.
    thread_local RegexCache cache;

    // Les patterns sont passés tels quels à std::regex, en syntaxe ECMAScript
    // (équivalent à la regex PCRE habituelle : \d, \w, [a-zA-Z], etc.).
    // Pas de pré-traitement type "Lua pattern" : la pseudo-traduction des `%`
    // était un faux-ami qui produisait silencieusement des regex incorrectes
    // (`%a` devenait `\a` = caractère BEL, pas une classe de lettres).
    const std::regex &get_or_compile_regex(RegexCache &cache, const std::string &pattern,
                                           bool case_insensitive = false)
    {
        auto &regex_map = case_insensitive ? cache.iname_regex : cache.name_regex;
        auto it = regex_map.find(pattern);
        if (it == regex_map.end())
        {
            std::regex_constants::syntax_option_type flags = std::regex_constants::ECMAScript;
            if (case_insensitive)
            {
                flags |= std::regex_constants::icase;
            }
            auto [new_it, _] = regex_map.try_emplace(pattern, std::regex(pattern, flags));
            return new_it->second;
        }
        return it->second;
    }

    bool matches_options(const fs::directory_entry &entry, const FindOptions &options,
                         RegexCache &cache)
    {
        if (!options.type.empty())
        {
            if ((options.type == "f" && !fs::is_regular_file(entry)) ||
                (options.type == "d" && !fs::is_directory(entry)))
            {
                return false;
            }
        }

        if (!options.name.empty())
        {
            const auto &name_regex = get_or_compile_regex(cache, options.name);
            if (!std::regex_match(entry.path().filename().string(), name_regex))
            {
                return false;
            }
        }

        if (!options.iname.empty())
        {
            const auto &iname_regex = get_or_compile_regex(cache, options.iname, true);
            if (!std::regex_match(entry.path().filename().string(), iname_regex))
            {
                return false;
            }
        }

        if (!options.path.empty())
        {
            // Note : pas de cache pour `path` (peu de répétition attendue,
            // contrairement à `name` qui filtre des milliers d'entrées).
            const std::regex path_regex(options.path, std::regex_constants::ECMAScript);
            if (!std::regex_search(entry.path().string(), path_regex))
            {
                return false;
            }
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
        lua_getfield(L, index, "mindepth");
        if (lua_isnumber(L, -1))
        {
            out.mindepth = lua_tointeger(L, -1);
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'mindepth' must be a number";
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "maxdepth");
        if (lua_isnumber(L, -1))
        {
            out.maxdepth = lua_tointeger(L, -1);
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'maxdepth' must be a number";
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "type");
        if (lua_isstring(L, -1))
        {
            out.type = lua_tostring(L, -1);
        }
        else if (!lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            err = "find: 'type' must be a string";
            return false;
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "name");
        if (lua_isstring(L, -1))
        {
            out.name = lua_tostring(L, -1);
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
            out.iname = lua_tostring(L, -1);
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
            out.path = lua_tostring(L, -1);
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

    std::optional<std::string> find(const fs::path &root, const FindOptions &options,
                                    std::function<void(const fs::path &)> callback,
                                    RegexCache &cache)
    {
        if (!fs::exists(root))
        {
            return "path does not exist: " + root.string();
        }

        if (!fs::is_directory(root))
        {
            return "path is not a directory: " + root.string();
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

                if (matches_options(*it, options, cache))
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
    int argc = lua_gettop(L);
    if (argc < 2)
    {
        return luaL_error(L, "Expected at least two arguments");
    }

    if (!lua_isstring(L, 1))
    {
        return luaL_error(L, "Expected a string as the first argument");
    }

    if (!lua_istable(L, 2))
    {
        return luaL_error(L, "Expected a table as the second argument");
    }

    const char *root = luaL_checkstring(L, 1);

    // CORRECTIF Gemini (longjmp/C++) : parse_options ne fait plus de
    // luaL_error. On reçoit (ok, err_msg) et on remonte l'erreur via
    // push_fail() qui ne fait PAS de longjmp — donc FindOptions se
    // détruira proprement à la sortie de cette fonction.
    FindOptions options;
    const char *parse_err = nullptr;
    if (!parse_options(L, 2, options, parse_err))
    {
        return push_fail(L, parse_err);
    }

    lua_newtable(L);
    int result_index = lua_gettop(L);

    int file_index = 1;

    auto callback = [L, result_index, &file_index](const fs::path &path)
    {
        lua_pushstring(L, path.string().c_str());
        lua_rawseti(L, result_index, file_index++);
    };

    if (auto error_message = find(root, options, callback, cache))
    {
        lua_pushnil(L);
        lua_pushstring(L, error_message->c_str());
        return 2;
    }

    lua_pushnil(L);
    return 2;
}
