#include "lua_bindings/worker_process.hpp"
#include <lua.hpp>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

static int fault = 0;
static const char *shell_override = nullptr;
extern "C" {
int __real_pipe2(int *, int);
FILE *__real_fdopen(int, const char *);
int __real_posix_spawn_file_actions_init(posix_spawn_file_actions_t *);
int __real_posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *, int, int);
int __real_posix_spawnattr_init(posix_spawnattr_t *);
int __real_posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *,
                      const posix_spawnattr_t *, char *const[], char *const[]);
int __wrap_pipe2(int *p, int flags)
{ if (fault == 1) { errno = EMFILE; return -1; } return __real_pipe2(p, flags); }
FILE *__wrap_fdopen(int fd, const char *mode)
{ if (fault == 2) { errno = ENOMEM; return nullptr; } return __real_fdopen(fd, mode); }
int __wrap_posix_spawn_file_actions_init(posix_spawn_file_actions_t *a)
{ return fault == 3 ? ENOMEM : __real_posix_spawn_file_actions_init(a); }
int __wrap_posix_spawnattr_init(posix_spawnattr_t *a)
{ return fault == 4 ? ENOMEM : __real_posix_spawnattr_init(a); }
int __wrap_posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *a, int f, int t)
{ return fault == 7 ? EBADF : __real_posix_spawn_file_actions_adddup2(a, f, t); }
int __wrap_posix_spawn(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *a, const posix_spawnattr_t *attr,
    char *const argv[], char *const env[])
{
    if (fault == 5) return EAGAIN;
    if (fault == 6) return ENOENT;
    return __real_posix_spawn(pid, shell_override ? shell_override : path,
                              a, attr, argv, env);
}
}

static int fd_count()
{
    DIR *d = ::opendir("/proc/self/fd");
    if (!d) std::abort();
    int n = 0;
    while (const dirent *e = ::readdir(d)) if (e->d_name[0] != '.') ++n;
    ::closedir(d);
    return n;
}

struct Allocator { bool armed = false; bool failed = false; int remaining = 0; size_t live = 0; };
static void *allocate(void *ud, void *ptr, size_t old, size_t size)
{
    auto &a = *static_cast<Allocator *>(ud);
    if (!ptr) old = 0;
    if (size == 0) { a.live -= old; std::free(ptr); return nullptr; }
    if (a.armed && size > old && a.remaining-- <= 0)
    { a.failed = true; return nullptr; }
    void *result = std::realloc(ptr, size);
    if (result) a.live = a.live - old + size;
    return result;
}

static lua_State *new_state(Allocator &allocator, const char *self)
{
    lua_State *L = lua_newstate(allocate, &allocator, 0);
    if (!L) std::abort();
    luaL_openlibs(L);
    const int top = lua_gettop(L);
    register_worker_process_functions(L);
    if (lua_gettop(L) != top) std::abort();
    lua_pushstring(L, self); lua_setglobal(L, "probe");
    return L;
}

static void no_leaks(Allocator &a, int before)
{
    if (a.live != 0 || fd_count() != before) std::abort();
    int status;
    errno = 0;
    if (::waitpid(-1, &status, WNOHANG) != -1 || errno != ECHILD) std::abort();
}

