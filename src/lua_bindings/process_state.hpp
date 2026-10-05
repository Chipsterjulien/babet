#ifndef BABET_PROCESS_STATE_HPP
#define BABET_PROCESS_STATE_HPP

#include <functional>

namespace babet_runtime
{
// Irreversible for this process. Call before creating workers or entering
// dlopen(GTK): even a failed load/init can leave native threads/state behind.
// The lock is released before any native initializer or Lua callback runs.
void freeze_process_state();

// Queries may run after freezing. Mutation and freeze share one mutex, so an
// in-flight mutation finishes before freeze returns. fn must not call Lua or
// re-enter this guard; throwing a C++ exception releases the lock normally.
bool with_process_state_lock(bool mutation, const std::function<void()> &fn);
}

// Existing setenv/chdir call sites use the mutation-only form.
bool with_process_env_lock(const std::function<void()> &fn);

#endif
