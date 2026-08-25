#include <babet/babet.h>

#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace {

babet_status throwing_host_function(babet_host_call *, void *)
{
    throw std::runtime_error("cpp host exception sentinel");
}

babet_status ok_host_function(babet_host_call *call, void *)
{
    babet_value result{};
    result.type = BABET_VALUE_INTEGER;
    result.as.integer = 42;
    return babet_host_call_set_result(call, &result);
}

bool expect_status(const char *label, babet_status actual, babet_status expected)
{
    if (actual == expected)
        return true;
    std::fprintf(stderr, "%s: expected %s, got %s\n", label,
                 babet_status_name(expected), babet_status_name(actual));
    return false;
}

} // namespace

int main()
{
    babet_context *context = nullptr;
    if (!expect_status("create", babet_context_create(&context), BABET_STATUS_OK) ||
        context == nullptr)
        return 1;

    if (!expect_status("register throwing callback",
                       babet_context_register_host_function(
                           context, "throwing_cpp", throwing_host_function, nullptr),
                       BABET_STATUS_OK) ||
        !expect_status("register recovery callback",
                       babet_context_register_host_function(
                           context, "ok_cpp", ok_host_function, nullptr),
                       BABET_STATUS_OK)) {
        std::fprintf(stderr, "%s\n", babet_context_last_error(context));
        (void)babet_context_destroy(context);
        return 1;
    }

    static constexpr char chunk[] =
        "local ok, err = pcall(babet.host.throwing_cpp)\n"
        "assert(not ok)\n"
        "assert(tostring(err):find('cpp host exception sentinel', 1, true))\n"
        "assert(babet.host.ok_cpp() == 42)\n";

    if (!expect_status("run", babet_context_run(context, chunk, sizeof(chunk) - 1,
                                                 "cpp-host-callback-smoke"),
                       BABET_STATUS_OK)) {
        std::fprintf(stderr, "%s\n", babet_context_last_error(context));
        (void)babet_context_destroy(context);
        return 1;
    }

    if (!expect_status("destroy", babet_context_destroy(context), BABET_STATUS_OK))
        return 1;

    std::puts("embedding C++ host callback smoke: PASS");
    return 0;
}
