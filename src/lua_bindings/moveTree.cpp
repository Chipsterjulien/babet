#include "moveTree.hpp"
#include "lua_utils.hpp"
#include "nofollow_path.hpp"
#include "secure_destination.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <system_error>
#include <utility>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
    struct TreeEntry
    {
        fs::path source_path;
        fs::path relative_path;
        struct stat identity{};
    };

    struct SymlinkMapping
    {
        fs::path relative_path;
        fs::path target;
        struct stat identity{};
    };

    struct TreeScan
    {
        std::vector<TreeEntry> directories;
        std::vector<TreeEntry> movable_entries;
        std::vector<SymlinkMapping> symlinks;
        bool has_retargeted_symlink = false;
    };

    // `candidate` est-il `base` lui-même, ou strictement dessous ?
    // Comparaison par COMPOSANT (et non par préfixe de chaîne).
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

    std::string traversal_error(const fs::path &path,
                                const std::error_code &ec)
    {
        return "cannot read directory '" + path.string() + "': " +
               ec.message();
    }

    std::size_t relative_depth(const fs::path &base, const fs::path &path)
    {
        fs::path relative = path.lexically_relative(base);
        return static_cast<std::size_t>(
            std::distance(relative.begin(), relative.end()));
    }

    // Parcours explicite sans skip_permission_denied : moveTree ne doit
    // jamais annoncer un succès après avoir ignoré une partie de source.
    // Le scan se fait AVANT toute modification afin de détecter les erreurs
    // de parcours et de préparer les liens symboliques transactionnellement.
    std::string scan_tree(const fs::path &source,
                          const fs::path &source_real,
                          const fs::path &destination_real,
                          TreeScan &scan)
    {
        std::vector<fs::path> pending_directories;
        pending_directories.push_back(source);

        while (!pending_directories.empty())
        {
            fs::path current = std::move(pending_directories.back());
            pending_directories.pop_back();

            std::error_code ec;
            fs::directory_iterator it(current, fs::directory_options::none,
                                      ec);
            if (ec)
            {
                return traversal_error(current, ec);
            }

            const fs::directory_iterator end;
            while (it != end)
            {
                const fs::path path = it->path();
                struct stat status{};
                if (::lstat(path.c_str(), &status) != 0)
                {
                    return "cannot inspect '" + path.string() + "': " +
                           std::strerror(errno);
                }

                fs::path relative_path = path.lexically_relative(source);

                if (S_ISDIR(status.st_mode))
                {
                    scan.directories.push_back(
                        {path, relative_path, status});
                    pending_directories.push_back(path);
                }
                else if (S_ISLNK(status.st_mode))
                {
                    fs::path old_target = fs::read_symlink(path, ec);
                    if (ec)
                    {
                        return "cannot read symlink '" + path.string() +
                               "': " + ec.message();
                    }

                    fs::path new_target = old_target;
                    bool retargeted = false;

                    if (old_target.is_absolute())
                    {
                        std::error_code target_ec;
                        fs::path target_real =
                            fs::weakly_canonical(old_target, target_ec);
                        if (!target_ec && is_within(source_real, target_real))
                        {
                            new_target =
                                destination_real /
                                target_real.lexically_relative(source_real);
                            retargeted = (new_target != old_target);
                        }
                        // Cible non résoluble : on conserve le lien tel quel.
                    }

                    scan.symlinks.push_back(
                        {relative_path, new_target, status});
                    scan.has_retargeted_symlink =
                        scan.has_retargeted_symlink || retargeted;
                }
                else
                {
                    // Même périmètre qu'avant : tout ce qui n'est ni dossier
                    // ni symlink est déplacé via rename, avec fallback
                    // copy_file pour les fichiers traversant un filesystem.
                    scan.movable_entries.push_back(
                        {path, relative_path, status});
                }

                it.increment(ec);
                if (ec)
                {
                    return traversal_error(current, ec);
                }
            }
        }

        // Le parcours DFS ci-dessus rencontre normalement les parents avant
        // les enfants. Le tri explicite rend toutefois cet invariant évident
        // et indépendant de l'ordre d'énumération du filesystem.
        std::stable_sort(
            scan.directories.begin(), scan.directories.end(),
            [&source](const TreeEntry &a, const TreeEntry &b)
            {
                return relative_depth(source, a.source_path) <
                       relative_depth(source, b.source_path);
            });

        return "";
    }

    void rollback_created_symlinks(SecureDestination &destination,
                                    const std::vector<fs::path> &paths)
    {
        for (auto it = paths.rbegin(); it != paths.rend(); ++it)
        {
            destination.remove_entry_best_effort(*it);
        }
    }

    std::string remove_scanned_entry(const fs::path &path,
                                     const struct stat &scanned,
                                     bool directory)
    {
        struct stat current{};
        if (::lstat(path.c_str(), &current) != 0)
        {
            return "cannot inspect source entry before cleanup '" +
                   path.string() + "': " + std::strerror(errno);
        }
        // Never knowingly unlink a file/link substituted after the scan.
        // This is a consistency check, not a filesystem-wide transaction.
        if (current.st_dev != scanned.st_dev ||
            current.st_ino != scanned.st_ino ||
            (current.st_mode & S_IFMT) != (scanned.st_mode & S_IFMT))
        {
            return "source entry changed during move: '" + path.string() + "'";
        }

        // rmdir, unlike remove_all, preserves every untransferred entry that
        // appeared after the scan. ENOTEMPTY is an error, never a reason to
        // retry recursively. unlink removes only the scanned symlink itself.
        const int rc = directory ? ::rmdir(path.c_str()) : ::unlink(path.c_str());
        if (rc != 0)
        {
            return "cannot remove source entry '" + path.string() +
                   "': " + std::strerror(errno);
        }
        return "";
    }
} // namespace

