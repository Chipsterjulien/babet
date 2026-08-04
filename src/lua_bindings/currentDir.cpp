#include "currentDir.hpp"
#include "lua_utils.hpp"

#include <filesystem>
#include <optional>
#include <string>

namespace fs = std::filesystem;

std::optional<std::string> currentDir()
{
    std::error_code ec;
    const auto path = fs::current_path(ec);
    if (ec)
        return std::nullopt;
    return path.string();
}

int lua_currentDir(lua_State *L)
{
    std::error_code ec;
    const auto path = fs::current_path(ec);
    if (ec)
    {
        const std::string message = ec.message();
        return push_fail_protected(L, message);
    }

    const std::string result = path.string();
    return push_string_result_protected(L, result);
}
