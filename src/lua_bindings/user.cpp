// user.cpp — Implémentation de babet.user (cf. user.hpp pour le
// design).

#include "user.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <cstdio>   // snprintf
#include <cstring>  // strerror_r, strlen
#include <limits>   // std::numeric_limits (uid_t bounds check)
#include <string>
#include <vector>

#include <pwd.h>     // getpwnam_r, getpwuid_r, struct passwd
#include <sys/types.h>
#include <unistd.h>  // sysconf, _SC_GETPW_R_SIZE_MAX

extern "C"
{
#include <lauxlib.h>
#include <lua.h>
}

namespace
{

    // Taille initiale du buffer NSS. 1024 octets est suffisant pour la
    // grande majorité des entrées (un struct passwd contient quelques
    // chaînes courtes : name, passwd placeholder, gecos, home, shell).
    // En cas de gecos exceptionnellement long ou d'environnement
    // inhabituel, on double le buffer jusqu'à MAX_BUF_SIZE.
    constexpr size_t INITIAL_BUF_SIZE = 1024;

    // Plafond pour éviter d'allouer indéfiniment sur ERANGE répétés
    // (bug de NSS, ou entrée pathologique). 64 KiB est très largement
    // au-dessus de tout cas légitime.
    constexpr size_t MAX_BUF_SIZE = 64 * 1024;

    // Résultat sémantique d'un appel NSS. POSIX dit que rc == 0 avec
    // *result == nullptr signifie "absent". Certaines libcs ont
    // historiquement retourné ENOENT/ESRCH à la place — on traite
    // ces cas comme "absent" aussi par robustesse.
    enum class Lookup
    {
        Found,
        NotFound,
        Error
    };

    // Choix de taille initiale : on consulte sysconf si possible,
    // sinon on prend INITIAL_BUF_SIZE. sysconf retourne parfois -1
    // (taille non bornée, Linux moderne) — dans ce cas notre défaut
    // s'applique.
    size_t initial_buf_size()
    {
        long s = sysconf(_SC_GETPW_R_SIZE_MAX);
        if (s <= 0)
        {
            return INITIAL_BUF_SIZE;
        }
        // Cap au cas où sysconf renvoie une valeur absurde.
        size_t sz = static_cast<size_t>(s);
        if (sz > MAX_BUF_SIZE) sz = MAX_BUF_SIZE;
        if (sz < INITIAL_BUF_SIZE) sz = INITIAL_BUF_SIZE;
        return sz;
    }

    // Traduit un errno NSS en message lisible. On évite strerror_r
    // (dont la signature varie entre GNU et XSI) en mappant les
    // erreurs les plus courantes à la main, avec fallback générique
    // sur "errno %d".
    void describe_errno(int rc, std::string &out)
    {
        const char *known = nullptr;
        switch (rc)
        {
        case EIO:    known = "I/O error"; break;
        case EMFILE: known = "too many open files in this process"; break;
        case ENFILE: known = "too many open files in the system"; break;
        case ENOMEM: known = "out of memory"; break;
        case EAGAIN: known = "name service temporarily unavailable"; break;
        case EINTR:  known = "interrupted"; break;
        case ERANGE: known = "buffer too small (giving up)"; break;
        default:     break;
        }
        if (known)
        {
            out = known;
            return;
        }
        char buf[48];
        std::snprintf(buf, sizeof(buf), "errno %d", rc);
        out = buf;
    }

    // Exécute getpwnam_r en gérant le buffer dynamique. Sur Found,
    // remplit `pwd_out` et le buffer `buf` (qui reste référencé par
    // les pointeurs dans pwd_out). Le caller ne doit pas relâcher
    // `buf` avant d'avoir copié les chaînes côté Lua.
    Lookup do_getpwnam_r(const char *name,
                         struct passwd &pwd_out,
                         std::vector<char> &buf,
                         std::string &err_msg)
    {
        buf.resize(initial_buf_size());
        for (;;)
        {
            struct passwd *result = nullptr;
            errno = 0;
            int rc = getpwnam_r(name, &pwd_out, buf.data(),
                                buf.size(), &result);
            if (rc == 0)
            {
                return result ? Lookup::Found : Lookup::NotFound;
            }
            if (rc == ENOENT || rc == ESRCH || rc == EBADF)
            {
                // Certaines anciennes glibc remontent un errno
                // spécifique pour "absent" plutôt que rc=0+result=NULL.
                return Lookup::NotFound;
            }
            if (rc == ERANGE)
            {
                // Buffer trop petit, on double tant qu'on est sous
                // le plafond.
                if (buf.size() >= MAX_BUF_SIZE)
                {
                    describe_errno(rc, err_msg);
                    return Lookup::Error;
                }
                size_t newsize = buf.size() * 2;
                if (newsize > MAX_BUF_SIZE) newsize = MAX_BUF_SIZE;
                buf.resize(newsize);
                continue;
            }
            describe_errno(rc, err_msg);
            return Lookup::Error;
        }
    }

