#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "process_common.hpp"
#include "lua_utils.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <csignal>
#include <cstring>
#include <ctime>
#include <unordered_set>

#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace babet_process
{
namespace
{

int move_fd_above_standard_streams(int &fd)
{
    if (fd > STDERR_FILENO)
    {
        return 0;
    }
#ifdef F_DUPFD_CLOEXEC
    const int replacement = ::fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
#else
    const int replacement = ::fcntl(fd, F_DUPFD, STDERR_FILENO + 1);
#endif
    if (replacement < 0)
    {
        return -1;
    }
#ifndef F_DUPFD_CLOEXEC
    const int flags = ::fcntl(replacement, F_GETFD);
    if (flags < 0 ||
        ::fcntl(replacement, F_SETFD, flags | FD_CLOEXEC) < 0)
    {
        const int saved = errno;
        ::close(replacement);
        errno = saved;
        return -1;
    }
#endif
    ::close(fd);
    fd = replacement;
    return 0;
}

int make_pipe(int p[2])
{
#ifdef O_CLOEXEC
    if (::pipe2(p, O_CLOEXEC) != 0)
    {
        return -1;
    }
#else
    if (::pipe(p) != 0)
    {
        return -1;
    }
    const int flags0 = ::fcntl(p[0], F_GETFD);
    const int flags1 = ::fcntl(p[1], F_GETFD);
    if (flags0 < 0 || flags1 < 0 ||
        ::fcntl(p[0], F_SETFD, flags0 | FD_CLOEXEC) < 0 ||
        ::fcntl(p[1], F_SETFD, flags1 | FD_CLOEXEC) < 0)
    {
        const int saved = errno;
        ::close(p[0]);
        ::close(p[1]);
        errno = saved;
        return -1;
    }
#endif

    if (move_fd_above_standard_streams(p[0]) != 0 ||
        move_fd_above_standard_streams(p[1]) != 0)
    {
        const int saved = errno;
        ::close(p[0]);
        ::close(p[1]);
        p[0] = -1;
        p[1] = -1;
        errno = saved;
        return -1;
    }
    return 0;
}

void close_pair(int p[2])
{
    if (p[0] >= 0)
    {
        ::close(p[0]);
        p[0] = -1;
    }
    if (p[1] >= 0)
    {
        ::close(p[1]);
        p[1] = -1;
    }
}

std::string prefixed(const char *prefix, const std::string &message)
{
    std::string result;
    if (prefix && *prefix)
    {
        result += prefix;
        result += ": ";
    }
    result += message;
    return result;
}


[[noreturn]] void report_launch_failure_and_exit(int fd,
                                                  int error_number) noexcept
{
    const auto *data = reinterpret_cast<const unsigned char *>(&error_number);
    size_t offset = 0;
    while (offset < sizeof(error_number))
    {
        const ssize_t written =
            ::write(fd, data + offset, sizeof(error_number) - offset);
        if (written > 0)
        {
            offset += static_cast<size_t>(written);
            continue;
        }
        if (written < 0 && errno == EINTR)
        {
            continue;
        }
        break;
    }
    _exit(127);
}

void build_environment(
    const std::vector<std::pair<std::string, std::string>> &overrides,
    std::vector<std::string> &strings,
    std::vector<char *> &envp)
{
    std::unordered_set<std::string> override_keys;
    for (const auto &kv : overrides)
    {
        override_keys.insert(kv.first);
    }

    if (environ != nullptr)
    {
        for (char **e = environ; *e != nullptr; ++e)
        {
            std::string entry(*e);
            const auto eq = entry.find('=');
            if (eq != std::string::npos &&
                override_keys.count(entry.substr(0, eq)) > 0)
            {
                continue;
            }
            strings.push_back(std::move(entry));
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

} // namespace

bool collect_args(lua_State *L, int idx, const std::string &cmd,
                  std::vector<std::string> &out, std::string &err)
{
    out.clear();
    out.push_back(cmd);

    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = "args must be a table";
        return false;
    }

    const int table_idx = lua_absindex(L, idx);
    const size_t raw_n = lua_rawlen(L, table_idx);
    if (raw_n > static_cast<size_t>(LUA_MAXINTEGER))
    {
        err = "args array is too large";
        return false;
    }
    const lua_Integer n = static_cast<lua_Integer>(raw_n);

    // Refuse les trous et les clés hors séquence. Cela empêche qu'une table
    // telle que {[2] = "x"} soit silencieusement interprétée différemment
    // selon la définition de l'opérateur longueur de Lua.
    lua_Integer seen = 0;
    lua_pushnil(L);
    while (lua_next(L, table_idx) != 0)
    {
        if (!lua_is_strict_integer(L, -2))
        {
            lua_pop(L, 2);
            err = "args must be a dense array of strings";
            return false;
        }
        const lua_Integer key = lua_tointeger(L, -2);
        if (key < 1 || key > n)
        {
            lua_pop(L, 2);
            err = "args must be a dense array of strings";
            return false;
        }
        ++seen;
        lua_pop(L, 1);
    }
    if (seen != n)
    {
        err = "args must be a dense array of strings";
        return false;
    }

    out.reserve(static_cast<size_t>(n) + 1);
    for (lua_Integer i = 1; i <= n; ++i)
    {
        lua_geti(L, table_idx, i);
        if (!lua_is_strict_string(L, -1))
        {
            lua_pop(L, 1);
            err = "args must contain only strings";
            return false;
        }
        std::string arg;
        const std::string label = "args[" + std::to_string(i) + "]";
        if (!lua_string_without_nul(L, -1, arg, label, err))
        {
            lua_pop(L, 1);
            return false;
        }
        out.push_back(std::move(arg));
        lua_pop(L, 1);
    }
    return true;
}

bool collect_cwd_env(lua_State *L, int idx,
                     std::string &cwd, bool &has_cwd,
                     std::vector<std::pair<std::string, std::string>> &env,
                     std::string &err)
{
    has_cwd = false;
    env.clear();

    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = "opts must be a table";
        return false;
    }

    const int opts_idx = lua_absindex(L, idx);

    lua_pushliteral(L, "cwd");
    lua_rawget(L, opts_idx);
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_string(L, -1))
        {
            lua_pop(L, 1);
            err = "opts.cwd must be a string";
            return false;
        }
        if (!lua_string_without_nul(L, -1, cwd, "opts.cwd", err))
        {
            lua_pop(L, 1);
            return false;
        }
        has_cwd = true;
    }
    lua_pop(L, 1);

    lua_pushliteral(L, "env");
    lua_rawget(L, opts_idx);
    if (!lua_isnil(L, -1))
    {
        if (lua_type(L, -1) != LUA_TTABLE)
        {
            lua_pop(L, 1);
            err = "opts.env must be a table";
            return false;
        }
        const int env_idx = lua_absindex(L, -1);
        lua_pushnil(L);
        while (lua_next(L, env_idx) != 0)
        {
            if (!lua_is_strict_string(L, -2) ||
                !lua_is_strict_string(L, -1))
            {
                lua_pop(L, 3);
                err = "opts.env must map strings to strings";
                return false;
            }
            std::string key;
            std::string value;
            if (!lua_string_without_nul(L, -2, key,
                                        "opts.env: key", err))
            {
                lua_pop(L, 3);
                return false;
            }
            if (key.empty())
            {
                lua_pop(L, 3);
                err = "opts.env: key must not be empty";
                return false;
            }
            if (key.find('=') != std::string::npos)
            {
                lua_pop(L, 3);
                err = "opts.env: key must not contain '='";
                return false;
            }
            if (!lua_string_without_nul(L, -1, value,
                                        "opts.env: value", err))
            {
                lua_pop(L, 3);
                return false;
            }
            env.emplace_back(std::move(key), std::move(value));
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
    return true;
}

long long now_ms()
{
    struct timespec ts{};
    ::clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<long long>(ts.tv_sec) * 1000LL +
           static_cast<long long>(ts.tv_nsec / 1000000L);
}

void kill_group(pid_t pid, int sig)
{
    if (pid <= 0)
    {
        return;
    }
    if (::kill(-pid, sig) != 0 && errno == ESRCH)
    {
        ::kill(pid, sig);
    }
}

ssize_t write_without_sigpipe(int fd, const void *buf, size_t count)
{
    sigset_t block_set;
    ::sigemptyset(&block_set);
    ::sigaddset(&block_set, SIGPIPE);

    sigset_t old_mask;
    const int mask_rc = ::pthread_sigmask(SIG_BLOCK, &block_set, &old_mask);
    if (mask_rc != 0)
    {
        errno = mask_rc;
        return -1;
    }

    sigset_t pending_before_set;
    bool pending_before = false;
    if (::sigpending(&pending_before_set) == 0)
    {
        pending_before = ::sigismember(&pending_before_set, SIGPIPE) == 1;
    }

    const ssize_t result = ::write(fd, buf, count);
    const int saved_errno = errno;

    if (result < 0 && saved_errno == EPIPE && !pending_before)
    {
        struct timespec zero_timeout{};
        while (::sigtimedwait(&block_set, nullptr, &zero_timeout) < 0 &&
               errno == EINTR)
        {
        }
    }

    ::pthread_sigmask(SIG_SETMASK, &old_mask, nullptr);
    errno = saved_errno;
    return result;
}

ChildWaitResult wait_child_until(pid_t pid, int &status,
                                 long long deadline_ms)
{
    for (;;)
    {
        const pid_t r = ::waitpid(pid, &status, WNOHANG);
        if (r == pid)
        {
            return ChildWaitResult::reaped;
        }
        if (r < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            return ChildWaitResult::error;
        }
        if (now_ms() >= deadline_ms)
        {
            return ChildWaitResult::timed_out;
        }
        struct timespec pause{0, 10 * 1000 * 1000};
        while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
        {
        }
    }
}

bool terminate_and_reap(pid_t pid, int &status)
{
    kill_group(pid, SIGTERM);
    if (wait_child_until(pid, status, now_ms() + 500) ==
        ChildWaitResult::reaped)
    {
        return true;
    }
    kill_group(pid, SIGKILL);
    return wait_child_until(pid, status, now_ms() + 2000) ==
           ChildWaitResult::reaped;
}

bool set_nonblocking(int fd, const char *prefix, const char *label,
                     std::string &err)
{
    const int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
    {
        err = prefixed(prefix,
                       std::string("cannot make ") + label +
                           " non-blocking: " + std::strerror(errno));
        return false;
    }
    return true;
}

void close_fd(int &fd)
{
    if (fd >= 0)
    {
        ::close(fd);
        fd = -1;
    }
}

void close_process_fds(LaunchedProcess &process)
{
    close_fd(process.stdin_fd);
    close_fd(process.stdout_fd);
    close_fd(process.stderr_fd);
}

LaunchResult launch(const LaunchSpec &spec)
{
    LaunchResult result;
    if (spec.command.empty() || spec.argv_strings.empty())
    {
        result.error = prefixed(spec.error_prefix,
                                "command and argv must not be empty");
        return result;
    }

    std::vector<char *> argv;
    argv.reserve(spec.argv_strings.size() + 1);
    for (const std::string &arg : spec.argv_strings)
    {
        argv.push_back(const_cast<char *>(arg.c_str()));
    }
    argv.push_back(nullptr);

    std::vector<std::string> env_strings;
    std::vector<char *> envp;
    build_environment(spec.env_overrides, env_strings, envp);

    int pipe_in[2] = {-1, -1};
    int pipe_out[2] = {-1, -1};
    int pipe_err[2] = {-1, -1};
    int pipe_exec[2] = {-1, -1};

    if (make_pipe(pipe_in) != 0)
    {
        result.error = std::string("pipe2() failed: ") + std::strerror(errno);
        return result;
    }
    if (make_pipe(pipe_out) != 0)
    {
        result.error = std::string("pipe2() failed: ") + std::strerror(errno);
        close_pair(pipe_in);
        return result;
    }
    if (make_pipe(pipe_err) != 0)
    {
        result.error = std::string("pipe2() failed: ") + std::strerror(errno);
        close_pair(pipe_in);
        close_pair(pipe_out);
        return result;
    }
    if (make_pipe(pipe_exec) != 0)
    {
        result.error = std::string("pipe2() failed: ") + std::strerror(errno);
        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        return result;
    }

    const pid_t pid = ::fork();
    if (pid < 0)
    {
        result.error = std::string("fork() failed: ") + std::strerror(errno);
        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        close_pair(pipe_exec);
        return result;
    }

    if (pid == 0)
    {
        ::setpgid(0, 0);

        if (::dup2(pipe_in[0], STDIN_FILENO) < 0 ||
            ::dup2(pipe_out[1], STDOUT_FILENO) < 0 ||
            ::dup2(pipe_err[1], STDERR_FILENO) < 0)
        {
            report_launch_failure_and_exit(pipe_exec[1], errno);
        }

        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        ::close(pipe_exec[0]);

        if (spec.has_cwd && ::chdir(spec.cwd.c_str()) != 0)
        {
            report_launch_failure_and_exit(pipe_exec[1], errno);
        }

#ifdef __GLIBC__
        ::execvpe(spec.command.c_str(), argv.data(), envp.data());
#else
        environ = envp.data();
        ::execvp(spec.command.c_str(), argv.data());
#endif

        report_launch_failure_and_exit(pipe_exec[1], errno);
    }

    ::setpgid(pid, pid);

    ::close(pipe_in[0]);
    pipe_in[0] = -1;
    ::close(pipe_out[1]);
    pipe_out[1] = -1;
    ::close(pipe_err[1]);
    pipe_err[1] = -1;
    ::close(pipe_exec[1]);
    pipe_exec[1] = -1;

    LaunchedProcess process;
    process.pid = pid;
    process.stdin_fd = pipe_in[1];
    process.stdout_fd = pipe_out[0];
    process.stderr_fd = pipe_err[0];

    std::string nonblock_error;
    if (!set_nonblocking(pipe_exec[0], spec.error_prefix, "launch pipe",
                         nonblock_error))
    {
        result.error = std::move(nonblock_error);
        close_process_fds(process);
        ::close(pipe_exec[0]);
        int ignored_status = 0;
        terminate_and_reap(pid, ignored_status);
        return result;
    }

    int launch_errno = 0;
    ssize_t launch_bytes = 0;
    for (;;)
    {
        int timeout_ms = -1;
        if (spec.has_deadline)
        {
            const long long remaining = spec.deadline_ms - now_ms();
            timeout_ms = remaining <= 0
                             ? 0
                             : (remaining > INT_MAX
                                    ? INT_MAX
                                    : static_cast<int>(remaining));
        }

        struct pollfd pfd{};
        pfd.fd = pipe_exec[0];
        pfd.events = POLLIN;
        const int pr = ::poll(&pfd, 1, timeout_ms);
        if (pr < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            result.error = prefixed(
                spec.error_prefix,
                std::string("launch poll failed: ") + std::strerror(errno));
            break;
        }
        if (pr == 0)
        {
            result.timed_out = true;
            break;
        }

        launch_bytes = ::read(pipe_exec[0], &launch_errno,
                              sizeof(launch_errno));
        if (launch_bytes > 0)
        {
            if (launch_bytes != static_cast<ssize_t>(sizeof(launch_errno)))
            {
                result.error = prefixed(
                    spec.error_prefix,
                    "incomplete launch error received from child");
            }
            break;
        }
        if (launch_bytes == 0)
        {
            break;
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        {
            continue;
        }
        result.error = prefixed(
            spec.error_prefix,
            std::string("cannot read launch status: ") +
                std::strerror(errno));
        break;
    }
    ::close(pipe_exec[0]);
    pipe_exec[0] = -1;

    if (result.timed_out || !result.error.empty())
    {
        close_process_fds(process);
        result.status_valid = terminate_and_reap(pid, result.status);
        if (!result.error.empty() && !result.status_valid)
        {
            result.error +=
                " (child could not be reaped within cleanup deadline)";
        }
        return result;
    }

    if (launch_bytes > 0)
    {
        close_process_fds(process);
        if (wait_child_until(pid, result.status, now_ms() + 2000) !=
            ChildWaitResult::reaped)
        {
            result.status_valid = terminate_and_reap(pid, result.status);
        }
        else
        {
            result.status_valid = true;
        }
        result.error = std::string("cannot launch '") + spec.command +
                       "': " + std::strerror(launch_errno);
        return result;
    }

    if (!set_nonblocking(process.stdin_fd, spec.error_prefix,
                         "stdin pipe", nonblock_error) ||
        !set_nonblocking(process.stdout_fd, spec.error_prefix,
                         "stdout pipe", nonblock_error) ||
        !set_nonblocking(process.stderr_fd, spec.error_prefix,
                         "stderr pipe", nonblock_error))
    {
        result.error = std::move(nonblock_error);
        close_process_fds(process);
        result.status_valid = terminate_and_reap(pid, result.status);
        return result;
    }

    result.success = true;
    result.process = process;
    return result;
}


void close_pipeline_fds(LaunchedPipeline &pipeline)
{
    close_fd(pipeline.stdin_fd);
    close_fd(pipeline.stdout_fd);
    for (auto &child : pipeline.children)
    {
        close_fd(child.stderr_fd);
    }
}

PipelineLaunchResult launch_pipeline(const PipelineLaunchSpec &spec)
{
    PipelineLaunchResult result;
    const size_t count = spec.stages.size();
    if (count < 2)
    {
        result.error = prefixed(spec.error_prefix,
                                "at least two stages are required");
        return result;
    }

    struct PreparedStage
    {
        std::vector<char *> argv;
        std::vector<std::string> env_strings;
        std::vector<char *> envp;
    };

    // Toutes les allocations sont faites avant le premier fork().
    std::vector<PreparedStage> prepared(count);
    for (size_t i = 0; i < count; ++i)
    {
        const PipelineStageSpec &stage = spec.stages[i];
        if (stage.command.empty() || stage.argv_strings.empty())
        {
            result.error = prefixed(
                spec.error_prefix,
                "stage " + std::to_string(i + 1) +
                    " has an empty command or argv");
            return result;
        }
        prepared[i].argv.reserve(stage.argv_strings.size() + 1);
        for (const std::string &arg : stage.argv_strings)
        {
            prepared[i].argv.push_back(const_cast<char *>(arg.c_str()));
        }
        prepared[i].argv.push_back(nullptr);
        build_environment(stage.env_overrides,
                          prepared[i].env_strings,
                          prepared[i].envp);
    }

    auto make_pipe_vector = [](size_t n) {
        std::vector<std::array<int, 2>> pipes(n);
        for (auto &pipe : pipes)
        {
            pipe[0] = -1;
            pipe[1] = -1;
        }
        return pipes;
    };

    int input[2] = {-1, -1};
    int output[2] = {-1, -1};
    auto links = make_pipe_vector(count - 1);
    auto stderrs = make_pipe_vector(count);
    auto launch_pipes = make_pipe_vector(count);

    auto close_all_raw_pipes = [&]() {
        close_pair(input);
        close_pair(output);
        for (auto &pipe : links)
        {
            close_pair(pipe.data());
        }
        for (auto &pipe : stderrs)
        {
            close_pair(pipe.data());
        }
        for (auto &pipe : launch_pipes)
        {
            close_pair(pipe.data());
        }
    };

    auto create_pipe = [&](int pipe[2], const char *kind) -> bool {
        if (make_pipe(pipe) == 0)
        {
            return true;
        }
        result.error = prefixed(
            spec.error_prefix,
            std::string("cannot create ") + kind + " pipe: " +
                std::strerror(errno));
        return false;
    };

    if (!create_pipe(input, "stdin") || !create_pipe(output, "stdout"))
    {
        close_all_raw_pipes();
        return result;
    }
    for (auto &pipe : links)
    {
        if (!create_pipe(pipe.data(), "pipeline"))
        {
            close_all_raw_pipes();
            return result;
        }
    }
    for (auto &pipe : stderrs)
    {
        if (!create_pipe(pipe.data(), "stderr"))
        {
            close_all_raw_pipes();
            return result;
        }
    }
    for (auto &pipe : launch_pipes)
    {
        if (!create_pipe(pipe.data(), "launch"))
        {
            close_all_raw_pipes();
            return result;
        }
    }

    LaunchedPipeline launched;
    launched.children.reserve(count);

    auto terminate_and_reap_all = [&](long long term_ms,
                                      long long kill_ms) -> bool {
        for (const auto &child : launched.children)
        {
            kill_group(child.pid, SIGTERM);
        }

        // Ne pas récupérer les leaders pendant la période de grâce : leur PID
        // continue d’ancrer le groupe et empêche qu’un SIGKILL ultérieur vise
        // un identifiant recyclé. Cela garantit aussi la suppression d’un
        // descendant qui ignorerait SIGTERM après la sortie du leader direct.
        const long long term_deadline = now_ms() + term_ms;
        while (now_ms() < term_deadline)
        {
            const long long remaining = term_deadline - now_ms();
            struct timespec pause{
                static_cast<time_t>(remaining / 1000),
                static_cast<long>((remaining % 1000) * 1000000LL)};
            while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
            {
            }
        }

        for (const auto &child : launched.children)
        {
            kill_group(child.pid, SIGKILL);
        }

        std::vector<unsigned char> reaped(launched.children.size(), 0);
        size_t remaining = launched.children.size();
        const long long kill_deadline = now_ms() + kill_ms;
        while (remaining > 0)
        {
            for (size_t i = 0; i < launched.children.size(); ++i)
            {
                if (reaped[i])
                {
                    continue;
                }
                int status = 0;
                const pid_t r = ::waitpid(launched.children[i].pid,
                                          &status, WNOHANG);
                if (r == launched.children[i].pid ||
                    (r < 0 && errno == ECHILD))
                {
                    reaped[i] = 1;
                    --remaining;
                }
                else if (r < 0 && errno != EINTR)
                {
                    reaped[i] = 1;
                    --remaining;
                }
            }
            if (remaining == 0 || now_ms() >= kill_deadline)
            {
                break;
            }
            struct timespec pause{0, 10 * 1000 * 1000};
            while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
            {
            }
        }
        return remaining == 0;
    };

    for (size_t i = 0; i < count; ++i)
    {
        const pid_t pid = ::fork();
        if (pid < 0)
        {
            result.error = prefixed(
                spec.error_prefix,
                "fork() failed for stage " + std::to_string(i + 1) +
                    ": " + std::strerror(errno));
            close_all_raw_pipes();
            close_pipeline_fds(launched);
            if (!terminate_and_reap_all(500, 2000))
            {
                result.error +=
                    " (some children could not be reaped during cleanup)";
            }
            return result;
        }

        if (pid == 0)
        {
            ::setpgid(0, 0);
            const int in_fd = i == 0 ? input[0] : links[i - 1][0];
            const int out_fd = i + 1 == count ? output[1] : links[i][1];

            if (::dup2(in_fd, STDIN_FILENO) < 0 ||
                ::dup2(out_fd, STDOUT_FILENO) < 0 ||
                ::dup2(stderrs[i][1], STDERR_FILENO) < 0)
            {
                report_launch_failure_and_exit(launch_pipes[i][1], errno);
            }

            close_pair(input);
            close_pair(output);
            for (auto &pipe : links)
            {
                close_pair(pipe.data());
            }
            for (auto &pipe : stderrs)
            {
                close_pair(pipe.data());
            }
            for (size_t k = 0; k < launch_pipes.size(); ++k)
            {
                close_fd(launch_pipes[k][0]);
                if (k != i)
                {
                    close_fd(launch_pipes[k][1]);
                }
            }

            const PipelineStageSpec &stage = spec.stages[i];
            if (stage.has_cwd && ::chdir(stage.cwd.c_str()) != 0)
            {
                report_launch_failure_and_exit(launch_pipes[i][1], errno);
            }

#ifdef __GLIBC__
            ::execvpe(stage.command.c_str(), prepared[i].argv.data(),
                      prepared[i].envp.data());
#else
            environ = prepared[i].envp.data();
            ::execvp(stage.command.c_str(), prepared[i].argv.data());
#endif
            report_launch_failure_and_exit(launch_pipes[i][1], errno);
        }

        ::setpgid(pid, pid);
        launched.children.push_back({pid, stderrs[i][0]});
        stderrs[i][0] = -1;
        close_fd(launch_pipes[i][1]);
    }

    close_fd(input[0]);
    close_fd(output[1]);
    for (auto &pipe : links)
    {
        close_pair(pipe.data());
    }
    for (auto &pipe : stderrs)
    {
        close_fd(pipe[1]);
    }

    bool launch_failed = false;
    for (size_t i = 0; i < count && !launch_failed; ++i)
    {
        std::string nonblock_error;
        if (!set_nonblocking(launch_pipes[i][0], spec.error_prefix,
                             "launch pipe", nonblock_error))
        {
            result.error = std::move(nonblock_error);
            launch_failed = true;
            break;
        }

        int launch_errno = 0;
        size_t offset = 0;
        bool eof = false;
        while (!eof && offset < sizeof(launch_errno))
        {
            int timeout_ms = -1;
            if (spec.has_deadline)
            {
                const long long remaining = spec.deadline_ms - now_ms();
                timeout_ms = remaining <= 0
                                 ? 0
                                 : (remaining > INT_MAX
                                        ? INT_MAX
                                        : static_cast<int>(remaining));
            }

            struct pollfd pfd{};
            pfd.fd = launch_pipes[i][0];
            pfd.events = POLLIN;
            const int pr = ::poll(&pfd, 1, timeout_ms);
            if (pr < 0)
            {
                if (errno == EINTR)
                {
                    continue;
                }
                result.error = prefixed(
                    spec.error_prefix,
                    "launch poll failed: " + std::string(std::strerror(errno)));
                launch_failed = true;
                break;
            }
            if (pr == 0)
            {
                result.timed_out = true;
                launch_failed = true;
                break;
            }

            const ssize_t n = ::read(
                launch_pipes[i][0],
                reinterpret_cast<unsigned char *>(&launch_errno) + offset,
                sizeof(launch_errno) - offset);
            if (n > 0)
            {
                offset += static_cast<size_t>(n);
                continue;
            }
            if (n == 0)
            {
                eof = true;
                break;
            }
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
            {
                continue;
            }
            result.error = prefixed(
                spec.error_prefix,
                "cannot read launch status: " +
                    std::string(std::strerror(errno)));
            launch_failed = true;
            break;
        }

        close_fd(launch_pipes[i][0]);
        if (!launch_failed && offset > 0)
        {
            if (offset != sizeof(launch_errno))
            {
                result.error = prefixed(
                    spec.error_prefix,
                    "incomplete launch error received from stage " +
                        std::to_string(i + 1));
            }
            else
            {
                result.error = prefixed(
                    spec.error_prefix,
                    "stage " + std::to_string(i + 1) + " cannot launch '" +
                        spec.stages[i].command + "': " +
                        std::strerror(launch_errno));
            }
            launch_failed = true;
        }
    }

    for (auto &pipe : launch_pipes)
    {
        close_fd(pipe[0]);
    }

    if (launch_failed)
    {
        close_fd(input[1]);
        close_fd(output[0]);
        close_pipeline_fds(launched);
        if (!terminate_and_reap_all(500, 2000) && !result.timed_out)
        {
            result.error +=
                " (some children could not be reaped during cleanup)";
        }
        return result;
    }

    std::string nonblock_error;
    if (!set_nonblocking(input[1], spec.error_prefix, "stdin pipe",
                         nonblock_error) ||
        !set_nonblocking(output[0], spec.error_prefix, "stdout pipe",
                         nonblock_error))
    {
        result.error = std::move(nonblock_error);
        close_fd(input[1]);
        close_fd(output[0]);
        close_pipeline_fds(launched);
        terminate_and_reap_all(500, 2000);
        return result;
    }
    for (auto &child : launched.children)
    {
        if (!set_nonblocking(child.stderr_fd, spec.error_prefix,
                             "stderr pipe", nonblock_error))
        {
            result.error = std::move(nonblock_error);
            close_fd(input[1]);
            close_fd(output[0]);
            close_pipeline_fds(launched);
            terminate_and_reap_all(500, 2000);
            return result;
        }
    }

    launched.stdin_fd = input[1];
    launched.stdout_fd = output[0];
    result.success = true;
    result.pipeline = std::move(launched);
    return result;
}

int exit_code_from_status(int status, bool status_valid)
{
    if (!status_valid)
    {
        return -1;
    }
    if (WIFEXITED(status))
    {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status))
    {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

} // namespace babet_process
