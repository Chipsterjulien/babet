#include "moveTree.hpp"
#include "lua_utils.hpp"
#include <system_error>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

namespace
{
    // `candidate` est-il `base` lui-même, ou strictement dessous ?
    // Comparaison par COMPOSANT (et non par préfixe de chaîne) : un
    // premier composant "..data" / "..." commence par ".." sans être
    // le parent "..". Un rfind("..",0) le classerait à tort hors base
    // et désactiverait le garde -> trou de sécurité. rel == "."
    // (candidate == base) -> true (voulu : refus dest==source ; et
    // destination_real / "." == destination_real, inoffensif au
    // retarget).
    //
    // (Dupliqué à l'identique dans copyTree.cpp — stratégie symlink
    // partagée volontairement ; voir le commentaire détaillé là-bas.)
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
} // namespace

/**
 * @brief Moves a directory tree from the source path to the destination path.
 *
 * Stratégie :
 *   1. On tente fs::rename atomique sur le dossier entier (O(1) sur la
 *      même partition, instantané même pour des arbres énormes).
 *   2. Si EXDEV (partitions différentes) ou destination existante, on
 *      bascule sur un fallback récursif :
 *      - dossiers : create_directories en destination
 *      - fichiers réguliers : tente fs::rename, et en cas d'EXDEV bascule
 *        sur copy_file + remove pour passer la frontière de filesystem
 *      - symlinks : recréés dans la destination en post-pass. La cible est
 *        retargetée uniquement si elle est absolue ET pointait à l'intérieur
 *        de l'arbre source ; sinon elle est conservée telle quelle. Un lien
 *        relatif reste donc valide après le déplacement si et seulement si
 *        sa cible bouge avec lui (typiquement : cible dans le même arbre,
 *        ou cible extérieure à source dont le chemin reste atteignable).
 *      - source : remove_all en fin de parcours
 *
 * Refuse explicitement les cas où la destination est dans l'arbre source
 * (par exemple moveTree("src", "src/backup")), qui produiraient un parcours
 * récursif corrompu.
 *
 * @param source The source path of the directory tree to move.
 * @param destination The destination path where the directory tree will be moved.
 * @return An error message if any, or an empty string if successful.
 */
