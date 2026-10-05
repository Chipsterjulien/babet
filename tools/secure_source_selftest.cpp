#include "lua_bindings/secure_destination.hpp"
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;
namespace
{
std::string victim;
std::string saved;
int swap_when = 0; // 1/2: before/after pin; 3/4/5: replace/remove at publication
int swaps = 0;
bool unsafe_io_open = false;
bool force_exdev = false;
bool fail_reopen = false;
void replace_with_fifo()
{
    if (::rename(victim.c_str(), saved.c_str()) != 0 ||
        ::mkfifo(victim.c_str(), 0600) != 0) std::abort();
    ++swaps;
}
std::string read_file(const fs::path &path)
{
    std::ifstream input(path);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
}

extern "C" int __real_open(const char *, int, ...);
extern "C" int __wrap_open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if ((flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE)
    {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    if (!victim.empty() && victim == path)
    {
        if (!(flags & O_PATH)) unsafe_io_open = true;
        if ((flags & O_PATH) && swap_when == 1) { swap_when = 0; replace_with_fifo(); }
    }
    if (fail_reopen && std::strncmp(path, "/proc/self/fd/", 14) == 0)
    { errno = ENOENT; return -1; }
    const int fd = __real_open(path, flags, mode);
    if (fd >= 0 && victim == path && (flags & O_PATH) && swap_when == 2)
    { swap_when = 0; replace_with_fifo(); }
    return fd;
}
extern "C" int __real_renameat(int, const char *, int, const char *);
extern "C" int __wrap_renameat(int from, const char *source, int to, const char *destination)
{
    if (force_exdev && victim == source) { errno = EXDEV; return -1; }
    const int result = __real_renameat(from, source, to, destination);
    if (result == 0 && swap_when >= 3)
    {
        if (::rename(victim.c_str(), saved.c_str()) != 0) std::abort();
        if (swap_when == 3) { std::ofstream file(victim); file << "UNTRANSFERRED"; }
        if (swap_when == 4 && ::symlink(saved.c_str(), victim.c_str()) != 0) std::abort();
        swap_when = 0;
        ++swaps;
    }
    return result;
}

int main()
{
    ::alarm(15);
    char pattern[] = "/tmp/babet-secure-source.XXXXXX";
    char *temporary = ::mkdtemp(pattern);
    if (!temporary) return 2;
    const fs::path root = temporary;
    struct Cleanup { fs::path path; ~Cleanup() { std::error_code ec; fs::remove_all(path, ec); } } cleanup{root};
    fs::create_directory(root / "out");
    SecureDestination destination;
    if (destination.open_root(root / "out")) return 2;
    for (int when : {0, 1, 2})
    {
        victim = (root / ("source-" + std::to_string(when))).string();
        saved = victim + ".saved";
        { std::ofstream file(victim); file << "ORIGINAL"; }
        swap_when = when; swaps = 0; unsafe_io_open = false;
        const fs::path leaf = "copy-" + std::to_string(when);
        const auto error = destination.copy_regular_file(victim, leaf);
        if (unsafe_io_open || swaps != (when ? 1 : 0)) return 1;
        if (when == 1)
        {
            if (!error || fs::exists(root / "out" / leaf) || read_file(saved) != "ORIGINAL") return 1;
        }
        else if (error || read_file(root / "out" / leaf) != "ORIGINAL") return 1;
        std::printf("[PASS] regular source pin/replacement scenario %d\n", when);
    }
    victim = (root / "missing-proc").string();
    { std::ofstream file(victim); file << "PRESERVED"; }
    fail_reopen = true;
    const auto reopen_error = destination.copy_regular_file(victim, "unpublished");
    fail_reopen = false;
    if (!reopen_error || fs::exists(root / "out/unpublished") || read_file(victim) != "PRESERVED") return 1;
    std::puts("[PASS] unavailable procfs reopen preserves source and destination");

    // Inject EXDEV and substitute a source after its inode was pinned, or
    // after the completed destination was published but before source unlink.
    const auto fd_count = [] {
        std::size_t count = 0;
        for (const auto &entry : fs::directory_iterator("/proc/self/fd"))
        { (void)entry; ++count; }
        return count;
    };
    const auto baseline_fds = fd_count();
    for (int when : {0, 2, 3, 4, 5})
    {
        victim = (root / ("move-" + std::to_string(when))).string();
        saved = victim + ".saved";
        { std::ofstream file(victim); file << "ORIGINAL"; }
        const auto leaf = "moved-" + std::to_string(when);
        force_exdev = true; swap_when = when; swaps = 0;
        const auto error = destination.move_entry(victim, leaf);
        force_exdev = false;
        if (read_file(root / "out" / leaf) != "ORIGINAL" || fd_count() != baseline_fds)
            return 1;
        if (when == 0)
        {
            if (error || fs::exists(victim) || swaps) return 1;
        }
        else
        {
            if (!error || swaps != 1 || read_file(saved) != "ORIGINAL") return 1;
            if (when == 2 && !fs::is_fifo(victim)) return 1;
            if (when == 3 && read_file(victim) != "UNTRANSFERRED") return 1;
            if (when == 4 && (!fs::is_symlink(victim) || read_file(victim) != "ORIGINAL")) return 1;
            if (when == 5 && fs::exists(victim)) return 1;
        }
        std::printf("[PASS] EXDEV source identity before removal scenario %d, no FD leak\n", when);
    }

    // A real private PTY makes the old device-open side effect observable,
    // without root, mknod, or touching a real terminal/device belonging to a user.
    const int master = ::posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0 || ::grantpt(master) != 0 || ::unlockpt(master) != 0) return 2;
    victim = ::ptsname(master);
    const pid_t child = ::fork();
    if (child < 0) return 2;
    if (child == 0)
    {
        if (::setsid() < 0) std::_Exit(2);
        if (::open("/dev/tty", O_RDONLY | O_NOCTTY) >= 0) std::_Exit(3);
        force_exdev = true; unsafe_io_open = false;
        const auto error = destination.move_entry(victim, "device");
        const int controlling = ::open("/dev/tty", O_RDONLY | O_NOCTTY);
        if (controlling >= 0) ::close(controlling);
        std::_Exit(error && !unsafe_io_open && controlling < 0 &&
                   !fs::exists(root / "out/device") ? 0 : 1);
    }
    int status = 0;
    const pid_t waited = ::waitpid(child, &status, 0);
    ::close(master);
    if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 1;
    std::puts("[PASS] EXDEV device refusal performs no I/O open and acquires no controlling terminal");
    std::puts("secure source: 10 PASS / 0 FAIL");
    return 0;
}
