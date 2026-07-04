#include "lua_bindings/attributes.hpp"
#include "lua_bindings/blake2b.hpp"
#include "lua_bindings/blake2s.hpp"
#include "lua_bindings/chdir.hpp"
#include "lua_bindings/copy.hpp"
#include "lua_bindings/copyTree.hpp"
#include "lua_bindings/crc32.hpp"
#include "lua_bindings/currentDir.hpp"
#include "lua_bindings/deepCopyTable.hpp"
#include "lua_bindings/exec.hpp"
#include "lua_bindings/fileExists.hpp"
#include "lua_bindings/fileSize.hpp"
#include "lua_bindings/fileUtils.hpp"
#include "lua_bindings/find.hpp"
#include "lua_bindings/helloThere.hpp"
#include "lua_bindings/http.hpp"
#include "lua_bindings/inotify.hpp"
#include "lua_bindings/isdir.hpp"
#include "lua_bindings/isfile.hpp"
#include "lua_bindings/json.hpp"
#include "lua_bindings/link.hpp"
#include "lua_bindings/listFiles.hpp"
#include "lua_bindings/md5.hpp"
#include "lua_bindings/memoryUtils.hpp"
#include "lua_bindings/mergeTables.hpp"
#include "lua_bindings/mkdir.hpp"
#include "lua_bindings/mode.hpp"
#include "lua_bindings/moveTree.hpp"
#include "lua_bindings/joinPath.hpp"
#include "lua_bindings/rename.hpp"
#include "lua_bindings/remove.hpp"
#include "lua_bindings/rmdir.hpp"
#include "lua_bindings/sha1.hpp"
#include "lua_bindings/sha256.hpp"
#include "lua_bindings/sha3_256.hpp"
#include "lua_bindings/sha3_512.hpp"
#include "lua_bindings/sha3_384.hpp"
#include "lua_bindings/sha384.hpp"
#include "lua_bindings/sha512.hpp"
#include "lua_bindings/sleep.hpp"
#include "lua_bindings/signal.hpp"
#include "lua_bindings/socket.hpp"
#include "lua_bindings/split.hpp"
#include "lua_bindings/sqlite.hpp"
#include "lua_bindings/sys.hpp"
#include "lua_bindings/symlinkattr.hpp"
#include "lua_bindings/time_clock.hpp"
#include "lua_bindings/time_format.hpp"
#include "lua_bindings/toml.hpp"
#include "lua_bindings/touch.hpp"
#include "lua_bindings/user.hpp"
#include "lua_bindings/workers.hpp"
#include "lua_bindings/fileIterator.hpp"

#include "project_core/bundled_modules.hpp"
#include "project_core/create_executable.hpp"
#include "project_core/embedded_searcher.hpp"
#include "project_core/executable_path.hpp"
#include "project_core/loadLuaFile.hpp"
#include "project_core/help.hpp"
#include "project_core/zip_utils.hpp"

#include "version.hpp"

#include <iostream>
#include <lua.hpp>
#include <filesystem>

namespace fs = std::filesystem;

/**
 * @brief Register Babet functions to Lua state.
 * @param L Lua state.
 */
