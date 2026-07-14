#ifndef SLEEP_HPP
#define SLEEP_HPP

#include <lua.hpp>

/**
 * Binding Lua :
 *
 *   babet.sleep(amount [, unit])
 *     -> (true, nil)
 *      | (nil, "interrupted")
 *      | (nil, "Invalid time unit")
 *      | (nil, "sleep: <system error>")
 *
 * `amount` doit être un number Lua fini et non négatif. `unit` doit être
 * une vraie string Lua parmi "s" (défaut), "ms" et "us". Les erreurs de
 * type, d'arité, NaN/Inf, valeurs négatives et durées trop grandes lèvent
 * une erreur Lua. Une unité textuelle inconnue conserve le contrat
 * historique `(nil, "Invalid time unit")`.
 *
 * Le même binding est exposé comme babet.time.sleep.
 */
int lua_sleep(lua_State *L);

#endif // SLEEP_HPP