    // Symétrique pour getpwuid_r. Code dupliqué assumé (deux
    // signatures distinctes, factoriser via templates ne gagne rien
    // pour 30 lignes).
    Lookup do_getpwuid_r(uid_t uid,
                         struct passwd &pwd_out,
                         std::vector<char> &buf,
                         std::string &err_msg)
    {
        buf.resize(initial_buf_size());
        for (;;)
        {
            struct passwd *result = nullptr;
            errno = 0;
            int rc = getpwuid_r(uid, &pwd_out, buf.data(),
                                buf.size(), &result);
            if (rc == 0)
            {
                return result ? Lookup::Found : Lookup::NotFound;
            }
            if (rc == ENOENT || rc == ESRCH || rc == EBADF)
            {
                return Lookup::NotFound;
            }
            if (rc == ERANGE)
            {
                if (buf.size() >= MAX_BUF_SIZE)
                {
                    describe_errno(rc, err_msg);
                    return Lookup::Error;
                }
                size_t newsize = buf.size() * 2;
                if (newsize > MAX_BUF_SIZE) newsize = MAX_BUF_SIZE;
                buf.resize(newsize);
                continue;
            }
            describe_errno(rc, err_msg);
            return Lookup::Error;
        }
    }

    // Helper sécuritaire : pousse une chaîne C qui peut être nullptr.
    // Lua n'accepte pas nullptr pour lua_pushstring, et certains
    // champs (gecos notamment) peuvent être NULL sur certaines
    // implémentations NSS.
    void push_cstring_or_empty(lua_State *L, const char *s)
    {
        if (s == nullptr)
        {
            lua_pushliteral(L, "");
        }
        else
        {
            lua_pushstring(L, s);
        }
    }

    // Pose une table Lua qui décrit le struct passwd sur la pile.
    // Les chaînes pointées par pw_* doivent rester valides pendant
    // l'appel (Lua copie en interne).
    void push_passwd_table(lua_State *L, const struct passwd &pw)
    {
        lua_createtable(L, 0, 6);

        push_cstring_or_empty(L, pw.pw_name);
        lua_setfield(L, -2, "name");

        lua_pushinteger(L, static_cast<lua_Integer>(pw.pw_uid));
        lua_setfield(L, -2, "uid");

        lua_pushinteger(L, static_cast<lua_Integer>(pw.pw_gid));
        lua_setfield(L, -2, "gid");

        // GECOS exposé brut. Le format historique est
        // "Full Name,Office,WorkPhone,HomePhone[,Other]" mais en
        // pratique beaucoup d'entrées ne contiennent que le nom
        // complet sans virgules. On laisse le user parser s'il le
        // souhaite, c'est trivial en Lua.
        push_cstring_or_empty(L, pw.pw_gecos);
        lua_setfield(L, -2, "gecos");

        push_cstring_or_empty(L, pw.pw_dir);
        lua_setfield(L, -2, "home");

        push_cstring_or_empty(L, pw.pw_shell);
        lua_setfield(L, -2, "shell");
    }

    // Forme parsée d'un argument utilisateur après validation stricte.
    // Une seule des deux représentations est valide selon `is_name`.
    // POD strict : aucun objet C++ avec destructeur, donc sûr à
    // retourner par valeur même si la fonction qui le produit fait
    // luaL_error en cours de route.
    struct ParsedArg
    {
        bool is_name;     // true → name ; false → uid
        const char *name; // valide si is_name == true (Lua-owned)
        uid_t uid;        // valide si is_name == false
    };

