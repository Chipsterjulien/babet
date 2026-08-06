#!/usr/bin/env bash
# Régression déterministe de la disparition d'un dossier entre readdir et
# l'ouverture de sa descente par babet.find(). Une bibliothèque LD_PRELOAD
# retire exactement le dossier ciblé au moment où libstdc++ ouvre sa descente.
# Plusieurs symboles glibc sont interceptés (open/openat, variantes 64 bits et
# fortifiées, plus opendir/fdopendir) afin de rester discriminant entre distributions.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /chemin/vers/babet" >&2
    exit 2
fi

BINARY="$1"
if [ ! -x "${BINARY}" ]; then
    echo "find disappearance regression: binaire introuvable: ${BINARY}" >&2
    exit 2
fi

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

TREE="${TMP_ROOT}/tree"
MARKER="${TMP_ROOT}/injected"
mkdir -p "${TREE}/one" "${TREE}/two" "${TREE}/three"
printf 'one\n' > "${TREE}/one/payload.txt"
printf 'two\n' > "${TREE}/two/payload.txt"
printf 'three\n' > "${TREE}/three/payload.txt"

cat > "${TMP_ROOT}/find_vanish.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);
typedef DIR *(*opendir_fn)(const char *);
typedef DIR *(*fdopendir_fn)(int);

static open_fn real_open_fn;
static open_fn real_open64_fn;
static openat_fn real_openat_fn;
static openat_fn real_openat64_fn;
static open_fn real___open_2_fn;
static open_fn real___open64_2_fn;
static openat_fn real___openat_2_fn;
static openat_fn real___openat64_2_fn;
static opendir_fn real_opendir_fn;
static fdopendir_fn real_fdopendir_fn;
static int injected;

static void *resolve_next(const char *symbol)
{
    dlerror();
    void *result = dlsym(RTLD_NEXT, symbol);
    (void)dlerror();
    return result;
}

static void ensure_real_functions(void)
{
    if (!real_open_fn)
    {
        real_open_fn = (open_fn)resolve_next("open");
    }
    if (!real_open64_fn)
    {
        real_open64_fn = (open_fn)resolve_next("open64");
    }
    if (!real_openat_fn)
    {
        real_openat_fn = (openat_fn)resolve_next("openat");
    }
    if (!real_openat64_fn)
    {
        real_openat64_fn = (openat_fn)resolve_next("openat64");
    }
    if (!real___open_2_fn)
    {
        real___open_2_fn = (open_fn)resolve_next("__open_2");
    }
    if (!real___open64_2_fn)
    {
        real___open64_2_fn = (open_fn)resolve_next("__open64_2");
    }
    if (!real___openat_2_fn)
    {
        real___openat_2_fn = (openat_fn)resolve_next("__openat_2");
    }
    if (!real___openat64_2_fn)
    {
        real___openat64_2_fn = (openat_fn)resolve_next("__openat64_2");
    }
    if (!real_opendir_fn)
    {
        real_opendir_fn = (opendir_fn)resolve_next("opendir");
    }
    if (!real_fdopendir_fn)
    {
        real_fdopendir_fn = (fdopendir_fn)resolve_next("fdopendir");
    }
}

static int write_all(int fd, const char *data, size_t size)
{
    while (size > 0)
    {
        const ssize_t written = write(fd, data, size);
        if (written < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            return -1;
        }
        if (written == 0)
        {
            errno = EIO;
            return -1;
        }
        data += (size_t)written;
        size -= (size_t)written;
    }
    return 0;
}

static int parent_path_for_fd(int dirfd, char *parent,
                              size_t parent_capacity)
{
    if (dirfd == AT_FDCWD)
    {
        return getcwd(parent, parent_capacity) != NULL;
    }

    char proc_path[64];
    const int proc_length = snprintf(
        proc_path, sizeof(proc_path), "/proc/self/fd/%d", dirfd);
    if (proc_length < 0 || (size_t)proc_length >= sizeof(proc_path))
    {
        return 0;
    }

    const ssize_t parent_length = readlink(
        proc_path, parent, parent_capacity - 1);
    if (parent_length < 0 || (size_t)parent_length >= parent_capacity)
    {
        return 0;
    }
    parent[parent_length] = '\0';
    return 1;
}

