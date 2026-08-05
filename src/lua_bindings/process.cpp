#include "process.hpp"
#include "process_common.hpp"
#include "lua_utils.hpp"
#include "signal.hpp"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <csignal>
#include <cstring>
#include <ctime>
#include <limits>
#include <new>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <poll.h>
#include <sys/wait.h>
#include <unistd.h>

namespace
{

constexpr const char *PROCESS_META = "babet.process";
constexpr size_t DEFAULT_READ_SIZE = 64 * 1024;
constexpr size_t MAX_READ_SIZE = 16 * 1024 * 1024;
constexpr double DEFAULT_TERMINATE_GRACE = 2.0;

struct Process
{
    pid_t pid;
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
    bool stdin_piped;
    bool stdout_piped;
    bool stderr_piped;
    babet_process::TerminalHandoff terminal;
    int status;
    bool status_valid;
    bool stopped;
    bool closed;
};

Process *check_process(lua_State *L, int idx)
{
    return static_cast<Process *>(luaL_checkudata(L, idx, PROCESS_META));
}

Process *push_empty_process(lua_State *L)
{
    void *raw = lua_newuserdatauv(L, sizeof(Process), 0);
    auto *process = static_cast<Process *>(raw);
    process->pid = -1;
    process->stdin_fd = -1;
    process->stdout_fd = -1;
    process->stderr_fd = -1;
    process->stdin_piped = false;
    process->stdout_piped = false;
    process->stderr_piped = false;
    process->terminal = babet_process::TerminalHandoff{};
    process->status = 0;
    process->status_valid = false;
    process->stopped = false;
    process->closed = true;
    luaL_getmetatable(L, PROCESS_META);
    lua_setmetatable(L, -2);
    return process;
}

void initialize_process(Process *process,
                        const babet_process::LaunchedProcess &launched)
{
    process->pid = launched.pid;
    process->stdin_fd = launched.stdin_fd;
    process->stdout_fd = launched.stdout_fd;
    process->stderr_fd = launched.stderr_fd;
    process->stdin_piped = launched.stdin_piped;
    process->stdout_piped = launched.stdout_piped;
    process->stderr_piped = launched.stderr_piped;
    process->terminal = launched.terminal;
    process->status = 0;
    process->status_valid = false;
    process->stopped = false;
    process->closed = false;
}

void raw_getfield(lua_State *L, int idx, const char *name)
{
    idx = lua_absindex(L, idx);
    lua_pushstring(L, name);
    lua_rawget(L, idx);
}

bool validate_spawn_opts_keys(lua_State *L, int idx, std::string &err)
{
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = "opts must be a table";
        return false;
    }

    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 2);
            err = "opts keys must be strings";
            return false;
        }
        size_t len = 0;
        const char *data = lua_tolstring(L, -2, &len);
        const std::string_view key(data, len);
        if (key != "cwd" && key != "env" && key != "launch_timeout" &&
            key != "stdin" && key != "stdout" && key != "stderr")
        {
            err = "unknown spawn option: ";
            err.append(key.data(), key.size());
            lua_pop(L, 2);
            return false;
        }
        lua_pop(L, 1);
    }
    return true;
}

bool validate_file_redirection_keys(lua_State *L, int idx,
                                    const char *label, std::string &err)
{
    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 2);
            err = std::string(label) + " keys must be strings";
            return false;
        }
        size_t len = 0;
        const char *data = lua_tolstring(L, -2, &len);
        const std::string_view key(data, len);
        if (key != "file" && key != "append" && key != "permissions")
        {
            err = std::string("unknown ") + label + " option: ";
            err.append(key.data(), key.size());
            lua_pop(L, 2);
            return false;
        }
        lua_pop(L, 1);
    }
    return true;
}

