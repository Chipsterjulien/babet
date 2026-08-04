#include "inotify.hpp"
#include "inotify_buffer.hpp"
#include "lua_utils.hpp"
#include "signal.hpp"

#include <cerrno>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

#include <poll.h>
#include <sys/inotify.h>
#include <unistd.h>

namespace
{

    constexpr const char *INOT_META = "LuapilotInotify";

    // État porté par l'userdata. Volontairement trivial : un seul FD
    // inotify. Pas de membre non-trivial -> pas de placement new ni de
    // destructeur explicite à appeler dans __gc (contrairement à Sock
    // dans socket.cpp qui porte un std::string). lua_newuserdata fait
    // le malloc, on initialise le champ à la main, __gc ferme le FD.
    struct Watcher
    {
        int fd; // -1 si fermé
    };

    class OwnedFd
    {
    public:
        explicit OwnedFd(int fd) noexcept : fd_(fd) {}
        OwnedFd(const OwnedFd &) = delete;
        OwnedFd &operator=(const OwnedFd &) = delete;
        ~OwnedFd() noexcept
        {
            if (fd_ >= 0)
                ::close(fd_);
        }
        void release() noexcept { fd_ = -1; }

    private:
        int fd_;
    };

    Watcher *check_watcher(lua_State *L, int idx)
    {
        return static_cast<Watcher *>(luaL_checkudata(L, idx, INOT_META));
    }

    // Pousse un nouveau userdata Watcher, puis lui transfère le FD seulement
    // après la dernière API Lua susceptible d'allouer. Si la pose de la
    // métatable échoue, __gc voit donc -1 tandis que OwnedFd ferme l'original :
    // aucune fuite et aucun double close différé.
    Watcher *push_new_watcher(lua_State *L, int fd)
    {
        void *raw = lua_newuserdata(L, sizeof(Watcher));
        Watcher *w = static_cast<Watcher *>(raw);
        w->fd = -1;
        luaL_getmetatable(L, INOT_META);
        lua_setmetatable(L, -2);
        w->fd = fd; // transfert après toutes les allocations Lua possibles
        return w;
    }

    // (nil, "inotify: <prefix>: <strerror(errno)>") — miroir de
    // push_errno_fail dans socket.cpp, préfixe "inotify:".
    int push_errno_fail(lua_State *L, const char *prefix)
    {
        int saved = errno;
        std::string msg = "inotify: ";
        msg += prefix;
        msg += ": ";
        msg += std::strerror(saved);
        return push_fail_protected(L, msg);
    }

    // -----------------------------------------------------------------
    // Timeout + interruption signal (répliqué de socket.cpp, version
    // minimale : seulement POLLIN, pas de TLS).
    //
    // DIVERGENCE ASSUMÉE vs socket : ici timeout==0 signifie « poll
    // non bloquant, rends ce qui est dispo tout de suite », et
    // l'ABSENCE de timeout (argument nil) signifie « bloquant infini ».
    // socket utilise set_timeout(0)=infini ; la sémantique read([t])
    // d'inotify est différente, donc on NE réutilise PAS make_deadline.
    // La deadline est construite directement au site d'appel de read().
    // -----------------------------------------------------------------
    using Clock = std::chrono::steady_clock;
    using Deadline = Clock::time_point;
    const Deadline NO_DEADLINE = Deadline::max();

    // Timeout effectif à passer à poll() :
    //   < 0 = bloquant infini (deadline == NO_DEADLINE)
    //   0   = deadline dépassée (poll non bloquant : rend tout
    //         de suite ce qui est prêt, ou 0 si rien)
    //   > 0 = millisecondes restantes (borné à INT_MAX)
    int remaining_ms(Deadline deadline)
    {
        if (deadline == NO_DEADLINE)
        {
            return -1;
        }
        auto now = Clock::now();
        if (now >= deadline)
        {
            return 0;
        }
        auto delta = std::chrono::duration_cast<std::chrono::milliseconds>(
                         deadline - now)
                         .count();
        if (delta > INT_MAX)
        {
            return INT_MAX;
        }
        return static_cast<int>(delta);
    }

    constexpr int WAIT_INTERRUPTED = -2;

