#include "babet/plugin.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <pthread.h>
#include <sched.h>
#include <unistd.h>

namespace
{
std::atomic<bool> running{false};

void at_exit() { std::fputs("NATIVE_ATEXIT\n", stderr); }
struct StaticProbe
{
    ~StaticProbe() { std::fputs("NATIVE_DESTRUCTOR\n", stderr); }
} probe;

void *native_thread(void *)
{
    running.store(true, std::memory_order_release);
    for (;;) ::pause();
    return nullptr;
}

babet_status start(babet_host_call *, void *) noexcept
{
    pthread_t thread;
    if (::pthread_create(&thread, nullptr, native_thread, nullptr) != 0)
        return BABET_STATUS_INTERNAL_ERROR;
    // A process-exit fixture, intentionally alive until the process stops.
    (void)::pthread_detach(thread);
    while (!running.load(std::memory_order_acquire)) ::sched_yield();
    std::fputs("NATIVE_THREAD_READY\n", stderr);
    return BABET_STATUS_OK;
}

const babet_plugin_function_v1 functions[] = {
    {{"start", sizeof("start") - 1}, start, nullptr},
};
const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    static_cast<uint32_t>(sizeof(babet_plugin_descriptor_v1)),
    static_cast<uint32_t>(sizeof(babet_plugin_function_v1)),
    0,
    {"exit-probe", sizeof("exit-probe") - 1},
    {"1.0.0", sizeof("1.0.0") - 1},
    functions, 1,
};
}

extern "C" const babet_plugin_descriptor_v1 *babet_plugin_query_v1() noexcept
{
    if (std::atexit(at_exit) != 0) return nullptr;
    return &descriptor;
}
