#include "runtime_registration.hpp"

#ifndef BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION
#include "../lua_bindings/archive.hpp"
#endif
#include "../lua_bindings/base64.hpp"
#ifndef BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING
#include "../lua_bindings/blake2b.hpp"
#include "../lua_bindings/blake2s.hpp"
#include "../lua_bindings/md5.hpp"
#include "../lua_bindings/sha1.hpp"
#include "../lua_bindings/sha256.hpp"
#include "../lua_bindings/sha3_256.hpp"
#include "../lua_bindings/sha3_384.hpp"
#include "../lua_bindings/sha3_512.hpp"
#include "../lua_bindings/sha384.hpp"
#include "../lua_bindings/sha512.hpp"
#endif
#include "../lua_bindings/attributes.hpp"
#include "../lua_bindings/chdir.hpp"
#ifndef BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION
#include "../lua_bindings/compression.hpp"
#endif
#include "../lua_bindings/copy.hpp"
#include "../lua_bindings/copyTree.hpp"
#include "../lua_bindings/crc32.hpp"
#include "../lua_bindings/currentDir.hpp"
#include "../lua_bindings/curses.hpp"
#include "../lua_bindings/deepCopyTable.hpp"
#include "../lua_bindings/exec.hpp"
#include "../lua_bindings/process.hpp"
#include "../lua_bindings/pipeline.hpp"
#include "../lua_bindings/fileExists.hpp"
#include "../lua_bindings/fileSize.hpp"
#include "../lua_bindings/fileUtils.hpp"
#ifndef BABET_SIZE_EXPERIMENT_NO_FIND_RE2
#include "../lua_bindings/find.hpp"
#endif
#include "../lua_bindings/gui.hpp"
#include "../lua_bindings/helloThere.hpp"
#ifndef BABET_SIZE_EXPERIMENT_NO_NETWORK
#include "../lua_bindings/http.hpp"
#endif
#include "../lua_bindings/inotify.hpp"
#include "../lua_bindings/isdir.hpp"
#include "../lua_bindings/isfile.hpp"
#include "../lua_bindings/json.hpp"
#include "../lua_bindings/link.hpp"
#include "../lua_bindings/listFiles.hpp"
#include "../lua_bindings/lua_utils.hpp"
#include "../lua_bindings/memoryUtils.hpp"
#include "../lua_bindings/mergeTables.hpp"
#include "../lua_bindings/mkdir.hpp"
#include "../lua_bindings/mode.hpp"
#include "../lua_bindings/moveTree.hpp"
#include "../lua_bindings/native_plugin.hpp"
#include "../lua_bindings/joinPath.hpp"
#include "../lua_bindings/rename.hpp"
#include "../lua_bindings/remove.hpp"
#include "../lua_bindings/rmdir.hpp"
#include "../lua_bindings/sleep.hpp"
#include "../lua_bindings/signal.hpp"
#ifndef BABET_SIZE_EXPERIMENT_NO_NETWORK
#include "../lua_bindings/socket.hpp"
#include "../lua_bindings/websocket.hpp"
#endif
#include "../lua_bindings/split.hpp"
#include "../lua_bindings/sqlite.hpp"
#include "../lua_bindings/sys.hpp"
#include "../lua_bindings/symlinkattr.hpp"
#include "../lua_bindings/time_clock.hpp"
#include "../lua_bindings/time_format.hpp"
#include "../lua_bindings/toml.hpp"
#include "../lua_bindings/touch.hpp"
#include "../lua_bindings/user.hpp"
#include "../lua_bindings/workers.hpp"
#include "../lua_bindings/writeFileAtomic.hpp"
#include "../lua_bindings/fileIterator.hpp"
#include "version.hpp"

#include <lua.hpp>

namespace
{
template <int (*Fn)(lua_State *)>
int babet_lua_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "babet: out of memory", "babet: internal failure",
        "babet: unknown internal failure");
}
} // namespace

void prepend_babet_package_path(lua_State *L, std::string_view prefix)
{
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    if (lua_type(L, -1) == LUA_TSTRING)
    {
        lua_pushlstring(L, prefix.data(), prefix.size());
        lua_insert(L, -2); // package, prefix, oldpath
        lua_concat(L, 2);  // package, prefix .. oldpath
    }
    else
    {
        lua_pop(L, 1);
        lua_pushlstring(L, prefix.data(), prefix.size());
    }
    lua_setfield(L, -2, "path");
    lua_pop(L, 1); // pop package
}