    // Attend que `fd` devienne lisible (POLLIN), en respectant la
    // deadline. Renvoie :
    //   > 0 = prêt
    //   0   = timeout par deadline
    //   -1  = erreur (errno positionné)
    //   WAIT_INTERRUPTED = interrompu par un signal géré (le caller
    //         doit dispatcher via signal_dispatch_pending(L) puis
    //         renvoyer (nil, "interrupted")).
    int wait_readable_deadline(int fd, Deadline deadline)
    {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        for (;;)
        {
            // Note : on ne court-circuite PAS quand t == 0. POSIX
            // garantit que poll(..., 0) retourne immédiatement avec
            // les fd déjà prêts (sans bloquer), ce qui est exactement
            // la sémantique attendue de read(0) ("non bloquant, rends
            // ce qui est dispo"). Court-circuiter avant poll() ferait
            // rater des événements déjà présents dans la queue.
            int t = remaining_ms(deadline);
            pfd.revents = 0;
            // CORRECTIF (revue ChatGPT post-release, étendu ici par
            // cohérence — la revue ne visait que sleep) : même garde
            // pré-poll que wait_ready_deadline (socket) et sleep. Un
            // signal géré déjà en attente interrompt immédiatement,
            // au lieu de laisser le poll aller à son terme.
            if (signal_any_handled_pending())
            {
                return WAIT_INTERRUPTED;
            }
            int r = ::poll(&pfd, 1, t);
            if (r < 0)
            {
                if (errno == EINTR)
                {
                    // EINTR d'un signal QU'ON GÈRE -> propager au
                    // caller pour (nil, "interrupted"). Sinon (signal
                    // non géré, p.ex. SIGWINCH), retry silencieux :
                    // remaining_ms recalcule le temps restant.
                    if (signal_any_handled_pending())
                    {
                        return WAIT_INTERRUPTED;
                    }
                    continue;
                }
                return -1;
            }
            return r; // 0 = timeout, > 0 = prêt
        }
    }

    // -----------------------------------------------------------------
    // Mapping nom d'événement -> flag IN_* (pour add()).
    // 0 = inconnu (sentinelle sûre : aucun flag inotify ne vaut 0,
    // IN_ACCESS == 0x1).
    // -----------------------------------------------------------------
    struct EventName
    {
        const char *name;
        uint32_t flag;
    };

    const EventName ADD_EVENTS[] = {
        {"access", IN_ACCESS},
        {"modify", IN_MODIFY},
        {"attrib", IN_ATTRIB},
        {"close_write", IN_CLOSE_WRITE},
        {"close_nowrite", IN_CLOSE_NOWRITE},
        {"close", IN_CLOSE}, // IN_CLOSE_WRITE | IN_CLOSE_NOWRITE
        {"open", IN_OPEN},
        {"moved_from", IN_MOVED_FROM},
        {"moved_to", IN_MOVED_TO},
        {"move", IN_MOVE}, // IN_MOVED_FROM | IN_MOVED_TO
        {"create", IN_CREATE},
        {"delete", IN_DELETE},
        {"delete_self", IN_DELETE_SELF},
        {"move_self", IN_MOVE_SELF},
    };

    uint32_t event_name_to_flag(std::string_view name)
    {
        for (const auto &e : ADD_EVENTS)
        {
            if (name == e.name)
            {
                return e.flag;
            }
        }
        return 0;
    }

    // -----------------------------------------------------------------
    // Décodage masque -> table d'événements lisibles (pour read()).
    // Ne couvre QUE les bits individuels que le noyau positionne dans
    // un événement reçu. IN_ISDIR est traité à part (champ is_dir),
    // IN_Q_OVERFLOW aussi (champ events.overflow + wd == -1).
    // -----------------------------------------------------------------
    const EventName READ_FLAGS[] = {
        {"access", IN_ACCESS},
        {"modify", IN_MODIFY},
        {"attrib", IN_ATTRIB},
        {"close_write", IN_CLOSE_WRITE},
        {"close_nowrite", IN_CLOSE_NOWRITE},
        {"open", IN_OPEN},
        {"moved_from", IN_MOVED_FROM},
        {"moved_to", IN_MOVED_TO},
        {"create", IN_CREATE},
        {"delete", IN_DELETE},
        {"delete_self", IN_DELETE_SELF},
        {"move_self", IN_MOVE_SELF},
        // Flags positionnés par le noyau (pas demandables dans add) :
        {"ignored", IN_IGNORED}, // watch retiré (rm_watch, ou cible supprimée/démontée)
        {"unmount", IN_UNMOUNT}, // le FS portant la cible a été démonté
    };

