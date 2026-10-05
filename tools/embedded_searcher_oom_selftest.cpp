#include "project_core/embedded_searcher.hpp"
#include "project_core/zip_utils.hpp"

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <stdexcept>

// Track C++ buffers independently of LeakSanitizer. Lua uses its separate
// realloc-based allocator, so a nonzero count after lua_pcall is evidence of
// a C++ owner skipped by longjmp, even on hosts without leak detection.
namespace
{
bool track_cpp = false;
bool fail_cpp = false;
std::size_t cpp_budget = 0;
std::size_t cpp_calls = 0;
std::size_t cpp_live = 0;
struct alignas(std::max_align_t) Allocation { bool tracked; };
}

void *operator new(std::size_t size)
{
    if (track_cpp)
    {
        ++cpp_calls;
        if (fail_cpp && cpp_budget == 0) throw std::bad_alloc();
        if (fail_cpp) --cpp_budget;
    }
    if (size > std::numeric_limits<std::size_t>::max() - sizeof(Allocation))
        throw std::bad_alloc();
    auto *allocation = static_cast<Allocation *>(std::malloc(sizeof(Allocation) + size));
    if (!allocation) throw std::bad_alloc();
    allocation->tracked = track_cpp;
    if (allocation->tracked) ++cpp_live;
    return allocation + 1;
}
void operator delete(void *pointer) noexcept
{
    if (!pointer) return;
    auto *allocation = static_cast<Allocation *>(pointer) - 1;
    if (allocation->tracked) --cpp_live;
    std::free(allocation);
}
void *operator new[](std::size_t size) { return ::operator new(size); }
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t) noexcept { ::operator delete(p); }

namespace
{
enum class Scenario { present, init, missing, read_error, syntax, native_error, unknown_error };
const char *scenario_name(Scenario value)
{
    static const char *const names[] = {
        "module.lua", "module/init.lua", "missing", "read error", "syntax error",
        "native exception", "unknown native exception"};
    return names[static_cast<int>(value)];
}
Scenario scenario;
constexpr const char *module_name =
    "fixture.module_with_a_long_name_that_must_allocate_both_candidate_paths_and_loader_data";
struct LuaAllocator
{
    bool count = false;
    bool fail = false;
    std::size_t budget = 0;
    std::size_t calls = 0;
};
LuaAllocator *allocator;
enum class Failure { none, lua, cpp };
Failure failure;
std::size_t budget;
std::size_t runs = 0;

void *lua_allocator(void *userdata, void *pointer, std::size_t old_size, std::size_t size)
{
    auto &state = *static_cast<LuaAllocator *>(userdata);
    if (size == 0) { std::free(pointer); return nullptr; }
    if (!pointer || size > old_size)
    {
        if (state.count) ++state.calls;
        // Lua retries after emergency GC: keep refusing until pcall returns.
        if (state.fail && state.budget == 0) return nullptr;
        if (state.fail) --state.budget;
    }
    return std::realloc(pointer, size);
}

int invoke_searcher(lua_State *L)
{
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushvalue(L, 1);
    cpp_calls = 0;
    cpp_budget = budget;
    fail_cpp = failure == Failure::cpp;
    track_cpp = true;
    allocator->count = true;
    allocator->fail = failure == Failure::lua;
    allocator->budget = budget;
    lua_call(L, 1, LUA_MULTRET);
    return lua_gettop(L) - 1; // leave the original module argument behind
}

bool one_run(Scenario current, Failure injection, std::size_t allowance,
             std::size_t &lua_calls, std::size_t &native_calls)
{
    LuaAllocator state;
    allocator = &state;
    scenario = current;
    failure = injection;
    budget = allowance;
    lua_State *L = lua_newstate(lua_allocator, &state, 0xBA8E7215u);
    if (!L) return false;
    luaL_openlibs(L);
    register_embedded_searcher(L, "fixture-executable");
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "searchers");
    lua_rawgeti(L, -1, 2);
    lua_pushcclosure(L, invoke_searcher, 1);
    lua_replace(L, 1);
    lua_settop(L, 1);
    lua_pushstring(L, module_name);
    const int status = lua_pcall(L, 1, LUA_MULTRET, 0);
    track_cpp = fail_cpp = state.count = state.fail = false;
    lua_calls = state.calls;
    native_calls = cpp_calls;
    ++runs;
    bool ok = cpp_live == 0;
    if (injection == Failure::lua)
        ok = ok && status == LUA_ERRMEM;
    else if (injection == Failure::cpp)
        ok = ok && status == LUA_ERRRUN && lua_isstring(L, -1) &&
            std::strstr(lua_tostring(L, -1), "out of memory");
    else if (current == Scenario::missing)
        ok = ok && status == LUA_OK && lua_gettop(L) == 1 &&
            std::strstr(lua_tostring(L, -1), "no embedded file");
    else if (current == Scenario::syntax || current == Scenario::native_error ||
             current == Scenario::unknown_error)
        ok = ok && status == LUA_ERRRUN && lua_isstring(L, -1);
    else
    {
        ok = ok && status == LUA_OK && lua_gettop(L) == 2 &&
            lua_isfunction(L, 1) && lua_isstring(L, 2);
        if (ok)
        {
            const char *path = lua_tostring(L, 2);
            ok = current == Scenario::init ? std::strstr(path, "/init.lua") != nullptr
                                          : std::strstr(path, "/init.lua") == nullptr;
            lua_settop(L, 1);
            const int loaded = lua_pcall(L, 0, 1, 0);
            if (current == Scenario::read_error)
                ok = ok && loaded == LUA_ERRRUN &&
                    std::strstr(lua_tostring(L, -1), "fixture read failure");
            else
                ok = ok && loaded == LUA_OK && lua_tointeger(L, -1) == 42;
        }
    }
    if (!ok)
        std::fprintf(stderr, "[FAIL] embedded loader: scenario=%d injection=%d budget=%zu "
                     "status=%d leaked_cpp_buffers=%zu message=%s\n", static_cast<int>(current),
                     static_cast<int>(injection), allowance, status, cpp_live,
                     lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "(not a string)");
    // The state remains usable after a caught allocation error.
    lua_settop(L, 0);
    if (luaL_dostring(L, "return 6 * 7") != LUA_OK || lua_tointeger(L, -1) != 42)
        ok = false;
    lua_close(L);
    return ok;
}

