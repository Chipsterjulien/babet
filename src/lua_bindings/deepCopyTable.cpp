#include "deepCopyTable.hpp"
#include "lua_utils.hpp"
#include <cassert>

/**
 * @brief Copie profondément la table à `srcIndex` (voir deepCopyTable.hpp).
 *
 * Principe pour les cycles : la copie d'une table est enregistrée dans
 * `visited` AVANT de parcourir ses éléments. Ainsi, si le parcours retombe
 * sur la même table source (cycle direct ou indirect, ou sous-table
 * partagée), on réutilise la copie déjà créée au lieu d'en refaire une.
 */
bool deepCopyTable(lua_State *L, int srcIndex, int depth, int maxDepth, VisitedMap &visited)
{
    assert(lua_istable(L, srcIndex));

    // Index absolu : la pile va grandir, un index relatif deviendrait faux.
    srcIndex = lua_absindex(L, srcIndex);

    const void *srcPointer = lua_topointer(L, srcIndex);

    // Déjà copiée ? On réutilise la copie existante AVANT d'appliquer la
    // limite de profondeur. Une référence cyclique ou partagée ne descend
    // pas réellement dans une nouvelle table : la refuser uniquement parce
    // que l'arête de retour se trouve à maxDepth + 1 cassait les cycles qui
    // se refermaient exactement à la profondeur maximale autorisée.
    auto it = visited.find(srcPointer);
    if (it != visited.end())
    {
        assert(it->second != LUA_NOREF);
        if (!lua_checkstack(L, 1))
        {
            return false;
        }
        lua_rawgeti(L, LUA_REGISTRYINDEX, it->second); // pousse la copie
        return true;
    }

    if (depth > maxDepth)
    {
        return false;
    }

    // Réserver la pile AVANT de pousser. L'API Lua ne garantit qu'environ
    // LUA_MINSTACK (20) slots libres à l'entrée de la fonction C ; cette
    // récursion consomme des slots à chaque niveau et MAX_DEPTH = 75.
    // lua_checkstack agrandit la pile si nécessaire. En cas d'échec
    // théorique, on propage le canal false existant.
    //
    // Au pic, un niveau utilise cinq slots au-dessus de son point d'entrée :
    // copy, key, value, keyDup et valueCopy.
    if (!lua_checkstack(L, 5))
    {
        return false;
    }

    // Réserve d'abord l'entrée C++ SANS référence Lua. Si l'allocation de
    // l'unordered_map échoue, aucune référence du registre n'existe encore.
    // Si une allocation Lua échoue ensuite, le nettoyage extérieur voit
    // LUA_NOREF et n'a rien à libérer pour cette entrée incomplète.
    auto [visited_it, inserted] = visited.emplace(srcPointer, LUA_NOREF);
    assert(inserted);

    // Nouvelle table de destination.
    lua_newtable(L);
    int copyIndex = lua_absindex(L, -1);

    // On enregistre la copie dans le registre AVANT de parcourir la source,
    // pour que les références cycliques retrouvent cette copie-ci.
    lua_pushvalue(L, copyIndex);              // duplique la copie
    int ref = luaL_ref(L, LUA_REGISTRYINDEX); // luaL_ref dépile le doublon
    visited_it->second = ref;                 // affectation non allouante

    // Parcours de toutes les paires (clé, valeur) de la source.
    lua_pushnil(L);
    while (lua_next(L, srcIndex) != 0)
    {
        // Pile : ..., copy, key, value
        int valueIndex = lua_absindex(L, -1);
        int keyIndex = valueIndex - 1;

        // On duplique la clé (l'originale doit rester pour lua_next).
        // Les clés sont réutilisées telles quelles, pas copiées en profondeur.
        lua_pushvalue(L, keyIndex); // ..., copy, key, value, keyDup

        // Préparation de la valeur copiée, posée au sommet.
        if (lua_istable(L, valueIndex))
        {
            if (!deepCopyTable(L, valueIndex, depth + 1, maxDepth, visited))
            {
                // Échec en profondeur : on restaure la pile de ce niveau
                // (keyDup, value, key, copy) avant de propager l'échec.
                lua_pop(L, 4);
                return false;
            }
            // ..., copy, key, value, keyDup, valueCopy
        }
        else
        {
            lua_pushvalue(L, valueIndex); // ..., copy, key, value, keyDup, valueCopy
        }

        // copy[keyDup] = valueCopy ; lua_settable dépile keyDup et valueCopy.
        lua_settable(L, copyIndex); // ..., copy, key, value

        lua_pop(L, 1); // retire value, garde key
        // ..., copy, key
    }

    // La métatable est PARTAGÉE avec la source (comportement standard d'un
    // deep copy : on ne recopie pas la métatable elle-même).
    if (lua_getmetatable(L, srcIndex))
    {
        lua_setmetatable(L, copyIndex);
    }

    // La copie est au sommet de la pile.
    return true;
}

namespace
{
void release_visited_references(lua_State *L,
                                const VisitedMap &visited) noexcept
{
    for (const auto &entry : visited)
    {
        if (entry.second != LUA_NOREF && entry.second != LUA_REFNIL)
        {
            luaL_unref(L, LUA_REGISTRYINDEX, entry.second);
        }
    }
}

int lua_deepCopyTable_impl(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "Expected one argument (a table)");
    }
    if (!lua_istable(L, 1))
    {
        return luaL_error(L, "Argument must be a table");
    }

    VisitedMap visited;
    auto builder = [&visited](lua_State *Ls) -> int
    {
        // Argument 1 belongs to lua_build_results_protected's internal
        // context. The original source table is forwarded explicitly as
        // argument 2 of this protected frame.
        if (!deepCopyTable(Ls, 2, 0, MAX_DEPTH, visited))
        {
            return luaL_error(
                Ls, "Table is too deep to copy (max depth %d exceeded)",
                MAX_DEPTH);
        }
        return 1;
    };

    try
    {
        const int result = lua_build_results_protected_with_stack_value(
            L, builder, 1, 1);
        release_visited_references(L, visited);
        return result;
    }
    catch (...)
    {
        // Le pcall intérieur a déjà transformé tout longjmp Lua en exception
        // C++. Les références sont donc libérées et la map détruite avant que
        // la frontière publique ne relance l'erreur Lua d'origine.
        release_visited_references(L, visited);
        throw;
    }
}
} // namespace

int lua_deepCopyTable(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_deepCopyTable_impl>(
        L, "deepCopyTable: out of memory",
        "deepCopyTable: internal failure",
        "deepCopyTable: unknown internal failure");
}
