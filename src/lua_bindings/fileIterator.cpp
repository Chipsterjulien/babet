#include "fileIterator.hpp"
#include "lua_utils.hpp"

#include <cstddef>
#include <new>
#include <stdexcept>
#include <system_error>

namespace fs = std::filesystem;

namespace
{
constexpr const char *FILE_ITERATOR_META = "FileIterator";

struct FileIteratorUserdata
{
    bool constructed = false;
    alignas(FileIterator) std::byte storage[sizeof(FileIterator)];

    FileIterator *get() noexcept
    {
        return std::launder(reinterpret_cast<FileIterator *>(storage));
    }
};

FileIteratorUserdata *check_userdata(lua_State *L, int idx)
{
    return static_cast<FileIteratorUserdata *>(
        luaL_checkudata(L, idx, FILE_ITERATOR_META));
}

FileIterator *check_iterator(lua_State *L)
{
    FileIteratorUserdata *userdata = check_userdata(L, 1);
    if (!userdata->constructed)
        luaL_error(L, "iterator has been closed");
    return userdata->get();
}

void destroy_iterator(FileIteratorUserdata *userdata) noexcept
{
    if (userdata && userdata->constructed)
    {
        userdata->get()->~FileIterator();
        userdata->constructed = false;
    }
}

int lua_nextFile_impl(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "FileIterator.next expects only self");

    FileIterator *iterator = check_iterator(L);
    switch (iterator->next())
    {
    case FileIterator::NextState::file:
        return push_string_result_protected(L, iterator->value());
    case FileIterator::NextState::error:
        return push_fail_protected(L, iterator->error());
    case FileIterator::NextState::end:
    {
        auto builder = [](lua_State *Ls) noexcept -> int
        {
            lua_pushnil(Ls);
            lua_pushnil(Ls);
            return 2;
        };
        return lua_build_results_protected(L, builder, 2);
    }
    }
    return push_fail_protected(L, "file iterator: invalid internal state");
}

int lua_createFileIterator_impl(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
        return luaL_error(L,
                          "createFileIterator expects one or two arguments");
    if (!lua_is_strict_string(L, 1))
        return luaL_error(L, "path must be a string");
    if (!lua_is_optional_strict_boolean(L, 2))
        return luaL_error(L, "recursive must be a boolean or nil");

    const std::string_view path =
        luaL_checkstring_view_without_nul(L, 1, "path");
    const bool recursive = lua_is_strict_boolean(L, 2) &&
                           lua_toboolean(L, 2) != 0;

    auto *userdata = static_cast<FileIteratorUserdata *>(
        lua_newuserdatauv(L, sizeof(FileIteratorUserdata), 0));
    userdata->constructed = false;
    luaL_getmetatable(L, FILE_ITERATOR_META);
    lua_setmetatable(L, -2);

    try
    {
        new (userdata->storage) FileIterator(path, recursive);
        userdata->constructed = true;
    }
    catch (const std::bad_alloc &)
    {
        throw;
    }
    catch (const std::exception &e)
    {
        lua_pop(L, 1);
        return push_fail_protected(L, e.what());
    }

    lua_pushnil(L);
    return 2;
}

template <int (*Fn)(lua_State *)>
int file_iterator_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "file iterator: out of memory",
        "file iterator: internal C++ failure",
        "file iterator: unknown internal C++ failure");
}

int lua_closeFileIterator(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "FileIterator.close expects only self");
    destroy_iterator(check_userdata(L, 1));
    return 0;
}
} // namespace

FileIterator::FileIterator(std::string_view path, bool recursive)
    : recursive_(recursive)
{
    const fs::path root{std::string(path)};
    std::error_code ec;
    if (recursive_)
        recursive_it_.emplace(root, ec);
    else
        flat_.emplace(root, ec);
    if (ec)
        throw std::runtime_error("cannot access directory: " + ec.message());
}

bool FileIterator::inspect_current(const fs::directory_entry &entry,
                                   bool &yield)
{
    yield = false;
    std::error_code ec;
    const fs::file_status link_status = entry.symlink_status(ec);
    if (ec)
    {
        error_ = "cannot inspect '" + entry.path().string() + "': " +
                 ec.message();
        return false;
    }

    if (fs::is_symlink(link_status))
    {
        const fs::file_status target_status = entry.status(ec);
        if (!ec && fs::is_regular_file(target_status))
        {
            value_ = entry.path().string();
            yield = true;
        }
        return true;
    }

    if (fs::is_regular_file(link_status))
    {
        value_ = entry.path().string();
        yield = true;
    }
    return true;
}

bool FileIterator::advance()
{
    std::error_code ec;
    if (recursive_)
        recursive_it_->increment(ec);
    else
        flat_->increment(ec);
    if (ec)
    {
        error_ = "cannot continue directory iteration: " + ec.message();
        deferred_error_ = true;
        return false;
    }
    return true;
}

FileIterator::NextState FileIterator::next()
{
    value_.clear();
    if (deferred_error_)
    {
        deferred_error_ = false;
        exhausted_ = true;
        return NextState::error;
    }
    error_.clear();
    if (exhausted_)
        return NextState::end;

    const fs::directory_iterator flat_end;
    const fs::recursive_directory_iterator recursive_end;
    for (;;)
    {
        const bool at_end = recursive_
                                ? *recursive_it_ == recursive_end
                                : *flat_ == flat_end;
        if (at_end)
        {
            exhausted_ = true;
            return NextState::end;
        }

        const fs::directory_entry &entry = recursive_
                                               ? **recursive_it_
                                               : **flat_;
        bool yield = false;
        if (!inspect_current(entry, yield))
        {
            exhausted_ = true;
            return NextState::error;
        }

        const bool advanced = advance();
        if (yield)
            return NextState::file;
        if (!advanced)
        {
            deferred_error_ = false;
            exhausted_ = true;
            return NextState::error;
        }
    }
}

int lua_nextFile(lua_State *L)
{
    return file_iterator_boundary<lua_nextFile_impl>(L);
}

int lua_gcFileIterator(lua_State *L)
{
    auto *userdata = static_cast<FileIteratorUserdata *>(
        luaL_testudata(L, 1, FILE_ITERATOR_META));
    destroy_iterator(userdata);
    return 0;
}

int lua_gcFileIterator_boundary(lua_State *L) noexcept
{
    try
    {
        return lua_gcFileIterator(L);
    }
    catch (...)
    {
        return 0;
    }
}

int lua_closeFileIterator_boundary(lua_State *L)
{
    return file_iterator_boundary<lua_closeFileIterator>(L);
}

int lua_createFileIterator(lua_State *L)
{
    return file_iterator_boundary<lua_createFileIterator_impl>(L);
}

int file_iterator_create_meta(lua_State *L)
{
    luaL_newmetatable(L, FILE_ITERATOR_META);

    lua_newtable(L);
    lua_pushcfunction(L, lua_nextFile);
    lua_setfield(L, -2, "next");
    lua_pushcfunction(L, lua_closeFileIterator_boundary);
    lua_setfield(L, -2, "close");
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, lua_gcFileIterator_boundary);
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, lua_closeFileIterator_boundary);
    lua_setfield(L, -2, "__close");
    return 1;
}

extern "C" int luaopen_file_iterator(lua_State *L)
{
    file_iterator_create_meta(L);
    luaL_Reg file_iterator_functions[] = {
        {"createFileIterator", lua_createFileIterator},
        {nullptr, nullptr}};
    luaL_newlib(L, file_iterator_functions);
    return 1;
}
