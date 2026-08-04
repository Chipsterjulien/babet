#include "base64.hpp"
#include "lua_utils.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <stdexcept>
#include <string>
#include <string_view>

namespace
{
constexpr char STANDARD_ALPHABET[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
constexpr char URL_SAFE_ALPHABET[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

struct EncodeOptions
{
    bool url_safe = false;
    bool padding = true;
};

struct DecodeOptions
{
    bool url_safe = false;
    bool allow_unpadded = false;
    bool ignore_whitespace = false;
    bool has_max_output = false;
    std::uint64_t max_output = 0;
};

bool key_equals(const char *data, std::size_t len,
                std::string_view expected) noexcept
{
    return len == expected.size() &&
           std::string_view(data, len) == expected;
}

int unknown_option_error(lua_State *L, const char *function_name,
                         int key_index)
{
    key_index = lua_absindex(L, key_index);
    lua_pushfstring(L, "%s: unknown option '", function_name);
    lua_pushvalue(L, key_index);
    lua_pushliteral(L, "'");
    lua_concat(L, 3);
    return lua_error(L);
}

void validate_option_keys(lua_State *L, int opts_index,
                          const char *function_name, bool for_decode)
{
    opts_index = lua_absindex(L, opts_index);
    lua_pushnil(L);
    while (lua_next(L, opts_index) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 1);
            luaL_error(L, "%s: option keys must be strings", function_name);
            return;
        }

        std::size_t key_len = 0;
        const char *key = lua_tolstring(L, -2, &key_len);
        const bool common = key_equals(key, key_len, "url_safe");
        const bool allowed = for_decode
                                 ? common ||
                                       key_equals(key, key_len,
                                                  "allow_unpadded") ||
                                       key_equals(key, key_len,
                                                  "ignore_whitespace") ||
                                       key_equals(key, key_len, "max_output")
                                 : common || key_equals(key, key_len, "padding");
        if (!allowed)
        {
            lua_pop(L, 1); // value; keep key for the error message
            unknown_option_error(L, function_name, -1);
            return;
        }
        lua_pop(L, 1);
    }
}

bool read_boolean_option(lua_State *L, int opts_index, const char *name,
                         bool default_value, const char *function_name)
{
    lua_getfield(L, opts_index, name);
    if (lua_isnil(L, -1))
    {
        lua_pop(L, 1);
        return default_value;
    }
    if (!lua_is_strict_boolean(L, -1))
    {
        lua_pop(L, 1);
        luaL_error(L, "%s: opts.%s must be a boolean", function_name, name);
        return default_value;
    }
    const bool value = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    return value;
}

EncodeOptions parse_encode_options(lua_State *L)
{
    EncodeOptions options;
    if (lua_gettop(L) == 1 || lua_isnil(L, 2))
    {
        return options;
    }
    if (!lua_istable(L, 2))
    {
        luaL_typeerror(L, 2, "table");
        return options;
    }

    validate_option_keys(L, 2, "babet.base64.encode", false);
    options.url_safe = read_boolean_option(
        L, 2, "url_safe", false, "babet.base64.encode");
    options.padding = read_boolean_option(
        L, 2, "padding", true, "babet.base64.encode");
    return options;
}

DecodeOptions parse_decode_options(lua_State *L)
{
    DecodeOptions options;
    if (lua_gettop(L) == 1 || lua_isnil(L, 2))
    {
        return options;
    }
    if (!lua_istable(L, 2))
    {
        luaL_typeerror(L, 2, "table");
        return options;
    }

    validate_option_keys(L, 2, "babet.base64.decode", true);
    options.url_safe = read_boolean_option(
        L, 2, "url_safe", false, "babet.base64.decode");
    options.allow_unpadded = read_boolean_option(
        L, 2, "allow_unpadded", false, "babet.base64.decode");
    options.ignore_whitespace = read_boolean_option(
        L, 2, "ignore_whitespace", false, "babet.base64.decode");

    lua_getfield(L, 2, "max_output");
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_integer(L, -1))
        {
            lua_pop(L, 1);
            luaL_error(L,
                       "babet.base64.decode: opts.max_output must be an integer");
            return options;
        }
        const lua_Integer value = lua_tointeger(L, -1);
        if (value < 0)
        {
            lua_pop(L, 1);
            luaL_error(
                L,
                "babet.base64.decode: opts.max_output must be non-negative");
            return options;
        }
        options.has_max_output = true;
        options.max_output = static_cast<std::uint64_t>(value);
    }
    lua_pop(L, 1);
    return options;
}

