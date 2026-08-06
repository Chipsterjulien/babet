#include "find.hpp"
#include "lua_utils.hpp"
#include "project_core/safe_glob.hpp"
#include <re2/re2.h>
#include <memory>
#include <new>
#include <cstdint>
#include <climits>
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
#include <cerrno>
#include <sys/stat.h>

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
        bool xdev = false;       // do not descend into another st_dev
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
                         bool entry_is_regular,
                         bool entry_is_directory,
                         const FindOptions &options,
                         const CompiledMatchers &compiled)
    {
        if (!options.type.empty())
        {
            if ((options.type == "f" && !entry_is_regular) ||
                (options.type == "d" && !entry_is_directory))
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

        auto read_optional_boolean = [&](const char *field,
                                         bool &destination) -> bool
        {
            lua_getfield(L, index, field);
            if (lua_is_none_or_nil(L, -1))
            {
                lua_pop(L, 1);
                return true;
            }
            if (!lua_isboolean(L, -1))
            {
                err = std::string("find: '") + field +
                      "' must be a boolean";
                lua_pop(L, 1);
                return false;
            }
            destination = lua_toboolean(L, -1) != 0;
            lua_pop(L, 1);
            return true;
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
               read_optional_string("path_iglob", out.path_iglob) &&
               read_optional_boolean("xdev", out.xdev);
    }

    std::optional<std::string> find(
        const fs::path &root, const FindOptions &options,
        const std::function<void(const fs::path &)> &callback)
    {
        auto path_error = [](const char *operation, const fs::path &path,
                             const std::error_code &ec)
        {
            return std::string(operation) + " '" + path.string() +
                   "': " + ec.message();
        };

        std::error_code check_ec;
        const bool root_exists = fs::exists(root, check_ec);
        if (check_ec)
        {
            return path_error("cannot inspect path", root, check_ec);
        }
        if (!root_exists)
        {
            return "path does not exist: " + root.string();
        }

        const bool root_is_directory = fs::is_directory(root, check_ec);
        if (check_ec)
        {
            return path_error("cannot inspect path", root, check_ec);
        }
        if (!root_is_directory)
        {
            return "path is not a directory: " + root.string();
        }

        dev_t root_device = 0;
        if (options.xdev)
        {
            // stat() deliberately follows a final symlink accepted by the
            // historical root-directory contract. The resulting st_dev is
            // therefore the filesystem that directory_iterator will actually
            // traverse.
            struct stat root_stat{};
            if (::stat(root.c_str(), &root_stat) != 0)
            {
                const int stat_errno = errno;
                return "cannot inspect path '" + root.string() + "': " +
                       std::generic_category().message(stat_errno);
            }
            root_device = root_stat.st_dev;
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

        struct DirectoryFrame
        {
            fs::directory_iterator current;
            fs::directory_iterator end;
            lua_Integer depth = 0;
        };

        try
        {
            std::error_code root_iter_ec;
            fs::directory_iterator root_iterator(root, root_iter_ec);
            if (root_iter_ec)
            {
                return path_error("cannot traverse directory", root,
                                  root_iter_ec);
            }

            std::vector<DirectoryFrame> stack;
            stack.push_back(
                DirectoryFrame{std::move(root_iterator), {}, 0});

            while (!stack.empty())
            {
                DirectoryFrame &frame = stack.back();
                if (frame.current == frame.end)
                {
                    stack.pop_back();
                    continue;
                }

                // Copy the current entry and advance the parent iterator before
                // any descent. The parent therefore already points at the next
                // sibling when a child frame is pushed. A disappearing child
                // can then be skipped without losing the remaining siblings,
                // unlike recursive_directory_iterator whose failed increment
                // becomes end after an ENOENT descent race.
                const fs::directory_entry entry = *frame.current;
                const lua_Integer depth = frame.depth;
                const fs::path parent_path = entry.path().parent_path();

                std::error_code advance_ec;
                frame.current.increment(advance_ec);
                if (advance_ec)
                {
                    if (advance_ec == std::errc::no_such_file_or_directory)
                    {
                        // The directory represented by this frame disappeared.
                        // Its remaining entries no longer exist, but the parent
                        // frame (if any) is still valid and can continue.
                        stack.pop_back();
                        continue;
                    }
                    else
                    {
                        return path_error("cannot continue traversal in",
                                          parent_path, advance_ec);
                    }
                }

                std::error_code link_status_ec;
                const fs::file_status link_status =
                    entry.symlink_status(link_status_ec);
                if (link_status_ec)
                {
                    if (link_status_ec ==
                        std::errc::no_such_file_or_directory)
                    {
                        continue;
                    }
                    return path_error("cannot inspect path", entry.path(),
                                      link_status_ec);
                }
                const bool entry_is_symlink = fs::is_symlink(link_status);

                std::error_code target_status_ec;
                const fs::file_status target_status =
                    entry.status(target_status_ec);
                if (target_status_ec)
                {
                    if (target_status_ec ==
                        std::errc::no_such_file_or_directory)
                    {
                        if (!entry_is_symlink)
                        {
                            // The directory entry itself vanished after
                            // readdir. A dangling symlink remains a visible
                            // path, but a vanished non-symlink has nothing left
                            // to match or descend into.
                            continue;
                        }
                    }
                    else
                    {
                        return path_error("cannot inspect path", entry.path(),
                                          target_status_ec);
                    }
                }

                const bool entry_is_directory =
                    !target_status_ec && fs::is_directory(target_status);
                const bool entry_is_regular =
                    !target_status_ec && fs::is_regular_file(target_status);
                const bool may_descend =
                    entry_is_directory && !entry_is_symlink;

                bool crosses_device = false;
                if (options.xdev && may_descend)
                {
                    // lstat() observes the mounted inode of a real mount point
                    // while keeping directory symlinks non-followed. Only real
                    // directories can reach this branch because may_descend is
                    // false for symlinks.
                    struct stat entry_stat{};
                    if (::lstat(entry.path().c_str(), &entry_stat) != 0)
                    {
                        const int lstat_errno = errno;
                        if (lstat_errno == ENOENT)
                        {
                            continue;
                        }
                        return "cannot inspect path '" +
                               entry.path().string() + "': " +
                               std::generic_category().message(lstat_errno);
                    }
                    crosses_device = entry_stat.st_dev != root_device;
                }

                if (depth >= options.mindepth &&
                    depth <= options.maxdepth &&
                    matches_options(entry, entry_is_regular,
                                    entry_is_directory, options, compiled))
                {
                    callback(entry.path());
                }

                // The entry itself remains visible. Only descent into its
                // children is suppressed by maxdepth or xdev. Opening each
                // child through the error_code overload makes ENOENT a local
                // disappearance race: siblings remain available in the parent
                // frame and every other error stays fatal.
                if (may_descend && depth < options.maxdepth &&
                    !crosses_device)
                {
                    std::error_code child_ec;
                    fs::directory_iterator child(entry.path(), child_ec);
                    if (child_ec)
                    {
                        if (child_ec ==
                            std::errc::no_such_file_or_directory)
                        {
                            continue;
                        }
                        return path_error("cannot traverse directory",
                                          entry.path(), child_ec);
                    }

                    stack.push_back(DirectoryFrame{
                        std::move(child), {}, depth + 1});
                }
            }
        }
        catch (const std::bad_alloc &)
        {
            throw;
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

static int lua_find_impl(lua_State *L)
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
        // Le parseur remplit des std::string tout en consultant une table Lua.
        // Il s'exécute donc sous pcall : un OOM ou un __index fautif ne peut
        // pas longjmp par-dessus FindOptions ou parse_err.
        std::string parse_err;
        bool options_ok = false;
        auto parser = [&](lua_State *Ls)
        {
            options_ok = parse_options(Ls, 2, options, parse_err);
        };
        lua_run_protected(L, parser);
        if (!options_ok)
        {
            return push_fail_protected(L, parse_err);
        }
    }

    std::vector<std::string> results;
    auto callback = [&results](const fs::path &path)
    {
        results.push_back(path.string());
    };

    if (auto error_message = find(root, options, callback))
    {
        return push_fail_protected(L, *error_message);
    }

    auto builder = [&results](lua_State *Ls) noexcept -> int
    {
        const int array_hint = results.size() <= static_cast<std::size_t>(INT_MAX)
                                   ? static_cast<int>(results.size())
                                   : 0;
        lua_createtable(Ls, array_hint, 0);
        lua_Integer index = 1;
        for (const std::string &path : results)
        {
            lua_pushlstring(Ls, path.data(), path.size());
            lua_rawseti(Ls, -2, index++);
        }
        lua_pushnil(Ls);
        return 2;
    };
    return lua_build_results_protected(L, builder, 2);
}

int lua_find(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_find_impl>(
        L, "find: out of memory", "find: internal failure",
        "find: unknown internal failure");
}
