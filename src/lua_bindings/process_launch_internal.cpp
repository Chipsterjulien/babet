#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "process_launch_internal.hpp"

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <memory>
#include <unordered_set>

#include <fcntl.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

namespace babet_process::detail
{
namespace
{

std::string join_path(const std::string &base, const std::string &leaf)
{
    if (base.empty())
    {
        return leaf;
    }
    if (base.back() == '/')
    {
        return base + leaf;
    }
    return base + "/" + leaf;
}

bool current_directory(std::string &out, int &error_number)
{
    errno = 0;
    std::unique_ptr<char, decltype(&std::free)> cwd(::getcwd(nullptr, 0),
                                                    &std::free);
    if (!cwd)
    {
        error_number = errno != 0 ? errno : EIO;
        return false;
    }
    out.assign(cwd.get());
    return true;
}

bool effective_working_directory(const std::string &cwd, bool has_cwd,
                                 std::string &out, int &error_number)
{
    if (has_cwd && !cwd.empty() && cwd.front() == '/')
    {
        out = cwd;
        return true;
    }

    std::string parent;
    if (!current_directory(parent, error_number))
    {
        return false;
    }
    out = has_cwd ? join_path(parent, cwd) : std::move(parent);
    return true;
}

void build_environment(
    const std::vector<std::pair<std::string, std::string>> &overrides,
    std::vector<std::string> &strings,
    std::vector<char *> &envp)
{
    std::unordered_set<std::string> override_keys;
    override_keys.reserve(overrides.size());
    for (const auto &kv : overrides)
    {
        override_keys.insert(kv.first);
    }

    if (environ != nullptr)
    {
        for (char **entry = environ; *entry != nullptr; ++entry)
        {
            std::string value(*entry);
            const auto equals = value.find('=');
            if (equals != std::string::npos &&
                override_keys.count(value.substr(0, equals)) > 0)
            {
                continue;
            }
            strings.push_back(std::move(value));
        }
    }

    for (const auto &kv : overrides)
    {
        strings.push_back(kv.first + "=" + kv.second);
    }

    envp.reserve(strings.size() + 1);
    for (std::string &entry : strings)
    {
        envp.push_back(entry.data());
    }
    envp.push_back(nullptr);
}

bool environment_value(const std::vector<std::string> &environment,
                       const char *name, std::string &value)
{
    const std::string prefix = std::string(name) + "=";
    for (const std::string &entry : environment)
    {
        if (entry.starts_with(prefix))
        {
            value.assign(entry.data() + prefix.size(),
                         entry.size() - prefix.size());
            return true;
        }
    }
    return false;
}

std::string default_search_path()
{
#ifdef _CS_PATH
    const size_t required = ::confstr(_CS_PATH, nullptr, 0);
    if (required > 1)
    {
        std::string path(required, '\0');
        if (::confstr(_CS_PATH, path.data(), required) == required)
        {
            path.resize(required - 1);
            return path;
        }
    }
#endif
    return "/bin:/usr/bin";
}

bool prepare_executable_paths(const std::string &command,
                              const std::vector<std::string> &environment,
                              const std::string &cwd, bool has_cwd,
                              std::vector<std::string> &paths,
                              int &error_number)
{
    if (!command.empty() && command.front() == '/')
    {
        paths.push_back(command);
        return true;
    }

    std::string effective_cwd;
    bool effective_cwd_ready = false;
    auto ensure_effective_cwd = [&]() -> bool {
        if (effective_cwd_ready)
        {
            return true;
        }
        if (!effective_working_directory(cwd, has_cwd, effective_cwd,
                                         error_number))
        {
            return false;
        }
        effective_cwd_ready = true;
        return true;
    };

    if (command.find('/') != std::string::npos)
    {
        if (!ensure_effective_cwd())
        {
            return false;
        }
        paths.push_back(join_path(effective_cwd, command));
        return true;
    }

    std::string search_path;
    if (!environment_value(environment, "PATH", search_path))
    {
        search_path = default_search_path();
    }

    size_t start = 0;
    for (;;)
    {
        const size_t separator = search_path.find(':', start);
        const std::string component =
            separator == std::string::npos
                ? search_path.substr(start)
                : search_path.substr(start, separator - start);

        std::string directory;
        if (!component.empty() && component.front() == '/')
        {
            directory = component;
        }
        else
        {
            if (!ensure_effective_cwd())
            {
                return false;
            }
            directory = component.empty()
                            ? effective_cwd
                            : join_path(effective_cwd, component);
        }

        paths.push_back(join_path(directory, command));
        if (separator == std::string::npos)
        {
            break;
        }
        start = separator + 1;
    }
    return true;
}

unsigned int test_delay_ms(const char *name) noexcept
{
    const char *text = std::getenv(name);
    if (!text || !*text)
    {
        return 0;
    }
    char *end = nullptr;
    errno = 0;
    const unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno != 0 || !end || *end != '\0')
    {
        return 0;
    }
    return static_cast<unsigned int>(std::min<unsigned long>(parsed, 5000UL));
}

bool claim_test_marker(const char *name) noexcept
{
    const char *path = std::getenv(name);
    if (!path || !*path)
    {
        return true;
    }
    const int fd = ::open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0)
    {
        return false;
    }
    static constexpr char marker[] = "ready\n";
    const ssize_t ignored = ::write(fd, marker, sizeof(marker) - 1);
    (void)ignored;
    ::close(fd);
    return true;
}

