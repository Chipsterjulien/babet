#include "fileIterator.hpp"
#include "lua_utils.hpp"
#include <stdexcept>
#include <memory>

namespace fs = std::filesystem;

FileIterator::FileIterator(const std::string &path, bool recursive)
{
    loadFiles(path, recursive);
    current = files.begin();
}

void FileIterator::loadFiles(const fs::path &path, bool recursive)
{
    auto fail = [](const fs::path &entry, const std::error_code &ec)
    {
        throw std::runtime_error(
            "cannot inspect '" + entry.string() + "': " + ec.message());
    };

    auto add_if_regular = [&](const fs::directory_entry &entry)
    {
        // Inspect the directory entry itself first. A dangling symbolic link is
        // a valid directory entry and must not make an iterator over regular
        // files fail. Genuine lstat/symlink_status errors are still reported.
        std::error_code link_ec;
        const fs::file_status link_status = entry.symlink_status(link_ec);
        if (link_ec)
        {
            fail(entry.path(), link_ec);
        }

        if (fs::is_symlink(link_status))
        {
            // Preserve the historical behaviour for a valid symlink to a
            // regular file by returning the link path. If its target cannot be
            // resolved (dangling link, loop, inaccessible target), simply skip
            // it: the link itself was inspected successfully and is not a
            // regular file entry we can yield safely.
            std::error_code target_ec;
            const fs::file_status target_status = entry.status(target_ec);
            if (!target_ec && fs::is_regular_file(target_status))
            {
                files.emplace_back(entry.path().string());
            }
            return;
        }

        if (fs::is_regular_file(link_status))
        {
            files.emplace_back(entry.path().string());
        }
    };

    if (recursive)
    {
        std::error_code ec;
        fs::recursive_directory_iterator it(path, ec);
        const fs::recursive_directory_iterator end;
        if (ec)
        {
            throw std::runtime_error("cannot access directory: " +
                                     ec.message());
        }

        while (it != end)
        {
            add_if_regular(*it);

            std::error_code increment_ec;
            it.increment(increment_ec);
            if (increment_ec)
            {
                throw std::runtime_error(
                    "cannot continue directory iteration: " +
                    increment_ec.message());
            }
        }
        return;
    }

    std::error_code ec;
    fs::directory_iterator it(path, ec);
    const fs::directory_iterator end;
    if (ec)
    {
        throw std::runtime_error("cannot access directory: " + ec.message());
    }

    while (it != end)
    {
        add_if_regular(*it);

        std::error_code increment_ec;
        it.increment(increment_ec);
        if (increment_ec)
        {
            throw std::runtime_error(
                "cannot continue directory iteration: " +
                increment_ec.message());
        }
    }
}

std::optional<std::string> FileIterator::next()
{
    if (current != files.end())
    {
        return *(current++);
    }
    return std::nullopt;
}

bool FileIterator::hasNext() const
{
    return current != files.end();
}

static std::shared_ptr<FileIterator> *check_iterator(lua_State *L)
{
    return static_cast<std::shared_ptr<FileIterator> *>(
        luaL_checkudata(L, 1, "FileIterator"));
}

int lua_nextFile(lua_State *L)
{
    auto *iter = check_iterator(L);
    if (!*iter)
    {
        return luaL_error(L, "iterator has been closed");
    }
    if (auto nextFile = (*iter)->next())
    {
        lua_pushstring(L, nextFile->c_str());
    }
    else
    {
        lua_pushnil(L);
    }
    return 1;
}

static int lua_closeFileIterator(lua_State *L)
{
    auto *iter = check_iterator(L);
    iter->reset();
    return 0;
}

int lua_gcFileIterator(lua_State *L)
{
    auto *iter = check_iterator(L);
    iter->~shared_ptr();
    return 0;
}

int lua_createFileIterator(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L,
                          "createFileIterator expects one or two arguments");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "path must be a string");
    }
    if (!lua_is_optional_strict_boolean(L, 2))
    {
        return luaL_error(L, "recursive must be a boolean or nil");
    }

    std::string path = luaL_checkstring_without_nul(L, 1, "path");
    const bool recursive = lua_is_strict_boolean(L, 2) &&
                           lua_toboolean(L, 2);

    // Construire l'objet d'abord : si ça throw, la pile Lua n'a pas été touchée.
    std::shared_ptr<FileIterator> iter;
    try
    {
        iter = std::make_shared<FileIterator>(path, recursive);
    }
    catch (const std::exception &e)
    {
        return push_fail(L, e.what());
    }

    void *userdata = lua_newuserdata(L, sizeof(std::shared_ptr<FileIterator>));
    new (userdata) std::shared_ptr<FileIterator>(std::move(iter));

    luaL_getmetatable(L, "FileIterator");
    lua_setmetatable(L, -2);

    lua_pushnil(L); // pas d'erreur
    return 2;
}

int file_iterator_create_meta(lua_State *L)
{
    luaL_newmetatable(L, "FileIterator");

    lua_newtable(L);
    lua_pushcfunction(L, lua_nextFile);
    lua_setfield(L, -2, "next");
    lua_pushcfunction(L, lua_closeFileIterator);
    lua_setfield(L, -2, "close");
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, lua_gcFileIterator);
    lua_setfield(L, -2, "__gc");
    return 1;
}

extern "C" int luaopen_file_iterator(lua_State *L)
{
    file_iterator_create_meta(L);

    luaL_Reg file_iterator_functions[] = {
        {"createFileIterator", lua_createFileIterator},
        {NULL, NULL}};

    luaL_newlib(L, file_iterator_functions);
    return 1;
}