bool parse_file_redirection(lua_State *L, int idx, const char *label,
                            babet_process::StreamRedirection &out,
                            std::string &err)
{
    if (!validate_file_redirection_keys(L, idx, label, err))
    {
        return false;
    }

    idx = lua_absindex(L, idx);
    raw_getfield(L, idx, "file");
    if (!lua_is_strict_string(L, -1))
    {
        lua_pop(L, 1);
        err = std::string(label) + ".file must be a string";
        return false;
    }
    std::string path;
    if (!lua_string_without_nul(L, -1, path,
                                std::string(label) + ".file", err))
    {
        lua_pop(L, 1);
        return false;
    }
    lua_pop(L, 1);
    if (path.empty())
    {
        err = std::string(label) + ".file must not be empty";
        return false;
    }

    bool append = false;
    raw_getfield(L, idx, "append");
    if (!lua_isnil(L, -1))
    {
        if (lua_type(L, -1) != LUA_TBOOLEAN)
        {
            lua_pop(L, 1);
            err = std::string(label) + ".append must be a boolean";
            return false;
        }
        append = lua_toboolean(L, -1) != 0;
    }
    lua_pop(L, 1);

    mode_t permissions = 0600;
    raw_getfield(L, idx, "permissions");
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_integer(L, -1))
        {
            lua_pop(L, 1);
            err = std::string(label) +
                  ".permissions must be an integer between 0 and 0777";
            return false;
        }
        const lua_Integer value = lua_tointeger(L, -1);
        if (value < 0 || value > 0777)
        {
            lua_pop(L, 1);
            err = std::string(label) +
                  ".permissions must be between 0 and 0777";
            return false;
        }
        permissions = static_cast<mode_t>(value);
    }
    lua_pop(L, 1);

    out.kind = babet_process::StreamRedirectionKind::file;
    out.file.path = std::move(path);
    out.file.append = append;
    out.file.permissions = permissions;
    return true;
}

enum class StreamRole
{
    stdin_stream,
    stdout_stream,
    stderr_stream,
};

bool parse_stream_redirection(lua_State *L, int opts_idx,
                              const char *field, StreamRole role,
                              babet_process::StreamRedirection &out,
                              std::string &err)
{
    out = babet_process::StreamRedirection{};
    if (lua_is_none_or_nil(L, opts_idx))
    {
        return true;
    }

    raw_getfield(L, opts_idx, field);
    if (lua_isnil(L, -1))
    {
        lua_pop(L, 1);
        return true;
    }

    const std::string label = std::string("opts.") + field;
    if (lua_is_strict_string(L, -1))
    {
        size_t len = 0;
        const char *data = lua_tolstring(L, -1, &len);
        const std::string mode(data, len);
        lua_pop(L, 1);

        if (mode == "pipe")
        {
            out.kind = babet_process::StreamRedirectionKind::pipe;
            return true;
        }
        if (mode == "inherit")
        {
            out.kind = babet_process::StreamRedirectionKind::inherit;
            return true;
        }
        if (mode == "null")
        {
            out.kind = babet_process::StreamRedirectionKind::null_device;
            return true;
        }
        if (role == StreamRole::stderr_stream && mode == "stdout")
        {
            out.kind = babet_process::StreamRedirectionKind::stdout_stream;
            return true;
        }

        err = label + " has an invalid redirection mode";
        return false;
    }

    if (lua_type(L, -1) == LUA_TTABLE && role != StreamRole::stdin_stream)
    {
        const bool ok = parse_file_redirection(L, -1, label.c_str(),
                                               out, err);
        lua_pop(L, 1);
        return ok;
    }

    lua_pop(L, 1);
    if (role == StreamRole::stdin_stream)
    {
        err = label + " must be 'pipe', 'inherit', or 'null'";
    }
    else if (role == StreamRole::stderr_stream)
    {
        err = label +
              " must be 'pipe', 'inherit', 'null', 'stdout', or a file table";
    }
    else
    {
        err = label +
              " must be 'pipe', 'inherit', 'null', or a file table";
    }
    return false;
}

bool parse_timeout_value(lua_State *L, int idx, const char *label,
                         double default_value, bool allow_absent,
                         double &out, bool &present, std::string &err)
{
    if (lua_is_none_or_nil(L, idx))
    {
        if (!allow_absent && lua_isnil(L, idx))
        {
            err = std::string(label) + " must be a number";
            return false;
        }
        out = default_value;
        present = false;
        return true;
    }
    if (!lua_is_strict_number(L, idx))
    {
        err = std::string(label) + " must be a number";
        return false;
    }
    out = lua_tonumber(L, idx);
    if (!std::isfinite(out))
    {
        err = std::string(label) + " must be finite";
        return false;
    }
    if (out < 0)
    {
        err = std::string(label) + " must be greater than or equal to 0";
        return false;
    }
    if (out * 1000.0 > static_cast<double>(INT_MAX))
    {
        err = std::string(label) + " too large";
        return false;
    }
    present = true;
    return true;
}

