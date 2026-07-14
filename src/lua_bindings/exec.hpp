#ifndef EXEC_HPP
#define EXEC_HPP

#include <lua.hpp>

/**
 * @brief Exécute un programme externe sans shell implicite.
 *
 * API Lua :
 *
 *   result, err = babet.exec(cmd [, args] [, opts])
 *
 *   cmd  : chaîne stricte, programme recherché dans PATH ou chemin direct.
 *   args : table séquence de chaînes, facultative ; aucun parsing shell.
 *   opts : table facultative :
 *          - cwd        : chaîne, répertoire de travail de l'enfant ;
 *          - env        : table string -> string fusionnée avec environ ;
 *          - stdin      : chaîne binaire envoyée puis pipe fermé ;
 *          - timeout    : nombre fini strictement positif, secondes ;
 *          - max_output : entier 1..2 Gio, plafond distinct pour stdout
 *                         et stderr (défaut 10 Mio par flux).
 *
 * En lancement réussi, même si le programme sort non-zéro ou expire :
 *
 *   result = {
 *       stdout = string,             // binary-safe, éventuellement tronquée
 *       stderr = string,             // binary-safe, éventuellement tronquée
 *       code = integer,              // exit code ou 128 + signal ; parfois -1
 *       timed_out = boolean,
 *       stdout_truncated = boolean,
 *       stderr_truncated = boolean,
 *   }
 *   err = nil
 *
 * Une erreur avant exec effectif (programme absent, cwd invalide, validation
 * des options, erreur de poll interne, etc.) renvoie (nil, err). Seul cmd
 * absent ou non string relève de luaL_error. Le timeout couvre préparation,
 * lancement, E/S et attente finale ; à expiration, le groupe enfant reçoit
 * SIGTERM, puis SIGKILL après le délai de grâce interne.
 *
 * @param L État Lua.
 * @return Nombre de valeurs laissées sur la pile (toujours 2 sauf erreur Lua).
 */
int lua_exec(lua_State *L);

#endif // EXEC_HPP
