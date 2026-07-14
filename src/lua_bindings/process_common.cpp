#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "process_common.hpp"
#include "lua_utils.hpp"

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

int make_pipe(int p[2])
{
#ifdef O_CLOEXEC
    return ::pipe2(p, O_CLOEXEC);
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
    return 0;
#endif
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

} // namespace

bool collect_args(lua_State *L, int idx, const std::string &cmd,
                  std::vector<std::string> &out, std::string &err)
{
    out.clear();
    out.push_back(cmd);

    if (lua_isnoneornil(L, idx))
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
        if (!lua_isinteger(L, -2))
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
        if (lua_type(L, -1) != LUA_TSTRING)
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

    if (lua_isnoneornil(L, idx))
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
        if (lua_type(L, -1) != LUA_TSTRING)
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
            if (lua_type(L, -2) != LUA_TSTRING ||
                lua_type(L, -1) != LUA_TSTRING)
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

    std::unordered_set<std::string> override_keys;
    for (const auto &kv : spec.env_overrides)
    {
        override_keys.insert(kv.first);
    }

    std::vector<std::string> env_strings;
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
            env_strings.push_back(std::move(entry));
        }
    }
    for (const auto &kv : spec.env_overrides)
    {
        std::string entry = kv.first;
        entry.push_back('=');
        entry.append(kv.second);
        env_strings.push_back(std::move(entry));
    }

    std::vector<char *> envp;
    envp.reserve(env_strings.size() + 1);
    for (std::string &entry : env_strings)
    {
        envp.push_back(entry.data());
    }
    envp.push_back(nullptr);

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
            const int e = errno;
            const ssize_t ignored = ::write(pipe_exec[1], &e, sizeof(e));
            (void)ignored;
            _exit(127);
        }

        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        ::close(pipe_exec[0]);

        if (spec.has_cwd && ::chdir(spec.cwd.c_str()) != 0)
        {
            const int e = errno;
            const ssize_t ignored = ::write(pipe_exec[1], &e, sizeof(e));
            (void)ignored;
            _exit(127);
        }

#ifdef __GLIBC__
        ::execvpe(spec.command.c_str(), argv.data(), envp.data());
#else
        environ = envp.data();
        ::execvp(spec.command.c_str(), argv.data());
#endif

        const int e = errno;
        const ssize_t ignored = ::write(pipe_exec[1], &e, sizeof(e));
        (void)ignored;
        _exit(127);
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