    // Pose les booléens décodés sur la table au sommet de la pile (-1).
    void decode_flags_into_table(lua_State *L, uint32_t mask)
    {
        for (const auto &f : READ_FLAGS)
        {
            if (mask & f.flag)
            {
                lua_pushboolean(L, 1);
                lua_setfield(L, -2, f.name);
            }
        }
    }

    // -----------------------------------------------------------------
    // Méthodes du userdata
    // -----------------------------------------------------------------

    int inot_add(lua_State *L)
    {
        if (!lua_arity_between(L, 3, 4))
        {
            return luaL_error(L,
                              "inotify.add expects path, events and optional opts");
        }
        Watcher *w = check_watcher(L, 1);

        // Toutes les validations susceptibles de lever via luaL_error doivent
        // précéder la construction de std::string. Lua utilise un longjmp pour
        // ses erreurs : un destructeur C++ présent sur la pile ne serait alors
        // pas exécuté (détecté par LeakSanitizer sur events mal typé).
        luaL_checktype(L, 2, LUA_TSTRING);
        // events : OBLIGATOIRE (décision INOT-B). luaL_checktype lève
        // si absent (none) ou si ce n'est pas une table.
        luaL_checktype(L, 3, LUA_TTABLE);
        bool onlydir = false;
        if (!lua_is_none_or_nil(L, 4))
        {
            luaL_checktype(L, 4, LUA_TTABLE);
            // Conserver le comportement historique de lua_getfield (donc
            // l'éventuel __index), mais l'exécuter avant tout objet C++ non
            // trivial afin qu'une erreur Lua ne contourne aucun destructeur.
            lua_getfield(L, 4, "onlydir");
            if (!lua_isnil(L, -1))
            {
                if (!lua_is_strict_boolean(L, -1))
                {
                    lua_pop(L, 1);
                    return push_fail_protected(L,
                                     "inotify: add: opts.onlydir must be a boolean");
                }
                onlydir = lua_toboolean(L, -1) != 0;
            }
            lua_pop(L, 1);
        }

        if (w->fd < 0)
        {
            return push_fail_protected(L, "inotify: add: watcher is closed");
        }

        lua_Integer count = static_cast<lua_Integer>(lua_rawlen(L, 3));
        if (count == 0)
        {
            return push_fail_protected(L,
                             "inotify: add: events list must not be empty");
        }

        uint32_t mask = onlydir ? IN_ONLYDIR : 0;
        for (lua_Integer i = 1; i <= count; ++i)
        {
            lua_rawgeti(L, 3, static_cast<lua_Integer>(i));
            if (!lua_is_strict_string(L, -1))
            {
                // Cohérence : toutes les erreurs de contenu de la
                // table events (sparse, extra keys, unknown event,
                // élément non-string) retournent (nil, err). Le
                // mauvais TYPE de l'argument lui-même (events pas
                // une table) est déjà rejeté par luaL_checktype
                // au-dessus avec luaL_error, comme le reste du
                // projet.
                std::string msg = "inotify: add: event #";
                msg += std::to_string(i);
                msg += " must be a string, got ";
                msg += lua_typename(L, lua_type(L, -1));
                lua_pop(L, 1);
                return push_fail_protected(L, msg);
            }
            std::string ename;
            std::string event_err;
            if (!lua_string_without_nul(L, -1, ename,
                                        "inotify: add: event", event_err))
            {
                lua_pop(L, 1);
                return push_fail_protected(L, event_err);
            }
            uint32_t flag = event_name_to_flag(ename);
            if (flag == 0)
            {
                std::string msg = "inotify: add: unknown event '";
                msg += ename;
                msg += "'";
                lua_pop(L, 1);
                return push_fail_protected(L, msg);
            }
            mask |= flag;
            lua_pop(L, 1);
        }

        // Vérification stricte : la table events doit être une vraie
        // liste 1..count, sans clé supplémentaire (sparse, non-integer,
        // ou string). Sans ce check, une table mixte du genre
        // {"create", x="extra"} verrait "x" ignoré silencieusement,
        // ce qui viole l'esprit "pas de comportement silencieux" du
        // projet. Pattern miroir du scan sparse-keys dans sqlite.cpp.
        lua_pushnil(L); // first key
        while (lua_next(L, 3) != 0)
        {
            int kt = lua_type(L, -2);
            if (kt == LUA_TNUMBER && lua_is_strict_integer(L, -2))
            {
                lua_Integer idx = lua_tointeger(L, -2);
                if (idx < 1 || idx > count)
                {
                    std::string msg = "inotify: add: events table has "
                                      "extra integer key [" +
                                      std::to_string(idx) +
                                      "] outside 1.." +
                                      std::to_string(count);
                    lua_pop(L, 2); // value + key
                    return push_fail_protected(L, msg);
                }
            }
            else if (kt == LUA_TNUMBER)
            {
                // Float key (e.g. [1.5])
                lua_pop(L, 2);
                return push_fail_protected(L,
                                 "inotify: add: events table has a "
                                 "non-integer numeric key");
            }
            else if (kt == LUA_TSTRING)
            {
                size_t key_len = 0;
                const char *key = lua_tolstring(L, -2, &key_len);
                std::string msg = "inotify: add: events table has "
                                  "extra string key '";
                msg.append(key, key_len);
                msg += "' (events must be a list, not a dict)";
                lua_pop(L, 2);
                return push_fail_protected(L, msg);
            }
            else
            {
                // Autre type de clé (table, boolean...) : très rare,
                // on refuse pour rester strict.
                lua_pop(L, 2);
                return push_fail_protected(L,
                                 "inotify: add: events table has a "
                                 "key of unexpected type");
            }
            lua_pop(L, 1); // value, keep key for next iteration
        }

        // Construire les propriétaires C++ seulement APRÈS tout parcours de
        // la table Lua. Ainsi, un longjmp provenant de lua_rawgeti/lua_next
        // ne peut contourner aucun destructeur std::string.
        std::string path;
        std::string string_err;
        if (!lua_string_without_nul(L, 2, path,
                                    "inotify: add: path", string_err))
        {
            return push_fail_protected(L, string_err);
        }

        int wd = ::inotify_add_watch(w->fd, path.c_str(), mask);
        if (wd < 0)
        {
            return push_errno_fail(L, "add");
        }
        lua_pushinteger(L, wd);
        return 1;
    }

