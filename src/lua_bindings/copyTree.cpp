#include "copyTree.hpp"
#include "lua_utils.hpp"
#include "nofollow_path.hpp"
#include "secure_destination.hpp"

#include <iostream>
#include <system_error>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

namespace
{
    bool is_within(const fs::path &base, const fs::path &candidate)
    {
        auto rel = candidate.lexically_relative(base);
        if (rel.empty())
        {
            return false;
        }
        if (rel == fs::path("."))
        {
            return true;
        }
        auto it = rel.begin();
        return it != rel.end() && *it != fs::path("..");
    }

    bool report_copy_problem(const std::string &message,
                             bool continue_on_error,
                             bool &has_warnings,
                             std::optional<std::string> &fatal_error)
    {
        if (continue_on_error)
        {
            std::cerr << "warning: " << message << '\n';
            has_warnings = true;
            return true;
        }

        fatal_error = message;
        return false;
    }
} // namespace

/**
 * @brief Recursively copies a directory and its contents.
 *
 * Le parcours est explicite, sans skip_permission_denied. Chaque dossier
 * inaccessible produit donc soit une erreur immédiate, soit un warning réel
 * en mode continue_on_error. La fonction ne peut plus annoncer un succès
 * silencieux après avoir omis une branche de l'arborescence.
 */
