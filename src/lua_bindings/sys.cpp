#include "sys.hpp"
#include "workers.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

#include <limits.h>      // HOST_NAME_MAX (Linux)
#include <sys/utsname.h> // uname()
#include <unistd.h>      // gethostname, getpid, setenv

// Fallback de portabilité : sur certains systèmes UNIX (macOS / BSD
// anciens), HOST_NAME_MAX n'est pas garanti dans <limits.h> — ils
// utilisent MAXHOSTNAMELEN dans <sys/param.h>. 255 est la valeur
// POSIX standard (suffisante pour tous les hostnames DNS valides).
#ifndef HOST_NAME_MAX
#define HOST_NAME_MAX 255
#endif

namespace fs = std::filesystem;

namespace
{

    // Cherche `name` dans les répertoires de la variable d'env PATH,
    // dans l'ordre, et renvoie le premier exécutable trouvé. Renvoie
    // chaîne vide si rien.
    //
    // - Si `name` contient '/', on ne consulte PAS PATH : on teste
    //   directement le chemin tel quel (comme /usr/bin/which réel).
    // - PATH absent ou vide -> rien trouvé.
    // - Une entrée PATH vide ("::") signifie le cwd, convention Unix
    //   historique respectée par la libc.
    std::string find_in_path(const std::string &name)
    {
        if (name.empty())
        {
            return {};
        }
        std::error_code ec;
        if (name.find('/') != std::string::npos)
        {
            fs::path p(name);
            if (fs::is_regular_file(p, ec) &&
                ::access(p.c_str(), X_OK) == 0)
            {
                // Normalise en absolu si possible, pour rendre la
                // valeur stable même si le cwd change ensuite.
                auto abs = fs::absolute(p, ec);
                return ec ? p.string() : abs.string();
            }
            return {};
        }
        const char *path_env = std::getenv("PATH");
        if (path_env == nullptr || *path_env == '\0')
        {
            return {};
        }
        std::string path = path_env;
        size_t start = 0;
        while (start <= path.size())
        {
            size_t end = path.find(':', start);
            if (end == std::string::npos)
            {
                end = path.size();
            }
            std::string dir = path.substr(start, end - start);
            if (dir.empty())
            {
                dir = "."; // convention Unix : entrée vide = cwd
            }
            fs::path candidate = fs::path(dir) / name;
            if (fs::is_regular_file(candidate, ec) &&
                ::access(candidate.c_str(), X_OK) == 0)
            {
                auto abs = fs::absolute(candidate, ec);
                return ec ? candidate.string() : abs.string();
            }
            if (end == path.size())
            {
                break;
            }
            start = end + 1;
        }
        return {};
    }

} // namespace

// babet.which(name) -> "path" | (nil, "msg")
//
// Mauvais usage (arg absent/non-string) -> luaL_error.
// name non trouvé dans PATH -> (nil, "msg") : c'est un échec runtime
// attendu, pas une faute du programmeur. (Décision UTIL-4 ne porte
// que sur env ; pour which, on garde (nil, err) explicite : un
// `which("foo")` qui rend nil silencieusement induirait en erreur.)
int lua_sys_which(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TSTRING);
    std::string name;
    std::string err;
    if (!lua_string_without_nul(L, 1, name, "which: name", err))
    {
        return push_fail(L, err);
    }
    std::string found = find_in_path(name);
    if (found.empty())
    {
        return push_fail(L,
                         std::string("which: '") + name + "' not found in PATH");
    }
    lua_pushlstring(L, found.data(), found.size());
    return 1;
}

// babet.env(name) -> "value" | nil   (PAS de (nil, err))
//
// Décision UTIL-4 : variable absente = nil seul, sans message
// d'erreur, pour permettre l'idiome `local p = babet.env("PORT")
// or "8080"`. Mauvais usage (arg absent/non-string) -> luaL_error.
int lua_sys_env(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TSTRING);

    // env() suit la convention historique de cette API : une faute de type
    // ou un nom impossible lève une erreur Lua. On vérifie le NUL avant de
    // construire un objet C++ afin de ne pas franchir un luaL_argerror avec
    // des destructeurs actifs.
    size_t name_len = 0;
    const char *name_data = lua_tolstring(L, 1, &name_len);
    if (std::memchr(name_data, '\0', name_len) != nullptr)
    {
        return luaL_argerror(L, 1,
                             "env: name must not contain NUL byte");
    }

    std::string name(name_data, name_len);
    const char *val = std::getenv(name.c_str());
    if (val == nullptr)
    {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, val);
    return 1;
}

