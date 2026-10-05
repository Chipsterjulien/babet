#include "lua_bindings/sigpipe_guard.hpp"
#include <atomic>
#include <cassert>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

static volatile sig_atomic_t calls = 0;
static void handler(int) { calls = calls + 1; }
static bool blocked()
{
    sigset_t mask;
    assert(pthread_sigmask(SIG_SETMASK, nullptr, &mask) == 0);
    return sigismember(&mask, SIGPIPE) == 1;
}
static bool pending()
{
    sigset_t mask;
    assert(sigpending(&mask) == 0);
    return sigismember(&mask, SIGPIPE) == 1;
}
static void broken_write()
{
    int pipefd[2];
    assert(pipe(pipefd) == 0);
    close(pipefd[0]);
    int rc = babet_io::without_sigpipe([&] {
        return static_cast<int>(write(pipefd[1], "x", 1));
    });
    assert(rc == -1 && errno == EPIPE);
    close(pipefd[1]);
}
int main()
{
    sigset_t empty;
    sigemptyset(&empty);
    assert(pthread_sigmask(SIG_SETMASK, &empty, nullptr) == 0);
    struct sigaction action{};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGPIPE, &action, nullptr) == 0);
    broken_write(); // With SIG_DFL, any undrained signal kills this executable.
    assert(!blocked() && !pending());
    action.sa_handler = handler;
    assert(sigaction(SIGPIPE, &action, nullptr) == 0);
    broken_write();
    assert(calls == 0 && !blocked() && !pending());
    assert(raise(SIGPIPE) == 0 && calls == 1);

    // A signal already pending belongs to the caller, even after another EPIPE.
    sigset_t pipe_set;
    sigemptyset(&pipe_set); sigaddset(&pipe_set, SIGPIPE);
    assert(pthread_sigmask(SIG_BLOCK, &pipe_set, nullptr) == 0);
    assert(raise(SIGPIPE) == 0 && pending());
    broken_write();
    assert(blocked() && pending() && calls == 1);
    assert(pthread_sigmask(SIG_UNBLOCK, &pipe_set, nullptr) == 0);
    assert(calls == 2);

    // A scope in another thread must not change this thread's signal policy.
    std::atomic<bool> ready{false}, done{false};
    std::thread other([&] {
        babet_io::SigpipeGuard guard;
        assert(guard.error() == 0 && blocked());
        ready.store(true);
        while (!done.load()) std::this_thread::yield();
    });
    while (!ready.load()) std::this_thread::yield();
    assert(!blocked());
    assert(raise(SIGPIPE) == 0 && calls == 3);
    done.store(true); other.join();

    errno = ENOENT;
    try {
        babet_io::SigpipeGuard guard;
        assert(guard.error() == 0 && errno == ENOENT);
        throw 1;
    } catch (int) {}
    assert(!blocked() && errno == ENOENT);
    return 0;
}