void sleep_ms(unsigned int delay_ms) noexcept
{
    if (delay_ms == 0)
    {
        return;
    }
    struct timespec delay{};
    delay.tv_sec = static_cast<time_t>(delay_ms / 1000U);
    delay.tv_nsec = static_cast<long>((delay_ms % 1000U) * 1000000U);
    while (::nanosleep(&delay, &delay) != 0 && errno == EINTR)
    {
    }
}

} // namespace

void PreparedCommand::reset() noexcept
{
    // Drop the non-owning pointer arrays before invalidating their owners.
    argv.clear();
    envp.clear();
    executable_paths.clear();
    argv_strings.clear();
    env_strings.clear();
}

bool prepare_command(
    const std::string &command,
    const std::vector<std::string> &argv_strings,
    const std::string &cwd,
    bool has_cwd,
    const std::vector<std::pair<std::string, std::string>> &env_overrides,
    PreparedCommand &prepared,
    int &error_number)
{
    prepared.reset();
    error_number = 0;

    prepared.argv_strings = argv_strings;
    prepared.argv.reserve(prepared.argv_strings.size() + 1);
    for (std::string &argument : prepared.argv_strings)
    {
        prepared.argv.push_back(argument.data());
    }
    prepared.argv.push_back(nullptr);

    build_environment(env_overrides, prepared.env_strings, prepared.envp);

    return prepare_executable_paths(command, prepared.env_strings, cwd,
                                    has_cwd, prepared.executable_paths,
                                    error_number);
}

int exec_prepared_command(const PreparedCommand &prepared) noexcept
{
    // A worker blocks Babet's managed signals in its own thread. That mask
    // survives fork and exec, but must not make the external program ignore
    // SIGTERM/SIGINT/SIGPIPE. Every Babet-launched command starts unblocked.
    // sigprocmask is async-signal-safe; this path does not allocate after fork.
    sigset_t empty_mask;
    ::sigemptyset(&empty_mask);
    if (::sigprocmask(SIG_SETMASK, &empty_mask, nullptr) != 0)
    {
        return errno;
    }

    bool saw_eacces = false;
    for (const std::string &path : prepared.executable_paths)
    {
        ::execve(path.c_str(), prepared.argv.data(), prepared.envp.data());
        switch (errno)
        {
        case EACCES:
            saw_eacces = true;
            break;
        case ENOENT:
        case ENOTDIR:
            break;
        default:
            // glibc also retries ESTALE, ENODEV and ETIMEDOUT while walking
            // PATH. Babet deliberately reports those transient filesystem
            // errors immediately so launch failures remain deterministic.
            return errno;
        }
    }
    return saw_eacces ? EACCES : ENOENT;
}

void delay_before_fork_for_test() noexcept
{
    const unsigned int delay = test_delay_ms("BABET_TEST_PRE_FORK_DELAY_MS");
    if (delay == 0 ||
        !claim_test_marker("BABET_TEST_PRE_FORK_DELAY_MARKER"))
    {
        return;
    }
    sleep_ms(delay);
}

} // namespace babet_process::detail
