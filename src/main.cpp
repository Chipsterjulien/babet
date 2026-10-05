#include "lua_bindings/curses.hpp"
#include "lua_bindings/lua_utils.hpp"
#include "lua_bindings/main_thread.hpp"
#include "lua_bindings/native_plugin.hpp"
#include "lua_bindings/workers.hpp"

#ifndef BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION
#include "project_core/archive_backend.hpp"
#endif
#include "project_core/bundled_modules.hpp"
#include "project_core/create_executable.hpp"
#include "project_core/embedded_searcher.hpp"
#include "project_core/embedded_lua.hpp"
#include "project_core/executable_path.hpp"
#include "project_core/loadLuaFile.hpp"
#include "project_core/runtime_registration.hpp"
#include "project_core/help.hpp"
#include "project_core/zip_utils.hpp"

#include "version.hpp"

#include <cstring>
#include <iostream>
#include <lua.hpp>
#include <filesystem>

namespace fs = std::filesystem;



/**
 * @brief Exposes the process command line to Lua as the global `arg`
 *        table, following the standard Lua standalone convention:
 *        arg[0] is the "script", arg[1..n] the arguments after it, and
 *        anything before the script gets negative indices.
 *
 *        Each argv[i] is stored at arg[i - script_index].
 *
 * Modes:
 *   - packaged executable (script_index = 0):
 *       arg[0] = binary, arg[1..n] = its arguments
 *   - folder runner `./babet <dir> ...` (script_index = 1):
 *       arg[-1] = babet binary, arg[0] = <dir>,
 *       arg[1..n] = user arguments
 *
 * lua_rawseti is used deliberately (raw set, no metamethods) since we
 * are building the table from scratch.
 */
static void push_lua_arg(lua_State *L, int argc, char *argv[], int script_index)
{
    lua_newtable(L);
    for (int i = 0; i < argc; ++i)
    {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - script_index);
    }
    lua_setglobal(L, "arg");
}

// Exécute un fichier Lua avec l'environnement outil complet (lot 10,
// audit v21 : factorisation du mode dossier historique, réutilisée à
// l'identique par le nouveau mode fichier).
//
// `anchorDir` ancre package.path (require des voisins) et le contexte
// workers : le répertoire du projet en mode dossier, le répertoire du
// script en mode fichier. `scriptPath` est le fichier chargé
// (<dir>/main.lua ou le script passé en argument). La table `arg` est
// construite depuis argv : arg[-1] = binaire babet, arg[0] = cible
// lancée telle que tapée (dossier ou script), arg[1..n] = arguments
// utilisateur.
static int run_tool_script(const fs::path &anchorDir,
                           const std::string &scriptPath,
                           int argc, char *argv[])
{
    lua_State *L = luaL_newstate();
    if (!L)
    {
        std::cerr << "Erreur : impossible d'allouer un état Lua" << std::endl;
        return 1;
    }
    std::string package_prefix;
    try
    {
        package_prefix = (anchorDir / "?.lua").string() + ";" +
                         (anchorDir / "?" / "init.lua").string() + ";";
    }
    catch (const std::exception &error)
    {
        std::cerr << "Erreur : impossible de préparer package.path - "
                  << error.what() << std::endl;
        close_babet_lua_state(L);
        return 1;
    }

    NativePluginRuntime plugin_runtime(L);
    auto setup_runtime = [&](lua_State *state)
    {
        luaL_openlibs(state);
        register_cli_process_exit(state);
        register_bundled_modules(state);
        register_babet(state, &plugin_runtime, NativePluginMode::allowed);
        prepend_babet_package_path(state, package_prefix);
        push_lua_arg(state, argc, argv, 1);
    };
    std::string setup_error;
    if (!lua_run_setup_protected(
            L, setup_runtime, "Erreur : initialisation Lua impossible",
            setup_error))
    {
        std::cerr << setup_error << std::endl;
        close_babet_lua_state(L);
        return 1;
    }

    // Workers (Chantier 8) : indiquer le mode d'exécution pour que
    // require() utilisateur fonctionne aussi dans les workers
    // (cf. set_workers_init_context).
    set_workers_init_context(anchorDir.string(), "", false);

    std::string script_error;
    const bool ok = loadLuaFile(L, scriptPath, script_error);
    close_babet_lua_state(L);
    if (!ok)
    {
        std::cerr << script_error << std::endl;
    }
    return ok ? 0 : 1;
}

