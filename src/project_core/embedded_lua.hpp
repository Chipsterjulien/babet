#ifndef BABET_EMBEDDED_LUA_HPP
#define BABET_EMBEDDED_LUA_HPP

#include <lua.hpp>
#include <cstddef>
#include <cstring>

// File semantics for a Lua chunk read from the embedded archive. As with
// luaL_loadfile, skip an optional UTF-8 BOM and an initial '#' line. Keep
// one newline for source line numbers, but never prepend it to bytecode.
// The reader borrows its input and owns no C++ resource across lua_load.
inline int load_embedded_lua(lua_State *L, const char *data, std::size_t size,
                             const char *name)
{
    std::size_t offset = 0;
    if (size >= 3 && std::memcmp(data, "\xEF\xBB\xBF", 3) == 0)
        offset = 3;

    const bool comment = offset < size && data[offset] == '#';
    if (comment)
    {
        while (offset < size && data[offset] != '\n')
            ++offset;
        if (offset < size)
            ++offset;
    }
    const bool binary = offset < size && data[offset] == LUA_SIGNATURE[0];
    struct Reader
    {
        const char *data;
        std::size_t size;
        bool newline;
    } reader{size > offset ? data + offset : nullptr,
             size - offset, comment && !binary};

    return lua_load(L, [](lua_State *, void *context, std::size_t *length)
                    -> const char *
    {
        auto &r = *static_cast<Reader *>(context);
        if (r.newline)
        {
            r.newline = false;
            *length = 1;
            return "\n";
        }
        *length = r.size;
        r.size = 0;
        return *length != 0 ? r.data : nullptr;
    }, &reader, name, nullptr);
}

#endif // BABET_EMBEDDED_LUA_HPP
