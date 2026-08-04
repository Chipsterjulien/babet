#include "lua_exception_boundary.hpp"

#include <cstdio>
#include <exception>
#include <stdexcept>

struct lua_State
{
    int success_value = 0;
};

namespace
{
int return_success(lua_State *L)
{
    L->success_value = 42;
    return 1;
}

int throw_bad_alloc(lua_State *)
{
    throw std::bad_alloc();
}

int throw_standard_exception(lua_State *)
{
    throw std::runtime_error("detail that must not escape");
}

int throw_unknown_exception(lua_State *)
{
    throw 42;
}

struct Reporter
{
    LuaCxxExceptionKind *observed;
    bool *exception_inactive;

    int operator()(lua_State *, LuaCxxExceptionKind kind) const noexcept
    {
        *observed = kind;
        *exception_inactive = std::current_exception() == nullptr;
        return 2;
    }
};

struct FailureCheck
{
    bool classification;
    bool exception_inactive;
};

template <int (*Fn)(lua_State *)>
FailureCheck check_failure(lua_State *L, LuaCxxExceptionKind expected)
{
    LuaCxxExceptionKind observed = LuaCxxExceptionKind::unknown;
    bool exception_inactive = false;
    const int results = invoke_lua_cfunction_with_exception_boundary<Fn>(
        L, Reporter{&observed, &exception_inactive});
    return {results == 2 && observed == expected, exception_inactive};
}
} // namespace

int main()
{
    lua_State state;
    lua_State *L = &state;
    LuaCxxExceptionKind unused = LuaCxxExceptionKind::unknown;
    bool success_reporter_unused = false;
    const int success_results =
        invoke_lua_cfunction_with_exception_boundary<return_success>(
            L, Reporter{&unused, &success_reporter_unused});
    const bool success_ok = success_results == 1 && L->success_value == 42;
    const FailureCheck bad_alloc = check_failure<throw_bad_alloc>(
        L, LuaCxxExceptionKind::out_of_memory);
    const FailureCheck standard = check_failure<throw_standard_exception>(
        L, LuaCxxExceptionKind::standard);
    const FailureCheck unknown = check_failure<throw_unknown_exception>(
        L, LuaCxxExceptionKind::unknown);
    const bool reporters_inactive = bad_alloc.exception_inactive &&
                                    standard.exception_inactive &&
                                    unknown.exception_inactive;

    if (!success_ok || !bad_alloc.classification || !standard.classification ||
        !unknown.classification || !reporters_inactive)
    {
        std::fprintf(stderr,
                     "[FAIL] exception boundary self-test: success=%d "
                     "bad_alloc=%d standard=%d unknown=%d "
                     "reporters_inactive=%d\n",
                     success_ok ? 1 : 0,
                     bad_alloc.classification ? 1 : 0,
                     standard.classification ? 1 : 0,
                     unknown.classification ? 1 : 0,
                     reporters_inactive ? 1 : 0);
        return 1;
    }

    std::puts("[PASS] common Lua C++ exception classification boundary "
              "reports after catch cleanup");
    return 0;
}