int main(int argc, char *argv[])
{
#ifndef BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION
    // === ÉTAPE -1 : vérifier les backends d'archive liés ============
    // La 2.8.0 utilise libarchive, zlib, liblzma, libbz2 et libzstd
    // statiquement pour TAR/gzip/xz/bzip2/zstd, tout en conservant miniz pour
    // ZIP. Ces contrôles détectent
    // immédiatement un mélange header/bibliothèque dans les builds personnalisés.
    const auto libarchive_runtime = babet::archive_backend::inspect_runtime();
    if (libarchive_runtime.runtime_version_string == nullptr)
    {
        std::cerr << "Erreur : libarchive n'a retourné aucune version runtime."
                  << std::endl;
        return 1;
    }
    if (libarchive_runtime.runtime_version != libarchive_runtime.header_version)
    {
        std::cerr << "Erreur : incohérence libarchive entre les en-têtes ("
                  << libarchive_runtime.header_version << ") et la bibliothèque ("
                  << libarchive_runtime.runtime_version << ")." << std::endl;
        return 1;
    }
    if (libarchive_runtime.zlib_header_version == nullptr ||
        libarchive_runtime.zlib_runtime_version == nullptr)
    {
        std::cerr << "Erreur : zlib n'a retourné aucune version runtime."
                  << std::endl;
        return 1;
    }
    if (std::strcmp(libarchive_runtime.zlib_header_version,
                    libarchive_runtime.zlib_runtime_version) != 0)
    {
        std::cerr << "Erreur : incohérence zlib entre les en-têtes ("
                  << libarchive_runtime.zlib_header_version
                  << ") et la bibliothèque ("
                  << libarchive_runtime.zlib_runtime_version << ")."
                  << std::endl;
        return 1;
    }
    if (libarchive_runtime.lzma_header_version == nullptr ||
        libarchive_runtime.lzma_runtime_version == nullptr)
    {
        std::cerr << "Erreur : liblzma n'a retourné aucune version runtime."
                  << std::endl;
        return 1;
    }
    if (std::strcmp(libarchive_runtime.lzma_header_version,
                    libarchive_runtime.lzma_runtime_version) != 0)
    {
        std::cerr << "Erreur : incohérence liblzma entre les en-têtes ("
                  << libarchive_runtime.lzma_header_version
                  << ") et la bibliothèque ("
                  << libarchive_runtime.lzma_runtime_version << ")."
                  << std::endl;
        return 1;
    }
    if (libarchive_runtime.bzip2_expected_version == nullptr ||
        libarchive_runtime.bzip2_runtime_version == nullptr)
    {
        std::cerr << "Erreur : libbz2 n'a retourné aucune version runtime."
                  << std::endl;
        return 1;
    }
    const std::size_t bzip2_expected_length =
        std::strlen(libarchive_runtime.bzip2_expected_version);
    const std::size_t bzip2_runtime_length =
        std::strlen(libarchive_runtime.bzip2_runtime_version);
    if (bzip2_runtime_length < bzip2_expected_length ||
        std::strncmp(libarchive_runtime.bzip2_runtime_version,
                     libarchive_runtime.bzip2_expected_version,
                     bzip2_expected_length) != 0 ||
        (bzip2_runtime_length > bzip2_expected_length &&
         libarchive_runtime.bzip2_runtime_version[bzip2_expected_length] != ','))
    {
        std::cerr << "Erreur : incohérence libbz2 entre la version attendue ("
                  << libarchive_runtime.bzip2_expected_version
                  << ") et la bibliothèque ("
                  << libarchive_runtime.bzip2_runtime_version << ")."
                  << std::endl;
        return 1;
    }
    if (libarchive_runtime.zstd_header_version == nullptr ||
        libarchive_runtime.zstd_runtime_version == nullptr)
    {
        std::cerr << "Erreur : libzstd n'a retourné aucune version runtime."
                  << std::endl;
        return 1;
    }
    if (std::strcmp(libarchive_runtime.zstd_header_version,
                    libarchive_runtime.zstd_runtime_version) != 0)
    {
        std::cerr << "Erreur : incohérence libzstd entre les en-têtes ("
                  << libarchive_runtime.zstd_header_version
                  << ") et la bibliothèque ("
                  << libarchive_runtime.zstd_runtime_version << ")."
                  << std::endl;
        return 1;
    }

#endif

    // === ÉTAPE 0 : capturer le thread principal partagé ==============
    // Doit être fait avant tout spawn de worker. Signal, curses et les
    // handoffs terminal interactifs réutilisent cette même identité ; aucun
    // sous-système ne maintient sa propre notion parallèle du main thread.
    babet_runtime::register_main_thread();

    // === ÉTAPE 1 : IDENTITÉ (avant toute lecture de argv) ===========
    // Le descripteur de l'image chargée indique si ce binaire est une
    // application générée, même si son ZIP a été tronqué. Les flags
    // applicatifs appartiennent à son main.lua, pas au mode outil Babet.
    // Une seule exception est volontairement réservée au runtime :
    // --create-exe / -c, car une application générée est un artefact final
    // et ne doit jamais redevenir builder.
    //
    // On contrôle cette identité et l'intégrité du chargement AVANT
    // d'interpréter le moindre argument. (Avant ce correctif, la
    // détection se faisait sur `argc < 2` : un exécutable packagé lancé
    // avec des arguments — ./mon_app --port 8080 — basculait à tort en
    // mode outil et cherchait un dossier nommé "--port".)
    {
        // Lire l'inode réellement exécuté : le chemin affiché par readlink
        // peut déjà désigner une autre version après un remplacement atomique.
        const char *exePath = RUNNING_EXECUTABLE_CONTENT;

        // Une application marquée ne peut jamais revenir au mode outil,
        // même si le ZIP ou main.lua manque. Un runtime nu ne prend pas une
        // constante ZIP de ses sections ELF pour une application.
        std::string embedded_error;
        const auto image_layout = runningEmbeddedImageLayout(&embedded_error);
        if (!image_layout)
        {
            std::cerr << "Erreur : " << embedded_error << std::endl;
            return 1;
        }
        auto fileData = readEmbeddedFile(exePath, "main.lua", &embedded_error, &*image_layout);
        if (!fileData && embedded_error.empty() && image_layout->generated)
            embedded_error = "generated application has no embedded main.lua";
        if (!fileData && !embedded_error.empty())
        {
            std::cerr << "Erreur : " << embedded_error << std::endl;
            return 1;
        }
        if (image_layout->generated)
        {
            // Le descripteur généré et le chargement valide sont requis.
            // Les arguments applicatifs ne peuvent pas activer le builder.
            if (argc >= 2 &&
                (std::strcmp(argv[1], "--create-exe") == 0 ||
                 std::strcmp(argv[1], "-c") == 0))
            {
                std::cerr
                    << "Erreur : --create-exe n'est pas disponible dans un exécutable généré.\n"
                    << "Utilisez le binaire Babet original pour créer un nouvel exécutable."
                    << std::endl;
                return 1;
            }

            lua_State *L = luaL_newstate();
            if (!L)
            {
                std::cerr << "Erreur : impossible d'allouer un état Lua" << std::endl;
                return 1;
            }
            auto setup_runtime = [&](lua_State *state)
            {
                luaL_openlibs(state);
                register_cli_process_exit(state);
                register_bundled_modules(state);
                register_babet(state, nullptr,
                               NativePluginMode::generated_application);
                register_embedded_searcher(state, exePath);
                // Binaire packagé = l'application elle-même est le script :
                // arg[0] = binaire, arg[1..n] = ses arguments.
                push_lua_arg(state, argc, argv, 0);
            };
            std::string setup_error;
            if (!lua_run_setup_protected(
                    L, setup_runtime,
                    "Erreur : initialisation Lua embarquée impossible",
                    setup_error))
            {
                std::cerr << setup_error << std::endl;
                close_babet_lua_state(L);
                return 1;
            }

            // Workers (Chantier 8) : indiquer le mode d'exécution
            // pour que require() utilisateur fonctionne aussi dans
            // les workers (cf. set_workers_init_context).
            set_workers_init_context("", exePath, true);

            if (load_embedded_lua(L, fileData->data(), fileData->size(), "main.lua") || lua_pcall(L, 0, LUA_MULTRET, 0))
            {
                const std::string execution_error =
                    "Erreur : " + lua_value_to_display_string(L, -1);
                close_babet_lua_state(L);
                std::cerr << execution_error << std::endl;
                return 1;
            }

            close_babet_lua_state(L);
            return 0;
        }
        // Pas packagé : on continue en mode outil ci-dessous.
    }

    // === ÉTAPE 2 : MODE OUTIL BABET (pas de main.lua embarqué) ====

    // Outil lancé sans argument : on affiche l'aide. (Anciennement ce
    // cas tombait dans la détection d'embarqué et émettait un message
    // d'archive trompeur ; maintenant qu'on sait qu'on n'est pas
    // packagé, l'aide est la réponse honnête.)
    if (argc < 2)
    {
        printHelp();
        return 1;
    }

    std::string option = argv[1];

    // --version / -V : intercepté UNIQUEMENT en mode outil (binaire
    // babet nu). Pour un binaire packagé via --create-exe, ce flag
    // appartient à l'application embarquée et l'étape 1 (ci-dessus)
    // l'aurait déjà transmise au script. À ce point on sait qu'on
    // n'est pas packagé, donc on peut interpréter --version comme
    // une demande de version du runtime Babet.
    if (option == "--version" || option == "-V")
    {
        std::cout << "babet " << BABET_VERSION_STRING << '\n';
        return 0;
    }

    // --help / -h n'est reconnu QU'EN PREMIER argument. Plus loin
    // (`babet mon_projet --help`) le flag appartient au projet, qui
    // le lira via la table `arg` : sinon Babet intercepterait un
    // argument destiné au script. (Sans contrainte sur argc : c'est la
    // POSITION qui compte, pas le nombre d'arguments.)
    if (option == "--help" || option == "-h")
    {
        printHelp();
        return 0;
    }

    if (option == "--create-exe" || option == "-c")
    {
        if (argc != 4)
        {
            std::cerr << "Usage : " << argv[0] << " --create-exe <dir> <output>" << std::endl;
            return 1;
        }
        std::string dir = argv[2];
        std::string output = argv[3];
        return createExecutableWithDir(dir, output) ? 0 : 1;
    }

    // Tout autre argument qui commence par "-" est un flag inconnu :
    // on refuse explicitement plutôt que de l'interpréter comme un
    // nom de dossier (ce qui produirait un message d'erreur très
    // confus). Un vrai dossier dont le nom commence par "-" reste
    // accessible via "./-dirname" — convention POSIX habituelle.
    if (!option.empty() && option[0] == '-')
    {
        std::cerr << "Unknown option: " << option << "\n"
                  << "Try 'babet --help' for more information." << std::endl;
        return 1;
    }

    // Mode "exécution" (lot 10, audit v21) : l'argument est soit un
    // SCRIPT (fichier régulier — n'importe quelle extension : Lua
    // ignore nativement une première ligne shebang `#!`, donc
    // `#!/usr/bin/env babet` fonctionne), soit un DOSSIER de projet
    // contenant main.lua. Avant ce lot, l'argument était toujours
    // traité comme un dossier, et `babet script.lua` échouait avec
    // le message trompeur « main.lua introuvable dans le répertoire
    // script.lua ».
    std::string path = argv[1];
    std::error_code abs_ec;
    fs::path target = fs::absolute(path, abs_ec);
    if (abs_ec) target = fs::path(path);
    std::error_code ec;
    fs::file_status target_status = fs::status(target, ec);
    if (ec && ec != std::errc::no_such_file_or_directory &&
        ec != std::errc::not_a_directory)
    {
        std::cerr << "Erreur : impossible d'inspecter '" << path
                  << "' : " << ec.message() << std::endl;
        return 1;
    }

    if (fs::is_regular_file(target_status))
    {
        // Mode FICHIER : package.path et le contexte workers sont
        // ancrés au répertoire du script, pour que require() des
        // fichiers voisins fonctionne exactement comme en mode
        // dossier. arg[0] reste le chemin tel que tapé (via argv).
        return run_tool_script(target.parent_path(), target.string(),
                               argc, argv);
    }

    if (fs::is_directory(target_status))
    {
        // Mode DOSSIER : comportement historique inchangé.
        std::string mainLuaPath = (target / "main.lua").string();
        // CORRECTIF (revue ChatGPT post-audit v21) : fichier RÉGULIER
        // exigé, pas seulement l'existence. Un DOSSIER nommé main.lua
        // passait fs::exists, puis luaL_dofile échouait avec un
        // message OS abscons ("Is a directory"). is_regular_file suit
        // les symlinks : un lien vers un vrai main.lua reste accepté.
        // Le message conserve "main.lua introuvable" (Test 5 le
        // greppe) et précise le cas non-régulier.
        std::error_code mec;
        const fs::file_status main_status = fs::status(mainLuaPath, mec);
        if (mec && mec != std::errc::no_such_file_or_directory &&
            mec != std::errc::not_a_directory)
        {
            std::cerr << "Erreur : impossible d'inspecter main.lua dans le répertoire "
                      << path << " : " << mec.message() << std::endl;
            return 1;
        }
        if (!fs::is_regular_file(main_status))
        {
            std::cerr << "Erreur : main.lua introuvable (ou pas un fichier régulier) dans le répertoire "
                      << path << std::endl;
            return 1;
        }
        return run_tool_script(target, mainLuaPath, argc, argv);
    }

    // Ni fichier régulier ni dossier : chemin inexistant, FIFO,
    // socket… — erreur explicite au lieu de l'ancien message
    // « main.lua introuvable » hors sujet.
    std::cerr << "Erreur : '" << path
              << "' n'est ni un script Lua (fichier) ni un dossier de projet contenant main.lua"
              << std::endl;
    return 1;
}
