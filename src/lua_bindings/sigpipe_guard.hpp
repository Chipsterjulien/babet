#ifndef BABET_SIGPIPE_GUARD_HPP
#define BABET_SIGPIPE_GUARD_HPP

#include <cerrno>
#include <csignal>
#include <pthread.h>
#include <time.h>

namespace babet_io
{
// OpenSSL's socket BIO can write during connect/read/write/shutdown. Block
// SIGPIPE only in this thread, preserving the process-wide disposition and
// any signal already pending on entry. No Lua longjmp may cross this scope.
class SigpipeGuard
{
public:
    SigpipeGuard() noexcept
    {
        const int saved_errno = errno;
        ::sigemptyset(&pipe_set_);
        ::sigaddset(&pipe_set_, SIGPIPE);
        error_ = ::pthread_sigmask(SIG_BLOCK, &pipe_set_, &old_mask_);
        if (error_ == 0)
        {
            sigset_t pending;
            if (::sigpending(&pending) != 0)
            {
                error_ = errno;
                ::pthread_sigmask(SIG_SETMASK, &old_mask_, nullptr);
            }
            else
            {
                pending_before_ = ::sigismember(&pending, SIGPIPE) == 1;
                active_ = true;
            }
        }
        errno = saved_errno;
    }

    ~SigpipeGuard() noexcept
    {
        if (!active_)
            return;
        const int saved_errno = errno;
        if (!pending_before_)
        {
            // TLS can hide EPIPE behind an SSL error, or generate it while
            // closing an otherwise successful HTTP request. Drain the newly
            // pending signal without waiting, before restoring the mask.
            const struct timespec no_wait{};
            while (::sigtimedwait(&pipe_set_, nullptr, &no_wait) < 0 &&
                   errno == EINTR)
            {
            }
        }
        ::pthread_sigmask(SIG_SETMASK, &old_mask_, nullptr);
        errno = saved_errno;
    }

    SigpipeGuard(const SigpipeGuard &) = delete;
    SigpipeGuard &operator=(const SigpipeGuard &) = delete;
    int error() const noexcept { return error_; }

private:
    sigset_t pipe_set_{};
    sigset_t old_mask_{};
    int error_ = 0;
    bool active_ = false;
    bool pending_before_ = false;
};

// The wrapper leaves errno and OpenSSL's error queue available to the caller
// of SSL_get_error, and never executes unprotected I/O if masking failed.
template <typename Operation>
int without_sigpipe(Operation operation)
{
    SigpipeGuard guard;
    if (guard.error() != 0)
    {
        errno = guard.error();
        return -1;
    }
    return operation();
}
} // namespace babet_io

#endif // BABET_SIGPIPE_GUARD_HPP
