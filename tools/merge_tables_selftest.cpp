#include "mergeTables.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <new>

namespace
{
bool forbid_cpp_allocation = false;
bool count_next = false;
std::size_t next_calls = 0;
int source_mutation = 0;
struct Allocator
{
    bool count = false, fail = false;
    std::size_t calls = 0, budget = 0, live_bytes = 0;
};
Allocator *allocator;
bool inject_failure = false;
std::size_t requested_budget = 0;
std::size_t oom_runs = 0;
}

void *operator new(std::size_t size)
{
    if (forbid_cpp_allocation)
    {
        std::fputs("[FAIL] mergeTables allocated storage outside Lua\n", stderr);
        std::abort();
    }
    void *p = std::malloc(size ? size : 1);
    if (!p) throw std::bad_alloc();
    return p;
}
void operator delete(void *p) noexcept { std::free(p); }
void *operator new[](std::size_t size) { return ::operator new(size); }
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t) noexcept { ::operator delete(p); }

extern "C" int __real_lua_next(lua_State *, int);
extern "C" int __wrap_lua_next(lua_State *L, int index)
{
    if (count_next) ++next_calls;
    return __real_lua_next(L, index);
}
extern "C" void *__real_lua_newuserdatauv(lua_State *, std::size_t, int);
extern "C" void *__wrap_lua_newuserdatauv(lua_State *L, std::size_t size, int values)
{
    const int mutation = source_mutation;
    source_mutation = 0;
    // Deterministically simulate a finalizer changing the source between
    // the count pass and scratch allocation, without depending on GC timing.
    if (mutation > 0)
        for (int key = 5; key < 30; key += 2)
        { lua_pushinteger(L, key); lua_rawseti(L, 1, key); }
    if (mutation < 0)
    { lua_pushnil(L); lua_rawseti(L, 1, 1); }
    return __real_lua_newuserdatauv(L, size, values);
}

namespace
{
void *allocate(void *userdata, void *p, std::size_t old_size, std::size_t size)
{
    auto &state = *static_cast<Allocator *>(userdata);
    if (size == 0)
    {
        if (p) state.live_bytes -= old_size;
        std::free(p); return nullptr;
    }
    if (!p || size > old_size)
    {
        if (state.count) ++state.calls;
        if (state.fail && state.budget == 0) return nullptr;
        if (state.fail) --state.budget;
    }
    const std::size_t previous = p ? old_size : 0;
    void *next = std::realloc(p, size);
    if (next) state.live_bytes = state.live_bytes - previous + size;
    return next;
}
int invoke(lua_State *L)
{
    allocator->count = true;
    allocator->fail = inject_failure;
    allocator->budget = requested_budget;
    forbid_cpp_allocation = count_next = true;
    return lua_mergeTables(L);
}

bool profile(bool sparse, int size, bool fail, std::size_t budget,
             std::size_t &allocations, std::size_t &iterations, int mutation = 0)
{
    Allocator state; allocator = &state;
    lua_State *L = lua_newstate(allocate, &state, 0xBA8E7215u);
    if (!L) return false;
    lua_pushcfunction(L, invoke);
    lua_newtable(L);
    for (int i = 1; i <= size; ++i)
    {
        const int key = sparse ? i * 2 - 1 : i;
        lua_pushinteger(L, key); lua_rawseti(L, 2, key);
    }
    lua_pushliteral(L, "map-value"); lua_setfield(L, 2, "label");
    lua_newtable(L);
    next_calls = 0;
    source_mutation = mutation;
    inject_failure = fail; requested_budget = budget;
    const int status = lua_pcall(L, 2, 1, 0);
    forbid_cpp_allocation = count_next = state.count = state.fail = false;
    source_mutation = 0;
    allocations = state.calls; iterations = next_calls;
    bool ok = fail ? status == LUA_ERRMEM : status == LUA_OK;
    if (fail) ++oom_runs;
    if (ok && !fail)
    {
        const int expected_size = mutation > 0 ? 15 : mutation < 0 ? 1 : size;
        ok = lua_rawlen(L, 1) == static_cast<std::size_t>(expected_size);
        for (int i = 1; i <= expected_size && ok; ++i)
        {
            lua_rawgeti(L, 1, i);
            const int expected = mutation < 0 ? 3 : sparse ? i * 2 - 1 : i;
            ok = lua_tointeger(L, -1) == expected;
            lua_pop(L, 1);
        }
        lua_getfield(L, 1, "label");
        ok = ok && lua_isstring(L, -1) && std::strcmp(lua_tostring(L, -1), "map-value") == 0;
    }
    lua_close(L);
    ok = ok && state.live_bytes == 0;
    if (!ok)
        std::fprintf(stderr, "[FAIL] mergeTables: sparse=%d size=%d fail=%d budget=%zu "
                     "status=%d leaked Lua bytes=%zu mutation=%d\n",
                     sparse, size, fail, budget, status, state.live_bytes, mutation);
    return ok;
}

bool contracts(const char *file)
{
    Allocator state;
    lua_State *L = lua_newstate(allocate, &state, 0xBA8E7215u);
    if (!L) return false;
    luaL_openlibs(L);
    lua_newtable(L); lua_pushcfunction(L, lua_mergeTables); lua_setfield(L, -2, "mergeTables");
    lua_setglobal(L, "babet");
    const int status = luaL_dofile(L, file);
    if (status != LUA_OK) std::fprintf(stderr, "[FAIL] %s\n", lua_tostring(L, -1));
    lua_close(L);
    return status == LUA_OK && state.live_bytes == 0;
}
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    if (!contracts(argv[1])) return 1;
    for (bool sparse : {false, true})
    {
        std::size_t allocations = 0, iterations = 0, unused1 = 0, unused2 = 0;
        if (!profile(sparse, 4096, false, 0, allocations, iterations)) return 1;
        if (iterations > 4 * 4096 + 20)
        {
            std::fprintf(stderr, "[FAIL] mergeTables quadratic traversal: %zu lua_next calls\n", iterations);
            return 1;
        }
        std::printf("[PASS] %s traversal: %zu lua_next calls for 4096 elements\n",
                    sparse ? "sparse" : "dense", iterations);
        if (!profile(sparse, 128, false, 0, allocations, iterations) || allocations == 0) return 1;
        for (std::size_t budget = 0; budget < allocations; ++budget)
            if (!profile(sparse, 128, true, budget, unused1, unused2)) return 1;
    }
    for (int mutation : {1, -1})
    {
        std::size_t allocations = 0, iterations = 0, unused1 = 0, unused2 = 0;
        if (!profile(true, 2, false, 0, allocations, iterations, mutation)) return 1;
        for (std::size_t budget = 0; budget < allocations; ++budget)
            if (!profile(true, 2, true, budget, unused1, unused2, mutation)) return 1;
    }
    std::puts("[PASS] source growth/shrink at allocation boundary remains bounded");
    std::printf("mergeTables OOM: %zu failure points / 0 leaked Lua bytes\n", oom_runs);
    return 0;
}
