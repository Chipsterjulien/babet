#include "symlinkattr.hpp"
#include "lua_utils.hpp"
#include <unistd.h>
#include <cerrno>
#include <system_error>
#include <limits>

int lua_symlinkattr(lua_State *L)
{
    if (!lua_arity_is(L, 3))
    {
        return luaL_error(L, "Expected three arguments: path, owner (UID), and group (GID)");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_argerror(L, 1, "Expected a string as the first argument");
    }
    if (!lua_is_strict_integer(L, 2))
    {
        return luaL_argerror(L, 2, "Expected an integer as the second argument (owner UID)");
    }
    if (!lua_is_strict_integer(L, 3))
    {
        return luaL_argerror(L, 3, "Expected an integer as the third argument (group GID)");
    }

    const lua_Integer owner_raw = lua_tointeger(L, 2);
    const lua_Integer group_raw = lua_tointeger(L, 3);
    std::string path = luaL_checkstring_without_nul(L, 1, "path");

    if (owner_raw < 0 || group_raw < 0)
    {
        return push_fail(L, "UID and GID must be non-negative");
    }

    // Borne haute : uid_t / gid_t sont typiquement uint32_t sous Linux,
    // mais lua_Integer est int64_t. Sans ce check, une valeur > 2^32-1
    // serait silencieusement tronquée par le static_cast. Pire scénario :
    // 4294967296 → 0 (root). Faille d'élévation de privilèges si l'UID
    // vient d'une source externe.
    using uid_limits = std::numeric_limits<uid_t>;
    using gid_limits = std::numeric_limits<gid_t>;
    if (static_cast<unsigned long long>(owner_raw) > uid_limits::max() ||
        static_cast<unsigned long long>(group_raw) > gid_limits::max())
    {
        return push_fail(L, "UID or GID out of range");
    }

    uid_t owner = static_cast<uid_t>(owner_raw);
    gid_t group = static_cast<gid_t>(group_raw);

    // lchown agit sur le lien symbolique lui-même, sans le suivre
    // (chown, lui, agirait sur la cible du lien).
    if (lchown(path.c_str(), owner, group) != 0)
    {
        return push_fail(L, std::generic_category().message(errno));
    }

    return push_ok(L);
}