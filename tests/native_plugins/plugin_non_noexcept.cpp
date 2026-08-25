#include "babet/plugin.h"

babet_status potentially_throwing_callback(babet_host_call *, void *)
{
    return BABET_STATUS_OK;
}

/* This source is expected NOT to compile in C++: a potentially-throwing
 * function pointer must not satisfy the native-plugin noexcept callback ABI. */
static const babet_plugin_function_v1 functions[] = {
    {{"bad", sizeof("bad") - 1}, potentially_throwing_callback, nullptr},
};

int main()
{
    return functions[0].function == nullptr;
}
