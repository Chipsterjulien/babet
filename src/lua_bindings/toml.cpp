#define TOML_EXCEPTIONS 0
#include <toml++/toml.hpp>

#include "toml.hpp"
#include "lua_utils.hpp"

#include <cstdint>
#include <new>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace
{
constexpr int MAX_TOML_DEPTH = 1000;

enum class TomlLuaKind
{
    table,
    array,
    string,
    integer,
    number,
    boolean,
    nil,
};

struct TomlLuaValue
{
    TomlLuaKind kind = TomlLuaKind::nil;
    std::vector<std::pair<std::string, TomlLuaValue>> table;
    std::vector<TomlLuaValue> array;
    std::string text;
    std::int64_t integer = 0;
    double number = 0.0;
    bool boolean = false;
};

template <typename T>
std::string temporal_to_iso(const T &value)
{
    std::ostringstream stream;
    stream << value;
    return stream.str();
}

TomlLuaValue snapshot_toml_node(const toml::node &node, int depth)
{
    if (depth > MAX_TOML_DEPTH)
        throw std::runtime_error("toml: nesting is too deep");

    TomlLuaValue result;
    if (const auto *table = node.as_table())
    {
        result.kind = TomlLuaKind::table;
        result.table.reserve(table->size());
        for (const auto &[key, value] : *table)
            result.table.emplace_back(
                std::string(key.str()), snapshot_toml_node(value, depth + 1));
        return result;
    }
    if (const auto *array = node.as_array())
    {
        result.kind = TomlLuaKind::array;
        result.array.reserve(array->size());
        for (const auto &value : *array)
            result.array.push_back(snapshot_toml_node(value, depth + 1));
        return result;
    }
    // Do not use value<T>() itself as the type discriminator. toml++ permits
    // selected lossless conversions there (notably bool -> integer), so the
    // first successful optional can silently change the public Lua type. The
    // decoded TOML node kind is authoritative; value<T>() is only used after
    // the exact kind has been established.
    if (node.is_string())
    {
        const auto value = node.value<std::string>();
        result.kind = TomlLuaKind::string;
        result.text = value.value_or(std::string{});
        return result;
    }
    if (node.is_boolean())
    {
        const auto value = node.value<bool>();
        result.kind = TomlLuaKind::boolean;
        result.boolean = value.value_or(false);
        return result;
    }
    if (node.is_integer())
    {
        const auto value = node.value<std::int64_t>();
        result.kind = TomlLuaKind::integer;
        result.integer = value.value_or(0);
        return result;
    }
    if (node.is_floating_point())
    {
        const auto value = node.value<double>();
        result.kind = TomlLuaKind::number;
        result.number = value.value_or(0.0);
        return result;
    }
    if (node.is_date())
    {
        const auto value = node.value<toml::date>();
        result.kind = TomlLuaKind::string;
        result.text = value ? temporal_to_iso(*value) : std::string{};
        return result;
    }
    if (node.is_time())
    {
        const auto value = node.value<toml::time>();
        result.kind = TomlLuaKind::string;
        result.text = value ? temporal_to_iso(*value) : std::string{};
        return result;
    }
    if (node.is_date_time())
    {
        const auto value = node.value<toml::date_time>();
        result.kind = TomlLuaKind::string;
        result.text = value ? temporal_to_iso(*value) : std::string{};
        return result;
    }
    return result;
}

void push_toml_snapshot(lua_State *L, const TomlLuaValue &value, int depth)
{
    if (depth > MAX_TOML_DEPTH || !lua_checkstack(L, 5))
        throw std::runtime_error("toml: Lua stack exhausted during conversion");

    switch (value.kind)
    {
    case TomlLuaKind::table:
        lua_createtable(L, 0, static_cast<int>(value.table.size()));
        for (const auto &[key, child] : value.table)
        {
            lua_pushlstring(L, key.data(), key.size());
            push_toml_snapshot(L, child, depth + 1);
            lua_rawset(L, -3);
        }
        return;
    case TomlLuaKind::array:
        lua_createtable(L, static_cast<int>(value.array.size()), 0);
        for (std::size_t index = 0; index < value.array.size(); ++index)
        {
            push_toml_snapshot(L, value.array[index], depth + 1);
            lua_rawseti(L, -2, static_cast<lua_Integer>(index + 1));
        }
        return;
    case TomlLuaKind::string:
        lua_pushlstring(L, value.text.data(), value.text.size());
        return;
    case TomlLuaKind::integer:
        lua_pushinteger(L, static_cast<lua_Integer>(value.integer));
        return;
    case TomlLuaKind::number:
        lua_pushnumber(L, static_cast<lua_Number>(value.number));
        return;
    case TomlLuaKind::boolean:
        lua_pushboolean(L, value.boolean ? 1 : 0);
        return;
    case TomlLuaKind::nil:
        lua_pushnil(L);
        return;
    }
}

std::string format_parse_error(const toml::parse_error &error)
{
    const auto &source = error.source();
    std::string message = "toml: ";
    message.append(error.description());
    message += " (line ";
    message += std::to_string(source.begin.line);
    message += ", col ";
    message += std::to_string(source.begin.column);
    message += ")";
    return message;
}

int lua_toml_decode_impl(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "Expected one argument");
    if (!lua_is_strict_string(L, 1))
        return luaL_error(L, "Expected a string as argument");

    std::size_t length = 0;
    const char *data = lua_tolstring(L, 1, &length);

    try
    {
        const toml::parse_result parsed =
            toml::parse(std::string_view(data, length));
        if (!parsed)
            return push_fail_protected(L, format_parse_error(parsed.error()));

        const TomlLuaValue snapshot =
            snapshot_toml_node(parsed.table(), 0);
        auto builder = [&snapshot](lua_State *Ls) -> int
        {
            push_toml_snapshot(Ls, snapshot, 0);
            lua_pushnil(Ls);
            return 2;
        };
        return lua_build_results_protected(L, builder, 2);
    }
    catch (const std::bad_alloc &)
    {
        throw;
    }
    catch (const std::exception &error)
    {
        lua_settop(L, argc);
        std::string message = error.what();
        if (message.rfind("toml:", 0) != 0)
            message.insert(0, "toml: ");
        return push_fail_protected(L, message);
    }
}

template <int (*Fn)(lua_State *)>
int toml_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "toml: out of memory", "toml: internal C++ failure",
        "toml: unknown internal C++ failure");
}
} // namespace

int lua_toml_decode(lua_State *L)
{
    return toml_boundary<lua_toml_decode_impl>(L);
}

void register_toml(lua_State *L)
{
    lua_newtable(L);
    lua_pushcfunction(L, lua_toml_decode);
    lua_setfield(L, -2, "decode");
    lua_setfield(L, -2, "toml");
}
