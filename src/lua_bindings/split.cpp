#include "split.hpp"
#include <string>
#include <string_view>

/**
 * @brief Splits a given string using a specified delimiter and inserts the substrings into a Lua table.
 *
 * This function expects up to three arguments from the Lua stack:
 * - The string to be split (binary-safe, NUL bytes preserved).
 * - An optional single-character delimiter.
 * - An optional maximum number of splits (default -1 = no limit);
 *   the uncut remainder lands in the last element.
 *
 * If the delimiter is an empty string, OR OMITTED, the function splits
 * the input string into individual bytes ("byte mode").
 * There is no default delimiter. (Docstring corrigée à l'audit v21 :
 * elle annonçait un espace par défaut, ce qui n'a jamais été le
 * comportement — décision : doc alignée sur le code, API inchangée.)
 * Frozen edge cases, documented and tested: split("", sep) returns
 * { "" } (one empty entry); split("") in character mode returns {}.
 * The resulting substrings are pushed into a Lua table which is then returned.
 *
 * @param L The Lua state.
 * @return int The number of results to be returned to Lua (always 1, the table of substrings).
 *
 * @throws luaL_error If the arguments are invalid (wrong types,
 *         delimiter longer than one character, max_splits < -1).
 */
int lua_split(lua_State *L)
{
    int argc = lua_gettop(L);
    if (argc < 1 || argc > 3)
    {
        return luaL_error(L, "Expected 1 to 3 arguments: string, optional delimiter, and optional max_splits");
    }

    // Lua's lua_isstring() also accepts numbers because they can be
    // converted to text. The public API requires an actual Lua string.
    if (lua_type(L, 1) != LUA_TSTRING)
    {
        return luaL_error(L, "Expected a Lua string as the first argument");
    }
    // CORRECTIF (audit v21) : longueur Lua réelle via luaL_checklstring,
    // plus std::strlen. Les strings Lua peuvent contenir des NUL ;
    // strlen tronquait silencieusement le sujet au premier '\0'
    // (split("a\0b,c", ",") rendait {"a"} au lieu de {"a\0b", "c"}).
    // Incohérent avec le reste de la fonction, qui mesure déjà le
    // délimiteur avec lua_rawlen. Tout le corps travaille sur
    // (str, str_len) et lua_pushlstring : binaire-safe de bout en bout.
    size_t str_len = 0;
    const char *str = luaL_checklstring(L, 1, &str_len);

    char delimiter = ' ';
    bool has_delimiter = false;
    if (argc >= 2)
    {
        if (lua_type(L, 2) != LUA_TSTRING)
        {
            return luaL_error(L, "Expected a Lua string as the second argument");
        }
        size_t delim_len = 0;
        const char *delim = luaL_checklstring(L, 2, &delim_len);
        if (delim_len == 1)
        {
            delimiter = delim[0];
            has_delimiter = true;
        }
        else if (delim_len > 1)
        {
            return luaL_error(L, "Delimiter should contain zero or one byte");
        }
    }

    // CORRECTIF (revue ChatGPT post-audit v21, vérifié) : max_splits
    // reste en lua_Integer de bout en bout. L'ancien code le rangeait
    // dans un int : un entier Lua valide hors plage int subissait un
    // narrowing dépendant de l'implémentation — split(s, ",", 2^32)
    // devenait silencieusement max_splits = 0 (résultat { s } au lieu
    // du découpage complet), et split(s, ",", 2^31) donnait l'erreur
    // absurde "should be -1 or greater" pour une entrée positive.
    lua_Integer max_splits = -1;
    if (argc == 3)
    {
        if (!lua_isinteger(L, 3))
        {
            return luaL_error(L, "Expected an integer as the third argument");
        }
        max_splits = luaL_checkinteger(L, 3);
        if (max_splits < -1)
        {
            return luaL_error(L, "max_splits should be -1 or greater");
        }
    }

    lua_newtable(L);
    int table_index = lua_gettop(L);

    if (!has_delimiter)
    {
        // Split by bytes (not Unicode code points).
        for (size_t i = 0; i < str_len; ++i)
        {
            lua_pushinteger(L, i + 1);
            lua_pushlstring(L, str + i, 1);
            lua_settable(L, table_index);
        }
    }
    else
    {
        std::string_view str_view(str, str_len);
        size_t start = 0;
        size_t end = 0;
        // splits comparé à max_splits : même type pour éviter toute
        // promotion surprenante. index reste lua_Integer par symétrie
        // (l'excursion au-delà de 2^31 éléments est théorique mais le
        // type juste ne coûte rien).
        lua_Integer splits = 0;
        lua_Integer index = 1;

        while (end != std::string::npos)
        {
            end = str_view.find_first_of(delimiter, start);
            if (end == std::string::npos || (max_splits != -1 && splits >= max_splits))
            {
                lua_pushinteger(L, index++);
                lua_pushlstring(L, str + start, str_len - start);
                lua_settable(L, table_index);
                break;
            }
            else
            {
                lua_pushinteger(L, index++);
                lua_pushlstring(L, str + start, end - start);
                lua_settable(L, table_index);
                start = end + 1;
                ++splits;
            }
        }
    }

    return 1;
}
