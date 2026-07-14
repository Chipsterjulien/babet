#include "executable_path.hpp"

#include <cerrno>
#include <cstring>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>

std::string getExecutablePath()
{
    std::vector<char> buffer(256);

    for (;;)
    {
        const ssize_t count =
            ::readlink("/proc/self/exe", buffer.data(), buffer.size());
        if (count < 0)
        {
            throw std::runtime_error(
                std::string("Cannot read executable path: ") +
                std::strerror(errno));
        }

        const std::size_t length = static_cast<std::size_t>(count);
        if (length < buffer.size())
        {
            return std::string(buffer.data(), length);
        }

        // readlink() does not report the required length. A full buffer means
        // possible truncation, so retry with a larger one.
        if (buffer.size() > (1U << 20))
        {
            throw std::runtime_error("Executable path is unexpectedly long");
        }
        buffer.resize(buffer.size() * 2);
    }
}

std::string getExecutableDirectory()
{
    const std::string executable_path = getExecutablePath();
    const std::size_t last_slash = executable_path.find_last_of('/');
    if (last_slash == std::string::npos)
    {
        return ".";
    }
    if (last_slash == 0)
    {
        return "/";
    }
    return executable_path.substr(0, last_slash);
}