// babet.setenv(name, value) -> (true, nil) | (nil, err)
//
// Décision UTIL-5. La libc setenv(3) renvoie 0 / -1+errno.
// Validations programmeur (arg manquant / mauvais type) -> luaL_error.
// Validations runtime (name contient '=', name vide) -> (nil, err) :
// la libc rejette avec EINVAL, on relaie proprement.
int lua_sys_setenv(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TSTRING);
    luaL_checktype(L, 2, LUA_TSTRING);
    std::string name;
    std::string value;
    std::string err;
    if (!lua_string_without_nul(L, 1, name, "setenv: name", err) ||
        !lua_string_without_nul(L, 2, value, "setenv: value", err))
    {
        return push_fail(L, err);
    }
    // 1 = overwrite : on remplace une valeur existante (comportement
    // attendu d'un setter, sinon on aurait un setter qui ne fait
    // parfois rien selon l'état du process — exactement le « muet »
    // qu'on évite).
    // CORRECTIF (option A validée, revue Gemini triée) : mutation
    // d'état PROCESS-WIDE, interdite dès qu'un worker a été lancé.
    // setenv(3) peut réallouer `environ` pendant qu'un worker le lit
    // (getenv, exec, résolution DNS) -> course de données, SIGSEGV
    // possible. Le syscall s'exécute sous le verrou partagé avec
    // spawn (cf. workers.hpp) ; AUCUNE opération Lua sous le verrou.
    int rc = 0;
    int saved = 0;
    if (!with_process_env_lock([&]()
                               {
            rc = ::setenv(name.c_str(), value.c_str(), 1);
            saved = errno; }))
    {
        return push_fail(L,
                         "setenv: forbidden after workers.spawn (the process "
                         "environment is shared across threads; set it before "
                         "spawning workers)");
    }
    if (rc != 0)
    {
        return push_fail(L,
                         std::string("setenv: ") + std::strerror(saved));
    }
    return push_ok(L);
}

// babet.hostname() -> "host" | (nil, err)
//
// Aucun argument. gethostname(2) tronque silencieusement si le buffer
// est trop petit ; on utilise HOST_NAME_MAX (Linux) avec marge +1
// pour le NUL, et on assure la terminaison nous-même au cas où une
// implémentation oublierait sur troncature (POSIX ne le garantit pas).
int lua_sys_hostname(lua_State *L)
{
    char buf[HOST_NAME_MAX + 1];
    if (::gethostname(buf, sizeof(buf)) != 0)
    {
        int saved = errno;
        return push_fail(L,
                         std::string("hostname: ") + std::strerror(saved));
    }
    buf[sizeof(buf) - 1] = '\0';
    lua_pushstring(L, buf);
    return 1;
}

// babet.uname() -> { sysname, nodename, release, version, machine }
//                  | (nil, err)
//
// Mappe les 5 champs de struct utsname (Linux/POSIX). Tous des
// strings, comme la commande `uname -a`. Pas de champ "domainname"
// (extension GNU non portable, et rarement utile).
int lua_sys_uname(lua_State *L)
{
    struct utsname u;
    if (::uname(&u) != 0)
    {
        int saved = errno;
        return push_fail(L,
                         std::string("uname: ") + std::strerror(saved));
    }
    lua_newtable(L);
    lua_pushstring(L, u.sysname);
    lua_setfield(L, -2, "sysname");
    lua_pushstring(L, u.nodename);
    lua_setfield(L, -2, "nodename");
    lua_pushstring(L, u.release);
    lua_setfield(L, -2, "release");
    lua_pushstring(L, u.version);
    lua_setfield(L, -2, "version");
    lua_pushstring(L, u.machine);
    lua_setfield(L, -2, "machine");
    return 1;
}

// babet.pid() -> integer
//
// getpid(2) ne peut pas échouer (POSIX). Aucun argument.
int lua_sys_pid(lua_State *L)
{
    lua_pushinteger(L, static_cast<lua_Integer>(::getpid()));
    return 1;
}

void register_sys(lua_State *L)
{
    // Précondition : table babet au sommet (-1), comme
    // register_http / register_json. Ici on POSE les fonctions
    // DIRECTEMENT sur cette table (nommage plat, pas de sous-table) ;
    // la pile reste donc identique après l'appel.
    lua_pushcfunction(L, lua_sys_which);
    lua_setfield(L, -2, "which");

    lua_pushcfunction(L, lua_sys_env);
    lua_setfield(L, -2, "env");

    lua_pushcfunction(L, lua_sys_setenv);
    lua_setfield(L, -2, "setenv");

    lua_pushcfunction(L, lua_sys_hostname);
    lua_setfield(L, -2, "hostname");

    lua_pushcfunction(L, lua_sys_uname);
    lua_setfield(L, -2, "uname");

    lua_pushcfunction(L, lua_sys_pid);
    lua_setfield(L, -2, "pid");
}
