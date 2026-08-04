#ifndef FILEITERATOR_HPP
#define FILEITERATOR_HPP

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

#include <lua.hpp>

/** Lazy iterator over regular files in a directory. */
class FileIterator
{
public:
    enum class NextState
    {
        file,
        end,
        error,
    };

    FileIterator(std::string_view path, bool recursive);
    FileIterator(const FileIterator &) = delete;
    FileIterator &operator=(const FileIterator &) = delete;
    FileIterator(FileIterator &&) = delete;
    FileIterator &operator=(FileIterator &&) = delete;
    ~FileIterator() = default;

    NextState next();
    const std::string &value() const noexcept { return value_; }
    const std::string &error() const noexcept { return error_; }

private:
    bool inspect_current(const std::filesystem::directory_entry &entry,
                         bool &yield);
    bool advance();

    bool recursive_ = false;
    std::optional<std::filesystem::directory_iterator> flat_;
    std::optional<std::filesystem::recursive_directory_iterator> recursive_it_;
    std::string value_;
    std::string error_;
    bool exhausted_ = false;
    bool deferred_error_ = false;
};

int lua_nextFile(lua_State *L);
int lua_gcFileIterator(lua_State *L);
int lua_createFileIterator(lua_State *L);
int file_iterator_create_meta(lua_State *L);
extern "C" int luaopen_file_iterator(lua_State *L);

#endif // FILEITERATOR_HPP
