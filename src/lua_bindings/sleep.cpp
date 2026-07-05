#include "sleep.hpp"
#include "lua_utils.hpp"
#include "signal.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>
#include <cerrno>
#include <cstring>
#include <time.h>

/**
 * Converts a string to a std::chrono::duration based on the unit.
 * @param duration The duration value.
 * @param unit The unit of time ("s" for seconds, "ms" for milliseconds, "us" for microseconds).
 * @return The corresponding std::chrono::duration.
 */
std::chrono::duration<double> convert_to_duration(double duration, const std::string &unit)
{
    if (unit == "s")
    {
        return std::chrono::duration<double>(duration);
    }
    else if (unit == "ms")
    {
        return std::chrono::duration<double, std::milli>(duration);
    }
    else if (unit == "us")
    {
        return std::chrono::duration<double, std::micro>(duration);
    }
    else
    {
        throw std::invalid_argument("Invalid time unit");
    }
}

/**
 * Lua binding for the sleep function.
 * @param L The Lua state.
 * @return Number of return values (0).
 * Lua usage: lua_sleep(duration, unit)
 *   - duration: The amount of time to sleep.
 *   - unit: The unit of time (optional, default is seconds). Can be "s" for seconds, "ms" for milliseconds, "us" for microseconds.
 *
 * Phase B signal : si un signal géré par babet.signal arrive
 * pendant le sleep, l'attente est interrompue, le callback Lua est
 * dispatché, et la fonction retourne (nil, "interrupted") au lieu
 * de (true, nil). Pour les signaux non gérés (genre SIGWINCH), le
 * sleep est repris avec le temps restant — aucune perte d'attente
 * pour le user.
 */
int lua_sleep(lua_State *L)
{
    int argc = lua_gettop(L);
    if (argc < 1 || argc > 2)
    {
        return luaL_error(L, "Expected one or two arguments: duration and optional unit");
    }
    if (!lua_isnumber(L, 1))
    {
        return luaL_argerror(L, 1, "Expected a number as the first argument for duration");
    }

    double duration = lua_tonumber(L, 1);
    // CORRECTIF (audit v21) : rejeter NaN et ±Inf AVANT le cast
    // time_t plus bas. L'ancien code ne testait que `duration < 0`,
    // qui laisse passer NaN (toute comparaison avec NaN est fausse)
    // et +Inf ; static_cast<time_t>(NaN/Inf) est un comportement
    // indéfini. babet.sleep(0/0) ou babet.sleep(math.huge) le
    // déclenchait. Cohérent avec socket.set_timeout, exec
    // opts.timeout, workers et inotify, qui refusent tous NaN/Inf.
    // Convention : erreur d'argument, comme la durée négative juste
    // en dessous (faute de programmation, pas erreur runtime).
    // Longjmp-safe : uniquement des POD vivants à ce point.
    if (!std::isfinite(duration))
    {
        return luaL_argerror(L, 1, "Duration must be finite (not NaN or inf)");
    }
    if (duration < 0)
    {
        return luaL_argerror(L, 1, "Duration must be non-negative");
    }

    // CORRECTIF longjmp (post-revue Gemini) : `const char *` au lieu
    // de `std::string` pour stocker la valeur par défaut. Si l'arg 2
    // n'est pas une string, luaL_argerror fait un longjmp qui ne
    // déroule PAS les destructeurs C++. Avec un pointeur, rien à
    // détruire. La conversion implicite const char* -> std::string
    // pour l'appel à convert_to_duration se fait à l'intérieur du
    // try/catch, donc une éventuelle exception serait propre.
    const char *unit = "s";
    if (argc == 2)
    {
        if (!lua_isstring(L, 2))
        {
            return luaL_argerror(L, 2, "Expected a string as the second argument for unit");
        }
        unit = lua_tostring(L, 2);
    }

    double seconds;
    try
    {
        auto duration_chrono = convert_to_duration(duration, unit);
        seconds = duration_chrono.count();
    }
    catch (const std::invalid_argument &e)
    {
        return push_fail(L, e.what());
    }

    // CORRECTIF (audit v21) : borne haute avant le cast vers time_t.
    // Subtilité : (double)INT64_MAX n'est PAS représentable en double
    // et s'arrondit à 2^63 exactement, donc le test doit être `>=`
    // (un `>` laisserait passer seconds == 2^63, dont le cast est
    // indéfini). 2^63 secondes ≈ 292 milliards d'années : aucune
    // attente légitime n'est restreinte. Longjmp-safe : seuls des
    // POD sont vivants ici (duration_chrono est mort avec le try).
    constexpr double kMaxTimeT =
        static_cast<double>(std::numeric_limits<time_t>::max());
    if (seconds >= kMaxTimeT)
    {
        return luaL_argerror(L, 1, "Duration too large");
    }

    // Phase B signal : on passe par nanosleep direct (et non
    // std::this_thread::sleep_for qui retry silencieusement sur
    // EINTR) pour pouvoir détecter qu'un signal géré est arrivé.
    struct timespec req;
    req.tv_sec = static_cast<time_t>(seconds);
    req.tv_nsec = static_cast<long>((seconds - static_cast<double>(req.tv_sec)) * 1e9);
    // Clamp pour éviter tv_nsec >= 1e9 dû aux erreurs flottantes.
    if (req.tv_nsec >= 1000000000L)
    {
        req.tv_nsec -= 1000000000L;
        req.tv_sec += 1;
    }
    if (req.tv_nsec < 0)
    {
        req.tv_nsec = 0;
    }

    struct timespec rem;
    for (;;)
    {
        // CORRECTIF (revue ChatGPT post-release, vérifié) : fenêtre
        // PRÉ-attente, même principe que le garde pré-poll de
        // wait_ready_deadline (socket). Un signal géré livré juste
        // AVANT nanosleep posait son flag sans interrompre le sommeil
        // qui suivait : toute la durée s'écoulait avant le dispatch —
        // incohérent avec le contrat signal-aware. Testé à CHAQUE
        // itération (les reprises après un EINTR étranger re-vérifient
        // aussi). NB : la fenêtre n'est pas réduite à zéro (un signal
        // peut tomber entre ce test et l'entrée dans nanosleep) — la
        // fermer totalement demanderait un mécanisme type
        // ppoll/sigmask ; réduction assumée, comme côté socket.
        if (signal_any_handled_pending())
        {
            signal_dispatch_pending(L);
            return push_fail(L, "interrupted");
        }
        if (::nanosleep(&req, &rem) == 0)
        {
            break;
        }
        if (errno != EINTR)
        {
            // Erreur improbable sur Linux moderne (EINVAL si tv_nsec
            // out of range, mais on a clampé). Pas de helper
            // push_errno_fail global dans le projet → message en
            // ligne, cohérent avec le style "sleep: <strerror>".
            std::string msg = "sleep: ";
            msg += std::strerror(errno);
            return push_fail(L, msg);
        }
        // EINTR : un signal est arrivé. Si c'est un signal qu'on
        // gère, on dispatche son callback et on retourne
        // "interrupted". Sinon, on reprend le sleep avec le temps
        // restant.
        if (signal_any_handled_pending())
        {
            signal_dispatch_pending(L);
            return push_fail(L, "interrupted");
        }
        req = rem;
    }

    return push_ok(L);
}