bool encode_base64(std::string_view input, const EncodeOptions &options,
                   std::string &output, std::string &error)
{
    const std::size_t full_groups = input.size() / 3;
    const std::size_t remainder = input.size() % 3;
    if (full_groups > std::numeric_limits<std::size_t>::max() / 4)
    {
        error = "base64: input too large";
        return false;
    }

    std::size_t output_size = full_groups * 4;
    if (remainder != 0)
    {
        const std::size_t tail_size = options.padding ? 4 : remainder + 1;
        if (output_size > std::numeric_limits<std::size_t>::max() - tail_size)
        {
            error = "base64: input too large";
            return false;
        }
        output_size += tail_size;
    }

    const char *alphabet =
        options.url_safe ? URL_SAFE_ALPHABET : STANDARD_ALPHABET;
    output.clear();
    output.reserve(output_size);
    const auto *bytes = reinterpret_cast<const unsigned char *>(input.data());

    std::size_t index = 0;
    while (input.size() - index >= 3)
    {
        const unsigned int value =
            (static_cast<unsigned int>(bytes[index]) << 16) |
            (static_cast<unsigned int>(bytes[index + 1]) << 8) |
            static_cast<unsigned int>(bytes[index + 2]);
        output.push_back(alphabet[(value >> 18) & 0x3f]);
        output.push_back(alphabet[(value >> 12) & 0x3f]);
        output.push_back(alphabet[(value >> 6) & 0x3f]);
        output.push_back(alphabet[value & 0x3f]);
        index += 3;
    }

    if (remainder == 1)
    {
        const unsigned int value =
            static_cast<unsigned int>(bytes[index]) << 16;
        output.push_back(alphabet[(value >> 18) & 0x3f]);
        output.push_back(alphabet[(value >> 12) & 0x3f]);
        if (options.padding)
        {
            output.push_back('=');
            output.push_back('=');
        }
    }
    else if (remainder == 2)
    {
        const unsigned int value =
            (static_cast<unsigned int>(bytes[index]) << 16) |
            (static_cast<unsigned int>(bytes[index + 1]) << 8);
        output.push_back(alphabet[(value >> 18) & 0x3f]);
        output.push_back(alphabet[(value >> 12) & 0x3f]);
        output.push_back(alphabet[(value >> 6) & 0x3f]);
        if (options.padding)
        {
            output.push_back('=');
        }
    }

    return output.size() == output_size;
}

bool is_ascii_whitespace(unsigned char value) noexcept
{
    switch (value)
    {
    case ' ':
    case '\t':
    case '\n':
    case '\v':
    case '\f':
    case '\r':
        return true;
    default:
        return false;
    }
}

int decode_value(unsigned char value, bool url_safe) noexcept
{
    if (value >= 'A' && value <= 'Z')
    {
        return value - 'A';
    }
    if (value >= 'a' && value <= 'z')
    {
        return value - 'a' + 26;
    }
    if (value >= '0' && value <= '9')
    {
        return value - '0' + 52;
    }
    if (!url_safe && value == '+')
    {
        return 62;
    }
    if (!url_safe && value == '/')
    {
        return 63;
    }
    if (url_safe && value == '-')
    {
        return 62;
    }
    if (url_safe && value == '_')
    {
        return 63;
    }
    return -1;
}

std::string byte_error(std::string_view reason, std::size_t position)
{
    std::string error = "base64: ";
    error.append(reason);
    error += " at byte ";
    error += std::to_string(position);
    return error;
}

struct InputShape
{
    std::size_t data_count = 0;
    std::size_t decoded_size = 0;
};

bool analyze_input(std::string_view input, const DecodeOptions &options,
                   InputShape &shape, std::string &error)
{
    std::size_t symbol_count = 0;
    std::size_t padding_count = 0;
    std::size_t first_padding_position = 0;
    bool padding_seen = false;
    std::array<int, 4> tail_values{};
    std::array<std::size_t, 4> tail_positions{};
    std::size_t tail_count = 0;

    for (std::size_t i = 0; i < input.size(); ++i)
    {
        const unsigned char value =
            static_cast<unsigned char>(input[i]);
        if (is_ascii_whitespace(value))
        {
            if (options.ignore_whitespace)
            {
                continue;
            }
            error = byte_error("invalid character", i + 1);
            return false;
        }

        ++symbol_count;
        if (value == '=')
        {
            if (!padding_seen)
            {
                first_padding_position = i + 1;
                padding_seen = true;
            }
            ++padding_count;
            continue;
        }

        const int decoded_value = decode_value(value, options.url_safe);
        if (decoded_value < 0)
        {
            error = byte_error("invalid character", i + 1);
            return false;
        }
        if (padding_seen)
        {
            error = byte_error("invalid padding", i + 1);
            return false;
        }

        tail_values[tail_count] = decoded_value;
        tail_positions[tail_count] = i + 1;
        ++tail_count;
        if (tail_count == 4)
        {
            tail_count = 0;
        }
        ++shape.data_count;
    }

    if (padding_seen)
    {
        if (symbol_count % 4 != 0 || padding_count > 2 ||
            (padding_count == 1 && shape.data_count % 4 != 3) ||
            (padding_count == 2 && shape.data_count % 4 != 2))
        {
            error = byte_error("invalid padding", first_padding_position);
            return false;
        }
        shape.decoded_size = (symbol_count / 4) * 3 - padding_count;
    }
    else
    {
        const std::size_t remainder = shape.data_count % 4;
        if (remainder == 1)
        {
            error = "base64: truncated input";
            return false;
        }
        if ((remainder == 2 || remainder == 3) &&
            !options.allow_unpadded)
        {
            error = "base64: truncated input";
            return false;
        }

        shape.decoded_size = (shape.data_count / 4) * 3;
        if (remainder == 2)
        {
            ++shape.decoded_size;
        }
        else if (remainder == 3)
        {
            shape.decoded_size += 2;
        }
    }

    if (tail_count == 2 && (tail_values[1] & 0x0f) != 0)
    {
        error = byte_error("non-zero trailing bits", tail_positions[1]);
        return false;
    }
    if (tail_count == 3 && (tail_values[2] & 0x03) != 0)
    {
        error = byte_error("non-zero trailing bits", tail_positions[2]);
        return false;
    }

    if (options.has_max_output &&
        shape.decoded_size > options.max_output)
    {
        error = "base64: decoded output exceeds max_output";
        return false;
    }
    return true;
}