    int inot_read(lua_State *L)
    {
        if (!lua_arity_between(L, 1, 2))
        {
            return luaL_error(L, "inotify.read expects an optional timeout");
        }
        Watcher *w = check_watcher(L, 1);
        if (w->fd < 0)
        {
            return push_fail_protected(L, "inotify: read: watcher is closed");
        }

        // timeout : absent/nil -> bloquant infini. Sinon doit être
        // un nombre fini >= 0 (0 = non bloquant, rend ce qui est
        // dispo tout de suite). Refuser NaN/Inf cohérent avec le
        // reste du projet (exec, socket, workers).
        Deadline deadline = NO_DEADLINE;
        if (!lua_is_none_or_nil(L, 2))
        {
            if (!lua_is_strict_number(L, 2))
            {
                return luaL_error(L,
                                  "inotify.read timeout must be a number");
            }
            const double secs = lua_tonumber(L, 2);
            if (std::isnan(secs) || !std::isfinite(secs) || secs < 0)
            {
                return push_fail_protected(L,
                                 "inotify: read: timeout must be a "
                                 "finite number >= 0");
            }
            if (secs * 1000.0 > static_cast<double>(INT_MAX))
            {
                return push_fail_protected(L,
                                 "inotify: read: timeout too large");
            }
            const auto timeout_ms = static_cast<long long>(secs * 1000.0);
            deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);
        }

        // Buffer aligné pour struct inotify_event. Dimensionné large
        // pour batcher plusieurs événements en un seul read() ; doit
        // pouvoir contenir au moins un événement de nom maximal
        // (sizeof(struct inotify_event) + NAME_MAX + 1) sinon read()
        // renverrait EINVAL.
        alignas(struct inotify_event) char buf[8192];