/**
 * @brief Register Babet functions to Lua state.
 * @param L Lua state.
 */
void register_babet(lua_State *L, NativePluginRuntime *plugin_runtime,
                    NativePluginMode plugin_mode)
{
    lua_newtable(L);

    lua_pushcfunction(L, babet_lua_boundary<lua_setattr>);
    lua_setfield(L, -2, "setAttributes");

    lua_pushcfunction(L, babet_lua_boundary<lua_getattr>);
    lua_setfield(L, -2, "getAttributes");

    lua_pushcfunction(L, babet_lua_boundary<lua_chdir>);
    lua_setfield(L, -2, "chdir");

    lua_pushcfunction(L, babet_lua_boundary<lua_copy_file>);
    lua_setfield(L, -2, "copy");

    lua_pushcfunction(L, babet_lua_boundary<lua_copyTree>);
    lua_setfield(L, -2, "copyTree");

    lua_pushcfunction(L, babet_lua_boundary<lua_crc32>);
    lua_setfield(L, -2, "crc32");

    lua_pushcfunction(L, babet_lua_boundary<lua_crc32sum>);
    lua_setfield(L, -2, "crc32sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_currentDir>);
    lua_setfield(L, -2, "currentDir");

    lua_pushcfunction(L, babet_lua_boundary<lua_deepCopyTable>);
    lua_setfield(L, -2, "deepCopyTable");

    lua_pushcfunction(L, babet_lua_boundary<lua_exec>);
    lua_setfield(L, -2, "exec");

    // Processus pilotables en streaming (2.4.0). Enregistre babet.spawn
    // ainsi que la métatable du userdata babet.process.
    register_process(L);

    // Pipelines synchrones et pilotables en streaming (2.5.0).
    register_pipeline(L);

    lua_pushcfunction(L, babet_lua_boundary<lua_fileExists>);
    lua_setfield(L, -2, "fileExists");

    lua_pushcfunction(L, babet_lua_boundary<lua_fileSize>);
    lua_setfield(L, -2, "fileSize");

#ifndef BABET_SIZE_EXPERIMENT_NO_FIND_RE2
    lua_pushcfunction(L, babet_lua_boundary<lua_find>);
    lua_setfield(L, -2, "find");
#endif

    lua_pushcfunction(L, babet_lua_boundary<lua_getBasename>);
    lua_setfield(L, -2, "getBasename");

    lua_pushcfunction(L, babet_lua_boundary<lua_getExtension>);
    lua_setfield(L, -2, "getExtension");

    lua_pushcfunction(L, babet_lua_boundary<lua_getFilename>);
    lua_setfield(L, -2, "getFilename");

    lua_pushcfunction(L, babet_lua_boundary<lua_getMemoryUsage>);
    lua_setfield(L, -2, "getMemoryUsage");

    lua_pushcfunction(L, babet_lua_boundary<lua_getDetailedMemoryUsage>);
    lua_setfield(L, -2, "getDetailedMemoryUsage");

    lua_pushcfunction(L, babet_lua_boundary<lua_getPath>);
    lua_setfield(L, -2, "getPath");

    lua_pushcfunction(L, babet_lua_boundary<lua_helloThere>);
    lua_setfield(L, -2, "helloThere");

    // Nommage (décision post-v2.1.1) : les composés Babet sont en
    // camelCase (fileExists, listFiles, currentDir...), les noms
    // POSIX restent en minuscules (mkdir, chdir, touch...).
    // isdir/isfile/symlinkattr étaient les trois intrus : le
    // camelCase devient canonique, les minuscules restent des alias
    // dépréciés (même fonction C, zéro coût, zéro casse).
    lua_pushcfunction(L, babet_lua_boundary<lua_isDir>);
    lua_setfield(L, -2, "isDir");
    lua_pushcfunction(L, babet_lua_boundary<lua_isDir>);
    lua_setfield(L, -2, "isdir"); // alias déprécié

    lua_pushcfunction(L, babet_lua_boundary<lua_isFile>);
    lua_setfield(L, -2, "isFile");
    lua_pushcfunction(L, babet_lua_boundary<lua_isFile>);
    lua_setfield(L, -2, "isfile"); // alias déprécié

    lua_pushcfunction(L, babet_lua_boundary<lua_link>);
    lua_setfield(L, -2, "link");

    lua_pushcfunction(L, babet_lua_boundary<lua_listFiles>);
    lua_setfield(L, -2, "listFiles");

#ifndef BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING
    lua_pushcfunction(L, babet_lua_boundary<lua_md5sum>);
    lua_setfield(L, -2, "md5sum");
#endif

    lua_pushcfunction(L, babet_lua_boundary<lua_mergeTables>);
    lua_setfield(L, -2, "mergeTables");

    lua_pushcfunction(L, babet_lua_boundary<lua_mkdir>);
    lua_setfield(L, -2, "mkdir");

    lua_pushcfunction(L, babet_lua_boundary<lua_moveTree>);
    lua_setfield(L, -2, "moveTree");

    lua_pushcfunction(L, babet_lua_boundary<lua_joinPath>);
    lua_setfield(L, -2, "joinPath");

    lua_pushcfunction(L, babet_lua_boundary<lua_remove_file>);
    lua_setfield(L, -2, "remove");

    lua_pushcfunction(L, babet_lua_boundary<lua_rename>);
    lua_setfield(L, -2, "rename");

    lua_pushcfunction(L, babet_lua_boundary<lua_rmdir>);
    lua_setfield(L, -2, "rmdir");

    lua_pushcfunction(L, babet_lua_boundary<lua_rmdir_all>);
    lua_setfield(L, -2, "rmdirAll");

    lua_pushcfunction(L, babet_lua_boundary<lua_setmode>);
    lua_setfield(L, -2, "setMode");

    lua_pushcfunction(L, babet_lua_boundary<lua_getmode>);
    lua_setfield(L, -2, "getMode");

#ifndef BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING
    lua_pushcfunction(L, babet_lua_boundary<lua_sha1sum>);
    lua_setfield(L, -2, "sha1sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_sha3_256sum>);
    lua_setfield(L, -2, "sha3_256sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_sha3_512sum>);
    lua_setfield(L, -2, "sha3_512sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_sha256sum>);
    lua_setfield(L, -2, "sha256sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_sha512sum>);
    lua_setfield(L, -2, "sha512sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_blake2b512sum>);
    lua_setfield(L, -2, "blake2b512sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_blake2s256sum>);
    lua_setfield(L, -2, "blake2s256sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_sha384sum>);
    lua_setfield(L, -2, "sha384sum");

    lua_pushcfunction(L, babet_lua_boundary<lua_sha3_384sum>);
    lua_setfield(L, -2, "sha3_384sum");

#endif

    lua_pushcfunction(L, babet_lua_boundary<lua_sleep>);
    lua_setfield(L, -2, "sleep");

    // Chantier 11 : monotonic + now pour mesurer durées et timestamper.
    lua_pushcfunction(L, babet_lua_boundary<lua_monotonic>);
    lua_setfield(L, -2, "monotonic");

    lua_pushcfunction(L, babet_lua_boundary<lua_now>);
    lua_setfield(L, -2, "now");

    lua_pushcfunction(L, babet_lua_boundary<lua_split>);
    lua_setfield(L, -2, "split");

    lua_pushcfunction(L, babet_lua_boundary<lua_symlinkattr>);
    lua_setfield(L, -2, "symlinkAttr");
    lua_pushcfunction(L, babet_lua_boundary<lua_symlinkattr>);
    lua_setfield(L, -2, "symlinkattr"); // alias déprécié

    lua_pushcfunction(L, babet_lua_boundary<lua_touch>);
    lua_setfield(L, -2, "touch");

    lua_pushcfunction(L, babet_lua_boundary<lua_writeFileAtomic>);
    lua_setfield(L, -2, "writeFileAtomic");

    lua_pushcfunction(L, babet_lua_boundary<lua_createFileIterator>);
    lua_setfield(L, -2, "createFileIterator");

    // Sous-table babet.base64 (RFC 4648, chaînes binaires).
    register_base64(L);

#ifndef BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION
    // Sous-table babet.compression (flux gzip/xz/bzip2/zstd autonomes).
    register_compression(L);

    // Sous-table babet.archive (ZIP miniz + TAR brut/gzip/xz/bzip2/zstd).
    // Même précondition de pile que les autres sous-modules.
    register_archive(L);
#endif

    // Sous-table babet.json (encode/decode + sentinels null,
    // empty_array). register_json attend la table babet au sommet de
    // la pile, ce qui est le cas ici.
    register_json(L);

#ifndef BABET_SIZE_EXPERIMENT_NO_NETWORK
    // Sous-table babet.http (request/get/post). Même précondition de
    // pile que register_json (table babet au sommet).
    register_http(L);
#endif

    // Sous-table babet.toml (decode). Même précondition de pile
    // que register_json / register_http (table babet au sommet).
    register_toml(L);

#ifndef BABET_SIZE_EXPERIMENT_NO_NETWORK
    // Sous-table babet.socket (connect/listen + métatable
    // LuapilotSocket dans le registry). Même précondition de pile
    // (table babet au sommet) ; register_socket pose en passant
    // la métatable dans le registry, mais laisse la pile inchangée.
    register_socket(L);

    // Sous-table babet.websocket : client RFC 6455 ws:// / wss://.
    // Le protocole reste générique ; Selenium/WebDriver BiDi se construit
    // au-dessus côté Lua sans dépendance spécifique dans Babet.
    register_websocket(L);
#endif

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

    // Sous-table babet.plugin : chargement natif explicite. Seul le runtime
    // CLI normal reçoit un NativePluginRuntime autorisé ; applications générées,
    // embedding et workers conservent une fonction load() de refus contrôlé.
    register_native_plugin(L, plugin_runtime, plugin_mode);

    // Sous-table babet.gui : API GUI optionnelle. Son enregistrement ne charge
    // aucun toolkit ; GTK 4 n'est recherché que lors d'un appel Lua explicite.
    babet_gui::register_gui(L);

    // Sous-table babet.curses : interface terminal ncursesw. Toutes les
    // opérations restent limitées au thread principal et partagent le
    // gestionnaire de terminal de process/spawn.
    babet_curses::register_curses(L);

#ifndef BABET_SIZE_EXPERIMENT_NO_SQLITE
    // Sous-table babet.sqlite (open + méthodes du userdata db).
    // V1 : API haut niveau, open/close/exec sans params (session 1).
    // Sessions à venir : params bind, query lazy iterator. Cf.
    // sqlite.hpp pour le design figé.
    register_sqlite(L);
#endif

    // Sous-table babet.user (get/exists) pour les lookups
    // utilisateur via NSS (getpwnam_r/getpwuid_r). Couvre LDAP,
    // SSSD, NIS+, etc. — pas une lecture directe de /etc/passwd.
    // Précondition de pile identique (table babet au sommet).
    // Cf. user.hpp pour le design.
    register_user(L);

    // babet.VERSION = BABET_VERSION_STRING
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

    lua_pushcfunction(L, babet_lua_boundary<lua_time_iso>);
    lua_setfield(L, -2, "iso");
    lua_pushcfunction(L, babet_lua_boundary<lua_time_parse_iso>);
    lua_setfield(L, -2, "parse_iso");
    lua_pushcfunction(L, babet_lua_boundary<lua_time_parse_duration>);
    lua_setfield(L, -2, "parse_duration");
    lua_pushcfunction(L, babet_lua_boundary<lua_time_format_duration>);
    lua_setfield(L, -2, "format_duration");

    // Aliases for ergonomy: same C functions used at babet.X.
    lua_pushcfunction(L, babet_lua_boundary<lua_now>);
    lua_setfield(L, -2, "now");
    lua_pushcfunction(L, babet_lua_boundary<lua_monotonic>);
    lua_setfield(L, -2, "monotonic");
    lua_pushcfunction(L, babet_lua_boundary<lua_sleep>);
    lua_setfield(L, -2, "sleep");

    lua_setfield(L, -2, "time"); // babet.time = <new table>

    lua_setglobal(L, "babet");

    // Enregistre la metatable "FileIterator" dans le registry Lua.
    file_iterator_create_meta(L);
    lua_pop(L, 1);
}


void close_babet_lua_state(lua_State *L) noexcept
{
    if (!L)
        return;

    // GUI callback/widget state must be neutralized before Lua disappears.
    // Lot 1 only releases logical ownership; later widget lots extend this
    // same hook without moving toolkit cleanup behind lua_close().
    babet_gui::cleanup_on_main_thread(L);

    // Process userdata finalizers may still have to terminate/resume an
    // interactive child. Let them return the TTY to the registry first, then
    // restore/service curses on the registered main thread.
    lua_close(L);
    babet_curses::service_terminal_events();
    babet_curses::cleanup_on_main_thread();
}