bool parse_launch_timeout(lua_State *L, int opts_idx,
                          bool &has_timeout, long long &deadline,
                          std::string &err)
{
    has_timeout = false;
    deadline = 0;
    if (lua_is_none_or_nil(L, opts_idx))
    {
        return true;
    }

    raw_getfield(L, opts_idx, "launch_timeout");
    if (lua_isnil(L, -1))
    {
        lua_pop(L, 1);
        return true;
    }

    double timeout = 0.0;
    bool present = false;
    const bool ok = parse_timeout_value(L, -1, "opts.launch_timeout", 0.0,
                                        true, timeout, present, err);
    lua_pop(L, 1);
    if (!ok)
    {
        return false;
    }
    if (timeout <= 0)
    {
        err = "opts.launch_timeout must be greater than 0";
        return false;
    }
    has_timeout = true;
    deadline = babet_process::now_ms() +
               static_cast<long long>(timeout * 1000.0);
    return true;
}

int push_process_result(lua_State *L, const Process *process)
{
    const int code = babet_process::exit_code_from_status(
        process->status, process->status_valid);

    lua_newtable(L);
    lua_pushinteger(L, code);
    lua_setfield(L, -2, "code");

    const bool exited = process->status_valid && WIFEXITED(process->status);
    const bool signaled = process->status_valid && WIFSIGNALED(process->status);
    lua_pushboolean(L, exited ? 1 : 0);
    lua_setfield(L, -2, "exited");
    lua_pushboolean(L, signaled ? 1 : 0);
    lua_setfield(L, -2, "signaled");
    if (signaled)
    {
        lua_pushinteger(L, WTERMSIG(process->status));
        lua_setfield(L, -2, "signal");
    }
    lua_pushnil(L);
    return 2;
}

int push_process_result_protected(lua_State *L, const Process *process)
{
    auto builder = [process](lua_State *Ls) noexcept -> int
    {
        return push_process_result(Ls, process);
    };
    return lua_build_results_protected(L, builder, 2);
}

void restore_process_terminal(Process *process) noexcept
{
    if (process)
    {
        babet_process::restore_terminal(process->terminal);
    }
}

void reclaim_process_terminal(Process *process) noexcept
{
    if (process)
    {
        babet_process::reclaim_terminal(process->terminal);
    }
}

bool apply_wait_status(Process *process, int status)
{
    if (WIFEXITED(status) || WIFSIGNALED(status))
    {
        process->status = status;
        process->status_valid = true;
        process->stopped = false;
        babet_process::close_fd(process->stdin_fd);
        restore_process_terminal(process);
        return true;
    }
    if (WIFSTOPPED(status))
    {
        process->stopped = true;
        reclaim_process_terminal(process);
        return true;
    }
#ifdef WIFCONTINUED
    if (WIFCONTINUED(status))
    {
        process->stopped = false;
        return true;
    }
#endif
    return false;
}

bool refresh_status(Process *process, std::string &err)
{
    if (process->status_valid || process->pid <= 0)
    {
        return true;
    }

    for (;;)
    {
        int observed_status = 0;
        const pid_t r = ::waitpid(process->pid, &observed_status,
                                  WNOHANG | WUNTRACED | WCONTINUED);
        if (r == process->pid)
        {
            apply_wait_status(process, observed_status);
            if (process->status_valid || process->stopped)
            {
                return true;
            }
            continue;
        }
        if (r == 0)
        {
            return true;
        }
        if (errno == EINTR)
        {
            continue;
        }
        err = std::string("process: waitpid failed: ") +
              std::strerror(errno);
        return false;
    }
}

int wait_fd(lua_State *L, int fd, short events, double timeout)
{
    const bool finite_timeout = timeout >= 0.0;
    const long long deadline = finite_timeout
                                   ? babet_process::now_ms() +
                                         static_cast<long long>(
                                             std::ceil(timeout * 1000.0))
                                   : 0;

    struct pollfd pfd{};
    pfd.fd = fd;
    pfd.events = events;
    for (;;)
    {
        if (signal_any_handled_pending())
        {
            signal_dispatch_pending(L);
            return -2;
        }

        int poll_timeout = -1;
        if (finite_timeout)
        {
            const long long remaining = deadline - babet_process::now_ms();
            poll_timeout = remaining <= 0
                               ? 0
                               : (remaining > INT_MAX
                                      ? INT_MAX
                                      : static_cast<int>(remaining));
        }

        pfd.revents = 0;
        const int r = ::poll(&pfd, 1, poll_timeout);
        if (r >= 0)
        {
            if (r > 0 && (pfd.revents & POLLNVAL))
            {
                errno = EBADF;
                return -1;
            }
            return r;
        }
        if (errno == EINTR)
        {
            if (signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                return -2;
            }
            continue;
        }
        return -1;
    }
}

