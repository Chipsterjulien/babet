#include "deepCopyTable.hpp"
#include "exec.hpp"
#include "listFiles.hpp"
#include "lua_utils.hpp"

#include <lua.hpp>

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <limits>
#include <new>
#include <string>
#include <system_error>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace
{
struct AllocatorState
{
    bool fail_growth = false;
    bool count_growth = false;
    std::size_t growth_budget = std::numeric_limits<std::size_t>::max();
    std::size_t growth_count = 0;
};

void *test_allocator(void *userdata, void *pointer, std::size_t old_size,
                     std::size_t new_size)
{
    auto *state = static_cast<AllocatorState *>(userdata);
    if (new_size == 0)
    {
        std::free(pointer);
        return nullptr;
    }

    if (new_size > old_size)
    {
        if (state->count_growth)
            ++state->growth_count;

        // Lua may retry a failed allocation after an emergency full GC.
        // Once the budget reaches zero, reject every subsequent growth until
        // the enclosing lua_pcall has returned.
        if (state->fail_growth)
        {
            if (state->growth_budget == 0)
                return nullptr;
            --state->growth_budget;
        }
    }
    return std::realloc(pointer, new_size);
}

AllocatorState *allocator_state = nullptr;
std::size_t requested_growth_budget = 0;
std::size_t measured_deepcopy_growth = 0;
bool stack_owner_destroyed = false;
bool userdata_owner_destroyed = false;
bool setup_owner_destroyed = false;

void disable_allocator_failure() noexcept
{
    allocator_state->fail_growth = false;
    allocator_state->count_growth = false;
    allocator_state->growth_budget =
        std::numeric_limits<std::size_t>::max();
}

lua_State *new_test_state(AllocatorState &state)
{
    state = AllocatorState{};
    allocator_state = &state;
    return lua_newstate(test_allocator, &state, 0xBA8E7215u);
}

struct StackOwner
{
    ~StackOwner() noexcept { stack_owner_destroyed = true; }
};

int protected_oom_impl(lua_State *L)
{
    StackOwner owner;
    static const std::string payload(1024 * 1024, 'x');
    auto builder = [](lua_State *Ls) noexcept -> int
    {
        allocator_state->fail_growth = true;
        allocator_state->growth_budget = 0;
        lua_pushlstring(Ls, payload.data(), payload.size());
        return 1;
    };
    return lua_build_results_protected(L, builder, 1);
}

int protected_oom(lua_State *L)
{
    return lua_cfunction_exception_boundary<protected_oom_impl>(
        L, "oom", "internal", "unknown");
}

struct UserdataOwner
{
    ~UserdataOwner() noexcept { userdata_owner_destroyed = true; }
};

int userdata_gc(lua_State *L)
{
    auto *owner = static_cast<UserdataOwner *>(lua_touserdata(L, 1));
    owner->~UserdataOwner();
    return 0;
}

int userdata_oom(lua_State *L)
{
    void *storage = lua_newuserdatauv(L, sizeof(UserdataOwner), 0);
    new (storage) UserdataOwner();
    luaL_getmetatable(L, "babet.oom.owner");
    lua_setmetatable(L, -2);

    static const std::string payload(1024 * 1024, 'y');
    allocator_state->fail_growth = true;
    allocator_state->growth_budget = 0;
    lua_pushlstring(L, payload.data(), payload.size());
    return 1;
}

bool run_protected_oom(lua_State *L)
{
    stack_owner_destroyed = false;
    lua_pushcfunction(L, protected_oom);
    const int status = lua_pcall(L, 0, 1, 0);
    disable_allocator_failure();
    lua_settop(L, 0);
    return status == LUA_ERRMEM && stack_owner_destroyed;
}

bool run_userdata_oom(lua_State *L)
{
    userdata_owner_destroyed = false;
    lua_pushcfunction(L, userdata_oom);
    const int status = lua_pcall(L, 0, 1, 0);
    disable_allocator_failure();
    lua_settop(L, 0);
    lua_gc(L, LUA_GCCOLLECT);
    return status == LUA_ERRMEM && userdata_owner_destroyed;
}

struct SetupOwner
{
    ~SetupOwner() noexcept { setup_owner_destroyed = true; }
};


bool run_argument_forwarding(lua_State *L)
{
    lua_settop(L, 0);
    lua_pushliteral(L, "alpha");
    lua_pushinteger(L, 42);
    lua_createtable(L, 0, 1);
    lua_pushliteral(L, "value");
    lua_setfield(L, -2, "key");

    bool saw_original_frame = false;
    auto operation = [&](lua_State *Ls)
    {
        saw_original_frame =
            lua_gettop(Ls) == 3 &&
            lua_isstring(Ls, 1) &&
            std::strcmp(lua_tostring(Ls, 1), "alpha") == 0 &&
            lua_isinteger(Ls, 2) && lua_tointeger(Ls, 2) == 42 &&
            lua_istable(Ls, 3);
        lua_getfield(Ls, 3, "key");
        saw_original_frame =
            saw_original_frame && lua_isstring(Ls, -1) &&
            std::strcmp(lua_tostring(Ls, -1), "value") == 0;
        lua_pop(Ls, 1);
    };

    lua_run_protected(L, operation);
    const bool caller_stack_preserved =
        lua_gettop(L) == 3 && lua_isstring(L, 1) &&
        lua_isinteger(L, 2) && lua_istable(L, 3);
    lua_settop(L, 0);
    return saw_original_frame && caller_stack_preserved;
}

bool run_setup_oom(lua_State *L)
{
    setup_owner_destroyed = false;
    bool failed_cleanly = false;
    {
        SetupOwner owner;
        static const std::string payload(1024 * 1024, 's');
        auto operation = [](lua_State *state)
        {
            allocator_state->fail_growth = true;
            allocator_state->growth_budget = 0;
            lua_pushlstring(state, payload.data(), payload.size());
            lua_pop(state, 1);
        };
        std::string error;
        failed_cleanly = !lua_run_setup_protected(
            L, operation, "setup OOM", error);
        disable_allocator_failure();
        lua_settop(L, 0);
        failed_cleanly = failed_cleanly && !error.empty();
    }
    return failed_cleanly && setup_owner_destroyed;
}

int arm_exec_oom(lua_State *L)
{
    allocator_state->fail_growth = true;
    allocator_state->growth_budget = 0;
    return lua_exec(L);
}

bool run_exec_oom(lua_State *L)
{
    lua_settop(L, 0);
    lua_pushcfunction(L, arm_exec_oom);
    lua_pushliteral(L, "/bin/sh");
    lua_createtable(L, 2, 0);
    lua_pushliteral(L, "-c");
    lua_rawseti(L, -2, 1);
    lua_pushliteral(
        L, "head -c 1048576 /dev/zero | tr '\\000' x");
    lua_rawseti(L, -2, 2);

    const int status = lua_pcall(L, 2, LUA_MULTRET, 0);
    disable_allocator_failure();

    // The protected reporter normally re-raises LUA_ERRMEM because the
    // allocator remains armed. If its short diagnostic was already interned,
    // a regular (nil, err) result is also acceptable: in both cases all exec
    // owners have already unwound before Lua is touched again. ASan/LSan makes
    // the old direct-result implementation fail by detecting its leaked output
    // buffers.
    bool ok = status == LUA_ERRMEM;
    if (status == LUA_OK)
    {
        ok = lua_gettop(L) == 2 && lua_isnil(L, 1) &&
             lua_isstring(L, 2);
    }
    lua_settop(L, 0);
    return ok;
}

std::size_t count_open_fds()
{
    DIR *directory = ::opendir("/proc/self/fd");
    if (directory == nullptr)
        return std::numeric_limits<std::size_t>::max();

    std::size_t count = 0;
    while (dirent *entry = ::readdir(directory))
    {
        if (std::strcmp(entry->d_name, ".") != 0 &&
            std::strcmp(entry->d_name, "..") != 0)
        {
            ++count;
        }
    }
    ::closedir(directory);
    return count;
}

int arm_list_files_oom(lua_State *L)
{
    allocator_state->fail_growth = true;
    allocator_state->growth_budget = requested_growth_budget;
    return lua_listFiles(L);
}

bool prepare_directory_fixture(fs::path &directory)
{
    char pattern[] = "/tmp/babet-listfiles-oom.XXXXXX";
    char *created = ::mkdtemp(pattern);
    if (created == nullptr)
        return false;
    directory = created;

    try
    {
        for (int i = 0; i < 24; ++i)
        {
            const std::string name =
                "entry_" + std::to_string(i) + "_" +
                std::string(180, static_cast<char>('a' + (i % 26)));
            std::ofstream file(directory / name, std::ios::binary);
            file << "x";
            if (!file)
                return false;
        }
    }
    catch (...)
    {
        return false;
    }
    return true;
}

bool run_list_files_oom(const fs::path &directory)
{
    const std::size_t fd_baseline = count_open_fds();
    if (fd_baseline == std::numeric_limits<std::size_t>::max())
        return false;

    int oom_runs = 0;
    for (std::size_t budget = 0; budget <= 24; ++budget)
    {
        AllocatorState state;
        lua_State *L = new_test_state(state);
        if (L == nullptr)
            return false;

        requested_growth_budget = budget;
        lua_pushcfunction(L, arm_list_files_oom);
        const std::string path = directory.string();
        lua_pushlstring(L, path.data(), path.size());
        lua_pushboolean(L, 0);
        const int status = lua_pcall(L, 2, LUA_MULTRET, 0);
        disable_allocator_failure();
        if (status != LUA_OK ||
            (lua_gettop(L) >= 1 && lua_isnil(L, 1)))
        {
            ++oom_runs;
        }
        lua_settop(L, 0);
        lua_close(L);

        if (count_open_fds() != fd_baseline)
            return false;
    }

    // Several budgets must reach a Lua allocation failure; otherwise the FD
    // invariant would not actually have been exercised.
    return oom_runs >= 3;
}

void build_deepcopy_fixture(lua_State *L)
{
    lua_newtable(L); // root
    const int root = lua_absindex(L, -1);
    int parent = root;

    for (int depth = 0; depth < 12; ++depth)
    {
        lua_newtable(L);
        const int child = lua_absindex(L, -1);
        lua_pushinteger(L, depth);
        lua_setfield(L, child, "depth");
        lua_pushvalue(L, child);
        lua_setfield(L, parent, "child");
        parent = child;
    }

    // Close a cycle at the deepest level, then remove the temporary child
    // tables while retaining the root and its full chain.
    lua_pushvalue(L, root);
    lua_setfield(L, parent, "root");
    lua_settop(L, root);
}

int count_deepcopy_growth(lua_State *L)
{
    allocator_state->growth_count = 0;
    allocator_state->count_growth = true;
    const int result = lua_deepCopyTable(L);
    allocator_state->count_growth = false;
    measured_deepcopy_growth = allocator_state->growth_count;
    return result;
}

int arm_deepcopy_oom(lua_State *L)
{
    allocator_state->fail_growth = true;
    allocator_state->growth_budget = requested_growth_budget;
    return lua_deepCopyTable(L);
}

bool prepare_ref_baseline(lua_State *L, int &baseline)
{
    lua_pushinteger(L, 12345);
    baseline = luaL_ref(L, LUA_REGISTRYINDEX);
    if (baseline == LUA_NOREF || baseline == LUA_REFNIL)
        return false;
    luaL_unref(L, LUA_REGISTRYINDEX, baseline);
    return true;
}

bool measure_deepcopy_growth_count(std::size_t &growth_count)
{
    AllocatorState state;
    lua_State *L = new_test_state(state);
    if (L == nullptr)
        return false;

    build_deepcopy_fixture(L);
    int baseline = LUA_NOREF;
    if (!prepare_ref_baseline(L, baseline))
    {
        lua_close(L);
        return false;
    }

    lua_pushcfunction(L, count_deepcopy_growth);
    lua_pushvalue(L, 1);
    const int status = lua_pcall(L, 1, 1, 0);
    disable_allocator_failure();
    growth_count = measured_deepcopy_growth;
    lua_close(L);
    return status == LUA_OK && growth_count >= 4;
}

std::size_t count_registry_table_refs(lua_State *L, int first_ref)
{
    std::size_t count = 0;
    lua_pushnil(L);
    while (lua_next(L, LUA_REGISTRYINDEX) != 0)
    {
        if (lua_isinteger(L, -2) &&
            lua_tointeger(L, -2) >= static_cast<lua_Integer>(first_ref) &&
            lua_istable(L, -1))
        {
            ++count;
        }
        lua_pop(L, 1);
    }
    return count;
}

bool run_one_deepcopy_oom(std::size_t budget)
{
    AllocatorState state;
    lua_State *L = new_test_state(state);
    if (L == nullptr)
        return false;

    build_deepcopy_fixture(L);
    int baseline = LUA_NOREF;
    if (!prepare_ref_baseline(L, baseline))
    {
        lua_close(L);
        return false;
    }

    requested_growth_budget = budget;
    lua_pushcfunction(L, arm_deepcopy_oom);
    lua_pushvalue(L, 1);
    const int status = lua_pcall(L, 1, LUA_MULTRET, 0);
    disable_allocator_failure();
    const bool failed = status != LUA_OK ||
                        (lua_gettop(L) >= 3 && lua_isnil(L, 2));
    if (!failed)
    {
        lua_close(L);
        return false;
    }

    lua_settop(L, 1); // retain only the original fixture
    // luaL_unref turns each released registry slot into an integer free-list
    // link. A copied table still present at or above the first public ref is
    // therefore an unambiguous leaked deepCopyTable reference, independent of
    // the unordered_map cleanup order.
    const bool refs_released = count_registry_table_refs(L, baseline) == 0;
    lua_close(L);
    return refs_released;
}

bool run_deepcopy_oom()
{
    std::size_t total_growth = 0;
    if (!measure_deepcopy_growth_count(total_growth))
        return false;

    // Fail late enough that several destination tables and registry
    // references already exist. The exact allocation profile can vary across
    // Lua builds, so exercise the final three growth points.
    const std::size_t first_budget = total_growth > 3 ? total_growth - 3 : 0;
    for (std::size_t budget = first_budget; budget < total_growth; ++budget)
    {
        if (!run_one_deepcopy_oom(budget))
            return false;
    }
    return true;
}
} // namespace