std::optional<std::string>
copy_directory(const fs::path &source, const fs::path &destination,
               bool continue_on_error)
{
    std::vector<std::pair<fs::path, fs::path>> symlink_mappings;
    std::error_code ec;
    bool has_warnings = false;

    // A trailing slash (or terminal /.) makes POSIX follow a final symlink
    // before symlink_status sees it.  Strip only those terminal spellings so
    // the documented "source root must not be a symlink" guard cannot be
    // bypassed with e.g. "link/".
    const fs::path source_nofollow = nofollow_final_component_path(source);
    std::error_code src_ec;
    const fs::file_status source_status =
        fs::symlink_status(source_nofollow, src_ec);
    if (src_ec == std::errc::no_such_file_or_directory)
    {
        return "source directory does not exist: " + source.string();
    }
    if (src_ec)
    {
        return "cannot inspect source directory '" + source.string() +
               "': " + src_ec.message();
    }
    if (fs::is_symlink(source_status))
    {
        return "source root must not be a symlink: '" + source.string() + "'";
    }
    if (!fs::is_directory(source_status))
    {
        return "source is not a directory: " + source.string();
    }

    std::error_code wc_ec;
    fs::path source_real = fs::weakly_canonical(source, wc_ec);
    if (wc_ec)
    {
        return "cannot resolve source path '" + source.string() +
               "': " + wc_ec.message();
    }

    fs::path destination_real = fs::weakly_canonical(destination, wc_ec);
    if (wc_ec)
    {
        return "cannot resolve destination path '" + destination.string() +
               "': " + wc_ec.message();
    }

    if (is_within(source_real, destination_real))
    {
        return "destination cannot be inside source: '" +
               destination.string() + "' resolves inside '" +
               source.string() + "'";
    }
    if (is_within(destination_real, source_real))
    {
        // Merging into an ancestor can overwrite a source entry before it
        // has been copied. Reject before creating or changing any destination.
        return "destination cannot be an ancestor of source: '" +
               destination.string() + "' contains '" + source.string() + "'";
    }

    SecureDestination secure_destination;
    if (auto secure_error = secure_destination.open_root(destination);
        secure_error)
    {
        return secure_error;
    }

    std::vector<fs::path> pending_directories;
    pending_directories.push_back(source);

    try
    {
        while (!pending_directories.empty())
        {
            fs::path current = std::move(pending_directories.back());
            pending_directories.pop_back();

            fs::directory_iterator it(current, fs::directory_options::none,
                                      ec);
            if (ec)
            {
                std::optional<std::string> fatal_error;
                std::string message = "cannot read directory '" +
                                      current.string() + "': " +
                                      ec.message();
                ec.clear();
                if (!report_copy_problem(message, continue_on_error,
                                         has_warnings, fatal_error))
                {
                    return fatal_error;
                }
                continue;
            }

            const fs::directory_iterator end;
            while (it != end)
            {
                const fs::path path = it->path();
                fs::file_status status = it->symlink_status(ec);
                if (ec)
                {
                    std::optional<std::string> fatal_error;
                    std::string message = "cannot inspect '" +
                                          path.string() + "': " +
                                          ec.message();
                    ec.clear();
                    if (!report_copy_problem(message, continue_on_error,
                                             has_warnings, fatal_error))
                    {
                        return fatal_error;
                    }
                }
                else
                {
                    fs::path relative_path =
                        path.lexically_relative(source);

                    if (fs::is_directory(status) &&
                        !fs::is_symlink(status))
                    {
                        if (auto directory_error =
                                secure_destination.ensure_directory(relative_path);
                            directory_error)
                        {
                            std::optional<std::string> fatal_error;
                            if (!report_copy_problem(
                                    *directory_error, continue_on_error,
                                    has_warnings, fatal_error))
                            {
                                return fatal_error;
                            }
                            // Ne pas parcourir une branche dont la destination
                            // sûre n'a pas pu être créée.
                        }
                        else
                        {
                            pending_directories.push_back(path);
                        }
                    }
                    else if (fs::is_regular_file(status))
                    {
                        if (auto copy_error =
                                secure_destination.copy_regular_file(
                                    path, relative_path);
                            copy_error)
                        {
                            std::optional<std::string> fatal_error;
                            if (!report_copy_problem(
                                    *copy_error, continue_on_error,
                                    has_warnings, fatal_error))
                            {
                                return fatal_error;
                            }
                        }
                    }
                    else if (fs::is_symlink(status))
                    {
                        fs::path old_target = fs::read_symlink(path, ec);
                        if (ec)
                        {
                            std::optional<std::string> fatal_error;
                            std::string message =
                                "cannot read symlink '" + path.string() +
                                "': " + ec.message();
                            ec.clear();
                            if (!report_copy_problem(
                                    message, continue_on_error, has_warnings,
                                    fatal_error))
                            {
                                return fatal_error;
                            }
                        }
                        else
                        {
                            fs::path new_target = old_target;
                            if (old_target.is_absolute())
                            {
                                std::error_code target_ec;
                                fs::path target_real =
                                    fs::weakly_canonical(old_target,
                                                         target_ec);
                                if (!target_ec &&
                                    is_within(source_real, target_real))
                                {
                                    new_target =
                                        destination_real /
                                        target_real.lexically_relative(
                                            source_real);
                                }
                            }
                            symlink_mappings.emplace_back(relative_path,
                                                          new_target);
                        }
                    }
                    else
                    {
                        std::optional<std::string> fatal_error;
                        std::string message =
                            "unknown file type: " + path.string();
                        if (!report_copy_problem(message, continue_on_error,
                                                 has_warnings, fatal_error))
                        {
                            return fatal_error;
                        }
                    }
                }

                it.increment(ec);
                if (ec)
                {
                    std::optional<std::string> fatal_error;
                    std::string message = "cannot continue reading directory '" +
                                          current.string() + "': " +
                                          ec.message();
                    ec.clear();
                    if (!report_copy_problem(message, continue_on_error,
                                             has_warnings, fatal_error))
                    {
                        return fatal_error;
                    }
                    // Après une erreur d'incrément, l'état de l'itérateur
                    // n'est plus exploitable de façon portable : on abandonne
                    // ce dossier, mais les autres dossiers déjà empilés seront
                    // encore traités en mode continue_on_error.
                    break;
                }
            }
        }

        for (const auto &[relative_symlink, target] : symlink_mappings)
        {
            if (auto symlink_error =
                    secure_destination.create_symlink(target,
                                                      relative_symlink);
                symlink_error)
            {
                std::optional<std::string> fatal_error;
                if (!report_copy_problem(*symlink_error, continue_on_error,
                                         has_warnings, fatal_error))
                {
                    return fatal_error;
                }
            }
        }
    }
    catch (const fs::filesystem_error &e)
    {
        return "cannot copy directory: " + std::string(e.what());
    }

    if (has_warnings)
    {
        return "completed with warnings (see stderr for details)";
    }

    return std::nullopt;
}

int lua_copyTree(lua_State *L)
{
    if (!lua_arity_between(L, 2, 3) ||
        !lua_is_strict_string(L, 1) ||
        !lua_is_strict_string(L, 2))
    {
        return luaL_error(
            L,
            "Expected two string arguments and an optional boolean");
    }
    if (!lua_is_optional_strict_boolean(L, 3))
    {
        return luaL_error(L,
                          "continue_on_error must be a boolean or nil");
    }

    const std::string_view src_path =
        luaL_checkstring_view_without_nul(L, 1, "source");
    const std::string_view dest_path =
        luaL_checkstring_view_without_nul(L, 2, "destination");

    bool continue_on_error = true;
    if (lua_is_strict_boolean(L, 3))
    {
        continue_on_error = lua_toboolean(L, 3);
    }

    return push_action_result_protected(
        L, copy_directory(src_path, dest_path, continue_on_error));
}