int process_read_stream(lua_State *L, int Process::*fd_member,
                        bool Process::*piped_member,
                        const char *method_name)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 3))
    {
        return luaL_error(L, "%s expects optional max_bytes and timeout",
                          method_name);
    }
    Process *process = check_process(L, 1);

    size_t max_bytes = DEFAULT_READ_SIZE;
    if (argc >= 2 && !lua_isnil(L, 2))
    {
        if (!lua_is_strict_integer(L, 2))
        {
            return luaL_error(L, "%s: max_bytes must be an integer",
                              method_name);
        }
        const lua_Integer value = lua_tointeger(L, 2);
        if (value <= 0 ||
            static_cast<unsigned long long>(value) > MAX_READ_SIZE)
        {
            return luaL_error(L,
                              "%s: max_bytes must be between 1 and %zu",
                              method_name, MAX_READ_SIZE);
        }
        max_bytes = static_cast<size_t>(value);
    }

    double timeout = 0.0;
    bool timeout_present = false;
    {
        std::string parse_error;
        if (argc >= 3 &&
            !parse_timeout_value(L, 3, "timeout", 0.0, false,
                                 timeout, timeout_present, parse_error))
        {
            std::string full = method_name;
            full += ": ";
            full += parse_error;
            return push_fail_protected(L, full);
        }
    }

    if (!(process->*piped_member))
    {
        return push_fail_protected(L, "not_piped");
    }

    int &fd = process->*fd_member;
    if (fd < 0)
    {
        return push_fail_protected(L, "closed");
    }

    const int ready = wait_fd(L, fd, POLLIN, timeout);
    if (ready == -2)
    {
        return push_fail_protected(L, "interrupted");
    }
    if (ready < 0)
    {
        const std::string error = std::string("process: poll failed: ") +
                                  std::strerror(errno);
        return push_fail_protected(L, error);
    }
    if (ready == 0)
    {
        return push_fail_protected(L, "timeout");
    }

    // Le tampon temporaire vit dans un userdata Lua : si lua_pushlstring()
    // déclenche une erreur d'allocation (longjmp), aucune allocation C++
    // nécessitant un destructeur n'est abandonnée.
    void *raw_buffer = lua_newuserdatauv(L, max_bytes, 0);
    auto *buffer = static_cast<char *>(raw_buffer);
    for (;;)
    {
        const ssize_t n = ::read(fd, buffer, max_bytes);
        if (n > 0)
        {
            lua_pushlstring(L, buffer, static_cast<size_t>(n));
            lua_remove(L, -2); // retire le userdata tampon
            lua_pushnil(L);
            return 2;
        }
        if (n == 0)
        {
            babet_process::close_fd(fd);
            lua_pop(L, 1); // userdata tampon
            return push_fail_protected(L, "closed");
        }
        if (errno == EINTR)
        {
            if (signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                lua_pop(L, 1); // userdata tampon
                return push_fail_protected(L, "interrupted");
            }
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
        {
            lua_pop(L, 1); // userdata tampon
            return push_fail_protected(L, "timeout");
        }
        const std::string error = std::string("process: read failed: ") +
                                  std::strerror(errno);
        lua_pop(L, 1); // userdata tampon
        return push_fail_protected(L, error);
    }
}

int process_read_stdout(lua_State *L)
{
    return process_read_stream(L, &Process::stdout_fd,
                               &Process::stdout_piped,
                               "process.read_stdout");
}

int process_read_stderr(lua_State *L)
{
    return process_read_stream(L, &Process::stderr_fd,
                               &Process::stderr_piped,
                               "process.read_stderr");
}

