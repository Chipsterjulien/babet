#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "process_common.hpp"
#include "curses.hpp"
#include "process_launch_internal.hpp"
#include "process_terminal_internal.hpp"
#include "lua_utils.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <csignal>
#include <cstring>

#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace babet_process
{
namespace
{

std::string prefixed(const char *prefix, const std::string &message);

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

bool clear_nonblocking(int fd, const char *prefix, const char *label,
                       std::string &err)
{
    const int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags < 0 ||
        ((flags & O_NONBLOCK) != 0 &&
         ::fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0))
    {
        err = prefixed(prefix,
                       std::string("cannot configure ") + label + ": " +
                           std::strerror(errno));
        return false;
    }
    return true;
}

bool open_null_redirection(bool for_input, const char *prefix,
                           const char *label, int &fd, std::string &err)
{
    const int flags = (for_input ? O_RDONLY : O_WRONLY) | O_CLOEXEC;
    fd = ::open("/dev/null", flags);
    if (fd < 0)
    {
        err = prefixed(prefix,
                       std::string("cannot open /dev/null for ") + label +
                           ": " + std::strerror(errno));
        return false;
    }
    if (move_fd_above_standard_streams(fd) != 0)
    {
        const int saved = errno;
        ::close(fd);
        fd = -1;
        errno = saved;
        err = prefixed(prefix,
                       std::string("cannot prepare /dev/null for ") + label +
                           ": " + std::strerror(errno));
        return false;
    }
    return true;
}

bool open_output_redirection(const FileRedirection &file,
                             const char *prefix, const char *label,
                             int &fd, std::string &err)
{
    const int common_flags = O_WRONLY | O_CLOEXEC | O_NOFOLLOW |
                             O_NONBLOCK |
                             (file.append ? O_APPEND : 0);
    bool created = false;

    fd = ::open(file.path.c_str(), common_flags | O_CREAT | O_EXCL, 0600);
    if (fd >= 0)
    {
        created = true;
    }
    else if (errno == EEXIST)
    {
        fd = ::open(file.path.c_str(), common_flags);
    }

    if (fd < 0)
    {
        err = prefixed(prefix,
                       std::string("cannot open ") + label + " file '" +
                           file.path + "': " + std::strerror(errno));
        return false;
    }

    auto fail_open = [&](const std::string &message) {
        const int saved = errno;
        ::close(fd);
        fd = -1;
        errno = saved;
        err = prefixed(prefix, message);
        return false;
    };

    struct stat st{};
    if (::fstat(fd, &st) != 0)
    {
        return fail_open(std::string("cannot inspect ") + label +
                         " file '" + file.path + "': " +
                         std::strerror(errno));
    }
    if (!S_ISREG(st.st_mode))
    {
        errno = EINVAL;
        return fail_open(std::string(label) + " destination '" + file.path +
                         "' is not a regular file");
    }

    if (created && ::fchmod(fd, file.permissions & 0777) != 0)
    {
        return fail_open(std::string("cannot set permissions on ") + label +
                         " file '" + file.path + "': " +
                         std::strerror(errno));
    }
    if (!file.append && ::ftruncate(fd, 0) != 0)
    {
        return fail_open(std::string("cannot truncate ") + label +
                         " file '" + file.path + "': " +
                         std::strerror(errno));
    }
    if (!clear_nonblocking(fd, prefix, label, err))
    {
        const int saved = errno;
        ::close(fd);
        fd = -1;
        errno = saved;
        return false;
    }
    if (move_fd_above_standard_streams(fd) != 0)
    {
        const int saved = errno;
        ::close(fd);
        fd = -1;
        errno = saved;
        err = prefixed(prefix,
                       std::string("cannot prepare ") + label + " file '" +
                           file.path + "': " + std::strerror(errno));
        return false;
    }
    return true;
}

bool valid_launch_redirections(const LaunchSpec &spec, std::string &err)
{
    const auto stdin_kind = spec.stdin_redirection.kind;
    if (stdin_kind != StreamRedirectionKind::pipe &&
        stdin_kind != StreamRedirectionKind::inherit &&
        stdin_kind != StreamRedirectionKind::null_device)
    {
        err = prefixed(spec.error_prefix, "invalid stdin redirection");
        return false;
    }

    const auto stdout_kind = spec.stdout_redirection.kind;
    if (stdout_kind != StreamRedirectionKind::pipe &&
        stdout_kind != StreamRedirectionKind::inherit &&
        stdout_kind != StreamRedirectionKind::null_device &&
        stdout_kind != StreamRedirectionKind::file)
    {
        err = prefixed(spec.error_prefix, "invalid stdout redirection");
        return false;
    }

    const auto stderr_kind = spec.stderr_redirection.kind;
    if (stderr_kind != StreamRedirectionKind::pipe &&
        stderr_kind != StreamRedirectionKind::inherit &&
        stderr_kind != StreamRedirectionKind::null_device &&
        stderr_kind != StreamRedirectionKind::file &&
        stderr_kind != StreamRedirectionKind::stdout_stream)
    {
        err = prefixed(spec.error_prefix, "invalid stderr redirection");
        return false;
    }
    return true;
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
        lua_rawgeti(L, table_idx, i);
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
    // Un processus suspendu ne peut pas traiter SIGTERM tant qu'il n'est pas
    // repris. SIGCONT est sans effet nuisible sur un processus déjà actif.
    kill_group(pid, SIGCONT);
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

void close_fd(int &fd) noexcept
{
    if (fd >= 0)
    {
        ::close(fd);
        fd = -1;
    }
}

void close_process_fds(LaunchedProcess &process) noexcept
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
    if (!valid_launch_redirections(spec, result.error))
    {
        return result;
    }

    detail::PreparedCommand prepared_command;
    int preparation_errno = 0;
    if (!detail::prepare_command(spec.command, spec.argv_strings, spec.cwd,
                                 spec.has_cwd, spec.env_overrides,
                                 prepared_command, preparation_errno))
    {
        result.error = prefixed(
            spec.error_prefix,
            std::string("cannot launch '") + spec.command + "': " +
                std::strerror(preparation_errno));
        return result;
    }

    int pipe_in[2] = {-1, -1};
    int pipe_out[2] = {-1, -1};
    int pipe_err[2] = {-1, -1};
    int pipe_exec[2] = {-1, -1};
    int pipe_terminal[2] = {-1, -1};
    int terminal_fd = -1;
    pid_t terminal_restore_pgid = -1;
    struct termios terminal_restore_attributes{};
    bool terminal_attributes_valid = false;
    bool use_terminal_handoff = false;
    unsigned long terminal_reservation_token = 0;
    int stdin_target = -1;
    int stdout_target = -1;
    int stderr_target = -1;
    LaunchedProcess process;

    auto close_prepared = [&]() noexcept {
        babet_curses::cancel_reserved_terminal_handoff(terminal_reservation_token);
        detail::cancel_terminal_reservation(terminal_reservation_token);
        terminal_reservation_token = 0;
        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        close_pair(pipe_exec);
        close_pair(pipe_terminal);
        close_fd(terminal_fd);
        close_fd(stdin_target);
        close_fd(stdout_target);
        close_fd(stderr_target);
    };

    auto make_stream_pipe = [&](int p[2], const char *label) {
        if (make_pipe(p) == 0)
        {
            return true;
        }
        result.error = prefixed(
            spec.error_prefix,
            std::string("cannot create ") + label + " pipe: " +
                std::strerror(errno));
        return false;
    };

    try
    {
        if (spec.stdin_redirection.kind == StreamRedirectionKind::pipe &&
            !make_stream_pipe(pipe_in, "stdin"))
        {
            close_prepared();
            return result;
        }
        if (spec.stdout_redirection.kind == StreamRedirectionKind::pipe &&
            !make_stream_pipe(pipe_out, "stdout"))
        {
            close_prepared();
            return result;
        }
        if (spec.stderr_redirection.kind == StreamRedirectionKind::pipe &&
            !make_stream_pipe(pipe_err, "stderr"))
        {
            close_prepared();
            return result;
        }

        if (spec.stdin_redirection.kind ==
                StreamRedirectionKind::null_device &&
            !open_null_redirection(true, spec.error_prefix, "stdin",
                                   stdin_target, result.error))
        {
            close_prepared();
            return result;
        }
        if (spec.stdout_redirection.kind ==
                StreamRedirectionKind::null_device &&
            !open_null_redirection(false, spec.error_prefix, "stdout",
                                   stdout_target, result.error))
        {
            close_prepared();
            return result;
        }
        if (spec.stdout_redirection.kind == StreamRedirectionKind::file &&
            !open_output_redirection(spec.stdout_redirection.file,
                                     spec.error_prefix, "stdout",
                                     stdout_target, result.error))
        {
            close_prepared();
            return result;
        }
        if (spec.stderr_redirection.kind ==
                StreamRedirectionKind::null_device &&
            !open_null_redirection(false, spec.error_prefix, "stderr",
                                   stderr_target, result.error))
        {
            close_prepared();
            return result;
        }
        if (spec.stderr_redirection.kind == StreamRedirectionKind::file &&
            !open_output_redirection(spec.stderr_redirection.file,
                                     spec.error_prefix, "stderr",
                                     stderr_target, result.error))
        {
            close_prepared();
            return result;
        }
        if (spec.stdin_redirection.kind ==
                StreamRedirectionKind::inherit &&
            ::isatty(STDIN_FILENO) == 1)
        {
            if (!detail::duplicate_terminal_fd(terminal_fd))
            {
                result.error = prefixed(
                    spec.error_prefix,
                    std::string("cannot duplicate inherited terminal: ") +
                        std::strerror(errno));
                close_prepared();
                return result;
            }

            const pid_t parent_pgid = ::getpgrp();
            const detail::TerminalReservationResult reservation =
                detail::reserve_terminal_handoff(
                    terminal_fd, parent_pgid, terminal_reservation_token,
                    terminal_restore_attributes, spec.has_deadline,
                    spec.deadline_ms);

            if (reservation == detail::TerminalReservationResult::busy)
            {
                result.error = prefixed(spec.error_prefix,
                                        "terminal handoff is busy");
                close_prepared();
                return result;
            }
            if (reservation == detail::TerminalReservationResult::error)
            {
                if (errno != ENOTTY)
                {
                    result.error = prefixed(
                        spec.error_prefix,
                        std::string("cannot inspect inherited terminal: ") +
                            std::strerror(errno));
                    close_prepared();
                    return result;
                }
                close_fd(terminal_fd);
            }
            else if (reservation == detail::TerminalReservationResult::acquired)
            {
                terminal_attributes_valid = true;
                terminal_restore_pgid = parent_pgid;
                use_terminal_handoff = true;

                std::string curses_error;
                const auto curses_prepare =
                    babet_curses::prepare_reserved_terminal_handoff(
                        terminal_reservation_token, curses_error);
                if (curses_prepare ==
                    babet_curses::HandoffPrepareResult::error)
                {
                    result.error = prefixed(spec.error_prefix, curses_error);
                    close_prepared();
                    return result;
                }
                if (curses_prepare ==
                    babet_curses::HandoffPrepareResult::suspended)
                {
                    // La réservation a capturé les attributs pendant que
                    // curses était encore en mode programme. Après endwin(),
                    // mémoriser le vrai mode shell : c'est celui que le
                    // moniteur doit restaurer avant une reprise curses, et
                    // surtout celui qui doit rester si curses.stop() est
                    // demandé pendant que l'enfant possède le TTY.
                    int attr_rc = -1;
                    do
                    {
                        attr_rc = ::tcgetattr(terminal_fd,
                                              &terminal_restore_attributes);
                    } while (attr_rc != 0 && errno == EINTR);
                    if (attr_rc != 0)
                    {
                        const int saved = errno;
                        result.error = prefixed(
                            spec.error_prefix,
                            std::string("cannot snapshot terminal after curses suspension: ") +
                                std::strerror(saved));
                        close_prepared();
                        return result;
                    }
                }

                detail::delay_terminal_reservation_for_test();
                if (!make_stream_pipe(pipe_terminal, "terminal-handoff"))
                {
                    close_prepared();
                    return result;
                }
            }
            else
            {
                // Le lanceur est lui-même en arrière-plan : il ne doit pas
                // voler le terminal au groupe de premier plan actuel.
                close_fd(terminal_fd);
            }
        }

        if (!make_stream_pipe(pipe_exec, "launch-status"))
        {
            close_prepared();
            return result;
        }

        detail::delay_before_fork_for_test();

        const pid_t pid = ::fork();
        if (pid < 0)
        {
            result.error = prefixed(spec.error_prefix,
                                    std::string("fork() failed: ") +
                                        std::strerror(errno));
            close_prepared();
            return result;
        }

        if (pid == 0)
        {
            if (::setpgid(0, 0) != 0)
            {
                report_launch_failure_and_exit(pipe_exec[1], errno);
            }

            if (use_terminal_handoff)
            {
                close_fd(pipe_terminal[1]);
                char release = 0;
                ssize_t received = -1;
                do
                {
                    received = ::read(pipe_terminal[0], &release, 1);
                } while (received < 0 && errno == EINTR);
                close_fd(pipe_terminal[0]);
                close_fd(terminal_fd);
                if (received != 1)
                {
                    report_launch_failure_and_exit(pipe_exec[1], ECANCELED);
                }
            }

            auto duplicate_stream = [&](StreamRedirectionKind kind,
                                        int pipe_child_fd, int target_fd,
                                        int standard_fd) {
                if (kind == StreamRedirectionKind::inherit)
                {
                    return true;
                }
                const int source = kind == StreamRedirectionKind::pipe
                                       ? pipe_child_fd
                                       : target_fd;
                return source >= 0 && ::dup2(source, standard_fd) >= 0;
            };

            if (!duplicate_stream(spec.stdin_redirection.kind, pipe_in[0],
                                  stdin_target, STDIN_FILENO) ||
                !duplicate_stream(spec.stdout_redirection.kind, pipe_out[1],
                                  stdout_target, STDOUT_FILENO))
            {
                report_launch_failure_and_exit(pipe_exec[1], errno);
            }

            if (spec.stderr_redirection.kind ==
                StreamRedirectionKind::stdout_stream)
            {
                if (::dup2(STDOUT_FILENO, STDERR_FILENO) < 0)
                {
                    report_launch_failure_and_exit(pipe_exec[1], errno);
                }
            }
            else if (!duplicate_stream(spec.stderr_redirection.kind,
                                       pipe_err[1], stderr_target,
                                       STDERR_FILENO))
            {
                report_launch_failure_and_exit(pipe_exec[1], errno);
            }

            close_pair(pipe_in);
            close_pair(pipe_out);
            close_pair(pipe_err);
            close_pair(pipe_terminal);
            close_fd(terminal_fd);
            close_fd(stdin_target);
            close_fd(stdout_target);
            close_fd(stderr_target);
            ::close(pipe_exec[0]);

            if (spec.has_cwd && ::chdir(spec.cwd.c_str()) != 0)
            {
                report_launch_failure_and_exit(pipe_exec[1], errno);
            }

            const int launch_errno =
                detail::exec_prepared_command(prepared_command);
            report_launch_failure_and_exit(pipe_exec[1], launch_errno);
        }

        // À partir d'ici, toute exception doit nettoyer l'enfant avant de
        // remonter vers la frontière Lua. Aucun appel lua_* n'est autorisé
        // dans cette région : un longjmp contournerait le catch ci-dessous.
        process.pid = pid;
        int setpgid_rc = -1;
        do
        {
            setpgid_rc = ::setpgid(pid, pid);
        } while (setpgid_rc != 0 && errno == EINTR);
        if (setpgid_rc != 0)
        {
            const int setpgid_errno = errno;
            pid_t actual_pgid = -1;
            do
            {
                actual_pgid = ::getpgid(pid);
            } while (actual_pgid < 0 && errno == EINTR);
            if (actual_pgid != pid)
            {
                result.error = prefixed(
                    spec.error_prefix,
                    std::string("cannot isolate child process group: ") +
                        std::strerror(setpgid_errno));
                close_fd(pipe_terminal[1]);
                close_process_fds(process);
                close_prepared();
                int ignored_status = 0;
                if (terminate_and_reap(pid, ignored_status))
                {
                    process.pid = -1;
                }
                return result;
            }
        }

        close_fd(pipe_in[0]);
        close_fd(pipe_out[1]);
        close_fd(pipe_err[1]);
        close_fd(pipe_exec[1]);
        close_fd(stdin_target);
        close_fd(stdout_target);
        close_fd(stderr_target);

        process.stdin_fd = std::exchange(pipe_in[1], -1);
        process.stdout_fd = std::exchange(pipe_out[0], -1);
        process.stderr_fd = std::exchange(pipe_err[0], -1);
        process.stdin_piped =
            spec.stdin_redirection.kind == StreamRedirectionKind::pipe;
        process.stdout_piped =
            spec.stdout_redirection.kind == StreamRedirectionKind::pipe;
        process.stderr_piped =
            spec.stderr_redirection.kind == StreamRedirectionKind::pipe;

        if (use_terminal_handoff)
        {
            close_fd(pipe_terminal[0]);
            process.terminal.fd = std::exchange(terminal_fd, -1);
            process.terminal.owner_pgid = pid;
            process.terminal.restore_pgid = terminal_restore_pgid;
            process.terminal.restore_attributes = terminal_restore_attributes;
            process.terminal.attributes_valid = terminal_attributes_valid;
            process.terminal.active = true;
            const unsigned long committed_reservation_token =
                terminal_reservation_token;
            const bool terminal_committed = detail::commit_terminal_handoff(
                process.terminal.fd, committed_reservation_token, pid,
                terminal_restore_pgid, terminal_restore_attributes);
            terminal_reservation_token = 0;
            if (!terminal_committed)
            {
                babet_curses::cancel_reserved_terminal_handoff(
                    committed_reservation_token);
                result.error = prefixed(
                    spec.error_prefix,
                    std::string("cannot give terminal to child: ") +
                        std::strerror(errno));
                close_fd(pipe_terminal[1]);
                close_process_fds(process);
                int ignored_status = 0;
                if (terminate_and_reap(pid, ignored_status))
                {
                    process.pid = -1;
                }
                restore_terminal(process.terminal);
                babet_curses::service_terminal_events();
                close_fd(pipe_exec[0]);
                return result;
            }

            const char release = 1;
            const ssize_t released =
                write_without_sigpipe(pipe_terminal[1], &release, 1);
            const int release_errno = errno;
            close_fd(pipe_terminal[1]);
            if (released != 1)
            {
                result.error = prefixed(
                    spec.error_prefix,
                    std::string("cannot release interactive child: ") +
                        std::strerror(release_errno));
                close_process_fds(process);
                int ignored_status = 0;
                if (terminate_and_reap(pid, ignored_status))
                {
                    process.pid = -1;
                }
                restore_terminal(process.terminal);
                babet_curses::service_terminal_events();
                close_fd(pipe_exec[0]);
                return result;
            }
        }

        std::string nonblock_error;
        if (!set_nonblocking(pipe_exec[0], spec.error_prefix, "launch pipe",
                             nonblock_error))
        {
            result.error = std::move(nonblock_error);
            close_process_fds(process);
            close_fd(pipe_exec[0]);
            int ignored_status = 0;
            if (terminate_and_reap(pid, ignored_status))
            {
                process.pid = -1;
            }
            restore_terminal(process.terminal);
            babet_curses::service_terminal_events();
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
                    std::string("launch poll failed: ") +
                        std::strerror(errno));
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
                if (launch_bytes !=
                    static_cast<ssize_t>(sizeof(launch_errno)))
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
        close_fd(pipe_exec[0]);

        if (result.timed_out || !result.error.empty())
        {
            close_process_fds(process);
            result.status_valid = terminate_and_reap(pid, result.status);
            if (result.status_valid)
            {
                process.pid = -1;
            }
            if (!result.error.empty() && !result.status_valid)
            {
                result.error +=
                    " (child could not be reaped within cleanup deadline)";
            }
            restore_terminal(process.terminal);
            babet_curses::service_terminal_events();
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
            if (result.status_valid)
            {
                process.pid = -1;
            }
            result.error = prefixed(
                spec.error_prefix,
                std::string("cannot launch '") + spec.command + "': " +
                    std::strerror(launch_errno));
            restore_terminal(process.terminal);
            babet_curses::service_terminal_events();
            return result;
        }

        if ((process.stdin_piped &&
             !set_nonblocking(process.stdin_fd, spec.error_prefix,
                              "stdin pipe", nonblock_error)) ||
            (process.stdout_piped &&
             !set_nonblocking(process.stdout_fd, spec.error_prefix,
                              "stdout pipe", nonblock_error)) ||
            (process.stderr_piped &&
             !set_nonblocking(process.stderr_fd, spec.error_prefix,
                              "stderr pipe", nonblock_error)))
        {
            result.error = std::move(nonblock_error);
            close_process_fds(process);
            result.status_valid = terminate_and_reap(pid, result.status);
            if (result.status_valid)
            {
                process.pid = -1;
            }
            restore_terminal(process.terminal);
            babet_curses::service_terminal_events();
            return result;
        }

        if (use_terminal_handoff)
        {
            std::string monitor_error;
            if (!detail::start_terminal_exit_monitor(pid, process.terminal,
                                             monitor_error))
            {
                result.error = prefixed(spec.error_prefix, monitor_error);
                close_process_fds(process);
                result.status_valid = terminate_and_reap(pid, result.status);
                if (result.status_valid)
                {
                    process.pid = -1;
                }
                restore_terminal(process.terminal);
                return result;
            }
        }

        result.success = true;
        result.process = process;
        process.pid = -1;
        process.stdin_fd = -1;
        process.stdout_fd = -1;
        process.stderr_fd = -1;
        process.terminal.fd = -1;
        process.terminal.owner_pgid = -1;
        process.terminal.restore_pgid = -1;
        process.terminal.attributes_valid = false;
        process.terminal.child_attributes_valid = false;
        process.terminal.active = false;
        return result;
    }
    catch (...)
    {
        close_prepared();
        emergency_kill_and_reap(process);
        throw;
    }
}

void close_pipeline_fds(LaunchedPipeline &pipeline) noexcept
{
    close_fd(pipeline.stdin_fd);
    close_fd(pipeline.stdout_fd);
    for (auto &child : pipeline.children)
    {
        close_fd(child.stderr_fd);
    }
}


bool emergency_kill_and_reap(LaunchedProcess &process,
                             long long reap_timeout_ms) noexcept
{
    close_process_fds(process);
    if (process.pid <= 0)
    {
        restore_terminal(process.terminal);
        return true;
    }

    kill_group(process.pid, SIGKILL);
    const long long deadline = now_ms() + std::max<long long>(0, reap_timeout_ms);
    for (;;)
    {
        int status = 0;
        const pid_t waited = ::waitpid(process.pid, &status, WNOHANG);
        if (waited == process.pid || (waited < 0 && errno == ECHILD))
        {
            process.pid = -1;
            restore_terminal(process.terminal);
            return true;
        }
        if (waited < 0 && errno != EINTR)
        {
            restore_terminal(process.terminal);
            return false;
        }
        if (now_ms() >= deadline)
        {
            restore_terminal(process.terminal);
            return false;
        }
        struct timespec pause{0, 10 * 1000 * 1000};
        while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
        {
        }
    }
}

bool emergency_kill_and_reap(LaunchedPipeline &pipeline,
                             long long reap_timeout_ms) noexcept
{
    close_pipeline_fds(pipeline);

    size_t remaining = 0;
    for (auto &child : pipeline.children)
    {
        if (child.pid > 0)
        {
            kill_group(child.pid, SIGKILL);
            ++remaining;
        }
    }
    if (remaining == 0)
    {
        return true;
    }

    const long long deadline = now_ms() + std::max<long long>(0, reap_timeout_ms);
    while (remaining > 0)
    {
        for (auto &child : pipeline.children)
        {
            if (child.pid <= 0)
            {
                continue;
            }
            int status = 0;
            const pid_t waited = ::waitpid(child.pid, &status, WNOHANG);
            if (waited == child.pid || (waited < 0 && errno == ECHILD))
            {
                child.pid = -1;
                --remaining;
            }
            else if (waited < 0 && errno != EINTR)
            {
                child.pid = -1;
                --remaining;
            }
        }
        if (remaining == 0)
        {
            return true;
        }
        if (now_ms() >= deadline)
        {
            return false;
        }
        struct timespec pause{0, 10 * 1000 * 1000};
        while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
        {
        }
    }
    return true;
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
    if (count > MAX_PIPELINE_STAGES)
    {
        result.error = prefixed(spec.error_prefix,
                                "too many pipeline stages");
        return result;
    }

    // Toutes les allocations et la résolution PATH sont faites avant le
    // premier fork().
    std::vector<detail::PreparedCommand> prepared(count);
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
        int preparation_errno = 0;
        if (!detail::prepare_command(
                stage.command, stage.argv_strings, stage.cwd, stage.has_cwd,
                stage.env_overrides, prepared[i], preparation_errno))
        {
            result.error = prefixed(
                spec.error_prefix,
                "stage " + std::to_string(i + 1) + " cannot launch '" +
                    stage.command + "': " + std::strerror(preparation_errno));
            return result;
        }
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

    auto close_all_raw_pipes = [&]() noexcept {
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

    LaunchedPipeline launched;
    launched.children.reserve(count);

    try
    {
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

    auto terminate_and_reap_all = [&](long long term_ms,
                                      long long kill_ms) noexcept -> bool {
        for (const auto &child : launched.children)
        {
            if (child.pid > 0)
            {
                kill_group(child.pid, SIGTERM);
            }
        }

        // Tous les groupes reçoivent SIGTERM immédiatement. Les leaders déjà
        // terminés restent volontairement non réapés pendant la grâce afin que
        // leur PID, également utilisé comme PGID, ne puisse pas être recyclé
        // avant l'éventuel SIGKILL final.
        const long long term_deadline = now_ms() + term_ms;
        while (now_ms() < term_deadline)
        {
            const long long remaining_ms = term_deadline - now_ms();
            struct timespec pause{
                static_cast<time_t>(remaining_ms / 1000),
                static_cast<long>((remaining_ms % 1000) * 1000000LL)};
            while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
            {
            }
        }

        size_t remaining = 0;
        for (const auto &child : launched.children)
        {
            if (child.pid > 0)
            {
                kill_group(child.pid, SIGKILL);
                ++remaining;
            }
        }

        const long long kill_deadline = now_ms() + kill_ms;
        while (remaining > 0)
        {
            for (auto &child : launched.children)
            {
                if (child.pid <= 0)
                {
                    continue;
                }
                int status = 0;
                const pid_t r = ::waitpid(child.pid, &status, WNOHANG);
                if (r == child.pid || (r < 0 && errno == ECHILD))
                {
                    child.pid = -1;
                    --remaining;
                }
                else if (r < 0 && errno != EINTR)
                {
                    child.pid = -1;
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

        // Dès le premier fork réussi, aucune API Lua ne doit être appelée dans
        // cette région : un longjmp contournerait le catch et le nettoyage.
        detail::delay_before_fork_for_test();
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

            const int launch_errno = detail::exec_prepared_command(prepared[i]);
            report_launch_failure_and_exit(launch_pipes[i][1], launch_errno);
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

        launched.stdin_fd = std::exchange(input[1], -1);
        launched.stdout_fd = std::exchange(output[0], -1);
        result.success = true;
        result.pipeline = std::move(launched);
        return result;
    }
    catch (...)
    {
        close_all_raw_pipes();
        close_pipeline_fds(launched);
        emergency_kill_and_reap(launched);
        throw;
    }
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
