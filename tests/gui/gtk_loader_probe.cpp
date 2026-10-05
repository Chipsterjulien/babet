#include "gui_gtk_loader.hpp"
#include "process_state.hpp"

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <latch>
#include <string>
#include <string_view>
#include <thread>

extern "C" int babet_test_mutation_allowed()
{
    bool called = false;
    const bool accepted = with_process_env_lock([&]() { called = true; });
    return accepted && called;
}

extern "C" void *__real_dlopen(const char *, int);
extern "C" void *__wrap_dlopen(const char *name, int flags)
{
    if (std::getenv("BABET_TEST_GTK_LOAD_FAILURE")) return nullptr;
    return __real_dlopen(name, flags);
}

static bool frozen()
{
    bool read = false;
    return !babet_test_mutation_allowed() &&
        babet_runtime::with_process_state_lock(false, [&]() { read = true; }) && read;
}

static int concurrent_freeze()
{
    // Exception unwinding must release the lock, then freeze must wait for an
    // already-running mutation before it can publish the permanent state.
    try { with_process_env_lock([]() { throw 42; }); }
    catch (int value) { if (value != 42) return 70; }
    if (!babet_test_mutation_allowed()) return 71;
    std::latch entered(1), freezing(1), release(1);
    std::atomic_bool mutation_finished{false}, freeze_observed_finish{false};
    std::thread mutation([&]() {
        if (!with_process_env_lock([&]() {
            entered.count_down(); release.wait(); mutation_finished = true;
        })) std::abort();
    });
    entered.wait();
    std::thread freezer([&]() {
        freezing.count_down(); babet_runtime::freeze_process_state();
        freeze_observed_finish = mutation_finished.load();
    });
    freezing.wait(); release.count_down();
    mutation.join(); freezer.join();
    if (!freeze_observed_finish || !frozen()) return 72;
    babet_runtime::freeze_process_state(); // idempotent, never thawed
    if (!frozen()) return 73;
    std::cout << "CONCURRENT_FREEZE_OK\n";
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2)
        return 64;

    const std::string_view mode(argv[1]);
    if (!babet_test_mutation_allowed()) return 69;
    if (mode == "concurrent-freeze") return concurrent_freeze();
    std::string error;
    if (mode == "load")
    {
        const bool loaded = babet_gui::detail::gtk4_load(error);
        if (!frozen()) return 71;
        if (loaded)
        {
            std::cout << "LOAD_OK\n";
            return 0;
        }
        std::cout << "LOAD_FAIL " << error << "\n";
        return 2;
    }
    if (mode == "init")
    {
        const bool initialized = babet_gui::detail::gtk4_initialize(error);
        if (!frozen()) return 71;
        if (initialized)
        {
            std::cout << "INIT_OK\n";
            return 0;
        }
        std::cout << "INIT_FAIL " << error << "\n";
        return 3;
    }
    if (mode == "load-twice")
    {
        std::string first_error;
        if (babet_gui::detail::gtk4_load(first_error))
            return 5;

        std::string second_error;
        if (babet_gui::detail::gtk4_load(second_error))
            return 6;

        if (first_error != second_error)
            return 7;
        if (!frozen()) return 71;

        std::cout << "LOAD_TWICE_FAIL " << second_error << "\n";
        return 4;
    }
    return 64;
}
