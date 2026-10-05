#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "worker_process.hpp"
#include "lua_utils.hpp"

#include <lua.hpp>
#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <fcntl.h>
#include <new>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace
{
// No process-wide signal disposition changes: libc system() temporarily
// ignores INT/QUIT for *every* thread, including the main Lua state. Only the
// child's signal mask is reset here. exec preserves deliberate SIG_IGN policy
// and resets caught handlers as usual. Worker mask and dispositions stay put.
int spawn_shell(const char *command, const posix_spawn_file_actions_t *actions,
                pid_t &pid) noexcept
{
    posix_spawnattr_t attributes;
    int error = ::posix_spawnattr_init(&attributes);
    if (error != 0) return error;
    sigset_t mask;
    ::sigemptyset(&mask);
    error = ::posix_spawnattr_setsigmask(&attributes, &mask);
    if (error == 0)
        error = ::posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK);
    if (error == 0)
    {
        char *arguments[] = {const_cast<char *>("sh"), const_cast<char *>("-c"),
                             const_cast<char *>(command), nullptr};
        error = ::posix_spawn(&pid, "/bin/sh", actions, &attributes,
                              arguments, environ);
    }
    (void)::posix_spawnattr_destroy(&attributes);
    return error;
}

int wait_child(pid_t pid, int &status) noexcept
{
    pid_t result;
    do { result = ::waitpid(pid, &status, 0); }
    while (result < 0 && errno == EINTR);
    return result < 0 ? errno : 0;
}

int lua_worker_os_execute(lua_State *L)
{
    const char *command = luaL_optstring(L, 1, nullptr);
    pid_t pid = -1;
    int status = 0;
    int error = spawn_shell(command ? command : "exit 0", nullptr, pid);
    if (error == 0) error = wait_child(pid, status);
    if (command == nullptr)
    {
        lua_pushboolean(L, error == 0 && status == 0);
        return 1;
    }
    errno = error;
    return luaL_execresult(L, error == 0 ? status : -1);
}

// Lua's io implementation reads this exact prefix. The extra child identity
// belongs to the Lua userdata, so allocation errors never strand a FILE/pid
// in an automatic C++ owner skipped by Lua's longjmp.
struct WorkerPipe
{
    luaL_Stream stream{nullptr, nullptr};
    pid_t pid = -1;
};
static_assert(offsetof(WorkerPipe, stream) == 0);

int lua_worker_pipe_close(lua_State *L)
{
    auto *pipe = static_cast<WorkerPipe *>(luaL_checkudata(L, 1, LUA_FILEHANDLE));
    // Lua's aux_close already clears closef, making all close paths idempotent.
    FILE *file = pipe->stream.f;
    const pid_t pid = pipe->pid;
    pipe->stream.f = nullptr;
    pipe->pid = -1;
    errno = 0;
    const int close_error = std::fclose(file) == 0 ? 0 : (errno ? errno : EIO);
    int status = 0;
    const int wait_error = wait_child(pid, status);
    const int error = wait_error != 0 ? wait_error : close_error;
    errno = error;
    return luaL_execresult(L, error == 0 ? status : -1);
}

int open_pipe(const char *command, const char *mode, WorkerPipe &pipe) noexcept
{
    int descriptors[2];
    if (::pipe2(descriptors, O_CLOEXEC) != 0) return errno;
    const bool reading = mode[0] == 'r';
    const int parent = descriptors[reading ? 0 : 1];
    const int child = descriptors[reading ? 1 : 0];
    const int target = reading ? STDOUT_FILENO : STDIN_FILENO;

    FILE *file = ::fdopen(parent, mode);
    if (!file)
    {
        const int error = errno;
        (void)::close(parent);
        (void)::close(child);
        return error;
    }

    posix_spawn_file_actions_t actions;
    int error = ::posix_spawn_file_actions_init(&actions);
    if (error == 0)
    {
        // Close the parent's end first: it can equal target if stdin/stdout
        // were closed before pipe2. adddup2 also clears CLOEXEC when child ==
        // target (unlike a plain dup2), preserving that alias case.
        error = ::posix_spawn_file_actions_addclose(&actions, parent);
        if (error == 0)
            error = ::posix_spawn_file_actions_adddup2(&actions, child, target);
        if (error == 0 && child != target)
            error = ::posix_spawn_file_actions_addclose(&actions, child);
        if (error == 0) error = spawn_shell(command, &actions, pipe.pid);
        (void)::posix_spawn_file_actions_destroy(&actions);
    }
    (void)::close(child);
    if (error != 0)
    {
        (void)std::fclose(file);
        return error;
    }
    // The parent keeps CLOEXEC, so later/concurrent commands cannot retain
    // another popen's pipe and delay EOF. No global popen descriptor list.
    pipe.stream.f = file;
    pipe.stream.closef = lua_worker_pipe_close;
    return 0;
}

int lua_worker_io_popen(lua_State *L)
{
    const char *command = luaL_checkstring(L, 1);
    const char *mode = luaL_optstring(L, 2, "r");
    luaL_argcheck(L, (mode[0] == 'r' || mode[0] == 'w') && mode[1] == '\0',
                  2, "invalid mode");
    auto *pipe = new (lua_newuserdatauv(L, sizeof(WorkerPipe), 0)) WorkerPipe;
    luaL_setmetatable(L, LUA_FILEHANDLE);
    (void)std::fflush(nullptr); // Lua's POSIX io.popen flushes before launch.
    const int error = open_pipe(command, mode, *pipe);
    if (error == 0) return 1;
    errno = error;
    return luaL_fileresult(L, 0, command);
}

template <int (*Fn)(lua_State *)>
int worker_process_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "worker process: out of memory", "worker process: internal failure",
        "worker process: unknown internal failure");
}
}

void register_worker_process_functions(lua_State *L)
{
    lua_getglobal(L, "os");
    lua_pushcfunction(L, worker_process_boundary<lua_worker_os_execute>);
    lua_setfield(L, -2, "execute");
    lua_pop(L, 1);
    lua_getglobal(L, "io");
    lua_pushcfunction(L, worker_process_boundary<lua_worker_io_popen>);
    lua_setfield(L, -2, "popen");
    lua_pop(L, 1);
}
