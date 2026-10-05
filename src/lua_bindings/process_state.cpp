#include "process_state.hpp"

#include <mutex>

namespace
{
std::mutex process_state_mutex;
bool process_state_frozen = false;
}

void babet_runtime::freeze_process_state()
{
    std::lock_guard<std::mutex> lock(process_state_mutex);
    process_state_frozen = true;
}

bool babet_runtime::with_process_state_lock(
    bool mutation, const std::function<void()> &fn)
{
    std::lock_guard<std::mutex> lock(process_state_mutex);
    if (mutation && process_state_frozen)
        return false;
    fn();
    return true;
}

bool with_process_env_lock(const std::function<void()> &fn)
{
    return babet_runtime::with_process_state_lock(true, fn);
}