static int first_child_under_root(int dirfd, const char *path,
                                  const char *root, char *full,
                                  size_t full_capacity)
{
    if (!root || !path)
    {
        return 0;
    }

    if (path[0] == '/')
    {
        const size_t root_length = strlen(root);
        if (strncmp(path, root, root_length) != 0 ||
            path[root_length] != '/' || path[root_length + 1] == '\0' ||
            strchr(path + root_length + 1, '/'))
        {
            return 0;
        }
        const int full_length = snprintf(full, full_capacity, "%s", path);
        return full_length >= 0 && (size_t)full_length < full_capacity;
    }

    if (strchr(path, '/'))
    {
        return 0;
    }

    char parent[PATH_MAX];
    if (!parent_path_for_fd(dirfd, parent, sizeof(parent)) ||
        strcmp(parent, root) != 0)
    {
        return 0;
    }

    const int full_length = snprintf(
        full, full_capacity, "%s/%s", parent, path);
    return full_length >= 0 && (size_t)full_length < full_capacity;
}

static void write_marker(const char *target)
{
    const char *marker = getenv("BABET_TEST_FIND_VANISH_MARKER");
    if (!marker)
    {
        return;
    }

    const long marker_fd_long = syscall(
        SYS_openat, AT_FDCWD, marker,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (marker_fd_long < 0 || marker_fd_long > INT_MAX)
    {
        return;
    }

    const int marker_fd = (int)marker_fd_long;
    const int write_rc = write_all(marker_fd, target, strlen(target));
    const int close_rc = close(marker_fd);
    if (write_rc != 0 || close_rc != 0)
    {
        (void)unlink(marker);
    }
}

static int maybe_vanish(int dirfd, const char *path, int directory_open)
{
    if (injected || !directory_open)
    {
        return 0;
    }

    const char *root = getenv("BABET_TEST_FIND_VANISH_ROOT");
    char target[PATH_MAX];
    if (!first_child_under_root(
            dirfd, path, root, target, sizeof(target)))
    {
        return 0;
    }

    injected = 1;
    char child[PATH_MAX];
    const int child_length = snprintf(
        child, sizeof(child), "%s/payload.txt", target);
    if (child_length >= 0 && (size_t)child_length < sizeof(child))
    {
        (void)unlink(child);
    }
    (void)rmdir(target);
    write_marker(target);
    return 1;
}

static mode_t extract_mode(int flags, va_list args)
{
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
    {
        return (mode_t)va_arg(args, int);
    }
    return 0;
}

static int call_open(open_fn function, const char *path, int flags,
                     mode_t mode)
{
    if (!function)
    {
        errno = ENOSYS;
        return -1;
    }
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
    {
        return function(path, flags, mode);
    }
    return function(path, flags);
}

static int call_openat(openat_fn function, int dirfd, const char *path,
                       int flags, mode_t mode)
{
    if (!function)
    {
        errno = ENOSYS;
        return -1;
    }
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
    {
        return function(dirfd, path, flags, mode);
    }
    return function(dirfd, path, flags);
}

int open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
    {
        va_list args;
        va_start(args, flags);
        mode = extract_mode(flags, args);
        va_end(args);
    }
    ensure_real_functions();
    (void)maybe_vanish(AT_FDCWD, path, (flags & O_DIRECTORY) != 0);
    return call_open(real_open_fn, path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
    {
        va_list args;
        va_start(args, flags);
        mode = extract_mode(flags, args);
        va_end(args);
    }
    ensure_real_functions();
    (void)maybe_vanish(AT_FDCWD, path, (flags & O_DIRECTORY) != 0);
    return call_open(real_open64_fn ? real_open64_fn : real_open_fn,
                     path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
    {
        va_list args;
        va_start(args, flags);
        mode = extract_mode(flags, args);
        va_end(args);
    }
    ensure_real_functions();
    (void)maybe_vanish(dirfd, path, (flags & O_DIRECTORY) != 0);
    return call_openat(real_openat_fn, dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
    {
        va_list args;
        va_start(args, flags);
        mode = extract_mode(flags, args);
        va_end(args);
    }
    ensure_real_functions();
    (void)maybe_vanish(dirfd, path, (flags & O_DIRECTORY) != 0);
    return call_openat(real_openat64_fn ? real_openat64_fn : real_openat_fn,
                       dirfd, path, flags, mode);
}

int __open_2(const char *path, int flags)
{
    ensure_real_functions();
    (void)maybe_vanish(AT_FDCWD, path, (flags & O_DIRECTORY) != 0);
    if (real___open_2_fn)
    {
        return real___open_2_fn(path, flags);
    }
    return call_open(real_open_fn, path, flags, 0);
}

int __open64_2(const char *path, int flags)
{
    ensure_real_functions();
    (void)maybe_vanish(AT_FDCWD, path, (flags & O_DIRECTORY) != 0);
    if (real___open64_2_fn)
    {
        return real___open64_2_fn(path, flags);
    }
    return call_open(real_open64_fn ? real_open64_fn : real_open_fn,
                     path, flags, 0);
}

int __openat_2(int dirfd, const char *path, int flags)
{
    ensure_real_functions();
    (void)maybe_vanish(dirfd, path, (flags & O_DIRECTORY) != 0);
    if (real___openat_2_fn)
    {
        return real___openat_2_fn(dirfd, path, flags);
    }
    return call_openat(real_openat_fn, dirfd, path, flags, 0);
}

int __openat64_2(int dirfd, const char *path, int flags)
{
    ensure_real_functions();
    (void)maybe_vanish(dirfd, path, (flags & O_DIRECTORY) != 0);
    if (real___openat64_2_fn)
    {
        return real___openat64_2_fn(dirfd, path, flags);
    }
    return call_openat(real_openat64_fn ? real_openat64_fn : real_openat_fn,
                       dirfd, path, flags, 0);
}

DIR *opendir(const char *path)
{
    ensure_real_functions();
    (void)maybe_vanish(AT_FDCWD, path, 1);
    if (!real_opendir_fn)
    {
        errno = ENOSYS;
        return NULL;
    }
    return real_opendir_fn(path);
}

DIR *fdopendir(int fd)
{
    ensure_real_functions();

    char proc_path[64];
    char target[PATH_MAX];
    const int proc_length = snprintf(
        proc_path, sizeof(proc_path), "/proc/self/fd/%d", fd);
    if (proc_length >= 0 && (size_t)proc_length < sizeof(proc_path))
    {
        const ssize_t target_length = readlink(
            proc_path, target, sizeof(target) - 1);
        if (target_length >= 0 && (size_t)target_length < sizeof(target))
        {
            target[target_length] = '\0';
            if (maybe_vanish(AT_FDCWD, target, 1))
            {
                // Leave ownership of fd with the caller on failure, exactly as
                // fdopendir() requires. The short-lived test process will let
                // libstdc++ close it through its normal error path.
                errno = ENOENT;
                return NULL;
            }
        }
    }

    if (!real_fdopendir_fn)
    {
        errno = ENOSYS;
        return NULL;
    }
    return real_fdopendir_fn(fd);
}

C

cc -shared -fPIC -O2 -Wall -Wextra -Werror \
    "${TMP_ROOT}/find_vanish.c" -ldl -o "${TMP_ROOT}/find_vanish.so"

echo "[PASS] disappearance preload compiled"

cat > "${TMP_ROOT}/test.lua" <<'LUA'
local root = assert(babet.env("BABET_TEST_FIND_ROOT"))
local results, err = babet.find(root, { type = "f" })
assert(results, err)
assert(#results == 2,
       "expected two surviving sibling files, got " .. tostring(#results))
for _, path in ipairs(results) do
    assert(path:sub(-12) == "/payload.txt",
           "unexpected result: " .. tostring(path))
    print("FOUND:" .. path)
end
print("BABET_FIND_DISAPPEARANCE_OK")
LUA

PRELOAD="${TMP_ROOT}/find_vanish.so"
if [ -n "${BABET_TEST_ASAN_RUNTIME:-}" ]; then
    PRELOAD="${BABET_TEST_ASAN_RUNTIME}:${PRELOAD}"
fi
if [ -n "${LD_PRELOAD:-}" ]; then
    PRELOAD="${PRELOAD}:${LD_PRELOAD}"
fi

set +e
OUTPUT=$(BABET_TEST_FIND_ROOT="${TREE}" \
    BABET_TEST_FIND_VANISH_ROOT="${TREE}" \
    BABET_TEST_FIND_VANISH_MARKER="${MARKER}" \
    LD_PRELOAD="${PRELOAD}" \
    "${BINARY}" "${TMP_ROOT}/test.lua" 2>&1)
RC=$?
set -e

if [ ! -f "${MARKER}" ]; then
    echo "[FAIL] disappearance hook was not triggered" >&2
    echo "${OUTPUT}" >&2
    exit 1
fi
echo "[PASS] disappearance hook triggered before child open"

if [ "${RC}" -ne 0 ]; then
    echo "[FAIL] babet.find failed after a child directory vanished" >&2
    echo "${OUTPUT}" >&2
    exit 1
fi
echo "[PASS] babet.find returns successfully after ENOENT descent race"

VICTIM="$(cat "${MARKER}")"
if ! grep -q '^BABET_FIND_DISAPPEARANCE_OK$' <<<"${OUTPUT}" ||
   [ "$(grep -c '^FOUND:' <<<"${OUTPUT}")" -ne 2 ] ||
   grep -Fq "FOUND:${VICTIM}/payload.txt" <<<"${OUTPUT}"; then
    echo "[FAIL] surviving siblings or vanished child contract failed" >&2
    echo "victim=${VICTIM}" >&2
    echo "${OUTPUT}" >&2
    exit 1
fi
echo "[PASS] both later siblings remain visible and vanished child is absent"

echo "find disappearing-directory regression: 4 PASS / 0 FAIL"