        ssize_t n = 0;
        for (;;)
        {
            int wr = wait_readable_deadline(w->fd, deadline);
            if (wr == WAIT_INTERRUPTED)
            {
                signal_dispatch_pending(L);
                return push_fail_protected(L, "interrupted");
            }
            if (wr == 0)
            {
                return push_fail_protected(L, "timeout");
            }
            if (wr < 0)
            {
                return push_errno_fail(L, "read"); // poll a échoué
            }

            // FD signalé lisible : lire.
            n = ::read(w->fd, buf, sizeof(buf));
            if (n < 0)
            {
                if (errno == EINTR)
                {
                    if (signal_any_handled_pending())
                    {
                        signal_dispatch_pending(L);
                        return push_fail_protected(L, "interrupted");
                    }
                    continue; // signal non géré : re-poll
                }
                if (errno == EAGAIN || errno == EWOULDBLOCK)
                {
                    // Race entre poll() et read() (autre consommateur,
                    // ou faux positif). Re-poll : la deadline borne
                    // la boucle, pas d'attente infinie possible.
                    continue;
                }
                return push_errno_fail(L, "read");
            }
            if (n == 0)
            {
                // inotify ne fait jamais d'EOF ; défensif pour ne pas
                // boucler indéfiniment si ça arrivait.
                return push_fail_protected(L,
                                 "inotify: read: unexpected zero-length read");
            }
            break; // n > 0 : on a des événements
        }

        // Parcours du buffer : suite de struct inotify_event de taille
        // variable (header fixe + name[len]).
        lua_newtable(L); // array des événements
        lua_Integer idx = 1;
        std::size_t off = 0;
        const std::size_t buffer_size = static_cast<std::size_t>(n);
        while (true)
        {
            babet::inotify_detail::RecordView view;
            const auto status = babet::inotify_detail::next_record(
                buf, buffer_size, off, view);
            if (status ==
                babet::inotify_detail::RecordStatus::truncated_header)
            {
                return push_fail_protected(
                    L, "inotify: malformed event buffer: truncated header");
            }
            if (status ==
                babet::inotify_detail::RecordStatus::truncated_name)
            {
                return push_fail_protected(
                    L, "inotify: malformed event buffer: truncated name");
            }
            if (status == babet::inotify_detail::RecordStatus::end)
            {
                break;
            }

            lua_newtable(L); // l'événement

            if (view.mask & IN_Q_OVERFLOW)
            {
                // Débordement de queue : événements perdus. wd == -1,
                // pas de nom. On le remonte EXPLICITEMENT (INOT-D).
                lua_pushinteger(L, -1);
                lua_setfield(L, -2, "wd");
                lua_pushliteral(L, "");
                lua_setfield(L, -2, "name");
                lua_newtable(L);
                lua_pushboolean(L, 1);
                lua_setfield(L, -2, "overflow");
                lua_setfield(L, -2, "events");
                lua_pushboolean(L, 0);
                lua_setfield(L, -2, "is_dir");
                lua_pushinteger(L, 0);
                lua_setfield(L, -2, "cookie");
            }
            else
            {
                lua_pushinteger(L, view.wd);
                lua_setfield(L, -2, "wd");

                if (view.len > 0)
                {
                    // name est NUL-terminé et padné jusqu'à len.
                    const std::size_t nl =
                        ::strnlen(view.name, static_cast<std::size_t>(view.len));
                    lua_pushlstring(L, view.name, nl);
                }
                else
                {
                    lua_pushliteral(L, "");
                }
                lua_setfield(L, -2, "name");

                lua_newtable(L);
                decode_flags_into_table(L, view.mask);
                lua_setfield(L, -2, "events");

                lua_pushboolean(L, (view.mask & IN_ISDIR) ? 1 : 0);
                lua_setfield(L, -2, "is_dir");

                lua_pushinteger(L,
                                static_cast<lua_Integer>(view.cookie));
                lua_setfield(L, -2, "cookie");
            }

            lua_rawseti(L, -2, idx); // array[idx] = event
            ++idx;
            off += view.record_size;
        }

