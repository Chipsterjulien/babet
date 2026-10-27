#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "lockFile.hpp"
#include "lua_utils.hpp"

#include <atomic>
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <new>
#include <pthread.h>
#include <sched.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr const char *metatable = "babet.file_lock";
struct FileLock {
    int fd = -1;
    FileLock *previous = nullptr;
    FileLock *next = nullptr;
};

// One process-wide list, including independent Lua VMs and worker threads.
// No Lua call/allocation while holding the gate. atomic_flag is guaranteed
// lock-free: the child fork handler only touches scalar memory and close().
std::atomic_flag gate = ATOMIC_FLAG_INIT;
FileLock *head = nullptr;
pthread_once_t once = PTHREAD_ONCE_INIT;
int atfork_error = 0;

void take_gate() noexcept {
    while (gate.test_and_set(std::memory_order_acquire)) ::sched_yield();
}
void release_gate() noexcept { gate.clear(std::memory_order_release); }
void after_fork_child() noexcept {
    const int saved = errno;
    while (head) {
        FileLock *item = head;
        head = item->next;
        // Never LOCK_UN: parent and child refer to the same open description.
        (void)::close(item->fd);
        item->fd = -1;
        item->previous = item->next = nullptr;
    }
    release_gate();
    errno = saved;
}
void install_atfork() noexcept {
    atfork_error = ::pthread_atfork(take_gate, release_gate, after_fork_child);
}

void link_handle(FileLock *item, int fd) noexcept {
    item->fd = fd;
    item->next = head;
    if (head) head->previous = item;
    head = item;
}
int close_handle(FileLock *item) noexcept {
    take_gate();
    int error = 0;
    if (item->fd >= 0) {
        if (item->previous) item->previous->next = item->next;
        else head = item->next;
        if (item->next) item->next->previous = item->previous;
        const int fd = item->fd;
        item->fd = -1;
        item->previous = item->next = nullptr;
        // Linux releases the fd even on EINTR. Retrying could close a reused fd.
        if (::close(fd) != 0) error = errno;
    }
    release_gate();
    return error;
}

int fail_errno(lua_State *L, const char *operation, int error) {
    // strerror_r avoids strerror's shared mutable error buffer.
    char reason[160]{};
#if defined(__GLIBC__)
    const char *message = ::strerror_r(error, reason, sizeof(reason));
#else
    const char *message = ::strerror_r(error, reason, sizeof(reason)) == 0
        ? reason : "system error";
#endif
    char diagnostic[240]{};
    std::snprintf(diagnostic, sizeof(diagnostic), "babet.%s: %s (errno %d)",
                  operation, message, error);
    return push_fail_protected(L, diagnostic);
}

