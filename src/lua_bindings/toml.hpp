#ifndef TOML_HPP
#define TOML_HPP

#include <lua.hpp>

/**
 * @brief Binding TOML : babet.toml.decode(s) -> (table, nil) | (nil, err)
 *
 * Contrat public :
 *
 *   - Périmètre v1 : decode seul. Pas d'encode, decode_file,
 *     options de parsing, schéma ni sentinelle de type.
 *
 *   - Arite et erreurs :
 *       * exactement une chaîne Lua est exigée ; mauvais usage -> luaL_error
 *       * TOML invalide -> (nil, "toml: <description> (line L, col C)")
 *       * succès -> (table, nil)
 *
 *   - Mapping :
 *       * string -> chaîne Lua binary-safe
 *       * integer int64 -> entier Lua (Lua 5.5 standard : int64)
 *       * float, y compris inf/nan -> nombre Lua
 *       * boolean -> booléen Lua
 *       * array -> table Lua séquentielle 1..n
 *       * table -> table Lua à clés chaînes binary-safe
 *
 *     Les tableaux vides et tables TOML vides deviennent tous deux une
 *     table Lua vide ; aucun marquage ne permet de les distinguer ensuite.
 *
 *   - Types temporels TOML -> chaînes ISO 8601 normalisées :
 *       local-date       : "YYYY-MM-DD"
 *       local-time       : "HH:MM:SS[.fffffffff]"
 *       local-date-time  : "YYYY-MM-DDTHH:MM:SS[.fffffffff]"
 *       offset-date-time : "YYYY-MM-DDTHH:MM:SS[.fffffffff]<+|-HH:MM|Z>"
 *
 *     La valeur temporelle est conservée, mais sa graphie d'origine peut
 *     être normalisée et elle devient indiscernable d'une string TOML.
 *
 *   - Les clés citées sont poussées avec leur longueur explicite : un
 *     caractère U+0000 obtenu par une séquence TOML \u0000 ne doit jamais
 *     être tronqué par une API attendant une chaîne C.
 *
 *   - Aucune exception C++ ne traverse vers Lua. toml++ est compilé avec
 *     TOML_EXCEPTIONS=0 et la conversion est protégée par un try/catch.
 */

int lua_toml_decode(lua_State *L);

/**
 * @brief Construit la sous-table `toml` et l'attache à babet.
 *
 * Précondition : la table babet est au sommet de la pile (-1), exactement
 * comme register_json / register_http. La pile est inchangée après l'appel.
 */
void register_toml(lua_State *L);

#endif // TOML_HPP