int process_write(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 2, 3))
    {
        return luaL_error(L, "process.write expects data and optional timeout");
    }
    Process *process = check_process(L, 1);
    luaL_checktype(L, 2, LUA_TSTRING);

    double timeout = 0.0;
    bool timeout_present = false;
    {
        std::string parse_error;
        if (argc == 3 &&
            !parse_timeout_value(L, 3, "timeout", 0.0, false,
                                 timeout, timeout_present, parse_error))
        {
            return push_fail_protected(
                L, std::string("process.write: ") + parse_error);
        }
    }

    if (!process->stdin_piped)
    {
        return push_fail_protected(L, "not_piped");
    }
    if (process->stdin_fd < 0)
    {
        return push_fail_protected(L, "closed");
    }

    size_t length = 0;
    const char *data = lua_tolstring(L, 2, &length);
    if (length == 0)
    {
        lua_pushinteger(L, 0);
        lua_pushnil(L);
        return 2;
    }

    const int ready = wait_fd(L, process->stdin_fd, POLLOUT, timeout);
    if (ready == -2)
    {
        return push_fail_protected(L, "interrupted");
    }
    if (ready < 0)
    {
        const std::string error = std::string("process: poll failed: ") +
                                  std::strerror(errno);
        return push_fail_protected(L, error);
    }
    if (ready == 0)
    {
        return push_fail_protected(L, "timeout");
    }

    for (;;)
    {
        const size_t write_size = std::min(
            length,
            static_cast<size_t>(std::numeric_limits<ssize_t>::max()));
        const ssize_t n = babet_process::write_without_sigpipe(
            process->stdin_fd, data, write_size);
        if (n >= 0)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(n));
            lua_pushnil(L);
            return 2;
        }
        if (errno == EINTR)
        {
            if (signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                return push_fail_protected(L, "interrupted");
            }
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
        {
            return push_fail_protected(L, "timeout");
        }
        if (errno == EPIPE)
        {
            babet_process::close_fd(process->stdin_fd);
            return push_fail_protected(L, "closed");
        }
        const std::string error = std::string("process: write failed: ") +
                                  std::strerror(errno);
        return push_fail_protected(L, error);
    }
}

int process_close_stdin(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "process.close_stdin expects no argument");
    }
    Process *process = check_process(L, 1);
    if (!process->stdin_piped)
    {
        return push_fail_protected(L, "not_piped");
    }
    babet_process::close_fd(process->stdin_fd);
    return push_ok_protected(L);
}

int process_pid(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "process.pid expects no argument");
    }
    const Process *process = check_process(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(process->pid));
    return 1;
}

int process_is_running(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "process.is_running expects no argument");
    }
    Process *process = check_process(L, 1);
    if (process->closed)
    {
        lua_pushboolean(L, 0);
        return 1;
    }
    std::string error;
    if (!refresh_status(process, error))
    {
        return push_fail_protected(L, error);
    }
    lua_pushboolean(L, process->status_valid ? 0 : 1);
    return 1;
}

int process_state(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "process.state expects no argument");
    }
    Process *process = check_process(L, 1);
    if (process->closed)
    {
        return push_string_protected(L, "closed");
    }

    std::string_view state = "running";
    {
        std::string error;
        if (!refresh_status(process, error))
        {
            return push_fail_protected(L, error);
        }
        if (process->status_valid)
        {
            state = "exited";
        }
        else if (process->stopped)
        {
            state = "stopped";
        }
    }
    return push_string_protected(L, state);
}

int wait_for_process(lua_State *L, Process *process,
                     bool has_timeout, double timeout)
{
    std::string refresh_error;
    if (!refresh_status(process, refresh_error))
    {
        return push_fail_protected(L, refresh_error);
    }
    if (process->status_valid)
    {
        return push_process_result_protected(L, process);
    }
    if (process->closed)
    {
        return push_fail_protected(L, "closed");
    }
    if (process->stopped)
    {
        return push_fail_protected(L, "stopped");
    }

    const long long deadline = has_timeout
                                   ? babet_process::now_ms() +
                                         static_cast<long long>(
                                             timeout * 1000.0)
                                   : 0;

    for (;;)
    {
        if (signal_any_handled_pending())
        {
            signal_dispatch_pending(L);
            return push_fail_protected(L, "interrupted");
        }
        int observed_status = 0;
        int wait_options = WUNTRACED | WCONTINUED;
        if (has_timeout)
        {
            wait_options |= WNOHANG;
        }
        const pid_t r = ::waitpid(process->pid, &observed_status,
                                  wait_options);
        if (r == process->pid)
        {
            apply_wait_status(process, observed_status);
            if (process->status_valid)
            {
                return push_process_result_protected(L, process);
            }
            if (process->stopped)
            {
                return push_fail_protected(L, "stopped");
            }
            continue;
        }
        if (r < 0)
        {
            if (errno == EINTR)
            {
                if (signal_any_handled_pending())
                {
                    signal_dispatch_pending(L);
                    return push_fail_protected(L, "interrupted");
                }
                continue;
            }
            const std::string error = std::string("process: waitpid failed: ") +
                                      std::strerror(errno);
            return push_fail_protected(L, error);
        }

        if (signal_any_handled_pending())
        {
            signal_dispatch_pending(L);
            return push_fail_protected(L, "interrupted");
        }
        if (has_timeout && babet_process::now_ms() >= deadline)
        {
            return push_fail_protected(L, "timeout");
        }
        struct timespec pause{0, 10 * 1000 * 1000};
        while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
        {
            if (signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                return push_fail_protected(L, "interrupted");
            }
        }
    }
}

