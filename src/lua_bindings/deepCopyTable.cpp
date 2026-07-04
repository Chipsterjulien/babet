#include "deepCopyTable.hpp"
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

    if (depth > maxDepth)
    {
        return false;
    }

    // CORRECTIF (revue Gemini post-audit v21, vérifié) : réserver la
    // pile AVANT de pousser. L'API Lua ne garantit qu'environ
    // LUA_MINSTACK (20) slots libres à l'entrée de la fonction C ;
    // cette récursion consomme des slots à CHAQUE niveau et
    // MAX_DEPTH = 75 (cf. deepCopyTable.hpp) : atteindre le plafond
    // suppose déjà ~75 x 5 = ~375 slots poussés — une table
    // légalement imbriquée débordait donc la pile allouée bien avant
    // le garde-fou de profondeur -> corruption mémoire (UB), pas une
    // erreur propre.
    // Même classe de bug déjà corrigée dans json.cpp (lignes ~220 et
    // ~295) lors d'une session précédente — le garde n'avait jamais
    // été propagé ici. lua_checkstack FAIT GRANDIR la pile si besoin
    // (jusqu'à ~LUAI_MAXSTACK) : l'échec est donc théorique, et
    // MAX_DEPTH déclenche bien avant ; on rend false par le canal
    // existant (le caller signale « too deep », approximation
    // acceptable pour un cas inatteignable en pratique).
    //
    // Comptage : au pic, un niveau a 5 slots simultanés au-dessus de
    // son point d'entrée — copy, key, value, keyDup, valueCopy (le
    // 5e est poussé par CE niveau quand la valeur n'est pas une
    // table ; pour une table, il est réservé par le checkstack de
    // l'appel récursif enfant). Les autres chemins (rawgeti,
    // pushvalue+luaL_ref, getmetatable) restent sous 5.
    if (!lua_checkstack(L, 5))
    {
        return false;
    }

    // Index absolu : la pile va grandir, un index relatif deviendrait faux.
    srcIndex = lua_absindex(L, srcIndex);

    const void *srcPointer = lua_topointer(L, srcIndex);

    // Déjà copiée ? On réutilise la copie existante (gère cycles + partage).
    auto it = visited.find(srcPointer);
    if (it != visited.end())
    {
        lua_rawgeti(L, LUA_REGISTRYINDEX, it->second); // pousse la copie
        return true;
    }

    // Nouvelle table de destination.
    lua_newtable(L);
    int copyIndex = lua_absindex(L, -1);

    // On enregistre la copie dans le registre AVANT de parcourir la source,
    // pour que les références cycliques retrouvent cette copie-ci.
    lua_pushvalue(L, copyIndex);              // duplique la copie
    int ref = luaL_ref(L, LUA_REGISTRYINDEX); // luaL_ref dépile le doublon
    visited[srcPointer] = ref;

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

int lua_deepCopyTable(lua_State *L)
{
    if (lua_gettop(L) != 1)
    {
        return luaL_error(L, "Expected one argument (a table)");
    }
    if (!lua_istable(L, 1))
    {
        return luaL_error(L, "Argument must be a table");
    }

    // Scope explicite pour la VisitedMap : sur Lua compilé en C
    // (cas par défaut), luaL_error utilise longjmp() qui ne déroule
    // PAS les destructeurs C++. Sans ce scope, en cas de profondeur
    // dépassée, le longjmp dans le luaL_error final fuierait les
    // buckets de la unordered_map. On force ici sa destruction
    // AVANT toute possibilité de longjmp.
    bool ok;
    {
        VisitedMap visited;
        ok = deepCopyTable(L, 1, 0, MAX_DEPTH, visited);

        // Libère toutes les références registre créées pour la
        // détection de cycles, qu'on ait réussi ou échoué : sinon
        // fuite dans le registre Lua.
        for (const auto &entry : visited)
        {
            luaL_unref(L, LUA_REGISTRYINDEX, entry.second);
        }
    } // ← 'visited' détruit proprement ici (avant longjmp éventuel).

    if (!ok)
    {
        return luaL_error(L, "Table is too deep to copy (max depth %d exceeded)", MAX_DEPTH);
    }

    // deepCopyTable a poussé la copie au sommet de la pile.
    return 1;
}