int main(int argc, char **argv)
{
    if (argc == 2 && std::strcmp(argv[1], "--input") == 0)
    {
        char buffer[4];
        return std::fread(buffer,1,4,stdin)==4 && std::memcmp(buffer,"DATA",4)==0 ? 0 : 1;
    }
    if (argc == 2 && std::strcmp(argv[1], "--mask") == 0)
    {
        sigset_t mask; ::sigprocmask(SIG_SETMASK, nullptr, &mask);
        for (int sig : {SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGUSR1, SIGUSR2, SIGPIPE})
            if (::sigismember(&mask, sig) != 0) return 23;
        std::puts("MASK_CLEAR"); return 0;
    }
    sigset_t mask, previous;
    ::sigemptyset(&mask);
    for (int sig : {SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGUSR1, SIGUSR2, SIGPIPE})
        ::sigaddset(&mask, sig);
    if (::sigprocmask(SIG_BLOCK, &mask, &previous) != 0) return 1;
    if (argc == 3 && std::strcmp(argv[1], "--closed") == 0)
    {
        const int bits = std::atoi(argv[2]);
        for (int fd = 0; fd < 3; ++fd) if (bits & (1 << fd)) (void)::close(fd);
        const int descriptors = fd_count();
        Allocator a; lua_State *L = new_state(a, argv[0]);
        const int status = luaL_dostring(L, R"LUA(
            local function q(s) return "'"..s:gsub("'", "'\\''").."'" end
            local f=assert(io.popen('printf xyz'));assert(f:read('*a')=='xyz');assert(f:close())
            f=assert(io.popen('exec '..q(probe)..' --input','w'));assert(f:write('DATA'));assert(f:close())
        )LUA");
        lua_close(L); no_leaks(a, descriptors);
        return status == LUA_OK ? 0 : 1;
    }
    const int before = fd_count();
    int count = 0;
    const char *contract = R"LUA(
        local function q(s) return "'"..s:gsub("'", "'\\''").."'" end
        local cmd='exec '..q(probe)..' --mask'
        assert(os.execute()==true)
        local a,b,c=os.execute(cmd); assert(a==true and b=='exit' and c==0)
        local f=assert(io.popen(cmd)); assert(io.type(f)=='file')
        assert(f:read('*a')=='MASK_CLEAR\n'); a,b,c=f:close()
        assert(a==true and b=='exit' and c==0 and io.type(f)=='closed file')
        assert(not pcall(f.close,f))
        a,b,c=os.execute('exit 17');assert(a==nil and b=='exit' and c==17)
        a,b,c=os.execute('babet_nonexistent_command_xyz 2>/dev/null');assert(a==nil and b=='exit' and c==127)
        a,b,c=os.execute('kill -TERM $$');assert(a==nil and b=='signal' and c==15)
        f=assert(io.popen('exit 19'));a,b,c=f:close();assert(a==nil and b=='exit' and c==19)
        f=assert(io.popen('kill -TERM $$'));a,b,c=f:close();assert(a==nil and b=='signal' and c==15)
        f=assert(io.popen('cat >/dev/null','w'));assert(f:write('hello'));assert(f:close())
        do local f <close> = assert(io.popen('printf abc'));assert(f:read('*a')=='abc') end
        for _, mode in ipairs({'','rw','rb','x'}) do assert(not pcall(io.popen,'true',mode)) end
        assert(not pcall(os.execute,{}));assert(not pcall(io.popen,{}))
    )LUA";
    for (const char *shell : {static_cast<const char *>(nullptr), "/bin/bash"})
    {
        if (shell && ::access(shell, X_OK) != 0) continue;
        shell_override = shell;
        Allocator a; lua_State *L = new_state(a, argv[0]);
        if (luaL_dostring(L, contract) != LUA_OK)
        { std::fprintf(stderr, "[FAIL] %s\n", lua_tostring(L,-1)); return 1; }
        lua_close(L); no_leaks(a, before); ++count;
        std::printf("[PASS] standard contracts and clear child masks via %s\n", shell ? shell : "/bin/sh");
    }
    shell_override = nullptr;
    for (int bits = 1; bits < 8; ++bits)
    {
        char value[2] = {static_cast<char>('0' + bits), '\0'};
        char *args[] = {argv[0], const_cast<char *>("--closed"), value, nullptr};
        pid_t pid;
        extern char **environ;
        if (::posix_spawn(&pid, argv[0], nullptr, nullptr, args, environ) != 0) return 1;
        int status = 0;
        if (::waitpid(pid, &status, 0) != pid || status != 0) return 1;
        ++count;
    }
    for (int i = 1; i <= 7; ++i)
    {
        Allocator a; lua_State *L = new_state(a, argv[0]); fault = i;
        const char *code = "local f,e,n=io.popen('exit 0'); assert(f==nil and type(e)=='string' and type(n)=='number')";
        const int status = luaL_dostring(L, code); fault = 0;
        if (status != LUA_OK) { std::fprintf(stderr,"[FAIL] fault %d: %s\n",i,lua_tostring(L,-1)); return 1; }
        lua_close(L); no_leaks(a, before); ++count;
    }
    for (int i : {4, 5, 6})
    {
        Allocator a; lua_State *L = new_state(a, argv[0]); fault = i;
        const char *code = "local a,b,c=os.execute('true'); assert(a==nil and type(b)=='string' and type(c)=='number'); assert(os.execute()==false)";
        const int status = luaL_dostring(L, code); fault = 0;
        if (status != LUA_OK) { std::fprintf(stderr,"[FAIL] execute fault %d: %s\n",i,lua_tostring(L,-1)); return 1; }
        lua_close(L); no_leaks(a, before); ++count;
    }
    int oom = 0;
    for (int scenario : {0, 1, 5})
    {
        bool done = false;
        for (int n = 0; n < 100; ++n)
        {
            Allocator a; lua_State *L = new_state(a, argv[0]);
            if (luaL_loadstring(L, "local f=assert(io.popen('printf hello')); return f:read('*a')") != LUA_OK) return 1;
            a.remaining = n; a.armed = true; fault = scenario;
            const int status = lua_pcall(L, 0, LUA_MULTRET, 0);
            fault = 0; a.armed = false;
            if (a.failed && status != LUA_ERRMEM) return 1;
            if (!a.failed && ((scenario == 0) != (status == LUA_OK))) return 1;
            lua_close(L); no_leaks(a, before);
            if (!a.failed) { done = true; break; }
            ++oom;
        }
        if (!done) return 1;
    }
    sigset_t after; ::sigprocmask(SIG_SETMASK,nullptr,&after);
    for (int sig : {SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGUSR1, SIGUSR2, SIGPIPE})
        if (::sigismember(&after,sig) != 1) return 1;
    (void)::sigprocmask(SIG_SETMASK,&previous,nullptr);
    std::printf("Worker process native tests: %d PASS; %d OOM points; no Lua/FD/child leaks\n",count,oom);
    return 0;
}