int finalize(lua_State *L) {
    auto *item = static_cast<FileLock *>(luaL_testudata(L, 1, metatable));
    if (item) (void)close_handle(item);
    return 0;
}
int close_method(lua_State *L) {
    if (!lua_arity_is(L, 1)) return luaL_error(L, "file lock:close expects no arguments");
    auto *item = static_cast<FileLock *>(luaL_checkudata(L, 1, metatable));
    const int error = close_handle(item);
    return error ? fail_errno(L, "lock:close", error) : push_ok_protected(L);
}
int write_method(lua_State *L) {
    if (!lua_arity_is(L, 2) || !lua_is_strict_string(L, 2))
        return luaL_error(L, "file lock:write expects one string");
    auto *item = static_cast<FileLock *>(luaL_checkudata(L, 1, metatable));
    std::size_t size = 0;
    const char *text = lua_tolstring(L, 2, &size);
    if (size > static_cast<std::uintmax_t>(std::numeric_limits<off_t>::max()))
        return push_fail_protected(L, "babet.lock:write: content is too large");
    // This handle is used only by its owning Lua state. There is no Lua call
    // during native I/O that could reenter close/finalize; fork cleanup touches
    // only the child's copy. Do not hold the process-wide registry gate across
    // a potentially slow write: independent lock operations and forks may run.
    if (item->fd < 0) {
        return push_fail_protected(L, "babet.lock:write: handle is closed");
    }
    int error = 0;
    std::size_t done = 0;
    while (done < size) {
        const std::size_t count = std::min(size - done,
            static_cast<std::size_t>(std::numeric_limits<ssize_t>::max()));
        const ssize_t n = ::pwrite(item->fd, text + done, count, static_cast<off_t>(done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { error = n < 0 ? errno : EIO; break; }
        done += static_cast<std::size_t>(n);
    }
    if (!error) {
        int rc;
        do { rc = ::ftruncate(item->fd, static_cast<off_t>(size)); }
        while (rc != 0 && errno == EINTR);
        if (rc != 0) error = errno;
    }
    // Writing failure does NOT release the lock. This is an in-place update,
    // not an atomic/durable data-file save; a failure can leave partial text.
    return error ? fail_errno(L, "lock:write", error) : push_ok_protected(L);
}

template <int (*Fn)(lua_State *)>
int file_lock_lua_boundary(lua_State *L) {
    // Protected builders translate Lua allocation failures to a C++ marker.
    // Each method needs its own boundary before returning through Lua C frames.
    return lua_cfunction_exception_boundary<Fn>(L,
        "babet.file_lock: out of memory", "babet.file_lock: internal failure",
        "babet.file_lock: unknown internal failure");
}

// Never open a pre-existing FIFO/device for I/O, even across path replacement.
// The O_PATH descriptor pins the checked inode, like Babet's tree-copy reader.
int open_regular(const char *path, int &error) noexcept {
    int fd;
    do { fd = ::open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600); }
    while (fd < 0 && errno == EINTR);
    if (fd >= 0) return fd;
    if (errno != EEXIST) { error = errno; return -1; }
    int pin;
    do { pin = ::open(path, O_PATH | O_CLOEXEC); } while (pin < 0 && errno == EINTR);
    if (pin < 0) { error = errno; return -1; }
    struct stat before{};
    if (::fstat(pin, &before) != 0) error = errno;
    else if (!S_ISREG(before.st_mode)) error = EINVAL;
    if (error) { (void)::close(pin); return -1; }
    char pinned_path[64];
    std::snprintf(pinned_path, sizeof(pinned_path), "/proc/self/fd/%d", pin);
    do { fd = ::open(pinned_path, O_RDWR | O_CLOEXEC | O_NOCTTY); }
    while (fd < 0 && errno == EINTR);
    if (fd < 0) error = errno;
    else {
        struct stat after{};
        if (::fstat(fd, &after) != 0) error = errno;
        else if (!S_ISREG(after.st_mode) || before.st_dev != after.st_dev ||
                 before.st_ino != after.st_ino) error = EAGAIN;
        if (error) { (void)::close(fd); fd = -1; }
    }
    (void)::close(pin);
    return fd;
}

int lock_file(lua_State *L) {
    if (!lua_arity_is(L, 1) || !lua_is_strict_string(L, 1))
        return luaL_error(L, "babet.lockFile expects one path string");
    const auto path = luaL_checkstring_view_without_nul(L, 1, "path");
    if (path.empty()) return luaL_error(L, "babet.lockFile: path must not be empty");
    // Build the whole metatable before publishing it, so an OOM cannot leave
    // an incomplete registry entry for the next attempt.
    luaL_getmetatable(L, metatable);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_createtable(L, 0, 5);
        lua_pushcfunction(L, finalize); lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, finalize); lua_setfield(L, -2, "__close");
        lua_pushliteral(L, "file lock"); lua_setfield(L, -2, "__metatable");
        lua_createtable(L, 0, 2);
        lua_pushcfunction(L, file_lock_lua_boundary<write_method>); lua_setfield(L, -2, "write");
        lua_pushcfunction(L, file_lock_lua_boundary<close_method>); lua_setfield(L, -2, "close");
        lua_setfield(L, -2, "__index");
        lua_pushvalue(L, -1); lua_setfield(L, LUA_REGISTRYINDEX, metatable);
    }
    auto *item = new (lua_newuserdatauv(L, sizeof(FileLock), 0)) FileLock;
    lua_pushvalue(L, -2); lua_setmetatable(L, -2);
    lua_remove(L, -2);
    lua_pushnil(L); // Prepare both return values before obtaining a resource.
    int error = ::pthread_once(&once, install_atfork);
    if (!error) error = atfork_error;
    if (error) return fail_errno(L, "lockFile: fork cleanup unavailable", error);
    take_gate();
    const int fd = open_regular(path.data(), error);
    bool busy = false;
    if (fd >= 0) {
        int rc;
        do { rc = ::flock(fd, LOCK_EX | LOCK_NB); } while (rc != 0 && errno == EINTR);
        if (rc != 0) {
            error = errno;
            busy = error == EWOULDBLOCK || error == EAGAIN;
            (void)::close(fd);
        } else link_handle(item, fd);
    }
    release_gate();
    if (busy) return push_fail_protected(L, "locked");
    if (error) return fail_errno(L, "lockFile", error);
    return 2;
}
} // namespace

int lua_lockFile(lua_State *L) {
    return lua_cfunction_exception_boundary<lock_file>(L,
        "babet.lockFile: out of memory", "babet.lockFile: internal failure",
        "babet.lockFile: unknown internal failure");
}
