#include "copyTree.hpp"
#include "lua_utils.hpp"
#include <vector>
#include <utility>
#include <system_error>
#include <iostream>

namespace fs = std::filesystem;

namespace
{
    // `candidate` est-il `base` lui-même, ou strictement dessous ?
    //
    // Comparaison par COMPOSANT, jamais par préfixe de chaîne : un
    // premier composant nommé "..data", "..." ou "..foo" commence par
    // les caractères ".." sans être le composant parent "..". Un test
    // du genre rel.native().rfind("..",0)==0 le rangerait à tort "hors
    // base" et désactiverait le garde -> trou de sécurité. On teste
    // donc *rel.begin().
    //
    // rel == "." (candidate == base) -> true, voulu aux deux usages :
    //   - garde dest-in-source : on refuse aussi destination == source
    //   - retarget symlink     : destination_real / "." vaut
    //                            destination_real, donc inoffensif.
    //
    // (Helper dupliqué à l'identique dans moveTree.cpp : les deux
    // fichiers partagent volontairement la stratégie symlink.)
    bool is_within(const fs::path &base, const fs::path &candidate)
    {
        auto rel = candidate.lexically_relative(base);
        if (rel.empty())
        {
            return false; // pas de racine commune -> hors base
        }
        if (rel == fs::path("."))
        {
            return true; // candidate == base
        }
        auto it = rel.begin();
        return it != rel.end() && *it != fs::path("..");
    }
} // namespace

/**
 * @brief Utility function to copy a single file.
 *
 * Important : ce helper retourne TOUJOURS l'erreur s'il y en a une.
 * C'est l'appelant (copy_directory) qui décide d'arrêter ou de continuer.
 * Cela permet à copy_directory de mettre à jour son flag has_warnings de
 * manière fiable quand on est en mode continue_on_error.
 *
 * @param source The source file path.
 * @param destination The destination file path.
 * @return std::optional<std::string> The error message if any, nullopt on success.
 */
std::optional<std::string> copy_file_with_error_handling(const fs::path &source, const fs::path &destination)
{
    std::error_code ec;
    fs::copy_file(source, destination, fs::copy_options::overwrite_existing, ec);
    if (ec)
    {
        return "cannot copy '" + source.string() + "' to '" + destination.string() + "': " + ec.message();
    }
    return std::nullopt;
}

/**
 * @brief Recursively copies a directory and its contents to a destination, handling symbolic links.
 *
 * Stratégie symlinks (alignée sur moveTree) :
 *   - on capture chaque symlink pendant le parcours, on le recrée en post-pass
 *   - la cible est retargetée vers `destination` UNIQUEMENT si elle est
 *     absolue ET pointait à l'intérieur de l'arbre source
 *   - sinon (relative, ou absolue extérieure à source), on conserve la
 *     cible telle quelle. Un lien relatif intra-source reste valide après
 *     copie si la relation relative entre le lien et sa cible est préservée.
 *
 * Refuse explicitement les cas où la destination est dans l'arbre source
 * (par exemple copyTree("src", "src/backup")), qui produiraient un parcours
 * infini ou des résultats corrompus.
 *
 * @param source The source directory to copy from.
 * @param destination The destination directory to copy to.
 * @param continue_on_error If true, warnings are logged on stderr for each
 *        problematic entry and the operation continues; if false, the first
 *        problem aborts and is returned as an error.
 * @return std::optional<std::string> The error message if any, nullopt on success.
 */