void register_babet(lua_State *L)
{
    lua_newtable(L);

    lua_pushcfunction(L, lua_setattr);
    lua_setfield(L, -2, "setAttributes");

    lua_pushcfunction(L, lua_getattr);
    lua_setfield(L, -2, "getAttributes");

    lua_pushcfunction(L, lua_chdir);
    lua_setfield(L, -2, "chdir");

    lua_pushcfunction(L, lua_copy_file);
    lua_setfield(L, -2, "copy");

    lua_pushcfunction(L, lua_copyTree);
    lua_setfield(L, -2, "copyTree");

    lua_pushcfunction(L, lua_crc32);
    lua_setfield(L, -2, "crc32");

    lua_pushcfunction(L, lua_crc32sum);
    lua_setfield(L, -2, "crc32sum");

    lua_pushcfunction(L, lua_currentDir);
    lua_setfield(L, -2, "currentDir");

    lua_pushcfunction(L, lua_deepCopyTable);
    lua_setfield(L, -2, "deepCopyTable");

    lua_pushcfunction(L, lua_exec);
    lua_setfield(L, -2, "exec");

    lua_pushcfunction(L, lua_fileExists);
    lua_setfield(L, -2, "fileExists");

    lua_pushcfunction(L, lua_fileSize);
    lua_setfield(L, -2, "fileSize");

    lua_pushcfunction(L, lua_find);
    lua_setfield(L, -2, "find");

    lua_pushcfunction(L, lua_getBasename);
    lua_setfield(L, -2, "getBasename");

    lua_pushcfunction(L, lua_getExtension);
    lua_setfield(L, -2, "getExtension");

    lua_pushcfunction(L, lua_getFilename);
    lua_setfield(L, -2, "getFilename");

    lua_pushcfunction(L, lua_getMemoryUsage);
    lua_setfield(L, -2, "getMemoryUsage");

    lua_pushcfunction(L, lua_getDetailedMemoryUsage);
    lua_setfield(L, -2, "getDetailedMemoryUsage");

    lua_pushcfunction(L, lua_getPath);
    lua_setfield(L, -2, "getPath");

    lua_pushcfunction(L, lua_helloThere);
    lua_setfield(L, -2, "helloThere");

    lua_pushcfunction(L, lua_isDir);
    lua_setfield(L, -2, "isdir");

    lua_pushcfunction(L, lua_isFile);
    lua_setfield(L, -2, "isfile");

    lua_pushcfunction(L, lua_link);
    lua_setfield(L, -2, "link");

    lua_pushcfunction(L, lua_listFiles);
    lua_setfield(L, -2, "listFiles");

    lua_pushcfunction(L, lua_md5sum);
    lua_setfield(L, -2, "md5sum");

    lua_pushcfunction(L, lua_mergeTables);
    lua_setfield(L, -2, "mergeTables");

    lua_pushcfunction(L, lua_mkdir);
    lua_setfield(L, -2, "mkdir");

    lua_pushcfunction(L, lua_moveTree);
    lua_setfield(L, -2, "moveTree");

    lua_pushcfunction(L, lua_joinPath);
    lua_setfield(L, -2, "joinPath");

    lua_pushcfunction(L, lua_remove_file);
    lua_setfield(L, -2, "remove");

    lua_pushcfunction(L, lua_rename);
    lua_setfield(L, -2, "rename");

    lua_pushcfunction(L, lua_rmdir);
    lua_setfield(L, -2, "rmdir");

    lua_pushcfunction(L, lua_rmdir_all);
    lua_setfield(L, -2, "rmdirAll");

    lua_pushcfunction(L, lua_setmode);
    lua_setfield(L, -2, "setMode");

    lua_pushcfunction(L, lua_getmode);
    lua_setfield(L, -2, "getMode");

    lua_pushcfunction(L, lua_sha1sum);
    lua_setfield(L, -2, "sha1sum");

    lua_pushcfunction(L, lua_sha3_256sum);
    lua_setfield(L, -2, "sha3_256sum");

    lua_pushcfunction(L, lua_sha3_512sum);
    lua_setfield(L, -2, "sha3_512sum");

    lua_pushcfunction(L, lua_sha256sum);
    lua_setfield(L, -2, "sha256sum");

    lua_pushcfunction(L, lua_sha512sum);
    lua_setfield(L, -2, "sha512sum");

    lua_pushcfunction(L, lua_blake2b512sum);
    lua_setfield(L, -2, "blake2b512sum");

    lua_pushcfunction(L, lua_blake2s256sum);
    lua_setfield(L, -2, "blake2s256sum");

    lua_pushcfunction(L, lua_sha384sum);
    lua_setfield(L, -2, "sha384sum");

    lua_pushcfunction(L, lua_sha3_384sum);
    lua_setfield(L, -2, "sha3_384sum");

    lua_pushcfunction(L, lua_sleep);
    lua_setfield(L, -2, "sleep");

    // Chantier 11 : monotonic + now pour mesurer durées et timestamper.
    lua_pushcfunction(L, lua_monotonic);
    lua_setfield(L, -2, "monotonic");

    lua_pushcfunction(L, lua_now);
    lua_setfield(L, -2, "now");

    lua_pushcfunction(L, lua_split);
    lua_setfield(L, -2, "split");

    lua_pushcfunction(L, lua_symlinkattr);
    lua_setfield(L, -2, "symlinkattr");

    lua_pushcfunction(L, lua_touch);
    lua_setfield(L, -2, "touch");

    lua_pushcfunction(L, lua_createFileIterator);
    lua_setfield(L, -2, "createFileIterator");

    // Sous-table babet.json (encode/decode + sentinels null,
    // empty_array). register_json attend la table babet au sommet de
    // la pile, ce qui est le cas ici.
    register_json(L);

    // Sous-table babet.http (request/get/post). Même précondition de
    // pile que register_json (table babet au sommet).
    register_http(L);

    // Sous-table babet.toml (decode). Même précondition de pile
    // que register_json / register_http (table babet au sommet).
    register_toml(L);

    // Sous-table babet.socket (connect/listen + métatable
    // LuapilotSocket dans le registry). Même précondition de pile
    // (table babet au sommet) ; register_socket pose en passant
    // la métatable dans le registry, mais laisse la pile inchangée.
    register_socket(L);

    // Sous-table babet.inotify (new + métatable LuapilotInotify
    // dans le registry). Surveillance de système de fichiers via
    // inotify(7). Même précondition de pile (table babet au
    // sommet) ; register_inotify pose la métatable dans le registry
    // et laisse la pile inchangée. Cf. inotify.hpp pour le design.
    register_inotify(L);

    // Sous-table babet.workers (spawn + métatable LuapilotWorker
    // dans le registry). Même précondition de pile (table babet
    // au sommet) ; register_workers pose la métatable dans le
    // registry et laisse la pile inchangée. Chantier 8.
    register_workers(L);

    // Fonctions utilitaires plates sous babet.* (which, env, setenv,
    // hostname, uname, pid). register_sys NE crée PAS de sous-table :
    // pose les fonctions directement sur babet. Même précondition
    // de pile (table babet au sommet).
    register_sys(L);

    // Sous-table babet.signal (handle/ignore/default). Pour la
    // gestion propre de SIGTERM/SIGINT/SIGHUP/SIGUSR1/SIGUSR2/SIGPIPE
    // depuis Lua. Même précondition de pile (table babet au
    // sommet). Cf. signal.hpp pour le design.
    register_signal(L);

    // Sous-table babet.sqlite (open + méthodes du userdata db).
    // V1 : API haut niveau, open/close/exec sans params (session 1).
    // Sessions à venir : params bind, query lazy iterator. Cf.
    // sqlite.hpp pour le design figé.
    register_sqlite(L);

    // Sous-table babet.user (get/exists) pour les lookups
    // utilisateur via NSS (getpwnam_r/getpwuid_r). Couvre LDAP,
    // SSSD, NIS+, etc. — pas une lecture directe de /etc/passwd.
    // Précondition de pile identique (table babet au sommet).
    // Cf. user.hpp pour le design.
    register_user(L);

    // babet.VERSION = "1.7.1"
    lua_pushstring(L, BABET_VERSION_STRING);
    lua_setfield(L, -2, "VERSION");

    // babet.VERSION_MAJOR / MINOR / PATCH (integers, pour comparaison programmatique)
    lua_pushinteger(L, BABET_VERSION_MAJOR);
    lua_setfield(L, -2, "VERSION_MAJOR");
    lua_pushinteger(L, BABET_VERSION_MINOR);
    lua_setfield(L, -2, "VERSION_MINOR");
    lua_pushinteger(L, BABET_VERSION_PATCH);
    lua_setfield(L, -2, "VERSION_PATCH");

    // ---------------------------------------------------------------
    // Sub-table babet.time (v1.8.0): date/duration utilities, with
    // aliases for monotonic/now/sleep so the new code can stay inside
    // babet.time.* without losing access to the existing flat names.
    // The flat babet.monotonic / .now / .sleep stay around for
    // backward compatibility with v1.7.x scripts.
    // ---------------------------------------------------------------
    lua_newtable(L);

    lua_pushcfunction(L, lua_time_iso);
    lua_setfield(L, -2, "iso");
    lua_pushcfunction(L, lua_time_parse_iso);
    lua_setfield(L, -2, "parse_iso");
    lua_pushcfunction(L, lua_time_parse_duration);
    lua_setfield(L, -2, "parse_duration");
    lua_pushcfunction(L, lua_time_format_duration);
    lua_setfield(L, -2, "format_duration");

    // Aliases for ergonomy: same C functions used at babet.X.
    lua_pushcfunction(L, lua_now);
    lua_setfield(L, -2, "now");
    lua_pushcfunction(L, lua_monotonic);
    lua_setfield(L, -2, "monotonic");
    lua_pushcfunction(L, lua_sleep);
    lua_setfield(L, -2, "sleep");

    lua_setfield(L, -2, "time"); // babet.time = <new table>

    lua_setglobal(L, "babet");

    // Enregistre la metatable "FileIterator" dans le registry Lua.
    file_iterator_create_meta(L);
    lua_pop(L, 1);
}