    // Validation STRICTE de l'argument utilisateur (string ou integer
    // dans le range uid_t). Toutes les erreurs sont signalées via
    // luaL_error (longjmp).
    //
    // IMPORTANT (pattern défensif) : cette fonction est appelée AVANT
    // toute allocation d'objet C++ avec destructeur dans la fonction
    // appelante. Comme luaL_error fait un longjmp pur qui ne déroule
    // pas la pile C++, faire la validation ici sans rien à libérer
    // côté C++ garantit qu'aucune ressource ne fuite en cas de bad
    // input. Miroir du pattern adopté dans sqlite.cpp.
    //
    // Cas couverts :
    //   - LUA_TSTRING contenant un NUL embarqué -> luaL_error
    //   - LUA_TNUMBER non-integer (float) -> luaL_error
    //   - Integer négatif -> luaL_error
    //   - Integer > uid_t max -> luaL_error
    //   - Tout autre type (table, boolean, nil, …) -> luaL_error
    ParsedArg parse_user_arg(lua_State *L, int arg_idx)
    {
        ParsedArg out{};
        int t = lua_type(L, arg_idx);
        if (t == LUA_TSTRING)
        {
            // Détecter un NUL embarqué. getpwnam_r prend une C-string
            // et s'arrêterait au premier NUL : "root\0evil" serait
            // vu comme "root", ce qui peut contourner une
            // vérification de l'appelant sur du nom dérivé d'input
            // utilisateur. On refuse proprement.
            size_t len = 0;
            const char *name = lua_tolstring(L, arg_idx, &len);
            if (std::strlen(name) != len)
            {
                luaL_error(L,
                           "user: name must not contain embedded "
                           "NUL bytes");
                // unreachable
            }
            out.is_name = true;
            out.name = name;
            return out;
        }
        if (t == LUA_TNUMBER && lua_is_strict_integer(L, arg_idx))
        {
            // Pas de coercion silencieuse pour les floats : un user
            // qui passe 1.5 a probablement un bug, on lui dit.
            lua_Integer n = lua_tointeger(L, arg_idx);
            if (n < 0)
            {
                // Refuser les UID négatifs (qui wrappent en valeur
                // très grande après cast en uid_t, et pourraient
                // matcher des comptes service par hasard).
                luaL_error(L,
                           "user: uid must be a non-negative integer");
                // unreachable
            }
            // Plafond : lua_Integer est typiquement 64-bit signé,
            // uid_t est 32-bit non signé sur Linux. Sans ce check,
            // un UID > 2^32 - 1 serait silencieusement tronqué et
            // pourrait matcher un compte par hasard.
            using uid_limits = std::numeric_limits<uid_t>;
            if (static_cast<unsigned long long>(n) > uid_limits::max())
            {
                luaL_error(L,
                           "user: uid out of range for uid_t (max %llu)",
                           static_cast<unsigned long long>(
                               uid_limits::max()));
                // unreachable
            }
            out.is_name = false;
            out.uid = static_cast<uid_t>(n);
            return out;
        }
        luaL_error(L,
                   "user: argument must be a string (name) or "
                   "non-negative integer (uid), got %s",
                   lua_typename(L, t));
        // unreachable
        return out;
    }

    // babet.user.get(name_or_uid) -> table | (nil, err)
    int lua_user_get(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L,
                              "user.get: missing argument (name or uid)");
        }

        // 1) Validation STRICTE en premier. Tous les luaL_error
        //    possibles se font ici, AVANT d'avoir alloué quoi que ce
        //    soit côté C++ avec destructeur. Comme luaL_error est un
        //    longjmp pur qui ne déroule pas la pile C++, ce
        //    découpage garantit qu'aucune fuite n'est possible en cas
        //    de bad input.
        ParsedArg arg = parse_user_arg(L, 1);

        // 2) Maintenant qu'on est sûr que le chemin restant n'appelle
        //    plus luaL_error, on peut allouer en toute sécurité.
        //    do_getpwnam_r / do_getpwuid_r retournent un enum, jamais
        //    longjmp.
        struct passwd pwd_out{};
        std::vector<char> buf;
        std::string err_msg;

        Lookup r = arg.is_name
                       ? do_getpwnam_r(arg.name, pwd_out, buf, err_msg)
                       : do_getpwuid_r(arg.uid, pwd_out, buf, err_msg);
        if (r == Lookup::Found)
        {
            push_passwd_table(L, pwd_out);
            return 1;
        }
        if (r == Lookup::NotFound)
        {
            return push_fail(L, "user not found");
        }
        // Error
        std::string full = "user: ";
        full += err_msg;
        return push_fail(L, full);
    }

    // babet.user.exists(name_or_uid) -> boolean
    //
    // Strictement true ou false. Les erreurs NSS sont silencieusement
    // assimilées à "false" pour rester cohérent avec la sémantique
    // d'un prédicat "exists". Si l'utilisateur veut diagnostiquer
    // une vraie panne NSS, il utilise get() qui retourne un message.
    int lua_user_exists(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L,
                              "user.exists: missing argument (name or uid)");
        }

        // Même séparation validation / allocation que lua_user_get.
        ParsedArg arg = parse_user_arg(L, 1);

        struct passwd pwd_out{};
        std::vector<char> buf;
        std::string err_msg;

        Lookup r = arg.is_name
                       ? do_getpwnam_r(arg.name, pwd_out, buf, err_msg)
                       : do_getpwuid_r(arg.uid, pwd_out, buf, err_msg);
        lua_pushboolean(L, r == Lookup::Found ? 1 : 0);
        return 1;
    }

    template <int (*Fn)(lua_State *)>
    int user_lua_boundary(lua_State *L)
    {
        return lua_cfunction_exception_boundary<Fn>(
            L, "user: out of memory", "user: internal failure",
            "user: unknown internal failure");
    }

} // namespace

void register_user(lua_State *L)
{
    // Précondition : la table babet est au sommet.
    lua_newtable(L);

    lua_pushcfunction(L, user_lua_boundary<lua_user_get>);
    lua_setfield(L, -2, "get");

    lua_pushcfunction(L, user_lua_boundary<lua_user_exists>);
    lua_setfield(L, -2, "exists");

    lua_setfield(L, -2, "user");
}
