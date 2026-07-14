#ifndef DEEPCOPYTABLE_HPP
#define DEEPCOPYTABLE_HPP

#include <lua.hpp>
#include <unordered_map>

/**
 * @file deepCopyTable.hpp
 * @brief Déclarations pour la copie profonde des tables Lua.
 *
 * La copie profonde duplique récursivement les VALEURS qui sont des tables.
 * Les clés sont conservées telles quelles : une table utilisée comme clé
 * reste donc la table source, elle n'est pas copiée. La métatable de chaque
 * table copiée est partagée avec la source. Les cycles et sous-tables
 * partagées rencontrés dans les valeurs sont préservés : une table source
 * ne donne lieu qu'à une seule copie, réutilisée partout.
 */

constexpr int MAX_DEPTH = 75; // 75 descentes sous la racine (profondeur racine = 0)

/**
 * @brief Associe le pointeur d'une table source à la référence (registre Lua)
 *        de sa copie déjà créée. Sert à la détection de cycles et au partage
 *        des sous-tables communes.
 */
using VisitedMap = std::unordered_map<const void *, int>;

/**
 * @brief Copie profondément la table à l'index `srcIndex`.
 *
 * En cas de succès, la copie est poussée au sommet de la pile Lua.
 * En cas d'échec (profondeur maximale dépassée), la pile est laissée
 * inchangée.
 *
 * @param L L'état Lua.
 * @param srcIndex Index de la table source (relatif ou absolu).
 * @param depth Profondeur actuelle de la récursion.
 * @param maxDepth Profondeur maximale autorisée.
 * @param visited Tables déjà copiées (pointeur source -> référence de la copie).
 * @return true si la copie a réussi (copie au sommet de la pile), false sinon.
 */
bool deepCopyTable(lua_State *L, int srcIndex, int depth, int maxDepth, VisitedMap &visited);

/**
 * @brief Liaison Lua pour effectuer une copie profonde d'une table.
 *
 * Usage Lua:
 *     copiedTable = babet.deepCopyTable(originalTable)
 *
 * @param L L'état Lua.
 * @return int Le nombre de valeurs retournées à Lua (1 : la table copiée).
 */
int lua_deepCopyTable(lua_State *L);

#endif // DEEPCOPYTABLE_HPP