/**
 * @brief Prepends a project's "?.lua" and "?/init.lua" to package.path,
 *        so that require() can find sibling modules of main.lua.
 */
static void prepend_project_to_package_path(lua_State *L, const fs::path &projectDir)
{
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");

    const char *current = lua_tostring(L, -1);
    std::string oldPath = current ? current : "";
    lua_pop(L, 1);

    std::string newPath =
        (projectDir / "?.lua").string() + ";" +
        (projectDir / "?" / "init.lua").string() + ";" +
        oldPath;

    lua_pushstring(L, newPath.c_str());
    lua_setfield(L, -2, "path");
    lua_pop(L, 1); // pop package
}

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
    luaL_openlibs(L);
    register_bundled_modules(L);
    register_babet(L);
    prepend_project_to_package_path(L, anchorDir);

    // Workers (Chantier 8) : indiquer le mode d'exécution pour que
    // require() utilisateur fonctionne aussi dans les workers
    // (cf. set_workers_init_context).
    set_workers_init_context(anchorDir.string(), "", false);

    push_lua_arg(L, argc, argv, 1);

    bool ok = loadLuaFile(L, scriptPath);
    lua_close(L);
    return ok ? 0 : 1;
}

int main(int argc, char *argv[])
{
    // === ÉTAPE 0 : capturer le thread principal pour signal.cpp =====
    // Doit être fait avant tout spawn de worker. Permet à
    // babet.signal.handle/ignore/default de refuser les appels
    // depuis un autre thread (les handlers POSIX sont process-wide ;
    // installer depuis un worker mène à un bug latent silencieux).
    register_main_thread();

    // === ÉTAPE 1 : IDENTITÉ (avant toute lecture de argv) ===========
    // Un binaire « packagé » = un binaire qui contient un main.lua
    // embarqué. Dans ce cas il EST l'application finale : Babet ne
    // doit intercepter AUCUN flag (--help, --create-exe, ...), tous
    // appartiennent à l'application embarquée, quel que soit argc.
    //
    // On résout donc cette identité en testant la présence de l'archive
    // AVANT d'interpréter le moindre argument. (Avant ce correctif, la
    // détection se faisait sur `argc < 2` : un exécutable packagé lancé
    // avec des arguments — ./mon_app --port 8080 — basculait à tort en
    // mode outil et cherchait un dossier nommé "--port".)
    {
        // getExecutablePath() lit /proc/self/exe (chemin canonique du
        // binaire courant) et PAS argv[0], qui peut n'être qu'un
        // basename si l'exe est dans le PATH — auquel cas miniz ne
        // saurait pas le retrouver sur le disque pour lire le zip.
        std::string exePath;
        try
        {
            exePath = getExecutablePath();
        }
        catch (const std::exception &e)
        {
            std::cerr << "Erreur : impossible de localiser l'exécutable - "
                      << e.what() << std::endl;
            return 1;
        }

        // optional vide = pas de zip / pas de main.lua embarqué : ce
        // n'est PAS une erreur, juste « je ne suis pas packagé » -> on
        // bascule en mode outil Babet (étape 2).
        auto fileData = readEmbeddedFile(exePath, "main.lua");
        if (fileData)
        {
            lua_State *L = luaL_newstate();
            if (!L)
            {
                std::cerr << "Erreur : impossible d'allouer un état Lua" << std::endl;
                return 1;
            }
            luaL_openlibs(L);
            register_bundled_modules(L);
            register_babet(L);
            register_embedded_searcher(L, exePath.c_str());

            // Workers (Chantier 8) : indiquer le mode d'exécution
            // pour que require() utilisateur fonctionne aussi dans
            // les workers (cf. set_workers_init_context).
            set_workers_init_context("", exePath, true);

            // Binaire packagé = l'application elle-même est le script :
            // arg[0] = binaire, arg[1..n] = ses arguments.
            push_lua_arg(L, argc, argv, 0);

            if (luaL_loadbuffer(L, fileData->data(), fileData->size(), "main.lua") || lua_pcall(L, 0, LUA_MULTRET, 0))
            {
                std::cerr << "Erreur : " << lua_tostring(L, -1) << std::endl;
                lua_close(L);
                return 1;
            }

            lua_close(L);
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
    fs::path target = fs::absolute(path);
    std::error_code ec;

    if (fs::is_regular_file(target, ec))
    {
        // Mode FICHIER : package.path et le contexte workers sont
        // ancrés au répertoire du script, pour que require() des
        // fichiers voisins fonctionne exactement comme en mode
        // dossier. arg[0] reste le chemin tel que tapé (via argv).
        return run_tool_script(target.parent_path(), target.string(),
                               argc, argv);
    }

    if (fs::is_directory(target, ec))
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
        if (!fs::is_regular_file(mainLuaPath, mec))
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
