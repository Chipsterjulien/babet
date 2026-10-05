#pragma once

#include <filesystem>

/**
 * Keep the caller's lexical path semantics while making a terminal symlink
 * remain the final pathname component for symlink_status()/O_NOFOLLOW.
 *
 * POSIX resolves `link/` (and `link/.`) as a directory traversal, so the link
 * is no longer the final component and O_NOFOLLOW cannot protect it.  Do not
 * use lexically_normal() here: collapsing `foo/..` would change whether the
 * original path has to exist.  We only remove trailing separators and terminal
 * `.` components, which are the spellings that hide the final symlink.
 */
inline std::filesystem::path
nofollow_final_component_path(const std::filesystem::path &input)
{
    namespace fs = std::filesystem;

    if (input.empty())
        return input;

    fs::path path = input;

    auto strip_trailing_separator = [&]()
    {
        while (path.has_relative_path() && path.filename().empty())
        {
            const fs::path parent = path.parent_path();
            if (parent == path)
                break;
            path = parent;
        }
    };

    strip_trailing_separator();
    while (path.has_relative_path() && path.filename() == fs::path("."))
    {
        const fs::path parent = path.parent_path();
        // Preserve a bare "." (current directory).
        if (parent.empty() || parent == path)
            break;
        path = parent;
        strip_trailing_separator();
    }

    return path;
}
