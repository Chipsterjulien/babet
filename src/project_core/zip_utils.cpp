#include "zip_utils.hpp"
#include "miniz.h"

#include <iostream>
#include <fstream>
#include <filesystem>
#include <system_error>
#include <cerrno>
#include <exception>

namespace fs = std::filesystem;

bool createZipFromDirectory(const std::string &dir, const std::string &zipFileName,
                            const std::string &excludePath)
{
    mz_zip_archive zip = {};

    if (!mz_zip_writer_init_file(&zip, zipFileName.c_str(), 0))
    {
        std::cerr << "Error creating ZIP file: " << zipFileName << std::endl;
        return false;
    }

    // CORRECTIF (audit v21) : try/catch autour de l'itération.
    //
    // recursive_directory_iterator (variante sans error_code) JETTE
    // filesystem_error sur une erreur d'OS — typiquement un
    // sous-dossier illisible (EACCES) rencontré pendant le parcours.
    // L'appelant (createExecutableWithDir) appelle cette fonction HORS
    // de son try/catch : avant ce correctif, l'exception remontait
    // jusqu'à main() sans être attrapée -> std::terminate (abort,
    // code 134) au lieu d'un message d'erreur propre + exit 1.
    //
    // Politique : on échoue FORT et PROPREMENT. Pas de
    // skip_permission_denied ici (contrairement à copyTree) : un
    // --create-exe qui embarquerait silencieusement un projet
    // incomplet produirait un binaire cassé de façon différée et
    // difficile à diagnostiquer. Mieux vaut refuser tout de suite
    // avec la cause.
    try
    {
        for (const auto &entry : fs::recursive_directory_iterator(dir))
        {
            if (!fs::is_regular_file(entry))
                continue;

            // CORRECTIF (revue ChatGPT post-v2.2.0, vérifié) : ne
            // jamais réembarquer l'output d'un --create-exe
            // PRÉCÉDENT. `--create-exe . app` lancé deux fois :
            // l'ancien `app` (binaire complet !) vivait dans le
            // dossier parcouru et finissait dans le ZIP du nouveau —
            // app(N+1) = Babet + projet + app(N), croissance à
            // chaque reconstruction. fs::equivalent compare les
            // inodes (symlinks résolus : un lien vers l'output est
            // exclu aussi) ; au premier build l'output n'existe pas
            // encore -> equivalent pose eq_ec et rend false, aucun
            // skip. Variante error_code : jamais d'exception ici.
            if (!excludePath.empty())
            {
                std::error_code eq_ec;
                if (fs::equivalent(entry.path(), excludePath, eq_ec))
                {
                    continue;
                }
            }

            // CORRECTIF (audit v21) : PURE lexical, surtout PAS
            // fs::relative — même bug (et même fix) que copyTree.cpp /
            // moveTree.cpp. fs::relative équivaut à
            // weakly_canonical(path).lexically_relative(
            // weakly_canonical(dir)) : il RÉSOUT les symlinks. Pour un
            // module du projet qui est un symlink vers un fichier hors
            // du dossier (ex : proj/mylib.lua -> ../shared/mylib.lua),
            // le nom d'entrée ZIP devenait le chemin de la CIBLE
            // relatif au projet ("../shared/mylib.lua") au lieu de la
            // position du lien ("mylib.lua") -> require("mylib")
            // échouait dans le binaire empaqueté.
            //
            // L'itérateur fournit toujours path = dir/... littéral,
            // donc lexically_relative donne la structure exacte vue
            // dans le projet, sans suivre aucun lien. Le CONTENU, lui,
            // est lu par mz_zip_writer_add_file qui ouvre le chemin et
            // suit donc le symlink : on embarque le bon contenu sous
            // le bon nom. Vérifié aussi avec un slash final sur `dir`
            // (forme produite par la complétion tab) : la
            // décomposition en composants de lexically_relative
            // l'absorbe correctement.
            //
            // Limite préexistante (inchangée) : les symlinks vers des
            // DOSSIERS ne sont pas suivis par
            // recursive_directory_iterator (comportement par défaut),
            // leur contenu n'est donc pas embarqué.
            std::string relativePath =
                entry.path().lexically_relative(dir).string();

            if (!mz_zip_writer_add_file(&zip, relativePath.c_str(),
                                        entry.path().string().c_str(),
                                        nullptr, 0, MZ_BEST_COMPRESSION))
            {
                std::cerr << "Error adding to ZIP: " << entry.path() << std::endl;
                mz_zip_writer_end(&zip);
                return false;
            }
        }
    }
    catch (const std::exception &e)
    {
        std::cerr << "Error scanning directory '" << dir << "': "
                  << e.what() << std::endl;
        mz_zip_writer_end(&zip);
        return false;
    }

    if (!mz_zip_writer_finalize_archive(&zip))
    {
        std::cerr << "Error finalizing ZIP" << std::endl;
        mz_zip_writer_end(&zip);
        return false;
    }
    mz_zip_writer_end(&zip);
    return true;
}

void mergeFiles(const std::string &exe, const std::string &zip, const std::string &output)
{
    std::ifstream exeFile(exe, std::ios::binary);
    if (!exeFile)
    {
        throw std::system_error(errno, std::generic_category(), "open " + exe);
    }
    std::ifstream zipFile(zip, std::ios::binary);
    if (!zipFile)
    {
        throw std::system_error(errno, std::generic_category(), "open " + zip);
    }
    std::ofstream outFile(output, std::ios::binary);
    if (!outFile)
    {
        throw std::system_error(errno, std::generic_category(), "create " + output);
    }

    outFile << exeFile.rdbuf() << zipFile.rdbuf();
    if (!outFile)
    {
        throw std::system_error(errno, std::generic_category(), "write " + output);
    }
    std::cout << "Successfully created executable: " << output << std::endl;
}

std::optional<std::vector<char>> readEmbeddedFile(const std::string &exePath,
                                                  const std::string &archivePath)
{
    mz_zip_archive zip = {};

    // miniz scanne depuis la fin du fichier pour trouver l'EOCD, donc un zip
    // appendé à un exécutable est trouvé automatiquement.
    // Cette fonction est silencieuse : c'est aux callers de logger leurs erreurs
    // (le searcher Lua n'a pas besoin de spammer stderr à chaque require).
    if (!mz_zip_reader_init_file(&zip, exePath.c_str(), 0))
    {
        return std::nullopt;
    }

    int idx = mz_zip_reader_locate_file(&zip, archivePath.c_str(), nullptr, 0);
    if (idx < 0)
    {
        mz_zip_reader_end(&zip);
        return std::nullopt;
    }

    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&zip, idx, &stat))
    {
        mz_zip_reader_end(&zip);
        return std::nullopt;
    }

    std::vector<char> data(static_cast<size_t>(stat.m_uncomp_size));
    if (!mz_zip_reader_extract_to_mem(&zip, idx, data.data(), data.size(), 0))
    {
        mz_zip_reader_end(&zip);
        return std::nullopt;
    }

    mz_zip_reader_end(&zip);
    return data;
}