bool decode_input(std::string_view input, const DecodeOptions &options,
                  const InputShape &shape, std::string &output,
                  std::string &error)
{
    output.clear();
    output.reserve(shape.decoded_size);

    std::array<int, 4> values{};
    std::array<std::size_t, 4> positions{};
    std::size_t count = 0;

    for (std::size_t i = 0; i < input.size(); ++i)
    {
        const unsigned char value =
            static_cast<unsigned char>(input[i]);
        if (is_ascii_whitespace(value) && options.ignore_whitespace)
        {
            continue;
        }
        if (value == '=')
        {
            break;
        }

        values[count] = decode_value(value, options.url_safe);
        positions[count] = i + 1;
        ++count;

        if (count == 4)
        {
            output.push_back(
                static_cast<char>((values[0] << 2) | (values[1] >> 4)));
            output.push_back(static_cast<char>(
                ((values[1] & 0x0f) << 4) | (values[2] >> 2)));
            output.push_back(static_cast<char>(
                ((values[2] & 0x03) << 6) | values[3]));
            count = 0;
        }
    }

    if (count == 2)
    {
        if ((values[1] & 0x0f) != 0)
        {
            error = byte_error("non-zero trailing bits", positions[1]);
            return false;
        }
        output.push_back(
            static_cast<char>((values[0] << 2) | (values[1] >> 4)));
    }
    else if (count == 3)
    {
        if ((values[2] & 0x03) != 0)
        {
            error = byte_error("non-zero trailing bits", positions[2]);
            return false;
        }
        output.push_back(
            static_cast<char>((values[0] << 2) | (values[1] >> 4)));
        output.push_back(static_cast<char>(
            ((values[1] & 0x0f) << 4) | (values[2] >> 2)));
    }

    if (output.size() != shape.decoded_size)
    {
        error = "base64: internal decoded-size mismatch";
        return false;
    }
    return true;
}

} // namespace

int lua_base64_encode_impl(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(
            L, "babet.base64.encode expects one or two arguments");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_typeerror(L, 1, "string");
    }

    const EncodeOptions options = parse_encode_options(L);
    std::size_t input_size = 0;
    const char *input = lua_tolstring(L, 1, &input_size);

    try
    {
        std::string output;
        std::string error;
        if (!encode_base64(std::string_view(input, input_size), options,
                           output, error))
        {
            if (error.empty())
            {
                error = "base64: internal encoded-size mismatch";
            }
            return push_fail_protected(L, error);
        }

        return push_string_result_protected(L, output);
    }
    catch (const std::length_error &)
    {
        return push_fail_protected(L, "base64: encoded output too large");
    }
    catch (const std::bad_alloc &)
    {
        throw;
    }
    catch (...)
    {
        return push_fail_protected(L, "base64: unexpected internal error");
    }
}

int lua_base64_decode_impl(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(
            L, "babet.base64.decode expects one or two arguments");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_typeerror(L, 1, "string");
    }

    const DecodeOptions options = parse_decode_options(L);
    std::size_t input_size = 0;
    const char *input = lua_tolstring(L, 1, &input_size);

    try
    {
        const std::string_view text(input, input_size);
        InputShape shape;
        std::string error;
        if (!analyze_input(text, options, shape, error))
        {
            return push_fail_protected(L, error);
        }

        std::string output;
        if (!decode_input(text, options, shape, output, error))
        {
            return push_fail_protected(L, error);
        }

        return push_string_result_protected(L, output);
    }
    catch (const std::length_error &)
    {
        return push_fail_protected(L, "base64: decoded output too large");
    }
    catch (const std::bad_alloc &)
    {
        throw;
    }
    catch (...)
    {
        return push_fail_protected(L, "base64: unexpected internal error");
    }
}

template <int (*Fn)(lua_State *)>
int base64_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "base64: out of memory", "base64: internal failure",
        "base64: unknown internal failure");
}

int lua_base64_encode(lua_State *L)
{
    return base64_boundary<lua_base64_encode_impl>(L);
}

int lua_base64_decode(lua_State *L)
{
    return base64_boundary<lua_base64_decode_impl>(L);
}

void register_base64(lua_State *L)
{
    lua_newtable(L);

    lua_pushcfunction(L, lua_base64_encode);
    lua_setfield(L, -2, "encode");

    lua_pushcfunction(L, lua_base64_decode);
    lua_setfield(L, -2, "decode");

    lua_setfield(L, -2, "base64");
}