/**
 * @brief Moves a directory tree from the source path to the destination path.
 *
 * Stratégie :
 *   1. Valider et scanner entièrement la source avant toute modification.
 *   2. Utiliser fs::rename sur le dossier entier seulement si la destination
 *      n'existe pas ET qu'aucun lien absolu interne ne doit être réécrit.
 *      Le chemin rapide produit ainsi exactement la même sémantique que le
 *      fallback.
 *   3. Fallback fusion/cross-device :
 *      - créer les dossiers de destination ;
 *      - créer tous les symlinks AVANT de supprimer ceux de la source ;
 *      - déplacer les autres entrées ;
 *      - supprimer les liens scannés, puis les dossiers devenus vides.
 *
 * Si la création d'un symlink échoue, les symlinks déjà créés par cet appel
 * sont retirés et la source n'a encore subi aucune modification.
 */
std::string moveTree(const fs::path &source, const fs::path &destination)
{
    // Validations préalables.
    const fs::path source_nofollow = nofollow_final_component_path(source);
    struct stat source_status{};
    if (::lstat(source_nofollow.c_str(), &source_status) != 0)
    {
        if (errno == ENOENT)
        {
            return "source path does not exist: " + source.string();
        }
        return "cannot inspect source path '" + source.string() +
               "': " + std::strerror(errno);
    }
    if (S_ISLNK(source_status.st_mode))
    {
        return "source root must not be a symlink: '" + source.string() + "'";
    }
    if (!S_ISDIR(source_status.st_mode))
    {
        return "source path is not a directory: " + source.string();
    }

    // Chemins réels pour les gardes et le retarget des liens absolus.
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
        return "destination cannot be an ancestor of source: '" +
               destination.string() + "' contains '" + source.string() + "'";
    }

    const fs::path destination_nofollow =
        nofollow_final_component_path(destination);
    std::error_code dst_ec;
    fs::file_status destination_status =
        fs::symlink_status(destination_nofollow, dst_ec);
    if (dst_ec && dst_ec != std::errc::no_such_file_or_directory)
    {
        return "cannot inspect destination path '" + destination.string() +
               "': " + dst_ec.message();
    }
    if (!dst_ec && fs::is_symlink(destination_status))
    {
        return "destination root must not be a symlink: '" +
               destination.string() + "'";
    }
    bool destination_exists =
        !dst_ec && fs::exists(destination_status);

    TreeScan scan;
    if (std::string err = scan_tree(source_nofollow, source_real,
                                    destination_real, scan);
        !err.empty())
    {
        return err;
    }

    // Chemin rapide cohérent : il n'est autorisé que si aucun lien ne
    // nécessite de changement de cible. Les liens relatifs, cassés ou
    // absolus extérieurs sont alors préservés à l'identique dans les deux
    // stratégies.
    if (!destination_exists && !scan.has_retargeted_symlink)
    {
        std::error_code rename_ec;
        fs::rename(source_nofollow, destination, rename_ec);
        if (!rename_ec)
        {
            return "";
        }
        if (rename_ec != std::errc::cross_device_link)
        {
            return "cannot move '" + source.string() + "' to '" +
                   destination.string() + "': " + rename_ec.message();
        }
        // EXDEV : poursuivre avec le fallback entrée par entrée.
    }

    SecureDestination secure_destination;
    if (auto secure_error = secure_destination.open_root(destination);
        secure_error)
    {
        return *secure_error;
    }

    for (const TreeEntry &entry : scan.directories)
    {
        if (auto directory_error =
                secure_destination.ensure_directory(entry.relative_path);
            directory_error)
        {
            return *directory_error;
        }
    }

    // Tous les liens sont créés avant le premier déplacement de fichier.
    // Ainsi, une collision ou une permission insuffisante ne détruit jamais
    // le lien original. On retire nos créations si la phase échoue.
    std::vector<fs::path> created_symlinks;
    created_symlinks.reserve(scan.symlinks.size());

    for (const SymlinkMapping &mapping : scan.symlinks)
    {
        if (auto symlink_error = secure_destination.create_symlink(
                mapping.target, mapping.relative_path);
            symlink_error)
        {
            rollback_created_symlinks(secure_destination,
                                      created_symlinks);
            return *symlink_error;
        }
        created_symlinks.push_back(mapping.relative_path);
    }

    for (const TreeEntry &entry : scan.movable_entries)
    {
        if (auto move_error = secure_destination.move_entry(
                entry.source_path, entry.relative_path);
            move_error)
        {
            // À ce stade certains fichiers peuvent déjà avoir été déplacés.
            // Ne pas retirer les symlinks destination : cela aggraverait
            // l'état partiel et pourrait supprimer le seul lien utile côté
            // destination. Les liens source restent présents jusqu'au
            // nettoyage final des seuls liens et dossiers scannés.
            return *move_error;
        }
    }

    // Do not sweep the current tree: it may now contain files that were never
    // transferred. Remove only known symlinks, then empty directories in
    // reverse depth order. Any new entry makes rmdir fail without deleting it.
    for (const SymlinkMapping &mapping : scan.symlinks)
    {
        if (auto err = remove_scanned_entry(
                source_nofollow / mapping.relative_path, mapping.identity, false);
            !err.empty())
        {
            return err;
        }
    }
    for (auto it = scan.directories.rbegin(); it != scan.directories.rend(); ++it)
    {
        if (auto err = remove_scanned_entry(it->source_path, it->identity, true);
            !err.empty())
        {
            return err;
        }
    }

    return remove_scanned_entry(source_nofollow, source_status, true);
}

/**
 * @brief Lua binding for moveTree function.
 *
 * Lua usage: ok, err = babet.moveTree(source, destination)
 */
int lua_moveTree(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_string(L, 1) ||
        !lua_is_strict_string(L, 2))
    {
        return luaL_error(L, "Expected two strings as arguments");
    }

    const std::string_view source =
        luaL_checkstring_view_without_nul(L, 1, "source");
    const std::string_view destination =
        luaL_checkstring_view_without_nul(L, 2, "destination");

    std::string error_message =
        moveTree(fs::path(source), fs::path(destination));
    if (error_message.empty())
    {
        return push_ok(L);
    }
    return push_fail_protected(L, error_message);
}
