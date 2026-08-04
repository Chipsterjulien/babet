#ifndef SYS_HPP
#define SYS_HPP

#include <lua.hpp>

/**
 * @brief Bindings utilitaires système plats sous babet.*
 *
 * Décisions actées :
 *   - Nommage plat (babet.which, babet.hostname, ...) — cohérent
 *     avec exec, sleep, currentDir.
 *   - Un seul .cpp regroupe le tout (register_sys n'attache PAS de
 *     sous-table : les fonctions sont posées directement sur
 *     babet).
 *   - Contrat d'erreur miroir maison :
 *       * succès : valeur retournée directement (string pour
 *         hostname/which, table pour uname, integer pour pid)
 *       * échec runtime attendu (which inexistant) : (nil, "msg")
 *       * mauvais usage (arg absent / mauvais type) : luaL_error
 *     Cas particulier `env(name)` : variable absente = nil seul
 *     (sans message d'erreur), permet l'idiome `or default`.
 *   - setenv : (true, nil) en succès, (nil, err) en échec — cohérent
 *     avec les autres setters du codebase.
 *   - Les six fonctions sont enregistrées via la frontière d'exception
 *     C++ commune. Seule une exception C++ inattendue ajoute un diagnostic
 *     interne (nil, err) aux contrats ordinaires de env/pid.
 *
 * v1 : which, env, setenv, hostname, uname, pid.
 * Hors v1 (additif plus tard) : getuid, getgid, getenv-tout-renvoyer,
 * unsetenv, getppid, getlogin, ...
 */
int lua_sys_which(lua_State *L);
int lua_sys_env(lua_State *L);
int lua_sys_setenv(lua_State *L);
int lua_sys_hostname(lua_State *L);
int lua_sys_uname(lua_State *L);
int lua_sys_pid(lua_State *L);

/**
 * @brief Attache les fonctions utilitaires plates à la table babet.
 *
 * Précondition : la table babet est au sommet de la pile (-1),
 * exactement comme register_http / register_json. La pile est
 * inchangée après l'appel (les fonctions sont attachées sur la table
 * du sommet, qui reste au sommet).
 *
 * À la différence de register_http qui crée une sous-table 'http',
 * register_sys POSE les fonctions DIRECTEMENT sur babet (nommage
 * plat décidé). Les fonctions exposées sont les wrappers de frontière, jamais
 * les implémentations C++ enregistrées directement.
 */
void register_sys(lua_State *L);

#endif // SYS_HPP
