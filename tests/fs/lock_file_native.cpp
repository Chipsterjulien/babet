#include "lua_bindings/lockFile.hpp"
#include <lua.hpp>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

// Linker wrappers affect only this test executable, never production builds.
static thread_local int io_fault = 0, write_calls = 0, truncate_calls = 0, close_calls = 0;
static std::atomic<bool> io_blocked{false}, resume_io{false};
static void block_io() {
    io_blocked.store(true);
    while (!resume_io.load()) resume_io.wait(false);
}
extern "C" ssize_t __real_pwrite(int, const void *, size_t, off_t);
extern "C" int __real_ftruncate(int, off_t);
extern "C" int __real_close(int);
extern "C" ssize_t __wrap_pwrite(int fd, const void *data, size_t n, off_t offset) {
    if (io_fault == 6) block_io();
    if (io_fault == 1 && write_calls++ == 0) { errno = EINTR; return -1; }
    if (io_fault == 2 && write_calls++ != 0) { errno = ENOSPC; return -1; }
    if (io_fault == 3) { ++write_calls; return 0; }
    if ((io_fault == 1 || io_fault == 2) && n > 2) n = 2;
    return __real_pwrite(fd, data, n, offset);
}
extern "C" int __wrap_ftruncate(int fd, off_t size) {
    if (io_fault == 7) block_io();
    if (io_fault == 1 && truncate_calls++ == 0) { errno = EINTR; return -1; }
    if (io_fault == 4) { errno = EIO; return -1; }
    return __real_ftruncate(fd, size);
}
extern "C" int __wrap_close(int fd) {
    const int result = __real_close(fd);
    // Linux close errors still release the descriptor: preserve that behavior.
    if (io_fault == 5 && result == 0) { ++close_calls; errno = EIO; return -1; }
    return result;
}