int process_wait(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L, "process.wait expects an optional timeout");
    }
    Process *process = check_process(L, 1);

    double timeout = 0.0;
    bool has_timeout = false;
    std::string error;
    if (argc == 2 &&
        !parse_timeout_value(L, 2, "timeout", 0.0, false,
                             timeout, has_timeout, error))
    {
        return push_fail_protected(L, std::string("process.wait: ") + error);
    }
    return wait_for_process(L, process, has_timeout, timeout);
}

bool signal_process_group_checked(pid_t pid, int signal) noexcept
{
    if (pid <= 0)
    {
        errno = ESRCH;
        return false;
    }
    if (::kill(-pid, signal) == 0)
    {
        return true;
    }
    const int group_errno = errno;
    if (group_errno == ESRCH && ::kill(pid, signal) == 0)
    {
        return true;
    }
    errno = group_errno;
    return false;
}

int process_resume(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L,
                          "process.resume expects an optional foreground boolean");
    }
    Process *process = check_process(L, 1);

    bool foreground = process->terminal.fd >= 0;
    if (argc == 2 && !lua_isnil(L, 2))
    {
        if (!lua_is_strict_boolean(L, 2))
        {
            return luaL_error(L,
                              "process.resume: foreground must be a boolean");
        }
        foreground = lua_toboolean(L, 2) != 0;
    }

    if (process->closed)
    {
        return push_fail_protected(L, "closed");
    }
    std::string error;
    if (!refresh_status(process, error))
    {
        return push_fail_protected(L, error);
    }
    if (process->status_valid)
    {
        return push_fail_protected(L, "exited");
    }
    if (!process->stopped)
    {
        return push_fail_protected(L, "not_stopped");
    }
    if (foreground && process->terminal.fd < 0)
    {
        return push_fail_protected(L, "not_interactive");
    }

    if (foreground &&
        !babet_process::foreground_terminal(process->terminal, process->pid))
    {
        const std::string terminal_error =
            std::string("process: cannot foreground child: ") +
            std::strerror(errno);
        return push_fail_protected(L, terminal_error);
    }

    if (!signal_process_group_checked(process->pid, SIGCONT))
    {
        const int signal_errno = errno;
        if (foreground)
        {
            reclaim_process_terminal(process);
        }
        const std::string signal_error =
            std::string("process: cannot continue child: ") +
            std::strerror(signal_errno);
        return push_fail_protected(L, signal_error);
    }

    process->stopped = false;
    return push_ok_protected(L);
}

int terminate_process(lua_State *L, Process *process, int signal,
                      double grace_seconds)
{
    std::string error;
    if (!refresh_status(process, error))
    {
        return push_fail_protected(L, error);
    }
    if (process->status_valid)
    {
        return push_process_result_protected(L, process);
    }
    if (process->closed)
    {
        return push_fail_protected(L, "closed");
    }

    babet_process::kill_group(process->pid, signal);
    if (process->stopped && signal != SIGKILL)
    {
        babet_process::kill_group(process->pid, SIGCONT);
        process->stopped = false;
    }
    babet_process::ChildWaitResult result =
        babet_process::wait_child_until(
            process->pid, process->status,
            babet_process::now_ms() +
                static_cast<long long>(grace_seconds * 1000.0));

    if (result == babet_process::ChildWaitResult::timed_out &&
        signal != SIGKILL)
    {
        babet_process::kill_group(process->pid, SIGKILL);
        result = babet_process::wait_child_until(
            process->pid, process->status,
            babet_process::now_ms() + 2000);
    }
    if (result == babet_process::ChildWaitResult::error)
    {
        const std::string wait_error =
            std::string("process: waitpid failed: ") + std::strerror(errno);
        return push_fail_protected(L, wait_error);
    }
    if (result != babet_process::ChildWaitResult::reaped)
    {
        return push_fail_protected(L, "process: child could not be reaped");
    }

    process->status_valid = true;
    babet_process::close_fd(process->stdin_fd);
    restore_process_terminal(process);
    return push_process_result_protected(L, process);
}

