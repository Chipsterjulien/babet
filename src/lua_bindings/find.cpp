#include "find.hpp"
#include "lua_utils.hpp"
#include "project_core/safe_glob.hpp"
#include <re2/re2.h>
#include <memory>
#include <cstdint>
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
#include <utility>

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
        std::string name;  // RE2 regex, full match on the basename
        std::string iname; // idem, case-insensitive
        std::string path;  // RE2 regex, searched on the full path
        std::string glob;       // bounded glob on the complete basename
        std::string iglob;      // idem, ASCII case-insensitive
        std::string path_glob;  // bounded glob on the complete generic path
        std::string path_iglob; // idem, ASCII case-insensitive
    };

    constexpr std::size_t kMaxRegexPatternBytes = 4096;
    constexpr std::int64_t kRegexMaxMemoryBytes = 1LL << 20;

    struct CompiledMatchers
    {
        std::unique_ptr<re2::RE2> name;
        std::unique_ptr<re2::RE2> iname;
        std::unique_ptr<re2::RE2> path;
        std::optional<babet::safe_glob::Pattern> glob;
        std::optional<babet::safe_glob::Pattern> iglob;
        std::optional<babet::safe_glob::Pattern> path_glob;
        std::optional<babet::safe_glob::Pattern> path_iglob;
    };

    std::optional<std::string>
    compile_regexes(const FindOptions &options, CompiledMatchers &compiled)
    {
        auto compile_one = [](const std::string &source,
                              bool case_insensitive,
                              std::unique_ptr<re2::RE2> &destination,
                              const char *option_name)
            -> std::optional<std::string>
        {
            if (source.empty())
            {
                return std::nullopt;
            }

            if (source.size() > kMaxRegexPatternBytes)
            {
                return std::string("find: '") + option_name +
                       "' regular expression exceeds the 4096-byte limit";
            }

            // Linux paths are byte strings and may contain non-UTF-8 bytes.
            // Latin-1 makes RE2 operate on every byte without rejecting such
            // filenames. The explicit memory budget bounds each compiled
            // expression and its DFA caches; RE2 falls back to its linear-time
            // NFA when the budget is exhausted.
            re2::RE2::Options regex_options;
            regex_options.set_encoding(re2::RE2::Options::EncodingLatin1);
            regex_options.set_case_sensitive(!case_insensitive);
            regex_options.set_log_errors(false);
            regex_options.set_max_mem(kRegexMaxMemoryBytes);

            auto regex = std::make_unique<re2::RE2>(source, regex_options);
            if (!regex->ok())
            {
                std::string message = std::string("find: invalid regular expression for '") +
                                      option_name + "': " + regex->error();
                if (!regex->error_arg().empty())
                {
                    message += " near '" + regex->error_arg() + "'";
                }
                return message;
            }

            destination = std::move(regex);
            return std::nullopt;
        };

        if (auto error = compile_one(options.name, false, compiled.name,
                                     "name"))
        {
            return error;
        }
        if (auto error = compile_one(options.iname, true, compiled.iname,
                                     "iname"))
        {
            return error;
        }
        return compile_one(options.path, false, compiled.path, "path");
    }

    std::optional<std::string>
    compile_globs(const FindOptions &options, CompiledMatchers &compiled)
    {
        auto compile_one = [](const std::string &source,
                              bool case_insensitive,
                              std::optional<babet::safe_glob::Pattern> &dest,
                              const char *option_name)
            -> std::optional<std::string>
        {
            if (source.empty())
            {
                return std::nullopt;
            }

            babet::safe_glob::Pattern pattern;
            if (auto error = babet::safe_glob::compile(
                    source, case_insensitive, pattern))
            {
                return std::string("find: invalid '") + option_name +
                       "': " + *error;
            }
            dest.emplace(std::move(pattern));
            return std::nullopt;
        };

        if (auto error = compile_one(options.glob, false, compiled.glob,
                                     "glob"))
        {
            return error;
        }
        if (auto error = compile_one(options.iglob, true, compiled.iglob,
                                     "iglob"))
        {
            return error;
        }
        if (auto error = compile_one(options.path_glob, false,
                                     compiled.path_glob, "path_glob"))
        {
            return error;
        }
        return compile_one(options.path_iglob, true, compiled.path_iglob,
                           "path_iglob");
    }

    bool matches_options(const fs::directory_entry &entry,
                         const FindOptions &options,
                         const CompiledMatchers &compiled)
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
            !re2::RE2::FullMatch(entry.path().filename().string(),
                                 *compiled.name))
        {
            return false;
        }
        if (compiled.iname &&
            !re2::RE2::FullMatch(entry.path().filename().string(),
                                 *compiled.iname))
        {
            return false;
        }
        if (compiled.path &&
            !re2::RE2::PartialMatch(entry.path().string(), *compiled.path))
        {
            return false;
        }

        if (compiled.glob || compiled.iglob)
        {
            const std::string basename = entry.path().filename().string();
            if (compiled.glob && !compiled.glob->matches(basename))
            {
                return false;
            }
            if (compiled.iglob && !compiled.iglob->matches(basename))
            {
                return false;
            }
        }

        if (compiled.path_glob || compiled.path_iglob)
        {
            const std::string generic_path = entry.path().generic_string();
            if (compiled.path_glob &&
                !compiled.path_glob->matches(generic_path))
            {
                return false;
            }
            if (compiled.path_iglob &&
                !compiled.path_iglob->matches(generic_path))
            {
                return false;
            }
        }
        return true;
    }

    // Option parsing is deliberately non-throwing from Lua's point of
    // view: no luaL_error is called while FindOptions owns C++ strings.
    // Validation failures are returned as text and become (nil, err) in the
    // public binding, so every C++ destructor still runs normally.
    bool parse_options(lua_State *L, int index, FindOptions &out,
                       std::string &err)
    {
        index = lua_absindex(L, index);

        auto read_optional_integer = [&](const char *field,
                                         lua_Integer &destination) -> bool
        {
            lua_getfield(L, index, field);
            if (!lua_is_optional_strict_integer(L, -1))
            {
                err = std::string("find: '") + field +
                      "' must be an integer";
                lua_pop(L, 1);
                return false;
            }
            if (lua_is_strict_integer(L, -1))
            {
                destination = lua_tointeger(L, -1);
            }
            lua_pop(L, 1);
            return true;
        };

        auto read_optional_string = [&](const char *field,
                                        std::string &destination) -> bool
        {
            lua_getfield(L, index, field);
            if (lua_is_none_or_nil(L, -1))
            {
                lua_pop(L, 1);
                return true;
            }

            const std::string label = std::string("find: '") + field + "'";
            const bool ok = lua_string_without_nul(
                L, -1, destination, label, err);
            lua_pop(L, 1);
            return ok;
        };

        // A non-integer depth must never be truncated silently by
        // lua_tointeger().  Both fields retain their documented lua_Integer
        // range and default values.
        if (!read_optional_integer("mindepth", out.mindepth) ||
            !read_optional_integer("maxdepth", out.maxdepth) ||
            !read_optional_string("type", out.type))
        {
            return false;
        }

        if (!out.type.empty() && out.type != "f" && out.type != "d")
        {
            err = "find: 'type' must be \"f\" or \"d\"";
            return false;
        }

        return read_optional_string("name", out.name) &&
               read_optional_string("iname", out.iname) &&
               read_optional_string("path", out.path) &&
               read_optional_string("glob", out.glob) &&
               read_optional_string("iglob", out.iglob) &&
               read_optional_string("path_glob", out.path_glob) &&
               read_optional_string("path_iglob", out.path_iglob);
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

        CompiledMatchers compiled;
        if (auto regex_error = compile_regexes(options, compiled); regex_error)
        {
            return regex_error;
        }
        if (auto glob_error = compile_globs(options, compiled); glob_error)
        {
            return glob_error;
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
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L, "Expected one or two arguments");
    }

    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as the first argument");
    }

    if (!lua_is_none_or_nil(L, 2) && !lua_istable(L, 2))
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
        std::string parse_err;
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