int main()
{
    AllocatorState state;
    lua_State *L = new_test_state(state);
    if (L == nullptr)
        return 2;

    if (luaL_newmetatable(L, "babet.oom.owner"))
    {
        lua_pushcfunction(L, userdata_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);

    const bool protected_ok = run_protected_oom(L);
    const bool userdata_ok = run_userdata_oom(L);
    const bool forwarding_ok = run_argument_forwarding(L);
    const bool setup_ok = run_setup_oom(L);
    const bool exec_ok = run_exec_oom(L);
    lua_close(L);

    fs::path directory;
    const bool fixture_ok = prepare_directory_fixture(directory);
    const bool list_files_ok = fixture_ok && run_list_files_oom(directory);
    std::error_code cleanup_error;
    if (fixture_ok)
        fs::remove_all(directory, cleanup_error);

    const bool deep_copy_ok = run_deepcopy_oom();

    if (!protected_ok || !userdata_ok || !forwarding_ok || !setup_ok ||
        !exec_ok || !list_files_ok || !deep_copy_ok)
    {
        std::fprintf(
            stderr,
            "[FAIL] Lua OOM cleanup: protected=%d userdata=%d "
            "forwarding=%d setup=%d exec=%d listFiles=%d "
            "deepCopyTable=%d\n",
            protected_ok ? 1 : 0, userdata_ok ? 1 : 0,
            forwarding_ok ? 1 : 0, setup_ok ? 1 : 0, exec_ok ? 1 : 0,
            list_files_ok ? 1 : 0,
            deep_copy_ok ? 1 : 0);
        return 1;
    }

    std::puts("[PASS] Lua OOM longjmp cleans generic RAII, forwards "
              "protected parser arguments, runtime setup, userdata, exec "
              "buffers, listFiles iterators and deepCopyTable registry refs");
    return 0;
}