int process_terminate(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L,
                          "process.terminate expects an optional grace period");
    }
    Process *process = check_process(L, 1);

    double grace = DEFAULT_TERMINATE_GRACE;
    bool present = false;
    std::string error;
    if (argc == 2 &&
        !parse_timeout_value(L, 2, "grace_period",
                             DEFAULT_TERMINATE_GRACE, false,
                             grace, present, error))
    {
        return push_fail_protected(
            L, std::string("process.terminate: ") + error);
    }
    return terminate_process(L, process, SIGTERM, grace);
}

int process_kill(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "process.kill expects no argument");
    }
    Process *process = check_process(L, 1);
    return terminate_process(L, process, SIGKILL, 2.0);
}

void cleanup_process(Process *process) noexcept
{
    if (!process || process->closed)
    {
        return;
    }

    if (!process->status_valid && process->pid > 0)
    {
        for (;;)
        {
            const pid_t result = ::waitpid(process->pid, &process->status,
                                           WNOHANG);
            if (result == process->pid)
            {
                process->status_valid = true;
                break;
            }
            if (result == 0)
            {
                break;
            }
            if (result < 0 && errno == EINTR)
            {
                continue;
            }
            break;
        }
    }
    if (!process->status_valid && process->pid > 0)
    {
        process->status_valid =
            babet_process::terminate_and_reap(process->pid, process->status);
    }

    restore_process_terminal(process);
    babet_process::close_fd(process->stdin_fd);
    babet_process::close_fd(process->stdout_fd);
    babet_process::close_fd(process->stderr_fd);
    process->closed = true;
}

int process_close(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "process.close expects no argument");
    }
    Process *process = check_process(L, 1);
    cleanup_process(process);
    return push_ok_protected(L);
}

int process_gc(lua_State *L)
{
    Process *process = static_cast<Process *>(
        luaL_testudata(L, 1, PROCESS_META));
    cleanup_process(process);
    return 0;
}

int process_gc_boundary(lua_State *L) noexcept
{
    try
    {
        return process_gc(L);
    }
    catch (...)
    {
        return 0;
    }
}

int process_tostring(lua_State *L)
{
    Process *process = check_process(L, 1);
    const char *state = process->closed
                            ? "closed"
                            : (process->status_valid
                                   ? "exited"
                                   : (process->stopped ? "stopped" : "running"));
    lua_pushfstring(L, "babet.process(pid=%d, %s)",
                    static_cast<int>(process->pid), state);
    return 1;
}