        lua_pushnil(L); // (events, nil)
        return 2;
    }

    int inot_remove(lua_State *L)
    {
        if (!lua_arity_is(L, 2))
        {
            return luaL_error(L, "inotify.remove expects a watch descriptor");
        }
        Watcher *w = check_watcher(L, 1);
        if (!lua_is_strict_integer(L, 2))
        {
            return luaL_error(
                L, "inotify.remove expects an integer watch descriptor");
        }
        const lua_Integer wd = lua_tointeger(L, 2);
        if (wd < static_cast<lua_Integer>(INT_MIN) ||
            wd > static_cast<lua_Integer>(INT_MAX))
        {
            return push_fail_protected(L,
                             "inotify: remove: watch descriptor out of range");
        }
        if (w->fd < 0)
        {
            return push_fail_protected(L, "inotify: remove: watcher is closed");
        }
        // Note : le noyau émet un événement `ignored` pour ce wd juste
        // après le retrait — visible au prochain read().
        if (::inotify_rm_watch(w->fd, static_cast<int>(wd)) != 0)
        {
            return push_errno_fail(L, "remove");
        }
        return push_ok_protected(L);
    }

    int inot_close(lua_State *L)
    {
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L, "inotify.close expects no argument");
        }
        Watcher *w = check_watcher(L, 1);
        if (w->fd >= 0)
        {
            ::close(w->fd);
            w->fd = -1;
        }
        return push_ok_protected(L); // idempotent
    }

    int inot_gc(lua_State *L)
    {
        Watcher *w = static_cast<Watcher *>(
            luaL_testudata(L, 1, INOT_META));
        if (w && w->fd >= 0)
        {
            ::close(w->fd);
            w->fd = -1;
        }
        return 0;
    }

    int inot_tostring(lua_State *L)
    {
        Watcher *w = check_watcher(L, 1);
        if (w->fd < 0)
        {
            lua_pushliteral(L, "inotify (closed)");
        }
        else
        {
            lua_pushfstring(L, "inotify (fd=%d)", w->fd);
        }
        return 1;
    }

    int lua_inotify_new(lua_State *L)
    {
        if (!lua_arity_is(L, 0))
        {
            return luaL_error(L, "inotify.new expects no argument");
        }
        // IN_NONBLOCK : read() pilote son blocage via poll() (INOT-C).
        // IN_CLOEXEC  : pas d'héritage par les sous-processus exec
        //               (INOT-F, même rationale que les sockets).
        int fd = ::inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        if (fd < 0)
        {
            return push_errno_fail(L, "new");
        }
        OwnedFd owned_fd(fd);
        auto builder = [fd](lua_State *Ls) noexcept -> int
        {
            push_new_watcher(Ls, fd);
            return 1;
        };
        const int result = lua_build_results_protected(L, builder, 1);
        owned_fd.release();
        return result;
    }

    template <int (*Fn)(lua_State *)>
    int inotify_lua_boundary(lua_State *L)
    {
        return lua_cfunction_exception_boundary<Fn>(
            L, "inotify: out of memory", "inotify: internal failure",
            "inotify: unknown internal failure");
    }

    int inotify_gc_boundary(lua_State *L) noexcept
    {
        try
        {
            return inot_gc(L);
        }
        catch (...)
        {
            // A __gc metamethod cannot report a useful result. Its only
            // responsibility on an exceptional path is to avoid unwinding a
            // C++ exception through Lua's C frames.
            return 0;
        }
    }

} // namespace

void register_inotify(lua_State *L)
{
    // 1. Métatable LuapilotInotify dans le registry (une fois).
    if (luaL_newmetatable(L, INOT_META))
    {
        // Méthodes via __index = la métatable elle-même.
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");

        // __gc : filet anti-fuite de FD (cf. INOT-C/F).
        lua_pushcfunction(L, inotify_gc_boundary);
        lua_setfield(L, -2, "__gc");

        lua_pushcfunction(L, inotify_lua_boundary<inot_tostring>);
        lua_setfield(L, -2, "__tostring");

        lua_pushcfunction(L, inotify_lua_boundary<inot_add>);
        lua_setfield(L, -2, "add");
        lua_pushcfunction(L, inotify_lua_boundary<inot_read>);
        lua_setfield(L, -2, "read");
        lua_pushcfunction(L, inotify_lua_boundary<inot_remove>);
        lua_setfield(L, -2, "remove");
        lua_pushcfunction(L, inotify_lua_boundary<inot_close>);
        lua_setfield(L, -2, "close");
    }
    lua_pop(L, 1); // dépile la métatable ; table babet au sommet

    // 2. Sous-table babet.inotify.
    //    Précondition : table babet au sommet (-1).
    lua_newtable(L);
    lua_pushcfunction(L, inotify_lua_boundary<lua_inotify_new>);
    lua_setfield(L, -2, "new");
    lua_setfield(L, -2, "inotify");
}
