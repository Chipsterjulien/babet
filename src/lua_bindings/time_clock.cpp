// =====================================================================
// time_clock.cpp — implémentation des bindings monotonic / now
// =====================================================================

#include "time_clock.hpp"
#include "lua_utils.hpp"

#include <cerrno>
#include <cstring>
#include <ctime>
#include <string>

#include <lua.hpp>

namespace
{

    // Convertit un timespec (seconds + nanoseconds) en double seconds.
    // Précision : un double IEEE-754 a 53 bits de mantisse. Sur la
    // plage des timestamps Unix actuels (~10^9 secondes), il reste
    // ~10^16 / 10^9 = 10^7 incréments unitaires représentables — donc
    // ~100 nanosecondes de granularité utile près d'aujourd'hui. Pour
    // CLOCK_MONOTONIC qui démarre à 0 au boot, la précision est sub-µs
    // pendant des décennies. C'est largement suffisant pour les
    // mesures de durée IRC / HTTP / scripts.
    double timespec_to_seconds(const struct timespec &ts)
    {
        return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) / 1.0e9;
    }

    // Helper commun aux deux bindings : pas d'argument accepté.
    // Retourne directement via luaL_error si argument fourni (mauvais
    // usage = faute de programmeur, pas runtime).
    void check_no_args(lua_State *L, const char *fname)
    {
        if (!lua_arity_is(L, 0))
        {
            luaL_error(L,
                       "babet.%s: no arguments expected", fname);
        }
    }

    // push_fail_protected() vient de lua_utils.hpp (helper global du projet).
    // Pas de redéfinition locale.

} // namespace

int lua_monotonic(lua_State *L)
{
    check_no_args(L, "monotonic");

    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    {
        // En pratique impossible sur Linux moderne. On respecte la
        // convention (nil, err) pour cohérence avec le reste de
        // l'API Babet.
        return push_fail_protected(L,
                         std::string("babet.monotonic: clock_gettime failed: ") + std::strerror(errno));
    }

    lua_pushnumber(L, timespec_to_seconds(ts));
    return 1;
}

int lua_now(lua_State *L)
{
    check_no_args(L, "now");

    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
    {
        return push_fail_protected(L,
                         std::string("babet.now: clock_gettime failed: ") + std::strerror(errno));
    }

    lua_pushnumber(L, timespec_to_seconds(ts));
    return 1;
}