int lua_spawn_impl(lua_State *L)
{
    if (!lua_arity_between(L, 1, 3))
    {
        return luaL_error(L, "spawn expects command, optional args and opts");
    }
    if (!lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "spawn: command must be a string");
    }

    std::string error;
    std::string command;
    if (!lua_string_without_nul(L, 1, command, "command", error))
    {
        return push_fail_protected(L, error);
    }

    std::vector<std::string> args;
    if (!babet_process::collect_args(L, 2, command, args, error))
    {
        return push_fail_protected(L, error);
    }

    if (!validate_spawn_opts_keys(L, 3, error))
    {
        return push_fail_protected(L, error);
    }

    std::string cwd;
    bool has_cwd = false;
    std::vector<std::pair<std::string, std::string>> env;
    if (!babet_process::collect_cwd_env(L, 3, cwd, has_cwd, env, error))
    {
        return push_fail_protected(L, error);
    }

    bool has_launch_timeout = false;
    long long launch_deadline = 0;
    if (!parse_launch_timeout(L, 3, has_launch_timeout,
                              launch_deadline, error))
    {
        return push_fail_protected(L, error);
    }

    babet_process::StreamRedirection stdin_redirection;
    babet_process::StreamRedirection stdout_redirection;
    babet_process::StreamRedirection stderr_redirection;
    if (!parse_stream_redirection(L, 3, "stdin", StreamRole::stdin_stream,
                                  stdin_redirection, error) ||
        !parse_stream_redirection(L, 3, "stdout", StreamRole::stdout_stream,
                                  stdout_redirection, error) ||
        !parse_stream_redirection(L, 3, "stderr", StreamRole::stderr_stream,
                                  stderr_redirection, error))
    {
        return push_fail_protected(L, error);
    }

    babet_process::LaunchSpec spec;
    spec.command = command;
    spec.argv_strings = std::move(args);
    spec.cwd = std::move(cwd);
    spec.has_cwd = has_cwd;
    spec.env_overrides = std::move(env);
    spec.has_deadline = has_launch_timeout;
    spec.deadline_ms = launch_deadline;
    spec.stdin_redirection = std::move(stdin_redirection);
    spec.stdout_redirection = std::move(stdout_redirection);
    spec.stderr_redirection = std::move(stderr_redirection);
    spec.error_prefix = "spawn";

    // Alloue le userdata AVANT fork(). Une panne d'allocation Lua ne peut
    // ainsi pas abandonner un processus enfant déjà lancé. Le userdata est
    // initialisé fermé jusqu'au succès complet de launch().
    auto builder = [](lua_State *Ls) noexcept -> int
    {
        push_empty_process(Ls);
        return 1;
    };
    lua_build_results_protected(L, builder, 1);
    Process *process = static_cast<Process *>(lua_touserdata(L, -1));

    babet_process::LaunchResult launched = babet_process::launch(spec);
    if (!launched.success)
    {
        lua_pop(L, 1); // userdata vide, aucune ressource à nettoyer
        if (launched.timed_out)
        {
            return push_fail_protected(L, "spawn: launch timed out");
        }
        return push_fail_protected(L, launched.error);
    }

    initialize_process(process, launched.process);
    lua_pushnil(L);
    return 2;
}

template <int (*Fn)(lua_State *)>
int process_lua_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "process: out of memory", "process: internal C++ failure",
        "process: unknown internal C++ failure");
}

int lua_spawn(lua_State *L)
{
    return process_lua_boundary<lua_spawn_impl>(L);
}

void register_process_metatable(lua_State *L)
{
    if (luaL_newmetatable(L, PROCESS_META))
    {
        lua_pushcfunction(L, process_gc_boundary);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, process_gc_boundary);
        lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, process_lua_boundary<process_tostring>);
        lua_setfield(L, -2, "__tostring");

        lua_newtable(L);
        lua_pushcfunction(L, process_lua_boundary<process_read_stdout>);
        lua_setfield(L, -2, "read_stdout");
        lua_pushcfunction(L, process_lua_boundary<process_read_stderr>);
        lua_setfield(L, -2, "read_stderr");
        lua_pushcfunction(L, process_lua_boundary<process_write>);
        lua_setfield(L, -2, "write");
        lua_pushcfunction(L, process_lua_boundary<process_close_stdin>);
        lua_setfield(L, -2, "close_stdin");
        lua_pushcfunction(L, process_lua_boundary<process_is_running>);
        lua_setfield(L, -2, "is_running");
        lua_pushcfunction(L, process_lua_boundary<process_state>);
        lua_setfield(L, -2, "state");
        lua_pushcfunction(L, process_lua_boundary<process_pid>);
        lua_setfield(L, -2, "pid");
        lua_pushcfunction(L, process_lua_boundary<process_wait>);
        lua_setfield(L, -2, "wait");
        lua_pushcfunction(L, process_lua_boundary<process_resume>);
        lua_setfield(L, -2, "resume");
        lua_pushcfunction(L, process_lua_boundary<process_terminate>);
        lua_setfield(L, -2, "terminate");
        lua_pushcfunction(L, process_lua_boundary<process_kill>);
        lua_setfield(L, -2, "kill");
        lua_pushcfunction(L, process_lua_boundary<process_close>);
        lua_setfield(L, -2, "close");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

} // namespace

void register_process(lua_State *L)
{
    register_process_metatable(L);
    lua_pushcfunction(L, lua_spawn);
    lua_setfield(L, -2, "spawn");
}