std::string moveTree(const fs::path &source, const fs::path &destination)
{
    std::error_code ec;

    // Validations préalables.
    std::error_code src_ec;
    if (!fs::exists(source, src_ec))
    {
        return "source path does not exist: " + source.string();
    }
    if (!fs::is_directory(source, src_ec))
    {
        return "source path is not a directory: " + source.string();
    }

    // Chemins RÉELS (symlinks résolus), pas seulement normalisés
    // lexicalement — même raisonnement que copyTree : sans ça, une
    // destination ou une cible de lien atteignant physiquement source
    // via un lien échapperait aux gardes (lexically_normal ne suit
    // aucun lien). weakly_canonical résout la partie existante (liens
    // suivis) + reste lexical : la destination n'existe pas forcément.
    // TOCTOU : résolution au moment du contrôle, fenêtre réduite non
    // fermée. (Voir copyTree.cpp pour le détail du raisonnement.)
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

    // Garde : refuser destination == source ou destination ⊂ source
    // (chemins réels, comparaison par composant via is_within). Sans
    // ça, le parcours récursif rencontrerait la destination créée à
    // l'intérieur -> corruption.
    if (is_within(source_real, destination_real))
    {
        return "destination cannot be inside source: '" +
               destination.string() + "' resolves inside '" +
               source.string() + "'";
    }

    // --- Chemin rapide : rename atomique du dossier entier ----------
    // Sur la même partition, fs::rename est instantané (un seul syscall).
    // On ne le tente que si la destination n'existe PAS : sinon le fallback
    // ci-dessous implémente une fusion entrée par entrée, comportement que
    // fs::rename ne sait pas faire.
    std::error_code dst_ec;
    if (!fs::exists(destination, dst_ec))
    {
        fs::rename(source, destination, ec);
        if (!ec)
        {
            return ""; // Succès, terminé en O(1).
        }
        if (ec != std::errc::cross_device_link)
        {
            // Erreur autre qu'EXDEV : pas la peine d'essayer le fallback,
            // il échouera pareil (permissions, chemin invalide, etc.).
            return "cannot move '" + source.string() + "' to '" +
                   destination.string() + "': " + ec.message();
        }
        // ec == EXDEV : source et destination sur partitions différentes.
        // On bascule sur le fallback, qui gère le cross-device fichier
        // par fichier via copy_file + remove.
        ec.clear();
    }

    // --- Fallback : déplacement entrée par entrée -------------------
    // Couvre deux cas : (a) destination existe déjà = fusion, (b) source
    // et destination sur des partitions différentes = cross-device.

    std::vector<std::pair<fs::path, fs::path>> symlink_mappings;

    fs::create_directories(destination, ec);
    if (ec)
    {
        return "cannot create destination directory: " + ec.message();
    }

    try
    {
        for (const auto &entry : fs::recursive_directory_iterator(source, fs::directory_options::skip_permission_denied))
        {
            const auto &path = entry.path();
            // PURE lexical, surtout PAS fs::relative : ce dernier résout
            // les symlinks (weakly_canonical des deux côtés). Pour une
            // entrée symlink il renverrait le relatif de la cible et non
            // du lien -> arbre reconstruit faux. L'itérateur fournit
            // path = source/... littéral. (Même raisonnement que
            // copyTree.cpp, voir le commentaire détaillé là-bas.)
            fs::path relative_path = path.lexically_relative(source);
            fs::path dest_path = destination / relative_path;

            auto file_status = fs::symlink_status(path);

            if (fs::is_directory(file_status) && !fs::is_symlink(file_status))
            {
                fs::create_directories(dest_path, ec);
                if (ec)
                {
                    return "cannot create directory '" + dest_path.string() + "': " + ec.message();
                }
            }
            else if (fs::is_symlink(file_status))
            {
                fs::path old_target = fs::read_symlink(path);
                fs::path new_target = old_target;

                if (old_target.is_absolute())
                {
                    // Cible réelle (liens résolus) vs source_real :
                    // reconnaît une cible atteignant source via un lien.
                    std::error_code tec;
                    fs::path target_real = fs::weakly_canonical(old_target, tec);
                    if (!tec)
                    {
                        if (is_within(source_real, target_real))
                        {
                            new_target = destination_real /
                                         target_real.lexically_relative(source_real);
                        }
                    }
                    // tec non nul = cible non résoluble (boucle, accès) :
                    // on conserve old_target tel quel (décision actée :
                    // un lien cassé reste déplacé à l'identique).
                }

                symlink_mappings.emplace_back(dest_path, new_target);
            }
            else
            {
                // Fichier régulier : on tente le rename rapide d'abord.
                fs::rename(path, dest_path, ec);
                if (ec == std::errc::cross_device_link)
                {
                    // Cross-device : copier puis supprimer.
                    ec.clear();
                    fs::copy_file(path, dest_path,
                                  fs::copy_options::overwrite_existing, ec);
                    if (ec)
                    {
                        return "cannot copy '" + path.string() + "' to '" +
                               dest_path.string() + "': " + ec.message();
                    }
                    fs::remove(path, ec);
                    if (ec)
                    {
                        return "cannot remove source file '" + path.string() +
                               "' after copy: " + ec.message();
                    }
                }
                else if (ec)
                {
                    return "cannot move '" + path.string() + "' to '" + dest_path.string() + "': " + ec.message();
                }
            }
        }

        // Supprime l'arborescence source résiduelle (dossiers vides + symlinks).
        fs::remove_all(source, ec);
        if (ec)
        {
            return "cannot remove source directory '" + source.string() + "': " + ec.message();
        }

        // Recrée les symlinks dans la destination.
        for (const auto &[dest_symlink, target] : symlink_mappings)
        {
            fs::create_symlink(target, dest_symlink, ec);
            if (ec)
            {
                return "cannot create symlink '" + dest_symlink.string() +
                       "' -> '" + target.string() + "': " + ec.message();
            }
        }
    }
    catch (const fs::filesystem_error &e)
    {
        return std::string(e.what());
    }

    return "";
}

/**
 * @brief Lua binding for moveTree function.
 *
 * Lua usage: ok, err = babet.moveTree(source, destination)
 *
 * @param L Lua state.
 * @return int Number of return values on the Lua stack (2: ok/nil, err/nil).
 */
int lua_moveTree(lua_State *L)
{
    if (lua_gettop(L) != 2 || !lua_isstring(L, 1) || !lua_isstring(L, 2))
    {
        return luaL_error(L, "Expected two strings as arguments");
    }

    const char *source = luaL_checkstring(L, 1);
    const char *destination = luaL_checkstring(L, 2);

    std::string error_message = moveTree(source, destination);
    if (error_message.empty())
    {
        return push_ok(L);
    }
    return push_fail(L, error_message);
}