std::optional<std::string> copy_directory(const fs::path &source, const fs::path &destination, bool continue_on_error)
{
    std::vector<std::pair<fs::path, fs::path>> symlink_mappings;
    std::error_code ec;
    bool has_warnings = false;

    // Validations préalables.
    std::error_code src_ec;
    if (!fs::exists(source, src_ec))
    {
        return "source directory does not exist: " + source.string();
    }
    if (!fs::is_directory(source, src_ec))
    {
        return "source is not a directory: " + source.string();
    }

    // Chemins RÉELS (symlinks résolus), pas seulement normalisés
    // lexicalement : sans ça, une destination passant par un lien qui
    // mène physiquement dans source — ou une cible de symlink qui y
    // mène — échapperait aux gardes ci-dessous, car lexically_normal()
    // ne suit aucun lien.
    //
    // weakly_canonical résout la partie EXISTANTE du chemin (liens
    // suivis) et garde le reste, inexistant, normalisé lexicalement.
    // C'est le contrat voulu : la destination n'existe pas forcément
    // encore. Conséquence assumée : on protège contre une destination
    // qui *traverse* un lien menant dans source ; un lien créé plus
    // tard dans la partie encore inexistante n'est pas couvert (limite
    // inhérente, pas un oubli).
    //
    // Honnêteté TOCTOU : la résolution a lieu au moment de ce contrôle.
    // Entre ce contrôle et la copie effective, un lien peut encore être
    // modifié. La fenêtre est fortement réduite, pas fermée à 100 %.
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
    // (comparaison sur les chemins réels, par composant via is_within).
    // Sans ça, créer destination puis parcourir source rencontrerait la
    // destination qu'on vient de créer, avec boucle ou corruption.
    if (is_within(source_real, destination_real))
    {
        return "destination cannot be inside source: '" +
               destination.string() + "' resolves inside '" +
               source.string() + "'";
    }

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
            // PURE lexical, surtout PAS fs::relative : ce dernier équivaut
            // à weakly_canonical(path).lexically_relative(weakly_canonical(
            // source)), donc il RÉSOUT les symlinks. Pour une entrée qui
            // est elle-même un symlink (ou sous un parent symlink), il
            // renverrait le chemin relatif de la *cible*, pas du lien :
            // l'arborescence reconstruite serait fausse (collision, lien
            // mal placé). L'itérateur fournit toujours path = source/...
            // littéral, donc lexically_relative donne la structure exacte
            // sans suivre aucun lien — c'est ce qu'on veut ici.
            fs::path relative_path = path.lexically_relative(source);
            fs::path dest_path = destination / relative_path;

            auto file_status = fs::symlink_status(path);

            if (fs::is_directory(file_status) && !fs::is_symlink(file_status))
            {
                fs::create_directories(dest_path, ec);
                if (ec)
                {
                    std::string msg = "cannot create directory '" + dest_path.string() + "': " + ec.message();
                    if (continue_on_error)
                    {
                        std::cerr << "warning: " << msg << '\n';
                        has_warnings = true;
                        continue;
                    }
                    else
                    {
                        return msg;
                    }
                }
            }
            else if (fs::is_regular_file(file_status))
            {
                if (auto err = copy_file_with_error_handling(path, dest_path); err)
                {
                    if (continue_on_error)
                    {
                        std::cerr << "warning: " << *err << '\n';
                        has_warnings = true;
                        continue;
                    }
                    else
                    {
                        return err;
                    }
                }
            }
            else if (fs::is_symlink(file_status))
            {
                // Détermine la cible à utiliser pour le symlink recréé.
                fs::path old_target = fs::read_symlink(path);
                fs::path new_target = old_target;

                if (old_target.is_absolute())
                {
                    // Cible RÉELLE (liens résolus) comparée à
                    // source_real : un lien dont la cible atteint source
                    // via un autre lien est ainsi correctement reconnu
                    // intra-source (lexically_normal ne le verrait pas).
                    std::error_code tec;
                    fs::path target_real = fs::weakly_canonical(old_target, tec);
                    if (!tec)
                    {
                        if (is_within(source_real, target_real))
                        {
                            // rel forcément exprimable ici (sinon
                            // is_within aurait renvoyé false) ; le cas
                            // "." donne destination_real, inoffensif.
                            new_target = destination_real /
                                         target_real.lexically_relative(source_real);
                        }
                    }
                    // tec non nul = cible non résoluble (boucle de
                    // liens, accès refusé). Décision actée : on conserve
                    // old_target tel quel — copier un lien cassé à
                    // l'identique est légitime (cf. cp -a) ; durcir ne
                    // doit pas le transformer en crash ni en lien
                    // réécrit au hasard.
                }

                symlink_mappings.emplace_back(dest_path, new_target);
            }
            else
            {
                std::string msg = "unknown file type: " + path.string();
                if (continue_on_error)
                {
                    std::cerr << "warning: " << msg << '\n';
                    has_warnings = true;
                    continue;
                }
                else
                {
                    return msg;
                }
            }
        }

        // Recrée les symlinks dans la destination, après que les fichiers
        // réguliers aient été copiés (les cibles internes existent maintenant).
        for (const auto &[dest_symlink, target] : symlink_mappings)
        {
            fs::create_symlink(target, dest_symlink, ec);
            if (ec)
            {
                std::string msg = "cannot create symlink '" + dest_symlink.string() +
                                  "' -> '" + target.string() + "': " + ec.message();
                if (continue_on_error)
                {
                    std::cerr << "warning: " << msg << '\n';
                    has_warnings = true;
                }
                else
                {
                    return msg;
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

/**
 * @brief Lua binding for the copy_directory function.
 *
 * Lua usage:
 *   ok, err = babet.copyTree(source, destination [, continue_on_error])
 *
 * @param L The Lua state.
 * @return int Number of return values on the Lua stack (2: ok/nil, err/nil).
 */
int lua_copyTree(lua_State *L)
{
    if (lua_gettop(L) < 2 || !lua_isstring(L, 1) || !lua_isstring(L, 2))
    {
        return luaL_error(L, "Expected at least two string arguments: source and destination paths");
    }

    std::string_view src_path(luaL_checkstring(L, 1));
    std::string_view dest_path(luaL_checkstring(L, 2));

    bool continue_on_error = true;
    if (lua_gettop(L) >= 3)
    {
        continue_on_error = lua_toboolean(L, 3);
    }

    return push_action_result(L, copy_directory(src_path, dest_path, continue_on_error));
}
