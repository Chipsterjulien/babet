#ifndef TIME_FORMAT_HPP
#define TIME_FORMAT_HPP

#include <lua.hpp>

/**
 * Bindings exposés sous la sous-table `babet.time` :
 *
 *   babet.time.iso([ts])           -> string UTC
 *   babet.time.parse_iso(s)        -> (unix_ts integer, nil)
 *                                     | (nil, "parse_iso: ...")
 *   babet.time.parse_duration(s)   -> (seconds integer, nil)
 *                                     | (nil, "parse_duration: ...")
 *   babet.time.format_duration(n)  -> "1d2h3m4s"
 *
 * Contrat de types strict : aucune coercition implicite entre strings et
 * numbers. `iso` accepte zéro ou un number ; `format_duration` un number
 * entier non négatif ; les deux parseurs exactement une string.
 *
 * `iso` formate en UTC, sans locale ni base de fuseaux. Les fractions sont
 * arrondies vers -infini à la seconde. `parse_iso` accepte volontairement
 * un sous-ensemble strict à année sur quatre chiffres et timezone requise.
 *
 * Contrat d'erreur :
 *   - iso / format_duration lèvent pour toute entrée invalide ;
 *   - parse_iso / parse_duration lèvent pour type ou arité incorrects,
 *     mais renvoient `(nil, "<fonction>: <raison>")` pour un texte invalide.
 */
int lua_time_iso(lua_State *L);
int lua_time_parse_iso(lua_State *L);
int lua_time_parse_duration(lua_State *L);
int lua_time_format_duration(lua_State *L);

#endif // TIME_FORMAT_HPP