bool require_contract(Scenario current)
{
    LuaAllocator state;
    allocator = &state;
    scenario = current;
    lua_State *L = lua_newstate(lua_allocator, &state, 0xBA8E7215u);
    if (!L) return false;
    luaL_openlibs(L);
    register_embedded_searcher(L, "fixture-executable");
    lua_pushstring(L, module_name); lua_setglobal(L, "fixture_name");
    lua_pushboolean(L, current == Scenario::missing); lua_setglobal(L, "expect_fallback");
    lua_pushboolean(L, current == Scenario::present || current == Scenario::init ||
                       current == Scenario::missing); lua_setglobal(L, "expect_success");
    track_cpp = true;
    const int first = luaL_dostring(L,
        "local fallback=false; package.searchers={package.searchers[2],function() "
        "fallback=true; return function() return 88 end end}; "
        "local ok,value=pcall(require,fixture_name); assert(ok==expect_success,tostring(value)); "
        "assert(fallback==expect_fallback); "
        "if ok then assert(value==(expect_fallback and 88 or 42)) "
        "else assert(type(value)=='string' and #value>0) end; package.loaded[fixture_name]=nil");
    track_cpp = false;
    bool ok = first == LUA_OK && cpp_live == 0;
    // A failed require must not poison a subsequent attempt in this state.
    scenario = Scenario::present;
    lua_settop(L, 0);
    track_cpp = true;
    const int retry = luaL_dostring(L, "assert(require(fixture_name)==42)");
    track_cpp = false;
    ok = ok && retry == LUA_OK && cpp_live == 0;
    lua_close(L);
    std::printf("[%s] require %s: fallback policy and retry\n", ok ? "PASS" : "FAIL",
                scenario_name(current));
    return ok;
}
}

// Only archive I/O is replaced. The real searcher and Lua parser allocate,
// compile, build closures and propagate errors exactly as in the runtime.
std::optional<std::vector<char>> readEmbeddedFile(
    const std::string &, const std::string &path, std::string *error,
    const EmbeddedImageLayout *)
{
    if (scenario == Scenario::native_error) throw std::runtime_error("fixture native failure");
    if (scenario == Scenario::unknown_error) throw 42;
    if (scenario == Scenario::missing ||
        (scenario == Scenario::init && !path.ends_with("/init.lua"))) return std::nullopt;
    if (scenario == Scenario::read_error)
    {
        *error = "fixture read failure for '" + path + "'";
        return std::nullopt;
    }
    const char *code = scenario == Scenario::syntax ? "local = broken" : "return 42";
    std::vector<char> data(8192, ' ');
    std::memcpy(data.data(), code, std::strlen(code));
    return data;
}

int main()
{
    const Scenario scenarios[] = {Scenario::present, Scenario::init, Scenario::missing,
        Scenario::read_error, Scenario::syntax, Scenario::native_error, Scenario::unknown_error};
    for (Scenario current : scenarios)
    {
        std::size_t lua_count = 0, cpp_count = 0, unused_lua = 0, unused_cpp = 0;
        if (!one_run(current, Failure::none, 0, lua_count, cpp_count)) return 1;
        if (lua_count == 0 || cpp_count == 0) return 2;
        for (std::size_t i = 0; i < lua_count; ++i)
            if (!one_run(current, Failure::lua, i, unused_lua, unused_cpp)) return 1;
        for (std::size_t i = 0; i < cpp_count; ++i)
            if (!one_run(current, Failure::cpp, i, unused_lua, unused_cpp)) return 1;
        std::printf("[PASS] embedded loader %s: %zu Lua and %zu C++ failure points\n",
                    scenario_name(current), lua_count, cpp_count);
    }
    std::printf("embedded loader OOM: %zu runs / 0 leaked C++ buffers\n", runs);
    for (Scenario current : scenarios)
        if (!require_contract(current)) return 1;
    return 0;
}