static void require(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "[FAIL] file lock native: %s\n", message); std::exit(1); }
}
static void setup(lua_State *L, const char *path) {
    luaL_openlibs(L);
    lua_newtable(L); lua_pushcfunction(L, lua_lockFile); lua_setfield(L, -2, "lockFile");
    lua_setglobal(L, "babet"); lua_pushstring(L, path); lua_setglobal(L, "path");
}
static void run(lua_State *L, const char *code) {
    if (luaL_dostring(L, code) != LUA_OK) {
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_getglobal(L, "path"); std::fprintf(stderr, "path=%s\n", lua_tostring(L, -1));
        require(false, "Lua contract");
    }
}
static int native_lock(const char *path, bool available) {
    const int fd = ::open(path, O_RDWR | O_CLOEXEC);
    require(fd >= 0, "native open");
    const int rc = ::flock(fd, LOCK_EX | LOCK_NB);
    require(available ? rc == 0 : rc != 0 && (errno == EWOULDBLOCK || errno == EAGAIN),
            "native flock contention");
    if (!available) { ::close(fd); return -1; }
    return fd;
}
static int count_fds() {
    DIR *dir = ::opendir("/proc/self/fd"); require(dir != nullptr, "fd count");
    int n = 0; while (::readdir(dir)) ++n; ::closedir(dir); return n;
}
struct Allocator { long remaining = -1; };
static void *allocate(void *data, void *ptr, std::size_t, std::size_t n) {
    if (!n) { std::free(ptr); return nullptr; }
    auto *a = static_cast<Allocator *>(data);
    if (a->remaining == 0) return nullptr;
    if (a->remaining > 0) --a->remaining;
    return std::realloc(ptr, n);
}
static bool wait_until(const std::atomic<bool> &flag) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!flag.load()) {
        if (std::chrono::steady_clock::now() >= deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}
static void slow_write_tests(const char *directory) {
    const int baseline = count_fds();
    const std::string path = std::string(directory) + "/slow-writer";
    const std::string other_path = std::string(directory) + "/independent-lock";
    // Handshakes, not a speed benchmark: I/O stays blocked until both unrelated
    // operations finish (or a generous failure deadline expires). Exercise both
    // syscalls so a future partial fix cannot leave ftruncate under the gate.
    for (int fault : {6, 7}) {
        io_blocked = false; resume_io = false;
        std::atomic<bool> lock_done{false}, fork_done{false};
        std::thread writer([&] {
            lua_State *T = luaL_newstate(); require(T != nullptr, "slow writer state");
            setup(T, path.c_str());
            run(T, "h = assert(babet.lockFile(path))");
            io_fault = fault;
            run(T, "assert(h:write('after slow I/O'))");
            io_fault = 0;
            lua_close(T);
        });
        const bool entered = wait_until(io_blocked);
        if (!entered) {
            resume_io = true; resume_io.notify_all(); writer.join();
            require(false, "slow I/O wrapper was not reached");
        }
        std::thread contender([&] {
            lua_State *T = luaL_newstate(); require(T != nullptr, "independent lock state");
            setup(T, other_path.c_str());
            run(T, "local h <close> = assert(babet.lockFile(path)); assert(h:write('independent'))");
            lua_close(T); lock_done = true;
        });
        std::thread forker([&] {
            const pid_t pid = ::fork(); require(pid >= 0, "fork during slow I/O");
            if (pid == 0) _exit(0);
            int status = 0; pid_t result;
            do { result = ::waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
            require(result == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0,
                    "slow I/O child exit");
            fork_done = true;
        });
        const bool independent_lock = wait_until(lock_done);
        const bool independent_fork = independent_lock && wait_until(fork_done);
        // The real lock must remain held while fork's child closes its copy.
        native_lock(path.c_str(), false);
        resume_io = true; resume_io.notify_all();
        writer.join(); contender.join(); forker.join();
        require(independent_lock, "slow lock:write blocked an independent lock acquisition");
        require(independent_fork, "slow lock:write blocked an independent fork");
        ::close(native_lock(path.c_str(), true));
        ::close(native_lock(other_path.c_str(), true));
        require(count_fds() == baseline, "descriptor leak after slow I/O");
    }
    ::unlink(path.c_str()); ::unlink(other_path.c_str());
    std::puts("[PASS] file lock native: blocked pwrite/ftruncate allow independent locks and forks, parent lock retained");
}
static void native_tests() {
    char temp[] = "/tmp/babet-lock-native.XXXXXX";
    require(::mkdtemp(temp) != nullptr, "mkdtemp");
    const std::string path = std::string(temp) + "/lock";
    lua_State *L = luaL_newstate(); require(L != nullptr, "Lua state"); setup(L, path.c_str());
    run(L, "h = assert(babet.lockFile(path)); assert(h:write('owner'))");
    // CLOEXEC on both newly created files and existing-inode reopenings.
    struct stat identity{}; require(::stat(path.c_str(), &identity) == 0, "stat");
    for (int pass = 0; pass < 2; ++pass) {
        bool found = false;
        for (int fd = 0; fd < 512; ++fd) {
            struct stat st{};
            if (::fstat(fd, &st) == 0 && st.st_dev == identity.st_dev && st.st_ino == identity.st_ino) {
                found = true; require((::fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0, "FD_CLOEXEC missing");
            }
        }
        require(found, "held descriptor not found");
        if (!pass) run(L, "assert(h:close()); h = assert(babet.lockFile(path))");
    }
    int ready[2], release[2]; require(::pipe(ready) == 0 && ::pipe(release) == 0, "pipe");
    const pid_t child = ::fork(); require(child >= 0, "fork");
    if (child == 0) {
        ::close(ready[0]); ::close(release[1]);
        run(L, "assert(h:write('child') == nil); assert(h:close())");
        lua_close(L); // finalizers in a child must not release the parent's lock
        const char byte = 'x'; require(::write(ready[1], &byte, 1) == 1, "ready");
        char input; (void)::read(release[0], &input, 1); _exit(0);
    }
    ::close(ready[1]); ::close(release[0]); char byte;
    require(::read(ready[0], &byte, 1) == 1, "child handshake");
    native_lock(path.c_str(), false);
    run(L, "assert(h:close())");
    ::close(native_lock(path.c_str(), true)); // child is still alive here
    require(::write(release[1], &byte, 1) == 1, "child release");
    ::close(ready[0]); ::close(release[1]); int status;
    require(::waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "fork child exit");
    lua_close(L);
    std::puts("[PASS] file lock native: CLOEXEC and fork child cleanup without unlocking parent");

    const int baseline = count_fds(); int failures = 0;
    for (int point = 0; point < 60; ++point) {
        Allocator a;
        L = lua_newstate(allocate, &a, 0); require(L != nullptr, "allocator state"); setup(L, path.c_str());
        require(luaL_loadstring(L, "local h = assert(babet.lockFile(path)); assert(h:write('x')); h:close()") == LUA_OK, "load");
        a.remaining = point;
        const int rc = lua_pcall(L, 0, 0, 0);
        a.remaining = -1;
        if (rc != LUA_OK) ++failures;
        lua_settop(L, 0); lua_gc(L, LUA_GCCOLLECT);
        ::close(native_lock(path.c_str(), true));
        run(L, "local h <close> = assert(babet.lockFile(path)); assert(h:write('retry'))");
        lua_close(L);
        require(count_fds() == baseline, "fd leaked after Lua allocation failure");
    }
    require(failures > 0, "OOM injection did not fail any allocation");
    std::printf("[PASS] file lock native: %d allocator failures, retry and 60 Lua states closed\n", failures);

    // Force OOM specifically while the methods build an error result. A
    // protected result builder without a method boundary would throw through
    // Lua's C frames. Start each case in a fresh VM (no interned diagnostics).
    for (int target = 0; target < 3; ++target) {
        Allocator a;
        L = lua_newstate(allocate, &a, 0); require(L != nullptr, "method OOM state");
        setup(L, path.c_str()); run(L, "h = assert(babet.lockFile(path))");
        if (target == 0) run(L, "assert(h:close())");
        lua_getglobal(L, "h");
        lua_getfield(L, -1, target == 2 ? "close" : "write");
        lua_pushvalue(L, -2); lua_remove(L, -3);
        if (target != 2) lua_pushliteral(L, "method OOM probe");
        write_calls = close_calls = 0;
        io_fault = target == 1 ? 3 : target == 2 ? 5 : 0;
        a.remaining = 0;
        const int rc = lua_pcall(L, target == 2 ? 1 : 2, 2, 0);
        a.remaining = -1; io_fault = 0;
        require(rc == LUA_ERRMEM, "method result OOM did not stay inside Lua protection");
        if (target == 1) require(write_calls == 1, "OOM happened before native write");
        if (target == 2) require(close_calls == 1, "OOM happened before native close");
        lua_settop(L, 0);
        if (target == 1) native_lock(path.c_str(), false);
        else ::close(native_lock(path.c_str(), true));
        run(L, "assert(h:close()); local retry <close> = assert(babet.lockFile(path)); "
               "assert(retry:write('recovered'))");
        lua_close(L);
        require(count_fds() == baseline, "fd leaked on method result OOM");
    }
    std::puts("[PASS] file lock native: 3 method-result OOM cases contained, lock state preserved, retry succeeds");

    L = luaL_newstate(); require(L != nullptr, "I/O state"); setup(L, path.c_str());
    run(L, "h = assert(babet.lockFile(path))");
    for (int fault = 1; fault <= 4; ++fault) {
        io_fault = fault; write_calls = truncate_calls = 0;
        if (fault == 1) run(L, "assert(h:write('abcdef')); local f=assert(io.open(path)); "
                              "assert(f:read('a')=='abcdef'); f:close()");
        else run(L, "local ok,err=h:write('XYZ'); assert(ok==nil and type(err)=='string')");
        io_fault = 0;
        native_lock(path.c_str(), false);
        run(L, "assert(h:write('recovered'))");
    }
    run(L, "h=nil; collectgarbage('collect')"); lua_close(L);
    ::close(native_lock(path.c_str(), true));
    require(count_fds() == baseline, "fd leaked on I/O error");
    std::puts("[PASS] file lock native: EINTR, short/zero writes, ENOSPC, truncate failure, lock retained");

    std::atomic<bool> start{false};
    auto thread = [&](int index) {
        const std::string own = std::string(temp) + "/thread" + std::to_string(index);
        lua_State *T = luaL_newstate(); require(T != nullptr, "thread state"); setup(T, own.c_str());
        while (!start.load()) std::this_thread::yield();
        for (int i = 0; i < 100; ++i)
            // The parent may resume before the child runs its atfork handler:
            // a just-closed description can remain locked for that short gap.
            run(T, "local h, err; repeat h,err=babet.lockFile(path); "
                   "assert(h or err=='locked', err) until h; "
                   "assert(h:write('thread')); assert(h:close())");
        lua_close(T); ::unlink(own.c_str());
    };
    std::thread a(thread, 1), b(thread, 2); start = true;
    for (int i = 0; i < 30; ++i) {
        const pid_t pid = ::fork(); require(pid >= 0, "concurrent fork");
        if (!pid) _exit(0);
        require(::waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0,
                "concurrent child exit");
    }
    a.join(); b.join(); require(count_fds() == baseline, "thread descriptor leak");
    std::puts("[PASS] file lock native: independent Lua threads and 30 concurrent forks");
    slow_write_tests(temp);
    ::unlink(path.c_str()); ::rmdir(temp);
}
int main(int argc, char **argv) {
    if (argc == 1) { native_tests(); return 0; }
    lua_State *L = luaL_newstate(); require(L != nullptr, "runner state"); setup(L, "");
    lua_newtable(L);
    for (int i = 1; i < argc; ++i) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 1); }
    lua_setglobal(L, "arg");
    const int rc = luaL_loadfile(L, argv[1]) || lua_pcall(L, 0, 0, 0);
    if (rc) std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L); return rc ? 1 : 0;
}
